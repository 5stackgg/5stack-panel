#!/bin/bash

# shellcheck source=tests/timescaledb/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TARGET=timescale/timescaledb:2.30.2-pg18@sha256:e72689191e1c977892c53d6f2c344dbc4a9657a867dc8cc1899229f9d3672b2e
OLD_PINNED=timescale/timescaledb:2.30.2-pg17@sha256:b346edcdb51a1fd6020e3965e0bd1c9f3406fa6d5fbce1e28f4852587ef934e2
KUBECONFIG_FLAG=--kubeconfig=/home/ops/.kube/prod.yaml
METRICS_WARNING='E1014 18:50:17.402803   77293 memcache.go:287] "Unhandled Error" err="couldn'"'"'t get resource list for metrics.k8s.io/v1beta1: the server is currently unable to handle the request"'

setup_upgrade() {
    load_scripts upgrade_timescaledb_major.sh
    export TIMESCALEDB_UPGRADE_TTY=/nonexistent/tty
    PANEL_DIR="$STUB_DIR/panel"
    manifest "$TARGET"
    stub exit-code 0
}

manifest() {
    mkdir -p "$PANEL_DIR/base/timescaledb"
    printf '      containers:\n        - name: timescaledb\n          image: %s\n' "$1" >"$PANEL_DIR/base/timescaledb/stateful-set.yaml"
}

probe_output() {
    stub probe "major=${1}
data_kb=${2:-10485760}
stage_kb=${3:-}
free_kb=${4:-104857600}
size_kb=${5:-209715200}
entries=${6:-timescaledb }
old_binary=${7:-postgres (PostgreSQL) 17.11}
"
}

volume_on_17() {
    stub pvc persistentvolumeclaim/timescaledb-pvc
    stub pg-version 17
    stub sts-image "$OLD_PINNED"
    stub job-pod timescaledb-major-upgrade-x7k2p
    stub exit-code 0
    probe_output 17
}

planned_upgrade() {
    setup_upgrade
    volume_on_17
    ASSUME_YES=true plan_timescaledb_major_upgrade >"$STUB_DIR/plan-output" 2>&1 || fail "plan returned $?: $(cat "$STUB_DIR/plan-output")"
}

pod_states() {
    printf '%s\n' "$@" >"$STUB_DIR/pod-states"
}

kubectl_lines_carry_the_kubeconfig() {
    local lines
    lines="$(grep 'kubectl ' <<<"$1" || true)"
    if [ -z "$lines" ]; then
        fail "no kubectl command was printed: $1"
    fi
    if grep -v -- "$KUBECONFIG_FLAG" <<<"$lines" | grep -q .; then
        fail "printed kubectl without $KUBECONFIG_FLAG: $(grep -v -- "$KUBECONFIG_FLAG" <<<"$lines")"
    fi
}

test_manifest_image_with_a_digest_is_parsed() {
    setup_upgrade
    timescaledb_manifest_image || fail "returned $?"
    assert_eq "$TIMESCALEDB_REPO" timescale/timescaledb
    assert_eq "$TIMESCALEDB_VERSION" 2.30.2
    assert_eq "$TIMESCALEDB_MAJOR" 18
    assert_eq "$TIMESCALEDB_IMAGE" "$TARGET"
}

test_manifest_image_without_a_version_is_refused() {
    setup_upgrade
    manifest timescale/timescaledb:latest-pg18
    if timescaledb_manifest_image 2>/dev/null; then
        fail "accepted latest-pg18"
    fi
}

test_fresh_install_without_a_volume_is_a_no_op() {
    setup_upgrade
    plan_timescaledb_major_upgrade >"$STUB_DIR/out" 2>&1 || fail "returned $?"
    assert_eq "$TIMESCALEDB_UPGRADE_FROM" ""
    assert_eq "$(cat "$STUB_DIR/out")" ""
    assert_not_called "exec "
    assert_not_called "apply "
}

test_unreachable_cluster_refuses() {
    setup_upgrade
    stub stderr "The connection to the server prod:6443 was refused - did you specify the right host or port?"
    stub_rc pvc 1
    if plan_timescaledb_major_upgrade >"$STUB_DIR/out" 2>&1; then
        fail "went ahead without seeing the cluster"
    fi
    assert_contains "$(cat "$STUB_DIR/out")" "The connection to the server prod:6443 was refused"
    assert_contains "$(cat "$STUB_DIR/out")" "could not look for timescaledb's volume"
}

