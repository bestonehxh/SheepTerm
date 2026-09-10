// SheepVT — OSC dispatch (`ESC ] number ; payload ST`).
//
// The payload is bytes; we decode it as UTF-8 with replacement rather than
// rejecting it, because a mangled title is still a title. Only the first ';'
// separates the number from the payload — OSC 8 URIs and OSC 52 data both
// contain semicolons of their own.

extension Terminal {

    public func oscDispatch(_ payload: ArraySlice<UInt8>, bellTerminated: Bool) {
        lastActionWasPrint = false
        let text = String(decoding: payload, as: UTF8.self)

        let number: String
        let rest: String
        if let sep = text.firstIndex(of: ";") {
            number = String(text[text.startIndex..<sep])
            rest = String(text[text.index(after: sep)...])
        } else {
            number = text
            rest = ""
        }
        guard let code = Int(number), code >= 0 else {
            unhandled("OSC \(number)")
            return
        }

        switch code {
        case 0: // title + icon name
            setTitle(rest)
            setIconName(rest)
        case 1:
            setIconName(rest)
        case 2:
            setTitle(rest)
        case 4:
            indexedColor(rest)
        case 7:
            delegate?.workingDirectoryChanged(self, url: rest)
        case 8:
            hyperlink(rest)
        case 9:
            delegate?.notification(self, title: "", body: rest)
        case 10, 11, 12:
            specialColor(rest, base: code)
        case 52:
            clipboard(rest)
        case 104:
            resetIndexedColor(rest)
        case 110, 111, 112:
            resetSpecialColor(base: code)
        case 133:
            if let mark = rest.first {
                delegate?.semanticPrompt(self, mark: mark, row: buffer.y)
            }
        case 777:
            notify777(rest)
        default:
            unhandled("OSC \(code)")
        }
    }

    // MARK: - OSC 4 / 104 — the 256-colour palette

    /// xterm's stock 256-colour table.
    static func defaultPaletteColor(_ index: Int) -> UInt32 {
        let ansi: [UInt32] = [0x000000, 0xCD0000, 0x00CD00, 0xCDCD00, 0x0000EE, 0xCD00CD, 0x00CDCD, 0xE5E5E5,
                              0x7F7F7F, 0xFF0000, 0x00FF00, 0xFFFF00, 0x5C5CFF, 0xFF00FF, 0x00FFFF, 0xFFFFFF]
        if index < 16 { return ansi[Swift.max(0, index)] }
        if index < 232 {
            let n = index - 16
            let steps: [UInt32] = [0, 95, 135, 175, 215, 255]
            return (steps[n / 36] << 16) | (steps[(n / 6) % 6] << 8) | steps[n % 6]
        }
        let g = UInt32(8 + (Swift.min(index, 255) - 232) * 10)
        return (g << 16) | (g << 8) | g
    }

    private func indexedColor(_ rest: String) {
        // `4 ; index ; spec [ ; index ; spec ]…`, where spec may be `?`.
        let parts = rest.split(separator: ";", omittingEmptySubsequences: false).map(String.init)
        var i = 0
        // Replies per OSC, capped: a 7 MiB `4;0;?;0;?…` under the payload cap
        // drew 1.8 million replies (45 MB) from one sequence, each one a
        // write queued to the worker. 256 covers every real palette probe
        // (the palette has 256 entries) and bounds the amplification.
        var answered = 0
        while i + 1 < parts.count {
            defer { i += 2 }
            guard let index = Int(parts[i]), index >= 0, index < palette.count else { continue }
            let spec = parts[i + 1]
            if spec == "?" {
                guard answered < palette.count else { continue }
                answered += 1
                // xterm always answers; a program probing the palette would
                // otherwise block on its timeout. An untouched entry reports
                // xterm's default for that index (the host theme's 16 are not
                // known here — close enough for capability probing).
                let rgb = palette[index] ?? Terminal.defaultPaletteColor(index)
                send("\u{1b}]4;\(index);\(Self.xColorString(rgb))\u{1b}\\")
            } else if let rgb = Self.parseColor(spec) {
                setPaletteEntry(index, rgb)
            }
        }
    }

    private func resetIndexedColor(_ rest: String) {
        if rest.isEmpty {
            resetPalette()
            return
        }
        for part in rest.split(separator: ";", omittingEmptySubsequences: false) {
            if let index = Int(part) { setPaletteEntry(index, nil) }
        }
    }

    // MARK: - OSC 10 / 11 / 12 — default foreground, background and cursor

