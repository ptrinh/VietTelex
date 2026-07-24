import XCTest
@testable import VietTelex

// The per-app routing MATRIX — usesMarkedText / usesTapMode / usesSelectionReplace /
// usesEmptyReset / autoResolvedMode / needsProbe across (trusted × manual × learned ×
// built-in). This is pure decision logic where a wrong answer silently types wrong
// (a manual tap pick without Accessibility once fell through to in-place and lost
// diacritics), so it gets the same golden treatment as the engine.
//
// Tests run against the real AppState singleton + UserDefaults suite: setUp
// snapshots every piece of state they touch and tearDown restores it, so a test
// run never perturbs the developer's own configuration. Trust is forced through
// Accessibility.testTrustOverride (DEBUG-only seam).
final class AppStateRoutingTests: XCTestCase {

    private let s = AppState.shared
    private var savedManual: [String: String] = [:]
    private var savedFallback: [String] = []
    private var savedInPlace: [String] = []

    // Fictional bundle ids so built-in rules can never collide.
    private let unknownApp = "test.viettelex.unknown"
    private let learnedBadApp = "test.viettelex.learnedbad"
    private let learnedGoodApp = "test.viettelex.learnedgood"
    private let pinnedApp = "test.viettelex.pinned"

    override func setUp() {
        super.setUp()
        savedManual = s.manualModes
        savedFallback = s.learnedFallbackApps
        savedInPlace = s.learnedInPlaceApps
        Accessibility.testTrustOverride = true
    }

    override func tearDown() {
        Accessibility.testTrustOverride = nil
        // Restore learned + manual state exactly.
        s.resetLearnedApps()
        for id in savedFallback { s.markUsesMarkedText(id) }
        for id in savedInPlace { s.markInPlaceGood(id) }
        let current = s.manualModes
        for id in current.keys where savedManual[id] == nil { s.setManualMode(.auto, for: id) }
        for (id, raw) in savedManual {
            if let m = AppState.AppMode(rawValue: raw) { s.setManualMode(m, for: id) }
        }
        super.tearDown()
    }

    // MARK: Built-in rules come from typing-modes.yml

    func testBuiltInRulesLoadedFromPlist() {
        // Core promise entries must be present (the loader's own fallback also
        // guarantees the terminals, so this holds even if the resource breaks).
        XCTAssertTrue(AppState.builtInFallbackApps.contains("com.apple.Terminal"))
        XCTAssertTrue(AppState.builtInFallbackApps.contains("com.googlecode.iterm2"))
        // Representative entries of every other mode class.
        XCTAssertTrue(AppState.builtInInPlaceApps.contains("com.apple.Notes"))
        XCTAssertTrue(AppState.builtInSpecialApps.contains("com.apple.Safari"))       // axDetect
        XCTAssertTrue(AppState.builtInSpecialApps.contains("com.microsoft.Excel"))    // emptyReset
        XCTAssertTrue(AppState.builtInPassthroughApps.contains("com.apple.ScreenSharing"))
        XCTAssertTrue(AppState.terminalApps.isSubset(of: AppState.builtInFallbackApps))
    }

    // MARK: Auto routing × trust

    func testAutoRoutingTrusted() {
        Accessibility.testTrustOverride = true
        // Terminals: tap (not marked) when trusted.
        XCTAssertTrue(s.usesTapMode("com.apple.Terminal"))
        XCTAssertTrue(s.usesMarkedText("com.apple.Terminal"))   // marked is the umbrella "no in-place"
        // Browsers: per-field, not tap, not marked.
        XCTAssertTrue(s.usesSelectionReplace("com.apple.Safari"))
        XCTAssertFalse(s.usesTapMode("com.apple.Safari"))
        XCTAssertFalse(s.usesMarkedText("com.apple.Safari"))
        // Excel: empty-reset.
        XCTAssertTrue(s.usesEmptyReset("com.microsoft.Excel"))
        // Verified in-place stays clean.
        XCTAssertFalse(s.usesMarkedText("com.apple.Notes"))
        XCTAssertFalse(s.usesTapMode("com.apple.Notes"))
        // Unknown app: in-place trial (probe) — nothing forces marked.
        XCTAssertFalse(s.usesMarkedText(unknownApp))
        XCTAssertTrue(s.needsProbe(unknownApp))
    }

