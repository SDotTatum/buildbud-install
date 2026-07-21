#!/usr/bin/env bash
# BuildBud self-host installer bootstrap. Downloads the installer to ./buildbud-install.
# Usage:  curl -fsSL https://raw.githubusercontent.com/SDotTatum/buildbud-install/main/bootstrap.sh | bash
set -euo pipefail
DIR="${BB_INSTALL_DIR:-buildbud-install}"
echo "[buildbud] downloading installer -> ./$DIR"
curl -fsSL https://github.com/SDotTatum/buildbud-install/archive/refs/heads/main.tar.gz | tar xz
rm -rf "$DIR"; mv buildbud-install-main "$DIR"
chmod +x "$DIR/setup.sh" "$DIR/harden.sh" "$DIR/genesis/inspect.sh" 2>/dev/null || true
echo "[buildbud] done. Next:"
echo "  cd $DIR && ./setup.sh --license /path/to/license.json --domain your.host.example"
