// SheepVT — byte-at-a-time UTF-8 decoder.
//
// Sits in front of the escape-sequence state machine and is used **only in
// ground state** (Ghostty/xterm.js rule): inside an escape sequence the bytes
// are raw and must not be reinterpreted.
//
// The decoder is a small DFA in the shape used by vte and Ghostty: the lead
// byte fixes how many continuation bytes follow *and* the legal range of the
// first of them, so overlong forms (0xC0/0xC1 leads, 0xE0 0x80…0x9F,
// 0xF0 0x80…0x8F), surrogates (0xED 0xA0…0xBF) and code points above
// U+10FFFF (0xF4 0x90… and leads 0xF5…0xFF) are all rejected at the byte that
// makes them impossible — never after silently accumulating them.
//
// Error handling follows the WHATWG "maximal subpart" rule, which is what
// every modern terminal does: the truncated sequence becomes one U+FFFD and
// the byte that broke it is **re-examined** as the start of a new sequence, so
// `<lead> A` prints U+FFFD followed by "A" instead of eating the "A".
// Because `decode` returns at most one scalar per call, that re-examination is
// signalled to the caller with `needsRetry` (see below).

public struct UTF8Decoder {
    /// Continuation bytes still expected for the sequence in progress (0…3).
    private var remaining: UInt8 = 0
    /// Code point accumulated so far.
    private var scalar: UInt32 = 0
    /// Legal range of the *next* continuation byte (narrowed after a lead byte
    /// that only allows part of 0x80…0xBF).
    private var lo: UInt8 = 0x80
    private var hi: UInt8 = 0xBF

    /// Set by `decode` when the byte it was just given was rejected as a
    /// continuation byte: the pending sequence was flushed as U+FFFD and the
    /// *same byte* must be handed to the decoder again (or handled by the
    /// caller as a fresh byte — an ASCII byte after a truncated sequence is
    /// still an ASCII byte). Never set twice in a row for the same byte:
    /// after a retry no sequence is pending, so the retry always completes.
    public private(set) var needsRetry = false

    public init() {}

    /// True while a multi-byte sequence is incomplete.
    public var isPending: Bool { remaining != 0 }

    /// Feed one byte. Returns a completed scalar (or U+FFFD for invalid
    /// input), or nil while a sequence is in progress.
    public mutating func decode(_ byte: UInt8) -> UInt32? {
        needsRetry = false
        if remaining == 0 {
            // Lead byte.
            if byte < 0x80 { return UInt32(byte) }
            if byte >= 0xC2 && byte <= 0xDF {           // 2-byte, U+0080…U+07FF
                remaining = 1; scalar = UInt32(byte & 0x1F); lo = 0x80; hi = 0xBF
                return nil
            }
            if byte >= 0xE0 && byte <= 0xEF {           // 3-byte, U+0800…U+FFFF
                remaining = 2; scalar = UInt32(byte & 0x0F)
                lo = (byte == 0xE0) ? 0xA0 : 0x80       // reject overlong
                hi = (byte == 0xED) ? 0x9F : 0xBF       // reject surrogates
                return nil
            }
            if byte >= 0xF0 && byte <= 0xF4 {           // 4-byte, U+10000…U+10FFFF
                remaining = 3; scalar = UInt32(byte & 0x07)
                lo = (byte == 0xF0) ? 0x90 : 0x80       // reject overlong
                hi = (byte == 0xF4) ? 0x8F : 0xBF       // reject > U+10FFFF
                return nil
            }
            // 0x80…0xC1 (continuation byte out of place, or an overlong lead)
            // and 0xF5…0xFF (beyond Unicode): invalid, and consumed.
            return 0xFFFD
        }
        // Continuation byte.
        if byte < lo || byte > hi {
            remaining = 0
            needsRetry = true
            return 0xFFFD
        }
        scalar = (scalar << 6) | UInt32(byte & 0x3F)
        remaining &-= 1
        lo = 0x80; hi = 0xBF
        return remaining == 0 ? scalar : nil
    }

    /// Discard a partial sequence (ESC interrupting a sequence, or the end of a
    /// stream): the partial becomes U+FFFD. Returns nil when nothing was pending.
    public mutating func flush() -> UInt32? {
        needsRetry = false
        guard remaining != 0 else { return nil }
        remaining = 0
        return 0xFFFD
    }
}
