#!/bin/bash

# Deploys the Backblaze proxy: a Cloudflare Worker in front of the S3 bucket
# (Backblaze B2) that serves demos, clips, news images, event media and map
# assets through Cloudflare, so B2 egress is free and popular files come from
# the edge.
#
# Walks through everything it needs: the bucket keys, the hostname (default
# cf.<WEB_DOMAIN>), signing in to Cloudflare, the hostname's DNS record, the
# deploy and the routes, then saves the hostname as CLOUDFLARE_WORKER_DOMAIN
# in overlays/config/api-config.env, which the panel builds its download URLs
# from, and offers Smart Tiered Cache.
#
# The bucket comes from the panel's config. The keys come from the cluster on
# Vault installs and from overlays/local-secrets otherwise, and Backblaze has
# to accept them before anything is deployed: one worker serves every panel
# pointed at it, so bad keys would break downloads for all of them.
#
# Safe to run again; it updates the worker in place and keeps any routes it
# already has on other hostnames, so older links keep working.
#
#   ./backblaze-proxy.sh [hostname]

PANEL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$PANEL_DIR/utils/colors.sh"
source "$PANEL_DIR/utils/interactive_select.sh"
source "$PANEL_DIR/utils/print_domains_and_hosts.sh"
source "$PANEL_DIR/utils/update_env_var.sh"
source "$PANEL_DIR/utils/cloudflare_workers.sh"

# Existing Cloudflare routes point at this name; renaming spawns a second
# worker while the old one keeps serving.
WORKER_NAME="5stack"
WORKER_DIR="$PANEL_DIR/cloudflare-workers/backblaze-proxy"
DOCS_URL="https://docs.5stack.gg/advanced/s3/backblaze"
ROUTE_PATHS=("/demo*" "/clips*" "/news*" "/maps*" "/events*")

read_env() {
    grep -h "^$1=" "$2" 2>/dev/null | tail -n 1 | cut -d '=' -f2-
}

