#!/usr/bin/env bash
set -euo pipefail

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT

fail() {
    echo "FAIL (persistent-packages helper): $*" >&2
    exit 1
}

bashio::log.info() { :; }
bashio::log.warning() { :; }
bashio::log.error() { :; }

config_apk_packages=$'tmux\nopenssh-client'
config_pip_packages=$'requests\nyaml'
bashio::config() {
    case "$1" in
        persistent_apk_packages) printf '%s\n' "$config_apk_packages" ;;
        persistent_pip_packages) printf '%s\n' "$config_pip_packages" ;;
        *) printf '%s\n' "${2:-}" ;;
    esac
}

PERSISTENT_PACKAGES_SKIP_MAIN=true
source "$repo_root/claude-terminal/scripts/persistent-packages.sh"

persist_apk_install() { printf '%s\n' "$@" > "$tmp_dir/apk.args"; }
persist_pip_install() { printf '%s\n' "$@" > "$tmp_dir/pip.args"; }
auto_install_packages
printf 'tmux\nopenssh-client\n' > "$tmp_dir/apk.expected"
printf 'requests\nyaml\n' > "$tmp_dir/pip.expected"
cmp -s "$tmp_dir/apk.expected" "$tmp_dir/apk.args" || fail "newline APK list compatibility failed"
cmp -s "$tmp_dir/pip.expected" "$tmp_dir/pip.args" || fail "newline pip list compatibility failed"

config_apk_packages='["git","nano"]'
config_pip_packages='["httpx","ruff"]'
auto_install_packages
printf 'git\nnano\n' > "$tmp_dir/apk.expected"
printf 'httpx\nruff\n' > "$tmp_dir/pip.expected"
cmp -s "$tmp_dir/apk.expected" "$tmp_dir/apk.args" || fail "JSON APK list compatibility failed"
cmp -s "$tmp_dir/pip.expected" "$tmp_dir/pip.args" || fail "JSON pip list compatibility failed"

config_apk_packages='[]'
config_pip_packages=''
rm "$tmp_dir/apk.args" "$tmp_dir/pip.args"
auto_install_packages
[ ! -e "$tmp_dir/apk.args" ] || fail "empty APK list should not install"
[ ! -e "$tmp_dir/pip.args" ] || fail "empty pip list should not install"

echo "Persistent package helper regression suite passed"
