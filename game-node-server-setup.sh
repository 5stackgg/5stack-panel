#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/utils/utils.sh" "$@"
check_sudo

if ! command -v jq &> /dev/null; then
    err "jq is not installed. Please install it first."
    exit 1
fi

step "Installing tailscale"
curl -sfL https://tailscale.com/install.sh | sh

banner "Tailscale OAuth Setup Required"
echo "    This script automates Tailscale configuration using OAuth API."
echo
echo "    ${C_STEP}1.${C_RESET} Create Access Control Tag at:"
echo "       ${C_OK}https://login.tailscale.com/admin/acls/visual/tags/add${C_RESET}"
echo "       Required tag: ${C_OK}fivestack${C_RESET}"
echo
echo "    ${C_STEP}2.${C_RESET} Create an OAuth Client at:"
echo "       ${C_OK}https://login.tailscale.com/admin/settings/trust-credentials/add${C_RESET}"
echo "       OAuth scopes:"
echo "         - General: ${C_OK}Policy File (write)${C_RESET}"
echo "         - Keys : ${C_OK}Auth Keys (write)${C_RESET}"
echo "       Required tag: ${C_OK}fivestack${C_RESET}"
echo
echo "    ${C_STEP}3.${C_RESET} After creating the OAuth client, you'll receive:"
echo "         - Client ID"
echo "         - Client Secret ${C_WARN}(shown only once!)${C_RESET}"
echo

echo -e "${C_STEP}Enter your Tailscale OAuth Client ID:${C_RESET}"
read TAILSCALE_CLIENT_ID
while [ -z "$TAILSCALE_CLIENT_ID" ]; do
    warn "Client ID cannot be empty. Please enter your OAuth Client ID:"
    read TAILSCALE_CLIENT_ID
done

echo -e "${C_STEP}Enter your Tailscale OAuth Client Secret:${C_RESET}"
read -s TAILSCALE_CLIENT_SECRET
echo
while [ -z "$TAILSCALE_CLIENT_SECRET" ]; do
    warn "Client Secret cannot be empty. Please enter your OAuth Client Secret (when pasting it will not show for security reasons):"
    read -s TAILSCALE_CLIENT_SECRET
    echo
done

step "Authenticating with Tailscale API"
ACCESS_TOKEN=$(get_oauth_token "$TAILSCALE_CLIENT_ID" "$TAILSCALE_CLIENT_SECRET")

if [ -z "$ACCESS_TOKEN" ]; then
    err "Failed to authenticate with Tailscale. Please check your OAuth credentials."
    exit 1
fi
ok "authenticated"

update_env_var "overlays/config/api-config.env" "TAILSCALE_CLIENT_ID" "$TAILSCALE_CLIENT_ID"
update_env_var "overlays/local-secrets/tailscale-secrets.env" "TAILSCALE_SECRET_ID" "$TAILSCALE_CLIENT_SECRET"

step "Configuring ACL rules for fivestack tag"
update_acl_for_fivestack "$ACCESS_TOKEN"

if [ $? -eq 0 ]; then
    ok "ACL configured (10.42.0.0/16 subnet with auto-approvers)"
else
    warn "ACL configuration failed. You may need to configure ACL manually."
fi

step "Generating pre-approved auth key"
TAILSCALE_AUTH_KEY=$(create_auth_key "$ACCESS_TOKEN")

if [ -z "$TAILSCALE_AUTH_KEY" ]; then
    err "Failed to generate auth key."
    exit 1
fi
ok "auth key generated"

step "Joining tailscale network"
tailscale up --authkey=$TAILSCALE_AUTH_KEY --accept-routes

step "Waiting for tailscale IP"
for i in {1..60}; do
    TAILSCALE_NODE_IP=$(tailscale ip -4 2>/dev/null | head -n 1)
    if [ -n "$TAILSCALE_NODE_IP" ]; then
        break
    fi
    sleep 2
done

if [ -z "$TAILSCALE_NODE_IP" ]; then
    if [ ! -t 0 ] && [ ! -e /dev/tty ]; then
        err "Failed to get Tailscale IP after 2 minutes and no terminal available for manual entry."
        err "Check tailscale status with: tailscale status"
        exit 1
    fi
    warn "Failed to get Tailscale IP automatically."
    warn "Please check the Tailscale dashboard and manually enter the node IP."
    warn "https://login.tailscale.com/admin/machines"
    while true; do
        echo -e "${C_STEP}Enter the Tailscale node IP address:${C_RESET}"
        read TAILSCALE_NODE_IP </dev/tty
        if [ -n "$TAILSCALE_NODE_IP" ]; then
            break
        fi
        warn "Node IP cannot be empty. Please enter the Tailscale node IP:"
    done
fi
ok "tailscale IP: $TAILSCALE_NODE_IP"

update_env_var "overlays/config/api-config.env" "TAILSCALE_NODE_IP" "$TAILSCALE_NODE_IP"

