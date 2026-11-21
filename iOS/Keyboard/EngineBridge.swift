// EngineBridge — pure glue between TelexEngine and an abstract text proxy.
// No UIKit: fully unit-testable with a mock proxy. The keyboard view calls
// press(_:); the bridge feeds the engine and applies the minimal diff
// (deleteBackward × N + insertText) — the exact edit model iOS gives us.
import Foundation
import TelexCore

/// The slice of UITextDocumentProxy the bridge needs.
protocol TextProxyLike {
    func insertText(_ text: String)
    func deleteBackward()
    var isSecure: Bool { get }
    /// Chữ trước con trỏ (UITextDocumentProxy.documentContextBeforeInput). nil =
    /// host không cho biết. Chỉ đọc trước lệnh xoá ≥ CompositionSync.verifyThreshold.
    var contextBeforeInput: String? { get }
    /// Chữ SAU con trỏ (documentContextAfterInput). nil = không biết / hết văn bản.
    /// Chỉ đọc ở đường sửa dấu từ đã gõ (không phải hot path).
    var contextAfterInput: String? { get }
    /// Đang có vùng chọn khác rỗng (selectedText, iOS 16+).
    var hasSelection: Bool { get }
}

/// Shared settings (App Group on device; in-memory defaults in tests).
struct KeyboardSettings {
    // Defaults iOS (user 2026-07-24): Telex đơn giản BẬT + bỏ dấu tự do BẬT +
    // tự khôi phục tiếng Anh BẬT. (Khác macOS: simpleTelex mặc định tắt.)
    var freeMarking = true
    var simpleTelex = true
    var liveSpellCheck = true
    var autoRestore = true
    var quickTelex = false
    var modernTone = false
    /// Chính tả teencode (wá, zui, kó, bíe, thík, gòy, ừk) — mặc định TẮT như macOS
    /// 1.7.11 (maintainer 25/09/2026, issue #94).
    var teencode = false
    /// "Tự thêm dấu mũ" (issue #166): vietj → việt, benhj → bệnh khi vần không mũ không tồn tại.
    /// Mặc định TẮT (cùng macOS/Linux).
    var autoCircumflex = false
    var showSuggestions = true
    var learnWords = true      // đi theo showSuggestions (không còn toggle riêng)
    var filterSensitive = true
    var hapticFeedback = false // rung phím — chỉ hoạt động khi có Full Access
    /// Độ mạnh rung 10…100 (%), mặc định KeyHaptics.defaultPercent (30; trước 45) khi key vắng.
    var hapticStrength = KeyHaptics.defaultPercent
    /// Âm thanh phím riêng (KeySound) — mặc định TẮT (= click hệ thống như cũ). Cần Full Access.
    var keySound = false
    /// Âm lượng âm phím 0…100 (%), mặc định 50.
    var keySoundVolume = 50
    /// Kiểu âm phím (KeySoundStyle.rawValue): system ("iOS", click hệ thống)|subtle|wood|mechanical|typewriter|bubble|rock|pop|water|vintage|phao|jingle|piano|dantranh|trong|boo|guitar|custom.
    var keySoundStyle = KeySoundStyle.defaultStyle.rawValue
    /// Gợi ý sửa lỗi chạm trượt phím kề (AdjacentKeyFixer) — mặc định BẬT (25/09/2026).
    var autoFixAdjacent = true
    /// Quyết định theo ngữ cảnh (như macOS, mặc định BẬT): sau một từ tiếng Anh, từ
    /// mơ hồ kế tiếp giữ tiếng Anh ("he is" → he is, không phải "he í").
    var contextualEnglish = true
    /// "Tự sửa từ phía trước" (thử nghiệm, mặc định TẮT; chỉ hiện khi contextualEnglish
    /// bật): engine luôn quyết định sửa ngược tiếng Anh khi contextualEnglish bật
    /// (docs/DESIGN.md "Sửa ngược tiếng Anh"); công tắc này chọn TỰ ÁP (+ chip "Khôi
    /// phục", ⌫ ngay sau trả lại) thay vì chỉ MỜI qua chip trên thanh gợi ý.
    var retroEnglishAuto = false
    /// "Đoán từ trùng theo tần suất" (thử nghiệm, mặc định TẮT): engine `englishByFrequency`
    /// (đầu cụm "his" → His khi âm tiết Việt hiếm; từ kế cho thấy tiếng Việt ⇒ LẬT LẠI). Phép lật
    /// lại luôn tự áp (kể cả công tắc sửa ngược tắt, kể cả Enter — áp trước khi chèn ký tự).
    var englishByFrequency = false
    /// Sửa dấu từ đã gõ xong (mặc định BẬT, user 26/09/2026): ⌫ ngay sau space/dấu
    /// câu mở lại từ vừa chốt, và phím dấu thanh ngay sau một từ nạp lại từ đó.
    var reEditWord = true
    /// Gõ vuốt (thử nghiệm, mặc định TẮT): tắt ⇒ không dựng template, không theo dõi
    /// touchesMoved thêm — 0 RAM/CPU.
    var swipeTyping = false
    /// Vuốt ra từ tiếng Anh (công tắc con của Gõ vuốt) — mặc định BẬT: câu Việt chen từ
    /// Anh rất thường (check mail, gửi file); decoder nghiêng Việt + biên độ nên chỉ ra
    /// tiếng Anh khi hình vuốt thắng rõ / đang trong mạch Anh, từ điển chỉ nạp khi gõ vuốt
    /// bật. Giống Android.
    var swipeEnglish = true
    /// Giải mã vuốt bằng mô hình FUTO Swipe (thử nghiệm, mặc định TẮT — FutoSwipe.swift):
    /// tắt ⇒ không tải model. Giống Android Keys.SWIPE_FUTO.
    var swipeFuto = false
    /// Kiểu gõ VNI (mặc định TẮT = Telex): số 1–9/0 mang dấu KHI ĐANG SOẠN TỪ (hoặc sửa
    /// dấu từ ngay trước con trỏ); ngoài từ vẫn là số. Engine giống macOS (`vniMode`).
    var vniMode = false
    /// Chọn phím theo ngữ cảnh lúc chạm vùng biên 2 phím (TouchTarget) — thử nghiệm, mặc
    /// định BẬT (mô phỏng: lỗi phím giảm ~55%, người gõ chuẩn không tệ hơn). Giống Android.
    var smartTouch = true
    /// Gõ tắt (mặc định BẬT, bảng mặc định RỖNG như macOS — người dùng tự thêm hoặc bấm
    /// "Thêm bộ gợi ý" trong app). Bảng lưu App Group key "shortcuts" ([khoá: nội dung]).
    var shortcutsEnabled = true
    var shortcuts = ShortcutTable()
    /// Dùng Thay thế văn bản của iOS làm gõ tắt (SystemTextReplacement) — mặc định BẬT (chỉ
    /// đọc dữ liệu người dùng tự tạo). Tắt (hoặc tắt Gõ tắt) ⇒ không gọi UILexicon.
    var useSystemTextReplacement = true
    /// Chip "Thêm dấu" tự hiện sau dấu cách khi câu trước con trỏ gõ không dấu (Plus) —
    /// mặc định TẮT (27/09/2026, ưu tiên hiệu năng): tắt ⇒ không đọc context / không chạy
    /// AddTones ở mỗi dấu cách.
    var addTonesChip = false
    /// Chip số (đọc số thành chữ / định dạng tiền / máy tính) — mặc định BẬT; tắt ⇒ không
    /// đọc context sau chữ số.
    var numberChips = true
    /// "Hiện kết quả phép tính": gõ "12*3=" → chip "36" ở slot đầu — mặc định BẬT; chỉ đọc
    /// context ngay sau phím "=", tắt ⇒ không làm gì.
    var mathResults = true
    /// Công cụ văn bản (Plus — thẻ "Công cụ" của bảng ☰) — mặc định BẬT;
    /// người dùng tắt được ở màn Plus / Gõ tắt & mẫu câu. Tắt ⇒ không chip, không làm gì.
    /// Giống Android Keys.TEXT_TOOLS_ENABLED.
    var textToolsEnabled = true
    /// "Sửa lỗi bằng Apple Intelligence" (Plus, iOS 26+ — AIAssist.swift) — mặc định TẮT; tắt ⇒
    /// không đọc vùng chọn, không nạp VTIntelligence, không prewarm model (0 chi phí).
    var aiProofread = false
    /// "Gợi ý cả khi ứng dụng tắt gợi ý" (#113, như nhiều bàn phím khác) — mặc định BẬT: ô
    /// autocorrection = .no không nhạy cảm vẫn gợi ý chữ (không tự sửa, không học). Tắt ⇒
    /// như cũ: chỉ thanh công cụ (StripMode.tools). Song sinh Android `suggestInNoSuggestFields`.
    var suggestInNoSuggestFields = true
    /// Emoji trên thanh gợi ý khi đang gõ — mặc định BẬT; tắt ⇒ không tra bảng emoji mỗi phím.
    var emojiSuggest = true
    /// "Số từ gợi ý" (SuggestionCount): 0 = Tự động (3 ô), 1…5. Song sinh Android.
    var suggestionCount = SuggestionCount.auto
    /// Nút "Dán" nội dung vừa copy trên thanh gợi ý — mặc định BẬT; tắt ⇒ không hỏi
    /// UIPasteboard (XPC) ở đầu từ.
    var pasteButton = true
    /// Tự động viết hoa đầu câu (auto-shift) — mặc định BẬT. Bàn phím bên thứ ba không đọc
    /// được công tắc Tự động viết hoa của iOS nên có công tắc riêng; tắt ⇒ không đọc context.
    var autoCapitalize = true
    /// Vuốt phím cách đổi Tiếng Việt ↔ Tiếng Anh (mặc định TẮT ⇒ luôn Tiếng Việt).
    var spaceSwipeLanguage = false
    /// "Độ nhạy con trỏ" khi giữ phím cách (TrackpadSpeed, mặc định Vừa). Song sinh Android.
    var trackpadSpeed = TrackpadSpeed.defaultValue
    /// Tự thêm dấu cách sau . , ? ! ; : (AutoSpace) — mặc định TẮT; tắt ⇒ không đọc context.
    var autoSpaceAfterPunct = false
    /// "Vuốt phím để sao chép/dán" (KeyCommandGesture) — mặc định TẮT ⇒ router không theo dõi gì thêm.
    var swipeKeyCommands = false
    /// Tự sửa từ gõ sai ở dấu cách (AutoCorrect) — thử nghiệm, mặc định TẮT. Giống Android.
    var autoCorrect = false
    /// Giữ q…p ra 1…0 (chỉ khi hàng phím số TẮT) — mặc định BẬT. KeyAlternates.
    var longPressNumbers = true
    /// Giữ a–l, z–m ra ký hiệu — mặc định TẮT. KeyAlternates.
    var longPressSymbols = false
    /// "Giữ Shift để gõ số và ký hiệu" (ShiftHold) — mặc định BẬT. Giống Android.
    var holdShiftSymbols = true

