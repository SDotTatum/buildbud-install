#!/usr/bin/env bash
# buildbud-update-apply.sh — host-side privileged applier for one-click update.
# Design B (spec_selfhost_inapp_update.md v1): the app has NO docker/host access;
# it writes request.json into the control dir and this host unit does the upgrade.
# Fail-safe: always writes status.json, claims the request, DB-dumps best-effort,
# health-gates the new version, and ROLLS BACK to the previous image on failure.
set -uo pipefail

CONTROL_DIR="${BB_UPDATE_CONTROL_DIR:-/var/lib/buildbud/update-control}"
COMPOSE="${BB_COMPOSE_FILE:-/opt/buildbud/docker-compose.yml}"
REQ="$CONTROL_DIR/request.json"
STATUS="$CONTROL_DIR/status.json"
LOG="$CONTROL_DIR/apply.log"

ts(){ date -u +%FT%TZ; }
lg(){ printf '%s %s\n' "$(ts)" "$*" >>"$LOG" 2>/dev/null || true; }
st(){ # state phase message [target_version_json]
  printf '{"state":"%s","phase":"%s","message":"%s","updated_at":"%s","target_version":%s}\n' \
    "$1" "$2" "$3" "$(ts)" "${4:-null}" >"$STATUS" 2>/dev/null || true
}
dc(){ docker compose -f "$COMPOSE" "$@"; }

[ -f "$REQ" ] || exit 0
[ -f "$COMPOSE" ] || { st failed precheck "compose file not found"; exit 1; }

# Claim the request so a re-trigger cannot double-apply.
WORK="$REQ.processing"
mv -f "$REQ" "$WORK" 2>/dev/null || exit 0
TARGET_VER="$(sed -n 's/.*"target_version" *: *"\([^"]*\)".*/\1/p' "$WORK" | head -1)"
if [ -n "$TARGET_VER" ]; then TV="\"$TARGET_VER\""; else TV=null; fi
lg "apply requested target=$TARGET_VER"

# 1. record current image for rollback
st applying record "recording current version" "$TV"
CID="$(dc ps -q buildbud 2>/dev/null | head -1)"
PREV_IMG="$(docker inspect --format '{{.Image}}' "$CID" 2>/dev/null || true)"
IMG_REF="$(dc config 2>/dev/null | sed -n 's/^ *image: *\(.*buildbud:[^ ]*\).*/\1/p' | head -1)"
lg "prev_image=$PREV_IMG img_ref=$IMG_REF"

# 2. pre-update DB dump (best-effort; never blocks the apply)
st applying backup "backing up database" "$TV"
if dc exec -T postgres pg_dumpall -U postgres >"$CONTROL_DIR/pre-update-$(date -u +%Y%m%dT%H%M%SZ).sql" 2>/dev/null; then
  lg "db dump ok"; else lg "db dump skipped/failed (non-fatal)"; fi

# 3. pull + recreate the app (v2: pin to the digest-addressed target when the
#    manifest supplied one, so the apply is immune to the :prod tag drifting
#    between manifest-publish and apply; falls back to the compose tag pull).
st applying pull "pulling new image" "$TV"
TARGET_IMG="$(sed -n 's/.*"target_image" *: *"\([^"]*\)".*/\1/p' "$WORK" | head -1)"
if [ -n "$TARGET_IMG" ] && printf '%s' "$TARGET_IMG" | grep -q '@sha256:'; then
  if ! docker pull "$TARGET_IMG" >>"$LOG" 2>&1; then
    st failed pull "image pull failed"; mv -f "$WORK" "$REQ.failed" 2>/dev/null || true; exit 1
  fi
  [ -n "$IMG_REF" ] && docker tag "$TARGET_IMG" "$IMG_REF" >>"$LOG" 2>&1 || true
  lg "pulled digest-pinned $TARGET_IMG -> $IMG_REF"
elif ! dc pull buildbud >>"$LOG" 2>&1; then
  st failed pull "image pull failed"; mv -f "$WORK" "$REQ.failed" 2>/dev/null || true; exit 1
fi
st applying recreate "recreating container" "$TV"
dc up -d buildbud >>"$LOG" 2>&1 || true

# 4. health probe (~180s)
st applying health "waiting for health probe" "$TV"
ok=0
for _ in $(seq 1 60); do
  if dc exec -T buildbud sh -lc 'wget -qO- http://localhost:3001/api/health >/dev/null 2>&1 || curl -sf http://localhost:3001/api/health >/dev/null 2>&1'; then ok=1; break; fi
  sleep 3
done

if [ "$ok" = 1 ]; then
  st healthy done "update applied and healthy" "$TV"; lg "healthy"; rm -f "$WORK"
  # 4b. Reclaim the images this update orphaned.
  #
  # `docker compose pull` re-points the :prod tag and leaves the OLD image
  # untagged. Nothing ever removed those, so an instance accumulated one
  # ~4.4GB layer set per upgrade until the disk filled. Measured on a real
  # customer-shaped install (thesue, 2026-08-21): 38G disk at 95% with 26.8GB
  # of unused images, and a `docker compose pull` that died mid-extract with
  # `no space left on device`. A self-hosted instance has no operator watching
  # `docker system df`, so this has to be the product's job.
  #
  # Ordering is deliberate: prune only AFTER the health probe passes, never
  # before. Until health is confirmed, the previous image is the rollback
  # target and removing it would turn a bad update into an unrecoverable one.
  # PREV_IMG is re-tagged first so exactly one rollback target survives —
  # growth is bounded at two image sets rather than unbounded.
  if [ -n "$PREV_IMG" ]; then
    docker tag "$PREV_IMG" buildbud-rollback:previous >>"$LOG" 2>&1 || true
  fi
  before="$(df -P / | awk 'NR==2{print $4}')"
  docker image prune -f >>"$LOG" 2>&1 || true
  after="$(df -P / | awk 'NR==2{print $4}')"
  lg "pruned orphaned images: ${before}K -> ${after}K free (rollback target kept as buildbud-rollback:previous)"
else
  # 5. rollback: re-point the local tag to the previous image + recreate
  lg "unhealthy — rolling back to $PREV_IMG"
  st applying rollback "new version unhealthy — rolling back" "$TV"
  if [ -n "$PREV_IMG" ] && [ -n "$IMG_REF" ]; then
    docker tag "$PREV_IMG" "$IMG_REF" 2>>"$LOG" && dc up -d --force-recreate buildbud >>"$LOG" 2>&1 || true
  fi
  st rolled_back done "update failed health check; rolled back to the previous version"
  mv -f "$WORK" "$REQ.failed" 2>/dev/null || true
fi
