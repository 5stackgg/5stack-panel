#!/bin/bash

source setup-env.sh "$@"

echo "Installing Tailscale ..."
curl -sfL https://tailscale.com/install.sh | sh


echo "Generate and enter your Tailscale auth key: https://login.tailscale.com/admin/settings/keys"
read TAILSCALE_AUTH_KEY

if [ -z "$TAILSCALE_AUTH_KEY" ]; then
    echo "Error: Tailscale auth key is required."
    exit 1
fi

update_env_var "base/secrets/tailscale-secrets.env" "TAILSCALE_AUTH_KEY" "$TAILSCALE_AUTH_KEY"

curl -sfL https://get.k3s.io | sh -s - --disable=traefik --vpn-auth="name=tailscale,joinKey=${TAILSCALE_AUTH_KEY}";


echo "Enter your Tailscale network name (e.g. example.ts.net) from https://login.tailscale.com/admin/dns:"
read TAILSCALE_NET_NAME

if [ -z "$TAILSCALE_NET_NAME" ]; then
    echo "Error: Tailscale network name is required."
    exit 1
fi

update_env_var "base/properties/api-config.env" "TAILSCALE_NET_NAME" "$TAILSCALE_NODE_IP"


echo "Create A oAuth Client with the `devices` scope and from https://login.tailscale.com/admin/settings/oauth"

echo "Enter your Secret Key From the Step Above:"   
read TAILSCALE_SECRET_ID

if [ -z "$TAILSCALE_SECRET_ID" ]; then
    echo "Error: Tailscale secret key is required."
    exit 1
fi

update_env_var "base/secrets/tailscale-secrets.env" "TAILSCALE_SECRET_ID" "$TAILSCALE_SECRET_ID"

echo "Enter the Client ID from the Step Above:"   
read TAILSCALE_CLIENT_ID

if [ -z "$TAILSCALE_CLIENT_ID" ]; then
    echo "Error: Tailscale client ID is required."
    exit 1
fi

update_env_var "base/properties/api-config.env" "TAILSCALE_CLIENT_ID" "$TAILSCALE_CLIENT_ID"

echo "On the tailscale dashboard you should see your node come online, once it does enter the IP Address of the node:"
read TAILSCALE_NODE_IP

if [ -z "$TAILSCALE_NODE_IP" ]; then
    echo "Error: Tailscale node IP is required."
    exit 1
fi

update_env_var "base/properties/api-config.env" "TAILSCALE_NODE_IP" "$TAILSCALE_NODE_IP"

source update.sh "$@"