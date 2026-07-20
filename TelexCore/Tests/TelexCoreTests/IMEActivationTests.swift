// IMEActivationTests.swift
// Regression tests for the out-of-order activate/deactivate race that left the
// terminal tap dormant (Vietnamese typing passing through) in iTerm2 until a focus
// cycle. See IMEActivation.swift for the failure mechanism.
import XCTest
@testable import TelexCore

final class IMEActivationTests: XCTestCase {

    /// Baseline: activate, then a genuine switch-away turns it off.
    func testActivateThenGenuineDeactivate() {
        var s = IMEActivation()
        XCTAssertFalse(s.isActive)
        s.activate()
        XCTAssertTrue(s.isActive)
        s.deactivate(stillSelected: false)   // switched to ABC/US
        XCTAssertFalse(s.isActive)
    }

    /// THE BUG. IMK calls the newly focused client's activateServer BEFORE the old
    /// client's deactivateServer. That stale deactivate fires while VietTelex is still
    /// the OS-selected source — it must NOT clobber the active flag, or the tap goes
    /// dormant and typing silently passes through.
    func testOutOfOrderDeactivateDoesNotClobber() {
        var s = IMEActivation()
        s.activate()                         // iTerm2 (new focus) activates
        s.deactivate(stillSelected: true)    // previous client's late deactivate
        XCTAssertTrue(s.isActive,
            "a stale out-of-order deactivate turned the tap off while VietTelex was still selected")
    }

    /// Switching to English inside a terminal (authoritative TIS notification) really
    /// turns it off, so the shell sees plain keys.
    func testSelectionChangedToEnglishTurnsOff() {
        var s = IMEActivation(isActive: true)
        s.selectionChanged(isVietTelex: false)
        XCTAssertFalse(s.isActive)
    }

    /// Per-document input switching can restore VietTelex on focus-return WITHOUT an
    /// activateServer call; the TIS notification must re-activate on its own.
    func testSelectionChangedReactivates() {
        var s = IMEActivation()
        s.selectionChanged(isVietTelex: true)
        XCTAssertTrue(s.isActive)
    }

    /// Full sequence reproducing the report: type in iTerm2 (active) → focus another
    /// VietTelex client → the interleaving lands activate-before-deactivate → back in
    /// iTerm2 typing must still work.
    func testFocusBounceKeepsActive() {
        var s = IMEActivation()
        s.activate()                         // typing in iTerm2
        // focus bounce: new client activates, old client deactivates late
        s.activate()
        s.deactivate(stillSelected: true)
        XCTAssertTrue(s.isActive)
    }

    /// The initializer's explicit state is honored (used when seeding from the live
    /// TIS selection at startup).
    func testInitialStateHonored() {
        XCTAssertFalse(IMEActivation().isActive)
        XCTAssertTrue(IMEActivation(isActive: true).isActive)
    }

    /// activate() / selectionChanged(true) are idempotent — repeated calls don't
    /// flip anything, so duplicate IMK/TIS callbacks are safe.
    func testIdempotentCalls() {
        var s = IMEActivation()
        s.activate(); s.activate()
        XCTAssertTrue(s.isActive)
        s.selectionChanged(isVietTelex: true); s.selectionChanged(isVietTelex: true)
        XCTAssertTrue(s.isActive)
        s.deactivate(stillSelected: false); s.deactivate(stillSelected: false)
        XCTAssertFalse(s.isActive)
    }

    /// A genuine deactivate (not selected) turns it off even right after an activate —
    /// the "stillSelected" guard only protects the OUT-OF-ORDER case, not a real switch.
    func testActivateThenImmediateGenuineDeactivate() {
        var s = IMEActivation()
        s.activate()
        s.deactivate(stillSelected: false)
        XCTAssertFalse(s.isActive)
    }

    /// The authoritative TIS notification overrides a stale active flag in both
    /// directions, regardless of prior activate/deactivate hints.
    func testSelectionChangedIsAuthoritative() {
        var s = IMEActivation()
        s.activate()
        s.selectionChanged(isVietTelex: false)     // TIS says not us -> off
        XCTAssertFalse(s.isActive)
        s.deactivate(stillSelected: true)          // stale hint can't turn it back on
        XCTAssertFalse(s.isActive)
        s.selectionChanged(isVietTelex: true)      // TIS says us -> on
        XCTAssertTrue(s.isActive)
    }

    /// Equatable conformance (used to detect state changes without spurious work).
    func testEquatable() {
        XCTAssertEqual(IMEActivation(isActive: true), IMEActivation(isActive: true))
        XCTAssertNotEqual(IMEActivation(isActive: true), IMEActivation(isActive: false))
    }
}
