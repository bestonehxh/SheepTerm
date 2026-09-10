// SheepVT — parser unit tests (agent A).
//
// Everything here goes through the public API only: bytes in, `VTActor` calls
// out. `RecordingActor` normalises the two places where the parser is free to
// choose a chunking (`printRun` and `dcsPut`) so that "same bytes, different
// feed chunking" must produce byte-identical event lists.

import Testing
import SheepVT

// MARK: - recording actor

final class RecordingActor: VTActor {
    enum Event: Equatable, CustomStringConvertible {
        case print(UInt32)
        case execute(UInt8)
        case csi(prefix: UInt8, intermediates: [UInt8], final: UInt8, values: [Int32], subs: [Bool])
        case esc(intermediates: [UInt8], final: UInt8)
        case osc(payload: [UInt8], bell: Bool)
        case dcsHook(prefix: UInt8, intermediates: [UInt8], final: UInt8, values: [Int32])
        case dcsPut([UInt8])
        case dcsUnhook
        case apc([UInt8])

        var description: String {
            switch self {
            case .print(let c): return "print(U+\(String(c, radix: 16, uppercase: true)))"
            case .execute(let c): return "execute(0x\(String(c, radix: 16)))"
            case .csi(let p, let i, let f, let v, let s):
                return "csi(prefix: \(p), inter: \(i), final: \(Character(UnicodeScalar(f))), values: \(v), subs: \(s))"
            case .esc(let i, let f): return "esc(inter: \(i), final: \(Character(UnicodeScalar(f))))"
            case .osc(let p, let b): return "osc(\(String(decoding: p, as: UTF8.self)), bell: \(b))"
            case .dcsHook(let p, let i, let f, let v):
                return "dcsHook(prefix: \(p), inter: \(i), final: \(Character(UnicodeScalar(f))), values: \(v))"
            case .dcsPut(let b): return "dcsPut(\(String(decoding: b, as: UTF8.self)))"
            case .dcsUnhook: return "dcsUnhook"
            case .apc(let p): return "apc(\(String(decoding: p, as: UTF8.self)))"
            }
        }
    }

    private(set) var events: [Event] = []
    /// How many times the parser used the `printRun` fast path, and with what.
    private(set) var runs: [[UInt8]] = []

    func print(_ codePoint: UInt32) { events.append(.print(codePoint)) }

    // Normalised: a run is recorded as one `.print` per byte, so the event list
    // does not depend on how the input was chunked.
    func printRun(_ bytes: UnsafeBufferPointer<UInt8>) {
        runs.append(Array(bytes))
        for b in bytes { events.append(.print(UInt32(b))) }
    }

    func execute(_ control: UInt8) { events.append(.execute(control)) }

    func csiDispatch(prefix: UInt8, intermediates: ArraySlice<UInt8>, final: UInt8, params: CSIParams) {
        events.append(.csi(prefix: prefix, intermediates: Array(intermediates), final: final,
                           values: params.values, subs: params.isSub))
    }

    func escDispatch(intermediates: ArraySlice<UInt8>, final: UInt8) {
        events.append(.esc(intermediates: Array(intermediates), final: final))
    }

    func oscDispatch(_ payload: ArraySlice<UInt8>, bellTerminated: Bool) {
        events.append(.osc(payload: Array(payload), bell: bellTerminated))
    }

    func dcsHook(prefix: UInt8, intermediates: ArraySlice<UInt8>, final: UInt8, params: CSIParams) {
        events.append(.dcsHook(prefix: prefix, intermediates: Array(intermediates), final: final,
                               values: params.values))
    }

    // Normalised the same way as `printRun`: adjacent puts are merged.
    func dcsPut(_ bytes: ArraySlice<UInt8>) {
        if case .dcsPut(let previous) = events.last {
            events[events.count - 1] = .dcsPut(previous + Array(bytes))
        } else {
            events.append(.dcsPut(Array(bytes)))
        }
    }

    func dcsUnhook() { events.append(.dcsUnhook) }
    func apcDispatch(_ payload: ArraySlice<UInt8>) { events.append(.apc(Array(payload))) }
}

// MARK: - harness

private func bytes(_ s: String) -> [UInt8] { Array(s.utf8) }

/// Feed `input` and return the events. `chunk` = nil feeds it in one call.
@discardableResult
private func run(_ input: [UInt8], chunk: Int? = nil) -> [RecordingActor.Event] {
    let actor = RecordingActor()
    let parser = VTParser(actor: actor)
    if let chunk {
        var i = 0
        while i < input.count {
            let end = Swift.min(i + chunk, input.count)
            parser.feed(Array(input[i..<end]))
            i = end
        }
    } else {
        parser.feed(input)
    }
    return actor.events
}

private func run(_ input: String, chunk: Int? = nil) -> [RecordingActor.Event] {
    run(bytes(input), chunk: chunk)
}

