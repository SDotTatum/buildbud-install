# BuildBud Self-Host — Pre-Alpha Access

BuildBud is in **pre-alpha**. The image is **not public**. Access is gated two ways:

1. **Tailscale tailnet** — the registry lives at a tailnet address, unreachable from the open internet. The maintainer invites you to the tailnet.
2. **Private Gitea org** — pulling the image requires a Gitea account that belongs to the private `buildbud` org.

## Getting access (ask the maintainer for)
- An invite to the Tailscale tailnet (install Tailscale, accept the invite).
- A Gitea account on `buildbud-infra.tail9f87a3.ts.net:3002` added to the `buildbud` org.
- (Optional) a read token for that account to avoid interactive login.

## Install
```bash
# interactive (prompts for the license + Claude token):
./install/setup.sh --license license.json --domain your.host.example
# non-interactive (headless — pass your Claude token so the instance is usable on boot):
./install/setup.sh --license license.json --domain your.host.example --claude-token <tok>
# or via env:
CLAUDE_CODE_OAUTH_TOKEN=<tok> ./install/setup.sh --license license.json --domain your.host.example
```
`setup.sh` logs in to the registry, generates all local secrets, and boots the
self-contained stack (Postgres + PostgREST + FalkorDB + NATS + bb-verify +
graph-api + app) on **your** infrastructure. Bring your own Claude auth: pass
`--claude-token`/`--anthropic-key`, set `CLAUDE_CODE_OAUTH_TOKEN`/`ANTHROPIC_API_KEY`
in the environment, or add it later in the app (Settings -> API Key Setup — it persists).
Get an OAuth token with `claude setup-token`.

## Signing in (and recovering the token)

The installer prints a `BUILDBUD_API_TOKEN` at the end of the run. That token is
the only way into a self-host instance — the Tailscale identity path needs a
`tailscaled` socket, which a customer VPS does not have and the compose file
does not mount, so it can never resolve there. Paste the token into the login
dialog the app shows on first load, or send it as `Authorization: Bearer <tok>`.

If you close that terminal, the token is still in the install's `.env`. Read it
back with:

```bash
./setup.sh --show-token
```

Run it from the directory you installed into. It prints the token on stdout and
nothing else, so it pipes cleanly:

```bash
curl -H "Authorization: Bearer $(./setup.sh --show-token)" https://your.host.example/api/health
```

If it reports the `.env` is missing you are in the wrong directory; if it
reports the token is empty, the install predates token auth — re-run
`./setup.sh --upgrade`.

## Revoking / going public later
Access is revoked by removing you from the tailnet or the Gitea org. When BuildBud
leaves pre-alpha, the image can be published publicly (ghcr) and this gating dropped.

## Hardening the VPS (optional, recommended)
BuildBud ships `install/harden.sh` — SSH hardening (disable root + password auth,
key-only, optional port change, AllowUsers), fail2ban, and a UFW firewall
(allow SSH + 80/443 + Tailscale, deny the rest).

**It can lock you out** if misused, so it is DRY-RUN by default and refuses to
disable password auth unless your user already has an SSH key installed.

```bash
sudo ./harden.sh --user you --ssh-port 22        # preview (changes nothing)
# review, keep a SECOND ssh session open, then:
sudo ./harden.sh --apply --user you --ssh-port 2222
# verify a fresh: ssh -p 2222 you@host   BEFORE closing the old session
```
