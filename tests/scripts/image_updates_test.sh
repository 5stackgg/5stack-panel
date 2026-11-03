#!/bin/bash

# shellcheck source=tests/scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

STUB_BIN="$(cd "$(dirname "${BASH_SOURCE[0]}")/stub" && pwd)"
SCRIPT="$TEST_ROOT/.github/scripts/image_updates.sh"
OLD_DIGEST="sha256:$(printf "%064d" 1)"
NEW_DIGEST="sha256:$(printf "%064d" 2)"

# pin FILE LINE...: a tracked file of the test repository.
pin() {
    mkdir -p "$(dirname "$WORK_DIR/repo/$1")"
    printf '%s\n' "${@:2}" >"$WORK_DIR/repo/$1"
}

# tags REPOSITORY TAG...: what the registry lists for REPOSITORY.
tags() {
    mkdir -p "$WORK_DIR/tags"
    printf '%s\n' "${@:2}" >"$WORK_DIR/tags/$(printf '%s' "$1" | tr / _)"
}

digest() {
    echo "$1 $2" >>"$WORK_DIR/digests"
}

image_updates() {
    [ -d "$WORK_DIR/repo/.git" ] || git init -q "$WORK_DIR/repo"
    (
        cd "$WORK_DIR/repo" || exit 1
        git add -A
        PATH="$STUB_BIN:$PATH" bash "$SCRIPT" "$@"
    )
}

test_the_newest_minor_and_the_newest_major_are_planned() {
    pin base/typesense.yaml "          image: typesense/typesense:30.2"
    tags typesense/typesense 29.1 30.0 30.2 30.3 30.10 31.0 32.1
    assert_eq "$(image_updates plan)" "minor typesense/typesense:30.2 typesense/typesense:30.10
major typesense/typesense:30.2 typesense/typesense:32.1"
}

test_an_update_keeps_the_suffix_and_the_number_of_version_parts() {
    pin base/redis.yaml "        image: redis:8.10.3-alpine"
    tags redis 8.10.3-alpine 8.10.4-alpine3.23 8.11-alpine 8.12.0-alpine 8.12.1 9.0.0-rc1-alpine 8.12.1-alpine-arm64
    assert_eq "$(image_updates plan)" "minor redis:8.10.3-alpine redis:8.12.0-alpine"
}

test_an_update_keeps_the_v() {
    pin base/hasura.yaml "        - image: hasura/graphql-engine:v2.51.3-ce.cli-migrations-v3"
    tags hasura/graphql-engine v2.51.4-ce.cli-migrations-v3 2.51.5-ce.cli-migrations-v3 v2.51.9 v2.52.0-beta.1-ce.cli-migrations-v3
    assert_eq "$(image_updates plan)" "minor hasura/graphql-engine:v2.51.3-ce.cli-migrations-v3 hasura/graphql-engine:v2.51.4-ce.cli-migrations-v3"
}

test_prereleases_and_tags_that_are_not_versions_are_skipped() {
    pin base/typesense.yaml "          image: typesense/typesense:30.2"
    tags typesense/typesense latest main 31.0.rc22-arm64 30.3rc1 30.2
    assert_eq "$(image_updates plan)" ""
}

# Below 1.0 a minor release may break things, as a major does from 1.0 on.
test_below_1_0_a_new_second_part_is_major() {
    pin base/rustfs.yaml "          image: rustfs/rc:v0.1.36"
    tags rustfs/rc v0.1.35 v0.1.37 v0.2.0 v1.0.0
    assert_eq "$(image_updates plan)" "minor rustfs/rc:v0.1.36 rustfs/rc:v0.1.37
major rustfs/rc:v0.1.36 rustfs/rc:v1.0.0"
}

test_a_one_part_version_only_moves_to_a_major() {
    pin base/backup.yaml "              image: postgres:18-alpine"
    tags postgres 17-alpine 18-alpine 18.1-alpine 19-alpine 19beta1-alpine 19-alpine3.22
    assert_eq "$(image_updates plan)" "major postgres:18-alpine postgres:19-alpine"
}

test_a_pinned_digest_is_repinned_to_the_new_tags() {
    pin base/redis.yaml "        image: redis:8.10.3-alpine@$OLD_DIGEST"
    tags redis 8.10.4-alpine
    digest redis:8.10.4-alpine "$NEW_DIGEST"
    assert_eq "$(image_updates plan)" "minor redis:8.10.3-alpine@$OLD_DIGEST redis:8.10.4-alpine@$NEW_DIGEST"
}

test_a_digest_that_is_not_a_sha256_is_not_pinned() {
    pin base/redis.yaml "        image: redis:8.10.3-alpine@$OLD_DIGEST"
    tags redis 8.10.4-alpine
    digest redis:8.10.4-alpine "sha256:\$(reboot)"
    assert_eq "$(image_updates plan 2>"$WORK_DIR/stderr")" ""
    assert_contains "$(cat "$WORK_DIR/stderr")" "::warning::could not read the digest of redis:8.10.4-alpine"
}

test_shell_and_quoted_pins_are_planned() {
    pin tests/lib.sh "K3S_IMAGE=rancher/k3s:v1.36.5-k3s1"
    pin overlays/x.yaml '          image: "coturn/coturn:4.18.0"'
    tags rancher/k3s v1.36.5-rc1-k3s1 v1.36.6-k3s1 v1.36.5-k3s2
    tags coturn/coturn 4.18.1 4.18.0-r0-debian-amd64
    assert_eq "$(image_updates plan)" "minor coturn/coturn:4.18.0 coturn/coturn:4.18.1
minor rancher/k3s:v1.36.5-k3s1 rancher/k3s:v1.36.6-k3s1"
}

