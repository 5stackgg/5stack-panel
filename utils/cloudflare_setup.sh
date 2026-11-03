#!/bin/bash

# Manages the panel's hostnames on Cloudflare with CLOUDFLARE_API_TOKEN.
#
#   cloudflare_setup.sh plan [--json]           what each hostname gets; changes nothing
#   cloudflare_setup.sh records [--replace a,b] DNS records, DNS-only until the proxy step
#   cloudflare_setup.sh proxy                   rules, then the orange cloud, host by host
#   cloudflare_setup.sh status --json           records and settings against what setup left
#   cloudflare_setup.sh fix <host>              puts one record back
#   cloudflare_setup.sh tiered-cache            turns on Smart Tiered Cache
#
# Every hostname goes through Cloudflare except demo uploads (DEMOS_DOMAIN,
# over Cloudflare's 100 MB request limit) and TURN (UDP). The Worker hostname
# and hosts a Workers route answers are never touched. A proxied name must be
# the zone, one label below it, or covered by one of the zone's certificate
# packs: Cloudflare's free certificate covers nothing deeper. Nothing is
# proxied when HTTPS_PORT isn't 443.

CF_SETUP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
: "${PANEL_DIR:=$(cd "$CF_SETUP_DIR/.." && pwd)}"
# shellcheck source=utils/colors.sh
source "$CF_SETUP_DIR/colors.sh"
# shellcheck source=utils/cloudflare_api.sh
source "$CF_SETUP_DIR/cloudflare_api.sh"

CF_COMMENT="5stack-panel (managed by update.sh)"
CF_CONFIG_REF="5stack_panel"
CF_CACHE_REF="5stack_panel_no_cache"
CF_PROXIED_KEYS="WEB_DOMAIN API_DOMAIN WS_DOMAIN TYPESENSE_HOST RELAY_DOMAIN GAME_STREAM_DOMAIN S3_CONSOLE_HOST"
CF_DIRECT_KEYS="DEMOS_DOMAIN TURN_DOMAIN"
CF_NO_CACHE_KEYS="API_DOMAIN WS_DOMAIN TYPESENSE_HOST RELAY_DOMAIN GAME_STREAM_DOMAIN"
: "${CF_TRACE_URL:=https://1.1.1.1/cdn-cgi/trace}"
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
}

cf_load_token() {
    if [ -n "$CLOUDFLARE_API_TOKEN" ]; then
        return 0
    fi
    CLOUDFLARE_API_TOKEN="$(cf_env_value "$PANEL_DIR/overlays/local-secrets/cloudflare-secrets.env" CLOUDFLARE_API_TOKEN)"
    if [ -z "$CLOUDFLARE_API_TOKEN" ] || [ "$CLOUDFLARE_API_TOKEN" = VAULT ]; then
        CLOUDFLARE_API_TOKEN="$(kubectl --kubeconfig="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}" -n 5stack get secret cloudflare-secrets \
            -o jsonpath='{.data.CLOUDFLARE_API_TOKEN}' 2>/dev/null | base64 -d 2>/dev/null)"
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
        response="$(cfa GET "/zones?name=$candidate&status=active")" || return 1
        if jq -e '.result | length > 0' >/dev/null 2>&1 <<<"$response"; then
            jq -r '.result[0] | "\(.id) \(.name) \(.plan.name // "unknown")"' <<<"$response"
            return 0
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
    local host="$1" zone_id="$2"
    cfa GET "/zones/$zone_id/workers/routes" |
        jq -e --arg h "$host" 'any(.result[]?; (.pattern | split("/")[0]) == $h)' >/dev/null 2>&1
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
    local key host zone zone_id zone_name proxied why
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
            why="$([ "$key" = TURN_DOMAIN ] && echo udp || echo uploads)"
        elif [ -n "$HTTPS_PORT" ] && [ "$HTTPS_PORT" != 443 ]; then
            proxied=no
            why=port
        elif ! cf_covered "$host" "$zone_name" "$zone_id"; then
            proxied=no
            why=depth
        fi
        if cf_worker_routed "$host" "$zone_id"; then
            proxied=skip
            why=worker
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
    local zone_id zone_name ids response probe phase
    zone_id=""
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
        for phase in http_config_settings http_request_cache_settings; do
            response="$(cfa GET "/zones/$zone_id/rulesets/phases/$phase/entrypoint")"
            if ! cfa_ok <<<"$response" && ! jq -e 'any(.errors[]?; .code == 10003)' >/dev/null 2>&1 <<<"$response"; then
                echo "rules: $zone_name: $phase: $(cfa_errors <<<"$response")"
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
    local replace_list="$1" key host zone_id zone_name proxied why want conflicts="" out
    cf_public_ip || {
        err "Could not find this server's public IP. Set CLOUDFLARE_ORIGIN_IPV4."
        return 1
    }
    if cf_private_ip "$CLOUDFLARE_ORIGIN_IPV4"; then
        err "$CLOUDFLARE_ORIGIN_IPV4 is a private address, so Cloudflare can't reach this server there."
        return 1
    fi
    while read -r key host zone_id zone_name proxied why; do
        if [ "$proxied" = skip ]; then
            continue
        fi
        want=keep
        if [ "$proxied" = no ]; then
            want=false
        fi
        out="$(cf_sync_host "$zone_id" "$host" "$want" "$(cf_in_list "$host" "$replace_list" && echo true || echo false)")" || return 1
        if [ -n "$out" ]; then
            conflicts+="$out"$'\n'
        else
            ok "$host → $CLOUDFLARE_ORIGIN_IPV4$([ "$want" = false ] && echo " (straight to this server)")"
        fi
    done < <(cf_plan)
    while read -r zone_id zone_name; do
        cf_caa_warning "$zone_id" "$zone_name"
    done < <(cf_plan | awk '$3 != "-" { print $3 " " $4 }' | sort -u)
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
    local zone_id="$1" phase="$2" ref="$3" description="$4" action="$5" params="$6" response rule ruleset_id rule_id
    shift 6
    rule="$(jq -nc --arg ref "$ref" --arg d "$description" --arg a "$action" --argjson p "$params" --arg e "$(cf_host_expression "$@")" \
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

