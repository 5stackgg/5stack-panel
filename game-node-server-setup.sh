#!/bin/bash

CYAN="\033[1;36m"
RED="\033[1;31m"
RESET="\033[0m"

source setup-env.sh "$@"

echo "Installing Game Node Server dependencies..."

curl -sfL https://tailscale.com/install.sh | sh

echo "Generate and enter your Tailscale auth key: https://login.tailscale.com/admin/settings/keys, make sure to select the \"Pre Approved\" option"

echo -e "${CYAN}Enter your Tailscale auth key:${RESET}"
read TAILSCALE_AUTH_KEY

while [ -z "$TAILSCALE_AUTH_KEY" ]; do
    echo "Tailscale auth key cannot be empty. Please enter your Tailscale auth key:"
    read TAILSCALE_AUTH_KEY
done

curl -sfL https://get.k3s.io | sh -s - --disable=traefik --vpn-auth="name=tailscale,joinKey=${TAILSCALE_AUTH_KEY}";


echo -e "${CYAN}Enter your Tailscale network name (e.g. example.ts.net) from https://login.tailscale.com/admin/dns:${RESET}"
read TAILSCALE_NET_NAME
while [ -z "$TAILSCALE_NET_NAME" ]; do
    echo "Tailscale network name cannot be empty. Please enter your Tailscale network name (e.g. example.ts.net):"
    read TAILSCALE_NET_NAME
done

update_env_var "overlays/config/api-config.env" "TAILSCALE_NET_NAME" "$TAILSCALE_NET_NAME"

echo -e "${RED}Create an OAuth Client with the Auth Keys (\`auth_keys\`) scope with write access from https://login.tailscale.com/admin/settings/oauth${RESET}"

echo -e "${CYAN}Enter your Secret Key from the step above:${RESET}"
read TAILSCALE_SECRET_ID
while [ -z "$TAILSCALE_SECRET_ID" ]; do
    echo "Tailscale secret key cannot be empty. Please enter your Tailscale secret key:"
    read TAILSCALE_SECRET_ID
done

update_env_var "overlays/local-secrets/tailscale-secrets.env" "TAILSCALE_SECRET_ID" "$TAILSCALE_SECRET_ID"

echo -e "${CYAN}Enter the Client ID from the Step Above:${RESET}"   
read TAILSCALE_CLIENT_ID
while [ -z "$TAILSCALE_CLIENT_ID" ]; do
    echo "Tailscale client ID cannot be empty. Please enter your Tailscale client ID:"
    read TAILSCALE_CLIENT_ID
done

update_env_var "overlays/config/api-config.env" "TAILSCALE_CLIENT_ID" "$TAILSCALE_CLIENT_ID"

echo -e "${CYAN}On the tailscale dashboard you should see your node come online, once it does enter the IP Address of the node:${RESET}"
read TAILSCALE_NODE_IP
while [ -z "$TAILSCALE_NODE_IP" ]; do
    echo "Tailscale node IP cannot be empty. Please enter your Tailscale node IP:"
    read TAILSCALE_NODE_IP
done

update_env_var "overlays/config/api-config.env" "TAILSCALE_NODE_IP" "$TAILSCALE_NODE_IP"

DEFAULT_TAG="fivestack"
DEFAULT_TAG_FULL="tag:${DEFAULT_TAG}"

echo -e "${CYAN}Enter the ACL tag you want to assign to this node."
echo -e "This tag must match one declared in your ACL file (e.g. ${DEFAULT_TAG_FULL})"
echo -e "If unsure, press Enter to use the secure default: ${DEFAULT_TAG_FULL}${RESET}"
read TAILSCALE_ACL_TAG

TAILSCALE_ACL_TAG="${TAILSCALE_ACL_TAG:-$DEFAULT_TAG_FULL}"

if [[ "$TAILSCALE_ACL_TAG" != tag:* ]]; then
  TAILSCALE_ACL_TAG="tag:$TAILSCALE_ACL_TAG"
fi

if [[ "$TAILSCALE_ACL_TAG" != "$DEFAULT_TAG_FULL" ]]; then
  echo -e "${YELLOW}⚠️  You entered a custom tag: ${TAILSCALE_ACL_TAG}${RESET}"
  echo -e "${YELLOW}   Make sure this tag exists in your ACL file and is assigned in the Tailscale dashboard.${RESET}"
fi

update_env_var "overlays/config/api-config.env" "TAILSCALE_ACL_TAG" "$TAILSCALE_ACL_TAG"

source update.sh "$@"