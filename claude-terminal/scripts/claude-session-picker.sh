#!/bin/bash

# Claude Session Picker - Interactive menu for choosing Claude session type
# Provides options for new session, continue, resume, manual command, or regular shell

# Get Claude flags from environment. CLAUDE_FLAGS (set by run.sh) is shell
# text, so launches eval it once and quoting in claude_extra_args survives.
get_claude_flags() {
    local flags="${CLAUDE_FLAGS-}"
    # Older run.sh only exported the dangerous-mode switch
    if [ -z "${CLAUDE_FLAGS+set}" ] && [ "${CLAUDE_DANGEROUS_MODE}" = "true" ]; then
        flags="--dangerously-skip-permissions"
    fi
    if [[ "$flags" == *"--dangerously-skip-permissions"* ]]; then
        echo "⚠️  Running in DANGEROUS mode (unrestricted file access)" >&2
        # Set IS_SANDBOX=1 to allow dangerous mode when running as root
        export IS_SANDBOX=1
    fi
    echo "$flags"
}

show_banner() {
    clear
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║                    🤖 Claude Terminal                        ║"
    echo "║                   Interactive Session Picker                ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo ""
}

# Only offer the manual update option when run.sh has set up a persistent
# Claude install (use_persistent_claude: true) for it to update.
is_persistent_claude_enabled() {
    [ "${USE_PERSISTENT_CLAUDE:-false}" = "true" ]
}

# Menu item numbers shift depending on whether the update option is shown,
# so both the menu display and the choice handling read from these.
compute_menu_numbers() {
    if is_persistent_claude_enabled; then
        NUM_UPDATE=7
        NUM_BASH=8
        NUM_EXIT=9
    else
        NUM_UPDATE=""
        NUM_BASH=7
        NUM_EXIT=8
    fi
}

LATEST_VERSION_CACHE="${XDG_CACHE_HOME:-/data/.cache}/claude-latest-version"
LATEST_VERSION_TTL=3600

# "2.1.226 (Claude Code)" -> "2.1.226"
get_installed_version() {
    [ -x /usr/local/bin/claude ] || return 0
    /usr/local/bin/claude --version 2>/dev/null | awk 'NR==1 {print $1}'
}

# The version the Update option would install. A pinned spec (ARMv7) is its
# own answer; otherwise ask the npm registry, cached so the menu redraw loop
# does not hit the network every time. Prints nothing when it cannot tell.
get_latest_version() {
    local spec="${CLAUDE_NPM_SPEC:-@anthropic-ai/claude-code@latest}"
    local pinned="${spec##*@}"
    case "$pinned" in
        [0-9]*) echo "$pinned"; return 0 ;;
    esac

    local now cached_at cached_version
    now=$(date +%s)
    if [ -f "$LATEST_VERSION_CACHE" ]; then
        read -r cached_at cached_version < "$LATEST_VERSION_CACHE"
        if [ -n "$cached_version" ] && [ $((now - ${cached_at:-0})) -lt "$LATEST_VERSION_TTL" ]; then
            echo "$cached_version"
            return 0
        fi
    fi

    local latest
    latest=$(curl -fsS --max-time 3 https://registry.npmjs.org/@anthropic-ai/claude-code/latest 2>/dev/null | jq -r '.version // empty' 2>/dev/null)
    if [ -n "$latest" ]; then
        mkdir -p "$(dirname "$LATEST_VERSION_CACHE")" 2>/dev/null
        echo "$now $latest" > "$LATEST_VERSION_CACHE" 2>/dev/null
        echo "$latest"
    fi
}

# True when $1 is strictly newer than $2.
version_is_newer() {
    [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n 1)" = "$1" ]
}

update_menu_label() {
    local installed latest
    installed=$(get_installed_version)
    latest=$(get_latest_version)

    if [ -z "$latest" ]; then
        echo "Update Claude Code (latest version unknown)"
    elif [ -n "$installed" ] && version_is_newer "$latest" "$installed"; then
        echo "Update Claude Code ($installed → $latest available)"
    else
        echo "Update Claude Code (${installed:-$latest}, up to date)"
    fi
}

