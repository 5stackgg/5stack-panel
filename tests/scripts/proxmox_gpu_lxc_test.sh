#!/bin/bash

# shellcheck source=tests/scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

load() {
    # shellcheck source=gpu-node/proxmox-gpu-lxc.sh
    PROXMOX_GPU_LXC_LIB=1 source "$TEST_ROOT/gpu-node/proxmox-gpu-lxc.sh"
    # The script has its own fail(); the asserts need the one that exits.
    # shellcheck source=tests/scripts/lib.sh
    source "$TEST_ROOT/tests/scripts/lib.sh"
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
    assert_eq "$(size_gb 512M)" "0"
    assert_eq "$(size_gb "")" ""
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

run_tests
