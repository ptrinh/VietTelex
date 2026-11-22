import XCTest
@testable import VietTelex

// Banner "đang có công cụ gõ tiếng Việt khác chạy" (tab Chung). Hàm thuần: nhận danh sách app
// đang chạy, trả tên cần cảnh báo.
final class TypingConflictsTests: XCTestCase {

    func testOrdinaryAppsAndOurselvesAreNotConflicts() {
        let running: [(bundleID: String?, name: String?)] = [
            ("com.apple.Safari", "Safari"), ("com.viettelex.inputmethod.telex", "VietTelex"),
            (nil, "helper"), ("com.apple.inputmethod.VietnameseIM", "Vietnamese"),
        ]
        XCTAssertEqual(TypingConflicts.names(running: running), [])
    }

    func testEveryKnownToolIsReportedOnceWhateverTheCase() {
        for id in TypingConflicts.knownBundleIDs {
            XCTAssertEqual(id, id.lowercased(), "bảng phải là chữ thường: \(id)")
            let running: [(bundleID: String?, name: String?)] = [
                ("com.apple.finder", "Finder"), (id.uppercased(), "Tool"), (id, "Tool helper"),
            ]
            XCTAssertEqual(TypingConflicts.names(running: running), ["Tool"], id)
        }
    }

    func testMissingNameFallsBackToBundleID() {
        let id = TypingConflicts.knownBundleIDs.sorted()[0]
        XCTAssertEqual(TypingConflicts.names(running: [(id, nil)]), [id])
        XCTAssertEqual(TypingConflicts.names(running: [(id, "  ")]), [id])
    }
}
