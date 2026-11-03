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
export HA_STATUSLINE_SUPERVISOR_API="file://$tmp_dir/sup"
export SUPERVISOR_TOKEN=test-token
export TZ=UTC
mkdir -p "$tmp_dir/api" "$tmp_dir/sup/core" "$tmp_dir/sup/host" "$tmp_dir/sup/resolution"

# A friendly name carrying an escape sequence must not reach the terminal
cat > "$tmp_dir/api/states" << 'STATES'
[
  {"entity_id": "person.ana", "state": "home", "attributes": {}},
  {"entity_id": "person.ben", "state": "not_home", "attributes": {}},
  {"entity_id": "light.hall", "state": "unavailable", "attributes": {}},
  {"entity_id": "automation.broken", "state": "unavailable", "attributes": {}},
  {"entity_id": "automation.fine", "state": "on", "attributes": {}},
  {"entity_id": "sensor.door_battery", "state": "12", "attributes": {"device_class": "battery", "friendly_name": "Door\u001b]0;pwned\u0007"}},
  {"entity_id": "sensor.ok_battery", "state": "90", "attributes": {"device_class": "battery"}},
  {"entity_id": "sensor.gone_battery", "state": "unknown", "attributes": {"device_class": "battery"}},
  {"entity_id": "binary_sensor.smoke", "state": "on", "attributes": {"device_class": "smoke", "friendly_name": "Kitchen smoke"}},
  {"entity_id": "binary_sensor.motion", "state": "on", "attributes": {"device_class": "motion"}},
  {"entity_id": "update.core", "state": "on", "attributes": {}},
  {"entity_id": "weather.home", "state": "sunny", "attributes": {"temperature": 18, "temperature_unit": "°C"}},
  {"entity_id": "sensor.co2", "state": "820", "attributes": {"unit_of_measurement": "ppm", "friendly_name": "Living CO2"}}
]
STATES
old_backup=$(date -u -d "@$(( $(date +%s) - 10 * 86400 ))" +%Y-%m-%dT%H:%M:%S.123456+00:00)
printf '{"result":"ok","data":{"version":"2026.10.3","version_latest":"2026.11.0","update_available":true}}' > "$tmp_dir/sup/core/info"
printf '{"result":"ok","data":{"disk_total":100,"disk_used":91}}' > "$tmp_dir/sup/host/info"
printf '{"result":"ok","data":{"backups":[{"date":"%s"}]}}' "$old_backup" > "$tmp_dir/sup/backups"
printf '{"result":"ok","data":{"unhealthy":[],"unsupported":[],"issues":[{"type":"x"}]}}' > "$tmp_dir/sup/resolution/info"

all_home='alerts repairs automations backup disk core updates unavailable battery people weather'
printf '%s' "$all_home" | jq -Rc 'split(" ") | map({s: .}) + [{s: "entity", id: "sensor.co2", label: "CO2"}, {s: "entity", id: "sensor.nope", label: ""}] | {layout: .}' \
    > "$HA_STATUSLINE_CONFIG"

"$script" --refresh || fail "--refresh failed against the test API"
home=$("$script" --home)
case "$home" in *$'\e]'*|*$'\a'*) fail "escape sequence from an entity name reached the output" ;; esac
home=$(strip_ansi <<< "$home")
for want in "🏠 🚨 Kitchen smoke" "🩺 1 repair" "🤖 1 broken" "💾 10d" "💽 91%" "⬆ HA 2026.11.0" \
            "📦 1" "⚠ 2 unavailable" "🔋 Door]0;pwned" "👥 1/2" "☀ 18°C" "CO2 820 ppm" "sensor.nope missing"; do
    [[ "$home" == *"$want"* ]] || fail "home line lacks '$want': $home"
done
[[ "$home" != *motion* ]] || fail "motion is not an alert: $home"
[ "$(wc -l <<< "$home")" -eq 1 ] || fail "--home should be one line"

# Default layout: Claude, usage and tokens, then the home. Pieces with
# nothing to say are left out.
rm -f "$HA_STATUSLINE_CONFIG"
claude_json=$(jq -nc --arg d "$tmp_dir" '{model: {display_name: "Opus"}, workspace: {current_dir: $d},
    context_window: {used_percentage: 63.4, total_input_tokens: 45210, total_output_tokens: 3100},
    cost: {total_duration_ms: 4320000, total_lines_added: 12, total_lines_removed: 3},
    rate_limits: {five_hour: {used_percentage: 38, resets_at: 1800000000},
                  seven_day: {used_percentage: 95, resets_at: 1800000000}}}')