/// Escape helpers so the sequences below read like the specs they come from.
private let ESC: UInt8 = 0x1B
private let BEL: UInt8 = 0x07
private let CAN: UInt8 = 0x18
private let SUB: UInt8 = 0x1A
private func seq(_ parts: Any...) -> [UInt8] {
    var out: [UInt8] = []
    for p in parts {
        switch p {
        case let b as UInt8: out.append(b)
        case let s as String: out.append(contentsOf: s.utf8)
        case let a as [UInt8]: out.append(contentsOf: a)
        default: fatalError("seq: unsupported \(type(of: p))")
        }
    }
    return out
}

// MARK: - UTF8Decoder

@Suite("UTF8Decoder")
struct UTF8DecoderTests {
    /// Decode a whole byte string, applying the re-examination rule.
    private func scalars(_ input: [UInt8]) -> [UInt32] {
        var d = UTF8Decoder()
        var out: [UInt32] = []
        for b in input {
            if let s = d.decode(b) { out.append(s) }
            if d.needsRetry, let s = d.decode(b) { out.append(s) }
        }
        if let s = d.flush() { out.append(s) }
        return out
    }

    @Test func ascii() {
        #expect(scalars(Array("Hi!".utf8)) == [0x48, 0x69, 0x21])
    }

    @Test func multiByte() {
        #expect(scalars(Array("é€𝄞".utf8)) == [0xE9, 0x20AC, 0x1D11E])
    }

    @Test func overlongRejected() {
        #expect(scalars([0xC0, 0xAF]) == [0xFFFD, 0xFFFD])          // 0xC0 is never a lead
        #expect(scalars([0xC1, 0xBF]) == [0xFFFD, 0xFFFD])
        #expect(scalars([0xE0, 0x80, 0xAF]) == [0xFFFD, 0xFFFD, 0xFFFD])
        #expect(scalars([0xF0, 0x82, 0x82, 0xAC]) == [0xFFFD, 0xFFFD, 0xFFFD, 0xFFFD])
    }

    @Test func surrogatesRejected() {
        // U+D800 encoded as ED A0 80.
        #expect(scalars([0xED, 0xA0, 0x80]) == [0xFFFD, 0xFFFD, 0xFFFD])
        // U+D7FF (ED 9F BF) is fine.
        #expect(scalars([0xED, 0x9F, 0xBF]) == [0xD7FF])
    }

    @Test func aboveMaxRejected() {
        #expect(scalars([0xF4, 0x90, 0x80, 0x80]) == [0xFFFD, 0xFFFD, 0xFFFD, 0xFFFD])
        #expect(scalars([0xF5, 0x80, 0x80, 0x80]) == [0xFFFD, 0xFFFD, 0xFFFD, 0xFFFD])
        #expect(scalars([0xF4, 0x8F, 0xBF, 0xBF]) == [0x10FFFF])     // exactly U+10FFFF
    }

    @Test func truncatedSequenceRetriesTheOffendingByte() {
        // "\u{20AC}" truncated then an ASCII 'A': the A must survive.
        #expect(scalars([0xE2, 0x82, 0x41]) == [0xFFFD, 0x41])
        var d = UTF8Decoder()
        _ = d.decode(0xE2)
        #expect(d.isPending)
        #expect(d.decode(0x41) == 0xFFFD)
        #expect(d.needsRetry)
        #expect(d.decode(0x41) == 0x41)
        #expect(!d.needsRetry)
        #expect(!d.isPending)
    }

    @Test func flushEmitsReplacement() {
        var d = UTF8Decoder()
        #expect(d.flush() == nil)
        _ = d.decode(0xF0)
        _ = d.decode(0x9F)
        #expect(d.isPending)
        #expect(d.flush() == 0xFFFD)
        #expect(!d.isPending)
        #expect(d.flush() == nil)
    }
}

// MARK: - transition table

@Suite("ParseTable")
struct ParseTableTests {
    @Test func shapeAndDefaults() {
        #expect(ParseTable.table.count == ParseTable.stateCount * ParseTable.byteCount)
        // Every entry decodes to a real action and a real state.
        for (index, entry) in ParseTable.table.enumerated() {
            #expect(ParseAction(rawValue: entry >> 8) != nil, "bad action at \(index)")
            #expect(VTParser.State(rawValue: UInt8(truncatingIfNeeded: entry)) != nil, "bad state at \(index)")
        }
    }

