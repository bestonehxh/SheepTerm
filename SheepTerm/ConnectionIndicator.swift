import Foundation

/// How the bottom bar shows a session's connection state (View ▸ Bottom Bar
/// Items ▸ Connection Status, 5.0 (60)): wool puffs (the default), a packet
/// running between two ends, the sheep, or nothing — the owner's picks.
/// Pure — harness-tested.
nonisolated enum ConnectionIndicator: String, CaseIterable, Identifiable, Sendable {
    case wool, packet, sheep, off
    var id: String { rawValue }

    static let storageKey = "statusConnectionStyle"

    /// The stored choice. Before this existed there was only the "Sheep"
    /// switch: on (or never set) becomes the new default, Wool; off stays Off.
    /// A value from an older 5.0 (60) draft (dot, icon…) reads as Wool.
    static func stored(_ raw: String?, legacySheepShown: Bool?) -> ConnectionIndicator {
        if let raw, let style = ConnectionIndicator(rawValue: raw) { return style }
        return legacySheepShown == false ? .off : .wool
    }

    /// Once connected the colour is turned down (the owner: a full green
    /// sitting in the bar all day draws the eye); connecting stays bright.
    enum Phase: Sendable { case connecting, connected, closed }
    static func brightness(_ phase: Phase) -> Double {
        switch phase {
        case .connecting: return 1.0
        case .connected: return 0.5
        case .closed: return 0.75
        }
    }
}
