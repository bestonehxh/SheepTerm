// Message numbers (RFC 4250 §4.1) and the KEXINIT message.

public enum SSHMessage {
    public static let disconnect: UInt8 = 1
    public static let ignore: UInt8 = 2
    public static let unimplemented: UInt8 = 3
    public static let debug: UInt8 = 4
    public static let serviceRequest: UInt8 = 5
    public static let serviceAccept: UInt8 = 6
    public static let extInfo: UInt8 = 7
    public static let kexInit: UInt8 = 20
    public static let newKeys: UInt8 = 21
    // 30–49: key-exchange-method specific.
    public static let kexDHInit: UInt8 = 30          // also ECDH / hybrid INIT
    public static let kexDHReply: UInt8 = 31         // also ECDH REPLY and GEX GROUP
    public static let kexDHGexInit: UInt8 = 32
    public static let kexDHGexReply: UInt8 = 33
    public static let kexDHGexRequest: UInt8 = 34

    /// Transport-layer messages that may appear during key exchange (and
    /// therefore do not count as "application" traffic to queue).
    static func isKexMessage(_ n: UInt8) -> Bool {
        n == kexInit || n == newKeys || (30...49).contains(n)
    }

    /// Messages allowed during kex that are not kex messages (RFC 4253 §7.1).
    /// In strict-kex mode none of these are tolerated in the initial kex.
    static func isTransportGeneric(_ n: UInt8) -> Bool {
        n == disconnect || n == ignore || n == unimplemented || n == debug
    }
}

/// RFC 4253 §11.1 reason codes.
public enum DisconnectReason: UInt32, Sendable {
    case hostNotAllowedToConnect = 1, protocolError, keyExchangeFailed, reserved, macError,
         compressionError, serviceNotAvailable, protocolVersionNotSupported, hostKeyNotVerifiable,
         connectionLost, byApplication, tooManyConnections, authCancelledByUser,
         noMoreAuthMethodsAvailable, illegalUserName
}

public struct KexInit: Sendable, Equatable {
    public let cookie: [UInt8]
    public let kexAlgorithms: [String]
    public let hostKeyAlgorithms: [String]
    public let ciphersClientToServer: [String]
    public let ciphersServerToClient: [String]
    public let macsClientToServer: [String]
    public let macsServerToClient: [String]
    public let compressionClientToServer: [String]
    public let compressionServerToClient: [String]
    public let languagesClientToServer: [String]
    public let languagesServerToClient: [String]
    public let firstKexPacketFollows: Bool

    /// The exact payload (message byte included) — it goes into the exchange
    /// hash as sent/received, never re-encoded.
    public let payload: [UInt8]

    public init(cookie: [UInt8], kexAlgorithms: [String], hostKeyAlgorithms: [String],
                ciphers: [String], macs: [String]) {
        self.cookie = cookie
        self.kexAlgorithms = kexAlgorithms
        self.hostKeyAlgorithms = hostKeyAlgorithms
        self.ciphersClientToServer = ciphers
        self.ciphersServerToClient = ciphers
        self.macsClientToServer = macs
        self.macsServerToClient = macs
        self.compressionClientToServer = ["none"]
        self.compressionServerToClient = ["none"]
        self.languagesClientToServer = []
        self.languagesServerToClient = []
        self.firstKexPacketFollows = false
        self.payload = Self.encode(cookie: cookie, lists: [kexAlgorithms, hostKeyAlgorithms, ciphers, ciphers, macs, macs, ["none"], ["none"], [], []], firstKexPacketFollows: false)
    }

    public init(payload: [UInt8]) throws(SSHWireError) {
        var r = SSHReader(payload)
        guard try r.readByte() == SSHMessage.kexInit else { throw .invalidValue }
        cookie = try r.readBytes(16)
        kexAlgorithms = try r.readNameList()
        hostKeyAlgorithms = try r.readNameList()
        ciphersClientToServer = try r.readNameList()
        ciphersServerToClient = try r.readNameList()
        macsClientToServer = try r.readNameList()
        macsServerToClient = try r.readNameList()
        compressionClientToServer = try r.readNameList()
        compressionServerToClient = try r.readNameList()
        languagesClientToServer = try r.readNameList()
        languagesServerToClient = try r.readNameList()
        firstKexPacketFollows = try r.readBool()
        _ = try r.readUInt32()  // reserved
        self.payload = payload
    }

    static func encode(cookie: [UInt8], lists: [[String]], firstKexPacketFollows: Bool) -> [UInt8] {
        var w = SSHWriter(capacity: 1024)
        w.writeByte(SSHMessage.kexInit)
        w.writeBytes(cookie)
        for list in lists { w.writeNameList(list) }
        w.writeBool(firstKexPacketFollows)
        w.writeUInt32(0)
        return w.bytes
    }
}