    /// CAN, SUB and ESC mean the same thing in every state.
    @Test func anywhereRules() {
        let all: [VTParser.State] = [
            .ground, .escape, .escapeIntermediate, .csiEntry, .csiParam, .csiIntermediate,
            .csiIgnore, .dcsEntry, .dcsParam, .dcsIntermediate, .dcsPassthrough, .dcsIgnore,
            .oscString, .sosPmApcString,
        ]
        for s in all {
            for c in [CAN, SUB] {
                #expect(ParseTable.next(of: ParseTable.entry(s, c)) == .ground, "\(s) \(c)")
            }
            let escEntry = ParseTable.entry(s, ESC)
            switch s {
            case .oscString:
                #expect(ParseTable.action(of: escEntry) == .oscEnd)
            case .sosPmApcString:
                #expect(ParseTable.action(of: escEntry) == .apcEnd)
            case .dcsPassthrough:
                #expect(ParseTable.action(of: escEntry) == .dcsUnhook)
            default:
                #expect(ParseTable.action(of: escEntry) == .clear)
                #expect(ParseTable.next(of: escEntry) == .escape)
            }
        }
    }

    /// One representative byte per class, per state.
    @Test func transitionsPerStateAndByteClass() {
        typealias S = VTParser.State
        // (state, byte, expected action, expected next state)
        let cases: [(S, UInt8, ParseAction, S)] = [
            // ground
            (.ground, 0x0A, .execute, .ground),
            (.ground, 0x41, .print, .ground),
            (.ground, 0x7F, .ignore, .ground),
            (.ground, 0xA0, .print, .ground),
            // escape
            (.escape, 0x0A, .execute, .escape),
            (.escape, 0x7F, .ignore, .escape),
            (.escape, 0x28, .collect, .escapeIntermediate),      // ESC ( — charset
            (.escape, 0x37, .escDispatch, .ground),              // ESC 7 — DECSC
            (.escape, 0x44, .escDispatch, .ground),              // ESC D — IND
            (.escape, 0x5C, .escDispatch, .ground),              // ESC \ — ST
            (.escape, 0x5B, .clear, .csiEntry),
            (.escape, 0x5D, .oscStart, .oscString),
            (.escape, 0x50, .clear, .dcsEntry),
            (.escape, 0x5F, .apcStart, .sosPmApcString),
            (.escape, 0x58, .apcStart, .sosPmApcString),
            (.escape, 0x5E, .apcStart, .sosPmApcString),
            (.escape, 0xA0, .error, .ground),
            // escape intermediate
            (.escapeIntermediate, 0x0A, .execute, .escapeIntermediate),
            (.escapeIntermediate, 0x20, .collect, .escapeIntermediate),
            (.escapeIntermediate, 0x42, .escDispatch, .ground),
            (.escapeIntermediate, 0x7F, .ignore, .escapeIntermediate),
            (.escapeIntermediate, 0xA0, .error, .ground),
            // csi entry
            (.csiEntry, 0x0A, .execute, .csiEntry),
            (.csiEntry, 0x7F, .ignore, .csiEntry),
            (.csiEntry, 0x20, .collect, .csiIntermediate),
            (.csiEntry, 0x31, .param, .csiParam),
            (.csiEntry, 0x3B, .param, .csiParam),
            (.csiEntry, 0x3A, .param, .csiParam),
            (.csiEntry, 0x3F, .collectPrefix, .csiParam),
            (.csiEntry, 0x6D, .csiDispatch, .ground),
            (.csiEntry, 0xA0, .error, .ground),
            // csi param
            (.csiParam, 0x0A, .execute, .csiParam),
            (.csiParam, 0x32, .param, .csiParam),
            (.csiParam, 0x3F, .ignore, .csiIgnore),
            (.csiParam, 0x24, .collect, .csiIntermediate),
            (.csiParam, 0x48, .csiDispatch, .ground),
            (.csiParam, 0x7F, .ignore, .csiParam),
            (.csiParam, 0xA0, .error, .ground),
            // csi intermediate
            (.csiIntermediate, 0x0A, .execute, .csiIntermediate),
            (.csiIntermediate, 0x21, .collect, .csiIntermediate),
            (.csiIntermediate, 0x33, .ignore, .csiIgnore),
            (.csiIntermediate, 0x70, .csiDispatch, .ground),
            (.csiIntermediate, 0xA0, .error, .ground),
            // csi ignore
            (.csiIgnore, 0x0A, .execute, .csiIgnore),
            (.csiIgnore, 0x20, .ignore, .csiIgnore),
            (.csiIgnore, 0x3F, .ignore, .csiIgnore),
            (.csiIgnore, 0x6D, .ignore, .ground),
            (.csiIgnore, 0x7F, .ignore, .csiIgnore),
            (.csiIgnore, 0xA0, .ignore, .csiIgnore),
            // dcs entry
            (.dcsEntry, 0x0A, .execute, .dcsEntry),
            (.dcsEntry, 0x7F, .ignore, .dcsEntry),
            (.dcsEntry, 0x24, .collect, .dcsIntermediate),
            (.dcsEntry, 0x31, .param, .dcsParam),
            (.dcsEntry, 0x3E, .collectPrefix, .dcsParam),
            (.dcsEntry, 0x71, .dcsHook, .dcsPassthrough),
            (.dcsEntry, 0xA0, .error, .ground),
            // dcs param
            (.dcsParam, 0x0A, .execute, .dcsParam),
            (.dcsParam, 0x31, .param, .dcsParam),
            (.dcsParam, 0x3C, .ignore, .dcsIgnore),
            (.dcsParam, 0x24, .collect, .dcsIntermediate),
            (.dcsParam, 0x71, .dcsHook, .dcsPassthrough),
            (.dcsParam, 0xA0, .error, .ground),
            // dcs intermediate
            (.dcsIntermediate, 0x0A, .execute, .dcsIntermediate),
            (.dcsIntermediate, 0x24, .collect, .dcsIntermediate),
            (.dcsIntermediate, 0x31, .ignore, .dcsIgnore),
            (.dcsIntermediate, 0x71, .dcsHook, .dcsPassthrough),
            (.dcsIntermediate, 0xA0, .error, .ground),
            // dcs passthrough
            (.dcsPassthrough, 0x0A, .dcsPut, .dcsPassthrough),
            (.dcsPassthrough, 0x41, .dcsPut, .dcsPassthrough),
            (.dcsPassthrough, 0xA0, .dcsPut, .dcsPassthrough),
            (.dcsPassthrough, 0x7F, .ignore, .dcsPassthrough),
            // dcs ignore
            (.dcsIgnore, 0x0A, .ignore, .dcsIgnore),
            (.dcsIgnore, 0x41, .ignore, .dcsIgnore),
            (.dcsIgnore, 0xA0, .ignore, .dcsIgnore),
            // osc
            (.oscString, 0x0A, .ignore, .oscString),
            (.oscString, 0x41, .oscPut, .oscString),
            (.oscString, 0xA0, .oscPut, .oscString),      // includes raw 0x9C — payload, not ST
            (.oscString, 0x7F, .ignore, .oscString),
            (.oscString, BEL, .oscEnd, .ground),
            // sos / pm / apc
            (.sosPmApcString, 0x0A, .ignore, .sosPmApcString),
            (.sosPmApcString, BEL, .ignore, .sosPmApcString),   // BEL does not end APC
            (.sosPmApcString, 0x41, .apcPut, .sosPmApcString),
            (.sosPmApcString, 0xA0, .apcPut, .sosPmApcString),
            (.sosPmApcString, 0x7F, .ignore, .sosPmApcString),
        ]
        for (state, byte, action, next) in cases {
            let entry = ParseTable.entry(state, byte)
            #expect(ParseTable.action(of: entry) == action, "\(state) byte 0x\(String(byte, radix: 16))")
            #expect(ParseTable.next(of: entry) == next, "\(state) byte 0x\(String(byte, radix: 16))")
        }
    }

