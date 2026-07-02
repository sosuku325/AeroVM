#!/bin/bash
set -euo pipefail



validate_int() {
    local name="$1" value="$2" min="$3" max="${4:-}"
    # Guard the digit count before any arithmetic: a value wider than int64
    # makes `[ -lt ]`/`[ -gt ]` error out, which would otherwise short-circuit
    # the check and let an absurd value slip through.
    if ! [[ "$value" =~ ^[0-9]{1,18}$ ]]; then
        echo "ERROR: $name must be an integer (got: '$value')" >&2
        exit 1
    fi
    if [ "$value" -lt "$min" ]; then
        echo "ERROR: $name must be >= $min (got: $value)" >&2
        exit 1
    fi
    if [ -n "$max" ] && [ "$value" -gt "$max" ]; then
        echo "ERROR: $name must be <= $max (got: $value)" >&2
        exit 1
    fi
}

validate_port() {
    validate_int "$1" "$2" 1 65535
}

# Pterodactyl's "boolean" rule accepts 1/0/true/false; accept the truthy forms
# case-insensitively so a panel value of "true" isn't silently treated as off.
is_truthy() {
    case "${1,,}" in
        1|true|yes|on) return 0 ;;
        *) return 1 ;;
    esac
}

yaml_dquote() {
    printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

VM_DISK_GB="${VM_DISK_GB:-20}"
VM_RAM_MB="${VM_RAM_MB:-512}"
VM_CPU_CORES="${VM_CPU_CORES:-1}"
SERVER_PORT="${SERVER_PORT:-2222}"
DISPLAY_MODE="${DISPLAY_MODE:-ssh}"
UEFI="${UEFI:-0}"
ADDITIONAL_PORTS="${ADDITIONAL_PORTS:-}"
OS_HOSTNAME="${OS_HOSTNAME:-aerovm}"
OS_PASSWORD="${OS_PASSWORD:-}"
OS_PUBKEY="${OS_PUBKEY:-}"
PACKAGE_UPDATE="${PACKAGE_UPDATE:-0}"
IPV4_MODE="${IPV4_MODE:-user}"
OVERWRITE_HOST="${OVERWRITE_HOST:-}"
OVERWRITE_IP="${OVERWRITE_IP:-}"
BANNER="${BANNER:-}"
CLOUD_OS_FAMILY="${CLOUD_OS_FAMILY:-}"
KVM="${KVM:-auto}"
OS_ISO_URL="${OS_ISO_URL:-}"

# Fixed container port the noVNC web server listens on (DISPLAY_MODE=novnc).
NOVNC_PORT=6080

# Maxes keep downstream arithmetic (e.g. disk bytes) well within int64 and
# reject nonsensical values before they reach QEMU.
validate_int "VM_DISK_GB" "$VM_DISK_GB" 1 1048576
validate_int "VM_RAM_MB" "$VM_RAM_MB" 128 16777216
validate_int "VM_CPU_CORES" "$VM_CPU_CORES" 1 16
validate_port "SERVER_PORT" "$SERVER_PORT"

case "$DISPLAY_MODE" in
    ssh|vnc|novnc|spice|rdp|none) ;;
    *)
        echo "ERROR: DISPLAY_MODE must be one of: ssh, vnc, novnc, spice, rdp, none" >&2
        exit 1
        ;;
esac

case "$IPV4_MODE" in
    disabled|user|all) ;;
    *)
        echo "ERROR: IPV4_MODE must be one of: disabled, user, all" >&2
        exit 1
        ;;
esac

case "$KVM" in
    auto|on|off) ;;
    *)
        echo "ERROR: KVM must be one of: auto, on, off" >&2
        exit 1
        ;;
esac

# RFC 952/1123: labels are letters/digits/hyphens, 1-63 chars, and must not
# start or end with a hyphen (guests reject such hostnames).
if ! [[ "$OS_HOSTNAME" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$ ]]; then
    echo "ERROR: OS_HOSTNAME must be 1-63 letters, numbers, and hyphens, and must not start or end with a hyphen (got: '$OS_HOSTNAME')" >&2
    exit 1
