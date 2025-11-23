# Install Python Packages

Install Python packages that survive container restarts using the persistent package manager.

## Usage
- `/install-python <package1> [package2] [...]` - Install Python packages
- Example: `/install-python homeassistant-cli requests pandas`

## What You Should Do

1. **Check Python is installed**: If not, install it first with `persist-install python3 py3-pip`
2. **Install packages**: Run `persist-install --python <packages>` NOT `pip install`
3. **Verify installation**: Test the package (e.g., `hass-cli --version` or `python3 -c "import requests"`)
4. **Explain persistence**: Tell the user the packages will survive reboots

## Important

- **Ensure Python is installed first**: Run `python3 --version` to check
- **ALWAYS use `persist-install --python`** - Never use `pip install` directly
- **Packages install to venv** - Located at `/data/packages/python/venv`
- **Packages persist across reboots** - They're in persistent storage

## Example

When user runs: `/install-python homeassistant-cli`

You should:
1. Check: `python3 --version` (install if needed)
2. Run: `persist-install --python homeassistant-cli`
3. Verify: `hass-cli --version`
4. Say: "Home Assistant CLI installed successfully! It's in the persistent Python virtual environment and will survive reboots."

## Common Python Packages

- `homeassistant-cli` - Home Assistant CLI
- `requests` - HTTP library
- `pyyaml` - YAML parser
- `pandas` - Data analysis
- `numpy` - Numerical computing
- `flask` - Web framework
- `jupyter` - Jupyter notebooks
- `black` - Code formatter

For system packages, use `/install` instead.
