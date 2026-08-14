#!/bin/bash

# VAPID keys identify this panel to the browsers' push services when sending
# Web Push notifications. They are self-signed -- there is no service to
# register with, no account, and no cost -- so they are generated here rather
# than asked of the operator.
#
# Not $(RAND32): this is a P-256 keypair, and the public half has to be the
# curve point derived from the private half. Two unrelated random strings would
# be accepted by the env file and then rejected by every push service.
generate_vapid_keypair() {
    local text
    text=$(openssl ecparam -name prime256v1 -genkey -noout 2>/dev/null \
        | openssl ec -text -noout 2>/dev/null)

    if [ -z "$text" ]; then
        echo "Warning: unable to generate VAPID keys (openssl missing?)" >&2
        return 1
    fi

    # openssl prints the 32-byte private scalar and the 65-byte uncompressed
    # public point (0x04 || X || Y) as colon-separated hex.
    local priv_hex pub_hex
    priv_hex=$(printf '%s\n' "$text" | sed -n '/priv:/,/pub:/p' | grep -v 'priv:\|pub:' | tr -d ' :\n')
    pub_hex=$(printf '%s\n' "$text" | sed -n '/pub:/,/ASN1 OID/p' | grep -v 'pub:\|ASN1 OID' | tr -d ' :\n')

    # A leading zero byte is sometimes emitted as padding; VAPID wants exactly
    # 32 bytes.
    priv_hex=${priv_hex: -64}

    if [ ${#priv_hex} -ne 64 ] || [ ${#pub_hex} -ne 130 ]; then
        echo "Warning: generated VAPID key had an unexpected length, skipping" >&2
        return 1
    fi

    # base64url, unpadded -- the encoding the Web Push spec uses.
    VAPID_PRIVATE_KEY=$(printf '%s' "$priv_hex" | xxd -r -p | openssl base64 -A | tr '+/' '-_' | tr -d '=')
    VAPID_PUBLIC_KEY=$(printf '%s' "$pub_hex" | xxd -r -p | openssl base64 -A | tr '+/' '-_' | tr -d '=')
}

# Fills in the web push keys only when they are missing.
#
# Deliberately never regenerates: rotating the keypair invalidates every
# existing push subscription, since browsers signed up against the old public
# key. An update must not silently unsubscribe everyone.
ensure_vapid_keys_in_env_file() {
    local env_file=$1

    # An install that predates this file won't have it at all.
    if [ ! -f "$env_file" ]; then
        touch "$env_file" || return
    fi

    # Both must be present AND non-empty. Half a pair is worse than none: the
    # public key has to be the point derived from the private one, so a
    # mismatched pair is accepted by the env file and rejected by every push
    # service.
    if grep -q "^WEB_PUSH_PUBLIC_KEY=." "$env_file" && grep -q "^WEB_PUSH_PRIVATE_KEY=." "$env_file"; then
        return
    fi

    if ! generate_vapid_keypair; then
        return
    fi

    # Drop any blank or half-written placeholders, so the keys can never end up
    # in the file twice.
    local tmp_file
    tmp_file=$(mktemp)
    grep -v "^WEB_PUSH_PUBLIC_KEY=\|^WEB_PUSH_PRIVATE_KEY=" "$env_file" > "$tmp_file"
    mv "$tmp_file" "$env_file"

    # An env file that doesn't end in a newline would otherwise have the first
    # key appended onto whatever its last line is, silently corrupting both.
    if [ -s "$env_file" ] && [ -n "$(tail -c 1 "$env_file")" ]; then
        printf '\n' >> "$env_file"
    fi

    printf 'WEB_PUSH_PUBLIC_KEY=%s\n' "$VAPID_PUBLIC_KEY" >> "$env_file"
    printf 'WEB_PUSH_PRIVATE_KEY=%s\n' "$VAPID_PRIVATE_KEY" >> "$env_file"

    echo "Generated Web Push (VAPID) keys"
}
