import CryptoKit
import XCTest
@testable import SheepSync

final class VaultCryptoTests: XCTestCase {
    private func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }

    /// RFC 7914 §11 vectors, cross-checked with Python's hashlib.pbkdf2_hmac
    /// (OpenSSL), plus one at the production iteration count.
    func testPBKDF2MatchesReferenceVectors() throws {
        XCTAssertEqual(hex(try PassphraseKDF.pbkdf2SHA256(password: Data("passwd".utf8), salt: Data("salt".utf8),
                                                          iterations: 1, length: 64)),
                       "55ac046e56e3089fec1691c22544b605f94185216dde0465e68b9d57c20dacbc49ca9cccf179b645991664b39d77ef317c71b845b1e30bd509112041d3a19783")
        XCTAssertEqual(hex(try PassphraseKDF.pbkdf2SHA256(password: Data("Password".utf8), salt: Data("NaCl".utf8),
                                                          iterations: 80000, length: 64)),
                       "4ddcd8f60b98be21830cee5ef22701f9641a4418d04c0414aeff08876b34ab56a1d425a1225833549adb841b51c9b3176a272bdebba1d078478f62b397f33c8d")
        XCTAssertEqual(hex(try PassphraseKDF.pbkdf2SHA256(password: Data("sheep vault".utf8), salt: Data(0..<16),
                                                          iterations: 600_000, length: 32)),
                       "f275a6b59a9a49687ada47cb47878dc043b43a176dd2e8aa96bbff4fb96810b2")
    }

    func testPassphraseIsNormalisedBeforeDerivation() {
        // é precomposed vs e + combining acute: the same passphrase.
        XCTAssertEqual(PassphraseKDF.passphraseBytes("caf\u{e9}"), PassphraseKDF.passphraseBytes("cafe\u{301}"))
    }

    func testKeyFileRoundTripAndWrongPassphrase() throws {
        let (file, key) = try VaultKeyFile.create(passphrase: "correct horse", iterations: 1000)
        let decoded = try JSONDecoder().decode(VaultKeyFile.self, from: try JSONEncoder().encode(file))
        XCTAssertEqual(decoded, file)
        let opened = try decoded.unwrap(passphrase: "correct horse")
        XCTAssertEqual(opened.withUnsafeBytes { Data($0) }, key.withUnsafeBytes { Data($0) })
        XCTAssertThrowsError(try decoded.unwrap(passphrase: "correct horsE")) {
            XCTAssertEqual($0 as? VaultCryptoError, .wrongPassphrase)
        }
        // The wrapped bytes never contain the key itself.
        XCTAssertNil(decoded.wrappedKey.range(of: key.withUnsafeBytes { Data($0) }))
    }

    func testRewrapKeepsTheKeyAndDropsTheOldPassphrase() throws {
        let (file, key) = try VaultKeyFile.create(passphrase: "old", iterations: 1000)
        let moved = try file.rewrapped(key, newPassphrase: "new")
        XCTAssertEqual(moved.keyID, file.keyID)
        XCTAssertNotEqual(moved.salt, file.salt)
        XCTAssertEqual(try moved.unwrap(passphrase: "new").withUnsafeBytes { Data($0) },
                       key.withUnsafeBytes { Data($0) })
        XCTAssertThrowsError(try moved.unwrap(passphrase: "old"))
    }

    func testKeyFileFromTheFutureOrTamperedIsRefused() throws {
        var (file, _) = try VaultKeyFile.create(passphrase: "p", iterations: 1000)
        var future = file
        future.format = 99
        XCTAssertThrowsError(try future.unwrap(passphrase: "p")) {
            XCTAssertEqual($0 as? VaultCryptoError, .unsupportedFormat(99))
        }
        file.wrappedKey[file.wrappedKey.count - 1] ^= 1
        XCTAssertThrowsError(try file.unwrap(passphrase: "p")) {
            XCTAssertEqual($0 as? VaultCryptoError, .wrongPassphrase)
        }
        var silly = file
        silly.iterations = 0
        XCTAssertThrowsError(try silly.unwrap(passphrase: "p"))
    }

    func testSealedBlobsAreBoundToTheirContext() throws {
        let sealer = VaultSealer(vaultKey: SymmetricKey(size: .bits256))
        let sealed = try sealer.seal(Data("hosts".utf8), context: "a")
        XCTAssertEqual(try sealer.open(sealed, context: "a"), Data("hosts".utf8))
        XCTAssertThrowsError(try sealer.open(sealed, context: "b"))
        var tampered = sealed
        tampered[10] ^= 0x40
        XCTAssertThrowsError(try sealer.open(tampered, context: "a"))
        XCTAssertThrowsError(try sealer.open(Data("SSV1".utf8), context: "a"))
        XCTAssertThrowsError(try VaultSealer(vaultKey: SymmetricKey(size: .bits256)).open(sealed, context: "a"))
    }

    func testDigestIsKeyedAndSeparatesIdFromPayload() {
        let key = SymmetricKey(size: .bits256)
        let a = VaultSealer(vaultKey: key)
        XCTAssertEqual(a.digest(id: "x", payload: Data("1".utf8)), a.digest(id: "x", payload: Data("1".utf8)))
        XCTAssertNotEqual(a.digest(id: "x", payload: Data("1".utf8)), a.digest(id: "x1", payload: Data()))
        XCTAssertNotEqual(a.digest(id: "x", payload: Data("1".utf8)),
                          VaultSealer(vaultKey: SymmetricKey(size: .bits256)).digest(id: "x", payload: Data("1".utf8)))
    }
}
