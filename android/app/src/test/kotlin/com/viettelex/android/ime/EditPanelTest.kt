package com.viettelex.android.ime

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Bảng sửa văn bản (27/09/2026): lưới, hàm thuần đầu/cuối dòng + chọn từ, lệnh trên FakeEditor. */
class EditPanelTest {
    private val tracker = SelectionTracker()

    private fun proxy(ed: FakeEditor, reliable: Boolean = true): IcProxy {
        tracker.reset(ed.selStart, ed.selEnd)
        val p = IcProxy({ ed }, tracker)
        p.startInput(null, false)
        if (reliable) {
            p.begin(); p.insertText("x"); p.end(); tracker.onUpdate(ed.selStart, ed.selEnd)
            p.begin(); p.deleteCodePoints(1); p.end(); tracker.onUpdate(ed.selStart, ed.selEnd)
            assertTrue(tracker.reliable)
        }
        return p
    }

    private fun run(p: IcProxy, a: EditAction, selecting: Boolean = false): Boolean {
        p.begin()
        try { return EditCommands.run(a, selecting, p, tracker) } finally { p.end() }
    }

    // MARK: lưới

    @Test fun gridHasEveryActionOnce() {
        val all = EditPanel.GRID.flatten()
        assertEquals(EditAction.values().toSet(), all.toSet())
        assertEquals(all.size, all.toSet().size)
        assertTrue(EditPanel.GRID.all { it.size == 4 })
    }

    @Test fun gridBuildsEditKeysInsideSpanWithOneHand() {
        val keys = KeyLayout.build(LayoutConfig(Plane.EDIT, 390f, 224f, 1f, oneHand = OneHandSide.LEFT))
        assertEquals(16, keys.size)
        assertTrue(keys.all { it.kind == KeyKind.EDIT && EditAction.of(it.insert) != null })
        assertTrue(keys.all { it.right <= 390f * OneHand.RATIO + 0.01f })
        // Router tới đúng ô (plane không phải chữ: vùng nở).
        for (k in keys) assertEquals(k, KeyLayout.hit(keys, Plane.EDIT, k.centerX, k.centerY, 4f, 1f))
    }

    private val nTools = com.viettelex.keyboard.TextTool.entries.size + 1   // + "Thêm dấu"

    /** Nối công cụ văn bản: editTools ⇒ các hàng công cụ (TextTool…, Thêm dấu) dưới lưới 4×4, chạm = TOOL:id. */
    @Test fun toolsRowWhenTextToolsUnlocked() {
        val keys = KeyLayout.build(LayoutConfig(Plane.EDIT, 390f, 280f, 1f, oneHand = OneHandSide.RIGHT, editTools = true))
        assertEquals(16 + nTools, keys.size)
        val tools = keys.filter { EditPanel.toolOf(it.insert) != null }
        assertEquals(com.viettelex.keyboard.TextTool.entries, tools.map { EditPanel.toolOf(it.insert) })
        assertEquals(1, keys.count { it.insert == EditPanel.ADD_TONES_INSERT })
        val gridBottom = keys.filter { EditAction.of(it.insert) != null }.maxOf { it.bottom }
        assertTrue(keys.filter { EditPanel.isToolCell(it.insert) }.all { it.top >= gridBottom && it.bottom <= 280f + 0.01f })
        assertTrue(keys.all { it.left >= 390f * (1 - OneHand.RATIO) - 0.01f })
        for (k in keys) assertEquals(k, KeyLayout.hit(keys, Plane.EDIT, k.centerX, k.centerY, 4f, 1f))
        assertEquals(null, EditPanel.toolOf("LEFT"))
        assertEquals(null, EditAction.of(tools.first().insert))
        // Khoá ⇒ lưới 4×4 như cũ.
        assertEquals(16, KeyLayout.build(LayoutConfig(Plane.EDIT, 390f, 280f, 1f)).size)
    }

