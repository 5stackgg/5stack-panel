#!/bin/bash

# Deploys the Backblaze proxy: a Cloudflare Worker in front of the S3 bucket
# (Backblaze B2) that serves demos, clips, news images and map assets through
# Cloudflare, so B2 egress is free and popular files come from the edge. The
# bucket, endpoint and keys come from the panel's config; the hostname to put
# it on is asked for (or given as the first argument).
#
# The hostname has to be on a domain proxied through Cloudflare (orange cloud).
# Wrangler signs in to Cloudflare in a browser the first time; on a machine
# without one, export CLOUDFLARE_API_TOKEN (Workers Scripts: Edit and Workers
# Routes: Edit) first.
#
# Panels keeping their secrets in Vault can export S3_ACCESS_KEY and S3_SECRET
# before running this instead.

PANEL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$PANEL_DIR/utils/colors.sh"
source "$PANEL_DIR/utils/print_domains_and_hosts.sh"

WORKER_DIR="$PANEL_DIR/cloudflare-workers/backblaze-proxy"

read_env() {
    grep -h "^$1=" "$2" 2>/dev/null | cut -d '=' -f2-
}

load_domains_and_hosts

S3_BUCKET="${S3_BUCKET:-$(read_env S3_BUCKET "$PANEL_DIR/overlays/config/s3-config.env")}"
S3_ENDPOINT="${S3_ENDPOINT:-$(read_env S3_ENDPOINT "$PANEL_DIR/overlays/config/s3-config.env")}"
S3_ENDPOINT="${S3_ENDPOINT#*://}"
S3_ENDPOINT="${S3_ENDPOINT%/}"
S3_ACCESS_KEY="${S3_ACCESS_KEY:-$(read_env S3_ACCESS_KEY "$PANEL_DIR/overlays/local-secrets/s3-secrets.env")}"
S3_SECRET="${S3_SECRET:-$(read_env S3_SECRET "$PANEL_DIR/overlays/local-secrets/s3-secrets.env")}"

if [ -z "$S3_BUCKET" ] || [ -z "$S3_ENDPOINT" ]; then
    err "S3_BUCKET and S3_ENDPOINT have to be set in overlays/config/s3-config.env."
    exit 1
fi

# The worker reaches the bucket at https://<bucket>.<endpoint>, so the in-cluster
# storage the panel ships with cannot sit behind it.
if [[ "$S3_ENDPOINT" != *.* ]]; then
    err "S3_ENDPOINT ($S3_ENDPOINT) is not a public S3 host. This worker is for a"
    err "remote bucket such as Backblaze B2 (e.g. s3.us-east-005.backblazeb2.com)."
    exit 1
fi

if [ -z "$S3_ACCESS_KEY" ] || [ -z "$S3_SECRET" ]; then
    err "S3_ACCESS_KEY and S3_SECRET were not found in overlays/local-secrets/s3-secrets.env."
    err "Export them before running this if your secrets live in Vault."
    exit 1
fi

if ! command -v npx >/dev/null 2>&1; then
    err "npx was not found. Install Node.js (https://nodejs.org), or run this from a machine that has it."
    exit 1
fi

WORKER_HOST="$1"
if [ -z "$WORKER_HOST" ]; then
    DEFAULT_HOST="demo-dl.${WEB_DOMAIN:-example.com}"
    read -r -p "Hostname for the worker [$DEFAULT_HOST]: " WORKER_HOST
    WORKER_HOST="${WORKER_HOST:-$DEFAULT_HOST}"
fi

step "Checking that $WORKER_HOST goes through Cloudflare"
if ! curl -sI --max-time 10 "https://$WORKER_HOST/" | grep -qi "^server: cloudflare"; then
    err "$WORKER_HOST is not proxied through Cloudflare."
    err "Add a DNS record for it with the proxy on (orange cloud), then run this again."
    exit 1
fi
ok "$WORKER_HOST is proxied through Cloudflare"

step "About to deploy the Backblaze proxy"
ok "Hostname: https://$WORKER_HOST"
ok "Bucket:   $S3_BUCKET at $S3_ENDPOINT"
ok "API:      https://$API_DOMAIN"
read -r -p "Deploy it? [y/N] " CONFIRM
if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    warn "Nothing deployed."
    exit 0
fi

step "Installing the worker's dependencies"
if ! npm ci --silent --no-audit --no-fund --prefix "$WORKER_DIR"; then
    err "npm ci failed. See the output above."
    exit 1
fi

step "Deploying to $WORKER_HOST"
if ! npx --yes wrangler@4 deploy \
    --config "$WORKER_DIR/wrangler.toml" \
    --var "BUCKET_NAME:$S3_BUCKET" \
    --var "S3_ENDPOINT:$S3_ENDPOINT" \
    --var "API_URL:https://$API_DOMAIN" \
    --route "$WORKER_HOST/demo*" \
    --route "$WORKER_HOST/clips*" \
    --route "$WORKER_HOST/news*" \
    --route "$WORKER_HOST/maps*"; then
    err "The deploy failed. See the wrangler output above."
    exit 1
fi

step "Setting the bucket keys as worker secrets"
SECRETS_FILE="$(mktemp)"
trap 'rm -f "$SECRETS_FILE"' EXIT
chmod 600 "$SECRETS_FILE"
S3_ACCESS_KEY="$S3_ACCESS_KEY" S3_SECRET="$S3_SECRET" node -e \
    'process.stdout.write(JSON.stringify({ S3_ACCESS_KEY: process.env.S3_ACCESS_KEY, S3_SECRET: process.env.S3_SECRET }))' \
    > "$SECRETS_FILE"
if ! npx --yes wrangler@4 secret bulk "$SECRETS_FILE" --config "$WORKER_DIR/wrangler.toml"; then
    err "Setting the secrets failed. See the wrangler output above."
    exit 1
fi

ok "The Backblaze proxy is deployed on https://$WORKER_HOST"
warn "Last step: in the panel, open Settings -> Application -> Demo settings and"
warn "set the Cloudflare Worker URL to https://$WORKER_HOST"
