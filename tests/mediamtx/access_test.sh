#!/bin/bash
# The ways in (hls, whep, whip), the Deployment's env and its command and args
# are split into words on purpose.
# shellcheck disable=SC2046,SC2086

# MediaMTX started as its Deployment starts it, on the pinned images with the
# panel's config and the Deployment's password env, in a "node" container
# standing in for the hostNetwork host. A client on several Docker networks
# reaches it from private ranges a cluster's pods and nodes use, and from
# public ones standing in for the internet, as each of MediaMTX's users or as
# nobody. Test names on the command line run just those.

# shellcheck source=tests/mediamtx/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PREFIX=mediamtx-access-test
DEPLOYMENT="$TEST_ROOT/overlays/mediamtx/deployment.yaml"
PYTHON_IMAGE=python:3.13.18-alpine3.24@sha256:bbc0290146ebe0a8b9a8ed07d3f2c7bdeb4d917fc93300a4e47490c8b5a11b48
MATCH=0a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d
VOICE="voice-$MATCH-76561198000000001"
CAMERA="camera-$MATCH-76561198000000001"
PRIVATE_NETWORKS="10.253.47.0/24 172.31.247.0/24 192.168.247.0/24 100.87.247.0/24"
PUBLIC_NETWORKS="198.51.100.0/24 172.32.247.0/24 100.128.247.0/24"
PRIVATE=10.253.47.0/24
PUBLIC=198.51.100.0/24
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/mediamtx-test.XXXXXX")"

# The password a test install has under each mediamtx-secrets key.
password() {
    printf '%s' "$1" | shasum -a 256 | cut -c 1-32
}

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
trap 'cleanup; rm -rf "$WORK_DIR"' EXIT

# The Deployment's init and MediaMTX containers, as shell assignments: their
# images, command or args, and which mediamtx-secrets key each MTX_ env takes.
# A Deployment without the init container mounts mediamtx.yml as it is.
read_deployment() {
    KUBECONFIG=/dev/null kubectl patch --local -o json --type merge -p '{}' -f "$DEPLOYMENT" >"$WORK_DIR/deployment.json" ||
        return 1
    python3 -I - "$WORK_DIR/deployment.json" >"$WORK_DIR/deployment.env" <<'PY' || return 1
import json, shlex, sys
spec = json.load(open(sys.argv[1]))["spec"]["template"]["spec"]
init = next((c for c in spec.get("initContainers", []) if c["name"] == "node-addresses"), {"image": "", "command": []})
mediamtx = next(c for c in spec["containers"] if c["name"] == "mediamtx")
passwords = [f"{e['name']}={e['valueFrom']['secretKeyRef']['key']}" for e in mediamtx.get("env", [])
             if e["name"].startswith("MTX_") and "secretKeyRef" in e.get("valueFrom", {})]
for name, value in [("INIT_IMAGE", init["image"]), ("INIT_COMMAND", " ".join(init["command"])),
                    ("MEDIAMTX_IMAGE", mediamtx["image"]),
                    ("MEDIAMTX_ARGS", " ".join(mediamtx.get("args", []))), ("MEDIAMTX_PASSWORDS", " ".join(passwords))]:
    print(f"{name}={shlex.quote(value)}")
PY
    # shellcheck source=/dev/null
    source "$WORK_DIR/deployment.env"
}

# The -e flags that give a container mediamtx-secrets the way the Deployment does.
secret_env() {
    local key
    for key in MEDIAMTX_API_PASSWORD MEDIAMTX_STREAMER_PASSWORD MEDIAMTX_RELAY_PASSWORD MEDIAMTX_VIEWER_PASSWORD; do
        printf -- '-e\n%s=%s\n' "$key" "$(password "$key")"
    done
}

mediamtx_env() {
    local entry
    for entry in $MEDIAMTX_PASSWORDS; do
        printf -- '-e\n%s=%s\n' "${entry%%=*}" "$(password "${entry#*=}")"
    done
}

# The node's address on the network of $1.
node_on() {
    docker inspect -f "{{(index .NetworkSettings.Networks \"$(network_name "$1")\").IPAddress}}" "$PREFIX-node"
}

# request FROM SUBNET USER METHOD PORT PATH [BODY [HEADER...]]: the status
# MediaMTX answers container FROM on its address on SUBNET's network, signed
# in as USER (api, streamer, relay or viewer) or as nobody (-).
request() {
    local from="$1" subnet="$2" user="$3" method="$4" port="$5" path="$6" body="${7:-}" key=""
    shift 6
    [ "$#" -gt 0 ] && shift
    case "$user" in
        api) key=MEDIAMTX_API_PASSWORD ;;
        streamer) key=MEDIAMTX_STREAMER_PASSWORD ;;
        relay) key=MEDIAMTX_RELAY_PASSWORD ;;
        viewer) key=MEDIAMTX_VIEWER_PASSWORD ;;
    esac
    docker exec "$PREFIX-$from" python3 -I -c '
