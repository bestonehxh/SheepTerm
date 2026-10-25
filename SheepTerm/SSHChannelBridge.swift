import Foundation
import SheepSSH
import Synchronization

// A Files tab riding a terminal tab's own SSH connection (no second login).
// The connection belongs to the SSHWorker's queue; the Files tab's engine
// runs on its own. The bridge carries commands one way and connection
// events the other under one lock, and each side pokes the other's
// self-pipe. The engine only ever sees the bridge's own channel numbers;
// the real ones live on the worker queue.
//
// - Inbound is flow-controlled: the channels use a manual window that
//   reopens only as the engine TAKES the bytes, so a slow disk stops the
//   device instead of growing this Mac's memory.
// - Outbound goes to the connection only after the terminal's own input,
//   and only while the socket backlog is small: a big upload never makes
//   typing wait behind it.
// - The worker ending (logout, a drop, a closed tab) ends every bridge with
//   a reason; the engine reports the Files session lost.
// - Nothing here sends a byte on its own: channels open only when the
//   engine asks (the user opened Files).
nonisolated final class SSHChannelBridge: Sendable {
    enum Command: Sendable, Equatable {
        case open(UInt32)
        case subsystem(UInt32, String)
        case exec(UInt32, String)
        case write(UInt32, [UInt8])
        case close(UInt32)
    }

    private struct State: Sendable {
        var commands: [Command] = []
        var events: [SSHConnection.Event] = []
        /// Bytes the engine took per channel, not yet reported to the
        /// connection (the manual window reopens by that much).
        var taken: [UInt32: Int] = [:]
        /// Queued in `commands` + waiting in the connection, per channel.
        var queuedOut: [UInt32: Int] = [:]
        var connectionPending: [UInt32: Int] = [:]
        var open: Set<UInt32> = []
        var nextID: UInt32 = 1
        var lost: String?
        var detached = false
        var engineWake: (@Sendable () -> Void)?
        var workerWake: Int32 = -1
    }

    private let state = Mutex(State())

    /// Channels at once on one bridge (an SFTP channel + an SCP one).
    static let maximumChannels = 4

    init(workerWake: Int32) {
        state.withLock { $0.workerWake = workerWake }
    }

    /// Inside the lock: `end()` clears the fd under the same lock before
    /// the worker closes its pipe, so a reused descriptor is never poked.
    /// The write end is non-blocking.
    private static func poke(_ fd: Int32) {
        guard fd >= 0 else { return }
        var byte: UInt8 = 1
        _ = Darwin.write(fd, &byte, 1)
    }

    // MARK: Engine side (the Files engine's queue)

    /// Wakes the engine's poll when events arrive or the bridge is lost
    /// (the engine's self-pipe; poking it after it closed is a no-op).
    func setEngineWake(_ poke: @escaping @Sendable () -> Void) {
        state.withLock { $0.engineWake = poke }
    }

    var lost: String? { state.withLock { $0.lost } }

    private func enqueue(_ command: Command) throws(BridgeError) {
        try state.withLock { s throws(BridgeError) in
            if let lost = s.lost { throw .lost(lost) }
            if s.detached { throw .lost("closed") }
            s.commands.append(command)
            if case .write(let id, let bytes) = command { s.queuedOut[id, default: 0] += bytes.count }
            Self.poke(s.workerWake)
        }
    }

    enum BridgeError: Error, Equatable {
        case lost(String)
        case tooManyChannels
    }

    func openSessionChannel() throws(BridgeError) -> UInt32 {
        let id = try state.withLock { s throws(BridgeError) -> UInt32 in
            if let lost = s.lost { throw .lost(lost) }
            guard s.open.count < Self.maximumChannels else { throw .tooManyChannels }
            let id = s.nextID
            s.nextID &+= 1
            s.open.insert(id)
            return id
        }
        try enqueue(.open(id))
        return id
    }

    func requestSubsystem(_ id: UInt32, _ name: String) throws(BridgeError) { try enqueue(.subsystem(id, name)) }
    func requestExec(_ id: UInt32, command: String) throws(BridgeError) { try enqueue(.exec(id, command)) }
    func write(_ id: UInt32, _ bytes: [UInt8]) throws(BridgeError) {
        guard !bytes.isEmpty else { return }
        try enqueue(.write(id, bytes))
    }

    func close(_ id: UInt32) {
        state.withLock { s in
            guard s.lost == nil, !s.detached, s.open.contains(id) else { return }
            s.commands.append(.close(id))
            Self.poke(s.workerWake)
        }
    }

    func isOpen(_ id: UInt32) -> Bool { state.withLock { $0.lost == nil && $0.open.contains(id) } }

    /// Bytes written on `id` and not yet on the wire (bridge queue +
    /// connection backlog) — the same back-pressure signal the engine reads
    /// from SSHConnection.pendingOutput on its own connection.
    func pendingOutput(_ id: UInt32) -> Int {
        state.withLock { ($0.queuedOut[id] ?? 0) + ($0.connectionPending[id] ?? 0) }
    }

    /// Everything the worker passed over since the last call. Data handed
    /// out here counts as consumed: the window reopens by that much.
    func takeEvents() -> [SSHConnection.Event] {
        state.withLock { s -> [SSHConnection.Event] in
            let events = s.events
            s.events.removeAll()
            var credited = false
            for event in events {
                switch event {
                case .data(let id, let bytes), .extendedData(let id, let bytes):
                    s.taken[id, default: 0] += bytes.count
                    credited = true
                case .closed(let id):
                    s.open.remove(id)
                default: break
                }
            }
            if credited { Self.poke(s.workerWake) }
            return events
        }
    }

    var hasEvents: Bool { state.withLock { !$0.events.isEmpty } }

    /// The engine is done: its channels close, nothing more is delivered.
    func detach() {
        state.withLock { s in
            guard !s.detached else { return }
            s.detached = true
            s.engineWake = nil
            if s.lost == nil { for id in s.open.sorted() { s.commands.append(.close(id)) } }
            Self.poke(s.workerWake)
        }
    }

    var isDetached: Bool { state.withLock { $0.detached } }

    // MARK: Worker side (the SSHWorker's queue)

    /// proxy id ↔ real channel number. Worker-queue confined.
    private final class Map: @unchecked Sendable {
        var real: [UInt32: UInt32] = [:]
        var proxy: [UInt32: UInt32] = [:]
        /// Commands waiting because the socket backlog is full.
        var held: [Command] = []
        /// Real channels the engine closed before they were confirmed.
        var closeOnOpen: Set<UInt32> = []
    }
    private let map = Map()

    /// The channel an event is about (nil for connection-wide ones).
    static func channel(of event: SSHConnection.Event) -> UInt32? {
        switch event {
        case .channelOpened(let id), .channelOpenFailed(let id, _, _), .channelRequestReply(let id, _, _),
             .data(let id, _), .extendedData(let id, _), .eof(let id), .closed(let id),
             .exitStatus(let id, _), .exitSignal(let id, _, _):
            return id
        case .globalReply, .agentChannelOpened, .remoteForwardReply, .forwardedChannelOpened:
            return nil
        }
    }

    /// The engine left and every channel is closed: the worker drops it.
    var isFinished: Bool {
        (isDetached || lost != nil) && map.real.isEmpty && map.held.isEmpty
    }

    /// True when a channel number is one of this bridge's.
    func owns(_ real: UInt32) -> Bool { map.proxy[real] != nil }

    /// Commands still waiting for room in the socket backlog: the worker
    /// should poll again soon instead of sleeping a second.
    var wantsPromptPump: Bool { !map.held.isEmpty }

    /// Hands queued commands to the connection. Writes stop while the
    /// socket backlog is over `unsentLimit` (they wait for the next pass).
    /// Never throws: a command the connection refuses ends THAT channel
    /// (the engine hears it closed), never the terminal session — if the
    /// transport itself died, the worker's own step says so.
    func service(connection: SSHConnection, unsentBytes: () -> Int, unsentLimit: Int = 512 * 1024) {
        let (fresh, taken) = state.withLock { s -> ([Command], [UInt32: Int]) in
            defer { s.commands.removeAll(); s.taken.removeAll() }
            return (s.commands, s.taken)
        }
        for (id, count) in taken {
            if let real = map.real[id] { try? connection.consumed(real, count) }
        }
        let queue = map.held + fresh
        map.held.removeAll()
        var sentBytes: [UInt32: Int] = [:]
        var newEvents: [SSHConnection.Event] = []
        func fail(_ id: UInt32) {
            if let real = map.real[id] {
                if connection.isOpen(real) { try? connection.close(real) }
                forget(real: real, proxy: id)
            }
            newEvents.append(.closed(id))
        }
        var index = 0
        commands: while index < queue.count {
            let command = queue[index]
            index += 1
            switch command {
            case .open(let id):
                do {
                    let real = try connection.openSession(manualWindow: true)
                    map.real[id] = real
                    map.proxy[real] = id
                } catch {
                    newEvents.append(.channelOpenFailed(id, reason: 0, description: "the terminal session could not open a channel"))
                }
            case .subsystem(let id, let name):
                guard let real = map.real[id] else { continue }
                do { try connection.requestSubsystem(real, name) } catch { fail(id) }
            case .exec(let id, let line):
                guard let real = map.real[id] else { continue }
                do { try connection.requestExec(real, command: line) } catch { fail(id) }
            case .write(let id, let bytes):
                guard let real = map.real[id], connection.isOpen(real) else {
                    sentBytes[id, default: 0] += bytes.count
                    continue
                }
                if unsentBytes() > unsentLimit || connection.pendingOutput(real) > 1024 * 1024 {
                    map.held = Array(queue[(index - 1)...])
                    break commands
                }
                do { try connection.write(real, bytes) } catch { fail(id) }
                sentBytes[id, default: 0] += bytes.count
            case .close(let id):
                guard let real = map.real[id] else {
                    newEvents.append(.closed(id))
                    continue
                }
                if connection.isOpen(real) {
                    try? connection.close(real)
                } else {
                    // Not confirmed yet: closed the moment it is (`deliver`).
                    map.closeOnOpen.insert(real)
                }
            }
        }
        let pending = map.real.reduce(into: [UInt32: Int]()) { $0[$1.key] = connection.pendingOutput($1.value) }
        let wake: (@Sendable () -> Void)? = state.withLock { s in
            for (id, count) in sentBytes { s.queuedOut[id] = max(0, (s.queuedOut[id] ?? 0) - count) }
            s.connectionPending = pending
            guard !newEvents.isEmpty, !s.detached else { return nil }
            s.events += newEvents
            return s.engineWake
        }
        wake?()
    }

    /// A connection event for one of this bridge's channels (`owns`).
    func deliver(_ event: SSHConnection.Event, connection: SSHConnection) {
        // The engine closed it before the device confirmed it: close it now.
        if case .channelOpened(let real) = event, map.closeOnOpen.remove(real) != nil {
            try? connection.close(real)
            return
        }
        func translated(_ real: UInt32) -> UInt32? { map.proxy[real] }
        let out: SSHConnection.Event?
        switch event {
        case .channelOpened(let r): out = translated(r).map { .channelOpened($0) }
        case .channelOpenFailed(let r, let reason, let description):
            out = translated(r).map { .channelOpenFailed($0, reason: reason, description: description) }
            if let id = translated(r) { forget(real: r, proxy: id) }
        case .channelRequestReply(let r, let request, let success):
            out = translated(r).map { .channelRequestReply($0, request: request, success: success) }
        case .data(let r, let bytes): out = translated(r).map { .data($0, bytes) }
        case .extendedData(let r, let bytes): out = translated(r).map { .extendedData($0, bytes) }
        case .eof(let r): out = translated(r).map { .eof($0) }
        case .closed(let r):
            out = translated(r).map { .closed($0) }
            if let id = translated(r) { forget(real: r, proxy: id) }
        case .exitStatus(let r, let code): out = translated(r).map { .exitStatus($0, code) }
        case .exitSignal(let r, let signal, let message):
            out = translated(r).map { .exitSignal($0, signal: signal, message: message) }
        default: out = nil
        }
        guard let out else { return }
        let wake: (@Sendable () -> Void)? = state.withLock { s in
            guard !s.detached else { return nil }
            s.events.append(out)
            return s.engineWake
        }
        wake?()
    }

    private func forget(real: UInt32, proxy: UInt32) {
        map.real.removeValue(forKey: proxy)
        map.proxy.removeValue(forKey: real)
        map.held.removeAll { command in
            switch command {
            case .write(proxy, _), .subsystem(proxy, _), .exec(proxy, _), .close(proxy): return true
            default: return false
            }
        }
    }

    /// The terminal session is over: the engine hears why.
    func end(_ why: String) {
        let wake: (@Sendable () -> Void)? = state.withLock { s in
            guard s.lost == nil else { return nil }
            s.lost = why
            s.workerWake = -1
            return s.engineWake
        }
        wake?()
    }
}