    /** Dịch trên máy: ô "Dịch" cuối hàng công cụ; chỉ bật dịch ⇒ một hàng một ô phủ kín. */
    @Test fun translateCellOnToolsRow() {
        val both = KeyLayout.build(LayoutConfig(Plane.EDIT, 390f, 280f, 1f, editTools = true, editTranslate = true))
        assertEquals(16 + nTools + 1, both.size)
        val tr = both.single { it.insert == EditPanel.TRANSLATE_INSERT }
        assertEquals(null, EditPanel.toolOf(tr.insert)); assertEquals(null, EditAction.of(tr.insert))
        assertTrue(EditPanel.isToolCell(tr.insert))
        assertEquals(both.filter { it.top == tr.top }.maxOf { it.right }, tr.right)
        for (k in both) assertEquals(k, KeyLayout.hit(both, Plane.EDIT, k.centerX, k.centerY, 4f, 1f))
        val only = KeyLayout.build(LayoutConfig(Plane.EDIT, 390f, 280f, 1f, editTranslate = true))
        assertEquals(17, only.size)
        val t = only.single { it.insert == EditPanel.TRANSLATE_INSERT }
        assertEquals(3f, t.left, 0.01f); assertEquals(387f, t.right, 0.01f)
    }

    /**
     * Tester 11/2026 ("cho người OCD"): mọi hàng cùng cao, cùng khe, phủ đúng bề ngang; hàng công
     * cụ đầy thì THẲNG cột với lưới 4×4; không ô trống / nhãn rỗng (trừ icon ⌫); tổng chiều cao
     * không vượt vùng phím.
     */
    @Test fun allRowsAlignedNoEmptyCells() {
        for ((tools, trans) in listOf(true to false, true to true, false to true, false to false)) {
            val W = 390f; val H = 224f
            val keys = KeyLayout.build(LayoutConfig(Plane.EDIT, W, H, 1f, editTools = tools, editTranslate = trans))
            val rows = keys.groupBy { it.top }.toSortedMap().values.toList()
            val nCells = EditPanel.toolCells(tools, trans).size
            assertEquals(4 + EditPanel.rowSizes(nCells, EditPanel.COLS).size, rows.size)
            val h = rows.first().first().height
            val gap = KeyLayout.KEY_SPACING
            val colEdges = rows.first().map { it.left to it.right }
            for (row in rows) {
                assertTrue(row.all { kotlin.math.abs(it.height - h) < 0.01f })
                assertEquals(KeyLayout.ROW_MARGIN_H, row.first().left, 0.01f)
                assertEquals(W - KeyLayout.ROW_MARGIN_H, row.last().right, 0.01f)
                for (i in 1 until row.size) assertEquals(gap, row[i].left - row[i - 1].right, 0.01f)
                val w0 = row.first().width
                assertTrue(row.all { kotlin.math.abs(it.width - w0) < 0.01f })
                if (row.size == EditPanel.COLS) assertEquals(colEdges, row.map { it.left to it.right })
                assertTrue(row.all { it.label.isNotEmpty() || it.insert == EditAction.DELETE.name })
            }
            assertTrue(keys.maxOf { it.bottom } <= H + 0.01f)
            // khe dọc đều
            val tops = rows.map { it.first().top }
            for (i in 2 until tops.size) assertEquals(tops[1] - tops[0], tops[i] - tops[i - 1], 0.01f)
        }
    }

    @Test fun toolCellsOrderAndNames() {
        val labels = EditPanel.toolCells(true, true).map { it.first }
        assertEquals(listOf("HOA", "thường", "Hoa đầu từ", "Hoa đầu câu", "Xoá dấu", "Thêm dấu", "Dịch").map { com.viettelex.keyboard.tr(it) }, labels)
        assertEquals(listOf(4, 3), EditPanel.rowSizes(7, 4))
        assertEquals(listOf(4, 2), EditPanel.rowSizes(6, 4))
        assertEquals(emptyList<Int>(), EditPanel.rowSizes(0, 4))
    }

    // MARK: hàm thuần

    @Test fun lineStartAndEnd() {
        assertEquals(5, EditOps.lineStartBack("hello"))
        assertEquals(3, EditOps.lineStartBack("ab\ncde"))
        assertEquals(0, EditOps.lineStartBack("ab\n"))
        assertEquals(2, EditOps.lineStartBack("x\r\nyz"))            // \r\n một ngắt
        assertEquals(4, EditOps.lineEndForward("tail"))
        assertEquals(2, EditOps.lineEndForward("ab\ncd"))
        assertEquals(0, EditOps.lineEndForward("\nx"))
        assertEquals(1, EditOps.lineEndForward("a b"))
    }

