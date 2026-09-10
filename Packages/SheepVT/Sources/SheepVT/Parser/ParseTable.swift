// SheepVT — the VT500 transition table (Paul Williams' DEC ANSI parser),
// built once by a pure function the way xterm.js `EscapeSequenceParser.ts`
// does it (MIT).
//
// Layout: one `[UInt16]` of `stateCount * 256` entries.
//   index = state << 8 | byte
//   value = action << 8 | nextState
//
// The caller collapses every byte >= 0xA0 to 0xA0 before indexing (xterm.js'
// NON_ASCII_PRINTABLE trick), so only 0x00…0xA0 of each row is ever read; the
// rows are nevertheless filled for the whole 0x00…0xFF range, with 0x80…0xFF
// all carrying the same rule, so the table is total and a stray uncollapsed
// byte cannot produce garbage.
//
// Differences from the xterm.js table, all of them deliberate (see SPEC.md):
//
//  * **No raw C1 handling.** xterm.js gives 0x80…0x9F "anywhere" meanings
//    (0x9B = CSI, 0x9D = OSC, 0x90 = DCS, 0x9C = ST …). SheepVT decodes UTF-8
//    in front of the machine, so those bytes are either UTF-8 continuation
//    bytes or invalid ones. They are therefore treated exactly like a
//    non-ASCII printable byte (payload inside strings, U+FFFD in ground).
//    In particular raw 0x9C does **not** terminate an OSC — it is payload.
//  * **SOS, PM and APC share one state** (`sosPmApcString`); all three are
//    accumulated and delivered through `apcDispatch`.
//  * **C0 controls inside the DCS header states are executed** (xterm.js
//    ignores them there), matching what it already does for CSI and ESC:
//    a control that arrives in the middle of a sequence is acted on and the
//    sequence continues.
//  * **0x7F (DEL) is ignored everywhere**, including inside OSC/APC payloads
//    (xterm.js keeps it in the OSC payload).
//  * The prefix byte (0x3C…0x3F) has its own action (`collectPrefix`) instead
//    of sharing `collect` with the intermediates, so the parser can enforce
//    "one prefix, at most two intermediates" without post-hoc unpacking.

/// What the parser does with a byte. Stored in the high byte of a table entry.
public enum ParseAction: UInt16, Sendable {
    /// Drop the byte.
    case ignore = 0
    /// Unexpected byte for this state: drop it and abort to ground.
    case error
    /// Printable code point (ground only; the parser's fast path handles this).
    case print
    /// C0 control: deliver to `VTActor.execute`.
    case execute
    /// Start a new sequence: reset params, intermediates, prefix, ignore flag.
    case clear
    /// Intermediate byte 0x20…0x2F.
    case collect
    /// Private-marker byte 0x3C…0x3F (only legal as the first parameter byte).
    case collectPrefix
    /// Parameter byte 0x30…0x3B (digit, ';' or ':').
    case param
    case csiDispatch
    case escDispatch
    case oscStart
    case oscPut
    case oscEnd
    case dcsHook
    case dcsPut
    case dcsUnhook
    case apcStart
    case apcPut
    case apcEnd
}

public enum ParseTable {
    public static let stateCount = 14
    public static let byteCount = 256

    /// `state << 8 | byte` → `action << 8 | nextState`.
    public static let table: [UInt16] = makeTable()

    @inlinable
    public static func pack(_ action: ParseAction, _ next: VTParser.State) -> UInt16 {
        (action.rawValue << 8) | UInt16(next.rawValue)
    }
    @inlinable
    public static func action(of entry: UInt16) -> ParseAction {
        ParseAction(rawValue: entry >> 8) ?? .error
    }
    @inlinable
    public static func next(of entry: UInt16) -> VTParser.State {
        VTParser.State(rawValue: UInt8(truncatingIfNeeded: entry)) ?? .ground
    }
    /// Entry for a state/byte pair, applying the >= 0xA0 collapse.
    @inlinable
    public static func entry(_ state: VTParser.State, _ byte: UInt8) -> UInt16 {
        table[(Int(state.rawValue) << 8) | (byte < 0xA0 ? Int(byte) : 0xA0)]
    }

    // MARK: - construction

