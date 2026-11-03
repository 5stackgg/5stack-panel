#!/bin/bash

# shellcheck source=tests/scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

load() {
    # shellcheck source=gpu-node/gpu-node-check.sh
    GPU_NODE_CHECK_LIB=1 source "$TEST_ROOT/gpu-node/gpu-node-check.sh"
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

# fake_amd_gpu NAME integrated|discrete [DRIVER]
# A PCI device directory as sysfs shows an AMD GPU, with a render node, bound
# to DRIVER (amdgpu unless given).
fake_amd_gpu() {
    local dev="$WORK_DIR/pci/$1" driver="${3:-amdgpu}"
    mkdir -p "$dev/drm/renderD128" "$dev/hwmon/hwmon0"
    ln -s "$WORK_DIR/drivers/$driver" "$dev/driver"
    mkdir -p "$WORK_DIR/drivers/$driver"
    if [ "$2" = integrated ]; then
        echo vddnb >"$dev/hwmon/hwmon0/in1_label"
    else
        echo vddgfx >"$dev/hwmon/hwmon0/in1_label"
    fi
    echo "$dev"
}

test_the_script_runs_nothing_when_sourced() {
    local out
    out=$(GPU_NODE_CHECK_LIB=1 bash -c "source '$TEST_ROOT/gpu-node/gpu-node-check.sh'; echo sourced" 2>&1)
    assert_eq "$out" "sourced"
}

test_a_bad_vendor_is_a_usage_error() {
    load
    local status
    (parse_args --vendor intel) 2>/dev/null
    status=$?
    assert_eq "$status" "2"
    (parse_args --bogus) 2>/dev/null
    status=$?
    assert_eq "$status" "2"
}

test_an_apu_is_recognised_by_its_vddnb_rail() {
    load
    local apu card
    apu=$(fake_amd_gpu 0000:c5:00.0 integrated)
    card=$(fake_amd_gpu 0000:03:00.0 discrete)
    amd_integrated "$apu" || fail "the APU was not seen as integrated"
    if amd_integrated "$card"; then
        fail "the discrete card was seen as integrated"
    fi
}

test_an_apu_is_recognised_by_its_gpu_metrics_revision() {
    load
    local dev="$WORK_DIR/pci/0000:c5:00.0"
    mkdir -p "$dev"
    printf '\x00\x00\x02\x00' >"$dev/gpu_metrics"
    amd_integrated "$dev" || fail "gpu_metrics revision 2 was not seen as integrated"
    printf '\x00\x00\x01\x00' >"$dev/gpu_metrics"
    if amd_integrated "$dev"; then
        fail "gpu_metrics revision 1 was seen as integrated"
    fi
}

test_the_integrated_note_depends_on_a_discrete_card() {
    load
    local alone beside
    alone=$(amd_integrated_note 0000:c5:00.0 false)
    beside=$(amd_integrated_note 0000:c5:00.0 true)
    assert_contains "$alone" "tick this node"
    assert_contains "$beside" "leave it unticked"
    assert_contains "$beside" "renders on the discrete card"
    assert_not_contains "$beside" "tick this node"
}

# check_amd reads the kernel log and /proc/cmdline; these keep it on the
# fake devices.
quiet_amd_host() {
    IN_LXC=true
    # shellcheck disable=SC2317 # called by the function under test
    kernel_log() { :; }
    # shellcheck disable=SC2317 # called by the function under test
    cmdline_has() { return 1; }
}

test_an_apu_beside_a_discrete_card_stays_unticked() {
    load
    quiet_amd_host
    AMD_GPUS=("$(fake_amd_gpu 0000:c5:00.0 integrated)" "$(fake_amd_gpu 0000:03:00.0 discrete)")
    local out
    out=$(script check_amd)
    assert_contains "$out" "0000:c5:00.0 is integrated, and this node has a discrete AMD GPU on amdgpu: leave it unticked"
    assert_not_contains "$out" "tick this node"
    assert_not_contains "$out" "runpm"
}

test_an_apu_on_its_own_is_ticked() {
    load
    quiet_amd_host
    AMD_GPUS=("$(fake_amd_gpu 0000:c5:00.0 integrated)")
    local out
    out=$(script check_amd)
    assert_contains "$out" "0000:c5:00.0 is integrated and the only AMD GPU on amdgpu: tick this node"
    assert_not_contains "$out" "runpm"
}

# A card held for VM passthrough renders nothing on this node, so the APU is
# still the GPU to tick.
test_a_discrete_card_on_vfio_pci_does_not_count() {
    load
    quiet_amd_host
    AMD_GPUS=("$(fake_amd_gpu 0000:c5:00.0 integrated)" "$(fake_amd_gpu 0000:03:00.0 discrete vfio-pci)")
    local out
    out=$(script check_amd)
    assert_contains "$out" "[FAIL] 0000:03:00.0 is bound to 'vfio-pci', not amdgpu"
    assert_contains "$out" "0000:c5:00.0 is integrated and the only AMD GPU on amdgpu: tick this node"
    assert_not_contains "$out" "leave it unticked"
}

test_the_nvidia_node_hint_uses_m_for_modeset() {
    load
    local out
    out=$(nvidia_nodes_hint " /dev/nvidia-modeset")
    assert_contains "$out" "'nvidia-modprobe -m'"
    assert_not_contains "$out" "-c0"
    out=$(nvidia_nodes_hint " /dev/nvidiactl /dev/nvidia-uvm /dev/nvidia-modeset /dev/nvidia0")
    assert_contains "$out" "'nvidia-modprobe -c0; nvidia-modprobe -c0 -u; nvidia-modprobe -m'"
    out=$(nvidia_nodes_hint " /dev/nvidia-uvm")
    assert_contains "$out" "'nvidia-modprobe -c0 -u'"
    assert_not_contains "$out" "modprobe -m"
}

test_the_k3s_pin_goes_after_sudo() {
    load
    assert_eq "$(k3s_join_hint v1.36.5+k3s1)" \
        "curl -fsSL https://get.5stack.gg | sudo INSTALL_K3S_VERSION=v1.36.5+k3s1 sh -s -- join --panel-key <the key the panel shows>"
}

test_without_k3s_the_join_hint_has_the_pin() {
    load
    # shellcheck disable=SC2317 # called by the function under test
    command() {
        if [ "$1" = -v ] && [ "$2" = k3s ]; then return 1; fi
        builtin command "$@"
    }
    # shellcheck disable=SC2317 # called by the function under test
    df() { printf 'Filesystem 1G-blocks Used Available Use%% Mounted on\n/dev/root 500G 10G 490G 2%% /\n'; }
    CPU_SYSFS="$WORK_DIR/cpu"
    K3S_VERSION=v1.36.5+k3s1
    local out
    out=$(script check_common)
    assert_contains "$out" "sudo INSTALL_K3S_VERSION=v1.36.5+k3s1 sh -s -- join"
    assert_not_contains "$out" "INSTALL_K3S_VERSION=v1.36.5+k3s1 curl"
}

# ubuntu-drivers on PATH, writing to stdout as the real one does.
shim_ubuntu_drivers() {
    mkdir -p "$WORK_DIR/bin"
    cat >"$WORK_DIR/bin/ubuntu-drivers" <<SHIM
#!/bin/sh
echo "Reading package lists... lots of installer output"
exit $1
SHIM
    chmod +x "$WORK_DIR/bin/ubuntu-drivers"
    PATH="$WORK_DIR/bin:$PATH"
}

test_the_driver_install_still_reports_its_result() {
    load
    shim_ubuntu_drivers 0
    local out
    out=$(script apply_step "installed the recommended NVIDIA driver; reboot, then run this again" install_nvidia_driver)
    assert_eq "$out" "  [FIX ] installed the recommended NVIDIA driver; reboot, then run this again"
}

test_a_failed_driver_install_is_reported() {
    load
    shim_ubuntu_drivers 1
    local out
    out=$(script apply_step "installed the recommended NVIDIA driver; reboot, then run this again" install_nvidia_driver)
    assert_eq "$out" "  [FAIL] could not apply: installed the recommended NVIDIA driver; reboot, then run this again"
}

# check_nvidia on an Ubuntu machine without the NVIDIA module, as --apply
# reaches install_nvidia_driver there.
test_check_nvidia_installs_the_driver_and_reports_it() {
    load
    shim_ubuntu_drivers 0
    IN_LXC=false
    APPLY=true
    OS_ID=ubuntu
    NVIDIA_GPUS=()
    # shellcheck disable=SC2317 # called by the function under test
    nvidia_kernel_version() { :; }
    # shellcheck disable=SC2317 # called by the function under test
    install_nvidia_container_toolkit() { return 0; }
    local out
    out=$(script check_nvidia)
    assert_contains "$out" "[FAIL] the NVIDIA kernel module is not loaded"
    assert_contains "$out" "[FIX ] installed the recommended NVIDIA driver; reboot, then run this again"
    assert_not_contains "$out" "Reading package lists"
}

test_proc_sys_is_probed_under_vm() {
    load
    assert_eq "$PROC_SYS_PROBE" "/proc/sys/vm/overcommit_memory"
}

test_a_read_only_proc_sys_vm_fails_the_lxc_check() {
    [ "$(id -u)" -eq 0 ] && return 0
    load
    echo 0 >"$WORK_DIR/overcommit_memory"
    chmod 0444 "$WORK_DIR/overcommit_memory"
    PROC_SYS_PROBE="$WORK_DIR/overcommit_memory"
    local out
    out=$(script check_lxc)
    assert_contains "$out" "[FAIL] /proc/sys/vm is read-only"
    assert_not_contains "$out" "[PASS] /proc/sys/vm writable"

    chmod 0644 "$WORK_DIR/overcommit_memory"
    out=$(script check_lxc)
    assert_contains "$out" "[PASS] /proc/sys/vm writable"
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
    CPUFREQUTILS_DEFAULT="$WORK_DIR/cpufrequtils"
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
    [ -e "$WORK_DIR/systemd/5stack-cpu-governor.service.5stack-new" ] && fail "the temp unit was left behind"
    return 0
}

# The panel's tuning points cpufrequtils's boot script at performance too.
test_the_governor_fix_sets_cpufrequtils_to_performance() {
    load
    stub_governor true
    printf 'ENABLE="true"\nGOVERNOR="ondemand"\nMAX_SPEED="0"\n' >"$CPUFREQUTILS_DEFAULT"
    install_governor_unit >"$WORK_DIR/out" || fail "install_governor_unit failed: $(cat "$WORK_DIR/out")"
    assert_eq "$(cat "$CPUFREQUTILS_DEFAULT")" 'ENABLE="true"
MAX_SPEED="0"
GOVERNOR="performance"'
    [ -e "$CPUFREQUTILS_DEFAULT.5stack-new" ] && fail "the temp file was left behind"
    return 0
}

test_the_governor_fix_adds_no_cpufrequtils_settings() {
    load
    stub_governor true
    install_governor_unit >"$WORK_DIR/out" || fail "install_governor_unit failed: $(cat "$WORK_DIR/out")"
    [ -e "$CPUFREQUTILS_DEFAULT" ] && fail "cpufrequtils settings were created"
    return 0
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
