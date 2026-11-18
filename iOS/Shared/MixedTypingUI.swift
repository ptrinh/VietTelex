// Nhóm "Gõ lẫn tiếng Anh" (docs/ONBOARDING-SPEC.md §4, docs/SETTINGS-CLEANUP-SPEC.md §1): nhóm
// thu gọn được trong tab Kiểu Gõ (mặc định thu gọn). Cấp 1 chỉ có bộ chọn hồ sơ, vuốt phím cách
// và Từ điển cá nhân; các công tắc nhận diện tiếng Anh nằm ở trang con "Nâng cao". "Vuốt từ tiếng
// Anh" đã về trang Gõ vuốt (tìm kiếm: SettingsIndex). Phần thuần (không SwiftUI) để test được:
// danh mục mục, key lưu (KHÔNG đổi — sao lưu/khôi phục giữ nguyên), từ khoá tìm kiếm, chỗ đặt, lý
// do làm mờ mục phụ thuộc. Song sinh Android ui/MixedTyping.kt.
import Foundation

enum MixedTypingItem: String, CaseIterable, Hashable {
    /// Dòng tiêu đề nhóm (bấm để mở/thu gọn).
    case section
    // Cấp 1 của nhóm
    case spaceSwipeLanguage, userDictionary
    // Trang con "Nâng cao"
    case autoRestore, contextualEnglish, retroEnglish, englishByFrequency

    /// Mục nằm ở cấp 1 của nhóm hay trong trang con "Nâng cao".
    enum Placement: CaseIterable { case top, advanced }

    var placement: Placement {
        switch self {
        case .section, .spaceSwipeLanguage, .userDictionary: return .top
        case .autoRestore, .contextualEnglish, .retroEnglish, .englishByFrequency: return .advanced
        }
    }

    /// Tên gốc tiếng Việt = khoá L10n = chữ trên dòng cài đặt.
    var viTitle: String {
        switch self {
        case .section: return MixedTypingUI.titleKey
        case .autoRestore: return LK("Tự khôi phục từ tiếng Anh")
        case .contextualEnglish: return LK("Quyết định theo ngữ cảnh")
        case .retroEnglish: return LK("Tự sửa từ phía trước")
        case .englishByFrequency: return LK("Đoán từ trùng theo tần suất")
        case .spaceSwipeLanguage: return LK("Vuốt phím cách đổi Tiếng Việt / Tiếng Anh")
        case .userDictionary: return LK("Từ điển cá nhân")
        }
    }

    /// Từ khoá tìm kiếm thêm (Việt + Anh) ngoài tên.
    var keywords: String {
        switch self {
        case .section: return "mixed trộn song ngữ bilingual tiếng anh english việt anh"
        case .autoRestore: return "english google restore khôi phục nâng cao advanced"
        case .contextualEnglish: return "context ngữ cảnh english he is nâng cao advanced"
        case .retroEnglish: return "sửa ngược retro english thử nghiệm experimental nâng cao advanced"
        case .englishByFrequency: return "tần suất frequency his hí từ trùng collision thử nghiệm experimental nâng cao advanced"
        case .spaceSwipeLanguage: return "space ngôn ngữ english language vuốt phím cách tiếng việt tiếng anh"
        case .userDictionary: return "dictionary tên riêng thuật ngữ từ tiếng anh"
        }
    }

    /// Key App Group (KHÔNG đổi khi chuyển chỗ) — nil với dòng không phải công tắc.
    var storageKey: String? {
        switch self {
        case .section, .userDictionary: return nil
        case .autoRestore: return "autoRestore"
        case .contextualEnglish: return "contextualEnglish"
        case .retroEnglish: return RetroEnglishUI.autoKey
        case .englishByFrequency: return RetroEnglishUI.frequencyKey
        case .spaceSwipeLanguage: return "spaceSwipeLanguage"
        }
    }
}

