#!/bin/bash

# Manages the panel's hostnames on Cloudflare with CLOUDFLARE_API_TOKEN.
#
#   cloudflare_setup.sh plan [--json]           what each hostname gets; changes nothing
#   cloudflare_setup.sh records [--replace a,b] rules, then DNS records, proxied from the start
#   cloudflare_setup.sh proxy                   checks each proxied host, and puts one back to
#                                               DNS-only when Cloudflare or Let's Encrypt can't reach it
#   cloudflare_setup.sh origins                 changes nothing, unless Cloudflare can't reach a proxied
#                                               host: that one goes back to DNS-only
#   cloudflare_setup.sh status --json           records and settings against what setup left
#   cloudflare_setup.sh fix <host>              puts one record back
#   cloudflare_setup.sh tiered-cache            turns on Smart Tiered Cache
#   cloudflare_setup.sh stream-relay            the stream relay Worker on GAME_STREAM_DOMAIN
#
# Every hostname goes through Cloudflare except demo uploads (DEMOS_DOMAIN,
# over Cloudflare's 100 MB request limit), streams (GAME_STREAM_DOMAIN: the CDN
# terms keep video off the plain proxy) and TURN (UDP). The Worker hostname
# and hosts a Workers route answers are never touched. A proxied name must be
# the zone, one label below it, or covered by one of the zone's certificate
# packs: Cloudflare's free certificate covers nothing deeper. Nothing is
# proxied when HTTPS_PORT isn't 443. Certificates stay with cert-manager's
# HTTP-01 check, so plain HTTP on /.well-known/acme-challenge/ must reach the
# panel: Always Use HTTPS goes off and a redirect rule sends everything else to
# HTTPS. Behind the operator's own reverse proxy (REVERSE_PROXY=true) the panel
# issues no certificates, so none of that is set up or checked, and a host goes
# back to DNS-only only when Cloudflare can't reach the origin. With
# CLOUDFLARE_ZONE set, only that zone is used.

CF_SETUP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
: "${PANEL_DIR:=$(cd "$CF_SETUP_DIR/.." && pwd)}"
# shellcheck source=utils/colors.sh
source "$CF_SETUP_DIR/colors.sh"
# shellcheck source=utils/cloudflare_api.sh
source "$CF_SETUP_DIR/cloudflare_api.sh"

CF_COMMENT="5stack-panel (managed by update.sh)"
CF_CONFIG_REF="5stack_panel"
CF_CACHE_REF="5stack_panel_no_cache"
CF_REDIRECT_REF="5stack_panel_https"
CF_ACME_REF="5stack_panel_acme"
CF_ACME_PATH="/.well-known/acme-challenge/"
CF_ACME_CHECK="/.well-known/acme-challenge/5stack-check"
CF_PROXIED_KEYS="WEB_DOMAIN API_DOMAIN WS_DOMAIN TYPESENSE_HOST RELAY_DOMAIN S3_CONSOLE_HOST"
CF_DIRECT_KEYS="DEMOS_DOMAIN GAME_STREAM_DOMAIN TURN_DOMAIN"
CF_NO_CACHE_KEYS="API_DOMAIN WS_DOMAIN TYPESENSE_HOST RELAY_DOMAIN GAME_STREAM_DOMAIN"
CF_RELAY_WORKER="5stack-stream-relay"
: "${CF_RELAY_WAIT:=12}"
: "${CF_RELAY_PAUSE:=5}"
: "${CF_TRACE_URL:=https://1.1.1.1/cdn-cgi/trace}"
: "${CF_DOH_URL:=https://1.1.1.1/dns-query}"
: "${CF_PROBE_WAIT:=12}"
: "${CF_PROBE_PAUSE:=5}"
: "${CLOUDFLARE_ORIGIN_IPV6:=}"

cf_env_value() {
    local file="$1" key="$2"
    grep -hs "^$key=" "$file" | tail -n 1 | cut -d= -f2- | tr -d '\r"'
}

cf_load_hosts() {
    local config="$PANEL_DIR/overlays/config" key value
    for key in WEB_DOMAIN API_DOMAIN WS_DOMAIN RELAY_DOMAIN DEMOS_DOMAIN GAME_STREAM_DOMAIN CLOUDFLARE_WORKER_DOMAIN; do
        if [ -z "${!key}" ]; then
            value="$(cf_env_value "$config/api-config.env" "$key")"
            printf -v "$key" '%s' "$value"
        fi
    done
    [ -n "$S3_CONSOLE_HOST" ] || S3_CONSOLE_HOST="$(cf_env_value "$config/s3-config.env" S3_CONSOLE_HOST)"
    [ -n "$TYPESENSE_HOST" ] || TYPESENSE_HOST="$(cf_env_value "$config/typesense-config.env" TYPESENSE_HOST)"
    [ -n "$TURN_DOMAIN" ] || TURN_DOMAIN="$(cf_env_value "$PANEL_DIR/overlays/coturn/coturn.env" TURN_DOMAIN)"
    [ -n "$HTTPS_PORT" ] || HTTPS_PORT="$(cf_env_value "$config/traefik-config.env" HTTPS_PORT)"
    [ -n "$REVERSE_PROXY" ] || REVERSE_PROXY="$(cf_env_value "$PANEL_DIR/.5stack-env.config" REVERSE_PROXY)"
}

cf_reverse_proxy() {
    [ "$REVERSE_PROXY" = true ]
}