    private func specialColor(_ rest: String, base: Int) {
        // Slots run fg, bg, cursor from whichever number started the sequence:
        // `OSC 10 ; fg ; bg ; cursor` is one legal way to set all three.
        var slot = base
        for part in rest.split(separator: ";", omittingEmptySubsequences: false) {
            defer { slot += 1 }
            let spec = String(part)
            // A query answers what is IN EFFECT, not the theme's baseline: a
            // program that set its own scheme and then asks must be told what
            // it is looking at, or it "restores" the wrong colour itself.
            switch slot {
            case 10:
                if spec == "?" { send("\u{1b}]10;\(Self.xColorString(defaultForeground))\u{1b}\\") }
                else if let rgb = Self.parseColor(spec) { setProgramForeground(rgb); markAllDirty() }
            case 11:
                if spec == "?" { send("\u{1b}]11;\(Self.xColorString(defaultBackground))\u{1b}\\") }
                else if let rgb = Self.parseColor(spec) { setProgramBackground(rgb); markAllDirty() }
            case 12:
                if spec == "?" { send("\u{1b}]12;\(Self.xColorString(defaultCursorColor))\u{1b}\\") }
                else if let rgb = Self.parseColor(spec) { setProgramCursorColor(rgb); markAllDirty() }
            default:
                break // mouse fg/bg, highlight, Tektronix: not ours
            }
        }
    }

    // MARK: - OSC 110 / 111 / 112 — back to the theme

    /// The polite way out of an `OSC 10/11/12`, which is what a program sends
    /// on exit. It cannot mean "power-on white on black" — the user picked a
    /// theme — so it means the host's baseline, the same place RIS goes.
    /// xterm ignores any payload on these, and so do we.
    private func resetSpecialColor(base: Int) {
        switch base {
        case 110: restoreHostForeground()
        case 111: restoreHostBackground()
        default:  restoreHostCursorColor()
        }
        markAllDirty()
    }

    // MARK: - OSC 8 — hyperlinks

    private func hyperlink(_ rest: String) {
        // `8 ; params ; uri`. Semicolons inside the URI are legal, so only the
        // first one is a separator.
        guard let sep = rest.firstIndex(of: ";") else { return }
        let params = String(rest[rest.startIndex..<sep])
        let uri = String(rest[rest.index(after: sep)...])
        if uri.isEmpty {
            pen.extended.hyperlinkID = 0
            touch()
            return
        }
        var id = ""
        for field in params.split(separator: ":", omittingEmptySubsequences: false) where field.hasPrefix("id=") {
            id = String(field.dropFirst(3))
        }
        pen.extended.hyperlinkID = registerHyperlink(id: id, uri: uri)
        touch()
    }

    // MARK: - OSC 52 — clipboard

    private func clipboard(_ rest: String) {
        let sep = rest.firstIndex(of: ";")
        let selection = sep.map { String(rest[rest.startIndex..<$0]) } ?? "s0"
        let data = sep.map { String(rest[rest.index(after: $0)...]) } ?? ""
        if data == "?" {
            guard let bytes = delegate?.getClipboard(self, selection: selection) else { return }
            send("\u{1b}]52;\(selection);\(Base64.encode(bytes))\u{1b}\\")
        } else if let bytes = Base64.decode(data) {
            delegate?.setClipboard(self, selection: selection, data: bytes)
        }
    }

    // MARK: - OSC 777 — desktop notification

