import Darwin
import Foundation

/// Who holds a local TCP port, for "Port 22 / 21 is in use by …" (the TCP
/// twin of TFTP's `PortOwner.udp`, which lives in a file the SSH and FTP
/// harnesses do not build). Used by `SSHFileServer` and `FTPServer`.
/// libproc sees only this user's processes: macOS Remote Login's socket
/// belongs to root's launchd, so for 22 `remoteLoginOn` asks launchd
/// instead — `launchctl print system/com.openssh.sshd` answers without root
/// (exit 0 = the service is loaded = Remote Login is on).
nonisolated enum TCPPortOwner {
    /// The name of a visible process with a TCP socket LISTENING on `port`.
    static func listener(port: UInt16) -> String? {
        let needed = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard needed > 0 else { return nil }
        var pids = [pid_t](repeating: 0, count: Int(needed) / MemoryLayout<pid_t>.size + 64)
        let got = pids.withUnsafeMutableBytes { proc_listpids(UInt32(PROC_ALL_PIDS), 0, $0.baseAddress, Int32($0.count)) }
        guard got > 0 else { return nil }
        for pid in pids.prefix(Int(got) / MemoryLayout<pid_t>.size) where pid > 0 && listens(pid: pid, port: port) {
            var name = [CChar](repeating: 0, count: 256)
            guard proc_name(pid, &name, UInt32(name.count)) > 0 else { return nil }
            let text = String(decoding: name.prefix { $0 != 0 }.map(UInt8.init(bitPattern:)), as: UTF8.self)
            return text.isEmpty ? nil : text
        }
        return nil
    }

    private static func listens(pid: pid_t, port: UInt16) -> Bool {
        let size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard size > 0 else { return false }
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(size) / MemoryLayout<proc_fdinfo>.size + 8)
        let got = fds.withUnsafeMutableBytes { proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count)) }
        guard got > 0 else { return false }
        for fd in fds.prefix(Int(got) / MemoryLayout<proc_fdinfo>.size) where fd.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
            var info = socket_fdinfo()
            let length = Int32(MemoryLayout<socket_fdinfo>.size)
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &info, length) == length else { continue }
            let socket = info.psi
            guard socket.soi_kind == Int32(SOCKINFO_TCP),
                  socket.soi_family == AF_INET || socket.soi_family == AF_INET6 else { continue }
            let tcp = socket.soi_proto.pri_tcp
            guard tcp.tcpsi_state == Int32(TSI_S_LISTEN) else { continue }
            if UInt16(bigEndian: UInt16(truncatingIfNeeded: tcp.tcpsi_ini.insi_lport)) == port { return true }
        }
        return false
    }

    /// `remoteLoginOn` on a queue of its own: it waits up to 2 s on a
    /// semaphore, which must never park a Swift concurrency pool thread.
    static func remoteLoginOnAsync() async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            probeQueue.async { continuation.resume(returning: remoteLoginOn()) }
        }
    }

    private static let probeQueue = DispatchQueue(label: "sheepterm.remote-login-probe")

    /// macOS Remote Login (launchd's `com.openssh.sshd`) is on. Gives up
    /// (false) after 2 s rather than hold the start. Blocks: call it
    /// through `remoteLoginOnAsync` from async code.
    static func remoteLoginOn() -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        task.arguments = ["print", "system/com.openssh.sshd"]
        task.standardInput = FileHandle.nullDevice
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0)
        task.terminationHandler = { _ in done.signal() }
        guard (try? task.run()) != nil else { return false }
        guard done.wait(timeout: .now() + 2) == .success else { task.terminate(); return false }
        return task.terminationStatus == 0
    }
}
