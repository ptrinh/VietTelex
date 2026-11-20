package com.viettelex.keyboard

import java.text.Normalizer
import kotlin.math.ln
import kotlin.math.sqrt

/*
 * SwipeTyping.kt — phần THUẦN của tích hợp gõ vuốt (không View/MotionEvent):
 *  - [GestureClassifier]: chạm hay vuốt (chữ đầu HOÃN tới lúc nhấc — #172; thành vuốt thì
 *    caller bỏ chữ đó, chưa từng chèn).
 *  - [SwipeSuggest]: ứng viên decoder → từ có dấu top-1 + biến thể cho thanh gợi ý,
 *    điểm ngữ cảnh từ UserLangModel, luật dấu cách treo.
 * Cùng hằng số/hành vi với bản iOS.
 */

/**
 * Bộ phân loại cử chỉ trên một phím chữ. Mọi toạ độ dp, thời gian ms.
 *
 * Thành VUỐT khi (cùng lúc): chỉ một ngón, đã ra khỏi phím xuất phát, xa điểm chạm
 * ≥ [Params.minDistanceKeys] bề rộng phím và tốc độ trung bình ≥ [Params.minSpeed].
 * Vừa gõ chữ trong [Params.fastTypingWindowMs] ⇒ hai ngưỡng nhân hệ số giảm tuyến tính
 * từ [Params.fastTypingFactor] về 1 (kiểu AOSP LatinIME: gõ nhanh kéo lệch ngón không
 * thành vuốt). Ngón thứ hai, hoặc quá [Params.lockAfterMs] chưa đạt ⇒ khoá là CHẠM.
 */
class GestureClassifier(val params: Params = Params()) {
    data class Params(
        val minDistanceKeys: Float = 1.0f,
        /** dp/ms. */
        val minSpeed: Float = 0.1f,
        val lockAfterMs: Long = 500,
        val fastTypingWindowMs: Long = 350,
        val fastTypingFactor: Float = 3.0f,
    )

    enum class State { IDLE, PENDING, SWIPE, TAP }

    var state = State.IDLE; private set
    private var x0 = 0f; private var y0 = 0f; private var t0 = 0L
    private var kl = 0f; private var kt = 0f; private var kr = 0f; private var kb = 0f
    private var distThreshold = 0f
    private var speedThreshold = 0f
    private var left = false

    /**
     * Ngón chạm xuống phím chữ (rect [keyL]…[keyB]). [sinceLastLetterMs] = thời gian từ
     * phím chữ trước (Long.MAX_VALUE nếu không có).
     */
    fun begin(x: Float, y: Float, tMs: Long, keyL: Float, keyT: Float, keyR: Float, keyB: Float,
              keyWidth: Float, sinceLastLetterMs: Long) {
        state = State.PENDING
        x0 = x; y0 = y; t0 = tMs
        kl = keyL; kt = keyT; kr = keyR; kb = keyB
        left = false
        val f = factorAfterTyping(sinceLastLetterMs)
        distThreshold = params.minDistanceKeys * keyWidth * f
        speedThreshold = params.minSpeed * f
    }

    /** Hệ số ngưỡng sau khi vừa gõ: fastTypingFactor ở 0 ms → 1 ở hết cửa sổ. */
    fun factorAfterTyping(sinceMs: Long): Float {
        val w = params.fastTypingWindowMs
        if (sinceMs < 0 || sinceMs >= w) return 1f
        return 1f + (params.fastTypingFactor - 1f) * (1f - sinceMs.toFloat() / w.toFloat())
    }

    /** Ngón khác chạm xuống: đang chờ ⇒ khoá chạm (gõ chồng ngón). */
    fun pointerAdded() { if (state == State.PENDING) state = State.TAP }

    /** Điểm mới của ngón đang theo dõi (kể cả điểm lịch sử). */
    fun move(x: Float, y: Float, tMs: Long): State {
        if (state != State.PENDING) return state
        val dt = tMs - t0
        if (!left && (x < kl || x >= kr || y < kt || y >= kb)) left = true
        val dx = x - x0; val dy = y - y0
        val dist = sqrt(dx * dx + dy * dy)
        if (left && dist >= distThreshold && dt > 0 && dist / dt.toFloat() >= speedThreshold) {
            state = State.SWIPE
        } else if (dt > params.lockAfterMs) {
            state = State.TAP
        }
        return state
    }

    fun end() { state = State.IDLE }
}

