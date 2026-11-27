package com.viettelex.android.ime

import com.viettelex.keyboard.WriteMode
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Ô nhập giả: văn bản + selection; key event áp BẤT ĐỒNG BỘ (sau endBatch) như AOSP. */
class FakeEditor(initial: String = "", var selStart: Int = initial.length, var selEnd: Int = selStart) : EditorPort {
    val sb = StringBuilder(initial)
    val text: String get() = sb.toString()
    val keys = ArrayList<EditorPort.PortKey>()
    private val pendingKeys = ArrayList<Any>()   // PortKey hoặc String (sendText)
    /** Mô phỏng app bỏ qua lệnh: ONLYOFFICE (deleteSurrounding) / WPS sandbox (commitText). */
    var ignoreDeletes = false
    var ignoreCommits = false
    var reads = 0
    var failWrites = false
    var finishComposingCalls = 0
    var setSelections = 0
    var readable = true
    private var depth = 0

    override fun beginBatch() { depth++ }
    override fun endBatch() { if (--depth == 0) flushKeys() }
    private fun flushKeys() {
        for (k in pendingKeys) when (k) {
            is String -> replaceSel(k)
            EditorPort.PortKey.DEL -> if (selStart != selEnd) replaceSel("") else if (selStart > 0) {
                val n = Character.charCount(Character.codePointBefore(sb, selStart))
                sb.delete(selStart - n, selStart); selStart -= n; selEnd = selStart
            }
            EditorPort.PortKey.LEFT -> { if (selStart > 0) selStart--; selEnd = selStart }
            EditorPort.PortKey.RIGHT -> { if (selEnd < sb.length) selEnd++; selStart = selEnd }
            EditorPort.PortKey.ENTER -> replaceSel("\n")
            EditorPort.PortKey.UP -> dpadVertical(up = true)
            EditorPort.PortKey.DOWN -> dpadVertical(up = false)
        }
        pendingKeys.clear()
    }
    /** Số DPAD lên/xuống KHÔNG được tiêu thụ ⇒ hệ thống sẽ dời focus sang view khác. */
    var focusEscapes = 0
    /** Mô phỏng ArrowKeyMovementMethod (Selection.moveUp/moveDown), dòng = dòng logic. */
    private fun dpadVertical(up: Boolean) {
        val t = text; val p = selEnd
        val lineStart = t.lastIndexOf('\n', p - 1) + 1
        val col = p - lineStart
        if (up) {
            if (lineStart > 0) {
                val prevStart = t.lastIndexOf('\n', lineStart - 2) + 1
                selStart = prevStart + minOf(col, lineStart - 1 - prevStart)
            } else if (p != 0) selStart = 0 else focusEscapes++
        } else {
            val nl = t.indexOf('\n', p)
            if (nl >= 0) {
                val nextEnd = t.indexOf('\n', nl + 1).let { if (it < 0) t.length else it }
                selStart = nl + 1 + minOf(col, nextEnd - nl - 1)
            } else if (p != t.length) selStart = t.length else focusEscapes++
        }
        selEnd = selStart
    }
    private fun replaceSel(t: CharSequence) {
        sb.replace(selStart, selEnd, t.toString()); selStart += t.length; selEnd = selStart
    }
    override fun commitText(text: CharSequence): Boolean {
        if (failWrites) return false; if (!ignoreCommits) replaceSel(text); return true
    }
    override fun sendText(text: CharSequence) { pendingKeys.add(text.toString()); if (depth == 0) flushKeys() }
    override fun deleteBefore(utf16: Int): Boolean {
        if (failWrites) return false
        val n = minOf(utf16, selStart); sb.delete(selStart - n, selStart); selStart -= n; selEnd -= n; return true
    }
    override fun deleteCodePointsBefore(count: Int): Boolean {
        if (failWrites) return false
        if (ignoreDeletes) return true
        var p = selStart
        repeat(count) { if (p > 0) p -= Character.charCount(Character.codePointBefore(sb, p)) }
        return deleteBefore(selStart - p)
    }
    override fun deleteSurrounding(before: Int, after: Int): Boolean {
        val a = maxOf(0, selStart - before); val b = minOf(sb.length, selEnd + after)
        sb.delete(a, b); selStart = a; selEnd = a; return true
    }
    override fun textBefore(n: Int): CharSequence? { reads++; if (!readable) return null; return sb.substring(maxOf(0, selStart - n), selStart) }
    override fun textAfter(n: Int): CharSequence? = if (!readable) null else sb.substring(selEnd, minOf(sb.length, selEnd + n))
    override fun selectedText(): CharSequence? = if (!readable) null else sb.substring(minOf(selStart, selEnd), maxOf(selStart, selEnd))
    override fun setSelection(start: Int, end: Int): Boolean { setSelections++; selStart = start; selEnd = end; return true }
    override fun finishComposing(): Boolean { finishComposingCalls++; return true }
    val actions = ArrayList<Int>()
    /** Độ sâu batch lúc Enter / editor action tới app (#182: phải là 0 — sửa đã áp xong). */
    val depthAtNewline = ArrayList<Int>()
    override fun performEditorAction(actionId: Int): Boolean { depthAtNewline.add(depth); actions.add(actionId); return true }
    override fun sendKey(key: EditorPort.PortKey) {
        if (key == EditorPort.PortKey.ENTER) depthAtNewline.add(depth)
        keys.add(key); pendingKeys.add(key); if (depth == 0) flushKeys()
    }

