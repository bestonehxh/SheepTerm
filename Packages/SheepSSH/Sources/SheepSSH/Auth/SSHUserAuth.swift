// User authentication (RFC 4252 + keyboard-interactive, RFC 4256), sans-I/O
// on top of SSHTransport. The caller decides WHAT to try and in which order
// (SSHWorker keeps its none → keys → password/keyboard-interactive policy and
// its prompts); this type does the wire format and tells it what came back.
//
//   let auth = SSHUserAuth(transport: t, username: "admin")
//   try auth.requestService()                       // once, after .ready
//   try auth.handle(payload)  → [Event]             // every .message before success
//   try auth.tryNone() / tryPassword(_:) / tryPublicKey(_:) / startKeyboardInteractive()
//   try auth.respond(to: request, answers)          // for .infoRequest
//
// One method is in flight at a time; starting another before its answer
// arrives is a programming error and throws.

public enum UserAuthError: Error, Equatable, Sendable {
    case protocolError(String)
    /// A method was started while another one waits for its answer.
    case methodInProgress
    case notReady
    case signer(SignerError)
    case transport(SSHTransportError)
}

public final class SSHUserAuth {
    public struct InfoRequest: Sendable, Equatable {
        public let name: String
        public let instruction: String
        public let prompts: [(text: String, echo: Bool)]

        public static func == (a: InfoRequest, b: InfoRequest) -> Bool {
            a.name == b.name && a.instruction == b.instruction && a.prompts.count == b.prompts.count
                && zip(a.prompts, b.prompts).allSatisfy { $0.text == $1.text && $0.echo == $1.echo }
        }
    }

    public enum Method: String, Sendable {
        case none, password, publicKeyQuery = "publickey-query", publicKey = "publickey", keyboardInteractive = "keyboard-interactive"
    }

    public enum Event: Sendable, Equatable {
        case serviceAccepted
        /// Authenticated. Everything after this belongs to the connection layer.
        case success
        /// The method in flight did not (fully) succeed. `methods` is what may
        /// continue; `partialSuccess` means it worked but more is required
        /// (sshd's AuthenticationMethods).
        case failure(method: Method, methods: [String], partialSuccess: Bool)
        /// SSH_MSG_USERAUTH_BANNER — the device's login banner, to show.
        case banner(String)
        /// SSH_MSG_USERAUTH_PK_OK: the server would accept this key; sign next.
        case publicKeyAcceptable(SSHPublicKey)
        /// keyboard-interactive wants answers (possibly zero prompts).
        case infoRequest(InfoRequest)
        /// The server wants a new password (SSH_MSG_USERAUTH_PASSWD_CHANGEREQ);
        /// SheepTerm does not change passwords, so this ends the method.
        case passwordChangeRequested(prompt: String)
    }

    public static let service = "ssh-connection"
    /// Upper bound on prompts in one INFO_REQUEST — a real device asks 1–3.
    static let maximumPrompts = 64

    public let transport: SSHTransport
    public let username: String
    public private(set) var isAuthenticated = false
    public private(set) var serviceAccepted = false
    private var inFlight: Method?
    private var pendingKey: SSHPublicKey?

    public init(transport: SSHTransport, username: String) {
        self.transport = transport
        self.username = username
    }

    // MARK: Requests

    public func requestService() throws(UserAuthError) {
        var w = SSHWriter()
        w.writeByte(SSHMessage.serviceRequest)
        w.writeString("ssh-userauth")
        try send(w.bytes)
    }

    private func header(_ method: String) -> SSHWriter {
        var w = SSHWriter(capacity: 256)
        w.writeByte(50)                          // SSH_MSG_USERAUTH_REQUEST
        w.writeString(username)
        w.writeString(Self.service)
        w.writeString(method)
        return w
    }

