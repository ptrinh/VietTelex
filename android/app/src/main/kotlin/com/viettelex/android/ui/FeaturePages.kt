package com.viettelex.android.ui

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Slider
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.viettelex.keyboard.HapticStrength
import com.viettelex.keyboard.KeySoundStyle
import com.viettelex.keyboard.PreviewThrottle
import com.viettelex.android.ime.KeyFeedbackPreview
import com.viettelex.android.ime.KeySoundImport
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.runtime.DisposableEffect
import android.os.SystemClock
import com.viettelex.keyboard.KeyAlternates
import com.viettelex.keyboard.Keys
import com.viettelex.keyboard.SpaceSideKey
import com.viettelex.keyboard.SymbolReturn
import com.viettelex.keyboard.EmojiKeyPlacement
import com.viettelex.keyboard.KeyLabelSize
import com.viettelex.keyboard.PlusFeature
import com.viettelex.keyboard.PlusGate
import java.text.Normalizer
import java.util.Locale
import com.viettelex.keyboard.tr
import com.viettelex.keyboard.L10n
import com.viettelex.keyboard.L10nTable
import com.viettelex.android.shared.UiLang
import androidx.compose.ui.draw.clip
import androidx.compose.foundation.layout.widthIn
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextAlign
import com.viettelex.keyboard.SuggestionCount

// Tab Tính Năng (27/09/2026): trang chính là các nhóm (icon + tên + tóm tắt trạng thái), mỗi
// nhóm mở một trang con — thay cho danh sách dài mọi công tắc. Ô tìm kiếm lọc theo tên/từ
// khoá rồi mở đúng trang. KHÔNG đổi key/mặc định: trang con đọc/ghi cùng SharedPreferences.
// Cùng cấu trúc với iOS (App/FeaturePages.swift). Thu gọn 05/11/2026 (SETTINGS-CLEANUP-SPEC §4):
// "Chính tả & sửa lỗi" + "Gợi ý & từ điển" → "Sửa lỗi & gợi ý"; "Riêng tư & clipboard" + "Sao lưu
// & đồng bộ" → "Riêng tư & sao lưu"; Gỡ lỗi (từ Giới Thiệu) → "Nâng cao / Gỡ lỗi" cuối danh sách.

internal val APPLY_NOTE get() = tr("Cài đặt áp dụng ngay lần mở bàn phím kế tiếp.")

/** Trang con của "Phím & cử chỉ": rung, âm thanh, phóng to/sẫm phím khi bấm. */
internal const val FEEDBACK_TITLE = "Phản hồi khi chạm" // l10n-key

/** [viTitle] = khoá dịch; hiển thị qua [title] (theo ngôn ngữ giao diện). [anchor] rỗng = không có mục Hướng dẫn. */
/** [badgeVi]: nhãn cạnh tên trang (khoá dịch) — Gõ vuốt = "Máy học" (thay "Thử nghiệm", Phil 12/11/2026). */
enum class FeaturePage(val viTitle: String, val glyph: Glyph, val color: Color, val anchor: String, val enAnchor: String, val badgeVi: String? = null) {
    SuaLoi("Sửa lỗi & gợi ý", Glyph.Spell, Color(0xFF34C759), "goi-y", "suggestions"), // l10n-key
    GoVuot("Gõ vuốt", Glyph.Swipe, Color(0xFFAF52DE), "go-vuot", "swipe", badgeVi = "Máy học"), // l10n-key
    GoTat("Gõ tắt & mẫu câu", Glyph.Quote, Color(0xFF30B0C7), "go-tat", "shortcuts"), // l10n-key
    Phim("Phím & cử chỉ", Glyph.Keyboard, Color(0xFF8E8E93), "cu-chi", "gestures"), // l10n-key
    GiaoDien("Giao diện", Glyph.Palette, Color(0xFFFF2D55), "giao-dien", "look"), // l10n-key
    RiengTu("Riêng tư & sao lưu", Glyph.Lock, Color(0xFF5856D6), "sao-luu", "backup"), // l10n-key
    NangCao("Nâng cao / Gỡ lỗi", Glyph.Sliders, Color(0xFF8E8E93), "", ""); // l10n-key

    val title: String get() = tr(viTitle)
    /** Hướng dẫn đúng ngôn ngữ: /hdsd/#… hoặc /en/guide/#… (anchor tiếng Anh khác). */
    val guideUrl: String get() = L10n.guideUrl("android", if (L10n.isEnglish) enAnchor else anchor)

    companion object {
        /** Khối như app Cài đặt; "Nâng cao / Gỡ lỗi" cuối danh sách. */
        val groups = listOf(listOf(SuaLoi, GoVuot, GoTat), listOf(Phim, GiaoDien), listOf(RiengTu), listOf(NangCao))
    }
}

/**
 * Chỉ mục ô tìm kiếm: tên cài đặt ([viTitle] = khoá dịch) + từ khoá → trang chứa nó. Tìm khớp
 * CẢ tên tiếng Việt lẫn tên tiếng Anh (bất kể đang chọn ngôn ngữ nào) + từ khoá (Việt/Anh).
 */