    #if DEBUG
    /// Test: số lần load() (mỗi lần hiện bàn phím đúng MỘT lần — KeyboardStartupTests).
    nonisolated(unsafe) static var debugLoadCount = 0
    #endif
    static func load() -> KeyboardSettings {
        #if DEBUG
        debugLoadCount += 1
        #endif
        var s = KeyboardSettings()
        guard let d = UserDefaultsProvider.shared else { return s }
        if d.object(forKey: "freeMarking") != nil { s.freeMarking = d.bool(forKey: "freeMarking") }
        if d.object(forKey: "simpleTelex") != nil { s.simpleTelex = d.bool(forKey: "simpleTelex") }
        if d.object(forKey: "liveSpellCheck") != nil { s.liveSpellCheck = d.bool(forKey: "liveSpellCheck") }
        if d.object(forKey: "autoRestore") != nil { s.autoRestore = d.bool(forKey: "autoRestore") }
        if d.object(forKey: "quickTelex") != nil { s.quickTelex = d.bool(forKey: "quickTelex") }
        if d.object(forKey: "modernTone") != nil { s.modernTone = d.bool(forKey: "modernTone") }
        if d.object(forKey: "teencode") != nil { s.teencode = d.bool(forKey: "teencode") }
        if d.object(forKey: "autoCircumflex") != nil { s.autoCircumflex = d.bool(forKey: "autoCircumflex") }
        if d.object(forKey: "showSuggestions") != nil { s.showSuggestions = d.bool(forKey: "showSuggestions") }
        if d.object(forKey: "filterSensitive") != nil { s.filterSensitive = d.bool(forKey: "filterSensitive") }
        if d.object(forKey: "hapticFeedback") != nil { s.hapticFeedback = d.bool(forKey: "hapticFeedback") }
        if d.object(forKey: "hapticStrength") != nil { s.hapticStrength = max(10, min(100, d.integer(forKey: "hapticStrength"))) }
        if d.object(forKey: "keySound") != nil { s.keySound = d.bool(forKey: "keySound") }
        if d.object(forKey: "keySoundVolume") != nil { s.keySoundVolume = max(0, min(100, d.integer(forKey: "keySoundVolume"))) }
        if let v = d.string(forKey: "keySoundStyle"), KeySoundStyle(rawValue: v) != nil { s.keySoundStyle = v }
        if d.object(forKey: "autoFixAdjacent") != nil { s.autoFixAdjacent = d.bool(forKey: "autoFixAdjacent") }
        if d.object(forKey: "contextualEnglish") != nil { s.contextualEnglish = d.bool(forKey: "contextualEnglish") }
        if d.object(forKey: RetroEnglishUI.autoKey) != nil { s.retroEnglishAuto = d.bool(forKey: RetroEnglishUI.autoKey) }
        if d.object(forKey: RetroEnglishUI.frequencyKey) != nil { s.englishByFrequency = d.bool(forKey: RetroEnglishUI.frequencyKey) }
        if d.object(forKey: "reEditWord") != nil { s.reEditWord = d.bool(forKey: "reEditWord") }
        if d.object(forKey: "swipeTyping") != nil { s.swipeTyping = d.bool(forKey: "swipeTyping") }
        if d.object(forKey: "swipeEnglish") != nil { s.swipeEnglish = d.bool(forKey: "swipeEnglish") }
        if d.object(forKey: "swipeFuto") != nil { s.swipeFuto = d.bool(forKey: "swipeFuto") }
        if d.object(forKey: "vniMode") != nil { s.vniMode = d.bool(forKey: "vniMode") }
        if d.object(forKey: "smartTouch") != nil { s.smartTouch = d.bool(forKey: "smartTouch") }
        if d.object(forKey: ShortcutFile.enabledKey) != nil { s.shortcutsEnabled = d.bool(forKey: ShortcutFile.enabledKey) }
        if s.shortcutsEnabled, let dict = d.dictionary(forKey: ShortcutFile.storeKey) as? [String: String] {
            s.shortcuts = ShortcutTable(dict)
        }
        if d.object(forKey: SystemTextReplacement.enabledKey) != nil {
            s.useSystemTextReplacement = d.bool(forKey: SystemTextReplacement.enabledKey)
        }
        let flags: [(String, WritableKeyPath<KeyboardSettings, Bool>)] = [
            ("addTonesChip", \.addTonesChip), ("numberChips", \.numberChips),
            ("mathResults", \.mathResults), ("textToolsEnabled", \.textToolsEnabled),
            (PlusFeature.aiProofreadKey, \.aiProofread),
            ("suggestInNoSuggestFields", \.suggestInNoSuggestFields),
            ("emojiSuggest", \.emojiSuggest), ("pasteButton", \.pasteButton),
            ("autoCapitalize", \.autoCapitalize), ("spaceSwipeLanguage", \.spaceSwipeLanguage),
            ("longPressNumbers", \.longPressNumbers), ("longPressSymbols", \.longPressSymbols),
            ("holdShiftSymbols", \.holdShiftSymbols),
            ("autoCorrect", \.autoCorrect), ("autoSpaceAfterPunct", \.autoSpaceAfterPunct),
            ("swipeKeyCommands", \.swipeKeyCommands)]
        for (k, kp) in flags where d.object(forKey: k) != nil { s[keyPath: kp] = d.bool(forKey: k) }
        s.suggestionCount = SuggestionCount.load(d)
        s.trackpadSpeed = TrackpadSpeed.load(d)
        s.learnWords = s.showSuggestions   // bật gợi ý = bật học (quyết định 2026-07-24)
        return s
    }

    /// Công cụ văn bản hiện thật: đã mở khoá Plus VÀ công tắc người dùng bật.
    func textToolsActive(unlocked: Bool = PlusGate.isUnlocked(.textTools)) -> Bool {
        unlocked && textToolsEnabled
    }
}

/// Indirection so tests never touch the real App Group.
enum UserDefaultsProvider {
    nonisolated(unsafe) static var shared: UserDefaults? =
        UserDefaults(suiteName: AppFlavor.appGroup)
}

final class EngineBridge {
    private var engine = TelexEngine()
    private let settings: KeyboardSettings

    /// Field không autocorrect (mã/username, autocorrectionType == .no): gõ
    /// LITERAL, bỏ qua engine Telex — như field mật khẩu. (Tắt autoRestore thôi
    /// thì diacritic lại DÍNH, ngược ý.) Set theo field ở viewWillAppear.
    var passthrough = false

    /// Ô email (FieldTraits.emailCompose): Telex/VNI BẬT để tìm người nhận theo tên ("Sown" →
    /// "Sơn"), nhưng token có "@"/"." được trả về đúng phím thô và gõ thô tới hết token
    /// (EmailTokenGuard). Không gõ tắt / không với lại từ đã chốt (không viết lại chữ app chèn).
    var emailField = false { didSet { email.invalidate() } }
    private var email = EmailTokenGuard()
    private var emailActive: Bool { emailField && !englishMode }

    /// Cho phép "với" lại chữ CÓ SẴN trước con trỏ: phím dấu/mũ nạp lại từ ngay trước con
    /// trỏ (seed), nối tiếp mẩu từ, tự sửa. Controller TẮT ở omnibox (keyboardType
    /// .webSearch): inline autocomplete tự sửa chữ bên dưới mình. KHÔNG chặn ⌫ mở lại từ
    /// VỪA CHỐT (#148: thanh địa chỉ "go␣⌫s" phải ra "gó") — xem `canReopen`.
    var reachBackAllowed = true
    /// Engine đang giữ một từ ĐÃ GÕ XONG được lấy lại để sửa (⌫ mở lại, nạp từ trước con
    /// trỏ, gạch đ): phím `d` / `w` kế tiếp là SỬA từ đó chứ không phải gõ liền mạch, nên
    /// với ngược được cả khi "Bỏ dấu tự do" tắt (#169). Sống qua các phím còn biến đổi từ;
    /// phím nối chữ, ranh giới, ⌫, reset ⇒ tắt. Xem letterCore.
    private var editingFinishedWord = false

    /// Cho phép gõ tắt ở ô này. Controller TẮT ở omnibox (.webSearch: inline autocomplete
    /// tự viết lại chữ bên dưới). Ô URL/email/mật khẩu đã là passthrough.
    var shortcutsAllowed = true

    /// Lần bung gõ tắt gần nhất — ⌫ NGAY SAU đó trả lại đúng chữ đã gõ (một lần).
    private struct ExpansionUndo {
        let typed: String
        let expansion: String
        let boundary: String
        var autoCorrect = false
        /// Sửa ngược tiếng Anh vừa TỰ ÁP: typed = chữ cũ (kể cả ký tự ranh giới),
        /// expansion = chữ mới, boundary rỗng.
        var retro = false
    }
    /// Mọi thao tác đổi hoàn tác này (phím kế, reset…) cũng bỏ lời mời sửa ngược.
    private var expansionUndo: ExpansionUndo? { didSet { retroOffer = nil } }

    // MARK: sửa ngược tiếng Anh (RetroCorrection) — docs/DESIGN.md "Sửa ngược tiếng Anh"
    /// Phép sửa engine vừa đề xuất, công tắc "Tự sửa từ phía trước" TẮT ⇒ controller hiện
    /// chip (chữ đã sửa) tới phím kế; chạm ⇒ `applyRetroOffer`.
    private(set) var retroOffer: RetroCorrection?
    /// Phép sửa vừa TỰ ÁP còn hoàn tác được (chip "Khôi phục" / ⌫ ngay sau).
    var retroUndoAvailable: Bool { expansionUndo?.retro == true }
    /// ⌫ / chip vừa trả lại chữ trước lần tự sửa ngược (một lần — controller đọc rồi xoá).
    var revertedRetro = false
    /// boundary() vừa rồi đã bung gõ tắt / tự sửa (controller: không mời "hoàn tác khôi
    /// phục", học nội dung đã bung thay vì chữ tắt).
    private(set) var expandedAtLastBoundary = false

    /// Tự sửa từ gõ sai (AutoCorrect): phím thô của từ vừa gõ → từ sửa hoặc nil. Controller
    /// chỉ gắn khi công tắc BẬT và ô cho phép; nil ⇒ boundary không tốn thêm gì.
    var autoCorrector: ((String) -> String?)?
    /// ⌫ / chip vừa trả lại chữ gốc của một lần tự sửa: chữ gốc (một lần — controller đọc rồi xoá).
    var revertedAutoCorrect: String?
    /// Lần tự sửa còn hoàn tác được (chữ gốc, từ đã sửa) — chip "↩︎ chữ gốc" trên thanh gợi ý.
    var autoCorrectUndo: (original: String, fixed: String)? {
        guard let u = expansionUndo, u.autoCorrect else { return nil }
        return (u.typed, u.expansion)
    }

    /// Thao tác cuối của bridge là chèn ký tự ranh giới → chắc chắn ký tự trước con
    /// trỏ KHÔNG phải chữ: phím đầu từ mới khỏi phải đọc context (XPC) để thử seed.
    private var lastWasOwnBoundary = false

