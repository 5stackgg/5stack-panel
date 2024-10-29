#!/bin/bash

source setup-env.sh "$@"

echo "Installing Tailscale ..."
curl -sfL https://tailscale.com/install.sh | sh


echo "Generate and enter your Tailscale auth key: https://login.tailscale.com/admin/settings/keys"

echo "Enter your Tailscale auth key:"
while [ -z "$TAILSCALE_AUTH_KEY" ]; do
    echo "Tailscale auth key cannot be empty. Please enter your Tailscale auth key:"
    read TAILSCALE_AUTH_KEY
done

update_env_var "base/secrets/tailscale-secrets.env" "TAILSCALE_AUTH_KEY" "$TAILSCALE_AUTH_KEY"

curl -sfL https://get.k3s.io | sh -s - --disable=traefik --vpn-auth="name=tailscale,joinKey=${TAILSCALE_AUTH_KEY}";


echo "Enter your Tailscale network name (e.g. example.ts.net) from https://login.tailscale.com/admin/dns:"

while [ -z "$TAILSCALE_NET_NAME" ]; do
    echo "Tailscale network name cannot be empty. Please enter your Tailscale network name (e.g. example.ts.net):"
    read TAILSCALE_NET_NAME
done

update_env_var "base/properties/api-config.env" "TAILSCALE_NET_NAME" "$TAILSCALE_NODE_IP"


echo "Create A oAuth Client with the `devices` scope and from https://login.tailscale.com/admin/settings/oauth"

echo "Enter your Secret Key From the Step Above:"   
while [ -z "$TAILSCALE_SECRET_ID" ]; do
    echo "Tailscale secret key cannot be empty. Please enter your Tailscale secret key:"
    read TAILSCALE_SECRET_ID
done

update_env_var "base/secrets/tailscale-secrets.env" "TAILSCALE_SECRET_ID" "$TAILSCALE_SECRET_ID"

echo "Enter the Client ID from the Step Above:"   
while [ -z "$TAILSCALE_CLIENT_ID" ]; do
    echo "Tailscale client ID cannot be empty. Please enter your Tailscale client ID:"
    read TAILSCALE_CLIENT_ID
done

update_env_var "base/properties/api-config.env" "TAILSCALE_CLIENT_ID" "$TAILSCALE_CLIENT_ID"

echo "On the tailscale dashboard you should see your node come online, once it does enter the IP Address of the node:"
while [ -z "$TAILSCALE_NODE_IP" ]; do
    echo "Tailscale node IP cannot be empty. Please enter your Tailscale node IP:"
    read TAILSCALE_NODE_IP
done

update_env_var "base/properties/api-config.env" "TAILSCALE_NODE_IP" "$TAILSCALE_NODE_IP"

source update.sh "$@"