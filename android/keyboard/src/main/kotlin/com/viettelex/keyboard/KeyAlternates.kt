package com.viettelex.keyboard

import kotlin.math.hypot

/**
 * Giữ phím chữ để ra ký tự phụ (issue #98, kiểu Gboard): hàng trên q…p → 1…0, hàng 2–3 →
 * ký hiệu. Phần THUẦN, bản Swift song sinh iOS/Keyboard/KeyAlternates.swift — sửa ở đây thì
 * sửa y hệt bên kia (bảng khớp fixture chung iOS/KeyboardTests/Fixtures/key-alternates.txt).
 *
 * Bảng ký hiệu gốc Gboard tiếng Anh (a@ s# … m?), đổi 3 phím cho tiếng Việt: d → $, c → %,
 * b → / (tiếng Việt ít dùng ' và ;, hay dùng % và / — ngày tháng, link; ₫ nằm ở giữ "$" trên bàn 123).
 * Không trùng ký tự nào giữa các phím.
 *
 * Giữ phím "," hàng đáy (bàn chữ) ra "." như Gboard — bật khi có ÍT NHẤT một công tắc giữ phím
 * đang có hiệu lực (số khi hàng số tắt, hoặc ký hiệu), tức [map] không rỗng. "." chốt từ đang
 * gõ y như ",". Riêng Android: "," đã có giữ lâu = gõ giọng nói (khi có IME giọng nói) ⇒ giữ
 * nguyên hành động đó, không ra "." ([commaHold]).
 */
object KeyAlternates {
    val digits: Map<Char, String> = "qwertyuiop".toList().zip("1234567890".map { it.toString() }).toMap()
    val symbols: Map<Char, String> = linkedMapOf(
        'a' to "@", 's' to "#", 'd' to "\$", 'f' to "_", 'g' to "&", 'h' to "-", 'j' to "+", 'k' to "(", 'l' to ")",
        'z' to "*", 'x' to "\"", 'c' to "%", 'v' to ":", 'b' to "/", 'n' to "!", 'm' to "?",
    )

    /** Giữ bao lâu thì thành ký tự phụ — ngắn hơn giữ ⌫/😊 (450–500 ms), dài hơn trackpad (300 ms). */
    const val HOLD_MS = 380L
    /** Ngón trôi quá ngần này (dp) trước khi đủ giờ ⇒ không phải giữ (vuốt / trượt). */
    const val SLOP_DP = 10f

    /**
     * Bảng đang dùng. Hàng số bật ⇒ bỏ số (đã có phím riêng). TalkBack/touch exploration:
     * giữ phím là cử chỉ của trình đọc ⇒ tắt hết. Rỗng ⇒ không hẹn giờ, không vẽ nhãn.
     */
    fun map(numbers: Boolean, symbols: Boolean, numberRow: Boolean, accessibility: Boolean = false): Map<Char, String> {
        if (accessibility) return emptyMap()
        val m = LinkedHashMap<Char, String>()
        if (numbers && !numberRow) m.putAll(digits)
        if (symbols) m.putAll(this.symbols)
        return m
    }

    /**
     * Bảng cho "Giữ Shift để gõ số và ký hiệu" ([ShiftHold]): cùng ký tự với [map], nhưng số
     * q…p vẫn có khi hàng số bật (nhất quán — giữ ⇧ + q luôn ra 1). Tắt / TalkBack ⇒ rỗng.
     */
    fun shiftMap(enabled: Boolean, numbers: Boolean, symbols: Boolean, numberRow: Boolean, accessibility: Boolean = false): Map<Char, String> =
        if (!enabled) emptyMap()
        else map(numbers || numberRow, symbols, numberRow = false, accessibility = accessibility)

    /** Ký tự phụ của phím "," hàng đáy. */
    const val COMMA_ALT = "."

    /** Giữ "," ra "." khi bảng ký tự phụ không rỗng — trừ khi "," đang là phím giọng nói. */
    fun commaHold(alternates: Map<Char, String>, voiceAvailable: Boolean) = alternates.isNotEmpty() && !voiceAvailable

    /**
     * Giữ "," đủ giờ: đổi phím đang chờ chốt thành "." — vẫn chốt lúc nhấc / khi ngón khác chạm
     * (cùng đường với ","). false nếu "," đã chốt rồi (ngón khác chạm trước khi đủ giờ).
     */
    fun holdComma(commits: KeyCommitQueue, key: Any, fire: (String) -> () -> Unit): Boolean {
        if (!commits.isArmed(key)) return false
        commits.disarm(key)
        commits.arm(key, fire(COMMA_ALT))
        return true
    }

    /** Công tắc số chỉ có nghĩa (và chỉ hiện trong app) khi hàng phím số TẮT. */
    fun numbersSettingVisible(numberRow: Boolean) = !numberRow

    /**
     * Theo dõi MỘT ngón đang giữ phím có ký tự phụ (toạ độ dp). Không đồng hồ bên trong: view
     * hẹn giờ [HOLD_MS] rồi gọi [fire]; mọi huỷ (trôi, ngón khác, thành vuốt) đi qua đây.
     */
    class Hold(val alt: String, private val x0: Float, private val y0: Float) {
        var fired = false; private set
        var cancelled = false; private set

        /** Ngón di chuyển; true nếu vừa huỷ vì trôi quá slop (trước khi bắn). */
        fun move(x: Float, y: Float): Boolean {
            if (fired || cancelled) return false
            if (hypot(x - x0, y - y0) > SLOP_DP) { cancelled = true; return true }
            return false
        }
        fun cancel() { if (!fired) cancelled = true }
        /** Hết giờ: true nếu thành ký tự phụ (chưa huỷ). */
        fun fire(): Boolean {
            if (fired || cancelled) return false
            fired = true
            return true
        }
        /** Nhấc tay: ký tự phụ phải chèn (thay chữ đã chèn lúc chạm), null = chạm thường. */
        val commit: String? get() = if (fired) alt else null
    }
}
