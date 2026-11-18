import XCTest
@testable import SheepSync

final class SyncMergeTests: XCTestCase {
    private func digest(_ id: String, _ data: Data) -> String { id + ":" + data.base64EncodedString() }
    private func d(_ s: String) -> Data { Data(s.utf8) }
    private func stamp(_ t: Int64, _ dev: String = "B") -> SyncStamp { SyncStamp(modified: t, device: dev) }

    private func plan(_ local: [String: String], unavailable: Set<String> = [],
                      shadow: [String: ShadowEntry]?, remote: [SyncRecord], now: Int64 = 1000) -> SyncPlan {
        SyncMerge.plan(snapshot: SyncSnapshot(records: local.mapValues { d($0) }, unavailable: unavailable),
                       shadow: shadow, remote: Dictionary(uniqueKeysWithValues: remote.map { ($0.id, $0) }),
                       now: now, device: "A", digest: digest)
    }

    private func synced(_ id: String, _ value: String, _ t: Int64, _ dev: String = "B") -> (SyncRecord, ShadowEntry) {
        (SyncRecord(id: id, stamp: stamp(t, dev), payload: d(value)),
         ShadowEntry(stamp: stamp(t, dev), deleted: false, digest: digest(id, d(value))))
    }

    /// SheepTerm 6.1 (14): a record a NEWER build made (a setting this build
    /// does not list) is applied, not seen again, and must not come back as a
    /// deletion — the app marks the family unavailable by prefix.
    func testARecordThisBuildCannotSeeUnderAnUnavailablePrefixIsNeverDeleted() {
        let (r, s) = synced("setting:hostWorkspaces", "{}", 500)
        let snapshot = SyncSnapshot(records: ["setting:theme": d("dark")], unavailable: [], unavailablePrefixes: ["setting:"])
        let p = SyncMerge.plan(snapshot: snapshot, shadow: ["setting:hostWorkspaces": s], remote: [r.id: r],
                               now: 1000, device: "A", digest: digest)
        XCTAssertEqual(p.merged["setting:hostWorkspaces"], r, "the cloud's copy stays")
        XCTAssertNil(p.apply["setting:hostWorkspaces"] ?? nil)
        XCTAssertFalse(p.merged["setting:hostWorkspaces"]?.deleted ?? true)
        // Without the prefix the same state WAS a deletion (what older builds did).
        let old = SyncMerge.plan(snapshot: SyncSnapshot(records: ["setting:theme": d("dark")], unavailable: []),
                                 shadow: ["setting:hostWorkspaces": s], remote: [r.id: r], now: 1000, device: "A", digest: digest)
        XCTAssertEqual(old.merged["setting:hostWorkspaces"]?.deleted, true)
    }

    func testFirstJoinTakesTheCloudAndUploadsOnlyWhatTheCloudLacks() {
        let remote = SyncRecord(id: "hosts", stamp: stamp(500), payload: d("cloud"))
        let p = plan(["hosts": "fresh-mac-default", "snippets": "local only"], shadow: nil, remote: [remote])
        XCTAssertEqual(p.apply, ["hosts": d("cloud")])
        XCTAssertEqual(p.merged["hosts"], remote)
        XCTAssertEqual(p.merged["snippets"]?.payload, d("local only"))
        XCTAssertEqual(p.merged["snippets"]?.stamp, stamp(1000, "A"))
        XCTAssertTrue(p.needsUpload)
        XCTAssertEqual(p.shadow["hosts"]?.digest, digest("hosts", d("cloud")))
    }

    func testFirstSyncOfAnEmptyVaultUploadsEverything() {
        let p = plan(["hosts": "h", "pw:1": "secret"], shadow: nil, remote: [])
        XCTAssertTrue(p.apply.isEmpty)
        XCTAssertEqual(Set(p.merged.keys), ["hosts", "pw:1"])
        XCTAssertTrue(p.needsUpload)
    }

    func testNothingChangedMeansNoUploadAndNoApply() {
        let (r, s) = synced("hosts", "v1", 500)
        let p = plan(["hosts": "v1"], shadow: ["hosts": s], remote: [r])
        XCTAssertFalse(p.needsUpload)
        XCTAssertTrue(p.apply.isEmpty)
        XCTAssertEqual(p.shadow, ["hosts": s])
    }

