# Licence expiry and recovery

Instances are licensed for a fixed term. The licence renews itself — a daily
timer (`buildbud-license-renew.timer`) tops it up well before expiry, and every
`--upgrade` renews first. You should never have to think about this.

This page is for when that did not happen.

## Symptom

`./setup.sh --upgrade` fails with something like:

```
401 Unauthorized
failed to resolve reference "hub.cutclouds.com/buildbud:prod"
```

The app itself keeps running. **An expired licence blocks updates and feedback
reporting; it does not stop your instance or your builds.** Nothing is lost by
taking a few minutes over this.

## Recovery

```bash
cd /path/to/buildbud-install
./setup.sh --self-update      # refresh the installer itself
./setup.sh --renew-license    # renew the licence and the registry credential
./setup.sh --upgrade          # now the pull works
```

**Why `--self-update` first.** The renewal logic lives in `setup.sh`, and the
normal way an instance receives a new `setup.sh` is `--upgrade` — which is the
thing that is broken. `--self-update` fetches the tooling from a public source
and needs no licence, so it works when nothing else does.

### If `--self-update` is not recognised

Your installer predates that flag. Re-run the bootstrap from your account:

1. Sign in at <https://cutclouds.com>
2. Copy your install command (it carries a one-time token)
3. Run it in place — configuration, data and secrets are preserved

### If renewal itself fails

`--renew-license` prints the reason and a remedy. The usual cause is no network
route to `hub.cutclouds.com`. If the licence has been revoked, renewal is
refused deliberately and the remedy is to sign in and download a fresh one:

```bash
./setup.sh --license /path/to/license.json
```

## Checking before it bites

The app shows licence state in its status banner once inside 7 days of expiry,
and `GET /api/diagnostics` reports it under the `license` check:

```bash
curl -s localhost:3001/api/diagnostics | python3 -m json.tool | grep -A4 '"license"'
```

Or read it directly on the host:

```bash
python3 -c 'import json,datetime
b=json.load(open("$HOME/.buildbud/license.json")); e=b["exp"]
e = e/1000 if e > 1e11 else e          # the hub mints milliseconds
print(datetime.datetime.fromtimestamp(e, datetime.UTC).isoformat())'
```

## Opting out of automatic renewal

Air-gapped or policy-restricted hosts can pass `--no-auto-renew`, which skips
installing the timer. Renewal then has to be run by hand before each expiry —
`--upgrade` will still attempt one.
