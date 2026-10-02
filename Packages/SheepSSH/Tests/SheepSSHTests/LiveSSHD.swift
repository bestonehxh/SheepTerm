// A throwaway OpenSSH server for end-to-end tests, and a blocking TCP loop
// that drives an SSHTransport against it. Nothing of the user's is touched:
// host keys, config and pid file live in a temporary directory, the server
// listens on 127.0.0.1 only and allows no logins.
//
// Skipped (XCTSkip) when /usr/sbin/sshd or ssh-keygen is missing.
import Foundation
import XCTest
@testable import SheepSSH
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

final class LiveSSHD {
    let port: UInt16
    let directory: URL
    private let process: Process
    let logURL: URL

    static let sshd = "/usr/sbin/sshd"
    static var keygen: String? {
        ["/usr/bin/ssh-keygen", "/opt/homebrew/bin/ssh-keygen"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// A client ed25519 key the server accepts for the current user.
    static let clientKey = Curve25519.Signing.PrivateKey()
    static let clientKeyBlob: [UInt8] = {
        var w = SSHWriter()
        w.writeString("ssh-ed25519")
        w.writeString(Array(clientKey.publicKey.rawRepresentation))
        return w.bytes
    }()
    static var userName: String { String(cString: getpwuid(getuid())!.pointee.pw_name) }

    /// What the local OpenSSH implements (`ssh -Q kex|cipher|mac|key`), so a
    /// Mac with OpenSSH 10 (no DSA) skips instead of failing.
    static func supported(_ query: String) -> Set<String> {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        p.arguments = ["-Q", query]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return Set(String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline).map(String.init))
    }

    /// Host keys are made once per test run and shared.
    nonisolated(unsafe) static var sharedKeyDirectory: URL?

    static func hostKeyDirectory() throws -> URL {
        if let dir = sharedKeyDirectory { return dir }
        guard let keygen else { throw XCTSkip("ssh-keygen not found") }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sheepssh-hostkeys-\(getpid())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (name, args) in [("ed25519", ["-t", "ed25519"]), ("ecdsa256", ["-t", "ecdsa", "-b", "256"]),
                             ("ecdsa384", ["-t", "ecdsa", "-b", "384"]), ("ecdsa521", ["-t", "ecdsa", "-b", "521"]),
                             ("rsa", ["-t", "rsa", "-b", "2048"]), ("rsa1024", ["-t", "rsa", "-b", "1024"]),
                             ("dsa", ["-t", "dsa"])] {
            let path = dir.appendingPathComponent(name).path
            if FileManager.default.fileExists(atPath: path) { continue }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: keygen)
            p.arguments = ["-q"] + args + ["-N", "", "-f", path]
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try p.run()
            p.waitUntilExit()
        }
        sharedKeyDirectory = dir
        return dir
    }

