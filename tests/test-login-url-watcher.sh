#!/usr/bin/env bash
set -euo pipefail

repo_root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT

fail() {
    echo "FAIL (login URL watcher): $*" >&2
    exit 1
}

# shellcheck source=../claude-terminal/scripts/login-url-watcher.sh
source "$repo_root/claude-terminal/scripts/login-url-watcher.sh"

pane="$tmp_dir/pane"
calls="$tmp_dir/calls"
: > "$calls"
tmux() {
    case "$1" in
        has-session) return 0 ;;
        capture-pane) cat "$pane" ;;
    esac
}
# Record which service was called, and the URL for a create
curl() {
    local body="" url="" arg
    while [ $# -gt 0 ]; do
        arg="$1"; shift
        case "$arg" in
            -d) body="$1"; shift ;;
            http*) url="$arg" ;;
        esac
    done
    if [[ "$url" == */create ]]; then
        printf 'create %s\n' "$(printf '%s' "$body" | jq -r '.message' | tail -1)" >> "$calls"
    else
        printf 'dismiss\n' >> "$calls"
    fi
}

link='https://claude.com/cai/oauth/authorize?code=true&client_id=abc&redirect_uri=https%3A%2F%2Fclaude.com%2Foauth%2Fcode%2Fcallback&code_challenge=challenge&state=STATE1'

# A URL hard-wrapped across lines, indented and inside a border, is rebuilt whole
cat > "$pane" << 'PANE'
 Browser didn't open? Use the url below to sign in:

 │ https://claude.com/cai/oauth/authorize?code=true&cl │
 │ ient_id=abc&redirect_uri=https%3A%2F%2Fclaude.com%2 │
 │ Foauth%2Fcode%2Fcallback&code_challenge=challenge&s │
 │ tate=STATE1                                        │
 │                                                    │

 Paste code here if prompted >
PANE
[ "$(extract_url)" = "$link" ] || fail "wrapped bordered URL rebuilt wrong: $(extract_url)"

printf 'Help: https://example.com then %s\nPaste code here if prompted >\n' "$link" > "$pane"
[ "$(extract_url)" = "$link" ] || fail "should extract the OAuth URL and stop at the prompt"

# A newer login may render only its first row. Do not fall back to an older
# URL in scrollback or post a partial one.
printf '%s\n\n%s\nPaste code here if prompted >\n' "$link" "${link%%&redirect_uri=*}" > "$pane"
[ -z "$(extract_url)" ] || fail "missing redirect_uri should suppress the notification"

for suffix in '&state=' '...' '…' '%2'; do
    printf '%s%s\n' "${link%&state=*}" "$suffix" > "$pane"
    [ -z "$(extract_url)" ] || fail "missing state should suppress the notification"
    printf '%s%s\n' "$link" "$suffix" > "$pane"
    [ -z "$(extract_url)" ] || fail "truncated URL should suppress the notification"
done

printf 'nothing to see here\n' > "$pane"
[ -z "$(extract_url)" ] || fail "no URL should give empty output"

# A login, then token expiry with the old URL still in scrollback, then a
# genuinely new login. Each sleep advances one step.
export HOME="$tmp_dir/home"
mkdir -p "$HOME/.claude"
creds="$HOME/.claude/.credentials.json"
future=$(( ($(date +%s) + 3600) * 1000 ))
past=$(( ($(date +%s) - 3600) * 1000 ))
printf ' %s\n\n' "$link" > "$pane"
step=0
sleep() {
    step=$((step + 1))
    case "$step" in
        1) printf '{"claudeAiOauth":{"expiresAt":%s}}' "$future" > "$creds" ;;
        2) printf '{"claudeAiOauth":{"expiresAt":%s}}' "$past" > "$creds" ;;
        3) ;;
        4) printf ' %s\n\n' "${link/STATE1/STATE2}" > "$pane" ;;
        5) exit 0 ;;
    esac
}
( main >/dev/null )

expected="dismiss
create $link
dismiss
create ${link/STATE1/STATE2}"
[ "$(cat "$calls")" = "$expected" ] || fail "unexpected service calls:
$(cat "$calls")
expected:
$expected"

# /login while still logged in (renewing or switching account): the link is
# posted although the old login is valid, the notification stays while the
# saved login is unchanged, and goes once the new login is saved.
: > "$calls"
printf '{"claudeAiOauth":{"expiresAt":%s,"n":1}}' "$future" > "$creds"
printf 'Claude is running\n' > "$pane"
step=0
sleep() {
    step=$((step + 1))
    case "$step" in
        1) printf ' %s\n\n' "${link/STATE1/STATE3}" > "$pane" ;;
        2) ;;
        3) printf '{"claudeAiOauth":{"expiresAt":%s,"n":2}}' "$future" > "$creds" ;;
        4) ;;
        5) exit 0 ;;
    esac
}
( main >/dev/null )

expected="dismiss
create ${link/STATE1/STATE3}
dismiss"
[ "$(cat "$calls")" = "$expected" ] || fail "re-login while logged in, unexpected service calls:
$(cat "$calls")
expected:
$expected"

echo "Login URL watcher regression suite passed"