    /// Checkpoint của phím CHỮ gần nhất — để HUỶ đúng phím đó khi nó hoá ra là cử chỉ
    /// (iPad vuốt xuống / giữ phím ra ký tự phụ, vuốt phím lên ra lệnh; gõ vuốt thì chữ đầu
    /// được hoãn tới lúc nhấc nên không cần huỷ — #172). KHÔNG dùng ⌫: engine.backspace()
    /// xoá chữ cuối ĐANG HIỆN, không gỡ phím vừa gõ — "tieng" + vuốt s từng ra "tiến#"
    /// (26/09/2026). Mọi thao tác khác ngoài letter() đều xoá checkpoint.
    private struct LetterUndo {
        let engine: TelexEngine
        let removed: String      // chữ phím đó đã xoá khỏi màn hình
        let inserted: String     // chữ phím đó đã chèn
        let ownBoundary: Bool
        var swipe: SwipeOpen? = nil
        var settled: SettledCommit? = nil
        var enWord = ""
    }
    private var letterUndo: LetterUndo?
    /// Có ghi checkpoint huỷ phím chữ không. Controller chỉ bật khi có người dùng nó
    /// (iPad vuốt xuống / giữ phím ra ký tự phụ, vuốt phím lên ra lệnh); tắt ⇒ 0 copy engine
    /// mỗi phím.
    var letterUndoEnabled = true

    // MARK: gõ vuốt — từ vuốt là composition ĐANG MỞ (seed)
    /// Từ vuốt vừa chèn vẫn đang mở trong engine: phím dấu Telex sửa được, gợi ý thay
    /// được, ⌫ ĐẦU TIÊN (`fresh`) xoá cả từ. `accepted` = user đã chọn từ này trên thanh
    /// gợi ý (học weight 2 khi chốt).
    struct SwipeOpen: Equatable {
        var fresh = true
        var accepted = false
        /// Từ tiếng Anh chèn NGUYÊN VĂN (giai đoạn 3): engine trống, phím dấu Telex không
        /// sửa nó (phím chữ kế = dấu cách treo), ⌫ đầu xoá cả từ, chốt ⇒ học + ngữ cảnh Anh.
        var literal: String? = nil
        /// Vuốt KHOÁ gõ tắt ("vn"): `literal` là nội dung đã bung, đây là khoá (đúng hoa/thường
        /// như vuốt) — ⌫ đầu trả lại khoá như hoàn tác gõ tắt khi gõ tay.
        var shortcutKey: String? = nil
    }
    struct SettledCommit: Equatable {
        let word: String
        let accepted: Bool
    }
    private var swipeOpen: SwipeOpen?
    /// Từ vuốt đã chốt bởi phím chữ gõ tiếp (dấu cách treo) nhưng CHƯA giao cho caller
    /// học: phím đó có thể còn bị huỷ (nó là chữ đầu của một cú vuốt mới) — khi đó từ
    /// vuốt mở lại, học sớm là học hai lần. Caller lấy bằng `takeSettledCommit()` ở
    /// thao tác kế tiếp (lúc đó phím chữ kia không còn huỷ được).
    private var settledCommit: SettledCommit?

    /// Chế độ Tiếng Anh (vuốt phím cách): phím chữ chèn NGUYÊN VĂN (không Telex/VNI), từ đang
    /// gõ nằm ở `enWord` — gợi ý tiếng Anh, gõ tắt vẫn bung. Đổi giữa chừng qua `setEnglish`.
    private(set) var englishMode = false
    private var enWord = ""

    /// Bảng gõ tắt hiệu lực = settings.shortcuts (+ Thay thế văn bản iOS khi nạp xong).
    private var shortcutTable: ShortcutTable

    /// Bảng gõ tắt hiệu lực (từ vựng vuốt: SwipeVocab.setShortcuts) — rỗng khi tắt Gõ tắt.
    var effectiveShortcuts: ShortcutTable {
        settings.shortcutsEnabled ? shortcutTable : ShortcutTable()
    }

    /// Nội dung sẽ chèn khi VUỐT ra `word` (đã áp Shift: "vn" / "Vn" / "VN") — đúng như gõ
    /// `word` + dấu cách: chỉ khoá thuần chữ, theo công tắc Gõ tắt + ô cho phép (không ở ô
    /// passthrough / omnibox / email). nil = không phải khoá.
    func swipeShortcutExpansion(for word: String) -> String? {
        guard settings.shortcutsEnabled, shortcutsAllowed, !passthrough, !emailField,
              !shortcutTable.isEmpty, ShortcutTable.isWordKey(word) else { return nil }
        return shortcutTable.expansion(for: word)
    }

    /// Gộp Thay thế văn bản của iOS vào bảng gõ tắt (bảng VietTelex thắng khi trùng). Chỉ
    /// khi Gõ tắt + công tắc bật; controller gọi bất đồng bộ sau khi UILexicon trả về.
    func setSystemReplacements(_ system: [String: String]) {
        guard settings.shortcutsEnabled, settings.useSystemTextReplacement else { return }
        shortcutTable = SystemTextReplacement.merged(own: settings.shortcuts.entries, system: system)
        onShortcutsChanged?(shortcutTable)
    }

    /// Bảng gõ tắt hiệu lực vừa đổi (Thay thế văn bản iOS nạp xong) — controller nối vào từ vựng vuốt
    /// khi gõ vuốt bật; nil = không ai cần (0 việc).
    var onShortcutsChanged: ((ShortcutTable) -> Void)?

    init(settings: KeyboardSettings = .load()) {
        self.settings = settings
        self.shortcutTable = settings.shortcuts
        engine.freeMarking = settings.freeMarking
        engine.simpleTelex = settings.simpleTelex
        engine.liveSpellCheck = settings.liveSpellCheck
        // "goog" thay vì "gôg" giữa từ — chỉ khi tự khôi phục bật (boundary giữ nguyên).
        engine.eagerEnglishRestore = settings.autoRestore
        engine.quickTelex = settings.quickTelex
        engine.modernTone = settings.modernTone
        engine.teencode = settings.teencode
        engine.autoCircumflex = settings.autoCircumflex
        engine.contextualEnglish = settings.contextualEnglish
        engine.vniMode = settings.vniMode
        // Cả hai chế độ (mời / tự áp) cần quyết định của engine; contextualEnglish tắt ⇒ không gì cả.
        engine.retroactiveEnglish = settings.contextualEnglish
        engine.englishByFrequency = settings.englishByFrequency
    }

    /// A letter key ("a"…"z", already cased by the shift state).
    func letter(_ ch: Character, proxy: TextProxyLike) {
        letterUndo = nil
        expansionUndo = nil
        guard !proxy.isSecure, !passthrough else {
            proxy.insertText(String(ch))
            letterUndo = LetterUndo(engine: engine, removed: "", inserted: String(ch),
                                    ownBoundary: lastWasOwnBoundary)
            return
        }
        if emailActive {
            if !email.synced { email.sync(context: proxy.contextBeforeInput) }
            if email.literal {                        // token địa chỉ: phím thô, ⌫ thường
                proxy.insertText(String(ch))
                email.appended(shown: String(ch), raw: String(ch))
                lastWasOwnBoundary = false
                return
            }
        }
        if swipeOpen != nil {
            letterAfterSwipe(ch, proxy: proxy)
            return
        }
        letterCore(ch, proxy: proxy)
        letterUndo?.settled = settledCommit
    }

    /// Đổi Tiếng Việt ↔ Tiếng Anh: chốt từ đang gõ như ranh giới rỗng (auto-restore, không
    /// gõ tắt, không chèn ký tự nào) rồi đổi chế độ. Trả từ đã chốt (caller học).
    @discardableResult
    func setEnglish(_ on: Bool, proxy: TextProxyLike) -> String {
        guard on != englishMode else { return "" }
        let final = isComposing ? boundary("", proxy: proxy, expand: false) : ""
        englishMode = on
        engine.reset(); engine.forgetLastCommit()
        // phím kế là đầu từ MỚI của ngôn ngữ kia — không nạp lại / nối vào từ vừa chốt
        enWord = ""; letterUndo = nil; swipeOpen = nil; lastWasOwnBoundary = true
        email.invalidate()
        return final
    }

    /// Vuốt phím cách khi đang gõ dở một từ (ONBOARDING-SPEC §7): đổi chế độ VÀ chuyển luôn
    /// từ đang soạn sang ngôn ngữ đích, từ vẫn mở. Sang EN ⇒ thay bằng đúng phím gốc đã gõ
    /// ("Hí" → "His", "vẻy" → "very"); sang VI ⇒ chạy lại phím gốc qua Telex/VNI ("His" →
    /// "Hí") — kể cả khi engine đã đóng băng tiếng Anh giữa từ. Khứ hồi trả đúng như cũ. Chỉ
    /// xoá/chèn đúng từ đó (CompositionSync.canDelete). Không có từ gõ tay đang soạn / từ vuốt
    /// còn mở (từ từ điển, phím gốc là phím tổng hợp) / ô email / chữ lệch / phím ngoài engine
    /// ⇒ false, KHÔNG đổi gì (caller dùng `setEnglish` như cũ). Port 1:1 Android.
    func convertComposing(toEnglish: Bool, proxy: TextProxyLike) -> Bool {
        guard toEnglish != englishMode, swipeOpen == nil, isComposing, !proxy.isSecure,
              !passthrough, !emailField else { return false }
        let shown = typedWord
        // Vuốt hiếm ⇒ luôn đối chiếu chữ trước con trỏ (threshold 1), không như hot path.
        guard CompositionSync.canDelete(shown.count, expected: shown,
                                        context: { proxy.contextBeforeInput }, threshold: 1) else { return false }
        let target: String
        if toEnglish {
            target = engine.rawKeystrokes
            guard !target.isEmpty else { return false }
            engine.reset(); engine.forgetLastCommit()
            enWord = target
        } else {
            let raw = enWord
            let snapshot = engine
            for ch in raw { _ = engine.feed(ch) }
            guard engine.rawKeystrokes == raw else { engine = snapshot; return false }  // phím engine không nhận / tràn
            target = engine.composed
            enWord = ""
        }
        englishMode = toEnglish
        letterUndo = nil; expansionUndo = nil; lastWasOwnBoundary = false
        email.invalidate()
        if target != shown {
            for _ in 0..<shown.count { proxy.deleteBackward() }
            proxy.insertText(target)
        }
        TouchLog.write("lang flick: convert word → \(toEnglish ? "en" : "vi")")
        return true
    }

    /// Vuốt phím cách đổi ngôn ngữ: `convertWord` (đang ở bảng chữ) và chuyển được ⇒ từ đang
    /// soạn đổi sang ngôn ngữ đích, vẫn mở (`convertComposing`); không thì như cũ — chốt từ rồi
    /// đổi (`setEnglish`). Trả từ đã chốt cho caller học ("" khi đã chuyển / không có từ).
    @discardableResult
    func flickLanguage(toEnglish: Bool, convertWord: Bool, proxy: TextProxyLike) -> String {
        if convertWord, convertComposing(toEnglish: toEnglish, proxy: proxy) { return "" }
        return setEnglish(toEnglish, proxy: proxy)
    }

    /// Kiểu gõ đang là VNI (controller định tuyến phím số qua `vniDigit`).
    var vniMode: Bool { settings.vniMode }

