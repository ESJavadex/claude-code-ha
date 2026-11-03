#!/usr/bin/env bash
# shellcheck shell=bash
#
# ha-statusline: a Claude Code status line that shows the state of the home.
#
#   line 1  model · context bar · folder · git branch       (from Claude Code)
#   line 2  alerts · people home · unavailable · batteries · updates · your entities
#
# Claude Code runs this on every update with the session JSON on stdin
# (https://code.claude.com/docs/en/statusline). It must answer fast and never
# block, so Home Assistant is never queried here: the states are summarised
# by a background refresh into a small cache file, and each run only reads it.
# A Raspberry Pi with thousands of entities pays for one /api/states call per
# HA_STATUSLINE_TTL seconds, not one per keystroke.
#
# Usage:
#   ha-statusline            the status line (reads Claude's JSON on stdin)
#   ha-statusline --home     only the home line, for your own status line script
#   ha-statusline --refresh  refresh the cache now and print any error
#   ha-statusline --help
#
# Everything shown from Home Assistant (names, states, units) has control
# characters removed, so an entity name can't send escape sequences to the
# terminal.

set -uo pipefail

HA_API="${HA_STATUSLINE_API:-http://supervisor/core/api}"
CACHE_DIR="${HA_STATUSLINE_CACHE_DIR:-/tmp/ha-statusline}"
CONFIG_FILE="${HA_STATUSLINE_CONFIG:-/data/.config/ha-statusline.json}"
TTL="${HA_STATUSLINE_TTL:-30}"
SUMMARY="$CACHE_DIR/summary.json"
LOCK="$CACHE_DIR/refresh.lock"

supervisor_token() {
    if [ -n "${SUPERVISOR_TOKEN:-}" ]; then
        printf '%s' "$SUPERVISOR_TOKEN"
    elif [ -r /run/s6/container_environment/SUPERVISOR_TOKEN ]; then
        cat /run/s6/container_environment/SUPERVISOR_TOKEN
    fi
}

# The entities the user listed in the add-on options, as
# [{"entity_id": ..., "label": ...}]. run.sh writes and validates this file.
configured_entities() {
    if [ -r "$CONFIG_FILE" ]; then
        jq -c '.entities // [] | map(select(type == "object" and (.entity_id | type) == "string"))' \
            "$CONFIG_FILE" 2>/dev/null || printf '[]'
    else
        printf '[]'
    fi
}

