#!/usr/bin/env bash
set -euo pipefail

# AGH LLM Suite — Setup Script
#
# Interactive (SSH):
#   bash /opt/agh-llm-suite/startup.sh
#   curl -fsSL https://raw.githubusercontent.com/niksresearch/agh-llm-suite/main/startup.sh | bash
#
# Cloud-init (Shadeform / unattended boot):
#   Paste this URL into Shadeform startup script field — it clones the repo
#   and prints SSH instructions. User completes setup interactively.

INSTALL_DIR="/opt/agh-llm-suite"

# ---------------------------------------------------------------------------
# Fetch / update repo first (needed in both modes)
# ---------------------------------------------------------------------------
apt-get update -qq
apt-get install -y --no-install-recommends git

if [ -d "$INSTALL_DIR/.git" ]; then
  git -C "$INSTALL_DIR" pull --ff-only
else
  git clone https://github.com/niksresearch/agh-llm-suite.git "$INSTALL_DIR"
fi

chmod +x "$INSTALL_DIR/startup.sh" \
         "$INSTALL_DIR/llm-setup-bundle.sh" \
         "$INSTALL_DIR/bootstrap.sh"

# ---------------------------------------------------------------------------
# Non-interactive (cloud-init / no TTY): print SSH instructions and exit
# ---------------------------------------------------------------------------
if [ ! -t 0 ]; then
  echo ""
  echo "======================================================="
  echo " AGH LLM Suite ready at $INSTALL_DIR"
  echo " SSH into this instance and run:"
  echo ""
  echo "   bash $INSTALL_DIR/startup.sh"
  echo "======================================================="
  exit 0
fi

# ---------------------------------------------------------------------------
# Interactive (SSH): prompt for bundle and config
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

if [ "$BUNDLE" = "3" ]; then
  while true; do
    read -rsp " Virtual Desktop password: " VD_PASS; echo ""
    read -rsp " Confirm password:         " VD_PASS2; echo ""
    [ "$VD_PASS" = "$VD_PASS2" ] && break
    echo " Passwords do not match — try again."
  done
  export VD_PASS
fi

export BUNDLE

echo ""
echo " Bundle ${BUNDLE} selected. Starting deploy..."
echo "=============================================="
echo ""

cd "$INSTALL_DIR"
exec bash llm-setup-bundle.sh --bundle "$BUNDLE"
