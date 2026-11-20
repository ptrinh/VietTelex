package com.viettelex.keyboard

import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import java.io.File
import java.util.Locale

/**
 * Từ vựng gõ vuốt theo công tắc "Lọc từ nhạy cảm" ([SwipeVocab]). Fixture chung iOS ↔ Android:
 * iOS/KeyboardTests/Fixtures/swipe-vocab.tsv (sinh ở đây, `VT_WRITE_FIXTURE=1`; iOS SwipeVocabTests
 * khớp từng dòng). Cột cách TAB:
 *
 * - `E filter folded words` — [SwipeDecoder.expand](folded, 40) không ngữ cảnh: `từ:điểm` (%.4f).
 * - `P filter case words expected` — cả câu vuốt đường sạch (như [SwipeReviseParityTests.phrase]).
 *
 * filter = 1 (bật, mặc định) / 0 (tắt).
 */
class SwipeVocabTests {
    @Before fun setUp() = TestAssets.install()
    @After fun tearDown() { SwipeVocab.filterSensitive = true; SwipeVocab.teencode = false }

    private val layout = SwipeLayout.qwerty(keyWidth = 36f, rowHeight = 54f)
    private val decoder = SwipeDecoder().also { it.setLayout(layout) }

    private fun fixtureDir(): File = listOf("../../iOS", "../iOS", "iOS").map { File(it, "KeyboardTests/Fixtures") }
        .firstOrNull { it.exists() } ?: error("không thấy KeyboardTests/Fixtures")

    private fun sensitive(text: String) = text.split(' ').any { it.lowercase() in SensitiveWords.set }

    @Test fun tableAgreesWithFilterList() {
        for (e in SwipeVocab.CHAT) assertFalse(e.word, e.word in SensitiveWords.set)
        val sens = SwipeVocab.sensitiveEntries(SeedData.unigrams)
        assertEquals(SensitiveWords.set, sens.map { it.word }.toSet())
        // sàn chỉ cho từ vnlexicon không có; từ có sẵn (đĩ, cứt…) giữ tần suất vnlexicon
        val off = SwipeVocab.build(false).words.values.flatten().associate { it.word to it.score.toInt() }
        assertEquals(setOf("đĩ", "cứt", "dâm", "điếm", "lìn"), SensitiveWords.set.filter { it !in off }.toSet())
        assertTrue(off.filterKeys { it in SensitiveWords.set }.values.all { it >= SwipeVocab.SENSITIVE_FLOOR })
        assertTrue(SwipeVocab.build(true).words.values.flatten().none { it.word in SensitiveWords.set })
    }

    /** Lọc bật: KHÔNG dạng nào (lexicon + thêm) bung ra từ nhạy cảm — kể cả đĩ, cứt, dâm, điếm có sẵn. */
    @Test fun filteredExpansionNeverSensitive() {
        SwipeVocab.filterSensitive = true
        val v = SwipeVocab.current
        for (f in 0 until v.forms.count) {
            val ws = SwipeDecoder.expand(v.forms.folded[f], 64)
            assertTrue(v.forms.folded[f], ws.none { it.word in SensitiveWords.set })
        }
        SwipeVocab.filterSensitive = false
        assertEquals("địt", SwipeDecoder.expand("dit", 1).first().word)
        assertTrue(SwipeDecoder.expand("cut", 8).any { it.word == "cứt" })
        assertEquals(listOf("đcm", "dcm"), SwipeDecoder.expand("dcm", 8).map { it.word })
    }

    /** Từ một chữ vuốt theo phím Telex (11/2026, Phil: "ở, ạ… rất khó vuốt; ow là ở, aj là ạ, ừ thì uw là đủ"). */
    @Test fun singleLetterWordsSwipeByTelexKeys() {
        fun top(f: String) = SwipeDecoder.expand(f, 1).firstOrNull()?.word
        assertEquals("ở", top("ow"))
        assertEquals("ừ", top("uw"))
        assertEquals("ạ", top("aj"))
        assertEquals("à", top("af"))
        assertEquals("ý", top("ys"))
        assertEquals("ở", top("owr"))
        assertEquals("ừ", top("uwf"))
        assertEquals(listOf("ở", "ờ", "ơ", "ợ", "ớ"), SwipeDecoder.expand("ow", 8).map { it.word })
        assertEquals("ồ" to "of", SwipeVocab.telexPaths("ồ").first?.let { "ồ" to it })
        assertEquals("owr" to "ow", SwipeVocab.telexPaths("ở"))
        assertEquals(null to null, SwipeVocab.telexPaths("a"))
        // đường trùng từ tiếng Anh thông dụng hơn âm tiết Việt mạnh nhất của nó thì bỏ — và chỉ những đường đó
        val en = SwipeEnglish.lexicon
        val best = HashMap<String, Int>()
        for (v in "aeiouy") {
            val f = SwipeLexicon.indexOf(v.toString())
            for (id in SwipeLexicon.forms.idStart[f] until SwipeLexicon.forms.idStart[f + 1]) {
                val (full, fam) = SwipeVocab.telexPaths(VNSuggest.display(id))
                for (p in listOfNotNull(full, fam)) best[p] = maxOf(best[p] ?: 0, VNSuggest.freq(id))
            }
        }
        val clash = best.filter { (p, f) -> SwipeEnglish.indexOf(p).let { it >= 0 && en.freq(it) >= f } }.keys
        assertEquals(SwipeVocab.TELEX_SKIP, clash)
        assertTrue(SwipeVocab.telexEntries.none { it.path in SwipeVocab.TELEX_SKIP })
        // một chữ không dấu vẫn không vuốt được, dạng vnlexicon không đổi
        assertEquals(null, SwipeVocab.current.forms.folded.firstOrNull { it.length == 1 && SwipeLexicon.indexOf(it) < 0 })
    }

