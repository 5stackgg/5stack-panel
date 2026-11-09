#!/bin/bash

# Calls the Cloudflare API with CLOUDFLARE_API_TOKEN. The token reaches curl on
# stdin as a config line, never as an argument, so ps and the shell's history
# never see it.

: "${CLOUDFLARE_API:=https://api.cloudflare.com/client/v4}"

cfa() {
    local method="$1" path="$2" body="${3:-}"
    local args=(-sS --max-time 30 -X "$method" -H "Content-Type: application/json")
    if [ -n "$body" ]; then
        args+=(--data-binary "$body")
    fi
    printf 'header = "Authorization: Bearer %s"\n' "$CLOUDFLARE_API_TOKEN" |
        curl -K - "${args[@]}" "$CLOUDFLARE_API$path"
}

cfa_ok() {
    jq -e '.success == true' >/dev/null 2>&1
}

cfa_errors() {
    jq -r '[.errors[]?.message] | join("; ")' 2>/dev/null
}
