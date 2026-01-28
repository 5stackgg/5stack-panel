#!/bin/bash

source setup-env.sh "$@"

echo "Installing Game Node Server dependencies..."
curl -sfL https://tailscale.com/install.sh | sh

echo ""
echo "=========================================="
echo "Tailscale OAuth Setup Required"
echo "=========================================="
echo ""
echo "This script automates Tailscale configuration using OAuth API."
echo ""
echo "One-time setup:"
echo "Access Control Tags:"
ehoo " https://login.tailscale.com/admin/acls/visual/tags/add"
echo "  - fivestack"
echo ""
echo "Create an OAuth Client at:"
echo "  https://login.tailscale.com/admin/settings/trust-credentials/add"
echo ""
echo "OAuth scopes:"
echo "  Keys : Auth Keys (write)"
echo "  Devices: Core (read)"
echo "  General: Policy File (write)"
echo "  General: DNS (read)"
echo ""
echo "Required tag:"
echo "  ✓ fivestack"
echo ""
echo "After creating the OAuth client, you'll receive:"
echo "  - Client ID"
echo "  - Client Secret (shown only once - save it securely!)"
echo ""
echo "=========================================="
echo ""

# Collect OAuth credentials
echo -e "\033[1;36mEnter your Tailscale OAuth Client ID:\033[0m"
read TAILSCALE_CLIENT_ID
while [ -z "$TAILSCALE_CLIENT_ID" ]; do
    echo "Client ID cannot be empty. Please enter your OAuth Client ID:"
    read TAILSCALE_CLIENT_ID
done

echo -e "\033[1;36mEnter your Tailscale OAuth Client Secret:\033[0m"
read -s TAILSCALE_CLIENT_SECRET
echo ""
while [ -z "$TAILSCALE_CLIENT_SECRET" ]; do
    echo "Client Secret cannot be empty. Please enter your OAuth Client Secret (when pasting it will not show for security reasons):"
    read -s TAILSCALE_CLIENT_SECRET
    echo ""
done

echo ""
echo "🔐 Authenticating with Tailscale API..."
ACCESS_TOKEN=$(get_oauth_token "$TAILSCALE_CLIENT_ID" "$TAILSCALE_CLIENT_SECRET")

if [ -z "$ACCESS_TOKEN" ]; then
    echo "❌ Failed to authenticate with Tailscale. Please check your OAuth credentials."
    exit 1
fi

echo "✅ Authentication successful"

# Store OAuth credentials
update_env_var "overlays/config/api-config.env" "TAILSCALE_CLIENT_ID" "$TAILSCALE_CLIENT_ID"
update_env_var "overlays/local-secrets/tailscale-secrets.env" "TAILSCALE_SECRET_ID" "$TAILSCALE_CLIENT_SECRET"

echo ""
echo "📡 Retrieving tailnet information..."
TAILSCALE_NET_NAME=$(get_tailnet_info "$ACCESS_TOKEN")

if [ -z "$TAILSCALE_NET_NAME" ]; then
    echo "❌ Failed to retrieve tailnet information."
    exit 1
fi

echo "✅ Tailnet: $TAILSCALE_NET_NAME"
update_env_var "overlays/config/api-config.env" "TAILSCALE_NET_NAME" "$TAILSCALE_NET_NAME"

echo ""
echo "🔧 Configuring ACL rules for fivestack tag..."
update_acl_for_fivestack "$ACCESS_TOKEN"

if [ $? -eq 0 ]; then
    echo "✅ ACL configured (10.42.0.0/16 subnet with auto-approvers)"
else
    echo "⚠️  Warning: ACL configuration failed. You may need to configure ACL manually."
fi

echo ""
echo "🔑 Generating pre-approved auth key..."
TAILSCALE_AUTH_KEY=$(create_auth_key "$ACCESS_TOKEN")

if [ -z "$TAILSCALE_AUTH_KEY" ]; then
    echo "❌ Failed to generate auth key."
    exit 1
fi

echo "✅ Auth key generated"

echo ""
echo "🚀 Installing K3S with Tailscale VPN integration..."
curl -sfL https://get.k3s.io | sh -s - --disable=traefik --vpn-auth="name=tailscale,joinKey=${TAILSCALE_AUTH_KEY}"

echo ""
echo "⏳ Waiting for node to come online in Tailscale network..."
HOSTNAME=$(hostname)
TAILSCALE_NODE_IP=$(wait_for_device_and_get_ip "$ACCESS_TOKEN" "$HOSTNAME")

if [ -z "$TAILSCALE_NODE_IP" ]; then
    echo "❌ Timeout waiting for node to appear."
    echo "Please check the Tailscale dashboard and manually enter the node IP."
    echo -e "\033[1;36mEnter the Tailscale node IP address:\033[0m"
    read TAILSCALE_NODE_IP
    while [ -z "$TAILSCALE_NODE_IP" ]; do
        echo "Node IP cannot be empty. Please enter the Tailscale node IP:"
        read TAILSCALE_NODE_IP
    done
else
    echo "✅ Node online with IP: $TAILSCALE_NODE_IP"
fi

update_env_var "overlays/config/api-config.env" "TAILSCALE_NODE_IP" "$TAILSCALE_NODE_IP"

echo ""
echo "🎉 Game node server setup complete!"
echo ""
echo "Configuration saved:"
echo "  - TAILSCALE_NET_NAME: $TAILSCALE_NET_NAME"
echo "  - TAILSCALE_CLIENT_ID: $TAILSCALE_CLIENT_ID"
echo "  - TAILSCALE_NODE_IP: $TAILSCALE_NODE_IP"
echo ""

source update.sh "$@"