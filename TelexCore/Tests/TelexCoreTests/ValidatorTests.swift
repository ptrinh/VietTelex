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

    // Every declared onset must, on its own, form at least one valid syllable when
    // followed by a simple rime — guards the onset table against silent omission.
    func testEveryOnsetComposesAValidSyllable() {
        // A rime each onset legally combines with (kept simple + all-tone so the only
        // thing under test is the onset). "a" works for every consonant onset.
        let onsets = ["", "b", "c", "ch", "d", "đ", "g", "gh", "gi", "h", "k", "kh",
                      "l", "m", "n", "ng", "ngh", "nh", "p", "ph", "qu", "r", "s",
                      "t", "th", "tr", "v", "x", "z", "dz"]
        for on in onsets {
            // gh/ngh/k only precede front vowels e/i/ê; qu needs a following vowel.
            let rime: String
            switch on {
            case "gh", "ngh", "k": rime = "e"
            case "qu", "gi":       rime = "a"
            default:               rime = "a"
            }
            let w = on + rime
            XCTAssertTrue(SyllableValidator.isValidSyllable(w), "onset '\(on)' → '\(w)' should be valid")
        }
    }

    // Non-onsets and illegal clusters must be rejected as full syllables.
    func testInvalidOnsetsRejected() {
        for w in ["fa", "wa", "ja", "spa", "cla", "bra", "tla", "pfa", "gna", "hna"] {
            XCTAssertFalse(SyllableValidator.isValidSyllable(w), "'\(w)' should be invalid (bad onset)")
        }
    }

    // A representative sweep of rimes with a fixed onset, positive and negative.
    func testRimeSweep() {
        // Sonorant/open rimes only here (they're valid toneless); stop-coda rimes
        // need a tone and are covered by testStopCodaToneMaskExhaustive.
        let validRimes = ["a", "ai", "am", "an", "ang", "anh", "ao", "au", "ay",
                          "ăn", "âm", "âu", "ây", "em", "eo", "ên", "êu", "im", "in",
                          "iêu", "iên", "oa", "oe", "oi", "ong", "ôi", "ơi", "uy",
                          "uôi", "uôn", "ưa", "ưng", "ươi", "ương", "yê"]
        for r in validRimes {
            XCTAssertTrue(SyllableValidator.isValidSyllable("t" + r) || SyllableValidator.isValidSyllable(r),
                          "rime '\(r)' should form a valid syllable")
        }
        let nonRimes = ["ea", "eou", "iiu", "uu", "oaa", "aeiou", "bb", "kk"]
        for r in nonRimes {
            XCTAssertFalse(SyllableValidator.isValidSyllable("t" + r), "rime '\(r)' should be invalid")
        }
    }

    // Full tone × stop-coda mask: sắc/nặng allowed, the other three (and none) rejected
    // — checked on -c, -ch, -p, -t across several nuclei.
    func testStopCodaToneMaskExhaustive() {
        let stops = ["ac", "ach", "ap", "at", "ôc", "êch", "op", "ut"]
        for base in stops {
            let toneless = "b" + base                          // e.g. "bac"
            XCTAssertFalse(SyllableValidator.isValidSyllable(toneless), "no tone on stop: \(toneless)")
            // Build acute/grave/hook/tilde/dot forms by toning the nucleus vowel.
            let acute = toned(toneless, .acute), dot = toned(toneless, .dot)
            let grave = toned(toneless, .grave), hook = toned(toneless, .hook), tilde = toned(toneless, .tilde)
            XCTAssertTrue(SyllableValidator.isValidSyllable(acute), "acute ok on \(toneless): \(acute)")
            XCTAssertTrue(SyllableValidator.isValidSyllable(dot), "dot ok on \(toneless): \(dot)")
            XCTAssertFalse(SyllableValidator.isValidSyllable(grave), "grave rejected: \(grave)")
            XCTAssertFalse(SyllableValidator.isValidSyllable(hook), "hook rejected: \(hook)")
            XCTAssertFalse(SyllableValidator.isValidSyllable(tilde), "tilde rejected: \(tilde)")
        }
    }

    /// Apply a tone to the first tone-able vowel of a toneless syllable (test helper).
    private func toned(_ word: String, _ tone: Tone) -> String {
        var out = String.UnicodeScalarView()
        var done = false
        for scalar in word.unicodeScalars {
            if !done, Tables.tonedTable[scalar.value] != nil {
                out.append(Unicode.Scalar(Tables.applyTone(scalar.value, tone))!)
                done = true
            } else {
                out.append(scalar)
            }
        }
        return String(out)
    }

    // MARK: - String façade edge cases

    func testValidSyllableStringFacadeEdges() {
        XCTAssertFalse(SyllableValidator.isValidSyllable(""))           // empty
        // Uppercase input is lowercased internally: same verdict as lowercase.
        XCTAssertTrue(SyllableValidator.isValidSyllable("VIỆT"))
        XCTAssertTrue(SyllableValidator.isValidSyllable("Người"))
        XCTAssertEqual(SyllableValidator.isValidSyllable("HÓA"),
                       SyllableValidator.isValidSyllable("hóa"))
        // A combining (decomposed) sequence has >1 scalar per Character → rejected
        // (the façade requires one precomposed scalar per character).
        let decomposed = "a\u{0301}"                                    // 'a' + combining acute = "á"
        XCTAssertFalse(SyllableValidator.isValidSyllable(decomposed), "decomposed input must be rejected")
        // A non-letter character makes the whole token invalid.
        XCTAssertFalse(SyllableValidator.isValidSyllable("a1"))
        XCTAssertFalse(SyllableValidator.isValidSyllable("hó-a"))
        // Two tones in one syllable is impossible → invalid.
        XCTAssertFalse(SyllableValidator.isValidSyllable("óá"))
    }

    func testValidPrefixStringFacadeEdges() {
        XCTAssertTrue(SyllableValidator.isValidPrefix(""))              // empty start
        // Uppercase prefixes accepted the same as lowercase.
        XCTAssertTrue(SyllableValidator.isValidPrefix("NGƯ"))
        XCTAssertEqual(SyllableValidator.isValidPrefix("TRƯ"),
                       SyllableValidator.isValidPrefix("trư"))
        // Decomposed / non-letter input rejected by the façade.
        XCTAssertFalse(SyllableValidator.isValidPrefix("a\u{0301}"))
        XCTAssertFalse(SyllableValidator.isValidPrefix("a1"))
    }

    // The class-based core and the String façade must agree on a broad word set.
    func testCoreAndFacadeAgree() {
        let words = ["đây", "người", "trường", "được", "windows", "hello", "xyz",
                     "quý", "già", "gì", "khỏe", "hoc", "cạc", "càc", "abc", "nghe"]
        for w in words {
            // Recompute via the class core directly and compare to the façade.
            var classes = [UInt8](); var tone: Tone = .none; var ok = true
            for ch in w.lowercased() {
                guard ch.unicodeScalars.count == 1, let s = ch.unicodeScalars.first else { ok = false; break }
                var toneless = ch
                if let (base, t) = Tables.detoneTable[s.value] {
                    toneless = Character(Unicode.Scalar(base)!)
                    if t != .none { if tone != .none { ok = false; break }; tone = t }
                }
                guard let cls = Tables.charClass[toneless] else { ok = false; break }
                classes.append(cls)
            }
            let core = ok && SyllableValidator.isValidSyllable(classes: classes, count: classes.count, tone: tone)
            XCTAssertEqual(core, SyllableValidator.isValidSyllable(w), "core/façade disagree on \(w)")
        }
    }
}
