#!/bin/bash
# ==============================================================================
# One-Script Installer & Setup for "Oh My Pi" (OMP) with Gemini WebAPI
# Works in geoblocked locations via DoH SNI routing & Firefox cookie extraction.
# ==============================================================================
# POSIX compatibility: re-exec with bash if launched via dash/sh
if [ -z "$BASH_VERSION" ]; then
    if command -v bash >/dev/null 2>&1; then
        exec bash "$0" "$@"
    fi
fi
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
STACK_DIR="$HOME/local-ai-stack"
FASTAPI_DIR="$STACK_DIR/gemini-fastapi"
FASTAPI_PORT=8000
BIN_DIR="$HOME/.local/bin"

DEFAULT_DOH_URL="https://dns.comss.one/dns-query"
export GEMINI_DOH_URL="${GEMINI_DOH_URL:-$DEFAULT_DOH_URL}"

# Purge any stale desynchronized cookie caches to avoid Error 1097
rm -f /tmp/gemini_webapi/.cached_cookies_*.json 2>/dev/null || true

echo "=== [1/5] Checking Environment & Dependencies ==="

# Check Python 3
if ! command -v python3 &>/dev/null; then
    echo "Error: Python 3 is required. Please install python3 (>= 3.10)."
    exit 1
fi

PY_VER=$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')
echo "Detected Python $PY_VER"

# Check Curl
if ! command -v curl &>/dev/null; then
    echo "Error: curl is required."
    exit 1
fi

mkdir -p "$STACK_DIR" "$BIN_DIR" "$HOME/.omp/agent" "$HOME/.pi/agent"

echo "=== [2/5] Installing Oh My Pi (omp) ==="

OMP_INSTALLED=0
if [ -f "$SCRIPT_DIR/bin/omp" ]; then
    echo "Found embedded omp binary in $SCRIPT_DIR/bin/omp."
    cp "$SCRIPT_DIR/bin/omp" "$BIN_DIR/omp"
    chmod +x "$BIN_DIR/omp"
    OMP_INSTALLED=1
elif [ -f "$STACK_DIR/bin/omp" ]; then
    echo "Found existing omp in $STACK_DIR/bin/omp."
    cp "$STACK_DIR/bin/omp" "$BIN_DIR/omp"
    chmod +x "$BIN_DIR/omp"
    OMP_INSTALLED=1
else
    echo "Downloading latest omp-linux-x64 binary..."
    OMP_RELEASE_URL="https://github.com/can1357/oh-my-pi/releases/download/v18.2.8/omp-linux-x64"
    if curl -L "$OMP_RELEASE_URL" -o "$BIN_DIR/omp"; then
        chmod +x "$BIN_DIR/omp"
        OMP_INSTALLED=1
    else
        echo "Failed to download omp-linux-x64 directly. Checking local fallback..."
    fi
fi

if [ $OMP_INSTALLED -ne 1 ] || [ ! -x "$BIN_DIR/omp" ]; then
    echo "Error: Could not install executable omp binary."
    exit 1
fi

mkdir -p "$STACK_DIR/bin"
cp "$BIN_DIR/omp" "$STACK_DIR/bin/omp"
chmod +x "$STACK_DIR/bin/omp"
echo "omp binary installed successfully at $BIN_DIR/omp and $STACK_DIR/bin/omp"

echo "=== [3/5] Setting Up Gemini-FastAPI Backend ==="

if [ ! -f "$FASTAPI_DIR/run.py" ]; then
    if [ -d "$SCRIPT_DIR/gemini-fastapi" ] && [ -f "$SCRIPT_DIR/gemini-fastapi/run.py" ]; then
        echo "Deploying embedded gemini-fastapi from $SCRIPT_DIR/gemini-fastapi..."
        mkdir -p "$FASTAPI_DIR"
        cp -r "$SCRIPT_DIR/gemini-fastapi/"* "$FASTAPI_DIR/"
    elif command -v git &>/dev/null; then
        echo "Cloning gemini-fastapi from GitHub..."
        git clone https://github.com/Nativu5/Gemini-FastAPI.git "$FASTAPI_DIR"
    else
        echo "Error: No gemini-fastapi source found and git is unavailable."
        exit 1
    fi