    func testLocalEditBeatsAnOlderCloudCopy() {
        let (r, s) = synced("hosts", "v1", 500)
        let p = plan(["hosts": "v2"], shadow: ["hosts": s], remote: [r])
        XCTAssertTrue(p.needsUpload)
        XCTAssertEqual(p.merged["hosts"]?.payload, d("v2"))
        XCTAssertEqual(p.merged["hosts"]?.stamp, stamp(1000, "A"))
        XCTAssertTrue(p.apply.isEmpty)
    }

    func testNewerCloudCopyIsAppliedWhenUnchangedHere() {
        let (_, s) = synced("hosts", "v1", 500)
        let newer = SyncRecord(id: "hosts", stamp: stamp(800), payload: d("v3"))
        let p = plan(["hosts": "v1"], shadow: ["hosts": s], remote: [newer])
        XCTAssertEqual(p.apply, ["hosts": d("v3")])
        XCTAssertFalse(p.needsUpload)
    }

    func testBothChangedLaterStampWins() {
        let (_, s) = synced("hosts", "v1", 500)
        // Cloud edited at 2000, after our "now" of 1000: cloud wins.
        let later = SyncRecord(id: "hosts", stamp: stamp(2000), payload: d("theirs"))
        let p = plan(["hosts": "mine"], shadow: ["hosts": s], remote: [later])
        XCTAssertEqual(p.apply, ["hosts": d("theirs")])
        XCTAssertFalse(p.needsUpload)
    }

    func testLocalDeleteBecomesATombstone() {
        let (r, s) = synced("pw:1", "x", 500)
        let p = plan([:], shadow: ["pw:1": s], remote: [r])
        XCTAssertEqual(p.merged["pw:1"], SyncRecord(id: "pw:1", stamp: stamp(1000, "A"), deleted: true, payload: nil))
        XCTAssertTrue(p.needsUpload)
        XCTAssertEqual(p.shadow["pw:1"]?.deleted, true)
    }

    func testCloudTombstoneDeletesHere() {
        let (_, s) = synced("pw:1", "x", 500)
        let gone = SyncRecord(id: "pw:1", stamp: stamp(700), deleted: true, payload: nil)
        let p = plan(["pw:1": "x"], shadow: ["pw:1": s], remote: [gone])
        XCTAssertEqual(p.apply.count, 1)
        XCTAssertEqual(p.apply["pw:1"], .some(nil))
    }

    func testUnavailableRecordIsNeverTombstoned() {
        let (r, s) = synced("pw:1", "x", 500)
        let p = plan([:], unavailable: ["pw:1"], shadow: ["pw:1": s], remote: [r])
        XCTAssertFalse(p.needsUpload)
        XCTAssertEqual(p.merged["pw:1"], r)
        // Nothing newer in the cloud than what was last synced: nothing to
        // bring down (round-2 review: re-applying it every sync only
        // overwrote whatever was really there).
        XCTAssertTrue(p.apply.isEmpty)
    }

    func testUnavailableRecordStillGetsANewerCloudCopy() {
        let (_, s) = synced("pw:1", "x", 500)
        let newer = SyncRecord(id: "pw:1", stamp: stamp(800), payload: d("y"))
        let p = plan([:], unavailable: ["pw:1"], shadow: ["pw:1": s], remote: [newer])
        XCTAssertEqual(p.apply, ["pw:1": d("y")])
    }

    func testUnavailableNeverSyncedHereGetsTheCloudCopy() {
        // A new Mac: the credential is listed, its password never arrived.
        let r = SyncRecord(id: "pw:1", stamp: stamp(500), payload: d("x"))
        let p = plan([:], unavailable: ["pw:1"], shadow: [:], remote: [r])
        XCTAssertEqual(p.apply, ["pw:1": d("x")])
    }

    func testUnavailableAndAbsentFromTheCloudKeepsItsShadow() {
        let (_, s) = synced("pw:1", "x", 500)
        let p = plan([:], unavailable: ["pw:1"], shadow: ["pw:1": s], remote: [])
        XCTAssertTrue(p.merged.isEmpty)
        XCTAssertFalse(p.needsUpload)
        XCTAssertEqual(p.shadow["pw:1"], s)
    }

