import XCTest
@testable import SheepSSH

final class KnownHostsTests: XCTestCase {
    func key(_ name: String) throws -> SSHPublicKey {
        try SSHPublicKey(openSSHLine: Vectors.keyFiles.first { $0.name == name }!.publicLine)
    }

    func testHashedEntriesFromSSHKeygen() throws {
        let kh = KnownHosts(text: Vectors.hashedKnownHosts)
        XCTAssertEqual(kh.entries.count, 3)
        XCTAssertEqual(kh.skippedLines, 0)
        XCTAssertTrue(kh.entries.allSatisfy { $0.hostField.hasPrefix("|1|") })
        XCTAssertEqual(kh.lookup(host: "switch-a.lab", port: 22, key: try key("ed25519")), .ok(line: 1))
        XCTAssertEqual(kh.lookup(host: "SWITCH-A.lab", port: 22, key: try key("ed25519")), .ok(line: 1), "case-folded")
        XCTAssertEqual(kh.lookup(host: "10.0.0.9", port: 2222, key: try key("ecdsa256")), .ok(line: 2))
        XCTAssertEqual(kh.lookup(host: "10.0.0.9", port: 22, key: try key("ecdsa256")), .notFound, "port is part of the name")
        XCTAssertEqual(kh.lookup(host: "core-sw", port: 22, key: try key("rsa2048")), .ok(line: 3))
    }

    func testChangedOtherTypeAndNotFound() throws {
        let ed = try key("ed25519"), ed2 = try key("ed25519-aes256ctr"), rsa = try key("rsa2048")
        let kh = KnownHosts(text: "sw1 \(ed.keyType) \(ed.base64)\n")
        XCTAssertEqual(kh.lookup(host: "sw1", port: 22, key: ed2), .changed(lines: [1]))
        XCTAssertEqual(kh.lookup(host: "sw1", port: 22, key: rsa), .otherType(knownTypes: ["ssh-ed25519"], lines: [1]))
        XCTAssertEqual(kh.lookup(host: "sw2", port: 22, key: ed), .notFound)
    }

    func testAnyMatchingLineWins() throws {
        let ed = try key("ed25519"), ed2 = try key("ed25519-aes256ctr")
        let kh = KnownHosts(text: "sw1 \(ed2.keyType) \(ed2.base64)\nsw1 \(ed.keyType) \(ed.base64)\n")
        XCTAssertEqual(kh.lookup(host: "sw1", port: 22, key: ed), .ok(line: 2))
    }

    func testPatternsNegationAndMarkers() throws {
        let ed = try key("ed25519"), rsa = try key("rsa2048")
        let text = """
            # comment

            *.lab,!evil.lab \(ed.keyType) \(ed.base64)
            sw?,[10.1.*]:830 \(rsa.keyType) \(rsa.base64) a comment
            @revoked * \(rsa.keyType) \(rsa.base64)
            @cert-authority *.corp \(ed.keyType) \(ed.base64)
            @bogus x \(ed.keyType) \(ed.base64)
            broken-line-without-key
            h ssh-ed25519 AAAA
            """
        let kh = KnownHosts(text: text)
        XCTAssertEqual(kh.entries.count, 4)
        XCTAssertEqual(kh.skippedLines, 3)
        XCTAssertEqual(kh.lookup(host: "a.lab", port: 22, key: ed), .ok(line: 3))
        XCTAssertEqual(kh.lookup(host: "evil.lab", port: 22, key: ed), .notFound, "negation vetoes")
        XCTAssertEqual(kh.lookup(host: "x.corp", port: 22, key: ed), .notFound, "CA lines are not host keys")
        XCTAssertEqual(kh.lookup(host: "sw1", port: 22, key: rsa), .revoked(line: 5), "revocation beats a match")
        XCTAssertEqual(kh.lookup(host: "10.1.2.3", port: 830, key: ed), .otherType(knownTypes: ["ssh-rsa"], lines: [4]),
                       "bracketed port pattern matches; the revoked line is not a pinned type")
        XCTAssertEqual(kh.lookup(host: "10.1.2.3", port: 22, key: ed), .notFound)
    }

    func testWindowsLineEndings() throws {
        let ed = try key("ed25519"), rsa = try key("rsa2048"), ed2 = try key("ed25519-aes256ctr")
        let text = "sw1 \(ed.keyType) \(ed.base64)\r\nsw2 \(rsa.keyType) \(rsa.base64)\r\n"
        let kh = KnownHosts(text: text)
        XCTAssertEqual(kh.entries.count, 2)
        XCTAssertEqual(kh.lookup(host: "sw1", port: 22, key: ed), .ok(line: 1))
        XCTAssertEqual(kh.lookup(host: "sw2", port: 22, key: rsa), .ok(line: 2))
        XCTAssertEqual(kh.lookup(host: "sw1", port: 22, key: ed2), .changed(lines: [1]), "a CRLF file must still pin")
    }

    func testPinnedKeyTypes() throws {
        let ed = try key("ed25519"), rsa = try key("rsa2048"), ec = try key("ecdsa256")
        let kh = KnownHosts(text: "sw1 \(rsa.keyType) \(rsa.base64)\nsw1 \(ec.keyType) \(ec.base64)\n"
            + "sw1 \(rsa.keyType) \(rsa.base64)\n@revoked sw1 \(ed.keyType) \(ed.base64)\n")
        XCTAssertEqual(kh.pinnedKeyTypes(host: "sw1", port: 22), ["ssh-rsa", "ecdsa-sha2-nistp256"])
        XCTAssertEqual(kh.pinnedKeyTypes(host: "sw2", port: 22), [])
    }

    func testWildcardMatcher() {
        let yes = [("*", ""), ("*", "abc"), ("a*c", "abbbc"), ("a*c", "ac"), ("?b", "ab"), ("*.lab", "x.y.lab"),
                   ("a*b*c", "a-b-b-c"), ("[10.0.0.*]:22*", "[10.0.0.1]:2222")]
        let no = [("a*c", "ab"), ("?", ""), ("abc", "abcd"), ("*.lab", "lab"), ("a?c", "ac")]
        for (p, t) in yes { XCTAssertTrue(KnownHosts.wildcardMatch(p, t), "\(p) ~ \(t)") }
        for (p, t) in no { XCTAssertFalse(KnownHosts.wildcardMatch(p, t), "\(p) !~ \(t)") }
    }

    func testAppendLineRoundTrips() throws {
        let ed = try key("ed25519")
        let line = KnownHosts.line(host: "Core-SW", port: 2200, key: ed)
        XCTAssertTrue(line.hasPrefix("[core-sw]:2200 ssh-ed25519 "))
        XCTAssertTrue(line.hasSuffix("\n"))
        XCTAssertEqual(KnownHosts(text: line).lookup(host: "core-sw", port: 2200, key: ed), .ok(line: 1))
    }
}
