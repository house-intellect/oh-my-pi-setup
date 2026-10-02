import glob
import os

def clean_stale_gemini_cookie_caches():
    """Purge cached cookie files that cause Error 1097 desync."""
    for f in glob.glob("/tmp/gemini_webapi/.cached_cookies_*.json"):
        try:
            os.remove(f)
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
        clean_stale_gemini_cookie_caches()
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
            # Prioritize Firefox first: reads cookies.sqlite directly without triggering OS keyring / KWallet / SecretService GUI prompts.
            found_clients = []
            try:
                import rookiepy
                for b_name in ["firefox"]:
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
                    except Exception:
                        pass

                if not found_clients:
                    for b_name in ["chrome", "chromium", "brave", "edge", "opera"]:
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
                                break
                        except Exception:
                            continue
            except Exception:
                pass

            if found_clients:
                clients_to_load = found_clients

        if len(clients_to_load) == 0:
            raise ValueError("No Gemini clients configured and auto-extraction failed.")

        import os
        doh_url = os.environ.get("GEMINI_DOH_URL", "https://dns.comss.one/dns-query")
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
                success_count += 1

        if success_count == 0:
            try:
                import rookiepy
                import os
                from curl_cffi import CurlOpt
                candidate_resolvers = []
                env_doh = os.environ.get("GEMINI_DOH_URL")
                if env_doh:
                    candidate_resolvers.append(env_doh)
                for r in ["https://dns.bezmezhau.com/dns-query", "https://dns.comss.one/dns-query"]:
                    if r not in candidate_resolvers:
                        candidate_resolvers.append(r)

                initialized = False
                for b_name in ["chrome", "firefox", "chromium", "brave"]:
                    if initialized:
                        break
                    fn = getattr(rookiepy, b_name, None)
                    if not fn:
                        continue
                    try:
                        cookies = fn([".google.com"])
                        cdict = {c["name"]: c["value"] for c in cookies if c.get("domain") in [".google.com", "google.com"] and "1PSID" in c.get("name", "")}
                        if not ("__Secure-1PSID" in cdict and "__Secure-1PSIDTS" in cdict):
                            continue

                        for resolver in candidate_resolvers:
                            doh_bytes = resolver.encode() if isinstance(resolver, str) else resolver
                            try:
                                fallback_client = GeminiClientWrapper(
                                    client_id=f"live-{b_name}",
                                    secure_1psid=cdict["__Secure-1PSID"],
                                    secure_1psidts=cdict["__Secure-1PSIDTS"],
                                    secure_1psidcc=cdict.get("__Secure-1PSIDCC") or cdict.get("__Secure-3PSIDCC") or cdict.get("SIDCC"),
                                    proxy=None,
                                    curl_options={CurlOpt.DOH_URL: doh_bytes},
                                )
                                await fallback_client.init(
                                    timeout=g_config.gemini.timeout,
                                    watchdog_timeout=g_config.gemini.watchdog_timeout,
                                    auto_refresh=g_config.gemini.auto_refresh,
                                    verbose=g_config.gemini.verbose,
                                    refresh_interval=g_config.gemini.refresh_interval,
                                )
                                if fallback_client.running():
                                    self._clients.append(fallback_client)
                                    self._id_map[fallback_client.id] = fallback_client
                                    self._round_robin.append(fallback_client)
                                    self._restart_locks[fallback_client.id] = asyncio.Lock()
                                    success_count += 1
                                    initialized = True
                                    break
                            except Exception:
                                continue
                    except Exception:
                        continue
            except Exception:
                pass

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
                logger.info(f"Restarted Gemini client {client.id} after it stopped.")
                return True
            except Exception:
                logger.exception(f"Failed to restart Gemini client {client.id}")
                return False

    @property
    def clients(self) -> list[GeminiClientWrapper]:
        """Return managed clients."""
        return self._clients

    def status(self) -> dict[str, bool]:
        """Return running status for each client."""
        return {client.id: client.running() for client in self._clients}
