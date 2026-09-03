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

    local key
    for key in S3_REGION S3_FORCE_PATH_STYLE; do
        if grep -q "^${key}=" "$env_file"; then
            continue
        fi

        printf '%s=\n' "$key" >> "$env_file"
    done
}
