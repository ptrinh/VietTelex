package com.viettelex.keyboard

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/** Tích hợp gõ vuốt — phần thuần: phân loại cử chỉ, huỷ chữ đầu, luồng session. */
class SwipeTypingTests {
    @Before fun setUp() = TestAssets.install()

    // ---- GestureClassifier (dp, ms) ----

    /** Phím 35×50 dp ở (0,0); bề rộng phím 35 dp. */
    private fun classifier(x: Float = 17f, y: Float = 25f, since: Long = Long.MAX_VALUE) =
        GestureClassifier().also { it.begin(x, y, 0L, 0f, 0f, 35f, 50f, 35f, since) }

    /** Trượt thẳng (dx, dy) trong [ms], mẫu mỗi 8 ms; trả trạng thái cuối. */
    private fun GestureClassifier.slide(dx: Float, dy: Float, ms: Long, x0: Float = 17f, y0: Float = 25f,
                                        t0: Long = 0L): GestureClassifier.State {
        var s = state
        var t = 8L
        while (t <= ms) {
            val f = t.toFloat() / ms
            s = move(x0 + dx * f, y0 + dy * f, t0 + t)
            t += 8
        }
        return s
    }

    @Test fun quickTapWithSlideIsNotSwipe() {
        for (d in listOf(5f, 10f, 15f)) {
            // giữa phím, trượt ngang/chéo 5–15 dp nhanh
            assertNotEquals(GestureClassifier.State.SWIPE, classifier().slide(d, 0f, 60))
            assertNotEquals(GestureClassifier.State.SWIPE, classifier().slide(d, d, 40))
            // sát mép phím: ra khỏi phím nhưng chưa đủ 1 bề rộng phím
            assertNotEquals(GestureClassifier.State.SWIPE, classifier(x = 30f).slide(d, 0f, 50, x0 = 30f))
        }
    }

    @Test fun secondFingerLocksTap() {
        val c = classifier()
        c.move(20f, 25f, 8)
        c.pointerAdded()
        assertEquals(GestureClassifier.State.TAP, c.state)
        assertEquals(GestureClassifier.State.TAP, c.slide(120f, 0f, 200, t0 = 16))
    }

    @Test fun swipeRightAfterTapIsSuppressed() {
        // 100 ms sau phím trước: ngưỡng ×2.43 ⇒ kéo 2 phím (70 dp) chưa thành vuốt
        assertNotEquals(GestureClassifier.State.SWIPE, classifier(since = 100).slide(70f, 0f, 120))
        // cùng cử chỉ khi không vừa gõ ⇒ vuốt
        assertEquals(GestureClassifier.State.SWIPE, classifier().slide(70f, 0f, 120))
        val c = GestureClassifier()
        assertEquals(3f, c.factorAfterTyping(0), 1e-4f)
        assertEquals(1f, c.factorAfterTyping(350), 1e-4f)
        assertTrue(c.factorAfterTyping(100) > c.factorAfterTyping(200))
    }

    @Test fun realSwipeIsSwipe() {
        assertEquals(GestureClassifier.State.SWIPE, classifier().slide(60f, 10f, 150))
        // lên hàng trên (ra khỏi phím theo trục dọc)
        assertEquals(GestureClassifier.State.SWIPE, classifier().slide(20f, -45f, 120))
    }

    @Test fun slowDragLocksTapAfterTimeout() {
        val c = classifier()
        // 0.05 dp/ms: sau 500 ms mới đi 25 dp — khoá chạm, đi xa hơn cũng không thành vuốt
        assertEquals(GestureClassifier.State.TAP, c.slide(40f, 0f, 800))
    }

    // ---- EngineBridge.undoLastLetter ----

    private fun bridge() = EngineBridge().also { it.trackLetterUndo = true }

