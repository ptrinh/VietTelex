package com.viettelex.android.ime

import com.viettelex.keyboard.KeyboardSettings
import com.viettelex.keyboard.SpaceSideKey
import com.viettelex.keyboard.SplitLayout

/**
 * Hình học bàn phím — port 1:1 các constraint UIStackView của iOS KeyboardView
 * (spec §6.1, §6.3, §6.4). THUẦN (không Android API) để unit-test; mọi toạ độ là
 * px, tính từ dp qua [density]. Chỉ chạy khi đổi plane / cỡ / cấu hình — không
 * bao giờ trong onDraw.
 */
enum class Plane { LETTERS, NUMBERS, SYMBOLS, EMOJI, TEMPLATES,
    /** Ô tìm emoji (hàng trên, EmojiSearchBar) + plane chữ thu thấp bên dưới. */
    EMOJI_SEARCH,
    /** Bàn số điện thoại kiểu Gboard (TYPE_CLASS_PHONE). */
    PHONE,
    /** Bàn số kiểu Gboard (TYPE_CLASS_NUMBER / DATETIME). */
    NUMPAD,
    /** Bảng sửa văn bản ([EditPanel]) thay chỗ phím chữ. */
    EDIT }
enum class InputKind { NORMAL, NUMBER, EMAIL, URL, PHONE, DATETIME;
    /** Plane mở đầu cho loại ô (bàn số riêng cho ô số/điện thoại/ngày giờ). */
    val padPlane: Plane? get() = when (this) {
        PHONE -> Plane.PHONE
        NUMBER, DATETIME -> Plane.NUMPAD
        else -> null
    }
}

object KeyKind {
    const val LETTER = 0      // chèn lúc DOWN, qua router
    const val CHAR = 1        // số/ký hiệu plane 123/#+=: arm DOWN, chốt UP, có balloon
    const val SHIFT = 2
    const val BACKSPACE = 3
    const val PLANE = 4       // 123 / ABC (hàng đáy)
    const val MORE = 5        // #+= / 123 (hàng 3 plane số)
    const val GLOBE = 6
    const val EMOJI = 7
    const val CLEAR = 8       // 🗑 plane mẫu câu
    const val SPACE = 9
    const val PUNCT = 10      // , @ . / cạnh space: arm DOWN, chốt UP, không balloon
    const val RETURN = 11
    const val DISMISS = 12    // tablet: ẩn bàn phím
    /** Phím bàn số (số / ký hiệu phụ): arm DOWN, chốt UP, không balloon, luôn literal. */
    const val PAD = 13
    /** Ô bảng sửa văn bản: insert = tên [EditAction]; hành động lúc chạm (lặp khi giữ) / nhấc. */
    const val EDIT = 14
    /** 📋 bàn số (PHONE / NUMPAD): dán clipboard đã lọc theo ô ([com.viettelex.keyboard.NumericPaste]), lúc nhấc. */
    const val PASTE = 15

    fun isSpecial(k: Int) = when (k) {
        LETTER, CHAR, PUNCT, SPACE, PAD -> false
        else -> true
    }
}

/** Một phím đã đặt chỗ. Mutable field chỉ là trạng thái vẽ (pressed). */
class LaidKey(
    @JvmField val kind: Int,
    /** Nhãn thường (chữ thường cho phím chữ). */
    @JvmField val label: String,
    /** Nhãn khi shift ON/CAPS (phím chữ); = label với phím khác. */
    @JvmField val upper: String,
    /** Chuỗi chèn (CHAR/PUNCT) hoặc đích plane ("123","ABC","#+="). */
    @JvmField val insert: String,
    @JvmField var left: Float, @JvmField var top: Float,
    @JvmField var right: Float, @JvmField var bottom: Float,
    /** Chữ phụ nhỏ dưới số (bàn điện thoại: ABC, DEF…). */
    @JvmField val hint: String = "",
    /** Phím phụ của bàn số (tô màu phím chức năng). */
    @JvmField val side: Boolean = false,
) {
    @JvmField var pressed = false
    /** Chỉ số ổn định trong plane — làm id cho KeyCommitQueue. */
    @JvmField var index = 0
    val width get() = right - left
    val height get() = bottom - top
    val centerX get() = (left + right) / 2
    val centerY get() = (top + bottom) / 2
    fun contains(x: Float, y: Float) = x >= left && x < right && y >= top && y < bottom
    override fun toString() = "LaidKey($label k=$kind [$left,$top,$right,$bottom])"
}

data class LayoutConfig(
    val plane: Plane,
    val widthPx: Float,
    /** Chiều cao VÙNG PHÍM (không gồm strip gợi ý / nav bar). */
    val keyAreaPx: Float,
    val density: Float,
    val kind: InputKind = InputKind.NORMAL,
    val needsGlobe: Boolean = false,
    val tablet: Boolean = false,
    val returnLabel: String = "return",
    /** TYPE_NUMBER_FLAG_SIGNED / DECIMAL (bàn NUMPAD). */
    val numberSigned: Boolean = false,
    val numberDecimal: Boolean = false,
    /** Hàng phím số 1…0 trên plane chữ (Settings, mặc định tắt) — [keyAreaPx] đã gồm nó. */
    val numberRow: Boolean = false,
    /** Chế độ một tay (IME chỉ bật trên điện thoại). */
    val oneHand: OneHandSide = OneHandSide.OFF,
    /** Bảng sửa văn bản có hàng công cụ văn bản cuối (PlusGate TEXT_TOOLS). */
    val editTools: Boolean = false,
    /** Hàng công cụ có thêm ô "Dịch" (PlusGate TRANSLATE). */
    val editTranslate: Boolean = false,
    /** Hàng số cao bằng hàng chữ (Settings, mặc định tắt ⇒ phím số 0.8×) — [keyAreaPx] đã tính theo nó. */
    val numberRowFull: Boolean = false,
    /** "Phím cạnh dấu cách" (Settings, mặc định ",") — chỉ bàn chữ điện thoại ô thường, [KeyLayout.sideKey]. */
    val spaceSideKey: SpaceSideKey = SpaceSideKey.DEFAULT,
    /**
     * "Nút emoji" = Thanh trên VÀ thanh gợi ý đang hiện (EmojiKeyPlacement.inStrip): bàn CHỮ bỏ phím
     * 😊 ở hàng đáy (space ăn chỗ) — nút nằm trên StripView. Plane khác / ô tìm emoji giữ 😊.
     */
    val emojiInStrip: Boolean = false,
    /**
     * Công tắc "Bàn phím tách đôi" (Settings, mặc định TẮT). Chỉ có hiệu lực khi đủ rộng
     * ([KeyLayout.splitActive]) và ở plane chữ / 123 / #+= ([KeyLayout.splitPlane]).
     */
    val split: Boolean = false,
    /**
     * "Phím to" (Settings, mặc định TẮT — [KeyLayout.largeKeysActive]): "," "." hàng đáy điện thoại
     * rộng bằng phím 😊, space co lại (không dưới [KeyLayout.LARGE_MIN_SPACE_DP]). Tablet bỏ qua.
     */
    val largeKeys: Boolean = false,
)

object KeyLayout {
    // dp — kiểu Gboard / Material (26/09/2026; hành vi giữ nguyên bản iOS)
    const val KEY_SPACING = 5f
    const val ROW_MARGIN_V = 5f
    const val ROW_MARGIN_H = 3f
    /** Hàng đáy dùng cùng margin như mọi hàng (Gboard), không sát đáy như iOS. */
    const val BOTTOM_ROW_TOP = ROW_MARGIN_V
    const val BOTTOM_ROW_BOTTOM = ROW_MARGIN_V
    const val KEY_RADIUS = 7f
    /**
     * Strip gợi ý mở mặc định (mức Vừa — [com.viettelex.keyboard.SuggestionBarHeight.MEDIUM]) — tỉ lệ
     * Gboard (~0.75 hàng phím 56 dp; #112: 34 dp trông mỏng, lệch). Thấp 35 / Cao 51 theo cài đặt
     * "Chiều cao thanh gợi ý" (StripView.configure).
     */
    const val OPEN_STRIP = 42f
    const val COLLAPSED_STRIP = 14f
    /** Tâm dọc nội dung bar (chữ gợi ý, pill, icon) khi mở: gần giữa dải, nhích lên 1 dp. */
    const val BAR_CY = OPEN_STRIP / 2 - 1f
    /** [BAR_CY] cho strip mở cao [openStripDp] (mức "Chiều cao thanh gợi ý"). */
    fun barCy(openStripDp: Float): Float = openStripDp / 2 - 1f
    const val STRIP_ZONE_W = 52f

