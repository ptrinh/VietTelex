package com.viettelex.android.ime

import android.annotation.SuppressLint
import android.content.Context
import android.graphics.Canvas
import android.graphics.Paint
import android.text.TextPaint
import android.text.TextUtils
import android.view.MotionEvent
import android.view.View
import com.viettelex.android.R
import com.viettelex.keyboard.BarChip
import com.viettelex.keyboard.BarLayout
import com.viettelex.keyboard.SlotTapLatch
import com.viettelex.keyboard.SuggestionBarHeight
import com.viettelex.keyboard.SuggestionCount
import com.viettelex.keyboard.SuggestionSet
import com.viettelex.keyboard.SuggestionSlots
import kotlin.math.abs
import com.viettelex.keyboard.tr

/**
 * Strip gợi ý (spec §6.6, §7.1): [☰ 52][ "nguyên văn" | từ 1 | từ 2 / ≤3 emoji ][😊][📋][nhân vật]([⌄ 52])
 * sát mép phải — nút ⌄ thu gọn đã bỏ (10/2026, nhường chỗ cho gợi ý); ⌄ ẨN BÀN PHÍM (11/2026) chỉ khi bật
 * "Nút ẩn bàn phím" (mặc định tắt ⇒ bố cục y như trước, [StripGeometry.dismissShown]); thẻ Dán kiểu iOS 27.
 * View này PHỦ lên mép trên vùng phím 4 dp — chạm không trúng mục tiêu nào trả false
 * để rơi xuống [KeyboardView].
 */
@SuppressLint("ViewConstructor")
class StripView(context: Context, private val theme: ImeTheme, private val feedback: Feedback) : View(context) {

    interface Listener {
        fun onSuggestion(item: String)
        fun onToggleTemplates()
        /** Chạm ô "↩︎ Khôi phục" sau vuốt ⌫ xoá theo từ. */
        fun onRestoreDeleted()
        /** Icon con trỏ: mở/đóng bảng sửa văn bản. */
        fun onToggleEditPanel()
        /** Giữ lâu icon con trỏ: bật/tắt chế độ một tay (chỉ khi [oneHandAvailable]). */
        fun onToggleOneHand()
        /** Nút 📋 (khi lịch sử clipboard bật): mở/đóng bảng lịch sử. */
        fun onToggleClipboard()
        /** Nút 🎤 (#175, khi máy có bộ nhận giọng nói): chuyển sang gõ giọng nói. */
        fun onVoiceInput() {}
        /** Nút 😊 ("Nút emoji" = Thanh trên): chạm = bảng emoji. */
        fun onEmojiButton() {}
        fun onBuddyTickle() {}
        /**
         * Giữ nút 😊 strip: menu như giữ phím 😊 (đổi bàn phím, giọng nói, một tay…). Toạ độ px của
         * StripView; IME đổi sang toạ độ bàn phím. true = menu đã mở (nhận [onEmojiButtonHoldMove]).
         */
        fun onEmojiButtonHold(anchorCx: Float, anchorTop: Float, anchorBottom: Float, x: Float, y: Float): Boolean = false
        fun onEmojiButtonHoldMove(x: Float, y: Float) {}
        fun onEmojiButtonHoldEnd(cancel: Boolean) {}
        /** ⌄ "Nút ẩn bàn phím" (góc phải dải): ẩn bàn phím — cùng tên KeyboardView.Listener (IME requestHideSelf). */
        fun onDismissKeyboard() {}
        /** ← trên dải ở bàn emoji: về bàn chữ. */
        fun onBackToLetters() {}
    }

    /** Điện thoại (không tablet): giữ lâu icon con trỏ = một tay. */
    var oneHandAvailable = false

    /**
     * Lời mời dán (thẻ Dán / chip clipboard) hiện (true) / rời bar (false) — PasteOfferOnce.
     * Gọi khi ĐỔI, và mỗi lượt show khi đang hiện; lúc gõ chữ (không có lời mời) không gọi.
     */
    var onPasteOffer: ((Boolean) -> Unit)? = null
    private var pasteOfferOn = false
    private fun notePasteOffer(on: Boolean = paste || (0 until chipCount).any { i ->
        slotPayload[i]?.let { it == SuggestionSet.PASTE_TOKEN || it.startsWith(SuggestionSet.CLIP_CHIP_PREFIX) } == true
    }) {
        if (!on && on == pasteOfferOn) return
        pasteOfferOn = on
        onPasteOffer?.invoke(on)
    }

    var listener: Listener? = null

    private val d = theme.density
    var suggestionsEnabled = false; private set
    /** Dải giữ chỗ (công tắc toàn cục — [KeyLayout.stripReserved]); nội dung theo [suggestionsEnabled]. */
    private var reserved = false
    private var plane = Plane.LETTERS
    private var templatesEnabled = true
    /**
     * Công cụ văn bản hiện (Plus + công tắc, không phải ô mật khẩu) — Mẫu câu tắt mà công cụ
     * bật thì ☰ vẫn hiện, mở thẳng công cụ (TemplatesMenu). IME đặt mỗi lần vào ô.
     */
    var toolsEnabled = false
        set(v) { if (field != v) { field = v; invalidate() } }
    private fun burgerShown() =
        TemplatesMenu.leftZone(templatesEnabled, toolsEnabled) != TemplatesMenu.LeftZone.NONE