    // --- bảng sửa văn bản: performContextMenuAction + phím kèm meta ---
    /** false ⇒ app không hỗ trợ menu (WebView cũ…): IME phải rơi về phím tắt. */
    var menuSupported = true
    /** undo/redo là menu riêng: TextView có, Chrome không. */
    var undoMenuSupported = true
    var clipboard = ""
    val menus = ArrayList<EditorPort.MenuAction>()
    val metaKeys = ArrayList<Triple<EditorPort.PortKey, Boolean, Boolean>>()
    private val undoStack = ArrayList<Triple<String, Int, Int>>()
    private val redoStack = ArrayList<Triple<String, Int, Int>>()
    fun snapshot() { undoStack.add(Triple(text, selStart, selEnd)); redoStack.clear() }
    private fun restore(t: Triple<String, Int, Int>) { sb.setLength(0); sb.append(t.first); selStart = t.second; selEnd = t.third }
    private fun selected() = sb.substring(minOf(selStart, selEnd), maxOf(selStart, selEnd))
    override fun menuAction(action: EditorPort.MenuAction): Boolean {
        if (!menuSupported) return false
        if ((action == EditorPort.MenuAction.UNDO || action == EditorPort.MenuAction.REDO) && !undoMenuSupported) return false
        menus.add(action)
        when (action) {
            EditorPort.MenuAction.SELECT_ALL -> { selStart = 0; selEnd = sb.length }
            EditorPort.MenuAction.COPY -> if (selStart != selEnd) clipboard = selected()
            EditorPort.MenuAction.CUT -> if (selStart != selEnd) {
                snapshot(); clipboard = selected()
                val lo = minOf(selStart, selEnd); val hi = maxOf(selStart, selEnd); selStart = lo; selEnd = hi
                replaceSel("")
            }
            EditorPort.MenuAction.PASTE -> {
                snapshot()
                val lo = minOf(selStart, selEnd); val hi = maxOf(selStart, selEnd); selStart = lo; selEnd = hi
                replaceSel(clipboard)
            }
            EditorPort.MenuAction.UNDO -> undoStack.removeLastOrNull()?.let { redoStack.add(Triple(text, selStart, selEnd)); restore(it) }
            EditorPort.MenuAction.REDO -> redoStack.removeLastOrNull()?.let { undoStack.add(Triple(text, selStart, selEnd)); restore(it) }
        }
        return true
    }
    /** Shift+←/→: mở rộng vùng chọn (neo = đầu kia) như ArrowKeyMovementMethod. */
    override fun sendKeyMeta(key: EditorPort.PortKey, shift: Boolean, ctrl: Boolean) {
        metaKeys.add(Triple(key, shift, ctrl))
        if (shift && !ctrl) when (key) {
            EditorPort.PortKey.LEFT -> if (selEnd > 0) selEnd--
            EditorPort.PortKey.RIGHT -> if (selEnd < sb.length) selEnd++
            else -> {}
        }
    }
}