fi

if [[ "$OVERWRITE_HOST" == *","* ]] || [[ "$OVERWRITE_HOST" == *"\""* ]]; then
    echo "ERROR: OVERWRITE_HOST must not contain commas or quotes" >&2
    exit 1
fi

# OS_PASSWORD is written verbatim into a cloud-init chpasswd "user:password"
# line, which is newline-delimited, so a newline would corrupt the structure.
if [[ "$OS_PASSWORD" == *$'\n'* ]] || [[ "$OS_PASSWORD" == *$'\r'* ]]; then
    echo "ERROR: OS_PASSWORD must not contain newline characters" >&2
    exit 1
fi

# OS_PUBKEY is embedded in a double-quoted YAML scalar; a newline there would
# break the document.
if [[ "$OS_PUBKEY" == *$'\n'* ]] || [[ "$OS_PUBKEY" == *$'\r'* ]]; then
    echo "ERROR: OS_PUBKEY must not contain newline characters" >&2
    exit 1
fi

BASE_IMAGE="/opt/base-image/base.qcow2"
CLOUD_INIT_MODE=0
[ -f "$BASE_IMAGE" ] && CLOUD_INIT_MODE=1

if [ "$DISPLAY_MODE" = "rdp" ] && [ "$CLOUD_INIT_MODE" -ne 1 ]; then
    echo "ERROR: DISPLAY_MODE=rdp requires a cloud-init image (blank-disk images have no guest OS to provide RDP)" >&2
    exit 1
fi

# RDP needs host port 3389; if the primary (SSH) allocation is also 3389 the
# two forwards collide and RDP would be silently shadowed by SSH.
if [ "$DISPLAY_MODE" = "rdp" ] && [ "$((10#$SERVER_PORT))" -eq 3389 ]; then
    echo "ERROR: DISPLAY_MODE=rdp needs host port 3389, but the server's primary port is also 3389; assign a different primary port" >&2
    exit 1
fi

# vnc/novnc/spice bind fixed container ports for their display listeners. If
# the primary (SSH) allocation is one of those ports, the SSH hostfwd would be
# skipped as reserved and the VM would boot with no SSH access at all — fail
# loudly instead.
case "$DISPLAY_MODE" in
    vnc|spice)
        if [ "$((10#$SERVER_PORT))" -eq 5900 ]; then
            echo "ERROR: DISPLAY_MODE=${DISPLAY_MODE} uses port 5900 for the display, but the server's primary port is also 5900; assign a different primary port" >&2
            exit 1
        fi
        ;;
    novnc)
        if [ "$((10#$SERVER_PORT))" -eq 5900 ] || [ "$((10#$SERVER_PORT))" -eq "$NOVNC_PORT" ]; then
            echo "ERROR: DISPLAY_MODE=novnc uses ports 5900 and ${NOVNC_PORT}, but the server's primary port collides with one of them; assign a different primary port" >&2
            exit 1
        fi
        ;;
esac

needs_desktop=0
case "$DISPLAY_MODE" in
    vnc|novnc|spice|rdp) [ "$CLOUD_INIT_MODE" -eq 1 ] && needs_desktop=1 ;;
esac

if [ "$needs_desktop" -eq 1 ]; then
    case "$CLOUD_OS_FAMILY" in
        debian|fedora|rhel|arch) ;;
        *)
            echo "ERROR: DISPLAY_MODE=${DISPLAY_MODE} needs a desktop environment, but this image has no recognized CLOUD_OS_FAMILY ('${CLOUD_OS_FAMILY}')" >&2
            exit 1
            ;;
    esac
fi



QEMU_ACCEL=()

# Disk I/O is always cache=writeback + aio=threads. aio=native would need
# cache.direct=on (i.e. cache=none/O_DIRECT), which both conflicts with
# cache=writeback (QEMU refuses to start) and isn't supported on every node
# filesystem (e.g. some ZFS setups). threads works everywhere and the big KVM
# win is CPU virtualization below, not the disk AIO backend.
AIO_MODE="threads"
CACHE_MODE="writeback"

