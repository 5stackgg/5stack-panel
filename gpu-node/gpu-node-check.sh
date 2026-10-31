#!/bin/bash

# Checks that a machine can run 5stack GPU render pods, and with --apply fixes
# what it safely can. Run it as root on the GPU node itself: a dedicated
# machine, a VM with the GPU passed through, or a Proxmox LXC container (run
# gpu-node/proxmox-gpu-lxc.sh on the Proxmox host first).
#
# Run it before the panel's node setup command, and again after, since some
# checks (the k3s container runtime) only mean something once k3s is there.
#
#   gpu-node-check.sh [--apply] [--vendor nvidia|amd] [--k3s-version v1.36.5+k3s1]
#
# Exit code: 0 when nothing failed, 1 when a check failed, 2 on bad usage.
#
# It never touches the GPU's power or clock settings, the desktop session or
# Tailscale, and it never installs a kernel driver inside a container.

APPLY=false
VENDOR=""
K3S_VERSION=""

usage() {
    echo "usage: gpu-node-check.sh [--apply] [--vendor nvidia|amd] [--k3s-version v1.36.5+k3s1]" >&2
    exit 2
}

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

if [ "$APPLY" = true ] && [ "$(id -u)" -ne 0 ]; then
    echo "--apply must run as root" >&2
    exit 2
fi

# shellcheck source=/dev/null
. /etc/os-release 2>/dev/null
OS_ID="${ID:-unknown}"
OS_VERSION="${VERSION_ID:-}"

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

# apply_step DESCRIPTION COMMAND...
# Runs an --apply step and reports it as fixed or failed.
apply_step() {
    local description="$1"
    shift
    if "$@"; then
        fixed "$description"
    else
        fail "could not apply: $description"
    fi
}

# The kernel log, when this machine may read it. A container usually may not.
kernel_log() {
    dmesg 2>/dev/null || journalctl -k -b 0 --no-pager 2>/dev/null
}

step "Machine"

CONTAINER=$(systemd-detect-virt -c 2>/dev/null || true)
VM=$(systemd-detect-virt -v 2>/dev/null || true)
IN_LXC=false
ON_HOST=""
case "$CONTAINER" in
    lxc*)
        IN_LXC=true
        ON_HOST=" on the host"
        ;;
    none | "") ;;
    *)
        fail "running in a $CONTAINER container; only bare metal, VMs and LXC are supported"
        ;;
esac

if [ "$IN_LXC" = true ]; then
    info "LXC container on kernel $(uname -r); the host owns the GPU driver, firmware and CPU governor"
elif [ -n "$VM" ] && [ "$VM" != none ]; then
    info "$VM VM on kernel $(uname -r); the GPU must be passed through to it"
else
    info "bare metal, kernel $(uname -r)"
fi
info "$OS_ID $OS_VERSION"

# GPUs, from sysfs, which a container sees too.
NVIDIA_GPUS=()
AMD_GPUS=()
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

driver_of() {
    basename "$(readlink "$1/driver" 2>/dev/null)" 2>/dev/null
}

cmdline_has() {
    tr ' ' '\n' </proc/cmdline | grep -qx "$1"
}

# --- AMD -------------------------------------------------------------------

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