cf_load_token() {
    if [ -n "$CLOUDFLARE_API_TOKEN" ]; then
        return 0
    fi
    CLOUDFLARE_API_TOKEN="$(cf_env_value "$PANEL_DIR/overlays/local-secrets/cloudflare-secrets.env" CLOUDFLARE_API_TOKEN)"
    if [ "$CLOUDFLARE_API_TOKEN" = VAULT ] || { [ -z "$CLOUDFLARE_API_TOKEN" ] && [ "$VAULT_MANAGER" = true ]; }; then
        CLOUDFLARE_API_TOKEN=""
        if command -v vault >/dev/null 2>&1; then
            CLOUDFLARE_API_TOKEN="$(vault kv get -field=CLOUDFLARE_API_TOKEN kv/cloudflare 2>/dev/null)"
        fi
    fi
    [ -n "$CLOUDFLARE_API_TOKEN" ]
}

cf_lower() {
    tr '[:upper:]' '[:lower:]' <<<"$1"
}

cf_zone() {
    local host candidate response
    host="$(cf_lower "$1")"
    candidate="$host"
    while [[ "$candidate" == *.* ]]; do
        if [ -z "$CLOUDFLARE_ZONE" ] || [ "$candidate" = "$(cf_lower "$CLOUDFLARE_ZONE")" ]; then
            response="$(cfa GET "/zones?name=$candidate&status=active")" || return 1
            if jq -e '.result | length > 0' >/dev/null 2>&1 <<<"$response"; then
                jq -r '.result[0] | "\(.id) \(.name) \(.plan.name // "unknown")"' <<<"$response"
                return 0
            fi
        fi
        candidate="${candidate#*.}"
    done
    return 1
}

cf_covered() {
    local host="$1" zone="$2" zone_id="$3" rel packs
    if [ "$host" = "$zone" ]; then
        return 0
    fi
    rel="${host%".$zone"}"
    if [[ "$rel" != *.* ]]; then
        return 0
    fi
    packs="$(cfa GET "/zones/$zone_id/ssl/certificate_packs?status=all")" || return 1
    jq -e --arg h "$host" '
        [.result[]? | select(.status == "active") | .hosts[]?] as $names
        | ($h | split(".")[1:] | join(".")) as $parent
        | any($names[]; . == $h or . == ("*." + $parent))
    ' >/dev/null 2>&1 <<<"$packs"
}

cf_worker_routed() {
    local host="$1" zone_id="$2" routes
    routes="$(cfa GET "/zones/$zone_id/workers/routes")"
    if ! cfa_ok <<<"$routes"; then
        echo routes
        return 0
    fi
    jq -e --arg h "$host" 'any(.result[]?; (.pattern | split("/")[0]) == $h)' >/dev/null 2>&1 <<<"$routes" && echo worker
}

cf_keyed_hosts() {
    local key
    for key in $CF_PROXIED_KEYS $CF_DIRECT_KEYS; do
        if [ -n "${!key}" ]; then
            printf '%s %s\n' "$key" "$(cf_lower "${!key}")"
        fi
    done | awk '!seen[$2]++'
}

cf_plan() {
    local key host zone zone_id zone_name proxied why routed
    while read -r key host; do
        if [ -n "$CLOUDFLARE_WORKER_DOMAIN" ] && [ "$host" = "$(cf_lower "$CLOUDFLARE_WORKER_DOMAIN")" ]; then
            continue
        fi
        if ! zone="$(cf_zone "$host")"; then
            printf '%s %s - - skip %s\n' "$key" "$host" "not_in_account"
            continue
        fi
        read -r zone_id zone_name _ <<<"$zone"
        proxied=yes
        why=-
        if [[ " $CF_DIRECT_KEYS " == *" $key "* ]]; then
            proxied=no
            case "$key" in
                TURN_DOMAIN) why=udp ;;
                GAME_STREAM_DOMAIN) why=video ;;
                *) why=uploads ;;
            esac
        elif [ -n "$HTTPS_PORT" ] && [ "$HTTPS_PORT" != 443 ]; then
            proxied=no
            why=port
        elif ! cf_covered "$host" "$zone_name" "$zone_id"; then
            proxied=no
            why=depth
        fi
        routed="$(cf_worker_routed "$host" "$zone_id")"
        if [ -n "$routed" ]; then
            proxied=skip
            why="$routed"
        fi
        printf '%s %s %s %s %s %s\n' "$key" "$host" "$zone_id" "$zone_name" "$proxied" "$why"
    done < <(cf_keyed_hosts)
}

cf_public_ip() {
    if [ -n "$CLOUDFLARE_ORIGIN_IPV4" ]; then
        return 0
    fi
    CLOUDFLARE_ORIGIN_IPV4="$(curl -sS --max-time 10 "$CF_TRACE_URL" | sed -n 's/^ip=//p' | tr -d '\r')"
    [ -n "$CLOUDFLARE_ORIGIN_IPV4" ]
}

cf_private_ip() {
    local ip="$1" a b
    IFS=. read -r a b _ _ <<<"$ip"
    [ "$a" = 10 ] || [ "$a" = 127 ] || [ "$a" = 0 ] ||
        { [ "$a" = 172 ] && [ "$b" -ge 16 ] && [ "$b" -le 31 ]; } ||
        { [ "$a" = 192 ] && [ "$b" = 168 ]; } ||
        { [ "$a" = 169 ] && [ "$b" = 254 ]; } ||
        { [ "$a" = 100 ] && [ "$b" -ge 64 ] && [ "$b" -le 127 ]; }
}

