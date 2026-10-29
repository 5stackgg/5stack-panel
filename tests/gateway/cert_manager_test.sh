#!/bin/bash

# cert-manager issuing and renewing an https install's certificates through
# Traefik, end to end. cert-manager comes from the manifests update.sh applies;
# the Issuer and Certificates are the overlay's own, with only the ACME server
# swapped for Pebble, Let's Encrypt's test CA, running in the cluster. Pebble
# validates HTTP-01 the way Let's Encrypt does, over port 80 to whatever the
# hostname resolves to, and pebble-challtestsrv resolves every test hostname to
# Traefik -- for cert-manager's own self-check too, through CoreDNS. So a
# certificate is only issued if the solver Ingress cert-manager creates from the
# panel's Issuer wins port 80 over the https-redirect route on the same hosts.
#
# The 5stack-ssl it starts from is an ingress-nginx install's: issued under the
# Issuer that install had, and due for renewal once the update has run.

# shellcheck source=tests/gateway/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
trap cleanup EXIT

PEBBLE_IMAGE=ghcr.io/letsencrypt/pebble:2.10.1@sha256:ddf230642b1a584f519f32e347de1b05a6e4c1f6c35c1863b33effeab5f78199
CHALLTESTSRV_IMAGE=ghcr.io/letsencrypt/pebble-challtestsrv:2.10.1@sha256:12ce21884def456bcf9786542113949e1f19dc7738d2c70e156c2d0c38a1405b
PEBBLE_DIRECTORY=https://pebble.pebble.svc:14000/dir
LETS_ENCRYPT_DIRECTORY=https://acme-v02.api.letsencrypt.org/directory

API="api.$DOMAIN"
WEB="$DOMAIN"
DEMOS="demos.$DOMAIN"
WS="ws.$DOMAIN"
RELAY="tv.$DOMAIN"
HLS="hls.$DOMAIN"
SEARCH="search.$DOMAIN"
CONSOLE="console.$DOMAIN"

# As update.sh does it: the vendored manifests, the CRDs, then the webhook.
install_cert_manager() {
    # shellcheck source=utils/cert_manager.sh
    source "$PANEL_DIR/utils/cert_manager.sh"
    apply_overlay overlays/cert-manager-crds || return 1
    for crd in certificates.cert-manager.io issuers.cert-manager.io clusterissuers.cert-manager.io; do
        kubectl wait --for=condition=Established "crd/$crd" --timeout=120s >/dev/null || return 1
    done
    wait_for_cert_manager 300 >/dev/null
}

# The https overlay update.sh applies, rendered to $WORK_DIR/overlay.yaml, and
# its Issuer and Certificates to $WORK_DIR/cert-manager.yaml with Let's
# Encrypt's directory replaced by Pebble's and nothing else changed.
render_cert_manager_objects() {
    write_overlays || return 1
    "$PANEL_DIR/kustomize" build "$PANEL_DIR/overlays/local-secrets-https" >"$WORK_DIR/overlay.yaml" || return 1
    python3 -I - "$WORK_DIR/overlay.yaml" "$LETS_ENCRYPT_DIRECTORY" "$PEBBLE_DIRECTORY" >"$WORK_DIR/cert-manager.yaml" <<'PY'
import re, sys
docs = open(sys.argv[1]).read().split("\n---\n")
kind = lambda d: (re.search(r"(?m)^kind: (\S+)$", d) or [None, None])[1]
out = []
for d in docs:
    if kind(d) == "Issuer":
        d, n = re.subn(r"(?m)^( +)server: " + re.escape(sys.argv[2]) + "$",
                       lambda m: f"{m[1]}server: {sys.argv[3]}\n{m[1]}skipTLSVerify: true", d)
        assert n == 1, "the Issuer's ACME server is not Let's Encrypt's"
        out.append(d)
    elif kind(d) == "Certificate":
        out.append(d)
assert len(out) == 3, f"expected an Issuer and two Certificates, got {len(out)}"
print("\n---\n".join(out))
PY
}