    /** Khe dọc giữa 2 hàng phím (dp): mỗi hàng chừa [ROW_MARGIN_V] trên + dưới. */
    const val ROW_GAP = 2 * ROW_MARGIN_V
    /**
     * Hàng số thấp hơn hàng chữ như Gboard: PHÍM số = 0.8× PHÍM chữ, KHÔNG tính khe (cùng iOS
     * KeyGeometry.numberKeyRatio, 12/10/2026). Trước: hàng số = 0.75× cả HÀNG kể khe ⇒ phím
     * số 32 dp cạnh phím chữ 46 (≈ 70%) — tester: "phím số nhỏ quá so với phím chữ".
     */
    const val NUMBER_KEY_RATIO = 0.8f

    /** Tỉ lệ phím số / phím chữ: [NUMBER_KEY_RATIO], hoặc 1 khi bật "Hàng số cao bằng hàng chữ". */
    fun numberKeyRatio(full: Boolean): Float = if (full) 1f else NUMBER_KEY_RATIO

    /** Cao hàng số (khe + phím) khi hàng chữ cao [unit] (khe + phím); [gap] cùng đơn vị (dp hoặc px). */
    fun numberRowHeight(unit: Float, gap: Float, full: Boolean = false): Float =
        gap + numberKeyRatio(full) * maxOf(unit - gap, 0f)

    /**
     * Vùng phím không cao quá phần này của chiều cao màn hình (dp) khi chỉnh hàng VƯỢT trần cũ
     * +10 ([KeyboardSettings.ROW_HEIGHT_UNCLAMPED_MAX]) — máy nhỏ / màn ngang (16/10/2026).
     */
    const val MAX_KEY_AREA_FRACTION = 0.5f

    /**
     * Mức chỉnh hàng thực dùng: kẹp [KeyboardSettings.ROW_HEIGHT_MIN]…[KeyboardSettings.ROW_HEIGHT_MAX];
     * phần trên +10 chỉ dùng tới chừng vùng phím còn ≤ [MAX_KEY_AREA_FRACTION] × [screenHeightDp]
     * (≤ 0 = không biết màn hình ⇒ không kẹp). Tới +10 luôn giữ nguyên như trước (không thụt lùi).
     */
    fun effectiveRowAdjust(tablet: Boolean, landscape: Boolean, rowHeightAdjust: Int, numberRow: Boolean = false,
                           numberRowFull: Boolean = false, screenHeightDp: Float = 0f): Int {
        val a = rowHeightAdjust.coerceIn(KeyboardSettings.ROW_HEIGHT_MIN, KeyboardSettings.ROW_HEIGHT_MAX)
        val floor = KeyboardSettings.ROW_HEIGHT_UNCLAMPED_MAX
        if (a <= floor || screenHeightDp <= 0f) return a
        val cap = MAX_KEY_AREA_FRACTION * screenHeightDp
        var e = a
        while (e > floor && rawKeyAreaDp(tablet, landscape, e, numberRow, numberRowFull) > cap) e--
        return e
    }

    private fun rawKeyAreaDp(tablet: Boolean, landscape: Boolean, adj: Int, numberRow: Boolean, numberRowFull: Boolean): Float {
        val base = if (tablet) (if (landscape) 300f else 256f) else (if (landscape) 168f else 224f)
        val four = base + adj * 4f
        return if (numberRow) four + numberRowHeight(four / 4f, ROW_GAP, numberRowFull) else four
    }

    /**
     * Gboard: điện thoại 224 dọc (4 × 56) / 168 ngang; tablet 256 / 300; + rowHeightAdjust × 4 hàng
     * ([effectiveRowAdjust]: −10…+18, phần trên +10 kẹp theo [screenHeightDp]).
     * Hàng số bật ⇒ + [numberRowHeight] (điện thoại dọc: 10 + 0.8 × 46 = 46.8 dp), cho MỌI plane
     * (chuyển 123/emoji không đổi chiều cao bàn phím; plane số/ký hiệu giữ 4 hàng, mỗi hàng cao hơn chút).
     * [numberRowFull] ⇒ hàng số cao đúng 1 hàng chữ (56 dp dọc), bàn phím cao thêm tương ứng.
     */
    fun keyAreaDp(tablet: Boolean, landscape: Boolean, rowHeightAdjust: Int, numberRow: Boolean = false,
                  numberRowFull: Boolean = false, screenHeightDp: Float = 0f): Float =
        rawKeyAreaDp(tablet, landscape,
            effectiveRowAdjust(tablet, landscape, rowHeightAdjust, numberRow, numberRowFull, screenHeightDp),
            numberRow, numberRowFull)

    /** Cả bàn phím cao thêm bao nhiêu dp khi chỉnh [rowHeightAdjust] dp mỗi hàng (chữ cài đặt). */
    fun adjustTotalDp(rowHeightAdjust: Int, numberRow: Boolean, numberRowFull: Boolean = false): Int = Math.round(
        keyAreaDp(false, false, rowHeightAdjust, numberRow, numberRowFull) - keyAreaDp(false, false, 0, numberRow, numberRowFull))

    /** Chiều cao hàng ô tìm emoji (plane EMOJI_SEARCH): 1/5 vùng phím. */
    fun searchHeaderPx(keyAreaPx: Float) = keyAreaPx / 5f

    /**
     * Chiều cao một hàng phím chuẩn (khe + phím) trong vùng phím [keyAreaPx] — ngược của
     * [keyAreaDp]: K = 4u + gap + r(u − gap) ⇒ u = (K − (1 − r)·gap) / (4 + r), gap = [ROW_GAP] × [density],
     * r = [numberKeyRatio] (hàng số đủ cao: r = 1 ⇒ u = K / 5).
     */
    fun rowUnit(keyAreaPx: Float, numberRow: Boolean, density: Float, numberRowFull: Boolean = false): Float {
        if (!numberRow) return keyAreaPx / 4f
        val r = numberKeyRatio(numberRowFull)
        return (keyAreaPx - (1f - r) * ROW_GAP * density) / (4f + r)
    }

    /**
     * Dải strip giữ theo CÔNG TẮC "Thanh gợi ý" toàn cục, không theo từng ô (port iOS
     * e72ae43): ô từ chối gợi ý (mật khẩu, URL, NO_SUGGESTIONS…) để trống dải thay vì làm
     * bàn phím thấp đi 38 dp rồi cao lại khi sang ô khác.
     */
    fun stripReserved(showSuggestionsSetting: Boolean): Boolean = showSuggestionsSetting

    fun stripDp(suggestionsEnabled: Boolean, collapsed: Boolean, open: Float = OPEN_STRIP): Float =
        if (!suggestionsEnabled) 0f else if (collapsed) COLLAPSED_STRIP else open

