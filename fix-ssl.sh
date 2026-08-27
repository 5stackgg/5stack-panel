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

# Failed orders and challenges are not retried on their own once the order has
# reached a terminal state; the Certificate has to be re-issued to make a new
# one. Only touch certificates that aren't currently valid, so a healthy cert is
# never thrown away (and never re-requested against Let's Encrypt's rate limit).
CERTS="$(list_certificate_status)"

CLEARED=0
while IFS=$'\t' read -r NAME STATUS _; do
    [ -z "$NAME" ] && continue
    if [ "$STATUS" = "True" ]; then
        ok "$NAME is valid, leaving it alone"
        continue
    fi
    warn "$NAME is not valid, requesting a new certificate"
    # The Secret is intentionally kept: nginx keeps serving whatever it has
    # while the replacement is issued.
    output_redirect kubectl --kubeconfig=$KUBECONFIG delete certificate "$NAME" -n 5stack

    # Scoped to this certificate, never `--all`. A certificate that is valid but
    # inside its renewBefore window has a live Order and Challenge for the
    # renewal, and deleting those restarts it from scratch -- a fresh ACME order
    # against exactly the rate limit the check above exists to protect.
    #
    # Deleting the Certificate already cascades to its CertificateRequest, Order
    # and Challenge through ownerReferences; this only sweeps up any that were
    # orphaned by an earlier run.
    for RESOURCE in orders.acme.cert-manager.io challenges.acme.cert-manager.io; do
        output_redirect kubectl --kubeconfig=$KUBECONFIG delete "$RESOURCE" -n 5stack \
            -l "cert-manager.io/certificate-name=$NAME" 2>/dev/null
    done
    CLEARED=$((CLEARED + 1))
done <<< "$CERTS"

if [ "$CLEARED" -eq 0 ]; then
    ok "nothing to clear"
else
    ok "cleared $CLEARED certificate(s)"
fi

source "$PANEL_DIR/update.sh" "$@"
