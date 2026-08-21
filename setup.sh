#!/usr/bin/env bash
set -euo pipefail

# BuildBud Self-Hosted Setup
# Usage: ./setup.sh [--domain your.domain.com] [--upgrade] [--reset] [--self-update]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENABLE_ONECLICK="${ENABLE_ONECLICK:-false}"
SEED_STARTER="${SEED_STARTER:-true}"
SELF_UPDATE=false
STARTER_NAME="${STARTER_NAME:-my-first-app}"
ENV_FILE="$SCRIPT_DIR/.env"
SECRETS_DIR="$SCRIPT_DIR/secrets"
VERSION="${VERSION:-prod}"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
info()    { echo -e "${BLUE}[BuildBud]${NC} $*"; }
success() { echo -e "${GREEN}[BuildBud]${NC} $*"; }
warn()    { echo -e "${YELLOW}[BuildBud]${NC} $*"; }
error()   { echo -e "${RED}[BuildBud]${NC} $*" >&2; }

# ─── Diagnosis helpers ────────────────────────────────────────────────────────
# Pure-ish helpers, unit-tested by install/__tests__/setup-lib.test.sh. They
# exist because the installer used to state things it had never checked: it
# printed "Prerequisites OK" without ever talking to the Docker API, retried
# errors that can never succeed on a retry, and printed a URL it had never
# fetched. Each helper answers exactly one question, so the answer can be tested.

# Can we actually TALK to the Docker daemon? The binary existing says nothing.
# Echoes: ok | permission | nodaemon | unknown
docker_api_state() {
  local out
  if out="$(docker info 2>&1)"; then
    echo ok
    return 0
  fi
  case "$out" in
    *"permission denied"*)                                        echo permission ;;
    *"Cannot connect to the Docker daemon"*|*"docker daemon running"*) echo nodaemon ;;
    *)                                                            echo unknown ;;
  esac
}

# Is a stack-start failure worth retrying? Retrying a permission denial or a
# port conflict only delays and hides the real message (G39).
# Echoes: transient | permission | port-conflict | permanent
classify_stack_error() {
  local out="$1"
  case "$out" in
    *"permission denied while trying to connect to the Docker daemon"*|*"Got permission denied while trying"*)
      echo permission ;;
    *"address already in use"*|*"port is already allocated"*|*"failed to bind host port"*|*"Bind for "*"failed"*)
      echo port-conflict ;;
    *"denied: requested access to the resource is denied"*|*"unauthorized: "*|*"manifest unknown"*|*"no space left on device"*)
      echo permanent ;;
    *"Conflict. The container name"*|*"TLS handshake timeout"*|*"i/o timeout"*|*"connection reset by peer"*|*"toomanyrequests"*|*"net/http: request canceled"*|*"context deadline exceeded"*)
      echo transient ;;
    *)
      echo permanent ;;
  esac
}

# Fetch a URL and echo the HTTP status code. 000 means "nothing answered" —
# curl's own convention, kept so a caller cannot mistake it for a real code.
probe_http() {
  # curl already writes 000 when nothing answers; do not add a second 000 on
  # its non-zero exit. Empty output (no curl at all) becomes 000 too.
  local code
  code="$(curl -sk -o /dev/null -w '%{http_code}' --max-time "${2:-6}" "$1" 2>/dev/null)"
  echo "${code:-000}"
}

# Does a status code mean the entry point is serving? A 401/403 does: the app
# answered and asked for auth. A 000 or a 5xx does not.
entry_ok() {
  case "${1:-000}" in
    2[0-9][0-9]|3[0-9][0-9]|4[0-9][0-9]) return 0 ;;   # something served it
    *) return 1 ;;                                     # 000 = nothing, 5xx = broken
  esac
}

# Who is holding a host port? Used to explain a bind conflict instead of just
# reporting one. Best-effort: prints nothing when no tool is available.
port_holders() {
  local port="$1"
  if command -v ss &>/dev/null; then
    ss -lntp 2>/dev/null | awk -v p=":$port\$" '$4 ~ p'
  elif command -v lsof &>/dev/null; then
    lsof -nP -iTCP:"$port" -sTCP:LISTEN 2>/dev/null
  fi
}

# Print the instance's login credential, or explain why there isn't one.
# The API token is the ONLY way into a self-host instance: the Tailscale
# identity path needs a tailscaled socket that a customer VPS does not have and
# this compose file does not mount, so it can never resolve there. Before
# --show-token the credential was printed exactly once, at the end of the
# install, and never again — closing that terminal locked the operator out of
# their own instance (G61). Echoes the token on stdout and nothing else, so it
# can be piped; every diagnosis goes to stderr.
show_api_token() {
  local env_file="$1" tok
  if [ ! -f "$env_file" ]; then
    echo "No install found: $env_file does not exist." >&2
    echo "Run ./setup.sh first, or run this from the directory you installed into." >&2
    return 1
  fi
  tok="$(grep -E '^BUILDBUD_API_TOKEN=' "$env_file" | head -1 | cut -d= -f2-)"
  tok="${tok%\"}"; tok="${tok#\"}"
  if [ -z "$tok" ]; then
    echo "BUILDBUD_API_TOKEN is empty or absent in $env_file." >&2
    echo "Re-run ./setup.sh --upgrade to regenerate it." >&2
    return 1
  fi
  echo "$tok"
}

# ─── Install-tree freshness (G72) ─────────────────────────────────────────────
# `docker compose pull` updates the APPLICATION IMAGE and nothing else. The
# install tree -- this script, the compose file, the Caddyfile, the updater --
# is whatever bootstrap.sh downloaded on the day of the install, and nothing
# ever refreshes it. So every installer fix (G37 unprobed URL, G39 retrying
# permanent errors, G40 wrong directory name, G42 feedback banner, G61
# --show-token) reaches NEW installs only and is invisible to every instance
# already in the field. Measured on the real bb-team instance: `./setup.sh
# --show-token` answers "Unknown option", although the flag has been in the
# upstream install repo since it merged.
#
# These helpers are above the LIB_ONLY line so install/__tests__ can drive them.