class IcProxyTest {
    private val tracker = SelectionTracker()
    private fun proxy(ed: FakeEditor, reliable: Boolean = true): IcProxy {
        tracker.reset(ed.selStart, ed.selEnd)
        val p = IcProxy({ ed }, tracker)
        p.startInput(null, false)
        if (reliable) {                        // app đã báo một update khớp mốc
            p.begin(); p.insertText("x"); p.end()
            tracker.onUpdate(ed.selStart, ed.selEnd)
            p.begin(); p.deleteCodePoints(1); p.end()
            tracker.onUpdate(ed.selStart, ed.selEnd)
            assertTrue(tracker.reliable)
        }
        return p
    }
    private fun IcProxy.batch(f: IcProxy.() -> Unit) { begin(); try { f() } finally { end() } }

    // Mục 1: ⌫ / double-space không dùng KEYCODE_DEL bất đồng bộ.

    @Test fun deleteThenInsertSameBatchKeepsOrder() {
        val ed = FakeEditor("chữ ")
        val p = proxy(ed)
        p.batch { deleteBackward(); insertText(". ") }
        assertEquals("chữ. ", ed.text)
        assertTrue(ed.keys.isEmpty())
    }

    @Test fun backspaceDeletesWholeZwjEmoji() {
        val family = "👨‍👩‍👧"   // 👨‍👩‍👧
        val ed = FakeEditor("a$family")
        val p = proxy(ed)
        p.batch { deleteBackward() }
        assertEquals("a", ed.text)
        assertTrue(ed.keys.isEmpty())
    }

    @Test fun backspaceDeletesFlagAndSurrogate() {
        val ed = FakeEditor("x🇻🇳😀")          // 🇻🇳😀
        val p = proxy(ed)
        p.batch { deleteBackward() }
        assertEquals("x🇻🇳", ed.text)
        p.batch { deleteBackward() }
        assertEquals("x", ed.text)
    }

    @Test fun backspaceCombiningMark() {
        val ed = FakeEditor("aé")                                    // e + dấu sắc tổ hợp
        val p = proxy(ed)
        p.batch { deleteBackward() }
        assertEquals("a", ed.text)
    }

    @Test fun emptyFieldUsesKeyDel() {
        val ed = FakeEditor("")
        val p = proxy(ed, reliable = false)
        p.batch { deleteBackward() }
        assertEquals(listOf(EditorPort.PortKey.DEL), ed.keys)
    }

    @Test fun unreadableFieldUsesKeyDel() {
        val ed = FakeEditor("abc").also { it.readable = false }
        val p = proxy(ed, reliable = false)
        p.batch { deleteBackward() }
        assertEquals(listOf(EditorPort.PortKey.DEL), ed.keys)
        assertEquals("ab", ed.text)
    }

    @Test fun typeNullUsesKeyDel() {
        val ed = FakeEditor("abc")
        val p = proxy(ed).also { it.rawKeys = true }
        p.batch { deleteBackward() }
        assertEquals(listOf(EditorPort.PortKey.DEL), ed.keys)
    }

    @Test fun selectionDeletedByEmptyCommit() {
        val ed = FakeEditor("hello world")
        val p = proxy(ed)
        ed.selStart = 0; ed.selEnd = 5
        assertTrue(tracker.onUpdate(0, 5))
        p.invalidateShadow()
        p.batch { deleteBackward() }
        assertEquals(" world", ed.text)
        assertTrue(ed.keys.isEmpty())
        assertFalse(tracker.onUpdate(0, 0))     // mốc đúng: không phải đổi từ ngoài
    }

    // Mục 6: shadow giảm IPC.