import base64, sys, urllib.error, urllib.request
method, url, body, user, password, *headers = sys.argv[1:]
request = urllib.request.Request(url, method=method, data=body.encode() if body else None)
if user != "-":
    request.add_header("Authorization", "Basic " + base64.b64encode(f"{user}:{password}".encode()).decode())
for header in headers:
    name, value = header.split(": ", 1)
    request.add_header(name, value)
try:
    print(urllib.request.urlopen(request, timeout=10).status)
except urllib.error.HTTPError as error:
    print(error.code)
' "$method" "http://$(node_on "$subnet"):$port$path" "$body" "$user" "${key:+$(password "$key")}" "$@"
}

# expect FROM WANT SUBNET USER METHOD PORT PATH [BODY [HEADER...]]
expect() {
    local from="$1" want="$2" got
    shift 2
    got="$(request "$from" "$@")"
    [ "$got" = "$want" ] || fail "$3 :$4$5 from $from on $1 as $2: expected $want, got $got"
}

# The ways in, as METHOD PORT PATH [BODY HEADER] for request: read over HLS
# and WHEP, publish over WHIP, and the API.
hls() { printf 'GET 8888 /%s/index.m3u8' "$1"; }
whep() { printf 'POST 8889 /%s/whep' "$1"; }
whip() { printf 'POST 8889 /%s/whip' "$1"; }
SDP=(v=0 "Content-Type: application/sdp")

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
    local config="$TEST_ROOT/overlays/mediamtx/mediamtx.yml:/mediamtx.yml:ro"
    if [ -n "$INIT_IMAGE" ]; then
        run_init "$PREFIX-config" $(secret_env) || return 1
        config="$PREFIX-config:/config:ro"
    fi
    docker run -d --name "$PREFIX-mediamtx" --network "container:$PREFIX-node" -v "$config" \
        $(mediamtx_env) "$MEDIAMTX_IMAGE" $MEDIAMTX_ARGS >/dev/null || return 1
    for _ in $(seq 1 30); do
        [ "$(request client "$first" api GET 9997 /v3/paths/list)" = 200 ] && return 0
        sleep 1
    done
    docker logs "$PREFIX-mediamtx" 2>&1 | tail -n 20
    return 1
}

# run_init VOLUME [DOCKER FLAGS...]: the Deployment's init container, writing
# the config into VOLUME.
run_init() {
    local volume="$1"
    shift
    docker run --rm --network "container:$PREFIX-node" -v "$volume:/config" "$@" \
        -v "$TEST_ROOT/overlays/mediamtx/mediamtx.yml:/etc/mediamtx/mediamtx.yml:ro" \
        -v "$TEST_ROOT/overlays/mediamtx/node-addresses.sh:/etc/mediamtx/node-addresses.sh:ro" \
        "$INIT_IMAGE" $INIT_COMMAND
}

test_without_credentials_nobody_gets_in_from_anywhere() {
    local subnet way
    for subnet in $PRIVATE_NETWORKS $PUBLIC_NETWORKS; do
        expect client 401 "$subnet" - GET 9997 /v3/paths/list
        expect client 401 "$subnet" - GET 9998 /metrics
        for way in "$(hls "$MATCH")" "$(hls "$VOICE")"; do
            expect client 401 "$subnet" - $way
        done
        for way in "$(whep "$MATCH")" "$(whep "$CAMERA")" "$(whip "$MATCH")" "$(whip "$CAMERA")"; do
            expect client 401 "$subnet" - $way "${SDP[@]}"
        done
    done
}

test_a_turn_relayed_source_on_the_node_needs_credentials_too() {
    local subnet way
    for subnet in $PUBLIC_NETWORKS $PRIVATE; do
        expect node 401 "$subnet" - GET 9997 /v3/paths/list
        expect node 401 "$subnet" - $(hls "$MATCH")
        for way in "$(whip "$MATCH")" "$(whip "$VOICE")" "$(whep "$CAMERA")"; do
            expect node 401 "$subnet" - $way "${SDP[@]}"
        done
    done
}