    @Test fun undoTelexKeyRestoresWordAndEngine() {
        val b = bridge(); val p = MockProxy()
        for (c in "tieng") b.letter(c, p)
        b.letter('s', p)
        assertEquals("tiéng", p.text)
        assertTrue(b.undoLastLetter(p))           // "tieng" + s huỷ về "tieng"
        assertEquals("tieng", p.text)
        assertEquals("tieng", b.composedWord)
        assertEquals("tieng", b.rawWord)          // engine trở về ĐÚNG trước phím s
        b.letter('f', p)
        assertEquals("tièng", p.text)
        val b2 = bridge(); val p2 = MockProxy()
        for (c in "tieeng") b2.letter(c, p2)
        b2.letter('s', p2)
        assertEquals("tiếng", p2.text)
        assertTrue(b2.undoLastLetter(p2))
        assertEquals("tiêng", p2.text)
        b2.letter('s', p2)
        assertEquals("tiếng", p2.text)            // KHÔNG "tiến#" như khi dùng ⌫
    }

    @Test fun undoPlainLetterAndCircumflex() {
        val b = bridge(); val p = MockProxy()
        for (c in "tie") b.letter(c, p)
        b.letter('e', p)                         // tie + e → tiê (xoá e, chèn ê)
        assertEquals("tiê", p.text)
        assertTrue(b.undoLastLetter(p))
        assertEquals("tie", p.text); assertEquals("tie", b.composedWord)
        b.letter('v', p)
        assertTrue(b.undoLastLetter(p))
        assertEquals("tie", p.text)
    }

    @Test fun undoRefusesWhenContextChanged() {
        val b = bridge(); val p = MockProxy()
        for (c in "tieng") b.letter(c, p)
        b.letter('s', p)
        p.sb.setLength(0); p.sb.append("khác")   // ô đổi mà không được báo
        assertFalse(b.undoLastLetter(p))
        assertEquals("khác", p.text)
    }

    @Test fun undoOnlyOnceAndOnlyRightAfterLetter() {
        val b = bridge(); val p = MockProxy()
        b.letter('a', p)
        assertTrue(b.undoLastLetter(p))
        assertFalse(b.undoLastLetter(p))
        b.letter('a', p); b.boundary(" ", p)
        assertFalse(b.undoLastLetter(p))
        b.letter('b', p); b.backspace(p)
        assertFalse(b.undoLastLetter(p))
        val off = EngineBridge(); off.letter('a', p)
        assertFalse(off.undoLastLetter(p))      // tắt ⇒ không checkpoint
    }

    @Test fun undoReEditSeedRestoresScreen() {
        val b = bridge(); val p = MockProxy()
        p.sb.append("chao")                       // từ có sẵn, con trỏ cuối từ
        b.letter('f', p)                          // seed lại từ ⇒ chào
        assertEquals("chào", p.text)
        assertTrue(b.undoLastLetter(p))
        assertEquals("chao", p.text)
        assertFalse(b.isComposing)
    }

    // ---- luồng session ----

    private val layout = SwipeLayout.qwerty(keyWidth = 36f, rowHeight = 54f)
    private val decoder = SwipeDecoder().also { it.setLayout(layout) }

    private fun session(traits: FieldTraits = FieldTraits()): KeyboardSession {
        val s = KeyboardSession(UserLangModel(), null) { 0L }
        s.startInput(KeyboardSettings(), traits)
        s.setSwipeTyping(true)
        return s
    }

    private fun KeyboardSession.type(p: TextProxy, keys: String) {
        for (c in keys) handle(when (c) { ' ' -> Key.Space; ',', '.' -> Key.Text(c.toString()); else -> Key.Letter(c) }, p)
    }

    /** Chạm xuống chữ đầu (hoãn, chưa chèn — #172) → thành vuốt (bỏ) → nhấc tay (decode + chèn). */
    private fun KeyboardSession.swipe(p: TextProxy, word: String, case: SwipeSuggest.Case = SwipeSuggest.Case.LOWER): SwipeChoice {
        val path = SwipeSim(7).path(word, layout, sigma = 0.0, jitter = 0.0)
        val ctx = swipeContext()
        // như IME: ctx.english != null ⇒ thêm ứng viên tiếng Anh
        val cands = decoder.decode(path, SwipeSuggest.TOP_K, ctx.folded, ctx.english, if (ctx.english != null) ctx.englishWord else null)
        val choice = SwipeSuggest.choose(cands, ctx.word, case)
        assertNotNull(choice)
        commitSwipe(choice!!, p)
        return choice
    }

