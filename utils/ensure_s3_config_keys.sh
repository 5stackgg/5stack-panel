#!/bin/bash

# S3_REGION and S3_FORCE_PATH_STYLE only matter for a remote bucket, but they
# have to be *visible* to be set. copy_config_or_secrets only creates env files
# that do not exist yet, so an install that predates these keys would never see
# them appear in its own s3-config.env -- and an operator on Backblaze or AWS
# has no way to know the api is signing with the defaults.
ensure_s3_config_keys_in_env_file() {
    local env_file=$1

    if [ ! -f "$env_file" ]; then
        return
    fi

    # The first version of this function appended without checking for a
    # trailing newline, so the new key landed on the end of the last line and
    # turned `S3_PORT=` into `S3_PORT=S3_REGION=`. That value goes straight
    # into the api's endpoint as the port (`http://rustfs:S3_REGION=`), which
    # fails URL parsing and takes down every S3 call. Repaired here because
    # update.sh is the only thing that reaches an install that already ran it.
    if grep -qE '^[A-Z0-9_]+=.*S3_REGION=$' "$env_file"; then
        sed -i.bak -E 's/^([A-Z0-9_]+=.*)S3_REGION=$/\1/' "$env_file"
        rm -f "$env_file.bak"
    fi

    # A generated env file routinely ends without a newline, which is what
    # caused the splice above.
    if [ -n "$(tail -c 1 "$env_file")" ]; then
        printf '\n' >> "$env_file"
    fi

    local key
    for key in S3_REGION S3_FORCE_PATH_STYLE; do
        if grep -q "^${key}=" "$env_file"; then
            continue
        fi

        printf '%s=\n' "$key" >> "$env_file"
    done
}
