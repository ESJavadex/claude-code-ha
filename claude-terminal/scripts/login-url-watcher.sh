#!/bin/bash
# login-url-watcher - background loop that spots Claude Code's OAuth login URL
# in the 'claude' tmux session and posts it as a clickable Home Assistant
# persistent notification, then dismisses it once login succeeds.
#
# Why: the login URL is long and wraps across lines, so clicking it in the
# terminal opens a truncated link, and selecting it on a phone is awkward. A
# notification also reaches the Companion app. The authorization code the
# browser shows afterwards still has to be pasted into the terminal: the
# container's localhost callback can't be reached from the browser.
#
# Adapted from heytcass/home-assistant-addons (2.5.2/2.5.3, contributed by
# @heman22union). Started once from run.sh; cheap when idle, since it only
# polls a local tmux pane.

NOTIFICATION_ID="claude_login_url"
POLL_INTERVAL="${LOGIN_WATCHER_POLL_INTERVAL:-3}"
SUPERVISOR_URL="${LOGIN_WATCHER_SUPERVISOR_URL:-http://supervisor}"

# Rebuild the URL from the pane. Claude hard-wraps it with real line breaks
# (which capture-pane -J does not rejoin) and may indent it or draw a border
# round it, so take the URL characters from the first line and from each
# following line until a blank one.
extract_url() {
    tmux capture-pane -p -J -t claude -S -500 2>/dev/null | awk '
        $0 ~ /https:\/\/(claude\.(com|ai)|console\.anthropic\.com|platform\.claude\.com)/ {
            match($0, /https:\/\/[A-Za-z0-9._~:\/?#@!$&()*+,;=%-]*/)
            url = substr($0, RSTART, RLENGTH)
            collecting = 1
            next
        }
        collecting {
            if (NF == 0) { collecting = 0 }
            else if (match($0, /[A-Za-z0-9._~:\/?#@!$&()*+,;=%-]+/)) {
                url = url substr($0, RSTART, RLENGTH)
            }
        }
        END { print url }
    '
}

is_logged_in() {
    local cred="$HOME/.claude/.credentials.json"
    [ -f "$cred" ] || return 1
    local expires_at
    expires_at=$(jq -r '.claudeAiOauth.expiresAt // empty' "$cred" 2>/dev/null)
    [ -n "$expires_at" ] && [ "$expires_at" -gt "$(($(date +%s) * 1000))" ] 2>/dev/null
}

call_service() {
    local service="$1" body="$2"
    curl -s -m 10 -X POST \
        -H "Authorization: Bearer ${SUPERVISOR_TOKEN:-}" \
        -H "Content-Type: application/json" \
        -d "$body" \
        "${SUPERVISOR_URL}/core/api/services/persistent_notification/${service}" >/dev/null 2>&1
}

notify() {
    local url="$1"
    call_service create "$(jq -n --arg url "$url" --arg id "$NOTIFICATION_ID" '{
        title: "Claude Code login",
        message: ("[Click here to authorize Claude Code](" + $url + ")\n\nThen paste the code it shows into the Claude Terminal Pro terminal.\n\nIf the link does not open, copy it instead:\n" + $url),
        notification_id: $id
    }')"
}

dismiss() {
    call_service dismiss "$(jq -n --arg id "$NOTIFICATION_ID" '{notification_id: $id}')"
}

main() {
    # A login URL's state/PKCE challenge belongs to the claude process that
    # printed it, and HA notifications outlive the add-on, so one left over
    # from a previous container would point at a process that no longer
    # exists. Clear it before publishing current ones.
    dismiss

    # Every URL already posted. Not cleared on login: the used URL stays in
    # scrollback, and when the access token later expires is_logged_in turns
    # false again, which must not re-post a dead link. A new login always
    # prints a new URL (fresh state), so it is still posted.
    local posted=" " notified=0 url
    while true; do
        if tmux has-session -t claude 2>/dev/null; then
            if is_logged_in; then
                if [ "$notified" = "1" ]; then
                    dismiss
                    notified=0
                    echo "Login complete; notification dismissed"
                fi
            else
                url=$(extract_url)
                if [ -n "$url" ] && [[ "$posted" != *" $url "* ]]; then
                    notify "$url"
                    posted="$posted$url "
                    notified=1
                    echo "Login link posted as a Home Assistant notification"
                fi
            fi
        fi
        sleep "$POLL_INTERVAL"
    done
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    main "$@"
fi
