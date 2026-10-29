#!/bin/bash

# A fresh install's routing layer: Traefik from charts/ through k3s's
# helm-controller (install_traefik), then the Gateway, HTTPRoutes and
# Middlewares of the overlay update.sh builds, in front of stub backends.
# https mode first -- before and after its certificates exist -- then http.

# shellcheck source=tests/gateway/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
trap cleanup EXIT

API="api.$DOMAIN"
WEB="$DOMAIN"
DEMOS="demos.$DOMAIN"
WS="ws.$DOMAIN"
RELAY="tv.$DOMAIN"
HLS="hls.$DOMAIN"
SEARCH="search.$DOMAIN"
CONSOLE="console.$DOMAIN"
ORIGIN="https://$DOMAIN"

# What cert-manager creates from overlays/cert-manager/issuer.yaml for a
# challenge: the Issuer's class and ingressTemplate annotations on an Ingress
# for /.well-known/acme-challenge/<token>.
solver_ingress() {
    python3 -I - "$WORK_DIR/issuer.yaml" "$@" <<'PY'
import re, sys
issuer = open(sys.argv[1]).read()
klass = re.search(r"ingressClassName: (\S+)", issuer).group(1)
annotations = re.findall(r"(?m)^ +(traefik\.ingress\.kubernetes\.io/\S+): (.+)$", issuer)
print(f"""apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: cm-acme-http-solver-test
  namespace: 5stack
  annotations:""")
for key, value in annotations:
    print(f"    {key}: {value}")
print(f"""spec:
  ingressClassName: {klass}
  rules:""")
for host in sys.argv[2:]:
    print(f"""    - host: {host}
      http:
        paths:
          - path: /.well-known/acme-challenge/test-token
            pathType: ImplementationSpecific
            backend:
              service:
                name: acme-solver
                port:
                  number: 8089""")
PY
}

test_http01_is_answered_beside_the_https_redirect() {
    wait_for 200 http "$API" /.well-known/acme-challenge/test-token
    expect_json .backend acme-solver
    call http "$HLS" /.well-known/acme-challenge/test-token
    expect_code 200
    expect_json .path /.well-known/acme-challenge/test-token
    call http "$API" /me
    expect_code 308
    expect_header Location "https://$API/me"
}

test_hosts_serve_while_the_stream_certificate_is_missing() {
    wait_for 200 https "$API" /me
    expect_json .backend api
    call https "$WEB" /
    expect_code 200
    expect_json .backend web
}

test_api_allowlist_paths_reach_their_backends() {
    local entry path backend
    for entry in /me:api /system/healthz:api /system/logs/download:api /matches/1/live:api /twitch/x:api \
        /game-server-node/script:api /game-server-node/ping/1:api /avatars/1.png:api /trophies/x:api \
        /branding/logo:api /news/1:api /utility/x:api /custom-pages/x:api /plugins/authorize/x:api \
        /huds/x.zip:api /events/media/1:api /snapshots/1:api /steam-match-history/upload:api /clip-views/1:api \
        /voice/1:api /notifications/1:api /chat/1:api /sanctions/server/1:api /file-manager/upload:api /mediamtx/stats:api \
        /v1/graphql:hasura /v1alpha1/x:hasura /v2/query:hasura; do
        path="${entry%:*}"
        backend="${entry##*:}"
        call https "$API" "$path"
        expect_code 200
        expect_json .backend "$backend"
        expect_json .path "$path"
    done
}

test_paths_outside_the_allowlist_are_404() {
    local path
    for path in / /nope /matchesx /me/x /system/healthz/x /system/logs /v3 /ws /auth/steam /mediamtx; do
        call https "$API" "$path"
        expect_code 404
    done
}

test_hasura_healthz_is_rewritten() {
    call https "$API" /v2/healthz
    expect_code 200
    expect_json .backend hasura
    expect_json .path /healthz
}

test_web_host_sends_its_api_paths_to_the_api() {
    local entry path backend
    for entry in /auth/steam:api /extension/x:api /telemetry:api /discord-invite:api /discord-bot:api \
        /calendar/x.ics:api /quick-connect:api /telemetry/x:web /authx:web /:web "/matches/1?tab=x:web"; do
        path="${entry%:*}"
        backend="${entry##*:}"
        call https "$WEB" "$path"
        expect_code 200
        expect_json .backend "$backend"
        expect_json .path "$path"
    done
}

