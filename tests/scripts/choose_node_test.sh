#!/bin/bash

# shellcheck source=tests/scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=utils/choose_node.sh
source "$TEST_ROOT/utils/choose_node.sh"

pick() {
    printf '%s\n' "$@" | choose_node node-a node-b node-c 2>"$WORK_DIR/asked"
}

test_a_number_picks_that_node() {
    assert_eq "$(pick 2)" "node-b"
}

test_leading_zeros_count_as_decimal() {
    assert_eq "$(pick 03)" "node-c"
}

test_a_number_out_of_range_is_asked_again() {
    assert_eq "$(pick 0 4 1)" "node-a"
    assert_contains "$(cat "$WORK_DIR/asked")" "Enter a number from 1 to 3."
}

test_only_digits_count_as_an_answer() {
    assert_eq "$(pick two 1+1 -1 2x 1)" "node-a"
}

test_no_answer_chooses_nothing() {
    if pick >/dev/null; then
        fail "chose a node without an answer"
    fi
}

test_no_nodes_chooses_nothing() {
    if printf '1\n' | choose_node 2>/dev/null; then
        fail "chose a node from an empty list"
    fi
}

run_tests
