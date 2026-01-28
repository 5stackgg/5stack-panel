#!/bin/bash

# Tailscale API helper functions
# Documentation: https://tailscale.com/kb/1101/api

TAILSCALE_API_BASE="https://api.tailscale.com/api/v2"

# Get OAuth access token from client credentials
# Args: client_id, client_secret
# Returns: access_token (printed to stdout)
get_oauth_token() {
    local client_id=$1
    local client_secret=$2

    if [ -z "$client_id" ] || [ -z "$client_secret" ]; then
        echo "Error: Client ID and Client Secret are required" >&2
        return 1
    fi

    echo "Getting OAuth token..." >&2
    echo "Client ID: $client_id" >&2
    echo "Client Secret: $client_secret" >&2

    local response=$(curl -s -X POST "https://api.tailscale.com/api/v2/oauth/token" \
        -d "client_id=${client_id}" \
        -d "client_secret=${client_secret}" \
        -d "grant_type=client_credentials")

    # Check if response contains an error
    if echo "$response" | grep -q '"error"'; then
        echo "Error: Failed to get OAuth token" >&2
        echo "$response" | grep -o '"error":"[^"]*"' >&2
        return 1
    fi

    # Extract access token
    local token=$(echo "$response" | grep -o '"access_token":"[^"]*"' | cut -d'"' -f4)

    if [ -z "$token" ]; then
        echo "Error: No access token in response" >&2
        return 1
    fi

    echo "$token"
}

# Create pre-approved auth key with fivestack tag
# Args: access_token
# Returns: auth key string (printed to stdout)
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

    # Check if response contains an error
    if echo "$response" | grep -q '"message"' && ! echo "$response" | grep -q '"key"'; then
        echo "Error: Failed to create auth key" >&2
        echo "$response" >&2
        return 1
    fi

    # Extract auth key
    local key=$(echo "$response" | grep -o '"key":"[^"]*"' | cut -d'"' -f4)

    if [ -z "$key" ]; then
        echo "Error: No auth key in response" >&2
        return 1
    fi

    echo "$key"
}

# Get tailnet information (DNS name)
# Args: access_token
# Returns: TAILSCALE_NET_NAME (printed to stdout)
get_tailnet_info() {
    local access_token=$1

    if [ -z "$access_token" ]; then
        echo "Error: Access token is required" >&2
        return 1
    fi

    local response=$(curl -s -X GET "${TAILSCALE_API_BASE}/tailnet/-/devices" \
        -H "Authorization: Bearer ${access_token}")

    # Check if response contains an error
    if echo "$response" | grep -q '"message"' && ! echo "$response" | grep -q '"devices"'; then
        echo "Error: Failed to get tailnet info" >&2
        echo "$response" >&2
        return 1
    fi

    # Extract DNS suffix from first device or use default format
    local dns_suffix=$(echo "$response" | grep -o '"dnsName":"[^"]*"' | head -1 | cut -d'"' -f4 | sed 's/^[^.]*\.//')

    if [ -z "$dns_suffix" ]; then
        # If no devices exist yet, try to get tailnet name from the API
        local tailnet_response=$(curl -s -X GET "${TAILSCALE_API_BASE}/tailnet/-" \
            -H "Authorization: Bearer ${access_token}")

        dns_suffix=$(echo "$tailnet_response" | grep -o '"name":"[^"]*"' | head -1 | cut -d'"' -f4)

        if [ -z "$dns_suffix" ]; then
            echo "Error: Could not determine tailnet DNS name" >&2
            return 1
        fi

        # Add .ts.net if not present
        if [[ ! "$dns_suffix" == *.ts.net ]]; then
            dns_suffix="${dns_suffix}.ts.net"
        fi
    fi

    echo "$dns_suffix"
}