internal data class FeatureSearchEntry(
    val viTitle: String, val keywords: String, val page: FeaturePage?,
    /** Mục của nhóm thu gọn "Gõ lẫn tiếng Anh" (tab Kiểu Gõ) — [page] = null. */
    val mixed: MixedTypingItem? = null,
    /** Mục kiểu gõ (tab Kiểu Gõ, trang chính hoặc "Nâng cao") — [page] = null. */
    val typing: TypingOption? = null,
    /** Dòng ở trang con "Phản hồi khi chạm" (trong Phím & cử chỉ) ⇒ mở thẳng trang con đó. */
    val feedback: Boolean = false,
) {
    val title: String get() = tr(viTitle)
    val isPage: Boolean get() = page != null && viTitle == page.viTitle
    /** Đích ở tab Kiểu Gõ (null = trang Tính Năng [page]). */
    val kieuGoTarget: KieuGoTarget? get() = mixed?.target ?: typing?.target

    /** Đường dẫn hiện dưới kết quả: "Kiểu Gõ › Gõ lẫn tiếng Anh › Nâng cao"… */
    val path: String get() {
        val tab = AppTab.KieuGo.title
        val adv = tr("Nâng cao")
        return when {
            mixed != null -> listOfNotNull(tab, tr(MIXED_TITLE).takeIf { mixed != MixedTypingItem.Section },
                adv.takeIf { mixed.placement == MixedTypingItem.Placement.Advanced }).joinToString(" › ")
            typing != null -> listOfNotNull(tab, tr("Kiểu gõ").takeIf { typing != TypingOption.InputMethod },
                adv.takeIf { typing.advanced }).joinToString(" › ")
            page != null -> listOfNotNull(AppTab.TinhNang.title, page.title,
                tr(FEEDBACK_TITLE).takeIf { feedback && viTitle != FEEDBACK_TITLE }).joinToString(" › ")
            else -> ""
        }
    }

    companion object {
        val all = listOf(
            FeatureSearchEntry("Kiểm tra chính tả khi gõ", "spell check", FeaturePage.SuaLoi), // l10n-key
            FeatureSearchEntry("Sửa dấu từ đã gõ", "sửa dấu con trỏ backspace", FeaturePage.SuaLoi), // l10n-key
            FeatureSearchEntry("Tự thêm dấu mũ", "dấu mũ circumflex viet việt ê â mũ tự động auto hat", FeaturePage.SuaLoi), // l10n-key
            FeatureSearchEntry("Gợi ý sửa lỗi chạm trượt", "chạm trượt phím bên cạnh adjacent typo gợi ý sửa", FeaturePage.SuaLoi), // l10n-key
            FeatureSearchEntry("Chọn phím thông minh", "chạm trượt smart touch thử nghiệm experimental", FeaturePage.SuaLoi), // l10n-key
            FeatureSearchEntry("Tự sửa từ gõ sai", "autocorrect sửa lỗi chạm trượt thử nghiệm experimental", FeaturePage.SuaLoi), // l10n-key
            FeatureSearchEntry("Thanh gợi ý", "suggestion học từ", FeaturePage.SuaLoi), // l10n-key
            FeatureSearchEntry("Nút ẩn bàn phím", "ẩn bàn phím hide dismiss keyboard chevron ⌄ đóng close", FeaturePage.SuaLoi), // l10n-key
            FeatureSearchEntry("Gợi ý số tiền", "chip số tiền đọc số number money currency", FeaturePage.SuaLoi), // l10n-key
            FeatureSearchEntry("Hiện kết quả phép tính", "tính toán máy tính bằng math calculator", FeaturePage.SuaLoi), // l10n-key
            FeatureSearchEntry("Thêm dấu", "chip thêm dấu cả câu không dấu add tones plus", FeaturePage.SuaLoi), // l10n-key
            FeatureSearchEntry("Lọc từ nhạy cảm", "tục chửi filter", FeaturePage.SuaLoi), // l10n-key
            FeatureSearchEntry("Từ điển cá nhân", "dictionary tên riêng thuật ngữ", FeaturePage.SuaLoi), // l10n-key
            FeatureSearchEntry("Xóa từ đã học", "xoá học reset", FeaturePage.SuaLoi), // l10n-key
            FeatureSearchEntry("Gõ vuốt", "swipe vuốt", FeaturePage.GoVuot), // l10n-key
            FeatureSearchEntry("Vuốt từ tiếng Anh", "swipe english gõ vuốt tiếng anh", FeaturePage.GoVuot), // l10n-key
            FeatureSearchEntry("Hiệu ứng nét vuốt", "swipe trail nét vuốt vệt hiệu ứng lửa fire điện electric lightning bút lông brush mực ink cầu vồng rainbow neon bụi sao stardust sparkle pháo hoa firework plasma ảo ảnh kính vạn hoa kaleidoscope tan chảy melt vệt lặp chroma echo phím sáng theo đường key glow thư pháp calligraphy sao chổi comet đom đóm fireflies ma trận matrix rain cánh hoa petals sen lotus theo giao diện theme plus", FeaturePage.GoVuot), // l10n-key
            FeatureSearchEntry("Âm thanh nét vuốt", "swipe sound tiếng âm thanh vuốt bút chì pencil chổi lông brush phấn bảng chalk bút dạ marker roi vụt whip tia sét lightning plasma đũa phép magic wand nốt nhạc theo phím key melody note giai điệu sáo trúc flute sóng biển waves ocean mèo kêu meow cat chim hót birdsong bird âm của bạn your sound custom plus", FeaturePage.GoVuot), // l10n-key
            FeatureSearchEntry("Mô hình neural gõ vuốt", "futo neural swipe", FeaturePage.GoVuot), // l10n-key
            FeatureSearchEntry("Luyện vuốt", "practice swipe", FeaturePage.GoVuot), // l10n-key
            FeatureSearchEntry("Gõ tắt", "shortcut viết tắt", FeaturePage.GoTat), // l10n-key
            FeatureSearchEntry("Bảng gõ tắt", "shortcut yaml import export", FeaturePage.GoTat), // l10n-key
            FeatureSearchEntry("Mẫu câu", "template câu soạn sẵn", FeaturePage.GoTat), // l10n-key
            FeatureSearchEntry("Công cụ văn bản", "text tools hoa thường bỏ dấu dịch translate plus", FeaturePage.GoTat), // l10n-key
            FeatureSearchEntry("Dịch trên máy", "translate dịch ngôn ngữ language ml kit plus", FeaturePage.GoTat), // l10n-key
            FeatureSearchEntry("Hàng phím số", "number row số", FeaturePage.Phim), // l10n-key
            FeatureSearchEntry("Hàng số cao bằng hàng chữ", "number row tall height cao số", FeaturePage.Phim), // l10n-key
            FeatureSearchEntry("Phím cạnh dấu cách", "dấu phẩy dấu chấm cả hai comma period both key next to space", FeaturePage.Phim), // l10n-key
            FeatureSearchEntry("Về bàn chữ sau ký hiệu", "123 ký hiệu symbols bàn số quay về chữ letters tự động luôn tắt auto always", FeaturePage.Phim), // l10n-key
            FeatureSearchEntry("Cỡ phím chấm và phẩy", "larger keys phím lớn dấu phẩy dấu chấm comma period bấm nhầm phím cách", FeaturePage.Phim), // l10n-key
            FeatureSearchEntry("Nút emoji", "emoji biểu tượng cảm xúc thanh trên top bar toolbar", FeaturePage.Phim), // l10n-key
            FeatureSearchEntry("Cỡ chữ trên phím", "cỡ chữ to lớn font size label large key", FeaturePage.Phim), // l10n-key
            FeatureSearchEntry("Giữ phím hàng trên để ra số", "số giữ lâu number long press", FeaturePage.Phim), // l10n-key
            FeatureSearchEntry("Giữ phím hàng 2, 3 để ra ký tự đặc biệt", "ký hiệu symbol @ # giữ lâu long press", FeaturePage.Phim), // l10n-key
            FeatureSearchEntry("Giữ Shift để gõ số và ký hiệu", "shift giữ hold số number ký hiệu symbol 123", FeaturePage.Phim), // l10n-key
            FeatureSearchEntry("Độ nhạy con trỏ", "trackpad con trỏ cursor phím cách space kéo tốc độ nhạy sensitivity speed", FeaturePage.Phim), // l10n-key
            FeatureSearchEntry("Vuốt phím để sao chép/dán", "copy paste cut undo redo select sao chép dán cắt hoàn tác chọn hết clipboard vuốt lên swipe", FeaturePage.Phim), // l10n-key
            FeatureSearchEntry("Chế độ một tay", "one hand một tay", FeaturePage.Phim), // l10n-key
            FeatureSearchEntry("Bàn phím thả nổi", "floating nổi kéo di chuyển float", FeaturePage.Phim), // l10n-key
            FeatureSearchEntry("Phóng to chữ khi bấm", "key preview popup", FeaturePage.Phim, feedback = true), // l10n-key
            FeatureSearchEntry("Phím sẫm khi bấm", "pressed key highlight darken", FeaturePage.Phim, feedback = true), // l10n-key
            FeatureSearchEntry("Rung phím", "haptic rung vibrate", FeaturePage.Phim, feedback = true), // l10n-key
            FeatureSearchEntry("Âm thanh phím", "sound click tiếng âm lượng volume kiểu style gỗ cơ máy chữ bong bóng custom", FeaturePage.Phim, feedback = true), // l10n-key
            FeatureSearchEntry("Âm thanh gõ", "typing sound key sound style kiểu âm hệ thống system click gỗ wood đá rock pop nước water cổ điển vintage pháo firecracker tết chuông jingle bell giáng sinh piano nốt nhạc đàn tranh dan tranh zither việt nam viet nam bàn phím cơ mechanical máy chữ typewriter bong bóng bubble ding sci-fi scifi bíp beep vũ trụ space trống lân lion drum trung thu mid autumn ma quái spooky boo halloween guitar ghi ta ghi-ta đàn ghi-ta acoustic hợp âm chord búa gỗ mallet bop bíp 8-bit 8 bit chiptune chip blip retro game synth ai bíp ai nhịp club club beat hi-hat hihat kick trống điện tử edm tạ sắt iron plate keng gym", FeaturePage.Phim, feedback = true), // l10n-key
            FeatureSearchEntry("Telex cho bàn phím cứng", "bluetooth usb dex chromebook hardware", FeaturePage.Phim), // l10n-key
            FeatureSearchEntry("Theme & ảnh nền", "theme màu chủ đề wallpaper hình nền color tết tet năm mới lunar new year mai đào giáng sinh noel christmas xmas tuyết snow piano đàn dương cầm sen lotus hoa sen sen việt đàn tranh dan tranh zither việt nam viet nam máy chữ cổ typewriter vintage gaming rgb cầu vồng rainbow vũ trụ space sao star outer space trung thu mid autumn đèn lồng lantern trăng moon valentine tình yêu love tim heart halloween bí ngô pumpkin dơi bat guitar ghi ta ghi-ta đàn ghi-ta acoustic dây đàn strings đập chuột whack a mole xám trung tính neutral grey gray xám ghi gboard material you màu hình nền tím purple pixel 8-bit 8 bit retro game boy máy chơi game điểm ảnh biển sea ocean đại dương sóng wave bọt bubbles cát sand theo giờ time of day bình minh sunrise dawn hoàng hôn sunset ban ngày ban đêm night bầu trời sky ai trí tuệ nhân tạo artificial intelligence cực quang aurora mạng nơ-ron neural neon night club hộp đêm vũ trường disco quả cầu disco đèn rọi spotlight sàn nhảy dance floor led ảo giác psychedelic cầu vồng xoắn ốc swirl gym phòng tập thể hình fitness tạ sắt sàn thép cung hoàng đạo zodiac horoscope chòm sao constellation bạch dương kim ngưu song tử cự giải sư tử xử nữ thiên bình bọ cạp nhân mã ma kết bảo bình song ngư tự hào pride lgbt lgbtq cờ cầu vồng rainbow flag chuyển giới trans song tính bi toàn tính pan đồng tính nữ lesbian phi nhị nguyên non-binary nonbinary", FeaturePage.GiaoDien), // l10n-key
            FeatureSearchEntry("Độ trong suốt phím", "trong suốt transparent", FeaturePage.GiaoDien), // l10n-key
            FeatureSearchEntry("Độ trong suốt ký tự", "trong suốt transparent chữ", FeaturePage.GiaoDien), // l10n-key
            FeatureSearchEntry("Tuỳ chỉnh nâng cao", "màu chữ màu phím màu nhấn accent color colour bo góc tròn vuông corner radius cỡ chữ size phông font độ đậm weight bold đặt lại reset mặc định giao diện theme", FeaturePage.GiaoDien), // l10n-key
            FeatureSearchEntry("Dán giao diện", "json theme giao diện chép copy paste dán sửa edit nhập import tự tạo custom chia sẻ share", FeaturePage.GiaoDien), // l10n-key
            FeatureSearchEntry("Bạn đồng hành", "bạn đồng hành nhân vật thú cưng mèo gà con cô gái chàng trai buddy keyboard buddy pet character mascot cat chick girl boy nhảy dance ngủ sleep plus mắt ai ai eye quả cầu orb", FeaturePage.GiaoDien), // l10n-key
            FeatureSearchEntry("Hiệu ứng khi bấm phím", "key press effect animation hoạt ảnh trái tim heart bong bóng bubble gợn sóng ripple cánh hoa petal pháo hoa firework nháy sáng flash matrix tia sét lightning emoji theo chữ emoji words hoa đào mai tết blossom lửa combo fire mực loang ink sóng nước water wave tuyết rơi snow giáng sinh christmas sao băng shooting star meteor vũ trụ space plus đèn lồng lantern glow trung thu mid autumn sương ma khói smoke spooky mist halloween rung dây string vibration guitar ghi ta đàn ghi-ta token ai tokens trí tuệ nhân tạo kính vạn hoa kaleidoscope rep reps set hiệp gym beast mode +1 rep chòm sao constellation sao star cung hoàng đạo zodiac cầu vồng rainbow burst tự hào pride", FeaturePage.GiaoDien), // l10n-key
            FeatureSearchEntry("Đập chuột", "đập chuột trò chơi game whack a mole chuột mouse theme giao diện vui fun plus", FeaturePage.GiaoDien), // l10n-key
            FeatureSearchEntry("Màu nhấn", "accent color colour nhập enter return shift tuỳ chỉnh nâng cao", FeaturePage.GiaoDien), // l10n-key
            FeatureSearchEntry("Màu viền phím", "key border outline colour color viền phím màu viền neon tuỳ chỉnh nâng cao", FeaturePage.GiaoDien), // l10n-key
            FeatureSearchEntry("Khôi phục giao diện gốc", "reset mặc định default", FeaturePage.GiaoDien), // l10n-key
            FeatureSearchEntry("Chiều cao hàng phím", "height cao thấp", FeaturePage.GiaoDien), // l10n-key
            FeatureSearchEntry("Màu chữ gợi ý", "suggestion text color colour xám grey gray sáng bright thanh gợi ý chữ mờ dịu", FeaturePage.GiaoDien), // l10n-key
            FeatureSearchEntry("Hiện logo Vᴛ", "logo phím cách space", FeaturePage.GiaoDien), // l10n-key
            FeatureSearchEntry("Bàn phím tách đôi", "split tách chia hai nửa gập ngang fold foldable tablet máy tính bảng", FeaturePage.GiaoDien), // l10n-key
            FeatureSearchEntry("Lịch sử clipboard", "copy dán clipboard paste giữ lịch sử 24 giờ 7 ngày keep history", FeaturePage.RiengTu), // l10n-key
            FeatureSearchEntry("Chế độ ẩn danh", "incognito riêng tư privacy", FeaturePage.RiengTu), // l10n-key
            FeatureSearchEntry("Xuất / nhập file sao lưu", "backup export import restore đồng bộ sync", FeaturePage.RiengTu), // l10n-key
            FeatureSearchEntry("Phản hồi khi chạm", "touch feedback rung âm thanh phóng to haptic sound", FeaturePage.Phim, feedback = true), // l10n-key
            FeatureSearchEntry("Debug mode — ghi log chạm phím", "gỡ lỗi debug log nhật ký tester", FeaturePage.NangCao), // l10n-key
        ) + MixedTypingItem.entries.map { FeatureSearchEntry(it.viTitle, it.keywords, null, mixed = it) } +
            TypingOption.entries.map { FeatureSearchEntry(it.viTitle, it.keywords, null, typing = it) }

        /** Bỏ dấu + chữ thường ("trong suot" khớp "trong suốt"). */
        fun fold(s: String): String =
            Normalizer.normalize(s.replace('đ', 'd').replace('Đ', 'D'), Normalizer.Form.NFD)
                .replace(Regex("\\p{Mn}+"), "").lowercase(Locale.ROOT)

        /** Chữ để khớp: tên Việt + tên Anh + từ khoá — tìm được bằng cả hai ngôn ngữ. */
        private fun haystack(e: FeatureSearchEntry): String =
            fold(e.viTitle + " " + (L10nTable.EN[e.viTitle] ?: "") + " " + e.keywords)

        fun search(query: String): List<FeatureSearchEntry> {
            val words = fold(query).split(' ').filter { it.isNotBlank() }
            if (words.isEmpty()) return emptyList()
            val pages = FeaturePage.entries.map { FeatureSearchEntry(it.viTitle, "", it) }
            return (pages + all).filter { e -> haystack(e).let { h -> words.all { h.contains(it) } } }
        }
    }
}

