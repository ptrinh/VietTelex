package com.viettelex.android.ui

// Chú thích MỘT dòng ngắn của từng cài đặt (06/11/2026, cùng chữ với iOS App/SettingsIndex.swift
// `SettingCaption`): ≤ 95 ký tự cả tiếng Việt lẫn tiếng Anh, một ví dụ — SettingsCleanupTest.
// Hiển thị qua `tr(SettingCaption.x)`; bản dịch ở keyboard/…/L10nTable.kt.

@Suppress("ConstPropertyName")
internal object SettingCaption {
    // Kiểu Gõ
    const val vni = "Dấu bằng số: 1–5 sắc/huyền/hỏi/ngã/nặng, 6 â ê ô, 7 ơ ư, 8 ă, 9 đ, 0 xoá dấu." // l10n-key
    const val autoCapitalize = "Bật shift ở đầu ô, sau . ! ? và khi xuống dòng." // l10n-key
    const val simpleTelex = "w đứng riêng vẫn là w (gõ uw ra ư)." // l10n-key
    const val freeMarking = "Đặt dấu ở đâu trong từ cũng được (ama → âm). Tắt: chặt hơn, hợp gõ tiếng Anh/code." // l10n-key
    const val quickTelex = "Gõ đúp phụ âm đầu: kk → kh, nn → ng, pp → ph, tt → th…" // l10n-key
    const val modernTone = "hoà, thuý, khoẻ thay vì hòa, thủy, khỏe." // l10n-key
    const val teencode = "Nhận kiểu viết chat: wá, zui zẻ, kó. Tắt: was, zoo giữ nguyên." // l10n-key
    // Gõ lẫn tiếng Anh
    const val profileHint = "Chọn một — các công tắc bên dưới sẽ tự đặt theo." // l10n-key
    const val customProfile = "Bạn đã tự chỉnh các công tắc bên dưới." // l10n-key
    const val spaceSwipeLanguage = "Vuốt nhanh phím cách sang trái/phải; góc phím cách hiện VI / EN." // l10n-key
    const val userDictionary = "Xem, tìm, xoá từ đã học; thêm tên riêng." // l10n-key
    const val autoRestore = "Từ không phải tiếng Việt trả về đúng như đã gõ (google, github)." // l10n-key
    const val contextualEnglish = "Sau một từ tiếng Anh, từ kế giữ tiếng Anh: “he is”, không thành “he í”." // l10n-key
    const val retroEnglish = "Sửa từ bị bỏ dấu nhầm khi câu hoá ra tiếng Anh: “Hí cả í” → “His car is”." // l10n-key
    /** Thay cả nhóm khi chọn VNI (SETTINGS-CLEANUP-SPEC §1) — cùng chữ với iOS. */
    const val vniMixedNote = "Gõ VNI không làm đổi từ tiếng Anh nên không cần chỉnh phần này." // l10n-key
    const val englishByFrequency = "Đầu câu, “his” giữ tiếng Anh thay vì “hí”; tự đổi lại nếu câu là tiếng Việt." // l10n-key
    // Sửa lỗi & gợi ý
    const val liveSpellCheck = "Ngừng thêm dấu ngay khi từ không thể là tiếng Việt (google, github)." // l10n-key
    const val reEditWord = "Thêm dấu cho từ đã gõ: toan + s → toán." // l10n-key
    const val autoCircumflex = "Gõ vietj ra việt, benhj ra bệnh khi vần không mũ không tồn tại." // l10n-key
    const val autoFixAdjacent = "Gợi ý từ đúng khi bạn lỡ chạm phím bên cạnh: ohims → phím." // l10n-key
    const val smartTouch = "Chạm sát mép hai phím thì chọn phím hợp với chữ đang gõ." // l10n-key
    const val autoCorrect = "Khi gõ dấu cách, sửa từ chạm nhầm (tpoi → tôi); ⌫ ngay sau để trả lại." // l10n-key
    const val adjacentFooter = "Gợi ý sửa lỗi hiện trên thanh gợi ý (cần bật Thanh gợi ý)." // l10n-key
    const val showSuggestions = "Gợi ý từ + emoji, tự học từ bạn hay dùng (chỉ trên máy)." // l10n-key
    const val suggestionCount = "Tự động: 3 từ. Máy hẹp có thể hiện ít hơn để ô đủ rộng cho dễ chạm." // l10n-key
    const val keyboardDismissButton = "Hiện ⌄ ở góc phải thanh gợi ý; chạm để ẩn bàn phím." // l10n-key
    const val suggestInNoSuggestFields = "Vẫn gợi ý ở ô mà ứng dụng tắt gợi ý (ô chat, thanh địa chỉ); không học từ ở đó." // l10n-key
    const val numberChips = "Đọc số thành chữ, định dạng tiền (1tr2 → 1.200.000 ₫)." // l10n-key
    const val mathResults = "Gõ phép tính (12*3) → “= 36” hiện trên thanh gợi ý, chạm để chèn." // l10n-key
    const val addTones = "Gõ không dấu cả câu rồi chạm chip “Thêm dấu”: hom nay troi dep → hôm nay trời đẹp." // l10n-key
    const val filterSensitive = "Không chủ động gợi ý từ tục — gõ tay vẫn bình thường." // l10n-key
    // Gõ vuốt
    const val swipeTyping = "Vuốt qua các chữ không dấu rồi nhấc tay: v→i→e→t ra “việt”." // l10n-key
    const val swipeEnglish = "check, mail, meeting… Nét vừa Việt vừa Anh (the/thế) ưu tiên tiếng Việt." // l10n-key
    const val swipeFuto = "Mạng neural chạy trên máy, chấm cùng bộ giải mã. Tốn thêm ~3 MB bộ nhớ." // l10n-key
    const val swipePractice = "Vuốt thử từng từ, xem bàn phím đọc đúng bao nhiêu." // l10n-key
    // Gõ tắt & mẫu câu
    const val shortcuts = "Gõ chữ tắt rồi dấu cách để bung: ko → không. ⌫ ngay sau để trả lại." // l10n-key
    const val templates = "Nút ☰ chèn câu soạn sẵn (tab Mẫu Câu). Tắt: ẩn tab Mẫu Câu." // l10n-key
    const val textTools = "Thẻ Công cụ trong bảng ☰ và bảng sửa văn bản: đổi HOA/thường, thêm/xoá dấu, dịch…" // l10n-key
    // Phím & cử chỉ
    const val numberRow = "Thêm hàng 1 … 0 trên hàng chữ (bàn phím cao thêm gần một hàng)." // l10n-key
    const val numberRowFullHeight = "Phím số to bằng phím chữ (bàn phím cao thêm đúng một hàng)." // l10n-key
    const val spaceSideKey = "Phím hẹp cạnh phím cách. Cả hai: dấu phẩy bên trái, dấu chấm bên phải." // l10n-key
    const val largeKeys = "Dấu phẩy, dấu chấm cạnh phím cách rộng hơn, đỡ chạm nhầm phím cách." // l10n-key
    const val emojiKeyPlacement = "Thanh trên: nút emoji lên thanh gợi ý, phím cách rộng hơn." // l10n-key
    const val keyLabelSize = "Lớn: chữ trên phím to hơn ~20%. Plus: chỉnh chi tiết ở Giao diện." // l10n-key
    const val longPressNumbers = "Giữ q … p để gõ 1 … 0 (số nhỏ ở góc phím)." // l10n-key
    const val longPressSymbols = "Giữ a … l, z … m để gõ @ # \$ _ & - + ( ) …" // l10n-key
    const val flickDownAlternates = "Vuốt thẳng xuống trên phím để gõ ký tự ở góc phím: y → 6. Tắt khi bật Gõ vuốt." // l10n-key
    const val holdShiftSymbols = "Giữ ⇧ rồi chạm phím chữ để gõ ký tự ở góc phím: q w e → 1 2 3." // l10n-key
    const val autoSpaceAfterPunct = "Gõ . , ? ! ; : tự thêm dấu cách sau (trừ trong số, email, đường dẫn)." // l10n-key
    const val symbolReturn = "Tự động: sau , ? ! ; & $ @ và dấu nháy; dấu . : ) thì ở lại. Luôn: sau mọi ký hiệu." // l10n-key
    const val trackpadSpeed = "Giữ phím cách rồi kéo để di con trỏ; mức này chỉnh độ tăng tốc." // l10n-key
    const val swipeKeyCommandsAndroid = "Vuốt C, X, V, A, Z, Y lên: sao chép, cắt, dán, chọn hết, hoàn tác, làm lại." // l10n-key
    const val oneHandAndroid = "Thu bàn phím về một bên; giữ lâu icon con trỏ trên thanh gợi ý để bật/tắt." // l10n-key
    const val floatingKeyboard = "Bàn phím thành khung nhỏ, kéo đặt đâu cũng được. Bật nhanh: giữ 😊 → 🪟." // l10n-key
    const val hardwareTelex = "Gõ Telex/VNI bằng bàn phím Bluetooth/USB, DeX, Chromebook; Ctrl/Alt vẫn tới app." // l10n-key
    const val keyPreview = "Ô chữ lớn nổi trên phím vừa chạm." // l10n-key
    const val keyPressHighlight = "Phím đổi màu trong lúc chạm, kể cả khi tắt phóng to chữ." // l10n-key
    const val hapticFeedback = "Rung nhẹ mỗi lần chạm phím." // l10n-key
    const val keySound = "Tiếng phím riêng của VietTelex: chọn kiểu, âm lượng. Tắt: dùng tiếng của hệ thống." // l10n-key
    // Giao diện
    const val plusThemes = "Theme có nhãn Plus và ảnh nền thuộc VietTelex Plus; các theme khác miễn phí." // l10n-key
    const val materialYou = "Tắt để bàn phím dùng màu xám trung tính, không đổi theo hình nền." // l10n-key
    const val moleGame = "Gõ như thường — chú chuột thò lên ở phím bạn sắp gõ. Gõ trúng lúc nó lên là đập được!" // l10n-key
    const val spotlightPhoto = "Thêm ảnh nền để đèn rọi lên ảnh của bạn." // l10n-key
    const val wallpaper = "Ảnh được thu nhỏ, nén ngay trên máy, không gửi đi đâu. Lớp phủ giúp chữ dễ đọc." // l10n-key
    const val transparency = "Phím: 100% chỉ còn chữ, ảnh nền vẫn giữ. Ký tự: 100% là phím trơn không chữ." // l10n-key
    const val transparencyHostApp = "Chỉ app vẽ dưới bàn phím (trình duyệt…) mới thấy xuyên; mọi app: dùng ảnh nền." // l10n-key
    const val rowHeightClamp = "Màn hình thấp hoặc xoay ngang: tự giới hạn để bàn phím không quá nửa màn hình." // l10n-key
    const val keyboardRaise = "Thêm khoảng trống dưới hàng phím cuối để bàn phím nằm cao hơn." // l10n-key
    const val suggestionBarHeight = "Cao hơn thì dễ chạm trúng gợi ý; bàn phím cao thêm đúng phần đó." // l10n-key
    const val suggestionInk = "Xám: dịu như bàn phím Apple, đỡ rối mắt. Sáng: cùng màu chữ phím." // l10n-key
    const val spaceLogo = "Logo mờ ở góc phải phím cách." // l10n-key
    const val splitKeyboardAndroid = "Màn hình rộng (máy tính bảng, xoay ngang, máy gập): chia bàn phím làm hai nửa." // l10n-key
    const val resetAppearance = "Theme, ảnh nền, độ trong suốt, tuỳ chỉnh về mặc định. Ảnh, chiều cao hàng, logo giữ nguyên." // l10n-key
    const val advancedStyle = "Màu, bo góc, cỡ chữ, phông, độ đậm — lưu riêng cho từng giao diện." // l10n-key
    const val fontScaleAndroid = "Phím hẹp tự thu nhỏ chữ cho vừa. Khi đặt, thay cho “Cỡ chữ trên phím” ở trang Phím." // l10n-key
    // Riêng tư & sao lưu
    const val clipboardHistory = "Nút clipboard trên thanh gợi ý mở tối đa 100 mục vừa copy; ghim để giữ. Chỉ lưu trên máy." // l10n-key
    const val clipboardTTL = "Mục trông như mật khẩu/OTP vẫn tự xoá sau 2 phút; ghim để giữ lâu." // l10n-key
    const val clipboardFooterAndroid = "Lịch sử chỉ ghi khi VietTelex là bàn phím đang chọn. Không có gì rời khỏi máy." // l10n-key
    const val incognitoAndroid = "Không học từ mới, không lưu clipboard; tự bật ở tab ẩn danh của trình duyệt." // l10n-key
    const val includeLearned = "Từ bàn phím đã học (tần suất gõ) — riêng tư, chỉ bật khi file do chính bạn giữ." // l10n-key
    const val driveSync = "Cài đặt, gõ tắt, mẫu câu theo bạn sang máy Android khác qua thư mục ẩn trên Google Drive." // l10n-key
    const val backupFile = "File gồm cài đặt, gõ tắt, mẫu câu; mở được trên iPhone, iPad, Android. Nhập sẽ gộp thêm." // l10n-key
    const val debugLogAndroid = "Ghi thời điểm chạm, độ trễ, số phím — KHÔNG ghi chữ bạn gõ. Tắt khi xong." // l10n-key
    const val showLog = "Bật để xem log bên dưới và copy toàn bộ — tắt rồi bật lại để tải log mới." // l10n-key
    const val clearLog = "Bật để xoá log cũ trước khi thử lại." // l10n-key
    // Giới thiệu
    const val swipeDataCredit = "Dữ liệu gõ vuốt: Wikipedia, Wikisource… tiếng Việt (CC BY-SA 4.0), Tatoeba (CC BY 2.0 FR)" // l10n-key
    const val privacyAndroid = "VietTelex chạy trên máy, không gửi gì đi; mạng chỉ dùng cho Mẫu câu động (https://)." // l10n-key
    const val tryItAndroid = "Bấm biểu tượng bàn phím ở thanh điều hướng, chọn VietTelex, rồi gõ thử: vieejt → việt." // l10n-key
    // Phản hồi khi chạm › Âm thanh gõ
    const val keySoundStylesAndroid = "Hệ thống: âm thanh khi chạm của Android. Kiểu khác: tiếng riêng của VietTelex." // l10n-key
    const val keySoundVolumeAndroid = "Kéo hoặc chọn kiểu để nghe thử. Không nghe thấy? Tắt chế độ Rung/Im lặng." // l10n-key
    // Giao diện › Cung hoàng đạo / Tự hào
    const val zodiacSign = "Màu theo nguyên tố của cung; Chòm sao vẽ chòm của cung. Chỉ lưu cung, không lưu ngày sinh." // l10n-key
    const val prideFlag = "Màu, viền phím và Cầu vồng theo lá cờ bạn chọn. Gõ \"tự hào\" để thấy lá cờ tung bay." // l10n-key
    const val customSound = "Cắt lặng đầu, tối đa 0,3 giây, chỉnh độ to an toàn. File chỉ trên máy này (không sao lưu)." // l10n-key

