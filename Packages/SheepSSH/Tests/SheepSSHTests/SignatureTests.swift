import Foundation
import XCTest
@testable import SheepSSH

final class SignatureTests: XCTestCase {
    func verify(_ v: (keyLine: String, algorithm: String, data: String, signature: String),
                data: [UInt8]? = nil, signature: [UInt8]? = nil, algorithm: HostKeyAlgorithm? = nil) throws {
        let key = try SSHPublicKey(openSSHLine: v.keyLine)
        try SignatureVerifier.verify(signatureBlob: signature ?? hex(v.signature), data: data ?? hex(v.data), key: key,
                                     algorithm: algorithm ?? HostKeyAlgorithm(rawValue: v.algorithm)!)
    }

    func testEverySignatureFromPycaVerifies() throws {
        var seen = Set<String>()
        for v in Vectors.signatures {
            XCTAssertNoThrow(try verify(v), "\(v.algorithm) \(v.keyLine.prefix(40))")
            seen.insert(v.algorithm)
        }
        XCTAssertEqual(seen, Set(HostKeyAlgorithm.allCases.map(\.rawValue)))
    }

    func testAnyChangedBitFails() throws {
        for v in Vectors.signatures {
            var data = hex(v.data)
            data[0] ^= 1
            XCTAssertThrowsError(try verify(v, data: data), v.algorithm) { XCTAssertEqual($0 as? SignatureError, .invalid) }
            var sig = hex(v.signature)
            sig[sig.count - 5] ^= 0x10
            XCTAssertThrowsError(try verify(v, signature: sig), v.algorithm)
        }
    }

    func testSignatureMustNameTheNegotiatedAlgorithm() throws {
        let rsa = Vectors.signatures.first { $0.algorithm == "rsa-sha2-256" }!
        XCTAssertThrowsError(try verify(rsa, algorithm: .rsaSHA512)) {
            XCTAssertEqual($0 as? SignatureError, .algorithmMismatch(expected: "rsa-sha2-512", got: "rsa-sha2-256"))
        }
        // A signature re-labelled as another hash must not verify either.
        var relabelled = SSHWriter()
        relabelled.writeString("rsa-sha2-512")
        var r = SSHReader(hex(rsa.signature))
        _ = try r.readString()
        relabelled.writeString(try r.readString())
        XCTAssertThrowsError(try verify(rsa, signature: relabelled.bytes, algorithm: .rsaSHA512))
        let ed = Vectors.signatures.first { $0.algorithm == "ssh-ed25519" }!
        XCTAssertThrowsError(try verify(ed, algorithm: .ecdsaP256)) {
            XCTAssertEqual($0 as? SignatureError, .keyTypeMismatch(expected: "ecdsa-sha2-nistp256", got: "ssh-ed25519"))
        }
    }

    func testShortRSASignatureIsPaddedLikeOpenSSH() throws {
        let short = Vectors.signatures.first { v in
            guard v.algorithm == "rsa-sha2-256" else { return false }
            var r = SSHReader(hex(v.signature))
            _ = try? r.readString()
            return (try? r.readString())?.count == 127
        }
        XCTAssertNotNil(short, "the generator emits one signature with its leading zero dropped")
        if let short { XCTAssertNoThrow(try verify(short)) }
    }

    func testRSASignatureLongerThanModulusOrNotBelowItFails() throws {
        let v = Vectors.signatures.first { $0.algorithm == "rsa-sha2-256" }!
        var r = SSHReader(hex(v.signature))
        _ = try r.readString()
        let raw = try r.readString()
        var long = SSHWriter()
        long.writeString("rsa-sha2-256")
        long.writeString([0] + raw)
        XCTAssertThrowsError(try verify(v, signature: long.bytes))
        var huge = SSHWriter()
        huge.writeString("rsa-sha2-256")
        huge.writeString([UInt8](repeating: 0xFF, count: raw.count))
        XCTAssertThrowsError(try verify(v, signature: huge.bytes))
    }

    /// A huge public exponent would make verification cost seconds of CPU.
    func testHugeRSAExponentIsRefusedCheaply() throws {
        let n = (BigUInt(1) << 16383) + BigUInt(1)
        let e = (BigUInt(1) << 16000) + BigUInt(1)
        let t0 = Date()
        XCTAssertThrowsError(try SignatureVerifier.verifyRSA(e: e, n: n, hash: .sha256,
                                                             signature: [UInt8](repeating: 1, count: 2048), data: [1]))
        XCTAssertLessThan(Date().timeIntervalSince(t0), 0.1)
    }

    func testMalformedSignatureBlobs() throws {
        let v = Vectors.signatures.first { $0.algorithm == "ssh-ed25519" }!
        let blob = hex(v.signature)
        for cut in 0..<blob.count {
            XCTAssertThrowsError(try verify(v, signature: Array(blob[0..<cut])))
        }
        XCTAssertThrowsError(try verify(v, signature: blob + [0]))
    }
}
