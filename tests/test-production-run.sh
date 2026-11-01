#!/usr/bin/env bash
set -euo pipefail

repo_root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
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
config_dangerous=false
config_remote_control=false
config_extra_args=''
config_working_directory=''
config_auto_launch=true
bashio::config() {
    case "$1" in
        dangerously_skip_permissions) printf '%s\n' "$config_dangerous" ;;
        enable_remote_control) printf '%s\n' "$config_remote_control" ;;
        claude_extra_args) printf '%s\n' "$config_extra_args" ;;
        working_directory) printf '%s\n' "$config_working_directory" ;;
        auto_launch_claude) printf '%s\n' "$config_auto_launch" ;;
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

# ~/.tmux.conf is rewritten on every start, so user settings live in
# ~/.tmux.local.conf. It must be sourced last, or the defaults would win.
[ "$(grep -v '^#' "$HOME/.tmux.conf" | grep -v '^$' | tail -1)" = 'source-file -q ~/.tmux.local.conf' ] || \
    fail "tmux.conf must source ~/.tmux.local.conf as its last setting"
grep -qx 'set -g focus-events on' "$HOME/.tmux.conf" || \
    fail "tmux must pass focus events through to Claude Code"

# The frontend fix has to be reachable from the page that embeds ttyd.
clipboard_bridge="$repo_root/claude-terminal/image-service/public/terminal-clipboard.js"
terminal_page="$repo_root/claude-terminal/image-service/public/index.html"
[ -f "$clipboard_bridge" ] || fail "clipboard bridge is missing"
grep -q 'src="terminal-clipboard.js"' "$terminal_page" || \
    fail "terminal page must load the clipboard bridge"
grep -q 'installTerminalClipboard(iframe)' "$terminal_page" || \
    fail "terminal page must attach the clipboard bridge to the ttyd iframe"

# The on-screen keyboard shrinks the visual viewport but not 100vh, so without
# this the prompt ends up behind the keyboard.
grep -q 'window.visualViewport' "$terminal_page" || \
    fail "terminal page must follow the visual viewport so the keyboard cannot cover the prompt"
grep -q 'interactive-widget=resizes-content' "$terminal_page" || \
    fail "the viewport must shrink with the on-screen keyboard, not sit behind it"

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

# /data/npm is excluded from backups: after a restore it is empty, and the
# install must come back rather than silently using the baked binary.
rm -rf "$PERSISTENT_CLAUDE_ROOT"
# A script on PATH, not a function: run.sh calls npm through timeout
export npm_calls="$tmp_dir/npm-calls"
mkdir -p "$tmp_dir/fake-npm"
cat > "$tmp_dir/fake-npm/npm" << 'NPM_EOF'
#!/bin/sh
printf '%s %s\n' "$NPM_CONFIG_PREFIX" "$*" >> "$npm_calls"
mkdir -p "$NPM_CONFIG_PREFIX/bin" "$NPM_CONFIG_PREFIX/lib/node_modules/@anthropic-ai/claude-code"
printf '#!/bin/sh\n' > "$NPM_CONFIG_PREFIX/bin/claude"
chmod +x "$NPM_CONFIG_PREFIX/bin/claude"
printf '{}\n' > "$NPM_CONFIG_PREFIX/lib/node_modules/@anthropic-ai/claude-code/package.json"
NPM_EOF
chmod +x "$tmp_dir/fake-npm/npm"
# macOS has no timeout(1); the add-on's Alpine image does. Stand in with one
# that just runs the command.
if ! command -v timeout >/dev/null 2>&1; then
    printf '#!/bin/sh\nshift\nexec "$@"\n' > "$tmp_dir/fake-npm/timeout"
    chmod +x "$tmp_dir/fake-npm/timeout"
fi
saved_path="$PATH"
PATH="$tmp_dir/fake-npm:$PATH"
setup_persistent_claude
grep -q "^$PERSISTENT_CLAUDE_ROOT install -g @anthropic-ai/claude-code@" "$npm_calls" || \
    fail "missing persistent Claude was not reinstalled"
[ "$(readlink "$CLAUDE_BIN_LINK")" = "$PERSISTENT_CLAUDE_ROOT/bin/claude" ] || \
    fail "reinstalled persistent Claude was not activated"

# An existing install is not reinstalled on every start
: > "$npm_calls"
setup_persistent_claude
[ ! -s "$npm_calls" ] || fail "existing persistent Claude should not be reinstalled"
PATH="$saved_path"

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


