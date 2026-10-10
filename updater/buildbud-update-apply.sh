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

# Remove every local image of the app repo (and old rollback tags) EXCEPT the
# image IDs given as arguments, then drop dangling layers (G226).
#
# `docker image prune -f` alone reclaimed nothing on a real install: the v2
# apply pulls by digest (repo@sha256:...), and an image pulled that way keeps a
# repo-digest reference after :prod moves on, so it is never "dangling". thesue
# logged "pruned orphaned images: 2033968K -> 2033968K free" on every apply
# while six old 4.6GB images filled its 38G disk, and the next pull died
# extracting a layer. Selecting by repository catches both shapes.
reclaim_images(){ # phase keep_id...
  local phase="$1"; shift
  local repo="${IMG_REF%:*}" id k keep before after n=0
  [ -n "$repo" ] && [ "$#" -gt 0 ] || { lg "reclaim($phase) skipped: repo='$repo' keep=$#"; return 0; }
  before="$(df -P / | awk 'NR==2{print $4}')"
  for id in $( { docker images --no-trunc --format '{{.ID}}' "$repo"; \
                 docker images --no-trunc --format '{{.ID}}' buildbud-rollback; } 2>/dev/null | sort -u); do
    keep=0
    for k in "$@"; do [ "$id" = "$k" ] && keep=1; done
    [ "$keep" = 1 ] && continue
    docker rmi -f "$id" >>"$LOG" 2>&1 && n=$((n+1))
  done
  docker image prune -f >>"$LOG" 2>&1 || true
  after="$(df -P / | awk 'NR==2{print $4}')"
  lg "reclaim($phase): removed $n image(s), ${before}K -> ${after}K free (kept: $*)"
}

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
# 2b. Make room BEFORE pulling. A disk that a broken prune already filled can
#     otherwise never pull again, so the box could not even install the fix.
#     Keeps the running image and the current rollback target; nothing else of
#     ours is needed until the new image is healthy.
st applying reclaim "freeing disk space" "$TV"
RB_IMG="$(docker image inspect --format '{{.Id}}' buildbud-rollback:previous 2>/dev/null || true)"
if [ -n "$PREV_IMG" ]; then reclaim_images pre-pull "$PREV_IMG" $RB_IMG; else lg "reclaim(pre-pull) skipped: no running app image"; fi

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
  NEW_CID="$(dc ps -q buildbud 2>/dev/null | head -1)"
  NEW_IMG="$(docker inspect --format '{{.Image}}' "$NEW_CID" 2>/dev/null || true)"
  if [ -n "$NEW_IMG" ] && [ -n "$PREV_IMG" ]; then
    reclaim_images post-healthy "$NEW_IMG" "$PREV_IMG"
  else
    # Without both IDs we cannot tell the rollback target from an orphan; leave
    # them all and only drop dangling layers.
    docker image prune -f >>"$LOG" 2>&1 || true
    lg "reclaim(post-healthy) limited to dangling: new='$NEW_IMG' prev='$PREV_IMG'"
  fi
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
