// KeyVariantsTests — giữ phím bàn số / ký hiệu ra hàng biến thể như stock iOS (góp ý người
// dùng 30/09/2026: giữ `"` ở bàn 123 stock ra « » „ “ ” "; VietTelex không có gì).
import XCTest
import UIKit

final class KeyVariantsTests: XCTestCase {
    /// Phím có trên bàn 123 / #+= iPhone (KeyboardView.rebuild).
    private let numbersKeys = ["1","2","3","4","5","6","7","8","9","0",
                               "-","/",":",";","(",")","$","&","@","\"", ".",",","?","!","'"]
    private let symbolsKeys = ["[","]","{","}","#","%","^","*","+","=",
                               "_","\\","|","~","<",">","€","¥","₫","•", ".",",","?","!","'"]

    // MARK: bảng

    func testEveryEntryStartsWithItsBaseAndIsOnAPlane() {
        let onPlanes = Set(numbersKeys + symbolsKeys)
        for (key, list) in KeyVariants.table {
            XCTAssertEqual(list.first, key, "ô 0 = ký tự gốc (mặc định được chọn) — \(key)")
            XCTAssertGreaterThanOrEqual(list.count, 2, key)
            XCTAssertEqual(Set(list).count, list.count, "\(key): trùng biến thể")
            XCTAssertTrue(onPlanes.contains(key), "\(key) không có trên bàn số/ký hiệu")
        }
    }

    func testStockOrdering() {
        let t = KeyVariants.table
        XCTAssertEqual(t["\""], ["\"", "”", "“", "„", "»", "«"])
        XCTAssertEqual(t["'"], ["'", "‘", "’", "`"])
        XCTAssertEqual(t["-"], ["-", "–", "—", "•"])
        XCTAssertEqual(t["0"], ["0", "°"])
        XCTAssertEqual(t["."], [".", "…"])
        XCTAssertEqual(t["?"], ["?", "¿"])
        XCTAssertEqual(t["!"], ["!", "¡"])
        XCTAssertEqual(t["/"], ["/", "=", "\\"])
        XCTAssertEqual(t["&"], ["&", "§"])
        XCTAssertEqual(t["%"], ["%", "‰"])
        XCTAssertEqual(t["$"]?.prefix(2), ["$", "₫"], "₫ ngay sau $ cho người dùng Việt")
        XCTAssertEqual(Set(t["$"] ?? []), ["$", "₫", "€", "£", "¥", "₩", "₹", "₽", "¢"])
    }

    func testGating() {
        XCTAssertEqual(KeyVariants.variants(for: "\"", symbolPlane: true), KeyVariants.table["\""])
        XCTAssertEqual(KeyVariants.variants(for: "\"", symbolPlane: false), [], "bàn chữ: không")
        XCTAssertEqual(KeyVariants.variants(for: "e", symbolPlane: false), [], "không đè giữ q…p / dấu tiếng Việt")
        XCTAssertEqual(KeyVariants.variants(for: "0", symbolPlane: true, numericField: true), [], "ô số: không")
        XCTAssertEqual(KeyVariants.variants(for: "@", symbolPlane: true), [], "phím không có biến thể")
    }

    // MARK: KeyboardView — đường action thật

    @MainActor private func makeKeyboard(_ kind: KeyboardView.InputKind = .normal,
                                         log: @escaping (String) -> Void) -> (KeyboardView, UIView) {
        let kb = KeyboardView(needsGlobe: false, inputController: nil) { k in
            switch k {
            case .letter(let c): log("L\(c.lowercased())")
            case .text(let s): log("T\(s)")
            case .replaceLastLetter(let s): log("R\(s)")
            default: log("?")
            }
        }
        let w: CGFloat = UIDevice.current.userInterfaceIdiom == .pad ? 834 : 390
        let host = UIView(frame: CGRect(x: 0, y: 0, width: w, height: 320))
        host.addSubview(kb)
        kb.frame = host.bounds
        kb.configureInputKind(kind)
        kb.layoutIfNeeded()
        return (kb, host)
    }

