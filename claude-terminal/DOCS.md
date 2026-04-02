# Claude Terminal Pro

An enhanced terminal interface for Anthropic's Claude Code CLI in Home Assistant.

## About

Claude Terminal Pro is an enhanced fork of the original Claude Terminal add-on, providing a web-based terminal with Claude Code CLI pre-installed plus persistent package management capabilities. Access Claude's powerful AI capabilities directly from your Home Assistant dashboard with the added benefit of installing and persisting custom packages across restarts.

## Installation

1. Add this repository to your Home Assistant add-on store:
   - Go to Settings → Add-ons → Add-on Store
   - Click the menu (⋮) and select Repositories
   - Add: `https://github.com/esjavadex/claude-code-ha`
2. Install the Claude Terminal Pro add-on
3. Start the add-on
4. Click "OPEN WEB UI" to access the terminal
5. On first use, follow the OAuth prompts to log in to your Anthropic account

## Configuration

The add-on offers several configuration options:

### Auto Launch Claude
- **Default**: `true`
- When enabled, Claude starts automatically when you open the terminal
- When disabled, shows an interactive session picker menu

### Dangerously Skip Permissions
- **Default**: `false`
- When enabled, Claude runs with `--dangerously-skip-permissions` flag
- **⚠️ WARNING**: This gives Claude unrestricted file system access
- Use only if you understand the security implications
- Useful for advanced users who need full file access

### Persistent Packages
- Configure APK and pip packages to auto-install on startup
- Packages are stored in `/data/packages` and survive restarts

### Optional Persistent Claude Code
- **Default**: `use_persistent_claude: false`
- When enabled, the add-on will look for a Claude Code install in `/data/npm/` and use it instead of the version baked into the image
- This is intended for advanced users who want a persistent override without changing the default supported behavior

### Optional Startup Updates
- **Default**: `auto_update_claude_on_start: false`
- Only relevant if `use_persistent_claude: true`
- When enabled, the add-on will update Claude Code in `/data/npm/` on each startup
- Safer default is to keep this off and update manually only when needed

**Example Configuration**:
```yaml
auto_launch_claude: false
dangerously_skip_permissions: true
persistent_apk_packages:
  - python3
  - git
persistent_pip_packages:
  - requests
use_persistent_claude: true
auto_update_claude_on_start: false
```

Your OAuth credentials are stored in the `/config/claude-config` directory and will persist across add-on updates and restarts, so you won't need to log in again.

If you enable `use_persistent_claude`, install the persistent Claude Code version once from a shell inside the add-on:

```bash
NPM_CONFIG_PREFIX=/data/npm npm install -g @anthropic-ai/claude-code@latest --prefer-online
```

After that, restarts will continue using the persistent version automatically.

## Usage

Claude launches automatically when you open the terminal. You can also start Claude manually with:

```bash
node /usr/local/bin/claude
```

### Common Commands

- `claude -i` - Start an interactive Claude session
- `claude --help` - See all available commands
- `claude "your prompt"` - Ask Claude a single question
- `claude process myfile.py` - Have Claude analyze a file
- `claude --editor` - Start an interactive editor session

The terminal starts directly in your `/config` directory, giving you immediate access to all your Home Assistant configuration files. This makes it easy to get help with your configuration, create automations, and troubleshoot issues.

## Features

### Core Features
- **Web Terminal**: Access a full terminal environment via your browser
- **Auto-Launching**: Claude starts automatically when you open the terminal
- **Claude AI**: Access Claude's AI capabilities for programming, troubleshooting and more
- **Direct Config Access**: Terminal starts in `/config` for immediate access to all Home Assistant files
- **Simple Setup**: Uses OAuth for easy authentication
- **Home Assistant Integration**: Access directly from your dashboard

### Enhanced Features (Pro)
- **Persistent Packages**: Install system (APK) and Python (pip) packages that survive restarts
- **Auto-Install Configuration**: Set packages to auto-install on startup
- **Simple Management**: Use `persist-install` command for easy package installation
- **Python Virtual Environment**: Isolated Python environment in `/data/packages`

## Troubleshooting

- If Claude doesn't start automatically, try running `node /usr/local/bin/claude -i` manually
- If you see permission errors, try restarting the add-on
- If you have authentication issues, try logging out and back in
- Check the add-on logs for any error messages

## Credits

**Original Creator:** Tom Cassady ([@heytcass](https://github.com/heytcass))
**Fork Maintainer:** Javier Santos ([@esjavadex](https://github.com/esjavadex))

This add-on was created and enhanced with the assistance of Claude Code itself! The development process, debugging, and documentation were all completed using Claude's AI capabilities - a perfect demonstration of what this add-on can help you accomplish.