show_menu() {
    local ver="unknown"
    if [ -x /usr/local/bin/claude ]; then
        ver=$(/usr/local/bin/claude --version 2>/dev/null || echo "unknown")
    fi

    echo "Claude Code version: $ver"
    echo ""
    echo "Choose your Claude session type:"
    echo ""
    echo "  1) 🆕 New interactive session (default)"
    echo "  2) ⏩ Continue most recent conversation (-c)"
    echo "  3) 📋 Resume from conversation list (-r)"
    echo "  4) ⚙️  Custom Claude command (manual flags)"
    echo "  5) 🔐 Claude authentication helper"
    echo "  6) 🐙 GitHub CLI login (gh auth)"
    if is_persistent_claude_enabled; then
        echo "  ${NUM_UPDATE}) 🔄 $(update_menu_label)"
    fi
    echo "  ${NUM_BASH}) 🐚 Drop to bash shell"
    echo "  ${NUM_EXIT}) ❌ Exit"
    echo ""
}

get_user_choice() {
    local choice
    # Send prompt to stderr to avoid capturing it with the return value
    printf "Enter your choice [1-%s] (default: 1): " "$NUM_EXIT" >&2
    read -r choice
    
    # Default to 1 if empty
    if [ -z "$choice" ]; then
        choice=1
    fi
    
    # Trim whitespace and return only the choice
    choice=$(echo "$choice" | tr -d '[:space:]')
    echo "$choice"
}

launch_claude_new() {
    local flags=$(get_claude_flags)
    echo "🚀 Starting new Claude session..."
    sleep 1
    eval "/usr/local/bin/claude $flags"
    # Returns here when Claude exits, loop in main() shows menu again
}

launch_claude_continue() {
    local flags=$(get_claude_flags)
    echo "⏩ Continuing most recent conversation..."
    sleep 1
    eval "/usr/local/bin/claude -c $flags"
}

launch_claude_resume() {
    local flags=$(get_claude_flags)
    echo "📋 Opening conversation list for selection..."
    sleep 1
    eval "/usr/local/bin/claude -r $flags"
}

launch_claude_custom() {
    local base_flags=$(get_claude_flags)
    echo ""
    echo "Enter your Claude command (e.g., 'claude --help' or 'claude -p \"hello\"'):"
    echo "Available flags: -c (continue), -r (resume), -p (print), --model,"
    echo "                 --dangerously-skip-permissions, etc."
    if [ -n "$base_flags" ]; then
        echo "Note: these will be added automatically: $base_flags"
    fi
    echo -n "> claude "
    read -r custom_args

    if [ -z "$custom_args" ]; then
        echo "No arguments provided. Starting default session..."
        launch_claude_new
    else
        echo "🚀 Running: claude $custom_args $base_flags"
        sleep 1
        eval "/usr/local/bin/claude $custom_args $base_flags"
    fi
}

launch_update_claude() {
    local persistent_root="${PERSISTENT_CLAUDE_ROOT:-/data/npm}"
    local claude_link="${CLAUDE_BIN_LINK:-/usr/local/bin/claude}"
    local claude_npm_spec="${CLAUDE_NPM_SPEC:-@anthropic-ai/claude-code@latest}"
    local persistent_bin="$persistent_root/bin/claude"

    echo "🔄 Updating Claude Code (${claude_npm_spec})..."
    if NPM_CONFIG_PREFIX="$persistent_root" npm install -g "$claude_npm_spec" --prefer-online; then
        rm -f "$LATEST_VERSION_CACHE"
        if [ -x "$persistent_bin" ]; then
            ln -sf "$persistent_bin" "$claude_link"
            local new_version
            new_version=$("$claude_link" --version 2>/dev/null || echo "unknown")
            echo "✅ Claude Code updated: $new_version"
        else
            echo "⚠️  Update ran but no binary was found at $persistent_bin"
        fi
    else
        echo "❌ Update failed. Keeping the existing installed version."
    fi

    printf "Press Enter to return to menu..." >&2
    read -r
}

