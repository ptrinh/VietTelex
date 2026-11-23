package com.viettelex.android.ime

/**
 * #175: Enter đi bằng key event / performEditorAction ⇒ app xử lý BẤT ĐỒNG BỘ. Auto-shift tính ngay sau phím
 * đọc getTextBeforeCursor có thể còn chữ CŨ (chưa có "\n") ⇒ không bật shift, và onUpdateSelection của chính
 * Enter về sau lại khớp mốc WILDCARD ([SelectionTracker]) nên không ai tính lại — "xuống dòng nhiều khi không
 * viết hoa". Lớp này nhớ "đang chờ app báo lại sau Enter": mỗi update CỦA MÌNH trong lúc đó ⇒ IME bỏ shadow
 * (có thể vừa nạp chữ cũ) và tính lại shift; hết mốc chờ thì thôi. App không báo selection ⇒ như trước.
 * THUẦN — pinned by ShiftRecheckTest.
 */
class ShiftRecheck {
    private var armed = false

    /** Vừa gửi Enter không đồng bộ. */
    fun arm() { armed = true }

    /** Ô mới / con trỏ bị dời từ ngoài (đường đó tự tính lại shift). */
    fun reset() { armed = false }

    /**
     * onUpdateSelection khớp mốc của mình ([SelectionTracker.onUpdate] = false). [pending] = còn mốc chưa về
     * ([SelectionTracker.hasPending]). @return true ⇒ đọc lại chữ + tính lại auto-shift.
     */
    fun onOwnUpdate(pending: Boolean): Boolean {
        if (!armed) return false
        if (!pending) armed = false
        return true
    }
}
