#!/usr/bin/env bash
set -euo pipefail

# AGH LLM Suite — Remote startup script
# Fetched and run by Shadeform cloud-init.
# Secrets/config come from env vars set in the cloud-init block.

INSTALL_DIR="/opt/agh-llm-suite"

apt-get update -qq
apt-get install -y --no-install-recommends git

if [ -d "$INSTALL_DIR/.git" ]; then
  echo "Repo already cloned — pulling latest..."
  git -C "$INSTALL_DIR" pull --ff-only
else
  git clone https://github.com/niksresearch/agh-llm-suite.git "$INSTALL_DIR"
fi

chmod +x "$INSTALL_DIR/llm-setup-bundle.sh" "$INSTALL_DIR/bootstrap.sh"
cd "$INSTALL_DIR"
exec bash llm-setup-bundle.sh --bundle "${BUNDLE:-2}"
