// ImeTricksTests.swift
// Engine-level tests for the field-proven IME behaviours added on top of the core
// Telex engine: backspace-resume of the last committed word, the auto-restore
// whitelist, z/w/j/f loanword tolerance, gõ-tắt auto-caps, the repeated-key guard,
// and the Ctrl-tap word bypass.

import XCTest
@testable import TelexCore

/// Feed a whole key sequence into an existing engine.
private func type(_ e: inout TelexEngine, _ keys: String) {
    for ch in keys { _ = e.feed(ch) }
}

/// Compose in a fresh engine.
private func compose(_ keys: String) -> String {
    var e = TelexEngine()
    type(&e, keys)
    return e.composed
}

/// Compose with live spell-check on.
private func composeSpell(_ keys: String) -> String {
    var e = TelexEngine()
    e.liveSpellCheck = true
    type(&e, keys)
    return e.composed
}

/// Type keys then commit at a word boundary with auto-restore on.
private func commit(_ keys: String) -> String {
    var e = TelexEngine()
    type(&e, keys)
    return e.commitText(autoRestore: true)
}

// MARK: - 1. Backspace-resume of the last committed word

final class ResumeTests: XCTestCase {

    func testCleanCommitIsSaved() {
        var e = TelexEngine()
        type(&e, "hoa")
        XCTAssertEqual(e.commitText(autoRestore: true), "hoa")
        XCTAssertTrue(e.hasSavedWord)
        XCTAssertTrue(e.isEmpty)          // commit reset the live buffer
    }

    func testResumeReopensWordForEditing() {
        var e = TelexEngine()
        type(&e, "hoa")
        _ = e.commitText(autoRestore: true)
        XCTAssertTrue(e.resumeLastWord())
        XCTAssertEqual(e.composed, "hoa")
        // "hoa␣" + ⌫ + "f" → the forgotten tone lands: hòa (old style default).
        _ = e.feed("f")
        XCTAssertEqual(e.composed, "hòa")
        XCTAssertFalse(e.hasSavedWord)    // slot is one-shot
    }

    func testResumeRestoresTransformedWord() {
        var e = TelexEngine()
        type(&e, "truowng")               // trương
        XCTAssertEqual(e.commitText(autoRestore: true), "trương")
        XCTAssertTrue(e.resumeLastWord())
        XCTAssertEqual(e.composed, "trương")
        _ = e.feed("f")
        XCTAssertEqual(e.composed, "trường")
    }

    func testAutoRestoredCommitIsNotSaved() {
        var e = TelexEngine()
        type(&e, "gogles")                // "gógle"? -> invalid -> restored to raw
        let committed = e.commitText(autoRestore: true)
        XCTAssertEqual(committed, "gogles")   // raw keystrokes
        XCTAssertFalse(e.hasSavedWord)        // screen ≠ composed render: not resumable
    }

    func testCancelledWordIsResumable() {
        var e = TelexEngine()
        type(&e, "iss")                   // double-s cancel -> "is"
        XCTAssertEqual(e.commitText(autoRestore: true), "is")
        XCTAssertTrue(e.resumeLastWord())
        XCTAssertEqual(e.composed, "is")  // re-render reproduces the cancel
    }

    func testResumeOnEmptySlotFails() {
        var e = TelexEngine()
        XCTAssertFalse(e.resumeLastWord())
        type(&e, "hoa")
        XCTAssertFalse(e.resumeLastWord())   // nothing committed yet
    }

    func testClearSavedWord() {
        var e = TelexEngine()
        type(&e, "hoa")
        _ = e.commitText(autoRestore: true)
        e.clearSavedWord()
        XCTAssertFalse(e.hasSavedWord)
        XCTAssertFalse(e.resumeLastWord())
    }

    func testSavedWordSurvivesPlainReset() {
        // reset() ends a word; only clearSavedWord() (click/focus/app switch) or a
        // non-clean commit drops the slot.
        var e = TelexEngine()
        type(&e, "hoa")
        _ = e.commitText(autoRestore: true)
        e.reset()
        XCTAssertTrue(e.hasSavedWord)
    }

