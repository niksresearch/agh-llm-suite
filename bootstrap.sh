#!/usr/bin/env bash
set -euo pipefail

# bootstrap.sh — AGH LLM Suite (multi-pod / envPod architecture)
# Called by llm-setup-bundle.sh after sourcing the bundle env and setting all vars.
# envPod is already installed on the host (done by startup.sh prereq phase).
#
# Required env vars (set by llm-setup-bundle.sh):
#   BUNDLE        = 1 | 2 | 3
#   POD_INDEX     = 1..10  (default 1)
#   MODEL_TAG     = full Ollama pull string (e.g. hf.co/unsloth/...)
#   MODEL_SHORT   = display name (e.g. "Gemma 4 31B")
#   OLLAMA_NUM_CTX
#   RATE_LIMIT_RPM
#   LLM_API_KEY   (may be empty — generated if so)
#   ADMIN_TOKEN   (may be empty — generated if so, Bundle 2+)
#   WEBHOOK_URL   (optional)
#   TUNNEL_TOKEN  (optional)
#   VD_PASS       (Bundle 3, default "changeme")
#   SCRIPT_DIR    = path to llm-setup/ dir

SCRIPT_DIR="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"

# ---------------------------------------------------------------------------
# Error handler — posts webhook on failure then exits 1
# ---------------------------------------------------------------------------
_fail() {
  echo "ERROR: $1" >&2
  if [ -n "${WEBHOOK_URL:-}" ]; then
    curl -sf -X POST "$WEBHOOK_URL" \
      -H "Content-Type: application/json" \
      -d "{\"status\":\"failure\",\"error\":\"$1\",\"pod\":${POD_INDEX},\"bundle\":${BUNDLE},\"model\":\"${MODEL_TAG:-unknown}\"}" \
      || true
  fi
  exit 1
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {

  # ---- Step 1: Compute ports + dirs -----------------------------------------
  POD_INDEX="${POD_INDEX:-1}"
  POD_NAME="agh-llm-pod-${POD_INDEX}"
  OLLAMA_PORT=$((11430 + POD_INDEX))
  GATEWAY_PORT=$((8000  + POD_INDEX))
  VNC_PORT=$((5900  + POD_INDEX))
  WS_PORT=$((6080  + POD_INDEX))
  DATA_DIR="/data/${POD_NAME}"
  LOG_DIR="/var/log/${POD_NAME}"
  mkdir -p "$LOG_DIR"
  echo "Pod ${POD_INDEX}: Ollama=${OLLAMA_PORT} Gateway=${GATEWAY_PORT}"

  # ---- Step 2: Launch envPod ------------------------------------------------
  if ps aux | grep -v grep | grep -q "${POD_NAME}"; then
    echo "Pod ${POD_NAME} already running — reusing."
    POD_PID=$(ps aux | grep "sleep infinity" | grep -v grep | awk '{print $2}' | head -1)
  else
    envpod run --name "$POD_NAME" --gpu -- sleep infinity &
    POD_PID=""
    for i in $(seq 1 20); do
      POD_PID=$(ps aux | grep "sleep infinity" | grep -v grep | awk '{print $2}' | tail -1)
      [ -n "$POD_PID" ] && break
      sleep 3
    done
  fi
  [[ -n "${POD_PID:-}" ]] || _fail "Could not find PID for pod ${POD_NAME}"
  echo "Pod PID: $POD_PID"

  # ---- Step 3: Install deps inside pod --------------------------------------
  echo "Installing common dependencies inside pod..."
  nsenter -t "$POD_PID" -m -- bash -c "
    apt-get update -qq
    apt-get install -y --no-install-recommends curl python3 python3-pip python3-venv
  " || _fail "Dependency install failed"

  # ---- Step 4: Install Ollama inside pod (idempotent) -----------------------
  echo "Checking / installing Ollama inside pod..."
  nsenter -t "$POD_PID" -m -- bash -c "
    command -v ollama >/dev/null 2>&1 && exit 0
    curl -fsSL https://ollama.ai/install.sh | sh
  " || _fail "Ollama install failed"

  # ---- Step 5: Python venv + gateway deps inside pod ------------------------
  echo "Creating Python venv and installing gateway dependencies..."
  VENV="/opt/llm-env-pod-${POD_INDEX}"
  nsenter -t "$POD_PID" -m -- bash -c "
    python3 -m venv ${VENV}
    ${VENV}/bin/pip install --quiet \
      fastapi==0.138.2 uvicorn[standard]==0.49.0 httpx==0.28.1 pydantic==2.13.4
  " || _fail "Python venv setup failed"

  # ---- Step 6: Copy gateway source into pod ---------------------------------
  echo "Copying gateway source into pod..."
  GW_DIR="/opt/llm-gateway-pod-${POD_INDEX}"
  nsenter -t "$POD_PID" -m -- bash -c "mkdir -p ${GW_DIR}"
  for f in app.py config.py keystore.py ratelimit.py; do
    [ -f "$SCRIPT_DIR/gateway/$f" ] || _fail "Gateway source missing: $f"
    nsenter -t "$POD_PID" -m -- bash -c "cat > ${GW_DIR}/$f" < "$SCRIPT_DIR/gateway/$f"
  done
  echo "Gateway source copied."

  # ---- Step 7: Generate secrets ---------------------------------------------
  if [ -z "${LLM_API_KEY:-}" ]; then
    LLM_API_KEY="$(openssl rand -hex 32)"
    echo "Generated LLM_API_KEY."
  fi
  if [ "${BUNDLE}" -ge 2 ] && [ -z "${ADMIN_TOKEN:-}" ]; then
    ADMIN_TOKEN="$(openssl rand -hex 32)"
    echo "Generated ADMIN_TOKEN."
  fi

  # ---- Step 8: Write keyfile inside pod -------------------------------------
  echo "Writing keyfile inside pod..."
  ISO_DATE="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  nsenter -t "$POD_PID" -m -- bash -c "
    mkdir -p ${DATA_DIR}
    echo 'k_bootstrap:${LLM_API_KEY}:bootstrap:${ISO_DATE}' > ${DATA_DIR}/keys.txt
    chmod 600 ${DATA_DIR}/keys.txt
  "
  echo "Keyfile written."

  # ---- Step 9: Start Ollama inside pod --------------------------------------
  echo "Starting Ollama inside pod (port ${OLLAMA_PORT})..."
  nsenter -t "$POD_PID" -m -- bash -c "
    OLLAMA_NUM_CTX=${OLLAMA_NUM_CTX} OLLAMA_HOST=0.0.0.0:${OLLAMA_PORT} \
      nohup ollama serve > ${LOG_DIR}/ollama.log 2>&1 &
    echo \$! > /var/run/${POD_NAME}-ollama.pid
  "

  # Wait up to 120 s for Ollama to become ready
  echo "Waiting for Ollama to become ready..."
  for i in $(seq 1 24); do
    nsenter -t "$POD_PID" -m -- bash -c \
      "OLLAMA_HOST=0.0.0.0:${OLLAMA_PORT} ollama list" >/dev/null 2>&1 && break
    echo "Waiting for Ollama (pod ${POD_INDEX})... ($i/24)"
    sleep 5
  done
  nsenter -t "$POD_PID" -m -- bash -c \
    "OLLAMA_HOST=0.0.0.0:${OLLAMA_PORT} ollama list" >/dev/null 2>&1 \
    || _fail "Ollama did not start within 120s"
  echo "Ollama is ready."

  # ---- Step 10: Pull model --------------------------------------------------
  echo "Pulling model: ${MODEL_SHORT} (${MODEL_TAG}) ..."
  nsenter -t "$POD_PID" -m -- bash -c "
    OLLAMA_HOST=0.0.0.0:${OLLAMA_PORT} ollama pull '${MODEL_TAG}'
  " || _fail "Model pull failed: ${MODEL_TAG}"
  echo "Model pulled successfully."

  # ---- Step 11: Start gateway inside pod ------------------------------------
  echo "Starting LLM gateway (port ${GATEWAY_PORT})..."
  ADMIN_TOKEN_VAL="${ADMIN_TOKEN:-}"
  nsenter -t "$POD_PID" -m -- bash -c "
    export OLLAMA_URL=http://localhost:${OLLAMA_PORT}
    export MODEL=${MODEL_TAG}
    export OLLAMA_NUM_CTX=${OLLAMA_NUM_CTX}
    export RATE_LIMIT_RPM=${RATE_LIMIT_RPM}
    export LLM_API_KEY=${LLM_API_KEY}
    export ADMIN_TOKEN=${ADMIN_TOKEN_VAL}
    export KEYFILE=${DATA_DIR}/keys.txt
    export BUNDLE=${BUNDLE}
    cd ${GW_DIR}
    nohup ${VENV}/bin/uvicorn app:app --host 0.0.0.0 --port ${GATEWAY_PORT} \
      > ${LOG_DIR}/gateway.log 2>&1 &
    echo \$! > /var/run/${POD_NAME}-gateway.pid
  "
  sleep 3
  echo "Gateway started."

  # ---- Step 12: Start cloudflared API tunnel --------------------------------
  echo "Installing cloudflared (if needed)..."
  nsenter -t "$POD_PID" -m -- bash -c "
    if ! command -v cloudflared >/dev/null 2>&1; then
      curl -fsSL https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 \
        -o /usr/local/bin/cloudflared && chmod +x /usr/local/bin/cloudflared
    else
      echo 'cloudflared already installed — skipping.'
    fi
  " || _fail "cloudflared install failed"

  echo "Starting cloudflared API tunnel..."
  nsenter -t "$POD_PID" -m -- bash -c "
    if [ -n '${TUNNEL_TOKEN:-}' ]; then
      nohup cloudflared tunnel --no-autoupdate run --token ${TUNNEL_TOKEN:-} \
        > ${LOG_DIR}/cloudflared-api.log 2>&1 &
    else
      nohup cloudflared tunnel --no-autoupdate --url http://localhost:${GATEWAY_PORT} \
        > ${LOG_DIR}/cloudflared-api.log 2>&1 &
    fi
    echo \$! > /var/run/${POD_NAME}-cf-api.pid
  "

  # Grep for public URL (trycloudflare quick tunnel)
  echo "Waiting for API tunnel URL..."
  API_URL=""
  for i in $(seq 1 30); do
    API_URL=$(nsenter -t "$POD_PID" -m -- bash -c "
      grep -oP 'https://[a-z0-9-]+\.trycloudflare\.com' ${LOG_DIR}/cloudflared-api.log 2>/dev/null | head -1 || true
    ")
    [ -n "$API_URL" ] && break
    sleep 2
  done
  # Fallback: named tunnel URL (different log pattern)
  if [ -z "$API_URL" ]; then
    API_URL=$(nsenter -t "$POD_PID" -m -- bash -c "
      grep -oP 'https://[^\s]+' ${LOG_DIR}/cloudflared-api.log 2>/dev/null \
        | grep -v 'api\.cloudflare' | head -1 || true
    ")
  fi
  [ -n "$API_URL" ] || echo "WARNING: Could not determine API URL from cloudflared log." >&2

  # ---- Step 13: [Bundle 3 only] Virtual Desktop + UduChat -------------------
  VD_URL=""
  if [ "${BUNDLE}" -eq 3 ]; then
    echo "Setting up Virtual Desktop + UduChat (Bundle 3, pod ${POD_INDEX})..."

    nsenter -t "$POD_PID" -m -- bash -c "
      apt-get install -y --no-install-recommends \
        xvfb xfce4 xfce4-terminal x11vnc websockify chromium-browser dbus-x11 xauth
    " || _fail "Desktop packages install failed"

    nsenter -t "$POD_PID" -m -- bash -c "
      ${VENV}/bin/pip install --quiet open-webui
    " || _fail "Open WebUI install failed"

    DISPLAY_NUM=$((10 + POD_INDEX))

    # Xvfb
    nsenter -t "$POD_PID" -m -- bash -c "
      nohup Xvfb :${DISPLAY_NUM} -screen 0 1280x800x24 > ${LOG_DIR}/xvfb.log 2>&1 &
      echo \$! > /var/run/${POD_NAME}-xvfb.pid
    "
    sleep 2

    # XFCE
    nsenter -t "$POD_PID" -m -- bash -c "
      DISPLAY=:${DISPLAY_NUM} nohup startxfce4 > ${LOG_DIR}/xfce4.log 2>&1 &
      echo \$! > /var/run/${POD_NAME}-xfce4.pid
    "
    sleep 3

    # x11vnc
    nsenter -t "$POD_PID" -m -- bash -c "
      mkdir -p /root/.vnc
      x11vnc -storepasswd '${VD_PASS}' /root/.vnc/passwd
      nohup x11vnc -display :${DISPLAY_NUM} -rfbauth /root/.vnc/passwd \
        -forever -shared -rfbport ${VNC_PORT} > ${LOG_DIR}/x11vnc.log 2>&1 &
      echo \$! > /var/run/${POD_NAME}-vnc.pid
    "

    # websockify
    nsenter -t "$POD_PID" -m -- bash -c "
      nohup websockify ${WS_PORT} localhost:${VNC_PORT} > ${LOG_DIR}/websockify.log 2>&1 &
      echo \$! > /var/run/${POD_NAME}-ws.pid
    " || true

    # UduChat (Open WebUI)
    UDUCHAT_PORT=$((3000 + POD_INDEX - 1))
    nsenter -t "$POD_PID" -m -- bash -c "
      export WEBUI_NAME='UduChat'
      export OLLAMA_BASE_URL='http://localhost:${OLLAMA_PORT}'
      export DATA_DIR='${DATA_DIR}/uduchat'
      mkdir -p '${DATA_DIR}/uduchat'
      nohup ${VENV}/bin/open-webui serve --host 0.0.0.0 --port ${UDUCHAT_PORT} \
        > ${LOG_DIR}/uduchat.log 2>&1 &
      echo \$! > /var/run/${POD_NAME}-uduchat.pid
    " || _fail "UduChat failed to start"

    # Desktop shortcut — use printf to expand UDUCHAT_PORT inside nsenter bash -c string
    nsenter -t "$POD_PID" -m -- bash -c "
      mkdir -p /root/Desktop
      printf '[Desktop Entry]\nVersion=1.0\nType=Application\nName=UduChat\nComment=AGH AI Chat Interface\nExec=chromium-browser --no-sandbox http://localhost:${UDUCHAT_PORT}\nIcon=chromium-browser\nTerminal=false\nCategories=Network;\n' \
        > /root/Desktop/UduChat.desktop
      chmod +x /root/Desktop/UduChat.desktop
    "

    # cloudflared VD tunnel
    nsenter -t "$POD_PID" -m -- bash -c "
      nohup cloudflared tunnel --no-autoupdate --url http://localhost:${WS_PORT} \
        > ${LOG_DIR}/cloudflared-vd.log 2>&1 &
      echo \$! > /var/run/${POD_NAME}-cf-vd.pid
    "

    # Grep VD URL
    echo "Waiting for VD tunnel URL..."
    for i in $(seq 1 30); do
      VD_URL=$(nsenter -t "$POD_PID" -m -- bash -c "
        grep -oP 'https://[a-z0-9-]+\.trycloudflare\.com' ${LOG_DIR}/cloudflared-vd.log 2>/dev/null | head -1 || true
      ")
      [ -n "$VD_URL" ] && break
      sleep 2
    done
    [ -n "$VD_URL" ] || echo "WARNING: Could not determine VD URL from cloudflared log." >&2

    echo "Bundle 3 desktop and UduChat setup complete."
  fi

  # ---- Step 14: Summary + webhook -------------------------------------------
  echo ""
  echo "================================================"
  echo " AGH LLM Suite — Pod ${POD_INDEX} Deployed"
  echo " Bundle ${BUNDLE} | ${MODEL_SHORT}"
  echo "================================================"
  echo " Pod      : ${POD_NAME}"
  echo " Model    : ${MODEL_SHORT}"
  echo " API URL  : ${API_URL:-unknown}"
  echo " API Key  : ${LLM_API_KEY}"
  [ "${BUNDLE}" -ge 2 ] && echo " Admin    : ${ADMIN_TOKEN:-}"
  [ "${BUNDLE}" -eq 3 ] && echo " VD URL   : ${VD_URL:-unknown}"
  [ "${BUNDLE}" -eq 3 ] && echo " VD Pass  : ${VD_PASS:-changeme}"
  echo " Ports    : Ollama=${OLLAMA_PORT} Gateway=${GATEWAY_PORT}"
  echo ""
  echo " curl -s -X POST ${API_URL:-<URL>}/query \\"
  echo "   -H \"Authorization: Bearer ${LLM_API_KEY}\" \\"
  echo "   -H \"Content-Type: application/json\" \\"
  echo "   -d '{\"prompt\":\"Hello!\"}' | python3 -m json.tool"
  echo "================================================"

  if [ -n "${WEBHOOK_URL:-}" ]; then
    BODY="{\"status\":\"success\",\"pod\":${POD_INDEX},\"bundle\":${BUNDLE}"
    BODY="${BODY},\"api_url\":\"${API_URL:-}\",\"api_key\":\"${LLM_API_KEY}\",\"model\":\"${MODEL_TAG}\",\"model_name\":\"${MODEL_SHORT}\""
    [ "${BUNDLE}" -ge 2 ] && BODY="${BODY},\"admin_token\":\"${ADMIN_TOKEN:-}\""
    [ "${BUNDLE}" -eq 3 ] && BODY="${BODY},\"vd_url\":\"${VD_URL:-}\",\"vd_password\":\"${VD_PASS:-changeme}\""
    BODY="${BODY}}"
    curl -sf -X POST "$WEBHOOK_URL" -H "Content-Type: application/json" -d "$BODY" \
      || echo "WARNING: Webhook POST failed (non-fatal)"
  fi
}

main "$@"