else
    echo "Found existing Gemini-FastAPI at $FASTAPI_DIR, synchronizing latest app updates..."
    if [ -d "$SCRIPT_DIR/gemini-fastapi/app" ]; then
        cp -r "$SCRIPT_DIR/gemini-fastapi/app/"* "$FASTAPI_DIR/app/" 2>/dev/null || true
    fi
fi

# Ensure Python Virtual Environment
PYTHON_EXEC=""
if [ -d "$STACK_DIR/tool-calling-test/.venv" ] && [ -x "$STACK_DIR/tool-calling-test/.venv/bin/python" ]; then
    echo "Reusing existing verified local-ai-stack virtual environment..."
    PYTHON_EXEC="$STACK_DIR/tool-calling-test/.venv/bin/python"
    ln -sfn "$STACK_DIR/tool-calling-test/.venv" "$FASTAPI_DIR/.venv"
elif [ -d "$FASTAPI_DIR/.venv" ] && [ -x "$FASTAPI_DIR/.venv/bin/python" ]; then
    echo "Reusing existing gemini-fastapi virtual environment..."
    PYTHON_EXEC="$FASTAPI_DIR/.venv/bin/python"
else
    if [ ! -d "$FASTAPI_DIR/.venv" ]; then
        echo "Creating dedicated virtual environment in $FASTAPI_DIR/.venv..."
        python3 -m venv "$FASTAPI_DIR/.venv"
    fi
    PYTHON_EXEC="$FASTAPI_DIR/.venv/bin/python"
    PIP_EXEC="$FASTAPI_DIR/.venv/bin/pip"
    
    echo "Installing required Python packages..."
    if [ -d "$SCRIPT_DIR/wheels" ]; then
        "$PIP_EXEC" install --no-index --find-links="$SCRIPT_DIR/wheels" \
            fastapi "uvicorn[standard]" curl_cffi gemini-webapi==2.0.0 rookiepy lmdb pydantic pydantic-settings pyyaml loguru orjson httptools 2>/dev/null || true
    fi
    "$PIP_EXEC" install --upgrade pip setuptools wheel 2>/dev/null || true
    "$PIP_EXEC" install fastapi "uvicorn[standard]" curl_cffi gemini-webapi==2.0.0 rookiepy lmdb pydantic pydantic-settings pyyaml loguru orjson httptools 2>/dev/null || true
fi

echo "=== [4/5] Applying Geoblock & Keyring-Free Patches ==="

# Apply patches to Gemini-FastAPI server files
"$PYTHON_EXEC" -c '
import re
from pathlib import Path

fastapi_dir = Path("'"$FASTAPI_DIR"'")

