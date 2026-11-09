#!/bin/bash

# shellcheck source=tests/scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

GUARD="$TEST_ROOT/tests/scripts/host_network_ports.py"
ALLOWED="$TEST_ROOT/tests/scripts/host_network_ports.txt"
OVERLAYS="vault-http vault-https local-secrets-http local-secrets-https"

# A copy of the checkout with its env files made from the examples, and every
# overlay update.sh can apply written with TURN, nvidia and the AI service on.
make_panel() {
    PANEL="$WORK_DIR/panel"
    mkdir -p "$PANEL"
    cp -R "$TEST_ROOT/base" "$TEST_ROOT/overlays" "$TEST_ROOT/utils" "$PANEL/"
    find "$PANEL/overlays" -name '*.env.example' | while read -r example; do
        cp "$example" "${example%.example}"
    done
}

write() {
    (
        # shellcheck disable=SC2030 # only write_overlays reads it
        export PANEL_DIR="$PANEL" TURN_DOMAIN=turn.example.gg GPU_VENDOR=nvidia AI_ENABLED=true
        # shellcheck source=utils/write_overlays.sh
        source "$PANEL/utils/write_overlays.sh"
        write_overlays
    ) >"$WORK_DIR/write-output" 2>&1 || fail "write_overlays failed: $(cat "$WORK_DIR/write-output")"
}

# render OVERLAY: $WORK_DIR/OVERLAY.json, as kubectl prints the overlay.
render() {
    kubectl kustomize "$PANEL/overlays/$1" >"$WORK_DIR/$1.yaml" || fail "kubectl kustomize $1 failed"
    KUBECONFIG=/dev/null kubectl patch --local -o json --type merge -p '{}' -f "$WORK_DIR/$1.yaml" >"$WORK_DIR/$1.json" ||
        fail "could not read $1 as JSON"
}

# guard JSON [ALLOWLIST]: the guard's verdict, its output in $WORK_DIR/guard.
guard() {
    python3 -I "$GUARD" "${2:-$ALLOWED}" "$1" >"$WORK_DIR/guard" 2>&1
}

# workload KIND NAME POD_SPEC: one workload, as kubectl prints it.
workload() {
    printf '{"apiVersion": "apps/v1", "kind": "%s", "metadata": {"name": "%s"}, "spec": {"template": {"spec": %s}}}\n' "$1" "$2" "$3"
}

# mediamtx CONFIG ENV [ENV_FROM]: a hostNetwork MediaMTX with no declared
# ports, mounting CONFIG (mediamtx.yml) and with the container env in ENV.
mediamtx() {
    python3 -I - "$1" "$2" "${3:-[]}" <<'PY'
import json, sys
config, env, env_from = sys.argv[1], json.loads(sys.argv[2]), json.loads(sys.argv[3])
print(json.dumps({"apiVersion": "v1", "kind": "ConfigMap", "metadata": {"name": "mediamtx-config"},
                  "data": {"mediamtx.yml": config}}))
print(json.dumps({"apiVersion": "apps/v1", "kind": "Deployment", "metadata": {"name": "mediamtx"},
                  "spec": {"template": {"spec": {"hostNetwork": True,
                  "containers": [{"name": "mediamtx", "env": env, "envFrom": env_from}],
                  "volumes": [{"name": "config", "configMap": {"name": "mediamtx-config"}}]}}}}))
PY
}

# A secretKeyRef env entry for MTX_AUTHINTERNALUSERS_$1_PASS, optional when $2 is true.
password_env() {
    printf '{"name": "MTX_AUTHINTERNALUSERS_%s_PASS", "valueFrom": {"secretKeyRef": {"name": "mediamtx-secrets", "key": "K", "optional": %s}}}' "$1" "${2:-false}"
}

API_USER='authInternalUsers:
  - user: api
    pass:
    ips: [10.0.0.0/8]
    permissions:
      - action: api
'

