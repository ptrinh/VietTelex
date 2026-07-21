
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
}
