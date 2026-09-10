//
//  ProcessTests.swift — SPEC "Phase 3 / E — pty".
//
//  These run real processes. Everything is deliberately tiny and bounded: the longest wait is
//  `terminate()` on `/bin/sleep 30`, which must finish well inside 2 s.
//
//  The delegate callbacks arrive via `DispatchQueue.main.async`, so a test has to let the main
//  queue drain: `waitFor` awaits `Task.sleep`, which yields the main thread back to its dispatch
//  loop between polls. A blocking `Thread.sleep` here would deadlock every one of these tests.
//

import Foundation
import Testing
@testable import SheepVTRender

/// The child's world: no inherited PATH surprises, and a TERM the shell is happy with.
private let childEnvironment = ["PATH=/usr/bin:/bin", "TERM=xterm-256color"]

/// Collects everything a `LocalProcess` reports.
@MainActor private final class Collector: LocalProcessDelegate {
    var bytes: [UInt8] = []
    /// Size of each delivered batch — the ≤ 64 KiB contract is checked against this.
    var batchSizes: [Int] = []
    var exitCode: Int32?
    var terminationCount = 0

    var text: String { String(decoding: bytes, as: UTF8.self) }

    func dataReceived(_ process: LocalProcess, bytes: [UInt8]) {
        batchSizes.append(bytes.count)
        self.bytes.append(contentsOf: bytes)
    }

    func processTerminated(_ process: LocalProcess, exitCode: Int32?) {
        terminationCount += 1
        self.exitCode = exitCode
    }
}

/// How many descriptors this process has open right now. `fcntl(F_GETFD)` answers EBADF for a
/// closed one and nothing else, so this is cheap enough to poll in a `waitFor` — which it has to
/// be, because both of `LocalProcess`'s closes happen on their owning queue, a hop after the main
/// actor asked for them.
private func openDescriptorCount() -> Int {
    var count = 0
    let limit = min(getdtablesize(), 4096)
    for fd in 0..<limit where fcntl(fd, F_GETFD) != -1 { count += 1 }
    return count
}

/// Counts and verifies a stream without storing it: 64 MiB is too much to keep, and what matters
/// about it is only that every byte arrived, in order, exactly once. A lost, doubled or reordered
/// byte breaks the alignment and every byte after it, so this catches far more than the count does.
@MainActor private final class Verifier: LocalProcessDelegate {
    /// The repeating unit the children below write. No newline in it, deliberately: with ONLCR on,
    /// macOS's tty layer re-emits the CR when its (1 KiB) output queue fills between the CR and the
    /// LF, so a blocked reader gets `sheep\r\r\n` roughly every 4 KiB. That is the kernel's, not
    /// ours — the same runs verify byte-exact once the newlines are gone — but it would make an
    /// exact check meaningless, so the children pipe through `tr -d` and this unit is 5 bytes.
    private let unit = Array("sheep".utf8)
    private var cursor = 0
    private(set) var count = 0
    private(set) var outOfOrderAt: Int?
    /// What actually arrived at the divergence, so a failure names the bytes instead of only the
    /// offset — a stray line from the child reads very differently from a shuffled batch.
    private(set) var divergence: [UInt8] = []
    private(set) var batchSizes: (max: Int, count: Int) = (0, 0)
    var exitCode: Int32?
    var terminationCount = 0

    func dataReceived(_ process: LocalProcess, bytes: [UInt8]) {
        batchSizes = (max(batchSizes.max, bytes.count), batchSizes.count + 1)
        for byte in bytes {
            if byte != unit[cursor], outOfOrderAt == nil { outOfOrderAt = count }
            if let start = outOfOrderAt, count - start < 48 { divergence.append(byte) }
            count += 1
            cursor += 1
            if cursor == unit.count { cursor = 0 }
        }
    }

    func processTerminated(_ process: LocalProcess, exitCode: Int32?) {
        terminationCount += 1
        self.exitCode = exitCode
    }
}

/// Resident size of this whole test process, the number Activity Monitor shows. A backlog of
/// `[UInt8]` waiting on the main queue is invisible to anything smaller.
///
/// `nonisolated`, like everything else the sampler thread touches: this target defaults to
/// MainActor isolation, so a plain global function called from a GCD queue traps in
/// `dispatch_assert_queue` — the same rule LocalProcess.swift's `nonisolated static` factories
/// exist for.
private nonisolated func residentBytes() -> UInt64 {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
    let ok = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
        }
    }
    return ok == KERN_SUCCESS ? info.resident_size : 0
}

