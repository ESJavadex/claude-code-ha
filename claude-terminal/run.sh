#!/usr/bin/with-contenv bashio
# shellcheck shell=bash

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

    # Ensure Claude is available at $HOME/.local/bin/claude, where Claude's
    # native self-check looks (HOME=/data/home at runtime). The image installs
    # it at /usr/local/bin/claude. Up to 2.1.9 this link pointed at
    # /root/.local/bin/claude, which no longer exists, so replace a dangling
    # link too; a working one (e.g. from `claude update`) is left alone.
    local native_bin_dir="$data_home/.local/bin"
    if [ ! -d "$native_bin_dir" ]; then
        mkdir -p "$native_bin_dir"
    fi
    if [ ! -e "$native_bin_dir/claude" ] && [ -x /usr/local/bin/claude ]; then
        ln -sf /usr/local/bin/claude "$native_bin_dir/claude"
        bashio::log.info "  - Claude binary linked: $native_bin_dir/claude"
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
    dangerously_skip_permissions=$(bashio::config 'dangerously_skip_permissions' 'false') || dangerously_skip_permissions='false'
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

# Older versions let npm and pip caches pile up in /data, inflating HA backups
# (HOME is /data/home, so npm's ~/.npm persisted). The Dockerfile now points
# both caches at /tmp or disables them; this removes what is left behind.
clean_persistent_storage() {
    rm -rf "$HOME/.npm" "$XDG_CACHE_HOME/pip"
    prune_claude_versions
    prune_uploads
}

# Files pasted, dropped or uploaded in the panel are only needed while Claude
# works on them, so drop ones older than UPLOAD_MAX_AGE_DAYS. /data/images is
# where images went before 2.3.7. Both are left out of backups.
prune_uploads() {
    local days="${UPLOAD_MAX_AGE_DAYS:-30}"
    local dir pruned=0 count
    for dir in ${UPLOAD_PRUNE_DIRS:-/data/uploads /data/images}; do
        [ -d "$dir" ] || continue
        count=$(find "$dir" -type f -mtime +"$days" -print -delete 2>/dev/null | wc -l)
        pruned=$((pruned + count))
    done
    if [ "$pruned" -gt 0 ]; then
        bashio::log.info "Removed $pruned uploaded file(s) older than $days days"
    fi
    return 0
}