    /**
     * Hàng đáy có phím "." RIÊNG (thêm vào, ngoài phím hẹp cạnh space)? Plane chữ ô thường ĐIỆN
     * THOẠI: KHÔNG — một phím hẹp duy nhất kiểu iPhone [?123][😊][space rộng][, hẹp][↵] (issue
     * #113; Phil 12/10/2026 bỏ công tắc "Hiện phím dấu chấm" — hàng ", ." dồn góc, space bé —
     * KHÔNG đưa lại hàng ", ." dồn góc). Phím hẹp đó là "," / "." / không có theo "Phím cạnh dấu
     * cách" ([sideKey], 16/10/2026); "Cả hai" (16/10/2026, Phil duyệt) = "," TRÁI + "." phải space,
     * space vẫn ở giữa — không phải "." riêng. Luôn có: ô URL / email (giữ "." ra đuôi tên miền), tablet
     * (dư chỗ), plane số / ký hiệu / mẫu câu.
     */
    fun hasPeriodKey(c: LayoutConfig): Boolean =
        c.plane != Plane.LETTERS || c.kind == InputKind.URL || c.kind == InputKind.EMAIL ||
            (c.tablet && tabletPunct(c))

    /**
     * Tuỳ chọn "Phím cạnh dấu cách" CÓ HIỆU LỰC (dạng một phím hẹp) cho layout này: bàn chữ
     * ĐIỆN THOẠI ô thường ⇒ [LayoutConfig.spaceSideKey]; còn lại (tablet — xem [tabletPunct], ô
     * URL / email, plane số / ký hiệu / mẫu câu) ⇒ null. View dùng để biết phím "." có popup dấu
     * câu ("," chọn sẵn) không — tablet có cả "," lẫn "." nên "." không cần popup đó.
     */
    fun sideKey(c: LayoutConfig): SpaceSideKey? =
        if (c.plane == Plane.LETTERS && (!c.tablet || splitActive(c)) && c.kind != InputKind.URL && c.kind != InputKind.EMAIL)
            c.spaceSideKey else null

    /**
     * Tablet, bàn chữ ô thường (16/10/2026): "Phím cạnh dấu cách" Dấu phẩy / Dấu chấm ⇒ CẢ "," lẫn
     * "." hai bên space (dư chỗ); Tắt ⇒ không phím dấu câu nào, space rộng thêm. Ô URL / email /
     * plane khác không theo tuỳ chọn ⇒ true (giữ "." như cũ).
     */
    fun tabletPunct(c: LayoutConfig): Boolean =
        !(c.plane == Plane.LETTERS && c.kind != InputKind.URL && c.kind != InputKind.EMAIL) ||
            c.spaceSideKey != SpaceSideKey.OFF

    private val ROW1 = "qwertyuiop"
    private val ROW2 = "asdfghjkl"
    private val ROW3 = "zxcvbnm"
    internal val NUM1 = listOf("1", "2", "3", "4", "5", "6", "7", "8", "9", "0")
    /*
     * Plane 123 / #+= GIỐNG HỆT bàn iOS (#165 — người dùng không tìm ra "$"): hàng ký tự = iOS
     * KeyLayout.phoneNumberRows / phoneSymbolRows, hàng 3 = [#+= | 123] . , ? ! ' ⌫ như iOS
     * buildPlane. "," "." có cả ở hàng 3 lẫn hàng đáy (hàng 3 như iOS). Pinned bởi KeyLayoutTest
     * (đọc thẳng file Swift) — sửa bên này thì sửa y hệt bên kia.
     */
    internal val NUM2 = listOf("-", "/", ":", ";", "(", ")", "\$", "&", "@", "\"")
    internal val SYM1 = listOf("[", "]", "{", "}", "#", "%", "^", "*", "+", "=")
    // 3 tiền tệ như iOS: €, ¥, ₫ (₫ còn ở giữ "$" plane 123).
    internal val SYM2 = listOf("_", "\\", "|", "~", "<", ">", "€", "¥", "₫", "•")
    /** Ký tự hàng 3 (giữa phím #+= / 123 và ⌫) — chung hai plane, như iOS. */
    internal val THIRD = listOf(".", ",", "?", "!", "'")
    /** Bàn tách đôi: hàng 3 chia [more] . , | ? ! ' [⌫] như iOS buildSplitPlane. */
    internal const val THIRD_SPLIT_LEFT = 2

    /** Nhãn phím đầu hàng 3 (đổi 123 ⇄ #+=) như iOS: plane 123 ⇒ "#+=", plane ký hiệu ⇒ "123". */
    fun moreKeyLabel(p: Plane): String = if (p == Plane.NUMBERS) "#+=" else "123"

    /**
     * Hàng ký tự (10 phím) TRÊN hàng 3 của plane 123 / #+= — song sinh iOS phoneSymbolicRows.
     * Tắt hàng số: [NUM1, NUM2] / [SYM1, SYM2]. Bật hàng số: hàng đầu là ĐÚNG hàng số plane chữ
     * (1…0) + 2 hàng ký hiệu ⇒ 5 hàng cùng khung plane chữ; plane 123 mượn hàng đầu plane #+=
     * (SYM1). Hàng mượn nằm NGAY DƯỚI hàng số (#142, cùng iOS): hàng - / : ; ( ) $ & @ " giữ đúng
     * vị trí thứ 3 từ dưới lên như khi tắt hàng số.
     */
    fun symbolicRows(numbers: Boolean, numberRow: Boolean): List<List<String>> = when {
        !numberRow && numbers -> listOf(NUM1, NUM2)
        !numberRow -> listOf(SYM1, SYM2)
        numbers -> listOf(NUM1, SYM1, NUM2)
        else -> listOf(NUM1, SYM1, SYM2)
    }

