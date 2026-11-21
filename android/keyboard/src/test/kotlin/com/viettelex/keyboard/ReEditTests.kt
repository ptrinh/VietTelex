package com.viettelex.keyboard

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/** Sửa dấu từ đã gõ xong: ⌫ mở lại từ vừa chốt, phím dấu nạp lại từ trước con trỏ. */
class ReEditTests {
    @Before fun setUp() = TestAssets.install()

    private fun session(model: UserLangModel = UserLangModel(), traits: FieldTraits = FieldTraits(),
                        settings: KeyboardSettings = KeyboardSettings()) =
        KeyboardSession(model).also { it.startInput(settings, traits) }

    private fun KeyboardSession.typeKeys(p: TextProxy, keys: String) {
        for (c in keys) handle(when (c) {
            ' ' -> Key.Space
            '<' -> Key.Backspace
            '\n' -> Key.Newline
            '.' -> Key.Text(".")
            else -> Key.Letter(c)
        }, p)
    }

    // MARK: ⌫ mở lại từ

    @Test fun backspaceReopensLastWord() {
        val s = session(); val p = MockProxy()
        s.typeKeys(p, "thays ")
        assertEquals("tháy ", p.text)
        s.typeKeys(p, "<")
        assertEquals("tháy", p.text)
        assertTrue(s.bridge.isComposing)
        s.typeKeys(p, "a")
        assertEquals("thấy", p.text)
        s.typeKeys(p, " ")
        assertEquals("thấy ", p.text)
    }

    @Test fun backspaceReopensAfterPunctuation() {
        val s = session(); val p = MockProxy()
        s.typeKeys(p, "xin chao.<f")
        assertEquals("xin chào", p.text)
    }

    @Test fun reopenMidSentenceKeepsEarlierText() {
        val s = session(); val p = MockProxy()
        s.typeKeys(p, "toi thays <a ")
        assertEquals("toi thấy ", p.text)
    }

    @Test fun screenMismatchDoesNotEdit() {
        val s = session(); val p = MockProxy()
        s.typeKeys(p, "thays ")
        // App tự sửa chữ mà không báo selection.
        p.sb.setLength(0); p.sb.append("khác ")
        s.typeKeys(p, "<")
        assertEquals("khác", p.text)          // ⌫ thường
        assertFalse(s.bridge.isComposing)
        s.typeKeys(p, "n")
        assertEquals("khácn", p.text)
    }

    @Test fun boundaryMissingOnScreenDoesNotEdit() {
        val s = session(); val p = MockProxy()
        s.typeKeys(p, "thays ")
        p.sb.setLength(p.sb.length - 1)       // app nuốt space
        s.typeKeys(p, "<")
        assertEquals("thá", p.text)           // ⌫ thường, không mở lại
        assertFalse(s.bridge.isComposing)
    }

    @Test fun selectionPreventsReopenAndForgets() {
        val s = session(); val p = MockProxy()
        s.typeKeys(p, "thays ")
        p.selection = true
        s.typeKeys(p, "<")
        assertFalse(s.bridge.isComposing)
        p.selection = false
        // Snapshot đã bỏ: ⌫ tiếp không được hồi sinh từ cũ.
        s.typeKeys(p, "<")
        assertFalse(s.bridge.isComposing)
    }

    @Test fun fieldWithoutReEditIsPlainBackspace() {
        val s = session(); val p = MockProxy().also { it.reEdit = false }
        s.typeKeys(p, "thays <a")
        assertEquals("tháya", p.text)
    }

    /** #148: thanh địa chỉ (ô URI — canReEdit false, canReopen true): "go␣⌫s" phải ra "gó". */
    @Test fun uriFieldReopensButDoesNotSeed() {
        val s = session(traits = FieldTraits(urlField = true))
        val p = MockProxy().also { it.reEdit = false; it.reopen = true }
        s.typeKeys(p, "go <s")
        assertEquals("gó", p.text)
        // Seed (phím dấu sau từ có sẵn, không phải từ mình vừa chốt) vẫn TẮT ở ô URI.
        val s2 = session(traits = FieldTraits(urlField = true))
        val p2 = MockProxy().also { it.reEdit = false; it.reopen = true; it.sb.append("viet") }
        s2.typeKeys(p2, "j")
        assertEquals("vietj", p2.text)
    }