    func testRecreatedAfterDeleteWins() {
        let tomb = ShadowEntry(stamp: stamp(500), deleted: true, digest: nil)
        let remote = SyncRecord(id: "pw:1", stamp: stamp(500), deleted: true, payload: nil)
        let p = plan(["pw:1": "again"], shadow: ["pw:1": tomb], remote: [remote])
        XCTAssertEqual(p.merged["pw:1"]?.payload, d("again"))
        XCTAssertTrue(p.needsUpload)
    }

    func testOldTombstonesExpire() {
        let old = SyncRecord(id: "pw:1", stamp: stamp(1), deleted: true, payload: nil)
        let now = 2 + SyncMerge.tombstoneLifetimeMs
        let p = plan([:], shadow: ["pw:1": ShadowEntry(stamp: stamp(1), deleted: true, digest: nil)],
                     remote: [old], now: now)
        XCTAssertNil(p.merged["pw:1"])
        XCTAssertNil(p.shadow["pw:1"])
        XCTAssertTrue(p.needsUpload)
    }

    /// Regression: an edit in the same millisecond as the last sync tied
    /// with the cloud's stamp, lost, and the old cloud value was written
    /// back over it (seen as a flaky engine test).
    func testEditInTheSameMillisecondAsTheSyncStillWins() {
        let (r, s) = synced("hosts", "v1", 1000, "A")
        let p = plan(["hosts": "v2"], shadow: ["hosts": s], remote: [r], now: 1000)
        XCTAssertEqual(p.merged["hosts"]?.payload, d("v2"))
        XCTAssertEqual(p.merged["hosts"]?.stamp, stamp(1001, "A"))
        XCTAssertTrue(p.apply.isEmpty)
        XCTAssertTrue(p.needsUpload)
    }

    func testExactTieIsResolvedTheSameWayOnEveryMac() {
        let a = SyncStamp(modified: 5, device: "A")
        let b = SyncStamp(modified: 5, device: "B")
        XCTAssertTrue(a < b)
        XCTAssertFalse(b < a)
    }

    /// Round 4: when the app asks for a whole family (its file is gone), the
    /// plan must bring down EVERY record of it — not only the ones the cloud
    /// changed since the last sync. Otherwise the rebuilt file holds just
    /// those, and the next sync tombstones the rest everywhere.
    func testWantCloudPrefixBringsTheWholeFamily() {
        var shadow: [String: ShadowEntry] = [:]
        var remote: [SyncRecord] = []
        for name in ["A", "B", "C"] {
            let (r, s) = synced("snippet:\(name)", name, 500)
            shadow[r.id] = s
            remote.append(r)
        }
        remote[1] = SyncRecord(id: "snippet:B", stamp: stamp(900), payload: d("B2"))
        let p = SyncMerge.plan(snapshot: SyncSnapshot(records: [:], wantCloudPrefixes: ["snippet:"]),
                               shadow: shadow, remote: Dictionary(uniqueKeysWithValues: remote.map { ($0.id, $0) }),
                               now: 1000, device: "A", digest: digest)
        XCTAssertEqual(Set(p.apply.keys), ["snippet:A", "snippet:B", "snippet:C"])
        XCTAssertFalse(p.needsUpload)
    }

    // MARK: A cloud deletion the app never carries out (SheepTerm's settings)

    private func keeping(_ local: [String: String], shadow: [String: ShadowEntry]?, remote: [SyncRecord],
                         now: Int64, device: String = "C") -> SyncPlan {
        SyncMerge.plan(snapshot: SyncSnapshot(records: local.mapValues { d($0) }, unavailablePrefixes: ["setting:"],
                                              keepOnRemoteDeletePrefixes: ["setting:"]),
                       shadow: shadow, remote: Dictionary(uniqueKeysWithValues: remote.map { ($0.id, $0) }),
                       now: now, device: device, digest: digest)
    }

