import Foundation

/// A login that rides along with a share link: one entry per distinct credential, with the ids (as written in the group document)
/// of the hosts that use it. Mirrors `SheepSync.ShareCredentials.Entry`; this file stays free of SheepSync so the test harness can
/// compile it.
nonisolated struct ShareLogin: Equatable, Sendable {
    var name: String
    var username: String
    var password: String
    var hostIDs: [String]
}

/// The Mac-side half of Share Link that is pure (no Google, no UI): what leaves with a group, and how what arrives becomes a group.
/// The package (`ShareService`) deals in opaque bytes; this is where those bytes are a SheepTerm group.
enum ShareLinkPlan {
    struct Outgoing {
        /// `ShareCodec` bytes: credentialID, agent forwarding and jump hosts already stripped.
        var document: Data
        var hostCount: Int
        var logins: [ShareLogin]
    }

    enum PlanError: Error, LocalizedError {
        case noGroup, passwordNotKept
        var errorDescription: String? {
            switch self {
            case .noGroup: return "The shared group could not be read."
            // Same words as SheepTerm for Windows (SheepTermSync/ShareLinkPlan.swift).
            case .passwordNotKept: return "A shared password could not be saved in the Keychain, so nothing was imported."
            }
        }
    }

    /// The import preview, counted from the DECODED document: the envelope's host count and name are only the sender's claim.
    /// The name is cut to the length a group name may have.
    static func preview(document: Data) throws -> (name: String, hostCount: Int) {
        let group = try decode(document: document)
        return (String(group.name.prefix(maxPreviewName)), group.hosts.count)
    }
    static let maxPreviewName = 64

    /// What the preview card shows, worked out ONCE when the content arrives (the sheet keeps it in its stage): the
    /// decoded document's name and count, or — if it does not decode — the envelope's name cut to size and its count.
    static func previewSummary(document: Data, envelopeName: String, envelopeHostCount: Int) -> (name: String, hostCount: Int) {
        (try? preview(document: document)) ?? (String(envelopeName.prefix(maxPreviewName)), envelopeHostCount)
    }

    /// Hosts as they land: the sender's "Disable paging on connect" is NOT kept — the importer's app must not start sending
    /// commands to devices because someone else ticked a box (the app never sends on its own unless this user chose it).
    static func landing(_ group: HostGroup) -> HostGroup {
        var out = group
        for index in out.hosts.indices { out.hosts[index].disablePaging = nil }
        return out
    }

    /// Sender side: hosts that reach their device through a jump host (saved bastion or typed spec). The jump host never travels.
    static func jumpHostCount(_ group: HostGroup) -> Int {
        group.hosts.filter { $0.jumpHostID != nil || !($0.jumpSpec ?? "").isEmpty }.count
    }

    /// The share sheet's line for `jumpHostCount` (same words as SheepTerm for Windows); nil when no host uses one.
    static func jumpHostNote(_ count: Int) -> String? {
        count == 0 ? nil : "\(count) host\(count == 1 ? " uses" : "s use") a jump host \u{2014} it is not shared."
    }

    /// All or nothing, like SheepTerm for Windows: every password is stored BEFORE any credential exists; one refusal removes the
    /// ones already written and the import stops with nothing added. `ids` runs parallel to `logins`.
    static func storePasswords(_ logins: [ShareLogin], ids: [UUID], set: (String, UUID) -> Bool, remove: (UUID) -> Void) -> Bool {
        var written: [UUID] = []
        for (login, id) in zip(logins, ids) where !login.password.isEmpty {
            guard set(login.password, id) else {
                written.forEach(remove)
                return false
            }
            written.append(id)
        }
        return true
    }

    /// A group as it travels. `credential`/`password` are the sender's own lookups; a host with a credential whose password is missing
    /// contributes no login (it would arrive as a username with nothing to open it).
    static func outgoing(group: HostGroup, credential: (UUID) -> (name: String, username: String)?, password: (UUID) -> String?) throws -> Outgoing {
        let document = try ShareCodec.encode(group, sender: "share")
        var order: [UUID] = []
        var byCredential: [UUID: ShareLogin] = [:]
        for host in group.hosts {
            guard let id = host.credentialID, let cred = credential(id), let secret = password(id), !secret.isEmpty else { continue }
            if byCredential[id] == nil {
                byCredential[id] = ShareLogin(name: cred.name, username: cred.username, password: secret, hostIDs: [])
                order.append(id)
            }
            byCredential[id]?.hostIDs.append(host.id.uuidString)
        }
        return Outgoing(document: document, hostCount: group.hosts.count, logins: order.compactMap { byCredential[$0] })
    }

    /// How many distinct logins `outgoing` would carry (for the sheet: the checkbox is off when there are none).
    static func loginCount(group: HostGroup, credential: (UUID) -> (name: String, username: String)?, hasPassword: (UUID) -> Bool) -> Int {
        Set(group.hosts.compactMap { $0.credentialID }.filter { credential($0) != nil && hasPassword($0) }).count
    }

    /// The incoming group document → a group. Goes through `ShareCodec.decode`, the one door every incoming group uses, so no
    /// credentialID, agent forwarding, jump host or cipher override can arrive whatever the sender's file held.
    static func decode(document: Data) throws -> HostGroup {
        guard let group = try ShareCodec.decode(document).allGroups.first else { throw PlanError.noGroup }
        return group
    }

    /// Points each host at the credential created for its login (`credentialIDs` runs parallel to `logins`). The host keeps its
    /// username unless the login names one: a credential's username and its password are ONE login (HostEditSheet.effectiveUsername).
    static func attach(_ logins: [ShareLogin], credentialIDs: [UUID], to group: HostGroup) -> HostGroup {
        var out = group
        for (login, id) in zip(logins, credentialIDs) {
            let wanted = Set(login.hostIDs)
            for index in out.hosts.indices where wanted.contains(out.hosts[index].id.uuidString) {
                out.hosts[index].credentialID = id
                if !login.username.isEmpty { out.hosts[index].username = login.username }
            }
        }
        return out
    }
}