# One document of $WORK_DIR/cert-manager.yaml, by kind and name.
cert_manager_object() {
    python3 -I - "$WORK_DIR/cert-manager.yaml" "$1" "$2" <<'PY'
import re, sys
for d in open(sys.argv[1]).read().split("\n---\n"):
    if re.search(rf"(?m)^kind: {sys.argv[2]}$", d) and re.search(rf"(?m)^  name: {re.escape(sys.argv[3])}$", d):
        print(d)
PY
}

# What an ingress-nginx install leaves: the Issuer it had, the panel's
# Certificate, and the 5stack-ssl that Issuer gave it -- a 90-day certificate
# with 5 days left, so inside renewBefore (240h) and due. cert-manager's
# controller is held at zero until the update has run: on a real install
# nothing is due during the update, and a renewal attempted here, with no
# ingress-nginx to serve its solver, would fail and back off for an hour.
leave_an_nginx_era_certificate() {
    local san="" host
    for host in "$WEB" "$API" "$DEMOS" "$SEARCH" "$CONSOLE" "$WS" "$RELAY"; do
        san="${san:+$san,}DNS:$host"
    done
    kubectl -n cert-manager scale deployment cert-manager --replicas=0 >/dev/null || return 1
    kubectl -n cert-manager wait --for=delete pod -l app.kubernetes.io/component=controller --timeout=120s >/dev/null 2>&1
    kubectl apply -f "$HERE/fixtures/nginx-era-issuer.yaml" >/dev/null || return 1
    cert_manager_object Certificate 5stack-ssl | kubectl apply -f - >/dev/null || return 1
    client openssl req -x509 -newkey rsa:2048 -nodes -subj "/CN=$WEB" -addext "subjectAltName=$san" \
        -not_before "$(date -u -d '-85 days' +%Y%m%d%H%M%SZ)" -not_after "$(date -u -d '+5 days' +%Y%m%d%H%M%SZ)" \
        -keyout /tmp/tls.key -out /tmp/tls.crt >/dev/null 2>&1 || return 1
    docker cp "$PREFIX-client:/tmp/tls.key" "$WORK_DIR/tls.key" >/dev/null
    docker cp "$PREFIX-client:/tmp/tls.crt" "$WORK_DIR/tls.crt" >/dev/null
    # Inside renewBefore, not just short-lived: cert-manager renews a
    # certificate shorter than renewBefore at two thirds of its life instead.
    openssl x509 -noout -checkend $((6 * 86400)) -in "$WORK_DIR/tls.crt" >/dev/null && return 1
    openssl x509 -noout -checkend $((4 * 86400)) -in "$WORK_DIR/tls.crt" >/dev/null || return 1
    kubectl -n 5stack create secret tls 5stack-ssl --cert="$WORK_DIR/tls.crt" --key="$WORK_DIR/tls.key" \
        --dry-run=client -o yaml | kubectl apply -f - >/dev/null || return 1
    kubectl -n 5stack annotate --overwrite secret 5stack-ssl cert-manager.io/issuer-name=5stack-issuer \
        cert-manager.io/issuer-kind=Issuer cert-manager.io/issuer-group=cert-manager.io \
        cert-manager.io/certificate-name=5stack-ssl >/dev/null || return 1
    NGINX_ERA_SERIAL="$(secret_certificate 5stack-ssl serial)"
}

