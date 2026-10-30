<p align="center"><img src="docs/icon.png" width="128" alt="Relaya icon"></p>

<h1 align="center">Relaya</h1>

<p align="center">
  A native macOS SSH client where your keys live in <code>~/.ssh</code> — not in our vault.
</p>

<p align="center">
  <a href="https://github.com/hvckfy/Relaya/releases/latest"><img src="https://img.shields.io/github/v/release/hvckfy/Relaya" alt="Latest release"></a>
  <a href="https://github.com/hvckfy/Relaya/actions/workflows/ci.yml"><img src="https://github.com/hvckfy/Relaya/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
  <img src="https://img.shields.io/badge/macOS-14%2B-blue" alt="macOS 14+">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-green" alt="MIT license"></a>
</p>

---

Relaya is a free, open source alternative to Termius-style SSH managers, built with SwiftUI. It has **no proprietary storage and no cloud sync**:

- your host list **is** your `~/.ssh/config`,
- your keys are plain files in `~/.ssh`,
- passwords and passphrases live in the macOS **Keychain**.

Everything you set up in Relaya keeps working from Terminal, VS Code, git, Ansible — anything that speaks SSH.

## Screenshots

<p align="center"><img src="docs/screenshots/tiles.jpg" width="860" alt="Terminals side by side as tiles over a shared background, Liquid Glass sidebar"></p>

| Host card | Keys |
|---|---|
| <img src="docs/screenshots/host.jpg" alt="Host card with live status, ports and connection details"> | <img src="docs/screenshots/keys.jpg" alt="Keys screen with fingerprints"> |
| **Snippets** | **Appearance** |
| <img src="docs/screenshots/snippets.jpg" alt="Snippets with variables"> | <img src="docs/screenshots/settings.jpg" alt="Appearance settings: window style, Liquid Glass, background image"> |

<sub>All hosts and keys above are fictional — screenshots are taken with `Relaya --demo`.</sub>

## Features

**Hosts**
- Add, edit, duplicate and delete hosts directly in `~/.ssh/config`. Every change is shown as a diff first and backed up to `config.bak`; comments and directives Relaya doesn't manage are preserved.
- Groups and free-form tags, stored as a comment above the host (`# relaya: group=work tags=prod,db`) — ssh ignores it.
- A Finder-style sidebar: Hosts, Remote Desktops and Tools sections with collapsible groups, search and a tag filter. Git-hosting entries (GitHub, GitLab, `User git`…) are kept out of the host list.
- A **Host** menu in the menu bar with every action for the selected host.

**Passwords & keys**
- Passwords live in Keychain and are typed in automatically when the server asks — after **Touch ID** (or your Mac password). They never appear in process arguments or environment variables.
- **"Set up key login" wizard**: generates an ed25519 key, installs it on the server (OpenWrt/Dropbear too), verifies a passwordless login and only then updates your config.
- **Keys screen**: every key pair in `~/.ssh` with fingerprints, agent status and the hosts using it.

**Terminal**
- Tabs, host-key fingerprint check on first connect, a loud warning when a server's key changes, auto-reconnect, find (⌘F), output highlighting.
- **Tiles**: drag a tab onto the edge of another terminal and it docks there; drag it to the edge of the window to span the full width or height. Splits are resizable and never overlap. SFTP tabs tile too. Each tile shows where it's connected.
- **Broadcast input**: type into several terminals at once (passwords and snippets are never broadcast).
- **tmux sessions**: reconnect straight back into the same session. Closing a tab ends it; after a dropped connection the server closes it by itself after an idle timeout (1 hour by default), so sessions never pile up. Turn tmux on or off in an open tab, keep a session running on purpose for 24 hours, see and clean up sessions in the host card.

**Files**
- SFTP browser with a transfer queue: progress, speed, cancel and retry. Uploads go to a temporary file first, so a broken transfer never corrupts the original.
- **Open in Editor**: edit a remote file in your default editor — every save is uploaded back.
- Drag & drop from Finder, rename, new folder, delete, keyboard shortcuts.