    /// `options` are extra sshd_config lines (KexAlgorithms, Ciphers, …).
    /// `hostKeys` names files from `hostKeyDirectory()`.
    init(hostKeys: [String], options: [String], authorizedKeys: [String] = []) throws {
        guard FileManager.default.isExecutableFile(atPath: Self.sshd) else { throw XCTSkip("no \(Self.sshd)") }
        let keys = try Self.hostKeyDirectory()
        if getuid() == 0 {
            // Root sshd wants its privilege-separation directory.
            try? FileManager.default.createDirectory(atPath: "/run/sshd", withIntermediateDirectories: true)
        }
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("sheepssh-sshd-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        port = Self.freePort()
        let fixtureKey = "ssh-ed25519 " + Data(Self.clientKeyBlob).base64EncodedString() + " sheepssh-test"
        try (([fixtureKey] + authorizedKeys).joined(separator: "\n") + "\n")
            .write(to: directory.appendingPathComponent("authorized_keys"), atomically: true, encoding: .utf8)
        // sshd keeps the FIRST value of a keyword, so the caller's options
        // go before the defaults below.
        var config = options + [
            "ListenAddress 127.0.0.1",
            "Port \(port)",
            "PidFile \(directory.appendingPathComponent("pid").path)",
            "AuthorizedKeysFile \(directory.appendingPathComponent("authorized_keys").path)",
            "PasswordAuthentication no",
            "KbdInteractiveAuthentication no",
            "PubkeyAuthentication yes",
            "PermitRootLogin yes",
            "UsePAM no",
            "StrictModes no",
            "LogLevel DEBUG1",
        ]
        config += hostKeys.map { "HostKey \(keys.appendingPathComponent($0).path)" }
        let configURL = directory.appendingPathComponent("sshd_config")
        try (config.joined(separator: "\n") + "\n").write(to: configURL, atomically: true, encoding: .utf8)
        logURL = directory.appendingPathComponent("sshd.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        process = Process()
        process.executableURL = URL(fileURLWithPath: Self.sshd)
        process.arguments = ["-D", "-e", "-f", configURL.path]
        let logHandle = try FileHandle(forWritingTo: logURL)
        process.standardOutput = logHandle
        process.standardError = logHandle
        try process.run()
        // Wait until it accepts connections.
        for _ in 0..<200 {
            if let fd = try? Self.connect(port: port) { close(fd); return }
            usleep(20_000)
        }
        throw XCTSkip("sshd did not come up:\n\(log())")
    }

    func log() -> String {
        (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
    }

    deinit {
        process.terminate()
        process.waitUntilExit()
        try? FileManager.default.removeItem(at: directory)
    }

    static func freePort() -> UInt16 {
        let fd = socket(AF_INET, sockStream, 0)
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
#if canImport(Darwin)
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
#endif
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0
        _ = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
        }
        return UInt16(bigEndian: addr.sin_port)
    }

    static func connect(port: UInt16) throws -> Int32 {
        let fd = socket(AF_INET, sockStream, 0)
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
#if canImport(Darwin)
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
#endif
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = port.bigEndian
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Glibc_or_Darwin_connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard rc == 0 else { close(fd); throw POSIXError(.ECONNREFUSED) }
        return fd
    }
}

#if canImport(Glibc)
private let Glibc_or_Darwin_connect = Glibc.connect
private let sockStream = Int32(SOCK_STREAM.rawValue)
#else
private let Glibc_or_Darwin_connect = Darwin.connect
private let sockStream = SOCK_STREAM
#endif

/// Drives a transport over a connected socket until `until` says stop.
struct TransportDriver {
    let fd: Int32
    let transport: SSHTransport
    var events: [SSHTransport.Event] = []

    init(port: UInt16, configuration: SSHTransport.Configuration) throws {
        fd = try LiveSSHD.connect(port: port)
        transport = SSHTransport(configuration: configuration)
        transport.start()
    }

    func close() { _ = Glibc_or_Darwin_close(fd) }

    func flush() throws {
        let out = transport.takeOutgoing()
        var sent = 0
        while sent < out.count {
            let n = out[sent...].withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            guard n > 0 else { throw POSIXError(.EPIPE) }
            sent += n
        }
    }

    /// Pumps until `done(events so far)` or the timeout. Returns false on timeout.
    @discardableResult
    mutating func run(timeout: TimeInterval = 20, until done: ([SSHTransport.Event]) -> Bool) throws -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        var buffer = [UInt8](repeating: 0, count: 65536)
        while Date() < deadline {
            try flush()
            if done(events) { return true }
            var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&p, 1, 100)
            if ready <= 0 { continue }
            let n = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if n <= 0 { throw POSIXError(.ECONNRESET) }
            try transport.receive(buffer[0..<n])
            events += transport.takeEvents()
        }
        return done(events)
    }
}

#if canImport(Glibc)
private let Glibc_or_Darwin_close = Glibc.close
#else
private let Glibc_or_Darwin_close = Darwin.close
#endif

/// A private ssh-agent on a temp socket, for agent tests. Nothing of the
/// user's agent is touched.
final class LiveAgent {
    let socketPath: String
    private let process: Process

    init() throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/ssh-agent") else { throw XCTSkip("no ssh-agent") }
        // Short path: sun_path is ~104 bytes on macOS.
        socketPath = "/tmp/sheepssh-agent-\(getpid())-\(UInt32.random(in: 0...UInt32.max))"
        process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-agent")
        process.arguments = ["-D", "-a", socketPath]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        for _ in 0..<200 where !FileManager.default.fileExists(atPath: socketPath) { usleep(10_000) }
    }

    /// ssh-add a private key file.
    func add(_ path: String) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-add")
        p.arguments = [path]
        p.environment = ["SSH_AUTH_SOCK": socketPath]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw XCTSkip("ssh-add \(path) failed") }
    }

    deinit {
        process.terminate()
        process.waitUntilExit()
        try? FileManager.default.removeItem(atPath: socketPath)
    }
}