# Pebble, with pebble-challtestsrv beside it answering every DNS query with
# Traefik's address. Validation goes to port 80, as Let's Encrypt's does, and
# no authorization is reused, so every issuance is validated again.
deploy_pebble() {
    local traefik_ip
    traefik_ip="$(kubectl -n traefik get service traefik -o jsonpath='{.spec.clusterIP}')"
    [ -n "$traefik_ip" ] || return 1
    kubectl apply -f - >/dev/null <<EOF || return 1
apiVersion: v1
kind: Namespace
metadata:
  name: pebble
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: pebble
  namespace: pebble
data:
  pebble.json: |
    {"pebble": {"listenAddress": "0.0.0.0:14000", "managementListenAddress": "0.0.0.0:15000",
      "certificate": "/test/certs/localhost/cert.pem", "privateKey": "/test/certs/localhost/key.pem",
      "httpPort": 80, "tlsPort": 443, "ocspResponderURL": "", "externalAccountBindingRequired": false,
      "profiles": {"default": {"description": "90 days", "validityPeriod": 7776000}}}}
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: pebble
  namespace: pebble
spec:
  selector:
    matchLabels: {app: pebble}
  template:
    metadata:
      labels: {app: pebble}
    spec:
      containers:
        - name: pebble
          image: $PEBBLE_IMAGE
          args: [-config, /config/pebble.json, -dnsserver, "127.0.0.1:8053"]
          env:
            - {name: PEBBLE_VA_NOSLEEP, value: "1"}
            - {name: PEBBLE_WFE_NONCEREJECT, value: "0"}
            - {name: PEBBLE_AUTHZREUSE, value: "0"}
          volumeMounts:
            - {name: config, mountPath: /config}
        - name: challtestsrv
          image: $CHALLTESTSRV_IMAGE
          args: [-defaultIPv4, "$traefik_ip", -defaultIPv6, "", -http01, "", -https01, "", -tlsalpn01, "", -doh, ""]
      volumes:
        - name: config
          configMap: {name: pebble}
---
apiVersion: v1
kind: Service
metadata:
  name: pebble
  namespace: pebble
spec:
  selector: {app: pebble}
  ports:
    - {name: acme, port: 14000, protocol: TCP}
    - {name: dns, port: 8053, protocol: UDP}
    - {name: dns-tcp, port: 8053, protocol: TCP}
EOF
    kubectl -n pebble rollout status deployment/pebble --timeout=180s >/dev/null || return 1

    # cert-manager checks a challenge is reachable before presenting it, over
    # cluster DNS; k3s's CoreDNS takes extra zones from coredns-custom.
    kubectl -n kube-system create configmap coredns-custom --dry-run=client -o yaml \
        --from-literal=pebble.server="$DOMAIN:53 {
    forward . $(kubectl -n pebble get service pebble -o jsonpath='{.spec.clusterIP}'):8053
}" | kubectl apply -f - >/dev/null || return 1
    kubectl -n kube-system rollout restart deployment/coredns >/dev/null || return 1
    kubectl -n kube-system rollout status deployment/coredns --timeout=120s >/dev/null
}

# A field of the certificate in Secret $1: issuer, serial, or sans (sorted,
# comma separated).
secret_certificate() {
    kubectl -n 5stack get secret "$1" -o jsonpath='{.data.tls\.crt}' | base64 -d | certificate_field "$2"
}

# The same, for the certificate Traefik serves on 443 for SNI $1.
served_certificate() {
    client sh -c "openssl s_client -connect $NODE_IP:443 -servername $1 </dev/null 2>/dev/null | openssl x509" |
        certificate_field "$2"
}

certificate_field() {
    case "$1" in
        issuer) openssl x509 -noout -issuer -nameopt RFC2253 | sed 's/^issuer=//' ;;
        serial) openssl x509 -noout -serial | sed 's/^serial=//' ;;
        sans) openssl x509 -noout -ext subjectAltName | tail -n +2 | tr ',' '\n' | sed 's/^ *DNS://' | sort | paste -sd, - ;;
    esac
}

wait_until_ready() {
    if ! kubectl -n 5stack wait --for=condition=Ready "$@" --timeout=300s >/dev/null; then
        kubectl -n 5stack get certificates,certificaterequests,orders,challenges >&2
        kubectl -n 5stack get challenges -o jsonpath='{range .items[*]}{.spec.dnsName}: {.status.reason}{"\n"}{end}' >&2
        return 1
    fi
}

# Until Traefik has picked up the Secret's current certificate for SNI $1.
wait_until_served() {
    local want
    want="$(secret_certificate "$2" serial)"
    for _ in $(seq 1 30); do
        [ "$(served_certificate "$1" serial)" = "$want" ] && return 0
        sleep 2
    done
    fail "$1 is served $(served_certificate "$1" issuer) serial $(served_certificate "$1" serial), not $2's $want"
}

