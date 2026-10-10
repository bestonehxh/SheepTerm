import Foundation

/// Platform-neutral, public face of the Mac app's Sync rules (SyncPolicy.swift:
/// what may be read as "deleted", what may be written; and the per-record
/// split/join of hosts.json, credentials.json and snippets.json). The Windows
/// app compiles the SAME file, so a record id, a canonical record or a
/// "never read as deletion" decision cannot drift between the two apps.
public nonisolated enum CoreSync {
    public static let passwordPrefix = SyncPolicy.passwordPrefix
    public static let recoveredGroupID = SyncRecordCodec.recoveredGroupID

    public nonisolated struct Family: Equatable, Sendable {
        public let file: String
        public let order: String
        public let item: String
        public let child: String?
        public var prefixes: [String] { inner.prefixes }
        public func owns(_ id: String) -> Bool { inner.owns(id) }
        fileprivate var inner: SyncRecordCodec.Family { SyncRecordCodec.Family(file: file, order: order, item: item, child: child) }
        fileprivate init(_ f: SyncRecordCodec.Family) { file = f.file; order = f.order; item = f.item; child = f.child }
    }

    public static let families: [Family] = SyncRecordCodec.families.map(Family.init)
    public static let hosts = Family(SyncRecordCodec.hosts)
    public static let credentials = Family(SyncRecordCodec.credentials)
    public static let snippets = Family(SyncRecordCodec.snippets)

    public static func decompose(_ data: Data, as family: Family) throws -> [String: Data] {
        try SyncRecordCodec.decompose(data, as: family.inner)
    }
    public static func compose(_ records: [String: Data], as family: Family) throws -> Data {
        try SyncRecordCodec.compose(records, as: family.inner)
    }
    public static func canonical(_ object: Any) throws -> Data { try SyncRecordCodec.canonical(object) }

    public nonisolated struct PasswordRecords: Equatable, Sendable {
        public var records: [String: Data]
        public var unavailable: Set<String>
        public var unavailablePrefixes: [String]
    }
    public static func passwordRecords(listTrusted: Bool, listFileReadable: Bool, credentialIDs: [UUID],
                                       password: (UUID) -> String?) -> PasswordRecords {
        let r = SyncPolicy.passwordRecords(listTrusted: listTrusted, listFileReadable: listFileReadable,
                                           credentialIDs: credentialIDs, password: password)
        return PasswordRecords(records: r.records, unavailable: r.unavailable, unavailablePrefixes: r.unavailablePrefixes)
    }

    public nonisolated enum PasswordAction: Equatable, Sendable { case write, delete, skip, retry }
    public static func passwordAction(_ id: UUID, isDelete: Bool, listTrusted: Bool, known: Set<UUID>,
                                      listFailedThisRound: Bool) -> PasswordAction {
        switch SyncPolicy.passwordAction(id, isDelete: isDelete, listTrusted: listTrusted, known: known,
                                         listFailedThisRound: listFailedThisRound) {
        case .write: return .write
        case .delete: return .delete
        case .skip: return .skip
        case .retry: return .retry
        }
    }

    public nonisolated enum FamilyRead: Equatable, Sendable { case records, unavailable, wantCloud }
    public static func familyRead(quarantined: Bool, fileExists: Bool, storeEmpty: Bool, readableAndSaved: Bool) -> FamilyRead {
        switch SyncPolicy.familyRead(quarantined: quarantined, fileExists: fileExists, storeEmpty: storeEmpty,
                                     readableAndSaved: readableAndSaved) {
        case .records: return .records
        case .unavailable: return .unavailable
        case .wantCloud: return .wantCloud
        }
    }
    public static func mayApplyWithoutFile(quarantined: Bool, fileExists: Bool, storeEmpty: Bool) -> Bool {
        SyncPolicy.mayApplyWithoutFile(quarantined: quarantined, fileExists: fileExists, storeEmpty: storeEmpty)
    }
    public static func usableClientID(id: String, secret: String) -> String { SyncPolicy.usableClientID(id: id, secret: secret) }
}
