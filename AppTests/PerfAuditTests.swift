import XCTest
@testable import VietTelex
@testable import TelexCore

// Hàng rào cho đợt tối ưu 17/08/2026 (audit hiệu năng). Mỗi test ở đây pin một
// tính chất mà nếu ai đó "dọn dẹp" làm hỏng thì rất khó phát hiện bằng mắt: cờ
// engine bị rơi trên đường truyền, hoặc watchdog quay lại đốt pin khi gõ tiếng Anh.
final class PerfAuditTests: XCTestCase {

    // MARK: Gộp 8 cờ engine vào MỘT lần khoá

    func testEngineFlagsSnapshotMatchesIndividualGetters() {
        // Ảnh chụp phải khớp từng getter — nếu ai thêm cờ vào EngineFlags mà quên
        // đọc đúng biến nền, test này đỏ thay vì âm thầm gửi giá trị mặc định.
        let s = AppState.shared
        let f = s.engineFlags()
        XCTAssertEqual(f.freeMarking, s.freeMarking)
        XCTAssertEqual(f.modernTone, s.modernOrthography)
        XCTAssertEqual(f.liveSpellCheck, s.liveSpellCheck)
        XCTAssertEqual(f.simpleTelex, s.simpleTelex)
        XCTAssertEqual(f.quickTelex, s.quickTelex)
        XCTAssertEqual(f.vniMode, s.vniMode)
        XCTAssertEqual(f.bracketVowels, s.bracketVowels)
        XCTAssertEqual(f.contextualEnglish, s.contextualEnglish)
        XCTAssertEqual(f.retroactiveEnglish, s.retroactiveEnglish)
        XCTAssertEqual(f.englishByFrequency, s.englishByFrequency)
        XCTAssertEqual(f.teencode, s.teencode)
        XCTAssertEqual(f.autoCircumflex, s.autoCircumflex)
    }

    func testEngineFlagsSnapshotFollowsAToggle() {
        // Ảnh chụp là ảnh MỚI mỗi lần gọi, không phải cache thiu: hai path nóng đẩy
        // cờ vào engine mỗi phím chính vì user có thể gạt toggle giữa từ.
        let s = AppState.shared
        let saved = s.vniMode
        defer { s.vniMode = saved }
        s.vniMode = !saved
        XCTAssertEqual(s.engineFlags().vniMode, !saved)
    }

    func testEveryEngineFlagIsCarriedIntoTheEngine() {
        // Đường truyền đầy đủ: đặt MỌI cờ về giá trị nghịch với mặc định của engine
        // rồi apply — cờ nào bị quên trong apply() sẽ lộ ra ngay.
        var flags = AppState.EngineFlags()
        flags.freeMarking = true; flags.modernTone = true; flags.liveSpellCheck = true
        flags.simpleTelex = true; flags.quickTelex = true; flags.vniMode = true
        flags.bracketVowels = true; flags.contextualEnglish = true; flags.teencode = true
        flags.autoRestore = true; flags.retroactiveEnglish = true; flags.englishByFrequency = true
        flags.autoCircumflex = true
        var e = TelexEngine()
        e.apply(flags)
        XCTAssertTrue(e.freeMarking); XCTAssertTrue(e.modernTone)
        XCTAssertTrue(e.liveSpellCheck); XCTAssertTrue(e.simpleTelex)
        XCTAssertTrue(e.quickTelex); XCTAssertTrue(e.vniMode)
        XCTAssertTrue(e.bracketVowels); XCTAssertTrue(e.contextualEnglish); XCTAssertTrue(e.teencode)
        XCTAssertTrue(e.eagerEnglishRestore); XCTAssertTrue(e.retroactiveEnglish); XCTAssertTrue(e.englishByFrequency)
        XCTAssertTrue(e.autoCircumflex)

        var allOff = AppState.EngineFlags()
        allOff.freeMarking = false; allOff.modernTone = false; allOff.liveSpellCheck = false
        allOff.simpleTelex = false; allOff.quickTelex = false; allOff.vniMode = false
        allOff.bracketVowels = false; allOff.contextualEnglish = false; allOff.teencode = false
        allOff.autoRestore = false; allOff.retroactiveEnglish = false; allOff.englishByFrequency = false
        allOff.autoCircumflex = false
        e.apply(allOff)
        XCTAssertFalse(e.freeMarking); XCTAssertFalse(e.modernTone)
        XCTAssertFalse(e.liveSpellCheck); XCTAssertFalse(e.simpleTelex)
        XCTAssertFalse(e.quickTelex); XCTAssertFalse(e.vniMode)
        XCTAssertFalse(e.bracketVowels); XCTAssertFalse(e.contextualEnglish); XCTAssertFalse(e.teencode)
        XCTAssertFalse(e.eagerEnglishRestore); XCTAssertFalse(e.retroactiveEnglish); XCTAssertFalse(e.englishByFrequency)
        XCTAssertFalse(e.autoCircumflex)
    }

