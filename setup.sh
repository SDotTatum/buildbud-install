#!/usr/bin/env bash
set -euo pipefail

# BuildBud Self-Hosted Setup
# Usage: ./setup.sh [--domain your.domain.com] [--upgrade] [--reset]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"
SECRETS_DIR="$SCRIPT_DIR/secrets"
VERSION="${VERSION:-prod}"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
info()    { echo -e "${BLUE}[BuildBud]${NC} $*"; }
success() { echo -e "${GREEN}[BuildBud]${NC} $*"; }
warn()    { echo -e "${YELLOW}[BuildBud]${NC} $*"; }
error()   { echo -e "${RED}[BuildBud]${NC} $*" >&2; }

# ─── Argument parsing ─────────────────────────────────────────────────────────
DOMAIN="localhost"
UPGRADE=false
RESET=false
LICENSE_FILE=""

while [[ $# -gt 0 ]]; do
  case $1 in
    --domain) DOMAIN="$2"; shift 2 ;;
    --license) LICENSE_FILE="$2"; shift 2 ;;
    --upgrade) UPGRADE=true; shift ;;
    --reset) RESET=true; shift ;;
    *) error "Unknown option: $1"; exit 1 ;;
  esac
done

echo ""
echo "  ╔══════════════════════════════════════╗"
echo "  ║      BuildBud Self-Hosted Setup      ║"
echo "  ╚══════════════════════════════════════╝"
echo ""

# ─── Prerequisites ────────────────────────────────────────────────────────────
info "Checking prerequisites..."

if ! command -v docker &>/dev/null; then
  error "Docker is not installed. Install it from https://docs.docker.com/get-docker/"
  exit 1
fi

if ! docker compose version &>/dev/null 2>&1; then
  error "Docker Compose v2 is not installed."
  exit 1
fi

if ! command -v python3 &>/dev/null; then
  error "python3 is required for key generation."
  exit 1
fi

if ! command -v openssl &>/dev/null; then
  error "openssl is required for signing key generation."
  exit 1
fi

success "Prerequisites OK"

# ─── Upgrade path ─────────────────────────────────────────────────────────────
if $UPGRADE; then
  info "Upgrading BuildBud..."
  docker compose -f "$SCRIPT_DIR/docker-compose.yml" pull buildbud
  docker compose -f "$SCRIPT_DIR/docker-compose.yml" up -d buildbud
  success "BuildBud upgraded!"
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
  warn ".env already exists. Re-running setup will regenerate secrets."
  warn "Run with --upgrade to upgrade the app only, --reset to wipe all data."
  warn "Continue and regenerate secrets? [y/N]"
  read -r confirm
  [[ "$confirm" =~ ^[Yy]$ ]] || { info "Exiting. Use --upgrade to update the app."; exit 0; }
fi

# ─── Generate secrets ─────────────────────────────────────────────────────────
# ─── Claude auth (BYO — required for agents) ──────────────────────────────────
CLAUDE_CODE_OAUTH_TOKEN="${CLAUDE_CODE_OAUTH_TOKEN:-}"
ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY:-}"
if [[ -z "$CLAUDE_CODE_OAUTH_TOKEN" && -z "$ANTHROPIC_API_KEY" ]]; then
  warn "BuildBud agents need YOUR Claude auth (nothing is sent to us)."
  warn "Get an OAuth token with:  claude setup-token   (or use an Anthropic API key)."
  read -r -p "Paste CLAUDE_CODE_OAUTH_TOKEN (or leave blank to set ANTHROPIC_API_KEY / edit .env later): " CLAUDE_CODE_OAUTH_TOKEN || true
  if [[ -z "$CLAUDE_CODE_OAUTH_TOKEN" ]]; then
    read -r -p "Paste ANTHROPIC_API_KEY (or leave blank to configure later in .env): " ANTHROPIC_API_KEY || true
  fi