# A native Claude Code update (`claude update`, or `claude install`) leaves
# a ~250 MB binary in versions/ every time, carried into every HA backup from
# then on. Keep the version the active symlink resolves to plus the newest
# entry (rollback), prune the rest. A pruned binary that is mid-execution keeps
# running (the inode stays alive until the process exits).
# Adapted from heytcass/home-assistant-addons 2.5.4.
prune_claude_versions() {
    local versions_dir="$XDG_DATA_HOME/claude/versions"
    [ -d "$versions_dir" ] || return 0

    local active newest="" entry pruned=0
    active=$(readlink -f "$HOME/.local/bin/claude" 2>/dev/null || true)
    # Find the newest entry without a pipe: under pipefail, `ls -t | head -1`
    # can die of SIGPIPE when head exits first, and set -e then kills startup
    for entry in "$versions_dir"/*; do
        [ -e "$entry" ] || continue
        if [ -z "$newest" ] || [ "$entry" -nt "$newest" ]; then
            newest="$entry"
        fi
    done

    for entry in "$versions_dir"/*; do
        [ -e "$entry" ] || continue
        [ "$entry" = "$active" ] && continue
        [ "$entry" = "$newest" ] && continue
        rm -rf "$entry"
        pruned=$((pruned + 1))
    done

    if [ "$pruned" -gt 0 ]; then
        bashio::log.info "Pruned $pruned old Claude Code version(s) from persistent storage"
    fi
}

# The persist-install venv in /data belongs to the Python that created it.
# When an update brings a new Python (Alpine 3.21's 3.12 -> 3.24's 3.14), its
# packages stop importing and its own pip breaks, and nothing repairs it:
# venv/bin/python still resolves, to the new interpreter. Recreate the venv
# and reinstall what it held from PyPI, one package at a time (needs the
# network). A package installed from a URL, a path or a wheel (PEP 610
# direct_url.json) is not reinstalled by name, which could fetch an unrelated
# PyPI package. What needs a manual reinstall is kept in a file, because the
# old venv, and with it the list, is gone after this boot.
migrate_python_venv() {
    local venv="${PERSIST_VENV:-/data/packages/python/venv}"
    local python="${PYTHON_BIN:-python3}"
    local todo="${venv%/*}/reinstall-needed.txt"
    [ -f "$venv/pyvenv.cfg" ] || return 0

    local old new
    old=$(sed -n -E 's/^version(_info)? *= *([0-9]+\.[0-9]+).*/\2/p' "$venv/pyvenv.cfg")
    new=$("$python" -c 'import sys; print("%d.%d" % sys.version_info[:2])' 2>/dev/null) || return 0
    if [ -z "$old" ] || [ -z "$new" ] || [ "$old" = "$new" ]; then
        return 0
    fi

    local -a packages=() manual=()
    local info name url
    for info in "$venv/lib/python$old/site-packages"/*.dist-info; do
        [ -f "$info/METADATA" ] || continue
        name=$(sed -n '/^Name:/{s/^Name: *//;p;q;}' "$info/METADATA")
        case "$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]')" in
            ''|pip|setuptools|wheel) continue ;;
        esac
        if [ -f "$info/direct_url.json" ]; then
            url=$(jq -r '.url // empty' "$info/direct_url.json" 2>/dev/null) || url=""
            manual+=("$name${url:+ (from $url)}")
        else
            packages+=("$name")
        fi
    done

    bashio::log.warning "Python changed from $old to $new: rebuilding the persist-install venv"
    rm -rf "$venv"
    if ! "$python" -m venv "$venv"; then
        bashio::log.error "Could not recreate $venv; persist-install --python will create it again"
        return 0
    fi

    # Short timeout and one retry: this runs before the terminal starts, so
    # an offline boot must not wait out pip's defaults for every package
    for name in "${packages[@]}"; do
        bashio::log.info "  Reinstalling: $name"
        "$venv/bin/pip" install -q --disable-pip-version-check --timeout 10 --retries 1 "$name" || \
            manual+=("$name")
    done
    if [ "${#manual[@]}" -gt 0 ]; then
        printf '%s\n' "${manual[@]}" > "$todo"
        bashio::log.warning "Reinstall these with persist-install --python (list kept in $todo): ${manual[*]}"
    else
        rm -f "$todo"
    fi
}

# Binaries and libraries that persist-install copied into /data/packages come
# from the Alpine release they were installed on, and /data/packages/lib is
# first on LD_LIBRARY_PATH. After the base image moves to a new release, name
# the files to reinstall. Runs after the auto-install: packages listed in the
# add-on options were just installed into the system and copied again, so an
# identical system file means the copy is current. The container's system
# files come from the image, so a manual install from before has none.
check_persisted_alpine_release() {
    local root="${PERSIST_ROOT:-/data/packages}"
    local system="${SYSTEM_ROOT:-}"
    local marker="$root/.alpine-release"
    local current previous
    current=$(cut -d. -f1,2 "${ALPINE_RELEASE_FILE:-/etc/alpine-release}" 2>/dev/null) || return 0
    [ -n "$current" ] || return 0
    # No marker: the files predate 2.3.8, and the base was 3.21 from early 2025
    previous=$(cat "$marker" 2>/dev/null || echo "3.21")

    if [ "$previous" != "$current" ]; then
        local -a stale=()
        local file name
        for file in "$root"/bin/* "$root"/lib/*; do
            [ -f "$file" ] || continue
            name=${file##*/}
            if cmp -s "$file" "$system/usr/bin/$name" || cmp -s "$file" "$system/usr/sbin/$name" || \
                cmp -s "$file" "$system/usr/lib/$name"; then
                continue
            fi
            stale+=("$name")
        done
        if [ "${#stale[@]}" -gt 0 ]; then
            bashio::log.warning "The base image moved from Alpine $previous to $current. These files were installed with persist-install on $previous and may not work: ${stale[*]}"
            bashio::log.warning "Reinstall the packages they came from with persist-install"
        fi
    fi
    mkdir -p "$root" && printf '%s\n' "$current" > "$marker"
}