    /// Every byte >= 0xA0 collapses onto the same rule.
    @Test func highBytesCollapse() {
        for state in [VTParser.State.ground, .oscString, .dcsPassthrough, .csiIgnore] {
            let reference = ParseTable.entry(state, 0xA0)
            for b in stride(from: 0xA0, through: 0xFF, by: 1) {
                #expect(ParseTable.entry(state, UInt8(b)) == reference)
            }
        }
    }
}

// MARK: - printing and controls

@Suite("VTParser printing")
struct ParserPrintTests {
    @Test func printableRunUsesPrintRun() {
        let actor = RecordingActor()
        let parser = VTParser(actor: actor)
        parser.feed("hi there")
        #expect(actor.runs == [Array("hi there".utf8)])
        #expect(actor.events.count == 8)
        #expect(parser.state == .ground)
    }

    /// printRun must be exactly equivalent to a print per code point.
    @Test func printRunMatchesPrint() {
        let text = "Hello, world! 123"
        let whole = run(text)
        let split = run(text, chunk: 1)
        #expect(whole == split)
        #expect(whole == text.unicodeScalars.map { RecordingActor.Event.print($0.value) })
    }

    @Test func runStopsAtDelAndControls() {
        let actor = RecordingActor()
        let parser = VTParser(actor: actor)
        parser.feed([0x41, 0x42, 0x7F, 0x43, 0x0A, 0x44])
        #expect(actor.runs == [[0x41, 0x42], [0x43], [0x44]])
        #expect(actor.events == [.print(0x41), .print(0x42), .print(0x43), .execute(0x0A), .print(0x44)])
    }

