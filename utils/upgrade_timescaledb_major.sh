#!/bin/bash

# PostgreSQL will not start on a data directory written by an older major. When
# base/timescaledb/stateful-set.yaml moves to a new -pgNN image, the data on the
# volume is upgraded first, by pg_upgrade in a Job on the database node (the
# Job runs utils/timescaledb_major_upgrade_job.sh). Everything here goes through
# kubectl: update.sh is usually run from a laptop against a remote cluster.

TIMESCALEDB_UPGRADE_JOB=timescaledb-major-upgrade
# Outlives the Job, so the follow-up work of an upgrade whose update.sh died
# before reaching it is picked up by the next run.
TIMESCALEDB_UPGRADE_MARKER=timescaledb-major-upgraded
TIMESCALEDB_UPGRADE_FROM=""

timescaledb_kubectl() {
    kubectl --kubeconfig="$KUBECONFIG" -n 5stack "$@"
}

timescaledb_gib() {
    awk -v kb="$1" 'BEGIN { printf "%.1f GiB", kb / 1048576 }'
}

timescaledb_manifest_image() {
    local image
    image="$(sed -n 's/^ *image: *\(timescale\/timescaledb:.*\)$/\1/p' "$PANEL_DIR/base/timescaledb/stateful-set.yaml" | head -n 1)"
    if [[ ! "$image" =~ ^([^:]+):([0-9]+\.[0-9]+\.[0-9]+)-pg([0-9]+)(@sha256:[0-9a-f]+)?$ ]]; then
        err "base/timescaledb/stateful-set.yaml has no <version>-pg<major> timescaledb image: '$image'"
        return 1
    fi
    TIMESCALEDB_IMAGE="$image"
    TIMESCALEDB_REPO="${BASH_REMATCH[1]}"
    TIMESCALEDB_VERSION="${BASH_REMATCH[2]}"
    TIMESCALEDB_MAJOR="${BASH_REMATCH[3]}"
}

# Pins a pod to the database node and mounts the whole volume at /pv: the
# StatefulSet only ever sees its timescaledb/ subPath, and the upgrade needs
# the directories next to it. volumes comes last so callers can add to it.
timescaledb_volume_pod_spec() {
    sed "s/^/$1/" <<EOF
restartPolicy: Never
affinity:
  nodeAffinity:
    requiredDuringSchedulingIgnoredDuringExecution:
      nodeSelectorTerms:
        - matchExpressions:
            - key: 5stack-timescaledb
              operator: In
              values:
                - 'true'
volumes:
  - name: pv
    persistentVolumeClaim:
      claimName: timescaledb-pvc
EOF
}

# until is "started" or "exited". A failed get is the network or the API
# server, not an answer, so it is asked again until the deadline.
timescaledb_wait_container() {
    local pod="$1" container="$2" until="$3" deadline=$((SECONDS + $4)) state=""
    while [ "$SECONDS" -lt "$deadline" ]; do
        if state="$(timescaledb_kubectl get pod "$pod" --ignore-not-found -o jsonpath="{.status.initContainerStatuses[?(@.name==\"$container\")].state}{.status.containerStatuses[?(@.name==\"$container\")].state} {.status.conditions[?(@.type==\"PodScheduled\")].reason}" 2>/dev/null)"; then
            if [ -z "$state" ]; then
                err "pod $pod is gone"
                return 1
            fi
            case "$state" in
                *'"terminated"'*)
                    return 0
                    ;;
                *'"running"'*)
                    if [ "$until" = started ]; then
                        return 0
                    fi
                    ;;
                *InvalidImageName*|*CreateContainerConfigError*)
                    err "$pod/$container cannot start: $state"
                    return 1
                    ;;
            esac
        fi
        sleep 2
    done
    err "timed out waiting for $pod/$container: $state"
    return 1
}

