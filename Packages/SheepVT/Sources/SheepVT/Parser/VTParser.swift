// SheepVT — the escape-sequence parser.
//
// A table-driven Williams/DEC state machine (`ParseTable`) with a UTF-8
// decoder in front of it that only runs in ground state, plus the three fast
// paths xterm.js uses: a run of printable ASCII delivered with one `printRun`,
// `ESC [` collapsed straight into `csiEntry`, and C0 controls executed without
// a table lookup. The per-byte loop allocates nothing: one `CSIParams`, one
// 2-byte intermediates array, one payload buffer and one DCS scratch buffer
// are reused for the life of the parser.
//
// The parser knows syntax only. Everything it recognises is handed to a
// `VTActor` (see VTActor.swift), which is the Terminal in production and a
// recording actor in the tests.

public final class VTParser {
    /// At most two intermediate bytes (0x20…0x2F) are kept; a third makes the
    /// whole sequence invalid (vte's `ignoring` flag) and it is not dispatched.
    public static let maxIntermediates = 2
    /// OSC / APC accumulation cap and DCS byte cap. An OSC or APC payload that
    /// grows past this is dropped **whole** (never truncated and delivered);
    /// DCS is streamed, so its `dcsPut` calls simply stop at the cap.
    public static let maxPayload = 8 * 1024 * 1024

    public enum State: UInt8, Sendable {
        case ground, escape, escapeIntermediate, csiEntry, csiParam, csiIntermediate,
             csiIgnore, dcsEntry, dcsParam, dcsIntermediate, dcsPassthrough, dcsIgnore,
             oscString, sosPmApcString
    }

    /// The actor is not owned: in production the Terminal owns the parser and
    /// is itself the actor, so a strong reference would be a cycle.
    public unowned var actor: any VTActor
    public private(set) var state: State = .ground

    // Sequence in progress.
    private var decoder = UTF8Decoder()
    private var params = CSIParams()
    private var intermediates: [UInt8] = [0, 0]
    private var intermediateCount = 0
    private var prefix: UInt8 = 0
    /// A third intermediate arrived: keep parsing, but do not dispatch.
    private var ignoreSequence = false
    /// The last entry of `params.values` belongs to the field being scanned.
    private var paramStarted = false
    /// Whether that field was introduced by ':' (sub-parameter) or ';'.
    private var currentParamIsSub = false

    // String payloads (OSC / APC accumulated, DCS streamed).
    private var payload: [UInt8] = []
    private var payloadOverflow = false
    private var dcsActive = false
    private var dcsBytes = 0
    private var dcsScratch: [UInt8] = []

    private let table = ParseTable.table

    /// A `feed` is running. An actor callback that writes straight back into
    /// the same terminal (a DA reply looped back, a test double) would trample
    /// the sequence in flight, so its bytes wait in `pending` instead.
    private var isFeeding = false
    private var pending: [UInt8] = []

    public init(actor: any VTActor) {
        self.actor = actor
        payload.reserveCapacity(256)
        dcsScratch.reserveCapacity(256)
    }

    /// Reset to ground and drop every partial sequence (RIS, tests). A DCS in
    /// flight is dropped without a closing `dcsUnhook` — the actor is being
    /// reset too.
    public func reset() {
        state = .ground
        decoder = UTF8Decoder()
        clear()
        payload.removeAll(keepingCapacity: true)
        payloadOverflow = false
        dcsActive = false
        dcsBytes = 0
    }

    public func feed(_ bytes: [UInt8]) {
        bytes.withUnsafeBufferPointer { feed($0) }
    }

    public func feed(_ text: String) {
        var t = text
        t.withUTF8 { feed($0) }
    }

    // MARK: - the loop

    public func feed(_ bytes: UnsafeBufferPointer<UInt8>) {
        guard !bytes.isEmpty else { return }
        guard !isFeeding else {
            pending.append(contentsOf: bytes)
            return
        }
        isFeeding = true
        defer { isFeeding = false }
        run(bytes)
        while !pending.isEmpty {
            var next: [UInt8] = []
            swap(&next, &pending)
            next.withUnsafeBufferPointer { run($0) }
        }
    }

