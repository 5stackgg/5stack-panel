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
        # `|| true`: when every surviving line is filtered out (a single-key
        # file), grep exits 1; without this the mv would be skipped, leaving the
        # stale line in place next to the appended one. The redirect writes the
        # (possibly empty) tmp regardless, so mv always runs.
        grep -v "^$key=" "$file" > "$file.tmp" 2>/dev/null || true
        mv "$file.tmp" "$file"
    fi
    printf '%s=%s\n' "$key" "$value" >> "$file"
}