    /** Ô URI có tự hoàn tất dạng vùng chọn ngay lúc ⌫: không mở lại (⌫ chỉ làm việc của nó). */
    @Test fun uriFieldSelectionBlocksReopen() {
        val s = session(traits = FieldTraits(urlField = true))
        val p = MockProxy().also { it.reEdit = false; it.reopen = true }
        s.typeKeys(p, "go ")
        p.selection = true
        s.typeKeys(p, "<")
        assertFalse(s.bridge.isComposing)
    }

    @Test fun passthroughFieldIsPlain() {
        val s = session(traits = FieldTraits(passthrough = true)); val p = MockProxy()
        s.typeKeys(p, "thays <a")
        assertEquals("thaysa", p.text)
    }

    @Test fun newlineForgetsLastWord() {
        val s = session(); val p = MockProxy()
        s.typeKeys(p, "thays\n<")
        assertFalse(s.bridge.isComposing)
    }

    @Test fun externalSelectionChangeForgets() {
        val s = session(); val p = MockProxy()
        s.typeKeys(p, "thays ")
        s.externalSelectionChange()
        s.typeKeys(p, "<")
        assertFalse(s.bridge.isComposing)
    }

    /** Khôi phục KHÔNG đổi gì trên màn hình (eager restore đã hiện "google" từ phím thứ 4):
     *  chữ trên màn hình đúng là chữ engine giữ ⇒ ⌫ mở lại từ như mọi từ khác (07/11/2026,
     *  = TelexCore testNoOpRestoreIsReopenable); gõ tiếp vẫn ra chữ thô. */
    @Test fun noOpRestoredWordIsReopened() {
        val s = session(); val p = MockProxy()
        s.typeKeys(p, "google ")
        assertEquals("google ", p.text)
        s.typeKeys(p, "<")
        assertEquals("google", p.text)
        assertTrue(s.bridge.isComposing)
        s.typeKeys(p, "s ")
        assertEquals("googles ", p.text)
    }

    /** Từ chưa có dấu mà engine "khôi phục" y nguyên ("hoc"): ⌫ rồi thêm dấu vẫn sửa được từ đó. */
    @Test fun noOpRestoreThenToneEditsTheWord() {
        val s = session(); val p = MockProxy()
        s.typeKeys(p, "hoc <j")
        assertEquals("học", p.text)
    }

    // MARK: nạp lại từ trước con trỏ

    @Test fun seedAddsToneToWordBeforeCursor() {
        val s = session(); val p = MockProxy()
        p.sb.append("viêt")
        s.typeKeys(p, "j")
        assertEquals("việt", p.text)
        s.typeKeys(p, " ")
        assertEquals("việt ", p.text)
    }

    /** Giống hệt gõ liền "vietj" (Telex: j đặt nặng, không tự thêm mũ). */
    @Test fun seedMatchesFreshTyping() {
        val fresh = MockProxy()
        session().typeKeys(fresh, "vietj")
        val s = session(); val p = MockProxy()
        p.sb.append("viet")
        s.typeKeys(p, "j")
        assertEquals(fresh.text, p.text)
        assertEquals("viẹt", p.text)
    }

    @Test fun seedHornButNotDoubledVowel() {
        // a/e/o/d KHÔNG nạp lại (user 26/09/2026): con trỏ sau "to" gõ o = "too", không "tô".
        run { val s = session(); val p = MockProxy(); p.sb.append("ban to"); s.typeKeys(p, "o"); assertEquals("ban too", p.text) }
        run { val s = session(); val p = MockProxy(); p.sb.append("co"); s.typeKeys(p, "d"); assertEquals("cod", p.text) }
        run { val s = session(); val p = MockProxy(); p.sb.append("tu"); s.typeKeys(p, "w"); assertEquals("tư", p.text) }
        run { val s = session(); val p = MockProxy(); p.sb.append("việt"); s.typeKeys(p, "z"); assertEquals("viêt", p.text) }
    }

