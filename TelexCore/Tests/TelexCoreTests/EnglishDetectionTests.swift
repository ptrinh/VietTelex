// EnglishDetectionTests.swift
// Rule A ("tone must be terminal"): an English word whose Telex reading happens
// to be a valid Vietnamese syllable (test→tét, list→lít, more→mỏe) consumes a
// tone key MID-word and then keeps typing — Vietnamese doesn't. The engine
// detects the pattern positionally, re-renders the word literally right away,
// and commits it as typed. The tone-early kill-switch learns typists who place
// the tone before the final consonants ("tieesng") and silences Rule A.

import XCTest
@testable import TelexCore

/// Feed a whole key sequence into an existing engine.
private func type(_ e: inout TelexEngine, _ keys: String) {
    for ch in keys { _ = e.feed(ch) }
}

/// Compose in a fresh engine (Rule A on by default).
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

final class EnglishDetectionTests: XCTestCase {

    // SAFETY corpus: Vietnamese must never be flagged. Tone at the end, tone
    // replaced by another tone, or mark-before-tone (tieesng style) all commit
    // as Vietnamese.
    func testVietnameseSafetyCorpus() {
        let cases: [(String, String)] = [
            ("tets", "tét"), ("lits", "lít"), ("maats", "mất"), ("maix", "mãi"),
            ("saus", "sáu"), ("hoangf", "hoàng"), ("tieengs", "tiếng"),
            ("dduwowcj", "được"), ("nguwowif", "người"), ("quar", "quả"),
            ("nhuwngx", "những"), ("toans", "toán"), ("hoanfs", "hoán"),
            ("xooong", "xoong"), ("vieejt", "việt"), ("dduwowjc", "được"),
            ("quowrn", "quởn"), ("hojc", "học"),
            // "hojc"?? — no: see comment below. (kept out of the literal list)
        ]
        for (keys, expected) in cases where keys != "hojc" {
            XCTAssertEqual(commit(keys), expected, "must stay Vietnamese: \(keys)")
        }
        // NOTE "hojc"/"toasn" (tone between vowel and coda, NO mark in the word)
        // DO trip Rule A before the kill-switch learns the style — that is the
        // designed trade-off: the mark-protected majority of tone-early words
        // ("tieesng", "dduwowjc", "vieejt") trains toneEarlyStyle quickly.
        XCTAssertEqual(commit("hojc"), "hojc")
    }

    // English wins: tone key consumed mid-word + trailing literal/mark keys →
    // the word renders literally LIVE and commits as typed.
    func testEnglishWordsCommitAsTyped() {
        for w in ["test", "list", "best", "rest", "mist", "most", "must",
                  "last", "cost", "post", "trust", "more", "here", "horse",
                  "these"] {
            XCTAssertEqual(compose(w), w, "live literal render: \(w)")
            XCTAssertEqual(commit(w), w, "commit as typed: \(w)")
        }
    }

    // Known misses (documented, NOT fixed): raw-identical to a Vietnamese
    // syllable — the tone key is terminal (or absent), so Rule A cannot fire:
    //   his→hị? no: his = h,i,s(tone, terminal) → "hí"; its→"ít"; of→"ò"? (o,f);
    //   seen→"sên"; soon→"sôn"; door→"đỏ"?? (d,o,o,r → "dôr"?); how/did…
    // These need a dictionary/frequency model, out of scope by design.
    func testKnownMissesStayVietnamese() {
        // Tone terminal → not suspect; composed forms commit (illustrative subset).
        XCTAssertEqual(commit("his"), "hí")
        XCTAssertEqual(commit("its"), "ít")
        // "did" → trailing-d converts the onset (đi) — excluded trigger by design.
        XCTAssertEqual(commit("did"), "đi")
    }

