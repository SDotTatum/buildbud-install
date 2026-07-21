# BuildBud Project Genesis

Turns a blank (or existing) VPS into a real BuildBud project: inspect the host,
define intent, seed a living blueprint, generate agent instructions, and start
building from a shared source of truth. Genesis is the *front door* the deploy
machinery (`../setup.sh`, `../harden.sh`) sits behind.

Full plan + phases: `spec_project_genesis.md` in the ops repo.

## Available now

### `genesis start` — full orchestrator (G3)

Chains the pieces into one command: host scan (G1) -> living blueprint (G2) ->
agent context CLAUDE.md/AGENTS.md (#504). Every step is best-effort and
idempotent, so a re-run never clobbers human-authored sections. Run via the
backend CLI:

```bash
cd apps/backend
python -m cli.main --genesis start \
  --genesis-project-dir /path/to/new/project \
  --genesis-name MyApp \
  --genesis-intent-what "what the app is / does" \
  --genesis-intent-never "what it must never do"

python -m cli.main --genesis inspect --genesis-project-dir /path  # scan only
```

Produces: `INFRASTRUCTURE_SCAN.md`, `docs/blueprint/*` (9-file ledger), and
`CLAUDE.md` + `AGENTS.md` — all tuned to the scanned host + stated intent.

### `genesis update` — blueprint auto-sync (G4, the moat)

Keeps the blueprint current from git history instead of manual edits. Reads
`git diff <base>..HEAD` in the project, maps changed files to components, and
upserts the machine-maintained table in `docs/blueprint/built.md` (the region
between the `<!-- AUTOGEN:built-inventory -->` markers). Human-authored sections
(vision / decisions / roadmap) are never touched. Idempotent and best-effort.

```bash
cd apps/backend
python -m cli.main --genesis update \
  --genesis-project-dir /path/to/project \
  --genesis-base HEAD~1          # default; any git ref works (e.g. origin/main)
```

An optional `.blueprint-map.json` in the project root overrides the default
path-to-component heuristic:

```json
[{"pattern": "^apps/api/", "id": "api", "name": "API service", "layer": "L2"}]
```

### `genesis harden` — guided host hardening (P4)

Thin, safe wrapper over `../harden.sh` (SSH + fail2ban + UFW). **Dry-run by
default** — prints exactly what it would change and mutates nothing. Add
`--genesis-apply` to actually apply (double-gated: neither harden.sh nor the
wrapper mutates without it). Needs sudo (host-level changes) and keeps a
lock-out guard: it refuses to disable password auth unless the admin user
already has an authorized_keys entry.

```bash
cd apps/backend
sudo python -m cli.main --genesis harden --genesis-user deploy --genesis-ssh-port 22   # dry-run
sudo python -m cli.main --genesis harden --genesis-apply --genesis-user deploy          # apply
```

### `genesis refresh-state` — deploy-state sync (blueprint reflects LIVE)

On-demand, non-mutating. Reads an optional `.blueprint-state.json` mapping
components to a probe (HTTP GET / TCP port / `docker ps` container), runs each
probe, and flips the `activity` column of `built.md` to `active` (up) or
`dormant` (defined but down). Components without a probe stay `unverified`.
Human sections untouched. Idempotent.

```bash
cd apps/backend
python -m cli.main --genesis refresh-state --genesis-project-dir /path/to/project
```

`.blueprint-state.json` (in the project root, or `--genesis-state-file`):

```json
[
  {"id": "apps.api",   "http": "http://localhost:3007/api/health"},
  {"id": "service.db", "port": 5432},
  {"id": "apps.web",   "container": "buildbud-staging"}
]
```

### `genesis interview` — capture whole-project intent

Interactive Q&A that captures the project's intent (what it is, who it serves,
core workflows, boundaries, constraints) and writes `project-intent.json` — the
whole-project intent artifact the blueprint and future spec work read from.
`genesis start` runs this automatically when it has a TTY and no `--genesis-intent-*`
flags; headless it falls back to the flags (or skips, never hangs).

```bash
cd apps/backend
python -m cli.main --genesis interview --genesis-project-dir /path/to/project   # standalone
python -m cli.main --genesis start     --genesis-project-dir /path/to/project   # runs interview if interactive
```

### `inspect.sh` — host infrastructure scan (G1)

Read-only. Inspects OS, resources, listening ports, services, Docker, databases,
domains, firewall, CI, and any existing BuildBud install, then writes
`INFRASTRUCTURE_SCAN.md`. Runs no mutations; safe with or without sudo (more
detail with passwordless sudo). Its output seeds the blueprint's Infrastructure
section.

```bash
./inspect.sh                      # -> ./INFRASTRUCTURE_SCAN.md
./inspect.sh --out /path/scan.md  # custom path
./inspect.sh --stdout             # print instead of writing
```

## Coming (see the plan)

- Deeper spec-pipeline milestone planning from the captured project-intent.json
