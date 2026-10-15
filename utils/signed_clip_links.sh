#!/bin/bash

# Whether the panel's API signs clip and lineup file links with the key a
# backblaze-proxy worker holding S3_SECRET checks them with. The worker refuses
# unsigned clip links only when deployed with REQUIRE_SIGNED_CLIPS=1, and only
# "signing" here may turn that on: in front of an API that does not sign, or
# signs with another S3_SECRET, the worker would refuse every clip.
#
# Asks the database rather than the API's version: it is the database's link
# functions that sign, and they are what a rollback or a stalled update leaves
# behind. Compares a hash of the stored key, so the key itself never leaves the
# cluster.
#
#   signed_clip_links_state S3_SECRET
#
# Prints one of:
#   signing      the clip link function signs, with the key S3_SECRET derives
#   mismatch     it signs, with a key from a different S3_SECRET
#   unsigned     an API from before signed links, or one that has not stored
#                its key yet
#   unreachable  the panel's database could not be asked
signed_clip_links_state() {
    local secret="$1" signs stored expected

    if ! signs="$(signed_clip_links_psql "SELECT to_regclass('private.file_url_signing_key') IS NOT NULL AND position('file_url_signature' IN pg_get_functiondef(to_regprocedure('public.clip_download_url(public.match_clips)'))) > 0")"; then
        echo unreachable
        return
    fi
    if [ "$signs" != "t" ]; then
        echo unsigned
        return
    fi

    if ! stored="$(signed_clip_links_psql "SELECT encode(sha256(key), 'hex') FROM private.file_url_signing_key")"; then
        echo unreachable
        return
    fi
    if [ -z "$stored" ]; then
        echo unsigned
        return
    fi

    expected="$(S3_SECRET="$secret" node -e '
        const crypto = require("crypto");
        const key = crypto.createHmac("sha256", process.env.S3_SECRET).update("5stack-file-url-v1").digest();
        process.stdout.write(crypto.createHash("sha256").update(key).digest("hex"));
    ')"
    if [ "$stored" = "$expected" ]; then
        echo signing
    else
        echo mismatch
    fi
}

# worker_signed_clip_links WORKER -- whether the deployed worker refuses
# unsigned clip links now: on, off (also when it was never deployed) or
# unknown. Asked of Cloudflare because a deploy replaces every var the worker
# has, so leaving REQUIRE_SIGNED_CLIPS out of one turns it off.
worker_signed_clip_links() {
    local response

    response="$(cf_api GET "/accounts/$CLOUDFLARE_ACCOUNT_ID/workers/scripts/$1/settings")"
    if [ "$(echo "$response" | cf_json 'j.success')" = "true" ]; then
        if [ "$(echo "$response" | cf_json '(j.result?.bindings || []).some((b) => b.type === "plain_text" && b.name === "REQUIRE_SIGNED_CLIPS" && b.text === "1")')" = "true" ]; then
            echo on
        else
            echo off
        fi
    elif [ "$(echo "$response" | cf_json '(j.errors || []).some((e) => e.code === 10007)')" = "true" ]; then
        echo off
    else
        echo unknown
    fi
}

# require_signed_clip_links WORKER STATE -- decides REQUIRE_SIGNED_CLIPS for
# this deploy from whether the worker requires signed links now (WORKER, from
# worker_signed_clip_links) and what signed_clip_links_state found (STATE), and
# says why. One worker can serve several panels, so this only ever turns it
# off on an explicit yes.
#
# Returns 0 to require them, 1 to deploy without, 2 to deploy nothing.
require_signed_clip_links() {
    local worker="$1" state="$2" answer

    if [ "$state" = signing ]; then
        if [ "$worker" = on ]; then
            ok "The panel's API signs clip links with these keys, and the worker keeps"
            ok "refusing a clip or lineup file without one."
        else
            ok "The panel's API signs clip links with these keys, so the worker will refuse"
            ok "a clip or lineup file without one. Every panel using this worker must"
            ok "already sign them, or its clips stop loading."
        fi
        return 0
    fi

    if [ "$worker" = on ] && [ "$state" = unreachable ]; then
        warn "Could not ask the panel's database (kubeconfig $PANEL_KUBECONFIG) whether"
        warn "its API signs clip links. The worker requires them now, so it keeps"
        warn "requiring them; a panel's clips only stop being checked on a run that can"
        warn "see it does not sign them."
        return 0
    fi

    case "$state" in
        mismatch)
            warn "The panel's API signs clip links with a different S3_SECRET than the one"
            warn "going to the worker. Give the worker the keys the API runs with (after"
            warn "changing them, ./update.sh restarts the API), then run this again."
            ;;
        unsigned)
            warn "The panel's API does not sign clip links yet. Update the panel"
            warn "(./update.sh), then run this again."
            ;;
        *)
            warn "Could not ask the panel's database (kubeconfig $PANEL_KUBECONFIG) whether"
            warn "its API signs clip links. Run this again where kubectl reaches the panel"
            warn "(on k3s, as root)."
            ;;
    esac

    if [ "$worker" = off ]; then
        warn "The worker does not require signed clip links, and will not until then: a"
        warn "private clip can be downloaded by anyone who has its link."
        return 1
    fi

    if [ "$worker" = on ]; then
        warn "The worker requires signed clip links now. Deploying without them turns"
        warn "that off for every panel using this worker, and their private clips can"
        warn "be downloaded by anyone who has the link."
    else
        warn "Could not read from Cloudflare whether the worker requires signed clip"
        warn "links now. If it does, deploying without them turns that off for every"
        warn "panel using this worker."
    fi
    read -r -p "    Deploy without requiring signed clip links? [y/N] " answer
    if [[ "$answer" =~ ^[Yy] ]]; then
        return 1
    fi
    return 2
}

signed_clip_links_psql() {
    kubectl --kubeconfig="$PANEL_KUBECONFIG" -n 5stack exec timescaledb-0 -c timescaledb -- \
        sh -c 'psql -X -v ON_ERROR_STOP=1 -At -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "$1"' sh "$1" 2>/dev/null
}
