#!/bin/bash

# An update while a game node is switched off, on a cluster with k3s's own
# add-ons as install.sh leaves them, and with CoreDNS and metrics-server on
# that game node: the scheduler puts them on any node. Right after the node
# drops they are down with it; five minutes on, Kubernetes evicts them.

# shellcheck source=tests/gateway/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
trap cleanup EXIT

API="api.$DOMAIN"
# shellcheck disable=SC2034 # read by run_k3s
K3S_DISABLE=--disable=traefik

if [ "${1:-}" = before-gateway-api ]; then
    K3S_IMAGE="$K3S_BEFORE_GATEWAY_API"
fi

update_panel() {
    install_traefik "$PANEL_DIR/overlays/config/traefik-config.env" && routing_layer http
}

cluster_state() {
    kubectl get nodes -o wide
    kubectl get pods -A -o wide
    kubectl get apiservices | grep -v Local
    kubectl -n kube-system get jobs,helmcharts
    kubectl get crd -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.conditions[?(@.type=="Established")].status}{"\n"}{end}'
} 2>&1

# Cordons the server so the add-ons restart on the game node.
add_ons_onto_game_node() {
    kubectl cordon "$PREFIX-k3s" >/dev/null || return 1
    kubectl -n kube-system rollout restart deployment/coredns deployment/metrics-server >/dev/null || return 1
    kubectl -n kube-system rollout status deployment/coredns --timeout=180s >/dev/null || return 1
    kubectl -n kube-system rollout status deployment/metrics-server --timeout=180s >/dev/null || return 1
    kubectl uncordon "$PREFIX-k3s" >/dev/null || return 1
    [ "$(kubectl -n kube-system get pods -l k8s-app=metrics-server -o jsonpath='{.items[*].spec.nodeName}')" = "$PREFIX-node" ]
}

add_ons_evicted() {
    for _ in $(seq 1 120); do
        [ "$(kubectl get apiservice v1beta1.metrics.k8s.io -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null)" = True ] &&
            [ -n "$(kubectl -n kube-system get pods -l k8s-app=kube-dns --field-selector "spec.nodeName=$PREFIX-k3s,status.phase=Running" -o name 2>/dev/null)" ] &&
            return 0
        sleep 5
    done
    return 1
}

test_update_gets_past_a_game_node_that_just_dropped() {
    docker kill "$PREFIX-node" >/dev/null || fail "could not switch the game node off"
    game_node_is NotReady || fail "the cluster never noticed the game node was off"
    if ! update_panel; then
        cluster_state
        fail "update.sh's routing steps failed right after a game node dropped"
    fi
    deploy_panel_stubs || {
        cluster_state
        fail "the stub backends never started"
    }
    wait_for 200 http "$API" /me
}

test_update_gets_past_a_game_node_that_stayed_off() {
    add_ons_evicted || {
        cluster_state
        fail "the add-ons never came back on the server"
    }
    set_env overlays/config/traefik-config.env TRUSTED_PROXIES 10.9.8.7
    if ! update_panel; then
        cluster_state
        fail "update.sh's routing steps failed with a game node off for minutes"
    fi
    wait_for 200 http "$API" /me
}

start_cluster || exit 1
make_panel || exit 1
join_game_node || exit 1
add_ons_onto_game_node || {
    cluster_state
    exit 1
}

run_test test_update_gets_past_a_game_node_that_just_dropped
cluster_state
run_test test_update_gets_past_a_game_node_that_stayed_off

summary