timescaledb_exit_code() {
    local code
    for _ in $(seq 1 30); do
        if code="$(timescaledb_kubectl get pod "$1" -o jsonpath="{.status.initContainerStatuses[?(@.name==\"$2\")].state.terminated.exitCode}{.status.containerStatuses[?(@.name==\"$2\")].state.terminated.exitCode}" 2>/dev/null)" \
            && [ -n "$code" ]; then
            echo "$code"
            return 0
        fi
        sleep 2
    done
    return 1
}

timescaledb_pvc_users() {
    local pods
    pods="$(timescaledb_kubectl get pods -o jsonpath='{range .items[*]}{.metadata.name} {.status.phase} {.spec.volumes[*].persistentVolumeClaim.claimName}{"\n"}{end}')" || return 1
    awk '$2 != "Succeeded" && $2 != "Failed" && / timescaledb-pvc( |$)/ { print $1 }' <<<"$pods"
}

timescaledb_pv_path() {
    local path
    path="$(timescaledb_kubectl get pv timescaledb-pv -o jsonpath='{.spec.local.path}' 2>/dev/null)"
    TIMESCALEDB_PV_PATH="${path:-the timescaledb-pv volume}"
}

# Reads the volume rather than asking postgres, so it answers while postgres is
# down or crash-looping too. ReadWriteOnce only keeps other nodes off the claim,
# so this runs fine next to a live timescaledb-0. Given the old major's image,
# it also pulls that before the downtime starts and checks its postgres runs in
# the new image, which is what the upgrade relies on.
timescaledb_probe_volume() {
    local old_image="${1:-}" pod=timescaledb-volume-probe output key value
    local init="" old_volume="" old_mount=""
    TIMESCALEDB_PROBE_MAJOR=""
    TIMESCALEDB_DATA_KB=""
    TIMESCALEDB_FREE_KB=""
    TIMESCALEDB_SIZE_KB=""
    TIMESCALEDB_PV_ENTRIES=""
    TIMESCALEDB_OLD_BINARY=""

    if [ -n "$old_image" ]; then
        init="  initContainers:
    - name: old-binary
      image: $old_image
      command: [cp, /usr/local/bin/postgres, /old/postgres]
      volumeMounts:
        - name: old-binary
          mountPath: /old"
        old_volume="    - name: old-binary
      emptyDir: {}"
        old_mount="        - name: old-binary
          mountPath: /old"
    fi

    timescaledb_kubectl delete pod "$pod" --ignore-not-found --wait=true --timeout=120s >/dev/null 2>&1
    if ! timescaledb_kubectl apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: $pod
  namespace: 5stack
spec:
$(timescaledb_volume_pod_spec "  ")
$old_volume
$init
  containers:
    - name: probe
      image: $TIMESCALEDB_IMAGE
      command:
        - sh
        - -c
        - |
          cd /pv
          echo "major=\$(cat timescaledb/PG_VERSION 2>/dev/null)"
          echo "data_kb=\$(du -sk timescaledb 2>/dev/null | cut -f1)"
          echo "free_kb=\$(df -Pk . | awk 'NR == 2 { print \$4 }')"
          echo "size_kb=\$(df -Pk . | awk 'NR == 2 { print \$2 }')"
          echo "entries=\$(ls -A | tr '\n' ' ')"
          if [ -e /old/postgres ]; then
            echo "old_binary=\$(/old/postgres -V 2>&1 | head -n 1)"
          fi
      volumeMounts:
        - name: pv
          mountPath: /pv
$old_mount
EOF
    then
        err "could not start a pod to read timescaledb-pvc"
        return 1
    fi

    if ! timescaledb_wait_container "$pod" probe exited 900 || [ "$(timescaledb_exit_code "$pod" probe)" != 0 ]; then
        err "could not read timescaledb-pvc"
        timescaledb_kubectl delete pod "$pod" --ignore-not-found --wait=true --timeout=120s >/dev/null 2>&1
        return 1
    fi
    output="$(timescaledb_kubectl logs "$pod" -c probe)"
    TIMESCALEDB_NODE="$(timescaledb_kubectl get pod "$pod" -o jsonpath='{.spec.nodeName}')"
    timescaledb_kubectl delete pod "$pod" --ignore-not-found --wait=true --timeout=120s >/dev/null 2>&1

    while IFS='=' read -r key value; do
        case "$key" in
            major) TIMESCALEDB_PROBE_MAJOR="$value" ;;
            data_kb) TIMESCALEDB_DATA_KB="$value" ;;
            free_kb) TIMESCALEDB_FREE_KB="$value" ;;
            size_kb) TIMESCALEDB_SIZE_KB="$value" ;;
            entries) TIMESCALEDB_PV_ENTRIES=" $value" ;;
            old_binary) TIMESCALEDB_OLD_BINARY="$value" ;;
        esac
    done <<<"$output"
}