    @MainActor func testHoldQuoteOnNumbersPlane() throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom == .pad)
        var out: [String] = []
        let (kb, host) = makeKeyboard { out.append($0) }
        kb.symbolReturn = .auto   // mặc định là Tắt từ 10/11/2026; test này kiểm luật "Tự động"
        kb.debugSetPlane(numbers: true)
        kb.layoutIfNeeded()
        XCTAssertTrue(kb.debugDomainHold("\"", fire: false))
        XCTAssertEqual(out, ["T\""], "chạm thường vẫn ra ký tự gốc")
        XCTAssertEqual(kb.debugPlaneName, "letters", "\" = dấu kết vế ⇒ về chữ ngay (06/11/2026)")
        out = []
        kb.debugSetPlane(numbers: true); kb.layoutIfNeeded()
        kb.debugDomainHold("\"")                                   // giữ rồi nhấc tại chỗ
        XCTAssertEqual(out, ["T\""], "mặc định chọn ký tự gốc như stock")
        XCTAssertEqual(kb.debugPlaneName, "letters", "chọn từ popup theo cùng luật chạm")
        let l = try XCTUnwrap(kb.debugLastDomainLayout)
        XCTAssertEqual(l.count, 6)
        XCTAssertGreaterThanOrEqual(l.originX, 0)
        XCTAssertLessThanOrEqual(l.originX + l.width, kb.bounds.width)
        out = []
        kb.debugSetPlane(numbers: true); kb.layoutIfNeeded()
        kb.debugDomainHold("\"", dx: l.mirrored ? -l.itemWidth : l.itemWidth)
        XCTAssertEqual(out, ["T”"])
        XCTAssertEqual(kb.debugPlaneName, "letters", "” đóng ⇒ về chữ")
        out = []
        kb.debugSetPlane(numbers: true); kb.layoutIfNeeded()
        kb.debugDomainHold("\"", dy: -300)
        XCTAssertEqual(out, [], "trượt xa ⇒ huỷ")
        XCTAssertEqual(kb.debugPlaneName, "numbers", "huỷ ⇒ không chèn, không đổi plane")
        out = []
        kb.debugDomainHold("$")
        XCTAssertEqual(kb.debugPlaneName, "letters", "$ về chữ ở luật Tự động hiện hành")
        let d = try XCTUnwrap(kb.debugLastDomainLayout)
        out = []
        kb.debugSetPlane(numbers: true); kb.layoutIfNeeded()
        kb.debugDomainHold("$", dx: d.mirrored ? -d.itemWidth : d.itemWidth)
        XCTAssertEqual(out, ["T₫"], "₫ ngay cạnh $")
        withExtendedLifetime(host) {}
    }

    /// Field report 18/10/2026 ("dấu bằng để rất sâu"): bàn 123 iPhone không có phím "=" —
    /// giữ "/" rồi trượt một ô ra "=".
    @MainActor func testEqualsReachableFromNumbersPlane() throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom == .pad)
        XCTAssertFalse(KeyLayout.phoneNumberRows.joined().contains("="), "bàn 123 (không hàng số) chưa có phím =")
        let reachable = KeyLayout.phoneNumberRows.joined().contains {
            KeyVariants.variants(for: $0, symbolPlane: true).contains("=")
        }
        XCTAssertTrue(reachable, "= phải là biến thể giữ phím của một phím bàn 123")
        var out: [String] = []
        let (kb, host) = makeKeyboard { out.append($0) }
        kb.debugSetPlane(numbers: true)
        kb.layoutIfNeeded()
        XCTAssertTrue(kb.debugDomainHold("/", fire: false))
        XCTAssertEqual(out, ["T/"], "chạm thường vẫn ra /")
        out = []
        kb.debugDomainHold("/")
        let l = try XCTUnwrap(kb.debugLastDomainLayout)
        out = []
        kb.debugDomainHold("/", dx: l.mirrored ? -l.itemWidth : l.itemWidth)
        XCTAssertEqual(out, ["T="])
        withExtendedLifetime(host) {}
    }

    @MainActor func testPopupStaysOpenWithBaseSelected() throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom == .pad)
        var out: [String] = []
        let (kb, host) = makeKeyboard { out.append($0) }
        kb.debugSetPlane(numbers: true)
        kb.layoutIfNeeded()
        kb.debugDomainHold("\"", keepOpen: true)
        XCTAssertTrue(kb.debugDomainPopupVisible)
        XCTAssertEqual(kb.debugDomainSelection, "\"")
        XCTAssertEqual(out, [])
        withExtendedLifetime(host) {}
    }

    @MainActor func testNoVariantsWhereNotInTable() throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom == .pad)
        var out: [String] = []
        let (kb, host) = makeKeyboard { out.append($0) }
        kb.debugSetPlane(numbers: true)
        kb.layoutIfNeeded()
        XCTAssertFalse(kb.debugDomainHold("@"), "@ không có biến thể ⇒ không hẹn giờ")
        XCTAssertEqual(out, ["T@"])
        // Bàn chữ: giữ "e" vẫn là ký tự phụ số (KeyAlternates), không popup biến thể.
        kb.debugSetPlane(numbers: false)
        kb.configureKeyAlternates(numbers: true, symbols: true)
        kb.setNeedsLayout(); kb.layoutIfNeeded()
        out = []
        XCTAssertTrue(kb.debugHold("e"))
        XCTAssertEqual(out, ["Le", "R3"])
        XCTAssertFalse(kb.debugDomainPopupMade)
        withExtendedLifetime(host) {}
    }

    /// iPad: phím có nhãn phụ xám (vuốt xuống / giữ ra nhãn phụ) giữ nguyên; phím không
    /// nhãn phụ trên bàn số/ký hiệu mới có biến thể.
    @MainActor func testPadHintedKeysKeepHintGesture() throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom != .pad)
        var out: [String] = []
        let (kb, host) = makeKeyboard { out.append($0) }
        kb.debugSetPlane(numbers: true)
        kb.layoutIfNeeded()
        for t in ["1", "2", "3", "0"] where kb.debugPadHint(t) != nil {
            XCTAssertFalse(kb.debugDomainHold(t, fire: false), "\(t) có nhãn phụ ⇒ không popup")
        }
        withExtendedLifetime(host) {}
    }
}
