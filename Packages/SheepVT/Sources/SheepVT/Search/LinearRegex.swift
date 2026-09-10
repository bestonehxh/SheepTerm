// SheepVT — a linear-time regular expression engine for the find bar.
//
// WHY a second engine exists at all. Swift's `Regex` backtracks, has no step
// limit, and nothing stops a match that is already running: `(a+)+b` over 24
// `a`s does not finish, and a `Task` cancelled around it goes on burning a core
// exactly as before. `SearchEngine.RegexRunner` bounds the WAIT, not the work —
// control comes back in ~50 ms, but the abandoned matchers were measured
// holding ~3.9 cores, and they outlive the engine that started them because the
// closure belongs to the GCD queue, not to us. Closing every tab does not give
// the cores back; quitting does.
//
// The fix the rest of the field already uses for terminal search is an
// automaton instead of a backtracker: Alacritty runs regex-automata's lazy
// DFAs, WezTerm and ripgrep run the Rust regex crate ("finite automata,
// guaranteed linear time on all inputs"). Swift has no such engine, so this is
// one — a Pike VM: Thompson's construction, simulated with the whole set of
// live threads advanced in lock-step, one step per input scalar. Russ Cox's
// pike.c, minus submatch capture (search wants ranges) plus the leftmost-first
// cutoff that makes the answer agree with a backtracker's.
//
// The property that matters: a thread set holds at most one entry per program
// counter, so a scan is O(instructions x scalars) and there is no path through
// this file that can backtrack. Measured (release, M-series): `(a+)+b`,
// `(a|a)*b` and `(a*)*b` over 40 `a`s return in 2.6, 3.4 and 2.7 microseconds;
// `(a+)+b` over ten thousand `a`s takes 0.44 ms, which is the same number
// scaled by the text length, which is the whole point. Swift `Regex` does not
// return at all on any of them.
//
// Finding EVERY non-overlapping match restarts the scan at each match's end, so
// the call as a whole is O(instructions x scalars x matches) in a contrived
// case — the same trade RE2 makes for its own FindAll — and O(instructions x
// scalars) in every real one. What is gone is the exponential, not every
// polynomial.
//
// WHAT it is not. This is a subset engine, on purpose. `init?` returns nil for
// anything it cannot compile *exactly* — backreferences, lookaround, unknown
// escapes, a program that would not fit the instruction cap — because the
// caller's contract is "nil means fall back to `Regex`", and a pattern silently
// mis-compiled here would be worse than a slow one. Strict beats clever.
//
// Semantics are Swift `Regex`'s, at `.matchingSemantics(.unicodeScalar)`, and
// `LinearRegexTests` proves it with 200k differential cases rather than by
// argument. The scalar level is not a compromise: `SearchEngine` measures every
// offset in scalars because that is what its cell map is keyed on, so an engine
// that counted grapheme clusters would be answering a different question.
//
// Two places where this engine deliberately does NOT copy the `Regex` path the
// app ships today, both of them written down where they are implemented:
//
//   * `.` and every quantifier count SCALARS, where the current path runs at
//     `Regex`'s default grapheme level and swallows a combining mark whole.
//   * `\b` is the classic "word character on exactly one side" rule, because
//     neither of `Regex`'s two word-boundary kinds is that rule and both of
//     them answer questions about `12 34` and `a1b` that no other engine
//     would agree with. See `isWordBoundary`.

/// A compiled pattern that matches in time linear in the text.
///
/// Immutable and `Sendable` once built: the program is a value, and every
/// mutable thing a match needs is allocated inside `matches(in:limit:)`. It can
/// therefore be handed to another queue without the `UncheckedBox` dance the
/// `Regex` path needs — though the point of it is that it no longer has to be.
public struct LinearRegex: Sendable {

    /// Compiled program length past which we refuse the pattern.
    ///
    /// Counted repetition is expanded, so `a{1000}{1000}` asks for a million
    /// instructions. Linear does not mean free: a scan costs instructions x
    /// scalars, measured here at ~16 ns per step (release, M-series), so the
    /// program length is the second half of the time bound and has to be capped
    /// as firmly as the first.
    ///
    /// Measured, `a{n}b` over one long logical line:
    ///
    ///     n     400 scalars   10,000 scalars   20,000 scalars
    ///     64        0.4 ms          12 ms            24 ms
    ///     1024      1.5 ms         160 ms           340 ms
    ///     4000      1.5 ms         650 ms          1300 ms
    ///
    /// 1024 keeps the worst thing anyone can type to a third of a second on a
    /// line longer than any device emits, and still compiles `a{1000}`. A
    /// pattern of the shape people actually search for — `(\w+)@[a-z.]+`, about
    /// twenty instructions — is 1.4 ms over those same 20,000 scalars.
    static let maxInstructions = 1024