timescaledb_upgrade_consent() {
    local answer
    if [ "${ASSUME_YES:-false}" = true ]; then
        ok "--yes given; upgrading without asking"
        return 0
    fi
    if ! { : </dev/tty; } 2>/dev/null; then
        err "there is no terminal to ask on: re-run ./update.sh in one, or pass --yes (or set ASSUME_YES=true) to upgrade unattended"
        return 1
    fi
    read -r -p "    Stop timescaledb and upgrade it now? [y/N] " answer </dev/tty
    case "$answer" in
        y|Y|yes|Yes|YES)
            return 0
            ;;
    esac
    err "upgrade declined; nothing was changed"
    return 1
}

plan_timescaledb_major_upgrade() {
    local pvc data_major live_image need_kb minutes
    TIMESCALEDB_UPGRADE_FROM=""

    timescaledb_manifest_image || return 1

    if ! pvc="$(timescaledb_kubectl get pvc timescaledb-pvc --ignore-not-found -o name 2>&1)"; then
        err "could not look for timescaledb's volume: ${pvc##*$'\n'}"
        return 1
    fi
    if [ -z "$pvc" ]; then
        return 0
    fi

    data_major="$(timescaledb_kubectl exec timescaledb-0 -c timescaledb -- cat /var/lib/postgresql/data/PG_VERSION 2>/dev/null)"
    if [ -z "$data_major" ]; then
        timescaledb_probe_volume || return 1
        data_major="$TIMESCALEDB_PROBE_MAJOR"
    fi
    if [ -z "$data_major" ]; then
        # An upgrade killed between its two renames leaves the old data only
        # under timescaledb-pgNN, and the apply would initdb an empty database
        # in its place.
        if [[ "$TIMESCALEDB_PV_ENTRIES" == *" timescaledb-pg"* ]]; then
            timescaledb_pv_path
            err "$TIMESCALEDB_PV_PATH on $TIMESCALEDB_NODE holds no database in timescaledb/ but has:$TIMESCALEDB_PV_ENTRIES"
            err "an earlier upgrade was interrupted; move the right timescaledb-pg<major> back to timescaledb, then re-run"
            return 1
        fi
        return 0
    fi
    if [ "$data_major" = "$TIMESCALEDB_MAJOR" ]; then
        return 0
    fi
    if [[ ! "$data_major" =~ ^[0-9]+$ ]]; then
        err "timescaledb's PG_VERSION reads '$data_major'"
        return 1
    fi
    if [ "$data_major" -gt "$TIMESCALEDB_MAJOR" ]; then
        err "the timescaledb data is PostgreSQL $data_major, newer than the PostgreSQL $TIMESCALEDB_MAJOR image in base/timescaledb/stateful-set.yaml"
        return 1
    fi

    step "Upgrading TimescaleDB from PostgreSQL $data_major to $TIMESCALEDB_MAJOR"
    # The running image is the one already on the node, pinned, whenever it is
    # the old major of the TimescaleDB release being moved to.
    live_image="$(timescaledb_kubectl get statefulset timescaledb -o jsonpath='{.spec.template.spec.containers[?(@.name=="timescaledb")].image}' 2>/dev/null)"
    case "$live_image" in
        "$TIMESCALEDB_REPO:$TIMESCALEDB_VERSION-pg$data_major"|"$TIMESCALEDB_REPO:$TIMESCALEDB_VERSION-pg$data_major@"*)
            TIMESCALEDB_OLD_IMAGE="$live_image"
            ;;
        *)
            TIMESCALEDB_OLD_IMAGE="$TIMESCALEDB_REPO:$TIMESCALEDB_VERSION-pg$data_major"
            ;;
    esac
    timescaledb_probe_volume "$TIMESCALEDB_OLD_IMAGE" || return 1
    timescaledb_pv_path

    if [ "$TIMESCALEDB_PROBE_MAJOR" != "$data_major" ]; then
        err "the volume's PG_VERSION reads '$TIMESCALEDB_PROBE_MAJOR', not $data_major"
        return 1
    fi
    if [[ "$TIMESCALEDB_OLD_BINARY" != *"PostgreSQL) $data_major."* ]]; then
        err "PostgreSQL $data_major from $TIMESCALEDB_OLD_IMAGE does not run in $TIMESCALEDB_IMAGE, and pg_upgrade needs both in one container: $TIMESCALEDB_OLD_BINARY"
        return 1
    fi
    if [[ "$TIMESCALEDB_PV_ENTRIES" == *" timescaledb-pg$data_major "* ]]; then
        err "$TIMESCALEDB_PV_PATH/timescaledb-pg$data_major already exists on $TIMESCALEDB_NODE, left by an earlier upgrade; move or delete it and re-run"
        return 1
    fi
    if [[ ! "$TIMESCALEDB_DATA_KB$TIMESCALEDB_FREE_KB$TIMESCALEDB_SIZE_KB" =~ ^[0-9]+$ ]] \
        || [ -z "$TIMESCALEDB_DATA_KB" ] || [ -z "$TIMESCALEDB_FREE_KB" ] || [ -z "$TIMESCALEDB_SIZE_KB" ]; then
        err "could not read the size of $TIMESCALEDB_PV_PATH (used '$TIMESCALEDB_DATA_KB', free '$TIMESCALEDB_FREE_KB', size '$TIMESCALEDB_SIZE_KB' KiB)"
        return 1
    fi

    # On top of the copy, 5% of the disk: k3s evicts pods once a node's disk
    # drops below that, and the volume is usually on the node's disk.
    need_kb=$((TIMESCALEDB_DATA_KB + TIMESCALEDB_DATA_KB / 10 + ${TIMESCALEDB_UPGRADE_HEADROOM_KB:-1048576} + TIMESCALEDB_SIZE_KB / 20))
    if [ "$TIMESCALEDB_FREE_KB" -lt "$need_kb" ]; then
        err "the upgrade copies the database: it needs $(timescaledb_gib "$need_kb") free on $TIMESCALEDB_NODE:$TIMESCALEDB_PV_PATH (the copy, a margin, and the 5% k3s keeps free) and has $(timescaledb_gib "$TIMESCALEDB_FREE_KB"), $(timescaledb_gib $((need_kb - TIMESCALEDB_FREE_KB))) short"
        return 1
    fi

    minutes=$((2 + TIMESCALEDB_DATA_KB / 6144000))
    warn "base/timescaledb/stateful-set.yaml runs PostgreSQL $TIMESCALEDB_MAJOR; the data on the volume is PostgreSQL $data_major"
    echo "    database   $(timescaledb_gib "$TIMESCALEDB_DATA_KB") in $TIMESCALEDB_PV_PATH/timescaledb on $TIMESCALEDB_NODE"
    echo "    disk       $(timescaledb_gib "$TIMESCALEDB_FREE_KB") free, the upgrade needs $(timescaledb_gib "$need_kb")"
    echo "    downtime   about $minutes minutes (copying at ~100 MiB/s): timescaledb is stopped, hasura and the api error until it is back"
    echo "    rollback   the PostgreSQL $data_major data is kept in $TIMESCALEDB_PV_PATH/timescaledb-pg$data_major, on TimescaleDB $TIMESCALEDB_VERSION ($TIMESCALEDB_OLD_IMAGE)"
    timescaledb_upgrade_consent || return 1

    TIMESCALEDB_UPGRADE_FROM="$data_major"
}

