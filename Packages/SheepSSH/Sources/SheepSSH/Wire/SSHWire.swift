// SSH wire encoding, RFC 4251 §5: byte, boolean, uint32, uint64, string,
// mpint, name-list. Everything the protocol and the key formats read or write
// goes through these two types, so a length that runs past the end of the
// buffer is caught in exactly one place.

public enum SSHWireError: Error, Equatable, Sendable {
    /// A field claims more bytes than are left.
    case truncated
    /// An mpint with its sign bit set. SSH never sends a negative number
    /// where SheepSSH reads one, so it is refused rather than interpreted.
    case negativeMPInt
    /// Kept for source compatibility; no longer thrown (redundant leading
    /// zeros are trimmed, as OpenSSH does).
    case nonMinimalMPInt
    /// A string that should be text is not valid UTF-8.
    case invalidUTF8
    /// A name-list entry is empty or contains a byte outside printable ASCII.
    case invalidNameList
    /// A boolean or enum field holds a value the format does not define.
    case invalidValue
}

/// Reads SSH wire fields from a byte array. Value type: copying it forks the
/// read position, which the key parsers use to peek.
public struct SSHReader: Sendable {
    public let bytes: [UInt8]
    public private(set) var offset: Int

    public init(_ bytes: [UInt8]) {
        self.bytes = bytes
        self.offset = 0
    }

    public init<S: Sequence>(_ bytes: S) where S.Element == UInt8 {
        self.init(Array(bytes))
    }

    /// Reads `bytes` from `offset` on without copying them (a message body
    /// after its type byte: `dropFirst()` went through the Sequence init
    /// and copied every packet once more on the receive path).
    public init(_ bytes: [UInt8], from offset: Int) {
        precondition(offset >= 0 && offset <= bytes.count, "SSHReader offset out of range")
        self.bytes = bytes
        self.offset = offset
    }

    public var remaining: Int { bytes.count - offset }
    public var isAtEnd: Bool { offset == bytes.count }
    /// The unread tail.
    public var rest: ArraySlice<UInt8> { bytes[offset...] }

    public mutating func readByte() throws(SSHWireError) -> UInt8 {
        guard remaining >= 1 else { throw .truncated }
        defer { offset += 1 }
        return bytes[offset]
    }

    /// RFC 4251: any non-zero value is TRUE. Accepted as such.
    public mutating func readBool() throws(SSHWireError) -> Bool {
        try readByte() != 0
    }

    public mutating func readUInt32() throws(SSHWireError) -> UInt32 {
        guard remaining >= 4 else { throw .truncated }
        var v: UInt32 = 0
        for i in 0..<4 { v = v << 8 | UInt32(bytes[offset + i]) }
        offset += 4
        return v
    }

    public mutating func readUInt64() throws(SSHWireError) -> UInt64 {
        guard remaining >= 8 else { throw .truncated }
        var v: UInt64 = 0
        for i in 0..<8 { v = v << 8 | UInt64(bytes[offset + i]) }
        offset += 8
        return v
    }

    /// Exactly `count` raw bytes (no length prefix).
    public mutating func readBytes(_ count: Int) throws(SSHWireError) -> [UInt8] {
        guard count >= 0, remaining >= count else { throw .truncated }
        defer { offset += count }
        return Array(bytes[offset..<offset + count])
    }

    /// A length-prefixed string meant for a human (banners, prompts,
    /// messages). Decoded leniently: network gear sends Latin-1 and CP437 in
    /// its banners, and libssh showed them — invalid bytes become U+FFFD
    /// instead of failing the connection.
    public mutating func readText() throws(SSHWireError) -> String {
        String(decoding: try readString(), as: UTF8.self)
    }

    /// A length-prefixed string as raw bytes.
    public mutating func readString() throws(SSHWireError) -> [UInt8] {
        let length = try readUInt32()
        // Compared as UInt64-safe Int: on 64-bit, UInt32 always fits.
        guard Int(length) <= remaining else { throw .truncated }
        return try readBytes(Int(length))
    }

    /// A length-prefixed string that must be UTF-8 text.
    public mutating func readUTF8() throws(SSHWireError) -> String {
        let raw = try readString()
        guard let s = String(validating: raw, as: UTF8.self) else { throw .invalidUTF8 }
        return s
    }

