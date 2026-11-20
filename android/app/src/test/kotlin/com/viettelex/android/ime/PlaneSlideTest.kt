package com.viettelex.android.ime

import android.os.Looper
import android.text.InputType
import android.view.MotionEvent
import android.view.View
import android.view.ViewGroup
import android.view.inputmethod.EditorInfo
import com.viettelex.keyboard.FieldTraits
import com.viettelex.keyboard.Key
import com.viettelex.keyboard.KeyboardSession
import com.viettelex.keyboard.KeyboardSettings
import com.viettelex.keyboard.Keys
import com.viettelex.keyboard.PlusGate
import com.viettelex.keyboard.UserLangModel
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import org.robolectric.android.controller.ServiceController
import org.robolectric.annotation.Config

/** #171 — trượt từ phím 123: phần quyết định thuần. = iOS PlaneSlideTests. */
class PlaneSlidePureTest {
    @Test fun moveReportsOnlyChanges() {
        val s = PlaneSlide<String>()
        assertNull("còn trên phím 123 / khe: không đổi", s.move(null))
        assertEquals(PlaneSlide.Change(null, "2"), s.move("2"))
        assertNull("trong cùng phím: không vẽ lại", s.move("2"))
        assertEquals(PlaneSlide.Change("2", "3"), s.move("3"))
        assertEquals(PlaneSlide.Change("3", null), s.move(null))
        assertNull(s.over)
    }

    @Test fun liftInsertsOnlyOverInsertableKeyAndNotCancelled() {
        assertEquals("2", PlaneSlide.lift("2", cancelled = false))
        assertNull("khe / phím không chèn: không gì", PlaneSlide.lift<String>(null, cancelled = false))
        assertNull("huỷ: không gì", PlaneSlide.lift("2", cancelled = true))
    }
}

/**
 * #171 — luồng KeyboardView thật (MotionEvent): chạm 123 đổi sang plane số ngay lúc chạm; trượt
 * sang phím ký tự rồi nhấc ⇒ chèn + về chữ; nhấc tại chỗ / chỗ không chèn / huỷ / ngón thứ hai ⇒
 * không chèn, ở lại plane số. = iOS PlaneSlideKeyboardFlowTests.
 */
@RunWith(RobolectricTestRunner::class)
@Config(qualifiers = "w411dp-h891dp-port-xxhdpi")
class PlaneSlideTest {
    private var ctrl: ServiceController<VietTelexIME>? = null
    private val savedPaywall = PlusGate.paywallEnabled

    @Before fun setUp() { PlusGate.paywallEnabled = false }
    @After fun tearDown() {
        ctrl?.destroy()
        RuntimeEnvironment.getApplication().getSharedPreferences(Keys.PREFS, android.content.Context.MODE_PRIVATE)
            .edit().clear().commit()
        PlusGate.paywallEnabled = savedPaywall
    }

    /** Ghi lại phím KeyboardView giao cho IME; mọi thứ khác đi thẳng vào IME thật. */
    private class Recorder(ime: VietTelexIME) : KeyboardView.Listener by ime {
        val keys = ArrayList<Key>()
        override fun onKey(key: Key) { keys.add(key) }
    }

    private fun keyboard(): Pair<KeyboardView, Recorder> {
        val c = Robolectric.buildService(VietTelexIME::class.java).create()
        ctrl = c
        val ime = c.get()
        val v = ime.onCreateInputView()
        ime.setInputView(v)
        val frame = v.parent as ViewGroup
        ime.onStartInputView(EditorInfo().apply { inputType = InputType.TYPE_CLASS_TEXT; packageName = "com.example.chat" }, false)
        val r = frame.getChildAt(0)
        val dm = ime.resources.displayMetrics
        r.measure(View.MeasureSpec.makeMeasureSpec(dm.widthPixels, View.MeasureSpec.EXACTLY),
            View.MeasureSpec.makeMeasureSpec(dm.heightPixels, View.MeasureSpec.AT_MOST))
        r.layout(0, 0, r.measuredWidth, r.measuredHeight)
        val kb = find(r, ImeRootView::class.java)!!.keyboard
        val rec = Recorder(ime)
        kb.listener = rec
        kb.swipeTyping = false
        return kb to rec
    }

