#!/bin/bash
# One persisted source for API update checks and host applies. No channel fallback.
FIVESTACK_UPDATE_PROFILE=""
FIVESTACK_UPDATE_SELECTION=""

update_source_validate() {
    jq -e '
      def image: type == "string" and length <= 512 and
        test("^(?:[a-z0-9.-]+(?::[0-9]+)?/)?[a-z0-9]+(?:[._-][a-z0-9]+)*(?:/[a-z0-9]+(?:[._-][a-z0-9]+)*)*(?::[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}|@sha256:[a-f0-9]{64})?$");
      def panel: . == null or (type == "object" and
        (.repository | type == "string" and test("^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$") and (contains("..")|not)) and
        (.ref | type == "string" and test("^[A-Za-z0-9][A-Za-z0-9._/-]{0,180}$") and (contains("..")|not) and (contains("//")|not) and (endswith("/")|not) and (endswith(".lock")|not)));
      .version == 1 and (.mode == "installed" or .mode == "official" or .mode == "custom") and
      (.panel | panel) and (.images | type == "object") and
      (.images | keys | sort) == (["api","web","game-server-node-connector","demo-parser","game-streamer","game-server-sw","game-server-css"]|sort) and
      (.images | all(.[]; image))
    ' >/dev/null
}

update_source_current_images() {
    local deployments connector config config_name configs="[]"
    local -a kc=()
    [ -n "${KUBECONFIG:-}" ] && kc=(--kubeconfig="$KUBECONFIG")
    deployments="$(kubectl "${kc[@]}" -n 5stack get deployments api web demo-parser -o json)" || return 1
    connector="$(kubectl "${kc[@]}" -n 5stack get daemonset game-server-node-connector -o json)" || return 1
    # Kustomize hashes generated ConfigMap names. Follow the deployment's actual
    # envFrom order so a preserved installation cannot silently inherit defaults.
    while IFS= read -r config_name; do
        config="$(kubectl "${kc[@]}" -n 5stack get configmap "$config_name" -o json)" || return 1
        configs="$(jq --argjson config "$config" '. + [$config]' <<<"$configs")" || return 1
    done < <(jq -r '.items[] | select(.metadata.name=="api") | .spec.template.spec.containers[0].envFrom[]?.configMapRef.name // empty' <<<"$deployments")
    config="$(jq '{data: (reduce .[] as $item ({}; . + ($item.data // {})))}' <<<"$configs")" || return 1
    jq -n --argjson ds "$deployments" --argjson connector "$connector" --argjson config "$config" '
      ($ds.items | map(select(.metadata.name == "api"))[0].spec.template.spec.containers[0]) as $api |
      (($api.env // []) | map(select(.value != null)) | map({key:.name,value:.value}) | from_entries) as $env |
      ($config.data // {}) as $base |
      def setting($name; $fallback): $env[$name] // $base[$name] // $fallback;
      {
        api: ($ds.items | map(select(.metadata.name == "api"))[0].spec.template.spec.containers[0].image),
        web: ($ds.items | map(select(.metadata.name == "web"))[0].spec.template.spec.containers[0].image),
        "demo-parser": ($ds.items | map(select(.metadata.name == "demo-parser"))[0].spec.template.spec.containers[0].image),
        "game-server-node-connector": $connector.spec.template.spec.containers[0].image,
        "game-streamer": setting("GAME_STREAMER_IMAGE"; "ghcr.io/5stackgg/game-streamer:latest"),
        "game-server-sw": (setting("SERVER_IMAGE"; "") as $override | if $override != "" then $override else setting("GAME_SERVER_SW_IMAGE"; "ghcr.io/5stackgg/game-server-sw:latest") end),
        "game-server-css": (setting("SERVER_IMAGE"; "") as $override | if $override != "" then $override else setting("GAME_SERVER_CSS_IMAGE"; "ghcr.io/5stackgg/game-server-css:latest") end)
      }'
}

update_source_image_available() {
    local image="$1" parsed registry repository reference token
    parsed="$(jq -nr --arg image "$image" '
      ($image | if contains("@") then split("@") | {base:.[0],ref:.[1]}
        elif (split("/")[-1] | contains(":")) then capture("^(?<base>.*):(?<ref>[^:]+)$")
        else {base:.,ref:"latest"} end) as $p |
      ($p.base | split("/")) as $parts |
      if ($parts|length)>1 and ($parts[0]|test("[.:]|^localhost$")) then
        [$parts[0],($parts[1:]|join("/")),$p.ref]
      else ["docker.io",(if ($parts|length)==1 then "library/" else "" end)+$p.base,$p.ref] end | @tsv
    ')" || return 1
    IFS=$'\t' read -r registry repository reference <<<"$parsed"
    if [ "$registry" = docker.io ]; then
        token="$(curl -fsS --max-time 15 "https://auth.docker.io/token?service=registry.docker.io&scope=repository:$repository:pull" | jq -er '.token // .access_token')" || return 1
        registry="registry-1.docker.io"
    else
        token="$(curl -fsS --max-time 15 "https://$registry/token?scope=repository:$repository:pull" | jq -r '.token // .access_token // empty')" || token=""
    fi
    local -a headers=()
    [ -n "$token" ] && headers=(-H "Authorization: Bearer $token")
    curl -fsS --max-time 15 "${headers[@]}" \
        -H 'Accept: application/vnd.oci.image.index.v1+json,application/vnd.docker.distribution.manifest.list.v2+json,application/vnd.oci.image.manifest.v1+json,application/vnd.docker.distribution.manifest.v2+json' \
        -o /dev/null "https://$registry/v2/$repository/manifests/$reference"
}

update_source_prepare() {
    FIVESTACK_UPDATE_PROFILE=""
    FIVESTACK_UPDATE_SELECTION=""
    local document profile mode images panel expected_repo expected_ref branch remote url matched
    local -a kc=()
    [ -n "${KUBECONFIG:-}" ] && kc=(--kubeconfig="$KUBECONFIG")
    document="$(kubectl "${kc[@]}" -n 5stack get configmap 5stack-update-source --ignore-not-found -o json)" || return 1
    [ -n "$document" ] || return 0
    profile="$(jq -r '.data["profile.json"] // empty' <<<"$document")" || return 1
    [ -n "$profile" ] || return 0
    FIVESTACK_UPDATE_SELECTION="$profile"
    mode="$(jq -er '.mode' <<<"$profile")" || return 1
    case "$mode" in
        installed)
            images="$(update_source_current_images)" || return 1
            profile="$(jq --argjson images "$images" '. + {images:$images}' <<<"$profile")" || return 1
            ;;
        official)
            profile="$(jq '
              if .channel != "latest" and .channel != "beta" then error("invalid channel") else . end |
              .panel={repository:"5stackgg/5stack-panel",ref:(if .channel=="beta" then "beta" else "main" end)} |
              .images=(.channel as $tag | ["api","web","game-server-node-connector","demo-parser","game-streamer","game-server-sw","game-server-css"] | map({key:.,value:("ghcr.io/5stackgg/"+.+":"+$tag)}) | from_entries)
            ' <<<"$profile")" || return 1
            ;;
        custom) ;;
        *) echo "Invalid update source; no resources were applied." >&2; return 1 ;;
    esac
    if ! update_source_validate <<<"$profile"; then
        echo "Invalid selected update source; no resources were applied." >&2
        return 1
    fi
    panel="$(jq -c '.panel // null' <<<"$profile")"
    if [ "$panel" = null ]; then
        panel="$(jq -c '(.data["installed.json"] // "{}" | fromjson).panel // null' <<<"$document")" || return 1
    fi
    expected_repo="$(jq -r '.repository // empty' <<<"$panel")"
    expected_ref="$(jq -r '.ref // empty' <<<"$panel")"
    if [ -n "$expected_repo" ] && [ -n "$expected_ref" ]; then
        branch="$(git -C "$PANEL_DIR" branch --show-current)"
        matched=false
        while IFS= read -r remote; do
            url="$(git -C "$PANEL_DIR" remote get-url "$remote")"
            case "$url" in
                "https://github.com/$expected_repo"|"https://github.com/$expected_repo.git"|"git@github.com:$expected_repo"|"git@github.com:$expected_repo.git")
                    [ "$branch" = "$expected_ref" ] && matched=true ;;
            esac
        done < <(git -C "$PANEL_DIR" remote)
        if [ "$matched" != true ]; then
            if [ -z "$branch" ] &&
               [ "$(git -C "$PANEL_DIR" config --get 5stack.update-source-repository)" = "$expected_repo" ] &&
               [ "$(git -C "$PANEL_DIR" config --get 5stack.update-source-ref)" = "$expected_ref" ] &&
               [ "$(git -C "$PANEL_DIR" rev-parse HEAD)" = "$(git -C "$PANEL_DIR" rev-parse FETCH_HEAD)" ]; then
                matched=true
            fi
        fi
        if [ "$matched" != true ]; then
            echo "Check out the selected panel repository/ref before running the updater: $expected_repo@$expected_ref" >&2
            return 1
        fi
    fi
    while IFS= read -r image; do
        if ! update_source_image_available "$image"; then
            echo "Selected build unavailable: $image. No stable or original build was substituted." >&2
            return 1
        fi
    done < <(jq -r '.images[]' <<<"$profile")
    FIVESTACK_UPDATE_PROFILE="$profile"
}

