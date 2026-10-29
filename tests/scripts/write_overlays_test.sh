#!/bin/bash

# shellcheck source=tests/scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

write() {
    (
        export PANEL_DIR="$WORK_DIR/panel"
        mkdir -p "$PANEL_DIR/overlays"
        cp -R "$TEST_ROOT/overlays/http" "$PANEL_DIR/overlays/http"
        # shellcheck source=utils/write_overlays.sh
        source "$TEST_ROOT/utils/write_overlays.sh"
        write_overlays
    ) >"$WORK_DIR/output" 2>&1
}

overlay() {
    printf '%s' "$WORK_DIR/panel/overlays/$1"
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

run_tests