test_matching_majors_are_a_no_op() {
    setup_upgrade
    volume_on_17
    stub pg-version 18
    plan_timescaledb_major_upgrade >"$STUB_DIR/out" 2>&1 || fail "returned $?"
    assert_eq "$TIMESCALEDB_UPGRADE_FROM" ""
    assert_not_called "apply "
}

test_data_newer_than_the_image_refuses() {
    setup_upgrade
    volume_on_17
    stub pg-version 19
    if plan_timescaledb_major_upgrade >"$STUB_DIR/out" 2>&1; then
        fail "went ahead"
    fi
    assert_contains "$(cat "$STUB_DIR/out")" "the timescaledb data is PostgreSQL 19, newer than the PostgreSQL 18 image"
}

test_missing_data_dir_is_a_no_op() {
    setup_upgrade
    volume_on_17
    stub_rc pg-version 1
    stub pg-version ""
    probe_output "" 0 "" 104857600 209715200 ""
    plan_timescaledb_major_upgrade >"$STUB_DIR/out" 2>&1 || fail "returned $?: $(cat "$STUB_DIR/out")"
    assert_eq "$TIMESCALEDB_UPGRADE_FROM" ""
}

test_missing_data_dir_next_to_a_kept_cluster_refuses() {
    setup_upgrade
    volume_on_17
    stub_rc pg-version 1
    stub pg-version ""
    probe_output "" 0 "" 104857600 209715200 "timescaledb-pg17 "
    if plan_timescaledb_major_upgrade >"$STUB_DIR/out" 2>&1; then
        fail "went ahead with no database in timescaledb/"
    fi
    assert_contains "$(cat "$STUB_DIR/out")" "an earlier upgrade was interrupted"
}

test_no_terminal_and_no_yes_refuses_before_changing_anything() {
    setup_upgrade
    volume_on_17
    if plan_timescaledb_major_upgrade >"$STUB_DIR/out" 2>&1; then
        fail "went ahead without consent"
    fi
    assert_contains "$(cat "$STUB_DIR/out")" "there is no terminal to ask on: re-run ./update.sh in one, or pass --yes (or set ASSUME_YES=true)"
    assert_eq "$TIMESCALEDB_UPGRADE_FROM" ""
    assert_not_called "scale "
    assert_not_called "set image"
    assert_not_called "<ConfigMap>"
    assert_not_called "<Job>"
}

test_yes_upgrades_without_asking() {
    setup_upgrade
    volume_on_17
    ASSUME_YES=true plan_timescaledb_major_upgrade >"$STUB_DIR/out" 2>&1 || fail "returned $?: $(cat "$STUB_DIR/out")"
    assert_eq "$TIMESCALEDB_UPGRADE_FROM" 17
    assert_contains "$(cat "$STUB_DIR/out")" "--yes given; upgrading without asking"
}

test_answering_y_upgrades() {
    setup_upgrade
    volume_on_17
    echo y >"$STUB_DIR/tty"
    TIMESCALEDB_UPGRADE_TTY="$STUB_DIR/tty" plan_timescaledb_major_upgrade >"$STUB_DIR/out" 2>&1 || fail "returned $?: $(cat "$STUB_DIR/out")"
    assert_eq "$TIMESCALEDB_UPGRADE_FROM" 17
}

test_answering_anything_else_refuses() {
    setup_upgrade
    volume_on_17
    echo "" >"$STUB_DIR/tty"
    if TIMESCALEDB_UPGRADE_TTY="$STUB_DIR/tty" plan_timescaledb_major_upgrade >"$STUB_DIR/out" 2>&1; then
        fail "went ahead on an empty answer"
    fi
    assert_contains "$(cat "$STUB_DIR/out")" "upgrade declined; nothing was changed"
}

test_old_image_is_the_pinned_one_already_running() {
    planned_upgrade
    assert_eq "$TIMESCALEDB_OLD_IMAGE" "$OLD_PINNED"
}

