// Ping engine, from SheepPing (PingCore.swift): one long-lived /sbin/ping -i
// (ping6 for IPv6) per target, a line parser, and a watchdog for lost replies.
// Kept nonisolated and Foundation-only so the harness compiles it.

import Foundation

// MARK: - PingResult  (Sendable: crosses actor boundaries)
//
// `nonisolated` is load-bearing: the project sets SWIFT_DEFAULT_ACTOR_ISOLATION
// to MainActor, so without it this value — built on a background thread by the
// ping stream and read again off the main actor by tests — inherits MainActor
// isolation and its own producer cannot touch its properties.
nonisolated struct PingResult: Sendable {
    let isSuccess: Bool
    let resolvedIP: String
    let latency: Double?
    let message: String
}

// MARK: - Sendable plumbing for the ping subprocess
//
// Process and Pipe are not Sendable, and `Process.terminationHandler` is a
// `@Sendable` closure, so under Swift 6 nothing that touches them may be
// captured directly. PingProcessBox owns the Process and hands out only Sendable
// operations; whatever reads the pipe (see PingLineReader) deliberately holds
// no reference back to the Process, so the handler cannot form a retain cycle.

private nonisolated final class PingProcessBox: @unchecked Sendable {
    private let lock = NSLock()
    private let process = Process()
    private var didLaunch = false
    private var killRequested = false

    init(executable: String, arguments: [String], pipe: Pipe) {
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe
    }

    func setTerminationHandler(_ handler: @escaping @Sendable (Process) -> Void) {
        process.terminationHandler = handler
    }

    func run() throws {
        lock.lock(); defer { lock.unlock() }
        try process.run()
        didLaunch = true
        // A sub-second deadline can fire before run() gets here. Honour the kill
        // now instead of leaving an orphan ping running out its own -t.
        if killRequested { process.terminate() }
    }

    /// Safe before launch, after exit, and from another thread.
    func terminate() {
        lock.lock(); defer { lock.unlock() }
        killRequested = true
        guard didLaunch, process.isRunning else { return }
        process.terminate()
    }
}

// MARK: - Free functions that run off MainActor
// nonisolated opts out of the default @MainActor isolation set by the project.

// macOS ships two separate ping binaries and they are NOT interchangeable:
// /sbin/ping speaks IPv4 only and answers any IPv6 literal with
// "cannot resolve <addr>: Unknown host", while /sbin/ping6 speaks IPv6.
// /sbin/ping also rejects a -6 flag outright, so the binary is the only switch.
nonisolated func pingExecutable(for address: String) -> String {
    address.contains(":") ? "/sbin/ping6" : "/sbin/ping"
}

// Pulls the peer address out of a reply line, handling both families:
//   IPv4  "64 bytes from 8.8.8.8: icmp_seq=0 ttl=118 time=12.3 ms"
//   IPv6  "16 bytes from 2606:4700:4700::1111, icmp_seq=0 hlim=57 time=11.4 ms"
// Splitting on ":" (as this used to) truncates every IPv6 address to its first
// group, so stop at the real separators instead and strip the trailing punctuation.
nonisolated func extractReplyIP(_ line: String) -> String? {
    guard let from = line.range(of: "from ") else { return nil }
    // Only the *trailing* punctuation is a separator. Trimming both ends (as this
    // used to) ate the leading colons of an address like "::1", reporting it as "1".
    var token = line[from.upperBound...].prefix(while: { $0 != " " && $0 != "," })
    while let last = token.last, last == ":" || last == "," { token = token.dropLast() }
    return token.isEmpty ? nil : String(token)
}

// True for reply lines and transport errors that mean "this ping did not succeed".
// Matched case-insensitively because the wording differs between ping and ping6.
// Hoisted out of the function: this runs once per line of a stream that never
// stops, so rebuilding the literal each time was pure waste.
private nonisolated let pingFailurePhrases = [
    "timeout", "unreachable", "cannot resolve", "no route", "network is down",
    "time to live exceeded", "prohibited", "frag needed", "host is down",
    "getaddrinfo", "not permitted", "filtered", "parameter problem",
    "source quench", "redirect", "bad checksum", "net unknown", "host unknown",
]

// Purely informational ICMP notices. They are printed *alongside* the packet
// they relate to, not instead of it, so a live stream must not count one as a
// lost packet — if the packet really was lost, ping prints its own
// "Request timeout for icmp_seq N" line right after.
private nonisolated let pingNoticePhrases = ["redirect", "source quench"]

nonisolated func isPingFailureLine(_ line: String) -> Bool {
    let l = line.lowercased()
    return pingFailurePhrases.contains { l.contains($0) }
}

