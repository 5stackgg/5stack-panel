#!/bin/bash

# The shared secret the API signs short-lived TURN credentials with, and that
# coturn verifies them against. One secret, one file, mounted by both -- two
# copies of it would be a rotation bug waiting to happen.
#
# Added here rather than only in coturn-secrets.env.example because
# copy_config_or_secrets only creates env files that do not already exist, so an
# existing install would never pick a new key up -- and coturn refuses to start
# without one rather than come up as an open relay.
#
# Deliberately never regenerates: rotating it invalidates every credential
# already handed out, which would drop anyone mid-call until their client asked
# for a fresh one.
ensure_turn_secret_in_env_file() {
    local env_file=$1

    if [ ! -f "$env_file" ]; then
        touch "$env_file" || return
    fi

    # Present AND non-empty. An empty value is the case coturn exits on, so it
    # has to count as missing here.
    if grep -q "^TURN_SECRET=." "$env_file"; then
        return
    fi

    local secret
    secret=$(openssl rand -hex 32)

    if [ -z "$secret" ]; then
        echo "Warning: unable to generate TURN secret (openssl missing?)" >&2
        return
    fi

    # Drop a blank placeholder so the key can never end up in the file twice.
    local tmp_file
    tmp_file=$(mktemp)
    grep -v "^TURN_SECRET=" "$env_file" > "$tmp_file"
    mv "$tmp_file" "$env_file"

    # An env file that does not end in a newline would otherwise have this
    # appended onto whatever its last line is, corrupting both.
    if [ -s "$env_file" ] && [ -n "$(tail -c 1 "$env_file")" ]; then
        printf '\n' >> "$env_file"
    fi

    printf 'TURN_SECRET=%s\n' "$secret" >> "$env_file"

    echo "Generated TURN shared secret"
}
