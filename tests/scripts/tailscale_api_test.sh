#!/bin/bash

# shellcheck source=tests/scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TS_STUB="$(cd "$(dirname "${BASH_SOURCE[0]}")/tailscale-stub" && pwd)"

policy() {
    if [ -n "${1:-}" ]; then
        printf '%s\n' "$1" >"$WORK_DIR/acl.json"
    else
        printf '%s\n' '{"acls": [{"action": "accept", "src": ["*"], "dst": ["*:*"]}]}' >"$WORK_DIR/acl.json"
    fi
}

tailnet() {
    (
        export PATH="$TS_STUB:$PATH"
        unset PANEL_POD_RANGE PANEL_SERVICE_RANGE PANEL_TAILSCALE_TAG
        if [ -n "${POD_RANGE:-}" ]; then
            export PANEL_POD_RANGE="$POD_RANGE"
        fi
        if [ -n "${TAG:-}" ]; then
            export PANEL_TAILSCALE_TAG="$TAG"
        fi
        # shellcheck source=utils/tailscale-api.sh
        source "$TEST_ROOT/utils/tailscale-api.sh"
        "$@"
    )
}

posted() {
    jq -c "$1" "$WORK_DIR/acl-posted.json"
}

test_a_panel_on_the_shared_range_keeps_the_shared_lines() {
    policy
    echo "10.42.0.0/24" >"$WORK_DIR/pod-cidrs"
    tailnet update_acl_for_fivestack ts-access >"$WORK_DIR/out" 2>&1 || fail "$(cat "$WORK_DIR/out")"
    assert_eq "$(posted '.autoApprovers.routes')" '{"10.42.0.0/16":["tag:fivestack"]}'
    assert_eq "$(posted '.grants')" '[{"src":["tag:fivestack","10.42.0.0/16"],"dst":["tag:fivestack","10.42.0.0/16"],"ip":["*"]}]'
    assert_eq "$(posted '.tagOwners')" null
}

test_a_panel_with_its_own_range_gets_its_own_lines_and_never_the_shared_ones() {
    policy
    echo "10.52.0.0/24" >"$WORK_DIR/pod-cidrs"
    POD_RANGE=10.52.0.0/16 TAG=tag:fivestack-abc123 tailnet update_acl_for_fivestack ts-access >"$WORK_DIR/out" 2>&1 || fail "$(cat "$WORK_DIR/out")"
    assert_eq "$(posted '.autoApprovers.routes')" '{"10.52.0.0/16":["tag:fivestack-abc123"]}'
    assert_eq "$(posted '.grants')" '[{"src":["tag:fivestack-abc123","10.52.0.0/16"],"dst":["tag:fivestack-abc123","10.52.0.0/16"],"ip":["*"]}]'
    assert_eq "$(posted '.tagOwners')" '{"tag:fivestack-abc123":["autogroup:admin"]}'
    assert_not_contains "$(cat "$WORK_DIR/acl-posted.json")" "10.42."
    assert_eq "$(posted '.acls | length')" 1
}

test_another_panels_shared_lines_stay_as_they_are() {
    policy '{"autoApprovers": {"routes": {"10.42.0.0/16": ["tag:fivestack"]}}, "grants": [{"src": ["tag:fivestack", "10.42.0.0/16"], "dst": ["tag:fivestack", "10.42.0.0/16"], "ip": ["*"]}]}'
    POD_RANGE=10.52.0.0/16 TAG=tag:fivestack-abc123 tailnet update_acl_for_fivestack ts-access >"$WORK_DIR/out" 2>&1 || fail "$(cat "$WORK_DIR/out")"
    assert_eq "$(posted '.autoApprovers.routes')" '{"10.42.0.0/16":["tag:fivestack"],"10.52.0.0/16":["tag:fivestack-abc123"]}'
    assert_eq "$(posted '.grants | length')" 2
    assert_eq "$(posted '.grants[0].src')" '["tag:fivestack-abc123","10.52.0.0/16"]'
}

test_a_cluster_on_its_own_range_without_it_in_the_config_is_refused() {
    policy
    echo "10.52.0.0/24" >"$WORK_DIR/pod-cidrs"
    if tailnet update_acl_for_fivestack ts-access >"$WORK_DIR/out" 2>&1; then
        fail "the policy was edited for a panel whose pods are on 10.52.0.0/24"
    fi
    [ ! -e "$WORK_DIR/acl-posted.json" ] || fail "posted: $(cat "$WORK_DIR/acl-posted.json")"
    assert_contains "$(cat "$WORK_DIR/out")" "this panel's pods are on 10.52.0.0/24, outside 10.42.0.0/16. Set PANEL_POD_RANGE and PANEL_TAILSCALE_TAG"
}

test_game_node_keys_carry_the_panels_own_tag() {
    tailnet create_auth_key ts-access >"$WORK_DIR/out" 2>&1 || fail "$(cat "$WORK_DIR/out")"
    assert_eq "$(jq -c '.capabilities.devices.create.tags' "$WORK_DIR/key-request.json")" '["tag:fivestack"]'
    assert_eq "$(jq -c '.capabilities.devices.create | [.reusable, .ephemeral, .preauthorized]' "$WORK_DIR/key-request.json")" '[false,false,true]'
    assert_eq "$(cat "$WORK_DIR/out")" "tskey-auth-test"
    TAG=tag:fivestack-abc123 tailnet create_auth_key ts-access >"$WORK_DIR/out" 2>&1 || fail "$(cat "$WORK_DIR/out")"
    assert_eq "$(jq -c '.capabilities.devices.create.tags' "$WORK_DIR/key-request.json")" '["tag:fivestack","tag:fivestack-abc123"]'
}

run_tests
