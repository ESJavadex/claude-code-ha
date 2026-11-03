#!/usr/bin/env bash
set -euo pipefail

repo_root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT
script="$repo_root/claude-terminal/scripts/ha-statusline.sh"

fail() {
    echo "FAIL (status line): $*" >&2
    exit 1
}

strip_ansi() { sed 's/\x1b\[[0-9;]*m//g'; }

# --- ha-statusline: the script Claude Code runs -----------------------------

export HA_STATUSLINE_CACHE_DIR="$tmp_dir/cache"
export HA_STATUSLINE_CONFIG="$tmp_dir/ha-statusline.json"
export HA_STATUSLINE_API="file://$tmp_dir/api"
export SUPERVISOR_TOKEN=test-token
mkdir -p "$tmp_dir/api"

# A friendly name carrying an escape sequence must not reach the terminal
cat > "$tmp_dir/api/states" << 'STATES'
[
  {"entity_id": "person.ana", "state": "home", "attributes": {}},
  {"entity_id": "person.ben", "state": "not_home", "attributes": {}},
  {"entity_id": "light.hall", "state": "unavailable", "attributes": {}},
  {"entity_id": "switch.fan", "state": "unavailable", "attributes": {}},
  {"entity_id": "sensor.door_battery", "state": "12", "attributes": {"device_class": "battery", "friendly_name": "Door\u001b]0;pwned\u0007"}},
  {"entity_id": "sensor.ok_battery", "state": "90", "attributes": {"device_class": "battery"}},
  {"entity_id": "sensor.gone_battery", "state": "unknown", "attributes": {"device_class": "battery"}},
  {"entity_id": "binary_sensor.smoke", "state": "on", "attributes": {"device_class": "smoke", "friendly_name": "Kitchen smoke"}},
  {"entity_id": "binary_sensor.motion", "state": "on", "attributes": {"device_class": "motion"}},
  {"entity_id": "update.core", "state": "on", "attributes": {}},
  {"entity_id": "sensor.co2", "state": "820", "attributes": {"unit_of_measurement": "ppm", "friendly_name": "Living CO2"}}
]
STATES
printf '{"entities":[{"entity_id":"sensor.co2","label":"CO2"},{"entity_id":"sensor.nope","label":""}]}\n' > "$HA_STATUSLINE_CONFIG"

"$script" --refresh || fail "--refresh failed against the test API"
home=$("$script" --home)
case "$home" in *$'\e]'*|*$'\a'*) fail "escape sequence from an entity name reached the output" ;; esac
home=$(strip_ansi <<< "$home")
for want in "🚨 Kitchen smoke" "🏠 1/2 home" "⚠ 2 unavailable" "🔋 Door]0;pwned" "⬆ 1 update" "CO2 820 ppm" "sensor.nope missing"; do
    [[ "$home" == *"$want"* ]] || fail "home line lacks '$want': $home"
done
[[ "$home" != *motion* ]] || fail "motion is not an alert: $home"

# Claude's JSON gives line 1; the home line follows
out=$(printf '{"model":{"display_name":"Opus"},"workspace":{"current_dir":"%s"},"context_window":{"used_percentage":55.2}}' "$tmp_dir" \
    | "$script" | strip_ansi)
[ "$(wc -l <<< "$out")" -eq 2 ] || fail "expected two lines: $out"
[[ "$(head -1 <<< "$out")" == "Opus · ▓▓▓▓▓░░░░░ 55% · 📁 $(basename "$tmp_dir")"* ]] || \
    fail "Claude line wrong: $(head -1 <<< "$out")"

# Empty stdin (or none at all) still prints something
out=$("$script" < /dev/null | strip_ansi)
[[ "$out" == "Claude ·"* ]] || fail "empty input should fall back to 'Claude': $out"

# Home Assistant down: an error line, never a failure
HA_STATUSLINE_API="file://$tmp_dir/missing" "$script" --refresh 2>/dev/null && \
    fail "--refresh should fail when Home Assistant is unreachable"
[[ "$("$script" --home | strip_ansi)" == "🏠 Home Assistant unreachable"* ]] || \
    fail "unreachable HA should say so"

