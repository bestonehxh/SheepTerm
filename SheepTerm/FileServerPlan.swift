import Darwin
import Foundation

/// The rules behind File ▸ File Server (status-bar TFTP server): which names a
/// device may read or write, when the server turns itself off, and the
/// device-side command for each family. Pure — no AppKit, no sockets — so the
/// harness runs the real rules (`Tests/tests/FileServerTests.swift`).
nonisolated enum FileServerPlan {
    /// One upload's ceiling, every server (was 256 MB; a show-tech or a
    /// core dump can pass 2 GB — the owner, 6.0 (2)). The disk reserve
    /// (`DownloadCap.reserve`) still applies below it.
    static let maximumUpload: Int64 = 16 * 1024 * 1024 * 1024

    /// What devices may send while Receive files is on, all uploads
    /// together: half the free space there was when it was switched on —
    /// past it Receive files turns itself off (security review 6.0 (2):
    /// each upload had a cap, their NUMBER had none). Scales with the disk.
    static func uploadBudget(freeWhenTurnedOn free: Int64) -> Int64 { max(0, free / 2) }

    /// How a server event counts. A refusal (failed, 0 bytes) never keeps
    /// the server awake — a scanner must not defeat the auto-off — and one
    /// never shown before stays off the bottom bar and the Transfer Log.
    /// But a row already shown as active that then fails with 0 bytes (TFTP's
    /// name-taken answer at the first block, a WRQ that never sends) ends
    /// like any transfer: skipping it left the bar up empty (review 6.0 (2)).
    static func counts(failed: Bool, done: Int64, shownBefore: Bool) -> (keepsAwake: Bool, accepted: Bool) {
        let refused = failed && done == 0
        return (!refused, !refused || shownBefore)
    }

    /// Free bytes on the volume of `folder`, or of its nearest existing
    /// parent (the backup folder is made at the first upload). Nil when
    /// nothing on the path can be measured.
    static func freeSpace(near folder: URL) -> Int64? {
        var url = folder.standardizedFileURL
        while true {
            var fs = statfs()
            if statfs(url.path, &fs) == 0 { return Int64(fs.f_bavail) * Int64(fs.f_bsize) }
            let parent = url.deletingLastPathComponent()
            if parent.path == url.path { return nil }
            url = parent
        }
    }

    /// Whether this event is the row's END (first non-active state): what
    /// the budget counts, so a repeated .done is never counted twice.
    static func finishesNow(previous: ServerTransfer.State?, incoming: ServerTransfer.State) -> Bool {
        incoming != .active && (previous == nil || previous == .active)
    }

    /// Whether switching Receive files on starts a fresh budget. Not when
    /// the login servers restart for a new user name / password: that turns
    /// writes off and on again, and used to hand devices a new 1,000 files
    /// and half the disk again (review 6.0 (4)).
    static func startsNewBudget(wasOn: Bool, isOn: Bool, restartingForLogin: Bool) -> Bool {
        isOn && !wasOn && !restartingForLogin
    }

    /// Files devices may leave while Receive files is on (the byte budget
    /// does not count empty ones): past it Receive files turns itself off.
    static let maximumUploadFiles = 1000

    /// True when the bytes received plus the ones in flight pass the budget.
    static func overUploadBudget(received: Int64, inFlight: Int64, budget: Int64) -> Bool {
        received + inFlight > budget
    }

    /// The bottom bar's transfer strip (5.0 (60)): what it says while files
    /// move. One transfer = its name; several = "N files", summed. `fraction`
    /// is nil while any size is unknown (TFTP without tsize).
    struct Strip: Equatable {
        var label: String
        var fraction: Double?
        /// "69%", nil when the size is unknown.
        var percent: String?
        /// "734 KB/1.1 MB", or just "734 KB" when the size is unknown.
        var size: String
        var detail: String { [percent, size].compactMap { $0 }.joined(separator: "  ") }
    }

    /// A popover row on hover. Running: "26% · 78.9 MB of 300 MB". Done:
    /// what moved against the file's size ("300 MB of 300 MB"; exact bytes
    /// read as clutter, the user, 6.0).
    /// Failed: the reason.
    static func rowDetail(_ t: ServerTransfer) -> String {
        let size = { (n: Int64) in ByteCountFormatter.string(fromByteCount: n, countStyle: .file) }
        switch t.state {
        case .failed:
            return t.detail.isEmpty ? String(localized: "failed") : t.detail
        case .done:
            if t.total > 0 { return String(localized: "\(size(t.done)) of \(size(t.total))") }
            return size(t.done)
        case .active:
            guard t.total > 0 else { return size(t.done) }
            let pct = min(100, Int(Double(t.done) / Double(t.total) * 100))
            return "\(pct)% · " + String(localized: "\(size(t.done)) of \(size(t.total))")
        }
    }

    static func strip(_ transfers: [ServerTransfer]) -> Strip? {
        let live = transfers.filter { $0.state == .active }
        guard !live.isEmpty else { return nil }
        let done = live.reduce(Int64(0)) { $0 + max(0, $1.done) }
        let known = live.allSatisfy { $0.total > 0 }
        let total = live.reduce(Int64(0)) { $0 + max(0, $1.total) }
        let label = live.count == 1 ? live[0].name : String(localized: "\(live.count) files")
        let size = { (n: Int64) in ByteCountFormatter.string(fromByteCount: n, countStyle: .file) }
        guard known, total > 0 else { return Strip(label: label, fraction: nil, percent: nil, size: size(done)) }
        let fraction = min(1, Double(done) / Double(total))
        return Strip(label: label, fraction: fraction, percent: "\(Int(fraction * 100))%",
                     size: "\(size(min(done, total)))/\(size(total))")
    }


    // MARK: Idle

    /// No transfer for this long and the server turns itself off. TFTP has no
    /// login: anyone on the segment can read what it serves, so it must not be
    /// left listening after the job (the owner's call, 2026-10-25).
    static let idleLimit: TimeInterval = 10 * 60

    /// True when the server has been quiet long enough to stop. A transfer in
    /// flight is never cut off, however long a slow device takes.
    static func shouldStop(lastActivity: Date, now: Date, transfersInFlight: Int) -> Bool {
        transfersInFlight == 0 && now.timeIntervalSince(lastActivity) >= idleLimit
    }

    // MARK: Names a device asks for

    /// A device READ resolves only to the one file the user picked — matched
    /// by its name, with or without a leading slash or directory the device
    /// puts in front (`/file`, `flash/file`). Nothing else on the Mac is
    /// reachable, so serving a firmware image from ~/Downloads never exposes
    /// the rest of ~/Downloads.
    static func readTarget(requested: String, served: URL?) -> URL? {
        guard let served else { return nil }
        let name = lastComponent(of: requested)
        guard !name.isEmpty, name == served.lastPathComponent else { return nil }
        return served
    }

    /// A device WRITE (a config backup) lands in `folder` under a plain file
    /// name: no directories, no dot-files, no control characters, and never
    /// over an existing file — a device must not be able to replace something
    /// already on the Mac. Nil = refuse the request.
    static func writeTarget(requested: String, folder: URL?, exists: (URL) -> Bool) -> URL? {
        guard let folder else { return nil }
        let name = lastComponent(of: requested)
        guard isPlainName(name) else { return nil }
        let target = folder.appendingPathComponent(name, isDirectory: false)
        guard target.deletingLastPathComponent().standardizedFileURL.path == folder.standardizedFileURL.path,
              !exists(target) else { return nil }
        return target
    }

    /// TFTP's answer to a name already in the folder: the next free
    /// `name-2.ext`, `name-3.ext`, … beside it. TFTP has no login, so a
    /// taken name and a free one must get the same answer — a refusal let
    /// anyone on the segment list the folder by asking (review 6.0 (2)) —
    /// and the device's re-run backup now succeeds, nothing replaced.
    /// `-2` … `-99` in order, then a random suffix: a folder an attacker
    /// filled with name-2 … name-N must not cost each request thousands of
    /// lookups on the server's one queue (review 6.0 (2)). Nil when the name
    /// would pass 255 bytes or nothing free turns up.
    static func freeVariant(of target: URL, exists: (URL) -> Bool,
                            random: () -> String = { String(UUID().uuidString.prefix(8)).lowercased() }) -> URL? {
        let folder = target.deletingLastPathComponent()
        let name = target.lastPathComponent
        let dot = name.lastIndex(of: ".").flatMap { $0 == name.startIndex ? nil : $0 }
        let stem = dot.map { String(name[..<$0]) } ?? name
        let ext = dot.map { String(name[$0...]) } ?? ""
        let suffixes = (2...99).map(String.init) + (0..<4).map { _ in random() }
        for suffix in suffixes {
            let candidate = "\(stem)-\(suffix)\(ext)"
            guard candidate.utf8.count <= 255 else { return nil }
            let url = folder.appendingPathComponent(candidate, isDirectory: false)
            if !exists(url) { return url }
        }
        return nil
    }

    /// The name after the last `/` or `\` (devices send both).
    static func lastComponent(of raw: String) -> String {
        let cut = raw.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "/" || $0 == "\\" })
        return String(cut.last ?? "")
    }

    static func isPlainName(_ name: String) -> Bool {
        guard !name.isEmpty, name.utf8.count <= 255, !name.hasPrefix("."),
              name != "..", !name.contains(":"), !InvisibleFormatting.found(in: name) else { return false }
        return !name.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F || (0x80...0x9F).contains($0.value) }
    }

    // MARK: This Mac's address, as the device sees it

    /// The local IPv4 the kernel would use to reach `host` (an IPv4 literal
    /// or a name — resolving one can block, so call this off main): a
    /// connected UDP socket picks the outgoing interface without sending a
    /// packet. This is the address that belongs in a device command; en0's
    /// is useless to a switch on another lab subnet or behind a VPN.
    static func ipv4(toReach host: String) -> String? {
        var hints = addrinfo(ai_flags: 0, ai_family: AF_INET, ai_socktype: SOCK_DGRAM,
                             ai_protocol: IPPROTO_UDP, ai_addrlen: 0, ai_canonname: nil,
                             ai_addr: nil, ai_next: nil)
        var result: UnsafeMutablePointer<addrinfo>?
        guard !host.isEmpty, getaddrinfo(host, "69", &hints, &result) == 0, let info = result else { return nil }
        defer { freeaddrinfo(result) }
        let sock = socket(AF_INET, SOCK_DGRAM, 0)
        guard sock >= 0 else { return nil }
        defer { close(sock) }
        guard connect(sock, info.pointee.ai_addr, info.pointee.ai_addrlen) == 0 else { return nil }
        var local = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let ok = withUnsafeMutablePointer(to: &local) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(sock, $0, &length) == 0 }
        }
        guard ok else { return nil }
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        var address = local.sin_addr
        guard inet_ntop(AF_INET, &address, &buffer, socklen_t(buffer.count)) != nil else { return nil }
        let ip = String(decoding: buffer.prefix { $0 != 0 }.map(UInt8.init(bitPattern:)), as: UTF8.self)
        return ip == "0.0.0.0" ? nil : ip
    }

    // MARK: Device commands

    struct Command: Equatable, Sendable {
        enum Kind: Sendable { case pull, backup }
        let kind: Kind
        let text: String
        /// Checked against the vendor's own documentation or a real device.
        /// Only these get the "type into the terminal" button; the rest can
        /// still be copied, so an unverified line is read before it is used.
        let verified: Bool
        /// The line as shown: a password the CLI insists on is masked. Such
        /// a line is never typed in (only copied) — what the app types must
        /// never carry a password into history, a session log or the screen.
        var display: String = ""
        var shown: String { display.isEmpty ? text : display }
        var carriesPassword: Bool { !display.isEmpty }
        init(kind: Kind, text: String, verified: Bool, display: String = "") {
            self.kind = kind
            self.text = text
            self.verified = verified && display.isEmpty
            self.display = display
        }
    }

    /// The protocols the File Server offers a device. SFTP and SCP share
    /// one SSH server.
    enum Proto: String, Sendable, CaseIterable, Identifiable {
        case tftp, sftp, scp, ftp
        var id: String { rawValue }
        var label: String { rawValue.uppercased() }
        var defaultPort: UInt16 {
            switch self {
            case .tftp: return 69
            case .sftp, .scp: return 22
            case .ftp: return 21
            }
        }
    }

    /// `host[:port]` for a URL (the protocol's default port is left out).
    static func authority(ip: String, port: UInt16, proto: Proto = .tftp) -> String {
        port == proto.defaultPort ? ip : "\(ip):\(port)"
    }

    /// File name for a config backup of `hostName`: the tab's name made safe
    /// for a file, or "config" when nothing usable is left.
    static func backupName(for hostName: String, suffix: String = ".cfg") -> String {
        let kept = hostName.unicodeScalars.map { scalar -> Character in
            let c = Character(scalar)
            return (c.isLetter || c.isNumber || c == "-" || c == "_" || c == ".") && scalar.isASCII ? c : "-"
        }
        var name = String(kept).trimmingCharacters(in: CharacterSet(charactersIn: "-."))
        if name.isEmpty { name = "config" }
        return String(name.prefix(64)) + suffix
    }

    /// A name that is safe inside every device CLI and URL here: no space,
    /// no shell or URL metacharacter (`;` `$` `#` `?` `%` …). Anything else
    /// is still shown — to copy and fix by hand — but never typed in.
    static func isCommandSafe(_ name: String) -> Bool {
        !name.isEmpty && name.unicodeScalars.allSatisfy {
            $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "._+-".unicodeScalars.contains($0))
        }
    }

    /// The commands a device of `vendor` runs to fetch `file` from this Mac
    /// over `proto`, and to push its configuration here. `.auto` has none —
    /// the popover asks for the family instead. A form that cannot carry a
    /// port is left out when the server is not on its standard port; a
    /// family with no CLI form for the protocol has none.
    static func commands(vendor: Vendor, proto: Proto = .tftp, ip: String, port: UInt16,
                         user: String = "", password: String = "",
                         file: String?, hostName: String) -> [Command] {
        let at = authority(ip: ip, port: port, proto: proto)
        let standard = port == proto.defaultPort
        let cfg = backupName(for: hostName)
        var out: [Command] = []
        let safeFile = file.map(isCommandSafe) ?? false
        func pull(_ text: String, verified: Bool = true) {
            guard file != nil else { return }
            out.append(Command(kind: .pull, text: text, verified: verified && safeFile))
        }
        func backup(_ text: String, verified: Bool = true) {
            out.append(Command(kind: .backup, text: text, verified: verified))
        }
        /// A form where the CLI takes the password inline: shown masked,
        /// copy-only (never typed in).
        let mask = String(repeating: "•", count: 6)
        func secretPull(_ text: (String) -> String) {
            guard file != nil else { return }
            out.append(Command(kind: .pull, text: text(password), verified: false, display: text(mask)))
        }
        func secretBackup(_ text: (String) -> String) {
            out.append(Command(kind: .backup, text: text(password), verified: false, display: text(mask)))
        }
        let f = file ?? ""
        let u = user
        switch (vendor, proto) {
        case (.auto, _), (.gaia, .tftp):
            break

        // Aruba CX: one URL form for every protocol (`copy <url> primary`).
        case (.arubaCX, .tftp):
            pull("copy tftp://\(at)/\(f) primary")
            backup("copy running-config tftp://\(at)/\(cfg) cli")
        case (.arubaCX, .sftp), (.arubaCX, .scp):
            let s = proto.rawValue
            pull("copy \(s)://\(u)@\(at)/\(f) primary")
            backup("copy running-config \(s)://\(u)@\(at)/\(cfg) cli")
        case (.arubaCX, .ftp):
            break

        // ArubaOS controller / MM: the partition is left for the user to
        // type — it must be the one the box is NOT booted from (`show boot`).
        case (.arubaOS, .tftp):
            if standard {
                pull("copy tftp: \(ip) \(f) system: partition ")
                backup("copy running-config tftp: \(ip) \(cfg)", verified: false)
            }
        case (.arubaOS, .scp):
            if standard { pull("copy scp: \(ip) \(u) \(f) system: partition ") }
        case (.arubaOS, .ftp):
            if standard { pull("copy ftp: \(ip) \(u) \(f) system: partition ", verified: false) }
        case (.arubaOS, .sftp):
            break

        case (.cisco, .tftp):
            pull("copy tftp://\(at)/\(f) flash:")
            backup("copy running-config tftp://\(at)/\(cfg)")
        case (.cisco, .scp), (.cisco, .sftp):
            let s = proto.rawValue
            pull("copy \(s)://\(u)@\(at)/\(f) flash:", verified: proto == .scp)
            backup("copy running-config \(s)://\(u)@\(at)/\(cfg)", verified: proto == .scp)
        case (.cisco, .ftp):
            secretPull { "copy ftp://\(u):\($0)@\(at)/\(f) flash:" }
            secretBackup { "copy running-config ftp://\(u):\($0)@\(at)/\(cfg)" }

        case (.huawei, .tftp):
            if standard {
                pull("tftp \(ip) get \(f)")
                backup("tftp \(ip) put vrpcfg.zip \(backupName(for: hostName, suffix: ".zip"))", verified: false)
            }
        case (.huawei, .scp):
            if standard { pull("scp \(u)@\(ip):\(f) flash:/\(f)", verified: false) }
        case (.huawei, _):
            break

        case (.comware, .tftp):
            if standard {
                pull("tftp \(ip) get \(f)")
                backup("tftp \(ip) put startup.cfg \(cfg)", verified: false)
            }
        case (.comware, .scp):
            if standard { pull("scp \(ip) get \(f)", verified: false) }
        case (.comware, _):
            break

        case (.juniper, .tftp):
            pull("file copy tftp://\(at)/\(f) /var/tmp/\(f)", verified: false)
            backup("file copy /config/juniper.conf.gz tftp://\(at)/\(backupName(for: hostName, suffix: ".conf.gz"))", verified: false)
        case (.juniper, .scp), (.juniper, .ftp):
            // Junos asks for the password itself.
            let s = proto.rawValue
            pull("file copy \(s)://\(u)@\(at)/\(f) /var/tmp/\(f)")
            backup("file copy /config/juniper.conf.gz \(s)://\(u)@\(at)/\(backupName(for: hostName, suffix: ".conf.gz"))")
        case (.juniper, .sftp):
            break

        case (.fortios, .tftp):
            if standard {
                pull("execute restore image tftp \(f) \(ip)")
                backup("execute backup config tftp \(cfg) \(ip)", verified: false)
            }
        case (.fortios, .ftp):
            if standard {
                secretPull { "execute restore image ftp \(f) \(ip) \(u) \($0)" }
                secretBackup { "execute backup config ftp \(cfg) \(ip) \(u) \($0)" }
            }
        case (.fortios, _):
            break

        case (.panos, .tftp):
            if standard {
                pull("tftp import software from \(ip) file \(f)")
                backup("tftp export configuration from running-config.xml to \(ip)")
            }
        case (.panos, .scp):
            let portArg = standard ? "" : " remote-port \(port)"
            pull("scp import software from \(u)@\(ip):\(f)\(portArg)")
            backup("scp export configuration from running-config.xml to \(u)@\(ip):\(cfg)\(portArg)")
        case (.panos, _):
            break

        case (.linux, .tftp):
            pull("curl -o \(shellQuoted(f)) tftp://\(at)/\(f)")
        case (.linux, .scp), (.gaia, .scp):
            let portArg = standard ? "" : "-P \(port) "
            pull("scp \(portArg)\(u)@\(ip):\(shellQuoted(f)) .")
        case (.linux, .sftp), (.gaia, .sftp):
            let portArg = standard ? "" : "-P \(port) "
            pull("sftp \(portArg)\(u)@\(ip):\(shellQuoted(f))")
        case (.linux, .ftp), (.gaia, .ftp):
            // curl asks for the password itself with `-u user`.
            pull("curl -u \(u) -o \(shellQuoted(f)) ftp://\(at)/\(f)")
        }
        return out
    }

    private static func shellQuoted(_ s: String) -> String {
        s.allSatisfy { $0.isLetter || $0.isNumber || "._-+".contains($0) } ? s
            : "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// The bare URL a device (or a person) uses when no CLI form is known.
    static func url(proto: Proto, ip: String, port: UInt16, user: String, file: String?) -> String {
        let at = authority(ip: ip, port: port, proto: proto)
        let who = proto == .tftp ? "" : "\(user)@"
        return "\(proto.rawValue)://\(who)\(at)/\(file ?? "")"
    }

    /// The bottom-bar glyph shows when its View switch is on, or — switched
    /// off — while a server runs, starts or its popover is open (opened from
    /// ＋ → File Server…); it goes away by itself when all of those end.
    static func showsGlyph(switchOn: Bool, running: Bool, starting: Bool, popoverOpen: Bool) -> Bool {
        switchOn || running || starting || popoverOpen
    }

    /// A hidden temp one of SheepTerm's own transfers writes beside its
    /// target: TFTP/FTP/SSH server uploads, TFTP/FTP/SFTP downloads.
    static func isOurTemp(_ name: String) -> Bool {
        guard name.hasPrefix(".") else { return false }
        return name.hasPrefix(".sheepterm-tftp-") || name.hasPrefix(".sheepterm-ftp-") || name.hasPrefix(".sheepterm-ssh-")
            || name.contains(".sheepterm-part-") || (name.contains(".sheepterm-") && name.hasSuffix(".part"))
    }

    /// Removes our temps from one folder (not below it). Quit only — while
    /// running, every transfer cleans up its own.
    static func sweepTemps(in folder: URL) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        for name in names where isOurTemp(name) {
            unlink(folder.appendingPathComponent(name).path)
        }
    }

    /// What tapping a protocol chip does (SFTP and SCP share one server).
    enum ChipAction: Equatable { case start, show, stop }
    static func chipAction(serverOn: Bool, shownProto: Proto?, tapped: Proto) -> ChipAction {
        guard serverOn else { return .start }
        return shownProto == tapped ? .stop : .show
    }

    // MARK: Login for SFTP / SCP / FTP

    static let serverUsername = "sheepterm"

    /// A fresh password per launch, never stored: what a device types once
    /// to pull a file. 12 characters from an alphabet every CLI accepts
    /// unquoted (no `@ : / ? # %`, no look-alikes).
    static func newPassword(using generator: inout some RandomNumberGenerator) -> String {
        let alphabet = Array("abcdefghjkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        return String((0..<12).map { _ in alphabet.randomElement(using: &generator)! })
    }

    /// Why a login typed by the user cannot be used, or nil. Both parts go
    /// into device commands and URLs, so both must be command-safe; the
    /// password needs 8+ characters.
    static func loginProblem(user: String, password: String) -> String? {
        guard isCommandSafe(user), user.count <= 32 else {
            return String(localized: "Username: letters, digits, . _ + - only")
        }
        guard password.count >= 8, password.count <= 64 else {
            return String(localized: "Password: 8 to 64 characters")
        }
        guard isCommandSafe(password) else {
            return String(localized: "Password: letters, digits, . _ + - only (it goes into device commands)")
        }
        return nil
    }

    /// Constant-time comparison for a login — no early exit on the first
    /// different byte or on a length mismatch.
    static func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        var diff: UInt8 = x.count == y.count ? 0 : 1
        for i in 0..<max(x.count, y.count) {
            diff |= (i < x.count ? x[i] : 0) ^ (i < y.count ? y[i] : 0)
        }
        return diff == 0
    }
}
