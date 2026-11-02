#!/bin/bash

# shellcheck source=tests/scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

load() {
    # shellcheck source=gpu-node/proxmox-gpu-lxc.sh
    PROXMOX_GPU_LXC_LIB=1 source "$TEST_ROOT/gpu-node/proxmox-gpu-lxc.sh"
    # The script has its own fail(); the asserts need the one that exits.
    SCRIPT_FAIL=$(declare -f fail)
    # shellcheck source=tests/scripts/lib.sh
    source "$TEST_ROOT/tests/scripts/lib.sh"
}

# script FUNCTION ARGS...
# Runs one of the script's functions with the script's own fail(), which
# records a [FAIL] line instead of ending the test.
script() {
    (
        eval "$SCRIPT_FAIL"
        "$@"
    )
}

write_conf() {
    cat >"$WORK_DIR/100.conf" <<'CONF'
arch: amd64
cores: 8
features: keyctl=1
hostname: gpu-node
rootfs: local-lvm:vm-100-disk-0,size=128G
unprivileged: 0

[before-k3s]
arch: amd64
rootfs: local-lvm:vm-100-disk-0,size=32G
unprivileged: 1
CONF
}

test_conf_value_reads_the_container_not_its_snapshots() {
    load
    write_conf
    assert_eq "$(conf_value "$WORK_DIR/100.conf" rootfs)" "local-lvm:vm-100-disk-0,size=128G"
    assert_eq "$(conf_value "$WORK_DIR/100.conf" unprivileged)" "0"
    assert_eq "$(conf_value "$WORK_DIR/100.conf" nesting)" ""
}

test_size_gb_reads_proxmox_disk_sizes() {
    load
    assert_eq "$(size_gb 128G)" "128"
    assert_eq "$(size_gb 2T)" "2048"
    assert_eq "$(size_gb 131072M)" "128"
    assert_eq "$(size_gb 512M)" "0"
    assert_eq "$(size_gb 134217728K)" "128"
    assert_eq "$(size_gb 137438953472)" "128"
    assert_eq "$(size_gb 8.5G)" "8"
    assert_eq "$(size_gb "")" ""
    assert_eq "$(size_gb abc)" ""
    assert_eq "$(size_gb 1.2.3G)" ""
}

test_nesting_is_added_without_dropping_other_features() {
    load
    assert_eq "$(features_with_nesting "keyctl=1,fuse=1")" "keyctl=1,fuse=1,nesting=1"
    assert_eq "$(features_with_nesting "nesting=0,keyctl=1")" "keyctl=1,nesting=1"
    assert_eq "$(features_with_nesting "")" "nesting=1"
}

test_lxc_lines_go_before_the_first_snapshot() {
    load
    write_conf
    add_lxc_lines "$WORK_DIR/100.conf" "lxc.apparmor.profile: unconfined" "lxc.cap.drop: " || fail "add_lxc_lines failed"
    assert_eq "$(sed -n '6,10p' "$WORK_DIR/100.conf" | sed 's/ *$//')" "unprivileged: 0
lxc.apparmor.profile: unconfined
lxc.cap.drop:

[before-k3s]"
    assert_eq "$(tail -1 "$WORK_DIR/100.conf")" "unprivileged: 1"
}

# Proxmox drops the trailing space of an empty value when it rewrites the file.
test_lxc_lines_are_added_once() {
    load
    write_conf
    add_lxc_lines "$WORK_DIR/100.conf" "lxc.cap.drop: "
    sed -i 's/^lxc.cap.drop: $/lxc.cap.drop:/' "$WORK_DIR/100.conf"
    add_lxc_lines "$WORK_DIR/100.conf" "lxc.cap.drop: " || fail "add_lxc_lines failed"
    assert_eq "$(grep -c '^lxc.cap.drop' "$WORK_DIR/100.conf")" "1"
}

test_a_line_in_a_snapshot_does_not_count() {
    load
    write_conf
    echo "lxc.apparmor.profile: unconfined" >>"$WORK_DIR/100.conf"
    assert_eq "$(missing_lines "$WORK_DIR/100.conf" "lxc.apparmor.profile: unconfined")" "lxc.apparmor.profile: unconfined"
}

test_a_config_without_snapshots_gets_the_lines_at_the_end() {
    load
    printf 'arch: amd64\nunprivileged: 0\n' >"$WORK_DIR/101.conf"
    add_lxc_lines "$WORK_DIR/101.conf" "lxc.mount.auto: proc:rw sys:rw"
    assert_eq "$(cat "$WORK_DIR/101.conf")" "arch: amd64
unprivileged: 0
lxc.mount.auto: proc:rw sys:rw"
}

