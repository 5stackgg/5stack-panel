#!/bin/bash

PANEL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$PANEL_DIR/utils/utils.sh" "$@"

if [ "$REVERSE_PROXY" = true ]; then
    die "this install terminates TLS at a reverse proxy; there is no certificate for 5Stack to issue"
fi

# Deleting every Ingress in the namespace was the old repair here. It worked by
# accident: the Certificate cert-manager's ingress-shim had created was owned by
# an Ingress, so removing the Ingresses garbage-collected it and let update.sh
# lay down the correct one. The shim annotation is gone now, so clear out the
# stuck resources directly -- no downtime, and no ingress recreation to wait on.
step "Clearing stuck certificate resources"

prune_shim_owned_certificates

# Failed orders and challenges are not retried on their own once the order has
# reached a terminal state; the Certificate has to be re-issued to make a new
# one. Only touch certificates that aren't currently valid, so a healthy cert is
# never thrown away (and never re-requested against Let's Encrypt's rate limit).
CERTS=$(kubectl --kubeconfig=$KUBECONFIG get certificates.cert-manager.io -n 5stack \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' 2>/dev/null)

while IFS=$'\t' read -r NAME STATUS; do
    [ -z "$NAME" ] && continue
    if [ "$STATUS" = "True" ]; then
        ok "$NAME is valid, leaving it alone"
        continue
    fi
    warn "$NAME is not valid, requesting a new certificate"
    # The Secret is intentionally kept: nginx keeps serving whatever it has
    # while the replacement is issued.
    output_redirect kubectl --kubeconfig=$KUBECONFIG delete certificate "$NAME" -n 5stack
done <<< "$CERTS"

output_redirect kubectl --kubeconfig=$KUBECONFIG delete orders.acme.cert-manager.io --all -n 5stack 2>/dev/null
output_redirect kubectl --kubeconfig=$KUBECONFIG delete challenges.acme.cert-manager.io --all -n 5stack 2>/dev/null
ok "cleared"

source "$PANEL_DIR/update.sh" "$@"