    // --- nội dung bar ---
    // Pool cố định SuggestionCount.MAX ô; đang dùng [slotCount] ô ("Số từ gợi ý" — [slotSetting]).
    private val slotText = arrayOfNulls<String>(SuggestionCount.MAX)      // đã ellipsize
    private val slotPayload = arrayOfNulls<String>(SuggestionCount.MAX)
    /** Hệ số co chữ của ô (StripGeometry.fitScale): từ dài co lại trước, hết mức mới cắt giữa (#178). */
    private val slotScale = FloatArray(SuggestionCount.MAX) { 1f }
    private val slotL = FloatArray(SuggestionCount.MAX); private val slotR = FloatArray(SuggestionCount.MAX)
    /** "Số từ gợi ý" (0 = Tự động). */
    private var slotSetting = SuggestionCount.AUTO
    /** Số ô đang dùng = [SuggestionCount.fit] theo bề rộng bar (ô < 44 dp ⇒ bớt ô). */
    private var slotCount = SuggestionCount.AUTO_SLOTS
    /** Ô tô đậm (Gboard: gợi ý chính) — [SuggestionSlots.primaryIndex]. */
    private var primary = 1
    /**
     * Ô tô nền (ONBOARDING-SPEC §8: bản tự sửa dấu cách sẽ áp) — -1 = không. Vẽ cùng nền/chữ chip
     * của theme ([ImeTheme.chip] / [ImeTheme.chipInk]) ⇒ theo sáng/tối và theme tự tạo.
     */
    private var highlight = -1
    private val emojiText = arrayOfNulls<String>(3)
    private val emojiL = FloatArray(3); private val emojiR = FloatArray(3)
    private var emojiCount = 0
    private var paste = false
    /** Slot đang là chip tách số (vẽ nền pill, chia đều bar theo [chipCount]). */
    private var chipCount = 0
    /** Nút 📋 lịch sử clipboard (sát phải bar, bar co lại). */
    private var clipButton = false
    private var clipOpen = false
    /** Nút 🎤 gõ giọng nói (#175) — trái ô 📋, ẩn/hiện cùng 📋 ([tools]). IME đặt theo VoiceInput.available. */
    private var voiceButton = false
    fun setVoiceButton(on: Boolean) {
        if (on == voiceButton) return
        voiceButton = on
        lastSet?.let { layoutSlots(it) }
        layoutPaste()
        invalidate()
    }
    /** Cụm công cụ mép phải (📋 + 🎤): có nút nào không / bề ngang dp. */
    private fun rightTools() = clipButton || voiceButton
    private fun rightToolsW() = StripGeometry.rightToolsW(clipButton, voiceButton)
    /** Nút 😊 sát mép phải ("Nút emoji" = Thanh trên) — luôn hiện (cả khi có gợi ý), StripGeometry.EMOJI_W. */
    var emojiButton = false; private set
    /** Công tắc "Nút ẩn bàn phím" (mặc định TẮT) — ⌄ hiện thật theo [dismissShown]. */
    var dismissButton = false; private set
    /** ⌄ ẩn bàn phím đang hiện (bật + dải giữ chỗ + không ở bàn emoji). Hiện cả khi dải TRỐNG (ô mật khẩu). */
    private fun dismissShown(): Boolean =
        StripGeometry.dismissShown(dismissButton, reserved, plane == Plane.EMOJI || plane == Plane.EMOJI_SEARCH)
    /** Bề ngang ô ⌄ (px); 0 khi không hiện ⇒ mọi khung bên phải y như chưa có nút. Root dùng đặt ô nhân vật. */
    fun dismissPx(): Float = theme.dp(StripGeometry.dismissW(dismissShown()))
    private var lastSig = ""
    private var lastSet: SuggestionSet? = null
    /** Bộ gợi ý đang hiện (Đập chuột đọc ứng viên lúc thả chuột — không mỗi phím). */
    val shownSet: SuggestionSet? get() = lastSet
    /** Bar đang có nội dung gợi ý (chữ/emoji/chip/thẻ Dán/pill) ⇒ ẩn icon con trỏ + 📋 (#113). */
    private var hasContent = false

    /** Icon con trỏ + 📋 có hiện không — chỉ đổi khi nội dung rỗng↔có (StripGeometry.toolsShown). */
    private fun tools(): Boolean = StripGeometry.toolsShown(hasContent, plane == Plane.EDIT, clipOpen)

    /** Chữ ô gợi ý ("Màu chữ gợi ý", mặc định Xám) — giải lúc configure, không mỗi lần vẽ. */
    private var wordInk = theme.suggestionInk(com.viettelex.keyboard.SuggestionInk.DEFAULT)
    private val wordPaint = TextPaint(theme.text(StripGeometry.WORD_SP, color = theme.barInk))
    private var wordOff = theme.centerOffset(wordPaint)
    /** Gboard nhấn mạnh gợi ý giữa (medium). */
    private val wordCenterPaint = TextPaint(theme.text(StripGeometry.WORD_SP, color = theme.barInk, medium = true))
    private var wordCenterOff = theme.centerOffset(wordCenterPaint)
    init {
        // Phông điểm ảnh (theme Pixel 8-bit) cả trên ô gợi ý — iOS refreshBarFonts y hệt. Theme khác: null, không đổi gì.
        theme.stripTypeface?.let { tf ->
            wordPaint.typeface = tf; wordCenterPaint.typeface = tf
            wordOff = theme.centerOffset(wordPaint); wordCenterOff = theme.centerOffset(wordCenterPaint)
        }
    }
    /** Strip MỞ (dp) theo "Chiều cao thanh gợi ý" ([SuggestionBarHeight]; mặc định Vừa = [KeyLayout.OPEN_STRIP]). */
    var openStripDp = KeyLayout.OPEN_STRIP; private set
    /** Tâm dọc nội dung bar khi mở (dp). */
    private fun barCyDp() = KeyLayout.barCy(openStripDp)
    private val emojiPaint = theme.text(22f)
    private val emojiOff = theme.centerOffset(emojiPaint)
    private val iconPaint = Paint(Paint.ANTI_ALIAS_FLAG)
    private val pasteTitle = theme.text(15f, color = theme.barInk, medium = true, align = Paint.Align.LEFT)
    private val pasteSub = theme.text(13f, color = theme.withAlpha(theme.barInk, 0.7f), align = Paint.Align.LEFT)
    private val pasteTitleText = tr("Dán")
    private val pasteSubText = tr("Nội dung vừa copy")
    private var pasteIconCx = 0f; private var pasteTextX = 0f; private var pasteSubX = 0f
    private var pasteL = 0f; private var pasteR = 0f; private var pasteT = 0f; private var pasteB = 0f
    private var pasteShowSub = true
    private val chipPaint = theme.fill(theme.chip)
    /**
     * Độ mờ chip (hoạt ảnh / nhấn, 0…255) NHÂN vào alpha gốc của chip — không `chipPaint.alpha = …`: chip bán
     * trong (Kính tối = trắng 30%, độ trong suốt phím) sẽ thành trắng đặc, chữ trắng biến mất (bug 19/10/2026).
     */
    private fun setChipOpacity(a: Int) { chipPaint.color = theme.chipFill(a / 255f) }
    private val pressPaint = theme.fill(theme.withAlpha(theme.barInk, 0.10f))
    private var pressed = T_NONE
    private var pressedIndex = 0
    private var pasteTitleBase = 0f; private var pasteSubBase = 0f; private var pasteIconCy = 0f