    private func begin(_ method: Method) throws(UserAuthError) {
        guard serviceAccepted, !isAuthenticated else { throw .notReady }
        guard inFlight == nil else { throw .methodInProgress }
        inFlight = method
    }

    /// "none": succeeds on servers without authentication, otherwise lists
    /// the methods the server takes.
    public func tryNone() throws(UserAuthError) {
        try begin(.none)
        try send(header("none").bytes)
    }

    public func tryPassword(_ password: String) throws(UserAuthError) {
        try begin(.password)
        var w = header("password")
        w.writeBool(false)
        w.writeString(password)
        try send(w.bytes)
    }

    /// Asks whether the server would take this key, without signing
    /// (so an agent is not asked to sign for a key that will be refused).
    public func queryPublicKey(_ key: SSHPublicKey, algorithm: String) throws(UserAuthError) {
        try begin(.publicKeyQuery)
        pendingKey = key
        var w = header("publickey")
        w.writeBool(false)
        w.writeString(algorithm)
        w.writeString(key.blob)
        try send(w.bytes)
    }

    /// Signs and sends. `algorithm` from `publicKeyAlgorithm(for:…)`.
    public func tryPublicKey(_ signer: SSHSigner, algorithm: String) throws(UserAuthError) {
        guard let sessionID = transport.sessionID else { throw .notReady }
        try begin(.publicKey)
        var w = header("publickey")
        w.writeBool(true)
        w.writeString(algorithm)
        w.writeString(signer.publicKey.blob)
        // RFC 4252 §7: the signature covers session id ‖ this request so far.
        var signed = SSHWriter(capacity: 512)
        signed.writeString(sessionID)
        signed.writeBytes(w.bytes)
        let signature: [UInt8]
        do {
            signature = try signer.sign(signed.bytes, algorithm: algorithm)
        } catch {
            inFlight = nil
            throw .signer(error)
        }
        w.writeString(signature)
        try send(w.bytes)
    }

    public func startKeyboardInteractive() throws(UserAuthError) {
        try begin(.keyboardInteractive)
        var w = header("keyboard-interactive")
        w.writeString("")                        // language
        w.writeString("")                        // submethods
        try send(w.bytes)
    }

    /// Answers the last `.infoRequest`, one answer per prompt.
    public func respond(_ answers: [String]) throws(UserAuthError) {
        guard inFlight == .keyboardInteractive else { throw .protocolError("no keyboard-interactive exchange to answer") }
        var w = SSHWriter()
        w.writeByte(61)                          // SSH_MSG_USERAUTH_INFO_RESPONSE
        w.writeUInt32(UInt32(answers.count))
        for a in answers { w.writeString(a) }
        try send(w.bytes)
    }

    private func send(_ payload: [UInt8]) throws(UserAuthError) {
        do { try transport.send(payload) } catch { throw .transport(error) }
    }

    // MARK: Replies

