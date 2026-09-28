#!/bin/bash

# Shared by the scripts that deploy the panel's Cloudflare Workers
# (playcast-relay.sh, backblaze-proxy.sh).
#
# Routes are created through the Cloudflare API instead of wrangler's --route:
# wrangler replaces every route a worker already has with the ones it is given,
# so moving a worker to a new hostname would silently drop the old one, along
# with every link that still points there.

CF_WRANGLER="wrangler@^4.139"
CF_API="https://api.cloudflare.com/client/v4"

wrangler() {
    npx --yes "$CF_WRANGLER" "$@"
}

# cf_json EXPR [ARG...] -- prints EXPR evaluated against the JSON on stdin,
# which it sees as `j`; extra arguments are passed in as the array `a`.
cf_json() {
    node -e '
        let input = "";
        process.stdin.on("data", (chunk) => (input += chunk));
        process.stdin.on("end", () => {
            try {
                const j = JSON.parse(input.slice(input.indexOf("{")));
                const out = new Function("j", "a", "return (" + process.argv[1] + ")")(j, process.argv.slice(2));
                if (out !== undefined && out !== null) {
                    process.stdout.write(String(out));
                }
            } catch {}
        });
    ' "$@"
}

cf_link() {
    echo "${C_STEP}    $1${C_RESET}"
}

cf_require_node() {
    if ! command -v node >/dev/null 2>&1 || ! command -v npx >/dev/null 2>&1; then
        err "Node.js is needed to run wrangler, Cloudflare's deploy tool."
        err "Install Node.js 22 or newer (https://nodejs.org/en/download), then run this again."
        exit 1
    fi
    if [ "$(node -p 'process.versions.node.split(".")[0]')" -lt 22 ]; then
        err "wrangler needs Node.js 22 or newer, and this machine has $(node --version)."
        err "Update it (https://nodejs.org/en/download), then run this again."
        exit 1
    fi
}

cf_read_api_token() {
    echo
    echo "    Create a token in Cloudflare for this:"
    cf_link "https://dash.cloudflare.com/profile/api-tokens"
    echo "      1. Create Token, then use the \"Edit Cloudflare Workers\" template"
    echo "      2. Account Resources: your account. Zone Resources: the domain $1 is on"
    echo "      3. Continue to summary, Create Token, and copy it"
    echo "    It is only used for this run and is not saved."
    echo
    read_masked "    API token: " CLOUDFLARE_API_TOKEN
    export CLOUDFLARE_API_TOKEN
}

# cf_sign_in HOST -- signs wrangler in (asking how when it is not), picks the
# account and sets CF_TOKEN for the API calls below.
cf_sign_in() {
    local host="$1" whoami choice default=1 count names=() name index

    step "Signing in to Cloudflare"
    whoami="$(wrangler whoami --json 2>/dev/null)"
    if [ "$(echo "$whoami" | cf_json 'j.loggedIn')" != "true" ]; then
        if [ -n "$CLOUDFLARE_API_TOKEN" ]; then
            die "Cloudflare rejected the CLOUDFLARE_API_TOKEN in your environment. Unset or replace it, then run this again."
        fi
        if [ "$(uname)" = "Darwin" ] || [ -n "$DISPLAY" ] || [ -n "$WAYLAND_DISPLAY" ]; then
            default=0
        fi
        interactive_menu choice "How do you want to sign in to Cloudflare?" "$default" \
            "Open a browser on this machine" \
            "Enter a code on another device (servers without a browser)" \
            "Paste an API token"
        case "$choice" in
            0) wrangler login || die "Signing in to Cloudflare failed." ;;
            1) wrangler login --device --browser=false || die "Signing in to Cloudflare failed." ;;
            2) cf_read_api_token "$host" ;;
        esac
        whoami="$(wrangler whoami --json 2>/dev/null)"
        if [ "$(echo "$whoami" | cf_json 'j.loggedIn')" != "true" ]; then
            die "Still not signed in to Cloudflare. Run this again to retry."
        fi
    fi

    count="$(echo "$whoami" | cf_json 'j.accounts.length')"
    if [ -z "$count" ] || [ "$count" -eq 0 ]; then
        die "This Cloudflare login has no accounts it can use."
    fi
    if [ -z "$CLOUDFLARE_ACCOUNT_ID" ]; then
        index=0
        if [ "$count" -gt 1 ]; then
            while IFS= read -r name; do
                names+=("$name")
            done < <(echo "$whoami" | cf_json 'j.accounts.map((account) => account.name).join("\n")')
            interactive_menu index "Which Cloudflare account is $host's domain in?" 0 "${names[@]}"
        fi
        CLOUDFLARE_ACCOUNT_ID="$(echo "$whoami" | cf_json 'j.accounts[Number(a[0])].id' "$index")"
    fi
    export CLOUDFLARE_ACCOUNT_ID
    CF_ACCOUNT_NAME="$(echo "$whoami" | cf_json 'j.accounts.find((account) => account.id === a[0])?.name' "$CLOUDFLARE_ACCOUNT_ID")"
    if [ -z "$CF_ACCOUNT_NAME" ]; then
        die "CLOUDFLARE_ACCOUNT_ID ($CLOUDFLARE_ACCOUNT_ID) is not an account this login can use."
    fi

    CF_TOKEN="$(wrangler auth token --json 2>/dev/null | cf_json 'j.token')"
    if [ -z "$CF_TOKEN" ]; then
        die "Could not read the Cloudflare token wrangler signed in with."
    fi

    ok "Signed in as $(echo "$whoami" | cf_json 'j.email || "an API token"'), account $CF_ACCOUNT_NAME"
}

