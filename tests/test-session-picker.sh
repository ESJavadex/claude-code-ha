#!/usr/bin/env bash
# Session picker layout: the box banner and full labels on a wide terminal,
# a short form that fits a phone (about 45 columns) on a narrow one.
set -euo pipefail

repo_root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT

fail() {
    echo "FAIL (session picker): $*" >&2
    exit 1
}

# shellcheck source=/dev/null
source "$repo_root/claude-terminal/scripts/claude-session-picker.sh"

# No terminal to reset or clear, and no network for the update label
reset_terminal() { :; }
clear() { :; }
get_installed_version() { echo 2.1.319; }
get_latest_version() { echo 2.1.319; }

# Display width: emoji count two cells, the emoji selector none
width() {
    python3 -c '
import sys
for line in sys.stdin.read().splitlines():
    w = 0
    for ch in line:
        o = ord(ch)
        if o == 0xFE0F: continue
        w += 2 if (o >= 0x1F000 or o in (0x23E9, 0x274C)) else 1
    print(w)'
}

render() {  # render <cols>
    COLS="$1"
    stty() { [ "$1" = size ] && echo "24 $COLS"; }
    compute_menu_numbers
    { show_banner; show_menu; } 2>/dev/null
}

for persistent in false true; do
    export USE_PERSISTENT_CLAUDE=$persistent
    compute_menu_numbers

    narrow=$(render 45)
    max=$(printf '%s\n' "$narrow" | width | sort -n | tail -1)
    [ "$max" -le 45 ] || fail "a line is $max cells wide at 45 columns (persistent=$persistent)"
    ! grep -q '╔' <<<"$narrow" || fail "no box banner on a narrow terminal"
    grep -q 'Session Picker' <<<"$narrow" || fail "narrow header missing"
    grep -q '^  1) .*New session' <<<"$narrow" || fail "narrow menu missing option 1"
    grep -q "^  ${NUM_EXIT}) .*Exit" <<<"$narrow" || fail "narrow menu missing Exit"
    if [ "$persistent" = true ]; then
        grep -q '^  7) .*Update Claude Code$' <<<"$narrow" || fail "narrow update option"
        grep -q '^        2.1.319, up to date$' <<<"$narrow" || fail "narrow update detail line"
    fi

    wide=$(render 80)
    grep -q '╔' <<<"$wide" || fail "box banner on a wide terminal"
    grep -q 'Continue most recent conversation (-c)' <<<"$wide" || fail "full labels on a wide terminal"
    max=$(printf '%s\n' "$wide" | width | sort -n | tail -1)
    [ "$max" -le 64 ] || fail "wide layout is $max cells, more than 64"
done

# Option 4 uses 🔧: ⚙️ is one cell in some terminals and two in others
! grep -v '^ *#' "$repo_root/claude-terminal/scripts/claude-session-picker.sh" | grep -q '⚙' || \
    fail "the menu should not use ⚙️, whose width varies between terminals"
grep -c '4) 🔧 ' "$repo_root/claude-terminal/scripts/claude-session-picker.sh" | grep -qx 2 || \
    fail "option 4 should show 🔧 and one space in both menus"

echo "Session picker layout tests passed"
