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

# require_signed_clip_links STATE -- says what STATE means for the worker, and
# succeeds only when it may refuse unsigned clip links.
require_signed_clip_links() {
    case "$1" in
        signing)
            ok "The panel's API signs clip links with these keys, so the worker will refuse"
            ok "a clip or lineup file without one. Every panel this worker serves has to"
            ok "sign them too, or its clips stop loading."
            return 0
            ;;
        mismatch)
            warn "The panel's API signs clip links with a different S3_SECRET than the one"
            warn "going to the worker, so the worker will not require them. Give the worker"
            warn "the keys the API runs with (after changing them, ./update.sh restarts the"
            warn "API), then run this again."
            ;;
        unsigned)
            warn "The panel's API does not sign clip links yet, so the worker will not"
            warn "require them. Update the panel (./update.sh), then run this again."
            ;;
        *)
            warn "Could not ask the panel's database (kubeconfig $PANEL_KUBECONFIG) whether"
            warn "its API signs clip links, so the worker will not require them. Run this"
            warn "again where kubectl reaches the panel."
            ;;
    esac
    warn "Until then a private clip can be downloaded by anyone who has its link."
    return 1
}

signed_clip_links_psql() {
    kubectl --kubeconfig="$PANEL_KUBECONFIG" -n 5stack exec timescaledb-0 -c timescaledb -- \
        sh -c 'psql -X -v ON_ERROR_STOP=1 -At -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "$1"' sh "$1" 2>/dev/null
}