BB_INSTALL_TARBALL="${BB_INSTALL_TARBALL:-https://github.com/SDotTatum/buildbud-install/archive/refs/heads/main.tar.gz}"

# Files that belong to the TOOLING and may be replaced wholesale. Everything
# else in the install dir -- .env, secrets/, data/, docker-compose.override.yml
# -- is instance state and is never touched by a tree refresh.
bb_tree_tooling_files() {
  printf '%s\n' setup.sh bootstrap.sh docker-compose.yml Caddyfile harden.sh \
    PRE-ALPHA-ACCESS.md INSTALL-GUIDE.md README.md
}

# Is a candidate directory a plausible install tree? A refresh that overwrote a
# live install with a half-downloaded or wrong tarball would be worse than a
# stale one, so this is checked before anything is copied.
# Echoes: ok | missing-setup | missing-compose
bb_tree_looks_valid() {
  local dir="$1"
  [ -f "$dir/setup.sh" ]           || { echo missing-setup; return 1; }
  [ -f "$dir/docker-compose.yml" ] || { echo missing-compose; return 1; }
  echo ok
}

# Compare two setup.sh files by the flags they accept, which is the property an
# operator actually cares about ("does my copy have --show-token?"). Echoes the
# flags present upstream and absent locally, one per line; empty when current.
bb_tree_missing_flags() {
  local local_setup="$1" upstream_setup="$2"
  local up loc
  up="$(grep -oE '^\s+--[a-z-]+\)' "$upstream_setup" 2>/dev/null | tr -d ' )' | sort -u)"
  loc="$(grep -oE '^\s+--[a-z-]+\)' "$local_setup" 2>/dev/null | tr -d ' )' | sort -u)"
  comm -23 <(printf '%s\n' "$up") <(printf '%s\n' "$loc")
}

# Sourced by install/__tests__: define the helpers above, then stop. Nothing
# below this line runs, so the tests cannot install anything.
if [ -n "${BB_SETUP_LIB_ONLY:-}" ]; then return 0 2>/dev/null || exit 0; fi

# ─── Argument parsing ─────────────────────────────────────────────────────────
DOMAIN="localhost"
DOMAIN_SET=false
UPGRADE=false
RESET=false
LICENSE_FILE=""
INSTALL_DEPS=true
SHOW_TOKEN=false

while [[ $# -gt 0 ]]; do
  case $1 in
    --domain) DOMAIN="$2"; DOMAIN_SET=true; shift 2 ;;
    --license) LICENSE_FILE="$2"; shift 2 ;;
    --claude-token) CLAUDE_CODE_OAUTH_TOKEN="$2"; shift 2 ;;
    --anthropic-key) ANTHROPIC_API_KEY="$2"; shift 2 ;;
    --upgrade) UPGRADE=true; shift ;;
    --enable-one-click-update) ENABLE_ONECLICK=true; shift ;;
    --reset) RESET=true; shift ;;
    --no-install-deps) INSTALL_DEPS=false; shift ;;
    --no-starter-project) SEED_STARTER=false; shift ;;
    --show-token) SHOW_TOKEN=true; shift ;;
    --self-update) SELF_UPDATE=true; shift ;;
    *) error "Unknown option: $1"; exit 1 ;;
  esac
done

# --show-token: reprint the login credential and exit. The API token is the
# only way into a self-host instance (the Tailscale identity path needs a
# tailscaled socket, which a customer VPS does not have and this compose file
# does not mount), and before this flag it was printed exactly once, at the end
# of the install, and never again. Closing that terminal locked the operator
# out of their own instance with no documented way back in (G61).
if [ "$SHOW_TOKEN" = true ]; then
  show_api_token "$ENV_FILE" || exit 1
  exit 0
fi

# --self-update: refresh the install TOOLING from upstream (G72). The image and
# the tree are two different things; this updates the tree, and only the tree.
# Instance state (.env, secrets/, data/, docker-compose.override.yml) is never
# touched. The script does not re-exec itself afterwards -- a script replacing
# itself mid-run is how an interrupted update leaves an unusable installer --
# so it reports what changed and asks for a re-run.
if [ "$SELF_UPDATE" = true ]; then
  info "Refreshing install tooling from $BB_INSTALL_TARBALL"
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  if ! curl -fsSL "$BB_INSTALL_TARBALL" | tar xz -C "$tmp" 2>/dev/null; then
    error "Could not download the install bundle. Tree left untouched."
    exit 1
  fi
  src="$(find "$tmp" -maxdepth 2 -name setup.sh -printf '%h\n' 2>/dev/null | head -1)"
  if [ -z "$src" ]; then
    error "Downloaded bundle contains no setup.sh. Tree left untouched."
    exit 1
  fi
  state="$(bb_tree_looks_valid "$src")" || {
    error "Downloaded bundle is not a valid install tree ($state). Tree left untouched."
    exit 1
  }

  missing="$(bb_tree_missing_flags "$SCRIPT_DIR/setup.sh" "$src/setup.sh")"
  backup="$SCRIPT_DIR/.tooling-backup-$(date -u +%Y%m%dT%H%M%SZ)"
  mkdir -p "$backup"
  while IFS= read -r f; do
    [ -e "$SCRIPT_DIR/$f" ] && cp -a "$SCRIPT_DIR/$f" "$backup/" 2>/dev/null || true
    [ -e "$src/$f" ] && cp -a "$src/$f" "$SCRIPT_DIR/$f" 2>/dev/null || true
  done < <(bb_tree_tooling_files)
  [ -d "$src/updater" ] && cp -a "$src/updater/." "$SCRIPT_DIR/updater/" 2>/dev/null || true
  chmod +x "$SCRIPT_DIR/setup.sh" 2>/dev/null || true

  success "Install tooling refreshed. Previous copies: $backup"
  if [ -n "$missing" ]; then
    info "Flags this instance did not have before:"
    printf '  %s\n' $missing
  else
    info "No new flags — the tooling was already current."
  fi
  info "Instance state (.env, secrets/, data/) was not touched."
  info "Re-run ./setup.sh --upgrade to apply the refreshed tooling."
  exit 0
