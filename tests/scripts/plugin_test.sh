#!/bin/bash

# shellcheck source=tests/scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

STUB_BIN="$(cd "$(dirname "${BASH_SOURCE[0]}")/stub" && pwd)"

make_panel() {
    PANEL="$WORK_DIR/panel"
    mkdir -p "$PANEL/overlays/config"
    cp "$TEST_ROOT/plugin.sh" "$PANEL/plugin.sh"
    cp -R "$TEST_ROOT/utils" "$PANEL/utils"
    printf '#!/bin/sh\necho "kustomize $*"\n' >"$PANEL/kustomize"
    chmod +x "$PANEL/kustomize"
    printf 'REVERSE_PROXY=true\nVAULT_MANAGER=false\nKUBECONFIG=/dev/null\n' >"$PANEL/.5stack-env.config"
    printf 'WEB_DOMAIN=%s\n' "$1" >"$PANEL/overlays/config/api-config.env"
    if [ -n "${2:-}" ]; then
        printf 'AUTH_COOKIE_DOMAIN=%s\n' "$2" >>"$PANEL/overlays/config/api-config.env"
    fi
}

make_plugin() {
    PLUGIN="$WORK_DIR/hello-plugin"
    mkdir -p "$PLUGIN/public" "$PLUGIN/k8s/base" "$PLUGIN/k8s/overlays/http"
    local panel=""
    if [ "${1:-}" = "asks-for-panel" ]; then
        panel=', "panel": { "file": "k8s/base/panel.env" }'
    fi
    cat >"$PLUGIN/public/5stack-plugin.json" <<EOF
{
  "name": "Hello",
  "slug": "hello",
  "install": {
    "overlays": { "http": "k8s/overlays/http" },
    "domain": { "prefix": "hello", "var": "HELLO_DOMAIN", "file": "k8s/base/hello.env" }$panel
  }
}
EOF
    printf 'HELLO_DOMAIN=hello.example.org\n' >"$PLUGIN/k8s/base/hello.env.example"
}

# A plugin that also ships Gateway API routes, beside its Ingress install.
# $1: which Gateway API overlays it ships (default http); $2: "with-https" for
# a certificate Ingress install as well. The gateway overlays render the hello
# route, or a $WORK_DIR/gateway-kind of choice; the Ingress ones the hello
# Ingress, the way kustomize would.
make_gateway_plugin() {
    local gateway="${1:-http}" legacy='"http": "k8s/overlays/http"' overlays=""
    make_plugin
    [ "${2:-}" = with-https ] && legacy="$legacy, \"https\": \"k8s/overlays/https\""
    case "$gateway" in
        http) overlays='"http": "k8s/gateway/http"' ;;
        https) overlays='"https": "k8s/gateway/https"' ;;
        both) overlays='"http": "k8s/gateway/http", "https": "k8s/gateway/https"' ;;
    esac
    mkdir -p "$PLUGIN/k8s/gateway/http" "$PLUGIN/k8s/gateway/https" "$PLUGIN/k8s/overlays/https"
    sed -i.bak "s#\"overlays\": { \"http\": \"k8s/overlays/http\" },#\"overlays\": { $legacy },\\n    \"gateway\": { \"overlays\": { $overlays } },#" "$PLUGIN/public/5stack-plugin.json"
    rm -f "$PLUGIN/public/5stack-plugin.json.bak"
    cat >"$PANEL/kustomize" <<'STUB'