    private static func makeTable() -> [UInt16] {
        typealias S = VTParser.State
        var t = [UInt16](repeating: pack(.error, .ground), count: stateCount * byteCount)

        func add(_ state: S, _ codes: [UInt8], _ action: ParseAction, _ next: S) {
            let base = Int(state.rawValue) << 8
            let value = pack(action, next)
            for c in codes { t[base | Int(c)] = value }
        }
        func range(_ from: UInt8, _ through: UInt8) -> [UInt8] { Array(from...through) }

        // Byte classes (xterm.js names).
        //  executables      C0 controls that are executed and leave the state alone
        //  cancels          CAN (0x18) / SUB (0x1A): abort to ground, and are executed
        //  printables       0x20…0x7E
        //  intermediates    0x20…0x2F
        //  paramBytes       0x30…0x39 digits, 0x3A ':' , 0x3B ';'
        //  prefixBytes      0x3C…0x3F private markers
        //  finals           0x40…0x7E
        //  high             0x80…0xFF (collapsed to 0xA0 by the caller)
        let executables = range(0x00, 0x17) + [0x19] + range(0x1C, 0x1F)
        let cancels: [UInt8] = [0x18, 0x1A]
        let esc: [UInt8] = [0x1B]
        let del: [UInt8] = [0x7F]
        let printables = range(0x20, 0x7E)
        let intermediates = range(0x20, 0x2F)
        let paramBytes = range(0x30, 0x3B)
        let prefixBytes = range(0x3C, 0x3F)
        let finals = range(0x40, 0x7E)
        let high = range(0x80, 0xFF)

        let allStates: [S] = [
            .ground, .escape, .escapeIntermediate, .csiEntry, .csiParam, .csiIntermediate,
            .csiIgnore, .dcsEntry, .dcsParam, .dcsIntermediate, .dcsPassthrough, .dcsIgnore,
            .oscString, .sosPmApcString,
        ]

        // ── anywhere rules ────────────────────────────────────────────────
        // CAN/SUB abort whatever is in flight and are delivered to the actor;
        // ESC starts a new sequence. String states override these below so the
        // payload they have collected is closed properly first.
        for s in allStates {
            add(s, cancels, .execute, .ground)
            add(s, esc, .clear, .escape)
        }

        // ── ground ────────────────────────────────────────────────────────
        // The parser inlines this row (printable runs, C0 fast path, ESC), and
        // routes bytes >= 0x80 through the UTF-8 decoder instead of the table;
        // the row is kept complete and correct as the documentation of those
        // rules and for the leftovers (0x18, 0x19, 0x1A, 0x1C…0x1F, 0x7F).
        add(.ground, executables, .execute, .ground)
        add(.ground, printables, .print, .ground)
        add(.ground, del, .ignore, .ground)
        add(.ground, high, .print, .ground)

        // ── escape ────────────────────────────────────────────────────────
        add(.escape, executables, .execute, .escape)
        add(.escape, del, .ignore, .escape)
        add(.escape, intermediates, .collect, .escapeIntermediate)
        // Finals: 0x30…0x7E minus the string/CSI/DCS introducers.
        add(.escape, range(0x30, 0x4F), .escDispatch, .ground)
        add(.escape, range(0x51, 0x57), .escDispatch, .ground)
        add(.escape, [0x59, 0x5A, 0x5C], .escDispatch, .ground)   // 0x5C = ST, dispatched
        add(.escape, range(0x60, 0x7E), .escDispatch, .ground)
        add(.escape, [0x50], .clear, .dcsEntry)                   // ESC P — DCS
        add(.escape, [0x5B], .clear, .csiEntry)                   // ESC [ — CSI
        add(.escape, [0x5D], .oscStart, .oscString)               // ESC ] — OSC
        add(.escape, [0x58, 0x5E, 0x5F], .apcStart, .sosPmApcString)  // ESC X/^/_ — SOS/PM/APC

        // ── escape intermediate ───────────────────────────────────────────
        add(.escapeIntermediate, executables, .execute, .escapeIntermediate)
        add(.escapeIntermediate, del, .ignore, .escapeIntermediate)
        add(.escapeIntermediate, intermediates, .collect, .escapeIntermediate)
        add(.escapeIntermediate, range(0x30, 0x7E), .escDispatch, .ground)

        // ── CSI ───────────────────────────────────────────────────────────
        add(.csiEntry, executables, .execute, .csiEntry)
        add(.csiEntry, del, .ignore, .csiEntry)
        add(.csiEntry, intermediates, .collect, .csiIntermediate)
        add(.csiEntry, paramBytes, .param, .csiParam)
        add(.csiEntry, prefixBytes, .collectPrefix, .csiParam)
        add(.csiEntry, finals, .csiDispatch, .ground)

        add(.csiParam, executables, .execute, .csiParam)
        add(.csiParam, del, .ignore, .csiParam)
        add(.csiParam, paramBytes, .param, .csiParam)
        add(.csiParam, prefixBytes, .ignore, .csiIgnore)   // a second private marker: give up
        add(.csiParam, intermediates, .collect, .csiIntermediate)
        add(.csiParam, finals, .csiDispatch, .ground)

        add(.csiIntermediate, executables, .execute, .csiIntermediate)
        add(.csiIntermediate, del, .ignore, .csiIntermediate)
        add(.csiIntermediate, intermediates, .collect, .csiIntermediate)
        add(.csiIntermediate, range(0x30, 0x3F), .ignore, .csiIgnore)  // params after intermediates
        add(.csiIntermediate, finals, .csiDispatch, .ground)

        add(.csiIgnore, executables, .execute, .csiIgnore)
        add(.csiIgnore, del, .ignore, .csiIgnore)
        add(.csiIgnore, range(0x20, 0x3F), .ignore, .csiIgnore)
        add(.csiIgnore, finals, .ignore, .ground)          // swallow the whole sequence
        add(.csiIgnore, high, .ignore, .csiIgnore)

        // ── DCS ───────────────────────────────────────────────────────────
        // Header states mirror CSI; the final byte hooks and the payload is
        // streamed until ESC/CAN/SUB.
        add(.dcsEntry, executables, .execute, .dcsEntry)
        add(.dcsEntry, del, .ignore, .dcsEntry)
        add(.dcsEntry, intermediates, .collect, .dcsIntermediate)
        add(.dcsEntry, paramBytes, .param, .dcsParam)
        add(.dcsEntry, prefixBytes, .collectPrefix, .dcsParam)
        add(.dcsEntry, finals, .dcsHook, .dcsPassthrough)

        add(.dcsParam, executables, .execute, .dcsParam)
        add(.dcsParam, del, .ignore, .dcsParam)
        add(.dcsParam, paramBytes, .param, .dcsParam)
        add(.dcsParam, prefixBytes, .ignore, .dcsIgnore)
        add(.dcsParam, intermediates, .collect, .dcsIntermediate)
        add(.dcsParam, finals, .dcsHook, .dcsPassthrough)

        add(.dcsIntermediate, executables, .execute, .dcsIntermediate)
        add(.dcsIntermediate, del, .ignore, .dcsIntermediate)
        add(.dcsIntermediate, intermediates, .collect, .dcsIntermediate)
        add(.dcsIntermediate, range(0x30, 0x3F), .ignore, .dcsIgnore)
        add(.dcsIntermediate, finals, .dcsHook, .dcsPassthrough)

        add(.dcsPassthrough, executables, .dcsPut, .dcsPassthrough)
        add(.dcsPassthrough, printables, .dcsPut, .dcsPassthrough)
        add(.dcsPassthrough, high, .dcsPut, .dcsPassthrough)
        add(.dcsPassthrough, del, .ignore, .dcsPassthrough)
        add(.dcsPassthrough, cancels, .dcsUnhook, .ground)
        add(.dcsPassthrough, esc, .dcsUnhook, .ground)     // parser moves on to .escape

        // Nothing was hooked, so nothing has to be unhooked: swallow bytes.
        add(.dcsIgnore, executables, .ignore, .dcsIgnore)
        add(.dcsIgnore, del, .ignore, .dcsIgnore)
        add(.dcsIgnore, printables, .ignore, .dcsIgnore)
        add(.dcsIgnore, high, .ignore, .dcsIgnore)

        // ── OSC ───────────────────────────────────────────────────────────
        // Payload is 0x20…0x7E plus every byte >= 0x80 (UTF-8 text, and 0x9C
        // which is *not* a terminator here). BEL and ESC end it; CAN/SUB abort it.
        add(.oscString, executables, .ignore, .oscString)
        add(.oscString, del, .ignore, .oscString)
        add(.oscString, printables, .oscPut, .oscString)
        add(.oscString, high, .oscPut, .oscString)
        add(.oscString, [0x07], .oscEnd, .ground)          // BEL
        add(.oscString, cancels, .oscEnd, .ground)         // abort, no dispatch
        add(.oscString, esc, .oscEnd, .ground)             // parser moves on to .escape

        // ── SOS / PM / APC ────────────────────────────────────────────────
        // Same shape as OSC but BEL is not a terminator (kitty's graphics
        // protocol sends binary payloads terminated by ESC \ only).
        add(.sosPmApcString, executables, .ignore, .sosPmApcString)
        add(.sosPmApcString, del, .ignore, .sosPmApcString)
        add(.sosPmApcString, printables, .apcPut, .sosPmApcString)
        add(.sosPmApcString, high, .apcPut, .sosPmApcString)
        add(.sosPmApcString, cancels, .apcEnd, .ground)
        add(.sosPmApcString, esc, .apcEnd, .ground)

        return t
    }
}
