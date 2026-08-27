#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/utils/utils.sh" "$@"

# Nothing terminates TLS in the cluster in this mode, so any Certificate left
# over from a previous https install keeps retrying HTTP-01 against a server
# that no longer answers the challenge -- silently accumulating failed orders
# against Let's Encrypt's rate limit. watch_ssl_status is skipped below, so
# there is nothing to report it either.
if [ "$REVERSE_PROXY" = true ]; then
    for CERT in 5stack-ssl 5stack-mediamtx-ssl; do
        kubectl --kubeconfig=$KUBECONFIG delete certificate "$CERT" -n 5stack 2>/dev/null
    done
fi

if [ "$REVERSE_PROXY" != true ]; then
    step "Installing cert-manager"
    apply_overlay overlays/cert-manager-crds || die "failed to install cert-manager"

    for CRD in certificates.cert-manager.io issuers.cert-manager.io clusterissuers.cert-manager.io; do
        if ! output_redirect kubectl --kubeconfig=$KUBECONFIG wait --for=condition=Established "crd/$CRD" --timeout=120s; then
            die "cert-manager CRD $CRD never became established"
        fi
    done
    ok "cert-manager CRDs ready"

    # The CRDs are Established within a second of the apply, long before any
    # cert-manager pod is running -- which is exactly why this wait exists. The
    # overlay below carries the Certificate and the Issuer, and cert-manager's
    # admission webhook rejects both outright while it is still starting.
    step "Waiting for cert-manager"
    wait_for_cert_manager || die "cert-manager did not become ready; re-run ./update.sh once it settles"
    ok "cert-manager is ready"
fi

step "Building overlay manifests"
HTTP_REPLACEMENTS="$PANEL_DIR/overlays/http/http-replacements.yaml"
HTTPS_REPLACEMENTS="$PANEL_DIR/overlays/http/https-replacements.yaml"

# Whether an operator has asked for a TURN relay at all. Read straight from
# coturn's own env file rather than the environment: this is the same file the
# generated ConfigMap is built from, so the two can never disagree.
TURN_DOMAIN="$(grep -s '^TURN_DOMAIN=' "$PANEL_DIR/overlays/coturn/coturn.env" | tail -1 | cut -d= -f2- | tr -d '\r')"
TURN_DOMAIN="${TURN_DOMAIN%\"}"
TURN_DOMAIN="${TURN_DOMAIN#\"}"

OVERLAY_BASES=("vault" "local-secrets")
for BASE in "${OVERLAY_BASES[@]}"; do
    for PROTOCOL in "http" "https"; do
        OVERLAY="overlays/${BASE}-${PROTOCOL}"
        mkdir -p "$OVERLAY"
        # MediaMTX is a WebRTC relay, not an encoder, and it now also carries
        # player cameras — which have nothing to do with GPU game streaming.
        # Only the nvidia device plugin stays GPU-gated.
        STREAMING_RESOURCES="$(if [[ "$PROTOCOL" == "https" ]]; then echo "- ../mediamtx-https"; else echo "- ../mediamtx"; fi)"
        # The TURN relay is opt-in and most installs never need one: WebRTC
        # connects directly for the large majority of players, and STUN covers
        # most of the rest. Deployed only once TURN_DOMAIN is set, so nobody
        # ends up running a relay -- on hostNetwork, holding port 3478 -- that
        # they never asked for. It has no http/https split: it speaks TURN, not
        # HTTP, and the media it relays is already DTLS-encrypted end to end.
        if [ -n "$TURN_DOMAIN" ]; then
            STREAMING_RESOURCES="$STREAMING_RESOURCES
- ../coturn"
        fi
        if [ "$GPU_VENDOR" = "nvidia" ]; then
            STREAMING_RESOURCES="- ../nvidia