    @Test func c0ControlsExecute() {
        #expect(run([0x07, 0x08, 0x09, 0x0D, 0x00]) ==
                [.execute(0x07), .execute(0x08), .execute(0x09), .execute(0x0D), .execute(0x00)])
    }

    @Test func delIgnoredInGround() {
        #expect(run([0x7F]) == [])
    }

    @Test func utf8IsPrintedAsScalars() {
        #expect(run("aé€𝄞") == [.print(0x61), .print(0xE9), .print(0x20AC), .print(0x1D11E)])
    }

    @Test func utf8SplitAcrossFeeds() {
        let actor = RecordingActor()
        let parser = VTParser(actor: actor)
        parser.feed([0xE2, 0x82])
        #expect(actor.events.isEmpty)
        parser.feed([0xAC])
        #expect(actor.events == [.print(0x20AC)])
    }

    @Test func invalidBytesBecomeReplacement() {
        #expect(run([0xFF]) == [.print(0xFFFD)])
        #expect(run([0x80]) == [.print(0xFFFD)])          // raw C1 byte in ground
        #expect(run([0x9B]) == [.print(0xFFFD)])          // raw CSI byte is NOT a CSI
        #expect(run([0xE2, 0x41]) == [.print(0xFFFD), .print(0x41)])
        #expect(run([0xE2, 0x0D]) == [.print(0xFFFD), .execute(0x0D)])
    }

    @Test func c1ViaUTF8IsDropped() {
        // U+0080…U+009F encoded as C2 80 … C2 9F: dropped, never printed.
        for low in UInt8(0x80)...UInt8(0x9F) {
            #expect(run([0xC2, low]) == [], "C2 \(low)")
        }
        #expect(run([0xC2, 0xA0]) == [.print(0xA0)])      // NBSP still prints
    }

    @Test func escInterruptsPendingUTF8() {
        // ESC while a sequence is pending: U+FFFD, then the ESC sequence runs.
        #expect(run(seq([0xE2, 0x82] as [UInt8], ESC, "[1m")) ==
                [.print(0xFFFD), .csi(prefix: 0, intermediates: [], final: 0x6D, values: [1], subs: [false])])
    }
}

// MARK: - CSI

@Suite("VTParser CSI")
struct ParserCSITests {
    @Test func simpleDispatch() {
        #expect(run(seq(ESC, "[31m")) ==
                [.csi(prefix: 0, intermediates: [], final: 0x6D, values: [31], subs: [false])])
    }

    @Test func noParams() {
        #expect(run(seq(ESC, "[H")) ==
                [.csi(prefix: 0, intermediates: [], final: 0x48, values: [], subs: [])])
    }

    @Test func omittedLeadingParam() {
        #expect(run(seq(ESC, "[;5H")) ==
                [.csi(prefix: 0, intermediates: [], final: 0x48, values: [-1, 5], subs: [false, false])])
    }

    @Test func omittedTrailingParam() {
        #expect(run(seq(ESC, "[5;H")) ==
                [.csi(prefix: 0, intermediates: [], final: 0x48, values: [5, -1], subs: [false, false])])
    }

    @Test func subParametersAreKept() {
        #expect(run(seq(ESC, "[38:2::1:2:3m")) ==
                [.csi(prefix: 0, intermediates: [], final: 0x6D,
                      values: [38, 2, -1, 1, 2, 3],
                      subs: [false, true, true, true, true, true])])
    }

    @Test func mixedSubAndTopLevel() {
        #expect(run(seq(ESC, "[1:2;3m")) ==
                [.csi(prefix: 0, intermediates: [], final: 0x6D,
                      values: [1, 2, 3], subs: [false, true, false])])
    }

    @Test func prefixAndIntermediate() {
        #expect(run(seq(ESC, "[?1049h")) ==
                [.csi(prefix: 0x3F, intermediates: [], final: 0x68, values: [1049], subs: [false])])
        #expect(run(seq(ESC, "[ q")) ==
                [.csi(prefix: 0, intermediates: [0x20], final: 0x71, values: [], subs: [])])
        #expect(run(seq(ESC, "[?2026$p")) ==
                [.csi(prefix: 0x3F, intermediates: [0x24], final: 0x70, values: [2026], subs: [false])])
    }

    @Test func secondPrefixByteIgnoresTheSequence() {
        #expect(run(seq(ESC, "[?<1h", "A")) == [.print(0x41)])
    }

    @Test func thirdIntermediateSuppressesDispatch() {
        #expect(run(seq(ESC, "[!!!p", "A")) == [.print(0x41)])
        // Two intermediates still dispatch.
        #expect(run(seq(ESC, "[!!p")) ==
                [.csi(prefix: 0, intermediates: [0x21, 0x21], final: 0x70, values: [], subs: [])])
    }

    @Test func maxParamsAndOverflow() {
        let thirtyTwo = (1...32).map(String.init).joined(separator: ";")
        let ok = run(seq(ESC, "[", thirtyTwo, "m"))
        #expect(ok.count == 1)
        if case .csi(_, _, _, let values, _) = ok[0] {
            #expect(values.count == 32)
            #expect(values.first == 1 && values.last == 32)
        } else {
            Issue.record("expected a CSI dispatch, got \(ok)")
        }
        // 33 parameters: overflowed → nothing is dispatched, parser still recovers.
        let thirtyThree = (1...33).map(String.init).joined(separator: ";")
        #expect(run(seq(ESC, "[", thirtyThree, "m", "A")) == [.print(0x41)])
    }

    @Test func hugeParameterIsClamped() {
        let ok = run(seq(ESC, "[99999999999999m"))
        #expect(ok == [.csi(prefix: 0, intermediates: [], final: 0x6D,
                            values: [Int32(CSIParams.maxValue)], subs: [false])])
    }

    @Test func c0InsideCSIExecutesAndSequenceContinues() {
        #expect(run(seq(ESC, "[1", 0x0D as UInt8, "2m")) ==
                [.execute(0x0D), .csi(prefix: 0, intermediates: [], final: 0x6D,
                                      values: [12], subs: [false])])
        // …also in csiEntry and csiIntermediate.
        #expect(run(seq(ESC, "[", 0x08 as UInt8, "H")) ==
                [.execute(0x08), .csi(prefix: 0, intermediates: [], final: 0x48, values: [], subs: [])])
        #expect(run(seq(ESC, "[ ", 0x08 as UInt8, "q")) ==
                [.execute(0x08), .csi(prefix: 0, intermediates: [0x20], final: 0x71, values: [], subs: [])])
    }

    @Test func canAndSubAbortToGround() {
        let actor = RecordingActor()
        let parser = VTParser(actor: actor)
        parser.feed(seq(ESC, "[12", CAN, "3m"))
        #expect(parser.state == .ground)
        #expect(actor.events == [.execute(CAN), .print(0x33), .print(0x6D)])

        let actor2 = RecordingActor()
        let parser2 = VTParser(actor: actor2)
        parser2.feed(seq(ESC, "[12", SUB, "A"))
        #expect(parser2.state == .ground)
        #expect(actor2.events == [.execute(SUB), .print(0x41)])
    }

    @Test func escAbortsAnUnfinishedCSI() {
        #expect(run(seq(ESC, "[12", ESC, "[1m")) ==
                [.csi(prefix: 0, intermediates: [], final: 0x6D, values: [1], subs: [false])])
    }

    @Test func highByteAbortsCSI() {
        // A byte >= 0x80 inside a CSI is not a C1 control and not UTF-8 either
        // (inside a sequence bytes are raw): the sequence is abandoned. The
        // second byte of the pair is then a stray continuation byte in ground.
        #expect(run(seq(ESC, "[1", [0xC3, 0xA9] as [UInt8], "m")) ==
                [.print(0xFFFD), .print(0x6D)])
    }
}

