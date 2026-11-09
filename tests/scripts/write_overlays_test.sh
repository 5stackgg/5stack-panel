#!/bin/bash

# shellcheck source=tests/scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

in_panel() {
    (
        export PANEL_DIR="$WORK_DIR/panel"
        mkdir -p "$PANEL_DIR/overlays"
        [ -d "$PANEL_DIR/overlays/http" ] || cp -R "$TEST_ROOT/overlays/http" "$PANEL_DIR/overlays/http"
        # shellcheck source=utils/write_overlays.sh
        source "$TEST_ROOT/utils/write_overlays.sh"
        "$@"
    ) >"$WORK_DIR/output" 2>&1
}

write() {
    in_panel write_overlays
}

overlay() {
    printf '%s' "$WORK_DIR/panel/overlays/$1"
}

with_s3_endpoint() {
    mkdir -p "$WORK_DIR/panel"
    cp -R "$TEST_ROOT/base" "$TEST_ROOT/overlays" "$WORK_DIR/panel/"
    find "$WORK_DIR/panel/overlays" -name '*.env.example' | while read -r example; do
        cp "$example" "${example%.example}"
    done
    grep -v '^S3_ENDPOINT=' "$TEST_ROOT/overlays/config/s3-config.env.example" >"$(overlay config)/s3-config.env"
    printf 'S3_ENDPOINT=%s\n' "$1" >>"$(overlay config)/s3-config.env"
}

with_demos_domain() {
    grep -v '^DEMOS_DOMAIN=' "$(overlay config)/api-config.env" >"$WORK_DIR/api-config.env"
    printf 'DEMOS_DOMAIN=%s\n' "$1" >>"$WORK_DIR/api-config.env"
    mv "$WORK_DIR/api-config.env" "$(overlay config)/api-config.env"
}

builtin() {
    in_panel s3_storage_is_builtin
}

# document MANIFEST KIND NAME: that one object of a rendered manifest.
document() {
    awk -v kind="$2" -v name="$3" '
        function flush() {
            if (index(doc, "\nkind: " kind "\n") && index(doc, "\n  name: " name "\n")) { printf "%s", doc }
            doc = "\n"
        }
        BEGIN { doc = "\n" }
        /^---$/ { flush(); next }
        { doc = doc $0 "\n" }
        END { flush() }
    ' <<<"$1"
}

kinds_and_names() {
    awk '/^---/ { kind = ""; next } /^kind: / { kind = $2 } /^  name: / && kind != "" { print kind "/" $2; kind = "" }' <<<"$1"
}

test_rustfs_is_built_in_storage_by_any_of_its_names() {
    for endpoint in "" rustfs minio RustFS "http://rustfs:9000" "https://minio:9000/" '"rustfs"' "rustfs:9000"; do
        with_s3_endpoint "$endpoint"
        builtin || fail "'$endpoint' was not taken for the built-in RustFS"
    done
}

test_without_an_s3_config_storage_is_built_in() {
    builtin || fail "a panel with no s3-config.env was not taken for the built-in RustFS"
}

test_any_other_s3_endpoint_is_external() {
    for endpoint in s3.us-east-005.backblazeb2.com "https://s3.us-east-005.backblazeb2.com" minio.example.com "rustfs.example.com:9000" s3.amazonaws.com; do
        with_s3_endpoint "$endpoint"
        builtin && fail "'$endpoint' was taken for the built-in RustFS"
    done
    true
}

test_built_in_storage_keeps_rustfs_in_every_overlay() {
    with_s3_endpoint ""
    write || fail "write_overlays failed: $(cat "$WORK_DIR/output")"
    for o in vault-http vault-https local-secrets-http local-secrets-https; do
        assert_not_contains "$(cat "$(overlay "$o")/kustomization.yaml")" "external-s3"
    done
    manifest="$(kubectl kustomize "$(overlay local-secrets-https)")" || fail "kubectl kustomize failed"
    rendered="$(kinds_and_names "$manifest")"
    for object in StatefulSet/rustfs Service/rustfs Service/minio HTTPRoute/s3-console PersistentVolumeClaim/minio-pvc; do
        assert_contains "$rendered" "$object"
    done
}

