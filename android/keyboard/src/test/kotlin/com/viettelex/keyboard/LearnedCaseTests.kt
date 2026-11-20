package com.viettelex.keyboard

import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.file.Files
import java.util.concurrent.Executor
import java.util.zip.CRC32
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * Hoa/thường cho gõ vuốt + gợi ý (10/2026) — song sinh iOS LearnedCaseTests.swift: DisplayCase áp
 * lên từ vuốt (kết hợp Shift / Caps / đầu câu), hoa/thường người dùng viết nhất quán giữa câu
 * ([CaseTable]), lưu trong userlm.bin (VTL2 flags bit 0), xoá cùng "Xoá từ đã học". Fixture chung
 * iOS/KeyboardTests/Fixtures/userlm-vtl2-case.bin.
 */
class LearnedCaseTests {
    @org.junit.Before fun setUp() = TestAssets.install()

    private val direct = Executor { it.run() }

    /** Ghi một từ như session: bằng chứng = DisplayCase.casingEvidence (giữa câu, không chuỗi). */
    private fun UserLangModel.type(word: String, after: String?, times: Int = 1) {
        repeat(times) { record(word, after, caseEvidence = DisplayCase.casingEvidence(word, after)) }
    }

    @Test fun threeMidSentenceUsesTeachPreferredForm() {
        val m = UserLangModel()
        m.type("SenPrints", "ty", 2)
        assertNull(m.learnedCase("senprints"), "2 lần chưa đủ")
        m.type("SenPrints", "ở")
        assertEquals("SenPrints", m.learnedCase("senprints"))
        m.type("Văn", "anh", 3)
        assertEquals("Văn", m.learnedCase("văn"))
    }

    @Test fun sentenceStartCapitalsAreNotLearned() {
        val m = UserLangModel()
        m.type("Văn", null, 6)
        assertNull(m.learnedCase("văn"))
        assertEquals(0, m.caseCount)
        assertFalse(DisplayCase.casingEvidence("Văn", null))
        assertFalse(DisplayCase.casingEvidence("Văn", ""))
    }

    @Test fun capsLockAndSingleLettersAreNotLearned() {
        val m = UserLangModel()
        m.type("SENPRINTS", "ở", 5)
        m.type("VĂN", "anh", 5)
        m.type("A", "điểm", 5)
        assertNull(m.learnedCase("senprints"))
        assertNull(m.learnedCase("văn"))
        assertNull(m.learnedCase("a"))
        assertEquals(0, m.caseCount)
    }

    @Test fun chainCapitalsAreNotEvidence() {
        val m = UserLangModel()
        m.type("Nam", "Việt", 6)
        assertNull(m.learnedCase("nam"))
        assertFalse(DisplayCase.casingEvidence("Nam", "việt"))
        assertTrue(DisplayCase.casingEvidence("Nam", "anh"))
    }

    @Test fun ambiguousWordNeedsConsistency() {
        val m = UserLangModel()
        m.type("văn", "bài", 20)
        m.type("Văn", "anh", 3)
        assertNull(m.learnedCase("văn"))
        val n = UserLangModel()
        n.type("Văn", "anh", 4)
        assertEquals("Văn", n.learnedCase("văn"))
        n.type("văn", "bài")                    // 4/5 = 80% — vẫn giữ
        assertEquals("Văn", n.learnedCase("văn"))
        n.type("văn", "bài")                    // 4/6 < 80%
        assertNull(n.learnedCase("văn"))
    }

    @Test fun competingCapitalFormsCancel() {
        val m = UserLangModel()
        m.type("SenPrints", "ở", 3)
        m.type("Senprints", "ở", 2)
        assertNull(m.learnedCase("senprints"))
        m.type("Senprints", "ở", 4)
        assertNull(m.learnedCase("senprints"), "4 dạng mới / 9 < 80%")
    }

    @Test fun countersSaturateKeepingRatio() {
        val c = CaseTable()
        repeat(600) { c.observe("VietTelex", "viettelex", 0) }
        val s = c.stats["viettelex"]!!
        assertTrue(s.total <= CaseTable.MAX_COUNT)
        assertEquals(s.total, s.hits)
        assertEquals("VietTelex", c.preferred("viettelex"))
        assertEquals(CaseTable.Kind.MIXED, CaseTable.kind("iPhone"))
        assertEquals(CaseTable.Kind.MIXED, CaseTable.kind("Đà"))
        assertEquals(CaseTable.Kind.IGNORED, CaseTable.kind("ĐÀ"))
        assertEquals(CaseTable.Kind.LOWER, CaseTable.kind("đà"))
    }

