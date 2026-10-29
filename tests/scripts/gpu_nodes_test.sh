#!/bin/bash

# shellcheck source=tests/scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

STUB_BIN="$(cd "$(dirname "${BASH_SOURCE[0]}")/stub" && pwd)"

run_label_gpu_nodes() {
    (
        export PATH="$STUB_BIN:$PATH" KUBECONFIG=/dev/null
        # shellcheck source=utils/colors.sh
        source "$TEST_ROOT/utils/colors.sh"
        # shellcheck source=utils/gpu_nodes.sh
        source "$TEST_ROOT/utils/gpu_nodes.sh"
        label_gpu_nodes "$@"
    ) >"$WORK_DIR/output" 2>&1 || fail "label_gpu_nodes exited $?: $(cat "$WORK_DIR/output")"
}

labels() {
    sed 's/^--kubeconfig=\/dev\/null label node //' "$WORK_DIR/calls" 2>/dev/null || true
}

test_an_amd_node_gets_the_vendor_label_and_loses_nvidia_gpu() {
    run_label_gpu_nodes amd "gpu-1" "gpu-1" "" ""
    assert_eq "$(labels)" "gpu-1 5stack-game-streamer=true 5stack-gpu-vendor=amd --overwrite
gpu-1 nvidia-gpu- 5stack-gpu-integrated-"
}

test_an_integrated_amd_node_is_opted_in() {
    run_label_gpu_nodes amd "apu-1 gpu-1" "apu-1 gpu-1" "" "apu-1"
    assert_eq "$(labels)" "apu-1 5stack-game-streamer=true 5stack-gpu-vendor=amd 5stack-gpu-integrated=true --overwrite
apu-1 nvidia-gpu-
gpu-1 5stack-game-streamer=true 5stack-gpu-vendor=amd --overwrite
gpu-1 nvidia-gpu- 5stack-gpu-integrated-"
}

test_an_nvidia_node_drops_the_amd_labels() {
    run_label_gpu_nodes nvidia "gpu-1" "gpu-1" "gpu-1" ""
    assert_eq "$(labels)" "gpu-1 5stack-game-streamer=true nvidia-gpu=true --overwrite
gpu-1 5stack-gpu-vendor- 5stack-gpu-integrated-"
}

test_a_deselected_node_loses_every_gpu_label() {
    run_label_gpu_nodes amd "gpu-1 gpu-2" "gpu-1" "gpu-1 gpu-2" ""
    assert_contains "$(labels)" "gpu-2 nvidia-gpu- 5stack-gpu-vendor- 5stack-gpu-integrated- 5stack-game-streamer-"
    assert_contains "$(cat "$WORK_DIR/output")" "gpu-2: GPU labels removed"
}

test_a_node_never_selected_is_left_alone() {
    run_label_gpu_nodes amd "game-1 gpu-1" "gpu-1" "gpu-1" ""
    assert_not_contains "$(labels)" "game-1"
}

test_a_node_whose_name_contains_another_is_not_mistaken_for_it() {
    run_label_gpu_nodes amd "gpu-1 gpu-10" "gpu-10" "" ""
    assert_not_contains "$(labels)" "gpu-1 "
}

run_tests
