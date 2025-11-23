---
name: persistent-package-manager
description: |
  Install and manage packages that persist across container restarts in Home Assistant add-ons.
  Use this skill when users ask to install system packages (git, vim, python3) or Python packages
  (homeassistant-cli, requests, pandas). Automatically uses persist-install instead of apk/pip
  to ensure packages survive reboots and container recreations.
---

# Persistent Package Manager Skill

## Purpose

This skill helps you install packages in the Claude Terminal Home Assistant add-on that will **persist across container restarts and reboots**. You must NEVER use `apk add` or `pip install` directly, as those install to ephemeral storage that disappears on restart.

## Core Concept: Container Architecture

```
┌─────────────────────────────────────────┐
│  Container Filesystem (EPHEMERAL)      │
│  - Base image packages (node, npm)     │
│  - apk add installs HERE (LOST!)       │
│  ❌ Disappears on reboot               │
└─────────────────────────────────────────┘
              ↕
┌─────────────────────────────────────────┐
│  /data/packages (PERSISTENT)           │
│  - persist-install installs HERE       │
│  - Survives reboots & updates          │
│  ✅ Permanent storage                  │
└─────────────────────────────────────────┘
```

## When to Use This Skill

Activate this skill when users:
- Ask to install any package: "install python", "I need git", "add vim"
- Want to use a tool that isn't installed: "can we use pandas?"
- Encounter "command not found" errors
- Ask about package management or persistence
- Want to set up a development environment

## The Golden Rule

**ALWAYS use `persist-install` - NEVER use `apk add` or `pip install` directly!**

## Commands Available

### 1. Install System Packages (Alpine APK)

```bash
persist-install <package1> [package2] [...]
```

**Examples**:
```bash
persist-install python3 py3-pip
persist-install git vim htop
persist-install curl wget jq sqlite
```

### 2. Install Python Packages

```bash
persist-install --python <package1> [package2] [...]
```

**Examples**:
```bash
persist-install --python homeassistant-cli
persist-install --python requests pandas numpy
persist-install --python flask fastapi uvicorn
```

### 3. List Installed Packages

```bash
persist-install --list
```

### 4. Get Help

```bash
persist-install --help
```

## Your Workflow When User Asks to Install

### Step 1: Recognize Intent

User phrases like:
- "install X"
- "I need X"
- "can you add X?"
- "let's use X"
- "how do I get X?"
- "bash: X: command not found"

### Step 2: Check If Already Installed (Optional but Recommended)

```bash
which <package>
# or
command -v <package>
# or
<package> --version
```

### Step 3: Use persist-install

**For system packages**:
```bash
persist-install <package>
```

**For Python packages**:
```bash
# Ensure Python is installed first!
python3 --version || persist-install python3 py3-pip

# Then install Python package
persist-install --python <package>
```

### Step 4: Verify Installation

```bash
<package> --version
# or
which <package>
# or for Python packages
python3 -c "import <package>"
```

### Step 5: Explain to User

Tell them:
- ✅ Package installed successfully
- ✅ Stored in `/data/packages` (persistent storage)
- ✅ Will survive reboots and container restarts
- ✅ Available in PATH immediately

## Example Conversations

### Example 1: Installing Python

```
User: "I need Python installed"

You: "I'll install Python using persist-install so it survives reboots."

[Execute]: persist-install python3 py3-pip

[Verify]: python3 --version

You: "Python 3.11.x installed successfully! It's stored in /data/packages
     and will persist across all restarts. You can now install Python
     packages with: persist-install --python <package>"
```

### Example 2: Installing Home Assistant CLI

```
User: "Install homeassistant-cli"

You: "I'll install the Home Assistant CLI using the persistent package manager."

[Check Python]: python3 --version
[If not found]: persist-install python3 py3-pip

[Execute]: persist-install --python homeassistant-cli

[Verify]: hass-cli --version

You: "Home Assistant CLI installed! You can now use commands like:
     - hass-cli entity list
     - hass-cli state get sensor.temperature
     - hass-cli service call light.turn_on

     It's stored in the persistent Python virtual environment."
```

### Example 3: Data Science Setup

