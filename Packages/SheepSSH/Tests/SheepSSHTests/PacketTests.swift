import XCTest
@testable import SheepSSH

final class PacketTests: XCTestCase {
    static func keys(_ cipher: CipherAlgorithm, _ mac: MACAlgorithm?) -> DirectionKeys {
        DirectionKeys(cipher: cipher, mac: cipher.isAEAD ? nil : mac,
                      key: (0..<cipher.keySize).map { UInt8($0) }, iv: (0..<cipher.ivSize).map { UInt8(0xA0 + $0) },
                      macKey: (0..<(mac?.keySize ?? 0)).map { UInt8(0x40 + $0) })
    }

    static var combinations: [(CipherAlgorithm, MACAlgorithm?)] {
        var out: [(CipherAlgorithm, MACAlgorithm?)] = []
        for c in CipherAlgorithm.allCases where c.isAvailable {
            if c.isAEAD { out.append((c, nil)) } else { for m in MACAlgorithm.allCases { out.append((c, m)) } }
        }
        return out
    }

    func pair(_ c: CipherAlgorithm, _ m: MACAlgorithm?) throws -> (PacketProtection, PacketProtection) {
        (try PacketProtection(keys: Self.keys(c, m), encrypting: true), try PacketProtection(keys: Self.keys(c, m), encrypting: false))
    }

    /// Seal a stream of packets, then open them from a buffer fed in odd
    /// pieces, as the socket would.
    func testRoundTripEveryCombination() throws {
        let payloads: [[UInt8]] = [[94], Array(0..<200), [UInt8](repeating: 7, count: 33_000), [1, 2, 3], []]
        for (c, m) in Self.combinations {
            let (out, inp) = try pair(c, m)
            var wire: [UInt8] = []
            for (i, p) in payloads.enumerated() {
                let sealed = try out.seal(payload: p, sequence: UInt32(i) &+ 0xFFFF_FFFE)
                // Whatever is encrypted is whole blocks (the length field
                // excluded when it travels apart).
                let encrypted = sealed.count - out.trailerSize - (out.lengthIsSeparate ? 4 : 0)
                XCTAssertEqual(encrypted % c.blockSize, 0, "\(c.rawValue) \(m?.rawValue ?? "")")
                wire += sealed
            }
            var buffer: [UInt8] = []
            var got: [[UInt8]] = []
            var sequence: UInt32 = 0xFFFF_FFFE
            var cursor = 0
            let pieces = [1, 3, 17, 4096, 5, 100_000]
            var pieceIndex = 0
            while cursor < wire.count {
                let n = min(pieces[pieceIndex % pieces.count], wire.count - cursor)
                pieceIndex += 1
                buffer += wire[cursor..<cursor + n]
                cursor += n
                while let size = try inp.packetSize(in: buffer[...], sequence: sequence), buffer.count >= size {
                    got.append(try inp.open(buffer[0..<size], sequence: sequence))
                    buffer.removeFirst(size)
                    sequence &+= 1
                }
            }
            XCTAssertEqual(got, payloads, "\(c.rawValue) \(m?.rawValue ?? "")")
            XCTAssertTrue(buffer.isEmpty)
        }
    }

    func testNoneProtectionRoundTrip() throws {
        let out = PacketProtection(), inp = PacketProtection()
        let sealed = try out.seal(payload: [20, 1, 2, 3], sequence: 0)
        XCTAssertEqual(sealed.count % 8, 0)
        let size = try XCTUnwrap(try inp.packetSize(in: sealed[...], sequence: 0))
        XCTAssertEqual(size, sealed.count)
        XCTAssertEqual(try inp.open(sealed[...], sequence: 0), [20, 1, 2, 3])
    }

    func testEveryFlippedBitIsCaught() throws {
        for (c, m) in Self.combinations {
            let (out, _) = try pair(c, m)
            let sealed = try out.seal(payload: Array(0..<40), sequence: 5)
            for index in stride(from: 0, to: sealed.count, by: 3) {
                var bad = sealed
                bad[index] ^= 0x04
                let (_, inp) = try pair(c, m)
                do {
                    guard let size = try inp.packetSize(in: bad[...], sequence: 5) else { continue }
                    guard size <= bad.count else { continue }   // a corrupted length just waits for more
                    _ = try inp.open(bad[0..<size], sequence: 5)
                    XCTFail("\(c.rawValue) \(m?.rawValue ?? "") accepted a flip at \(index)")
                } catch {}
            }
            // And the wrong sequence number. AES-GCM (RFC 5647) does not use
            // it — its nonce counter carries the order instead, tested below.
            if c == .aes128GCM || c == .aes256GCM { continue }
            let (_, inp) = try pair(c, m)
            do {
                if let size = try inp.packetSize(in: sealed[...], sequence: 6), size <= sealed.count {
                    _ = try inp.open(sealed[0..<size], sequence: 6)
                    XCTFail("\(c.rawValue) accepted the wrong sequence number")
                }
            } catch {}
        }
    }

