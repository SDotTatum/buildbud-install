#!/usr/bin/env bash
# BuildBud self-host installer bootstrap. Downloads the installer to ./buildbud-install.
# Usage:  curl -fsSL https://raw.githubusercontent.com/SDotTatum/buildbud-install/main/bootstrap.sh | bash
set -euo pipefail
DIR="${BB_INSTALL_DIR:-buildbud-install}"

# This used to be `rm -rf "$DIR"` before the move. On a configured instance that
# is a data-loss bug, not a tidy-up: .env and secrets/ live INSIDE the install
# directory, so re-running the documented one-liner in a directory that already
# has an install deletes the credentials and secrets of a working deployment.
# The one-liner is the first thing anyone runs, it is easy to run twice, and the
# second run is silent about what it destroyed.
#
# A refresh of an existing install is `./setup.sh --self-update`, which replaces
# the tooling and explicitly leaves instance state alone. So: refuse, and say so.
if [ -e "$DIR" ]; then
  if [ -e "$DIR/.env" ] || [ -e "$DIR/secrets" ] || [ -e "$DIR/data" ]; then
    echo "[buildbud] '$DIR' is an existing install — refusing to overwrite it." >&2
    echo "[buildbud] It holds instance state (.env / secrets / data) that this" >&2
    echo "[buildbud] script would delete." >&2
    echo >&2
    echo "[buildbud] To update the tooling in place, keeping your instance:" >&2
    echo "[buildbud]   cd $DIR && ./setup.sh --self-update && ./setup.sh --upgrade" >&2
    echo >&2
    echo "[buildbud] To install alongside it instead:" >&2
    echo "[buildbud]   BB_INSTALL_DIR=buildbud-install-new curl -fsSL <this url> | bash" >&2
    exit 1
  fi
  # Present but carries no instance state: move it aside rather than delete it.
  # Even a stale tree can hold a note or a hand-edit worth more than the seconds
  # saved by removing it.
  _aside="$DIR.replaced-$(date -u +%Y%m%dT%H%M%SZ)"
  echo "[buildbud] '$DIR' exists with no instance state — moving it to $_aside"
  mv "$DIR" "$_aside"
fi

echo "[buildbud] downloading installer -> ./$DIR"
# Extract into a private staging dir. Unpacking into the working directory left
# buildbud-install-main/ behind on any failure, and a second run would then `mv`
# the new tree INSIDE the stale one.
_stage="$(mktemp -d "${TMPDIR:-/tmp}/bb-bootstrap.XXXXXX")"
trap 'rm -rf "$_stage"' EXIT
curl -fsSL https://github.com/SDotTatum/buildbud-install/archive/refs/heads/main.tar.gz | tar xz -C "$_stage"

_src="$_stage/buildbud-install-main"
[ -d "$_src" ] || { echo "[buildbud] downloaded archive has an unexpected layout — nothing changed." >&2; exit 1; }
[ -f "$_src/setup.sh" ] || { echo "[buildbud] downloaded archive has no setup.sh — nothing changed." >&2; exit 1; }

mv "$_src" "$DIR"
chmod +x "$DIR/setup.sh" "$DIR/harden.sh" "$DIR/genesis/inspect.sh" 2>/dev/null || true
echo "[buildbud] done. Next:"
echo "  cd $DIR && ./setup.sh --license /path/to/license.json --domain your.host.example"