// MARK: - ESC

@Suite("VTParser ESC")
struct ParserESCTests {
    @Test func simpleAndIntermediate() {
        #expect(run(seq(ESC, "D")) == [.esc(intermediates: [], final: 0x44)])
        #expect(run(seq(ESC, "(0")) == [.esc(intermediates: [0x28], final: 0x30)])
        #expect(run(seq(ESC, "#8")) == [.esc(intermediates: [0x23], final: 0x38)])
    }

    @Test func stringTerminatorIsDispatched() {
        #expect(run(seq(ESC, "\\")) == [.esc(intermediates: [], final: 0x5C)])
    }

    @Test func thirdIntermediateSuppressesDispatch() {
        #expect(run(seq(ESC, "   0", "A")) == [.print(0x41)])
    }

    @Test func c0InsideEscExecutes() {
        #expect(run(seq(ESC, 0x0D as UInt8, "D")) == [.execute(0x0D), .esc(intermediates: [], final: 0x44)])
    }

    @Test func doubleEscRestarts() {
        #expect(run(seq(ESC, ESC, "D")) == [.esc(intermediates: [], final: 0x44)])
    }
}

// MARK: - OSC

@Suite("VTParser OSC")
struct ParserOSCTests {
    @Test func bellTerminated() {
        #expect(run(seq(ESC, "]0;title", BEL)) == [.osc(payload: Array("0;title".utf8), bell: true)])
    }

