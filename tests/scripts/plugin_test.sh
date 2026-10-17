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

run_plugin() {
    (cd "$WORK_DIR" && PATH="$STUB_BIN:$PATH" bash "$PANEL/plugin.sh" "$PLUGIN" --dry-run -y "$@") \
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

test_a_host_under_the_panel_is_not_warned() {
    make_panel cs-panel.example.com
    make_plugin
    run_plugin
    assert_eq "$(plugin_env HELLO_DOMAIN)" "HELLO_DOMAIN=hello.cs-panel.example.com"
    assert_not_contains "$(cat "$WORK_DIR/plugin-output")" "outside the session cookie's domain"
}

run_tests