    private func notify777(_ rest: String) {
        // `777 ; notify ; title ; body` (body may itself contain semicolons).
        let parts = rest.split(separator: ";", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2, parts[0] == "notify" else {
            unhandled("OSC 777;\(rest)")
            return
        }
        delegate?.notification(self, title: parts[1], body: parts.count > 2 ? parts[2] : "")
    }

    // MARK: - Colour parsing

    /// XParseColor, the subset devices actually emit: `rgb:R/G/B` with 1–4 hex
    /// digits per channel, and `#RGB` / `#RRGGBB` / `#RRRRGGGGBBBB`.
    static func parseColor(_ spec: String) -> UInt32? {
        if spec.hasPrefix("rgb:") {
            let body = spec.dropFirst(4)
            let comps = body.split(separator: "/", omittingEmptySubsequences: false)
            guard comps.count == 3 else { return nil }
            var out: UInt32 = 0
            for c in comps {
                guard let v = scaledHex(c) else { return nil }
                out = (out << 8) | v
            }
            return out
        }
        if spec.hasPrefix("#") {
            let body = spec.dropFirst()
            guard body.count % 3 == 0, body.count >= 3, body.count <= 12 else { return nil }
            let n = body.count / 3
            var out: UInt32 = 0
            var idx = body.startIndex
            for _ in 0..<3 {
                let end = body.index(idx, offsetBy: n)
                guard let v = scaledHex(body[idx..<end]) else { return nil }
                out = (out << 8) | v
                idx = end
            }
            return out
        }
        return nil
    }

    /// One channel of 1–4 hex digits, scaled to 8 bits.
    private static func scaledHex(_ s: Substring) -> UInt32? {
        guard !s.isEmpty, s.count <= 4 else { return nil }
        var v: UInt32 = 0
        for ch in s.unicodeScalars {
            guard let d = hexDigit(ch) else { return nil }
            v = v << 4 | d
        }
        let maximum = (UInt32(1) << (4 * UInt32(s.count))) - 1
        guard maximum > 0 else { return nil }
        return (v * 255 + maximum / 2) / maximum
    }

    private static func hexDigit(_ ch: UnicodeScalar) -> UInt32? {
        switch ch {
        case "0"..."9": return ch.value - 48
        case "a"..."f": return ch.value - 87
        case "A"..."F": return ch.value - 55
        default: return nil
        }
    }

    /// The `rgb:rrrr/gggg/bbbb` form xterm replies with (8-bit values doubled
    /// into 16-bit channels).
    static func xColorString(_ rgb: UInt32) -> String {
        func chan(_ shift: UInt32) -> String {
            let byte = (rgb >> shift) & 0xFF
            return format4(byte << 8 | byte)
        }
        return "rgb:\(chan(16))/\(chan(8))/\(chan(0))"
    }

    private static let hexDigits: [Character] = Array("0123456789abcdef")

    private static func format4(_ v: UInt32) -> String {
        var out = ""
        out.reserveCapacity(4)
        for shift in stride(from: UInt32(12), through: UInt32(0), by: -4) {
            out.append(hexDigits[Int((v >> shift) & 0xF)])
        }
        return out
    }
}

// MARK: - Base64 (OSC 52)

/// Small enough to keep the package free of a Foundation import.
enum Base64 {
    private static let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/")

    static func encode(_ bytes: [UInt8]) -> String {
        var out = ""
        out.reserveCapacity((bytes.count + 2) / 3 * 4)
        var i = 0
        while i + 2 < bytes.count {
            let n = (Int(bytes[i]) << 16) | (Int(bytes[i + 1]) << 8) | Int(bytes[i + 2])
            out.append(alphabet[(n >> 18) & 63])
            out.append(alphabet[(n >> 12) & 63])
            out.append(alphabet[(n >> 6) & 63])
            out.append(alphabet[n & 63])
            i += 3
        }
        let remaining = bytes.count - i
        if remaining == 1 {
            let n = Int(bytes[i]) << 16
            out.append(alphabet[(n >> 18) & 63])
            out.append(alphabet[(n >> 12) & 63])
            out.append("==")
        } else if remaining == 2 {
            let n = (Int(bytes[i]) << 16) | (Int(bytes[i + 1]) << 8)
            out.append(alphabet[(n >> 18) & 63])
            out.append(alphabet[(n >> 12) & 63])
            out.append(alphabet[(n >> 6) & 63])
            out.append("=")
        }
        return out
    }

    static func decode(_ s: String) -> [UInt8]? {
        var out: [UInt8] = []
        out.reserveCapacity(s.utf8.count / 4 * 3)
        var acc = 0
        var bits = 0
        for ch in s.utf8 {
            if ch == UInt8(ascii: "=") { break }
            guard let v = value(of: ch) else {
                // Whitespace is common in wrapped payloads; anything else is junk.
                if ch == 0x0A || ch == 0x0D || ch == 0x20 || ch == 0x09 { continue }
                return nil
            }
            acc = (acc << 6) | Int(v)
            bits += 6
            if bits >= 8 {
                bits -= 8
                out.append(UInt8((acc >> bits) & 0xFF))
            }
        }
        return out
    }

    private static func value(of ch: UInt8) -> UInt8? {
        switch ch {
        case UInt8(ascii: "A")...UInt8(ascii: "Z"): return ch - UInt8(ascii: "A")
        case UInt8(ascii: "a")...UInt8(ascii: "z"): return ch - UInt8(ascii: "a") + 26
        case UInt8(ascii: "0")...UInt8(ascii: "9"): return ch - UInt8(ascii: "0") + 52
        case UInt8(ascii: "+"): return 62
        case UInt8(ascii: "/"): return 63
        default: return nil
        }
    }
}