cf_check() {
    local zone_id zone_name ids response probe phase phases
    zone_id=""
    phases="http_config_settings http_request_cache_settings http_request_dynamic_redirect"
    if cf_reverse_proxy; then
        phases="http_config_settings http_request_cache_settings"
    fi
    ids="$(cf_plan | awk '$3 != "-" { print $3 " " $4 }' | sort -u)"
    if [ -z "$ids" ]; then
        echo "zone: none of the panel's hostnames is in a zone this token can read"
        return
    fi
    while read -r zone_id zone_name; do
        response="$(cfa POST "/zones/$zone_id/dns_records" "$(jq -nc --arg n "_5stack-check.$zone_name" '{type: "TXT", name: $n, content: "\"5stack\"", ttl: 60}')")"
        if probe="$(jq -er '.result.id' 2>/dev/null <<<"$response")"; then
            cfa DELETE "/zones/$zone_id/dns_records/$probe" >/dev/null
        else
            echo "dns_edit: $zone_name: $(cfa_errors <<<"$response")"
        fi
        cfa GET "/zones/$zone_id/settings/websockets" | jq -e '.result.value == "on"' >/dev/null 2>&1 ||
            echo "websockets: $zone_name has WebSockets off, so live updates can't connect. Turn it on under Network."
        response="$(cfa GET "/zones/$zone_id/bot_management")"
        if ! cfa_ok <<<"$response"; then
            echo "bot_read: $zone_name: $(cfa_errors <<<"$response")"
        elif jq -e '.result.fight_mode == true' >/dev/null 2>&1 <<<"$response"; then
            echo "bot_fight: $zone_name has Bot Fight Mode on, which blocks game servers talking to the panel. Turn it off under Security, Bots."
        fi
        cfa GET "/zones/$zone_id/ssl/universal/settings" | jq -e '.result.enabled != false' >/dev/null 2>&1 ||
            echo "universal_ssl: $zone_name has Universal SSL off, so Cloudflare has no certificate for the proxied names."
        for phase in $phases; do
            response="$(cfa GET "/zones/$zone_id/rulesets/phases/$phase/entrypoint")"
            if ! cfa_ok <<<"$response" && ! jq -e 'any(.errors[]?; .code == 10003)' >/dev/null 2>&1 <<<"$response"; then
                if [ "$phase" = http_request_dynamic_redirect ]; then
                    echo "redirect_rules: The Cloudflare key can't manage Redirect Rules for $zone_name, which keep Let's Encrypt's check reaching this server. Connect Cloudflare again, or make a new key with ./cloudflare.sh."
                else
                    echo "rules: $zone_name: $phase: $(cfa_errors <<<"$response")"
                fi
            fi
        done
    done <<<"$ids"
}

cf_records_json() {
    local zone_id="$1" host="$2"
    cfa GET "/zones/$zone_id/dns_records?name=$host&per_page=100" |
        jq -c '[.result[]? | select(.type == "A" or .type == "AAAA" or .type == "CNAME")]'
}

cf_record_body() {
    local type="$1" host="$2" content="$3" proxied="$4"
    jq -nc --arg t "$type" --arg n "$host" --arg c "$content" --argjson p "$proxied" --arg m "$CF_COMMENT" \
        '{type: $t, name: $n, content: $c, proxied: $p, ttl: 1, comment: $m}'
}

cf_sync_host() {
    local zone_id="$1" host="$2" want="$3" replace="$4" records foreign type content id proxied current
    records="$(cf_records_json "$zone_id" "$host")"
    foreign="$(jq -c --arg m "$CF_COMMENT" '[.[] | select(.comment != $m)]' <<<"$records")"
    if [ "$(jq length <<<"$foreign")" -gt 0 ]; then
        if [ "$replace" != true ]; then
            jq -r --arg h "$host" '.[] | "conflict: \($h) \(.type) \(.content)\(if .proxied then " proxied" else "" end)"' <<<"$foreign"
            return 0
        fi
        for id in $(jq -r '.[].id' <<<"$foreign"); do
            cfa DELETE "/zones/$zone_id/dns_records/$id" | cfa_ok || {
                err "Could not remove a record for $host"
                return 1
            }
        done
    fi
    for type in A AAAA; do
        content="$CLOUDFLARE_ORIGIN_IPV4"
        if [ "$type" = AAAA ]; then
            content="$CLOUDFLARE_ORIGIN_IPV6"
        fi
        current="$(jq -c --arg t "$type" --arg m "$CF_COMMENT" '[.[] | select(.type == $t and .comment == $m)][0] // empty' <<<"$records")"
        if [ -z "$content" ]; then
            if [ -n "$current" ]; then
                cfa DELETE "/zones/$zone_id/dns_records/$(jq -r .id <<<"$current")" >/dev/null
            fi
            continue
        fi
        proxied="$want"
        if [ "$want" = keep ]; then
            proxied="$(jq -r 'if . == null then false else (.proxied // false) end' <<<"${current:-null}")"
        fi
        if [ -z "$current" ]; then
            cfa POST "/zones/$zone_id/dns_records" "$(cf_record_body "$type" "$host" "$content" "$proxied")" | cfa_ok || {
                err "Could not add the $type record for $host"
                return 1
            }
        elif [ "$(jq -r '"\(.content) \(.proxied)"' <<<"$current")" != "$content $proxied" ]; then
            cfa PATCH "/zones/$zone_id/dns_records/$(jq -r .id <<<"$current")" "$(cf_record_body "$type" "$host" "$content" "$proxied")" | cfa_ok || {
                err "Could not update the $type record for $host"
                return 1
            }
        fi
    done
}

