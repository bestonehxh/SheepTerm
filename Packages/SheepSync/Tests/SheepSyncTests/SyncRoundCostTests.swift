import CryptoKit
import XCTest
@testable import SheepSync

/// The cost of an unchanged sync round (6.1 (62)): the record digests are
/// remembered per sealer, and a round that changed nothing but the time does
/// not rewrite the whole state file. Same answers as before — only cheaper.
final class SyncRoundCostTests: XCTestCase {
    private func randomPayload(_ count: Int = .random(in: 0...600)) -> Data {
        Data((0..<count).map { _ in UInt8.random(in: 0...255) })
    }

    /// Every memo answer is the HMAC's own, whatever was asked before.
    func testDigestMemoMatchesTheHMAC() {
        let sealer = VaultSealer(vaultKey: SymmetricKey(size: .bits256))
        var ids = (0..<300).map { "host:\($0)" } + ["", "setting:a", "password:" + UUID().uuidString]
        var payloads = Dictionary(uniqueKeysWithValues: ids.map { ($0, randomPayload()) })
        for round in 0..<12 {
            for id in ids {
                let payload = payloads[id]!
                XCTAssertEqual(sealer.digest(id: id, payload: payload), sealer.uncachedDigest(id: id, payload: payload), "round \(round) \(id)")
                // Asked twice in one plan: the same answer.
                XCTAssertEqual(sealer.digest(id: id, payload: payload), sealer.uncachedDigest(id: id, payload: payload))
            }
            // Edits between rounds: changed bytes, one byte flipped, the same
            // bytes under another id, a record gone, one added.
            for id in ids.shuffled().prefix(20) { payloads[id] = randomPayload() }
            if var flipped = payloads["host:1"], !flipped.isEmpty {
                flipped[flipped.startIndex] ^= 0x01
                payloads["host:1"] = flipped
            }
            payloads["host:2"] = payloads["host:3"]
            if let gone = ids.popLast() { payloads[gone] = nil }
            let added = "snippet:\(round)"
            ids.append(added)
            payloads[added] = randomPayload()
            sealer.endDigestRound()
        }
        // An id and its payload swapped around the separator are not one record.
        XCTAssertNotEqual(sealer.digest(id: "a", payload: Data("b".utf8)), sealer.digest(id: "ab", payload: Data()))
    }

    /// Another key, another memo: two sealers never answer for each other.
    func testDigestMemoIsPerKey() {
        let one = VaultSealer(vaultKey: SymmetricKey(size: .bits256))
        let other = VaultSealer(vaultKey: SymmetricKey(size: .bits256))
        let payload = Data("router-core-01".utf8)
        let a = one.digest(id: "host:1", payload: payload)
        let b = other.digest(id: "host:1", payload: payload)
        XCTAssertNotEqual(a, b)
        XCTAssertEqual(b, other.uncachedDigest(id: "host:1", payload: payload))
        // The same key in a fresh sealer (an unlock after sign-out) agrees.
        let key = SymmetricKey(size: .bits256)
        XCTAssertEqual(VaultSealer(vaultKey: key).digest(id: "x", payload: payload),
                       VaultSealer(vaultKey: key).uncachedDigest(id: "x", payload: payload))
    }

    /// The memo holds one round's records, not every payload ever seen.
    func testDigestMemoKeepsOneRound() {
        let sealer = VaultSealer(vaultKey: SymmetricKey(size: .bits256))
        let memo = Mirror(reflecting: sealer).children.first { $0.label == "memo" }!.value as! DigestMemo
        for i in 0..<100 { _ = sealer.digest(id: "a:\(i)", payload: randomPayload(32)) }
        sealer.endDigestRound()
        XCTAssertEqual(memo.count, 100)
        for i in 0..<10 { _ = sealer.digest(id: "a:\(i)", payload: randomPayload(32)) }   // 10 changed
        for i in 10..<20 { _ = sealer.digest(id: "b:\(i)", payload: randomPayload(32)) }  // 10 new
        sealer.endDigestRound()
        XCTAssertEqual(memo.count, 20, "only what the last round asked for stays")
        sealer.endDigestRound()
        XCTAssertEqual(memo.count, 0)
    }

