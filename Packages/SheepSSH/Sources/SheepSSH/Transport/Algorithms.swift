// Algorithm names, the lists SheepSSH offers, and RFC 4253 §7.1 negotiation.
//
// The lists mirror what SheepTerm handed libssh: `modern` is libssh 0.12's
// client default (minus sntrup761, which nothing on Apple implements), and
// `legacy` is SSHWorker's legacy list verbatim — modern first, old after, so
// new gear still negotiates the best it has while old switches connect.

public enum KexAlgorithm: String, Sendable, CaseIterable {
    case mlkem768x25519 = "mlkem768x25519-sha256"
    case curve25519 = "curve25519-sha256"
    case curve25519LibSSH = "curve25519-sha256@libssh.org"
    case ecdhP256 = "ecdh-sha2-nistp256"
    case ecdhP384 = "ecdh-sha2-nistp384"
    case ecdhP521 = "ecdh-sha2-nistp521"
    case dhGexSHA256 = "diffie-hellman-group-exchange-sha256"
    case dhGroup16 = "diffie-hellman-group16-sha512"
    case dhGroup18 = "diffie-hellman-group18-sha512"
    case dhGroup14SHA256 = "diffie-hellman-group14-sha256"
    case dhGroup14SHA1 = "diffie-hellman-group14-sha1"
    case dhGroup1 = "diffie-hellman-group1-sha1"
    case dhGexSHA1 = "diffie-hellman-group-exchange-sha1"

    public var hash: SSHHash {
        switch self {
        case .mlkem768x25519, .curve25519, .curve25519LibSSH, .ecdhP256, .dhGexSHA256, .dhGroup14SHA256: return .sha256
        case .ecdhP384: return .sha384
        case .ecdhP521, .dhGroup16, .dhGroup18: return .sha512
        case .dhGroup14SHA1, .dhGroup1, .dhGexSHA1: return .sha1
        }
    }

    /// Whether this build can run it (ML-KEM: always on macOS 26+, never on Linux).
    public var isAvailable: Bool {
        switch self {
        case .mlkem768x25519: return HybridMLKEM.isAvailable
        default: return true
        }
    }
}

public enum HostKeyAlgorithm: String, Sendable, CaseIterable {
    case ed25519 = "ssh-ed25519"
    case ecdsaP521 = "ecdsa-sha2-nistp521"
    case ecdsaP384 = "ecdsa-sha2-nistp384"
    case ecdsaP256 = "ecdsa-sha2-nistp256"
    case rsaSHA512 = "rsa-sha2-512"
    case rsaSHA256 = "rsa-sha2-256"
    case rsaSHA1 = "ssh-rsa"
    case dss = "ssh-dss"

    /// The key type inside the blob that signs for this algorithm.
    public var keyType: String {
        switch self {
        case .rsaSHA512, .rsaSHA256, .rsaSHA1: return "ssh-rsa"
        default: return rawValue
        }
    }
}

public enum CipherAlgorithm: String, Sendable, CaseIterable {
    case chacha20Poly1305 = "chacha20-poly1305@openssh.com"
    case aes256GCM = "aes256-gcm@openssh.com"
    case aes128GCM = "aes128-gcm@openssh.com"
    case aes256CTR = "aes256-ctr"
    case aes192CTR = "aes192-ctr"
    case aes128CTR = "aes128-ctr"
    case aes256CBC = "aes256-cbc"
    case aes192CBC = "aes192-cbc"
    case aes128CBC = "aes128-cbc"
    case tripleDESCBC = "3des-cbc"

    public var keySize: Int {
        switch self {
        case .chacha20Poly1305: return 64
        case .aes256GCM, .aes256CTR, .aes256CBC: return 32
        case .aes192CTR, .aes192CBC, .tripleDESCBC: return 24
        case .aes128GCM, .aes128CTR, .aes128CBC: return 16
        }
    }

