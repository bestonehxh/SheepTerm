import Foundation

/// The system language remains the default. AppleLanguages is the supported
/// per-app override, read by both SwiftUI and AppKit on the next launch.
enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case system, english = "en", german = "de", spanish = "es", french = "fr", brazilianPortuguese = "pt-BR",
         russian = "ru", japanese = "ja", korean = "ko", simplifiedChinese = "zh-Hans"

    var id: String { rawValue }

    /// Each language in its own name, as macOS lists them (never translated).
    var nativeName: String? {
        switch self {
        case .system: nil
        case .english: "English"
        case .german: "Deutsch"
        case .spanish: "Español"
        case .french: "Français"
        case .brazilianPortuguese: "Português (Brasil)"
        case .russian: "Русский"
        case .japanese: "日本語"
        case .korean: "한국어"
        case .simplifiedChinese: "简体中文"
        }
    }

    static let launchLanguage = current()

    static func current(in defaults: UserDefaults = .standard) -> AppLanguage {
        guard let value = defaults.string(forKey: "interfaceLanguage"),
              let language = AppLanguage(rawValue: value) else { return .system }
        return language
    }

    /// With no override, a Traditional-Chinese system (zh-Hant, zh-TW, zh-HK, zh-MO) would get English — the app has
    /// only Simplified. Only the FIRST preferred language counts: someone who put English first keeps English.
    static func chineseFallback(preferred: [String]) -> String? {
        guard let first = preferred.first?.lowercased(), first == "zh" || first.hasPrefix("zh-") else { return nil }
        if first.hasPrefix("zh-hans") || first == "zh-cn" || first == "zh-sg" { return nil }
        return simplifiedChinese.rawValue
    }

    /// Called first thing at launch (before any localized lookup). A volatile argument-domain AppleLanguages changes
    /// this run only — nothing is written, so "System Default" stays the system's.
    static func applySystemFallback(defaults: UserDefaults = .standard) {
        guard current(in: defaults) == .system,
              let language = chineseFallback(preferred: Locale.preferredLanguages) else { return }
        var args = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        args["AppleLanguages"] = [language] + Locale.preferredLanguages
        defaults.setVolatileDomain(args, forName: UserDefaults.argumentDomain)
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
