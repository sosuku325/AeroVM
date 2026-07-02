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
- **Two ways to provision**: pick a cloud-init image (Debian 10-13, Ubuntu 18.04-24.04, Kali, Fedora, Arch, Rocky, AlmaLinux) that's ready to log into on first boot, or install any OS yourself on a blank disk from an installer ISO (`OS_ISO_URL` or an uploaded `os.iso`)
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

The patch itself adds a `/dev/kvm` device mapping to every server container and grants the container's process the host's `kvm` group, so guests can use hardware acceleration. `container.go.txt` targets Wings v1.12+ (newer Docker SDK); `container_legacy.go.txt` targets v1.11.x (older SDK) — the installer chooses automatically. (These overlays replace a file inside the Wings source tree, so they're stored as `.go.txt` to keep local Go tooling from type-checking them out of context; the installer writes the chosen one back as `container.go` before building.)

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

- **Blank disk** (Alpine, Ubuntu 22.04/24.04/26.04 LTS): an empty disk — you install the OS yourself from an installer ISO. Set `OS_ISO_URL` to a direct ISO download link (or upload one as `os.iso` via SFTP/file manager), set `DISPLAY_MODE` to `vnc` or `novnc` to see the installer, and start the server. The ISO boots automatically while the disk is empty; after installing, delete `os.iso` and clear `OS_ISO_URL`.
- **Cloud-init** (Debian 12, Ubuntu 22.04, Ubuntu 24.04, Fedora, Arch Linux, Rocky Linux, AlmaLinux): the disk is pre-provisioned from the official cloud image and ready to log into on first boot — set `OS_HOSTNAME`/`OS_PASSWORD`/`OS_PUBKEY` to configure it. Setting `DISPLAY_MODE` to `vnc`/`novnc`/`spice`/`rdp` makes cloud-init install a desktop environment automatically (adds a few minutes to first boot).

Configure RAM, CPU, and disk via the egg variables. Start the server — the VM will boot automatically, using KVM acceleration if step 1 was applied to that node.

> **Note:** `ADDITIONAL_PORTS` requires the ports to also be assigned as **Allocations** in the Pterodactyl panel. QEMU-side forwarding alone is not enough; Docker must also expose the port.

## Egg Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `VM_RAM_MB` | RAM allocated to the VM (MB). Cloud-init images need ≥ 1024; use 2048+ under software emulation | `1024` |
| `VM_CPU_CORES` | vCPU cores (max 16). Use 2+ for cloud-init images | `2` |
| `VM_DISK_GB` | Virtual disk size (GB) | `20` |
| `DISPLAY_MODE` | `ssh` / `vnc` / `novnc` / `spice` / `rdp` / `none` | `ssh` |
| `KVM` | `auto` (KVM on bare metal; software emulation if the node is itself a VM) / `off` (force software emulation) / `on` (force KVM, even nested) | `auto` |
| `ADDITIONAL_PORTS` | Extra port forwards (e.g. `8080-80,443`) | — |
| `UEFI` | Enable UEFI firmware (`0` or `1`) | `0` |
| `OS_HOSTNAME` | Guest hostname (cloud-init images only). Letters/digits/hyphens, no leading or trailing hyphen | `aerovm` |
| `OS_PASSWORD` | Root/SSH password (cloud-init images only). Leave blank to auto-generate one — it's persisted in `.aerovm-root-password` and printed to the console on every boot | — |
| `OS_PUBKEY` | SSH public key (cloud-init images only). If set, password SSH login is disabled | — |
| `PACKAGE_UPDATE` | Update packages on every boot (cloud-init images only, `0` or `1`) | `0` |
| `OS_ISO_URL` | Direct http(s) URL of an OS installer ISO (blank-disk images only) — downloaded once as `os.iso` and attached as a CD-ROM | — |
| `IPV4_MODE` | `disabled` (ignore Additional Ports) / `user` (forward Additional Ports) / `all` (also forward ports 1-1024, slower startup) | `user` |
| `OVERWRITE_HOST` | Overwrite the host/product name shown inside the VM (neofetch, dmidecode, etc.) | — |
| `OVERWRITE_IP` | Overwrite the host/IP shown in the connection info printed at startup | — |
| `BANNER` | Custom startup banner (`\n` and Bash color codes supported) | — |

> `VM_RAM_MB` and `VM_CPU_CORES` are independent of Pterodactyl's resource limits. Set them to values your node can actually support.
>
> **First boot timing out / dropping to emergency mode?** The ready-to-use cloud-init images boot a full systemd userland and need more than the bare minimum, especially when the node runs the VM under software emulation (`KVM=off`, or `auto` on a nested node). Give the server at least **2048 MB RAM and 2 cores** — a starved VM can miss systemd's 90s device-detection timeout and drop to an emergency shell. On bare-metal nodes with real KVM, 1024 MB / 1 core is usually fine.
>
> `OS_HOSTNAME`/`OS_PASSWORD`/`OS_PUBKEY`/`PACKAGE_UPDATE` only have an effect on the cloud-init Docker images. The blank-disk images (Alpine/Ubuntu LTS) ignore them since there's no OS installed yet to configure — use `OS_ISO_URL` (or upload `os.iso`) there instead.
>
> **Changing settings later:** on cloud-init images, changing `OS_HOSTNAME`, `OS_PASSWORD`, `OS_PUBKEY`, `PACKAGE_UPDATE`, or `DISPLAY_MODE` is applied on the **next restart** (the provisioning re-runs; the guest also regenerates its SSH host keys, so your SSH client will show a one-time host-key warning).
>
> **Pterodactyl "Disk Space"** (the container disk limit, in MiB) must be larger than `VM_DISK_GB` — the VM's `disk.qcow2` can grow up to `VM_DISK_GB`, and a server is stopped if it exceeds its Pterodactyl disk limit. For `VM_DISK_GB=20`, set Disk Space to ~`25000` MiB or `0` (unlimited).

> ⚠️ **Nested virtualization.** If your Pterodactyl **node is itself a virtual machine** (e.g. a VM from another VPS host), using hardware KVM inside it means *nested* virtualization, which on some hosts (notably certain AMD setups) is unstable and can **kernel-panic the whole node**. AeroVM guards against this: in the default `KVM=auto` mode it detects a virtualized node (via the CPU `hypervisor` flag) and automatically uses **software emulation** there, so it won't crash your node even with the KVM patch applied. Set `KVM=on` only to force nested KVM on a host you know supports it. On bare-metal nodes, `auto` uses KVM normally. Note: software emulation works but is **much slower** — heavy guests like Ubuntu Desktop are impractical without real KVM, so for performance run AeroVM on a bare-metal node.

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

> **Note:** `vnc`/`spice` (port `5900`), `novnc` (port `6080`), and `rdp` (port `3389`) all need their port assigned as an **Allocation** in the Pterodactyl panel, the same as `ADDITIONAL_PORTS` — QEMU listening on the port isn't enough if Docker/Wings hasn't also exposed it. The server's **primary** port must be a *different* port than these — AeroVM refuses to start otherwise, because the SSH forward would be unusable.

## How It Works

The container's entrypoint is [`scripts/start.sh`](scripts/start.sh), which runs every boot and builds the QEMU command line from the egg variables:

1. **Validate inputs** — integers are range-checked (and guarded against int64 overflow), `DISPLAY_MODE`/`IPV4_MODE`/`KVM` are checked against their allowed sets, the hostname against RFC 952/1123 label rules (1-63 letters/digits/hyphens, no leading/trailing hyphen), `OS_PASSWORD`/`OS_PUBKEY` are rejected if they contain newlines (they're embedded into cloud-init YAML), and configurations where the primary port would collide with the display port (5900/6080/3389) are rejected outright.
2. **Detect KVM** — if `/dev/kvm` is readable *and* writable (and the node isn't itself a VM, see the nested-virtualization note), QEMU runs with `-enable-kvm -cpu host`; otherwise it falls back to software emulation (`-cpu qemu64`). Disk I/O always uses `cache=writeback,aio=threads`. Either way the VM boots.
3. **Provision the disk** (`/home/container/disk.qcow2`, persisted across reboots):
   - *Blank-disk images*: create an empty `qcow2` of `VM_DISK_GB`.
   - *Cloud-init images*: copy the bundled cloud image (`/opt/base-image/base.qcow2`) and grow it to `VM_DISK_GB` (skipped if that's smaller than the image's own size).
4. **Build a cloud-init seed** (cloud-init images only) — a NoCloud `cidata` ISO (`meta-data` + `user-data`) is generated with `xorriso` and attached via `-cdrom`. It sets the hostname, the root password (`chpasswd`), an SSH key (if provided), and optional package upgrades. The instance-id is a hash of these settings, so unchanged settings never re-provision on restarts, while any change (e.g. a new password in the panel) gets a new instance-id and is applied on the next restart. An auto-generated password is persisted in `.aerovm-root-password` so it stays valid across boots. For a graphical `DISPLAY_MODE` it also creates an `aerovm` sudo user for the desktop session and runs a `runcmd` that installs XFCE + LightDM (plus `spice-vdagent` or `xrdp`) using the package manager for the image's `CLOUD_OS_FAMILY` (`debian`/`fedora`/`rhel`/`arch`).
   **Blank-disk images** instead attach `/home/container/os.iso` as a CD-ROM when present (downloading it first from `OS_ISO_URL` if set), and boot with `order=cd` so the firmware falls through to the installer while the disk is empty and boots the installed OS afterwards.
5. **Set up networking** — QEMU user-mode networking with `hostfwd` rules: the primary Pterodactyl port → guest `22`, plus RDP `3389` (rdp mode), the `1-1024` range (`IPV4_MODE=all`), and `ADDITIONAL_PORTS`. Ports the display already uses (5900/6080) and duplicates are skipped.
6. **Pick the display** — `ssh` uses the serial console (`-nographic -serial mon:stdio`); `vnc`/`novnc` use `-vga virtio` on VNC `:0` (5900), with `novnc` also launching a noVNC→VNC proxy on 6080; `spice` uses `-vga qxl` with `-spice`; `rdp`/`none` run headless.
7. **Launch QEMU** — `exec qemu-system-x86_64` with virtio disk/net, a memory balloon, a `virtio-rng` device (fast guest entropy — cuts first-boot time), optional `-bios` (OVMF, when `UEFI` is on), and optional `-smbios` (when `OVERWRITE_HOST` is set).

**KVM on the node (optional patch).** Wings starts each server container with an explicit numeric `uid:gid`, which makes Docker ignore the image's own group memberships — so just adding the container user to a `kvm` group in the Dockerfile isn't enough. The patch in [`wings-patch/`](wings-patch/) makes Wings map `/dev/kvm` into the container and add the host's real `kvm` group GID via Docker's `GroupAdd`, so the guest can actually open the device.

## Images & Versions

All images are published to `ghcr.io/sosuku325/aerovm:<tag>`.

| Tag | Base image | Bundled guest OS |
|-----|-----------|------------------|
| `alpine` | Alpine 3.19 | — (blank disk) |
| `ubuntu-22.04` / `ubuntu-24.04` / `ubuntu-26.04` | Ubuntu LTS | — (blank disk) |
| `guest-debian-10` … `guest-debian-13` | Alpine 3.19 | Debian 10 (buster, EOL) / 11 (bullseye) / 12 (bookworm) / 13 (trixie) cloud image |
| `guest-ubuntu-18.04` … `guest-ubuntu-24.04` | Alpine 3.19 | Ubuntu 18.04 (bionic, EOL) / 20.04 (focal) / 22.04 (jammy) / 24.04 (noble) cloud image |
| `guest-kali` | Alpine 3.19 | Kali Linux Rolling (GenericCloud, converted to qcow2 at build) |
| `guest-fedora` | Alpine 3.19 | Fedora Cloud Base 44 |
| `guest-arch` | Alpine 3.19 | Arch Linux (latest cloud image) |
| `guest-rockylinux` / `guest-almalinux` | Alpine 3.19 | Rocky Linux 9 / AlmaLinux 9 GenericCloud |
| `shell` | Alpine 3.19 | — (debug container: no VM, interactive shell with `qemu-img`/`xorriso`/`curl` for inspecting server files) |

> Debian 10/11 bundle an older cloud-init (20.x), so AeroVM automatically uses the legacy `chpasswd` format there (`CLOUD_INIT_LEGACY=1` baked into those images) — passwords work the same either way. The EOL images (Debian 10, Ubuntu 18.04) no longer receive upstream security updates; prefer a supported release unless you specifically need them.

Cloud-init images bundle the official upstream `qcow2`/`img` at build time, so no extra download happens when a server is created. Desktop sessions use **XFCE4 + LightDM** (with **xrdp** for RDP, **spice-vdagent** for SPICE).

## Project Structure

```
AeroVM/
├── egg/
│   └── egg-aerovm.json       # Pterodactyl egg (user-facing)
├── docker/
│   ├── Dockerfile.alpine               # Alpine-based image, blank disk (smallest)
│   ├── Dockerfile.ubuntu-{22,24,26}.04 # Ubuntu LTS images, blank disk
│   ├── Dockerfile.guest-debian-{10..13}    # Debian cloud images bundled, cloud-init
│   ├── Dockerfile.guest-ubuntu-{18..24}.04 # Ubuntu cloud images bundled, cloud-init
│   ├── Dockerfile.guest-kali           # Kali Linux cloud image bundled, cloud-init
│   ├── Dockerfile.guest-fedora         # Fedora Cloud image bundled, cloud-init
│   ├── Dockerfile.guest-arch           # Arch Linux cloud image bundled, cloud-init
│   ├── Dockerfile.guest-rockylinux     # Rocky Linux cloud image bundled, cloud-init
│   ├── Dockerfile.guest-almalinux      # AlmaLinux cloud image bundled, cloud-init
│   └── Dockerfile.shell                # Debug container (no VM, interactive shell)
├── scripts/
│   ├── start.sh              # VM startup script
│   └── shell.sh              # Entrypoint for the shell debug image
├── wings-patch/
│   ├── container.go.txt      # Patched Wings file (KVM support), for Wings v1.12+
│   ├── container_legacy.go.txt # Patched Wings file (KVM support), for Wings v1.11.x
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