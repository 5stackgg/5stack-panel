#!/bin/bash

# coturn on its pinned image, started by the Deployment's own script with the
# panel's turnserver.conf, on a Docker network standing in for the internet. A
# TURN client with credentials signed by the shared secret asks it to relay to
# peers. Test names on the command line run just those.

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_ROOT="${TEST_ROOT:-$(cd "$HERE/../.." && pwd)}"
PREFIX=coturn-relay-test
DEPLOYMENT="$TEST_ROOT/overlays/coturn/deployment.yaml"
COTURN_IMAGE="$(sed -n 's/^ *image: *\(coturn\/coturn:.*\)$/\1/p' "$DEPLOYMENT" | head -n 1)"
SUBNET=198.51.100.0/24
NODE=198.51.100.10
PEER=198.51.100.20
CLIENT=198.51.100.30
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/coturn-test.XXXXXX")"
TESTS_PASSED=0
TESTS_FAILED=0

cleanup() {
    docker rm -f -v "$PREFIX-node-peer" "$PREFIX-node" "$PREFIX-peer" >/dev/null 2>&1
    docker network rm "$PREFIX-net" >/dev/null 2>&1
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT

fail() {
    echo "      $*"
    exit 1
}

run_test() {
    if ("$1"); then
        TESTS_PASSED=$((TESTS_PASSED + 1))
        echo "ok   $1"
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        echo "FAIL $1"
    fi
}

# The command block of the Deployment's container, as the pod runs it.
start_script() {
    python3 -I - "$DEPLOYMENT" <<'PY'
import sys
lines = open(sys.argv[1]).read().split("\n")
start = lines.index("            - |") + 1
body = []
for line in lines[start:]:
    if line.strip() and not line.startswith(" " * 14):
        break
    body.append(line[14:])
print("\n".join(body).rstrip())
PY
}

start() {
    cleanup
    mkdir -p "$WORK_DIR"
    start_script >"$WORK_DIR/start.sh" || return 1
    grep -q '^exec turnserver ' "$WORK_DIR/start.sh" || fail "no start script in $DEPLOYMENT"
    docker network create --subnet "$SUBNET" "$PREFIX-net" >/dev/null || return 1
    docker run -d --name "$PREFIX-node" --network "$PREFIX-net" --ip "$NODE" \
        -e TURN_DOMAIN=turn.test -e TURN_SECRET=test-secret -e HOST_IP="$NODE" -e TURN_PUBLIC_IP="$NODE" \
        -v "$WORK_DIR/start.sh:/start.sh:ro" \
        -v "$TEST_ROOT/overlays/coturn/turnserver.conf:/etc/coturn/turnserver.conf:ro" \
        --entrypoint sh "$COTURN_IMAGE" /start.sh >/dev/null || return 1
    docker run -d --name "$PREFIX-peer" --network "$PREFIX-net" --ip "$PEER" \
        --entrypoint turnutils_peer "$COTURN_IMAGE" -L "$PEER" >/dev/null || return 1
    docker run -d --name "$PREFIX-node-peer" --network "container:$PREFIX-node" \
        --entrypoint turnutils_peer "$COTURN_IMAGE" -L "$NODE" >/dev/null || return 1
    for _ in $(seq 1 30); do
        docker logs "$PREFIX-node" 2>&1 | grep -q 'Total auth threads' && return 0
        sleep 1
    done
    docker logs "$PREFIX-node" 2>&1 | tail -n 20
    return 1
}

# relay USER PEER [FLAGS...]: what the TURN client says after asking the relay
# to send three messages to PEER. A user per call keeps clear of user-quota.
relay() {
    local user="$1" peer="$2"
    shift 2
    docker run --rm --network "$PREFIX-net" --ip "$CLIENT" --entrypoint timeout "$COTURN_IMAGE" 10 \
        turnutils_uclient -W test-secret -u "$user" -n 3 -e "$peer" "$@" "$NODE" 2>&1
}

test_a_public_peer_is_relayed() {
    local out
    out="$(relay public "$PEER" -c)"
    grep -q 'tot_recv_msgs=3' <<<"$out" || fail "nothing came back from $PEER: $(tail -n 3 <<<"$out")"
}

# MediaMTX shares the node with coturn, and calls relay to it there.
test_the_node_itself_is_relayed_over_udp() {
    local out
    out="$(relay node "$NODE" -c)"
    grep -q 'tot_recv_msgs=3' <<<"$out" || fail "nothing came back from $NODE: $(tail -n 3 <<<"$out")"
}

test_special_purpose_ranges_are_not_relayed() {
    local peer flags out n=0
    for peer in 192.0.0.8 198.18.0.5 198.19.255.1 240.0.0.1 64:ff9b::c633:6414 ::ffff:c633:6414; do
        n=$((n + 1))
        flags=-c
        case "$peer" in
            *:*) flags="-c -x" ;;
        esac
        # shellcheck disable=SC2086
        out="$(relay "special$n" "$peer" $flags)"
        grep -q 'error 403' <<<"$out" || fail "$peer was not refused: $(tail -n 3 <<<"$out")"
    done
}

test_private_ranges_are_not_relayed() {
    local peer out n=0
    for peer in 10.1.2.3 172.16.0.1 192.168.1.1 100.64.0.1 169.254.169.254; do
        n=$((n + 1))
        out="$(relay "private$n" "$peer" -c)"
        grep -q 'error 403' <<<"$out" || fail "$peer was not refused: $(tail -n 3 <<<"$out")"
    done
}

test_tcp_relays_are_refused() {
    local peer out
    for peer in "$PEER" "$NODE"; do
        out="$(relay "tcp-$peer" "$peer" -T)"
        grep -q 'error 442' <<<"$out" || fail "a TCP relay to $peer was not refused: $(tail -n 3 <<<"$out")"
    done
}

docker pull -q "$COTURN_IMAGE" >/dev/null || exit 1
start || exit 1
if [ "$#" -eq 0 ]; then
    while IFS= read -r name; do
        set -- "$@" "$name"
    done < <(declare -F | awk '{ print $3 }' | grep '^test_')
fi
for name in "$@"; do
    run_test "$name"
done
echo
echo "$TESTS_PASSED passed, $TESTS_FAILED failed"
[ "$TESTS_FAILED" -eq 0 ]
