import XCTest
import CoreGraphics
@testable import VietTelex

// Regression guard for the synthetic-key recognizers. The bug this locks out:
// Chromium/Electron apps (Slack, Lark, Discord, VS Code…) deliver REAL keydowns to
// the input method stamped with `eventSourceUnixProcessID == getpid()`. When the
// IMKit path recognized its own output by that pid, it dropped every real key in
// those apps → Vietnamese was untypable (raw "vieejt", no diacritics). The IMKit
// path must recognize our output by the private source's MAGIC userData ONLY, never
// the pid. The tap's cascade guard keeps the pid check (needed for the hang fix).
final class SyntheticRecognizerTests: XCTestCase {

    private func keyEvent() -> CGEvent {
        // A bare keydown; we stamp the source fields ourselves to model each scenario.
        CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true)!
    }

    /// IMKit recognizer (isSyntheticMagic) keys off the magic userData, not the pid.
    func testIMKitRecognizerIsMagicOnly() {
        let e = keyEvent()

        // Real key with our magic ABSENT → must NOT be seen as synthetic, even if it
        // happens to carry our pid (the exact Slack/Lark condition).
        e.setIntegerValueField(.eventSourceUserData, value: 0)
        e.setIntegerValueField(.eventSourceUnixProcessID, value: Int64(getpid()))
        XCTAssertFalse(SyntheticKeyboard.isSyntheticMagic(e),
                       "IMKit recognizer must be magic-only — a real key stamped with our pid is NOT ours")

        // Our own output carries the magic → recognized. Model it the way production
        // stamps it: on the SOURCE's userData, not the per-event field — setting
        // .eventSourceUserData directly on an event does not stick (this test
        // originally did that and failed; the field is backed by the event's source,
        // exactly why SyntheticKeyboard stamps its private CGEventSource).
        let src = CGEventSource(stateID: .privateState)!
        src.userData = SyntheticKeyboard.magic
        let ours = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: true)!
        XCTAssertTrue(SyntheticKeyboard.isSyntheticMagic(ours),
                      "an event created from our magic-stamped source is ours")
    }

    /// The tap's cascade guard (isSynthetic) MUST still match our posting pid — that
    /// is the load-bearing fix for the system-wide keyboard-freeze hang.
    func testTapGuardStillMatchesPid() {
        let e = keyEvent()
        e.setIntegerValueField(.eventSourceUserData, value: 0)          // no magic
        e.setIntegerValueField(.eventSourceUnixProcessID, value: Int64(getpid()))
        XCTAssertTrue(SyntheticKeyboard.isSynthetic(e),
                      "tap cascade guard must still recognize our pid even without magic (hang guard)")
    }

    /// A foreign event (neither our magic nor our pid) is never ours, on either path.
    func testForeignEventNeverSynthetic() {
        let e = keyEvent()
        e.setIntegerValueField(.eventSourceUserData, value: 0)
        e.setIntegerValueField(.eventSourceUnixProcessID, value: Int64(getpid()) + 1)
        XCTAssertFalse(SyntheticKeyboard.isSyntheticMagic(e))
        XCTAssertFalse(SyntheticKeyboard.isSynthetic(e))
    }
}
