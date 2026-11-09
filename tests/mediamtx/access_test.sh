#!/bin/bash

# MediaMTX started as its Deployment starts it, on the pinned images with the
# panel's config, in a "node" container standing in for the hostNetwork host.
# A client on several Docker networks reaches it from private ranges a
# cluster's pods and nodes use, and from public ones standing in for the
# internet. Test names on the command line run just those.

# shellcheck source=tests/mediamtx/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PREFIX=mediamtx-access-test
DEPLOYMENT="$TEST_ROOT/overlays/mediamtx/deployment.yaml"
MEDIAMTX_IMAGE="$(sed -n 's/^ *image: *\(ghcr.io\/5stackgg\/mediamtx:.*\)$/\1/p' "$DEPLOYMENT" | head -n 1)"
INIT_IMAGE="$(sed -n 's/^ *image: *\(busybox:.*\)$/\1/p' "$DEPLOYMENT" | head -n 1)"
INIT_COMMAND="$(sed -n 's/^ *command: \[\(sh, \/etc\/mediamtx\/.*\)\]$/\1/p' "$DEPLOYMENT" | tr -d ,)"
MEDIAMTX_ARGS="$(sed -n 's/^ *args: \[\(.*\)\]$/\1/p' "$DEPLOYMENT" | tr -d ,)"
PYTHON_IMAGE=python:3.13.18-alpine3.24@sha256:bbc0290146ebe0a8b9a8ed07d3f2c7bdeb4d917fc93300a4e47490c8b5a11b48
MATCH=0a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d
PRIVATE_NETWORKS="10.253.47.0/24 172.31.247.0/24 192.168.247.0/24 100.87.247.0/24"
PUBLIC_NETWORKS="198.51.100.0/24 172.32.247.0/24 100.128.247.0/24"

network_name() {
    printf '%s-%s' "$PREFIX" "${1//[.\/]/-}"
}

cleanup() {
    local subnet
    docker rm -f -v "$PREFIX-mediamtx" "$PREFIX-node" "$PREFIX-client" >/dev/null 2>&1
    docker volume rm "$PREFIX-config" >/dev/null 2>&1
    for subnet in $PRIVATE_NETWORKS $PUBLIC_NETWORKS; do
        docker network rm "$(network_name "$subnet")" >/dev/null 2>&1
    done
}
trap cleanup EXIT

# The node's address on the network of $1.
node_on() {
    docker inspect -f "{{(index .NetworkSettings.Networks \"$(network_name "$1")\").IPAddress}}" "$PREFIX-node"
}

# request FROM SUBNET METHOD PORT PATH [BODY [HEADER...]]: the status MediaMTX
# answers container FROM on its address on SUBNET's network.
request() {
    local from="$1" subnet="$2" method="$3" port="$4" path="$5" body="${6:-}"
    shift 5
    [ "$#" -gt 0 ] && shift
    docker exec "$PREFIX-$from" python3 -I -c '
import sys, urllib.error, urllib.request
method, url, body, *headers = sys.argv[1:]
request = urllib.request.Request(url, method=method, data=body.encode() if body else None)
for header in headers:
    name, value = header.split(": ", 1)
    request.add_header(name, value)
try:
    print(urllib.request.urlopen(request, timeout=10).status)
except urllib.error.HTTPError as error:
    print(error.code)
' "$method" "http://$(node_on "$subnet"):$port$path" "$body" "$@"
}

# expect_status WANT SUBNET METHOD PORT PATH [BODY [HEADER...]], from the client.
expect_status() {
    expect_status_from client "$@"
}

expect_status_from() {
    local from="$1" want="$2" got
    shift 2
    got="$(request "$from" "$@")"
    [ "$got" = "$want" ] || fail "$2 :$3$4 from $from on $1: expected $want, got $got"
}

