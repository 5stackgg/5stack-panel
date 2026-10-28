#!/bin/bash

# Writes overlays/{vault,local-secrets}-{http,https}, of which update.sh applies
# the one REVERSE_PROXY and VAULT_MANAGER select. Reads TURN_DOMAIN and
# GPU_VENDOR.
write_overlays() {
    local BASE PROTOCOL OVERLAY STREAMING_RESOURCES
    for BASE in vault local-secrets; do
        for PROTOCOL in "http" "https"; do
            OVERLAY="$PANEL_DIR/overlays/${BASE}-${PROTOCOL}"
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
$(if [[ "$PROTOCOL" == "https" ]]; then echo "- ../cert-manager"; echo "- https-redirect.yaml"; fi)
EOF
            if [ "$PROTOCOL" = "https" ]; then
                cp "$PANEL_DIR/overlays/http/gateway-https-patch.yaml" "$PANEL_DIR/overlays/http/https-redirect.yaml" "$OVERLAY/"
                cat "$PANEL_DIR/overlays/http/https-replacements.yaml" >> "$OVERLAY/kustomization.yaml"
            else
                cat "$PANEL_DIR/overlays/http/http-replacements.yaml" >> "$OVERLAY/kustomization.yaml"
            fi
        done
    done
}