with_open_mediamtx() {
    python3 -I - "$PANEL/overlays/mediamtx/mediamtx.yml" <<'PY'
import re, sys
path = sys.argv[1]
text = open(path).read()
text, n = re.subn(r"(?ms)^authInternalUsers:\n.*?(?=^\S)", "authInternalUsers:\n  - user: any\n    pass:\n    ips: []\n"
                  "    permissions:\n      - action: publish\n      - action: read\n      - action: api\n\n", text)
assert n == 1
open(path, "w").write(text)
PY
}

test_every_overlay_listens_on_the_host_only_where_it_should() {
    make_panel
    write
    for o in $OVERLAYS; do
        render "$o"
        guard "$WORK_DIR/$o.json" || fail "$o: $(cat "$WORK_DIR/guard")"
        for object in Deployment/mediamtx Deployment/coturn DaemonSet/game-server-node-connector \
            DaemonSet/game-server-node-connector-nvidia DaemonSet/game-server-node-connector-nvidia-fallback; do
            assert_contains "$(jq -r '"\(.kind)/\(.metadata.name)"' "$WORK_DIR/$o.json")" "$object"
        done
    done
}

test_a_mediamtx_open_to_any_address_fails() {
    make_panel
    with_open_mediamtx
    write
    render local-secrets-https
    guard "$WORK_DIR/local-secrets-https.json" && fail "the guard passed: $(cat "$WORK_DIR/guard")"
    for port in 8888/TCP 8889/TCP 8890/UDP 9997/TCP 9998/TCP; do
        assert_contains "$(cat "$WORK_DIR/guard")" "Deployment/mediamtx listens on $port on the host's network"
    done
    assert_contains "$(cat "$WORK_DIR/guard")" "Deployment/mediamtx: authInternalUsers grants any api and publish with no password"
    assert_not_contains "$(cat "$WORK_DIR/guard")" "8189/UDP"
}

test_a_host_network_workload_nobody_listed_fails() {
    workload DaemonSet probe '{"hostNetwork": true, "containers": [{"name": "p", "ports": [{"containerPort": 9100}]}]}' >"$WORK_DIR/probe.json"
    guard "$WORK_DIR/probe.json" && fail "the guard passed: $(cat "$WORK_DIR/guard")"
    assert_contains "$(cat "$WORK_DIR/guard")" "DaemonSet/probe runs on the host network but host_network_ports.txt doesn't list it"
    assert_contains "$(cat "$WORK_DIR/guard")" "DaemonSet/probe listens on 9100/TCP on the host's network, which isn't an intended public port and nothing limits who reaches it"
}

test_a_host_port_off_the_host_network_is_checked_too() {
    workload Deployment probe '{"containers": [{"name": "p", "ports": [{"containerPort": 80, "hostPort": 8080}]}]}' >"$WORK_DIR/probe.json"
    guard "$WORK_DIR/probe.json" && fail "the guard passed: $(cat "$WORK_DIR/guard")"
    assert_contains "$(cat "$WORK_DIR/guard")" "Deployment/probe listens on 8080/TCP"
    workload Deployment probe '{"containers": [{"name": "p", "ports": [{"containerPort": 80}]}]}' >"$WORK_DIR/probe.json"
    guard "$WORK_DIR/probe.json" || fail "a port off the host network failed: $(cat "$WORK_DIR/guard")"
}

test_a_listed_port_passes_only_for_its_workload_and_protocol() {
    workload Deployment coturn '{"hostNetwork": true, "containers": [{"name": "c", "ports": [{"containerPort": 3478, "protocol": "UDP"}, {"containerPort": 50100, "protocol": "UDP"}]}]}' >"$WORK_DIR/coturn.json"
    guard "$WORK_DIR/coturn.json" || fail "coturn's own ports failed: $(cat "$WORK_DIR/guard")"
    workload Deployment coturn '{"hostNetwork": true, "containers": [{"name": "c", "ports": [{"containerPort": 8189, "protocol": "UDP"}, {"containerPort": 50100, "protocol": "TCP"}]}]}' >"$WORK_DIR/coturn.json"
    guard "$WORK_DIR/coturn.json" && fail "the guard passed: $(cat "$WORK_DIR/guard")"
    assert_contains "$(cat "$WORK_DIR/guard")" "Deployment/coturn listens on 8189/UDP"
    assert_contains "$(cat "$WORK_DIR/guard")" "Deployment/coturn listens on 50100/TCP"
}