```
User: "Set me up for data science work"

You: "I'll set up a complete data science environment with persistent packages."

[Execute]: persist-install python3 py3-pip
[Execute]: persist-install --python pandas numpy scipy matplotlib jupyter

[Verify]: python3 -c "import pandas; import numpy; print('All packages ready!')"

You: "Data science environment ready! Installed:
     - Python 3.11.x
     - pandas - Data analysis
     - numpy - Numerical computing
     - scipy - Scientific computing
     - matplotlib - Plotting
     - jupyter - Interactive notebooks

     All packages are persistent and will survive reboots."
```

### Example 4: Development Tools

```
User: "I want git and vim"

You: "I'll install git and vim using persist-install."

[Execute]: persist-install git vim

[Verify]:
git --version
vim --version

You: "Development tools installed:
     - Git 2.x - Version control
     - Vim 9.x - Text editor

     Both are persistent and available in PATH."
```

## Common Packages

### System Tools
- `python3 py3-pip` - Python and package manager
- `git` - Version control
- `vim` - Text editor (nano already installed)
- `htop` - Process monitor
- `sqlite` - Database
- `wget` - Download tool
- `tree` - Directory viewer
- `tmux` - Terminal multiplexer

### Python Packages
- `homeassistant-cli` - Home Assistant management
- `requests` - HTTP library
- `pyyaml` - YAML parser
- `pandas` - Data analysis
- `numpy` - Numerical computing
- `flask` - Web framework
- `fastapi` - Modern web framework
- `jupyter` - Notebooks
- `black` - Code formatter
- `pytest` - Testing framework

## Auto-Install Configuration

When users ask about automatic installation on startup, guide them:

1. Go to **Settings** → **Add-ons** → **Claude Terminal**
2. Click **Configuration** tab
3. Add packages to configuration:

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

4. **Save** and **Restart** the add-on

These packages will auto-install every time the container starts!

## Troubleshooting

### Package not found after installation

```bash
# Check if in persistent storage
ls -la /data/packages/bin/

# Check PATH
echo $PATH | grep /data/packages
```

### Python import errors

```bash
# Activate venv manually
source /data/packages/python/venv/bin/activate

# List installed packages
pip list
```

### Check disk usage

```bash
du -sh /data/packages
```

### Re-install package

```bash
# Just run persist-install again
persist-install <package>
```

## Important Reminders

1. **NEVER use `apk add`** for user-requested packages - Always `persist-install`
2. **NEVER use `pip install`** directly - Always `persist-install --python`
3. **ALWAYS verify** after installation with `--version` or test command
4. **ALWAYS explain** that packages will persist across reboots
5. **BE PROACTIVE** - Install packages when you detect the need
6. **CHECK FIRST** - See if package is already installed before installing

## Storage Details

- **Location**: `/data/packages/`
- **Binaries**: `/data/packages/bin/` (in PATH)
- **Libraries**: `/data/packages/lib/` (in LD_LIBRARY_PATH)
- **Python venv**: `/data/packages/python/venv/`
- **Persistence**: Survives all reboots, restarts, and updates

## What NOT to Do

❌ **DON'T** use `apk add python3` - Use `persist-install python3`
❌ **DON'T** use `pip install requests` - Use `persist-install --python requests`
❌ **DON'T** forget to verify installation
❌ **DON'T** install packages to system paths
❌ **DON'T** assume packages will persist without using persist-install

## Best Practices

✅ **DO** check if package is already installed first
✅ **DO** use persist-install for all user-requested packages
✅ **DO** verify installation after installing
✅ **DO** explain persistence to users
✅ **DO** suggest auto-install config for frequently used packages
✅ **DO** batch install related packages together

## Quick Reference

| User Says | You Do | Command |
|-----------|--------|---------|
| "install python" | Install Python | `persist-install python3 py3-pip` |
| "I need git" | Install git | `persist-install git` |
| "install pandas" | Install Python package | `persist-install --python pandas` |
| "what's installed?" | List packages | `persist-install --list` |
| "install git vim htop" | Install multiple | `persist-install git vim htop` |

## Summary

When users ask to install anything:
1. ✅ Use `persist-install` (NOT apk/pip)
2. ✅ Verify it works
3. ✅ Explain it persists
4. ✅ Suggest auto-install if appropriate

This ensures packages survive reboots and provides a great user experience!
