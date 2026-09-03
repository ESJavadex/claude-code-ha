#!/usr/bin/with-contenv bashio

# Enable strict error handling
set -e
set -o pipefail

# Initialize environment for Claude Code CLI using /data (HA best practice)
init_environment() {
    # Use /data exclusively - guaranteed writable by HA Supervisor
    local data_home="/data/home"
    local config_dir="/data/.config"
    local cache_dir="/data/.cache"
    local state_dir="/data/.local/state"
    local claude_config_dir="/data/.config/claude"
    local gh_config_dir="/data/.config/gh"
    local persist_root="/data/packages"
    local persist_bin="$persist_root/bin"
    local persist_lib="$persist_root/lib"
    local persist_python="$persist_root/python"

    bashio::log.info "Initializing Claude Code environment in /data..."

    # Create all required directories
    if ! mkdir -p "$data_home" "$config_dir/claude" "$config_dir/gh" "$cache_dir" "$state_dir" "/data/.local" \
                  "$persist_bin" "$persist_lib" "$persist_python"; then
        bashio::log.error "Failed to create directories in /data"
        exit 1
    fi

    # Set permissions
    chmod 755 "$data_home" "$config_dir" "$cache_dir" "$state_dir" "$claude_config_dir" "$gh_config_dir" \
              "$persist_root" "$persist_bin" "$persist_lib" "$persist_python"

    # Ensure Claude native binary is available at $HOME/.local/bin/claude
    # The native installer places it at /root/.local/bin/claude during Docker build,
    # but at runtime HOME=/data/home, so Claude's self-check looks in /data/home/.local/bin/
    local native_bin_dir="$data_home/.local/bin"
    if [ ! -d "$native_bin_dir" ]; then
        mkdir -p "$native_bin_dir"
    fi
    if [ -f /root/.local/bin/claude ] && [ ! -f "$native_bin_dir/claude" ]; then
        ln -sf /root/.local/bin/claude "$native_bin_dir/claude"
        bashio::log.info "  - Claude native binary linked: $native_bin_dir/claude"
    fi

    # Set XDG and application environment variables
    export HOME="$data_home"
    export XDG_CONFIG_HOME="$config_dir"
    export XDG_CACHE_HOME="$cache_dir"
    export XDG_STATE_HOME="$state_dir"
    export XDG_DATA_HOME="/data/.local/share"

    # Claude-specific environment variables
    export ANTHROPIC_CONFIG_DIR="$claude_config_dir"
    export ANTHROPIC_HOME="/data"

    # Disable auto-updates: binary is baked into the container image,
    # updates are delivered via add-on releases, not CLI self-update
    export DISABLE_AUTOUPDATER=1

    # GitHub CLI persistent configuration
    export GH_CONFIG_DIR="$gh_config_dir"

    # Get dangerously-skip-permissions configuration
    local dangerously_skip_permissions
    dangerously_skip_permissions=$(bashio::config 'dangerously_skip_permissions' 'false')
    export CLAUDE_DANGEROUS_MODE="$dangerously_skip_permissions"

    # This addon always runs as root inside an HA supervisor container.
    # IS_SANDBOX=1 tells Claude Code that root is expected (container sandbox),
    # so it won't refuse to start. This is independent of --dangerously-skip-permissions
    # (which controls permission prompts, not whether Claude can launch).
    export IS_SANDBOX=1

    # Setup persistent package paths (HIGHEST PRIORITY)
    export PATH="$persist_bin:$persist_python/venv/bin:$data_home/.local/bin:$PATH"
    export LD_LIBRARY_PATH="$persist_lib:${LD_LIBRARY_PATH:-}"
    export PKG_CONFIG_PATH="$persist_lib/pkgconfig:${PKG_CONFIG_PATH:-}"

    # Python virtual environment if it exists
    if [ -d "$persist_python/venv" ]; then
        export VIRTUAL_ENV="$persist_python/venv"
        bashio::log.info "  - Python venv: active"
    fi

    # Create profile script for persistent environment variables
    # This ensures ALL bash sessions (including ttyd shells) have correct PATH
    cat > /etc/profile.d/persistent-packages.sh << 'PROFILE_EOF'
# Persistent package environment - auto-loaded for all bash sessions
export HOME="/data/home"
export XDG_CONFIG_HOME="/data/.config"
export XDG_CACHE_HOME="/data/.cache"
export XDG_STATE_HOME="/data/.local/state"
export XDG_DATA_HOME="/data/.local/share"
export ANTHROPIC_CONFIG_DIR="/data/.config/claude"
export ANTHROPIC_HOME="/data"

# Disable auto-updates inside container (updates via add-on releases)
export DISABLE_AUTOUPDATER=1

# Always running as root inside HA supervisor container — IS_SANDBOX=1 allows Claude to start
export IS_SANDBOX=1

# GitHub CLI persistent configuration
export GH_CONFIG_DIR="/data/.config/gh"

# Persistent package paths and native Claude binary (HIGHEST PRIORITY)
export PATH="/data/packages/bin:/data/packages/python/venv/bin:/data/home/.local/bin:$PATH"
export LD_LIBRARY_PATH="/data/packages/lib:${LD_LIBRARY_PATH:-}"
export PKG_CONFIG_PATH="/data/packages/lib/pkgconfig:${PKG_CONFIG_PATH:-}"

# Python virtual environment if it exists
if [ -d "/data/packages/python/venv" ]; then
    export VIRTUAL_ENV="/data/packages/python/venv"
fi
PROFILE_EOF

    chmod 644 /etc/profile.d/persistent-packages.sh
    bashio::log.info "  - Profile script created: /etc/profile.d/persistent-packages.sh"

    # Migrate any existing authentication files from legacy locations
    migrate_legacy_auth_files "$claude_config_dir"

    # Setup Claude Code skills and commands
    if [ -d "/opt/.claude" ]; then
        if [ ! -d "$data_home/.claude" ]; then
            cp -r /opt/.claude "$data_home/.claude"
            bashio::log.info "  - Claude Code skills & commands installed"
        else
            bashio::log.info "  - Claude Code skills & commands: already configured"
        fi
    fi

    bashio::log.info "Environment initialized:"
    bashio::log.info "  - Home: $HOME"
    bashio::log.info "  - Config: $XDG_CONFIG_HOME"
    bashio::log.info "  - Claude config: $ANTHROPIC_CONFIG_DIR"
    bashio::log.info "  - GitHub config: $GH_CONFIG_DIR"
    bashio::log.info "  - Cache: $XDG_CACHE_HOME"
    bashio::log.info "  - Persistent packages: $persist_root"
}

