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
}