test_old_image_is_derived_from_the_target_when_another_one_runs() {
    setup_upgrade
    volume_on_17
    stub sts-image timescale/timescaledb:latest-pg17
    ASSUME_YES=true plan_timescaledb_major_upgrade >"$STUB_DIR/out" 2>&1 || fail "returned $?: $(cat "$STUB_DIR/out")"
    assert_eq "$TIMESCALEDB_OLD_IMAGE" timescale/timescaledb:2.30.2-pg17
}

test_old_binary_that_does_not_run_in_the_new_image_refuses() {
    setup_upgrade
    volume_on_17
    probe_output 17 "" "" "" "" "" "Error loading shared library libicui18n.so.74"
    if ASSUME_YES=true plan_timescaledb_major_upgrade >"$STUB_DIR/out" 2>&1; then
        fail "went ahead"
    fi
    assert_contains "$(cat "$STUB_DIR/out")" "does not run in $TARGET"
}

test_existing_kept_cluster_refuses() {
    setup_upgrade
    volume_on_17
    probe_output 17 "" "" "" "" "timescaledb timescaledb-pg17 "
    if ASSUME_YES=true plan_timescaledb_major_upgrade >"$STUB_DIR/out" 2>&1; then
        fail "went ahead"
    fi
    assert_contains "$(cat "$STUB_DIR/out")" "/opt/5stack/timescaledb/timescaledb-pg17 already exists on node-a"
}

test_disk_short_refuses_with_the_shortfall() {
    setup_upgrade
    volume_on_17
    probe_output 17 10485760 "" 12582912 209715200
    if ASSUME_YES=true plan_timescaledb_major_upgrade >"$STUB_DIR/out" 2>&1; then
        fail "went ahead"
    fi
    assert_contains "$(cat "$STUB_DIR/out")" "it needs 22.0 GiB free on node-a:/opt/5stack/timescaledb (the copy, a margin, and the 5% k3s keeps free) and has 12.0 GiB, 10.0 GiB short"
    assert_not_called "scale "
}

test_leftover_staging_dir_counts_as_free_space() {
    setup_upgrade
    volume_on_17
    probe_output 17 10485760 10485760 15728640 209715200 "timescaledb timescaledb-pg18-upgrade "
    ASSUME_YES=true plan_timescaledb_major_upgrade >"$STUB_DIR/out" 2>&1 || fail "returned $?: $(cat "$STUB_DIR/out")"
    assert_contains "$(cat "$STUB_DIR/out")" "disk       25.0 GiB free, the upgrade needs 22.0 GiB"
    assert_contains "$(cat "$STUB_DIR/out")" "10.0 GiB of it held by timescaledb-pg18-upgrade"
}

test_unreadable_free_space_refuses() {
    setup_upgrade
    volume_on_17
    stub probe "major=17
data_kb=10485760
free_kb=
size_kb=209715200
entries=timescaledb 
old_binary=postgres (PostgreSQL) 17.11
"
    if ASSUME_YES=true plan_timescaledb_major_upgrade >"$STUB_DIR/out" 2>&1; then
        fail "went ahead without knowing the free space"
    fi
    assert_contains "$(cat "$STUB_DIR/out")" "could not read the size of /opt/5stack/timescaledb"
}

test_plan_names_the_cluster_it_will_stop() {
    planned_upgrade
    assert_contains "$(cat "$STUB_DIR/plan-output")" "cluster    context stub-context at https://stub.example:6443"
}

test_marker_is_written_before_anything_stops() {
    planned_upgrade
    upgrade_timescaledb_major >"$STUB_DIR/out" 2>&1 || fail "returned $?: $(cat "$STUB_DIR/out")"
    assert_called "create configmap timescaledb-major-upgraded --from-literal=from=17 --from-literal=to=18 --from-literal=node=node-a --from-literal=path=/opt/5stack/timescaledb --from-literal=image=$OLD_PINNED"
    assert_before "create configmap timescaledb-major-upgraded" "scale statefulset timescaledb --replicas=0"
    assert_before "create configmap timescaledb-major-upgraded" "<Job>"
}