cf_caa_warning() {
    local zone_id="$1" zone_name="$2"
    cfa GET "/zones/$zone_id/dns_records?type=CAA&name=$zone_name" |
        jq -e '(.result | length > 0) and (all(.result[]; (.content | ascii_downcase | contains("letsencrypt.org")) | not))' >/dev/null 2>&1 &&
        warn "$zone_name has CAA records without letsencrypt.org, so Let's Encrypt can't issue the panel's certificates."
}

cf_in_list() {
    [[ ",$2," == *",$1,"* ]]
}

cf_records() {
    local replace_list="$1" key host zone_id zone_name proxied why want orange=keep note plan conflicts="" out
    cf_public_ip || {
        err "Could not find this server's public IP. Set CLOUDFLARE_ORIGIN_IPV4."
        return 1
    }
    if cf_private_ip "$CLOUDFLARE_ORIGIN_IPV4"; then
        err "$CLOUDFLARE_ORIGIN_IPV4 is a private address, so Cloudflare can't reach this server there."
        return 1
    fi
    plan="$(cf_plan)"
    if awk '$5 == "yes" { found = 1 } END { exit !found }' <<<"$plan"; then
        if cf_ready && cf_rules; then
            orange=true
        else
            warn "The panel's Cloudflare rules aren't in place, so its hostnames don't go through Cloudflare yet."
        fi
    fi
    while read -r key host zone_id zone_name proxied why; do
        if [ -z "$host" ] || [ "$proxied" = skip ]; then
            continue
        fi
        want="$orange"
        if [ "$proxied" = no ]; then
            want=false
        fi
        out="$(cf_sync_host "$zone_id" "$host" "$want" "$(cf_in_list "$host" "$replace_list" && echo true || echo false)")" || return 1
        if [ -n "$out" ]; then
            conflicts+="$out"$'\n'
        else
            case "$want" in
                true) note=" (through Cloudflare)" ;;
                false) note=" (straight to this server)" ;;
                *) note="" ;;
            esac
            ok "$host → $CLOUDFLARE_ORIGIN_IPV4$note"
        fi
    done <<<"$plan"
    while read -r zone_id zone_name; do
        cf_caa_warning "$zone_id" "$zone_name"
    done < <(awk 'NF && $3 != "-" { print $3 " " $4 }' <<<"$plan" | sort -u)
    if [ -n "$conflicts" ]; then
        printf '%s' "$conflicts"
        warn "These records are not 5Stack's, so they were left alone. Run again with --replace and their names to replace them."
        return 2
    fi
}

cf_host_expression() {
    jq -rn --args '"(http.host in {\($ARGS.positional | map("\"" + . + "\"") | join(" "))})"' "$@"
}

cf_rule() {
    local zone_id="$1" phase="$2" ref="$3" description="$4" action="$5" params="$6" expression="$7" response rule ruleset_id rule_id
    rule="$(jq -nc --arg ref "$ref" --arg d "$description" --arg a "$action" --argjson p "$params" --arg e "$expression" \
        '{ref: $ref, description: $d, expression: $e, action: $a, action_parameters: $p, enabled: true}')"
    response="$(cfa GET "/zones/$zone_id/rulesets/phases/$phase/entrypoint")"
    if ! cfa_ok <<<"$response"; then
        cfa PUT "/zones/$zone_id/rulesets/phases/$phase/entrypoint" "$(jq -nc --argjson r "$rule" '{rules: [$r]}')" | cfa_ok
        return
    fi
    ruleset_id="$(jq -r '.result.id' <<<"$response")"
    rule_id="$(jq -r --arg ref "$ref" '[.result.rules[]? | select(.ref == $ref)][0].id // empty' <<<"$response")"
    if [ -n "$rule_id" ]; then
        cfa PATCH "/zones/$zone_id/rulesets/$ruleset_id/rules/$rule_id" "$rule" | cfa_ok
    else
        cfa POST "/zones/$zone_id/rulesets/$ruleset_id/rules" "$rule" | cfa_ok
    fi
}

cf_acme_expression() {
    printf '%s and starts_with(http.request.uri.path, "%s")' "$(cf_host_expression "$@")" "$CF_ACME_PATH"
}

cf_https_expression() {
    printf '(not ssl and not starts_with(http.request.uri.path, "%s"))' "$CF_ACME_PATH"
}

cf_https() {
    local zone_id="$1" wide=false expression params
    shift
    if cfa GET "/zones/$zone_id/settings/always_use_https" | jq -e '.result.value == "on"' >/dev/null 2>&1; then
        wide=true
    fi
    if cfa GET "/zones/$zone_id/rulesets/phases/http_request_dynamic_redirect/entrypoint" |
        jq -e --arg ref "$CF_REDIRECT_REF" 'any(.result.rules[]?; .ref == $ref and (.expression | startswith("(http.host in") | not))' >/dev/null 2>&1; then
        wide=true
    fi
    expression="$(cf_https_expression)"
    if [ "$wide" != true ]; then
        expression="$(cf_host_expression "$@") and $expression"
    fi
    params='{"from_value": {"status_code": 301, "target_url": {"expression": "concat(\"https://\", http.host, http.request.uri.path)"}, "preserve_query_string": true}}'
    cf_rule "$zone_id" http_request_dynamic_redirect "$CF_REDIRECT_REF" "5Stack panel: HTTPS, except Let's Encrypt's check" redirect "$params" "$expression" || {
        err "Could not save the 5Stack rule that sends plain HTTP to HTTPS"
        return 1
    }
    if [ "$wide" = true ]; then
        cfa PATCH "/zones/$zone_id/settings/always_use_https" '{"value": "off"}' | cfa_ok || {
            err "Could not turn off Always Use HTTPS, which sends Let's Encrypt's check to HTTPS"
            return 1
        }
    fi
}

