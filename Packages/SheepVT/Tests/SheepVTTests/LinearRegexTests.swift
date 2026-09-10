// LinearRegexTests.swift — SheepVT
//
// Three kinds of test, because the engine has three ways to be wrong.
//
//  1. Directed cases pin the subset down construct by construct, and the scalar
//     UNIT down with Thai and emoji — an engine that quietly counted UTF-16 or
//     graphemes would still pass every ASCII test in this file, and would put
//     the find bar's highlight on the wrong cells the first time a device
//     printed a Thai hostname.
//
//  2. A differential fuzz against Swift `Regex` — 200,000 (pattern, text) pairs
//     by default. This is the only honest proof that the greedy/lazy priority
//     rules agree; leftmost-first is a claim about WHICH match wins, and no
//     amount of arguing about split ordering settles it. The oracle is pinned
//     to `.matchingSemantics(.unicodeScalar)`
//     because those are the semantics `LinearRegex` implements. The generator
//     never puts a quantifier around a group that already contains one: the
//     oracle is a backtracker, and a hung oracle proves nothing. It also never
//     emits `\b` — see `boundaryPositionsFollowTheClassicRule`.
//
//  3. Timing on the patterns that are the entire reason this file exists.
//     `(a+)+b` is not slow here; it is not even measurable at this length.
//
// Long soak:  SHEEPVT_REGEX_CASES=5000000 ./Tests/run.sh vt -c release --filter LinearRegex

import Foundation
import Testing

@testable import SheepVT

// MARK: - helpers

private func scalars(_ s: String) -> [Unicode.Scalar] { Array(s.unicodeScalars) }

/// Our answer, as `[lower, upper]` pairs of scalar offsets.
private func ours(_ pattern: String, _ text: String,
                  ignoresCase: Bool = false, limit: Int = 1000) -> [[Int]]? {
    guard let rx = LinearRegex(pattern: pattern, ignoresCase: ignoresCase) else { return nil }
    return rx.matches(in: scalars(text), limit: limit).map { [$0.lowerBound, $0.upperBound] }
}

/// Swift `Regex`'s answer, built exactly the way `SearchEngine.regexRanges`
/// builds its own list (empty matches dropped, offsets measured in scalars) but
/// at the scalar semantic level `LinearRegex` implements.
private func oracle(_ regex: Regex<AnyRegexOutput>, _ text: String,
                    limit: Int = 1000) -> [[Int]] {
    var out: [[Int]] = []
    let view = text.unicodeScalars
    for m in text.matches(of: regex) {
        let r = m.range
        if r.isEmpty { continue }
        let lo = view.distance(from: view.startIndex, to: r.lowerBound)
        let hi = view.distance(from: view.startIndex, to: r.upperBound)
        out.append([lo, hi])
        if out.count >= limit { break }
    }
    return out
}

private func oracleRegex(_ pattern: String, ignoresCase: Bool) -> Regex<AnyRegexOutput>? {
    guard let rx = try? Regex(pattern) else { return nil }
    return rx
        .matchingSemantics(.unicodeScalar)
        .ignoresCase(ignoresCase)
}

/// Deterministic PRNG (SplitMix64), the same one `SearchTests` uses, so a fuzz
/// failure is reproducible from the seed printed with it.
private struct RegexRNG {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func below(_ n: Int) -> Int { n <= 0 ? 0 : Int(next() % UInt64(n)) }
    mutating func pick<T>(_ xs: [T]) -> T { xs[below(xs.count)] }
}

// MARK: - the subset, construct by construct

@Suite("LinearRegex subset")
struct LinearRegexSubsetTests {

    @Test func literalsAndNonOverlap() {
        #expect(ours("abc", "xxabcxxabc")! == [[2, 5], [7, 10]])
        #expect(ours("aa", "aaaa")! == [[0, 2], [2, 4]])   // non-overlapping
        #expect(ours("z", "abc")! == [])
        #expect(ours("", "abc")! == [])                    // all matches empty
    }

    @Test func dotStopsAtLineBreaks() {
        #expect(ours(".", "ab")! == [[0, 1], [1, 2]])
        #expect(ours(".", "a\nb")! == [[0, 1], [2, 3]])
        #expect(ours(".", "\r\u{0B}\u{0C}\u{85}\u{2028}\u{2029}")! == [])
        #expect(ours("a.c", "a\nc")! == [])
    }

    @Test func characterClasses() {
        #expect(ours("[abc]", "xbxc")! == [[1, 2], [3, 4]])
        #expect(ours("[a-c]+", "zabcz")! == [[1, 4]])
        #expect(ours("[^a-c]+", "zabcz")! == [[0, 1], [4, 5]])
        #expect(ours("[-a]+", "-a-")! == [[0, 3]])          // '-' first is a literal
        #expect(ours("[a-]+", "-a-")! == [[0, 3]])          // '-' last is a literal
        #expect(ours("[\\]]", "]")! == [[0, 1]])
        #expect(ours("[\\d]+", "a12b")! == [[1, 3]])
        #expect(ours("[\\dx]+", "a1x2b")! == [[1, 4]])
        #expect(ours("[^\\d]+", "a12b")! == [[0, 1], [3, 4]])
        #expect(ours("[\\t\\n]+", "a\t\nb")! == [[1, 3]])
    }