test_statefulset_runs_the_old_image_before_the_job_starts() {
    setup_upgrade
    volume_on_17
    stub sts-image timescale/timescaledb:latest-pg17
    ASSUME_YES=true plan_timescaledb_major_upgrade >"$STUB_DIR/out" 2>&1 || fail "plan returned $?"
    upgrade_timescaledb_major >"$STUB_DIR/out" 2>&1 || fail "returned $?: $(cat "$STUB_DIR/out")"
    assert_before "scale statefulset timescaledb --replicas=0" "set image statefulset/timescaledb timescaledb=timescale/timescaledb:2.30.2-pg17"
    assert_before "set image statefulset/timescaledb timescaledb=timescale/timescaledb:2.30.2-pg17" "<Job>"
}

test_job_carries_resource_requests() {
    planned_upgrade
    manifest_yaml="$(timescaledb_upgrade_job_manifest)"
    assert_eq "$(grep -c 'memory: "512Mi"' <<<"$manifest_yaml")" 2
    assert_eq "$(grep -c 'cpu: "500m"' <<<"$manifest_yaml")" 2
}

test_successful_upgrade_removes_the_job() {
    planned_upgrade
    upgrade_timescaledb_major >"$STUB_DIR/out" 2>&1 || fail "returned $?: $(cat "$STUB_DIR/out")"
    assert_contains "$(cat "$STUB_DIR/out")" "data upgraded to PostgreSQL 18"
    assert_called "delete job timescaledb-major-upgrade --ignore-not-found --wait=false"
}

test_running_job_is_waited_for_instead_of_restarted() {
    setup_upgrade
    volume_on_17
    stub job "1|7200"
    stub pvc-users "timescaledb-major-upgrade-x7k2p Running timescaledb-pvc"
    stub marker "17|18|node-a|/opt/5stack/timescaledb|$OLD_PINNED"
    plan_timescaledb_major_upgrade >"$STUB_DIR/out" 2>&1 || fail "plan returned $?: $(cat "$STUB_DIR/out")"
    assert_eq "$TIMESCALEDB_UPGRADE_FROM" 17
    assert_contains "$(cat "$STUB_DIR/out")" "started by an earlier ./update.sh is still running; this run waits for it"
    upgrade_timescaledb_major >"$STUB_DIR/out" 2>&1 || fail "returned $?: $(cat "$STUB_DIR/out")"
    assert_not_called "delete job timescaledb-major-upgrade --ignore-not-found --cascade=foreground"
    assert_not_called "<Job>"
    assert_not_called "create configmap timescaledb-major-upgraded"
    assert_called "logs -f timescaledb-major-upgrade-x7k2p -c upgrade"
}

test_failed_job_leaves_a_recovery_command_with_the_kubeconfig() {
    planned_upgrade
    stub exit-code-upgrade 1
    if upgrade_timescaledb_major >"$STUB_DIR/out" 2>&1; then
        fail "reported success"
    fi
    output="$(cat "$STUB_DIR/out")"
    assert_contains "$output" "the StatefulSet now runs $OLD_PINNED"
    assert_contains "$output" "kubectl $KUBECONFIG_FLAG -n 5stack scale statefulset timescaledb --replicas=1"
    assert_contains "$output" "context stub-context at https://stub.example:6443"
    kubectl_lines_carry_the_kubeconfig "$output"
}

test_job_not_confirmed_gone_names_the_kubeconfig() {
    planned_upgrade
    stub exit-code-upgrade 1
    stub pvc-users "timescaledb-major-upgrade-x7k2p Running timescaledb-pvc"
    if upgrade_timescaledb_major >"$STUB_DIR/out" 2>&1; then
        fail "reported success"
    fi
    kubectl_lines_carry_the_kubeconfig "$(cat "$STUB_DIR/out")"
}

test_volume_still_in_use_names_the_kubeconfig() {
    planned_upgrade
    stub pvc-users "backup-28761 Running timescaledb-pvc"
    if upgrade_timescaledb_major >"$STUB_DIR/out" 2>&1; then
        fail "went ahead with the volume in use"
    fi
    assert_not_called "<Job>"
    kubectl_lines_carry_the_kubeconfig "$(cat "$STUB_DIR/out")"
}

test_job_that_finished_after_all_counts_as_success() {
    planned_upgrade
    stub exit-code-upgrade 1
    probe_output 18
    upgrade_timescaledb_major >"$STUB_DIR/out" 2>&1 || fail "returned $?: $(cat "$STUB_DIR/out")"
    assert_contains "$(cat "$STUB_DIR/out")" "the Job finished the upgrade after all"
}