test_demos_reach_rustfs_with_host_and_path_as_signed() {
    local path='/5stack/demos/a%20b%2Bc.dem?X-Amz-Signature=ab%2Fcd&partNumber=3'
    call https "$DEMOS" "$path"
    expect_code 200
    expect_json .backend rustfs
    expect_json .path "$path"
    expect_json .host "$DEMOS"
    call https "$DEMOS" /demos/1/download
    expect_json .backend api
    call https "$DEMOS" /clips/1
    expect_json .backend api
    call https "$DEMOS" /other
    expect_code 404
}

test_a_64mib_part_put_reaches_rustfs_whole() {
    client sh -c 'head -c 67108864 /dev/zero >/tmp/part'
    call https "$DEMOS" '/5stack/demos/x.dem?partNumber=1&uploadId=u' -X PUT --data-binary @/tmp/part
    expect_code 200
    expect_json .method PUT
    expect_json .body_bytes 67108864
}

test_ws_and_relay_hosts_rewrite_into_the_api() {
    call https "$WS" '/socket?EIO=4'
    expect_json .backend api
    expect_json .path '/ws/socket?EIO=4'
    call https "$WS" /
    expect_json .path /ws/
    call https "$RELAY" '/match/1/0/start?x=1'
    expect_json .path '/match-relay/match/1/0/start?x=1'
}

test_websocket_upgrades_through_the_ws_host() {
    local out
    out="$(client python3 /client.py ws "$NODE_IP" "$WS" /live 0)"
    [ "$(jq -r .status <<<"$out")" = 101 ] || fail "no 101: $out"
    [ "$(jq -r .hello.path <<<"$out")" = /ws/live ] || fail "wrong upstream path: $out"
    [ "$(jq -r .echoes <<<"$out")" -ge 1 ] || fail "no echo: $out"
}

test_typesense_and_s3_console_hosts() {
    call https "$SEARCH" /collections
    expect_json .backend typesense
    call https "$CONSOLE" /browser
    expect_json .backend rustfs-console
    expect_json .path /browser
}

test_mediamtx_preflight_is_answered_before_forward_auth() {
    auth_log '?clear' >/dev/null
    call https "$HLS" /m1/whep -X OPTIONS -H "Origin: $ORIGIN" -H 'Access-Control-Request-Method: POST' \
        -H 'Access-Control-Request-Headers: content-type'
    expect_code 200
    expect_header Access-Control-Allow-Origin "$ORIGIN"
    expect_header Access-Control-Allow-Credentials true
    [ -z "$BODY" ] || fail "the preflight reached a backend: $BODY"
    local seen
    seen="$(auth_log | jq '[.[] | select(.headers["x-forwarded-uri"] | startswith("/m1/whep"))]')"
    [ "$(jq length <<<"$seen")" = 0 ] || fail "the preflight went through forward-auth: $seen"
}

test_mediamtx_requires_a_session() {
    call https "$HLS" /m1/index.m3u8 -H "Origin: $ORIGIN"
    expect_code 401
    expect_header Access-Control-Allow-Origin "$ORIGIN"
    call https "$HLS" /m1/index.m3u8 -H "Origin: $ORIGIN" -H 'Cookie: session=ok'
    expect_code 200
    expect_json .backend mediamtx-hls
    expect_json .path /m1/index.m3u8
    call https "$HLS" /m1/ -H 'Cookie: session=ok'
    expect_json .backend mediamtx-hls
}

