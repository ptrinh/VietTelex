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

    // When a restore fires it emits a MINIMAL edit: the shared leading run with the
    // raw keystrokes is left untouched (never deleted+retyped — that duplicated the
    // first char in Chrome's omnibox), so bs deletes only the changed suffix and
    // insert is the raw tail. Applying it to `composed` must still reconstruct raw.
    func testRestoreEmitsMinimalPrefixStrippedEdit() {
        // Words whose composition actually TRANSFORMS (composed != raw) so a restore
        // fires. (w-words / no-transform words compose == raw and correctly yield
        // .none — nothing to back out; that path is covered in testValidWordsAreNotRestored.)
        for keys in ["retore", "user", "paper", "after", "strongs", "codej", "google"] {
            var e = feed(keys)
            let composed = Array(e.composed)
            let raw = e.rawKeystrokes
            let action = e.commitBoundary(autoRestore: true)
            guard case .replace(let bs, let insert) = action else {
                return XCTFail("expected restore for \(keys), got \(action)")
            }
            // Minimal: the deleted suffix + insert must never re-type the shared prefix.
            let lcp = zip(composed, Array(raw)).prefix { $0 == $1 }.count
            XCTAssertEqual(bs, composed.count - lcp, "must delete only the changed suffix for \(keys)")
            XCTAssertEqual(insert, String(raw.dropFirst(lcp)), "must retype only the raw tail for \(keys)")
            // Applying the edit to the on-screen composition reconstructs the raw word.
            var screen = composed; screen.removeLast(bs); screen.append(contentsOf: insert)
            XCTAssertEqual(String(screen), raw, "edit must reconstruct raw for \(keys)")
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

    // Cancel contract (final, 2026-07-22): the English table wins over everything
    // ("off"/"ass"/"class" restore their real double letters); any other cancel
    // keeps the COMPOSED text — the extra key was an undo gesture and typing may
    // continue after it ("Deffault" keys → Default).
    func testCancelledWordsFollowDictThenComposed() {
        // real English words → raw restore in BOTH paths
        for keys in ["ass", "off", "class"] {
            var b = feed(keys)
            let composed = Array(b.composed)
            if case .replace(let bs, let insert) = b.commitBoundary(autoRestore: true) {
                // Minimal edit (prefix-stripped): applying it must reconstruct raw.
                var screen = composed; screen.removeLast(bs); screen.append(contentsOf: insert)
                XCTAssertEqual(String(screen), keys, "\(keys) should restore to raw")
            } else { XCTFail("\(keys) should restore") }
            XCTAssertEqual(commitText(keys, restore: true), keys)
        }
        // non-English cancels → composed survives in BOTH paths
        for (keys, kept) in [("iss", "is"), ("messs", "mess"), ("asz", "a")] {
            var b = feed(keys)
            XCTAssertEqual(b.commitBoundary(autoRestore: true), .none, "\(keys) keeps composed")
            XCTAssertEqual(commitText(keys, restore: true), kept)
        }
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
