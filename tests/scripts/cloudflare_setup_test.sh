#!/bin/bash

# shellcheck source=tests/scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CF_STUB="$(cd "$(dirname "${BASH_SOURCE[0]}")/cloudflare-stub" && pwd)"
TOKEN="cf-test-token-0123456789"

panel_at() {
    local domain="$1"
    mkdir -p "$WORK_DIR/panel/overlays/config" "$WORK_DIR/panel/overlays/coturn" "$WORK_DIR/panel/overlays/local-secrets"
    cat >"$WORK_DIR/panel/overlays/config/api-config.env" <<EOF
WEB_DOMAIN=$domain
API_DOMAIN=api.$domain
WS_DOMAIN=ws.$domain
RELAY_DOMAIN=tv.$domain
DEMOS_DOMAIN=demos.$domain
GAME_STREAM_DOMAIN=hls.$domain
EOF
    printf 'S3_CONSOLE_HOST=console.%s\n' "$domain" >"$WORK_DIR/panel/overlays/config/s3-config.env"
    printf 'TYPESENSE_HOST=search.%s\n' "$domain" >"$WORK_DIR/panel/overlays/config/typesense-config.env"
    printf 'HTTP_PORT=80\nHTTPS_PORT=443\n' >"$WORK_DIR/panel/overlays/config/traefik-config.env"
    printf 'CLOUDFLARE_API_TOKEN=%s\n' "$TOKEN" >"$WORK_DIR/panel/overlays/local-secrets/cloudflare-secrets.env"
}

zone() {
    local name="$1" plan="${2:-Free Website}"
    jq -nc --arg t "$TOKEN" --arg n "$name" --arg p "$plan" \
        '{token: $t, ip: "203.0.113.40", zones: [{id: "z1", name: $n, plan: {name: $p}}], records: []}' >"$WORK_DIR/cf-state.json"
}

state() {
    jq -c "$1" "$WORK_DIR/cf-state.json" >"$WORK_DIR/cf-state.next" && mv "$WORK_DIR/cf-state.next" "$WORK_DIR/cf-state.json"
}

cf() {
    (
        export PANEL_DIR="$WORK_DIR/panel" PATH="$CF_STUB:$PATH"
        unset CLOUDFLARE_API_TOKEN CLOUDFLARE_ORIGIN_IPV4 CLOUDFLARE_ORIGIN_IPV6 HTTPS_PORT TURN_DOMAIN CLOUDFLARE_WORKER_DOMAIN
        bash "$TEST_ROOT/utils/cloudflare_setup.sh" "$@"
    )
}

plan_of() {
    cf plan | awk -v h="$1" '$2 == h { print $5 " " $6 }'
}

record() {
    jq -r --arg n "$1" --arg t "${2:-A}" '[.records[] | select(.name == $n and .type == $t)][0] | "\(.content) \(.proxied)"' "$WORK_DIR/cf-state.json"
}

test_everything_but_demo_uploads_streams_and_turn_goes_through_cloudflare() {
    panel_at example.gg
    zone example.gg
    printf 'TURN_DOMAIN=turn.example.gg\n' >"$WORK_DIR/panel/overlays/coturn/coturn.env"
    for host in example.gg api.example.gg ws.example.gg tv.example.gg search.example.gg console.example.gg; do
        assert_eq "$(plan_of "$host")" "yes -"
    done
    assert_eq "$(plan_of demos.example.gg)" "no uploads"
    assert_eq "$(plan_of hls.example.gg)" "no video"
    assert_eq "$(plan_of turn.example.gg)" "no udp"
    cf records >"$WORK_DIR/out" 2>&1 || fail "records: $(cat "$WORK_DIR/out")"
    cf proxy >"$WORK_DIR/out" 2>&1 || fail "proxy: $(cat "$WORK_DIR/out")"
    assert_eq "$(record api.example.gg)" "203.0.113.40 true"
    assert_eq "$(record demos.example.gg)" "203.0.113.40 false"
    assert_eq "$(record hls.example.gg)" "203.0.113.40 false"
    assert_eq "$(record turn.example.gg)" "203.0.113.40 false"
    if grep -E '"name":"(demos|hls|turn)\.example\.gg"[^}]*"proxied":true' "$WORK_DIR/cf-calls"; then
        fail "demos, hls or turn was sent with proxied:true"
    fi
    if grep -E 'ORIGIN (demos|hls|turn)\.example\.gg' "$WORK_DIR/cf-calls"; then
        fail "the proxy step checked a host that stays straight to this server"
    fi
}

test_one_level_below_the_zone_is_covered_and_deeper_names_are_not() {
    panel_at panel.example.gg
    zone example.gg
    assert_eq "$(plan_of panel.example.gg)" "yes -"
    assert_eq "$(plan_of api.panel.example.gg)" "no depth"
    assert_eq "$(plan_of ws.panel.example.gg)" "no depth"
}