    private func run(_ bytes: UnsafeBufferPointer<UInt8>) {
        guard let base = bytes.baseAddress, !bytes.isEmpty else { return }
        let n = bytes.count
        table.withUnsafeBufferPointer { tbl in
            var i = 0
            while i < n {
                let b = base[i]

                // 1. Ground state is the only place UTF-8 is decoded. Inside a
                //    sequence the bytes are raw.
                if state == .ground, b >= 0x80 || decoder.isPending {
                    if b == 0x1B {
                        // ESC interrupts a partial sequence: it becomes U+FFFD
                        // and the ESC is handled below as usual.
                        if let s = decoder.flush() { emit(s) }
                    } else {
                        if let s = decoder.decode(b) { emit(s) }
                        if decoder.needsRetry {
                            if b >= 0x80 {
                                // The byte starts a new sequence (or is invalid too).
                                if let s = decoder.decode(b) { emit(s) }
                                i += 1
                                continue
                            }
                            // An ASCII byte after a truncated sequence: fall
                            // through and treat it as the fresh byte it is.
                        } else {
                            i += 1
                            continue
                        }
                    }
                }

                // 2. Fast path: C0 controls in the states where they are simply
                //    executed and the sequence continues (ground … csiIgnore).
                if b < 0x18, state.rawValue <= State.csiIgnore.rawValue {
                    actor.execute(b)
                    i += 1
                    continue
                }

                // 3. Fast paths in ground: printable runs and `ESC [`.
                if state == .ground {
                    if b >= 0x20, b < 0x7F {
                        var j = i + 1
                        while j < n, base[j] >= 0x20, base[j] < 0x7F { j += 1 }
                        actor.printRun(UnsafeBufferPointer(start: base + i, count: j - i))
                        i = j
                        continue
                    }
                    if b == 0x1B {
                        clear()
                        if i + 1 < n, base[i + 1] == 0x5B {
                            state = .csiEntry
                            i += 2
                        } else {
                            state = .escape
                            i += 1
                        }
                        continue
                    }
                    // 0x18, 0x19, 0x1A, 0x1C…0x1F and 0x7F fall through to the table.
                }

                // 4. Table lookup. Bytes >= 0xA0 collapse onto 0xA0.
                let entry = tbl[(Int(state.rawValue) << 8) | (b < 0xA0 ? Int(b) : 0xA0)]
                state = State(rawValue: UInt8(truncatingIfNeeded: entry)) ?? .ground

                switch ParseAction(rawValue: entry >> 8) ?? .error {
                case .ignore, .error:
                    break

                case .print:
                    actor.print(UInt32(b))

                case .execute:
                    actor.execute(b)

                case .clear:
                    clear()

                case .collect:
                    if intermediateCount < VTParser.maxIntermediates {
                        intermediates[intermediateCount] = b
                        intermediateCount += 1
                    } else {
                        ignoreSequence = true
                    }

                case .collectPrefix:
                    prefix = b

                case .param:
                    // Inner loop over the whole run of parameter bytes.
                    var c = b
                    while true {
                        if c == 0x3B { addSeparator(sub: false) }
                        else if c == 0x3A { addSeparator(sub: true) }
                        else { addDigit(c) }
                        let k = i + 1
                        guard k < n, base[k] >= 0x30, base[k] <= 0x3B else { break }
                        i = k
                        c = base[k]
                    }

                case .csiDispatch:
                    if !ignoreSequence, !params.overflowed {
                        actor.csiDispatch(prefix: prefix,
                                          intermediates: intermediates[0..<intermediateCount],
                                          final: b,
                                          params: params)
                    }

                case .escDispatch:
                    if !ignoreSequence {
                        actor.escDispatch(intermediates: intermediates[0..<intermediateCount],
                                          final: b)
                    }

                case .dcsHook:
                    if ignoreSequence || params.overflowed {
                        state = .dcsIgnore        // never hooked, so never unhooked
                    } else {
                        dcsActive = true
                        dcsBytes = 0
                        actor.dcsHook(prefix: prefix,
                                      intermediates: intermediates[0..<intermediateCount],
                                      final: b,
                                      params: params)
                    }

                case .dcsPut:
                    var j = i
                    while j < n {
                        let c = base[j]
                        if c == 0x18 || c == 0x1A || c == 0x1B || c == 0x7F { break }
                        j += 1
                    }
                    put(dcs: base + i, count: j - i)
                    i = j - 1

                case .dcsUnhook:
                    if dcsActive {
                        actor.dcsUnhook()
                        dcsActive = false
                    }
                    if b == 0x18 || b == 0x1A { actor.execute(b) }
                    if b == 0x1B { clear(); state = .escape }

                case .oscStart, .apcStart:
                    payload.removeAll(keepingCapacity: true)
                    payloadOverflow = false

                case .oscPut, .apcPut:
                    var j = i
                    while j < n {
                        let c = base[j]
                        if c < 0x20 || c == 0x7F { break }
                        j += 1
                    }
                    append(payload: base + i, count: j - i)
                    i = j - 1

                case .oscEnd:
                    if b == 0x18 || b == 0x1A {
                        actor.execute(b)                      // aborted: nothing dispatched
                    } else if !payloadOverflow {
                        actor.oscDispatch(payload[...], bellTerminated: b == 0x07)
                    }
                    endString(terminator: b)

                case .apcEnd:
                    if b == 0x18 || b == 0x1A {
                        actor.execute(b)
                    } else if !payloadOverflow {
                        actor.apcDispatch(payload[...])
                    }
                    endString(terminator: b)
                }
                i += 1
            }
        }
    }