    @Test func shorthands() {
        #expect(ours("\\d+", "ab123cd45")! == [[2, 5], [7, 9]])
        #expect(ours("\\D+", "ab12")! == [[0, 2]])
        #expect(ours("\\w+", "hi_there!x")! == [[0, 8], [9, 10]])
        #expect(ours("\\W", "a b")! == [[1, 2]])
        #expect(ours("\\s+", "a \t b")! == [[1, 4]])
        #expect(ours("\\S+", " ab ")! == [[1, 3]])
        // `\d` is Unicode Nd, not ASCII — Swift Regex matches Thai digits too.
        #expect(ours("\\d", "\u{0E51}")! == [[0, 1]])
    }

    @Test func anchors() {
        #expect(ours("^ab", "abab")! == [[0, 2]])
        #expect(ours("ab$", "abab")! == [[2, 4]])
        #expect(ours("^abab$", "abab")! == [[0, 4]])
        #expect(ours("^", "abc")! == [])                    // empty, dropped
        #expect(ours("^a", "ba")! == [])
        // `$` is end of input, not "before a trailing newline".
        #expect(ours("a$", "a\n")! == [])
        #expect(ours("a$", "a")! == [[0, 1]])
    }

    @Test func wordBoundariesAtBothEnds() {
        #expect(ours("\\bab\\b", "ab")! == [[0, 2]])
        #expect(ours("\\bab\\b", "xab")! == [])
        #expect(ours("\\bab\\b", "abx")! == [])
        #expect(ours("\\bab\\b", " ab ")! == [[1, 3]])
        #expect(ours("\\b\\w+", "one two")! == [[0, 3], [4, 7]])
        #expect(ours("\\Bb", "ab b")! == [[1, 2]])
        #expect(ours("\\B", "ab")! == [])                   // empty, dropped
        #expect(ours("a\\b", "a_")! == [])                  // '_' is a word scalar
    }

    /// `\b` is the one construct with no usable oracle: `Regex`'s `.default`
    /// kind puts a boundary inside `🙂a` and at position 0 of the empty string,
    /// and its `.simple` kind finds none at all in `12 34` and one between
    /// every pair of characters in `a1b`. Both were measured, both are in the
    /// engine's comment, and this is the rule we implement instead — the one
    /// PCRE, ripgrep, JavaScript and Python all agree on.
    @Test func boundaryPositionsFollowTheClassicRule() {
        func positions(_ text: String) -> [Int] {
            let sc = scalars(text)
            return (0...sc.count).filter { LinearRegex.isWordBoundary(at: $0, in: sc) }
        }
        #expect(positions("") == [])
        #expect(positions("a") == [0, 1])
        #expect(positions("ab") == [0, 2])
        #expect(positions("1a") == [0, 2])          // digits and letters are one word
        #expect(positions("a1b") == [0, 3])
        #expect(positions("12 34") == [0, 2, 3, 5])
        #expect(positions("a_b") == [0, 3])         // '_' is a word scalar
        #expect(positions("a'b") == [0, 1, 2, 3])   // an apostrophe is not
        #expect(positions(" a ") == [1, 2])
        #expect(positions("🙂a") == [1, 2])          // emoji are not word scalars
        #expect(positions("ก a") == [0, 1, 2, 3])   // Thai letters are
        #expect(positions("aก1_") == [0, 4])
    }

    @Test func groupsAndAlternation() {
        #expect(ours("(ab)+", "ababx")! == [[0, 4]])
        #expect(ours("(?:ab)+", "ababx")! == [[0, 4]])
        #expect(ours("a|b", "ba")! == [[0, 1], [1, 2]])
        #expect(ours("(a|b)c", "ac bc")! == [[0, 2], [3, 5]])
        #expect(ours("x(|a)y", "xy xay")! == [[0, 2], [3, 6]])
        // Leftmost beats alternation order; alternation order beats length.
        #expect(ours("ab|a", "ab")! == [[0, 2]])
        #expect(ours("a|ab", "ab")! == [[0, 1]])
        #expect(ours("b|ab", "ab")! == [[0, 2]])
    }

    @Test func greedyVersusLazy() {
        #expect(ours("a.*b", "axbxb")! == [[0, 5]])
        #expect(ours("a.*?b", "axbxb")! == [[0, 3]])
        #expect(ours("a+", "aaa")! == [[0, 3]])
        #expect(ours("a+?", "aaa")! == [[0, 1], [1, 2], [2, 3]])
        #expect(ours("a?", "aa")! == [[0, 1], [1, 2]])
        #expect(ours("a??b", "ab")! == [[0, 2]])             // lazy still has to reach 'b'
        #expect(ours("<.+>", "<a><b>")! == [[0, 6]])
        #expect(ours("<.+?>", "<a><b>")! == [[0, 3], [3, 6]])
    }

