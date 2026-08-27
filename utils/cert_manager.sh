#!/bin/bash

# cert-manager guards every cert-manager.io/acme.cert-manager.io write with an
# admission webhook whose failurePolicy is Fail. Until that webhook is serving
# *and* cainjector has published the CA bundle the API server needs to trust
# it, creating a Certificate or an Issuer is rejected outright -- it is not
# queued and retried later. Applying the overlay seconds after the cert-manager
# manifests land (image pulls alone take 30-90s on a fresh box) therefore drops
# our Certificate and Issuer on the floor.
#
# Waiting for the CRDs to be Established is not enough: that happens within a
# second of the apply, long before any cert-manager pod is running. A
# server-side dry run is the only check that exercises the whole path -- the
# webhook endpoint, its serving certificate, and the injected CA bundle -- so
# that is what we poll on.
wait_for_cert_manager() {
    local timeout="${1:-600}"
    local deadline=$((SECONDS + timeout))
    local deployment remaining probe output

    for deployment in cert-manager cert-manager-cainjector cert-manager-webhook; do
        remaining=$((deadline - SECONDS))
        [ "$remaining" -lt 1 ] && remaining=1
        # Deliberately not redirected: this is a first-install image pull that
        # can take minutes, and `rollout status` narrating it is the only thing
        # standing between the operator and a silent hang.
        if ! kubectl --kubeconfig="$KUBECONFIG" -n cert-manager \
            rollout status "deployment/$deployment" --timeout="${remaining}s"; then
            err "cert-manager: deployment/$deployment never became ready"
            kubectl --kubeconfig="$KUBECONFIG" -n cert-manager get pods >&2
            return 1
        fi
    done

    probe="$(cat <<'YAML'
apiVersion: cert-manager.io/v1
kind: Issuer
metadata:
  name: 5stack-webhook-probe
  namespace: cert-manager
spec:
  selfSigned: {}
YAML
)"

    echo "Waiting for the cert-manager admission webhook to accept resources..."
    while true; do
        # --dry-run=server runs full admission without persisting anything, so
        # this proves the webhook will accept the real Certificate and Issuer.
        # A rejection of the probe itself would still prove the webhook is
        # answering; only a webhook that isn't there yet is worth waiting on.
        if output="$(echo "$probe" | kubectl --kubeconfig="$KUBECONFIG" \
            apply --dry-run=server -f - 2>&1)" \
            || ! webhook_unavailable_error "$output"; then
            return 0
        fi

        if [ "$SECONDS" -ge "$deadline" ]; then
            err "cert-manager admission webhook is not accepting resources after ${timeout}s:"
            echo "$output" | sed 's/^/    /' >&2
            kubectl --kubeconfig="$KUBECONFIG" -n cert-manager get pods >&2
            return 1
        fi

        sleep 5
    done
}

# cert-manager's ingress-shim names the Certificate it creates after the
# Ingress' TLS secretName, so every 5stack Ingress pointing at `5stack-ssl`
# was competing to own a single Certificate -- against each other and against
# the one we declare in overlays/cert-manager. Whichever won defined the cert,
# and a shim-created one only ever carries the single host of the Ingress that
# made it, which is how an install ends up "valid" but serving the wrong name
# on six of seven domains. The annotation that caused this is gone from the
# ingress patch; clear out anything it left behind so the declared Certificate
# is the one that gets renewed.
#
# The Secret is deliberately left alone: nginx keeps serving the existing
# certificate while the replacement is issued, so this costs no downtime.
prune_shim_owned_certificates() {
    local name owner

    for name in 5stack-ssl 5stack-mediamtx-ssl; do
        owner="$(kubectl --kubeconfig="$KUBECONFIG" get certificate "$name" -n 5stack \
            -o jsonpath='{.metadata.ownerReferences[?(@.kind=="Ingress")].name}' 2>/dev/null)"
        if [ -n "$owner" ]; then
            warn "certificate $name is owned by ingress '$owner' (only covers one host); replacing it"
            output_redirect kubectl --kubeconfig="$KUBECONFIG" delete certificate "$name" -n 5stack
        fi
    done
}
