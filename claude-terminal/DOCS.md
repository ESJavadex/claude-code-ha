# Claude Terminal Pro

An enhanced terminal interface for Anthropic's Claude Code CLI in Home Assistant.

## About

Claude Terminal Pro is an enhanced fork of the original Claude Terminal add-on, providing a web-based terminal with Claude Code CLI pre-installed plus persistent package management capabilities. Access Claude's powerful AI capabilities directly from your Home Assistant dashboard with the added benefit of installing and persisting custom packages across restarts.

## Installation

You need a Claude subscription that includes Claude Code, or an Anthropic Console
account with API billing. Claude Code isn't included in the free Claude plan. See
[Claude Code account requirements](https://code.claude.com/docs/en/quickstart).

1. Add this repository to your Home Assistant add-on store:
   - Go to Settings → Add-ons → Add-on Store
   - Click the menu (⋮) and select Repositories
   - Add: `https://github.com/esjavadex/claude-code-ha`
2. Install the Claude Terminal Pro add-on
3. Start the add-on
4. Click "OPEN WEB UI" to access the terminal
5. On first use, follow the login prompts and sign in with your Claude plan or Anthropic Console account

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

### Files Sidebar
- The **🗂️ Files** button in the header (or the rail on the right edge) opens a sidebar with a tree of `/config`. Hide it with » and drag its left edge to resize it. Click a file to preview it and **Insert path** to type its path at the prompt
- **Recent changes** lists the files in `/config` changed in the last hour, day or week, so you can see what Claude edited
- **✓ Check HA configuration** runs Home Assistant's configuration check (`ha core check`) before you restart
- **± Changes** lists what changed in `/config` since the last checkpoint, with a coloured diff per file. **↩ Revert file** restores a file (two clicks) and **✓ Accept all changes** saves a new checkpoint. It uses git: if `/config` isn't a repository yet, the tab offers to create a local one (leaving out `secrets.yaml`, `.storage`, databases and logs). Nothing is pushed anywhere
- Files and Recent are read-only. Changes only writes when you click Revert, Accept or Start tracking. Everything is limited to `/config`

### Giving Claude Files
- Paste (Cmd/Ctrl+V), drag-and-drop onto the terminal, or **📎 Upload** to send images, PDFs, text, YAML, CSV, logs, code or any other file. Several at once work too. Each file is saved to `/data/uploads` and its path is typed at the prompt, ready for your question
- Names are kept, cleaned up for the prompt and given a time stamp, e.g. `/data/uploads/20261020-141233-automations.yaml`. Up to 50 MB per file
- Pasting a file copied in Finder or Explorer works in Safari and recent Chrome/Edge; drag-and-drop works in every browser. On an iPhone or iPad, use 📎 to pick from Photos or the Files app
- Claude is started with `--add-dir /data/uploads`, so it can read uploads without asking. If you start `claude` yourself from a shell, add that flag, or Claude asks before reading each one
- Uploads are left out of Home Assistant backups and removed after 30 days. Files you want to keep belong in `/config` or `/share`

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

### Keys for a Phone or Tablet

On a touch screen, a row of keys sits above the on-screen keyboard, for the
keys Claude Code uses that the keyboard doesn't have:

| Key | What it does in Claude Code |
|-----|-----------------------------|
| **Esc** | Stops Claude, or closes a menu |
| **↑ / ↓** | Moves through menu options and earlier prompts |
| **Tab** | Accepts Claude's suggested prompt, or completes a file name or command |
| **⇧Tab** | Switches mode (auto-accept edits, plan mode) |
| **^C** | Ctrl+C: clears what you've typed, or cancels. Two in a row would quit Claude, so after one tap the key shows *wait* for two seconds and ignores taps. To quit Claude, type `/exit` |
| **⇧↵** | Starts a new line in the prompt without sending it, like Shift+Enter |
| **↵** | Enter |

Tapping a key leaves the on-screen keyboard open. The row only appears when a
touch screen is the main pointer, so a laptop with a touch screen, or an iPad
with a trackpad, doesn't show it.

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

### Init Commands
- **Default**: `init_commands: []`
- Shell commands run once on every start, as root, after persistent packages are installed and before the terminal starts. Each runs in `/config`, and its output appears in the add-on log
- Each command gets 120 seconds. A command that never ends is stopped so the panel can start, so start services in the background and send their output to your own log:

```yaml
init_commands:
  - nohup /config/claude-bridge/start-bridge.sh > /config/claude-bridge/bridge.log 2>&1 &
  - git config --global user.name "Home Assistant"
```

- A failing command is logged as a warning and the add-on carries on
- Only the add-on configuration is used. Scripts in `/config` are never run automatically, because other add-ons can write there

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

After that, restarts will continue using the persistent version automatically.

## Usage

### Voice Input

Open **Voice Input** to dictate text, review and edit it, then **Copy Text**
or **Insert in Terminal**. Insertion never presses Enter, and strips control
characters and line breaks so a transcript cannot submit a shell command.

For Firefox, or a Companion app WebView without browser speech recognition,
configure a Home Assistant speech-to-text engine (for example Whisper) and set:

```yaml
voice_stt_provider: stt.faster_whisper
voice_language: de
```

Use your actual STT entity ID from **Settings → Devices & services → Entities**
(filter by the speech-to-text domain), and a language supported by that engine.
Legacy STT provider names are also accepted. An empty `voice_language` uses
your browser language; you can change the language in the dialog. The add-on
matches regional codes such as `de-DE` to `de` if the engine supports it.
It does not automatically choose or run an Assist conversation pipeline.

Microphone access requires **HTTPS** (or localhost) and browser/app permission.
In the Companion app, check both the app's OS microphone permission and the
WebView's permission prompt. Availability still depends on the app/WebView.
The add-on cannot enable microphone access that the browser or app blocks.

Each recording is limited to 60 seconds and kept in memory. Audio goes through
the Supervisor to the configured HA STT engine; neither audio nor transcripts
are written to add-on storage or logs. A cloud STT engine may send audio to its
own service under your HA configuration; choose a local engine to keep it local.
The Supervisor token is never sent to the browser. Close the dialog to cancel.

With `voice_stt_provider` empty, browsers supporting the Web Speech API use
their own speech service, which may be online. Firefox needs the HA option.
An invalid or unavailable configured HA provider never silently falls back to
the browser's speech service.
If transcription fails, check the configured entity and language, that its
engine supports 16 kHz mono PCM audio, and that Home Assistant is reachable.

Claude launches automatically when you open the terminal. You can also start Claude manually with:

```bash
node /usr/local/bin/claude
```

### Session Picker

The session picker is the menu for starting Claude and the tools around it.

- **`auto_launch_claude: true`** (the default): Claude starts as soon as you
  open the terminal, and the picker appears when you exit Claude (`/exit`, or
  Ctrl+C twice).
- **`auto_launch_claude: false`**: the picker is the first thing you see.

Whatever you start from the picker, you come back to it when that ends.

```text
Claude Code version: 2.1.316 (Claude Code)

Choose your Claude session type:

  1) 🆕 New interactive session (default)
  2) ⏩ Continue most recent conversation (-c)
  3) 📋 Resume from conversation list (-r)
  4) ⚙️ Custom Claude command (manual flags)
  5) 🔐 Claude authentication helper
  6) 🐙 GitHub CLI login (gh auth)
  7) 🔄 Update Claude Code (2.1.316, up to date)
  8) 🐚 Drop to bash shell
  9) ❌ Exit
```

| Option | What it does |
| --- | --- |
| 1 New interactive session | Starts `claude` in a new conversation. Pressing Enter on its own picks this. |
| 2 Continue most recent conversation | `claude -c`: reopens the latest conversation in the working directory with its full context |
| 3 Resume from conversation list | `claude -r`: lists earlier conversations to pick from |
| 4 Custom Claude command | Asks for your own arguments, e.g. `--model claude-sonnet-5-5` or `-p "summarise automations.yaml"` for a one-off answer. Empty input starts a new session. |
| 5 Claude authentication helper | Other ways to log in when pasting the code into the terminal doesn't work: type the code in, or read it from `/config/auth-code.txt`, which the helper deletes after use. |
| 6 GitHub CLI login | `gh auth login` by browser or personal access token, so Claude can use `gh` for issues and pull requests. The login is kept in `/data`. |
| 7 Update Claude Code | Installs the latest Claude Code into `/data/npm` and shows whether an update is available (checked at most once an hour). Only shown with `use_persistent_claude: true`; without it, the options below move up one number. |
| 8 Drop to bash shell | A plain shell in the working directory, for `ha`, `git`, `persist-install` and so on. `exit` returns to the menu. |
| 9 Exit | Closes the picker and ends the terminal session. Reload the panel to start a new one. |

Options 1 to 4 add the flags from your configuration: `enable_remote_control`,
`claude_extra_args` and `dangerously_skip_permissions`. Option 4 shows them
before it runs.

The terminal runs in a tmux session that outlives the browser tab. Closing the
tab, or opening the panel on another device, reattaches to the same running
session. You don't need option 2 for that.

For the `gh` token login, the picker suggests the `repo`, `read:org` and
`workflow` scopes. A fine-grained token limited to the repositories you want
Claude to work on is safer.

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

These folders are also mounted, read/write:

- `/addons`: local add-ons, for developing your own
- `/share`: the folder shared between add-ons and Home Assistant
- `/media`: the media folder

`/backup`, `/ssl` and `/addon_configs` are not mounted. Anyone who can open
this terminal can read and change everything it mounts (see
[Security](#security)). Those folders hold every backup, your TLS private keys
and other add-ons' state, such as Z-Wave network keys and Matter credentials.
Use Studio Code Server or the Samba share if you need them.

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
container, has read/write access to `/config`, `/addons`, `/share` and
`/media`, and can call the Supervisor and Home Assistant APIs.

**Any Home Assistant user can reach the terminal, not just administrators.**
`panel_admin: true` hides the sidebar entry from non-admins, but it does not
restrict the ingress URL behind it. That is how ingress works in Home Assistant
generally, not something this add-on can switch off: any signed-in user can get
an ingress session and the add-on's ingress URL (see
[core#60120](https://github.com/home-assistant/core/pull/60120)). Here that
means a non-admin account is one URL away from a root shell that can write
anywhere in those folders and drive the Supervisor API. Treat every account on
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
