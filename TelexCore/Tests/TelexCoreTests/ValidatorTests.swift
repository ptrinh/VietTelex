import XCTest
@testable import TelexCore

final class ValidatorTests: XCTestCase {

    func testValidSyllables() {
        let valid = [
            "đây", "tiếng", "việt", "hóa", "huyền", "người", "quân", "thuở",
            "nước", "đồng", "hòa", "toán", "học", "mía", "của", "quý", "già",
            "nghiêng", "ngoài", "chuyển", "trường",
            "an", "em", "ơn", "ưng", "ăn", "ân", "ba", "bàn", "cáp", "cạnh",
            "yêu", "uống", "khỏe", "thúy", "ngọc", "giường", "khuya",
        ]
        for w in valid {
            XCTAssertTrue(SyllableValidator.isValidSyllable(w), "should be valid: \(w)")
        }
    }

    func testInvalidSyllables() {
        let invalid = [
            "windows", "xyz", "strong", "hello", "abc", "cn", "ng",
            "hoc",   // stop coda 'c' needs sắc/nặng
            "ngoc",  // same
            "cap",   // stop coda 'p' needs sắc/nặng
            "zzz",
            "wxyz",
        ]
        for w in invalid {
            XCTAssertFalse(SyllableValidator.isValidSyllable(w), "should be invalid: \(w)")
        }
    }

    func testToneCodaConstraint() {
        // Stop codas p/t/c/ch only accept sắc (acute) or nặng (dot).
        XCTAssertTrue(SyllableValidator.isValidSyllable("các"))   // acute ok
        XCTAssertTrue(SyllableValidator.isValidSyllable("cạc"))   // dot ok
        XCTAssertFalse(SyllableValidator.isValidSyllable("càc"))  // grave not ok
        XCTAssertFalse(SyllableValidator.isValidSyllable("cảc"))  // hook not ok
        XCTAssertFalse(SyllableValidator.isValidSyllable("cãc"))  // tilde not ok
        XCTAssertFalse(SyllableValidator.isValidSyllable("cac"))  // none not ok

        // Non-stop codas accept any tone.
        XCTAssertTrue(SyllableValidator.isValidSyllable("càn"))
        XCTAssertTrue(SyllableValidator.isValidSyllable("cạnh"))
        XCTAssertTrue(SyllableValidator.isValidSyllable("cảng"))
    }

    func testOnsetRules() {
        XCTAssertTrue(SyllableValidator.isValidSyllable("nghe"))
        XCTAssertTrue(SyllableValidator.isValidSyllable("nghĩ"))
        XCTAssertTrue(SyllableValidator.isValidSyllable("quà"))
        XCTAssertTrue(SyllableValidator.isValidSyllable("gì"))    // g + i (not gi onset)
        XCTAssertTrue(SyllableValidator.isValidSyllable("gia"))   // gi onset + a
        XCTAssertFalse(SyllableValidator.isValidSyllable("fga"))  // f not a valid onset
        XCTAssertFalse(SyllableValidator.isValidSyllable(""))     // empty
    }

    // isValidPrefix underpins live spell-check (G2). SAFETY: every prefix of a valid
    // Vietnamese word — and every bare Telex intermediate — must be accepted, or a
    // real word would freeze mid-typing.
    func testValidPrefixAcceptsRealWords() {
        XCTAssertTrue(SyllableValidator.isValidPrefix(""))       // empty = valid start
        // Every prefix (by scalar) of these composed words must be a valid prefix.
        let words = ["người", "trường", "được", "nước", "thương", "đường", "tiếng",
                     "việt", "nguyễn", "khỏe", "thủy", "quốc", "khuya", "uống",
                     "giường", "chuyện", "nghiêng", "hoàng", "quyển", "mía", "của",
                     "sương", "mượn", "tươi", "ngoáy", "đâu"]
        for w in words {
            let scalars = Array(w.unicodeScalars)
            for i in 1...scalars.count {
                let prefix = String(String.UnicodeScalarView(scalars[0..<i]))
                XCTAssertTrue(SyllableValidator.isValidPrefix(prefix),
                              "prefix '\(prefix)' of '\(w)' must be valid")
            }
        }
        // Bare Telex intermediates (before the diacritic lands) must also pass.
        for p in ["uo", "uoi", "uon", "uong", "uoc", "ie", "tie", "nguoi", "ngh",
                  "ng", "q", "qu", "gi", "kh", "tr", "oa", "uy", "uya", "hoa"] {
            XCTAssertTrue(SyllableValidator.isValidPrefix(p), "intermediate '\(p)' must be valid")
        }
    }

    // EFFECT: sequences that cannot become a Vietnamese syllable are rejected, so the
    // engine freezes on foreign words / URLs.
    func testValidPrefixRejectsGarbage() {
        for p in ["gôg", "gôgl", "goog", "st", "str", "xz", "bd", "fgh", "web",
                  "aoe", "spl", "wht", "js"] {
            XCTAssertFalse(SyllableValidator.isValidPrefix(p), "'\(p)' must be rejected")
        }
    }
}
