import XCTest
@testable import VietTelex

// App-side coverage for the gonhanh-learnings batch: remote-desktop passthrough
// routing (item 3) and tap-lifecycle safety without Accessibility (item 2).
final class GonhanhHardeningTests: XCTestCase {

    override func tearDown() {
        Accessibility.testTrustOverride = nil
        super.tearDown()
    }

    func testRemoteDesktopPassthroughRouting() {
        for id in ["com.carriez.rustdesk", "com.philandro.anydesk", "com.apple.ScreenContinuity"] {
            XCTAssertEqual(AppState.shared.autoResolvedMode(id), .passthrough, id)
            XCTAssertTrue(AppState.builtInPassthroughApps.contains(id), "\(id) missing from plist")
        }
    }

    func testBundledPlistCarriesTheNewRules() {
        // the SHIPPED resource (not just the repo file) must contain the ids
        guard let url = Bundle(for: TelexInputController.self)
                .url(forResource: "typing-modes", withExtension: "plist"),
              let data = try? Data(contentsOf: url),
              let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String]
        else { return XCTFail("bundled typing-modes.plist unreadable") }
        XCTAssertEqual(dict["com.carriez.rustdesk"], "passthrough")
        XCTAssertEqual(dict["com.philandro.anydesk"], "passthrough")
        XCTAssertEqual(dict["com.apple.ScreenContinuity"], "passthrough")
    }

    // Watchdog/lifecycle safety: with Accessibility revoked, ensureRunning must
    // be a no-op that never creates a tap (the watchdog calls it every 3s now —
    // it has to be safe to call from any state).
    func testEnsureRunningIsSafeWithoutTrust() {
        Accessibility.testTrustOverride = false
        let controller = TerminalTapController.shared
        controller.ensureRunning()
        controller.ensureRunning()          // idempotent
        XCTAssertFalse(controller.isRunning)
    }
}
