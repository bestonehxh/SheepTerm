// bcrypt_pbkdf, the KDF OpenSSH uses for passphrase-protected private keys
// ("openssh-key-v1" with kdfname "bcrypt"). A port of OpenBSD's
// bcrypt_pbkdf.c and the parts of blf.c it needs (the "eksblowfish" key
// schedule). SHA-512 comes from CryptoKit.
//
// Blowfish's S-box lookups are indexed by secret-derived data, so this is not
// constant-time — the same as every other implementation of it. It runs once,
// locally, on a key file the user opened; there is no remote party to time it.

public enum BcryptPBKDFError: Error, Equatable, Sendable {
    case invalidParameters
}

public enum BcryptPBKDF {
    /// Derives `keyLength` bytes. Same limits as OpenBSD: non-empty password
    /// and salt, salt ≤ 1 MiB, 1…1024 output bytes, rounds ≥ 1.
    public static func derive(password: [UInt8], salt: [UInt8], rounds: Int, keyLength: Int) throws(BcryptPBKDFError) -> [UInt8] {
        guard rounds >= 1, !password.isEmpty, !salt.isEmpty, salt.count <= 1 << 20,
              keyLength >= 1, keyLength <= 32 * 32 else {
            throw .invalidParameters
        }
        let stride = (keyLength + 32 - 1) / 32
        var amount = (keyLength + stride - 1) / stride
        var key = [UInt8](repeating: 0, count: keyLength)
        let sha2pass = SSHHash.sha512.hash(password)
        var remaining = keyLength
        var count: UInt32 = 1
        let state = BlowfishState()
        while remaining > 0 {
            var countSalt = salt
            countSalt.append(UInt8(truncatingIfNeeded: count >> 24))
            countSalt.append(UInt8(truncatingIfNeeded: count >> 16))
            countSalt.append(UInt8(truncatingIfNeeded: count >> 8))
            countSalt.append(UInt8(truncatingIfNeeded: count))
            var sha2salt = SSHHash.sha512.hash(countSalt)
            var tmp = bcryptHash(state, sha2pass, sha2salt)
            var out = tmp
            if rounds > 1 {
                for _ in 1..<rounds {
                    sha2salt = SSHHash.sha512.hash(tmp)
                    tmp = bcryptHash(state, sha2pass, sha2salt)
                    for j in 0..<out.count { out[j] ^= tmp[j] }
                }
            }
            amount = min(amount, remaining)
            var i = 0
            while i < amount {
                let dest = i * stride + Int(count - 1)
                if dest >= keyLength { break }
                key[dest] = out[i]
                i += 1
            }
            remaining -= i
            count += 1
        }
        return key
    }

    static let magic = Array("OxychromaticBlowfishSwatDynamite".utf8)

    /// bcrypt_hash from bcrypt_pbkdf.c: 32 bytes out.
    static func bcryptHash(_ state: BlowfishState, _ sha2pass: [UInt8], _ sha2salt: [UInt8]) -> [UInt8] {
        state.reset()
        state.expand(data: sha2salt, key: sha2pass)
        for _ in 0..<64 {
            state.expand0(key: sha2salt)
            state.expand0(key: sha2pass)
        }
        var cdata = [UInt32](repeating: 0, count: 8)
        var j = 0
        for i in 0..<8 { cdata[i] = BlowfishState.streamToWord(magic, &j) }
        for _ in 0..<64 {
            var i = 0
            while i < 8 {
                let (l, r) = state.encipher(cdata[i], cdata[i + 1])
                cdata[i] = l; cdata[i + 1] = r
                i += 2
            }
        }
        var out = [UInt8](repeating: 0, count: 32)
        for i in 0..<8 {
            out[4 * i + 3] = UInt8(truncatingIfNeeded: cdata[i] >> 24)
            out[4 * i + 2] = UInt8(truncatingIfNeeded: cdata[i] >> 16)
            out[4 * i + 1] = UInt8(truncatingIfNeeded: cdata[i] >> 8)
            out[4 * i] = UInt8(truncatingIfNeeded: cdata[i])
        }
        return out
    }
}

/// Mutable Blowfish state (P-array + S-boxes) in one allocation, zeroed on
/// release since it is derived from the passphrase.
final class BlowfishState {
    /// 18 P words, then S0…S3 (256 words each).
    private let words: UnsafeMutablePointer<UInt32>
    static let wordCount = 18 + 4 * 256

    init() {
        words = .allocate(capacity: Self.wordCount)
        words.initialize(repeating: 0, count: Self.wordCount)
        reset()
    }

    deinit {
        words.update(repeating: 0, count: Self.wordCount)
        words.deallocate()
    }

    func reset() {
        for i in 0..<18 { words[i] = BlowfishTables.p[i] }
        for i in 0..<256 {
            words[18 + i] = BlowfishTables.s0[i]
            words[18 + 256 + i] = BlowfishTables.s1[i]
            words[18 + 512 + i] = BlowfishTables.s2[i]
            words[18 + 768 + i] = BlowfishTables.s3[i]
        }
    }

    /// Blowfish_stream2word: the next 4 bytes of `data`, cycling, big-endian.
    static func streamToWord(_ data: [UInt8], _ j: inout Int) -> UInt32 {
        var temp: UInt32 = 0
        for _ in 0..<4 {
            if j >= data.count { j = 0 }
            temp = temp << 8 | UInt32(data[j])
            j += 1
        }
        return temp
    }

    @inline(__always)
    private func f(_ x: UInt32) -> UInt32 {
        let s = words + 18
        let a = s[Int(x >> 24)]
        let b = s[256 + Int((x >> 16) & 0xff)]
        let c = s[512 + Int((x >> 8) & 0xff)]
        let d = s[768 + Int(x & 0xff)]
        return ((a &+ b) ^ c) &+ d
    }

    func encipher(_ xl: UInt32, _ xr: UInt32) -> (UInt32, UInt32) {
        var l = xl ^ words[0]
        var r = xr
        var n = 1
        while n <= 16 {
            r ^= f(l) ^ words[n]
            l ^= f(r) ^ words[n + 1]
            n += 2
        }
        return (r ^ words[17], l)
    }

    /// Blowfish_expandstate: key into P, then re-encrypt P and S with `data`
    /// mixed in.
    func expand(data: [UInt8], key: [UInt8]) {
        var j = 0
        for i in 0..<18 { words[i] ^= Self.streamToWord(key, &j) }
        j = 0
        var l: UInt32 = 0, r: UInt32 = 0
        var i = 0
        while i < Self.wordCount {
            l ^= Self.streamToWord(data, &j)
            r ^= Self.streamToWord(data, &j)
            (l, r) = encipher(l, r)
            words[i] = l
            words[i + 1] = r
            i += 2
        }
    }

    /// Blowfish_expand0state: the same without the data stream.
    func expand0(key: [UInt8]) {
        var j = 0
        for i in 0..<18 { words[i] ^= Self.streamToWord(key, &j) }
        var l: UInt32 = 0, r: UInt32 = 0
        var i = 0
        while i < Self.wordCount {
            (l, r) = encipher(l, r)
            words[i] = l
            words[i + 1] = r
            i += 2
        }
    }
}