/** Nhãn picker ngôn ngữ — giống hệt ở hai ngôn ngữ (người không đọc được tiếng Việt vẫn thấy). */
internal const val LANGUAGE_TITLE = "Ngôn ngữ / Language" // l10n-skip: song ngữ sẵn

// ---------------------------------------------------------------- khối dùng chung

@Composable
internal fun ExperimentalBadge(text: String = tr("Thử nghiệm")) {
    Text(text, style = VTType.caption2.copy(fontWeight = FontWeight.SemiBold), color = Color(0xFFAF52DE),
        modifier = Modifier.background(Color(0xFFAF52DE).copy(alpha = 0.15f), RoundedCornerShape(50))
            .padding(horizontal = 6.dp, vertical = 1.dp))
}

/** "Ngôn ngữ / Language": Tiếng Việt | English (segmented, như picker Kiểu gõ). */
@Composable
internal fun LanguagePickerRow() {
    val c = LocalVT.current
    val ctx = LocalContext.current
    val lang = UiLang.state.value
    VTRow {
        GlyphIcon(Glyph.Globe, c.accent, 20.dp)
        Text(LANGUAGE_TITLE, style = VTType.body, color = c.label,
            modifier = Modifier.weight(1f).padding(start = 12.dp, end = 8.dp))
        Row(Modifier.clip(RoundedCornerShape(9.dp)).background(c.fill).padding(2.dp)) {
            for ((code, label) in listOf(L10n.VI to "Tiếng Việt", L10n.EN to "English")) { // l10n-skip: tên ngôn ngữ giữ nguyên
                val sel = lang == code
                Box(
                    Modifier.clip(RoundedCornerShape(7.dp))
                        .background(if (sel) c.card else Color.Transparent)
                        .clickable { if (!sel) UiLang.select(ctx, code) }
                        .padding(horizontal = 12.dp, vertical = 6.dp),
                ) { Text(label, style = VTType.subheadline, color = c.label) }
            }
        }
    }
}

/** Toggle có nhãn "Thử nghiệm". */
@Composable
internal fun ExperimentalToggle(key: String, default: Boolean, title: String, caption: String, badge: String = tr("Thử nghiệm")) {
    val c = LocalVT.current
    var v by rememberBoolPref(key, default)
    VTRow(onClick = { v = !v }) {
        Column(Modifier.weight(1f).padding(end = 12.dp), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                Text(title, style = VTType.body, color = c.label)
                ExperimentalBadge(badge)
            }
            Text(caption, style = VTType.footnote, color = c.secondary)
        }
        IosSwitch(v) { v = it }
    }
}

@Composable
private fun FeatureIcon(p: FeaturePage) {
    Box(Modifier.size(29.dp).background(p.color, RoundedCornerShape(7.dp)), contentAlignment = Alignment.Center) {
        GlyphIcon(p.glyph, Color.White, 18.dp)
    }
}

@Composable
private fun FeatureRow(p: FeaturePage, title: String, subtitle: String, badge: String?, onClick: () -> Unit) {
    val c = LocalVT.current
    VTRow(onClick = onClick) {
        FeatureIcon(p)
        Column(Modifier.weight(1f).padding(start = 12.dp, end = 8.dp), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                Text(title, style = VTType.body, color = c.label)
                if (badge != null) ExperimentalBadge(badge)
            }
            Text(subtitle, style = VTType.footnote, color = c.secondary, maxLines = 1, overflow = TextOverflow.Ellipsis)
        }
        Text("›", style = VTType.title3, color = c.tertiary)
    }
}

/** Kết quả tìm trỏ về tab Kiểu Gõ (nhóm gõ lẫn tiếng Anh: icon quả địa cầu; kiểu gõ: bàn phím). */
@Composable
private fun KieuGoSearchRow(title: String, path: String, mixed: Boolean, onClick: () -> Unit) {
    val c = LocalVT.current
    VTRow(onClick = onClick) {
        Box(Modifier.size(29.dp).background(if (mixed) Color(0xFF30B0C7) else Color(0xFF007AFF), RoundedCornerShape(7.dp)),
            contentAlignment = Alignment.Center) {
            GlyphIcon(if (mixed) Glyph.Globe else Glyph.Keyboard, Color.White, 18.dp)
        }
        Column(Modifier.weight(1f).padding(start = 12.dp, end = 8.dp), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(title, style = VTType.body, color = c.label)
            Text(path, style = VTType.footnote, color = c.secondary, maxLines = 1, overflow = TextOverflow.Ellipsis)
        }
        Text("›", style = VTType.title3, color = c.tertiary)
    }
}

/** Đầu trang con: "‹ Tính Năng" (hoặc [backTitle]) + tên trang. */
@Composable
internal fun SubPageHeader(title: String, onBack: () -> Unit, backTitle: String = tr("‹ Tính Năng")) {
    val c = LocalVT.current
    BackHandler(onBack = onBack)
    VTRow(onClick = onBack) { Text(backTitle, style = VTType.body, color = c.accent) }
    Text(title, style = VTType.title2, color = c.label, modifier = Modifier.padding(start = 20.dp, top = 2.dp, bottom = 12.dp))
}

/** Link "Tìm hiểu thêm" cuối mỗi trang con. */
@Composable
internal fun GuideLinkSection(p: FeaturePage) {
    val ctx = LocalContext.current
    VTSection(footer = APPLY_NOTE) {
        LinkRow(Glyph.Info, tr("Tìm hiểu thêm trong Hướng dẫn")) { openUrl(ctx, p.guideUrl) }
    }
}

