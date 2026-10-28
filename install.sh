#!/bin/bash

PANEL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$PANEL_DIR/utils/utils.sh" "$@"
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
# Downloaded to a file rather than piped into sh. `curl ... | sh` reports only
# sh's status, and sh handed an empty script exits 0 -- so an unreachable
# get.k3s.io looked like a successful install, and the failure surfaced much
# later as every kubectl call failing against a cluster that was never created.
K3S_INSTALLER="$(mktemp)"
trap 'rm -f "$K3S_INSTALLER"' EXIT
if ! curl -sfL https://get.k3s.io -o "$K3S_INSTALLER"; then
    die "could not download the k3s installer from https://get.k3s.io"
fi
if ! sh "$K3S_INSTALLER" --disable=traefik; then
    die "k3s install failed"
fi
rm -f "$K3S_INSTALLER"
trap - EXIT
ok "k3s installed"

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

# Also what holds the node labels below back until k3s has registered its
# node: Traefik is not Ready before it is scheduled on one.
step "Installing Traefik (this may take a few minutes)"
install_traefik || die "Traefik install failed"
ok "Traefik installed"

kubectl label node $(kubectl get nodes -o jsonpath='{.items[0].metadata.name}') 5stack-api=true 5stack-hasura=true 5stack-minio=true 5stack-rustfs=true 5stack-timescaledb=true 5stack-redis=true 5stack-typesense=true 5stack-web=true

source "$PANEL_DIR/update.sh" "$@"

banner "5Stack installed"
