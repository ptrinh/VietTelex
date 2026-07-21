
import XCTest
@testable import TelexCore

/// Items 4-6 of the gonhanh-learnings batch: English-collision restore,
/// cancel-restore semantics, ethnic-name syllables. Golden, engine-validated.
final class EnglishCollisionTests: XCTestCase {
    private func commit(_ keys: String) -> String {
        var e = TelexEngine(); e.freeMarking = true
        for ch in keys { _ = e.feed(ch) }
        return e.commitText(autoRestore: true)
    }
    private func commitSimple(_ keys: String) -> String {
        var e = TelexEngine(); e.simpleTelex = true; e.freeMarking = true
        for ch in keys { _ = e.feed(ch) }
        return e.commitText(autoRestore: true)
    }

    func testCommonEnglishRestores() {
        for w in ["his", "this", "see", "of", "if", "is", "or", "us", "has",
                  "must", "last", "list", "most", "does", "those", "these",
                  "there", "here", "did", "days", "test", "now"] where w != "now" {
            XCTAssertEqual(commit(w), w, "English '\(w)' must survive")
        }
    }

    func testCancelRestoresEnglishDoubles() {
        // double-letter cancel used to eat one letter (off→of, class→clas)
        for w in ["off", "office", "class", "pass", "press", "less", "boss",
                  "address", "message", "access", "process", "business"] {
            XCTAssertEqual(commit(w), w, "'\(w)' must keep its double letter")
        }
        // invalid-after-cancel restores raw even for Vietnamese-looking input:
        // the user gets exactly the keys they pressed
        XCTAssertEqual(commit("hoass"), "hoass")
    }

    func testVietnameseProtectedWords() {
        // raw sequences shared with English where Vietnamese WINS (protect list)
        XCTAssertEqual(commit("sex"), "sẽ")
        XCTAssertEqual(commit("teen"), "tên")
        XCTAssertEqual(commit("been"), "bên")
        XCTAssertEqual(commit("own"), "ơn")
        XCTAssertEqual(commit("car"), "cả")
        XCTAssertEqual(commit("too"), "tô")
        XCTAssertEqual(commit("its"), "ít")
        XCTAssertEqual(commit("as"), "á")
        XCTAssertEqual(commit("low"), "lơ")
    }

    func testTeencodeSurvivesInSimpleTelex() {
        XCTAssertEqual(commitSimple("was"), "wá")   // w-guard: literal w = teencode
    }

    func testEthnicNameSyllables() {
        XCTAssertEqual(commit("DDawks"), "Đắk")
        XCTAssertEqual(commit("Lawks"), "Lắk")
        XCTAssertEqual(commit("Kroong"), "Krông")
    }

    // Coda k follows the stop-coda tone rule (sắc/nặng only, like c):
    // toneless or huyền forms are invalid and restore to raw.
    func testCodaKToneRule() {
        XCTAssertEqual(commit("DDawk"), "DDawk")    // toneless ăk → invalid
        XCTAssertEqual(commit("lawkf"), "lawkf")    // huyền on stop coda → invalid
        XCTAssertEqual(commit("lawkj"), "lặk")      // nặng allowed
    }

    // MARK: - Collision-table mechanics (item 4)

    func testCollisionRestoreIsCaseInsensitive() {
        XCTAssertEqual(commit("His"), "His")
        XCTAssertEqual(commit("THIS"), "THIS")
        XCTAssertEqual(commit("Off"), "Off")
        XCTAssertEqual(commit("OFF"), "OFF")        // dict beats the all-caps cancel escape
    }

    func testCollisionTableCanBeDisabled() {
        var e = TelexEngine()
        e.freeMarking = true
        e.englishWordRestore = false
        for ch in "his" { _ = e.feed(ch) }
        XCTAssertEqual(e.commitText(autoRestore: true), "hí")   // validator-only behavior
    }

    func testCollisionSkipsUntransformedWords() {
        // words the engine never touched can't be "restored" (and must not be):
        // no transform → composed == raw → commit is a no-op either way
        for w in ["me", "do", "go", "no", "to", "and", "the"] {
            XCTAssertEqual(commit(w), w)
        }
    }

    // Regression net for future `gen-english` runs: the generated table must
    // keep the pain words, and must NEVER contain a protected/junk raw.
    func testGeneratedTableSanity() {
        // NOTE: off/class/pass are NOT here — the cancel contract restores them
        // structurally, so gen-english correctly leaves them out of the table.
        for expected in ["his", "this", "see", "test", "of", "if", "is"] {
            XCTAssertTrue(EnglishCollisions.words.contains(expected), "table lost '\(expected)'")
        }
        // protected: Vietnamese wins these raw sequences (sẽ=sex, ơn=own…)
        for banned in ["sex", "teen", "been", "own", "car", "too", "its", "as",
                       "low", "now", "how", "room", "box", "air", "bar", "beer",
                       "bus", "lee", "max", "moon", "seen", "sir", "six", "tax", "ups"] {
            XCTAssertFalse(EnglishCollisions.words.contains(banned), "protected '\(banned)' leaked into the table")
        }
        // web-corpus junk that would eat Vietnamese typing (sw = sư)
        for junk in ["sw", "nw", "aa", "ee", "usr", "var", "www"] {
            XCTAssertFalse(EnglishCollisions.words.contains(junk), "junk '\(junk)' leaked into the table")
        }
        // minimal means minimal: a few hundred words, not a dictionary
        XCTAssertLessThan(EnglishCollisions.words.count, 400)
        XCTAssertGreaterThan(EnglishCollisions.words.count, 80)
    }

    // MARK: - Cancel contract (item 5)

    func testCancelContractMatrix() {
        // valid Vietnamese after cancel → composed survives
        XCTAssertEqual(commit("asz"), "a")
        // all-caps acronym escape → composed survives (literal DD reachable)
        XCTAssertEqual(commit("DDDR"), "DDR")
        // invalid + not in dict → exact raw keys come back
        XCTAssertEqual(commit("iss"), "iss")
        XCTAssertEqual(commit("banhss"), "banhss")   // bánh + s-cancel → invalid → raw
        // invalid + in dict → raw keys too (same visible result, dict path)
        XCTAssertEqual(commit("boss"), "boss")
    }

    // MARK: - Remote-desktop passthrough ids (item 3)

    func testNewPassthroughBundleIDs() {
        for id in ["com.carriez.rustdesk", "com.philandro.anydesk", "com.apple.ScreenContinuity"] {
            XCTAssertTrue(ClientPolicy.isRemoteDesktop(id), "\(id) must be passthrough")
        }
        XCTAssertFalse(ClientPolicy.isRemoteDesktop("com.apple.Terminal"))
    }
}