    @Test func countedRepetitionEdges() {
        #expect(ours("a{0}", "aaa")! == [])                  // matches empty, dropped
        #expect(ours("a{1}", "aa")! == [[0, 1], [1, 2]])
        #expect(ours("a{3}", "aaaa")! == [[0, 3]])
        #expect(ours("a{2,}", "aaaa")! == [[0, 4]])
        #expect(ours("a{2,}?", "aaaa")! == [[0, 2], [2, 4]])
        #expect(ours("a{2,3}", "aaaa")! == [[0, 3]])
        #expect(ours("a{2,3}?", "aaaa")! == [[0, 2], [2, 4]])
        #expect(ours("a{0,2}b", "b ab aab aaab")! == [[0, 1], [2, 4], [5, 8], [10, 13]])
        #expect(ours("a{2,2}", "aaa")! == [[0, 2]])
        #expect(ours("(ab){2}", "ababab")! == [[0, 4]])
        // `{` with no digit behind it is a literal brace, the way Regex reads it.
        #expect(ours("a{", "a{")! == [[0, 2]])
        #expect(ours("{\"k\"", "{\"k\":1")! == [[0, 4]])
    }

    @Test func escapedMetacharacters() {
        #expect(ours("a\\.b", "a.b axb")! == [[0, 3]])
        #expect(ours("\\(a\\)", "(a)")! == [[0, 3]])
        #expect(ours("\\[a\\]", "[a]")! == [[0, 3]])
        #expect(ours("a\\*", "a*")! == [[0, 2]])
        #expect(ours("a\\\\b", "a\\b")! == [[0, 3]])
        #expect(ours("\\$\\^", "$^")! == [[0, 2]])
        #expect(ours("\\{2\\}", "{2}")! == [[0, 3]])
    }

    @Test func caseFolding() {
        #expect(ours("abc", "ABC", ignoresCase: true)! == [[0, 3]])
        #expect(ours("ABC", "abc", ignoresCase: true)! == [[0, 3]])
        #expect(ours("abc", "ABC", ignoresCase: false)! == [])
        #expect(ours("[a-z]+", "ABC", ignoresCase: true)! == [[0, 3]])
        #expect(ours("[A-Z]+", "abc", ignoresCase: true)! == [[0, 3]])
        #expect(ours("[^a]", "A", ignoresCase: true)! == [])   // folds into the set
        #expect(ours("[^a]", "b", ignoresCase: true)! == [[0, 1]])
        // The Kelvin sign folds to 'k' in `SearchEngine.fold`, as it does in Regex.
        #expect(ours("k", "\u{212A}", ignoresCase: true)! == [[0, 1]])
    }

    @Test func offsetsAreScalarsNotBytesOrGraphemes() {
        // Thai: three scalars, nine UTF-8 bytes. A byte-counting engine would
        // report [3,6] for the middle one.
        #expect(ours("ข", "กขค")! == [[1, 2]])
        #expect(ours(".", "กขค")! == [[0, 1], [1, 2], [2, 3]])
        #expect(ours("[ก-ฮ]+", "aกขคb")! == [[1, 4]])
        #expect(ours("\\w+", "สวัสดี")! == [[0, 6]])          // Thai vowel signs are Alphabetic
        #expect(ours("\\w+", "ก\u{0E48}ข")! == [[0, 1], [2, 3]])  // a tone mark is not \w

        // Emoji outside the BMP: one scalar, two UTF-16 units. A UTF-16 engine
        // would report [3,5] for the 'b'.
        #expect(ours("b", "a🙂b")! == [[2, 3]])
        #expect(ours(".", "a🙂b")! == [[0, 1], [1, 2], [2, 3]])
        #expect(ours("🙂+", "a🙂🙂b")! == [[1, 3]])
        #expect(ours("\\W", "a🙂")! == [[1, 2]])

        // Scalar semantics, deliberately: `.` takes the combining mark on its
        // own, where a grapheme-level engine would swallow both at once. This
        // is the one place `LinearRegex` and the app's current `Regex` path
        // (which runs at the default grapheme level) do not agree.
        #expect(ours("e.", "e\u{301}x")! == [[0, 2]])
    }

    /// Swift's `\w` drops an ASCII digit or `_` that sits immediately before a
    /// scalar of three or more UTF-8 bytes (Swift 6.3.3). It is the only place
    /// the differential fuzz had to be narrowed, so the evidence lives here
    /// with the answer this engine gives — which is the one every other engine
    /// gives, and the one the find bar needs for `eth_0` next to Thai text.
    @Test func theStdlibWordShorthandBug() {
        #expect(ours("\\w+", "b__z")! == [[0, 4]])
        #expect(ours("\\w+", "b__ก")! == [[0, 4]])
        #expect(ours("\\w+", "_🙂")! == [[0, 1]])
        #expect(ours("\\w+", "12ก")! == [[0, 3]])
        #expect(ours("\\W", "_🙂")! == [[1, 2]])

        // The oracle really does disagree — if a future Swift fixes this, the
        // expectation below flips and the fuzz's text filter can come out.
        let rx = try! Regex("\\w+").matchingSemantics(.unicodeScalar)
        #expect(oracle(rx, "b__ก") != [[0, 4]], "Regex's \\w bug appears to be fixed")
    }