# Both containers run the Alpine images the StatefulSet itself runs. A glibc
# image such as timescaledb-ha collates text differently, and every text index
# it touched would come out silently wrong.
timescaledb_upgrade_job_manifest() {
    cat <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: $TIMESCALEDB_UPGRADE_JOB
  namespace: 5stack
spec:
  backoffLimit: 0
  activeDeadlineSeconds: $((3600 + TIMESCALEDB_DATA_KB / 10240))
  ttlSecondsAfterFinished: 86400
  template:
    metadata:
      labels:
        app: $TIMESCALEDB_UPGRADE_JOB
    spec:
$(timescaledb_volume_pod_spec "      ")
        - name: old-binaries
          emptyDir: {}
        - name: script
          configMap:
            name: $TIMESCALEDB_UPGRADE_JOB
      initContainers:
        - name: prepare
          image: $TIMESCALEDB_OLD_IMAGE
          command: [bash, /scripts/upgrade.sh, prepare]
$(timescaledb_upgrade_container_tail)
      containers:
        - name: upgrade
          image: $TIMESCALEDB_IMAGE
          command: [bash, /scripts/upgrade.sh, upgrade]
$(timescaledb_upgrade_container_tail)
EOF
}

timescaledb_upgrade_container_tail() {
    cat <<EOF
          env:
            - name: NEW_MAJOR
              value: "$TIMESCALEDB_MAJOR"
            - name: TIMESCALEDB_VERSION
              value: "$TIMESCALEDB_VERSION"
            - name: POSTGRES_USER
              value: hasura
            - name: TIMESCALEDB_UPGRADE_HEADROOM_KB
              value: "${TIMESCALEDB_UPGRADE_HEADROOM_KB:-1048576}"
          volumeMounts:
            - name: pv
              mountPath: /pv
            - name: old-binaries
              mountPath: /old
            - name: script
              mountPath: /scripts
EOF
}

