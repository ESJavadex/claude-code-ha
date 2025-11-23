# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This repository contains Home Assistant add-ons, specifically the **Claude Terminal** add-on which provides a web-based terminal interface with Claude Code CLI pre-installed. The add-on allows Home Assistant users to access Claude AI capabilities directly from their dashboard.

## Development Environment

### Setup
```bash
# Enter the development shell (NixOS/Nix)
nix develop

# Or with direnv (if installed)
direnv allow
```

### Core Development Commands
- `build-addon` - Build the Claude Terminal add-on with Podman
- `run-addon` - Run add-on locally on port 7681 with volume mapping
- `lint-dockerfile` - Lint Dockerfile using hadolint
- `test-endpoint` - Test web endpoint availability (curl localhost:7681)

### Manual Commands (without aliases)
```bash
# Build
podman build --build-arg BUILD_FROM=ghcr.io/home-assistant/amd64-base:3.19 -t local/claude-terminal ./claude-terminal

# Run locally
podman run -p 7681:7681 -v $(pwd)/config:/config local/claude-terminal

# Lint
hadolint ./claude-terminal/Dockerfile

# Test endpoint
curl -X GET http://localhost:7681/
```

## Architecture

### Add-on Structure (claude-terminal/)
- **config.yaml** - Home Assistant add-on configuration (multi-arch, ingress, ports)
- **Dockerfile** - Alpine-based container with Node.js and Claude Code CLI
- **build.yaml** - Multi-architecture build configuration (amd64, aarch64, armv7)
- **run.sh** - Main startup script with credential management and ttyd terminal
- **scripts/** - Modular credential management scripts

### Key Components
1. **Web Terminal**: Uses ttyd to provide browser-based terminal access
2. **Credential Management**: Persistent authentication storage in `/config/claude-config/`
3. **Service Integration**: Home Assistant ingress support with panel icon
4. **Multi-Architecture**: Supports amd64, aarch64, armv7 platforms

### Credential System
The add-on implements a sophisticated credential management system:
- **Persistent Storage**: Credentials saved to `/config/claude-config/` (survives restarts)
- **Multiple Locations**: Handles various Claude credential file locations
- **Background Service**: Continuous credential monitoring and saving
- **Security**: Proper file permissions (600) and safe directory operations

### Container Execution Flow
1. Initialize environment and create credential directories
2. Install ttyd and tools via apk
3. Setup modular credential management scripts
4. Start background credential monitoring service
5. Launch ttyd web terminal with Claude auto-start

## Development Notes

### Local Container Testing
For rapid development and debugging without pushing new versions:

#### Quick Build & Test
```bash
# Build test version
podman build --build-arg BUILD_FROM=ghcr.io/home-assistant/amd64-base:3.19 -t local/claude-terminal:test ./claude-terminal

# Create test config directory
mkdir -p /tmp/test-config/claude-config

# Configure session picker (optional)
echo '{"auto_launch_claude": false}' > /tmp/test-config/options.json

# Run test container
podman run -d --name test-claude-dev -p 7681:7681 -v /tmp/test-config:/config local/claude-terminal:test

# Check logs
podman logs test-claude-dev

# Test web interface at http://localhost:7681

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
- **Volume contents**: `ls -la /tmp/test-config/` to verify persistence

### Production Testing
- **Local Testing**: Use `run-addon` to test on localhost:7681
- **Container Health**: Check logs with `podman logs <container-id>`
- **Authentication**: Use `claude-auth debug` within terminal for credential troubleshooting

### File Conventions
- **Shell Scripts**: Use `#!/usr/bin/with-contenv bashio` for add-on scripts
- **Indentation**: 2 spaces for YAML, 4 spaces for shell scripts
- **Error Handling**: Use `bashio::log.error` for error reporting
- **Permissions**: Credential files must have 600 permissions

### Key Environment Variables
- `CLAUDE_CREDENTIALS_DIRECTORY=/config/claude-config`
- `ANTHROPIC_CONFIG_DIR=/config/claude-config`
- `HOME=/root`

### Important Constraints
- No sudo privileges available in development environment
- Add-on targets Home Assistant OS (Alpine Linux base)
- Must handle credential persistence across container restarts
- Requires multi-architecture compatibility

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
persist-install --python homeassistant-cli requests pandas numpy

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
User: "Install homeassistant-cli"

Claude (YOU): "I'll install the Home Assistant CLI using persist-install to
              ensure it persists."

[Run]: persist-install --python homeassistant-cli

[Verify]: hass-cli --version

Claude: "Home Assistant CLI installed successfully! You can now use commands
        like 'hass-cli entity list'."
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
- `homeassistant-cli` - Home Assistant CLI
- `requests` - HTTP library
- `pyyaml` - YAML parser
- `pandas` - Data analysis
- `numpy` - Numerical computing
- `flask` / `fastapi` - Web frameworks
- `jupyter` - Jupyter notebooks

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
```

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