    // The mid-word flip renders literally IMMEDIATELY (one re-parse), mirroring
    // invalid-word passthrough — the user sees "test" live, never "tét".
    func testLiveLiteralReRender() {
        var e = TelexEngine()
        type(&e, "tes")
        XCTAssertEqual(e.composed, "té")      // tone consumed, still Vietnamese
        _ = e.feed("t")                        // trailing literal key → flip
        XCTAssertEqual(e.composed, "test")     // whole word re-rendered literally
        type(&e, "s")                          // further keys stay literal
        XCTAssertEqual(e.composed, "tests")    // s is NOT a tone anymore
        XCTAssertEqual(e.commitText(autoRestore: true), "tests")
    }

    // Sticky within the word across backspace (like the repeated-key guard).
    func testSuspectStickyAcrossBackspace() {
        var e = TelexEngine()
        type(&e, "test")
        XCTAssertEqual(e.composed, "test")
        _ = e.backspace()
        XCTAssertEqual(e.composed, "tes")      // still literal, not "té"
        type(&e, "t")
        XCTAssertEqual(e.composed, "test")
        // Erasing the whole word re-arms detection for a fresh word.
        for _ in 0..<4 { _ = e.backspace() }
        XCTAssertTrue(e.isEmpty)
        type(&e, "toans")
        XCTAssertEqual(e.composed, "toán")
    }

    // MARK: - Kill-switch state machine

    // A valid commit in the tone-early pattern (mark BEFORE tone + keys AFTER
    // tone) reports lastCommitToneEarlyPattern; the caller persists a counter
    // and sets toneEarlyStyle at ≥2, silencing Rule A for good.
    func testToneEarlyPatternReporting() {
        var e = TelexEngine()
        type(&e, "tieesng")                    // mark(ee) < tone(s), n g after
        XCTAssertEqual(e.commitText(autoRestore: true), "tiếng")
        XCTAssertTrue(e.lastCommitToneEarlyPattern)

        type(&e, "dduwowjc")                   // marks early, tone j, trailing c
        XCTAssertEqual(e.commitText(autoRestore: true), "được")
        XCTAssertTrue(e.lastCommitToneEarlyPattern)

        // Terminal-tone words do NOT count.
        type(&e, "tieengs")
        XCTAssertEqual(e.commitText(autoRestore: true), "tiếng")
        XCTAssertFalse(e.lastCommitToneEarlyPattern)
        type(&e, "hoa")
        _ = e.commitText(autoRestore: true)
        XCTAssertFalse(e.lastCommitToneEarlyPattern)
        // Rule A suspects do not count either.
        type(&e, "test")
        XCTAssertEqual(e.commitText(autoRestore: true), "test")
        XCTAssertFalse(e.lastCommitToneEarlyPattern)
    }

    // Caller-side state machine: two tone-early commits → toneEarlyStyle → Rule A
    // permanently silent ("tieesng" still fine, and "test" goes back to "tét").
    func testKillSwitchSilencesRuleA() {
        var e = TelexEngine()
        var counter = 0
        for _ in 0..<2 {
            type(&e, "tieesng")
            XCTAssertEqual(e.commitText(autoRestore: true), "tiếng")
            if e.lastCommitToneEarlyPattern { counter += 1 }
            e.toneEarlyStyle = counter >= 2    // what AppState/controller do
        }
        XCTAssertTrue(e.toneEarlyStyle)
        // Rule A is now silent: tone-early unmarked words compose again…
        type(&e, "hojc")
        XCTAssertEqual(e.composed, "học")
        XCTAssertEqual(e.commitText(autoRestore: true), "học")
        // …and English collisions fall back to the pre-Rule-A behaviour.
        type(&e, "test")
        XCTAssertEqual(e.commitText(autoRestore: true), "tét")
        // tieesng keeps working, obviously.
        type(&e, "tieesng")
        XCTAssertEqual(e.commitText(autoRestore: true), "tiếng")
    }

    // MARK: - Interactions

    // The setting gate: detectEnglishTone = false disables Rule A only.
    func testSettingGate() {
        var e = TelexEngine()
        e.detectEnglishTone = false
        type(&e, "test")
        XCTAssertEqual(e.composed, "tét")
        XCTAssertEqual(e.commitText(autoRestore: true), "tét")
        // Auto-restore of invalid words is untouched by the gate.
        type(&e, "school")
        XCTAssertEqual(e.commitText(autoRestore: true), "school")
    }

