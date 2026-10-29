#!/bin/bash

# k3s in Docker, with the panel's routing layer installed by the same functions
# update.sh calls, in front of stub backends named like the real Services.
# Requests come from a separate client container on the same Docker network,
# so the client IP the backends see is a real peer's. One cluster at a time;
# everything is named after $PREFIX and removed on exit.

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_ROOT="${TEST_ROOT:-$(cd "$HERE/../.." && pwd)}"
PREFIX="${PREFIX:-gateway-test}"
K3S_IMAGE=rancher/k3s:v1.36.5-k3s1@sha256:057cfd5a9d51b89f1f0ee139c28d5d5fdd5aa7ddeac2742a0ba90c6dbc0329bb
PYTHON_IMAGE=python:3.13.18-alpine3.24@sha256:bbc0290146ebe0a8b9a8ed07d3f2c7bdeb4d917fc93300a4e47490c8b5a11b48
DOMAIN=5stack.test
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/gateway-test.XXXXXX")"
PANEL_DIR="$WORK_DIR/panel"
KUBECONFIG="$WORK_DIR/kubeconfig"
DEBUG=false
TESTS_PASSED=0
TESTS_FAILED=0
export KUBECONFIG PANEL_DIR DEBUG

cleanup() {
    docker rm -f -v "$PREFIX-k3s" "$PREFIX-client" >/dev/null 2>&1
    docker network rm "$PREFIX-net" >/dev/null 2>&1
    rm -rf "$WORK_DIR"
}

fail() {
    echo "      $*"
    exit 1
}

run_test() {
    if ("$1"); then
        TESTS_PASSED=$((TESTS_PASSED + 1))
        echo "ok   $1"
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        echo "FAIL $1"
    fi
}

summary() {
    echo
    echo "$TESTS_PASSED passed, $TESTS_FAILED failed"
    [ "$TESTS_FAILED" -eq 0 ]
}

client() {
    docker exec "$PREFIX-client" "$@"
}

