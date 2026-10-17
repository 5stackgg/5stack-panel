#!/bin/bash

# k3s's node-ip moves the kubelet (its serving certificate and the
# k3s.io/internal-ip annotation) but not the Node's InternalIP. The cloud-node
# controller only takes an address that matches alpha.kubernetes.io/provided-node-ip,
# and the kubelet writes that once, when the node first registers. A panel
# installed on its LAN IP and then moved to Tailscale by
# game-node-server-setup.sh kept its LAN InternalIP, which its kubelet's
# certificate no longer covers, so every exec, log stream and metrics scrape of
# that node failed with x509 errors.
ensure_node_ip() {
    local config="${K3S_CONFIG:-/etc/rancher/k3s/config.yaml}"
    local attempts="${NODE_IP_ATTEMPTS:-30}"
    local want attempt name internal provided

    want=$(sed -n 's/^node-ip:[[:space:]]*//p' "$config" 2>/dev/null | tail -n 1 | tr -d '\r')
    if [ -z "$want" ]; then
        return 0
    fi

    # Right after a restart k3s has not rewritten k3s.io/internal-ip yet, and
    # annotating before it has would name an address the node does not have.
    for ((attempt = 1; attempt <= attempts; attempt++)); do
        while IFS=$'\t' read -r name internal provided; do
            if [ "${internal%%,*}" != "${want%%,*}" ]; then
                continue
            fi
            if [ "$provided" = "$want" ]; then
                return 0
            fi
            if ! kubectl --kubeconfig="$KUBECONFIG" annotate node "$name" "alpha.kubernetes.io/provided-node-ip=$want" --overwrite >/dev/null; then
                warn "Could not move node $name to $want; kubectl exec, logs and metrics for it stay broken."
                return 0
            fi
            echo "Node $name moved to $want (was ${provided:-unset}); its InternalIP follows within 5 minutes."
            return 0
        done < <(kubectl --kubeconfig="$KUBECONFIG" get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.metadata.annotations.k3s\.io/internal-ip}{"\t"}{.metadata.annotations.alpha\.kubernetes\.io/provided-node-ip}{"\n"}{end}' 2>/dev/null)
        if [ "$attempt" -lt "$attempts" ]; then
            sleep 2
        fi
    done
    warn "No node reports the node-ip $want from $config yet; re-run ./update.sh once k3s is up."
}