    @Test fun shadowServesContextWithoutIpcWhenReliable() {
        val ed = FakeEditor("")
        val p = proxy(ed)
        p.contextBeforeInput()
        val r0 = ed.reads
        p.batch { insertText("xin"); insertText(" ") }
        assertEquals("xin ", p.contextBeforeInput())
        p.batch { deleteCodePoints(1); insertText(". ") }
        assertEquals("xin. ", p.contextBeforeInput())
        assertEquals(r0, ed.reads)
        p.invalidateShadow()                     // đổi từ ngoài
        ed.sb.insert(0, "A"); ed.selStart++; ed.selEnd++
        assertEquals("Axin. ", p.contextBeforeInput())
        assertEquals(r0 + 1, ed.reads)
    }

    /**
     * Đường CHẶT (⌫, confirmTail, sửa từ): tracker chưa tin ⇒ luôn đọc thật — kể cả khi shadow vừa nạp từ
     * chữ ban đầu của ô. Đổi 10/11/2026: chỉ AUTO-SHIFT được dùng chữ ban đầu ([contextForShift]).
     */
    @Test fun unreliableAlwaysReads() {
        val ed = FakeEditor("abc")
        val p = proxy(ed, reliable = false)
        p.contextBeforeInput(); p.contextBeforeInput()
        assertEquals(2, ed.reads)
        // Chữ ban đầu tin được (initialSel khớp) vẫn KHÔNG phục vụ đường chặt.
        val ed2 = FakeEditor("Chào. ")
        tracker.reset(6, 6)
        val p2 = IcProxy({ ed2 }, tracker)
        p2.startInput("Chào. ", atFieldStart = true)
        assertEquals("Chào. ", p2.contextBeforeInput())
        assertTrue(p2.confirmTail("o. "))
        assertEquals(2, ed2.reads)
    }

    /** Lần auto-shift đầu lúc hiện: chữ ban đầu (đã đối chiếu initialSel) ⇒ 0 lần đọc IPC. */
    @Test fun seededTextServesShiftWithoutReads() {
        val ed = FakeEditor("Chào. ")
        tracker.reset(6, 6)
        val p = IcProxy({ ed }, tracker)
        p.startInput("Chào. ", atFieldStart = true)
        assertEquals("Chào. ", p.contextForShift(allowRead = false))
        assertEquals("Chào. ", p.contextForShift(allowRead = true))   // đổi bảng phím trước khi gõ: vẫn 0 IPC
        assertEquals(0, ed.reads)
    }

    /** Chữ ban đầu hết hiệu lực sau edit đầu / đổi từ ngoài ⇒ về luật thường (đọc nếu được phép). */
    @Test fun seededTextExpiresOnEditOrExternalChange() {
        val ed = FakeEditor("Chào. ")
        tracker.reset(6, 6)
        val p = IcProxy({ ed }, tracker)
        p.startInput("Chào. ", atFieldStart = true)
        p.batch { insertText("x") }                    // tracker chưa nhận update khớp ⇒ chưa tin
        assertNull(p.contextForShift(allowRead = false))
        assertEquals("Chào. x", p.contextForShift(allowRead = true))
        assertEquals(1, ed.reads)

        val ed2 = FakeEditor("Chào. ")
        tracker.reset(6, 6)
        val p2 = IcProxy({ ed2 }, tracker)
        p2.startInput("Chào. ", atFieldStart = true)
        p2.invalidateShadow()                          // onUpdateSelection: đổi từ ngoài
        assertNull(p2.contextForShift(allowRead = false))
        assertEquals(0, ed2.reads)
    }

    /** Không có chữ ban đầu tin được (API < 30 / initialSel lệch): khung đầu không đọc, trả null. */
    @Test fun noSeedNoReadWhenReadsDisallowed() {
        val ed = FakeEditor("abc")
        val p = proxy(ed, reliable = false)
        assertNull(p.contextForShift(allowRead = false))
        assertEquals(0, ed.reads)
        assertEquals("abc", p.contextForShift(allowRead = true))
        assertEquals(1, ed.reads)
    }

    @Test fun initialTextSeedsShadow() {
        val ed = FakeEditor("Chào")
        tracker.reset(4, 4)
        val p = IcProxy({ ed }, tracker)
        p.startInput("Chào", atFieldStart = true)
        p.batch { insertText("x") }; tracker.onUpdate(5, 5)
        assertEquals("Chàox", p.contextBeforeInput())
        assertEquals(0, ed.reads)
    }

