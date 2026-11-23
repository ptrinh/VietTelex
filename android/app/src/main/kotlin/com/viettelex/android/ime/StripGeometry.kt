package com.viettelex.android.ime

import com.viettelex.keyboard.BarLayout

/**
 * Hình học slot thanh gợi ý — THUẦN. 3 slot BẰNG NHAU, cố định theo bề rộng bar (không
 * theo nội dung) ⇒ không "lúc rộng lúc hẹp" như lỗi iOS 27/09/2026. Thẻ Dán thay CẢ bar
 * (StripView không vẽ slot khi thẻ hiện). Pinned by StripGeometryTest.
 */
object StripGeometry {
    /** Chiều cao pill (thẻ Dán, chip số, Khôi phục) và ô nhấn slot, dp. */
    const val PILL_H = 32f
    /** Bề ngang ô icon con trỏ (sau ô mẫu câu) / ô 📋 (mép phải), dp. */
    const val TOOL_W = 44f
    const val CLIP_W = 40f
    /** Ô 🎤 gõ giọng nói (trái ô 📋), dp. */
    const val MIC_W = 40f

    /**
     * #175: bề ngang cụm công cụ mép phải (dp) = 📋 (lịch sử clipboard bật) + 🎤 (máy có bộ nhận giọng nói, không
     * phải ô mật khẩu). Cả cụm ẩn/hiện cùng [toolsShown] — truyền vào `clipW` của [rightExtraW] / [barRight] với
     * `clipButton = clip || voice`.
     */
    fun rightToolsW(clip: Boolean, voice: Boolean): Float = (if (clip) CLIP_W else 0f) + (if (voice) MIC_W else 0f)
    /** Ô nút 😊 sát mép phải / ô nhân vật ("Nút emoji" = Thanh trên), dp. */
    const val EMOJI_W = 40f
    /** Icon thanh công cụ (☰ mẫu câu, con trỏ, 😊, 📋), dp. */
    const val ICON_OPEN = 22f
    /** Icon khi thu gọn (hàng nổi 14 dp). */
    const val ICON_COLLAPSED = 14f
    /** Cỡ chữ gợi ý (sp) — Gboard ~16–17; giữa đậm vừa. */
    const val WORD_SP = 17f

    /** Cỡ icon nội suy theo độ mở [o] (0 thu gọn … 1 mở); [delta] = bớt so với [ICON_OPEN]. */
    fun iconDp(o: Float, delta: Float = 0f): Float =
        ICON_COLLAPSED + (ICON_OPEN - delta - ICON_COLLAPSED) * o.coerceIn(0f, 1f)

    /**
     * #113 kiểu Gboard: đang có nội dung gợi ý (chữ, emoji, chip số/email, thẻ Dán, pill hoàn
     * tác) ⇒ ẩn icon con trỏ + 📋 để 3 slot rộng hơn; ☰ giữ nguyên. Bảng sửa / lịch sử
     * clipboard đang mở ⇒ vẫn hiện icon tương ứng để đóng được. Chỉ đổi khi nội dung rỗng↔có.
     */
    fun toolsShown(hasContent: Boolean, editOpen: Boolean, clipOpen: Boolean): Boolean =
        !hasContent || editOpen || clipOpen

    /**
     * Bar có nội dung đẩy icon đi: chữ/emoji, chip số/email/Dán, thẻ Dán, pill hoàn tác.
     * [idle] (ô trống, chưa có từ trước — SuggestionSet.idle): chữ đệm phổ biến KHÔNG tính.
     */
    fun hasContent(l: BarLayout, idle: Boolean = false): Boolean = when (l) {
        is BarLayout.Slots -> !idle && (l.emojis.isNotEmpty() || l.slots.any { it != null })
        is BarLayout.Chips -> l.chips.isNotEmpty()
        is BarLayout.Pill, BarLayout.PasteCard -> true
    }

    /** Mép trái vùng slot (dp): zone ☰ + ô icon con trỏ khi [toolsShown]. */
    fun barLeft(zoneW: Float, toolW: Float, toolsShown: Boolean): Float =
        zoneW + if (toolsShown) toolW else 0f

