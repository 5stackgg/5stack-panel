#!/bin/bash
# Finds newer releases of the third-party images the panel pins, for
# .github/workflows/image-updates.yml. Run it from inside the repository.
#
#   image_updates.sh plan           one line per update: <minor|major> <old ref> <new ref>
#   image_updates.sh apply OLD NEW  rewrites every pin of OLD to NEW
#   image_updates.sh title          the commit title for the plan lines on stdin
#
# A pin is a tracked line that starts `image: <ref>` or a shell `<NAME>_IMAGE=<ref>`
# assignment whose tag is a version. An update keeps the tag's shape: its `v`,
# its number of version parts and the suffix after the version (`-alpine`,
# `-pg18`, `-k3s1`) stay the same, so a tag only moves to another release of
# the same build, and prereleases (`-rc1`, `.rc22`) never match. A pinned
# digest is re-pinned to the new tag's. An update is major when the first
# version part changes, or below 1.0 the second.
set -euo pipefail

# Pins that only move by hand.
IGNORED_PATHS=(
    # The upstream cert-manager release file, held on 1.17: from 1.18 the
    # HTTP-01 solver's Ingress is rejected by the older ingress-nginx some
    # panels still run, and renewals quietly stop.
    ':!overlays/cert-manager-crds/cert-manager.yaml'
    # The system-upgrade-controller's release assets, which
    # tests/scripts/system_upgrade_test.sh checks against their sha256.
    ':!base/system-upgrade/'
    # The old releases the TimescaleDB upgrade tests start from.
    ':!tests/timescaledb/'
    # This script's own test fixtures.
    ':!tests/scripts/image_updates_test.sh'
    # Workflows, which the app's token can't push.
    ':!.github/'
)

die() {
    echo "image_updates.sh: $*" >&2
    exit 1
}

cd "$(git rev-parse --show-toplevel)"

# Every distinct ref pinned in the tracked files.
pins() {
    git grep -I -h -o -E \
        -e '^[[:space:]]*(-[[:space:]]+)?image:[[:space:]]*"?[^[:space:]"]+' \
        -e '^[[:space:]]*[A-Z0-9_]+_IMAGE=[^[:space:]"]+' \
        -- "${IGNORED_PATHS[@]}" |
        sed -E 's/^.*(image:[[:space:]]*"?|_IMAGE=)//' |
        sort -u
}

# The newest tags in the list on stdin that keep the shape of tag $1, as
# "minor <tag>" and "major <tag>" lines.
newer_tags() {
    awk -v current="$1" '
        # Splits a tag into its v, version and suffix. 0 for a tag that is not
        # a plain version, like latest, 19beta1-alpine or 31.0.rc22-arm64.
        function parse(tag, out) {
            out["v"] = ""
            if (tag ~ /^v[0-9]/) {
                out["v"] = "v"
                tag = substr(tag, 2)
            }
            if (!match(tag, /^[0-9]+(\.[0-9]+)*/)) return 0
            out["version"] = substr(tag, 1, RLENGTH)
            out["suffix"] = substr(tag, RLENGTH + 1)
            return out["suffix"] == "" || out["suffix"] ~ /^-/
        }
        # 1 when version a is newer than version b, which has as many parts.
        function newer(a, b,   x, y, n, i) {
            n = split(a, x, ".")
            split(b, y, ".")
            for (i = 1; i <= n; i++) {
                if (x[i] + 0 != y[i] + 0) return x[i] + 0 > y[i] + 0
            }
            return 0
        }
        BEGIN {
            if (!parse(current, cur)) exit
            parts = split(cur["version"], c, ".")
        }
        {
            if (!parse($0, cand)) next
            if (cand["v"] != cur["v"] || cand["suffix"] != cur["suffix"]) next
            if (split(cand["version"], n, ".") != parts) next
            if (!newer(cand["version"], cur["version"])) next
            kind = "minor"
            if (n[1] + 0 != c[1] + 0 || (c[1] + 0 == 0 && parts > 1 && n[2] + 0 != c[2] + 0)) kind = "major"
            if (!(kind in best) || newer(cand["version"], best[kind])) {
                best[kind] = cand["version"]
                best_tag[kind] = $0
            }
        }
        END {
            if ("minor" in best_tag) print "minor", best_tag["minor"]
            if ("major" in best_tag) print "major", best_tag["major"]
        }
    '
}

