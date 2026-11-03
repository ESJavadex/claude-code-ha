#!/usr/bin/env bash
# relink_stale_native_claude: a ~/.local/bin/claude left by an old
# `claude update` must not shadow a newer Claude Code from the image.
set -euo pipefail

repo_root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT

fail() {
    echo "FAIL (native claude): $*" >&2
    exit 1
}

bashio::log.info() { printf '%s\n' "$*" >> "$tmp_dir/log"; }
bashio::log.warning() { :; }
bashio::log.error() { :; }
bashio::config() { printf '%s\n' "${2:-}"; }
export CLAUDE_RUN_SH_SKIP_MAIN=true
# shellcheck source=/dev/null
source "$repo_root/claude-terminal/run.sh"

fake() {  # fake <path> <version>: a claude that prints its version
    mkdir -p "$(dirname "$1")"
    printf '#!/bin/sh\necho "%s (Claude Code)"\n' "$2" > "$1"
    chmod +x "$1"
}
image="$tmp_dir/usr/local/bin/claude"
link="$tmp_dir/home/.local/bin/claude"
versions="$tmp_dir/share/claude/versions"
fake "$image" 2.1.316
mkdir -p "$(dirname "$link")"

# An old `claude update` (2.1.38 < 2.1.316): back to the image's
fake "$versions/2.1.38" 2.1.38
ln -sf "$versions/2.1.38" "$link"
relink_stale_native_claude "$link" "$image"
[ "$(readlink "$link")" = "$image" ] || fail "an older native install should be replaced"
grep -q "2.1.316 instead of 2.1.38" "$tmp_dir/log" || fail "the switch should be logged"
[ ! -e "$versions/2.1.38" ] || fail "the old binary should be removed from versions/"
fake "$versions/2.1.38" 2.1.38

# A `claude update` newer than the image is kept (2.1.400 > 2.1.316)
fake "$versions/2.1.400" 2.1.400
ln -sf "$versions/2.1.400" "$link"
relink_stale_native_claude "$link" "$image"
[ "$(readlink "$link")" = "$versions/2.1.400" ] || fail "a newer native install should be kept"

# The same version is kept
fake "$versions/2.1.316" 2.1.316
ln -sf "$versions/2.1.316" "$link"
relink_stale_native_claude "$link" "$image"
[ "$(readlink "$link")" = "$versions/2.1.316" ] || fail "the same version should be kept"

# One that no longer runs (wrong architecture, half-written) is replaced
printf 'garbage' > "$versions/broken"
chmod +x "$versions/broken"
ln -sf "$versions/broken" "$link"
relink_stale_native_claude "$link" "$image"
[ "$(readlink "$link")" = "$image" ] || fail "a broken native install should be replaced"

# A plain file (not a link) and a link to the image are left alone
rm -f "$link"; fake "$link" 2.0.1
relink_stale_native_claude "$link" "$image"
[ ! -L "$link" ] || fail "a plain file must not be replaced"

# An image whose version can't be read changes nothing
ln -sf "$versions/2.1.38" "$link.2"
printf '#!/bin/sh\nexit 1\n' > "$tmp_dir/badimage"; chmod +x "$tmp_dir/badimage"
relink_stale_native_claude "$link.2" "$tmp_dir/badimage"
[ "$(readlink "$link.2")" = "$versions/2.1.38" ] || fail "an unreadable image version must change nothing"

echo "native claude: all checks passed"