    // --- vuốt ⌫: xem trước đoạn sẽ xoá / ô Khôi phục (đè nội dung bar tới khi gỡ) ---
    private var swipePreview: String? = null
    /** Dòng trạng thái không chạm được (vd "Đang dịch…", nhắc tải gói dịch); null = gỡ. */
    private var statusText: String? = null
    private var restoreOffer = false
    /** Hoàn tác thêm dấu (SuggestionSlots tầng 1) — vẽ cùng kiểu pill ô Khôi phục. */
    private var actionPill: BarChip? = null
    private val restoreDefault = "↩\uFE0E " + tr("Khôi phục")
    private var restoreText = restoreDefault
    private val chipText = TextPaint(theme.text(15f, color = theme.barInk, medium = true))
    private val chipTextOff = theme.centerOffset(chipText)

    // --- touch ---
    private var target = T_NONE
    private var targetIndex = 0
    private var downX = 0f; private var downY = 0f

    init {
        importantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_NO
        layoutPaste()
    }

    /** Bề rộng dành cho nhân vật + 😊 + 📋 ở mép phải. */
    private fun extraW(): Float = theme.dp(StripGeometry.rightExtraW(rightToolsW(), rightTools(), tools(), emojiButton, buddyDp,
        StripGeometry.dismissW(dismissShown())))

    /**
     * Ô "Bạn đồng hành" (dp; 0 = tắt): bar chừa đúng bấy nhiêu sát mép phải, 😊 / 📋 dời trái — nhân vật không
     * bao giờ đè chip. IME đặt mỗi lần hiện.
     */
    var buddyDp = 0f
        set(v) { if (field != v) { field = v; lastSet?.let { layoutSlots(it) }; layoutPaste(); onBuddySlot?.invoke(); invalidate() } }
    /** Ô nhân vật đang hiện (bar mở, plane chữ/số). */
    fun buddySlotShown(): Boolean = buddyDp > 0f && barVisible
    var buddyFigure: com.viettelex.keyboard.BuddyRect? = null
    /** Gọi khi [buddySlotShown] có thể đổi (plane, cấu hình). */
    var onBuddySlot: (() -> Unit)? = null
    /** Lề mỗi bên cho pill căn giữa: zone ☰ + phần lớn hơn giữa icon con trỏ (trái) và 😊/📋/nhân vật (phải). */
    private fun sideW(): Float = theme.dp(KeyLayout.STRIP_ZONE_W) + maxOf(if (tools()) theme.dp(STRIP_TOOL_W) else 0f, extraW())

    /** Nút 📋 (lịch sử bật) + chỉ báo ẩn danh; [open] = bảng lịch sử đang mở (tô đậm). */
    fun setExtras(clipButton: Boolean, open: Boolean = clipOpen) {
        if (clipButton == this.clipButton && open == clipOpen) return
        this.clipButton = clipButton; clipOpen = open
        lastSet?.let { layoutSlots(it) }
        layoutPaste()
        invalidate()
    }

    /** Chiều cao strip (dp → px) — root dùng để đặt vùng phím. */
    fun stripPx(): Float = if (!reserved) 0f else theme.dp(openStripDp)

    /** Chiều cao view = strip + 4 dp phủ lên mép hàng phím. */
    fun viewHeightPx(): Int = if (!reserved) 0 else (stripPx() + theme.dp(4f)).toInt()

    /** [reserved]: giữ chỗ dải dù ô này không có gợi ý (bàn phím không đổi cao giữa các ô). */
    fun configure(enabled: Boolean, templatesEnabled: Boolean, reserved: Boolean = enabled,
                  emojiButton: Boolean = false, slotSetting: Int = SuggestionCount.AUTO,
                  barHeight: SuggestionBarHeight = SuggestionBarHeight.DEFAULT, landscapeCap: Boolean = false,
                  suggestionInk: com.viettelex.keyboard.SuggestionInk = com.viettelex.keyboard.SuggestionInk.DEFAULT,
                  dismissButton: Boolean = false) {
        this.slotSetting = slotSetting
        wordInk = theme.suggestionInk(suggestionInk)
        applyBarHeight(barHeight, landscapeCap)
        if (emojiButton != this.emojiButton) { this.emojiButton = emojiButton; layoutPaste() }
        val dismissBefore = dismissShown()
        this.suggestionsEnabled = enabled
        this.reserved = reserved || enabled
        this.templatesEnabled = templatesEnabled
        this.dismissButton = dismissButton
        if (dismissShown() != dismissBefore) layoutPaste()   // slot: lượt show kế (lastSig rỗng) đặt lại
        lastSig = ""
        if (!enabled) { clearContent(); notePasteOffer(false) }
        onBuddySlot?.invoke()
        invalidate()
    }