timescaledb_follow_container() {
    local pod="$1" container="$2" line
    timescaledb_wait_container "$pod" "$container" started 900 || return 1
    timescaledb_kubectl logs -f "$pod" -c "$container" 2>&1 | while IFS= read -r line; do
        echo "    $line"
    done
    timescaledb_wait_container "$pod" "$container" exited $((3600 + TIMESCALEDB_DATA_KB / 10240)) || return 1
    [ "$(timescaledb_exit_code "$pod" "$container")" = 0 ]
}

# Whatever failed on this side, the Job may still be running or yet to start
# (an image pull being retried, a dropped connection), and scaling timescaledb
# up next to it would put two servers on one data directory. So the Job goes
# first, and then the volume says what happened. Returns 0 when it shows the
# upgrade went through after all.
timescaledb_upgrade_failed() {
    local from="$1" tmp="${TMPDIR:-/tmp}" log users
    log="$(mktemp "${tmp%/}/timescaledb-major-upgrade.XXXXXX")"
    timescaledb_kubectl logs "job/$TIMESCALEDB_UPGRADE_JOB" --all-containers --prefix >"$log" 2>&1
    timescaledb_kubectl delete job "$TIMESCALEDB_UPGRADE_JOB" --ignore-not-found --cascade=foreground --wait=true --timeout=300s >/dev/null 2>&1

    if ! users="$(timescaledb_pvc_users)" || [ -n "$users" ]; then
        err "the upgrade did not finish, and its Job could not be confirmed gone. Do not scale timescaledb up while"
        err "    kubectl -n 5stack get pods -l job-name=$TIMESCALEDB_UPGRADE_JOB"
        err "still lists a pod. The Job's output so far is in $log"
        return 1
    fi
    if ! timescaledb_probe_volume; then
        err "the upgrade did not finish and the volume could not be read; check $TIMESCALEDB_PV_PATH on $TIMESCALEDB_NODE before scaling timescaledb up. The Job's output is in $log"
        return 1
    fi

    case "$TIMESCALEDB_PROBE_MAJOR" in
        "$TIMESCALEDB_MAJOR")
            warn "the Job finished the upgrade after all"
            return 0
            ;;
        "$from")
            err "the upgrade did not finish, and the PostgreSQL $from data was left in place. The Job's output is in $log"
            err "fix the cause and re-run ./update.sh, or bring timescaledb back on PostgreSQL $from with:"
            err "    kubectl -n 5stack scale statefulset timescaledb --replicas=1"
            ;;
        *)
            err "the upgrade did not finish, and $TIMESCALEDB_PV_PATH/timescaledb on $TIMESCALEDB_NODE holds no database;"
            err "the PostgreSQL $from data should be in $TIMESCALEDB_PV_PATH/timescaledb-pg$from. The Job's output is in $log"
            ;;
    esac
    return 1
}