// ---------------------------------------------------------------- trang chính

@Composable
fun TinhNangTab(openRequest: FeaturePage? = null, onOpened: () -> Unit = {}, onOpenPlus: () -> Unit = {}) {
    var open by rememberSaveable { mutableStateOf<String?>(null) }
    /** Trang con "Phản hồi khi chạm" (trong Phím & cử chỉ) đang mở. */
    var feedbackOpen by rememberSaveable { mutableStateOf(false) }
    // Màn Plus chạm một quyền lợi ⇒ mở thẳng trang chứa cài đặt của nó.
    androidx.compose.runtime.LaunchedEffect(openRequest) { if (openRequest != null) { open = openRequest.name; onOpened() } }
    val page = open?.let { n -> FeaturePage.entries.firstOrNull { it.name == n } }
    if (page != null) {
        val back = { open = null; feedbackOpen = false }
        when (page) {
            FeaturePage.SuaLoi -> SuaLoiPage(back)
            FeaturePage.GoVuot -> GoVuotPage(back, onOpenPlus)
            FeaturePage.GoTat -> GoTatPage(back)
            FeaturePage.Phim -> PhimPage(back, feedbackOpen) { feedbackOpen = it }
            FeaturePage.GiaoDien -> ThemePage(back, onOpenPlus)
            FeaturePage.RiengTu -> {
                SubPageHeader(page.title, back); PrivacySection(); SaoLuuSection(onOpenPlus); GuideLinkSection(page)
            }
            FeaturePage.NangCao -> { SubPageHeader(page.title, back); DebugSection() }
        }
        return
    }
    FeatureHome { p, feedback -> open = p.name; feedbackOpen = feedback }
}

@Composable
private fun FeatureHome(onOpen: (FeaturePage, Boolean) -> Unit) {
    val c = LocalVT.current
    val ctx = LocalContext.current
    var query by rememberSaveable { mutableStateOf("") }

    val liveSpell by rememberBoolPref(Keys.LIVE_SPELL_CHECK, Prefs.D.liveSpellCheck)
    val reEdit by rememberBoolPref(Keys.RE_EDIT_WORDS, Prefs.D.reEditWords)
    val autoCorrect by rememberBoolPref(Keys.AUTO_CORRECT, Prefs.D.autoCorrect)
    val vniHome by rememberBoolPref(Keys.VNI_MODE, Prefs.D.vniMode)
    val suggestions by rememberBoolPref(Keys.SHOW_SUGGESTIONS, Prefs.D.showSuggestions)
    val numberChips by rememberBoolPref(Keys.NUMBER_CHIPS, Prefs.D.numberChips)
    val addTones by rememberBoolPref(Keys.ADD_TONES_CHIP, Prefs.D.addTonesChip)
    val swipe by rememberBoolPref(Keys.SWIPE_TYPING, Prefs.D.swipeTyping)
    val swipeFuto by rememberBoolPref(Keys.SWIPE_FUTO, Prefs.D.swipeFuto)
    val shortcutsOn by rememberBoolPref(Keys.SHORTCUTS_ENABLED, Prefs.D.shortcutsEnabled)
    val templatesOn by rememberBoolPref(Keys.TEMPLATES_ENABLED, Prefs.D.templatesEnabled)
    val numberRow by rememberBoolPref(Keys.NUMBER_ROW, Prefs.D.numberRow)
    val keyCmds by rememberBoolPref(Keys.SWIPE_KEY_COMMANDS, Prefs.D.swipeKeyCommands)
    val autoSpace by rememberBoolPref(Keys.AUTO_SPACE_AFTER_PUNCT, Prefs.D.autoSpaceAfterPunct)
    val haptic by rememberBoolPref(Keys.HAPTIC_FEEDBACK, Prefs.D.hapticFeedback)
    val keySound by rememberBoolPref(Keys.KEY_SOUND, Prefs.D.keySound)
    val oneHand by rememberStringPref(Keys.ONE_HAND_MODE, Prefs.D.oneHandMode)
    val sideKey by rememberStringPref(Keys.SPACE_SIDE_KEY, Prefs.D.spaceSideKey.id)
    val symbolReturn by rememberStringPref(Keys.SYMBOL_RETURN, Prefs.D.symbolReturn.id)
    val largeKeys by rememberBoolPref(Keys.LARGE_KEYS, Prefs.D.largeKeys)
    val phone = LocalConfiguration.current.smallestScreenWidthDp < 600
    val emojiPlace by rememberStringPref(Keys.EMOJI_KEY_PLACEMENT, Prefs.D.emojiKeyPlacement.id)
    val labelSize by rememberStringPref(Keys.KEY_LABEL_SIZE, Prefs.D.keyLabelSize.id)
    val floating by rememberBoolPref(Keys.FLOATING_KEYBOARD, Prefs.D.floatingKeyboard)
    val hardware by rememberBoolPref(Keys.HARDWARE_TELEX, Prefs.D.hardwareTelex)
    val clipHistory by rememberBoolPref(Keys.CLIPBOARD_HISTORY, Prefs.D.clipboardHistory)
    val incognito by rememberBoolPref(Keys.INCOGNITO, Prefs.D.incognito)
    val debugLog by rememberBoolPref(Keys.DEBUG_TOUCH_LOG, Prefs.D.debugTouchLog)
    val shortcutCount = remember { ShortcutsStore.load(ctx).size }
    val theme = remember { loadThemeSettings(ctx) }
    val wallpaperOn = remember { theme.wallpaperActive(WallpaperStore.file(ctx).exists()) }

    fun join(vararg parts: Pair<Boolean, String>, none: String) =
        parts.filter { it.first }.joinToString(" · ") { it.second }.ifEmpty { none }

    fun summary(p: FeaturePage): String = when (p) {
        FeaturePage.SuaLoi -> join(liveSpell to tr("Kiểm tra chính tả"), reEdit to tr("Sửa dấu"),
            (autoCorrect && !vniHome) to tr("Tự sửa"), suggestions to tr("Thanh gợi ý"), (suggestions && numberChips) to tr("Số tiền"),
            (suggestions && addTones && PlusGate.isUnlocked(PlusFeature.SENTENCE_DIACRITICS)) to tr("Thêm dấu"), none = tr("Đang tắt"))
        FeaturePage.GoVuot -> if (!swipe) tr("Đang tắt") else join(true to tr("Bật"), swipeFuto to "Neural", none = "")
        FeaturePage.GoTat -> (if (!shortcutsOn) tr("Gõ tắt tắt") else if (shortcutCount == 0) tr("Gõ tắt bật") else tr("Gõ tắt: %d mục", shortcutCount)) +
            " · " + if (templatesOn) tr("Mẫu câu bật") else tr("Mẫu câu tắt")
        FeaturePage.Phim -> join(numberRow to tr("Hàng số"),
            (SpaceSideKey.of(sideKey) != SpaceSideKey.DEFAULT) to tr("Phím cạnh dấu cách"),
            (largeKeys && phone && SpaceSideKey.of(sideKey).showsLargeKeysSetting) to tr("Cỡ phím chấm và phẩy"),
            (EmojiKeyPlacement.of(emojiPlace) != EmojiKeyPlacement.DEFAULT) to tr("Nút emoji"),
            (KeyLabelSize.of(labelSize) != KeyLabelSize.DEFAULT) to tr("Cỡ chữ trên phím"),
            keyCmds to tr("Vuốt sao chép/dán"),
            autoSpace to tr("Cách sau dấu câu"),
            (SymbolReturn.of(symbolReturn) != SymbolReturn.DEFAULT) to tr("Về bàn chữ sau ký hiệu"),
            haptic to tr("Rung"), keySound to tr("Âm"),
            (oneHand != "off") to tr("Một tay"), floating to tr("Thả nổi"), hardware to tr("Bàn phím cứng"), none = tr("Mặc định"))
        FeaturePage.GiaoDien -> theme.effectiveTheme.title + (if (wallpaperOn) " · " + tr("Ảnh nền") else "") +
            if (theme.keyboardTransparency > 0 || theme.labelTransparency > 0) " · " + tr("Trong suốt") else ""
        FeaturePage.RiengTu -> (if (clipHistory) tr("Lịch sử clipboard bật") else tr("Lịch sử clipboard tắt")) +
            (if (incognito) " · " + tr("Ẩn danh") else "") + " · " + tr("Xuất / nhập file")
        FeaturePage.NangCao -> if (debugLog) tr("Đang ghi log chạm phím") else tr("Ghi log chạm phím cho tester")
    }

    // Ngôn ngữ giao diện — mục ĐẦU TIÊN của Tính Năng, nhãn song ngữ (ai không đọc được tiếng
    // Việt vẫn tìm ra). Đổi là áp dụng ngay cho cả app (L10n → recompose), bàn phím lần hiện kế.
    VTSection { LanguagePickerRow() }

    VTSection {
        VTRow {
            GlyphIcon(Glyph.Search, c.secondary, 18.dp)
            Box(Modifier.weight(1f).padding(start = 10.dp)) {
                VTTextField(query, { query = it }, tr("Tìm cài đặt…"), capitalization = KeyboardCapitalization.None)
            }
            if (query.isNotEmpty()) {
                Text("✕", style = VTType.body, color = c.tertiary,
                    modifier = Modifier.clickable { query = "" }.padding(start = 8.dp))
            }
        }
    }

    if (query.isBlank()) {
        FeaturePage.groups.forEach { group ->
            VTSection {
                group.forEachIndexed { i, p ->
                    if (i > 0) RowDivider(57.dp)
                    FeatureRow(p, p.title, summary(p), p.badgeVi?.let { tr(it) }) { onOpen(p, false) }
                }
            }
        }
    } else {
        val hits = FeatureSearchEntry.search(query)
        VTSection(header = tr("Kết quả")) {
            if (hits.isEmpty()) VTRow { Text(tr("Không tìm thấy cài đặt nào."), style = VTType.body, color = c.secondary) }
            hits.forEachIndexed { i, e ->
                if (i > 0) RowDivider(57.dp)
                val p = e.page
                val target = e.kieuGoTarget
                if (p != null) {
                    val isPage = e.isPage
                    // Dòng phụ = đường dẫn tới chỗ của cài đặt (vd "Tính Năng › Phím & cử chỉ › Phản hồi khi chạm").
                    FeatureRow(p, e.title, if (isPage) summary(p) else e.path, if (isPage) p.badgeVi?.let { tr(it) } else null) { onOpen(p, e.feedback) }
                } else if (target != null) {
                    // Tab Kiểu Gõ: RootScreen đổi tab, KieuGoTab mở đúng trang/nhóm + cuộn tới dòng.
                    KieuGoSearchRow(e.title, e.path, e.mixed != null) { KieuGoNav.request.value = target }
                }
            }
        }
    }
}