test_finish_runs_from_the_marker_in_a_later_run() {
    setup_upgrade
    timescaledb_manifest_image
    stub marker "17|18|node-a|/opt/5stack/timescaledb|$OLD_PINNED"
    stub pg-version 18
    probe_output 18 "" "" "" "" "timescaledb timescaledb-pg17 "
    finish_timescaledb_major_upgrade >"$STUB_DIR/out" 2>&1 || fail "returned $?: $(cat "$STUB_DIR/out")"
    output="$(cat "$STUB_DIR/out")"
    assert_called "--all --analyze-in-stages"
    assert_called "rollout restart deployment/hasura deployment/api"
    assert_called "delete configmap timescaledb-major-upgraded timescaledb-major-upgrade"
    assert_contains "$output" "set the image in base/timescaledb/stateful-set.yaml to $OLD_PINNED"
    assert_contains "$output" "rm -rf /opt/5stack/timescaledb/timescaledb-pg17"
    kubectl_lines_carry_the_kubeconfig "$output"
}

test_finish_does_nothing_when_the_upgrade_never_happened() {
    setup_upgrade
    timescaledb_manifest_image
    stub marker "17|18|node-a|/opt/5stack/timescaledb|$OLD_PINNED"
    stub pg-version 17
    finish_timescaledb_major_upgrade >"$STUB_DIR/out" 2>&1 || fail "returned $?"
    assert_eq "$(cat "$STUB_DIR/out")" ""
    assert_not_called "vacuumdb"
    assert_not_called "rollout restart"
}

test_failed_probe_pod_is_refused_at_once() {
    setup_upgrade
    pod_states 'Failed| |{"waiting":{"reason":"PodInitializing"}}| PodInitializing| '
    stub logs "cp: can't stat '/usr/local/bin/postgres': No such file or directory"
    if timescaledb_wait_container timescaledb-volume-probe probe exited 900 >"$STUB_DIR/out" 2>&1; then
        fail "returned success"
    fi
    assert_contains "$(cat "$STUB_DIR/out")" "pod timescaledb-volume-probe failed:"
    assert_contains "$(cat "$STUB_DIR/out")" "can't stat '/usr/local/bin/postgres'"
    assert_eq "$(grep -c ' get pod timescaledb-volume-probe ' "$STUB_DIR/calls")" 1
}

test_unschedulable_probe_pod_is_refused_at_once() {
    setup_upgrade
    pod_states 'Pending|Unschedulable 0/1 nodes are available: 1 node(s) had untolerated taint {node.kubernetes.io/unreachable: }.|{"waiting":{"reason":"PodInitializing"}}| PodInitializing| '
    if timescaledb_wait_container timescaledb-volume-probe probe exited 900 >"$STUB_DIR/out" 2>&1; then
        fail "returned success"
    fi
    assert_contains "$(cat "$STUB_DIR/out")" "cannot be scheduled: 0/1 nodes are available: 1 node(s) had untolerated taint"
    assert_eq "$(grep -c ' get pod timescaledb-volume-probe ' "$STUB_DIR/calls")" 1
}

test_unpullable_image_is_refused_at_once() {
    setup_upgrade
    pod_states 'Pending| |{"waiting":{"reason":"PodInitializing"}}|ImagePullBackOff PodInitializing|Back-off pulling image "timescale/timescaledb:9.9.9-pg17" '
    if timescaledb_wait_container timescaledb-volume-probe probe exited 900 >"$STUB_DIR/out" 2>&1; then
        fail "returned success"
    fi
    assert_contains "$(cat "$STUB_DIR/out")" 'cannot start: ImagePullBackOff PodInitializing: Back-off pulling image "timescale/timescaledb:9.9.9-pg17"'
    assert_eq "$(grep -c ' get pod timescaledb-volume-probe ' "$STUB_DIR/calls")" 1
}

