@testable import SheepSSH

func hex(_ s: String) -> [UInt8] {
    var out: [UInt8] = []
    var chars = Array(s.unicodeScalars.filter { $0 != " " && $0 != "\n" })
    if chars.count % 2 == 1 { chars.insert("0", at: 0) }
    var i = 0
    while i < chars.count {
        out.append(chars[i].hexNibble! << 4 | chars[i + 1].hexNibble!)
        i += 2
    }
    return out
}

func hex(_ b: [UInt8]) -> String {
    b.map { ($0 < 16 ? "0" : "") + String($0, radix: 16) }.joined()
}

func big(_ s: String) -> BigUInt { BigUInt(hex: s)! }
