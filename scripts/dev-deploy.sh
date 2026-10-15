#!/bin/bash
# Install the working tree on a Home Assistant box as a separate *local*
# add-on, "Claude Terminal (dev)", to test changes on real HA (ingress,
# notifications, Remote Control, backups) without a version bump, a push or
# a release. Adapted from heytcass/home-assistant-addons (#139).
#
#   scripts/dev-deploy.sh root@homeassistant.local   # copy, then build/install
#   scripts/dev-deploy.sh --copy-only root@homeassistant.local
#   scripts/dev-deploy.sh                            # only build dist/claude-terminal-dev/
#
# The target is an SSH login to a Home Assistant SSH add-on (Advanced SSH &
# Web Terminal, or the official Terminal & SSH); both mount /addons and have
# the `ha` CLI. For a port other than 22 use the URI form, e.g.
# ssh://root@homeassistant.local:2222, or a Host entry in ~/.ssh/config.
# DEV_DEPLOY_TARGET can be set instead of passing it.
#
# The copy is changed so it can't be mistaken for, or collide with, the real
# add-on:
#   - slug claude_terminal_dev, name/panel "Claude Terminal (dev)": its own
#     /data (log in to Claude once in it) and its own sidebar entry
#   - boot: manual, so it doesn't start with Home Assistant
#   - backup_exclude patterns name the dev slug, so its backups match the
#     real add-on's
#   - version <version>-dev.<commit>.<timestamp>: every deploy, committed or
#     not, is a new version, so the Supervisor offers it as an update and
#     rebuilds the image instead of reusing the last one
#
# Unless --copy-only is given, it then reloads the store and installs or
# updates the add-on with `ha` over the same SSH login (the build takes a few
# minutes). It is not started automatically the first time: open it in
# Settings → Add-ons to set options and start it.
#
# Remove it when done: uninstall it in HA, then
#   ssh <target> rm -rf /addons/claude-terminal-dev
set -euo pipefail

copy_only=false
if [ "${1:-}" = "--copy-only" ]; then
    copy_only=true
    shift
fi
target="${1:-${DEV_DEPLOY_TARGET:-}}"

repo_root=$(cd "$(dirname "$0")/.." && pwd)
src="$repo_root/claude-terminal"
dist="$repo_root/dist/claude-terminal-dev"
remote_dir="/addons/claude-terminal-dev"
# Local add-ons get the "local_" prefix in the Supervisor
addon_slug="local_claude_terminal_dev"

commit=$(git -C "$repo_root" rev-parse --short HEAD 2>/dev/null || echo nogit)
if [ -n "$(git -C "$repo_root" status --porcelain -- claude-terminal 2>/dev/null)" ]; then
    commit="${commit}.dirty"
fi
stamp=$(date +%Y%m%d%H%M%S)
# Keep macOS tar from adding ._ metadata files to the copy
export COPYFILE_DISABLE=1

rm -rf "$dist"
mkdir -p "$dist"
# node_modules is installed by the Dockerfile; a local copy would only bloat
# the transfer
tar -C "$src" --exclude node_modules -cf - . | tar -C "$dist" -xf -

config="$dist/config.yaml"
version=$(sed -n 's/^version: *"\{0,1\}\([^"]*\)"\{0,1\}.*/\1/p' "$config" | head -1)
[ -n "$version" ] || { echo "Could not read version from $config" >&2; exit 1; }
dev_version="${version}-dev.${commit}.${stamp}"

# GNU and BSD sed disagree on -i; write to a temp file instead
sed \
    -e 's/^name: .*/name: "Claude Terminal (dev)"/' \
    -e 's/^slug: .*/slug: "claude_terminal_dev"/' \
    -e 's/^panel_title: .*/panel_title: "Claude Terminal (dev)"/' \
    -e "s/^version: .*/version: \"${dev_version}\"/" \
    -e '/^image: /d' \
    -e '/^boot: /d' \
    -e 's|^\(  - "\*_\)claude_terminal_pro/|\1claude_terminal_dev/|' \
    "$config" > "$config.tmp" && mv "$config.tmp" "$config"

# A test copy shouldn't start with Home Assistant (the default is auto)
printf '\n# dev-deploy: start only when asked\nboot: manual\n' >> "$config"

grep -q '^slug: "claude_terminal_dev"' "$config" || {
    echo "Failed to rewrite the slug in $config" >&2; exit 1; }

echo "Built local add-on: $dist"
echo "  slug    claude_terminal_dev"
echo "  version $dev_version"

if [ -z "$target" ]; then
    echo
    echo "No SSH target given. Copy $dist to $remote_dir on your"
    echo "Home Assistant box (e.g. through the Samba 'addons' share), then"
    echo "Add-on Store → ⋮ → Check for updates."
    exit 0
fi

echo "Copying to ${target}:${remote_dir} ..."
# tar over ssh works on every SSH add-on, unlike rsync. remote_dir is meant
# to expand client-side.
# shellcheck disable=SC2029
ssh "$target" "rm -rf '$remote_dir' && mkdir -p '$remote_dir'"
# shellcheck disable=SC2029
tar -C "$dist" -cf - . | ssh "$target" "tar -xf - -C '$remote_dir'"

if [ "$copy_only" = "true" ]; then
    echo "Copied. In HA: Add-on Store → ⋮ → Check for updates → Claude Terminal (dev)."
    exit 0
fi

echo "Reloading the add-on store and building (this takes a few minutes) ..."
# shellcheck disable=SC2029
# Update fails when it isn't installed yet (first deploy), so fall back to
# install. The Supervisor restarts a running add-on after an update itself.
# Newer CLIs call add-ons "apps" and warn on "addons"; older ones only know
# "addons".
if ssh "$target" "if ha apps --help >/dev/null 2>&1; then cmd=apps; else cmd=addons; fi; \
    ha store reload >/dev/null && \
    { ha \$cmd update '$addon_slug' || \
      { echo 'Update failed; installing (expected on the first deploy) ...'; \
        ha \$cmd install '$addon_slug'; }; }"; then
    echo "Done: Claude Terminal (dev) $dev_version"
else
    echo "The copy worked but the build/install step failed. Check the add-on's" >&2
    echo "page in HA (Settings → Add-ons → Claude Terminal (dev)) for the build log." >&2
    exit 1
fi
