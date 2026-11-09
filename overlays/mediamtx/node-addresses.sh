#!/bin/sh
# node-addresses.sh CONFIG OUT: CONFIG with this node's own addresses added to
# the first user's ips. A hostNetwork pod on the node, as a game streamer is,
# reaches MediaMTX's Service from the address the node routes by, which can be
# a public one. Writes nothing while a password is empty: MediaMTX would take
# it as any password.
set -eu
for key in MEDIAMTX_API_PASSWORD MEDIAMTX_STREAMER_PASSWORD MEDIAMTX_RELAY_PASSWORD MEDIAMTX_VIEWER_PASSWORD; do
    if [ -z "$(printenv "$key" || true)" ]; then
        echo "node-addresses.sh: $key is empty in mediamtx-secrets" >&2
        exit 1
    fi
done
ip -o addr show | awk '/ scope global / { sub("/.*", "", $4); print $4 }' | awk '
    NR == FNR { addresses[++n] = $0; next }
    { print }
    /^    ips:$/ && !done { for (i = 1; i <= n; i++) printf "      - \"%s\"\n", addresses[i]; done = 1 }
' - "$1" >"$2"
