# Claude Terminal Pro for Home Assistant

[![Version](https://img.shields.io/badge/version-2.0.13-1f6feb)](claude-terminal/CHANGELOG.md)
[![Latest release](https://img.shields.io/github/v/release/ESJavadex/claude-code-ha?label=release&color=1f6feb)](https://github.com/ESJavadex/claude-code-ha/releases)
[![License: MIT](https://img.shields.io/badge/license-MIT-3fb950)](LICENSE)
[![Architectures](https://img.shields.io/badge/arch-amd64%20%7C%20aarch64%20%7C%20armv7-8957e5)](#architecture-support)
[![Base image](https://img.shields.io/badge/base-Alpine%203.21-0db7ed)](claude-terminal/Dockerfile)

A Home Assistant add-on that runs Anthropic's **Claude Code CLI** in a browser-based terminal, right inside your dashboard. It ships the tools you actually need for HA work — the `ha` and `gh` CLIs, git, Python — keeps your session alive across restarts with tmux, and lets you install extra packages that survive reboots.

![Claude Terminal Screenshot](claude-terminal/screenshot.png)

> **Fork of** [heytcass/home-assistant-addons](https://github.com/heytcass/home-assistant-addons) by Tom Cassady, maintained by Javier Santos ([@esjavadex](https://github.com/esjavadex)). Same MIT license as the original.

---

## Install

[![Open your Home Assistant instance and show the add add-on repository dialog with a specific repository URL pre-filled.](https://my.home-assistant.io/badges/supervisor_add_addon_repository.svg)](https://my.home-assistant.io/redirect/supervisor_add_addon_repository/?repository_url=https%3A%2F%2Fgithub.com%2Fesjavadex%2Fclaude-code-ha)

Or add it manually:

1. **Settings → Add-ons → Add-on Store**
2. Top-right menu (⋮) → **Repositories**
3. Add `https://github.com/esjavadex/claude-code-ha` and click **Add**
4. Install **Claude Terminal Pro**, start it, and open the panel from the sidebar

Authentication uses OAuth — no API key or config needed for a normal setup. The terminal opens in your `/config` directory.

---

## Features

### Terminal & session
- **Web terminal** via ttyd, embedded in the HA sidebar (`code-braces-box` panel icon)
- **Auto-launch** Claude on open, or an interactive **session picker** (`auto_launch_claude`)
- **Persistent tmux session** — closing the browser tab or restarting Home Assistant Core does not kill your Claude session; reopening reattaches to the same one
- **Reliable browser copy/paste** — tmux mouse capture is **off by default** so pasting works (including OAuth login codes); re-enable with `tmux_mouse` if you prefer tmux mouse selection

### Bundled tooling
- **Claude Code CLI** — latest native release on amd64/aarch64
- **Home Assistant CLI** (`ha`) — talk to Supervisor and Core from the terminal
- **GitHub CLI** (`gh`) — with persistent auth
- **git, Python 3 + pip, Node.js, jq, yq, vim, nano, tree** and more, out of the box
- **Claude Code skills & commands** for Home Assistant pre-installed

### Persistence & packages
- **Everything in `/data`** survives reboots and add-on updates (auth, config, packages)
- **`persist-install`** — install APK/pip packages that stick across restarts, into an isolated Python venv
- **Auto-install** — declare packages in the config and they install on startup (`persistent_apk_packages`, `persistent_pip_packages`)
- **Optional persistent Claude override** — advanced users can pin/manage a Claude Code install in `/data/npm` (`use_persistent_claude`, `auto_update_claude_on_start`), validated with a version check before it is activated

### Extras
- **Image paste** — paste (Ctrl+V), drag-drop, or upload images for Claude to analyze (JPEG/PNG/GIF/WebP/SVG, ~10 MB), stored in `/data/images/`. Lightweight service (~10 MB RAM), ARM-compatible
- **Unrestricted mode** — optionally run Claude with `--dangerously-skip-permissions` for full file access (`dangerously_skip_permissions`)

---

## Configuration

| Option | Default | Description |
| --- | --- | --- |
| `auto_launch_claude` | `true` | Start Claude automatically, or show the session picker |
| `tmux_mouse` | `false` | Enable tmux mouse mode. Keep off for native browser copy/paste |
| `dangerously_skip_permissions` | `false` | Run Claude with unrestricted file access |
| `persistent_apk_packages` | `[]` | Alpine (APK) packages to auto-install on startup |
| `persistent_pip_packages` | `[]` | Python (pip) packages to auto-install on startup |
| `use_persistent_claude` | `false` | Use a Claude Code install kept in `/data/npm` instead of the baked-in one |
| `auto_update_claude_on_start` | `false` | When the override is enabled, update it on each start |

**Example:**

```yaml
auto_launch_claude: true
tmux_mouse: false
dangerously_skip_permissions: false
persistent_apk_packages:
  - htop
  - ripgrep
persistent_pip_packages:
  - httpx
```

See [DOCS.md](claude-terminal/DOCS.md) for the full guide.

---

## Quick start

```bash
# Ask Claude directly
claude "Write a Home Assistant automation that turns on the porch light at sunset"

# Interactive session
claude

# Install a package that survives restarts
persist-install ripgrep
persist-install --python httpx

# Use the bundled CLIs
ha core info
gh repo list
```

---

## Architecture support

| Architecture | Claude Code | Home Assistant CLI | GitHub CLI |
| --- | --- | --- | --- |
| `amd64` | native, latest | latest | latest |
| `aarch64` | native, latest | latest | latest |
| `armv7` | portable JS `1.0.128` ¹ | `4.46.0` ² | `armv6` build ³ |

¹ Current Claude Code native releases do not publish a 32-bit ARM binary, so armv7 uses the last portable JavaScript release.
² `4.46.0` is the last HA CLI release that still ships the `ha_armv7` asset (later releases dropped it).
³ GitHub CLI has no armv7 build; the armv6 binary runs on armv7 and is pinned to a version verified to publish it.

The target architecture is resolved from Home Assistant's `BUILD_ARCH` build argument, so the image builds correctly on each device without relying on BuildKit-specific variables.

---

## Recommended: Home Assistant plugins for Claude

Pair the add-on with the **[Claude Home Assistant Plugins](https://github.com/ESJavadex/claude-homeassistant-plugins)** for HA-specific tools and context (entity management, automation helpers, and more):

```bash
npx claude-plugins install @ESJavadex/claude-homeassistant-plugins/homeassistant-config
```

This drops a `CLAUDE.md` into your config directory with context tailored for Home Assistant development.

---

## Documentation

- [Add-on documentation](claude-terminal/DOCS.md) — options, usage, persistent packages
- [Development guide](DEVELOPMENT.md) — build and test the add-on locally
- [Changelog](claude-terminal/CHANGELOG.md) — release history

## Community tools

- **[ha-ws-client-go](https://github.com/schoolboyqueue/home-assistant-blueprints/tree/main/scripts/ha-ws-client-go)** by [@schoolboyqueue](https://github.com/schoolboyqueue) — lightweight Go CLI for the Home Assistant WebSocket API. Gives Claude direct access to entity states, service calls, automation traces, and real-time monitoring. Single binary, no dependencies.

## Support

Found a bug or have a request? [Open an issue](https://github.com/ESJavadex/claude-code-ha/issues).

## Credits

- **Original creator:** Tom Cassady ([@heytcass](https://github.com/heytcass)) — the initial Claude Terminal add-on
- **Fork maintainer:** Javier Santos ([@esjavadex](https://github.com/esjavadex)) — persistent packages, tmux persistence, multi-arch, and ongoing enhancements

Built and maintained with the help of Claude Code itself.

## License

MIT — see [LICENSE](LICENSE).

## About the author

Maintained by **Javier Santos** ([@ESJavadex](https://github.com/ESJavadex)) — AI consultant and founder of [Javadex](https://www.javadex.es/), where I help companies run private AI platforms. I also build [Cortex](https://www.javadex.es/plataforma), a self-hosted multi-model AI platform (the same "your AI, your data" philosophy as this add-on). More AI + Home Assistant content (in Spanish) on the [Javadex blog](https://www.javadex.es/blog).