    @Test func limitCapsTheList() {
        #expect(ours("a", "aaaaa", limit: 3)! == [[0, 1], [1, 2], [2, 3]])
        #expect(ours("a", "aaaaa", limit: 0)! == [])
        #expect(ours("a", "aaaaa", limit: 1)! == [[0, 1]])
    }

    @Test func emptyTextAndEmptyMatchAdvance() {
        #expect(ours("a", "")! == [])
        #expect(ours("a*", "")! == [])
        #expect(ours("a*", "aab")! == [[0, 2]])
        #expect(ours("(a*)(b*)", "ab")! == [[0, 2]])
        #expect(ours("x*", "yxxy")! == [[1, 3]])
    }
}

// MARK: - what we refuse

@Suite("LinearRegex refusals")
struct LinearRegexRefusalTests {

    @Test func backreferencesAreUnsupported() {
        #expect(LinearRegex(pattern: "(a)\\1", ignoresCase: false) == nil)
        #expect(LinearRegex(pattern: "(ab)+\\1", ignoresCase: false) == nil)
        #expect(LinearRegex(pattern: "[\\1]", ignoresCase: false) == nil)
    }

    @Test func lookaroundIsUnsupported() {
        #expect(LinearRegex(pattern: "a(?=b)", ignoresCase: false) == nil)
        #expect(LinearRegex(pattern: "a(?!b)", ignoresCase: false) == nil)
        #expect(LinearRegex(pattern: "(?<=a)b", ignoresCase: false) == nil)
        #expect(LinearRegex(pattern: "(?<!a)b", ignoresCase: false) == nil)
        // Anything else behind `(?` is a flag or a named group; we decline
        // those too rather than guess at them.
        #expect(LinearRegex(pattern: "(?i)a", ignoresCase: false) == nil)
        #expect(LinearRegex(pattern: "(?<name>a)", ignoresCase: false) == nil)
    }

    @Test func unknownEscapesAreUnsupported() {
        #expect(LinearRegex(pattern: "\\A", ignoresCase: false) == nil)
        #expect(LinearRegex(pattern: "\\p{L}", ignoresCase: false) == nil)
        #expect(LinearRegex(pattern: "\\u{41}", ignoresCase: false) == nil)
        #expect(LinearRegex(pattern: "\\q", ignoresCase: false) == nil)
        #expect(LinearRegex(pattern: "[\\b]", ignoresCase: false) == nil)
    }

    @Test func malformedPatternsAreRejected() {
        #expect(LinearRegex(pattern: "[", ignoresCase: false) == nil)
        #expect(LinearRegex(pattern: "[a", ignoresCase: false) == nil)
        #expect(LinearRegex(pattern: "[]", ignoresCase: false) == nil)
        #expect(LinearRegex(pattern: "[z-a]", ignoresCase: false) == nil)
        #expect(LinearRegex(pattern: "a{2,1}", ignoresCase: false) == nil)
        #expect(LinearRegex(pattern: "a{2", ignoresCase: false) == nil)
        #expect(LinearRegex(pattern: "(", ignoresCase: false) == nil)
        #expect(LinearRegex(pattern: "(a", ignoresCase: false) == nil)
        #expect(LinearRegex(pattern: ")", ignoresCase: false) == nil)
        #expect(LinearRegex(pattern: "a)", ignoresCase: false) == nil)
        #expect(LinearRegex(pattern: "*", ignoresCase: false) == nil)
        #expect(LinearRegex(pattern: "+a", ignoresCase: false) == nil)
        #expect(LinearRegex(pattern: "?", ignoresCase: false) == nil)
        #expect(LinearRegex(pattern: "a|*", ignoresCase: false) == nil)
        #expect(LinearRegex(pattern: "a\\", ignoresCase: false) == nil)
    }

