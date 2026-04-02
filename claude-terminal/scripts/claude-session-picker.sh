#!/bin/bash

# Claude Session Picker - Interactive menu for choosing Claude session type
# Provides options for new session, continue, resume, manual command, or regular shell

# Get Claude flags from environment
get_claude_flags() {
    local flags=""
    if [ "${CLAUDE_DANGEROUS_MODE}" = "true" ]; then
        flags="--dangerously-skip-permissions"
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

show_menu() {
    local ver="unknown"
    if command -v claude &> /dev/null; then
        ver=$(claude --version 2>/dev/null || echo "unknown")
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
    echo "  7) 🐚 Drop to bash shell"
    echo "  8) ❌ Exit"
    echo ""
}

get_user_choice() {
    local choice
    # Send prompt to stderr to avoid capturing it with the return value
    printf "Enter your choice [1-8] (default: 1): " >&2
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
    /usr/local/bin/claude $flags
    # Returns here when Claude exits, loop in main() shows menu again
}

launch_claude_continue() {
    local flags=$(get_claude_flags)
    echo "⏩ Continuing most recent conversation..."
    sleep 1
    /usr/local/bin/claude -c $flags
}

launch_claude_resume() {
    local flags=$(get_claude_flags)
    echo "📋 Opening conversation list for selection..."
    sleep 1
    /usr/local/bin/claude -r $flags
}

launch_claude_custom() {
    local base_flags=$(get_claude_flags)
    echo ""
    echo "Enter your Claude command (e.g., 'claude --help' or 'claude -p \"hello\"'):"
    echo "Available flags: -c (continue), -r (resume), -p (print), --model,"
    echo "                 --dangerously-skip-permissions, etc."
    if [ "${CLAUDE_DANGEROUS_MODE}" = "true" ]; then
        echo "Note: --dangerously-skip-permissions will be automatically added"
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
            7)
                launch_bash_shell
                ;;
            8)
                exit_session_picker
                ;;
            *)
                echo ""
                echo "❌ Invalid choice: '$choice'"
                echo "Please select a number between 1-8"
                echo ""
                printf "Press Enter to continue..." >&2
                read -r
                ;;
        esac
    done
}

# Run main function
main "$@"