# Launch flags: built once as shell text, then parsed exactly once by eval,
# so quoting in claude_extra_args survives into separate argv entries.
[ "$(build_claude_flags)" = "--add-dir /data/uploads" ] || fail "no options should mean only the uploads folder"
config_dangerous=true
config_remote_control=true
config_extra_args="--model x --append-system-prompt 'be terse'"
flags=$(build_claude_flags)
argv_dump() { for a in "$@"; do printf '[%s]' "$a"; done; }
got=$(eval "argv_dump $flags")
[ "$got" = "[--add-dir][/data/uploads][--dangerously-skip-permissions][--remote-control][Home Assistant][--model][x][--append-system-prompt][be terse]" ] || \
    fail "flags must parse into the expected argv, got: $got"
launch=$(get_claude_launch_command)
[[ "$launch" == *"/usr/local/bin/claude $flags"* ]] || fail "auto-launch command must carry the flags"
if [ ! -f /usr/local/bin/claude-session-picker ]; then
    # Without the picker, picker mode falls back to launching Claude directly
    config_auto_launch=false
    [[ "$(get_claude_launch_command)" == *"/usr/local/bin/claude $flags"* ]] || \
        fail "picker-mode fallback must carry the flags too"
    config_auto_launch=true
fi
config_dangerous=false; config_remote_control=false; config_extra_args=''

# Working directory: default, existing path, and a typo falls back
[ "$(get_working_directory)" = "/config" ] || fail "working_directory should default to /config"
config_working_directory="$tmp_dir"
[ "$(get_working_directory)" = "$tmp_dir" ] || fail "an existing working_directory should be used"
config_working_directory="$tmp_dir/does-not-exist"
[ "$(get_working_directory)" = "/config" ] || fail "a missing working_directory should fall back to /config"
config_working_directory=''

grep -q 'new-session -s claude -c "${CLAUDE_WORKDIR:-/config}"' "$TMUX_WRAPPER_PATH" || \
    fail "tmux wrapper must start new sessions in CLAUDE_WORKDIR"