test_the_api_user_reaches_the_api_from_private_and_node_addresses_only() {
    local subnet
    for subnet in $PRIVATE_NETWORKS; do
        expect client 200 "$subnet" api GET 9997 /v3/paths/list
        expect client 200 "$subnet" api GET 9998 /metrics
    done
    for subnet in $PUBLIC_NETWORKS; do
        expect client 401 "$subnet" api GET 9997 /v3/paths/list
        expect client 401 "$subnet" api GET 9997 /v3/paths/list "" "X-Forwarded-For: 10.0.0.1" "X-Real-IP: 10.0.0.1"
        expect node 200 "$subnet" api GET 9997 /v3/paths/list
    done
}

test_no_credential_but_the_api_users_reaches_the_api() {
    local user
    for user in streamer relay viewer; do
        expect client 401 "$PRIVATE" "$user" GET 9997 /v3/paths/list
        expect client 401 "$PRIVATE" "$user" GET 9998 /metrics
        expect client 401 "$PRIVATE" "$user" POST 9997 /v3/config/paths/add/probe '{}' "Content-Type: application/json"
    done
    expect client 404 "$PRIVATE" api GET 9997 /v3/config/paths/get/probe
}

# Past authentication MediaMTX answers 404 to a read, since nothing publishes,
# and 400 to a publish, since "v=0" is no offer.
test_the_viewer_reads_match_streams_and_nothing_else() {
    local path
    expect client 404 "$PRIVATE" viewer $(hls "$MATCH")
    expect client 404 "$PUBLIC" viewer $(hls "$MATCH")
    expect client 404 "$PRIVATE" viewer $(whep "$MATCH") "${SDP[@]}"
    for path in "$VOICE" "$CAMERA" "voicecam-$MATCH-76561198000000001" "camera-talk-$MATCH"; do
        expect client 401 "$PRIVATE" viewer $(hls "$path")
        expect client 401 "$PRIVATE" viewer $(whep "$path") "${SDP[@]}"
    done
    expect client 401 "$PRIVATE" viewer $(whip "$MATCH") "${SDP[@]}"
}

test_the_streamer_publishes_match_streams_and_nothing_else() {
    local path
    expect client 400 "$PRIVATE" streamer $(whip "$MATCH") "${SDP[@]}"
    expect client 400 "$PUBLIC" streamer $(whip "$MATCH") "${SDP[@]}"
    for path in "$VOICE" "$CAMERA" "voicecam-$MATCH-76561198000000001" "x$MATCH"; do
        expect client 401 "$PRIVATE" streamer $(whip "$path") "${SDP[@]}"
    done
    expect client 401 "$PRIVATE" streamer $(hls "$MATCH")
    expect client 401 "$PRIVATE" streamer $(whep "$MATCH") "${SDP[@]}"
}

test_the_relay_has_voice_and_cameras_and_no_match_stream() {
    local path
    for path in "$VOICE" "$CAMERA" "voicecam-$MATCH-76561198000000001" "camera-talk-$MATCH"; do
        expect client 400 "$PRIVATE" relay $(whip "$path") "${SDP[@]}"
        expect client 404 "$PRIVATE" relay $(whep "$path") "${SDP[@]}"
    done
    expect client 401 "$PRIVATE" relay $(whip "$MATCH") "${SDP[@]}"
    expect client 401 "$PRIVATE" relay $(whep "$MATCH") "${SDP[@]}"
    expect client 401 "$PRIVATE" relay $(hls "$MATCH")
}

# srt FROM SUBNET STREAMID SECONDS: publishes a test picture over SRT, as a
# game streamer's srtsink does, for SECONDS; the status is ffmpeg's.
srt() {
    docker exec "$PREFIX-$1" sh -c 'command -v ffmpeg >/dev/null || apk add -q --no-cache ffmpeg >/dev/null' || return 1
    docker exec "$PREFIX-$1" timeout 20 ffmpeg -hide_banner -loglevel error -re -f lavfi \
        -i testsrc=size=160x120:rate=10 -t "$4" -c:v libx264 -preset ultrafast -tune zerolatency -g 10 -f mpegts \
        "srt://$(node_on "$2"):8890?streamid=$3&pkt_size=1316" >"$WORK_DIR/srt.log" 2>&1
}

# ready PATH: whether MediaMTX's API says something publishes PATH.
ready() {
    docker exec "$PREFIX-client" python3 -I -c '
import base64, json, sys, urllib.error, urllib.request
request = urllib.request.Request(sys.argv[1])
request.add_header("Authorization", "Basic " + base64.b64encode(f"api:{sys.argv[2]}".encode()).decode())
try:
    print(str(json.load(urllib.request.urlopen(request, timeout=10)).get("ready")).lower())
except urllib.error.HTTPError as error:
    print(error.code)
' "http://$(node_on "$PRIVATE"):9997/v3/paths/get/$1" "$(password MEDIAMTX_API_PASSWORD)"
}

