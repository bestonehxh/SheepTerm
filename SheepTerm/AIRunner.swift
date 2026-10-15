import Foundation
import Synchronization

/// AI panel, Mac side of the process work: finding the vendors' CLIs and
/// running them. Foundation only (no AppKit) so `Tests/run.sh tests` drives
/// the real code against fake `claude` / `codex` scripts in `Tests/fakecli`.
/// What to run is decided by the shared pure `AICLI`; this file spawns it.
///
/// Rules (ARCHITECTURE.md "AI panel"): the prompt goes on stdin, never argv;
/// the child gets no API key; it runs in an empty work directory; Codex runs
/// under `CodexSandbox`; nothing a model writes is ever executed here.

/// Where a CLI was found.
nonisolated struct AIBinary: Equatable, Sendable {
    /// The path found (maybe a symlink) — what is executed.
    var path: String
    /// Symlinks resolved — what the sandbox allows.
    var resolved: String
}

nonisolated enum AIBinaryLocator {
    /// Screenshots point a DEBUG build at fake CLIs with this; a Release
    /// build ignores it (an environment variable must not be able to swap
    /// the CLI the app runs). The harness passes `binDirectory` instead.
    static let overrideDirectoryKey = "SHEEPTERM_AI_BIN_DIR"

    static func overrideDirectory(in environment: [String: String]) -> String? {
        #if DEBUG
        if let dir = environment[overrideDirectoryKey], !dir.isEmpty { return dir }
        #endif
        return nil
    }

    private static let cache = Mutex<[String: String]>([:])
    private static let loginPathCache = Mutex<String??>(nil)

    static func locate(_ provider: AIProvider, environment: [String: String] = ProcessInfo.processInfo.environment,
                       useLoginShell: Bool = true, binDirectory: String? = nil) -> AIBinary? {
        let name = provider.binaryName
        let fm = FileManager.default
        var candidates: [String] = []
        let override = binDirectory ?? overrideDirectory(in: environment)
        if let dir = override {
            candidates.append((dir as NSString).appendingPathComponent(name))
        }
        candidates += AICLI.candidatePaths(for: name, home: NSHomeDirectory())
        var found = candidates.first { fm.isExecutableFile(atPath: $0) }
        if found == nil, useLoginShell, override == nil {
            if let cached = cache.withLock({ $0[name] }) {
                found = cached.isEmpty ? nil : cached
            } else {
                let probe = runCapture("/bin/zsh", AICLI.shellProbeArguments(for: name), environment: environment,
                                       cwd: NSTemporaryDirectory(), timeout: 5)
                let path = probe.flatMap { AICLI.parseProbe($0.output) }.flatMap { fm.isExecutableFile(atPath: $0) ? $0 : nil }
                cache.withLock { $0[name] = path ?? "" }
                found = path
            }
        }
        guard let found else { return nil }
        return AIBinary(path: found, resolved: canonicalPath(found))
    }

    /// Forget a negative/positive probe (Settings re-check after an install).
    static func reset() {
        cache.withLock { $0 = [:] }
        loginPathCache.withLock { $0 = nil }
    }

    /// The login shell's PATH, asked once (a CLI installed with npm needs
    /// `node` from it).
    static func loginPath(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        if let cached = loginPathCache.withLock({ $0 }) { return cached }
        let out = runCapture("/bin/zsh", ["-lc", "printf '%s' \"$PATH\""], environment: environment,
                             cwd: NSTemporaryDirectory(), timeout: 5)
        let path = out.map { $0.output.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }
        loginPathCache.withLock { $0 = .some(path) }
        return path
    }

    /// A script whose `#!` names node: the node it will run, resolved.
    static func nodeInterpreter(for binary: AIBinary, path: String?) -> String? {
        guard let handle = FileHandle(forReadingAtPath: binary.resolved) else { return nil }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: 128)) ?? Data()
        guard head.starts(with: Data("#!".utf8)),
              let line = String(data: head, encoding: .utf8)?.split(separator: "\n").first,
              line.contains("node") else { return nil }
        let dirs = (path ?? "").split(separator: ":").map(String.init) + ["/opt/homebrew/bin", "/usr/local/bin"]
        for dir in dirs {
            let candidate = (dir as NSString).appendingPathComponent("node")
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return canonicalPath(candidate)
            }
        }
        return nil
    }
}

