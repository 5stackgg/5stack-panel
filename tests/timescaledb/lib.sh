#!/bin/bash

# A small harness for the update.sh helpers: each test runs in its own subshell
# with the stub kubectl first on PATH, sleep replaced by a clock that only moves
# SECONDS forward, and the scripts under test sourced from $TEST_ROOT (the
# checkout, unless the caller points it at another tree).

TEST_ROOT="${TEST_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
STUB_BIN="$(cd "$(dirname "${BASH_SOURCE[0]}")/stub" && pwd)"
TESTS_PASSED=0
TESTS_FAILED=0
FAILED_NAMES=()

load_scripts() {
    export KUBECONFIG=/home/ops/.kube/prod.yaml DEBUG=false
    PATH="$STUB_BIN:$PATH"
    # shellcheck source=/dev/null
    source "$TEST_ROOT/utils/colors.sh"
    # shellcheck source=/dev/null
    source "$TEST_ROOT/utils/output_redirect.sh"
    local script
    for script in "$@"; do
        # shellcheck source=/dev/null
        source "$TEST_ROOT/utils/$script"
    done
    # shellcheck disable=SC2317,SC2329
    sleep() {
        SECONDS=$((SECONDS + ${1%.*}))
    }
}

stub() {
    printf '%s' "$2" >"$STUB_DIR/$1"
}

stub_rc() {
    echo "$2" >"$STUB_DIR/$1.rc"
}

called() {
    grep -qF -- "$1" "$STUB_DIR/calls"
}

call_line() {
    grep -nF -- "$1" "$STUB_DIR/calls" | head -n 1 | cut -d: -f1
}

fail() {
    echo "      $*"
    exit 1
}

assert_called() {
    called "$1" || fail "kubectl was never called with: $1"
}

assert_not_called() {
    if called "$1"; then
        fail "kubectl was called with: $1"
    fi
}

assert_before() {
    local first second
    first="$(call_line "$1")"
    second="$(call_line "$2")"
    if [ -z "$first" ] || [ -z "$second" ] || [ "$first" -ge "$second" ]; then
        fail "expected '$1' (call ${first:-none}) before '$2' (call ${second:-none})"
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

assert_eq() {
    if [ "$1" != "$2" ]; then
        fail "expected '$2', got '$1'"
    fi
}

run_test() {
    local name="$1" status
    STUB_DIR="$(mktemp -d "${TMPDIR:-/tmp}/timescaledb-test.XXXXXX")"
    export STUB_DIR
    : >"$STUB_DIR/calls"
    ("$name") >"$STUB_DIR/test-output" 2>&1
    status=$?
    if [ "$status" -eq 0 ]; then
        TESTS_PASSED=$((TESTS_PASSED + 1))
        echo "ok   $name"
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        FAILED_NAMES+=("$name")
        echo "FAIL $name"
        sed 's/^/      /' "$STUB_DIR/test-output" | tail -n 40
    fi
    rm -rf "$STUB_DIR"
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