    func testCommitBoundaryAlsoSaves() {
        var e = TelexEngine()
        type(&e, "vieetj")                // việt
        XCTAssertEqual(e.commitBoundary(autoRestore: true), .none)   // clean
        XCTAssertTrue(e.resumeLastWord())
        XCTAssertEqual(e.composed, "việt")
    }

    func testCommitBoundaryRestoreClearsSlot() {
        var e = TelexEngine()
        type(&e, "gogles")
        if case .replace = e.commitBoundary(autoRestore: true) {} else {
            XCTFail("expected auto-restore replace")
        }
        XCTAssertFalse(e.hasSavedWord)
    }

    func testEmptyCommitKeepsPreviousSlotUntouched() {
        var e = TelexEngine()
        type(&e, "hoa")
        _ = e.commitText(autoRestore: true)
        XCTAssertEqual(e.commitBoundary(autoRestore: true), .none)   // nothing typed
        XCTAssertTrue(e.hasSavedWord)   // caller (controller) gates arming per commit
    }
}

// MARK: - 2/3a. Auto-restore whitelist

final class WhitelistTests: XCTestCase {

    func testWhitelistedWordIsNotRestored() {
        var e = TelexEngine()
        e.restoreWhitelist = ["zò"]
        type(&e, "zof")                   // z literal + huyền -> "zò", invalid syllable
        XCTAssertEqual(e.composed, "zò")
        XCTAssertEqual(e.commitText(autoRestore: true), "zò")
    }

    func testNonWhitelistedStillRestores() {
        var e = TelexEngine()
        e.restoreWhitelist = ["khác"]
        type(&e, "zof")
        XCTAssertEqual(e.commitText(autoRestore: true), "zof")   // reverted to raw
    }

    func testWhitelistIsCaseFolded() {
        var e = TelexEngine()
        e.restoreWhitelist = ["zò"]       // stored lowercase
        type(&e, "Zof")
        XCTAssertEqual(e.composed, "Zò")
        XCTAssertEqual(e.commitText(autoRestore: true), "Zò")
    }

    func testWhitelistSurvivesReset() {
        var e = TelexEngine()
        e.restoreWhitelist = ["zò"]
        e.reset()
        type(&e, "zof")
        XCTAssertEqual(e.commitText(autoRestore: true), "zò")
    }

    func testWhitelistedWordIsResumable() {
        var e = TelexEngine()
        e.restoreWhitelist = ["zò"]
        type(&e, "zof")
        _ = e.commitText(autoRestore: true)   // clean (word kept as composed)
        XCTAssertTrue(e.resumeLastWord())
        XCTAssertEqual(e.composed, "zò")
    }
}

// MARK: - 3b. z/w/j/f loanword-onset tolerance

final class LoanConsonantTests: XCTestCase {

    func testZInitialIsLiteralWithoutVowel() {
        // z used to be consumed as "clear tone" even with nothing to clear.
        XCTAssertEqual(compose("zalo"), "zalo")
        XCTAssertEqual(compose("zoo"), "zô")     // circumflex still applies after it
        XCTAssertEqual(compose("az"), "a")       // after a vowel z still clears tone
    }

    func testLoanOnsetsKeepComposingUnderSpellCheck() {
        // Without the tolerance, live spell-check froze these at the first key.
        XCTAssertEqual(composeSpell("zoo"), "zô")
        XCTAssertEqual(composeSpell("zooj"), "zộ")
        XCTAssertEqual(composeSpell("fowr"), "fở")
        XCTAssertEqual(composeSpell("jos"), "jó")
    }

    func testToleranceIsOnlyOneLeadingConsonant() {
        // Two impossible consonants: spell-check disables as before.
        XCTAssertEqual(composeSpell("fzoo"), "fzoo")
    }

    func testWInitialWordsStayLiteral() {
        XCTAssertEqual(composeSpell("windows"), "windows")
        XCTAssertEqual(composeSpell("was"), "was")
    }