// ---------------------------------------------------------------- trang con

/**
 * "Sửa lỗi & gợi ý" (SETTINGS-CLEANUP-SPEC §4): gộp "Chính tả & sửa lỗi" + "Gợi ý & từ điển". Ba
 * mục sửa chạm trượt giữ công tắc riêng, xếp liền nhau (gợi ý sửa từ tab Kiểu Gõ chuyển về đây).
 */
@Composable
private fun SuaLoiPage(onBack: () -> Unit) {
    val c = LocalVT.current
    val ctx = LocalContext.current
    SubPageHeader(FeaturePage.SuaLoi.title, onBack)
    VTSection(header = tr("Chính tả")) {
        BoolToggle(Keys.LIVE_SPELL_CHECK, Prefs.D.liveSpellCheck, tr("Kiểm tra chính tả khi gõ"), tr(SettingCaption.liveSpellCheck))
        RowDivider()
        BoolToggle(Keys.RE_EDIT_WORDS, Prefs.D.reEditWords, tr("Sửa dấu từ đã gõ"), tr(SettingCaption.reEditWord))
        RowDivider()
        BoolToggle(Keys.AUTO_CIRCUMFLEX, Prefs.D.autoCircumflex, tr("Tự thêm dấu mũ"), tr(SettingCaption.autoCircumflex))
    }
    // Phụ thuộc (SETTINGS-CLEANUP-SPEC §6): mục cha ở nhóm/trang khác ⇒ mờ + lý do; cùng nhóm ⇒ ẩn.
    val vni by rememberBoolPref(Keys.VNI_MODE, Prefs.D.vniMode)
    val suggestions by rememberBoolPref(Keys.SHOW_SUGGESTIONS, Prefs.D.showSuggestions)
    VTSection(header = tr("Chạm trượt"), footer = tr(SettingCaption.adjacentFooter)) {
        DependentToggle(Keys.AUTO_FIX_ADJACENT, Prefs.D.autoFixAdjacent, tr("Gợi ý sửa lỗi chạm trượt"),
            tr(SettingCaption.autoFixAdjacent), SettingDeps.autoFixAdjacentReason(suggestions)?.let { tr(it) })
        RowDivider()
        DependentToggle(Keys.SMART_TOUCH, Prefs.D.smartTouch, tr("Chọn phím thông minh"), tr(SettingCaption.smartTouch),
            SettingDeps.telexOnlyReason(vni)?.let { tr(it) }, experimental = true, indent = false)
        RowDivider()
        DependentToggle(Keys.AUTO_CORRECT, Prefs.D.autoCorrect, tr("Tự sửa từ gõ sai"), tr(SettingCaption.autoCorrect),
            SettingDeps.telexOnlyReason(vni)?.let { tr(it) }, experimental = true, indent = false)
    }
    VTSection(header = tr("Thanh gợi ý")) {
        SettingDeps.suggestionRows(suggestions).forEachIndexed { i, row ->
            if (i > 0) RowDivider()
            when (row) {
                SettingDeps.SuggestionRow.Toggle ->
                    BoolToggle(Keys.SHOW_SUGGESTIONS, Prefs.D.showSuggestions, tr("Thanh gợi ý"), tr(SettingCaption.showSuggestions))
                SettingDeps.SuggestionRow.Count -> SuggestionCountRow()
                SettingDeps.SuggestionRow.DismissButton ->
                    BoolToggle(Keys.KEYBOARD_DISMISS_BUTTON, Prefs.D.keyboardDismissButton, tr("Nút ẩn bàn phím"),
                        tr(SettingCaption.keyboardDismissButton))
                SettingDeps.SuggestionRow.InNoSuggestFields ->
                    BoolToggle(Keys.SUGGEST_IN_NO_SUGGEST_FIELDS, Prefs.D.suggestInNoSuggestFields, tr("Gợi ý cả khi ứng dụng tắt gợi ý"),
                        tr(SettingCaption.suggestInNoSuggestFields))
                SettingDeps.SuggestionRow.NumberChips ->
                    BoolToggle(Keys.NUMBER_CHIPS, Prefs.D.numberChips, tr("Gợi ý số tiền"), tr(SettingCaption.numberChips))
                SettingDeps.SuggestionRow.MathResults ->
                    BoolToggle(Keys.MATH_RESULTS, Prefs.D.mathResults, tr("Hiện kết quả phép tính"), tr(SettingCaption.mathResults))
                // Plus: chưa mở khoá ⇒ dòng khoá (không là công tắc bật được), như Công cụ văn bản.
                SettingDeps.SuggestionRow.AddTones ->
                    if (PlusGate.isUnlocked(PlusFeature.SENTENCE_DIACRITICS))
                        BoolToggle(Keys.ADD_TONES_CHIP, Prefs.D.addTonesChip, tr("Thêm dấu"), tr(SettingCaption.addTones))
                    else PlusLockedRow(tr("Thêm dấu"), tr(SettingCaption.addTones))
                SettingDeps.SuggestionRow.FilterSensitive ->
                    BoolToggle(Keys.FILTER_SENSITIVE, Prefs.D.filterSensitive, tr("Lọc từ nhạy cảm"), tr(SettingCaption.filterSensitive))
            }
        }
    }
    VTSection(header = tr("Từ đã học")) {
        UserDictRow()
        RowDivider()
        // Xoá không hoàn tác được ⇒ hỏi lại; xong thì báo ngay tại dòng.
        var confirmErase by remember { mutableStateOf(false) }
        var erased by remember { mutableStateOf(false) }
        VTRow(onClick = { confirmErase = true }) {
            Text(tr("Xóa từ đã học"), style = VTType.body, color = c.red, modifier = Modifier.weight(1f))
            if (erased) Text(tr("Đã xoá"), style = VTType.footnote, color = c.secondary)
        }
        if (confirmErase) androidx.compose.material3.AlertDialog(
            onDismissRequest = { confirmErase = false },
            title = { Text(tr("Xóa từ đã học?")) },
            text = { Text(tr("Bàn phím quên mọi từ đã học trên máy này, kể cả từ thêm tay trong từ điển cá nhân. Không hoàn tác được.")) },
            confirmButton = {
                androidx.compose.material3.TextButton(onClick = {
                    confirmErase = false
                    java.io.File(ctx.filesDir, Keys.USERLM_FILE).delete()
                    // IME (process khác) nhận mốc đổi qua PrefSync ⇒ bỏ model trong RAM, seed lại, không ghi đè.
                    Prefs.of(ctx).edit().putLong(Keys.USERLM_RESET_AT, System.currentTimeMillis()).apply()
                    erased = true
                }) { Text(tr("Xoá"), color = c.red) }
            },
            dismissButton = { androidx.compose.material3.TextButton(onClick = { confirmErase = false }) { Text(tr("Huỷ"), color = c.accent) } },
        )
    }
    GuideLinkSection(FeaturePage.SuaLoi)
}

