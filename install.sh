#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/utils/utils.sh" "$@"
check_sudo

step "Setting up filesystem"
mkdir -p /opt/5stack/dev
mkdir -p /opt/5stack/demos
mkdir -p /opt/5stack/steamcmd
mkdir -p /opt/5stack/serverfiles
mkdir -p /opt/5stack/serverfiles-csgo
mkdir -p /opt/5stack/timescaledb
mkdir -p /opt/5stack/typesense
mkdir -p /opt/5stack/minio
mkdir -p /opt/5stack/custom-plugins
ok "directories created"

step "Installing k3s"
curl -sfL https://get.k3s.io | sh -s - --disable=traefik

step "Writing systemd helper scripts"
cat <<-'SCRIPT' >/usr/local/bin/5stack-cpu-state-check.sh
	#!/bin/bash
	STATE=/var/lib/kubelet/cpu_manager_state
	[ ! -f "$STATE" ] && exit 0
	CACHE="$(dirname "$STATE")/cpu_count"
	CURRENT=$(nproc)
	PREVIOUS=$(cat "$CACHE" 2>/dev/null || echo "$CURRENT")
	if [ "$CURRENT" != "$PREVIOUS" ]; then
	  echo "CPU count changed from $PREVIOUS to $CURRENT, removing $STATE"
	  rm -f "$STATE"
	fi
	echo "$CURRENT" > "$CACHE"
SCRIPT
chmod +x /usr/local/bin/5stack-cpu-state-check.sh
ok "helper scripts written"

step "Installing systemd drop-ins"
mkdir -p /etc/systemd/system/k3s.service.d

cat <<-'DROPIN' >/etc/systemd/system/k3s.service.d/cpu-state-check.conf
	[Service]
	ExecStartPre=/usr/local/bin/5stack-cpu-state-check.sh
DROPIN

systemctl daemon-reload
ok "drop-ins installed"

step "Installing Ingress Nginx (this may take a few minutes)"
install_ingress_nginx true
ok "ingress-nginx installed"

kubectl label node $(kubectl get nodes -o jsonpath='{.items[0].metadata.name}') 5stack-api=true 5stack-hasura=true 5stack-minio=true 5stack-timescaledb=true 5stack-redis=true 5stack-typesense=true 5stack-web=true

source update.sh "$@"

banner "5Stack installed"