**Host card**
- Live status: load, memory, disk, uptime — in one of four styles (tiles, compact, pixel, console).
- **Docker**: containers with status and ports; logs, a shell inside, start/stop/restart.
- Port forwarding presets and OS-specific actions.
- Server OS detection with distro logos (Ubuntu, Debian, Proxmox VE, OpenWrt, Fedora, Arch, Alpine, Mint, Kali and more).

**Tunnels & snippets**
- Local (`-L`), remote (`-R`) and SOCKS (`-D`) tunnels with start/stop, auto-start and a menu bar icon.
- Snippets with `{{variables}}`: insert with ⇧⌘P or run on several hosts at once.

**Remote desktops**
- Built-in **VNC** and **RDP** (NLA) viewers in a tab or a separate window, optionally through an SSH tunnel; passwords in Keychain. RDP resolution adapts to the window on the fly.

**AI agents (MCP)**
- `Relaya --mcp` is a local MCP server for Claude, Cursor and other clients: `list_hosts`, `run_command`, `read_file`.
- Per-host access: off, read-only, confirm each command, or trusted. Confirmation is a **Touch ID** prompt showing the exact command. Agents never see your keys.

**Looks**
- Relaya themes or the native macOS style, **Liquid Glass** on macOS 26, light/dark/system.
- A background image shared by the whole workspace — tiles, terminals and panels show it through, with adjustable opacity.
- Terminal color schemes and fonts. English and Russian UI.

**Plain system ssh**
- Sessions run `/usr/bin/ssh`, so ProxyJump, ssh-agent, FIDO keys and every config option behave exactly like in Terminal.app.

## Installation

1. Download `Relaya-vX.Y.Z.zip` from [Releases](https://github.com/hvckfy/Relaya/releases/latest).
2. Unzip and move `Relaya.app` to `/Applications`.
3. Builds are signed with a persistent self-signed certificate (Keychain permissions survive updates) but not notarized, so remove the quarantine flag once:

```bash
xattr -dr com.apple.quarantine /Applications/Relaya.app
```

Requires macOS 14 Sonoma or later; Liquid Glass needs macOS 26. Universal binary (Apple Silicon and Intel).

## Keyboard shortcuts

| Action | Shortcut |
|---|---|
| New host | ⇧⌘N |
| Connect to selected host | ⌘T or double-click |
| Close tab | ⌘W |
| Switch tab | ⌘1 … ⌘9 |
| Reconnect | ⌘R |
| Find in terminal | ⌘F |
| Edit / duplicate host | ⌘E / ⌘D |
| Open files (SFTP) | ⇧⌘O |
| Snippets | ⇧⌘P |
| Reload `~/.ssh/config` | ⇧⌘R |
| Settings | ⌘, |

## Security model

- **Nothing is written without confirmation.** Config edits, new key files and server changes are previewed as a diff first.
- **Secrets stay in Keychain.** For non-interactive operations (e.g. installing a key on a server) ssh receives the secret through an askpass helper — Relaya itself, launched by ssh, reads it from Keychain on demand.
- **Known limitation:** `ssh-keygen` only accepts a new key's passphrase as an argument, so it is briefly visible in the process list while the key is generated.
- **Server changes only after confirmation.** Disabling password login, for example, asks first, shows the command and warns if the host has no key; OS actions are inserted into the terminal without Enter.
- **AI agents need your approval.** On hosts in "confirm" mode every command is shown in a Touch ID prompt.

## Building from source

```bash
git clone https://github.com/hvckfy/Relaya.git
cd Relaya
swift build
swift test
swift run Relaya
```

To produce a universal `.app` bundle:

```bash
scripts/bundle.sh 0.1.0
```

The result is `build/Relaya.app`. Releases are built by GitHub Actions on every `v*` tag.

See [docs/UI_SPEC.md](docs/UI_SPEC.md) for the full UI specification (in Russian).

## Contributing

Issues and pull requests are welcome. Please keep the core idea intact: `~/.ssh` stays the source of truth, and every change to files or servers is shown before it is applied.

## License

[MIT](LICENSE) © 2026 hvckfy and Relaya contributors.

Relaya uses [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm), [RoyalVNCKit](https://github.com/royalapplications/royalvnc) and [RDPKit](https://github.com/steelbrain/RDPKit) (MIT). Distro logos are from [Simple Icons](https://simpleicons.org) (CC0); they are trademarks of their owners.
