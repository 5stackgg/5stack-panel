#!/bin/bash

# An install that is still on ingress-nginx -- the controller, its admission
# webhook, the panel's Ingresses as they were, and another app's nginx-class
# Ingress with forward-auth -- taken through update.sh's routing steps:
# install_traefik, the overlay's Gateway and routes, retire_ingress_nginx.

# shellcheck source=tests/gateway/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
trap cleanup EXIT

INGRESS_NGINX_MANIFEST=https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.13.9/deploy/static/provider/baremetal/deploy.yaml
INGRESS_NGINX_SHA256=946884f0b417d7af1bc50d8896bd8c201b90fda25813cf797e050ee19b53e1c4
API="api.$DOMAIN"
HLS="hls.$DOMAIN"
ORIGIN="https://$DOMAIN"

# Applies while ingress-nginx's admission webhook may still be starting.
apply_with_retries() {
    for _ in $(seq 1 30); do
        kubectl apply -f "$1" >/dev/null 2>&1 && return 0
        sleep 4
    done
    kubectl apply -f "$1"
}

install_ingress_nginx() {
    curl -fsSL "$INGRESS_NGINX_MANIFEST" -o "$WORK_DIR/ingress-nginx.yaml" || return 1
    echo "$INGRESS_NGINX_SHA256  $WORK_DIR/ingress-nginx.yaml" | shasum -a 256 -c - >/dev/null || return 1
    kubectl apply -f "$WORK_DIR/ingress-nginx.yaml" >/dev/null || return 1
    kubectl -n ingress-nginx rollout status deployment/ingress-nginx-controller --timeout=300s >/dev/null || return 1
    kubectl create namespace 5stack >/dev/null || return 1
    apply_with_retries "$HERE/fixtures/ingress-nginx-panel.yaml"
}

# Another app on the same cluster that stays on an nginx-class Ingress: plain
# HTTP, its own forward-auth with a sign-in redirect, a body limit, no
# buffering and long timeouts.
deploy_other_app() {
    deploy_stub qx "80:qx,8000:qx-auth" "qx-app:80" "qx-auth:8000" || return 1
    cat >"$WORK_DIR/qx-ingress.yaml" <<'EOF'
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: qx-control
  namespace: qx
  annotations:
    nginx.ingress.kubernetes.io/auth-url: http://qx-auth.qx.svc.cluster.local:8000/qx/authorize
    nginx.ingress.kubernetes.io/auth-signin: https://qx.test/login
    nginx.ingress.kubernetes.io/proxy-body-size: 8m
    nginx.ingress.kubernetes.io/proxy-buffering: "off"
    nginx.ingress.kubernetes.io/proxy-read-timeout: "3600"
    nginx.ingress.kubernetes.io/proxy-send-timeout: "3600"
spec:
  ingressClassName: nginx
  rules:
    - host: qx.test
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: qx-app
                port:
                  number: 80
EOF
    apply_with_retries "$WORK_DIR/qx-ingress.yaml"
}

expect_other_app_routes_with_its_auth() {
    call http qx.test /dashboard
    expect_code 302
    case "$(header Location)" in
        https://qx.test/login\?rd=*) ;;
        *) fail "no sign-in redirect: $(header Location)" ;;
    esac
    call http qx.test /dashboard -H 'Cookie: session=ok'
    expect_code 200
    expect_json .backend qx
    expect_json .path /dashboard
    client sh -c 'head -c 4194304 /dev/zero >/tmp/small; head -c 10485760 /dev/zero >/tmp/large'
    call http qx.test /upload -H 'Cookie: session=ok' --data-binary @/tmp/small
    expect_code 200
    expect_json .body_bytes 4194304
    call http qx.test /upload -H 'Cookie: session=ok' --data-binary @/tmp/large
    expect_code 413
}

test_before_the_update_ingress_nginx_serves_everything() {
    wait_for 200 https "$API" /me
    expect_json .backend api
    kubectl -n ingress-nginx get service ingress-nginx-controller >/dev/null 2>&1 || fail "ingress-nginx is not serving"
    kubectl get namespace traefik >/dev/null 2>&1 && fail "Traefik is already installed"
    expect_other_app_routes_with_its_auth
}

test_ingress_nginx_is_gone() {
    local phase
    phase="$(kubectl get namespace ingress-nginx -o jsonpath='{.status.phase}' 2>/dev/null)"
    [ -z "$phase" ] || [ "$phase" = Terminating ] || fail "ingress-nginx namespace is $phase"
    kubectl get validatingwebhookconfiguration ingress-nginx-admission >/dev/null 2>&1 && fail "the admission webhook is still there"
    kubectl get clusterrole ingress-nginx >/dev/null 2>&1 && fail "the ingress-nginx ClusterRole is still there"
    [ "$(kubectl get ingressclass nginx -o jsonpath='{.spec.controller}')" = k8s.io/ingress-nginx ] || fail "IngressClass nginx is gone"
    [ -z "$(kubectl -n 5stack get ingress -o name)" ] || fail "panel Ingresses left: $(kubectl -n 5stack get ingress -o name)"
}

