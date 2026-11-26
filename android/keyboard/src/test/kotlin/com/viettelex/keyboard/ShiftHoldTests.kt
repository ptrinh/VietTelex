package com.viettelex.keyboard

import com.viettelex.keyboard.SuggestionCase.Shift
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/**
 * "Giữ Shift để gõ số và ký hiệu" (yêu cầu người dùng Văn Việt, Phil duyệt): giữ ⇧ + chạm
 * q w e ⇒ "123" mà không phải sang bàn số. Máy trạng thái ⇧ (chạm / chạm đôi / giữ) THUẦN —
 * cùng bộ ca với iOS ShiftHoldTests.
 */
class ShiftHoldTests {
    @Before fun setUp() = TestAssets.install()

    private val digitsOnly = KeyAlternates.shiftMap(true, numbers = true, symbols = false, numberRow = false)
    private val all = KeyAlternates.shiftMap(true, numbers = true, symbols = true, numberRow = false)
    private val H = ShiftHold.ROLLOVER_MS + 50

    /** Chạm nhanh ⇧ = viết hoa một lần; chạm đôi = Caps Lock; chạm thứ hai chậm = tắt (như cũ). */
    @Test fun tripleTapLeavesCapsLock() {
        val h = ShiftHold()
        var s = h.down(Shift.OFF, 1_000); s = h.up(s)
        s = h.down(s, 1_150); assertEquals(Shift.CAPS_LOCK, s); s = h.up(s)
        s = h.down(s, 1_300); assertEquals("lần thứ ba không còn là chạm đôi", Shift.OFF, s); s = h.up(s)
        s = h.down(s, 1_450); assertEquals("chạm đôi mới", Shift.CAPS_LOCK, s)
    }

    @Test fun tapDoubleTapUnchanged() {
        val h = ShiftHold()
        var s = h.down(Shift.OFF, 1_000); assertEquals(Shift.ONCE, s)
        s = h.up(s); assertEquals(Shift.ONCE, s)
        s = h.down(s, 1_200); assertEquals(Shift.CAPS_LOCK, s)
        s = h.up(s); assertEquals(Shift.CAPS_LOCK, s)
        s = h.down(s, 5_000); assertEquals(Shift.OFF, s)
        s = h.up(s)
        s = h.down(s, 9_000); assertEquals(Shift.ONCE, s)
        s = h.up(s)
        s = h.down(s, 9_000 + ShiftHold.DOUBLE_TAP_MS + 1); assertEquals("chậm ⇒ không phải chạm đôi", Shift.OFF, s)
    }

    /** Giữ ⇧ + q w e ⇒ 1 2 3; nhả KHÔNG để lại viết hoa một lần; lần chạm kế không thành chạm đôi. */
    @Test fun heldShiftTypesDigitsAndLeavesNoOneShot() {
        val h = ShiftHold()
        var s = h.down(Shift.OFF, 1_000)
        val out = "qwe".mapIndexed { i, c -> h.symbol(c, digitsOnly, 1_000 + H + i * 100L) }.joinToString("")
        assertEquals("123", out)
        s = h.up(s)
        assertEquals(Shift.OFF, s)
        assertFalse(h.held)
        // Chạm ⇧ ngay sau khi nhả (< 300 ms tính từ lúc chạm trước): vẫn một-lần, không Caps.
        s = h.down(s, 1_000 + H + 250); assertEquals(Shift.ONCE, s)
    }

    /** Đầu câu (auto-shift ON) giữ ⇧ gõ số: nhả ⇒ OFF (IME tự tính lại auto-shift sau đó). */
    @Test fun heldFromAutoShiftEndsOff() {
        val h = ShiftHold()
        var s = h.down(Shift.ONCE, 0)       // chạm ⇧ khi đang ON ⇒ OFF lúc giữ
        assertEquals("1", h.symbol('q', digitsOnly, H))
        s = h.up(s)
        assertEquals(Shift.OFF, s)
    }

    /** Caps Lock đang bật: giữ ⇧ gõ ký hiệu ⇒ nhả vẫn Caps Lock. Không giữ thì Caps gõ chữ hoa như cũ. */
    @Test fun capsLockPreserved() {
        val h = ShiftHold()
        assertNull("không giữ ⇧ ⇒ chữ như cũ (Caps hoa)", h.symbol('q', all, 0))
        var s = h.down(Shift.CAPS_LOCK, 10_000)
        assertEquals(Shift.OFF, s)
        assertEquals("@", h.symbol('a', all, 10_000 + H))
        s = h.up(s)
        assertEquals(Shift.CAPS_LOCK, s)
        // Chạm đôi rồi giữ, gõ số: vẫn Caps Lock.
        s = h.down(Shift.OFF, 20_000); s = h.up(s)
        s = h.down(s, 20_100); assertEquals(Shift.CAPS_LOCK, s)
        assertEquals("2", h.symbol('w', all, 20_100 + H))
        assertEquals(Shift.CAPS_LOCK, h.up(s))
    }

    /** Gõ chồng ngón nhanh (⇧ rồi chữ, ⇧ chưa nhả) vẫn là chữ hoa — không thành số. */
    @Test fun rolloverStaysCapital() {
        val h = ShiftHold()
        var s = h.down(Shift.OFF, 1_000)
        assertNull(h.symbol('q', all, 1_000 + 60))
        s = Shift.OFF                        // view: chữ hoa đã dùng một-lần
        assertEquals(Shift.OFF, h.up(s))
        // Giữ lâu hơn: ngón thứ hai gõ nhiều phím liền ⇒ số.
        s = h.down(Shift.OFF, 5_000)
        assertNull(h.symbol('q', all, 5_100))                    // chồng ngón
        assertEquals("2", h.symbol('w', all, 5_000 + H))        // đã giữ
        assertEquals(Shift.OFF, h.up(Shift.OFF))
    }