test_the_streamer_publishes_a_match_over_srt_with_its_password() {
    local path=1f2e3d4c-5b6a-4978-8a9b-0c1d2e3f4a5b seen=""
    srt client "$PRIVATE" "publish:$path:streamer:$(password MEDIAMTX_STREAMER_PASSWORD)" 8 &
    for _ in $(seq 1 15); do
        seen="$(ready "$path")"
        [ "$seen" = true ] && break
        sleep 1
    done
    wait
    [ "$seen" = true ] || fail "$path never went live over SRT: $seen $(cat "$WORK_DIR/srt.log")"
}

test_srt_without_the_right_credentials_is_refused() {
    local entry from subnet streamid path refusals
    for entry in "client $PRIVATE publish:2a3b4c5d-6e7f-4a8b-9c0d-1e2f3a4b5c6d" \
        "client $PRIVATE publish:3b4c5d6e-7f8a-4b9c-8d0e-1f2a3b4c5d6e:streamer:0123456789abcdef0123456789abcdef" \
        "client $PRIVATE publish:4c5d6e7f-8a9b-4c0d-9e1f-2a3b4c5d6e7f:relay:$(password MEDIAMTX_RELAY_PASSWORD)" \
        "client $PRIVATE publish:$VOICE:streamer:$(password MEDIAMTX_STREAMER_PASSWORD)" \
        "client $PUBLIC publish:5d6e7f8a-9b0c-4d1e-8f2a-3b4c5d6e7f8a" \
        "node $PUBLIC publish:6e7f8a9b-0c1d-4e2f-9a3b-4c5d6e7f8a9b"; do
        read -r from subnet streamid <<<"$entry"
        refusals="$(docker logs "$PREFIX-mediamtx" 2>&1 | grep -c '\[SRT\].*authentication failed')"
        if srt "$from" "$subnet" "$streamid" 3; then
            fail "SRT from $from on $subnet with ${streamid%:*:*}:… was let in"
        fi
        [ "$(docker logs "$PREFIX-mediamtx" 2>&1 | grep -c '\[SRT\].*authentication failed')" -gt "$refusals" ] ||
            fail "MediaMTX did not refuse SRT from $from: $(docker logs "$PREFIX-mediamtx" 2>&1 | grep '\[SRT\]' | tail -n 2)"
        path="${streamid#publish:}"
        path="${path%%:*}"
        [ "$(ready "$path")" != true ] || fail "$path went live"
    done
}

test_nobody_is_granted_pprof() {
    local actions
    actions="$(docker exec "$PREFIX-client" python3 -I -c '
import base64, json, sys, urllib.request
request = urllib.request.Request(sys.argv[1])
request.add_header("Authorization", "Basic " + base64.b64encode(f"api:{sys.argv[2]}".encode()).decode())
config = json.load(urllib.request.urlopen(request, timeout=10))
print(" ".join(sorted({p["action"] for u in config["authInternalUsers"] for p in u["permissions"]})))
' "http://$(node_on "$PRIVATE"):9997/v3/config/global/get" "$(password MEDIAMTX_API_PASSWORD)")"
    assert_eq "$actions" "api metrics playback publish read"
}

test_an_empty_password_keeps_mediamtx_from_starting() {
    local key
    [ -n "$INIT_IMAGE" ] || fail "the Deployment has no init container to refuse an empty password"
    for key in MEDIAMTX_API_PASSWORD MEDIAMTX_STREAMER_PASSWORD MEDIAMTX_RELAY_PASSWORD MEDIAMTX_VIEWER_PASSWORD; do
        docker volume create "$PREFIX-empty" >/dev/null || return 1
        if run_init "$PREFIX-empty" $(secret_env) -e "$key=" >"$WORK_DIR/init.log" 2>&1; then
            docker volume rm "$PREFIX-empty" >/dev/null
            fail "the init container wrote a config with $key empty"
        fi
        assert_eq "$(docker run --rm -v "$PREFIX-empty:/config" "$INIT_IMAGE" ls /config)" ""
        docker volume rm "$PREFIX-empty" >/dev/null
    done
}

read_deployment || fail "could not read $DEPLOYMENT"
for image in "$MEDIAMTX_IMAGE" ${INIT_IMAGE:+"$INIT_IMAGE"} "$PYTHON_IMAGE"; do
    docker pull -q "$image" >/dev/null || exit 1
done
start || exit 1
run_tests "$@"