# On the Alpine 3.24 base, bashio::config fails when the Supervisor API can't be
# reached. Under set -e an unguarded `x=$(bashio::config ...)` ends startup, so
# every option read must fall back to its default. The subshell runs in the
# background because bash ignores set -e in a subshell tested with || or if.
(
    set -e
    bashio::config() { return 1; }
    setup_tmux
    grep -qx 'set -g mouse off' "$HOME/.tmux.conf"
    [ "$(get_working_directory)" = "/config" ]
    [ "$(build_claude_flags)" = "--add-dir /data/uploads" ]
    [[ "$(get_claude_launch_command)" == *"/usr/local/bin/claude"* ]]
    unset CLAUDE_CODE_OAUTH_TOKEN
    export_oauth_token
    [ -z "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]
    echo survived > "$tmp_dir/option-reads"
) &
wait $! || true
[ "$(cat "$tmp_dir/option-reads" 2>/dev/null)" = "survived" ] || \
    fail "a failed option read must fall back to the default, not end startup"
bad_reads=$(grep -nE '^\s*(local )?\w+=\$\(bashio::config [^)]*\)\s*$' "$repo_root/claude-terminal/run.sh" || true)
[ -z "$bad_reads" ] || fail "option reads without a fallback: $bad_reads"

# A venv from an older Python is rebuilt and its packages reinstalled
venv="$tmp_dir/venv"
mkdir -p "$venv/lib/python3.12/site-packages/"{Requests-2.32.3,pip-24.3.1,six-1.17.0,broken-1.0}.dist-info
printf 'version = 3.12.16\n' > "$venv/pyvenv.cfg"
printf 'Metadata-Version: 2.1\nName: Requests\nVersion: 2.32.3\n\nName: not-this\n' \
    > "$venv/lib/python3.12/site-packages/Requests-2.32.3.dist-info/METADATA"
printf 'Name: pip\n' > "$venv/lib/python3.12/site-packages/pip-24.3.1.dist-info/METADATA"
printf 'Name: six\n' > "$venv/lib/python3.12/site-packages/six-1.17.0.dist-info/METADATA"
printf 'Name: broken\n' > "$venv/lib/python3.12/site-packages/broken-1.0.dist-info/METADATA"
mkdir -p "$venv/lib/python3.12/site-packages/mytool-0.1.dist-info"
printf 'Name: mytool\n' > "$venv/lib/python3.12/site-packages/mytool-0.1.dist-info/METADATA"
printf '{"url": "git+https://example.com/mytool.git", "vcs_info": {"vcs": "git"}}\n' \
    > "$venv/lib/python3.12/site-packages/mytool-0.1.dist-info/direct_url.json"
fake_pip="$tmp_dir/fake-pip"
cat > "$fake_pip" << 'FAKE'
#!/usr/bin/env bash
# pip install -q ... NAME: the name is the last argument
name="${!#}"
[ "$name" = broken ] && exit 1
echo "$*" >> "$PIP_ARGS_LOG"
echo "$name" >> "$PIP_LOG"
FAKE
fake_python="$tmp_dir/fake-python"
cat > "$fake_python" << 'FAKE'
#!/usr/bin/env bash
[ "$1" = "-c" ] && { echo 3.14; exit 0; }
[ "$1 $2" = "-m venv" ] || exit 1
mkdir -p "$3/bin"
printf 'version = 3.14.10\n' > "$3/pyvenv.cfg"
cp "$FAKE_PIP" "$3/bin/pip"
FAKE
chmod +x "$fake_python" "$fake_pip"
export FAKE_PIP="$fake_pip" PIP_LOG="$tmp_dir/pip.log" PIP_ARGS_LOG="$tmp_dir/pip-args.log"
warnings="$tmp_dir/warnings"
bashio::log.warning() { echo "$*" >> "$warnings"; }
PERSIST_VENV="$venv" PYTHON_BIN="$fake_python" migrate_python_venv
[ "$(sort "$tmp_dir/pip.log" | tr '\n' ' ')" = "Requests six " ] || \
    fail "the rebuilt venv must reinstall the old packages (not pip), got: $(cat "$tmp_dir/pip.log")"
grep -q 'version = 3.14' "$venv/pyvenv.cfg" || fail "the venv must be recreated for the new Python"
[ ! -e "$venv/lib/python3.12" ] || fail "the old venv must be removed"
todo="$tmp_dir/reinstall-needed.txt"
grep -qx 'broken' "$todo" || fail "a failed reinstall must be kept in reinstall-needed.txt"
grep -qx 'mytool (from git+https://example.com/mytool.git)' "$todo" || \
    fail "a package installed from a URL must be listed with its source, not reinstalled by name"
! grep -q mytool "$tmp_dir/pip.log" || fail "a package installed from a URL must not be reinstalled from PyPI"
grep -q 'broken.*mytool\|mytool.*broken' "$warnings" || fail "packages to reinstall by hand must be named in the log"
grep -q -- '--timeout 10 --retries 1' "$tmp_dir/pip-args.log" || \
    fail "reinstalls must use a short timeout so an offline boot doesn't stall"
rm -f "$tmp_dir/pip.log"
PERSIST_VENV="$venv" PYTHON_BIN="$fake_python" migrate_python_venv
[ ! -e "$tmp_dir/pip.log" ] || fail "a venv for the current Python must be left alone"

# Files persist-install copied on an older Alpine release are named once.
# A file with an identical system copy was just reinstalled from the options.
persist="$tmp_dir/packages"
system="$tmp_dir/system"
mkdir -p "$persist/bin" "$persist/lib" "$system/usr/bin"
printf 'old htop\n' > "$persist/bin/htop"
printf 'old lib\n' > "$persist/lib/libfoo.so.1"
printf 'new ssh\n' > "$persist/bin/ssh"
printf 'new ssh\n' > "$system/usr/bin/ssh"
printf '3.24.1\n' > "$tmp_dir/alpine-release"
check_release() {
    PERSIST_ROOT="$persist" SYSTEM_ROOT="$system" ALPINE_RELEASE_FILE="$tmp_dir/alpine-release" \
        check_persisted_alpine_release
}
: > "$warnings"
check_release
grep -q 'from Alpine 3.21 to 3.24.*htop.*libfoo.so.1' "$warnings" || \
    fail "files from before the marker existed must be reported after the move to 3.24"
! grep -q 'ssh' "$warnings" || fail "a file just reinstalled from the options must not be reported"
[ "$(cat "$persist/.alpine-release")" = "3.24" ] || fail "the current release must be recorded"
: > "$warnings"
check_release
[ ! -s "$warnings" ] || fail "an unchanged release must not warn again"
printf '3.21.4\n' > "$tmp_dir/alpine-release"
rm -f "$persist/.alpine-release"
check_release
[ ! -s "$warnings" ] || fail "files from before the marker must not warn on a 3.21 image"
bashio::log.warning() { :; }

# Uploads older than 30 days go; newer ones and missing folders are fine
UPLOAD_PRUNE_DIRS="$tmp_dir/uploads $tmp_dir/images $tmp_dir/missing"
mkdir -p "$tmp_dir/uploads" "$tmp_dir/images"
touch "$tmp_dir/uploads/new.pdf"
touch -t 202001010000 "$tmp_dir/uploads/old.pdf" "$tmp_dir/images/pasted-1.png"
prune_uploads
[ -f "$tmp_dir/uploads/new.pdf" ] || fail "prune_uploads must keep recent uploads"
[ ! -e "$tmp_dir/uploads/old.pdf" ] || fail "prune_uploads must remove uploads older than 30 days"
[ ! -e "$tmp_dir/images/pasted-1.png" ] || fail "prune_uploads must also clear the pre-2.3.7 images folder"
unset UPLOAD_PRUNE_DIRS

echo "Production run.sh regression suite passed"
