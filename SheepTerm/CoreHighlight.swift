import Foundation

/// Platform-neutral adapter over the Mac app's original vendor/scanner code.
/// Byte offsets refer to ASCII input; non-ASCII follows the Mac scanner's policy.
public enum CoreHighlight {
    public struct Span: Equatable, Sendable {
        public let range: Range<Int>
        public let colorHex: String
        public let bold: Bool
    }

    public static var vendors: [String] { Vendor.allCases.map(\.rawValue) }

    @MainActor public static func installDefaults() { Highlighter.installDefaults() }

    public static func spans(in bytes: [UInt8], vendor name: String = "auto") -> [Span] {
        let vendor = Vendor(rawValue: name) ?? .auto
        let configs = Highlighter.defaultConfigs(for: vendor)
        return Highlighter.spans(in: bytes, vendor: vendor).compactMap { item in
            guard configs.indices.contains(item.rule) else { return nil }
            let config = configs[item.rule]
            return Span(range: item.range.location..<(item.range.location + item.range.length),
                        colorHex: config.colorHex, bold: config.bold)
        }
    }

    // MARK: - Overlay support (Windows terminal)

    /// One rule's fixed colour, in the order `ruleSpans` reports rule indices.
    public struct RuleColour: Equatable, Sendable {
        public let rgb: UInt32
        public let bold: Bool
    }

    /// Rule index -> colour for a vendor's pack. Built exactly like `VendorHighlightProvider.rebuild`: the default
    /// configs minus the ones that fail to compile, so index N here is rule N in `Highlighter.spans`.
    @MainActor public static func palette(for name: String) -> [RuleColour] {
        let vendor = Vendor(rawValue: name) ?? .auto
        var out: [RuleColour] = []
        for config in Highlighter.defaultConfigs(for: vendor) {
            guard HighlightRule(config: config, vendor: vendor) != nil else { continue }
            out.append(RuleColour(rgb: UInt32(config.colorHex, radix: 16) ?? 0xFFFFFF, bold: config.bold))
        }
        return out
    }

    /// The raw matcher output (byte range + rule index) for a paragraph, without colour lookup.
    public static func ruleSpans(in bytes: [UInt8], vendor name: String) -> [(range: Range<Int>, rule: Int)] {
        let vendor = Vendor(rawValue: name) ?? .auto
        return Highlighter.spans(in: bytes, vendor: vendor).compactMap { item in
            guard item.range.location != NSNotFound, item.range.length > 0 else { return nil }
            return (item.range.location..<(item.range.location + item.range.length), item.rule)
        }
    }

    public static func label(for name: String) -> String { (Vendor(rawValue: name) ?? .auto).label }
    public static func badge(for name: String) -> String { (Vendor(rawValue: name) ?? .auto).badge }

    /// The passive device-family detector (`VendorFingerprint`) behind a public face. Same rules: bounded byte budget,
    /// only a more specific family replaces a lock.
    public struct Fingerprint {
        private var inner = VendorFingerprint()
        public init() {}
        public var locked: Bool { inner.locked }
        public mutating func seed(with name: String) {
            if let v = Vendor(rawValue: name) { inner.seed(with: v) }
        }
        /// The family's raw name on a (new or more specific) lock, else nil.
        public mutating func consider(_ bytes: [UInt8]) -> String? { inner.consider(bytes)?.rawValue }
    }
}