# cf_api METHOD PATH [BODY] -- the token goes in through curl's config on stdin
# so it never shows up in the process list.
cf_api() {
    local args=(-sS -K - -X "$1" -H "Content-Type: application/json")
    if [ -n "$3" ]; then
        args+=(--data "$3")
    fi
    printf 'header = "Authorization: Bearer %s"\n' "$CF_TOKEN" | curl "${args[@]}" "$CF_API$2"
}

cf_api_errors() {
    local errors
    if [ "$(echo "$1" | cf_json 'j.success')" = "true" ]; then
        return
    fi
    errors="$(echo "$1" | cf_json '(j.errors || []).map((e) => e.message).join("; ")')"
    echo "${errors:-no usable response from the Cloudflare API}"
}

# cf_find_zone HOST -- sets CF_ZONE_ID, CF_ZONE_NAME and CF_ZONE_NS for the
# domain HOST is on, or explains how to get the domain onto Cloudflare.
cf_find_zone() {
    local host="$1" candidate="$1" response errors status

    while [[ "$candidate" == *.* ]]; do
        response="$(cf_api GET "/zones?name=$candidate&account.id=$CLOUDFLARE_ACCOUNT_ID")"
        errors="$(cf_api_errors "$response")"
        if [ -n "$errors" ]; then
            die "Cloudflare did not let us look up $candidate: $errors"
        fi
        CF_ZONE_ID="$(echo "$response" | cf_json 'j.result[0]?.id')"
        if [ -n "$CF_ZONE_ID" ]; then
            CF_ZONE_NAME="$(echo "$response" | cf_json 'j.result[0].name')"
            CF_ZONE_NS="$(echo "$response" | cf_json 'j.result[0].name_servers.join(" ")')"
            status="$(echo "$response" | cf_json 'j.result[0].status')"
            if [ "$status" != "active" ]; then
                err "$CF_ZONE_NAME is in Cloudflare but not active yet (status: $status)."
                err "Cloudflare is waiting for its nameservers to be changed at your registrar to:"
                err "  $CF_ZONE_NS"
                err "Once the dashboard shows it as Active, run this again."
                cf_link "https://dash.cloudflare.com/$CLOUDFLARE_ACCOUNT_ID/$CF_ZONE_NAME"
                exit 1
            fi
            ok "$host is on $CF_ZONE_NAME in Cloudflare"
            return 0
        fi
        candidate="${candidate#*.}"
    done

    err "$host is not on a domain in the Cloudflare account $CF_ACCOUNT_NAME."
    err "Add your domain to Cloudflare and change its nameservers at your registrar to the"
    err "ones Cloudflare gives you. Once the dashboard shows it as Active, run this again."
    cf_link "https://dash.cloudflare.com/$CLOUDFLARE_ACCOUNT_ID/add-site"
    exit 1
}

