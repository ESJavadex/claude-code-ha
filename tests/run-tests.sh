#!/usr/bin/env bash
set -euo pipefail

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

bashio::log.info() { :; }
bashio::log.warning() { :; }
bashio::log.error() { :; }

# Load function definitions without starting the add-on.
CLAUDE_RUN_SH_SKIP_MAIN=true
source "$repo_root/claude-terminal/run.sh"

config_tmux_mouse=false
config_use_persistent_claude=true
config_auto_update_claude_on_start=false
bashio::config() {
    case "$1" in
        tmux_mouse) printf '%s\n' "$config_tmux_mouse" ;;
        use_persistent_claude) printf '%s\n' "$config_use_persistent_claude" ;;
        auto_update_claude_on_start) printf '%s\n' "$config_auto_update_claude_on_start" ;;
        *) printf '%s\n' "${2:-}" ;;
    esac
}

HOME="$tmp_dir/home"
TMUX_WRAPPER_PATH="$tmp_dir/tmux-claude"
mkdir -p "$HOME"
setup_tmux
grep -qx 'set -g mouse false' "$HOME/.tmux.conf" || fail "tmux mouse should default to false"

config_tmux_mouse=true
setup_tmux
grep -qx 'set -g mouse true' "$HOME/.tmux.conf" || fail "tmux mouse option should be configurable"

PERSISTENT_CLAUDE_ROOT="$tmp_dir/npm"
CLAUDE_BIN_LINK="$tmp_dir/claude"
mkdir -p "$PERSISTENT_CLAUDE_ROOT/bin" \
    "$PERSISTENT_CLAUDE_ROOT/lib/node_modules/@anthropic-ai/claude-code"
printf '#!/bin/sh\n' > "$PERSISTENT_CLAUDE_ROOT/bin/claude"
chmod +x "$PERSISTENT_CLAUDE_ROOT/bin/claude"
printf '{}\n' > "$PERSISTENT_CLAUDE_ROOT/lib/node_modules/@anthropic-ai/claude-code/package.json"
setup_persistent_claude
[ "$(readlink "$CLAUDE_BIN_LINK")" = "$PERSISTENT_CLAUDE_ROOT/bin/claude" ] || \
    fail "current npm Claude layout was not activated"

# Older npm releases expose bin/claude as a symlink to cli.js. Keep accepting it.
rm "$PERSISTENT_CLAUDE_ROOT/bin/claude"
printf '#!/usr/bin/env node\n' > "$PERSISTENT_CLAUDE_ROOT/lib/node_modules/@anthropic-ai/claude-code/cli.js"
chmod +x "$PERSISTENT_CLAUDE_ROOT/lib/node_modules/@anthropic-ai/claude-code/cli.js"
ln -s ../lib/node_modules/@anthropic-ai/claude-code/cli.js "$PERSISTENT_CLAUDE_ROOT/bin/claude"
setup_persistent_claude
[ "$(readlink "$CLAUDE_BIN_LINK")" = "$PERSISTENT_CLAUDE_ROOT/bin/claude" ] || \
    fail "legacy npm Claude layout was not activated"

# Load the package helper definitions without running its command dispatcher.
PERSISTENT_PACKAGES_SKIP_MAIN=true
source "$repo_root/claude-terminal/scripts/persistent-packages.sh"

config_apk_packages=$'tmux\nopenssh-client'
config_pip_packages=$'requests\nyaml'
bashio::config() {
    case "$1" in
        persistent_apk_packages) printf '%s\n' "$config_apk_packages" ;;
        persistent_pip_packages) printf '%s\n' "$config_pip_packages" ;;
        *) printf '%s\n' "${2:-}" ;;
    esac
}

persist_apk_install() { printf '%s\n' "$@" > "$tmp_dir/apk.args"; }
persist_pip_install() { printf '%s\n' "$@" > "$tmp_dir/pip.args"; }
auto_install_packages
printf 'tmux\nopenssh-client\n' > "$tmp_dir/apk.expected"
printf 'requests\nyaml\n' > "$tmp_dir/pip.expected"
cmp -s "$tmp_dir/apk.expected" "$tmp_dir/apk.args" || fail "APK list was not passed as separate values"
cmp -s "$tmp_dir/pip.expected" "$tmp_dir/pip.args" || fail "pip list was not passed as separate values"

# Older Bashio versions may return JSON arrays; accept those too.
config_apk_packages='["git","nano"]'
config_pip_packages='["httpx","ruff"]'
auto_install_packages
printf 'git\nnano\n' > "$tmp_dir/apk.expected"
printf 'httpx\nruff\n' > "$tmp_dir/pip.expected"
cmp -s "$tmp_dir/apk.expected" "$tmp_dir/apk.args" || fail "JSON APK list compatibility failed"
cmp -s "$tmp_dir/pip.expected" "$tmp_dir/pip.args" || fail "JSON pip list compatibility failed"

# Empty options must be a no-op.
config_apk_packages='[]'
config_pip_packages=''
rm "$tmp_dir/apk.args" "$tmp_dir/pip.args"
auto_install_packages
[ ! -e "$tmp_dir/apk.args" ] || fail "empty APK list should not install"
[ ! -e "$tmp_dir/pip.args" ] || fail "empty pip list should not install"

echo "All regression tests passed"
