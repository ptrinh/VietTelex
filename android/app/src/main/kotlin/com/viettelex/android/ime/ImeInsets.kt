package com.viettelex.android.ime

/**
 * Đệm dưới hàng phím đáy cho nút hệ thống của IME (⌄ ẩn bàn phím / 🌐 đổi bàn phím)
 * và nav bar 3 nút — CHỈ Android 15+ (trước đó hệ thống tự chừa). Android 15+ vẽ IME edge-to-edge: các nút đó đè LÊN hàng phím đáy
 * nếu không chừa dải như Gboard. THUẦN — pinned by ImeInsetsTest.
 */
object ImeInsets {
    /**
     * @param navBottom      WindowInsets navigationBars().bottom (px)
     * @param tappableBottom WindowInsets tappableElement().bottom (px)
     * @param captionBottom  WindowInsets captionBar().bottom (px) — API 35+ (điều hướng cử chỉ)
     *                       báo dải nút ⌄/🌐 của IME qua captionBar, có thể cao hơn navigationBars
     *                       (API 36: nav 63, caption 126). Lấy max, không cộng dồn.
     * @param fallbackNavBar chiều cao nav bar IME của hệ thống (px, từ dimen android) —
     *                       chỉ dùng khi API ≥ 35 mà insets không tới view (bị ancestor nuốt).
     * @param insetsKnown    đã nhận được WindowInsets thật hay chưa
     */
    fun bottomPad(sdk: Int, navBottom: Int, tappableBottom: Int, fallbackNavBar: Int, insetsKnown: Boolean,
                  captionBottom: Int = 0): Int {
        // API < 35: hệ thống tự đặt cửa sổ IME TRÊN nav bar ⇒ KHÔNG đệm, kể cả khi insets gốc của cửa sổ vẫn báo
        // nav bar (#176, Android 13: rootWindowInsets báo đủ chiều cao nav trong khi khung IMS đã chừa sẵn ⇒ đệm
        // đôi, bàn phím hở một dải đúng bằng nav bar).
        if (sdk < 35) return 0
        val reported = maxOf(maxOf(navBottom, tappableBottom), captionBottom, 0)
        if (reported > 0) return reported
        return if (insetsKnown) 0 else maxOf(fallbackNavBar, 0)
    }

    /** "Nâng bàn phím" dp (kẹp 0…KEYBOARD_RAISE_MAX) → px làm tròn; cộng vào [bottomPad]. */
    fun raisePx(raiseDp: Int, density: Float): Int =
        Math.round(com.viettelex.keyboard.KeyboardSettings.clampRaise(raiseDp) * density)

    /** Tổng chiều cao input view. */
    fun totalHeight(strip: Int, keyArea: Int, bottomPad: Int) = strip + keyArea + bottomPad
}
