#!/bin/bash

replace_rand32_in_env_files() {
    local secrets_dir=$1
    
    if [ ! -d "$secrets_dir" ]; then
        echo "Warning: Secrets directory $secrets_dir not found, skipping RAND32 replacement..."
        return
    fi
    
    # Replace each $(RAND32) with its OWN fresh random value. The previous global
    # (g) sed used one value per file, so paired secrets came out identical
    # (e.g. APP_KEY == ENC_SECRET, S3_ACCESS_KEY == S3_SECRET) and learning the
    # semi-public one leaked its partner. Rewrite line by line using bash's
    # replace-first substitution (not sed) so each occurrence gets a distinct
    # value and no secret is ever interpreted as a sed pattern.
    for env_file in "$secrets_dir"/*.env; do
        if [[ -f "$env_file" && ! "$env_file" == *.example ]]; then
            local tmp_file
            tmp_file=$(mktemp)
            while IFS= read -r line || [[ -n "$line" ]]; do
                while [[ "$line" == *'$(RAND32)'* ]]; do
                    # base64 alphabet minus '/' and padding '='; the remaining
                    # chars ([A-Za-z0-9+_]) are all literal in the replacement.
                    random_string=$(openssl rand -base64 32 | tr '/' '_' | tr '=' '_')
                    line=${line/'$(RAND32)'/$random_string}
                done
                printf '%s\n' "$line" >> "$tmp_file"
            done < "$env_file"
            mv "$tmp_file" "$env_file"
        fi
    done
}

