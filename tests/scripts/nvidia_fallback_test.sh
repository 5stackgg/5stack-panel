#!/bin/bash

# shellcheck source=tests/scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BASE="$TEST_ROOT/base/game-server-node-connector/daemonset.yaml"
NVIDIA="$TEST_ROOT/overlays/nvidia/game-server-node-connector-nvidia.yaml"
FALLBACK="$TEST_ROOT/overlays/nvidia/game-server-node-connector-nvidia-fallback.yaml"

require_fallback() {
    [ -f "$FALLBACK" ] || fail "no fallback DaemonSet at $FALLBACK"
}

mounts() {
    sed -n '/^ *volumeMounts:/,$p' "$1"
}

test_the_fallback_mounts_what_the_connector_does() {
    require_fallback
    assert_eq "$(mounts "$FALLBACK")" "$(mounts "$NVIDIA")"
    assert_eq "$(mounts "$FALLBACK")" "$(mounts "$BASE")"
}

# The NVIDIA runtime hook fails on NVML when the driver isn't loaded.
test_the_fallback_starts_without_the_nvidia_runtime() {
    require_fallback
    assert_not_contains "$(cat "$FALLBACK")" "runtimeClassName"
    assert_not_contains "$(cat "$FALLBACK")" "NVIDIA_VISIBLE_DEVICES"
}

# On hostNetwork a containerPort is a hostPort, and the NVIDIA connector's pod
# holds 8585 on the node even when it can't start.
test_the_fallback_claims_no_host_port() {
    require_fallback
    assert_not_contains "$(cat "$FALLBACK")" "containerPort"
}

test_the_fallback_runs_only_on_nvidia_gpu_nodes_as_the_fallback() {
    require_fallback
    assert_contains "$(cat "$FALLBACK")" 'key: nvidia-gpu
                    operator: In
                    values: ["true"]'
    assert_contains "$(cat "$FALLBACK")" '- name: NVIDIA_DRIVER_FALLBACK
              value: "true"'
    assert_contains "$(cat "$FALLBACK")" "image: ghcr.io/5stackgg/game-server-node-connector:latest"
}

test_the_nvidia_overlay_deploys_the_fallback() {
    assert_contains "$(cat "$TEST_ROOT/overlays/nvidia/kustomization.yaml")" "- game-server-node-connector-nvidia-fallback.yaml"
}

run_tests