    /** Tên riêng khi vuốt viết hoa chuẩn (Phil 12/11/2026: Hà Nội, Saigon, Singapore, Paris, Google). */
    @Test fun properNounsSwipeCapitalized() {
        for ((t, want) in listOf("tôi ở hà nội" to "Tôi ở Hà Nội", "hà nội" to "Hà Nội", "đi singapore" to "Đi Singapore",
            "ở paris" to "Ở Paris", "tìm trên google" to "Tìm trên Google", "về saigon" to "Về Saigon",
            "ở sài gòn" to "Ở Sài Gòn", "đi đà nẵng" to "Đi Đà Nẵng", "hồ chí minh" to "Hồ Chí Minh",
            "đi hanoi" to "Đi Hanoi", "ở vietnam" to "Ở Vietnam", "đi huế" to "Đi Huế", "đi hàn quốc" to "Đi Hàn Quốc",
            "sang trung quốc" to "Sang Trung Quốc", "tôi yêu việt nam" to "Tôi yêu Việt Nam", "mua iphone" to "Mua iPhone",
            // từ Anh vừa vuốt cũng được viết hoa ngược (Phil 12/11/2026)
            "ở new york" to "Ở New York"))
            assertEquals(t, want, session(t, true).first)
        // từ thường không bị hoa nhầm: "nội" / "quốc" / "bình" đứng ngoài chuỗi
        assertEquals("nội", DisplayCase.apply("nội", "bà"))
        assertEquals("quốc", DisplayCase.apply("quốc", "tổ"))
        assertEquals("bình", DisplayCase.apply("bình", "hòa"))
    }

    /** Phil 12/11/2026: "er → ẻ (nếu bật teencode)" — tắt teencode thì không có. */
    @Test fun teencodeAddsEr() {
        SwipeVocab.teencode = false
        assertTrue(SwipeDecoder.expand("er", 4).none { it.word == "ẻ" })
        SwipeVocab.teencode = true
        assertEquals("ẻ", SwipeDecoder.expand("er", 1).firstOrNull()?.word)
        assertEquals("ở", SwipeDecoder.expand("ow", 1).firstOrNull()?.word)   // nét Telex khác giữ nguyên
        SwipeVocab.teencode = false
        assertTrue(SwipeDecoder.expand("er", 4).none { it.word == "ẻ" })
    }

    @Test fun chatAbbreviationsAlwaysThere() {
        for (filter in listOf(true, false)) {
            SwipeVocab.filterSensitive = filter
            assertEquals("ko", SwipeDecoder.expand("ko", 1).first().word)
            assertEquals("đc", SwipeDecoder.expand("dc", 1).first().word)
            assertTrue(SwipeVocab.current.indexOf("nma") >= SwipeLexicon.forms.count)
        }
    }

    // ---- ca Phil (đường IME thật: KeyboardSession, LM cá nhân seed như máy mới) ----

    private fun KeyboardSession.swipeR(p: TextProxy, word: String, case: SwipeSuggest.Case) {
        val path = SwipeSim(7).path(word, layout, sigma = 0.0, jitter = 0.0)
        val ctx = swipeContext()
        val cands = decoder.decode(path, SwipeSuggest.TOP_K, ctx.folded, ctx.english, if (ctx.english != null) ctx.englishWord else null)
        commitSwipe(resolveSwipe(cands, ctx, case) ?: return, p)
    }