# Claude Code's runtime (Bun) requires AVX on x86-64. Hypervisor default CPU
# types (Proxmox/QEMU kvm64, qemu64) mask it even when the host CPU has it,
# and every claude invocation then crashes or spins at 100% CPU. Warn in the
# add-on log, since the terminal itself is unusable in that state.
check_cpu_features() {
    if [ "$(uname -m)" = "x86_64" ] && ! grep -q avx /proc/cpuinfo; then
        bashio::log.warning "This CPU does not expose AVX - Claude Code will likely hang or crash on every invocation"
        bashio::log.warning "On a Proxmox/QEMU VM, set the VM's CPU type to 'host', then fully shut the VM down and start it again (a reboot is not enough)"
    fi
    # The test above is false on a healthy CPU; don't let that become the
    # function's status under set -e
    return 0
}

# Setup tmux configuration and session wrapper
setup_tmux() {
    local tmux_conf="${HOME}/.tmux.conf"
    local tmux_mouse
    local tmux_wrapper="${TMUX_WRAPPER_PATH:-/usr/local/bin/tmux-claude}"

    tmux_mouse=$(bashio::config 'tmux_mouse' 'false') || tmux_mouse='false'
    case "${tmux_mouse:-false}" in
        true|on|yes|1) tmux_mouse="on" ;;
        *) tmux_mouse="off" ;;
    esac
    bashio::log.info "Setting up tmux..."

    cat > "$tmux_conf" << TMUX_EOF
# Rewritten on every add-on start, so edits here don't survive a restart.
# Put your own settings in ~/.tmux.local.conf: it is sourced at the end, so
# it overrides anything below, and the add-on never touches it.

# Mouse mode is disabled by default so ttyd/browser copy and paste keeps working.
set -g mouse ${tmux_mouse}

# Let applications in the pane (Claude Code's /copy) set the clipboard through
# OSC 52 and forward it out to ttyd. The default 'external' drops what they send.
set -g set-clipboard on

# tmux only emits OSC 52 when the outer terminal advertises the 'Ms' capability.
# ttyd's frontend always accepts it, so declare it instead of trusting terminfo.
set -as terminal-features ',*:clipboard'

# Large scrollback buffer
set -g history-limit 50000

# Reduce escape-time so claude/vim feel responsive inside tmux
set -g escape-time 20

# Pass focus in/out events through, so Claude Code and vim notice the
# terminal regaining focus
set -g focus-events on

# Start window and pane numbering at 1 (easier to reach on keyboard)
set -g base-index 1
setw -g pane-base-index 1
set -g renumber-windows on

# Status bar
set -g status-bg colour235
set -g status-fg colour136
set -g status-left '[#S] '
set -g status-right '%H:%M'

# Your overrides, last so they win. -q: a missing file is not an error.
source-file -q ~/.tmux.local.conf
TMUX_EOF

    # Wrapper: attach to existing 'claude' session, or create a fresh one that runs the launch command
    cat > "$tmux_wrapper" << 'WRAPPER_EOF'
#!/bin/bash
if tmux has-session -t claude 2>/dev/null; then
    exec tmux attach-session -t claude
else
    exec tmux new-session -s claude -c "${CLAUDE_WORKDIR:-/config}" bash -c 'eval "$CLAUDE_LAUNCH_CMD"'
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

    use_persistent_claude=$(bashio::config 'use_persistent_claude' 'false') || use_persistent_claude='false'
    auto_update_claude_on_start=$(bashio::config 'auto_update_claude_on_start' 'false') || auto_update_claude_on_start='false'

    # Exported so the session picker knows whether to offer a manual
    # "Update Claude Code" menu option.
    export USE_PERSISTENT_CLAUDE="$use_persistent_claude"

    if [ "$use_persistent_claude" != "true" ]; then
        bashio::log.info "Persistent Claude override: disabled"
        return 0
    fi

    mkdir -p "$persistent_root"

    # Exported so the session picker's manual update option can reuse the
    # same install path/spec instead of duplicating the arch resolution.
    export PERSISTENT_CLAUDE_ROOT="$persistent_root"
    export CLAUDE_BIN_LINK="$claude_link"
    export CLAUDE_NPM_SPEC="$claude_npm_spec"

    # /data/npm is left out of HA backups (backup_exclude), so after a restore
    # it is missing: install it again rather than silently falling back to
    # the image's copy. A broken install is left alone (see the check below).
    # Capped at 5 minutes: this runs before the web UI starts, so an offline
    # boot must not leave the panel down.
    if [ ! -e "$persistent_package" ]; then
        bashio::log.info "Persistent Claude override: installing Claude Code into $persistent_root..."
        if NPM_CONFIG_PREFIX="$persistent_root" timeout 300 npm install -g "$claude_npm_spec" --prefer-online; then
            bashio::log.info "Persistent Claude override: install completed"
        else
            bashio::log.warning "Persistent Claude override: install failed"
        fi
    elif [ "$auto_update_claude_on_start" = "true" ]; then
        bashio::log.info "Persistent Claude override: updating Claude Code in /data/npm..."
        if NPM_CONFIG_PREFIX="$persistent_root" timeout 300 npm install -g "$claude_npm_spec" --prefer-online; then
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

