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

extension Quarantine {
    /// Transfer Log note for a file saved on a volume that would not keep
    /// the mark (FAT/exFAT, some network shares).
    static let unmarkedNote = "saved without the quarantine mark (this volume cannot hold it)"
}

/// The last step of every Files-tab download (review 6.0 (4)): the part file
/// is marked first — the attribute moves with the rename, so the real name
/// never exists unmarked — then renamed into place. Over an existing file
/// only when the user said Replace for this download; otherwise a name that
/// appeared meanwhile, or one that differs only in case (`a.txt` and `A.txt`
/// from the device land on the same file here), is refused, never replaced.
nonisolated enum DownloadCommit {
    /// `.<name>.sheepterm-<tag>.part`, the name cut so the whole stays within
    /// 255 bytes: a long device file name used to fail before a byte came.
    static func partName(for destination: URL, tag: String) -> String {
        let suffix = ".sheepterm-\(tag).part"
        var budget = 255 - 1 - suffix.utf8.count
        var kept = ""
        for character in destination.lastPathComponent {
            let size = String(character).utf8.count
            guard size <= budget else { break }
            budget -= size
            kept.append(character)
        }
        return "." + kept + suffix
    }

    /// True when the file is marked.
    @discardableResult
    static func commit(_ part: URL, to destination: URL, replacing: Bool) throws -> Bool {
        let marked = Quarantine.mark(part)
        let moved = replacing
            ? Darwin.rename(part.path, destination.path) == 0
            : renamex_np(part.path, destination.path, UInt32(RENAME_EXCL)) == 0
        guard moved else {
            let err = errno
            if err == EEXIST { throw RemoteFileError.alreadyExists(destination.lastPathComponent) }
            throw RemoteFileError.permissionDenied("\(destination.lastPathComponent) (\(String(cString: strerror(err))))")
        }
        return marked
    }
}