    /// A comma-separated name-list. An empty string is an empty list.
    public mutating func readNameList() throws(SSHWireError) -> [String] {
        let raw = try readString()
        if raw.isEmpty { return [] }
        // RFC 4251 §5 says non-empty US-ASCII names, but embedded servers
        // send "a,b," or a stray space, and OpenSSH and libssh just split on
        // commas: empty entries are dropped and names trimmed. A name that is
        // still odd simply matches nothing in negotiation.
        return raw.split(separator: UInt8(ascii: ",")).compactMap { part in
            let name = String(decoding: part, as: UTF8.self).trimmingCharacters(in: .whitespaces)
            return name.isEmpty ? nil : name
        }
    }

    /// A non-negative mpint as its magnitude, big-endian with no leading zeros.
    /// RFC 4251 forbids redundant leading zero bytes, but OpenSSH
    /// (sshbuf_get_bignum2) and libssh both trim them, and embedded servers
    /// that pad to a fixed width exist — so they are trimmed here too. Only a
    /// set sign bit (a negative number) is refused.
    /// `allowingSignBit`: for values that can only be positive (RSA/DSA
    /// public key fields, ECDSA r and s) the top bit is read as magnitude,
    /// not sign — firmware that writes fixed-width bignums without the 0x00
    /// prefix is accepted, as libssh (BN_bin2bn) does; the raw bytes are what
    /// K_S hashes anyway.
    public mutating func readMPIntBytes(allowingSignBit: Bool = false) throws(SSHWireError) -> [UInt8] {
        let raw = try readString()
        guard let first = raw.first else { return [] }
        if first & 0x80 != 0, !allowingSignBit { throw .negativeMPInt }
        return Array(raw.drop(while: { $0 == 0 }))
    }

    public mutating func readMPInt() throws(SSHWireError) -> BigUInt {
        BigUInt(bigEndian: try readMPIntBytes())
    }

    public mutating func readUnsignedMPInt() throws(SSHWireError) -> BigUInt {
        BigUInt(bigEndian: try readMPIntBytes(allowingSignBit: true))
    }
}

/// Builds SSH wire fields into a byte array.
public struct SSHWriter: Sendable {
    public private(set) var bytes: [UInt8]

    public init(capacity: Int = 64) {
        bytes = []
        bytes.reserveCapacity(capacity)
    }

    public mutating func writeByte(_ v: UInt8) { bytes.append(v) }

    public mutating func writeBool(_ v: Bool) { bytes.append(v ? 1 : 0) }

    public mutating func writeUInt32(_ v: UInt32) {
        bytes.append(UInt8(truncatingIfNeeded: v >> 24))
        bytes.append(UInt8(truncatingIfNeeded: v >> 16))
        bytes.append(UInt8(truncatingIfNeeded: v >> 8))
        bytes.append(UInt8(truncatingIfNeeded: v))
    }

    public mutating func writeUInt64(_ v: UInt64) {
        writeUInt32(UInt32(truncatingIfNeeded: v >> 32))
        writeUInt32(UInt32(truncatingIfNeeded: v))
    }

    /// Raw bytes, no length prefix.
    public mutating func writeBytes<C: Collection>(_ v: C) where C.Element == UInt8 {
        bytes.append(contentsOf: v)
    }

    public mutating func writeString<C: Collection>(_ v: C) where C.Element == UInt8 {
        writeUInt32(UInt32(v.count))
        bytes.append(contentsOf: v)
    }

    public mutating func writeString(_ v: String) {
        writeString(Array(v.utf8))
    }

    public mutating func writeNameList(_ names: [String]) {
        writeString(names.joined(separator: ","))
    }

    /// An unsigned magnitude as an mpint: leading zeros stripped, one zero
    /// byte prepended when the top bit is set, zero encoded as an empty string.
    public mutating func writeMPInt<C: Collection>(unsigned magnitude: C) where C.Element == UInt8 {
        let trimmed = magnitude.drop(while: { $0 == 0 })
        if let first = trimmed.first, first & 0x80 != 0 {
            writeUInt32(UInt32(trimmed.count + 1))
            bytes.append(0)
        } else {
            writeUInt32(UInt32(trimmed.count))
        }
        bytes.append(contentsOf: trimmed)
    }

    public mutating func writeMPInt(_ v: BigUInt) {
        writeMPInt(unsigned: v.bigEndianBytes())
    }
}
