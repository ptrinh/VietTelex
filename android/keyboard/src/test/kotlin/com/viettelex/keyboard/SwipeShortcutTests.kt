package com.viettelex.keyboard

import java.io.File
import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertSame
import kotlin.test.assertTrue

/**
 * Gõ tắt trong gõ vuốt (10/2026): khoá gõ tắt thuần chữ vuốt được (chèn nội dung bung như gõ khoá +
 * dấu cách, ⌫ đầu trả lại khoá), từ của nội dung ngắn (≤ 3 từ) vào từ vựng vuốt đúng hoa/thường.
 * Song sinh iOS SwipeShortcutTests.swift; fixture CHUNG iOS/KeyboardTests/Fixtures/swipe-shortcuts.tsv.
 */
class SwipeShortcutTests {
    @org.junit.Before fun setUp() = TestAssets.install()
    @AfterTest fun reset() { SwipeVocab.setShortcuts(null) }

    private class Fixture {
        val table = LinkedHashMap<String, String>()
        val entries = ArrayList<Pair<String, Int>>()
        val swipes = ArrayList<Triple<String, SwipeSuggest.Case, String>>()
    }

    private fun fixture(): Fixture {
        val f = listOf("../../iOS", "../iOS", "iOS").map { File(it, "KeyboardTests/Fixtures/swipe-shortcuts.tsv") }
            .firstOrNull { it.exists() } ?: error("không thấy iOS/KeyboardTests/Fixtures/swipe-shortcuts.tsv")
        val out = Fixture()
        var section = ""
        for (line in f.readLines()) {
            if (line.startsWith("#") || line.isEmpty()) continue
            if (line.startsWith("[")) { section = line; continue }
            val c = line.split("\t")
            when (section) {
                "[table]" -> out.table[c[0]] = c[1]
                "[entries]" -> out.entries.add(c[0] to c[1].toInt())
                "[swipe]" -> out.swipes.add(Triple(c[0], when (c[1]) {
                    "upper" -> SwipeSuggest.Case.ALL; "capitalized" -> SwipeSuggest.Case.FIRST; else -> SwipeSuggest.Case.LOWER
                }, c[2]))
            }
        }
        return out
    }

    private fun bigTable(): Map<String, String> {
        val big = LinkedHashMap<String, String>()
        var i = 0
        for (a in 'a'..'z') for (b in 'a'..'z') { big["q$a$b"] = "Xyzq${i++}" }
        return big
    }

    @Test fun entriesMatchSharedFixture() {
        val f = fixture()
        val got = SwipeVocab.shortcutEntries(ShortcutTable(f.table))
        assertEquals(f.entries.map { it.first }, got.map { it.word })
        assertEquals(f.entries.map { it.second }, got.map { it.freq })
    }

    @Test fun capAndNoChangeNoRebuild() {
        assertEquals(SwipeVocab.SHORTCUT_CAP, SwipeVocab.shortcutEntries(ShortcutTable(bigTable())).size)
        val t = ShortcutTable(mapOf("vn" to "Việt Nam"))
        assertTrue(SwipeVocab.setShortcuts(t))
        val v = SwipeVocab.current
        assertFalse(SwipeVocab.setShortcuts(t), "bảng không đổi ⇒ không dựng lại")
        assertSame(v, SwipeVocab.current)
        assertTrue(v.indexOf("vn") >= 0)
        assertTrue(SwipeVocab.setShortcuts(null))
        assertTrue(SwipeVocab.current.indexOf("vn") < 0, "tắt Gõ tắt ⇒ khoá không vuốt được nữa")
    }

    private val layout = SwipeLayout.qwerty(keyWidth = 36f, rowHeight = 54f)
    private val decoder = SwipeDecoder().also { it.setLayout(layout) }

    private fun session(table: Map<String, String>, enabled: Boolean = true,
                        traits: FieldTraits = FieldTraits()): KeyboardSession {
        val s = KeyboardSession(UserLangModel(), null) { 0L }
        s.startInput(KeyboardSettings(swipeTyping = true, shortcutsEnabled = enabled,
            shortcuts = ShortcutTable(table)), traits)
        s.setSwipeTyping(true)
        return s
    }

