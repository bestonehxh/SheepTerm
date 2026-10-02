import XCTest
@testable import SheepSSH

final class WireTests: XCTestCase {
    /// RFC 4251 §5 mpint examples (the non-negative ones).
    func testMPIntRFCExamples() throws {
        let cases: [(String, String)] = [
            ("", "00000000"),
            ("09a378f9b2e332a7", "0000000809a378f9b2e332a7"),
            ("80", "000000020080"),
        ]
        for (value, wire) in cases {
            var w = SSHWriter()
            w.writeMPInt(big(value.isEmpty ? "0" : value))
            XCTAssertEqual(hex(w.bytes), wire)
            var r = SSHReader(hex(wire))
            XCTAssertEqual(try r.readMPInt(), big(value.isEmpty ? "0" : value))
            XCTAssertTrue(r.isAtEnd)
        }
    }

    func testMPIntRejectsNegativeButTrimsPadding() throws {
        var r = SSHReader(hex("00000002edcc"))           // -1234
        XCTAssertThrowsError(try r.readMPInt()) { XCTAssertEqual($0 as? SSHWireError, .negativeMPInt) }
        // Redundant leading zeros are accepted and trimmed, like OpenSSH.
        r = SSHReader(hex("000000020001"))
        XCTAssertEqual(try r.readMPInt(), BigUInt(1))
        r = SSHReader(hex("0000000100"))                 // zero written as 00
        XCTAssertEqual(try r.readMPIntBytes(), [])
        r = SSHReader(hex("00000004000000ff"))           // padded to a fixed width
        XCTAssertEqual(try r.readMPIntBytes(), [0xff])
    }

    func testReadTextIsLenient() throws {
        var r = SSHReader(hex("00000003a92032"))          // Latin-1 "© 2"
        XCTAssertEqual(try r.readText(), "\u{FFFD} 2")
    }

    func testMPIntFromPaddedMagnitude() {
        var w = SSHWriter()
        w.writeMPInt(unsigned: [0, 0, 0x7f, 1])
        w.writeMPInt(unsigned: [0, 0, 0])
        XCTAssertEqual(hex(w.bytes), "000000027f01" + "00000000")
    }

    func testIntegersStringsAndBooleans() throws {
        var w = SSHWriter()
        w.writeByte(7)
        w.writeBool(true)
        w.writeUInt32(0xDEAD_BEEF)
        w.writeUInt64(0x0102_0304_0506_0708)
        w.writeString("testing")
        w.writeString([UInt8]())
        w.writeNameList(["zlib", "none"])
        w.writeNameList([])
        XCTAssertEqual(hex(w.bytes),
                       "07" + "01" + "deadbeef" + "0102030405060708" + "0000000774657374696e67"
                       + "00000000" + "000000097a6c69622c6e6f6e65" + "00000000")
        var r = SSHReader(w.bytes)
        XCTAssertEqual(try r.readByte(), 7)
        XCTAssertEqual(try r.readBool(), true)
        XCTAssertEqual(try r.readUInt32(), 0xDEAD_BEEF)
        XCTAssertEqual(try r.readUInt64(), 0x0102_0304_0506_0708)
        XCTAssertEqual(try r.readUTF8(), "testing")
        XCTAssertEqual(try r.readString(), [])
        XCTAssertEqual(try r.readNameList(), ["zlib", "none"])
        XCTAssertEqual(try r.readNameList(), [])
        XCTAssertTrue(r.isAtEnd)
    }

    func testTruncationIsCaughtEverywhere() {
        var r = SSHReader(hex("000000ff41"))            // claims 255 bytes, has 1
        XCTAssertThrowsError(try r.readString()) { XCTAssertEqual($0 as? SSHWireError, .truncated) }
        r = SSHReader(hex("ffffffff"))                  // 4 GiB claim
        XCTAssertThrowsError(try r.readString())
        r = SSHReader(hex("0102"))
        XCTAssertThrowsError(try r.readUInt32())
        XCTAssertEqual(r.offset, 0, "a failed read must not move the cursor")
        r = SSHReader([])
        XCTAssertThrowsError(try r.readByte())
    }

    func testNameListIsLenientLikeOpenSSH() {
        // Embedded servers send trailing/doubled commas and stray spaces;
        // refusing them made every connect to such a device fail.
        for (raw, expected) in [("a,,b", ["a", "b"]), (",a", ["a"]), ("a,", ["a"]), ("a, b", ["a", "b"]), (",", [])] {
            var w = SSHWriter()
            w.writeString(raw)
            var r = SSHReader(w.bytes)
            XCTAssertEqual(try r.readNameList(), expected, raw)
        }
    }

    func testInvalidUTF8() {
        var r = SSHReader(hex("00000002c328"))
        XCTAssertThrowsError(try r.readUTF8()) { XCTAssertEqual($0 as? SSHWireError, .invalidUTF8) }
    }
}