/// The real path the sandbox matches against (`/var` → `/private/var`).
/// `NSString.resolvingSymlinksInPath` will not do: it strips `/private`.
nonisolated func canonicalPath(_ path: String) -> String {
    if let real = realpath(path, nil) {
        defer { free(real) }
        return String(cString: real)
    }
    let parent = (path as NSString).deletingLastPathComponent
    guard parent != path, !parent.isEmpty else { return path }
    return (canonicalPath(parent) as NSString).appendingPathComponent((path as NSString).lastPathComponent)
}

/// Run a short command to completion and capture stdout (status checks, the
/// login-shell probe). nil when it could not start or ran past `timeout`.
nonisolated func runCapture(_ executable: String, _ arguments: [String], environment: [String: String],
                            cwd: String, timeout: TimeInterval) -> (status: Int32, output: String, errors: String)? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.environment = environment
    process.currentDirectoryURL = URL(fileURLWithPath: cwd)
    let out = Pipe(), err = Pipe()
    process.standardOutput = out
    process.standardError = err
    process.standardInput = FileHandle.nullDevice
    let done = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in done.signal() }
    do { try process.run() } catch { return nil }
    let collected = Mutex(Data()), collectedErr = Mutex(Data())
    let reader = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
        let data = out.fileHandleForReading.readDataToEndOfFile()
        collected.withLock { $0 = data }
        reader.signal()
    }
    DispatchQueue.global().async {
        let data = err.fileHandleForReading.readDataToEndOfFile()
        collectedErr.withLock { $0 = data }
        reader.signal()
    }
    if done.wait(timeout: .now() + timeout) == .timedOut {
        process.terminate()
        _ = done.wait(timeout: .now() + 1)
        return nil
    }
    _ = reader.wait(timeout: .now() + 2)
    _ = reader.wait(timeout: .now() + 2)
    let data = collected.withLock { $0 }, errData = collectedErr.withLock { $0 }
    return (process.terminationStatus, String(decoding: data.prefix(256 * 1024), as: UTF8.self),
            String(decoding: errData.prefix(64 * 1024), as: UTF8.self))
}

