#!/bin/bash

PANEL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$PANEL_DIR/utils/colors.sh"
source "$PANEL_DIR/utils/interactive_select.sh"
source "$PANEL_DIR/utils/print_domains_and_hosts.sh"
source "$PANEL_DIR/utils/update_env_var.sh"
source "$PANEL_DIR/utils/cloudflare_workers.sh"
source "$PANEL_DIR/utils/cloudflare_setup.sh"

WORKER_NAME="5stack-stream-relay"
WORKER_CONFIG="$PANEL_DIR/cloudflare-workers/stream-relay/wrangler.toml"

load_domains_and_hosts

if [ -z "$GAME_STREAM_DOMAIN" ]; then
    die "GAME_STREAM_DOMAIN is not set in overlays/config/api-config.env. Set up streaming first."
fi

banner "Stream edge relay"
echo "    Puts a Cloudflare Worker in front of https://$GAME_STREAM_DOMAIN, so viewers load"
echo "    streams from Cloudflare and never see this server's address. Each video piece"
echo "    leaves this server once per Cloudflare location instead of once per viewer."
echo
echo "    Each viewer makes about two requests a second. Cloudflare's free Workers plan"
echo "    covers 100,000 requests a day, and streams stop until the next day once they"
echo "    run out. Busy panels need Workers Paid: \$5 a month for 10 million requests."

if cf_load_token; then
    step "Setting it up with the panel's Cloudflare key"
    cloudflare_setup stream-relay
    status=$?
    if [ "$status" = 0 ]; then
        update_env_var "$PANEL_DIR/.5stack-env.config" CLOUDFLARE_STREAM_RELAY true
        ok "Updates keep the Worker deployed."
    fi
    exit "$status"
fi

cf_require_node
cf_sign_in "$GAME_STREAM_DOMAIN"

step "Finding $GAME_STREAM_DOMAIN in Cloudflare"
cf_find_zone "$GAME_STREAM_DOMAIN"

cf_wait_for_proxied "$GAME_STREAM_DOMAIN"
cf_check_origin "$GAME_STREAM_DOMAIN"

step "Ready to deploy"
ok "Worker:  $WORKER_NAME"
ok "Route:   $GAME_STREAM_DOMAIN/*"
read -r -p "    Deploy it? [Y/n] " CONFIRM
if [[ "$CONFIRM" =~ ^[Nn] ]]; then
    warn "Nothing deployed."
    exit 0
fi

step "Deploying the worker"
if ! wrangler deploy --config "$WORKER_CONFIG" --var "WEB_ORIGIN:https://$WEB_DOMAIN"; then
    die "The deploy failed. See the wrangler output above."
fi

step "Routing $GAME_STREAM_DOMAIN through it"
cf_ensure_routes "$WORKER_NAME" false "$GAME_STREAM_DOMAIN/*"

step "Waiting for it to answer on https://$GAME_STREAM_DOMAIN/health"
for _ in $(seq 1 24); do
    if cf_curl "$GAME_STREAM_DOMAIN" -fsS --max-time 10 "https://$GAME_STREAM_DOMAIN/health" 2>/dev/null | grep -q "\"worker\":\"$WORKER_NAME\""; then
        ok "The stream edge relay is active on $GAME_STREAM_DOMAIN"
        exit 0
    fi
    sleep 5
done

err "https://$GAME_STREAM_DOMAIN/health is not answering from the worker yet."
err "Check the route in $CF_ZONE_NAME's Workers Routes, or run this again in a minute."
cf_link "https://dash.cloudflare.com/$CLOUDFLARE_ACCOUNT_ID/$CF_ZONE_NAME/workers"
exit 1
