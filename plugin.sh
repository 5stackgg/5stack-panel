#!/bin/bash
#
# Install a 5Stack plugin from its repository.
#
#   ./plugin.sh https://github.com/lukepolo/5stack-inventory-plugin
#   ./plugin.sh 5stackgg/5stack-plugin-hello-world
#   ./plugin.sh list
#   ./plugin.sh remove inventory
#
# Any plugin that ships a `5stack-plugin.json` with an `install` block and a
# kustomize package works — there is nothing plugin-specific in this script.
# The format is documented at https://docs.5stack.gg/plugins/installing
#
# The point of it is that this site is already configured. The kubeconfig, the
# domain, whether TLS terminates here or in front of us, the Postgres
# credentials — all of that was settled when you installed the panel, and this
# reads it rather than asking you again:
#
#   .5stack-env.config       -> KUBECONFIG, REVERSE_PROXY
#   REVERSE_PROXY            -> which of the plugin's two installs to apply
#   overlays/config/*.env    -> WEB_DOMAIN, so the plugin defaults to
#                               <prefix>.<your domain>
#   the cluster              -> the Postgres connection string
#   the node label           -> where a node-bound plugin already lives
#
# Plugins land in custom/<slug>/ — the same place ./custom.sh deploys from, so
# the two agree on the node label (5stack-<slug>) and you can hand-edit and
# re-apply a plugin without this script.
set -euo pipefail

PANEL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$PANEL_DIR"

source "$PANEL_DIR/utils/colors.sh"
source "$PANEL_DIR/utils/update_env_var.sh"
source "$PANEL_DIR/utils/interactive_select.sh"
source "$PANEL_DIR/utils/setup_kustomize.sh"
source "$PANEL_DIR/utils/apply_overlay.sh"

# Deliberately NOT utils/utils.sh: that sources setup-env.sh, which re-runs the
# whole panel setup (cloudflare/reverse-proxy questions, secret generation,
# vault migration). Installing a plugin should read that config, never redo it.

PLUGINS_DIR="$PANEL_DIR/custom"

die() { echo; err "$1"; echo; exit 1; }

# copy_tree SRC DST — without the parts of a checkout that have no business
# being deployed. A GitHub tarball never contains these, but installing from a
# local path (which is how you test a plugin you're writing) otherwise copies a
# half-gigabyte of node_modules into custom/.
copy_tree() {
    mkdir -p "$2"
    ( cd "$1" && tar --exclude='./node_modules' --exclude='./.git' -cf - . ) \
        | ( cd "$2" && tar -xf - )
}

# ---------------------------------------------------------------------------
# Args
# ---------------------------------------------------------------------------

COMMAND="install"
SOURCE=""
REF=""
DOMAIN=""
NODE_NAME=""
DATABASE_URL_ARG=""
TLS_MODE=""
ASSUME_YES=false
DRY_RUN=false
KUBECONFIG_ARG=false

usage() {
    cat <<EOF

  ${C_STEP}5Stack plugin installer${C_RESET}

  ./plugin.sh <repo>              install or upgrade a plugin
  ./plugin.sh list                what's installed
  ./plugin.sh remove <slug>       delete a plugin from the cluster

  <repo> is a GitHub URL, an owner/repo shorthand, or a local directory.

  --ref <branch|tag>   which ref to download (default: main, then master)
  --domain <host>      host to serve on (default: <prefix>.<your WEB_DOMAIN>)
  --node <name>        node to pin to (default: the labeled one, else asked)
  --database-url <url> Postgres URL (default: copied from the cluster)
  --kubeconfig <path>  (default: from .5stack-env.config)
  --tls / --no-tls     force the certificate / plain-HTTP install
  --dry-run            print the manifests instead of applying them
  -y, --yes            accept every default, ask nothing
  -h, --help           this

EOF
    exit 0
}

[ $# -gt 0 ] || usage

case "${1:-}" in
    list|remove) COMMAND="$1"; shift ;;
    -h|--help)   usage ;;
esac