    /// Feed every transport `.message` until `.success`. Messages that are not
    /// userauth replies are a protocol error before authentication.
    public func handle(_ payload: [UInt8]) throws(UserAuthError) -> [Event] {
        guard let type = payload.first else { throw .protocolError("empty message") }
        var r = SSHReader(payload, from: 1)
        do {
            switch type {
            case SSHMessage.serviceAccept:
                // OpenSSH accepts a bare SERVICE_ACCEPT ("buggy server:
                // service_accept w/o service"), libssh does not parse it.
                if !r.isAtEnd, try r.readUTF8() != "ssh-userauth" {
                    throw UserAuthError.protocolError("wrong service accepted")
                }
                serviceAccepted = true
                return [.serviceAccepted]
            case 53:                             // BANNER
                let message = try r.readText()
                return [.banner(message)]
            case 52:                             // SUCCESS
                guard inFlight != nil, inFlight != .publicKeyQuery else {
                    throw UserAuthError.protocolError("USERAUTH_SUCCESS with no method in flight")
                }
                inFlight = nil
                isAuthenticated = true
                return [.success]
            case 51:                             // FAILURE
                guard let method = inFlight else { throw UserAuthError.protocolError("USERAUTH_FAILURE with no method in flight") }
                let methods = try r.readNameList()
                let partial = try r.readBool()
                inFlight = nil
                pendingKey = nil
                return [.failure(method: method, methods: methods, partialSuccess: partial)]
            case 60:                             // PK_OK / PASSWD_CHANGEREQ / INFO_REQUEST
                switch inFlight {
                case .publicKeyQuery:
                    _ = try r.readString()       // algorithm
                    let blob = try r.readString()
                    guard let key = pendingKey else {
                        throw UserAuthError.protocolError("PK_OK for a key that was not offered")
                    }
                    // Byte-identical, or the same key re-encoded (a device
                    // that rebuilds it from its stored form, mpint padding
                    // changed): OpenSSH compares the parsed keys. Anything
                    // else is "not this key" — move on, don't abort.
                    guard key.blob == blob || (try? SSHPublicKey(blob: blob))?.sameKey(as: key) == true else {
                        inFlight = nil
                        pendingKey = nil
                        return [.failure(method: .publicKeyQuery, methods: [], partialSuccess: false)]
                    }
                    inFlight = nil
                    pendingKey = nil
                    return [.publicKeyAcceptable(key)]
                case .password:
                    let prompt = try r.readText()
                    inFlight = nil
                    return [.passwordChangeRequested(prompt: prompt)]
                case .keyboardInteractive:
                    let name = try r.readText()
                    let instruction = try r.readText()
                    _ = try r.readString()       // language
                    let count = try r.readUInt32()
                    guard count <= Self.maximumPrompts else {
                        throw UserAuthError.protocolError("keyboard-interactive with \(count) prompts")
                    }
                    var prompts: [(text: String, echo: Bool)] = []
                    for _ in 0..<count {
                        let text = try r.readText()
                        prompts.append((text, try r.readBool()))
                    }
                    return [.infoRequest(InfoRequest(name: name, instruction: instruction, prompts: prompts))]
                default:
                    throw UserAuthError.protocolError("message 60 with no method that expects it")
                }
            case 80:                             // GLOBAL_REQUEST (a keepalive while a prompt is up)
                // libssh answers these in any phase; failing the login over
                // one ended a password or OTP prompt the user was typing in.
                _ = try r.readString()
                if try r.readBool() { try send([82]) }   // REQUEST_FAILURE
                return []
            default:
                throw UserAuthError.protocolError("unexpected message \(type) during authentication")
            }
        } catch let error as UserAuthError {
            throw error
        } catch {
            throw .protocolError("malformed userauth message \(type)")
        }
    }
}

/// The key files libssh's publickey_auto tried, in its order.
public enum DefaultIdentities {
    public static let fileNames = ["id_ed25519", "id_ecdsa", "id_rsa"]

    public enum Entry {
        case ready(PrivateKeySigner)
        /// Exists but needs a passphrase; the public half is known when the
        /// file is in OpenSSH format (so the server can be asked first).
        case encrypted(path: String, publicKey: SSHPublicKey?)
        case unreadable(path: String, reason: String)
    }

    /// Reads `<directory>/id_*`. Missing files are skipped silently.
    public static func load(directory: String) -> [Entry] {
        var out: [Entry] = []
        for name in fileNames {
            let path = directory + "/" + name
            guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
            if PEMPrivateKey.isEncrypted(text) {
                let pub = (try? OpenSSHPrivateKeyFile(text: text))?.publicKey
                out.append(.encrypted(path: path, publicKey: pub))
                continue
            }
            do {
                out.append(.ready(PrivateKeySigner(try PEMPrivateKey.load(text, passphrase: nil), label: "file \(path)")))
            } catch {
                out.append(.unreadable(path: path, reason: "\(error)"))
            }
        }
        return out
    }
}

import Foundation
