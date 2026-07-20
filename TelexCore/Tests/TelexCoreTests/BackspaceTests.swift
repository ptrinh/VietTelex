import XCTest
@testable import TelexCore

// Backspace deletes a whole DISPLAYED glyph (with the provenance keys that produced
// it), then rebuilds. The central invariant: after ANY mix of feeds and backspaces,
// the raw keystroke buffer stays a faithful generator of the composition — i.e.
// composing e.rawKeystrokes from scratch reproduces e.composed. If that ever breaks,
// the engine's state has diverged from what it would parse fresh (corruption class).
final class BackspaceTests: XCTestCase {

    private func compose(_ keys: String) -> String {
        var e = TelexEngine(); for ch in keys { _ = e.feed(ch) }; return e.composed
    }

    /// compose(e.rawKeystrokes) must always equal e.composed.
    private func assertRawGeneratesComposed(_ e: TelexEngine, _ ctx: String,
                                            file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(compose(e.rawKeystrokes), e.composed,
                       "raw \"\(e.rawKeystrokes)\" no longer generates composed \"\(e.composed)\" (\(ctx))",
                       file: file, line: line)
    }

    // MARK: - Documented single-glyph deletions + retype

    func testBackspaceDeletesGlyphThenRetype() {
        // khoo -> khô ; backspace -> kh ; type o -> kho (plain, no circumflex)
        var e = TelexEngine()
        for ch in "khoo" { _ = e.feed(ch) }
        XCTAssertEqual(e.composed, "khô")
        _ = e.backspace(); XCTAssertEqual(e.composed, "kh")
        _ = e.feed("o");   XCTAssertEqual(e.composed, "kho")
        assertRawGeneratesComposed(e, "khoo/bs/o")
    }

    func testBackspaceAfterTone() {
        // toán is CLOSED (coda n) so the tone sits on the 2nd vowel. Deleting the coda
        // re-OPENS the nucleus, and the tone correctly relocates to the 1st vowel
        // (old-style oa placement): "toán" -> "tóa". The engine re-renders placement on
        // every edit, so this is a feature, not a stale glyph.
        var e = TelexEngine()
        for ch in "toans" { _ = e.feed(ch) }
        XCTAssertEqual(e.composed, "toán")
        _ = e.backspace(); XCTAssertEqual(e.composed, "tóa")   // drop coda n -> tone re-homes to o
        assertRawGeneratesComposed(e, "toán/bs")
        _ = e.backspace(); XCTAssertEqual(e.composed, "tó")    // drop the 'a'
        assertRawGeneratesComposed(e, "toán/bs/bs")
        _ = e.backspace(); XCTAssertEqual(e.composed, "t")     // drop toned vowel + tone key
        assertRawGeneratesComposed(e, "toán/bs/bs/bs")
    }

    func testBackspaceThroughDuong() {
        var e = TelexEngine()
        for ch in "dduwowngf" { _ = e.feed(ch) }
        XCTAssertEqual(e.composed, "đường")
        let steps = ["đườn", "đườ", "đư", "đ", ""]
        for expected in steps {
            _ = e.backspace()
            XCTAssertEqual(e.composed, expected)
            assertRawGeneratesComposed(e, "đường step \(expected)")
        }
        // One more backspace on empty -> passthrough.
        XCTAssertEqual(e.backspace(), .passthrough)
    }

    // MARK: - Backspace re-opens a spell-check-frozen word

    func testBackspaceReopensFrozenWord() {
        var e = TelexEngine(); e.liveSpellCheck = true
        for ch in "google" { _ = e.feed(ch) }
        XCTAssertEqual(e.composed, "gôgle")               // frozen after 2nd g
        // Delete back to the still-valid "gô", then a tone key must apply again
        // (backspace lifts the freeze; "gô" is a valid prefix so it stays lifted).
        _ = e.backspace(); XCTAssertEqual(e.composed, "gôgl")
        _ = e.backspace(); XCTAssertEqual(e.composed, "gôg")
        _ = e.backspace(); XCTAssertEqual(e.composed, "gô")
        _ = e.feed("s");   XCTAssertEqual(e.composed, "gố")   // transform works after re-open
        assertRawGeneratesComposed(e, "google reopen")
    }

    // MARK: - Backspace at every position of many words + retype

    func testBackspaceEveryPositionKeepsRawInvariant() {
        let words = ["dduwowngf", "nguwowif", "truowngf", "vieejt", "tieengs",
                     "hoas", "nuawx", "quocs", "ddaay", "nghieeng", "chuyeenr", "khoo"]
        for w in words {
            // Backspace all the way down, checking the invariant after every delete.
            var e = TelexEngine()
            for ch in w { _ = e.feed(ch) }
            while !e.composed.isEmpty {
                _ = e.backspace()
                assertRawGeneratesComposed(e, "\(w) shrinking")
            }
            XCTAssertTrue(e.rawKeystrokes.isEmpty, "raw not empty after full backspace of \(w)")

            // Backspace to each depth, then retype a suffix; invariant must survive.
            for depth in 1...w.count {
                var f = TelexEngine()
                for ch in w { _ = f.feed(ch) }
                for _ in 0..<depth { _ = f.backspace() }
                for ch in "as" { _ = f.feed(ch) }
                assertRawGeneratesComposed(f, "\(w) depth \(depth) + retype")
            }
        }
    }

    // MARK: - Fuzz: random feeds + backspaces, raw-invariant after every op

    private struct LCG {
        var state: UInt64
        mutating func next() -> UInt64 { state = state &* 6364136223846793005 &+ 1442695040888963407; return state }
        mutating func int(_ n: Int) -> Int { Int(next() >> 33) % n }
    }

    func testRandomFeedBackspaceRawInvariant() {
        let alphabet = Array("aeiouywdsfrxjqhngtcbmlpAADDWW")
        var rng = LCG(state: 0xACE1_2468_1357_9BDF)
        for _ in 0..<5000 {
            var e = TelexEngine()
            let len = 1 + rng.int(26)
            for _ in 0..<len {
                if rng.int(4) == 0 { _ = e.backspace() }
                else { _ = e.feed(alphabet[rng.int(alphabet.count)]) }
                assertRawGeneratesComposed(e, "fuzz")
            }
        }
    }

    // Same fuzz but with every setting enabled — the rebuild-on-backspace path must
    // stay consistent regardless of policy.
    func testRandomFeedBackspaceRawInvariantAllSettings() {
        let alphabet = Array("aeiouywdsfrxjqhngtcbmlpAADDWW")
        var rng = LCG(state: 0x5555_AAAA_3333_CCCC)
        for _ in 0..<3000 {
            var e = TelexEngine()
            e.freeMarking = true; e.simpleTelex = true; e.modernTone = true
            let len = 1 + rng.int(26)
            for _ in 0..<len {
                if rng.int(4) == 0 { _ = e.backspace() }
                else { _ = e.feed(alphabet[rng.int(alphabet.count)]) }
                // Compose the raw through an engine with the SAME settings.
                var g = TelexEngine(); g.freeMarking = true; g.simpleTelex = true; g.modernTone = true
                for ch in e.rawKeystrokes { _ = g.feed(ch) }
                XCTAssertEqual(g.composed, e.composed, "settings fuzz raw=\"\(e.rawKeystrokes)\"")
            }
        }
    }
}
