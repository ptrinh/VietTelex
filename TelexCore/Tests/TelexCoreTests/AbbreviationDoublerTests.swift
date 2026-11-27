import XCTest
@testable import TelexCore

// ABBREVIATION-Đ (feature 2026-08-06, maintainer spec): Vietnamese initialisms that
// carry a Đ anywhere — not just at the start — typed by doubling "d" the normal Telex
// way: "VNĐ" (Việt Nam Đồng), "HTĐ" (Hợp tác xã?), "HĐND" (Hội đồng nhân dân), "ĐSQ"/
// "ĐHQG" (already worked — Đ was the FIRST letter, so live-spell-check's freeze never
// got a chance to block the doubler). Case must be ONE case throughout — all-caps OR
// all-lowercase, never mixed — matching how a real initialism is typed.
//
// The blocker this fixes: live-spell-check freezes a word to literal ASCII the moment
// its prefix can no longer be a valid Vietnamese syllable — "VN" (two bare consonants)
// triggers that on the SECOND key, so the dd→Đ doubler never even ran for the D's that
// follow. The fix is narrowly scoped to keep two families of existing behavior intact:
//   - English words with "dd" (add/odd/ladder/kidding/middle/address…) ALWAYS carry a
//     vowel before the "dd" — the exception requires a bare-consonant prefix (no vowel
//     anywhere), so it structurally cannot fire on them.
//   - Mixed-case input ("Vndd", "vnDD") is a real typing attempt, not an initialism —
//     rejected by the same-case requirement.
final class AbbreviationDoublerTests: XCTestCase {

    private func commit(_ keys: String) -> String {
        var e = TelexEngine()
        e.freeMarking = true
        e.liveSpellCheck = true
        for ch in keys { _ = e.feed(ch) }
        return e.commitText(autoRestore: true)
    }

    func testNewAbbreviationsWithDInTheMiddleOrEnd() {
        for (keys, want) in [("VNDD", "VNĐ"), ("vndd", "vnđ"),
                             ("HTDD", "HTĐ"), ("htdd", "htđ"),
                             ("HDDND", "HĐND"), ("hddnd", "hđnd"),
                             ("NDDND", "NĐND")] {
            XCTAssertEqual(commit(keys), want, keys)
        }
    }

    /// Y is an initial like any other in an initialism ("YKTĐ" = ý kiến thẩm định).
    func testYDoesNotEndTheAbbreviationShape() {
        for (keys, want) in [("YKTDD", "YKTĐ"), ("yktdd", "yktđ"), ("DDYT", "ĐYT")] {
            XCTAssertEqual(commit(keys), want, keys)
        }
        // A real vowel still exits the rule; mixed case too.
        XCTAssertEqual(commit("YADD"), "YADD")
        XCTAssertEqual(commit("Yktdd"), "Yktdd")
    }

    /// ALL-CAPS initialisms that carry a vowel before the Đ ("UBĐ"), and "ÔB" (ông bà),
    /// report 2026-11-27. English "dd" follows a vowel, so those still restore.
    func testCapsInitialismWithAVowelKeepsItsDBar() {
        for (keys, want) in [("UBDD", "UBĐ"), ("UBDDT", "UBĐT"), ("OOB", "ÔB"),
                             ("OOTC", "ÔTC"), ("UWCV", "ƯCV"), ("OOG", "ÔG"), ("TOOB", "TÔB"),
                             ("BCHTUW", "BCHTƯ"), ("BCOO", "BCÔ"), ("TTAAL", "TTÂL"), ("HSAWN", "HSĂN"),
                             ("BCHTUWW", "BCHTUW"), ("BCOOO", "BCOO")] {
            XCTAssertEqual(commit(keys), want, keys)
        }
        for keys in ["ADD", "ODD", "ADDRESS", "LADDER", "MIDDLE", "AAT", "bchtuw", "Bchtuw",
                     "SLEEP", "SPOON", "STRAW", "BROWN", "CROWD", "GROW", "SNOW", "SLOW", "FLOW", "BLOW",
                     "CROWN", "THROW", "SCREEN", "SHEET", "SHEEP", "STEEL", "STEEP", "SWEEP", "GREET",
                     "FREEZE", "BREEZE", "SNEEZE", "KNEE", "FLEE", "GLEE", "SPREE", "SHOOT", "SCOOP",
                     "STOOL", "SPOOL", "BLOOM", "BROOM", "GROOM", "GLOOM", "PROOF", "TROOP", "DROOL",
                     "CLAW", "FLAW", "SPAWN", "DRAWN", "SHAWL", "CRAWL", "BRAWL", "PRAWN",
                     "SCOWL", "GROWL", "PROWL", "FROWN", "DROWN", "CLOWN", "PLOW", "GLOW", "STOW",
                     "KNOWN", "SHOWN", "GROWN", "BLOWN", "FLOWN", "THROWN", "GROWTH", "BROWSER",
                     "SPEECH", "STREAM", "FREEDOM", "GREECE", "CREEK", "CREEP", "BLEED", "BREED",
                     "PREEN", "TWEED", "SKEW", "SCREW", "SHREW", "KNEW", "CHROME", "SPRING", "XBOX", "HTTP",
                     "CSS", "HTML", "CRAAP", "KPOP", "ubdd", "Ubdd", "BOOK", "OOPS",
                     "GOOD", "NEED", "FEEL", "SEE", "WEEK", "FREE", "COOL", "ZOOM",
                     "TOOL", "FOOD", "DOOR", "LOOK", "KEEP", "MEET", "SEEN", "ADDED",
                     "HIDDEN", "SUDDEN", "GOOGLE", "FACEBOOK", "MACBOOK", "NOTEBOOK", "FEEDBACK",
                     "COFFEE", "SPEED", "STREET", "SCHOOL", "GREEN", "THREE", "EEG", "AAC", "OOP",
                     "OOTD", "AAPL", "UWB", "UWP", "AWK", "AWS", "HOW", "NOW", "LAW", "SAW",
                     "WWW", "AWARD", "AWAY", "SWEET", "TWEET", "AGREE", "CHEESE",
                     "BLOOD", "FLOOR", "SMOOTH", "CHOOSE", "BOOT", "ROOT", "FOOT", "POOL", "WOOD",
                     "DEEP", "FEED", "SEED", "FEE", "ZOO", "TODD", "BUDDY",
                     "PUDDING", "WEDDING", "MOOD", "HOOK", "COOK", "LOOP", "SOON",
                     "GOOSE", "LOOSE", "WOW", "ROW", "SHOW", "KNOW",
                     "DRAW", "RAW", "JAW", "PAW", "OWE", "AWE", "SQL", "USB"] {
            XCTAssertEqual(commit(keys), keys, keys)
        }
    }