    /// Largest repetition count we will even parse, before the cap above gets a
    /// say. Bounds the arithmetic; `{9999999999}` is a typo, not a query.
    private static let maxRepeat = 100_000
    /// How deep `(` may nest. The parser is recursive descent and the emitter
    /// walks the tree the same way, so depth is the one dimension the other
    /// caps do not cover: a few thousand `(` — one paste — is a few thousand
    /// stack frames, and a review measured the overflow happening between
    /// 10,000 and 50,000 levels on a stack the size of the main thread's. A
    /// crash is a worse answer than "not supported", and no find bar needs
    /// more than a handful of levels; 128 is already far past any pattern a
    /// person types.
    static let maxDepth = 128
    /// How many quantifiers may stack on one atom. `a{1}{1}{1}…` needs no
    /// parentheses, so `maxDepth` never sees it, and `{1}` emits nothing, so
    /// neither the instruction cap nor the work cap fires either — measured:
    /// 200,000 of them SIGSEGV'd the process while 20,000 was merely refused.
    /// The tree is what gets deep, and both the emitter's walk and ARC's
    /// release of a deeply nested indirect enum recurse over it. Eight is
    /// already more than a human writes; the two caps together bound the tree
    /// at roughly 128 x 9.
    static let maxQuantifierChain = 8

    private let program: [Inst]
    private let classes: [CharClass]
    private let ignoresCase: Bool

    // MARK: - instructions

    /// One Thompson instruction. `split`/`jump`/the three assertions are
    /// epsilon transitions — they never appear in a thread list, because
    /// `addThread` follows them to the consuming instructions behind them.
    private enum Inst: Sendable {
        case scalar(Unicode.Scalar)     // already folded when `ignoresCase`
        case any                        // `.` — anything but a line break
        case klass(Int)                 // index into `classes`
        case split(Int, Int)            // try the first target first
        case jump(Int)
        case assertStart                // `^`
        case assertEnd                  // `$`
        case assertBoundary(Bool)       // `\b` (true) / `\B` (false)
        case match
    }

    private struct ScalarRange: Sendable {
        var lo: UInt32
        var hi: UInt32
    }

    private enum Builtin: Sendable {
        case digit, notDigit, word, notWord, space, notSpace
    }

    /// A `[...]` class, or one of the `\d`-family shorthands wearing the same
    /// clothes so the VM has one membership test instead of two.
    private struct CharClass: Sendable {
        var negated = false
        var ranges: [ScalarRange] = []
        var builtins: [Builtin] = []

        /// Case-insensitive membership is tested on the *positive* set and only
        /// then negated, which is why `[^a]` correctly refuses `A`: `A` folds
        /// into the set, so the negation excludes it. Swift `Regex` agrees.
        func matches(_ raw: Unicode.Scalar, _ folded: Unicode.Scalar,
                     _ uppered: Unicode.Scalar, ignoresCase: Bool) -> Bool {
            var hit = contains(raw)
            if ignoresCase && !hit {
                if folded != raw { hit = contains(folded) }
                if !hit && uppered != raw { hit = contains(uppered) }
            }
            return negated ? !hit : hit
        }

        private func contains(_ s: Unicode.Scalar) -> Bool {
            let v = s.value
            for r in ranges where v >= r.lo && v <= r.hi { return true }
            for b in builtins where LinearRegex.matchesBuiltin(b, s) { return true }
            return false
        }
    }

    // MARK: - building

    /// Why a pattern was refused. The find bar shows a different sentence for
    /// each, because they ask different things of the person typing: a broken
    /// pattern is a typo to fix, and an unsupported one needs rewriting with
    /// what this engine does have (`\b` covers most of what lookahead is used
    /// for in a search box).
    public enum Failure: Error, Equatable, Sendable {
        case malformed
        /// A backreference or a lookaround. Not a gap to fill in later: an
        /// automaton with no backtracking cannot remember what an earlier group
        /// matched, which is the whole point of it and the reason a search can
        /// no longer hang.
        case unsupported
        case tooBig
    }

    /// `nil` for anything this engine refuses; `compile` says which.
    ///
    /// There is no fallback behind a refusal — `SearchEngine` has no other
    /// matcher any more — so the find bar reports it ("not supported" / "bad
    /// pattern" / "too complex") and the search does not run. The bar for
    /// ACCEPTING is therefore "we compile it to exactly what `Regex` would
    /// do", not "we can make something of it"; the differential fuzz in
    /// `LinearRegexTests` is what holds that — 200,000 cases on every run,
    /// and 10,000,000 across the seeds it was developed against.
    init?(pattern: String, ignoresCase: Bool) {
        guard let made = try? LinearRegex.compile(pattern: pattern, ignoresCase: ignoresCase) else {
            return nil
        }
        self = made
    }

    static func compile(pattern: String, ignoresCase: Bool) throws -> LinearRegex {
        var parser = Parser(pattern: Array(pattern.unicodeScalars), ignoresCase: ignoresCase)
        let node: Node
        do { node = try parser.parse() } catch { throw LinearRegex.failure(from: error) }
        var emitter = Emitter(classes: parser.classes)
        do { try emitter.emit(node) } catch { throw LinearRegex.failure(from: error) }
        emitter.program.append(.match)
        guard emitter.program.count <= LinearRegex.maxInstructions else { throw Failure.tooBig }
        return LinearRegex(program: emitter.program, classes: emitter.classes, ignoresCase: ignoresCase)
    }

