import Foundation

/// The system language remains the default. AppleLanguages is the supported
/// per-app override, read by both SwiftUI and AppKit on the next launch.
enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case system, english = "en", simplifiedChinese = "zh-Hans"

    var id: String { rawValue }

    static let launchLanguage = current()

    static func current(in defaults: UserDefaults = .standard) -> AppLanguage {
        guard let value = defaults.string(forKey: "interfaceLanguage"),
              let language = AppLanguage(rawValue: value) else { return .system }
        return language
    }

    func apply(to defaults: UserDefaults = .standard) {
        defaults.set(rawValue, forKey: "interfaceLanguage")
        if self == .system {
            defaults.removeObject(forKey: "AppleLanguages")
        } else {
            defaults.set([rawValue], forKey: "AppleLanguages")
        }
    }
}