    fun build(c: LayoutConfig): List<LaidKey> {
        // Tách đôi (công tắc bật + đủ rộng): plane chữ / 123 / #+= dựng hai nửa; một tay bỏ qua.
        if (c.split && splitPlane(c.plane) && splitActive(c)) {
            val out = ArrayList<LaidKey>(44)
            buildSplit(out, c)
            for (i in out.indices) out[i].index = i
            return out
        }
        // Một tay: dựng plane ở bề ngang hẹp rồi dời — mọi hình học (router, tâm phím gõ
        // vuốt, bước vuốt ⌫) tự đúng, không nhánh riêng.
        if (c.oneHand != OneHandSide.OFF && OneHand.appliesTo(c.plane)) {
            val (x0, w) = OneHand.span(c.widthPx, c.oneHand)
            val keys = build(c.copy(widthPx = w, oneHand = OneHandSide.OFF))
            OneHand.shift(keys, x0)
            return keys
        }
        val out = ArrayList<LaidKey>(40)
        val rowH = c.keyAreaPx / 4f
        when (c.plane) {
            Plane.LETTERS -> {
                // Hàng số (tuỳ chọn): phím CHAR như plane 123 (arm DOWN, chốt UP, balloon),
                // phím số 0.8× phím chữ ([numberRowHeight]); 4 hàng chữ dời xuống y0. Không hàng số ⇒ y0 = 0, như cũ.
                val u = rowUnit(c.keyAreaPx, c.numberRow, c.density, c.numberRowFull)
                val y0 = if (c.numberRow) numberRowHeight(u, ROW_GAP * c.density, c.numberRowFull) else 0f
                if (c.numberRow) equalRow(out, NUM1, KeyKind.CHAR, c, 0, y0, 0f)
                equalRow(out, ROW1.map { it.toString() }, KeyKind.LETTER, c, 0, u, 0f, y0)
                equalRow(out, ROW2.map { it.toString() }, KeyKind.LETTER, c, 1, u, 0.5f, y0)
                thirdRow(out, c, u, letters = true, y0 = y0)
                bottomRow(out, c, y0 + 3 * u, u, planeKey = "?123", clearInsteadOfEmoji = false)
            }
            Plane.NUMBERS, Plane.SYMBOLS -> if (c.numberRow) {
                // Bật hàng số (field report 18/10/2026: "hàng phím số khi bấm chuyển lại bị mất dẫn
                // đến hụt hàng… khoảng cách phím không cân đối, toàn bấm nhầm"): trước đây 4 hàng
                // giãn cả vùng phím (đã cao thêm hàng số) ⇒ mọi hàng cao ~1,2×, hàng 1…0 nhảy chỗ.
                // Giờ: ĐÚNG hàng số của plane chữ (cùng khung) + [symbolicRows] + hàng 3 + hàng đáy,
                // mọi hàng cao y hệt plane chữ.
                val u = rowUnit(c.keyAreaPx, true, c.density, c.numberRowFull)
                val y0 = numberRowHeight(u, ROW_GAP * c.density, c.numberRowFull)
                val rows = symbolicRows(c.plane == Plane.NUMBERS, numberRow = true)
                equalRow(out, rows[0], KeyKind.CHAR, c, 0, y0, 0f)
                equalRow(out, rows[1], KeyKind.CHAR, c, 0, u, 0f, y0)
                equalRow(out, rows[2], KeyKind.CHAR, c, 1, u, 0f, y0)
                thirdRow(out, c, u, letters = false, y0 = y0)
                bottomRow(out, c, y0 + 3 * u, u, planeKey = if (c.kind.padPlane != null) "123" else "ABC",
                    clearInsteadOfEmoji = false)
            } else {
                val num = c.plane == Plane.NUMBERS
                equalRow(out, if (num) NUM1 else SYM1, KeyKind.CHAR, c, 0, rowH, 0f)
                equalRow(out, if (num) NUM2 else SYM2, KeyKind.CHAR, c, 1, rowH, 0f)
                thirdRow(out, c, rowH, letters = false)
                // Hàng đáy: [ABC][,][😊][space][.][↵] (+ 🌐 / ẩn tablet).
                bottomRow(out, c, 3 * rowH, rowH, planeKey = if (c.kind.padPlane != null) "123" else "ABC",
                    clearInsteadOfEmoji = false)
            }
            Plane.TEMPLATES -> {
                // Chips giãn phần trên; hàng đáy cao ĐÚNG 1 hàng phím chuẩn.
                val u = rowUnit(c.keyAreaPx, c.numberRow, c.density, c.numberRowFull)
                bottomRow(out, c, c.keyAreaPx - u, u, planeKey = "ABC", clearInsteadOfEmoji = true)
            }
            Plane.EMOJI -> Unit   // EmojiPane tự vẽ
            Plane.EMOJI_SEARCH -> {
                // Plane chữ đầy đủ trong phần dưới; hàng trên (1/5) là ô tìm + kết quả.
                val head = searchHeaderPx(c.keyAreaPx)
                // Ô tìm emoji: strip ẩn ⇒ luôn giữ 😊 (về bảng emoji).
                for (k in build(c.copy(plane = Plane.LETTERS, keyAreaPx = c.keyAreaPx - head, oneHand = OneHandSide.OFF,
                        emojiInStrip = false, split = false))) {
                    k.top += head; k.bottom += head
                    out += k
                }
            }
            Plane.EDIT -> EditPanel.build(out, c)
            Plane.PHONE, Plane.NUMPAD -> numberPad(out, c, rowH)
        }
        for (i in out.indices) out[i].index = i
        return out
    }

    private fun keyTop(rowIndex: Int, rowH: Float, d: Float, y0: Float = 0f) = y0 + rowIndex * rowH + ROW_MARGIN_V * d
    private fun keyBottom(rowIndex: Int, rowH: Float, d: Float, y0: Float = 0f) = y0 + (rowIndex + 1) * rowH - ROW_MARGIN_V * d

    /** Hàng phím bằng nhau; sideInset tính theo "phím" = W/10 như iOS (hàng 2 thụt 0.5). */
    private fun equalRow(out: MutableList<LaidKey>, labels: List<String>, kind: Int,
                         c: LayoutConfig, rowIndex: Int, rowH: Float, sideInset: Float, y0: Float = 0f) {
        val d = c.density
        val gap0 = KEY_SPACING * d
        // Thụt theo BƯỚC phím hàng 10 (phím + khe) ⇒ phím hàng 2 đúng bằng hàng 1.
        val pitch = (c.widthPx - 2 * ROW_MARGIN_H * d - 9 * gap0) / 10f + gap0
        val inset = ROW_MARGIN_H * d + sideInset * pitch
        val n = labels.size
        val gap = KEY_SPACING * d
        val w = (c.widthPx - 2 * inset - gap * (n - 1)) / n
        val t = keyTop(rowIndex, rowH, d, y0); val b = keyBottom(rowIndex, rowH, d, y0)
        var x = inset
        for (s in labels) {
            val up = if (kind == KeyKind.LETTER) s.uppercase() else s
            out += LaidKey(kind, s, up, s, x, t, x + w, b)
            x += w + gap
        }
    }

    /**
     * Hàng 3: plane chữ = ⇧(1.5) z…m ⌫(1.5) trên lưới 10 cột; plane số / ký hiệu như iOS =
     * [#+= | 123](1.5) . , ? ! ' ⌫(1.5) — 5 dấu chia đều phần còn lại.
     */
    private fun thirdRow(out: MutableList<LaidKey>, c: LayoutConfig, rowH: Float, letters: Boolean, y0: Float = 0f) {
        val d = c.density
        val m = ROW_MARGIN_H * d
        val gap = KEY_SPACING * d
        val inner = c.widthPx - 2 * m
        val k = (inner - 8 * gap) / 10f            // phím chữ hàng 3 (1.5+7+1.5 = 10)
        val side = 1.5f * k
        val t = keyTop(2, rowH, d, y0); val b = keyBottom(2, rowH, d, y0)
        var x = m
        if (letters) {
            out += LaidKey(KeyKind.SHIFT, "", "", "", x, t, x + side, b); x += side + gap
            for (ch in ROW3) {
                val s = ch.toString()
                out += LaidKey(KeyKind.LETTER, s, s.uppercase(), s, x, t, x + k, b); x += k + gap
            }
        } else {
            val more = moreKeyLabel(c.plane)
            out += LaidKey(KeyKind.MORE, more, more, more, x, t, x + side, b); x += side + gap
            val row = THIRD
            val p = (inner - 2 * side - (row.size + 1) * gap) / row.size
            for (s in row) { out += LaidKey(KeyKind.CHAR, s, s, s, x, t, x + p, b); x += p + gap }
        }
        out += LaidKey(KeyKind.BACKSPACE, "", "", "", x, t, c.widthPx - m, b)
    }

