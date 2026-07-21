# BuildBud Self-Host — Install Guide (Pre-Alpha)

> **DRAFT v0.2** — updated to the license-token install flow (no Tailscale, no Gitea).
> Validated end-to-end on a fresh VPS 2026-07-20. BuildBud is pre-alpha: run it on a
> throwaway VPS you don't mind rebuilding. Feedback welcome.

Blank VPS → running BuildBud instance on **your own infrastructure**, gated only by a
**license token** the maintainer gives you. ~20–30 min.

---

## 0. What you need first

**From the maintainer:**
- A **license bundle** — a small `license.json` file. It's your key to pull the image
  and (later) the feedback channel. Nothing else — no Tailscale invite, no Gitea account.

**Your own:**
- A **fresh VPS** — Ubuntu 22.04+/Debian 12+. **Min 4 GB RAM, 2 vCPU, 40 GB disk** (the
  stack runs ~6 containers; 8 GB comfortable).
- **Claude auth** — a `CLAUDE_CODE_OAUTH_TOKEN` (run `claude setup-token`) **or** an
  `ANTHROPIC_API_KEY`. Agents don't run without one (the app still boots).
- A **domain** you can point at the VPS, for a real `https://` URL (recommended).

---

## 1. Provision the VPS + SSH in

Create the VPS, add your SSH **public** key when prompted (generate one with
`ssh-keygen -t ed25519` if needed). Note the IP and login user (usually `root`).

```bash
ssh root@YOUR.VPS.IP
```

---

## 2. Create a non-root sudo user (before hardening)

```bash
adduser you && usermod -aG sudo you
mkdir -p /home/you/.ssh && cp ~/.ssh/authorized_keys /home/you/.ssh/
chown -R you:you /home/you/.ssh && chmod 700 /home/you/.ssh && chmod 600 /home/you/.ssh/authorized_keys
```
Verify `ssh you@YOUR.VPS.IP` works in a **new** terminal before continuing.

---

## 3. Install Docker + Compose v2

```bash
curl -fsSL https://get.docker.com | sh
sudo usermod -aG docker you    # re-login afterwards so `docker` works without sudo
docker compose version         # must print v2.x
```

---

## 4. Get the installer + your license

Download the BuildBud installer bundle (public — scripts only, no secrets):

```bash
# (pre-alpha: the maintainer sends you the install/ bundle or a download link)
mkdir -p ~/buildbud && cd ~/buildbud
# e.g. curl -fsSL https://<install-url>/install.tar.gz | tar xz
```

Put the **`license.json`** the maintainer gave you next to it (e.g. `~/buildbud/license.json`).

Have your Claude token ready (`claude setup-token` on any machine with the Claude CLI).

---

## 5. Run the installer

```bash
cd ~/buildbud/install
./setup.sh --license ~/buildbud/license.json --domain buildbud.yourdomain.com
```

`setup.sh` will:
1. Check Docker/Compose.
2. Ask for your **Claude token** (paste it, or leave blank to add to `.env` later).
3. Generate all local secrets.
4. **Authenticate to the registry with your license** — `docker login hub.cutclouds.com`
   using your license's pull token. No tailnet, no Gitea.
5. Pull the image and boot the stack; wait until the app answers `/api/health`.
6. Print your **URL** and **API token** — save both.

> **Using a domain?** Point an **A record** for `buildbud.yourdomain.com` at the VPS IP
> *before* this step so Caddy can issue TLS. The domain also becomes the app's allowed
> origin — wrong domain ⇒ the app loads blank.
>
> **No domain yet?** Use `--domain localhost` to validate the boot; reach it via an SSH
> tunnel: `ssh -L 8080:localhost:80 you@YOUR.VPS.IP`.

---

## 6. Open BuildBud

- **With a domain:** `https://buildbud.yourdomain.com`
- Log in with the **API token** the installer printed.

Manage the stack (from `~/buildbud/install`):
```bash
docker compose logs -f                 # follow logs
./setup.sh --upgrade                   # pull + restart the latest image
./setup.sh --reset                     # wipe and start over
```

---

## 7. Harden the VPS (recommended)

Dry-run by default; refuses to lock you out without a key present.
```bash
sudo ./harden.sh --user you --ssh-port 22        # preview — changes nothing
# review, keep a SECOND ssh session open, then:
sudo ./harden.sh --apply --user you --ssh-port 2222
ssh -p 2222 you@YOUR.VPS.IP                       # confirm BEFORE closing the old session
```

---

## 8. Start your first project (Genesis)

Genesis turns your instance into a real project — scans the host, interviews you, and
seeds a living blueprint the agents read.

```bash
cd ~/buildbud/install/genesis
./inspect.sh                                       # read-only host scan -> INFRASTRUCTURE_SCAN.md
```
Then, in the app container:
```bash
docker exec -it buildbud-app python3 -m cli.main --genesis interview --genesis-project-dir /path/to/project
docker exec -it buildbud-app python3 -m cli.main --genesis start     --genesis-project-dir /path/to/project
```
Produces `docs/blueprint/` + tuned `CLAUDE.md` / `AGENTS.md`. Keep it current as you build:
```bash
docker exec buildbud-app python3 -m cli.main --genesis update        --genesis-project-dir /path/to/project
docker exec buildbud-app python3 -m cli.main --genesis refresh-state  --genesis-project-dir /path/to/project
```

> Genesis project-dir mounting inside the app container is still being finalized for
> self-host — confirm with the maintainer.

---

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `Registry login failed` | License expired/revoked, or wrong `license.json`. Contact the maintainer. |
| App loads **blank** (no styling) | `--domain` didn't match the URL you visit → CORS blocks assets. Re-run with the correct domain. |
| App never answers `/api/health` | Image didn't pull, or no Claude auth. `docker compose logs buildbud`. |
| `graph-api` / `bb-verify` not running | Optional sidecars, off by default in pre-alpha. Core app is unaffected. |
| Locked out after harden | Provider web console; you set the wrong `--ssh-port`/`--user`. (Keep a 2nd session open.) |
| TLS cert not issued | A record not pointing at the VPS, or 80/443 blocked. |

---

## What changed from v0.1 (for maintainer notes)
- **Removed the entire Tailscale + Gitea-account requirement.** Access is now a single
  **license token** → `docker login hub.cutclouds.com` (license-gated Cloudflare-tunnel
  proxy). Validated on a fresh external VPS with zero tailnet.
- Registry is `hub.cutclouds.com`; default image tag `prod`.
- `graph-api` + `bb-verify` sidecars default-off (compose profiles) pending image fixes.

## Open items (maintainer)
1. **Installer delivery** (gap G-g): publish `install/` to a public URL / tarball (it has
   no secrets) so step 4 isn't manual.
2. **Sidecar images** (G-f `bb-verify`, G-j `graph-api`): fix so Insights/verification work.
3. **Genesis self-host project-dir mount** — finalize the volume story.

---

## Hosted (managed) option — no install

Don't want to run your own VPS? The maintainer can host an instance for you:

1. You get a **`<yourname>.cutclouds.com`** URL + an admin token.
2. Log in, connect your project, and start building — same BuildBud, we run the box.
3. Bring your own Claude auth the same way (paste your `CLAUDE_CODE_OAUTH_TOKEN` in Settings).

Your instance is isolated (its own database, network, and secrets) and can be revoked/torn
down at any time. Ask the maintainer for a hosted slot.
