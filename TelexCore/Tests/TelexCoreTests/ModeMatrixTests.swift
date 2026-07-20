import XCTest
@testable import TelexCore

// Settings matrix: each parse-affecting setting under both values, and — critically —
// FLIPPED MID-WORD. The engine re-applies settings every keystroke and rebuilds the
// parse when freeMarking/simpleTelex change, so a mid-word flip must land on exactly
// the same composition as if the final setting had been in force from the first key.
// (modernTone affects only render, which reruns every key; liveSpellCheck is
// intentionally forward-only — enabling it mid-word does NOT retroactively freeze.)
final class ModeMatrixTests: XCTestCase {

    private func composed(_ keys: String, _ cfg: (inout TelexEngine) -> Void) -> String {
        var e = TelexEngine(); cfg(&e)
        for ch in keys { _ = e.feed(ch) }
        return e.composed
    }

    /// Feed `keys`, applying `cfg` right before the key at `flipAt`.
    private func composedFlipping(_ keys: String, at flipAt: Int, _ cfg: (inout TelexEngine) -> Void) -> String {
        var e = TelexEngine()
        for (i, ch) in keys.enumerated() {
            if i == flipAt { cfg(&e) }
            _ = e.feed(ch)
        }
        return e.composed
    }

    // The words most sensitive to each parse setting.
    private static let words = [
        "ama", "aam", "coto", "coot", "data", "trangw", "trawng", "quatw",
        "cw", "kw", "uw", "cuw", "thw", "ngw", "windows", "ew", "giw",
        "hoas", "khoer", "thuys", "hoef", "muaf", "mias", "toans", "nguowif",
        "truowngf", "dduowcj", "nuawx", "nuwax", "ddaay", "tieengs", "vieejt",
    ]

    // freeMarking flip: rebuild path — must equal from-start for every flip point.
    func testFreeMarkingFlipEqualsFromStart() {
        for w in Self.words where w.count >= 2 {
            let fromStart = composed(w) { $0.freeMarking = true }
            for flip in 1..<w.count {
                XCTAssertEqual(composedFlipping(w, at: flip) { $0.freeMarking = true }, fromStart,
                               "freeMarking flip@\(flip) diverged for \(w)")
            }
        }
    }

    // simpleTelex flip: rebuild path — must equal from-start.
    func testSimpleTelexFlipEqualsFromStart() {
        for w in Self.words where w.count >= 2 {
            let fromStart = composed(w) { $0.simpleTelex = true }
            for flip in 1..<w.count {
                XCTAssertEqual(composedFlipping(w, at: flip) { $0.simpleTelex = true }, fromStart,
                               "simpleTelex flip@\(flip) diverged for \(w)")
            }
        }
    }

    // modernTone flip: render-only — final composition must also equal from-start.
    func testModernToneFlipEqualsFromStart() {
        for w in Self.words where w.count >= 2 {
            let fromStart = composed(w) { $0.modernTone = true }
            for flip in 1..<w.count {
                XCTAssertEqual(composedFlipping(w, at: flip) { $0.modernTone = true }, fromStart,
                               "modernTone flip@\(flip) diverged for \(w)")
            }
        }
    }

    // Combined settings: freeMarking + simpleTelex together are still just the union
    // of their per-key effects, and flip-equivalence holds under the combination.
    func testCombinedSettingsFlipEqualsFromStart() {
        let cfg: (inout TelexEngine) -> Void = { $0.freeMarking = true; $0.simpleTelex = true }
        for w in Self.words where w.count >= 2 {
            let fromStart = composed(w, cfg)
            for flip in 1..<w.count {
                XCTAssertEqual(composedFlipping(w, at: flip, cfg), fromStart,
                               "combined flip@\(flip) diverged for \(w)")
            }
        }
    }

    // Explicit combined table: simpleTelex keeps standalone w literal while freeMarking
    // reaches circumflex/breve back over a consonant — the two are independent axes.
    func testCombinedSettingsTable() {
        let cfg: (inout TelexEngine) -> Void = { $0.freeMarking = true; $0.simpleTelex = true }
        XCTAssertEqual(composed("cw", cfg), "cw")          // simpleTelex: lone w literal
        XCTAssertEqual(composed("ama", cfg), "âm")         // freeMarking: reach-back circumflex
        XCTAssertEqual(composed("trangw", cfg), "trăng")   // freeMarking breve reach-back
        XCTAssertEqual(composed("cuw", cfg), "cư")         // adjacent w still horns
        XCTAssertEqual(composed("uw", cfg), "ư")
    }

    // MARK: - liveSpellCheck at the word boundary (freeze then auto-restore to raw).

    private func commit(_ keys: String, spell: Bool) -> String {
        var e = TelexEngine(); e.liveSpellCheck = spell
        for ch in keys { _ = e.feed(ch) }
        return e.commitText(autoRestore: true)
    }

    func testLiveSpellCheckFreezeThenBoundaryRestore() {
        // Frozen mid-word (foreign) → boundary restores the raw keystrokes.
        var e = TelexEngine(); e.liveSpellCheck = true
        for ch in "gogle" { _ = e.feed(ch) }
        XCTAssertEqual(e.composed, "gogle")                 // "gog" invalid → frozen literal
        XCTAssertEqual(e.commitText(autoRestore: true), "gogle")

        // google/github: composed (partly transformed) form, then restore to raw.
        XCTAssertEqual(commit("google", spell: true), "google")
        XCTAssertEqual(commit("github", spell: true), "github")

        // Valid Vietnamese under spell-check is untouched and NOT restored.
        for (keys, word) in [("nguwowif", "người"), ("truowngf", "trường"), ("dduowcj", "được")] {
            XCTAssertEqual(commit(keys, spell: true), word, "spell-check altered valid \(word)")
        }
    }

    // liveSpellCheck is forward-only: enabling it AFTER the word already went invalid
    // does not retroactively unfreeze/refreeze — it only gates keys from that point on.
    // Documents the design (contrast with freeMarking/simpleTelex which rebuild).
    func testLiveSpellCheckIsForwardOnly() {
        // Enable spell-check only for the LAST key: earlier transforms already applied.
        var e = TelexEngine()
        let keys = Array("google")
        for i in 0..<keys.count {
            if i == keys.count - 1 { e.liveSpellCheck = true }
            _ = e.feed(keys[i])
        }
        // "googl" already composed "gôgl" (spell-check off); enabling it for 'e' only
        // gates that last key. The already-applied circumflex stays.
        XCTAssertEqual(e.composed, "gôgle")
    }
}