    /** "Chiều cao thanh gợi ý": strip mở + cỡ chữ gợi ý (chỉ khi đổi — lúc hiện bàn phím, không mỗi phím). */
    private fun applyBarHeight(h: SuggestionBarHeight, landscapeCap: Boolean) {
        val open = h.openStripDp(landscapeCap)
        val sp = theme.sp(h.wordSp(landscapeCap))
        if (open == openStripDp && sp == wordPaint.textSize) return
        openStripDp = open
        if (sp != wordPaint.textSize) {
            wordPaint.textSize = sp; wordCenterPaint.textSize = sp
            wordOff = theme.centerOffset(wordPaint); wordCenterOff = theme.centerOffset(wordCenterPaint)
        }
        lastSet?.let { layoutSlots(it) }
        layoutPaste()
    }

    fun setPlane(p: Plane) {
        if (p == plane) return
        val before = tools()
        val dismissBefore = dismissShown()
        plane = p
        onBuddySlot?.invoke()
        if (p == Plane.EMOJI || p == Plane.EMOJI_SEARCH) { paste = false; notePasteOffer(false) }
        if (tools() != before || dismissShown() != dismissBefore) { lastSet?.let { layoutSlots(it) }; layoutPaste() }
        invalidate()
    }

    private val barVisible get() = suggestionsEnabled && plane != Plane.EMOJI && plane != Plane.EMOJI_SEARCH

    private fun clearContent() {
        for (i in slotText.indices) { slotText[i] = null; slotPayload[i] = null }
        for (i in emojiText.indices) emojiText[i] = null
        emojiCount = 0; paste = false; chipCount = 0; actionPill = null; highlight = -1
        lastSet = null; hasContent = false
    }

    /** Vuốt ⌫: đoạn sẽ xoá (null = gỡ). */
    fun showSwipePreview(text: String?) {
        if (text == swipePreview) return
        swipePreview = text
        invalidate()
    }

    /** Trạng thái tạm (không chạm được) đè lên thanh gợi ý; null = gỡ. */
    fun showStatus(text: String?) {
        if (text == statusText) return
        statusText = text
        invalidate()
    }

    /** Ô "↩︎ Khôi phục" một lượt sau vuốt ⌫ xoá; [label] khác (vd "Hoàn tác" công cụ văn bản). */
    fun showRestore(on: Boolean, label: String? = null) {
        val text = label?.let { "↩\uFE0E $it" } ?: restoreDefault
        if (on == restoreOffer && text == restoreText) return
        restoreOffer = on
        restoreText = text
        invalidate()
    }

    /** Có phím chữ ⇒ ẩn thẻ Dán NGAY (không đợi gợi ý nền). */
    fun hidePasteCard() {
        notePasteOffer(false)
        if (!paste) return
        paste = false; lastSig = ""
        invalidate()
    }

    /** Token AI: gợi ý vừa đổi (sau khi xếp ô) — IME chỉ đặt khi kiểu là Token AI; null = 0 chi phí. */
    var onShown: ((SuggestionSet) -> Unit)? = null
    /** Mép trái / phải vùng ô gợi ý (px, toạ độ view này) của lần xếp gần nhất. */
    var slotSpanL = 0f; private set
    var slotSpanR = 0f; private set

    fun show(set: SuggestionSet?) {
        if (!suggestionsEnabled) return
        if (set == null) return
        val sig = set.signature() + (if (set.paste) "\u0005p" else "")
        if (sig != lastSig || width <= 0) {
            lastSig = sig
            lastSet = set
            layoutSlots(set)
            invalidate()
            onShown?.invoke(set)
        }
        notePasteOffer()
    }

    override fun onSizeChanged(w: Int, h: Int, oldw: Int, oldh: Int) {
        if (w != oldw) { lastSet?.let { layoutSlots(it) }; layoutPaste() }
    }

    private fun layoutSlots(set: SuggestionSet) {
        val disp = arrayOfNulls<String>(SuggestionCount.MAX)
        val toolsBefore = tools()
        clearContent()
        lastSet = set
        // Thứ tự ưu tiên slot (hoàn tác > clipboard > Thêm dấu > chip số > chữ): SuggestionSlots.
        // Gboard: từ kế tiếp tốt nhất ở GIỮA; không ngoặc kép quanh nguyên văn.
        var l = SuggestionSlots.arrange(set, undoAsPill = true, bestInMiddle = true, pasteLabel = pasteTitleText,
            count = SuggestionCount.resolved(slotSetting))
        hasContent = StripGeometry.hasContent(l, set.idle)
        val shown = tools()
        if (shown != toolsBefore) layoutPaste()
        // Trái: ô mẫu câu + icon con trỏ (bảng sửa); phải: 😊 / 📋 / nhân vật sát mép. Có gợi ý ⇒ ẩn con trỏ/📋 (#113).
        val barL = theme.dp(StripGeometry.barLeft(KeyLayout.STRIP_ZONE_W, STRIP_TOOL_W, shown))
        val barR = theme.dp(StripGeometry.barRight(width / d, rightToolsW(), rightTools(), shown, emojiButton, buddyDp,
            StripGeometry.dismissW(dismissShown())))
        slotSpanL = barL; slotSpanR = barR
        // Bar chật (máy nhỏ, icon con trỏ/📋/😊 đang hiện) ⇒ bớt ô cho mỗi ô ≥ 44 dp.
        slotCount = if (width > 0) SuggestionCount.fit(slotSetting, (barR - barL) / d) else SuggestionCount.resolved(slotSetting)
        if (l is BarLayout.Slots && l.slots.size != slotCount)
            l = SuggestionSlots.arrange(set, undoAsPill = true, bestInMiddle = true, pasteLabel = pasteTitleText, count = slotCount)
        val led = set.action == SuggestionSet.ADD_TONES_TOKEN || set.action == SuggestionSet.UNDO_REVISE_TOKEN ||
            set.action == SuggestionSet.UNDO_AUTOCORRECT_TOKEN || set.action == SuggestionSet.RETRO_OFFER_TOKEN ||
            set.action == SuggestionSet.UNDO_RETRO_TOKEN
        primary = SuggestionSlots.primaryIndex(slotCount, set.nextWords.isNotEmpty() && !led, bestInMiddle = true)
        when (l) {
            is BarLayout.Pill -> { actionPill = l.chip; return }
            BarLayout.PasteCard -> { paste = true; return }
            is BarLayout.Chips -> {
                // Chip tách số thay thẻ Dán: [Dán OTP 482913][Dán] — chia đều bar, nền pill.
                chipCount = l.chips.size
                val each = (barR - barL) / chipCount
                val pad = theme.dp(10f)
                for (i in 0 until chipCount) {
                    slotL[i] = barL + i * each; slotR[i] = slotL[i] + each
                    slotPayload[i] = l.chips[i].payload
                    slotText[i] = TextUtils.ellipsize(l.chips[i].label, chipText, each - 2 * pad - theme.dp(4f),
                        TextUtils.TruncateAt.END).toString()
                }
                return
            }
            is BarLayout.Slots -> {
                for (i in l.slots.indices) l.slots[i]?.let { disp[i] = it.label; slotPayload[i] = it.payload }
                highlight = l.slots.indexOfFirst { it?.highlight == true }
                emojiCount = l.emojis.size
                for (i in l.emojis.indices) emojiText[i] = l.emojis[i]
            }
        }

        // Gboard: [slotCount] ô bằng nhau (Tự động = 3), không vạch ngăn; emoji chia đều ô cuối.
        val n = slotCount
        val cell = (barR - barL) / n
        val pad = theme.dp(4f)
        StripGeometry.cells(barL, barR, n, slotL, slotR)
        for (i in 0 until n) {
            val t = disp[i] ?: continue
            val p = if (i == primary || i == highlight) wordCenterPaint else wordPaint
            val maxW = cell - 2 * pad
            val k = StripGeometry.fitScale(p.measureText(t), maxW)
            slotScale[i] = k
            if (k < 1f) {
                val full = p.textSize
                p.textSize = full * k
                slotText[i] = TextUtils.ellipsize(t, p, maxW, TextUtils.TruncateAt.MIDDLE).toString()
                p.textSize = full
            } else slotText[i] = t
        }
        if (emojiCount > 0) {
            val each = cell / emojiCount
            val z = slotL[n - 1]
            for (i in 0 until emojiCount) { emojiL[i] = z + i * each; emojiR[i] = z + (i + 1) * each }
        }
    }