    // MARK: - helpers

    /// A decoded ground-state code point.
    private func emit(_ scalar: UInt32) {
        if scalar < 0x20 { actor.execute(UInt8(scalar)); return }
        if scalar == 0x7F { return }
        // C1 controls that arrived UTF-8 encoded are dropped: only their raw
        // single-byte form ever meant anything, and SheepVT does not accept
        // that either (those bytes are UTF-8 continuation bytes here).
        if scalar >= 0x80, scalar <= 0x9F { return }
        actor.print(scalar)
    }

    private func clear() {
        params.reset()
        intermediateCount = 0
        prefix = 0
        ignoreSequence = false
        paramStarted = false
        currentParamIsSub = false
    }

    private func addDigit(_ byte: UInt8) {
        if !paramStarted {
            params.addParam(sub: currentParamIsSub)
            paramStarted = true
        }
        params.addDigit(Int32(byte - 0x30))
    }

    /// ';' or ':': close the field being scanned (materialising it as an
    /// omitted parameter when it had no digits, so `ESC[;5H` is [-1, 5]) and
    /// open the next one.
    private func addSeparator(sub: Bool) {
        if !paramStarted { params.addParam(sub: currentParamIsSub) }
        params.addParam(sub: sub)
        paramStarted = true
        currentParamIsSub = sub
    }

    private func append(payload p: UnsafePointer<UInt8>, count: Int) {
        guard count > 0, !payloadOverflow else { return }
        if payload.count + count > VTParser.maxPayload {
            payloadOverflow = true
            payload.removeAll(keepingCapacity: false)   // an over-long payload is dropped whole
            return
        }
        payload.append(contentsOf: UnsafeBufferPointer(start: p, count: count))
    }

    private func endString(terminator: UInt8) {
        payload.removeAll(keepingCapacity: payload.count <= 65_536)   // a 7 MiB OSC must not pin 7 MiB per tab
        payloadOverflow = false
        if terminator == 0x1B { clear(); state = .escape }
    }

    private func put(dcs p: UnsafePointer<UInt8>, count: Int) {
        guard count > 0, dcsActive else { return }
        if dcsBytes < VTParser.maxPayload {
            let allowed = Swift.min(count, VTParser.maxPayload - dcsBytes)
            dcsScratch.removeAll(keepingCapacity: true)
            dcsScratch.append(contentsOf: UnsafeBufferPointer(start: p, count: allowed))
            actor.dcsPut(dcsScratch[...])
        }
        dcsBytes += count
    }
}