    @Test func theInstructionCapRejectsHugePrograms() {
        // Well inside the cap.
        #expect(LinearRegex(pattern: "a{1000}", ignoresCase: false) != nil)
        // Counted repetition is expanded, so this asks for a million
        // instructions and gets nil instead — the case the cap exists for.
        #expect(LinearRegex(pattern: "a{1000}{1000}", ignoresCase: false) == nil)
        #expect(LinearRegex(pattern: "(?:abcd){2000}", ignoresCase: false) == nil)
        #expect(LinearRegex(pattern: "a{99999}", ignoresCase: false) == nil)
        #expect(LinearRegex(pattern: "a{999999999999}", ignoresCase: false) == nil)
        // A body that emits nothing grows no program, so the length cap alone
        // would never fire on this and the expansion loops would run forever.
        #expect(LinearRegex(pattern: "(?:){4000}{4000}", ignoresCase: false) == nil)
        #expect(LinearRegex(pattern: "(?:a?){2000}{2000}", ignoresCase: false) == nil)

        // Right at the edge: 1023 instructions plus `.match` fits, one more
        // does not.
        #expect(LinearRegex(pattern: "a{1023}", ignoresCase: false) != nil)
        #expect(LinearRegex(pattern: "a{1024}", ignoresCase: false) == nil)

        // A repeat count that is merely enormous is "too complex", not "bad
        // pattern": `a{100001}` used to be reported as malformed while
        // `a{100000}` was reported as too big, one digit apart, and the find
        // bar told the user to go and fix a syntax error that was not there.
        #expect(throws: LinearRegex.Failure.tooBig) {
            try LinearRegex.compile(pattern: "a{100001}", ignoresCase: false)
        }
        #expect(throws: LinearRegex.Failure.tooBig) {
            try LinearRegex.compile(pattern: "a{99999999}", ignoresCase: false)
        }
        #expect(throws: LinearRegex.Failure.malformed) {
            try LinearRegex.compile(pattern: "a{2x}", ignoresCase: false)
        }
        // Digits are not the measure — the VALUE is. Eight characters asking
        // for one used to be refused as too complex.
        #expect(LinearRegex(pattern: "a{00000001}", ignoresCase: false) != nil)
        #expect(LinearRegex(pattern: "a{000000000000000002}", ignoresCase: false) != nil)
    }

    /// Depth is the one dimension the other caps miss: the parser and the
    /// emitter both recurse, so nesting is stack frames, and a review measured
    /// the overflow arriving between 10,000 and 50,000 levels on a stack the
    /// size of the main thread's. A pattern this deep can be pasted in one
    /// gesture, so "not supported" has to arrive before the crash does.
    @Test func deepNestingIsRefusedRatherThanOverflowingTheStack() {
        #expect(LinearRegex(pattern: String(repeating: "(", count: 100)
                            + "a" + String(repeating: ")", count: 100),
                            ignoresCase: false) != nil)
        for depth in [200, 5_000, 50_000] {
            let pattern = String(repeating: "(", count: depth) + "a" + String(repeating: ")", count: depth)
            #expect(throws: LinearRegex.Failure.tooBig) {
                try LinearRegex.compile(pattern: pattern, ignoresCase: false)
            }
        }
        // Unbalanced and deep is still malformed, and must also not recurse
        // its way off the stack on the way to finding that out.
        #expect(LinearRegex(pattern: String(repeating: "(", count: 50_000),
                            ignoresCase: false) == nil)
    }

    /// Depth without parentheses. The cap above counts `(`, and this shape has
    /// none: quantifiers stack straight onto one atom, and `{1}` emits nothing,
    /// so the instruction cap and the work cap never fire either. Measured
    /// before the chain cap existed: 20,000 of them was refused and 200,000
    /// killed the process with SIGSEGV — the tree is what gets deep, and both
    /// the emitter's walk and ARC's release of a nested indirect enum recurse
    /// over it. The first version of the depth cap missed this entirely.
    @Test func chainedQuantifiersCannotBuildADeepTreeEither() {
        #expect(LinearRegex(pattern: "a{1}{1}", ignoresCase: false) != nil)
        #expect(LinearRegex(pattern: "a" + String(repeating: "{1}", count: 8),
                            ignoresCase: false) != nil)
        #expect(LinearRegex(pattern: "a" + String(repeating: "{1}", count: 9),
                            ignoresCase: false) == nil)
        for n in [1_000, 200_000] {
            #expect(LinearRegex(pattern: "a" + String(repeating: "{1}", count: n),
                                ignoresCase: false) == nil)
            #expect(LinearRegex(pattern: "a" + String(repeating: "?", count: n),
                                ignoresCase: false) == nil)
        }
        // Every cap at its limit at once must still be a pattern, not a crash.
        let worst = String(repeating: "(?:", count: 128) + "a"
            + String(repeating: "{1}", count: 8) + String(repeating: ")", count: 128)
        #expect(LinearRegex(pattern: worst, ignoresCase: false) != nil)
    }

    /// A loop whose body can match nothing: deliberately NOT what a
    /// backtracker does, and pinned here so it stays a decision rather than a
    /// surprise. PCRE, Python and Swift `Regex` all stop such a loop at the
    /// empty iteration and report no match; this engine keeps the non-empty
    /// run it found. Neither answer is wrong — an automaton has no "iteration"
    /// to stop, it has a set of states — and for a find bar, showing the run
    /// that is really there beats showing nothing. Found by a review's
    /// differential fuzz against Python's `re`, which is the only reason it is
    /// written down.
    @Test func loopsWithAnEmptyableBodyKeepTheirMatch() {
        let rx = LinearRegex(pattern: "((B|_)?|1{1,3})*", ignoresCase: false)
        let text = Array("a 1 b1B22ABA".unicodeScalars)
        // "a 1 b1B22ABA" — the "1", then "1B", then the last "B". Python's
        // `re` finds none of them.
        #expect(rx?.matches(in: text, limit: 10) == [2..<3, 5..<7, 10..<11])
        // Same class, simpler shape.
        let star = LinearRegex(pattern: "(a*)*", ignoresCase: false)
        #expect(star?.matches(in: Array("bbaab".unicodeScalars), limit: 10) == [2..<4])
    }

    /// Everything we refuse, Swift `Regex` must be able to take — that is what
    /// makes "return nil" a safe fallback rather than a dropped feature.
    @Test func refusalsAreThingsRegexCanStillDo() {
        // Lookbehind is not on the list: `Regex(_:)` built at runtime rejects
        // `(?<=…)` and `(?<!…)` outright, so refusing it here costs nothing.
        for p in ["(a)\\1", "a(?=b)", "a(?!b)", "(?i)a",
                  "(?<name>a)", "\\A", "\\p{L}", "\\u{41}", "[\\b]"] {
            #expect((try? Regex(p)) != nil, "Regex should still accept \(p)")
        }
    }
}

