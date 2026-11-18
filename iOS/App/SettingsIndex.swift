// Cấu trúc cài đặt (docs/SETTINGS-CLEANUP-SPEC.md §3–§4) — phần THUẦN (không SwiftUI) để test:
// các trang của tab Tính Năng, nhãn chung (bảng §3), chỉ mục ô tìm cài đặt và chỗ mỗi mục nằm.
// Giao diện ở FeaturePages.swift (icon, màu, trang đích). KHÔNG đổi key/mặc định: chỉ đổi chỗ
// hiển thị. Song sinh Android ui/FeaturePages.kt.
import Foundation

/// Các trang của tab Tính Năng — cùng thứ tự/tên với Android.
enum FeaturePage: String, CaseIterable, Identifiable {
    case suaLoi, goVuot, goTat, phim, giaoDien, riengTu, nangCao
    var id: String { rawValue }

    var title: String { L(viTitle) }
    /// Tên gốc tiếng Việt — khoá tra L10n và so khớp tìm kiếm.
    var viTitle: String {
        switch self {
        case .suaLoi: return LK("Sửa lỗi & gợi ý")
        case .goVuot: return LK("Gõ vuốt")
        case .goTat: return LK("Gõ tắt & mẫu câu")
        case .phim: return LK("Phím & cử chỉ")
        case .giaoDien: return LK("Giao diện")
        case .riengTu: return LK("Riêng tư & sao lưu")
        case .nangCao: return LK("Nâng cao / Gỡ lỗi")
        }
    }
    /// Cả nhóm đang thử nghiệm → nhãn nhỏ ngay trên dòng.
    /// Nhãn cạnh tên trang: Gõ vuốt = "Máy học" (thay "Thử nghiệm", Phil 12/11/2026).
    var badge: String? { self == .goVuot ? L("Máy học") : nil }
    /// Mục tương ứng trong Hướng dẫn sử dụng (docs/hdsd/index.html); nil = không có mục riêng.
    var guideAnchor: String? {
        switch self {
        case .suaLoi: return "goi-y"
        case .goVuot: return "go-vuot"
        case .goTat: return "go-tat"
        case .phim: return "cu-chi"
        case .giaoDien: return "giao-dien"
        case .riengTu: return "sao-luu"
        case .nangCao: return nil
        }
    }

    /// Các nhóm hiển thị theo khối như app Cài đặt; "Nâng cao / Gỡ lỗi" cuối danh sách.
    static let groups: [[FeaturePage]] = [[.suaLoi, .goVuot, .goTat], [.phim, .giaoDien], [.riengTu], [.nangCao]]
}

/// Nhãn dùng chung mọi nền tảng (SETTINGS-CLEANUP-SPEC §3) — giao diện + chỉ mục tìm kiếm đọc từ đây.
enum SettingLabel {
    static let freeMarking = LK("Bỏ dấu tự do")
    static let modernTone = LK("Bỏ dấu kiểu mới (oà, uý)")
    static let reEditWord = LK("Sửa dấu từ đã gõ")
    static let numberChips = LK("Gợi ý số tiền")
    static let autoRestore = LK("Tự khôi phục từ tiếng Anh")
    static let simpleTelex = LK("Telex đơn giản")
    static let quickTelex = LK("Gõ nhanh (Quick Telex)")
    static let teencode = LK("Chính tả teencode")
    static let autoCircumflex = LK("Tự thêm dấu mũ")
    static let autoCapitalize = LK("Tự động viết hoa đầu câu")
    /// Một tên cho mọi cách thêm dấu cả câu (§4).
    static let addTones = LK("Thêm dấu")
    static let swipeEnglish = LK("Vuốt từ tiếng Anh")
    static let feedbackPage = LK("Phản hồi khi chạm")
    /// Trang con "Nâng cao" của mục Kiểu gõ + dòng phụ liệt kê bên trong.
    static let typingAdvanced = LK("Nâng cao")
    static let typingAdvancedSubtitle = LK("Telex đơn giản, bỏ dấu tự do, gõ nhanh, bỏ dấu kiểu mới, teencode…")
}

/// Nơi một mục cài đặt nằm — ô tìm kiếm mở đúng chỗ này.
enum SettingsLocation: Hashable {
    /// Trang Tính Năng.
    case page(FeaturePage)
    /// Tính Năng › Phím & cử chỉ › Phản hồi khi chạm.
    case feedback
    /// Kiểu Gõ › Kiểu gõ › Nâng cao.
    case typingAdvanced
    /// Kiểu Gõ › Gõ lẫn tiếng Anh (cấp 1 của nhóm): đổi tab, mở nhóm, cuộn tới dòng.
    case mixed(MixedTypingItem)
    /// Kiểu Gõ › Gõ lẫn tiếng Anh › Nâng cao.
    case mixedAdvanced(MixedTypingItem)

    /// Khoá L10n của đường dẫn hiện dưới kết quả tìm kiếm (nối bằng " › ").
    var pathKeys: [String] {
        let typing = LK("Kiểu Gõ")
        switch self {
        case .page(let p): return [p.viTitle]
        case .feedback: return [FeaturePage.phim.viTitle, SettingLabel.feedbackPage]
        case .typingAdvanced: return [typing, SettingLabel.typingAdvanced]
        case .mixed: return [typing, MixedTypingUI.titleKey]
        case .mixedAdvanced: return [typing, MixedTypingUI.titleKey, MixedTypingUI.advancedTitleKey]
        }
    }
}