    private init(program: [Inst], classes: [CharClass], ignoresCase: Bool) {
        self.program = program
        self.classes = classes
        self.ignoresCase = ignoresCase
    }

    private static func failure(from error: Error) -> Failure {
        switch error as? ParseError {
        case .unsupported: return .unsupported
        case .tooBig: return .tooBig
        default: return .malformed
        }
    }

    // MARK: - matching

    /// Leftmost, non-overlapping matches, offsets in SCALAR units, empty
    /// matches dropped, at most `limit` of them.
    ///
    /// This is deliberately the same list `SearchEngine.regexRanges` builds
    /// today, including the awkward parts: an empty match is *taken* (it is the
    /// leftmost match at that position, so it decides where the next search
    /// starts) and then discarded from the output, which is what
    /// `String.matches(of:)` followed by `if r.isEmpty { continue }` does.
    /// Whole-word filtering is not here — it stays in the caller, which means
    /// `limit` counts matches BEFORE that filter. See `SearchEngine`'s
    /// `regexRanges` for why that is the right side of the trade.
    func matches(in scalars: [Unicode.Scalar], limit: Int) -> [Range<Int>] {
        matches(in: scalars, limit: limit, budget: Int.max).ranges
    }

    /// The same list, cut short once `budget` thread-steps have been spent
    /// (a step = one thread looked at at one position). `exhausted` says the
    /// list is incomplete. See `SearchEngine.regexBudget` for why a bound is
    /// needed at all on an engine that is linear per match.
    func matches(in scalars: [Unicode.Scalar], limit: Int, budget: Int)
        -> (ranges: [Range<Int>], exhausted: Bool) {
        guard limit > 0 else { return ([], false) }
        var out: [Range<Int>] = []
        var clist = ThreadList(size: program.count)
        var nlist = ThreadList(size: program.count)
        var stack: [Int] = []
        stack.reserveCapacity(program.count)

        var steps = 0
        var i = 0
        while i <= scalars.count && out.count < limit {
            let m = firstMatch(in: scalars, from: i, &clist, &nlist, &stack,
                               steps: &steps, budget: budget)
            // Checked BEFORE the match is used, and on the no-match path too.
            // The first shape of this loop checked only after a match came
            // back, so a search that found nothing — `a{1000}b` over 200,000
            // `a`s, a thousand live threads at every position — ran to the
            // end of the line (3.3 s) with the budget never consulted; and a
            // match returned from a run the budget cut short is not a
            // leftmost-first match, only the best thread seen so far.
            if steps > budget { return (out, true) }
            guard let m else { break }
            if m.isEmpty {
                i = m.lowerBound + 1
            } else {
                out.append(m)
                i = m.upperBound
            }
        }
        return (out, false)
    }

    /// One leftmost-first match at or after `from`, or nil.
    ///
    /// pike.c's shape: seed a new thread at every position until something has
    /// matched, run the whole set one scalar at a time, and when a thread
    /// reaches `.match` record it and drop every thread behind it in the list.
    /// Dropping the tail is the entire difference between "leftmost-longest"
    /// (POSIX) and "leftmost-first" (what a backtracker, and therefore Swift
    /// `Regex`, produces) — the surviving threads are exactly the ones a
    /// backtracker would still have on its stack.
    private func firstMatch(in scalars: [Unicode.Scalar], from: Int,
                            _ clist: inout ThreadList, _ nlist: inout ThreadList,
                            _ stack: inout [Int], steps: inout Int,
                            budget: Int = Int.max) -> Range<Int>? {
        let n = scalars.count
        guard from <= n else { return nil }
        var matched: Range<Int>? = nil
        var pos = from
        clist.clear()

        while true {
            steps += clist.count + 1
            // Enforced here, inside the position loop, or a single call could
            // spend the whole budget many times over before anyone looked.
            // The caller reads `steps` to learn that this happened.
            if steps > budget { break }
            // A new start only while nothing has matched: once it has, the
            // leftmost start is settled and later ones cannot improve on it.
            if matched == nil {
                addThread(&clist, &stack, pc: 0, start: pos, pos: pos, scalars: scalars)
            }
            if clist.count == 0 {
                if matched != nil || pos >= n { break }
                pos += 1
                clist.clear()
                continue
            }

            // Fold once per position, not once per instruction: folding a
            // non-ASCII scalar costs a String round trip inside
            // `SearchEngine.fold`, and a thread set can hold hundreds of pcs.
            var raw = Unicode.Scalar(UInt8(0))
            var folded = Unicode.Scalar(UInt8(0))
            var uppered = Unicode.Scalar(UInt8(0))
            let hasScalar = pos < n
            if hasScalar {
                raw = scalars[pos]
                folded = ignoresCase ? SearchEngine.fold(raw) : raw
                uppered = ignoresCase ? LinearRegex.upper(raw) : raw
            }

            nlist.clear()
            var i = 0
            scan: while i < clist.count {
                let pc = clist.pcs[i]
                let start = clist.starts[i]
                switch program[pc] {
                case .scalar(let c):
                    if hasScalar, folded == c {
                        addThread(&nlist, &stack, pc: pc + 1, start: start,
                                  pos: pos + 1, scalars: scalars)
                    }
                case .any:
                    if hasScalar, !LinearRegex.isLineBreak(raw) {
                        addThread(&nlist, &stack, pc: pc + 1, start: start,
                                  pos: pos + 1, scalars: scalars)
                    }
                case .klass(let k):
                    if hasScalar,
                       classes[k].matches(raw, folded, uppered, ignoresCase: ignoresCase) {
                        addThread(&nlist, &stack, pc: pc + 1, start: start,
                                  pos: pos + 1, scalars: scalars)
                    }
                case .match:
                    matched = start..<pos
                    break scan          // everything behind this is lower priority
                default:
                    break               // epsilon: `addThread` never leaves one here
                }
                i += 1
            }

            swap(&clist, &nlist)
            if pos >= n { break }
            pos += 1
        }
        return matched
    }

