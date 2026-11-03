#!/usr/bin/env bash
# shellcheck shell=bash
#
# ha-statusline: a Claude Code status line for Home Assistant.
#
# Default layout (each piece hides itself when there's nothing to say):
#   Opus 5.5 │ ✍️ 63% │ config (main*) │ 1h12m │ +120/-30
#   5h ●●●○○ 62% ⟳ 14:00 │ 7d ●●●●○ 81% ⟳ Fri 09:00 │ in 45.2k · out 3.1k
#   🏠 🚨 Kitchen smoke │ 💾 9d │ ⚠ 3 unavailable          (or just 🏠 ✓)
#
# Pieces, in the order you list them in the add-on's statusline option
# (--- starts a new line, Label=sensor.x or sensor.x adds an entity):
#   Claude: model context folder duration lines usage tokens
#   Home:   alerts repairs automations backup disk core updates
#           unavailable battery people weather
#
# Claude Code runs this on every update with the session JSON on stdin
# (https://code.claude.com/docs/en/statusline). It never waits for Home
# Assistant: a background refresh summarises /api/states (every 30 s) and the
# Supervisor's backups, disk and repairs (every 5 min) into a small cache,
# and drawing the line only reads that cache.
#
# Usage:
#   ha-statusline              the status line (reads Claude's JSON on stdin)
#   ha-statusline --home       only the home pieces, for your own status line
#   ha-statusline --preview    the status line with sample Claude data
#   ha-statusline --refresh    refresh the cache now and print any error
#   ha-statusline --segments   the piece names
#
# Style based on susomejias/claude-statusline (MIT).
# Text from Home Assistant has control characters removed, so an entity name
# can't send escape sequences to the terminal.

set -uo pipefail

HA_API="${HA_STATUSLINE_API:-http://supervisor/core/api}"
SUPERVISOR_API="${HA_STATUSLINE_SUPERVISOR_API:-http://supervisor}"
CACHE_DIR="${HA_STATUSLINE_CACHE_DIR:-/tmp/ha-statusline}"
CONFIG_FILE="${HA_STATUSLINE_CONFIG:-/data/.config/ha-statusline.json}"
TTL="${HA_STATUSLINE_TTL:-30}"
SUPERVISOR_TTL="${HA_STATUSLINE_SUPERVISOR_TTL:-300}"
STATES="$CACHE_DIR/states.json"
SYSTEM="$CACHE_DIR/system.json"
LOCK="$CACHE_DIR/refresh.lock"

CLAUDE_SEGMENTS="model context folder duration lines usage tokens"
HOME_SEGMENTS="alerts repairs automations backup disk core updates unavailable battery people weather"
DEFAULT_LAYOUT='model context folder duration lines --- usage tokens --- alerts repairs automations backup disk core updates unavailable battery'

# The layout as [{"s": name}, {"s": "---"}, {"s": "entity", "id": ..., "label": ...}].
# run.sh validates the add-on option and writes it; null means the default.
layout() {
    local saved=""
    [ -r "$CONFIG_FILE" ] && saved=$(jq -c '.layout // empty | arrays' "$CONFIG_FILE" 2>/dev/null)
    if [ -n "$saved" ]; then
        printf '%s' "$saved"
    else
        jq -nc --arg l "$DEFAULT_LAYOUT" '$l | split(" ") | map({s: .})'
    fi
}

supervisor_token() {
    if [ -n "${SUPERVISOR_TOKEN:-}" ]; then
        printf '%s' "$SUPERVISOR_TOKEN"
    elif [ -r /run/s6/container_environment/SUPERVISOR_TOKEN ]; then
        cat /run/s6/container_environment/SUPERVISOR_TOKEN
    fi
}

