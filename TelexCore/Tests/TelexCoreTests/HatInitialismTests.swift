import XCTest
@testable import TelexCore

// 08/11/2026 — "ÂL" (âm lịch) typed "AAL" showed ÂL live but auto-restore committed the raw
// keys "AAL" ("âl" is no syllable). Two-letter hat-vowel initialisms now keep the screen,
// like the DD→Đ initialisms ("BĐS", "ĐT"). The rule is narrow: exactly vowel+doubler/w +
// one bare consonant, one case, no tone, no English reading. The Kotlin
// (android/telexcore HatInitialismTest.kt) and C++ (windows/engine/tests unit_tests.cpp)
// ports carry the same cases.

private func macEngine() -> TelexEngine {
    var e = TelexEngine()
    e.freeMarking = true; e.liveSpellCheck = true; e.contextualEnglish = true
    e.collisionPrefersVietnamese = true; e.teencode = false; e.eagerEnglishRestore = true
    return e
}

private func liveSpellDefaults() -> TelexEngine { var e = TelexEngine(); e.liveSpellCheck = true; return e }

private func engines() -> [(String, TelexEngine)] { [
    ("mac", macEngine()), ("defaults", TelexEngine()), ("defaults+liveSpell", liveSpellDefaults()),
] }

/// Feed `w` (letters only); return (live composition, commitText at the boundary).
private func liveAndCommit(_ w: String, _ e0: TelexEngine) -> (String, String) {
    var e = e0
    for ch in w { _ = e.feed(ch) }
    let live = e.composed
    let peek = e.peekCommitText(autoRestore: true, boundary: " ")
    let c = e.commitText(autoRestore: true, boundary: " ")
    XCTAssertEqual(peek, c, "\(w): peekCommitText must equal commitText")
    return (live, c)
}

/// Type `s` like a host through `commitBoundary` (replace actions on a screen buffer).
private func typed(_ s: String, _ e0: TelexEngine) -> String {
    var e = e0
    var screen = ""
    func apply(_ a: TelexAction) {
        if case let .replace(bs, ins) = a { screen.removeLast(min(bs, screen.count)); screen += ins }
    }
    for ch in s {
        if let a = ch.asciiValue, (a >= 65 && a <= 90) || (a >= 97 && a <= 122) {
            let r = e.feed(ch)
            if case .passthrough = r { screen.append(ch) } else { apply(r) }
        } else {
            apply(e.commitBoundary(autoRestore: true, boundary: ch))
            screen.append(ch)
            e.noteBoundaryCharacter(ch)
        }
    }
    apply(e.commitBoundary(autoRestore: true))
    return screen
}

final class HatInitialismTests: XCTestCase {

    func testHatInitialismKeepsComposition() {
        let kept = [("AAL", "ÂL"), ("aal", "âl"), ("UWD", "ƯD"), ("uwd", "ưd"), ("OWB", "ƠB")]
        for (name, e) in engines() {
            for (keys, want) in kept {
                let (live, commit) = liveAndCommit(keys, e)
                XCTAssertEqual(live, want, "\(name) \(keys) live")
                XCTAssertEqual(commit, want, "\(name) \(keys) commit")
                XCTAssertEqual(typed(keys, e), want, "\(name) \(keys) commitBoundary")
            }
            XCTAssertEqual(typed("ngayf 15 AAL", e), "ngày 15 ÂL", name)
            // The Đ initialisms are untouched.
            XCTAssertEqual(typed("BDDS DDT", e), "BĐS ĐT", name)
        }
    }

    func testHatInitialismStaysNarrow() {
        // English words / acronyms (dictionary or the closed hat list), 3+ letter forms,
        // mixed case, standalone-w ư, the AAA cancel: exactly as before the rule.
        let raw = ["EEL", "eel", "OOH", "ooh", "EEK", "eek", "BOOK", "book", "COOL", "cool",
                   "LOOK", "look", "FEED", "feed", "OOTD", "ootd", "AAPL", "aapl", "EEG", "eeg",
                   "OOP", "oop", "AAC", "aac", "OWL", "owl", "AWL", "awl", "AAH", "aah",
                   "UWB", "UWP", "AWK", "awk", "aat", "AAT", "eep", "eet", "oog", "uwk", "awt", "owp", "uwc", "Aal", "aAL", "AAl", "WL", "wl", "AAAL", "aaal"]
        for (name, e) in engines() {
            for w in raw {
                XCTAssertEqual(liveAndCommit(w, e).1, String(w.replacingOccurrences(of: "AAA", with: "AA")
                    .replacingOccurrences(of: "aaa", with: "aa")), "\(name) \(w) restores")
            }
            // Tone keys still compose: OOF → Ồ, unchanged.
            XCTAssertEqual(liveAndCommit("OOF", e).1, "Ồ", name)
            XCTAssertEqual(liveAndCommit("oof", e).1, "ồ", name)
            // Already-valid syllables unchanged.
            XCTAssertEqual(liveAndCommit("AAN", e).1, "ÂN", name)
            XCTAssertEqual(liveAndCommit("OOM", e).1, "ÔM", name)
        }
    }
}
