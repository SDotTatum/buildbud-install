# BuildBud — Self-Host Installer (Pre-Alpha)

Install BuildBud on your own VPS. Gated by a per-instance **license token** the
maintainer issues you — no Tailscale, no Git account.

## Quick start
```bash
curl -fsSL https://raw.githubusercontent.com/SDotTatum/buildbud-install/main/bootstrap.sh | bash
cd buildbud-install
./setup.sh --license /path/to/license.json --domain your.host.example
```

See **PRE-ALPHA-ACCESS.md** for access + **the install guide** for full steps.

## What's here
| File | Purpose |
|---|---|
| `bootstrap.sh` | one-line downloader |
| `setup.sh` | main installer (license login → generate secrets → boot stack) |
| `docker-compose.yml` | the self-contained stack (Postgres/PostgREST/FalkorDB/NATS/app/Caddy) |
| `Caddyfile` | TLS reverse proxy |
| `harden.sh` | optional VPS hardening (dry-run default) |
| `genesis/` | Project Genesis (host scan + new-project blueprint) |
| `init/` | DB roles + schema bootstrap |

BuildBud is pre-alpha — run it on a throwaway VPS you don't mind rebuilding.