test_whep_post_and_patch_pass_forward_auth() {
    auth_log '?clear' >/dev/null
    call https "$HLS" /m1/whep -X POST -H "Origin: $ORIGIN" -H 'Cookie: session=ok' \
        -H 'Content-Type: application/sdp' --data-binary 'v=0'
    expect_code 201
    expect_json .backend mediamtx-whip
    expect_header Location /m1/whep/session-1
    expect_header Access-Control-Expose-Headers Location
    local entry
    entry="$(auth_log | jq -c '.[-1]')"
    [ "$(jq -r .method <<<"$entry")" = GET ] || fail "the auth call was not a GET: $entry"
    [ "$(jq -r '.headers["x-forwarded-method"]' <<<"$entry")" = POST ] || fail "$entry"
    [ "$(jq -r '.headers["x-forwarded-uri"]' <<<"$entry")" = /m1/whep ] || fail "$entry"
    call https "$HLS" /m1/whep/session-1 -X PATCH -H 'Cookie: session=ok' --data-binary 'a=candidate'
    expect_code 200
    expect_json .backend mediamtx-whip
}

test_forward_auth_receives_only_the_cookie() {
    auth_log '?clear' >/dev/null
    call https "$HLS" /m1/index.m3u8 -H 'Cookie: session=ok' -H 'Authorization: Bearer x' -H 'X-Probe: 1' \
        -H 'X-Forwarded-Uri: /other/index.m3u8'
    expect_code 200
    local headers
    headers="$(auth_log | jq -c '.[-1].headers')"
    [ "$(jq -r .cookie <<<"$headers")" = session=ok ] || fail "$headers"
    [ "$(jq -r '.authorization // "none"' <<<"$headers")" = none ] || fail "Authorization reached the api: $headers"
    [ "$(jq -r '.["x-probe"] // "none"' <<<"$headers")" = none ] || fail "X-Probe reached the api: $headers"
    [ "$(jq -r '.["x-forwarded-uri"]' <<<"$headers")" = /m1/index.m3u8 ] || fail "the client's X-Forwarded-Uri won: $headers"
}

test_spoofed_preflight_headers_do_not_bypass_forward_auth() {
    local spoof
    for spoof in 'X-Forwarded-Method: OPTIONS' 'X-Original-Method: OPTIONS'; do
        call https "$HLS" /m1/index.m3u8 -H "$spoof"
        expect_code 401
        call https "$HLS" /m1/whep -X POST -H "$spoof" --data-binary 'v=0'
        expect_code 401
    done
}

test_mediamtx_paths_outside_its_patterns_are_404() {
    local path
    for path in /m1 /m1/a/b.ts /m1/whep/a/b; do
        call https "$HLS" "$path" -H 'Cookie: session=ok'
        expect_code 404
    done
}

test_snapshot_is_rewritten_with_open_cors() {
    call https "$HLS" '/snapshot/abc-123?t=1' -H 'Origin: https://elsewhere.test'
    expect_code 200
    expect_json .backend api
    expect_json .path '/game-streamer/abc-123/snapshot?t=1'
    expect_header Access-Control-Allow-Origin '*'
}

test_http_redirects_to_https_without_a_port() {
    local host
    for host in "$WEB" "$API" "$DEMOS" "$WS" "$RELAY" "$SEARCH" "$CONSOLE" "$HLS"; do
        call http "$host" '/x/y?z=1'
        expect_code 308
        expect_header Location "https://$host/x/y?z=1"
    done
}

test_client_ip_reaches_the_backend() {
    call https "$API" /me
    expect_json '.headers["x-forwarded-for"]' "$CLIENT_IP"
    expect_json '.headers["x-real-ip"]' "$CLIENT_IP"
    expect_json '.headers["x-forwarded-proto"]' https
}

test_other_namespaces_attach_to_the_shared_listener() {
    deploy_stub other "80:other" "other:80"
    kubectl apply -f - >/dev/null <<'EOF'
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: other
  namespace: other
spec:
  parentRefs:
    - name: traefik-gateway
      namespace: traefik
      sectionName: web
  hostnames:
    - other.test
  rules:
    - backendRefs:
        - name: other
          port: 80
EOF
    wait_for 200 http other.test /x
    expect_json .backend other
    call http unknown.test /
    expect_code 404
}

# An app on the shared Gateway, attached to both of its listeners, as a
# reverse proxy that forwards to 443 needs.
shared_route_on_both_listeners() {
    kubectl apply -f - >/dev/null <<'EOF'
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: other-both
  namespace: other
spec:
  parentRefs:
    - name: traefik-gateway
      namespace: traefik
      sectionName: web
    - name: traefik-gateway
      namespace: traefik
      sectionName: websecure
  hostnames:
    - both.test
  rules:
    - backendRefs:
        - name: other
          port: 80
EOF
}

