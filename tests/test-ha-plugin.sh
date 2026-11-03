#!/usr/bin/env bash
# setup_ha_plugin: installs the bundled Home Assistant plugin once, updates it
# when the image ships a newer version, and never overrides the user's choice
# to disable it. Uses a fake `claude` that records calls and keeps plugin state.
set -euo pipefail

repo_root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT

fail() {
    echo "FAIL (ha plugin): $*" >&2
    exit 1
}

bashio::log.info() { :; }
bashio::log.warning() { :; }
bashio::log.error() { :; }

config_ha_plugin=true
bashio::config() {
    case "$1" in
        home_assistant_plugin) printf '%s\n' "$config_ha_plugin" ;;
        *) printf '%s\n' "${2:-}" ;;
    esac
}

CLAUDE_RUN_SH_SKIP_MAIN=true
# shellcheck source=/dev/null
source "$repo_root/claude-terminal/run.sh"

export HOME="$tmp_dir/home"
mkdir -p "$HOME"

# Bundled marketplace
export HA_PLUGIN_MARKETPLACE_DIR="$tmp_dir/mkt"
mkdir -p "$HA_PLUGIN_MARKETPLACE_DIR/homeassistant-config/.claude-plugin"
bundle() { printf '{"name":"homeassistant-config","version":"%s"}\n' "$1" \
    > "$HA_PLUGIN_MARKETPLACE_DIR/homeassistant-config/.claude-plugin/plugin.json"; }
bundle 2.0.0

# Fake claude: state in $FAKE (installed version + enabled flag), calls in $CALLS
export FAKE="$tmp_dir/fake" CALLS="$tmp_dir/calls"
mkdir -p "$tmp_dir/bin" "$FAKE"
cat > "$tmp_dir/bin/claude" <<'SH'
#!/usr/bin/env bash
[ "$1" = plugin ] || exit 1
shift
echo "$*" >> "$CALLS"
mkt="$HA_PLUGIN_MARKETPLACE_DIR/homeassistant-config/.claude-plugin/plugin.json"
case "$1 $2" in
    "list --json")
        if [ -f "$FAKE/version" ]; then
            printf '[{"id":"homeassistant-config@claude-homeassistant-plugins","version":"%s","enabled":%s}]\n' \
                "$(cat "$FAKE/version")" "$(cat "$FAKE/enabled")"
        else
            echo '[]'
        fi ;;
    "marketplace add"|"marketplace update") : ;;
    "install homeassistant-config@claude-homeassistant-plugins")
        jq -r .version "$mkt" > "$FAKE/version"; echo true > "$FAKE/enabled" ;;
    "update homeassistant-config@claude-homeassistant-plugins")
        jq -r .version "$mkt" > "$FAKE/version" ;;
    "disable homeassistant-config@claude-homeassistant-plugins") echo false > "$FAKE/enabled" ;;
    "enable homeassistant-config@claude-homeassistant-plugins") echo true > "$FAKE/enabled" ;;
    *) exit 1 ;;
esac
SH
chmod +x "$tmp_dir/bin/claude"
export PATH="$tmp_dir/bin:$PATH"

calls() { cat "$CALLS" 2>/dev/null || true; }
reset_calls() { : > "$CALLS"; }

# 1. First start installs it
setup_ha_plugin
calls | grep -qx 'marketplace add .*' || fail "first start must register the marketplace"
calls | grep -qx 'install homeassistant-config@claude-homeassistant-plugins' || fail "first start must install"
[ "$(cat "$FAKE/enabled")" = true ] || fail "plugin should be enabled after install"

# 2. Second start with the same image does nothing
reset_calls
setup_ha_plugin
[ -z "$(calls)" ] || fail "unchanged start must not call claude: $(calls)"

# 3. User disables it with /plugin; a new image updates but keeps it disabled
echo false > "$FAKE/enabled"
bundle 2.1.0
reset_calls
setup_ha_plugin
calls | grep -qx 'update homeassistant-config@claude-homeassistant-plugins' || fail "new bundled version must update"
calls | grep -q '^install ' && fail "must not reinstall (that re-enables it)"
calls | grep -q '^enable ' && fail "must not re-enable a plugin the user disabled"
[ "$(cat "$FAKE/version")" = 2.1.0 ] || fail "plugin should be at 2.1.0"
[ "$(cat "$FAKE/enabled")" = false ] || fail "user's disable must survive the update"

# 4. Option off disables it
echo true > "$FAKE/enabled"
config_ha_plugin=false
reset_calls
setup_ha_plugin
calls | grep -qx 'disable homeassistant-config@claude-homeassistant-plugins' || fail "option off must disable"
[ "$(cat "$FAKE/enabled")" = false ] || fail "plugin should be disabled"

# 5. Option back on enables it again
config_ha_plugin=true
reset_calls
setup_ha_plugin
calls | grep -qx 'enable homeassistant-config@claude-homeassistant-plugins' || fail "option back on must enable"
[ "$(cat "$FAKE/enabled")" = true ] || fail "plugin should be enabled again"

# 6. Option off on a fresh install never installs it
rm -rf "$FAKE"/* "$HOME/.claude"
config_ha_plugin=false
reset_calls
setup_ha_plugin
calls | grep -q '^install ' && fail "option off must not install"

# 7. Not bundled or no claude: silent no-op
config_ha_plugin=true
rm -rf "$HOME/.claude"
HA_PLUGIN_MARKETPLACE_DIR="$tmp_dir/missing" setup_ha_plugin || fail "missing bundle must not fail"
PATH="/usr/bin:/bin" setup_ha_plugin || fail "missing claude must not fail"

echo "ha plugin setup: all checks passed"
