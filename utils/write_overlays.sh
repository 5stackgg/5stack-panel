#!/bin/bash

# The self-signed certificate 5stack-tls answers on in a REVERSE_PROXY install
# (overlays/http/gateway-tls.yaml). Kept, so an update changes nothing, until
# it's within 30 days of expiring or unreadable; the proxy in front doesn't
# check it, as it didn't ingress-nginx's.
ensure_reverse_proxy_certificate() {
    local dir="$1"
    if [ -s "$dir/reverse-proxy-tls.key" ] &&
        openssl x509 -noout -checkend 2592000 -in "$dir/reverse-proxy-tls.crt" >/dev/null 2>&1; then
        return 0
    fi
    (
        umask 077
        openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj "/CN=5stack" \
            -keyout "$dir/reverse-proxy-tls.key" -out "$dir/reverse-proxy-tls.crt" >/dev/null 2>&1
    ) || {
        rm -f "$dir/reverse-proxy-tls.key" "$dir/reverse-proxy-tls.crt"
        echo "could not make the reverse proxy's upstream certificate; is openssl installed?" >&2
        return 1
    }
}

# Writes overlays/{vault,local-secrets}-{http,https}, of which update.sh applies
# the one REVERSE_PROXY and VAULT_MANAGER select. Reads TURN_DOMAIN,
# GPU_VENDOR and AI_ENABLED.
write_overlays() {
    local BASE PROTOCOL OVERLAY STREAMING_RESOURCES AI_RESOURCES
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
            # Rokkan, the AI service, is 5Stack's own and its image is private.
            # Vault only: its secrets and the image pull secret are ExternalSecrets.
            AI_RESOURCES=""
            if [ "$AI_ENABLED" = true ] && [ "$BASE" = "vault" ]; then
                AI_RESOURCES="- ../ai"
            fi

            cat > "$OVERLAY/kustomization.yaml" <<EOF
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
- ../$BASE
- ../config
$STREAMING_RESOURCES
$AI_RESOURCES
$(if [[ "$PROTOCOL" == "https" ]]; then echo "- ../cert-manager"; echo "- https-redirect.yaml"; else echo "- gateway-tls.yaml"; fi)
EOF
            if [ "$PROTOCOL" = "https" ]; then
                cp "$PANEL_DIR/overlays/http/gateway-https-patch.yaml" "$PANEL_DIR/overlays/http/https-redirect.yaml" "$OVERLAY/"
                cat "$PANEL_DIR/overlays/http/https-replacements.yaml" >> "$OVERLAY/kustomization.yaml"
            else
                ensure_reverse_proxy_certificate "$OVERLAY" || return 1
                cp "$PANEL_DIR/overlays/http/gateway-tls.yaml" "$OVERLAY/"
                cat "$PANEL_DIR/overlays/http/http-replacements.yaml" "$PANEL_DIR/overlays/http/reverse-proxy-tls.yaml" >> "$OVERLAY/kustomization.yaml"
            fi
        done
    done
}
