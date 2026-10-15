import Foundation

/// Share links: the pure pieces (link text, recipients, lifetimes, errors). The crypto is in ShareCrypto.swift, the Drive calls behind
/// `ShareBackend`, the flow in ShareService.swift. Byte format: SHARE-LINK.md at the repository root.
public enum ShareError: Error, Equatable, Sendable, LocalizedError {
    case noRecipients
    case badRecipient(String)
    case tooManyRecipients
    /// The sender's own address: sharing with yourself is a mistake, not a feature.
    case ownAddress
    case passphraseTooShort
    case nothingToShare
    case badLink
    /// The file is gone (Google answered 403/404): revoked by the sender, or deleted when it expired.
    case revoked
    /// Past the expiry written INSIDE the share (an honest client refuses it even if the Drive file is still there).
    case expired
    case needsPassphrase
    case wrongPassphrase
    case damaged(String)
    case unsupported(Int)
    case tooLarge
    case notSignedIn
    case notRecipient

    public var errorDescription: String? {
        switch self {
        case .noRecipients: return "Add at least one recipient."
        case .badRecipient(let address): return "\u{201C}\(address)\u{201D} is not a valid email address."
        case .tooManyRecipients: return "A link can be shared with at most \(ShareRecipients.maximum) people."
        case .ownAddress: return "That is your own address."
        case .passphraseTooShort: return "The share passphrase needs at least \(ShareService.minimumPassphraseLength) characters."
        case .nothingToShare: return "There is nothing to share."
        case .badLink: return "That is not a SheepTerm share link."
        case .revoked: return "This link was revoked or has expired."
        case .expired: return "This link has expired."
        case .needsPassphrase: return "Enter the share passphrase."
        case .wrongPassphrase: return "That passphrase doesn\u{2019}t open this link (or the link was changed)."
        case .damaged(let what): return "The share is damaged or was altered (\(what))."
        case .unsupported: return "This share was made by a newer SheepTerm \u{2014} update the app to open it."
        case .tooLarge: return "The shared file is too large."
        case .notSignedIn: return "Sign in with Google (Settings \u{25B8} Sync) first."
        case .notRecipient: return "This link was shared with other people."
        }
    }
}

/// `https://bestonehxh.github.io/share/#v2.<driveFileId>.<base64url linkKey>` and its app form `sheepterm://share#v2.…`.
/// The key is in the fragment: no server ever receives it. A v1 link (the 5.0 development format) is refused.
public struct SharedLink: Equatable, Sendable {
    public static let version = "v2"
    public static let webPrefix = "https://bestonehxh.github.io/share/#"
    public static let schemePrefix = "sheepterm://share#"

    public var fileID: String
    /// 32 bytes.
    public var key: Data

    public init(fileID: String, key: Data) {
        self.fileID = fileID
        self.key = key
    }

    public var fragment: String { "\(Self.version).\(fileID).\(Self.base64URL(key))" }
    public var url: String { Self.webPrefix + fragment }
    public var appURL: String { Self.schemePrefix + fragment }

    /// Accepts the web link, the app link, or the bare fragment (with or without the leading #). Anything else is nil.
    public static func parse(_ text: String) -> SharedLink? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count < 400 else { return nil }
        let fragment: String
        if let hash = trimmed.firstIndex(of: "#") {
            let head = trimmed[..<hash].lowercased()
            let allowedHeads = ["https://bestonehxh.github.io/share", "https://bestonehxh.github.io/share/",
                                "sheepterm://share", "sheepterm://share/", ""]
            guard allowedHeads.contains(head) else { return nil }
            fragment = String(trimmed[trimmed.index(after: hash)...])
        } else {
            fragment = trimmed
        }
        let parts = fragment.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, parts[0] == version else { return nil }
        let id = parts[1]
        guard (10...128).contains(id.count), id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") })
        else { return nil }
        guard let key = base64URLDecode(parts[2]), key.count == 32 else { return nil }
        return SharedLink(fileID: id, key: key)
    }

    public static func base64URL(_ data: Data) -> String { GoogleOAuth.base64URL(data) }

    public static func base64URLDecode(_ text: String) -> Data? {
        guard text.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }) else { return nil }
        var body = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while body.count % 4 != 0 { body += "=" }
        return Data(base64Encoded: body)
    }
}

