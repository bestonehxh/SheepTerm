<p align="center">
  <img src=".github/icon.png?v=3" width="128" alt="SheepTerm app icon">
</p>

# 🐑 SheepTerm

**A native macOS terminal client built for network engineers — SSH, Serial, and local shell in one window.**

SheepTerm is written in SwiftUI + AppKit (Swift 6) with its own terminal emulator, and is
designed around the daily workflow of configuring switches, routers, firewalls, and access
points: legacy-cipher SSH to old gear, serial consoles over USB adapters, device output
highlighted per vendor, hundreds of hosts organised by site and floor, and safe multi-line
config pasting.

## ⬇️ Download

[![Download SheepTerm for macOS](https://img.shields.io/badge/Download-SheepTerm_4.1_%283%29_for_macOS-2ea44f?style=for-the-badge&logo=apple&logoColor=white)](https://github.com/bestonehxh/SheepTerm/releases/latest)

**[Get the latest release →](https://github.com/bestonehxh/SheepTerm/releases/latest)** — download `SheepTerm-4.1-3.zip`, unzip, and drag **SheepTerm.app** into `Applications`.

> The build is unsigned (not notarized), so macOS will warn on first launch —
> right-click the app and choose **Open**, or run
> `xattr -dr com.apple.quarantine /Applications/SheepTerm.app`
>
> Requires macOS 26.4 (Tahoe) or later, Apple Silicon.

## The Sheep family 🐑

SheepTerm is one of seven small native macOS apps that share the same sheep icon set:

|  | App | What it does |
|---|---|---|
| <img src="https://raw.githubusercontent.com/bestonehxh/SheepDrop/main/.github/icon.png?v=3" width="44" alt=""> | [SheepDrop](https://github.com/bestonehxh/SheepDrop) | SFTP / SCP / FTP / TFTP file transfer — client and built-in server |
| <img src="https://raw.githubusercontent.com/bestonehxh/SheepTerm/main/.github/icon.png?v=3" width="44" alt=""> | [SheepTerm](https://github.com/bestonehxh/SheepTerm) | SSH / Serial / local-shell terminal for network engineers |
| <img src="https://raw.githubusercontent.com/bestonehxh/SheepTap/main/.github/icon.png?v=3" width="44" alt=""> | [SheepTap](https://github.com/bestonehxh/SheepTap) | Menu-bar viewer for your Mac's network interfaces with click-to-copy |
| <img src="https://raw.githubusercontent.com/bestonehxh/SheepPing/main/.github/icon.png?v=3" width="44" alt=""> | [SheepPing](https://github.com/bestonehxh/SheepPing) | Continuous multi-host ping monitor with per-host logs and CSV export |
| <img src="https://raw.githubusercontent.com/bestonehxh/SheepText/main/.github/icon.png?v=3" width="44" alt=""> | [SheepText](https://github.com/bestonehxh/SheepText) | Fast text editor with tree-sitter highlighting and a JavaScript plugin system |
| <img src="https://raw.githubusercontent.com/bestonehxh/SheepArt/main/.github/icon.png?v=3" width="44" alt=""> | [SheepArt](https://github.com/bestonehxh/SheepArt) | Screenshot annotation — draw, crop, layers, one-key background removal |
| <img src="https://raw.githubusercontent.com/bestonehxh/SheepRadius/main/.github/icon.png?v=4" width="44" alt=""> | [SheepRadius](https://github.com/bestonehxh/SheepRadius) | RADIUS + LDAP lab for 802.1X, device logins and NAC — with a joinable Samba AD |

## Features

### Connections
- **SSH** via bundled libssh 0.12 — works with both modern ciphers and the legacy
  algorithms old Cisco / Aruba / HPE gear still speaks; SSH agent forwarding supported
- **Serial console** over USB serial adapters (configurable baud rate)
- **Local shell** tabs alongside your remote sessions
- **Quick Connect (⌘K)** — type `admin@10.0.0.1`, `admin@sw01:2222`, or an IPv6 literal and go,
  or search your saved hosts by name, address, or section
- **Saved credentials** — pick a username + password once and reuse it on any number of hosts;
  set one credential for a whole group in one step
- Ask-before-quit when live SSH/serial sessions would be lost (local shells don't nag)

### Host management
- Sidebar with **host groups**, search, and recent connections
- **Sections inside a group** — sub-headings such as a building floor, a rack, or a role.
  A group owns its sections in the order you choose; hosts can sit loose in the group or under a
  section; a section can stay empty until you need it
- **Drag and drop** — hosts, whole groups, and section headings. Select several hosts with ⌘ or ⇧
  and move them in one drag; drag a section to reorder it, or drop it on another group to move it
  with all its hosts (a section with the same name there is merged)
- **Add Hosts** — a table (Name · Host / IP · Credential · Section) that takes a ⌘V straight from
  Excel, Numbers, or a CSV file, or **Import CSV…** (UTF-8 or UTF-16). Pasting behaves like a
  spreadsheet: empty cells stay empty, a block spreads down from the cell you pasted into, and a
  header row must use the table's own column names or the paste is refused with a warning
- **Import / Export groups** as `.sheepterm` files to share with teammates —
  credentials are always stripped from exported files by design
- **Backup / Restore** the whole configuration as a single `.sheeptermbackup` file —
  passwords are never written to the file; they live only in the macOS Keychain
- Careful merge-on-import: no silent overwrites, per-host conflict resolution

### Terminal
- **Own terminal emulator** rendered with Metal — 10,000 lines of scrollback by default
- **Syntax highlighting for network device output**, one built-in pack per device family:
  Cisco IOS / IOS-XE / NX-OS, Aruba CX, ArubaOS, Huawei VRP, H3C / HPE Comware, Juniper Junos,
  Palo Alto PAN-OS, Fortinet FortiOS, Check Point Gaia, and Linux. The family is set per host,
  switched live from the View menu or the status bar, or detected automatically from the device
  output. Highlighting is painted on screen only — the text itself is untouched, so copy and
  session logs stay clean, and colours the device sends itself are never overridden (⇧⌘H toggles it)
- **Safe Multi-line Paste** — pasting 2+ lines into an SSH/serial session shows a
  read-only preview first, with the option to send line-by-line at a chosen pacing
  delay (great for config blocks on slow control planes)
- **Find in scrollback** (⌘F, ⌘G / ⇧⌘G, ⌘E to use the selection), clear scrollback (⌘L)
- **Session logging** to `~/Documents/SheepTerm Logs/`
- 6 terminal themes: SheepTerm, Dracula, Nord, One Dark, Solarized Dark, Gruvbox Dark;
  terminal font and size adjustable (⌘= / ⌘−)
- Dark appearance throughout, with the sidebar and tab bar in **Liquid Glass** or a solid colour
- Full UTF-8 handling (Thai, CJK, emoji, box-drawing) — shortcuts keep working on
  non-Latin keyboard layouts

### Security
- Passwords are stored **only in the macOS Keychain** — never in config files,
  backups, or exports

## Requirements

- macOS 26.4 (Tahoe) or later, Apple Silicon
- To build: Xcode 26+ and Homebrew `libssh` (which brings `openssl@3`)

## Building

```bash
brew install libssh
xcodebuild -project SheepTerm.xcodeproj -scheme SheepTerm -configuration Release build
```

The app is built at
`~/Library/Developer/Xcode/DerivedData/SheepTerm-*/Build/Products/Release/SheepTerm.app`.
The build copies libssh and OpenSSL's libcrypto into the app bundle, so the result runs on a Mac
without Homebrew.

## Acknowledgements

- [libssh](https://www.libssh.org) (LGPL-2.1) — SSH transport, bundled as a dynamic library
- [OpenSSL](https://www.openssl.org) (Apache-2.0) — `libcrypto`, bundled as a dynamic library for libssh

## License

[MIT](LICENSE) © 2026 bestonehxh
