import Foundation

/// A serial port's speed (6.0 (14), "Other…" on the console card): a rate
/// POSIX lists goes through termios; anything else is tried through termios
/// first (a pty and many drivers take it) and then through Apple's
/// `IOSSIOSPEED`; a driver that takes neither is refused clearly. Pure —
/// SerialWorker passes the two system calls in.
nonisolated enum SerialSpeed {
    /// The rates termios names (B50 … B230400).
    static let posix: Set<Int> = [50, 75, 110, 134, 150, 200, 300, 600, 1200, 1800, 2400, 4800, 9600, 19200, 38400, 57600, 115200, 230400]

    enum Outcome: Equatable {
        case termios
        case ioss
        case refused(String)
    }

    static func apply(_ baud: Int, termios: (Int) -> Bool, ioss: (Int) -> Bool) -> Outcome {
        if termios(baud) { return .termios }
        guard !posix.contains(baud) else { return .refused("cannot set \(baud) baud") }
        if ioss(baud) { return .ioss }
        return .refused("the adapter does not take \(baud) baud")
    }
}
