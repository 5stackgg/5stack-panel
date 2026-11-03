#!/bin/bash

# shellcheck source=tests/scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CF_STUB="$(cd "$(dirname "${BASH_SOURCE[0]}")/cloudflare-stub" && pwd)"
TOKEN="cf-test-token-0123456789"
STUB_PATH="$CF_STUB:$PATH"

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
        export PANEL_DIR="$WORK_DIR/panel" PATH="$STUB_PATH"
        unset CLOUDFLARE_API_TOKEN CLOUDFLARE_ORIGIN_IPV4 CLOUDFLARE_ORIGIN_IPV6 HTTPS_PORT TURN_DOMAIN CLOUDFLARE_WORKER_DOMAIN VAULT_MANAGER
        CF_RELAY_WAIT=2 CF_RELAY_PAUSE=0 CF_PROBE_WAIT=2 CF_PROBE_PAUSE=0 bash "$TEST_ROOT/utils/cloudflare_setup.sh" "$@" </dev/null
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
    assert_eq "$(jq -r '[.rulesets.z1.http_config_settings.rules[].ref] | join(",")' "$WORK_DIR/cf-state.json")" "their_rule,5stack_panel,5stack_panel_acme"
    assert_eq "$(jq -r '.rulesets.z1.http_config_settings.rules[1].action_parameters | "\(.ssl) \(.rocket_loader) \(.email_obfuscation) \(.disable_zaraz) \(.bic)"' "$WORK_DIR/cf-state.json")" "strict false false true false"
    assert_eq "$(jq -r '.rulesets.z1.http_request_cache_settings.rules | length' "$WORK_DIR/cf-state.json")" 1
    assert_contains "$(jq -r '.rulesets.z1.http_request_cache_settings.rules[0].expression' "$WORK_DIR/cf-state.json")" '"api.example.gg"'
    assert_not_contains "$(jq -r '.rulesets.z1.http_request_cache_settings.rules[0].expression' "$WORK_DIR/cf-state.json")" '"example.gg"'
    assert_not_contains "$(cat "$WORK_DIR/cf-calls")" "PUT-OVER-EXISTING"
    assert_eq "$(grep -c 'PATCH /zones/z1/rulesets/rs9/rules/' "$WORK_DIR/cf-calls")" 2
}

through_cloudflare() {
    PATH="$STUB_PATH" curl -sS -o /dev/null -D - "http://$1$2" | tr -d '\r'
}

redirect_rule() {
    jq -c '.rulesets.z1.http_request_dynamic_redirect.rules[] | select(.ref == "5stack_panel_https")' "$WORK_DIR/cf-state.json"
}