cf_challenge_blockers() {
    local zone_id="$1" response target pattern host rule
    shift
    response="$(cfa GET "/zones/$zone_id/rulesets/phases/http_request_dynamic_redirect/entrypoint")"
    if cfa_ok <<<"$response"; then
        while read -r rule; do
            echo "redirect_rule: The Redirect Rule \"$rule\" can send Let's Encrypt's check to HTTPS. Leave $CF_ACME_PATH out of it."
        done < <(jq -r --arg ref "$CF_REDIRECT_REF" --argjson hosts "$(jq -nc '$ARGS.positional' --args "$@")" '
            .result.rules[]?
            | select(.ref != $ref and .enabled != false and .action == "redirect")
            | select(.expression | contains("acme-challenge") | not)
            | . as $r
            | select(($r.expression | contains("http.host") | not) or any($hosts[]; . as $h | $r.expression | contains("\"" + $h + "\"")))
            | .description // .ref // .id' <<<"$response")
    fi
    response="$(cfa GET "/zones/$zone_id/pagerules?status=active")"
    cfa_ok <<<"$response" || return 0
    while IFS=$'\t' read -r rule target; do
        [ -n "$target" ] || continue
        if [[ "$target" == https://* ]]; then
            continue
        fi
        pattern="${target#http://}"
        pattern="${pattern%%/*}"
        pattern="${pattern//./\\.}"
        pattern="^${pattern//\*/.*}$"
        for host in "$@"; do
            if [[ "$host" =~ $pattern ]]; then
                echo "page_rule: The Page Rule for $target ($rule) sends Let's Encrypt's check to HTTPS, and a Page Rule can't leave one path out. Replace it with a Redirect Rule that leaves $CF_ACME_PATH out."
                break
            fi
        done
    done < <(jq -r '.result[]? | select(any(.actions[]?; .id == "always_use_https" or .id == "forwarding_url")) | [([.actions[].id] | join(",")), (.targets[0].constraint.value // "")] | @tsv' <<<"$response")
}

cf_edge_ip() {
    curl -sS --max-time 10 -H 'accept: application/dns-json' "$CF_DOH_URL?name=$1&type=A" 2>/dev/null |
        jq -r --arg o "$CLOUDFLARE_ORIGIN_IPV4" '[.Answer[]? | select(.type == 1 and .data != $o) | .data][0] // empty' 2>/dev/null
}

cf_acme_probe() {
    local host="$1" edge headers code args
    args=(-sS -o /dev/null -D - --max-time 20)
    edge="$(cf_edge_ip "$host")"
    if [ -n "$edge" ]; then
        args+=(--resolve "$host:80:$edge")
    fi
    headers="$(curl "${args[@]}" "http://$host$CF_ACME_CHECK" 2>/dev/null | tr -d '\r' | tr '[:upper:]' '[:lower:]')"
    code="$(awk 'NR == 1 { print $2 }' <<<"$headers")"
    if grep -q '^x-5stack-check:' <<<"$headers"; then
        if grep -q '^cf-ray:' <<<"$headers"; then
            echo ok
        else
            echo direct
        fi
        return
    fi
    case "$code" in
        "") echo none ;;
        52[0-6] | 530) echo "unreachable $code" ;;
        3[0-9][0-9]) echo "redirect $code $(sed -n 's/^location: *//p' <<<"$headers" | head -n 1)" ;;
        *)
            if grep -q '^cf-mitigated:' <<<"$headers" || { [[ "$code" =~ ^(403|429|503)$ ]] && grep -q '^server: cloudflare' <<<"$headers"; }; then
                echo "challenge $code"
            else
                echo "other $code"
            fi
            ;;
    esac
}

cf_acme_blocked() {
    local host="$1" i result
    for ((i = 0; i < CF_PROBE_WAIT; i++)); do
        result="$(cf_acme_probe "$host")"
        case "$result" in
            ok) return 1 ;;
            redirect*)
                echo "Cloudflare redirects http://$host$CF_ACME_CHECK to ${result#redirect * }"
                return 0
                ;;
            challenge*)
                echo "Cloudflare answers http://$host$CF_ACME_CHECK with a security challenge"
                return 0
                ;;
            unreachable*)
                echo "Cloudflare can't reach this server for http://$host$CF_ACME_CHECK (HTTP ${result#unreachable })"
                return 0
                ;;
            other*)
                echo "http://$host$CF_ACME_CHECK answers HTTP ${result#other } instead of the panel"
                return 0
                ;;
        esac
        sleep "$CF_PROBE_PAUSE"
    done
    warn "http://$host$CF_ACME_CHECK didn't answer through Cloudflare yet, so Let's Encrypt's path wasn't checked. The next update checks it again." >&2
    return 1
}

cf_origin_status() {
    local host="$1"
    curl -s -o /dev/null --max-time 20 -w '%{http_code}' "https://$host/"
}

cf_ready() {
    local problems line
    problems="$(cf_check)"
    if [ -n "$problems" ]; then
        err "Cloudflare isn't ready for the panel:"
        while read -r line; do
            err "${line#*: }"
        done <<<"$problems"
        return 1
    fi
}

cf_ruled() {
    awk '$5 == "yes" || ($1 == "GAME_STREAM_DOMAIN" && $6 == "worker")'
}

