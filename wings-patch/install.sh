#!/bin/bash
set -euo pipefail

WINGS_BIN="/usr/local/bin/wings"
WINGS_SERVICE="wings"
WINGS_REPO="https://github.com/pterodactyl/wings"
CONTAINER_GO_URL="https://raw.githubusercontent.com/sosuku325/aerovm/main/wings-patch/container.go.txt"
CONTAINER_GO_LEGACY_URL="https://raw.githubusercontent.com/sosuku325/aerovm/main/wings-patch/container_legacy.go.txt"
MIN_SUPPORTED_WINGS_VERSION="v1.11.9"

# Wings v1.12.0 switched its pinned docker/docker SDK from v25 to v28, which
# moved several option types (e.g. image.PullOptions, network.InspectOptions)
# into new subpackages. container.go targets the new SDK; container_legacy.go
# targets v1.11.x, which still uses the old "api/types" option types.
LEGACY_MINOR_VERSION="11"

# Minimum Go required to compile each Wings line (their go.mod "go" directive):
# v1.11.x needs Go 1.21, v1.12.0+ bumped it to 1.24. The right minimum is chosen
# from the detected Wings version in check_wings_version.
GO_LEGACY_VERSION="1.21"
GO_CURRENT_VERSION="1.24"
GO_MIN_VERSION=""

require_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo "ERROR: This script must be run as root" >&2
        exit 1
    fi
}

check_kvm() {
    if [ ! -e /dev/kvm ]; then
        echo "WARNING: /dev/kvm not found — KVM patch will be applied but hardware acceleration unavailable"
    else
        echo "INFO: /dev/kvm found — KVM acceleration will be available"
    fi
}

# Print copy-pasteable commands to install a new-enough Go, tailored to the CPU
# architecture and the required version. The distro's packaged Go is often too
# old (e.g. Ubuntu ships 1.22 while Wings v1.12+ needs 1.24), so this is the most
# common thing a user has to fix.
print_go_install_help() {
    local goarch tarball
    case "$(uname -m)" in
        x86_64)  goarch="amd64" ;;
        aarch64) goarch="arm64" ;;
        *)       goarch="amd64" ;;  # best-effort default
    esac
    tarball="go${GO_MIN_VERSION}.0.linux-${goarch}.tar.gz"
    echo "       Install Go >= ${GO_MIN_VERSION} (your distro's package is likely too old):" >&2
    echo "         rm -rf /usr/local/go" >&2
    echo "         curl -fsSL https://go.dev/dl/${tarball} -o /tmp/go.tar.gz" >&2
    echo "         tar -C /usr/local -xzf /tmp/go.tar.gz" >&2
    echo "         export PATH=/usr/local/go/bin:\$PATH" >&2
    echo "       Then re-run this installer in the same shell. (newer Go is fine too: https://go.dev/dl/)" >&2
}

check_go() {
    if ! command -v go &>/dev/null; then
        echo "ERROR: Go is not installed." >&2
        print_go_install_help
        exit 1
    fi

    local version
    version=$(go version | grep -oP 'go\K[0-9]+\.[0-9]+')
    local major minor req_major req_minor
    major=$(echo "$version" | cut -d. -f1)
    minor=$(echo "$version" | cut -d. -f2)
    req_major=$(echo "$GO_MIN_VERSION" | cut -d. -f1)
    req_minor=$(echo "$GO_MIN_VERSION" | cut -d. -f2)

    if [ "$major" -lt "$req_major" ] || { [ "$major" -eq "$req_major" ] && [ "$minor" -lt "$req_minor" ]; }; then
        echo "ERROR: Go >= ${GO_MIN_VERSION} required, found ${version}" >&2
        print_go_install_help
        exit 1
    fi
    echo "INFO: Go ${version} found"
}

WINGS_VERSION=""
CONTAINER_GO_SELECTED_URL=""

