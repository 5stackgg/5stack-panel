#!/bin/bash
# Mocks and PANEL_DIR are consumed by the sourced updater functions.
# shellcheck disable=SC2329,SC2034
# Source selection must never silently replace a fork or a missing beta image.
# shellcheck source=tests/scripts/lib.sh
source "$(dirname "$0")/lib.sh"
# shellcheck source=utils/update_source.sh
source "$TEST_ROOT/utils/update_source.sh"

profile() {
    jq -n '{version:1,mode:"custom",panel:null,images:(["api","web","game-server-node-connector","demo-parser","game-streamer","game-server-sw","game-server-css"] | map({key:.,value:("ghcr.io/example/"+.+":testing")}) | from_entries)}'
}

document() {
    jq -n --arg profile "$1" '{data:{"profile.json":$profile}}'
}

test_complete_custom_profile() {
    profile | update_source_validate || fail "valid complete source rejected"
    if profile | jq 'del(.images.web)' | update_source_validate; then fail "missing image accepted"; fi
    if profile | jq '.images.api="name:tag;id"' | update_source_validate; then fail "shell syntax accepted"; fi
    if profile | jq '.panel={repository:"example/panel",ref:"../main"}' | update_source_validate; then fail "unsafe ref accepted"; fi
}

test_beta_never_falls_back() {
    kubectl() { document '{"version":1,"mode":"official","channel":"beta"}'; }
    git() { case "$*" in *branch*) echo beta ;; *remote\ get-url*) echo https://github.com/5stackgg/5stack-panel.git ;; *remote*) echo origin ;; esac; }
    update_source_image_available() { echo "$1" >>"$WORK_DIR/images"; return 1; }
    PANEL_DIR="$WORK_DIR"
    if update_source_prepare; then fail "unavailable beta accepted"; fi
    assert_contains "$(cat "$WORK_DIR/images")" ":beta"
    assert_not_contains "$(cat "$WORK_DIR/images")" ":latest"
    assert_eq "$FIVESTACK_UPDATE_PROFILE" ""
}

test_wrong_panel_path_stops_before_registry_or_apply() {
    kubectl() { document "$(profile | jq '.panel={repository:"example/panel",ref:"testing"}')"; }
    git() { case "$*" in *branch*) echo main ;; *remote\ get-url*) echo https://github.com/5stackgg/5stack-panel.git ;; *remote*) echo origin ;; esac; }
    update_source_image_available() { touch "$WORK_DIR/registry-called"; }
    PANEL_DIR="$WORK_DIR"
    if update_source_prepare; then fail "wrong Git source accepted"; fi
    [ ! -f "$WORK_DIR/registry-called" ] || fail "registry called before Git validation"
}

test_hashed_configmaps_preserve_current_runtime_images() {
    kubectl() {
        case "$*" in
            *"get deployments"*) jq -n '{items:[{metadata:{name:"api"},spec:{template:{spec:{containers:[{image:"ghcr.io/example/api:testing",envFrom:[{configMapRef:{name:"api-config-hashed"}},{configMapRef:{name:"optional-missing",optional:true}}]}]}}}},{metadata:{name:"web"},spec:{template:{spec:{containers:[{image:"ghcr.io/example/web:testing"}]}}}},{metadata:{name:"demo-parser"},spec:{template:{spec:{containers:[{image:"ghcr.io/example/demo-parser:testing"}]}}}}]}' ;;
            *"get daemonset"*) echo '{"spec":{"template":{"spec":{"containers":[{"image":"ghcr.io/example/connector:testing"}]}}}}' ;;
            *"get configmap optional-missing"*) ;;
            *"get configmap api-config-hashed"*) echo '{"data":{"GAME_STREAMER_IMAGE":"ghcr.io/example/streamer:testing","SERVER_IMAGE":"ghcr.io/example/server:testing"}}' ;;
            *) fail "unexpected kubectl call: $*" ;;
        esac
    }
    local current
    current="$(update_source_current_images)" || fail "failed to resolve generated config"
    assert_eq "$(jq -r '.["game-streamer"]' <<<"$current")" "ghcr.io/example/streamer:testing"
    assert_eq "$(jq -r '.["game-server-css"]' <<<"$current")" "ghcr.io/example/server:testing"
}

test_render_applies_only_selected_core_images() {
    FIVESTACK_UPDATE_PROFILE="$(profile)"
    FIVESTACK_UPDATE_SELECTION="$FIVESTACK_UPDATE_PROFILE"
    kubectl() {
        case "$*" in
            *"get configmap 5stack-update-source"*) document "$FIVESTACK_UPDATE_SELECTION" ;;
            *"create --dry-run=client"*) cat "$WORK_DIR/objects.json" ;;
            *) fail "mutation attempted during render" ;;
        esac
    }
    jq -n '{apiVersion:"v1",kind:"List",items:[
      {kind:"Deployment",metadata:{name:"api",namespace:"5stack"},spec:{template:{spec:{containers:[{name:"api",image:"old",env:[{name:"KEEP_ME",value:"keep"},{name:"SERVER_IMAGE",value:"old"}]}]}}}},
      {kind:"Deployment",metadata:{name:"hasura",namespace:"5stack"},spec:{template:{spec:{containers:[{name:"hasura",image:"engine"}],initContainers:[{name:"migrations",image:"old"}]}}}},
      {kind:"Deployment",metadata:{name:"inventory-backend",namespace:"5stack"},spec:{template:{spec:{containers:[{name:"inventory-backend",image:"private-plugin"}]}}}},
      {kind:"StatefulSet",metadata:{name:"timescaledb"},spec:{template:{spec:{containers:[{image:"pg17"}]}}}},
      {kind:"Secret",metadata:{name:"example"},data:{value:"cHJpdmF0ZQ=="}}
    ]}' >"$WORK_DIR/objects.json"
    touch "$WORK_DIR/rendered"
    update_source_render "$WORK_DIR/rendered" || fail "render failed"
    jq -e '.items[0].spec.template.spec.containers[0] | .image=="ghcr.io/example/api:testing" and .imagePullPolicy=="Always" and (.env|map(select(.name=="KEEP_ME"))[0].value)=="keep" and (.env|map(select(.name=="SERVER_IMAGE"))[0].value)=="" and (.env|map(select(.name=="GAME_STREAMER_IMAGE"))[0].value)=="ghcr.io/example/game-streamer:testing"' "$WORK_DIR/rendered" >/dev/null || fail "core images/env not applied"
    jq -e '.items[1].spec.template.spec | .containers[0].image=="engine" and .initContainers[0].image=="ghcr.io/example/api:testing"' "$WORK_DIR/rendered" >/dev/null || fail "migration image mismatch"
    assert_eq "$(jq -c '.items[2:]' "$WORK_DIR/rendered")" "$(jq -c '.items[2:]' "$WORK_DIR/objects.json")"
}

test_source_change_during_preflight_stops_apply() {
    FIVESTACK_UPDATE_PROFILE="$(profile)"
    FIVESTACK_UPDATE_SELECTION="$FIVESTACK_UPDATE_PROFILE"
    kubectl() { document '{"version":1,"mode":"installed"}'; }
    echo preserved >"$WORK_DIR/rendered"
    if update_source_render "$WORK_DIR/rendered"; then fail "concurrent source edit accepted"; fi
    assert_eq "$(cat "$WORK_DIR/rendered")" "preserved"
}

run_tests