    @Test func escTerminatedDispatchesThenTheEscFinal() {
        // ESC ends the OSC (bellTerminated == false) and starts an ESC sequence,
        // so the `\` of ST arrives as an ESC dispatch the actor ignores.
        #expect(run(seq(ESC, "]2;hi", ESC, "\\")) ==
                [.osc(payload: Array("2;hi".utf8), bell: false),
                 .esc(intermediates: [], final: 0x5C)])
    }

    @Test func escFollowedByAnythingElseStillEndsOSC() {
        #expect(run(seq(ESC, "]2;hi", ESC, "[1m")) ==
                [.osc(payload: Array("2;hi".utf8), bell: false),
                 .csi(prefix: 0, intermediates: [], final: 0x6D, values: [1], subs: [false])])
    }

    @Test func rawC1TerminatorIsPayload() {
        // 0x9C is a UTF-8 continuation byte, never ST.
        #expect(run(seq(ESC, "]1;", 0x9C as UInt8, "x", BEL)) ==
                [.osc(payload: [0x31, 0x3B, 0x9C, 0x78], bell: true)])
    }

    @Test func utf8PayloadIsRaw() {
        #expect(run(seq(ESC, "]0;héllo", BEL)) ==
                [.osc(payload: Array("0;héllo".utf8), bell: true)])
    }

    @Test func canAborts() {
        let actor = RecordingActor()
        let parser = VTParser(actor: actor)
        parser.feed(seq(ESC, "]0;title", CAN, "A"))
        #expect(parser.state == .ground)
        #expect(actor.events == [.execute(CAN), .print(0x41)])
    }

    @Test func controlsAndDelAreDroppedFromPayload() {
        #expect(run(seq(ESC, "]0;a", 0x01 as UInt8, "b", 0x7F as UInt8, "c", BEL)) ==
                [.osc(payload: Array("0;abc".utf8), bell: true)])
    }

    @Test func emptyPayload() {
        #expect(run(seq(ESC, "]", BEL)) == [.osc(payload: [], bell: true)])
    }

    @Test func overlongPayloadIsDroppedWhole() {
        let actor = RecordingActor()
        let parser = VTParser(actor: actor)
        var input: [UInt8] = [ESC, 0x5D]
        input.append(contentsOf: [UInt8](repeating: 0x41, count: VTParser.maxPayload + 1))
        input.append(BEL)
        input.append(0x42)
        parser.feed(input)
        #expect(parser.state == .ground)
        #expect(actor.events == [.print(0x42)])          // no truncated OSC
    }

    @Test func payloadAtTheCapStillDispatches() {
        let actor = RecordingActor()
        let parser = VTParser(actor: actor)
        var input: [UInt8] = [ESC, 0x5D]
        input.append(contentsOf: [UInt8](repeating: 0x41, count: VTParser.maxPayload))
        input.append(BEL)
        parser.feed(input)
        #expect(actor.events.count == 1)
        if case .osc(let payload, let bell) = actor.events[0] {
            #expect(payload.count == VTParser.maxPayload)
            #expect(bell)
        } else {
            Issue.record("expected an OSC dispatch")
        }
    }
}

// MARK: - DCS and APC

@Suite("VTParser DCS / APC")
struct ParserStringTests {
    @Test func dcsIsStreamed() {
        #expect(run(seq(ESC, "P1$q\"p", ESC, "\\")) ==
                [.dcsHook(prefix: 0, intermediates: [0x24], final: 0x71, values: [1]),
                 .dcsPut(Array("\"p".utf8)),
                 .dcsUnhook,
                 .esc(intermediates: [], final: 0x5C)])
    }

    @Test func dcsPutIsChunkIndependent() {
        let input = seq(ESC, "Pqpayload here", ESC, "\\")
        #expect(run(input) == run(input, chunk: 1))
    }

    @Test func dcsAbortedByCanStillUnhooks() {
        let actor = RecordingActor()
        let parser = VTParser(actor: actor)
        parser.feed(seq(ESC, "Pqdata", CAN, "A"))
        #expect(parser.state == .ground)
        #expect(actor.events == [.dcsHook(prefix: 0, intermediates: [], final: 0x71, values: []),
                                 .dcsPut(Array("data".utf8)),
                                 .dcsUnhook,
                                 .execute(CAN),
                                 .print(0x41)])
    }

    @Test func dcsWithTooManyIntermediatesNeverHooks() {
        let actor = RecordingActor()
        let parser = VTParser(actor: actor)
        parser.feed(seq(ESC, "P!!!qdata", ESC, "\\", "A"))
        #expect(actor.events == [.esc(intermediates: [], final: 0x5C), .print(0x41)])
    }

    @Test func dcsDelIsNotPayload() {
        #expect(run(seq(ESC, "Pqa", 0x7F as UInt8, "b", ESC, "\\")) ==
                [.dcsHook(prefix: 0, intermediates: [], final: 0x71, values: []),
                 .dcsPut(Array("ab".utf8)),
                 .dcsUnhook,
                 .esc(intermediates: [], final: 0x5C)])
    }

    @Test func apcAccumulates() {
        #expect(run(seq(ESC, "_Gf=100,a=T;dGVzdA==", ESC, "\\")) ==
                [.apc(Array("Gf=100,a=T;dGVzdA==".utf8)),
                 .esc(intermediates: [], final: 0x5C)])
    }

    @Test func pmAndSosUseTheSamePath() {
        #expect(run(seq(ESC, "^private", ESC, "\\")) ==
                [.apc(Array("private".utf8)), .esc(intermediates: [], final: 0x5C)])
        #expect(run(seq(ESC, "Xstart", ESC, "\\")) ==
                [.apc(Array("start".utf8)), .esc(intermediates: [], final: 0x5C)])
    }

    @Test func bellDoesNotEndApc() {
        #expect(run(seq(ESC, "_ab", BEL, "cd", ESC, "\\")) ==
                [.apc(Array("abcd".utf8)), .esc(intermediates: [], final: 0x5C)])
    }
}