fi

echo ""
echo "  ╔══════════════════════════════════════╗"
echo "  ║      BuildBud Self-Hosted Setup      ║"
echo "  ╚══════════════════════════════════════╝"
echo ""

# ─── Prerequisites ────────────────────────────────────────────────────────────
# Fresh-VPS auto-install (Coolify-style) so the whole install is one command.
# Privileged: installs Docker via the official get.docker.com convenience script
# and python3/openssl via the distro package manager. These mutate the host and
# run as root/sudo. Opt out with --no-install-deps for locked-down hosts (then
# the step only verifies and errors on anything missing).
info "Checking prerequisites..."

# Privilege helper: root -> run direct; else sudo if present.
if [ "$(id -u)" -eq 0 ]; then SUDO=""
elif command -v sudo &>/dev/null; then SUDO="sudo"
else SUDO=""; fi
_priv() { if [ -n "$SUDO" ]; then $SUDO "$@"; else "$@"; fi; }

# One-click host updater (design B): app writes a marker, this privileged host
# systemd path-unit applies the upgrade with DB dump + health gate + auto-rollback.
# Opt-in via --enable-one-click-update. Without it the Updates panel shows the copy-command.
# ─── Seed a git-ready starter project (fresh installs only) ───────────────────
# A brand-new instance otherwise lands the user on an empty board, and the first
# folder they open is usually git-less -> reactive "Git Repository Required"
# modal. Seed ONE canonical project that is already a git repo with an initial
# commit, so isolated worktree builds work on first click.
# Idempotent: skips when any project is already registered (incl. --upgrade).
# Opt out with --no-starter-project or SEED_STARTER=false.
seed_starter_project() {
  [ "$SEED_STARTER" = true ] || { info "Starter project seeding disabled (--no-starter-project)."; return 0; }
  info "Seeding starter project \"$STARTER_NAME\"..."
  local out
  if ! out=$(docker compose -f "$SCRIPT_DIR/docker-compose.yml" exec -T \
      -e BB_SEED_NAME="$STARTER_NAME" buildbud node - <<'SEEDJS' 2>&1
const NAME = process.env.BB_SEED_NAME || 'my-first-app';
const TOKEN = process.env.BUILDBUD_API_TOKEN || '';
const BASE = 'http://localhost:' + (process.env.PORT || '3001') + '/api';
const H = { 'Content-Type': 'application/json' };
if (TOKEN) H.Authorization = 'Bearer ' + TOKEN;
const jf = async (p, o) => {
  const r = await fetch(BASE + p, Object.assign({ headers: H }, o || {}));
  const t = await r.text();
  let b; try { b = JSON.parse(t); } catch { b = { raw: t }; }
  return { status: r.status, body: b };
};
(async () => {
  const list = await jf('/projects');
  if (list.status !== 200) { console.log('SEED_SKIP cannot list projects (status ' + list.status + ')'); return; }
  const existing = Array.isArray(list.body && list.body.data) ? list.body.data : [];
  if (existing.length > 0 && process.env.BB_SEED_FORCE !== '1') {
    console.log('SEED_SKIP ' + existing.length + ' project(s) already registered');
    return;
  }
  const rootRes = await jf('/projects/default-root');
  const root = rootRes.body && rootRes.body.data;
  if (!root) { throw new Error('no default projects root (status ' + rootRes.status + ')'); }
  const mk = await jf('/projects/create-folder', { method: 'POST', body: JSON.stringify({ location: root, name: NAME, initGit: true }) });
  const path = require('path');
  let dir = mk.body && mk.body.data;
  if (!dir && mk.status === 409) { dir = path.join(root, NAME); console.log('SEED_INFO reusing existing folder ' + dir); }
  if (!dir) { throw new Error('create-folder failed (status ' + mk.status + ')'); }
  // Give the initial commit something to contain.
  const fs = require('fs');
  const readme = path.join(dir, 'README.md');
  if (!fs.existsSync(readme)) {
    fs.writeFileSync(readme, '# ' + NAME + '\n\nYour first BuildBud project.\n\n' +
      'BuildBud builds in isolated git worktrees, so this folder is already a git\n' +
      'repository with one initial commit. Describe what you want built on the\n' +
      'Kanban board or in Chat, and BuildBud takes it from there.\n\n' +
      'Rename or delete this project any time - it is only here so your first\n' +
      'build has somewhere to run.\n');
  }
  const ignore = path.join(dir, '.gitignore');
  if (!fs.existsSync(ignore)) fs.writeFileSync(ignore, 'node_modules/\n.env\ndist/\n');
  const add = await jf('/projects', { method: 'POST', body: JSON.stringify({ path: dir, name: NAME }) });
  const proj = add.body && add.body.data;
  if (!proj || !proj.id) { throw new Error('register failed (status ' + add.status + ')'); }
  const gi = await jf('/projects/' + proj.id + '/git/init', { method: 'POST' });
  const g = (gi.body && gi.body.data) || {};
  console.log('SEED_OK ' + dir + ' id=' + proj.id + ' git=' + gi.status + ' hasCommits=' + !!g.hasCommits);
})().catch(e => { console.log('SEED_FAIL ' + ((e && e.message) || String(e))); process.exit(1); });
SEEDJS
  ); then
    warn "Could not seed the starter project (non-fatal): ${out:-unknown error}"
    warn "Create one in the app: New Project -> Start a new app."
    return 0
  fi
  case "$out" in
    *SEED_OK*)   success "Starter project ready: $STARTER_NAME (git initialized, first commit made)." ;;
    *SEED_SKIP*) info "Starter project not needed (${out#*SEED_SKIP })." ;;
    *)           warn "Starter project seeding returned: $out" ;;
  esac
}

