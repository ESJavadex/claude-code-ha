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

### tmux Mouse Mode
- **Default**: `false`
- Keep disabled for reliable native browser copy/paste in the ttyd terminal, including OAuth codes
- Enable only if you prefer tmux mouse selection, scrolling, and pane controls

### Copying Text Out of the Terminal

There are four ways, and which ones you need depends on the device:

- **`🔗 Copy link`** appears in the header on its own whenever a link is on
  screen. One tap copies it, and the status line names the host it took. This is
  the quickest way to get an OAuth login URL out, on any device.
- **`📋 Copy`** opens the terminal's text in a box you can select from. On a
  phone this is the only way to copy arbitrary text: xterm.js has no touch
  support in its selection code and draws to a canvas, so a finger cannot select
  anything in the terminal itself. Long-press in the box for the native selection
  handles, or use **Copy all**. The switch chooses the visible screen or the
  whole scrollback.
- **Mouse selection** copies automatically on a computer. The scissors overlay
  (`✂`) appears only when the clipboard was actually written.
- **Claude Code's `/copy`** emits an OSC 52 escape sequence; tmux forwards it
  (`set-clipboard on`) and the browser writes it to the clipboard.

**Long links.** The terminal breaks a long URL across rows, and the add-on puts
it back together — including the case where the tail is re-indented, which would
otherwise leave spaces inside the link. If a link is cut off at the edge of the
screen it is refused rather than copied in half, and the status line says so;
scroll until all of it is visible.

**Plain HTTP.** Over `http://homeassistant.local:8123` browsers do not expose
`navigator.clipboard` at all — that API is restricted to secure contexts. The
add-on falls back to a hidden-textarea copy, which Chrome only permits while it
is handling a user gesture:

- Every **button** works, because your tap is the gesture. So does mouse
  selection, because releasing the button is one.
- **`/copy` does not.** It arrives from the terminal with no tap behind it, so
  the browser refuses it; the add-on says so and points at `📋`. Nothing the page
  can do changes this — it is the browser's security model, not a bug.
- Serving Home Assistant over HTTPS makes `/copy` work too.

### Scrolling on a Phone or Touch Screen

Swipe up and down over the terminal. A mouse wheel has always worked, but touch
did not: xterm.js ignores touch entirely while the program in the terminal has
taken over the mouse, which Claude Code does. Swipes are now translated into
wheel events, so they behave the same as a wheel.

Pinch-zoom and horizontal panning still belong to the browser, and putting a
second finger down stops the scroll — so a pinch is not read as a drag.

### Reading the Clipboard

**Reading** the clipboard *from* the terminal is deliberately not implemented:
OSC 52 read requests (`\e]52;c;?\a`) are swallowed rather than answered, so a
program in the terminal cannot exfiltrate your clipboard.

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
tmux_mouse: false
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

On ARMv7, use the final portable JavaScript release because current Claude Code
native releases do not publish ARM32 binaries:

```bash
NPM_CONFIG_PREFIX=/data/npm npm install -g @anthropic-ai/claude-code@1.0.128 --prefer-online
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