    public var ivSize: Int {
        switch self {
        case .chacha20Poly1305: return 0
        case .aes256GCM, .aes128GCM: return 12
        case .tripleDESCBC: return 8
        default: return 16
        }
    }

    public var blockSize: Int {
        switch self {
        case .chacha20Poly1305, .tripleDESCBC: return 8
        default: return 16
        }
    }

    /// AEAD ciphers carry their own tag; the negotiated MAC is not used.
    public var isAEAD: Bool {
        self == .chacha20Poly1305 || self == .aes256GCM || self == .aes128GCM
    }

    public var isAvailable: Bool {
        self == .tripleDESCBC ? BlockCipherStream.tripleDESAvailable : true
    }
}

public enum MACAlgorithm: String, Sendable, CaseIterable {
    case hmacSHA256ETM = "hmac-sha2-256-etm@openssh.com"
    case hmacSHA512ETM = "hmac-sha2-512-etm@openssh.com"
    case hmacSHA1ETM = "hmac-sha1-etm@openssh.com"
    case hmacSHA256 = "hmac-sha2-256"
    case hmacSHA512 = "hmac-sha2-512"
    case hmacSHA1 = "hmac-sha1"
    case hmacMD5 = "hmac-md5"

    public var hash: SSHHash {
        switch self {
        case .hmacSHA256ETM, .hmacSHA256: return .sha256
        case .hmacSHA512ETM, .hmacSHA512: return .sha512
        case .hmacSHA1ETM, .hmacSHA1: return .sha1
        case .hmacMD5: return .md5
        }
    }

    /// Key length = output length for every HMAC SSH uses.
    public var keySize: Int { hash.outputSize }
    public var isEncryptThenMAC: Bool { rawValue.hasSuffix("-etm@openssh.com") }
}

/// What the client offers, most preferred first.
public struct AlgorithmPreferences: Sendable, Equatable {
    public var kex: [KexAlgorithm]
    public var hostKeys: [HostKeyAlgorithm]
    public var ciphers: [CipherAlgorithm]
    public var macs: [MACAlgorithm]

    public init(kex: [KexAlgorithm], hostKeys: [HostKeyAlgorithm], ciphers: [CipherAlgorithm], macs: [MACAlgorithm]) {
        self.kex = kex
        self.hostKeys = hostKeys
        self.ciphers = ciphers
        self.macs = macs
    }

    /// libssh 0.12's client default.
    public static let modern = AlgorithmPreferences(
        kex: [.mlkem768x25519, .curve25519, .curve25519LibSSH, .ecdhP256, .ecdhP384, .ecdhP521,
              .dhGroup18, .dhGroup16, .dhGexSHA256, .dhGroup14SHA256],
        hostKeys: [.ed25519, .ecdsaP521, .ecdsaP384, .ecdsaP256, .rsaSHA512, .rsaSHA256],
        ciphers: [.chacha20Poly1305, .aes256GCM, .aes128GCM, .aes256CTR, .aes192CTR, .aes128CTR],
        macs: [.hmacSHA256ETM, .hmacSHA512ETM, .hmacSHA1ETM, .hmacSHA256, .hmacSHA512, .hmacSHA1])

    /// SSHWorker's legacyKex / legacyCiphers / legacyHostKeys / legacyMacs.
    public static let legacy = AlgorithmPreferences(
        kex: [.mlkem768x25519, .curve25519, .curve25519LibSSH, .ecdhP521, .ecdhP384, .ecdhP256,
              .dhGexSHA256, .dhGroup16, .dhGroup18, .dhGroup14SHA256, .dhGroup14SHA1, .dhGroup1, .dhGexSHA1],
        hostKeys: [.ed25519, .ecdsaP521, .ecdsaP384, .ecdsaP256, .rsaSHA512, .rsaSHA256, .rsaSHA1, .dss],
        ciphers: [.chacha20Poly1305, .aes256GCM, .aes128GCM, .aes256CTR, .aes192CTR, .aes128CTR,
                  .aes256CBC, .aes192CBC, .aes128CBC, .tripleDESCBC],
        macs: [.hmacSHA256ETM, .hmacSHA512ETM, .hmacSHA256, .hmacSHA512, .hmacSHA1, .hmacMD5])