/// One CLI process for one turn. Events arrive on a private serial queue in
/// stdout order; `onExit` is always last, exactly once.
nonisolated final class AIProcessRun: @unchecked Sendable {
    struct Spec: Sendable {
        var executable: String
        var arguments: [String]
        var environment: [String: String]
        var cwd: String
        var stdin: Data
        /// Removed when the process has exited (Claude's system prompt file).
        var cleanup: [String] = []
    }

    /// How a run ended — the shared `AIRunEnding` (AIRules.swift).
    typealias Ending = AIRunEnding

    private let spec: Spec
    private let provider: AIProvider
    private let onEvent: @Sendable (AIStreamEvent) -> Void
    private let onExit: @Sendable (Ending) -> Void
    private let state = Mutex(State())
    /// The shared timing rules (`AIRunTiming`, AIRules.swift).
    static let interruptGrace = AIRunTiming.interruptGrace
    static let killGrace = AIRunTiming.killGrace
    static let doneGrace = AIRunTiming.doneGrace
    static let stderrCap = AIRunTiming.stderrCap

    private struct State {
        var cancelled = false
        var aborted: String?
        var failure: String?
        var sawDone = false
        var pid: pid_t = 0
        var exited = false
        /// Write end of the pipe that wakes the readers (forced end).
        var wakeWrite: Int32 = -1
        var finished = false
    }

    init(spec: Spec, provider: AIProvider, onEvent: @escaping @Sendable (AIStreamEvent) -> Void,
         onExit: @escaping @Sendable (Ending) -> Void) {
        self.spec = spec
        self.provider = provider
        self.onEvent = onEvent
        self.onExit = onExit
    }

    var processIdentifier: Int32 { state.withLock { $0.pid } }

    /// The CLI runs in its OWN process group (`POSIX_SPAWN_SETPGROUP`), so
    /// Stop / abort signal the whole group — a helper it forked that still
    /// holds stdout goes too — and only the three pipe ends are inherited
    /// (`POSIX_SPAWN_CLOEXEC_DEFAULT`).
    func start() throws {
        var inPipe: [Int32] = [-1, -1], outPipe: [Int32] = [-1, -1], errPipe: [Int32] = [-1, -1], wakePipe: [Int32] = [-1, -1]
        func closeAll() { for fd in inPipe + outPipe + errPipe + wakePipe where fd >= 0 { close(fd) } }
        guard pipe(&inPipe) == 0, pipe(&outPipe) == 0, pipe(&errPipe) == 0, pipe(&wakePipe) == 0 else {
            closeAll(); throw POSIXError(.EMFILE)
        }
        for fd in [inPipe[1], outPipe[0], errPipe[0], wakePipe[0], wakePipe[1]] { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }
        // A child that exits without reading stdin must not SIGPIPE the app.
        _ = fcntl(inPipe[1], F_SETNOSIGPIPE, 1)

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, inPipe[0], 0)
        posix_spawn_file_actions_adddup2(&actions, outPipe[1], 1)
        posix_spawn_file_actions_adddup2(&actions, errPipe[1], 2)
        posix_spawn_file_actions_addchdir(&actions, spec.cwd)

        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT
                                              | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))
        posix_spawnattr_setpgroup(&attr, 0)
        var defaults = sigset_t(), empty = sigset_t()
        sigemptyset(&defaults); sigemptyset(&empty)
        for sig in [SIGPIPE, SIGINT, SIGTERM, SIGHUP, SIGQUIT] { sigaddset(&defaults, sig) }
        posix_spawnattr_setsigdefault(&attr, &defaults)
        posix_spawnattr_setsigmask(&attr, &empty)

        let argv = ([spec.executable] + spec.arguments).map { strdup($0) } + [nil]
        let envp = spec.environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { for p in argv + envp { free(p) } }
        var pid: pid_t = 0
        let rc = posix_spawn(&pid, spec.executable, &actions, &attr, argv, envp)
        close(inPipe[0]); close(outPipe[1]); close(errPipe[1])
        guard rc == 0 else {
            for fd in [inPipe[1], outPipe[0], errPipe[0], wakePipe[0], wakePipe[1]] { close(fd) }
            throw POSIXError(POSIXErrorCode(rawValue: rc) ?? .ENOENT)
        }
        let wakeRead = wakePipe[0]
        let childPID = pid
        state.withLock { $0.pid = childPID; $0.wakeWrite = wakePipe[1] }

        let input = spec.stdin
        let stdinFD = inPipe[1]
        DispatchQueue.global().async {
            input.withUnsafeBytes { raw in
                var offset = 0
                while offset < raw.count {
                    let n = write(stdinFD, raw.baseAddress! + offset, raw.count - offset)
                    if n <= 0 { if n < 0 && errno == EINTR { continue }; break }
                    offset += n
                }
            }
            close(stdinFD)
        }

        let stderrData = Mutex(Data())
        let stderrDone = DispatchSemaphore(value: 0)
        let stderrFD = errPipe[0]
        DispatchQueue.global().async {
            Self.pump(stderrFD, wake: wakeRead) { chunk in
                stderrData.withLock { if $0.count < Self.stderrCap { $0.append(chunk.prefix(Self.stderrCap - $0.count)) } }
            }
            close(stderrFD)
            stderrDone.signal()
        }

        let provider = self.provider
        let stdoutFD = outPipe[0]
        DispatchQueue.global().async { [self] in
            var claude = ClaudeStreamParser()
            var codex = CodexStreamParser()
            var pending = Data()
            func feed(_ lineData: Data) {
                let line = String(decoding: lineData, as: UTF8.self)
                let events = provider == .claude ? claude.consume(line) : codex.consume(line)
                for event in events { deliver(event) }
            }
            Self.pump(stdoutFD, wake: wakeRead) { chunk in
                pending.append(chunk)
                while let nl = pending.firstIndex(of: 0x0A) {
                    feed(pending[pending.startIndex..<nl])
                    pending.removeSubrange(pending.startIndex...nl)
                }
            }
            close(stdoutFD)
            if !pending.isEmpty { feed(pending) }
            var status: Int32 = 0
            while waitpid(childPID, &status, 0) < 0 && errno == EINTR {}
            state.withLock { $0.exited = true }
            let stderrEnded = stderrDone.wait(timeout: .now() + 2) == .success
            let wakeWrite = state.withLock { s -> Int32 in
                s.finished = true
                let fd = s.wakeWrite
                s.wakeWrite = -1
                return fd
            }
            // Closing the write end wakes a stderr reader still held open by
            // a grandchild; only then is the read end safe to close.
            if wakeWrite >= 0 { close(wakeWrite) }
            if !stderrEnded { stderrDone.wait() }
            close(wakeRead)
            for path in spec.cleanup { try? FileManager.default.removeItem(atPath: path) }
            let stderr = String(decoding: stderrData.withLock { $0 }, as: UTF8.self)
            // Exit status: WIFEXITED / WEXITSTATUS by hand (C macros).
            let signaled = (status & 0x7F) != 0 && (status & 0x7F) != 0x7F
            let code = (status >> 8) & 0xFF
            onExit(ending(status: code, signaled: signaled, stderr: stderr))
        }
    }

    /// Read `fd` to EOF, or until `wake` becomes readable (a forced end).
    private static func pump(_ fd: Int32, wake: Int32, _ onChunk: (Data) -> Void) {
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        var fds = [pollfd(fd: fd, events: Int16(POLLIN), revents: 0), pollfd(fd: wake, events: Int16(POLLIN), revents: 0)]
        while true {
            fds[0].revents = 0
            fds[1].revents = 0
            let r = poll(&fds, 2, -1)
            if r < 0 { if errno == EINTR { continue }; return }
            if fds[0].revents != 0 {
                let n = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
                if n < 0 { if errno == EINTR || errno == EAGAIN { continue }; return }
                if n == 0 { return }
                onChunk(Data(buffer[0..<n]))
                continue
            }
            if fds[1].revents != 0 { return }
        }
    }

    /// Signal the CLI's whole process group (nothing once it has been reaped:
    /// the group id could be reused).
    private func signalGroup(_ sig: Int32) {
        let pid = state.withLock { $0.exited ? 0 : $0.pid }
        guard pid > 0 else { return }
        kill(-pid, sig)
    }

    /// SIGTERM to the group now; if the run still has not ended after
    /// `killGrace`, SIGKILL the group and wake the readers so `onExit` fires.
    private func terminate() {
        signalGroup(SIGTERM)
        DispatchQueue.global().asyncAfter(deadline: .now() + Self.killGrace) { [self] in
            forceEnd()
        }
    }

    /// The turn ended `doneGrace` ago and the run has not: if the CLI itself
    /// has exited (a helper holds stdout) end it now; if it is still running,
    /// the normal SIGTERM → SIGKILL path.
    private func endAfterDone() {
        let pid = state.withLock { $0.finished ? 0 : $0.pid }
        guard pid > 0 else { return }
        var info = siginfo_t()
        let exited = waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT) == 0 && info.si_pid == pid
        if exited { forceEnd() } else { terminate() }
    }

    private func forceEnd() {
        guard state.withLock({ !$0.finished }) else { return }
        signalGroup(SIGKILL)
        // Under the lock: the finishing reader closes this fd under it too.
        state.withLock { s in
            guard !s.finished, s.wakeWrite >= 0 else { return }
            var byte: UInt8 = 1
            _ = write(s.wakeWrite, &byte, 1)
        }
    }

    private func deliver(_ event: AIStreamEvent) {
        switch event {
        case .abort(let message):
            let first = state.withLock { s -> Bool in
                guard s.aborted == nil else { return false }
                s.aborted = message
                return true
            }
            if first { terminate() }
        case .failure(let message):
            state.withLock { if $0.failure == nil { $0.failure = message } }
        case .done:
            state.withLock { $0.sawDone = true }
            onEvent(.done)
            DispatchQueue.global().asyncAfter(deadline: .now() + Self.doneGrace) { [self] in endAfterDone() }
        default:
            // Nothing more is shown once a safety check stopped the run.
            guard state.withLock({ $0.aborted == nil }) else { return }
            onEvent(event)
        }
    }

    private func ending(status: Int32, signaled: Bool, stderr: String) -> Ending {
        let s = state.withLock { $0 }
        return AIRunEnding.decide(aborted: s.aborted, cancelled: s.cancelled, failure: s.failure, sawDone: s.sawDone,
                                  exitStatus: status, signaled: signaled, stderr: stderr, provider: provider)
    }

    /// Stop: SIGINT to the process group (the CLI cleans up), SIGTERM after
    /// `interruptGrace`, then SIGKILL + a forced end after `killGrace`.
    func cancel() {
        let live = state.withLock { s -> Bool in
            s.cancelled = true
            return !s.finished
        }
        guard live else { return }
        signalGroup(SIGINT)
        DispatchQueue.global().asyncAfter(deadline: .now() + Self.interruptGrace) { [self] in
            guard state.withLock({ !$0.finished }) else { return }
            terminate()
        }
    }
}

