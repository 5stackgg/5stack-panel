#!/bin/bash

update_env_var() {
    local file=$1
    local key=$2
    local value=$3

    # Never feed the value through sed: a secret containing sed metacharacters
    # ('|' delimiter, '&', trailing '\') would corrupt or silently drop the
    # value (a Steam password like 'p@ss|word' broke the substitution). Instead
    # remove any existing line for the key, then append the value literally with
    # printf. Env files are order-independent, so re-appending is safe.
    if [ -f "$file" ] && grep -q "^$key=" "$file" 2>/dev/null; then
        grep -v "^$key=" "$file" > "$file.tmp" && mv "$file.tmp" "$file"
    fi
    printf '%s=%s\n' "$key" "$value" >> "$file"
}

