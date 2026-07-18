import XCTest
@testable import TelexCore

final class BenchmarkTests: XCTestCase {

    // Real-world benchmark corpus: a Vietnamese paragraph with capitalized words,
    // foreign proper nouns, digits and punctuation. All three cases derive their
    // keystroke streams from this one text (see helpers at the bottom).
    private static let corpusText = """
        Phil Trịnh (Trịnh Minh Phúc) là một nhà sáng lập đa lĩnh vực sinh ra tại \
        Hà Nội, hiện sống tại Singapore. Anh du học ngành Khoa học Máy tính tại \
        Đại học Drexel (Mỹ), sau đó làm kỹ sư phần mềm tại SIG, Zalora và Grab. \
        Hiện anh đồng điều hành ba công ty gồm SenPrints (SaaS thương mại điện \
        tử/print-on-demand), Printik (in ấn tại Mỹ) và AloRide (cho thuê xe máy), \
        với bề dày kinh nghiệm về kỹ thuật và xây dựng doanh nghiệp.
        """

    /// Case 1 — Vietnamese: each word as the raw Telex keystrokes that produce it
    /// (sáng → "sangs", điều → "ddieeuf", thương → "thuwowng"…).
    private static let vietnameseWords: [String] =
        words(of: corpusText).map(telexKeystrokes)

    /// Case 2 — English mode: the same words ASCII-folded (diacritics stripped),
    /// so the engine re-parses per key but (almost) nothing transforms.
    private static let englishWords: [String] =
        words(of: corpusText).map(asciiFolded)

    /// Case 3 — passthrough: every non-letter key in the text (space, punctuation,
    /// digits) — the engine returns .passthrough before touching any buffer.
    private static let passthroughKeys: [Character] =
        corpusText.filter { !$0.isLetter }

    // MARK: - Benchmarks

    /// Average engine latency per keystroke must stay under 50µs (Vietnamese case).
    func testPerKeystrokeLatencyUnder50Microseconds() {
        let micros = measureCase(name: "Vietnamese (Telex)", iterations: 2000) {
            feedWords(Self.vietnameseWords)
        }
        XCTAssertLessThan(micros, 50.0,
                          "avg keystroke latency \(micros)µs exceeds 50µs budget")
    }

    /// Baseline — English mode: real letters, engine still re-parses the word per
    /// key, but nothing transforms. The cost VietTelex adds while typing English.
    func testBaselineEnglishTextLatency() {
        _ = measureCase(name: "English mode (folded)", iterations: 2000) {
            feedWords(Self.englishWords)
        }
    }

    /// Baseline — pure passthrough: non-letter keys return .passthrough before
    /// touching any buffer. The engine's raw call overhead, "no logic at all".
    func testBaselinePassthroughLatency() {
        var e = TelexEngine()
        _ = measureCase(name: "Passthrough (non-letters)", iterations: 20_000) {
            var n = 0
            for ch in Self.passthroughKeys {
                _ = e.feed(ch)
                n += 1
            }
            return n
        }
    }

    // XCTest's own reporting harness for reference numbers.
    func testMeasureBlock() {
        measure {
            for _ in 0..<200 { feedWords(Self.vietnameseWords) }
        }
    }

    // Sanity: the generated Telex keystrokes really reproduce the original text's
    // Vietnamese words (commit-level). Guards the corpus generator itself. Pure-ASCII
    // words are skipped: their outcome legitimately depends on auto-restore edge
    // cases ("SaaS" → aa→â + s-tone → "Sấ", a VALID syllable, so no restore) —
    // that's engine behavior under test elsewhere, not a corpus property.
    func testCorpusRoundTrips() {
        for (word, keys) in zip(Self.words(of: Self.corpusText), Self.vietnameseWords) {
            guard word.contains(where: { $0.asciiValue == nil }) else { continue }
            var e = TelexEngine()
            for ch in keys { _ = e.feed(ch) }
            XCTAssertEqual(e.commitText(autoRestore: true), word,
                           "corpus word '\(word)' did not round-trip via '\(keys)'")
        }
    }

    // MARK: - Harness

    /// Runs `body` `iterations` times (after one warm-up call), prints and returns
    /// the average µs/keystroke. `body` returns the number of keystrokes fed.
    private func measureCase(name: String, iterations: Int, _ body: () -> Int) -> Double {
        _ = body()   // warm up (also warms the static tables)

        var total = 0
        let clock = ContinuousClock()
        let elapsed = clock.measure {
            for _ in 0..<iterations { total += body() }
        }
        let nanos = Double(elapsed.components.seconds) * 1_000_000_000
            + Double(elapsed.components.attoseconds) / 1_000_000_000
        let micros = nanos / Double(total) / 1000.0
        print(String(format: "Benchmark %@: %.4f µs/keystroke over %d keystrokes",
                     name, micros, total))
        return micros
    }

    /// Feed every word once (fresh engine per word, boundary commit). Returns keystrokes.
    @discardableResult
    private func feedWords(_ words: [String]) -> Int {
        var count = 0
        for w in words {
            var e = TelexEngine()
            for ch in w {
                _ = e.feed(ch)
                count += 1
            }
            _ = e.commitBoundary(autoRestore: true)
        }
        return count
    }

    // MARK: - Corpus generation (composed text -> keystroke streams)

    private static func words(of text: String) -> [String] {
        text.split(whereSeparator: { !$0.isLetter }).map(String.init)
    }

    private static let markExpansion: [Character: String] = [
        "â": "aa", "ă": "aw", "ê": "ee", "ô": "oo", "ơ": "ow", "ư": "uw", "đ": "dd",
    ]
    private static let baseFold: [Character: Character] = [
        "â": "a", "ă": "a", "ê": "e", "ô": "o", "ơ": "o", "ư": "u", "đ": "d",
    ]
    private static func toneKeyFor(_ t: Tone) -> Character? {
        switch t {
        case .acute: return "s"
        case .grave: return "f"
        case .hook:  return "r"
        case .tilde: return "x"
        case .dot:   return "j"
        case .none:  return nil
        }
    }

    /// Strip tone via the engine's own table; returns the toneless (marked) char.
    private static func detone(_ lower: Character) -> (Character, Tone) {
        guard lower.unicodeScalars.count == 1,
              let scalar = lower.unicodeScalars.first,
              let (base, t) = Tables.detoneTable[scalar.value]
        else { return (lower, .none) }
        return (Character(Unicode.Scalar(base)!), t)
    }

    /// "sáng" → "sangs", "điều" → "ddieeuf", "thương" → "thuwowng", "Mỹ" → "Myx".
    /// The tone key is appended at the end of the word (standard Telex habit).
    private static func telexKeystrokes(_ word: String) -> String {
        var out = ""
        var tone: Character?
        for ch in word {
            let isUpper = ch.isUppercase
            let (toneless, t) = detone(Character(ch.lowercased()))
            if t != .none { tone = toneKeyFor(t) }
            let expansion = markExpansion[toneless] ?? String(toneless)
            out += isUpper ? expansion.uppercased() : expansion
        }
        if let tone { out.append(tone) }
        return out
    }

    /// "sáng" → "sang", "điều" → "dieu" — the same text as plain ASCII letters.
    private static func asciiFolded(_ word: String) -> String {
        var out = ""
        for ch in word {
            let isUpper = ch.isUppercase
            let (toneless, _) = detone(Character(ch.lowercased()))
            let folded = baseFold[toneless] ?? toneless
            out.append(isUpper ? Character(folded.uppercased()) : folded)
        }
        return out
    }
}