cf_rules() {
    local key host zone_id zone_name proxied why zone hosts nocache
    for zone in $(cf_plan | cf_ruled | awk '{ print $3 }' | sort -u); do
        hosts=()
        nocache=()
        while read -r key host zone_id zone_name proxied why; do
            hosts+=("$host")
            if [[ " $CF_NO_CACHE_KEYS " == *" $key "* ]]; then
                nocache+=("$host")
            fi
        done < <(cf_plan | cf_ruled | awk -v z="$zone" '$3 == z')
        cf_rule "$zone" http_config_settings "$CF_CONFIG_REF" "5Stack panel" set_config \
            '{"ssl": "strict", "rocket_loader": false, "email_obfuscation": false, "disable_zaraz": true, "bic": false}' "$(cf_host_expression "${hosts[@]}")" || {
            err "Could not save the 5Stack configuration rule"
            return 1
        }
        if ! cf_reverse_proxy; then
            cf_rule "$zone" http_config_settings "$CF_ACME_REF" "5Stack panel: Let's Encrypt's check" set_config \
                '{"security_level": "essentially_off", "bic": false}' "$(cf_acme_expression "${hosts[@]}")" || {
                err "Could not save the 5Stack rule that keeps challenges off Let's Encrypt's check"
                return 1
            }
        fi
        if [ "${#nocache[@]}" -gt 0 ]; then
            cf_rule "$zone" http_request_cache_settings "$CF_CACHE_REF" "5Stack panel: live data" set_cache_settings \
                '{"cache": false}' "$(cf_host_expression "${nocache[@]}")" || {
                err "Could not save the 5Stack cache rule"
                return 1
            }
        fi
        if ! cf_reverse_proxy; then
            cf_https "$zone" "${hosts[@]}" || return 1
        fi
    done
}

cf_zone_blockers() {
    local hosts
    if cf_reverse_proxy; then
        return 0
    fi
    mapfile -t hosts < <(cf_plan | cf_ruled | awk -v z="$1" '$3 == z { print $2 }')
    cf_challenge_blockers "$1" "${hosts[@]}"
}

cf_blockers() {
    local zone
    for zone in $(cf_plan | cf_ruled | awk '{ print $3 }' | sort -u); do
        cf_zone_blockers "$zone"
    done
}

cf_proxy() {
    local key host zone_id zone_name proxied why status code blocked line
    cf_ready || return 1
    cf_public_ip || return 1
    cf_rules || return 1
    while read -r line; do
        [ -n "$line" ] && warn "${line#*: }"
    done < <(cf_blockers)
    status=0
    while read -r key host zone_id zone_name proxied why; do
        [ "$proxied" = yes ] || continue
        cf_sync_host "$zone_id" "$host" true false >/dev/null || return 1
        code="$(cf_origin_status "$host")"
        case "$code" in
            52[0-6] | 530)
                warn "Cloudflare can't reach the panel on $host (HTTP $code), so it goes straight to this server again."
                cf_sync_host "$zone_id" "$host" false false >/dev/null
                status=3
                continue
                ;;
        esac
        if ! cf_reverse_proxy && blocked="$(cf_acme_blocked "$host")"; then
            warn "Let's Encrypt can't reach $host through Cloudflare: $blocked. It goes straight to this server again, so its certificate keeps renewing."
            cf_sync_host "$zone_id" "$host" false false >/dev/null
            status=3
            continue
        fi
        ok "$host through Cloudflare"
    done < <(cf_plan)
    return "$status"
}

cf_origins() {
    local key host zone_id zone_name proxied why code status=0
    cf_public_ip || return 1
    while read -r key host zone_id zone_name proxied why; do
        [ "$proxied" = yes ] || continue
        code="$(cf_origin_status "$host")"
        case "$code" in
            52[0-6] | 530)
                warn "Cloudflare can't reach the panel on $host (HTTP $code), so it goes straight to this server again."
                cf_sync_host "$zone_id" "$host" false false >/dev/null
                status=3
                ;;
        esac
    done < <(cf_plan)
    return "$status"
}

cf_status_json() {
    local key host zone_id zone_name proxied why records zones
    cf_public_ip
    zones="$(cf_plan | awk '$3 != "-" { print $3 " " $4 }' | sort -u)"
    {
        while read -r key host zone_id zone_name proxied why; do
            if [ "$zone_id" = - ]; then
                jq -nc --arg k "$key" --arg h "$host" '{key: $k, host: $h, state: "not_in_account"}'
                continue
            fi
            records="$(cf_records_json "$zone_id" "$host")"
            jq -nc --arg k "$key" --arg h "$host" --arg p "$proxied" --arg w "$why" --arg ip "$CLOUDFLARE_ORIGIN_IPV4" --arg m "$CF_COMMENT" --argjson r "$records" '
                ([$r[] | select(.type == "A")][0]) as $a
                | {key: $k, host: $h, want_proxied: ($p == "yes"), why: $w, ip: $ip,
                   content: ($a.content // null), proxied: ($a.proxied // null), modified: ($a.modified_on // null),
                   managed: (($a.comment // "") == $m),
                   state: (if $p == "skip" then "skipped"
                           elif $a == null then "missing"
                           elif $a.content != $ip then "elsewhere"
                           elif ($p == "yes") != ($a.proxied // false) then "cloud"
                           else "ok" end)}'
        done < <(cf_plan)
    } | jq -sc --argjson zones "$(while read -r zone_id zone_name; do
        [ -n "$zone_id" ] || continue
        jq -nc --arg id "$zone_id" --arg name "$zone_name" \
            --argjson ws "$(cfa GET "/zones/$zone_id/settings/websockets" | jq -c '.result.value // null')" \
            --argjson bot "$(cfa GET "/zones/$zone_id/bot_management" | jq -c '.result | if type == "object" and has("fight_mode") then .fight_mode else null end')" \
            --argjson tiered "$(cfa GET "/zones/$zone_id/cache/tiered_cache_smart_topology_enable" | jq -c '.result.value // null')" \
            --argjson rule "$(cfa GET "/zones/$zone_id/rulesets/phases/http_config_settings/entrypoint" | jq -c --arg ref "$CF_CONFIG_REF" '[.result.rules[]? | select(.ref == $ref)][0].action_parameters.ssl // null')" \
            --argjson always "$(cfa GET "/zones/$zone_id/settings/always_use_https" | jq -c '.result.value // null')" \
            --argjson redirect "$(cfa GET "/zones/$zone_id/rulesets/phases/http_request_dynamic_redirect/entrypoint" | jq -c --arg ref "$CF_REDIRECT_REF" --arg p "$CF_ACME_PATH" '[.result.rules[]? | select(.ref == $ref and .enabled != false and (.expression | contains("not starts_with(http.request.uri.path, \"" + $p + "\")")))] | length > 0')" \
            --argjson blockers "$(cf_zone_blockers "$zone_id" | sed 's/^[a-z_]*: //' | jq -Rsc 'split("\n") | map(select(length > 0))')" \
            '{id: $id, name: $name, websockets: $ws, bot_fight: $bot, tiered_cache: $tiered, ssl: $rule, always_https: $always, https_rule: $redirect, blockers: $blockers}'
    done <<<"$zones" | jq -sc .)" '{zones: $zones, hosts: .}'
}

