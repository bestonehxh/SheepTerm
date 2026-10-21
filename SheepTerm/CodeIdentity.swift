import Foundation
import Security

/// Who signed this running copy. A Developer ID build (5.0 (36) on) carries Team ID CU6RLF74Z7; a self-signed or
/// ad-hoc build (a public clone, or a build after the membership lapses) carries none. Read once from the app's own
/// code signature — never from Info.plist or the environment.
enum CodeIdentity {
    static let ownTeamID: String? = {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return nil }
        return validTeamID(dict[kSecCodeInfoTeamIdentifier as String] as? String)
    }()

    /// Apple Team IDs are ten upper-case letters/digits; anything else is treated as no team.
    static func validTeamID(_ value: String?) -> String? {
        guard let value, value.count == 10,
              value.allSatisfy({ ($0.isASCII && $0.isUppercase && $0.isLetter) || ($0.isASCII && $0.isNumber) }) else { return nil }
        return value
    }
}