fi
if [[ -z "$CLAUDE_CODE_OAUTH_TOKEN" && -z "$ANTHROPIC_API_KEY" ]]; then
  warn "No Claude auth set — the app will start but agents will fail until you add"
  warn "CLAUDE_CODE_OAUTH_TOKEN or ANTHROPIC_API_KEY to .env and re-run --upgrade."
fi

info "Generating secrets..."
mkdir -p "$SECRETS_DIR"
chmod 700 "$SECRETS_DIR"

# Random passwords/keys
POSTGRES_PASSWORD=$(openssl rand -hex 24)
FALKORDB_PASSWORD=$(openssl rand -hex 24)
JWT_SECRET=$(openssl rand -hex 32)
CREDENTIALS_ENCRYPTION_KEY=$(openssl rand -hex 32)
BUILDBUD_API_TOKEN=$(openssl rand -base64 32 | tr -d '+=/' | head -c 40)
BB_VERIFY_SERVICE_TOKEN=$(openssl rand -hex 24)
BB_GRAPH_API_TOKEN=$(openssl rand -hex 24)

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
  if [[ -z "$LIC" ]]; then
    read -r -p "Path to your BuildBud license bundle (.json): " LIC || true
  fi
  [[ -f "$LIC" ]] || { error "License bundle not found: '$LIC'. Ask the maintainer for your license.json."; exit 1; }
  PULL_TOKEN=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["pullToken"])' "$LIC" 2>/dev/null) \
    || { error "Could not read pullToken from '$LIC' (is it a valid license bundle?)."; exit 1; }
  # Persist the whole bundle for the feedback channel (P5/P6) — 0600.
  mkdir -p "$HOME/.buildbud" && chmod 700 "$HOME/.buildbud"
  cp "$LIC" "$HOME/.buildbud/license.json" && chmod 600 "$HOME/.buildbud/license.json"
fi

# Pin the hub's Ed25519 public key so the instance can verify signed update
# manifests (C2). This key is PUBLIC; the instance never gets the private key.
cat > "$HOME/.buildbud/hub-signing.pub" <<'PUBKEY'
-----BEGIN PUBLIC KEY-----
MCowBQYDK2VwAyEA7y2q+nWoBtQGpE4kAuLNJwDGFzFFtI2WtdNp9Qq8Axg=
-----END PUBLIC KEY-----
PUBKEY
chmod 644 "$HOME/.buildbud/hub-signing.pub"

echo "$PULL_TOKEN" | docker login "$REG_HOST" -u license --password-stdin \
  || { error "Registry login failed. Your license may be expired or revoked — contact the maintainer."; exit 1; }
success "License accepted — registry access granted"

# ─── Start stack ──────────────────────────────────────────────────────────────

info "Starting BuildBud stack..."
docker compose -f "$SCRIPT_DIR/docker-compose.yml" up -d

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

# ─── Print access info ────────────────────────────────────────────────────────
echo ""
echo "  ╔══════════════════════════════════════════════════════╗"
echo "  ║         BuildBud is running!                         ║"
echo "  ╠══════════════════════════════════════════════════════╣"
if [[ "$DOMAIN" == "localhost" ]]; then
  echo "  ║  URL:   http://localhost                             ║"
else
  echo "  ║  URL:   https://${DOMAIN}"
fi
echo "  ║  Token: ${BUILDBUD_API_TOKEN}"
echo "  ╠══════════════════════════════════════════════════════╣"
echo "  ║  Manage:  docker compose logs -f                     ║"
echo "  ║  Upgrade: ./setup.sh --upgrade                       ║"
echo "  ║  Reset:   ./setup.sh --reset                         ║"
echo "  ╚══════════════════════════════════════════════════════╝"
echo ""
info "Optional: harden this VPS (SSH + fail2ban + firewall):"
info "  sudo ./harden.sh            # dry-run preview"
info "  sudo ./harden.sh --apply    # apply (keep a 2nd session open!)"
success "Setup complete!"
