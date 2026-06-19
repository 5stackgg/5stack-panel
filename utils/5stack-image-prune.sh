#!/bin/bash
#
# 5stack image prune
#
# Reclaims disk from superseded 5stack container images. Most 5stack images
# are deployed as ghcr.io/5stackgg/*:latest or another channel tag (such as
# :dev-sw). A re-pull moves that tag to the new digest and leaves the previous
# version behind untagged (a "dangling" image whose overlayfs snapshot keeps
# filling /var/lib/rancher/k3s/agent). This removes those superseded versions.
#
# An image that still holds a tag is always kept, running or not. That keeps
# the current game-server / game-streamer images, which usually are NOT
# running when this fires but must stay ready so a match start does not wait
# on a re-pull. It also keeps version pins: a node pinned to a plugin version
# runs its game-server image as :v<version>, a tag that never moves. After a
# pin change the old :v<version> image stays tagged and is kept, so superseded
# pins pile up until kubelet's disk-pressure image GC removes them (a known
# limitation).
#
# An image that a container on this node references (running, exited or
# created) is kept as well, even after its tag has moved on. CRI's RemoveImage
# does not refuse an image that is in use (only `crictl rmi --prune` checks),
# so that is filtered here. A plain `crictl rmi --prune` is not used: it
# removes every image that no container uses, which would also delete the idle
# but current game-server / game-streamer images.
#
# One case looks exactly like a superseded version: an image deployed by
# digest (name@sha256:...) that no container uses. It is pruned and pulled
# again the next time it is used.
#
# Installed and scheduled by setup_image_prune (utils/setup_image_prune.sh).
# Safe to run by hand.

set -o pipefail

# k3s ships crictl; prefer it on PATH, fall back to `k3s crictl`.
if command -v crictl >/dev/null 2>&1; then
  CRICTL=(crictl)
elif command -v k3s >/dev/null 2>&1; then
  CRICTL=(k3s crictl)
else
  echo "[5stack] image-prune: crictl not found, nothing to do"
  exit 0
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "[5stack] image-prune: jq not found, skipping"
  exit 0
fi

# Every image a container on this node still references (running, exited or
# created).
# Without that list nothing can be shown to be unused, so the run is skipped.
if ! IN_USE="$(
  "${CRICTL[@]}" ps -a -o json 2>/dev/null | jq -c '
    [.containers[]? | .imageRef?, .imageId?, .image.image? | strings | select(. != "")]
    | unique
  '
)" || [ -z "$IN_USE" ]; then
  echo "[5stack] image-prune: could not list containers, skipping"
  exit 0
fi

# Every image on this node. A failed, empty or unreadable listing is reported as
# such, not as "no superseded 5stack images".
if ! IMAGES="$("${CRICTL[@]}" images -o json 2>/dev/null)" || [ -z "$IMAGES" ] ||
  ! printf '%s\n' "$IMAGES" | jq -e '.images | type == "array"' >/dev/null 2>&1; then
  echo "[5stack] image-prune: could not list images, skipping"
  exit 0
fi

# Superseded = a 5stack image (matched by tag or digest) that holds no tag any
# more and that no container references. Pinned images (e.g. the pause
# sandbox) are never touched. The in-use list reaches jq as a file
# (--slurpfile), not on the command line, so its size has no argv limit.
mapfile -t STALE < <(
  printf '%s\n' "$IMAGES" | jq -r --slurpfile inuse <(printf '%s' "$IN_USE") '
    ($inuse[0] | map({key: ., value: true}) | from_entries) as $used
    | .images[]
    | select(.pinned != true)
    | select([.repoTags[]?, .repoDigests[]?] | any(contains("ghcr.io/5stackgg/")))
    | select([.repoTags[]? | select(contains("<none>") | not)] | length == 0)
    | select(any(.id, .repoDigests[]?; $used[.] == true) | not)
    | .id
  ' | sort -u
)

if [ "${#STALE[@]}" -eq 0 ]; then
  echo "[5stack] image-prune: no superseded 5stack images"
  exit 0
fi

removed=0
for id in "${STALE[@]}"; do
  [ -n "$id" ] || continue
  if "${CRICTL[@]}" rmi "$id" >/dev/null 2>&1; then
    echo "[5stack] image-prune: removed $id"
    removed=$((removed + 1))
  else
    # The runtime could not remove it right now - leave it for the next run.
    echo "[5stack] image-prune: skipped $id (removal failed)"
  fi
done

echo "[5stack] image-prune: removed $removed superseded image(s)"
