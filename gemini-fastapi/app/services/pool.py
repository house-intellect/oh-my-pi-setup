import glob
import json
import os
import tempfile
from pathlib import Path

def clean_stale_gemini_cookie_caches():
    """Purge cached cookie files that cause Error 1097 desync or replay of revoked sessions."""
    dirs_to_clean = [
        Path(tempfile.gettempdir()) / "gemini_webapi",
        Path("/tmp/gemini_webapi"),
    ]
    env_path = os.getenv("GEMINI_COOKIE_PATH")
    if env_path:
        dirs_to_clean.append(Path(env_path))

    for cdir in dirs_to_clean:
        if cdir.exists():
            for f in cdir.glob(".cached_cookies_*.json"):
                try:
                    f.unlink(missing_ok=True)
                except OSError:
                    pass

import asyncio
from collections import deque

from loguru import logger

from app.utils import g_config
from app.utils.config import GeminiClientSettings
from app.utils.singleton import Singleton

from .client import GeminiClientWrapper


class GeminiClientPool(metaclass=Singleton):
    """Pool of GeminiClient instances identified by unique ids."""

    def __init__(self) -> None:
        self._clients: list[GeminiClientWrapper] = []
        self._id_map: dict[str, GeminiClientWrapper] = {}
        self._round_robin: deque[GeminiClientWrapper] = deque()
        self._restart_locks: dict[str, asyncio.Lock] = {}

        clients_to_load = list(g_config.gemini.clients)
        if len(clients_to_load) == 0 or (
            len(clients_to_load) == 1
            and (
                not clients_to_load[0].secure_1psid
                or "YOUR_SECURE" in str(clients_to_load[0].secure_1psid)
            )
        ):
            found_clients = []
            dirs_to_check = [
                Path(tempfile.gettempdir()) / "gemini_webapi",
                Path("/tmp/gemini_webapi"),
            ]
            env_cpath = os.getenv("GEMINI_COOKIE_PATH")
            if env_cpath:
                dirs_to_check.append(Path(env_cpath))

            cached_files = []
            for d in dirs_to_check:
                if d.exists():
                    cached_files.extend(list(d.glob(".cached_cookies_*.json")))

            if cached_files:
                newest_cache = max(cached_files, key=lambda p: p.stat().st_mtime)
                try:
                    cdata = json.loads(newest_cache.read_text())
                    if isinstance(cdata, list):
                        cdict = {c.get("name"): c.get("value") for c in cdata if isinstance(c, dict)}
                    elif isinstance(cdata, dict):
                        cdict = cdata
                    else:
                        cdict = {}
                    cpsid = cdict.get("__Secure-1PSID")
                    cpsidts = cdict.get("__Secure-1PSIDTS")
                    cpsidcc = cdict.get("__Secure-1PSIDCC") or cdict.get("__Secure-3PSIDCC") or cdict.get("SIDCC")
                    if cpsid and cpsidts:
                        found_clients.append(
                            GeminiClientSettings(
                                id="active-cached-session",
                                secure_1psid=cpsid,
                                secure_1psidts=cpsidts,
                                secure_1psidcc=cpsidcc,
                                proxy=None,
                            )
                        )
                        logger.info(f"Reusing active rotated session cookies from cache ({newest_cache.name}).")
                except Exception as e:
                    logger.debug(f"Failed to read existing cache {newest_cache}: {e}")

            if not found_clients:
                try:
                    import rookiepy
                    for b_name in ["firefox", "chrome", "chromium", "brave", "edge", "opera", "vivaldi"]:
                        fn = getattr(rookiepy, b_name, None)
                        if not fn:
                            continue
                        try:
                            cookies = fn([".google.com"])
                            cdict = {c["name"]: c["value"] for c in cookies if c.get("domain") in [".google.com", "google.com"]}
                            psid = cdict.get("__Secure-1PSID")
                            psidts = cdict.get("__Secure-1PSIDTS")
                            psidcc = cdict.get("__Secure-1PSIDCC") or cdict.get("__Secure-3PSIDCC") or cdict.get("SIDCC")
                            if psid and psidts:
                                found_clients.append(
                                    GeminiClientSettings(
                                        id=f"auto-{b_name}",
                                        secure_1psid=psid,
                                        secure_1psidts=psidts,
                                        secure_1psidcc=psidcc,
                                        proxy=None,
                                    )
                                )
                                logger.info(f"Loaded Google session cookies from {b_name}.")
                                break
                        except Exception:
                            continue
                except Exception:
                    pass

            if found_clients:
                clients_to_load = found_clients

        if len(clients_to_load) == 0:
            raise ValueError("No Gemini clients configured and auto-extraction failed.")

        doh_url = os.environ.get("GEMINI_DOH_URL", "https://dns.bezmezhau.com/dns-query")
        if isinstance(doh_url, str):
            doh_url = doh_url.encode()

        for c in clients_to_load:
            curl_opts = {}
            try:
                from curl_cffi import CurlOpt
                curl_opts[CurlOpt.DOH_URL] = doh_url
            except Exception:
                pass

            client = GeminiClientWrapper(
                client_id=c.id,
                secure_1psid=c.secure_1psid,
                secure_1psidts=c.secure_1psidts,
                secure_1psidcc=getattr(c, "secure_1psidcc", None),
                proxy=c.proxy,
                curl_options=curl_opts,
            )
            self._clients.append(client)
            self._id_map[c.id] = client
            self._round_robin.append(client)
            self._restart_locks[c.id] = asyncio.Lock()

        self._recovery_lock = asyncio.Lock()

    async def reload_cookies_from_browser(self, target_client: GeminiClientWrapper | None = None) -> bool:
        """
        Dynamically extract fresh cookies from local browsers (prioritizing Firefox)
        and re-initialize the target client (or active pool clients) to recover from
        expired sessions, guest mode, or 401 UNAUTHENTICATED errors.
        """
        async with self._recovery_lock:
            if target_client and target_client.running() and getattr(target_client, "_cookie_source", "") != "Guest":
                if any(m.is_available for m in getattr(target_client, "models", []) if "flash" in m.model_name.lower()):
                    return True

            clean_stale_gemini_cookie_caches()

            import rookiepy
            browsers = ["firefox", "chrome", "chromium", "brave", "edge", "opera", "vivaldi"]

            clients_to_update = [target_client] if target_client else list(self._clients)
            if not clients_to_update:
                new_client = GeminiClientWrapper(
                    client_id="live-recovered",
                    proxy=None,
                )
                self._clients.append(new_client)
                self._id_map[new_client.id] = new_client
                self._round_robin.append(new_client)
                self._restart_locks[new_client.id] = asyncio.Lock()
                clients_to_update = [new_client]

            for b_name in browsers:
                fn = getattr(rookiepy, b_name, None)
                if not fn:
                    continue
                try:
                    cookies = fn([".google.com"])
                    cdict = {c["name"]: c["value"] for c in cookies if c.get("domain") in [".google.com", "google.com"]}
                    psid = cdict.get("__Secure-1PSID")
                    psidts = cdict.get("__Secure-1PSIDTS")
                    psidcc = cdict.get("__Secure-1PSIDCC") or cdict.get("__Secure-3PSIDCC") or cdict.get("SIDCC")
                    if not (psid and psidts):
                        continue

                    logger.info(f"Testing candidate session cookies from {b_name}...")
                    clean_stale_gemini_cookie_caches()

                    candidate_success = False
                    for client in clients_to_update:
                        if not client:
                            continue
                        lock = self._restart_locks.setdefault(client.id, asyncio.Lock())
                        async with lock:
                            try:
                                await client.close()
                            except Exception:
                                pass

                            client._cookies.set("__Secure-1PSID", psid, domain=".google.com", secure=True)
                            client._cookies.set("__Secure-1PSIDTS", psidts, domain=".google.com", secure=True)
                            if psidcc:
                                client._cookies.set("__Secure-1PSIDCC", psidcc, domain=".google.com", secure=True)

                            client.client = None
                            client.SNlM0e = None
                            client._running = False

                            clean_stale_gemini_cookie_caches()

                            try:
                                await client.init(
                                    timeout=g_config.gemini.timeout,
                                    watchdog_timeout=g_config.gemini.watchdog_timeout,
                                    auto_refresh=g_config.gemini.auto_refresh,
                                    verbose=g_config.gemini.verbose,
                                    refresh_interval=g_config.gemini.refresh_interval,
                                )
                                if client.running() and getattr(client, "_cookie_source", "") != "Guest":
                                    logger.success(f"Client {client.id} successfully authenticated and recovered using {b_name} cookies!")
                                    candidate_success = True
                                else:
                                    logger.warning(f"Client {client.id} with {b_name} cookies fell back to Guest mode.")
                                    try:
                                        await client.close()
                                    except Exception:
                                        pass
                                    clean_stale_gemini_cookie_caches()
                            except Exception as e:
                                logger.warning(f"Browser {b_name} cookies failed to authenticate client {client.id}: {e}")

                    if candidate_success:
                        return True
                    else:
                        logger.warning(f"Cookies from {b_name} were unauthenticated or expired. Trying next browser...")
                except Exception as e:
                    logger.debug(f"Failed to extract cookies from {b_name}: {e}")
                    continue

            logger.error("Dynamic cookie recovery failed: No working browser session cookies found across all tested browsers.")
            return False

    async def init(self) -> None:
        """Initialize all clients in the pool."""
        success_count = 0
        for client in self._clients:
            if not client.running():
                try:
                    await client.init(
                        timeout=g_config.gemini.timeout,
                        watchdog_timeout=g_config.gemini.watchdog_timeout,
                        auto_refresh=g_config.gemini.auto_refresh,
                        verbose=g_config.gemini.verbose,
                        refresh_interval=g_config.gemini.refresh_interval,
                    )
                except Exception:
                    pass

            if client.running():
                if getattr(client, "_cookie_source", "") == "Guest":
                    logger.warning(f"Client {client.id} initialized in unauthenticated Guest mode. Discarding guest session.")
                    try:
                        await client.close()
                    except Exception:
                        pass
                    clean_stale_gemini_cookie_caches()
                else:
                    success_count += 1

        if success_count == 0:
            logger.warning("No authenticated clients initialized via existing cookies. Attempting dynamic cookie recovery from browser...")
            if await self.reload_cookies_from_browser():
                success_count = sum(1 for c in self._clients if c.running() and getattr(c, "_cookie_source", "") != "Guest")

        if success_count == 0:
            raise RuntimeError("Failed to initialize any Gemini clients")


    async def acquire(self, client_id: str | None = None) -> GeminiClientWrapper:
        """Return a healthy client by id or using round-robin."""
        if not self._round_robin:
            raise RuntimeError("No Gemini clients configured")

        if client_id:
            client = self._id_map.get(client_id)
            if not client:
                raise ValueError(f"Client id {client_id} not found")
            if await self._ensure_client_ready(client):
                return client
            raise RuntimeError(
                f"Gemini client {client_id} is not running and could not be restarted"
            )

        for _ in range(len(self._round_robin)):
            client = self._round_robin[0]
            self._round_robin.rotate(-1)
            if await self._ensure_client_ready(client):
                return client

        await self.init()
        for _ in range(len(self._round_robin)):
            client = self._round_robin[0]
            self._round_robin.rotate(-1)
            if await self._ensure_client_ready(client):
                return client

        raise RuntimeError("No Gemini clients are currently available")

    async def _ensure_client_ready(self, client: GeminiClientWrapper) -> bool:
        """Make sure the client is running, attempting a restart if needed."""
        if client.running():
            return True

        lock = self._restart_locks.get(client.id)
        if lock is None:
            return False

        async with lock:
            if client.running():
                return True

            try:
                await client.init(
                    timeout=g_config.gemini.timeout,
                    watchdog_timeout=g_config.gemini.watchdog_timeout,
                    auto_refresh=g_config.gemini.auto_refresh,
                    verbose=g_config.gemini.verbose,
                    refresh_interval=g_config.gemini.refresh_interval,
                )
                if client.running():
                    logger.info(f"Restarted Gemini client {client.id} after it stopped.")
                    return True
            except Exception:
                logger.warning(f"Standard restart failed for Gemini client {client.id}. Attempting dynamic browser cookie recovery...")

            try:
                if await self.reload_cookies_from_browser(client):
                    return True
            except Exception:
                logger.exception(f"Dynamic cookie recovery failed for client {client.id}")

            return False

    @property
    def clients(self) -> list[GeminiClientWrapper]:
        """Return managed clients."""
        return self._clients

    def status(self) -> dict[str, bool]:
        """Return running status for each client."""
        return {client.id: client.running() for client in self._clients}