    /// "Tự thêm dấu mũ" (issue #166): công tắc mặc định TẮT ở cả ảnh chụp lẫn engine.
    func testAutoCircumflexDefaultsOff() {
        XCTAssertFalse(AppState.EngineFlags().autoCircumflex)
        XCTAssertFalse(TelexEngine().autoCircumflex)
        var e = TelexEngine()
        var f = AppState.EngineFlags(); f.autoCircumflex = true
        e.apply(f)
        for ch in "vietj" { _ = e.feed(ch) }
        XCTAssertEqual(e.composed, "việt")
    }

    func testEngineFlagsHasExactlyTheDocumentedCount() {
        // Thêm cờ mới vào struct mà quên thêm vào apply() là lỗi im lặng (setting
        // không tới engine, không ai báo). Đếm field buộc người thêm phải đụng cả
        // engineFlagCount lẫn hai test ở trên.
        XCTAssertEqual(Mirror(reflecting: AppState.EngineFlags()).children.count,
                       AppState.engineFlagCount)
    }

    // MARK: Watchdog không được coi phím tiếng Anh là "đang gõ"

    func testLivenessStampOnlyWhileVietTelexIsSelected() {
        // Tap nhìn thấy MỌI phím trên máy. Trước 17/08 phím nào cũng stamp, nên gõ
        // ABC cả buổi vẫn giữ watchdog ở trạng thái "typing active" → mỗi 3s một
        // synthetic F20 + một AX scan cross-process cho một tap không biến đổi gì.
        XCTAssertTrue(TerminalTapController.stampsLiveness(imeActive: true))
        XCTAssertFalse(TerminalTapController.stampsLiveness(imeActive: false))
    }

    // MARK: Dòng "Chế độ gõ" trong menu (19/08/2026)

    func testStrategyLabelNamesTheChannelForBothAudiences() {
        // Không có quyền AX thì MỌI app họ tap rơi về marked (đúng thiết kế
        // safe-unknown) — test host vốn không được cấp, nên phải override để đo
        // đúng nhãn của từng kênh.
        Accessibility.testTrustOverride = true
        defer { Accessibility.testTrustOverride = nil }
        FocusedFieldDetector._testSetCached(false)
        FocusedFieldDetector._testSetMarked(false)
        FocusedFieldDetector._testSetPassthrough(false)
        let c = TelexInputController()
        // Bản snapshot (localized: false) phải GIỮ TIẾNG ANH + nêu rõ kênh, để bug
        // report grep được bất kể ngôn ngữ UI của người báo.
        let term = c.strategyLabel("com.apple.Terminal", localized: false)
        XCTAssertTrue(term.contains("tap"), "terminal phải là kênh tap: \(term)")
        let notes = c.strategyLabel("com.apple.Notes", localized: false)
        XCTAssertTrue(notes.contains("in-place"), "Notes phải in-place: \(notes)")
        let excel = c.strategyLabel("com.microsoft.Excel", localized: false)
        XCTAssertTrue(excel.contains("emptyReset"), "Excel phải emptyReset: \(excel)")
        // Bản cho menu (localized: true) dùng đúng nhãn người dùng thấy trong Cài đặt.
        XCTAssertEqual(c.strategyLabel("com.apple.Notes", localized: true), VTLocalized(ModeNames.inPlace))
        // id nil (chưa biết client) không được crash và vẫn trả nhãn dùng được.
        XCTAssertFalse(c.strategyLabel(nil, localized: true).isEmpty)
    }

    // MARK: Quyết định marked chỉ giải MỘT lần mỗi phím

    func testMarkedDecisionIsPureForAGivenState() {
        // `handle()` giải `usesMarkedNow` một lần rồi dùng lại cho mọi nhánh. Điều đó
        // chỉ đúng nếu hàm là thuần theo state — pin lại đây để ai thêm side effect
        // (đọc rồi ghi lại cache) sẽ thấy giả định bị phá.
        let c = TelexInputController()
        let first = c._testUsesMarkedNow("com.apple.Terminal")
        XCTAssertEqual(first, c._testUsesMarkedNow("com.apple.Terminal"))
        XCTAssertEqual(first, c._testUsesMarkedNow("com.apple.Terminal"))
    }

    // MARK: Đợt 14/10/2026 — marked text không cấp phát NSColor mỗi phím

    func testMarkedTextAttributesReuseOneColorAndKeepBase() {
        let base: [NSAttributedString.Key: Any] = [NSAttributedString.Key("NSMarkedClauseSegment"): 0]
        let a = TelexInputController.markedTextAttributes(base: base)
        let b = TelexInputController.markedTextAttributes(base: [:])
        XCTAssertEqual(a[.underlineStyle] as? Int, 1)
        XCTAssertEqual(a[NSAttributedString.Key("NSMarkedClauseSegment")] as? Int, 0)   // base giữ nguyên
        let ca = a[.underlineColor] as AnyObject, cb = b[.underlineColor] as AnyObject
        XCTAssertTrue(ca === cb, "underline colour must be one shared instance")
        // Công thức đã field-test 21/07: alpha ≈ 1/255, KHÔNG trong suốt hẳn (Chromium).
        let c = TelexInputController.markedUnderlineColor
        XCTAssertGreaterThan(c.alphaComponent, 0)
        XCTAssertLessThan(c.alphaComponent, 0.01)
    }
}
