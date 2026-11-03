#!/bin/bash

# Checks that a GPU node can run 5stack render pods. Run it as root on the node,
# before the panel's join command and again after it. See README.md.
#
#   gpu-node-check.sh [--apply] [--vendor nvidia|amd] [--k3s-version v1.36.5+k3s1]

APPLY=false
VENDOR=""
K3S_VERSION=""
IN_LXC=false
ON_HOST=""
NVIDIA_GPUS=()
AMD_GPUS=()
SYSTEMD_DIR="${SYSTEMD_DIR:-/etc/systemd/system}"
GOVERNOR_SCRIPT="${GOVERNOR_SCRIPT:-/usr/local/bin/5stack-cpu-governor.sh}"
CPU_SYSFS="${CPU_SYSFS:-/sys/devices/system/cpu}"
CPUFREQUTILS_DEFAULT="${CPUFREQUTILS_DEFAULT:-/etc/default/cpufrequtils}"
# LXC's proc:mixed leaves /proc/sys/net writable but not /proc/sys/vm, and
# the kubelet writes to /proc/sys/vm, so that is what is tested.
PROC_SYS_PROBE="${PROC_SYS_PROBE:-/proc/sys/vm/overcommit_memory}"

usage() {
    echo "usage: gpu-node-check.sh [--apply] [--vendor nvidia|amd] [--k3s-version v1.36.5+k3s1]" >&2
    exit 2
}

parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --apply) APPLY=true ;;
            --vendor)
                VENDOR="$2"
                shift
                ;;
            --k3s-version)
                K3S_VERSION="$2"
                shift
                ;;
            -h | --help) usage ;;
            *)
                echo "unknown option: $1" >&2
                usage
                ;;
        esac
        shift
    done

    case "$VENDOR" in
        "" | nvidia | amd) ;;
        *)
            echo "--vendor must be nvidia or amd" >&2
            exit 2
            ;;
    esac
}

if [ -t 1 ]; then
    C_RESET=$'\033[0m' C_STEP=$'\033[1;36m' C_OK=$'\033[0;32m' C_WARN=$'\033[1;33m' C_ERR=$'\033[0;31m'
else
    C_RESET='' C_STEP='' C_OK='' C_WARN='' C_ERR=''
fi

FAILS=0
WARNS=0
step() { echo; echo "${C_STEP}==> $1${C_RESET}"; }
pass() { echo "${C_OK}  [PASS] $1${C_RESET}"; }
info() { echo "  [INFO] $1"; }
warn() { WARNS=$((WARNS + 1)); echo "${C_WARN}  [WARN] $1${C_RESET}"; }
fail() { FAILS=$((FAILS + 1)); echo "${C_ERR}  [FAIL] $1${C_RESET}"; }
fixed() { echo "${C_OK}  [FIX ] $1${C_RESET}"; }
hint() { echo "         $1"; }

apt_has() {
    command -v apt-cache >/dev/null 2>&1 &&
        apt-cache policy "$1" 2>/dev/null | grep -q 'Candidate: [^(]'
}

pkg_installed() {
    dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q 'install ok installed'
}

# Package installs never prompt: under "curl ... | bash" a prompt would read
# the rest of this script as its answer.
APT_UPDATED=false
apt_install() {
    if [ "$APT_UPDATED" = false ]; then
        DEBIAN_FRONTEND=noninteractive apt-get update </dev/null >/dev/null || return 1
        APT_UPDATED=true
    fi
    DEBIAN_FRONTEND=noninteractive apt-get install -y -o Dpkg::Options::=--force-confold "$@" </dev/null >/dev/null
}

apply_step() {
    local description="$1"
    shift
    if "$@"; then
        fixed "$description"
    else
        fail "could not apply: $description"
        return 1
    fi
}

kernel_log() {
    dmesg 2>/dev/null || journalctl -k -b 0 --no-pager 2>/dev/null
}

