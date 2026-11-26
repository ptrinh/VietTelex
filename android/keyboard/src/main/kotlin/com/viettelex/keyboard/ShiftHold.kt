package com.viettelex.keyboard

import com.viettelex.keyboard.SuggestionCase.Shift

/**
 * Phím ⇧ bàn phím cảm ứng: chạm (viết hoa một lần), chạm đôi (Caps Lock), và GIỮ làm phím
 * bổ trợ — "Giữ Shift để gõ số và ký hiệu" (mặc định BẬT): ngón đè ⇧ + chạm phím chữ ⇒ ký tự
 * phụ của phím (số nhỏ q…p, ký hiệu a…m — cùng ký tự giữ lâu / vuốt xuống cho) thay vì chữ hoa.
 *
 * - Chạm ⇧ nhanh: một-lần như cũ; chạm đôi < [DOUBLE_TAP_MS]: Caps Lock.
 * - Đã giữ ⇧ gõ ký tự phụ: nhả KHÔNG để lại viết hoa một-lần (Caps Lock trước đó giữ nguyên),
 *   và lần chạm ⇧ kế tiếp không tính là chạm đôi. Chạm đôi rồi giữ: vẫn Caps Lock.
 * - Giữ ⇧ + kéo phím cách chọn chữ ([markSelect]): nhả trả shift như trước khi chạm (như cũ).
 * - Phím không có ký tự phụ / tắt cài đặt (bảng rỗng): [symbol] trả null ⇒ chữ như cũ.
 *
 * Đường phím chữ chỉ thêm một phép kiểm tra boolean ([held]) — bảng rỗng khi tắt.
 * Ký tự phụ gửi vào phiên như số numpad ([key]): LUÔN là ký tự nguyên văn/ranh giới, kể cả
 * VNI (người dùng giữ ⇧ là muốn SỐ, không muốn bỏ dấu).
 *
 * THUẦN — pinned by ShiftHoldTests. Bản iOS: iOS/Keyboard/ShiftHold.swift (cùng chuyển trạng thái).
 */
class ShiftHold(private val doubleTapMs: Long = DOUBLE_TAP_MS) {
    /** Có ngón đang đè ⇧. */
    var held = false
        private set
    private var before = Shift.OFF
    private var pressed = Shift.OFF
    private var lastTap = NEVER
    private var downAt = NEVER
    private var selectUsed = false
    private var symbolsUsed = false

    /** Ngón chạm ⇧ lúc [now] (ms) khi shift đang là [cur]: trả shift mới. */
    fun down(cur: Shift, now: Long): Shift {
        before = cur
        held = true; selectUsed = false; symbolsUsed = false
        // Chạm đôi ⇒ Caps Lock; lần chạm NGAY sau đó là chạm mới (tắt Caps), không phải chạm đôi
        // nữa — chạm ba nhanh trước đây vẫn kẹt ở Caps. Giống iOS.
        val double = lastTap != NEVER && now - lastTap < doubleTapMs
        val next = if (double) Shift.CAPS_LOCK else if (cur == Shift.OFF) Shift.ONCE else Shift.OFF
        lastTap = if (double) NEVER else now
        downAt = now
        pressed = next
        return next
    }

    /**
     * Phím chữ [label] (chữ thường) vừa chạm lúc [now] (ms): ký tự phụ phải gõ thay chữ, hoặc
     * null (chữ như cũ). [map] = [KeyAlternates.shiftMap] (rỗng khi tắt cài đặt).
     * Gõ chồng ngón (⇧ chưa kịp nhả mà phím chữ đã chạm, < [ROLLOVER_MS] sau khi chạm ⇧) vẫn là
     * chữ hoa — gõ nhanh "⇧ rồi chữ" không biến thành số.
     */
    fun symbol(label: Char, map: Map<Char, String>, now: Long): String? {
        if (!held || now - downAt < ROLLOVER_MS) return null
        val s = map[label] ?: return null
        symbolsUsed = true
        return s
    }

    /** ⇧ đang giữ vừa làm phím bổ trợ chọn chữ (giữ ⇧ + kéo phím cách). */
    fun markSelect() { if (held) selectUsed = true }

    /** Nhấc ngón khỏi ⇧ khi shift đang là [cur]: trả shift mới. */
    fun up(cur: Shift): Shift {
        if (!held) return cur
        held = false
        val out = when {
            symbolsUsed -> if (before == Shift.CAPS_LOCK || pressed == Shift.CAPS_LOCK) Shift.CAPS_LOCK else Shift.OFF
            selectUsed -> before
            else -> return cur
        }
        selectUsed = false; symbolsUsed = false
        lastTap = NEVER
        return out
    }

    /** Huỷ mọi chạm (bàn phím ẩn, đổi bố cục): bỏ trạng thái giữ, shift để nguyên. */
    fun cancel() { held = false; selectUsed = false; symbolsUsed = false }

    companion object {
        const val DOUBLE_TAP_MS = 300L
        /** Phím chữ chạm sớm hơn ngần này sau khi chạm ⇧ ⇒ gõ chồng ngón (chữ hoa), chưa phải giữ. */
        const val ROLLOVER_MS = 150L
        private const val NEVER = Long.MIN_VALUE

        /** Phím gửi vào [KeyboardSession] cho ký tự phụ khi giữ ⇧: nguyên văn (VNI không bỏ dấu). */
        fun key(symbol: String): Key = Key.Text(symbol, numpad = true)
    }
}