    @Test fun recordWithoutEvidenceNeverTouchesCaseTable() {
        val m = UserLangModel()
        repeat(5) { m.record("SenPrints", "ở") }
        assertEquals(0, m.caseCount)
        assertNull(m.learnedCase("senprints"))
    }

    @Test fun pendingRecordsCarryEvidence() {
        val f = File(tmpDir("pend"), "userlm.bin")
        val queue = ArrayList<Runnable>()
        val m = UserLangModel(f, ImmediateMainThread(), Executor { queue.add(it) })
        m.type("SenPrints", "ở", 3)                 // chưa nạp xong ⇒ vào hàng chờ
        queue.toList().forEach { it.run() }
        assertEquals("SenPrints", m.learnedCase("senprints"))
    }

    // MARK: xoá

    @Test fun clearLearnedWordsClearsCasing() {
        val m = UserLangModel()
        m.type("Văn", "anh", 3)
        m.type("SenPrints", "ở", 3)
        assertTrue(m.removeWord("văn"))
        assertNull(m.learnedCase("văn"))
        assertEquals("SenPrints", m.learnedCase("senprints"))
        m.eraseAll()
        assertNull(m.learnedCase("senprints"))
        assertEquals(0, m.caseCount)
    }

    @Test fun eraseFileClearsCasingOnReload() {
        val f = File(tmpDir("erase"), "userlm.bin")
        val m = UserLangModel(f, ImmediateMainThread(), direct)
        m.type("SenPrints", "ở", 3)
        m.save()
        f.delete()                                   // nút "Xóa từ đã học" của app
        m.reloadAfterExternalErase()
        assertNull(m.learnedCase("senprints"))
        assertNull(UserLangModel(f, ImmediateMainThread(), direct).learnedCase("senprints"))
    }

    @Test fun decayDropsCasingOfForgottenWords() {
        var now = 1_000_000_000_000L
        val m = UserLangModel(clock = { now })
        m.type("Văn", "anh", 3)
        now += 52L * 7 * 86_400_000L
        m.decayIfDue(now)
        assertEquals(0, m.count("văn"))
        assertNull(m.learnedCase("văn"))
        assertEquals(0, m.caseCount)
    }

    // MARK: lưu

    @Test fun persistenceRoundTrip() {
        val f = File(tmpDir("rt"), "userlm.bin")
        val m = UserLangModel(f, ImmediateMainThread(), direct)
        m.type("SenPrints", "ở", 3)
        m.type("Văn", "anh", 2)
        m.save()
        val r = UserLangModel(f, ImmediateMainThread(), direct)
        assertEquals("SenPrints", r.learnedCase("senprints"))
        assertNull(r.learnedCase("văn"))
        assertEquals(CaseStat("Văn", 2, 2), r.caseStat("văn"))
        r.type("Văn", "anh")
        assertEquals("Văn", r.learnedCase("văn"))
    }

    @Test fun noCasingKeepsOldBytesAndOldFilesLoad() {
        val old = UserLMCompactTests.fixtureFile("userlm-vtl2.bin").readBytes()
        val d = assertNotNull(UserLMCodec.decode(old))
        assertTrue(d.cases.isEmpty)
        assertContentEquals(old, UserLMCodec.encode(d.t, d.lastDecay, d.manual, d.cases))
        assertEquals(0, old[6].toInt()); assertEquals(0, old[7].toInt())
    }

    @Test fun crossPlatformCaseFixture() {
        val data = UserLMCompactTests.fixtureFile("userlm-vtl2-case.bin").readBytes()
        val d = assertNotNull(UserLMCodec.decode(data))
        assertEquals(mapOf("senprints" to 3, "văn" to 21, "nam" to 4), d.t.uniMap())
        assertEquals(CaseStat("SenPrints", 3, 3), d.cases.stats["senprints"])
        assertEquals(CaseStat("Văn", 1, 21), d.cases.stats["văn"])
        assertNull(d.cases.stats["nam"])
        assertEquals("SenPrints", d.cases.preferred("senprints"))
        assertNull(d.cases.preferred("văn"))
        assertContentEquals(data, UserLMCodec.encode(d.t, d.lastDecay, d.manual, d.cases))
        for (i in data.size - 30 until data.size) {
            val bad = data.copyOf(); bad[i] = (bad[i].toInt() xor 0x40).toByte()
            assertNull(UserLMCodec.decode(bad), "byte $i")
        }
    }