test_always_use_https_goes_off_and_a_rule_redirects_everything_but_the_challenge_path() {
    panel_at example.gg
    zone example.gg
    state '.settings.z1.always_use_https = "on"'
    cf records >/dev/null 2>&1 || fail "records"
    cf proxy >"$WORK_DIR/out" 2>&1 || fail "proxy: $(cat "$WORK_DIR/out")"
    assert_eq "$(jq -r '.settings.z1.always_use_https' "$WORK_DIR/cf-state.json")" off
    assert_eq "$(redirect_rule | jq -r '.expression')" '(not ssl and not starts_with(http.request.uri.path, "/.well-known/acme-challenge/"))'
    assert_eq "$(redirect_rule | jq -r '"\(.action) \(.enabled) \(.action_parameters.from_value.status_code) \(.action_parameters.from_value.preserve_query_string)"')" "redirect true 301 true"
    assert_eq "$(redirect_rule | jq -r '.action_parameters.from_value.target_url.expression')" 'concat("https://", http.host, http.request.uri.path)'
    rule_at="$(grep -n 'POST /zones/z1/rulesets/.*5stack_panel_https\|PUT /zones/z1/rulesets/phases/http_request_dynamic_redirect' "$WORK_DIR/cf-calls" | head -n 1 | cut -d: -f1)"
    off_at="$(grep -n 'PATCH /zones/z1/settings/always_use_https' "$WORK_DIR/cf-calls" | cut -d: -f1)"
    [ -n "$rule_at" ] && [ -n "$off_at" ] && [ "$rule_at" -lt "$off_at" ] || fail "Always Use HTTPS went off before the rule was in"
    assert_contains "$(through_cloudflare api.example.gg /.well-known/acme-challenge/5stack-check)" "x-5stack-check: acme-path"
    assert_contains "$(through_cloudflare api.example.gg /.well-known/acme-challenge/5stack-check)" "cf-ray:"
    assert_contains "$(through_cloudflare api.example.gg /login)" "HTTP/1.1 301"
    assert_contains "$(through_cloudflare example.gg /login)" "location: https://example.gg/login"
    assert_not_contains "$(cat "$WORK_DIR/out")" "(y/n)"
    assert_not_contains "$(cat "$WORK_DIR/out")" "other sites"
    for host in example.gg api.example.gg ws.example.gg tv.example.gg search.example.gg console.example.gg; do
        assert_eq "$(record "$host")" "203.0.113.40 true"
        assert_contains "$(cat "$WORK_DIR/cf-calls")" "HTTP $host/.well-known/acme-challenge/5stack-check cloudflare"
    done
    if grep -E 'HTTP (demos|hls)\.example\.gg' "$WORK_DIR/cf-calls"; then
        fail "probed a host that stays straight to this server"
    fi
    cf proxy >"$WORK_DIR/out" 2>&1 || fail "proxy again: $(cat "$WORK_DIR/out")"
    assert_eq "$(jq '[.rulesets.z1.http_request_dynamic_redirect.rules[] | select(.ref == "5stack_panel_https")] | length' "$WORK_DIR/cf-state.json")" 1
    assert_eq "$(redirect_rule | jq -r '.expression')" '(not ssl and not starts_with(http.request.uri.path, "/.well-known/acme-challenge/"))'
    assert_not_contains "$(cat "$WORK_DIR/cf-calls")" "PUT-OVER-EXISTING"
}

test_with_always_use_https_off_the_rule_covers_only_the_panel() {
    panel_at example.gg
    zone example.gg
    state '.rulesets.z1.http_request_dynamic_redirect = {id: "rs7", phase: "http_request_dynamic_redirect", rules: [{id: "theirs", ref: "their_shop", action: "redirect", expression: "(http.host in {\"shop.example.gg\"} and not ssl)", action_parameters: {from_value: {status_code: 301}}}]}'
    cf records >/dev/null 2>&1 || fail "records"
    cf proxy >"$WORK_DIR/out" 2>&1 || fail "proxy: $(cat "$WORK_DIR/out")"
    expression="$(redirect_rule | jq -r '.expression')"
    assert_contains "$expression" '(http.host in {"example.gg" "api.example.gg"'
    assert_contains "$expression" 'and (not ssl and not starts_with(http.request.uri.path, "/.well-known/acme-challenge/"))'
    assert_not_contains "$expression" "demos.example.gg"
    assert_not_contains "$expression" "hls.example.gg"
    assert_eq "$(jq -r '[.rulesets.z1.http_request_dynamic_redirect.rules[].ref] | join(",")' "$WORK_DIR/cf-state.json")" "their_shop,5stack_panel_https"
    assert_not_contains "$(cat "$WORK_DIR/cf-calls")" "PATCH /zones/z1/settings/always_use_https"
    assert_not_contains "$(cat "$WORK_DIR/out")" "their_shop"
}

test_the_challenge_path_is_kept_off_security_challenges() {
    panel_at example.gg
    zone example.gg
    cf records >/dev/null 2>&1 || fail "records"
    cf proxy >"$WORK_DIR/out" 2>&1 || fail "proxy: $(cat "$WORK_DIR/out")"
    rule="$(jq -c '.rulesets.z1.http_config_settings.rules[] | select(.ref == "5stack_panel_acme")' "$WORK_DIR/cf-state.json")"
    assert_eq "$(jq -r '"\(.action) \(.action_parameters.security_level) \(.action_parameters.bic)"' <<<"$rule")" "set_config essentially_off false"
    assert_contains "$(jq -r '.expression' <<<"$rule")" '"api.example.gg"'
    assert_contains "$(jq -r '.expression' <<<"$rule")" 'and starts_with(http.request.uri.path, "/.well-known/acme-challenge/")'
}