enum MixedTypingUI {
    /// Tên nhóm — cùng tên/thứ tự trên iOS và Android.
    static let titleKey = LK("Gõ lẫn tiếng Anh")
    /// Dòng "Nâng cao" của nhóm + dòng phụ liệt kê những gì bên trong (SETTINGS-CLEANUP-SPEC §1).
    static let advancedTitleKey = LK("Nâng cao")
    static let advancedSubtitleKey = LK("Khôi phục từ tiếng Anh, ngữ cảnh, khi trùng từ, sửa từ phía trước…")

    /// Thứ tự dòng ở trang con "Nâng cao".
    static let advancedItems: [MixedTypingItem] = MixedTypingItem.allCases.filter { $0.placement == .advanced }

    // MARK: Chọn VNI ⇒ ẩn nhóm (SETTINGS-CLEANUP-SPEC §1, 06/11/2026)

    /// Dòng duy nhất thay cho bộ chọn hồ sơ + "Nâng cao" khi chọn VNI (cùng chữ Android/macOS).
    static let vniNoteKey = LK("Gõ VNI không làm đổi từ tiếng Anh nên không cần chỉnh phần này.")

    /// VNI đặt dấu bằng phím số nên từ tiếng Anh gõ ra nguyên vẹn: mọi công tắc nhận diện tiếng Anh
    /// vô tác dụng ⇒ ẩn bộ chọn hồ sơ + "Nâng cao" (ngoại lệ có chủ đích của §0.4). Chỉ đổi hiển thị:
    /// key/giá trị giữ nguyên, đổi lại Telex thấy y như cũ.
    static func groupHidden(vniMode: Bool) -> Bool { vniMode }

    /// Các dòng cấp 1 của nhóm khi mở (theo thứ tự hiện).
    enum Row: Hashable { case profilePicker, vniNote, spaceSwipeLanguage, userDictionary, advanced }

    /// Vuốt phím cách (cách chuyển ngôn ngữ) và Từ điển cá nhân (từ đã học cho thanh gợi ý, tên
    /// riêng — không chỉ phục vụ khôi phục tiếng Anh) luôn hiện.
    static func rows(vniMode: Bool) -> [Row] {
        groupHidden(vniMode: vniMode)
            ? [.vniNote, .spaceSwipeLanguage, .userDictionary]
            : [.profilePicker, .spaceSwipeLanguage, .userDictionary, .advanced]
    }

    /// Mục có đang hiện (cấp 1 hoặc trong "Nâng cao") hay bị ẩn vì chọn VNI.
    static func isVisible(_ item: MixedTypingItem, vniMode: Bool) -> Bool {
        !(groupHidden(vniMode: vniMode) && item.placement == .advanced)
    }

    /// Dòng của trang con "Nâng cao" theo thứ tự hiện (SETTINGS-CLEANUP-SPEC §0.4, §6 — 06/11/2026):
    /// hai mục thử nghiệm nằm NGAY DƯỚI "Quyết định theo ngữ cảnh" (cùng nhóm) ⇒ ẨN khi nó tắt
    /// (engine retroactiveEnglishActive = retro && ngữ cảnh), bật lại hiện ngay. VNI ⇒ cả trang chỉ
    /// còn dòng ghi chú (groupHidden). Chỉ hiển thị: key/giá trị giữ nguyên.
    static func advancedRows(contextualEnglish: Bool, vniMode: Bool) -> [MixedTypingItem] {
        if groupHidden(vniMode: vniMode) { return [] }
        return contextualEnglish ? advancedItems : advancedItems.filter { !$0.dependsOnContext }
    }
}

extension MixedTypingItem {
    /// Chỉ có tác dụng khi "Quyết định theo ngữ cảnh" bật.
    var dependsOnContext: Bool { self == .retroEnglish || self == .englishByFrequency }
}

/// Tuỳ chọn chỉ có tác dụng ở Telex. Ở TRANG KHÁC với bộ chọn Telex/VNI ⇒ làm mờ kèm lý do này;
/// ngay dưới bộ chọn (Kiểu gõ › Nâng cao) ⇒ ẩn (SettingsDeps.typingAdvancedRows).
enum TelexOnly {
    static let reasonKey = LK("Chỉ áp dụng cho Telex")
}

