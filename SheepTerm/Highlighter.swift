import Foundation
import Synchronization

/// One built-in highlight rule and its fixed presentation. Colours are
/// compile-time constants (see `makeConfigs`); there is no longer any
/// user-facing customization or on-disk persistence for them.
struct HighlightRuleConfig {
    var name: String
    var pattern: String
    var colorHex: String        // "RRGGBB"
    var bold = false
    var caseInsensitive = false
}

/// A rule the byte scanner can serve.
///
/// There is no second matcher any more. The app used to compile every
/// `config.pattern` with `NSRegularExpression` and keep a regex branch in
/// `claimedSpans` for rules the scanner could not serve; nothing in the
/// shipping app ever reached it (every pack rule is a built-in, and the only
/// entry point refuses non-ASCII outright), so the ICU objects were 111
/// pattern compilations at launch that only the tests ever read. The pattern
/// strings stay — they are generated from the same sorted keyword arrays the
/// scanner buckets, they document the pack, and they are what the test
/// oracle compiles — but the app no longer compiles them.
struct HighlightRule {
    /// Which built-in this rule is. NOT optional: the scanner is the only
    /// matcher left, so a rule it cannot serve has no way to match anything.
    let builtIn: HighlightScanner.BuiltIn

    init?(config: HighlightRuleConfig, vendor: Vendor = .auto) {
        // Compiling the pattern used to be what proved a rule was usable. The
        // equivalent proof now is the scanner's own admission test: the rule
        // must still be this VENDOR's default (same name, pattern and
        // case-sensitivity — the scanner walks that vendor's profile, so a
        // pattern from another pack would be matched with the wrong keyword
        // table) and its name must resolve to a `BuiltIn` the scanner
        // implements. Failing either returns nil, so the rule does not exist
        // at all rather than sitting in the set matching nothing —
        // `HighlightProvider` applies the same filter when it builds the
        // palette, which is what keeps rule indices lined up.
        guard let def = Highlighter.defaultConfigs(for: vendor).first(where: { $0.name == config.name }),
              def.pattern == config.pattern,
              def.caseInsensitive == config.caseInsensitive,
              let builtIn = HighlightScanner.BuiltIn(rawValue: config.name) else {
            return nil
        }
        self.builtIn = builtIn
    }
}