# The subject of the certificate served on 443 for SNI $1.
served_certificate() {
    client sh -c "openssl s_client -connect $NODE_IP:443 -servername $1 </dev/null 2>/dev/null | openssl x509 -noout -subject -nameopt RFC2253"
}

test_the_shared_gateway_answers_on_443_as_well() {
    shared_route_on_both_listeners
    wait_for 200 https both.test /x
    expect_json .backend other
    expect_json '.headers["x-forwarded-proto"]' https
    call http both.test /x
    expect_code 200
    expect_json '.headers["x-forwarded-proto"]' http
}

# The shared listener on 443 has no hostname; the panel's own listeners carry
# theirs, so they keep their hosts and their certificate.
test_panel_hosts_keep_their_certificate_beside_the_shared_listener() {
    [ "$(served_certificate "$API")" = "subject=CN=$WEB" ] || fail "$API was served $(served_certificate "$API")"
    call https "$API" /me
    expect_code 200
    expect_json .backend api
}

test_http_mode_shares_443_with_the_shared_gateway() {
    call https "$API" /me
    expect_code 200
    expect_json .backend api
    call https both.test /x
    expect_code 200
    expect_json .backend other
    expect_json '.headers["x-forwarded-proto"]' https
}

# Has helm-controller upgrade the gateway release, by changing one value.
upgrade_gateway_release() {
    local old_uid uid complete
    old_uid="$(kubectl -n kube-system get job helm-install-gateway -o jsonpath='{.metadata.uid}')"
    kubectl -n kube-system patch helmchart gateway --type merge \
        -p "{\"spec\":{\"set\":{\"traefik.deployment.podAnnotations.upgraded\":\"$1\"}}}" >/dev/null || return 1
    for _ in $(seq 1 100); do
        IFS='|' read -r uid complete < <(kubectl -n kube-system get job helm-install-gateway \
            -o jsonpath='{.metadata.uid}{"|"}{.status.conditions[?(@.type=="Complete")].status}{"\n"}' 2>/dev/null)
        if [ -n "$uid" ] && [ "$uid" != "$old_uid" ] && [ "$complete" = True ]; then
            return 0
        fi
        sleep 3
    done
    return 1
}

shared_certificate() {
    kubectl -n traefik get secret traefik-gateway-tls -o jsonpath='{.data.tls\.crt}'
}

# helm-controller upgrades the release with cluster access, so lookup finds
# the certificate the install made and the upgrade keeps it.
test_an_upgrade_keeps_the_shared_certificate() {
    local before
    before="$(shared_certificate)"
    [ -n "$before" ] || fail "traefik-gateway-tls is missing"
    upgrade_gateway_release once || fail "the upgrade never completed"
    [ "$(shared_certificate)" = "$before" ] || fail "the upgrade replaced the certificate"
}

# Rewrites the certificate's recorded expiry as Helm itself would have written
# it. helm-controller's Helm applies server-side as "helm", so a change made
# under any other field manager would conflict with the upgrade's own apply.
age_shared_certificate() {
    kubectl -n traefik get secret traefik-gateway-tls -o json |
        python3 -I -c '
import json, sys
s = json.load(sys.stdin)
m = s["metadata"]
m["annotations"]["gateway.5stack.gg/not-after"] = sys.argv[1]
print(json.dumps({"apiVersion": "v1", "kind": "Secret", "type": s["type"], "data": s["data"],
                  "metadata": {k: m[k] for k in ("name", "namespace", "labels", "annotations") if k in m}}))' "$1" |
        kubectl apply --server-side --field-manager=helm --force-conflicts -f - >/dev/null
}