    /**
     * Hàng đáy kiểu Gboard: [?123|ABC 0.15][, 0.10][🌐 0.10?][😊|🗑 0.10][space còn lại][. 0.10?]
     * [enter 0.15] ("." theo [hasPeriodKey]). Bàn chữ ô thường: "," sang phải space như iOS —
     * điện thoại [?123][🌐?][😊?][space][, 0.085][enter] (phím hẹp "," | "." | không có theo [sideKey];
     * Cả hai: [?123][😊?][, 0.085][space][. 0.085][enter]; 😊 lên strip khi [LayoutConfig.emojiInStrip]);
     * tablet: [tabletLettersBottom] (space giữa, dấu câu hai bên). Plane số tablet: + [ẩn 0.07]. Ô email: "," ⇒ "@"; ô URL: "," ⇒ "/" (issue #113: không
     * phím ".com" riêng — space rộng như stock, đuôi tên miền ở giữ "." — DomainPopup).
     * Hệ số nhân với bề ngang CẢ hàng.
     */
    private fun bottomRow(out: MutableList<LaidKey>, c: LayoutConfig, rowTop: Float, rowH: Float,
                          planeKey: String, clearInsteadOfEmoji: Boolean) {
        val d = c.density
        val W = c.widthPx
        val m = ROW_MARGIN_H * d
        val gap = KEY_SPACING * d
        val t = rowTop + BOTTOM_ROW_TOP * d
        val b = rowTop + rowH - BOTTOM_ROW_BOTTOM * d
        val slots = ArrayList<Slot>(9)
        val letters = c.plane == Plane.LETTERS
        if (letters && c.tablet && c.kind != InputKind.EMAIL && c.kind != InputKind.URL) {
            tabletLettersBottom(out, c, t, b, planeKey); return
        }
        slots += Slot(KeyKind.PLANE, planeKey, planeKey, 0.15f)
        // Bàn chữ ô thường: "," sang PHẢI phím cách như iOS ([space][,][.?][enter]).
        val commaRight = letters && c.kind != InputKind.EMAIL && c.kind != InputKind.URL
        val left = if (letters) when (c.kind) {
            InputKind.EMAIL -> "@"
            InputKind.URL -> "/"
            else -> ","
        } else ","
        if (!commaRight) slots += Slot(KeyKind.PUNCT, left, left, 0.10f)
        if (c.needsGlobe) slots += Slot(KeyKind.GLOBE, "", "", 0.10f)
        if (clearInsteadOfEmoji) slots += Slot(KeyKind.CLEAR, "", "", 0.10f)
        else if (!(letters && c.emojiInStrip)) slots += Slot(KeyKind.EMOJI, "", "", 0.10f)   // Thanh trên ⇒ 😊 ở strip
        // Điện thoại: phím hẹp theo "Phím cạnh dấu cách" ("," / "." cùng chỗ cùng cỡ; Cả hai ⇒ "," trái +
        // "." phải, cùng cỡ; Tắt ⇒ không phím, space ăn chỗ).
        val side = if (commaRight) sideKey(c) else null
        side?.left?.let { slots += Slot(KeyKind.PUNCT, it, it, PHONE_LETTERS_COMMA) }
        slots += Slot(KeyKind.SPACE, "", " ", -1f)
        side?.right?.let { slots += Slot(KeyKind.PUNCT, it, it, PHONE_LETTERS_COMMA) }
        if (hasPeriodKey(c)) slots += Slot(KeyKind.PUNCT, ".", ".", 0.10f)
        slots += Slot(KeyKind.RETURN, c.returnLabel, "\n", 0.15f)
        if (c.tablet) slots += Slot(KeyKind.DISMISS, "", "", 0.07f)
        var fixed = 0f
        for (s in slots) if (s.mult > 0) fixed += s.mult * W
        var space = (W - 2 * m - fixed - gap * (slots.size - 1)).coerceAtLeast(gap)
        if (largeKeysActive(c)) space = widenPuncts(slots, space, LARGE_PUNCT * W, d, scale = W)
        var x = m
        for (s in slots) {
            val w = if (s.mult > 0) s.mult * W else space
            out += LaidKey(s.kind, s.label, s.label, s.insert, x, t, x + w, b)
            x += w + gap
        }
    }

    private data class Slot(val kind: Int, val label: String, val insert: String, val mult: Float)

    // MARK: "Phím to" (LargeKeys — song sinh iOS KeyGeometry.LargeKeys; Settings → Phím, mặc định TẮT)
    // Tắt ⇒ một phép AND lúc dựng, không phím / số nào đổi. Bật (chỉ điện thoại): "," / "." cạnh space
    // rộng bằng phím 😊 ([LARGE_PUNCT] — plane số / ký hiệu / mẫu câu, ô email / URL vốn đã bằng),
    // space co lại đúng phần đó nhưng không dưới [LARGE_MIN_SPACE_DP] (không bao giờ hẹp hơn lúc tắt);
    // bàn tách đôi: "," "." = phím 😊 nửa trái (keyWidth). Hàng Z không đổi: ⇧ / ⌫ Android vốn sát
    // z / m đúng một khe phím (không có khe rộng như iPhone).

    /** "Phím to" có hiệu lực: công tắc bật + không phải tablet. */
    fun largeKeysActive(c: LayoutConfig): Boolean = c.largeKeys && !c.tablet

    /** Bề rộng "," / "." khi bật (tỉ lệ hàng) = phím 😊 hàng đáy điện thoại. */
    const val LARGE_PUNCT = 0.10f
    /** Space không co dưới chừng này (dp) — đủ giữ-kéo con trỏ, vuốt đổi ngôn ngữ, logo. */
    const val LARGE_MIN_SPACE_DP = 80f

    /** Phím hàng đáy được nở khi bật. */
    fun largeWidens(label: String) = label == "," || label == "."

    /**
     * Nở các slot "," / "." trong [slots] (mult × [scale] = bề rộng px) tới [target] px, lấy chỗ từ
     * space đang rộng [space] px; space giữ ≥ [LARGE_MIN_SPACE_DP] (đã hẹp hơn thì không nở). Trả bề
     * rộng space mới. THUẦN — chỉ chạy lúc dựng layout.
     */
    private fun widenPuncts(slots: MutableList<Slot>, space: Float, target: Float, d: Float, scale: Float): Float {
        var n = 0
        for (s in slots) if (s.kind == KeyKind.PUNCT && largeWidens(s.label) && s.mult * scale < target) n++
        if (n == 0) return space
        val spare = (space - LARGE_MIN_SPACE_DP * d).coerceAtLeast(0f)
        var used = 0f
        for (i in slots.indices) {
            val s = slots[i]
            if (s.kind != KeyKind.PUNCT || !largeWidens(s.label)) continue
            val w = s.mult * scale
            if (w >= target) continue
            val grow = minOf(target - w, spare / n)
            slots[i] = s.copy(mult = (w + grow) / scale)
            used += grow
        }
        return space - used
    }

    /** Tablet bàn chữ: bề rộng phím (đơn vị = BƯỚC phím hàng 10 chữ, phím + khe). */
    const val TABLET_PLANE_U = 1.25f
    const val TABLET_PLANE_GLOBE_U = 1.0f
    /** 😊 / 🌐 / ẩn bàn phím. */
    const val TABLET_CONTROL_U = 0.75f
    /** "," "." = đúng một phím chữ. */
    const val TABLET_PUNCT_U = 1.0f
    const val TABLET_RETURN_U = 1.25f

    /**
     * Hàng đáy bàn chữ TABLET ô thường (16/10/2026 — tester tablet: space ngắn, lệch hẳn một bên
     * vì [?123][😊][space][,][.][↵][ẩn] dồn 4 phím bên phải). Kiểu Gboard / Samsung tablet: space
     * ĐÚNG GIỮA hàng, dấu câu chia hai bên, mép phím thẳng cột với hàng chữ (đơn vị = bước phím
     * hàng q…p, cùng công thức [equalRow]):
     *   Dấu phẩy / Dấu chấm: [?123 1.25][😊 .75][, 1] [space 4 ≈ dưới x½ c v b n x½] [. 1][↵ 1.25][ẩn .75]
     *   Tắt:                 [?123 1.25][😊 .75]      [space 6 ≈ dưới z½ … m½]          [↵ 1.25][ẩn .75]
     *   có 🌐: [?123 1][🌐 .75][😊 .75][,] … [.][↵][ẩn] — bên nào ngắn hơn thì phím mép (?123 hoặc ↵)
     *   nở bù, để hai bên luôn bằng nhau ⇒ space luôn giữa (có 🌐 + dấu câu: space 3).
     */
    private fun tabletLettersBottom(out: MutableList<LaidKey>, c: LayoutConfig, t: Float, b: Float, planeKey: String) {
        val d = c.density
        val m = ROW_MARGIN_H * d
        val gap = KEY_SPACING * d
        val pitch = (c.widthPx - 2 * m + gap) / 10f
        val punct = tabletPunct(c)
        val left = ArrayList<Slot>(4); val right = ArrayList<Slot>(3)
        left += Slot(KeyKind.PLANE, planeKey, planeKey, if (c.needsGlobe) TABLET_PLANE_GLOBE_U else TABLET_PLANE_U)
        if (c.needsGlobe) left += Slot(KeyKind.GLOBE, "", "", TABLET_CONTROL_U)
        if (!c.emojiInStrip) left += Slot(KeyKind.EMOJI, "", "", TABLET_CONTROL_U)
        if (punct) { left += Slot(KeyKind.PUNCT, ",", ",", TABLET_PUNCT_U); right += Slot(KeyKind.PUNCT, ".", ".", TABLET_PUNCT_U) }
        right += Slot(KeyKind.RETURN, c.returnLabel, "\n", TABLET_RETURN_U)
        right += Slot(KeyKind.DISMISS, "", "", TABLET_CONTROL_U)
        val l = left.sumOf { it.mult.toDouble() }.toFloat()
        val r = right.sumOf { it.mult.toDouble() }.toFloat()
        // Phím mép bên ngắn hơn nở bù ⇒ hai bên bằng nhau, space đúng giữa.
        if (l > r) { val i = right.indexOfFirst { it.kind == KeyKind.RETURN }; right[i] = right[i].copy(mult = right[i].mult + l - r) }
        else if (r > l) left[0] = left[0].copy(mult = left[0].mult + r - l)
        val side = maxOf(l, r)
        var u = 0f
        fun put(s: Slot, w: Float) {
            out += LaidKey(s.kind, s.label, s.label, s.insert, m + u * pitch, t, m + (u + w) * pitch - gap, b)
            u += w
        }
        for (s in left) put(s, s.mult)
        put(Slot(KeyKind.SPACE, "", " ", 0f), 10f - 2 * side)
        for (s in right) put(s, s.mult)
    }

