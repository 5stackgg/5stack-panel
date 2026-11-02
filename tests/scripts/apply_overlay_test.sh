#!/bin/bash

# shellcheck source=tests/scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

RENDERED='apiVersion: v1
kind: ConfigMap
metadata:
  name: example'

setup_stubs() {
    PANEL_DIR="$WORK_DIR/panel"
    mkdir -p "$PANEL_DIR/overlay" "$WORK_DIR/bin"
    printf '#!/bin/sh\ncat <<EOF\n%s\nEOF\n' "$RENDERED" >"$PANEL_DIR/kustomize"
    cat >"$WORK_DIR/bin/kubectl" <<EOF
#!/bin/sh
echo "\$*" >>"$WORK_DIR/kubectl-calls"
if [ "\$1" = apply ]; then cp "\$3" "$WORK_DIR/applied"; fi
EOF
    chmod +x "$PANEL_DIR/kustomize" "$WORK_DIR/bin/kubectl"
    export PATH="$WORK_DIR/bin:$PATH" PANEL_DIR KUBECONFIG=""
}

hook() {
    cat >"$WORK_DIR/pre-apply" <<EOF
#!/bin/sh
cp "\$1" "$WORK_DIR/checked"
echo "$2"
exit $1
EOF
    chmod +x "$WORK_DIR/pre-apply"
    export FIVESTACK_PRE_APPLY="$WORK_DIR/pre-apply"
}

run_apply() {
    (
        # shellcheck source=utils/colors.sh
        source "$TEST_ROOT/utils/colors.sh"
        # shellcheck source=utils/apply_overlay.sh
        source "$TEST_ROOT/utils/apply_overlay.sh"
        apply_overlay overlay 1 0
    ) >"$WORK_DIR/output" 2>&1
}

test_an_apply_without_the_5stack_service_goes_straight_to_kubectl() {
    setup_stubs
    run_apply || fail "apply_overlay exited $?: $(cat "$WORK_DIR/output")"
    assert_eq "$(cat "$WORK_DIR/applied")" "$RENDERED"
}

test_the_5stack_service_sees_the_rendered_overlay_before_it_is_applied() {
    setup_stubs
    hook 0 "no rollout without zero downtime"
    run_apply || fail "apply_overlay exited $?: $(cat "$WORK_DIR/output")"
    assert_eq "$(cat "$WORK_DIR/checked")" "$RENDERED"
    assert_eq "$(cat "$WORK_DIR/applied")" "$RENDERED"
}

test_the_5stack_service_can_stop_an_apply() {
    setup_stubs
    hook 1 "the panel did not drain within 30 minutes"
    run_apply && fail "apply_overlay carried on after the 5Stack service refused"
    [ ! -e "$WORK_DIR/kubectl-calls" ] || fail "kubectl ran: $(cat "$WORK_DIR/kubectl-calls")"
    assert_contains "$(cat "$WORK_DIR/output")" "the 5Stack service stopped overlay from being applied"
    assert_contains "$(cat "$WORK_DIR/output")" "the panel did not drain within 30 minutes"
}

run_tests
