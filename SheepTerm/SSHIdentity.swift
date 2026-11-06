import CryptoKit
import Foundation
import SheepSSH

/// A private key kept for a credential (6.1, Credentials ▸ Key): the key
/// file's text as imported or generated, and its passphrase when it has one.
/// Lives ONLY in the Keychain vault (`Keychain.key(for:)`, entry
/// `key.<credential uuid>`), never in credentials.json — that file carries
/// just the public line (`Credential.publicKey`), which is not a secret.
nonisolated struct StoredKey: Codable, Equatable, Sendable {
    var text: String
    var passphrase: String?
    /// The OpenSSH certificate for this key (6.1), a `-cert.pub` line. Set
    /// only on the way to a session, from `Credential.certificate` (public,
    /// in credentials.json) — never written into the vault.
    var certificate: String? = nil

    private enum CodingKeys: String, CodingKey { case text, passphrase }
}

/// The credential keys one SSH session offers: the target's and the bastion's,
/// each with the credential's name for notices.
nonisolated struct SessionKeys: Sendable {
    var target: (key: StoredKey, name: String)? = nil
    var jump: (key: StoredKey, name: String)? = nil
    /// The bastion's Authentication (6.1).
    var jumpAuthMethod: SSHAuthMethod = .automatic
}

/// Reading, checking and generating SSH private keys for credentials.
/// Pure (no Keychain, no UI): the harness `workers` drives it.
nonisolated enum SSHIdentity {
    enum Problem: Error, Equatable {
        /// Encrypted, and no passphrase given.
        case needsPassphrase
        case wrongPassphrase
        /// Not a key SheepSSH reads (format, cipher, key type) — the reason.
        case unreadable(String)
    }

    /// The key parsed and decrypted: its public line ("ssh-ed25519 AAAA… comment")
    /// for credentials.json, or why it cannot be used. An empty passphrase
    /// counts as none.
    static func inspect(_ key: StoredKey) -> Result<String, Problem> {
        do {
            let parsed = try load(key)
            return .success(publicLine(parsed.publicKey, comment: parsed.comment))
        } catch let problem as Problem {
            return .failure(problem)
        } catch {
            return .failure(.unreadable("\(error)"))
        }
    }

    /// The signers the worker offers, in order: the certificate (when the
    /// key has one that loads) and then the bare key — a server that does
    /// not trust the CA may still have the key in authorized_keys. `label`
    /// names them in notices; a certificate that cannot be used is reported
    /// through `problem` and the bare key is still offered.
    static func signers(_ key: StoredKey, label: String, problem: (String) -> Void = { _ in }) throws -> [SSHSigner] {
        let bare = PrivateKeySigner(try load(key), label: label)
        guard let line = key.certificate?.trimmingCharacters(in: .whitespacesAndNewlines), !line.isEmpty else { return [bare] }
        do {
            let cert = try SSHPublicKey(certificateLine: line)
            if let info = cert.certificate, !info.isValid(at: Date()) {
                problem("certificate of \(label) is outside its validity period")
            }
            return [try CertificateSigner(certificate: cert, signer: bare, label: "certificate of \(label)"), bare]
        } catch {
            problem("certificate of \(label) could not be used (\(error))")
            return [bare]
        }
    }

    enum CertificateProblem: Error, Equatable {
        case unreadable(String)
        /// A host certificate, not a user one.
        case notUserCertificate
        /// Signed for another key than the credential's.
        case otherKey
    }

    /// Checks a `-cert.pub` line against the credential's public key line.
    static func inspectCertificate(_ line: String, publicKey: String?) -> Result<SSHCertificateInfo, CertificateProblem> {
        let cert: SSHPublicKey
        do { cert = try SSHPublicKey(certificateLine: line.trimmingCharacters(in: .whitespacesAndNewlines)) }
        catch { return .failure(.unreadable(describe(error))) }
        guard let info = cert.certificate else { return .failure(.unreadable("not a certificate")) }
        guard info.isUserCertificate else { return .failure(.notUserCertificate) }
        if let publicKey, let bare = try? SSHPublicKey(openSSHLine: publicKey), !cert.sameKey(as: bare) {
            return .failure(.otherKey)
        }
        return .success(info)
    }

    /// "ED25519 · …nqgejF0" — the type and the fingerprint's last 8, for the
    /// editor's key box (the whole line is its tooltip).
    static func shortSummary(ofPublicLine line: String) -> String? {
        guard let full = summary(ofPublicLine: line), let dot = full.range(of: " · ") else { return nil }
        let fingerprint = full[dot.upperBound...]
        return String(full[..<dot.lowerBound]) + " · …" + String(fingerprint.suffix(8))
    }

    /// "Certificate · id · until 5 Nov 2027" for a credential row; nil when it
    /// does not parse. `compact` drops the leading word (the row is labelled).
    /// Gregorian dates: an expiry is compared with the CA's, which never
    /// writes Buddhist-era years.
    static func certificateSummary(_ line: String, now: Date = Date(), compact: Bool = false) -> String? {
        guard let cert = try? SSHPublicKey(certificateLine: line.trimmingCharacters(in: .whitespacesAndNewlines)),
              let info = cert.certificate else { return nil }
        let until: String
        if info.validBefore == UInt64.max {
            until = String(localized: "no expiry")
        } else {
            let date = Date(timeIntervalSince1970: TimeInterval(min(info.validBefore, UInt64(Int64.max / 2))))
            var style = Date.FormatStyle(date: .abbreviated, time: .omitted)
            style.calendar = Calendar(identifier: .gregorian)
            until = info.isValid(at: now)
                ? String(localized: "until \(date.formatted(style))")
                : String(localized: "expired")
        }
        return ((compact ? [] : [String(localized: "Certificate")]) + [info.keyID, until])
            .filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private static func load(_ key: StoredKey) throws -> SSHPrivateKey {
        let passphrase = key.passphrase.flatMap { $0.isEmpty ? nil : Array($0.utf8) }
        do {
            return try PEMPrivateKey.load(key.text, passphrase: passphrase)
        } catch .passphraseRequired {
            throw Problem.needsPassphrase
        } catch .wrongPassphrase {
            throw Problem.wrongPassphrase
        } catch {
            // A PEM key with the wrong passphrase decrypts to garbage that
            // fails to parse: say "passphrase" when one was given for an
            // encrypted file, not "malformed".
            if passphrase != nil, PEMPrivateKey.isEncrypted(key.text) { throw Problem.wrongPassphrase }
            throw Problem.unreadable(describe(error))
        }
    }

    private static func describe(_ error: SSHKeyError) -> String {
        switch error {
        case .malformed(let why): return why
        case .unsupportedKeyType(let type): return "key type \(type) is not supported"
        case .unsupportedCipher(let cipher): return "cipher \(cipher) is not supported"
        case .unsupportedKDF(let kdf): return "key derivation \(kdf) is not supported"
        case .passphraseRequired: return "a passphrase is required"
        case .wrongPassphrase: return "wrong passphrase"
        }
    }

    /// "<type> <base64>[ comment]" — an authorized_keys line.
    static func publicLine(_ key: SSHPublicKey, comment: String) -> String {
        let trimmed = comment.trimmingCharacters(in: .whitespacesAndNewlines)
        return key.keyType + " " + key.base64 + (trimmed.isEmpty ? "" : " " + trimmed)
    }

    /// "ED25519 · SHA256:…" for a credential row; nil for a line that does not parse.
    static func summary(ofPublicLine line: String) -> String? {
        guard let key = try? SSHPublicKey(openSSHLine: line) else { return nil }
        let type: String
        switch key.kind {
        case .ed25519: type = "ED25519"
        case .ecdsa: type = "ECDSA \(key.bits)"
        case .rsa: type = "RSA \(key.bits)"
        case .dsa: type = "DSA"
        }
        return type + " · " + key.fingerprintSHA256
    }

    /// A new Ed25519 key in OpenSSH's own format ("openssh-key-v1", no
    /// cipher — the vault is what protects it), as `ssh-keygen -t ed25519 -N ''` writes.
    static func generateEd25519(comment: String) -> StoredKey {
        generateEd25519(comment: comment, seed: Curve25519.Signing.PrivateKey().rawRepresentation,
                        check: UInt32.random(in: .min ... .max))
    }

    /// Deterministic core, for the harness.
    static func generateEd25519(comment: String, seed: Data, check: UInt32) -> StoredKey {
        let key = try! Curve25519.Signing.PrivateKey(rawRepresentation: seed)
        let pub = Array(key.publicKey.rawRepresentation)
        var blob = Wire()
        blob.string("ssh-ed25519"); blob.string(pub)
        var priv = Wire()
        priv.uint32(check); priv.uint32(check)
        priv.string("ssh-ed25519"); priv.string(pub)
        priv.string(Array(seed) + pub)
        priv.string(comment)
        var pad: UInt8 = 1
        while priv.bytes.count % 8 != 0 { priv.bytes.append(pad); pad += 1 }
        var file = Wire()
        file.bytes = Array("openssh-key-v1".utf8) + [0]
        file.string("none"); file.string("none"); file.string([UInt8]())
        file.uint32(1)
        file.string(blob.bytes)
        file.string(priv.bytes)
        let base64 = Data(file.bytes).base64EncodedString()
        var lines: [String] = [OpenSSHPrivateKeyFile.armorBegin]
        var rest = Substring(base64)
        while !rest.isEmpty { lines.append(String(rest.prefix(70))); rest = rest.dropFirst(70) }
        lines.append(OpenSSHPrivateKeyFile.armorEnd)
        return StoredKey(text: lines.joined(separator: "\n") + "\n", passphrase: nil)
    }

    private struct Wire {
        var bytes: [UInt8] = []
        mutating func uint32(_ v: UInt32) { bytes += [UInt8(v >> 24), UInt8(v >> 16 & 0xff), UInt8(v >> 8 & 0xff), UInt8(v & 0xff)] }
        mutating func string(_ b: [UInt8]) { uint32(UInt32(b.count)); bytes += b }
        mutating func string(_ s: String) { string(Array(s.utf8)) }
    }
}
