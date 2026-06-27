#!/bin/bash
set -euo pipefail



validate_int() {
    local name="$1" value="$2" min="$3"
    if ! [[ "$value" =~ ^[0-9]+$ ]] || [ "$value" -lt "$min" ]; then
        echo "ERROR: $name must be an integer >= $min (got: '$value')" >&2
        exit 1
    fi
}

validate_port() {
    local name="$1" value="$2"
    validate_int "$name" "$value" 1
    if [ "$value" -gt 65535 ]; then
        echo "ERROR: $name must be <= 65535 (got: $value)" >&2
        exit 1
    fi
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

validate_int "VM_DISK_GB" "$VM_DISK_GB" 1
validate_int "VM_RAM_MB" "$VM_RAM_MB" 128
validate_int "VM_CPU_CORES" "$VM_CPU_CORES" 1

if [ "$VM_CPU_CORES" -gt 16 ]; then
    echo "ERROR: VM_CPU_CORES must be <= 16 (got: $VM_CPU_CORES)" >&2
    exit 1
fi
validate_port "SERVER_PORT" "$SERVER_PORT"

case "$DISPLAY_MODE" in
    ssh|vnc|novnc|none) ;;
    *)
        echo "ERROR: DISPLAY_MODE must be one of: ssh, vnc, novnc, none" >&2
        exit 1
        ;;
esac

if ! [[ "$OS_HOSTNAME" =~ ^[a-zA-Z0-9-]{1,63}$ ]]; then
    echo "ERROR: OS_HOSTNAME must be 1-63 characters of letters, numbers, and hyphens (got: '$OS_HOSTNAME')" >&2
    exit 1
fi



QEMU_ACCEL=()
AIO_MODE="threads"

if [ -r /dev/kvm ] && [ -w /dev/kvm ]; then
    QEMU_ACCEL=(-enable-kvm -cpu host)
    AIO_MODE="native"
    echo "INFO: KVM enabled"
else
    QEMU_ACCEL=(-cpu qemu64)
    echo "INFO: KVM not available, using software emulation"
fi



DISK_IMAGE="/home/container/disk.qcow2"
BASE_IMAGE="/opt/base-image/base.qcow2"
CLOUD_INIT_MODE=0
[ -f "$BASE_IMAGE" ] && CLOUD_INIT_MODE=1

if [ ! -f "$DISK_IMAGE" ]; then
    if [ "$CLOUD_INIT_MODE" -eq 1 ]; then
        echo "INFO: Provisioning disk from bundled cloud image"
        cp "$BASE_IMAGE" "$DISK_IMAGE" \
            || { echo "ERROR: Failed to copy base cloud image" >&2; exit 1; }

        current_bytes="$(qemu-img info "$DISK_IMAGE" | sed -n '/bytes)/{s/.*(\([0-9]*\) bytes).*/\1/p;q}')"
        requested_bytes=$(( VM_DISK_GB * 1024 * 1024 * 1024 ))
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

CDROM_OPTS=()
if [ "$CLOUD_INIT_MODE" -eq 1 ]; then
    SEED_ISO="/home/container/seed.iso"
    INSTANCE_ID_FILE="/home/container/.cloud-init-instance-id"

    if [ -f "$INSTANCE_ID_FILE" ]; then
        instance_id="$(cat "$INSTANCE_ID_FILE")"
    else
        instance_id="aerovm-$(tr -dc 'a-f0-9' </dev/urandom | head -c 16 || true)"
        echo "$instance_id" > "$INSTANCE_ID_FILE"
    fi

    password="$OS_PASSWORD"
    if [ -z "$password" ]; then
        password="$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 20 || true)"
        echo "INFO: OS_PASSWORD was empty, generated root password: ${password}"
    fi

    pkg_update="false"
    [ "$PACKAGE_UPDATE" = "1" ] && pkg_update="true"

    pwauth="true"
    ssh_keys_yaml=""
    if [ -n "$OS_PUBKEY" ]; then
        pwauth="false"
        ssh_keys_yaml=$'ssh_authorized_keys:\n  - "'"$(yaml_dquote "$OS_PUBKEY")"'"'
    fi

    seed_dir="$(mktemp -d)"
    hostname_esc="$(yaml_dquote "$OS_HOSTNAME")"
    password_esc="$(yaml_dquote "$password")"

    cat > "${seed_dir}/meta-data" <<EOF
instance-id: ${instance_id}
local-hostname: "${hostname_esc}"
EOF

    cat > "${seed_dir}/user-data" <<EOF
#cloud-config
hostname: "${hostname_esc}"
manage_etc_hosts: true
chpasswd:
  expire: false
password: "${password_esc}"
ssh_pwauth: ${pwauth}
package_update: ${pkg_update}
package_upgrade: ${pkg_update}
${ssh_keys_yaml}
EOF

    xorriso -as mkisofs -output "$SEED_ISO" -volid cidata -joliet -rock \
        "${seed_dir}/user-data" "${seed_dir}/meta-data" >/dev/null 2>&1 \
        || { echo "ERROR: Failed to build cloud-init seed image" >&2; exit 1; }

    rm -rf "$seed_dir"

    CDROM_OPTS=(-cdrom "$SEED_ISO")
fi



build_hostfwd() {
    local result=",hostfwd=tcp::${SERVER_PORT}-:22"
    [ -z "$ADDITIONAL_PORTS" ] && { echo "$result"; return; }

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
        if [ "$host_p" -gt 65535 ] || [ "$guest_p" -gt 65535 ]; then
            echo "WARNING: Skipping out-of-range port mapping: '$mapping'" >&2
            continue
        fi
        result="${result},hostfwd=tcp::${host_p}-:${guest_p}"
    done <<< "$(echo "$ADDITIONAL_PORTS" | tr ', ;' '\n')"

    echo "$result"
}

NETDEV_OPTS=(-netdev "user,id=net0$(build_hostfwd)" -device virtio-net-pci,netdev=net0)



NOVNC_PORT=6080
NOVNC_PID=""
NOVNC_LOG="/home/container/.novnc.log"

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
        vnc)
            echo "-display vnc=:0 -vga virtio"
            ;;
        novnc)
            echo "-display vnc=:0 -vga virtio"
            ;;
        none)
            echo "-display none"
            ;;
    esac
}

[ "$DISPLAY_MODE" = "novnc" ] && start_novnc

read -ra DISPLAY_OPTS <<< "$(build_display_opts)"


UEFI_OPTS=()
if [ "$UEFI" = "1" ]; then
    ovmf=""
    for path in /usr/share/ovmf/OVMF.fd \
                /usr/share/OVMF/OVMF.fd \
                /usr/share/edk2/ovmf/OVMF_CODE.fd; do
        [ -f "$path" ] && { ovmf="$path"; break; }
    done
    [ -z "$ovmf" ] && { echo "ERROR: UEFI=1 but OVMF firmware not found" >&2; exit 1; }
    UEFI_OPTS=(-bios "$ovmf")
fi



echo "Starting AeroVM"

exec qemu-system-x86_64 \
    "${QEMU_ACCEL[@]}" \
    -m "${VM_RAM_MB}M" \
    -smp "${VM_CPU_CORES}" \
    -drive "file=${DISK_IMAGE},format=qcow2,if=virtio,cache=writeback,aio=${AIO_MODE}" \
    "${NETDEV_OPTS[@]}" \
    "${DISPLAY_OPTS[@]}" \
    "${UEFI_OPTS[@]}" \
    "${CDROM_OPTS[@]}" \
    -device virtio-balloon \
    -boot order=c \
    -no-reboot