    /**
     * ONBOARDING-SPEC §7 + gõ vuốt: từ vuốt còn mở là từ từ điển (phím gốc là phím tổng hợp,
     * không phải phím người dùng gõ) ⇒ vuốt phím cách KHÔNG chuyển từ, chốt nguyên như cũ.
     */
    @Test fun spaceFlickKeepsOpenSwipeWord() {
        val s = KeyboardSession(UserLangModel(), null) { 0L }
        s.startInput(KeyboardSettings(spaceSwipeLanguage = true), FieldTraits())
        s.setSwipeTyping(true)
        val p = MockProxy()
        s.restoreLanguage(null, p)
        s.swipe(p, "viet")
        val shown = p.text
        assertEquals(KeyboardLanguage.EN, s.toggleLanguage(p))
        assertEquals(shown, p.text)
        assertFalse(s.bridge.isComposing)
        assertTrue(s.bridge.englishMode)
    }

    @Test fun swipeInSentenceSpacesAndPunctuation() {
        val s = session(); val p = MockProxy()
        s.type(p, "baif")                         // đang soạn "bài"
        s.swipe(p, "viet")
        assertEquals("bài viết", p.text)          // từ đang soạn được chốt + dấu cách treo
        s.type(p, ",")
        assertEquals("bài viết,", p.text)         // dấu câu dính sát
        s.swipe(p, "nam")
        assertTrue(p.text, p.text.startsWith("bài viết, n"))
        s.type(p, " ")
        s.swipe(p, "rat")
        assertFalse(p.text, p.text.contains("  "))   // sau space của user: không thêm space
    }

    // ---- tiền nghiệm liên tục ngôn ngữ (SwipeLangContext.prior(kinds)) ----

    @Test fun languageContinuityTheAfterEnglishWords() {
        // đang gõ tiếng Anh ⇒ vuốt "the" ra "the" (tiếng Anh), kể cả qua dấu chấm câu
        run {
            val s = session(); val p = MockProxy()
            s.type(p, "i like big ")
            val c = s.swipe(p, "the")
            assertTrue(c.toString(), c.english); assertEquals("the", c.word)
        }
        run {
            val s = session(); val p = MockProxy()
            s.type(p, "i like big. ")                   // sang câu mới: ngữ cảnh LM mất, ngôn ngữ còn
            val c = s.swipe(p, "the")
            assertTrue(c.toString(), c.english); assertEquals("the", c.word)
            s.externalSelectionChange()                 // con trỏ nhảy ⇒ quên mạch
            s.type(p, " ")
            val d = s.swipe(p, "the")
            assertFalse(d.toString(), d.english)
        }
    }

    @Test fun languageContinuityTheAfterVietnameseWords() {
        val s = session(); val p = MockProxy()
        s.type(p, "vis duj nhuw ")
        assertEquals("ví dụ như ", p.text)
        val c = s.swipe(p, "the")
        assertFalse(c.toString(), c.english); assertEquals("thế", c.word)
        assertTrue(c.toString(), "the" in c.englishAlternatives)       // phương án Anh vẫn trên thanh
        // chen MỘT từ Anh giữa câu Việt vẫn ra (nét không trùng từ Việt nào)
        val s2 = session(); val p2 = MockProxy()
        s2.type(p2, "minhf ddang ")
        val m = s2.swipe(p2, "check")
        assertTrue(m.toString(), m.english); assertEquals("check", m.word)
    }

    @Test fun swipeAtFieldStartAndAfterNewlineNoLeadingSpace() {
        val s = session(); val p = MockProxy()
        val c = s.swipe(p, "viet", SwipeSuggest.Case.FIRST)
        assertEquals("Viết", c.word)
        assertEquals("Viết", p.text)
        p.sb.setLength(0); p.sb.append("a\n"); s.externalSelectionChange()
        s.swipe(p, "viet")
        assertEquals("a\nviết", p.text)
    }