# No cache yet: a stale or missing cache starts a background refresh and the
# line says it is loading instead of waiting
rm -rf "$HA_STATUSLINE_CACHE_DIR"
[[ "$("$script" --home | strip_ansi)" == *"loading"* ]] || fail "first run should say loading"
for _ in 1 2 3 4 5 6 7 8 9 10; do
    [ -s "$HA_STATUSLINE_CACHE_DIR/summary.json" ] && break
    sleep 0.3
done
[ -s "$HA_STATUSLINE_CACHE_DIR/summary.json" ] || fail "background refresh never wrote the cache"

# --- setup_statusline in run.sh ---------------------------------------------

bashio::log.info() { :; }
bashio::log.warning() { printf '%s\n' "$*" >> "$tmp_dir/warnings"; }
bashio::log.error() { :; }
config_statusline=home_assistant
config_statusline_entities=''
bashio::config() {
    case "$1" in
        statusline) printf '%s\n' "$config_statusline" ;;
        statusline_entities) printf '%s\n' "$config_statusline_entities" ;;
        *) printf '%s\n' "${2:-}" ;;
    esac
}
export CLAUDE_RUN_SH_SKIP_MAIN=true
# shellcheck source=../claude-terminal/run.sh
source "$repo_root/claude-terminal/run.sh"

HOME="$tmp_dir/home"
HA_STATUSLINE_BIN="$tmp_dir/bin/ha-statusline"
export HA_STATUSLINE_SOURCE="$script"
settings="$HOME/.claude/settings.json"
mkdir -p "$tmp_dir/bin"

# No settings yet: ours is added, and the script installed
setup_statusline
[ -x "$HA_STATUSLINE_BIN" ] || fail "script not installed"
[ "$(jq -r '.statusLine.command' "$settings")" = "$HA_STATUSLINE_BIN" ] || fail "status line not added"
[ "$(jq -r '.statusLine.refreshInterval' "$settings")" = 30 ] || fail "refreshInterval not set"

# Other settings survive
jq '.theme = "dark"' "$settings" > "$settings.new" && mv "$settings.new" "$settings"
setup_statusline
[ "$(jq -r '.theme' "$settings")" = dark ] || fail "other settings were lost"

# Off removes ours only
config_statusline=off
setup_statusline
[ "$(jq -r 'has("statusLine")' "$settings")" = false ] || fail "off should remove our status line"
[ "$(jq -r '.theme' "$settings")" = dark ] || fail "off lost other settings"

# A status line the user made (e.g. with /statusline) is never touched
user_cmd="$HOME/.claude/statusline.sh"
jq --arg c "$user_cmd" '.statusLine = {type: "command", command: $c}' "$settings" > "$settings.new" \
    && mv "$settings.new" "$settings"
config_statusline=home_assistant
setup_statusline
[ "$(jq -r '.statusLine.command' "$settings")" = "$user_cmd" ] || fail "user status line replaced"
config_statusline=off
setup_statusline
[ "$(jq -r '.statusLine.command' "$settings")" = "$user_cmd" ] || fail "off removed the user's status line"

# Invalid JSON is left as it is
printf '{ broken' > "$settings"
config_statusline=home_assistant
setup_statusline
[ "$(cat "$settings")" = '{ broken' ] || fail "invalid settings.json was rewritten"

# A missing option ("null" from bashio, e.g. after an upgrade) means on
rm -f "$settings"
config_statusline=null
setup_statusline
[ "$(jq -r '.statusLine.command' "$settings")" = "$HA_STATUSLINE_BIN" ] || fail "missing option should default to on"

# Entities: labels kept, anything that isn't an entity ID skipped
: > "$tmp_dir/warnings"
config_statusline_entities='["CO₂=sensor.air_co2", "sensor.temp", "$(reboot)", "Bad=../../etc"]'
setup_statusline
[ "$(jq -c '.entities' "$HA_STATUSLINE_CONFIG")" = \
  '[{"entity_id":"sensor.air_co2","label":"CO₂"},{"entity_id":"sensor.temp","label":""}]' ] || \
    fail "entities parsed wrong: $(jq -c '.entities' "$HA_STATUSLINE_CONFIG")"
[ "$(grep -c skipping "$tmp_dir/warnings")" -eq 2 ] || fail "invalid entities should be warned about"

echo "Status line tests passed"