test_two_levels_deep_nothing_is_proxied() {
    panel_at cs.panel.example.gg
    zone example.gg
    assert_eq "$(plan_of cs.panel.example.gg)" "no depth"
    assert_eq "$(plan_of api.cs.panel.example.gg)" "no depth"
}

test_a_paid_plan_alone_does_not_cover_deeper_names() {
    panel_at panel.example.gg
    zone example.gg "Pro Website"
    assert_eq "$(plan_of api.panel.example.gg)" "no depth"
}

test_an_advanced_certificate_covers_deeper_names() {
    panel_at panel.example.gg
    zone example.gg
    state '.packs.z1 = [{status: "active", type: "advanced", hosts: ["panel.example.gg", "*.panel.example.gg"]}]'
    assert_eq "$(plan_of api.panel.example.gg)" "yes -"
    state '.packs.z1[0].status = "pending_validation"'
    assert_eq "$(plan_of api.panel.example.gg)" "no depth"
}

test_a_panel_off_port_443_proxies_nothing() {
    panel_at example.gg
    zone example.gg
    printf 'HTTP_PORT=8080\nHTTPS_PORT=8443\n' >"$WORK_DIR/panel/overlays/config/traefik-config.env"
    assert_eq "$(plan_of api.example.gg)" "no port"
    assert_eq "$(plan_of example.gg)" "no port"
}

test_worker_hostnames_are_never_touched() {
    panel_at example.gg
    zone example.gg
    printf 'CLOUDFLARE_WORKER_DOMAIN=cf.example.gg\n' >>"$WORK_DIR/panel/overlays/config/api-config.env"
    state '.routes.z1 = [{id: "w1", pattern: "tv.example.gg/*", script: "5stack-playcast-relay"}]'
    assert_eq "$(plan_of tv.example.gg)" "skip worker"
    assert_eq "$(plan_of cf.example.gg)" ""
    cf records >"$WORK_DIR/out" 2>&1 || fail "records: $(cat "$WORK_DIR/out")"
    if grep -E '(POST|PATCH|DELETE) .*(tv|cf)\.example\.gg' "$WORK_DIR/cf-calls"; then
        fail "a Worker's hostname was changed"
    fi
}

test_records_start_dns_only_and_keep_their_cloud() {
    panel_at example.gg
    zone example.gg
    cf records >/dev/null 2>&1 || fail "records"
    assert_eq "$(record ws.example.gg)" "203.0.113.40 false"
    cf proxy >"$WORK_DIR/out" 2>&1 || fail "proxy: $(cat "$WORK_DIR/out")"
    assert_eq "$(record ws.example.gg)" "203.0.113.40 true"
    state '.ip = "203.0.113.41"'
    cf records >/dev/null 2>&1 || fail "records again"
    assert_eq "$(record ws.example.gg)" "203.0.113.41 true"
    assert_eq "$(jq '[.records[] | select(.name == "ws.example.gg")] | length' "$WORK_DIR/cf-state.json")" 1
}

test_records_that_are_not_ours_are_left_until_replaced() {
    panel_at example.gg
    zone example.gg
    state '.records = [{id: "old1", zone: "z1", type: "A", name: "api.example.gg", content: "198.51.100.7", proxied: true}, {id: "mx", zone: "z1", type: "MX", name: "example.gg", content: "mail.example.gg"}, {id: "txt", zone: "z1", type: "TXT", name: "example.gg", content: "v=spf1"}]'
    cf records >"$WORK_DIR/out" 2>&1
    assert_eq "$?" 2
    assert_contains "$(cat "$WORK_DIR/out")" "conflict: api.example.gg A 198.51.100.7 proxied"
    assert_eq "$(record api.example.gg)" "198.51.100.7 true"
    cf records --replace api.example.gg >"$WORK_DIR/out" 2>&1 || fail "replace: $(cat "$WORK_DIR/out")"
    assert_eq "$(record api.example.gg)" "203.0.113.40 false"
    assert_eq "$(jq -r '[.records[] | select(.type == "MX" or .type == "TXT") | .id] | join(",")' "$WORK_DIR/cf-state.json")" "mx,txt"
}

