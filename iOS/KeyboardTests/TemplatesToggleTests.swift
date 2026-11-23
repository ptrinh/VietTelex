// TemplatesToggleTests — công tắc "Mẫu câu" (App Group "templatesEnabled", mặc định BẬT;
// Tính Năng → Gõ tắt). Tắt (Phil 30/09/2026): app ẩn tab Mẫu Câu; bàn phím ẩn nút ☰ trên
// thanh gợi ý, không mở được plane mẫu câu và KHÔNG đọc danh sách mẫu (0 chi phí). Nút ⌄
// bên phải thanh gợi ý là thu gọn/mở thanh — tính năng riêng, giữ nguyên.
import XCTest
import UIKit

final class TemplatesToggleTests: XCTestCase {
    private let suite = "vt-templates-toggle-tests"

    @MainActor private func withKeyboard(_ pairs: [String: Any],
                                         _ body: (KeyboardView) throws -> Void) rethrows {
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        for (k, v) in pairs { d.set(v, forKey: k) }
        let saved = UserDefaultsProvider.shared
        UserDefaultsProvider.shared = d
        defer { UserDefaultsProvider.shared = saved; d.removePersistentDomain(forName: suite) }
        let kb = KeyboardView(needsGlobe: false, inputController: nil) { _ in }
        let host = UIView(frame: CGRect(x: 0, y: 0, width: 390, height: 320))
        host.addSubview(kb)
        kb.frame = host.bounds
        kb.applyAppearance(.light, style: .light)
        kb.setSuggestionsEnabled(true)
        kb.setNeedsLayout(); kb.layoutIfNeeded()
        try body(kb)
        withExtendedLifetime(host) {}
    }

    @MainActor func testDefaultOnShowsBurgerAndLoadsLazily() {
        withKeyboard([:]) { kb in
            XCTAssertTrue(kb.debugBurgerVisible, "mặc định BẬT: có nút ☰")
            XCTAssertFalse(kb.debugTemplatesLoaded, "chưa mở ⇒ chưa đọc danh sách mẫu")
            kb.debugTapBurger()
            XCTAssertTrue(kb.debugInTemplates)
            XCTAssertTrue(kb.debugTemplatesLoaded)
        }
    }

    @MainActor func testOffHidesBurgerAndCostsNothing() {
        withKeyboard(["templatesEnabled": false,
                      "userTemplates": [["label": "👋", "text": "Chào"]]]) { kb in
            // iPhone: ô ☰ thành nút MỘT TAY (tester 1.2.8) — không còn là ☰ mẫu câu.
            XCTAssertEqual(kb.debugLeftZone, UIDevice.current.userInterfaceIdiom == .pad ? .none : .oneHand)
            XCTAssertEqual(kb.debugBurgerVisible, UIDevice.current.userInterfaceIdiom != .pad)
            kb.debugTapBurger()
            XCTAssertFalse(kb.debugInTemplates, "tắt: không mở plane mẫu câu")
            XCTAssertFalse(kb.debugTemplatesLoaded, "tắt: không đọc danh sách mẫu")
            // Không còn nút ⌄ ở mép phải (10/2026): thanh gợi ý (hoặc 📋) chạm mép phải.
            let s = kb.debugStripLayout()
            XCTAssertEqual(s.clip?.maxX ?? s.bar.maxX, kb.bounds.width, accuracy: 0.5)
        }
    }

    func testBackupCarriesToggleWithDefaultOn() {
        let spec = BackupSettings.all.first { $0.key == "templatesEnabled" }
        XCTAssertEqual(spec?.kind, .bool(true))
    }

    /// #175: "Hiện mẫu câu theo dòng" — một cột, mỗi dòng có nhãn kèm nội dung; lưới giữ nguyên chỉ nhãn.
    func testListModeShowsLabelWithText() {
        XCTAssertEqual(KeyboardView.snippetCols(width: 393, list: true), 1)
        XCTAssertEqual(KeyboardView.snippetCols(width: 393, list: false), KeyboardView.snippetCols(width: 393))
        XCTAssertEqual(KeyboardView.templateCellText(label: "👋", text: "Xin chào", list: false), "👋")
        XCTAssertEqual(KeyboardView.templateCellText(label: "👋", text: "Xin chào", list: true), "👋  Xin chào")
        XCTAssertEqual(KeyboardView.templateCellText(label: "", text: "Xin chào", list: true), "Xin chào")
        XCTAssertEqual(KeyboardView.templateCellText(label: "Xin chào", text: "Xin chào", list: true), "Xin chào")
        XCTAssertEqual(KeyboardView.templateCellText(label: "📍", text: "Số 1\nPhố A", list: true), "📍  Số 1 Phố A")
        XCTAssertEqual(BackupSettings.all.first { $0.key == "templatesAsList" }?.kind, .bool(false))
    }
}