    /** Chip clipboard kiểu Gboard: pill màu secondary container giữa bar, icon + "Dán" + mô tả. */
    private fun layoutPaste() {
        val cy = theme.dp(barCyDp())
        val h = theme.dp(StripGeometry.PILL_H)
        val icon = theme.dp(18f); val gap = theme.dp(6f); val padH = theme.dp(12f)
        val tW = pasteTitle.measureText(pasteTitleText); val sW = pasteSub.measureText(pasteSubText)
        val maxW = maxOf(0f, width - 2 * sideW())
        var total = padH + icon + gap + tW + gap + sW + padH
        pasteShowSub = total <= maxW
        if (!pasteShowSub) total = padH + icon + gap + tW + padH
        pasteL = (width - total) / 2; pasteR = pasteL + total
        pasteT = cy - h / 2; pasteB = cy + h / 2
        pasteIconCx = pasteL + padH + icon / 2
        pasteIconCy = cy
        pasteTextX = pasteL + padH + icon + gap
        pasteSubX = pasteTextX + tW + gap
        pasteTitleBase = cy + theme.centerOffset(pasteTitle)
        pasteSubBase = cy + theme.centerOffset(pasteSub)
    }

    // MARK: vẽ

    override fun onDraw(c: Canvas) {
        ImeTrace.drew(keys = false)
        // ⌄ ẩn bàn phím: vẽ TRƯỚC khi xét bar — dải trống (ô mật khẩu) vẫn có nút.
        if (dismissShown()) drawDismiss(c, width.toFloat(), theme.dp(barCyDp()))
        if (emojiTools) { drawEmojiTools(c); return }
        if (!barVisible) return
        val w = width.toFloat()
        val cyOpen = theme.dp(barCyDp())
        val cy = cyOpen
        val icon = theme.dp(StripGeometry.ICON_OPEN)
        if (burgerShown()) {
            val bx = theme.dp(26f)
            val active = plane == Plane.TEMPLATES
            if (active) c.drawCircle(bx, cy, theme.dp(18f), chipPaint)
            iconPaint.color = theme.withAlpha(theme.barInk, if (active) 1f else 0.75f)
            ImeIcons.draw(c, ImeIcons.GRID, bx, cy, icon, iconPaint)
        }
        if (tools()) {
            // Icon con trỏ (bảng sửa văn bản) cạnh ô mẫu câu — ẩn khi đang có gợi ý (#113).
            val ex = theme.dp(KeyLayout.STRIP_ZONE_W + STRIP_TOOL_W / 2)
            val active = plane == Plane.EDIT
            if (active || pressed == T_EDIT) c.drawCircle(ex, cy, theme.dp(18f), chipPaint)
            iconPaint.color = theme.withAlpha(theme.barInk, if (active) 1f else 0.75f)
            ImeIcons.draw(c, ImeIcons.CURSOR, ex, cy, icon, iconPaint)
        }
        drawExtras(c, w, cy)
        val alpha = 255
        statusText?.let { drawChip(c, it, alpha, TextUtils.TruncateAt.END); return }
        swipePreview?.let { drawChip(c, "⌫ " + it.replace('\n', ' '), alpha, TextUtils.TruncateAt.START); return }
        if (restoreOffer) { drawChip(c, restoreText, alpha, TextUtils.TruncateAt.END); return }
        actionPill?.let { drawChip(c, it.label, alpha, TextUtils.TruncateAt.END); return }
        if (paste) { drawPaste(c, alpha); return }
        val barCy = cyOpen
        val hh = theme.dp(StripGeometry.PILL_H / 2); val inset = theme.dp(2f)
        if (pressed == T_SLOT) {
            val i = pressedIndex
            c.drawRoundRect(slotL[i] + inset, barCy - hh, slotR[i] - inset, barCy + hh, hh, hh, pressPaint)
        } else if (pressed == T_EMOJI) {
            val i = pressedIndex
            c.drawRoundRect(emojiL[i] + inset, barCy - hh, emojiR[i] - inset, barCy + hh, hh, hh, pressPaint)
        }
        if (chipCount > 0) {
            chipText.color = theme.chipInk; chipText.alpha = alpha
            val ci = theme.dp(3f)
            for (i in 0 until chipCount) {
                val s = slotText[i] ?: continue
                setChipOpacity(if (pressed == T_SLOT && pressedIndex == i) (alpha * 0.8f).toInt() else alpha)
                c.drawRoundRect(slotL[i] + ci, barCy - hh, slotR[i] - ci, barCy + hh, hh, hh, chipPaint)
                c.drawText(s, (slotL[i] + slotR[i]) / 2, barCy + chipTextOff, chipText)
            }
            setChipOpacity(255)
            return
        }
        // alpha hoạt ảnh nhân alpha của màu chữ (Xám = chữ bán trong).
        val wa = alpha * com.viettelex.keyboard.ThemeColor.alpha(wordInk) / 255
        wordPaint.color = wordInk; wordPaint.alpha = wa
        wordCenterPaint.color = wordInk; wordCenterPaint.alpha = wa
        for (i in 0 until slotCount) {
            val s = slotText[i] ?: continue
            if (i == highlight) {
                // Ô tô nền (§8): pill màu chip theme, chữ đậm màu chữ chip.
                setChipOpacity(if (pressed == T_SLOT && pressedIndex == i) (alpha * 0.8f).toInt() else alpha)
                c.drawRoundRect(slotL[i] + inset, barCy - hh, slotR[i] - inset, barCy + hh, hh, hh, chipPaint)
                setChipOpacity(255)
                wordCenterPaint.color = theme.chipInk; wordCenterPaint.alpha = alpha
                drawWord(c, s, i, barCy + wordCenterOff, wordCenterPaint)
                wordCenterPaint.color = wordInk; wordCenterPaint.alpha = wa
            } else if (i == primary) drawWord(c, s, i, barCy + wordCenterOff, wordCenterPaint)
            else drawWord(c, s, i, barCy + wordOff, wordPaint)
        }
        emojiPaint.alpha = alpha
        for (i in 0 until emojiCount) {
            val s = emojiText[i] ?: continue
            c.drawText(s, (emojiL[i] + emojiR[i]) / 2, barCy + emojiOff, emojiPaint)
        }
    }