    /// Reordered or replayed packets fail for every cipher, GCM included.
    func testReorderAndReplayAreCaught() throws {
        for (c, m) in Self.combinations {
            let (out, _) = try pair(c, m)
            let first = try out.seal(payload: [1, 1, 1], sequence: 0)
            let second = try out.seal(payload: [2, 2, 2], sequence: 1)
            let (_, inp) = try pair(c, m)
            // Deliver the second packet first, at the sequence number the
            // first should have had.
            var rejected = false
            do {
                if let size = try inp.packetSize(in: second[...], sequence: 0), size <= second.count {
                    _ = try inp.open(second[0..<size], sequence: 0)
                } else { rejected = true }
            } catch { rejected = true }
            XCTAssertTrue(rejected, "\(c.rawValue) \(m?.rawValue ?? ""): reordered packet accepted")
            // Replay: the first packet twice.
            let (_, replay) = try pair(c, m)
            let size = try XCTUnwrap(try replay.packetSize(in: first[...], sequence: 0))
            XCTAssertEqual(try replay.open(first[0..<size], sequence: 0), [1, 1, 1])
            rejected = false
            do {
                if let size = try replay.packetSize(in: first[...], sequence: 1), size <= first.count {
                    _ = try replay.open(first[0..<size], sequence: 1)
                } else { rejected = true }
            } catch { rejected = true }
            XCTAssertTrue(rejected, "\(c.rawValue) \(m?.rawValue ?? ""): replayed packet accepted")
        }
    }

    func testLengthLimits() throws {
        let inp = PacketProtection()
        func header(_ length: UInt32) -> [UInt8] {
            var w = SSHWriter()
            w.writeUInt32(length)
            return w.bytes + [4, 0, 0, 0]
        }
        XCTAssertThrowsError(try inp.packetSize(in: header(256 * 1024 + 4)[...], sequence: 0))
        XCTAssertThrowsError(try inp.packetSize(in: header(0xFFFF_FFFF)[...], sequence: 0))
        XCTAssertThrowsError(try inp.packetSize(in: header(3)[...], sequence: 0), "below the 5-byte minimum")
        // Alignment is enforced once encrypted (cleartext kex framing is
        // tolerated, like libssh): ETM, length 13, AES block 16.
        let etm = try PacketProtection(keys: Self.keys(.aes128CTR, .hmacSHA256ETM), encrypting: false)
        XCTAssertThrowsError(try etm.packetSize(in: header(13)[...], sequence: 0), "not block aligned")
        XCTAssertNil(try PacketProtection().packetSize(in: [0, 0][...], sequence: 0), "needs more bytes")
    }

    /// CVE-2008-5161: a bad decrypted length under a non-ETM block cipher
    /// must not fail early; the packet is waited for at full size and then
    /// failed like a MAC error.
    func testBadLengthUnderCBCIsDiscardedNotRejected() throws {
        for (c, m) in [(CipherAlgorithm.aes128CBC, MACAlgorithm.hmacSHA1), (.aes128CTR, .hmacSHA256)] {
            let inp = try PacketProtection(keys: Self.keys(c, m), encrypting: false)
            let garbage = [UInt8](repeating: 0x5A, count: 16)
            let size = try XCTUnwrap(try inp.packetSize(in: garbage[...], sequence: 0), c.rawValue)
            XCTAssertEqual(size, 4 + 256 * 1024 + m.keySize, "waits for a maximum-size packet")
            XCTAssertEqual(try inp.packetSize(in: garbage[...], sequence: 0), size)
            let whole = [UInt8](repeating: 0x5A, count: size)
            XCTAssertThrowsError(try inp.open(whole[...], sequence: 0)) {
                XCTAssertEqual($0 as? PacketError, .macMismatch)
            }
        }
        // ETM and AEAD lengths are not secret: those still fail at once.
        let etm = try PacketProtection(keys: Self.keys(.aes128CTR, .hmacSHA256ETM), encrypting: false)
        XCTAssertThrowsError(try etm.packetSize(in: [0xFF, 0xFF, 0xFF, 0xFF][...], sequence: 0))
    }

    func testLooseCleartextFramingIsAcceptedLikeLibssh() throws {
        // Before any cipher: padding under 4 and a length that is not a
        // multiple of 8 are tolerated (old embedded stacks send them).
        let packet: [UInt8] = [0, 0, 0, 12, 3] + [UInt8](repeating: 9, count: 11)
        let inp = PacketProtection()
        XCTAssertEqual(try inp.packetSize(in: packet[...], sequence: 0), 16)
        XCTAssertEqual(try inp.open(packet[...], sequence: 0), [UInt8](repeating: 9, count: 8))
        let unaligned: [UInt8] = [0, 0, 0, 9, 4, 20] + [UInt8](repeating: 0, count: 7)
        XCTAssertEqual(try PacketProtection().packetSize(in: unaligned[...], sequence: 0), 13)
        XCTAssertEqual(try PacketProtection().open(unaligned[...], sequence: 0), [20, 0, 0, 0])
        let overlong: [UInt8] = [0, 0, 0, 12, 12] + [UInt8](repeating: 9, count: 11)
        _ = try PacketProtection().packetSize(in: overlong[...], sequence: 0)
        XCTAssertThrowsError(try PacketProtection().open(overlong[...], sequence: 0))
    }

    func testGCMInvocationCounterCarries() {
        let n: [UInt8] = [1, 2, 3, 4, 0, 0, 0, 0, 0, 0, 0xFF, 0xFF]
        XCTAssertEqual(PacketProtection.incrementInvocation(n), [1, 2, 3, 4, 0, 0, 0, 0, 0, 1, 0, 0])
        let top: [UInt8] = [1, 2, 3, 4] + [UInt8](repeating: 0xFF, count: 8)
        XCTAssertEqual(PacketProtection.incrementInvocation(top), [1, 2, 3, 4] + [UInt8](repeating: 0, count: 8),
                       "the fixed field never changes")
    }
}