test_an_external_s3_endpoint_leaves_rustfs_out_of_every_overlay() {
    with_s3_endpoint s3.us-east-005.backblazeb2.com
    write || fail "write_overlays failed: $(cat "$WORK_DIR/output")"
    for o in vault-http vault-https local-secrets-http local-secrets-https; do
        manifest="$(kubectl kustomize "$(overlay "$o")")" || fail "kubectl kustomize $o failed"
        rendered="$(kinds_and_names "$manifest")"
        for object in StatefulSet/rustfs Service/rustfs Service/minio HTTPRoute/s3-console PersistentVolume/minio-pv PersistentVolumeClaim/minio-pvc Secret/rustfs-secrets ExternalSecret/rustfs-secrets; do
            assert_not_contains "$rendered" "$object"
        done
        assert_not_contains "$manifest" "name: rustfs"
        assert_contains "$rendered" "HTTPRoute/demos"
        assert_contains "$rendered" "Deployment/api"
        assert_contains "$manifest" "value: /demos"
        assert_contains "$(cat "$(overlay "$o")/kustomization.yaml")" "- ../external-s3"
    done
}

test_s3_on_the_demos_domain_is_the_built_in_rustfs() {
    for endpoint in demos.example.com "https://Demos.Example.com/" "demos.example.com:443"; do
        with_s3_endpoint "$endpoint"
        with_demos_domain demos.example.com
        builtin || fail "'$endpoint' on DEMOS_DOMAIN demos.example.com was taken for a remote bucket"
    done
}

test_s3_on_another_host_is_external_beside_a_demos_domain() {
    for endpoint in s3.us-east-005.backblazeb2.com files.demos.example.com; do
        with_s3_endpoint "$endpoint"
        with_demos_domain demos.example.com
        builtin && fail "'$endpoint' was taken for the built-in RustFS"
    done
    true
}

test_s3_on_the_demos_domain_keeps_the_demos_route_to_rustfs() {
    with_s3_endpoint demos.example.com
    with_demos_domain demos.example.com
    write || fail "write_overlays failed: $(cat "$WORK_DIR/output")"
    for o in vault-http vault-https local-secrets-http local-secrets-https; do
        manifest="$(kubectl kustomize "$(overlay "$o")")" || fail "kubectl kustomize $o failed"
        route="$(document "$manifest" HTTPRoute demos)"
        assert_contains "$route" "value: /5stack"
        assert_contains "$route" "name: rustfs"
        assert_contains "$(kinds_and_names "$manifest")" "StatefulSet/rustfs"
    done
}

test_the_backup_reads_the_demos_domain_from_the_api_config() {
    with_s3_endpoint demos.example.com
    with_demos_domain demos.example.com
    write || fail "write_overlays failed: $(cat "$WORK_DIR/output")"
    manifest="$(kubectl kustomize "$(overlay local-secrets-https)")" || fail "kubectl kustomize failed"
    config_map="$(kinds_and_names "$manifest" | sed -n 's#^ConfigMap/\(api-config.*\)#\1#p')"
    [ -n "$config_map" ] || fail "no api-config ConfigMap was rendered"
    assert_eq "$(document "$manifest" CronJob postgres-backup | grep -A1 'key: DEMOS_DOMAIN$' | sed -n 2p | tr -d ' ')" "name:$config_map"
}

