package com.viettelex.keyboard

/**
 * "Về bàn chữ sau ký hiệu" (setting [Keys.SYMBOL_RETURN]; cùng chuỗi với iOS App Group
 * "symbolReturn"; 06/11/2026). Chạm một ký tự ở plane 123 / #+= rồi:
 *  - [AUTO] ("Tự động"): , ? ! ) " ' : ; & $ @ (… ” ’ ») về chữ ngay; "." và ký hiệu khác ở lại
 *    (gõ "..." liền tay — 15/11/2026).
 *  - [ALWAYS] ("Luôn"): MỌI ký hiệu về chữ ngay; chữ số ở lại.
 *  - [OFF] (mặc định từ 10/11/2026, "Tắt"): không về sau ký hiệu — chỉ dấu cách đưa về chữ.
 *    (Người dùng tưởng "chọn một ký tự là bị về ABC" là lỗi — email 10/11/2026.)
 * Ngay sau chữ số thì . , : ở lại (2.5, 1,000, 10:30); ô số không bao giờ về. Dấu cách đưa về
 * chữ ở cả ba chế độ (PlanePolicy.returnToLettersOnSpace). Đọc lúc hiện — 0 chi phí mỗi phím.
 */
enum class SymbolReturn(val id: String) {
    AUTO("auto"), ALWAYS("always"), OFF("off");

    companion object {
        val DEFAULT = OFF
        val IDS: Set<String> = entries.map { it.id }.toSet()
        /** Giá trị lạ / thiếu ⇒ [DEFAULT]. */
        fun of(raw: Any?): SymbolReturn = entries.firstOrNull { it.id == raw } ?: DEFAULT
    }
}
