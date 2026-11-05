#!/bin/bash

# Lets 5Stack manage this panel's hostnames on Cloudflare: the DNS records, the
# proxy on every hostname but demo uploads and streams, and HTTPS Full (strict),
# with Let's Encrypt's plain HTTP check let through. Then applies the panel.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/utils/utils.sh" --cloudflare-managed "$@"

if [ "$VAULT_MANAGER" = true ] && ! vault kv get -field=CLOUDFLARE_API_TOKEN kv/cloudflare >/dev/null 2>&1; then
    step "Cloudflare API token"
    echo "    Make a token on Cloudflare's page; the permissions 5Stack needs are filled in:"
    echo "    $(cloudflare_token_url)"
    read -rs -p "    Paste the token: " CLOUDFLARE_API_TOKEN
    echo
    [ -n "$CLOUDFLARE_API_TOKEN" ] || die "No token, so nothing changed."
    jq -n --arg t "$CLOUDFLARE_API_TOKEN" '{CLOUDFLARE_API_TOKEN: $t}' | vault kv put kv/cloudflare - >/dev/null || die "Could not save the token in Vault at kv/cloudflare."
    export CLOUDFLARE_API_TOKEN
fi

step "Checking Cloudflare"
problems="$(cloudflare_setup check)" || exit 1
if [ -n "$problems" ]; then
    while read -r line; do
        err "${line#*: }"
    done <<<"$problems"
    die "Fix these in Cloudflare, then run ./cloudflare.sh again."
fi
cloudflare_setup plan | while read -r _ host _ zone proxied why; do
    case "$proxied" in
        yes) ok "$host · through Cloudflare ($zone)" ;;
        no) ok "$host · straight to this server ($why)" ;;
        skip) ok "$host · left alone ($why)" ;;
    esac
done

"$SCRIPT_DIR/update.sh" "$@"