start() {
    local subnet first="" container
    cleanup
    for subnet in $PRIVATE_NETWORKS $PUBLIC_NETWORKS; do
        docker network create --subnet "$subnet" "$(network_name "$subnet")" >/dev/null || return 1
        first="${first:-$subnet}"
    done
    for container in node client; do
        docker create --name "$PREFIX-$container" --network "$(network_name "$first")" \
            "$PYTHON_IMAGE" sleep infinity >/dev/null || return 1
        for subnet in $PRIVATE_NETWORKS $PUBLIC_NETWORKS; do
            [ "$subnet" = "$first" ] && continue
            docker network connect "$(network_name "$subnet")" "$PREFIX-$container" || return 1
        done
    done
    docker start "$PREFIX-node" "$PREFIX-client" >/dev/null || return 1
    docker volume create "$PREFIX-config" >/dev/null || return 1
    # shellcheck disable=SC2086 # the Deployment's command and args, word by word
    docker run --rm --network "container:$PREFIX-node" -v "$PREFIX-config:/config" \
        -v "$TEST_ROOT/overlays/mediamtx/mediamtx.yml:/etc/mediamtx/mediamtx.yml:ro" \
        -v "$TEST_ROOT/overlays/mediamtx/node-addresses.sh:/etc/mediamtx/node-addresses.sh:ro" \
        "$INIT_IMAGE" $INIT_COMMAND || return 1
    # shellcheck disable=SC2086
    docker run -d --name "$PREFIX-mediamtx" --network "container:$PREFIX-node" -v "$PREFIX-config:/config:ro" \
        "$MEDIAMTX_IMAGE" $MEDIAMTX_ARGS >/dev/null || return 1
    for _ in $(seq 1 30); do
        [ "$(request client "$first" GET 9997 /v3/paths/list)" = 200 ] && return 0
        sleep 1
    done
    docker logs "$PREFIX-mediamtx" 2>&1 | tail -n 20
    return 1
}

test_private_clients_reach_the_api_and_metrics() {
    local subnet
    for subnet in $PRIVATE_NETWORKS; do
        expect_status 200 "$subnet" GET 9997 /v3/paths/list
        expect_status 200 "$subnet" GET 9998 /metrics
    done
}

# Past authentication, MediaMTX answers 404: nothing publishes $MATCH.
test_private_clients_reach_hls_and_whep() {
    local subnet
    for subnet in $PRIVATE_NETWORKS; do
        expect_status 404 "$subnet" GET 8888 "/$MATCH/index.m3u8"
        expect_status 404 "$subnet" POST 8889 "/$MATCH/whep" "v=0" "Content-Type: application/sdp"
    done
}

test_public_clients_are_refused_everywhere() {
    local subnet
    for subnet in $PUBLIC_NETWORKS; do
        expect_status 401 "$subnet" GET 9997 /v3/paths/list
        expect_status 401 "$subnet" GET 9997 /v3/config/global/get
        expect_status 401 "$subnet" GET 9998 /metrics
        expect_status 401 "$subnet" GET 8888 "/$MATCH/index.m3u8"
        expect_status 401 "$subnet" POST 8889 "/$MATCH/whep" "v=0" "Content-Type: application/sdp"
    done
}

test_a_public_client_cannot_change_the_config() {
    expect_status 401 198.51.100.0/24 POST 9997 /v3/config/paths/add/probe '{}' "Content-Type: application/json"
    expect_status 404 10.253.47.0/24 GET 9997 /v3/config/paths/get/probe
}

test_forwarded_headers_do_not_make_a_public_client_private() {
    local entry port path
    for entry in "9997 /v3/paths/list" "8888 /$MATCH/index.m3u8"; do
        read -r port path <<<"$entry"
        expect_status 401 198.51.100.0/24 GET "$port" "$path" "" \
            "X-Forwarded-For: 10.0.0.1" "X-Real-IP: 10.0.0.1"
    done
    expect_status 401 198.51.100.0/24 POST 8889 "/$MATCH/whep" "v=0" "Content-Type: application/sdp" \
        "X-Forwarded-For: 10.0.0.1" "X-Real-IP: 10.0.0.1"
}

# A hostNetwork game streamer on the node reaches the Service from the address
# the node routes by, a public one on a server with its own public address.
test_the_node_itself_is_let_in_on_its_public_addresses() {
    local subnet
    for subnet in $PUBLIC_NETWORKS; do
        expect_status_from node 200 "$subnet" GET 9997 /v3/paths/list
        expect_status_from node 404 "$subnet" GET 8888 "/$MATCH/index.m3u8"
    done
}

test_nobody_is_granted_pprof() {
    local users
    users="$(docker exec "$PREFIX-client" python3 -I -c '
import json, sys, urllib.request
config = json.load(urllib.request.urlopen(sys.argv[1], timeout=10))
print(" ".join(sorted({p["action"] for u in config["authInternalUsers"] for p in u["permissions"]})))
' "http://$(node_on 10.253.47.0/24):9997/v3/config/global/get")"
    assert_eq "$users" "api metrics playback publish read"
}

[ -n "$INIT_IMAGE" ] && [ -n "$INIT_COMMAND" ] || fail "the Deployment has no node-addresses init container"
for image in "$MEDIAMTX_IMAGE" "$INIT_IMAGE" "$PYTHON_IMAGE"; do
    docker pull -q "$image" >/dev/null || exit 1
done
start || exit 1
run_tests "$@"
