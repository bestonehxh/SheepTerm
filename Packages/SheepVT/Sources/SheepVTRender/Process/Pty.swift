//
//  Pty.swift — pseudo-terminal primitives.
//
//  Port of SwiftTerm's `Pty.swift` (MIT), trimmed to what SheepTerm needs. Pure POSIX: no
//  Dispatch, no AppKit, no actor isolation. `forkpty` is the one call that makes the child a
//  session leader with the pty as its *controlling* terminal — which is what job control,
//  SIGWINCH and `stty` all depend on — so it stays, rather than openpty + posix_spawn.
//

import Foundation

/// A NULL-terminated `char **` built from Swift strings, owned by the caller.
///
/// Allocated in the *parent* before `forkpty`: between fork and exec only async-signal-safe
/// calls are legal, and `strdup`/`malloc` are not.
private nonisolated struct CStringArray {
    let base: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
    let count: Int

    init?(_ strings: [String]) {
        let base = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>.allocate(capacity: strings.count + 1)
        var initialized = 0
        for (index, string) in strings.enumerated() {
            guard let copy = strdup(string) else {
                for i in 0..<initialized { free(base[i]) }
                base.deallocate()
                return nil
            }
            base[index] = copy
            initialized += 1
        }
        base[strings.count] = nil
        self.base = base
        self.count = strings.count
    }

    func deallocate() {
        for i in 0..<count { free(base[i]) }
        base.deallocate()
    }
}

/// Wrappers over the libc pty API. Every member is `nonisolated`: this type is safe to call
/// from any thread or queue.
public nonisolated enum Pty {
    /// Forks a child running `executable` on the slave side of a fresh pseudo-terminal.
    ///
    /// - Parameters:
    ///   - executable: absolute path of the program to exec.
    ///   - args: arguments *after* argv[0].
    ///   - environment: the child's environment, as `"KEY=value"` strings (passed verbatim —
    ///     the child gets exactly this and nothing else).
    ///   - execName: argv[0] for the child; a leading `"-"` marks it a login shell. Defaults to
    ///     `executable` when nil.
    ///   - cols/rows: the initial window size reported by `TIOCGWINSZ` in the child.
    /// - Returns: the child pid and the master (primary) file descriptor, or nil if the fork or
    ///   any allocation failed. The caller owns the fd and must `close` it.
    public static func fork(
        executable: String,
        args: [String],
        environment: [String],
        execName: String?,
        cols: Int,
        rows: Int
    ) -> (pid: pid_t, fd: Int32)? {
        var argv = args
        argv.insert(execName ?? executable, at: 0)

        guard let cArgs = CStringArray(argv) else { return nil }
        guard let cEnv = CStringArray(environment) else {
            cArgs.deallocate()
            return nil
        }
        guard let cExecutable = strdup(executable) else {
            cEnv.deallocate()
            cArgs.deallocate()
            return nil
        }
        defer {
            free(cExecutable)
            cEnv.deallocate()
            cArgs.deallocate()
        }

        var size = winsize(cols: cols, rows: rows)
        var master: Int32 = 0
        let pid = forkpty(&master, nil, nil, &size)
        if pid < 0 { return nil }
        if pid == 0 {
            // Child. Only async-signal-safe calls from here on.
            _ = execve(cExecutable, cArgs.base, cEnv.base)
            _exit(127)
        }
        return (pid, master)
    }

    /// Tells the pty its new geometry; the kernel raises SIGWINCH in the child's foreground
    /// process group. Silently ignores a closed or non-tty descriptor.
    public static func setWinSize(_ fd: Int32, cols: Int, rows: Int) {
        guard fd >= 0 else { return }
        var size = winsize(cols: cols, rows: rows)
        _ = ioctl(fd, TIOCSWINSZ, &size)
    }
}

nonisolated extension winsize {
    /// Clamped to the 16-bit fields the kernel actually stores; 0 rows/cols confuses curses
    /// programs, so the floor is 1.
    fileprivate init(cols: Int, rows: Int) {
        self.init(
            ws_row: UInt16(clamping: max(1, rows)),
            ws_col: UInt16(clamping: max(1, cols)),
            ws_xpixel: 0,
            ws_ypixel: 0
        )
    }
}
