#!/bin/bash

# shellcheck source=tests/scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

STUB_BIN="$(cd "$(dirname "${BASH_SOURCE[0]}")/stub" && pwd)"

run_debug() {
    printf '%s\n' \
        "hasura-1   1/1   Running            37 (2m ago)   3h" \
        "api-1      0/1   CrashLoopBackOff   29 (1m ago)   3h" \
        "redis-0    1/1   Running            0             3h" >"$WORK_DIR/pods"
    printf '%s\n' \
        "migrations|0|||" \
        "hasura|37|Error|137|2026-10-17T02:32:34Z" >"$WORK_DIR/containers-hasura-1"
    printf '%s\n' "api|29|Error|137|" >"$WORK_DIR/containers-api-1"
    printf '%s\n' "redis|0|||2026-10-17T00:00:00Z" >"$WORK_DIR/containers-redis-0"
    (cd "$WORK_DIR" && PATH="$STUB_BIN:$PATH" bash "$TEST_ROOT/debug.sh") >/dev/null 2>&1
    cat "$WORK_DIR"/debug_output_*.txt
}

test_a_running_container_that_restarted_dumps_its_previous_run() {
    report="$(run_debug)"
    assert_contains "$report" "current logs of hasura-1/hasura"
    assert_contains "$report" "previous logs of hasura-1/hasura"
}

test_a_waiting_container_is_not_dumped_twice() {
    report="$(run_debug)"
    assert_contains "$report" "current logs of api-1/api"
    assert_not_contains "$report" "previous logs of api-1/api"
}

test_init_container_logs_are_in_the_report() {
    report="$(run_debug)"
    assert_contains "$report" "current logs of hasura-1/migrations"
    assert_not_contains "$report" "previous logs of hasura-1/migrations"
}

test_a_container_that_never_restarted_skips_previous_logs() {
    report="$(run_debug)"
    assert_contains "$report" "current logs of redis-0/redis"
    assert_not_contains "$report" "previous logs of redis-0/redis"
}

test_each_container_shows_its_last_exit() {
    report="$(run_debug)"
    assert_contains "$report" "Container: hasura (restarts: 37, last exit: Error 137)"
    assert_contains "$report" "Container: migrations (restarts: 0)"
}

test_namespace_events_are_in_the_report() {
    report="$(run_debug)"
    assert_contains "$(cat "$WORK_DIR/calls")" "get events -n 5stack"
    assert_contains "$report" "Container hasura failed startup probe, will be restarted"
}

test_an_events_error_lands_in_the_report() {
    touch "$WORK_DIR/events-error"
    report="$(run_debug)"
    assert_contains "$report" "The connection to the server was refused"
}

run_tests
