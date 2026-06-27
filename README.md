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
- **Lightweight** — optimized QEMU flags, minimal Docker image (Alpine-based)
- **Pterodactyl native** — one egg import, no panel modifications required
- **Two ways to provision**: bring your own OS on a blank disk, or pick a cloud-init image (Debian, Ubuntu, Fedora, Arch, Rocky, AlmaLinux) that's ready to log into on first boot
- **SSH, VNC, noVNC, SPICE, or RDP** — cloud-init images can auto-provision a lightweight desktop for the latter four

## Requirements

| Component | Minimum |
|-----------|---------|
| Pterodactyl Panel | 1.11.x |
| Wings | v1.11.9+ |
| Docker | 20.x+ |
| Host OS | Linux (KVM-capable for acceleration) |

## Quick Start

**1. (Optional, recommended) Enable KVM on the node**

Run this once on each Wings node, before importing the egg, to get hardware-accelerated VMs. Without it, AeroVM still works, just slower (software emulation).

**Prerequisites:** Go >= 1.21, Wings v1.11.9 or newer, root access

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/sosuku325/aerovm/main/wings-patch/install.sh)
```

The script will:
1. Detect the installed Wings version (v1.11.9+ supported)
2. Stop Wings
3. Clone the matching Wings source tag and replace `container.go` with the KVM-patched version for that Wings release (`container.go` for v1.12+, `container_legacy.go` for v1.11.x — Wings v1.12 changed its pinned Docker SDK, which moved several option types into new packages)
4. Build and install the patched binary
5. Set `/dev/kvm` permissions persistently
6. Restart Wings

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

## Display Modes

| Mode | Description |
|------|-------------|
| `ssh` | SSH via the server's primary Pterodactyl port |
| `vnc` | Raw VNC on port 5900 |
| `novnc` | Browser-based VNC on port 6080 |
| `spice` | SPICE protocol on port 5900 (connect with a native SPICE client) |
| `rdp` | RDP on port 3389 — **cloud-init images only**, logs in as the `aerovm` user |
| `none` | Headless — no display output |

On a cloud-init image, choosing `vnc`/`novnc`/`spice`/`rdp` makes cloud-init install a lightweight XFCE desktop (and xrdp, for `rdp`) on first boot — this adds a few minutes before the desktop is usable. On blank-disk images, `vnc`/`novnc`/`spice` just show the VM's console/installer screen (no OS to provision yet), and `rdp` isn't available.

> **Note:** `vnc`/`spice` (port `5900`), `novnc` (port `6080`), and `rdp` (port `3389`) all need their port assigned as an **Allocation** in the Pterodactyl panel, the same as `ADDITIONAL_PORTS` — QEMU listening on the port isn't enough if Docker/Wings hasn't also exposed it.

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
└── .github/workflows/
    └── build.yml             # Auto-build and push to ghcr.io
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