    @Test fun firstLetterUndoneCleanlyEvenTelexKey() {
        val s = session(); val p = MockProxy()
        s.type(p, "tieng")
        s.swipe(p, "sao")                         // chạm s ⇒ "tiếng" rồi huỷ
        assertTrue(p.text, p.text.startsWith("tieng "))
        assertFalse(p.text.contains("tiếng"))
        assertEquals(1, p.text.count { it == ' ' })
    }

    @Test fun firstBackspaceDeletesWholeSwipedWord() {
        val s = session(); val p = MockProxy()
        s.type(p, "baif ")
        s.swipe(p, "viet")
        assertEquals("bài viết", p.text)
        s.handle(Key.Backspace, p)
        assertEquals("bài ", p.text)
        s.handle(Key.Backspace, p)                // sau đó ⌫ như thường
        assertEquals("bài", p.text)
    }

    @Test fun telexKeyAfterSwipeChangesTone() {
        val s = session(); val p = MockProxy()
        s.swipe(p, "viet")
        assertEquals("viết", p.text)
        s.handle(Key.Letter('j'), p)              // phím dấu Telex sửa từ vuốt
        assertEquals("việt", p.text)
        s.handle(Key.Backspace, p)                // không còn là từ vuốt ⇒ ⌫ engine thường
        assertNotEquals("", p.text)
    }

    @Test fun alternativesReplaceAndLearnOnCommit() {
        val s = session(); val p = MockProxy()
        s.swipe(p, "viet")
        val alts = s.swipeAlternatives!!
        assertTrue(alts.toString(), "việt" in alts)
        assertEquals(alts, s.suggestionsNow(p)!!.nextWords)
        s.acceptSuggestion("việt", p)
        assertEquals("việt", p.text)
        assertTrue("viết" in s.swipeAlternatives!!)  // đổi lại được
        s.handle(Key.Backspace, p)                   // vẫn là từ vuốt: ⌫ xoá cả từ
        assertEquals("", p.text)
        s.swipe(p, "viet")
        s.acceptSuggestion("việt", p)
        s.type(p, " ")
        assertEquals("việt ", p.text)
        assertTrue(s.langModel.count("việt") > 0)
        assertNull(s.swipeAlternatives)
    }

    // ---- sửa lại từ vuốt trước (ngữ cảnh hai phía, SwipeRevise) ----

    /** Như [swipe] nhưng đi đường IME thật: resolveSwipe (có sửa lại từ trước) → commitSwipe. */
    private fun KeyboardSession.swipeR(p: TextProxy, word: String, case: SwipeSuggest.Case = SwipeSuggest.Case.LOWER): SwipeChoice {
        val path = SwipeSim(7).path(word, layout, sigma = 0.0, jitter = 0.0)
        val ctx = swipeContext()
        val cands = decoder.decode(path, SwipeSuggest.TOP_K, ctx.folded, ctx.english, if (ctx.english != null) ctx.englishWord else null)
        val r = resolveSwipe(cands, ctx, case)!!
        commitSwipe(r, p)
        return r.choice
    }

    @Test fun nextSwipeRevisesPreviousAndOffersUndo() {
        val s = session(); val p = MockProxy()
        s.swipeR(p, "co")
        assertEquals("có", p.text)                    // một mình: "có"
        s.swipeR(p, "gang")
        assertEquals("cố gắng", p.text)               // biết từ kế ⇒ sửa "cố", từ kế chọn lại theo "cố"
        assertTrue(s.langModel.count("cố") > 0)
        val set = s.suggestionsNow(p)!!
        assertEquals("↩\uFE0E có", set.actionLabel)
        assertEquals(SuggestionSet.UNDO_REVISE_TOKEN, set.action)
        val before = s.langModel.count("cố")
        s.acceptSuggestion(SuggestionSet.UNDO_REVISE_TOKEN, p)
        assertEquals("có gắng", p.text)
        assertTrue(s.langModel.count("cố") < before)  // rút lượt học từ mới
        assertNull(s.suggestionsNow(p)!!.action)      // hoàn tác một lần
        s.type(p, " ")
        assertEquals("có gắng ", p.text)
    }