    /// Phím SỐ ở kiểu gõ VNI (hàng số hoặc plane 123). true = đã xử lý như phím của từ:
    /// đang soạn từ ⇒ feed engine (áp dấu khi áp được, không thì số nằm trong từ — "mp3",
    /// như macOS); engine trống ⇒ chỉ thử sửa dấu từ ngay trước con trỏ (1–5/0/7/8).
    /// false = ngoài từ ⇒ caller chèn số như ký hiệu (boundary) — "2026" vẫn là số.
    func vniDigit(_ ch: Character, proxy: TextProxyLike) -> Bool {
        guard settings.vniMode, !englishMode, ch.isASCII, ch.isNumber, !proxy.isSecure, !passthrough else { return false }
        if emailActive, email.literal { return false }  // token địa chỉ: số là số
        if let open = swipeOpen {
            // Từ vuốt đang mở: số chỉ SỬA từ (dấu) — không sửa được ⇒ ranh giới (chốt từ +
            // số liền sau, không chèn dấu cách treo như phím chữ).
            guard open.literal == nil, !engine.isEmpty else { return false }
            let snapshot = engine
            let before = engine.composed
            let action = engine.feed(ch)
            if case .replace(let bs, let insert) = action, bs > 0,
               engine.composed != before + String(ch),
               safeToApply(action, expected: before, proxy: proxy) {
                letterUndo = nil
                apply(action, literal: String(ch), proxy: proxy)
                letterUndo = LetterUndo(engine: snapshot, removed: String(before.suffix(bs)),
                                        inserted: insert, ownBoundary: false,
                                        swipe: open, settled: settledCommit)
                swipeOpen = SwipeOpen(fresh: false, accepted: open.accepted)
                lastWasOwnBoundary = false
                return true
            }
            engine = snapshot
            return false
        }
        if !engine.isEmpty {
            letter(ch, proxy: proxy)
            return true
        }
        guard !lastWasOwnBoundary, settings.reEditWord, canReachBack, isReEditKey(ch) else {
            return false
        }
        letterUndo = nil
        return seedWordBeforeCaret(then: ch, proxy: proxy)
    }

    /// Phím chữ ngay sau từ vuốt đang mở: phím dấu Telex (s f r x j z w) BIẾN ĐỔI từ ⇒
    /// sửa từ đó (viet vuốt → việt, + s → viết). Phím khác (hoặc phím dấu không đổi
    /// gì) ⇒ dấu cách treo: chốt từ vuốt + " " rồi phím này mở từ mới. Cả hai huỷ được
    /// trọn vẹn bằng undoLastLetter (phím đó hoá ra là giữ ra ký tự phụ / vuốt-lên-lệnh).
    private func letterAfterSwipe(_ ch: Character, proxy: TextProxyLike) {
        guard let open = swipeOpen else { return }
        let snapshot = engine
        let before = open.literal ?? engine.composed
        if open.literal == nil, isReEditKey(ch) {
            let action = engine.feed(ch)
            if case .replace(let bs, let insert) = action, bs > 0,
               engine.composed != before + String(ch),
               safeToApply(action, expected: before, proxy: proxy) {
                apply(action, literal: String(ch), proxy: proxy)
                letterUndo = LetterUndo(engine: snapshot, removed: String(before.suffix(bs)),
                                        inserted: insert, ownBoundary: false,
                                        swipe: open, settled: settledCommit)
                swipeOpen = SwipeOpen(fresh: false, accepted: open.accepted)
                lastWasOwnBoundary = false
                return
            }
            engine = snapshot
            if freeMarkWord(before, key: ch, proxy: proxy) {   // chế độ chặt: w vẫn sửa từ vuốt
                swipeOpen = SwipeOpen(fresh: false, accepted: open.accepted)
                lastWasOwnBoundary = false
                return
            }
        }
        let settledBefore = settledCommit
        let final = boundary(" ", proxy: proxy)      // xoá swipeOpen + letterUndo
        settledCommit = SettledCommit(word: final, accepted: open.accepted)
        letterCore(ch, proxy: proxy)
        guard let u = letterUndo, u.removed.isEmpty else { letterUndo = nil; return }
        // Huỷ gộp: màn hình "before" → "final" + " " + chữ phím này.
        letterUndo = LetterUndo(engine: snapshot, removed: before, inserted: final + " " + u.inserted,
                                ownBoundary: false, swipe: open, settled: settledBefore)
    }

    /// Lấy (một lần) từ vuốt đã chốt bởi dấu cách treo — gọi ở đầu thao tác kế tiếp.
    func takeSettledCommit() -> SettledCommit? {
        defer { settledCommit = nil }
        return settledCommit
    }

    /// Từ vuốt đang mở (chưa chốt) — controller hiện thanh biến thể / học weight.
    var isSwipeWordOpen: Bool { swipeOpen != nil }
    /// Từ vuốt đang mở còn NGUYÊN như lúc chèn (chưa phím dấu nào sửa).
    var isFreshSwipeWord: Bool { swipeOpen?.fresh == true }
    /// Từ đang mở là từ user chọn trên thanh gợi ý (học weight 2 khi chốt).
    var openWordAccepted: Bool { swipeOpen?.accepted ?? false }

    /// Chèn từ vuốt. Đang gõ dở một từ (kể cả từ vuốt trước) ⇒ chốt nó + " " (trả về
    /// để caller học); không thì thêm " " nếu ngay trước con trỏ là chữ/dấu câu (dấu
    /// cách treo). Sau đó chèn `word` và SEED engine bằng nó để từ vẫn là composition
    /// đang mở. Seed không round-trip, hoặc boundary sẽ auto-restore nó ⇒ chữ thường
    /// (không mở), vẫn chèn.
    /// `literal` = từ tiếng Anh: chèn nguyên văn, KHÔNG seed engine (xem SwipeOpen.literal).
    @discardableResult
    func insertSwipeWord(_ word: String, accepted: Bool = false, literal: Bool = false,
                         shortcutKey: String? = nil, proxy: TextProxyLike) -> SettledCommit? {
        letterUndo = nil
        expansionUndo = nil
        var committed = settledCommit
        settledCommit = nil
        if !engine.isEmpty || swipeOpen?.literal != nil || !enWord.isEmpty {
            let wasAccepted = swipeOpen?.accepted ?? false
            // dấu cách tự chèn trước từ vuốt: không phải ranh giới người dùng gõ → không gõ tắt
            let final = boundary(" ", proxy: proxy, expand: false)
            if !final.isEmpty { committed = SettledCommit(word: final, accepted: wasAccepted) }
        } else if SwipeSpacing.needsLeadingSpace(before: proxy.contextBeforeInput) {
            engine.forgetLastCommit()                  // ⌫ không mở lại từ cũ qua " " của mình
            proxy.insertText(" ")
        }
        proxy.insertText(word)
        openSwipeWord(word, accepted: accepted, literal: literal || shortcutKey != nil)
        if let shortcutKey, swipeOpen != nil { swipeOpen?.shortcutKey = shortcutKey }
        return committed
    }

    /// Thay từ vuốt đang mở bằng `word` (biến thể trên thanh gợi ý). false = không còn
    /// mở / màn hình lệch (caller xử lý như gợi ý thường).
    func replaceSwipeWord(with word: String, literal: Bool = false, accepted: Bool = true,
                          proxy: TextProxyLike) -> Bool {
        guard let open = swipeOpen, open.literal != nil || !engine.isEmpty else { return false }
        let composed = open.literal ?? engine.composed
        guard CompositionSync.canDelete(composed.count, expected: composed,
                                        context: { proxy.contextBeforeInput }) else {
            reset()
            return false
        }
        letterUndo = nil
        for _ in 0..<composed.count { proxy.deleteBackward() }
        proxy.insertText(word)
        openSwipeWord(word, accepted: accepted, literal: literal)
        return true
    }

    /// Chip "↩︎ từ cũ" (SwipeRevise): trả từ đã chốt ngay trước từ vuốt đang mở từ `new` về
    /// `old`. Đuôi màn hình phải ĐÚNG "new + ␠ + từ đang mở" (đọc được) — lệch ⇒ không đụng.
    func restoreRevisedWord(old: String, new: String, proxy: TextProxyLike) -> Bool {
        guard let open = swipeOpen, open.literal != nil || !engine.isEmpty else { return false }
        let tail = new + " " + (open.literal ?? engine.composed)
        guard let ctx = proxy.contextBeforeInput, ctx.hasSuffix(tail) else { return false }
        letterUndo = nil
        expansionUndo = nil
        for _ in 0..<tail.count { proxy.deleteBackward() }
        proxy.insertText(old + String(tail.dropFirst(new.count)))
        engine.forgetLastCommit()            // ⌫ không mở lại "new" đã rời màn hình
        return true
    }

    private func openSwipeWord(_ word: String, accepted: Bool, literal: Bool = false) {
        lastWasOwnBoundary = false
        if literal {
            engine.reset()
            engine.forgetLastCommit()                 // ⌫ không mở lại từ trước qua từ Anh
            swipeOpen = passthrough ? nil : SwipeOpen(fresh: true, accepted: accepted, literal: word)
            return
        }
        if !passthrough, engine.seed(word),
           engine.peekCommitText(autoRestore: settings.autoRestore) == word {
            swipeOpen = SwipeOpen(fresh: true, accepted: accepted)
        } else {
            engine.reset()
            swipeOpen = nil
        }
    }

    private func letterCore(_ ch: Character, proxy: TextProxyLike) {
        let ownBoundary = lastWasOwnBoundary
        lastWasOwnBoundary = false
        if englishMode {
            letterUndo = letterUndoEnabled ? LetterUndo(engine: engine, removed: "", inserted: String(ch),
                                                        ownBoundary: ownBoundary, enWord: enWord) : nil
            enWord.append(ch)
            proxy.insertText(String(ch))
            return
        }
        // Đang sửa một từ đã gõ xong (engine đang giữ nó): `d` gạch đ, `w` thêm móc/trăng —
        // kể cả khi "Bỏ dấu tự do" tắt (engine khi đó không với ngược qua phụ âm, #169).
        let editing = editingFinishedWord
        editingFinishedWord = false
        if editing, !engine.isEmpty, !settings.vniMode, canReachBack {
            let word = engine.composed
            if ch == "d" || ch == "D", Self.strokeReEditApplies(to: word),
               strokeWord(word, proxy: proxy) { return }
            if freeMarkWord(word, key: ch, proxy: proxy) { return }
        }
        if engine.isEmpty, !ownBoundary, settings.reEditWord, canReachBack {
            if isStrokeReEdit(ch, proxy: proxy) {
                if strokeWordBeforeCaret(proxy: proxy) { return }
            } else if isReEditKey(ch) {
                // sửa từ trên màn hình: không huỷ được
                if seedWordBeforeCaret(then: ch, proxy: proxy) { return }
                if freeMarkWordBeforeCaret(key: ch, proxy: proxy) { return }
            }
            if continueWordBeforeCaret(ch, proxy: proxy) { return }
        }
        let before = engine.composed
        defer {   // phím dấu còn biến đổi từ ⇒ vẫn đang sửa; phím nối chữ ⇒ thôi
            if editing, engine.composed != before + String(ch) { editingFinishedWord = true }
        }
        // Chụp engine CHỈ khi cần huỷ phím (iPad vuốt xuống / gõ vuốt): giữ bản copy qua
        // feed() làm COW nhân đôi buffer engine MỖI PHÍM (cấp phát trên đường nóng).
        let snapshot: TelexEngine? = letterUndoEnabled ? engine : nil
        let action = engine.feed(ch)
        guard safeToApply(action, expected: before, proxy: proxy) else {
            // Chữ trước con trỏ không còn là từ đang gõ → bỏ từ cũ, phím này mở từ MỚI
            // (engine trống + 1 phím = chèn literal, không xoá gì).
            reset()
            apply(engine.feed(ch), literal: String(ch), proxy: proxy)
            return
        }
        apply(action, literal: String(ch), proxy: proxy)
        guard let snapshot else { letterUndo = nil; return }
        switch action {
        case .replace(let bs, let insert):
            letterUndo = LetterUndo(engine: snapshot, removed: String(before.suffix(bs)),
                                    inserted: insert, ownBoundary: ownBoundary)
        case .passthrough:
            letterUndo = LetterUndo(engine: snapshot, removed: "", inserted: String(ch),
                                    ownBoundary: ownBoundary)
        case .none:
            letterUndo = LetterUndo(engine: snapshot, removed: "", inserted: "",
                                    ownBoundary: ownBoundary)
        }
    }