test_amd_lines_bind_dri_and_kfd() {
    load
    assert_contains "$(lxc_lines amd)" "lxc.mount.entry: /dev/dri dev/dri none bind,optional,create=dir"
    assert_contains "$(lxc_lines amd)" "lxc.mount.entry: /dev/kfd dev/kfd none bind,optional,create=file"
    assert_not_contains "$(lxc_lines amd)" "nvidia"
}

test_nvidia_lines_bind_the_nvidia_devices() {
    load
    assert_contains "$(lxc_lines nvidia)" "lxc.mount.entry: /dev/nvidiactl dev/nvidiactl none bind,optional,create=file"
    assert_contains "$(lxc_lines nvidia)" "lxc.mount.entry: /dev/nvidia-uvm dev/nvidia-uvm none bind,optional,create=file"
    assert_contains "$(lxc_lines nvidia)" "/dev/nvidia0 dev/nvidia0"
    assert_not_contains "$(lxc_lines nvidia)" "/dev/kfd"
}

# An awk that fails only for the rewrite in add_lxc_lines, the one call that
# passes ADD_LINES. MODE is fail (writes half the file, exits 1, as on a full
# disk), empty (writes nothing, exits 0) or short (writes 2 lines, exits 0).
shim_awk() {
    local real
    real=$(command -v awk)
    mkdir -p "$WORK_DIR/bin"
    cat >"$WORK_DIR/bin/awk" <<SHIM
#!/bin/bash
if [ -n "\${ADD_LINES:-}" ]; then
    case "$1" in
        fail) head -c 20 "\${@: -1}"; exit 1 ;;
        empty) exit 0 ;;
        short) head -2 "\${@: -1}"; exit 0 ;;
    esac
fi
exec "$real" "\$@"
SHIM
    chmod +x "$WORK_DIR/bin/awk"
    PATH="$WORK_DIR/bin:$PATH"
}

assert_conf_untouched() {
    assert_eq "$(cat "$WORK_DIR/100.conf")" "$(cat "$WORK_DIR/100.conf.orig")"
    assert_eq "$(find "$WORK_DIR" -maxdepth 1 -name '100.conf.tmp.*' | wc -l)" "0"
}

test_a_failing_rewrite_leaves_the_config_as_it_was() {
    load
    write_conf
    cp "$WORK_DIR/100.conf" "$WORK_DIR/100.conf.orig"
    shim_awk fail
    if add_lxc_lines "$WORK_DIR/100.conf" "lxc.apparmor.profile: unconfined" >"$WORK_DIR/out"; then
        fail "add_lxc_lines succeeded although awk failed"
    fi
    assert_conf_untouched
    assert_contains "$(cat "$WORK_DIR/out")" "is unchanged"
}

test_an_empty_rewrite_is_refused() {
    load
    write_conf
    cp "$WORK_DIR/100.conf" "$WORK_DIR/100.conf.orig"
    shim_awk empty
    if add_lxc_lines "$WORK_DIR/100.conf" "lxc.apparmor.profile: unconfined" >/dev/null; then
        fail "add_lxc_lines took an empty result"
    fi
    assert_conf_untouched
}

test_a_cut_off_rewrite_is_refused() {
    load
    write_conf
    cp "$WORK_DIR/100.conf" "$WORK_DIR/100.conf.orig"
    shim_awk short
    if add_lxc_lines "$WORK_DIR/100.conf" "lxc.apparmor.profile: unconfined" >/dev/null; then
        fail "add_lxc_lines took a cut-off result"
    fi
    assert_conf_untouched
}

# A directory that takes no new file, like a full disk or /etc/pve without
# quorum. Root ignores the permission, so this only runs unprivileged.
test_a_directory_that_takes_no_temp_file_leaves_the_config_as_it_was() {
    load
    [ "$(id -u)" -eq 0 ] && return 0
    mkdir "$WORK_DIR/pve"
    write_conf
    mv "$WORK_DIR/100.conf" "$WORK_DIR/pve/100.conf"
    cp "$WORK_DIR/pve/100.conf" "$WORK_DIR/100.conf.orig"
    chmod 0555 "$WORK_DIR/pve"
    if add_lxc_lines "$WORK_DIR/pve/100.conf" "lxc.apparmor.profile: unconfined" >/dev/null 2>&1; then
        chmod 0755 "$WORK_DIR/pve"
        fail "add_lxc_lines succeeded in a read-only directory"
    fi
    chmod 0755 "$WORK_DIR/pve"
    assert_eq "$(cat "$WORK_DIR/pve/100.conf")" "$(cat "$WORK_DIR/100.conf.orig")"
}

