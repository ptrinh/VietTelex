package com.viettelex.keyboard

/**
 * Giữ phím ở bàn SỐ / KÝ HIỆU ra hàng biến thể như stock iOS: giữ `"` ⇒ " ” “ „ » «, giữ `$`
 * ⇒ $ ₫ € … Bản THUẦN song sinh iOS/Keyboard/KeyVariants.swift. View dùng chung popup trượt-chọn
 * của [DomainPopup].
 *
 * Từ #165 bàn 123 / #+= Android có ĐÚNG bộ phím của iOS (KeyLayout NUM2 / SYM1 / SYM2 / THIRD), nên
 * hai bảng phải trùng hoàn toàn — sửa biến thể bên này thì sửa y hệt bên kia. Lệch có chủ đích
 * (nếu sau này có) phải khai ở [ANDROID_ONLY] / [IOS_ONLY] (pinned bởi
 * KeyVariantsTests.matchesSwiftTable) — hiện rỗng.
 *
 * Thứ tự = từ phím ra ngoài: ô 0 là ký tự GỐC (mặc định được chọn khi popup mở, như stock) —
 * trừ [HOLD_PRESELECT]: ô 0 là ký tự hay muốn khi đã GIỮ phím, gốc đứng ô 1 (như giữ "," chọn
 * sẵn "." — [CommaPopup]). Chạm vẫn ra ký tự gốc.
 *
 * Bàn CHỮ không có biến thể: giữ phím chữ đã là ký tự phụ số/ký hiệu ([KeyAlternates] —
 * q…p → 1…0, a → @…) và "," → "."; dấu tiếng Việt gõ bằng Telex/VNI.
 */
object KeyVariants {
    /** Bảng biến thể Android (khoá = ký tự gốc trên phím). */
    val table: Map<String, List<String>> = linkedMapOf(
        // bàn 123
        "1" to listOf("1", "¹", "½", "⅓", "¼", "⅛"),
        "2" to listOf("2", "²", "⅔"),
        "3" to listOf("3", "³", "¾", "⅜"),
        "4" to listOf("4", "⁴"),
        "5" to listOf("5", "⅝"),
        "7" to listOf("7", "⅞"),
        "0" to listOf("0", "°"),
        "-" to listOf("-", "–", "—", "•"),
        // "=" ngay cạnh "/" — bàn 123 (tắt hàng số) không có phím "=" (song sinh iOS, field report 18/10/2026).
        "/" to listOf("/", "=", "\\"),
        // "$" là phím gốc như iOS (#165: người dùng không tìm ra "$" khi nó nằm dưới "₫");
        // giữ ⇒ ₫ ngay ô kế, rồi các tiền tệ khác — y hệt bảng Swift.
        "\$" to listOf("\$", "₫", "€", "£", "¥", "₩", "₹", "₽", "¢"),
        "&" to listOf("&", "§"),
        "." to listOf(".", "…"),
        "?" to listOf("?", "¿"),
        "!" to listOf("!", "¡"),
        "'" to listOf("'", "‘", "’", "`"),
        "\"" to listOf("\"", "”", "“", "„", "»", "«"),
        // bàn #+=
        "%" to listOf("%", "‰"),
        "=" to listOf("=", "≠", "≈"),
        "+" to listOf("+", "±"),
        "<" to listOf("<", "≤", "‹", "«"),
        ">" to listOf(">", "≥", "›", "»"),
        "*" to listOf("*", "×"),
        "~" to listOf("~", "≈"),
        "€" to listOf("€", "\$", "£", "¥", "₫"),
        "•" to listOf("•", "·", "°"),
    )

    /** Khoá chỉ Android có (không có trong bảng Swift). */
    val ANDROID_ONLY: Set<String> = emptySet()
    /** Khoá có ô 0 ≠ ký tự gốc (gốc ở ô 1): giữ rồi nhả tại chỗ ra ô 0, chạm vẫn ra gốc. */
    val HOLD_PRESELECT: Set<String> = emptySet()
    /** Khoá chỉ iOS có (bảng Swift) — phím đó không còn trên bàn số / ký hiệu Android. */
    val IOS_ONLY: Set<String> = emptySet()

    /** Hàng biến thể của phím [key] ở bàn số/ký hiệu; rỗng = không có. Bàn chữ / ô số luôn rỗng. */
    fun variants(key: String, symbolPlane: Boolean, numericField: Boolean = false): List<String> {
        if (!symbolPlane || numericField) return emptyList()
        return table[key] ?: emptyList()
    }
}