    @Test fun revisionKeepsCaseAndOnlyOnce() {
        val s = session(); val p = MockProxy()
        s.swipeR(p, "co", SwipeSuggest.Case.FIRST)
        s.swipeR(p, "gang")
        assertEquals("Cố gắng", p.text)
        s.swipeR(p, "len")                             // "Cố" đã chốt: không bị sửa lần nữa
        assertTrue(p.text, p.text.startsWith("Cố gắng "))
    }

    /** Vuốt "ngay" đầu câu ra "Này" (n-a-y ≈ n-g-a-y); "mai" kế ⇒ "Ngày mai", chip ↩︎ trả "Này". */
    @Test fun nayRevisedToNgayMaiAtSentenceStart() {
        val s = session(); val p = MockProxy()
        s.swipeR(p, "ngay", SwipeSuggest.Case.FIRST)
        assertEquals("Này", p.text)
        s.swipeR(p, "mai")
        assertEquals("Ngày mai", p.text)
        assertEquals("↩︎ Này", s.suggestionsNow(p)!!.actionLabel)
        s.acceptSuggestion(SuggestionSet.UNDO_REVISE_TOKEN, p)
        assertEquals("Này mai", p.text)
    }

    @Test fun noRevisionAfterUserEditOrChoice() {
        // phím dấu Telex sửa từ vuốt ⇒ không còn nguyên ⇒ không sửa lại
        run {
            val s = session(); val p = MockProxy()
            s.swipeR(p, "co")
            s.handle(Key.Letter('f'), p)               // có → cò
            assertEquals("cò", p.text)
            s.swipeR(p, "gang")
            assertTrue(p.text, p.text.startsWith("cò "))
        }
        // chọn phương án trên thanh gợi ý ⇒ user đã quyết
        run {
            val s = session(); val p = MockProxy()
            s.swipeR(p, "co")
            val alt = s.swipeAlternatives!!.first { it != "cố" }
            s.acceptSuggestion(alt, p)
            s.swipeR(p, "gang")
            assertTrue(p.text, p.text.startsWith("$alt "))
        }
        // con trỏ dời (selection đổi từ ngoài) ⇒ quên
        run {
            val s = session(); val p = MockProxy()
            s.swipeR(p, "co")
            s.externalSelectionChange()
            s.swipeR(p, "gang")
            assertTrue(p.text, p.text.startsWith("có "))
        }
    }

    @Test fun revisionFailSafeWhenScreenDiffers() {
        val s = session(); val p = MockProxy()
        s.swipeR(p, "co")
        val path = SwipeSim(7).path("gang", layout, sigma = 0.0, jitter = 0.0)
        val ctx = s.swipeContext()
        val r = s.resolveSwipe(decoder.decode(path, SwipeSuggest.TOP_K, ctx.folded, ctx.english, ctx.englishWord), ctx)!!
        assertEquals("cố", r.revisedPrev)
        p.sb.setLength(0); p.sb.append("xco")          // host sửa chữ sau lưng
        s.commitSwipe(r, p)
        assertFalse(p.text, p.text.contains("cố"))     // đuôi lệch ⇒ không đụng
    }

    // ---- sửa lại từ vuốt khi từ kế GÕ PHÍM (SwipeRevise.reviseTyped) ----

