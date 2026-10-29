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

install_chart() {
    (
        # shellcheck source=utils/colors.sh
        source "$TEST_ROOT/utils/colors.sh"
        # shellcheck source=utils/output_redirect.sh
        source "$TEST_ROOT/utils/output_redirect.sh"
        # shellcheck source=utils/install_traefik.sh
        source "$TEST_ROOT/utils/install_traefik.sh"
        install_helm_chart gateway "$TEST_ROOT/charts/gateway" ""
    ) >"$WORK_DIR/output" 2>&1
}

run_install_chart() {
    install_chart || fail "install_helm_chart exited $?: $(cat "$WORK_DIR/output")"
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

# By the time update.sh runs again the failed Job's pod, and its logs, are gone;
# the release records say what state helm left it in.
test_a_release_waiting_for_intervention_is_reinstalled_on_the_rerun() {
    touch "$WORK_DIR/job-failed"
    printf '%s\n' "9 deployed" "10 failed" >"$WORK_DIR/releases-gateway"
    run_install_chart
    assert_contains "$(calls)" "patch helmchart gateway -n kube-system --type merge -p {\"spec\":{\"failurePolicy\":\"reinstall\"}}"
    assert_contains "$(cat "$WORK_DIR/output")" "reinstalling it"
}

test_a_failed_job_on_a_deployed_release_is_just_run_again() {
    touch "$WORK_DIR/job-failed"
    printf '%s\n' "1 superseded" "2 deployed" >"$WORK_DIR/releases-gateway"
    run_install_chart
    assert_eq "$(calls)" "--kubeconfig=/dev/null delete job helm-install-gateway -n kube-system"
}

test_a_failed_install_shows_helms_error_from_before_its_pod_went() {
    printf '%s\n' "uid-1||" "uid-1||True" >"$WORK_DIR/job-states"
    echo 'Error: INSTALLATION FAILED: Unable to continue with install: CustomResourceDefinition "httproutes.gateway.networking.k8s.io" exists' >"$WORK_DIR/pod-logs"
    if install_chart; then
        fail "install_helm_chart succeeded for a failed Job"
    fi
    assert_contains "$(cat "$WORK_DIR/output")" "Unable to continue with install"
    assert_not_contains "$(cat "$WORK_DIR/output")" "timed out waiting for the condition"
}

test_a_failed_install_whose_pod_left_nothing_says_so() {
    echo "uid-1||True" >"$WORK_DIR/job-states"
    if install_chart; then
        fail "install_helm_chart succeeded for a failed Job"
    fi
    assert_contains "$(cat "$WORK_DIR/output")" "its pod is already gone"
}

cluster_objects() {
    printf '%s\n' "$@" >"$WORK_DIR/cluster-objects"
}

hand_over() {
    (
        # shellcheck source=utils/colors.sh
        source "$TEST_ROOT/utils/colors.sh"
        # shellcheck source=utils/output_redirect.sh
        source "$TEST_ROOT/utils/output_redirect.sh"
        # shellcheck source=utils/install_traefik.sh
        source "$TEST_ROOT/utils/install_traefik.sh"
        adopt_orphaned_chart_objects "$TEST_ROOT/charts/gateway-crds" gateway-crds traefik
    ) >"$WORK_DIR/output" 2>&1
}

handovers() {
    grep -E ' (annotate|label) ' "$WORK_DIR/calls" 2>/dev/null || true
}

K3S_HTTPROUTES="CustomResourceDefinition/httproutes.gateway.networking.k8s.io|traefik-crd|kube-system"
K3S_GATEWAYS="CustomResourceDefinition/gateways.gateway.networking.k8s.io|traefik-crd|kube-system"

test_crds_left_by_k3s_traefik_are_handed_to_gateway_crds() {
    cluster_objects "$K3S_HTTPROUTES" "$K3S_GATEWAYS" \
        "CustomResourceDefinition/gatewayclasses.gateway.networking.k8s.io|gateway-crds|traefik" \
        "CustomResourceDefinition/helmcharts.helm.cattle.io||"
    hand_over || fail "adopt_orphaned_chart_objects failed: $(cat "$WORK_DIR/output")"
    assert_contains "$(handovers)" "annotate --overwrite customresourcedefinition/httproutes.gateway.networking.k8s.io customresourcedefinition/gateways.gateway.networking.k8s.io meta.helm.sh/release-name=gateway-crds meta.helm.sh/release-namespace=traefik"
    assert_contains "$(handovers)" "label --overwrite customresourcedefinition/httproutes.gateway.networking.k8s.io customresourcedefinition/gateways.gateway.networking.k8s.io app.kubernetes.io/managed-by=Helm"
    assert_not_contains "$(handovers)" gatewayclasses
    assert_not_contains "$(handovers)" helmcharts
}

test_k3s_still_running_its_traefik_stops_the_install() {
    cluster_objects "$K3S_HTTPROUTES"
    echo helmchart.helm.cattle.io/traefik-crd >"$WORK_DIR/helmcharts-traefik-crd"
    if hand_over; then
        fail "the CRDs of k3s's running Traefik were taken"
    fi
    assert_contains "$(cat "$WORK_DIR/output")" "--disable=traefik"
    assert_eq "$(handovers)" ""
}

test_crds_of_another_live_release_stop_the_install() {
    cluster_objects "CustomResourceDefinition/httproutes.gateway.networking.k8s.io|eg|envoy-gateway-system"
    echo secret/sh.helm.release.v1.eg.v1 >"$WORK_DIR/releases-eg"
    if hand_over; then
        fail "another release's CRDs were taken"
    fi
    assert_contains "$(cat "$WORK_DIR/output")" "belongs to the Helm release eg in envoy-gateway-system"
    assert_eq "$(handovers)" ""
}

test_crds_created_outside_helm_stop_the_install() {
    cluster_objects "CustomResourceDefinition/httproutes.gateway.networking.k8s.io||"
    if hand_over; then
        fail "CRDs created outside Helm were taken"
    fi
    assert_contains "$(cat "$WORK_DIR/output")" "created outside Helm"
    assert_eq "$(handovers)" ""
}

# Traefik's own chart re-creates the traefik.io CRDs without Helm's marks once
# gateway-crds is installed; an update after that must not trip over them.
test_an_installed_release_is_left_to_helm() {
    cluster_objects "CustomResourceDefinition/ingressroutes.traefik.io||" \
        "CustomResourceDefinition/httproutes.gateway.networking.k8s.io|gateway-crds|traefik"
    echo secret/sh.helm.release.v1.gateway-crds.v1 >"$WORK_DIR/releases-gateway-crds"
    hand_over || fail "adopt_orphaned_chart_objects failed: $(cat "$WORK_DIR/output")"
    assert_eq "$(handovers)" ""
}

test_a_first_install_that_failed_still_hands_k3s_crds_over() {
    cluster_objects "$K3S_HTTPROUTES"
    echo helmchart.helm.cattle.io/gateway-crds >"$WORK_DIR/helmcharts-gateway-crds"
    hand_over || fail "adopt_orphaned_chart_objects failed: $(cat "$WORK_DIR/output")"
    assert_contains "$(handovers)" "annotate --overwrite customresourcedefinition/httproutes.gateway.networking.k8s.io"
}

test_a_cluster_with_nothing_left_over_hands_nothing_over() {
    cluster_objects "CustomResourceDefinition/helmcharts.helm.cattle.io||" \
        "CustomResourceDefinition/httproutes.gateway.networking.k8s.io|gateway-crds|traefik" \
        "ValidatingAdmissionPolicy/safe-upgrades.gateway.networking.k8s.io|gateway-crds|traefik"
    hand_over || fail "adopt_orphaned_chart_objects failed: $(cat "$WORK_DIR/output")"
    assert_eq "$(handovers)" ""
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
