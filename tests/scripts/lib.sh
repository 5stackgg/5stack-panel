#!/bin/bash

TEST_ROOT="${TEST_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
TESTS_PASSED=0
TESTS_FAILED=0

fail() {
    echo "      $*"
    exit 1
}

assert_eq() {
    if [ "$1" != "$2" ]; then
        fail "expected '$2', got '$1'"
    fi
}

assert_contains() {
    case "$1" in
        *"$2"*) ;;
        *) fail "expected output to contain: $2" ;;
    esac
}

assert_not_contains() {
    case "$1" in
        *"$2"*) fail "expected output not to contain: $2" ;;
    esac
}

run_test() {
    local name="$1" status
    WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/panel-test.XXXXXX")"
    export WORK_DIR
    (
        export TMPDIR="$WORK_DIR"
        "$name"
    ) >"$WORK_DIR/test-output" 2>&1
    status=$?
    if [ "$status" -eq 0 ]; then
        TESTS_PASSED=$((TESTS_PASSED + 1))
        echo "ok   $name"
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        echo "FAIL $name"
        sed 's/^/      /' "$WORK_DIR/test-output" | tail -n 40
    fi
    rm -rf "$WORK_DIR"
}

run_tests() {
    local name
    for name in $(declare -F | awk '{ print $3 }' | grep '^test_'); do
        run_test "$name"
    done
    echo
    echo "$TESTS_PASSED passed, $TESTS_FAILED failed"
    [ "$TESTS_FAILED" -eq 0 ]
}
