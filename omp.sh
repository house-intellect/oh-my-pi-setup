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