install_host_updater() {
  local CTRL="${BB_CONTROL_DIR:-/var/lib/buildbud/update-control}"
  info "Installing one-click host updater (privileged, opt-in)..."
  _priv mkdir -p "$CTRL" /opt/buildbud/updater /etc/buildbud
  _priv chmod 0777 "$CTRL"   # markers only (non-sensitive); container writes request, host writes status
  _priv install -m 0755 "$SCRIPT_DIR/updater/buildbud-update-apply.sh" /opt/buildbud/updater/buildbud-update-apply.sh
  _priv install -m 0644 "$SCRIPT_DIR/updater/buildbud-update-apply.service" /etc/systemd/system/buildbud-update-apply.service
  _priv install -m 0644 "$SCRIPT_DIR/updater/buildbud-update-apply.path" /etc/systemd/system/buildbud-update-apply.path
  _priv sed -i "s#/var/lib/buildbud/update-control#${CTRL}#g" /etc/systemd/system/buildbud-update-apply.path
  printf 'BB_COMPOSE_FILE=%s\nBB_UPDATE_CONTROL_DIR=%s\n' "$SCRIPT_DIR/docker-compose.yml" "$CTRL" | _priv tee /etc/buildbud/updater.env >/dev/null
  _priv systemctl daemon-reload
  _priv systemctl enable --now buildbud-update-apply.path
  _priv touch "$CTRL/.host-updater-ready"
  success "One-click updater installed (DB dump + health gate + auto-rollback)."
}

detect_pkg_mgr() {
  if command -v apt-get &>/dev/null; then echo apt
  elif command -v dnf &>/dev/null; then echo dnf
  elif command -v yum &>/dev/null; then echo yum
  elif command -v apk &>/dev/null; then echo apk
  else echo none; fi
}

pkg_install() {  # pkg_install <pkg>...
  case "$(detect_pkg_mgr)" in
    apt) _priv apt-get update -qq && _priv apt-get install -y -qq "$@" ;;
    dnf) _priv dnf install -y -q "$@" ;;
    yum) _priv yum install -y -q "$@" ;;
    apk) _priv apk add --no-cache "$@" ;;
    *)   return 1 ;;
  esac
}

install_docker() {
  info "Docker not found — installing via get.docker.com ..."
  if [ "$(id -u)" -ne 0 ] && [ -z "$SUDO" ]; then
    error "Installing Docker needs root or sudo. Re-run as root."; exit 1
  fi
  curl -fsSL https://get.docker.com | _priv sh
  _priv systemctl enable --now docker 2>/dev/null \
    || _priv service docker start 2>/dev/null || true
}

if $INSTALL_DEPS; then
  # Base tools the installer + docker script need.
  for tool in curl tar; do
    command -v "$tool" &>/dev/null || { info "Installing $tool ..."; pkg_install "$tool" || warn "could not install $tool"; }
  done
  command -v docker &>/dev/null || install_docker
  # get.docker.com bundles the compose plugin; add explicitly if still absent.
  docker compose version &>/dev/null 2>&1 || pkg_install docker-compose-plugin || true
  command -v python3 &>/dev/null || { info "Installing python3 ..."; pkg_install python3 || true; }
  command -v openssl &>/dev/null || { info "Installing openssl ..."; pkg_install openssl || true; }
fi

# Hard verification — fail clearly if anything is still missing.
_missing=""
command -v docker &>/dev/null            || _missing="$_missing docker"
docker compose version &>/dev/null 2>&1  || _missing="$_missing docker-compose-v2"
command -v python3 &>/dev/null           || _missing="$_missing python3"
command -v openssl &>/dev/null           || _missing="$_missing openssl"
if [ -n "$_missing" ]; then
  error "Missing prerequisites:$_missing"
  if $INSTALL_DEPS; then
    error "Auto-install did not satisfy all deps on this distro. Install manually, then re-run:"
  else
    error "--no-install-deps set. Install these manually, then re-run:"
  fi
  error "  Docker: curl -fsSL https://get.docker.com | sh"
  error "  Deps:   <apt-get|dnf|yum|apk> install python3 openssl"
  exit 1
fi

# A docker binary on PATH is not Docker access. Every step after this one talks
# to the daemon, so check that here — with the remedy — instead of dying 200
# lines later on a raw socket error (G38). Docker may have just been installed,
# so give the daemon a moment to come up before judging it.
for _ in $(seq 1 30); do docker info &>/dev/null 2>&1 && break; sleep 1; done
case "$(docker_api_state)" in
  ok) ;;
  permission)
    error "Docker is installed but this user cannot use it (permission denied on /var/run/docker.sock)."
    error "  Remedy:  sudo usermod -aG docker $(id -un) && newgrp docker"
    error "  Or re-run this installer with sudo."
    exit 1 ;;
  nodaemon)
    error "Docker is installed but the daemon is not running."
    error "  Remedy:  sudo systemctl enable --now docker"
    exit 1 ;;
  *)
    error "Docker is installed but 'docker info' failed:"
    docker info 2>&1 | tail -5 >&2
    exit 1 ;;
esac

success "Prerequisites OK"

