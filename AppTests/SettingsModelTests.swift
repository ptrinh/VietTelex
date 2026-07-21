import XCTest
@testable import VietTelex

// SettingsModel's mode-table logic: rows, labels, filter, sort, add/delete, and
// — per an explicit field requirement — IMPORT IDEMPOTENCY: applying the same
// plist any number of times must converge to one identical state, never crash,
// never duplicate. Same snapshot/restore discipline as AppStateRoutingTests.
final class SettingsModelTests: XCTestCase {

    private let s = AppState.shared
    private var savedManual: [String: String] = [:]

    override func setUp() {
        super.setUp()
        savedManual = s.manualModes
        Accessibility.testTrustOverride = true
    }

    override func tearDown() {
        Accessibility.testTrustOverride = nil
        let current = s.manualModes
        for id in current.keys where savedManual[id] == nil { s.setManualMode(.auto, for: id) }
        for (id, raw) in savedManual {
            if let m = AppState.AppMode(rawValue: raw) { s.setManualMode(m, for: id) }
        }
        super.tearDown()
    }

    func testImportIsIdempotentAndValidates() {
        let model = SettingsModel(selected: .modeTable)
        let dict = [
            "test.viettelex.import.a": "tap",
            "test.viettelex.import.b": "inPlace",
            "test.viettelex.import.bad": "notAMode",   // must be skipped, not crash
            "": "tap",                                  // empty id skipped
        ]
        let first = model.importManualModes(dict)
        XCTAssertEqual(first, 2, "two valid entries applied, junk skipped")
        let stateAfterFirst = s.manualModes
        // Same file, five more times: identical state every time.
        for _ in 0..<5 {
            XCTAssertEqual(model.importManualModes(dict), 2)
            XCTAssertEqual(s.manualModes, stateAfterFirst)
        }
        s.setManualMode(.auto, for: "test.viettelex.import.a")
        s.setManualMode(.auto, for: "test.viettelex.import.b")
    }

    func testImportingTheShippedRulesFileIsSafe() {
        // The typing-modes.plist attached to releases is importable as manual pins
        // — twice, without drift (the user-facing "Nhập từ plist…" path).
        guard let url = Bundle(for: TelexInputController.self)
                .url(forResource: "typing-modes", withExtension: "plist"),
              let data = try? Data(contentsOf: url),
              let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String]
        else { return XCTFail("bundled typing-modes.plist unreadable") }
        let model = SettingsModel(selected: .modeTable)
        let n1 = model.importManualModes(dict)
        let snapshot = s.manualModes
        let n2 = model.importManualModes(dict)
        XCTAssertEqual(n1, n2)
        XCTAssertEqual(s.manualModes, snapshot)
        for id in dict.keys { s.setManualMode(.auto, for: id) }   // clean up pins
    }

    func testRowsFilterSortAndLabels() {
        let model = SettingsModel(selected: .modeTable)
        model.reloadModeTable()
        // Terminal row exists with a truthful detected label under both trusts.
        Accessibility.testTrustOverride = true
        model.reloadModeTable()
        guard let term = model.visibleModeRows.first(where: { $0.id == "com.apple.Terminal" })
        else { return XCTFail("Terminal row missing") }
        XCTAssertFalse(term.missingPermission)
        Accessibility.testTrustOverride = false
        model.reloadModeTable()
        let term2 = model.visibleModeRows.first(where: { $0.id == "com.apple.Terminal" })!
        XCTAssertTrue(term2.missingPermission)

        // Filter matches name, id, and labels; is case-insensitive.
        model.modeFilter = "com.apple.terminal"
        XCTAssertTrue(model.visibleModeRows.contains { $0.id == "com.apple.Terminal" })
        model.modeFilter = "zzz-no-such-app-zzz"
        XCTAssertTrue(model.visibleModeRows.isEmpty)
        model.modeFilter = ""

        // Header sort: descending by name reverses the default.
        let asc = model.visibleModeRows.map(\.name)
        model.modeSortOrder = [KeyPathComparator(\AppModeRow.name, order: .reverse)]
        XCTAssertEqual(model.visibleModeRows.map(\.name), asc.reversed())
        model.modeSortOrder = [KeyPathComparator(\AppModeRow.name)]
    }

    func testAddAndDeleteRow() {
        let model = SettingsModel(selected: .modeTable)
        model.newModeAppID = "test.viettelex.added"
        model.addApp()
        XCTAssertTrue(model.visibleModeRows.contains { $0.id == "test.viettelex.added" })
        XCTAssertEqual(model.newModeAppID, "")
        model.deleteRow("test.viettelex.added")
        XCTAssertFalse(model.visibleModeRows.contains { $0.id == "test.viettelex.added" })
        // Deleting a built-in row forgets user data but the row itself stays.
        model.deleteRow("com.apple.Terminal")
        XCTAssertTrue(model.visibleModeRows.contains { $0.id == "com.apple.Terminal" })
    }

    func testAppNameResolution() {
        XCTAssertEqual(SettingsModel.appName(for: SettingsModel.spotlightRowID), "Spotlight")
        // Unknown bundle id falls back to the id itself.
        XCTAssertEqual(SettingsModel.appName(for: "test.viettelex.ghost"), "test.viettelex.ghost")
    }
}
