package com.viettelex.keyboard

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/**
 * "Vuốt phím để sao chép/dán" (KeyCommandGesture) — cùng số liệu với iOS KeyCommandGestureTests:
 * phím 37 dp, mép trên vùng phím y = 0, hàng dưới (c x v) tâm y ≈ 135, hàng trên (e) ≈ 27.
 */
class KeyCommandGestureTests {
    @Before fun setUp() = TestAssets.install()

    private val pitch = 37f
    private val top = 0f

    private fun start(key: Char, x: Float = 150f, y: Float = 135f, enabled: Boolean = true, full: Boolean = true) =
        KeyCommandGesture.start(enabled, key, x, y, top, pitch, full = full)

    // MARK: ánh xạ phím → lệnh

    @Test fun mappingByPhysicalKey() {
        assertEquals(KeyCommand.COPY, KeyCommandGesture.commandFor('c'))
        assertEquals(KeyCommand.CUT, KeyCommandGesture.commandFor('x'))
        assertEquals(KeyCommand.PASTE, KeyCommandGesture.commandFor('v'))
        assertEquals(KeyCommand.SELECT_ALL, KeyCommandGesture.commandFor('a'))
        assertEquals(KeyCommand.UNDO, KeyCommandGesture.commandFor('z'))
        assertEquals(KeyCommand.REDO, KeyCommandGesture.commandFor('y'))
        assertEquals(KeyCommand.COPY, KeyCommandGesture.commandFor('C'))   // shift không đổi lệnh
        for (c in "bdefghijklmnopqrstuw") assertNull(c.toString(), KeyCommandGesture.commandFor(c))
    }

    @Test fun commandlessGestureArmsTheSameWay() {
        val g = KeyCommandGesture.startUp(150f, 27f, top, pitch)!!
        assertNull(g.command)
        g.move(150f, 10f)
        assertFalse(g.armed)
        g.move(152f, -10f)
        assertTrue(g.armed)
        assertTrue(g.releaseArmed(152f, -12f))
        assertFalse(KeyCommandGesture.startUp(150f, 27f, top, pitch)!!.releaseArmed(150f, 20f))
        val diag = KeyCommandGesture.startUp(150f, 27f, top, pitch)!!
        diag.move(200f, 20f)                       // sang phím bên cạnh: gõ vuốt tiếp quản
        assertFalse(diag.live)
        assertNull(KeyCommandGesture.startUp(150f, 27f, top, 0f))
    }

    @Test fun iosVariantOnlyCopyCutPaste() {
        assertEquals(KeyCommand.COPY, KeyCommandGesture.commandFor('c', full = false))
        assertEquals(KeyCommand.PASTE, KeyCommandGesture.commandFor('v', full = false))
        for (c in "azy") assertNull(KeyCommandGesture.commandFor(c, full = false))
    }

    @Test fun settingOffNeverArms() {
        for (c in "cxvazy") assertNull(start(c, enabled = false))
        assertNull(start('q'))                                   // phím không có lệnh: không theo dõi
        assertEquals(KeyCommand.COPY, start('c')!!.command)
    }

    @Test fun defaultsOffInSettingsAndBackup() {
        assertFalse(KeyboardSettings().swipeKeyCommands)
        assertTrue(KeyboardSettings.load { if (it == Keys.SWIPE_KEY_COMMANDS) true else null }.swipeKeyCommands)
        assertEquals(SettingKind.Bool(false), BackupSettings.byKey[Keys.SWIPE_KEY_COMMANDS]?.kind)
    }

    // MARK: bật / huỷ

    @Test fun straightUpPastTopArmsAndReleaseFires() {
        val g = start('c')!!
        assertEquals(KeyCommandGesture.Event.NONE, g.move(150f, 80f))
        assertEquals(KeyCommandGesture.Event.NONE, g.move(152f, 0f))       // đúng mép: chưa (cần 4 dp)
        assertEquals(KeyCommandGesture.Event.ARMED, g.move(155f, -5f))
        assertTrue(g.armed)
        assertEquals(KeyCommand.COPY, g.release(156f, -20f))
    }

    @Test fun releaseInsideKeyAreaIsNotACommand() {
        val g = start('v')!!
        g.move(150f, 30f)
        assertNull(g.release(150f, 27f))                                    // nhấc ở hàng trên: chỉ là chữ
        assertTrue(g.live)
    }

