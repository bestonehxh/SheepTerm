import Foundation

/// The package's own strings: Resources/Localizable.xcstrings, in every language SheepTerm ships
/// (an app with fewer languages simply shows English for the rest).
func L(_ value: String.LocalizationValue) -> String { String(localized: value, bundle: .module) }

public enum SheepWebResources {
    /// The package's resource bundle (its string catalog), for tests and diagnostics.
    public static var bundle: Bundle { .module }
}
