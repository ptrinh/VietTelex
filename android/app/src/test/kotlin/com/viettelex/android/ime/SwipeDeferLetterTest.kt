package com.viettelex.android.ime

import android.os.Looper
import android.text.InputType
import android.view.MotionEvent
import android.view.View
import android.view.ViewGroup
import android.view.inputmethod.EditorInfo
import com.viettelex.keyboard.Key
import com.viettelex.keyboard.Keys
import com.viettelex.keyboard.PlusGate
import com.viettelex.keyboard.SwipePath
import com.viettelex.keyboard.SwipeSuggest
import org.junit.After
import org.junit.Assert.assertEquals
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

/**
 * #172 — gõ vuốt bật: ngón còn đè thì KHÔNG ghi gì vào ô. Chạm ⇒ chữ chèn lúc nhấc (hoặc khi ngón
 * khác chạm xuống, đúng thứ tự chạm); vuốt ⇒ chỉ từ vuốt (chữ đầu không hiện rồi mất). Tắt gõ vuốt
 * ⇒ chữ chèn ngay lúc chạm như cũ. Đường KeyboardView thật (MotionEvent), IME thật làm phần còn lại.
 */
@RunWith(RobolectricTestRunner::class)
@Config(qualifiers = "w411dp-h891dp-port-xxhdpi")
class SwipeDeferLetterTest {
    private var ctrl: ServiceController<VietTelexIME>? = null
    private val savedPaywall = PlusGate.paywallEnabled

    @Before fun setUp() { PlusGate.paywallEnabled = false }
    @After fun tearDown() {
        ctrl?.destroy()
        RuntimeEnvironment.getApplication().getSharedPreferences(Keys.PREFS, android.content.Context.MODE_PRIVATE)
            .edit().clear().commit()
        PlusGate.paywallEnabled = savedPaywall
    }

    /** Ghi lại những gì KeyboardView giao cho IME; mọi thứ khác đi thẳng vào IME thật. */
    private class Recorder(ime: VietTelexIME) : KeyboardView.Listener by ime {
        val letters = StringBuilder()
        var swipeStarts = 0
        var swipeEnds = 0
        override fun onKey(key: Key) { if (key is Key.Letter) letters.append(key.ch.lowercaseChar()) }
        override fun onSwipeTypingStart(): Boolean { swipeStarts++; return true }
        override fun onSwipeTypingEnd(path: SwipePath, case: SwipeSuggest.Case) { swipeEnds++ }
        override fun onSwipeTypingCancel() {}
    }

    private fun keyboard(swipe: Boolean): Pair<KeyboardView, Recorder> {
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
        kb.swipeTyping = swipe
        return kb to rec
    }

    private fun <T : View> find(v: View, type: Class<T>): T? {
        if (type.isInstance(v)) return type.cast(v)
        if (v is ViewGroup) for (i in 0 until v.childCount) find(v.getChildAt(i), type)?.let { return it }
        return null
    }

    private val down0 = 1_000L
    private val active = LinkedHashMap<Int, android.graphics.PointF>()

    /** Một sự kiện cho mọi ngón đang chạm ([active]); [index] = ngón của action (POINTER_DOWN/UP). */
    private fun send(kb: KeyboardView, action: Int, t: Long, index: Int = 0) {
        val ids = active.keys.toList()
        val props = Array(ids.size) { i -> MotionEvent.PointerProperties().apply { id = ids[i]; toolType = MotionEvent.TOOL_TYPE_FINGER } }
        val coords = Array(ids.size) { i -> MotionEvent.PointerCoords().apply { x = active[ids[i]]!!.x; y = active[ids[i]]!!.y; pressure = 1f; size = 1f } }
        val a = if (action == MotionEvent.ACTION_POINTER_DOWN || action == MotionEvent.ACTION_POINTER_UP)
            action or (index shl MotionEvent.ACTION_POINTER_INDEX_SHIFT) else action
        val e = MotionEvent.obtain(down0, t, a, ids.size, props, coords, 0, 0, 1f, 1f, 0, 0, 0, 0)
        kb.dispatchTouchEvent(e)
        e.recycle()
        shadowOf(Looper.getMainLooper()).idle()
    }

    private fun down(kb: KeyboardView, pid: Int, p: android.graphics.PointF, t: Long) {
        active[pid] = p
        send(kb, if (active.size == 1) MotionEvent.ACTION_DOWN else MotionEvent.ACTION_POINTER_DOWN, t, active.keys.indexOf(pid))
    }

    private fun up(kb: KeyboardView, pid: Int, t: Long) {
        val idx = active.keys.indexOf(pid)
        send(kb, if (active.size == 1) MotionEvent.ACTION_UP else MotionEvent.ACTION_POINTER_UP, t, idx)
        active.remove(pid)
    }

    private fun center(kb: KeyboardView, s: String) = kb.keyCenter(s)!!

    @Test fun tapCommitsOnLiftNotOnTouchDown() {
        val (kb, rec) = keyboard(swipe = true)
        down(kb, 0, center(kb, "a"), down0)
        assertEquals("chạm xuống: chưa chèn", "", rec.letters.toString())
        up(kb, 0, down0 + 60)
        assertEquals("a", rec.letters.toString())
    }

    @Test fun overlappingTapsKeepTouchDownOrder() {
        val (kb, rec) = keyboard(swipe = true)
        down(kb, 0, center(kb, "a"), down0)
        down(kb, 1, center(kb, "n"), down0 + 40)          // a chưa nhấc ⇒ a chốt TRƯỚC n
        assertEquals("an", rec.letters.toString())
        up(kb, 1, down0 + 70)                              // n nhấc trước a: không đổi thứ tự, không mất
        up(kb, 0, down0 + 80)
        assertEquals("an", rec.letters.toString())
        down(kb, 0, center(kb, "h"), down0 + 500)
        assertEquals("an", rec.letters.toString())
        up(kb, 0, down0 + 560)
        assertEquals("anh", rec.letters.toString())
    }

    @Test fun swipeWritesNothingWhileFingerDown() {
        val (kb, rec) = keyboard(swipe = true)
        val keys = "chao".map { center(kb, it.toString()) }
        down(kb, 0, keys[0], down0)
        var t = down0
        for (i in 1 until keys.size) {
            val a = keys[i - 1]; val b = keys[i]
            for (j in 1..8) {
                val u = j / 8f
                t += 16
                active[0] = android.graphics.PointF(a.x + (b.x - a.x) * u, a.y + (b.y - a.y) * u)
                send(kb, MotionEvent.ACTION_MOVE, t)
            }
        }
        assertEquals("thành vuốt", 1, rec.swipeStarts)
        assertEquals("đang vuốt: không chữ nào hiện rồi mất", "", rec.letters.toString())
        up(kb, 0, t + 16)
        assertEquals(1, rec.swipeEnds)
        assertEquals("nhấc tay: chỉ từ vuốt, không có chữ đầu", "", rec.letters.toString())
    }

    @Test fun swipeTypingOffInsertsOnTouchDown() {
        val (kb, rec) = keyboard(swipe = false)
        down(kb, 0, center(kb, "a"), down0)
        assertEquals("tắt gõ vuốt: chèn ngay lúc chạm như cũ", "a", rec.letters.toString())
        up(kb, 0, down0 + 60)
        assertEquals("a", rec.letters.toString())
        assertTrue(rec.swipeStarts == 0)
    }
}