# 1. Patch app/services/client.py
wrap_file = fastapi_dir / "app" / "services" / "client.py"
if wrap_file.exists():
    wtxt = wrap_file.read_text()
    if "AccountStatus.LOCATION_REJECTED" not in wtxt:
        new_client_code = """class GeminiClientWrapper(GeminiClient):
    \"\"\"Extended GeminiClient that tracks lifecycle state and DoH curl options.\"\"\"

    def __init__(
        self,
        client_id: str,
        secure_1psid: str,
        secure_1psidts: str,
        proxy: str | None = None,
        secure_1psidcc: str | None = None,
        curl_options: dict | None = None,
    ) -> None:
        kwargs = {}
        if secure_1psidcc:
            kwargs["secure_1psidcc"] = secure_1psidcc
        if curl_options:
            kwargs["curl_options"] = curl_options

        super().__init__(
            secure_1psid=secure_1psid,
            secure_1psidts=secure_1psidts,
            proxy=proxy,
            **kwargs,
        )
        self.id = client_id
        self._running = False
        self.curl_options = curl_options or {}
        try:
            from curl_cffi import CurlOpt
            import os
            doh_endpoint = os.environ.get("GEMINI_DOH_URL", "https://dns.comss.one/dns-query").encode()
            if CurlOpt.DOH_URL not in self.curl_options:
                self.curl_options[CurlOpt.DOH_URL] = doh_endpoint
        except Exception:
            pass

    async def init(
        self,
        timeout: float = cast(float, _UNSET),
        watchdog_timeout: float = cast(float, _UNSET),
        auto_close: bool = False,
        close_delay: float = cast(float, _UNSET),
        auto_refresh: bool = cast(bool, _UNSET),
        refresh_interval: float = cast(float, _UNSET),
        verbose: bool = cast(bool, _UNSET),
    ) -> None:
        config = g_config.gemini
        timeout = cast(float, _resolve(timeout, config.timeout))
        watchdog_timeout = cast(float, _resolve(watchdog_timeout, config.watchdog_timeout))
        close_delay = timeout
        auto_refresh = cast(bool, _resolve(auto_refresh, config.auto_refresh))
        refresh_interval = cast(float, _resolve(refresh_interval, config.refresh_interval))
        verbose = cast(bool, _resolve(verbose, config.verbose))

        try:
            await super().init(
                timeout=timeout,
                watchdog_timeout=watchdog_timeout,
                auto_close=auto_close,
                close_delay=close_delay,
                auto_refresh=auto_refresh,
                refresh_interval=refresh_interval,
                verbose=verbose,
            )
            from gemini_webapi.constants import AccountStatus
            hard_blocks = [
                AccountStatus.LOCATION_REJECTED,
                AccountStatus.ACCOUNT_REJECTED,
                AccountStatus.ACCESS_TEMPORARILY_UNAVAILABLE,
                AccountStatus.ACCOUNT_REJECTED_BY_GUARDIAN,
                AccountStatus.GUARDIAN_APPROVAL_REQUIRED,
            ]
            if hasattr(self, "account_status") and self.account_status in hard_blocks:
                self._running = False
            elif self.client and hasattr(self, "curl_options") and self.curl_options:
                if not getattr(self.client, "curl_options", None):
                    self.client.curl_options = dict(self.curl_options)
                else:
                    for k, v in self.curl_options.items():
                        self.client.curl_options.setdefault(k, v)
        except Exception:
            raise

    def running(self) -> bool:
        from gemini_webapi.constants import AccountStatus
        hard_blocks = [
            AccountStatus.LOCATION_REJECTED,
            AccountStatus.ACCOUNT_REJECTED,
            AccountStatus.ACCESS_TEMPORARILY_UNAVAILABLE,
            AccountStatus.ACCOUNT_REJECTED_BY_GUARDIAN,
            AccountStatus.GUARDIAN_APPROVAL_REQUIRED,
        ]
        if hasattr(self, "account_status") and self.account_status in hard_blocks:
            return False
        return self._running
"""
        wtxt = re.sub(r"class GeminiClientWrapper\(GeminiClient\):.*?def running\(self\) -> bool:\s+return self\._running", new_client_code.strip(), wtxt, flags=re.DOTALL)
        wrap_file.write_text(wtxt)