kvm_usable=0
if [ -r /dev/kvm ] && [ -w /dev/kvm ]; then
    kvm_usable=1
fi

# Detect whether the NODE itself is a VM. The container shares the host kernel,
# so /proc/cpuinfo shows the node's CPU flags; the "hypervisor" flag means the
# node is virtualized and using KVM here would be *nested* virtualization.
# Nested KVM (especially on AMD) can kernel-panic the whole node, so in auto
# mode we fall back to software emulation when nested. KVM=on overrides this for
# hosts known to support stable nested virt.
nested_virt=0
if grep -qw hypervisor /proc/cpuinfo 2>/dev/null; then
    nested_virt=1
fi

if [ "$KVM" = "off" ]; then
    QEMU_ACCEL=(-cpu qemu64)
    echo "INFO: KVM disabled (KVM=off), using software emulation"
elif [ "$KVM" = "on" ]; then
    if [ "$kvm_usable" -ne 1 ]; then
        echo "ERROR: KVM=on but /dev/kvm is not available/writable in the container" >&2
        echo "       Apply the Wings KVM patch (wings-patch/install.sh) or set KVM=auto/off" >&2
        exit 1
    fi
    QEMU_ACCEL=(-enable-kvm -cpu host)
    echo "INFO: KVM enabled (KVM=on)"
    [ "$nested_virt" -eq 1 ] && echo "WARNING: node appears virtualized; forced nested KVM (KVM=on) can crash the host if it doesn't support stable nested virtualization"
elif [ "$kvm_usable" -eq 1 ] && [ "$nested_virt" -eq 1 ]; then
    # /dev/kvm is available but the node is itself a VM — avoid risking a host
    # panic from nested KVM. Use software emulation; KVM=on forces KVM.
    QEMU_ACCEL=(-cpu qemu64)
    echo "INFO: node is virtualized (nested) — using software emulation to avoid host-crashing nested KVM. Set KVM=on to force KVM if your host supports stable nested virtualization."
elif [ "$kvm_usable" -eq 1 ]; then
    QEMU_ACCEL=(-enable-kvm -cpu host)
    echo "INFO: KVM enabled"
else
    QEMU_ACCEL=(-cpu qemu64)
    echo "INFO: KVM not available, using software emulation"
fi



DISK_IMAGE="/home/container/disk.qcow2"

if [ ! -f "$DISK_IMAGE" ]; then
    if [ "$CLOUD_INIT_MODE" -eq 1 ]; then
        echo "INFO: Provisioning disk from bundled cloud image"
        cp "$BASE_IMAGE" "$DISK_IMAGE" \
            || { echo "ERROR: Failed to copy base cloud image" >&2; exit 1; }

        current_bytes="$(qemu-img info "$DISK_IMAGE" | sed -n '/bytes)/{s/.*(\([0-9]*\) bytes).*/\1/p;q}')"
        [[ "$current_bytes" =~ ^[0-9]+$ ]] || current_bytes=0
        requested_bytes=$(( 10#$VM_DISK_GB * 1024 * 1024 * 1024 ))
        if [ "$requested_bytes" -gt "$current_bytes" ]; then
            qemu-img resize "$DISK_IMAGE" "${VM_DISK_GB}G" \
                || { echo "ERROR: Failed to resize disk image" >&2; exit 1; }
        else
            echo "INFO: VM_DISK_GB (${VM_DISK_GB}G) is not larger than the bundled image; keeping its original size"
        fi
    else
        qemu-img create -f qcow2 "$DISK_IMAGE" "${VM_DISK_GB}G" \
            || { echo "ERROR: Failed to create disk image" >&2; exit 1; }
    fi
fi

build_desktop_runcmd() {
    case "$CLOUD_OS_FAMILY" in
        debian)
            echo "  - apt-get update"
            echo "  - DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends xfce4 lightdm"
            [ "$DISPLAY_MODE" = "spice" ] && echo "  - DEBIAN_FRONTEND=noninteractive apt-get install -y spice-vdagent"
            if [ "$DISPLAY_MODE" = "rdp" ]; then
                echo "  - DEBIAN_FRONTEND=noninteractive apt-get install -y xrdp"
                echo "  - systemctl enable --now xrdp"
            fi
            ;;
        fedora)
            echo "  - dnf install -y xfce4-session lightdm"
            [ "$DISPLAY_MODE" = "spice" ] && echo "  - dnf install -y spice-vdagent"
            if [ "$DISPLAY_MODE" = "rdp" ]; then
                echo "  - dnf install -y xrdp"
                echo "  - systemctl enable --now xrdp"
            fi
            ;;
        rhel)
            echo "  - dnf install -y dnf-plugins-core epel-release"
            echo "  - dnf config-manager --set-enabled crb"
            echo "  - dnf install -y xfce4-session lightdm"
            [ "$DISPLAY_MODE" = "spice" ] && echo "  - dnf install -y spice-vdagent"
            if [ "$DISPLAY_MODE" = "rdp" ]; then
                echo "  - dnf install -y xrdp"
                echo "  - systemctl enable --now xrdp"
            fi
            ;;
        arch)
            echo "  - pacman -Syu --noconfirm xfce4 lightdm lightdm-gtk-greeter"
            [ "$DISPLAY_MODE" = "spice" ] && echo "  - pacman -S --noconfirm spice-vdagent"
            if [ "$DISPLAY_MODE" = "rdp" ]; then
                echo "  - pacman -S --noconfirm xrdp"
                echo "  - systemctl enable --now xrdp"
            fi
            ;;
    esac

    if [ "$DISPLAY_MODE" != "rdp" ]; then
        echo "  - systemctl enable lightdm"
        echo "  - systemctl set-default graphical.target || true"
    fi
}