step "Configuring kernel IP forwarding"
if [ -d "/etc/sysctl.d" ]; then
  if ! grep -q "^net.ipv4.ip_forward = 1" /etc/sysctl.d/99-tailscale.conf 2>/dev/null; then
    echo 'net.ipv4.ip_forward = 1' | sudo tee -a /etc/sysctl.d/99-tailscale.conf >/dev/null
  fi
  if ! grep -q "^net.ipv6.conf.all.forwarding = 1" /etc/sysctl.d/99-tailscale.conf 2>/dev/null; then
    echo 'net.ipv6.conf.all.forwarding = 1' | sudo tee -a /etc/sysctl.d/99-tailscale.conf >/dev/null
  fi
  sudo sysctl -p /etc/sysctl.d/99-tailscale.conf >/dev/null
else
  if ! grep -q "^net.ipv4.ip_forward = 1" /etc/sysctl.conf; then
    echo 'net.ipv4.ip_forward = 1' | sudo tee -a /etc/sysctl.conf >/dev/null
  fi
  if ! grep -q "^net.ipv6.conf.all.forwarding = 1" /etc/sysctl.conf; then
    echo 'net.ipv6.conf.all.forwarding = 1' | sudo tee -a /etc/sysctl.conf >/dev/null
  fi
  sudo sysctl -p /etc/sysctl.conf >/dev/null
fi
ok "ip forwarding enabled"

step "Writing systemd helper scripts"
cat <<-'SCRIPT' >/usr/local/bin/5stack-tailscale-state-check.sh
	#!/bin/bash
	command -v tailscale >/dev/null 2>&1 || exit 0

	check_health() {
	  local status backend health_count
	  status=$(tailscale status --json 2>/dev/null) || return 1
	  backend=$(echo "$status" | jq -r '.BackendState // "Unknown"')
	  health_count=$(echo "$status" | jq -r '.Health | length')
	  [ "$backend" = "Running" ] && [ "$health_count" -eq 0 ]
	}

	if check_health; then
	  exit 0
	fi

	STATUS=$(tailscale status --json 2>/dev/null)
	BACKEND=$(echo "$STATUS" | jq -r '.BackendState // "Unknown"')
	HEALTH=$(echo "$STATUS" | jq -rc '.Health // []')
	echo "[5stack] tailscale unhealthy (BackendState=$BACKEND, Health=$HEALTH), restarting tailscaled"
	systemctl restart tailscaled

	for i in {1..15}; do
	  sleep 2
	  if check_health; then
	    echo "[5stack] tailscale recovered after restart"
	    exit 0
	  fi
	done

	echo "[5stack] tailscale still unhealthy after restart"
	exit 0
SCRIPT
ok "helper scripts written"

step "Installing k3s"
curl -sfL https://get.k3s.io | sh -s - --disable=traefik --vpn-auth="name=tailscale,joinKey=${TAILSCALE_AUTH_KEY}"

step "Writing k3s config"
mkdir -p /etc/rancher/k3s
cat <<-EOF >/etc/rancher/k3s/config.yaml
	node-ip: $TAILSCALE_NODE_IP
EOF
ok "node-ip set to $TAILSCALE_NODE_IP"

step "Installing systemd drop-ins and timer"
chmod +x /usr/local/bin/5stack-tailscale-state-check.sh

rm -f /etc/systemd/system/k3s.service.d/update-tailscale-ip.conf
rm -f /etc/systemd/system/k3s.service.d/tailscale-state-check.conf

cat <<-'DROPIN' >/etc/systemd/system/k3s.service.d/update-tailscale-ip.conf
	[Service]
	ExecStartPre=/bin/bash -c 'TSIP=$(tailscale ip -4 2>/dev/null | head -n 1); if [ -n "$TSIP" ] && [ -f /etc/rancher/k3s/config.yaml ]; then sed -i "s/^node-ip:.*/node-ip: $TSIP/" /etc/rancher/k3s/config.yaml; echo "[5stack] Updated k3s node-ip to $TSIP"; fi'
DROPIN

cat <<-'DROPIN' >/etc/systemd/system/k3s.service.d/tailscale-state-check.conf
	[Service]
	ExecStartPre=/usr/local/bin/5stack-tailscale-state-check.sh
DROPIN

cat <<-'UNIT' >/etc/systemd/system/5stack-tailscale-state-check.service
	[Unit]
	Description=5stack tailscale state check
	After=tailscaled.service
	Wants=tailscaled.service

	[Service]
	Type=oneshot
	ExecStart=/usr/local/bin/5stack-tailscale-state-check.sh
UNIT

cat <<-'UNIT' >/etc/systemd/system/5stack-tailscale-state-check.timer
	[Unit]
	Description=Run 5stack tailscale state check every 5 minutes

	[Timer]
	OnBootSec=2min
	OnUnitActiveSec=5min
	Unit=5stack-tailscale-state-check.service

	[Install]
	WantedBy=timers.target
UNIT

systemctl daemon-reload
systemctl enable --now 5stack-tailscale-state-check.timer >/dev/null 2>&1
ok "drop-ins installed, periodic tailscale check enabled"

step "Restarting k3s"
systemctl restart k3s
ok "k3s restarted"

source update.sh "$@"

banner "Game node server setup complete"
echo "  Tailscale IP: $TAILSCALE_NODE_IP"
echo
