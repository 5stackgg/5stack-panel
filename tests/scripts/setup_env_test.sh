#!/bin/bash

# shellcheck source=tests/scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

make_panel() {
    PANEL="$WORK_DIR/panel"
    mkdir -p "$PANEL"
    cp -R "$TEST_ROOT/utils" "$PANEL/utils"
    local dir
    for dir in overlays/local-secrets overlays/config overlays/mediamtx overlays/coturn; do
        mkdir -p "$PANEL/$dir"
        cp "$TEST_ROOT/$dir"/*.env.example "$PANEL/$dir/"
    done
    printf '#!/bin/sh\n' >"$PANEL/kustomize"
    chmod +x "$PANEL/kustomize"
    printf 'REVERSE_PROXY=false\nCLOUDFLARE=false\nVAULT_MANAGER=false\nKUBECONFIG=/dev/null\n' >"$PANEL/.5stack-env.config"
    set_env overlays/local-secrets/steam-secrets.env STEAM_WEB_API_KEY test
}

set_env() {
    local file="$PANEL/$1"
    if [ ! -f "$file" ]; then
        cp "$file.example" "$file"
    fi
    grep -v "^$2=" "$file" >"$file.tmp" || true
    mv "$file.tmp" "$file"
    printf '%s=%s\n' "$2" "$3" >>"$file"
}

set_sibling_domains() {
    set_env overlays/config/api-config.env WEB_DOMAIN cs-panel.example.com
    set_env overlays/config/api-config.env API_DOMAIN api-cs-panel.example.com
    set_env overlays/config/api-config.env WS_DOMAIN ws-cs-panel.example.com
    set_env overlays/config/api-config.env RELAY_DOMAIN tv-cs-panel.example.com
    set_env overlays/config/api-config.env DEMOS_DOMAIN demos-cs-panel.example.com
    set_env overlays/config/api-config.env GAME_STREAM_DOMAIN hls-cs-panel.example.com
    set_env overlays/config/api-config.env MAIL_FROM hello@cs-panel.example.com
    set_env overlays/config/s3-config.env S3_CONSOLE_HOST console-cs-panel.example.com
    set_env overlays/config/typesense-config.env TYPESENSE_HOST search-cs-panel.example.com
}

run_setup_env() {
    bash -c 'source "$1/utils/utils.sh"' _ "$PANEL" </dev/null >"$WORK_DIR/setup-output" 2>&1 &
    local pid=$! ticks=0 status
    while kill -0 "$pid" 2>/dev/null; do
        if [ "$ticks" -ge 600 ]; then
            kill "$pid"
            fail "setup-env.sh did not finish; is it waiting on a prompt? $(tail -n 5 "$WORK_DIR/setup-output")"
        fi
        sleep 0.1
        ticks=$((ticks + 1))
    done
    wait "$pid"
    status=$?
    if [ "$status" -ne 0 ]; then
        fail "setup-env.sh exited $status: $(tail -n 20 "$WORK_DIR/setup-output")"
    fi
}

env_lines() {
    grep "^$2=" "$PANEL/$1" || true
}

test_an_update_leaves_empty_push_keys_for_the_api_to_generate() {
    make_panel
    set_env overlays/config/api-config.env WEB_DOMAIN example.com
    set_env overlays/local-secrets/push-secrets.env WEB_PUSH_PUBLIC_KEY ""
    set_env overlays/local-secrets/push-secrets.env WEB_PUSH_PRIVATE_KEY ""
    run_setup_env
    assert_eq "$(env_lines overlays/local-secrets/push-secrets.env WEB_PUSH_PUBLIC_KEY)" "WEB_PUSH_PUBLIC_KEY="
    assert_eq "$(env_lines overlays/local-secrets/push-secrets.env WEB_PUSH_PRIVATE_KEY)" "WEB_PUSH_PRIVATE_KEY="
}

test_hosts_beside_the_web_domain_share_its_parent_as_the_cookie_domain() {
    make_panel
    set_sibling_domains
    run_setup_env
    assert_eq "$(env_lines overlays/config/api-config.env AUTH_COOKIE_DOMAIN)" "AUTH_COOKIE_DOMAIN=.example.com"
}

test_hosts_under_the_web_domain_leave_the_cookie_domain_alone() {
    make_panel
    set_env overlays/config/api-config.env WEB_DOMAIN panel.example.com
    run_setup_env
    assert_eq "$(env_lines overlays/config/api-config.env API_DOMAIN)" "API_DOMAIN=api.panel.example.com"
    assert_eq "$(env_lines overlays/config/api-config.env AUTH_COOKIE_DOMAIN)" ""
}

test_an_operator_cookie_domain_that_covers_the_hosts_is_kept() {
    make_panel
    set_env overlays/config/api-config.env WEB_DOMAIN panel.example.com
    set_env overlays/config/api-config.env AUTH_COOKIE_DOMAIN .example.com
    run_setup_env
    assert_eq "$(env_lines overlays/config/api-config.env AUTH_COOKIE_DOMAIN)" "AUTH_COOKIE_DOMAIN=.example.com"
}

test_a_cookie_domain_on_a_crlf_line_is_kept() {
    make_panel
    set_env overlays/config/api-config.env WEB_DOMAIN panel.example.com
    printf 'AUTH_COOKIE_DOMAIN=.example.com\r\n' >>"$PANEL/overlays/config/api-config.env"
    run_setup_env
    assert_eq "$(env_lines overlays/config/api-config.env AUTH_COOKIE_DOMAIN)" $'AUTH_COOKIE_DOMAIN=.example.com\r'
}

test_a_cookie_domain_left_from_old_hosts_is_replaced() {
    make_panel
    set_sibling_domains
    set_env overlays/config/api-config.env AUTH_COOKIE_DOMAIN .ccentral.xyz
    run_setup_env
    assert_eq "$(env_lines overlays/config/api-config.env AUTH_COOKIE_DOMAIN)" "AUTH_COOKIE_DOMAIN=.example.com"
    assert_contains "$(cat "$WORK_DIR/setup-output")" "(was .ccentral.xyz)"
}

test_only_a_stream_host_beside_the_web_domain_is_warned_about() {
    make_panel
    set_env overlays/config/api-config.env WEB_DOMAIN panel.example.com
    set_env overlays/config/api-config.env GAME_STREAM_DOMAIN hls-panel.example.com
    run_setup_env
    assert_eq "$(env_lines overlays/config/api-config.env AUTH_COOKIE_DOMAIN)" ""
    assert_contains "$(cat "$WORK_DIR/setup-output")" "hls-panel.example.com is not under .panel.example.com"
}

test_hosts_on_another_domain_are_warned_about_instead() {
    make_panel
    set_env overlays/config/api-config.env WEB_DOMAIN panel.example.com
    set_env overlays/config/api-config.env API_DOMAIN api.example.net
    run_setup_env
    assert_eq "$(env_lines overlays/config/api-config.env AUTH_COOKIE_DOMAIN)" ""
    assert_contains "$(cat "$WORK_DIR/setup-output")" "api.example.net shares no parent domain with panel.example.com"
}

test_domain_case_and_trailing_dots_are_ignored() {
    make_panel
    set_env overlays/config/api-config.env WEB_DOMAIN Panel.Example.com.
    set_env overlays/config/api-config.env API_DOMAIN api.panel.example.com
    set_env overlays/config/api-config.env WS_DOMAIN WS.Panel.Example.com
    run_setup_env
    assert_eq "$(env_lines overlays/config/api-config.env AUTH_COOKIE_DOMAIN)" ""
    assert_not_contains "$(cat "$WORK_DIR/setup-output")" "is not under"
}

test_a_config_without_a_final_newline_keeps_its_last_line() {
    make_panel
    set_sibling_domains
    config="$PANEL/overlays/config/api-config.env"
    printf '%s' "$(cat "$config")" >"$config.tmp"
    mv "$config.tmp" "$config"
    run_setup_env
    assert_eq "$(env_lines overlays/config/api-config.env MAIL_FROM)" "MAIL_FROM=hello@cs-panel.example.com"
    assert_eq "$(env_lines overlays/config/api-config.env AUTH_COOKIE_DOMAIN)" "AUTH_COOKIE_DOMAIN=.example.com"
}

run_tests
