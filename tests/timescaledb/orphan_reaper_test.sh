#!/bin/bash

# Why the TimescaleDB pod shares its process namespace: an exec that gets cut
# off leaves its children to PID 1. When PID 1 is the postmaster, one of them
# dying by a signal is an "untracked child" crash and the whole database
# restarts. With a reaper as PID 1 (docker's --init standing in for the pod's
# pause container) nothing happens. Runs the pinned image, one container at a
# time.

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_ROOT="${TEST_ROOT:-$(cd "$HERE/../.." && pwd)}"
PREFIX=timescaledb-orphan-test
IMAGE="$(sed -n 's/^ *image: *\(timescale\/timescaledb:.*\)$/\1/p' "$TEST_ROOT/base/timescaledb/stateful-set.yaml" | head -n 1)"
TESTS_PASSED=0
TESTS_FAILED=0

cleanup() {
    docker ps -aq --filter "name=^$PREFIX" | xargs docker rm -f >/dev/null 2>&1
}
trap cleanup EXIT

fail() {
    echo "      $*"
    exit 1
}

# start NAME [DOCKER_ARGS...]: postgres up and past the image's first-run setup.
start() {
    local name="$PREFIX-$1"
    shift
    docker run -d --name "$name" "$@" -e POSTGRES_PASSWORD=test "$IMAGE" >/dev/null ||
        fail "could not start $IMAGE"
    for _ in $(seq 1 120); do
        if docker logs "$name" 2>&1 | grep -q "PostgreSQL init process complete" &&
            docker exec "$name" pg_isready -q -U postgres -h 127.0.0.1; then
            return 0
        fi
        sleep 1
    done
    fail "postgres never became ready: $(docker logs "$name" 2>&1 | tail -5)"
}

# orphan_dies_by_a_signal NAME: what a cut-off exec leaves behind, killed.
orphan_dies_by_a_signal() {
    local name="$PREFIX-$1" pid
    pid="$(docker exec "$name" sh -c 'sleep 300 >/dev/null 2>&1 & echo $!')" || fail "could not start the orphan"
    sleep 1
    [ "$(docker exec "$name" sh -c "sed -n 's/^PPid:[[:space:]]*//p' /proc/$pid/status")" = 1 ] ||
        fail "the orphan $pid was not handed to PID 1"
    docker exec "$name" kill -9 "$pid" || fail "could not kill the orphan $pid"
    sleep 3
}

crashed() {
    docker logs "$PREFIX-$1" 2>&1 | grep -q "untracked child process .* was terminated by signal 9" &&
        docker logs "$PREFIX-$1" 2>&1 | grep -q "all server processes terminated; reinitializing"
}

test_postgres_as_pid_1_restarts_the_database_when_an_orphan_is_killed() {
    start postgres-pid-1
    [ "$(docker exec "$PREFIX-postgres-pid-1" cat /proc/1/comm)" = postgres ] || fail "postgres is not PID 1"
    orphan_dies_by_a_signal postgres-pid-1
    crashed postgres-pid-1 || fail "postgres did not restart: $(docker logs "$PREFIX-postgres-pid-1" 2>&1 | tail -5)"
    docker rm -f "$PREFIX-postgres-pid-1" >/dev/null
}

test_a_reaper_as_pid_1_takes_the_orphan_and_postgres_stays_up() {
    start reaper --init
    [ "$(docker exec "$PREFIX-reaper" cat /proc/1/comm)" != postgres ] || fail "postgres is still PID 1"
    orphan_dies_by_a_signal reaper
    if docker logs "$PREFIX-reaper" 2>&1 | grep -E -q "untracked child process|reinitializing"; then
        fail "postgres restarted: $(docker logs "$PREFIX-reaper" 2>&1 | tail -5)"
    fi
    docker exec "$PREFIX-reaper" pg_isready -q -U postgres -h 127.0.0.1 || fail "postgres is down"
    docker rm -f "$PREFIX-reaper" >/dev/null
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
docker pull -q "$IMAGE" >/dev/null || exit 1
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