# Must run before the overlay apply: the apply starts the new image, and the
# new major only crash-loops on the old data.
upgrade_timescaledb_major() {
    local from="$TIMESCALEDB_UPGRADE_FROM" pod="" users
    if [ -z "$from" ]; then
        return 0
    fi

    step "Stopping timescaledb for the upgrade"
    if timescaledb_kubectl get statefulset timescaledb >/dev/null 2>&1 \
        && ! timescaledb_kubectl scale statefulset timescaledb --replicas=0 >/dev/null; then
        err "could not scale timescaledb down"
        return 1
    fi
    timescaledb_kubectl delete job "$TIMESCALEDB_UPGRADE_JOB" --ignore-not-found --cascade=foreground --wait=true --timeout=300s >/dev/null 2>&1
    timescaledb_kubectl wait --for=delete pod/timescaledb-0 --timeout=300s >/dev/null 2>&1
    if ! users="$(timescaledb_pvc_users)" || [ -n "$users" ]; then
        err "timescaledb is scaled to 0, but timescaledb-pvc is still in use: $(echo "${users:-could not list pods}" | tr '\n' ' ')"
        err "once that is gone, re-run ./update.sh, or bring timescaledb back on PostgreSQL $from with:"
        err "    kubectl -n 5stack scale statefulset timescaledb --replicas=1"
        return 1
    fi
    ok "timescaledb stopped"

    step "Running pg_upgrade on $TIMESCALEDB_NODE"
    if ! timescaledb_kubectl create configmap "$TIMESCALEDB_UPGRADE_JOB" \
            --from-file=upgrade.sh="$PANEL_DIR/utils/timescaledb_major_upgrade_job.sh" --dry-run=client -o yaml \
            | timescaledb_kubectl apply -f - >/dev/null \
        || ! timescaledb_upgrade_job_manifest | timescaledb_kubectl apply -f - >/dev/null; then
        err "could not create the $TIMESCALEDB_UPGRADE_JOB Job"
        timescaledb_upgrade_failed "$from"
        return 1
    fi

    for _ in $(seq 1 60); do
        pod="$(timescaledb_kubectl get pods -l job-name="$TIMESCALEDB_UPGRADE_JOB" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)"
        if [ -n "$pod" ]; then
            break
        fi
        sleep 2
    done

    if [ -z "$pod" ] \
        || ! timescaledb_follow_container "$pod" prepare \
        || ! timescaledb_follow_container "$pod" upgrade; then
        timescaledb_upgrade_failed "$from" || return 1
    fi

    timescaledb_kubectl delete job "$TIMESCALEDB_UPGRADE_JOB" --ignore-not-found --wait=false >/dev/null 2>&1
    timescaledb_kubectl delete configmap "$TIMESCALEDB_UPGRADE_JOB" --ignore-not-found >/dev/null 2>&1
    if ! timescaledb_kubectl create configmap "$TIMESCALEDB_UPGRADE_MARKER" \
            --from-literal=from="$from" --from-literal=to="$TIMESCALEDB_MAJOR" \
            --from-literal=node="$TIMESCALEDB_NODE" --from-literal=path="$TIMESCALEDB_PV_PATH" \
            --from-literal=image="$TIMESCALEDB_OLD_IMAGE" --dry-run=client -o yaml \
            | timescaledb_kubectl apply -f - >/dev/null; then
        warn "could not record the upgrade in the $TIMESCALEDB_UPGRADE_MARKER ConfigMap"
    fi
    ok "data upgraded to PostgreSQL $TIMESCALEDB_MAJOR"
}

# Runs once timescaledb is back on the new image, in the same update.sh as the
# upgrade or, through the marker, in the next one.
finish_timescaledb_major_upgrade() {
    local marker from to node path image
    if [ -n "$TIMESCALEDB_UPGRADE_FROM" ]; then
        from="$TIMESCALEDB_UPGRADE_FROM" to="$TIMESCALEDB_MAJOR" node="$TIMESCALEDB_NODE"
        path="$TIMESCALEDB_PV_PATH" image="$TIMESCALEDB_OLD_IMAGE"
    else
        marker="$(timescaledb_kubectl get configmap "$TIMESCALEDB_UPGRADE_MARKER" --ignore-not-found \
            -o jsonpath='{.data.from}|{.data.to}|{.data.node}|{.data.path}|{.data.image}' 2>/dev/null)"
        if [ -z "$marker" ]; then
            return 0
        fi
        IFS='|' read -r from to node path image <<<"$marker"
    fi

    step "Refreshing planner statistics"
    # pg_upgrade from 18 on carries most statistics over, so only what is
    # missing needs analysing.
    # shellcheck disable=SC2016
    if output_redirect timescaledb_kubectl exec timescaledb-0 -c timescaledb -- sh -c '
        set -- --all --analyze-in-stages
        if vacuumdb --help | grep -q -- --missing-stats-only; then
            set -- "$@" --missing-stats-only
        fi
        vacuumdb -U "$POSTGRES_USER" "$@"'; then
        ok "statistics refreshed"
        timescaledb_kubectl delete configmap "$TIMESCALEDB_UPGRADE_MARKER" --ignore-not-found >/dev/null 2>&1
    else
        warn "vacuumdb failed; the next ./update.sh tries it again"
    fi

    timescaledb_kubectl rollout restart deployment/hasura deployment/api >/dev/null 2>&1
    ok "hasura and the api restarted"

    warn "The PostgreSQL $from data is kept on $node in $path/timescaledb-pg$from."
    echo "    To roll back to it (losing everything written since the upgrade):"
    echo "      kubectl -n 5stack scale statefulset timescaledb --replicas=0"
    echo "      on $node: mv -T $path/timescaledb $path/timescaledb-pg$to-discarded && mv -T $path/timescaledb-pg$from $path/timescaledb"
    echo "      set the image in base/timescaledb/stateful-set.yaml to $image, then run ./update.sh"
    echo "    Once PostgreSQL $to has proven itself, free the space:"
    echo "      on $node: rm -rf $path/timescaledb-pg$from"
}
