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

check_trash_execution() {
    local cwd_phys
    cwd_phys="$(pwd -P 2>/dev/null || pwd)"
    case "$SCRIPT_DIR|$cwd_phys" in
        *Trash*|*/.local/share/Trash/*|*/.Trash/*)
            echo "❌ ERROR: Cannot run installation from inside Trash directory:"
            echo "   SCRIPT_DIR: $SCRIPT_DIR"
            echo "   CWD:        $cwd_phys"
            echo ""
            echo "   This happens if previous project directories were deleted via a file manager or trash"
            echo "   while your terminal was still navigated inside them."
            echo "   Please navigate to a clean folder outside of Trash, for example:"
            echo "       cd ~"
            echo "       tar -xzf oh-my-pi-offline.tar.gz"
            echo "       cd oh-my-pi-setup && ./install_oh_my_pi.sh"
            exit 1
            ;;
    esac
}
check_trash_execution

# Detect user's private Firefox DoH resolver (e.g. network.trr.uri / custom_uri)
detect_firefox_doh() {
    local dirs=(
        "$HOME/.mozilla/firefox"
        "$HOME/.var/app/org.mozilla.firefox/.mozilla/firefox"
        "$HOME/snap/firefox/common/.mozilla/firefox"
    )
    for d in "${dirs[@]}"; do
        [ -d "$d" ] || continue
        for pref in "$d"/*/prefs.js; do
            [ -f "$pref" ] || continue
            local uri
            uri=$(grep -E 'network\.trr\.(custom_)?uri' "$pref" 2>/dev/null | grep -o 'https://[^"]*' | head -n1 || true)
            if [ -n "$uri" ]; then
                case "$uri" in
                    *xbox-dns*|*1.1.1.1*|*cloudflare*)
                        continue
                        ;;
                    *)
                        echo "$uri"
                        return 0
                        ;;
                esac
            fi
        done
    done
    return 1
}

if [ -z "$CUSTOM_DOH_URL" ] && [ -z "$GEMINI_DOH_URL" ]; then
    DETECTED_DOH=$(detect_firefox_doh || true)
    if [ -n "$DETECTED_DOH" ]; then
        CUSTOM_DOH_URL="$DETECTED_DOH"
    else
        CUSTOM_DOH_URL="https://dns.bezmezhau.com/dns-query"
    fi
fi
DEFAULT_DOH_URL="${CUSTOM_DOH_URL:-https://dns.bezmezhau.com/dns-query}"
export GEMINI_DOH_URL="${GEMINI_DOH_URL:-$DEFAULT_DOH_URL}"
export CUSTOM_DOH_URL="$GEMINI_DOH_URL"