start_cluster() {
    local port
    cleanup
    mkdir -p "$WORK_DIR"
    docker network create "$PREFIX-net" >/dev/null || return 1
    docker run -d --name "$PREFIX-k3s" --hostname "$PREFIX-k3s" --network "$PREFIX-net" --privileged \
        --tmpfs /run --tmpfs /var/run -p 127.0.0.1::6443 "$K3S_IMAGE" server \
        --disable=traefik --disable=metrics-server --disable=local-storage --tls-san 127.0.0.1 >/dev/null || return 1
    port="$(docker port "$PREFIX-k3s" 6443/tcp | head -n 1 | sed 's/.*://')"
    for _ in $(seq 1 90); do
        docker exec "$PREFIX-k3s" test -s /etc/rancher/k3s/k3s.yaml 2>/dev/null && break
        sleep 2
    done
    docker exec "$PREFIX-k3s" cat /etc/rancher/k3s/k3s.yaml | sed "s#https://127.0.0.1:6443#https://127.0.0.1:$port#" >"$KUBECONFIG"
    for _ in $(seq 1 90); do
        kubectl wait --for=condition=Ready node --all --timeout=5s >/dev/null 2>&1 && break
        sleep 2
    done
    kubectl wait --for=condition=Ready node --all --timeout=5s >/dev/null || return 1
    NODE_IP="$(docker inspect -f "{{(index .NetworkSettings.Networks \"$PREFIX-net\").IPAddress}}" "$PREFIX-k3s")"

    docker run -d --name "$PREFIX-client" --network "$PREFIX-net" "$PYTHON_IMAGE" sleep infinity >/dev/null || return 1
    client apk add --no-cache -q curl jq openssl >/dev/null || return 1
    docker cp "$HERE/client.py" "$PREFIX-client:/client.py" >/dev/null
    # shellcheck disable=SC2034
    CLIENT_IP="$(docker inspect -f "{{(index .NetworkSettings.Networks \"$PREFIX-net\").IPAddress}}" "$PREFIX-client")"
}

set_env() {
    local file="$PANEL_DIR/$1"
    [ -f "$file" ] || cp "$file.example" "$file"
    grep -v "^$2=" "$file" >"$file.tmp" || true
    printf '%s=%s\n' "$2" "$3" >>"$file.tmp"
    mv "$file.tmp" "$file"
}

# A copy of the checkout configured as setup-env.sh would leave it, with the
# panel's own scripts sourced from it.
make_panel() {
    local dir file
    mkdir -p "$PANEL_DIR"
    (cd "$TEST_ROOT" && tar --exclude=./.git --exclude=./kustomize -cf - .) | (cd "$PANEL_DIR" && tar -xf -)
    for dir in overlays/config overlays/local-secrets overlays/mediamtx overlays/coturn; do
        for file in "$PANEL_DIR/$dir"/*.env.example; do
            cp "$file" "${file%.example}"
        done
    done
    set_env overlays/config/api-config.env WEB_DOMAIN "$DOMAIN"
    set_env overlays/config/api-config.env API_DOMAIN "api.$DOMAIN"
    set_env overlays/config/api-config.env WS_DOMAIN "ws.$DOMAIN"
    set_env overlays/config/api-config.env RELAY_DOMAIN "tv.$DOMAIN"
    set_env overlays/config/api-config.env DEMOS_DOMAIN "demos.$DOMAIN"
    set_env overlays/config/api-config.env GAME_STREAM_DOMAIN "hls.$DOMAIN"
    set_env overlays/config/api-config.env MAIL_FROM "hello@$DOMAIN"
    set_env overlays/config/s3-config.env S3_CONSOLE_HOST "console.$DOMAIN"
    set_env overlays/config/typesense-config.env TYPESENSE_HOST "search.$DOMAIN"
    set_env overlays/mediamtx/mediamtx.env GAME_STREAM_DOMAIN "hls.$DOMAIN"

    local script
    for script in colors.sh output_redirect.sh apply_overlay.sh setup_kustomize.sh write_overlays.sh \
        update_env_var.sh install_traefik.sh retire_ingress_nginx.sh; do
        # shellcheck source=/dev/null
        source "$PANEL_DIR/utils/$script"
    done
    setup_kustomize >/dev/null || return 1
}

# The kinds of the overlay update.sh applies that make up the routing layer.
# The rest (databases, the api itself) is what the stub backends stand in for.
routing_layer() {
    local protocol="$1"
    write_overlays
    "$PANEL_DIR/kustomize" build "$PANEL_DIR/overlays/local-secrets-$protocol" >"$WORK_DIR/overlay.yaml" || return 1
    python3 -I - "$WORK_DIR/overlay.yaml" "$WORK_DIR/routing.yaml" "$WORK_DIR/issuer.yaml" <<'PY'
import re, sys
docs = open(sys.argv[1]).read().split("\n---\n")
kind = lambda d: (re.search(r"(?m)^kind: (\S+)$", d) or [None, None])[1]
routing = [d for d in docs if kind(d) in ("Namespace", "Gateway", "HTTPRoute", "Middleware", "IngressClass")
           or (kind(d) == "Secret" and re.search(r"(?m)^  name: 5stack-reverse-proxy-tls$", d))]
open(sys.argv[2], "w").write("\n---\n".join(routing) + "\n")
open(sys.argv[3], "w").write("\n---\n".join(d for d in docs if kind(d) == "Issuer") + "\n")
PY
    kubectl apply -f "$WORK_DIR/routing.yaml" >/dev/null
}

# Pods running backend.py, listening on PORTS, behind one Service per entry
# of SERVICES ("name:port[,port]").
deploy_stub() {
    local ns="$1" ports="$2" service svc_name svc_ports port
    shift 2
    kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
    kubectl -n "$ns" create configmap stub-backend --from-file=backend.py="$HERE/backend.py" \
        --dry-run=client -o yaml | kubectl apply -f - >/dev/null
    kubectl apply -f - >/dev/null <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: stub
  namespace: $ns
spec:
  selector:
    matchLabels: {app: stub}
  template:
    metadata:
      labels: {app: stub}
    spec:
      containers:
        - name: stub
          image: $PYTHON_IMAGE
          command: [python3, -u, /app/backend.py]
          env:
            - {name: PORTS, value: "$ports"}
          volumeMounts:
            - {name: app, mountPath: /app}
      volumes:
        - name: app
          configMap: {name: stub-backend}
EOF
    for service in "$@"; do
        svc_name="${service%%:*}"
        svc_ports=""
        for port in ${service#*:}; do
            svc_ports="$svc_ports
    - {name: p$port, port: $port, targetPort: $port}"
        done
        kubectl apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Service
metadata:
  name: $svc_name
  namespace: $ns
spec:
  selector: {app: stub}
  ports:$svc_ports
EOF
    done
    kubectl -n "$ns" rollout status deployment/stub --timeout=180s >/dev/null
}

deploy_panel_stubs() {
    deploy_stub 5stack \
        "5585:api,8080:hasura,3000:web,9000:rustfs,9001:rustfs-console,8108:typesense,8888:mediamtx-hls,8889:mediamtx-whip,8089:acme-solver" \
        "api:5585" "hasura:8080" "web:3000" "rustfs:9000 9001" "typesense:8108" "mediamtx:8888 8889" "acme-solver:8089"
}

# A self-signed kubernetes.io/tls Secret in 5stack for the given hosts.
tls_secret() {
    local name="$1" san="" host
    shift
    for host in "$@"; do
        san="${san:+$san,}DNS:$host"
    done
    client openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj "/CN=$1" -addext "subjectAltName=$san" \
        -keyout /tmp/tls.key -out /tmp/tls.crt >/dev/null 2>&1 || return 1
    docker cp "$PREFIX-client:/tmp/tls.key" "$WORK_DIR/tls.key" >/dev/null
    docker cp "$PREFIX-client:/tmp/tls.crt" "$WORK_DIR/tls.crt" >/dev/null
    kubectl -n 5stack create secret tls "$name" --cert="$WORK_DIR/tls.crt" --key="$WORK_DIR/tls.key" \
        --dry-run=client -o yaml | kubectl apply -f - >/dev/null
}

# One request from the client container: sets CODE, HEADERS and BODY.
#   call https api.5stack.test /me [curl args...]
call() {
    local scheme="$1" host="$2" path="$3" port=80 out rest
    shift 3
    [ "$scheme" = https ] && port=443
    LAST="$scheme://$host$path"
    out="$(client sh -c 'rm -f /tmp/body /tmp/headers; curl -sk -o /tmp/body -D /tmp/headers -w "%{http_code}" --max-time 30 "$@"; echo; cat /tmp/headers; echo "@@BODY@@"; cat /tmp/body 2>/dev/null' \
        sh --resolve "$host:$port:$NODE_IP" "$@" "$scheme://$host$path")"
    CODE="${out%%$'\n'*}"
    rest="${out#*$'\n'}"
    HEADERS="${rest%%@@BODY@@*}"
    BODY="${rest#*@@BODY@@}"
    BODY="${BODY#$'\n'}"
}

header() {
    printf '%s\n' "$HEADERS" | grep -i "^$1:" | head -n 1 | cut -d: -f2- | tr -d '\r' | sed 's/^ //'
}

json() {
    jq -r "$1" <<<"$BODY" 2>/dev/null
}

expect_code() {
    [ "$CODE" = "$1" ] || fail "$LAST: expected HTTP $1, got $CODE ${BODY:0:200}"
}

expect_json() {
    local got
    got="$(json "$1")"
    [ "$got" = "$2" ] || fail "$LAST: expected $1 = '$2', got '$got'"
}

expect_header() {
    local got
    got="$(header "$1")"
    [ "$got" = "$2" ] || fail "$LAST: expected header $1: '$2', got '$got'"
}

# Polls until a request answers with the given code: routes take a moment to
# reach Traefik after an apply.
wait_for() {
    local want="$1"
    shift
    for _ in $(seq 1 60); do
        call "$@"
        [ "$CODE" = "$want" ] && return 0
        sleep 2
    done
    fail "$LAST never answered $want (last $CODE)"
}

auth_log() {
    call https "demos.$DOMAIN" "/demos/__auth_log$1"
    printf '%s' "$BODY"
}
