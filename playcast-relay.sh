#!/bin/bash

# Deploys the Playcast edge relay: a Cloudflare Worker on the panel's relay
# domain (RELAY_DOMAIN). Game servers' uploads pass straight through it to the
# panel, and Playcast viewers are served from Cloudflare's cache.
#
# Walks through everything it needs: signing in to Cloudflare, the relay
# domain's DNS and SSL settings, the deploy, and the route (set to fail open,
# so the Workers Free daily limit bypasses the worker instead of breaking
# broadcasts). Safe to run again; it updates the worker in place.

PANEL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$PANEL_DIR/utils/colors.sh"
source "$PANEL_DIR/utils/interactive_select.sh"
source "$PANEL_DIR/utils/print_domains_and_hosts.sh"
source "$PANEL_DIR/utils/cloudflare_workers.sh"

WORKER_NAME="5stack-playcast-relay"
WORKER_CONFIG="$PANEL_DIR/cloudflare-workers/playcast-relay/wrangler.toml"

load_domains_and_hosts

if [ -z "$RELAY_DOMAIN" ]; then
    die "RELAY_DOMAIN is not set in overlays/config/api-config.env. Run install.sh first."
fi

banner "Playcast edge relay"
echo "    Puts a Cloudflare Worker in front of https://$RELAY_DOMAIN, so Playcast viewers"
echo "    are served from Cloudflare's cache instead of your server. Needs the domain on"
echo "    Cloudflare; the Workers Free plan covers 100,000 requests a day."

cf_require_node
cf_sign_in "$RELAY_DOMAIN"

step "Finding $RELAY_DOMAIN in Cloudflare"
cf_find_zone "$RELAY_DOMAIN"

cf_wait_for_proxied "$RELAY_DOMAIN"
cf_check_origin "$RELAY_DOMAIN"

step "Ready to deploy"
ok "Worker:  $WORKER_NAME"
ok "Route:   $RELAY_DOMAIN/*"
read -r -p "    Deploy it? [Y/n] " CONFIRM
if [[ "$CONFIRM" =~ ^[Nn] ]]; then
    warn "Nothing deployed."
    exit 0
fi

step "Deploying the worker"
if ! wrangler deploy --config "$WORKER_CONFIG"; then
    die "The deploy failed. See the wrangler output above."
fi

step "Routing $RELAY_DOMAIN through it"
cf_ensure_routes "$WORKER_NAME" true "$RELAY_DOMAIN/*"

# Only the worker answers /health; the panel's own relay has no such path.
step "Waiting for it to answer on https://$RELAY_DOMAIN/health"
for _ in $(seq 1 24); do
    if cf_curl "$RELAY_DOMAIN" -fsS --max-time 10 "https://$RELAY_DOMAIN/health" 2>/dev/null | grep -q "\"worker\":\"$WORKER_NAME\""; then
        ok "The Playcast edge relay is active on $RELAY_DOMAIN"
        ok "Settings -> Application -> Streaming shows it as Online:"
        cf_link "https://$WEB_DOMAIN/settings/application/streaming"
        exit 0
    fi
    sleep 5
done

err "https://$RELAY_DOMAIN/health is not answering from the worker yet."
err "Check the route in $CF_ZONE_NAME's Workers Routes, or run this again in a minute."
cf_link "https://dash.cloudflare.com/$CLOUDFLARE_ACCOUNT_ID/$CF_ZONE_NAME/workers"
exit 1