    private fun <T : View> find(v: View, type: Class<T>): T? {
        if (type.isInstance(v)) return type.cast(v)
        if (v is ViewGroup) for (i in 0 until v.childCount) find(v.getChildAt(i), type)?.let { return it }
        return null
    }

    private val t0 = 1_000L
    private val active = LinkedHashMap<Int, android.graphics.PointF>()

    private fun send(kb: KeyboardView, action: Int, t: Long, index: Int = 0) {
        val ids = active.keys.toList()
        val props = Array(ids.size) { i -> MotionEvent.PointerProperties().apply { id = ids[i]; toolType = MotionEvent.TOOL_TYPE_FINGER } }
        val coords = Array(ids.size) { i -> MotionEvent.PointerCoords().apply { x = active[ids[i]]!!.x; y = active[ids[i]]!!.y; pressure = 1f; size = 1f } }
        val a = if (action == MotionEvent.ACTION_POINTER_DOWN || action == MotionEvent.ACTION_POINTER_UP)
            action or (index shl MotionEvent.ACTION_POINTER_INDEX_SHIFT) else action
        val e = MotionEvent.obtain(t0, t, a, ids.size, props, coords, 0, 0, 1f, 1f, 0, 0, 0, 0)
        kb.dispatchTouchEvent(e)
        e.recycle()
        shadowOf(Looper.getMainLooper()).idle()
    }

    private fun down(kb: KeyboardView, pid: Int, p: android.graphics.PointF, t: Long) {
        active[pid] = p
        send(kb, if (active.size == 1) MotionEvent.ACTION_DOWN else MotionEvent.ACTION_POINTER_DOWN, t, active.keys.indexOf(pid))
    }

    private fun moveTo(kb: KeyboardView, pid: Int, p: android.graphics.PointF, t: Long) {
        active[pid] = p
        send(kb, MotionEvent.ACTION_MOVE, t)
    }

    private fun up(kb: KeyboardView, pid: Int, t: Long, cancel: Boolean = false) {
        val idx = active.keys.indexOf(pid)
        send(kb, if (cancel) MotionEvent.ACTION_CANCEL else if (active.size == 1) MotionEvent.ACTION_UP else MotionEvent.ACTION_POINTER_UP, t, idx)
        if (cancel) active.clear() else active.remove(pid)
    }

    private fun tap(kb: KeyboardView, p: android.graphics.PointF, t: Long) { down(kb, 0, p, t); up(kb, 0, t + 40) }

    /** Chạm 123 (ngón 0, còn đè). */
    private fun press123(kb: KeyboardView): android.graphics.PointF {
        assertEquals(Plane.LETTERS, kb.plane)
        val p = kb.planeKeyCenter()!!
        down(kb, 0, p, t0)
        assertEquals("đổi plane ngay lúc chạm", Plane.NUMBERS, kb.plane)
        return p
    }

    @Test fun tapOn123StaysOnNumbers() {
        val (kb, rec) = keyboard()
        press123(kb)
        up(kb, 0, t0 + 60)
        assertEquals(Plane.NUMBERS, kb.plane)
        assertTrue(rec.keys.isEmpty())
        // ABC vẫn về chữ như cũ (hành động lúc nhấc)
        tap(kb, kb.planeKeyCenter()!!, t0 + 500)
        assertEquals(Plane.LETTERS, kb.plane)
    }

    @Test fun slideToDigitInsertsAndReturnsToLetters() {
        val (kb, rec) = keyboard()
        press123(kb)
        moveTo(kb, 0, kb.keyCenter("3")!!, t0 + 30)
        val two = kb.keyCenter("2")!!
        moveTo(kb, 0, two, t0 + 60)
        assertTrue("đang trượt: chưa chèn gì", rec.keys.isEmpty())
        up(kb, 0, t0 + 90)
        assertEquals(listOf<Key>(Key.Text("2")), rec.keys)
        assertEquals("tự về plane chữ", Plane.LETTERS, kb.plane)
    }