    /// The whole merge, memo vs none, over generated rounds of edits on both
    /// sides: the same plan every time.
    func testPlanIsTheSameWithTheMemo() {
        let key = SymmetricKey(size: .bits256)
        let memoized = VaultSealer(vaultKey: key)
        let plain = VaultSealer(vaultKey: key)
        var local: [String: Data] = [:]
        for i in 0..<200 { local["host:\(i)"] = randomPayload(64) }
        var remote: [String: SyncRecord] = [:]
        var shadowA: [String: ShadowEntry]? = nil
        var shadowB: [String: ShadowEntry]? = nil
        var now: Int64 = 1_700_000_000_000
        for round in 0..<25 {
            now += 300_000
            // This Mac: edits, deletions, additions; some unreadable.
            for id in local.keys.shuffled().prefix(5) { local[id] = randomPayload(64) }
            if round % 3 == 0, let gone = local.keys.randomElement() { local[gone] = nil }
            local["snippet:\(round)"] = randomPayload(40)
            let unavailable = Set(local.keys.shuffled().prefix(round % 4))
            // Another Mac: a newer copy of a few records, and a tombstone.
            for id in remote.keys.shuffled().prefix(3) {
                remote[id] = SyncRecord(id: id, stamp: SyncStamp(modified: now - 1, device: "B"), payload: randomPayload(64))
            }
            if round % 5 == 4, let id = remote.keys.randomElement() {
                remote[id] = SyncRecord(id: id, stamp: SyncStamp(modified: now - 1, device: "B"), deleted: true, payload: nil)
            }
            let snapshot = SyncSnapshot(records: local.filter { !unavailable.contains($0.key) }, unavailable: unavailable,
                                        keepOnRemoteDeletePrefixes: ["setting:"])
            let a = SyncMerge.plan(snapshot: snapshot, shadow: shadowA, remote: remote, now: now, device: "A",
                                   digest: memoized.digest)
            let b = SyncMerge.plan(snapshot: snapshot, shadow: shadowB, remote: remote, now: now, device: "A",
                                   digest: plain.uncachedDigest)
            XCTAssertEqual(a, b, "round \(round)")
            memoized.endDigestRound()
            shadowA = a.shadow
            shadowB = b.shadow
            remote = a.merged
            for (id, value) in a.apply { local[id] = value ?? nil }
        }
    }

    /// `sync-last.json` counts only beside the state it was written for.
    func testLastSyncNoteIsBoundToItsState() {
        let earlier = Date(timeIntervalSince1970: 1_700_000_000), later = earlier.addingTimeInterval(300)
        var state = SyncLocalState(device: "A#1")
        state.keyID = "k1"
        state.shadow = [:]
        state.lastSync = earlier
        let note = SyncEngine.LastSyncNote(keyID: "k1", lastSync: later)
        XCTAssertEqual(SyncEngine.lastSync(state: state, note: note), later)
        XCTAssertEqual(SyncEngine.lastSync(state: state, note: nil), earlier)
        XCTAssertEqual(SyncEngine.lastSync(state: state, note: .init(keyID: "k2", lastSync: later)), earlier, "another vault's note")
        XCTAssertEqual(SyncEngine.lastSync(state: state, note: .init(keyID: "k1", lastSync: earlier.addingTimeInterval(-1))), earlier,
                       "an older note never winds the time back")
        var forgotten = state
        forgotten.keyID = nil
        forgotten.shadow = nil
        forgotten.lastSync = nil
        XCTAssertNil(SyncEngine.lastSync(state: forgotten, note: note), "a forgotten vault does not get its time back")
        var joining = state
        joining.shadow = nil
        XCTAssertEqual(SyncEngine.lastSync(state: joining, note: note), earlier)
    }
}
