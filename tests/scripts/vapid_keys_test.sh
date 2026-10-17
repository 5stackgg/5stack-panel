#!/bin/bash

# shellcheck source=tests/scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

load_vapid_script() {
    # shellcheck source=/dev/null
    source "$TEST_ROOT/utils/generate_vapid_keys.sh"
}

without_xxd() {
    mkdir -p "$WORK_DIR/bin"
    cat >"$WORK_DIR/bin/xxd" <<'SH'
#!/bin/sh
echo "xxd: command not found" >&2
exit 127
SH
    chmod +x "$WORK_DIR/bin/xxd"
    PATH="$WORK_DIR/bin:$PATH"
}

base64url_to_hex() {
    local value
    value="$(printf '%s' "$1" | tr -- '-_' '+/')"
    while [ $((${#value} % 4)) -ne 0 ]; do
        value="$value="
    done
    printf '%s' "$value" | openssl base64 -d -A | od -An -v -tx1 | tr -d ' \n'
}

hex_to_bytes() {
    printf '%b' "$(printf '%s' "$1" | sed 's/../\\x&/g')"
}

# A SEC1 ECPrivateKey with only the scalar and the prime256v1 OID, which is
# enough for openssl to derive the public point.
public_hex_for_private_hex() {
    hex_to_bytes "30310201010420${1}a00a06082a8648ce3d030107" \
        | openssl ec -inform DER -pubout -outform DER 2>/dev/null \
        | tail -c 65 | od -An -v -tx1 | tr -d ' \n'
}

env_value() {
    sed -n "s/^$2=//p" "$1"
}

test_keys_are_generated_without_xxd() {
    load_vapid_script
    without_xxd
    env_file="$WORK_DIR/push-secrets.env"
    output="$(ensure_vapid_keys_in_env_file "$env_file" 2>&1)"
    assert_contains "$output" "Generated Web Push (VAPID) keys"

    private_hex="$(base64url_to_hex "$(env_value "$env_file" WEB_PUSH_PRIVATE_KEY)")"
    public_hex="$(base64url_to_hex "$(env_value "$env_file" WEB_PUSH_PUBLIC_KEY)")"
    assert_eq "${#private_hex}" 64
    assert_eq "${#public_hex}" 130
    assert_eq "$(public_hex_for_private_hex "$private_hex")" "$public_hex"
}

test_keys_that_encode_to_nothing_are_not_written() {
    load_vapid_script
    mkdir -p "$WORK_DIR/bin"
    REAL_OPENSSL="$(command -v openssl)"
    export REAL_OPENSSL
    cat >"$WORK_DIR/bin/openssl" <<'SH'
#!/bin/sh
[ "$1" = base64 ] && exit 1
exec "$REAL_OPENSSL" "$@"
SH
    chmod +x "$WORK_DIR/bin/openssl"
    PATH="$WORK_DIR/bin:$PATH"

    env_file="$WORK_DIR/push-secrets.env"
    printf 'OTHER=1\n' >"$env_file"
    output="$(ensure_vapid_keys_in_env_file "$env_file" 2>&1)"
    assert_not_contains "$output" "Generated Web Push (VAPID) keys"
    assert_eq "$(cat "$env_file")" "OTHER=1"
}

test_existing_keys_are_kept() {
    load_vapid_script
    env_file="$WORK_DIR/push-secrets.env"
    printf 'WEB_PUSH_PUBLIC_KEY=pub\nWEB_PUSH_PRIVATE_KEY=priv\n' >"$env_file"
    output="$(ensure_vapid_keys_in_env_file "$env_file" 2>&1)"
    assert_eq "$output" ""
    assert_eq "$(env_value "$env_file" WEB_PUSH_PUBLIC_KEY)" pub
    assert_eq "$(env_value "$env_file" WEB_PUSH_PRIVATE_KEY)" priv
}

run_tests
