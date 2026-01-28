#!/bin/bash

# Tailscale API helper functions
# Documentation: https://tailscale.com/api

TAILSCALE_API_BASE="https://api.tailscale.com/api/v2"

get_oauth_token() {
    local client_id=$1
    local client_secret=$2

    if [ -z "$client_id" ] || [ -z "$client_secret" ]; then
        echo "Error: Client ID and Client Secret are required" >&2
        return 1
    fi

    local response=$(curl -s -X POST "https://api.tailscale.com/api/v2/oauth/token" \
        -d "client_id=${client_id}" \
        -d "client_secret=${client_secret}" \
        -d "grant_type=client_credentials")

    if echo "$response" | grep -q '"error"'; then
        echo "Error: Failed to get OAuth token" >&2
        echo "$response" | grep -o '"error":"[^"]*"' >&2
        return 1
    fi

    local token=$(echo "$response" | grep -o '"access_token":"[^"]*"' | cut -d'"' -f4)

    if [ -z "$token" ]; then
        echo "Error: No access token in response" >&2
        return 1
    fi

    echo "$token"
}

create_auth_key() {
    local access_token=$1

    if [ -z "$access_token" ]; then
        echo "Error: Access token is required" >&2
        return 1
    fi

    local response=$(curl -s -X POST "${TAILSCALE_API_BASE}/tailnet/-/keys" \
        -H "Authorization: Bearer ${access_token}" \
        -H "Content-Type: application/json" \
        -d '{
            "capabilities": {
                "devices": {
                    "create": {
                        "reusable": false,
                        "ephemeral": false,
                        "preauthorized": true,
                        "tags": ["tag:fivestack"]
                    }
                }
            },
            "expirySeconds": 3600,
            "description": "5stack game node auth key"
        }')

    if echo "$response" | grep -q '"message"' && ! echo "$response" | grep -q '"key"'; then
        echo "Error: Failed to create auth key" >&2
        echo "$response" >&2
        return 1
    fi

    local key=$(echo "$response" | grep -o '"key":"[^"]*"' | cut -d'"' -f4)

    if [ -z "$key" ]; then
        echo "Error: No auth key in response" >&2
        return 1
    fi

    echo "$key"
}

update_acl_for_fivestack() {
    local access_token=$1

    if [ -z "$access_token" ]; then
        echo "Error: Access token is required" >&2
        return 1
    fi

    local acl_response=$(curl -s -D - -X GET "${TAILSCALE_API_BASE}/tailnet/-/acl" \
        -H "Authorization: Bearer ${access_token}" \
        -H "Accept: application/json")

    local headers=$(echo "$acl_response" | sed '/^\r$/q')
    local body=$(echo "$acl_response" | sed '1,/^\r$/d')

    local etag=$(echo "$headers" | grep -i '^etag:' | awk '{print $2}' | tr -d $'\r\n"')
    if [ -z "$etag" ]; then
        echo "Error: Could not extract ACL ETag. Cannot ensure concurrency-safe update." >&2
        return 1
    fi

    if echo "$body" | grep -q '"message"' && ! echo "$body" | grep -q '"acls"'; then
        echo "Error: Failed to get current ACL" >&2
        echo "$body" >&2
        return 1
    fi

    echo "Current ACL: $body" >&2

    if ! command -v jq &>/dev/null; then
        echo "Error: jq is required to update ACLs. Please install jq." >&2
        return 1
    fi

    updated_acl=$(echo "$body" | jq '
        .autoApprovers = (.autoApprovers // {})
        | .autoApprovers.routes = (.autoApprovers.routes // {})
        | .autoApprovers.routes["10.42.0.0/16"] = (
            (.autoApprovers.routes["10.42.0.0/16"] // []) |
            if index("tag:fivestack") == null then . + ["tag:fivestack"] else . end
        )
        | .grants = (.grants // [])
        # Filter out any existing identical grant to avoid duplicates and enforce desired position.
        | .grants = (
            [ 
                # Our new grant at the front:
                { src: ["tag:fivestack", "10.42.0.0/16"], dst: ["tag:fivestack", "10.42.0.0/16"], ip: ["*"] }
            ] + (
                .grants
                | map(select(
                    .src != ["tag:fivestack", "10.42.0.0/16"]
                    or .dst != ["tag:fivestack", "10.42.0.0/16"]
                    or .ip != ["*"]
                ))
            )
        )
    ')

    local response=$(curl -s -X POST "${TAILSCALE_API_BASE}/tailnet/-/acl" \
        -H "Authorization: Bearer ${access_token}" \
        -H "Content-Type: application/json" \
        -H "If-Match: \"${etag}\"" \
        -d "$updated_acl")

    if echo "$response" | grep -q '"message"'; then
        echo "Error: Failed to update ACL" >&2
        echo "$response" >&2

        if echo "$response" | grep -q 'precondition failed'; then
            echo "Your ACL has been modified elsewhere. Please re-run or manually resolve the ACL update." >&2
        fi

        return 1
    fi

    return 0
}