cf_fix() {
    local target key host zone_id zone_name proxied why
    target="$(cf_lower "$1")"
    cf_public_ip || return 1
    while read -r key host zone_id zone_name proxied why; do
        if [ "$host" = "$target" ] && [ "$proxied" != skip ]; then
            cf_sync_host "$zone_id" "$host" "$([ "$proxied" = yes ] && echo true || echo false)" true
            return
        fi
    done < <(cf_plan)
    err "$target isn't one of the panel's hostnames on Cloudflare."
    return 1
}

cf_tiered_cache() {
    local zone
    for zone in $(cf_plan | awk '$5 == "yes" { print $3 }' | sort -u); do
        cfa PATCH "/zones/$zone/argo/tiered_caching" '{"value": "on"}' | cfa_ok || return 1
        cfa PATCH "/zones/$zone/cache/tiered_cache_smart_topology_enable" '{"value": "on"}' | cfa_ok || return 1
    done
}

cf_upload_worker() {
    local account="$1" dir response
    dir="$(mktemp -d)"
    jq -nc --arg web "https://$(cf_lower "$WEB_DOMAIN")" \
        '{main_module: "worker.js", compatibility_date: "2025-04-29", bindings: [{type: "plain_text", name: "WEB_ORIGIN", text: $web}]}' >"$dir/metadata.json"
    response="$(printf 'header = "Authorization: Bearer %s"\n' "$CLOUDFLARE_API_TOKEN" |
        curl -K - -sS --max-time 60 -X PUT \
            -F "metadata=<$dir/metadata.json;type=application/json" \
            -F "worker.js=@$CF_SETUP_DIR/../cloudflare-workers/stream-relay/worker.js;type=application/javascript+module" \
            "$CLOUDFLARE_API/accounts/$account/workers/scripts/$CF_RELAY_WORKER")"
    rm -rf "$dir"
    if ! cfa_ok <<<"$response"; then
        err "Cloudflare refused the stream relay Worker: $(cfa_errors <<<"$response")"
        return 1
    fi
}

cf_relay_route() {
    local zone_id="$1" pattern="$2" routes id owner body response
    routes="$(cfa GET "/zones/$zone_id/workers/routes")"
    cfa_ok <<<"$routes" || {
        err "Could not read the zone's Worker routes: $(cfa_errors <<<"$routes")"
        return 1
    }
    id="$(jq -r --arg p "$pattern" '[.result[]? | select(.pattern == $p)][0].id // empty' <<<"$routes")"
    owner="$(jq -r --arg p "$pattern" '[.result[]? | select(.pattern == $p)][0].script // empty' <<<"$routes")"
    if [ -n "$owner" ] && [ "$owner" != "$CF_RELAY_WORKER" ]; then
        err "The route $pattern already sends requests to the Worker \"$owner\". Remove it in Cloudflare first."
        return 1
    fi
    body="$(jq -nc --arg p "$pattern" --arg s "$CF_RELAY_WORKER" '{pattern: $p, script: $s, request_limit_fail_open: false}')"
    if [ -z "$id" ]; then
        response="$(cfa POST "/zones/$zone_id/workers/routes" "$body")"
    else
        response="$(cfa PUT "/zones/$zone_id/workers/routes/$id" "$body")"
    fi
    cfa_ok <<<"$response" || {
        err "Could not route $pattern to the stream relay Worker: $(cfa_errors <<<"$response")"
        return 1
    }
}

cf_relay_answers() {
    local host="$1" i
    for ((i = 0; i < CF_RELAY_WAIT; i++)); do
        if curl -fsS --max-time 10 "https://$host/health" 2>/dev/null | grep -q "\"worker\":\"$CF_RELAY_WORKER\""; then
            return 0
        fi
        sleep "$CF_RELAY_PAUSE"
    done
    return 1
}