    @Test fun codecRejectsInvalidCaseRows() {
        val t = UserLMTables()
        t.setUni(t.intern("văn"), 5)
        t.setUni(t.intern("senprints"), 3)
        val good = UserLMCodec.encode(t, 0L, emptyList(),
            CaseTable(mapOf("văn" to CaseStat("Văn", 2, 6), "senprints" to CaseStat("SenPrints", 3, 3))))
        assertEquals(1, good[6].toInt(), "flags bit 0")
        assertEquals(2, UserLMCodec.decode(good)?.cases?.count)
        val orphan = UserLMCodec.encode(t, 0L, emptyList(), CaseTable(mapOf("xyz" to CaseStat("Xyz", 3, 3))))
        assertEquals(0, orphan[6].toInt())
        fun patched(edit: (ByteArray) -> Unit): ByteArray {
            val b = good.copyOf(good.size - 4); edit(b)
            val c = CRC32().apply { update(b) }.value.toInt()
            return b + ByteBuffer.allocate(4).order(ByteOrder.LITTLE_ENDIAN).putInt(c).array()
        }
        val n = good.size - 4
        assertNotNull(UserLMCodec.decode(patched { }))
        assertNull(UserLMCodec.decode(patched { it[n - 4] = 9; it[n - 3] = 0 }), "hits > total")
        assertNull(UserLMCodec.decode(patched { it[n - 2] = 0; it[n - 1] = 0 }), "total 0")
        assertNull(UserLMCodec.decode(patched { it[6] = 0 }), "flag tắt mà còn dữ liệu")
    }

    @Test fun entriesShowLearnedForm() {
        val m = UserLangModel()
        m.type("SenPrints", "ở", 3)
        assertEquals("SenPrints", m.entries("sen").single().word)
    }

    private fun tmpDir(tag: String): File = Files.createTempDirectory("lcase-$tag").toFile().apply { deleteOnExit() }

    // MARK: vuốt — DisplayCase + Shift + học

    @Test fun swipeCaseAppliesProperFormThenShift() {
        val proper: (String) -> String = { DisplayCase.resolve(it) }
        assertEquals("iPhone", SwipeSuggest.applyCase("iphone", SwipeSuggest.Case.LOWER, proper))
        assertEquals("iPhone", SwipeSuggest.applyCase("iphone", SwipeSuggest.Case.FIRST, proper))
        assertEquals("IPHONE", SwipeSuggest.applyCase("iphone", SwipeSuggest.Case.ALL, proper))
        assertEquals("London", SwipeSuggest.applyCase("london", SwipeSuggest.Case.LOWER, proper))
        assertEquals("Nguyễn", SwipeSuggest.applyCase("nguyễn", SwipeSuggest.Case.LOWER, proper))
        assertEquals("Chào", SwipeSuggest.applyCase("chào", SwipeSuggest.Case.FIRST, proper))
        assertEquals("chào", SwipeSuggest.applyCase("chào", SwipeSuggest.Case.LOWER, proper))
        val chain: (String) -> String = { DisplayCase.resolve(it, "việt") }
        assertEquals("Nam", SwipeSuggest.applyCase("nam", SwipeSuggest.Case.LOWER, chain))
        assertEquals("NAM", SwipeSuggest.applyCase("nam", SwipeSuggest.Case.ALL, chain))
        val learned: (String) -> String = { DisplayCase.resolve(it, null) { k -> if (k == "văn") "Văn" else null } }
        assertEquals("Văn", SwipeSuggest.applyCase("văn", SwipeSuggest.Case.LOWER, learned))
        assertEquals("Văn", SwipeSuggest.applyCase("văn", SwipeSuggest.Case.FIRST, learned))
        assertEquals("VĂN", SwipeSuggest.applyCase("văn", SwipeSuggest.Case.ALL, learned))
        assertEquals("Chào", SwipeSuggest.applyCase("chào", SwipeSuggest.Case.FIRST), "API cũ chỉ Shift")
    }