// MARK: - state, reset, chunking, fuzz

@Suite("VTParser robustness")
struct ParserRobustnessTests {
    @Test func resetReturnsToGround() {
        let actor = RecordingActor()
        let parser = VTParser(actor: actor)
        parser.feed(seq(ESC, "]0;half"))
        #expect(parser.state == .oscString)
        parser.reset()
        #expect(parser.state == .ground)
        parser.feed("A")
        #expect(actor.events == [.print(0x41)])
    }

    @Test func stateIsVisibleForEveryPhase() {
        let actor = RecordingActor()
        let parser = VTParser(actor: actor)
        parser.feed([ESC]);            #expect(parser.state == .escape)
        parser.feed([0x5B]);           #expect(parser.state == .csiEntry)
        parser.feed([0x31]);           #expect(parser.state == .csiParam)
        parser.feed([0x24]);           #expect(parser.state == .csiIntermediate)
        parser.feed([0x70]);           #expect(parser.state == .ground)
        parser.feed(seq(ESC, "P"));    #expect(parser.state == .dcsEntry)
        parser.feed([0x71]);           #expect(parser.state == .dcsPassthrough)
        parser.feed([ESC]);            #expect(parser.state == .escape)
        parser.feed([0x5C]);           #expect(parser.state == .ground)
        parser.feed(seq(ESC, "_"));    #expect(parser.state == .sosPmApcString)
        parser.feed([CAN]);            #expect(parser.state == .ground)
    }

    @Test func feedStringMatchesFeedBytes() {
        let text = "\u{1b}[1;31mhé\u{1b}[0m\n"
        #expect(run(text) == run(Array(text.utf8)))
    }

    @Test func chunkInvarianceOnARealisticStream() {
        let input = seq(
            "plain text ", ESC, "[1;31mred", ESC, "[0m\r\n",
            ESC, "]0;a title", BEL,
            ESC, "P1$q\"p", ESC, "\\",
            ESC, "_Gpayload", ESC, "\\",
            "unicode: héllo € 𝄞 ", [0xE2, 0x82] as [UInt8], "truncated\r\n",
            ESC, "[?1049h", ESC, "[38:2::255:0:0m", "x"
        )
        let whole = run(input)
        for size in [1, 2, 3, 5, 7, 13, 64] {
            #expect(run(input, chunk: size) == whole, "chunk size \(size)")
        }
    }

    /// 100 KB of random bytes: no crash, chunking still does not matter, and
    /// the parser can always be brought back to ground.
    @Test func randomFuzz() {
        var state: UInt64 = 0x5EEDBEEF_1234_5678
        func next() -> UInt8 {                       // SplitMix64
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return UInt8(truncatingIfNeeded: z ^ (z >> 31))
        }
        var input = [UInt8]()
        input.reserveCapacity(100_000)
        for _ in 0..<100_000 { input.append(next()) }

        let actor = RecordingActor()
        let parser = VTParser(actor: actor)
        parser.feed(input)
        parser.feed([CAN])                            // CAN aborts from every state
        #expect(parser.state == .ground)

        let byteAtATime = RecordingActor()
        let slowParser = VTParser(actor: byteAtATime)
        for b in input { slowParser.feed([b]) }
        slowParser.feed([CAN])
        #expect(slowParser.state == .ground)
        #expect(byteAtATime.events == actor.events)
    }

    /// The same, biased towards escape introducers so the string states get hit.
    @Test func fuzzWithManyEscapes() {
        var state: UInt64 = 0xC0FFEE_D00D
        func next() -> UInt8 {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return UInt8(truncatingIfNeeded: z ^ (z >> 31))
        }
        let alphabet: [UInt8] = [ESC, 0x5B, 0x5D, 0x50, 0x5F, 0x3B, 0x3A, 0x3F, 0x21,
                                 0x30, 0x39, 0x6D, 0x48, BEL, CAN, SUB, 0x1B, 0x0A,
                                 0x41, 0x7F, 0x9C, 0xC2, 0x80, 0xE2, 0xF0, 0xFF]
        var input = [UInt8]()
        input.reserveCapacity(50_000)
        for _ in 0..<50_000 { input.append(alphabet[Int(next()) % alphabet.count]) }

        let whole = RecordingActor()
        let p1 = VTParser(actor: whole)
        p1.feed(input)
        p1.feed([CAN])
        #expect(p1.state == .ground)

        let slow = RecordingActor()
        let p2 = VTParser(actor: slow)
        for b in input { p2.feed([b]) }
        p2.feed([CAN])
        #expect(slow.events == whole.events)
    }
}