    /// Follow every epsilon transition out of `pc` and leave the consuming
    /// instructions behind them in `list`, in priority order.
    ///
    /// Explicit stack, not recursion: `a{1000}` compiles to a chain a thousand
    /// deep and a `(?:x)*` loop can chase further, which is more than we want
    /// on a display-link thread's stack. Pushing a `split`'s second target
    /// first makes the pop order a depth-first preorder walk, which is exactly
    /// the order a backtracker would try the branches in. The per-position mark
    /// is claimed at pop, so the first (highest-priority) arrival at a state
    /// keeps it — and it is what makes an empty loop like `(?:a?)*` terminate
    /// instead of spinning.
    private func addThread(_ list: inout ThreadList, _ stack: inout [Int],
                           pc: Int, start: Int, pos: Int, scalars: [Unicode.Scalar]) {
        stack.removeAll(keepingCapacity: true)
        stack.append(pc)
        while let current = stack.popLast() {
            guard list.claim(current) else { continue }
            switch program[current] {
            case .jump(let t):
                stack.append(t)
            case .split(let a, let b):
                stack.append(b)
                stack.append(a)
            case .assertStart:
                if pos == 0 { stack.append(current + 1) }
            case .assertEnd:
                if pos == scalars.count { stack.append(current + 1) }
            case .assertBoundary(let want):
                if LinearRegex.isWordBoundary(at: pos, in: scalars) == want {
                    stack.append(current + 1)
                }
            case .scalar, .any, .klass, .match:
                list.append(current, start)
            }
        }
    }

    /// The live thread set for one input position: pcs in priority order plus a
    /// generation-stamped mark per pc, so `clear()` is O(1) and membership is
    /// O(1) — the sparse-set trick that keeps a step linear in the *reachable*
    /// states rather than in the program.
    private struct ThreadList {
        var pcs: [Int]
        var starts: [Int]
        var marks: [Int]
        var count = 0
        var generation = 0

        init(size: Int) {
            pcs = Array(repeating: 0, count: size)
            starts = Array(repeating: 0, count: size)
            marks = Array(repeating: 0, count: size)
        }

        mutating func clear() {
            count = 0
            generation += 1
        }

        mutating func claim(_ pc: Int) -> Bool {
            if marks[pc] == generation { return false }
            marks[pc] = generation
            return true
        }

        mutating func append(_ pc: Int, _ start: Int) {
            pcs[count] = pc
            starts[count] = start
            count += 1
        }
    }

    // MARK: - scalar predicates

    /// What `.` refuses. Swift `Regex` without `dotMatchesNewlines` excludes all
    /// seven Unicode line breaks, not just `\n`; each of the seven was checked
    /// against it one at a time, and `dotStopsAtLineBreaks` holds the result.
    /// (The fuzz cannot: a logical line never contains a line break, so the
    /// generator does not put one in the text either.)
    @inline(__always)
    static func isLineBreak(_ s: Unicode.Scalar) -> Bool {
        switch s.value {
        case 0x0A, 0x0B, 0x0C, 0x0D, 0x85, 0x2028, 0x2029: return true
        default: return false
        }
    }

    /// `\b` / `\B`: a word scalar on exactly one side. The classic rule —
    /// PCRE's, ripgrep's, JavaScript's, Python's.
    ///
    /// This is the ONE construct where agreeing with Swift `Regex` was not
    /// possible, and the reason is that neither of its two word-boundary kinds
    /// implements that rule. Measured positions of `\b`:
    ///
    ///     text     classic    Regex .default    Regex .simple
    ///     "1a"     0, 2       0, 2              1, 2
    ///     "a1b"    0, 3       0, 3              0, 1, 2, 3
    ///     "12 34"  0,2,3,5    0, 2, 3, 5        (none)
    ///     "a'b"    0,1,2,3    0, 3              0, 1, 2, 3
    ///     "🙂a"     1, 2       0, 1, 2           1, 2
    ///     ""       (none)     0                 (none)
    ///
    /// Both kinds are UAX #29 flavoured, in different directions, and both do
    /// things a network engineer searching `show run` output would file as a
    /// bug: `.simple` finds no boundary at all in `12 34`, `.default` finds one
    /// inside `a1b`'s neighbours and one in the empty string. So `\b` here is
    /// the rule everyone else implements, `LinearRegexTests` pins it down with a
    /// table instead of the differential fuzz, and the fuzz's generator does not
    /// emit `\b` — an oracle this far from the rest of the field cannot settle
    /// anything. Integrating this engine therefore CHANGES `\b` in the find bar,
    /// towards what the pattern means everywhere else.
    @inline(__always)
    static func isWordBoundary(at pos: Int, in scalars: [Unicode.Scalar]) -> Bool {
        let before = pos > 0 && isWord(scalars[pos - 1])
        let after = pos < scalars.count && isWord(scalars[pos])
        return before != after
    }