// MARK: - the reason this engine exists

@Suite("LinearRegex catastrophic patterns")
struct LinearRegexBlowupTests {

    /// Wall time for one full `matches` call, best of five so a scheduling
    /// hiccup does not decide the test.
    private func bestTime(_ pattern: String, _ text: String,
                          iterations: Int = 5) -> Duration {
        let rx = LinearRegex(pattern: pattern, ignoresCase: false)
        #expect(rx != nil, "\(pattern) should compile")
        guard let rx else { return .seconds(999) }
        let hay = scalars(text)
        var best = Duration.seconds(999)
        for _ in 0..<iterations {
            let t = ContinuousClock().measure { _ = rx.matches(in: hay, limit: 1000) }
            if t < best { best = t }
        }
        return best
    }

    /// The three shapes that do not return in Swift `Regex`. 24 `a`s is where
    /// the user measured ~3.9 cores being burned; 40 is far past the point of
    /// no return for a backtracker. Measured here (release, M-series): 2.6 us,
    /// 3.4 us and 2.7 us at 40 `a`s — three orders of magnitude under the bound
    /// asserted, which is deliberately loose so a debug build passes it too.
    @Test func catastrophicPatternsFinishImmediately() {
        for count in [24, 32, 40] {
            let a = String(repeating: "a", count: count)
            for pattern in ["(a+)+b", "(a|a)*b", "(a*)*b", "(a|aa)+b", "(a+)+(b+)+c"] {
                let t = bestTime(pattern, a)
                #expect(t < .milliseconds(10),
                        "\(pattern) over \(count) a's took \(t)")
            }
        }
    }

    /// The same patterns when the text does end in `b`, so the answer is a
    /// match rather than a failure — the failure case is the classic blow-up,
    /// but a caller pasting a real line hits the other one.
    @Test func catastrophicPatternsAlsoFinishWhenTheyMatch() {
        let text = String(repeating: "a", count: 40) + "b"
        for pattern in ["(a+)+b", "(a|a)*b", "(a*)*b"] {
            let t = bestTime(pattern, text)
            #expect(t < .milliseconds(10), "\(pattern) took \(t)")
            #expect(ours(pattern, text)! == [[0, 41]])
        }
    }

    /// Linear, not quadratic-in-disguise: 10,000 `a`s is 250x the text above
    /// and costs 250x — 0.44 ms measured against 2.6 us at 40.
    @Test func longTextStaysLinear() {
        let t = bestTime("(a+)+b", String(repeating: "a", count: 10_000))
        #expect(t < .milliseconds(100), "10k a's took \(t)")
    }

    /// The other half of the time bound. A scan costs instructions x scalars,
    /// so the cap is what keeps the WORST legal pattern bounded too, not just
    /// the pathological ones. Measured in release: 33 ms here, and 160 ms for
    /// the same program over a 10,000-scalar line — nothing the user can type
    /// gets past that, because anything longer is refused at compile time. The
    /// bound is loose because a debug build is ~22x slower and has to pass too.
    @Test func theLargestAllowedProgramStillReturns() {
        let t = bestTime("a{1000}b", String(repeating: "a", count: 2_000),
                         iterations: 1)
        #expect(t < .seconds(2), "the cap's worst case took \(t)")
    }
}

// MARK: - differential fuzz against Swift Regex

@Suite("LinearRegex differential fuzz", .serialized)
struct LinearRegexFuzzTests {

    /// (pattern, text) pairs per run. 200k finishes in a few seconds in
    /// release; the env var drives the long soak.
    static var caseCount: Int {
        if let s = ProcessInfo.processInfo.environment["SHEEPVT_REGEX_CASES"], let n = Int(s) {
            return n
        }
        return 200_000
    }