# Asks the zone's own nameservers first: a resolver that looked the name up
# before its record existed can keep answering "no such host" for half an hour.
cf_resolve() {
    local host="$1" ns ip
    if command -v dig >/dev/null 2>&1; then
        for ns in $CF_ZONE_NS; do
            ip="$(dig +short +time=3 +tries=1 A "$host" "@$ns" 2>/dev/null | grep -E '^[0-9.]+$' | head -n 1)"
            if [ -n "$ip" ]; then
                echo "$ip"
                return 0
            fi
        done
    fi
    curl -s --max-time 10 -H "accept: application/dns-json" \
        "https://cloudflare-dns.com/dns-query?name=$host&type=A" \
        | cf_json '(j.Answer || []).filter((answer) => answer.type === 1).map((answer) => answer.data)[0]'
}

# cf_curl HOST [CURL ARGS...] -- curl pinned to the address cf_resolve found.
cf_curl() {
    local host="$1" ip
    shift
    ip="$(cf_resolve "$host")"
    if [ -n "$ip" ]; then
        curl --resolve "$host:443:$ip" "$@"
    else
        curl "$@"
    fi
}

cf_wait_to_retry() {
    local answer
    if ! read -r -p "    Press Enter to check again, or type skip to carry on anyway: " answer; then
        echo
        die "Stopped."
    fi
    if [ "$answer" = "skip" ]; then
        warn "Carrying on without this check."
        return 1
    fi
    return 0
}

# cf_wait_for_proxied HOST [placeholder] -- waits until HOST is served through
# Cloudflare, telling the admin what to change in the dashboard until it is.
# With "placeholder", HOST is only ever answered by a worker, so a record with
# a placeholder address is all it needs.
cf_wait_for_proxied() {
    local host="$1" placeholder="$2" name="@" ip

    if [ "$host" != "$CF_ZONE_NAME" ]; then
        name="${host%".$CF_ZONE_NAME"}"
    fi

    step "Checking that $host goes through Cloudflare"
    while true; do
        ip="$(cf_resolve "$host")"
        if [ -n "$ip" ] && curl -sI --max-time 10 --resolve "$host:443:$ip" "https://$host/" | grep -qi '^server: cloudflare'; then
            ok "$host is proxied through Cloudflare"
            return 0
        fi

        if [ -z "$ip" ] && [ "$placeholder" = "placeholder" ]; then
            warn "$host has no DNS record yet. Add this one in Cloudflare's DNS records:"
            warn "  Type: AAAA   Name: $name   IPv6 address: 100::   Proxy status: Proxied"
            warn "The worker answers every request on it, so 100:: is only a placeholder."
        elif [ -z "$ip" ]; then
            warn "$host has no DNS record in Cloudflare. Add one pointing at your panel's"
            warn "server, the same as your other panel hostnames, with Proxy status: Proxied."
        else
            warn "$host is in DNS but is not proxied through Cloudflare. Edit its record in"
            warn "Cloudflare's DNS records and turn Proxy status on (the orange cloud)."
        fi
        cf_link "https://dash.cloudflare.com/$CLOUDFLARE_ACCOUNT_ID/$CF_ZONE_NAME/dns/records"
        warn "DNS changes can take a minute to show up here."
        cf_wait_to_retry || return 0
    done
}

