package com.viettelex.android.ime

/**
 * Trượt từ phím 123 (#171), như bàn phím iOS gốc — cùng hành vi bản iOS (PlaneSlide.swift).
 *
 * Chạm phím "123" ở plane chữ: plane số hiện NGAY lúc chạm. Ngón còn đè mà trượt sang một phím
 * ký tự (CHAR) của plane số rồi nhấc ⇒ chèn ký tự đó (đúng đường chạm thường của phím) và tự về
 * plane chữ. Nhấc ở chỗ không chèn được (khe, phím ABC chỗ 123 cũ, #+=, ⇧, ⌫, ↵, space, ngoài
 * vùng phím), touch bị huỷ, hoặc ngón thứ hai chạm ⇒ không chèn gì, ở lại plane số.
 *
 * Phần quyết định THUẦN — pinned by PlaneSlideTest. [K] = phím chèn được dưới ngón (null = không có).
 */
class PlaneSlide<K> {
    /** Phím chèn được đang dưới ngón (đang sẫm + balloon xem trước). */
    var over: K? = null
        private set

    /** Đổi phím dưới ngón: (rời, vào). */
    data class Change<K>(val leave: K?, val enter: K?)

    /** Ngón tới chỗ có phím chèn được [k] (null = không). null = không đổi gì (không vẽ lại). */
    fun move(k: K?): Change<K>? {
        if (k == over) return null
        val c = Change(over, k)
        over = k
        return c
    }

    companion object {
        /** Nhấc trên [k]: phím sẽ chèn (rồi về plane chữ); null = không chèn, ở lại plane số. */
        fun <K> lift(k: K?, cancelled: Boolean): K? = if (cancelled) null else k
    }
}
