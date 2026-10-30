# Development Guide

This guide covers local development and testing workflows for the Claude Terminal add-on.

## GitHub Actions checks

Every pull request and push to `main` runs shell lint, metadata validation,
JavaScript syntax checks, regression suites, npm audit and workflow validation
with actionlint. CI then builds all architectures listed in the add-on manifest,
amd64 and aarch64, each on a native runner. Each image must run its
packaged tools and start the image service successfully. Failed container checks
upload diagnostics for seven days. CI does not publish or deploy images.

The same workflow can be started from **Actions → CI → Run workflow** and runs
weekly to detect breakage from upstream packages and base images. Superseded runs
on the same branch/PR are cancelled. Dependabot opens weekly updates for Actions
and the image service's npm dependencies; updates still go through these checks.

To add another supported architecture, update the add-on metadata and the
platform/runner mapping in `scripts/ci-build-matrix.py`.

## Local Container Testing

### Prerequisites

- **Podman** (or Docker) installed
- **Git** repository cloned locally
- **NixOS development environment** (optional, for `nix develop`)

### Quick Start Testing

The fastest way to test changes without publishing new versions:

```bash
# 1. Build test container
podman build --build-arg BUILD_FROM=ghcr.io/home-assistant/amd64-base:3.24 \
  -t local/claude-terminal:test ./claude-terminal

# 2. Create test configuration
mkdir -p /tmp/test-config/claude-config
echo '{"auto_launch_claude": false}' > /tmp/test-config/options.json

# 3. Run test container
podman run -d --name test-claude-dev \
  -p 7681:7681 \
  -v /tmp/test-config:/config \
  local/claude-terminal:test

# 4. Check startup logs
podman logs test-claude-dev

# 5. Test in browser: http://localhost:7681

# 6. Clean up when done
podman stop test-claude-dev && podman rm test-claude-dev
```

### Development Workflow

#### 1. Iterative Development

```bash
# Make changes to code
vim claude-terminal/scripts/claude-session-picker.sh

# Rebuild image
podman build --build-arg BUILD_FROM=ghcr.io/home-assistant/amd64-base:3.24 \
  -t local/claude-terminal:test ./claude-terminal

# Stop old container
podman stop test-claude-dev && podman rm test-claude-dev

# Start new container with changes
podman run -d --name test-claude-dev -p 7681:7681 \
  -v /tmp/test-config:/config local/claude-terminal:test

# Test changes
open http://localhost:7681
```

#### 2. Hot-reload Script Testing

For script changes without full rebuilds:

```bash
# Copy updated script to running container
podman cp ./claude-terminal/scripts/claude-session-picker.sh \
  test-claude-dev:/opt/scripts/claude-session-picker.sh

# Make executable
podman exec test-claude-dev chmod +x /opt/scripts/claude-session-picker.sh

# Test directly
podman exec -it test-claude-dev /opt/scripts/claude-session-picker.sh
```

### Testing Scenarios

#### Session Picker Testing

```bash
# Test with auto-launch disabled
echo '{"auto_launch_claude": false}' > /tmp/test-config/options.json

# Test with auto-launch enabled (default)
echo '{"auto_launch_claude": true}' > /tmp/test-config/options.json
# OR
rm /tmp/test-config/options.json
```

#### Authentication Testing

```bash
# Start with clean credentials
rm -rf /tmp/test-config/claude-config/*

# Pre-populate credentials for testing
cp ~/.config/anthropic/* /tmp/test-config/claude-config/
```

#### Multi-session Testing

```bash
# Run multiple containers on different ports
podman run -d --name test-claude-dev-8681 -p 8681:7681 -v /tmp/test-config-2:/config local/claude-terminal:test
podman run -d --name test-claude-dev-9681 -p 9681:7681 -v /tmp/test-config-3:/config local/claude-terminal:test
```

### Debugging Techniques

#### Container Inspection

```bash
# Follow logs in real-time
podman logs -f test-claude-dev

# Execute shell inside container
podman exec -it test-claude-dev /bin/bash

# Check running processes
podman exec test-claude-dev ps aux

# Inspect environment variables
podman exec test-claude-dev env | grep CLAUDE
```

#### Script Debugging

```bash
# Test session picker with debug output
podman exec -it test-claude-dev bash -x /opt/scripts/claude-session-picker.sh

# Test startup script components
podman exec test-claude-dev /usr/local/bin/claude-session-picker

# Check file permissions and locations
podman exec test-claude-dev ls -la /opt/scripts/
podman exec test-claude-dev ls -la /config/claude-config/
```

#### Network Testing

```bash
# Test web endpoint
curl -I http://localhost:7681

# Test WebSocket connection
curl --include --no-buffer \
  --header "Connection: Upgrade" \
  --header "Upgrade: websocket" \
  --header "Sec-WebSocket-Key: SGVsbG8sIHdvcmxkIQ==" \
  --header "Sec-WebSocket-Version: 13" \
  http://localhost:7681/ws
```

### Performance Testing

#### Resource Usage

```bash
# Monitor container resources
podman stats test-claude-dev

# Check container size
podman images local/claude-terminal:test

# Inspect layers
podman history local/claude-terminal:test
```