    /// What `\w`, `\W` and both boundary assertions call a word scalar.
    ///
    /// NOT `SearchEngine.isWordScalar`, deliberately, and the difference was
    /// measured rather than assumed: Swift `Regex` counts Alphabetic, ASCII
    /// digits and `_`, and nothing else — a Thai digit `๑` (U+0E51) is `\d` but
    /// not `\w`, and neither is `²`. `SearchEngine.isWordScalar` calls both of
    /// those word characters, which is the right answer for the find bar's
    /// whole-word checkbox and the wrong one for `\w`. The two rules stay
    /// separate: whole-word filtering is applied by the caller, after us.
    ///
    /// Swift's own `\w` does not quite implement its own rule — it drops an
    /// ASCII digit or `_` that sits immediately before a scalar of three or
    /// more UTF-8 bytes, so `\w+` over `12ก` finds `1` and `ก`. That is a
    /// stdlib bug, not a semantic choice; we implement the rule as written.
    /// `theStdlibWordShorthandBug` has the evidence.
    @inline(__always)
    static func isWord(_ s: Unicode.Scalar) -> Bool {
        let v = s.value
        if v < 128 {
            return (v >= 97 && v <= 122) || (v >= 65 && v <= 90)
                || (v >= 48 && v <= 57) || v == 95
        }
        return s.properties.isAlphabetic
    }

    @inline(__always)
    private static func matchesBuiltin(_ b: Builtin, _ s: Unicode.Scalar) -> Bool {
        switch b {
        case .digit: return isDigit(s)
        case .notDigit: return !isDigit(s)
        case .word: return isWord(s)
        case .notWord: return !isWord(s)
        case .space: return isSpace(s)
        case .notSpace: return !isSpace(s)
        }
    }

    /// `\d` is Unicode Nd, not ASCII — Swift `Regex` matches Thai `๑` and so
    /// must we.
    @inline(__always)
    private static func isDigit(_ s: Unicode.Scalar) -> Bool {
        let v = s.value
        if v < 128 { return v >= 48 && v <= 57 }
        return s.properties.numericType == .decimal
    }

    @inline(__always)
    private static func isSpace(_ s: Unicode.Scalar) -> Bool {
        let v = s.value
        if v < 128 { return v == 32 || (v >= 9 && v <= 13) }
        return s.properties.isWhitespace
    }

    /// The mirror of `SearchEngine.fold`, and needed for the same reason: a
    /// class written `[A-Z]` has to answer for a lowercase input under
    /// `ignoresCase`, and folding the *class* would be wrong. A scalar whose
    /// uppercase form is not exactly one scalar is left alone, so offsets can
    /// never drift.
    @inline(__always)
    static func upper(_ s: Unicode.Scalar) -> Unicode.Scalar {
        let v = s.value
        if v < 128 {
            if v >= 97 && v <= 122 { return Unicode.Scalar(v - 32)! }
            return s
        }
        guard s.properties.changesWhenUppercased else { return s }
        let raised = String(s).uppercased().unicodeScalars
        if raised.count == 1, let first = raised.first { return first }
        return s
    }
}

// MARK: - the parser

extension LinearRegex {

    /// Everything that makes us hand the pattern back to `Regex`. The cases are
    /// named so a future reader can tell "we refuse this" from "this is broken".
    private enum ParseError: Error {
        case malformed
        case unsupported          // backreference, lookaround, unknown escape
        case tooBig
    }

    /// The syntax tree. Captures are not modelled: search wants ranges, so
    /// `(...)` and `(?:...)` compile identically.
    private indirect enum Node {
        case empty
        case scalar(Unicode.Scalar)
        case any
        case klass(Int)
        case assertStart
        case assertEnd
        case assertBoundary(Bool)
        case concat([Node])
        case alternate([Node])
        case repeated(Node, min: Int, max: Int?, greedy: Bool)
    }

    /// Recursive descent over the pattern's scalars.
    ///
    ///     alternation := concat ('|' concat)*
    ///     concat      := quantified*
    ///     quantified  := atom quantifier*
    ///     quantifier  := ('*' | '+' | '?' | '{' n [',' [m]] '}') '?'?
    ///     atom        := '(' ['?:'] alternation ')' | '[' class ']'
    ///                  | '.' | '^' | '$' | '\' escape | literal
    private struct Parser {
        let pattern: [Unicode.Scalar]
        let ignoresCase: Bool
        var i = 0
        var classes: [CharClass] = []
        /// Nesting depth, checked on the way in and released on the way out.
        private var depth = 0