# Run the user's init_commands once per start, after persistent packages and
# before the terminal (#33). They come from the add-on options, which only HA
# admins can change; nothing is read from /config, where other add-ons can
# write. Each command gets INIT_COMMAND_TIMEOUT seconds so a mistake can't
# keep the panel down: long-running services must put themselves in the
# background (nohup ... &).
run_init_commands() {
    local commands command status output_file
    local timeout_seconds="${INIT_COMMAND_TIMEOUT:-120}"

    commands=$(normalize_config_list "$(bashio::config 'init_commands' '')")
    [ -n "$commands" ] || return 0

    bashio::log.info "Running init_commands from configuration..."
    while IFS= read -r command; do
        [ -n "$command" ] || continue
        bashio::log.info "  Running: $command"
        # Output goes to a file, not a pipe: a service started in the
        # background keeps stdout open, and a pipe would wait for it
        output_file=$(mktemp)
        if (cd /config && timeout "$timeout_seconds" bash -c "$command") < /dev/null > "$output_file" 2>&1; then
            status=0
        else
            status=$?
        fi
        while IFS= read -r line; do
            bashio::log.info "  [init] $line"
        done < "$output_file"
        rm -f "$output_file"
        # 124 from coreutils timeout, 143 (SIGTERM) from BusyBox's
        if [ "$status" -eq 124 ] || [ "$status" -eq 143 ]; then
            bashio::log.warning "  Stopped after ${timeout_seconds}s (use 'nohup ... &' for services): $command"
        elif [ "$status" -ne 0 ]; then
            bashio::log.warning "  Exited with status $status: $command"
        fi
    done <<< "$commands"
}

