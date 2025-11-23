# Install Persistent Packages

Install system packages that survive container restarts using the persistent package manager.

## Usage
- `/install <package1> [package2] [...]` - Install system packages
- Example: `/install python3 py3-pip git vim`

## What You Should Do

1. **Understand the request**: User wants to install system packages (Alpine APK packages)
2. **Use persist-install**: Run `persist-install <packages>` NOT `apk add`
3. **Verify installation**: Check the package is available (e.g., `python3 --version`)
4. **Explain persistence**: Tell the user the packages will survive reboots

## Important

- **ALWAYS use `persist-install`** - Never use `apk add` directly
- **Packages persist across reboots** - They're stored in `/data/packages`
- **Explain to the user** - Make it clear these packages will survive restarts

## Example

When user runs: `/install python3 py3-pip`

You should:
1. Run: `persist-install python3 py3-pip`
2. Verify: `python3 --version`
3. Say: "Python installed successfully! It's stored in /data/packages and will persist across reboots."

## Common Packages

- `python3 py3-pip` - Python and package manager
- `git` - Version control
- `vim` - Text editor
- `htop` - Process monitor
- `sqlite` - Database
- `wget` - Download tool

For Python packages, use `/install-python` instead.