test_a_page_rule_that_redirects_the_check_keeps_the_panel_straight_to_this_server() {
    panel_at example.gg
    zone example.gg
    state '.pagerules.z1 = [{id: "pr1", status: "active", targets: [{target: "url", constraint: {operator: "matches", value: "http://*example.gg/*"}}], actions: [{id: "always_use_https"}]}]'
    cf records >/dev/null 2>&1 || fail "records"
    cf proxy >"$WORK_DIR/out" 2>&1
    assert_eq "$?" 3
    assert_contains "$(cat "$WORK_DIR/out")" "The Page Rule for http://*example.gg/* (always_use_https) sends Let's Encrypt's check to HTTPS"
    assert_contains "$(cat "$WORK_DIR/out")" "Let's Encrypt can't reach api.example.gg through Cloudflare: Cloudflare redirects http://api.example.gg/.well-known/acme-challenge/5stack-check to https://api.example.gg/.well-known/acme-challenge/5stack-check"
    for host in example.gg api.example.gg ws.example.gg tv.example.gg search.example.gg console.example.gg; do
        assert_eq "$(record "$host")" "203.0.113.40 false"
    done
}

test_someone_elses_redirect_rule_is_named_and_only_its_host_stays_straight() {
    panel_at example.gg
    zone example.gg
    state '.rulesets.z1.http_request_dynamic_redirect = {id: "rs7", phase: "http_request_dynamic_redirect", rules: [{id: "theirs", ref: "their_api", description: "API to HTTPS", action: "redirect", expression: "(http.host in {\"api.example.gg\"} and not ssl)", action_parameters: {from_value: {status_code: 308}}}, {id: "fine", ref: "their_fine", description: "Fine", action: "redirect", expression: "(not ssl and not starts_with(http.request.uri.path, \"/.well-known/acme-challenge/\"))", action_parameters: {from_value: {status_code: 301}}}]}'
    cf records >/dev/null 2>&1 || fail "records"
    cf proxy >"$WORK_DIR/out" 2>&1
    assert_eq "$?" 3
    assert_contains "$(cat "$WORK_DIR/out")" 'The Redirect Rule "API to HTTPS" can send Let'"'"'s Encrypt'"'"'s check to HTTPS. Leave /.well-known/acme-challenge/ out of it.'
    assert_not_contains "$(cat "$WORK_DIR/out")" '"Fine"'
    assert_eq "$(record api.example.gg)" "203.0.113.40 false"
    assert_eq "$(record ws.example.gg)" "203.0.113.40 true"
    status="$(cf status --json)"
    assert_contains "$(jq -r '.zones[0].blockers[0]' <<<"$status")" 'The Redirect Rule "API to HTTPS"'
    assert_eq "$(jq -r '.zones[0] | "\(.always_https) \(.https_rule)"' <<<"$status")" "off true"
}

test_a_security_challenge_or_a_panel_without_the_check_keeps_the_host_straight() {
    panel_at example.gg
    zone example.gg
    state '.challenge = ["ws.example.gg"]'
    cf records >/dev/null 2>&1 || fail "records"
    cf proxy >"$WORK_DIR/out" 2>&1
    assert_eq "$?" 3
    assert_contains "$(cat "$WORK_DIR/out")" "Let's Encrypt can't reach ws.example.gg through Cloudflare: Cloudflare answers http://ws.example.gg/.well-known/acme-challenge/5stack-check with a security challenge"
    assert_eq "$(record ws.example.gg)" "203.0.113.40 false"
    assert_eq "$(record api.example.gg)" "203.0.113.40 true"
    state '.challenge = [] | .no_acme_route = true'
    cf proxy >"$WORK_DIR/out" 2>&1
    assert_eq "$?" 3
    assert_eq "$(record api.example.gg)" "203.0.113.40 false"
}

test_a_check_that_never_goes_through_cloudflare_is_named_and_the_host_kept() {
    panel_at example.gg
    zone example.gg
    state '.stale_dns = true'
    cf records >/dev/null 2>&1 || fail "records"
    cf proxy >"$WORK_DIR/out" 2>&1 || fail "proxy: $(cat "$WORK_DIR/out")"
    assert_contains "$(cat "$WORK_DIR/out")" "http://example.gg/.well-known/acme-challenge/5stack-check didn't answer through Cloudflare yet"
    assert_eq "$(record example.gg)" "203.0.113.40 true"
    assert_eq "$(grep -c 'HTTP example.gg/.well-known/acme-challenge/5stack-check' "$WORK_DIR/cf-calls")" 2
}