test_an_upgrade_renews_a_shared_certificate_about_to_expire() {
    local before expires
    before="$(shared_certificate)"
    age_shared_certificate "$(($(date +%s) + 86400))" || fail "could not age the certificate"
    upgrade_gateway_release twice || fail "the upgrade never completed"
    [ "$(shared_certificate)" != "$before" ] || fail "the upgrade kept a certificate a day from expiring"
    expires="$(kubectl -n traefik get secret traefik-gateway-tls -o jsonpath='{.metadata.annotations.gateway\.5stack\.gg/not-after}')"
    [ "$expires" -gt $(($(date +%s) + 3000 * 86400)) ] || fail "the new certificate expires at $expires"
    wait_for 200 https both.test /x
}

# Every panel route names its listener's host, so it reads as that host rather
# than "*" -- in each overlay update.sh or dev.sh applies.
test_every_panel_route_names_its_listeners_host() {
    local overlay file
    write_overlays || fail "write_overlays failed"
    for file in "$PANEL_DIR"/overlays/local-secrets/*.env; do
        [ -f "$PANEL_DIR/overlays/dev/secrets/${file##*/}" ] || cp "$file" "$PANEL_DIR/overlays/dev/secrets/"
    done
    for overlay in local-secrets-https local-secrets-http dev; do
        "$PANEL_DIR/kustomize" build "$PANEL_DIR/overlays/$overlay" >"$WORK_DIR/$overlay.yaml" || fail "$overlay did not build"
        python3 -I "$HERE/route_hostnames.py" "$WORK_DIR/$overlay.yaml" >"$WORK_DIR/hostnames.out" ||
            fail "$overlay: $(cat "$WORK_DIR/hostnames.out")"
    done
}

# GET https://$1$2 asking for gzip: the response's Content-Encoding ("none"
# without one) and the size of its body once decoded.
fetch_asking_for_gzip() {
    # shellcheck disable=SC2016 # expanded by the client container's sh
    client sh -c 'curl -sk --resolve "$1:443:$2" -H "Accept-Encoding: gzip" -D /tmp/h -o /tmp/b "https://$1$3"
        encoding="$(tr -d "\r" </tmp/h | awk -F": " "tolower(\$1) == \"content-encoding\" { print \$2 }")"
        if [ -n "$encoding" ]; then echo "$encoding $(gunzip -c /tmp/b | wc -c | tr -d " ")"
        else echo "none $(wc -c </tmp/b | tr -d " ")"; fi' sh "$1" "$NODE_IP" "$2"
}

expect_fetched() {
    local got
    got="$(fetch_asking_for_gzip "$1" "$2")"
    [ "$got" = "$3" ] || fail "https://$1$2: expected '$3', got '$got'"
}

test_text_from_web_and_the_api_is_compressed() {
    expect_fetched "$WEB" '/payload?type=text/html;%20charset=utf-8&bytes=20000' "gzip 20000"
    expect_fetched "$WEB" '/payload?type=image/svg%2Bxml&bytes=20000' "gzip 20000"
    expect_fetched "$API" '/matches/payload?type=application/json&bytes=20000' "gzip 20000"
    expect_fetched "$API" '/matches/payload?type=application/json&bytes=500' "none 500"
}

test_binary_and_already_encoded_responses_pass_through() {
    expect_fetched "$WEB" '/payload?type=application/octet-stream&bytes=20000' "none 20000"
    expect_fetched "$API" '/file-manager/payload?type=application/zip&bytes=20000' "none 20000"
    # Gzipped by the backend: decoding it once gives the body back, so it was
    # not compressed a second time.
    expect_fetched "$WEB" '/payload?type=application/json&bytes=20000&encoded=gzip' "gzip 20000"
    # Hasura on the api host is not behind the middleware; it compresses itself.
    expect_fetched "$API" '/v1/payload?type=application/json&bytes=20000' "none 20000"
}

# An event stream's first event arrives at once, uncompressed, rather than
# being held until the middleware has enough bytes to decide.
test_event_streams_are_neither_compressed_nor_held_back() {
    local out
    # shellcheck disable=SC2016 # expanded by the client container's sh
    out="$(client sh -c 'curl -sk -N --resolve "$1:443:$2" -H "Accept-Encoding: gzip" -D /tmp/h -o /tmp/b \
        -w "%{time_starttransfer} %{time_total}" "https://$1/matches/stream?seconds=4&type=text/event-stream"
        tr -d "\r" </tmp/h | grep -i "^content-encoding" || echo " none"' sh "$API" "$NODE_IP")"
    python3 -I -c '
import sys
first, total, encoding = sys.argv[1].split()[:3]
assert float(first) < 2 and float(total) >= 3.5, f"first byte after {first}s of {total}s"
assert encoding == "none", f"compressed: {encoding}"' "$out" || fail "$out"
}