expected_sans() {
    printf '%s\n' "$@" | sort | paste -sd, -
}

test_the_update_leaves_the_issuer_with_only_the_panels_solver() {
    local solver
    solver="$(kubectl -n 5stack get issuer 5stack-issuer -o jsonpath='{.spec.acme.solvers[0].http01.ingress}')"
    [ "$(jq -r .ingressClassName <<<"$solver")" = traefik ] || fail "solver: $solver"
    [ "$(jq -r '.ingressTemplate.metadata.annotations["traefik.ingress.kubernetes.io/router.entrypoints"]' <<<"$solver")" = web ] ||
        fail "solver: $solver"
    [ "$(jq -r '.ingressTemplate.metadata.annotations["traefik.ingress.kubernetes.io/router.priority"]' <<<"$solver")" = 1000000 ] ||
        fail "solver: $solver"
    [ "$(jq -r 'keys | join(",")' <<<"$solver")" = ingressClassName,ingressTemplate ] || fail "solver: $solver"
    kubectl -n 5stack get httproute https-redirect >/dev/null || fail "the https-redirect route is missing"
}

test_the_nginx_era_certificate_is_renewed_by_pebble_through_traefik() {
    [ "$(secret_certificate 5stack-ssl serial)" != "$NGINX_ERA_SERIAL" ] || fail "5stack-ssl still holds the nginx-era certificate"
    assert_pebble 5stack-ssl
    [ "$(secret_certificate 5stack-ssl sans)" = "$(expected_sans "$WEB" "$API" "$DEMOS" "$SEARCH" "$CONSOLE" "$WS" "$RELAY")" ] ||
        fail "5stack-ssl covers $(secret_certificate 5stack-ssl sans)"
}

test_the_panel_hosts_serve_it() {
    local host
    for host in "$API" "$WEB" "$WS"; do
        wait_until_served "$host" 5stack-ssl
    done
    case "$(served_certificate "$API" issuer)" in
        *Pebble*) ;;
        *) fail "$API is served a certificate from $(served_certificate "$API" issuer)" ;;
    esac
}

test_the_stream_certificate_is_issued_for_the_hls_host() {
    assert_pebble 5stack-mediamtx-ssl
    [ "$(secret_certificate 5stack-mediamtx-ssl sans)" = "$HLS" ] || fail "5stack-mediamtx-ssl covers $(secret_certificate 5stack-mediamtx-ssl sans)"
    wait_until_served "$HLS" 5stack-mediamtx-ssl
}

# What cmctl renew does: mark the Certificate as issuing. Pebble reuses no
# authorization, so the renewal is validated through Traefik again.
test_a_renewal_is_validated_and_served_again() {
    local before
    before="$(secret_certificate 5stack-ssl serial)"
    kubectl -n 5stack patch certificate 5stack-ssl --subresource=status --type=json -p "[{\"op\": \"add\",
        \"path\": \"/status/conditions/-\", \"value\": {\"type\": \"Issuing\", \"status\": \"True\",
        \"reason\": \"ManuallyTriggered\", \"message\": \"Certificate re-issuance manually triggered\",
        \"lastTransitionTime\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}}]" >/dev/null || fail "could not trigger a renewal"
    for _ in $(seq 1 90); do
        [ "$(secret_certificate 5stack-ssl serial)" != "$before" ] && break
        sleep 2
    done
    [ "$(secret_certificate 5stack-ssl serial)" != "$before" ] || fail "5stack-ssl was not renewed"
    wait_until_ready certificate/5stack-ssl || fail "5stack-ssl is not Ready after its renewal"
    assert_pebble 5stack-ssl
    wait_until_served "$API" 5stack-ssl
}