$STREAMING_RESOURCES"
        fi

        cat > "$OVERLAY/kustomization.yaml" <<EOF
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
- ../$BASE
- ../config
$STREAMING_RESOURCES
$(if [[ "$PROTOCOL" == "https" ]]; then echo "- ../cert-manager"; fi)
EOF
        if [ "$PROTOCOL" = "https" ]; then
            cp overlays/http/ingress-patch.yaml "$OVERLAY/ingress-patch.yaml"
            cat "$HTTPS_REPLACEMENTS" >> "$OVERLAY/kustomization.yaml"
        else
            cat "$HTTP_REPLACEMENTS" >> "$OVERLAY/kustomization.yaml"
        fi
    done
done
ok "overlays generated"

step "Applying kustomize overlay"
if [ "$VAULT_MANAGER" = true ]; then
    OVERLAY_BASE="vault"
else
    OVERLAY_BASE="local-secrets"
fi

if [ "$REVERSE_PROXY" = true ]; then
    OVERLAY="overlays/${OVERLAY_BASE}-http"
else
    OVERLAY="overlays/${OVERLAY_BASE}-https"
fi

apply_overlay "$OVERLAY" || die "failed to apply $OVERLAY"
ok "overlay applied"

# Strictly after the apply: it is the apply that removes the cert-manager.io/issuer
# annotation from the ingresses, and until that lands ingress-shim recreates an
# Ingress-owned Certificate as fast as we can let go of one.
if [ "$REVERSE_PROXY" != true ]; then
    disown_shim_owned_certificates
fi

if [ "$VAULT_MANAGER" = true ]; then
    step "Syncing Vault secrets"
    if ! resync_vault_secrets; then
        exit 1
    fi
fi

step "Recycling stateful workloads"
kubectl --kubeconfig=$KUBECONFIG delete deployment minio -n 5stack 2>/dev/null
kubectl --kubeconfig=$KUBECONFIG delete deployment timescaledb -n 5stack  2>/dev/null
kubectl --kubeconfig=$KUBECONFIG delete deployment typesense -n 5stack  2>/dev/null
kubectl --kubeconfig=$KUBECONFIG delete deployment redis -n 5stack  2>/dev/null

GIT_SHA=$(git rev-parse HEAD)

kubectl --kubeconfig=$KUBECONFIG label node $(kubectl --kubeconfig=$KUBECONFIG get nodes --selector='node-role.kubernetes.io/control-plane' -o jsonpath='{.items[0].metadata.name}') 5stack-panel-version=$GIT_SHA --overwrite

# Must track the mediamtx overlay above: the deployment's node affinity is
# requiredDuringScheduling, so without this label the pod never schedules.
kubectl --kubeconfig=$KUBECONFIG label node $(kubectl --kubeconfig=$KUBECONFIG get nodes --selector='node-role.kubernetes.io/control-plane' -o jsonpath='{.items[0].metadata.name}') 5stack-mediamtx=true --overwrite

if [ -n "$TURN_DOMAIN" ]; then
    kubectl --kubeconfig=$KUBECONFIG label node $(kubectl --kubeconfig=$KUBECONFIG get nodes --selector='node-role.kubernetes.io/control-plane' -o jsonpath='{.items[0].metadata.name}') 5stack-coturn=true --overwrite
fi

SSL_OK=true
if [ "$REVERSE_PROXY" != true ]; then
    watch_ssl_status || SSL_OK=false
fi

if [ "$SSL_OK" != true ]; then
    banner "5Stack : Updated (SSL incomplete)"
    # install.sh and game-node-server-setup.sh source this file, and an `exit`
    # here would take them down with it -- suppressing the install banner and,
    # on a game node, the Tailscale IP the operator needs to finish joining it.
    # The cluster work all succeeded; only issuance is outstanding. So report a
    # non-zero status when update.sh is what was run, and let a caller finish
    # its own output otherwise.
    if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
        exit 1
    fi
    return 1
fi

banner "5Stack : Updated"