start_long_requests() {
    client sh -c 'head -c 125829120 /dev/zero >/tmp/big'
    docker exec -d "$PREFIX-client" sh -c "curl -sk --resolve $DEMOS:443:$NODE_IP -X PUT --data-binary @/tmp/big \
        --limit-rate 1500K -o /tmp/upload.json -w '%{http_code} %{time_total}' \
        'https://$DEMOS/5stack/demos/big.dem?partNumber=1' >/tmp/upload.out 2>&1"
    docker exec -d "$PREFIX-client" sh -c "curl -sk -N --resolve $DEMOS:443:$NODE_IP -w '\n%{http_code} %{time_total}' \
        'https://$DEMOS/demos/stream?seconds=70' >/tmp/stream.out 2>&1"
    docker exec -d "$PREFIX-client" sh -c "python3 /client.py ws $NODE_IP $WS /live 70 >/tmp/ws.json"
}

await_long_requests() {
    for _ in $(seq 1 90); do
        if client test -s /tmp/upload.out && client sh -c 'tail -n 1 /tmp/stream.out | grep -qE "^[0-9]{3} [0-9.]+$"' && client test -s /tmp/ws.json; then
            return 0
        fi
        sleep 2
    done
}

test_an_upload_over_100mb_running_past_60s_completes() {
    local out
    out="$(client cat /tmp/upload.out)"
    [ "${out%% *}" = 200 ] || fail "upload: $out $(client cat /tmp/upload.json)"
    awk -v t="${out##* }" 'BEGIN { exit !(t > 60) }' || fail "the upload took only ${out##* }s"
    [ "$(client jq -r .body_bytes /tmp/upload.json)" = 125829120 ] || fail "$(client cat /tmp/upload.json)"
}

test_a_response_streaming_past_60s_completes() {
    local last ticks
    last="$(client tail -n 1 /tmp/stream.out)"
    ticks="$(client grep -c '^tick ' /tmp/stream.out)"
    if [ "${last%% *}" != 200 ] || [ "$ticks" != 70 ]; then
        fail "stream ended after $ticks ticks: $last"
    fi
    awk -v t="${last##* }" 'BEGIN { exit !(t > 60) }' || fail "the stream took only ${last##* }s"
}

test_a_websocket_held_past_60s_stays_open() {
    local out
    out="$(client cat /tmp/ws.json)"
    [ "$(jq -r .error <<<"$out")" = null ] || fail "$out"
    if [ "$(jq -r .held <<<"$out")" -lt 65 ] || [ "$(jq -r .echoes <<<"$out")" -lt 7 ]; then
        fail "$out"
    fi
}

test_http_mode_serves_every_host_without_redirect() {
    wait_for 200 http "$API" /me
    expect_json .backend api
    expect_json '.headers["x-forwarded-proto"]' http
    wait_for 200 http "$WS" /x
    expect_json .path /ws/x
    call http "$HLS" /m1/index.m3u8
    expect_code 401
    call http "$HLS" /m1/index.m3u8 -H 'Cookie: session=ok'
    expect_code 200
    call http "$HLS" /m1/whep -X OPTIONS -H "Origin: $ORIGIN" -H 'Access-Control-Request-Method: POST'
    expect_code 200
    expect_header Access-Control-Allow-Origin "$ORIGIN"
    call http "$DEMOS" '/5stack/demos/a.dem?X-Amz-Signature=x'
    expect_json .backend rustfs
    expect_json .host "$DEMOS"
}