public enum ShareRecipients {
    public static let maximum = 20

    /// One address, lowercased, or nil when it is not a plausible mailbox. Deliberately plain (letters, digits, `._%+-`@labels.tld): the
    /// address only ever goes to Drive as `emailAddress` of a `type=user` permission, never to a shell or a query.
    public static func normalize(_ raw: String) -> String? {
        let address = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let halves = address.split(separator: "@", omittingEmptySubsequences: false)
        guard halves.count == 2, !halves[0].isEmpty, halves[0].count <= 64, halves[1].count <= 255 else { return nil }
        let local = halves[0], domain = halves[1]
        guard local.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "._%+-'".contains($0)) }),
              !local.hasPrefix("."), !local.hasSuffix("."), !local.contains("..") else { return nil }
        let labels = domain.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2 else { return nil }
        for label in labels {
            guard !label.isEmpty, label.count <= 63, !label.hasPrefix("-"), !label.hasSuffix("-"),
                  label.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }) else { return nil }
        }
        guard labels.last!.count >= 2, labels.last!.allSatisfy({ $0.isLetter }) else { return nil }
        return address
    }

    /// A typed field ("a@x.com, b@y.com; c@z.com") or a list of fields: validated, lowercased, duplicates dropped, order kept.
    public static func parse(_ fields: [String], excluding own: String? = nil) throws -> [String] {
        var out: [String] = []
        for field in fields {
            for piece in field.split(whereSeparator: { ", ;\n\t".contains($0) }) {
                guard let address = normalize(String(piece)) else { throw ShareError.badRecipient(String(piece)) }
                if let own, own.lowercased() == address { throw ShareError.ownAddress }
                if !out.contains(address) { out.append(address) }
            }
        }
        guard !out.isEmpty else { throw ShareError.noRecipients }
        guard out.count <= maximum else { throw ShareError.tooManyRecipients }
        return out
    }
}

public enum ShareLifetime: String, CaseIterable, Codable, Sendable {
    case day, week, month, never

    public var seconds: TimeInterval? {
        switch self {
        case .day: return 86_400
        case .week: return 7 * 86_400
        case .month: return 30 * 86_400
        case .never: return nil
        }
    }

    public func expiry(from now: Date) -> Date? { seconds.map { now.addingTimeInterval($0) } }
}

public enum ShareNaming {
    /// The name an imported group lands under: its own when free, else "Name (shared)", then "Name (shared 2)" …
    public static func importName(_ base: String, taken: [String]) -> String {
        let name = base.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = name.isEmpty ? "Shared group" : name
        let used = Set(taken)
        if !used.contains(base) { return base }
        if !used.contains("\(base) (shared)") { return "\(base) (shared)" }
        var n = 2
        while used.contains("\(base) (shared \(n))") { n += 1 }
        return "\(base) (shared \(n))"
    }
}

/// Keys that must never travel in a shared group, whichever app wrote the document: the local credential reference and the settings that
/// decide what the IMPORTER hands a server. Applied by the service on the way out AND in (defence in depth: the app's own codec strips
/// them too, but a hand-made share is read by this).
public enum ShareScrub {
    public static let forbiddenKeys: Set<String> = ["credentialID", "agentForward", "jumpHostID", "jumpSpec"]

    public static func stripped(_ document: Data) throws -> Data {
        guard let object = try? JSONSerialization.jsonObject(with: document, options: [.fragmentsAllowed]) else {
            throw ShareError.damaged("group document")
        }
        let clean = scrub(object)
        return try JSONSerialization.data(withJSONObject: clean, options: [.sortedKeys, .fragmentsAllowed])
    }

    private static func scrub(_ value: Any) -> Any {
        if let dict = value as? [String: Any] {
            var out: [String: Any] = [:]
            for (key, item) in dict where !forbiddenKeys.contains(key) { out[key] = scrub(item) }
            return out
        }
        if let array = value as? [Any] { return array.map(scrub) }
        return value
    }
}