        init(pattern: [Unicode.Scalar], ignoresCase: Bool) {
            self.pattern = pattern
            self.ignoresCase = ignoresCase
        }

        mutating func parse() throws -> Node {
            let node = try parseAlternation()
            guard i == pattern.count else { throw ParseError.malformed }
            return node
        }

        private mutating func parseAlternation() throws -> Node {
            var branches = [try parseConcat()]
            while i < pattern.count, pattern[i] == "|" {
                i += 1
                branches.append(try parseConcat())
            }
            return branches.count == 1 ? branches[0] : .alternate(branches)
        }

        private mutating func parseConcat() throws -> Node {
            var parts: [Node] = []
            while i < pattern.count, pattern[i] != "|", pattern[i] != ")" {
                parts.append(try parseQuantified())
            }
            if parts.isEmpty { return .empty }
            return parts.count == 1 ? parts[0] : .concat(parts)
        }

        private mutating func parseQuantified() throws -> Node {
            var node = try parseAtom()
            // A loop, not an `if`: `a{2}{3}` and `a*?` both chain, and the
            // instruction cap — not the grammar — is what refuses the silly
            // ones like `a{1000}{1000}`.
            //
            // This is a CHOICE, and it is not what every engine does: PCRE and
            // Python read `a?+` and `a*+` as possessive quantifiers, and some
            // reject a doubled quantifier outright. Chaining is the reading
            // that needs no new concept and cannot backtrack (there is nothing
            // possessive to be possessive about in an automaton), but a pattern
            // written for a possessive engine will mean something else here.
            // A differential fuzz against Python's `re` found 118 cases of
            // exactly this and nothing else in that class.
            var chained = 0
            while i < pattern.count, let q = try parseQuantifier() {
                chained += 1
                guard chained <= LinearRegex.maxQuantifierChain else { throw ParseError.tooBig }
                node = .repeated(node, min: q.min, max: q.max, greedy: q.greedy)
            }
            return node
        }

        private mutating func parseQuantifier() throws -> (min: Int, max: Int?, greedy: Bool)? {
            guard i < pattern.count else { return nil }
            var lo = 0
            var hi: Int?
            switch pattern[i] {
            case "*": lo = 0; hi = nil; i += 1
            case "+": lo = 1; hi = nil; i += 1
            case "?": lo = 0; hi = 1; i += 1
            case "{":
                // `{` is only a quantifier when a digit follows it; otherwise it
                // is a literal brace, which is how `Regex` reads `a{` and
                // `a{,3}` and how anyone grepping JSON expects it to read.
                guard i + 1 < pattern.count, isASCIIDigit(pattern[i + 1]) else { return nil }
                var j = i + 1
                guard let n = try readNumber(&j) else { throw ParseError.malformed }
                lo = n
                hi = n
                if j < pattern.count, pattern[j] == "," {
                    j += 1
                    if j < pattern.count, isASCIIDigit(pattern[j]) {
                        guard let m = try readNumber(&j) else { throw ParseError.malformed }
                        hi = m
                    } else {
                        hi = nil
                    }
                }
                guard j < pattern.count, pattern[j] == "}" else { throw ParseError.malformed }
                if let hi, hi < lo { throw ParseError.malformed }
                i = j + 1
            default:
                return nil
            }
            var greedy = true
            if i < pattern.count, pattern[i] == "?" {
                greedy = false
                i += 1
            }
            return (lo, hi, greedy)
        }

        private mutating func readNumber(_ j: inout Int) throws -> Int? {
            var value = 0
            var digits = 0
            while j < pattern.count, isASCIIDigit(pattern[j]) {
                value = value * 10 + Int(pattern[j].value - 48)
                digits += 1
                // `nil` here means "not a quantifier", which the caller turns
                // into `.malformed`. A repeat count that is simply too large is
                // not malformed, though: `a{100001}` used to read "bad pattern"
                // while `a{100000}` read "too complex", for one digit.
                // Value, not digit count. The value is checked after every
                // digit, so it can never exceed maxRepeat * 10 + 9 and there is
                // nothing to overflow — while counting digits refused
                // `a{00000001}`, which is eight characters asking for one.
                if value > LinearRegex.maxRepeat { throw ParseError.tooBig }
                j += 1
            }
            return digits > 0 ? value : nil
        }

        private mutating func parseAtom() throws -> Node {
            guard i < pattern.count else { throw ParseError.malformed }
            let c = pattern[i]
            switch c {
            case "(":
                i += 1
                if i < pattern.count, pattern[i] == "?" {
                    // `(?:` is the only group flavour we take. Everything else
                    // behind `(?` is lookaround, a named group or an inline
                    // flag — all of which would change the answer if we guessed.
                    guard i + 1 < pattern.count, pattern[i + 1] == ":" else {
                        throw ParseError.unsupported
                    }
                    i += 2
                }
                depth += 1
                guard depth <= LinearRegex.maxDepth else { throw ParseError.tooBig }
                let inner = try parseAlternation()
                depth -= 1
                guard i < pattern.count, pattern[i] == ")" else { throw ParseError.malformed }
                i += 1
                return inner
            case ")":
                throw ParseError.malformed
            case "[":
                return .klass(try parseClass())
            case ".":
                i += 1
                return .any
            case "^":
                i += 1
                return .assertStart
            case "$":
                i += 1
                return .assertEnd
            case "*", "+", "?":
                throw ParseError.malformed         // a quantifier with nothing to quantify
            case "\\":
                return try parseEscape()
            default:
                i += 1
                return .scalar(literal(c))
            }
        }

