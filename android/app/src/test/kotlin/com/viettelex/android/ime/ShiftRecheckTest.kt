package com.viettelex.android.ime

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** #175: sau Enter (key event, app xử lý trễ) update của chính Enter phải làm IME tính lại auto-shift. */
class ShiftRecheckTest {
    @Test fun enterUpdateTriggersOneRecheck() {
        val t = SelectionTracker(); t.reset(3, 3)
        val r = ShiftRecheck()
        t.unknown(); r.arm()                         // Enter: không biết con trỏ về đâu
        assertFalse(t.onUpdate(4, 4))                // update của Enter khớp WILDCARD ⇒ không phải "đổi từ ngoài"
        assertTrue(r.onOwnUpdate(t.hasPending))      // ⇒ tính lại shift
        assertFalse(r.onOwnUpdate(t.hasPending))     // hết mốc chờ: update lặp không đọc lại nữa
    }

    @Test fun keepsRecheckingWhileOwnEditsArePending() {
        val t = SelectionTracker(); t.reset(3, 3)
        val r = ShiftRecheck()
        t.inserted(1)                                // chữ gõ ngay trước Enter, update chưa về
        t.unknown(); r.arm()
        assertFalse(t.onUpdate(4, 4))                // update của chữ về trước
        assertTrue(r.onOwnUpdate(t.hasPending))      // còn mốc Enter ⇒ vẫn chờ
        assertFalse(t.onUpdate(5, 5))
        assertTrue(r.onOwnUpdate(t.hasPending))
        assertFalse(r.onOwnUpdate(t.hasPending))
    }

    @Test fun ordinaryTypingNeverRechecks() {
        val t = SelectionTracker(); t.reset(0, 0)
        val r = ShiftRecheck()
        t.inserted(1)
        assertFalse(t.onUpdate(1, 1))
        assertFalse(r.onOwnUpdate(t.hasPending))
        r.arm(); r.reset()                           // ô mới / dời con trỏ từ ngoài
        assertFalse(r.onOwnUpdate(false))
    }
}