test_rules_are_added_by_ref_and_an_entrypoint_is_never_replaced() {
    panel_at example.gg
    zone example.gg
    state '.rulesets.z1.http_config_settings = {id: "rs9", phase: "http_config_settings", rules: [{id: "theirs", ref: "their_rule", expression: "true"}]}'
    cf records >/dev/null 2>&1
    cf proxy >"$WORK_DIR/out" 2>&1 || fail "proxy: $(cat "$WORK_DIR/out")"
    cf proxy >"$WORK_DIR/out" 2>&1 || fail "proxy again: $(cat "$WORK_DIR/out")"
    assert_eq "$(jq -r '[.rulesets.z1.http_config_settings.rules[].ref] | join(",")' "$WORK_DIR/cf-state.json")" "their_rule,5stack_panel"
    assert_eq "$(jq -r '.rulesets.z1.http_config_settings.rules[1].action_parameters | "\(.ssl) \(.rocket_loader) \(.email_obfuscation) \(.disable_zaraz) \(.bic)"' "$WORK_DIR/cf-state.json")" "strict false false true false"
    assert_eq "$(jq -r '.rulesets.z1.http_request_cache_settings.rules | length' "$WORK_DIR/cf-state.json")" 1
    assert_contains "$(jq -r '.rulesets.z1.http_request_cache_settings.rules[0].expression' "$WORK_DIR/cf-state.json")" '"api.example.gg"'
    assert_not_contains "$(jq -r '.rulesets.z1.http_request_cache_settings.rules[0].expression' "$WORK_DIR/cf-state.json")" '"example.gg"'
    assert_not_contains "$(cat "$WORK_DIR/cf-calls")" "PUT-OVER-EXISTING"
    assert_eq "$(grep -c 'PATCH /zones/z1/rulesets/rs9/rules/' "$WORK_DIR/cf-calls")" 1
}

test_bot_fight_mode_stops_the_proxy_before_anything_changes() {
    panel_at example.gg
    zone example.gg
    cf records >/dev/null 2>&1
    state '.bot_fight.z1 = true'
    : >"$WORK_DIR/cf-calls"
    cf proxy >"$WORK_DIR/out" 2>&1 && fail "proxied with Bot Fight Mode on"
    assert_contains "$(cat "$WORK_DIR/out")" "Bot Fight Mode on"
    if grep -E '^(PATCH|PUT) ' "$WORK_DIR/cf-calls" || grep -E '^POST /zones/z1/rulesets' "$WORK_DIR/cf-calls"; then
        fail "something changed: $(cat "$WORK_DIR/cf-calls")"
    fi
}

test_a_host_cloudflare_cannot_reach_goes_back_to_dns_only() {
    panel_at example.gg
    zone example.gg
    state '.origin = {"ws.example.gg": 522}'
    cf records >/dev/null 2>&1
    cf proxy >"$WORK_DIR/out" 2>&1
    assert_eq "$?" 3
    assert_eq "$(record ws.example.gg)" "203.0.113.40 false"
    assert_eq "$(record api.example.gg)" "203.0.113.40 true"
}

test_the_token_never_reaches_curl_arguments() {
    panel_at example.gg
    zone example.gg
    cf records >/dev/null 2>&1
    assert_not_contains "$(cat "$WORK_DIR/cf-calls")" "TOKEN-IN-ARGS"
    assert_not_contains "$(cat "$WORK_DIR/cf-calls")" "$TOKEN"
    state '.token = "another"'
    cf records >"$WORK_DIR/out" 2>&1 && fail "a wrong token worked"
    true
}

test_a_private_address_stops_the_records() {
    panel_at example.gg
    zone example.gg
    state '.ip = "100.72.1.4"'
    cf records >"$WORK_DIR/out" 2>&1 && fail "records pointed at a CGNAT address"
    assert_contains "$(cat "$WORK_DIR/out")" "private address"
    assert_eq "$(jq '.records | length' "$WORK_DIR/cf-state.json")" 0
}

test_a_token_without_dns_edit_is_named_before_anything_changes() {
    panel_at example.gg
    zone example.gg
    state '.no_dns_edit = true'
    assert_contains "$(cf check)" "dns_edit: example.gg"
}

test_status_names_a_moved_record_and_fix_puts_it_back() {
    panel_at example.gg
    zone example.gg
    cf records >/dev/null 2>&1
    cf proxy >/dev/null 2>&1
    state '(.records[] | select(.name == "ws.example.gg" and .type == "A")) |= (.content = "192.0.2.10")'
    state '(.records[] | select(.name == "hls.example.gg" and .type == "A")) |= (.proxied = true)'
    status="$(cf status --json)"
    assert_eq "$(jq -r '.hosts[] | select(.host == "ws.example.gg") | .state' <<<"$status")" elsewhere
    assert_eq "$(jq -r '.hosts[] | select(.host == "hls.example.gg") | "\(.state) \(.want_proxied) \(.why)"' <<<"$status")" "cloud false video"
    assert_eq "$(jq -r '.hosts[] | select(.host == "demos.example.gg") | "\(.state) \(.want_proxied)"' <<<"$status")" "ok false"
    assert_eq "$(jq -r '.zones[0] | "\(.name) \(.ssl) \(.websockets) \(.bot_fight) \(.tiered_cache)"' <<<"$status")" "example.gg strict on false off"
    cf fix ws.example.gg >/dev/null 2>&1 || fail "fix"
    assert_eq "$(record ws.example.gg)" "203.0.113.40 true"
    cf fix hls.example.gg >/dev/null 2>&1 || fail "fix hls"
    assert_eq "$(record hls.example.gg)" "203.0.113.40 false"
    cf tiered-cache || fail "tiered cache"
    assert_eq "$(jq -r '"\(.argo.z1) \(.tiered.z1)"' "$WORK_DIR/cf-state.json")" "on on"
}

run_tests
