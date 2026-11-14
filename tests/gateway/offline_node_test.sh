#!/bin/bash

# An update while a game node is switched off, as one is between events: off
# for long enough that the cluster marked it NotReady, and off a moment ago,
# while the cluster still schedules onto it.

# shellcheck source=tests/gateway/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
trap cleanup EXIT

API="api.$DOMAIN"

if [ "${1:-}" = before-gateway-api ]; then
    K3S_IMAGE="$K3S_BEFORE_GATEWAY_API"
fi

update_panel() {
    install_traefik "$PANEL_DIR/overlays/config/traefik-config.env" && routing_layer http
}

cluster_state() {
    kubectl get nodes -o wide
    kubectl get pods -A -o wide
    kubectl -n kube-system get jobs,helmcharts
    kubectl get crd -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.conditions[?(@.type=="Established")].status}{"\n"}{end}'
    docker logs --tail 60 "$PREFIX-k3s" 2>&1
}

test_update_gets_past_a_game_node_that_is_off() {
    docker kill "$PREFIX-node" >/dev/null || fail "could not switch the game node off"
    game_node_is NotReady || fail "the cluster never noticed the game node was off"
    if ! update_panel; then
        cluster_state
        fail "update.sh's routing steps failed with a game node off"
    fi
    deploy_panel_stubs || fail "the stub backends never started"
    wait_for 200 http "$API" /me
}

test_update_gets_past_a_game_node_that_just_dropped() {
    docker start "$PREFIX-node" >/dev/null || fail "could not switch the game node back on"
    game_node_is Ready || fail "the game node never came back"
    set_env overlays/config/traefik-config.env TRUSTED_PROXIES 10.9.8.7
    docker kill "$PREFIX-node" >/dev/null || fail "could not switch the game node off"
    if ! update_panel; then
        cluster_state
        fail "update.sh's routing steps failed right after a game node dropped"
    fi
    kubectl get pods -A -o wide
    wait_for 200 http "$API" /me
}

start_cluster || exit 1
make_panel || exit 1
join_game_node || exit 1

run_test test_update_gets_past_a_game_node_that_is_off
run_test test_update_gets_past_a_game_node_that_just_dropped

summary