    /// Huỷ phím chữ vừa gõ (chỉ khi chưa có thao tác nào khác xen vào): trả màn hình và
    /// engine về đúng trước phím đó. false = không huỷ được (caller tự xử lý).
    func undoLastLetter(proxy: TextProxyLike) -> Bool {
        expansionUndo = nil
        guard let u = letterUndo else { return false }
        letterUndo = nil
        if let ctx = proxy.contextBeforeInput, !ctx.hasSuffix(u.inserted) { return false }
        for _ in 0..<u.inserted.count { proxy.deleteBackward() }
        if !u.removed.isEmpty { proxy.insertText(u.removed) }
        engine = u.engine
        lastWasOwnBoundary = u.ownBoundary
        swipeOpen = u.swipe
        settledCommit = u.settled
        enWord = u.enWord
        return true
    }

    /// Phím số/ký hiệu (không phải dấu cách / Enter): ranh giới chèn `text`. Ngay sau từ vuốt
    /// còn nguyên (chưa phím nào xen vào — kể cả phím chữ vừa bị giữ ra số rồi gỡ) mà `text`
    /// mở từ mới (số / emoji / ngoặc mở) ⇒ dấu cách treo trước: "mua 2", không "mua2". ⌫ xoá
    /// số rồi dấu cách như gõ tay. Chỉ đọc context khi đúng trường hợp đó.
    @discardableResult
    func symbolBoundary(_ text: String, proxy: TextProxyLike) -> String {
        let spaced = swipeOpen?.fresh == true && SwipeSpacing.startsWord(text)
            && SwipeSpacing.spaceBefore(text, afterSwipe: true, before: proxy.contextBeforeInput)
        return boundary(spaced ? " " + text : text, proxy: proxy)
    }

    /// Space / return / punctuation: word boundary → auto-restore, then the char.
    /// Returns the FINAL committed word (post auto-restore) — the
    /// personalization model must learn what actually landed on screen.
    @discardableResult
    func boundary(_ text: String, proxy: TextProxyLike, expand: Bool = true) -> String {
        letterUndo = nil
        editingFinishedWord = false
        expansionUndo = nil
        expandedAtLastBoundary = false
        let literal = swipeOpen?.literal
        let wasSwipe = swipeOpen != nil
        swipeOpen = nil
        guard !proxy.isSecure, !passthrough else { if !text.isEmpty { proxy.insertText(text) }; return "" }
        if let literal, engine.isEmpty {
            // từ tiếng Anh nguyên văn: chốt như đã gõ, ngữ cảnh Anh cho từ gõ tiếp
            engine.noteExternalWord(literal, english: true)   // chức năng mở mạch, nội dung thì chờ từ Anh thứ hai
            if !text.isEmpty { proxy.insertText(text) }
            lastWasOwnBoundary = text.last.map { !$0.isLetter } ?? false
            return literal
        }
        if emailActive { return emailBoundary(text, proxy: proxy) }
        if englishMode {
            if expand, !wasSwipe, let expanded = tryExpandShortcut(text, proxy: proxy) { return expanded }
            let word = enWord
            enWord = ""
            if !text.isEmpty { proxy.insertText(text) }
            lastWasOwnBoundary = text.last.map { !$0.isLetter } ?? false
            return word
        }
        // Gõ tắt TRƯỚC tự khôi phục tiếng Anh. Không bung từ vuốt (từ vuốt là từ từ điển).
        if expand, !wasSwipe, let expanded = tryExpandShortcut(text, proxy: proxy) { return expanded }
        if expand, !wasSwipe, let ac = autoCorrector, let fixed = tryAutoCorrect(ac, text, proxy: proxy) { return fixed }
        let before = engine.composed
        // The character that ends the word: an apostrophe keeps an English contraction stem.
        var action = engine.commitBoundary(autoRestore: settings.autoRestore, boundary: text.first)
        if !safeToApply(action, expected: before, proxy: proxy) {
            // Lệch: KHÔNG auto-restore (sẽ xoá nhầm chữ khác) — chỉ chèn ký tự ngắt.
            reset()
            action = .none
        }
        var final = before
        if case let .replace(bs, insert) = action {
            final = String(before.dropLast(bs)) + insert
        }
        apply(action, literal: "", proxy: proxy)
        // Lật lại (englishByFrequency): sửa đoán của chính engine ("His hửng" → "hí hửng") ⇒ tự áp
        // TRƯỚC khi ký tự ranh giới vào — kể cả Enter (chưa gửi) và khi sửa ngược chỉ mời.
        if let c = engine.pendingRetroCorrection, c.flipBack { applyFlipBack(c, proxy: proxy) }
        if !text.isEmpty { proxy.insertText(text) }
        lastWasOwnBoundary = text.last.map { !$0.isLetter } ?? false
        // Engine cần MỌI ký tự ranh giới (dính "my_var" / "100W"), có sửa ngược hay không.
        // (⌫ sau khôi phục phím thô: controller mời chữ Việt trên thanh gợi ý — restoreUndo.)
        if engine.retroactiveEnglish { retroAfterBoundary(text, proxy: proxy) }
        else { for ch in text { engine.noteBoundaryCharacter(ch) } }
        return final
    }

    /// Bước 2–3 của luồng tích hợp sửa ngược: báo MỌI ký tự ranh giới vừa chèn, rồi mời
    /// (công tắc tắt) hoặc tự áp (bật) phép sửa — chỉ khi chữ trước con trỏ đúng `expected`.
    /// Enter không sửa (có thể đã gửi tin; chèn lại "\n" là phím Return của host).
    private func retroAfterBoundary(_ text: String, proxy: TextProxyLike) {
        for ch in text { engine.noteBoundaryCharacter(ch) }
        guard let c = engine.pendingRetroCorrection else { return }
        guard !text.contains("\n"), !proxy.hasSelection else { return }
        guard settings.retroEnglishAuto else { retroOffer = c; return }
        guard Self.retroMatches(c.expected, proxy.contextBeforeInput) else {
            TouchLog.write("retro: context lệch → không sửa")
            return
        }
        _ = engine.takeRetroCorrection()
        TouchLog.edit(bs: c.backspaces, insertLen: c.insert.count, insert: c.insert)
        for _ in 0..<c.backspaces { proxy.deleteBackward() }
        proxy.insertText(c.insert)
        expansionUndo = ExpansionUndo(typed: c.expected, expansion: c.insert, boundary: "", retro: true)
    }

    /// Áp phép LẬT LẠI ngay sau khi chốt từ (chưa chèn ranh giới): cùng kiểm chữ trước con trỏ
    /// như sửa ngược; lệch / có vùng chọn ⇒ bỏ (phép sửa hết hạn ở lệnh engine kế tiếp).
    private func applyFlipBack(_ c: RetroCorrection, proxy: TextProxyLike) {
        guard !proxy.hasSelection, Self.retroMatches(c.expected, proxy.contextBeforeInput) else {
            TouchLog.write("flip-back: context lệch → không sửa")
            return
        }
        _ = engine.takeRetroCorrection()
        TouchLog.edit(bs: c.backspaces, insertLen: c.insert.count, insert: c.insert)
        for _ in 0..<c.backspaces { proxy.deleteBackward() }
        proxy.insertText(c.insert)
    }

    /// Chữ trước con trỏ kết thúc ĐÚNG (từng scalar) bằng `expected`. nil (host không cho
    /// biết) ⇒ không sửa: phép sửa viết lại nhiều từ, không đoán.
    static func retroMatches(_ expected: String, _ ctx: String?) -> Bool {
        guard let ctx, !expected.isEmpty else { return false }
        let e = Array(expected.unicodeScalars), c = Array(ctx.unicodeScalars.suffix(e.count))
        return c == e
    }

    /// Nhãn chip mời: các từ ĐỔI sau khi sửa, trọn từ ("Hí cả í very fast " → "His car is").
    /// `context` = chữ trước con trỏ (lấy phần đầu từ không nằm trong phép sửa); nil/lệch ⇒
    /// chỉ dựa vào `insert`.
    static func retroLabel(_ c: RetroCorrection, context: String?) -> String {
        let exp = Array(c.expected.unicodeScalars), ins = Array(c.insert.unicodeScalars)
        var suf = 0
        while suf < exp.count, suf < ins.count, exp[exp.count - 1 - suf] == ins[ins.count - 1 - suf] { suf += 1 }
        var pre: [Unicode.Scalar] = []
        if let context, retroMatches(c.expected, context) {
            pre = Array(context.unicodeScalars.dropLast(exp.count).suffix(64))
        }
        let full = pre + ins
        func inWord(_ s: Unicode.Scalar) -> Bool { CharacterSet.alphanumerics.contains(s) || s == "'" || s == "\u{2019}" }
        var start = pre.count, end = max(start, full.count - suf)
        while start > 0, inWord(full[start - 1]) { start -= 1 }
        while end < full.count, inWord(full[end]) { end += 1 }
        var out = String.UnicodeScalarView()
        out.append(contentsOf: full[start..<end])
        let label = String(out).trimmingCharacters(in: .whitespacesAndNewlines)
        return label.isEmpty ? c.insert.trimmingCharacters(in: .whitespacesAndNewlines) : label
    }

    /// Chạm chip sửa ngược (công tắc tắt): áp phép sửa đang mời. false = không còn mời /
    /// chữ trước con trỏ đã khác ⇒ không sửa gì.
    @discardableResult
    func applyRetroOffer(proxy: TextProxyLike) -> Bool {
        guard let c = retroOffer else { return false }
        retroOffer = nil
        guard !proxy.isSecure, !passthrough, !proxy.hasSelection,
              Self.retroMatches(c.expected, proxy.contextBeforeInput) else {
            TouchLog.write("retro offer: context lệch → không sửa")
            return false
        }
        // Còn trong engine (chưa có lệnh nào khác) ⇒ lấy để lịch sử ghi các từ là tiếng Anh;
        // không thì quên lịch sử (màn hình đã khác cái engine nhớ).
        if engine.pendingRetroCorrection == c { _ = engine.takeRetroCorrection() } else { engine.resetContext() }
        TouchLog.edit(bs: c.backspaces, insertLen: c.insert.count, insert: c.insert)
        for _ in 0..<c.backspaces { proxy.deleteBackward() }
        proxy.insertText(c.insert)
        return true
    }

    /// Chip "Khôi phục" (công tắc bật): trả lại đúng chữ trước lần tự sửa ngược (như ⌫ ngay sau).
    @discardableResult
    func revertRetro(proxy: TextProxyLike) -> Bool {
        guard let u = expansionUndo, u.retro else { return false }
        expansionUndo = nil
        return undoExpansion(u, proxy: proxy)
    }