# 2. Patch app/services/pool.py (Prioritize Firefox cookies.sqlite, avoiding KWallet/SecretService popups)
pool_file = fastapi_dir / "app" / "services" / "pool.py"
if pool_file.exists():
    ptxt = pool_file.read_text()
    if "clean_stale_gemini_cookie_caches" not in ptxt:
        ptxt = "import glob\nimport os\n\ndef clean_stale_gemini_cookie_caches():\n    for f in glob.glob(\"/tmp/gemini_webapi/.cached_cookies_*.json\"):\n        try:\n            os.remove(f)\n        except OSError:\n            pass\n\n" + ptxt
    if "GeminiClientSettings" not in ptxt:
        ptxt = ptxt.replace("from app.utils import g_config", "from app.utils import g_config\nfrom app.utils.config import GeminiClientSettings")
    new_pool_code = """class GeminiClientPool(metaclass=Singleton):
    \"\"\"Pool of GeminiClient instances identified by unique ids.\"\"\"

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
        \"\"\"Initialize all clients in the pool.\"\"\"
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
                doh_url = os.environ.get("GEMINI_DOH_URL", "https://dns.comss.one/dns-query")
                if isinstance(doh_url, str):
                    doh_url = doh_url.encode()
                for b_name in ["firefox", "chrome", "chromium", "brave"]:
                    fn = getattr(rookiepy, b_name, None)
                    if not fn:
                        continue
                    try:
                        cookies = fn([".google.com"])
                        cdict = {c["name"]: c["value"] for c in cookies if c.get("domain") in [".google.com", "google.com"] and "1PSID" in c.get("name", "")}
                        if "__Secure-1PSID" in cdict and "__Secure-1PSIDTS" in cdict:
                            fallback_client = GeminiClientWrapper(
                                client_id=f"live-{b_name}",
                                secure_1psid=cdict["__Secure-1PSID"],
                                secure_1psidts=cdict["__Secure-1PSIDTS"],
                                secure_1psidcc=cdict.get("__Secure-1PSIDCC") or cdict.get("__Secure-3PSIDCC") or cdict.get("SIDCC"),
                                proxy=None,
                                curl_options={CurlOpt.DOH_URL: doh_url},
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
                                break
                    except Exception:
                        continue
            except Exception:
                pass

        if success_count == 0:
            raise RuntimeError("Failed to initialize any Gemini clients")

    async def acquire(self, client_id: str | None = None) -> GeminiClientWrapper:
        \"\"\"Return a healthy client by id or using round-robin.\"\"\"
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
"""
    if "class GeminiClientPool" in ptxt:
        ptxt = re.sub(r"class GeminiClientPool\(metaclass=Singleton\):.*?async def _ensure_client_ready", new_pool_code.strip() + "\n\n    async def _ensure_client_ready", ptxt, flags=re.DOTALL)
    pool_file.write_text(ptxt)

# 3. Patch app/utils/config.py
cfg_py = fastapi_dir / "app" / "utils" / "config.py"
if cfg_py.exists():
    ctxt = cfg_py.read_text()
    if "host: str = Field(default=\"0.0.0.0\"" in ctxt:
        ctxt = ctxt.replace("host: str = Field(default=\"0.0.0.0\"", "host: str = Field(default=\"127.0.0.1\"")
    if "secure_1psidcc: str | None = Field" not in ctxt:
        ctxt = ctxt.replace(
            "secure_1psidts: str = Field(..., description=\"Gemini Secure 1PSIDTS\")",
            "secure_1psidts: str = Field(..., description=\"Gemini Secure 1PSIDTS\")\n    secure_1psidcc: str | None = Field(default=None, description=\"Gemini Secure 1PSIDCC\")"
        )
    cfg_py.write_text(ctxt)