# Update ACL to include fivestack tag rules
# Args: access_token
# Returns: 0 on success, 1 on failure
update_acl_for_fivestack() {
    local access_token=$1

    if [ -z "$access_token" ]; then
        echo "Error: Access token is required" >&2
        return 1
    fi

    # Get current ACL
    local current_acl=$(curl -s -X GET "${TAILSCALE_API_BASE}/tailnet/-/acl" \
        -H "Authorization: Bearer ${access_token}" \
        -H "Accept: application/json")

    # Check if response contains an error
    if echo "$current_acl" | grep -q '"message"' && ! echo "$current_acl" | grep -q '"acls"'; then
        echo "Error: Failed to get current ACL" >&2
        echo "$current_acl" >&2
        return 1
    fi

    # Check if fivestack tag already exists
    if echo "$current_acl" | grep -q '"tag:fivestack"'; then
        echo "Note: fivestack tag already exists in ACL, skipping ACL update" >&2
        return 0
    fi

    # Create updated ACL with fivestack tag
    # This is a minimal ACL that adds the fivestack tag
    local updated_acl=$(cat <<'EOF'
{
  "tagOwners": {
    "tag:fivestack": ["autogroup:admin"]
  },
  "acls": [
    {
      "action": "accept",
      "src": ["tag:fivestack"],
      "dst": ["10.42.0.0/16:*"]
    },
    {
      "action": "accept",
      "src": ["autogroup:admin"],
      "dst": ["*:*"]
    }
  ],
  "autoApprovers": {
    "routes": {
      "10.42.0.0/16": ["tag:fivestack"]
    }
  }
}
EOF
)

    # Update ACL
    local response=$(curl -s -X POST "${TAILSCALE_API_BASE}/tailnet/-/acl" \
        -H "Authorization: Bearer ${access_token}" \
        -H "Content-Type: application/json" \
        -H "If-Match: \"*\"" \
        -d "$updated_acl")

    # Check if response contains an error
    if echo "$response" | grep -q '"message"'; then
        echo "Error: Failed to update ACL" >&2
        echo "$response" >&2
        return 1
    fi

    return 0
}

# Poll for new device to appear and get its IP
# Args: access_token, hostname, max_wait (optional, default 300)
# Returns: TAILSCALE_NODE_IP (printed to stdout)
wait_for_device_and_get_ip() {
    local access_token=$1
    local hostname=$2
    local max_wait=${3:-300}  # Default 5 minutes
    local wait_interval=10
    local elapsed=0

    if [ -z "$access_token" ] || [ -z "$hostname" ]; then
        echo "Error: Access token and hostname are required" >&2
        return 1
    fi

    echo "Polling for device '$hostname' to appear (timeout: ${max_wait}s)..." >&2

    while [ $elapsed -lt $max_wait ]; do
        local response=$(curl -s -X GET "${TAILSCALE_API_BASE}/tailnet/-/devices" \
            -H "Authorization: Bearer ${access_token}")

        # Check if response contains an error
        if echo "$response" | grep -q '"message"' && ! echo "$response" | grep -q '"devices"'; then
            echo "Warning: API error while polling for device" >&2
            sleep $wait_interval
            elapsed=$((elapsed + wait_interval))
            continue
        fi

        # Look for device with matching hostname
        # Extract device info for hostname match
        local device_info=$(echo "$response" | grep -B 5 -A 10 "\"hostname\":\"$hostname\"" | head -20)

        if [ -n "$device_info" ]; then
            # Extract IP address from the device info
            local ip=$(echo "$device_info" | grep -o '"addresses":\[[^]]*\]' | grep -o '"[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}"' | head -1 | tr -d '"')

            if [ -n "$ip" ]; then
                echo "$ip"
                return 0
            fi
        fi

        echo "Device not found yet, waiting ${wait_interval}s... (${elapsed}/${max_wait}s elapsed)" >&2
        sleep $wait_interval
        elapsed=$((elapsed + wait_interval))
    done

    echo "Error: Timeout waiting for device to appear after ${max_wait}s" >&2
    return 1
}