check_machine() {
    local container vm dev class

    step "Machine"

    container=$(systemd-detect-virt -c 2>/dev/null || true)
    vm=$(systemd-detect-virt -v 2>/dev/null || true)
    case "$container" in
        lxc*)
            IN_LXC=true
            ON_HOST=" on the host"
            ;;
        none | "") ;;
        *)
            fail "running in a $container container; only bare metal, VMs and LXC are supported"
            ;;
    esac

    if [ "$IN_LXC" = true ]; then
        info "LXC container on kernel $(uname -r); the host owns the GPU driver, firmware and CPU governor"
    elif [ -n "$vm" ] && [ "$vm" != none ]; then
        info "$vm VM on kernel $(uname -r); the GPU must be passed through to it"
    else
        info "bare metal, kernel $(uname -r)"
    fi
    info "$OS_ID $OS_VERSION"

    for dev in /sys/bus/pci/devices/*; do
        class=$(cat "$dev/class" 2>/dev/null)
        case "$class" in
            0x0300* | 0x0302* | 0x0380*) ;;
            *) continue ;;
        esac
        case "$(cat "$dev/vendor" 2>/dev/null)" in
            0x10de) NVIDIA_GPUS+=("$dev") ;;
            0x1002) AMD_GPUS+=("$dev") ;;
        esac
    done

    if [ -z "$VENDOR" ]; then
        if [ ${#NVIDIA_GPUS[@]} -gt 0 ] && [ ${#AMD_GPUS[@]} -gt 0 ]; then
            fail "found both NVIDIA and AMD GPUs; pass --vendor nvidia or --vendor amd"
            VENDOR=none
        elif [ ${#NVIDIA_GPUS[@]} -gt 0 ]; then
            VENDOR=nvidia
        elif [ ${#AMD_GPUS[@]} -gt 0 ]; then
            VENDOR=amd
        else
            fail "no NVIDIA or AMD GPU found on the PCI bus"
            VENDOR=none
        fi
    fi
}

driver_of() {
    basename "$(readlink "$1/driver" 2>/dev/null)" 2>/dev/null
}

cmdline_has() {
    tr ' ' '\n' </proc/cmdline | grep -qx "$1"
}

# Mirrors the connector: the vddnb voltage rail and gpu_metrics revision 2+
# only exist on APUs.
amd_integrated() {
    local dev="$1" hwmon rev
    for hwmon in "$dev"/hwmon/hwmon*; do
        [ "$(cat "$hwmon/in1_label" 2>/dev/null)" = vddnb ] && return 0
    done
    rev=$(od -An -tu1 -j2 -N1 "$dev/gpu_metrics" 2>/dev/null | tr -d ' ')
    [ -n "$rev" ] && [ "$rev" -ge 2 ]
}

amd_integrated_note() {
    if [ "$2" = true ]; then
        echo "$1 is integrated, and this node has a discrete AMD GPU on amdgpu: leave it unticked in setup-gpu-nodes.sh's integrated list so it renders on the discrete card"
    else
        echo "$1 is integrated and the only AMD GPU on amdgpu: tick this node in setup-gpu-nodes.sh's integrated list (5stack-gpu-integrated=true)"
    fi
}

check_amd() {
    local dev pci driver node render integrated bar0 size level has_discrete=false

    step "AMD GPU"

    # A card on vfio-pci or without a driver renders nothing here, so it does
    # not count as a discrete GPU.
    for dev in "${AMD_GPUS[@]}"; do
        [ "$(driver_of "$dev")" = amdgpu ] || continue
        amd_integrated "$dev" || has_discrete=true
    done

    if [ -d /sys/module/amdgpu ]; then
        pass "amdgpu driver loaded"
    else
        fail "amdgpu driver not loaded"
        [ "$IN_LXC" = true ] && hint "Load it on the host; a container cannot."
    fi

    for dev in "${AMD_GPUS[@]}"; do
        pci=$(basename "$dev")
        driver=$(driver_of "$dev")
        integrated=false
        amd_integrated "$dev" && integrated=true

        if [ "$driver" != amdgpu ]; then
            fail "$pci is bound to '${driver:-nothing}', not amdgpu"
            [ "$driver" = vfio-pci ] && hint "It is reserved for VM passthrough; an LXC or this host cannot use it."
            continue
        fi

        render=""
        for node in "$dev"/drm/renderD*; do
            [ -e "$node" ] && render=$(basename "$node") && break
        done
        if [ -z "$render" ]; then
            fail "$pci has no render node"
            continue
        fi
        if [ -c "/dev/dri/$render" ]; then
            pass "$pci: /dev/dri/$render ($([ "$integrated" = true ] && echo integrated || echo discrete))"
        else
            fail "$pci: /dev/dri/$render is missing"
            [ "$IN_LXC" = true ] && hint "Bind /dev/dri into the container (proxmox-gpu-lxc.sh does)."
        fi

        if [ "$integrated" = true ]; then
            info "$(amd_integrated_note "$pci" "$has_discrete")"
        else
            # BAR0 is the CPU's window into VRAM. 256 MiB means Above 4G
            # decoding (and Resizable BAR) is off in the firmware.
            bar0=$(head -1 "$dev/resource" 2>/dev/null)
            size=$(( $(echo "$bar0" | awk '{print $2}') - $(echo "$bar0" | awk '{print $1}') + 1 ))
            if [ "$size" -gt 0 ] && [ "$size" -le $((256 * 1024 * 1024)) ]; then
                warn "$pci: VRAM window is $((size / 1024 / 1024)) MiB; enable Above 4G decoding and Resizable BAR in the firmware"
            fi
        fi

        level=$(cat "$dev/power_dpm_force_performance_level" 2>/dev/null)
        if [ -n "$level" ] && [ "$level" != auto ]; then
            warn "$pci: power_dpm_force_performance_level is '$level'; 5stack expects 'auto' and never changes it"
        fi
    done

    for arg in nomodeset amdgpu.modeset=0 amdgpu.dpm=0; do
        if cmdline_has "$arg"; then
            fail "kernel command line has $arg, which disables what the streamer needs; remove it"
        fi
    done

    if [ -e /dev/kfd ]; then
        info "/dev/kfd present (not needed for rendering)"
    fi

    local log
    log=$(kernel_log)
    if [ ! -d /sys/module/amdgpu ]; then
        :
    elif [ -z "$log" ]; then
        info "kernel log not readable here; check firmware errors with 'dmesg | grep amdgpu' on the host"
    elif echo "$log" | grep -q "Direct firmware load for amdgpu/.* failed"; then
        fail "amdgpu firmware is missing: $(echo "$log" | grep -o "amdgpu/[^ ]*" | head -1)"
        hint "Install the AMD firmware package$ON_HOST, then reboot it."
    elif echo "$log" | grep -q "amdgpu.*Fatal error during GPU init"; then
        fail "amdgpu failed to start the GPU this boot; see 'dmesg | grep amdgpu'"
    else
        pass "no amdgpu firmware or init errors this boot"
        if echo "$log" | grep -qE "amdgpu.*(GPU reset begin|ring .* timeout)"; then
            warn "the GPU has reset this boot; see 'dmesg | grep -E \"reset|timeout\"'"
        fi
    fi

    if [ "$IN_LXC" = false ] && command -v apt-cache >/dev/null 2>&1; then
        local firmware=""
        for candidate in linux-firmware-amd-graphics firmware-amd-graphics pve-firmware linux-firmware; do
            if pkg_installed "$candidate"; then
                firmware="$candidate"
                break
            fi
        done
        if [ -n "$firmware" ]; then
            pass "firmware package $firmware installed"
        else
            for candidate in linux-firmware-amd-graphics firmware-amd-graphics; do
                if apt_has "$candidate"; then
                    if [ "$APPLY" = true ]; then
                        apply_step "installed $candidate; reboot to load it" apt_install "$candidate"
                    else
                        warn "$candidate is not installed (--apply installs it)"
                    fi
                    break
                fi
            done
        fi
    fi

    if [ "$IN_LXC" = false ] && [ "$OS_ID" = ubuntu ] && [ "$OS_VERSION" = "24.04" ]; then
        case "$(uname -r)" in
            6.8.*) warn "Ubuntu 24.04's original 6.8 kernel predates recent Radeons; install the HWE kernel (linux-generic-hwe-24.04)" ;;
        esac
    fi

    if [ "$IN_LXC" = false ]; then
        local dm
        for dm in gdm gdm3 sddm lightdm display-manager; do
            if systemctl is-active --quiet "$dm" 2>/dev/null; then
                warn "$dm is running; a desktop session holds the GPU's display, so a headless install is recommended"
                break
            fi
        done
    fi
}

# 595.99.02 from "NVRM version: NVIDIA UNIX Open Kernel Module for x86_64  595.99.02  Release Build ..."
nvidia_kernel_version() {
    head -1 /proc/driver/nvidia/version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1
}

install_nvidia_userspace() {
    # The container shares the host's kernel module, so it needs the same
    # version's libraries and nothing else. The .run installer is the one
    # source that has every version, matching the host whatever installed it.
    local version="$1" run opt
    run="/root/NVIDIA-Linux-x86_64-$version.run"
    if [ ! -f "$run" ]; then
        command -v curl >/dev/null 2>&1 || apt_install curl || {
            fail "could not install curl to download the NVIDIA $version installer"
            return 1
        }
        # Download beside the target, so an interrupted download is never
        # mistaken for the installer on the next run.
        if ! curl -fsSL -o "$run.part" "https://us.download.nvidia.com/XFree86/Linux-x86_64/$version/NVIDIA-Linux-x86_64-$version.run" </dev/null; then
            fail "could not download the NVIDIA $version installer"
            rm -f "$run.part"
            return 1
        fi
        mv "$run.part" "$run"
    fi
    opt=$(sh "$run" --advanced-options </dev/null 2>/dev/null | grep -oE -- '--no-kernel-modules?' | head -1)
    if sh "$run" --silent "${opt:---no-kernel-module}" </dev/null >/dev/null 2>&1; then
        fixed "installed the NVIDIA $version libraries"
    else
        fail "the NVIDIA $version installer failed; see /var/log/nvidia-installer.log"
        return 1
    fi
}

# The installer's output goes to /dev/null here, not on the apply_step call,
# which would swallow apply_step's own result line with it.
install_nvidia_driver() {
    DEBIAN_FRONTEND=noninteractive ubuntu-drivers install </dev/null >/dev/null
}

# -c0 makes nvidia0 and nvidiactl, -c0 -u the uvm nodes, and only -m makes nvidia-modeset.
nvidia_nodes_hint() {
    local missing="$1" commands=()
    case "$missing" in *"/dev/nvidia0"* | *"/dev/nvidiactl"*) commands+=("nvidia-modprobe -c0") ;; esac
    case "$missing" in *"/dev/nvidia-uvm"*) commands+=("nvidia-modprobe -c0 -u") ;; esac
    case "$missing" in *"/dev/nvidia-modeset"*) commands+=("nvidia-modprobe -m") ;; esac
    local joined="" command
    for command in "${commands[@]}"; do
        joined+="${joined:+; }$command"
    done
    echo "Create them with '$joined'. They are gone after a reboot, so run that at boot too (a oneshot systemd unit)."
}

install_nvidia_container_toolkit() {
    if [ "$OS_ID" != ubuntu ] && [ "$OS_ID" != debian ]; then
        fail "install nvidia-container-toolkit by hand on $OS_ID: https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html"
        return 1
    fi
    apt_install curl gnupg ca-certificates &&
        curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey </dev/null |
        gpg --dearmor --yes -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg &&
        curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list </dev/null |
        sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
            >/etc/apt/sources.list.d/nvidia-container-toolkit.list || return 1
    APT_UPDATED=false
    apt_install nvidia-container-toolkit
}

check_nvidia() {
    local dev pci driver kernel_version smi_version missing node

    step "NVIDIA GPU"

    for dev in "${NVIDIA_GPUS[@]}"; do
        pci=$(basename "$dev")
        driver=$(driver_of "$dev")
        case "$driver" in
            nvidia) pass "$pci bound to nvidia" ;;
            nouveau)
                fail "$pci is driven by nouveau; install the NVIDIA driver$ON_HOST"
                ;;
            vfio-pci)
                fail "$pci is reserved for VM passthrough (vfio-pci); an LXC or this host cannot use it"
                ;;
            *)
                fail "$pci has no driver"
                if [ "$IN_LXC" = false ] && mokutil --sb-state 2>/dev/null | grep -q enabled; then
                    hint "Secure Boot is on: use the signed prebuilt modules ('ubuntu-drivers install') or enroll the DKMS key with mokutil."
                fi
                ;;
        esac
    done

    kernel_version=$(nvidia_kernel_version)
    if [ -z "$kernel_version" ]; then
        fail "the NVIDIA kernel module is not loaded"
        if [ "$IN_LXC" = false ] && [ "$APPLY" = true ] && [ "$OS_ID" = ubuntu ] && command -v ubuntu-drivers >/dev/null 2>&1; then
            apply_step "installed the recommended NVIDIA driver; reboot, then run this again" install_nvidia_driver
        elif [ "$IN_LXC" = false ] && [ "$OS_ID" = ubuntu ]; then
            hint "Install it with 'ubuntu-drivers install' (--apply does), then reboot."
        fi
    else
        pass "kernel module $kernel_version"
    fi

    missing=""
    for node in /dev/nvidiactl /dev/nvidia-uvm /dev/nvidia-modeset; do
        [ -c "$node" ] || missing+=" $node"
    done
    ls /dev/nvidia[0-9]* >/dev/null 2>&1 || missing+=" /dev/nvidia0"
    if [ -z "$missing" ]; then
        pass "device nodes present"
    else
        fail "missing device nodes:$missing"
        if [ "$IN_LXC" = true ]; then
            hint "Bind them into the container (proxmox-gpu-lxc.sh does), and create them on the host first."
        else
            hint "$(nvidia_nodes_hint "$missing")"
        fi
    fi

    if [ -n "$kernel_version" ]; then
        smi_version=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1)
        if [ "$smi_version" = "$kernel_version" ]; then
            pass "nvidia-smi sees $(nvidia-smi --query-gpu=name --format=csv,noheader | head -1), driver $smi_version"
        elif [ "$IN_LXC" = true ]; then
            if [ "$APPLY" = true ]; then
                install_nvidia_userspace "$kernel_version"
            else
                fail "the container's NVIDIA libraries ($( [ -n "$smi_version" ] && echo "$smi_version" || echo none)) do not match the host's module $kernel_version (--apply installs $kernel_version)"
            fi
        else
            fail "nvidia-smi does not work: $(nvidia-smi 2>&1 | head -1)"
            hint "A library/module version mismatch clears after a reboot."
        fi
    fi

    if command -v nvidia-container-runtime >/dev/null 2>&1; then
        pass "nvidia-container-toolkit installed"
    elif [ "$APPLY" = true ]; then
        apply_step "installed nvidia-container-toolkit" install_nvidia_container_toolkit
    else
        fail "nvidia-container-toolkit is not installed (--apply installs it)"
    fi

    if command -v nvidia-container-cli >/dev/null 2>&1; then
        if nvidia-container-cli info >/dev/null 2>&1; then
            pass "nvidia-container-cli reaches the GPU"
        else
            fail "nvidia-container-cli cannot reach the GPU: $(nvidia-container-cli info 2>&1 | tail -1)"
        fi
    fi

    # k3s writes an nvidia runtime into its containerd config only when it
    # finds nvidia-container-runtime at start, so a toolkit installed after
    # the join needs a k3s restart.
    local containerd=/var/lib/rancher/k3s/agent/etc/containerd/config.toml service
    service=$(k3s_service)
    if [ -f "$containerd" ]; then
        if grep -q nvidia-container-runtime "$containerd"; then
            pass "k3s containerd has the nvidia runtime"
        elif [ "$APPLY" = true ] && command -v nvidia-container-runtime >/dev/null 2>&1; then
            apply_step "restarted $service to pick up the nvidia runtime" systemctl restart "$service"
        else
            fail "k3s containerd has no nvidia runtime; restart $service after installing the toolkit"
        fi
    fi
}

k3s_service() {
    if systemctl is-enabled --quiet k3s 2>/dev/null; then
        echo k3s
    else
        echo k3s-agent
    fi
}

# Same script and unit as the panel's CPU governor tuning, so a node never has two.
# cpufrequtils's boot script would otherwise set its own governor.
install_governor_unit() {
    local unit="$SYSTEMD_DIR/5stack-cpu-governor.service" governor
    mkdir -p "${GOVERNOR_SCRIPT%/*}" || return 1
    cat >"$GOVERNOR_SCRIPT.5stack-new" <<'SCRIPT' || return 1
#!/bin/sh
for governor in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
  echo performance > "$governor"
done
SCRIPT
    chmod 0755 "$GOVERNOR_SCRIPT.5stack-new" && mv -f "$GOVERNOR_SCRIPT.5stack-new" "$GOVERNOR_SCRIPT" || return 1
    cat >"$unit.5stack-new" <<UNIT || return 1
[Unit]
Description=Set the CPU governor to performance for game servers

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$GOVERNOR_SCRIPT

[Install]
WantedBy=multi-user.target
UNIT
    mv -f "$unit.5stack-new" "$unit" || return 1
    if [ -f "$CPUFREQUTILS_DEFAULT" ]; then
        { grep -v '^GOVERNOR=' "$CPUFREQUTILS_DEFAULT" || true; echo 'GOVERNOR="performance"'; } >"$CPUFREQUTILS_DEFAULT.5stack-new" &&
            mv -f "$CPUFREQUTILS_DEFAULT.5stack-new" "$CPUFREQUTILS_DEFAULT" || return 1
    fi
    # restart, not enable --now, which leaves an active unit alone.
    systemctl daemon-reload &&
        systemctl enable 5stack-cpu-governor.service >/dev/null 2>&1 &&
        systemctl restart 5stack-cpu-governor.service >/dev/null 2>&1 || return 1
    for governor in "$CPU_SYSFS"/cpu*/cpufreq/scaling_governor; do
        [ -f "$governor" ] || continue
        if [ "$(cat "$governor")" != performance ]; then
            hint "$governor is still $(cat "$governor")"
            return 1
        fi
    done
}