while [[ $# -gt 0 ]]; do
    case "$1" in
        --ref)          REF="$2"; shift 2 ;;
        --domain)       DOMAIN="$2"; shift 2 ;;
        --node)         NODE_NAME="$2"; shift 2 ;;
        --database-url) DATABASE_URL_ARG="$2"; shift 2 ;;
        --kubeconfig)   KUBECONFIG="$2"; export KUBECONFIG; KUBECONFIG_ARG=true; shift 2 ;;
        --tls)          TLS_MODE=https; shift ;;
        --no-tls)       TLS_MODE=http; shift ;;
        --dry-run)      DRY_RUN=true; shift ;;
        -y|--yes)       ASSUME_YES=true; shift ;;
        -h|--help)      usage ;;
        -*)             die "unknown option: $1 (try --help)" ;;
        *)              [ -z "$SOURCE" ] && SOURCE="$1"; shift ;;
    esac
done

ask() {
    local prompt="$1" default="$2" answer
    if [ "$ASSUME_YES" = true ] || [ ! -r /dev/tty ]; then
        echo "$default"; return
    fi
    printf "    %s [%s]: " "$prompt" "$default" > /dev/tty
    read -r answer < /dev/tty || answer=""
    echo "${answer:-$default}"
}

# ---------------------------------------------------------------------------
# Site config. Read, never rewritten.
# ---------------------------------------------------------------------------

[ -f "$PANEL_DIR/.5stack-env.config" ] \
    || die "No .5stack-env.config here — run ./install.sh first."

PANEL_KUBECONFIG=""; REVERSE_PROXY=""
while IFS='=' read -r key value; do
    value="${value%\"}"; value="${value#\"}"
    case "$key" in
        KUBECONFIG)    PANEL_KUBECONFIG="$value" ;;
        REVERSE_PROXY) REVERSE_PROXY="$value" ;;
    esac
done < <(grep -E '^(KUBECONFIG|REVERSE_PROXY)=' "$PANEL_DIR/.5stack-env.config" || true)

if [ "$KUBECONFIG_ARG" != true ]; then
    KUBECONFIG="${PANEL_KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"
    export KUBECONFIG
fi

command -v kubectl >/dev/null || die "kubectl is required."
kubectl version -o json >/dev/null 2>&1 || die "kubectl can't reach the cluster ($KUBECONFIG)."

WEB_DOMAIN="$(grep -h '^WEB_DOMAIN=' overlays/config/api-config.env 2>/dev/null | cut -d '=' -f2- || true)"

# ---------------------------------------------------------------------------
# list / remove
# ---------------------------------------------------------------------------

manifest_of() {  # manifest_of <dir> -> path, or empty
    local dir="$1" candidate
    for candidate in "$dir/public/5stack-plugin.json" "$dir/5stack-plugin.json" "$dir/dist/5stack-plugin.json"; do
        [ -f "$candidate" ] && { echo "$candidate"; return 0; }
    done
    # 0 even when there's nothing: "no manifest" is an answer, not a failure,
    # and under `set -e` a non-zero return here would kill the caller mid-loop.
    return 0
}

# Reads one dotted path out of a JSON file. Arrays come back space-separated,
# absent/null as the empty string.
json_read() {
    local file="$1" path="$2"
    if command -v python3 >/dev/null 2>&1; then
        python3 -c '
import json, sys
try:
    cur = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)
for part in sys.argv[2].split("."):
    if isinstance(cur, dict) and part in cur:
        cur = cur[part]
    else:
        sys.exit(0)
if cur is None:
    sys.exit(0)
if isinstance(cur, bool):
    print("true" if cur else "false")
elif isinstance(cur, list):
    print(" ".join(str(x) for x in cur))
else:
    print(cur)
' "$file" "$path"
    elif command -v jq >/dev/null 2>&1; then
        jq -r --arg p "$path" '
            getpath($p | split("."))
            | if . == null then empty
              elif type == "array" then join(" ")
              else tostring end' "$file" 2>/dev/null
    else
        die "python3 or jq is required to read a plugin manifest."
    fi
}

