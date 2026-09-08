#!/usr/bin/env bash
# Dependency availability for the pytest tasks used in the development batch.
# Run in a disposable copy of the task image, before allocating a model budget.
set -euo pipefail
if [[ ! -f /.dockerenv ]]; then
  echo 'Run this preflight in a disposable Docker container, never on the host.' >&2
  exit 64
fi
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends ca-certificates curl
arnes_uv_installer=$(mktemp)
trap 'rm -f "$arnes_uv_installer"' EXIT
curl --proto '=https' --proto-redir '=https' -fLsS \
  --retry 3 --retry-all-errors --connect-timeout 10 --max-time 120 \
  https://astral.sh/uv/0.9.5/install.sh -o "$arnes_uv_installer"
UV_NO_MODIFY_PATH=1 sh "$arnes_uv_installer"
"$HOME/.local/bin/uvx" -p 3.13 --with pytest==8.4.1 --with pytest-json-ctrf==0.3.5 pytest --version