# Normalize both Bashio list formats seen across Supervisor generations:
# newline-separated values and JSON arrays.
normalize_config_list() {
    local raw="$1"

    # bashio prints "null" for an option missing from the stored config
    if [ -z "$raw" ] || [ "$raw" = "[]" ] || [ "$raw" = "null" ]; then
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

# Flags added to every Claude launch, as shell text. The launch command (and
# the session picker) evals it exactly once, so ordinary quoting in
# claude_extra_args works: --append-system-prompt 'be terse' arrives as one
# argument.
build_claude_flags() {
    # Files pasted or dropped in the panel land in /data/uploads, outside the
    # working directory, so Claude would ask before every read. Make it one
    # of Claude's working directories. First, so the list-taking flag is
    # always followed by another option, never a prompt.
    local flags="--add-dir /data/uploads"
    local extra

    if [ "$(bashio::config 'dangerously_skip_permissions' 'false')" = "true" ]; then
        flags="${flags:+$flags }--dangerously-skip-permissions"
    fi

    # The interactive flag, not `claude remote-control` server mode: the
    # session stays typeable in the browser and also appears in the Claude app
    # and at claude.ai/code. The default name is the container hostname, an
    # opaque hex slug, so give it a readable one.
    if [ "$(bashio::config 'enable_remote_control' 'false')" = "true" ]; then
        flags="${flags:+$flags }--remote-control 'Home Assistant'"
    fi

    extra=$(bashio::config 'claude_extra_args' '') || extra=''
    if [ -n "$extra" ] && [ "$extra" != "null" ]; then
        flags="${flags:+$flags }$extra"
    fi

    echo "$flags"
}

# Directory the tmux session starts in. Defaults to /config; a path that
# doesn't exist logs a warning and falls back, so a typo can't leave a dead
# terminal. Claude asks its one-time folder-trust question per new directory.
get_working_directory() {
    local dir
    dir=$(bashio::config 'working_directory' '') || dir=''
    if [ -z "$dir" ] || [ "$dir" = "null" ]; then
        echo "/config"
    elif [ -d "$dir" ]; then
        echo "$dir"
    else
        bashio::log.warning "working_directory '$dir' does not exist; starting in /config instead"
        echo "/config"
    fi
}

# A token from `claude setup-token` reaches every claude in the session
# through the environment (tmux inherits it from this script). The value
# itself is never logged.
export_oauth_token() {
    local token
    token=$(bashio::config 'claude_code_oauth_token' '') || token=''
    if [ -n "$token" ] && [ "$token" != "null" ]; then
        export CLAUDE_CODE_OAUTH_TOKEN="$token"
        bashio::log.info "CLAUDE_CODE_OAUTH_TOKEN set from add-on configuration"
    fi
}

# Say at boot what the launch flags mean, rather than leaving the user to
# find out in the terminal. Nothing here is fatal.
log_claude_flags() {
    local flags="$1"

    if [[ "$flags" == *"--dangerously-skip-permissions"* ]]; then
        bashio::log.warning "Claude will run with --dangerously-skip-permissions (unrestricted file access)"
    fi

    [[ "$flags" == *"--remote-control"* ]] || return 0
    bashio::log.info "Remote Control enabled: the session appears as 'Home Assistant' in the Claude app and at claude.ai/code"
    if [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then
        bashio::log.warning "Remote Control needs a full claude.ai login; a claude_code_oauth_token from 'claude setup-token' cannot establish it"
    fi
    if [[ "$flags" == *"--dangerously-skip-permissions"* ]]; then
        bashio::log.warning "dangerously_skip_permissions + Remote Control: any device signed in to this Claude account can drive an unprompted root shell with write access to /config"
    fi
}

# Determine Claude launch command based on configuration
# Session picker handles its own loop, so Claude exiting returns to the menu (#6)
get_claude_launch_command() {
    local auto_launch_claude
    local claude_flags

    # Get configuration values
    auto_launch_claude=$(bashio::config 'auto_launch_claude' 'true') || auto_launch_claude='true'
    claude_flags=$(build_claude_flags)

    if [ "$auto_launch_claude" = "true" ]; then
        # Auto-launch Claude first, then fall back to session picker on exit
        if [ -f /usr/local/bin/claude-session-picker ]; then
            echo "clear && echo 'Welcome to Claude Terminal!' && echo '' && echo 'Starting Claude...' && sleep 1 && /usr/local/bin/claude ${claude_flags}; /usr/local/bin/claude-session-picker"
        else
            echo "clear && echo 'Welcome to Claude Terminal!' && echo '' && echo 'Starting Claude...' && sleep 1 && /usr/local/bin/claude ${claude_flags}"
        fi
    else
        # Show interactive session picker (has its own while-true loop)
        if [ -f /usr/local/bin/claude-session-picker ]; then
            echo "clear && /usr/local/bin/claude-session-picker"
        else
            bashio::log.warning "Session picker not found, falling back to auto-launch"
            echo "clear && echo 'Welcome to Claude Terminal!' && echo '' && echo 'Starting Claude...' && sleep 1 && /usr/local/bin/claude ${claude_flags}"
        fi
    fi
}


# True if the user has mapped this container port to a host port.
# DEV_DIRECT_ACCESS=1 (docker/podman -e, for local testing without a
# Supervisor) forces it; add-on users have no way to set it.
port_is_published() {
    [ "${DEV_DIRECT_ACCESS:-0}" = "1" ] && return 0
    local host_port
    host_port=$(bashio::app.port "${1}" 2>/dev/null || true)
    [ -n "${host_port}" ] && [ "${host_port}" != "null" ]
}

# Start image upload service
start_image_service() {
    local image_port=7680
    local ttyd_port=7681
    local upload_dir="/data/uploads"
    local service_dir="/opt/image-service"
    local server_file="${service_dir}/server.mjs"

    bashio::log.info "Starting image upload service on port ${image_port}..."

    # Create upload directory if it doesn't exist
    mkdir -p "${upload_dir}"
    chmod 755 "${upload_dir}"

    # Export environment variables for the image service
    export IMAGE_SERVICE_PORT="${image_port}"
    export TTYD_PORT="${ttyd_port}"
    export UPLOAD_DIR="${upload_dir}"
    VOICE_STT_PROVIDER=$(bashio::config 'voice_stt_provider' '') || VOICE_STT_PROVIDER=''
    VOICE_LANGUAGE=$(bashio::config 'voice_language' '') || VOICE_LANGUAGE=''
    [ "$VOICE_STT_PROVIDER" != 'null' ] || VOICE_STT_PROVIDER=''
    [ "$VOICE_LANGUAGE" != 'null' ] || VOICE_LANGUAGE=''
    export VOICE_STT_PROVIDER VOICE_LANGUAGE
    ADDON_VERSION="$(bashio::app.version)" || ADDON_VERSION=""
    export ADDON_VERSION

    # Without a published port, only ingress (and the container itself) may
    # connect; other add-ons on the hassio network are refused.
    if port_is_published "${image_port}"; then
        export ALLOW_DIRECT_ACCESS=1
        bashio::log.warning "Port ${image_port} is published: the web UI is reachable without a Home Assistant login"
    else
        export ALLOW_DIRECT_ACCESS=0
    fi

    # Check if server.mjs exists
    if [ ! -f "${server_file}" ]; then
        bashio::log.error "server.mjs not found at ${server_file}"
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

# Post Claude's OAuth login URL as a clickable HA notification when it
# appears, and dismiss it after login (see scripts/login-url-watcher.sh)
start_login_url_watcher() {
    local watcher="/opt/scripts/login-url-watcher.sh"
    if [ ! -f "$watcher" ]; then
        bashio::log.warning "Login URL watcher not found: $watcher"
        return 0
    fi
    # With a long-lived token there is no browser login to help with, and no
    # .credentials.json, so the watcher would treat every session as logged out
    if [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then
        bashio::log.info "Login URL watcher not needed (claude_code_oauth_token is set)"
        return 0
    fi
    bashio::log.info "Starting login URL watcher in background"
    bash "$watcher" 2>&1 | while IFS= read -r line; do
        bashio::log.info "[Login watcher] $line"
    done &
}

# Start main web terminal
start_web_terminal() {
    local port=7681
    bashio::log.info "Starting web terminal on port ${port}..."

    # Log environment information for debugging
    bashio::log.info "Environment variables:"
    bashio::log.info "ANTHROPIC_CONFIG_DIR=${ANTHROPIC_CONFIG_DIR}"
    bashio::log.info "HOME=${HOME}"

    # Shared with the session picker, which launches Claude itself
    export_oauth_token
    export CLAUDE_FLAGS
    CLAUDE_FLAGS=$(build_claude_flags)
    log_claude_flags "$CLAUDE_FLAGS"
    export CLAUDE_WORKDIR
    CLAUDE_WORKDIR=$(get_working_directory)
    bashio::log.info "Working directory: ${CLAUDE_WORKDIR}"

    # Get the appropriate launch command based on configuration
    local launch_command
    launch_command=$(get_claude_launch_command)

    # Log the configuration being used
    local auto_launch_claude
    auto_launch_claude=$(bashio::config 'auto_launch_claude' 'true') || auto_launch_claude='true'
    bashio::log.info "Auto-launch Claude: ${auto_launch_claude}"

    # Start the image upload service first
    start_image_service

    # Export launch command so the tmux-claude wrapper and session can access it
    export CLAUDE_LAUNCH_CMD="$launch_command"

    # Pre-create the persistent tmux session so the first browser connection is instant
    if ! tmux has-session -t claude 2>/dev/null; then
        bashio::log.info "Creating persistent tmux session 'claude'..."
        tmux new-session -d -s claude -c "$CLAUDE_WORKDIR" bash -c 'eval "$CLAUDE_LAUNCH_CMD"'
    else
        bashio::log.info "Reusing existing tmux session 'claude'..."
    fi

    start_login_url_watcher

    # ttyd has no login of its own. Unless 7681 is published for direct access,
    # bind it to loopback so only the image service proxy can reach it, not
    # other add-ons on the internal hassio network.
    local interface=127.0.0.1
    if port_is_published 7681; then
        interface=0.0.0.0
        bashio::log.warning "Port 7681 is published: ttyd is reachable without a Home Assistant login"
    fi

    # ttyd attaches every browser connection to the persistent tmux session.
    # If Claude is running and you close the browser tab, it keeps running.
    # Reopening the tab re-attaches to the same session.
    exec ttyd \
        --port "${port}" \
        --interface "${interface}" \
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
    check_cpu_features
    clean_persistent_storage
    migrate_python_venv
    setup_tmux
    setup_persistent_claude
    setup_session_picker
    setup_persistent_packages
    check_persisted_alpine_release
    run_init_commands
    start_web_terminal
}

# Execute main function
if [ "${CLAUDE_RUN_SH_SKIP_MAIN:-false}" != "true" ]; then
    main "$@"
fi