/// Finds the network-relevant tokens in a run of text. It produces SPANS,
/// not a coloured copy: `VendorHighlightProvider` hands them to SheepVT's
/// `HighlightOverlay`, which colours the rows the renderer is about to draw,
/// so the bytes the device sent are never touched and logs and copy/paste
/// stay clean.
nonisolated enum Highlighter {
    /// Compiled rules currently in effect plus the scanner mask derived from
    /// them. The mask is cached with the rules because it only changes on a
    /// recompile (`installDefaults`, once at startup): deriving it per call
    /// cost ~1.4 µs, and escape-heavy output calls the matcher once per text
    /// run BETWEEN escape sequences — thousands of times per chunk, not once.
    struct ActiveRules {
        var rules: [HighlightRule] = []
        /// Bit per built-in rule the scanner may match; 0 only when there are
        /// no rules at all, since every rule that compiles is a built-in.
        var scannerMask: UInt16 = 0
        /// The keyword tables the scanner walks for this vendor. Stored with
        /// the rules so the hot path takes ONE lock for all three.
        var profile = HighlightScanner.profile(Vendor.auto.rawValue)
    }

    /// One compiled set per vendor, indexed by `Vendor.slot`.
    ///
    /// A session does not own its rules — it owns a `Vendor` and reads the
    /// set out of here. That is what lets a single recompile reach every open
    /// tab, exactly as it did when there was one global set, while still
    /// letting two tabs on two different families colour differently at the
    /// same time.
    ///
    /// `Mutex` makes the cross-actor ownership explicit: matching runs on
    /// background highlight queues while the sets are installed on the main
    /// actor. Everything inside an `ActiveRules` is immutable and Sendable.
    private static let activeStorage = Mutex(
        [ActiveRules](repeating: ActiveRules(), count: Vendor.allCases.count)
    )

    /// Bumped by every `setActive`. `VendorHighlightProvider` keys one colour
    /// per rule INDEX, and a recompile can change what sits at an index — a
    /// rule that is dropped moves every later rule up one. The provider
    /// compares this before it answers, so a stale palette can never colour a
    /// rule with its neighbour's colour.
    private static let revisionBox = Mutex<UInt64>(0)
    nonisolated static var revision: UInt64 { revisionBox.withLock { $0 } }

    /// Called from background highlight queues as well as the main actor.
    nonisolated static func setActive(_ sets: [Vendor: [HighlightRule]]) {
        var built = [ActiveRules](repeating: ActiveRules(), count: Vendor.allCases.count)
        for vendor in Vendor.allCases {
            let rules = sets[vendor] ?? []
            built[vendor.slot] = ActiveRules(
                rules: rules,
                scannerMask: HighlightScanner.mask(of: rules.map(\.builtIn)),
                profile: HighlightScanner.profile(vendor.rawValue)
            )
        }
        activeStorage.withLock { $0 = built }
        revisionBox.withLock { $0 &+= 1 }
    }

    nonisolated static func setActive(_ rules: [HighlightRule], for vendor: Vendor) {
        let entry = ActiveRules(
            rules: rules,
            scannerMask: HighlightScanner.mask(of: rules.map(\.builtIn)),
            profile: HighlightScanner.profile(vendor.rawValue)
        )
        activeStorage.withLock { $0[vendor.slot] = entry }
        revisionBox.withLock { $0 &+= 1 }
    }

    /// The `.auto` set. Convenience for tests, benchmarks and any caller with
    /// no session context; production paths always name their vendor.
    nonisolated static var active: [HighlightRule] {
        get { activeStorage.withLock { $0[Vendor.auto.slot].rules } }
        set { setActive(newValue, for: .auto) }
    }

    /// The compiled rules for a vendor. Matching goes through these; the
    /// colours that go with them live in `defaultConfigs(for:)`.
    nonisolated static func active(for vendor: Vendor) -> [HighlightRule] {
        activeStorage.withLock { $0[vendor.slot].rules }
    }

    /// Compiles the fixed built-in rules for every vendor pack once, at
    /// startup. Colours are constants baked into `makeConfigs`, so this runs
    /// exactly once (AppModel init) and never again — there is no Settings UI
    /// left to recompile a changed colour or order. `@MainActor` because
    /// `HighlightRule` is a default-isolated type, so its initialiser is
    /// main-actor bound.
    @MainActor static func installDefaults() {
        for vendor in Vendor.allCases {
            setActive(
                defaultConfigs(for: vendor).compactMap { HighlightRule(config: $0, vendor: vendor) },
                for: vendor
            )
        }
    }

    /// The spans a paragraph's bytes claim, without producing any output —
    /// the overlay colours cells as it builds a frame instead of assembling a
    /// new byte stream, so it wants the ranges, not the coloured copy.
    nonisolated static func spans(
        in bytes: [UInt8], vendor: Vendor
    ) -> [(range: NSRange, rule: Int)] {
        let snapshot = activeSnapshot(vendor)
        guard !bytes.isEmpty, !snapshot.rules.isEmpty, isASCII(bytes) else { return [] }
        return claimedSpans(
            rules: snapshot.rules,
            scannerMask: snapshot.scannerMask,
            profile: snapshot.profile,
            bytes: bytes
        )
    }

    /// Rules, mask and profile in one lock acquisition — the matching path
    /// needs all three.
    nonisolated static func activeSnapshot(_ vendor: Vendor) -> ActiveRules {
        activeStorage.withLock { $0[vendor.slot] }
    }


    // MARK: - Rule packs

    /// All eleven rule names with the union vocabulary behind them.
    ///
    /// This is a CATALOGUE, not a pack: no session ever matches with it —
    /// matching always goes through the vendor's own pack. It exists so the
    /// full set of rule names stays nameable in one place (the tests assert
    /// against it) even though no single pack carries all eleven.
    static var canonicalConfigs: [HighlightRuleConfig] {
        packs[HighlightScanner.catalogueKey]!
    }

    /// Built once per vendor (plus the catalogue). `HighlightRule.init`
    /// consults this on every compile to decide whether a pattern is still
    /// stock, so rebuilding the strings each time showed up in recompile.
    private static let packs: [String: [HighlightRuleConfig]] = {
        var out: [String: [HighlightRuleConfig]] = [:]
        for key in Vendor.allCases.map(\.rawValue) + [HighlightScanner.catalogueKey] {
            out[key] = makeConfigs(HighlightScanner.profile(key))
        }
        return out
    }()

    /// Order = priority: earlier rules claim their ranges first.
    ///   vlan → interface → cx-port → mask → cidr → ipv4 → mac → ipv6
    ///        → state-good → state-warn → state-bad
    /// Patterns aligned with BeeSheep's BestTextLog grammar.
    static func defaultConfigs(for vendor: Vendor) -> [HighlightRuleConfig] {
        packs[vendor.rawValue] ?? packs[Vendor.auto.rawValue]!
    }

    /// Escapes the two characters an interface prefix may legitimately
    /// contain (`ge-`, `irb.`). Everything else in these lists is [A-Za-z0-9].
    private static func escaped(_ keyword: String) -> String {
        var out = ""
        out.reserveCapacity(keyword.count + 2)
        for ch in keyword {
            if ch == "." || ch == "-" { out.append("\\") }
            out.append(ch)
        }
        return out
    }

    /// The alternation for a keyword list, IN THE PROFILE'S ORDER.
    ///
    /// This is the load-bearing line of the whole vendor design. The scanner
    /// tries a bucket's keywords in profile order and the regex tries its
    /// alternatives in written order; generating the alternation from the
    /// same already-sorted array is what makes "the longer of a prefix pair
    /// must come first" true by construction rather than by review.
    private static func alternation(_ keywords: [String]) -> String {
        keywords.map(escaped).joined(separator: "|")
    }

    private static func makeConfigs(_ p: HighlightScanner.Profile) -> [HighlightRuleConfig] {
        func uses(_ rule: HighlightScanner.BuiltIn) -> Bool {
            p.rules & HighlightScanner.bit(of: rule) != 0
        }
        var out: [HighlightRuleConfig] = []

        // Before "interface": "vlan 1,10,225-227" (spaced list) is the vlan
        // keyword; "Vlan10" (attached) stays an interface name.
        if uses(.vlan) {
            let tail = p.vlanRanges
                ? #"(?:[ \t]*[,\-][ \t]*\d{1,4}|[ \t]+(?:to[ \t]+)?\d{1,4})*"#
                : #"(?:[ \t]*[,\-][ \t]*\d{1,4})*"#
            let batch = p.vlanRanges ? #"(?:[ \t]+batch)?"# : ""
            out.append(HighlightRuleConfig(
                name: "vlan",
                pattern: #"\bvlan"# + batch + #"[ \t-]+\d{1,4}"# + tail,
                colorHex: "E8D06B", caseInsensitive: true
            ))
        }
        if uses(.interface) {
            // The digit-led alternative must lead: it can never share a start
            // byte with a keyword, and the scanner tries it first.
            let speed = p.digitSpeedPorts ? #"\d{1,3}GE|"# : ""
            var pattern = ""
            // A profile with digit-led ports but no keywords would emit
            // `(?:\d{1,3}GE|)` — the empty alternative makes the whole thing
            // `\b\s?\d+…`, colouring every bare number, which the scanner
            // would never do. No pack does this today; keep it that way.
            precondition(
                !p.digitSpeedPorts || !p.interfaceKeywords.isEmpty,
                "digitSpeedPorts needs at least one interface keyword"
            )
            if !p.interfaceKeywords.isEmpty {
                pattern = #"\b(?:"# + speed + alternation(p.interfaceKeywords)
                    + #")\s?\d+(?:[\/.:_-]\d+)*\b"#
            }
            // Digit-less names are a separate top-level alternative, always
            // second, so `lo0` still beats a bare `lo`.
            if !p.bareInterfaces.isEmpty {
                if !pattern.isEmpty { pattern += "|" }
                pattern += #"\b(?:"# + alternation(p.bareInterfaces) + #")\b"#
            }
            if !pattern.isEmpty {
                out.append(HighlightRuleConfig(
                    name: "interface", pattern: pattern,
                    colorHex: "F0A860", caseInsensitive: true
                ))
            }
        }
        if uses(.cxPort) {
            out.append(HighlightRuleConfig(
                name: "cx-port", pattern: #"\b\d{1,2}/\d{1,2}/\d{1,2}(?::\d)?\b"#,
                colorHex: "F0A860"
            ))
        }
        if uses(.mask) {
            out.append(HighlightRuleConfig(
                name: "mask", pattern: #"\b255(?:\.\d{1,3}){3}\b"#, colorHex: "C678DD"
            ))
        }
        if uses(.cidr) {
            out.append(HighlightRuleConfig(
                name: "cidr", pattern: #"(?<=[.:]\d{1,3})/\d{1,2}\b"#, colorHex: "C678DD"
            ))
        }
        // Octets are capped at 255 so "999.999.999.999" no longer matches.
        if uses(.ipv4) {
            out.append(HighlightRuleConfig(
                name: "ipv4",
                pattern: #"\b(?:(?:25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])\.){3}(?:25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])\b"#,
                colorHex: "6CD1E0"
            ))
        }
        if uses(.mac) {
            // The dash form of the 4-hex-group alternative would colour any
            // "1234-5678-9012"-shaped token, so only families that print MACs
            // that way carry it.
            let group = p.macDashGroups ? #"[.\-]"# : #"\."#
            // AOS-CX writes the chassis base MAC as two 6-hex groups
            // (3810f0-7ade00). Last alternative, and the scanner tries its
            // branches in this same order.
            let sixHex = p.macSixHexGroups
                ? #"|\b[0-9A-Fa-f]{6}\-[0-9A-Fa-f]{6}\b"#
                : ""
            out.append(HighlightRuleConfig(
                name: "mac",
                pattern: #"\b(?:[0-9A-Fa-f]{4}"# + group + #"){2}[0-9A-Fa-f]{4}\b"#
                    + #"|\b(?:[0-9A-Fa-f]{2}[:\-]){5}[0-9A-Fa-f]{2}\b"# + sixHex,
                colorHex: "E08BC7"
            ))
        }
        // Empty groups allow the compressed "::" form (2001:db8::1). Custom
        // boundaries instead of \b so a leading "::" (e.g. ::1) also matches —
        // ":" is a non-word char, so \b would never fire before it.
        //
        // The leading lookahead is what keeps clocks out of it: that shape on
        // its own also fits `14:37:24`, so every timestamp in `show events` /
        // `show logging` used to be painted address blue. A run counts as an
        // address only if it is compressed (a `::` anywhere in it) or written
        // out in full (7 colons, all 8 groups non-empty). The body can only
        // end where a non-hex/non-colon byte follows, so it always spans the
        // whole maximal hex/colon run — a `::` the lookahead finds in that run
        // is therefore inside the match.
        if uses(.ipv6) {
            out.append(HighlightRuleConfig(
                name: "ipv6",
                pattern: #"(?<![0-9A-Fa-f:])"#
                    + #"(?=[0-9A-Fa-f:]*::|(?:[0-9A-Fa-f]{1,4}:){7}[0-9A-Fa-f]{1,4}(?![0-9A-Fa-f:]))"#
                    + #"(?:[0-9A-Fa-f]{0,4}:){2,7}[0-9A-Fa-f]{0,4}(?![0-9A-Fa-f:])"#,
                colorHex: "6CD1E0"
            ))
        }
        if uses(.stateGood) {
            // The negation branch leads, matching the scanner.
            let negation = p.negations.isEmpty
                ? ""
                : "(?:" + p.negations.joined(separator: "|") + #")[ \t]+shutdown|"#
            out.append(HighlightRuleConfig(
                name: "state-good",
                pattern: #"\b(?:"# + negation + alternation(p.stateGoodKeywords) + #")\b"#,
                colorHex: "7DD98C", bold: true, caseInsensitive: true
            ))
        }
        if uses(.stateWarn) {
            out.append(HighlightRuleConfig(
                name: "state-warn",
                pattern: #"\b(?:"# + alternation(p.stateWarnKeywords) + #")\b"#,
                colorHex: "E0B568", bold: true, caseInsensitive: true
            ))
        }
        if uses(.stateBad) {
            out.append(HighlightRuleConfig(
                name: "state-bad",
                pattern: #"\b(?:"# + alternation(p.stateBadKeywords) + #")\b"#,
                colorHex: "ED7A7A", bold: true, caseInsensitive: true
            ))
        }
        return out
    }

    /// Every `Vendor` must resolve to its OWN profile — a typo in a raw value
    /// would silently fall back to `.auto` and colour, say, a Junos box with
    /// Aruba's cx-port rule. Asserted by the test suite.
    static func vendorCoverageIsComplete() -> Bool {
        Vendor.allCases.allSatisfy { HighlightScanner.profiles[$0.rawValue] != nil }
    }

    /// One byte pass instead of `text.allSatisfy { $0.isASCII }` on top of
    /// the utf8 copy the scanner needs anyway — the Character-level probe
    /// was ~10 % of the matching pass by itself.
    @inline(__always)
    nonisolated private static func isASCII(_ bytes: [UInt8]) -> Bool {
        for byte in bytes where byte >= 0x80 { return false }
        return true
    }

    /// The non-overlapping spans each rule claims, in priority order.
    ///
    /// `bytes` is always pure ASCII — the caller refuses anything else, which
    /// is what lets a byte offset double as the terminal COLUMN the overlay
    /// paints. One scanner pass produces every rule's matches; there is no
    /// second matcher to fall back to.
    ///
    /// Claimed spans stay sorted by location and never overlap, and each
    /// rule's matches arrive sorted too — so each rule is merged into
    /// claimed in one linear pass. A match is dropped iff it overlaps an
    /// already-claimed span: spans ending at or before the match start
    /// cannot overlap, and the first span reaching into it is the only
    /// one that can (later spans start even further out). That is exactly
    /// the old prev/next neighbour check around a binary-search insert —
    /// but with no O(n) middle-of-array memmoves, which made multi-MB
    /// dumps quadratic.
    nonisolated static func claimedSpans(
        rules: [HighlightRule],
        scannerMask: UInt16,
        profile: HighlightScanner.Profile,
        bytes: [UInt8]
    ) -> [(range: NSRange, rule: Int)] {
        // Ordinal-indexed, so a rule's matches are an array subscript rather
        // than a Dictionary lookup — and building the result costs no hashing.
        let scanned = HighlightScanner.scan(bytes, enabledMask: scannerMask, profile: profile)
        var claimed: [(range: NSRange, rule: Int)] = []

        for (ruleIndex, rule) in rules.enumerated() {
            // Merging is a full rebuild of `claimed`, so a rule that
            // matched nothing must not pay for one. On escape-heavy
            // output the text runs between sequences are a few bytes
            // long and almost every rule lands here.
            let matches = scanned[HighlightScanner.ordinal(of: rule.builtIn)]
            if matches.isEmpty { continue }
            var merged: [(range: NSRange, rule: Int)] = []
            merged.reserveCapacity(claimed.count + matches.count)
            var ci = 0
            for match in matches where !match.isEmpty {
                while ci < claimed.count,
                      claimed[ci].range.location + claimed[ci].range.length <= match.lowerBound {
                    merged.append(claimed[ci])
                    ci += 1
                }
                // Overlaps a claimed span — drop this match, keep `ci`.
                if ci < claimed.count, claimed[ci].range.location < match.upperBound { continue }
                merged.append((NSRange(location: match.lowerBound, length: match.count), ruleIndex))
            }
            while ci < claimed.count { // remaining spans start past the last match
                merged.append(claimed[ci])
                ci += 1
            }
            claimed = merged
        }
        return claimed
    }

}