@Composable
private fun GoVuotPage(onBack: () -> Unit, onOpenPlus: () -> Unit = {}) {
    val c = LocalVT.current
    val ctx = LocalContext.current
    /** Trang con "Hiệu ứng nét vuốt" đang mở. */
    var pickingTrail by remember { mutableStateOf(false) }
    if (pickingTrail) { SwipeTrailPage(onOpenPlus = onOpenPlus, onBack = { pickingTrail = false }); return }
    /** Trang con "Âm thanh nét vuốt" đang mở. */
    var pickingSound by remember { mutableStateOf(false) }
    if (pickingSound) { SwipeSoundPage(onOpenPlus = onOpenPlus, onBack = { pickingSound = false }); return }
    val soundRaw by rememberStringPref(Keys.SWIPE_SOUND, com.viettelex.keyboard.SwipeSoundStyle.DEFAULT.id)
    val trailRaw by rememberStringPref(Keys.SWIPE_TRAIL, com.viettelex.keyboard.SwipeTrailStyle.DEFAULT.id)
    SubPageHeader(FeaturePage.GoVuot.title, onBack)
    val swipeOn by rememberBoolPref(Keys.SWIPE_TYPING, Prefs.D.swipeTyping)
    // Gõ vuốt tắt ⇒ ẩn mọi mục con của trang (SETTINGS-CLEANUP-SPEC §6), bật lại là hiện tại chỗ.
    val rows = SettingDeps.swipeRows(swipeOn)
    VTSection(footer = tr("Tự tắt khi bật TalkBack và ở ô mật khẩu, email, địa chỉ web.")) {
        ExperimentalToggle(Keys.SWIPE_TYPING, Prefs.D.swipeTyping, tr("Gõ vuốt"),
            tr(SettingCaption.swipeTyping), badge = tr("Máy học"))
        // "Vuốt từ tiếng Anh" ngay dưới công tắc Gõ vuốt (SETTINGS-CLEANUP-SPEC §1). Bộ chọn hồ sơ
        // (Kiểu Gõ › Gõ lẫn tiếng Anh) vẫn đặt cùng key.
        if (SettingDeps.SwipeRow.SwipeEnglish in rows) {
            RowDivider()
            DependentToggle(Keys.SWIPE_ENGLISH, Prefs.D.swipeEnglish, tr("Vuốt từ tiếng Anh"),
                tr(SettingCaption.swipeEnglish), null, indent = true)
        }
        if (SettingDeps.SwipeRow.NeuralModel in rows) {
            RowDivider()
            BoolToggle(Keys.SWIPE_FUTO, Prefs.D.swipeFuto, tr("Mô hình neural gõ vuốt"),
                tr(SettingCaption.swipeFuto))
            // Ghi công BẮT BUỘC theo FUTO Model Weights License 1.0 ("visible notice … within
            // the product's settings") — Phil 27/09/2026: chỉ hiện ở đây (dưới công tắc, khi đã
            // bật Gõ vuốt), chữ nhỏ mờ. KHÔNG xoá. Xem docs/DATA-SOURCES.md.
            VTRow(onClick = { openUrl(ctx, "https://github.com/ptrinh/viettelex/blob/main/docs/DATA-SOURCES.md#futo-swipe") }) {
                Text("powered by FUTO Swipe", style = VTType.caption2, color = c.tertiary)
            }
        }
    }
    if (SettingDeps.SwipeRow.Trail in rows) VTSection {
        VTRow(onClick = { pickingTrail = true }) {
            val plus = com.viettelex.keyboard.SwipeTrailGate.allows
            Text(tr("Hiệu ứng nét vuốt") + if (plus) "" else " · Plus", style = VTType.body, color = c.label,
                modifier = Modifier.weight(1f))
            Text("${com.viettelex.keyboard.SwipeTrailStyle.displayed(trailRaw).title} ›", style = VTType.body,
                color = c.secondary, maxLines = 1)
        }
        if (SettingDeps.SwipeRow.TrailSound in rows) {
            RowDivider()
            VTRow(onClick = { pickingSound = true }) {
                val plus = com.viettelex.keyboard.SwipeSoundGate.allows
                Text(tr("Âm thanh nét vuốt") + if (plus) "" else " · Plus", style = VTType.body, color = c.label,
                    modifier = Modifier.weight(1f))
                Text("${com.viettelex.keyboard.SwipeSoundStyle.displayed(soundRaw).title} ›", style = VTType.body,
                    color = c.secondary, maxLines = 1)
            }
        }
    }
    if (SettingDeps.SwipeRow.Practice in rows) {
        VTSection {
            var showPractice by remember { mutableStateOf(false) }
            VTRow(onClick = { showPractice = true }) {
                Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                    Text(tr("Luyện vuốt"), style = VTType.body, color = c.label)
                    Text(tr(SettingCaption.swipePractice), style = VTType.footnote, color = c.secondary)
                }
                Text("›", style = VTType.title3, color = c.tertiary)
            }
            if (showPractice) SwipePracticeDialog { showPractice = false }
        }
    }
    GuideLinkSection(FeaturePage.GoVuot)
}

@Composable
private fun GoTatPage(onBack: () -> Unit) {
    // Trang con "Bảng gõ tắt" (như NavigationLink iOS) — ⟵ hệ thống quay lại.
    var showShortcuts by rememberSaveable { mutableStateOf(false) }
    if (showShortcuts) { ShortcutsPage { showShortcuts = false }; return }
    SubPageHeader(FeaturePage.GoTat.title, onBack)
    ShortcutsSection { showShortcuts = true }
    VTSection(header = tr("Mẫu câu")) {
        BoolToggle(Keys.TEMPLATES_ENABLED, Prefs.D.templatesEnabled, tr("Mẫu câu"), tr(SettingCaption.templates))
        RowDivider()
        // Luôn hiện (tìm "Công cụ văn bản" phải tới được đây); chưa có Plus ⇒ dòng khoá.
        if (PlusGate.isUnlocked(PlusFeature.TEXT_TOOLS)) {
            BoolToggle(Keys.TEXT_TOOLS_ENABLED, Prefs.D.textToolsEnabled, tr("Công cụ văn bản"),
                tr(SettingCaption.textTools))
        } else PlusLockedRow(tr("Công cụ văn bản"), tr(SettingCaption.textTools))
    }
    // Dịch trên máy (Plus): cài đặt ở đây (cạnh Công cụ).
    VTSection(header = PlusFeature.TRANSLATE.title) {
        if (PlusGate.isUnlocked(PlusFeature.TRANSLATE)) TranslateSettings(leadingDivider = false)
        else PlusLockedRow(PlusFeature.TRANSLATE.title, PlusFeature.TRANSLATE.detail)
    }
    GuideLinkSection(FeaturePage.GoTat)
}

/** Tính năng Plus chưa mở khoá: vẫn hiện (tìm kiếm tới được) với nhãn khoá, không công tắc. */
@Composable
private fun PlusLockedRow(title: String, caption: String) {
    val c = LocalVT.current
    VTRow {
        Column(Modifier.weight(1f).padding(end = 12.dp), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(title, style = VTType.body, color = c.secondary)
            Text(caption, style = VTType.footnote, color = c.secondary)
        }
        Text(tr("🔒 Plus"), style = VTType.footnote, color = c.accent)
    }
}

/** Hàng chọn một trong vài giá trị chuỗi (nút bấm chia đều): tiêu đề + chú thích + các ô. */
@Composable
internal fun ChoiceRow(key: String, default: String, title: String, caption: String,
                      options: List<Pair<String, String>>, normalize: (String) -> String = { it }) {
    val c = LocalVT.current
    var mode by rememberStringPref(key, default)
    VTRow {
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(title, style = VTType.body, color = c.label)
            Text(caption, style = VTType.footnote, color = c.secondary)
        }
    }
    Row(Modifier.fillMaxWidth().padding(start = 16.dp, end = 16.dp, bottom = 12.dp),
        horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        for ((v, t) in options) {
            val on = normalize(mode) == v
            Box(Modifier.weight(1f)
                .background(if (on) c.accent else c.secondary.copy(alpha = 0.12f), RoundedCornerShape(10.dp))
                .clickable { mode = v }
                .padding(vertical = 8.dp), contentAlignment = Alignment.Center) {
                // 4 ô trên điện thoại hẹp ⇒ chữ nhỏ hơn một bậc cho vừa một dòng.
                Text(t, style = if (options.size > 3) VTType.subheadline else VTType.body, maxLines = 1,
                    color = if (on) Color.White else c.label)
            }
        }
    }
}

/**
 * "Phím cạnh dấu cách": Dấu phẩy (mặc định) / Dấu chấm / Cả hai / Tắt — bàn chữ ô thường
 * (điện thoại: phím hẹp, Cả hai = "," trái + "." phải; tablet: "," "." hai bên space hoặc không).
 */
@Composable
private fun SpaceSideKeyRow() = ChoiceRow(Keys.SPACE_SIDE_KEY, Prefs.D.spaceSideKey.id, tr("Phím cạnh dấu cách"),
    tr(SettingCaption.spaceSideKey),
    listOf(SpaceSideKey.COMMA.id to tr("Phẩy"), SpaceSideKey.PERIOD.id to tr("Chấm"),
        SpaceSideKey.BOTH.id to tr("Cả hai"), SpaceSideKey.OFF.id to tr("Tắt"))) { SpaceSideKey.of(it).id }

/**
 * "Về bàn chữ sau ký hiệu": Tự động / Luôn / Tắt (mặc định) — [SymbolReturn]. Cùng khoá + giá trị iOS.
 */
@Composable
private fun SymbolReturnRow() = ChoiceRow(Keys.SYMBOL_RETURN, Prefs.D.symbolReturn.id, tr("Về bàn chữ sau ký hiệu"),
    tr(SettingCaption.symbolReturn),
    listOf(SymbolReturn.AUTO.id to tr("Tự động"), SymbolReturn.ALWAYS.id to tr("Luôn"),
        SymbolReturn.OFF.id to tr("Tắt"))) { SymbolReturn.of(it).id }

/**
 * "Số từ gợi ý" ([SuggestionCount]): một hàng gọn − [giá trị] +, Tự động → 1 → … → 5 (− ở 1 về
 * Tự động; hai đầu thì nút mờ). Cùng khoá + giá trị iOS.
 */
