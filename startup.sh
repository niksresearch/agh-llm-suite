#!/usr/bin/env bash
set -euo pipefail

# AGH LLM Suite — Startup Script
# Interactive (SSH): prompts for bundle choice + VD password
# Unattended (cloud-init): reads BUNDLE env var, no prompts

INSTALL_DIR="/opt/agh-llm-suite"

# ---------------------------------------------------------------------------
# Interactive prompts (only when stdin is a real terminal)
# ---------------------------------------------------------------------------
if [ -t 0 ]; then
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
  echo "      Multiple API keys via admin endpoints"
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
    *) echo "Invalid bundle. Must be 1, 2, or 3." >&2; exit 1 ;;
  esac

  if [ "$BUNDLE" = "3" ]; then
    read -rsp " Virtual Desktop password: " VD_PASS
    echo ""
    read -rsp " Confirm password: " VD_PASS_CONFIRM
    echo ""
    if [ "$VD_PASS" != "$VD_PASS_CONFIRM" ]; then
      echo "Passwords do not match." >&2; exit 1
    fi
    export VD_PASS
  fi

  echo ""
  echo " Bundle ${BUNDLE} selected. Starting deploy..."
  echo "=============================================="
  echo ""
else
  # Unattended (cloud-init) — BUNDLE must be set as env var
  BUNDLE="${BUNDLE:-2}"
  echo "Unattended mode — Bundle ${BUNDLE}"
fi

export BUNDLE

# ---------------------------------------------------------------------------
# Fetch repo and run
# ---------------------------------------------------------------------------
apt-get update -qq
apt-get install -y --no-install-recommends git

if [ -d "$INSTALL_DIR/.git" ]; then
  echo "Repo found — pulling latest..."
  git -C "$INSTALL_DIR" pull --ff-only
else
  git clone https://github.com/niksresearch/agh-llm-suite.git "$INSTALL_DIR"
fi

chmod +x "$INSTALL_DIR/llm-setup-bundle.sh" "$INSTALL_DIR/bootstrap.sh"
cd "$INSTALL_DIR"
exec bash llm-setup-bundle.sh --bundle "$BUNDLE"