CDROM_OPTS=()
BOOT_ORDER="c"
if [ "$CLOUD_INIT_MODE" -eq 1 ]; then
    if [ -n "$OS_ISO_URL" ]; then
        echo "WARNING: OS_ISO_URL is ignored on ready-to-use (cloud-init) images; it is only for the blank-disk images" >&2
    fi
    SEED_ISO="/home/container/seed.iso"
    GENERATED_PW_FILE="/home/container/.aerovm-root-password"

    password="$OS_PASSWORD"
    if [ -z "$password" ]; then
        # Persist the generated password: without this, every boot would print
        # a fresh random password that cloud-init never applies (provisioning
        # only runs when the instance-id changes), stranding the user with a
        # console full of passwords that don't work.
        if [ -f "$GENERATED_PW_FILE" ]; then
            password="$(cat "$GENERATED_PW_FILE")"
            echo "INFO: OS_PASSWORD is empty, using previously generated root password: ${password}"
        else
            password="$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 20 || true)"
            if [ -z "$password" ]; then
                echo "ERROR: Failed to generate a random root password" >&2
                exit 1
            fi
            (umask 077; printf '%s\n' "$password" > "$GENERATED_PW_FILE")
            echo "INFO: OS_PASSWORD was empty, generated root password: ${password}"
        fi
    fi

    pkg_update="false"
    is_truthy "$PACKAGE_UPDATE" && pkg_update="true"

    # Derive the instance-id from every setting that shapes the generated
    # user-data. cloud-init only re-runs per-instance provisioning (chpasswd,
    # hostname, users, write_files, runcmd) when the instance-id changes, so:
    #   same settings   -> same id -> restarts never re-provision;
    #   changed setting -> new id  -> the change is applied on next restart
    # (e.g. a new Root Password set in the panel actually takes effect).
    # Note: a changed id also makes the guest regenerate its SSH host keys,
    # so SSH clients will see a host-key warning after a settings change.
    instance_id="aerovm-$(printf '%s\n' "$OS_HOSTNAME" "$password" "$OS_PUBKEY" "$DISPLAY_MODE" "$pkg_update" "$CLOUD_OS_FAMILY" | sha256sum | cut -c1-16)"

    pwauth="true"
    root_keys_yaml=""
    if [ -n "$OS_PUBKEY" ]; then
        pwauth="false"
        root_keys_yaml=$'    ssh_authorized_keys:\n      - "'"$(yaml_dquote "$OS_PUBKEY")"'"'
    fi

    seed_dir="$(mktemp -d)"
    hostname_esc="$(yaml_dquote "$OS_HOSTNAME")"
    # The password is a double-quoted YAML scalar in the chpasswd.users list
    # below, so it IS yaml-escaped (correct for that context; the parser
    # un-escapes it back to the literal password).
    password_esc="$(yaml_dquote "$password")"

    desktop_users_yaml=""
    desktop_chpasswd_yaml=""
    if [ "$needs_desktop" -eq 1 ]; then
        desktop_users_yaml=$'  - name: aerovm\n    lock_passwd: false\n    sudo: ALL=(ALL) NOPASSWD:ALL\n    shell: /bin/bash'
        desktop_chpasswd_yaml="    - {name: aerovm, password: \"${password_esc}\", type: text}"
        echo "INFO: DISPLAY_MODE=${DISPLAY_MODE} requires a desktop environment; cloud-init will install it on first boot (may take a few minutes)"
    fi

    # Cloud images ship sshd with PermitRootLogin=prohibit-password, which blocks
    # logging in as root with a password even when ssh_pwauth is on. When we're
    # using password auth (no SSH key supplied), drop in a config enabling root
    # password login and restart sshd. With a key (pwauth=false) the default
    # prohibit-password already allows key login, so we leave sshd alone.
    write_files_yaml=""
    runcmd_body=""
    if [ "$pwauth" = "true" ]; then
        write_files_yaml=$'write_files:\n  - path: /etc/ssh/sshd_config.d/99-aerovm.conf\n    content: |\n      PermitRootLogin yes\n      PasswordAuthentication yes'
        runcmd_body=$'  - sed -i \'s/^#*PermitRootLogin.*/PermitRootLogin yes/\' /etc/ssh/sshd_config\n  - systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || true'
    fi
    if [ "$needs_desktop" -eq 1 ]; then
        [ -n "$runcmd_body" ] && runcmd_body+=$'\n'
        runcmd_body+="$(build_desktop_runcmd)"
    fi
    runcmd_yaml=""
    [ -n "$runcmd_body" ] && runcmd_yaml="runcmd:"$'\n'"$runcmd_body"

    cat > "${seed_dir}/meta-data" <<EOF