extension SettingsLocation {
    /// Chỗ thật sự mở khi chọn kết quả tìm kiếm: chọn VNI ⇒ mục "Nâng cao" của nhóm Gõ lẫn tiếng
    /// Anh bị ẩn (MixedTypingUI.groupHidden) — vẫn tìm thấy, nhưng mở ra nhóm đang hiện dòng ghi chú.
    func resolved(vniMode: Bool) -> SettingsLocation {
        if case .mixedAdvanced(let m) = self, !MixedTypingUI.isVisible(m, vniMode: vniMode) {
            return .mixed(.section)
        }
        return self
    }
}

/// Một dòng của chỉ mục tìm kiếm.
struct SettingsIndexEntry: Hashable {
    /// Điều kiện hiện (tính năng Plus / chỉ iPhone…) — app đánh giá lúc tìm.
    enum Condition: Hashable { case always, phoneOnly, addTones, aiProofread, textTools, translate, iCloud }

    let viTitle: String
    let keywords: String
    let location: SettingsLocation
    /// Key App Group của công tắc (nil = không phải công tắc / nhiều key).
    var key: String? = nil
    var condition: Condition = .always

    var title: String { L(viTitle) }
    /// Dòng tên trang (kết quả tìm khớp tên trang).
    var isPage: Bool { if case .page(let p) = location { return p.viTitle == viTitle }; return false }
}

