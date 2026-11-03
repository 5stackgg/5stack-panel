# GPU nodes

A GPU node renders demos, highlights and clips. It can be a dedicated machine,
a VM with the GPU passed through, or a Proxmox LXC container. NVIDIA and AMD
GPUs are both supported, one vendor per panel (`GPU_VENDOR`).

| Script | Runs on | Does |
| --- | --- | --- |
| `gpu-node-check.sh` | the GPU node | checks the driver, firmware, container runtime, CPU governor, disk and k3s version; `--apply` fixes what it safely can |
| `proxmox-gpu-lxc.sh CTID` | the Proxmox host | checks the host driver and kernel modules and the container's settings; `--apply` writes them |
| `setup-gpu-nodes.sh` | the panel | labels the GPU nodes for the panel's vendor and turns that vendor's support on |

The two check scripts only report unless you pass `--apply`, and exit 1 while
something still fails. None of these scripts change the GPU's power or clock
settings.

## Getting the scripts

A GPU node or a Proxmox host has no panel checkout, so download the script you
need there:

```bash
curl -fsSLO https://raw.githubusercontent.com/5stackgg/5stack-panel/main/gpu-node/gpu-node-check.sh
curl -fsSLO https://raw.githubusercontent.com/5stackgg/5stack-panel/main/gpu-node/proxmox-gpu-lxc.sh
```

## Before you start

- **k3s version.** The join installs the latest k3s, and a kubelet newer than
  the panel's API server is unsupported. If the panel runs an older k3s, pin
  the join to its `Server Version` from `kubectl version`. The pin goes after
  `sudo`, which drops exported variables:

  ```bash
  curl -fsSL https://get.5stack.gg | sudo INSTALL_K3S_VERSION=v1.36.5+k3s1 sh -s -- join --panel-key <key>
  ```

- **Disk.** The join wants 120 GB free on `/` before CS2 is installed and 60 GB
  once it is, the panel's "Required disk space" settings.
- **CPU governor.** Render pods drop frames while the CPU ramps up, so `--apply`
  sets `performance` with the panel's `5stack-cpu-governor.service`. In an LXC
  container that happens on the Proxmox host.

## Dedicated machine or VM

1. Install Ubuntu 24.04 or newer, server or desktop. A headless install is
   recommended: a desktop session keeps hold of the GPU's display.
2. Run the check, then let it fix what it can and reboot if it asks:

   ```bash
   sudo bash gpu-node-check.sh
   sudo bash gpu-node-check.sh --apply --k3s-version v1.36.5+k3s1
   ```

3. Join the node: on the panel's **Game Server Nodes** page
   (`/game-server-nodes`), create a node and run the command it shows on this
   machine. Then run the check again: some checks only apply once k3s is there.
4. On the panel, run `setup-gpu-nodes.sh` and pick the vendor and nodes: from
   the panel checkout as `./setup-gpu-nodes.sh`, or on a panel that runs as the
   5Stack service, `sudo 5stack run setup-gpu-nodes.sh`. All GPU nodes of a
   panel use the same vendor.

### NVIDIA

- `--apply` installs the recommended driver (`ubuntu-drivers install`) and the
  NVIDIA container toolkit, and restarts k3s-agent if it started before the
  toolkit was there.
- With Secure Boot on, use Ubuntu's signed prebuilt driver modules
  (`ubuntu-drivers install` picks them) or enroll the DKMS key with `mokutil`.
- After a driver upgrade, `nvidia-smi` fails until the next reboot.
- A headless node may have no `/dev/nvidia-modeset`; `nvidia-modprobe -m`
  creates it.

### AMD

- `--apply` installs the AMD firmware package.
- On Ubuntu 24.04, use the HWE kernel (`linux-generic-hwe-24.04`); the original
  6.8 kernel predates recent Radeons.
- Never boot with `nomodeset`, `amdgpu.modeset=0` or `amdgpu.dpm=0`. There is
  no kernel parameter to add.
- For a discrete card, enable Above 4G decoding and Resizable BAR in the
  firmware.
- Tick a node in the integrated list of `setup-gpu-nodes.sh` only when its
  integrated GPU (an APU, such as Ryzen AI Max) is its only AMD GPU. Leave a
  node with a discrete Radeon card unticked, even when its CPU also has an
  integrated GPU: ticked, it renders on the integrated GPU and leaves the card
  unused. The check says which case a node is.

## Proxmox LXC container

k3s needs a **privileged** container. The host keeps the GPU driver and shares
the device with the container; do not bind the GPU to `vfio-pci`.

1. On the host, install the GPU driver (NVIDIA: the proxmox headers and
   NVIDIA's `.run` installer; AMD: the kernel driver is built in, firmware comes
   from `pve-firmware`).
2. Create a privileged Ubuntu container with at least 140 GB of disk (120 GB
   free for the join, plus the system) and no core limit (the kubelet pins pods
   to CPUs by number and sees every host CPU).
3. On the host:

   ```bash
   bash proxmox-gpu-lxc.sh 120
   bash proxmox-gpu-lxc.sh 120 --apply
   pct reboot 120
   ```

   `--apply` loads the kernel modules k3s needs, sets the CPU governor, creates
   the NVIDIA device nodes at boot, turns on nesting, backs up
   `/etc/pve/lxc/120.conf` to `/root`, and adds these lines to it:

   ```
   lxc.apparmor.profile: unconfined
   lxc.cgroup2.devices.allow: a
   lxc.cap.drop:
   lxc.mount.auto: proc:rw sys:rw
   lxc.mount.entry: /dev/kmsg dev/kmsg none bind,optional,create=file
   lxc.mount.entry: /dev/net/tun dev/net/tun none bind,optional,create=file
   # AMD
   lxc.mount.entry: /dev/dri dev/dri none bind,optional,create=dir
   lxc.mount.entry: /dev/kfd dev/kfd none bind,optional,create=file
   # NVIDIA: /dev/nvidia0, nvidiactl, nvidia-uvm, nvidia-uvm-tools,
   # nvidia-modeset and nvidia-caps, the same way
   ```

   > **`proc:rw` changes the whole host.** It lets the kubelet set
   > `vm.overcommit_memory=1`, `kernel.panic=10` and `kernel.panic_on_oops=1`,
   > which are not per container: the Proxmox host then reboots 10 seconds
   > after a kernel oops, and every guest on it goes down. Decide whether that
   > is acceptable before you restart the container.

4. Inside the container, run `gpu-node-check.sh --apply`. For NVIDIA it
   installs the host driver's exact version of the NVIDIA libraries, without
   the kernel module, plus the container toolkit.
5. Continue with step 3 of the dedicated machine steps.

If NVIDIA pods fail to start in the container with a device cgroup error, set
`no-cgroups = true` under `[nvidia-container-cli]` in
`/etc/nvidia-container-runtime/config.toml` and restart k3s-agent. Leave it at
the default otherwise: the NVIDIA device plugin runs unprivileged and relies
on it.

## Reporting a problem

Include the output of `gpu-node-check.sh`, `proxmox-gpu-lxc.sh` for a container,
and `journalctl -k -b | grep -iE "amdgpu|nvidia|nvrm"`.