    /** Tắt cài đặt (bảng rỗng) ⇒ hành vi cũ: giữ ⇧ + chữ là chữ hoa, nhả không đụng shift. */
    @Test fun settingOffRestoresOldBehaviour() {
        val off = KeyAlternates.shiftMap(false, numbers = true, symbols = true, numberRow = false)
        assertTrue(off.isEmpty())
        val h = ShiftHold()
        val s = h.down(Shift.OFF, 0)
        assertNull(h.symbol('q', off, H))
        assertEquals("nhả trả nguyên trạng thái view", Shift.ONCE, h.up(Shift.ONCE))
    }

    /** Phím không có ký tự phụ (chỉ bật số: a…m) ⇒ chữ như cũ. */
    @Test fun keyWithoutHintFallsBack() {
        val h = ShiftHold()
        h.down(Shift.OFF, 0)
        assertNull(h.symbol('a', digitsOnly, H))
        assertEquals("0", h.symbol('p', digitsOnly, H))
    }

    /** Giữ ⇧ + kéo phím cách chọn chữ: nhả trả shift như trước khi chạm (hành vi cũ). */
    @Test fun selectModifierRestoresBefore() {
        val h = ShiftHold()
        val s = h.down(Shift.ONCE, 0)
        h.markSelect()
        assertEquals(Shift.ONCE, h.up(s))
        h.markSelect()                       // không giữ ⇒ không ghi nhận
        h.down(Shift.OFF, 10_000)
        assertEquals(Shift.ONCE, h.up(Shift.ONCE))
    }

    @Test fun cancelDropsHold() {
        val h = ShiftHold()
        h.down(Shift.OFF, 0)
        h.cancel()
        assertFalse(h.held)
        assertNull(h.symbol('q', all, H))
        assertEquals(Shift.ONCE, h.up(Shift.ONCE))
    }

    /** Phiên thật trên CÙNG instance: chạm, giữ-gõ số, chọn chữ, Caps, chồng ngón xen kẽ. */
    @Test fun realisticSessionSequence() {
        val h = ShiftHold()
        var t = 100_000L
        var s = Shift.OFF
        s = h.down(s, t); s = h.up(s); assertEquals(Shift.ONCE, s)       // chạm: hoa một lần
        s = Shift.OFF                                                    // gõ "A"
        t += 1_000
        s = h.down(s, t)
        assertEquals("12", listOf('q', 'w').map { h.symbol(it, all, t + H) }.joinToString(""))
        s = h.up(s); assertEquals(Shift.OFF, s)
        t += 100
        s = h.down(s, t); assertEquals("không thành chạm đôi", Shift.ONCE, s); s = h.up(s)
        t += 150
        s = h.down(s, t); assertEquals(Shift.CAPS_LOCK, s); s = h.up(s)
        t += 2_000
        s = h.down(s, t); assertEquals("?", h.symbol('m', all, t + H)); s = h.up(s)
        assertEquals(Shift.CAPS_LOCK, s)
        t += 2_000
        s = h.down(s, t); s = h.up(s); assertEquals(Shift.OFF, s)        // chạm tắt Caps
    }

    /** Bảng giữ ⇧ = đúng ký tự phụ giữ lâu / vuốt xuống (KeyAlternates); hàng số bật vẫn có số. */
    @Test fun mapParityWithAlternates() {
        for (n in listOf(true, false)) for (sym in listOf(true, false)) {
            assertEquals(KeyAlternates.map(n, sym, numberRow = false), KeyAlternates.shiftMap(true, n, sym, numberRow = false))
            val row = KeyAlternates.shiftMap(true, n, sym, numberRow = true)
            for ((k, v) in KeyAlternates.digits) assertEquals("hàng số bật: giữ ⇧+$k vẫn ra $v", v, row[k])
            if (sym) for ((k, v) in KeyAlternates.symbols) assertEquals(v, row[k])
            else assertTrue(KeyAlternates.symbols.keys.none { it in row })
            // TalkBack: tắt như giữ lâu.
            assertTrue(KeyAlternates.shiftMap(true, n, sym, numberRow = false, accessibility = true).isEmpty())
        }
        assertEquals("1", all['q']); assertEquals("0", all['p']); assertEquals("@", all['a']); assertEquals("?", all['m'])
    }

    /** Ký tự phụ vào phiên là NGUYÊN VĂN: VNI không lấy "1" làm dấu sắc; Telex là ranh giới. */
    @Test fun heldDigitIsLiteralInVni() {
        val s = KeyboardSession(UserLangModel(), null) { 0L }
        s.startInput(KeyboardSettings(vniMode = true), FieldTraits())
        val p = MockProxy()
        s.handle(Key.Letter('a'), p)
        s.handle(ShiftHold.key("1"), p)
        assertEquals("a1", p.text)
        assertFalse(s.bridge.isComposing)
        // Đối chứng: số hàng số / giữ lâu (không giữ ⇧) vẫn bỏ dấu VNI.
        s.handle(Key.Space, p)
        s.handle(Key.Letter('a'), p)
        s.handle(Key.Text("1"), p)
        assertEquals("a1 á", p.text)

        val t = KeyboardSession(UserLangModel(), null) { 0L }
        t.startInput(KeyboardSettings(), FieldTraits())
        val q = MockProxy()
        for (c in "vieetj") t.handle(Key.Letter(c), q)
        for (c in "12") t.handle(ShiftHold.key(c.toString()), q)
        assertEquals("việt12", q.text)
    }
}