    private fun KeyboardSession.swipeR(p: TextProxy, word: String, case: SwipeSuggest.Case = SwipeSuggest.Case.LOWER): SwipeChoice {
        val path = SwipeSim(7).path(word, layout, sigma = 0.0, jitter = 0.0)
        val ctx = swipeContext()
        val cands = decoder.decode(path, SwipeSuggest.TOP_K, ctx.folded, ctx.english, if (ctx.english != null) ctx.englishWord else null)
        val r = resolveSwipe(cands, ctx, case)
        assertNotNull(r, word)
        commitSwipe(r, p)
        return r.choice
    }

    @Test fun swipesFromSharedFixture() {
        val f = fixture()
        for ((w, case, want) in f.swipes) {
            val s = session(f.table); val p = MockProxy()
            s.swipeR(p, w, case)
            assertEquals(want, p.text, "$w $case")
        }
    }

    @Test fun backspaceRestoresKeyAndAlternativeKeepsKey() {
        val table = mapOf("vn" to "Việt Nam")
        val s = session(table); val p = MockProxy()
        for (c in "yeeu ") s.handle(if (c == ' ') Key.Space else Key.Letter(c), p)
        s.swipeR(p, "vn")
        assertEquals("yêu Việt Nam", p.text)
        assertEquals("vn", s.swipeAlternatives?.firstOrNull(), "khoá đứng đầu phương án")
        s.handle(Key.Backspace, p)                         // như hoàn tác gõ tắt gõ tay
        assertEquals("yêu vn", p.text)
        s.handle(Key.Space, p)                             // không bung lại
        assertEquals("yêu vn ", p.text)
        // chọn phương án "vn" trên thanh: thay nguyên văn
        val s2 = session(table); val p2 = MockProxy()
        s2.swipeR(p2, "vn")
        s2.acceptSuggestion("vn", p2)
        assertEquals("vn", p2.text)
        s2.handle(Key.Backspace, p2)                       // phương án đã chọn: ⌫ đầu xoá cả từ, không trả khoá
        assertEquals("", p2.text)
    }

    @Test fun shortcutsOffOrFieldDisallowedInsertsKeyNotExpansion() {
        val table = mapOf("vn" to "Việt Nam")
        val off = EngineBridge(KeyboardSettings(shortcutsEnabled = false, shortcuts = ShortcutTable(table)))
        assertNull(off.swipeShortcutExpansion("vn"))
        // tắt Gõ tắt ⇒ startInput bỏ khoá khỏi từ vựng vuốt
        session(table, enabled = false)
        assertTrue(SwipeVocab.current.indexOf("vn") < 0)
        val url = EngineBridge(KeyboardSettings(shortcuts = ShortcutTable(table))).also { it.shortcutsAllowed = false }
        assertNull(url.swipeShortcutExpansion("vn"))
        assertNull(EngineBridge(KeyboardSettings(shortcuts = ShortcutTable(mapOf("k2" to "x")))).swipeShortcutExpansion("k2"))
        val on = EngineBridge(KeyboardSettings(shortcuts = ShortcutTable(table)))
        assertEquals("Việt Nam", on.swipeShortcutExpansion("Vn"))
        assertEquals("VIỆT NAM", on.swipeShortcutExpansion("VN"))
    }

    /** Bộ nhớ template: thêm tới [SwipeVocab.SHORTCUT_CAP] dạng từ bảng gõ tắt (in số đo để báo cáo). */
    @Test fun templateMemoryDelta() {
        val d = SwipeDecoder().also { it.setLayout(layout) }
        SwipeVocab.setShortcuts(null)
        d.prepare()
        val before = d.templateBytes
        SwipeVocab.setShortcuts(ShortcutTable(bigTable()))
        d.prepare()
        val after = d.templateBytes
        println("SWIPE-SHORTCUTS: templates $before → $after B (+${after - before} B cho ${SwipeVocab.SHORTCUT_CAP} mục)")
        assertTrue(after > before)
        assertTrue(after - before < 300_000)
    }
}