instance-id: ${instance_id}
local-hostname: "${hostname_esc}"
EOF

    cat > "${seed_dir}/user-data" <<EOF
#cloud-config
hostname: "${hostname_esc}"
manage_etc_hosts: true
disable_root: false
ssh_pwauth: ${pwauth}
package_update: ${pkg_update}
package_upgrade: ${pkg_update}
chpasswd:
  expire: false
  users:
    - {name: root, password: "${password_esc}", type: text}
${desktop_chpasswd_yaml}
users:
  - name: root
${root_keys_yaml}
${desktop_users_yaml}
${write_files_yaml}
${runcmd_yaml}
EOF

    xorriso -as mkisofs -output "$SEED_ISO" -volid cidata -joliet -rock \
        "${seed_dir}/user-data" "${seed_dir}/meta-data" >/dev/null 2>&1 \
        || { echo "ERROR: Failed to build cloud-init seed image" >&2; exit 1; }

    rm -rf "$seed_dir"

    CDROM_OPTS=(-cdrom "$SEED_ISO")
else
    # Blank-disk images: let the user boot an OS installer. Either they upload
    # an ISO as /home/container/os.iso themselves (SFTP / panel file manager),
    # or they set OS_ISO_URL and we download it once. With `-boot order=cd`
    # the BIOS tries the (empty) disk first and falls through to the installer
    # ISO; once an OS is installed, the disk boots even with the ISO attached.
    INSTALLER_ISO="/home/container/os.iso"

    if [ ! -f "$INSTALLER_ISO" ] && [ -n "$OS_ISO_URL" ]; then
        case "$OS_ISO_URL" in
            http://*|https://*) ;;
            *)
                echo "ERROR: OS_ISO_URL must be an http:// or https:// URL (got: '$OS_ISO_URL')" >&2
                exit 1
                ;;
        esac
        if ! command -v curl >/dev/null 2>&1; then
            echo "ERROR: curl is not available in this image; upload the installer as os.iso manually instead" >&2
            exit 1
        fi
        echo "INFO: Downloading installer ISO (this can take a while)..."
        echo "      ${OS_ISO_URL}"
        if ! curl -fL --retry 3 -o "${INSTALLER_ISO}.part" "$OS_ISO_URL"; then
            rm -f "${INSTALLER_ISO}.part"
            echo "ERROR: Failed to download the installer ISO from OS_ISO_URL" >&2
            exit 1
        fi
        mv "${INSTALLER_ISO}.part" "$INSTALLER_ISO"
        echo "INFO: Installer ISO saved as os.iso"
    fi

    if [ -f "$INSTALLER_ISO" ]; then
        CDROM_OPTS=(-cdrom "$INSTALLER_ISO")
        BOOT_ORDER="cd"
        echo "INFO: Installer ISO attached (os.iso). It boots while the disk is empty."
        echo "      After installing your OS, delete os.iso and clear OS_ISO_URL."
        case "$DISPLAY_MODE" in
            ssh|none)
                echo "WARNING: Most OS installers need a display; set DISPLAY_MODE to vnc or novnc to interact with the installer" >&2
                ;;
        esac
    fi