#### Load Testing

```bash
# Multiple concurrent connections
for i in {1..5}; do
  curl http://localhost:7681 &
done
wait
```

### Common Issues & Solutions

#### Port Already In Use
```bash
# Find and kill process using port 7681
sudo lsof -ti:7681 | xargs kill -9

# Or use different port
podman run -d --name test-claude-dev -p 7682:7681 -v /tmp/test-config:/config local/claude-terminal:test
```

#### Volume Mount Issues
```bash
# Ensure directory exists and has correct permissions
mkdir -p /tmp/test-config/claude-config
chmod 755 /tmp/test-config/claude-config

# Check SELinux labels (if applicable)
ls -laZ /tmp/test-config/
```

#### Build Cache Issues
```bash
# Force rebuild without cache
podman build --no-cache --build-arg BUILD_FROM=ghcr.io/home-assistant/amd64-base:3.24 \
  -t local/claude-terminal:test ./claude-terminal

# Clean up unused images
podman image prune
```

### Cleanup Commands

#### Clean Up Test Environment
```bash
# Stop and remove test containers
podman stop test-claude-dev && podman rm test-claude-dev

# Remove test configurations
rm -rf /tmp/test-config*

# Clean up test images
podman rmi local/claude-terminal:test
```

#### Full System Cleanup
```bash
# Remove all stopped containers
podman container prune

# Remove unused images
podman image prune

# Remove unused volumes
podman volume prune
```

## Testing on a Real Home Assistant (`scripts/dev-deploy.sh`)

Some things only happen on real Home Assistant: ingress, the login
notification, Remote Control, options from the UI, backups. To test them
without a version bump, a push or a release, install the working tree as a
separate local add-on, **Claude Terminal (dev)**:

```bash
scripts/dev-deploy.sh root@homeassistant.local
```

The script copies `claude-terminal/` to `/addons/claude-terminal-dev` over
SSH, then runs `ha store reload` and installs it (first time) or updates it.
HA builds the image on the box, which takes a few minutes.

- **It needs an SSH add-on**: Advanced SSH & Web Terminal or the official
  Terminal & SSH. Both mount `/addons` and have the `ha` CLI. Log in as a
  user that can write to `/addons` (in Advanced SSH, set `username: root`).
  If the add-on doesn't listen on port 22, use the URI form, e.g.
  `scripts/dev-deploy.sh ssh://root@homeassistant.local:2222`, or a Host
  entry in `~/.ssh/config`. You can set `DEV_DEPLOY_TARGET` instead of
  passing the target every time.
- **It can't touch the real add-on**: the copy's slug is `claude_terminal_dev`,
  so it has its own `/data` and its own sidebar panel. Log in to Claude once
  in it, and set its options in Settings → Add-ons → Claude Terminal (dev).
- **Every deploy is an update**: the version becomes
  `<version>-dev.<commit>.<timestamp>`, so uncommitted edits are picked up
  too. No version bump or changelog entry is needed until the change is
  ready to release.
- **It only runs when you start it**: the first install doesn't start it, and
  it is set not to start with Home Assistant (`boot: manual`). Open it in
  Settings → Add-ons, set options, and start it. Later deploys restart it if
  it is running.
- `--copy-only` skips the `ha` step (then use Add-on Store → ⋮ → Check for
  updates). With no target, the script only builds `dist/claude-terminal-dev/`,
  which you can copy through the Samba `addons` share instead.
- HA may briefly show an update for the dev add-on that then says none is
  available. The script reloads the store just before updating, and HA's
  update entity can catch the new version in between. It clears the next
  time HA polls the Supervisor, within a few minutes.
- Both add-ons post their login link under the same notification ID, so
  starting one clears a login notification the other is still showing.

Remove it when done: uninstall it in HA, then
`ssh root@homeassistant.local rm -rf /addons/claude-terminal-dev`.

## Production Deployment

Once testing is complete:

```bash
# Commit changes
git add .
git commit -m "feature: description of changes"

# Update version in config.yaml
vim claude-terminal/config.yaml

# Push to main branch
git push origin main
```

The changes will automatically be built and distributed to Home Assistant users.

## Advanced Testing

### Integration with Home Assistant

```bash
# Test with real Home Assistant config structure
mkdir -p /tmp/ha-config/{.storage,claude-config}
echo '{"auto_launch_claude": false}' > /tmp/ha-config/options.json

podman run -d --name test-ha-claude -p 7681:7681 \
  -v /tmp/ha-config:/config local/claude-terminal:test
```

### Cross-Platform Testing

```bash
# Test different base images. Home Assistant Supervisor always passes BUILD_ARCH;
# reproduce that locally so the Dockerfile resolves the right architecture. For a
# real cross-build add --platform so the emulated toolchain matches.
podman build --platform linux/arm64 \
  --build-arg BUILD_ARCH=aarch64 \
  --build-arg BUILD_FROM=ghcr.io/home-assistant/aarch64-base:3.24 \
  -t local/claude-terminal:arm64 ./claude-terminal
```