    static var baseSeed: UInt64 {
        if let s = ProcessInfo.processInfo.environment["SHEEPVT_REGEX_SEED"] {
            if s.hasPrefix("0x"), let n = UInt64(s.dropFirst(2), radix: 16) { return n }
            if let n = UInt64(s) { return n }
        }
        return 0x5EED_0000_0000_0001
    }

    /// Texts per compiled pattern. Compiling a Swift `Regex` costs far more
    /// than running one, so the cases are spread over reused patterns —
    /// otherwise 200k cases would be 200k compiles and the run would be
    /// measuring the oracle's parser instead of either matcher.
    private static let textsPerPattern = 100

    /// Scalars that appear in generated text.
    ///
    /// ASCII, plus a Thai consonant and an emoji so the scalar unit is under
    /// test on every case, and NOT: combining marks (Swift's `\w` counts them,
    /// `SearchEngine.isWordScalar` does not), Thai digits under `ignoresCase`,
    /// dotted-I and other scalars whose lowercase form is more than one scalar
    /// (`SearchEngine.fold` deliberately leaves those alone so offsets cannot
    /// drift, and `Regex` does not). Those divergences are known, documented,
    /// and not what this fuzz is looking for.
    private static let textAlphabet: [Character] =
        ["a", "a", "b", "b", "c", "A", "B", " ", "_", "1", "2", "\t", "-", "ก", "🙂"]

    private struct Generated {
        var pattern: String
        /// True when the source contains a quantifier — a group carrying one is
        /// never quantified again, which is what keeps the backtracking oracle
        /// out of the exponential cases.
        var quantified: Bool
    }

    private static func makeAtom(_ rng: inout RegexRNG, depth: Int) -> Generated {
        switch rng.below(depth >= 2 ? 8 : 10) {
        case 0:
            return Generated(pattern: ".", quantified: false)
        case 1:
            return Generated(pattern: rng.pick(["\\d", "\\D", "\\w", "\\W", "\\s", "\\S"]),
                             quantified: false)
        case 2:
            return Generated(pattern: rng.pick(["[ab]", "[^ab]", "[a-c]", "[^a-c]",
                                                "[abc1 ]", "[\\dab]", "[^\\d]", "[ก-ฮ]"]),
                             quantified: false)
        case 3:
            return Generated(pattern: rng.pick(["\\.", "\\-", "\\_", "\\ "]), quantified: false)
        case 8, 9:
            // A group: its own little alternation, one level down.
            let inner = makeAlternation(&rng, depth: depth + 1)
            let open = rng.below(2) == 0 ? "(" : "(?:"
            return Generated(pattern: open + inner.pattern + ")", quantified: inner.quantified)
        default:
            let c = rng.pick(Self.textAlphabet)
            // A literal space or tab reads badly in a failure message and adds
            // nothing the class cases do not cover.
            let safe = (c == " " || c == "\t") ? "a" : c
            return Generated(pattern: String(safe), quantified: false)
        }
    }

    private static func makePiece(_ rng: inout RegexRNG, depth: Int) -> Generated {
        // Anchors stand alone; quantifying one is a corner where engines
        // disagree about whether it is even legal.
        if depth == 0, rng.below(12) == 0 {
            // `^` and `$` only. `\b` is out of the fuzz on purpose: neither of
            // `Regex`'s word-boundary kinds implements the classic rule this
            // engine implements, so there is no oracle to compare against —
            // `boundaryPositionsFollowTheClassicRule` pins it down instead.
            return Generated(pattern: rng.pick(["^", "$"]), quantified: false)
        }
        var atom = makeAtom(&rng, depth: depth)
        // Never a quantifier on something already quantified: that is the
        // nesting that makes the oracle hang.
        guard !atom.quantified, rng.below(2) == 0 else { return atom }
        let q = rng.pick(["*", "+", "?", "{0,2}", "{1,2}", "{2}", "{1,}", "{0,3}", "{2,3}"])
        atom.pattern += q
        if rng.below(3) == 0 { atom.pattern += "?" }   // lazy
        atom.quantified = true
        return atom
    }

    private static func makeConcat(_ rng: inout RegexRNG, depth: Int) -> Generated {
        let n = 1 + rng.below(depth >= 2 ? 2 : 4)
        var out = ""
        var quantified = false
        for _ in 0..<n {
            let p = makePiece(&rng, depth: depth)
            out += p.pattern
            quantified = quantified || p.quantified
        }
        return Generated(pattern: out, quantified: quantified)
    }

    private static func makeAlternation(_ rng: inout RegexRNG, depth: Int) -> Generated {
        let n = 1 + rng.below(depth >= 2 ? 2 : 3)
        var branches: [String] = []
        var quantified = false
        for _ in 0..<n {
            let b = makeConcat(&rng, depth: depth)
            branches.append(b.pattern)
            quantified = quantified || b.quantified
        }
        return Generated(pattern: branches.joined(separator: "|"), quantified: quantified)
    }

