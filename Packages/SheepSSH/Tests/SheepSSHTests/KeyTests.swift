import XCTest
@testable import SheepSSH

final class KeyTests: XCTestCase {
    func testEveryKeyFileParsesAndDecrypts() throws {
        for v in Vectors.keyFiles {
            let file = try OpenSSHPrivateKeyFile(text: v.privateText)
            let pub = try SSHPublicKey(openSSHLine: v.publicLine)
            XCTAssertEqual(file.publicKey.blob, pub.blob, v.name)
            XCTAssertEqual(pub.fingerprintSHA256, v.fingerprint, v.name)
            XCTAssertEqual(pub.bits, v.bits, v.name)
            XCTAssertEqual(file.isEncrypted, v.passphrase != nil, v.name)
            let key = try file.decrypt(passphrase: v.passphrase.map { Array($0.utf8) })
            XCTAssertEqual(key.comment, "sheep@\(v.name)")
            XCTAssertEqual(key.publicKey.blob, pub.blob)
            switch key.kind {
            case .ed25519(let seed): XCTAssertEqual(seed.count, 32)
            case .ecdsa(let curve, let scalar): XCTAssertEqual(scalar.count, curve.coordinateSize)
            case .rsa(let n, _, _, _, let p, let q): XCTAssertEqual(p * q, n)
            }
        }
    }

    func testRSAKeyWithATrivialFactorIsRefused() {
        // p = 1, q = n multiplies to n but would divide by zero building the
        // signer (d mod (p − 1)) — a trap that took down every tab.
        let n = BigUInt(hex: "c5a1" + String(repeating: "37", count: 126) + "01")!
        let fields = [BigUInt(), n, BigUInt(65537), BigUInt(3), BigUInt(1), n, BigUInt(1), BigUInt(1), BigUInt(1)]
        let der = DERWriter.sequence(fields.map(DERWriter.integer).reduce([], +))
        XCTAssertThrowsError(try PEMPrivateKey.parsePKCS1(der)) {
            guard case .malformed? = $0 as? SSHKeyError else { return XCTFail("\($0)") }
        }
    }

    func testOddLengthLegacyIVIsRefusedNotTrapped() {
        // "ABC" parses as 0x0ABC — two bytes where one was asked for, which
        // trapped in bigEndianBytes(count:).
        for iv in ["ABC", String(repeating: "A", count: 33), "00"] {
            XCTAssertThrowsError(try PEMPrivateKey.decryptLegacy([UInt8](repeating: 0, count: 32), dekInfo: "AES-128-CBC,\(iv)",
                                                                  passphrase: Array("x".utf8)), iv)
        }
    }

    func testWrongOrMissingPassphrase() throws {
        for v in Vectors.keyFiles where v.passphrase != nil {
            let file = try OpenSSHPrivateKeyFile(text: v.privateText)
            XCTAssertThrowsError(try file.decrypt(passphrase: Array("wrong".utf8)), v.name) {
                XCTAssertEqual($0 as? SSHKeyError, .wrongPassphrase, v.name)
            }
            XCTAssertThrowsError(try file.decrypt(passphrase: nil)) {
                XCTAssertEqual($0 as? SSHKeyError, .passphraseRequired)
            }
        }
    }

    func testPublicKeyKinds() throws {
        var seen: Set<String> = []
        for v in Vectors.keyFiles {
            let pub = try SSHPublicKey(openSSHLine: v.publicLine)
            seen.insert(pub.keyType)
            switch pub.kind {
            case .ed25519(let k): XCTAssertEqual(k.count, 32)
            case .ecdsa(let curve, let point):
                XCTAssertEqual(point.count, curve.pointSize)
                XCTAssertEqual(pub.keyType, curve.keyType)
            case .rsa(let e, _): XCTAssertEqual(e, BigUInt(65537))
            case .dsa: XCTFail("no DSA keys generated")
            }
        }
        XCTAssertEqual(seen, ["ssh-ed25519", "ecdsa-sha2-nistp256", "ecdsa-sha2-nistp384", "ecdsa-sha2-nistp521", "ssh-rsa"])
    }

    func testMalformedInputsAreRefusedNotTrapped() throws {
        let v = Vectors.keyFiles[0]
        XCTAssertThrowsError(try OpenSSHPrivateKeyFile(text: "hello"))
        XCTAssertThrowsError(try SSHPublicKey(openSSHLine: "ssh-rsa " + v.publicLine.split(separator: " ")[1]),
                             "type word must match the blob")
        XCTAssertThrowsError(try SSHPublicKey(openSSHLine: "ssh-ed25519 !!!!"))
        XCTAssertThrowsError(try SSHPublicKey(blob: [0, 0, 0, 3, 0x61, 0x62, 0x63])) {
            XCTAssertEqual($0 as? SSHKeyError, .unsupportedKeyType("abc"))
        }
        // Every truncation of every key file and every public blob must throw
        // cleanly (never trap).
        for v in Vectors.keyFiles {
            let pub = try SSHPublicKey(openSSHLine: v.publicLine)
            for cut in 0..<pub.blob.count {
                XCTAssertThrowsError(try SSHPublicKey(blob: Array(pub.blob[0..<cut])))
            }
            XCTAssertThrowsError(try SSHPublicKey(blob: pub.blob + [0]), "trailing byte")
            let body = v.privateText.split(separator: "\n").dropFirst().dropLast().joined()
            let binary = Array(Data(base64Encoded: body)!)
            for cut in stride(from: 0, to: binary.count, by: 7) {
                if let file = try? OpenSSHPrivateKeyFile(binary: Array(binary[0..<cut])) {
                    _ = try? file.decrypt(passphrase: v.passphrase.map { Array($0.utf8) })
                    XCTFail("\(v.name) truncated at \(cut) parsed")
                }
            }
        }
    }

    func testOversizedModulusIsRefused() {
        var w = SSHWriter()
        w.writeString("ssh-rsa")
        w.writeMPInt(BigUInt(65537))
        w.writeMPInt((BigUInt(1) << 16384) + BigUInt(1))
        XCTAssertThrowsError(try SSHPublicKey(blob: w.bytes))
        w = SSHWriter()
        w.writeString("ssh-rsa")
        w.writeMPInt(BigUInt(65537))
        w.writeMPInt((BigUInt(1) << 16383) + BigUInt(1))
        XCTAssertNoThrow(try SSHPublicKey(blob: w.bytes))
    }

    func testBitFlipsInThePrivateSectionAreCaught() throws {
        // Unencrypted ed25519: flipping a byte of the private half must not
        // produce a key that silently differs from its public half.
        let v = Vectors.keyFiles.first { $0.name == "ed25519" }!
        let file = try OpenSSHPrivateKeyFile(text: v.privateText)
        var section = file.privateSection
        section[8 + 4 + 11 + 4 + 32 + 4 + 40] ^= 1   // inside the public copy in sk
        XCTAssertThrowsError(try OpenSSHPrivateKeyFile.parsePrivateSection(section, expectedPublic: file.publicKey, blockSize: 8))
    }
}

import Foundation
