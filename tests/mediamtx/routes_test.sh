#!/bin/bash

# Which paths on the game stream host the mediamtx HTTPRoute sends to MediaMTX,
# matched as Traefik does: each rule's RegularExpression, unanchored.

# shellcheck source=tests/mediamtx/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

MATCH=0a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d

# The port of the first mediamtx rule that matches $1, or "none".
routed_to() {
    python3 -I - "$TEST_ROOT/overlays/mediamtx/httproute.yaml" "$1" <<'PY'
import re, sys
docs = open(sys.argv[1]).read().split("\n---\n")
route = next(d for d in docs if re.search(r"(?m)^kind: HTTPRoute$", d) and re.search(r"(?m)^  name: mediamtx$", d))
rules = re.findall(r"type: RegularExpression\n\s+value: (\S+)\n(?:.*\n)*?\s+port: (\d+)", route)
assert len(rules) == 2, rules
print(next((port for pattern, port in rules if re.search(pattern, sys.argv[2])), "none"))
PY
}

expect_routed() {
    local path
    for path in "${@:2}"; do
        assert_eq "$(routed_to "$path") for $path" "$1 for $path"
    done
}

test_match_streams_reach_whep_and_hls() {
    expect_routed 8889 "/$MATCH/whep" "/$MATCH/whep/session-1" "/${MATCH^^}/whep"
    expect_routed 8888 "/$MATCH/" "/$MATCH/index.m3u8" "/$MATCH/video1_stream.m3u8" "/$MATCH/seg7.mp4"
}

test_voice_and_camera_paths_are_not_routed() {
    local path
    for path in "voice-$MATCH" "camera-$MATCH" "voice-$MATCH-76561198000000001" "camera-$MATCH-76561198000000001"; do
        expect_routed none "/$path/whep" "/$path/whep/session-1" "/$path/" "/$path/index.m3u8"
    done
}

test_first_segments_that_are_not_a_match_id_are_not_routed() {
    expect_routed none /m1/whep /m1/index.m3u8 "/x$MATCH/whep" "/$MATCH-x/whep" "/${MATCH:1}/index.m3u8" \
        "/${MATCH//-/}/whep" "/$MATCH/a/index.m3u8" "/$MATCH/whip" "/snapshot/$MATCH" "/v3/paths/list" /metrics
}

run_tests "$@"