cf_origin_status() {
    local host="$1"
    curl -s -o /dev/null --max-time 20 -w '%{http_code}' "https://$host/"
}

cf_proxy() {
    local problems line key host zone_id zone_name proxied why zone hosts nocache status code
    problems="$(cf_check)"
    if [ -n "$problems" ]; then
        err "Cloudflare isn't ready for the panel:"
        while read -r line; do
            err "${line#*: }"
        done <<<"$problems"
        return 1
    fi
    cf_public_ip || return 1
    for zone in $(cf_plan | awk '$5 == "yes" { print $3 }' | sort -u); do
        hosts=()
        nocache=()
        while read -r key host zone_id zone_name proxied why; do
            hosts+=("$host")
            if [[ " $CF_NO_CACHE_KEYS " == *" $key "* ]]; then
                nocache+=("$host")
            fi
        done < <(cf_plan | awk -v z="$zone" '$3 == z && $5 == "yes"')
        cf_rule "$zone" http_config_settings "$CF_CONFIG_REF" "5Stack panel" set_config \
            '{"ssl": "strict", "rocket_loader": false, "email_obfuscation": false, "disable_zaraz": true, "bic": false}' "${hosts[@]}" || {
            err "Could not save the 5Stack configuration rule"
            return 1
        }
        if [ "${#nocache[@]}" -gt 0 ]; then
            cf_rule "$zone" http_request_cache_settings "$CF_CACHE_REF" "5Stack panel: live data" set_cache_settings \
                '{"cache": false}' "${nocache[@]}" || {
                err "Could not save the 5Stack cache rule"
                return 1
            }
        fi
    done
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
                ;;
            *)
                ok "$host through Cloudflare"
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
            '{id: $id, name: $name, websockets: $ws, bot_fight: $bot, tiered_cache: $tiered, ssl: $rule}'
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
        cfa PATCH "/zones/$zone/cache/tiered_cache_smart_topology_enable" '{"value": "on"}' | cfa_ok || return 1
    done
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
        status) cf_status_json ;;
        fix) cf_fix "$1" ;;
        tiered-cache) cf_tiered_cache ;;
        *)
            err "Unknown step: $command"
            return 1
            ;;
    esac
}

cloudflare_sync_records() {
    local zones out status hosts answer
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
    zones="$(cf_plan 2>/dev/null | awk '$4 != "-" { print $4 }' | sort -u | paste -sd, -)"
    if [ -n "$zones" ]; then
        export CLOUDFLARE_ZONES="$zones"
        update_env_var "$PANEL_DIR/.5stack-env.config" CLOUDFLARE_ZONES "$zones"
    fi
}

cloudflare_sync_proxy() {
    if ! cloudflare_setup proxy; then
        warn "Cloudflare isn't in front of every panel hostname yet. Run ./cloudflare.sh to see why."
    fi
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    cloudflare_setup "$@"
fi