# check_mediamtx_secrets OVERLAY: MediaMTX gets each user's password from
# mediamtx-secrets, which the overlay creates, and the api gets them optionally.
check_mediamtx_secrets() {
    kubectl kustomize "$(overlay "$1")" >"$WORK_DIR/$1.yaml" || fail "kubectl kustomize $1 failed"
    KUBECONFIG=/dev/null kubectl patch --local -o json --type merge -p '{}' -f "$WORK_DIR/$1.yaml" >"$WORK_DIR/$1.json" ||
        fail "could not read $1 as JSON"
    python3 -I - "$WORK_DIR/$1.json" <<'PY' || fail "$1"
import json, sys
raw, decoder, at, objs = open(sys.argv[1]).read(), json.JSONDecoder(), 0, []
while raw[at:].strip():
    obj, at = decoder.raw_decode(raw, at + len(raw[at:]) - len(raw[at:].lstrip()))
    objs.append(obj)
find = lambda kind, name: next((o for o in objs if o["kind"] == kind and o["metadata"]["name"] == name), None)
keys = ["MEDIAMTX_API_PASSWORD", "MEDIAMTX_STREAMER_PASSWORD", "MEDIAMTX_RELAY_PASSWORD", "MEDIAMTX_VIEWER_PASSWORD"]
pod = find("Deployment", "mediamtx")["spec"]["template"]["spec"]
env = {e["name"]: e["valueFrom"]["secretKeyRef"] for e in pod["containers"][0]["env"] if e["name"].startswith("MTX_AUTH")}
assert list(env) == [f"MTX_AUTHINTERNALUSERS_{i}_PASS" for i in range(4)], env
assert [r["key"] for r in env.values()] == keys, env
assert not any(r.get("optional") for r in env.values()), env
secret = {r["name"] for r in env.values()}
assert len(secret) == 1, secret
secret = secret.pop()
init = pod["initContainers"][0]
assert [e["secretRef"] for e in init["envFrom"]] == [{"name": secret}], init["envFrom"]
generated = find("Secret", secret)
external = find("ExternalSecret", secret)
if generated:
    assert secret.startswith("mediamtx-secrets-") and sorted(generated["data"]) == sorted(keys), generated
else:
    assert external, f"nothing makes {secret}"
    assert [(d["secretKey"], d["remoteRef"]["key"], d["remoteRef"]["property"]) for d in external["spec"]["data"]] == \
        [(k, "mediamtx", k) for k in keys], external["spec"]["data"]
api = find("Deployment", "api")["spec"]["template"]["spec"]["containers"][0]
assert {"secretRef": {"name": secret, "optional": True}} in api["envFrom"], api["envFrom"]
assert find("Middleware", "mediamtx-auth")["spec"]["forwardAuth"]["authResponseHeaders"] == ["Authorization"]
PY
}

test_mediamtx_signs_in_with_passwords_from_mediamtx_secrets_in_every_overlay() {
    with_s3_endpoint ""
    write || fail "write_overlays failed: $(cat "$WORK_DIR/output")"
    for o in vault-http vault-https local-secrets-http local-secrets-https; do
        check_mediamtx_secrets "$o"
    done
}

test_update_sh_hands_a_minio_volume_to_rustfs_only_on_built_in_storage() {
    assert_contains "$(grep 'get statefulset minio' "$TEST_ROOT/update.sh")" "if s3_storage_is_builtin && "
}

test_a_reverse_proxy_overlay_answers_on_443_with_its_own_certificate() {
    write || fail "write_overlays failed: $(cat "$WORK_DIR/output")"
    openssl x509 -noout -in "$(overlay local-secrets-http)/reverse-proxy-tls.crt" || fail "no certificate"
    openssl pkey -noout -in "$(overlay local-secrets-http)/reverse-proxy-tls.key" || fail "no key"
    assert_contains "$(cat "$(overlay local-secrets-http)/kustomization.yaml")" "- gateway-tls.yaml"
    assert_contains "$(cat "$(overlay local-secrets-http)/kustomization.yaml")" "name: 5stack-reverse-proxy-tls"
    assert_contains "$(cat "$(overlay local-secrets-http)/kustomization.yaml")" "value: 5stack-tls"
    [ -f "$(overlay local-secrets-http)/gateway-tls.yaml" ] || fail "gateway-tls.yaml was not copied"
}

test_hasura_keeps_one_replica_by_default() {
    write || fail "write_overlays failed: $(cat "$WORK_DIR/output")"
    assert_not_contains "$(cat "$(overlay vault-https)/kustomization.yaml")" "replicas:"
}

test_hasura_replicas_sets_how_many_hasuras_run() {
    HASURA_REPLICAS=2 write || fail "write_overlays failed: $(cat "$WORK_DIR/output")"
    for name in vault-http vault-https local-secrets-http local-secrets-https; do
        assert_contains "$(cat "$(overlay "$name")/kustomization.yaml")" "- name: hasura"
        assert_contains "$(cat "$(overlay "$name")/kustomization.yaml")" "count: 2"
    done
}