        /// A literal is stored folded when `ignoresCase`, so the VM compares one
        /// folded scalar against one folded scalar.
        private func literal(_ c: Unicode.Scalar) -> Unicode.Scalar {
            ignoresCase ? SearchEngine.fold(c) : c
        }

        private mutating func parseEscape() throws -> Node {
            i += 1
            guard i < pattern.count else { throw ParseError.malformed }
            let c = pattern[i]
            i += 1
            switch c {
            case "d": return .klass(addClass(builtin: .digit))
            case "D": return .klass(addClass(builtin: .notDigit))
            case "w": return .klass(addClass(builtin: .word))
            case "W": return .klass(addClass(builtin: .notWord))
            case "s": return .klass(addClass(builtin: .space))
            case "S": return .klass(addClass(builtin: .notSpace))
            case "b": return .assertBoundary(true)
            case "B": return .assertBoundary(false)
            case "n": return .scalar("\n")
            case "t": return .scalar("\t")
            case "r": return .scalar("\r")
            case "f": return .scalar(Unicode.Scalar(0x0C)!)
            case "v": return .scalar(Unicode.Scalar(0x0B)!)
            case "0": return .scalar(Unicode.Scalar(0)!)
            default:
                // `\1`…`\9` is a backreference; a letter is some construct we do
                // not know (`\A`, `\p{…}`, `\u{…}`). Both are the caller's cue
                // to fall back. Punctuation is a plain escaped metacharacter.
                if isASCIIDigit(c) || isASCIILetter(c) { throw ParseError.unsupported }
                return .scalar(literal(c))
            }
        }

        private mutating func addClass(builtin: Builtin) -> Int {
            classes.append(CharClass(negated: false, ranges: [], builtins: [builtin]))
            return classes.count - 1
        }

        /// `[...]`, with ranges, negation and escapes inside.
        ///
        /// A `]` always closes the class, so `[]` and `[]]` are malformed here
        /// rather than quietly meaning something. `Regex` disagrees about
        /// `[]]`; nil sends it to `Regex`, which is the right outcome for a
        /// corner nobody types on purpose.
        private mutating func parseClass() throws -> Int {
            i += 1                                  // the '['
            var cls = CharClass()
            if i < pattern.count, pattern[i] == "^" {
                cls.negated = true
                i += 1
            }
            var items = 0
            while true {
                guard i < pattern.count else { throw ParseError.malformed }
                if pattern[i] == "]" {
                    i += 1
                    break
                }
                guard let lo = try parseClassItem(&cls) else {
                    items += 1                      // a `\d`-style shorthand, no range
                    continue
                }
                // A '-' that is not last inside the class starts a range.
                if i + 1 < pattern.count, pattern[i] == "-", pattern[i + 1] != "]" {
                    i += 1
                    guard let hi = try parseClassItem(&cls) else {
                        throw ParseError.malformed  // `[a-\d]`
                    }
                    guard lo.value <= hi.value else { throw ParseError.malformed }
                    cls.ranges.append(ScalarRange(lo: lo.value, hi: hi.value))
                } else {
                    cls.ranges.append(ScalarRange(lo: lo.value, hi: lo.value))
                }
                items += 1
            }
            guard items > 0 else { throw ParseError.malformed }
            classes.append(cls)
            return classes.count - 1
        }

        /// One member of a class. Returns the scalar for a single character, or
        /// nil when the item was a shorthand it appended to `cls` itself (which
        /// therefore cannot be a range endpoint).
        private mutating func parseClassItem(_ cls: inout CharClass) throws -> Unicode.Scalar? {
            guard i < pattern.count else { throw ParseError.malformed }
            let c = pattern[i]
            if c != "\\" {
                i += 1
                return c
            }
            i += 1
            guard i < pattern.count else { throw ParseError.malformed }
            let e = pattern[i]
            i += 1
            switch e {
            case "d": cls.builtins.append(.digit); return nil
            case "D": cls.builtins.append(.notDigit); return nil
            case "w": cls.builtins.append(.word); return nil
            case "W": cls.builtins.append(.notWord); return nil
            case "s": cls.builtins.append(.space); return nil
            case "S": cls.builtins.append(.notSpace); return nil
            case "n": return "\n"
            case "t": return "\t"
            case "r": return "\r"
            case "f": return Unicode.Scalar(0x0C)!
            case "v": return Unicode.Scalar(0x0B)!
            case "0": return Unicode.Scalar(0)!
            default:
                // `[\b]` is a backspace in some engines and a boundary in
                // others; we decline rather than pick. Same for `\1` and `\p`.
                if isASCIIDigit(e) || isASCIILetter(e) { throw ParseError.unsupported }
                return e
            }
        }

