#!/bin/bash

# shellcheck source=tests/scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# docker reports the architecture the k3d node runs on; uname is the fallback
# when docker can't be asked.
machine() {
    mkdir -p "$WORK_DIR/bin"
    if [ -n "$1" ]; then
        printf '#!/bin/sh\necho %s\n' "$1" >"$WORK_DIR/bin/docker"
    else
        printf '#!/bin/sh\nexit 1\n' >"$WORK_DIR/bin/docker"
    fi
    printf '#!/bin/sh\necho %s\n' "${2:-x86_64}" >"$WORK_DIR/bin/uname"
    chmod +x "$WORK_DIR/bin/docker" "$WORK_DIR/bin/uname"
}

game_server() {
    (
        export PATH="$WORK_DIR/bin:$PATH"
        # shellcheck source=utils/dev_game_server.sh
        source "$TEST_ROOT/utils/dev_game_server.sh"
        dev_game_server "$@"
    )
}

test_apple_silicon_plays_on_the_simulator() {
    machine aarch64
    assert_eq "$(game_server)" "simulator"
}

test_an_amd64_machine_runs_cs2() {
    machine x86_64
    assert_eq "$(game_server)" "cs2"
}

test_the_simulator_can_be_chosen_on_purpose() {
    machine x86_64
    assert_eq "$(game_server --simulator)" "simulator"
}

test_cs2_can_be_chosen_on_purpose() {
    machine aarch64
    assert_eq "$(game_server --cs2)" "cs2"
}

test_the_environment_chooses_when_no_flag_does() {
    machine aarch64
    assert_eq "$(DEV_GAME_SERVER=cs2 game_server)" "cs2"
    assert_eq "$(DEV_GAME_SERVER=cs2 game_server --simulator)" "simulator"
}

test_without_docker_the_machine_decides() {
    machine "" arm64
    assert_eq "$(game_server)" "simulator"
}

test_other_arguments_are_left_to_setup_env() {
    machine x86_64
    assert_eq "$(game_server --debug --kubeconfig /dev/null)" "cs2"
}

run_tests