/// Samples RSS from a background thread, because the test that needs it is holding the main thread
/// hostage on purpose and cannot sample anything itself.
private nonisolated final class ResidentSampler: @unchecked Sendable {
    private let lock = NSLock()
    private var peakValue: UInt64 = 0
    private var stopped = false

    var peak: UInt64 { lock.lock(); defer { lock.unlock() }; return peakValue }

    func start() {
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            while true {
                lock.lock()
                if stopped { lock.unlock(); return }
                peakValue = max(peakValue, residentBytes())
                lock.unlock()
                usleep(20_000)
            }
        }
    }

    func stop() { lock.lock(); stopped = true; lock.unlock() }
}

/// Blocks the calling thread outright — which is the point, and why it is not `Task.sleep`: the
/// backpressure tests reproduce a hitching UI, and a hitching UI is a main thread that does not
/// turn. `Thread.sleep` is unavailable from an async context (it is exactly the mistake these tests
/// make deliberately), so this goes straight to POSIX.
private nonisolated func blockThisThread(for seconds: Double) {
    var request = timespec(tv_sec: Int(seconds), tv_nsec: Int((seconds - Double(Int(seconds))) * 1e9))
    var remaining = timespec()
    while nanosleep(&request, &remaining) != 0 && errno == EINTR { request = remaining }
}

/// Polls `condition` until it holds or `timeout` elapses, letting the main queue run in between.
@MainActor
@discardableResult
private func waitFor(
    _ timeout: TimeInterval = 4,
    _ condition: @MainActor () -> Bool
) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
    return condition()
}

/// Runs a program to completion and returns its collector. Fails the test on timeout.
@MainActor
private func run(
    _ executable: String,
    _ args: [String],
    cols: Int = 80,
    rows: Int = 24,
    execName: String? = nil,
    timeout: TimeInterval = 4,
    while body: (@MainActor (LocalProcess, Collector) async -> Void)? = nil
) async -> Collector {
    let collector = Collector()
    let process = LocalProcess(delegate: collector)
    #expect(process.start(
        executable: executable,
        args: args,
        environment: childEnvironment,
        execName: execName,
        cols: cols,
        rows: rows
    ))
    if let body { await body(process, collector) }
    let done = await waitFor(timeout) { collector.terminationCount > 0 }
    #expect(done, "process \(executable) \(args) did not terminate in \(timeout)s")
    if !done { process.terminate() }
    return collector
}

@Suite(.serialized) struct ProcessTests {
    // MARK: - Pty

    @Test func ptyForkRunsAChildAndGivesAReadableMaster() async throws {
        let forked = Pty.fork(
            executable: "/bin/echo",
            args: ["hi"],
            environment: childEnvironment,
            execName: nil,
            cols: 80,
            rows: 24
        )
        let child = try #require(forked)
        #expect(child.pid > 0)
        #expect(child.fd >= 0)

        var buffer = [UInt8](repeating: 0, count: 256)
        let n = buffer.withUnsafeMutableBytes { read(child.fd, $0.baseAddress, 256) }
        #expect(n > 0)
        // The pty's ONLCR turns the newline into CR LF — proof this is a terminal, not a pipe.
        #expect(String(decoding: buffer[0..<max(0, n)], as: UTF8.self) == "hi\r\n")

        var status: Int32 = 0
        #expect(waitpid(child.pid, &status, 0) == child.pid)
        close(child.fd)
    }

    @Test func ptyForkFailsForAMissingExecutable() async {
        // forkpty itself succeeds; the child's execve does not, and it _exits 127.
        let collector = await run("/bin/no-such-program-here", [])
        #expect(collector.exitCode == 127)
    }

    @Test func ptyPassesTheInitialWindowSize() async {
        let collector = await run("/bin/sh", ["-c", "stty size"], cols: 132, rows: 43)
        #expect(collector.text.contains("43 132"))
    }

    // MARK: - LocalProcess lifecycle

    @Test func childOutputAndExitCodeAreReported() async {
        let collector = await run("/bin/sh", ["-c", "echo hello; exit 3"])
        #expect(collector.text.contains("hello\r\n"))
        #expect(collector.exitCode == 3)
        #expect(collector.terminationCount == 1)
    }