    @Test fun wordAroundCursor() {
        // "xin chà|o bạn" ⇒ cả "chào"
        assertEquals(-3 to 1, EditOps.wordAround("xin chà", "o bạn"))
        // sát cuối từ
        assertEquals(-3 to 0, EditOps.wordAround("xin bạn", " nhé"))
        // sát đầu từ
        assertEquals(0 to 3, EditOps.wordAround("xin ", "bạn"))
        // giữa khoảng trắng ⇒ từ ngay trước
        assertEquals(-6 to -2, EditOps.wordAround("xin chào  ", ""))
        assertEquals(-5 to -2, EditOps.wordAround("xin bạn, ", ""))
        assertEquals(0 to 2, EditOps.wordAround("xin bạn, ", "ok"))
        // tiếng Việt NFD (dấu kết hợp) vẫn là một từ
        val nfd = "việt"
        assertEquals(-nfd.length to 0, EditOps.wordAround(nfd, ""))
        assertNull(EditOps.wordAround("", ""))
        assertNull(EditOps.wordAround("  ", "  "))
    }

    // MARK: lệnh trên FakeEditor

    @Test fun arrowsReuseTrackpadMovement() {
        val ed = FakeEditor("ab\ncd")
        val p = proxy(ed)
        run(p, EditAction.LEFT)
        assertEquals(4 to 4, ed.selStart to ed.selEnd)
        tracker.onUpdate(4, 4)
        run(p, EditAction.RIGHT)
        assertEquals(5, ed.selStart)
        tracker.onUpdate(5, 5)
        run(p, EditAction.UP)                         // ô một dòng có '\n' ⇒ setSelection cùng cột
        assertEquals(2, ed.selStart)
        assertTrue(ed.keys.isEmpty())                 // không DPAD khi biết chắc con trỏ
    }

    @Test fun lineStartEndBySetSelection() {
        val ed = FakeEditor("một\nhai ba", selStart = 6)
        val p = proxy(ed)
        run(p, EditAction.LINE_END)
        assertEquals(10 to 10, ed.selStart to ed.selEnd)
        tracker.onUpdate(10, 10)
        run(p, EditAction.LINE_START)
        assertEquals(4, ed.selStart)
        assertTrue(ed.metaKeys.isEmpty() && ed.keys.isEmpty())
    }

    @Test fun lineStartFallsBackToHomeKeyWhenCursorUnknown() {
        val ed = FakeEditor("abc")
        val p = proxy(ed, reliable = false)
        run(p, EditAction.LINE_START)
        assertEquals(listOf(EditorPort.PortKey.HOME), ed.keys)
    }

    @Test fun selectingModeUsesShiftArrows() {
        val ed = FakeEditor("xin chào")
        val p = proxy(ed)
        run(p, EditAction.LEFT, selecting = true)
        run(p, EditAction.LEFT, selecting = true)
        assertEquals("ào", ed.text.substring(minOf(ed.selStart, ed.selEnd), maxOf(ed.selStart, ed.selEnd)))
        run(p, EditAction.LINE_START, selecting = true)
        assertEquals(Triple(EditorPort.PortKey.HOME, true, false), ed.metaKeys.last())
        assertEquals(-1, tracker.cursor)              // con trỏ không biết cho tới onUpdateSelection
    }

    @Test fun selectWordSelectsAndTrackerKnowsItsOwn() {
        val ed = FakeEditor("xin chào bạn", selStart = 6)
        val p = proxy(ed)
        assertTrue(run(p, EditAction.SELECT_WORD))
        assertEquals(4 to 8, ed.selStart to ed.selEnd)
        assertFalse(tracker.onUpdate(4, 8))           // selection của mình ≠ đổi từ ngoài
    }

    @Test fun copyCutPasteSelectAllViaContextMenu() {
        val ed = FakeEditor("xin chào bạn", selStart = 6)
        val p = proxy(ed)
        run(p, EditAction.SELECT_WORD)
        run(p, EditAction.COPY)
        assertEquals("chào", ed.clipboard)
        assertEquals("xin chào bạn", ed.text)
        run(p, EditAction.CUT)
        assertEquals("xin  bạn", ed.text)
        run(p, EditAction.PASTE)
        assertEquals("xin chào bạn", ed.text)
        run(p, EditAction.SELECT_ALL)
        assertEquals(0 to ed.text.length, ed.selStart to ed.selEnd)
        assertEquals(listOf(EditorPort.MenuAction.COPY, EditorPort.MenuAction.CUT, EditorPort.MenuAction.PASTE,
            EditorPort.MenuAction.SELECT_ALL), ed.menus)
        assertTrue(ed.metaKeys.isEmpty())
    }

