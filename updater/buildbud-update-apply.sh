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

# This script's own installed path, the copy of it the app image carries, and
# the opt-out (see the host-updater refresh block below / G227).
SELF="${BB_UPDATER_SELF:-${BASH_SOURCE[0]:-$0}}"
SELF_IN_IMAGE="${BB_UPDATER_IN_IMAGE:-/app/install/updater/buildbud-update-apply.sh}"
SELF_REFRESH="${BB_UPDATER_SELF_REFRESH:-1}"
HU_JSON=null       # host-updater report, published in status.json
HU_INSTALLED=""    # sha of the installed updater
HU_TARGET=""       # sha of the updater the release carries

ts(){ date -u +%FT%TZ; }
lg(){ printf '%s %s\n' "$(ts)" "$*" >>"$LOG" 2>/dev/null || true; }
st(){ # state phase message [target_version_json]
  printf '{"state":"%s","phase":"%s","message":"%s","updated_at":"%s","target_version":%s,"host_updater":%s}\n' \
    "$1" "$2" "$3" "$(ts)" "${4:-null}" "$HU_JSON" >"$STATUS" 2>/dev/null || true
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

# ─── Host-updater refresh (G227) ──────────────────────────────────────────────
#
# /opt/buildbud/updater/buildbud-update-apply.sh was installed ONLY by
# install_host_updater() in setup.sh (fresh install / --upgrade). A one-click
# apply swapped the app image and kept the script it ran with, so thesue -- the
# one customer-shaped install -- carried its 2026-08-21 updater through every
# release until the file was installed by hand on 2026-10-10, and every fix to
# the updater itself (the G226 reclaim, the G228 running.json) reached nobody.
#
# Where the new copy comes from: the app image carries the release's own
# install/ tree at /app/install/ (Dockerfile.web, `COPY install/ /app/install/`),
# so the updater that belongs with a release ships with it -- no network, no
# fetch from the public installer repo, nothing a customer host has to reach.
#
# It is read from the IMAGE, never from the running app container. A container's
# filesystem is its image plus a writable layer, so anything that could write
# /app/install/updater/ inside the app would be choosing the next script this
# host runs as root. The image is the artefact the apply pulled by digest and
# health-gated, so the copy is taken from a throwaway `docker create` container
# made from the image id, and that container is removed again on every path.
#
# Not breaking a working host is the whole job here:
#   * it installs only AFTER the health gate, so a release that never ran
#     cannot replace the updater, and an apply that fell back to the previous
#     image keeps the script that matches the app it restored;
#   * the candidate is staged beside the target and must be a regular file (a
#     symlink is refused outright: `docker cp` reproduces one from the image,
#     and every later test would then be answered by a file on the host),
#     non-empty, start with a shell shebang, mention BB_UPDATE_CONTROL_DIR (it
#     is our script, not whatever else that path resolved to) and parse under
#     `bash -n`. Any failure leaves the installed script untouched;
#   * it is installed with `mv` inside the same directory -- an atomic rename,
#     so no reader ever sees a half-written file, and THIS process keeps the
#     inode it is executing: the apply in flight finishes on the old script and
#     the next one runs the new script. Overwriting in place would corrupt the
#     running shell mid-script;
#   * the replaced script is kept next to it as *.prev;
#   * BB_UPDATER_SELF_REFRESH=0 in /etc/buildbud/updater.env turns the install
#     off and leaves the report, for an operator who pins the file by hand.
# Whatever happens, `host_updater` in status.json (and so GET
# /api/updates/apply/status) says what the host is left with, so a box that
# could not refresh reports stale instead of looking current.
#
# systemd units are deliberately NOT touched: buildbud-update-apply.{path,service}
# need a daemon-reload, and setup.sh rewrites the .path with the instance's
# control dir, so they are not comparable byte-for-byte. A unit change still
# needs `setup.sh --upgrade`; every updater fix so far has been in the script.
sha12(){ sha256sum "$1" 2>/dev/null | cut -c1-12; }

# The verdict key is `verdict`, not `state`: status.json is also read by shell
# (sed) in the installer tests, where a second "state":"..." on the line is
# picked up instead of the apply's own.
hu_report(){ # verdict [note]   (note must contain no '"' or '\')
  HU_JSON="$(printf '{"verdict":"%s","installed":"%s","target":"%s","note":"%s","checked_at":"%s"}' \
    "$1" "$HU_INSTALLED" "$HU_TARGET" "${2:-}" "$(ts)")"
  lg "host_updater: $1 installed=${HU_INSTALLED:-?} target=${HU_TARGET:-?} ${2:-}"
}

# Is this candidate our updater, and safe to install? The symlink test is
# FIRST: every later test ([ -f ], head, grep, bash -n) follows a link, so an
# image whose updater path is a symlink would have them all answered by a file
# on the host and the link itself would end up installed as the updater.
hu_vet(){ # path
  local p="$1"
  [ ! -L "$p" ] || { lg "host_updater: candidate is a symlink - refused"; return 1; }
  [ -f "$p" ] && [ -s "$p" ] || return 1
  head -1 "$p" | grep -q '^#!.*sh' || return 1
  grep -q 'BB_UPDATE_CONTROL_DIR' "$p" || return 1
  bash -n "$p" >>"$LOG" 2>&1 || return 1
}

# Copy the release's updater out of an IMAGE (not out of the running app -- see
# the block comment) and vet it. Echoes the staged path on success; on any
# failure nothing is left behind and it returns 1. The throwaway container is
# removed on every path, including when the copy or the vetting fails.
# rm -rf, not -f: if that path in the image is a directory or a symlink,
# `docker cp` reproduces it and a plain rm -f would leave it behind.
hu_stage(){ # image_id
  local img="$1" tmp="$SELF.new.$$" cid rc=0
  [ -n "$img" ] || return 1
  rm -rf "$tmp"
  cid="$(docker create "$img" 2>>"$LOG")" || return 1
  [ -n "$cid" ] || return 1
  docker cp "$cid:$SELF_IN_IMAGE" "$tmp" >>"$LOG" 2>&1 || rc=1
  docker rm -f "$cid" >>"$LOG" 2>&1 || lg "host_updater: could not remove staging container $cid"
  if [ "$rc" != 0 ] || ! hu_vet "$tmp"; then rm -rf "$tmp"; return 1; fi
  printf '%s' "$tmp"
}

# Report only: does the installed updater match the release that is RUNNING?
# Called before anything is changed, so even an apply that fails at pull leaves
# the staleness visible -- that was exactly thesue's situation. It is compared
# against the IMAGE the running container was created from, not the container.
hu_check(){ # image_id
  local staged
  [ -f "$SELF" ] || { hu_report unknown "installed updater not found"; return 0; }
  HU_INSTALLED="$(sha12 "$SELF")"
  staged="$(hu_stage "$1")" || { hu_report unknown "running release image carries no usable updater"; return 0; }
  HU_TARGET="$(sha12 "$staged")"
  if cmp -s "$staged" "$SELF"; then hu_report current "matches the running release"
  else hu_report stale "differs from the running release"; fi
  rm -f "$staged"
}

# Install the updater the new release shipped with. Never leaves the host
# without a working script: on every failure path the installed copy stays.
hu_refresh(){ # image_id
  local staged
  [ -f "$SELF" ] || { hu_report unknown "installed updater not found"; return 0; }
  HU_INSTALLED="$(sha12 "$SELF")"
  staged="$(hu_stage "$1")" || { hu_report stale "no usable updater in the new image at $SELF_IN_IMAGE"; return 0; }
  HU_TARGET="$(sha12 "$staged")"
  if cmp -s "$staged" "$SELF"; then rm -f "$staged"; hu_report current "already the version this release ships"; return 0; fi
  if [ "$SELF_REFRESH" = 0 ]; then rm -f "$staged"; hu_report stale "refresh disabled by BB_UPDATER_SELF_REFRESH=0"; return 0; fi
  cp -p "$SELF" "$SELF.prev" >>"$LOG" 2>&1 || true
  chmod 0755 "$staged" >>"$LOG" 2>&1 || true
  if mv -f "$staged" "$SELF" >>"$LOG" 2>&1; then
    hu_report refreshed "previous updater kept beside it as .prev"
  else
    rm -f "$staged"; hu_report stale "install failed; kept the working updater"
  fi
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
# Report the host updater against the IMAGE the running app came from, before
# anything changes (G227): an apply that dies at pull still says the host is
# stale. PREV_IMG is that image id, so nothing reads the app's writable layer.
if [ -n "$PREV_IMG" ]; then hu_check "$PREV_IMG"; else hu_report unknown "no running app image"; fi

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
  # The ONLY write of running.json (G228). status.json is overwritten by the next
  # request or failure, so the app reads what runs from here. A failed pull or a
  # rollback leaves it alone: the image it names is still the one running.
  RUN_IMG="$(docker inspect --format '{{.Image}}' "$(dc ps -q buildbud 2>/dev/null | head -1)" 2>/dev/null || true)"
  printf '{"version":%s,"image_id":"%s","updated_at":"%s"}\n' "$TV" "$RUN_IMG" "$(ts)" \
    >"$CONTROL_DIR/running.json.tmp" 2>/dev/null && mv -f "$CONTROL_DIR/running.json.tmp" "$CONTROL_DIR/running.json"
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
  # 4c. Leave the host with the updater this release ships (G227). Last, and
  #     only here: the release has proved healthy, so the script and the app it
  #     drives stay in step. Taken from NEW_IMG -- the image the apply pulled
  #     and health-gated -- not from the container now serving traffic.
  #     Re-publish the status so the report is final.
  if [ -n "$NEW_IMG" ]; then hu_refresh "$NEW_IMG"; else hu_report unknown "no app image after the apply"; fi
  st healthy done "update applied and healthy" "$TV"
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