    func testAutoRoutingUntrusted() {
        Accessibility.testTrustOverride = false
        // Tap family degrades to marked; no tap anywhere.
        XCTAssertTrue(s.usesMarkedText("com.apple.Terminal"))
        XCTAssertFalse(s.usesTapMode("com.apple.Terminal"))
        XCTAssertFalse(s.usesSelectionReplace("com.apple.Safari"))
        XCTAssertFalse(s.usesEmptyReset("com.microsoft.Excel"))
        // BLUNT policy: unknown apps are marked and never probed while untrusted.
        XCTAssertTrue(s.usesMarkedText(unknownApp))
        XCTAssertFalse(s.needsProbe(unknownApp))
        // Known-good in-place is the only exception.
        XCTAssertFalse(s.usesMarkedText("com.apple.Notes"))
    }

    // MARK: Chromium omnibox emit mode (.emptyReset autocomplete-cancel dance)

    // The fix for "google"→"gooogle" in Chrome's omnibox: per-field browsers emit tone
    // edits via .emptyReset (type U+202F to dismiss the INLINE autocomplete suggestion,
    // then delete + retype) instead of .selection (Shift+Left select-overtype, which the
    // suggestion's own selection offsets). Apps pinned to plain .selection (IDE popups,
    // not inline) must keep .selection.
    func testSelectionEmitModeBrowserVsSelectionPin() {
        Accessibility.testTrustOverride = true
        // Built-in per-field browsers → the U+202F dance.
        for browser in ["com.google.Chrome", "com.apple.Safari",
                        "com.microsoft.edgemac", "org.mozilla.firefox"] {
            XCTAssertTrue(s.usesAxDetect(browser), "\(browser) should be per-field (axDetect)")
            XCTAssertEqual(s.selectionEmitMode(browser), .emptyReset,
                           "\(browser) omnibox must emit via .emptyReset")
        }
        // A manual .selection pin (autocomplete popup, not inline) keeps plain Shift+Left.
        s.setManualMode(.selection, for: pinnedApp)
        XCTAssertTrue(s.usesSelectionReplace(pinnedApp))
        XCTAssertFalse(s.usesAxDetect(pinnedApp))
        XCTAssertEqual(s.selectionEmitMode(pinnedApp), .selection,
                       "manual .selection pin must stay .selection")
        // A manual .axDetect pin is treated as a per-field browser → .emptyReset.
        s.setManualMode(.axDetect, for: pinnedApp)
        XCTAssertEqual(s.selectionEmitMode(pinnedApp), .emptyReset,
                       "manual .axDetect pin must emit via .emptyReset")
    }

    // MARK: Learned classification

    func testLearnedRouting() {
        s.markUsesMarkedText(learnedBadApp)
        s.markInPlaceGood(learnedGoodApp)
        Accessibility.testTrustOverride = true
        XCTAssertTrue(s.usesTapMode(learnedBadApp))          // learned bad + trusted → tap
        XCTAssertFalse(s.usesMarkedText(learnedGoodApp))
        XCTAssertFalse(s.needsProbe(learnedBadApp))
        XCTAssertFalse(s.needsProbe(learnedGoodApp))
        XCTAssertEqual(s.autoResolvedMode(learnedBadApp), .tap)
        XCTAssertEqual(s.autoResolvedMode(learnedGoodApp), .inPlace)
        Accessibility.testTrustOverride = false
        XCTAssertTrue(s.usesMarkedText(learnedBadApp))       // degrades to marked
        XCTAssertFalse(s.usesTapMode(learnedBadApp))
        XCTAssertFalse(s.usesMarkedText(learnedGoodApp))     // known-good stays in-place
        // Ground-truth reversal (async AX verdict path).
        s.unmarkInPlaceGood(learnedGoodApp)
        XCTAssertFalse(s.learnedInPlaceApps.contains(learnedGoodApp))
    }