# ─── Upgrade path ─────────────────────────────────────────────────────────────
if $UPGRADE; then
  info "Upgrading BuildBud..."

  # Refresh docker-compose.yml from the published bundle.
  #
  # Without this an upgrade only ever pulls a new app image, so a fix that lives
  # in the compose can never reach an existing install. That is not theoretical:
  # the FalkorDB volume was mounted at /data while Redis writes to
  # /var/lib/falkordb/data, meaning NO self-host instance persisted its agent
  # memory, and every upgrade that recreated the container silently destroyed it.
  # The fix shipped, and would have reached nobody.
  #
  # The local file is always backed up first. Configuration belongs in .env, not
  # in this file, so replacing it is safe; if you did customise it, the backup
  # printed below is your copy.
  COMPOSE_URL="${BB_COMPOSE_URL:-https://raw.githubusercontent.com/SDotTatum/buildbud-install/main/docker-compose.yml}"
  _new_compose="$(mktemp)"
  if curl -fsSL --max-time 30 "$COMPOSE_URL" -o "$_new_compose" 2>/dev/null \
     && grep -q '^services:' "$_new_compose"; then
    if ! cmp -s "$_new_compose" "$SCRIPT_DIR/docker-compose.yml"; then
      _bak="$SCRIPT_DIR/docker-compose.yml.bak-upgrade-$(date +%Y%m%d-%H%M%S)"
      cp "$SCRIPT_DIR/docker-compose.yml" "$_bak"
      cp "$_new_compose" "$SCRIPT_DIR/docker-compose.yml"
      info "Updated docker-compose.yml from the published bundle (previous: $_bak)"
    fi
  else
    # Not fatal: an upgrade that cannot reach GitHub should still update the app.
    warn "Could not refresh docker-compose.yml from $COMPOSE_URL — continuing with the local copy"
  fi
  rm -f "$_new_compose"

  docker compose -f "$SCRIPT_DIR/docker-compose.yml" pull buildbud
  # `up -d` over the whole stack, not just buildbud: a refreshed compose can
  # change any service definition, and compose only recreates what actually
  # differs, so unchanged services are left running.
  docker compose -f "$SCRIPT_DIR/docker-compose.yml" up -d
  success "BuildBud upgraded!"
  [ "$ENABLE_ONECLICK" = true ] && install_host_updater
  exit 0
fi

# ─── Reset path ───────────────────────────────────────────────────────────────
if $RESET; then
  warn "This will delete ALL data and regenerate secrets. Continue? [y/N]"
  read -r confirm
  [[ "$confirm" =~ ^[Yy]$ ]] || exit 0
  docker compose -f "$SCRIPT_DIR/docker-compose.yml" down -v 2>/dev/null || true
  rm -f "$ENV_FILE"
  rm -rf "$SECRETS_DIR"
  info "Reset complete. Re-running setup..."
fi

# ─── Check if already configured ──────────────────────────────────────────────
if [[ -f "$ENV_FILE" ]]; then
  warn ".env already exists. Existing secrets will be preserved (re-run refreshes config only)."
  warn "Run with --upgrade to upgrade the app only, --reset to wipe all data."
  if [ -t 0 ]; then
    warn "Continue? [y/N]"
    read -r confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || { info "Exiting. Use --upgrade to update the app."; exit 0; }
  else
    info "Non-interactive re-run: preserving existing secrets and continuing."
  fi
fi

# ─── Preserve existing secrets on re-run ──────────────────────────────────────
# Rotating secrets on a re-run breaks a live instance: a new BUILDBUD_API_TOKEN
# locks out web login, a new POSTGRES_PASSWORD no longer matches the existing DB
# volume, and a new CREDENTIALS_ENCRYPTION_KEY orphans every stored credential.
# Read prior values from .env; the generators below only fill what is empty.
_keep() {
  [ -f "$ENV_FILE" ] || return 0
  grep -E "^$1=" "$ENV_FILE" | head -1 | cut -d= -f2- || true
}

# Same preservation for the domain: a re-run without --domain must not reset a
# configured instance back to localhost (wrong CORS origins -> blank app).
if ! $DOMAIN_SET; then
  _prev_domain="$(_keep BB_DOMAIN)"
  [ -n "$_prev_domain" ] && DOMAIN="$_prev_domain"
fi

# ─── Generate secrets ─────────────────────────────────────────────────────────
# ─── Claude auth (BYO — required for agents) ──────────────────────────────────
CLAUDE_CODE_OAUTH_TOKEN="${CLAUDE_CODE_OAUTH_TOKEN:-$(_keep CLAUDE_CODE_OAUTH_TOKEN)}"
ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY:-$(_keep ANTHROPIC_API_KEY)}"
OPENAI_API_KEY="${OPENAI_API_KEY:-$(_keep OPENAI_API_KEY)}"
if [[ -z "$CLAUDE_CODE_OAUTH_TOKEN" && -z "$ANTHROPIC_API_KEY" ]]; then
  warn "BuildBud agents need YOUR Claude auth (nothing is sent to us)."
  warn "Get an OAuth token with:  claude setup-token   (or use an Anthropic API key)."
  # Only prompt on a real terminal. A headless run (piped / nohup) skips cleanly
  # instead of no-op-reading a blank token into .env.
  if [ -t 0 ]; then
    read -r -p "Paste CLAUDE_CODE_OAUTH_TOKEN (or leave blank to set ANTHROPIC_API_KEY / edit .env later): " CLAUDE_CODE_OAUTH_TOKEN || true
    if [[ -z "$CLAUDE_CODE_OAUTH_TOKEN" ]]; then
      read -r -p "Paste ANTHROPIC_API_KEY (or leave blank to configure later in .env): " ANTHROPIC_API_KEY || true
    fi
  fi
fi
if [[ -z "$CLAUDE_CODE_OAUTH_TOKEN" && -z "$ANTHROPIC_API_KEY" ]]; then
  warn "No Claude auth set. The app will start, but agents stay idle until you add a token."
  warn "Easiest: open the app, then Settings -> API Key Setup and paste a token (it persists)."
  warn "Or: pass --claude-token <tok> (or CLAUDE_CODE_OAUTH_TOKEN=... env), or edit .env + --upgrade."
fi

info "Generating secrets..."
mkdir -p "$SECRETS_DIR"
chmod 700 "$SECRETS_DIR"