enum SettingsIndex {
    static let all: [SettingsIndexEntry] = {
        typealias E = SettingsIndexEntry
        var e: [E] = [
            // Kiểu Gõ › Nâng cao
            E(viTitle: SettingLabel.simpleTelex, keywords: "w ư simple telex nâng cao advanced", location: .typingAdvanced, key: "simpleTelex"),
            E(viTitle: SettingLabel.freeMarking, keywords: "free marking đặt dấu thứ tự nâng cao advanced", location: .typingAdvanced, key: "freeMarking"),
            E(viTitle: SettingLabel.quickTelex, keywords: "quick telex gõ nhanh cc ch gg gi nn ng phụ âm nâng cao advanced", location: .typingAdvanced, key: "quickTelex"),
            E(viTitle: SettingLabel.modernTone, keywords: "hoà hòa thuý thúy kiểu mới kiểu cũ modern tone nâng cao advanced", location: .typingAdvanced, key: "modernTone"),
            E(viTitle: SettingLabel.teencode, keywords: "teencode chat wá zui nâng cao advanced", location: .typingAdvanced, key: "teencode"),
            E(viTitle: SettingLabel.autoCircumflex, keywords: "dấu mũ mũ circumflex hat việt vietj bệnh tự thêm nâng cao advanced", location: .typingAdvanced, key: "autoCircumflex"),
            // Sửa lỗi & gợi ý
            E(viTitle: LK("Kiểm tra chính tả khi gõ"), keywords: "spell check", location: .page(.suaLoi), key: "liveSpellCheck"),
            E(viTitle: SettingLabel.reEditWord, keywords: "sửa dấu con trỏ backspace", location: .page(.suaLoi), key: "reEditWord"),
            E(viTitle: LK("Chọn phím thông minh"), keywords: "chạm trượt smart touch thử nghiệm", location: .page(.suaLoi), key: "smartTouch"),
            E(viTitle: LK("Tự sửa từ gõ sai"), keywords: "autocorrect sửa lỗi chạm trượt thử nghiệm", location: .page(.suaLoi), key: "autoCorrect"),
            E(viTitle: LK("Gợi ý sửa lỗi chạm trượt"), keywords: "chạm trượt phím bên cạnh adjacent typo gợi ý", location: .page(.suaLoi), key: "autoFixAdjacent"),
            E(viTitle: LK("Thanh gợi ý"), keywords: "suggestion học từ", location: .page(.suaLoi), key: "showSuggestions"),
            E(viTitle: LK("Nút ẩn bàn phím"), keywords: "ẩn bàn phím hide dismiss keyboard chevron ⌄ đóng close", location: .page(.suaLoi), key: KeyboardDismissButton.key),
            E(viTitle: LK("Gợi ý emoji"), keywords: "emoji biểu tượng", location: .page(.suaLoi), key: "emojiSuggest"),
            E(viTitle: SettingLabel.numberChips, keywords: "chip số tiền đọc số number money", location: .page(.suaLoi), key: "numberChips"),
            E(viTitle: LK("Hiện kết quả phép tính"), keywords: "tính toán máy tính bằng math calculator", location: .page(.suaLoi), key: "mathResults"),
            E(viTitle: LK("Nút Dán"), keywords: "paste dán clipboard", location: .page(.suaLoi), key: "pasteButton"),
            E(viTitle: LK("Lọc từ nhạy cảm"), keywords: "tục chửi filter", location: .page(.suaLoi), key: "filterSensitive"),
            E(viTitle: LK("Từ điển cá nhân"), keywords: "dictionary tên riêng thuật ngữ", location: .page(.suaLoi)),
            E(viTitle: LK("Xoá từ đã học"), keywords: "xoá học reset", location: .page(.suaLoi)),
            E(viTitle: SettingLabel.addTones, keywords: "chip thêm dấu câu không dấu add tones plus", location: .page(.suaLoi), key: "addTonesChip", condition: .addTones),
            E(viTitle: LK("Sửa lỗi bằng Apple Intelligence"), keywords: "apple intelligence ai trí tuệ nhân tạo sửa lỗi chính tả ngữ pháp proofread grammar spelling từ thay thế đồng nghĩa synonym plus", location: .page(.suaLoi), key: "aiProofread", condition: .aiProofread),
            // Gõ vuốt
            E(viTitle: LK("Gõ vuốt"), keywords: "swipe vuốt", location: .page(.goVuot), key: "swipeTyping"),
            E(viTitle: SettingLabel.swipeEnglish, keywords: "swipe english check mail meeting", location: .page(.goVuot), key: "swipeEnglish"),
            E(viTitle: LK("Hiệu ứng nét vuốt"), keywords: "swipe trail nét vuốt vệt hiệu ứng lửa fire điện electric lightning bút lông brush mực ink cầu vồng rainbow neon bụi sao stardust sparkle pháo hoa firework plasma ảo ảnh kính vạn hoa kaleidoscope tan chảy melt vệt lặp chroma echo phím sáng theo đường key glow thư pháp calligraphy sao chổi comet đom đóm fireflies ma trận matrix rain cánh hoa petals sen lotus theo giao diện theme plus", location: .page(.goVuot)),
            E(viTitle: LK("Âm thanh nét vuốt"), keywords: "swipe sound tiếng âm thanh vuốt bút chì pencil chổi lông brush phấn bảng chalk bút dạ marker roi vụt whip tia sét lightning plasma đũa phép magic wand nốt nhạc theo phím key melody note giai điệu sáo trúc flute sóng biển waves ocean mèo kêu meow cat chim hót birdsong bird âm của bạn your sound custom plus", location: .page(.goVuot)),
            E(viTitle: LK("Mô hình neural gõ vuốt"), keywords: "futo neural swipe", location: .page(.goVuot), key: "swipeFuto"),
            E(viTitle: LK("Luyện vuốt"), keywords: "practice swipe", location: .page(.goVuot)),
            // Gõ tắt & mẫu câu
            E(viTitle: LK("Gõ tắt"), keywords: "shortcut viết tắt", location: .page(.goTat)),
            E(viTitle: LK("Bảng gõ tắt"), keywords: "shortcut yaml import export", location: .page(.goTat)),
            E(viTitle: LK("Mẫu câu"), keywords: "template câu soạn sẵn snippets tắt ẩn tab ☰", location: .page(.goTat), key: "templatesEnabled"),
            E(viTitle: LK("Công cụ văn bản"), keywords: "text tools hoa thường bỏ dấu dịch translate plus", location: .page(.goTat), condition: .textTools),
            E(viTitle: LK("Dịch trên máy"), keywords: "translate dịch ngôn ngữ language gói dịch plus", location: .page(.goTat), condition: .translate),
            // Phím & cử chỉ
            E(viTitle: LK("Hàng phím số"), keywords: "number row số", location: .page(.phim), key: "numberRow"),
            E(viTitle: LK("Hàng số cao bằng hàng chữ"), keywords: "number row height cao số", location: .page(.phim)),
            E(viTitle: LK("Phím cạnh dấu cách"), keywords: "dấu phẩy dấu chấm comma period key next to space", location: .page(.phim)),
            E(viTitle: LK("Về bàn chữ sau ký hiệu"), keywords: "123 ký hiệu symbols bàn số quay về chữ letters tự động luôn tắt auto always", location: .page(.phim)),
            E(viTitle: LK("Cỡ phím chấm và phẩy"), keywords: "larger keys phím lớn dấu phẩy dấu chấm shift xoá comma period backspace bấm nhầm", location: .page(.phim)),
            E(viTitle: LK("Giữ phím ra ký tự đặc biệt"), keywords: "ký hiệu symbol @ # giữ lâu", location: .page(.phim)),
            E(viTitle: LK("Giữ phím hàng trên để ra số"), keywords: "số giữ lâu number", location: .page(.phim), condition: .phoneOnly),
            E(viTitle: LK("Giữ Shift để gõ số và ký hiệu"), keywords: "shift giữ hold số number ký hiệu symbol 123", location: .page(.phim), condition: .phoneOnly),
            E(viTitle: LK("Chế độ một tay"), keywords: "one hand một tay", location: .page(.phim), condition: .phoneOnly),
            E(viTitle: LK("Độ nhạy con trỏ"), keywords: "trackpad con trỏ cursor phím cách space kéo tốc độ nhạy sensitivity speed", location: .page(.phim)),
            E(viTitle: LK("Vuốt phím để sao chép/dán"), keywords: "copy paste cut sao chép dán cắt clipboard vuốt lên swipe", location: .page(.phim)),
            // Phím & cử chỉ › Phản hồi khi chạm
            E(viTitle: SettingLabel.feedbackPage, keywords: "feedback rung âm thanh haptic sound", location: .feedback),
            E(viTitle: LK("Phóng to chữ khi bấm"), keywords: "key preview popup phóng to phím", location: .feedback, key: "keyPreviewEnabled"),
            E(viTitle: LK("Phím sẫm khi bấm"), keywords: "pressed key highlight", location: .feedback, key: "keyPressHighlight"),
            E(viTitle: LK("Rung phím"), keywords: "haptic rung vibrate", location: .feedback, key: "hapticFeedback"),
            E(viTitle: LK("Âm thanh phím"), keywords: "sound click tiếng âm lượng volume kiểu style gỗ cơ máy chữ bong bóng custom", location: .feedback, key: "keySound"),
            E(viTitle: LK("Âm thanh gõ"), keywords: "typing sound key sound style kiểu âm iOS system click hệ thống gỗ wood đá rock pop nước water cổ điển vintage pháo firecracker tết chuông jingle bell giáng sinh piano nốt nhạc đàn tranh dan tranh zither việt nam viet nam bàn phím cơ mechanical máy chữ typewriter bong bóng bubble ding sci-fi scifi bíp beep vũ trụ space trống lân lion drum trung thu mid autumn ma quái spooky boo halloween guitar ghi ta ghi-ta đàn ghi-ta acoustic hợp âm chord búa gỗ mallet bop bíp 8-bit 8 bit chiptune chip blip retro game synth ai bíp ai nhịp club club beat hi-hat hihat kick trống điện tử edm tạ sắt iron plate keng gym bóng bụp ball thump bọt cá fish bloop đá lanh canh ice clink", location: .feedback),
            // Giao diện
            E(viTitle: LK("Theme & ảnh nền"), keywords: "theme màu chủ đề wallpaper hình nền tết tet năm mới lunar new year mai đào giáng sinh noel christmas xmas tuyết snow piano đàn dương cầm sen lotus hoa sen sen việt đàn tranh dan tranh zither việt nam viet nam máy chữ cổ typewriter vintage gaming rgb cầu vồng rainbow vũ trụ space sao star outer space trung thu mid autumn đèn lồng lantern trăng moon valentine tình yêu love tim heart halloween bí ngô pumpkin dơi bat guitar ghi ta ghi-ta đàn ghi-ta acoustic dây đàn strings đập chuột whack a mole xám trung tính neutral grey gray xám ghi gboard pixel 8-bit 8 bit retro game boy máy chơi game điểm ảnh biển sea ocean đại dương sóng wave bọt bubbles cát sand theo giờ time of day bình minh sunrise dawn hoàng hôn sunset ban ngày ban đêm night bầu trời sky ai trí tuệ nhân tạo artificial intelligence cực quang aurora mạng nơ-ron neural neon night club hộp đêm vũ trường disco quả cầu disco đèn rọi spotlight sàn nhảy dance floor led ảo giác psychedelic cầu vồng xoắn ốc swirl gym phòng tập thể hình fitness tạ sắt sàn thép cung hoàng đạo zodiac horoscope chòm sao constellation bạch dương kim ngưu song tử cự giải sư tử xử nữ thiên bình bọ cạp nhân mã ma kết bảo bình song ngư tự hào pride lgbt lgbtq cờ cầu vồng rainbow flag chuyển giới trans song tính bi toàn tính pan đồng tính nữ lesbian phi nhị nguyên non-binary nonbinary bóng đá football soccer sân cỏ pitch sút goal vô địch cổ vũ bể cá aquarium cá fish rong seaweed cà phê sữa đá iced coffee cafe phin ly đá", location: .page(.giaoDien)),
            E(viTitle: LK("Độ trong suốt phím"), keywords: "trong suốt transparent", location: .page(.giaoDien)),
            E(viTitle: LK("Độ trong suốt ký tự"), keywords: "trong suốt transparent chữ", location: .page(.giaoDien)),
            E(viTitle: LK("Tuỳ chỉnh nâng cao"), keywords: "màu chữ màu phím màu nhấn accent color colour bo góc tròn vuông corner radius cỡ chữ size phông font độ đậm weight bold đặt lại reset mặc định giao diện theme", location: .page(.giaoDien)),
            E(viTitle: LK("Dán giao diện"), keywords: "json theme giao diện chép copy paste dán sửa edit nhập import tự tạo custom chia sẻ share", location: .page(.giaoDien)),
            E(viTitle: LK("Bạn đồng hành"), keywords: "bạn đồng hành nhân vật thú cưng mèo gà con cô gái chàng trai buddy keyboard buddy pet character mascot cat chick girl boy nhảy dance ngủ sleep plus mắt ai ai eye quả cầu orb", location: .page(.giaoDien)),
            E(viTitle: LK("Hiệu ứng khi bấm phím"), keywords: "key press effect animation hoạt ảnh trái tim heart bong bóng bubble gợn sóng ripple cánh hoa petal pháo hoa firework nháy sáng flash matrix tia sét lightning emoji theo chữ emoji words hoa đào mai tết blossom lửa combo fire mực loang ink sóng nước water wave tuyết rơi snow giáng sinh christmas sao băng shooting star meteor vũ trụ space plus đèn lồng lantern glow trung thu mid autumn sương ma khói smoke spooky mist halloween rung dây string vibration guitar ghi ta đàn ghi-ta token ai tokens trí tuệ nhân tạo kính vạn hoa kaleidoscope rep reps set hiệp gym beast mode +1 rep chòm sao constellation sao star cung hoàng đạo zodiac cầu vồng rainbow burst tự hào pride sút kick goal bóng đá football cho cá ăn feed the fish bể cá aquarium đá lanh canh ice cà phê coffee", location: .page(.giaoDien)),
            E(viTitle: LK("Đập chuột"), keywords: "đập chuột trò chơi game whack a mole chuột mouse theme giao diện vui fun plus", location: .page(.giaoDien)),
            E(viTitle: LK("Màu nhấn"), keywords: "accent color colour nhập enter return shift tuỳ chỉnh nâng cao", location: .page(.giaoDien)),
            E(viTitle: LK("Màu viền phím"), keywords: "key border outline colour color viền phím màu viền neon tuỳ chỉnh nâng cao", location: .page(.giaoDien)),
            E(viTitle: LK("Khôi phục giao diện gốc"), keywords: "reset mặc định", location: .page(.giaoDien)),
            E(viTitle: LK("Chiều cao hàng phím"), keywords: "height cao thấp stock gốc apple cỡ phím size như bàn phím iphone", location: .page(.giaoDien)),
            E(viTitle: LK("Nâng bàn phím"), keywords: "raise nâng cao đẩy lên khoảng trống dưới padding bottom", location: .page(.giaoDien)),
            E(viTitle: LK("Màu chữ gợi ý"), keywords: "suggestion text color colour xám grey gray sáng bright thanh gợi ý chữ mờ dịu apple stock", location: .page(.giaoDien)),
            E(viTitle: LK("Hiện logo Vᴛ"), keywords: "logo phím cách", location: .page(.giaoDien)),
            E(viTitle: LK("Bàn phím tách đôi"), keywords: "split tách chia hai nửa gập ngang", location: .page(.giaoDien)),
            // Riêng tư & sao lưu
            E(viTitle: LK("Lịch sử clipboard"), keywords: "copy dán clipboard giữ lịch sử 24 giờ 7 ngày keep history", location: .page(.riengTu), key: "clipboardHistory"),
            E(viTitle: LK("Tự lưu khi sao chép"), keywords: "clipboard copy sao chép tự động lưu auto save đã dán từ pasted from thông báo banner", location: .page(.riengTu), key: "clipboardAutoSave"),
            E(viTitle: LK("Chế độ ẩn danh"), keywords: "incognito riêng tư", location: .page(.riengTu), key: "incognitoMode"),
            E(viTitle: LK("Xuất / nhập file sao lưu"), keywords: "backup export import restore sao lưu", location: .page(.riengTu)),
            E(viTitle: LK("Đồng bộ iCloud"), keywords: "sync icloud đồng bộ", location: .page(.riengTu), condition: .iCloud),
            // Nâng cao / Gỡ lỗi
            E(viTitle: LK("Debug mode — ghi log chạm phím"), keywords: "debug log gỡ lỗi nhật ký tester", location: .page(.nangCao), key: "debugTouchLog"),
        ]
        // Nhóm "Gõ lẫn tiếng Anh" (tab Kiểu Gõ) — tên + từ khoá ở Shared/MixedTypingUI.swift.
        e += MixedTypingItem.allCases.map { m in
            E(viTitle: m.viTitle, keywords: m.keywords,
              location: m.placement == .top ? .mixed(m) : .mixedAdvanced(m), key: m.storageKey)
        }
        return e
    }()

