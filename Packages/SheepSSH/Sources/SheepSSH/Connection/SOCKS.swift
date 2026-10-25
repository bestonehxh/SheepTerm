// The server half of a SOCKS5 handshake (RFC 1928) — and of SOCKS4/4a, for
// the older tools that only speak that — sans-I/O: a local
// client's bytes go in, the reply to send and — once a CONNECT request is
// complete — the target come out. What `ssh -D` speaks: no authentication
// (the listener is loopback-only), CONNECT only, IPv4 / domain / IPv6
// targets. Anything else is answered with the RFC's refusal and ended.
import Foundation

public struct SOCKSHandshake: Sendable {
    public enum Outcome: Equatable, Sendable {
        /// Needs more bytes.
        case pending
        /// Send `reply`, keep reading.
        case reply([UInt8])
        /// The request is complete: open the tunnel to host:port, then send
        /// `succeeded()` or `failed(_:)`. `leftover` is what the client sent
        /// after the request (its first bytes of payload) — forward it.
        case connect(host: String, port: Int, leftover: [UInt8])
        /// Send `reply` (possibly empty) and close the client.
        case refuse([UInt8])
    }

    private enum Stage: Sendable { case greeting, request, done }
    private var stage: Stage = .greeting
    private var buffer: [UInt8] = []
    /// A greeting and a request together are at most 2+255 and 6+1+255+2
    /// bytes; a client that sends more before we answer is not SOCKS.
    public static let maximumBuffered = 1024

    public init() {}

    public mutating func receive(_ bytes: [UInt8]) -> Outcome {
        guard stage != .done else { return .pending }
        buffer += bytes
        guard buffer.count <= Self.maximumBuffered else { stage = .done; return .refuse([]) }
        var replies: [UInt8] = []
        while true {
            switch stage {
            case .greeting:
                guard buffer.count >= 2 else { return replies.isEmpty ? .pending : .reply(replies) }
                if buffer[0] == 4 { return socks4() }
                guard buffer[0] == 5 else { stage = .done; return .refuse([]) }   // not SOCKS
                let count = Int(buffer[1])
                guard buffer.count >= 2 + count else { return .pending }
                let methods = buffer[2..<(2 + count)]
                buffer.removeFirst(2 + count)
                guard methods.contains(0) else { stage = .done; return .refuse([5, 0xFF]) }
                replies += [5, 0]
                stage = .request
            case .request:
                guard buffer.count >= 5 else { return replies.isEmpty ? .pending : .reply(replies) }
                guard buffer[0] == 5 else { stage = .done; return .refuse(replies + Self.reply(1)) }
                let command = buffer[1], type = buffer[3]
                let addressLength: Int
                switch type {
                case 1: addressLength = 4
                case 3: addressLength = 1 + Int(buffer[4])
                case 4: addressLength = 16
                default: stage = .done; return .refuse(replies + Self.reply(8))   // address type not supported
                }
                let total = 4 + addressLength + 2
                guard buffer.count >= total else { return replies.isEmpty ? .pending : .reply(replies) }
                guard command == 1 else { stage = .done; return .refuse(replies + Self.reply(7)) }   // CONNECT only
                let address = buffer[4..<(4 + addressLength)]
                let host: String
                switch type {
                case 1:
                    host = address.map(String.init).joined(separator: ".")
                case 3:
                    let name = address.dropFirst()
                    guard !name.isEmpty, let text = String(bytes: name, encoding: .utf8),
                          !text.contains(where: { $0.isWhitespace || $0 == "\0" }) else {
                        stage = .done; return .refuse(replies + Self.reply(4))
                    }
                    host = text
                default:
                    host = Self.ipv6Text(Array(address))
                }
                let port = Int(buffer[4 + addressLength]) << 8 | Int(buffer[5 + addressLength])
                let leftover = Array(buffer[total...])
                buffer.removeAll()
                stage = .done
                guard port > 0 else { return .refuse(replies + Self.reply(4)) }
                // The greeting's answer must go first; the caller sends it
                // with the connect outcome by prefixing `pendingReply`.
                pendingReply = replies
                return .connect(host: host, port: port, leftover: leftover)
            case .done:
                return .pending
            }
        }
    }

    /// The greeting's answer when it arrived in the same read as the request:
    /// send it before `succeeded()`/`failed(_:)`.
    public private(set) var pendingReply: [UInt8] = []

    /// 5, or 4 once a SOCKS4/4a request was read.
    public private(set) var version: UInt8 = 5

    /// Everything still owed to the client once the tunnel opened, in the
    /// client's version.
    public func successReply() -> [UInt8] {
        version == 4 ? [0, 0x5A, 0, 0, 0, 0, 0, 0] : pendingReply + Self.succeeded()
    }

    /// The same after the tunnel failed (`code` as for `failed(_:)`).
    public func failureReply(_ code: UInt8) -> [UInt8] {
        version == 4 ? [0, 0x5B, 0, 0, 0, 0, 0, 0] : pendingReply + Self.failed(code)
    }

    /// SOCKS4 (`VN CD DSTPORT DSTIP USERID NUL`) and 4a (DSTIP 0.0.0.x,
    /// then the host name and NUL). CONNECT only; the user id is ignored.
    private mutating func socks4() -> Outcome {
        guard buffer.count >= 9 else { return .pending }
        guard let userEnd = buffer[8...].firstIndex(of: 0) else { return .pending }
        let ip = Array(buffer[4..<8])
        let port = Int(buffer[2]) << 8 | Int(buffer[3])
        var host = ip.map(String.init).joined(separator: ".")
        var end = userEnd + 1
        if ip[0] == 0, ip[1] == 0, ip[2] == 0, ip[3] != 0 {
            guard let nameEnd = buffer[end...].firstIndex(of: 0) else { return .pending }
            guard nameEnd > end, let name = String(bytes: buffer[end..<nameEnd], encoding: .utf8),
                  !name.contains(where: { $0.isWhitespace }) else {
                stage = .done; version = 4; return .refuse([0, 0x5B, 0, 0, 0, 0, 0, 0])
            }
            host = name
            end = nameEnd + 1
        }
        version = 4
        stage = .done
        guard buffer[1] == 1, port > 0 else { return .refuse([0, 0x5B, 0, 0, 0, 0, 0, 0]) }
        let leftover = Array(buffer[end...])
        buffer.removeAll()
        return .connect(host: host, port: port, leftover: leftover)
    }

    /// After the tunnel opened. The bound address is reported as 0.0.0.0:0
    /// (as OpenSSH does — the real one is on the far side).
    public static func succeeded() -> [UInt8] { reply(0) }

    /// After the tunnel failed. `code`: 1 general failure, 2 not allowed,
    /// 3 network unreachable, 4 host unreachable, 5 connection refused.
    public static func failed(_ code: UInt8) -> [UInt8] { reply(code) }

    /// The SSH open-failure reason (RFC 4254 §5.1) as a SOCKS reply code.
    public static func code(forOpenFailure reason: UInt32) -> UInt8 {
        switch reason {
        case 1: return 2      // administratively prohibited
        case 2: return 5      // connect failed
        default: return 1
        }
    }

    private static func reply(_ code: UInt8) -> [UInt8] { [5, code, 0, 1, 0, 0, 0, 0, 0, 0] }

    private static func ipv6Text(_ bytes: [UInt8]) -> String {
        stride(from: 0, to: 16, by: 2).map { String(UInt16(bytes[$0]) << 8 | UInt16(bytes[$0 + 1]), radix: 16) }
            .joined(separator: ":")
    }
}
