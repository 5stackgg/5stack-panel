#!/bin/bash

# shellcheck source=tests/scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SECRET="admin-secret-1"

# A curl that answers the panel's GraphQL endpoint: the live worker url query
# with $LIVE_ANSWER (none when empty), and every settings write as taken,
# unless it is the setting named in $REFUSE. It keeps what it was asked: the
# call in $WORK_DIR/graphql, the body it sent in $WORK_DIR/graphql-body.
stub_curl() {
    mkdir -p "$WORK_DIR/bin"
    cat >"$WORK_DIR/bin/curl" <<'EOF'
#!/bin/bash
{
    echo "ARGS $*"
    if [[ " $* " == *" -K - "* ]]; then
        echo "CONFIG $(cat)"
    fi
} >>"$WORK_DIR/graphql"
body=""
while [ $# -gt 0 ]; do
    if [ "$1" = "--data" ]; then
        body="$2"
    fi
    shift
done
printf '%s\n' "$body" >>"$WORK_DIR/graphql-body"
if [[ "$(jq -r '.query' <<<"$body")" == query* ]]; then
    if [ -n "$LIVE_ANSWER" ]; then
        jq -nc --arg v "$LIVE_ANSWER" '{data: {settings_by_pk: {value: $v}}}'
    else
        echo '{"data":{"settings_by_pk":null}}'
    fi
elif [ "$(jq -r '.variables.name' <<<"$body")" = "$REFUSE" ]; then
    echo '{"errors":[{"message":"refused"}]}'
else
    echo '{"data":{"insert_settings":{"affected_rows":1}}}'
fi
EOF
    chmod +x "$WORK_DIR/bin/curl"
}

# Runs "$@" with utils/panel_settings.sh as backblaze-proxy.sh sources it, on a
# clock away from UTC. API_DOMAIN and HASURA_ADMIN_SECRET can be set empty.
panel() {
    stub_curl
    (
        export PATH="$WORK_DIR/bin:$PATH" TZ=America/New_York PANEL_DIR="$WORK_DIR/panel" WORKER_HOST=cf.example.test
        export API_DOMAIN="${API_DOMAIN-api.example.test}" HASURA_ADMIN_SECRET="${HASURA_ADMIN_SECRET-$SECRET}"
        # shellcheck source=utils/colors.sh
        source "$TEST_ROOT/utils/colors.sh"
        # shellcheck source=utils/cloudflare_workers.sh
        source "$TEST_ROOT/utils/cloudflare_workers.sh"
        # shellcheck source=utils/panel_settings.sh
        source "$TEST_ROOT/utils/panel_settings.sh"
        # shellcheck disable=SC2317,SC2329 # called by point_panel_at_worker
        update_env_var() { echo "update_env_var $*" >>"$WORK_DIR/calls"; }
        # shellcheck disable=SC2317,SC2329 # called by point_panel_at_worker
        offer_update() { echo "offer_update $WORKER_URL" >>"$WORK_DIR/calls"; }
        "$@"
    )
}

# The settings written, in order.
writes() {
    [ -f "$WORK_DIR/graphql-body" ] || return 0
    jq -r 'select(.query | startswith("mutation")) | .variables.name' "$WORK_DIR/graphql-body"
}

sent() {
    jq -c "select(.variables.name == \"$1\")" "$WORK_DIR/graphql-body"
}

calls() {
    cat "$WORK_DIR/calls" 2>/dev/null
}

# Hasura sends the api no event for the url written back unchanged, so a
# redeploy is told by its time alone.
test_a_redeploy_on_the_same_url_writes_only_the_deploy_time() {
    local out
    out="$(LIVE_ANSWER=https://cf.example.test CLOUDFLARE_WORKER_DOMAIN=cf.example.test panel point_panel_at_worker </dev/null 2>&1)" ||
        fail "the step failed: $out"

    assert_eq "$(writes)" "cloudflare_worker_deployed_at"
    assert_contains "$out" "The panel already serves files through https://cf.example.test"
    assert_not_contains "$out" "Switch it to"
    assert_not_contains "$out" "Could not tell the panel"
    assert_eq "$(calls)" ""
}

test_a_first_deploy_writes_the_url_then_the_deploy_time() {
    local out
    out="$(LIVE_ANSWER="" panel point_panel_at_worker </dev/null 2>&1)" || fail "the step failed: $out"

    assert_eq "$(writes | tr '\n' ' ')" "cloudflare_worker_url cloudflare_worker_deployed_at "
    assert_eq "$(sent cloudflare_worker_url | jq -r '.variables.value')" "https://cf.example.test"
    assert_eq "$(calls)" "update_env_var $WORK_DIR/panel/overlays/config/api-config.env CLOUDFLARE_WORKER_DOMAIN cf.example.test"
    assert_contains "$out" "The panel now serves demos, clips and media through https://cf.example.test"
}

test_a_declined_switch_still_writes_the_deploy_time() {
    local out
    out="$(LIVE_ANSWER=https://old.example.test panel point_panel_at_worker <<<"n" 2>&1)" || fail "the step failed: $out"

    assert_eq "$(writes)" "cloudflare_worker_deployed_at"
    assert_contains "$out" "Left it on https://old.example.test"
    assert_eq "$(calls)" ""
}

test_without_the_panel_s_api_nothing_is_sent_or_said_about_the_deploy() {
    local out
    out="$(API_DOMAIN="" LIVE_ANSWER="" panel point_panel_at_worker </dev/null 2>&1)" || fail "the step failed: $out"
    [ ! -f "$WORK_DIR/graphql" ] || fail "curl was called without API_DOMAIN: $(cat "$WORK_DIR/graphql")"
    assert_not_contains "$out" "Could not tell the panel"
    assert_contains "$(calls)" "offer_update https://cf.example.test"

    rm -f "$WORK_DIR/calls"
    out="$(HASURA_ADMIN_SECRET="" LIVE_ANSWER="" panel point_panel_at_worker </dev/null 2>&1)" || fail "the step failed: $out"
    [ ! -f "$WORK_DIR/graphql" ] || fail "curl was called without the admin secret: $(cat "$WORK_DIR/graphql")"
    assert_not_contains "$out" "Could not tell the panel"
    assert_contains "$(calls)" "offer_update https://cf.example.test"
}

test_a_refused_deploy_time_warns_and_carries_on() {
    local out status=0
    out="$(REFUSE=cloudflare_worker_deployed_at LIVE_ANSWER=https://cf.example.test CLOUDFLARE_WORKER_DOMAIN=cf.example.test \
        panel point_panel_at_worker </dev/null 2>&1)" || status=$?

    assert_eq "$status" "0"
    assert_contains "$out" "Could not tell the panel about this deploy. It checks the worker again when its API restarts."
}

test_the_deploy_time_is_utc_and_now() {
    local before after at seconds
    before="$(date -u +%s)"
    panel set_worker_deployed_at || fail "the write was taken but reported as failed"
    after="$(date -u +%s)"

    at="$(sent cloudflare_worker_deployed_at | jq -r '.variables.value')"
    [[ "$at" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] || fail "not a UTC ISO time: $at"
    seconds="$(node -p 'Math.floor(Date.parse(process.argv[1]) / 1000)' "$at")"
    if [ "$seconds" -lt "$before" ] || [ "$seconds" -gt "$after" ]; then
        fail "$at is not the time of the deploy"
    fi
    assert_contains "$(sent cloudflare_worker_deployed_at | jq -r '.query')" \
        "on_conflict: { constraint: settings_pkey, update_columns: [value] }"
}

test_the_admin_secret_only_travels_in_curl_s_config() {
    LIVE_ANSWER="" panel point_panel_at_worker </dev/null >/dev/null 2>&1 || fail "the step failed"

    assert_eq "$(grep -c '^ARGS ' "$WORK_DIR/graphql")" "3"
    if grep '^ARGS ' "$WORK_DIR/graphql" | grep -q "$SECRET"; then
        fail "the admin secret is on curl's command line"
    fi
    assert_eq "$(grep -c "^CONFIG header = \"x-hasura-admin-secret: $SECRET\"$" "$WORK_DIR/graphql")" "3"
    assert_eq "$(grep '^ARGS ' "$WORK_DIR/graphql" | grep -vc 'https://api.example.test/v1/graphql$')" "0"
}

test_a_write_the_panel_refuses_is_reported() {
    if REFUSE=cloudflare_worker_deployed_at panel set_worker_deployed_at; then
        fail "a refused write was reported as taken"
    fi
}

test_backblaze_proxy_points_the_panel_at_the_worker_once_it_answers() {
    local script live call
    script="$TEST_ROOT/backblaze-proxy.sh"
    live="$(grep -n 'ok "The Backblaze proxy is live' "$script" | cut -d: -f1)"
    call="$(grep -nE '^point_panel_at_worker$' "$script" | cut -d: -f1)"
    [ -n "$live" ] || fail "the step that waits for the worker to answer is gone"
    assert_eq "$(echo "$call" | wc -l | tr -d ' ')" "1"
    if [ -z "$call" ] || [ "$call" -le "$live" ]; then
        fail "the panel is pointed at the worker before it answers"
    fi
}

run_tests