check_wings_version() {
    if [ ! -f "$WINGS_BIN" ]; then
        echo "ERROR: Wings binary not found at ${WINGS_BIN}" >&2
        echo "       Install Wings first: https://pterodactyl.io/wings/1.0/installing.html" >&2
        exit 1
    fi

    # Wings exposes its version via the `version` subcommand (prints "wings vX.Y.Z");
    # it has no --version flag. Fall back to --version just in case a future build
    # adds one.
    WINGS_VERSION=$({ "$WINGS_BIN" version 2>/dev/null || "$WINGS_BIN" --version 2>/dev/null || true; } | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)

    if [ -z "$WINGS_VERSION" ]; then
        echo "ERROR: Could not determine Wings version (tried '${WINGS_BIN} version')" >&2
        exit 1
    fi

    echo "INFO: Wings version: ${WINGS_VERSION}"

    local major minor
    major=$(echo "$WINGS_VERSION" | grep -oP '(?<=v)[0-9]+' )
    minor=$(echo "$WINGS_VERSION" | cut -d. -f2)

    if [ "$major" -lt 1 ] || { [ "$major" -eq 1 ] && [ "$minor" -lt "$LEGACY_MINOR_VERSION" ]; }; then
        echo "ERROR: Unsupported Wings version: ${WINGS_VERSION}" >&2
        echo "       AeroVM supports Wings >= ${MIN_SUPPORTED_WINGS_VERSION}" >&2
        echo "       Upgrade Wings before applying this patch" >&2
        exit 1
    fi

    if [ "$major" -eq 1 ] && [ "$minor" -eq "$LEGACY_MINOR_VERSION" ]; then
        echo "INFO: Wings v1.${LEGACY_MINOR_VERSION}.x detected, using legacy docker SDK patch"
        CONTAINER_GO_SELECTED_URL="$CONTAINER_GO_LEGACY_URL"
        GO_MIN_VERSION="$GO_LEGACY_VERSION"
    else
        echo "INFO: Wings v1.$((LEGACY_MINOR_VERSION + 1))+ detected, using current docker SDK patch"
        CONTAINER_GO_SELECTED_URL="$CONTAINER_GO_URL"
        GO_MIN_VERSION="$GO_CURRENT_VERSION"
    fi

    echo "INFO: Wings version check passed (requires Go >= ${GO_MIN_VERSION})"
}

WORKDIR=""
WINGS_WAS_ACTIVE=0

cleanup() {
    [ -n "$WORKDIR" ] && rm -rf "$WORKDIR"
    # Safety net: if we stopped Wings and it isn't running again (e.g. the build
    # or install failed partway), bring it back so a failed patch never leaves
    # the node's Wings down.
    if [ "$WINGS_WAS_ACTIVE" -eq 1 ] && ! systemctl is-active --quiet "$WINGS_SERVICE" 2>/dev/null; then
        echo "INFO: Restarting Wings (recovering from incomplete patch)..." >&2
        systemctl start "$WINGS_SERVICE" || true
    fi
}
trap cleanup EXIT

stop_wings() {
    if systemctl is-active --quiet "$WINGS_SERVICE" 2>/dev/null; then
        WINGS_WAS_ACTIVE=1
        echo "INFO: Stopping Wings..."
        systemctl stop "$WINGS_SERVICE"
    fi
}

start_wings() {
    # Restart if it was running before, or if it's enabled to run at boot.
    if [ "$WINGS_WAS_ACTIVE" -eq 1 ] || systemctl is-enabled --quiet "$WINGS_SERVICE" 2>/dev/null; then
        echo "INFO: Starting Wings..."
        systemctl start "$WINGS_SERVICE"
    fi
}

backup_binary() {
    local backup="${WINGS_BIN}.bak.$(date +%Y%m%d%H%M%S)"
    cp "$WINGS_BIN" "$backup"
    echo "INFO: Backed up existing Wings binary to ${backup}"
}

# Clone + patch + compile the new binary BEFORE touching the running service,
# so a build failure aborts with Wings still up and the old binary intact.
build_patched_wings() {
    WORKDIR=$(mktemp -d)

    echo "INFO: Cloning Wings ${WINGS_VERSION}..."
    git clone --depth=1 --branch "$WINGS_VERSION" "$WINGS_REPO" "$WORKDIR/wings"

    echo "INFO: Downloading patched container.go..."
    # The overlay is stored as container.go.txt in the repo (so local Go tooling
    # ignores it); write it into the Wings tree as container.go to compile.
    curl -fsSL "$CONTAINER_GO_SELECTED_URL" -o "$WORKDIR/wings/environment/docker/container.go"

    echo "INFO: Building Wings..."
    (cd "$WORKDIR/wings" && go build -o wings .)

    echo "INFO: Build complete"
}

install_patched_wings() {
    echo "INFO: Installing patched Wings binary..."
    install -m 755 "$WORKDIR/wings/wings" "$WINGS_BIN"
}

set_kvm_permissions() {
    if [ -e /dev/kvm ]; then
        chgrp kvm /dev/kvm 2>/dev/null || true
        chmod 660 /dev/kvm

        if ! grep -q 'KERNEL=="kvm"' /etc/udev/rules.d/99-aerovm-kvm.rules 2>/dev/null; then
            echo 'KERNEL=="kvm", GROUP="kvm", MODE="0660"' > /etc/udev/rules.d/99-aerovm-kvm.rules
            udevadm control --reload-rules
            echo "INFO: KVM udev rules installed"
        fi
    fi
}

main() {
    require_root
    check_kvm
    # Detect the Wings version first: it determines which patch to use AND the
    # minimum Go version required to compile that Wings release.
    check_wings_version
    check_go
    build_patched_wings
    stop_wings
    backup_binary
    install_patched_wings
    set_kvm_permissions
    start_wings
    echo ""
    echo "INFO: AeroVM Wings patch installed successfully"
    echo "      To revert: restore the .bak binary and remove /etc/udev/rules.d/99-aerovm-kvm.rules"
}

main