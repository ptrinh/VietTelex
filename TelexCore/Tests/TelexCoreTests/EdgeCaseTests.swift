import XCTest
@testable import TelexCore

// Capacity/overflow boundary and additional cancellation edge cases that extend
// (not duplicate) the golden coverage in EngineTests.
final class EdgeCaseTests: XCTestCase {

    private func compose(_ keys: String) -> String {
        var e = TelexEngine(); for ch in keys { _ = e.feed(ch) }; return e.composed
    }
    private func commit(_ keys: String) -> String {
        var e = TelexEngine(); for ch in keys { _ = e.feed(ch) }; return e.commitText(autoRestore: true)
    }

    // MARK: - Capacity boundary (exactly at, one below, one above)

    func testExactlyAtCapacityDoesNotOverflow() {
        // 32 letters with no adjacent doublers → no transforms, no overflow.
        let word = String(repeating: "ab", count: 16)      // 32 chars
        XCTAssertEqual(word.count, TelexEngine.capacity)
        var e = TelexEngine()
        var lastAction: TelexAction = .none
        for ch in word { lastAction = e.feed(ch) }
        XCTAssertEqual(e.composed.count, 32, "all 32 keys should be composed")
        XCTAssertEqual(lastAction, .passthrough, "the 32nd key still composes (no overflow yet)")
        // Boundary still behaves normally at exactly capacity.
        XCTAssertEqual(e.backspace(), .replace(backspaces: 1, insert: ""))
    }

    func testKey33Overflows() {
        let word = String(repeating: "ab", count: 16) + "c"   // 33 chars
        var e = TelexEngine()
        var actions: [TelexAction] = []
        for ch in word { actions.append(e.feed(ch)) }
        XCTAssertEqual(actions.last, .passthrough, "the 33rd key overflows → passthrough")
        // Once overflowed, backspace and the boundary go inert (data-loss guard).
        XCTAssertEqual(e.backspace(), .passthrough)
        XCTAssertEqual(e.commitBoundary(autoRestore: true), .none)
    }

    // After an overflowed word, reset()/commit clears the flag and the next word
    // composes normally again.
    func testOverflowClearsOnNextWord() {
        let word = "nguyeenx" + String(repeating: "a", count: 32)
        var e = TelexEngine()
        for ch in word { _ = e.feed(ch) }
        _ = e.commitText(autoRestore: true)                 // resets, clears overflow
        XCTAssertTrue(e.isEmpty)
        for ch in "dduowcj" { _ = e.feed(ch) }
        XCTAssertEqual(e.composed, "được", "engine must recover after an overflowed word")
    }

    // A transform landing exactly at the last in-capacity slot still renders.
    func testTransformAtCapacityEdge() {
        // 30 filler + "aa" (doubler at positions 31-32) → last glyph is â.
        let word = String(repeating: "b", count: 30) + "aa"
        XCTAssertEqual(word.count, 32)
        var e = TelexEngine()
        for ch in word { _ = e.feed(ch) }
        XCTAssertEqual(e.composed.last, "â", "the capacity-edge doubler must still compose")
        XCTAssertEqual(e.composed.count, 31)                // 30 b + one â
    }

    // MARK: - Additional cancellation gestures

    func testDoubleHornCancel() {
        XCTAssertEqual(compose("oww"), "ow")     // ơ then cancel → literal o + w
        XCTAssertEqual(compose("uww"), "uw")     // ư then cancel → literal u + w
        XCTAssertEqual(compose("aww"), "aw")     // ă then cancel → literal a + w (parity)
        // After the cancel the word stays literal (English gesture).
        XCTAssertEqual(compose("owws"), "ows")   // trailing s literal, not a tone
    }

    func testTripleAndQuadDCancel() {
        XCTAssertEqual(compose("dd"), "đ")
        XCTAssertEqual(compose("ddd"), "dd")     // cancel đ → literal dd
        XCTAssertEqual(compose("dddd"), "ddd")   // then a further literal d
    }

    func testZCancelThenLiteral() {
        // z clears a tone (cancel), then subsequent tone keys are literal.
        XCTAssertEqual(compose("aszf"), "af")    // á →(z) a → f literal
        XCTAssertEqual(compose("huyeenfz"), "huyên")   // clear the huyền
        // z with no tone present is a literal letter wherever it sits.
        XCTAssertEqual(compose("azb"), "azb")
        XCTAssertEqual(compose("bzz"), "bzz")
    }

    // Cancelled words are not auto-restored (deliberate literal gesture) — extends the
    // EngineTests cases with the horn/quad-d variants.
    func testCancelledEdgeCasesSkipRestore() {
        XCTAssertEqual(commit("oww"), "ow")
        XCTAssertEqual(commit("uww"), "uw")
        XCTAssertEqual(commit("dddd"), "ddd")
        XCTAssertEqual(commit("bzz"), "bzz")
    }

    // MARK: - Empty / trivial inputs

    func testEmptyAndSingleChar() {
        XCTAssertEqual(compose(""), "")
        XCTAssertEqual(compose("a"), "a")
        XCTAssertEqual(compose("b"), "b")
        XCTAssertEqual(compose("A"), "A")
        // A lone tone key with no vowel is a literal letter.
        XCTAssertEqual(compose("s"), "s")
        XCTAssertEqual(compose("f"), "f")
        // A lone w depends on onset context — empty onset → literal.
        XCTAssertEqual(compose("w"), "w")
    }
}