out=$("$script" <<< "$claude_json" | strip_ansi)
[ "$(wc -l <<< "$out")" -eq 3 ] || fail "expected three lines: $out"
[ "$(sed -n 1p <<< "$out")" = "Opus │ ✍️ 37% │ $(basename "$tmp_dir") │ 1h12m │ +12/-3" ] || \
    fail "line 1 wrong: $(sed -n 1p <<< "$out")"
[ "$(sed -n 2p <<< "$out")" = "5h ●●●○○ 62% ⟳ 08:00 │ 7d ○○○○○ 5% ⟳ Fri 08:00 │ in 45.2k · out 3.1k" ] || \
    fail "line 2 wrong: $(sed -n 2p <<< "$out")"
[[ "$(sed -n 3p <<< "$out")" == "🏠 🚨 Kitchen smoke │ 🩺 1 repair"* ]] || fail "line 3 wrong: $(sed -n 3p <<< "$out")"
[[ "$out" != *"👥"* && "$out" != *"☀"* ]] || fail "people and weather are not in the default layout"

# API-key users have no rate limits: the cost is shown instead
out=$(jq -c 'del(.rate_limits) | .cost.total_cost_usd = 0.4213' <<< "$claude_json" | "$script" | strip_ansi)
[[ "$(sed -n 2p <<< "$out")" == '$0.42 │ in 45.2k'* ]] || fail "cost not shown: $(sed -n 2p <<< "$out")"

# A new session: empty pieces and the empty usage line disappear
out=$("$script" < /dev/null | strip_ansi)
[ "$(sed -n 1p <<< "$out")" = "Claude │ ✍️ 100%" ] || fail "empty input line 1: $(sed -n 1p <<< "$out")"
[ "$(wc -l <<< "$out")" -eq 2 ] || fail "empty usage line should be dropped: $out"

# All fine at home: a short check mark
printf '[]' > "$tmp_dir/api/states"
printf '{"result":"ok","data":{"disk_total":100,"disk_used":40}}' > "$tmp_dir/sup/host/info"
printf '{"result":"ok","data":{"backups":[{"date":"%s"}]}}' "$(date -u +%Y-%m-%dT%H:%M:%S+00:00)" > "$tmp_dir/sup/backups"
printf '{"result":"ok","data":{"update_available":false}}' > "$tmp_dir/sup/core/info"
printf '{"result":"ok","data":{"unhealthy":[],"issues":[]}}' > "$tmp_dir/sup/resolution/info"
HA_STATUSLINE_SUPERVISOR_TTL=0 "$script" --refresh || fail "refresh failed"
[ "$("$script" --home | strip_ansi)" = "🏠 ✓" ] || fail "a healthy home should be just 🏠 ✓: $("$script" --home | strip_ansi)"

# Home Assistant down: an error line, never a failure
HA_STATUSLINE_API="file://$tmp_dir/missing" "$script" --refresh 2>/dev/null && \
    fail "--refresh should fail when Home Assistant is unreachable"
[ "$("$script" --home | strip_ansi)" = "🏠 Home Assistant unreachable" ] || fail "unreachable HA should say so"

# No cache yet: a background refresh starts and the line doesn't wait for it
rm -rf "$HA_STATUSLINE_CACHE_DIR"
[ "$("$script" --home | strip_ansi)" = "🏠 …" ] || fail "first run should show the loading mark"
for _ in 1 2 3 4 5 6 7 8 9 10; do
    [ -s "$HA_STATUSLINE_CACHE_DIR/states.json" ] && break
    sleep 0.3
done
[ -s "$HA_STATUSLINE_CACHE_DIR/states.json" ] || fail "background refresh never wrote the cache"

# A layout with only Claude pieces never touches Home Assistant
rm -rf "$HA_STATUSLINE_CACHE_DIR"
printf '{"layout":[{"s":"model"}]}' > "$HA_STATUSLINE_CONFIG"
[ "$("$script" < /dev/null | strip_ansi)" = "Claude" ] || fail "model-only layout"
sleep 0.5
[ ! -e "$HA_STATUSLINE_CACHE_DIR/states.json" ] || fail "a Claude-only layout should not refresh"