test_a_private_host_ip_counts_only_off_the_host_network() {
    printf 'DaemonSet/probe 1/TCP internal test\n' >"$WORK_DIR/allowed.txt"
    workload DaemonSet probe '{"hostNetwork": true, "containers": [{"name": "p", "ports": [{"containerPort": 9100, "hostIP": "10.0.0.5"}]}]}' >"$WORK_DIR/probe.json"
    guard "$WORK_DIR/probe.json" "$WORK_DIR/allowed.txt" && fail "a hostNetwork port with a private hostIP passed: $(cat "$WORK_DIR/guard")"
    assert_contains "$(cat "$WORK_DIR/guard")" "DaemonSet/probe listens on 9100/TCP"
    workload Deployment probe '{"containers": [{"name": "p", "ports": [{"containerPort": 80, "hostPort": 9100, "hostIP": "10.0.0.5"}]}]}' >"$WORK_DIR/probe.json"
    guard "$WORK_DIR/probe.json" "$WORK_DIR/allowed.txt" || fail "a hostPort on 10.0.0.5 failed: $(cat "$WORK_DIR/guard")"
    workload Deployment probe '{"containers": [{"name": "p", "ports": [{"containerPort": 80, "hostPort": 9100, "hostIP": "203.0.113.5"}]}]}' >"$WORK_DIR/probe.json"
    guard "$WORK_DIR/probe.json" "$WORK_DIR/allowed.txt" && fail "a hostPort on 203.0.113.5 passed: $(cat "$WORK_DIR/guard")"
    assert_contains "$(cat "$WORK_DIR/guard")" "Deployment/probe listens on 9100/TCP"
}

test_mediamtx_is_checked_even_with_no_ports_declared() {
    mediamtx "$API_USER" "[$(password_env 0)]" >"$WORK_DIR/m.json"
    guard "$WORK_DIR/m.json" || fail "a locked-down MediaMTX failed: $(cat "$WORK_DIR/guard")"
    mediamtx "$API_USER" '[]' >"$WORK_DIR/m.json"
    guard "$WORK_DIR/m.json" && fail "the guard passed: $(cat "$WORK_DIR/guard")"
    assert_contains "$(cat "$WORK_DIR/guard")" "Deployment/mediamtx: authInternalUsers grants api api with no password"
}

test_a_mediamtx_password_must_come_from_a_required_secret() {
    mediamtx "$API_USER" '[{"name": "MTX_AUTHINTERNALUSERS_0_PASS", "value": ""}]' >"$WORK_DIR/m.json"
    guard "$WORK_DIR/m.json" && fail "a literal password passed: $(cat "$WORK_DIR/guard")"
    assert_contains "$(cat "$WORK_DIR/guard")" "MTX_AUTHINTERNALUSERS_0_PASS is set in the environment"
    mediamtx "$API_USER" "[$(password_env 0 true)]" >"$WORK_DIR/m.json"
    guard "$WORK_DIR/m.json" && fail "an optional secret passed: $(cat "$WORK_DIR/guard")"
    assert_contains "$(cat "$WORK_DIR/guard")" "authInternalUsers grants api api with no password"
}