    val all: List<String> = listOf(
        keySoundStylesAndroid, keySoundVolumeAndroid, customSound,
        vni, autoCapitalize, simpleTelex, freeMarking, quickTelex, modernTone,
        teencode, profileHint, customProfile, spaceSwipeLanguage, userDictionary, autoRestore,
        contextualEnglish, retroEnglish, englishByFrequency, vniMixedNote, liveSpellCheck, reEditWord, autoCircumflex, autoFixAdjacent,
        smartTouch, autoCorrect, adjacentFooter, showSuggestions, suggestionCount, keyboardDismissButton, suggestInNoSuggestFields, numberChips,
        mathResults, addTones, filterSensitive, swipeTyping, swipeEnglish, swipeFuto,
        swipePractice, shortcuts, templates, textTools, numberRow, numberRowFullHeight,
        spaceSideKey, largeKeys, emojiKeyPlacement, keyLabelSize, longPressNumbers, longPressSymbols,
        holdShiftSymbols, flickDownAlternates, autoSpaceAfterPunct, symbolReturn, trackpadSpeed, swipeKeyCommandsAndroid, oneHandAndroid, floatingKeyboard,
        hardwareTelex, keyPreview, keyPressHighlight, hapticFeedback, keySound, plusThemes,
        materialYou, moleGame, spotlightPhoto, wallpaper, transparency, transparencyHostApp, rowHeightClamp,
        keyboardRaise, suggestionBarHeight, suggestionInk, spaceLogo, splitKeyboardAndroid, resetAppearance,
        advancedStyle, fontScaleAndroid, clipboardHistory, clipboardTTL, clipboardFooterAndroid, incognitoAndroid,
        includeLearned, backupFile, driveSync, debugLogAndroid, showLog, clearLog, swipeDataCredit,
        privacyAndroid, tryItAndroid, zodiacSign, prideFlag,
    )
}