    /// The same lists with the host-key algorithms for `keyTypes` moved to
    /// the front (in that order), everything else keeping its place — what
    /// libssh did with the types already in known_hosts.
    public func preferringHostKeyTypes(_ keyTypes: [String]) -> AlgorithmPreferences {
        var front: [HostKeyAlgorithm] = []
        for type in keyTypes {
            front += hostKeys.filter { $0.keyType == type && !front.contains($0) }
        }
        return AlgorithmPreferences(kex: kex, hostKeys: front + hostKeys.filter { !front.contains($0) },
                                    ciphers: ciphers, macs: macs)
    }

    /// The same lists without what this build cannot run.
    var available: AlgorithmPreferences {
        AlgorithmPreferences(kex: kex.filter(\.isAvailable), hostKeys: hostKeys,
                             ciphers: ciphers.filter(\.isAvailable), macs: macs)
    }
}

/// Pseudo-algorithms that ride in the kex list (never selected).
enum KexExtension {
    static let extInfoClient = "ext-info-c"
    static let strictClient = "kex-strict-c-v00@openssh.com"
    static let strictServer = "kex-strict-s-v00@openssh.com"

    static func isMarker(_ name: String) -> Bool {
        name.hasPrefix("ext-info-") || name.hasPrefix("kex-strict-")
    }
}

public struct NegotiatedAlgorithms: Sendable, Equatable {
    public let kex: KexAlgorithm
    public let hostKey: HostKeyAlgorithm
    public let cipherClientToServer: CipherAlgorithm
    public let cipherServerToClient: CipherAlgorithm
    /// Nil when the cipher in that direction is AEAD.
    public let macClientToServer: MACAlgorithm?
    public let macServerToClient: MACAlgorithm?
}

public enum NegotiationError: Error, Equatable, Sendable {
    /// No common algorithm in the named category. The server's offer is
    /// included so the message can say what the device wanted.
    case noCommonAlgorithm(category: String, serverOffers: [String])
}

enum Negotiation {
    /// RFC 4253 §7.1: the first algorithm on the CLIENT's list that the
    /// server also lists.
    static func pick<A: RawRepresentable>(_ client: [A], _ server: [String], _ category: String) throws(NegotiationError) -> A
    where A.RawValue == String {
        for algorithm in client where server.contains(algorithm.rawValue) { return algorithm }
        // The markers (ext-info-s, kex-strict-s-…) are not algorithms; leaving
        // them in made "the device offers: …" read as if it offered them.
        throw .noCommonAlgorithm(category: category, serverOffers: server.filter { !KexExtension.isMarker($0) })
    }

    static func negotiate(client: AlgorithmPreferences, server: KexInit) throws(NegotiationError) -> NegotiatedAlgorithms {
        let kex = try pick(client.kex, server.kexAlgorithms, "key exchange")
        let hostKey = try pick(client.hostKeys, server.hostKeyAlgorithms, "host key")
        let c2s = try pick(client.ciphers, server.ciphersClientToServer, "cipher (client to server)")
        let s2c = try pick(client.ciphers, server.ciphersServerToClient, "cipher (server to client)")
        let macC2S = c2s.isAEAD ? nil : try pick(client.macs, server.macsClientToServer, "MAC (client to server)")
        let macS2C = s2c.isAEAD ? nil : try pick(client.macs, server.macsServerToClient, "MAC (server to client)")
        guard server.compressionClientToServer.contains("none"), server.compressionServerToClient.contains("none") else {
            throw .noCommonAlgorithm(category: "compression", serverOffers: server.compressionClientToServer)
        }
        return NegotiatedAlgorithms(kex: kex, hostKey: hostKey, cipherClientToServer: c2s, cipherServerToClient: s2c,
                                    macClientToServer: macC2S, macServerToClient: macS2C)
    }
}
