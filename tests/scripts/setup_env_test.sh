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

test_an_install_without_ai_enabled_generates_no_ai_secrets() {
    make_panel
    set_env overlays/config/api-config.env WEB_DOMAIN example.com
    mkdir -p "$PANEL/overlays/ai"
    cp "$TEST_ROOT/overlays/ai/ai-secrets.env.example" "$PANEL/overlays/ai/"
    run_setup_env
    [ ! -e "$PANEL/overlays/ai/ai-secrets.env" ] || fail "ai secrets were generated without AI_ENABLED"
}

test_ai_enabled_without_vault_is_warned_about_and_not_set_up() {
    make_panel
    set_env overlays/config/api-config.env WEB_DOMAIN example.com
    mkdir -p "$PANEL/overlays/ai"
    cp "$TEST_ROOT/overlays/ai/ai-secrets.env.example" "$PANEL/overlays/ai/"
    printf 'AI_ENABLED=true\n' >>"$PANEL/.5stack-env.config"
    run_setup_env
    assert_contains "$(cat "$WORK_DIR/setup-output")" "AI_ENABLED needs VAULT_MANAGER=true"
    [ ! -e "$PANEL/overlays/ai/ai-secrets.env" ] || fail "ai secrets were generated without Vault"
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
    export FLAT_HOSTS=false
    run_setup_env
    assert_eq "$(env_lines overlays/config/api-config.env API_DOMAIN)" "API_DOMAIN=api.panel.example.com"
    assert_eq "$(env_lines overlays/config/api-config.env AUTH_COOKIE_DOMAIN)" ""
}

test_a_subdomain_puts_every_address_one_level_deep_by_default() {
    make_panel
    set_env overlays/config/api-config.env WEB_DOMAIN panel.example.com
    run_setup_env
    assert_eq "$(env_lines overlays/config/api-config.env API_DOMAIN)" "API_DOMAIN=panel-api.example.com"
    assert_eq "$(env_lines overlays/config/typesense-config.env TYPESENSE_HOST)" "TYPESENSE_HOST=panel-search.example.com"
    assert_eq "$(env_lines overlays/config/api-config.env AUTH_COOKIE_DOMAIN)" "AUTH_COOKIE_DOMAIN=.example.com"
    assert_contains "$(cat "$WORK_DIR/setup-output")" "Sign-in then covers all of example.com, so other sites on example.com get the panel's sign-in cookie."
}

test_flat_hosts_put_every_address_one_level_deep_beside_the_panel() {
    make_panel
    set_env overlays/config/api-config.env WEB_DOMAIN panel.example.com
    export FLAT_HOSTS=true
    run_setup_env
    assert_eq "$(env_lines overlays/config/api-config.env API_DOMAIN)" "API_DOMAIN=panel-api.example.com"
    assert_eq "$(env_lines overlays/config/api-config.env WS_DOMAIN)" "WS_DOMAIN=panel-ws.example.com"
    assert_eq "$(env_lines overlays/config/api-config.env RELAY_DOMAIN)" "RELAY_DOMAIN=panel-tv.example.com"
    assert_eq "$(env_lines overlays/config/api-config.env DEMOS_DOMAIN)" "DEMOS_DOMAIN=panel-demos.example.com"
    assert_eq "$(env_lines overlays/config/api-config.env GAME_STREAM_DOMAIN)" "GAME_STREAM_DOMAIN=panel-hls.example.com"
    assert_eq "$(env_lines overlays/config/s3-config.env S3_CONSOLE_HOST)" "S3_CONSOLE_HOST=panel-console.example.com"
    assert_eq "$(env_lines overlays/config/typesense-config.env TYPESENSE_HOST)" "TYPESENSE_HOST=panel-search.example.com"
    assert_eq "$(env_lines overlays/config/api-config.env AUTH_COOKIE_DOMAIN)" "AUTH_COOKIE_DOMAIN=.example.com"
}

