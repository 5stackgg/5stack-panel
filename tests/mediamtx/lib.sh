#!/bin/bash

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_ROOT="${TEST_ROOT:-$(cd "$HERE/../.." && pwd)}"
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

run_test() {
    if ("$1"); then
        TESTS_PASSED=$((TESTS_PASSED + 1))
        echo "ok   $1"
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        echo "FAIL $1"
    fi
}

# Runs the tests named on the command line, or every test_ function.
run_tests() {
    local name
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
}