launch_auth_helper() {
    echo "🔐 Starting Claude authentication helper..."
    sleep 1
    /opt/scripts/claude-auth-helper.sh
}

launch_github_auth() {
    echo ""
    echo "🐙 GitHub CLI Authentication"
    echo "════════════════════════════"
    echo ""

    # Check if gh is installed
    if ! command -v gh &>/dev/null; then
        echo "❌ GitHub CLI (gh) is not installed!"
        echo "   Update to Claude Terminal Pro v2.0.4+ to get gh pre-installed."
        echo ""
        printf "Press Enter to return to menu..." >&2
        read -r
        return
    fi

    # Check current auth status
    echo "Checking current authentication status..."
    echo ""
    if gh auth status 2>/dev/null; then
        echo ""
        echo "✅ You are already authenticated!"
        echo ""
        echo "Options:"
        echo "  1) Keep current login"
        echo "  2) Login to a different account"
        echo ""
        printf "Choice [1-2] (default: 1): " >&2
        read -r auth_choice

        if [ "$auth_choice" != "2" ]; then
            echo ""
            printf "Press Enter to return to menu..." >&2
            read -r
            return
        fi
    fi

    echo ""
    echo "Choose authentication method:"
    echo ""
    echo "  1) 🌐 Browser login (if you have browser access)"
    echo "  2) 🔑 Token login (recommended for containers)"
    echo ""
    printf "Choice [1-2] (default: 2): " >&2
    read -r method_choice

    echo ""
    if [ "$method_choice" = "1" ]; then
        echo "Starting browser authentication..."
        gh auth login --web
    else
        echo "To create a personal access token:"
        echo ""
        echo "  1. Go to: https://github.com/settings/tokens"
        echo "  2. Click 'Generate new token (classic)'"
        echo "  3. Select scopes: repo, read:org, workflow"
        echo "  4. Generate and copy the token"
        echo ""
        gh auth login --with-token <<< "$(read -rsp 'Paste your token: ' token; echo "$token")" 2>/dev/null || {
            # Fallback to interactive if the above fails
            echo ""
            gh auth login -p https -h github.com
        }
    fi

    echo ""
    echo "Verifying authentication..."
    if gh auth status 2>/dev/null; then
        echo ""
        echo "✅ GitHub authentication successful!"
        echo "   Credentials saved to: $GH_CONFIG_DIR"
        echo "   They will persist across reboots."
    else
        echo ""
        echo "⚠️  Authentication may have failed. Try again or use 'gh auth login' from bash."
    fi

    echo ""
    printf "Press Enter to return to menu..." >&2
    read -r
}

launch_bash_shell() {
    echo "🐚 Dropping to bash shell..."
    echo "Tip: Run 'claude' manually, type 'exit' to return to this menu"
    sleep 1
    bash
    # Returns here when user types 'exit', loop in main() shows menu again
}

exit_session_picker() {
    echo "👋 Goodbye!"
    exit 0
}

# Main execution flow
main() {
    while true; do
        compute_menu_numbers
        show_banner
        show_menu
        choice=$(get_user_choice)

        case "$choice" in
            1)
                launch_claude_new
                ;;
            2)
                launch_claude_continue
                ;;
            3)
                launch_claude_resume
                ;;
            4)
                launch_claude_custom
                ;;
            5)
                launch_auth_helper
                ;;
            6)
                launch_github_auth
                ;;
            "$NUM_UPDATE")
                if is_persistent_claude_enabled; then
                    launch_update_claude
                fi
                ;;
            "$NUM_BASH")
                launch_bash_shell
                ;;
            "$NUM_EXIT")
                exit_session_picker
                ;;
            *)
                echo ""
                echo "❌ Invalid choice: '$choice'"
                echo "Please select a number between 1-${NUM_EXIT}"
                echo ""
                printf "Press Enter to continue..." >&2
                read -r
                ;;
        esac
    done
}

# Run main function
main "$@"