test_the_free_cloudflare_plan_puts_every_address_one_level_deep_and_says_so() {
    make_panel
    sed -i.bak 's/^CLOUDFLARE=false$/CLOUDFLARE=true/' "$PANEL/.5stack-env.config"
    set_env overlays/config/api-config.env WEB_DOMAIN panel.example.com
    export CLOUDFLARE_PLAN=free
    run_setup_env
    assert_eq "$(env_lines overlays/config/api-config.env API_DOMAIN)" "API_DOMAIN=panel-api.example.com"
    assert_eq "$(env_lines overlays/config/typesense-config.env TYPESENSE_HOST)" "TYPESENSE_HOST=panel-search.example.com"
    assert_contains "$(cat "$WORK_DIR/setup-output")" "Cloudflare's free plan only covers one level below example.com, so the addresses become panel-api.example.com, panel-ws.example.com, panel-tv.example.com, panel-demos.example.com, panel-hls.example.com, panel-console.example.com, panel-search.example.com."
    assert_contains "$(cat "$WORK_DIR/setup-output")" "Other sites on example.com will receive the panel's sign-in cookie."
}

test_a_paid_cloudflare_plan_keeps_the_default_without_the_free_plan_alert() {
    make_panel
    sed -i.bak 's/^CLOUDFLARE=false$/CLOUDFLARE=true/' "$PANEL/.5stack-env.config"
    set_env overlays/config/api-config.env WEB_DOMAIN panel.example.com
    export CLOUDFLARE_PLAN=paid
    run_setup_env
    assert_eq "$(env_lines overlays/config/api-config.env API_DOMAIN)" "API_DOMAIN=panel-api.example.com"
    assert_not_contains "$(cat "$WORK_DIR/setup-output")" "Cloudflare's free plan"
    assert_contains "$(cat "$WORK_DIR/setup-output")" "Sign-in then covers all of example.com"
}