# A proxy that forwards to the node on 443, as many did to ingress-nginx's
# self-signed certificate. The api's session cookie is Secure and express only
# sets it when X-Forwarded-Proto says https, so that header is what decides
# whether anyone can log in through such a proxy.
test_http_mode_also_answers_on_443_for_a_proxy_that_forwards_there() {
    local route parents
    wait_for 200 https "$API" /me
    expect_json .backend api
    expect_json '.headers["x-forwarded-proto"]' https
    call https "$WS" /x
    expect_code 200
    expect_json .path /ws/x
    expect_json '.headers["x-forwarded-proto"]' https
    call https "$HLS" /m1/index.m3u8
    expect_code 401
    call https "$HLS" /m1/index.m3u8 -H 'Cookie: session=ok'
    expect_code 200
    call https "$DEMOS" '/5stack/demos/a.dem?X-Amz-Signature=x'
    expect_json .backend rustfs
    for route in $(kubectl -n 5stack get httproute -o name); do
        parents="$(kubectl -n 5stack get "$route" -o jsonpath='{range .status.parents[*]}{.parentRef.name}={.conditions[?(@.type=="Accepted")].status} {end}')"
        case "$parents" in
            *"5stack=True"*"5stack-tls=True"* | *"5stack-tls=True"*"5stack=True"*) ;;
            *) fail "$route is not accepted on both Gateways: $parents" ;;
        esac
    done
}

start_cluster || exit 1
make_panel || exit 1
run_test test_every_panel_route_names_its_listeners_host
install_traefik "$PANEL_DIR/overlays/config/traefik-config.env" || exit 1
deploy_panel_stubs || exit 1
routing_layer https || exit 1
solver_ingress "$API" "$HLS" | kubectl apply -f - >/dev/null || exit 1

run_test test_http01_is_answered_beside_the_https_redirect

tls_secret 5stack-ssl "$WEB" "$API" "$DEMOS" "$WS" "$RELAY" "$SEARCH" "$CONSOLE" || exit 1
run_test test_hosts_serve_while_the_stream_certificate_is_missing
tls_secret 5stack-mediamtx-ssl "$HLS" || exit 1
call https "$HLS" /m1/index.m3u8
for _ in $(seq 1 30); do
    [ "$CODE" = 401 ] && break
    sleep 2
    call https "$HLS" /m1/index.m3u8
done

start_long_requests
for name in \
    test_api_allowlist_paths_reach_their_backends \
    test_paths_outside_the_allowlist_are_404 \
    test_hasura_healthz_is_rewritten \
    test_web_host_sends_its_api_paths_to_the_api \
    test_demos_reach_rustfs_with_host_and_path_as_signed \
    test_a_64mib_part_put_reaches_rustfs_whole \
    test_ws_and_relay_hosts_rewrite_into_the_api \
    test_websocket_upgrades_through_the_ws_host \
    test_typesense_and_s3_console_hosts \
    test_text_from_web_and_the_api_is_compressed \
    test_binary_and_already_encoded_responses_pass_through \
    test_event_streams_are_neither_compressed_nor_held_back \
    test_mediamtx_preflight_is_answered_before_forward_auth \
    test_mediamtx_requires_a_session \
    test_whep_post_and_patch_pass_forward_auth \
    test_forward_auth_receives_only_the_cookie \
    test_spoofed_preflight_headers_do_not_bypass_forward_auth \
    test_mediamtx_paths_outside_its_patterns_are_404 \
    test_snapshot_is_rewritten_with_open_cors \
    test_http_redirects_to_https_without_a_port \
    test_client_ip_reaches_the_backend \
    test_other_namespaces_attach_to_the_shared_listener \
    test_the_shared_gateway_answers_on_443_as_well \
    test_panel_hosts_keep_their_certificate_beside_the_shared_listener; do
    run_test "$name"
done

await_long_requests
run_test test_an_upload_over_100mb_running_past_60s_completes
run_test test_a_response_streaming_past_60s_completes
run_test test_a_websocket_held_past_60s_stays_open

routing_layer http || exit 1
kubectl delete httproute https-redirect -n 5stack >/dev/null
run_test test_http_mode_serves_every_host_without_redirect
run_test test_http_mode_also_answers_on_443_for_a_proxy_that_forwards_there
run_test test_http_mode_shares_443_with_the_shared_gateway
run_test test_an_upgrade_keeps_the_shared_certificate
run_test test_an_upgrade_renews_a_shared_certificate_about_to_expire

summary