# Random passwords/keys — preserved from an existing .env, generated when absent
POSTGRES_PASSWORD="$(_keep POSTGRES_PASSWORD)"; POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-$(openssl rand -hex 24)}"
FALKORDB_PASSWORD="$(_keep FALKORDB_PASSWORD)"; FALKORDB_PASSWORD="${FALKORDB_PASSWORD:-$(openssl rand -hex 24)}"
JWT_SECRET="$(_keep JWT_SECRET)"; JWT_SECRET="${JWT_SECRET:-$(openssl rand -hex 32)}"
CREDENTIALS_ENCRYPTION_KEY="$(_keep CREDENTIALS_ENCRYPTION_KEY)"; CREDENTIALS_ENCRYPTION_KEY="${CREDENTIALS_ENCRYPTION_KEY:-$(openssl rand -hex 32)}"
BUILDBUD_API_TOKEN="$(_keep BUILDBUD_API_TOKEN)"; BUILDBUD_API_TOKEN="${BUILDBUD_API_TOKEN:-$(openssl rand -base64 32 | tr -d '+=/' | head -c 40)}"
BB_VERIFY_SERVICE_TOKEN="$(_keep BB_VERIFY_SERVICE_TOKEN)"; BB_VERIFY_SERVICE_TOKEN="${BB_VERIFY_SERVICE_TOKEN:-$(openssl rand -hex 24)}"
BB_GRAPH_API_TOKEN="$(_keep BB_GRAPH_API_TOKEN)"; BB_GRAPH_API_TOKEN="${BB_GRAPH_API_TOKEN:-$(openssl rand -hex 24)}"

# Ed25519 dispatch signing keypair
openssl genpkey -algorithm ed25519 -out "$SECRETS_DIR/dispatch-signing.pem" 2>/dev/null
openssl pkey -in "$SECRETS_DIR/dispatch-signing.pem" -pubout -out "$SECRETS_DIR/dispatch-signing.pub" 2>/dev/null
chmod 600 "$SECRETS_DIR/dispatch-signing.pem"
chmod 644 "$SECRETS_DIR/dispatch-signing.pub"

# Generate PostgREST JWT tokens (HS256, signed with JWT_SECRET)
# service_role token: full DB access
# anon token: read-only access
generate_jwt() {
  local role="$1"
  local secret="$2"
  python3 - "$role" "$secret" << 'PYEOF'
import sys, json, base64, hmac, hashlib, time

role = sys.argv[1]
secret = sys.argv[2]

def b64url(data):
    if isinstance(data, str):
        data = data.encode()
    return base64.urlsafe_b64encode(data).rstrip(b'=').decode()

header  = b64url(json.dumps({"alg":"HS256","typ":"JWT"}, separators=(',', ':')))
payload = b64url(json.dumps({
    "role": role,
    "iss": "buildbud",
    "iat": int(time.time()),
    "exp": int(time.time()) + 315360000  # 10 years
}, separators=(',', ':')))

msg = f"{header}.{payload}"
sig = b64url(hmac.new(secret.encode(), msg.encode(), hashlib.sha256).digest())
print(f"{msg}.{sig}")
PYEOF
}

SERVICE_ROLE_KEY=$(generate_jwt "service_role" "$JWT_SECRET")
ANON_KEY=$(generate_jwt "anon" "$JWT_SECRET")

success "Secrets generated"

# ─── Write .env ───────────────────────────────────────────────────────────────
# Derive CORS origins from the domain. The server rejects requests (incl. its OWN
# static assets) whose Origin is not allowlisted, so a self-host instance MUST
# include its own origin or the app renders BLANK (assets 500 -> no CSS/JS).
if [[ "$DOMAIN" == "localhost" ]]; then
  CORS_ORIGINS="http://localhost,https://localhost,http://localhost:3001"
else
  CORS_ORIGINS="https://${DOMAIN},http://${DOMAIN}"
fi

info "Writing .env..."
cat > "$ENV_FILE" << EOF
# BuildBud Self-Hosted — generated $(date -u '+%Y-%m-%dT%H:%M:%SZ')

# Domain (use your hostname for auto-HTTPS, localhost for local)
BB_DOMAIN=${DOMAIN}
CORS_ORIGINS=${CORS_ORIGINS}

# Registry (license-gated proxy). Image resolves to REGISTRY/buildbud:VERSION.
REGISTRY=hub.cutclouds.com
VERSION=${VERSION}

# Secrets
POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
JWT_SECRET=${JWT_SECRET}
CREDENTIALS_ENCRYPTION_KEY=${CREDENTIALS_ENCRYPTION_KEY}
FALKORDB_PASSWORD=${FALKORDB_PASSWORD}
BUILDBUD_API_TOKEN=${BUILDBUD_API_TOKEN}
BB_VERIFY_SERVICE_TOKEN=${BB_VERIFY_SERVICE_TOKEN}
BB_GRAPH_API_TOKEN=${BB_GRAPH_API_TOKEN}

# Claude auth (BYO — at least one required for agents)
CLAUDE_CODE_OAUTH_TOKEN=${CLAUDE_CODE_OAUTH_TOKEN}
ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY}
# Codex provider (optional): your OpenAI API key enables the bundled codex CLI
OPENAI_API_KEY=${OPENAI_API_KEY:-}

# PostgREST JWT tokens
SERVICE_ROLE_KEY=${SERVICE_ROLE_KEY}
ANON_KEY=${ANON_KEY}

