// SheepVT — the contract between the byte-level parser and whoever gives the
// bytes meaning (Terminal in production, a recording actor in tests).
// Mirrors vte's `Perform` trait: the parser knows syntax, the actor knows
// semantics. Every method has a default no-op so partial actors are cheap.

/// CSI parameters as parsed: a flat list of values with a parallel flag that
/// marks colon-separated sub-parameters (`38:2:r:g:b`). Missing values are
/// stored as -1 so a handler can apply its own default ("ZDM" is the
/// handler's job, not the parser's).
public struct CSIParams: Sendable {
    public static let maxParams = 32
    public static let maxValue = 0x7FFF_FFFF

    /// Raw values in order, including sub-parameters. -1 = omitted.
    public private(set) var values: [Int32] = []
    /// `isSub[i]` is true when values[i] was introduced by ':' rather than ';'.
    public private(set) var isSub: [Bool] = []
    /// Set when more than `maxParams` parameters arrived; the sequence should be ignored.
    public private(set) var overflowed = false

    public init() { values.reserveCapacity(8); isSub.reserveCapacity(8) }

    public mutating func reset() { values.removeAll(keepingCapacity: true); isSub.removeAll(keepingCapacity: true); overflowed = false }

    /// Start a new (top-level or sub) parameter with no digits yet.
    public mutating func addParam(sub: Bool) {
        if values.count >= CSIParams.maxParams { overflowed = true; return }
        values.append(-1); isSub.append(sub)
    }
    /// Append a decimal digit to the current parameter (starting one if needed).
    public mutating func addDigit(_ d: Int32) {
        if values.isEmpty { addParam(sub: false) }
        if overflowed { return }
        let i = values.count - 1
        let cur = values[i] < 0 ? 0 : values[i]
        let next = cur &* 10 &+ d
        values[i] = (cur > 214_748_363 || next < 0) ? Int32(CSIParams.maxValue) : next
    }

    /// Number of top-level parameters (sub-parameters excluded).
    public var count: Int { var n = 0; for s in isSub where !s { n += 1 }; return n }

    /// Top-level parameter `i` (0-based, sub-parameters skipped) or `def` when
    /// absent or omitted. Zero is returned as-is; callers that need "0 means 1"
    /// use `param(i, default:1, min:1)`.
    public func param(_ i: Int, default def: Int = 0, min: Int = 0) -> Int {
        var n = 0
        for j in values.indices where !isSub[j] {
            if n == i { let v = values[j]; return v < 0 ? def : Swift.max(Int(v), min) }
            n += 1
        }
        return def
    }

    /// Index into `values` of top-level parameter `i`, or nil.
    public func index(ofParam i: Int) -> Int? {
        var n = 0
        for j in values.indices where !isSub[j] { if n == i { return j }; n += 1 }
        return nil
    }

    /// Sub-parameters that follow `values[index]` (until the next top-level param).
    public func subParams(after index: Int) -> ArraySlice<Int32> {
        var end = index + 1
        while end < values.count, isSub[end] { end += 1 }
        return values[(index + 1)..<end]
    }
}

/// The parser's view of the world. All methods are called on the thread that
/// calls `VTParser.feed`.
public protocol VTActor: AnyObject {
    /// A printable code point in ground state (already UTF-8 decoded; never a
    /// C0/C1 control). The parser calls this once per code point; runs of
    /// ASCII are delivered through `printRun` when the actor implements it.
    func print(_ codePoint: UInt32)
    /// A run of printable ASCII (0x20…0x7E) — a fast path the actor may use
    /// to avoid per-character overhead. Default implementation loops `print`.
    func printRun(_ bytes: UnsafeBufferPointer<UInt8>)
    /// A C0 control (0x00…0x1F, 0x7F never delivered). Also called for CAN/SUB
    /// when they abort a sequence.
    func execute(_ control: UInt8)
    /// CSI final byte with parameters. `intermediates` are the collected
    /// 0x20–0x2F bytes and `prefix` the 0x3C–0x3F private marker (0 if none).
    func csiDispatch(prefix: UInt8, intermediates: ArraySlice<UInt8>, final: UInt8, params: CSIParams)
    /// ESC sequence: intermediates (0x20–0x2F) and the final byte.
    func escDispatch(intermediates: ArraySlice<UInt8>, final: UInt8)
    /// Complete OSC payload (bytes after `ESC ]`, terminator removed).
    /// `bellTerminated` tells whether BEL or ST ended it.
    func oscDispatch(_ payload: ArraySlice<UInt8>, bellTerminated: Bool)
    /// DCS start with the same header shape as CSI; followed by `dcsPut`
    /// bytes and one `dcsUnhook`.
    func dcsHook(prefix: UInt8, intermediates: ArraySlice<UInt8>, final: UInt8, params: CSIParams)
    func dcsPut(_ bytes: ArraySlice<UInt8>)
    func dcsUnhook()
    /// APC / PM / SOS payload (bytes between the introducer and the terminator).
    func apcDispatch(_ payload: ArraySlice<UInt8>)
}

public extension VTActor {
    func printRun(_ bytes: UnsafeBufferPointer<UInt8>) { for b in bytes { print(UInt32(b)) } }
    func execute(_ control: UInt8) {}
    func csiDispatch(prefix: UInt8, intermediates: ArraySlice<UInt8>, final: UInt8, params: CSIParams) {}
    func escDispatch(intermediates: ArraySlice<UInt8>, final: UInt8) {}
    func oscDispatch(_ payload: ArraySlice<UInt8>, bellTerminated: Bool) {}
    func dcsHook(prefix: UInt8, intermediates: ArraySlice<UInt8>, final: UInt8, params: CSIParams) {}
    func dcsPut(_ bytes: ArraySlice<UInt8>) {}
    func dcsUnhook() {}
    func apcDispatch(_ payload: ArraySlice<UInt8>) {}
}
