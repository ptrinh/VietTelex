package com.viettelex.keyboard

/**
 * Hàm thuần cho SỬA LẠI từ đã gõ xong (port ý tưởng macOS `tryReopenLastCommit` /
 * `tryReEditWord`). Mọi nghi ngờ ⇒ không làm: sửa sai chữ user không yêu cầu tệ hơn
 * nhiều so với gõ literal.
 */
object ReEdit {
    /** Từ dài hơn một âm tiết thì engine cũng từ chối seed — đọc thêm vô ích. */
    const val MAX_WORD = 12

    /**
     * Phím được phép NẠP LẠI từ trước con trỏ: chỉ dấu thanh s f r x j z và móc w. KHÔNG
     * a/e/o/d (mũ/đ bằng phím lặp): con trỏ sau "to" gõ o thường là muốn "too", không phải
     * "tô" (user quyết 26/09/2026).
     */
    fun isTransformKey(ch: Char, vni: Boolean = false): Boolean =
        if (vni) when (ch) {
            // VNI ≙ Telex: 1–5 thanh, 0 huỷ thanh, 7/8 móc/trăng (≙ w). KHÔNG 6/9 (≙ a e o d).
            '1', '2', '3', '4', '5', '0', '7', '8' -> true
            else -> false
        } else when (ch.lowercaseChar()) {
            's', 'f', 'r', 'x', 'j', 'z', 'w' -> true
            else -> false
        }

    /**
     * Phím `d` (Telex) khi con trỏ DÍNH LIỀN sau một từ bắt đầu bằng d: gạch đ cho từ đó
     * ("dùng|" + d → "đùng", issue #169). Không ai mở từ mới dính vào từ trước nên, khác
     * a/e/o, phím này gần như chắc chắn là sửa; sau dấu cách `d` vẫn mở từ mới ("dùng đi").
     */
    fun isStrokeKey(ch: Char, word: String, vni: Boolean = false): Boolean =
        !vni && (ch == 'd' || ch == 'D') && word.length >= 2 && (word[0] == 'd' || word[0] == 'D')

    /**
     * Từ (toàn chữ cái) ngay trước con trỏ trong [before]; null nếu không có, dài quá
     * [MAX_WORD], hoặc dính vào thứ không phải từ tiếng Việt đứng riêng (chữ số, `@ . _ - /`…:
     * "mp3", "gmail.com", "a_b").
     */
    fun trailingWord(before: String): String? {
        var start = before.length
        var n = 0
        while (start > 0) {
            val cp = before.codePointBefore(start)
            if (!Character.isLetter(cp)) break
            start -= Character.charCount(cp)
            if (++n > MAX_WORD) return null
        }
        if (n == 0) return null
        if (start > 0) {
            val prev = before.codePointBefore(start)
            if (Character.isLetterOrDigit(prev) || prev in GLUE) return null
        }
        return before.substring(start)
    }

    /** Ký tự ngay sau con trỏ không phải chữ/số (hoặc cuối ô) — tức con trỏ ở CUỐI từ. */
    fun atWordEnd(after: String): Boolean =
        after.isEmpty() || !Character.isLetterOrDigit(after.codePointAt(0))

    /**
     * [before] (chữ trước con trỏ, TRƯỚC khi ⌫ xoá) kết thúc bằng đúng [word] + MỘT ký tự
     * ranh giới (không phải chữ/số) — thứ ⌫ sắp xoá.
     */
    fun endsWithWordThenBoundary(before: String, word: String): Boolean {
        if (word.isEmpty() || before.isEmpty()) return false
        val last = before.codePointBefore(before.length)
        if (Character.isLetterOrDigit(last)) return false
        val head = before.substring(0, before.length - Character.charCount(last))
        return head.endsWith(word)
    }

    private val GLUE = "@._-/\\#&=+%~:".map { it.code }.toSet()
}