    func testNonLoanForeignWordsStillFreeze() {
        XCTAssertEqual(composeSpell("github"), "github")
        XCTAssertEqual(composeSpell("google"), "gôgle")   // unchanged behaviour
    }

    func testEnglishLoanOnsetWordsRestoreAtBoundary() {
        // "just": the s is consumed as a tone ("jú"), then the trailing t trips
        // English detection (Rule A) — the word re-renders literally right away
        // and commits as typed.
        var e = TelexEngine()
        e.liveSpellCheck = true
        type(&e, "just")
        XCTAssertEqual(e.composed, "just")
        XCTAssertEqual(e.commitText(autoRestore: true), "just")

        // With detection off, the old path still holds: mid-word tone shows
        // ("jút") and the boundary auto-restore reverts it.
        var off = TelexEngine()
        off.liveSpellCheck = true
        off.detectEnglishTone = false
        type(&off, "just")
        XCTAssertEqual(off.composed, "jút")
        XCTAssertEqual(off.commitText(autoRestore: true), "just")
    }
}

// MARK: - 4. Gõ tắt auto-caps

final class ShortcutExpanderTests: XCTestCase {

    private let table = ["vn": "việt nam", "hn": "Hà Nội"]

    func testExactMatch() {
        XCTAssertEqual(ShortcutExpander.expansion(for: "vn", table: table), "việt nam")
        XCTAssertEqual(ShortcutExpander.expansion(for: "hn", table: table), "Hà Nội")
    }

    func testCapitalizedShortcutCapitalizesExpansion() {
        XCTAssertEqual(ShortcutExpander.expansion(for: "Vn", table: table), "Việt nam")
        XCTAssertEqual(ShortcutExpander.expansion(for: "Hn", table: table), "Hà Nội")
    }

    func testAllCapsShortcutUppercasesExpansion() {
        XCTAssertEqual(ShortcutExpander.expansion(for: "VN", table: table), "VIỆT NAM")
        XCTAssertEqual(ShortcutExpander.expansion(for: "HN", table: table), "HÀ NỘI")
    }

    func testExactCaseEntryWins() {
        var t = table
        t["VN"] = "Vietnam Airlines"
        XCTAssertEqual(ShortcutExpander.expansion(for: "VN", table: t), "Vietnam Airlines")
    }

    func testSingleUppercaseLetterCapitalizes() {
        XCTAssertEqual(ShortcutExpander.expansion(for: "V", table: ["v": "vâng"]), "Vâng")
    }

    func testNoMatchReturnsNil() {
        XCTAssertNil(ShortcutExpander.expansion(for: "xx", table: table))
        XCTAssertNil(ShortcutExpander.expansion(for: "vN", table: table))  // first letter lowercase
        XCTAssertNil(ShortcutExpander.expansion(for: "", table: table))
    }
}

// MARK: - 5. Repeated-key guard

final class RepeatedKeyGuardTests: XCTestCase {

    func testFourIdenticalKeysFreezeTheWord() {
        // After jjjj (vim spam), NOTHING transforms for the rest of the word.
        XCTAssertEqual(compose("jjjjaa"), "jjjjaa")     // aa would otherwise be â
        XCTAssertEqual(compose("kkkkas"), "kkkkas")     // s would otherwise tone the a
    }

    func testGuardSuppressesBoundaryRestore() {
        XCTAssertEqual(commit("jjjj"), "jjjj")
        XCTAssertEqual(commit("kkkkas"), "kkkkas")      // left exactly as typed
    }

    func testGuardIsCaseInsensitive() {
        XCTAssertEqual(compose("jJjJaa"), "jJjJaa")
    }

