# Persistent Package Management Guide

## 🎯 Problem Solved

**Before**: Installing packages with `apk add` in the terminal disappeared after reboot
**After**: Use `persist-install` to install packages that survive forever!

---

## 🚀 Quick Start

### Install System Packages
```bash
# Install Python
persist-install python3 py3-pip

# Install development tools
persist-install git vim htop

# Install multiple packages at once
persist-install curl wget jq sqlite
```

### Install Python Packages
```bash
# Install Home Assistant CLI
persist-install --python homeassistant-cli

# Install data science tools
persist-install --python pandas numpy requests

# Install web frameworks
persist-install --python flask fastapi
```

### Check What's Installed
```bash
persist-install --list
```

---

## 📋 How It Works

### The Persistent Storage Model

```
┌─────────────────────────────────────────────┐
│  Container Filesystem (EPHEMERAL)          │
│  - Base image packages (node, npm, bash)   │
│  - Runtime installs disappear on reboot    │
│  ❌ apk add python3 → LOST on reboot      │
└─────────────────────────────────────────────┘
                    ↕
┌─────────────────────────────────────────────┐
│  /data/packages (PERSISTENT)               │
│  - Stored on Home Assistant's disk         │
│  - Survives reboots and updates            │
│  ✅ persist-install python3 → PERMANENT    │
└─────────────────────────────────────────────┘
```

### Directory Structure

```
/data/packages/
├── bin/              # Executable binaries (in PATH)
│   ├── python3
│   ├── git
│   └── vim
├── lib/              # Shared libraries
│   └── *.so files
└── python/           # Python virtual environment
    └── venv/
        ├── bin/
        │   ├── python
        │   ├── pip
        │   └── hass-cli
        └── lib/
            └── python3.*/site-packages/
```

### PATH Priority

```bash
# Persistent packages are checked FIRST
/data/packages/bin                    # ← persist-install packages
/data/packages/python/venv/bin        # ← Python packages
/usr/local/bin                        # System packages
/usr/bin
/bin
```

---

## 🔧 Configuration: Auto-Install on Startup

You can configure packages to install automatically every time the add-on starts.

### Via Home Assistant UI

1. Go to **Settings** → **Add-ons** → **Claude Terminal**
2. Click **Configuration** tab
3. Add your packages:

```yaml
persistent_apk_packages:
  - python3
  - py3-pip
  - git
  - vim
  - htop

persistent_pip_packages:
  - homeassistant-cli
  - requests
  - pyyaml
```

4. **Save** and **Restart** the add-on

### Via config file (Advanced)

Edit `/config/claude-terminal/options.json`:

```json
{
  "auto_launch_claude": true,
  "persistent_apk_packages": [
    "python3",
    "py3-pip",
    "git",
    "vim",
    "htop"
  ],
  "persistent_pip_packages": [
    "homeassistant-cli",
    "requests",
    "pyyaml"
  ]
}
```

---

## 📚 Examples

### Example 1: Python Development Environment

```bash
# Install Python and essential tools
persist-install python3 py3-pip

# Install development libraries
persist-install --python ipython black pytest

# Install Home Assistant integration
persist-install --python homeassistant-cli

# Verify installation
python3 --version
pip --version
hass-cli --version

# Reboot your Raspberry Pi - everything still works!
```

### Example 2: Git Workflow

```bash
# Install Git
persist-install git

# Configure Git (persists in /data)
git config --global user.name "Your Name"
git config --global user.email "you@example.com"

# Clone repositories
cd /config
git clone https://github.com/yourusername/your-repo.git
```

### Example 3: System Administration Tools

```bash
# Install monitoring tools
persist-install htop iotop ncdu

# Install network tools
persist-install curl wget netcat-openbsd

# Install text processing
persist-install jq sed gawk

# Use them immediately
htop        # Process monitor
ncdu /      # Disk usage analyzer
```

### Example 4: Home Assistant Automation