    /** Issue #169: `d` dính liền sau từ bắt đầu bằng d gạch đ; sau dấu cách vẫn mở từ mới. */
    @Test fun strokeKeyEditsGluedWordStartingWithD() {
        fun glued(word: String, keys: String, settings: KeyboardSettings = KeyboardSettings()): String {
            val s = session(settings = settings); val p = MockProxy(); p.sb.append(word)
            s.typeKeys(p, keys); return p.text
        }
        assertEquals("đùng", glued("dùng", "d"))
        assertEquals("đúng", glued("dùng", "ds"))
        assertEquals("Đung", glued("Dung", "d"))
        assertEquals("cod", glued("co", "d"))
        assertEquals("band", glued("ban", "d"))
        assertEquals("đúngd", glued("đúng", "d"))
        assertEquals("dùngd", glued("dùng", "d", KeyboardSettings(vniMode = true)))
        assertEquals("dùng đi", glued("dùng ", "ddi"))
    }

    /**
     * Issue #169 (báo lại sau bản sửa đầu): "Bỏ dấu tự do" TẮT thì engine không với `d` cuối từ
     * về chữ d đầu — phím d dính liền vẫn phải gạch đ, cả khi con trỏ đứng sau từ có sẵn lẫn
     * khi từ vừa được ⌫ mở lại.
     */
    @Test fun strokeKeyEditsGluedWordWithFreeMarkingOff() {
        for (spell in listOf(true, false)) {
            val st = KeyboardSettings(freeMarking = false, liveSpellCheck = spell)
            fun glued(word: String, keys: String): String {
                val s = session(settings = st); val p = MockProxy(); p.sb.append(word)
                s.typeKeys(p, keys); return p.text
            }
            assertEquals("đùng", glued("dùng", "d"))
            assertEquals("đúng", glued("dùng", "ds"))
            assertEquals("đường", glued("dường", "d"))
            // `w` khi sửa từ đã gõ xong cũng với ngược qua phụ âm cuối (chế độ chặt).
            assertEquals("đứng", glued("dùng", "dws"))
            assertEquals("dưng", glued("dung", "w"))
            assertEquals("trăng", glued("trang", "w"))
            assertEquals("đường", glued("duong", "dwf"))
            assertEquals("trăng", glued("", "trang <w"))
            assertEquals("trangw", glued("", "trangw"))      // gõ liền mạch: w cuối vẫn là chữ
            assertEquals("Đung", glued("Dung", "d"))
            assertEquals("band", glued("ban", "d"))
            assertEquals("đúngd", glued("đúng", "d"))
            assertEquals("đúng", glued("", "dungf <ds"))     // ⌫ mở lại từ rồi d s
            assertEquals("dad", glued("", "dad"))            // gõ liền mạch: d cuối vẫn là chữ
        }
    }

    @Test fun midWordIsLiteral() {
        val s = session(); val p = MockProxy()
        p.sb.append("viet"); p.after = "nam"
        s.typeKeys(p, "j")
        assertEquals("vietj", p.text)
    }

    @Test fun unreadableAfterIsLiteral() {
        val s = session(); val p = MockProxy()
        p.sb.append("viet"); p.after = null
        s.typeKeys(p, "j")
        assertEquals("vietj", p.text)
    }

    @Test fun nonTransformKeyIsLiteral() {
        val s = session(); val p = MockProxy()
        p.sb.append("viet")
        s.typeKeys(p, "n")
        assertEquals("vietn", p.text)
    }

    @Test fun keyThatDoesNotTransformIsLiteral() {
        val s = session(); val p = MockProxy()
        p.sb.append("ban")                    // "band": d không có gì để lặp
        s.typeKeys(p, "d")
        assertEquals("band", p.text)
    }

