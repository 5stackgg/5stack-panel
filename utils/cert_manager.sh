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
    # Per-deployment, not a shared budget. The three roll out in sequence and
    # the first one pulls the largest image, so a single deadline spanning all
    # of them lets a slow pull starve the later waits down to nothing -- and
    # `rollout status --timeout=1s` fails instantly, killing an install that
    # was seconds from ready.
    local per_deployment="${1:-300}"
    local deployment probe

    for deployment in cert-manager cert-manager-cainjector cert-manager-webhook; do
        # Deliberately not redirected: this is a first-install image pull that
        # can take minutes, and `rollout status` narrating it is the only thing
        # standing between the operator and a silent hang.
        if ! kubectl --kubeconfig="$KUBECONFIG" -n cert-manager \
            rollout status "deployment/$deployment" --timeout="${per_deployment}s"; then
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

    # --dry-run=server runs full admission without persisting anything, so this
    # proves the webhook will accept the real Certificate and Issuer.
    if ! wait_for_webhook "cert-manager admission webhook" "$probe" "$per_deployment"; then
        kubectl --kubeconfig="$KUBECONFIG" -n cert-manager get pods >&2
        return 1
    fi
}

# Every Certificate in the namespace with its Ready status and message, tab
# separated. Shared by watch_ssl_status and fix-ssl.sh so the query, and any
# future addition to it, lives in one place.
list_certificate_status() {
    kubectl --kubeconfig="$KUBECONFIG" get certificates.cert-manager.io -n 5stack \
        -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.conditions[?(@.type=="Ready")].status}{"\t"}{.status.conditions[?(@.type=="Ready")].message}{"\n"}{end}' 2>/dev/null
}

# cert-manager's ingress-shim names the Certificate it creates after the
# Ingress' TLS secretName, so every 5stack Ingress pointing at `5stack-ssl`
# was competing to own a single Certificate -- against each other and against
# the one we declare in overlays/cert-manager. Whichever won defined the cert,
# and a shim-created one only ever carries the single host of the Ingress that
# made it, which is how an install ends up "valid" but serving the wrong name
# on six of seven domains.
#
# The ownerReference is what makes this dangerous rather than merely untidy: it
# marks the Certificate as garbage collectable, so deleting or renaming that one
# Ingress takes the panel's TLS with it.
#
# Dropping the reference is enough, and it is what we want rather than deleting
# the Certificate:
#
#   - Deleting it and letting the overlay recreate it costs a full ACME
#     issuance against Let's Encrypt's duplicate-certificate limit, every run.
#   - This must run *after* the apply that removes the shim annotation from the
#     Ingresses. Delete it before that and the shim simply recreates it, owned
#     all over again -- and `kubectl apply` never strips an ownerReference it
#     did not set, so the object stays owned forever.
#
# By the time this runs the apply has already corrected the spec to the full
# host list, so cert-manager re-issues on its own; all that is left is to cut
# the object loose from the Ingress.
disown_shim_owned_certificates() {
    local name owner certs

    # Any Certificate owned by an Ingress, not a hardcoded pair of names:
    # plugins can add their own Certificates to this namespace, and every new
    # TLS host we add would otherwise have to be remembered here.
    certs="$(kubectl --kubeconfig="$KUBECONFIG" get certificates.cert-manager.io -n 5stack \
        -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.metadata.ownerReferences[?(@.kind=="Ingress")].name}{"\n"}{end}' 2>/dev/null)"

    while IFS=$'\t' read -r name owner; do
        if [ -z "$name" ] || [ -z "$owner" ]; then
            continue
        fi
        warn "certificate $name is owned by ingress '$owner' (only covers one host); releasing it"
        # Removing the array rather than one entry: ingress-shim sets exactly
        # one ownerReference, and a Certificate we declare ourselves has none.
        output_redirect kubectl --kubeconfig="$KUBECONFIG" patch certificate "$name" -n 5stack \
            --type=json -p '[{"op": "remove", "path": "/metadata/ownerReferences"}]'
    done <<< "$certs"
}