```bash
# Install HA CLI and Python tools
persist-install python3 py3-pip
persist-install --python homeassistant-cli pyyaml

# Use HA CLI (requires HA API access)
hass-cli entity list
hass-cli state get sensor.temperature
hass-cli service call light.turn_on --arguments entity_id=light.living_room
```

---

## 🧪 Testing Persistence

### Verify packages survive reboots:

```bash
# 1. Install a package
persist-install python3
python3 --version

# 2. Check it's in persistent storage
ls -la /data/packages/bin/python3

# 3. Reboot your Raspberry Pi
# (or restart the add-on)

# 4. Verify it still works
python3 --version  # ✅ Still there!
```

---

## 🔍 Troubleshooting

### Package not found after installation

```bash
# Check if it's in persistent storage
ls -la /data/packages/bin/

# Check PATH includes persistent directory
echo $PATH | grep /data/packages

# Manually add to PATH if needed
export PATH="/data/packages/bin:$PATH"
```

### Python package import errors

```bash
# Activate the virtual environment
source /data/packages/python/venv/bin/activate

# Check installed packages
pip list

# Reinstall if needed
persist-install --python package-name
```

### Shared library errors (.so files)

```bash
# Check library path
echo $LD_LIBRARY_PATH

# List installed libraries
ls -la /data/packages/lib/

# Some complex packages may not work
# (requires all dependencies to be in persistent storage)
```

### Clean slate (remove all packages)

```bash
# Remove all persistent packages
rm -rf /data/packages/*

# Restart add-on to rebuild structure
```

---

## 💡 Best Practices

### ✅ DO

- Use `persist-install` for packages you need regularly
- Configure auto-install for your essential toolkit
- Use Python virtual environment for Python packages
- Test packages before adding to auto-install
- Keep packages list minimal to reduce startup time

### ❌ DON'T

- Don't use `apk add` directly (packages will disappear)
- Don't install huge packages (database servers, etc.)
- Don't expect 100% compatibility with all packages
- Don't install packages with complex system dependencies
- Don't modify `/data/packages/` manually (use persist-install)

---

## 🎓 Advanced Usage

### Using the Python Virtual Environment

```bash
# Activate venv manually
source /data/packages/python/venv/bin/activate

# Install with pip directly
pip install your-package

# Deactivate
deactivate
```

### Creating Custom Scripts

```bash
# Create a script in persistent storage
cat > /data/packages/bin/my-script.sh << 'EOF'
#!/bin/bash
echo "This script persists!"
EOF

chmod +x /data/packages/bin/my-script.sh

# Run it (it's in PATH)
my-script.sh
```

### Checking Disk Usage

```bash
# See how much space packages use
du -sh /data/packages

# Detailed breakdown
du -sh /data/packages/*
```

---

## 🆚 Comparison

| Method | Survives Reboot? | Survives Update? | Speed | Flexibility |
|--------|------------------|------------------|-------|-------------|
| `apk add` (old way) | ❌ No | ❌ No | Fast | High |
| Dockerfile (v1.3.x) | ✅ Yes | ✅ Yes | Slow rebuild | Low |
| `persist-install` (v1.4.0+) | ✅ Yes | ✅ Yes | Fast | High |

---

## 📖 Further Reading

- [Home Assistant Add-on Documentation](https://developers.home-assistant.io/docs/add-ons/)
- [Alpine Linux Packages](https://pkgs.alpinelinux.org/)
- [Python Package Index (PyPI)](https://pypi.org/)
- [Docker Volume Documentation](https://docs.docker.com/storage/volumes/)

---

## 🐛 Known Limitations

1. **Complex packages**: Some packages with heavy system dependencies may not work
2. **Compiled binaries**: Architecture-specific binaries may fail on different platforms
3. **Kernel modules**: Cannot install kernel-level packages
4. **System services**: Cannot run systemd/init services
5. **Storage space**: Limited by Home Assistant's available disk space

---

## 💬 Support

If you encounter issues:

1. Check the add-on logs: **Settings** → **Add-ons** → **Claude Terminal** → **Log**
2. Run `persist-install --list` to verify installations
3. Report issues on GitHub with log output
4. Include your package list and error messages