        private func isASCIIDigit(_ s: Unicode.Scalar) -> Bool { s.value >= 48 && s.value <= 57 }

        private func isASCIILetter(_ s: Unicode.Scalar) -> Bool {
            (s.value >= 65 && s.value <= 90) || (s.value >= 97 && s.value <= 122)
        }
    }
}

// MARK: - the emitter

extension LinearRegex {

    /// Tree to program. Nothing clever: the only thing worth watching is that
    /// every append is checked against `maxInstructions`, because counted
    /// repetition is expanded and that is where a pattern can ask for a
    /// megabyte of program.
    private struct Emitter {
        var program: [Inst] = []
        var classes: [CharClass]

        /// Expansion steps taken, capped separately from the program length.
        /// A repeat whose body emits nothing — `(?:){4000}{4000}` — grows no
        /// program at all, so the instruction cap never fires and the loops
        /// alone would run 16 million times. This is what refuses it.
        private var work = 0

        init(classes: [CharClass]) {
            self.classes = classes
        }

        private mutating func spend() throws {
            work += 1
            guard work <= LinearRegex.maxInstructions * 4 else { throw ParseError.tooBig }
        }

        private mutating func append(_ inst: Inst) throws -> Int {
            guard program.count < LinearRegex.maxInstructions else { throw ParseError.tooBig }
            program.append(inst)
            return program.count - 1
        }

        mutating func emit(_ node: Node) throws {
            switch node {
            case .empty:
                break
            case .scalar(let c):
                _ = try append(.scalar(c))
            case .any:
                _ = try append(.any)
            case .klass(let k):
                _ = try append(.klass(k))
            case .assertStart:
                _ = try append(.assertStart)
            case .assertEnd:
                _ = try append(.assertEnd)
            case .assertBoundary(let want):
                _ = try append(.assertBoundary(want))
            case .concat(let parts):
                for p in parts { try emit(p) }
            case .alternate(let branches):
                try emitAlternate(branches)
            case .repeated(let inner, let min, let max, let greedy):
                try emitRepeat(inner, min: min, max: max, greedy: greedy)
            }
        }

        /// `a|b|c` → split(a, split(b, c)), branches in source order so the
        /// leftmost alternative keeps the highest priority.
        private mutating func emitAlternate(_ branches: [Node]) throws {
            var jumps: [Int] = []
            for (index, branch) in branches.enumerated() {
                if index == branches.count - 1 {
                    try emit(branch)
                } else {
                    let split = try append(.split(0, 0))
                    program[split] = .split(split + 1, 0)
                    try emit(branch)
                    jumps.append(try append(.jump(0)))
                    if case .split(let a, _) = program[split] {
                        program[split] = .split(a, program.count)
                    }
                }
            }
            let end = program.count
            for j in jumps { program[j] = .jump(end) }
        }

        private mutating func emitRepeat(_ node: Node, min: Int, max: Int?,
                                         greedy: Bool) throws {
            if let max, max == 0 { return }

            // The mandatory prefix. `a{3,}` is `aa` then `a+`, and `a{3,5}` is
            // `aaa` then two optionals — expansion, because a counted repeat is
            // not expressible in Thompson's instruction set without it.
            let mandatory = max == nil ? Swift.max(min - 1, 0) : min
            for _ in 0..<mandatory {
                try spend()
                try emit(node)
            }

            if max == nil {
                if min == 0 {
                    try emitStar(node, greedy: greedy)
                } else {
                    try emitPlus(node, greedy: greedy)
                }
                return
            }

            // `{min,max}`: `max - min` optionals, every exit jumping past all of
            // them. Nested `(?:a(?:a)?)?` would work too and costs the same
            // instructions; the flat form keeps the patch-up loop readable.
            let optional = max! - min
            guard optional >= 0 else { throw ParseError.malformed }
            var splits: [Int] = []
            for _ in 0..<optional {
                try spend()
                let split = try append(.split(0, 0))
                splits.append(split)
                try emit(node)
            }
            let end = program.count
            for s in splits {
                program[s] = greedy ? .split(s + 1, end) : .split(end, s + 1)
            }
        }

        /// `L1: split(L2, L3); L2: node; jump L1; L3:`
        private mutating func emitStar(_ node: Node, greedy: Bool) throws {
            let split = try append(.split(0, 0))
            try emit(node)
            _ = try append(.jump(split))
            let end = program.count
            program[split] = greedy ? .split(split + 1, end) : .split(end, split + 1)
        }

        /// `L1: node; split(L1, L3); L3:` — one copy of the body, not two, which
        /// matters when the body is itself a counted repeat.
        private mutating func emitPlus(_ node: Node, greedy: Bool) throws {
            let body = program.count
            try emit(node)
            let split = try append(.split(0, 0))
            let end = program.count
            program[split] = greedy ? .split(body, end) : .split(end, body)
        }
    }
}
