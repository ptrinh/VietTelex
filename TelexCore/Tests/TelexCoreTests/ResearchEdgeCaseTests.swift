// ResearchEdgeCaseTests.swift
// Edge cases harvested from the issue trackers of other Vietnamese macOS IMEs
// (PHTV, OpenKey, EVKey) and from the compositional-validator/Rule-A research
// pass. Each test names its source. These pin down VietTelex's behavior on the
// exact inputs other engines got wrong — either verifying we handle them, or
// documenting the accepted trade-off so a future change is a conscious one.

import XCTest
@testable import TelexCore

/// Feed a whole key sequence into an existing engine.
private func type(_ e: inout TelexEngine, _ keys: String) {
    for ch in keys { _ = e.feed(ch) }
}

/// Compose in a fresh engine (defaults: Rule A on, spell-check off).
private func compose(_ keys: String) -> String {
    var e = TelexEngine()
    type(&e, keys)
    return e.composed
}

/// Type keys then commit at a word boundary with auto-restore on.
private func commit(_ keys: String) -> String {
    var e = TelexEngine()
    type(&e, keys)
    return e.commitText(autoRestore: true)
}

final class ResearchEdgeCaseTests: XCTestCase {

    // MARK: - English words that mangle in other engines

    // PHTV #176: "wwork" → "wỏk" (double-w escape + tone applied to the rest).
    // VietTelex: a leading w marks the whole word English — everything literal.
    func testDoubleWEnglishWord() {
        XCTAssertEqual(compose("wwork"), "wwork")
        XCTAssertEqual(commit("wwork"), "wwork")
        XCTAssertEqual(compose("www"), "www")          // URL prefix
        XCTAssertEqual(compose("wwwgooglecom"), "wwwgooglecom")
    }

    // PHTV #175 / #180: English words with an embedded tone key kept receiving
    // diacritics ("career" → "cảee"-style). Rule A: tone consumed mid-word +
    // more keys → literal live and committed as typed.
    func testEmbeddedToneEnglishWords() {
        for w in ["career", "install", "master", "faster", "poster"] {
            XCTAssertEqual(compose(w), w, "live literal: \(w)")
            XCTAssertEqual(commit(w), w, "commit as typed: \(w)")
        }
        // "under" ends ON the tone key (r), so Rule A stays quiet — but the
        // composed "ủnde" is not a valid syllable, so plain auto-restore still
        // hands back the raw word at the boundary.
        XCTAssertEqual(compose("under"), "ủnde")
        XCTAssertEqual(commit("under"), "under")
    }

    // PHTV #204: "brew install" in an address bar became "brew iíntall" (that
    // half is app-side pacing, but the engine half — "install" must never carry
    // a tone at the boundary — is pinned here).
    func testInstallNeverCarriesTone() {
        var e = TelexEngine()
        e.liveSpellCheck = true                        // app default
        type(&e, "install")
        XCTAssertEqual(e.composed, "install")
        XCTAssertEqual(e.commitText(autoRestore: true), "install")
    }

    // PHTV #175 (career, beef): double-vowel English words. Documented MISSES —
    // the tone key (or none) is terminal, so Rule A cannot distinguish them
    // from Vietnamese; they commit as the (valid) Vietnamese syllable.
    // A dictionary would be required — out of scope by design (DESIGN.md).
    func testDoubleVowelEnglishKnownMisses() {
        XCTAssertEqual(commit("beef"), "bề")     // ee→ê, terminal f = huyền
        XCTAssertEqual(commit("door"), "dổ")     // oo→ô, terminal r = hỏi
        XCTAssertEqual(commit("seen"), "sên")    // no tone key at all
        XCTAssertEqual(commit("soon"), "sôn")
    }

    // English double-letter cancel gesture: "coffee" loses one f to the
    // double-tone cancel (f=huyền, f=cancel→literal) and the cancel suppresses
    // restore — same accepted trade-off as miss/class in the golden tests.
    func testDoubleToneKeyEnglishTradeOff() {
        XCTAssertEqual(compose("coffee"), "cofee")
        XCTAssertEqual(commit("coffee"), "cofee")
    }

    // Uppercase English is detected the same way (Rule A is case-blind).
    func testUppercaseEnglishDetection() {
        XCTAssertEqual(commit("Test"), "Test")
        XCTAssertEqual(commit("TEST"), "TEST")
        XCTAssertEqual(commit("List"), "List")
    }

    // MARK: - Vietnamese near-misses from other trackers

    // PHTV #183: "leest" lost its diacritics. Here ee lands the mark BEFORE the
    // tone key, so the mark-before-tone protection keeps it Vietnamese.
    func testLeestStaysVietnamese() {
        XCTAssertEqual(compose("leest"), "lết")
        XCTAssertEqual(commit("leest"), "lết")
    }

    // PHTV #178: "Theer" → "Thể" (uppercase first letter + doubler + hook).
    func testCapitalizedTheer() {
        XCTAssertEqual(compose("Theer"), "Thể")
        XCTAssertEqual(commit("Theer"), "Thể")
    }