# Fetch /api/states and reduce it to the few numbers the status line shows.
refresh() {
    local token states_file tmp entities
    mkdir -p "$CACHE_DIR" || return 1
    chmod 700 "$CACHE_DIR" 2>/dev/null || true

    # One refresh at a time; a lock left by a killed refresh expires
    if ! mkdir "$LOCK" 2>/dev/null; then
        if [ -n "$(find "$LOCK" -maxdepth 0 -mmin +1 2>/dev/null)" ]; then
            rmdir "$LOCK" 2>/dev/null
            mkdir "$LOCK" 2>/dev/null || return 0
        else
            return 0
        fi
    fi
    # shellcheck disable=SC2064
    trap "rmdir '$LOCK' 2>/dev/null" EXIT

    token=$(supervisor_token)
    tmp=$(mktemp "$CACHE_DIR/summary.XXXXXX") || return 1
    states_file="$tmp.states"

    if [ -z "$token" ]; then
        printf '{"ts":%s,"error":"no Supervisor token"}\n' "$(date +%s)" > "$tmp"
        mv -f "$tmp" "$SUMMARY"
        echo "ha-statusline: no SUPERVISOR_TOKEN in the environment" >&2
        return 1
    fi

    # The token goes in a header read from stdin, so it never appears in ps
    if ! printf 'header = "Authorization: Bearer %s"\n' "$token" \
        | curl -fsS --max-time 8 -K - -o "$states_file" "$HA_API/states" 2>"$tmp.err"; then
        jq -nc --arg e "$(head -c 200 "$tmp.err" 2>/dev/null)" \
            '{ts: (now | floor), error: ("Home Assistant unreachable: " + $e)}' > "$tmp"
        mv -f "$tmp" "$SUMMARY"
        cat "$tmp.err" >&2
        rm -f "$tmp.err" "$states_file"
        return 1
    fi
    rm -f "$tmp.err"

    entities=$(configured_entities)
    if ! jq -c --argjson wanted "$entities" '
        def clean: tostring | gsub("[\u0000-\u001f\u007f-\u009f]"; "") | .[0:32];
        def name: (.attributes.friendly_name // .entity_id) | clean;
        def domain: .entity_id | split(".")[0];
        . as $all
        | (map({key: .entity_id, value: .}) | from_entries) as $by_id
        | {
            ts: (now | floor),
            alerts: [ $all[]
                | select(domain == "binary_sensor" and .state == "on")
                | select(.attributes.device_class as $c
                    | ["smoke", "gas", "carbon_monoxide", "moisture", "safety"] | index($c))
                | name ],
            people_home: [ $all[] | select(domain == "person" and .state == "home") ] | length,
            people: [ $all[] | select(domain == "person") ] | length,
            unavailable: [ $all[] | select(.state == "unavailable") ] | length,
            low_battery: [ $all[]
                | select(domain == "sensor" and .attributes.device_class == "battery")
                | select((.state | tonumber? // 101) < 20)
                | name ],
            updates: [ $all[] | select(domain == "update" and .state == "on") ] | length,
            entities: [ $wanted[]
                | . as $w
                | $by_id[$w.entity_id] as $s
                | { label: (($w.label // "") | clean),
                    name: (if $s then ($s | name) else $w.entity_id end),
                    state: (if $s then ($s.state | clean) else "missing" end),
                    unit: (if $s then (($s.attributes.unit_of_measurement // "") | clean) else "" end) } ]
          }' "$states_file" > "$tmp" 2>/dev/null; then
        printf '{"ts":%s,"error":"could not read the states"}\n' "$(date +%s)" > "$tmp"
    fi
    rm -f "$states_file"
    mv -f "$tmp" "$SUMMARY"
}

# Start a refresh in the background when the cache is missing or old. Claude
# Code cancels a status line run when the next update arrives, so the refresh
# runs in its own session and outlives it.
refresh_if_stale() {
    local now ts
    now=$(date +%s)
    ts=$(jq -r '.ts // 0' "$SUMMARY" 2>/dev/null || echo 0)
    [ $((now - ${ts:-0})) -ge "$TTL" ] || return 0
    if command -v setsid >/dev/null 2>&1; then
        setsid "$0" --refresh </dev/null >/dev/null 2>&1 &
    else
        nohup "$0" --refresh </dev/null >/dev/null 2>&1 &
    fi
}

home_line() {
    refresh_if_stale
    if [ ! -s "$SUMMARY" ]; then
        printf '\033[2m🏠 Home Assistant: loading…\033[0m\n'
        return 0
    fi
    jq -r --argjson now "$(date +%s)" '
        def red: "\u001b[31m" + . + "\u001b[0m";
        def yellow: "\u001b[33m" + . + "\u001b[0m";
        def green: "\u001b[32m" + . + "\u001b[0m";
        def dim: "\u001b[2m" + . + "\u001b[0m";
        . as $s
        | if .error then ("🏠 " + .error) | .[0:80] | dim
        else
          [ (if (.alerts | length) > 0 then ("🚨 " + (.alerts | join(", "))) | red else empty end),
            (if .people > 0 then "🏠 \(.people_home)/\(.people) home" else "🏠 HA" end),
            (if .unavailable > 0 then "⚠ \(.unavailable) unavailable" | yellow else "✓ all available" | green end),
            (if (.low_battery | length) > 0
               then ("🔋 " + (if (.low_battery | length) == 1 then .low_battery[0]
                              else "\(.low_battery | length) low" end)) | yellow
               else empty end),
            (if .updates > 0 then "⬆ \(.updates) update" + (if .updates > 1 then "s" else "" end) else empty end),
            (.entities[] | ((if .label != "" then .label else .name end) + " "
                + .state + (if .unit != "" then " " + .unit else "" end)))
          ]
          | join(" · ")
          + (if ($now - $s.ts) > 300 then " (stale)" | dim else "" end)
        end' "$SUMMARY" 2>/dev/null || printf '🏠 Home Assistant\n'
}

claude_line() {
    local input="$1" dir branch=""
    dir=$(printf '%s' "$input" | jq -r '.workspace.current_dir // .cwd // empty' 2>/dev/null)
    if [ -n "$dir" ] && [ -d "$dir" ]; then
        branch=$(GIT_OPTIONAL_LOCKS=0 git -C "$dir" symbolic-ref --short -q HEAD 2>/dev/null || true)
    fi
    printf '%s' "$input" | jq -r --arg branch "$branch" '
        def clean: tostring | gsub("[\u0000-\u001f\u007f-\u009f]"; "");
        def color($p): if $p >= 80 then "\u001b[31m" elif $p >= 50 then "\u001b[33m" else "\u001b[32m" end;
        ((.context_window.used_percentage // 0) | floor) as $p
        | ($p / 10 | floor | if . > 10 then 10 else . end) as $f
        | [ (.model.display_name // "Claude" | clean),
            (color($p) + ("▓" * $f) + ("░" * (10 - $f)) + " \($p)%" + "\u001b[0m"),
            ((.workspace.current_dir // .cwd // "") | clean | split("/") | last // ""
                | if . == "" then empty else "📁 " + . end),
            (if $branch != "" then "⎇ " + ($branch | clean) else empty end)
          ] | join(" · ")' 2>/dev/null || printf 'Claude\n'
}

case "${1:-}" in
    --refresh)
        refresh
        exit $?
        ;;
    --home)
        home_line
        ;;
    -h|--help)
        sed -n '3,20p' "$0" | sed 's/^# \{0,1\}//'
        ;;
    *)
        input=$(cat 2>/dev/null)
        [ -n "$input" ] || input='{}'
        claude_line "$input"
        home_line
        ;;
esac
exit 0