    @Test fun typedNextWordRevisesPreviousAndOffersUndo() {
        val s = session(); val p = MockProxy()
        s.swipeR(p, "co")
        s.type(p, " gawngs")
        assertEquals("có gắng", p.text)               // chưa chốt từ gõ ⇒ chưa đụng
        val coLearned = s.langModel.count("có")
        s.type(p, " ")
        assertEquals("cố gắng ", p.text)               // chốt "gắng" ⇒ sửa "cố", từ gõ + dấu cách y nguyên
        val coiLearned = s.langModel.count("cố")
        assertTrue(coiLearned > 0)
        assertTrue(s.langModel.count("có") < coLearned) // rút lượt học từ cũ
        val set = s.suggestionsNow(p)!!
        assertEquals("↩\uFE0E có", set.actionLabel)
        assertEquals(SuggestionSet.UNDO_REVISE_TOKEN, set.action)
        s.acceptSuggestion(SuggestionSet.UNDO_REVISE_TOKEN, p)
        assertEquals("có gắng ", p.text)
        assertTrue(s.langModel.count("cố") < coiLearned)
        assertTrue(s.langModel.count("có") >= coLearned)
        assertTrue(s.langModel.count("gắng") > 0)
        assertNull(s.suggestionsNow(p)!!.action)       // hoàn tác một lần
        s.type(p, "laf")
        assertEquals("có gắng là", p.text)
    }

    @Test fun typedRevisionPunctuationCaseAndBackspaceInWord() {
        run {                                           // dấu câu chốt từ gõ; chữ hoa giữ
            val s = session(); val p = MockProxy()
            s.swipeR(p, "co", SwipeSuggest.Case.FIRST)
            s.type(p, " gawngs,")
            assertEquals("Cố gắng,", p.text)
        }
        run {                                           // ⌫ trong từ gõ vẫn được
            val s = session(); val p = MockProxy()
            s.swipeR(p, "co")
            s.type(p, " gawngsk")
            s.handle(Key.Backspace, p)
            s.type(p, " ")
            assertEquals("cố gắng ", p.text)
        }
        run {                                           // chip sống tới phím kế
            val s = session(); val p = MockProxy()
            s.swipeR(p, "co")
            s.type(p, " gawngs ")
            s.type(p, "l")
            assertNull(s.suggestionsNow(p)?.action?.takeIf { it == SuggestionSet.UNDO_REVISE_TOKEN })
        }
    }

    @Test fun typedRevisionGuards() {
        fun check(msg: String, expected: String, body: (KeyboardSession, MockProxy) -> Unit) {
            val s = session(); val p = MockProxy()
            s.swipeR(p, "co")
            body(s, p)
            assertEquals(msg, expected, p.text)
        }
        check("phím dấu sửa từ vuốt", "cò gắng ") { s, p -> s.type(p, "f gawngs ") }
        check("đã chọn phương án", "") { s, p ->
            val alt = s.swipeAlternatives!!.first { it != "cố" }
            s.acceptSuggestion(alt, p); s.type(p, " gawngs ")
            assertEquals("$alt gắng ", p.text); p.sb.setLength(0)
        }
        check("con trỏ dời", "có gắng ") { s, p -> s.type(p, " "); s.externalSelectionChange(); s.type(p, "gawngs ") }
        check("⌫ ngoài từ gõ", "có gắng ") { s, p -> s.type(p, " a"); s.handle(Key.Backspace, p); s.handle(Key.Backspace, p); s.type(p, " gawngs ") }
        check("chỉ từ gõ NGAY SAU", "có thể gắng ") { s, p -> s.type(p, " theer gawngs ") }
        check("dấu câu ngay sau từ vuốt", "có, gắng ") { s, p -> s.type(p, ", gawngs ") }
        check("host sửa chữ sau lưng", "xcó gắng ") { s, p -> s.type(p, " gawngs"); p.sb.insert(0, 'x'); s.type(p, " ") }
        // tắt gõ vuốt ⇒ không chờ gì
        val s = session(); val p = MockProxy()
        s.swipeR(p, "co"); s.setSwipeTyping(false)
        s.type(p, " gawngs ")
        assertEquals("có gắng ", p.text)
    }

    @Test fun swipeAfterSwipeCommitsAndLearnsFirst() {
        val s = session(); val p = MockProxy()
        s.swipe(p, "viet")
        s.swipe(p, "nam")
        assertTrue(p.text, p.text.startsWith("viết n"))
        assertTrue(s.langModel.count("viết") > 0)
    }

    // ---- giai đoạn 3: từ tiếng Anh ----