/// The work before a CLI starts (login check, spec), off main. Its outcome
/// is applied only to the turn that asked (`AIConversation.isCurrent`).
nonisolated enum AIRunPrep {
    enum Outcome: Sendable {
        case ready(AIBinary, AIProcessRun.Spec)
        case failed(AIProcessRun.Ending, AIAccountStatus?)
    }

    static func prepare(_ provider: AIProvider, binary: AIBinary?, needsCheck: Bool, planner: AIRunPlanner,
                        spec: (AIRunPlanner, AIBinary) throws -> AIProcessRun.Spec) -> Outcome {
        guard let binary else { return .failed(.failed(AIRunMessages.notInstalled(provider)), .notInstalled) }
        if needsCheck {
            let status = planner.status(provider, binary: binary)
            switch status {
            case .signedIn, .unknown: break   // unknown: let the run itself say what is wrong
            case .apiKey: return .failed(.failed(AIRunMessages.apiKey(provider)), status)
            case .signedOut: return .failed(.failed(AIRunMessages.notSignedIn(provider)), status)
            case .notInstalled: return .failed(.failed(AIRunMessages.notInstalled(provider)), status)
            }
        }
        do { return .ready(binary, try spec(planner, binary)) } catch {
            return .failed(.failed("\(provider.label): couldn't prepare the run"), nil)
        }
    }
}

