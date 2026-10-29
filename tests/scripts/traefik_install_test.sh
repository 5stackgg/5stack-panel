#!/bin/bash

# shellcheck source=tests/scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

STUB_BIN="$(cd "$(dirname "${BASH_SOURCE[0]}")/stub" && pwd)"
export PATH="$STUB_BIN:$PATH" KUBECONFIG=/dev/null

nginx_ports() {
    printf '%s' "$1" >"$WORK_DIR/nginx-http-port"
    printf '%s' "$2" >"$WORK_DIR/nginx-https-port"
}

ports_file() {
    printf '%s\n' "$@" >"$WORK_DIR/traefik-config.env"
}

run_carry_over() {
    (
        # shellcheck source=utils/colors.sh
        source "$TEST_ROOT/utils/colors.sh"
        # shellcheck source=utils/update_env_var.sh
        source "$TEST_ROOT/utils/update_env_var.sh"
        # shellcheck source=utils/install_traefik.sh
        source "$TEST_ROOT/utils/install_traefik.sh"
        carry_over_ingress_nginx_ports "$WORK_DIR/traefik-config.env"
    ) >"$WORK_DIR/output" 2>&1 || fail "carry_over_ingress_nginx_ports exited $?: $(cat "$WORK_DIR/output")"
}

port() {
    grep "^$1=" "$WORK_DIR/traefik-config.env" | tail -n 1
}

test_ingress_nginx_on_other_ports_keeps_them_through_the_switch() {
    nginx_ports 8080 8443
    ports_file HTTP_PORT=80 HTTPS_PORT=443
    run_carry_over
    assert_eq "$(port HTTP_PORT)" "HTTP_PORT=8080"
    assert_eq "$(port HTTPS_PORT)" "HTTPS_PORT=8443"
    assert_contains "$(cat "$WORK_DIR/output")" "8080/8443"
}

test_a_lost_ports_file_is_rebuilt_from_ingress_nginx() {
    nginx_ports 8080 8443
    run_carry_over
    assert_eq "$(port HTTP_PORT)" "HTTP_PORT=8080"
    assert_eq "$(port HTTPS_PORT)" "HTTPS_PORT=8443"
}

test_ports_set_in_the_file_win() {
    nginx_ports 8080 8443
    ports_file HTTP_PORT=9080 HTTPS_PORT=9443
    run_carry_over
    assert_eq "$(port HTTP_PORT)" "HTTP_PORT=9080"
    assert_eq "$(port HTTPS_PORT)" "HTTPS_PORT=9443"
}

test_ingress_nginx_on_the_defaults_changes_nothing() {
    nginx_ports 80 443
    ports_file HTTP_PORT=80 HTTPS_PORT=443
    run_carry_over
    assert_eq "$(cat "$WORK_DIR/traefik-config.env")" "$(printf 'HTTP_PORT=80\nHTTPS_PORT=443')"
    assert_eq "$(cat "$WORK_DIR/output")" ""
}

test_an_install_without_ingress_nginx_changes_nothing() {
    ports_file HTTP_PORT=80 HTTPS_PORT=443
    run_carry_over
    assert_eq "$(cat "$WORK_DIR/traefik-config.env")" "$(printf 'HTTP_PORT=80\nHTTPS_PORT=443')"
}

run_install_chart() {
    (
        # shellcheck source=utils/colors.sh
        source "$TEST_ROOT/utils/colors.sh"
        # shellcheck source=utils/output_redirect.sh
        source "$TEST_ROOT/utils/output_redirect.sh"
        # shellcheck source=utils/install_traefik.sh
        source "$TEST_ROOT/utils/install_traefik.sh"
        install_helm_chart gateway "$TEST_ROOT/charts/gateway" ""
    ) >"$WORK_DIR/output" 2>&1 || fail "install_helm_chart exited $?: $(cat "$WORK_DIR/output")"
}

calls() {
    grep -E ' (patch helmchart|delete job) ' "$WORK_DIR/calls" 2>/dev/null || true
}

test_a_rerun_after_a_failed_install_tries_it_again() {
    touch "$WORK_DIR/job-failed"
    echo "Error: context deadline exceeded" >"$WORK_DIR/job-logs"
    run_install_chart
    assert_eq "$(calls)" "--kubeconfig=/dev/null delete job helm-install-gateway -n kube-system"
}

test_a_release_waiting_for_intervention_is_reinstalled_on_the_rerun() {
    touch "$WORK_DIR/job-failed"
    echo "Release status is 'failed' and failure policy is 'abort', not 'reinstall'; waiting for operator intervention" >"$WORK_DIR/job-logs"
    run_install_chart
    assert_contains "$(calls)" "patch helmchart gateway -n kube-system --type merge -p {\"spec\":{\"failurePolicy\":\"reinstall\"}}"
    assert_contains "$(cat "$WORK_DIR/output")" "reinstalling it"
}

test_an_unchanged_chart_that_installed_is_left_alone() {
    run_install_chart
    assert_eq "$(calls)" ""
}

run_retire() {
    (
        export TRAEFIK_ADDRESS_TIMEOUT=0
        # shellcheck source=utils/colors.sh
        source "$TEST_ROOT/utils/colors.sh"
        # shellcheck source=utils/output_redirect.sh
        source "$TEST_ROOT/utils/output_redirect.sh"
        # shellcheck source=utils/retire_ingress_nginx.sh
        source "$TEST_ROOT/utils/retire_ingress_nginx.sh"
        retire_ingress_nginx "$@"
    ) >"$WORK_DIR/output" 2>&1
}

test_a_stalled_handover_gives_ingress_nginx_its_ports_back() {
    nginx_ports 8080 8443
    if run_retire; then
        fail "retire_ingress_nginx succeeded with no Traefik address"
    fi
    assert_contains "$(cat "$WORK_DIR/applied")" "name: ingress-nginx-controller"
    assert_contains "$(cat "$WORK_DIR/applied")" "port: 8080"
    assert_contains "$(cat "$WORK_DIR/applied")" "port: 8443"
    assert_contains "$(cat "$WORK_DIR/output")" "keeps serving the panel"
}

test_a_handover_that_lands_leaves_ingress_nginx_gone() {
    nginx_ports 80 443
    echo '[{"ip":"10.0.0.1"}]' >"$WORK_DIR/traefik-address"
    run_retire || fail "retire_ingress_nginx failed: $(cat "$WORK_DIR/output")"
    [ ! -f "$WORK_DIR/applied" ] || fail "ingress-nginx's Service was put back"
    assert_contains "$(cat "$WORK_DIR/calls")" "delete namespace ingress-nginx"
}

test_dev_retires_without_waiting_for_routes() {
    nginx_ports 80 443
    echo '[{"ip":"10.0.0.1"}]' >"$WORK_DIR/traefik-address"
    run_retire --immediately || fail "retire_ingress_nginx failed: $(cat "$WORK_DIR/output")"
    assert_not_contains "$(cat "$WORK_DIR/calls")" "wait httproute/api"
}

run_tests
