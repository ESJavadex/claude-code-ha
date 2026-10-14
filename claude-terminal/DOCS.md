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

### Working Directory
- **Default**: empty (starts in `/config`)
- The folder the terminal and Claude start in, e.g. `/config/my_repo`
- Claude asks its one-time "do you trust this folder?" question the first time
  it sees a new directory, then remembers the answer
- A path that doesn't exist logs a warning and falls back to `/config`

### Claude Code OAuth Token
- **Default**: empty (log in through the browser as usual)
- A long-lived token from `claude setup-token` (run it on any machine where
  you're logged in), for setups where the browser login is impractical
- Masked in the Home Assistant UI and never written to the log, but like every
  add-on option it is stored in the add-on configuration, which is included in
  Home Assistant backups
- Can't be used for Remote Control (below), which needs the normal login

### Dangerously Skip Permissions
- **Default**: `false`
- When enabled, Claude runs with `--dangerously-skip-permissions` flag
- **⚠️ WARNING**: This gives Claude unrestricted file system access, and
  removes the last human checkpoint: a misunderstanding, or a prompt injection
  in any file or web page Claude reads, can change your configuration without
  asking you first
- Use only if you understand the security implications (see [Security](#security))
- Useful for advanced users who need full file access

### Enable Remote Control
- **Default**: `false`
- Launches Claude with `--remote-control`, so the same session also appears as
  "Home Assistant" in the Claude mobile app and at
  [claude.ai/code](https://claude.ai/code), where you can drive it from another
  device. The browser terminal keeps working as usual: it's one session
- Applies to every Claude launch, including those from the session picker
- Needs a normal claude.ai login (Pro/Max/Team/Enterprise), not
  `claude_code_oauth_token` or an API key. Claude asks a one-time
  "Enable Remote Control?" question per directory
- **⚠️ With Dangerously Skip Permissions on**, any device signed in to your
  Claude account can drive a root shell that runs tools without asking

### Claude Extra Args
- **Default**: empty
- Extra flags added to every Claude launch, e.g. `--model claude-sonnet-5-5`
- Parsed like a shell command line, so quoting works:
  `--append-system-prompt 'be terse'` arrives as one argument

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
- Installed automatically on the next start if `/data/npm` is empty. It is left out of Home Assistant backups (about 240 MB) and reinstalled after a restore

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

If you enable `use_persistent_claude`, the add-on installs Claude Code into `/data/npm` on the next start if nothing is there yet. `/data/npm` is left out of Home Assistant backups, so after a restore it is installed again the same way. To install or reinstall it by hand from a shell inside the add-on:

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

### Logging In

The first time Claude starts it shows a login link. There are two ways to
open it:

- **Home Assistant notification**: the add-on posts the link as a "Claude Code
  login" notification as soon as it appears, including in the Companion app.
  Tap it to sign in. The notification disappears by itself once login
  succeeds, and a stale one left over from before a restart is cleared on
  startup.
- **`🔗 Copy link`** in the terminal header (see below).

Either way, the browser then shows an **authorization code**: paste it into
the terminal at Claude's prompt. That step can't be automated, because Claude
receives the code through a callback inside the container, which your browser
can't reach.

Notifications are visible to every Home Assistant user, not only admins. The
link alone can't log anyone in, since the code still has to be pasted into
your terminal. No link is posted when you use `claude_code_oauth_token`.

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

### Typing Lags or Pauses for a Few Seconds, Then Catches Up

This has been traced to Home Assistant's own ingress layer (not this add-on):
requests to the terminal panel are proxied through Home Assistant's ingress
reverse proxy and appear to pass through the frontend's service worker
(Workbox), which can occasionally add several seconds of latency without
dropping the underlying WebSocket connection - the input just queues and then
flushes all at once.

Both ports are closed by default. To try bypassing ingress, open the add-on's
**Configuration** tab, set a host port under **Network** for 7680 (this add-on's
own web UI, still proxied to ttyd, with image paste) or 7681 (ttyd directly),
then restart the add-on and open `http://<home-assistant-host>:<port>/`. If
the lag disappears, it confirms the ingress layer rather than anything in this
add-on. **Read [Security](#security) first**: neither port has a login.

## Security

**This add-on gives Claude a lot of power by design**: it runs as root in its
container, has read/write access to `/config`, and can call the Supervisor and
Home Assistant APIs.

**Any Home Assistant user can reach the terminal, not just administrators.**
`panel_admin: true` hides the sidebar entry from non-admins, but it does not
restrict the ingress URL behind it. That is how ingress works in Home Assistant
generally, not something this add-on can switch off: any signed-in user can get
an ingress session and the add-on's ingress URL (see
[core#60120](https://github.com/home-assistant/core/pull/60120)). Here that
means a non-admin account is one URL away from a root shell that can write
anywhere in `/config` and drive the Supervisor API. Treat every account on
your instance as trusted while this add-on is installed.

**Publishing port 7680 or 7681 exposes an unauthenticated root shell.** Both
ports are closed by default and ingress needs neither. If you map one to your
host, anyone who can reach that port on your network gets the same shell with
no Home Assistant account involved at all. Leave them unset unless the port is
firewalled off and you accept that. While a port is unpublished, the add-on
also refuses connections to it from other add-ons on Home Assistant's internal
network.

## Credits

**Original Creator:** Tom Cassady ([@heytcass](https://github.com/heytcass))
**Fork Maintainer:** Javier Santos ([@esjavadex](https://github.com/esjavadex))

This add-on was created and enhanced with the assistance of Claude Code itself! The development process, debugging, and documentation were all completed using Claude's AI capabilities - a perfect demonstration of what this add-on can help you accomplish.