    /**
     * Bề rộng "," hàng đáy plane chữ ĐIỆN THOẠI (tỉ lệ hàng): 0.10 → 0.085 ≈ một phím chữ,
     * phần dư cho space (Phil 06/10/2026, cùng iOS 0.075 → 0.065; thêm HitBias). Tablet,
     * plane số, ô URL / email giữ 0.10.
     */
    const val PHONE_LETTERS_COMMA = 0.085f

    private val PHONE_HINTS = arrayOf("", "ABC", "DEF", "GHI", "JKL", "MNO", "PQRS", "TUV", "WXYZ")

    /**
     * Bàn số kiểu Gboard (feedback tester 15/11/2026: "làm như Gboard", Dán lên thanh trên):
     *  PHONE : trái  + · − · ( ) · ?123 | lưới 1…9, * 0 # (chữ ABC… dưới số) |
     *          phải  ⌫ · , ; (pause/wait) · ␣ · enter
     *  NUMPAD: KHÔNG cột trái (trừ DATETIME: / : − chia đều cả cột) | lưới 1…9, [, 0 .] — "," "."
     *          chỉ khi DECIMAL, không có thì 0 nở rộng |
     *          phải  − (chỉ khi SIGNED) · ␣ (cao 2 hàng nếu không có −) · ⌫ · enter
     * KHÔNG ?123 ở NUMPAD: ô số chỉ nhận số + dấu theo cờ — bàn ký hiệu gõ gì ô cũng từ chối.
     * KHÔNG phím 📋: Dán nằm trên thanh trên cùng (StripMode.TOOLS, dán số đã lọc — NumericPaste).
     * Phím không hợp cờ của ô thì không có (không gõ được ký tự ô từ chối).
     */
    private fun numberPad(out: MutableList<LaidKey>, c: LayoutConfig, rowH: Float) {
        val d = c.density
        val W = c.widthPx
        val m = ROW_MARGIN_H * d
        val gap = KEY_SPACING * d
        val phone = c.plane == Plane.PHONE
        val sides = if (!phone && c.kind == InputKind.DATETIME) listOf("/", ":", "-") else emptyList()
        val hasLeft = phone || sides.isNotEmpty()
        val sideW = 0.17f * W
        val leftX = m
        val rightX = W - m - sideW
        val gridX = if (hasLeft) m + sideW + gap else m
        val gridW = (rightX - gap - gridX - 2 * gap) / 3f
        fun top(r: Int) = r * rowH + ROW_MARGIN_V * d
        fun bot(r: Int) = (r + 1) * rowH - ROW_MARGIN_V * d
        fun pad(label: String, x0: Float, x1: Float, t: Float, b: Float, hint: String = "", side: Boolean = false) {
            out += LaidKey(KeyKind.PAD, label, label, label, x0, t, x1, b, hint, side)
        }
        fun cellX(col: Int) = gridX + col * (gridW + gap)
        // lưới số
        for (i in 0 until 9) {
            val r = i / 3; val x0 = cellX(i % 3)
            pad((i + 1).toString(), x0, x0 + gridW, top(r), bot(r), if (phone) PHONE_HINTS[i] else "")
        }
        val decimal = !phone && c.kind != InputKind.DATETIME && c.numberDecimal
        val bl = if (phone) "*" else if (decimal) "," else null
        val br = if (phone) "#" else if (decimal) "." else null
        bl?.let { pad(it, cellX(0), cellX(0) + gridW, top(3), bot(3)) }
        br?.let { pad(it, cellX(2), cellX(2) + gridW, top(3), bot(3)) }
        pad("0", if (bl != null) cellX(1) else cellX(0), if (br != null) cellX(1) + gridW else cellX(2) + gridW,
            top(3), bot(3), if (phone) "+" else "")
        // cột trái
        if (phone) {
            pad("+", leftX, leftX + sideW, top(0), bot(0), side = true)
            pad("-", leftX, leftX + sideW, top(1), bot(1), side = true)
            val hw = (sideW - gap) / 2
            pad("(", leftX, leftX + hw, top(2), bot(2), side = true)
            pad(")", leftX + hw + gap, leftX + sideW, top(2), bot(2), side = true)
            out += LaidKey(KeyKind.MORE, "?123", "?123", "?123", leftX, top(3), leftX + sideW, bot(3))
        } else if (sides.isNotEmpty()) {
            val t0 = top(0); val b0 = bot(3)
            val h = (b0 - t0 - gap * (sides.size - 1)) / sides.size
            for ((k, sym) in sides.withIndex()) {
                val t = t0 + k * (h + gap)
                pad(sym, leftX, leftX + sideW, t, t + h, side = true)
            }
        }
        fun space(r0: Int, r1: Int) { out += LaidKey(KeyKind.SPACE, "", "", " ", rightX, top(r0), rightX + sideW, bot(r1)) }
        // cột phải
        if (phone) {
            out += LaidKey(KeyKind.BACKSPACE, "", "", "", rightX, top(0), rightX + sideW, bot(0))
            val hw = (sideW - gap) / 2
            pad(",", rightX, rightX + hw, top(1), bot(1), side = true)
            pad(";", rightX + hw + gap, rightX + sideW, top(1), bot(1), side = true)
            space(2, 2)
        } else {
            // Như Gboard: − · ␣ · ⌫ · enter (⌫ và enter luôn ở hàng 3, 4).
            if (c.numberSigned && c.kind != InputKind.DATETIME) {
                pad("-", rightX, rightX + sideW, top(0), bot(0), side = true)
                space(1, 1)
            } else space(0, 1)
            out += LaidKey(KeyKind.BACKSPACE, "", "", "", rightX, top(2), rightX + sideW, bot(2))
        }
        out += LaidKey(KeyKind.RETURN, c.returnLabel, c.returnLabel, "\n", rightX, top(3), rightX + sideW, bot(3))
    }

    // MARK: bàn phím tách đôi (SplitLayout — Settings → Giao diện, mặc định TẮT)
    // Công tắc tắt ⇒ build() không vào nhánh này (một phép AND), không phím / vòng lặp nào thêm.
    // Bật + đủ rộng ⇒ plane chữ / 123 / #+= thành hai nửa: [nửa trái][khe chết][nửa phải]; emoji,
    // mẫu câu, tìm emoji, bảng sửa, bàn số giữ đầy bề ngang. Router [hit] giữ nguyên: khe giữa
    // cách mọi phím > 21 dp ⇒ không phím nào (vùng chết như Apple), mép phím vẫn nhận phím gần nhất.

    /** Bàn số kiểu Gboard (ô điện thoại / ô số) — phím cách không mang nhãn ngôn ngữ. */
    fun isNumberPad(p: Plane): Boolean = p == Plane.PHONE || p == Plane.NUMPAD