# sudo drops exported variables, so the pin goes after it.
k3s_join_hint() {
    echo "curl -fsSL https://get.5stack.gg | sudo INSTALL_K3S_VERSION=$1 sh -s -- join --panel-key <the key the panel shows>"
}

check_common() {
    step "Node"

    local tool
    for tool in curl jq; do
        if command -v "$tool" >/dev/null 2>&1; then
            pass "$tool installed"
        elif [ "$APPLY" = true ] && command -v apt-get >/dev/null 2>&1; then
            apply_step "installed $tool" apt_install "$tool"
        else
            fail "$tool is not installed (--apply installs it); the node setup command needs it"
        fi
    done

    local free_gb
    free_gb=$(df -BG / | awk 'NR==2 {print $4}' | tr -d 'G')
    if [ "${free_gb:-0}" -ge 120 ]; then
        pass "${free_gb} GB free on /"
    else
        warn "${free_gb} GB free on /; the node setup asks for 120 GB on a fresh node"
    fi

    local governor
    governor=$(cat "$CPU_SYSFS/cpu0/cpufreq/scaling_governor" 2>/dev/null)
    if [ -z "$governor" ]; then
        info "no CPU frequency scaling exposed"
    elif [ "$governor" = performance ]; then
        pass "CPU governor is performance"
    elif [ "$IN_LXC" = true ]; then
        warn "CPU governor is '$governor'; set it to performance on the host (proxmox-gpu-lxc.sh --apply does)"
    elif [ "$APPLY" = true ]; then
        apply_step "CPU governor set to performance, at every boot (5stack-cpu-governor.service)" install_governor_unit
    else
        warn "CPU governor is '$governor'; render pods drop frames on a ramping CPU (--apply sets performance at every boot)"
    fi

    if command -v k3s >/dev/null 2>&1; then
        local installed service
        installed=$(k3s --version 2>/dev/null | awk 'NR==1 {print $3}')
        service=$(k3s_service)
        if [ -n "$K3S_VERSION" ] && [ "$installed" != "$K3S_VERSION" ] &&
            [ "$(printf '%s\n' "$installed" "$K3S_VERSION" | sort -V | tail -1)" = "$installed" ]; then
            warn "k3s $installed is newer than the panel's $K3S_VERSION; a kubelet newer than its API server is unsupported"
            hint "Re-join with the version pinned: $(k3s_join_hint "$K3S_VERSION")"
        else
            pass "k3s $installed installed"
        fi
        if systemctl is-active --quiet "$service" 2>/dev/null; then
            pass "$service running"
        else
            fail "$service is not running; see 'journalctl -u $service -n 50'"
        fi
    else
        info "k3s not installed yet. The join command installs the latest k3s; to match the panel, join with the version pinned:"
        hint "$(k3s_join_hint "${K3S_VERSION:-<the Server Version from kubectl version on the panel>}")"
    fi
}

