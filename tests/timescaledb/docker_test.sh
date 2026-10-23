#!/bin/bash

# Runs the upgrade Job's script and update.sh's extension step against the real
# pinned images, with Docker standing in for the cluster: /pv is a volume laid
# out like timescaledb-pv. Test names on the command line run just those.

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_ROOT="${TEST_ROOT:-$(cd "$HERE/../.." && pwd)}"
PREFIX=timescaledb-upgrade-test
SEED_IMAGE=timescale/timescaledb@sha256:87901ae7d81e3dc6d999ae002cc41ea4b31b34fa0e16ab466ee36ca251bd09e6
OLD_IMAGE=timescale/timescaledb@sha256:b56a3f51991df1f79d0c1a0841cad5c5fa8058fdd6a3ee6886394a6d4c174538
NEW_IMAGE="$(sed -n 's/^ *image: *\(timescale\/timescaledb:.*\)$/\1/p' "$TEST_ROOT/base/timescaledb/stateful-set.yaml" | head -n 1)"
[[ "$NEW_IMAGE" =~ :([0-9.]+)-pg([0-9]+) ]]
VERSION="${BASH_REMATCH[1]}"
NEW_MAJOR="${BASH_REMATCH[2]}"
TESTS_PASSED=0
TESTS_FAILED=0

cleanup() {
    docker ps -aq --filter "name=^$PREFIX" | xargs docker rm -f >/dev/null 2>&1
    docker volume ls -q --filter "name=^$PREFIX" | xargs docker volume rm >/dev/null 2>&1
}
trap cleanup EXIT

fail() {
    echo "      $*"
    exit 1
}

# The images declare VOLUME paths; mounting a named volume there keeps Docker
# from leaving anonymous ones behind.
image_volume() {
    docker image inspect -f '{{range $path, $_ := .Config.Volumes}}{{$path}}{{end}}' "$1"
}

start_postgres() {
    local name="$1" image="$2" pv="$3" pgdata="$4"
    docker run -d --name "$PREFIX-$name" \
        -v "$PREFIX-$pv:/pv" -v "$PREFIX-$name-image:$(image_volume "$image")" \
        -e PGDATA="$pgdata" -e POSTGRES_USER=hasura -e POSTGRES_DB=hasura -e POSTGRES_PASSWORD=test \
        -e TIMESCALEDB_TELEMETRY=off \
        "$image" postgres -c shared_preload_libraries=pg_stat_statements,timescaledb -c fivestack.app_key=test >/dev/null
    for _ in $(seq 1 120); do
        if docker exec "$PREFIX-$name" pg_isready -q -h 127.0.0.1 -U hasura; then
            return 0
        fi
        sleep 1
    done
    docker logs "$PREFIX-$name" 2>&1 | tail -n 20
    fail "$name never accepted connections"
}

stop_postgres() {
    docker stop "$PREFIX-$1" >/dev/null
    docker rm "$PREFIX-$1" >/dev/null
}

sql() {
    docker exec -i "$PREFIX-$1" psql -X -v ON_ERROR_STOP=1 -At -U hasura -d hasura -c "$2"
}

fingerprint() {
    sql "$1" "SELECT concat_ws(' ',
        (SELECT count(*) FROM players), (SELECT count(*) FROM player_kills),
        (SELECT count(*) FROM player_damages), (SELECT count(*) FROM player_sanctions),
        (SELECT count(*) FROM plugin_inventory.items), (SELECT count(*) FROM timescaledb_information.chunks),
        (SELECT md5(string_agg(name, ',' ORDER BY name)) FROM players),
        (SELECT md5(string_agg(attacker_name, ',' ORDER BY attacker_name)) FROM player_kills))"
}

on_volume() {
    docker run --rm -v "$PREFIX-$1:/pv" --entrypoint sh "$OLD_IMAGE" -c "$2"
}

job_phase() {
    local phase="$1" image="$2" pv="$3" log
    log="$(mktemp "${TMPDIR:-/tmp}/timescaledb-test.XXXXXX")"
    if ! docker run --rm -v "$PREFIX-$pv:/pv" -v "$PREFIX-$pv-old:/old" \
        -v "$TEST_ROOT/utils/timescaledb_major_upgrade_job.sh:/scripts/upgrade.sh:ro" \
        -e NEW_MAJOR="$NEW_MAJOR" -e TIMESCALEDB_VERSION="$VERSION" -e POSTGRES_USER=hasura \
        -e TIMESCALEDB_UPGRADE_HEADROOM_KB=1048576 \
        --entrypoint bash "$image" /scripts/upgrade.sh "$phase" >"$log" 2>&1; then
        sed 's/^/      /' "$log"
        rm -f "$log"
        fail "the $phase phase failed"
    fi
    rm -f "$log"
}