nonisolated func isPingNoticeLine(_ line: String) -> Bool {
    let l = line.lowercased()
    return pingNoticePhrases.contains { l.contains($0) }
}

/// The resolved address as printed in ping's banner:
///   "PING google.com (142.250.204.78): 56 data bytes"
///   "PING6(56=40+8+8 bytes) 2001:db8::1 --> 2606:4700:4700::1111"
nonisolated func pingBannerIP(_ line: String) -> String? {
    guard line.hasPrefix("PING") else { return nil }
    if let open = line.range(of: "("), let close = line.range(of: ")"),
       open.upperBound <= close.lowerBound {
        let inner = String(line[open.upperBound..<close.lowerBound])
        if !inner.contains(" "), inner.contains(".") || inner.contains(":") {
            return inner
        }
    }
    if let arrow = line.range(of: "--> ") {
        let tail = String(line[arrow.upperBound...]).trimmingCharacters(in: .whitespaces)
        if !tail.isEmpty { return tail }
    }
    return nil
}

/// The round-trip time carried by a reply line, in milliseconds.
nonisolated func pingReplyLatency(_ line: String) -> Double? {
    guard line.contains("bytes from"), let range = line.range(of: "time=") else { return nil }
    return Double(String(line[range.upperBound...].prefix(while: { $0.isNumber || $0 == "." })))
}

// MARK: - Single-line parsing (used by the continuous stream)

nonisolated enum PingLineEvent: Sendable {
    /// ping told us which address it actually resolved to.
    case banner(String)
    /// This line settles one packet, one way or the other.
    case result(PingResult)
}

/// Verdict for one line of a continuously running ping.
///
/// `headerIP` is the banner address seen so far, used when a line has no source
/// of its own (a timeout line names no host).
nonisolated func parsePingLine(_ rawLine: String, address: String, headerIP: String) -> PingLineEvent? {
    let t = rawLine.trimmingCharacters(in: .whitespaces)
    guard !t.isEmpty else { return nil }

    if let ip = pingBannerIP(t) { return .banner(ip) }
    // A banner we could not read an address out of still is not a verdict.
    if t.hasPrefix("PING") { return nil }

    // Summary lines belong to a run that is ending, not to a packet.
    if t.hasPrefix("---") || t.contains("round-trip") || t.contains("packets transmitted") {
        return nil
    }

    if t.hasPrefix("ping:") || t.hasPrefix("ping6:") || t.hasPrefix("usage:") {
        return .result(PingResult(isSuccess: false, resolvedIP: headerIP, latency: nil, message: t))
    }

    if let ms = pingReplyLatency(t) {
        // A "(DUP!)" line is a second copy of a reply that was already counted;
        // scoring it again inflates the success count past packets actually sent.
        if t.contains("(DUP!)") { return nil }
        return .result(PingResult(isSuccess: true,
                                  resolvedIP: extractReplyIP(t) ?? headerIP,
                                  latency: ms, message: t))
    }

    // See pingNoticePhrases: the packet's real verdict is still coming.
    if isPingNoticeLine(t) { return nil }

    if isPingFailureLine(t) {
        return .result(PingResult(isSuccess: false, resolvedIP: headerIP, latency: nil, message: t))
    }
    return nil
}

// MARK: - PingStream (one long-lived ping per host)
//
// The session used to run `ping -c 1` once per tick. At 20 hosts on a 0.5 s
// interval that forked a setuid-root binary 40 times a second, and every fork
// paid DNS resolution and socket setup again. `ping -i <interval>` does the same
// work in one process per host: it is line-buffered through a pipe, and with -W
// it prints its own "Request timeout for icmp_seq N" for a lost packet, so each
// line out is exactly one packet's verdict.

/// -i is the send interval; -W is the per-reply wait, in milliseconds.
/// ping6 accepts neither -W nor -t, so on IPv6 the stream watchdog below is the
/// only reply timeout there is.
nonisolated func pingStreamArguments(for address: String, interval: Double, timeout: Double) -> [String] {
    // Below 0.1 s -i is root-only; PingPlan.intervals all sit above it.
    let wait = String(format: "%.2f", max(0.1, interval))
    // A packet count (about an hour) so a ping always ends by itself: a
    // silent IPv6 target never writes, so SIGPIPE would never come after an
    // app crash and ping6 would run until reboot (review 6.0 (2)). The
    // tab's loop starts the next one.
    let count = "\(max(1, Int((3600 / max(0.1, interval)).rounded())))"
    if address.contains(":") { return ["-c", count, "-i", wait, address] }
    return ["-c", count, "-i", wait, "-W", "\(max(1, Int((timeout * 1000).rounded())))", address]
}