/**
 * Kết quả vuốt: từ chèn + biến thể cho thanh gợi ý (đã theo chữ hoa). [english] = từ chèn
 * là tiếng Anh (chèn nguyên văn, không seed Telex); [englishAlternatives] = các phương án
 * tiếng Anh trong [alternatives].
 */
data class SwipeChoice(
    val word: String, val alternatives: List<String>,
    val english: Boolean = false, val englishAlternatives: Set<String> = emptySet(),
    /** Từ thắng chỉ áp Shift (không tên riêng) — tra khoá gõ tắt như gõ tay. = iOS Choice.shifted. */
    val shifted: String = "",
)

object SwipeSuggest {
    const val TOP_K = 5
    const val MAX_ALTERNATIVES = 3

    /** Chữ hoa theo shift lúc bắt đầu vuốt. */
    enum class Case { LOWER, FIRST, ALL }

    /** Bỏ dấu tiếng Việt + đ→d, chữ thường (khớp dạng folded của lexicon). */
    fun fold(w: String): String {
        val n = Normalizer.normalize(w.lowercase(), Normalizer.Form.NFD)
        val sb = StringBuilder(n.length)
        for (c in n) {
            if (Character.getType(c) == Character.NON_SPACING_MARK.toInt()) continue
            sb.append(if (c == 'đ') 'd' else c)
        }
        return sb.toString()
    }

    /**
     * Điểm ngữ cảnh (log-domain, GIỐNG bản iOS SwipeTyping.contextScore):
     *  - cá nhân: từ kế tiếp hay gặp sau (prev2, prev1) +[NEXT_BONUS]; từ hay gõ
     *    +ln(1+count)·[PERSONAL_WEIGHT] (trần [PERSONAL_CAP]);
     *  - tĩnh: trigram âm tiết (vnlm.bin, [SyllableLM]) sau (prev2, prev) ·[LM_WEIGHT] kẹp
     *    [[LM_FLOOR], [LM_CAP]] (< NEXT_BONUS ⇒ dữ liệu cá nhân vẫn thắng); đã có nextWords thì
     *    nhân [STATIC_DAMP]. Không có vnlm.bin / âm tiết trước lạ ⇒ không có điểm tĩnh.
     * [folded] (cho decoder) = điểm âm tiết tốt nhất của dạng không dấu (tần suất + ngữ cảnh)
     * trừ phần tần suất decoder đã tính ⇒ decode và expand chấm cùng một thước.
     */
    class Context(private val next: Set<String>, private val nextFolded: Set<String>,
                  private val count: (String) -> Int,
                  prev: String? = null,
                  /** Tham số tiếng Anh cho decoder (giai đoạn 3); null = tắt vuốt tiếng Anh. */
                  val english: SwipeEnglishPrior? = null,
                  /** Âm tiết trước nữa + mô hình trigram (vnlm.bin). */
                  prev2: String? = null, lm: SyllableLM? = null,
                  /** Cộng cặp chọn tay ([CuratedPairs]); false = mốc đo. */
                  useCurated: Boolean = true,
                  /** Hoa/thường đã học ([UserLangModel.learnedCase]). */
                  val learnedCase: ((String) -> String?)? = null,
                  /** false = ô địa chỉ / tìm kiếm (thanh gợi ý chữ thường): không tên riêng, chỉ Shift. */
                  val properNouns: Boolean = true) {
        /** Từ liền trước (chuỗi tên riêng [DisplayCase]). */
        val prevWord: String? = prev

        /** Dạng tên riêng của từ vuốt [w] (chữ thường) sau [prevWord] — trước khi áp Shift. = iOS Context.proper. */
        val proper: (String) -> String = { w ->
            if (properNouns) DisplayCase.resolve(w, prevWord, learnedCase) else w
        }

        private val id1 = if (prev == null) -1 else SyllableLM.idOf(prev)
        private val lmCtx: SyllableLM.Context? =
            if (lm == null || id1 < 0) null
            else lm.context(if (prev2 == null) -1 else SyllableLM.idOf(prev2), id1)
        private val damp = if (next.isEmpty()) 1f else STATIC_DAMP
        /** Từ chọn tay sau (prev2, prev) — [CuratedPairs.next]. */
        private val curated: Set<String> =
            if (prev == null || !useCurated) emptySet() else CuratedPairs.next(prev, prev2).toHashSet()
        private val staticWeight = LM_WEIGHT * damp
        /** λ tần suất khi chọn dạng + bung dấu (hạ còn [LM_LAMBDA_FREQ] khi có trigram). */
        val lambdaFreq: Float = if (lmCtx != null) LM_LAMBDA_FREQ else LAMBDA_FREQ

        /** Điểm LM tĩnh của âm tiết có dấu [w] (0 nếu không có dữ liệu). */
        fun static(w: String): Float {
            val c = lmCtx ?: return 0f
            val id = SyllableLM.idOf(w)
            return if (id < 0) 0f else maxOf(LM_FLOOR * damp, minOf(LM_CAP * damp, staticWeight * c.score(id)))
        }

        /**
         * Điểm ngữ cảnh cho ứng viên TIẾNG ANH: chỉ phần cá nhân (từ hay gõ / từ hay theo
         * sau) — bigram tĩnh là của âm tiết Việt ("the" Anh không được ăn PMI của "the" Việt).
         */
        val englishWord: (String) -> Float = { w ->
            val c = count(w)
            val p = if (c > 0) minOf(PERSONAL_CAP, PERSONAL_WEIGHT * ln(1.0 + c).toFloat()) else 0f
            p + (if (w in next) NEXT_BONUS else 0f) + englishFreqShift(w)
        }

        /**
         * Có trigram thì ứng viên Việt chấm tần suất bằng [LM_LAMBDA_FREQ] thay vì λ decoder —
         * hạ y như vậy cho từ tiếng Anh để cán cân Việt/Anh (bias, margin) giữ nguyên.
         */
        private fun englishFreqShift(w: String): Float {
            if (lmCtx == null) return 0f
            val i = SwipeEnglish.indexOf(w)
            return if (i < 0) 0f else -(LAMBDA_FREQ - LM_LAMBDA_FREQ) * SwipeEnglish.lexicon.freq(i) / 255f
        }

        val word: (String) -> Float = { w ->
            val c = count(w)
            val p = if (c > 0) minOf(PERSONAL_CAP, PERSONAL_WEIGHT * ln(1.0 + c).toFloat()) else 0f
            p + (if (w in next) NEXT_BONUS else 0f) + static(w) + (if (w in curated) CURATED_BONUS else 0f)
        }

        val folded: ((String) -> Float)? =
            if (nextFolded.isEmpty() && lmCtx == null && curated.isEmpty()) null
            else { f -> foldedScore(f, word, lambdaFreq, clamp = lmCtx == null) }
    }