test_the_rewrite_replaces_the_file_by_rename() {
    load
    write_conf
    local inode
    inode=$(stat -c %i "$WORK_DIR/100.conf")
    add_lxc_lines "$WORK_DIR/100.conf" "lxc.apparmor.profile: unconfined" || fail "add_lxc_lines failed"
    [ "$(stat -c %i "$WORK_DIR/100.conf")" != "$inode" ] || fail "the config was rewritten in place"
    assert_eq "$(find "$WORK_DIR" -maxdepth 1 -name '100.conf.tmp.*' | wc -l)" "0"
}

# pct as the container tests see it: STATUS is what pct status says, FREE the
# free GB df reports inside, and every other call is logged.
stub_pct() {
    PCT_STATUS="$1"
    PCT_FREE="${2:-}"
    # shellcheck disable=SC2317 # called by the function under test
    pct() {
        echo "pct $*" >>"$WORK_DIR/pct.log"
        case "$1" in
            status) echo "status: $PCT_STATUS" ;;
            exec)
                printf 'Filesystem 1G-blocks Used Available Use%% Mounted on\n'
                printf '/dev/loop0 200G 10G %sG 10%% /\n' "$PCT_FREE"
                ;;
        esac
    }
    touch "$WORK_DIR/pct.log"
}

test_a_running_container_is_judged_by_its_free_space() {
    load
    CTID=100
    stub_pct running 130
    assert_contains "$(script check_disk "local-lvm:vm-100-disk-0,size=128G")" "[PASS] root disk 128G, 130 GB free"
    stub_pct running 100
    local out
    out=$(script check_disk "local-lvm:vm-100-disk-0,size=128G")
    assert_contains "$out" "[FAIL] root disk 128G has 100 GB free; the node setup needs 120 GB free"
    assert_contains "$out" "pct resize 100 rootfs +40G"
}

test_a_stopped_container_is_judged_by_its_size() {
    load
    CTID=100
    stub_pct stopped
    assert_contains "$(script check_disk "local-lvm:vm-100-disk-0,size=100G")" "[FAIL] root disk is 100G"
    assert_contains "$(script check_disk "local-lvm:vm-100-disk-0,size=120G")" "[WARN] root disk is 120G"
    assert_contains "$(script check_disk "local-lvm:vm-100-disk-0,size=131072M")" "[WARN] root disk is 131072M"
    assert_contains "$(script check_disk "local-lvm:vm-100-disk-0,size=150G")" "[PASS] root disk 150G"
    assert_contains "$(script check_disk "local-lvm:vm-100-disk-0")" "[WARN] could not read the root disk size"
}

write_container() {
    write_conf
    mkdir -p "$WORK_DIR/lxc" "$WORK_DIR/backup"
    sed "s/^unprivileged: 0$/unprivileged: $1/" "$WORK_DIR/100.conf" >"$WORK_DIR/lxc/100.conf"
    cp "$WORK_DIR/lxc/100.conf" "$WORK_DIR/100.conf.orig"
    PVE_LXC_DIR="$WORK_DIR/lxc"
    BACKUP_DIR="$WORK_DIR/backup"
    CTID=100
    VENDOR=amd
    APPLY=true
    # The lock lives under /run/lock; the tests take none.
    # shellcheck disable=SC2317 # called by the function under test
    locked_add_lxc_lines() { add_lxc_lines "$@"; }
}

test_apply_stops_at_an_unprivileged_container() {
    load
    write_container 1
    stub_pct stopped
    local out
    out=$(script check_container)
    assert_contains "$out" "[FAIL] the container is unprivileged"
    assert_contains "$out" "--apply changes nothing in this container until it is privileged"
    assert_eq "$(cat "$WORK_DIR/lxc/100.conf")" "$(cat "$WORK_DIR/100.conf.orig")"
    assert_not_contains "$(cat "$WORK_DIR/pct.log")" "pct set"
    assert_eq "$(find "$WORK_DIR/backup" -type f | wc -l)" "0"
}

