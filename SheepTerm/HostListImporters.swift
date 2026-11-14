import Foundation

/// Add Hosts ▸ Import from another terminal (6.1 (17), Design/workspaces/
/// PLAN.md round 4): the session list another app exports, read straight
/// into `HostListCodec.Entry` rows — no separate converter, nothing written.
/// The rows then go through the paste parser like any import, so nothing is
/// saved until the user presses Add. Pure text in, entries out; the harness
/// checks each reader against a sample of the real file.
///
/// Never a secret: a password or key a file may carry is not read.
nonisolated enum HostListImporters {
    enum Source: String, CaseIterable, Sendable {
        case putty, secureCRT, mobaXterm, hostsFile
        var label: String {
            switch self {
            case .putty: "PuTTY"
            case .secureCRT: "SecureCRT"
            case .mobaXterm: "MobaXterm"
            case .hostsFile: "hosts file"
            }
        }
    }

    /// Which app wrote `text`, from what is in it (never the file name);
    /// nil = none of these (the CSV / JSON / ssh config path decides).
    static func detect(_ text: String) -> Source? {
        let head = String(text.prefix(4096))
        if head.contains("SimonTatham\\PuTTY\\Sessions") { return .putty }
        if head.contains("<VanDyke") { return .secureCRT }
        if head.range(of: #"(?m)^\[Bookmarks(_\d+)?\]"#, options: .regularExpression) != nil,
           text.range(of: #"=\s*#\d+#\d+%"#, options: .regularExpression) != nil { return .mobaXterm }
        if isHostsFile(text) { return .hostsFile }
        return nil
    }

    /// The entries of a file `detect` named.
    static func entries(_ text: String, as source: Source) -> [HostListCodec.Entry] {
        switch source {
        case .putty: return putty(text)
        case .secureCRT: return secureCRT(text)
        case .mobaXterm: return mobaXterm(text)
        case .hostsFile: return hostsFile(text)
        }
    }

    // MARK: PuTTY — a .reg export of HKCU\Software\SimonTatham\PuTTY\Sessions

    /// One entry per `[…\Sessions\<name>]` key with a HostName; the session
    /// name is URL-escaped (`%20`); "Default Settings" is PuTTY's template,
    /// not a host. Protocol ssh / telnet / serial (raw and rlogin are skipped:
    /// nothing here opens them).
    static func putty(_ text: String) -> [HostListCodec.Entry] {
        var out: [HostListCodec.Entry] = []
        var name: String?
        var values: [String: String] = [:]
        func flush() {
            defer { name = nil; values = [:] }
            guard let name, name != "Default Settings" else { return }
            let proto = (values["protocol"] ?? "ssh").lowercased()
            let type: String
            switch proto {
            case "ssh": type = "ssh"
            case "telnet": type = "telnet"
            case "serial": type = "serial"
            default: return
            }
            let address = proto == "serial" ? (values["serialline"] ?? "") : (values["hostname"] ?? "")
            guard !address.isEmpty else { return }
            var entry = HostListCodec.Entry(name: name, address: address, type: type)
            if proto != "serial", let port = values["portnumber"].flatMap(dword), (1...65535).contains(port) { entry.port = port }
            else if proto == "telnet" { entry.port = 23 }
            entry.user = values["username"] ?? ""
            out.append(entry)
        }
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") && line.hasSuffix("]") {
                flush()
                let key = String(line.dropFirst().dropLast())
                if let range = key.range(of: "\\Sessions\\", options: .caseInsensitive) {
                    let session = String(key[range.upperBound...])
                    if !session.isEmpty, !session.contains("\\") { name = session.removingPercentEncoding ?? session }
                }
                continue
            }
            // Searched from the second character: a line `"=1` has its `"=` AT the
            // start, and the key's range would run backwards (a trap).
            guard name != nil, line.hasPrefix("\""), let eq = line.range(of: "\"=", range: line.index(after: line.startIndex)..<line.endIndex) else { continue }
            let key = String(line[line.index(after: line.startIndex)..<eq.lowerBound]).lowercased()
            var value = String(line[eq.upperBound...])
            if value.hasPrefix("\"") && value.hasSuffix("\"") && value.count >= 2 {
                value = String(value.dropFirst().dropLast()).replacingOccurrences(of: "\\\\", with: "\\").replacingOccurrences(of: "\\\"", with: "\"")
            }
            values[key] = value
        }
        flush()
        return out
    }

    /// `dword:00000016` → 22.
    private static func dword(_ value: String) -> Int? {
        guard value.lowercased().hasPrefix("dword:") else { return Int(value) }
        return Int(value.dropFirst("dword:".count), radix: 16)
    }

    // MARK: SecureCRT — File ▸ Export Settings (XML)

    /// `<key name="Sessions">` and below: a key with a Hostname string is a
    /// session; the keys around it are its folders (the group path).
    /// "Protocol Name" SSH2 / SSH1 / Telnet / Serial.
    static func secureCRT(_ text: String) -> [HostListCodec.Entry] {
        guard let data = text.data(using: .utf8) else { return [] }
        let reader = SecureCRTReader()
        let parser = XMLParser(data: data)
        parser.delegate = reader
        parser.shouldResolveExternalEntities = false
        parser.parse()
        return reader.entries
    }

    private final class SecureCRTReader: NSObject, XMLParserDelegate {
        var entries: [HostListCodec.Entry] = []
        /// The key names from the root down; a frame per open key.
        private var stack: [(name: String, values: [String: String])] = []
        private var field: String?
        private var buffer = ""

        func parser(_ parser: XMLParser, didStartElement element: String, namespaceURI: String?,
                    qualifiedName: String?, attributes: [String: String] = [:]) {
            switch element {
            case "key": stack.append((attributes["name"] ?? "", [:]))
            case "string", "dword": field = attributes["name"]; buffer = ""
            default: break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) { if field != nil { buffer += string } }

        func parser(_ parser: XMLParser, didEndElement element: String, namespaceURI: String?, qualifiedName: String?) {
            switch element {
            case "string", "dword":
                if let field, !stack.isEmpty { stack[stack.count - 1].values[field.lowercased()] = buffer.trimmingCharacters(in: .whitespacesAndNewlines) }
                field = nil
            case "key":
                guard let frame = stack.popLast() else { return }
                guard let sessions = stack.firstIndex(where: { $0.name == "Sessions" }) else { return }
                let values = frame.values
                let proto = (values["protocol name"] ?? "SSH2").lowercased()
                let type: String
                switch proto {
                case "ssh2", "ssh1", "ssh": type = "ssh"
                case "telnet": type = "telnet"
                case "serial": type = "serial"
                default: return
                }
                let address = type == "serial" ? (values["com port"] ?? "") : (values["hostname"] ?? "")
                guard !address.isEmpty else { return }
                var entry = HostListCodec.Entry(name: frame.name, address: address, type: type)
                let portKey = type == "telnet" ? "port" : "[ssh2] port"
                if let port = (values[portKey] ?? values["port"]).flatMap({ Int($0) }), (1...65535).contains(port) { entry.port = port }
                else if type == "telnet" { entry.port = 23 }
                entry.user = values["username"] ?? ""
                entry.group = stack[(sessions + 1)...].map(\.name).joined(separator: "/")
                entries.append(entry)
            default: break
            }
        }
    }

    // MARK: MobaXterm — a .mxtsessions export (INI)

    /// `[Bookmarks]` / `[Bookmarks_N]` sections; `SubRep=` is the folder
    /// path (backslashes); each other `name=` line is a session whose value
    /// is `#<icon>#<type>%host%port%user%…`. Type 0 SSH, 1 Telnet, 8 Serial
    /// (its "host" is the COM port); the rest are skipped.
    static func mobaXterm(_ text: String) -> [HostListCodec.Entry] {
        var out: [HostListCodec.Entry] = []
        var folder = ""
        var inBookmarks = false
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") && line.hasSuffix("]") {
                inBookmarks = line.range(of: #"^\[Bookmarks(_\d+)?\]$"#, options: .regularExpression) != nil
                folder = ""
                continue
            }
            guard inBookmarks, let eq = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<eq]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            if key == "SubRep" { folder = value.replacingOccurrences(of: "\\", with: "/"); continue }
            guard key != "ImgNum", value.hasPrefix("#") else { continue }
            let parts = value.components(separatedBy: "%")
            let head = parts[0].split(separator: "#")
            guard head.count >= 2, let kind = Int(head[1]), parts.count >= 2 else { continue }
            let type: String
            switch kind {
            case 0: type = "ssh"
            case 1: type = "telnet"
            case 8: type = "serial"
            default: continue
            }
            let address = parts[1].trimmingCharacters(in: .whitespaces)
            guard !address.isEmpty else { continue }
            var entry = HostListCodec.Entry(name: key, address: address, type: type, group: folder)
            if type != "serial", parts.count > 2, let port = Int(parts[2]), (1...65535).contains(port) { entry.port = port }
            else if type == "telnet" { entry.port = 23 }
            if type == "ssh", parts.count > 3 { entry.user = parts[3].trimmingCharacters(in: .whitespaces) }
            out.append(entry)
        }
        return out
    }

    // MARK: A hosts file (/etc/hosts) or a plain list of addresses

    /// Every line (comments and blanks aside) starts with an IPv4 / IPv6
    /// address, and at least one line has a name after it — a bare list of
    /// addresses is already a one-column table and goes that way.
    static func isHostsFile(_ text: String) -> Bool {
        let lines = meaningfulLines(text)
        guard !lines.isEmpty else { return false }
        var named = false
        for line in lines {
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard let first = fields.first, isIPAddress(String(first)) else { return false }
            if fields.count > 1 { named = true }
        }
        return named
    }

    /// One entry per address line: the first name is the host's name, the
    /// address its address. Loopback, link-local multicast and broadcast
    /// lines (`localhost`, `ip6-allnodes` …) are not hosts anyone connects to.
    static func hostsFile(_ text: String) -> [HostListCodec.Entry] {
        meaningfulLines(text).compactMap { line in
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard let address = fields.first, isIPAddress(address), !isSystemAddress(address) else { return nil }
            return HostListCodec.Entry(name: fields.count > 1 ? fields[1] : address, address: address)
        }
    }

    private static func meaningfulLines(_ text: String) -> [String] {
        text.split(whereSeparator: \.isNewline).compactMap { raw in
            let line = (raw.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? "")
                .trimmingCharacters(in: .whitespaces)
            return line.isEmpty ? nil : line
        }
    }

    static func isIPAddress(_ s: String) -> Bool {
        var v4 = in_addr(), v6 = in6_addr()
        return inet_pton(AF_INET, s, &v4) == 1 || inet_pton(AF_INET6, s, &v6) == 1
    }

    private static func isSystemAddress(_ s: String) -> Bool {
        s.hasPrefix("127.") || s == "::1" || s == "255.255.255.255" || s == "0.0.0.0" || s.lowercased().hasPrefix("ff0") || s.lowercased().hasPrefix("fe00")
    }
}