test_slow_start_reports_progress() {
    setup_upgrade
    states=()
    for _ in $(seq 1 20); do
        states+=('Pending| |{"waiting":{"reason":"ContainerCreating"}}| ContainerCreating| ')
    done
    pod_states "${states[@]}" 'Succeeded| |{"terminated":{"exitCode":0}}| | '
    timescaledb_wait_container timescaledb-volume-probe probe exited 900 >"$STUB_DIR/out" 2>&1 || fail "returned $?: $(cat "$STUB_DIR/out")"
    assert_contains "$(cat "$STUB_DIR/out")" "still waiting for timescaledb-volume-probe/probe: ContainerCreating"
}

test_api_errors_are_retried_and_a_gone_pod_is_reported() {
    setup_upgrade
    pod_states API-ERROR API-ERROR GONE
    if timescaledb_wait_container timescaledb-volume-probe probe exited 900 >"$STUB_DIR/out" 2>&1; then
        fail "returned success"
    fi
    assert_contains "$(cat "$STUB_DIR/out")" "pod timescaledb-volume-probe is gone"
    assert_eq "$(grep -c ' get pod timescaledb-volume-probe ' "$STUB_DIR/calls")" 3
}

test_stderr_warnings_do_not_look_like_a_running_job() {
    setup_upgrade
    volume_on_17
    stub stderr "$METRICS_WARNING"
    stub marker "17|18|node-a|/opt/5stack/timescaledb|$OLD_PINNED"
    if plan_timescaledb_major_upgrade >"$STUB_DIR/out" 2>&1; then
        fail "went ahead without consent"
    fi
    assert_eq "$TIMESCALEDB_UPGRADE_ATTACH" ""
    assert_not_contains "$(cat "$STUB_DIR/out")" "still running"
    assert_contains "$(cat "$STUB_DIR/out")" "there is no terminal to ask on"
    assert_not_called "scale "
    assert_not_called "set image"
}

test_stderr_warnings_do_not_stop_a_fresh_install() {
    setup_upgrade
    stub stderr "$METRICS_WARNING"
    plan_timescaledb_major_upgrade >"$STUB_DIR/out" 2>&1 || fail "returned $?: $(cat "$STUB_DIR/out")"
    assert_eq "$TIMESCALEDB_UPGRADE_FROM" ""
    assert_not_contains "$(cat "$STUB_DIR/out")" "Job"
}

test_stderr_warnings_do_not_stop_an_upgrade() {
    setup_upgrade
    volume_on_17
    stub stderr "$METRICS_WARNING"
    ASSUME_YES=true plan_timescaledb_major_upgrade >"$STUB_DIR/out" 2>&1 || fail "returned $?: $(cat "$STUB_DIR/out")"
    assert_eq "$TIMESCALEDB_UPGRADE_FROM" 17
    assert_eq "$TIMESCALEDB_UPGRADE_ATTACH" ""
}

test_unexpected_answer_about_the_job_refuses() {
    setup_upgrade
    volume_on_17
    stub job "error: the server doesn't have a resource type \"job\""
    if ASSUME_YES=true plan_timescaledb_major_upgrade >"$STUB_DIR/out" 2>&1; then
        fail "went ahead"
    fi
    assert_contains "$(cat "$STUB_DIR/out")" "looking for a running upgrade gave an unexpected answer"
    assert_not_called "scale "
}

test_running_job_for_another_major_refuses() {
    setup_upgrade
    manifest "$OLD_PINNED"
    volume_on_17
    stub job "1|7200"
    stub marker "17|18|node-a|/opt/5stack/timescaledb|$OLD_PINNED"
    if plan_timescaledb_major_upgrade >"$STUB_DIR/out" 2>&1; then
        fail "waited for a Job that upgrades to another major"
    fi
    assert_contains "$(cat "$STUB_DIR/out")" "the running timescaledb-major-upgrade Job upgrades to PostgreSQL 18, but this checkout's base/timescaledb/stateful-set.yaml runs PostgreSQL 17"
    assert_not_called "scale "
}

test_old_job_pod_on_the_volume_stops_a_new_job() {
    planned_upgrade
    stub pvc-users "timescaledb-major-upgrade-old12 Running timescaledb-pvc"
    if upgrade_timescaledb_major >"$STUB_DIR/out" 2>&1; then
        fail "started a Job next to the old Job's pod"
    fi
    assert_contains "$(cat "$STUB_DIR/out")" "timescaledb-pvc is still in use: timescaledb-major-upgrade-old12"
    assert_not_called "<Job>"
}