# One-time migration of existing authentication files
migrate_legacy_auth_files() {
    local target_dir="$1"
    local migrated=false

    bashio::log.info "Checking for existing authentication files to migrate..."

    # Check common legacy locations
    local legacy_locations=(
        "/root/.config/anthropic"
        "/root/.anthropic" 
        "/config/claude-config"
        "/tmp/claude-config"
    )

    for legacy_path in "${legacy_locations[@]}"; do
        if [ -d "$legacy_path" ] && [ "$(ls -A "$legacy_path" 2>/dev/null)" ]; then
            bashio::log.info "Migrating auth files from: $legacy_path"
            
            # Copy files to new location
            if cp -r "$legacy_path"/* "$target_dir/" 2>/dev/null; then
                # Set proper permissions
                find "$target_dir" -type f -exec chmod 600 {} \;
                
                # Create compatibility symlink if this is a standard location
                if [[ "$legacy_path" == "/root/.config/anthropic" ]] || [[ "$legacy_path" == "/root/.anthropic" ]]; then
                    rm -rf "$legacy_path"
                    ln -sf "$target_dir" "$legacy_path"
                    bashio::log.info "Created compatibility symlink: $legacy_path -> $target_dir"
                fi
                
                migrated=true
                bashio::log.info "Migration completed from: $legacy_path"
            else
                bashio::log.warning "Failed to migrate from: $legacy_path"
            fi
        fi
    done

    if [ "$migrated" = false ]; then
        bashio::log.info "No existing authentication files found to migrate"
    fi
}

# Install required tools
install_tools() {
    bashio::log.info "Installing additional tools..."
    if ! apk add --no-cache ttyd jq curl tmux; then
        bashio::log.error "Failed to install required tools"
        exit 1
    fi
    bashio::log.info "Tools installed successfully"
}

# Setup tmux configuration and session wrapper
setup_tmux() {
    local tmux_conf="${HOME}/.tmux.conf"
    local tmux_mouse
    local tmux_wrapper="${TMUX_WRAPPER_PATH:-/usr/local/bin/tmux-claude}"

    tmux_mouse=$(bashio::config 'tmux_mouse' 'false')
    case "${tmux_mouse:-false}" in
        true|on|yes|1) tmux_mouse="on" ;;
        *) tmux_mouse="off" ;;
    esac
    bashio::log.info "Setting up tmux..."

    cat > "$tmux_conf" << TMUX_EOF
# Mouse mode is disabled by default so ttyd/browser copy and paste keeps working.
set -g mouse ${tmux_mouse}

# Large scrollback buffer
set -g history-limit 50000

# Reduce escape-time so claude/vim feel responsive inside tmux
set -g escape-time 20

# Start window and pane numbering at 1 (easier to reach on keyboard)
set -g base-index 1
setw -g pane-base-index 1
set -g renumber-windows on

# Status bar
set -g status-bg colour235
set -g status-fg colour136
set -g status-left '[#S] '
set -g status-right '%H:%M'
TMUX_EOF

    # Wrapper: attach to existing 'claude' session, or create a fresh one that runs the launch command
    cat > "$tmux_wrapper" << 'WRAPPER_EOF'
#!/bin/bash
if tmux has-session -t claude 2>/dev/null; then
    exec tmux attach-session -t claude
else
    exec tmux new-session -s claude bash -c 'eval "$CLAUDE_LAUNCH_CMD"'
fi
WRAPPER_EOF
    chmod +x "$tmux_wrapper"

    bashio::log.info "tmux configured (${tmux_conf})"
}

# Configure optional persistent Claude Code override in /data
setup_persistent_claude() {
    local use_persistent_claude
    local auto_update_claude_on_start
    local persistent_root="${PERSISTENT_CLAUDE_ROOT:-/data/npm}"
    local persistent_bin="$persistent_root/bin/claude"
    local persistent_package="$persistent_root/lib/node_modules/@anthropic-ai/claude-code/package.json"
    local claude_link="${CLAUDE_BIN_LINK:-/usr/local/bin/claude}"
    local claude_npm_spec="@anthropic-ai/claude-code@latest"

    use_persistent_claude=$(bashio::config 'use_persistent_claude' 'false')
    auto_update_claude_on_start=$(bashio::config 'auto_update_claude_on_start' 'false')

    if [ "$use_persistent_claude" != "true" ]; then
        bashio::log.info "Persistent Claude override: disabled"
        return 0
    fi

    mkdir -p "$persistent_root"

    # Current Claude Code native releases do not provide 32-bit ARM binaries.
    case "$(uname -m)" in
        armv7l|armv6l|armhf)
            claude_npm_spec="@anthropic-ai/claude-code@1.0.128"
            ;;
    esac

    if [ "$auto_update_claude_on_start" = "true" ]; then
        bashio::log.info "Persistent Claude override: updating Claude Code in /data/npm..."
        if NPM_CONFIG_PREFIX="$persistent_root" npm install -g "$claude_npm_spec" --prefer-online; then
            bashio::log.info "Persistent Claude override: update completed"
        else
            bashio::log.warning "Persistent Claude override: update failed, continuing with existing version if present"
        fi
    fi

    # Smoke-test the persistent binary before trusting it: this rejects a stale
    # or wrong-architecture install (e.g. an amd64 binary left in /data on a Pi).
    # Run under a timeout so a hung `--version` can never block add-on startup.
    local -a version_check=("$persistent_bin" --version)
    if command -v timeout >/dev/null 2>&1; then
        version_check=(timeout 15 "$persistent_bin" --version)
    fi

    if [ -x "$persistent_bin" ] && \
       [ -f "$persistent_package" ] && \
       "${version_check[@]}" >/dev/null 2>&1; then
        ln -sf "$persistent_bin" "$claude_link"
        bashio::log.info "Persistent Claude override active: $claude_link -> $persistent_bin"
    else
        bashio::log.warning "Persistent Claude override enabled but no working persistent Claude install found at $persistent_root"
        bashio::log.warning "Install it manually once with: NPM_CONFIG_PREFIX=/data/npm npm install -g $claude_npm_spec"
    fi
}

# Setup session picker script
setup_session_picker() {
    # Copy session picker script from built-in location
    if [ -f "/opt/scripts/claude-session-picker.sh" ]; then
        if ! cp /opt/scripts/claude-session-picker.sh /usr/local/bin/claude-session-picker; then
            bashio::log.error "Failed to copy claude-session-picker script"
            exit 1
        fi
        chmod +x /usr/local/bin/claude-session-picker
        bashio::log.info "Session picker script installed successfully"
    else
        bashio::log.warning "Session picker script not found, using auto-launch mode only"
    fi

    # Setup authentication helper if it exists
    if [ -f "/opt/scripts/claude-auth-helper.sh" ]; then
        chmod +x /opt/scripts/claude-auth-helper.sh
        bashio::log.info "Authentication helper script ready"
    fi
}

# Setup persistent package manager
setup_persistent_packages() {
    local persist_install="${PERSIST_INSTALL_BIN:-/usr/local/bin/persist-install}"
    local persist_install_source="${PERSIST_INSTALL_SOURCE:-/opt/scripts/persist-install}"

    # Install persist-install command globally
    if [ -f "$persist_install_source" ]; then
        cp "$persist_install_source" "$persist_install"
        chmod +x "$persist_install"
        bashio::log.info "Persistent package manager installed: 'persist-install'"
    fi

    # Auto-install packages from configuration
    auto_install_packages
}

# Normalize both Bashio list formats seen across Supervisor generations:
# newline-separated values and JSON arrays.
normalize_config_list() {
    local raw="$1"

    if [ -z "$raw" ] || [ "$raw" = "[]" ]; then
        return 0
    fi

    if printf '%s' "$raw" | jq -e 'type == "array"' >/dev/null 2>&1; then
        printf '%s' "$raw" | jq -r '.[]'
    else
        printf '%s\n' "$raw"
    fi
}

# Auto-install packages from add-on configuration
auto_install_packages() {
    local apk_packages
    local pip_packages
    local package
    local persist_install="${PERSIST_INSTALL_BIN:-/usr/local/bin/persist-install}"
    local -a pip_package_list=()

    apk_packages=$(normalize_config_list "$(bashio::config 'persistent_apk_packages' '')")
    pip_packages=$(normalize_config_list "$(bashio::config 'persistent_pip_packages' '')")

    if [ -n "$apk_packages" ]; then
        bashio::log.info "Auto-installing system packages from config..."
        while IFS= read -r package; do
            if [ -n "$package" ]; then
                bashio::log.info "  Installing: $package"
                "$persist_install" "$package" || bashio::log.warning "Failed to install: $package"
            fi
        done <<< "$apk_packages"
    fi

    if [ -n "$pip_packages" ]; then
        bashio::log.info "Auto-installing Python packages from config..."
        while IFS= read -r package; do
            [ -n "$package" ] && pip_package_list+=("$package")
        done <<< "$pip_packages"

        if [ "${#pip_package_list[@]}" -gt 0 ]; then
            bashio::log.info "  Installing: ${pip_package_list[*]}"
            "$persist_install" --python "${pip_package_list[@]}" || \
                bashio::log.warning "Failed to install Python packages"
        fi
    fi
}

# Legacy monitoring functions removed - using simplified /data approach

# Determine Claude launch command based on configuration
# Session picker handles its own loop, so Claude exiting returns to the menu (#6)
get_claude_launch_command() {
    local auto_launch_claude
    local dangerously_skip_permissions
    local remote_control
    local remote_control_session_name
    local claude_flags=""

    # Get configuration values
    auto_launch_claude=$(bashio::config 'auto_launch_claude' 'true')
    dangerously_skip_permissions=$(bashio::config 'dangerously_skip_permissions' 'false')
    remote_control=$(bashio::config 'remote_control' 'false')
    remote_control_session_name=$(bashio::config 'remote_control_session_name' '')

    # Build Claude flags
    if [ "$dangerously_skip_permissions" = "true" ]; then
        claude_flags="--dangerously-skip-permissions"
        bashio::log.warning "Claude will run with --dangerously-skip-permissions (unrestricted file access)"
    fi

    # Remote Control: start the auto-launched interactive session already paired
    # with claude.ai/code and the Claude mobile app (same as `claude --remote-control`),
    # so a phone or browser can drive it without opening the web terminal first.
    # Only affects the auto-launch path below; the session picker builds its own
    # commands. Needs a claude.ai OAuth login and Claude Code v2.1.51+, so it does
    # nothing on the ARMv7 image that pins the portable 1.0.128 release.
    if [ "$remote_control" = "true" ]; then
        claude_flags="${claude_flags:+${claude_flags} }--remote-control"
        if [ -n "$remote_control_session_name" ]; then
            # printf %q shell-quotes the name so spaces (and any other special
            # characters) survive the eval in the tmux wrapper as a single argument.
            claude_flags="${claude_flags} $(printf '%q' "$remote_control_session_name")"
        fi
        bashio::log.info "Remote Control enabled: Claude will start with --remote-control"
        if [ "$auto_launch_claude" != "true" ]; then
            bashio::log.warning "remote_control is set but has no effect while auto_launch_claude is false"
        fi
    fi

    if [ "$auto_launch_claude" = "true" ]; then
        # Auto-launch Claude first, then fall back to session picker on exit
        if [ -f /usr/local/bin/claude-session-picker ]; then
            echo "clear && echo 'Welcome to Claude Terminal!' && echo '' && echo 'Starting Claude...' && sleep 1 && claude ${claude_flags}; /usr/local/bin/claude-session-picker"
        else
            echo "clear && echo 'Welcome to Claude Terminal!' && echo '' && echo 'Starting Claude...' && sleep 1 && claude ${claude_flags}"
        fi
    else
        # Show interactive session picker (has its own while-true loop)
        if [ -f /usr/local/bin/claude-session-picker ]; then
            echo "clear && /usr/local/bin/claude-session-picker"
        else
            bashio::log.warning "Session picker not found, falling back to auto-launch"
            echo "clear && echo 'Welcome to Claude Terminal!' && echo '' && echo 'Starting Claude...' && sleep 1 && claude"
        fi
    fi
}


# Start image upload service
start_image_service() {
    local image_port=7680
    local ttyd_port=7681
    local upload_dir="/data/images"
    local service_dir="/opt/image-service"
    local server_file="${service_dir}/server.js"

    bashio::log.info "Starting image upload service on port ${image_port}..."

    # Create upload directory if it doesn't exist
    mkdir -p "${upload_dir}"
    chmod 755 "${upload_dir}"

    # Export environment variables for the image service
    export IMAGE_SERVICE_PORT="${image_port}"
    export TTYD_PORT="${ttyd_port}"
    export UPLOAD_DIR="${upload_dir}"

    # Check if server.js exists
    if [ ! -f "${server_file}" ]; then
        bashio::log.error "server.js not found at ${server_file}"
        ls -la "${service_dir}"
        return 1
    fi

    # Check if node_modules exists
    if [ ! -d "${service_dir}/node_modules" ]; then
        bashio::log.error "node_modules not found in ${service_dir}"
        bashio::log.info "Attempting to install dependencies..."
        cd "${service_dir}" && npm install || bashio::log.error "npm install failed"
        cd - > /dev/null
    fi

    # Start with better error logging (run from current directory with absolute path)
    bashio::log.info "Starting Node.js service from ${server_file}..."
    node "${server_file}" 2>&1 | while IFS= read -r line; do
        bashio::log.info "[Image Service] $line"
    done &

    # Store the PID for potential cleanup
    local image_service_pid=$!
    bashio::log.info "Image service started (PID: ${image_service_pid})"

    # Give it a moment to start
    sleep 3

    # Check if it's running
    if kill -0 "${image_service_pid}" 2>/dev/null; then
        bashio::log.info "Image service is running successfully"
    else
        bashio::log.error "Image service failed to start! Check logs above for errors"
        return 1
    fi
}

# Start main web terminal
start_web_terminal() {
    local port=7681
    bashio::log.info "Starting web terminal on port ${port}..."

    # Log environment information for debugging
    bashio::log.info "Environment variables:"
    bashio::log.info "ANTHROPIC_CONFIG_DIR=${ANTHROPIC_CONFIG_DIR}"
    bashio::log.info "HOME=${HOME}"

    # Get the appropriate launch command based on configuration
    local launch_command
    launch_command=$(get_claude_launch_command)

    # Log the configuration being used
    local auto_launch_claude
    auto_launch_claude=$(bashio::config 'auto_launch_claude' 'true')
    bashio::log.info "Auto-launch Claude: ${auto_launch_claude}"

    # Start the image upload service first
    start_image_service

    # Export launch command so the tmux-claude wrapper and session can access it
    export CLAUDE_LAUNCH_CMD="$launch_command"

    # Pre-create the persistent tmux session so the first browser connection is instant
    if ! tmux has-session -t claude 2>/dev/null; then
        bashio::log.info "Creating persistent tmux session 'claude'..."
        tmux new-session -d -s claude bash -c 'eval "$CLAUDE_LAUNCH_CMD"'
    else
        bashio::log.info "Reusing existing tmux session 'claude'..."
    fi

    # ttyd attaches every browser connection to the persistent tmux session.
    # If Claude is running and you close the browser tab, it keeps running.
    # Reopening the tab re-attaches to the same session.
    exec ttyd \
        --port "${port}" \
        --interface 0.0.0.0 \
        --writable \
        --ping-interval 30 \
        --client-option reconnect=5 \
        "${TMUX_WRAPPER_PATH:-/usr/local/bin/tmux-claude}"
}

# Run health check
run_health_check() {
    if [ -f "/opt/scripts/health-check.sh" ]; then
        bashio::log.info "Running system health check..."
        chmod +x /opt/scripts/health-check.sh
        /opt/scripts/health-check.sh || bashio::log.warning "Some health checks failed but continuing..."
    fi
}

# Main execution
main() {
    bashio::log.info "Initializing Claude Terminal add-on..."

    # Run diagnostics first (especially helpful for VirtualBox issues)
    run_health_check

    init_environment
    install_tools
    setup_tmux
    setup_persistent_claude
    setup_session_picker
    setup_persistent_packages
    start_web_terminal
}

# Execute main function
if [ "${CLAUDE_RUN_SH_SKIP_MAIN:-false}" != "true" ]; then
    main "$@"
fi