# The Supervisor token is only sent to http(s)://supervisor: any other API
# URL is refused before curl runs
mkdir -p "$tmp_dir/fakebin"
printf '#!/bin/sh\ntouch "%s/curl-called"\nexit 1\n' "$tmp_dir" > "$tmp_dir/fakebin/curl"
chmod +x "$tmp_dir/fakebin/curl"
for url in "https://evil.example/api" "http://supervisor.evil.example/core/api" "http://supervisor@evil.example/" "http://supervisor:8123/core/api"; do
    err=$(PATH="$tmp_dir/fakebin:$PATH" HA_STATUSLINE_API="$url" HA_STATUSLINE_SUPERVISOR_API="$url" "$script" --refresh 2>&1) && fail "$url accepted"
    [[ "$err" == *"refusing to send the Supervisor token"* ]] || fail "$url: no refusal message: $err"
    [ ! -e "$tmp_dir/curl-called" ] || fail "curl ran for $url"
done
PATH="$tmp_dir/fakebin:$PATH" HA_STATUSLINE_API="http://supervisor/core/api" "$script" --refresh 2>/dev/null || true
[ -e "$tmp_dir/curl-called" ] || fail "the real Supervisor URL should be allowed"

# --- setup_statusline in run.sh ---------------------------------------------

bashio::log.info() { :; }
bashio::log.warning() { printf '%s\n' "$*" >> "$tmp_dir/warnings"; }
bashio::log.error() { :; }
config_statusline=''
bashio::config() {
    case "$1" in
        statusline) printf '%s\n' "$config_statusline" ;;
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

# No settings yet: ours is added, with the default layout
setup_statusline
[ -x "$HA_STATUSLINE_BIN" ] || fail "script not installed"
[ "$(jq -r '.statusLine.command' "$settings")" = "$HA_STATUSLINE_BIN" ] || fail "status line not added"
[ "$(jq -r '.statusLine.refreshInterval' "$settings")" = 30 ] || fail "refreshInterval not set"
[ "$(jq -c '.layout' "$HA_STATUSLINE_CONFIG")" = null ] || fail "empty option should mean the default layout"

# A missing option (bashio prints "null") is the default too
config_statusline=null
setup_statusline
[ "$(jq -c '.layout' "$HA_STATUSLINE_CONFIG")" = null ] || fail "null option should mean the default layout"

# Other settings survive
jq '.theme = "dark"' "$settings" > "$settings.new" && mv "$settings.new" "$settings"
setup_statusline
[ "$(jq -r '.theme' "$settings")" = dark ] || fail "other settings were lost"

# The user's pieces, in order: names, line breaks, entities with and without
# labels. Anything else is skipped with a warning.
: > "$tmp_dir/warnings"
config_statusline='["model", " context ", "---", "CO₂=sensor.air_co2", "sensor.temp", "people", "$(reboot)", "Bad=../../etc", "nonsense"]'
setup_statusline
[ "$(jq -c '.layout' "$HA_STATUSLINE_CONFIG")" = \
  '[{"s":"model"},{"s":"context"},{"s":"---"},{"s":"entity","id":"sensor.air_co2","label":"CO₂"},{"s":"entity","id":"sensor.temp","label":""},{"s":"people"}]' ] || \
    fail "layout parsed wrong: $(jq -c '.layout' "$HA_STATUSLINE_CONFIG")"
[ "$(grep -c skipping "$tmp_dir/warnings")" -eq 3 ] || fail "invalid items should be warned about"

# off removes ours only, and keeps other settings
config_statusline='["off"]'
setup_statusline
[ "$(jq -r 'has("statusLine")' "$settings")" = false ] || fail "off should remove our status line"
[ "$(jq -r '.theme' "$settings")" = dark ] || fail "off lost other settings"

# A status line the user made (e.g. with /statusline) is never touched
user_cmd="$HOME/.claude/statusline.sh"
jq --arg c "$user_cmd" '.statusLine = {type: "command", command: $c}' "$settings" > "$settings.new" \
    && mv "$settings.new" "$settings"
config_statusline=''
setup_statusline
[ "$(jq -r '.statusLine.command' "$settings")" = "$user_cmd" ] || fail "user status line replaced"
config_statusline='["off"]'
setup_statusline
[ "$(jq -r '.statusLine.command' "$settings")" = "$user_cmd" ] || fail "off removed the user's status line"

# Invalid JSON is left as it is
printf '{ broken' > "$settings"
config_statusline=''
setup_statusline
[ "$(cat "$settings")" = '{ broken' ] || fail "invalid settings.json was rewritten"

# off with no settings file creates nothing
rm -f "$settings"
config_statusline='["off"]'
setup_statusline
[ ! -e "$settings" ] || fail "off should not create settings.json"

echo "Status line tests passed"
