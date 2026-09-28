#!/bin/bash

# Deploys the Playcast edge relay: a Cloudflare Worker that runs as a route on
# the panel's relay domain (RELAY_DOMAIN). Game servers' uploads pass straight
# through it to the panel, and Playcast viewers are served from Cloudflare's
# cache.
#
# The relay domain has to be proxied through Cloudflare (orange cloud).
# Wrangler signs in to Cloudflare in a browser the first time; on a machine
# without one, export CLOUDFLARE_API_TOKEN (Workers Scripts: Edit and Workers
# Routes: Edit) first.

PANEL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$PANEL_DIR/utils/colors.sh"
source "$PANEL_DIR/utils/print_domains_and_hosts.sh"

load_domains_and_hosts

if [ -z "$RELAY_DOMAIN" ]; then
    err "RELAY_DOMAIN is not set in overlays/config/api-config.env. Run install.sh first."
    exit 1
fi

if ! command -v npx >/dev/null 2>&1; then
    err "npx was not found. Install Node.js (https://nodejs.org), or run this from a machine that has it."
    exit 1
fi

step "Checking that $RELAY_DOMAIN goes through Cloudflare"
if ! curl -sI --max-time 10 "https://$RELAY_DOMAIN/" | grep -qi "^server: cloudflare"; then
    err "$RELAY_DOMAIN is not proxied through Cloudflare."
    err "Turn on the proxy (orange cloud) for its DNS record in Cloudflare, then run this again."
    exit 1
fi
ok "$RELAY_DOMAIN is proxied through Cloudflare"

step "Deploying the Playcast edge relay to $RELAY_DOMAIN"
if ! npx --yes wrangler@4 deploy \
    --config "$PANEL_DIR/cloudflare-workers/playcast-relay/wrangler.toml" \
    --route "$RELAY_DOMAIN/*"; then
    err "The deploy failed. See the wrangler output above."
    exit 1
fi

# Only the worker answers /health; the panel's own relay has no such path.
step "Waiting for it to answer on https://$RELAY_DOMAIN/health"
for _ in $(seq 1 24); do
    if curl -fsS --max-time 10 "https://$RELAY_DOMAIN/health" 2>/dev/null | grep -q '"worker":"5stack-playcast-relay"'; then
        ok "The Playcast edge relay is active on $RELAY_DOMAIN"
        warn "One last step in the Cloudflare dashboard: set this route's request limit"
        warn "failure mode to \"Fail open\", so broadcasts keep reaching the panel if the"
        warn "daily Workers limit is ever reached."
        exit 0
    fi
    sleep 5
done

err "https://$RELAY_DOMAIN/health is not answering from the worker yet."
err "Check the worker's route in the Cloudflare dashboard."
exit 1