private nonisolated final class PingStreamState: @unchecked Sendable {
    private let lock = NSLock()
    private var lastVerdict = ContinuousClock.now
    private var header = ""

    var headerIP: String {
        lock.lock(); defer { lock.unlock() }
        return header
    }

    func setHeaderIP(_ ip: String) {
        lock.lock(); header = ip; lock.unlock()
    }

    func markVerdict() {
        lock.lock(); lastVerdict = .now; lock.unlock()
    }

    func hasBeenQuiet(longerThan limit: Duration) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return ContinuousClock.now - lastVerdict > limit
    }
}

/// Splits the pipe into lines and turns each one into a verdict.
private nonisolated final class PingLineReader: @unchecked Sendable {
    let pipe = Pipe()

    private let lock = NSLock()
    private var buffer = Data()
    private let address: String
    private let state: PingStreamState
    private let onResult: @Sendable (PingResult) -> Void

    init(address: String, state: PingStreamState, onResult: @escaping @Sendable (PingResult) -> Void) {
        self.address = address
        self.state = state
        self.onResult = onResult
    }

    func start() {
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard let self else { return }
            if chunk.isEmpty {
                // Write end closed: the child is gone. The termination handler
                // does the rest; just stop being called back in a tight loop.
                self.stop()
                return
            }
            self.ingest(chunk)
        }
    }

    func stop() {
        pipe.fileHandleForReading.readabilityHandler = nil
    }


    private func ingest(_ chunk: Data) {
        var lines: [String] = []

        lock.lock()
        buffer.append(chunk)
        while let newline = buffer.firstIndex(of: 0x0A) {
            lines.append(String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self))
            buffer.removeSubrange(buffer.startIndex...newline)
        }
        // A run that never emits a newline must not grow without bound.
        if buffer.count > 64 * 1024 { buffer.removeAll(keepingCapacity: false) }
        lock.unlock()

        for line in lines {
            switch parsePingLine(line, address: address, headerIP: state.headerIP) {
            case .banner(let ip):
                state.setHeaderIP(ip)
            case .result(let result):
                state.markVerdict()
                onResult(result)
            case nil:
                break
            }
        }
    }
}

nonisolated final class PingStream: @unchecked Sendable {
    /// One element per packet, for as long as the underlying ping keeps running.
    /// Finishes when the child exits (bad route, killed) so the caller can decide
    /// whether to respawn.
    let results: AsyncStream<PingResult>

    private let continuation: AsyncStream<PingResult>.Continuation

    init(address: String, interval: Double, timeout: Double) {
        // Drop stale packets rather than stall the reader if the UI falls behind.
        let (stream, continuation) = AsyncStream<PingResult>.makeStream(
            bufferingPolicy: .bufferingNewest(16)
        )
        results = stream
        self.continuation = continuation

        let state = PingStreamState()
        let reader = PingLineReader(address: address, state: state) { result in
            continuation.yield(result)
        }
        let box = PingProcessBox(
            executable: pingExecutable(for: address),
            arguments: pingStreamArguments(for: address, interval: interval, timeout: timeout),
            pipe: reader.pipe
        )

        // Backstop, and the only reply timeout on IPv6: if no line has settled a
        // packet for longer than one interval plus the reply deadline, report the
        // loss ourselves rather than letting the row sit on a stale "OK".
        let quietLimit = Duration.seconds(interval + max(timeout, 1.0))
        let tick = Duration.seconds(max(0.25, interval / 2))
        let watchdog = Task.detached(priority: .utility) { [state] in
            while !Task.isCancelled {
                try? await Task.sleep(for: tick)
                guard !Task.isCancelled else { return }
                guard state.hasBeenQuiet(longerThan: quietLimit) else { continue }
                state.markVerdict()
                continuation.yield(PingResult(isSuccess: false, resolvedIP: state.headerIP,
                                              latency: nil,
                                              message: "Request timeout for \(address)"))
            }
        }

        continuation.onTermination = { [box, reader] _ in
            watchdog.cancel()
            box.terminate()
            reader.stop()
        }

        box.setTerminationHandler { [reader] _ in
            // No second read of the pipe here: it raced the readability
            // handler on the same fd (review 6.0 (2)); the handler sees EOF.
            reader.stop()
            continuation.finish()
        }

        reader.start()
        do {
            try box.run()
        } catch {
            continuation.yield(PingResult(isSuccess: false, resolvedIP: "", latency: nil,
                                          message: "Launch error: \(error.localizedDescription)"))
            continuation.finish()
        }
    }

    /// Ends the stream and kills the child. Safe to call more than once.
    func cancel() {
        continuation.finish()
    }
}