test_hasura_replicas_must_be_a_whole_number() {
    HASURA_REPLICAS=two write && fail "a replica count of 'two' was accepted"
    assert_contains "$(cat "$WORK_DIR/output")" "HASURA_REPLICAS must be a whole number"
}

test_the_certificate_is_kept_across_updates() {
    write || fail "write_overlays failed: $(cat "$WORK_DIR/output")"
    cp "$(overlay local-secrets-http)/reverse-proxy-tls.crt" "$WORK_DIR/first.crt"
    write || fail "write_overlays failed: $(cat "$WORK_DIR/output")"
    cmp -s "$WORK_DIR/first.crt" "$(overlay local-secrets-http)/reverse-proxy-tls.crt" || fail "the certificate changed"
    [ "$(grep -c "name: 5stack-reverse-proxy-tls" "$(overlay local-secrets-http)/kustomization.yaml")" = 1 ] ||
        fail "the kustomization was appended to, not rewritten"
}

test_a_certificate_near_its_expiry_is_replaced() {
    write || fail "write_overlays failed: $(cat "$WORK_DIR/output")"
    openssl req -x509 -newkey rsa:2048 -nodes -days 10 -subj "/CN=5stack" \
        -keyout "$(overlay local-secrets-http)/reverse-proxy-tls.key" \
        -out "$(overlay local-secrets-http)/reverse-proxy-tls.crt" >/dev/null 2>&1
    cp "$(overlay local-secrets-http)/reverse-proxy-tls.crt" "$WORK_DIR/expiring.crt"
    write || fail "write_overlays failed: $(cat "$WORK_DIR/output")"
    cmp -s "$WORK_DIR/expiring.crt" "$(overlay local-secrets-http)/reverse-proxy-tls.crt" && fail "the expiring certificate was kept"
    openssl x509 -noout -checkend $((3000 * 86400)) -in "$(overlay local-secrets-http)/reverse-proxy-tls.crt" >/dev/null ||
        fail "the new certificate isn't good for ten years"
}

test_an_unreadable_certificate_is_replaced() {
    write || fail "write_overlays failed: $(cat "$WORK_DIR/output")"
    echo "not a certificate" >"$(overlay local-secrets-http)/reverse-proxy-tls.crt"
    write || fail "write_overlays failed: $(cat "$WORK_DIR/output")"
    openssl x509 -noout -in "$(overlay local-secrets-http)/reverse-proxy-tls.crt" || fail "it was not replaced"
}

test_the_key_is_readable_only_by_its_owner() {
    write || fail "write_overlays failed: $(cat "$WORK_DIR/output")"
    assert_eq "$(find "$(overlay local-secrets-http)/reverse-proxy-tls.key" -perm 600 | wc -l | tr -d ' ')" 1
}

test_an_https_install_has_no_reverse_proxy_listener() {
    write || fail "write_overlays failed: $(cat "$WORK_DIR/output")"
    assert_not_contains "$(cat "$(overlay local-secrets-https)/kustomization.yaml")" "5stack-tls"
    assert_not_contains "$(cat "$(overlay local-secrets-https)/kustomization.yaml")" "gateway-tls.yaml"
    [ ! -e "$(overlay local-secrets-https)/reverse-proxy-tls.key" ] || fail "an https overlay got a certificate"
}

test_without_openssl_the_update_stops() {
    mkdir -p "$WORK_DIR/bin"
    printf '#!/bin/sh\nexit 1\n' >"$WORK_DIR/bin/openssl"
    chmod +x "$WORK_DIR/bin/openssl"
    if PATH="$WORK_DIR/bin:$PATH" write; then
        fail "write_overlays succeeded without a certificate"
    fi
    assert_contains "$(cat "$WORK_DIR/output")" "is openssl installed"
    [ ! -e "$(overlay local-secrets-http)/reverse-proxy-tls.key" ] || fail "a half-made key was left"
}