fresh_volume_from_seed() {
    docker volume create "$PREFIX-$1" >/dev/null
    docker run --rm -v "$PREFIX-seed:/seed:ro" -v "$PREFIX-$1:/pv" --entrypoint sh "$OLD_IMAGE" -c 'cp -a /seed/timescaledb /pv/'
}

seed() {
    docker volume create "$PREFIX-seed" >/dev/null
    start_postgres seeder "$SEED_IMAGE" seed /pv/timescaledb
    docker exec -i -e PGOPTIONS="-c client_min_messages=warning" "$PREFIX-seeder" \
        psql -X -q -v ON_ERROR_STOP=1 -U hasura -d hasura <"$HERE/fixtures/seed.sql" >/dev/null
    SEED_FINGERPRINT="$(fingerprint seeder)"
    assert_eq "$(sql seeder "SELECT extversion FROM pg_extension WHERE extname = 'timescaledb'")" 2.26.1
    stop_postgres seeder
}

assert_eq() {
    if [ "$1" != "$2" ]; then
        fail "expected '$2', got '$1'"
    fi
}

test_upgrade_keeps_the_data_and_the_old_cluster_boots() {
    local after before_chunks
    fresh_volume_from_seed upgrade
    job_phase prepare "$OLD_IMAGE" upgrade
    job_phase upgrade "$NEW_IMAGE" upgrade

    start_postgres new "$NEW_IMAGE" upgrade /pv/timescaledb
    assert_eq "$(sql new "SELECT current_setting('server_version_num')::int / 10000")" "$NEW_MAJOR"
    assert_eq "$(sql new "SELECT extversion FROM pg_extension WHERE extname = 'timescaledb'")" "$VERSION"
    assert_eq "$(fingerprint new)" "$SEED_FINGERPRINT"
    sql new "CREATE EXTENSION amcheck" >/dev/null
    assert_eq "$(sql new "SELECT count(*) > 300 FROM (SELECT bt_index_check(c.oid, true)
        FROM pg_index i JOIN pg_class c ON c.oid = i.indexrelid JOIN pg_am a ON a.oid = c.relam
        JOIN pg_attribute att ON att.attrelid = i.indrelid AND att.attnum = i.indkey[0]
        WHERE a.amname = 'btree' AND att.atttypid = 'text'::regtype) checked")" t
    before_chunks="$(sql new "SELECT count(*) FROM timescaledb_information.chunks")"
    sql new "INSERT INTO player_kills (time, match_id, match_map_id, attacker_steam_id, attacker_name, weapon)
        VALUES ('2030-01-01', gen_random_uuid(), gen_random_uuid(), 1, 'Zoë après', 'awp')" >/dev/null
    after="$(sql new "SELECT (SELECT count(*) FROM player_kills), (SELECT count(*) FROM timescaledb_information.chunks)")"
    assert_eq "$after" "701|$((before_chunks + 1))"
    stop_postgres new

    start_postgres kept "$OLD_IMAGE" upgrade "/pv/timescaledb-pg17"
    assert_eq "$(sql kept "SELECT current_setting('server_version_num')::int / 10000")" 17
    assert_eq "$(fingerprint kept)" "$SEED_FINGERPRINT"
    stop_postgres kept
}