    @Test fun shadowTracksSurrogatesForWordDelete() {
        val ed = FakeEditor("")
        val p = proxy(ed)
        p.contextBeforeInput()
        p.batch { insertText("a 😀😀") }
        p.batch { deleteCodePoints(2) }                  // xoá theo từ: 2 code point = 4 UTF-16
        assertEquals("a ", ed.text)
        assertEquals("a ", p.contextBeforeInput())
        assertFalse(tracker.onUpdate(2, 2))
    }

    // Mục 2: fail-safe trước khi xoá.

    @Test fun confirmTailReadsWhenUnreliable() {
        val ed = FakeEditor("xin chao ")
        val p = proxy(ed, reliable = false)
        assertFalse(p.confirmTail("tie"))
        ed.sb.append("tie"); ed.selStart += 3; ed.selEnd = ed.selStart
        assertTrue(p.confirmTail("tie"))
        assertEquals(2, ed.reads)
    }

    @Test fun confirmTailUsesShadowWhenReliable() {
        val ed = FakeEditor("")
        val p = proxy(ed)
        p.contextBeforeInput()
        val r0 = ed.reads
        p.batch { insertText("tie") }
        assertTrue(p.confirmTail("tie"))
        assertEquals(r0, ed.reads)
    }

    @Test fun confirmTailUnreadableKeepsOldBehavior() {
        val ed = FakeEditor("abc").also { it.readable = false }
        assertTrue(proxy(ed, reliable = false).confirmTail("zz"))
    }

    // Mục 5: composing span sót.

    @Test fun finishComposingOnNextEditOnce() {
        val ed = FakeEditor("")
        val p = proxy(ed)
        p.finishComposingOnNextEdit()
        p.batch { insertText("a") }
        p.batch { insertText("b") }
        assertEquals(1, ed.finishComposingCalls)
    }

    // Mục 7: trackpad.

    @Test fun trackpadUsesSetSelectionWhenCursorKnown() {
        val ed = FakeEditor("ab😀cd")
        val p = proxy(ed)
        p.moveCursor(-3)                                // d, c, 😀
        assertEquals(2, ed.selStart)
        assertTrue(ed.keys.isEmpty())
        assertFalse(tracker.onUpdate(2, 2))
        p.moveCursor(1)                                 // qua 😀 (2 UTF-16)
        assertEquals(4, ed.selStart)
        assertFalse(tracker.onUpdate(4, 4))
        p.moveCursor(-10)                               // chặn ở đầu ô
        assertEquals(0, ed.selStart)
        p.moveCursor(-1)                                // đầu ô: không làm gì, không DPAD
        assertTrue(ed.keys.isEmpty())
    }

    @Test fun trackpadFallsBackToDpad() {
        val ed = FakeEditor("abc")
        val p = proxy(ed, reliable = false)
        p.moveCursor(-2)
        assertEquals(listOf(EditorPort.PortKey.LEFT, EditorPort.PortKey.LEFT), ed.keys)
        val ed2 = FakeEditor("abc")
        val p2 = proxy(ed2).also { it.uriField = true }
        p2.moveCursor(-1)
        assertEquals(listOf(EditorPort.PortKey.LEFT), ed2.keys)
        assertEquals(0, ed2.setSelections)
    }

    // Mục 7b: trackpad lên/xuống.

    @Test fun trackpadVerticalSingleLineFieldUsesNewlineSelection() {
        val ed = FakeEditor("abcdef\nxy\nabcdefgh")         // con trỏ cuối (dòng 3, cột 8)
        val p = proxy(ed)
        p.moveCursorVertical(-1)                             // dòng "xy" ngắn hơn ⇒ cuối dòng
        assertEquals(9, ed.selStart)
        assertTrue(ed.keys.isEmpty())
        assertFalse(tracker.onUpdate(9, 9))
        p.moveCursorVertical(-1)                             // cột 2 ở "abcdef"
        assertEquals(2, ed.selStart)
        assertFalse(tracker.onUpdate(2, 2))
        p.moveCursorVertical(-1)                             // dòng đầu: không làm gì
        assertEquals(2, ed.selStart)
        p.moveCursorVertical(2)                              // xuống 2 dòng, cột 2
        assertEquals(12, ed.selStart)
        assertTrue(ed.keys.isEmpty())
    }