update_source_assert_selection() {
    local current
    local -a kc=()
    [ -n "${KUBECONFIG:-}" ] && kc=(--kubeconfig="$KUBECONFIG")
    current="$(kubectl "${kc[@]}" -n 5stack get configmap 5stack-update-source -o json | jq -r '.data["profile.json"] // empty')" || return 1
    if [ "$current" != "$FIVESTACK_UPDATE_SELECTION" ]; then
        echo "The update source changed during preflight; run the updater again." >&2
        return 1
    fi
}

update_source_render() {
    local rendered="$1" decoded transformed
    [ -n "$FIVESTACK_UPDATE_PROFILE" ] || return 0
    update_source_assert_selection || return 1
    local -a kc=()
    [ -n "${KUBECONFIG:-}" ] && kc=(--kubeconfig="$KUBECONFIG")
    decoded="$(mktemp)"; transformed="$(mktemp)"
    if ! kubectl "${kc[@]}" create --dry-run=client --validate=false -f "$rendered" -o json >"$decoded"; then
        rm -f "$decoded" "$transformed"; return 1
    fi
    if ! jq -s --argjson profile "$FIVESTACK_UPDATE_PROFILE" '
      def image($ref): .image=$ref | .imagePullPolicy=(if $ref|contains("@") then "IfNotPresent" else "Always" end);
      [ .[] | if .kind=="List" then .items[] else . end ] |
      map(if (.kind=="Deployment" or .kind=="DaemonSet") and (.metadata.namespace // "5stack")=="5stack" then
        if .metadata.name=="api" then
          .spec.template.spec.containers |= map(if .name=="api" then
            image($profile.images.api) |
            .env=((.env // []) | map(select(.name!="GAME_STREAMER_IMAGE" and .name!="GAME_SERVER_SW_IMAGE" and .name!="GAME_SERVER_CSS_IMAGE" and ($profile.mode=="installed" or .name!="SERVER_IMAGE"))) +
              [{name:"GAME_STREAMER_IMAGE",value:$profile.images["game-streamer"]},{name:"GAME_SERVER_SW_IMAGE",value:$profile.images["game-server-sw"]},{name:"GAME_SERVER_CSS_IMAGE",value:$profile.images["game-server-css"]}] +
              (if $profile.mode=="installed" then [] else [{name:"SERVER_IMAGE",value:""}] end))
          else . end)
        elif .metadata.name=="hasura" then .spec.template.spec.initContainers |= map(if .name=="migrations" then image($profile.images.api) else . end)
        elif .metadata.name=="web" then .spec.template.spec.containers |= map(if .name=="web" then image($profile.images.web) else . end)
        elif .metadata.name=="demo-parser" then .spec.template.spec.containers[0] |= image($profile.images["demo-parser"])
        elif (.metadata.name=="game-server-node-connector" or .metadata.name=="game-server-node-connector-nvidia") then .spec.template.spec.containers[0] |= image($profile.images["game-server-node-connector"])
        else . end
      else . end) | {apiVersion:"v1",kind:"List",items:.}
    ' "$decoded" >"$transformed"; then
        rm -f "$decoded" "$transformed"; return 1
    fi
    mv "$transformed" "$rendered"; rm -f "$decoded"
}

update_source_record_install() {
    local sha="$1" repository="" ref="" existing installed profile
    local -a kc=()
    [ -n "${KUBECONFIG:-}" ] && kc=(--kubeconfig="$KUBECONFIG")
    existing="$(kubectl "${kc[@]}" -n 5stack get configmap 5stack-update-source --ignore-not-found -o json)" || return 1
    [ -n "$existing" ] || return 0
    profile="$FIVESTACK_UPDATE_PROFILE"
    [ -n "$profile" ] || profile='{"version":1,"mode":"installed"}'
    repository="$(jq -r '.panel.repository // empty' <<<"$profile")"
    ref="$(jq -r '.panel.ref // empty' <<<"$profile")"
    if [ -z "$repository" ] || [ -z "$ref" ]; then
        repository="$(git -C "$PANEL_DIR" remote get-url origin | sed -E 's#^(https://github.com/|git@github.com:)##; s#\.git$##')"
        ref="$(git -C "$PANEL_DIR" branch --show-current)"
    fi
    installed="$(jq -n --arg sha "$sha" --arg repository "$repository" --arg ref "$ref" '{version:1,panel:{repository:$repository,ref:$ref,sha:$sha}}')" || return 1
    kubectl "${kc[@]}" -n 5stack patch configmap 5stack-update-source --type=merge \
        -p "$(jq -n --arg installed "$installed" '{data:{"installed.json":$installed}}')" >/dev/null
}
