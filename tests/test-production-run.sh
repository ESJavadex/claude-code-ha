#!/usr/bin/env bash
set -euo pipefail

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT

fail() {
    echo "FAIL (production run.sh): $*" >&2
    exit 1
}

bashio::log.info() { :; }
bashio::log.warning() { :; }
bashio::log.error() { :; }

config_tmux_mouse=false
config_use_persistent_claude=true
config_auto_update_claude_on_start=false
config_apk_packages=''
config_pip_packages=''
bashio::config() {
    case "$1" in
        tmux_mouse) printf '%s\n' "$config_tmux_mouse" ;;
        use_persistent_claude) printf '%s\n' "$config_use_persistent_claude" ;;
        auto_update_claude_on_start) printf '%s\n' "$config_auto_update_claude_on_start" ;;
        persistent_apk_packages) printf '%s\n' "$config_apk_packages" ;;
        persistent_pip_packages) printf '%s\n' "$config_pip_packages" ;;
        *) printf '%s\n' "${2:-}" ;;
    esac
}

# Load only the production entrypoint. No helper script may redefine its functions.
CLAUDE_RUN_SH_SKIP_MAIN=true
source "$repo_root/claude-terminal/run.sh"

HOME="$tmp_dir/home"
TMUX_WRAPPER_PATH="$tmp_dir/tmux-claude"
mkdir -p "$HOME"
setup_tmux
grep -qx 'set -g mouse off' "$HOME/.tmux.conf" || fail "tmux mouse should default to off"

config_tmux_mouse=true
setup_tmux
grep -qx 'set -g mouse on' "$HOME/.tmux.conf" || fail "tmux mouse option should enable mouse mode"

config_tmux_mouse=''
setup_tmux
grep -qx 'set -g mouse off' "$HOME/.tmux.conf" || fail "empty optional bool should safely disable mouse mode"

# Claude Code's /copy emits OSC 52. tmux defaults to set-clipboard=external, which
# drops what applications in the pane send, and only emits OSC 52 outwards when the
# outer terminal advertises the Ms capability.
grep -qx 'set -g set-clipboard on' "$HOME/.tmux.conf" || \
    fail "tmux must accept and forward OSC 52 from applications"
grep -qx "set -as terminal-features ',\*:clipboard'" "$HOME/.tmux.conf" || \
    fail "tmux must advertise the clipboard capability so OSC 52 reaches ttyd"

# The frontend fix has to be reachable from the page that embeds ttyd.
clipboard_bridge="$repo_root/claude-terminal/image-service/public/terminal-clipboard.js"
terminal_page="$repo_root/claude-terminal/image-service/public/index.html"
[ -f "$clipboard_bridge" ] || fail "clipboard bridge is missing"
grep -q 'src="terminal-clipboard.js"' "$terminal_page" || \
    fail "terminal page must load the clipboard bridge"
grep -q 'installTerminalClipboard(iframe)' "$terminal_page" || \
    fail "terminal page must attach the clipboard bridge to the ttyd iframe"

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

rm "$PERSISTENT_CLAUDE_ROOT/bin/claude"
printf '#!/usr/bin/env node\n' > "$PERSISTENT_CLAUDE_ROOT/lib/node_modules/@anthropic-ai/claude-code/cli.js"
chmod +x "$PERSISTENT_CLAUDE_ROOT/lib/node_modules/@anthropic-ai/claude-code/cli.js"
ln -s ../lib/node_modules/@anthropic-ai/claude-code/cli.js "$PERSISTENT_CLAUDE_ROOT/bin/claude"
setup_persistent_claude
[ "$(readlink "$CLAUDE_BIN_LINK")" = "$PERSISTENT_CLAUDE_ROOT/bin/claude" ] || \
    fail "legacy npm Claude layout was not activated"

# A package can look installed while its architecture-specific binary is absent.
rm "$CLAUDE_BIN_LINK" "$PERSISTENT_CLAUDE_ROOT/bin/claude"
printf '#!/bin/sh\nexit 1\n' > "$PERSISTENT_CLAUDE_ROOT/bin/claude"
chmod +x "$PERSISTENT_CLAUDE_ROOT/bin/claude"
setup_persistent_claude
[ ! -e "$CLAUDE_BIN_LINK" ] || fail "non-working persistent Claude should not replace the baked binary"

PERSIST_INSTALL_LOG="$tmp_dir/persist-install.log"
PERSIST_INSTALL_BIN="$tmp_dir/persist-install"
PERSIST_INSTALL_SOURCE="$tmp_dir/no-bundled-installer"
export PERSIST_INSTALL_LOG
cat > "$PERSIST_INSTALL_BIN" << 'CAPTURE_EOF'
#!/usr/bin/env bash
printf '%s\n' '---' "$@" >> "$PERSIST_INSTALL_LOG"
for argument in "$@"; do
    if [ -n "${PERSIST_INSTALL_FAIL_ON:-}" ] && [ "$argument" = "$PERSIST_INSTALL_FAIL_ON" ]; then
        exit 1
    fi
done
CAPTURE_EOF
chmod +x "$PERSIST_INSTALL_BIN"

config_apk_packages=$'tmux\nopenssh-client'
config_pip_packages=$'requests\nyaml'
setup_persistent_packages
printf '%s\n' '---' 'tmux' '---' 'openssh-client' '---' '--python' 'requests' 'yaml' > "$tmp_dir/expected.log"
cmp -s "$tmp_dir/expected.log" "$PERSIST_INSTALL_LOG" || fail "newline Bashio lists were not installed correctly"

config_apk_packages='["git","nano"]'
config_pip_packages='["httpx","ruff"]'
: > "$PERSIST_INSTALL_LOG"
setup_persistent_packages
printf '%s\n' '---' 'git' '---' 'nano' '---' '--python' 'httpx' 'ruff' > "$tmp_dir/expected.log"
cmp -s "$tmp_dir/expected.log" "$PERSIST_INSTALL_LOG" || fail "JSON Bashio lists were not installed correctly"

config_apk_packages='[]'
config_pip_packages=''
: > "$PERSIST_INSTALL_LOG"
setup_persistent_packages
[ ! -s "$PERSIST_INSTALL_LOG" ] || fail "empty package options should be a no-op"

# One optional package failure must not terminate add-on startup or skip the rest.
config_apk_packages=$'missing-package\ngit'
config_pip_packages=''
PERSIST_INSTALL_FAIL_ON='missing-package'
export PERSIST_INSTALL_FAIL_ON
: > "$PERSIST_INSTALL_LOG"
setup_persistent_packages
printf '%s\n' '---' 'missing-package' '---' 'git' > "$tmp_dir/expected.log"
cmp -s "$tmp_dir/expected.log" "$PERSIST_INSTALL_LOG" || fail "package failure did not continue safely"

echo "Production run.sh regression suite passed"
