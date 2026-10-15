#!/bin/bash

# shellcheck source=tests/timescaledb/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

test_extension_already_current_is_a_no_op() {
    load_scripts update_timescaledb_extension.sh
    stub extversion 2.30.2
    stub default-version 2.30.2
    output="$(update_timescaledb_extension 2>&1)" || fail "returned $?: $output"
    assert_contains "$output" "timescaledb extension 2.30.2"
    assert_not_called "ALTER EXTENSION"
    assert_not_called "rollout restart"
}

test_extension_behind_is_updated_and_hasura_and_api_restart() {
    load_scripts update_timescaledb_extension.sh
    stub extversion 2.26.1
    stub default-version 2.30.2
    output="$(update_timescaledb_extension 2>&1)" || fail "returned $?: $output"
    assert_contains "$output" "timescaledb extension updated from 2.26.1 to 2.30.2"
    assert_called "psql -X -v ON_ERROR_STOP=1 -At -U \"\$POSTGRES_USER\" -d \"\$POSTGRES_DB\" -c \"\$1\" sh ALTER EXTENSION timescaledb UPDATE"
    assert_before "ALTER EXTENSION timescaledb UPDATE" "rollout restart deployment/hasura deployment/api"
}

test_extension_not_installed_returns_quietly() {
    load_scripts update_timescaledb_extension.sh
    stub default-version 2.30.2
    output="$(update_timescaledb_extension 2>&1)" || fail "returned $?: $output"
    assert_eq "$output" ""
    assert_not_called "ALTER EXTENSION"
    assert_not_called "rollout restart"
}

test_rollout_never_ready_warns_without_exiting() {
    load_scripts update_timescaledb_extension.sh
    stub_rc rollout 1
    status=0
    update_timescaledb_extension >"$STUB_DIR/out" 2>&1 || status=$?
    assert_eq "$status" 1
    assert_contains "$(cat "$STUB_DIR/out")" "timescaledb never became ready; its extension was not updated"
    assert_not_called "exec timescaledb-0"
}

run_tests
