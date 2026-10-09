<p align="center">
  <img src=".github/icon.png?v=3" width="128" alt="SheepTerm app icon">
</p>

# 🐑 SheepTerm

**A native macOS terminal client built for network engineers — SSH, Serial, and local shell in one window.**

SheepTerm is written in SwiftUI + AppKit (Swift 6) with its own terminal emulator and its own
SSH implementation, and is designed around the daily workflow of configuring switches, routers, firewalls, and access
points: legacy-cipher SSH to old gear, serial consoles over USB adapters, device output
highlighted per vendor, hundreds of hosts organised by site and floor, and safe multi-line
config pasting.

## ⬇️ Download

[![Download SheepTerm for macOS](https://img.shields.io/badge/Download-SheepTerm_5.0_%288%29_for_macOS-2ea44f?style=for-the-badge&logo=apple&logoColor=white)](https://github.com/bestonehxh/SheepTerm/releases/latest)

**[Get the latest release →](https://github.com/bestonehxh/SheepTerm/releases/latest)** — download `SheepTerm-5.0-8.zip`, unzip, and drag **SheepTerm.app** into `Applications`.

> The build is unsigned (not notarized), so macOS will warn on first launch —
> right-click the app and choose **Open**, or run
> `xattr -dr com.apple.quarantine /Applications/SheepTerm.app`
>
> Requires macOS 26.4 (Tahoe) or later, Apple Silicon.

After the first install SheepTerm keeps itself up to date: it checks for a new release at launch
and once a day, and **SheepTerm → Check for Updates…** checks now. Each update is verified against
an Ed25519 signature before it is unpacked, and nothing is installed until you click
**Install & Relaunch**.

## The Sheep family 🐑

SheepTerm is one of a few small native macOS apps for network engineers:

|  | App | What it does |
|---|---|---|
| <img src="https://raw.githubusercontent.com/bestonehxh/SheepTerm/main/.github/icon.png?v=3" width="48" height="48" alt="SheepTerm"> | **[SheepTerm](https://github.com/bestonehxh/SheepTerm)**<br>[⬇️ Download](https://github.com/bestonehxh/SheepTerm/releases/latest) | SSH / Serial / local-shell terminal for network engineers |
| <img src="https://raw.githubusercontent.com/bestonehxh/SheepText/main/.github/icon.png?v=3" width="48" height="48" alt="SheepText"> | **[SheepText](https://github.com/bestonehxh/SheepText)**<br>[⬇️ Download](https://github.com/bestonehxh/SheepText/releases/latest) | Fast text editor with tree-sitter highlighting and a JavaScript plugin system |
| <img src="https://raw.githubusercontent.com/bestonehxh/SheepDrop/main/.github/icon.png?v=3" width="48" height="48" alt="SheepDrop"> | **[SheepDrop](https://github.com/bestonehxh/SheepDrop)**<br>[⬇️ Download](https://github.com/bestonehxh/SheepDrop/releases/latest) | SFTP / SCP / FTP / TFTP file transfer — client and built-in server |
| <img src="https://raw.githubusercontent.com/bestonehxh/SheepTap/main/.github/icon.png?v=3" width="48" height="48" alt="SheepTap"> | **[SheepTap](https://github.com/bestonehxh/SheepTap)**<br>[⬇️ Download](https://github.com/bestonehxh/SheepTap/releases/latest) | Menu-bar viewer for your Mac's network interfaces with click-to-copy |
| <img src="https://raw.githubusercontent.com/bestonehxh/SheepPing/main/.github/icon.png?v=3" width="48" height="48" alt="SheepPing"> | **[SheepPing](https://github.com/bestonehxh/SheepPing)**<br>[⬇️ Download](https://github.com/bestonehxh/SheepPing/releases/latest) | Continuous multi-host ping monitor with per-host logs and CSV export |

## The Lab family 🧪

The servers and hypervisor control a network lab needs, native on the Mac:

|  | App | What it does |
|---|---|---|
| <img src="https://raw.githubusercontent.com/bestonehxh/LabDC/main/.github/icon.png?v=2" width="48" height="48" alt="LabDC"> | **[LabDC](https://github.com/bestonehxh/LabDC)**<br>[⬇️ Download](https://github.com/bestonehxh/LabDC/releases/latest) | Active Directory–compatible domain controller with RADIUS for 802.1X and a lab CA |
| <img src="https://raw.githubusercontent.com/bestonehxh/LabDock/main/.github/icon.png?v=1" width="48" height="48" alt="LabDock"> | **[LabDock](https://github.com/bestonehxh/LabDock)**<br>[⬇️ Download](https://github.com/bestonehxh/LabDock/releases/latest) | VM control and console for standalone ESXi hosts — power, snapshots, guest files and scripts, no vCenter |

## Features

### Connections
- **SSH** via **SheepSSH**, SheepTerm's own SSH implementation — modern algorithms
  (including post-quantum `mlkem768x25519-sha256`) and, when a device needs them, the legacy
  ones old Cisco / Aruba / HPE gear still speaks (`diffie-hellman-group1-sha1`, `3des-cbc`,
  `ssh-dss`, `hmac-md5`), with automatic fallback; strict key exchange (Terrapin-safe); password,
  keyboard-interactive (TACACS / OTP), public-key and ssh-agent logins; SSH agent forwarding
- **Jump host (ProxyJump)** — reach a device through a bastion: pick a saved host or type
  `user@bastion[:port]` in Edit Host or Quick Connect (one hop)
- **Login inside the tab** — host key, username and password are asked on a card in the tab
  itself, not in a window-blocking dialog, so several tabs can connect at once
- **Serial console** over USB serial adapters (configurable baud rate), with **Send Break** (⌃⌥B)
- **Local shell** tabs alongside your remote sessions
- **Quick Connect (⌘K)** — type `admin@10.0.0.1`, `admin@sw01:2222`, or an IPv6 literal and go,
  or search your saved hosts by name, address, or section
- **Saved credentials** — pick a username + password once and reuse it on any number of hosts;
  set one credential for a whole group in one step
- **Tabs** — drag a tab to reorder it, or move the current one with ⌃⌘← / ⌃⌘→; a new local
  tab starts in your home folder
- **Split panes** — Split Right (⌘D) / Split Down (⇧⌘D), move focus with ⌥⌘ + arrows, zoom a
  pane (⇧⌘↩); drag a pane's header onto another pane, a tab, or the tab strip to rearrange, and
  drop a host from the sidebar beside an open pane
- **Tabs named from the prompt** — a session opened by bare IP or serial port takes the device's
  hostname from its prompt (`Core-SW (10.1.1.1)`), and its open log file is renamed to match
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
- **Auto-page** (View menu, off by default) answers `--More--` prompts for you; a host can also
  send the vendor's "disable paging" command right after an SSH login
- **Snippets** — saved commands and config blocks in the Snippets menu, with `{{variables}}`
  (and `{{name=default}}`) filled in a form before sending; **Broadcast to Tabs** (⇧⌘B) sends one
  to several connected sessions at once
- **Command history per host** (⌘Y) — commands read from the screen as you run them, so Tab
  completion and `?` help don't garble them; lines that look like passwords, keys or community
  strings are never kept
- **Find in scrollback** (⌘F, ⌘G / ⇧⌘G, ⌘E to use the selection), clear scrollback (⌘L)
- **Session logging** to `~/Documents/SheepTerm Logs/`, and **Search Logs** (⇧⌘F) across every
  saved log, plain text or regex
- 6 terminal themes: SheepTerm, Dracula, Nord, One Dark, Solarized Dark, Gruvbox Dark;
  terminal font and size adjustable (⌘= / ⌘−)
- Dark appearance throughout, with the sidebar and tab bar in **Liquid Glass** or a solid colour
- Full UTF-8 handling (Thai, CJK, emoji, box-drawing) — shortcuts keep working on
  non-Latin keyboard layouts

### Security
- Passwords are stored **only in the macOS Keychain** — never in config files,
  backups, or exports
- **First connection asks first** — a new host shows its key type and SHA256 fingerprint, and
  nothing is saved or sent until you choose Trust & Connect
- Host keys are pinned in `~/.ssh/known_hosts` (shared with OpenSSH); a changed key, a key of a
  different type or a revoked one is refused, and SheepTerm offers to open Known Hosts for that device
- **Known Hosts (File → Known Hosts…)** — search, inspect and remove saved host keys, including
  hashed entries; a backup is written before every change
- **Clipboard stays yours** — a remote program cannot set the Mac clipboard unless you allow it
  (Settings → Clipboard), and when allowed, pasting text it put there always asks first
- Imported `.sheepterm` files cannot turn on agent forwarding or change a host's cipher settings;
  session logs never keep terminal control codes
- SSH (SheepSSH) and the terminal emulator (SheepVT) are written in-house; cryptography comes
  from macOS itself — CryptoKit, CommonCrypto and Security — and is updated with the system

## Requirements

- macOS 26.4 (Tahoe) or later, Apple Silicon
- To build: Xcode 26+

## Building

```bash
xcodebuild -project SheepTerm.xcodeproj -scheme SheepTerm -configuration Release build
```

The app is built at
`~/Library/Developer/Xcode/DerivedData/SheepTerm-*/Build/Products/Release/SheepTerm.app`.
It links only Apple's frameworks and the three local packages in `Packages/` (SheepVT, SheepSSH,
SheepJump).

## License

[MIT](LICENSE) © 2026 bestonehxh