    /// Backspace. Trả true khi ⌫ này MỞ LẠI từ vừa chốt (engine lại đang gõ từ đó).
    @discardableResult
    func backspace(proxy: TextProxyLike) -> Bool {
        letterUndo = nil
        editingFinishedWord = false
        retroOffer = nil
        if let u = expansionUndo {
            expansionUndo = nil
            if undoExpansion(u, proxy: proxy) { return false }
        }
        lastWasOwnBoundary = false
        let open = swipeOpen
        swipeOpen = nil
        guard !proxy.isSecure, !passthrough else { proxy.deleteBackward(); return false }
        if let key = open?.shortcutKey, let lit = open?.literal, open?.fresh == true, engine.isEmpty {
            // ⌫ đầu ngay sau vuốt khoá gõ tắt: trả lại khoá (như hoàn tác gõ tắt gõ tay), khoá
            // vẫn mở như từ vuốt nguyên văn (⌫ kế xoá thường). Lệch ⇒ ⌫ thường.
            if CompositionSync.canDelete(lit.count, expected: lit, context: { proxy.contextBeforeInput }) {
                for _ in 0..<lit.count { proxy.deleteBackward() }
                proxy.insertText(key)
                swipeOpen = SwipeOpen(fresh: false, accepted: true, literal: key)
                TouchLog.write("shortcut undo (vuốt): -\(lit.count) +\(key.count)")
            } else {
                proxy.deleteBackward()
            }
            return false
        }
        if let lit = open?.literal, open?.fresh == true, engine.isEmpty {
            // ⌫ đầu ngay sau vuốt từ tiếng Anh: xoá cả từ. Lệch ⇒ ⌫ thường.
            if CompositionSync.canDelete(lit.count, expected: lit, context: { proxy.contextBeforeInput }) {
                for _ in 0..<lit.count { proxy.deleteBackward() }
            } else {
                TouchLog.write("failsafe: swipe-word ⌫ len=\(lit.count) → ⌫ thường")
                proxy.deleteBackward()
            }
            return false
        }
        if open?.fresh == true, !engine.isEmpty {
            // ⌫ đầu tiên ngay sau vuốt: xoá cả từ (như Gboard/QuickPath). Lệch ⇒ ⌫ thường.
            let composed = engine.composed
            engine.reset()
            if CompositionSync.canDelete(composed.count, expected: composed,
                                         context: { proxy.contextBeforeInput }) {
                for _ in 0..<composed.count { proxy.deleteBackward() }
            } else {
                TouchLog.write("failsafe: swipe-word ⌫ len=\(composed.count) → ⌫ thường")
                proxy.deleteBackward()
            }
            return false
        }
        if englishMode {
            if !enWord.isEmpty { enWord.removeLast() }
            proxy.deleteBackward()
            return false
        }
        guard !engine.isEmpty else {
            if emailActive { email.deletedOne() }
            if engine.canReopenLastCommit { return reopenLastCommit(proxy: proxy) }
            proxy.deleteBackward()
            return false
        }
        let before = engine.composed
        let action = engine.backspace()
        guard safeToApply(action, expected: before, proxy: proxy) else {
            reset()                    // lệch → xoá thường 1 ký tự, không vẽ lại từ
            proxy.deleteBackward()
            return false
        }
        switch action {
        case .replace(let bs, let insert):
            for _ in 0..<bs { proxy.deleteBackward() }
            if !insert.isEmpty { proxy.insertText(insert) }
        case .passthrough, .none:
            proxy.deleteBackward()
        }
        return false
    }

    /// Với lại từ đã chốt (⌫ mở lại, phím dấu nạp lại từ trước con trỏ): không ở ô email.
    private var canReachBack: Bool { reachBackAllowed && !emailField }
    /// ⌫ mở lại từ VỪA CHỐT: được cả ở omnibox (.webSearch) — chỉ đụng chữ chính mình vừa
    /// gõ + ranh giới của mình, context xác nhận trước VÀ sau khi xoá, có vùng chọn (inline
    /// autocomplete) ⇒ bỏ; sau đó là đường soạn từ thường (safeToApply trước mỗi lần xoá),
    /// vốn đã chạy ở omnibox (#148). Không ở ô email.
    private var canReopen: Bool { !emailField }

    // MARK: - Ô email (EmailTokenGuard)

    /// Ranh giới ở ô email. Token chưa là địa chỉ + phím không phải "@"/"." ⇒ chốt như thường
    /// (auto-restore). Phím "@"/"." ⇒ phần token mình gõ + từ đang soạn trả về ĐÚNG phím thô
    /// (fail-safe: chỉ khi chữ trước con trỏ đúng là nó; không thì chỉ từ đang soạn; không nữa thì
    /// không sửa gì), chèn ranh giới, gõ thô tới hết token. Không gõ tắt / tự sửa ở ô email.
    private func emailBoundary(_ text: String, proxy: TextProxyLike) -> String {
        if !email.synced { email.sync(context: proxy.contextBeforeInput) }
        lastWasOwnBoundary = text.last.map { !$0.isLetter } ?? false
        guard email.needsRestore(text) else {
            let before = engine.composed, raw = engine.rawKeystrokes
            let action = engine.commitBoundary(autoRestore: settings.autoRestore)
            guard safeToApply(action, expected: before, proxy: proxy) else {
                // Lệch: không sửa chữ trên màn hình; token đọc lại ở phím kế.
                reset()
                if !text.isEmpty { proxy.insertText(text) }
                lastWasOwnBoundary = text.last.map { !$0.isLetter } ?? false
                return before
            }
            var final = before
            if case let .replace(bs, insert) = action { final = String(before.dropLast(bs)) + insert }
            apply(action, literal: "", proxy: proxy)
            if !text.isEmpty { proxy.insertText(text) }
            email.appended(shown: final, raw: raw, text: text)
            return final
        }
        let composed = engine.composed, composedRaw = engine.rawKeystrokes
        engine.reset()
        engine.forgetLastCommit()
        if let plan = email.restorePlan(composed: composed, composedRaw: composedRaw) {
            if CompositionSync.canDelete(plan.shown.count, expected: plan.shown,
                                         context: { proxy.contextBeforeInput }, threshold: 1) {
                TouchLog.write("email: restore raw -\(plan.shown.count) +\(plan.raw.count)")
                for _ in 0..<plan.shown.count { proxy.deleteBackward() }
                proxy.insertText(plan.raw)
                if !text.isEmpty { proxy.insertText(text) }
                email.restored(to: plan.raw, text: text)
                return ""
            }
            if composed != composedRaw,
               CompositionSync.canDelete(composed.count, expected: composed,
                                         context: { proxy.contextBeforeInput }, threshold: 1) {
                TouchLog.write("email: restore word only -\(composed.count) +\(composedRaw.count)")
                for _ in 0..<composed.count { proxy.deleteBackward() }
                proxy.insertText(composedRaw)
                if !text.isEmpty { proxy.insertText(text) }
                email.appended(shown: composedRaw, raw: composedRaw, text: text)
                return ""
            }
            TouchLog.write("email: context lệch → không sửa")
            if !text.isEmpty { proxy.insertText(text) }
            email.appended(shown: composed, raw: composedRaw, text: text)
            return ""
        }
        if !text.isEmpty { proxy.insertText(text) }
        email.appended(shown: composed, raw: composedRaw, text: text)
        return ""
    }

    // MARK: - Gõ tắt

    /// Bung gõ tắt ở ký tự ranh giới `text` nếu khớp (xem ShortcutTable): xoá chữ đã gõ
    /// (fail-safe CompositionSync: chỉ khi chữ trước con trỏ đúng là nó), chèn nội dung +
    /// ranh giới. Trả nội dung đã bung, nil = không bung (boundary chạy tiếp như thường).
    private func tryExpandShortcut(_ text: String, proxy: TextProxyLike) -> String? {
        let table = shortcutTable
        guard settings.shortcutsEnabled, shortcutsAllowed, !table.isEmpty else { return nil }
        if !typedEmpty, ShortcutTable.triggersWord(text),
           let e = table.wordExpansion(composed: typedWord, raw: typedRaw) {
            let composed = typedWord
            let ctx = proxy.contextBeforeInput
            let glued = ShortcutTable.isGlued(word: composed, context: ctx)
            if !glued, CompositionSync.canDelete(composed.count, expected: composed, context: { ctx }) {
                return applyExpansion(typed: composed, expansion: e, boundary: text, proxy: proxy)
            }
            // Dính trước ("2fa": "fa" sau số) — cả cụm có thể là khoá chữ+số (#109).
            if !glued { return nil }
        }
        // Khoá ký hiệu/số: khoảng trắng/Enter. Khoá chữ+số (#109): cả dấu câu, như khoá chữ.
        let tokenTrigger = ShortcutTable.triggersToken(text)
        if table.hasTokenKeys, tokenTrigger || ShortcutTable.triggersAlnum(text),
           let ctx = proxy.contextBeforeInput, !proxy.hasSelection,
           let m = table.tokenExpansion(context: ctx),
           tokenTrigger || ShortcutTable.isAlnumKey(m.token),
           typedEmpty || m.token.hasSuffix(typedWord) {
            return applyExpansion(typed: m.token, expansion: m.expansion, boundary: text, proxy: proxy)
        }
        return nil
    }

    private func applyExpansion(typed: String, expansion: String, boundary text: String,
                                proxy: TextProxyLike) -> String {
        engine.reset()
        enWord = ""
        engine.forgetLastCommit()                    // ⌫ không mở lại chữ tắt qua engine
        engine.noteExternalWord(english: false)
        TouchLog.edit(bs: typed.count, insertLen: expansion.count, insert: expansion)
        for _ in 0..<typed.count { proxy.deleteBackward() }
        proxy.insertText(expansion)
        proxy.insertText(text)                       // tách riêng: "\n" là phím Return của host
        lastWasOwnBoundary = text.last.map { !$0.isLetter } ?? false
        expandedAtLastBoundary = true
        // Enter có thể đã gửi tin — không hứa hoàn tác qua nó.
        if !text.contains("\n") {
            expansionUndo = ExpansionUndo(typed: typed, expansion: expansion, boundary: text)
        }
        return expansion
    }

    /// Tự sửa ở ranh giới `text`: chỉ khi ô sửa lại được, chữ trước con trỏ đúng là từ đang
    /// soạn (không dính URL/email/số — ShortcutTable.isGlued), chữ hoa hợp lệ
    /// (AutoCorrect.caseAllows). Thay từ + ranh giới; ⌫ ngay sau trả lại đúng chữ boundary
    /// lẽ ra đã chốt (như hoàn tác gõ tắt).
    private func tryAutoCorrect(_ ac: (String) -> String?, _ text: String, proxy: TextProxyLike) -> String? {
        guard !engine.isEmpty, AutoCorrect.triggers(text), reachBackAllowed, !proxy.hasSelection,
              let fix = ac(engine.rawKeystrokes),
              let original = autoCorrectOriginal(fix, context: proxy.contextBeforeInput) else { return nil }
        let shown = engine.composed
        engine.reset()
        engine.forgetLastCommit()
        engine.noteExternalWord(english: false)
        TouchLog.write("autocorrect: -\(shown.count) +\(fix.count)")
        for _ in 0..<shown.count { proxy.deleteBackward() }
        proxy.insertText(fix)
        proxy.insertText(text)
        lastWasOwnBoundary = text.last.map { !$0.isLetter } ?? false
        expandedAtLastBoundary = true
        expansionUndo = ExpansionUndo(typed: original, expansion: fix, boundary: text, autoCorrect: true)
        return fix
    }

