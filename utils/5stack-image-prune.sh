#!/bin/bash
#
# 5stack image prune
#
# Reclaims disk from superseded 5stack container images. Every 5stack image is
# deployed as ghcr.io/5stackgg/*:latest, so when a node pulls a new build the
# :latest tag moves to the new digest and the previous version is left behind
# untagged (a "dangling" image whose overlayfs snapshot keeps filling
# /var/lib/rancher/k3s/agent). This removes those superseded versions.
#
# The image that currently holds a :latest tag is always kept - including
# game-server / game-streamer, which usually are NOT running when this fires
# but must stay ready so a match start does not wait on a re-pull. Because we
# key off the tag (not "is it running"), a plain `crictl rmi --prune` is not
# used: that would delete the idle-but-current game-server / game-streamer
# images too.
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

# Superseded = a 5stack image (matched by tag or digest) that no longer carries
# a :latest tag. Pinned images (e.g. the pause sandbox) are never touched.
mapfile -t STALE < <(
  "${CRICTL[@]}" images -o json 2>/dev/null | jq -r '
    .images[]
    | select(.pinned != true)
    | select([.repoTags[]?, .repoDigests[]?] | any(contains("ghcr.io/5stackgg/")))
    | select((.repoTags // []) | any(endswith(":latest")) | not)
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
    # Still referenced by a (terminating) container, or busy - leave it for the
    # next run. Removing it would not stop a running container anyway.
    echo "[5stack] image-prune: skipped $id (in use or busy)"
  fi
done

echo "[5stack] image-prune: removed $removed superseded image(s)"