test_mediamtx_auth_overrides_and_methods_fail() {
    local env
    for env in '{"name": "MTX_AUTHMETHOD", "value": "http"}' '{"name": "MTX_AUTHINTERNALUSERS_0_IPS", "value": "0.0.0.0/0"}'; do
        mediamtx "$API_USER" "[$(password_env 0), $env]" >"$WORK_DIR/m.json"
        guard "$WORK_DIR/m.json" && fail "the guard passed: $(cat "$WORK_DIR/guard")"
        assert_contains "$(cat "$WORK_DIR/guard")" "is set in the environment, which could widen who it lets in"
    done
    mediamtx "$API_USER" "[$(password_env 0)]" '[{"secretRef": {"name": "extra"}}]' >"$WORK_DIR/m.json"
    guard "$WORK_DIR/m.json" && fail "the guard passed: $(cat "$WORK_DIR/guard")"
    assert_contains "$(cat "$WORK_DIR/guard")" "its environment comes from Secret extra"
    mediamtx "authMethod: http
$API_USER" "[$(password_env 0)]" >"$WORK_DIR/m.json"
    guard "$WORK_DIR/m.json" && fail "the guard passed: $(cat "$WORK_DIR/guard")"
    assert_contains "$(cat "$WORK_DIR/guard")" "authMethod is http, not internal"
}

test_a_passwordless_user_on_private_addresses_still_may_not_publish() {
    mediamtx 'authInternalUsers:
  - user: any
    pass:
    ips: [10.0.0.0/8]
    permissions:
      - action: publish
      - action: read
' '[]' >"$WORK_DIR/m.json"
    guard "$WORK_DIR/m.json" && fail "the guard passed: $(cat "$WORK_DIR/guard")"
    assert_contains "$(cat "$WORK_DIR/guard")" "authInternalUsers grants any publish with no password"
}

# traefik HTTP_PORT HTTPS_PORT [HELM FLAGS...]: the gateway chart rendered
# with install_traefik's values, in $WORK_DIR/traefik.json.
traefik() {
    (
        # shellcheck source=utils/install_traefik.sh
        source "$TEST_ROOT/utils/install_traefik.sh"
        gateway_chart_values "$1" "$2"
    ) >"$WORK_DIR/traefik-values.yaml" || fail "gateway_chart_values failed"
    shift 2
    helm template gateway "$TEST_ROOT/charts/gateway" -n traefik -f "$WORK_DIR/traefik-values.yaml" "$@" \
        >"$WORK_DIR/traefik.yaml" || fail "helm template failed"
    KUBECONFIG=/dev/null kubectl patch --local -o json --type merge -p '{}' -f "$WORK_DIR/traefik.yaml" >"$WORK_DIR/traefik.json" ||
        fail "could not read the gateway chart as JSON"
}

test_traefik_binds_only_the_panels_http_and_https_ports() {
    local http https
    http="$(sed -n 's/^HTTP_PORT=//p' "$TEST_ROOT/overlays/config/traefik-config.env.example")"
    https="$(sed -n 's/^HTTPS_PORT=//p' "$TEST_ROOT/overlays/config/traefik-config.env.example")"
    traefik "$http" "$https"
    guard "$WORK_DIR/traefik.json" || fail "$(cat "$WORK_DIR/guard")"
    assert_eq "$(jq -r 'select(.kind == "Deployment") | .spec.template.spec.containers[].ports[] | select(.hostPort) | "\(.hostPort)/\(.protocol)"' "$WORK_DIR/traefik.json" | sort | xargs)" \
        "443/TCP 80/TCP"
    traefik "$http" "$https" --set traefik.ports.metrics.hostPort=9100
    guard "$WORK_DIR/traefik.json" && fail "the guard passed: $(cat "$WORK_DIR/guard")"
    assert_contains "$(cat "$WORK_DIR/guard")" "Deployment/traefik listens on 9100/TCP"
}

test_the_node_connector_is_listed_as_cluster_only() {
    assert_eq "$(grep -cE '^DaemonSet/game-server-node-connector(-nvidia|-nvidia-fallback)? +8585/TCP +internal ' "$ALLOWED")" 3
    assert_eq "$(grep -E ' 8585/' "$ALLOWED" | grep -cv ' internal ')" 0
}

run_tests