# Holds the upgrade phase at $1 (see the shims in fixtures/), sends the SIGTERM
# a Job deadline or a deleted pod would, and checks what is left on the volume.
sigterm_while_held_at() {
    local hold="$1" name="$PREFIX-sigterm-$1" status
    fresh_volume_from_seed "sigterm-$hold"
    job_phase prepare "$OLD_IMAGE" "sigterm-$hold"
    docker run -d --name "$name" -v "$PREFIX-sigterm-$hold:/pv" -v "$PREFIX-sigterm-$hold-old:/old" \
        -v "$PREFIX-sigterm-$hold-image:$(image_volume "$NEW_IMAGE")" \
        -v "$TEST_ROOT/utils/timescaledb_major_upgrade_job.sh:/scripts/upgrade.sh:ro" \
        -v "$HERE/fixtures:/fixtures:ro" \
        -e PATH=/fixtures:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin -e HOLD="$hold" \
        -e NEW_MAJOR="$NEW_MAJOR" -e TIMESCALEDB_VERSION="$VERSION" -e POSTGRES_USER=hasura \
        --entrypoint bash "$NEW_IMAGE" /scripts/upgrade.sh upgrade >/dev/null
    for _ in $(seq 1 120); do
        if docker exec "$name" test -e "/tmp/pg-upgrade/held-$hold" 2>/dev/null; then
            break
        fi
        sleep 1
    done
    docker exec "$name" test -e "/tmp/pg-upgrade/held-$hold" || fail "never held at $hold: $(docker logs "$name" 2>&1 | tail -n 5)"
    on_volume "sigterm-$hold" 'test -d /pv/timescaledb-pg18-upgrade' || fail "no new cluster was being built"
    docker stop -t 30 "$name" >/dev/null
    status="$(docker inspect -f '{{.State.ExitCode}}' "$name")"
    assert_eq "$(on_volume "sigterm-$hold" 'ls -A /pv | tr "\n" " "')" "timescaledb "
    assert_eq "$(on_volume "sigterm-$hold" 'cat /pv/timescaledb/PG_VERSION')" 17
    assert_eq "$(on_volume "sigterm-$hold" 'test -e /pv/timescaledb/postmaster.pid && echo running || echo stopped')" stopped
    assert_eq "$(on_volume "sigterm-$hold" 'LC_ALL=C pg_controldata /pv/timescaledb | sed -n "s/^Database cluster state: *//p"')" "shut down"
    assert_eq "$status" 143
    docker logs "$name" 2>&1 | grep -q "the PostgreSQL 17 data in /pv/timescaledb was left in place" \
        || fail "the pod log does not say the old data was left in place: $(docker logs "$name" 2>&1 | tail -n 3)"
}

test_sigterm_during_initdb_leaves_the_old_data_alone() {
    sigterm_while_held_at initdb
}

test_sigterm_during_the_check_stops_both_servers() {
    sigterm_while_held_at check
}

test_sigterm_during_the_copy_leaves_the_old_data_alone() {
    sigterm_while_held_at copy
}

test_sigterm_during_the_extension_updates_stops_the_new_server() {
    sigterm_while_held_at extensions
}

test_extension_step_moves_the_extension_once() {
    local output
    fresh_volume_from_seed extension
    start_postgres extension "$OLD_IMAGE" extension /pv/timescaledb
    STUB_DIR="$(mktemp -d "${TMPDIR:-/tmp}/timescaledb-test.XXXXXX")"
    : >"$STUB_DIR/calls"
    output="$(
        export STUB_DIR TIMESCALEDB_CONTAINER="$PREFIX-extension" KUBECONFIG=/dev/null DEBUG=false
        PATH="$HERE/docker-stub:$PATH"
        # shellcheck source=/dev/null
        source "$TEST_ROOT/utils/colors.sh"
        # shellcheck source=/dev/null
        source "$TEST_ROOT/utils/output_redirect.sh"
        # shellcheck source=/dev/null
        source "$TEST_ROOT/utils/update_timescaledb_extension.sh"
        update_timescaledb_extension
        update_timescaledb_extension
    )"
    case "$output" in
        *"timescaledb extension updated from 2.26.1 to $VERSION"*"timescaledb extension $VERSION"*) ;;
        *) fail "unexpected output: $output" ;;
    esac
    assert_eq "$(grep -c "rollout restart deployment/hasura deployment/api" "$STUB_DIR/calls")" 1
    assert_eq "$(sql extension "SELECT extversion FROM pg_extension WHERE extname = 'timescaledb'")" "$VERSION"
    assert_eq "$(sql extension "SELECT count(*) FROM player_kills")" 700
    rm -rf "$STUB_DIR"
    stop_postgres extension
}

run_test() {
    if ("$1"); then
        TESTS_PASSED=$((TESTS_PASSED + 1))
        echo "ok   $1"
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        echo "FAIL $1"
    fi
}

cleanup
for image in "$SEED_IMAGE" "$OLD_IMAGE" "$NEW_IMAGE"; do
    docker pull -q "$image" >/dev/null || exit 1
done
seed || exit 1
if [ "$#" -eq 0 ]; then
    while IFS= read -r name; do
        set -- "$@" "$name"
    done < <(declare -F | awk '{ print $3 }' | grep '^test_')
fi
for name in "$@"; do
    run_test "$name"
done
echo
echo "$TESTS_PASSED passed, $TESTS_FAILED failed"
[ "$TESTS_FAILED" -eq 0 ]
