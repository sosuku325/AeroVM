set -euo pipefail

WINGS_BIN="/usr/local/bin/wings"
WINGS_SERVICE="wings"
PATCH_URL="https://raw.githubusercontent.com/sosuku325/aerovm/main/wings-patch/container.go.patch"
WINGS_REPO="https://github.com/pterodactyl/wings"
GO_MIN_VERSION="1.21"

require_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo "ERROR: This script must be run as root" >&2
        exit 1
    fi
}

check_kvm() {
    if [ ! -e /dev/kvm ]; then
        echo "WARNING: /dev/kvm not found on this host"
        echo "         KVM patch will still be applied, but hardware acceleration"
        echo "         will not be available until KVM is enabled on the host."
    else
        echo "INFO: /dev/kvm found — KVM acceleration will be available"
    fi
}

check_go() {
    if ! command -v go &>/dev/null; then
        echo "ERROR: Go is not installed. Install Go >= ${GO_MIN_VERSION}" >&2
        echo "       https://go.dev/doc/install" >&2
        exit 1
    fi

    local version
    version=$(go version | grep -oP 'go\K[0-9]+\.[0-9]+')
    local major minor
    major=$(echo "$version" | cut -d. -f1)
    minor=$(echo "$version" | cut -d. -f2)
    local req_major req_minor
    req_major=$(echo "$GO_MIN_VERSION" | cut -d. -f1)
    req_minor=$(echo "$GO_MIN_VERSION" | cut -d. -f2)

    if [ "$major" -lt "$req_major" ] || { [ "$major" -eq "$req_major" ] && [ "$minor" -lt "$req_minor" ]; }; then
        echo "ERROR: Go >= ${GO_MIN_VERSION} required, found ${version}" >&2
        exit 1
    fi
    echo "INFO: Go ${version} found"
}

stop_wings() {
    if systemctl is-active --quiet "$WINGS_SERVICE" 2>/dev/null; then
        echo "INFO: Stopping Wings..."
        systemctl stop "$WINGS_SERVICE"
    fi
}

start_wings() {
    if systemctl is-enabled --quiet "$WINGS_SERVICE" 2>/dev/null; then
        echo "INFO: Starting Wings..."
        systemctl start "$WINGS_SERVICE"
    fi
}

backup_binary() {
    if [ -f "$WINGS_BIN" ]; then
        cp "$WINGS_BIN" "${WINGS_BIN}.bak.$(date +%Y%m%d%H%M%S)"
        echo "INFO: Backed up existing Wings binary"
    fi
}

build_patched_wings() {
    local workdir
    workdir=$(mktemp -d)
    trap "rm -rf $workdir" EXIT

    echo "INFO: Cloning Wings repository..."
    git clone --depth=1 "$WINGS_REPO" "$workdir/wings"

    echo "INFO: Applying KVM patch..."
    if ! patch -p1 -d "$workdir/wings" < <(curl -fsSL "$PATCH_URL"); then
        echo "ERROR: Failed to apply patch" >&2
        exit 1
    fi

    echo "INFO: Building Wings..."
    (cd "$workdir/wings" && go build -o wings .)

    echo "INFO: Installing patched Wings binary..."
    install -m 755 "$workdir/wings/wings" "$WINGS_BIN"

    echo "INFO: Build complete"
}

set_kvm_permissions() {
    if [ -e /dev/kvm ]; then
        chmod 660 /dev/kvm

        if ! grep -q 'KERNEL=="kvm"' /etc/udev/rules.d/99-aerovm-kvm.rules 2>/dev/null; then
            echo 'KERNEL=="kvm", MODE="0660"' > /etc/udev/rules.d/99-aerovm-kvm.rules
            udevadm control --reload-rules
            echo "INFO: KVM udev rules installed"
        fi
    fi
}

main() {
    require_root
    check_kvm
    check_go
    stop_wings
    backup_binary
    build_patched_wings
    set_kvm_permissions
    start_wings
    echo ""
    echo "INFO: AeroVM Wings patch installed successfully"
    echo "      To revert: restore the .bak binary and remove /etc/udev/rules.d/99-aerovm-kvm.rules"
}

main