#!/bin/sh
kind="$(cat "$WORK_DIR/gateway-kind" 2>/dev/null || echo HTTPRoute)"
case "$2" in
    */k8s/gateway/*) printf 'apiVersion: gateway.networking.k8s.io/v1\nkind: %s\nmetadata:\n  name: hello\n  namespace: 5stack\n' "$kind" ;;
    */k8s/overlays/*) printf 'apiVersion: networking.k8s.io/v1\nkind: Ingress\nmetadata:\n  name: hello\n  namespace: 5stack\n---\napiVersion: v1\nkind: Service\nmetadata:\n  name: hello\n  namespace: 5stack\n' ;;
esac
STUB
    chmod +x "$PANEL/kustomize"
}

# Without --dry-run: applies, then retires what it replaces.
run_plugin_for_real() {
    (cd "$WORK_DIR" && PATH="$STUB_BIN:$PATH" ROUTE_WAIT_TIMEOUT=0 bash "$PANEL/plugin.sh" "$PLUGIN" -y "$@") \
        >"$WORK_DIR/plugin-output" 2>&1 \
        || fail "plugin.sh exited $?: $(tail -n 20 "$WORK_DIR/plugin-output")"
}

ingress_deletes() {
    grep ' delete ingress ' "$WORK_DIR/calls" 2>/dev/null || true
}

run_plugin() {
    (cd "$WORK_DIR" && PATH="$STUB_BIN:$PATH" bash "$PANEL/plugin.sh" "$PLUGIN" --dry-run -y "$@") \
        >"$WORK_DIR/plugin-output" 2>&1 \
        || fail "plugin.sh exited $?: $(tail -n 20 "$WORK_DIR/plugin-output")"
}

# Enter at every question, as a person at a terminal would.
run_plugin_interactively() {
    printf '\n\n\n\n' >"$WORK_DIR/tty"
    (cd "$WORK_DIR" && PATH="$STUB_BIN:$PATH" PLUGIN_TTY="$WORK_DIR/tty" bash "$PANEL/plugin.sh" "$PLUGIN" --dry-run) \
        >"$WORK_DIR/plugin-output" 2>&1 \
        || fail "plugin.sh exited $?: $(tail -n 20 "$WORK_DIR/plugin-output")"
}

plugin_env() {
    grep "^$1=" "$PANEL/custom/hello/k8s/base/${2:-hello}.env" 2>/dev/null || true
}

test_a_plugin_that_asks_is_given_the_panels_domains() {
    make_panel cs-panel.example.com .example.com
    make_plugin asks-for-panel
    run_plugin --domain hello-cs-panel.example.com
    assert_eq "$(plugin_env WEB_DOMAIN panel)" "WEB_DOMAIN=cs-panel.example.com"
    assert_eq "$(plugin_env AUTH_COOKIE_DOMAIN panel)" "AUTH_COOKIE_DOMAIN=.example.com"
    assert_eq "$(plugin_env WEB_DOMAIN)" ""
}

test_a_rerun_follows_a_cookie_domain_the_panel_widened() {
    make_panel cs-panel.example.com
    make_plugin asks-for-panel
    run_plugin
    assert_eq "$(plugin_env AUTH_COOKIE_DOMAIN panel)" "AUTH_COOKIE_DOMAIN="
    printf 'AUTH_COOKIE_DOMAIN=.example.com\n' >>"$PANEL/overlays/config/api-config.env"
    run_plugin
    assert_eq "$(plugin_env AUTH_COOKIE_DOMAIN panel)" "AUTH_COOKIE_DOMAIN=.example.com"
}

test_a_plugin_that_does_not_ask_is_given_nothing() {
    make_panel cs-panel.example.com .example.com
    make_plugin
    run_plugin
    assert_eq "$(plugin_env WEB_DOMAIN panel)" ""
    assert_eq "$(plugin_env AUTH_COOKIE_DOMAIN panel)" ""
}

test_a_host_beside_the_panel_outside_the_cookie_domain_is_warned() {
    make_panel cs-panel.example.com
    make_plugin
    run_plugin --domain hello-cs-panel.example.com
    assert_contains "$(cat "$WORK_DIR/plugin-output")" "outside the session cookie's domain"
}

test_a_host_beside_the_panel_inside_a_wider_cookie_domain_is_not_warned() {
    make_panel cs-panel.example.com .example.com
    make_plugin
    run_plugin --domain hello-cs-panel.example.com
    assert_not_contains "$(cat "$WORK_DIR/plugin-output")" "outside the session cookie's domain"
}

test_a_rerun_keeps_a_host_inside_the_cookie_domain() {
    make_panel cs.example.com .example.com
    make_plugin
    run_plugin --domain skins.example.com
    run_plugin
    assert_eq "$(plugin_env HELLO_DOMAIN)" "HELLO_DOMAIN=skins.example.com"
}

# A sibling host the cookie never reaches was offered straight back, because
# `inventory-cs-panel.example.com` ends in the text `cs-panel.example.com`.
test_an_interactive_rerun_offers_a_host_the_cookie_reaches() {
    make_panel cs-panel.example.com
    make_plugin
    run_plugin --domain hello-cs-panel.example.com
    run_plugin_interactively
    assert_eq "$(plugin_env HELLO_DOMAIN)" "HELLO_DOMAIN=hello.cs-panel.example.com"
}

# Its DNS and the panel's registration point at it, so only a person moves it.
test_an_unattended_rerun_never_moves_a_host_an_install_chose() {
    make_panel cs-panel.example.com
    make_plugin
    run_plugin --domain hello-cs-panel.example.com
    run_plugin
    assert_eq "$(plugin_env HELLO_DOMAIN)" "HELLO_DOMAIN=hello-cs-panel.example.com"
    assert_contains "$(cat "$WORK_DIR/plugin-output")" "outside the session cookie's domain"
}

test_a_first_install_does_not_keep_the_example_host() {
    make_panel cs-panel.example.com
    make_plugin
    cp "$PLUGIN/k8s/base/hello.env.example" "$PLUGIN/k8s/base/hello.env"
    run_plugin
    assert_eq "$(plugin_env HELLO_DOMAIN)" "HELLO_DOMAIN=hello.cs-panel.example.com"
}

# cron, Ansible, ssh without -t: /dev/tty passes -r there but cannot be opened.
test_a_run_without_a_terminal_counts_as_unattended() {
    make_panel cs-panel.example.com
    make_plugin
    run_plugin --domain hello-cs-panel.example.com
    # A socket passes -r and cannot be opened, as /dev/tty does with no terminal.
    python3 -c 'import socket, sys; socket.socket(socket.AF_UNIX).bind(sys.argv[1])' "$WORK_DIR/no-tty"
    (cd "$WORK_DIR" && PATH="$STUB_BIN:$PATH" PLUGIN_TTY="$WORK_DIR/no-tty" bash "$PANEL/plugin.sh" "$PLUGIN" --dry-run) \
        >"$WORK_DIR/plugin-output" 2>&1 || fail "plugin.sh exited $?: $(tail -n 20 "$WORK_DIR/plugin-output")"
    assert_eq "$(plugin_env HELLO_DOMAIN)" "HELLO_DOMAIN=hello-cs-panel.example.com"
}

test_an_interactive_rerun_says_why_it_offers_another_host() {
    make_panel cs-panel.example.com
    make_plugin
    run_plugin --domain hello-cs-panel.example.com
    run_plugin_interactively
    assert_contains "$(cat "$WORK_DIR/plugin-output")" "hello-cs-panel.example.com, the current host, is outside"
}

# A fresh panel has the switch off, and the Add button only appears once it is on.
test_the_finish_says_to_turn_panel_plugins_on() {
    make_panel cs-panel.example.com
    make_plugin
    (cd "$WORK_DIR" && PATH="$STUB_BIN:$PATH" bash "$PANEL/plugin.sh" "$PLUGIN" -y) \
        >"$WORK_DIR/plugin-output" 2>&1 || fail "plugin.sh exited $?: $(tail -n 20 "$WORK_DIR/plugin-output")"
    assert_contains "$(cat "$WORK_DIR/plugin-output")" "Turn on the Panel Plugins switch"
}

test_a_host_under_the_panel_is_not_warned() {
    make_panel cs-panel.example.com
    make_plugin
    run_plugin
    assert_eq "$(plugin_env HELLO_DOMAIN)" "HELLO_DOMAIN=hello.cs-panel.example.com"
    assert_not_contains "$(cat "$WORK_DIR/plugin-output")" "outside the session cookie's domain"
}


test_a_panel_on_traefik_installs_the_plugins_gateway_routes() {
    make_panel panel.example.com
    make_gateway_plugin
    touch "$WORK_DIR/shared-gateway"
    run_plugin --domain hello.example.com
    assert_contains "$(cat "$WORK_DIR/plugin-output")" "custom/hello/k8s/gateway/http"
    assert_not_contains "$(cat "$WORK_DIR/plugin-output")" "custom/hello/k8s/overlays/http"
}

test_a_panel_still_on_ingress_nginx_installs_the_plugins_ingress() {
    make_panel panel.example.com
    make_gateway_plugin
    run_plugin --domain hello.example.com
    assert_contains "$(cat "$WORK_DIR/plugin-output")" "custom/hello/k8s/overlays/http"
    assert_not_contains "$(cat "$WORK_DIR/plugin-output")" "custom/hello/k8s/gateway/http"
}

test_a_plugin_without_gateway_routes_keeps_its_ingress_on_traefik() {
    make_panel panel.example.com
    make_plugin
    touch "$WORK_DIR/shared-gateway"
    run_plugin --domain hello.example.com
    assert_contains "$(cat "$WORK_DIR/plugin-output")" "custom/hello/k8s/overlays/http"
}

test_routes_that_serve_retire_the_ingress_install() {
    make_panel panel.example.com
    make_gateway_plugin
    touch "$WORK_DIR/shared-gateway" "$WORK_DIR/ingress-hello"
    echo "3 True/True/3 True/True/3 " >"$WORK_DIR/route-hello"
    run_plugin_for_real --domain hello.example.com
    assert_eq "$(ingress_deletes)" "-n 5stack delete ingress hello --ignore-not-found"
    assert_contains "$(cat "$WORK_DIR/plugin-output")" "retired Ingress hello"
}

test_routes_whose_backends_do_not_resolve_keep_the_ingresses() {
    make_panel panel.example.com
    make_gateway_plugin
    touch "$WORK_DIR/shared-gateway" "$WORK_DIR/ingress-hello"
    echo "3 True/False/3 True/False/3 " >"$WORK_DIR/route-hello"
    run_plugin_for_real --domain hello.example.com
    assert_eq "$(ingress_deletes)" ""
    assert_contains "$(cat "$WORK_DIR/plugin-output")" "Ingresses stay"
}

test_a_route_status_from_an_older_generation_keeps_the_ingresses() {
    make_panel panel.example.com
    make_gateway_plugin
    touch "$WORK_DIR/shared-gateway" "$WORK_DIR/ingress-hello"
    echo "4 True/True/3 True/True/3 " >"$WORK_DIR/route-hello"
    run_plugin_for_real --domain hello.example.com
    assert_eq "$(ingress_deletes)" ""
}


test_an_install_with_no_ingress_on_the_cluster_neither_waits_nor_retires() {
    make_panel panel.example.com
    make_gateway_plugin
    touch "$WORK_DIR/shared-gateway"
    run_plugin_for_real --domain hello.example.com
    assert_eq "$(ingress_deletes)" ""
    assert_not_contains "$(cat "$WORK_DIR/plugin-output")" "Ingresses stay"
    assert_not_contains "$(cat "$WORK_DIR/plugin-output")" "retired Ingress"
}

test_an_overlay_that_renders_no_httproute_keeps_the_ingresses() {
    make_panel panel.example.com
    make_gateway_plugin
    touch "$WORK_DIR/shared-gateway" "$WORK_DIR/ingress-hello"
    echo GRPCRoute >"$WORK_DIR/gateway-kind"
    run_plugin_for_real --domain hello.example.com
    assert_eq "$(ingress_deletes)" ""
    assert_contains "$(cat "$WORK_DIR/plugin-output")" "renders no HTTPRoute"
}

test_an_https_site_keeps_the_certificate_install_when_the_routes_are_http_only() {
    make_panel panel.example.com
    sed -i.bak 's/^REVERSE_PROXY=true/REVERSE_PROXY=false/' "$PANEL/.5stack-env.config"
    make_gateway_plugin http with-https
    touch "$WORK_DIR/shared-gateway"
    run_plugin --domain hello.example.com
    assert_contains "$(cat "$WORK_DIR/plugin-output")" "custom/hello/k8s/overlays/https"
    assert_not_contains "$(cat "$WORK_DIR/plugin-output")" "custom/hello/k8s/gateway/http"
}

test_a_proxied_site_keeps_the_http_install_when_the_routes_are_https_only() {
    make_panel panel.example.com
    make_gateway_plugin https
    touch "$WORK_DIR/shared-gateway"
    run_plugin --domain hello.example.com
    assert_contains "$(cat "$WORK_DIR/plugin-output")" "custom/hello/k8s/overlays/http"
    assert_not_contains "$(cat "$WORK_DIR/plugin-output")" "kustomize build $PANEL/custom/hello "
}

run_tests
