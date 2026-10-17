#!/bin/bash

# shellcheck source=tests/scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

STUB_BIN="$(cd "$(dirname "${BASH_SOURCE[0]}")/stub" && pwd)"

run_debug() {
    printf '%s\n' \
        "hasura-1   0/1   CrashLoopBackOff   37 (2m ago)   3h" \
        "redis-0    1/1   Running            0             3h" >"$WORK_DIR/pods"
    (cd "$WORK_DIR" && PATH="$STUB_BIN:$PATH" bash "$TEST_ROOT/debug.sh") >/dev/null 2>&1
    cat "$WORK_DIR"/debug_output_*.txt
}

test_a_restarted_pod_dumps_the_logs_from_before_its_restart() {
    report="$(run_debug)"
    assert_contains "$report" "current logs of hasura-1"
    assert_contains "$report" "previous logs of hasura-1"
}

test_a_pod_that_never_restarted_skips_previous_logs() {
    report="$(run_debug)"
    assert_contains "$report" "current logs of redis-0"
    assert_not_contains "$report" "previous logs of redis-0"
}

test_namespace_events_are_in_the_report() {
    report="$(run_debug)"
    assert_contains "$(cat "$WORK_DIR/calls")" "get events -n 5stack"
    assert_contains "$report" "Container hasura failed startup probe, will be restarted"
}

run_tests