# 4. Patch app/server/chat.py with comprehensive model aliases
chat_py = fastapi_dir / "app" / "server" / "chat.py"
if chat_py.exists():
    ctext = chat_py.read_text()
    if "gemini-3.8-flash" not in ctext:
        old_fn = """def _get_model_by_name(name: str) -> Model:
    \"\"\"Retrieve a Model instance by name.\"\"\"
    strategy = g_config.gemini.model_strategy
    custom_models = {m.model_name: m for m in g_config.gemini.models if m.model_name}

    if name in custom_models:
        return Model.from_dict(custom_models[name].model_dump())

    if strategy == "overwrite":
        raise ValueError(f"Model \x27{name}\x27 not found in custom models (strategy=\x27overwrite\x27).")

    return Model.from_name(name)"""
        new_fn = """MODEL_ALIASES = {
    "gemini-3.8-flash": "gemini-3-flash",
    "3.8-flash": "gemini-3-flash",
    "gemini-3.5-flash-lite": "gemini-3-flash",
    "gemini-3.1-pro": "gemini-3-pro",
    "gemini-extended-thinking": "gemini-3-flash-thinking",
    "gemini-3.7-flash": "gemini-3-flash",
    "gemini-3.7-pro": "gemini-3-pro",
    "gemini-3-flash": "gemini-3-flash",
    "gemini-3-flash-thinking": "gemini-3-flash-thinking",
    "gemini-3-pro": "gemini-3-pro",
    "flash": "gemini-3-flash",
    "thinking": "gemini-3-flash-thinking",
    "pro": "gemini-3-pro",
    "gemini-flash": "gemini-3-flash",
    "gemini-pro": "gemini-3-pro",
    "gpt-4o": "gemini-3-flash",
    "gpt-4": "gemini-3-pro",
}

def _get_model_by_name(name: str) -> Model:
    strategy = g_config.gemini.model_strategy
    custom_models = {m.model_name: m for m in g_config.gemini.models if m.model_name}

    if name in custom_models:
        return Model.from_dict(custom_models[name].model_dump())

    resolved_name = MODEL_ALIASES.get(name, name)
    if resolved_name in custom_models:
        return Model.from_dict(custom_models[resolved_name].model_dump())

    if strategy == "overwrite":
        raise ValueError(f"Model \x27{name}\x27 not found in custom models (strategy=\x27overwrite\x27).")

    try:
        return Model.from_name(resolved_name)
    except Exception:
        return Model.BASIC_FLASH"""
        if old_fn in ctext:
            ctext = ctext.replace(old_fn, new_fn)
            chat_py.write_text(ctext)

# 5. Patch config/config.yaml to ensure empty credentials trigger browser extraction
cfg_file = fastapi_dir / "config" / "config.yaml"
if not cfg_file.exists():
    cfg_file.parent.mkdir(parents=True, exist_ok=True)
    cfg_file.write_text("""server:
  host: "127.0.0.1"
  port: 8000
  api_key: null
  https:
    enabled: false

cors:
  enabled: true
  allow_origins: ["*"]
  allow_credentials: true
  allow_methods: ["*"]
  allow_headers: ["*"]

gemini:
  clients:
    - id: "primary-client"
      secure_1psid: ""
      secure_1psidts: ""
      proxy: null
  timeout: 600
""")
' 2>/dev/null || true

# Apply patches to site-packages (curl_cffi and gemini_webapi)
"$PYTHON_EXEC" -c '
import glob
import sys
from pathlib import Path