    @Test fun undoRedoViaMenuThenCtrlZFallback() {
        val ed = FakeEditor("abc", selStart = 0, selEnd = 3)
        val p = proxy(ed, reliable = false)
        run(p, EditAction.CUT)
        assertEquals("", ed.text)
        run(p, EditAction.UNDO)
        assertEquals("abc", ed.text)
        run(p, EditAction.REDO)
        assertEquals("", ed.text)
        // Ô không có menu hoàn tác (Chrome): Ctrl+Z / Ctrl+Shift+Z.
        ed.undoMenuSupported = false
        run(p, EditAction.UNDO)
        run(p, EditAction.REDO)
        assertEquals(listOf(Triple(EditorPort.PortKey.Z, false, true), Triple(EditorPort.PortKey.Z, true, true)),
            ed.metaKeys)
    }

    @Test fun menuUnsupportedFallsBackToShortcuts() {
        val ed = FakeEditor("abc")
        ed.menuSupported = false
        val p = proxy(ed)
        run(p, EditAction.SELECT_ALL); run(p, EditAction.COPY); run(p, EditAction.CUT); run(p, EditAction.PASTE)
        assertEquals(listOf(EditorPort.PortKey.A, EditorPort.PortKey.C, EditorPort.PortKey.X, EditorPort.PortKey.V),
            ed.metaKeys.map { it.first })
        assertTrue(ed.metaKeys.all { it.third && !it.second })
    }

    @Test fun viewSideActionsAreNotRunHere() {
        val ed = FakeEditor("abc")
        val p = proxy(ed)
        for (a in listOf(EditAction.SELECT, EditAction.DELETE, EditAction.CLOSE)) assertFalse(run(p, a))
        assertEquals("abc", ed.text)
    }

    // MARK: lệnh vuốt phím trên ô gom lệnh trong batch (#179)

    /**
     * Ô kiểu Compose: lệnh xoá trong batch chỉ áp ở endBatch; lệnh menu áp NGAY trên chữ hiện có
     * rồi khởi động lại phiên nhập ⇒ lệnh đang gom bị bỏ.
     */
    private class BufferingPort(val ed: FakeEditor) : EditorPort by ed {
        private var depth = 0
        private val queued = ArrayList<Int>()
        override fun beginBatch() { depth++ }
        override fun endBatch() { if (--depth == 0) { queued.forEach { ed.deleteCodePointsBefore(it) }; queued.clear() } }
        override fun deleteCodePointsBefore(count: Int): Boolean {
            if (depth > 0) { queued.add(count); return true }
            return ed.deleteCodePointsBefore(count)
        }
        override fun menuAction(action: EditorPort.MenuAction): Boolean { queued.clear(); return ed.menuAction(action) }
    }

    @Test fun keyCommandRemovesItsLetterBeforePastingInABufferingField() {
        val ed = FakeEditor("Xin v").also { it.clipboard = "chào" }
        tracker.reset(ed.selStart, ed.selEnd)
        val port = BufferingPort(ed)
        val p = IcProxy({ port }, tracker)
        p.startInput(null, false)
        assertTrue(KeyCommands.run(com.viettelex.keyboard.KeyCommand.PASTE, p, tracker) { p.deleteCodePoints(1) })
        assertEquals("Xin chào", ed.text)   // trước đây: "Xin vchào" — lệnh xoá chữ "v" bị bỏ
    }

    @Test fun keyCommandNeedingSelectionOnlySettlesWithoutOne() {
        val ed = FakeEditor("Xin c")
        tracker.reset(ed.selStart, ed.selEnd)
        val p = IcProxy({ BufferingPort(ed) }, tracker)
        p.startInput(null, false)
        assertTrue(KeyCommands.run(com.viettelex.keyboard.KeyCommand.COPY, p, tracker) { p.deleteCodePoints(1) })
        assertEquals("Xin ", ed.text)
        assertTrue(ed.menus.isEmpty())
    }
}