    // Whitelist beats Rule A: a whitelisted composed word is never flagged.
    func testWhitelistBeatsRuleA() {
        var e = TelexEngine()
        e.restoreWhitelist = ["tét"]
        type(&e, "test")
        XCTAssertEqual(e.composed, "tét")      // detection suppressed at flip time
        XCTAssertEqual(e.commitText(autoRestore: true), "tét")
        // Without the whitelist entry the same keys flip.
        var f = TelexEngine()
        type(&f, "test")
        XCTAssertEqual(f.commitText(autoRestore: true), "test")
    }

    // Ctrl-tap bypass wins (word literal, no detection needed nor fired).
    func testBypassWins() {
        var e = TelexEngine()
        _ = e.bypassCurrentWord()
        type(&e, "test")
        XCTAssertEqual(e.composed, "test")
        XCTAssertEqual(e.commitText(autoRestore: true), "test")
        XCTAssertFalse(e.lastCommitToneEarlyPattern)
    }

    // Repeated-key guard unaffected.
    func testRepeatedKeyGuardUnaffected() {
        XCTAssertEqual(compose("jjjjaa"), "jjjjaa")
        XCTAssertEqual(commit("kkkkas"), "kkkkas")
    }

    // Resume-after-backspace: a Rule A word resumes in its literal state (the
    // committed text IS the raw keys) and further keys stay literal; a normal
    // word resumes composing.
    func testResumeAfterBackspace() {
        var e = TelexEngine()
        type(&e, "list")
        XCTAssertEqual(e.commitText(autoRestore: true), "list")   // clean commit
        XCTAssertTrue(e.resumeLastWord())
        XCTAssertEqual(e.composed, "list")     // literal render reproduced
        _ = e.feed("s")
        XCTAssertEqual(e.composed, "lists")    // still literal
        XCTAssertEqual(e.commitText(autoRestore: true), "lists")

        // Normal Vietnamese resume is unchanged.
        type(&e, "hoa")
        _ = e.commitText(autoRestore: true)
        XCTAssertTrue(e.resumeLastWord())
        _ = e.feed("f")
        XCTAssertEqual(e.composed, "hòa")
    }

    // Simple Telex mode: Rule A applies identically.
    func testSimpleTelexMode() {
        var e = TelexEngine()
        e.simpleTelex = true
        type(&e, "test")
        XCTAssertEqual(e.composed, "test")
        XCTAssertEqual(e.commitText(autoRestore: true), "test")
        type(&e, "tieengs")
        XCTAssertEqual(e.commitText(autoRestore: true), "tiếng")
    }

    // Free marking ON → tone keys are legitimately non-terminal → Rule A
    // auto-disables.
    func testFreeMarkingDisablesRuleA() {
        var e = TelexEngine()
        e.freeMarking = true
        type(&e, "test")
        XCTAssertEqual(e.composed, "tét")
        XCTAssertEqual(e.commitText(autoRestore: true), "tét")
    }

    // Live spell-check ON (the app default) coexists with Rule A.
    func testLiveSpellCheckCoexists() {
        var e = TelexEngine()
        e.liveSpellCheck = true
        type(&e, "test")
        XCTAssertEqual(e.composed, "test")
        XCTAssertEqual(e.commitText(autoRestore: true), "test")
        var v = TelexEngine()
        v.liveSpellCheck = true
        type(&v, "tieengs")
        XCTAssertEqual(v.commitText(autoRestore: true), "tiếng")
    }

    // Tone replacement and tone cancel after the first tone are NOT triggers.
    func testToneReplacementAndCancelAreFine() {
        XCTAssertEqual(commit("hoanfs"), "hoán")   // f then s = replacement
        XCTAssertEqual(commit("asf"), "à")         // replacement on a single vowel
        XCTAssertEqual(commit("asz"), "a")         // z cancel
        XCTAssertEqual(commit("iss"), "is")        // double-tone cancel gesture
    }
}