    /** Vuốt cả câu qua session thật; trả (chữ trên màn hình, phương án thanh gợi ý của từ cuối). */
    private fun session(text: String, filter: Boolean): Pair<String, List<String>> {
        val lm = UserLangModel().apply { isKnownWord = { VNSuggest.contains(it) }; seedIfEmpty() }
        val s = KeyboardSession(lm, null) { 0L }
        s.startInput(KeyboardSettings().apply { filterSensitive = filter }, FieldTraits())
        s.setSwipeTyping(true)
        val p = MockProxy()
        for ((i, w) in text.split(' ').withIndex())
            s.swipeR(p, SwipeSuggest.fold(w), if (i == 0) SwipeSuggest.Case.FIRST else SwipeSuggest.Case.LOWER)
        return p.text to (s.swipeAlternatives ?: emptyList())
    }

    /** Muốn gõ → (lọc tắt) ra thực tế. Cặp chọn tay (CuratedPairs, 18/10/2026) sửa vãi lồn, ngu vl, bóp dái/vú,
     *  mò cu; vnlm.bin hội thoại (18/10/2026) sửa thêm "vãi cả lồn"; còn lệch: "sờ cu" (decoder ra dạng "chu" trước khi bung dấu).
     *  Giai đoạn 2 (vnlexicon tần suất corpus hội thoại, 18/10/2026): "mò cu" lại lệch → "Mơ chứ" — dạng "cu" có
     *  cư/cử/cú/củ vượt "cu" (hạng 8) nên "cu" rơi khỏi 4 dấu đầu, cặp chọn tay không áp được; "sờ cu" → "So cứ".
     *  Seed 18/10/2026 thêm cặp "móc lồn" ⇒ vuốt tắt lọc ra đúng "Móc lồn" (trước: "Mốc lớn"). */
    private val phil = listOf(
        "địt con mẹ" to "Địt con mẹ", "vãi lồn" to "Vãi lồn", "vãi cả lồn" to "Vãi cả lồn",
        "dkm" to "Đkm", "đcm" to "Đcm", "ngu vl" to "Ngu vl", "buscu" to "Buscu",
        "ko" to "Ko", "bóp dái" to "Bóp dái", "sờ cu" to "So cứ", "mò cu" to "Mơ chứ", "bóp vú" to "Bóp vú",
        "móc lồn" to "Móc lồn",
    )

    /**
     * Danh sách Phil 18/10/2026, vuốt riêng từng từ, TẮT lọc → (ra, từ muốn có trên thanh gợi ý nếu
     * không ra đầu). Từ cùng hình với từ thường rất phổ biến (lồn/lớn, cặc/các, buồi/buổi, đụ/đủ,
     * dâm/dám, vú/vụ, ngu/ngủ) KHÔNG được thắng một mình — nếu thắng thì "người lớn", "các bạn" hỏng;
     * phân biệt cần ngữ cảnh (chưa duyệt danh sách cụm).
     * Giai đoạn 2 (18/10/2026, tần suất corpus hội thoại + seed mới): đụ → Dù (dù 183 > đủ 179), vú → Vụ (seed),
     * dâm → Đảm (đảm 163: "đảm bảo"); "Ngu" rơi khỏi thanh gợi ý (ngữ 129 → 162 hoà ngu 162).
     */
    private val single = listOf(
        "lồn" to "Lớn", "địt" to "Địt", "buồi" to "Buổi", "đụ" to "Dù", "đkm" to "Đkm", "đcm" to "Đcm",
        "cặc" to "Các", "vú" to "Vụ", "vcl" to "Vcl", "vkl" to "Vkl", "dâm" to "Đảm", "ngu" to "Ngủ", "nắc" to "Nắc",
    )
    private val onBar = setOf("Lồn", "Buồi", "Cặc")

    /** Tắt lọc không được đổi từ thường cùng hình trong câu thường (trừ đít/địt — xem báo cáo). */
    private val guards = listOf("người lớn", "lớn lên", "rất lớn", "lớn nhất", "các bạn", "buổi sáng", "đi đâu", "đủ rồi")

    @Test fun philListFilterOff() {
        for ((w, want) in single) {
            val (text, alts) = session(w, filter = false)
            println(String.format(Locale.ROOT, "VOCAB lọc tắt '%s' → '%s' | %s", w, text, alts))
            assertEquals(w, want, text)
            val cap = Cp.capitalizeFirst(w)
            if (cap in onBar) assertTrue("$w trên thanh gợi ý: $alts", cap in alts)
        }
    }

    @Test fun philListFilterOn() {
        for ((w, _) in single) {
            val (text, alts) = session(w, filter = true)
            println(String.format(Locale.ROOT, "VOCAB lọc bật  '%s' → '%s' | %s", w, text, alts))
            assertFalse("$w → $text", sensitive(text))
            assertFalse("$w alts $alts", alts.any { it.lowercase() in SensitiveWords.set })
        }
        assertEquals("Nắc", session("nắc", filter = true).first)
    }

