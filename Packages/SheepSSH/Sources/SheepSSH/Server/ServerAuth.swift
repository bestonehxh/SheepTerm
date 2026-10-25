// The File Server's password check. `constantTimeEqual` (Crypto/Poly1305)
// returns early when the lengths differ — fine for MAC tags of a fixed size,
// a leak for a password: the time would tell an attacker the real length.
// Here both sides are first reduced to SHA-256 digests (32 bytes whatever
// was typed), then compared without an early exit.
import Foundation

public enum ServerAuth {
    public static func secretsEqual(_ offered: String, _ expected: String) -> Bool {
        let a = SSHHash.sha256.hash(Array(offered.utf8))
        let b = SSHHash.sha256.hash(Array(expected.utf8))
        return constantTimeEqual(a, b)
    }
}