    /// Dòng tên các trang Tính Năng (gõ tên trang cũng ra).
    static let pages: [SettingsIndexEntry] = FeaturePage.allCases.map {
        SettingsIndexEntry(viTitle: $0.viTitle, keywords: "", location: .page($0))
    }

    /// So khớp không phân biệt hoa/thường và dấu ("trong suot" vẫn ra) — SettingsSearch (Shared).
    static func search(_ query: String, allows: (SettingsIndexEntry.Condition) -> Bool) -> [SettingsIndexEntry] {
        let words = SettingsSearch.words(query)
        guard !words.isEmpty else { return [] }
        return (pages + all).filter {
            allows($0.condition) && SettingsSearch.matches(viTitle: $0.viTitle, keywords: $0.keywords, words: words)
        }
    }

    /// Mục có key `k` (test: bộ chọn hồ sơ trỏ đúng chỗ mới).
    static func entry(forKey k: String) -> SettingsIndexEntry? { all.first { $0.key == k } }
}

/// Chú thích MỘT dòng ngắn của từng cài đặt (06/11/2026, cùng chữ với Android ui/SettingCaptions.kt):
/// ≤ 95 ký tự cả tiếng Việt lẫn tiếng Anh, một ví dụ — SettingsCleanupTests.testCaptionsAreShort.
enum SettingCaption {
    // Kiểu Gõ
    static let vni = LK("Dấu bằng số: 1–5 sắc/huyền/hỏi/ngã/nặng, 6 â ê ô, 7 ơ ư, 8 ă, 9 đ, 0 xoá dấu.")
    static let autoCapitalize = LK("Bật shift ở đầu ô, sau . ! ? và khi xuống dòng.")
    static let simpleTelex = LK("w đứng riêng vẫn là w (gõ uw ra ư).")
    static let freeMarking = LK("Đặt dấu ở đâu trong từ cũng được (ama → âm). Tắt: chặt hơn, hợp gõ tiếng Anh/code.")
    static let quickTelex = LK("Gõ đúp phụ âm đầu: kk → kh, nn → ng, pp → ph, tt → th…")
    static let modernTone = LK("hoà, thuý, khoẻ thay vì hòa, thủy, khỏe.")
    static let teencode = LK("Nhận kiểu viết chat: wá, zui zẻ, kó. Tắt: was, zoo giữ nguyên.")
    static let autoCircumflex = LK("Gõ vietj ra việt, benhj ra bệnh khi vần không mũ không tồn tại.")
    // Gõ lẫn tiếng Anh
    static let profileHint = LK("Chọn một — các công tắc bên dưới sẽ tự đặt theo.")
    static let customProfile = LK("Bạn đã tự chỉnh các công tắc bên dưới.")
    static let spaceSwipeLanguage = LK("Vuốt nhanh phím cách sang trái/phải; góc phím cách hiện VI / EN.")
    static let userDictionary = LK("Xem, tìm, xoá từ đã học; thêm tên riêng.")
    static let autoRestore = LK("Từ không phải tiếng Việt trả về đúng như đã gõ (google, github).")
    static let contextualEnglish = LK("Sau một từ tiếng Anh, từ kế giữ tiếng Anh: “he is”, không thành “he í”.")
    static let retroEnglish = LK("Sửa từ bị bỏ dấu nhầm khi câu hoá ra tiếng Anh: “Hí cả í” → “His car is”.")
    static let englishByFrequency = LK("Đầu câu, “his” giữ tiếng Anh thay vì “hí”; tự đổi lại nếu câu là tiếng Việt.")
    /// Thay cả nhóm khi chọn VNI (SETTINGS-CLEANUP-SPEC §1).
    static let vniMixedNote = MixedTypingUI.vniNoteKey
    // Sửa lỗi & gợi ý
    static let liveSpellCheck = LK("Ngừng thêm dấu ngay khi từ không thể là tiếng Việt (google, github).")
    static let reEditWord = LK("Thêm dấu cho từ đã gõ: toan + s → toán.")
    static let autoFixAdjacent = LK("Gợi ý từ đúng khi bạn lỡ chạm phím bên cạnh: ohims → phím.")
    static let smartTouch = LK("Chạm sát mép hai phím thì chọn phím hợp với chữ đang gõ.")
    static let autoCorrect = LK("Khi gõ dấu cách, sửa từ chạm nhầm (tpoi → tôi); ⌫ ngay sau để trả lại.")
    static let adjacentFooter = LK("Gợi ý sửa lỗi hiện trên thanh gợi ý (cần bật Thanh gợi ý).")
    static let showSuggestions = LK("Gợi ý từ + emoji, tự học từ bạn hay dùng (chỉ trên máy).")
    static let suggestionCount = LK("Tự động: 3 từ. Máy hẹp có thể hiện ít hơn để ô đủ rộng cho dễ chạm.")
    static let keyboardDismissButton = LK("Hiện ⌄ ở góc phải thanh gợi ý; chạm để ẩn bàn phím.")
    static let suggestInNoSuggestFields = LK("Vẫn gợi ý ở ô mà ứng dụng tắt gợi ý (ô chat, thanh địa chỉ); không học từ ở đó.")
    static let emojiSuggest = LK("Emoji hợp với từ đang gõ (yêu → ❤️).")
    static let numberChips = LK("Đọc số thành chữ, định dạng tiền (1tr2 → 1.200.000 ₫).")
    static let mathResults = LK("Gõ phép tính (12*3) → “= 36” hiện trên thanh gợi ý, chạm để chèn.")
    static let pasteButton = LK("Vừa copy xong thì hiện nút Dán (cần Toàn quyền).")
    static let addTones = LK("Gõ không dấu cả câu rồi chạm chip “Thêm dấu”: hom nay troi dep → hôm nay trời đẹp.")
    static let aiProofread = LK("Chọn chữ → chip “✨ Sửa lỗi”: chính tả, dấu, ngữ pháp, xem trước. Chạy trên máy.")
    static let filterSensitive = LK("Không chủ động gợi ý từ tục — gõ tay vẫn bình thường.")
    // Gõ vuốt
    static let swipeTyping = LK("Vuốt qua các chữ không dấu rồi nhấc tay: v→i→e→t ra “việt”.")
    static let swipeFooterIos = LK("Chỉ trên iPhone. Tự tắt khi dùng VoiceOver và ở ô email/mật khẩu/URL.")
    static let swipeEnglish = LK("check, mail, meeting… Nét vừa Việt vừa Anh (the/thế) ưu tiên tiếng Việt.")
    static let swipeFuto = LK("Mạng neural chạy trên máy, chấm cùng bộ giải mã. Tốn thêm ~3 MB bộ nhớ.")
    static let swipePractice = LK("Vuốt thử từng từ, xem bàn phím đọc đúng bao nhiêu.")
    // Gõ tắt & mẫu câu
    static let shortcuts = LK("Gõ chữ tắt rồi dấu cách để bung: ko → không. ⌫ ngay sau để trả lại.")
    static let systemTextReplacement = LK("Bung cả mục Thay thế văn bản của iOS; trùng chữ tắt thì bảng VietTelex thắng.")
    static let templates = LK("Nút ☰ chèn câu soạn sẵn (tab Mẫu Câu). Tắt: ẩn tab Mẫu Câu.")
    static let textTools = LK("Thẻ Công cụ trong bảng ☰: đổi HOA/thường, thêm/xoá dấu, dịch…")
    static let translate = LK("Chọn ngôn ngữ dịch + tải gói dịch cho chip “Dịch ↔ …” trong Công cụ.")
    // Phím & cử chỉ
    static let numberRow = LK("Thêm hàng 1 … 0 trên hàng chữ (bàn phím cao thêm gần một hàng).")
    static let numberRowFullHeight = LK("Phím số to bằng phím chữ (bàn phím cao thêm đúng một hàng).")
    static let spaceSideKey = LK("Phím hẹp cạnh phím cách. Cả hai: dấu phẩy bên trái, dấu chấm bên phải.")
    static let largeKeys = LK("Dấu phẩy, dấu chấm cạnh phím cách rộng hơn, đỡ chạm nhầm phím cách.")
    static let emojiKeyPlacement = LK("Thanh trên: nút emoji lên thanh gợi ý, phím cách rộng hơn.")
    static let longPressNumbers = LK("Giữ q … p để gõ 1 … 0 (số nhỏ ở góc phím).")
    static let longPressSymbols = LK("Giữ a … l, z … m để gõ @ # $ _ & - + ( ) …")
    static let holdShiftSymbols = LK("Giữ ⇧ rồi chạm phím chữ để gõ ký tự ở góc phím: q w e → 1 2 3.")
    static let autoSpaceAfterPunct = LK("Gõ . , ? ! ; : tự thêm dấu cách sau (trừ trong số, email, đường dẫn).")
    static let symbolReturn = LK("Tự động: sau , ? ! ; & $ @ và dấu nháy; dấu . : ) thì ở lại. Luôn: sau mọi ký hiệu.")
    static let trackpadSpeed = LK("Giữ phím cách rồi kéo để di con trỏ; mức này chỉnh độ tăng tốc.")
    static let swipeKeyCommandsIos = LK("Vuốt C, X, V lên quá hàng trên cùng: sao chép, cắt, dán (cần Toàn quyền).")
    static let oneHandIos = LK("Thu bàn phím về một bên; giữ lâu nút ☰ trên thanh gợi ý để bật/tắt nhanh.")
    static let gesturesFooterIos = LK("Xuống dòng không gửi (ô chat trên web): giữ lâu Return, hoặc chạm ⇧ rồi Return.")
    static let keyPreview = LK("Ô chữ lớn nổi trên phím vừa chạm.")
    static let keyPressHighlight = LK("Phím đổi màu trong lúc chạm, kể cả khi tắt phóng to chữ.")
    static let hapticFeedback = LK("Rung nhẹ mỗi lần chạm phím.")
    static let keySound = LK("Tiếng phím riêng của VietTelex: chọn kiểu, âm lượng. Tắt: dùng tiếng của hệ thống.")
    // Giao diện
    static let plusThemes = LK("Theme có nhãn Plus và ảnh nền thuộc VietTelex Plus; các theme khác miễn phí.")
    static let systemBackdrop = LK("Giữ màu phím của theme, nền dùng lớp kính của iOS (liền với dải 🌐 🎤).")
    static let moleGame = LK("Gõ như thường — chú chuột thò lên ở phím bạn sắp gõ. Gõ trúng lúc nó lên là đập được!")
    static let spotlightPhoto = LK("Thêm ảnh nền để đèn rọi lên ảnh của bạn.")
    static let wallpaper = LK("Ảnh được thu nhỏ, nén ngay trên máy, không gửi đi đâu. Lớp phủ giúp chữ dễ đọc.")
    static let transparency = LK("Phím: 100% chỉ còn chữ, ảnh nền vẫn giữ. Ký tự: 100% là phím trơn không chữ.")
    static let rowHeightIos = LK("0 = như bàn phím gốc của iPhone, gõ theo thói quen không lệch phím.")
    static let keyboardRaise = LK("Thêm khoảng trống dưới hàng phím cuối để bàn phím nằm cao hơn.")
    static let suggestionBarHeight = LK("Cao hơn thì dễ chạm trúng gợi ý; bàn phím cao thêm đúng phần đó.")
    static let suggestionInk = LK("Xám: dịu như bàn phím Apple, đỡ rối mắt. Sáng: cùng màu chữ phím.")
    static let spaceLogo = LK("Logo mờ ở góc phải phím cách.")
    static let splitKeyboardIos = LK("Màn hình rộng (iPad, xoay ngang, máy gập): chia bàn phím làm hai nửa.")
    static let resetAppearance = LK("Theme, ảnh nền, độ trong suốt, tuỳ chỉnh về mặc định. Ảnh, chiều cao hàng, logo giữ nguyên.")
    static let advancedStyle = LK("Màu, bo góc, cỡ chữ, phông, độ đậm — lưu riêng cho từng giao diện.")
    static let fontScaleIos = LK("Phím hẹp tự thu nhỏ chữ cho vừa, dấu không bị cắt.")
    // Riêng tư & sao lưu
    static let clipboardHistory = LK("Nút clipboard trên thanh gợi ý mở 20 mục vừa copy; ghim để giữ. Chỉ lưu trên máy.")
    static let clipboardAutoSave = LK("Lưu vào lịch sử ngay khi bạn sao chép. iOS sẽ hiện thông báo \"VietTelex đã dán từ…\" mỗi lần.")
    static let clipboardTTL = LK("Mục trông như mật khẩu/OTP vẫn tự xoá sau 2 phút; ghim để giữ lâu.")
    static let clipboardPasteAllowIos = LK("Để tự ghi mục mới không bị hỏi: Cài đặt → VietTelex → Dán từ ứng dụng khác → Cho phép.")
    static let clipboardIosLimit = LK("iOS chỉ cho đọc clipboard khi bàn phím hiện: copy lúc ẩn chỉ ghi được mục cuối.")
    static let clipboardOffClears = LK("Tắt Lịch sử clipboard sẽ xoá toàn bộ mục đã lưu ở lần mở bàn phím kế tiếp.")
    static let incognitoIos = LK("Không học từ mới, không lưu clipboard.")
    static let iCloudSync = LK("Cài đặt, gõ tắt, mẫu câu giống nhau trên mọi máy cùng iCloud (trừ từ đã học).")
    static let includeLearned = LK("Từ bàn phím đã học (tần suất gõ) — riêng tư, chỉ bật khi file do chính bạn giữ.")
    static let backupFile = LK("File gồm cài đặt, gõ tắt, mẫu câu; mở được trên iPhone, iPad, Android. Nhập sẽ gộp thêm.")
    // Nâng cao / Gỡ lỗi
    static let debugLogIos = LK("Ghi thời điểm chạm, độ trễ, số phím — KHÔNG ghi chữ bạn gõ. Cần Toàn quyền.")
    static let showLog = LK("Bật để xem log bên dưới và copy toàn bộ — tắt rồi bật lại để tải log mới.")
    static let clearLog = LK("Bật để xoá log cũ trước khi thử lại.")
    // Giới thiệu
    static let swipeDataCredit = LK("Dữ liệu gõ vuốt: Wikipedia, Wikisource… tiếng Việt (CC BY-SA 4.0), Tatoeba (CC BY 2.0 FR)")
    // Phản hồi khi chạm › Âm thanh gõ
    static let keySoundStylesIos = LK("iOS: tiếng bấm của hệ thống, không cần Toàn quyền. Kiểu khác: tiếng riêng, cần Toàn quyền.")
    static let keySoundVolumeIos = LK("Kéo hoặc chọn kiểu để nghe thử. Không nghe thấy? Tắt gạt im lặng.")
    static let customSound = LK("Cắt lặng đầu, tối đa 0,3 giây, chỉnh độ to an toàn. File chỉ trên máy này (không sao lưu).")