check_lxc() {
    step "LXC container"

    if awk '$1 == 0 && $2 == 0 { found = 1 } END { exit !found }' /proc/self/uid_map; then
        pass "privileged container"
    else
        fail "unprivileged container; k3s needs a privileged one"
    fi

    local profile
    profile=$(cat /proc/self/attr/current 2>/dev/null)
    case "$profile" in
        unconfined | "") pass "AppArmor unconfined" ;;
        *) fail "AppArmor profile '$profile' blocks containerd; set lxc.apparmor.profile: unconfined" ;;
    esac

    if [ -e /dev/kmsg ]; then
        pass "/dev/kmsg present"
    else
        fail "/dev/kmsg missing; the kubelet needs it"
    fi
    if [ -c /dev/net/tun ]; then
        pass "/dev/net/tun present"
    else
        fail "/dev/net/tun missing; Tailscale needs it"
    fi

    if [ -w "$PROC_SYS_PROBE" ]; then
        pass "/proc/sys/vm writable"
    else
        fail "/proc/sys/vm is read-only, so the kubelet cannot set its kernel values; set lxc.mount.auto: proc:rw sys:rw on the host"
    fi

    local controllers controller
    controllers=$(cat /sys/fs/cgroup/cgroup.controllers 2>/dev/null)
    for controller in cpuset cpu memory pids; do
        if [[ " $controllers " != *" $controller "* ]]; then
            fail "cgroup controller '$controller' is not delegated to the container"
        fi
    done

    # Check what each module provides, not /sys/module: a module built into
    # the host kernel (br_netfilter on Proxmox) has no /sys/module entry, and
    # the container has no /lib/modules for the host kernel to ask modinfo.
    if grep -qw overlay /proc/filesystems 2>/dev/null; then
        pass "kernel module overlay loaded"
    else
        fail "kernel module overlay is not loaded; load it on the host"
    fi
    if [ -e /proc/sys/net/bridge/bridge-nf-call-iptables ]; then
        pass "kernel module br_netfilter loaded"
    else
        fail "kernel module br_netfilter is not loaded; load it on the host"
    fi

    # The kubelet's static CPU manager reads sysfs, which shows every host CPU even
    # where lxcfs narrows /proc/cpuinfo, so it can pin pods to CPUs the container lacks.
    local allowed host_cpus
    allowed=$(nproc 2>/dev/null)
    host_cpus=$(find /sys/devices/system/cpu -maxdepth 1 -name 'cpu[0-9]*' | wc -l)
    if [ -n "$allowed" ] && [ "$host_cpus" -gt "$allowed" ]; then
        warn "the container may use $allowed of the host's $host_cpus CPUs; remove its core limit (pct set <CTID> --delete cores), or the kubelet can pin pods to CPUs it cannot use"
    else
        pass "the container may use every CPU ($allowed)"
    fi
}

