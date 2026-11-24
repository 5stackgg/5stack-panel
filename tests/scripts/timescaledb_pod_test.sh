#!/bin/bash

# shellcheck source=tests/scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

OVERLAYS="vault-http vault-https local-secrets-http local-secrets-https"

# A copy of the checkout with its env files made from the examples, and every
# overlay update.sh can apply written.
make_panel() {
    PANEL="$WORK_DIR/panel"
    mkdir -p "$PANEL"
    cp -R "$TEST_ROOT/base" "$TEST_ROOT/overlays" "$TEST_ROOT/utils" "$PANEL/"
    find "$PANEL/overlays" -name '*.env.example' | while read -r example; do
        cp "$example" "${example%.example}"
    done
    (
        export PANEL_DIR="$PANEL"
        # shellcheck source=utils/write_overlays.sh
        source "$PANEL/utils/write_overlays.sh"
        write_overlays
    ) >"$WORK_DIR/write-output" 2>&1 || fail "write_overlays failed: $(cat "$WORK_DIR/write-output")"
}

# share_process_namespace OVERLAY: the TimescaleDB pod's setting, as rendered.
share_process_namespace() {
    kubectl kustomize "$PANEL/overlays/$1" >"$WORK_DIR/$1.yaml" || fail "kubectl kustomize $1 failed"
    KUBECONFIG=/dev/null kubectl patch --local -o json --type merge -p '{}' -f "$WORK_DIR/$1.yaml" >"$WORK_DIR/$1.json" ||
        fail "could not read $1 as JSON"
    python3 -I -c '
import json, sys
text = open(sys.argv[1]).read()
decoder = json.JSONDecoder()
at = 0
while at < len(text):
    if text[at].isspace():
        at += 1
        continue
    item, at = decoder.raw_decode(text, at)
    if item.get("kind") == "StatefulSet" and item["metadata"]["name"] == "timescaledb":
        print(item["spec"]["template"]["spec"].get("shareProcessNamespace"))
' "$WORK_DIR/$1.json"
}

test_every_overlay_gives_timescaledb_a_reaper_as_pid_1() {
    make_panel
    local overlay
    for overlay in $OVERLAYS; do
        assert_eq "$(share_process_namespace "$overlay")" "True"
    done
}

run_tests