cf_stream_relay() {
    local host zone zone_id zone_name account out blocked
    host="$(cf_lower "$GAME_STREAM_DOMAIN")"
    if [ -z "$host" ]; then
        err "The panel has no stream address (GAME_STREAM_DOMAIN), so there is nothing to relay."
        return 1
    fi
    if [ -n "$HTTPS_PORT" ] && [ "$HTTPS_PORT" != 443 ]; then
        err "The panel serves HTTPS on port $HTTPS_PORT, and a Cloudflare Worker only reaches port 443."
        return 1
    fi
    zone="$(cf_zone "$host")" || {
        err "$host isn't in a Cloudflare zone this token can read."
        return 1
    }
    read -r zone_id zone_name _ <<<"$zone"
    if ! cf_covered "$host" "$zone_name" "$zone_id"; then
        err "$host is deeper than Cloudflare's free certificate covers, so a Worker can't serve it."
        return 1
    fi
    cf_ready || return 1
    cf_public_ip || return 1
    account="$(cfa GET "/zones/$zone_id" | jq -r '.result.account.id // empty')"
    if [ -z "$account" ]; then
        err "Could not read which Cloudflare account $zone_name is in."
        return 1
    fi
    cf_upload_worker "$account" || return 1
    ok "Worker $CF_RELAY_WORKER deployed"
    cf_relay_route "$zone_id" "$host/*" || return 1
    ok "Route $host/* → $CF_RELAY_WORKER"
    cf_rules || return 1
    out="$(cf_sync_host "$zone_id" "$host" true false)" || return 1
    if [ -n "$out" ]; then
        printf '%s\n' "$out"
        err "$host has a record that isn't 5Stack's, so its proxy wasn't turned on. Run ./cloudflare.sh to replace it."
        return 1
    fi
    if ! cf_relay_answers "$host"; then
        warn "The stream relay Worker isn't answering on $host, so streams go straight to this server again."
        cf_sync_host "$zone_id" "$host" false false >/dev/null
        return 3
    fi
    if ! cf_reverse_proxy && blocked="$(cf_acme_blocked "$host")"; then
        warn "Let's Encrypt can't reach $host through Cloudflare: $blocked. Streams go straight to this server again."
        cf_sync_host "$zone_id" "$host" false false >/dev/null
        return 3
    fi
    ok "Streams on $host go through the stream relay Worker"
}

cf_plan_json() {
    cf_plan | jq -Rsc '
        split("\n") | map(select(length > 0) | split(" ")
            | {key: .[0], host: .[1], zone_id: .[2], zone: .[3], proxied: .[4], why: .[5]})'
}

cloudflare_setup() {
    local command="$1" replace="" response
    shift
    if ! command -v jq >/dev/null 2>&1; then
        err "Setting up Cloudflare needs jq. Install it with: apt-get install -y jq"
        return 1
    fi
    if [ "$1" = --replace ]; then
        replace="$(cf_lower "$2")"
    fi
    cf_load_hosts
    cf_load_token || {
        err "No Cloudflare API token. Run ./cloudflare.sh to add one."
        return 1
    }
    response="$(cfa GET "/zones?per_page=1")"
    if ! cfa_ok <<<"$response"; then
        err "Cloudflare refused the API token: $(cfa_errors <<<"$response")"
        return 1
    fi
    case "$command" in
        plan)
            if [ "$1" = --json ]; then
                cf_plan_json
            else
                cf_plan
            fi
            ;;
        check) cf_check ;;
        records) cf_records "$replace" ;;
        proxy) cf_proxy ;;
        origins) cf_origins ;;
        status) cf_status_json ;;
        fix) cf_fix "$1" ;;
        tiered-cache) cf_tiered_cache ;;
        stream-relay) cf_stream_relay ;;
        *)
            err "Unknown step: $command"
            return 1
            ;;
    esac
}

cloudflare_sync_records() {
    local out status hosts answer
    out="$(cloudflare_setup records)"
    status=$?
    grep -v '^conflict: ' <<<"$out"
    if [ "$status" = 2 ] && [ -t 0 ] && [ "$ASSUME_YES" != true ]; then
        grep '^conflict: ' <<<"$out" | sed 's/^conflict: /    /'
        hosts="$(grep '^conflict: ' <<<"$out" | awk '{ print $2 }' | sort -u | paste -sd, -)"
        read -r -p "    These records aren't 5Stack's. Replace them so the panel works? (y/n): " answer
        if [ "$answer" = y ]; then
            cloudflare_setup records --replace "$hosts"
            status=$?
        fi
    fi
    if [ "$status" != 0 ]; then
        warn "Not every Cloudflare record was updated; the panel carries on with them as they are."
    fi
}

cloudflare_sync_proxy() {
    if ! cloudflare_setup proxy; then
        warn "Cloudflare isn't in front of every panel hostname yet. Run ./cloudflare.sh to see why."
    fi
}

cloudflare_sync_stream_relay() {
    if ! cloudflare_setup stream-relay; then
        warn "The stream relay Worker isn't set up, so streams go straight to this server. Run ./stream-relay.sh to see why."
    fi
}

cloudflare_update_records() {
    if [ "$CLOUDFLARE_RECORDS_SET" = true ]; then
        return 0
    fi
    step "Updating the panel's Cloudflare records"
    cloudflare_sync_records
}

cloudflare_update_proxy() {
    if [ "$CLOUDFLARE_RECORDS_SET" = true ]; then
        cloudflare_setup origins
    else
        step "Putting Cloudflare in front of the panel"
        cloudflare_sync_proxy
    fi
    if [ "$CLOUDFLARE_STREAM_RELAY" = true ]; then
        step "Putting the stream relay Worker in front of streams"
        cloudflare_sync_stream_relay
    fi
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    cloudflare_setup "$@"
fi
