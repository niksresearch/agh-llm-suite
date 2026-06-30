#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------------------------------------------------------------------------
# AGH LLM Suite — Entrypoint
# Usage: sudo bash llm-setup-bundle.sh [--bundle 1|2|3]
#
# Bundle 1: Ollama + API (single key, no admin)
# Bundle 2: Ollama + API (multi-key, admin mint/list/revoke)
# Bundle 3: Bundle 2 + Virtual Desktop + UduChat (XFCE + Open WebUI)
#
# All bundles: gemma-4-31B-it-GGUF on A100
# ---------------------------------------------------------------------------

BUNDLE="${BUNDLE:-2}"

usage() {
  echo "Usage: sudo bash llm-setup-bundle.sh [--bundle 1|2|3]" >&2
  echo "  Bundle 1: API + single key" >&2
  echo "  Bundle 2: API + multi-key management  (default)" >&2
  echo "  Bundle 3: API + multi-key + Virtual Desktop + UduChat" >&2
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --bundle) BUNDLE="$2"; shift 2 ;;
    --help|-h) usage ;;
    *) echo "Unknown option: $1" >&2; usage ;;
  esac
done

case "$BUNDLE" in
  1|2|3) ;;
  *) echo "ERROR: --bundle must be 1, 2, or 3 (got: $BUNDLE)" >&2; exit 1 ;;
esac

BUNDLE_FILE="$SCRIPT_DIR/bundles/bundle${BUNDLE}.env"
if [ ! -f "$BUNDLE_FILE" ]; then
  echo "ERROR: Bundle file not found: $BUNDLE_FILE" >&2
  exit 1
fi

# Source bundle — sets MODEL, OLLAMA_NUM_CTX, RATE_LIMIT_RPM, BUNDLE_NAME, GPU_TARGET, VD_PASS (bundle3)
# shellcheck source=/dev/null
source "$BUNDLE_FILE"

echo "================================================"
echo " AGH LLM Suite — Bundle ${BUNDLE}: ${BUNDLE_NAME}"
echo " GPU: ${GPU_TARGET} | Model: ${MODEL}"
echo "================================================"

# Export bundle vars for bootstrap.sh
export BUNDLE MODEL OLLAMA_NUM_CTX RATE_LIMIT_RPM BUNDLE_NAME GPU_TARGET
export SCRIPT_DIR

# Pass through optional secrets (pre-supplied via cloud-init / launch_configuration)
export LLM_API_KEY="${LLM_API_KEY:-}"
export ADMIN_TOKEN="${ADMIN_TOKEN:-}"
export WEBHOOK_URL="${WEBHOOK_URL:-}"
export TUNNEL_TOKEN="${TUNNEL_TOKEN:-}"
export VD_PASS="${VD_PASS:-changeme}"

# Launch envPod if not already running
POD_NAME="agh-llm-b${BUNDLE}"
if ! ps aux | grep "sleep infinity" | grep -v grep >/dev/null 2>&1; then
  echo "Launching envPod ${POD_NAME}..."
  envpod run --name "$POD_NAME" --gpu -- sleep infinity &
  # Wait for pod to start
  for i in $(seq 1 20); do
    ps aux | grep "sleep infinity" | grep -v grep >/dev/null 2>&1 && break
    echo "Waiting for pod... ($i/20)"
    sleep 3
  done
  ps aux | grep "sleep infinity" | grep -v grep >/dev/null 2>&1 \
    || { echo "ERROR: envPod failed to start" >&2; exit 1; }
  echo "envPod started."
else
  echo "envPod already running — reusing."
fi

exec bash "$SCRIPT_DIR/bootstrap.sh"