# GET a Supervisor or HA API path into a file. The Supervisor token is only
# ever sent to the Supervisor itself (http(s)://supervisor/...), so pointing
# HA_STATUSLINE_API or HA_STATUSLINE_SUPERVISOR_API elsewhere can't leak it.
# file:// (the test fixtures) is read without it; anything else is refused.
# The token goes to curl on stdin, so it never shows in ps.
api_get() {
    local token="$1" url="$2" out="$3"
    if [[ "$url" =~ ^https?://supervisor(/[A-Za-z0-9/_.-]*)?$ ]]; then
        printf 'header = "Authorization: Bearer %s"\n' "$token" \
            | curl -fsS --max-time 8 --proto '=http,https' -K - -o "$out" "$url"
    elif [[ "$url" == file://* ]]; then
        curl -fsS --proto '=file' -o "$out" "$url"
    else
        echo "ha-statusline: refusing to send the Supervisor token to $url" >&2
        return 1
    fi
}

file_age() {
    local mtime
    mtime=$(stat -c %Y "$1" 2>/dev/null) || { echo 999999; return; }
    echo $(( $(date +%s) - mtime ))
}

write_error() {
    jq -nc --arg e "$1" '{ts: (now | floor), error: $e}' > "$STATES.tmp" && mv -f "$STATES.tmp" "$STATES"
}

refresh_states() {
    local token="$1" raw="$CACHE_DIR/states.raw" entities
    if ! api_get "$token" "$HA_API/states" "$raw" 2>"$CACHE_DIR/err"; then
        write_error "Home Assistant unreachable"
        cat "$CACHE_DIR/err" >&2
        rm -f "$raw"
        return 1
    fi
    entities=$(layout | jq -c '[.[] | select(.s == "entity")]')
    if ! jq -c --argjson wanted "$entities" '
        def clean: tostring | gsub("[\u0000-\u001f\u007f-\u009f]"; "") | .[0:32];
        def name: (.attributes.friendly_name // .entity_id) | clean;
        def domain: .entity_id | split(".")[0];
        . as $all
        | (map({key: .entity_id, value: .}) | from_entries) as $by_id
        | {
            ts: (now | floor),
            alerts: [ $all[] | select(domain == "binary_sensor" and .state == "on")
                | select(.attributes.device_class as $c
                    | ["smoke", "gas", "carbon_monoxide", "moisture", "safety"] | index($c))
                | name ],
            people_home: [ $all[] | select(domain == "person" and .state == "home") ] | length,
            people: [ $all[] | select(domain == "person") ] | length,
            unavailable: [ $all[] | select(.state == "unavailable") ] | length,
            broken_automations: [ $all[] | select(domain == "automation" and .state == "unavailable") ] | length,
            low_battery: [ $all[] | select(domain == "sensor" and .attributes.device_class == "battery")
                | select((.state | tonumber? // 101) < 20) | name ],
            updates: [ $all[] | select(domain == "update" and .state == "on") ] | length,
            weather: ([ $all[] | select(domain == "weather") ][0]
                | if . then {state: (.state | clean),
                             temp: ((.attributes.temperature // "") | clean),
                             unit: ((.attributes.temperature_unit // "") | clean)}
                  else null end),
            entities: [ $wanted[] | . as $w | $by_id[$w.id] as $s
                | { id: $w.id,
                    label: (($w.label // "") | clean),
                    name: (if $s then ($s | name) else $w.id end),
                    state: (if $s then ($s.state | clean) else "missing" end),
                    unit: (if $s then (($s.attributes.unit_of_measurement // "") | clean) else "" end) } ]
          }' "$raw" > "$STATES.tmp" 2>/dev/null; then
        rm -f "$raw" "$STATES.tmp"
        write_error "could not read the states"
        return 1
    fi
    rm -f "$raw"
    mv -f "$STATES.tmp" "$STATES"
}

# Backups, disk, core version and repairs: only from the Supervisor, which
# every install that can run this add-on has. Each part may fail on its own.
refresh_system() {
    local token="$1" part
    for part in core/info host/info backups resolution/info; do
        api_get "$token" "$SUPERVISOR_API/$part" "$CACHE_DIR/${part%%/*}.raw" 2>/dev/null \
            || printf '{}' > "$CACHE_DIR/${part%%/*}.raw"
    done
    jq -nc \
        --slurpfile core "$CACHE_DIR/core.raw" \
        --slurpfile host "$CACHE_DIR/host.raw" \
        --slurpfile backups "$CACHE_DIR/backups.raw" \
        --slurpfile res "$CACHE_DIR/resolution.raw" '
        def clean: tostring | gsub("[\u0000-\u001f\u007f-\u009f]"; "") | .[0:24];
        def epoch: try (sub("\\.[0-9]+"; "") | sub("\\+00:00$"; "Z") | fromdateiso8601) catch null;
        ($core[0].data // null) as $c
        | ($host[0].data // null) as $h
        | ($backups[0].data // null) as $b
        | ($res[0].data // null) as $r
        | {
            ts: (now | floor),
            core: (if $c then {update: ($c.update_available == true),
                               latest: (($c.version_latest // "") | clean)} else null end),
            disk_pct: (if $h and ($h.disk_total // 0) > 0
                       then ($h.disk_used / $h.disk_total * 100 | floor) else null end),
            last_backup: (if $b then ([$b.backups[]?.date | epoch] | map(select(. != null)) | max // 0)
                          else null end),
            unhealthy: (if $r then ($r.unhealthy | length) else null end),
            repairs: (if $r then ($r.issues | length) else null end)
          }' > "$SYSTEM.tmp" 2>/dev/null && mv -f "$SYSTEM.tmp" "$SYSTEM"
    rm -f "$CACHE_DIR"/*.raw "$SYSTEM.tmp"
}

refresh() {
    local token status=0
    mkdir -p "$CACHE_DIR" && chmod 700 "$CACHE_DIR" 2>/dev/null || return 1

    # One refresh at a time; a lock left by a killed refresh expires
    if ! mkdir "$LOCK" 2>/dev/null; then
        [ "$(file_age "$LOCK")" -gt 60 ] || return 0
        rmdir "$LOCK" 2>/dev/null
        mkdir "$LOCK" 2>/dev/null || return 0
    fi
    # shellcheck disable=SC2064
    trap "rmdir '$LOCK' 2>/dev/null" EXIT

    token=$(supervisor_token)
    if [ -z "$token" ]; then
        write_error "no Supervisor token"
        echo "ha-statusline: no SUPERVISOR_TOKEN in the environment" >&2
        return 1
    fi
    refresh_states "$token" || status=1
    if [ "$(file_age "$SYSTEM")" -ge "$SUPERVISOR_TTL" ]; then
        refresh_system "$token"
    fi
    return "$status"
}

# Claude Code cancels a status line run when the next update comes, so a
# refresh runs in its own session and outlives it.
refresh_if_stale() {
    [ "$(file_age "$STATES")" -ge "$TTL" ] || return 0
    if command -v setsid >/dev/null 2>&1; then
        setsid "$0" --refresh </dev/null >/dev/null 2>&1 &
    else
        nohup "$0" --refresh </dev/null >/dev/null 2>&1 &
    fi
}

render() {
    local input="$1" layout_json="$2" dir branch="" dirty=""
    local states='null' system='null'

    if jq -e 'any(.[]; .s as $s | ($s == "entity") or ($home | split(" ") | index($s)))' \
        --arg home "$HOME_SEGMENTS" <<< "$layout_json" >/dev/null 2>&1; then
        refresh_if_stale
        [ -s "$STATES" ] && states=$(cat "$STATES")
        [ -s "$SYSTEM" ] && system=$(cat "$SYSTEM")
    fi

    dir=$(jq -r '.workspace.current_dir // .cwd // empty' <<< "$input" 2>/dev/null)
    if [ -n "$dir" ] && [ -d "$dir" ] && jq -e 'any(.[]; .s == "folder")' <<< "$layout_json" >/dev/null 2>&1; then
        branch=$(GIT_OPTIONAL_LOCKS=0 git -C "$dir" symbolic-ref --short -q HEAD 2>/dev/null || true)
        if [ -n "$branch" ] && [ -n "$(GIT_OPTIONAL_LOCKS=0 timeout 1 git -C "$dir" status --porcelain --untracked-files=no 2>/dev/null | head -1)" ]; then
            dirty='*'
        fi
    fi

    jq -r -n \
        --argjson c "$input" \
        --argjson layout "$layout_json" \
        --argjson st "$states" \
        --argjson sys "$system" \
        --arg branch "$branch" --arg dirty "$dirty" \
        --arg home "$HOME_SEGMENTS" \
        --argjson now "$(date +%s)" '
        def esc($rgb): "\u001b[38;2;" + $rgb + "m";
        def reset: "\u001b[0m";
        def dim: "\u001b[2m" + . + reset;
        def green: esc("0;175;80") + . + reset;
        def orange: esc("255;176;85") + . + reset;
        def yellow: esc("230;200;0") + . + reset;
        def red: esc("255;85;85") + . + reset;
        def cyan: esc("86;182;194") + . + reset;
        def blue: esc("0;153;255") + . + reset;
        def white: esc("220;220;220") + . + reset;
        def clean: tostring | gsub("[\u0000-\u001f\u007f-\u009f]"; "");
        def by_pct($p): if $p >= 90 then red elif $p >= 70 then yellow elif $p >= 50 then orange else green end;
        def k: if . >= 1000 then ((. / 100 | floor) / 10 | tostring) + "k" else (floor | tostring) end;
        def bar($used): ((100 - $used) / 20 | floor) as $f
            | ([range(0; 5)] | map(if . < $f then ("●" | by_pct($used)) else ("○" | dim) end) | join(""));
        def limit($label; $w; $fmt):
            if $w == null or $w.used_percentage == null then empty
            else ($w.used_percentage | floor) as $u
              | ($label | white) + " " + bar($u) + " " + ("\(100 - $u)%" | by_pct($u))
                + (if $w.resets_at then " " + ("⟳ " | dim) + ($w.resets_at | strflocaltime($fmt) | white) else "" end)
            end;
        def ago($t): ($now - $t) as $d
            | if $d >= 86400 then "\($d / 86400 | floor)d" elif $d >= 3600 then "\($d / 3600 | floor)h" else "\($d / 60 | floor)m" end;
        def wicon: {sunny: "☀", "clear-night": "🌙", cloudy: "☁", partlycloudy: "⛅", rainy: "🌧",
                    pouring: "🌧", snowy: "❄", "snowy-rainy": "🌨", fog: "🌫", lightning: "🌩",
                    "lightning-rainy": "⛈", windy: "💨", "windy-variant": "💨", hail: "🌨"}[.] // "🌡";

        def seg:
          if .s == "model" then ($c.model.display_name // "Claude" | clean | blue)
          elif .s == "context" then
            # Two spaces: xterm.js gives ✍️ one cell but draws it across two
            (($c.context_window.used_percentage // 0) | floor) as $u
            | "✍️  " + ("\(100 - $u)%" | by_pct($u))
          elif .s == "folder" then
            (($c.workspace.current_dir // $c.cwd // "") | clean | split("/") | last // "") as $d
            | if $d == "" then empty
              else ($d | cyan) + (if $branch != "" then " " + (("(" + ($branch | clean | .[0:25])) | green)
                   + ($dirty | red) + (")" | green) else "" end)
              end
          elif .s == "duration" then
            (($c.cost.total_duration_ms // 0) / 1000 | floor) as $t
            | if $t < 60 then empty elif $t >= 3600 then "\($t / 3600 | floor)h\(($t % 3600) / 60 | floor)m" | white
              else "\($t / 60 | floor)m" | white end
          elif .s == "lines" then
            ($c.cost.total_lines_added // 0) as $a | ($c.cost.total_lines_removed // 0) as $r
            | if $a == 0 and $r == 0 then empty else ("+\($a)" | green) + ("/" | dim) + ("-\($r)" | red) end
          elif .s == "usage" then
            if ($c.rate_limits.five_hour // $c.rate_limits.seven_day) then
              limit("5h"; $c.rate_limits.five_hour; "%H:%M"), limit("7d"; $c.rate_limits.seven_day; "%a %H:%M")
            elif ($c.cost.total_cost_usd // 0) > 0 then ("$" + ($c.cost.total_cost_usd * 100 | round / 100 | tostring)) | green
            else empty end
          elif .s == "tokens" then
            ($c.context_window.total_input_tokens // 0) as $i | ($c.context_window.total_output_tokens // 0) as $o
            | if $i == 0 and $o == 0 then empty
              else ("in " | dim) + ($i | k | white) + (" · out " | dim) + ($o | k | white) end
          elif $st == null then empty
          elif $st.error then empty
          elif .s == "alerts" then
            if ($st.alerts | length) > 0 then "🚨 " + ($st.alerts | join(", ")) | red else empty end
          elif .s == "people" then (if $st.people > 0 then "👥 \($st.people_home)/\($st.people)" else empty end)
          elif .s == "unavailable" then (if $st.unavailable > 0 then "⚠ \($st.unavailable) unavailable" | dim else empty end)
          elif .s == "automations" then
            (if $st.broken_automations > 0 then "🤖 \($st.broken_automations) broken" | yellow else empty end)
          elif .s == "battery" then
            ($st.low_battery | length) as $n
            | if $n == 0 then empty elif $n == 1 then "🔋 " + $st.low_battery[0] | yellow else "🔋 \($n) low" | yellow end
          elif .s == "updates" then (if $st.updates > 0 then "📦 \($st.updates)" | dim else empty end)
          elif .s == "weather" then
            (if $st.weather then ($st.weather.state | wicon) + " " + $st.weather.temp + $st.weather.unit else empty end)
          elif .s == "entity" then
            (.id) as $id | ($st.entities[] | select(.id == $id)
              | (if .label != "" then .label else .name end) + " " + (.state | white)
                + (if .unit != "" then " " + .unit else "" end))
          elif $sys == null then empty
          elif .s == "backup" then
            if $sys.last_backup == null then empty
            elif $sys.last_backup == 0 then "💾 no backups" | red
            elif ($now - $sys.last_backup) > 604800 then "💾 " + ago($sys.last_backup) | red
            elif ($now - $sys.last_backup) > 172800 then "💾 " + ago($sys.last_backup) | yellow
            else empty end
          elif .s == "disk" then
            if $sys.disk_pct == null or $sys.disk_pct < 80 then empty
            else "💽 \($sys.disk_pct)%" | by_pct($sys.disk_pct) end
          elif .s == "core" then (if $sys.core.update then "⬆ HA " + $sys.core.latest | orange else empty end)
          elif .s == "repairs" then
            if ($sys.unhealthy // 0) > 0 then "🩺 unhealthy" | red
            elif ($sys.repairs // 0) > 0 then "🩺 \($sys.repairs) repair" + (if $sys.repairs > 1 then "s" else "" end) | yellow
            else empty end
          else empty end;

        def is_home: .s == "entity" or (.s as $s | $home | split(" ") | index($s));
        ($layout | reduce .[] as $i ([[]]; if $i.s == "---" then . + [[]] else .[-1] += [$i] end))
        | .[]
        | . as $line
        | [ .[] | seg ] as $parts
        | ($parts | join(" " + ("│" | dim) + " ")) as $text
        | if ($line | any(is_home)) then
            if $st == null then "🏠 …" | dim
            elif $st.error then "🏠 " + ($st.error | clean) | dim
            elif $text == "" then "🏠 ✓" | dim
            else ("🏠" | dim) + " " + $text end
          elif $text == "" then empty
          else $text end' 2>/dev/null || printf 'Claude\n'
}

case "${1:-}" in
    --refresh)
        refresh
        exit $?
        ;;
    --segments)
        # shellcheck disable=SC2086
        printf '%s\n' $CLAUDE_SEGMENTS $HOME_SEGMENTS
        exit 0
        ;;
    --home)
        render '{}' "$(layout | jq -c --arg home "$HOME_SEGMENTS" \
            '[.[] | select(.s == "entity" or (.s as $s | $home | split(" ") | index($s)))]')"
        ;;
    --preview)
        render "$(jq -nc --arg d "$PWD" '{model: {display_name: "Opus 5.5"}, workspace: {current_dir: $d},
            context_window: {used_percentage: 37, total_input_tokens: 74200, total_output_tokens: 3100},
            cost: {total_duration_ms: 4320000, total_lines_added: 120, total_lines_removed: 30},
            rate_limits: {five_hour: {used_percentage: 38, resets_at: (now + 7200 | floor)},
                          seven_day: {used_percentage: 19, resets_at: (now + 300000 | floor)}}}')" "$(layout)"
        ;;
    -h|--help)
        sed -n '3,33p' "$0" | sed 's/^# \{0,1\}//'
        ;;
    *)
        input=$(cat 2>/dev/null)
        jq -e 'type == "object"' <<< "$input" >/dev/null 2>&1 || input='{}'
        render "$input" "$(layout)"
        ;;
esac
exit 0
