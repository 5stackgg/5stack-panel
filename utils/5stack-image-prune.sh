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
# does not refuse an image that is in use, so that is filtered here.
#
# With --after-update (run once by update.sh, shortly after an update) it also
# removes old versions of non-5stack images: ones that no container uses and
# that are either untagged, or tagged under a repository whose image a
# container does use (cert-manager v1.17.1 once v1.17.2 is running). Those
# keep their tag after a version bump, so the weekly run never catches them.
#
# One case looks exactly like a superseded version: an image deployed by
# digest (name@sha256:...) that no container uses. It is pruned and pulled
# again the next time it is used.
#
# Installed and scheduled by setup_image_prune (utils/setup_image_prune.sh).
# Safe to run by hand.

set -o pipefail

AFTER_UPDATE=false
if [ "$1" = "--after-update" ]; then
  AFTER_UPDATE=true
fi

# k3s's own crictl first: a separate crictl on PATH (cri-tools from a package)
# is not pointed at the k3s containerd socket, and the k3s installer skips its
# crictl symlink when one already exists. --timeout because removing a
# multi-GB image waits for its snapshots to be deleted, which can take longer
# than crictl's 2s default.
if command -v k3s >/dev/null 2>&1; then
  CRICTL=(k3s crictl --timeout 120s)
elif command -v crictl >/dev/null 2>&1; then
  CRICTL=(crictl --timeout 120s)
else
  echo "[5stack] image-prune: crictl not found"
  exit 1
fi

# Images are listed before containers: a container created in between then
# shows up in the container list, so its image is never removed from under it.
# `images -v` prints one field per line (ID / RepoTags / RepoDigests / Pinned),
# which is what lets this run without jq.
if ! IMAGES="$("${CRICTL[@]}" images -v 2>/dev/null)" || ! grep -q '^ID: ' <<<"$IMAGES"; then
  echo "[5stack] image-prune: could not list images"
  exit 1
fi

# Every image a container on this node still references (running, exited or
# created). The refs are plain sha256 ids / digests, so grep is enough.
if ! CONTAINERS="$("${CRICTL[@]}" ps -a -o json 2>/dev/null)" || ! grep -q '"containers"' <<<"$CONTAINERS"; then
  echo "[5stack] image-prune: could not list containers"
  exit 1
fi
IN_USE="$(grep -oE '"(imageRef|imageId|image)": *"[^"]+"' <<<"$CONTAINERS" | sed -E 's/^"[^"]+": *"//; s/"$//' | sort -u)"

# Pinned images (e.g. the pause sandbox) are never touched. The in-use list
# reaches awk as a file, not on the command line, so its size has no argv limit.
if ! STALE="$(
  awk -v after_update="$AFTER_UPDATE" '
    function repo(ref) {
      sub(/@.*/, "", ref)
      sub(/:[^:\/]*$/, "", ref)
      return ref
    }
    FILENAME == ARGV[1] { if ($0 != "") used[$0] = 1; next }
    /^ID: /          { n++; id[n] = substr($0, 5); next }
    /^RepoTags: /    { t = substr($0, 11); if (t !~ /<none>/) tags[n] = tags[n] " " t; next }
    /^RepoDigests: / { digests[n] = digests[n] " " substr($0, 14); next }
    /^Pinned: true/  { pinned[n] = 1; next }
    END {
      for (i = 1; i <= n; i++) {
        in_use[i] = (id[i] in used)
        k = split(digests[i], d, " ")
        for (j = 1; j <= k; j++) if (d[j] in used) in_use[i] = 1
        if (!in_use[i]) continue
        k = split(tags[i] " " digests[i], r, " ")
        for (j = 1; j <= k; j++) used_repo[repo(r[j])] = 1
      }
      for (i = 1; i <= n; i++) {
        if (pinned[i] || in_use[i]) continue
        if (index(tags[i] " " digests[i], "ghcr.io/5stackgg/")) {
          if (tags[i] == "") print id[i]
          continue
        }
        if (after_update != "true") continue
        if (tags[i] == "") { print id[i]; continue }
        k = split(tags[i], r, " ")
        for (j = 1; j <= k; j++) if (repo(r[j]) in used_repo) { print id[i]; break }
      }
    }
  ' <(printf '%s\n' "$IN_USE") <(printf '%s\n' "$IMAGES")
)"; then
  echo "[5stack] image-prune: could not work out which images to remove"
  exit 1
fi

if [ -z "$STALE" ]; then
  echo "[5stack] image-prune: no superseded images"
  exit 0
fi

mapfile -t STALE_IDS <<<"$STALE"

removed=0
attempted=0
for id in "${STALE_IDS[@]}"; do
  [ -n "$id" ] || continue
  # Space the removals out: containerd deletes the snapshots in its own
  # process, so pacing is what keeps a large prune from hogging the disk
  # while match servers are running.
  [ "$attempted" -eq 0 ] || sleep 5
  attempted=$((attempted + 1))
  if "${CRICTL[@]}" rmi "$id" >/dev/null 2>&1; then
    echo "[5stack] image-prune: removed $id"
    removed=$((removed + 1))
  else
    # The runtime could not remove it right now - leave it for the next run.
    echo "[5stack] image-prune: skipped $id (removal failed)"
  fi
done

echo "[5stack] image-prune: removed $removed superseded image(s)"