main() {
    parse_args "$@"

    if [ "$APPLY" = true ] && [ "$(id -u)" -ne 0 ]; then
        echo "--apply must run as root" >&2
        exit 2
    fi

    # shellcheck source=/dev/null
    . /etc/os-release 2>/dev/null
    OS_ID="${ID:-unknown}"
    OS_VERSION="${VERSION_ID:-}"

    check_machine
    [ "$IN_LXC" = true ] && check_lxc
    case "$VENDOR" in
        amd) check_amd ;;
        nvidia) check_nvidia ;;
    esac
    check_common

    echo
    if [ "$FAILS" -gt 0 ]; then
        echo "${C_ERR}$FAILS failed, $WARNS warnings${C_RESET}"
        [ "$APPLY" = false ] && echo "Run with --apply to fix what this script can, then run it again."
        exit 1
    fi
    echo "${C_OK}ready for the ${VENDOR} GPU setup ($WARNS warnings)${C_RESET}"
    echo "Next: join this node from the panel's Game Server Nodes page, then run setup-gpu-nodes.sh on the panel."
}

# The tests source this file for its functions. Comparing BASH_SOURCE with $0
# cannot tell that apart from "curl ... | bash", where both differ.
if [ -z "${GPU_NODE_CHECK_LIB:-}" ]; then
    main "$@"
fi