/// Turns a request into a process spec. Separate from the run so the tests
/// can check exactly what would be executed.
nonisolated struct AIRunPlanner {
    /// Per-app scratch: `work` (the empty cwd), `tmp` (child TMPDIR),
    /// `prompts` (Claude's system prompt file, removed after the run).
    var root: String
    var baseEnvironment: [String: String]
    var loginPath: String?
    /// Off only in tests that cannot nest sandboxes.
    var sandboxCodex = true

    static func defaultRoot() -> String {
        (NSTemporaryDirectory() as NSString).appendingPathComponent("SheepTerm-AI-\(getuid())")
    }

    var workDir: String { (root as NSString).appendingPathComponent("work") }
    var tmpDir: String { (root as NSString).appendingPathComponent("tmp") }
    var promptsDir: String { (root as NSString).appendingPathComponent("prompts") }

    func prepareDirectories() throws {
        for dir in [workDir, tmpDir, promptsDir] {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        }
    }

    func claudeSpec(binary: AIBinary, system: String, prompt: String, model: String, sessionID: String, resume: Bool) throws -> AIProcessRun.Spec {
        try prepareDirectories()
        let file = (promptsDir as NSString).appendingPathComponent("system-\(UUID().uuidString).txt")
        guard FileManager.default.createFile(atPath: file, contents: Data(system.utf8), attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let env = AICLI.childEnvironment(baseEnvironment, provider: .claude, path: loginPath, tmpdir: nil)
        return AIProcessRun.Spec(
            executable: binary.path,
            arguments: AICLI.claudeArguments(systemPromptFile: file, model: model, sessionID: sessionID, resume: resume),
            environment: env, cwd: workDir, stdin: Data(prompt.utf8), cleanup: [file])
    }

    var codexHome: String {
        if let home = baseEnvironment["CODEX_HOME"], !home.isEmpty { return home }
        return (NSHomeDirectory() as NSString).appendingPathComponent(".codex")
    }

    func codexSpec(binary: AIBinary, prompt: String, threadID: String?) throws -> AIProcessRun.Spec {
        try prepareDirectories()
        let codexArgs = AICLI.codexArguments(threadID: threadID)
        var readRoots = CodexSandbox.installRoots(forResolved: binary.resolved)
        var path = "/usr/bin:/bin:/usr/sbin:/sbin"
        if let node = AIBinaryLocator.nodeInterpreter(for: binary, path: loginPath ?? baseEnvironment["PATH"]) {
            readRoots += CodexSandbox.installRoots(forResolved: node)
            path = (node as NSString).deletingLastPathComponent + ":" + path
        }
        path = (binary.path as NSString).deletingLastPathComponent + ":" + path
        var env = AICLI.childEnvironment(baseEnvironment, provider: .chatgpt, path: path, tmpdir: tmpDir)
        env["CODEX_HOME"] = codexHome
        guard sandboxCodex else {
            return AIProcessRun.Spec(executable: binary.path, arguments: codexArgs, environment: env, cwd: workDir,
                                     stdin: Data(prompt.utf8))
        }
        let profile = CodexSandbox.profile(readRoots: readRoots.map(canonicalPath),
                                           writeRoots: [codexHome, workDir, tmpDir].map(canonicalPath))
        // The RESOLVED binary: the found path is often a symlink in a folder the profile does not open (the standalone
        // installer's ~/.local/bin/codex -> ~/.codex/packages/…), and exec through it was "Operation not permitted".
        return AIProcessRun.Spec(executable: "/usr/bin/sandbox-exec",
                                 arguments: ["-p", profile, binary.resolved] + codexArgs,
                                 environment: env, cwd: workDir, stdin: Data(prompt.utf8))
    }

    /// Login status, off the main thread (blocks up to `timeout`).
    func status(_ provider: AIProvider, binary: AIBinary?, timeout: TimeInterval = 20) -> AIAccountStatus {
        guard let binary else { return .notInstalled }
        try? prepareDirectories()
        let env = AICLI.childEnvironment(baseEnvironment, provider: provider, path: loginPath, tmpdir: nil)
        let args = provider == .claude ? AICLI.claudeStatusArguments : AICLI.codexStatusArguments
        guard let result = runCapture(binary.path, args, environment: env, cwd: workDir, timeout: timeout) else {
            return .unknown("didn't answer")
        }
        return provider == .claude ? AICLI.claudeStatus(exitCode: result.status, output: result.output)
                                   : AICLI.codexStatus(exitCode: result.status, output: result.output + "\n" + result.errors)
    }
}
