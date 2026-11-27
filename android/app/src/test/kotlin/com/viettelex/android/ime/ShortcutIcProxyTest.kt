package com.viettelex.android.ime

import com.viettelex.keyboard.EngineBridge
import com.viettelex.keyboard.KeyboardSettings
import com.viettelex.keyboard.ShortcutTable
import com.viettelex.keyboard.WriteMode
import org.junit.Assert.assertEquals
import org.junit.Test

/** Gõ tắt qua IcProxy thật (FakeEditor): bung, ⌫ trả lại, ô đổi ngầm không xoá mù, KEY_ONLY. */
class ShortcutIcProxyTest {
    private val tracker = SelectionTracker()
    private val settings = KeyboardSettings(shortcuts = ShortcutTable(mapOf(
        "ko" to "không", "->" to "→", "sig" to "Thân mến,\nPhil")))

    private fun proxy(ed: FakeEditor): IcProxy {
        tracker.reset(ed.selStart, ed.selEnd)
        return IcProxy({ ed }, tracker).also { it.startInput(null, false) }
    }

    private fun key(p: IcProxy, ed: FakeEditor, f: () -> Unit) {
        p.begin(); try { f() } finally { p.end() }
        tracker.onUpdate(ed.selStart, ed.selEnd)
    }

    private fun type(keys: String, b: EngineBridge, p: IcProxy, ed: FakeEditor) {
        for (c in keys) key(p, ed) {
            when {
                c == '⌫' -> b.backspace(p)
                c.isLetter() -> b.letter(c, p)
                else -> b.boundary(c.toString(), p)
            }
        }
    }

    /** #182: Enter sau khi bung gõ tắt phải tới app SAU khi batch sửa đã đóng (ô Compose gom sửa tới endBatchEdit). */
    @Test fun enterAfterExpansionLeavesTheBatchFirst() {
        val ed = FakeEditor(); val p = proxy(ed); val b = EngineBridge(settings)
        type("Ko\n", b, p, ed)
        assertEquals("Không\n", ed.text)
        assertEquals(listOf(0), ed.depthAtNewline)
    }

    @Test fun expandAndUndoThroughIcProxy() {
        val ed = FakeEditor(); val p = proxy(ed); val b = EngineBridge(settings)
        type("Ko ", b, p, ed)
        assertEquals("Không ", ed.text)
        type("⌫", b, p, ed)
        assertEquals("Ko ", ed.text)
        type("a -> ", b, p, ed)
        assertEquals("Ko a → ", ed.text)
        type("sig ", b, p, ed)
        assertEquals("Ko a → Thân mến,\nPhil ", ed.text)
    }

    @Test fun editorChangedSilentlyNoBlindDelete() {
        val ed = FakeEditor(); val p = proxy(ed); val b = EngineBridge(settings)
        type("ko", b, p, ed)
        tracker.reset(-1, -1)                           // chưa tin shadow ⇒ IcProxy đọc thật
        ed.sb.setLength(0); ed.sb.append("xyz"); ed.selStart = 3; ed.selEnd = 3
        type(" ", b, p, ed)
        assertEquals("xyz ", ed.text)
    }

    @Test fun keyOnlyAppStillExpands() {
        val ed = FakeEditor().apply { ignoreCommits = true; ignoreDeletes = true }
        tracker.reset(-1, -1)
        val p = IcProxy({ ed }, tracker).also { it.startInput(null, false); it.writeMode = WriteMode.KEY_ONLY }
        val b = EngineBridge(settings)
        type("ko ", b, p, ed)
        assertEquals("không ", ed.text)
    }
}
