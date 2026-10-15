#!/usr/bin/with-contenv bashio
# shellcheck shell=bash

# Install Home Assistant CLI to persistent storage
# Downloads the official ha CLI binary from GitHub releases

set -e

PERSIST_BIN="/data/packages/bin"
HA_VERSION="4.42.0"
BASE_URL="https://github.com/home-assistant/cli/releases/download/${HA_VERSION}"

# Detect architecture
detect_arch() {
    local machine
    machine=$(uname -m)

    case "$machine" in
        x86_64)
            echo "amd64"
            ;;
        aarch64)
            echo "aarch64"
            ;;
        armv7l)
            echo "armv7"
            ;;
        armv6l)
            echo "armhf"
            ;;
        i386|i686)
            echo "i386"
            ;;
        *)
            bashio::log.error "Unsupported architecture: $machine"
            return 1
            ;;
    esac
}

# Install ha CLI binary
install_ha_cli() {
    local arch
    arch=$(detect_arch)
    local download_url="${BASE_URL}/ha_${arch}"
    local target_path="${PERSIST_BIN}/ha"

    bashio::log.info "Installing Home Assistant CLI v${HA_VERSION} for ${arch}..."

    # Create persistent bin directory if it doesn't exist
    mkdir -p "$PERSIST_BIN"

    # Download the binary
    bashio::log.info "Downloading from: ${download_url}"
    if ! curl -fsSL -o "${target_path}" "${download_url}"; then
        bashio::log.error "Failed to download ha CLI binary"
        return 1
    fi

    # Make it executable
    chmod +x "${target_path}"

    # Verify it works
    if "${target_path}" --version >/dev/null 2>&1; then
        bashio::log.info "✓ Home Assistant CLI installed successfully!"
        "${target_path}" --version
        bashio::log.info "Location: ${target_path}"
    else
        bashio::log.error "Downloaded binary is not working"
        rm -f "${target_path}"
        return 1
    fi
}

# Main execution
main() {
    # Check if already installed
    if [ -x "${PERSIST_BIN}/ha" ]; then
        bashio::log.info "Home Assistant CLI is already installed"
        "${PERSIST_BIN}/ha" --version
        bashio::log.info "Use 'ha --help' to see available commands"
        exit 0
    fi

    # Install it
    if install_ha_cli; then
        bashio::log.info ""
        bashio::log.info "════════════════════════════════════════"
        bashio::log.info "Home Assistant CLI is ready to use!"
        bashio::log.info "════════════════════════════════════════"
        bashio::log.info ""
        bashio::log.info "Try these commands:"
        bashio::log.info "  ha core info"
        bashio::log.info "  ha addons list"
        bashio::log.info "  ha network info"
        bashio::log.info "  ha supervisor info"
        bashio::log.info ""
    else
        bashio::log.error "Failed to install Home Assistant CLI"
        exit 1
    fi
}

# Run if executed directly
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    main "$@"
fi
