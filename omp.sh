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
    # 1. Quick check if port is serving HTTP /v1/models
    if ! curl --noproxy "*" --max-time 3 -s -f "http://127.0.0.1:$FASTAPI_PORT/v1/models" >/dev/null 2>&1; then
        return 2  # Server not running / port closed
    fi

    # 2. Probe gemini-flash directly with generous 15s timeout
    local resp http_code body
    resp=$(curl --noproxy "*" --max-time 15 -s -w "\nHTTP_STATUS:%{http_code}" -X POST "http://127.0.0.1:$FASTAPI_PORT/v1/chat/completions" \
        -H "Content-Type: application/json" \
        -d '{"model": "gemini-flash", "messages": [{"role": "user", "content": "ping"}], "max_tokens": 1}' 2>/dev/null || true)
    http_code=$(echo "$resp" | grep "HTTP_STATUS:" | cut -d':' -f2)
    body=$(echo "$resp" | sed '/HTTP_STATUS:/d')

    if echo "$body" | grep -q '"choices"'; then
        return 0  # Authenticated and healthy
    fi

    # Check if timeout (000 or empty) - server is alive but network or model slow/warming up. Preserve instance!
    if [ -z "$http_code" ] || [ "$http_code" = "000" ]; then
        echo "[omp.sh] ⚠️  Probe to gemini-flash timed out, but Gemini-FastAPI is active on port $FASTAPI_PORT. Preserving instance."
        return 0
    fi

    # Explicit auth/guest/unavailable error
    if [ "$http_code" = "401" ] || [ "$http_code" = "403" ] || \
       echo "$body" | grep -iqE '("status":\s*(401|403|1016|1002)|unauthenticated|guest mode|guest session|not available for use|is not available for use|autherror|login_required)'; then
        echo "[omp.sh] ⚠️  Gemini-FastAPI on port $FASTAPI_PORT returned unauthenticated / Guest mode error (HTTP $http_code)."
        return 1  # Unauthenticated
    fi

    # Any other status: if /v1/models is alive, do not kill blindly
    return 0
}

check_proxy_auth
auth_status=$?

if [ $auth_status -eq 0 ]; then
    # Server is active, authenticated, and healthy. Do not restart or kill.
    :
else
    # If auth_status is 1 (confirmed unauthenticated/guest error):
    # Only then terminate the dead/unauthenticated instance so a new one can be started.
    if [ $auth_status -eq 1 ]; then
        local_pids=""
        if command -v lsof >/dev/null 2>&1; then
            local_pids=$(lsof -ti:"$FASTAPI_PORT" 2>/dev/null || true)
        elif command -v fuser >/dev/null 2>&1; then
            local_pids=$(fuser "${FASTAPI_PORT}/tcp" 2>/dev/null || true)
        fi
        if [ -n "$local_pids" ]; then
            for pid in $local_pids; do
                if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
                    echo "[omp.sh] Terminating unauthenticated Gemini-FastAPI instance: PID $pid..."
                    kill -TERM "$pid" 2>/dev/null || true
                    sleep 1
                    if kill -0 "$pid" 2>/dev/null; then
                        kill -9 "$pid" 2>/dev/null || true
                    fi
                fi
            done
        fi
    fi

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
    for i in $(seq 1 60); do
        if curl --noproxy "*" --max-time 3 -s -f "http://127.0.0.1:$FASTAPI_PORT/v1/models" >/dev/null 2>&1; then
            READY=1
            echo " ready!"
            break
        fi
        printf "."
        sleep 1
    done
    echo ""

    if [ $READY -eq 0 ]; then
        echo "Error: Gemini-FastAPI server failed to start on port $FASTAPI_PORT within 60 seconds."
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
