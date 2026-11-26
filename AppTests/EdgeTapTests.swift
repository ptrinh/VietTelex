import XCTest
@testable import VietTelex

// EDGE-TAP (06/08/2026): từ neo ở offset 0 trong app PIN TAY In-place đi kênh
// synthetic ⌫-retype thay vì insertText. Field report: Discord pin In-place gõ
// ổn TRỪ chữ đầu message — "cos" → "coó". Slate/Lexical không map được
// replacementRange bắt đầu ở biên block nên APPEND thay vì replace; trick
// "space ở đầu" của maintainer xác nhận cơ chế (đẩy từ khỏi offset 0 là hết).
// Kênh synthetic là kênh duy nhất editor tôn trọng ở vị trí đó.
final class EdgeTapTests: XCTestCase {

    func testOnlyManualInPlacePinAtOffsetZeroWhileTrusted() {
        XCTAssertTrue(TelexInputController.edgeTapEligible(manualInPlace: true, caret: 0, trusted: true))
    }

    /// Ô Slate TRỐNG (Discord) báo caret=1 — phantom placeholder của block rỗng
    /// (đo 06/08: ô trống 2 lần caret=1, nhưng từ sau "abc " neo ở 4 chứ không
    /// phải 5 ⇒ số 1 là giả, text thật nằm từ 0). Predicate phải nhận caret=1,
    /// nếu không edge-tap câm ngay trên chính app nó được sinh ra để cứu.
    func testEmptySlateFieldPhantomOffsetOneIsEdge() {
        XCTAssertTrue(TelexInputController.edgeTapEligible(manualInPlace: true, caret: 1, trusted: true))
    }

    func testMidFieldWordStaysInPlace() {
        // Từ thứ hai trở đi (caret > 0) giữ nguyên in-place — đúng scope: user
        // xác nhận giữa dòng ổn, và synthetic hóa toàn bộ sẽ thành tap mode luôn.
        XCTAssertFalse(TelexInputController.edgeTapEligible(manualInPlace: true, caret: 3, trusted: true))
    }

    func testUnpinnedAppsNeverEdgeTap() {
        // App in-place built-in (TextEdit, Notes) honor offset 0 — không cần và
        // không được synthetic hóa chữ đầu (flicker vô ích).
        XCTAssertFalse(TelexInputController.edgeTapEligible(manualInPlace: false, caret: 0, trusted: true))
    }

    func testUntrustedFallsBackToPlainInPlace() {
        // Không có Trợ năng thì không post synthetic được — từ đầu chịu bug cũ
        // thay vì mất chữ (SyntheticKeyboard.apply sẽ drop cả edit nếu cứ gọi).
        XCTAssertFalse(TelexInputController.edgeTapEligible(manualInPlace: true, caret: 0, trusted: false))
    }

    /// Flavor theo composer (07/08): edge CHỈ cho Slate-class (Discord append ở
    /// offset 0). Quill (Slack) honor offset-0 insertText — đo bằng edgeTapKill —
    /// và Return của nó không được đi đường nuốt+re-post (composer tự chèn
    /// newline cho phím bị nuốt → double newline). Ai muốn thêm app vào set này
    /// phải có bằng chứng append như Discord, không suy từ "cũng là Electron".
    func testOnlySlateClassAppsAreEdgeEligible() {
        XCTAssertTrue(AppState.offset0AppendApps.contains("com.hnc.Discord"))
        XCTAssertFalse(AppState.offset0AppendApps.contains("com.tinyspeck.slackmacgap"))
        XCTAssertFalse(AppState.offset0AppendApps.contains("com.anthropic.claudefordesktop"))
    }

    func testNoCaretReadMeansNoEdgeTap() {
        // App không báo caret (một số Electron): không chứng minh được offset 0
        // → giữ đường per-op selectedRange như cũ.
        XCTAssertFalse(TelexInputController.edgeTapEligible(manualInPlace: true, caret: nil, trusted: true))
    }

    // #181 — Google Sheets trong Safari: chữ đầu từ đi như phím thật để ô vào chế độ sửa.
    func testSheetsGridFirstLetterPassesNativelyInWebKitOnly() {
        func f(wordStart: Bool = true, marked: Bool = false, edge: Bool = false, webKit: Bool = true,
               sheets: Bool = true, pinned: Bool = false, dead: Bool = false, capped: Bool = false) -> Bool {
            TelexInputController.gridFirstLetterNative(
                wordStart: wordStart, marked: marked, edge: edge, webKitBrowser: webKit, sheetsGrid: sheets,
                layoutPinned: pinned, afterDeadKey: dead, autoCapped: capped)
        }
        XCTAssertTrue(f())
        XCTAssertFalse(f(wordStart: false), "chỉ chữ đầu từ")
        XCTAssertFalse(f(webKit: false), "Chromium đi kênh tap + U+202F như cũ")
        XCTAssertFalse(f(sheets: false), "trang khác trong Safari không đổi")
        XCTAssertFalse(f(marked: true))
        XCTAssertFalse(f(edge: true))
        XCTAssertFalse(f(pinned: true), "layout ghim: phím thật ra chữ khác")
        XCTAssertFalse(f(dead: true))
        XCTAssertFalse(f(capped: true), "chữ tự viết hoa khác phím thật")
    }
}