    @Test fun trackpadVerticalMultiLineUsesDpadNeverEscapesFocus() {
        val ed = FakeEditor("ab\ncd\nef")
        val p = proxy(ed).also { it.multiLine = true }
        p.moveCursorVertical(-5)                             // 2 '\n' phía trên ⇒ tối đa 2 phím
        assertEquals(listOf(EditorPort.PortKey.UP, EditorPort.PortKey.UP), ed.keys)
        assertEquals(2, ed.selStart)
        p.moveCursorVertical(-1)                             // con trỏ chưa biết (chờ onUpdateSelection) ⇒ bỏ
        assertEquals(2, ed.keys.size)
        tracker.onUpdate(ed.selStart, ed.selEnd)
        p.moveCursorVertical(-3)                             // dòng đầu, chưa ở 0 ⇒ đúng 1 phím về 0
        assertEquals(0, ed.selStart)
        tracker.onUpdate(0, 0)
        p.moveCursorVertical(-1)                             // offset 0: không gửi DPAD
        assertEquals(3, ed.keys.size)
        assertEquals(0, ed.focusEscapes)
        p.moveCursorVertical(8)
        tracker.onUpdate(ed.selStart, ed.selEnd)
        p.moveCursorVertical(8)
        tracker.onUpdate(ed.selStart, ed.selEnd)
        p.moveCursorVertical(8)                              // cuối ô: dừng
        assertEquals(ed.text.length, ed.selStart)
        assertEquals(0, ed.focusEscapes)
    }

    @Test fun trackpadVerticalColumnZeroDoesNotOvershoot() {
        // Cột 0 dòng 2: phím UP thứ nhất về đúng offset 0 ⇒ phím thứ hai sẽ thoát focus.
        val ed = FakeEditor("ab\ncd", selStart = 3)
        val p = proxy(ed).also { it.multiLine = true }
        p.moveCursorVertical(-2)
        assertEquals(1, ed.keys.size)
        assertEquals(0, ed.focusEscapes)
    }

    @Test fun trackpadVerticalFallbacks() {
        val ed = FakeEditor("ab\ncd")
        val p = proxy(ed).also { it.rawKeys = true }         // TYPE_NULL: DPAD cho app
        p.moveCursorVertical(-2)
        assertEquals(listOf(EditorPort.PortKey.UP, EditorPort.PortKey.UP), ed.keys)
        val ed2 = FakeEditor("ab\ncd").also { it.readable = false }
        val p2 = proxy(ed2, reliable = false)               // con trỏ vẫn biết từ reset()
        p2.moveCursorVertical(1)                             // không đọc được: xuống không biết biên
        assertTrue(ed2.keys.isEmpty())
        p2.moveCursorVertical(-3)                            // lên: con trỏ > 0 ⇒ 1 phím
        assertEquals(listOf(EditorPort.PortKey.UP), ed2.keys)
        val ed3 = FakeEditor("ab\ncd")
        val p3 = proxy(ed3).also { it.uriField = true }
        p3.moveCursorVertical(-1)
        assertTrue(ed3.keys.isEmpty()); assertEquals(0, ed3.setSelections)
    }

    // Mục 8: giá trị trả về.

    @Test fun failedWriteReportsFailureAndForgetsCursor() {
        val ed = FakeEditor("abc")
        val p = proxy(ed)
        ed.failWrites = true
        p.batch { insertText("x") }
        assertTrue(p.takeFailure())
        assertFalse(p.takeFailure())
        assertEquals(-1, tracker.cursor)
        p.batch { deleteCodePoints(1) }
        assertTrue(p.takeFailure())
    }

    // Thuần.