    @Test fun filterOffKeepsCommonHomographs() {
        for (g in guards) assertEquals(g, session(g, filter = true).first, session(g, filter = false).first)
        assertEquals("Cái đít", session("cái đít", filter = true).first)
        assertEquals("Cái địt", session("cái đít", filter = false).first)   // giá của dit→địt khi tắt lọc
    }

    @Test fun philCasesFilterOnNeverProfane() {
        for ((want, _) in phil) {
            val (text, alts) = session(want, filter = true)
            println(String.format(Locale.ROOT, "VOCAB lọc bật  '%s' → '%s' | %s", want, text, alts))
            assertFalse("$want → $text", sensitive(text))
            assertFalse("$want alts $alts", alts.any { it.lowercase() in SensitiveWords.set })
        }
    }

    @Test fun philCasesFilterOff() {
        val got = phil.map { (want, _) -> session(want, filter = false) }
        for ((i, c) in phil.withIndex())
            println(String.format(Locale.ROOT, "VOCAB lọc tắt '%s' → '%s' | %s", c.first, got[i].first, got[i].second))
        assertEquals(phil.map { it.second }, got.map { it.first })
    }

    // ---- fixture chung ----

    private val folds = listOf("dit", "lon", "cac", "buoi", "du", "di", "cut", "dam", "diem", "vu", "dai", "cu", "so", "mo",
        "ow", "uw", "owr", "uwf", "aj", "af", "ar", "ys", "oj", "ej")

    private val phrases = phil.map { it.first } + single.map { it.first } + guards + listOf("ko biết", "đc không", "ok", "nma", "ntn", "bt", "ms", "haha",
        "uhm", "uhm được rồi", "ow", "uw", "tôi ow nhà", "vâng aj", "af thế", "ys kiến")

    private fun generate(): List<String> {
        val lines = ArrayList<String>()
        lines += "# swipe-vocab v1 — từ vựng vuốt theo công tắc lọc từ nhạy cảm (E bung dạng, P cả câu đường sạch). " +
            "Sinh bởi android SwipeVocabTests (VT_WRITE_FIXTURE=1); iOS SwipeVocabTests khớp từng dòng. Cột cách TAB."
        val par = SwipeReviseParityTests()
        for (filter in listOf(true, false)) {
            SwipeVocab.filterSensitive = filter
            val fl = if (filter) "1" else "0"
            for (f in (folds + SwipeVocab.current.words.keys.sorted()).distinct())
                lines += listOf("E", fl, f, SwipeDecoder.expand(f, 40).joinToString(",") {
                    "${it.word}:" + String.format(Locale.ROOT, "%.4f", it.score) }).joinToString("\t")
            for (s in phrases) lines += listOf("P", fl, "F", s, par.phrase(s.split(' '), SwipeSuggest.Case.FIRST)).joinToString("\t")
        }
        SwipeVocab.filterSensitive = true
        return lines
    }

    @Test fun parityFixture() {
        val out = File(fixtureDir(), "swipe-vocab.tsv")
        val lines = generate()
        if (System.getenv("VT_WRITE_FIXTURE") != null) out.writeText(lines.joinToString("\n") + "\n")
        assertEquals("chạy VT_WRITE_FIXTURE=1 để sinh lại", out.readLines(), lines)
        // lọc bật: không dòng P nào ra từ nhạy cảm
        for (l in lines) { val c = l.split('\t'); if (c[0] == "P" && c[1] == "1") assertFalse(l, sensitive(c[4])) }
    }

    /** Chẩn đoán (in): dạng có trong từ vựng? decoder ra dạng gì? bung dấu xếp thế nào. */
    @Test fun diagnose() {
        SwipeVocab.filterSensitive = false
        for (w in listOf("ko", "dái", "cu", "vú", "sờ", "mò", "bóp", "vãi", "ngu", "nắc", "lồn", "cặc", "buồi", "đụ", "dâm")) {
            val f = SwipeSuggest.fold(w)
            val cands = decoder.decode(SwipeSim(7).path(f, layout, sigma = 0.0, jitter = 0.0), SwipeSuggest.TOP_K)
            println("DIAG $w: dạng '$f' trong vocab=${SwipeVocab.current.indexOf(f) >= 0} | decode=" +
                cands.joinToString { it.folded + ":" + String.format(Locale.ROOT, "%.2f", it.score) } +
                " | bung=" + SwipeDecoder.expand(f, 6).joinToString { it.word + ":" + String.format(Locale.ROOT, "%.2f", it.score) })
        }
    }
}