@Composable
private fun SuggestionCountRow() {
    val c = LocalVT.current
    var v by rememberIntPref(Keys.SUGGESTION_COUNT, Prefs.D.suggestionCount)
    val n = SuggestionCount.parse(v)
    val value = if (n <= SuggestionCount.AUTO) tr("Tự động") else n.toString()
    VTRow {
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(tr("Số từ gợi ý"), style = VTType.body, color = c.label)
            Text(tr(SettingCaption.suggestionCount),
                style = VTType.footnote, color = c.secondary)
        }
        Row(Modifier.padding(start = 8.dp).clip(RoundedCornerShape(9.dp)).background(c.fill),
            verticalAlignment = Alignment.CenterVertically) {
            StepButton("−", tr("Bớt một từ gợi ý"), n > SuggestionCount.AUTO) { v = SuggestionCount.step(n, -1) }
            Text(value, style = VTType.body, color = c.label, textAlign = TextAlign.Center, maxLines = 1,
                modifier = Modifier.widthIn(min = 64.dp).semantics { contentDescription = tr("Số từ gợi ý") + ": " + value })
            StepButton("+", tr("Thêm một từ gợi ý"), n < SuggestionCount.MAX) { v = SuggestionCount.step(n, 1) }
        }
    }
}

@Composable
private fun StepButton(symbol: String, description: String, enabled: Boolean, onClick: () -> Unit) {
    val c = LocalVT.current
    Box(Modifier.size(44.dp).clickable(enabled = enabled, onClick = onClick).semantics { contentDescription = description },
        contentAlignment = Alignment.Center) {
        Text(symbol, style = VTType.title3, color = if (enabled) c.accent else c.tertiary)
    }
}

/** "Nút emoji": Hàng dưới (mặc định) / Thanh trên — [EmojiKeyPlacement]. */
@Composable
private fun EmojiPlacementRow() = ChoiceRow(Keys.EMOJI_KEY_PLACEMENT, Prefs.D.emojiKeyPlacement.id, tr("Nút emoji"),
    tr(SettingCaption.emojiKeyPlacement),
    listOf(EmojiKeyPlacement.BOTTOM.id to tr("Hàng dưới"), EmojiKeyPlacement.TOP.id to tr("Thanh trên"))) { EmojiKeyPlacement.of(it).id }

/** "Cỡ chữ trên phím": Vừa (mặc định) / Lớn — [KeyLabelSize]. */
@Composable
private fun KeyLabelSizeRow() = ChoiceRow(Keys.KEY_LABEL_SIZE, Prefs.D.keyLabelSize.id, tr("Cỡ chữ trên phím"),
    tr(SettingCaption.keyLabelSize),
    listOf(KeyLabelSize.MEDIUM.id to tr("Vừa"), KeyLabelSize.LARGE.id to tr("Lớn"))) { KeyLabelSize.of(it).id }

@Composable
private fun PhimPage(onBack: () -> Unit, feedbackOpen: Boolean, setFeedbackOpen: (Boolean) -> Unit) {
    if (feedbackOpen) { FeedbackPage { setFeedbackOpen(false) }; return }
    SubPageHeader(FeaturePage.Phim.title, onBack)
    val numberRow by rememberBoolPref(Keys.NUMBER_ROW, Prefs.D.numberRow)
    VTSection(header = tr("Phím")) {
        BoolToggle(Keys.NUMBER_ROW, Prefs.D.numberRow, tr("Hàng phím số"), tr(SettingCaption.numberRow))
        RowDivider()
        // Chỉ hiện khi hàng số bật (tắt hàng số thì công tắc này vô nghĩa, giá trị vẫn giữ).
        if (numberRow) {
            BoolToggle(Keys.NUMBER_ROW_FULL_HEIGHT, Prefs.D.numberRowFullHeight, tr("Hàng số cao bằng hàng chữ"),
                tr(SettingCaption.numberRowFullHeight))
            RowDivider()
        }
        SpaceSideKeyRow()
        RowDivider()
        // "Phím to" — chỉ điện thoại (tablet: bàn phím bỏ qua, KeyLayout.largeKeysActive). Miễn phí.
        val sideKeyId by rememberStringPref(Keys.SPACE_SIDE_KEY, Prefs.D.spaceSideKey.id)
        if (LocalConfiguration.current.smallestScreenWidthDp < 600 && SpaceSideKey.of(sideKeyId).showsLargeKeysSetting) {
            BoolToggle(Keys.LARGE_KEYS, Prefs.D.largeKeys, tr("Cỡ phím chấm và phẩy"),
                tr(SettingCaption.largeKeys))
            RowDivider()
        }
        EmojiPlacementRow()
        RowDivider()
        KeyLabelSizeRow()
        RowDivider()
        // Hàng số bật ⇒ giữ q…p ra số vô nghĩa (KeyAlternates.numbersSettingVisible).
        if (KeyAlternates.numbersSettingVisible(numberRow)) {
            BoolToggle(Keys.LONG_PRESS_NUMBERS, Prefs.D.longPressNumbers, tr("Giữ phím hàng trên để ra số"), tr(SettingCaption.longPressNumbers))
            RowDivider()
        }
        BoolToggle(Keys.LONG_PRESS_SYMBOLS, Prefs.D.longPressSymbols, tr("Giữ phím hàng 2, 3 để ra ký tự đặc biệt"),
            tr(SettingCaption.longPressSymbols))
        RowDivider()
        BoolToggle(Keys.HOLD_SHIFT_SYMBOLS, Prefs.D.holdShiftSymbols, tr("Giữ Shift để gõ số và ký hiệu"),
            tr(SettingCaption.holdShiftSymbols))
        RowDivider()
        BoolToggle(Keys.FLICK_DOWN_ALTERNATES, Prefs.D.flickDownAlternates, tr("Vuốt phím xuống để gõ số và ký hiệu"),
            tr(SettingCaption.flickDownAlternates))
        RowDivider()
        BoolToggle(Keys.AUTO_SPACE_AFTER_PUNCT, Prefs.D.autoSpaceAfterPunct, tr("Tự thêm dấu cách sau dấu câu"),
            tr(SettingCaption.autoSpaceAfterPunct))
        RowDivider()
        SymbolReturnRow()
    }
    // "Vuốt phím cách đổi Tiếng Việt / Tiếng Anh" chuyển sang nhóm "Gõ lẫn tiếng Anh" (tab Kiểu Gõ).
    VTSection(header = tr("Cử chỉ")) {
        // "Độ nhạy con trỏ" Chậm / Vừa (mặc định) / Nhanh — TrackpadSpeed, cùng khoá iOS.
        ChoiceRow(Keys.TRACKPAD_SPEED, Prefs.D.trackpadSpeed.id, tr("Độ nhạy con trỏ"),
            tr(SettingCaption.trackpadSpeed),
            listOf(com.viettelex.keyboard.TrackpadSpeed.SLOW.id to tr("Chậm"),
                com.viettelex.keyboard.TrackpadSpeed.MEDIUM.id to tr("Vừa"),
                com.viettelex.keyboard.TrackpadSpeed.FAST.id to tr("Nhanh"))) {
            com.viettelex.keyboard.TrackpadSpeed.of(it).id
        }
        RowDivider()
        BoolToggle(Keys.SWIPE_KEY_COMMANDS, Prefs.D.swipeKeyCommands, tr("Vuốt phím để sao chép/dán"),
            tr(SettingCaption.swipeKeyCommandsAndroid))
        RowDivider()
        OneHandRow()
        RowDivider()
        BoolToggle(Keys.FLOATING_KEYBOARD, Prefs.D.floatingKeyboard, tr("Bàn phím thả nổi"),
            tr(SettingCaption.floatingKeyboard))
    }
    // "Phản hồi khi chạm" (rung, âm thanh, phóng to/sẫm phím) tách thành trang con (SETTINGS-CLEANUP-SPEC §4).
    val preview by rememberBoolPref(Keys.KEY_PREVIEW, Prefs.D.keyPreview)
    val haptic by rememberBoolPref(Keys.HAPTIC_FEEDBACK, Prefs.D.hapticFeedback)
    val sound by rememberBoolPref(Keys.KEY_SOUND, Prefs.D.keySound)
    VTSection {
        NavRow(tr(FEEDBACK_TITLE), listOf(haptic to tr("Rung"), sound to tr("Âm"), preview to tr("Phóng to chữ"))
            .filter { it.first }.joinToString(" · ") { it.second }.ifEmpty { tr("Đang tắt") }) { setFeedbackOpen(true) }
    }
    VTSection(header = tr("Bàn phím cứng")) {
        BoolToggle(Keys.HARDWARE_TELEX, Prefs.D.hardwareTelex, tr("Telex cho bàn phím cứng"),
            tr(SettingCaption.hardwareTelex))
    }
    GuideLinkSection(FeaturePage.Phim)
}