test_refs_without_a_version_tag_never_reach_the_registry() {
    pin base/api.yaml "        - image: ghcr.io/5stackgg/api:latest"
    # shellcheck disable=SC2016 # a pin of an unexpanded variable
    pin tests/t.sh "SEED_IMAGE=timescale/timescaledb@sha256:abc" 'image: $PEBBLE_IMAGE'
    assert_eq "$(image_updates plan)" ""
    [ ! -e "$WORK_DIR/crane-calls" ] || fail "crane was asked: $(cat "$WORK_DIR/crane-calls")"
}

test_held_pins_are_not_planned() {
    pin overlays/cert-manager-crds/cert-manager.yaml '          image: "quay.io/jetstack/cert-manager-controller:v1.17.4"'
    pin base/system-upgrade/system-upgrade-controller.yaml "        image: rancher/system-upgrade-controller:v0.20.2"
    pin tests/timescaledb/major_upgrade_test.sh "OLD_IMAGE=timescale/timescaledb:2.30.2-pg17"
    pin tests/scripts/image_updates_test.sh "K3S_IMAGE=rancher/k3s:v1.36.5-k3s1"
    pin .github/workflows/x.yml "        image: rancher/k3s:v1.36.5-k3s1"
    tags rancher/k3s v1.36.6-k3s1
    tags quay.io/jetstack/cert-manager-controller v1.17.4 v1.21.2
    tags rancher/system-upgrade-controller v0.20.2 v0.20.3
    tags timescale/timescaledb 2.30.2-pg17 2.31.0-pg17
    assert_eq "$(image_updates plan)" ""
}

test_an_unreadable_repository_skips_only_its_own_pins() {
    pin base/a.yaml "          image: busybox:1.38" "          image: coturn/coturn:4.18.0"
    tags busybox 1.38 1.39
    assert_eq "$(image_updates plan 2>"$WORK_DIR/stderr")" "minor busybox:1.38 busybox:1.39"
    assert_contains "$(cat "$WORK_DIR/stderr")" "::warning::could not list the tags of coturn/coturn"
}

test_apply_rewrites_every_pin_and_nothing_else() {
    pin base/a.yaml \
        "  image: busybox:1.38" \
        '  - image: "busybox:1.38"' \
        "  image: busybox:1.38.1" \
        "  image: mybusybox:1.38" \
        "  image: docker.io/busybox:1.38"
    pin tests/a.sh \
        "TEST_IMAGE=busybox:1.38" \
        "OTHER=busybox:1.38" \
        'echo "pulling image busybox:1.38"'
    pin tests/timescaledb/a.sh "OLD_IMAGE=busybox:1.38"
    image_updates apply busybox:1.38 busybox:1.39 || fail "apply failed"
    assert_eq "$(cat "$WORK_DIR/repo/base/a.yaml")" "  image: busybox:1.39
  - image: \"busybox:1.39\"
  image: busybox:1.38.1
  image: mybusybox:1.38
  image: docker.io/busybox:1.38"
    assert_eq "$(cat "$WORK_DIR/repo/tests/a.sh")" "TEST_IMAGE=busybox:1.39
OTHER=busybox:1.38
echo \"pulling image busybox:1.38\""
    assert_eq "$(cat "$WORK_DIR/repo/tests/timescaledb/a.sh")" "OLD_IMAGE=busybox:1.38"
}

test_apply_moves_a_digest_pin_whole() {
    pin base/a.yaml "  image: redis:8.10.3-alpine@$OLD_DIGEST"
    image_updates apply "redis:8.10.3-alpine@$OLD_DIGEST" "redis:8.10.4-alpine@$NEW_DIGEST" || fail "apply failed"
    assert_eq "$(cat "$WORK_DIR/repo/base/a.yaml")" "  image: redis:8.10.4-alpine@$NEW_DIGEST"
}

test_apply_fails_when_the_ref_is_not_pinned() {
    pin tests/a.sh 'echo "pulling image busybox:1.38"'
    if image_updates apply busybox:1.38 busybox:1.39 2>"$WORK_DIR/stderr"; then
        fail "apply succeeded"
    fi
    assert_contains "$(cat "$WORK_DIR/stderr")" "busybox:1.38 is mentioned, but not pinned, in tests/a.sh"
    if image_updates apply busybox:1.37 busybox:1.39 2>"$WORK_DIR/stderr"; then
        fail "apply succeeded"
    fi
    assert_contains "$(cat "$WORK_DIR/stderr")" "busybox:1.37 is not pinned anywhere"
}

test_the_title_names_each_image_and_its_new_tag() {
    pin README.md "readme"
    assert_eq "$(image_updates title <<<"minor redis:8.10.3-alpine redis:8.12.0-alpine@sha256:abc")" \
        "chore: redis 8.12.0-alpine"
    assert_eq "$(printf '%s\n' \
        "minor redis:8.10.3-alpine redis:8.12.0-alpine@sha256:abc" \
        "minor ghcr.io/letsencrypt/pebble:2.10.1 ghcr.io/letsencrypt/pebble:2.10.2" \
        "major docker.io/library/postgres:18-alpine docker.io/library/postgres:19-alpine" |
        image_updates title)" \
        "chore: redis 8.12.0-alpine, letsencrypt/pebble 2.10.2 and postgres 19-alpine"
}

run_tests