test_finish_waits_when_the_data_cannot_be_read() {
    setup_upgrade
    timescaledb_manifest_image
    stub marker "17|18|node-a|/opt/5stack/timescaledb|$OLD_PINNED"
    stub_rc pg-version 1
    stub exit-code-probe 1
    finish_timescaledb_major_upgrade >"$STUB_DIR/out" 2>&1 || fail "returned $?"
    output="$(cat "$STUB_DIR/out")"
    assert_contains "$output" "could not read the volume; check /opt/5stack/timescaledb/timescaledb-pg17 on node-a"
    assert_not_contains "$output" "next ./update.sh finishes"
    assert_not_contains "$output" "To roll back"
    assert_not_called "rollout restart"
    assert_not_called "vacuumdb"
    assert_not_called "delete configmap timescaledb-major-upgraded"
}

test_finish_while_timescaledb_crash_loops_still_offers_the_rollback() {
    setup_upgrade
    timescaledb_manifest_image
    stub marker "17|18|node-a|/opt/5stack/timescaledb|$OLD_PINNED"
    stub_rc pg-version 1
    probe_output 18 "" "" "" "" "timescaledb timescaledb-pg17 "
    finish_timescaledb_major_upgrade >"$STUB_DIR/out" 2>&1 || fail "returned $?"
    output="$(cat "$STUB_DIR/out")"
    assert_contains "$output" "PostgreSQL is not answering in timescaledb-0, so the statistics were not refreshed and hasura and the api were not restarted."
    assert_contains "$output" "The volume reads PostgreSQL 18, and the PostgreSQL 17 data is kept on node-a in /opt/5stack/timescaledb/timescaledb-pg17."
    assert_contains "$output" "kubectl $KUBECONFIG_FLAG -n 5stack scale statefulset timescaledb --replicas=0"
    assert_contains "$output" "set the image in base/timescaledb/stateful-set.yaml to $OLD_PINNED"
    assert_not_contains "$output" "next ./update.sh finishes"
    kubectl_lines_carry_the_kubeconfig "$output"
    assert_not_called "rollout restart"
    assert_not_called "vacuumdb"
    assert_not_called "delete configmap timescaledb-major-upgraded"
}

test_finish_stays_quiet_while_down_when_the_upgrade_never_happened() {
    setup_upgrade
    timescaledb_manifest_image
    stub marker "17|18|node-a|/opt/5stack/timescaledb|$OLD_PINNED"
    stub_rc pg-version 1
    probe_output 17
    finish_timescaledb_major_upgrade >"$STUB_DIR/out" 2>&1 || fail "returned $?"
    assert_eq "$(cat "$STUB_DIR/out")" ""
    assert_not_called "rollout restart"
}

test_finish_prints_no_rollback_without_the_kept_copy() {
    setup_upgrade
    timescaledb_manifest_image
    stub marker "17|18|node-a|/opt/5stack/timescaledb|$OLD_PINNED"
    stub pg-version 18
    probe_output 18 "" "" "" "" "timescaledb "
    finish_timescaledb_major_upgrade >"$STUB_DIR/out" 2>&1 || fail "returned $?"
    output="$(cat "$STUB_DIR/out")"
    assert_contains "$output" "has no PostgreSQL 17 copy next to a PostgreSQL 18 database; there is nothing to roll back to"
    assert_not_contains "$output" "To roll back"
    assert_not_contains "$output" "rm -rf"
}

test_dev_upgrade_clears_the_marker_it_cannot_finish() {
    planned_upgrade
    upgrade_timescaledb_major >"$STUB_DIR/out" 2>&1 || fail "returned $?: $(cat "$STUB_DIR/out")"
    forget_timescaledb_major_upgrade >"$STUB_DIR/out" 2>&1 || fail "returned $?"
    assert_called "delete configmap timescaledb-major-upgraded timescaledb-major-upgrade --ignore-not-found"
    assert_contains "$(cat "$STUB_DIR/out")" "The PostgreSQL 17 copy stays on node-a in /opt/5stack/timescaledb/timescaledb-pg17"
    grep -q '^forget_timescaledb_major_upgrade$' "$TEST_ROOT/dev.sh" || fail "dev.sh does not call forget_timescaledb_major_upgrade"
}

run_tests