/** Trang con "Phản hồi khi chạm" của Phím & cử chỉ. */
@Composable
private fun FeedbackPage(onBack: () -> Unit) {
    var pickingSound by remember { mutableStateOf(false) }
    if (pickingSound) { KeySoundPage(onBack = { pickingSound = false }); return }
    SubPageHeader(tr(FEEDBACK_TITLE), onBack, backTitle = "‹ " + FeaturePage.Phim.title)
    VTSection(footer = APPLY_NOTE) {
        BoolToggle(Keys.KEY_PREVIEW, Prefs.D.keyPreview, tr("Phóng to chữ khi bấm"), tr(SettingCaption.keyPreview))
        RowDivider()
        BoolToggle(Keys.KEY_PRESS_HIGHLIGHT, Prefs.D.keyPressHighlight, tr("Phím sẫm khi bấm"),
            tr(SettingCaption.keyPressHighlight))
        RowDivider()
        BoolToggle(Keys.HAPTIC_FEEDBACK, Prefs.D.hapticFeedback, tr("Rung phím"), tr(SettingCaption.hapticFeedback))
        HapticStrengthRow()
        RowDivider()
        KeySoundRows(onOpenStyles = { pickingSound = true })
    }
}

/** Nghe/rung thử dùng chung cho trang Phím (nhả AudioTrack khi rời trang). */
@Composable
private fun rememberPreview(): KeyFeedbackPreview {
    val ctx = LocalContext.current
    val p = remember { KeyFeedbackPreview(ctx) }
    DisposableEffect(Unit) { onDispose { p.release() } }
    return p
}

/** Thanh trượt "Độ mạnh rung" 10…100 % dưới công tắc Rung phím (chỉ hiện khi bật) — giống iOS.
 *  Kéo ⇒ rung thử đúng độ mạnh (≤ 1 lần / 120 ms + lúc thả). */
@Composable
private fun HapticStrengthRow() {
    val on by rememberBoolPref(Keys.HAPTIC_FEEDBACK, Prefs.D.hapticFeedback)
    if (!on) return
    val c = LocalVT.current
    var pct by rememberIntPref(Keys.HAPTIC_STRENGTH, Prefs.D.hapticStrength)
    val preview = rememberPreview()
    val throttle = remember { PreviewThrottle() }
    fun fire(final: Boolean) {
        if (throttle.shouldFire(pct, SystemClock.uptimeMillis(), final)) preview.playHaptic(pct)
    }
    RowDivider()
    Column(Modifier.padding(horizontal = 16.dp, vertical = 8.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(tr("Độ mạnh rung"), style = VTType.body, color = c.label, modifier = Modifier.weight(1f))
            Text("${HapticStrength.clamp(pct)}%", style = VTType.body, color = c.secondary)
        }
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Text(tr("Nhẹ"), style = VTType.footnote, color = c.secondary)
            Slider(value = HapticStrength.clamp(pct).toFloat(), valueRange = 10f..100f, steps = 17,
                onValueChange = { v -> val n = HapticStrength.clamp(Math.round(v / 5) * 5); if (n != pct) { pct = n; fire(false) } },
                onValueChangeFinished = { fire(true) },
                modifier = Modifier.weight(1f))
            Text(tr("Mạnh"), style = VTType.footnote, color = c.secondary)
        }
    }
}

/** Âm thanh phím riêng: công tắc + hàng "Âm thanh gõ" (kiểu đang chọn ›) mở [KeySoundPage] — chỉ
 *  hiện khi bật. [com.viettelex.keyboard.KeySoundSynth]. */
@Composable
private fun KeySoundRows(onOpenStyles: () -> Unit) {
    val c = LocalVT.current
    val on by rememberBoolPref(Keys.KEY_SOUND, Prefs.D.keySound)
    BoolToggle(Keys.KEY_SOUND, Prefs.D.keySound, tr("Âm thanh phím"),
        tr(SettingCaption.keySound))
    if (!on) return
    val style by rememberStringPref(Keys.KEY_SOUND_STYLE, Prefs.D.keySoundStyle)
    RowDivider()
    VTRow(onClick = onOpenStyles) {
        Text(tr("Âm thanh gõ"), style = VTType.body, color = c.label, modifier = Modifier.weight(1f))
        Text("${tr(KeySoundStyle.resolve(style, true).viTitle)} ›", style = VTType.body, color = c.secondary, maxLines = 1)
    }
}

/**
 * "Âm thanh gõ" (Phil 19/10/2026): chọn kiểu âm phím — "Hệ thống" đầu, 11 kiểu tổng hợp + Piano, "Âm của
 * bạn" cuối. Chạm một kiểu = chọn + nghe thử chữ → xoá → phím chức năng. Âm lượng + nhập âm tự
 * chọn ở đây (iOS: KeySoundStylePage, cùng bố cục). Mọi kiểu miễn phí.
 */
@Composable
private fun KeySoundPage(onBack: () -> Unit) {
    val c = LocalVT.current
    val ctx = LocalContext.current
    var vol by rememberIntPref(Keys.KEY_SOUND_VOLUME, Prefs.D.keySoundVolume)
    var style by rememberStringPref(Keys.KEY_SOUND_STYLE, Prefs.D.keySoundStyle)
    var customDuration by remember { mutableStateOf(KeySoundImport.storedDuration(ctx)) }
    var notice by remember { mutableStateOf<String?>(null) }
    var styleBeforeImport by remember { mutableStateOf<String?>(null) }
    val preview = rememberPreview()
    val throttle = remember { PreviewThrottle() }
    val audible = { maxOf(vol, 20) }
    val current = KeySoundStyle.resolve(style, true)

    val importer = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
        val before = styleBeforeImport
        styleBeforeImport = null
        if (uri == null) {
            if (customDuration == null && style == KeySoundStyle.CUSTOM.id) style = before ?: KeySoundStyle.DEFAULT.id
            return@rememberLauncherForActivityResult
        }
        try {
            val o = KeySoundImport.importUri(ctx, uri)
            customDuration = o.duration
            style = KeySoundStyle.CUSTOM.id
            notice = if (o.truncated) tr("Âm dài hơn 0,3 giây nên đã được cắt ngắn.") else null
            preview.playStyle(style, audible())
        } catch (e: KeySoundImport.ImportException) {
            notice = when (e.failure) {
                KeySoundImport.Failure.SILENT -> tr("File không có tiếng (toàn im lặng).")
                KeySoundImport.Failure.TOO_LARGE -> tr("File quá lớn (tối đa 30 MB).")
                KeySoundImport.Failure.UNREADABLE -> tr("Không đọc được file âm thanh này.")
            }
            if (customDuration == null && style == KeySoundStyle.CUSTOM.id) style = before ?: KeySoundStyle.DEFAULT.id
        }
    }
    fun pick(id: String) {
        if (id == KeySoundStyle.CUSTOM.id && customDuration == null) {
            styleBeforeImport = style; style = id
            importer.launch(arrayOf("audio/*"))
            return
        }
        style = id
        preview.playStyle(id, audible())
    }

    SubPageHeader(tr("Âm thanh gõ"), onBack)
    VTSection(header = tr("Chạm một kiểu để chọn và nghe thử."),
        footer = tr(SettingCaption.keySoundStylesAndroid)) {
        KeySoundStyle.MENU_ORDER.forEachIndexed { i, st ->
            if (i > 0) RowDivider()
            VTRow(onClick = { pick(st.id) }) {
                Text(tr(st.viTitle), style = VTType.body, color = c.label, modifier = Modifier.weight(1f))
                if (current == st) GlyphIcon(Glyph.Check, c.accent, 18.dp)
            }
        }
    }
    if (current == KeySoundStyle.CUSTOM || customDuration != null) {
        VTSection {
            Column(Modifier.padding(horizontal = 16.dp, vertical = 8.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                val d = customDuration
                Text(if (d != null) tr("Âm của bạn: %s giây", String.format(Locale.ROOT, "%.2f", d))
                     else tr("Chưa có âm — chọn một file âm thanh ngắn (mp3, m4a, ogg, wav…)."),
                    style = VTType.footnote, color = if (d != null) c.label else c.secondary)
                Row(horizontalArrangement = Arrangement.spacedBy(20.dp)) {
                    Text(if (d == null) tr("Chọn file âm thanh…") else tr("Chọn âm khác…"), style = VTType.body, color = c.accent,
                        modifier = Modifier.clickable { styleBeforeImport = style; importer.launch(arrayOf("audio/*")) })
                    if (d != null) Text(tr("Xoá"), style = VTType.body, color = c.red,
                        modifier = Modifier.clickable {
                            KeySoundImport.remove(ctx); customDuration = null
                            if (style == KeySoundStyle.CUSTOM.id) style = KeySoundStyle.DEFAULT.id
                        })
                }
                Text(tr(SettingCaption.customSound),
                    style = VTType.footnote, color = c.secondary)
            }
            notice?.let { VTRow { Text(it, style = VTType.footnote, color = c.secondary) } }
        }
    }
    if (current.usesPool) {
        fun fire(final: Boolean) {
            if (throttle.shouldFire(vol, SystemClock.uptimeMillis(), final)) preview.playSound(style, vol)
        }
        VTSection {
            Column(Modifier.padding(horizontal = 16.dp, vertical = 8.dp)) {
                Text(tr("Âm lượng: %s%%", vol), style = VTType.body, color = c.label)
                Slider(value = vol.toFloat(), valueRange = 0f..100f, steps = 19,
                    onValueChange = { v -> val n = Math.round(v / 5) * 5; if (n != vol) { vol = n; fire(false) } },
                    onValueChangeFinished = { fire(true) })
                Text(tr(SettingCaption.keySoundVolumeAndroid),
                    style = VTType.footnote, color = c.secondary)
            }
        }
    }
}