# The pin: the panel's Issuer with its solver on neither port 80 nor 443
# (Traefik's metrics entrypoint). The https-redirect route then answers the
# challenge on port 80, the ACME server follows it to 443 where there's no
# solver either, and nothing is issued: the issuances above stand on the solver
# winning that path. Neither of its annotations alone decides that on Traefik
# v3.7.16 -- the solver Ingress outranks the redirect without the priority, and
# a solver on websecure is reached through the redirect -- so the pin takes
# both ports away.
test_with_no_solver_on_80_or_443_the_redirect_takes_the_challenge() {
    local token="" ready
    cert_manager_object Issuer 5stack-issuer | python3 -I -c '
import sys
d = sys.stdin.read()
assert "router.entrypoints: web\n" in d
d = d.replace("router.entrypoints: web\n", "router.entrypoints: metrics\n")
print(d.replace("name: 5stack-issuer", "name: no-solver"))' | kubectl apply -f - >/dev/null || fail "could not make the Issuer"
    kubectl apply -f - >/dev/null <<EOF || fail "could not make the Certificate"
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: no-solver
  namespace: 5stack
spec:
  secretName: no-solver
  dnsNames: [$API]
  issuerRef: {name: no-solver, kind: Issuer}
EOF
    for _ in $(seq 1 60); do
        token="$(kubectl -n 5stack get challenges \
            -o jsonpath='{.items[?(@.spec.issuerRef.name=="no-solver")].spec.token}{"|"}{.items[?(@.spec.issuerRef.name=="no-solver")].status.presented}')"
        [ "${token#*|}" = true ] && break
        sleep 2
    done
    [ "${token#*|}" = true ] || fail "the challenge was never presented"
    token="${token%%|*}"
    # Long past the time the solver's pod and Ingress take to come up.
    sleep 30
    for _ in $(seq 1 5); do
        call http "$API" "/.well-known/acme-challenge/$token"
        [ "$CODE" = 308 ] || fail "with no solver on 80 or 443 the challenge answered $CODE, not the redirect"
        call https "$API" "/.well-known/acme-challenge/$token"
        [ "$CODE" != 200 ] || fail "with no solver on 80 or 443, 443 answered the challenge"
        sleep 2
    done
    sleep 30
    ready="$(kubectl -n 5stack get certificate no-solver -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')"
    [ "$ready" != True ] || fail "a certificate was issued with no solver on 80 or 443"
    kubectl -n 5stack delete certificate no-solver >/dev/null
    kubectl -n 5stack delete issuer no-solver >/dev/null
}

assert_pebble() {
    case "$(secret_certificate "$1" issuer)" in
        *Pebble*) ;;
        *) fail "$1 was issued by $(secret_certificate "$1" issuer)" ;;
    esac
}

start_cluster || exit 1
make_panel || exit 1
install_cert_manager || exit 1
kubectl create namespace 5stack >/dev/null || exit 1
render_cert_manager_objects || exit 1
leave_an_nginx_era_certificate || exit 1

# The update: Traefik, the overlay's Gateway and routes, the Issuer and
# Certificates as they are now. Then cert-manager runs again.
install_traefik "$PANEL_DIR/overlays/config/traefik-config.env" || exit 1
deploy_pebble || exit 1
routing_layer https || exit 1
kubectl apply -f "$WORK_DIR/cert-manager.yaml" >/dev/null || exit 1
kubectl -n cert-manager scale deployment cert-manager --replicas=1 >/dev/null || exit 1
kubectl -n cert-manager rollout status deployment/cert-manager --timeout=180s >/dev/null || exit 1
# The nginx-era certificate still counts as Ready until its renewal lands.
for _ in $(seq 1 150); do
    [ "$(secret_certificate 5stack-ssl serial 2>/dev/null)" != "$NGINX_ERA_SERIAL" ] && break
    sleep 2
done
wait_until_ready certificate/5stack-ssl certificate/5stack-mediamtx-ssl || exit 1

for name in \
    test_the_update_leaves_the_issuer_with_only_the_panels_solver \
    test_the_nginx_era_certificate_is_renewed_by_pebble_through_traefik \
    test_the_panel_hosts_serve_it \
    test_the_stream_certificate_is_issued_for_the_hls_host \
    test_a_renewal_is_validated_and_served_again \
    test_with_no_solver_on_80_or_443_the_redirect_takes_the_challenge; do
    run_test "$name"
done

summary
