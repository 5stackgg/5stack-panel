#!/bin/bash

# Deploys the Backblaze proxy: a Cloudflare Worker in front of the S3 bucket
# (Backblaze B2) that serves demos, clips, news images, event media and map
# assets through Cloudflare, so B2 egress is free and popular files come from
# the edge.
#
# Walks through everything it needs: the hostname (default cf.<WEB_DOMAIN>),
# signing in to Cloudflare, the hostname's DNS record, the deploy, the bucket
# keys and the routes. The bucket comes from the panel's config. Safe to run
# again; it updates the worker in place and keeps any routes it already has on
# other hostnames, so older links keep working.
#
#   ./backblaze-proxy.sh [hostname]

PANEL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$PANEL_DIR/utils/colors.sh"
source "$PANEL_DIR/utils/interactive_select.sh"
source "$PANEL_DIR/utils/print_domains_and_hosts.sh"
source "$PANEL_DIR/utils/cloudflare_workers.sh"

# Existing Cloudflare routes point at this name; renaming spawns a second
# worker while the old one keeps serving.
WORKER_NAME="5stack"
WORKER_DIR="$PANEL_DIR/cloudflare-workers/backblaze-proxy"
DOCS_URL="https://docs.5stack.gg/advanced/s3/backblaze"
ROUTE_PATHS=("/demo*" "/clips*" "/news*" "/maps*" "/events*")

read_env() {
    grep -h "^$1=" "$2" 2>/dev/null | cut -d '=' -f2-
}

normalize_host() {
    local host="$1"
    host="${host#*://}"
    host="${host%%/*}"
    host="$(echo "$host" | tr '[:upper:]' '[:lower:]')"
    if [ -n "$host" ] && [[ "$host" != *.* ]] && [ -n "$WEB_DOMAIN" ]; then
        host="$host.$WEB_DOMAIN"
    fi
    echo "$host"
}

panel_host_name() {
    local var
    for var in WEB_DOMAIN API_DOMAIN WS_DOMAIN RELAY_DOMAIN DEMOS_DOMAIN GAME_STREAM_DOMAIN S3_CONSOLE_HOST TYPESENSE_HOST; do
        if [ -n "${!var}" ] && [ "${!var}" = "$1" ]; then
            echo "$var"
            return
        fi
    done
}

load_domains_and_hosts

S3_BUCKET="${S3_BUCKET:-$(read_env S3_BUCKET "$PANEL_DIR/overlays/config/s3-config.env")}"
S3_ENDPOINT="${S3_ENDPOINT:-$(read_env S3_ENDPOINT "$PANEL_DIR/overlays/config/s3-config.env")}"
S3_ENDPOINT="${S3_ENDPOINT#*://}"
S3_ENDPOINT="${S3_ENDPOINT%/}"
S3_ACCESS_KEY="${S3_ACCESS_KEY:-$(read_env S3_ACCESS_KEY "$PANEL_DIR/overlays/local-secrets/s3-secrets.env")}"
S3_SECRET="${S3_SECRET:-$(read_env S3_SECRET "$PANEL_DIR/overlays/local-secrets/s3-secrets.env")}"

banner "Backblaze proxy"
echo "    Puts a Cloudflare Worker in front of your B2 bucket, so demos, clips, news"
echo "    images, event media and map assets are served through Cloudflare: free B2"
echo "    egress, and popular files come from Cloudflare's cache."

if [ -z "$S3_BUCKET" ] || [ -z "$S3_ENDPOINT" ]; then
    err "The panel is not set up with a bucket yet: S3_BUCKET and S3_ENDPOINT are empty in"
    err "overlays/config/s3-config.env. Set up Backblaze B2 first:"
    cf_link "$DOCS_URL"
    exit 1
fi

# The worker reaches the bucket at https://<bucket>.<endpoint>, so the in-cluster
# storage the panel ships with cannot sit behind it.
if [[ "$S3_ENDPOINT" != *.* ]]; then
    err "S3_ENDPOINT ($S3_ENDPOINT) is the panel's own storage, not a public S3 host."
    err "This worker is for a remote bucket such as Backblaze B2"
    err "(e.g. s3.us-east-005.backblazeb2.com):"
    cf_link "$DOCS_URL"
    exit 1
fi

cf_require_node

if [ -z "$S3_ACCESS_KEY" ] || [ -z "$S3_SECRET" ]; then
    step "Bucket keys"
    warn "S3_ACCESS_KEY and S3_SECRET are not in overlays/local-secrets/s3-secrets.env"
    warn "(with Vault they live there instead). Enter the same keys the panel uses; they"
    warn "are stored in Cloudflare as worker secrets and nowhere else."
    while [ -z "$S3_ACCESS_KEY" ]; do
        read -r -p "    S3 access key ID: " S3_ACCESS_KEY
    done
    while [ -z "$S3_SECRET" ]; do
        read_masked "    S3 secret key: " S3_SECRET
    done
fi

step "Hostname"
echo "    The worker gets a hostname of its own, on a domain you have on Cloudflare."
DEFAULT_HOST=""
if [ -n "$WEB_DOMAIN" ]; then
    DEFAULT_HOST="cf.$WEB_DOMAIN"
