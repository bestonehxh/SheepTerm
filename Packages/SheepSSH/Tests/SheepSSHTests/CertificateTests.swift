import XCTest
@testable import SheepSSH

/// User certificates made by OpenSSH's own ssh-keygen -s, read back and
/// offered (6.1). The live login is in the app's `workers` run.
final class CertificateTests: XCTestCase {
    private func keygen(_ args: [String]) throws {
        guard let keygen = LiveSSHD.keygen else { throw XCTSkip("ssh-keygen not found") }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: keygen)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0, args.joined(separator: " "))
    }

    func testSSHKeygenCertificatesReadAndSign() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sheepssh-cert-\(getpid())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let ca = dir.appendingPathComponent("ca").path
        try keygen(["-q", "-t", "ed25519", "-N", "", "-f", ca])
        for (name, args, base) in [("ed", ["-t", "ed25519"], "ssh-ed25519"),
                                   ("ec", ["-t", "ecdsa", "-b", "256"], "ecdsa-sha2-nistp256"),
                                   ("rsa", ["-t", "rsa", "-b", "2048"], "ssh-rsa")] {
            let path = dir.appendingPathComponent(name).path
            try keygen(["-q", "-N", "", "-f", path] + args)
            try keygen(["-q", "-s", ca, "-I", "sheep-\(name)", "-n", "netadmin,ops", "-V", "+52w", "-z", "42", path + ".pub"])
            let line = try String(contentsOfFile: path + "-cert.pub", encoding: .utf8)
            let cert = try SSHPublicKey(certificateLine: line)
            XCTAssertEqual(cert.keyType, base + SSHCertificate.suffix, name)
            let info = try XCTUnwrap(cert.certificate)
            XCTAssertEqual(info.keyID, "sheep-\(name)")
            XCTAssertEqual(info.principals, ["netadmin", "ops"])
            XCTAssertEqual(info.serial, 42)
            XCTAssertTrue(info.isUserCertificate)
            XCTAssertTrue(info.isValid(at: Date()))
            XCTAssertFalse(info.isValid(at: Date(timeIntervalSinceNow: 60 * 60 * 24 * 400)))
            let caPub = try SSHPublicKey(openSSHLine: try String(contentsOfFile: ca + ".pub", encoding: .utf8))
            XCTAssertEqual(info.signatureKey.blob, caPub.blob)
            let bare = try SSHPublicKey(openSSHLine: try String(contentsOfFile: path + ".pub", encoding: .utf8))
            XCTAssertEqual(info.plainBlob, bare.blob, name)
            XCTAssertTrue(cert.sameKey(as: bare))
            // Host keys / known_hosts still refuse certificates.
            XCTAssertThrowsError(try SSHPublicKey(openSSHLine: line))

            let key = try PEMPrivateKey.load(try String(contentsOfFile: path, encoding: .utf8), passphrase: nil)
            let signer = try CertificateSigner(certificate: cert, signer: PrivateKeySigner(key, label: name), label: name)
            let algorithm = try XCTUnwrap(publicKeyAlgorithm(for: signer.publicKey, accepted: HostKeyAlgorithm.allCases,
                                                             serverSignatureAlgorithms: ["rsa-sha2-512", "rsa-sha2-256"]))
            XCTAssertEqual(algorithm, (base == "ssh-rsa" ? "rsa-sha2-512" : base) + SSHCertificate.suffix)
            // The signature inside names the bare algorithm.
            var r = SSHReader(try signer.sign([1, 2, 3], algorithm: algorithm))
            XCTAssertEqual(try r.readUTF8(), SSHCertificate.baseAlgorithm(of: algorithm))
        }
        // A certificate for another key is refused up front.
        let ed = try SSHPublicKey(certificateLine: try String(contentsOfFile: dir.appendingPathComponent("ed-cert.pub").path, encoding: .utf8))
        let other = try PEMPrivateKey.load(try String(contentsOfFile: dir.appendingPathComponent("ec").path, encoding: .utf8), passphrase: nil)
        XCTAssertThrowsError(try CertificateSigner(certificate: ed, signer: PrivateKeySigner(other, label: "ec"), label: "x"))
    }

    func testTruncatedOrBareCertificateIsRefused() {
        XCTAssertThrowsError(try SSHPublicKey(certificateBlob: Array("junk".utf8)))
        var w = SSHWriter()
        w.writeString("ssh-ed25519-cert-v01@openssh.com")
        w.writeString([UInt8](repeating: 0, count: 32))
        XCTAssertThrowsError(try SSHPublicKey(certificateBlob: w.bytes))
        XCTAssertNil(SSHCertificate.baseKeyType(of: "ssh-dss-cert-v01@openssh.com"))
        XCTAssertEqual(SSHCertificate.baseAlgorithm(of: "ssh-ed25519"), "ssh-ed25519")
    }
}
