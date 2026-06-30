#!/usr/bin/env bash
set -euo pipefail

# AGH LLM Suite — Setup Script
# Run this after SSH-ing into the GPU instance:
#   curl -fsSL https://raw.githubusercontent.com/niksresearch/agh-llm-suite/main/startup.sh | bash
# or if repo already cloned:
#   bash /opt/agh-llm-suite/startup.sh

INSTALL_DIR="/opt/agh-llm-suite"

# ---------------------------------------------------------------------------
# Phase 0: Prerequisites (idempotent — safe to run multiple times)
# ---------------------------------------------------------------------------
echo "[ AGH LLM Suite ] Checking prerequisites..."

apt-get update -qq
apt-get install -y --no-install-recommends git curl

# NVIDIA driver
if ! command -v nvidia-smi >/dev/null 2>&1; then
  echo "NVIDIA driver not found — installing..."
  OS_ID="$(. /etc/os-release && echo "$ID")"
  case "$OS_ID" in
    ubuntu)
      apt-get install -y --no-install-recommends ubuntu-drivers-common
      ubuntu-drivers autoinstall || \
        apt-get install -y nvidia-driver-580-server nvidia-utils-580-server nvidia-modprobe
      ;;
    debian)
      echo "deb http://deb.debian.org/debian bookworm-backports main contrib non-free non-free-firmware" \
        > /etc/apt/sources.list.d/backports.list
      apt-get update -qq
      apt-get install -y -t bookworm-backports nvidia-driver firmware-misc-nonfree
      ;;
    *)
      echo "WARNING: Unknown OS '$OS_ID' — install NVIDIA drivers manually." >&2
      ;;
  esac
else
  echo "NVIDIA driver OK: $(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1)"
fi

# envPod
if ! command -v envpod >/dev/null 2>&1; then
  echo "envPod not found — installing..."
  curl -fsSL https://envpod.dev/install.sh | bash
  ENVPOD_BIN=$(command -v envpod 2>/dev/null || echo "/usr/local/bin/envpod")
  [[ -x "$ENVPOD_BIN" ]] || { echo "ERROR: envpod not found after install." >&2; exit 1; }
  echo "envPod OK: $("$ENVPOD_BIN" --version 2>&1 | head -1)"
else
  echo "envPod OK: $(envpod --version 2>&1 | head -1)"
fi

# ---------------------------------------------------------------------------
# Phase 1: Fetch / update repo
# ---------------------------------------------------------------------------
if [ -d "$INSTALL_DIR/.git" ]; then
  echo "Repo found — pulling latest..."
  git -C "$INSTALL_DIR" pull --ff-only
else
  git clone https://github.com/niksresearch/agh-llm-suite.git "$INSTALL_DIR"
fi

chmod +x "$INSTALL_DIR/startup.sh" \
         "$INSTALL_DIR/llm-setup-bundle.sh" \
         "$INSTALL_DIR/bootstrap.sh"

# ---------------------------------------------------------------------------
# Phase 2: Interactive — prompt for bundle + pod slot
# ---------------------------------------------------------------------------
echo ""
echo "=============================================="
echo " AGH LLM Suite — Setup"
echo "=============================================="
echo ""
echo " Select a Bundle:"
echo ""
echo "  [1] Single-Key API"
echo "      Ollama + Gemma 4 31B + REST API"
echo "      One API key auto-generated at deploy"
echo ""
echo "  [2] Multi-Key API  (recommended)"
echo "      Ollama + Gemma 4 31B + REST API"
echo "      Multiple keys via admin endpoints"
echo "      Mint / list / revoke keys at runtime"
echo ""
echo "  [3] Multi-Key API + Virtual Desktop + UduChat"
echo "      Everything in Bundle 2, plus:"
echo "      XFCE desktop (VNC, password-protected)"
echo "      UduChat (Open WebUI) as Chrome icon on desktop"
echo ""
read -rp " Enter bundle [1/2/3]: " BUNDLE
echo ""

case "$BUNDLE" in
  1|2|3) ;;
  *) echo "Invalid choice. Must be 1, 2, or 3." >&2; exit 1 ;;
esac

echo " Active pods:"
if ps aux | grep -q "[s]leep infinity"; then
  ps aux | grep "[s]leep infinity" | awk '{print "  PID " $2}' | head -10
else
  echo "  (none)"
fi
echo ""

read -rp " Pod slot [1-10, default 1]: " POD_INDEX_INPUT
POD_INDEX="${POD_INDEX_INPUT:-1}"

if ! [[ "$POD_INDEX" =~ ^([1-9]|10)$ ]]; then
  echo "Invalid pod slot. Must be 1-10." >&2; exit 1
fi
echo ""

if [ "$BUNDLE" = "3" ]; then
  while true; do
    read -rsp " Virtual Desktop password: " VD_PASS; echo ""
    read -rsp " Confirm password:         " VD_PASS2; echo ""
    [ "$VD_PASS" = "$VD_PASS2" ] && break
    echo " Passwords do not match — try again."
  done
  export VD_PASS
fi

export BUNDLE POD_INDEX

echo ""
echo " Bundle ${BUNDLE} | Pod ${POD_INDEX} | Starting deploy..."
echo "=============================================="
echo ""

cd "$INSTALL_DIR"
exec bash llm-setup-bundle.sh --bundle "$BUNDLE" --pod-index "$POD_INDEX"