    /// One case's text.
    ///
    /// The one shape it refuses to build is an ASCII digit or `_` immediately
    /// followed by a scalar of three or more UTF-8 bytes, because Swift's own
    /// `\w` gets that wrong (Swift 6.3.3, and at both semantic levels):
    ///
    ///     "b__z"  \w+  ->  "b__"     correct
    ///     "b__ก"  \w+  ->  "b_"      the second '_' is dropped
    ///     "_🙂"    \w+  ->  ""        the '_' is dropped
    ///     "12ก"   \w+  ->  "1", "ก"  the '2' is dropped
    ///
    /// A letter before the same scalar is fine, `\d`, `\s` and explicit
    /// classes are all fine, so the trigger is exactly "ASCII digit or
    /// underscore, then a >= 3-byte scalar" and that is exactly what is
    /// excluded — the rest of the alphabet, Thai and emoji included, keeps
    /// running against every construct. `theStdlibWordShorthandBug` holds the
    /// evidence and asserts our (correct) answer, so this is documented rather
    /// than papered over.
    private static func makeText(_ rng: inout RegexRNG) -> String {
        var s = ""
        let n = rng.below(13)
        for _ in 0..<n {
            var c = rng.pick(Self.textAlphabet)
            if let last = s.unicodeScalars.last, last.value == 95 || (last.value >= 48 && last.value <= 57),
               String(c).utf8.count >= 3 {
                c = "a"
            }
            s.append(c)
        }
        return s
    }

    @Test func agreesWithSwiftRegexOnRandomPatterns() {
        var rng = RegexRNG(state: Self.baseSeed)
        let total = Self.caseCount
        var compared = 0
        var patterns = 0

        while compared < total {
            let seedBefore = rng.state
            let generated = Self.makeAlternation(&rng, depth: 0)
            let pattern = generated.pattern
            let ignoresCase = rng.below(2) == 0
            patterns += 1

            // The generator only emits patterns inside the subset, so a nil
            // here is a compile bug, not a refusal.
            guard let mine = LinearRegex(pattern: pattern, ignoresCase: ignoresCase) else {
                Issue.record("LinearRegex refused a supported pattern: /\(pattern)/ (seed 0x\(String(seedBefore, radix: 16)))")
                continue
            }
            guard let rx = oracleRegex(pattern, ignoresCase: ignoresCase) else {
                // Regex rejected something we accepted. Not a correctness bug
                // for the caller (we are the primary engine) but it means the
                // case cannot be compared, so it must not be silent.
                Issue.record("Regex refused /\(pattern)/ (seed 0x\(String(seedBefore, radix: 16)))")
                continue
            }

            for _ in 0..<Self.textsPerPattern where compared < total {
                let text = Self.makeText(&rng)
                let a = mine.matches(in: scalars(text), limit: 1000)
                    .map { [$0.lowerBound, $0.upperBound] }
                let b = oracle(rx, text)
                if a != b {
                    Issue.record("""
                        disagreement on /\(pattern)/ ignoresCase=\(ignoresCase)
                          text  : \(text.debugDescription)
                          ours  : \(a)
                          Regex : \(b)
                          seed  : 0x\(String(seedBefore, radix: 16))
                        """)
                    return
                }
                compared += 1
            }
        }

        #expect(compared == total)
        #expect(patterns > 0)
    }

    /// The same comparison over a fixed list of shapes the random generator
    /// reaches only rarely — the ones where leftmost-first, laziness and
    /// anchors interact, checked against every short text over `ab`.
    @Test func agreesOnHandPickedShapes() {
        let patterns = [
            "a*b", "a*?b", "a+b", "a+?b", "(a|ab)(b|)", "(ab|a)(b|)",
            "^a*", "a*$", "^a*$", "(a|b)*", "(a|b)*?",
            "a{0,2}b", "a{2,}b", "[ab]{2,3}", "[^a]*b", ".*", ".+", ".?",
            "(a|)*b", "(|a)b", "a|", "|a", "(a)(b)?", "a??b", "a{1,2}?b",
        ]
        var texts: [String] = [""]
        var frontier = [""]
        for _ in 0..<6 {
            var next: [String] = []
            for t in frontier {
                for c in ["a", "b"] { next.append(t + c) }
            }
            texts += next
            frontier = next
        }
        for pattern in patterns {
            for ignoresCase in [false, true] {
                guard let mine = LinearRegex(pattern: pattern, ignoresCase: ignoresCase),
                      let rx = oracleRegex(pattern, ignoresCase: ignoresCase) else {
                    Issue.record("could not build both engines for /\(pattern)/")
                    continue
                }
                for text in texts {
                    let a = mine.matches(in: scalars(text), limit: 1000)
                        .map { [$0.lowerBound, $0.upperBound] }
                    let b = oracle(rx, text)
                    let note = "/\(pattern)/ over \(text.debugDescription): ours \(a), Regex \(b)"
                    #expect(a == b, "\(note)")
                }
            }
        }
    }
}
