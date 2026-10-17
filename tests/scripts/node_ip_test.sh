#!/bin/bash

# shellcheck source=tests/scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

STUB_BIN="$(cd "$(dirname "${BASH_SOURCE[0]}")/stub" && pwd)"

nodes() {
    printf '%s\n' "$@" >"$WORK_DIR/nodes"
}

run_ensure_node_ip() {
    if [ -n "$1" ]; then
        printf 'node-ip: %s\n' "$1" >"$WORK_DIR/config.yaml"
    fi
    (
        export PATH="$STUB_BIN:$PATH" K3S_CONFIG="$WORK_DIR/config.yaml" KUBECONFIG=/dev/null NODE_IP_ATTEMPTS="${ATTEMPTS:-1}"
        # shellcheck source=utils/colors.sh
        source "$TEST_ROOT/utils/colors.sh"
        # shellcheck source=utils/ensure_node_ip.sh
        source "$TEST_ROOT/utils/ensure_node_ip.sh"
        ensure_node_ip
    ) >"$WORK_DIR/output" 2>&1 || fail "ensure_node_ip exited $?: $(cat "$WORK_DIR/output")"
}

annotations() {
    grep ' annotate ' "$WORK_DIR/calls" 2>/dev/null || true
}

# The panel registered on its LAN IP, then game-node-server-setup.sh moved k3s
# to Tailscale: the kubelet followed, the Node's InternalIP never did.
test_a_panel_moved_to_tailscale_has_its_provided_ip_moved_too() {
    nodes "$(printf 'dietpi\t100.117.134.62,fd7a:115c:a1e0::c02b:863f\t192.168.2.199')" \
        "$(printf 'game-node\t100.64.0.9\t100.64.0.9')"
    run_ensure_node_ip 100.117.134.62
    assert_eq "$(annotations)" "--kubeconfig=/dev/null annotate node dietpi alpha.kubernetes.io/provided-node-ip=100.117.134.62 --overwrite"
}

test_a_node_already_on_its_ip_is_left_alone() {
    nodes "$(printf 'dietpi\t100.117.134.62\t100.117.134.62')"
    run_ensure_node_ip 100.117.134.62
    assert_eq "$(annotations)" ""
}

test_a_panel_without_node_ip_never_asks_the_cluster() {
    nodes "$(printf 'dietpi\t192.168.2.199\t192.168.2.199')"
    run_ensure_node_ip ""
    assert_eq "$(cat "$WORK_DIR/calls" 2>/dev/null)" ""
}

# Annotating before k3s has restarted onto the new IP would name an address
# the node does not have yet.
test_a_node_k3s_has_not_moved_yet_is_left_alone() {
    nodes "$(printf 'dietpi\t192.168.2.199\t192.168.2.199')"
    run_ensure_node_ip 100.117.134.62
    assert_eq "$(annotations)" ""
    assert_contains "$(cat "$WORK_DIR/output")" "re-run ./update.sh"
}

# k3s's vpn-auth hands the kubelet the Tailscale IPv6 too, and a healthy kubelet
# keeps the annotation at both. Narrowing it to the configured IPv4 dropped the
# IPv6 InternalIP until the kubelet put it back, on every ./update.sh.
test_a_dual_stack_annotation_on_the_right_ip_is_left_alone() {
    nodes "$(printf 'dietpi\t100.117.134.62,fd7a:115c:a1e0::c02b:863f\t100.117.134.62,fd7a:115c:a1e0::c02b:863f')"
    run_ensure_node_ip 100.117.134.62
    assert_eq "$(annotations)" ""
    assert_eq "$(cat "$WORK_DIR/output")" ""
}

test_quotes_comments_and_spaces_in_the_config_are_not_part_of_the_ip() {
    nodes "$(printf 'dietpi\t100.117.134.62\t192.168.2.199')"
    run_ensure_node_ip '"100.117.134.62"  # tailscale'
    assert_eq "$(annotations)" "--kubeconfig=/dev/null annotate node dietpi alpha.kubernetes.io/provided-node-ip=100.117.134.62 --overwrite"
}

test_a_list_with_a_space_after_the_comma_is_written_without_it() {
    nodes "$(printf 'dietpi\t10.0.0.5,2001:db8::5\t192.168.2.199')"
    run_ensure_node_ip '[10.0.0.5, 2001:db8::5]'
    assert_eq "$(annotations)" "--kubeconfig=/dev/null annotate node dietpi alpha.kubernetes.io/provided-node-ip=10.0.0.5,2001:db8::5 --overwrite"
}

# game-node-server-setup.sh restarts k3s and runs update.sh straight away, before
# k3s has written the new IP onto its node.
test_it_waits_for_k3s_to_report_the_new_ip() {
    nodes "$(printf 'dietpi\t192.168.2.199\t192.168.2.199')"
    printf 'dietpi\t100.117.134.62\t192.168.2.199\n' >"$WORK_DIR/nodes.next"
    ATTEMPTS=2 run_ensure_node_ip 100.117.134.62
    assert_eq "$(annotations)" "--kubeconfig=/dev/null annotate node dietpi alpha.kubernetes.io/provided-node-ip=100.117.134.62 --overwrite"
}

test_a_refused_annotate_is_reported_not_fatal() {
    nodes "$(printf 'dietpi\t100.117.134.62\t192.168.2.199')"
    touch "$WORK_DIR/annotate-fails"
    run_ensure_node_ip 100.117.134.62
    assert_contains "$(cat "$WORK_DIR/output")" "Could not move node dietpi"
}

run_tests