for sp in sys.path:
    if "site-packages" not in sp:
        continue

    # Global BaseSession DoH injection
    init_file = Path(f"{sp}/gemini_webapi/__init__.py")
    if init_file.exists():
        txt = init_file.read_text()
        if "CurlOpt.DOH_URL" not in txt:
            doh_code = """try:
    from curl_cffi import CurlOpt
    from curl_cffi.requests.session import BaseSession

    _orig_base_init = BaseSession.__init__

    def _doh_base_init(self, *args, **kwargs):
        curl_opts = kwargs.get("curl_options")
        if curl_opts is None:
            curl_opts = {}
            kwargs["curl_options"] = curl_opts
        if isinstance(curl_opts, dict) and CurlOpt.DOH_URL not in curl_opts:
            curl_opts[CurlOpt.DOH_URL] = b"https://dns.comss.one/dns-query"
        _orig_base_init(self, *args, **kwargs)

    BaseSession.__init__ = _doh_base_init
except Exception:
    pass

"""
            init_file.write_text(doh_code + txt)

    # StrEnum polyfill for Python 3.10
    for f in glob.glob(f"{sp}/gemini_webapi/**/*.py", recursive=True):
        p = Path(f)
        txt = p.read_text()
        if "from enum import Enum, IntEnum, StrEnum" in txt:
            txt = txt.replace(
                "from enum import Enum, IntEnum, StrEnum",
                "from enum import Enum, IntEnum\ntry:\n    from enum import StrEnum\nexcept ImportError:\n    class StrEnum(str, Enum):\n        pass"
            )
            p.write_text(txt)

    # Patch client.py to store and pass curl_options & secure_1psidcc
    client_file = Path(f"{sp}/gemini_webapi/client.py")
    if client_file.exists():
        txt = client_file.read_text()
        if "self.curl_options" not in txt:
            txt = txt.replace(
                "self.kwargs = kwargs",
                "self.kwargs = kwargs\n        self.curl_options = kwargs.get(\"curl_options\")\n        if self.curl_options is None:\n            try:\n                from curl_cffi import CurlOpt\n                self.curl_options = {CurlOpt.DOH_URL: b\"https://dns.comss.one/dns-query\"}\n            except Exception:\n                pass"
            )
            txt = txt.replace(
                "verify=self.kwargs.get(\"verify\", True),",
                "verify=self.kwargs.get(\"verify\", True),\n                    curl_options=self.curl_options,"
            )
        if "secure_1psidcc" not in txt:
            txt = txt.replace(
                "self._cookies.set(\n                    \"__Secure-1PSIDTS\", secure_1psidts, domain=\".google.com\"\n                )",
                "self._cookies.set(\n                    \"__Secure-1PSIDTS\", secure_1psidts, domain=\".google.com\"\n                )\n        if secure_1psidcc := kwargs.get(\"secure_1psidcc\"):\n            self._cookies.set(\"__Secure-1PSIDCC\", secure_1psidcc, domain=\".google.com\")"
            )
        if "Ignoring non-fatal post-generation code" not in txt:
            old_err = """                                    case _:
                                        raise APIError(
                                            f"Failed to generate contents (stream). Unknown API error code: {error_code}. "
                                            "This might be a temporary Google service issue."
                                        )"""
            new_err = """                                    case _:
                                        if has_generated_text or error_code in [1096]:
                                            logger.warning(f"Ignoring non-fatal post-generation code {error_code}")
                                            break
                                        raise APIError(
                                            f"Failed to generate contents (stream). Unknown API error code: {error_code}. "
                                            "This might be a temporary Google service issue."
                                        )"""
            if old_err in txt:
                txt = txt.replace("nonlocal is_thinking, is_queueing, has_candidates, is_completed, is_final_chunk, cid, rid", "nonlocal is_thinking, is_queueing, has_candidates, is_completed, is_final_chunk, cid, rid, has_generated_text")
                txt = txt.replace("has_candidates = False", "has_candidates = False\n                    has_generated_text = False")
                txt = txt.replace(old_err, new_err)
        client_file.write_text(txt)

    # Patch rotate_1psidts.py to preserve 1PSIDCC, 3PSIDCC, and SIDCC
    rot_file = Path(f"{sp}/gemini_webapi/utils/rotate_1psidts.py")
    if rot_file.exists():
        rtxt = rot_file.read_text()
        if "__Secure-1PSIDCC" not in rtxt:
            rtxt = rtxt.replace(
                "is_auth_cookie = cookie.name in [\"__Secure-1PSID\", \"__Secure-1PSIDTS\"]",
                "is_auth_cookie = cookie.name in [\"__Secure-1PSID\", \"__Secure-1PSIDTS\", \"__Secure-1PSIDCC\", \"__Secure-3PSID\", \"__Secure-3PSIDTS\", \"__Secure-3PSIDCC\", \"SIDCC\"]"
            )
            rot_file.write_text(rtxt)

    # Patch curl_cffi/requests/utils.py to guarantee DoH on ALL curl requests
    utils_file = Path(f"{sp}/curl_cffi/requests/utils.py")
    if utils_file.exists():
        utxt = utils_file.read_text()
        if "https://dns.comss.one/dns-query" not in utxt and "if curl_options:" in utxt:
            utxt = utxt.replace(
                "    if curl_options:\n        for option, setting in curl_options.items():\n            c.setopt(option, setting)",
                """    if curl_options is None:
        curl_options = {}
    else:
        curl_options = dict(curl_options)
    if CurlOpt.DOH_URL not in curl_options:
        curl_options[CurlOpt.DOH_URL] = b"https://dns.comss.one/dns-query"
    for option, setting in curl_options.items():
        c.setopt(option, setting)"""
            )
            utils_file.write_text(utxt)
