import XCTest
@testable import SheepSync

/// Times an UNCHANGED sync round on main (6.1 (62)): 2,300 records of a few
/// hundred bytes (2,000 hosts + 300 groups' worth), after the vault settled.
/// Prints the median; asserts only a generous ceiling (the numbers belong in
/// the commit message, not in a flaky threshold).
@MainActor
final class SyncRoundBenchTests: XCTestCase {
    final class BenchApp: SyncDataSource {
        var records: [String: Data] = [:]
        func syncSnapshot() -> SyncSnapshot { SyncSnapshot(records: records) }
        func syncApply(_ changes: [String: Data?], firstJoin: Bool) -> SyncApplyResult {
            for (id, value) in changes { records[id] = value }
            return SyncApplyResult(failed: [])
        }
    }
    final class Secrets: SecretStoring, @unchecked Sendable {
        private let lock = NSLock()
        private var items: [String: Data] = [:]
        func read(_ account: String) -> Data? { lock.withLock { items[account] } }
        func write(_ account: String, _ value: Data) -> Bool { lock.withLock { items[account] = value }; return true }
        func delete(_ account: String) -> Bool { lock.withLock { items[account] = nil }; return true }
    }

    func testUnchangedRoundCost() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("sheepsync-bench-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = SyncConfiguration(
            appName: "Bench", google: GoogleClient(clientID: "1-x.apps.googleusercontent.com", clientSecret: nil),
            keychainService: "unused", stateDirectory: directory, deviceName: "A",
            debounce: .milliseconds(10), interval: .seconds(3600))
        let secrets = Secrets()
        SyncEngine.setRefreshToken("refresh", in: secrets)
        let drive = MemorySyncBackend()
        let engine = SyncEngine(configuration: config, secrets: secrets, makeBackend: { _ in drive })
        let app = BenchApp()
        for i in 0..<2_300 {
            let id = i < 2_000 ? "host:\(UUID().uuidString)" : "group:\(UUID().uuidString)"
            app.records[id] = Data(#"{"address":"10.\#(i % 250).\#(i / 250).1","kind":"ssh","name":"sw-core-\#(i)","port":22,"username":"admin","groupID":"\#(UUID().uuidString)"}"#.utf8)
        }
        engine.dataSource = app
        await engine.checkVault()
        try await engine.createVault(passphrase: "bench")
        await engine.syncNow()
        await engine.syncNow()
        var times: [Double] = []
        for _ in 0..<9 {
            let start = ContinuousClock.now
            await engine.syncNow()
            let took = start.duration(to: .now)
            times.append(Double(took.components.attoseconds) / 1e15 + Double(took.components.seconds) * 1000)
        }
        XCTAssertNil(engine.lastError)
        times.sort()
        print(String(format: "[sync bench] unchanged round, 2,300 records: median %.2f ms (min %.2f, max %.2f)", times[4], times[0], times[8]))
        XCTAssertLessThan(times[4], 500)
    }
}
