// chacha20-poly1305@openssh.com (OpenSSH PROTOCOL.chacha20poly1305).
//
// 64 bytes of key material are split in two ChaCha20 keys: K_2 = bytes 0–31
// ("main") encrypts the payload and derives the Poly1305 key, K_1 = bytes
// 32–63 ("header") encrypts only the 4-byte packet length. Both use the packet
// sequence number, big-endian, as the 8-byte nonce. The Poly1305 key is the
// first 32 bytes of the main keystream at block 0; the payload is encrypted
// from block 1. The tag covers the encrypted length and encrypted payload.
//
// The same construction with no header (aadLength 0, sequence number 0)
// encrypts OpenSSH private key files written with `-Z chacha20-poly1305@…`.

public enum ChaChaPolyError: Error, Equatable, Sendable {
    case authenticationFailed
    case truncated
}

public struct ChaChaPolyOpenSSH: Sendable {
    public static let keySize = 64
    public static let tagSize = 16

    private let main: ChaCha20
    private let header: ChaCha20

    public init(key: [UInt8]) {
        precondition(key.count == Self.keySize, "chacha20-poly1305@openssh.com needs 64 bytes of key")
        main = ChaCha20(key: Array(key[0..<32]))
        header = ChaCha20(key: Array(key[32..<64]))
    }

    static func nonce(_ sequenceNumber: UInt32) -> [UInt8] {
        let s = UInt64(sequenceNumber)
        return (0..<8).map { UInt8(truncatingIfNeeded: s >> UInt64(56 - 8 * $0)) }
    }

    /// Decrypts just the 4-byte packet length, so the reader knows how much
    /// more to wait for. The value is NOT authenticated until `open` succeeds;
    /// callers must bound it before trusting it.
    public func decryptLength<C: Collection>(sequenceNumber: UInt32, encrypted: C) -> UInt32
    where C.Element == UInt8 {
        precondition(encrypted.count == 4)
        var bytes = Array(encrypted)
        header.apply(nonce: Self.nonce(sequenceNumber), counter: 0, to: &bytes)
        return UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16 | UInt32(bytes[2]) << 8 | UInt32(bytes[3])
    }

    /// Encrypts `plaintext` (for a packet: the 4-byte length followed by the
    /// rest) and appends the tag. The first `aadLength` bytes go under the
    /// header key, the rest under the main key.
    public func seal(sequenceNumber: UInt32, aadLength: Int = 4, plaintext: [UInt8]) -> [UInt8] {
        precondition(aadLength >= 0 && aadLength <= plaintext.count)
        let nonce = Self.nonce(sequenceNumber)
        let polyKey = main.keystream(nonce: nonce, counter: 0, count: 32)
        // One buffer, encrypted in place (it was three copies per packet).
        var out = [UInt8]()
        out.reserveCapacity(plaintext.count + Self.tagSize)
        out.append(contentsOf: plaintext)
        header.apply(nonce: nonce, counter: 0, to: &out, range: 0..<aadLength)
        main.apply(nonce: nonce, counter: 1, to: &out, range: aadLength..<out.count)
        out.append(contentsOf: Poly1305.tag(message: out, key: polyKey))
        return out
    }

    /// Verifies the tag, then decrypts. Nothing is decrypted when the tag is
    /// wrong.
    public func open(sequenceNumber: UInt32, aadLength: Int = 4, sealed: [UInt8]) throws(ChaChaPolyError) -> [UInt8] {
        try open(sequenceNumber: sequenceNumber, aadLength: aadLength, sealed: sealed[...])
    }

    /// The same on a slice of the receive buffer: the tag is checked in
    /// place, then the text is copied ONCE and decrypted in place (it was
    /// four copies per packet).
    public func open(sequenceNumber: UInt32, aadLength: Int = 4, sealed: ArraySlice<UInt8>) throws(ChaChaPolyError) -> [UInt8] {
        guard sealed.count >= aadLength + Self.tagSize else { throw .truncated }
        let nonce = Self.nonce(sequenceNumber)
        let polyKey = main.keystream(nonce: nonce, counter: 0, count: 32)
        let bodyEnd = sealed.endIndex - Self.tagSize
        let tag = Array(sealed[bodyEnd...])
        guard Poly1305.verify(tag: tag, message: sealed[sealed.startIndex..<bodyEnd], key: polyKey) else {
            throw .authenticationFailed
        }
        var out = Array(sealed[sealed.startIndex..<bodyEnd])
        header.apply(nonce: nonce, counter: 0, to: &out, range: 0..<aadLength)
        main.apply(nonce: nonce, counter: 1, to: &out, range: aadLength..<out.count)
        return out
    }
}
