#!/usr/bin/env bash
set -euo pipefail
#
# BuildBud VPS hardening — SSH + fail2ban + UFW firewall.
#
# SAFETY: SSH hardening can LOCK YOU OUT. This script is DRY-RUN by default —
# it prints exactly what it would change and refuses to disable password auth
# unless a non-root user with an authorized_keys entry already exists. Review
# the dry-run, keep a second session open, THEN re-run with --apply.
#
# Usage:
#   ./harden.sh [--user <name>] [--ssh-port <port>]            # dry-run (default)
#   ./harden.sh --apply [--user <name>] [--ssh-port <port>]    # actually apply
#
# Defaults: --user = the invoking sudo user, --ssh-port = 22 (unchanged).

RED='\033[0;31m'; GRN='\033[0;32m'; YLW='\033[1;33m'; BLU='\033[0;34m'; NC='\033[0m'
info(){ echo -e "${BLU}[harden]${NC} $*"; }
ok(){ echo -e "${GRN}[harden]${NC} $*"; }
warn(){ echo -e "${YLW}[harden]${NC} $*"; }
err(){ echo -e "${RED}[harden]${NC} $*" >&2; }

APPLY=false
ADMIN_USER="${SUDO_USER:-$(id -un)}"
SSH_PORT=22
while [[ $# -gt 0 ]]; do case $1 in
  --apply) APPLY=true; shift;;
  --user) ADMIN_USER="$2"; shift 2;;
  --ssh-port) SSH_PORT="$2"; shift 2;;
  *) err "unknown option: $1"; exit 1;; esac; done

if [[ $EUID -ne 0 ]]; then err "Run with sudo (host-level changes)."; exit 1; fi
$APPLY && MODE="APPLY" || MODE="DRY-RUN"
echo ""; info "BuildBud hardening — mode: ${MODE}"
info "  admin user: ${ADMIN_USER}   ssh port: ${SSH_PORT}"; echo ""

# ── Lock-out guards ───────────────────────────────────────────────────────────
if ! id "$ADMIN_USER" &>/dev/null; then err "User '$ADMIN_USER' does not exist."; exit 1; fi
AUTH_KEYS="$(getent passwd "$ADMIN_USER" | cut -d: -f6)/.ssh/authorized_keys"
if [[ ! -s "$AUTH_KEYS" ]]; then
  err "No SSH keys in $AUTH_KEYS for '$ADMIN_USER'."
  err "Disabling password auth now would LOCK YOU OUT. Add a key first:"
  err "  ssh-copy-id -p ${SSH_PORT} ${ADMIN_USER}@<host>"
  exit 1
fi
ok "Lock-out guard passed: '$ADMIN_USER' has authorized_keys."

run(){ if $APPLY; then eval "$1"; else echo "    would run: $1"; fi; }

# ── 1. SSH hardening (drop-in, validated before reload) ───────────────────────
info "1) SSH hardening → /etc/ssh/sshd_config.d/99-buildbud-harden.conf"
DROP="/etc/ssh/sshd_config.d/99-buildbud-harden.conf"
read -r -d '' SSHD_CONF <<EOF || true
# Managed by BuildBud harden.sh — do not edit by hand.
Port ${SSH_PORT}
PermitRootLogin no
PasswordAuthentication no
PubkeyAuthentication yes
ChallengeResponseAuthentication no
KbdInteractiveAuthentication no
AllowUsers ${ADMIN_USER}
X11Forwarding no
MaxAuthTries 3
LoginGraceTime 30
EOF
if $APPLY; then
  cp -a /etc/ssh/sshd_config "/etc/ssh/sshd_config.buildbud-backup.$(date +%s)" 2>/dev/null || true
  printf '%s\n' "$SSHD_CONF" > "$DROP"
  if sshd -t; then
    systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || service ssh reload
    ok "SSH hardened (config validated + reloaded). Port ${SSH_PORT}, root+password OFF."
    warn "KEEP THIS SESSION OPEN. Verify a NEW ssh -p ${SSH_PORT} ${ADMIN_USER}@host works before closing."
  else
    err "sshd -t FAILED — removing drop-in, NOT reloading (no lock-out)."; rm -f "$DROP"; exit 1
  fi
else
  echo "    would write $DROP:"; printf '%s\n' "$SSHD_CONF" | sed 's/^/      /'
  echo "    would run: sshd -t && systemctl reload ssh"
fi

# ── 2. fail2ban (ssh jail) ────────────────────────────────────────────────────
info "2) fail2ban (bans brute-force SSH)"
run "DEBIAN_FRONTEND=noninteractive apt-get update -qq && apt-get install -y -qq fail2ban"
if $APPLY; then
  cat > /etc/fail2ban/jail.d/buildbud-sshd.conf <<EOF
[sshd]
enabled = true
port    = ${SSH_PORT}
maxretry = 4
bantime = 1h
findtime = 10m
EOF
  systemctl enable --now fail2ban && ok "fail2ban enabled (sshd jail, port ${SSH_PORT})."
else
  echo "    would write /etc/fail2ban/jail.d/buildbud-sshd.conf (sshd jail, port ${SSH_PORT})"
fi

# ── 3. UFW firewall (ssh + http/https + tailscale; deny the rest) ─────────────
info "3) UFW firewall — allow ${SSH_PORT}/tcp, 80, 443, Tailscale; default deny inbound"
run "DEBIAN_FRONTEND=noninteractive apt-get install -y -qq ufw"
run "ufw --force reset >/dev/null 2>&1 || true"
run "ufw default deny incoming"
run "ufw default allow outgoing"
run "ufw allow ${SSH_PORT}/tcp"
run "ufw allow 80/tcp"
run "ufw allow 443/tcp"
run "ufw allow in on tailscale0 2>/dev/null || ufw allow 41641/udp"   # Tailscale
$APPLY && { ufw --force enable && ok "UFW enabled."; } || echo "    would run: ufw --force enable"

echo ""
if $APPLY; then
  ok "Hardening applied. ⚠️  Verify a fresh SSH login on port ${SSH_PORT} BEFORE closing this session."
else
  warn "DRY-RUN complete — nothing changed. Review above, keep a backup session, then: sudo ./harden.sh --apply --user ${ADMIN_USER} --ssh-port ${SSH_PORT}"
fi
