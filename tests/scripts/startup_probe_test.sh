#!/bin/bash

# shellcheck source=tests/scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

startup_probe_seconds() {
    awk '
        BEGIN { delay = 0; period = 10; threshold = 3 }
        /^ *startupProbe:/ { in_probe = 1; next }
        in_probe && /^ *[a-zA-Z]+Probe:/ { in_probe = 0 }
        in_probe && /^ *initialDelaySeconds:/ { delay = $2 }
        in_probe && /^ *periodSeconds:/ { period = $2 }
        in_probe && /^ *failureThreshold:/ { threshold = $2 }
        END { print delay + period * threshold }
    ' "$1"
}

# hasura's probe clock starts while cli-migrations is still applying metadata
# on a temporary port, so its budget covers that apply and the schema build.
test_hasura_startup_outlasts_a_slow_metadata_apply() {
    budget="$(startup_probe_seconds "$TEST_ROOT/base/hasura/deployment.yaml")"
    [ "$budget" -ge 300 ] || fail "hasura startup probe gives up after ${budget}s"
}

test_api_startup_outlasts_hasura_startup() {
    hasura="$(startup_probe_seconds "$TEST_ROOT/base/hasura/deployment.yaml")"
    api="$(startup_probe_seconds "$TEST_ROOT/base/api/deployment.yaml")"
    [ "$api" -gt "$hasura" ] || fail "api startup probe (${api}s) gives up before hasura's (${hasura}s)"
}

run_tests
