#!/bin/sh
# node-addresses.sh CONFIG OUT: CONFIG with this node's own addresses added to
# the first user's ips. A hostNetwork pod on the node, as a game streamer is,
# reaches MediaMTX's Service from the address the node routes by, which can be
# a public one.
set -eu
ip -o addr show | awk '/ scope global / { sub("/.*", "", $4); print $4 }' | awk '
    NR == FNR { addresses[++n] = $0; next }
    { print }
    /^    ips:$/ && !done { for (i = 1; i <= n; i++) printf "      - \"%s\"\n", addresses[i]; done = 1 }
' - "$1" >"$2"
