import XCTest
@testable import SheepSSH

final class CipherTests: XCTestCase {
    /// RFC 8439 §2.4.2. Its nonce's first four bytes are zero, so the
    /// original layout with (counter 1, nonce = last 8 bytes) is identical.
    func testChaCha20RFC8439() {
        let key = hex("000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f")
        let nonce = hex("0000004a00000000")
        var data = Array("Ladies and Gentlemen of the class of '99: If I could offer you only one tip for the future, sunscreen would be it.".utf8)
        ChaCha20(key: key).apply(nonce: nonce, counter: 1, to: &data)
        XCTAssertEqual(hex(data), """
            6e2e359a2568f98041ba0728dd0d6981e97e7aec1d4360c20a27afccfd9fae0bf91b65c5524733ab8f593dabcd62b3571639d624e65152ab8f530c359f0861d807ca0dbf500d6a6156a38e088a22b65e52bc514d16ccf806818ce91ab77937365af90bbf74a35be6b40b8eedf2785e42874d
            """)
    }

    func testChaCha20Vectors() {
        for v in Vectors.chacha20 {
            var data = hex(v.plain)
            ChaCha20(key: hex(v.key)).apply(nonce: hex(v.nonce), counter: v.counter, to: &data)
            XCTAssertEqual(hex(data), v.cipher, "counter \(v.counter)")
        }
    }

    /// RFC 8439 §2.5.2.
    func testPoly1305RFC8439() {
        let key = hex("85d6be7857556d337f4452fe42d506a80103808afb0db2fd4abff6af4149f51b")
        let msg = Array("Cryptographic Forum Research Group".utf8)
        XCTAssertEqual(hex(Poly1305.tag(message: msg, key: key)), "a8061dc1305136c6c22b8baf0c0127a9")
    }

    func testPoly1305Vectors() {
        for v in Vectors.poly1305 {
            let tag = Poly1305.tag(message: hex(v.message), key: hex(v.key))
            XCTAssertEqual(hex(tag), v.tag, "key \(v.key) len \(v.message.count / 2)")
            XCTAssertTrue(Poly1305.verify(tag: hex(v.tag), message: hex(v.message), key: hex(v.key)))
        }
    }

    func testPoly1305OnSlices() {
        let v = Vectors.poly1305[5]
        let padded = [0xAA] + hex(v.message) + [0xBB]
        XCTAssertEqual(hex(Poly1305.tag(message: padded[1..<(padded.count - 1)], key: hex(v.key))), v.tag)
    }

    func testChaChaPolyOpenSSHVectors() throws {
        for v in Vectors.chachaPolyOpenSSH {
            let cipher = ChaChaPolyOpenSSH(key: hex(v.key))
            let sealed = cipher.seal(sequenceNumber: v.seq, aadLength: v.aad, plaintext: hex(v.plain))
            XCTAssertEqual(hex(sealed), v.sealed)
            XCTAssertEqual(try cipher.open(sequenceNumber: v.seq, aadLength: v.aad, sealed: sealed), hex(v.plain))
            if v.aad == 4 {
                let length = cipher.decryptLength(sequenceNumber: v.seq, encrypted: sealed[0..<4])
                XCTAssertEqual(Int(length), hex(v.plain).count - 4)
            }
        }
    }

    func testChaChaPolyRejectsTamperingAndWrongSequence() {
        let v = Vectors.chachaPolyOpenSSH[1]
        let cipher = ChaChaPolyOpenSSH(key: hex(v.key))
        let sealed = hex(v.sealed)
        for index in [0, 3, 4, sealed.count / 2, sealed.count - 1] {
            var bad = sealed
            bad[index] ^= 0x01
            XCTAssertThrowsError(try cipher.open(sequenceNumber: v.seq, sealed: bad)) {
                XCTAssertEqual($0 as? ChaChaPolyError, .authenticationFailed)
            }
        }
        XCTAssertThrowsError(try cipher.open(sequenceNumber: v.seq + 1, sealed: sealed))
        XCTAssertThrowsError(try cipher.open(sequenceNumber: v.seq, sealed: Array(sealed[0..<10]))) {
            XCTAssertEqual($0 as? ChaChaPolyError, .truncated)
        }
    }

    func testAESStreamVectorsWholeAndChunked() throws {
        for v in Vectors.aes {
            let encryptMode: AESStream.Mode = v.mode == "ctr" ? .ctr : .cbcEncrypt
            let decryptMode: AESStream.Mode = v.mode == "ctr" ? .ctr : .cbcDecrypt
            XCTAssertEqual(hex(try AESStream(mode: encryptMode, key: hex(v.key), iv: hex(v.iv)).process(hex(v.plain))), v.cipher)
            // Split in packet-sized pieces: the stream must continue across calls.
            let enc = try AESStream(mode: encryptMode, key: hex(v.key), iv: hex(v.iv))
            let dec = try AESStream(mode: decryptMode, key: hex(v.key), iv: hex(v.iv))
            let plain = hex(v.plain)
            var produced: [UInt8] = [], recovered: [UInt8] = []
            for range in [0..<16, 16..<48, 48..<64, 64..<96] {
                let c = try enc.process(Array(plain[range]))
                produced += c
                recovered += try dec.process(c)
            }
            XCTAssertEqual(hex(produced), v.cipher, v.mode)
            XCTAssertEqual(recovered, plain, v.mode)
        }
    }

    func testAESRejectsBadSizes() {
        XCTAssertThrowsError(try AESStream(mode: .ctr, key: [UInt8](repeating: 0, count: 20), iv: [UInt8](repeating: 0, count: 16)))
        XCTAssertThrowsError(try AESStream(mode: .ctr, key: [UInt8](repeating: 0, count: 16), iv: [UInt8](repeating: 0, count: 12)))
        let cbc = try! AESStream(mode: .cbcDecrypt, key: [UInt8](repeating: 0, count: 16), iv: [UInt8](repeating: 0, count: 16))
        XCTAssertThrowsError(try cbc.process([1, 2, 3])) { XCTAssertEqual($0 as? AESError, .notBlockAligned) }
    }

    func testAESGCMRoundTripAndTamper() throws {
        let key = [UInt8](repeating: 7, count: 32), nonce = [UInt8](repeating: 9, count: 12)
        let (c, tag) = try AESGCM.seal(key: key, nonce: nonce, aad: [1, 2], plaintext: Array("hello".utf8))
        XCTAssertEqual(try AESGCM.open(key: key, nonce: nonce, aad: [1, 2], ciphertext: c, tag: tag), Array("hello".utf8))
        var badTag = tag
        badTag[0] ^= 1
        XCTAssertThrowsError(try AESGCM.open(key: key, nonce: nonce, aad: [1, 2], ciphertext: c, tag: badTag)) {
            XCTAssertEqual($0 as? AESError, .authenticationFailed)
        }
        XCTAssertThrowsError(try AESGCM.open(key: key, nonce: nonce, aad: [1, 3], ciphertext: c, tag: tag))
    }

    func testConstantTimeEqual() {
        XCTAssertTrue(constantTimeEqual([1, 2, 3], [1, 2, 3]))
        XCTAssertFalse(constantTimeEqual([1, 2, 3], [1, 2, 4]))
        XCTAssertFalse(constantTimeEqual([1, 2, 3], [1, 2]))
        XCTAssertTrue(constantTimeEqual([UInt8](), [UInt8]()))
    }
}