test_panel_routes_go_through_traefik() {
    call https "$API" /me
    expect_code 200
    expect_json .backend api
    [ "$(header Server)" != nginx ] || fail "still answered by ingress-nginx"
    call https "$API" /nope
    expect_code 404
    call https "ws.$DOMAIN" /x
    expect_json .path /ws/x
    call https "$HLS" /m1/whep -X OPTIONS -H "Origin: $ORIGIN" -H 'Access-Control-Request-Method: POST'
    expect_code 200
    expect_header Access-Control-Allow-Origin "$ORIGIN"
    call https "$HLS" /m1/index.m3u8
    expect_code 401
    call https "$HLS" /m1/whep -X POST -H 'Cookie: session=ok' --data-binary 'v=0'
    expect_code 201
    call http "$API" /me
    expect_code 308
    call https "$API" /me
    expect_json '.headers["x-forwarded-for"]' "$CLIENT_IP"
}

test_the_other_app_keeps_its_nginx_ingress_and_auth() {
    [ "$(kubectl -n qx get ingress qx-control -o jsonpath='{.spec.ingressClassName}')" = nginx ] || fail "qx Ingress changed"
    expect_other_app_routes_with_its_auth
    [ "$(header Server)" != nginx ] || fail "still answered by ingress-nginx"
}

test_the_switch_costs_seconds() {
    local longest
    longest="$(jq -r .longest_outage <<<"$POLL")"
    echo "      outage while ports moved: ${longest}s ($(jq -r '"\(.failed) of \(.requests)"' <<<"$POLL") requests failed)"
    awk -v t="$longest" 'BEGIN { exit !(t < 30) }' || fail "$POLL"
}

test_a_plugin_ingress_pins_a_role_with_auth_snippet() {
    kubectl apply -f - >/dev/null <<EOF
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: plugin-admin
  namespace: 5stack
  annotations:
    nginx.ingress.kubernetes.io/auth-url: http://api.5stack.svc.cluster.local:5585/plugins/authorize
    nginx.ingress.kubernetes.io/auth-snippet: |
      proxy_set_header X-5stack-Required-Role administrator;
spec:
  ingressClassName: nginx
  rules:
    - host: plugin.$DOMAIN
      http:
        paths:
          - path: /api
            pathType: Prefix
            backend:
              service:
                name: web
                port:
                  number: 3000
EOF
    wait_for 401 http "plugin.$DOMAIN" /api/x
    call http "plugin.$DOMAIN" /api/x -H 'Cookie: session=ok'
    expect_code 403
    call http "plugin.$DOMAIN" /api/x -H 'Cookie: session=admin'
    expect_code 200
    expect_json .backend web
    call http "plugin.$DOMAIN" /api/x -X OPTIONS -H "Origin: $ORIGIN" -H 'Access-Control-Request-Method: POST'
    expect_code 200
    call http "plugin.$DOMAIN" /api/x -H 'X-Original-Method: OPTIONS'
    expect_code 401
}

test_running_the_update_again_changes_nothing() {
    install_traefik "$PANEL_DIR/overlays/config/traefik-config.env" >/dev/null || fail "install_traefik failed"
    routing_layer https || fail "the overlay did not apply"
    retire_ingress_nginx || fail "retire_ingress_nginx failed"
    call https "$API" /me
    expect_code 200
    expect_other_app_routes_with_its_auth
}

start_cluster || exit 1
make_panel || exit 1
install_ingress_nginx || exit 1
deploy_panel_stubs || exit 1
tls_secret 5stack-ssl "$DOMAIN" "$API" "demos.$DOMAIN" "ws.$DOMAIN" "tv.$DOMAIN" "search.$DOMAIN" "console.$DOMAIN" || exit 1
tls_secret 5stack-mediamtx-ssl "$HLS" || exit 1
deploy_other_app || exit 1

run_test test_before_the_update_ingress_nginx_serves_everything

client rm -f /tmp/stop
docker exec -d "$PREFIX-client" sh -c "python3 /client.py poll $NODE_IP $API /me /tmp/stop >/tmp/poll.json"
sleep 2
install_traefik "$PANEL_DIR/overlays/config/traefik-config.env" || exit 1
routing_layer https || exit 1
retire_ingress_nginx || exit 1
sleep 5
client touch /tmp/stop
for _ in $(seq 1 10); do
    client test -s /tmp/poll.json && break
    sleep 1
done
POLL="$(client cat /tmp/poll.json)"

for name in \
    test_ingress_nginx_is_gone \
    test_panel_routes_go_through_traefik \
    test_the_other_app_keeps_its_nginx_ingress_and_auth \
    test_the_switch_costs_seconds \
    test_a_plugin_ingress_pins_a_role_with_auth_snippet \
    test_running_the_update_again_changes_nothing; do
    run_test "$name"
done

summary