test_a_key_without_redirect_rules_is_named_before_anything_changes() {
    panel_at example.gg
    zone example.gg
    state '.rulesets.z1.http_request_dynamic_redirect = {id: "rs7", phase: "http_request_dynamic_redirect", rules: []} | .no_redirect_rules = true'
    assert_contains "$(cf check)" "redirect_rules: The Cloudflare key can't manage Redirect Rules for example.gg"
}

test_the_key_comes_from_the_file_or_vault_and_never_a_kubernetes_secret() {
    panel_at example.gg
    zone example.gg
    printf 'CLOUDFLARE_API_TOKEN=VAULT\n' >"$WORK_DIR/panel/overlays/local-secrets/cloudflare-secrets.env"
    mkdir -p "$WORK_DIR/bin"
    FAKE_SECRET="$(printf %s "$TOKEN" | base64)"
    FAKE_TOKEN="$TOKEN"
    export FAKE_SECRET FAKE_TOKEN
    cat >"$WORK_DIR/bin/kubectl" <<'STUB'
#!/bin/bash
echo "$*" >>"$WORK_DIR/kubectl-calls"
printf %s "$FAKE_SECRET"
STUB
    chmod +x "$WORK_DIR/bin/kubectl"
    STUB_PATH="$WORK_DIR/bin:$STUB_PATH"
    cf plan >"$WORK_DIR/out" 2>&1 && fail "read the key from somewhere other than the file or Vault"
    assert_contains "$(cat "$WORK_DIR/out")" "No Cloudflare API token"
    [ ! -e "$WORK_DIR/kubectl-calls" ] || fail "asked Kubernetes for the key: $(cat "$WORK_DIR/kubectl-calls")"
    cat >"$WORK_DIR/bin/vault" <<'STUB'
#!/bin/bash
[ "$*" = "kv get -field=CLOUDFLARE_API_TOKEN kv/cloudflare" ] && printf %s "$FAKE_TOKEN"
STUB
    chmod +x "$WORK_DIR/bin/vault"
    cf plan >"$WORK_DIR/out" 2>&1 || fail "plan with the key in Vault: $(cat "$WORK_DIR/out")"
    assert_contains "$(cat "$WORK_DIR/out")" "api.example.gg"
    [ ! -e "$WORK_DIR/kubectl-calls" ] || fail "asked Kubernetes for the key"
}