    /// Điều kiện theo CHỮ TRÊN MÀN HÌNH để thay từ đang soạn bằng `fix` ở ranh giới: không dính
    /// URL/email/số (ShortcutTable.isGlued), chữ trước con trỏ đúng là từ đang soạn, chữ hoa hợp lệ
    /// (AutoCorrect.caseAllows), `fix` khác chữ ranh giới sẽ chốt. Trả chữ đó (chữ gốc) hoặc nil.
    private func autoCorrectOriginal(_ fix: String, context: String?) -> String? {
        let raw = engine.rawKeystrokes, shown = engine.composed
        guard let ctx = context, !ShortcutTable.isGlued(word: shown, context: ctx),
              CompositionSync.canDelete(shown.count, expected: shown, context: { ctx }),
              AutoCorrect.caseAllows(raw, sentenceStart: AutoCorrect.isSentenceStart(String(ctx.dropLast(shown.count))))
        else { return nil }
        let original = engine.peekCommitText(autoRestore: settings.autoRestore)
        return fix == original ? nil : original
    }

    /// ONBOARDING-SPEC §8 — dấu cách lúc này có thay từ đang soạn bằng `fix` không (cùng điều kiện
    /// boundary → tryAutoCorrect, không đổi gì). Thanh gợi ý chỉ tô nền ô `fix` khi khác nil; trả chữ
    /// gốc (ô ngoặc kép). Không xét công tắc tự sửa (tắt: ô tô nền chỉ là gợi ý).
    func autoCorrectPreview(_ fix: String, context: String?) -> String? {
        guard !engine.isEmpty, !englishMode, !emailActive, !passthrough, swipeOpen == nil,
              reachBackAllowed, shortcutPreview == nil else { return nil }
        return autoCorrectOriginal(fix, context: context)
    }

    /// Chip "↩︎ chữ gốc": trả lại chữ gốc của lần tự sửa vừa rồi (như ⌫ ngay sau).
    func revertAutoCorrect(proxy: TextProxyLike) -> Bool {
        guard let u = expansionUndo, u.autoCorrect else { return false }
        expansionUndo = nil
        return undoExpansion(u, proxy: proxy)
    }

    /// ⌫ ngay sau khi bung: màn hình phải kết thúc ĐÚNG bằng nội dung + ranh giới (đọc
    /// context, nil ⇒ không làm) → thay bằng chữ đã gõ + ranh giới. false ⇒ ⌫ thường.
    private func undoExpansion(_ u: ExpansionUndo, proxy: TextProxyLike) -> Bool {
        guard !proxy.isSecure, !passthrough, !proxy.hasSelection,
              let ctx = proxy.contextBeforeInput,
              u.retro ? Self.retroMatches(u.expansion, ctx) : ctx.hasSuffix(u.expansion + u.boundary) else {
            TouchLog.write("shortcut undo: context lệch → ⌫ thường")
            return false
        }
        for _ in 0..<(u.expansion.count + u.boundary.count) { proxy.deleteBackward() }
        proxy.insertText(u.typed + u.boundary)
        engine.reset()
        engine.forgetLastCommit()
        swipeOpen = nil
        enWord = ""
        lastWasOwnBoundary = u.boundary.last.map { !$0.isLetter } ?? false
        TouchLog.write("shortcut undo: -\(u.expansion.count) +\(u.typed.count)")
        if u.autoCorrect { revertedAutoCorrect = u.typed }
        if u.retro {
            engine.resetContext()          // màn hình lại là chữ Việt cũ: lịch sử engine không còn khớp
            lastWasOwnBoundary = u.typed.last.map { !$0.isLetter } ?? false
            revertedRetro = true
        }
        return true
    }

    /// Nội dung sẽ bung nếu gõ ranh giới ngay bây giờ (thanh gợi ý hiện trước). Chỉ khoá chữ.
    var shortcutPreview: String? {
        guard settings.shortcutsEnabled, shortcutsAllowed, !passthrough, !emailField, swipeOpen == nil,
              !typedEmpty, !shortcutTable.isEmpty else { return nil }
        return shortcutTable.wordExpansion(composed: typedWord, raw: typedRaw)
    }

    /// Từ đang gõ tay (engine, hoặc nguyên văn ở chế độ Tiếng Anh) — cho gõ tắt.
    private var typedEmpty: Bool { englishMode ? enWord.isEmpty : engine.isEmpty }
    private var typedWord: String { englishMode ? enWord : engine.composed }
    private var typedRaw: String { englishMode ? enWord : engine.rawKeystrokes }

    // MARK: - Sửa dấu từ đã gõ xong (như macOS: reopenLastCommit + seed)

    /// ⌫ ngay sau ký tự ranh giới vừa chốt một từ: xoá ranh giới (luôn — đó là việc
    /// của ⌫) và nạp lại từ vào engine để gõ tiếp dấu ("tháy" ␣ ⌫ a → "thấy").
    /// Chỉ khi màn hình XÁC NHẬN: context trước con trỏ = …từ + 1 ký tự không phải chữ,
    /// khớp ĐÚNG từng scalar (NFD / host tự sửa chữ ⇒ lệch ⇒ bỏ). Context nil, có vùng
    /// chọn (kể cả inline autocomplete của omnibox), ô email ⇒ quên snapshot, ⌫ thường. Snapshot tiêu thụ 1 lần. Từ bị
    /// auto-restore ("google") engine không capture → không bao giờ tới đây, nên luồng
    /// backspace-undo (restoreUndo) của controller giữ nguyên.
    private func reopenLastCommit(proxy: TextProxyLike) -> Bool {
        guard settings.reEditWord, canReopen, !proxy.hasSelection,
              let ctx = proxy.contextBeforeInput,
              let boundaryChar = ctx.last, !boundaryChar.isLetter else {
            engine.forgetLastCommit()
            proxy.deleteBackward()
            return false
        }
        guard let word = engine.reopenLastCommit() else {     // setting đổi → replay lệch
            proxy.deleteBackward()
            return false
        }
        guard CompositionSync.endsWithWord(String(ctx.dropLast()), word) else {
            engine.reset()
            TouchLog.write("reopen: context lệch → bỏ")
            proxy.deleteBackward()
            return false
        }
        proxy.deleteBackward()
        // Đọc lại sau khi xoá: host nuốt/đổi lệnh xoá → không giữ từ (nil = không biết,
        // đã xác minh trước khi xoá nên giữ).
        if let after = proxy.contextBeforeInput, !CompositionSync.endsWithWord(after, word) {
            engine.reset()
            TouchLog.write("reopen: context sau xoá lệch → bỏ")
            return false
        }
        editingFinishedWord = true
        return true
    }

    /// Phím được nạp lại từ trước con trỏ: CHỈ dấu thanh / huỷ dấu / móc (s f r x j
    /// z w). KHÔNG a e o d (user 26/09/2026): "to" + o phải ra "too" chứ không "tô" —
    /// mũ/đ chỉ sửa được qua ⌫ mở lại từ. Lọc rẻ trước khi trả giá đọc context.
    /// VNI: tương ứng 1–5 (thanh), 0 (huỷ thanh), 7/8 (móc/trăng ≙ w) — KHÔNG 6/9
    /// (mũ/đ ≙ a e o d). Chữ cái trong VNI luôn là chữ thường, không bao giờ sửa từ.
    static func isReEditKey(_ ch: Character, vni: Bool = false) -> Bool {
        if vni {
            switch ch {
            case "1", "2", "3", "4", "5", "0", "7", "8": return true
            default: return false
            }
        }
        switch ch {
        case "s", "f", "r", "x", "j", "z", "w",
             "S", "F", "R", "X", "J", "Z", "W": return true
        default: return false
        }
    }
    private func isReEditKey(_ ch: Character) -> Bool { Self.isReEditKey(ch, vni: settings.vniMode) }

    /// Phím `d` (Telex) khi con trỏ DÍNH LIỀN sau một từ bắt đầu bằng d: gạch đ cho từ đó
    /// ("dùng|" + d → "đùng", issue #169 — từ vuốt ra "dùng" mà muốn "đúng"). Không ai mở
    /// từ mới dính vào từ trước, nên khác a/e/o ("to" + o = "too") phím này gần như chắc
    /// chắn là sửa; sau dấu cách (kể cả dấu cách treo sau từ vuốt) `d` vẫn mở từ mới
    /// ("dùng đi"). Từ không bắt đầu bằng d ⇒ false, `d` nối chữ như cũ.
    private func isStrokeReEdit(_ ch: Character, proxy: TextProxyLike) -> Bool {
        guard !settings.vniMode, ch == "d" || ch == "D",
              let ctx = proxy.contextBeforeInput,
              let word = CompositionSync.trailingWord(ctx) else { return false }
        return Self.strokeReEditApplies(to: word)
    }
    static func strokeReEditApplies(to word: String) -> Bool {
        word.count >= 2 && (word.first == "d" || word.first == "D")
    }

    /// `d` dính liền sau từ bắt đầu bằng d (isStrokeReEdit): cùng điều kiện vị trí như
    /// seedWordBeforeCaret (không vùng chọn, không ở giữa từ) rồi gạch đ bằng `strokeWord`.
    private func strokeWordBeforeCaret(proxy: TextProxyLike) -> Bool {
        guard !proxy.hasSelection,
              let ctx = proxy.contextBeforeInput,
              let word = CompositionSync.trailingWord(ctx) else { return false }
        if let after = proxy.contextAfterInput, let next = after.first, next.isLetter {
            return false                               // đang ở giữa từ
        }
        return strokeWord(word, proxy: proxy)
    }

    /// Đổi chữ d đầu của `word` (đang nằm ngay trước con trỏ) thành đ và để engine soạn
    /// tiếp từ đó ("dùng" → "đùng", gõ tiếp s → "đúng"). KHÔNG đi qua engine.feed("d"):
    /// khi "Bỏ dấu tự do" tắt, `d` cuối từ không với ngược về chữ d đầu nên feed chỉ nối
    /// chữ ("dùngd" — người báo #169 vẫn gặp ở 1.3.13). Seed thẳng dạng có đ thì chế độ nào
    /// cũng như nhau. Dạng có đ không seed được (không phải âm tiết gõ được) hoặc màn hình
    /// lệch ⇒ false, engine giữ nguyên, caller nối chữ như cũ.
    private func strokeWord(_ word: String, proxy: TextProxyLike) -> Bool {
        guard let first = word.first, first == "d" || first == "D" else { return false }
        let target = (first == "d" ? "đ" : "Đ") + word.dropFirst()
        let snapshot = engine
        guard engine.seed(target),
              CompositionSync.canDelete(word.count, expected: word,
                                        context: { proxy.contextBeforeInput }) else {
            engine = snapshot
            return false
        }
        TouchLog.edit(bs: word.count, insertLen: target.count, insert: target)
        for _ in 0..<word.count { proxy.deleteBackward() }
        proxy.insertText(target)
        editingFinishedWord = true
        return true
    }

