# List Installed Packages

Show all packages installed with the persistent package manager.

## Usage
- `/list-packages` - Show all persistent packages

## What You Should Do

1. **Run the list command**: `persist-install --list`
2. **Show the output**: Display what packages are installed
3. **Explain the structure**:
   - System binaries in `/data/packages/bin`
   - Python packages in `/data/packages/python/venv`
   - All packages persist across reboots

## Example Output

You'll see:
- List of system binaries (executables)
- List of Python packages (from venv)
- Total disk usage

## Additional Info

If user wants to see:
- **System packages only**: `ls -lh /data/packages/bin`
- **Python packages only**: `source /data/packages/python/venv/bin/activate && pip list`
- **Disk usage**: `du -sh /data/packages`