    @Test fun chooseAppliesDisplayCaseLikeBar() {
        val en = listOf(SwipeCandidate("iphone", 0f, SwipeLang.EN))
        val ctx = SwipeSuggest.context(null, null, null)
        assertEquals("iPhone", SwipeSuggest.choose(en, ctx.word, SwipeSuggest.Case.LOWER, ctx.lambdaFreq, ctx.proper)?.word)
        assertEquals("iPhone", SwipeSuggest.choose(en, ctx.word, SwipeSuggest.Case.FIRST, ctx.lambdaFreq, ctx.proper)?.word)
        assertEquals("IPHONE", SwipeSuggest.choose(en, ctx.word, SwipeSuggest.Case.ALL, ctx.lambdaFreq, ctx.proper)?.word)
        val plain = SwipeSuggest.context(null, null, null, properNouns = false)
        assertEquals("iphone", SwipeSuggest.choose(en, plain.word, SwipeSuggest.Case.LOWER, plain.lambdaFreq, plain.proper)?.word)
        val lark = listOf(SwipeCandidate("lark", 0f, SwipeLang.EN))
        assertEquals("lark", SwipeSuggest.choose(lark, ctx.word, proper = ctx.proper)?.word)
        val m = UserLangModel()
        m.type("Lark", "dùng", 3)
        val lctx = SwipeSuggest.context(m, null, null)
        assertEquals("Lark", SwipeSuggest.choose(lark, lctx.word, proper = lctx.proper)?.word)
    }

    // MARK: luồng session

    private val layout = SwipeLayout.qwerty(keyWidth = 36f, rowHeight = 54f)
    private val decoder = SwipeDecoder().also { it.setLayout(layout) }

    private fun session(model: UserLangModel = UserLangModel()): KeyboardSession {
        val s = KeyboardSession(model, null) { 0L }
        s.startInput(KeyboardSettings(), FieldTraits())
        s.setSwipeTyping(true)
        return s
    }

    private fun KeyboardSession.swipeR(p: TextProxy, word: String, case: SwipeSuggest.Case = SwipeSuggest.Case.LOWER): SwipeChoice {
        val path = SwipeSim(7).path(word, layout, sigma = 0.0, jitter = 0.0)
        val ctx = swipeContext()
        val cands = decoder.decode(path, SwipeSuggest.TOP_K, ctx.folded, ctx.english, if (ctx.english != null) ctx.englishWord else null)
        val r = resolveSwipe(cands, ctx, case)!!
        commitSwipe(r, p)
        return r.choice
    }

    @Test fun swipeVietNamCapitalizesChain() {
        val m = UserLangModel()
        repeat(3) { m.record("việt", "yêu"); m.record("nam", "việt") }   // biết "việt" sau "yêu"
        val s = session(m); val p = MockProxy()
        for (c in "tooi yeeu ") s.handle(if (c == ' ') Key.Space else Key.Letter(c), p)
        assertEquals("tôi yêu ", p.text)
        assertEquals("việt", s.swipeR(p, "viet").word)
        assertEquals("tôi yêu việt", p.text)
        assertEquals("Nam", s.swipeR(p, "nam").word)
        assertEquals("tôi yêu Việt Nam", p.text)
        assertEquals("↩︎ việt", s.suggestionsNow(p)!!.actionLabel)
    }

    @Test fun swipedProperNounWithShiftAndCaps() {
        for ((case, want) in listOf(SwipeSuggest.Case.LOWER to "London", SwipeSuggest.Case.FIRST to "London",
                                    SwipeSuggest.Case.ALL to "LONDON")) {
            val s = session(); val p = MockProxy()
            s.handle(Key.Space, p)
            val en = listOf(SwipeCandidate("london", 0f, SwipeLang.EN))
            val ctx = s.swipeContext()
            assertEquals(want, s.resolveSwipe(en, ctx, case)!!.choice.word, "$case")
        }
    }

    @Test fun suggestionBarUsesLearnedCase() {
        val m = UserLangModel().apply { isKnownWord = { true } }
        repeat(4) { m.type("Lark", "dùng") }
        val s = session(m); val p = MockProxy()
        for (c in "dungf ") s.handle(if (c == ' ') Key.Space else Key.Letter(c), p)
        val set = s.suggestionsNow(p)!!
        assertTrue("Lark" in set.nextWords, set.nextWords.toString())
    }
}