    /// The B / C / old-Mac replay: B and C hold plan P1 (t1); an OLD build,
    /// which does not list the key, uploads its deletion at t4; C syncs it
    /// (the app never deletes a setting); B edits to P2 at t5; C syncs at t6.
    /// C used to remember the tombstone as in step, read its untouched P1 as
    /// a fresh edit stamped t6 and upload it over B's P2 — and every new Mac
    /// did the same every round.
    func testAnOldBuildsSettingDeletionNeverTurnsTheUntouchedValueIntoANewEdit() {
        let id = "setting:hostWorkspaces"
        let (_, s1) = synced(id, "P1", 1, "A")
        let tomb = SyncRecord(id: id, stamp: stamp(4, "Old"), deleted: true, payload: nil)

        // t4: the deletion arrives. Kept here, not applied, nothing uploaded.
        let atT4 = keeping([id: "P1"], shadow: [id: s1], remote: [tomb], now: 4)
        XCTAssertNil(atT4.apply[id] ?? nil)
        XCTAssertTrue(atT4.apply.isEmpty, "a setting is never deleted from the cloud's say-so")
        XCTAssertFalse(atT4.needsUpload)
        XCTAssertEqual(atT4.merged[id], tomb, "the cloud keeps what the old build wrote")
        XCTAssertEqual(atT4.shadow[id], ShadowEntry(stamp: tomb.stamp, deleted: false, digest: digest(id, d("P1"))))

        // t6: B's P2 (t5) is in the cloud; C's P1 is untouched — B's wins.
        let p2 = SyncRecord(id: id, stamp: stamp(5, "B"), payload: d("P2"))
        let atT6 = keeping([id: "P1"], shadow: atT4.shadow, remote: [p2], now: 6)
        XCTAssertEqual(atT6.apply, [id: d("P2")], "B's newer edit comes down")
        XCTAssertEqual(atT6.merged[id], p2)
        XCTAssertFalse(atT6.needsUpload, "stale P1 is not uploaded over P2")

        // The bug, for the record: the same pass from a tombstone shadow.
        let buggy = keeping([id: "P1"], shadow: [id: ShadowEntry(stamp: tomb.stamp, deleted: true, digest: nil)],
                            remote: [p2], now: 6)
        XCTAssertEqual(buggy.merged[id]?.payload, d("P1"), "what the old shadow did")
    }

    /// Its quiet twin: after the kept deletion, round after round is idle —
    /// nothing uploaded, nothing applied, the same shadow.
    func testAKeptDeletionStaysQuietRoundAfterRound() {
        let id = "setting:theme"
        let (_, s1) = synced(id, "dark", 1, "A")
        let tomb = SyncRecord(id: id, stamp: stamp(4, "Old"), deleted: true, payload: nil)
        var shadow: [String: ShadowEntry] = [id: s1]
        for round in 0..<3 {
            let p = keeping([id: "dark"], shadow: shadow, remote: [tomb], now: 10 + Int64(round))
            XCTAssertFalse(p.needsUpload, "round \(round)")
            XCTAssertTrue(p.apply.isEmpty, "round \(round)")
            if round > 0 { XCTAssertEqual(p.shadow, shadow, "round \(round)") }
            shadow = p.shadow
        }
        // A REAL edit after it still syncs, stamped after the tombstone.
        let edited = keeping([id: "light"], shadow: shadow, remote: [tomb], now: 20)
        XCTAssertTrue(edited.needsUpload)
        XCTAssertEqual(edited.merged[id]?.payload, d("light"))
        XCTAssertEqual(edited.merged[id]?.stamp, stamp(20, "C"))
        // A Mac joining the vault keeps its value too, without uploading it.
        let joining = keeping([id: "dark"], shadow: nil, remote: [tomb], now: 30)
        XCTAssertTrue(joining.apply.isEmpty)
        XCTAssertFalse(joining.needsUpload)
    }

    /// Only the listed records: a password's deletion still deletes, and a
    /// setting with no value here still records the tombstone (a value set
    /// later is a real edit and goes up).
    func testOnlyListedRecordsWithAValueKeepTheirCopy() {
        let (_, sp) = synced("pw:1", "x", 1)
        let gone = SyncRecord(id: "pw:1", stamp: stamp(4), deleted: true, payload: nil)
        let p = keeping(["pw:1": "x"], shadow: ["pw:1": sp], remote: [gone], now: 5)
        XCTAssertEqual(p.apply["pw:1"], .some(nil))

        let id = "setting:theme"
        let (_, s1) = synced(id, "dark", 1)
        let tomb = SyncRecord(id: id, stamp: stamp(4, "Old"), deleted: true, payload: nil)
        let absent = keeping([:], shadow: [id: s1], remote: [tomb], now: 5)
        XCTAssertEqual(absent.shadow[id]?.deleted, true)
        let setLater = keeping([id: "light"], shadow: absent.shadow, remote: [tomb], now: 9)
        XCTAssertTrue(setLater.needsUpload)
        XCTAssertEqual(setLater.merged[id]?.payload, d("light"))
    }
}