    /// `w` khi SỬA một từ đã gõ xong mà "Bỏ dấu tự do" tắt: engine chặt không với `w` qua
    /// phụ âm cuối ("đùng" + w → "đùngw"), nhưng phím dính vào từ đã xong là để sửa — tính
    /// kết quả bằng một engine thử có bật bỏ dấu tự do ("đừng"), rồi seed thẳng dạng đó
    /// (dạng gõ liền kề nên engine chặt soạn tiếp được: + s → "đứng"). Chỉ nhận khi phím
    /// biến đổi từ mà không đổi độ dài (đúng là thêm móc/trăng, không nối chữ, không khôi
    /// phục phím thô). Gõ liền mạch không qua đây.
    private func freeMarkWord(_ word: String, key ch: Character, proxy: TextProxyLike) -> Bool {
        guard !settings.freeMarking, !settings.vniMode, ch == "w" || ch == "W" else { return false }
        var trial = engine
        trial.freeMarking = true
        guard trial.seed(word) else { return false }
        _ = trial.feed(ch)
        let target = trial.composed
        guard target != word, target.count == word.count else { return false }
        let snapshot = engine
        guard engine.seed(target),
              CompositionSync.canDelete(word.count, expected: word,
                                        context: { proxy.contextBeforeInput }) else {
            engine = snapshot
            return false
        }
        TouchLog.edit(bs: word.count, insertLen: target.count, insert: target)
        for _ in 0..<word.count { proxy.deleteBackward() }
        proxy.insertText(target)
        editingFinishedWord = true
        return true
    }
    private func freeMarkWordBeforeCaret(key ch: Character, proxy: TextProxyLike) -> Bool {
        guard !settings.freeMarking, ch == "w" || ch == "W", !proxy.hasSelection,
              let ctx = proxy.contextBeforeInput,
              let word = CompositionSync.trailingWord(ctx) else { return false }
        if let after = proxy.contextAfterInput, let next = after.first, next.isLetter {
            return false                               // đang ở giữa từ
        }
        return freeMarkWord(word, key: ch, proxy: proxy)
    }

    /// Engine rỗng, con trỏ đứng NGAY SAU một từ (không ở giữa từ, không vùng chọn):
    /// seed engine bằng từ đó rồi feed `ch`. Chỉ áp khi seed round-trip VÀ phím thật sự
    /// biến đổi từ ("viet" + j → "việt"); không thì engine reset, trả false → caller
    /// chèn literal như cũ. Context trước nil ⇒ không áp. Context SAU nil được coi là
    /// hết văn bản (host iOS hay trả nil thay cho "" ở cuối ô).
    private func seedWordBeforeCaret(then ch: Character, proxy: TextProxyLike) -> Bool {
        guard !proxy.hasSelection,
              let ctx = proxy.contextBeforeInput,
              let word = CompositionSync.trailingWord(ctx) else { return false }
        if let after = proxy.contextAfterInput, let next = after.first, next.isLetter {
            return false                               // đang ở giữa từ
        }
        guard engine.seed(word) else { return false }  // seed tự reset khi không khớp
        let action = engine.feed(ch)
        guard case .replace(let bs, let insert) = action, bs > 0,
              engine.composed != word + String(ch) else {
            engine.reset()
            return false
        }
        guard safeToApply(action, expected: word, proxy: proxy) else {
            engine.reset()
            return false
        }
        TouchLog.edit(bs: bs, insertLen: insert.count, insert: insert)
        for _ in 0..<bs { proxy.deleteBackward() }
        if !insert.isEmpty { proxy.insertText(insert) }
        editingFinishedWord = true
        return true
    }

    /// Engine rỗng mà con trỏ đứng NGAY SAU một mẩu từ (⌫ lùi vào chữ cũ, host gán lại
    /// text làm mất composition, con trỏ vừa dời tới cuối từ…): phím chữ này là phím
    /// TIẾP của từ đó, không phải đầu từ mới. Seed engine bằng mẩu từ rồi feed `ch` —
    /// CHỈ khi kết quả là nối thêm đúng một ký tự (không biến đổi chữ đã có: "to" + o
    /// vẫn ra "too" như quyết định 26/09/2026; mũ/dấu qua đường seedWordBeforeCaret).
    /// Không làm vậy thì "ph|" + a i r thành từ riêng "ải" (raw "air") và lúc chốt bị
    /// tự khôi phục tiếng Anh → "phair" (video người dùng Messenger 27/09/2026).
    private func continueWordBeforeCaret(_ ch: Character, proxy: TextProxyLike) -> Bool {
        guard ch.isLetter, !proxy.hasSelection,
              let ctx = proxy.contextBeforeInput,
              let word = CompositionSync.trailingWord(ctx) else { return false }
        if let after = proxy.contextAfterInput, let next = after.first, next.isLetter {
            return false                               // đang ở giữa từ
        }
        let snapshot = engine
        guard engine.seed(word) else { engine = snapshot; return false }
        let action = engine.feed(ch)
        guard engine.composed == word + String(ch),
              safeToApply(action, expected: word, proxy: proxy) else {
            engine = snapshot
            return false
        }
        apply(action, literal: String(ch), proxy: proxy)
        if case .replace(let bs, let insert) = action {
            letterUndo = LetterUndo(engine: snapshot, removed: String(word.suffix(bs)),
                                    inserted: insert, ownBoundary: false)
        } else {
            letterUndo = LetterUndo(engine: snapshot, removed: "", inserted: String(ch), ownBoundary: false)
        }
        return true
    }

    /// Ký tự ranh giới vừa chèn đã bị controller viết lại (double-space → ". ") —
    /// ⌫ kế tiếp không còn xoá đúng ký tự đã chốt từ.
    func forgetLastCommit() { engine.forgetLastCommit(); lastWasOwnBoundary = false; expansionUndo = nil }

    /// Field switch / selection moved / keyboard dismissed → forget the word.
    /// Cũng xoá ngữ cảnh tiếng Anh: đổi ô / con trỏ nhảy → từ trước không còn là
    /// "từ ngay trước" nữa (macOS làm y hệt khi activateServer / đổi field).
    func reset() {
        engine.reset(); engine.resetContext(); lastWasOwnBoundary = false; letterUndo = nil
        editingFinishedWord = false
        swipeOpen = nil; expansionUndo = nil; enWord = ""
        email.invalidate()
    }

    var isComposing: Bool { !engine.isEmpty || swipeOpen?.literal != nil || !enWord.isEmpty }

    /// Current word for the suggestion bar: on-screen composed form + raw keys. Từ tiếng
    /// Anh vuốt ra (nguyên văn, engine trống) cũng tính là từ đang mở.
    var composedWord: String { swipeOpen?.literal ?? (englishMode ? enWord : engine.composed) }
    var rawWord: String { swipeOpen?.literal ?? (englishMode ? enWord : engine.rawKeystrokes) }
    /// Từ đang mở là từ tiếng Anh nguyên văn vừa vuốt.
    var isLiteralSwipeWordOpen: Bool { swipeOpen?.literal != nil }
    var autoFixAdjacent: Bool { settings.autoFixAdjacent }
    /// Cache kết quả AdjacentKeyFixer theo raw — sống cùng bridge (cùng setting).
    let adjacentFixCache = AdjacentKeyFixer.Cache()

    /// Dạng hiển thị engine SẼ ra cho chuỗi phím `raw`, với đúng setting hiện tại —
    /// engine scratch riêng, không đụng từ đang gõ (AdjacentKeyFixer). Chỉ đọc
    /// `settings` (let) → gọi được từ hàng đợi gợi ý nền.
    func composeTrial(_ raw: String) -> String {
        var e = TelexEngine()
        e.freeMarking = settings.freeMarking
        e.simpleTelex = settings.simpleTelex
        e.liveSpellCheck = settings.liveSpellCheck
        e.eagerEnglishRestore = settings.autoRestore
        e.quickTelex = settings.quickTelex
        e.modernTone = settings.modernTone
        e.teencode = settings.teencode
        e.autoCircumflex = settings.autoCircumflex
        e.vniMode = settings.vniMode
        for ch in raw { _ = e.feed(ch) }
        return e.composed
    }

    /// Từ mà boundary SẼ chốt (auto-restore tính sẵn) — peek non-mutating trực
    /// tiếp trên engine. KHÔNG copy struct: bản copy cũ kích hoạt COW copy ~10
    /// buffer cố định mỗi phím khi commitText mutate (reset + scratch).
    var predictedCommit: String {
        swipeOpen?.literal ?? (englishMode ? enWord : engine.peekCommitText(autoRestore: settings.autoRestore))
    }

    /// Fail-safe trước khi xoá: action định xoá `bs` ký tự của `expected` (từ đang gõ
    /// lúc trước phím) — chỉ cho khi chữ trước con trỏ đúng là `expected`.
    private func safeToApply(_ action: TelexAction, expected: String, proxy: TextProxyLike) -> Bool {
        guard case .replace(let bs, _) = action, bs > 0 else { return true }
        let ok = CompositionSync.canDelete(bs, expected: expected,
                                           context: { proxy.contextBeforeInput })
        if !ok { TouchLog.write("failsafe: bs=\(bs) expectedLen=\(expected.count) → reset") }
        return ok
    }

    private func apply(_ action: TelexAction, literal: String, proxy: TextProxyLike) {
        switch action {
        case .replace(let bs, let insert):
            TouchLog.edit(bs: bs, insertLen: insert.count, insert: insert)
            for _ in 0..<bs { proxy.deleteBackward() }
            if !insert.isEmpty { proxy.insertText(insert) }
        case .passthrough:
            TouchLog.edit(bs: 0, insertLen: literal.count, insert: literal)
            if !literal.isEmpty { proxy.insertText(literal) }
        case .none:
            break
        }
    }
}

/// Thay thế văn bản iOS → gõ tắt, phần nối controller ↔ bridge (test được không cần UIKit):
/// công tắc tắt (hoặc Gõ tắt tắt) ⇒ KHÔNG hỏi UILexicon; bật ⇒ hỏi một lần mỗi phiên
/// (SupplementaryLexiconCache), lọc (SystemTextReplacement.entries), gộp vào bridge hiện tại.
final class SystemTextReplacementLoader {
    let cache: SupplementaryLexiconCache
    private(set) var entries: [String: String]?

    init(cache: SupplementaryLexiconCache) { self.cache = cache }

    static func wanted(_ s: KeyboardSettings) -> Bool { s.shortcutsEnabled && s.useSystemTextReplacement }

    /// `bridge` đọc lúc kết quả về (controller có thể đã dựng bridge mới). `loaded` chỉ gọi
    /// ở lần lọc đầu (ghi snapshot cho app). Trả false khi không cần nạp.
    @discardableResult
    func load(settings: KeyboardSettings, bridge: @escaping () -> EngineBridge?,
              loaded: @escaping ([String: String]) -> Void = { _ in }) -> Bool {
        guard Self.wanted(settings) else { return false }
        if let entries { bridge()?.setSystemReplacements(entries); return true }
        cache.get { [weak self] pairs in
            guard let self else { return }
            let first = self.entries == nil
            let e = self.entries ?? SystemTextReplacement.entries(from: pairs)
            self.entries = e
            bridge()?.setSystemReplacements(e)
            if first { loaded(e) }
        }
        return true
    }
}
