import Foundation

/// The .sheepterm file format. Credentials never travel: only host
/// structure is included, credential references are stripped. Nor do the
/// settings that decide what this Mac hands a server: agent forwarding is
/// stripped both ways and the cipher policy is reset on import (see `decode`).
///
/// `group` is the original single-group field and stays for good: a file this
/// build writes has to stay readable by a build that has never heard of
/// sections or of multi-group files. A multi-group export fills `groups` with
/// every group and `group` with the FIRST of them, so an older build importing
/// it gets one real group instead of an error. (Sections are not a level of
/// the file: a group carries its own heading LIST in `HostGroup.sections` —
/// empty headings included — and each host a pointer into it in
/// `Host.section`. A build that predates the list drops the key and shows the
/// headings its hosts imply, which is what `sanitizeHeadings` puts back.)
struct SharePayload: Codable {
    var version = 1
    var sender: String
    var group: HostGroup
    /// Every group in the file, for a section export. nil in a single-group
    /// file written by any build, including this one.
    var groups: [HostGroup]? = nil

    /// What an importer should work through, in file order.
    ///
    /// `groups`, when a file has one, normally already contains `group` (we
    /// write the first of them there for older builds). A hand-written or
    /// third-party file need not honour that, so `group` is unioned in when
    /// its id is missing — dropping a group because a file was sloppy is not
    /// an outcome worth having.
    var allGroups: [HostGroup] {
        guard let groups else { return [group] }
        return groups.contains(where: { $0.id == group.id }) ? groups : [group] + groups
    }
}

enum ShareCodec {
    static func encode(_ group: HostGroup, sender: String) throws -> Data {
        try encode([group], sender: sender)
    }

    /// One file for several groups. **Nothing in the UI writes one today** —
    /// a section belongs to its GROUP (`HostGroup.sections`, plus each host's
    /// pointer into that list), so a group export already brings its headings
    /// with it — empty ones included — and there is no "export a section".
    /// The multi-group path is kept because reading one costs nothing and a
    /// file from elsewhere (or a future export of several groups at once) must
    /// not be refused.
    static func encode(_ groups: [HostGroup], sender: String) throws -> Data {
        let sanitized = groups.map(stripForExport)
        // A single group is written exactly as before — same shape, same
        // keys, no `groups` array — so nothing that reads today's files has
        // to change to read tomorrow's single exports.
        guard let first = sanitized.first else {
            throw CocoaError(.coderInvalidValue)
        }
        var payload = SharePayload(sender: sender, group: first)
        if sanitized.count > 1 { payload.groups = sanitized }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(payload)
    }

    static func decode(_ data: Data) throws -> SharePayload {
        var payload = try JSONDecoder().decode(SharePayload.self, from: data)
        // Strip on the way IN as well. encode() drops credentialID, but a
        // hand-edited or third-party file can carry one, and an imported host
        // that points at a local credential would connect with a password the
        // sender never had. "Credentials never travel" has to be true of the
        // files we read, not only the ones we write — and of EVERY group in
        // them, not just the first.
        //
        // The same goes for the two connection settings that are about what
        // THIS Mac hands the far end, not about the device: `agentForward`
        // and `cipherMode`. A file that switched agent forwarding on would
        // give whoever runs the server in it the use of the importer's
        // ssh-agent keys for as long as the session is open, and the import
        // dialog for a new group does not show either field. So every
        // incoming host arrives with forwarding OFF (explicitly `false`, not
        // nil: nil is a hole `Host.completed(from:)` may fill) and the cipher
        // policy back at auto (nil — the default every new host has). Turning
        // either on is the importer's own decision, in Edit Host.
        //
        // This is the one door: Finder open, the Import menu and anything else
        // that reads a .sheepterm go through `decode`. On a Replace, the host
        // that lands is the file's version, so a replaced host also ends up
        // with forwarding off and cipher auto — and the Replace/Keep diff,
        // which compares effective values, names exactly that change.
        payload.group = stripForImport(payload.group)
        payload.groups = payload.groups?.map(stripForImport)
        return payload
    }

    /// What never leaves this Mac in a .sheepterm: the credential reference
    /// and the agent-forwarding switch (nil = key absent from the file). The
    /// cipher policy still travels — an older build reading the file uses it,
    /// and a legacy-only box is worth knowing about — but `decode` resets it,
    /// so it is information, never a setting.
    static func stripForExport(_ group: HostGroup) -> HostGroup {
        var copy = group
        copy.hosts = group.hosts.map { host in
            var host = host
            host.credentialID = nil
            host.agentForward = nil
            return host
        }
        return copy
    }

    /// What a .sheepterm may not decide for the importer: which credential a
    /// host uses, whether it forwards the ssh-agent, which cipher policy it
    /// negotiates with. See `decode`.
    static func stripForImport(_ group: HostGroup) -> HostGroup {
        var copy = group
        copy.hosts = group.hosts.map { host in
            var host = host
            host.credentialID = nil
            host.agentForward = false
            host.cipherMode = nil
            return host
        }
        return copy
    }

    static var deviceName: String {
        Foundation.Host.current().localizedName ?? "Mac"
    }
}
