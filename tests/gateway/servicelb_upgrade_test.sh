#!/bin/bash

# An install whose Traefik still sits behind k3s ServiceLB, as the panel ran it
# before Traefik bound the host's ports itself, taken through update.sh's
# install_traefik.

# shellcheck source=tests/gateway/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
trap cleanup EXIT

API="api.$DOMAIN"
PORTS_ENV="$PANEL_DIR/overlays/config/traefik-config.env"

install_traefik_behind_servicelb() {
    local crd
    install_helm_chart gateway-crds "$PANEL_DIR/charts/gateway-crds" "" >/dev/null || return 1
    for crd in gatewayclasses.gateway.networking.k8s.io gateways.gateway.networking.k8s.io \
        httproutes.gateway.networking.k8s.io middlewares.traefik.io; do
        kubectl wait --for=condition=Established "crd/$crd" --timeout=120s >/dev/null || return 1
    done
    install_helm_chart gateway "$PANEL_DIR/charts/gateway" "$(cat <<'EOF'
traefik:
  service:
    spec: {type: LoadBalancer, externalTrafficPolicy: Local}
  updateStrategy:
    rollingUpdate: {maxUnavailable: 0, maxSurge: 1}
EOF
)" >/dev/null || return 1
    kubectl -n traefik rollout status deployment/traefik --timeout=300s >/dev/null || return 1
    for _ in $(seq 1 90); do
        [ -n "$(kubectl -n traefik get service traefik -o jsonpath='{.status.loadBalancer.ingress}')" ] && return 0
        sleep 2
    done
    return 1
}

traefik_pod() {
    kubectl -n traefik get pods -l app.kubernetes.io/name=traefik -o jsonpath='{.items[*].metadata.uid}'
}

test_behind_servicelb_every_request_comes_from_its_pod() {
    wait_for 200 https "$API" /me
    case "$(json '.headers["x-forwarded-for"]')" in
        10.42.*) ;;
        *) fail "expected a ServiceLB pod address, got $(json '.headers["x-forwarded-for"]')" ;;
    esac
}

test_the_move_costs_seconds() {
    local longest
    longest="$(jq -r .longest_outage <<<"$POLL")"
    echo "      outage while Traefik moved: ${longest}s ($(jq -r '"\(.failed) of \(.requests)"' <<<"$POLL") requests failed)"
    awk -v t="$longest" 'BEGIN { exit !(t < 30) }' || fail "$POLL"
}

test_servicelb_no_longer_fronts_traefik() {
    [ "$(kubectl -n traefik get service traefik -o jsonpath='{.spec.type}')" = ClusterIP ] || fail "Traefik's Service is still $(kubectl -n traefik get service traefik -o jsonpath='{.spec.type}')"
    [ -z "$(kubectl -n kube-system get daemonset -l svccontroller.k3s.cattle.io/svcname=traefik -o name)" ] || fail "svclb-traefik is still running"
}

test_the_client_ip_reaches_the_backend() {
    call https "$API" /me
    expect_code 200
    expect_json '.headers["x-forwarded-for"]' "$CLIENT_IP"
    expect_json '.headers["x-real-ip"]' "$CLIENT_IP"
    call http "$API" /me
    expect_code 308
}

test_running_the_update_again_changes_nothing() {
    local before
    before="$(traefik_pod)"
    install_traefik "$PORTS_ENV" >/dev/null || fail "install_traefik failed"
    move_traefik_to_host_ports "$PORTS_ENV" >/dev/null || fail "move_traefik_to_host_ports failed"
    [ "$(traefik_pod)" = "$before" ] || fail "Traefik was restarted"
    call https "$API" /me
    expect_code 200
}

start_cluster || exit 1
make_panel || exit 1
install_traefik_behind_servicelb || exit 1
deploy_panel_stubs || exit 1
routing_layer https || exit 1
tls_secret 5stack-ssl "$DOMAIN" "$API" "demos.$DOMAIN" "ws.$DOMAIN" "tv.$DOMAIN" "search.$DOMAIN" "console.$DOMAIN" || exit 1
tls_secret 5stack-mediamtx-ssl "hls.$DOMAIN" || exit 1

run_test test_behind_servicelb_every_request_comes_from_its_pod

client rm -f /tmp/stop
docker exec -d "$PREFIX-client" sh -c "python3 /client.py poll $NODE_IP $API /me /tmp/stop >/tmp/poll.json"
sleep 2
install_traefik "$PORTS_ENV" || exit 1
sleep 5
client touch /tmp/stop
for _ in $(seq 1 10); do
    client test -s /tmp/poll.json && break
    sleep 1
done
POLL="$(client cat /tmp/poll.json)"

for name in \
    test_the_move_costs_seconds \
    test_servicelb_no_longer_fronts_traefik \
    test_the_client_ip_reaches_the_backend \
    test_running_the_update_again_changes_nothing; do
    run_test "$name"
done

summary
