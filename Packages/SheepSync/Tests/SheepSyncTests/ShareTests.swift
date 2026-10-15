import Foundation
import XCTest
@testable import SheepSync

/// Share links: known-answer vectors made by Node's crypto (an independent AES-GCM / PBKDF2), round trips, tampering, link parsing,
/// recipients, expiry, naming, the scrub, and the whole service against an in-memory Drive with two users.
final class ShareTests: XCTestCase {
    private func hex(_ d: Data) -> String { d.map { String(format: "%02x", $0) }.joined() }
    private func unhex(_ s: String) -> Data {
        var out = Data(); var i = s.startIndex
        while i < s.endIndex { let j = s.index(i, offsetBy: 2); out.append(UInt8(s[i..<j], radix: 16)!); i = j }
        return out
    }
    private let key = Data(0..<32)

    // MARK: Vector (SHARE-LINK.md quotes it)

    static let vector = "53534c32000186a0101112131415161718191a1b1c1d1e1fa0a1a2a3a4a5a6a7a8a9aaab8c62266863f59282356513471c851c3c832699d1d86823ce70c8fe2ddbad3a2f5487462d04497c66153a140acf12b4f47160f52828de092a5e11a88d375af4d20ab9075a34c27cb0ee9ab4f09ce094a9f0fe973ba7c3e5f6cf9c85fe7d961b05fa91be12a3bf859e10693251d3e545733450892af60e523c8fd6329584e8d8f36bb03f80cdf80aa40daf76fbd761d66b19828b88b6c2edd36f0bb032d35ceda6f09e64a84e4663aa11ef966344"
    private var vectorEnvelope: ShareEnvelope {
        ShareEnvelope(created: 1_700_000_000, expires: nil, sender: "alice@example.test", recipients: ["bob@example.test"], name: "Lab",
                      hostCount: 2, group: Data(#"{"a":1}"#.utf8), credentials: nil)
    }

    func testBlobMatchesTheIndependentVector() throws {
        let salt = Data((0..<16).map { UInt8(0x10 + $0) }), nonce = Data((0..<12).map { UInt8(0xA0 + $0) })
        XCTAssertEqual(hex(try ShareCrypto.seal(vectorEnvelope, linkKey: key, passphrase: "correct horse", iterations: 100_000,
                                                salt: salt, nonce: nonce)), Self.vector)
        XCTAssertEqual(try ShareCrypto.open(unhex(Self.vector), linkKey: key, passphrase: "correct horse"), vectorEnvelope)
    }

    // MARK: Both halves are needed

    func testNeitherTheLinkNorThePassphraseAloneOpensIt() throws {
        let linkKey = try ShareCrypto.newLinkKey()
        var env = vectorEnvelope
        env.credentials = ShareCredentials(entries: [.init(name: "core", username: "root", password: "hunter2-secret", hosts: ["h1"])])
        let blob = try ShareCrypto.seal(env, linkKey: linkKey, passphrase: "correct horse", iterations: 100_000)
        XCTAssertEqual(try ShareCrypto.open(blob, linkKey: linkKey, passphrase: "correct horse"), env)
        // Link key right, passphrase wrong (and nearly right).
        for wrong in ["correct horsE", "", "correct horse ", "wrong wrong"] {
            XCTAssertThrowsError(try ShareCrypto.open(blob, linkKey: linkKey, passphrase: wrong), wrong) { XCTAssertEqual($0 as? ShareError, .wrongPassphrase) }
        }
        // Passphrase right, link key wrong (one bit).
        var other = linkKey; other[0] ^= 1
        XCTAssertThrowsError(try ShareCrypto.open(blob, linkKey: other, passphrase: "correct horse")) { XCTAssertEqual($0 as? ShareError, .wrongPassphrase) }
        // Nothing readable in the blob.
        for word in ["Lab", "alice", "bob@", "hunter2", "root"] { XCTAssertNil(blob.range(of: Data(word.utf8)), word) }
        // The same inputs give a different blob every time.
        XCTAssertNotEqual(blob, try ShareCrypto.seal(env, linkKey: linkKey, passphrase: "correct horse", iterations: 100_000))
    }

    func testPassphraseIsNFCNormalised() throws {
        let key = try ShareCrypto.newLinkKey()
        let blob = try ShareCrypto.seal(vectorEnvelope, linkKey: key, passphrase: "caf\u{e9} au lait", iterations: 100_000)
        XCTAssertEqual(try ShareCrypto.open(blob, linkKey: key, passphrase: "cafe\u{301} au lait"), vectorEnvelope)
    }

    func testEveryByteOfATamperedBlobIsRefused() throws {
        let blob = unhex(Self.vector)
        for index in stride(from: 0, to: blob.count, by: 2) {
            var bad = blob
            bad[index] ^= 0x01
            XCTAssertThrowsError(try ShareCrypto.open(bad, linkKey: key, passphrase: "correct horse"), "byte \(index)")
        }
        XCTAssertThrowsError(try ShareCrypto.open(blob.dropLast(), linkKey: key, passphrase: "correct horse"))
        XCTAssertThrowsError(try ShareCrypto.open(Data("SSL2".utf8), linkKey: key, passphrase: "correct horse"))
    }

    func testOldNewerAndOutOfRangeFormatsAreRefused() throws {
        var old = unhex(Self.vector)
        old.replaceSubrange(0..<4, with: Data("SSL1".utf8))
        XCTAssertThrowsError(try ShareCrypto.open(old, linkKey: key, passphrase: "correct horse")) { XCTAssertEqual($0 as? ShareError, .unsupported(1)) }
        var future = vectorEnvelope
        future.v = 3
        let blob = try ShareCrypto.seal(future, linkKey: key, passphrase: "pass word", iterations: 100_000)
        XCTAssertThrowsError(try ShareCrypto.open(blob, linkKey: key, passphrase: "pass word")) { XCTAssertEqual($0 as? ShareError, .unsupported(3)) }
        XCTAssertThrowsError(try ShareCrypto.seal(vectorEnvelope, linkKey: key, passphrase: "x", iterations: 1000))
        var bad = unhex(Self.vector)
        bad.replaceSubrange(4..<8, with: [0, 0, 0, 5])
        XCTAssertThrowsError(try ShareCrypto.open(bad, linkKey: key, passphrase: "correct horse")) { XCTAssertEqual($0 as? ShareError, .damaged("iterations")) }
        bad.replaceSubrange(4..<8, with: [0xFF, 0xFF, 0xFF, 0xFF])   // would hang the app
        XCTAssertThrowsError(try ShareCrypto.open(bad, linkKey: key, passphrase: "correct horse"))
    }

    // MARK: Link text

    func testLinkRoundTripAndForms() {
        let link = SharedLink(fileID: "1AbC_dEf-GhIjKlMnOp", key: key)
        XCTAssertEqual(link.url, "https://bestonehxh.github.io/share/#v2.1AbC_dEf-GhIjKlMnOp.AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8")
        XCTAssertEqual(link.appURL, "sheepterm://share#v2.1AbC_dEf-GhIjKlMnOp.AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8")
        for text in [link.url, link.appURL, link.fragment, "  \(link.url)\n", "#" + link.fragment,
                     link.url.replacingOccurrences(of: "/share/#", with: "/share#"), "sheepterm://share/#" + link.fragment] {
            XCTAssertEqual(SharedLink.parse(text), link, text)
        }
    }

    func testLinkParserRefusesEverythingElse() {
        let good = "v2.1AbC_dEf-GhIjKlMnOp.AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8"
        let bad = [
            "", "hello", "http://bestonehxh.github.io/share/#" + good, "https://evil.example/share/#" + good,
            "https://bestonehxh.github.io.evil.example/share/#" + good, "https://bestonehxh.github.io/other/#" + good,
            "sheepterm://other#" + good, "v1.1AbC_dEf-GhIjKlMnOp.AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8", "v3.1AbC_dEf-GhIjKlMnOp.AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8",
            "v2.short.AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8",
            "v2.1AbC_dEf-GhIjKlMnOp.AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwd",           // 28-byte key
            "v2.1AbC_dEf-GhIjKlMnOp.AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8=",     // padded
            "v2.1AbC/dEf-GhIjKlMnOp.AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8",
            good + ".extra", "v2..AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8",
            String(repeating: "a", count: 500),
        ]
        for text in bad { XCTAssertNil(SharedLink.parse(text), text) }
    }

    // MARK: Recipients, lifetime, naming

    func testRecipients() throws {
        XCTAssertEqual(try ShareRecipients.parse(["Alice@Gmail.com, bob.smith+lab@gmail.com;alice@gmail.com\ncarol@example.co.th"]),
                       ["alice@gmail.com", "bob.smith+lab@gmail.com", "carol@example.co.th"])
        for bad in ["alice", "alice@", "@gmail.com", "a b@gmail.com", "a@gmail", "a@@gmail.com", "a@-x.com", "a@x..com",
                    ".a@x.com", "a..b@x.com", "a@x.c1", "anyone", "allUsers", "a@x.com/../b", String(repeating: "a", count: 70) + "@x.com"] {
            XCTAssertThrowsError(try ShareRecipients.parse([bad]), bad) {
                guard case ShareError.badRecipient = $0 else { return XCTFail("\(bad): \($0)") }
            }
        }
        XCTAssertThrowsError(try ShareRecipients.parse([])) { XCTAssertEqual($0 as? ShareError, .noRecipients) }
        XCTAssertThrowsError(try ShareRecipients.parse(["me@x.com"], excluding: "ME@x.com")) { XCTAssertEqual($0 as? ShareError, .ownAddress) }
        let many = (0..<21).map { "u\($0)@x.com" }
        XCTAssertThrowsError(try ShareRecipients.parse(many)) { XCTAssertEqual($0 as? ShareError, .tooManyRecipients) }
    }

    func testLifetimeExpiry() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertEqual(ShareLifetime.day.expiry(from: now), now.addingTimeInterval(86_400))
        XCTAssertEqual(ShareLifetime.week.expiry(from: now), now.addingTimeInterval(7 * 86_400))
        XCTAssertEqual(ShareLifetime.month.expiry(from: now), now.addingTimeInterval(30 * 86_400))
        XCTAssertNil(ShareLifetime.never.expiry(from: now))
        let record = ShareRecord(id: "x", groupName: "g", hostCount: 1, recipients: [], created: now,
                                 expires: now.addingTimeInterval(10), includesCredentials: false)
        XCTAssertFalse(record.isExpired(at: now.addingTimeInterval(9)))
        XCTAssertTrue(record.isExpired(at: now.addingTimeInterval(10)))
        var forever = record; forever.expires = nil
        XCTAssertFalse(forever.isExpired(at: now.addingTimeInterval(1e9)))
    }

    func testImportCollisionNaming() {
        XCTAssertEqual(ShareNaming.importName("Lab", taken: ["Core"]), "Lab")
        XCTAssertEqual(ShareNaming.importName("Lab", taken: ["Lab"]), "Lab (shared)")
        XCTAssertEqual(ShareNaming.importName("Lab", taken: ["Lab", "Lab (shared)"]), "Lab (shared 2)")
        XCTAssertEqual(ShareNaming.importName("Lab", taken: ["Lab", "Lab (shared)", "Lab (shared 2)"]), "Lab (shared 3)")
        XCTAssertEqual(ShareNaming.importName("  ", taken: []), "Shared group")
    }

    func testScrubRemovesCredentialReferencesAnywhere() throws {
        let doc = Data(#"{"group":{"id":"g","name":"n","hosts":[{"id":"h","credentialID":"C","agentForward":true,"jumpSpec":"x@y","jumpHostID":"J","name":"sw","port":22}]},"credentialID":"top"}"#.utf8)
        let clean = String(decoding: try ShareScrub.stripped(doc), as: UTF8.self)
        for word in ["credentialID", "agentForward", "jumpSpec", "jumpHostID"] { XCTAssertFalse(clean.contains(word), word) }
        XCTAssertTrue(clean.contains("\"name\":\"sw\""))
        XCTAssertTrue(clean.contains("\"port\":22"))
        XCTAssertThrowsError(try ShareScrub.stripped(Data("nope".utf8)))
    }

    // MARK: Service against an in-memory Drive

    private struct Lab {
        let store = MemoryShareBackend.SharedStore()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("share-test-\(UUID().uuidString)")
        let clock = Clock()
        final class Clock: @unchecked Sendable {
            private let lock = NSLock(); private var t = Date(timeIntervalSince1970: 1_800_000_000)
            var now: Date { lock.withLock { t } }
            func advance(_ s: TimeInterval) { lock.withLock { t = t.addingTimeInterval(s) } }
        }
        func service(_ user: String, secrets: SyncEngineTests.MemorySecrets = .init()) -> (ShareService, MemoryShareBackend) {
            let backend = MemoryShareBackend(user: user, store: store)
            let clock = self.clock
            return (ShareService(backend: backend, sender: user, records: ShareRecordStore(directory: dir.appendingPathComponent(user), secrets: secrets),
                                 now: { clock.now }), backend)
        }
        /// What a recipient's app does: public download, then open with the signed-in address.
        func receive(_ link: SharedLink, passphrase: String, account: String?, at date: Date? = nil) async throws -> ShareContent {
            let blob = try await ShareService.download(link, via: MemoryShareBackend(user: "", store: store))
            return try ShareService.open(blob: blob, link: link, passphrase: passphrase, account: account, now: date ?? clock.now)
        }
    }

    private let sampleCreds = ShareCredentials(entries: [.init(name: "core", username: "admin", password: "hunter2", hosts: ["22222222-2222-3333-4444-555555555555"])])

    private func request(creds: Bool = false, passphrase: String = "twelve chars!", to: [String] = ["b@gmail.com"],
                         lifetime: ShareLifetime = .week) -> ShareService.Request {
        ShareService.Request(
            groupDocument: Data(#"{"version":1,"sender":"x","group":{"id":"g","name":"Lab","hosts":[{"id":"h1","name":"sw1","credentialID":"LOCAL","address":"10.0.0.1"}]}}"#.utf8),
            groupName: "Lab", hostCount: 1, credentials: creds ? sampleCreds : nil, passphrase: passphrase, recipients: to, lifetime: lifetime)
    }

    func testSenderToRecipientEndToEnd() async throws {
        let lab = Lab()
        let (alice, aliceBackend) = lab.service("a@gmail.com")
        let (record, link) = try await alice.create(request(creds: true, to: ["B@Gmail.com", "d@gmail.com"]))
        XCTAssertEqual(record.recipients, ["b@gmail.com", "d@gmail.com"])
        XCTAssertTrue(record.includesCredentials)
        XCTAssertEqual(record.expires, lab.clock.now.addingTimeInterval(7 * 86_400))
        XCTAssertEqual(alice.records.link(for: record.id), link, "copy link again")
        // The only permission ever requested is "public": the backend has no per-user or domain call at all.
        let grants = await aliceBackend.publicGrants
        XCTAssertEqual(grants, [record.id])
        let content = try await lab.receive(SharedLink.parse(link.url)!, passphrase: "twelve chars!", account: "b@gmail.com")
        XCTAssertEqual(content.sender, "a@gmail.com")
        XCTAssertEqual(content.name, "Lab")
        XCTAssertEqual(content.hostCount, 1)
        XCTAssertEqual(content.credentials, sampleCreds)
        XCTAssertFalse(String(decoding: content.group, as: UTF8.self).contains("credentialID"), "credentialID never arrives")
        XCTAssertTrue(String(decoding: content.group, as: UTF8.self).contains("10.0.0.1"))
        // A second recipient, mixed-case address from the Google sign-in.
        _ = try await lab.receive(link, passphrase: "twelve chars!", account: "D@Gmail.com")
    }

    func testPassphraseIsRequiredForEveryShare() async throws {
        let (alice, backend) = Lab().service("a@gmail.com")
        for bad in ["", "short", "1234567"] {
            do { _ = try await alice.create(request(passphrase: bad)); XCTFail("accepted \(bad)") }
            catch { XCTAssertEqual(error as? ShareError, .passphraseTooShort) }
        }
        let count = await backend.store.count
        XCTAssertEqual(count, 0, "refused attempts upload nothing")
        _ = try await alice.create(request(passphrase: "12345678"))     // exactly 8 is enough, with or without credentials
    }

    func testWrongPassphraseWrongAccountAndSignedOut() async throws {
        let lab = Lab()
        let (alice, _) = lab.service("a@gmail.com")
        let (_, link) = try await alice.create(request(to: ["b@gmail.com"]))
        do { _ = try await lab.receive(link, passphrase: "wrong wrong", account: "b@gmail.com"); XCTFail() }
        catch { XCTAssertEqual(error as? ShareError, .wrongPassphrase) }
        // Right link + right passphrase, but another Google account: refused, with the plain words.
        do { _ = try await lab.receive(link, passphrase: "twelve chars!", account: "carol@gmail.com"); XCTFail("carol opened it") }
        catch {
            XCTAssertEqual(error as? ShareError, .notRecipient)
            XCTAssertEqual((error as? ShareError)?.errorDescription, "This link was shared with other people.")
        }
        do { _ = try await lab.receive(link, passphrase: "twelve chars!", account: nil); XCTFail() }
        catch { XCTAssertEqual(error as? ShareError, .notSignedIn) }
        do { _ = try await lab.receive(link, passphrase: "", account: "b@gmail.com"); XCTFail() }
        catch { XCTAssertEqual(error as? ShareError, .needsPassphrase) }
        // The recipient list is INSIDE the encryption: the stored file does not name anybody.
        let id = link.fileID
        let blob = lab.store.file(id)!.data
        XCTAssertNil(blob.range(of: Data("b@gmail.com".utf8)))
        XCTAssertNil(blob.range(of: Data("a@gmail.com".utf8)))
        XCTAssertEqual(ShareError.wrongPassphrase.errorDescription, "That passphrase doesn\u{2019}t open this link (or the link was changed).")
    }

    func testRevokeStopsFurtherImports() async throws {
        let lab = Lab()
        let (alice, _) = lab.service("a@gmail.com")
        let (record, link) = try await alice.create(request())
        _ = try await lab.receive(link, passphrase: "twelve chars!", account: "b@gmail.com")
        try await alice.revoke(record.id)
        XCTAssertTrue(alice.records.all().isEmpty)
        XCTAssertNil(alice.records.link(for: record.id))
        do { _ = try await lab.receive(link, passphrase: "twelve chars!", account: "b@gmail.com"); XCTFail("still readable") }
        catch { XCTAssertEqual(error as? ShareError, .revoked); XCTAssertEqual((error as? ShareError)?.errorDescription, "This link was revoked or has expired.") }
        try await alice.revoke(record.id)       // already gone: fine
    }

    func testAFileThatWasNeverMadePublicCannotBeFetched() async throws {
        let lab = Lab()
        let (alice, backend) = lab.service("a@gmail.com")
        await backend.setFailMakePublic()
        do { _ = try await alice.create(request()); XCTFail() } catch {}
        XCTAssertEqual(lab.store.count, 0, "a half-made share must not stay in Drive")
        XCTAssertTrue(alice.records.all().isEmpty)
        await backend.setFailNextUpload()
        do { _ = try await alice.create(request()); XCTFail() } catch {}
        XCTAssertTrue(alice.records.all().isEmpty)
    }

    func testExpiryIsEnforcedByTheReaderAndPurgedBySender() async throws {
        let lab = Lab()
        let (alice, _) = lab.service("a@gmail.com")
        let (day, dayLink) = try await alice.create(request(lifetime: .day))
        let (forever, foreverLink) = try await alice.create(request(lifetime: .never))
        XCTAssertNil(forever.expires)
        lab.clock.advance(86_400 - 1)
        _ = try await lab.receive(dayLink, passphrase: "twelve chars!", account: "b@gmail.com")
        let early = await alice.purgeExpired()
        XCTAssertTrue(early.isEmpty)
        lab.clock.advance(1)
        // The file is still there (the sender's app has not run yet): the READER refuses it.
        do { _ = try await lab.receive(dayLink, passphrase: "twelve chars!", account: "b@gmail.com"); XCTFail("expired link opened") }
        catch { XCTAssertEqual(error as? ShareError, .expired) }
        let purged = await alice.purgeExpired()
        XCTAssertEqual(purged, [day.id])
        XCTAssertEqual(alice.records.all().map(\.id), [forever.id])
        do { _ = try await lab.receive(dayLink, passphrase: "twelve chars!", account: "b@gmail.com"); XCTFail() }
        catch { XCTAssertEqual(error as? ShareError, .revoked) }
        _ = try await lab.receive(foreverLink, passphrase: "twelve chars!", account: "b@gmail.com")
    }

    func testAlteredFileAndForeignLinkKeyAreRefused() async throws {
        let lab = Lab()
        let (alice, _) = lab.service("a@gmail.com")
        let (record, link) = try await alice.create(request())
        let (_, other) = try await alice.create(request())
        do { _ = try await lab.receive(SharedLink(fileID: record.id, key: other.key), passphrase: "twelve chars!", account: "b@gmail.com"); XCTFail() } catch {}
        lab.store.modify(record.id) { $0.data[60] ^= 1 }
        do { _ = try await lab.receive(link, passphrase: "twelve chars!", account: "b@gmail.com"); XCTFail() }
        catch { XCTAssertEqual(error as? ShareError, .wrongPassphrase) }
    }

    func testRecordsSurviveARelaunchAndKeepNoKey() async throws {
        let lab = Lab()
        let secrets = SyncEngineTests.MemorySecrets()
        let (alice, _) = lab.service("a@gmail.com", secrets: secrets)
        let (record, link) = try await alice.create(request())
        let again = ShareRecordStore(directory: lab.dir.appendingPathComponent("a@gmail.com"), secrets: secrets)
        XCTAssertEqual(again.all(), [record])
        XCTAssertEqual(again.link(for: record.id), link)
        let raw = try String(contentsOf: lab.dir.appendingPathComponent("a@gmail.com/shares.json"), encoding: .utf8)
        XCTAssertFalse(raw.contains(SharedLink.base64URL(link.key)))
        try Data("garbage".utf8).write(to: lab.dir.appendingPathComponent("a@gmail.com/shares.json"))
        XCTAssertTrue(ShareRecordStore(directory: lab.dir.appendingPathComponent("a@gmail.com"), secrets: secrets).all().isEmpty)
        let names = try FileManager.default.contentsOfDirectory(atPath: lab.dir.appendingPathComponent("a@gmail.com").path)
        XCTAssertTrue(names.contains { $0.hasPrefix("shares.json.corrupt-") })
    }

    func testRecipientsAreValidatedBeforeAnythingIsUploaded() async throws {
        let (alice, backend) = Lab().service("a@gmail.com")
        for bad in ["anyone", "allUsers", "domain.com", "", "a@gmail.com"] {
            do { _ = try await alice.create(request(to: [bad])); XCTFail(bad) } catch {}
        }
        let count = await backend.store.count
        XCTAssertEqual(count, 0)
    }
}