    /** ⌄ ẩn bàn phím canh giữa ô sát mép phải (icon bàn phím + mũi tên xuống, như phím ẩn hàng đáy tablet). */
    private fun drawDismiss(c: Canvas, w: Float, cy: Float) {
        val cx = w - dismissPx() / 2
        if (pressed == T_DISMISS) c.drawCircle(cx, cy, theme.dp(18f), chipPaint)
        iconPaint.color = theme.withAlpha(theme.barInk, 0.75f)
        ImeIcons.draw(c, ImeIcons.KB_DISMISS, cx, cy, theme.dp(StripGeometry.ICON_OPEN), iconPaint)
    }

    /** Bàn emoji: ← về bàn chữ (mép trái), 📋 dán (mép phải) — [StripGeometry.emojiPlaneTools]. */
    private val emojiTools get() = StripGeometry.emojiPlaneTools(plane == Plane.EMOJI, reserved)
    private fun drawEmojiTools(c: Canvas) {
        val cy = theme.dp(barCyDp())
        val half = theme.dp(KeyLayout.STRIP_ZONE_W) / 2
        val icon = theme.dp(StripGeometry.ICON_OPEN)
        iconPaint.color = theme.withAlpha(theme.barInk, 0.75f)
        if (pressed == T_BACK) c.drawCircle(half, cy, theme.dp(18f), chipPaint)
        c.save(); c.scale(-1f, 1f, half, cy)          // mũi tên phải lật ngang = ←
        ImeIcons.draw(c, ImeIcons.ARROW_RIGHT, half, cy, icon, iconPaint)
        c.restore()
        val px = width - half
        if (pressed == T_PASTE_BTN) c.drawCircle(px, cy, theme.dp(18f), chipPaint)
        ImeIcons.draw(c, ImeIcons.CLIPBOARD, px, cy, theme.dp(StripGeometry.iconDp(1f, delta = 1f)), iconPaint)
    }

    /** 😊 (Thanh trên) rồi 📋 (bấm được) từ mép phải (sau ô nhân vật, ô ⌄). Không có chỉ báo ẩn danh (Phil 27/09 bỏ). */
    private fun drawExtras(c: Canvas, w: Float, cy: Float) {
        var x = w - dismissPx() - theme.dp(buddyDp)
        if (emojiButton) {
            val cx = x - theme.dp(StripGeometry.EMOJI_W) / 2
            if (pressed == T_EMOJI_BTN) c.drawCircle(cx, cy, theme.dp(18f), chipPaint)
            iconPaint.color = theme.withAlpha(theme.barInk, 0.75f)
            ImeIcons.draw(c, ImeIcons.FACE, cx, cy, theme.dp(StripGeometry.ICON_OPEN), iconPaint)
            x -= theme.dp(StripGeometry.EMOJI_W)
        }
        if (clipButton && tools()) {
            val cx = x - theme.dp(CLIP_W) / 2
            if (clipOpen) c.drawCircle(cx, cy, theme.dp(18f), chipPaint)
            iconPaint.color = theme.withAlpha(theme.barInk, if (clipOpen) 1f else 0.75f)
            ImeIcons.draw(c, ImeIcons.CLIPBOARD, cx, cy, theme.dp(StripGeometry.iconDp(1f, delta = 1f)), iconPaint)
            x -= theme.dp(CLIP_W)
        }
        if (voiceButton && tools()) {
            val cx = x - theme.dp(StripGeometry.MIC_W) / 2
            if (pressed == T_MIC) c.drawCircle(cx, cy, theme.dp(18f), chipPaint)
            iconPaint.color = theme.withAlpha(theme.barInk, 0.75f)
            ImeIcons.draw(c, ImeIcons.MIC, cx, cy, theme.dp(StripGeometry.ICON_OPEN), iconPaint)
        }
    }