# cf_check_origin HOST -- makes sure Cloudflare can reach the panel behind
# HOST, which a proxied hostname breaks when SSL/TLS is on Flexible.
cf_check_origin() {
    local host="$1" code location

    step "Checking that Cloudflare can reach your panel on $host"
    while true; do
        read -r code location < <(cf_curl "$host" -s -o /dev/null --max-time 15 \
            -w '%{http_code} %{redirect_url}\n' "https://$host/")
        case "$code" in
            525|526)
                warn "Cloudflare cannot make a secure connection to your panel (HTTP $code)."
                warn "Set SSL/TLS encryption mode to Full. Full (strict) only works when your"
                warn "panel's certificate is valid."
                cf_link "https://dash.cloudflare.com/$CLOUDFLARE_ACCOUNT_ID/$CF_ZONE_NAME/ssl-tls"
                ;;
            52[0-4]|530)
                warn "Cloudflare cannot reach your panel on $host (HTTP $code)."
                warn "Check that its DNS record points at your server and that ports 80 and 443"
                warn "are open, or that your Cloudflare Tunnel is running."
                cf_link "https://dash.cloudflare.com/$CLOUDFLARE_ACCOUNT_ID/$CF_ZONE_NAME/dns/records"
                ;;
            301|302|307|308)
                if [ "$location" != "https://$host/" ]; then
                    ok "Cloudflare reaches your panel"
                    return 0
                fi
                warn "$host redirects to itself, which is what SSL/TLS encryption mode Flexible"
                warn "does to a panel. Set it to Full."
                cf_link "https://dash.cloudflare.com/$CLOUDFLARE_ACCOUNT_ID/$CF_ZONE_NAME/ssl-tls"
                ;;
            000|"")
                warn "https://$host did not answer."
                ;;
            *)
                ok "Cloudflare reaches your panel"
                return 0
                ;;
        esac
        cf_wait_to_retry || return 0
    done
}

# cf_ensure_routes SCRIPT FAIL_OPEN PATTERN... -- points each PATTERN at
# SCRIPT, leaving the worker's other routes alone. FAIL_OPEN=true lets
# requests skip the worker, instead of failing, once the Workers Free daily
# request limit is reached.
cf_ensure_routes() {
    local script="$1" fail_open="$2" routes errors pattern id owner body response
    shift 2

    routes="$(cf_api GET "/zones/$CF_ZONE_ID/workers/routes")"
    errors="$(cf_api_errors "$routes")"
    if [ -n "$errors" ]; then
        die "Could not list $CF_ZONE_NAME's worker routes: $errors"
    fi

    for pattern in "$@"; do
        id="$(echo "$routes" | cf_json 'j.result.find((route) => route.pattern === a[0])?.id' "$pattern")"
        owner="$(echo "$routes" | cf_json 'j.result.find((route) => route.pattern === a[0])?.script' "$pattern")"
        body="$(node -p 'JSON.stringify({ pattern: process.argv[1], script: process.argv[2], request_limit_fail_open: process.argv[3] === "true" })' \
            "$pattern" "$script" "$fail_open")"

        if [ -n "$id" ] && [ -n "$owner" ] && [ "$owner" != "$script" ]; then
            err "The route $pattern already sends requests to the worker \"$owner\"."
            err "Remove it from $CF_ZONE_NAME's Workers Routes, then run this again."
            cf_link "https://dash.cloudflare.com/$CLOUDFLARE_ACCOUNT_ID/$CF_ZONE_NAME/workers"
            exit 1
        fi

        if [ -z "$id" ]; then
            response="$(cf_api POST "/zones/$CF_ZONE_ID/workers/routes" "$body")"
            errors="$(cf_api_errors "$response")"
            if [ -n "$errors" ]; then
                die "Could not add the route $pattern: $errors"
            fi
            id="$(echo "$response" | cf_json 'j.result.id')"
            ok "Added route $pattern -> $script"
            if [ "$fail_open" != "true" ]; then
                continue
            fi
        fi

        # Also run for a route just added: the fail-open flag is only
        # documented on the update endpoint.
        response="$(cf_api PUT "/zones/$CF_ZONE_ID/workers/routes/$id" "$body")"
        errors="$(cf_api_errors "$response")"
        if [ -n "$errors" ]; then
            die "Could not update the route $pattern: $errors"
        fi
        ok "Route $pattern -> $script"
    done

    CF_OTHER_ROUTES="$(echo "$routes" | cf_json \
        'j.result.filter((route) => route.script === a[0] && !a.slice(1).includes(route.pattern)).map((route) => route.pattern).join("\n")' \
        "$script" "$@")"
}