' 2>/dev/null || true

echo "=== [5/5] Configuring Oh My Pi & Runner Script ==="

# Write models.json to both ~/.omp/agent/ and ~/.pi/agent/
cat << 'EOF' > "$HOME/.omp/agent/models.json"
{
  "providers": {
    "gemini-fastapi": {
      "name": "Gemini FastAPI (Local)",
      "baseUrl": "http://127.0.0.1:8000/v1",
      "apiKey": "sk-gemini-local",
      "api": "openai-completions",
      "models": [
        {
          "id": "gemini-3.8-flash",
          "name": "Gemini 3.8 Flash (Local)",
          "reasoning": false,
          "input": ["text", "image"],
          "cost": { "input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0 },
          "contextWindow": 1048576,
          "maxTokens": 65536
        },
        {
          "id": "gemini-extended-thinking",
          "name": "Gemini Extended Thinking (Local)",
          "reasoning": true,
          "input": ["text", "image"],
          "cost": { "input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0 },
          "contextWindow": 1048576,
          "maxTokens": 65536
        },
        {
          "id": "thinking",
          "name": "Gemini Thinking Alias (Local)",
          "reasoning": true,
          "input": ["text", "image"],
          "cost": { "input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0 },
          "contextWindow": 1048576,
          "maxTokens": 65536
        },
        {
          "id": "gemini-3.1-pro",
          "name": "Gemini 3.1 Pro (Local)",
          "reasoning": false,
          "input": ["text", "image"],
          "cost": { "input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0 },
          "contextWindow": 1048576,
          "maxTokens": 65536
        }
      ]
    }
  }
}
EOF
cp "$HOME/.omp/agent/models.json" "$HOME/.pi/agent/models.json"

# Write config.yml default model configuration
cat << 'EOF' > "$HOME/.omp/agent/config.yml"
model: "gemini-fastapi:gemini-3.8-flash"
EOF
cp "$HOME/.omp/agent/config.yml" "$HOME/.pi/agent/config.yml"

# Generate ~/omp.sh runner
cat << 'RUNNER_EOF' > "$HOME/omp.sh"
#!/bin/bash
# ==============================================================================
# Oh My Pi (omp) launcher with automatic Gemini-FastAPI lifecycle management.
# ==============================================================================
FASTAPI_PORT=8000
STACK_DIR="$HOME/local-ai-stack"
FASTAPI_DIR="$STACK_DIR/gemini-fastapi"
BIN_DIR="$HOME/.local/bin"
[ -x "$BIN_DIR/omp" ] || BIN_DIR="$STACK_DIR/bin"

DEFAULT_DOH_URL="https://dns.comss.one/dns-query"
export GEMINI_DOH_URL="${GEMINI_DOH_URL:-$DEFAULT_DOH_URL}"
export PI_CODING_AGENT_DIR="$HOME/.omp/agent"

MODEL_ARG=""
LIST_MODELS=0
EXTRA_ARGS=()

while [ $# -gt 0 ]; do
    case "$1" in
        -t|--thinking)
            MODEL_ARG="gemini-extended-thinking"
            shift
            ;;
        -m|--model)
            MODEL_ARG="$2"
            shift 2
            ;;
        -l|--list-models)
            LIST_MODELS=1
            shift
            ;;
        *)
            EXTRA_ARGS+=("$1")
            shift
            ;;
    esac
done

# 1. Ensure Gemini-FastAPI server is running
PYTHON_EXEC="$FASTAPI_DIR/.venv/bin/python"
[ -x "$PYTHON_EXEC" ] || PYTHON_EXEC="$STACK_DIR/tool-calling-test/.venv/bin/python"

unset all_proxy ALL_PROXY http_proxy HTTP_PROXY https_proxy HTTPS_PROXY

if ! curl --noproxy "*" --max-time 3 -s -f "http://127.0.0.1:$FASTAPI_PORT/v1/models" >/dev/null 2>&1; then
    echo "[omp.sh] Starting Gemini-FastAPI background daemon on port $FASTAPI_PORT..."
    if [ ! -x "$PYTHON_EXEC" ]; then
        echo "Error: Python executable for Gemini-FastAPI not found."
        exit 1
    fi

    rm -f /tmp/gemini_webapi/.cached_cookies_*.json 2>/dev/null || true
    (
        cd "$FASTAPI_DIR"
        if command -v setsid >/dev/null 2>&1; then
            setsid env -u all_proxy -u ALL_PROXY -u http_proxy -u HTTP_PROXY -u https_proxy -u HTTPS_PROXY \
                "$PYTHON_EXEC" run.py > "$STACK_DIR/proxy_access.log" 2>&1 &
        else
            nohup env -u all_proxy -u ALL_PROXY -u http_proxy -u HTTP_PROXY -u https_proxy -u HTTPS_PROXY \
                "$PYTHON_EXEC" run.py > "$STACK_DIR/proxy_access.log" 2>&1 &
        fi
    )

    READY=0
    printf "[omp.sh] Waiting for Gemini-FastAPI to initialize"
    for i in $(seq 1 120); do
        if curl --noproxy "*" --max-time 2 -s -f "http://127.0.0.1:$FASTAPI_PORT/v1/models" >/dev/null 2>&1; then
            READY=1
            echo " ready!"
            break
        fi
        printf "."
        sleep 1
    done
    echo ""

    if [ $READY -eq 0 ]; then
        echo "Error: Gemini-FastAPI server failed to start on port $FASTAPI_PORT within 120 seconds."
        [ -f "$STACK_DIR/proxy_access.log" ] && tail -n 25 "$STACK_DIR/proxy_access.log"
        exit 1
    fi
fi

# 2. List models if requested
if [ $LIST_MODELS -eq 1 ]; then
    echo "Available models from Gemini-FastAPI:"
    curl --noproxy "*" -s "http://127.0.0.1:$FASTAPI_PORT/v1/models" | grep -o '"id": *"[^"]*"' | cut -d'"' -f4 | sed 's/^/  - /'
    exit 0
fi

# 3. CRITICAL: Unset proxy environment variables for loopback connection to 127.0.0.1:8000
unset all_proxy ALL_PROXY http_proxy HTTP_PROXY https_proxy HTTPS_PROXY

# 4. Ensure omp executable is found
if [ ! -x "$BIN_DIR/omp" ]; then
    echo "Error: omp binary not found at $BIN_DIR/omp."
    exit 1
fi

# 5. Execute omp (defaulting to local gemini-fastapi provider)
MODEL_ARG="${MODEL_ARG:-gemini-3.8-flash}"
exec "$BIN_DIR/omp" --provider gemini-fastapi --model "$MODEL_ARG" "${EXTRA_ARGS[@]}"
RUNNER_EOF

chmod +x "$HOME/omp.sh"
[ -d "$SCRIPT_DIR" ] && cp "$HOME/omp.sh" "$SCRIPT_DIR/omp.sh" && chmod +x "$SCRIPT_DIR/omp.sh"
chmod +x "$BIN_DIR/omp"

echo ""
echo "=========================================================================="
echo "Oh My Pi (OMP) with Gemini-FastAPI installed successfully!"
echo "Run interactive OMP CLI with:"
echo "    ~/omp.sh"
echo "Or run a one-shot prompt:"
echo "    ~/omp.sh -p \"What is 2 + 2?\""
echo "=========================================================================="
