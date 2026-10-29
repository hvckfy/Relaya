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

## Features

**Hosts**
- Add, edit, duplicate and delete hosts directly in `~/.ssh/config`.
- Every change is shown as a diff first and backed up to `config.bak`. Comments and directives Relaya doesn't manage are preserved.
- Groups and free-form tags, stored as a comment above the host (`# relaya: group=work tags=prod,db`) — ssh ignores it. Filter by tag, search across hosts.

**Passwords & keys**
- Passwords are saved in Keychain and typed in automatically when the server asks. They never appear in process arguments or environment variables.
- **"Set up key login" wizard**: after a password login, Relaya offers to generate an ed25519 key, shows every change up front, installs the key on the server, verifies a passwordless login — and only then updates your config.
- **Keys screen**: all key pairs in `~/.ssh` with fingerprints, agent status and the hosts using them. Deploy a key to several hosts at once, add keys to ssh-agent, store passphrases in Keychain (`UseKeychain`).

**Terminal**
- Tabs, host-key fingerprint check on first connect, a loud warning when a server's key changes.
- Auto-reconnect after a dropped connection, find in terminal (⌘F).
- Light/dark/system appearance, terminal color schemes, font settings.

**Files, tunnels, snippets**
- SFTP browser: navigate, download, upload (drag files from Finder), create folders, delete.
- Port forwarding: local (`-L`), remote (`-R`) and SOCKS (`-D`) tunnels with start/stop and auto-start.
- Snippets with `{{variables}}`: insert with ⇧⌘P or run on several hosts at once.

**Remote desktops**
- VNC opens in the built-in macOS Screen Sharing, RDP in Microsoft's free Windows App — optionally through an SSH tunnel.

**AI agents (MCP)**
- `Relaya --mcp` is a local MCP server for Claude, Cursor and other clients: `list_hosts`, `run_command`, `read_file`.
- Per-host access: off, read-only (safe commands only), confirm each command in a system dialog, or trusted. Every call is logged.
- Agents never see your keys — commands run through your own ssh.

**Server awareness**
- Detects the server OS (Ubuntu, Debian, OpenWrt, macOS…), shows its icon and offers OS-specific actions.

**Plain system ssh**
- Sessions run `/usr/bin/ssh`, so ProxyJump, ssh-agent, FIDO keys and every config option behave exactly like in Terminal.app.

## Installation

1. Download `Relaya-vX.Y.Z.zip` from [Releases](https://github.com/hvckfy/Relaya/releases/latest).
2. Unzip and move `Relaya.app` to `/Applications`.
3. Builds are not notarized yet, so remove the quarantine flag once:

```bash
xattr -dr com.apple.quarantine /Applications/Relaya.app
```

Requires macOS 14 Sonoma or later. Universal binary (Apple Silicon and Intel).

## Keyboard shortcuts

| Action | Shortcut |
|---|---|
| New host | ⇧⌘N |
| Connect to selected host | ⌘T or double-click |
| Close tab | ⌘W |
| Switch tab | ⌘1 … ⌘9 |
| Reconnect | ⌘R |
| Find in terminal | ⌘F |
| Snippets | ⇧⌘P |
| Reload `~/.ssh/config` | ⇧⌘R |
| Settings | ⌘, |

## Security model

- **Nothing is written without confirmation.** Config edits, new key files and server changes are previewed as a diff first.
- **Secrets stay in Keychain.** For non-interactive operations (e.g. installing a key on a server) ssh receives the secret through an askpass helper — Relaya itself, launched by ssh, reads it from Keychain on demand.
- **Known limitation:** `ssh-keygen` only accepts a new key's passphrase as an argument, so it is briefly visible in the process list while the key is generated.
- **Relaya never edits `sshd_config`.** The wizard shows the command to disable password login; you run it yourself when ready.

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

## Roadmap

- [x] **v0.1** — hosts, groups, tags, Keychain, key wizard, keys screen, themes
- [x] **v0.2** — SFTP browser, port forwarding, snippets
- [x] **v0.3** — VNC (via macOS Screen Sharing)
- [x] **v0.4** — RDP (via Windows App)
- [x] **v0.5** — local MCP server so AI agents can work with your servers safely
- [ ] Next — signed & notarized builds, Homebrew cask, built-in VNC/RDP viewer, Relaya Cloud

See [docs/UI_SPEC.md](docs/UI_SPEC.md) for the full UI specification (in Russian).

## Contributing

Issues and pull requests are welcome. Please keep the core idea intact: `~/.ssh` stays the source of truth, and every change to files or servers is shown before it is applied.

## License

[MIT](LICENSE) © 2026 hvckfy and Relaya contributors.

Relaya uses [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) (MIT).