# With Vault the files in overlays/local-secrets are placeholders; the real
# values are only in the cluster, synced from Vault under these names.
read_cluster_secret() {
    kubectl --kubeconfig="$PANEL_KUBECONFIG" -n 5stack get secret "$1" -o "jsonpath={.data.$2}" 2>/dev/null \
        | base64 --decode 2>/dev/null
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

# panel_graphql QUERY VARIABLES -- runs QUERY against the panel's Hasura as
# admin, the same way the web's settings pages write settings.
panel_graphql() {
    local body
    body="$(node -p 'JSON.stringify({ query: process.argv[1], variables: JSON.parse(process.argv[2]) })' "$1" "$2")"
    printf 'header = "x-hasura-admin-secret: %s"\n' "$HASURA_ADMIN_SECRET" \
        | curl -sS -K - --max-time 15 -H "Content-Type: application/json" \
            --data "$body" "https://$API_DOMAIN/v1/graphql"
}

# The api copies CLOUDFLARE_WORKER_DOMAIN into this setting when it boots;
# writing it here as well means it applies without an ./update.sh.
set_live_worker_url() {
    local variables
    variables="$(node -p 'JSON.stringify({ value: process.argv[1] })' "$1")"
    [ -n "$(panel_graphql \
        'mutation ($value: String!) { insert_settings(objects: [{ name: "cloudflare_worker_url", value: $value }], on_conflict: { constraint: settings_pkey, update_columns: [value] }) { affected_rows } }' \
        "$variables" | cf_json 'j.data?.insert_settings ? "ok" : undefined')" ]
}

# The api copies CLOUDFLARE_WORKER_DOMAIN into its setting when it restarts,
# which ./update.sh does whenever the config changed.
offer_update() {
    local answer
    if [ ! -f "$PANEL_KUBECONFIG" ]; then
        warn "Could not apply it to the running panel from here. Run ./update.sh on your"
        warn "panel's server to apply it."
        return
    fi
    warn "Could not apply it to the running panel directly, so ./update.sh has to apply it."
    read -r -p "    Run ./update.sh now, against the cluster in $PANEL_KUBECONFIG? [Y/n] " answer
    if [[ "$answer" =~ ^[Nn] ]]; then
        warn "Run ./update.sh to apply it."
        return
    fi
    if ! "$PANEL_DIR/update.sh"; then
        die "./update.sh failed. See the output above."
    fi
    ok "The panel now serves demos, clips and media through $WORKER_URL"
}

# Signs a read of an object that does not exist and prints Backblaze's error
# code. A missing object and a key without list access both come back as
# AccessDenied or NoSuchKey; only a bad key ID or secret is rejected outright.
bucket_key_check() {
    (cd "$WORKER_DIR" && S3_ACCESS_KEY="$S3_ACCESS_KEY" S3_SECRET="$S3_SECRET" node --input-type=module -e '
        import { AwsClient } from "aws4fetch";
        const client = new AwsClient({
            accessKeyId: process.env.S3_ACCESS_KEY,
            secretAccessKey: process.env.S3_SECRET,
            service: "s3",
        });
        const url = `https://${process.argv[1]}.${process.argv[2]}/.5stack-key-check-${crypto.randomUUID()}`;
        try {
            const signed = await client.sign(url, { method: "GET", headers: new Headers() });
            const response = await fetch(signed.url, { method: "GET", headers: signed.headers });
            const body = await response.text();
            process.stdout.write((body.match(/<Code>([^<]+)</) || [])[1] || `HTTP ${response.status}`);
        } catch (error) {
            process.stdout.write(`unreachable (${error.message})`);
        }
    ' "$S3_BUCKET" "$S3_ENDPOINT")
}

load_domains_and_hosts

S3_BUCKET="${S3_BUCKET:-$(read_env S3_BUCKET "$PANEL_DIR/overlays/config/s3-config.env")}"
S3_ENDPOINT="${S3_ENDPOINT:-$(read_env S3_ENDPOINT "$PANEL_DIR/overlays/config/s3-config.env")}"
S3_ENDPOINT="${S3_ENDPOINT#*://}"
S3_ENDPOINT="${S3_ENDPOINT%/}"
PANEL_KUBECONFIG="$(read_env KUBECONFIG "$PANEL_DIR/.5stack-env.config")"
PANEL_KUBECONFIG="${PANEL_KUBECONFIG:-${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}}"
VAULT_MANAGER="$(read_env VAULT_MANAGER "$PANEL_DIR/.5stack-env.config")"

if [ -n "$S3_ACCESS_KEY" ] && [ -n "$S3_SECRET" ]; then
    KEYS_FROM="your environment"
elif [ "$VAULT_MANAGER" = true ]; then
    KEYS_FROM="the panel's s3-secrets in the cluster"
    S3_ACCESS_KEY="$(read_cluster_secret s3-secrets S3_ACCESS_KEY)"
    S3_SECRET="$(read_cluster_secret s3-secrets S3_SECRET)"
else
    KEYS_FROM="overlays/local-secrets/s3-secrets.env"
    S3_ACCESS_KEY="$(read_env S3_ACCESS_KEY "$PANEL_DIR/overlays/local-secrets/s3-secrets.env")"
    S3_SECRET="$(read_env S3_SECRET "$PANEL_DIR/overlays/local-secrets/s3-secrets.env")"
fi

HASURA_ADMIN_SECRET="$HASURA_GRAPHQL_ADMIN_SECRET"
if [ -z "$HASURA_ADMIN_SECRET" ] && [ "$VAULT_MANAGER" = true ]; then
    HASURA_ADMIN_SECRET="$(read_cluster_secret hasura-secrets HASURA_GRAPHQL_ADMIN_SECRET)"
elif [ -z "$HASURA_ADMIN_SECRET" ]; then
    HASURA_ADMIN_SECRET="$(read_env HASURA_GRAPHQL_ADMIN_SECRET "$PANEL_DIR/overlays/local-secrets/hasura-secrets.env")"
fi

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

step "Installing the worker's dependencies"
if ! npm ci --silent --no-audit --no-fund --prefix "$WORKER_DIR"; then
    die "npm ci failed. See the output above."
fi

# The worker signs every read with these keys and checks upload tokens against
# S3_SECRET, which the api signs them with, so they have to be the api's keys.
step "Checking the bucket keys with Backblaze"
if [ -z "$S3_ACCESS_KEY" ] || [ -z "$S3_SECRET" ]; then
    warn "Could not read S3_ACCESS_KEY and S3_SECRET from $KEYS_FROM."
    S3_ACCESS_KEY=""
    S3_SECRET=""
fi
while true; do
    if [ -n "$S3_ACCESS_KEY" ] && [ -n "$S3_SECRET" ]; then
        KEY_CHECK="$(bucket_key_check)"
        case "$KEY_CHECK" in
            unreachable*)
                die "Could not reach https://$S3_BUCKET.$S3_ENDPOINT: ${KEY_CHECK#unreachable }"
                ;;
            InvalidAccessKeyId|SignatureDoesNotMatch|InvalidSecurity|InvalidToken|InvalidArgument)
                err "Backblaze rejected the keys from $KEYS_FROM ($KEY_CHECK)."
                ;;
            *)
                ok "Backblaze accepted the keys from $KEYS_FROM"
                break
                ;;
        esac
    fi
    warn "Enter the application key the panel's API uses for $S3_BUCKET. It is stored in"
    warn "Cloudflare as worker secrets and nowhere else."
    S3_ACCESS_KEY=""
    S3_SECRET=""
    while [ -z "$S3_ACCESS_KEY" ]; do
        read -r -p "    S3 access key ID: " S3_ACCESS_KEY || die "Stopped."
    done
    while [ -z "$S3_SECRET" ]; do
        read_masked "    S3 secret key: " S3_SECRET
    done
    KEYS_FROM="what you entered"