fi



build_hostfwd() {
    local result=""
    declare -A seen_host_ports=()
    declare -A reserved_ports=()

    # Ports the container itself binds for the chosen display mode. Forwarding
    # one of these via QEMU user-net would either collide with the display
    # listener (qemu refusing to start) or silently steal traffic from it, so
    # they must never become hostfwd rules.
    case "$DISPLAY_MODE" in
        vnc|spice) reserved_ports[5900]=1 ;;
        novnc)     reserved_ports[5900]=1; reserved_ports[$NOVNC_PORT]=1 ;;
    esac

    add_fwd() {
        local host_p="$1" guest_p="$2"
        if [ -n "${reserved_ports[$host_p]:-}" ]; then
            echo "WARNING: Skipping port ${host_p}: reserved by DISPLAY_MODE=${DISPLAY_MODE}" >&2
            return
        fi
        if [ -n "${seen_host_ports[$host_p]:-}" ]; then
            echo "WARNING: Skipping duplicate host port forward: ${host_p} (already forwarded to guest port ${seen_host_ports[$host_p]})" >&2
            return
        fi
        seen_host_ports[$host_p]="$guest_p"
        result="${result},hostfwd=tcp::${host_p}-:${guest_p}"
    }

    add_fwd "$SERVER_PORT" 22

    if [ "$DISPLAY_MODE" = "rdp" ]; then
        add_fwd 3389 3389
    fi

    if [ "$IPV4_MODE" = "all" ]; then
        echo "INFO: IPV4_MODE=all forwards ports 1-1024; this can noticeably slow down VM startup" >&2
        local p
        for ((p = 1; p <= 1024; p++)); do
            add_fwd "$p" "$p"
        done
    fi

    if [ "$IPV4_MODE" != "disabled" ] && [ -n "$ADDITIONAL_PORTS" ]; then
        local mapping host_p guest_p
        while IFS= read -r mapping; do
            [[ -z "$mapping" ]] && continue
            if [[ "$mapping" =~ ^([0-9]{1,5})-([0-9]{1,5})$ ]]; then
                host_p="${BASH_REMATCH[1]}"
                guest_p="${BASH_REMATCH[2]}"
            elif [[ "$mapping" =~ ^([0-9]{1,5})$ ]]; then
                host_p="${BASH_REMATCH[1]}"
                guest_p="$host_p"
            else
                echo "WARNING: Skipping invalid port mapping: '$mapping'" >&2
                continue
            fi
            if [ "$host_p" -lt 1 ] || [ "$host_p" -gt 65535 ] || [ "$guest_p" -lt 1 ] || [ "$guest_p" -gt 65535 ]; then
                echo "WARNING: Skipping out-of-range port mapping: '$mapping'" >&2
                continue
            fi
            add_fwd "$((10#$host_p))" "$((10#$guest_p))"
        done <<< "$(echo "$ADDITIONAL_PORTS" | tr ', ;' '\n')"
    fi

    echo "$result"
}