    /** Pill giữa bar (cùng kiểu thẻ Dán) cho xem trước vuốt ⌫ / Khôi phục. */
    /** Chữ ô [i] giữa ô, cỡ đã co theo [slotScale] (cùng đường chân chữ với các ô khác). */
    private fun drawWord(c: Canvas, s: String, i: Int, y: Float, p: Paint) {
        val k = slotScale[i]
        val x = (slotL[i] + slotR[i]) / 2
        if (k >= 1f) { c.drawText(s, x, y, p); return }
        val full = p.textSize
        p.textSize = full * k
        c.drawText(s, x, y, p)
        p.textSize = full
    }

    private fun drawChip(c: Canvas, text: String, alpha: Int, trunc: TextUtils.TruncateAt) {
        val cy = theme.dp(barCyDp())
        val padH = theme.dp(14f); val h = theme.dp(StripGeometry.PILL_H)
        val maxW = maxOf(0f, width - 2 * sideW() - 2 * padH)
        val t = TextUtils.ellipsize(text, chipText, maxW, trunc).toString()
        val w = chipText.measureText(t) + 2 * padH
        val l = (width - w) / 2
        setChipOpacity(if (pressed == T_RESTORE || pressed == T_PILL) (alpha * 0.8f).toInt() else alpha)
        c.drawRoundRect(l, cy - h / 2, l + w, cy + h / 2, h / 2, h / 2, chipPaint)
        setChipOpacity(255)
        chipText.color = theme.chipInk; chipText.alpha = alpha
        c.drawText(t, width / 2f, cy + chipTextOff, chipText)
    }

    private fun drawPaste(c: Canvas, alpha: Int) {
        setChipOpacity(if (pressed == T_PASTE) (alpha * 0.8f).toInt() else alpha)
        val r = (pasteB - pasteT) / 2
        c.drawRoundRect(pasteL, pasteT, pasteR, pasteB, r, r, chipPaint)
        setChipOpacity(255)
        iconPaint.color = theme.withAlpha(theme.chipInk, alpha / 255f)
        ImeIcons.draw(c, ImeIcons.CLIPBOARD, pasteIconCx, pasteIconCy, theme.dp(18f), iconPaint)
        pasteTitle.color = theme.chipInk; pasteTitle.alpha = alpha
        c.drawText(pasteTitleText, pasteTextX, pasteTitleBase, pasteTitle)
        if (pasteShowSub) {
            pasteSub.color = theme.withAlpha(theme.chipInk, 0.7f * alpha / 255f)
            c.drawText(pasteSubText, pasteSubX, pasteSubBase, pasteSub)
        }
    }

    // MARK: touch