    @Test fun seedSkipsGluedTokens() {
        for (ctx in listOf("mp3a", "gmail.com", "a_viet")) {
            val s = session(); val p = MockProxy()
            p.sb.append(ctx)
            s.typeKeys(p, "s")
            assertEquals(ctx + "s", p.text)
        }
    }

    @Test fun seedSkippedWithSelectionOrWithoutReEdit() {
        run { val s = session(); val p = MockProxy(); p.sb.append("viet"); p.selection = true
            s.typeKeys(p, "j"); assertEquals("vietj", p.text) }
        run { val s = session(); val p = MockProxy().also { it.reEdit = false }; p.sb.append("viet")
            s.typeKeys(p, "j"); assertEquals("vietj", p.text) }
        run { val s = session(traits = FieldTraits(passthrough = true)); val p = MockProxy(); p.sb.append("viet")
            s.typeKeys(p, "j"); assertEquals("vietj", p.text) }
    }

    @Test fun nullContextIsLiteral() {
        val s = session()
        val p = object : TextProxy {
            val sb = StringBuilder("viet")
            override val isSecure = false
            override fun insertText(text: String) { sb.append(text) }
            override fun deleteCodePoints(count: Int) { repeat(count) { sb.setLength(sb.length - 1) } }
            override fun deleteBackward() = deleteCodePoints(1)
            override fun contextBeforeInput(): String? = null
            override val canReEdit = true
            override fun contextAfterInput() = ""
        }
        s.handle(Key.Letter('j'), p)
        assertEquals("vietj", p.sb.toString())
    }

    // MARK: học từ

    @Test fun reopenAndRecommitLearnsOnce() {
        val m = UserLangModel(); val s = session(m); val p = MockProxy()
        val base = m.count("việt")
        s.typeKeys(p, "vieetj ")
        assertEquals(base + 1, m.count("việt"))
        s.typeKeys(p, "< ")
        assertEquals("việt ", p.text)
        assertEquals(base + 1, m.count("việt"))
    }

    @Test fun correctedWordReplacesWrongLearning() {
        val m = UserLangModel(); val s = session(m); val p = MockProxy()
        val wrong = m.count("tháy"); val right = m.count("thấy")
        s.typeKeys(p, "thays ")
        assertEquals(wrong + 1, m.count("tháy"))
        s.typeKeys(p, "<a ")
        assertEquals("thấy ", p.text)
        assertEquals(wrong, m.count("tháy"))
        assertEquals(right + 1, m.count("thấy"))
    }

    @Test fun reopenKeepsBigramContext() {
        val m = UserLangModel(); val s = session(m); val p = MockProxy()
        val base = m.count("chào")
        s.typeKeys(p, "xin chaof ")
        repeat(3) { s.typeKeys(p, "< ") }     // mở lại "chào" rồi chốt lại, 3 lần
        assertEquals("xin chào ", p.text)
        assertEquals(base + 1, m.count("chào"))
        // Ngữ cảnh khôi phục đúng "xin": bigram xin→chào vẫn còn.
        assertTrue("chào" in m.nextWords("xin", null, 24))
    }

    @Test fun retractRemovesCounts() {
        val m = UserLangModel()
        val l = m.record("việt", null)
        assertTrue(l != null)
        m.retract(l!!)
        assertEquals(0, m.count("việt"))
        assertNull(m.record("a1", null))      // không learnable ⇒ không biên nhận
    }

    @Test fun toggleOffDisablesReopenAndSeed() {
        val off = KeyboardSettings(reEditWords = false)
        run {   // ⌫ sau dấu cách chỉ xoá dấu cách, a gõ thành chữ mới
            val s = session(settings = off); val p = MockProxy()
            s.typeKeys(p, "thays <a"); assertEquals("tháya", p.text)
        }
        run {
            val s = session(settings = off); val p = MockProxy(); p.sb.append("xin chao")
            s.typeKeys(p, "f"); assertEquals("xin chaof", p.text)
        }
        assertTrue(KeyboardSettings().reEditWords)   // mặc định BẬT
    }
}
