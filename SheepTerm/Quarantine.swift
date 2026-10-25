import Darwin
import Foundation

/// Marks a file a device pushed to this Mac (File Server writes) or one the
/// Files tab downloaded as coming from the network, the way a browser
/// download is: Gatekeeper then asks before a `.command` / `.app` / `.terminal`
/// from a switch — or from whoever answered on its address — can run.
nonisolated enum Quarantine {
    static let attribute = "com.apple.quarantine"

    static func value(now: Date = Date()) -> String {
        // flags;hex-seconds;agent;  — 0x0083 = downloaded, user-approval
        // pending (what Safari writes for a download).
        String(format: "0083;%08x;SheepTerm;", UInt32(clamping: Int(now.timeIntervalSince1970)))
    }

    @discardableResult
    static func mark(_ url: URL, from _: String = "") -> Bool {
        let bytes = Array(value().utf8)
        return url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return false }
            return setxattr(path, attribute, bytes, bytes.count, 0, 0) == 0
        }
    }

    static func isMarked(_ url: URL) -> Bool {
        url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return false }
            return getxattr(path, attribute, nil, 0, 0, 0) > 0
        }
    }
}
