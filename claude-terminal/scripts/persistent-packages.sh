#!/usr/bin/with-contenv bashio

# Persistent Package Manager for Claude Terminal
# Installs packages to /data (persistent storage) instead of ephemeral container

set -e

PERSIST_ROOT="/data/packages"
PERSIST_BIN="$PERSIST_ROOT/bin"
PERSIST_LIB="$PERSIST_ROOT/lib"
PERSIST_PYTHON="$PERSIST_ROOT/python"
PERSIST_APK_CACHE="$PERSIST_ROOT/apk-cache"

# Initialize persistent package directories
init_persistent_storage() {
    bashio::log.info "Initializing persistent package storage..."

    mkdir -p "$PERSIST_BIN" \
             "$PERSIST_LIB" \
             "$PERSIST_PYTHON" \
             "$PERSIST_APK_CACHE"

    chmod 755 "$PERSIST_ROOT" "$PERSIST_BIN" "$PERSIST_LIB" "$PERSIST_PYTHON"

    # Setup Python virtual environment in persistent storage
    if [ ! -d "$PERSIST_PYTHON/venv" ]; then
        bashio::log.info "Creating persistent Python virtual environment..."
        python3 -m venv "$PERSIST_PYTHON/venv"
    fi

    bashio::log.info "Persistent storage ready at: $PERSIST_ROOT"
}

# Setup environment variables for persistent packages
setup_environment() {
    # Add persistent bin to PATH (highest priority)
    export PATH="$PERSIST_BIN:$PERSIST_PYTHON/venv/bin:$PATH"

    # Library paths for compiled binaries
    export LD_LIBRARY_PATH="$PERSIST_LIB:${LD_LIBRARY_PATH:-}"

    # Python virtual environment
    export VIRTUAL_ENV="$PERSIST_PYTHON/venv"

    # PKG_CONFIG for building packages
    export PKG_CONFIG_PATH="$PERSIST_LIB/pkgconfig:${PKG_CONFIG_PATH:-}"

    bashio::log.info "Environment configured for persistent packages"
}

# Install APK package to persistent storage (via bind mount trick)
persist_apk_install() {
    local packages="$@"

    if [ -z "$packages" ]; then
        bashio::log.error "No packages specified"
        return 1
    fi

    bashio::log.info "Installing APK packages to persistent storage: $packages"

    # Install to system first (needed for dependencies)
    apk add --no-cache $packages

    # Copy installed binaries to persistent storage
    for pkg in $packages; do
        # Find which files were installed by this package
        local pkg_files=$(apk info -L "$pkg" 2>/dev/null || echo "")

        if [ -n "$pkg_files" ]; then
            echo "$pkg_files" | while read -r file; do
                # Copy executables to persistent bin
                if [[ "$file" == /usr/bin/* ]] || [[ "$file" == /usr/sbin/* ]]; then
                    if [ -f "$file" ] && [ -x "$file" ]; then
                        cp -a "$file" "$PERSIST_BIN/"
                        bashio::log.info "  Copied: $file -> $PERSIST_BIN/"
                    fi
                fi

                # Copy libraries to persistent lib
                if [[ "$file" == /usr/lib/* ]] && [[ "$file" == *.so* ]]; then
                    if [ -f "$file" ]; then
                        cp -a "$file" "$PERSIST_LIB/"
                    fi
                fi
            done
        fi
    done

    bashio::log.info "APK packages installed and persisted successfully"
}

# Install Python package to persistent virtual environment
persist_pip_install() {
    local packages="$@"

    if [ -z "$packages" ]; then
        bashio::log.error "No packages specified"
        return 1
    fi

    bashio::log.info "Installing Python packages to persistent venv: $packages"

    # Activate venv and install
    source "$PERSIST_PYTHON/venv/bin/activate"
    pip install --upgrade pip
    pip install $packages

    bashio::log.info "Python packages installed successfully"
}

# Auto-install packages from configuration
auto_install_packages() {
    local apk_packages=$(bashio::config 'persistent_apk_packages' '[]')
    local pip_packages=$(bashio::config 'persistent_pip_packages' '[]')

    # Parse and install APK packages
    if [ "$apk_packages" != "[]" ] && [ "$apk_packages" != "" ]; then
        bashio::log.info "Auto-installing APK packages from config..."
        local pkg_list=$(echo "$apk_packages" | jq -r '.[]' | tr '\n' ' ')
        if [ -n "$pkg_list" ]; then
            persist_apk_install $pkg_list
        fi
    fi

    # Parse and install Python packages
    if [ "$pip_packages" != "[]" ] && [ "$pip_packages" != "" ]; then
        bashio::log.info "Auto-installing Python packages from config..."
        local pkg_list=$(echo "$pip_packages" | jq -r '.[]' | tr '\n' ' ')
        if [ -n "$pkg_list" ]; then
            persist_pip_install $pkg_list
        fi
    fi
}

# Show installed persistent packages
list_persistent_packages() {
    echo "=== Persistent Packages ==="
    echo ""
    echo "Binaries in $PERSIST_BIN:"
    ls -lh "$PERSIST_BIN" 2>/dev/null || echo "  (none)"
    echo ""
    echo "Python packages in virtual environment:"
    source "$PERSIST_PYTHON/venv/bin/activate"
    pip list
}

# Main execution when sourced
case "${1:-init}" in
    init)
        init_persistent_storage
        setup_environment
        auto_install_packages
        ;;
    install-apk)
        shift
        persist_apk_install "$@"
        ;;
    install-pip)
        shift
        persist_pip_install "$@"
        ;;
    list)
        list_persistent_packages
        ;;
    env)
        setup_environment
        ;;
    *)
        bashio::log.error "Unknown command: $1"
        echo "Usage: $0 {init|install-apk|install-pip|list|env}"
        exit 1
        ;;
esac