test_apply_backs_up_then_adds_the_lines_and_warns_about_proc_rw() {
    load
    write_container 0
    stub_pct stopped
    local out
    out=$(script check_container)
    assert_contains "$out" "[INFO] backed up the container config to $WORK_DIR/backup/5stack-lxc-100.conf."
    assert_contains "$out" "[WARN] lxc.mount.auto: proc:rw lets the kubelet set vm.overcommit_memory=1, kernel.panic=10 and kernel.panic_on_oops=1"
    assert_contains "$out" "reboots 10 seconds after a kernel oops"
    assert_contains "$out" "[FIX ] added 8 LXC lines for k3s and the amd GPU"
    assert_contains "$(cat "$WORK_DIR/pct.log")" "pct set 100 --features keyctl=1,nesting=1"
    assert_eq "$(cat "$WORK_DIR/backup"/5stack-lxc-100.conf.*)" "$(cat "$WORK_DIR/100.conf.orig")"
    local lines
    mapfile -t lines < <(lxc_lines amd)
    assert_eq "$(missing_lines "$WORK_DIR/lxc/100.conf" "${lines[@]}")" ""
}

test_apply_changes_nothing_when_the_backup_fails() {
    load
    write_container 0
    stub_pct stopped
    BACKUP_DIR="$WORK_DIR/no-such-dir"
    local out
    out=$(script check_container)
    assert_contains "$out" "[FAIL] could not back up $WORK_DIR/lxc/100.conf"
    assert_not_contains "$out" "[FIX ]"
    assert_not_contains "$(cat "$WORK_DIR/pct.log")" "pct set"
    assert_eq "$(cat "$WORK_DIR/lxc/100.conf")" "$(cat "$WORK_DIR/100.conf.orig")"
}

test_report_mode_lists_the_lines_and_warns_about_proc_rw() {
    load
    write_container 0
    stub_pct stopped
    APPLY=false
    local out
    out=$(script check_container)
    assert_contains "$out" "[FAIL] 8 LXC lines for k3s and the amd GPU are missing"
    assert_contains "$out" "[WARN] lxc.mount.auto: proc:rw lets the kubelet set"
    assert_eq "$(cat "$WORK_DIR/lxc/100.conf")" "$(cat "$WORK_DIR/100.conf.orig")"
}

test_nomodeset_only_fails_an_amd_host() {
    load
    echo "BOOT_IMAGE=/vmlinuz root=/dev/sda1 nomodeset quiet" >"$WORK_DIR/cmdline"
    PROC_CMDLINE="$WORK_DIR/cmdline"
    assert_contains "$(script check_host_amd)" "[FAIL] the kernel command line has nomodeset"
    VENDOR=nvidia
    assert_not_contains "$(script check_host_gpu)" "nomodeset"
}

# systemctl for the governor unit: a restart either sets every governor or,
# like an already-active unit that enable --now skips, changes nothing.
stub_governor() {
    mkdir -p "$WORK_DIR/cpu/cpu0/cpufreq" "$WORK_DIR/cpu/cpu1/cpufreq" "$WORK_DIR/systemd"
    echo powersave >"$WORK_DIR/cpu/cpu0/cpufreq/scaling_governor"
    echo powersave >"$WORK_DIR/cpu/cpu1/cpufreq/scaling_governor"
    CPU_SYSFS="$WORK_DIR/cpu"
    SYSTEMD_DIR="$WORK_DIR/systemd"
    GOVERNOR_SCRIPT="$WORK_DIR/bin/5stack-cpu-governor.sh"
    RESTART_SETS_GOVERNOR="$1"
    systemctl() {
        echo "systemctl $*" >>"$WORK_DIR/systemctl.log"
        if [ "$1" = restart ] && [ "$RESTART_SETS_GOVERNOR" = true ]; then
            local g
            for g in "$CPU_SYSFS"/cpu*/cpufreq/scaling_governor; do echo performance >"$g"; done
        fi
        return 0
    }
}

test_the_governor_unit_is_the_panels_and_restarted() {
    load
    stub_governor true
    install_governor_unit >"$WORK_DIR/out" || fail "install_governor_unit failed: $(cat "$WORK_DIR/out")"
    assert_contains "$(cat "$WORK_DIR/systemd/5stack-cpu-governor.service")" "ExecStart=$GOVERNOR_SCRIPT"
    # shellcheck disable=SC2016 # the literal line the unit's script holds
    assert_contains "$(cat "$GOVERNOR_SCRIPT")" 'echo performance > "$governor"'
    assert_contains "$(cat "$WORK_DIR/systemctl.log")" "systemctl restart 5stack-cpu-governor.service"
    assert_not_contains "$(cat "$WORK_DIR/systemctl.log")" "--now"
}

test_the_governor_fix_fails_when_the_governor_did_not_change() {
    load
    stub_governor false
    local out
    out=$(script apply_step "CPU governor set to performance" install_governor_unit)
    assert_contains "$out" "[FAIL] could not apply: CPU governor set to performance"
    assert_contains "$out" "is still powersave"
    assert_not_contains "$out" "[FIX ]"
}

run_tests