plan() {
    local ref name tag digest kind new_tag new_digest tags
    pins | while IFS= read -r ref; do
        digest=""
        if [[ $ref == *@* ]]; then
            digest="${ref#*@}"
        fi
        name="${ref%%@*}"
        tag="${name##*:}"
        # name@digest, a registry port with no tag after it, or a tag like
        # latest that no release moves
        if [[ $name != *:* || ! $tag =~ ^v?[0-9]+(\.[0-9]+)*(-.*)?$ ]]; then
            continue
        fi
        name="${name%:*}"
        if ! tags="$(crane ls "$name" 2>&1 </dev/null)"; then
            echo "::warning::could not list the tags of $name: $tags" >&2
            continue
        fi
        newer_tags "$tag" <<<"$tags" | while read -r kind new_tag; do
            if [ -z "$digest" ]; then
                echo "$kind $ref $name:$new_tag"
            elif new_digest="$(crane digest "$name:$new_tag" 2>&1 </dev/null)" &&
                [[ $new_digest =~ ^sha256:[0-9a-f]{64}$ ]]; then
                echo "$kind $ref $name:$new_tag@$new_digest"
            else
                echo "::warning::could not read the digest of $name:$new_tag: $new_digest" >&2
            fi
        done
    done
}

apply() {
    local old="$1" new="$2" files=() before
    while IFS= read -r file; do
        files+=("$file")
    done < <(git grep -I -l -F -e "$old" -- "${IGNORED_PATHS[@]}")
    [ ${#files[@]} -gt 0 ] || die "$old is not pinned anywhere"
    before="$(cat -- "${files[@]}" | git hash-object --stdin)"
    OLD="$old" NEW="$new" perl -pi -e \
        's/(image:[ \t]*"?|_IMAGE=)\Q$ENV{OLD}\E(?=["\s]|$)/$1$ENV{NEW}/g' -- "${files[@]}"
    if [ "$(cat -- "${files[@]}" | git hash-object --stdin)" = "$before" ]; then
        die "$old is mentioned, but not pinned, in ${files[*]}"
    fi
}

# "redis 8.12.0-alpine" for docker.io/library/redis:8.12.0-alpine@sha256:...
label() {
    local ref="${1%%@*}" name
    name="${ref%:*}"
    case "${name%%/*}" in
        *.* | *:* | localhost) [[ $name == */* ]] && name="${name#*/}" ;;
    esac
    name="${name#library/}"
    echo "$name ${ref##*:}"
}

title() {
    local kind old new labels=() list
    while read -r kind old new; do
        [ -n "$new" ] || continue
        labels+=("$(label "$new")")
    done
    [ ${#labels[@]} -gt 0 ] || die "no updates on stdin"
    list="${labels[0]}"
    if [ ${#labels[@]} -gt 1 ]; then
        list="$(printf '%s, ' "${labels[@]:0:${#labels[@]}-1}")"
        list="${list%, } and ${labels[${#labels[@]}-1]}"
    fi
    if [ ${#list} -gt 200 ]; then
        list="${#labels[@]} images"
    fi
    echo "chore: $list"
}

case "${1:-}" in
    plan) plan ;;
    apply)
        [ $# -eq 3 ] || die "usage: image_updates.sh apply OLD NEW"
        apply "$2" "$3"
        ;;
    title) title ;;
    *) die "usage: image_updates.sh plan | apply OLD NEW | title" ;;
esac
