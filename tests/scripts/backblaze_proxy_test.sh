#!/bin/bash

# shellcheck source=tests/scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# A curl that answers the panel's GraphQL endpoint with $GRAPHQL_ANSWER and
# keeps what it was asked: the call in $WORK_DIR/graphql, the body it sent in
# $WORK_DIR/graphql-body.
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
while [ $# -gt 0 ]; do
    if [ "$1" = "--data" ]; then
        printf '%s\n' "$2" >>"$WORK_DIR/graphql-body"
    fi
    shift
done
printf '%s' "$GRAPHQL_ANSWER"
EOF
    chmod +x "$WORK_DIR/bin/curl"
}

settings() {
    (
        export PATH="$WORK_DIR/bin:$PATH" API_DOMAIN=api.example.gg HASURA_ADMIN_SECRET=admin-secret-1
        # shellcheck source=utils/colors.sh
        source "$TEST_ROOT/utils/colors.sh"
        # shellcheck source=utils/cloudflare_workers.sh
        source "$TEST_ROOT/utils/cloudflare_workers.sh"
        # shellcheck source=utils/panel_settings.sh
        source "$TEST_ROOT/utils/panel_settings.sh"
        "$@"
    )
}

sent() {
    cat "$WORK_DIR/graphql-body"
}

test_a_deploy_is_written_as_the_time_it_happened() {
    stub_curl
    export GRAPHQL_ANSWER='{"data":{"insert_settings":{"affected_rows":1}}}'
    local before after
    before="$(date -u +%s)"

    settings set_worker_deployed_at || fail "the write was taken but reported as failed"

    after="$(date -u +%s)"
    assert_contains "$(cat "$WORK_DIR/graphql")" "https://api.example.gg/v1/graphql"
    assert_contains "$(cat "$WORK_DIR/graphql")" 'CONFIG header = "x-hasura-admin-secret: admin-secret-1"'
    assert_eq "$(sent | jq -r '.variables.name')" "cloudflare_worker_deployed_at"
    assert_contains "$(sent | jq -r '.query')" "on_conflict: { constraint: settings_pkey, update_columns: [value] }"
    local at
    at="$(sent | jq -r '.variables.value')"
    [[ "$at" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] || fail "not a UTC ISO time: $at"
    local seconds
    seconds="$(node -p 'Math.floor(Date.parse(process.argv[1]) / 1000)' "$at")"
    [ "$seconds" -ge "$before" ] && [ "$seconds" -le "$after" ] || fail "$at is not the time of the deploy"
}

test_a_write_the_panel_refuses_is_reported() {
    stub_curl
    export GRAPHQL_ANSWER='{"errors":[{"message":"x-hasura-admin-secret/x-hasura-access-key required, but not found"}]}'

    if settings set_worker_deployed_at; then
        fail "a refused write was reported as taken"
    fi
}

test_the_worker_url_is_still_written_as_before() {
    stub_curl
    export GRAPHQL_ANSWER='{"data":{"insert_settings":{"affected_rows":1}}}'

    settings set_live_worker_url "https://cf.example.gg" || fail "the write was taken but reported as failed"

    assert_eq "$(sent | jq -r '.variables.name')" "cloudflare_worker_url"
    assert_eq "$(sent | jq -r '.variables.value')" "https://cf.example.gg"
}

# Hasura sends the api no event for the url written back unchanged, which a
# redeploy usually does, so every deploy that answers also writes its time,
# and a panel that can't be told doesn't fail the deploy: the api checks the
# worker again when it restarts.
test_every_deploy_that_answers_tells_the_panel_without_failing_on_it() {
    local script live call
    script="$TEST_ROOT/backblaze-proxy.sh"
    live="$(grep -n 'ok "The Backblaze proxy is live' "$script" | cut -d: -f1)"
    call="$(grep -n 'set_worker_deployed_at' "$script" | cut -d: -f1)"
    [ -n "$live" ] || fail "the step that waits for the worker to answer is gone"
    assert_eq "$(echo "$call" | wc -l | tr -d ' ')" "1"
    [ "$call" -gt "$live" ] || fail "the deploy is written before the worker answers"
    assert_contains "$(sed -n "${call}p" "$script")" "! set_worker_deployed_at; then"
    assert_contains "$(sed -n "$((call + 1))p" "$script")" "warn "
    # shellcheck disable=SC2016 # the line as written in the script
    assert_contains "$(cat "$script")" 'source "$PANEL_DIR/utils/panel_settings.sh"'
}

run_tests