    @Test fun collisionAfterVietnameseStaysVietnameseWithEnglishAlternative() {
        val s = session(); val p = MockProxy()
        s.type(p, "tooi ")
        val c = s.swipe(p, "the")
        assertFalse(c.english)
        // dạng Việt "the" (dấu nào do tần suất/ngữ cảnh — thế/thể)
        assertEquals("the", SwipeSuggest.fold(c.word)); assertNotEquals("the", c.word)
        assertTrue(c.toString(), "the" in c.alternatives && "the" in c.englishAlternatives)
        assertEquals("tôi " + c.word, p.text)
        // chọn "the" trên thanh gợi ý ⇒ tiếng Anh nguyên văn, "thế" thành phương án
        s.acceptSuggestion("the", p)
        assertEquals("tôi the", p.text)
        assertTrue(s.swipeWordIsEnglish)
        assertTrue(c.word in s.swipeAlternatives!!)
    }

    @Test fun englishRunCheckMail() {
        val s = session(); val p = MockProxy()
        s.type(p, "minhf ddang ")
        val c1 = s.swipe(p, "check")
        assertTrue(c1.toString(), c1.english)
        assertEquals("mình đang check", p.text)
        assertTrue(s.swipeWordIsEnglish)
        assertTrue(c1.alternatives.any { it !in c1.englishAlternatives })   // phương án Việt
        val c2 = s.swipe(p, "mail")
        assertTrue(c2.toString(), c2.english)
        assertEquals("mình đang check mail", p.text)
        assertTrue(s.langModel.count("check") > 0)                          // chốt ⇒ học
        s.type(p, " ")
        assertTrue(s.langModel.count("mail") > 0)
        assertEquals("mình đang check mail ", p.text)
    }

    @Test fun englishWordBackspaceLetterAndCase() {
        val s = session(); val p = MockProxy()
        s.type(p, "guiwr ")
        val c = s.swipe(p, "file")
        assertTrue(c.english)
        assertEquals("gửi file", p.text)
        s.handle(Key.Backspace, p)                   // ⌫ đầu xoá cả từ
        assertEquals("gửi ", p.text)
        s.swipe(p, "file")
        s.handle(Key.Letter('s'), p)                 // phím dấu Telex KHÔNG sửa từ Anh: dấu cách treo
        assertEquals("gửi file s", p.text)
        assertTrue(s.langModel.count("file") > 0)
        val q = MockProxy(); val s2 = session()
        val cap = s2.swipe(q, "check", SwipeSuggest.Case.FIRST)
        assertTrue(cap.english)
        assertEquals("Check", q.text)
    }

    @Test fun englishSwitchOff() {
        val s = session(); val p = MockProxy()
        s.swipeEnglish = false
        s.type(p, "minhf ddang ")
        val c = s.swipe(p, "check")
        assertFalse(c.english)
        assertTrue(c.englishAlternatives.isEmpty())
    }

    @Test fun leadingSpaceRule() {
        assertFalse(SwipeSuggest.needsLeadingSpace(null))
        assertFalse(SwipeSuggest.needsLeadingSpace(""))
        assertTrue(SwipeSuggest.needsLeadingSpace("abc"))
        assertTrue(SwipeSuggest.needsLeadingSpace("abc,"))
        assertTrue(SwipeSuggest.needsLeadingSpace("abc."))
        assertFalse(SwipeSuggest.needsLeadingSpace("abc "))
        assertFalse(SwipeSuggest.needsLeadingSpace("abc\n"))
        assertFalse(SwipeSuggest.needsLeadingSpace("("))
        assertFalse(SwipeSuggest.needsLeadingSpace("“"))
    }

    // ---- dấu cách treo trước số / ký hiệu sau từ vuốt (bug "mua2") ----