stop_running_stack() {
    echo "=== Checking AI Stack Backend (Port 8000) ==="

    # If an existing stack is already running healthy Gemini-FastAPI on port 8000, preserve it!
    if curl --noproxy "*" --max-time 2 -s -f "http://127.0.0.1:8000/v1/models" >/dev/null 2>&1; then
        local probe_resp
        probe_resp=$(curl --noproxy "*" --max-time 4 -s -X POST "http://127.0.0.1:8000/v1/chat/completions" \
            -H "Content-Type: application/json" \
            -d '{"model": "gemini-flash", "messages": [{"role": "user", "content": "ping"}], "max_tokens": 1}' 2>/dev/null || true)
        if echo "$probe_resp" | grep -q '"choices"'; then
            echo "✓ Authenticated Gemini-FastAPI backend detected on port 8000. Preserving active service and rotated cookies."
            return 0
        else
            echo "⚠️  Gemini-FastAPI on port 8000 is unauthenticated or in Guest mode. Stopping instance to allow fresh browser cookie extraction..."
        fi
    fi

    local ports=(8000)
    local found_occupying=0
    local announced_pids=""

    # 1. Inspect port 8000 directly
    for port in "${ports[@]}"; do
        local pids=""
        if command -v lsof >/dev/null 2>&1; then
            pids=$(lsof -ti:"${port}" 2>/dev/null || true)
        elif command -v fuser >/dev/null 2>&1; then
            pids=$(fuser "${port}/tcp" 2>/dev/null || true)
        fi
        if [ -n "$pids" ]; then
            for pid in $pids; do
                if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
                    local cmd=""
                    if [ -r "/proc/$pid/cmdline" ]; then
                        cmd=$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | head -c 80 || true)
                    fi
                    [ -z "$cmd" ] && cmd=$(ps -p "$pid" -o comm= 2>/dev/null || echo "process")
                    echo "⚠️  Found unresponsive process occupying required port $port: PID $pid ($cmd)"
                    echo "   -> Terminating PID $pid to allow stack backend to bind to port $port..."
                    found_occupying=1
                    announced_pids="$announced_pids $pid"
                fi
            done
        fi
    done

    # 2. Check stale gemini-fastapi run.py processes
    local pattern_pids
    pattern_pids=$(pgrep -f "gemini-fastapi.*run\.py" 2>/dev/null || true)
    if [ -n "$pattern_pids" ]; then
        for pid in $pattern_pids; do
            case " $announced_pids " in
                *" $pid "*) ;; # already announced
                *)
                    if kill -0 "$pid" 2>/dev/null; then
                        local cmd=""
                        if [ -r "/proc/$pid/cmdline" ]; then
                            cmd=$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | head -c 80 || true)
                        fi
                        [ -z "$cmd" ] && cmd=$(ps -p "$pid" -o comm= 2>/dev/null || echo "process")
                        echo "⚠️  Found stale gemini-fastapi instance: PID $pid ($cmd)"
                        echo "   -> Terminating PID $pid..."
                        found_occupying=1
                        announced_pids="$announced_pids $pid"
                    fi
                    ;;
            esac
        done
    fi

    # 3. Stop standalone gemini-fastapi.service if present (do not stop open-webui.service)
    if command -v systemctl >/dev/null 2>&1; then
        if systemctl --user is-active gemini-fastapi.service >/dev/null 2>&1; then
            echo "⚠️  Found active standalone gemini-fastapi.service"
            echo "   -> Stopping gemini-fastapi.service..."
            systemctl --user stop gemini-fastapi.service 2>/dev/null || true
            found_occupying=1
        fi
    fi

    if [ "$found_occupying" -eq 0 ]; then
        echo "✓ Port 8000 is free."
        return 0
    fi

    # 4. Terminate stale fastapi with SIGTERM
    pkill -TERM -f "gemini-fastapi.*run\.py" 2>/dev/null || true

    for port in "${ports[@]}"; do
        if command -v fuser >/dev/null 2>&1; then
            fuser -k -TERM "${port}/tcp" >/dev/null 2>&1 || true
        fi
        if command -v lsof >/dev/null 2>&1; then
            local pids
            pids=$(lsof -ti:"${port}" 2>/dev/null || true)
            if [ -n "$pids" ]; then
                kill -TERM $pids >/dev/null 2>&1 || true
            fi
        fi
    done

    local wait_count=0
    while [ $wait_count -lt 5 ]; do
        if pgrep -f "gemini-fastapi.*run\.py" >/dev/null 2>&1; then
            sleep 1
            wait_count=$((wait_count + 1))
        else
            break
        fi
    done

    # 5. Force kill fallback with SIGKILL if still holding ports or running
    for port in "${ports[@]}"; do
        if command -v fuser >/dev/null 2>&1; then
            fuser -k -KILL "${port}/tcp" >/dev/null 2>&1 || true
        fi
        if command -v lsof >/dev/null 2>&1; then
            local pids
            pids=$(lsof -ti:"${port}" 2>/dev/null || true)
            if [ -n "$pids" ]; then
                kill -9 $pids >/dev/null 2>&1 || true
            fi
        fi
    done
    pkill -9 -f "gemini-fastapi.*run\.py" 2>/dev/null || true
    sleep 1

    echo "✓ Conflicting processes terminated. Ports (${ports[*]}) are now free."
}