test_only_the_selected_zone_is_used() {
    panel_at example.gg
    zone example.gg
    assert_eq "$(CLOUDFLARE_ZONE=other.gg plan_of api.example.gg)" "skip not_in_account"
    assert_eq "$(CLOUDFLARE_ZONE=example.gg plan_of api.example.gg)" "yes -"
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

test_the_stream_relay_puts_a_worker_in_front_of_streams_and_records_stay_its_own() {
    panel_at example.gg
    zone example.gg
    cf records >/dev/null 2>&1 || fail "records"
    cf proxy >/dev/null 2>&1 || fail "proxy"
    assert_eq "$(record hls.example.gg)" "203.0.113.40 false"
    cf stream-relay >"$WORK_DIR/out" 2>&1 || fail "stream-relay: $(cat "$WORK_DIR/out")"
    assert_eq "$(jq -r '.workers["5stack-stream-relay"] | "\(.account) \(.metadata.main_module) \(.metadata.bindings[0].name)=\(.metadata.bindings[0].text)"' "$WORK_DIR/cf-state.json")" "acct1 worker.js WEB_ORIGIN=https://example.gg"
    assert_contains "$(jq -r '.workers["5stack-stream-relay"].module' "$WORK_DIR/cf-state.json")" "5stack-stream-relay"
    assert_eq "$(jq -r '.routes.z1[] | "\(.pattern) \(.script) \(.request_limit_fail_open)"' "$WORK_DIR/cf-state.json")" "hls.example.gg/* 5stack-stream-relay false"
    assert_eq "$(record hls.example.gg)" "203.0.113.40 true"
    assert_eq "$(plan_of hls.example.gg)" "skip worker"
    assert_contains "$(jq -r '.rulesets.z1.http_config_settings.rules[0].expression' "$WORK_DIR/cf-state.json")" '"hls.example.gg"'
    assert_contains "$(jq -r '.rulesets.z1.http_request_cache_settings.rules[0].expression' "$WORK_DIR/cf-state.json")" '"hls.example.gg"'
    : >"$WORK_DIR/cf-calls"
    cf records >/dev/null 2>&1 || fail "records again"
    cf proxy >/dev/null 2>&1 || fail "proxy again"
    assert_eq "$(record hls.example.gg)" "203.0.113.40 true"
    if grep -E '(POST|PATCH|DELETE) /zones/z1/dns_records.*hls\.example\.gg' "$WORK_DIR/cf-calls"; then
        fail "an update changed the stream relay's record"
    fi
    cf stream-relay >/dev/null 2>&1 || fail "stream-relay again"
    assert_eq "$(jq '.routes.z1 | length' "$WORK_DIR/cf-state.json")" 1
}

test_an_unreadable_route_list_leaves_every_host_alone() {
    panel_at example.gg
    zone example.gg
    state '.no_routes_read = true'
    assert_eq "$(plan_of hls.example.gg)" "skip routes"
    assert_eq "$(plan_of api.example.gg)" "skip routes"
    cf records >/dev/null 2>&1
    assert_eq "$(jq '.records | length' "$WORK_DIR/cf-state.json")" 0
}

test_a_stream_relay_that_never_answers_puts_streams_back_straight_to_the_server() {
    panel_at example.gg
    zone example.gg
    cf records >/dev/null 2>&1 || fail "records"
    state '.worker_down = true'
    cf stream-relay >"$WORK_DIR/out" 2>&1
    assert_eq "$?" 3
    assert_contains "$(cat "$WORK_DIR/out")" "isn't answering on hls.example.gg"
    assert_eq "$(record hls.example.gg)" "203.0.113.40 false"
}

test_the_stream_relay_stops_on_a_token_that_cannot_deploy_workers() {
    panel_at example.gg
    zone example.gg
    cf records >/dev/null 2>&1 || fail "records"
    state '.no_workers_write = true'
    cf stream-relay >"$WORK_DIR/out" 2>&1 && fail "deployed without Workers Scripts write"
    assert_contains "$(cat "$WORK_DIR/out")" "refused the stream relay Worker"
    assert_eq "$(record hls.example.gg)" "203.0.113.40 false"
    assert_eq "$(jq '.routes.z1 // [] | length' "$WORK_DIR/cf-state.json")" 0
}

test_the_stream_relay_needs_a_name_the_free_certificate_covers() {
    panel_at panel.example.gg
    zone example.gg
    cf stream-relay >"$WORK_DIR/out" 2>&1 && fail "relayed a name too deep for the certificate"
    assert_contains "$(cat "$WORK_DIR/out")" "deeper than Cloudflare's free certificate"
    assert_eq "$(jq '.workers // {} | length' "$WORK_DIR/cf-state.json")" 0
}

test_stream_relay_sh_uses_the_managed_key_and_keeps_the_worker_through_updates() {
    panel_at example.gg
    zone example.gg
    cp -R "$TEST_ROOT/utils" "$TEST_ROOT/stream-relay.sh" "$WORK_DIR/panel/"
    mkdir -p "$WORK_DIR/panel/cloudflare-workers"
    cp -R "$TEST_ROOT/cloudflare-workers/stream-relay" "$WORK_DIR/panel/cloudflare-workers/"
    printf 'CLOUDFLARE_MANAGED=true\n' >"$WORK_DIR/panel/.5stack-env.config"
    cf records >/dev/null 2>&1 || fail "records"
    env -u CLOUDFLARE_API_TOKEN -u CLOUDFLARE_ORIGIN_IPV4 -u HTTPS_PORT PATH="$STUB_PATH" CF_RELAY_WAIT=2 CF_RELAY_PAUSE=0 \
        bash "$WORK_DIR/panel/stream-relay.sh" </dev/null >"$WORK_DIR/out" 2>&1 || fail "stream-relay.sh: $(cat "$WORK_DIR/out")"
    assert_contains "$(cat "$WORK_DIR/out")" "Workers Paid"
    assert_eq "$(record hls.example.gg)" "203.0.113.40 true"
    assert_contains "$(cat "$WORK_DIR/panel/.5stack-env.config")" "CLOUDFLARE_STREAM_RELAY=true"
    assert_not_contains "$(cat "$WORK_DIR/out")" "npx"
}

run_tests