    /**
     * Bề ngang các nút giữa slot và mép phải (dp): nhân vật + 😊 ([emojiButton], LUÔN — cả khi có gợi ý, để emoji
     * không mất lối vào) + 📋 (chỉ khi có nút và [toolsShown]).
     */
    fun rightExtraW(clipW: Float, clipButton: Boolean, toolsShown: Boolean, emojiButton: Boolean = false, buddy: Float = 0f,
                    dismiss: Float = 0f): Float =
        dismiss + buddy + (if (emojiButton) EMOJI_W else 0f) + (if (clipButton && toolsShown) clipW else 0f)

    /**
     * "Nút ẩn bàn phím" (Keys.KEYBOARD_DISMISS_BUTTON, mặc định TẮT): ⌄ sát MÉP PHẢI dải gợi ý, chạm = ẩn bàn phím
     * (requestHideSelf). Hiện khi: công tắc bật + dải đang giữ chỗ ([reserved] — kể cả ô mật khẩu/OTP, dải trống) +
     * không ở bàn emoji (lưới / ô tìm chiếm dải). Tắt "Thanh gợi ý" ⇒ dải cao 0 ⇒ KHÔNG có ⌄ (không thêm chiều cao chỉ
     * để chứa nó; tablet vẫn còn phím ẩn ở hàng đáy). = iOS KeyboardDismissButton.shown.
     */
    fun dismissShown(enabled: Boolean, reserved: Boolean, emojiPlane: Boolean): Boolean =
        enabled && reserved && !emojiPlane

    /** Bề ngang ô ⌄ (dp): = ô ☰ trái (như nút thu gọn cũ); 0 khi không hiện ⇒ mọi khung y như chưa có nút. */
    fun dismissW(shown: Boolean): Float = if (shown) KeyLayout.STRIP_ZONE_W else 0f

    /** Ô "Bạn đồng hành" (dp) sát MÉP PHẢI — 😊 / 📋 dời sang trái đúng bấy nhiêu. = iOS KeyboardView.buddyZoneWidth. */
    const val BUDDY_W = 34f

    /** Mép trái ô nhân vật (dp) khi bar mở: ô sát mép phải, hoặc sát trái ô ⌄ ẩn bàn phím ([dismiss] = [dismissW]). */
    fun buddyLeft(width: Float, dismiss: Float = 0f): Float = width - dismiss - BUDDY_W

    /** Phần nhân vật tràn xuống hàng phím đầu (theo tỉ lệ strip) — = iOS KeyboardView.buddyOverlapRatio. Chỉ là
     *  hình (BuddyView không nhận chạm) nên phím bên dưới vẫn bấm bình thường. */
    const val BUDDY_OVERLAP = 0.65f

    /** Chiều cao ô nhân vật (px) cho strip cao [strip] px: strip + phần tràn. */
    fun buddyHeight(strip: Int): Int = Math.round(strip * (1 + BUDDY_OVERLAP))

    /** Bề ngang khung VẼ nhân vật (px): vuông theo [buddyHeight] (dáng ngủ nằm ngang không bị cắt), tối thiểu ô
     *  chừa [zone]; canh giữa ô chừa nhưng kẹp trong mép phải, được đè lên 📋 / phím (lớp trên cùng). = iOS KeyboardView.buddyFrame. */
    fun buddyDrawWidth(strip: Int, zone: Int): Int = maxOf(zone, buddyHeight(strip))

    /** Mép phải vùng slot (dp): từ mép phải trừ ô ⌄ ([dismiss]), nhân vật, 😊 ([emojiButton]) và 📋 (chỉ khi có nút và [toolsShown]). */
    fun barRight(width: Float, clipW: Float, clipButton: Boolean, toolsShown: Boolean,
                 emojiButton: Boolean = false, buddy: Float = 0f, dismiss: Float = 0f): Float =
        width - rightExtraW(clipW, clipButton, toolsShown, emojiButton, buddy, dismiss)

    /** Mép trái/phải slot i (0..2) trong [barL, barR] → ghi vào [l]/[r]. */
    fun thirds(barL: Float, barR: Float, l: FloatArray, r: FloatArray) = cells(barL, barR, 3, l, r)

    /**
     * [n] ô bằng nhau ("Số từ gợi ý" — SuggestionCount.fit) trong [barL, barR] → mép trái/phải ô
     * i (0 until n) ghi vào [l]/[r]; ô cuối chạm đúng [barR].
     */
    fun cells(barL: Float, barR: Float, n: Int, l: FloatArray, r: FloatArray) {
        val w = (barR - barL) / n
        for (i in 0 until n) { l[i] = barL + i * w; r[i] = if (i == n - 1) barR else l[i] + w }
    }
}