done

step "Hostname"
echo "    The worker gets a hostname of its own, on a domain you have on Cloudflare."
DEFAULT_HOST="$CLOUDFLARE_WORKER_DOMAIN"
if [ -z "$DEFAULT_HOST" ] && [ -n "$WEB_DOMAIN" ]; then
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
# A read of a file that does not exist goes all the way to the bucket and back
# through the worker, so it fails on a broken deploy where a preflight would not.
PROBE_URL="https://$WORKER_HOST/maps/.5stack-check-$RANDOM$RANDOM"
ANSWERING=false
for _ in $(seq 1 24); do
    PROBE="$(cf_curl "$WORKER_HOST" -sS -o /dev/null -D - -w 'status=%{http_code}' --max-time 20 \
        -H "Origin: https://${WEB_DOMAIN:-example.com}" "$PROBE_URL" 2>/dev/null)"
    PROBE_STATUS="${PROBE##*status=}"
    if echo "$PROBE" | grep -qi '^access-control-allow-methods: GET, HEAD, PUT, OPTIONS' \
        && [ "${PROBE_STATUS:-500}" -lt 500 ]; then
        ANSWERING=true
        break
    fi
    sleep 5
done
if [ "$ANSWERING" != true ]; then
    err "https://$WORKER_HOST is not serving files through the worker (last answer: HTTP ${PROBE_STATUS:-none})."
    err "Watch its errors with the command below while you open a file on it, or check the"
    err "routes in $CF_ZONE_NAME's Workers Routes."
    err "  npx wrangler tail $WORKER_NAME"
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

step "Pointing the panel at it"
WORKER_URL="https://$WORKER_HOST"
LIVE_URL=""
if [ -n "$API_DOMAIN" ] && [ -n "$HASURA_ADMIN_SECRET" ]; then
    LIVE_URL="$(panel_graphql 'query { settings_by_pk(name: "cloudflare_worker_url") { value } }' '{}' \
        | cf_json 'j.data ? (j.data.settings_by_pk?.value ?? "") : undefined')"
fi

CURRENT_URL="$LIVE_URL"
if [ -n "$CLOUDFLARE_WORKER_DOMAIN" ]; then
    CURRENT_URL="https://$CLOUDFLARE_WORKER_DOMAIN"
fi
SWITCH=y
if [ -n "$CURRENT_URL" ] && [ "$CURRENT_URL" != "$WORKER_URL" ]; then
    ok "The panel serves files through $CURRENT_URL now."
    read -r -p "    Switch it to $WORKER_URL? [Y/n] " SWITCH
    SWITCH="${SWITCH:-y}"
fi

if [[ ! "$SWITCH" =~ ^[Yy] ]]; then
    warn "Left it on $CURRENT_URL. Run this again to switch later."
else
    if [ "$CLOUDFLARE_WORKER_DOMAIN" != "$WORKER_HOST" ]; then
        update_env_var "$PANEL_DIR/overlays/config/api-config.env" CLOUDFLARE_WORKER_DOMAIN "$WORKER_HOST"
    fi
    ok "CLOUDFLARE_WORKER_DOMAIN=$WORKER_HOST is in overlays/config/api-config.env"

    if [ "$LIVE_URL" = "$WORKER_URL" ]; then
        ok "The panel already serves files through $WORKER_URL"
    elif [ -n "$API_DOMAIN" ] && [ -n "$HASURA_ADMIN_SECRET" ] && set_live_worker_url "$WORKER_URL"; then
        ok "The panel now serves demos, clips and media through $WORKER_URL"
    else
        offer_update
    fi
fi

cf_offer_tiered_cache