    /**
     * max(λ'·tần suất + ngữ cảnh) trên các âm tiết của [f] − tần suất decoder đã cộng. Không
     * có trigram: λ' = λ, kẹp ≥ 0 (như cũ); có trigram: λ' = [LM_LAMBDA_FREQ], không kẹp.
     */
    fun foldedScore(f: String, word: (String) -> Float, lambdaFreq: Float = LAMBDA_FREQ,
                    clamp: Boolean = true): Float {
        val i = SwipeLexicon.indexOf(f)
        if (i < 0) return 0f
        val best = SwipeDecoder.expand(f, 1, lambdaFreq, context = word).firstOrNull() ?: return 0f
        val d = best.score - LAMBDA_FREQ * SwipeLexicon.forms.freq[i].toFloat() / 255f
        return if (clamp) maxOf(0f, d) else d
    }

    private val LAMBDA_FREQ = SwipeDecoder.Params().lambdaFreq

    const val NEXT_BONUS = 1.5f
    /**
     * Cặp chọn tay ([CuratedPairs.next] sau prev2, prev — Scripts/curated-pairs.txt): thưởng riêng, lớn
     * hơn từ kế tiếp cá nhân để phân định dấu cả khi cách đọc kia cũng nằm trong nextWords. = iOS
     * SwipeTyping.curatedBonus.
     */
    const val CURATED_BONUS = 3.0f
    const val PERSONAL_WEIGHT = 0.4f
    const val PERSONAL_CAP = 1.5f
    const val STATIC_DAMP = 0.5f
    /**
     * Trigram (vnlm.bin, [SyllableLM]): điểm = s·[LM_WEIGHT] kẹp [[LM_FLOOR], [LM_CAP]] (có
     * bằng chứng ÂM), λ tần suất hạ còn [LM_LAMBDA_FREQ]. Chỉnh trên tập dev (docs/DATA-SOURCES.md):
     * heldout top-1 0.861 → 0.894, top-3 0.951 → 0.962 (decoder tầng 2). GIỐNG iOS SwipeTyping.lm*.
     */
    const val LM_WEIGHT = 0.15f
    const val LM_CAP = 1.0f
    const val LM_FLOOR = -1.0f
    const val LM_LAMBDA_FREQ = 1.0f

