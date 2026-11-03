#!/bin/bash

# A panel installed while k3s left the Gateway API CRDs to it, then k3s
# upgraded in place as the panel's k3s updates do it: the same datastore and
# flags on a new binary. From 1.37 k3s's own gateway-api-crd chart installs
# beside gateway-crds' copies, and the next update.sh hands them over to it,
# safe-upgrades policy and all.

# shellcheck source=tests/gateway/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
trap cleanup EXIT

API="api.$DOMAIN"

gateway_api_objects() {
    chart_objects "$PANEL_DIR/charts/gateway-crds/templates/gateway-api.yaml"
}

# release/namespace from an object's Helm marks, or "missing".
owner() {
    kubectl get "$1" -o jsonpath='{.metadata.annotations.meta\.helm\.sh/release-name}/{.metadata.annotations.meta\.helm\.sh/release-namespace}' 2>/dev/null ||
        echo missing
}

expect_gateway_api_owned_by() {
    local object
    for object in $(gateway_api_objects); do
        [ "$(owner "$object")" = "$1" ] || fail "$object belongs to $(owner "$object"), not $1"
    done
}

update_panel() {
    install_traefik "$PANEL_DIR/overlays/config/traefik-config.env" && routing_layer http
}

# k3s runs its chart's install Job a little after it starts.
k3s_chart_installed() {
    for _ in $(seq 1 60); do
        [ "$(kubectl -n kube-system get job helm-install-gateway-api-crd -o jsonpath='{.status.succeeded}' 2>/dev/null)" = 1 ] &&
            return 0
        sleep 3
    done
    return 1
}

crds_generation() {
    kubectl -n kube-system get helmchart gateway-crds -o jsonpath='{.metadata.generation}'
}

test_gateway_crds_holds_the_gateway_api_before_k3s_does() {
    expect_gateway_api_owned_by gateway-crds/traefik
    wait_for 200 http "$API" /me
}

test_the_panel_serves_through_the_k3s_upgrade() {
    k3s_chart_installed || fail "$K3S_IMAGE never installed its gateway-api-crd chart"
    wait_for 200 http "$API" /me
}

test_update_hands_the_gateway_api_to_k3s() {
    update_panel || fail "update.sh's routing steps failed after the k3s upgrade"
    expect_gateway_api_owned_by gateway-api-crd/kube-system
    case "$(kubectl -n kube-system get helmchart gateway-crds -o jsonpath='{.spec.valuesContent}')" in
        *"gatewayApi: false"*) ;;
        *) fail "gateway-crds still installs the Gateway API" ;;
    esac
    kubectl wait --for=condition=Established crd/middlewares.traefik.io --timeout=10s >/dev/null ||
        fail "gateway-crds dropped Traefik's CRDs with the Gateway API's"
    wait_for 200 http "$API" /me
}

test_a_restart_keeps_the_handover() {
    k3s_chart_installed || fail "k3s didn't run its gateway-api-crd chart again"
    expect_gateway_api_owned_by gateway-api-crd/kube-system
    wait_for 200 http "$API" /me
}

test_another_update_changes_nothing() {
    local before
    before="$(crds_generation)"
    update_panel || fail "update.sh's routing steps failed on a second run"
    [ "$(crds_generation)" = "$before" ] || fail "a second update changed the gateway-crds HelmChart"
    expect_gateway_api_owned_by gateway-api-crd/kube-system
    wait_for 200 http "$API" /me
}

start_cluster "$K3S_BEFORE_GATEWAY_API" || exit 1
make_panel || exit 1
update_panel >/dev/null || exit 1
deploy_panel_stubs || exit 1
run_test test_gateway_crds_holds_the_gateway_api_before_k3s_does

run_k3s "$K3S_IMAGE" || exit 1
run_test test_the_panel_serves_through_the_k3s_upgrade
run_test test_update_hands_the_gateway_api_to_k3s

# A reboot, or the next k3s patch.
run_k3s "$K3S_IMAGE" || exit 1
run_test test_a_restart_keeps_the_handover
run_test test_another_update_changes_nothing

summary
