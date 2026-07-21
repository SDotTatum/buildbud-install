# BuildBud Self-Host — Pre-Alpha Access

BuildBud is in **pre-alpha**. Access is gated by a **per-instance license token** — a
small `license.json` file the maintainer issues to you. That token is your key to pull
the private image and (optionally) to connect the feedback channel. No accounts to
create, no networks to join.

## Getting access

Ask the maintainer for a **license bundle** (`license.json`). That's it — no Tailscale,
no Git account, nothing else.

## Install

```bash
# 1. Get the installer
curl -fsSL https://raw.githubusercontent.com/SDotTatum/buildbud-install/main/bootstrap.sh | bash
# (or clone this repo and run install/setup.sh directly)

# 2. Run setup with your license
cd buildbud-install
./setup.sh --license /path/to/license.json --domain your.host.example
```

`setup.sh` authenticates to the image registry with your license's pull token
(`docker login hub.cutclouds.com`), generates all local secrets, and boots the
self-contained stack (Postgres + PostgREST + FalkorDB + NATS + app + Caddy) on **your**
infrastructure. Bring your own Claude auth (`CLAUDE_CODE_OAUTH_TOKEN` or
`ANTHROPIC_API_KEY`).

## Revoking / going public later

Access is revoked by expiring or revoking your license — the maintainer does this
server-side; your next pull is denied. When BuildBud leaves pre-alpha, the base image
can be published publicly and this gating dropped.

## Hardening the VPS (optional, recommended)

BuildBud ships `harden.sh` — SSH hardening, fail2ban, and a UFW firewall. **It can lock
you out** if misused, so it is DRY-RUN by default and refuses to disable password auth
unless your user already has an SSH key installed.

```bash
sudo ./harden.sh --user you --ssh-port 22        # preview (changes nothing)
sudo ./harden.sh --apply --user you --ssh-port 2222   # apply (keep a 2nd session open!)
```