# Cross-instance feedback loop (OPT-IN, outbound-only to the BuildBud hub).
# Set BB_FEEDBACK_ENABLED=1 to share task-completion learnings. Secrets are
# scrubbed before send. Update checks verify a signed manifest before reporting.
BB_FEEDBACK_ENABLED=${BB_FEEDBACK_ENABLED:-0}
BB_FEEDBACK_URL=${BB_FEEDBACK_URL:-https://feedback.cutclouds.com/feedback}
BB_UPDATE_URL=${BB_UPDATE_URL:-https://feedback.cutclouds.com/updates/${LICENSE_CHANNEL:-ea}}
BB_CONTROL_DIR=${BB_CONTROL_DIR:-/var/lib/buildbud/update-control}
BB_HUB_PUBKEY_PATH=${HOME}/.buildbud/hub-signing.pub
BB_LICENSE_PATH=${HOME}/.buildbud/license.json
EOF
chmod 600 "$ENV_FILE"
success ".env written"

# ─── Registry login (license-gated — no tailnet, no Gitea account) ────────────
# The BuildBud image is private but you reach it with just your LICENSE TOKEN.
# The maintainer issues you a license bundle (a JSON file). Its `pull` token is
# your docker-login credential against the public license-gated registry proxy.
# No Tailscale, no Gitea org membership.
REG_HOST="${BB_REGISTRY_HOST:-hub.cutclouds.com}"
info "Authenticating to the BuildBud registry ($REG_HOST) with your license..."

# Resolve the pull token: from a bundle file (--license / BB_LICENSE_FILE) or a
# raw token (BB_PULL_TOKEN).
PULL_TOKEN="${BB_PULL_TOKEN:-}"
if [[ -z "$PULL_TOKEN" ]]; then
  LIC="${LICENSE_FILE:-${BB_LICENSE_FILE:-}}"
  # Re-runs: fall back to the bundle persisted by a previous install so
  # ./setup.sh without --license keeps working on a configured instance.
  if [[ -z "$LIC" && -f "$HOME/.buildbud/license.json" ]]; then
    LIC="$HOME/.buildbud/license.json"
    info "Using persisted license bundle: $LIC"
  fi
  if [[ -z "$LIC" ]]; then
    read -r -p "Path to your BuildBud license bundle (.json): " LIC || true
  fi
  [[ -f "$LIC" ]] || { error "License bundle not found: '$LIC'. Ask the maintainer for your license.json."; exit 1; }
  PULL_TOKEN=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["pullToken"])' "$LIC" 2>/dev/null) \
    || { error "Could not read pullToken from '$LIC' (is it a valid license bundle?)."; exit 1; }
  # Persist the whole bundle for the feedback channel (P5/P6) — 0600.
  # Skip the copy when --license already points at the persisted bundle:
  # cp refuses same-file and would abort the script under set -e.
  mkdir -p "$HOME/.buildbud" && chmod 700 "$HOME/.buildbud"
  if [[ "$(readlink -f "$LIC")" != "$(readlink -f "$HOME/.buildbud/license.json" 2>/dev/null || true)" ]]; then
    cp "$LIC" "$HOME/.buildbud/license.json"
  fi
  chmod 600 "$HOME/.buildbud/license.json"
  # Extract reportToken/instanceId into .env (0600) so the container app can send
  # opt-in feedback — it cannot read the host's root:root 0600 license.json directly.
  REPORT_TOKEN=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("reportToken",""))' "$LIC" 2>/dev/null || true)
  INSTANCE_ID=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("instanceId",""))' "$LIC" 2>/dev/null || true)
  # Replace, never append: re-runs previously stacked duplicate lines.
  sed -i '/^BB_REPORT_TOKEN=/d;/^BB_INSTANCE_ID=/d' "$ENV_FILE"
  { echo "BB_REPORT_TOKEN=$REPORT_TOKEN"; echo "BB_INSTANCE_ID=$INSTANCE_ID"; } >> "$ENV_FILE"
fi

# Pin the hub's Ed25519 public key so the instance can verify signed update
# manifests (C2). This key is PUBLIC; the instance never gets the private key.
cat > "$HOME/.buildbud/hub-signing.pub" <<'PUBKEY'
-----BEGIN PUBLIC KEY-----
MCowBQYDK2VwAyEA7y2q+nWoBtQGpE4kAuLNJwDGFzFFtI2WtdNp9Qq8Axg=
-----END PUBLIC KEY-----
PUBKEY
chmod 644 "$HOME/.buildbud/hub-signing.pub"
# Also place the hub key where the container mount expects it (./secrets/hub-signing.pub).
# Written on every run (incl. --upgrade) so pre-existing installs get the mount source.
cp "$HOME/.buildbud/hub-signing.pub" "$SECRETS_DIR/hub-signing.pub" && chmod 644 "$SECRETS_DIR/hub-signing.pub"

echo "$PULL_TOKEN" | docker login "$REG_HOST" -u license --password-stdin \
  || { error "Registry login failed. Your license may be expired or revoked — contact the maintainer."; exit 1; }
success "License accepted — registry access granted"

# ─── Start stack ──────────────────────────────────────────────────────────────

info "Starting BuildBud stack..."
# A freshly (re)started dockerd can hit a transient container-name conflict
# during parallel create (e.g. buildbud-nats), so one retry is worth it. But a
# permission denial or a port conflict can NEVER succeed on a retry: retrying
# them only delays the install and buries the message that would have fixed it
# (G39). Classify first, retry only what a retry can help. Daemon reachability
# was already established in the prerequisite block.
STACK_LOG="$(mktemp)"
if ! docker compose -f "$SCRIPT_DIR/docker-compose.yml" up -d 2>&1 | tee "$STACK_LOG"; then
  case "$(classify_stack_error "$(cat "$STACK_LOG")")" in
    transient)
      warn "First stack start hit a transient error — retrying once..."
      sleep 3
      docker compose -f "$SCRIPT_DIR/docker-compose.yml" up -d
      ;;
    permission)
      error "Docker refused the connection: permission denied on the daemon socket."
      error "  Remedy:  sudo usermod -aG docker $(id -un) && newgrp docker"
      rm -f "$STACK_LOG"; exit 1
      ;;
    port-conflict)
      error "A host port BuildBud needs (80/443) is already in use."
      for _p in 80 443; do
        _h="$(port_holders "$_p")"
        [ -n "$_h" ] && { error "  :$_p held by:"; echo "$_h" >&2; }
      done
      error "  Free the port, or put BuildBud behind your existing proxy and"
      error "  remove the caddy 'ports:' mapping from docker-compose.yml."
      rm -f "$STACK_LOG"; exit 1
      ;;
    *)
      error "Stack start failed. The message above is the cause — a retry would not change it."
      rm -f "$STACK_LOG"; exit 1
      ;;
  esac