    @SuppressLint("ClickableViewAccessibility")
    override fun onTouchEvent(e: MotionEvent): Boolean {
        when (e.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                target = findTarget(e.x, e.y)
                downX = e.x; downY = e.y
                if (target == T_SLOT || target == T_EMOJI || target == T_PASTE || target == T_RESTORE || target == T_PILL || target == T_EDIT || target == T_EMOJI_BTN || target == T_DISMISS || target == T_MIC || target == T_BACK || target == T_PASTE_BTN) {
                    pressed = target; pressedIndex = targetIndex; invalidate()
                }
                // chốt từ đang HIỆN dưới ngón tay — gợi ý nền về trước lúc nhấc không được đổi nó
                tap.down(when (target) {
                    T_SLOT -> slotPayload[targetIndex]
                    T_EMOJI -> emojiText[targetIndex]
                    T_PILL -> actionPill?.payload
                    else -> null
                })
                longFired = false
                removeCallbacks(editLongRun)
                if (target == T_EDIT && oneHandAvailable) postDelayed(editLongRun, LONG_MS)
                emojiHoldOpen = false
                removeCallbacks(emojiLongRun)
                if (target == T_EMOJI_BTN) postDelayed(emojiLongRun, LONG_MS)
                return target != T_NONE
            }
            MotionEvent.ACTION_MOVE -> if (emojiHoldOpen) listener?.onEmojiButtonHoldMove(e.x, e.y)
            MotionEvent.ACTION_UP -> {
                removeCallbacks(editLongRun); removeCallbacks(emojiLongRun)
                if (emojiHoldOpen) { emojiHoldOpen = false; target = T_NONE; listener?.onEmojiButtonHoldEnd(false); return true }
                val t = if (longFired) T_NONE else target; target = T_NONE
                if (pressed != T_NONE) { pressed = T_NONE; invalidate() }
                if (abs(e.x - downX) > theme.dp(40f) || abs(e.y - downY) > theme.dp(40f)) return true
                fire(t)
            }
            MotionEvent.ACTION_CANCEL -> { removeCallbacks(editLongRun); removeCallbacks(emojiLongRun)
                if (emojiHoldOpen) { emojiHoldOpen = false; listener?.onEmojiButtonHoldEnd(true) }
                target = T_NONE; tap.cancel(); if (pressed != T_NONE) { pressed = T_NONE; invalidate() } }
        }
        return true
    }

    private fun findTarget(x: Float, y: Float): Int {
        val w = width.toFloat()
        val strip = stripPx()
        val dz = dismissPx()
        // ⌄ ẩn bàn phím: trước cả kiểm tra bar (dải trống ô mật khẩu vẫn bấm được); không lấn hàng phím.
        if (dz > 0f && y <= strip && x >= w - dz) return T_DISMISS
        if (emojiTools) {
            if (y > strip) return T_NONE
            return when (StripGeometry.emojiPlaneTool(x / theme.density, w / theme.density)) {
                StripGeometry.EMOJI_TOOL_BACK -> T_BACK
                StripGeometry.EMOJI_TOOL_PASTE -> T_PASTE_BTN
                else -> T_NONE
            }
        }
        if (!barVisible) return T_NONE
        if (y > strip) return T_NONE          // không lấn hàng Q–P
        val zone = theme.dp(KeyLayout.STRIP_ZONE_W)
        if (x < zone) return if (burgerShown()) T_BURGER else T_NONE
        val tools = tools()
        if (tools && x < zone + theme.dp(STRIP_TOOL_W)) return T_EDIT
        val bd = theme.dp(buddyDp)
        val r = w - dz                        // mép phải các nút (trái ô ⌄; tắt ⇒ = w)
        if (bd > 0f && com.viettelex.keyboard.BuddyTap.tickles(x.toDouble(), y.toDouble(),
                com.viettelex.keyboard.BuddyRect((r - bd).toDouble(), 0.0, bd.toDouble(), strip.toDouble()), strip.toDouble(), buddyFigure))
            return T_BUDDY
        val em = if (emojiButton) theme.dp(StripGeometry.EMOJI_W) else 0f
        if (emojiButton && x >= r - bd - em) return T_EMOJI_BTN
        val cw = if (clipButton && tools) theme.dp(CLIP_W) else 0f
        if (cw > 0f && x >= r - bd - em - cw) return T_CLIP
        if (voiceButton && tools && x >= r - bd - em - cw - theme.dp(StripGeometry.MIC_W)) return T_MIC
        if (x >= w - extraW()) return T_NONE
        if (swipePreview != null || statusText != null) return T_NONE
        if (restoreOffer) return T_RESTORE
        if (actionPill != null) return T_PILL
        if (paste) return T_PASTE
        for (i in 0 until emojiCount) if (x >= emojiL[i] && x < emojiR[i]) { targetIndex = i; return T_EMOJI }
        val n = if (chipCount > 0) chipCount else slotCount
        for (i in 0 until n) if (slotText[i] != null && x >= slotL[i] && x < slotR[i]) { targetIndex = i; return T_SLOT }
        return T_NONE
    }

    private fun fire(t: Int) {
        when (t) {
            T_BURGER -> { feedback.click(Feedback.MODIFIER, this); listener?.onToggleTemplates() }
            T_EDIT -> { feedback.click(Feedback.MODIFIER, this); listener?.onToggleEditPanel() }
            T_CLIP -> { feedback.click(Feedback.MODIFIER, this); listener?.onToggleClipboard() }
            T_MIC -> { feedback.click(Feedback.MODIFIER, this); listener?.onVoiceInput() }
            T_EMOJI_BTN -> { feedback.click(Feedback.MODIFIER, this); listener?.onEmojiButton() }
            T_BUDDY -> { feedback.buddyClick(); listener?.onBuddyTickle() }
            T_DISMISS -> { feedback.click(Feedback.MODIFIER, this); listener?.onDismissKeyboard() }
            T_BACK -> { feedback.click(Feedback.MODIFIER, this); listener?.onBackToLetters() }
            T_PASTE_BTN -> { feedback.click(Feedback.MODIFIER, this); listener?.onSuggestion(SuggestionSet.PASTE_TOKEN) }
            T_PASTE -> { feedback.click(Feedback.MODIFIER, this); listener?.onSuggestion(SuggestionSet.PASTE_TOKEN) }
            T_RESTORE -> { feedback.click(Feedback.MODIFIER, this); listener?.onRestoreDeleted() }
            T_PILL -> tap.up()?.let { feedback.click(Feedback.MODIFIER, this); listener?.onSuggestion(it) }
            T_SLOT, T_EMOJI -> tap.up()?.let { feedback.click(Feedback.MODIFIER, this); listener?.onSuggestion(it) }
        }
    }

    private val tap = SlotTapLatch()
    private var longFired = false
    private val editLongRun = Runnable {
        longFired = true
        pressed = T_NONE; invalidate()
        feedback.longPress(this)
        listener?.onToggleOneHand()
    }

    /** Menu giữ 😊 strip đang mở (nhận move / nhấc). */
    private var emojiHoldOpen = false
    private val emojiLongRun = Runnable {
        if (target != T_EMOJI_BTN) return@Runnable
        longFired = true
        pressed = T_NONE; invalidate()
        val cx = emojiButtonCx()
        emojiHoldOpen = listener?.onEmojiButtonHold(cx, 0f, stripPx(), downX, downY) == true
    }

    /** Tâm ngang nút 😊 (px) — cùng công thức [drawExtras]. */
    private fun emojiButtonCx(): Float = width - dismissPx() - theme.dp(buddyDp) - theme.dp(StripGeometry.EMOJI_W) / 2

    fun onHidden() {
        removeCallbacks(editLongRun); removeCallbacks(emojiLongRun)
        if (emojiHoldOpen) { emojiHoldOpen = false; listener?.onEmojiButtonHoldEnd(true) }
        target = T_NONE; pressed = T_NONE; tap.cancel()
    }

    companion object {
        private const val T_NONE = 0
        private const val T_BURGER = 1
        private const val T_PASTE = 3
        private const val T_SLOT = 4
        private const val T_EMOJI = 5
        private const val T_RESTORE = 6
        private const val T_EDIT = 7
        private const val T_CLIP = 8
        private const val T_PILL = 9
        private const val T_EMOJI_BTN = 10
        private const val T_BUDDY = 11
        private const val T_DISMISS = 12
        private const val T_MIC = 13
        private const val T_BACK = 14
        private const val T_PASTE_BTN = 15
        /** Bề ngang ô icon con trỏ (sau ô mẫu câu), dp. */
        const val STRIP_TOOL_W = StripGeometry.TOOL_W
        private const val LONG_MS = 450L
        private const val CLIP_W = StripGeometry.CLIP_W
    }
}
