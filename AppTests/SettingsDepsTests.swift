import XCTest
@testable import VietTelex

/// SETTINGS-CLEANUP-SPEC §0.4 + bảng §6 (06/11/2026): mục con cùng nhóm ngay dưới cha ⇒ ẨN khi cha
/// làm nó vô tác dụng. Chỉ hiển thị — không đổi key/giá trị.
final class SettingsDepsTests: XCTestCase {

    func testVniHidesTelexOnlyStyleRows() {
        XCTAssertEqual(SettingsDeps.styleRows(vniMode: false), SettingsDeps.StyleRow.allCases)
        XCTAssertEqual(SettingsDeps.styleRows(vniMode: true),
                       [.modern, .teencode, .autoCircumflex, .bracket, .reEdit, .layout])
    }

    /// Teencode và Phím ngoặc chạy cả ở VNI (trước đây làm mờ nhầm "Chỉ áp dụng cho Telex").
    func testTeencodeAndBracketAlwaysShown() {
        for v in [false, true] {
            let rows = SettingsDeps.styleRows(vniMode: v)
            XCTAssertTrue(rows.contains(.teencode))
            XCTAssertTrue(rows.contains(.bracket))
            XCTAssertTrue(rows.contains(.autoCircumflex))
        }
    }

    func testMixedAdvancedRows() {
        XCTAssertEqual(SettingsDeps.mixedAdvancedRows(autoRestore: true, contextualEnglish: true),
                       [.autoRestore, .collision, .context, .retro, .frequency])
        XCTAssertEqual(SettingsDeps.mixedAdvancedRows(autoRestore: false, contextualEnglish: true),
                       [.autoRestore, .context, .retro])
        XCTAssertEqual(SettingsDeps.mixedAdvancedRows(autoRestore: true, contextualEnglish: false),
                       [.autoRestore, .collision, .context])
        XCTAssertEqual(SettingsDeps.mixedAdvancedRows(autoRestore: false, contextualEnglish: false),
                       [.autoRestore, .context])
    }

    /// Cha luôn hiện (để bật lại được tại chỗ).
    func testParentsAlwaysShown() {
        for a in [false, true] { for c in [false, true] {
            let rows = SettingsDeps.mixedAdvancedRows(autoRestore: a, contextualEnglish: c)
            XCTAssertTrue(rows.contains(.autoRestore) && rows.contains(.context))
        } }
    }

    /// Ẩn không đụng giá trị: tắt cha rồi bật lại, công tắc con giữ nguyên.
    func testHidingKeepsValues() {
        let s = AppState.shared
        let saved = OnboardingLogic.mixedKeys.map { ($0, s.mixedSetting($0)!) }
        let savedVni = s.vniMode, savedSimple = s.simpleTelex
        defer {
            for (k, v) in saved { s.setMixedSetting(k, v) }
            s.vniMode = savedVni
            s.simpleTelex = savedSimple
        }
        let model = SettingsModel(selected: .typing)
        model.retroactiveEnglish = true
        model.contextualEnglish = false
        XCTAssertFalse(SettingsDeps.mixedAdvancedRows(autoRestore: model.autoRestore,
                                                      contextualEnglish: model.contextualEnglish).contains(.retro))
        XCTAssertTrue(model.retroactiveEnglish)
        model.contextualEnglish = true
        XCTAssertTrue(model.retroactiveEnglish)
        model.simpleTelex = false
        model.vniMode = true
        model.vniMode = false
        XCTAssertFalse(model.simpleTelex)
    }
}