    // OpenKey #312: "chưa" + a gives "chưâ" (circumflex lands on the a) instead
    // of the arguably-expected "chưaa". VietTelex composes the same way other
    // Telex engines do, but "ưâ" is not a valid nucleus, so the boundary
    // auto-restore hands back the raw keys — the user never commits "chưâ".
    func testChuaPlusAAutoRestores() {
        XCTAssertEqual(compose("chuwaa"), "chưâ")   // current composition behavior
        XCTAssertFalse(SyllableValidator.isValidSyllable("chưâ"))
        XCTAssertEqual(commit("chuwaa"), "chuwaa")  // boundary reverts to raw
    }

    // Rule A trade-off (from the spec research): a mark typed AFTER the tone key
    // ("cusw" for cứ, "nguoifw" for người) reads as English and restores. The
    // tone-early kill-switch is the escape hatch for typists with that habit;
    // the canonical orders ("cuws", "nguoiwf") are unaffected.
    func testMarkAfterToneTradeOff() {
        XCTAssertEqual(commit("cusw"), "cusw")       // documented trade-off
        XCTAssertEqual(commit("nguoifw"), "nguoifw")
        XCTAssertEqual(commit("cuws"), "cứ")         // canonical order fine
        XCTAssertEqual(commit("nguoiwf"), "người")
    }

    // OpenKey #327: z-initial loanwords must keep composing (z is only "clear
    // tone" once a vowel exists). Extends the existing LoanConsonant tests with
    // the exact words from the issue.
    func testZInitialLoanwords() {
        XCTAssertEqual(compose("zui"), "zui")        // "vui" slang
        XCTAssertEqual(compose("zooo"), "zoo")       // circumflex then cancel
        var e = TelexEngine()
        e.liveSpellCheck = true
        type(&e, "zalo")
        XCTAssertEqual(e.composed, "zalo")
    }

    // MARK: - Shortcut table with Vietnamese keys (OpenKey #313)

    // A shortcut whose key contains ư (typed as uw / w) must expand, including
    // the capitalization variants.
    func testShortcutKeyWithMarkedVowel() {
        let table = ["ư": "ước mơ"]
        XCTAssertEqual(ShortcutExpander.expansion(for: "ư", table: table), "ước mơ")
        XCTAssertEqual(ShortcutExpander.expansion(for: "Ư", table: table), "Ước mơ")
        // The engine really produces "ư" from raw "uw", so the lookup connects.
        var e = TelexEngine()
        type(&e, "uw")
        XCTAssertEqual(ShortcutExpander.expansion(for: e.commitText(autoRestore: true),
                                                  table: table), "ước mơ")
    }

    // MARK: - Validator robustness (research pass)

    // Uppercase and mixed-case composed words validate (detone handles both
    // cases; the new-in-delta syllables too).
    func testValidatorCaseInsensitive() {
        for w in ["TIẾNG", "Quỳnh", "QUỲNH", "GIẾC", "Người", "ĐƯỢC"] {
            XCTAssertTrue(SyllableValidator.isValidSyllable(w), "should be valid: \(w)")
        }
    }

    // NFD (decomposed) input is rejected, not misparsed — the engine emits NFC
    // precomposed only (DESIGN.md), so combining marks can only arrive from
    // foreign text and must fail cleanly.
    func testDecomposedUnicodeRejected() {
        let nfd = "tiếng".decomposedStringWithCanonicalMapping
        // Sanity: really decomposed (more scalars than the NFC form; note Swift
        // String == is canonical-equivalent, so compare scalar counts).
        XCTAssertGreaterThan(nfd.unicodeScalars.count, "tiếng".unicodeScalars.count)
        XCTAssertFalse(SyllableValidator.isValidSyllable(nfd))
        XCTAssertFalse(SyllableValidator.isValidPrefix(nfd))
        // Precomposed equivalent stays valid.
        XCTAssertTrue(SyllableValidator.isValidSyllable("tiếng"))
    }

    // Structural garbage fails fast: two tones, digits/punctuation, consonant
    // after a vowel coda, đ in coda position, over-long input (early-out).
    func testValidatorStructuralGarbage() {
        XCTAssertFalse(SyllableValidator.isValidSyllable("áà"))     // two tones
        XCTAssertFalse(SyllableValidator.isValidSyllable("hoa1"))
        XCTAssertFalse(SyllableValidator.isValidSyllable("hoa!"))
        XCTAssertFalse(SyllableValidator.isValidSyllable("ađa"))    // đ as coda
        XCTAssertFalse(SyllableValidator.isValidSyllable("đ"))      // no vowel
        XCTAssertFalse(SyllableValidator.isValidSyllable(String(repeating: "a", count: 40)))
        XCTAssertFalse(SyllableValidator.isValidSyllable("nghiêngnghiêng"))
    }

    // uơ nucleus is open-only outside qu: quơn is valid (qu + ơn) but huơn is
    // not (uơ takes no coda) — a distinction the flat rime table blurred.
    func testUoNucleusClosureRules() {
        XCTAssertTrue(SyllableValidator.isValidSyllable("quơn"))
        XCTAssertTrue(SyllableValidator.isValidSyllable("huơ"))
        XCTAssertFalse(SyllableValidator.isValidSyllable("huơn"))
    }
}