    fun context(model: UserLangModel?, prev1: String?, prev2: String?,
                english: SwipeEnglishPrior? = null,
                lm: SyllableLM? = SyllableLM.shared, properNouns: Boolean = true,
                filterSensitive: Boolean = SwipeVocab.filterSensitive): Context {
        // Lọc bật ⇒ cặp / bộ ba nhạy cảm (SensitiveWords.pairs / triples: seed "sờ chim", "ngu như chó") không
        // thưởng ngữ cảnh; + chuỗi seed ba từ (SensitiveWords.chain). = iOS contextSet.
        val next = if (model != null && prev1 != null)
            SensitiveWords.dropPairs(SensitiveWords.chain(prev1, prev2) + model.nextWords(prev1, prev2, 24), prev1,
                filterSensitive, prev2).map { it.lowercase() }.toSet()
        else emptySet()
        val count: (String) -> Int = if (model == null) { _ -> 0 } else { w -> model.count(w) }
        val learned: ((String) -> String?)? = model?.let { m -> { k: String -> m.learnedCase(k) } }
        return Context(next, next.mapTo(HashSet()) { fold(it) }, count, prev1, english, prev2, lm,
            learnedCase = learned, properNouns = properNouns)
    }

    /** Chế độ Tiếng Anh (vuốt phím cách): chỉ giữ ứng viên tiếng Anh. Giống iOS SwipeTyping.englishOnly. */
    fun englishOnly(cands: List<SwipeCandidate>): List<SwipeCandidate> = cands.filter { it.lang == SwipeLang.EN }

    /** Từ hiển thị của một ứng viên: tiếng Anh = chính nó; Việt = bung dấu. */
    private fun wordsFor(c: SwipeCandidate, limit: Int, wordCtx: ((String) -> Float)?,
                         lambdaFreq: Float = LAMBDA_FREQ): List<String> =
        if (c.lang == SwipeLang.EN) listOf(c.folded)
        else SwipeDecoder.expand(c.folded, limit, lambdaFreq, context = wordCtx).map { it.word }

    /**
     * Ứng viên không dấu (đã xếp) → top-1 có dấu + biến thể: dấu khác của dạng top-1 và
     * dạng top-2/3 (cho/co), xen kẽ, tối đa [MAX_ALTERNATIVES]. null nếu không có gì.
     * [lambdaFreq] = [Context.lambdaFreq] (hạ khi có trigram).
     */
    fun choose(cands: List<SwipeCandidate>, wordCtx: ((String) -> Float)?, case: Case = Case.LOWER,
               lambdaFreq: Float = LAMBDA_FREQ, proper: (String) -> String = { it }): SwipeChoice? {
        val wordsFor = { c: SwipeCandidate, limit: Int, ctx: ((String) -> Float)? -> wordsFor(c, limit, ctx, lambdaFreq) }
        var best: List<String> = emptyList()
        var bestIdx = -1
        for ((i, c) in cands.withIndex()) {
            best = wordsFor(c, 8, wordCtx)
            if (best.isNotEmpty()) { bestIdx = i; break }
        }
        if (bestIdx < 0) return null
        val lead = cands[bestIdx].lang
        val word = best[0]
        val variants = best.drop(1)
        val english = HashSet<String>()
        if (lead == SwipeLang.EN) english.add(word)
        val others = ArrayList<String>()
        for (c in cands.drop(bestIdx + 1)) {
            if (others.size >= 2) break
            wordsFor(c, 1, wordCtx).firstOrNull()?.let {
                others.add(it)
                if (c.lang == SwipeLang.EN) english.add(it)
            }
        }
        val alts = LinkedHashSet<String>()
        var vi = 0; var oi = 0
        // Thứ tự: biến thể dấu tốt nhất (slot giữa), dạng top-2, biến thể kế, dạng top-3…
        while (alts.size < MAX_ALTERNATIVES && (vi < variants.size || oi < others.size)) {
            if (vi < variants.size) alts.add(variants[vi++])
            if (alts.size < MAX_ALTERNATIVES && oi < others.size) alts.add(others[oi++])
        }
        alts.remove(word)
        // Luôn có 1 phương án ngôn ngữ kia nếu decoder có (the ↔ thế): thay phương án cuối.
        val isOther = { w: String -> (w in english) != (lead == SwipeLang.EN) }
        if (alts.none(isOther)) {
            val c = cands.drop(bestIdx + 1).firstOrNull { it.lang != lead && wordsFor(it, 1, wordCtx).isNotEmpty() }
            val w = c?.let { wordsFor(it, 1, wordCtx)[0] }
            if (w != null && w != word) {
                if (c.lang == SwipeLang.EN) english.add(w) else english.remove(w)
                alts.remove(w)
                if (alts.size >= MAX_ALTERNATIVES) alts.remove(alts.last())
                alts.add(w)
            }
        }
        val cased = { w: String -> applyCase(w, case, proper) }
        return SwipeChoice(cased(word), alts.map(cased),
            lead == SwipeLang.EN, alts.filter { it in english }.mapTo(HashSet()) { cased(it) },
            shifted = applyCase(word, case))
    }