check_amd() {
    local dev pci driver node render integrated bar0 size level

    step "AMD GPU"

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
            info "$pci is integrated: select this node in setup-gpu-nodes.sh's integrated list (5stack-gpu-integrated=true)"
        else
            # BAR0 is the CPU's window into VRAM. 256 MiB means Above 4G
            # decoding (and Resizable BAR) is off in the firmware.
            bar0=$(head -1 "$dev/resource" 2>/dev/null)
            size=$(( $(echo "$bar0" | awk '{print $2}') - $(echo "$bar0" | awk '{print $1}') + 1 ))
            if [ "$size" -gt 0 ] && [ "$size" -le $((256 * 1024 * 1024)) ]; then
                warn "$pci: VRAM window is $((size / 1024 / 1024)) MiB; enable Above 4G decoding and Resizable BAR in the firmware"
            fi
            if ! cmdline_has amdgpu.runpm=0; then
                warn "$pci: a headless discrete GPU can drop off the bus in runtime suspend; add amdgpu.runpm=0 to the kernel command line${ON_HOST:+ of the host}"
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

# --- NVIDIA ----------------------------------------------------------------

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
    # The new repository needs its own package list.
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
            apply_step "installed the recommended NVIDIA driver; reboot, then run this again" \
                env DEBIAN_FRONTEND=noninteractive ubuntu-drivers install </dev/null >/dev/null
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
            hint "'nvidia-modprobe -u -c0' creates them; nvidia-persistenced keeps them across boots."
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

# --- Common ----------------------------------------------------------------

# The k3s unit: k3s-agent on a node that joined the panel, k3s when the GPU
# node is the panel's server itself.
k3s_service() {
    if systemctl is-enabled --quiet k3s 2>/dev/null; then
        echo k3s
    else
        echo k3s-agent
    fi
}

GOVERNOR_UNIT=/etc/systemd/system/cpu-governor-performance.service

install_governor_unit() {
    cat >"$GOVERNOR_UNIT" <<'UNIT' || return 1
[Unit]
Description=Set the CPU frequency governor to performance for game streaming
After=sysinit.target power-profiles-daemon.service

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'for g in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do echo performance > "$g"; done'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
UNIT
    systemctl daemon-reload && systemctl enable --now cpu-governor-performance.service >/dev/null 2>&1
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
    governor=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null)
    if [ -z "$governor" ]; then
        info "no CPU frequency scaling exposed"
    elif [ "$governor" = performance ]; then
        pass "CPU governor is performance"
    elif [ "$IN_LXC" = true ]; then
        warn "CPU governor is '$governor'; set it to performance on the host (proxmox-gpu-lxc.sh --apply does)"
    elif [ "$APPLY" = true ]; then
        apply_step "CPU governor set to performance, at every boot ($GOVERNOR_UNIT)" install_governor_unit
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
            hint "Re-join with: export INSTALL_K3S_VERSION=$K3S_VERSION, then the panel's node setup command."
        else
            pass "k3s $installed installed"
        fi
        if systemctl is-active --quiet "$service" 2>/dev/null; then
            pass "$service running"
        else
            fail "$service is not running; see 'journalctl -u $service -n 50'"
        fi
    else
        info "k3s not installed yet. The node setup command installs the latest k3s; to match the panel, first run:"
        if [ -n "$K3S_VERSION" ]; then
            hint "export INSTALL_K3S_VERSION=$K3S_VERSION"
        else
            hint "export INSTALL_K3S_VERSION=<the Server Version from kubectl version on the panel>"
        fi
    fi
}

# k3s in an LXC needs a privileged container with the host's kernel features
# opened up; proxmox-gpu-lxc.sh sets all of this on the host.
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

    if [ -w /proc/sys/net/ipv4/ip_forward ]; then
        pass "/proc/sys writable"
    else
        fail "/proc/sys is read-only; set lxc.mount.auto: proc:rw sys:rw"
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

    # The kubelet's static CPU manager finds CPUs through sysfs, which shows
    # every host CPU even where lxcfs narrows /proc/cpuinfo to the container's
    # cores, so a container held to fewer cores gets pods pinned to CPUs it
    # cannot use.
    local allowed host_cpus
    allowed=$(nproc 2>/dev/null)
    host_cpus=$(find /sys/devices/system/cpu -maxdepth 1 -name 'cpu[0-9]*' | wc -l)
    if [ -n "$allowed" ] && [ "$host_cpus" -gt "$allowed" ]; then
        warn "the container may use $allowed of the host's $host_cpus CPUs; remove its core limit (pct set <CTID> --delete cores), or the kubelet can pin pods to CPUs it cannot use"
    else
        pass "the container may use every CPU ($allowed)"
    fi
}

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
echo "Next: run the panel's node setup command here, then setup-gpu-nodes.sh on the panel."
