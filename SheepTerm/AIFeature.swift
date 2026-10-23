import Foundation

/// View ▸ AI Assistant (5.0 (47)): one switch for everyone who does not want
/// the AI at all. Off = no panel, no tab-bar button, no ⌥⌘A, no AI tab in
/// Settings; nothing is uninstalled or signed out, and turning it back on
/// brings every piece back as it was. On by default.
nonisolated enum AIFeature {
    static let enabledKey = "aiEnabled"

    static func isEnabled(_ defaults: UserDefaults = .standard) -> Bool {
        // bool(forKey:) also reads "NO"/"0" (a -aiEnabled NO launch argument).
        defaults.object(forKey: enabledKey) == nil ? true : defaults.bool(forKey: enabledKey)
    }

    /// The panel is open only while the feature is on: a panel left open
    /// when the user switched AI off stays closed after a relaunch.
    static func panelShown(stored: Bool, enabled: Bool) -> Bool { enabled && stored }
}