    /** Plane nào dựng tách đôi khi bật (như iOS: chữ, 123, #+=). */
    fun splitPlane(p: Plane): Boolean = p == Plane.LETTERS || p == Plane.NUMBERS || p == Plane.SYMBOLS

    /** Công tắc bật + bàn phím rộng ≥ [SplitLayout.MIN_WIDTH_DP] (không xét plane). */
    fun splitActive(c: LayoutConfig): Boolean = splitActive(c.split, c.widthPx, c.density)
    fun splitActive(setting: Boolean, widthPx: Float, density: Float): Boolean =
        setting && density > 0f && SplitLayout.active(true, widthPx / density)

    /** Hình học tách đôi (px) cho bề ngang [LayoutConfig.widthPx]. */
    fun splitMetrics(c: LayoutConfig): SplitLayout.Metrics {
        val d = c.density
        return SplitLayout.metrics(c.widthPx, ROW_MARGIN_H * d, KEY_SPACING * d, SplitLayout.MAX_PITCH_DP * d)
    }

    private fun buildSplit(out: MutableList<LaidKey>, c: LayoutConfig) {
        val d = c.density
        val m = splitMetrics(c)
        val p = m.pitch
        val xl = ROW_MARGIN_H * d
        val xr = c.widthPx - ROW_MARGIN_H * d - m.half
        // Phím đều [m.keyWidth] bắt đầu ở mép nửa + lề trong (đơn vị bước phím).
        fun keys(labels: List<String>, kind: Int, x0: Float, t: Float, b: Float) {
            var x = x0
            for (s in labels) {
                val up = if (kind == KeyKind.LETTER) s.uppercase() else s
                out += LaidKey(kind, s, up, s, x, t, x + m.keyWidth, b)
                x += p
            }
        }
        // Hàng 10 phím (số / ký hiệu) chia 5 | 5: nửa trái thụt phải ½, nửa phải thụt trái ½.
        fun tenRow(row: List<String>, t: Float, b: Float) {
            val (l, r) = SplitLayout.halves(row)
            keys(l, KeyKind.CHAR, xl, t, b)
            keys(r, KeyKind.CHAR, xr + 0.5f * p, t, b)
        }
        val letters = c.plane == Plane.LETTERS
        val u: Float
        val y0: Float
        if (c.numberRow) {
            u = rowUnit(c.keyAreaPx, true, d, c.numberRowFull)
            y0 = numberRowHeight(u, ROW_GAP * d, c.numberRowFull)
        } else { u = c.keyAreaPx / 4f; y0 = 0f }
        val sideW = 1.5f * p - KEY_SPACING * d      // ⇧ / ⌫ / phím chuyển plane hàng 3
        if (letters) {
            if (c.numberRow) tenRow(NUM1, keyTop(0, y0, d), keyBottom(0, y0, d))
            for (i in 0 until 2) {
                val (l, r) = SplitLayout.letterRows[i]
                val (il, ir) = SplitLayout.letterIndents[i]
                val t = keyTop(i, u, d, y0); val b = keyBottom(i, u, d, y0)
                keys(l.map { it.toString() }, KeyKind.LETTER, xl + il.l * p, t, b)
                keys(r.map { it.toString() }, KeyKind.LETTER, xr + ir.l * p, t, b)
            }
            // Hàng 3: [⇧] z x c v | v b n m [⌫] — ⇧ / ⌫ ≈ 1.5 bước.
            val (l3, r3) = SplitLayout.letterRows[2]
            val t = keyTop(2, u, d, y0); val b = keyBottom(2, u, d, y0)
            out += LaidKey(KeyKind.SHIFT, "", "", "", xl, t, xl + sideW, b)
            keys(l3.map { it.toString() }, KeyKind.LETTER, xl + 1.5f * p, t, b)
            keys(r3.map { it.toString() }, KeyKind.LETTER, xr, t, b)
            out += LaidKey(KeyKind.BACKSPACE, "", "", "", xr + 4f * p, t, xr + m.half, b)
            splitBottomRow(out, c, m, y0 + 3 * u, u, planeKey = "?123")
        } else {
            val rows = symbolicRows(c.plane == Plane.NUMBERS, c.numberRow)
            if (c.numberRow) {
                tenRow(rows[0], keyTop(0, y0, d), keyBottom(0, y0, d))
                tenRow(rows[1], keyTop(0, u, d, y0), keyBottom(0, u, d, y0))
                tenRow(rows[2], keyTop(1, u, d, y0), keyBottom(1, u, d, y0))
            } else {
                tenRow(rows[0], keyTop(0, u, d), keyBottom(0, u, d))
                tenRow(rows[1], keyTop(1, u, d), keyBottom(1, u, d))
            }
            // Hàng 3 như iOS buildSplitPlane: [#+= | 123] . , | ? ! ' [⌫] — ký tự = phím chuẩn đúng
            // cột hai hàng trên (trái: cột 4–5, phải: cột 1–3); phím đổi plane / ⌫ ăn phần còn lại.
            val l3 = THIRD.subList(0, THIRD_SPLIT_LEFT)
            val r3 = THIRD.subList(THIRD_SPLIT_LEFT, THIRD.size)
            val t = keyTop(2, u, d, y0); val b = keyBottom(2, u, d, y0)
            val more = moreKeyLabel(c.plane)
            val leftX = xl + (5 - l3.size) * p
            out += LaidKey(KeyKind.MORE, more, more, more, xl, t, leftX - KEY_SPACING * d, b)
            keys(l3, KeyKind.CHAR, leftX, t, b)
            keys(r3, KeyKind.CHAR, xr + 0.5f * p, t, b)
            out += LaidKey(KeyKind.BACKSPACE, "", "", "", xr + (0.5f + r3.size) * p, t, xr + m.half, b)
            splitBottomRow(out, c, m, y0 + 3 * u, u, planeKey = if (c.kind.padPlane != null) "123" else "ABC")
        }
    }

    /**
     * Hàng đáy tách: [?123|ABC][🌐?][😊?][space] | [space][dấu câu…][↵][ẩn? (tablet)]. Hai phím cách
     * cùng gõ dấu cách; phím PHẢI (sau cùng trong danh sách) mang logo / badge / trackpad như iOS.
     * Dấu câu nửa phải: bàn chữ ô thường theo "Phím cạnh dấu cách" ([sideKey]); ô email "@ .",
     * ô URL "/ ."; plane 123 / #+= ", ." (như bản không tách; hàng 3 cũng có . , như iOS).
     */
    private fun splitBottomRow(out: MutableList<LaidKey>, c: LayoutConfig, m: SplitLayout.Metrics,
                               rowTop: Float, rowH: Float, planeKey: String) {
        val d = c.density
        val gap = KEY_SPACING * d
        val t = rowTop + BOTTOM_ROW_TOP * d
        val b = rowTop + rowH - BOTTOM_ROW_BOTTOM * d
        val kw = m.keyWidth
        val letters = c.plane == Plane.LETTERS
        val left = ArrayList<Slot>(4)
        left += Slot(KeyKind.PLANE, planeKey, planeKey, kw)
        if (c.needsGlobe) left += Slot(KeyKind.GLOBE, "", "", kw)
        if (!(letters && c.emojiInStrip)) left += Slot(KeyKind.EMOJI, "", "", kw)
        left += Slot(KeyKind.SPACE, "", " ", -1f)
        val right = ArrayList<Slot>(5)
        right += Slot(KeyKind.SPACE, "", " ", -1f)
        val puncts: List<String> = if (letters) when (c.kind) {
            InputKind.EMAIL -> listOf("@", ".")
            InputKind.URL -> listOf("/", ".")
            else -> listOfNotNull(c.spaceSideKey.left, c.spaceSideKey.right)
        } else listOf(",", ".")
        for (s in puncts) right += Slot(KeyKind.PUNCT, s, s, 0.9f * kw)
        right += Slot(KeyKind.RETURN, c.returnLabel, "\n", 1.9f * kw)
        if (c.tablet) right += Slot(KeyKind.DISMISS, "", "", kw)
        val large = largeKeysActive(c)
        fun half(slots: MutableList<Slot>, x0: Float) {
            var fixed = 0f
            for (s in slots) if (s.mult > 0) fixed += s.mult
            var space = (m.half - fixed - gap * (slots.size - 1)).coerceAtLeast(gap)
            // "Phím to": "," / "." = phím 😊 nửa trái (kw), space nửa này co lại (có sàn).
            if (large) space = widenPuncts(slots, space, kw, d, scale = 1f)
            var x = x0
            for (s in slots) {
                val w = if (s.mult > 0) s.mult else space
                out += LaidKey(s.kind, s.label, s.label, s.insert, x, t, x + w, b)
                x += w + gap
            }
        }
        half(left, ROW_MARGIN_H * d)
        half(right, c.widthPx - ROW_MARGIN_H * d - m.half)
    }

