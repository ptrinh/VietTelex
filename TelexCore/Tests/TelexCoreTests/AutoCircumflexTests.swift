import XCTest
@testable import TelexCore

/// Issue #166 (18/11/2026): "Tự thêm dấu mũ" — công tắc, TẮT mặc định. Khi từ đã có phím
/// thanh mà vần không mũ không tồn tại, còn vần có mũ hợp lệ, hiện luôn dấu mũ.
final class AutoCircumflexTests: XCTestCase {
    private func engine(_ on: Bool, live: Bool = true, teencode: Bool = false) -> TelexEngine {
        var e = TelexEngine(); e.liveSpellCheck = live; e.teencode = teencode; e.autoCircumflex = on
        return e
    }
    private func commit(_ keys: String, on: Bool = true, live: Bool = true, teencode: Bool = false) -> String {
        var e = engine(on, live: live, teencode: teencode)
        for ch in keys { _ = e.feed(ch) }
        return e.commitText(autoRestore: true)
    }
    private func composed(_ keys: String, on: Bool = true) -> String {
        var e = engine(on)
        for ch in keys { _ = e.feed(ch) }
        return e.composed
    }

    static let rows: [(String, String)] = [
        // iê, yê, uyê
        ("vietj", "việt"), ("viejt", "việt"), ("viecj", "việc"), ("nguyenx", "nguyễn"),
        ("biets", "biết"), ("tienf", "tiền"), ("dieuf", "diều"), ("ddieemr", "điểm"),
        ("thiengs", "thiếng"), ("tiepj", "tiệp"), ("yeus", "yếu"), ("yenr", "yển"),
        ("yeets", "yết"), ("chuyenj", "chuyện"), ("quyets", "quyết"),
        ("ddienj", "điện"), ("VIETJ", "VIỆT"), ("Vietj", "Việt"),
        // ê trước nh, ch, u
        ("benhj", "bệnh"), ("lechj", "lệch"), ("keuf", "kều"), ("ddeuf", "đều"),
        // uê
        ("hues", "huế"), ("thuee", "thuê"), ("tuechj", "tuệch"),
        // uâ
        ("luanj", "luận"), ("xuats", "xuất"), ("khuays", "khuấy"), ("tuanf", "tuần"),
    ]

    func testAddsTheHat() {
        for (keys, want) in Self.rows where keys != "hues" && keys != "thuee" {
            XCTAssertEqual(commit(keys), want, keys)
            XCTAssertEqual(commit(keys, live: false), want, "no live check: \(keys)")
            XCTAssertEqual(commit(keys, teencode: true), want, "teencode: \(keys)")
        }
        XCTAssertEqual(composed("hues"), "huế")
    }

    func testOffChangesNothing() {
        XCTAssertFalse(TelexEngine().autoCircumflex)
        for keys in ["vietj", "viejt", "benhj", "luanj", "keuf", "nguyenx"] {
            var a = TelexEngine(); a.liveSpellCheck = true
            var b = TelexEngine(); b.liveSpellCheck = true; b.autoCircumflex = false
            for ch in keys { _ = a.feed(ch); _ = b.feed(ch) }
            XCTAssertEqual(a.composed, b.composed)
            XCTAssertFalse(a.composed.contains("ệ") || a.composed.contains("ậ")
                           || a.composed.contains("ề") || a.composed.contains("ễ"), keys)
        }
    }

    /// Vần không mũ là vần thật ⇒ không đụng tới.
    func testRealPlainRimesStay() {
        let rows: [(String, String)] = [
            ("quanr", "quản"), ("quats", "quát"), ("quays", "quáy"), ("quef", "què"),
            ("xengr", "xẻng"), ("secs", "séc"), ("tenf", "tèn"), ("mets", "mét"),
            ("hoanf", "hoàn"), ("muaf", "mùa"), ("kias", "kía"), ("theer", "thể"),
            ("meof", "mèo"), ("khoer", "khỏe"), ("giengs", "giéng"),
        ]
        for (keys, want) in rows {
            XCTAssertEqual(commit(keys).precomposedStringWithCanonicalMapping,
                           want.precomposedStringWithCanonicalMapping, keys)
        }
    }

    /// Không có thanh (hoặc thanh bị vần tắc loại) ⇒ không thêm mũ.
    func testNeedsALiveTone() {
        XCTAssertEqual(composed("viet"), "viet")
        XCTAssertEqual(composed("benh"), "benh")
        XCTAssertEqual(composed("vietf"), composed("vietf", on: false))
        XCTAssertEqual(composed("vietjj"), composed("vietjj", on: false))   // huỷ thanh
    }

    /// Chỉ là bước hiển thị: gõ tiếp, xoá vẫn y như không có tính năng.
    func testParseStateUntouched() {
        var e = engine(true)
        for ch in "vietj" { _ = e.feed(ch) }
        XCTAssertEqual(e.composed, "việt")
        _ = e.backspace()                       // ⌫ xoá chữ t, thanh còn ⇒ vần mở "ie" không thêm mũ
        XCTAssertEqual(e.composed, "vịe")
        _ = e.feed("c")
        XCTAssertEqual(e.composed, "việc")
        // Người quen tay vẫn gõ đủ "ee": kết quả như cũ.
        XCTAssertEqual(commit("vieetj"), "việt")
        XCTAssertEqual(commit("vieejt"), "việt")
        XCTAssertEqual(commit("luaanj"), "luận")
        // Thanh gõ sớm, mũ hiện khi vần đủ.
        XCTAssertEqual(composed("viej"), composed("viej", on: false))
        XCTAssertEqual(composed("viejt"), "việt")
    }

    /// Phím gốc là từ tiếng Anh ⇒ vẫn trả về phím gốc như trước.
    func testEnglishStillRestores() {
        for w in ["clients", "guest", "reuse", "quest", "use"] {
            XCTAssertEqual(commit(w), commit(w, on: false), w)
        }
    }
}
