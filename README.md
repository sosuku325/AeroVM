<div align="center">

# AeroVM

[![License](https://img.shields.io/github/license/sosuku325/aerovm?style=for-the-badge)](LICENSE)
[![GitHub Stars](https://img.shields.io/github/stars/sosuku325/aerovm?style=for-the-badge)](https://github.com/sosuku325/aerovm/stargazers)
[![GitHub Issues](https://img.shields.io/github/issues/sosuku325/aerovm?style=for-the-badge)](https://github.com/sosuku325/aerovm/issues)

**Lightweight, free, open-source QEMU-based VM egg for Pterodactyl**

Works without KVM. Faster with KVM.

[Quick Start](#quick-start) • [KVM Setup](#kvm-setup-optional) • [Variables](#egg-variables) • [Contributing](#contributing)

</div>

---

## Features

- **Free & open source** — no license keys, no paywalls
- **KVM hybrid** — runs on software emulation by default; hardware acceleration when KVM is available
- **Lightweight** — optimized QEMU flags, minimal Docker image (Alpine-based)
- **Pterodactyl native** — one egg import, no panel modifications required

## Requirements

| Component | Minimum |
|-----------|---------|
| Pterodactyl Panel | 1.11.x |
| Wings | v1.11.9 |
| Docker | 20.x+ |
| Host OS | Linux (KVM-capable for acceleration) |

## Quick Start

**1. Download the egg**

Download [`egg-aerovm.json`](egg/egg-aerovm.json) from this repository.

**2. Import to Pterodactyl**

Navigate to **Admin → Nests → Import Egg** and upload the file.

**3. Create a server**

Create a new server using the AeroVM egg. Configure RAM, CPU, and disk via the egg variables. Start the server — the VM will boot automatically.

> **Note:** `ADDITIONAL_PORTS` requires the ports to also be assigned as **Allocations** in the Pterodactyl panel. QEMU-side forwarding alone is not enough; Docker must also expose the port.

## KVM Setup (Optional)

Without KVM, AeroVM runs in software emulation mode. This works but is slower. Applying the Wings KVM patch enables hardware acceleration.

**Prerequisites:** Go >= 1.21, Wings v1.11.9, root access

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/sosuku325/aerovm/main/wings-patch/install.sh)
```

The script will:
1. Verify Wings v1.11.9 is installed
2. Stop Wings
3. Clone Wings source and replace `container.go` with the KVM-patched version
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

## Egg Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `VM_RAM_MB` | RAM allocated to the VM (MB) | `512` |
| `VM_CPU_CORES` | vCPU cores (max 16) | `1` |
| `VM_DISK_GB` | Virtual disk size (GB) | `20` |
| `DISPLAY_MODE` | `ssh` / `vnc` / `novnc` / `none` | `ssh` |
| `ADDITIONAL_PORTS` | Extra port forwards (e.g. `8080-80,443`) | — |
| `UEFI` | Enable UEFI firmware (`0` or `1`) | `0` |

> `VM_RAM_MB` and `VM_CPU_CORES` are independent of Pterodactyl's resource limits. Set them to values your node can actually support.

## Display Modes

| Mode | Description |
|------|-------------|
| `ssh` | SSH via the server's primary Pterodactyl port |
| `vnc` | Raw VNC on port 5900 |
| `novnc` | Browser-based VNC on port 6080 |
| `none` | Headless — no display output |

## Project Structure

```
AeroVM/
├── egg/
│   └── egg-aerovm.json       # Pterodactyl egg (user-facing)
├── docker/
│   └── Dockerfile.alpine     # Docker image definition
├── scripts/
│   └── start.sh              # VM startup script
├── wings-patch/
│   ├── container.go          # Patched Wings file (KVM support)
│   └── install.sh            # One-command KVM patch installer
└── .github/workflows/
    └── build.yml             # Auto-build and push to ghcr.io
```

## Contributing

PRs and issues are welcome.

1. Fork the repository
2. Create a feature branch
3. Commit your changes
4. Open a pull request

## License

MIT — see [LICENSE](LICENSE)