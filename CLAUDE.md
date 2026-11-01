# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This repository contains Home Assistant add-ons, specifically the **Claude Terminal Pro** add-on which provides a web-based terminal interface with Claude Code CLI pre-installed and persistent package management. The add-on allows Home Assistant users to access Claude AI capabilities directly from their dashboard.

**Fork Attribution:** This is an enhanced fork of [heytcass/home-assistant-addons](https://github.com/heytcass/home-assistant-addons) by Tom Cassady, maintained by Javier Santos ([@esjavadex](https://github.com/esjavadex)). The fork adds persistent package management, auto-install configuration, and enhanced documentation.

## Development Environment

### Setup
```bash
# Enter the development shell (NixOS/Nix)
nix develop

# Or with direnv (if installed)
direnv allow
```

### Core Development Commands
- `build-addon` - Build the Claude Terminal Pro add-on with Podman
- `run-addon` - Run add-on locally on port 7681 with volume mapping
- `lint-dockerfile` - Lint Dockerfile using hadolint
- `test-endpoint` - Test web endpoint availability (curl localhost:7681)

### Manual Commands (without aliases)
```bash
# Build
podman build --build-arg BUILD_FROM=ghcr.io/home-assistant/amd64-base:3.24 -t local/claude-terminal-pro ./claude-terminal

# Run locally
podman run -p 7680:7680 -p 7681:7681 -e DEV_DIRECT_ACCESS=1 -v $(pwd)/config:/config local/claude-terminal-pro

# Lint
hadolint ./claude-terminal/Dockerfile

# Test endpoint
curl -X GET http://localhost:7681/
```

## Architecture

### Add-on Structure (claude-terminal/)
- **config.yaml** - Home Assistant add-on configuration (multi-arch, ingress, ports)
- **translations/en.yaml** - The label and help text for each option in the Configuration tab, and the Network tab's port warnings. Every new option needs an entry (`scripts/check-addon-metadata.py` checks)
- **Dockerfile** - Alpine-based container with Node.js and Claude Code CLI
- **build.yaml** - Multi-architecture build configuration (amd64, aarch64)
- **run.sh** - Main startup script: sets up `/data`, tmux, persistent Claude/packages, then starts the image service and ttyd
- **scripts/** - Session picker, auth helper, `persist-install`, health check, HA CLI installer and API examples
- **image-service/** - Node.js web page on port 7680 (the ingress panel) that embeds ttyd and handles image upload/paste

### Key Components
1. **Web Terminal**: ttyd on port 7681, attached to a persistent tmux session, embedded in the image-service page on 7680
2. **Persistent State**: All Claude state (login, settings, history) and installed packages live in the add-on's private `/data`
3. **Service Integration**: Home Assistant ingress support with panel icon
4. **Multi-Architecture**: Supports amd64 and aarch64 (armv7 was dropped in 2.3.9)

### Persistent State (`/data`)
`/data` is private to each installed add-on and survives restarts and updates. `run.sh` (`init_environment`) points everything there:
- `HOME=/data/home` - Claude's `~/.claude*` files, including OAuth credentials
- `/data/.config/claude` - `ANTHROPIC_CONFIG_DIR`; XDG config/cache/state dirs are also under `/data`
- `/data/packages` - `persist-install` packages; `/data/npm` - the optional persistent Claude install (`use_persistent_claude`)
- `/data/options.json` - add-on options, written by the Supervisor on each start (bashio reads them from the Supervisor API, not this file)
- `/config/claude-config` is only a **legacy** location: if it exists, its files are copied into `/data/.config/claude` on startup (`migrate_legacy_auth_files`). Nothing is saved there any more.

Because `/data` is per add-on, installing the add-on from a different repository (or branch) starts with a fresh `/data`: the user must log in again and only options can be copied across (Configuration → Edit in YAML).

### Container Execution Flow (`main` in run.sh)
1. Run the health check
2. Initialize `/data` directories and environment variables, migrating any legacy auth files
3. Warn if the CPU lacks AVX; remove leftover npm/pip caches and old Claude versions from `/data` (ttyd, tmux, jq and curl are baked into the image)
4. Configure tmux and the `tmux-claude` wrapper
5. Set up persistent Claude (if `use_persistent_claude`)
6. Install the session picker and auth helper
7. Set up `persist-install` and auto-install packages listed in the options
8. Start the image service (7680), the login URL watcher (posts Claude's login link as an HA notification) and ttyd (7681)

## Development Notes

### Local Container Testing
For rapid development and debugging without pushing new versions:

#### Quick Build & Test
```bash
# Build test version
podman build --build-arg BUILD_FROM=ghcr.io/home-assistant/amd64-base:3.24 -t local/claude-terminal:test ./claude-terminal

# Create test directories (/data holds all add-on state, /config is HA's config dir)
mkdir -p /tmp/test-config /tmp/test-data /tmp/test-tmp/.bashio

# Options (optional). bashio::config asks the Supervisor API, not
# /data/options.json, and caches the answer; with no Supervisor, seed that
# cache. List every option: a missing key comes back as the string "null".
cat > /tmp/test-tmp/.bashio/addons.self.options.config.cache << 'OPTIONS'
{"auto_launch_claude": false, "tmux_mouse": false, "working_directory": "",
 "claude_code_oauth_token": "", "dangerously_skip_permissions": false,
 "enable_remote_control": false, "claude_extra_args": "",
 "persistent_apk_packages": [], "persistent_pip_packages": [],
 "use_persistent_claude": false, "auto_update_claude_on_start": false}
OPTIONS

# Run test container
# DEV_DIRECT_ACCESS=1: there is no Supervisor to report published ports, so
# without it the web UI refuses non-ingress clients and ttyd binds to loopback
podman run -d --name test-claude-dev -p 7680:7680 -p 7681:7681 -e DEV_DIRECT_ACCESS=1 \
  -v /tmp/test-config:/config -v /tmp/test-data:/data -v /tmp/test-tmp:/tmp local/claude-terminal:test

# Check logs
podman logs test-claude-dev

# Test web interface at http://localhost:7680 (raw ttyd at http://localhost:7681)

# Stop and cleanup
podman stop test-claude-dev && podman rm test-claude-dev
```

#### Interactive Testing
```bash
# Test session picker directly
podman run --rm -it local/claude-terminal:test /opt/scripts/claude-session-picker.sh

# Execute commands inside running container
podman exec -it test-claude-dev /bin/bash

# Test script modifications without rebuilding
podman cp ./claude-terminal/scripts/claude-session-picker.sh test-claude-dev:/opt/scripts/
podman exec test-claude-dev chmod +x /opt/scripts/claude-session-picker.sh
```

#### Development Workflow
1. **Make changes** to scripts or Dockerfile
2. **Rebuild** with `podman build -t local/claude-terminal:test ./claude-terminal`
3. **Stop/remove** old container: `podman stop test-claude-dev && podman rm test-claude-dev`
4. **Start new** container with updated image
5. **Test** changes at http://localhost:7681
6. **Repeat** until satisfied, then commit and push

#### Debugging Tips
- **Check container logs**: `podman logs -f test-claude-dev` (follow mode)
- **Inspect running processes**: `podman exec test-claude-dev ps aux`
- **Test individual scripts**: `podman exec test-claude-dev /opt/scripts/script-name.sh`
- **Volume contents**: `ls -la /tmp/test-data/` to verify persistence

### Production Testing
- **Local Testing**: Use `run-addon` to test on localhost:7681
- **On real Home Assistant**: `scripts/dev-deploy.sh root@homeassistant.local` installs the working tree as a separate local add-on, "Claude Terminal (dev)" (own slug and `/data`; no version bump needed). See DEVELOPMENT.md
- **Container Health**: Check logs with `podman logs <container-id>`
- **Authentication**: If pasting the login code fails, use the session picker's auth helper (`/opt/scripts/claude-auth-helper.sh`); check `ls -la /data/home/.claude* /data/.config/claude` for credential files

### File Conventions
- **Shell Scripts**: Use `#!/usr/bin/with-contenv bashio` for add-on scripts
- **Indentation**: 2 spaces for YAML, 4 spaces for shell scripts
- **Error Handling**: Use `bashio::log.error` for error reporting
- **Permissions**: Credential files must have 600 permissions
- **Option reads**: `run.sh` runs under `set -e`, and on the Alpine 3.24 base `bashio::config` fails (instead of returning empty) when the Supervisor API can't be reached. Give every read assigned to a variable its default as a fallback: `x=$(bashio::config 'key' 'false') || x='false'`

### Key Environment Variables
- `HOME=/data/home`
- `ANTHROPIC_CONFIG_DIR=/data/.config/claude`
- `XDG_CONFIG_HOME=/data/.config`, `XDG_CACHE_HOME=/data/.cache`, `XDG_STATE_HOME=/data/.local/state`
- `DISABLE_AUTOUPDATER=1` (updates come from add-on releases or the persistent install)

### Important Constraints
- No sudo privileges available in development environment
- Add-on targets Home Assistant OS (Alpine Linux base)
- Anything that must survive a restart has to live in `/data` (container filesystem is ephemeral)
- Requires multi-architecture compatibility

## Release Management

### CRITICAL: Always Update Version and Changelog

**When making ANY changes to the add-on, you MUST:**

1. **Bump the version** in `claude-terminal/config.yaml`
   - Patch version (x.x.X) for bug fixes and small changes
   - Minor version (x.X.0) for new features
   - Major version (X.0.0) for breaking changes

2. **Update the changelog** in `claude-terminal/CHANGELOG.md`
   - Add new version section at the TOP of the file
   - Use the format: `## X.X.X` followed by `### Category - Description`
   - Categories: ✨ New Feature, 🐛 Bug Fix, 🛠️ Improvement, 📚 Documentation, 🔧 Technical
   - Include bullet points describing what changed and why

**Example workflow:**
```bash
# 1. Make your code changes
# 2. Bump version in config.yaml (e.g., 1.7.3 → 1.7.4)
# 3. Add changelog entry at the top of CHANGELOG.md
# 4. Commit all changes together
```

**Changelog entry format:**
```markdown
## 1.7.4

### ✨ New Feature - Short Description
- **Bold summary**: Detailed explanation of the change
  - Sub-bullet for additional details
  - Another sub-bullet if needed
```

**DO NOT** commit changes without updating both the version and changelog!

## Persistent Package Management (v1.4.0+)

### CRITICAL: When Users Ask to Install Packages

**ALWAYS use `persist-install` instead of `apk add` or `pip install` directly!**

When a user asks you to install ANY package (Python, system tools, libraries, etc.), you MUST:

1. **Recognize the intent**: User says "install X", "I need X", "can you add X", etc.
2. **Use persist-install**: NEVER use `apk add` or `pip install` directly
3. **Explain why**: Tell them it will persist across reboots
4. **Verify**: Check that it worked and is available

### Why persist-install?

```bash
# ❌ WRONG - This disappears after reboot!
apk add python3

# ✅ CORRECT - This survives reboots!
persist-install python3
```

**Container Architecture**:
- `apk add` installs to ephemeral container layer (LOST on restart)
- `persist-install` installs to `/data/packages` (PERSISTENT storage)
- `/data` is mounted from Home Assistant and survives all reboots

### Usage Examples

```bash
# Install system packages (Alpine APK)
persist-install python3 py3-pip git vim htop

# Install Python packages
persist-install --python requests pandas numpy

# Install Home Assistant CLI (official ha command)
persist-install --ha-cli

# List installed packages
persist-install --list

# Check help
persist-install --help
```

### How It Works

```
/data/packages/
├── bin/              # Executable binaries (automatically in PATH)
├── lib/              # Shared libraries (LD_LIBRARY_PATH)
└── python/
    └── venv/         # Python virtual environment
        ├── bin/      # Python executables (in PATH)
        └── lib/      # Python packages (site-packages)
```

**Environment Setup**:
- `PATH="/data/packages/bin:/data/packages/python/venv/bin:$PATH"`
- Persistent packages are checked FIRST (highest priority)
- Python venv automatically activated when packages installed

### When User Asks to Install Something

**Example Conversation Flow**:

```
User: "I need Python installed"

Claude (YOU): "I'll install Python using persist-install so it survives reboots."

[Run]: persist-install python3 py3-pip

[Verify]: python3 --version

Claude: "Python 3.11.x installed successfully! It's stored in /data/packages
        and will persist across container restarts and reboots."
```

**Another Example**:

```
User: "I want to interact with Home Assistant entities"

Claude (YOU): "I'll show you how to use the Supervisor API to interact with
              Home Assistant. Let me install Python requests library."

[Run]: persist-install --python requests

[Show]: curl -H "Authorization: Bearer $SUPERVISOR_TOKEN" \
             http://supervisor/core/api/states | jq '.[0]'

Claude: "You can interact with Home Assistant using the Supervisor API!
        Check /opt/scripts/ha-api-examples.sh for more examples, or use
        Python's requests library for programmatic access."
```

### Proactive Behavior

**You should proactively use persist-install when:**

1. User mentions needing a package/tool/library
2. User wants to run a command that isn't installed
3. You recommend installing something
4. User asks about package management
5. Error indicates missing package

**Examples of user intent**:
- "install python"
- "I need git"
- "can you add vim?"
- "let's install requests"
- "how do I get pandas?"
- "bash: python: command not found" (error message)

### Common Packages Users Might Request

**System Tools**:
- `git` - Version control
- `vim` / `nano` - Text editors (nano already installed)
- `htop` - Process monitor
- `curl` / `wget` - Download tools (curl already installed)
- `jq` - JSON processor (already installed)
- `sqlite` - SQLite database

**Python Tools**:
- `python3 py3-pip` - Python and package manager
- `requests` - HTTP library for API calls
- `pyyaml` - YAML parser
- `pandas` - Data analysis
- `numpy` - Numerical computing
- `flask` / `fastapi` - Web frameworks
- `jupyter` - Jupyter notebooks

**Home Assistant CLI**:
- `ha` - Official Home Assistant CLI (install with `persist-install --ha-cli`)
  - Downloads from: https://github.com/home-assistant/cli
  - Provides commands: `ha core`, `ha supervisor`, `ha addons`, etc.
  - Alternative: Use Supervisor REST API (`http://supervisor/`) with `$SUPERVISOR_TOKEN`
  - See `scripts/ha-api-examples.sh` for API usage examples

### Auto-Install Configuration

Users can configure packages to auto-install on startup by editing the add-on configuration:

```yaml
persistent_apk_packages:
  - python3
  - py3-pip
  - git
  - vim

persistent_pip_packages:
  - homeassistant-cli
  - requests
```

**When users ask about auto-install**, guide them to:
1. Go to Settings → Add-ons → Claude Terminal
2. Click Configuration tab
3. Add packages to the lists above
4. Save and restart the add-on

### Troubleshooting

**Package not found after installation**:
```bash
# Check if it's in persistent storage
ls -la /data/packages/bin/

# Verify PATH includes persistent directory
echo $PATH | grep /data/packages

# If PATH is wrong, check if profile script exists
cat /etc/profile.d/persistent-packages.sh

# Source the profile manually if needed (temporary fix)
source /etc/profile.d/persistent-packages.sh

# If the profile script is missing, you're running an old version
# Update to v1.5.2+ which includes the PATH fix
```

**CRITICAL FIX (v1.5.2)**: Previous versions had a bug where persistent packages
were installed correctly but not in the PATH for ttyd bash sessions. This was
fixed by creating `/etc/profile.d/persistent-packages.sh` which is automatically
sourced by all bash sessions. If you installed packages before v1.5.2 and they
don't work, update to the latest version and restart the add-on.

**Python import errors**:
```bash
# Activate venv manually if needed
source /data/packages/python/venv/bin/activate

# Check installed packages
pip list
```

**Check disk usage**:
```bash
# See how much space packages use
du -sh /data/packages
```

### IMPORTANT REMINDERS

1. **NEVER use `apk add` for user-requested packages** - Always use `persist-install`
2. **ALWAYS verify after installation** - Run `--version` or test command
3. **EXPLAIN persistence** - Tell users packages will survive reboots
4. **BE PROACTIVE** - Install packages without being explicitly asked if user needs them
5. **CHECK FIRST** - Use `which` or `command -v` to see if already installed

### Example: Complete Installation Flow

```bash
# User asks: "I want to do data analysis with Python"

# Step 1: Install Python and pip
persist-install python3 py3-pip

# Step 2: Install data science packages
persist-install --python pandas numpy matplotlib jupyter

# Step 3: Verify installations
python3 --version
pip list | grep pandas

# Step 4: Inform user
echo "All set! You can now use Python for data analysis."
echo "Packages installed: pandas, numpy, matplotlib, jupyter"
echo "These will persist across reboots."
```

### Documentation Reference

For comprehensive details, see: `claude-terminal/PERSISTENT_PACKAGES.md`