/// Ẩn / làm mờ theo mục cha (SETTINGS-CLEANUP-SPEC §0.4, bảng §6 — 06/11/2026). Mục con cùng nhóm,
/// ngay dưới mục cha ⇒ ẨN khi cha làm nó vô tác dụng; mục cha ở trang/nhóm khác ⇒ làm mờ + lý do.
/// Chỉ hiển thị: không đổi key, không đổi giá trị đã lưu, engine không đổi. Song sinh macOS
/// SettingsDeps (App/Sources/SettingsDeps.swift).
enum SettingsDeps {
    static let needsSuggestionsKey = LK("Cần bật Thanh gợi ý")

    // MARK: Kiểu gõ › Nâng cao (dưới bộ chọn Telex/VNI)

    enum TypingAdvancedRow: CaseIterable, Hashable { case simpleTelex, freeMarking, quickTelex, modernTone, teencode, autoCircumflex }

    /// VNI ⇒ ẩn Telex đơn giản, Bỏ dấu tự do, Gõ nhanh (chỉ chạy trong parseStep của Telex).
    /// Teencode chạy cả ở VNI (bộ kiểm âm tiết) ⇒ luôn hiện; Bỏ dấu kiểu mới áp dụng cả hai.
    /// Tự thêm dấu mũ là bước hiển thị (render), không phụ thuộc kiểu gõ ⇒ luôn hiện.
    static func typingAdvancedRows(vniMode: Bool) -> [TypingAdvancedRow] {
        vniMode ? [.modernTone, .teencode, .autoCircumflex] : TypingAdvancedRow.allCases
    }

    // MARK: Gõ vuốt

    enum SwipeRow: CaseIterable, Hashable { case swipeEnglish, neuralModel, trailEffect, trailSound, practice }

    /// Tắt Gõ vuốt ⇒ ẩn mọi dòng bên dưới công tắc (cùng trang): Vuốt từ tiếng Anh, Mô hình neural +
    /// ghi công, Hiệu ứng nét vuốt, Âm thanh nét vuốt, Luyện vuốt.
    static func swipeRows(swipeTyping: Bool) -> [SwipeRow] {
        swipeTyping ? SwipeRow.allCases : []
    }

    // MARK: Sửa lỗi & gợi ý (trang khác với bộ chọn Telex/VNI)

    /// "Chọn phím thông minh" và "Tự sửa từ gõ sai": bàn phím tắt ngầm ở VNI
    /// (KeyboardViewController autoCorrectSetting, TelexKeyPrior.forTyping) ⇒ mờ + lý do.
    static func telexOnlyReason(vniMode: Bool) -> String? { vniMode ? TelexOnly.reasonKey : nil }

    /// "Gợi ý sửa lỗi chạm trượt" hiện trên thanh gợi ý nhưng nằm ở nhóm "Chạm trượt" ⇒ mờ + lý do.
    static func autoFixAdjacentReason(showSuggestions: Bool) -> String? {
        showSuggestions ? nil : needsSuggestionsKey
    }
}

/// So khớp ô tìm cài đặt: không phân biệt hoa/thường và dấu ("tan suat" khớp "tần suất"), mọi
/// từ của câu tìm phải có trong tên Việt + tên Anh + từ khoá.
enum SettingsSearch {
    static func fold(_ s: String) -> String {
        s.replacingOccurrences(of: "đ", with: "d").replacingOccurrences(of: "Đ", with: "D")
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    static func words(_ query: String) -> [String] {
        fold(query).split(separator: " ").map(String.init)
    }

    static func matches(viTitle: String, keywords: String, words: [String]) -> Bool {
        let hay = fold(viTitle + " " + (L10n.en[viTitle] ?? "") + " " + keywords)
        return !words.isEmpty && words.allSatisfy { hay.contains($0) }
    }
}
