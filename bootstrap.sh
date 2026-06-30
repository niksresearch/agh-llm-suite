#!/usr/bin/env bash
set -euo pipefail

# bootstrap.sh — AGH LLM Suite
# Called by llm-setup-bundle.sh after the envPod is already running.
# Services run as processes inside the pod via nsenter, NOT docker-compose.
#
# Required env vars (set by llm-setup-bundle.sh):
#   BUNDLE, MODEL, OLLAMA_NUM_CTX, RATE_LIMIT_RPM,
#   LLM_API_KEY (may be empty), ADMIN_TOKEN (may be empty, Bundle 2+ only),
#   WEBHOOK_URL (optional), TUNNEL_TOKEN (optional),
#   VD_PASS (Bundle 3, default "changeme"), SCRIPT_DIR

SCRIPT_DIR="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"

# ---------------------------------------------------------------------------
# Error handler — posts webhook on failure then exits 1
# ---------------------------------------------------------------------------
_fail() {
  echo "ERROR: $1" >&2
  if [ -n "${WEBHOOK_URL:-}" ]; then
    curl -sf -X POST "$WEBHOOK_URL" \
      -H "Content-Type: application/json" \
      -d "{\"status\":\"failure\",\"error\":\"$1\",\"bundle\":${BUNDLE},\"model\":\"${MODEL:-unknown}\"}" \
      || true
  fi
  exit 1
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {

  # ---- 1. Find the envPod PID ----------------------------------------------
  POD_PID=$(ps aux | grep "sleep infinity" | grep -v grep | awk '{print $2}' | head -1)
  [[ -n "$POD_PID" ]] || _fail "envPod not found. Run llm-setup-bundle.sh to start the pod first."
  echo "Pod PID: $POD_PID"

  # ---- 2. Install common deps inside pod ------------------------------------
  echo "Installing common dependencies inside pod..."
  nsenter -t "${POD_PID}" -m -- bash -c "
    apt-get update -qq
    apt-get install -y --no-install-recommends curl python3 python3-pip python3-venv
  "

  # ---- 3. Install Ollama inside pod (idempotent) ----------------------------
  echo "Checking / installing Ollama inside pod..."
  nsenter -t "${POD_PID}" -m -- bash -c "
    if ! command -v ollama >/dev/null 2>&1; then
      curl -fsSL https://ollama.ai/install.sh | sh
    else
      echo 'Ollama already installed — skipping.'
    fi
  "

  # ---- 4. Create Python venv + install gateway deps -------------------------
  echo "Creating Python venv and installing gateway dependencies..."
  nsenter -t "${POD_PID}" -m -- bash -c "
    python3 -m venv /opt/llm-env
    /opt/llm-env/bin/pip install --quiet \
      fastapi==0.138.2 \
      uvicorn[standard]==0.49.0 \
      httpx==0.28.1 \
      pydantic==2.13.4
  "

  # ---- 5. Copy gateway source into pod filesystem ---------------------------
  # Gateway files live at $SCRIPT_DIR/gateway/ on the host.
  # Write them into the pod at /opt/llm-gateway/ via stdin to handle mount ns.
  echo "Copying gateway source into pod..."
  nsenter -t "${POD_PID}" -m -- bash -c "mkdir -p /opt/llm-gateway"
  for f in app.py config.py keystore.py ratelimit.py; do
    [ -f "$SCRIPT_DIR/gateway/$f" ] || _fail "Gateway source file not found: $SCRIPT_DIR/gateway/$f"
    nsenter -t "${POD_PID}" -m -- bash -c "cat > /opt/llm-gateway/$f" < "$SCRIPT_DIR/gateway/$f"
  done
  echo "Gateway source copied."

  # ---- 6. Generate secrets --------------------------------------------------
  if [ -z "${LLM_API_KEY:-}" ]; then
    LLM_API_KEY="$(openssl rand -hex 32)"
    echo "Generated LLM_API_KEY."
  fi
  if [ "${BUNDLE}" -ge 2 ] && [ -z "${ADMIN_TOKEN:-}" ]; then
    ADMIN_TOKEN="$(openssl rand -hex 32)"
    echo "Generated ADMIN_TOKEN."
  fi

  # ---- 7. Write keyfile inside pod ------------------------------------------
  echo "Writing keyfile inside pod..."
  ISO_DATE="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  nsenter -t "${POD_PID}" -m -- bash -c "
    mkdir -p /data
    echo 'k_bootstrap:${LLM_API_KEY}:bootstrap:${ISO_DATE}' > /data/keys.txt
    chmod 600 /data/keys.txt
  "
  echo "Keyfile written."

  # ---- 8. Start Ollama inside pod -------------------------------------------
  echo "Starting Ollama inside pod..."
  nsenter -t "${POD_PID}" -m -- bash -c "
    OLLAMA_NUM_CTX=${OLLAMA_NUM_CTX} nohup ollama serve > /var/log/ollama.log 2>&1 &
    echo \$! > /var/run/ollama.pid
  "

  # Wait up to 120 s for Ollama to become ready
  echo "Waiting for Ollama to become ready..."
  ollama_ready=0
  for i in $(seq 1 24); do
    if nsenter -t "${POD_PID}" -m -- bash -c "ollama list" >/dev/null 2>&1; then
      ollama_ready=1
      break
    fi
    echo "Waiting for Ollama... ($i/24)"
    sleep 5
  done
  [ "$ollama_ready" -eq 1 ] || _fail "Ollama did not start within 120s"
  echo "Ollama is ready."

  # ---- 9. Pull model --------------------------------------------------------
  echo "Pulling model hf.co/unsloth/${MODEL}:UD-Q4_K_XL ..."
  nsenter -t "${POD_PID}" -m -- bash -c "
    ollama pull 'hf.co/unsloth/${MODEL}:UD-Q4_K_XL'
  " || _fail "Model pull failed"
  echo "Model pulled successfully."

  # ---- 10. Start gateway (uvicorn) ------------------------------------------
  echo "Starting LLM gateway (uvicorn)..."
  ADMIN_TOKEN_VAL="${ADMIN_TOKEN:-}"
  nsenter -t "${POD_PID}" -m -- bash -c "
    export OLLAMA_URL=http://localhost:11434
    export MODEL=${MODEL}
    export OLLAMA_NUM_CTX=${OLLAMA_NUM_CTX}
    export RATE_LIMIT_RPM=${RATE_LIMIT_RPM}
    export LLM_API_KEY=${LLM_API_KEY}
    export ADMIN_TOKEN=${ADMIN_TOKEN_VAL}
    export KEYFILE=/data/keys.txt
    export BUNDLE=${BUNDLE}
    cd /opt/llm-gateway
    nohup /opt/llm-env/bin/uvicorn app:app --host 0.0.0.0 --port 8000 \
      > /var/log/llm-gateway.log 2>&1 &
    echo \$! > /var/run/llm-gateway.pid
  "
  sleep 3  # brief wait for uvicorn to bind
  echo "Gateway started."

  # ---- 11. Install cloudflared + start API tunnel ---------------------------
  echo "Installing cloudflared (if needed)..."
  nsenter -t "${POD_PID}" -m -- bash -c "
    if ! command -v cloudflared >/dev/null 2>&1; then
      curl -fsSL https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 \
        -o /usr/local/bin/cloudflared
      chmod +x /usr/local/bin/cloudflared
    else
      echo 'cloudflared already installed — skipping.'
    fi
  "

  echo "Starting cloudflared API tunnel..."
  nsenter -t "${POD_PID}" -m -- bash -c "
    if [ -n '${TUNNEL_TOKEN:-}' ]; then
      nohup cloudflared tunnel --no-autoupdate run --token ${TUNNEL_TOKEN:-} \
        > /var/log/cloudflared-api.log 2>&1 &
    else
      nohup cloudflared tunnel --no-autoupdate --url http://localhost:8000 \
        > /var/log/cloudflared-api.log 2>&1 &
    fi
    echo \$! > /var/run/cloudflared-api.pid
  "

  # Grep for public URL (trycloudflare quick tunnel)
  echo "Waiting for API tunnel URL..."
  API_URL=""
  for i in $(seq 1 30); do
    API_URL=$(nsenter -t "${POD_PID}" -m -- bash -c "
      grep -oP 'https://[a-z0-9-]+\.trycloudflare\.com' /var/log/cloudflared-api.log 2>/dev/null | head -1 || true
    ")
    [ -n "$API_URL" ] && break
    sleep 2
  done
  # Fallback: named tunnel URL (different log pattern)
  if [ -z "$API_URL" ]; then
    API_URL=$(nsenter -t "${POD_PID}" -m -- bash -c "
      grep -oP 'https://[^\s]+' /var/log/cloudflared-api.log 2>/dev/null \
        | grep -v 'api\.cloudflare' | head -1 || true
    ")
  fi
  [ -n "$API_URL" ] || echo "WARNING: Could not determine API URL from cloudflared log." >&2

  # ---- 12. [Bundle 3 only] Virtual Desktop + UduChat ------------------------
  VD_URL=""
  if [ "${BUNDLE}" -eq 3 ]; then
    echo "Setting up Virtual Desktop + UduChat (Bundle 3)..."

    # Install desktop packages
    nsenter -t "${POD_PID}" -m -- bash -c "
      apt-get install -y --no-install-recommends \
        xvfb xfce4 xfce4-terminal x11vnc websockify chromium-browser \
        dbus-x11 xauth
    "

    # Install Open WebUI (UduChat engine) inside venv
    nsenter -t "${POD_PID}" -m -- bash -c "
      /opt/llm-env/bin/pip install --quiet open-webui
    " || _fail "Open WebUI install failed"

    # Start Xvfb
    nsenter -t "${POD_PID}" -m -- bash -c "
      nohup Xvfb :1 -screen 0 1280x800x24 > /var/log/xvfb.log 2>&1 &
      echo \$! > /var/run/xvfb.pid
    "
    sleep 2

    # Start XFCE desktop
    nsenter -t "${POD_PID}" -m -- bash -c "
      DISPLAY=:1 nohup startxfce4 > /var/log/xfce4.log 2>&1 &
      echo \$! > /var/run/xfce4.pid
    "
    sleep 3

    # Set x11vnc password and start VNC server
    VD_PASS="${VD_PASS:-changeme}"
    nsenter -t "${POD_PID}" -m -- bash -c "
      mkdir -p /root/.vnc
      x11vnc -storepasswd '${VD_PASS}' /root/.vnc/passwd
      nohup x11vnc -display :1 -rfbauth /root/.vnc/passwd -forever -shared \
        -rfbport 5900 > /var/log/x11vnc.log 2>&1 &
      echo \$! > /var/run/x11vnc.pid
    "

    # Start websockify (VNC → WebSocket for noVNC)
    nsenter -t "${POD_PID}" -m -- bash -c "
      nohup websockify --web /usr/share/novnc 6080 localhost:5900 \
        > /var/log/websockify.log 2>&1 &
      echo \$! > /var/run/websockify.pid
    " || true  # non-fatal if noVNC not present; VNC still accessible on 5900

    # Start UduChat (Open WebUI)
    nsenter -t "${POD_PID}" -m -- bash -c "
      export WEBUI_NAME='UduChat'
      export OLLAMA_BASE_URL='http://localhost:11434'
      export DATA_DIR='/data/uduchat'
      mkdir -p /data/uduchat
      nohup /opt/llm-env/bin/open-webui serve --host 0.0.0.0 --port 3000 \
        > /var/log/uduchat.log 2>&1 &
      echo \$! > /var/run/uduchat.pid
    " || _fail "UduChat failed to start"

    # Create desktop shortcut for UduChat
    nsenter -t "${POD_PID}" -m -- bash -c "
      mkdir -p /root/Desktop
      cat > /root/Desktop/UduChat.desktop <<'DESKTOP'
[Desktop Entry]
Version=1.0
Type=Application
Name=UduChat
Comment=AGH AI Chat Interface
Exec=chromium-browser --no-sandbox http://localhost:3000
Icon=chromium-browser
Terminal=false
Categories=Network;
DESKTOP
      chmod +x /root/Desktop/UduChat.desktop
    "

    # Start cloudflared VD tunnel
    nsenter -t "${POD_PID}" -m -- bash -c "
      nohup cloudflared tunnel --no-autoupdate --url http://localhost:6080 \
        > /var/log/cloudflared-vd.log 2>&1 &
      echo \$! > /var/run/cloudflared-vd.pid
    "

    # Grep VD URL
    echo "Waiting for VD tunnel URL..."
    for i in $(seq 1 30); do
      VD_URL=$(nsenter -t "${POD_PID}" -m -- bash -c "
        grep -oP 'https://[a-z0-9-]+\.trycloudflare\.com' /var/log/cloudflared-vd.log 2>/dev/null | head -1 || true
      ")
      [ -n "$VD_URL" ] && break
      sleep 2
    done
    [ -n "$VD_URL" ] || echo "WARNING: Could not determine VD URL from cloudflared log." >&2

    echo "Bundle 3 desktop and UduChat setup complete."
  fi

  # ---- 13. Determine bundle name for summary --------------------------------
  case "${BUNDLE}" in
    1) BUNDLE_NAME="API Only" ;;
    2) BUNDLE_NAME="API + Admin" ;;
    3) BUNDLE_NAME="Full Suite (API + Admin + Desktop)" ;;
    *) BUNDLE_NAME="Bundle ${BUNDLE}" ;;
  esac

  # ---- 14. Print summary ----------------------------------------------------
  echo ""
  echo "================================================"
  echo " AGH LLM Suite — Deploy Complete"
  echo " Bundle ${BUNDLE}: ${BUNDLE_NAME}"
  echo "================================================"
  echo " API URL   : ${API_URL:-unknown}"
  echo " API Key   : ${LLM_API_KEY}"
  [ "${BUNDLE}" -ge 2 ] && echo " Admin Tok : ${ADMIN_TOKEN:-}"
  [ "${BUNDLE}" -eq 3 ] && echo " VD URL    : ${VD_URL:-unknown} (password: ${VD_PASS:-changeme})"
  [ "${BUNDLE}" -eq 3 ] && echo " UduChat   : Open VD -> Chrome -> UduChat icon"
  echo " Model     : ${MODEL}"
  echo ""
  echo " Sample:"
  echo "   curl -s -X POST ${API_URL:-<API_URL>}/query \\"
  echo "     -H \"Authorization: Bearer ${LLM_API_KEY}\" \\"
  echo "     -H \"Content-Type: application/json\" \\"
  echo "     -d '{\"prompt\":\"Hello!\"}' | python3 -m json.tool"
  echo "================================================"

  # ---- Post success webhook -------------------------------------------------
  if [ -n "${WEBHOOK_URL:-}" ]; then
    WEBHOOK_BODY="{\"status\":\"success\",\"bundle\":${BUNDLE},\"api_url\":\"${API_URL:-}\",\"api_key\":\"${LLM_API_KEY}\",\"model\":\"${MODEL}\""
    [ "${BUNDLE}" -ge 2 ] && WEBHOOK_BODY="${WEBHOOK_BODY},\"admin_token\":\"${ADMIN_TOKEN:-}\""
    [ "${BUNDLE}" -eq 3 ] && WEBHOOK_BODY="${WEBHOOK_BODY},\"vd_url\":\"${VD_URL:-}\""
    WEBHOOK_BODY="${WEBHOOK_BODY}}"
    curl -sf -X POST "$WEBHOOK_URL" \
      -H "Content-Type: application/json" \
      -d "$WEBHOOK_BODY" \
      || echo "WARNING: Webhook POST failed (non-fatal)"
  fi
}

main "$@"