if [ "$COMMAND" = "list" ]; then
    step "Installed plugins"
    found=false
    for dir in "$PLUGINS_DIR"/*/; do
        [ -d "$dir" ] || continue
        manifest="$(manifest_of "${dir%/}")"
        [ -n "$manifest" ] || continue
        found=true
        slug="$(json_read "$manifest" slug)"
        name="$(json_read "$manifest" name)"
        domain_var="$(json_read "$manifest" install.domain.var)"
        domain=""
        if [ -n "$domain_var" ]; then
            domain_file="${dir%/}/$(json_read "$manifest" install.domain.file)"
            domain="$(grep -h "^$domain_var=" "$domain_file" 2>/dev/null | cut -d '=' -f2- || true)"
        fi
        printf "    %-14s %-22s %s\n" "$slug" "$name" "$domain"
    done
    [ "$found" = true ] || echo "    (none — ./plugin.sh <repo> to add one)"
    echo
    exit 0
fi

if [ "$COMMAND" = "remove" ]; then
    [ -n "$SOURCE" ] || die "which plugin? ./plugin.sh remove <slug>"
    dir="$PLUGINS_DIR/$SOURCE"
    [ -d "$dir" ] || die "no plugin at $dir — ./plugin.sh list"
    manifest="$(manifest_of "$dir")"
    [ -n "$manifest" ] || die "$dir has no 5stack-plugin.json."

    overlay_http="$(json_read "$manifest" install.overlays.http)"
    overlay_https="$(json_read "$manifest" install.overlays.https)"
    setup_kustomize

    step "Removing $SOURCE"
    warn "This deletes its workloads from the cluster. Data in Postgres is left alone."
    confirm_default=n
    [ "$ASSUME_YES" = true ] && confirm_default=y
    if [ "$(ask "Continue? (y/n)" "$confirm_default")" != "y" ]; then die "cancelled."; fi

    for overlay in "$overlay_https" "$overlay_http"; do
        [ -n "$overlay" ] && [ -d "$dir/$overlay" ] || continue
        ./kustomize build "$dir/$overlay" | kubectl delete --ignore-not-found -f - || true
        break
    done
    ok "removed from the cluster"
    echo "    Files are still at $dir — delete them by hand if you're done with it."
    echo
    exit 0
fi

# ---------------------------------------------------------------------------
# Fetch
# ---------------------------------------------------------------------------

[ -n "$SOURCE" ] || usage

banner "5Stack : Plugin Install"

STAGED=""   # where the freshly fetched copy is
step "Fetching $SOURCE"

if [ -d "$SOURCE" ]; then
    STAGED="$(cd "$SOURCE" && pwd)"
    ok "local directory $STAGED"
    LOCAL_SOURCE=true
else
    LOCAL_SOURCE=false
    command -v curl >/dev/null || die "curl is required."
    command -v tar  >/dev/null || die "tar is required."

    repo="$SOURCE"
    repo="${repo%.git}"
    repo="${repo%/}"
    case "$repo" in
        *"#"*) REF="${REF:-${repo#*#}}"; repo="${repo%%#*}" ;;
    esac
    case "$repo" in
        https://github.com/*/tree/*)
            REF="${REF:-${repo##*/tree/}}"
            repo="${repo%%/tree/*}"
            ;;
    esac
    case "$repo" in
        https://*|http://*) ;;
        */*) repo="https://github.com/$repo" ;;
        *)   die "can't tell what '$SOURCE' is — use a GitHub URL, owner/repo, or a local path." ;;
    esac

    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' EXIT

    fetched=false
    for candidate_ref in ${REF:-main master}; do
        url="$repo/archive/refs/heads/$candidate_ref.tar.gz"
        if curl -fsSL "$url" | tar -xz -C "$tmp" 2>/dev/null; then
            ok "$repo @ $candidate_ref"
            fetched=true
            break
        fi
        # not a branch? try it as a tag
        url="$repo/archive/refs/tags/$candidate_ref.tar.gz"
        if curl -fsSL "$url" | tar -xz -C "$tmp" 2>/dev/null; then
            ok "$repo @ tag $candidate_ref"
            fetched=true
            break
        fi
    done
    [ "$fetched" = true ] || die "couldn't download $repo (tried ${REF:-main and master}). Private repo, or wrong ref?"

    STAGED="$(find "$tmp" -mindepth 1 -maxdepth 1 -type d | head -1)"
    [ -n "$STAGED" ] || die "the archive was empty."
fi

# ---------------------------------------------------------------------------
# Manifest
# ---------------------------------------------------------------------------

step "Reading the plugin manifest"

MANIFEST="$(manifest_of "$STAGED")"
[ -n "$MANIFEST" ] \
    || die "no 5stack-plugin.json in that repo (looked in public/, the root, and dist/).
    See https://docs.5stack.gg/plugins/manifest"

SLUG="$(json_read "$MANIFEST" slug)"
NAME="$(json_read "$MANIFEST" name)"
[ -n "$SLUG" ] || die "the manifest has no \"slug\"."

OVERLAY_HTTP="$(json_read "$MANIFEST" install.overlays.http)"
OVERLAY_HTTPS="$(json_read "$MANIFEST" install.overlays.https)"
[ -n "$OVERLAY_HTTP$OVERLAY_HTTPS" ] \
    || die "$NAME ships no \"install\" block, so it can't be deployed to this cluster.
    It is a static build — host it anywhere and register it in the panel.
    See https://docs.5stack.gg/plugins/deploying"

DOMAIN_VAR="$(json_read "$MANIFEST" install.domain.var)"
DOMAIN_FILE="$(json_read "$MANIFEST" install.domain.file)"
DOMAIN_PREFIX="$(json_read "$MANIFEST" install.domain.prefix)"
DOMAIN_PREFIX="${DOMAIN_PREFIX:-$SLUG}"
CERT_NAME="$(json_read "$MANIFEST" install.certificate)"
NODE_LABEL="$(json_read "$MANIFEST" install.node.label)"
DB_VAR="$(json_read "$MANIFEST" install.database.var)"
DB_FILE="$(json_read "$MANIFEST" install.database.file)"
DEPLOYMENTS="$(json_read "$MANIFEST" deployments)"

ok "$NAME ($SLUG)"

# ---------------------------------------------------------------------------
# Land it in custom/<slug>, keeping any answers from a previous install
# ---------------------------------------------------------------------------

TARGET="$PLUGINS_DIR/$SLUG"

if [ "$LOCAL_SOURCE" = true ] && [ "$STAGED" = "$TARGET" ]; then
    :  # already installed from here; nothing to copy
else
    step "Installing into custom/$SLUG"
    mkdir -p "$PLUGINS_DIR"
    if [ -d "$TARGET" ]; then
        # The .env files hold this site's domain and database password. An
        # upgrade replaces code, never answers.
        keep="$(mktemp -d)"
        while IFS= read -r f; do
            mkdir -p "$keep/$(dirname "${f#$TARGET/}")"
            cp "$f" "$keep/${f#$TARGET/}"
        done < <(find "$TARGET" -name '*.env' ! -name '*.example' 2>/dev/null)
        rm -rf "$TARGET"
        copy_tree "$STAGED" "$TARGET"
        (cd "$keep" && find . -type f -exec cp {} "$TARGET"/{} \;) >/dev/null 2>&1 || true
        rm -rf "$keep"
        ok "upgraded (kept your .env files)"
    else
        copy_tree "$STAGED" "$TARGET"
        ok "custom/$SLUG"
    fi
fi

# Seed any *.env the plugin ships only as an example.
while IFS= read -r example; do
    real="${example%.example}"
    [ -f "$real" ] || cp "$example" "$real"
done < <(find "$TARGET" -name '*.env.example' 2>/dev/null)

# ---------------------------------------------------------------------------
# Which install
# ---------------------------------------------------------------------------

step "Choosing the install"

if [ -z "$TLS_MODE" ]; then
    if [ "$REVERSE_PROXY" = "true" ]; then TLS_MODE=http; else TLS_MODE=https; fi
    echo "    ${C_DIM}from this site's REVERSE_PROXY=$REVERSE_PROXY${C_RESET}"
fi

if [ "$TLS_MODE" = "https" ] && [ -n "$OVERLAY_HTTPS" ]; then
    OVERLAY="$OVERLAY_HTTPS"
    ok "certificate — $NAME gets its own, issued by 5stack-issuer"
    if ! kubectl get crd certificates.cert-manager.io >/dev/null 2>&1; then
        die "cert-manager isn't installed, but this site terminates TLS itself.
    Run ./update.sh first, or install with --no-tls."
    fi
    kubectl -n 5stack get issuer 5stack-issuer >/dev/null 2>&1 \
        || warn "Issuer/5stack-issuer not found — the certificate won't issue until it exists."
else
    if [ "$TLS_MODE" = "https" ]; then
        warn "$NAME ships no certificate install; using its HTTP one."
    fi
    OVERLAY="$OVERLAY_HTTP"
    TLS_MODE=http
    ok "plain HTTP — TLS is terminated in front of the cluster"
fi

[ -d "$TARGET/$OVERLAY" ] || die "the manifest points at $OVERLAY, which isn't in the repo."

setup_kustomize

# ---------------------------------------------------------------------------
# Domain
# ---------------------------------------------------------------------------

if [ -n "$DOMAIN_VAR" ] && [ -n "$DOMAIN_FILE" ]; then
    step "Domain"

    CURRENT="$(grep -h "^$DOMAIN_VAR=" "$TARGET/$DOMAIN_FILE" 2>/dev/null | cut -d '=' -f2- || true)"
    if [ -z "$DOMAIN" ]; then
        if [ -n "$CURRENT" ] && [ -n "$WEB_DOMAIN" ] && [[ "$CURRENT" == *"$WEB_DOMAIN" ]]; then
            default_domain="$CURRENT"
        elif [ -n "$WEB_DOMAIN" ]; then
            default_domain="$DOMAIN_PREFIX.$WEB_DOMAIN"
        else
            default_domain="$CURRENT"
        fi
        DOMAIN="$(ask "Host for $NAME" "$default_domain")"
    fi

    [ -n "$DOMAIN" ] && [[ "$DOMAIN" != *" "* ]] || die "invalid domain: '$DOMAIN'"
    if [ -n "$WEB_DOMAIN" ] && [[ "$DOMAIN" != *"$WEB_DOMAIN" ]]; then
        warn "$DOMAIN isn't a subdomain of $WEB_DOMAIN."
        warn "The 5stack session cookie is SameSite=Lax, so it won't be sent there"
        warn "and anything in the plugin that needs a signed-in user will fail."
    fi

    update_env_var "$TARGET/$DOMAIN_FILE" "$DOMAIN_VAR" "$DOMAIN"
    ok "$DOMAIN"
fi

# ---------------------------------------------------------------------------
# Database — plugins get a schema in the panel's Postgres, not their own server
# ---------------------------------------------------------------------------

if [ -n "$DB_VAR" ] && [ -n "$DB_FILE" ]; then
    step "Database"

    EXISTING="$(grep -h "^$DB_VAR=" "$TARGET/$DB_FILE" 2>/dev/null | cut -d '=' -f2- || true)"

    if [ -n "$DATABASE_URL_ARG" ]; then
        DB_URL="$DATABASE_URL_ARG"
        ok "from --database-url"
    elif [ -n "$EXISTING" ] && [[ "$EXISTING" != *CHANGEME* ]]; then
        DB_URL="$EXISTING"
        ok "already configured"
    else
        secret="$(kubectl -n 5stack get secret -o name 2>/dev/null | grep timescaledb-secrets | head -1 || true)"
        DB_URL=""
        if [ -n "$secret" ]; then
            DB_URL="$(kubectl -n 5stack get "$secret" \
                -o jsonpath='{.data.POSTGRES_CONNECTION_STRING}' 2>/dev/null | base64 -d || true)"
        fi
        if [ -n "$DB_URL" ]; then
            # Copied, not referenced: that secret's name carries a kustomize
            # content hash and the plugin is built standalone, so a reference to
            # the bare name would resolve to nothing. It also means this copy
            # does not follow a password rotation.
            ok "copied from the panel's Postgres secret"
            echo "    ${C_DIM}re-run this if you ever rotate the Postgres password${C_RESET}"
        else
            warn "Couldn't read the panel's Postgres secret."
            DB_URL="$(ask "Postgres connection string" "$EXISTING")"
        fi
    fi

    [ -n "$DB_URL" ] && [[ "$DB_URL" != *CHANGEME* ]] \
        || die "no usable Postgres connection string — pass --database-url."
    update_env_var "$TARGET/$DB_FILE" "$DB_VAR" "$DB_URL"
fi

# ---------------------------------------------------------------------------
# Node — the label is the memory of which one, so an upgrade never asks
# ---------------------------------------------------------------------------

if [ -n "$NODE_LABEL" ]; then
    step "Node"

    if [ -z "$NODE_NAME" ]; then
        NODE_NAME="$(kubectl get nodes -l "$NODE_LABEL=true" \
            -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
        [ -n "$NODE_NAME" ] && ok "$NODE_NAME (already labeled $NODE_LABEL=true)"
    fi

    if [ -z "$NODE_NAME" ]; then
        NODES=()
        while IFS= read -r n; do [ -n "$n" ] && NODES+=("$n"); done \
            < <(kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')
        [ "${#NODES[@]}" -gt 0 ] || die "no nodes found."
        if [ "${#NODES[@]}" -eq 1 ] || [ "$ASSUME_YES" = true ] || [ ! -r /dev/tty ]; then
            NODE_NAME="${NODES[0]}"
        else
            echo "    ${C_DIM}$NAME mounts host paths, so it pins to one node.${C_RESET}"
            interactive_menu idx "Which node should it run on?" 0 "${NODES[@]}"
            NODE_NAME="${NODES[$idx]}"
        fi
    fi

    if [ "$DRY_RUN" = true ]; then
        ok "$NODE_NAME would be labeled $NODE_LABEL=true"
    else
        kubectl label node "$NODE_NAME" "$NODE_LABEL=true" --overwrite >/dev/null
        ok "$NODE_NAME labeled $NODE_LABEL=true"
    fi
    echo "    ${C_DIM}to move it later: kubectl label node $NODE_NAME $NODE_LABEL- && ./plugin.sh custom/$SLUG${C_RESET}"
fi

# ---------------------------------------------------------------------------
# Apply
# ---------------------------------------------------------------------------

step "Applying custom/$SLUG/$OVERLAY"

if [ "$DRY_RUN" = true ]; then
    ./kustomize build "$TARGET/$OVERLAY"
    echo
    warn "dry run — nothing was applied"
    echo
    exit 0
fi

# apply_overlay rather than `./kustomize build ... | kubectl apply -f -`: the
# pipeline discarded the status of both halves, so a render error or a rejected
# resource still printed "applied". It also retries a plugin's resources past an
# admission webhook that is still starting.
apply_overlay "$TARGET/$OVERLAY" || die "failed to apply $NAME"
ok "applied"

for deployment in $DEPLOYMENTS; do
    kubectl -n 5stack rollout status "deployment/$deployment" --timeout=300s \
        || warn "$deployment isn't ready — kubectl -n 5stack describe deployment/$deployment"
done

# ---------------------------------------------------------------------------

banner "5Stack : $NAME Installed"

if [ -n "$DOMAIN" ]; then
    echo "    Host      https://$DOMAIN"
fi
echo "    Files     custom/$SLUG"
echo
echo "    ${C_STEP}Still to do${C_RESET}"
if [ -n "$DOMAIN" ]; then
    echo "      1. DNS — point $DOMAIN at the same address as ${WEB_DOMAIN:-this panel}."
    if [ "$TLS_MODE" = "https" ] && [ -n "$CERT_NAME" ]; then
        echo "      2. The certificate issues once that DNS is live:"
        echo "         kubectl -n 5stack get certificate $CERT_NAME -w"
    fi
    echo "      3. Register it: Settings → Application → Panel Plugins → Add,"
    echo "         paste https://$DOMAIN and press Detect."
else
    echo "      Register it: Settings → Application → Panel Plugins → Add, then Detect."
fi
echo
echo "    ${C_DIM}Re-run ./plugin.sh with the same repo to upgrade; your answers are kept.${C_RESET}"
echo