    // MARK: Manual pins win over everything

    func testManualOverrides() {
        Accessibility.testTrustOverride = true
        s.setManualMode(.inPlace, for: "com.apple.Terminal")   // user insists
        XCTAssertFalse(s.usesMarkedText("com.apple.Terminal"))
        XCTAssertFalse(s.usesTapMode("com.apple.Terminal"))
        s.setManualMode(.auto, for: "com.apple.Terminal")      // back to built-in
        XCTAssertTrue(s.usesTapMode("com.apple.Terminal"))

        s.setManualMode(.selection, for: pinnedApp)
        XCTAssertTrue(s.usesSelectionReplace(pinnedApp))
        s.setManualMode(.emptyReset, for: pinnedApp)
        XCTAssertTrue(s.usesEmptyReset(pinnedApp))
        s.setManualMode(.marked, for: pinnedApp)
        XCTAssertTrue(s.usesMarkedText(pinnedApp))
        XCTAssertFalse(s.needsProbe(pinnedApp))               // pinned → never probed
        XCTAssertTrue(s.isModeConfigured(pinnedApp))

        // Tap-family pin WITHOUT Accessibility degrades to marked, never to a
        // silent in-place (the regression this matrix exists to prevent).
        Accessibility.testTrustOverride = false
        s.setManualMode(.tap, for: pinnedApp)
        XCTAssertTrue(s.usesMarkedText(pinnedApp))
        XCTAssertFalse(s.usesTapMode(pinnedApp))
        s.setManualMode(.axDetect, for: pinnedApp)
        XCTAssertTrue(s.usesMarkedText(pinnedApp))
        XCTAssertFalse(s.usesSelectionReplace(pinnedApp))
        s.setManualMode(.auto, for: pinnedApp)
    }

    // MARK: forgetApp = pin + learned gone, built-ins untouched

    func testForgetApp() {
        s.setManualMode(.tap, for: pinnedApp)
        s.markUsesMarkedText(pinnedApp)
        s.forgetApp(pinnedApp)
        XCTAssertNil(s.manualMode(pinnedApp))
        XCTAssertFalse(s.learnedFallbackApps.contains(pinnedApp))
        s.forgetApp("com.apple.Terminal")                     // idempotent on built-ins
        XCTAssertTrue(AppState.builtInFallbackApps.contains("com.apple.Terminal"))
    }

    // MARK: Passthrough + misc surfaces

    func testPassthroughAndMisc() {
        XCTAssertEqual(s.autoResolvedMode("com.apple.ScreenSharing"), .passthrough)
        XCTAssertEqual(s.autoResolvedMode("com.microsoft.rdc.macos"), .passthrough)  // ClientPolicy floor
        XCTAssertNil(s.autoResolvedMode(unknownApp))
        XCTAssertNil(s.autoResolvedMode(nil))
        XCTAssertFalse(s.usesMarkedText(nil))
        XCTAssertFalse(s.usesTapMode(nil))
        XCTAssertFalse(s.needsProbe(nil))
        XCTAssertTrue(s.wantsAccessibility("com.apple.Terminal"))
        XCTAssertTrue(s.wantsAccessibility("com.apple.Safari"))
        XCTAssertFalse(s.wantsAccessibility(unknownApp))
        XCTAssertEqual(AppState.spotlightBundleID, "com.apple.Spotlight")
    }

    // MARK: Shortcuts CRUD (locked cache + persistence round trip)

    func testShortcutsCRUD() {
        let saved = s.shortcuts
        defer { s.setShortcuts(saved) }
        s.upsertShortcut(key: "tvtest", value: "VietTelex test")
        XCTAssertEqual(s.shortcuts["tvtest"], "VietTelex test")
        s.upsertShortcut(key: "", value: "ignored")            // empty key rejected
        XCTAssertNil(s.shortcuts[""])
        s.removeShortcut(key: "tvtest")
        XCTAssertNil(s.shortcuts["tvtest"])
    }
}