    static let all: [String] = [
        keySoundStylesIos, keySoundVolumeIos, customSound,
        vni, autoCapitalize, simpleTelex, freeMarking, quickTelex, modernTone,
        teencode, autoCircumflex, profileHint, customProfile, spaceSwipeLanguage, userDictionary, autoRestore,
        contextualEnglish, retroEnglish, englishByFrequency, vniMixedNote, liveSpellCheck, reEditWord, autoFixAdjacent,
        smartTouch, autoCorrect, adjacentFooter, showSuggestions, suggestionCount, keyboardDismissButton, suggestInNoSuggestFields,
        emojiSuggest, numberChips, mathResults, pasteButton, addTones, aiProofread,
        filterSensitive, swipeTyping, swipeFooterIos, swipeEnglish, swipeFuto, swipePractice,
        shortcuts, systemTextReplacement, templates, textTools, translate, numberRow,
        numberRowFullHeight, spaceSideKey, largeKeys, emojiKeyPlacement, longPressNumbers, longPressSymbols,
        holdShiftSymbols, autoSpaceAfterPunct, symbolReturn, trackpadSpeed, swipeKeyCommandsIos, oneHandIos, gesturesFooterIos,
        keyPreview, keyPressHighlight, hapticFeedback, keySound, plusThemes, systemBackdrop,
        moleGame, spotlightPhoto, wallpaper, transparency, rowHeightIos, keyboardRaise, suggestionBarHeight,
        suggestionInk, spaceLogo, splitKeyboardIos, resetAppearance, advancedStyle, fontScaleIos,
        clipboardHistory, clipboardAutoSave, clipboardTTL, clipboardPasteAllowIos, clipboardIosLimit, clipboardOffClears, incognitoIos,
        iCloudSync, includeLearned, backupFile, debugLogIos, showLog, clearLog,
        swipeDataCredit,
    ]
}
