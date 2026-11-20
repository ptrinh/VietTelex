package com.viettelex.android.ime

import com.viettelex.keyboard.FieldTraits
import com.viettelex.keyboard.Key
import com.viettelex.keyboard.KeyboardData
import com.viettelex.keyboard.KeyboardSession
import com.viettelex.keyboard.KeyboardSettings
import com.viettelex.keyboard.Keys
import com.viettelex.keyboard.SwipeChoice
import com.viettelex.keyboard.UserLangModel
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.BeforeClass
import org.junit.Test
import java.io.File
import java.io.RandomAccessFile
import java.nio.channels.FileChannel

/**
 * Gõ vuốt qua IcProxy THẬT + FakeEditor: huỷ chữ đầu, chèn từ vuốt, ⌫ đầu, phím dấu,
 * dấu câu — mọi edit của chính mình KHÔNG bị SelectionTracker coi là đổi từ ngoài.
 */
class SwipeTypingIcProxyTest {
    companion object {
        @BeforeClass @JvmStatic fun assets() {
            val dir = listOf(File("src/main/assets"), File("app/src/main/assets"), File("android/app/src/main/assets"))
                .first { File(it, Keys.ASSET_LEXICON).exists() }
            KeyboardData.install { name ->
                RandomAccessFile(File(dir, name), "r").use { f -> f.channel.map(FileChannel.MapMode.READ_ONLY, 0, f.length()) }
            }
        }
    }

    private val tracker = SelectionTracker()

    private fun setup(initial: String = ""): Triple<FakeEditor, IcProxy, KeyboardSession> {
        val ed = FakeEditor(initial)
        tracker.reset(ed.selStart, ed.selEnd)
        val p = IcProxy({ ed }, tracker).also { it.startInput(initial, true) }
        val s = KeyboardSession(UserLangModel(), null) { 0L }
        s.startInput(KeyboardSettings(swipeTyping = true), FieldTraits())
        s.setSwipeTyping(true)
        return Triple(ed, p, s)
    }

    /** Một thao tác trong batch; true nếu app báo selection KHÁC mốc (bị coi là đổi từ ngoài). */
    private fun op(p: IcProxy, ed: FakeEditor, f: () -> Unit): Boolean {
        p.begin(); try { f() } finally { p.end() }
        return tracker.onUpdate(ed.selStart, ed.selEnd)
    }

    /** Cú vuốt: chữ đầu hoãn tới lúc nhấc rồi bỏ (#172) ⇒ chỉ commitSwipe chạm ô. */
    private fun swipe(p: IcProxy, ed: FakeEditor, s: KeyboardSession, choice: SwipeChoice) {
        assertFalse(op(p, ed) { s.commitSwipe(choice, p) })
    }

    @Test fun swipeInSentenceThroughIcProxy() {
        val (ed, p, s) = setup("Hôm nay")
        swipe(p, ed, s, SwipeChoice("viết", listOf("việt", "biết")))
        assertEquals("Hôm nay viết", ed.text)
        assertFalse(op(p, ed) { s.handle(Key.Letter('j'), p) })     // phím dấu sửa từ vuốt
        assertEquals("Hôm nay việt", ed.text)
        assertFalse(op(p, ed) { s.handle(Key.Text("."), p) })        // dấu câu dính sát
        assertEquals("Hôm nay việt.", ed.text)
        swipe(p, ed, s, SwipeChoice("nam", emptyList()))
        assertEquals("Hôm nay việt. nam", ed.text)
    }

    @Test fun firstLetterTelexKeyUndoneAndBackspaceDeletesWord() {
        val (ed, p, s) = setup()
        for (c in "tieeng") op(p, ed) { s.handle(Key.Letter(c), p) }
        swipe(p, ed, s, SwipeChoice("sao", listOf("sào")))      // s đầu vuốt từng làm "tiếng"
        assertEquals("tiêng sao", ed.text)
        assertFalse(op(p, ed) { s.handle(Key.Backspace, p) })        // ⌫ đầu: cả từ vuốt
        assertEquals("tiêng ", ed.text)
        op(p, ed) { s.handle(Key.Backspace, p) }
        assertEquals("tiêng", ed.text)
    }

    @Test fun alternativeTapReplacesWord() {
        val (ed, p, s) = setup("a ")
        swipe(p, ed, s, SwipeChoice("co", listOf("cho", "có")))
        assertFalse(op(p, ed) { s.acceptSuggestion("cho", p) })
        assertEquals("a cho", ed.text)
        op(p, ed) { s.handle(Key.Space, p) }
        assertEquals("a cho ", ed.text)
    }
}