NOVNC_PID=""
NOVNC_LOG="/home/container/.novnc.log"

NETDEV_OPTS=(-netdev "user,id=net0$(build_hostfwd)" -device virtio-net-pci,netdev=net0)

cleanup() {
    [ -n "$NOVNC_PID" ] && kill "$NOVNC_PID" 2>/dev/null || true
}
trap cleanup EXIT

start_novnc() {
    local novnc_bin=""
    for bin in novnc_server \
               /usr/share/novnc/utils/novnc_proxy \
               /usr/share/novnc/utils/launch.sh; do
        if command -v "$bin" &>/dev/null || [ -x "$bin" ]; then
            novnc_bin="$bin"
            break
        fi
    done
    [ -z "$novnc_bin" ] && { echo "ERROR: noVNC binary not found" >&2; exit 1; }

    "$novnc_bin" --listen "$NOVNC_PORT" --vnc localhost:5900 >"$NOVNC_LOG" 2>&1 &
    NOVNC_PID=$!
}

build_display_opts() {
    case "$DISPLAY_MODE" in
        ssh)
            echo "-nographic -serial mon:stdio"
            ;;
        vnc|novnc)
            echo "-display vnc=:0 -vga virtio"
            ;;
        spice)
            echo "-spice port=5900,disable-ticketing=on -vga qxl"
            ;;
        rdp|none)
            echo "-display none"
            ;;
    esac
}

display_host_ref="${OVERWRITE_IP:-${SERVER_IP:-$(hostname)}}"
case "$DISPLAY_MODE" in
    novnc) echo "INFO: noVNC will be available at http://${display_host_ref}:${NOVNC_PORT}/vnc.html" ;;
    vnc|spice) echo "INFO: ${DISPLAY_MODE} will be available at ${display_host_ref}:5900" ;;
    rdp) echo "INFO: RDP will be available at ${display_host_ref}:3389 (user: aerovm)" ;;
esac

[ "$DISPLAY_MODE" = "novnc" ] && start_novnc

read -ra DISPLAY_OPTS <<< "$(build_display_opts)"


UEFI_OPTS=()
if is_truthy "$UEFI"; then
    # Only combined code+vars images (OVMF.fd) work with -bios. Split images
    # (OVMF_CODE.fd) need pflash drives and would silently fail to boot if
    # passed to -bios, so they are deliberately not in this list. Both image
    # bases (Ubuntu: /usr/share/ovmf, Alpine: /usr/share/OVMF) ship OVMF.fd.
    ovmf=""
    for path in /usr/share/ovmf/OVMF.fd \
                /usr/share/OVMF/OVMF.fd; do
        [ -f "$path" ] && { ovmf="$path"; break; }
    done
    [ -z "$ovmf" ] && { echo "ERROR: UEFI=1 but OVMF firmware (OVMF.fd) not found" >&2; exit 1; }
    UEFI_OPTS=(-bios "$ovmf")
fi

SMBIOS_OPTS=()
if [ -n "$OVERWRITE_HOST" ]; then
    SMBIOS_OPTS=(-smbios "type=1,manufacturer=${OVERWRITE_HOST},product=${OVERWRITE_HOST}")
fi



if [ -n "$BANNER" ]; then
    echo -e "${BANNER}"
fi

echo "Starting AeroVM"

exec qemu-system-x86_64 \
    "${QEMU_ACCEL[@]}" \
    -m "${VM_RAM_MB}M" \
    -smp "${VM_CPU_CORES}" \
    -drive "file=${DISK_IMAGE},format=qcow2,if=virtio,cache=${CACHE_MODE},aio=${AIO_MODE}" \
    "${NETDEV_OPTS[@]}" \
    "${DISPLAY_OPTS[@]}" \
    "${UEFI_OPTS[@]}" \
    "${SMBIOS_OPTS[@]}" \
    "${CDROM_OPTS[@]}" \
    -device virtio-balloon \
    -device virtio-rng-pci \
    -boot "order=${BOOT_ORDER}" \
    -no-reboot