fi
rm -f "$STACK_LOG"

# ─── Wait for Postgres ────────────────────────────────────────────────────────
info "Waiting for Postgres to be healthy..."
MAX_WAIT=60
WAITED=0
until docker compose -f "$SCRIPT_DIR/docker-compose.yml" exec -T postgres pg_isready -U postgres -d buildbud &>/dev/null; do
  WAITED=$((WAITED + 2))
  if [[ $WAITED -ge $MAX_WAIT ]]; then
    error "Postgres did not become healthy in ${MAX_WAIT}s."
    docker compose -f "$SCRIPT_DIR/docker-compose.yml" logs postgres
    exit 1
  fi
  sleep 2
done
success "Postgres is healthy"

# ─── Wait for the app (green DB != working app) ───────────────────────────────
info "Waiting for the BuildBud app to answer /api/health..."
APP_WAIT=0
until docker compose -f "$SCRIPT_DIR/docker-compose.yml" exec -T buildbud sh -lc 'wget -qO- http://localhost:3001/api/health >/dev/null 2>&1 || curl -sf http://localhost:3001/api/health >/dev/null 2>&1' &>/dev/null; do
  APP_WAIT=$((APP_WAIT + 3))
  if [[ $APP_WAIT -ge 90 ]]; then
    warn "App did not answer /api/health in 90s. Check: docker compose logs buildbud"
    warn "(Common causes: image not pulled, or Claude auth not set.)"
    break
  fi
  sleep 3
done
[[ $APP_WAIT -lt 90 ]] && success "App is answering /api/health"

# Seed a starter project only when the app actually answered (needs the API).
if [[ $APP_WAIT -lt 90 ]]; then
  seed_starter_project
fi

# ─── Probe the entry point, THEN print it ─────────────────────────────────────
# The installer used to end with "BuildBud is running!" and a URL it had never
# fetched. Measured on a real install (bb-team, 2026-08-19): that URL answered
# 000 while every check the installer did run was green, because the health
# probe goes through the compose network and never through the entry point the
# user is told to open (G37). Probe what we advertise, and when it does not
# answer, say what does.
if [[ "$DOMAIN" == "localhost" ]]; then ENTRY_URL="http://localhost"; else ENTRY_URL="https://${DOMAIN}"; fi
info "Probing ${ENTRY_URL} ..."
ENTRY_CODE="$(probe_http "$ENTRY_URL")"

# ─── Print access info ────────────────────────────────────────────────────────
echo ""
echo "  ╔══════════════════════════════════════════════════════╗"
if entry_ok "$ENTRY_CODE"; then
  echo "  ║         BuildBud is running!                         ║"
else
  echo "  ║   BuildBud started — entry point NOT reachable        ║"
fi
echo "  ╠══════════════════════════════════════════════════════╣"
if entry_ok "$ENTRY_CODE"; then
  printf "  ║  URL:   %-45s║\n" "$ENTRY_URL (HTTP $ENTRY_CODE)"
else
  printf "  ║  URL:   %-45s║\n" "$ENTRY_URL (no answer)"
fi
echo "  ║  Token: ${BUILDBUD_API_TOKEN}"
echo "  ╠══════════════════════════════════════════════════════╣"
echo "  ║  Lost the token? ./setup.sh --show-token              ║"
echo "  ║  Manage:  docker compose logs -f                     ║"
echo "  ║  Upgrade: ./setup.sh --upgrade                       ║"
echo "  ║  Reset:   ./setup.sh --reset                         ║"
echo "  ╚══════════════════════════════════════════════════════╝"
echo ""
if ! entry_ok "$ENTRY_CODE"; then
  error "${ENTRY_URL} did not answer (curl status ${ENTRY_CODE}). The stack is up but"
  error "the front door is not. What IS reachable:"
  _direct="$(probe_http "http://127.0.0.1:3001/api/health")"
  if entry_ok "$_direct"; then
    error "  http://127.0.0.1:3001/api/health -> HTTP ${_direct}  (the app itself is fine)"
  else
    error "  http://127.0.0.1:3001/api/health -> ${_direct}  (the app is not answering either)"
  fi
  _pub="$(docker compose -f "$SCRIPT_DIR/docker-compose.yml" port caddy 80 2>/dev/null || true)"
  if [ -z "$_pub" ]; then
    error "  caddy publishes no host port — something else already holds :80/:443."
    for _p in 80 443; do
      _h="$(port_holders "$_p")"
      [ -n "$_h" ] && { error "  :$_p held by:"; echo "$_h" >&2; }
    done
    error "  Fix: free the port, or drop caddy's 'ports:' mapping and proxy to it yourself."
  else
    error "  caddy is published on ${_pub} — try that address, or check: docker compose logs caddy"
  fi
  echo ""
fi
# G42: state the return edge out loud. It ships OFF, and an installer that
# never mentions it leaves the operator with no way to know a choice was made.
FEEDBACK_STATE="${BB_FEEDBACK_ENABLED:-0}"
if [[ "$FEEDBACK_STATE" == "1" ]]; then
  info "Learning reports: ON — build learnings are sent to ${BB_FEEDBACK_URL:-the BuildBud hub}"
  info "  Turn off: set BB_FEEDBACK_ENABLED=0 in .env, then docker compose up -d buildbud"
else
  info "Learning reports: OFF — nothing about your builds leaves this machine"
  info "  Turn on:  set BB_FEEDBACK_ENABLED=1 in .env, then docker compose up -d buildbud"
fi
info "  Check:    curl -H \"Authorization: Bearer \$TOKEN\" http://localhost/api/feedback/status"
echo ""
info "Optional: harden this VPS (SSH + fail2ban + firewall):"
info "  sudo ./harden.sh            # dry-run preview"
info "  sudo ./harden.sh --apply    # apply (keep a 2nd session open!)"
[ "$ENABLE_ONECLICK" = true ] && install_host_updater
success "Setup complete!"