fi
WORKER_HOST="$(normalize_host "$1")"
while true; do
    if [ -z "$WORKER_HOST" ]; then
        read -r -p "    Hostname for the worker${DEFAULT_HOST:+ [$DEFAULT_HOST]}: " WORKER_HOST
        WORKER_HOST="$(normalize_host "${WORKER_HOST:-$DEFAULT_HOST}")"
    fi
    CONFLICT="$(panel_host_name "$WORKER_HOST")"
    if [ -z "$WORKER_HOST" ]; then
        continue
    elif [[ "$WORKER_HOST" != *.* ]]; then
        err "Enter the full hostname, like cf.example.com."
    elif [ -n "$CONFLICT" ]; then
        err "$WORKER_HOST is the panel's own $CONFLICT. The worker takes over"
        err "${ROUTE_PATHS[*]} on its hostname, which would break the panel there."
        err "Use a hostname only the worker answers, like ${DEFAULT_HOST:-cf.<your domain>}."
    else
        break
    fi
    WORKER_HOST=""
done

cf_sign_in "$WORKER_HOST"

step "Finding $WORKER_HOST in Cloudflare"
cf_find_zone "$WORKER_HOST"

cf_wait_for_proxied "$WORKER_HOST" placeholder

ROUTES=()
for path in "${ROUTE_PATHS[@]}"; do
    ROUTES+=("$WORKER_HOST$path")
done

VARS=(--var "BUCKET_NAME:$S3_BUCKET" --var "S3_ENDPOINT:$S3_ENDPOINT")
if [ -n "$API_DOMAIN" ]; then
    VARS+=(--var "API_URL:https://$API_DOMAIN")
fi

step "Ready to deploy"
ok "Worker:   $WORKER_NAME"
ok "Hostname: https://$WORKER_HOST (${ROUTE_PATHS[*]})"
ok "Bucket:   $S3_BUCKET at $S3_ENDPOINT"
if [ -n "$API_DOMAIN" ]; then
    ok "API:      https://$API_DOMAIN (clip views are counted there)"
fi
read -r -p "    Deploy it? [Y/n] " CONFIRM
if [[ "$CONFIRM" =~ ^[Nn] ]]; then
    warn "Nothing deployed."
    exit 0
fi

step "Installing the worker's dependencies"
if ! npm ci --silent --no-audit --no-fund --prefix "$WORKER_DIR"; then
    die "npm ci failed. See the output above."
fi

step "Deploying the worker"
if ! wrangler deploy --config "$WORKER_DIR/wrangler.toml" "${VARS[@]}"; then
    die "The deploy failed. See the wrangler output above."
fi

step "Storing the bucket keys as worker secrets"
SECRETS_FILE="$(mktemp)"
trap 'rm -f "$SECRETS_FILE"' EXIT
chmod 600 "$SECRETS_FILE"
S3_ACCESS_KEY="$S3_ACCESS_KEY" S3_SECRET="$S3_SECRET" node -e \
    'process.stdout.write(JSON.stringify({ S3_ACCESS_KEY: process.env.S3_ACCESS_KEY, S3_SECRET: process.env.S3_SECRET }))' \
    > "$SECRETS_FILE"
if ! wrangler secret bulk "$SECRETS_FILE" --config "$WORKER_DIR/wrangler.toml"; then
    die "Storing the secrets failed. See the wrangler output above."
fi

step "Routing $WORKER_HOST through it"
cf_ensure_routes "$WORKER_NAME" false "${ROUTES[@]}"

step "Waiting for it to answer on https://$WORKER_HOST"
ANSWERING=false
for _ in $(seq 1 24); do
    if cf_curl "$WORKER_HOST" -sS -o /dev/null -D - --max-time 10 -X OPTIONS \
        -H "Origin: https://${WEB_DOMAIN:-example.com}" "https://$WORKER_HOST/clips/" 2>/dev/null \
        | grep -qi '^access-control-allow-methods: GET, HEAD, PUT, OPTIONS'; then
        ANSWERING=true
        break
    fi
    sleep 5
done
if [ "$ANSWERING" != true ]; then
    err "https://$WORKER_HOST is not answering from the worker yet."
    err "Check the routes in $CF_ZONE_NAME's Workers Routes, or run this again in a minute."
    cf_link "https://dash.cloudflare.com/$CLOUDFLARE_ACCOUNT_ID/$CF_ZONE_NAME/workers"
    exit 1
fi
ok "The Backblaze proxy is live on https://$WORKER_HOST"

if [ -n "$CF_OTHER_ROUTES" ]; then
    ok "Its earlier routes were kept, so links that still use them keep working:"
    while IFS= read -r route; do
        ok "  $route"
    done <<< "$CF_OTHER_ROUTES"
fi

step "Last step: point the panel at it"
echo "    In Settings -> Application -> Demo settings, set Cloudflare Worker URL to"
echo "    https://$WORKER_HOST"
if [ -n "$WEB_DOMAIN" ]; then
    cf_link "https://$WEB_DOMAIN/settings/application/demo-settings"
fi
echo
echo "    Recommended: turn on Smart Tiered Cache for $CF_ZONE_NAME, so each file is"
echo "    fetched from B2 once rather than once per Cloudflare location."
cf_link "https://dash.cloudflare.com/$CLOUDFLARE_ACCOUNT_ID/$CF_ZONE_NAME/caching/tiered-cache"