    /// Already worked before this feature (Đ is the FIRST letter, so the freeze
    /// hadn't triggered yet when the doubler ran) — must not regress.
    func testDInitialAbbreviationsStillWork() {
        XCTAssertEqual(commit("DDSQ"), "ĐSQ")
        XCTAssertEqual(commit("DDHQG"), "ĐHQG")
        XCTAssertEqual(commit("DDN"), "ĐN")
        XCTAssertEqual(commit("ddsq"), "đsq")
    }

    /// The escape hatch (double-key cancel) still yields a literal "dd", in both cases —
    /// this is the pre-existing mechanism, now reachable mid-word too.
    func testCancelStillYieldsLiteralDD() {
        XCTAssertEqual(commit("DDDR"), "DDR")
        XCTAssertEqual(commit("ddd"), "dd")
    }

    /// Mixed case is a real typing attempt, not an initialism — the exception must
    /// never fire, so these stay exactly as typed (no transform, no restore needed
    /// since nothing changed).
    func testMixedCaseNeverTriggersTheException() {
        for keys in ["Vndd", "vnDD", "VnDD", "vnDd"] {
            XCTAssertEqual(commit(keys), keys, keys)
        }
    }

    /// The exception requires a bare-consonant prefix (no vowel) — every one of these
    /// English words carries a vowel before its "dd", so the doubler must never fire
    /// and the dictionary/validator restore must still protect them, in both cases.
    func testEnglishWordsWithDdStillProtected() {
        for w in ["add", "odd", "midd", "ladd", "kidd", "address"] {
            XCTAssertEqual(commit(w), w, w)
            XCTAssertEqual(commit(w.uppercased()), w.uppercased(), w.uppercased())
        }
    }

    /// A vowel anywhere after the consonant run exits the abbreviation rule — this is
    /// the exact boundary case the maintainer spec drew the line at (a vowel means it
    /// might be a real word attempt, not purely an initialism).
    func testTrailingVowelExitsTheAbbreviationRule() {
        XCTAssertEqual(commit("ddsqa"), "ddsqa")
    }

    /// Backspace over the Đ must cleanly shrink back to the bare-consonant prefix, and
    /// retyping must re-double correctly (no desync between forward typing and ⌫).
    func testBackspaceOverTheDAndRetype() {
        var e = TelexEngine()
        e.freeMarking = true
        e.liveSpellCheck = true
        for ch in "VNDD" { _ = e.feed(ch) }
        XCTAssertEqual(e.composed, "VNĐ")
        _ = e.backspace()
        XCTAssertEqual(e.composed, "VN")
        _ = e.feed("D")
        XCTAssertEqual(e.composed, "VND")
        _ = e.feed("D")
        XCTAssertEqual(e.composed, "VNĐ")
    }

    /// VNI spells Đ with a digit (9), not by doubling letters — this feature must not
    /// touch VNI at all.
    func testVniModeUnaffected() {
        var e = TelexEngine()
        e.vniMode = true
        e.liveSpellCheck = true
        for ch in "VNDD" { _ = e.feed(ch) }
        XCTAssertEqual(e.composed, "VNDD", "VNI doesn't double letters for Đ")
    }
}