    @Test func runningIsFalseAfterTheChildExits() async {
        let collector = Collector()
        let process = LocalProcess(delegate: collector)
        #expect(process.start(
            executable: "/bin/sh",
            args: ["-c", "exit 0"],
            environment: childEnvironment,
            execName: nil,
            cols: 80,
            rows: 24
        ))
        #expect(process.running)
        #expect(process.pid > 0)
        #expect(await waitFor { collector.terminationCount > 0 })
        #expect(!process.running)
        // A second start on a finished process is allowed; starting over a live one is not.
        #expect(process.start(
            executable: "/bin/sh",
            args: ["-c", "exit 0"],
            environment: childEnvironment,
            execName: nil,
            cols: 80,
            rows: 24
        ))
        process.terminate()
    }

    @Test func startIsRefusedWhileAChildIsAlive() async {
        let collector = Collector()
        let process = LocalProcess(delegate: collector)
        #expect(process.start(
            executable: "/bin/sleep",
            args: ["30"],
            environment: childEnvironment,
            execName: nil,
            cols: 80,
            rows: 24
        ))
        #expect(!process.start(
            executable: "/bin/sh",
            args: [],
            environment: childEnvironment,
            execName: nil,
            cols: 80,
            rows: 24
        ))
        process.terminate()
        #expect(await waitFor { collector.terminationCount > 0 })
    }

    // MARK: - send

    @Test func sendReachesTheChildAndItsEchoComesBack() async {
        let collector = await run("/bin/sh", [], timeout: 4) { process, collector in
            // Wait until the shell has drawn its prompt: it must have opened the pty before it
            // will see anything we type.
            _ = await waitFor(2) { !collector.bytes.isEmpty }
            process.send(Array("echo marker-42\n".utf8))
            _ = await waitFor(2) { collector.text.contains("marker-42\r\n") }
            process.send(Array("exit\n".utf8))
        }
        // The pty echoes the typed line and then the shell prints the result.
        #expect(collector.text.contains("marker-42"))
        #expect(collector.exitCode == 0)
        #expect(collector.terminationCount == 1)
    }

    @Test func execNameBecomesArgv0() async {
        let collector = await run("/bin/sh", ["-c", "echo $0"], execName: "sheepsh")
        #expect(collector.text.contains("sheepsh"))
    }

    // MARK: - resize

    @Test func resizeReachesTheChild() async {
        let collector = await run("/bin/sh", ["-c", "stty size; read line; stty size"], cols: 80, rows: 24) { process, collector in
            _ = await waitFor(2) { collector.text.contains("24 80") }
            process.resize(cols: 100, rows: 40)
            process.send(Array("\n".utf8))
        }
        #expect(collector.text.contains("24 80"))
        #expect(collector.text.contains("40 100"))
    }

    // MARK: - terminate

    @Test func terminateKillsASleeperAndLeavesNoZombie() async {
        let collector = Collector()
        let process = LocalProcess(delegate: collector)
        #expect(process.start(
            executable: "/bin/sleep",
            args: ["30"],
            environment: childEnvironment,
            execName: nil,
            cols: 80,
            rows: 24
        ))
        let pid = process.pid
        let start = Date()
        process.terminate()
        #expect(await waitFor(2) { collector.terminationCount > 0 })
        #expect(Date().timeIntervalSince(start) < 2)
        #expect(!process.running)
        // SIGHUP, not a normal exit.
        #expect(collector.exitCode == nil)
        // Reaped: the pid is gone entirely, not sitting around as a zombie (a zombie still
        // answers kill(pid, 0) with success).
        #expect(kill(pid, 0) == -1)
        #expect(errno == ESRCH)
    }

    @Test func terminateEscalatesToSIGKILLWhenSIGHUPIsIgnored() async {
        let collector = Collector()
        let process = LocalProcess(delegate: collector)
        // Traps SIGHUP and stays busy, so only the SIGKILL a second later can end it.
        #expect(process.start(
            executable: "/bin/sh",
            args: ["-c", "trap '' HUP; while :; do sleep 0.2; done"],
            environment: childEnvironment,
            execName: nil,
            cols: 80,
            rows: 24
        ))
        let pid = process.pid
        // Let the shell install the trap before hupping it.
        try? await Task.sleep(nanoseconds: 200_000_000)
        let start = Date()
        process.terminate()
        #expect(await waitFor(4) { collector.terminationCount > 0 })
        let elapsed = Date().timeIntervalSince(start)
        #expect(elapsed >= 0.9, "SIGKILL should only land after the 1 s grace period")
        #expect(elapsed < 3)
        #expect(collector.exitCode == nil)
        #expect(kill(pid, 0) == -1)
    }

    @Test func terminateOnAnAlreadyDeadChildIsHarmless() async {
        let collector = Collector()
        let process = LocalProcess(delegate: collector)
        #expect(process.start(
            executable: "/bin/sh",
            args: ["-c", "exit 7"],
            environment: childEnvironment,
            execName: nil,
            cols: 80,
            rows: 24
        ))
        #expect(await waitFor { collector.terminationCount > 0 })
        process.terminate()
        process.send(Array("ignored".utf8))
        process.resize(cols: 10, rows: 10)
        // Still exactly one termination, still the original code.
        try? await Task.sleep(nanoseconds: 200_000_000)
        #expect(collector.terminationCount == 1)
        #expect(collector.exitCode == 7)
    }

    // MARK: - teardown races

    /// The shortest life a child can have: `exit(0)` before the read source is even armed. The
    /// exit event and the EOF then land back-to-back on the io queue, which is exactly the window
    /// where a read descriptor used to be closed under the exit path's feet.
    @Test func aChildThatExitsImmediatelyIsReportedExactlyOnce() async {
        let collector = Collector()
        let process = LocalProcess(delegate: collector)
        #expect(process.start(
            executable: "/usr/bin/true",
            args: [],
            environment: childEnvironment,
            execName: nil,
            cols: 80,
            rows: 24
        ))
        let pid = process.pid
        #expect(await waitFor { collector.terminationCount > 0 })
        #expect(collector.exitCode == 0)
        #expect(!process.running)
        // Nothing arrives late, and the corpse is reaped rather than left as a zombie.
        try? await Task.sleep(nanoseconds: 300_000_000)
        #expect(collector.terminationCount == 1)
        #expect(kill(pid, 0) == -1)
    }

    /// The `start` after a finished child gets its own termination: the session identity that keeps
    /// the *old* child's callbacks away from the new one must not swallow the new one's.
    @Test func aSecondStartDeliversItsOwnTermination() async {
        let collector = Collector()
        let process = LocalProcess(delegate: collector)
        #expect(process.start(
            executable: "/bin/sh",
            args: ["-c", "echo first; exit 1"],
            environment: childEnvironment,
            execName: nil,
            cols: 80,
            rows: 24
        ))
        #expect(await waitFor { collector.terminationCount == 1 })
        #expect(collector.exitCode == 1)

        #expect(process.start(
            executable: "/bin/sh",
            args: ["-c", "echo second; exit 5"],
            environment: childEnvironment,
            execName: nil,
            cols: 80,
            rows: 24
        ))
        #expect(await waitFor { collector.terminationCount == 2 })
        #expect(collector.exitCode == 5)
        #expect(collector.text.contains("first"))
        #expect(collector.text.contains("second"))
        try? await Task.sleep(nanoseconds: 200_000_000)
        #expect(collector.terminationCount == 2)
    }

    /// A tab closed while the child is still writing: the `LocalProcess` goes away in the same
    /// runloop turn as `terminate()`, with a read source armed, bytes in flight and an exit event
    /// on its way. Nothing may call back into the dead object, the descriptors must all come back,
    /// and the still-armed exit source must reap the child anyway.
    @Test func droppingTheProcessWhileOutputIsArrivingIsSafe() async {
        let baseline = openDescriptorCount()
        let collector = Collector()
        var pid: pid_t = 0
        do {
            let process = LocalProcess(delegate: collector)
            #expect(process.start(
                executable: "/bin/sh",
                args: ["-c", "yes sheep | head -100000"],
                environment: childEnvironment,
                execName: nil,
                cols: 80,
                rows: 24
            ))
            pid = process.pid
            // Output is genuinely flowing before we pull the rug.
            #expect(await waitFor(2) { !collector.bytes.isEmpty })
            process.terminate()
        }
        // Let anything that was in flight run to completion against a deallocated owner.
        let delivered = collector.terminationCount
        try? await Task.sleep(nanoseconds: 500_000_000)
        #expect(collector.terminationCount == delivered)
        #expect(collector.terminationCount <= 1)
        // Reaped by the exit source that deliberately outlives the object — no zombie.
        #expect(await waitFor(3) { kill(pid, 0) == -1 })
        #expect(await waitFor(3) { openDescriptorCount() <= baseline },
                "descriptors leaked: \(openDescriptorCount()) open, baseline \(baseline)")
    }

    /// Twenty tabs opened and closed in a row. Each `start` takes two descriptors (the pty master
    /// and its private dup) and each teardown has to give both back — on two different queues, so
    /// the count is polled rather than read once.
    @Test func manyProcessesInARowLeakNoDescriptors() async {
        // One warm-up round so the count is not fooled by anything the first run allocates lazily.
        _ = await run("/usr/bin/true", [])
        try? await Task.sleep(nanoseconds: 300_000_000)
        let baseline = openDescriptorCount()

        for _ in 0..<20 {
            let collector = Collector()
            let process = LocalProcess(delegate: collector)
            #expect(process.start(
                executable: "/bin/sh",
                args: ["-c", "echo tab"],
                environment: childEnvironment,
                execName: nil,
                cols: 80,
                rows: 24
            ))
            #expect(await waitFor(3) { collector.terminationCount > 0 })
            #expect(collector.terminationCount == 1)
            process.terminate()   // harmless on a finished child, and the realistic tab-close path
        }

        #expect(await waitFor(3) { openDescriptorCount() <= baseline },
                "descriptors leaked over 20 sessions: \(openDescriptorCount()) open, baseline \(baseline)")
    }

    // MARK: - batching

    @Test func largeOutputArrivesWholeInBatchesUnder64KiB() async {
        // ~140 KB once ONLCR expands the newlines: several batches, so the ≤ 64 KiB rule bites.
        let collector = await run("/bin/sh", ["-c", "yes sheep | head -20000"], timeout: 4)
        #expect(collector.exitCode == 0)
        let lines = collector.text.components(separatedBy: "sheep").count - 1
        #expect(lines == 20000)
        #expect(collector.batchSizes.count > 1)
        #expect(collector.batchSizes.allSatisfy { $0 <= 64 * 1024 })
    }

    // MARK: - backpressure
    //
    // The three below are one story: a `cat` of something large in a local shell while the main
    // actor is busy. Before the `Feed`, every batch the reader drained was posted to main with an
    // unconditional `DispatchQueue.main.async` and nothing counted what was already in flight — 64
    // MiB pushed through with main blocked for 2 s delivered 0 bytes during the stall and grew the
    // process by 491–711 MiB. The reader now stops instead, which makes the child block in
    // `write(2)`; nothing is dropped, so all three still check the bytes as well as the RAM.

    /// Deliberately blocks the main thread — `Thread.sleep`, not `Task.sleep` — because that is
    /// what a hitching UI does to `DispatchQueue.main.async`. Every wait after it is the usual
    /// `waitFor`, so the queue drains normally again.
    @MainActor
    @Test func aStalledMainActorCannotGrowTheBacklogWithoutBound() async {
        // 5 B × 13 421 773 = 64 MiB exactly, and a stream whose every byte is predictable from its
        // index, so order and completeness are checkable without keeping any of it.
        let lines = 13_421_773
        let expected = lines * 5
        let verifier = Verifier()
        let process = LocalProcess(delegate: verifier)
        let sampler = ResidentSampler()

        let baseline = residentBytes()
        sampler.start()
        #expect(process.start(
            executable: "/bin/sh",
            args: ["-c", "exec 2>/dev/null; yes sheep | head -n \(lines) | tr -d '\\n'"],
            environment: childEnvironment,
            execName: nil,
            cols: 80,
            rows: 24
        ))
        // The stall. Nothing can reach the delegate for these two seconds.
        blockThisThread(for: 2)
        let duringStall = sampler.peak
        let stalls = process.readStallCount
        let pending = process.pendingByteCount
        sampler.stop()

        #expect(verifier.count == 0, "the main queue was blocked; nothing should have been delivered")
        #expect(stalls > 0, "the reader never hit the cap — the test did not exercise backpressure")
        // The cap is 4 MiB. The slack covers the batch in flight, the 64 MiB child's own pages and
        // whatever the test harness allocates in the same two seconds; the failure this is looking
        // for is hundreds of megabytes, not a few.
        let growth = Int64(duringStall) - Int64(baseline)
        #expect(growth < 32 * 1024 * 1024,
                "resident grew \(growth / (1024 * 1024)) MiB during the stall (pending \(pending) B)")

        // And then everything arrives, in order, exactly once.
        let done = await waitFor(120) { verifier.terminationCount > 0 && verifier.count >= expected }
        #expect(done, "delivered \(verifier.count) of \(expected) bytes")
        #expect(verifier.count == expected)
        #expect(verifier.outOfOrderAt == nil,
                "stream diverged at byte \(verifier.outOfOrderAt ?? -1): \(String(decoding: verifier.divergence, as: UTF8.self).debugDescription)")
        #expect(verifier.terminationCount == 1)
        #expect(verifier.exitCode == 0)
        #expect(verifier.batchSizes.max <= 64 * 1024)
        print("""
              backpressure: RSS +\(growth / (1024 * 1024)) MiB during the stall, \
              \(stalls) reader stalls, \(pending / 1024) KiB pending at release, \
              \(verifier.count) B delivered in \(verifier.batchSizes.count) batches
              """)
    }

    /// A tab closed while the reader is parked. The suspended read source has to be resumed before
    /// it is cancelled or its cancel handler — the only thing that closes the pty master — never
    /// runs, and both descriptors leak for the life of the app.
    @MainActor
    @Test func droppingTheProcessWhileTheReaderIsPausedTearsDownCleanly() async {
        let baseline = openDescriptorCount()
        let verifier = Verifier()
        var pid: pid_t = 0
        do {
            let process = LocalProcess(delegate: verifier)
            #expect(process.start(
                executable: "/bin/sh",
                args: ["-c", "exec 2>/dev/null; yes sheep | tr -d '\\n'"],
                environment: childEnvironment,
                execName: nil,
                cols: 80,
                rows: 24
            ))
            pid = process.pid
            blockThisThread(for: 1.5)
            // Still holding the main thread: the drain this stall scheduled has not run yet, so
            // the reader is still suspended right now, and this is the moment the tab closes.
            #expect(process.readStallCount > 0, "the reader was not paused; the test proves nothing")
            process.terminate()
        }
        #expect(await waitFor(3) { kill(pid, 0) == -1 }, "the child was not reaped")
        #expect(await waitFor(3) { openDescriptorCount() <= baseline },
                "descriptors leaked: \(openDescriptorCount()) open, baseline \(baseline)")
        #expect(verifier.terminationCount <= 1)
    }

    /// The child dies while the reader is parked: the exit source fires on the same queue as the
    /// suspended read source, has to drain the tail past a full buffer, and must still report
    /// exactly one termination.
    @MainActor
    @Test func aChildThatExitsWhileTheReaderIsPausedIsStillReportedOnce() async {
        let verifier = Verifier()
        let process = LocalProcess(delegate: verifier)
        #expect(process.start(
            executable: "/bin/sh",
            args: ["-c", "exec 2>/dev/null; yes sheep | tr -d '\\n'"],
            environment: childEnvironment,
            execName: nil,
            cols: 80,
            rows: 24
        ))
        let pid = process.pid
        blockThisThread(for: 1.5)
        #expect(process.readStallCount > 0, "the reader was not paused; the test proves nothing")
        // SIGHUP lands while the source is suspended and the buffer is over its cap.
        process.terminate()

        #expect(await waitFor(4) { verifier.terminationCount > 0 })
        #expect(!process.running)
        #expect(verifier.exitCode == nil, "SIGHUP, not a normal exit")
        #expect(verifier.count > 0, "the bytes read before the pause still have to arrive")
        #expect(verifier.outOfOrderAt == nil,
                "stream diverged at byte \(verifier.outOfOrderAt ?? -1): \(String(decoding: verifier.divergence, as: UTF8.self).debugDescription)")
        #expect(await waitFor(3) { kill(pid, 0) == -1 })
        try? await Task.sleep(nanoseconds: 300_000_000)
        #expect(verifier.terminationCount == 1)
    }
}