    @Test fun graphemeHelpers() {
        assertEquals(0, Graphemes.lastLength(""))
        assertEquals(1, Graphemes.lastLength("ab"))
        assertEquals(2, Graphemes.lastLength("a😀"))
        assertEquals(4, Graphemes.unitsForward("🇻🇳x", 1))
        assertEquals(3, Graphemes.unitsBack("abc", 9))
    }

    @Test fun textShadowInvalidatesWhenTooShort() {
        val s = TextShadow(256)
        s.set("x".repeat(40), atFieldStart = false)
        s.deleted(20)                                  // còn 20 < 32, chưa tới đầu ô
        assertNull(s.text())
        s.set("abc", atFieldStart = true)
        s.deleted(5)
        assertEquals("", s.text())                     // ô trống thật
    }

    // WriteMode theo app (bảng WriteMode.forPackage) — regression 26/09/2026.
    private fun telexVieet(p: IcProxy) {
        p.begin(); p.insertText("vie"); p.end()
        p.begin(); p.deleteCodePoints(1); p.insertText("ê"); p.end()   // e→ê như engine
    }

    @Test fun delViaKeyEventForAppsIgnoringDeleteSurrounding() {
        val bad = FakeEditor().apply { ignoreDeletes = true }
        telexVieet(proxy(bad, reliable = false))
        assertEquals("vieê", bad.text)            // COMMIT: app nuốt lệnh xoá ⇒ nhân chữ

        val ed = FakeEditor().apply { ignoreDeletes = true }
        val p = proxy(ed, reliable = false).apply { writeMode = WriteMode.DEL_VIA_KEY_EVENT }
        telexVieet(p)
        assertEquals("viê", ed.text)
    }

    @Test fun keyOnlyForSandboxedApps() {
        val ed = FakeEditor().apply { ignoreCommits = true; ignoreDeletes = true }
        val p = proxy(ed, reliable = false).apply { writeMode = WriteMode.KEY_ONLY }
        telexVieet(p)
        assertEquals("viê", ed.text)
        p.begin(); p.deleteBackward(); p.end()
        assertEquals("vi", ed.text)
        assertTrue(p.confirmTail("không khớp"))   // key event trễ ⇒ không so đuôi
    }

    // Giữ lâu Enter: "\n" thật, không action, không KEYCODE_ENTER.

    @Test fun lineBreakCommitsNewlineWithoutAction() {
        val ed = FakeEditor("chào")
        val p = proxy(ed).apply { actionId = android.view.inputmethod.EditorInfo.IME_ACTION_SEND }
        p.batch { insertLineBreak() }
        assertEquals("chào\n", ed.text)
        assertTrue(ed.actions.isEmpty()); assertTrue(ed.keys.isEmpty())
        assertEquals("chào\n", p.contextBeforeInput())   // shadow/tracker theo kịp
        // Chạm Enter vẫn gửi action như cũ.
        p.batch { insertText("\n") }
        assertEquals(listOf(android.view.inputmethod.EditorInfo.IME_ACTION_SEND), ed.actions)
        assertEquals("chào\n", ed.text)
    }

    @Test fun lineBreakKeyOnlyGoesViaCharKeyEvent() {
        val ed = FakeEditor("a")
        val p = proxy(ed, reliable = false).apply { writeMode = WriteMode.KEY_ONLY; actionId = 4 }
        p.batch { insertLineBreak() }
        assertEquals("a\n", ed.text)
        assertTrue(ed.actions.isEmpty()); assertTrue(ed.keys.isEmpty())
    }

    @Test fun lineBreakAfterQueuedDelStaysInKeyQueue() {
        val ed = FakeEditor("ab")
        val p = proxy(ed, reliable = false).apply { writeMode = WriteMode.DEL_VIA_KEY_EVENT }
        p.batch { deleteBackward(); insertLineBreak() }
        assertEquals("a\n", ed.text)
        assertTrue(ed.actions.isEmpty())
    }

    @Test fun lineBreakRawKeysSendsEnter() {
        val ed = FakeEditor("$ ls")
        val p = proxy(ed).also { it.rawKeys = true }
        p.batch { insertLineBreak() }
        assertEquals(listOf(EditorPort.PortKey.ENTER), ed.keys)
        assertTrue(ed.actions.isEmpty())
    }
}
