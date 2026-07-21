import XCTest
@testable import TelexCore

// Word-boundary commit paths: commitBoundary (edit-action form, for the event-tap
// client) and commitText (final-string form, for the marked-text client) must agree,
// and the backspace/insert counts a boundary emits must exactly match what was on
// screen (outCount == composed.count) so the client never over- or under-deletes.
final class BoundaryTests: XCTestCase {

    private func feed(_ keys: String, _ cfg: (inout TelexEngine) -> Void = { _ in }) -> TelexEngine {
        var e = TelexEngine(); cfg(&e)
        for ch in keys { _ = e.feed(ch) }
        return e
    }
    private func commitText(_ keys: String, restore: Bool) -> String {
        var e = feed(keys); return e.commitText(autoRestore: restore)
    }

    // commitBoundary's .replace(backspaces:insert:) must delete exactly the composed
    // characters currently on screen and insert the raw keystrokes — applying it to a
    // simulated screen showing `composed` must yield exactly commitText's result.
    func testCommitBoundaryMatchesCommitText() {
        let corpus = ["retore", "user", "paper", "after", "google", "github", "windows",
                      "kw", "was", "school", "SaaS", "OmS",
                      "toans", "hoas", "nguwowif", "dduowcj", "vieejt", "quocs",
                      "iss", "ass", "messs", "asz", "zoo", "dzij", "z", "xyz", "pizza"]
        for keys in corpus {
            // commitText result (fresh engine).
            let textResult = commitText(keys, restore: true)

            // Apply commitBoundary's action to a screen showing the composition.
            var e = feed(keys)
            let composedBefore = e.composed
            let action = e.commitBoundary(autoRestore: true)
            var screen = Array(composedBefore)
            switch action {
            case .none:
                break                                   // screen already shows the final text
            case .replace(let bs, let insert):
                XCTAssertLessThanOrEqual(bs, screen.count, "over-delete for \(keys)")
                screen.removeLast(bs)
                screen.append(contentsOf: insert)
            case .passthrough:
                XCTFail("commitBoundary should never passthrough for \(keys)")
            }
            XCTAssertEqual(String(screen), textResult,
                           "commitBoundary screen != commitText for \(keys)")
        }
    }

    // When a restore fires, it must back out the WHOLE composition (outCount chars)
    // and type the raw keystrokes — verified against composed.count and rawKeystrokes.
    func testRestoreBackspaceCountEqualsComposedLength() {
        // Words whose composition actually TRANSFORMS (composed != raw) so a restore
        // fires. (w-words / no-transform words compose == raw and correctly yield
        // .none — nothing to back out; that path is covered in testValidWordsAreNotRestored.)
        for keys in ["retore", "user", "paper", "after", "strongs", "codej"] {
            var e = feed(keys)
            let composedLen = e.composed.count
            let raw = e.rawKeystrokes
            let action = e.commitBoundary(autoRestore: true)
            guard case .replace(let bs, let insert) = action else {
                return XCTFail("expected restore for \(keys), got \(action)")
            }
            XCTAssertEqual(bs, composedLen, "must delete the whole composition for \(keys)")
            XCTAssertEqual(insert, raw, "must retype the raw keystrokes for \(keys)")
        }
    }

    // Valid Vietnamese never restores; both commit paths keep the composition.
    func testValidWordsAreNotRestored() {
        for (keys, word) in [("toans", "toán"), ("nguwowif", "người"), ("dduowcj", "được"),
                             ("hoas", "hóa"), ("vieejt", "việt"), ("quoocs", "quốc"),
                             ("zoo", "zô"), ("dzij", "dzị")] {
            var b = feed(keys)
            XCTAssertEqual(b.commitBoundary(autoRestore: true), .none, "restored valid \(word)")
            XCTAssertEqual(commitText(keys, restore: true), word)
        }
    }

    // autoRestore == false disables the safety net entirely: commitBoundary is always
    // .none, commitText always returns the (possibly invalid) composed form.
    func testAutoRestoreOffKeepsComposed() {
        for keys in ["retore", "user", "windows", "github", "toans"] {
            var b = feed(keys)
            let composed = b.composed
            XCTAssertEqual(b.commitBoundary(autoRestore: false), .none)
            XCTAssertEqual(commitText(keys, restore: false), composed)
        }
    }

    // Cancel contract (2026-07-21, gonhanh learnings): a cancelled word keeps the
    // composed text ONLY when it is valid Vietnamese; otherwise the RAW keys come
    // back — the user gets exactly what they pressed ("off" stays off, "ass" stays
    // ass), instead of the old collapse that silently ate a letter ("iss"→is).
    func testCancelledWordsFollowValidityRule() {
        // invalid after cancel → raw restore in BOTH paths
        for keys in ["iss", "ass", "messs", "off", "class"] {
            var b = feed(keys)
            if case .replace(_, let insert) = b.commitBoundary(autoRestore: true) {
                XCTAssertEqual(insert, keys, "\(keys) should restore to raw")
            } else { XCTFail("\(keys) should restore") }
            XCTAssertEqual(commitText(keys, restore: true), keys)
        }
        // valid after cancel (z cleared the tone, "a" is fine) → keep composed
        var b = feed("asz")
        XCTAssertEqual(b.commitBoundary(autoRestore: true), .none, "asz keeps composed")
        XCTAssertEqual(commitText("asz", restore: true), "a")
    }

    // Empty engine: nothing to commit.
    func testEmptyBoundary() {
        var e = TelexEngine()
        XCTAssertEqual(e.commitBoundary(autoRestore: true), .none)
        var f = TelexEngine()
        XCTAssertEqual(f.commitText(autoRestore: true), "")
    }

    // Both commit paths reset the engine (next word starts clean); settings persist.
    func testCommitResetsButKeepsSettings() {
        var e = TelexEngine(); e.freeMarking = true; e.simpleTelex = true
        for ch in "toans" { _ = e.feed(ch) }
        _ = e.commitText(autoRestore: true)
        XCTAssertTrue(e.isEmpty)
        XCTAssertEqual(e.composed, "")
        XCTAssertTrue(e.freeMarking); XCTAssertTrue(e.simpleTelex)   // preserved across reset
        // The reset engine composes the next word normally.
        for ch in "hoas" { _ = e.feed(ch) }
        XCTAssertEqual(e.composed, "hóa")
    }
}