    func testLegitimateTelexDoublesUnaffected() {
        XCTAssertEqual(compose("caay"), "cây")          // aa
        XCTAssertEqual(compose("ddeem"), "đêm")         // dd + ee
        XCTAssertEqual(compose("toos"), "tố")           // oo
        XCTAssertEqual(compose("aaa"), "aa")            // triple-a undo latch
        XCTAssertEqual(compose("ass"), "as")            // double-s undo latch
        XCTAssertEqual(compose("aaaa"), "aaa")          // 4th key literal, same as before
    }

    func testGuardClearsAtBoundary() {
        var e = TelexEngine()
        type(&e, "jjjj")
        _ = e.commitText(autoRestore: true)
        type(&e, "caay")
        XCTAssertEqual(e.composed, "cây")               // next word transforms again
    }

    func testGuardPersistsAcrossBackspaceWithinWord() {
        var e = TelexEngine()
        type(&e, "jjjj")
        _ = e.backspace()
        type(&e, "aa")
        XCTAssertEqual(e.composed, "jjjaa")             // still frozen for this word
    }
}

// MARK: - 6. Ctrl-tap temp bypass (engine side)

final class WordBypassTests: XCTestCase {

    func testBypassRewindsTransformsToRaw() {
        var e = TelexEngine()
        type(&e, "hoaf")                                // hòa on screen
        XCTAssertEqual(e.composed, "hòa")
        let action = e.bypassCurrentWord()
        XCTAssertEqual(e.composed, "hoaf")              // literal raw keystrokes
        if case let .replace(bs, insert) = action {
            XCTAssertEqual(bs, 2)                       // h|òa -> h|oaf
            XCTAssertEqual(insert, "oaf")
        } else {
            XCTFail("expected a replace action, got \(action)")
        }
    }

    func testKeysAfterBypassStayLiteral() {
        var e = TelexEngine()
        type(&e, "te")
        _ = e.bypassCurrentWord()
        type(&e, "st")
        XCTAssertEqual(e.composed, "test")              // s did not become a tone
        XCTAssertEqual(e.commitText(autoRestore: true), "test")
    }

    func testBypassBeforeTypingArmsTheComingWord() {
        var e = TelexEngine()
        _ = e.bypassCurrentWord()                       // Ctrl tap on empty buffer
        type(&e, "test")
        XCTAssertEqual(e.composed, "test")              // would be "tét" otherwise
        XCTAssertEqual(e.commitText(autoRestore: true), "test")
    }

    func testBypassClearsAtWordBoundary() {
        var e = TelexEngine()
        _ = e.bypassCurrentWord()
        type(&e, "test")
        _ = e.commitText(autoRestore: true)
        type(&e, "hoas")
        XCTAssertEqual(e.composed, "hóa")               // next word composes normally
        // ("test" as the next word would also stay literal — via Rule A, not
        // via a leaked bypass; see testWithoutBypassTestBecomesTet.)
    }

    func testBypassSurvivesBackspace() {
        var e = TelexEngine()
        _ = e.bypassCurrentWord()
        type(&e, "test")
        _ = e.backspace()                               // "tes"
        type(&e, "st")
        XCTAssertEqual(e.composed, "tesst")             // still literal
    }

    func testBypassAlsoDisablesLiveSpellCheckPath() {
        var e = TelexEngine()
        e.liveSpellCheck = true
        _ = e.bypassCurrentWord()
        type(&e, "test")
        XCTAssertEqual(e.composed, "test")
        XCTAssertEqual(e.commitText(autoRestore: true), "test")
    }

    func testWithoutBypassTestBecomesTet() {
        // Historical control case: "test" is a valid Vietnamese syllable stream
        // (tét) that the validator alone cannot catch — the original reason the
        // Ctrl-tap escape hatch exists. English tone-position detection (Rule A)
        // now catches it by default; with detection off the old behaviour shows.
        XCTAssertEqual(compose("test"), "test")     // Rule A: literal, live
        XCTAssertEqual(commit("test"), "test")
        var e = TelexEngine()
        e.detectEnglishTone = false
        type(&e, "test")
        XCTAssertEqual(e.composed, "tét")
        XCTAssertEqual(e.commitText(autoRestore: true), "tét")
    }
}
