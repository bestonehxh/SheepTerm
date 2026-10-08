import Foundation

/// The bastion for a ProxyJump-style session: the client logs in here
/// first, asks for a direct-tcpip channel to the real host, and runs the real
/// host's SSH over that channel. The bastion carries ciphertext only and
/// never sees the inner login; its own host key is checked and pinned like
/// any other host's.
public struct JumpHop: Sendable, Equatable {
    /// Which algorithm set to offer the bastion — the same three choices the
    /// app gives a host (its `CipherMode`, by raw value).
    public enum CipherPolicy: String, Sendable {
        case auto, modern, legacy
    }

    public var host: String
    public var port: Int
    public var username: String
    public var password: String?
    public var cipherPolicy: CipherPolicy

    public init(host: String, port: Int, username: String, password: String? = nil,
                cipherPolicy: CipherPolicy = .auto) {
        self.host = host
        self.port = port
        self.username = username
        self.password = password
        self.cipherPolicy = cipherPolicy
    }

    /// `host:port` the way a status line or a notice names the hop; port 22
    /// is left off, an IPv6 literal is bracketed.
    public var label: String {
        let shownHost = host.contains(":") ? "[\(host)]" : host
        return port == 22 ? shownHost : "\(shownHost):\(port)"
    }
}