    @Test fun comingBackDownDisarmsAndCanRearm() {
        val g = start('x')!!
        assertEquals(KeyCommandGesture.Event.ARMED, g.move(150f, -10f))
        assertEquals(KeyCommandGesture.Event.NONE, g.move(150f, -1f))      // vùng trễ: vẫn bật
        assertEquals(KeyCommandGesture.Event.DISARMED, g.move(150f, 10f))
        assertNull(g.release(150f, 20f))
        val h = start('x')!!
        h.move(150f, -10f); h.move(150f, 10f)
        assertEquals(KeyCommandGesture.Event.ARMED, h.move(150f, -6f))
        assertEquals(KeyCommand.CUT, h.release(150f, -6f))
    }

    @Test fun diagonalSwipeTypingPathRejected() {
        // v (x=167) → e (x=93): chéo ~34° — gõ vuốt, không phải lệnh; loại vĩnh viễn.
        val g = start('v', x = 167f)!!
        assertEquals(KeyCommandGesture.Event.NONE, g.move(150f, 100f))
        var rejected = false
        for (i in 1..10) {
            val e = g.move(167f - 7.4f * i, 135f - 10.8f * i)
            if (e == KeyCommandGesture.Event.REJECTED) rejected = true
        }
        assertTrue(rejected)
        assertFalse(g.live)
        assertEquals(KeyCommandGesture.Event.NONE, g.move(93f, -20f))       // lên tiếp cũng không bật
        assertNull(g.release(93f, -20f))
    }

    @Test fun lateralToleranceThresholds() {
        // Gần điểm chạm: cho lệch tới nửa phím (18.5 dp).
        assertTrue(start('c')!!.apply { move(150f + 18f, 135f) }.live)
        assertFalse(start('c')!!.apply { move(150f + 19f, 135f) }.live)
        // Đi lên 100 dp: cho lệch 18.5 + 45 = 63.5 dp.
        assertTrue(start('c')!!.apply { move(150f + 63f, 35f) }.live)
        assertFalse(start('c')!!.apply { move(150f + 64f, 35f) }.live)
        // Lệch trái tính như phải.
        assertFalse(start('c')!!.apply { move(150f - 64f, 35f) }.live)
    }

    @Test fun movingDownRejects() {
        assertTrue(start('c')!!.apply { move(150f, 135f + 18f) }.live)
        assertFalse(start('c')!!.apply { move(150f, 135f + 19f) }.live)
    }

    @Test fun secondFingerOrPopupRejects() {
        val g = start('c')!!
        g.move(150f, -10f)
        assertEquals(KeyCommandGesture.Event.REJECTED, g.reject())
        assertEquals(KeyCommandGesture.Event.NONE, g.reject())
        assertNull(g.release(150f, -10f))
    }

    // MARK: checkpoint huỷ phím chữ

    @Test fun keyCommandsEnableLetterCheckpoint() {
        fun session(on: Boolean) = KeyboardSession(UserLangModel(), null) { 0L }.also {
            it.startInput(KeyboardSettings(), FieldTraits()); it.setKeyCommands(on)
        }
        val s = session(true); val p = MockProxy()
        for (c in "tieng") s.handle(Key.Letter(c), p)
        s.handle(Key.Letter('s'), p)
        val before = p.text                             // "tiếng"
        s.handle(Key.Letter('c'), p)                    // chạm c rồi vuốt lên: huỷ đúng phím c
        assertTrue(s.undoLastLetter(p))
        assertEquals(before, p.text)
        val off = session(false); val q = MockProxy()
        for (c in "an") off.handle(Key.Letter(c), q)
        assertFalse(off.undoLastLetter(q))              // tắt ⇒ không ghi checkpoint (0 chi phí)
    }

    /** #179: chữ hoãn lúc chạm mà đã chèn trước khi nhấc ⇒ không còn "hoãn", lệnh phải gỡ chữ. */
    @Test fun letterFiredBeforeReleaseIsNoLongerDeferred() {
        val q = KeyCommitQueue()
        val key = Any()
        var typed = 0
        q.arm(key) { typed++ }
        assertTrue(KeyCommandGesture.letterStillDeferred(true, q.isArmed(key)))    // còn chờ ⇒ chỉ bỏ khỏi hàng
        q.flush()                                                                  // giữ lâu / ngón khác: chữ đã chèn
        assertEquals(1, typed)
        assertFalse(KeyCommandGesture.letterStillDeferred(true, q.isArmed(key)))   // ⇒ lệnh gỡ chữ
        assertFalse(KeyCommandGesture.letterStillDeferred(false, false))           // chèn ngay lúc chạm như cũ
    }
}