    /** Chỉ Shift (không tên riêng) — giữ cho công cụ/test cũ. */
    fun applyCase(w: String, case: Case): String = applyCase(w, case) { it }

    /**
     * Dạng chèn của từ vuốt (chữ thường từ decoder): trước hết dạng tên riêng [proper] (hoa/thường
     * đã học ⊕ [DisplayCase] như thanh gợi ý — "iphone" → "iPhone", "nam" sau "việt" → "Nam"), rồi
     * Shift: Caps Lock ⇒ HOA HẾT; Shift một-lần / đầu câu ⇒ hoa chữ đầu, NHƯNG từ đã có chữ hoa giữ
     * nguyên ("iPhone" đầu câu vẫn "iPhone"); không bao giờ hạ chữ hoa. = iOS SwipeCase.apply(proper:).
     */
    fun applyCase(w: String, case: Case, proper: (String) -> String): String {
        val base = proper(w)
        return when (case) {
            Case.LOWER -> base
            Case.FIRST -> if (base.codePoints().anyMatch { Character.isUpperCase(it) || Character.isTitleCase(it) }) base
                else Cp.capitalizeFirst(base)
            Case.ALL -> base.uppercase()
        }
    }

    /**
     * Dấu cách treo: cần chèn " " trước từ vuốt khi ký tự liền trước là chữ/số/dấu câu
     * đóng. Không ở đầu ô, sau khoảng trắng/xuống dòng, sau ngoặc/nháy mở. Không đọc
     * được (null) ⇒ không thêm.
     */
    fun needsLeadingSpace(before: String?): Boolean {
        if (before.isNullOrEmpty()) return false
        val cp = before.codePointBefore(before.length)
        if (Character.isWhitespace(cp) || Character.isSpaceChar(cp)) return false
        return cp.toChar() !in OPENERS
    }

    private const val OPENERS = "([{\"'“‘«/-@#_–—"
}

/**
 * Dấu cách treo cho phím KÝ HIỆU (số, emoji, ngoặc…) ngay sau từ vuốt — chưa phím nào xen
 * vào. Từ vuốt chèn không kèm dấu cách sau, nên số / emoji / ký hiệu tiền tệ / ngoặc-nháy MỞ
 * (mở "từ" mới) cần " " trước: vuốt "mua" + 2 → "mua 2", không "mua2". Dấu câu đóng
 * (. , ! ? ; : ) ” …), nháy thẳng, ký hiệu nối (- / @ # _ % …) vẫn dính từ như cũ. Chữ cái
 * không qua đây (phím chữ sau từ vuốt có luật riêng: phím dấu Telex sửa từ vuốt).
 * [before] đọc được ⇒ theo [SwipeSuggest.needsLeadingSpace] (đã có khoảng trắng / ngoặc mở
 * ⇒ không thêm); null ⇒ tin trạng thái (đuôi là từ vuốt). = iOS SwipeSpacing.spaceBefore.
 */
object SwipeSpacing {
    private const val OPENERS = "([{“‘«"

    fun spaceBefore(text: String, afterSwipe: Boolean, before: String?): Boolean {
        if (!afterSwipe || text.isEmpty() || !startsWord(text)) return false
        return before == null || SwipeSuggest.needsLeadingSpace(before)
    }

    /** Ký tự đầu [text] mở một "từ" mới (cần tách khỏi từ trước bằng dấu cách). */
    fun startsWord(text: String): Boolean {
        val cp = text.codePointAt(0)
        if (cp in '0'.code..'9'.code) return true
        if (cp < 0x10000 && cp.toChar() in OPENERS) return true
        val type = Character.getType(cp)
        if (type == Character.CURRENCY_SYMBOL.toInt()) return true
        // emoji: ký hiệu ngoài BMP (😀 👍) hoặc ký hiệu kèm VS16 (❤️)
        return type == Character.OTHER_SYMBOL.toInt() &&
            (Character.isSupplementaryCodePoint(cp) || text.contains('️'))
    }
}