    @Test fun symbolSpaceRule() {
        assertTrue(SwipeSpacing.spaceBefore("2", true, "mua"))
        assertTrue(SwipeSpacing.spaceBefore("2", true, null))          // không đọc được: tin trạng thái
        assertFalse(SwipeSpacing.spaceBefore("2", false, "mua"))        // từ gõ tay: như cũ
        assertFalse(SwipeSpacing.spaceBefore("2", true, "mua "))        // đã có dấu cách
        assertFalse(SwipeSpacing.spaceBefore(".", true, "mua"))
        assertFalse(SwipeSpacing.spaceBefore(",", true, "mua"))
        assertFalse(SwipeSpacing.spaceBefore("!", true, "mua"))
        assertFalse(SwipeSpacing.spaceBefore(")", true, "mua"))
        assertFalse(SwipeSpacing.spaceBefore("\"", true, "mua"))        // nháy thẳng mơ hồ
        assertFalse(SwipeSpacing.spaceBefore("-", true, "mua"))
        assertFalse(SwipeSpacing.spaceBefore("%", true, "mua"))
        assertFalse(SwipeSpacing.spaceBefore("²", true, "m"))
        assertTrue(SwipeSpacing.spaceBefore("(", true, "mua"))
        assertTrue(SwipeSpacing.spaceBefore("“", true, "mua"))
        assertTrue(SwipeSpacing.spaceBefore("$", true, "mua"))
        assertTrue(SwipeSpacing.spaceBefore("😀", true, "mua"))
        assertTrue(SwipeSpacing.spaceBefore("❤️", true, "mua"))
        assertFalse(SwipeSpacing.spaceBefore("", true, "mua"))
    }

    @Test fun digitAfterSwipeGetsSpace() {
        val s = session(); val p = MockProxy()
        s.swipe(p, "viet")
        s.handle(Key.Text("2"), p)
        assertEquals("viết 2", p.text)
        s.handle(Key.Text("0"), p)
        assertEquals("viết 20", p.text)                 // số kế: không thêm nữa
        s.handle(Key.Backspace, p)
        s.handle(Key.Backspace, p)
        assertEquals("viết ", p.text)                    // ⌫ xoá số trước…
        s.handle(Key.Backspace, p)
        assertEquals("viết", p.text)                     // …rồi dấu cách treo
    }

    @Test fun punctuationAfterSwipeStaysGlued() {
        val s = session(); val p = MockProxy()
        s.swipe(p, "viet")
        s.handle(Key.Text("."), p)
        assertEquals("viết.", p.text)
        val s2 = session(); val p2 = MockProxy()
        s2.swipe(p2, "viet")
        s2.handle(Key.Text("("), p2)
        assertEquals("viết (", p2.text)
        val s3 = session(); val p3 = MockProxy()
        s3.swipe(p3, "viet")
        s3.handle(Key.Text("😀"), p3)
        assertEquals("viết 😀", p3.text)
    }

    @Test fun digitAfterTypedWordOrSpaceUnchanged() {
        val s = session(); val p = MockProxy()
        s.type(p, "mua")
        s.handle(Key.Text("2"), p)
        assertEquals("mua2", p.text)                     // từ gõ tay: không đổi
        val s2 = session(); val p2 = MockProxy()
        s2.swipe(p2, "viet")
        s2.type(p2, " ")
        s2.handle(Key.Text("2"), p2)
        assertEquals("viết 2", p2.text)                  // đã có dấu cách: không thành 2
    }

    @Test fun digitAfterEnglishSwipeGetsSpace() {
        val s = session(); val p = MockProxy()
        s.type(p, "minhf ddang ")
        val c = s.swipe(p, "check")
        assertTrue(c.english)
        s.handle(Key.Text("2"), p)
        assertEquals("mình đang check 2", p.text)
    }

    @Test fun heldDigitAfterSwipeGetsSpace() {
        val s = session(); val p = MockProxy()
        s.swipe(p, "viet")
        s.handle(Key.Letter('w'), p)                     // chạm phím chữ…
        s.handle(Key.Text("2", replacesLetter = true), p) // …giữ ra số: gỡ phím chữ, như ngay sau vuốt
        assertEquals("viết 2", p.text)
    }

    @Test fun foldMatchesLexicon() {
        assertEquals("duong", SwipeSuggest.fold("Đường"))
        assertEquals("viet", SwipeSuggest.fold("việt"))
    }
}