test_no_install_runs_the_ai_service_unless_it_asks() {
    write || fail "write_overlays failed: $(cat "$WORK_DIR/output")"
    for o in vault-http vault-https local-secrets-http local-secrets-https; do
        assert_not_contains "$(cat "$(overlay "$o")/kustomization.yaml")" "../ai"
    done
}

test_ai_enabled_deploys_the_ai_service_on_vault_installs_only() {
    AI_ENABLED=true write || fail "write_overlays failed: $(cat "$WORK_DIR/output")"
    for o in vault-http vault-https; do
        assert_contains "$(cat "$(overlay "$o")/kustomization.yaml")" "- ../ai"
    done
    for o in local-secrets-http local-secrets-https; do
        assert_not_contains "$(cat "$(overlay "$o")/kustomization.yaml")" "../ai"
    done
}

test_the_ai_overlay_keeps_its_secrets_to_itself() {
    rendered="$(kubectl kustomize "$TEST_ROOT/overlays/ai")" || fail "kubectl kustomize overlays/ai failed"
    assert_contains "$rendered" "image: ghcr.io/5stackgg/ai:latest"
    assert_contains "$rendered" "name: ghcr-pull"
    assert_contains "$rendered" "type: kubernetes.io/dockerconfigjson"
    assert_contains "$rendered" "AI_SERVICE_URL: http://ai:4000"
    assert_contains "$rendered" "value: postgres://ai:\$(AI_DATABASE_PASSWORD)@timescaledb:5432/ai"
    app="$(awk '/^      containers:$/{f=1} /^      initContainers:$/{f=0} f' <<<"$rendered")"
    assert_not_contains "$app" "timescaledb-secrets"
    assert_not_contains "$app" "postgres://hasura"
}

test_the_api_only_takes_the_shared_secret_from_ai_secrets() {
    rendered="$(kubectl kustomize "$TEST_ROOT/base")" || fail "kubectl kustomize base failed"
    assert_contains "$rendered" "key: AI_SERVICE_SECRET"
    assert_contains "$rendered" "name: ai-env"
    if grep -B1 'name: ai-secrets' <<<"$rendered" | grep -q 'secretRef:'; then
        fail "the api takes all of ai-secrets"
    fi
}

test_managed_cloudflare_keeps_http01_and_no_cloudflare_key_in_the_cluster() {
    with_s3_endpoint ""
    printf 'CLOUDFLARE_API_TOKEN=cf-key-0123456789abcdef\n' >"$(overlay local-secrets)/cloudflare-secrets.env"
    (
        export CLOUDFLARE_MANAGED=true CLOUDFLARE_ZONES=example.gg,example.net
        write
    ) || fail "write_overlays failed: $(cat "$WORK_DIR/output")"
    for o in local-secrets-https vault-https; do
        manifest="$(kubectl kustomize "$(overlay "$o")")" || fail "kubectl kustomize $o failed"
        issuer="$(awk '/^kind: Issuer/,/^---/' <<<"$manifest")"
        assert_contains "$issuer" "http01:"
        assert_contains "$issuer" "traefik.ingress.kubernetes.io/router.priority: \"1000000\""
        assert_not_contains "$manifest" "dns01"
        assert_not_contains "$manifest" "cloudflare-secrets"
        assert_not_contains "$manifest" "CLOUDFLARE_API_TOKEN"
        assert_not_contains "$manifest" "cf-key-0123456789abcdef"
        rendered="$(kinds_and_names "$manifest")"
        assert_contains "$rendered" "Ingress/acme-check"
        assert_contains "$rendered" "Middleware/acme-check"
    done
    check="$(awk '/^kind: Ingress/,/^---/' <<<"$(kubectl kustomize "$(overlay local-secrets-https)")")"
    assert_contains "$check" "path: /.well-known/acme-challenge/5stack-check"
    assert_contains "$check" "traefik.ingress.kubernetes.io/router.entrypoints: web"
    assert_contains "$check" "traefik.ingress.kubernetes.io/router.middlewares: 5stack-acme-check@kubernetescrd"
    assert_not_contains "$(cat "$(overlay local-secrets-http)/kustomization.yaml")" "acme-check"
}

run_tests
