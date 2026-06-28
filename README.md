<div align="center">

# AeroVM

[![License](https://img.shields.io/github/license/sosuku325/aerovm?style=for-the-badge)](LICENSE)
[![GitHub Stars](https://img.shields.io/github/stars/sosuku325/aerovm?style=for-the-badge)](https://github.com/sosuku325/aerovm/stargazers)
[![GitHub Issues](https://img.shields.io/github/issues/sosuku325/aerovm?style=for-the-badge)](https://github.com/sosuku325/aerovm/issues)
[![Discord](https://img.shields.io/badge/Discord-Join-5865F2?style=for-the-badge&logo=discord&logoColor=white)](https://discord.gg/UaP8DpsDEK)

**Lightweight, free, open-source QEMU-based VM egg for Pterodactyl**

Works without KVM. Faster with KVM.

[Quick Start](#quick-start) • [Variables](#egg-variables) • [Support](#support) • [Contributing](#contributing)

</div>

---

## Features

- **Free & open source** — no license keys, no paywalls
- **KVM hybrid** — runs on software emulation by default; hardware acceleration when KVM is available
- **Lightweight** — tuned QEMU flags (virtio disk/net, memory balloon); the Alpine blank-disk image is the smallest option
- **Pterodactyl native** — one egg import, no panel modifications required
- **Two ways to provision**: bring your own OS on a blank disk, or pick a cloud-init image (Debian, Ubuntu, Fedora, Arch, Rocky, AlmaLinux) that's ready to log into on first boot
- **SSH, VNC, noVNC, SPICE, or RDP** — cloud-init images can auto-provision a lightweight desktop for the latter four

## Requirements

| Component | Minimum |
|-----------|---------|
| Pterodactyl Panel | 1.11.x |
| Wings | v1.11.9+ (tested up to v1.13.0) |
| Docker | 20.x+ |
| Host OS | Linux (KVM-capable for acceleration) |

## Quick Start

**1. (Optional, recommended) Enable KVM on the node**

Run this once on each Wings node, before importing the egg, to get hardware-accelerated VMs. Without it, AeroVM still works, just slower (software emulation).

**Prerequisites:** Wings v1.11.9 or newer, Go, and root access. The required Go version depends on the Wings release: **Go 1.21+** for Wings v1.11.x, **Go 1.24+** for v1.12.0 and newer (their `go.mod` requires it). The installer detects this and tells you which it needs.

> **Heads-up:** most distros package an older Go than Wings v1.12+ needs (Ubuntu 24, for example, ships Go 1.22). If the installer says your Go is too old, install a current Go and put it first on `PATH`, then re-run in the same shell:
>
> ```bash
> rm -rf /usr/local/go
> curl -fsSL https://go.dev/dl/go1.24.0.linux-amd64.tar.gz -o /tmp/go.tar.gz   # arm64: swap amd64 -> arm64
> tar -C /usr/local -xzf /tmp/go.tar.gz
> export PATH=/usr/local/go/bin:$PATH
> go version   # should report go1.24.0 (or newer)
> ```

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/sosuku325/aerovm/main/wings-patch/install.sh)
```

The script will:
1. Detect the installed Wings version (v1.11.9+ supported) and pick the matching patch + required Go version
2. Build the patched Wings **before** stopping the service, so a build failure leaves your running Wings untouched
3. Stop Wings, back up the current binary (`wings.bak.<timestamp>`), and install the patched build
4. Set `/dev/kvm` permissions persistently (udev rule + group)
5. Restart Wings (an EXIT-trap safety net restarts it even if a step fails midway)

The patch itself adds a `/dev/kvm` device mapping to every server container and grants the container's process the host's `kvm` group, so guests can use hardware acceleration. `container.go` targets Wings v1.12+ (newer Docker SDK); `container_legacy.go` targets v1.11.x (older SDK) — the installer chooses automatically.

**To revert:**
```bash
# Restore the backup created by install.sh
cp /usr/local/bin/wings.bak.<timestamp> /usr/local/bin/wings
rm /etc/udev/rules.d/99-aerovm-kvm.rules
udevadm control --reload-rules
systemctl restart wings
```

**2. Download the egg**

Download [`egg-aerovm.json`](egg/egg-aerovm.json) from this repository.

**3. Import to Pterodactyl**

Navigate to **Admin → Nests → Import Egg** and upload the file.

**4. Create a server**

Create a new server using the AeroVM egg, and pick a **Docker Image**:

- **Blank disk** (Alpine, Ubuntu 22.04/24.04/26.04 LTS): an empty disk — you provide the OS yourself (e.g. by uploading a pre-made disk image over SFTP).
- **Cloud-init** (Debian 12, Ubuntu 22.04, Ubuntu 24.04, Fedora, Arch Linux, Rocky Linux, AlmaLinux): the disk is pre-provisioned from the official cloud image and ready to log into on first boot — set `OS_HOSTNAME`/`OS_PASSWORD`/`OS_PUBKEY` to configure it. Setting `DISPLAY_MODE` to `vnc`/`novnc`/`spice`/`rdp` makes cloud-init install a desktop environment automatically (adds a few minutes to first boot).

Configure RAM, CPU, and disk via the egg variables. Start the server — the VM will boot automatically, using KVM acceleration if step 1 was applied to that node.

> **Note:** `ADDITIONAL_PORTS` requires the ports to also be assigned as **Allocations** in the Pterodactyl panel. QEMU-side forwarding alone is not enough; Docker must also expose the port.

## Egg Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `VM_RAM_MB` | RAM allocated to the VM (MB) | `512` |
| `VM_CPU_CORES` | vCPU cores (max 16) | `1` |
| `VM_DISK_GB` | Virtual disk size (GB) | `20` |
| `DISPLAY_MODE` | `ssh` / `vnc` / `novnc` / `spice` / `rdp` / `none` | `ssh` |
| `KVM` | `auto` (use KVM if available) / `off` (force software emulation) / `on` (require KVM) | `auto` |
| `ADDITIONAL_PORTS` | Extra port forwards (e.g. `8080-80,443`) | — |
| `UEFI` | Enable UEFI firmware (`0` or `1`) | `0` |
| `OS_HOSTNAME` | Guest hostname (cloud-init images only) | `aerovm` |
| `OS_PASSWORD` | Root/SSH password (cloud-init images only). Leave blank to auto-generate one (printed to the console on first boot) | — |
| `OS_PUBKEY` | SSH public key (cloud-init images only). If set, password SSH login is disabled | — |
| `PACKAGE_UPDATE` | Update packages on every boot (cloud-init images only, `0` or `1`) | `0` |
| `IPV4_MODE` | `disabled` (ignore Additional Ports) / `user` (forward Additional Ports) / `all` (also forward ports 1-1024, slower startup) | `user` |
| `OVERWRITE_HOST` | Overwrite the host/product name shown inside the VM (neofetch, dmidecode, etc.) | — |
| `OVERWRITE_IP` | Overwrite the host/IP shown in the connection info printed at startup | — |
| `BANNER` | Custom startup banner (`\n` and Bash color codes supported) | — |

> `VM_RAM_MB` and `VM_CPU_CORES` are independent of Pterodactyl's resource limits. Set them to values your node can actually support.
>
> `OS_HOSTNAME`/`OS_PASSWORD`/`OS_PUBKEY`/`PACKAGE_UPDATE` only have an effect on the cloud-init Docker images. The blank-disk images (Alpine/Ubuntu LTS) ignore them since there's no OS installed yet to configure.
>
> **Pterodactyl "Disk Space"** (the container disk limit, in MiB) must be larger than `VM_DISK_GB` — the VM's `disk.qcow2` can grow up to `VM_DISK_GB`, and a server is stopped if it exceeds its Pterodactyl disk limit. For `VM_DISK_GB=20`, set Disk Space to ~`25000` MiB or `0` (unlimited).

> ⚠️ **Nested virtualization warning.** If your Pterodactyl **node is itself a virtual machine** (e.g. a VM from another VPS host), enabling hardware KVM inside it means *nested* virtualization. On some hosts (notably certain AMD setups) nested KVM is unstable and can **kernel-panic the whole node**. If applying the KVM patch and booting a VM crashes your node, set the **`KVM` variable to `off`** to force stable software emulation. KVM acceleration is only safe when the node is bare metal or its host explicitly supports stable nested virtualization.

## Display Modes

| Mode | Description |
|------|-------------|
| `ssh` | SSH via the server's primary Pterodactyl port |
| `vnc` | Raw VNC on port 5900 |
| `novnc` | Browser-based VNC on port 6080 |
| `spice` | SPICE protocol on port 5900 (connect with a native SPICE client) |
| `rdp` | RDP on port 3389 — **cloud-init images only**, logs in as the `aerovm` user |
| `none` | Headless — no display output |

On a cloud-init image, choosing `vnc`/`novnc`/`spice`/`rdp` makes cloud-init install a lightweight XFCE desktop (and xrdp, for `rdp`) on first boot — this adds a few minutes before the desktop is usable. A dedicated `aerovm` sudo user (password: `OS_PASSWORD`) is created for the desktop session — `vnc`/`novnc`/`spice` auto-login as `aerovm`, and `rdp` prompts for it at connection time. On blank-disk images, `vnc`/`novnc`/`spice` just show the VM's console/installer screen (no OS to provision yet), and `rdp` isn't available.

> **Note:** `vnc`/`spice` (port `5900`), `novnc` (port `6080`), and `rdp` (port `3389`) all need their port assigned as an **Allocation** in the Pterodactyl panel, the same as `ADDITIONAL_PORTS` — QEMU listening on the port isn't enough if Docker/Wings hasn't also exposed it.

## How It Works

The container's entrypoint is [`scripts/start.sh`](scripts/start.sh), which runs every boot and builds the QEMU command line from the egg variables:

1. **Validate inputs** — integers are range-checked (and guarded against int64 overflow), `DISPLAY_MODE`/`IPV4_MODE` are checked against their allowed sets, the hostname against `[a-zA-Z0-9-]{1,63}`, and `OS_PASSWORD`/`OS_PUBKEY` are rejected if they contain newlines (they're embedded into cloud-init YAML).
2. **Detect KVM** — if `/dev/kvm` is readable *and* writable, QEMU runs with `-enable-kvm -cpu host` and `aio=native`; otherwise it falls back to software emulation (`-cpu qemu64`, `aio=threads`). Either way the VM boots.
3. **Provision the disk** (`/home/container/disk.qcow2`, persisted across reboots):
   - *Blank-disk images*: create an empty `qcow2` of `VM_DISK_GB`.
   - *Cloud-init images*: copy the bundled cloud image (`/opt/base-image/base.qcow2`) and grow it to `VM_DISK_GB` (skipped if that's smaller than the image's own size).
4. **Build a cloud-init seed** (cloud-init images only) — a NoCloud `cidata` ISO (`meta-data` + `user-data`) is generated with `xorriso` and attached via `-cdrom`. It sets the hostname, the root password (`chpasswd`), an SSH key (if provided), and optional package upgrades. A random instance-id is persisted (`.cloud-init-instance-id`) so cloud-init doesn't re-run on later boots. For a graphical `DISPLAY_MODE` it also creates an `aerovm` sudo user for the desktop session and runs a `runcmd` that installs XFCE + LightDM (plus `spice-vdagent` or `xrdp`) using the package manager for the image's `CLOUD_OS_FAMILY` (`debian`/`fedora`/`rhel`/`arch`).
5. **Set up networking** — QEMU user-mode networking with `hostfwd` rules: the primary Pterodactyl port → guest `22`, plus RDP `3389` (rdp mode), the `1-1024` range (`IPV4_MODE=all`), and `ADDITIONAL_PORTS`. Ports the display already uses (5900/6080) and duplicates are skipped.
6. **Pick the display** — `ssh` uses the serial console (`-nographic -serial mon:stdio`); `vnc`/`novnc` use `-vga virtio` on VNC `:0` (5900), with `novnc` also launching a noVNC→VNC proxy on 6080; `spice` uses `-vga qxl` with `-spice`; `rdp`/`none` run headless.
7. **Launch QEMU** — `exec qemu-system-x86_64` with virtio disk/net, a memory balloon, optional `-bios` (OVMF, when `UEFI` is on), and optional `-smbios` (when `OVERWRITE_HOST` is set).

**KVM on the node (optional patch).** Wings starts each server container with an explicit numeric `uid:gid`, which makes Docker ignore the image's own group memberships — so just adding the container user to a `kvm` group in the Dockerfile isn't enough. The patch in [`wings-patch/`](wings-patch/) makes Wings map `/dev/kvm` into the container and add the host's real `kvm` group GID via Docker's `GroupAdd`, so the guest can actually open the device.

## Images & Versions

All images are published to `ghcr.io/sosuku325/aerovm:<tag>`.

| Tag | Base image | Bundled guest OS |
|-----|-----------|------------------|
| `alpine` | Alpine 3.19 | — (blank disk) |
| `ubuntu-22.04` / `ubuntu-24.04` / `ubuntu-26.04` | Ubuntu LTS | — (blank disk) |
| `guest-debian-12` | Alpine 3.19 | Debian 12 (bookworm) cloud image |
| `guest-ubuntu-22.04` / `guest-ubuntu-24.04` | Alpine 3.19 | Ubuntu 22.04 (jammy) / 24.04 (noble) cloud image |
| `guest-fedora` | Alpine 3.19 | Fedora Cloud Base 44 |
| `guest-arch` | Alpine 3.19 | Arch Linux (latest cloud image) |
| `guest-rockylinux` / `guest-almalinux` | Alpine 3.19 | Rocky Linux 9 / AlmaLinux 9 GenericCloud |

Cloud-init images bundle the official upstream `qcow2`/`img` at build time, so no extra download happens when a server is created. Desktop sessions use **XFCE4 + LightDM** (with **xrdp** for RDP, **spice-vdagent** for SPICE).

## Project Structure

```
AeroVM/
├── egg/
│   └── egg-aerovm.json       # Pterodactyl egg (user-facing)
├── docker/
│   ├── Dockerfile.alpine               # Alpine-based image, blank disk (smallest)
│   ├── Dockerfile.ubuntu-22.04         # Ubuntu 22.04 LTS image, blank disk
│   ├── Dockerfile.ubuntu-24.04         # Ubuntu 24.04 LTS image, blank disk
│   ├── Dockerfile.ubuntu-26.04         # Ubuntu 26.04 LTS image, blank disk
│   ├── Dockerfile.guest-debian-12      # Debian 12 cloud image bundled, cloud-init
│   ├── Dockerfile.guest-ubuntu-22.04   # Ubuntu 22.04 cloud image bundled, cloud-init
│   ├── Dockerfile.guest-ubuntu-24.04   # Ubuntu 24.04 cloud image bundled, cloud-init
│   ├── Dockerfile.guest-fedora         # Fedora Cloud image bundled, cloud-init
│   ├── Dockerfile.guest-arch           # Arch Linux cloud image bundled, cloud-init
│   ├── Dockerfile.guest-rockylinux     # Rocky Linux cloud image bundled, cloud-init
│   └── Dockerfile.guest-almalinux      # AlmaLinux cloud image bundled, cloud-init
├── scripts/
│   └── start.sh              # VM startup script
├── wings-patch/
│   ├── container.go          # Patched Wings file (KVM support), for Wings v1.12+
│   ├── container_legacy.go   # Patched Wings file (KVM support), for Wings v1.11.x
│   └── install.sh            # One-command KVM patch installer (auto-detects Wings version)
├── .github/workflows/
│   └── build.yml             # Auto-build and push all images to ghcr.io
└── .gitattributes            # Forces LF line endings (CRLF would break the shell scripts on Linux)
```

## Support

Questions, help, or feedback? Join the Discord: https://discord.gg/UaP8DpsDEK

## Contributing

PRs and issues are welcome.

1. Fork the repository
2. Create a feature branch
3. Commit your changes
4. Open a pull request

## License

MIT — see [LICENSE](LICENSE)