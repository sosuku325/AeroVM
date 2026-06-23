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

OS_DISKSIZE="${OS_DISKSIZE:-20}"
MEMORY="${SERVER_MEMORY:-512}"
CPU_CORES="${SERVER_CPU_LIMIT:-1}"
SERVER_PORT="${SERVER_PORT:-2222}"
DISPLAY_MODE="${DISPLAY_MODE:-ssh}"
UEFI="${UEFI:-0}"
ADDITIONAL_PORTS="${ADDITIONAL_PORTS:-}"

validate_int "OS_DISKSIZE" "$OS_DISKSIZE" 1
validate_int "SERVER_MEMORY" "$MEMORY" 128
validate_int "SERVER_CPU_LIMIT" "$CPU_CORES" 1
validate_port "SERVER_PORT" "$SERVER_PORT"

case "$DISPLAY_MODE" in
    ssh|vnc|novnc|none) ;;
    *)
        echo "ERROR: DISPLAY_MODE must be one of: ssh, vnc, novnc, none" >&2
        exit 1
        ;;
esac



QEMU_ACCEL=()
AIO_MODE="threads"

if [ -r /dev/kvm ]; then
    QEMU_ACCEL=(-enable-kvm -cpu host)
    AIO_MODE="native"
    echo "INFO: KVM enabled"
else
    QEMU_ACCEL=(-cpu qemu64)
    echo "INFO: KVM not available, using software emulation"
fi



DISK_IMAGE="/home/container/disk.qcow2"

if [ ! -f "$DISK_IMAGE" ]; then
    qemu-img create -f qcow2 "$DISK_IMAGE" "${OS_DISKSIZE}G" \
        || { echo "ERROR: Failed to create disk image" >&2; exit 1; }
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



#Display
NOVNC_PORT=6080
NOVNC_PID=""

cleanup() {
    [ -n "$NOVNC_PID" ] && kill "$NOVNC_PID" 2>/dev/null || true
}
trap cleanup EXIT

build_display_opts() {
    case "$DISPLAY_MODE" in
        ssh)
            echo "-nographic -serial mon:stdio"
            ;;
        vnc)
            echo "-display vnc=:0 -vga virtio"
            ;;
        novnc)
            local novnc_bin=""
            for bin in novnc_server \
                       /usr/share/novnc/utils/novnc_proxy \
                       /usr/share/novnc/utils/launch.sh; do
                [ -x "$bin" ] && { novnc_bin="$bin"; break; }
            done
            [ -z "$novnc_bin" ] && { echo "ERROR: noVNC binary not found" >&2; exit 1; }
            "$novnc_bin" --listen "$NOVNC_PORT" --vnc localhost:5900 &
            NOVNC_PID=$!
            echo "-display vnc=:0 -vga virtio"
            ;;
        none)
            echo "-display none"
            ;;
    esac
}
read -ra DISPLAY_OPTS <<< "$(build_display_opts)"

#UEFI
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
    -m "${MEMORY}M" \
    -smp "${CPU_CORES}" \
    -drive "file=${DISK_IMAGE},format=qcow2,if=virtio,cache=writeback,aio=${AIO_MODE}" \
    "${NETDEV_OPTS[@]}" \
    "${DISPLAY_OPTS[@]}" \
    "${UEFI_OPTS[@]}" \
    -device virtio-balloon \
    -boot order=c \
    -no-reboot