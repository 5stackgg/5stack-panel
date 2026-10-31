# GPU nodes

A GPU node renders demos, highlights and clips. It can be a dedicated machine,
a VM with the GPU passed through, or a Proxmox LXC container. NVIDIA and AMD
GPUs are both supported, one vendor per panel (`GPU_VENDOR`).

| Script | Runs on | Does |
| --- | --- | --- |
| `gpu-node-check.sh` | the GPU node | checks the driver, firmware, container runtime, CPU governor, disk and k3s version; `--apply` fixes what it safely can |
| `proxmox-gpu-lxc.sh CTID` | the Proxmox host | checks the host driver and kernel modules and the container's settings; `--apply` writes them |
| `setup-gpu-nodes.sh` | the panel | labels the GPU nodes for the panel's vendor and turns that vendor's support on |

Every script only reports unless you pass `--apply`, and exits 1 while
something still fails. None of them change the GPU's power or clock settings.

## Before you start

- **k3s version.** The node setup command installs the latest k3s, and a
  kubelet newer than the panel's API server is unsupported. If the panel runs
  an older k3s, read its version with `kubectl version` on the panel
  (`Server Version`) and export it on the node before the setup command:

  ```bash
  export INSTALL_K3S_VERSION=v1.36.5+k3s1
  ```

- **Disk.** The node setup command wants 120 GB free on `/`.
- **CPU governor.** Render pods drop frames while the CPU ramps up, so the
  governor is set to `performance`. In an LXC container that happens on the
  Proxmox host.

## Dedicated machine or VM

1. Install Ubuntu 24.04 or newer, server or desktop. A headless install is
   recommended: a desktop session keeps hold of the GPU's display.
2. Run the check, then let it fix what it can and reboot if it asks:

   ```bash
   sudo bash gpu-node-check.sh
   sudo bash gpu-node-check.sh --apply --k3s-version v1.36.5+k3s1
   ```

3. Export `INSTALL_K3S_VERSION`, run the node setup command from the panel
   (Settings, Nodes), and run the check again: some checks only apply once k3s
   is there.
4. On the panel, run `./setup-gpu-nodes.sh` and pick the vendor and nodes.
   All GPU nodes of a panel use the same vendor.

### NVIDIA

- `--apply` installs the recommended driver (`ubuntu-drivers install`) and the
  NVIDIA container toolkit, and restarts k3s-agent if it started before the
  toolkit was there.
- With Secure Boot on, use Ubuntu's signed prebuilt driver modules
  (`ubuntu-drivers install` picks them) or enroll the DKMS key with `mokutil`.
- After a driver upgrade, `nvidia-smi` fails until the next reboot.

### AMD

- `--apply` installs the AMD firmware package.
- On Ubuntu 24.04, use the HWE kernel (`linux-generic-hwe-24.04`); the original
  6.8 kernel predates recent Radeons.
- Never boot with `nomodeset`, `amdgpu.modeset=0` or `amdgpu.dpm=0`.
- For a discrete card: enable Above 4G decoding and Resizable BAR in the
  firmware, and add `amdgpu.runpm=0` to the kernel command line so a headless
  card cannot suspend off the bus.
- For an APU (such as Ryzen AI Max), select the node in the integrated list in
  `setup-gpu-nodes.sh`. The check says when a GPU is integrated.

## Proxmox LXC container

k3s needs a **privileged** container. The host keeps the GPU driver and shares
the device with the container; do not bind the GPU to `vfio-pci`.

1. On the host, install the GPU driver (NVIDIA: the proxmox headers and
   NVIDIA's `.run` installer; AMD: the kernel driver is built in, firmware comes
   from `pve-firmware`).
2. Create a privileged Ubuntu container with at least 120 GB of disk and no core
   limit (the kubelet pins pods to CPUs by number and sees every host CPU).
3. On the host:

   ```bash
   bash proxmox-gpu-lxc.sh 120
   bash proxmox-gpu-lxc.sh 120 --apply
   pct reboot 120
   ```

   `--apply` loads the kernel modules k3s needs (and at every boot), sets the CPU
   governor, creates the NVIDIA device nodes at boot, turns on nesting, and adds
   these lines to `/etc/pve/lxc/120.conf` (after backing it up to `/root`):

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