    @Test fun slideToSymbolInsertsAndReturnsToLetters() {
        val (kb, rec) = keyboard()
        press123(kb)
        moveTo(kb, 0, kb.keyCenter("@")!!, t0 + 40)
        up(kb, 0, t0 + 80)
        assertEquals(listOf<Key>(Key.Text("@")), rec.keys)
        assertEquals(Plane.LETTERS, kb.plane)
    }

    @Test fun liftOnNonInsertableKeyInsertsNothing() {
        val (kb, rec) = keyboard()
        press123(kb)
        moveTo(kb, 0, kb.keyCenter("1")!!, t0 + 30)
        moveTo(kb, 0, kb.backspaceCenter()!!, t0 + 60)
        up(kb, 0, t0 + 90)
        assertTrue("không ⌫, không ký tự", rec.keys.isEmpty())
        assertEquals(Plane.NUMBERS, kb.plane)
    }

    @Test fun liftOutsideKeysOrCancelInsertsNothing() {
        val (kb, rec) = keyboard()
        press123(kb)
        moveTo(kb, 0, kb.keyCenter("9")!!, t0 + 30)
        moveTo(kb, 0, android.graphics.PointF(5f, -200f), t0 + 60)      // lên khỏi bàn phím
        up(kb, 0, t0 + 90)
        assertTrue(rec.keys.isEmpty())
        assertEquals(Plane.NUMBERS, kb.plane)
        // huỷ (hệ thống giật ngón) khi đang trên phím số ⇒ không gì
        tap(kb, kb.planeKeyCenter()!!, t0 + 300)                     // ABC về chữ
        press123(kb)
        moveTo(kb, 0, kb.keyCenter("5")!!, t0 + 30)
        up(kb, 0, t0 + 60, cancel = true)
        assertTrue(rec.keys.isEmpty())
        assertEquals(Plane.NUMBERS, kb.plane)
    }

    @Test fun secondFingerEndsSlideWithoutInserting() {
        val (kb, rec) = keyboard()
        press123(kb)
        moveTo(kb, 0, kb.keyCenter("7")!!, t0 + 30)
        down(kb, 1, kb.keyCenter("8")!!, t0 + 50)                     // ngón thứ hai: gõ "8" như thường
        up(kb, 1, t0 + 80)
        up(kb, 0, t0 + 100)                                            // ngón trượt nhấc trên "7": đã hết trượt
        assertEquals("chỉ phím của ngón thứ hai", listOf<Key>(Key.Text("8")), rec.keys)
        assertEquals(Plane.NUMBERS, kb.plane)
    }

    /** VNI: số trượt tới = đúng như chạm phím số đó (cùng phím gửi đi ⇒ cùng kết quả trong từ). */
    @Test fun vniDigitViaSlideMatchesTap() {
        val (kb1, rec1) = keyboard()
        tap(kb1, kb1.planeKeyCenter()!!, t0)                           // chạm 123: ở plane số
        tap(kb1, kb1.keyCenter("6")!!, t0 + 200)
        val tapped = rec1.keys.toList()
        ctrl?.destroy(); ctrl = null; active.clear()
        val (kb2, rec2) = keyboard()
        press123(kb2)
        moveTo(kb2, 0, kb2.keyCenter("6")!!, t0 + 40)
        up(kb2, 0, t0 + 80)
        assertEquals(tapped, rec2.keys)
        assertEquals(listOf<Key>(Key.Text("6")), rec2.keys)
        // cùng chuỗi phím qua phiên VNI thật: "viet" + 6 ⇒ "viêt" (6 là dấu mũ, không phải chữ số)
        fun run(keys: List<Key>): String {
            val ed = FakeEditor("")
            val tracker = SelectionTracker().also { it.reset(ed.selStart, ed.selEnd) }
            val p = IcProxy({ ed }, tracker).also { it.startInput("", true) }
            val s = KeyboardSession(UserLangModel(), null) { 0L }
            s.startInput(KeyboardSettings(vniMode = true), FieldTraits())
            p.begin(); try { for (c in "viet") s.handle(Key.Letter(c), p); for (k in keys) s.handle(k, p) } finally { p.end() }
            return ed.text
        }
        assertEquals(run(tapped), run(rec2.keys))
        assertNotEquals("viet6", run(rec2.keys))
        assertEquals(Plane.LETTERS, kb2.plane)
    }
}