stop_running_stack

echo "=== [1/5] Checking Environment & Dependencies ==="

# Check Python 3 (>= 3.10 baseline)
PY_EXEC=""
for p in python3.12 python3.11 python3.10 python3; do
    if command -v "$p" &>/dev/null; then
        if "$p" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 10) else 1)' 2>/dev/null; then
            PY_EXEC="$(command -v "$p")"
            break
        fi
    fi
done

if [ -z "$PY_EXEC" ]; then
    echo "Error: Python >= 3.10 is required (baseline back-compat). Please install python3 (>= 3.10)."
    exit 1
fi

PY_VER=$("$PY_EXEC" -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')
echo "Detected Python $PY_VER ($PY_EXEC)"

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
        echo "Creating dedicated virtual environment in $FASTAPI_DIR/.venv using $PY_EXEC..."
        "$PY_EXEC" -m venv "$FASTAPI_DIR/.venv"
    fi
    PYTHON_EXEC="$FASTAPI_DIR/.venv/bin/python"
    PIP_EXEC="$FASTAPI_DIR/.venv/bin/pip"
    
    echo "Installing required Python packages..."
    if [ -d "$SCRIPT_DIR/wheels" ]; then
        "$PIP_EXEC" install --no-index --find-links="$SCRIPT_DIR/wheels" \
            fastapi "uvicorn[standard]" curl_cffi "gemini-webapi>=2.1.1" rookiepy lmdb pydantic pydantic-settings pyyaml loguru orjson httptools 2>/dev/null || true
    fi
    "$PIP_EXEC" install --upgrade pip setuptools wheel 2>/dev/null || true
    "$PIP_EXEC" install fastapi "uvicorn[standard]" curl_cffi "gemini-webapi>=2.1.1" rookiepy lmdb pydantic pydantic-settings pyyaml loguru orjson httptools 2>/dev/null || true
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
            doh_endpoint = os.environ.get("GEMINI_DOH_URL", "https://dns.bezmezhau.com/dns-query").encode()
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
if pool_file.exists() and "reload_cookies_from_browser" not in pool_file.read_text():
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
                candidate_resolvers = []
                env_doh = os.environ.get("GEMINI_DOH_URL")
                if env_doh:
                    candidate_resolvers.append(env_doh)
                for r in ["https://dns.bezmezhau.com/dns-query", "https://dns.comss.one/dns-query"]:
                    if r not in candidate_resolvers:
                        candidate_resolvers.append(r)

                initialized = False
                for b_name in ["firefox", "chrome", "chromium", "brave"]:
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


    if "_throttle_request" not in ctext:
        rate_code = """import asyncio
import time
_rate_limit_lock = asyncio.Lock()
_last_request_time = 0.0
_last_response_time = 0.0
MIN_REQUEST_INTERVAL = 2.0  # Impose max request frequency: at most 1 request per 2 seconds

async def _throttle_request():
    global _last_request_time, _last_response_time
    async with _rate_limit_lock:
        now = time.monotonic()
        target_time = max(_last_request_time, _last_response_time) + MIN_REQUEST_INTERVAL
        if now < target_time:
            wait_sec = target_time - now
            logger.info(f"Rate limiting active: waiting {wait_sec:.2f}s before sending to Gemini...")
            await asyncio.sleep(wait_sec)
        _last_request_time = time.monotonic()

def _mark_response_completed():
    global _last_response_time
    _last_response_time = time.monotonic()
"""
        doc_target = "\"\"\"Send text to Gemini, splitting or converting to attachment if too long.\"\"\""
        ctext = ctext.replace(doc_target, doc_target + "\n    await _throttle_request()")

    if "not available for use" not in ctext and "def _is_auth_error" in ctext:
        ctext = ctext.replace(
            "\"accounts.google.com\",\n        )",
            "\"accounts.google.com\",\n            \"not available for use\",\n            \"is not available for use\",\n            \"guest session\",\n            \"guest mode\",\n        )"
        )
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
            doh_ep = os.environ.get("GEMINI_DOH_URL", "https://dns.bezmezhau.com/dns-query")
            if isinstance(doh_ep, str):
                doh_ep = doh_ep.encode()
            curl_opts[CurlOpt.DOH_URL] = doh_ep
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
                "self.kwargs = kwargs\n        self.curl_options = kwargs.get(\"curl_options\")\n        if self.curl_options is None:\n            try:\n                from curl_cffi import CurlOpt\n                doh_ep = os.environ.get(\"GEMINI_DOH_URL\", \"https://dns.bezmezhau.com/dns-query\").encode()\n                self.curl_options = {CurlOpt.DOH_URL: doh_ep}\n            except Exception:\n                pass"
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
        if "dns.bezmezhau.com" not in utxt and "if curl_options:" in utxt:
            utxt = utxt.replace(
                "    if curl_options:\n        for option, setting in curl_options.items():\n            c.setopt(option, setting)",
                """    if curl_options is None:
        curl_options = {}
    else:
        curl_options = dict(curl_options)
    if CurlOpt.DOH_URL not in curl_options:
        doh_ep = os.environ.get("GEMINI_DOH_URL", "https://dns.bezmezhau.com/dns-query").encode()
        curl_options[CurlOpt.DOH_URL] = doh_ep
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
          "id": "gemini-flash",
          "name": "Gemini Flash (Local)",
          "reasoning": false,
          "input": ["text", "image"],
          "cost": { "input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0 },
          "contextWindow": 1048576,
          "maxTokens": 65536
        },
        {
          "id": "gemini-pro",
          "name": "Gemini Pro (Local)",
          "reasoning": true,
          "input": ["text", "image"],
          "cost": { "input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0 },
          "contextWindow": 1048576,
          "maxTokens": 65536
        },
        {
          "id": "gemini-flash-lite",
          "name": "Gemini Flash-Lite (Local)",
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
model: "gemini-fastapi:gemini-flash"
EOF
# Setup local DNS hosts spoofing
SPOOF_DIR="$HOME/.local/share/gemini-spoof"
HOSTS_FILE="$SPOOF_DIR/hosts"
if [ ! -f "$HOSTS_FILE" ] || ! grep -q "91.108.243.78" "$HOSTS_FILE" 2>/dev/null; then
    mkdir -p "$SPOOF_DIR"

    DYNAMIC_IP=""
    if command -v curl >/dev/null 2>&1 && [ -n "$GEMINI_DOH_URL" ]; then
        DYNAMIC_IP=$(curl -s -v --max-time 4 --doh-url "$GEMINI_DOH_URL" "https://gemini.google.com" 2>&1 | grep "Connected to gemini.google.com" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -n1 || true)
    fi
    PRIMARY_SPOOF_IP="${DYNAMIC_IP:-91.108.243.78}"

    cat << EOF_SPOOF > "$HOSTS_FILE"
127.0.0.1 localhost

# Google AI Services (unblocked SNI proxies)
$PRIMARY_SPOOF_IP gemini.google.com
91.108.243.78 gemini.google.com
45.88.174.254 gemini.google.com
$PRIMARY_SPOOF_IP aistudio.google.com
91.108.243.78 aistudio.google.com
45.88.174.254 aistudio.google.com
$PRIMARY_SPOOF_IP generativelanguage.googleapis.com
91.108.243.78 generativelanguage.googleapis.com
45.88.174.254 generativelanguage.googleapis.com
$PRIMARY_SPOOF_IP aitestkitchen.withgoogle.com
91.108.243.78 aitestkitchen.withgoogle.com
45.88.174.254 aitestkitchen.withgoogle.com
$PRIMARY_SPOOF_IP aisandbox-pa.googleapis.com
91.108.243.78 aisandbox-pa.googleapis.com
45.88.174.254 aisandbox-pa.googleapis.com
$PRIMARY_SPOOF_IP webchannel-alkalimakersuite-pa.clients6.google.com
91.108.243.78 webchannel-alkalimakersuite-pa.clients6.google.com
45.88.174.254 webchannel-alkalimakersuite-pa.clients6.google.com
$PRIMARY_SPOOF_IP alkalimakersuite-pa.clients6.google.com
91.108.243.78 alkalimakersuite-pa.clients6.google.com
45.88.174.254 alkalimakersuite-pa.clients6.google.com
$PRIMARY_SPOOF_IP assistant-s3-pa.googleapis.com
91.108.243.78 assistant-s3-pa.googleapis.com
45.88.174.254 assistant-s3-pa.googleapis.com
$PRIMARY_SPOOF_IP proactivebackend-pa.googleapis.com
91.108.243.78 proactivebackend-pa.googleapis.com
45.88.174.254 proactivebackend-pa.googleapis.com
$PRIMARY_SPOOF_IP robinfrontend-pa.googleapis.com
91.108.243.78 robinfrontend-pa.googleapis.com
45.88.174.254 robinfrontend-pa.googleapis.com
64.233.163.94 o.pki.goog
$PRIMARY_SPOOF_IP labs.google
91.108.243.78 labs.google
45.88.174.254 labs.google
$PRIMARY_SPOOF_IP notebooklm.google.com
91.108.243.78 notebooklm.google.com
45.88.174.254 notebooklm.google.com
$PRIMARY_SPOOF_IP jules.google.com
91.108.243.78 jules.google.com
45.88.174.254 jules.google.com
$PRIMARY_SPOOF_IP stitch.withgoogle.com
91.108.243.78 stitch.withgoogle.com
45.88.174.254 stitch.withgoogle.com

# Google Core & Auth
142.251.1.84 accounts.google.com
$PRIMARY_SPOOF_IP content-push.googleapis.com
91.108.243.78 content-push.googleapis.com
45.88.174.254 content-push.googleapis.com
142.251.157.119 www.google.com
142.251.1.139 google.com

# OpenAI
45.155.204.190 chatgpt.com
45.155.204.190 ab.chatgpt.com
45.155.204.190 auth.openai.com
45.155.204.190 auth0.openai.com
45.155.204.190 platform.openai.com
45.155.204.190 cdn.oaistatic.com
45.155.204.190 files.oaiusercontent.com
45.155.204.190 cdn.auth0.com
45.155.204.190 tcr9i.chat.openai.com
45.155.204.190 webrtc.chatgpt.com
45.155.204.190 android.chat.openai.com
45.155.204.190 api.openai.com
45.155.204.190 operator.chatgpt.com
45.155.204.190 sora.chatgpt.com
45.155.204.190 sora.com
45.155.204.190 videos.openai.com
45.155.204.190 ios.chat.openai.com

# Microsoft
45.155.204.190 copilot.microsoft.com
45.155.204.190 sydney.bing.com
45.155.204.190 edgeservices.bing.com
45.155.204.190 rewards.bing.com

# GitHub Copilot
144.31.14.104 api.github.com
144.31.14.104 api.individual.githubcopilot.com
144.31.14.104 proxy.individual.githubcopilot.com

# Grok
45.155.204.190 grok.com
45.155.204.190 accounts.x.ai
45.155.204.190 assets.grok.com

# Claude
45.155.204.190 claude.ai
45.155.204.190 console.anthropic.com
45.155.204.190 api.anthropic.com
EOF_SPOOF
fi

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

# Detect user's private Firefox DoH resolver (e.g. network.trr.uri / custom_uri)
detect_firefox_doh() {
    local dirs=(
        "$HOME/.mozilla/firefox"
        "$HOME/.var/app/org.mozilla.firefox/.mozilla/firefox"
        "$HOME/snap/firefox/common/.mozilla/firefox"
    )
    for d in "${dirs[@]}"; do
        [ -d "$d" ] || continue
        for pref in "$d"/*/prefs.js; do
            [ -f "$pref" ] || continue
            local uri
            uri=$(grep -E 'network\.trr\.(custom_)?uri' "$pref" 2>/dev/null | grep -o 'https://[^"]*' | head -n1 || true)
            if [ -n "$uri" ]; then
                case "$uri" in
                    *xbox-dns*|*1.1.1.1*|*cloudflare*)
                        continue
                        ;;
                    *)
                        echo "$uri"
                        return 0
                        ;;
                esac
            fi
        done
    done
    return 1
}

if [ -z "$CUSTOM_DOH_URL" ] && [ -z "$GEMINI_DOH_URL" ]; then
    DETECTED_DOH=$(detect_firefox_doh || true)
    if [ -n "$DETECTED_DOH" ]; then
        CUSTOM_DOH_URL="$DETECTED_DOH"
    else
        CUSTOM_DOH_URL="https://dns.bezmezhau.com/dns-query"
    fi
fi
DEFAULT_DOH_URL="${CUSTOM_DOH_URL:-https://dns.bezmezhau.com/dns-query}"
export GEMINI_DOH_URL="${GEMINI_DOH_URL:-$DEFAULT_DOH_URL}"
export CUSTOM_DOH_URL="$GEMINI_DOH_URL"
export PI_CODING_AGENT_DIR="$HOME/.omp/agent"

MODEL_ARG=""
LIST_MODELS=0
EXTRA_ARGS=()

while [ $# -gt 0 ]; do
    case "$1" in
        -t|--thinking)
            MODEL_ARG="gemini-pro"
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

# 1. Ensure local hosts file and bwrap containerization for DNS spoofing
SPOOF_DIR="$HOME/.local/share/gemini-spoof"
HOSTS_FILE="$SPOOF_DIR/hosts"
if [ ! -f "$HOSTS_FILE" ] || ! grep -q "91.108.243.78" "$HOSTS_FILE" 2>/dev/null; then
    mkdir -p "$SPOOF_DIR"

    DYNAMIC_IP=""
    if command -v curl >/dev/null 2>&1 && [ -n "$GEMINI_DOH_URL" ]; then
        DYNAMIC_IP=$(curl -s -v --max-time 4 --doh-url "$GEMINI_DOH_URL" "https://gemini.google.com" 2>&1 | grep "Connected to gemini.google.com" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -n1 || true)
    fi
    PRIMARY_SPOOF_IP="${DYNAMIC_IP:-91.108.243.78}"

    cat << EOF_SPOOF > "$HOSTS_FILE"
127.0.0.1 localhost

# Google AI Services (unblocked SNI proxies)
$PRIMARY_SPOOF_IP gemini.google.com
91.108.243.78 gemini.google.com
45.88.174.254 gemini.google.com
$PRIMARY_SPOOF_IP aistudio.google.com
91.108.243.78 aistudio.google.com
45.88.174.254 aistudio.google.com
$PRIMARY_SPOOF_IP generativelanguage.googleapis.com
91.108.243.78 generativelanguage.googleapis.com
45.88.174.254 generativelanguage.googleapis.com
$PRIMARY_SPOOF_IP aitestkitchen.withgoogle.com
91.108.243.78 aitestkitchen.withgoogle.com
45.88.174.254 aitestkitchen.withgoogle.com
$PRIMARY_SPOOF_IP aisandbox-pa.googleapis.com
91.108.243.78 aisandbox-pa.googleapis.com
45.88.174.254 aisandbox-pa.googleapis.com
$PRIMARY_SPOOF_IP webchannel-alkalimakersuite-pa.clients6.google.com
91.108.243.78 webchannel-alkalimakersuite-pa.clients6.google.com
45.88.174.254 webchannel-alkalimakersuite-pa.clients6.google.com
$PRIMARY_SPOOF_IP alkalimakersuite-pa.clients6.google.com
91.108.243.78 alkalimakersuite-pa.clients6.google.com
45.88.174.254 alkalimakersuite-pa.clients6.google.com
$PRIMARY_SPOOF_IP assistant-s3-pa.googleapis.com
91.108.243.78 assistant-s3-pa.googleapis.com
45.88.174.254 assistant-s3-pa.googleapis.com
$PRIMARY_SPOOF_IP proactivebackend-pa.googleapis.com
91.108.243.78 proactivebackend-pa.googleapis.com
45.88.174.254 proactivebackend-pa.googleapis.com
$PRIMARY_SPOOF_IP robinfrontend-pa.googleapis.com
91.108.243.78 robinfrontend-pa.googleapis.com
45.88.174.254 robinfrontend-pa.googleapis.com
64.233.163.94 o.pki.goog
$PRIMARY_SPOOF_IP labs.google
91.108.243.78 labs.google
45.88.174.254 labs.google
$PRIMARY_SPOOF_IP notebooklm.google.com
91.108.243.78 notebooklm.google.com
45.88.174.254 notebooklm.google.com
$PRIMARY_SPOOF_IP jules.google.com
91.108.243.78 jules.google.com
45.88.174.254 jules.google.com
$PRIMARY_SPOOF_IP stitch.withgoogle.com
91.108.243.78 stitch.withgoogle.com
45.88.174.254 stitch.withgoogle.com

# Google Core & Auth
142.251.1.84 accounts.google.com
$PRIMARY_SPOOF_IP content-push.googleapis.com
91.108.243.78 content-push.googleapis.com
45.88.174.254 content-push.googleapis.com
142.251.157.119 www.google.com
142.251.1.139 google.com

# OpenAI
45.155.204.190 chatgpt.com
45.155.204.190 ab.chatgpt.com
45.155.204.190 auth.openai.com
45.155.204.190 auth0.openai.com
45.155.204.190 platform.openai.com
45.155.204.190 cdn.oaistatic.com
45.155.204.190 files.oaiusercontent.com
45.155.204.190 cdn.auth0.com
45.155.204.190 tcr9i.chat.openai.com
45.155.204.190 webrtc.chatgpt.com
45.155.204.190 android.chat.openai.com
45.155.204.190 api.openai.com
45.155.204.190 operator.chatgpt.com
45.155.204.190 sora.chatgpt.com
45.155.204.190 sora.com
45.155.204.190 videos.openai.com
45.155.204.190 ios.chat.openai.com

# Microsoft
45.155.204.190 copilot.microsoft.com
45.155.204.190 sydney.bing.com
45.155.204.190 edgeservices.bing.com
45.155.204.190 rewards.bing.com

# GitHub Copilot
144.31.14.104 api.github.com
144.31.14.104 api.individual.githubcopilot.com
144.31.14.104 proxy.individual.githubcopilot.com

# Grok
45.155.204.190 grok.com
45.155.204.190 accounts.x.ai
45.155.204.190 assets.grok.com

# Claude
45.155.204.190 claude.ai
45.155.204.190 console.anthropic.com
45.155.204.190 api.anthropic.com
EOF_SPOOF
fi

BWRAP_CMD=""
if [ -f "$HOSTS_FILE" ] && command -v bwrap >/dev/null 2>&1; then
    BWRAP_CMD="bwrap --dev-bind / / --ro-bind $HOSTS_FILE /etc/hosts"
fi

# 2. Ensure Gemini-FastAPI server is running
PYTHON_EXEC="$FASTAPI_DIR/.venv/bin/python"
[ -x "$PYTHON_EXEC" ] || PYTHON_EXEC="$STACK_DIR/tool-calling-test/.venv/bin/python"

unset all_proxy ALL_PROXY http_proxy HTTP_PROXY https_proxy HTTPS_PROXY

check_proxy_auth() {
    if ! curl --noproxy "*" --max-time 2 -s -f "http://127.0.0.1:$FASTAPI_PORT/v1/models" >/dev/null 2>&1; then
        return 1
    fi
    local probe
    probe=$(curl --noproxy "*" --max-time 4 -s -X POST "http://127.0.0.1:$FASTAPI_PORT/v1/chat/completions" \
        -H "Content-Type: application/json" \
        -d '{"model": "gemini-flash", "messages": [{"role": "user", "content": "ping"}], "max_tokens": 1}' 2>/dev/null || true)
    if echo "$probe" | grep -q '"choices"'; then
        return 0
    fi
    return 1
}

if ! check_proxy_auth; then
    # Check if port 8000 is occupied by an unresponsive or conflicting process
    local_pids=""
    if command -v lsof >/dev/null 2>&1; then
        local_pids=$(lsof -ti:"$FASTAPI_PORT" 2>/dev/null || true)
    elif command -v fuser >/dev/null 2>&1; then
        local_pids=$(fuser "${FASTAPI_PORT}/tcp" 2>/dev/null || true)
    fi
    if [ -n "$local_pids" ]; then
        for pid in $local_pids; do
            if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
                cmd=""
                if [ -r "/proc/$pid/cmdline" ]; then
                    cmd=$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | head -c 80 || true)
                fi
                [ -z "$cmd" ] && cmd=$(ps -p "$pid" -o comm= 2>/dev/null || echo "process")
                echo "[omp.sh] ⚠️  Found process occupying required port $FASTAPI_PORT: PID $pid ($cmd)"
                echo "[omp.sh]    -> Terminating PID $pid to allow Gemini-FastAPI to bind to port $FASTAPI_PORT..."
                kill -TERM "$pid" 2>/dev/null || true
                sleep 1
                if kill -0 "$pid" 2>/dev/null; then
                    kill -9 "$pid" 2>/dev/null || true
                fi
            fi
        done
    fi

    echo "[omp.sh] Starting Gemini-FastAPI background daemon on port $FASTAPI_PORT..."
    if [ -n "$BWRAP_CMD" ]; then
        echo "[omp.sh] Applying local hosts DNS resolution via bwrap: $HOSTS_FILE"
    fi
    if [ ! -x "$PYTHON_EXEC" ]; then
        echo "Error: Python executable for Gemini-FastAPI not found."
        exit 1
    fi
    (
        cd "$FASTAPI_DIR"
        if [ -n "$BWRAP_CMD" ]; then
            if command -v setsid >/dev/null 2>&1; then
                setsid env -u all_proxy -u ALL_PROXY -u http_proxy -u HTTP_PROXY -u https_proxy -u HTTPS_PROXY \
                    $BWRAP_CMD "$PYTHON_EXEC" run.py > "$STACK_DIR/proxy_access.log" 2>&1 &
            else
                nohup env -u all_proxy -u ALL_PROXY -u http_proxy -u HTTP_PROXY -u https_proxy -u HTTPS_PROXY \
                    $BWRAP_CMD "$PYTHON_EXEC" run.py > "$STACK_DIR/proxy_access.log" 2>&1 &
            fi
        else
            if command -v setsid >/dev/null 2>&1; then
                setsid env -u all_proxy -u ALL_PROXY -u http_proxy -u HTTP_PROXY -u https_proxy -u HTTPS_PROXY \
                    "$PYTHON_EXEC" run.py > "$STACK_DIR/proxy_access.log" 2>&1 &
            else
                nohup env -u all_proxy -u ALL_PROXY -u http_proxy -u HTTP_PROXY -u https_proxy -u HTTPS_PROXY \
                    "$PYTHON_EXEC" run.py > "$STACK_DIR/proxy_access.log" 2>&1 &
            fi
        fi
    )

    READY=0
    printf "[omp.sh] Waiting for Gemini-FastAPI to initialize"
    for i in $(seq 1 120); do
        if check_proxy_auth; then
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
MODEL_ARG="${MODEL_ARG:-gemini-flash}"
if [ -n "$BWRAP_CMD" ]; then
    exec $BWRAP_CMD "$BIN_DIR/omp" --provider gemini-fastapi --model "$MODEL_ARG" "${EXTRA_ARGS[@]}"
else
    exec "$BIN_DIR/omp" --provider gemini-fastapi --model "$MODEL_ARG" "${EXTRA_ARGS[@]}"
fi
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
