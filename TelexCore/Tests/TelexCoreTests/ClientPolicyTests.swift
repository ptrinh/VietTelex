import XCTest
@testable import TelexCore

final class ClientPolicyTests: XCTestCase {

    func testRemoteDesktopAppsAreForcePassthrough() {
        let rdpApps = [
            "com.microsoft.rdc.macos",       // Microsoft Remote Desktop / Windows App
            "com.microsoft.rdc.osx.beta",
            "com.parallels.desktop.console",
            "com.vmware.fusion",
            "com.utmapp.UTM",
            "com.apple.ScreenSharing",
            "com.citrix.receiver.icaviewer.mac",
            "com.teamviewer.TeamViewer",
            "com.realvnc.vncviewer",
            "com.nulana.remotixmac",
        ]
        for id in rdpApps {
            XCTAssertTrue(ClientPolicy.isRemoteDesktop(id), "should be RDP: \(id)")
        }
    }

    func testOrdinaryAppsAreNotForcePassthrough() {
        let normal = [
            "com.apple.TextEdit", "com.google.Chrome", "com.microsoft.Word",
            "com.apple.Terminal", "com.microsoft.VSCode", "com.tinyspeck.slackmacgap",
            "com.hnc.Discord", nil,
        ]
        for id in normal {
            XCTAssertFalse(ClientPolicy.isRemoteDesktop(id), "should NOT be RDP: \(id ?? "nil")")
        }
    }

    func testUserAlwaysOffOverride() {
        let userOff: Set<String> = ["com.example.custom"]
        // Built-in RDP still forced regardless of user set.
        XCTAssertTrue(ClientPolicy.shouldForcePassthrough("com.microsoft.rdc.macos", userAlwaysOff: []))
        // User-added app is forced.
        XCTAssertTrue(ClientPolicy.shouldForcePassthrough("com.example.custom", userAlwaysOff: userOff))
        // Unlisted app is not.
        XCTAssertFalse(ClientPolicy.shouldForcePassthrough("com.apple.TextEdit", userAlwaysOff: userOff))
        // nil client never forced.
        XCTAssertFalse(ClientPolicy.shouldForcePassthrough(nil, userAlwaysOff: userOff))
    }
}