test_a_root_domain_keeps_its_addresses_under_it() {
    make_panel
    set_env overlays/config/api-config.env WEB_DOMAIN example.com
    export FLAT_HOSTS=true
    run_setup_env
    assert_eq "$(env_lines overlays/config/api-config.env API_DOMAIN)" "API_DOMAIN=api.example.com"
    assert_eq "$(env_lines overlays/config/typesense-config.env TYPESENSE_HOST)" "TYPESENSE_HOST=search.example.com"
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

test_hasura_only_grants_cors_to_the_web_and_api_hosts() {
    make_panel
    set_env overlays/config/api-config.env WEB_DOMAIN Panel.Example.com.
    set_env overlays/config/api-config.env API_DOMAIN api.panel.example.com
    run_setup_env
    assert_eq "$(env_lines overlays/config/api-config.env HASURA_GRAPHQL_CORS_DOMAIN)" \
        "HASURA_GRAPHQL_CORS_DOMAIN=https://panel.example.com, https://api.panel.example.com"
}

test_hasura_cors_includes_the_extra_cors_origins() {
    make_panel
    set_env overlays/config/api-config.env WEB_DOMAIN panel.example.com
    set_env overlays/config/api-config.env API_DOMAIN api.panel.example.com
    printf 'EXTRA_CORS_ORIGINS= https://a.trycloudflare.com ,,https://B.Example.net\r\n' >>"$PANEL/overlays/config/api-config.env"
    run_setup_env
    assert_eq "$(env_lines overlays/config/api-config.env HASURA_GRAPHQL_CORS_DOMAIN)" \
        "HASURA_GRAPHQL_CORS_DOMAIN=https://panel.example.com, https://api.panel.example.com, https://a.trycloudflare.com, https://b.example.net"
}

# dev.sh derives the same line into the committed dev config; a hand edit to
# either key there would otherwise drift from what it writes.
test_the_dev_configs_hasura_cors_is_what_dev_sh_derives() {
    local config="$WORK_DIR/dev-api-config.env"
    cp "$TEST_ROOT/overlays/dev/config/api-config.env" "$config"
    bash -c 'source "$1/utils/update_env_var.sh"; source "$1/utils/ensure_auth_cookie_domain.sh"
        source "$1/utils/ensure_hasura_cors_domain.sh"; ensure_hasura_cors_domain_in_env_file "$2"' \
        _ "$TEST_ROOT" "$config"
    assert_eq "$(cat "$config")" "$(cat "$TEST_ROOT/overlays/dev/config/api-config.env")"
}

test_hasura_cors_follows_a_changed_web_domain() {
    make_panel
    set_env overlays/config/api-config.env WEB_DOMAIN panel.example.com
    set_env overlays/config/api-config.env API_DOMAIN api.panel.example.com
    set_env overlays/config/api-config.env HASURA_GRAPHQL_CORS_DOMAIN "https://old.example.com"
    run_setup_env
    assert_eq "$(env_lines overlays/config/api-config.env HASURA_GRAPHQL_CORS_DOMAIN)" \
        "HASURA_GRAPHQL_CORS_DOMAIN=https://panel.example.com, https://api.panel.example.com"
}

test_custom_ports_move_from_nginx_config_env_to_traefik_config_env() {
    make_panel
    set_env overlays/config/api-config.env WEB_DOMAIN panel.example.com
    printf 'HTTP_PORT=8080\nHTTPS_PORT=8443\n' >"$PANEL/overlays/config/nginx-config.env"
    run_setup_env
    assert_eq "$(env_lines overlays/config/traefik-config.env HTTP_PORT)" "HTTP_PORT=8080"
    assert_eq "$(env_lines overlays/config/traefik-config.env HTTPS_PORT)" "HTTPS_PORT=8443"
    [ ! -e "$PANEL/overlays/config/nginx-config.env" ] || fail "nginx-config.env was left behind"
}

test_a_missing_steam_key_with_no_terminal_stops_instead_of_waiting() {
    make_panel
    set_sibling_domains
    set_env overlays/local-secrets/steam-secrets.env STEAM_WEB_API_KEY ""
    bash -c 'source "$1/utils/utils.sh"' _ "$PANEL" </dev/null >"$WORK_DIR/setup-output" 2>&1 &
    local pid=$! ticks=0 status
    while kill -0 "$pid" 2>/dev/null; do
        if [ "$ticks" -ge 100 ]; then
            kill "$pid"
            fail "setup-env.sh kept waiting for a Steam key with nothing to read from"
        fi
        sleep 0.1
        ticks=$((ticks + 1))
    done
    wait "$pid"
    status=$?
    [ "$status" -ne 0 ] || fail "setup-env.sh carried on without a Steam key"
    assert_contains "$(cat "$WORK_DIR/setup-output")" "has no STEAM_WEB_API_KEY"
}

use_vault() {
    sed 's/^VAULT_MANAGER=false$/VAULT_MANAGER=true/' "$PANEL/.5stack-env.config" >"$PANEL/.5stack-env.config.tmp"
    mv "$PANEL/.5stack-env.config.tmp" "$PANEL/.5stack-env.config"
    mkdir -p "$WORK_DIR/bin"
    printf '#!/bin/sh\necho "$*" >>"%s/vault-calls"\nexit 1\n' "$WORK_DIR" >"$WORK_DIR/bin/vault"
    chmod +x "$WORK_DIR/bin/vault"
    export PATH="$WORK_DIR/bin:$PATH"
}

test_the_5stack_service_runs_a_vault_install_without_the_vault_cli() {
    make_panel
    set_sibling_domains
    use_vault
    FIVESTACK_RELEASE=2026.11.1.1 run_setup_env
    [ ! -e "$WORK_DIR/vault-calls" ] || fail "setup-env.sh called vault: $(cat "$WORK_DIR/vault-calls")"
}

test_update_sh_on_a_vault_install_still_checks_the_vault_login() {
    make_panel
    set_sibling_domains
    use_vault
    bash -c 'source "$1/utils/utils.sh"' _ "$PANEL" </dev/null >"$WORK_DIR/setup-output" 2>&1 && fail "setup-env.sh carried on without a Vault login"
    assert_contains "$(cat "$WORK_DIR/vault-calls")" "status"
    assert_contains "$(cat "$WORK_DIR/setup-output")" "Not logged into vault"
}

test_managed_cloudflare_keeps_a_panel_behind_its_own_reverse_proxy_there() {
    make_panel
    set_env overlays/config/api-config.env WEB_DOMAIN example.com
    printf 'REVERSE_PROXY=true\nCLOUDFLARE=true\nCLOUDFLARE_MANAGED=true\nVAULT_MANAGER=false\nKUBECONFIG=/dev/null\n' >"$PANEL/.5stack-env.config"
    run_setup_env
    assert_contains "$(cat "$WORK_DIR/setup-output")" "no API token yet"
    assert_eq "$(env_lines overlays/local-secrets/cloudflare-secrets.env CLOUDFLARE_API_TOKEN)" "CLOUDFLARE_API_TOKEN="
    assert_eq "$(bash -c 'source "$1/utils/utils.sh" >/dev/null 2>&1; echo "$REVERSE_PROXY $CLOUDFLARE"' _ "$PANEL" </dev/null)" "true true"
    assert_eq "$(bash -c 'source "$1/utils/utils.sh" --reverse-proxy=n >/dev/null 2>&1; echo "$REVERSE_PROXY $CLOUDFLARE"' _ "$PANEL" </dev/null)" "false true"
}

test_managed_cloudflare_without_a_reverse_proxy_issues_its_own_certificates() {
    make_panel
    set_env overlays/config/api-config.env WEB_DOMAIN example.com
    printf 'CLOUDFLARE=true\nCLOUDFLARE_MANAGED=true\nVAULT_MANAGER=false\nKUBECONFIG=/dev/null\n' >"$PANEL/.5stack-env.config"
    assert_eq "$(bash -c 'source "$1/utils/utils.sh" >/dev/null 2>&1; echo "$REVERSE_PROXY $CLOUDFLARE"' _ "$PANEL" </dev/null)" "false true"
}

test_the_cloudflare_flag_with_a_reverse_proxy_saves_both() {
    make_panel
    set_env overlays/config/api-config.env WEB_DOMAIN example.com
    bash -c 'source "$1/utils/utils.sh" --cloudflare-managed --reverse-proxy=y' _ "$PANEL" </dev/null >"$WORK_DIR/setup-output" 2>&1 || fail "$(tail -n 20 "$WORK_DIR/setup-output")"
    assert_eq "$(env_lines .5stack-env.config CLOUDFLARE_MANAGED)" "CLOUDFLARE_MANAGED=true"
    assert_eq "$(env_lines .5stack-env.config REVERSE_PROXY)" "REVERSE_PROXY=true"
}

test_a_cloudflare_token_the_5stack_service_passes_is_not_asked_for() {
    make_panel
    set_sibling_domains
    printf 'REVERSE_PROXY=false\nCLOUDFLARE=true\nCLOUDFLARE_MANAGED=true\nVAULT_MANAGER=false\nKUBECONFIG=/dev/null\n' >"$PANEL/.5stack-env.config"
    CLOUDFLARE_API_TOKEN=cf-from-the-service FIVESTACK_RELEASE=2026.11.4.1 run_setup_env
    assert_not_contains "$(cat "$WORK_DIR/setup-output")" "no API token yet"
    assert_eq "$(env_lines overlays/local-secrets/cloudflare-secrets.env CLOUDFLARE_API_TOKEN)" "CLOUDFLARE_API_TOKEN="
}

test_a_vault_install_is_never_told_it_has_no_cloudflare_token() {
    make_panel
    set_sibling_domains
    printf 'REVERSE_PROXY=false\nCLOUDFLARE=true\nCLOUDFLARE_MANAGED=true\nVAULT_MANAGER=true\nKUBECONFIG=/dev/null\n' >"$PANEL/.5stack-env.config"
    FIVESTACK_RELEASE=2026.11.4.1 run_setup_env
    assert_not_contains "$(cat "$WORK_DIR/setup-output")" "no API token yet"
}

test_the_cloudflare_flag_saves_managed_mode() {
    make_panel
    set_env overlays/config/api-config.env WEB_DOMAIN example.com
    bash -c 'source "$1/utils/utils.sh" --cloudflare-managed' _ "$PANEL" </dev/null >"$WORK_DIR/setup-output" 2>&1 || fail "$(tail -n 20 "$WORK_DIR/setup-output")"
    assert_eq "$(env_lines .5stack-env.config CLOUDFLARE_MANAGED)" "CLOUDFLARE_MANAGED=true"
    assert_eq "$(env_lines .5stack-env.config REVERSE_PROXY)" "REVERSE_PROXY=false"
}

test_the_token_page_asks_for_exactly_what_setup_uses() {
    make_panel
    set_env overlays/config/api-config.env WEB_DOMAIN example.com
    url="$(bash -c 'source "$1/utils/utils.sh" >/dev/null 2>&1; cloudflare_token_url' _ "$PANEL" </dev/null)"
    assert_contains "$url" "https://dash.cloudflare.com/profile/api-tokens?permissionGroupKeys="
    assert_contains "$url" "&accountId=*&zoneId=all&name=5Stack%20panel"
    keys="$(python3 -c 'import sys, urllib.parse, json; q = urllib.parse.parse_qs(urllib.parse.urlparse(sys.argv[1]).query); print(" ".join(k["key"] + ":" + k["type"] for k in json.loads(q["permissionGroupKeys"][0])))' "$url")"
    assert_eq "$keys" "zone:read dns:edit zone_settings:edit ssl_and_certificates:read config_settings:edit cache_settings:edit workers_routes:edit workers_scripts:edit bot_management:read dynamic_url_redirects:edit page_rules:read"
}

run_tests