    /** Tâm phím a–z (toạ độ view) cho SwipeLayout — lấy từ frame THẬT (kể cả một tay). */
    fun letterCenters(keys: List<LaidKey>): Map<Char, Pair<Float, Float>> {
        val m = HashMap<Char, Pair<Float, Float>>(32)
        for (k in keys) {
            if (k.kind != KeyKind.LETTER || k.label.length != 1) continue
            val ch = k.label[0]
            if (ch in 'a'..'z') m[ch] = k.centerX to k.centerY
        }
        return m
    }

    // MARK: router (port KeyboardView.routedHitTest / nearestLetterButton)

    /** Footprint nở của phím: dx 3 dp, dy 5.5 dp (UIButton.point(inside:)). */
    fun expandedContains(k: LaidKey, x: Float, y: Float, d: Float): Boolean {
        val dx = 3f * d; val dy = 5.5f * d
        return x >= k.left - dx && x < k.right + dx && y >= k.top - dy && y < k.bottom + dy
    }

    /** Khoảng cách² từ điểm tới hình chữ nhật phím (0 nếu nằm trong). */
    fun dist2(k: LaidKey, x: Float, y: Float): Float {
        val dx = maxOf(k.left - x, 0f, x - k.right)
        val dy = maxOf(k.top - y, 0f, y - k.bottom)
        return dx * dx + dy * dy
    }

    /**
     * Chọn phím cho một điểm chạm. `x, y` = điểm chạm thô; `yOffsetPx` =
     * TouchGeometry.yOffset (4 dp) — điểm chọn phím chữ dời lên.
     *
     * Plane chữ (y iOS): phím chữ thắng trong footprint THẬT của nó (kể cả khi vùng
     * nở của ⇧/⌫ đè lên); rồi tới phím chức năng theo vùng nở; rồi phím chữ gần
     * nhất trong 21 dp. Cuối cùng (Android, bịt khe chết giữa hàng 3 và hàng đáy):
     * phím bất kỳ gần nhất trong 21 dp. `sinceLetterMs` (ms từ lần chạm chữ trước) nới
     * dải ưu tiên mép của [HitBias] khi gõ cuộn.
     */
    fun hit(keys: List<LaidKey>, plane: Plane, x: Float, y: Float, yOffsetPx: Float, d: Float,
            sinceLetterMs: Long = Long.MAX_VALUE): LaidKey? {
        val py = y - yOffsetPx
        if (plane == Plane.LETTERS || plane == Plane.EMOJI_SEARCH) {
            var inCore = false
            for (i in keys.indices) {
                val k = keys[i]
                if (k.kind == KeyKind.LETTER && k.contains(x, y)) { inCore = true; break }
            }
            if (inCore) return nearestLetter(keys, x, py, d)
            for (i in keys.indices.reversed()) {
                val k = keys[i]
                // Mép chung (HitBias): "," sát space ⇒ space. ⇧/⌫ không nhường cho chữ.
                if (k.kind != KeyKind.LETTER && expandedContains(k, x, y, d))
                    return HitBias.refine(keys, k, x, y, sinceLetterMs, d)
            }
            // Khe cạnh phím chức năng (m↔⌫, z↔⇧, mép màn hình) ⇒ phím chức năng.
            gutterOwner(keys, x, y, d)?.let { return it }
            nearestLetter(keys, x, py, d)?.let { return it }
        } else {
            for (i in keys.indices.reversed()) {
                val k = keys[i]
                if (expandedContains(k, x, y, d)) return HitBias.refine(keys, k, x, y, sinceLetterMs, d)
            }
        }
        var best: LaidKey? = null
        var bestD = Float.MAX_VALUE
        for (i in keys.indices) {
            val dd = dist2(keys[i], x, y)
            if (dd < bestD) { bestD = dd; best = keys[i] }
        }
        val lim = 21f * d
        return if (best != null && bestD <= lim * lim) best else null
    }

    /**
     * Phím chức năng sở hữu khe quanh nó (song sinh iOS SpecialKeyGutter.owner — 10/10/2026, bug
     * "bấm ⌫ hay thành m / l"). Lõi phím chữ ⇒ null. Khe CÙNG HÀNG ≤ 16 dp cạnh phím chức năng
     * ⇒ phím đó, trừ 3 dp sát mép phím chữ (nửa khe chữ↔chữ). Khe trên/dưới trong khoảng x của
     * nó ≤ 5.5 dp ⇒ phím đó. Nhiều phím ⇒ gần nhất.
     */
    fun gutterOwner(keys: List<LaidKey>, x: Float, y: Float, d: Float): LaidKey? {
        for (k in keys) if (k.kind == KeyKind.LETTER && k.contains(x, y)) return null
        val reach = 3f * d; val maxGap = 16f * d; val rowReach = 5.5f * d
        var best: LaidKey? = null
        var bestD = Float.MAX_VALUE
        for (k in keys) {
            if (k.kind == KeyKind.LETTER) continue
            val dd: Float
            if (k.contains(x, y)) dd = 0f
            else if (x >= k.left && x <= k.right) {
                dd = maxOf(k.top - y, y - k.bottom)
                if (dd > rowReach) continue
            } else {
                if (y < k.top || y > k.bottom) continue
                dd = maxOf(k.left - x, x - k.right)
                if (dd <= 0f || dd > maxGap) continue
                for (l in keys) {
                    if (l.kind == KeyKind.LETTER && y >= l.top && y <= l.bottom &&
                        x >= l.left - reach && x < l.right + reach) return null
                }
            }
            if (dd < bestD) { bestD = dd; best = k }
        }
        return best
    }

    /** nearestLetterButton: footprint nở ⇒ phím đó; không thì gần nhất nếu ≤ 21 dp. */
    fun nearestLetter(keys: List<LaidKey>, x: Float, y: Float, d: Float): LaidKey? {
        var best: LaidKey? = null
        var bestD = Float.MAX_VALUE
        for (i in keys.indices) {
            val k = keys[i]
            if (k.kind != KeyKind.LETTER) continue
            if (expandedContains(k, x, y, d)) return k
            val dd = dist2(k, x, y)
            if (dd < bestD) { bestD = dd; best = k }
        }
        val lim = 21f * d
        return if (best != null && bestD <= lim * lim) best else null
    }
}

/**
 * Kẹp cỡ chữ nhãn phím ("Cỡ chữ trên phím" = Lớn) theo bề ngang phím — THUẦN, pinned by
 * KeyLayoutTest. [glyphW] = bề ngang chữ rộng nhất ("W") ở cỡ [want]; chữ phải chừa [pad] mỗi
 * bên trong phím [keyW]. Không vừa ⇒ thu nhỏ tỉ lệ, nhưng không nhỏ hơn cỡ chuẩn [min].
 */
object KeyLabelFit {
    const val PAD_DP = 3f

    fun fit(want: Float, min: Float, glyphW: Float, keyW: Float, pad: Float): Float {
        val room = keyW - 2 * pad
        if (glyphW <= 0f || glyphW <= room) return want
        return maxOf(minOf(min, want), want * maxOf(room, 0f) / glyphW)
    }
}
