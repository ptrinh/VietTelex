// Port of TelexCore/Sources/TelexCore/TelexEngine.swift (1:1, behaviour identical —
// verified by the golden corpus generated from the Swift engine, see GenGolden).
//
// Hot path works over fixed-capacity (32) primitive arrays allocated once per
// instance: raw keys, the incremental parse state (letters as parallel arrays),
// render scratch and diff buffers. Per keystroke the only allocation is the
// `TelexAction.Replace` + its insert String when the screen actually changes —
// exactly what the Swift engine allocates.
//
// Swift `TelexEngine` is a value type; this is a class. Use `copy()` for an
// independent snapshot.
package com.viettelex.telexcore

/**
 * A boundary that restored a word to raw keys although its Vietnamese composition was a
 * real syllable ("hí" → "his", "NÁ" → "NAS") — Swift `RestoreUndo`. An immediate ⌫ may
 * put [vietnamese] back in place of [restored] (the caller's boundary char follows both).
 */
data class RestoreUndo(val restored: String, val vietnamese: String)

sealed class TelexAction {
    /** Not handled by the engine; let the system insert the character. */
    object Passthrough : TelexAction() { override fun toString() = "Passthrough" }
    /** Replace `backspaces` trailing characters already on screen with `insert`. */
    data class Replace(val backspaces: Int, val insert: String) : TelexAction()
    /** Nothing to do. */
    object None : TelexAction() { override fun toString() = "None" }
}

/** Vietnamese tone (Swift `Tone`; ordinal == Swift rawValue). */
enum class Tone { NONE, ACUTE, GRAVE, HOOK, TILDE, DOT }

class TelexEngine {

    /** "Bỏ dấu tự do" (free mark placement). */
    var freeMarking = false
    /** Modern tone placement for open oa/oe/uy (hoà, khoẻ, thuý). */
    var modernTone = false
    /** Live spell-check: stop transforming once the word can't be Vietnamese. */
    var liveSpellCheck = false
    /**
     * Eager English restore (Swift `eagerEnglishRestore`): at the freeze moment, a raw prefix in
     * [EnglishFreezePrefixes] restores the whole word to raw ("goog", not "gôg"). Callers pass
     * their effective auto-restore. Engine default OFF.
     */
    var eagerEnglishRestore = false
    /** Simple Telex: a standalone `w` stays literal. */
    var simpleTelex = false
    /** Teencode spelling (w→qu, z/dz→d, k before a/o/u, informal rimes). Engine default ON. */
    var teencode = true
    /** Quick Telex: cc→ch, gg→gi, kk→kh, nn→ng, qq→qu, pp→ph, tt→th (word-initial). */
    var quickTelex = false
    /** Bracket vowels: `[`→ơ, `]`→ư, `{`/`}` uppercase. */
    var bracketVowels = false
    /** VNI input method (digits carry the diacritics). */
    var vniMode = false
    /** Context-based English decision (experimental). */
    var contextualEnglish = false
    /**
     * An English RUN is open (Swift `previousWordEnglish`): set by an English FUNCTION word
     * or by the second English word in a row — never by one content word alone.
     */
    var previousWordEnglish = false
        private set
    /** Previous word was a lone English CONTENT word with no run open (Swift `englishCandidate`). */
    private var englishCandidate = false
    /** Predecessor-gate bits the previous committed word satisfies (Swift `previousGateBits`). */
    private var previousGateBits = 0
    /** Force-restore English words that collide with valid syllables. Default ON. */
    var englishWordRestore = true
    /** Prefer a valid Vietnamese syllable over a standalone collision-table hit. */
    var collisionPrefersVietnamese = false
    /**
     * Retroactive English correction (Swift `retroactiveEnglish`, EXPERIMENTAL, default OFF):
     * when an English run becomes certain, collision words composed as Vietnamese right before
     * it ("Hí cả í very fast") are rewritten to their raw keys. Inert unless
     * [contextualEnglish] is on (and in VNI). Callers report boundary characters with
     * [noteBoundaryCharacter] and apply [takeRetroCorrection] after each commit.
     */
    var retroactiveEnglish = false
    /** [retroactiveEnglish] is in effect (needs contextual English, Telex only). */
    val retroactiveEnglishActive: Boolean get() = retroactiveEnglish && contextualEnglish && !vniMode

    /**
     * TỪ TRÙNG THEO TẦN SUẤT + LẬT LẠI (Swift `englishByFrequency`, EXPERIMENTAL, mặc định TẮT —
     * Cài đặt → Thử nghiệm). Một từ mà phím gõ vừa là từ tiếng Anh vừa ra âm tiết Việt hợp lệ, ở
     * ĐẦU cụm (không có từ Việt ngay trước, chưa có mạch tiếng Anh): chọn tiếng Anh khi âm tiết
     * Việt HIẾM (tần suất < [FREQUENCY_VIETNAMESE_FLOOR]) và từ Anh phổ biến hơn ≥ ~10 lần
     * ([FREQUENCY_MARGIN] trên thang log chung — [EnglishFrequency]): "His car is fast." đúng ngay
     * từ "His". Từ kế cho thấy câu là tiếng Việt ⇒ LẬT LẠI từ trước về chữ Việt bằng đúng đường
     * sửa ngược ([RetroCorrection.flipBack], integrator TỰ ÁP kể cả khi sửa ngược chỉ mời): từ kế
     * lặp lại y phím ("hí hí", "Hí Hí") hoặc cùng từ trước thành cặp âm tiết Việt hay đi liền
     * ("hí hửng", "lát nữa"). Cần sửa ngược đang chạy ([retroactiveEnglishActive]) — không thì
     * trơ. Tắt = không đổi gì; chi phí khi tắt: một phép thử Boolean ở mỗi lần chốt từ.
     */
    var englishByFrequency = false
    /** [englishByFrequency] is actually in effect. */
    val englishByFrequencyActive: Boolean get() = englishByFrequency && retroactiveEnglishActive

    /**
     * Tự thêm dấu mũ (Swift `autoCircumflex`, issue #166): khi từ ĐÃ có phím thanh mà vần không
     * mũ không tồn tại trong tiếng Việt, còn vần có mũ thì hợp lệ, hiện luôn dấu mũ — "vietj"/
     * "viejt" → việt, "nguyenx" → nguyễn, "benhj" → bệnh, "keuf" → kều, "hues" → huế, "luanj" →
     * luận, "xuats" → xuất. Bốn nhóm vần: iê/yê/uyê, ê trước nh/ch/u, uê, uâ (sau "qu" thì vần
     * không mũ là từ thật — quan, quát, què — nên giữ nguyên). Chỉ là một bước ở khâu HIỂN THỊ
     * ([render]), trạng thái parse không đổi: gõ tiếp "ee"/"aa", xoá, huỷ thanh vẫn y như cũ.
     * Tắt (mặc định) = không đổi gì; chi phí khi tắt: một phép thử Boolean mỗi lần render.
     */
    var autoCircumflex = false

    /**
     * The last committed word in the current phrase was Vietnamese (read only by the frequency
     * rule: a colliding word right after Vietnamese stays Vietnamese — "sao í", "cho con bú").
     * Sentence punctuation / newline / [resetContext] clear it.
     */
    private var previousWordVietnamese = false

    // Retroactive-English session state (Swift retroHistory / retroGap / retroPending…).
    private val retroHistory = ArrayList<RetroWord>(RetroEnglish.HISTORY_CAPACITY)
    private var retroGap = 0
    private var retroPending: RetroCorrection? = null
    private var retroPendingPicks: IntArray? = null

    // Raw keystrokes (ascii, case preserved).
    private val raw = IntArray(CAPACITY)
    private var rawCount = 0
    private var overflowed = false

    // Current on-screen composition (scalar values).
    private val out = IntArray(CAPACITY)
    private var outCount = 0

    // Scratch buffers.
    private val scratch = IntArray(CAPACITY)
    private val rBase = IntArray(CAPACITY)       // renderLetters
    private val rMark = IntArray(CAPACITY)
    private val rUpper = BooleanArray(CAPACITY)
    private val basesScratch = IntArray(CAPACITY)
    private val rawLetter = IntArray(CAPACITY) { -1 }
    private val toneKeys = IntArray(CAPACITY)
    private val vowelIdx = IntArray(CAPACITY)
    private val valBuf = IntArray(CAPACITY + 1)  // composedIsValidSyllable stack twin
    private val headBuf = IntArray(CAPACITY + 1) // isValidHead stack twin
    private val wordBuf = IntArray(CAPACITY)     // lowercase word for dictionary probes

    // Incremental parse state.
    private val lBase = IntArray(CAPACITY)       // letters
    private val lMark = IntArray(CAPACITY)
    private val lUpper = BooleanArray(CAPACITY)
    private var pCount = 0
    private var pTone = T.NONE
    private var pToneKeyCount = 0
    private var pCancelled = false
    private var pToneCancelSpan = 0
    private var pToneCancelAt = -1
    /** A circumflex doubler cancelled a hat it reached back to across letters ("seem" + e). */
    private var pMarkCancelReachedBack = false
    private var pProcessed = 0
    private var pFreeMarking = false
    private var pSimpleTelex = false
    private var pQuickTelex = false
    private var pVniMode = false
    private var pBracketVowels = false
    private var pLiveSpellCheck = false

    private var disabledAtCount = Int.MAX_VALUE
    private var markCancelled = false
    private var toneCancelAt = -1
    private var toneCancelSpan = 0
    private var pFoldTones = false
    // Current parse was built with pFoldTones (freeze folded a pending tone) — see Swift.
    private var tonesFolded = false
    // Kept-tone freeze (PR #133): a marked word + visible tone stays as shown — see Swift.
    private var freezeKeepsTone = false
    // Letter count when the parse reached raw index disabledAtCount (-1 before) — see Swift.
    private var pFreezeLetters = -1
    private var lastEffTone = T.NONE
    // Lần render gần nhất có tự thêm dấu mũ ([autoCircumflex]). Đọc ở ranh giới từ.
    private var inferredCircumflex = false
    private val circBuf = IntArray(CAPACITY)     // inferCircumflex scratch (Swift temporary allocation)
    private var upperToneKey = false
    // Word frozen by feed()'s upper-case tone rule (disabledAtCount = 0) — see Swift.
    private var upperToneFrozen = false
    // Raw index of the initials suffix ("PhuwowngTH" → PhươngTH, issue #138), -1 none — see Swift.
    private var initialsSplitAt = -1

    // Re-open snapshot.
    private val reopenRaw = IntArray(CAPACITY)
    private val reopenOut = IntArray(CAPACITY)
    private var reopenRawCount = 0
    private var reopenOutCount = 0
    private var reopenPrevEnglish = false
    private var reopenCandidate = false
    private var reopenGateBits = 0

    // ⌫-undo of a boundary restore (Swift `restoreUndo`).
    private var restoreUndo: RestoreUndo? = null
    // Glued separators / digits (Swift noteGlue): 0 unknown, 1 Vietnamese/capitalized, 2 code-like.
    private var lastWordKind = 0
    private var noteSinceWord = true
    private var pendingGlue = 0   // 0 none, 1 separator, 2 digit
    private var wordGlue = 0
    private val keyBuf = IntArray(2 * CAPACITY + 1)   // CommonSyllables probe
    private val freqBuf = IntArray(4 * CAPACITY + 2)  // EnglishFrequency pair probe (Swift stack twin)

    val isEmpty: Boolean get() = rawCount == 0

    /** Deep copy (Swift value semantics). */
    fun copy(): TelexEngine = TelexEngine().also { copyInto(it) }

    /** Ghi đè toàn bộ trạng thái của [e] bằng bản này — checkpoint không cấp phát (EngineBridge.undoLastLetter). */
    fun copyInto(e: TelexEngine) {
        e.freeMarking = freeMarking; e.modernTone = modernTone; e.liveSpellCheck = liveSpellCheck
        e.eagerEnglishRestore = eagerEnglishRestore
        e.simpleTelex = simpleTelex; e.teencode = teencode; e.quickTelex = quickTelex
        e.bracketVowels = bracketVowels; e.vniMode = vniMode; e.contextualEnglish = contextualEnglish
        e.previousWordEnglish = previousWordEnglish; e.englishWordRestore = englishWordRestore
        e.englishCandidate = englishCandidate; e.previousGateBits = previousGateBits
        e.collisionPrefersVietnamese = collisionPrefersVietnamese
        e.retroactiveEnglish = retroactiveEnglish
        e.englishByFrequency = englishByFrequency; e.previousWordVietnamese = previousWordVietnamese
        e.autoCircumflex = autoCircumflex; e.inferredCircumflex = inferredCircumflex
        e.retroHistory.clear(); for (w in retroHistory) e.retroHistory.add(w.copy())
        e.retroGap = retroGap; e.retroPending = retroPending; e.retroPendingPicks = retroPendingPicks
        raw.copyInto(e.raw); e.rawCount = rawCount; e.overflowed = overflowed
        out.copyInto(e.out); e.outCount = outCount
        scratch.copyInto(e.scratch)
        rBase.copyInto(e.rBase); rMark.copyInto(e.rMark); rUpper.copyInto(e.rUpper)
        basesScratch.copyInto(e.basesScratch); rawLetter.copyInto(e.rawLetter)
        toneKeys.copyInto(e.toneKeys); vowelIdx.copyInto(e.vowelIdx)
        lBase.copyInto(e.lBase); lMark.copyInto(e.lMark); lUpper.copyInto(e.lUpper)
        e.pCount = pCount; e.pTone = pTone; e.pToneKeyCount = pToneKeyCount
        e.pCancelled = pCancelled; e.pToneCancelSpan = pToneCancelSpan; e.pToneCancelAt = pToneCancelAt
        e.pProcessed = pProcessed; e.pFreeMarking = pFreeMarking; e.pSimpleTelex = pSimpleTelex
        e.pQuickTelex = pQuickTelex; e.pVniMode = pVniMode; e.pBracketVowels = pBracketVowels
        e.pLiveSpellCheck = pLiveSpellCheck; e.disabledAtCount = disabledAtCount
        e.markCancelled = markCancelled; e.toneCancelAt = toneCancelAt; e.toneCancelSpan = toneCancelSpan
        e.pFoldTones = pFoldTones; e.tonesFolded = tonesFolded; e.lastEffTone = lastEffTone; e.upperToneKey = upperToneKey
        e.upperToneFrozen = upperToneFrozen; e.initialsSplitAt = initialsSplitAt
        e.freezeKeepsTone = freezeKeepsTone; e.pFreezeLetters = pFreezeLetters
        reopenRaw.copyInto(e.reopenRaw); reopenOut.copyInto(e.reopenOut)
        e.reopenRawCount = reopenRawCount; e.reopenOutCount = reopenOutCount
        e.reopenPrevEnglish = reopenPrevEnglish
        e.reopenCandidate = reopenCandidate; e.reopenGateBits = reopenGateBits
        e.restoreUndo = restoreUndo; e.lastWordKind = lastWordKind; e.noteSinceWord = noteSinceWord
        e.pendingGlue = pendingGlue; e.wordGlue = wordGlue
    }

    // MARK: - Public entry points

    /** RE-EDIT an already committed word; true only when the word round-trips exactly. */
    fun seed(word: String): Boolean {
        reset()
        if (word.isEmpty() || word.codePointCount(0, word.length) > CAPACITY / 2) return false
        val keys = seedKeystrokes(word, vniMode) ?: return false
        if (keys.length > CAPACITY) { reset(); return false }
        for (ch in keys) feed(ch)
        if (composed != word) { reset(); return false }
        return true
    }

    /** Feed one typed character. Only ascii letters compose. */
    fun feed(ch: Char): TelexAction {
        if (restoreUndo != null) restoreUndo = null
        val ascii = ch.code
        if (ascii >= 128 ||
            !(isLetter(ascii) || (vniMode && isDigit(ascii)) || (bracketVowels && bracketBase(ascii) >= 0))
        ) return TelexAction.Passthrough
        if (rawCount >= CAPACITY) { overflowed = true; return TelexAction.Passthrough }

        if (rawCount == 0) {
            reopenRawCount = 0; reopenOutCount = 0
            if (retroPending != null) retroPending = null
            wordGlue = pendingGlue
            pendingGlue = 0
        }

        raw[rawCount] = ascii
        rawCount++

        if (pLiveSpellCheck != liveSpellCheck) {
            recomputeFreeze()
            rebuildFrozenAware()
        } else if (pProcessed != rawCount - 1 ||
            pFreeMarking != freeMarking || pSimpleTelex != simpleTelex ||
            pQuickTelex != quickTelex || pVniMode != vniMode ||
            pBracketVowels != bracketVowels
        ) {
            rebuildFrozenAware()
        } else {
            parseStep(rawCount - 1)
            pProcessed = rawCount
        }

        var newCount = render()
        snapshotCancel()

        if (disabledAtCount == Int.MAX_VALUE && upperToneKey) {
            disabledAtCount = 0
            upperToneFrozen = true
            rebuildParseState()
            tonesFolded = false
            newCount = render()
            snapshotCancel()
        }

        if (liveSpellCheck && disabledAtCount == Int.MAX_VALUE && !prefixIsValid(newCount) &&
            elongationHeadCount(newCount, pTone) <= 0
        ) {
            disabledAtCount = rawCount
            freezeKeepsTone = false
            if (eagerRestoreApplies(newCount)) {
                disabledAtCount = 0
                rebuildParseState()
                tonesFolded = false
                newCount = render()
                snapshotCancel()
            } else if (pTone != T.NONE && prefixKeepsTone(rawCount - 1)) {
                // Marked word + visible tone (PR #133): keep it as shown, this key on literal.
                disabledAtCount = rawCount - 1
                freezeKeepsTone = true
                rebuildParseState()
                tonesFolded = false
                newCount = render()
                snapshotCancel()
            } else if (pTone != T.NONE) {
                pFoldTones = true
                rebuildParseState()
                pFoldTones = false
                tonesFolded = true
                newCount = render()
                snapshotCancel()
            }
        }

        // Eager English restore, deferred to key minLength when the word froze earlier ("ưin").
        if (eagerEnglishRestore && disabledAtCount != Int.MAX_VALUE && disabledAtCount > 0 &&
            disabledAtCount < EnglishFreezePrefixes.minLength &&
            rawCount == EnglishFreezePrefixes.minLength && eagerRestoreApplies(newCount)
        ) {
            disabledAtCount = 0
            rebuildParseState()
            tonesFolded = false
            newCount = render()
            snapshotCancel()
        }

        if (liveSpellCheck && disabledAtCount != Int.MAX_VALUE && !upperToneFrozen &&
            rawCount >= 2 && raw[rawCount - 1] == raw[rawCount - 2]
        ) {
            recomputeFreeze()
            rebuildFrozenAware()
            newCount = render()
            snapshotCancel()
        }

        // Initials suffix (issue #138), decided last — see Swift.
        if (applyInitialsSplit()) {
            newCount = render()
            snapshotCancel()
        }

        if (newCount == outCount + 1 && scratch[newCount - 1] == ascii &&
            commonPrefixLength(outCount) == outCount
        ) {
            copyOut(newCount)
            return TelexAction.Passthrough
        }

        val action = diff(newCount)
        copyOut(newCount)
        return action
    }

    private fun snapshotCancel() {
        markCancelled = pCancelled
        toneCancelAt = pToneCancelAt
        toneCancelSpan = pToneCancelSpan
    }

    /** Backspace: delete the whole last DISPLAYED character, then reconcile. */
    fun backspace(): TelexAction {
        if (restoreUndo != null) restoreUndo = null
        if (rawCount <= 0) {
            // The app deletes committed text: the retro history no longer matches the screen.
            if (retroHistory.isNotEmpty() || retroPending != null) retroClear()
            return TelexAction.Passthrough
        }
        if (overflowed) return TelexAction.Passthrough

        rebuildFrozenAware()
        render()

        if (pCount == 0) {
            rawCount -= 1
        } else {
            val last = pCount - 1
            var w = 0
            for (r in 0 until rawCount) {
                if (rawLetter[r] != last) { raw[w] = raw[r]; w++ }
            }
            rawCount = w
        }

        recomputeFreeze()
        rebuildFrozenAware()
        applyInitialsSplit()
        val newCount = render()
        snapshotCancel()
        val action = diff(newCount)
        copyOut(newCount)
        return action
    }

    /**
     * Word boundary reached. Optionally auto-restore raw keystrokes. Resets the word.
     * [boundary] = the character ending the word when the caller knows it (Swift
     * `commitBoundary(autoRestore:boundary:)`): an apostrophe restores an English
     * contraction stem ("doesn" before 't). 0 = unknown (old behaviour).
     */
    fun commitBoundary(autoRestore: Boolean, boundary: Char = '\u0000'): TelexAction {
        restoreUndo = null
        try {
            if (rawCount <= 0) { reopenRawCount = 0; reopenOutCount = 0; return TelexAction.None }
            if (overflowed) {
                if (contextualEnglish) clearEnglishContext()
                reopenRawCount = 0; reopenOutCount = 0
                if (retroHistory.isNotEmpty() || retroPending != null) retroClear()
                return TelexAction.None
            }
            val wantsRestore = outCount > 0 &&
                (needsStandaloneWRunRestore() || (autoRestore && shouldRestoreRaw(boundary)))
            var action: TelexAction = TelexAction.None
            if (wantsRestore && compositionDiffersFromRaw()) {
                val limit = minOf(rawCount, outCount)
                var lcp = 0
                while (lcp < limit && raw[lcp] == out[lcp]) lcp++
                val backspaces = outCount - lcp
                val sb = StringBuilder(rawCount - lcp)
                for (i in lcp until rawCount) sb.append(raw[i].toChar())
                action = TelexAction.Replace(backspaces, sb.toString())
            }
            // Teencode "Dạa" (Swift isToneThenATail): rewrite only the last character.
            val elongate = !wantsRestore && outCount > 0 && isToneThenATail()
            if (elongate) action = TelexAction.Replace(1, elongatedTail())
            // A restore that changed nothing on screen ("hoc", "tien") keeps its snapshot.
            captureReopen((wantsRestore && compositionDiffersFromRaw()) || elongate)
            noteCommittedWord(wantsRestore)
            if (retroactiveEnglish || retroHistory.isNotEmpty()) retroRecord(wantsRestore, elongate)
            updateContext(wantsRestore)
            return action
        } finally {
            resetWord()
        }
    }

    private fun captureReopen(restored: Boolean) {
        if (restored || rawCount <= 0) { reopenRawCount = 0; reopenOutCount = 0; return }
        for (i in 0 until rawCount) reopenRaw[i] = raw[i]
        for (i in 0 until outCount) reopenOut[i] = out[i]
        reopenRawCount = rawCount
        reopenOutCount = outCount
        reopenPrevEnglish = previousWordEnglish
        reopenCandidate = englishCandidate
        reopenGateBits = previousGateBits
    }

    /** Discard the re-open snapshot. */
    fun forgetLastCommit() {
        reopenRawCount = 0
        reopenOutCount = 0
        restoreUndo = null
        clearGlue()
        if (retroHistory.isNotEmpty() || retroPending != null) retroClear()   // text changed under us
    }

    /** True while `reopenLastCommit()` has something to put back. */
    val canReopenLastCommit: Boolean get() = rawCount == 0 && reopenRawCount > 0

    /** RE-OPEN the word the last boundary committed (⌫ on the boundary char). */
    fun reopenLastCommit(): String? {
        if (!canReopenLastCommit) return null
        val n = reopenRawCount
        val expected = reopenOutCount
        val prevEnglish = reopenPrevEnglish
        val prevCandidate = reopenCandidate
        val prevGateBits = reopenGateBits
        // reset() clears the snapshot counts but not the buffers — replay from them.
        reset()
        previousWordEnglish = prevEnglish
        englishCandidate = prevCandidate
        previousGateBits = prevGateBits
        for (i in 0 until n) feed(reopenRaw[i].toChar())
        if (rawCount != n || outCount != expected) { reset(); return null }
        for (i in 0 until outCount) if (out[i] != reopenOut[i]) { reset(); return null }
        return composed
    }

    // MARK: - Boundary restore decision (non-mutating apart from scratch buffers)

    /** A standalone run of three or more `w` keys is literal `www` text, regardless
     *  of the general auto-restore preference (mirrors Swift needsStandaloneWRunRestore). */
    private fun needsStandaloneWRunRestore(): Boolean {
        if (rawCount < 3 || !compositionDiffersFromRaw()) return false
        for (i in 0 until rawCount) if ((raw[i] or 0x20) != 'w'.code) return false
        return true
    }

    private fun shouldRestoreRaw(boundary: Char = '\u0000'): Boolean {
        if (shouldRestoreRawBase()) return true
        if (isApostrophe(boundary) && isContractionStemBeforeApostrophe()) return true
        return englishByFrequency && frequencyPrefersEnglish()
    }

    /** ' typed, or ’ (smart quote). */
    private fun isApostrophe(c: Char): Boolean = c == '\'' || c == '’'

    /** English contraction stem right before an apostrophe (Swift twin): raw keys, or raw
     *  minus a final `n` (n't), on EnglishContextWords.contractionStems. Boundary-only. */
    private fun isContractionStemBeforeApostrophe(): Boolean {
        if (!compositionDiffersFromRaw()) return false
        val n = lowerAsciiInto(raw, rawCount, EnglishContextWords.maxLength)
        if (n <= 0) return false
        if (EnglishContextWords.contractionStems.contains(wordBuf, n)) return true
        return n >= 2 && wordBuf[n - 1] == 'n'.code && EnglishContextWords.contractionStems.contains(wordBuf, n - 1)
    }

    /** Every restore rule except the frequency rule ([englishByFrequency]). */
    private fun shouldRestoreRawBase(): Boolean {
        if (initialsSplitAt >= 0) return false   // "PhươngTH" (issue #138) — see Swift
        if (isListedCapsAcronym()) return true     // "ASAP", "WWDC" — see Swift
        if (markCancelled) {
            if (composedIsValidSyllable()) return false
            if (toneCancelSpan > 1) {
                return !composedIsRecognizedEnglish() || rawIsEnglishContextWord(false)
            }
            if (toneCancelAt >= 0 && toneCancelAt < rawCount - 1 && rawIsEnglishCollision()) return true
            // Vowel-doubler cancel that reached back ("seemed" → "semed"): dictionary wins.
            if (pMarkCancelReachedBack && rawIsEnglishCollision()) return true
            if (isTeencodeKeep()) return false
            // Mark doubler + tone folded at the freeze ("cheese" → "chese"): restore raw.
            if (toneCancelAt < 0 && tonesFolded) return true
            return composedHasDiacritic()
        }
        // Lật lại (englishByFrequency): từ trước vừa bị luật tần suất đổi sang tiếng Anh, từ này
        // lặp lại y phím ("His His" = hí hí) hoặc cùng nó thành cặp âm tiết Việt hay gặp ⇒ GIỮ
        // tiếng Việt (rồi từ trước được lật lại ở retroRecord), trước mọi luật khôi phục Anh.
        if (englishByFrequency && frequencyKeepsVietnamese()) return false
        if (wordGlue != 0 && glueRestores()) return true   // "my_var", "100W" — see Swift
        // Tự thêm dấu mũ biến một âm tiết SAI (trước đây luôn được trả về phím gốc) thành âm
        // tiết đúng, nên bảng collision chưa biết các từ này: phím gốc có cách đọc tiếng Anh
        // ("diets", "hues") thì trả về phím gốc như trước khi có tính năng.
        if (inferredCircumflex && rawHasEnglishReading()) return true
        // Đuôi -k (ták/ák/rík) không thắng bảng collision (issue #127) — song sinh Swift.
        if (rawIsEnglishCollision() && !(collisionPrefersVietnamese && composedIsValidSyllable() && !composedEndsWithK())) return true
        if (upperToneKey || rawIsEnglishException() ||
            (!composedIsValidSyllable() && !isTeencodeKeep() && !isVietnameseTypoKeep() &&
                !isHatInitialismKeep())
        ) return true
        if (isRareAllCapsAcronym()) return true
        if (contextualEnglish && previousWordEnglish &&
            (rawIsEnglishContextWord(true) || (collisionPrefersVietnamese && rawIsEnglishCollision())) &&
            predecessorGateAllows()
        ) return true
        return false
    }

    // MARK: - Frequency rule + flip-back (englishByFrequency, Swift twins)

    /** EnglishFrequency scores (packed, -1 = absent) of the raw keys; boundary-only, allocation-free. */
    private fun rawFrequencyScores(): Int {
        val n = lowerAsciiInto(raw, rawCount, EnglishFrequency.maxWordLength)
        return if (n > 0) EnglishFrequency.scores(wordBuf, n) else -1
    }

    /**
     * Luật tần suất: từ ĐẦU cụm (không mạch Anh, không từ Việt ngay trước), chữ trên màn hình là
     * âm tiết Việt hợp lệ có biến đổi, âm tiết đó hiếm và từ Anh phổ biến hơn hẳn. Không chạy khi
     * bật teencode (tần suất Việt đếm trên corpus đã CHUẨN HOÁ teencode: "bít gòi" → "bits gòi").
     */
    private fun frequencyPrefersEnglish(): Boolean {
        if (!englishByFrequencyActive || teencode || previousWordEnglish || previousWordVietnamese ||
            !compositionDiffersFromRaw() || !composedIsValidSyllable()
        ) return false
        val sc = rawFrequencyScores()
        if (sc < 0) return false
        val vn = EnglishFrequency.vn(sc)
        if (vn <= 0) return false
        return vn < FREQUENCY_VIETNAMESE_FLOOR && EnglishFrequency.en(sc) >= vn + FREQUENCY_MARGIN
    }

    /** The previous history word, if the frequency rule restored it and only spaces separate it. */
    private fun frequencyRestoredPrevious(): RetroWord? {
        if (!englishByFrequencyActive || retroGap < 1 || retroGap > RetroEnglish.MAX_GAP) return null
        val w = retroHistory.lastOrNull() ?: return null
        return if (w.byFrequency) w else null
    }

    /** The frequency-restored word TWO back, a Vietnamese word between ("hí ha hí hửng"). */
    private fun frequencyRestoredTwoBack(): RetroWord? {
        val n = retroHistory.size
        if (!englishByFrequencyActive || n < 2 || retroGap < 1 || retroGap > RetroEnglish.MAX_GAP ||
            !retroHistory[n - 2].byFrequency || retroHistory[n - 1].gap <= 0 || retroHistory[n - 1].english
        ) return null
        return retroHistory[n - 2]
    }

    /** Reduplication or a known Vietnamese pair with the frequency-restored previous word. */
    private fun frequencyKeepsVietnamese(): Boolean {
        val prev = frequencyRestoredPrevious() ?: return false
        if (!composedIsValidSyllable() || !compositionHasDiacritic()) return false
        return frequencyPairEvidence(prev, false)
    }

    /**
     * Same raw keys as [prev] (case-insensitive: "His His", "hí hí") or, unless
     * [reduplicationOnly], (prev, this composition) is in EnglishFrequency PAIRS. Allocation-free.
     */
    private fun frequencyPairEvidence(prev: RetroWord, reduplicationOnly: Boolean): Boolean {
        val p = freqBuf
        var n = 0
        val pr = prev.raw
        for (j in pr.indices) {
            if (n >= CAPACITY) return false
            var b = pr[j].code
            if (b in 'A'.code..'Z'.code) b = b or 0x20
            p[n++] = b
        }
        // Reduplication: identical raw keys.
        if (n == rawCount) {
            var same = true
            for (i in 0 until rawCount) {
                var b = raw[i]
                if (b in 'A'.code..'Z'.code) b = b or 0x20
                if (b != p[i]) { same = false; break }
            }
            if (same) return true
        }
        if (reduplicationOnly) return false
        p[n++] = '>'.code
        n = appendComposedTelexKey(p, n)
        return EnglishFrequency.hasPair(p, n)
    }

    /** Append the composition's Telex key (CommonSyllables spelling: "hửng" → "huwngr") at p[start…]. */
    private fun appendComposedTelexKey(p: IntArray, start: Int): Int {
        var n = start
        for (k in 0 until pCount) {
            p[n++] = rBase[k]
            when (rMark[k]) {
                Mark.CIRCUMFLEX -> p[n++] = rBase[k]
                Mark.BREVE, Mark.HORN -> p[n++] = 'w'.code
                Mark.BAR -> p[n++] = 'd'.code
            }
        }
        when (lastEffTone) {
            T.ACUTE -> p[n++] = 's'.code
            T.GRAVE -> p[n++] = 'f'.code
            T.HOOK -> p[n++] = 'r'.code
            T.TILDE -> p[n++] = 'x'.code
            T.DOT -> p[n++] = 'j'.code
        }
        return n
    }

    /**
     * At a commit that KEPT Vietnamese: should the frequency-restored previous word flip back?
     * Only on EVIDENCE — reduplication or a known pair (Swift `frequencyFlipDistance`). Returns
     * how many words back (1 or 2; 0 = no flip). Two back only for an exact repeat across one
     * Vietnamese word ("hí ha hí"). Boundary-only.
     */
    private fun frequencyFlipDistance(restored: Boolean): Int {
        if (restored || !composedIsValidSyllable()) return 0
        val prev = frequencyRestoredPrevious()
        if (prev != null) return if (frequencyPairEvidence(prev, false)) 1 else 0
        if (compositionHasDiacritic()) {
            val two = frequencyRestoredTwoBack()
            if (two != null && frequencyPairEvidence(two, true)) return 2
        }
        return 0
    }

    // MARK: - Glue / typo / acronym rules + restore undo (Swift twins, see TelexEngine.swift)

    private fun noteGlue(ch: Char) {
        val first = !noteSinceWord
        noteSinceWord = true
        pendingGlue = when (ch) {
            '_' -> 1
            '.', '/' -> if (first && lastWordKind == 2) 1 else 0
            in '0'..'9' -> 2
            else -> 0
        }
    }

    private fun clearGlue() {
        lastWordKind = 0
        noteSinceWord = true
        pendingGlue = 0
    }

    private fun noteCommittedWord(restored: Boolean) {
        if (rawCount <= 0) return
        val keptVietnamese = !restored && (compositionHasDiacritic() || composedIsValidSyllable())
        // A word glued to a number is a quantity ("5k", "2h"): "/" after it starts a Vietnamese unit ("5k/tháng").
        lastWordKind = if (keptVietnamese || isUpperAscii(raw[0]) || wordGlue == 2) 1 else 2
        noteSinceWord = false
        pendingGlue = 0
        if (restored && wordGlue == 0 && compositionDiffersFromRaw() && compositionHasDiacritic() &&
            (composedIsValidSyllable() || isTeencodeKeep())
        ) restoreUndo = RestoreUndo(rawKeystrokes, composed)
    }

    /** The ⌫-undo record of the commit that just happened (consumed). See Swift `takeRestoreUndo`. */
    fun takeRestoreUndo(): RestoreUndo? {
        val u = restoreUndo
        restoreUndo = null
        return u
    }

    /** Non-consuming look at [takeRestoreUndo]. */
    val pendingRestoreUndo: RestoreUndo? get() = restoreUndo

    /** The caller put the Vietnamese word back (⌫ right after a restore). See Swift. */
    fun restoreUndoApplied() {
        reset()
        clearEnglishContext()
    }

    private fun glueRestores(): Boolean {
        if (vniMode || pCount <= 0 || !compositionHasDiacritic()) return false
        if (wordGlue == 1) {
            for (k in 0 until pCount) if (rMark[k] != Mark.NONE) return false
            return true
        }
        for (k in 0 until pCount) {
            if (rBase[k] == 'u'.code && rMark[k] == Mark.HORN && letterCreatedByW(k)) return true
        }
        return false
    }

    private fun isVietnameseTypoKeep(): Boolean {
        if (vniMode || pCount < 3 || rawCount < 3) return false
        val last = pCount - 1
        if (rMark[last] != Mark.NONE || isVowelAscii(rBase[last]) || rUpper[last] != rUpper[last - 1]) return false
        var groups = 0
        var inVowel = false
        for (i in 0 until rawCount) {
            val v = isVowelAscii(lowercased(raw[i]))
            if (v && !inVowel) groups++
            inVowel = v
        }
        if (groups != 1) return false
        var hasMark = false
        for (k in 0 until last) {
            if (rMark[k] == Mark.NONE) continue
            if (rMark[k] == Mark.HORN && rBase[k] == 'u'.code && letterCreatedByW(k)) return false
            hasMark = true
        }
        if (!hasMark || !lettersAreCommonSyllable(last)) return false
        if (SyllableValidator.isValidPrefix(composed.lowercase(), teencode)) return false
        return !rawHasEnglishReading()
    }

    /**
     * Two-letter hat-vowel initialism ("AAL" → ÂL = âm lịch) — Swift twin `isHatInitialismKeep`.
     * Exactly 3 raw keys, one case, no tone: vowel + doubler (aa ee oo) or vowel + w (aw ow uw,
     * never a standalone-w ư) + one bare consonant (not f j w z, not a stop c k p t g q); no English reading and not on
     * [HAT_INITIALISM_ENGLISH]. Boundary-only, allocation-free.
     */
    private fun isHatInitialismKeep(): Boolean {
        if (vniMode || rawCount != 3 || pCount != 2 || lastEffTone != T.NONE) return false
        val up = isUpperAscii(raw[0])
        if (isUpperAscii(raw[1]) != up || isUpperAscii(raw[2]) != up) return false
        val v = lowercased(raw[0]); val m = lowercased(raw[1]); val c = lowercased(raw[2])
        if (!isVowelAscii(v) || (m != v && m != 'w'.code)) return false
        if (m == v) { if (v != 'a'.code && v != 'e'.code && v != 'o'.code) return false }
        else if (v != 'a'.code && v != 'o'.code && v != 'u'.code) return false
        if (c < 'a'.code || c > 'z'.code || isVowelAscii(c) || HAT_INITIALISM_EXCLUDED.indexOf(c.toChar()) >= 0) return false
        if (rBase[0] != v || rMark[0] == Mark.NONE || rBase[1] != c || rMark[1] != Mark.NONE) return false
        val key = (v shl 16) or (m shl 8) or c
        for (e in HAT_INITIALISM_ENGLISH) if (e == key) return false
        if (isListedCapsAcronym() || rawIsEnglishCollision()) return false
        return !rawHasEnglishReading()
    }

    private fun rawHasEnglishReading(): Boolean {
        if (rawIsEnglishContextWord(true) || rawIsNeutralLoanword()) return true
        val n = lowerAsciiInto(raw, rawCount, EnglishContextWords.maxLength)
        if (n > 0 && EnglishCollisions.words.contains(wordBuf, n)) return true
        val top = minOf(rawCount, EnglishFreezePrefixes.maxLength)
        for (k in EnglishFreezePrefixes.minLength..top) if (EnglishFreezePrefixes.contains(raw, k)) return true
        return false
    }

    private fun isRareAllCapsAcronym(): Boolean {
        if (vniMode || !rawIsAllCapsToken()) return false
        var hasVowel = false
        for (k in 0 until pCount) if (isVowelAscii(rBase[k])) { hasVowel = true; break }
        if (!hasVowel || !compositionHasDiacritic() || !composedIsValidSyllable()) return false
        // Mid-word tone key = Vietnamese spelling ("DAJA"), unless 3+ raw keys spell a
        // dictionary English word ("NASA" → NẤ, "USA" → ÚA).
        if (lastEffTone != T.NONE && !isToneKey(rawCount - 1) && !(rawCount >= 3 && rawIsDictionaryWord())) return false
        // 4+ keys that are no English word = Vietnamese in capitals ("MUTS" → MÚT) — Swift twin.
        if (rawCount >= 4 && !rawIsDictionaryWord()) return false
        return !lettersAreCommonSyllable(pCount)
    }

    /** Raw keys are in the collision table or the context dictionary (Swift rawIsDictionaryWord). */
    private fun rawIsDictionaryWord(): Boolean {
        val n = lowerAsciiInto(raw, rawCount, EnglishContextWords.maxLength)
        return n > 0 && (EnglishCollisions.words.contains(wordBuf, n) || EnglishContextWords.words.contains(wordBuf, n))
    }

    /** ALL-CAPS 3–5 keys on EnglishContextWords.capsAcronyms, changed by Telex (Swift twin). */
    private fun isListedCapsAcronym(): Boolean {
        if (vniMode || rawCount < 3 || rawCount > 5 || !isUpperAscii(raw[0]) || !rawIsAllCapsToken() ||
            !compositionDiffersFromRaw()
        ) return false
        val n = lowerAsciiInto(raw, rawCount, EnglishContextWords.maxLength)
        return n > 0 && EnglishContextWords.capsAcronyms.contains(wordBuf, n)
    }

    private fun rawIsAllCapsToken(): Boolean {
        if (rawCount < 2) return false
        for (i in 0 until rawCount) if (!isUpperAscii(raw[i])) return false
        return pCount + (if (lastEffTone == T.NONE) 0 else 1) >= 2
    }

    private fun lettersAreCommonSyllable(count: Int): Boolean {
        var n = 0
        for (k in 0 until count) {
            keyBuf[n++] = rBase[k]
            when (rMark[k]) {
                Mark.CIRCUMFLEX -> keyBuf[n++] = rBase[k]
                Mark.BREVE, Mark.HORN -> keyBuf[n++] = 'w'.code
                Mark.BAR -> keyBuf[n++] = 'd'.code
            }
        }
        when (lastEffTone) {
            T.ACUTE -> keyBuf[n++] = 's'.code
            T.GRAVE -> keyBuf[n++] = 'f'.code
            T.HOOK -> keyBuf[n++] = 'r'.code
            T.TILDE -> keyBuf[n++] = 'x'.code
            T.DOT -> keyBuf[n++] = 'j'.code
        }
        return CommonSyllables.keys.contains(keyBuf, n)
    }

    /** Swift `predecessorGateAllows`: a gated word ("been") needs its predecessor ("has"). */
    private fun predecessorGateAllows(): Boolean {
        val n = lowerAsciiInto(raw, rawCount, EnglishContextWords.maxLength)
        if (n <= 0) return true
        val i = gateIndex(n)
        return i < 0 || (previousGateBits and (1 shl i)) != 0
    }

    /** Index of the gate rule whose word equals `wordBuf[0 until n]`, or -1. */
    private fun gateIndex(n: Int): Int {
        val gw = EnglishContextWords.gateWords
        outer@ for (i in gw.indices) {
            val w = gw[i]
            if (w.length != n) continue
            for (k in 0 until n) if (w[k].code != wordBuf[k]) continue@outer
            return i
        }
        return -1
    }

    /** Gate bits satisfied by the raw word as a predecessor (Swift `predecessorBits(of:)`). */
    private fun rawPredecessorBits(): Int {
        val n = lowerAsciiInto(raw, rawCount, EnglishContextWords.maxLength)
        if (n <= 0) return 0
        var bits = 0
        val gp = EnglishContextWords.gatePredecessors
        for (i in gp.indices) if (gp[i].contains(wordBuf, n)) bits = bits or (1 shl i)
        return bits
    }

    private fun rawIsFunctionWord(): Boolean {
        val n = lowerAsciiInto(raw, rawCount, EnglishContextWords.maxLength)
        return n > 0 && EnglishContextWords.functionWords.contains(wordBuf, n)
    }

    private fun rawIsRunKeeper(): Boolean {
        val n = lowerAsciiInto(raw, rawCount, EnglishContextWords.maxLength)
        return n > 0 && EnglishContextWords.runKeepers.contains(wordBuf, n)
    }

    private fun rawIsContractionTail(): Boolean {
        if (rawCount > 2) return false
        val n = lowerAsciiInto(raw, rawCount, EnglishContextWords.maxLength)
        return n > 0 && EnglishContextWords.contractionTails.contains(wordBuf, n)
    }

    private fun composedEndsWithK(): Boolean = pCount > 0 && lBase[pCount - 1] == 'k'.code

    private fun composedHasDiacritic(): Boolean {
        if (pTone != T.NONE) return true
        for (k in 0 until pCount) if (lMark[k] != Mark.NONE) return true
        return false
    }

    private fun composedIsRecognizedEnglish(): Boolean {
        if (outCount < 2 || outCount > 12) return false
        val n = lowerAsciiInto(out, outCount, 12)
        if (n < 0) return false
        return EnglishCollisions.words.contains(wordBuf, n) || EnglishContextWords.words.contains(wordBuf, n)
    }

    /**
     * Lowercase ascii-letter copy of `src[0 until count]` into `wordBuf` (the String
     * the Swift engine builds for its Set lookups, minus the allocation). Returns the
     * length, or -1 when empty / longer than `maxLen` / not all ascii letters.
     */
    private fun lowerAsciiInto(src: IntArray, count: Int, maxLen: Int): Int {
        if (count <= 0 || count > maxLen) return -1
        for (i in 0 until count) {
            var b = src[i]
            if (b in 'A'.code..'Z'.code) b = b or 0x20
            if (b < 'a'.code || b > 'z'.code) return -1
            wordBuf[i] = b
        }
        return count
    }

    private fun isRecognizedEnglish(): Boolean =
        rawIsEnglishContextWord(false) || rawIsEnglishCollision() || rawIsEnglishException()

    private fun classifyWordContext(restored: Boolean): Int {
        // Run keeper (box→bõ, car→cả): stays Vietnamese but must not END an open English run.
        if (!restored && compositionHasDiacritic())
            return if (previousWordEnglish && rawIsRunKeeper()) CTX_NEUTRAL else CTX_VIETNAMESE
        if (isRecognizedEnglish()) return if (rawIsFunctionWord()) CTX_ENGLISH_FUNCTION else CTX_ENGLISH
        val wn = lowerAsciiInto(out, outCount, EnglishContextWords.maxLength)   // composedAsciiWord
        if (wn > 0) {
            val neutral = EnglishContextWords.neutralLoanwords.contains(wordBuf, wn)
            if (EnglishContextWords.words.contains(wordBuf, wn) || EnglishCollisions.words.contains(wordBuf, wn) || neutral) {
                if (neutral) return CTX_NEUTRAL
                return if (EnglishContextWords.functionWords.contains(wordBuf, wn)) CTX_ENGLISH_FUNCTION else CTX_ENGLISH
            }
        }
        if (rawIsNeutralLoanword() || rawIsEnglishContextWord(true) || rawIsContractionTail()) return CTX_NEUTRAL
        if (!restored && SyllableValidator.isValidSyllableScalars(out, outCount, teencode, valBuf)) return CTX_VIETNAMESE
        if (rawCount <= 2) return CTX_NEUTRAL
        if (rawIsAllCapsToken()) return CTX_NEUTRAL   // acronym ("ASL"): never opens a run — see Swift
        return CTX_ENGLISH
    }

    private fun rawIsNeutralLoanword(): Boolean {
        val n = lowerAsciiInto(raw, rawCount, EnglishContextWords.maxLength)
        return n > 0 && EnglishContextWords.neutralLoanwords.contains(wordBuf, n)
    }

    private fun updateContext(restored: Boolean) {
        if (!contextualEnglish || rawCount <= 0) return
        when (classifyWordContext(restored)) {
            CTX_ENGLISH_FUNCTION -> { previousWordEnglish = true; englishCandidate = false }
            CTX_ENGLISH -> foldEnglishContentWord()
            CTX_VIETNAMESE -> { clearEnglishContext(); previousWordVietnamese = true; return }
            else -> {}
        }
        if (previousWordEnglish) previousWordVietnamese = false   // a run opened (one loanword does not)
        previousGateBits = rawPredecessorBits()
    }

    /** Content word: continue an open run; else the 2nd in a row opens it, the 1st is a candidate. */
    private fun foldEnglishContentWord() {
        if (previousWordEnglish) return
        if (englishCandidate) { previousWordEnglish = true; englishCandidate = false } else englishCandidate = true
    }

    private fun clearEnglishContext() {
        previousWordEnglish = false
        englishCandidate = false
        previousGateBits = 0
    }

    private fun rawIsEnglishContextWord(includingRestoreOnly: Boolean): Boolean {
        val n = lowerAsciiInto(raw, rawCount, EnglishContextWords.maxLength)
        if (n <= 0) return false
        if (EnglishContextWords.words.contains(wordBuf, n)) return true
        return includingRestoreOnly && EnglishContextWords.restoreOnly.contains(wordBuf, n)
    }

    /** Clear the cross-word English context (focus / app switch). */
    fun resetContext() {
        clearEnglishContext()
        previousWordVietnamese = false
        if (retroHistory.isNotEmpty() || retroPending != null) retroClear()
    }

    // MARK: - Retroactive English correction (Swift retroactiveEnglish)

    /** The caller inserted boundary character [ch] after a commit (Swift `noteBoundaryCharacter`). */
    fun noteBoundaryCharacter(ch: Char) {
        noteGlue(ch)
        // A sentence ends: the next word starts a phrase (frequency rule only reads this).
        if (previousWordVietnamese && (ch == '.' || ch == '!' || ch == '?' || ch == '\n' || ch == '\r')) {
            previousWordVietnamese = false
        }
        if (!retroactiveEnglish && retroHistory.isEmpty() && retroPending == null) return
        if (!retroactiveEnglishActive || rawCount != 0 || ch.isSurrogate()) { retroClear(); return }
        retroPending?.let { p ->
            retroPending = RetroCorrection(p.backspaces + 1, p.expected + ch, p.insert + ch, p.words, p.flipBack)
        }
        if (ch == ' ') {
            retroGap++
        } else {
            retroHistory.clear()
            retroPendingPicks = null
            retroGap = 0
        }
    }

    /** The edit the last commit decided, or null; taking it means the caller applies it. */
    fun takeRetroCorrection(): RetroCorrection? {
        val c = retroPending ?: return null
        retroPending = null
        retroPendingPicks?.let { picks ->
            for (i in picks) if (i < retroHistory.size) {
                val w = retroHistory[i]
                if (c.flipBack) {
                    w.shown = w.alt; w.english = false; w.byFrequency = false
                } else {
                    w.shown = w.raw; w.english = true; w.candidate = false
                }
            }
        }
        retroPendingPicks = null
        return c
    }

    /** Non-consuming look at the pending edit. */
    val pendingRetroCorrection: RetroCorrection? get() = retroPending

    private fun retroClear() {
        retroHistory.clear()
        retroPendingPicks = null
        retroPending = null
        retroGap = 0
    }

    private fun retroRecord(restored: Boolean, elongated: Boolean) {
        retroPending = null
        retroPendingPicks = null
        if (!retroactiveEnglishActive || rawCount <= 0) { retroClear(); return }
        val rawText = rawKeystrokes
        val shown = if (restored) rawText else if (elongated) composedElongated() else composed
        // Frequency rule (englishByFrequency): was THIS word restored only by it, and does it
        // flip the previous one back? Both read the state the restore decision saw.
        var byFrequency = false
        var flipBack = 0
        if (englishByFrequency) {
            byFrequency = restored && !elongated && !shouldRestoreRawBase() && !needsStandaloneWRunRestore() &&
                frequencyPrefersEnglish()
            flipBack = if (elongated) 0 else frequencyFlipDistance(restored)
        }
        var ascii = true
        for (c in shown) if (c.code >= 128) { ascii = false; break }
        val kind = classifyWordContext(restored)
        val ln = lowerAsciiInto(raw, rawCount, EnglishContextWords.maxLength)
        val lower: String? = if (ln > 0) rawText.lowercase() else null
        val english = ascii && (kind == CTX_ENGLISH || kind == CTX_ENGLISH_FUNCTION ||
            (rawCount == 1 && (raw[0] or 0x20) == 'a'.code))
        val candidate = !ascii && !restored && !elongated && rawCount >= 2 &&
            lower != null && RetroEnglish.isCandidateRaw(lower)
        val gap = if (retroHistory.isNotEmpty() && retroGap in 1..RetroEnglish.MAX_GAP) retroGap else 0
        val leftNonEnglish = gap > 0 && !retroHistory.last().english
        val gi = if (ln > 0) gateIndex(ln) else -1     // wordBuf still holds the lowercase raw
        val gateBit = if (gi >= 0) 1 shl gi else 0
        val predBits = rawPredecessorBits()
        val strong = english && kind == CTX_ENGLISH && lower != null && RetroEnglish.isStrongRaw(lower)
        if (retroHistory.size >= RetroEnglish.HISTORY_CAPACITY) retroHistory.removeAt(0)
        retroHistory.add(RetroWord(rawText, shown, english, candidate,
            if (lower != null) RetroEnglish.classBits(lower) else 0, gap, leftNonEnglish, gateBit, predBits,
            strong, byFrequency, if (byFrequency) composed else ""))
        retroGap = 0
        if (flipBack > 0 && retroHistory.size > flipBack && retroHistory[retroHistory.size - 1 - flipBack].byFrequency) {
            val picks = intArrayOf(retroHistory.size - 1 - flipBack)
            val c = RetroEnglish.correction(retroHistory, picks, flipBack = true)
            if (c != null) {
                retroPending = c
                retroPendingPicks = picks
            }
            return
        }
        if (!english) return
        val picks = RetroEnglish.plan(retroHistory) ?: return
        val c = RetroEnglish.correction(retroHistory, picks) ?: return
        retroPending = c
        retroPendingPicks = picks
    }

    /** Test-only: the history the retroactive check sees. */
    internal val debugRetroHistory: List<RetroWord> get() = retroHistory

    /** Caller vừa chèn NGUYÊN VĂN một từ ngoài engine (vuốt ra từ tiếng Anh): cập nhật ngữ cảnh chéo từ. */
    fun noteExternalWord(english: Boolean) = noteExternalWord(null, english)

    /** Biết chữ: từ chức năng mở mạch, từ nội dung chỉ là ứng viên; "has" mở cổng cho "been". */
    fun noteExternalWord(word: String?, english: Boolean) {
        if (!contextualEnglish) return
        if (!english) { clearEnglishContext(); return }
        val w = word?.lowercase()
        if (w != null && EnglishContextWords.functionWords.contains(w)) {
            previousWordEnglish = true; englishCandidate = false
        } else {
            foldEnglishContentWord()
        }
        var bits = 0
        if (w != null) {
            val gp = EnglishContextWords.gatePredecessors
            for (i in gp.indices) if (gp[i].contains(w)) bits = bits or (1 shl i)
        }
        previousGateBits = bits
    }

    /** Final text to commit at a word boundary, with auto-restore applied. Resets the word. */
    fun commitText(autoRestore: Boolean, boundary: Char = '\u0000'): String {
        restoreUndo = null
        try {
            if (overflowed) {
                if (contextualEnglish) clearEnglishContext()
                reopenRawCount = 0; reopenOutCount = 0
                if (retroHistory.isNotEmpty() || retroPending != null) retroClear()
                return composed
            }
            val wantsRestore = outCount > 0 &&
                (needsStandaloneWRunRestore() || (autoRestore && shouldRestoreRaw(boundary)))
            val elongate = !wantsRestore && outCount > 0 && isToneThenATail()
            val text = if (wantsRestore) rawKeystrokes else if (elongate) composedElongated() else composed
            captureReopen((wantsRestore && compositionDiffersFromRaw()) || elongate)
            noteCommittedWord(wantsRestore)
            if (retroactiveEnglish || retroHistory.isNotEmpty()) retroRecord(wantsRestore, elongate)
            updateContext(wantsRestore)
            return text
        } finally {
            resetWord()
        }
    }

    /** Non-mutating twin of `commitText`: what the boundary WILL commit. */
    fun peekCommitText(autoRestore: Boolean, boundary: Char = '\u0000'): String {
        if (overflowed) return composed
        if (outCount > 0 && needsStandaloneWRunRestore()) return rawKeystrokes
        if (autoRestore && outCount > 0 && shouldRestoreRaw(boundary)) return rawKeystrokes
        if (outCount > 0 && isToneThenATail()) return composedElongated()
        return composed
    }

    /**
     * TEENCODE one-letter elongation "Dạa" (Swift `isToneThenATail`): "daja" commits "dạa"
     * instead of the invalid bare "dậ" — the tone was placed before the extra `a` came.
     * Teencode only, Telex only, no cancel, tone keys between the target `a` and the final
     * `a`, the â carries the tone, and the head with a plain `a` is a valid syllable.
     */
    private fun isToneThenATail(): Boolean {
        if (!teencode || vniMode || markCancelled || overflowed || pCount < 2 || rawCount < 3 ||
            lastEffTone == T.NONE
        ) return false
        val last = pCount - 1
        if (lBase[last] != 'a'.code || lMark[last] != Mark.CIRCUMFLEX) return false
        if (lowercased(raw[rawCount - 1]) != 'a'.code || rawLetter[rawCount - 1] != last) return false
        if (outCount != pCount) return false
        if (out[outCount - 1] != Tables.applyTone(Tables.markedScalar('a'.code, Mark.CIRCUMFLEX, lUpper[last]), lastEffTone)) return false
        var r = rawCount - 2
        var tones = 0
        while (r >= 0 && isToneKey(r)) { tones++; r-- }
        if (tones == 0 || r < 0 || lowercased(raw[r]) != 'a'.code || rawLetter[r] != last) return false
        return isValidHead(pCount, lastEffTone, plainLast = true)
    }

    private fun isToneKey(r: Int): Boolean {
        when (lowercased(raw[r])) {
            's'.code, 'f'.code, 'r'.code, 'x'.code, 'j'.code -> {}
            else -> return false
        }
        for (j in 0 until pToneKeyCount) if (toneKeys[j] == r) return true
        return false
    }

    private fun elongatedTail(): String {
        val last = pCount - 1
        val toned = Tables.applyTone(Tables.markedScalar('a'.code, Mark.NONE, lUpper[last]), lastEffTone)
        val sb = StringBuilder(3)
        sb.appendCodePoint(toned)
        sb.append(raw[rawCount - 1].toChar())
        return sb.toString()
    }

    private fun composedElongated(): String {
        val sb = StringBuilder(outCount + 1)
        for (i in 0 until outCount - 1) sb.appendCodePoint(out[i])
        sb.append(elongatedTail())
        return sb.toString()
    }

    private fun rawIsEnglishCollision(): Boolean {
        if (!englishWordRestore) return false
        if (rawCount < 2 || rawCount > 12) return false
        if (!compositionDiffersFromRaw()) return false
        if ((raw[0] or 0x20) == 'w'.code) {
            val wTransformed = pCount > 0 && rBase[0] == 'u'.code && rMark[0] == Mark.HORN
            if (!wTransformed) return false
        }
        val n = lowerAsciiInto(raw, rawCount, 12)
        return n > 0 && EnglishCollisions.words.contains(wordBuf, n)
    }

    private fun rawIsEnglishException(): Boolean {
        if (pCount <= 0) return false
        val wTransformed = rBase[0] == 'u'.code && rMark[0] == Mark.HORN
        outer@ for (word in ENGLISH_EXCEPTIONS) {
            if (word.size != rawCount) continue
            if (word[0] == 'w'.code && !wTransformed) continue
            for (i in 0 until rawCount) if (lowercased(raw[i]) != word[i]) continue@outer
            return true
        }
        return false
    }

    /** Teencode onset code: 0 none, 1 w→qu (skip 1), 2 z→d (skip 1), 3 dz→d (skip 2). */
    private fun teencodeOnset(): Int {
        if (!teencode || pCount < 2 || rMark[0] != Mark.NONE) return 0
        return when (rBase[0]) {
            'w'.code -> 1
            'z'.code -> 2
            'd'.code -> if (pCount >= 3 && rBase[1] == 'z'.code && rMark[1] == Mark.NONE) 3 else 0
            else -> 0
        }
    }

    private fun onsetSkip(code: Int) = if (code == 3) 2 else 1

    /** Writes the canonical onset classes into buf, returns the count written. */
    private fun writeCanon(code: Int, buf: IntArray): Int {
        return if (code == 1) {
            buf[0] = 'q' - 'a'; buf[1] = 'u' - 'a'; 2
        } else {
            buf[0] = 'd' - 'a'; 1
        }
    }

    private fun isAbbreviationPrefix(upper: Boolean): Boolean {
        if (pCount <= 0) return false
        for (k in 0 until pCount) {
            if (isVowelAscii(lBase[k]) || lUpper[k] != upper) return false
        }
        return true
    }

    private fun abbreviationDoublerException(lower: Int, upper: Boolean): Boolean =
        !pVniMode && lower == 'd'.code && isAbbreviationPrefix(upper)

    private fun composedIsValidSyllable(): Boolean {
        if (pCount >= 1 && lastEffTone == T.NONE && rBase[0] == 'd'.code && rMark[0] == Mark.BAR) {
            var bareConsonantsOnly = true
            for (k in 1 until pCount) {
                if (rMark[k] != Mark.NONE || isVowelAscii(rBase[k])) { bareConsonantsOnly = false; break }
            }
            if (bareConsonantsOnly) return true
        }
        if (lastEffTone == T.NONE && rawCount >= 2) {
            var sameCase = true
            val firstIsUpper = isUpperAscii(raw[0])
            for (i in 0 until rawCount) if (isUpperAscii(raw[i]) != firstIsUpper) { sameCase = false; break }
            if (sameCase) {
                var hasBar = false
                var onlyBar = true
                for (k in 0 until pCount) {
                    if (isVowelAscii(rBase[k])) { onlyBar = false; break }
                    if (rBase[k] == 'd'.code && rMark[k] == Mark.BAR) hasBar = true
                    else if (rMark[k] != Mark.NONE) { onlyBar = false; break }
                }
                if (hasBar && onlyBar) return true
            }
        }
        val buf = valBuf
        val onset = teencodeOnset()
        val stacksTeencodeRime = pCount >= 3 &&
            rBase[pCount - 2] == 'i'.code && rMark[pCount - 2] == Mark.NONE &&
            rBase[pCount - 1] == 'e'.code && rMark[pCount - 1] == Mark.NONE &&
            onset != 0 && onsetSkip(onset) == pCount - 2
        if (!stacksTeencodeRime && pCount < CAPACITY - 1 && onset != 0) {
            var n = writeCanon(onset, buf)
            for (k in onsetSkip(onset) until pCount) {
                buf[n] = Tables.letterClass(rBase[k], rMark[k]); n++
            }
            if (SyllableValidator.isValidSyllable(buf, n, lastEffTone, teencode)) return true
        }
        for (k in 0 until pCount) buf[k] = Tables.letterClass(rBase[k], rMark[k])
        return SyllableValidator.isValidSyllable(buf, pCount, lastEffTone, teencode)
    }

    // MARK: - Teencode elongation

    private fun elongationHeadCount(count: Int, tone: Int): Int {
        val minRun = 3
        if (count < minRun + 1) return -1
        val lastB = rBase[count - 1]
        val lastM = rMark[count - 1]
        for (j in (count - minRun) until (count - 1)) {
            if (rBase[j] != lastB || rMark[j] != lastM) return -1
        }
        var runStart = count - minRun
        while (runStart > 0 && rBase[runStart - 1] == lastB && rMark[runStart - 1] == lastM) runStart--
        if (runStart < 1) runStart = 1
        var k = runStart
        while (k <= count - minRun) {
            if (isValidHead(k, tone)) return k
            k++
        }
        return -1
    }

    private fun isValidHead(k: Int, tone: Int, plainLast: Boolean = false): Boolean {
        if (k < 1 || k > CAPACITY) return false
        var t = tone
        if ((t == T.GRAVE || t == T.HOOK || t == T.TILDE) && hasStopCoda(k) &&
            !(t == T.GRAVE && isUkRime(k))
        ) t = T.NONE
        val buf = headBuf
        val onset = teencodeOnset()
        if (onset != 0 && onsetSkip(onset) < k) {
            var n = writeCanon(onset, buf)
            for (j in onsetSkip(onset) until k) {
                buf[n] = Tables.letterClass(rBase[j], if (plainLast && j == k - 1) Mark.NONE else rMark[j]); n++
            }
            if (SyllableValidator.isValidSyllable(buf, n, t, teencode)) return true
        }
        for (j in 0 until k) buf[j] = Tables.letterClass(rBase[j], if (plainLast && j == k - 1) Mark.NONE else rMark[j])
        return SyllableValidator.isValidSyllable(buf, k, t, teencode)
    }

    private fun isTeencodeKeep(): Boolean = elongationHeadCount(pCount, lastEffTone) > 0

    private fun compositionDiffersFromRaw(): Boolean {
        if (outCount != rawCount) return true
        for (i in 0 until outCount) if (out[i] != raw[i]) return true
        return false
    }

    private fun compositionHasDiacritic(): Boolean {
        for (i in 0 until outCount) if (out[i] > 127) return true
        return false
    }

    private fun letterCreatedByW(idx: Int): Boolean {
        for (i in 0 until rawCount) {
            if (rawLetter[i] == idx) return raw[i] == 'w'.code || raw[i] == 'W'.code
        }
        return false
    }

    private fun uaUuPredecessorAllowsRetarget(pred: Int): Boolean {
        val m = lMark[pred]
        return m == Mark.NONE || (m == Mark.HORN && !letterCreatedByW(pred))
    }

    private fun hasLowercaseBefore(at: Int): Boolean {
        for (i in 0 until at) if (raw[i] >= 'a'.code && raw[i] <= 'z'.code) return true
        return false
    }

    // MARK: - Initials suffix ("PhươngTH", "KiênTV", "HùngNV" — issue #138; see Swift)

    /** Raw index where the word splits into Title-case HEAD + 2–4 uppercase INITIALS, or -1. */
    private fun initialsSplitPoint(): Int {
        if (rawCount < 1 + INITIALS_MIN || !isUpperAscii(raw[0]) || !isUpperAscii(raw[rawCount - 1])) return -1
        var s = rawCount
        while (s > 0 && isUpperAscii(raw[s - 1])) s--
        val n = rawCount - s
        if (s < 2 || n < INITIALS_MIN || n > INITIALS_MAX) return -1
        var hasLower = false
        for (i in 1 until s) {
            val c = raw[i]
            if (c >= 'a'.code && c <= 'z'.code) { hasLower = true; continue }
            if (vniMode && isDigit(c)) continue
            if (!vniMode && i == 1 && c == 'D'.code && raw[0] == 'D'.code) continue
            return -1
        }
        return if (hasLower && !runIsCodeAcronym(s)) s else -1
    }

    /** raw[s until rawCount] is a code acronym ("MaxID"), not initials (EnglishContextWords.codeAcronyms). */
    private fun runIsCodeAcronym(s: Int): Boolean {
        val n = rawCount - s
        for (i in 0 until n) wordBuf[i] = raw[s + i] or 0x20
        return EnglishContextWords.codeAcronyms.contains(wordBuf, n)
    }

    /** raw[0 until s] alone: valid, transformed, uncancelled, non-English syllable (in-place re-parse). */
    private fun headIsInitialsSyllable(s: Int): Boolean {
        val full = rawCount
        val savedDisabled = disabledAtCount
        val savedKeep = freezeKeepsTone
        rawCount = s
        disabledAtCount = Int.MAX_VALUE
        freezeKeepsTone = false
        rebuildParseState()
        render()
        var ok = !pCancelled
        if (ok) {
            var transformed = lastEffTone != T.NONE
            for (k in 0 until pCount) if (rMark[k] != Mark.NONE) { transformed = true; break }
            ok = transformed && composedIsValidSyllable() && !rawHeadIsEnglish(s)
        }
        rawCount = full
        disabledAtCount = savedDisabled
        freezeKeepsTone = savedKeep
        if (!ok) rebuildFrozenAware()
        return ok
    }

    private fun rawHeadIsEnglish(s: Int): Boolean {
        if (!englishWordRestore) return false
        val n = lowerAsciiInto(raw, s, EnglishContextWords.maxLength)
        if (n <= 0) return false
        if (EnglishCollisions.words.contains(wordBuf, n) || EnglishContextWords.words.contains(wordBuf, n)) return true
        outer@ for (word in ENGLISH_EXCEPTIONS) {
            if (word.size != n) continue
            for (i in 0 until n) if (wordBuf[i] != word[i]) continue@outer
            return true
        }
        return false
    }

    /** Take / keep / lift the initials split; true when the caller must re-render. */
    private fun applyInitialsSplit(): Boolean {
        val s = initialsSplitPoint()
        if (s >= 0) {
            if (initialsSplitAt == s && disabledAtCount == s && freezeKeepsTone) return false
            if (headIsInitialsSyllable(s)) {
                initialsSplitAt = s
                disabledAtCount = s
                freezeKeepsTone = true
                upperToneFrozen = false
                rebuildParseState()
                tonesFolded = false
                return true
            }
            if (initialsSplitAt >= 0) {
                recomputeFreeze()
                rebuildFrozenAware()
            }
            return true
        }
        if (initialsSplitAt >= 0) {
            recomputeFreeze()
            rebuildFrozenAware()
            return true
        }
        return false
    }

    /** Drop the current word AND the re-open snapshot. */
    fun reset() {
        if (rawCount > 0) { clearEnglishContext(); previousWordVietnamese = true }
        resetWord()
        reopenRawCount = 0
        reopenOutCount = 0
        restoreUndo = null
        clearGlue()
        if (retroHistory.isNotEmpty() || retroPending != null) retroClear()   // caret moved / text unknown
    }

    private fun resetWord() {
        rawCount = 0
        outCount = 0
        markCancelled = false
        toneCancelAt = -1
        toneCancelSpan = 0
        upperToneKey = false
        upperToneFrozen = false
        initialsSplitAt = -1
        wordGlue = 0
        overflowed = false
        disabledAtCount = Int.MAX_VALUE
        tonesFolded = false
        freezeKeepsTone = false
        pFreezeLetters = -1
        pCount = 0
        pTone = T.NONE
        pToneKeyCount = 0
        pCancelled = false
        pToneCancelAt = -1
        pToneCancelSpan = 0
        pMarkCancelReachedBack = false
        pProcessed = 0
    }

    private fun prefixIsValid(n: Int): Boolean {
        var o = 0
        var start = 0
        if (teencode && n >= 1 && lMark[0] == Mark.NONE && n < CAPACITY - 1) {
            when (lBase[0]) {
                'w'.code -> { basesScratch[0] = 'q'.code; basesScratch[1] = 'u'.code; o = 2; start = 1 }
                'z'.code -> { basesScratch[0] = 'd'.code; o = 1; start = 1 }
                'd'.code -> if (n >= 2 && lBase[1] == 'z'.code && lMark[1] == Mark.NONE) {
                    basesScratch[0] = 'd'.code; o = 1; start = 2
                }
            }
        }
        for (k in start until n) {
            basesScratch[o] = lBase[k] or (if (lMark[k] != Mark.NONE) 0x80 else 0)
            o++
        }
        return SyllableValidator.isValidPrefix(basesScratch, o, teencode)
    }

    /** Eager English restore gate — only at the freeze moment (Swift `eagerRestoreApplies`). */
    private fun eagerRestoreApplies(n: Int): Boolean {
        if (!eagerEnglishRestore || vniMode || pCancelled ||
            rawCount < EnglishFreezePrefixes.minLength || rawCount > EnglishFreezePrefixes.maxLength
        ) return false
        var differs = n != rawCount
        if (!differs) {
            for (i in 0 until n) if (scratch[i] != raw[i]) { differs = true; break }
        }
        if (!differs) return false
        return EnglishFreezePrefixes.contains(raw, rawCount)
    }

    // MARK: - Caller helpers

    /** Freeze index (0 = whole word literal), null = not frozen (Swift `spellCheckFreezeAt`). */
    val spellCheckFreezeAt: Int? get() = if (disabledAtCount == Int.MAX_VALUE) null else disabledAtCount

    /** TRUE while the current word has exceeded the 32-key capacity. */
    val isOverflowed: Boolean get() = overflowed

    /** Current composed word. */
    val composed: String
        get() {
            val sb = StringBuilder(outCount)
            for (i in 0 until outCount) sb.appendCodePoint(out[i])
            return sb.toString()
        }

    /** The raw keystrokes typed for the current word. */
    val rawKeystrokes: String
        get() {
            val sb = StringBuilder(rawCount)
            for (i in 0 until rawCount) sb.append(raw[i].toChar())
            return sb.toString()
        }

    /** Test-only: live-spell-check freeze index (Int.MAX_VALUE = not frozen). */
    internal val debugFreezeAt: Int get() = disabledAtCount
    internal val debugCancelSnapshot: Triple<Boolean, Int, Int> get() = Triple(markCancelled, toneCancelAt, toneCancelSpan)
    internal val debugParseCancelState: Triple<Boolean, Int, Int> get() = Triple(pCancelled, pToneCancelAt, pToneCancelSpan)

    // MARK: - Rendering

    private fun copyOut(n: Int) {
        System.arraycopy(scratch, 0, out, 0, n)
        outCount = n
    }

    private fun render(): Int {
        val count = pCount
        System.arraycopy(lBase, 0, rBase, 0, count)
        System.arraycopy(lMark, 0, rMark, 0, count)
        System.arraycopy(lUpper, 0, rUpper, 0, count)
        // Kept-tone freeze (PR #133): the literal tail neither attracts the tone nor re-shapes ươ.
        val headEnd = if (freezeKeepsTone && pFreezeLetters >= 0) minOf(count, pFreezeLetters) else count

        for (k in 1 until maxOf(1, headEnd)) {
            if (rBase[k - 1] != 'u'.code || rBase[k] != 'o'.code) continue
            val prevHorn = rMark[k - 1] == Mark.HORN
            val curHorn = rMark[k] == Mark.HORN
            if (prevHorn == curHorn) continue
            val oIsLast = k == headEnd - 1
            val isQuGlide = k >= 2 && rBase[k - 2] == 'q'.code
            if (!oIsLast && !isQuGlide) {
                rMark[k - 1] = Mark.HORN
                rMark[k] = Mark.HORN
            }
        }

        var effTone = pTone
        var toneScope = headEnd
        if (pTone != T.NONE && headEnd == count) {
            val head = elongationHeadCount(count, pTone)
            if (head > 0) toneScope = head
        }
        var toneIdx = if (pTone == T.NONE) -1 else toneVowelIndex(toneScope)
        if (toneIdx >= 0 && (effTone == T.GRAVE || effTone == T.HOOK || effTone == T.TILDE) &&
            hasStopCoda(toneScope) && !(effTone == T.GRAVE && isUkRime(toneScope))
        ) {
            effTone = T.NONE
            toneIdx = -1
        }
        // Tự thêm dấu mũ (issue #166): sau khi biết thanh nào còn hiệu lực. Mũ vừa thêm là
        // nguyên âm có dấu duy nhất của vần nên thanh đặt lại lên nó.
        inferredCircumflex = false
        if (autoCircumflex && effTone != T.NONE && toneScope == count && inferCircumflex(count, effTone)) {
            inferredCircumflex = true
            toneIdx = toneVowelIndex(toneScope)
        }
        val target = if (toneIdx >= 0) toneIdx else maxOf(0, count - 1)
        for (j in 0 until pToneKeyCount) rawLetter[toneKeys[j]] = target
        lastEffTone = effTone

        for (k in 0 until count) {
            var scalar = Tables.markedScalar(rBase[k], rMark[k], rUpper[k])
            if (k == toneIdx) scalar = Tables.applyTone(scalar, effTone)
            scratch[k] = scalar
        }
        return count
    }

    /**
     * Tự thêm dấu mũ — xem [autoCircumflex]. Đọc/ghi rBase/rMark[0 until count]. Trả về true khi
     * đã đặt mũ. Điều kiện: đúng MỘT cụm nguyên âm, chưa chữ nào trong cụm mang dấu, cụm thuộc
     * danh sách dưới; âm tiết không mũ KHÔNG hợp lệ với thanh này còn âm tiết có mũ thì hợp lệ
     * (validator quyết định, nên "quan", "què", "xẻng", "séc" không bị đụng tới).
     */
    private fun inferCircumflex(count: Int, tone: Int): Boolean {
        if (count < 2 || count >= CAPACITY) return false
        var first = -1
        var last = -1
        for (k in 0 until count) {
            if (!isVowelAscii(rBase[k])) continue
            if (rMark[k] != Mark.NONE) return false
            if (first < 0) first = k else if (k != last + 1) return false
            last = k
        }
        if (first < 0) return false
        val n = last - first + 1
        val a = 'a'.code; val e = 'e'.code; val i = 'i'.code; val u = 'u'.code; val y = 'y'.code
        val v0 = rBase[first]
        val v1 = if (n >= 2) rBase[first + 1] else -1
        val v2 = if (n >= 3) rBase[first + 2] else -1
        val target = when {
            n == 1 && v0 == e -> first                                              // ênh, êch
            n == 2 && v1 == e && (v0 == i || v0 == y) && last < count - 1 -> first + 1  // iên, yêt…
            n == 2 && v0 == u && v1 == e -> first + 1                               // uê, uênh, uêch
            n == 2 && v0 == e && v1 == u -> first                                   // êu
            n == 2 && v0 == u && v1 == a && last < count - 1 -> first + 1           // uân, uât, uâng
            n == 3 && v0 == u && v1 == y && v2 == e && last < count - 1 -> first + 2   // uyên, uyêt
            n == 3 && (v0 == i || v0 == y) && v1 == e && v2 == u -> first + 1       // iêu, yêu
            n == 3 && v0 == u && v1 == a && v2 == y -> first + 1                    // uây
            else -> return false
        }
        val buf = circBuf
        for (k in 0 until count) buf[k] = Tables.letterClass(rBase[k], rMark[k])
        if (SyllableValidator.isValidSyllable(buf, count, tone, teencode)) return false
        buf[target] = Tables.letterClass(rBase[target], Mark.CIRCUMFLEX)
        if (!SyllableValidator.isValidSyllable(buf, count, tone, teencode)) return false
        rMark[target] = Mark.CIRCUMFLEX
        return true
    }

    // MARK: - Incremental parse

    /** Circumflex the doubler target; an o inside ươ also un-horns the u (ươ → uô). */
    private fun setCircumflex(k: Int) {
        lMark[k] = Mark.CIRCUMFLEX
        if (lBase[k] == 'o'.code && k >= 1 && lBase[k - 1] == 'u'.code && lMark[k - 1] == Mark.HORN) {
            lMark[k - 1] = Mark.NONE
        }
    }

    private fun nucleusHasHornVowel(end: Int): Boolean {
        var j = end
        while (j >= 0 && isVowelAscii(lBase[j])) {
            if (lMark[j] == Mark.HORN) return true
            j--
        }
        return false
    }

    private fun rebuildFrozenAware() {
        rebuildParseState()
        tonesFolded = false
        if (disabledAtCount != Int.MAX_VALUE && pTone != T.NONE && !freezeKeepsTone) {
            pFoldTones = true
            rebuildParseState()
            pFoldTones = false
            tonesFolded = true
        }
    }

    private fun recomputeFreeze() {
        val full = rawCount
        disabledAtCount = Int.MAX_VALUE
        freezeKeepsTone = false
        upperToneFrozen = false
        initialsSplitAt = -1
        var r = 1
        while (r <= full) {
            rawCount = r
            rebuildParseState()
            // feed()'s upper-case tone freeze, before spell-check and independent of it;
            // nothing lifts it ("VieeJt" ⌫ → "VieeJ") — see Swift.
            if (disabledAtCount == Int.MAX_VALUE && upperToneKey) {
                disabledAtCount = 0
                upperToneFrozen = true
                break
            }
            if (!liveSpellCheck) { r++; continue }
            if (disabledAtCount == Int.MAX_VALUE && pCount > 0 && !prefixIsValid(pCount)) {
                val n = render()
                if (elongationHeadCount(pCount, pTone) <= 0) {
                    if (eagerRestoreApplies(n)) {
                        disabledAtCount = 0
                    } else if (pTone != T.NONE && prefixKeepsTone(r - 1)) {
                        disabledAtCount = r - 1   // same kept-tone rule as feed() (PR #133)
                        freezeKeepsTone = true
                    } else {
                        disabledAtCount = r
                    }
                }
            } else if (eagerEnglishRestore && disabledAtCount != Int.MAX_VALUE && disabledAtCount > 0 &&
                disabledAtCount < EnglishFreezePrefixes.minLength && r == EnglishFreezePrefixes.minLength
            ) {
                rebuildFrozenAware()
                val n = render()
                if (eagerRestoreApplies(n)) disabledAtCount = 0
            }
            // feed()'s elongation unfreeze, on the key it fires on (exact repeat) — see Swift.
            if (disabledAtCount != Int.MAX_VALUE && r >= 2 && raw[r - 1] == raw[r - 2]) {
                val frozenAt = disabledAtCount
                disabledAtCount = Int.MAX_VALUE
                rebuildParseState()
                render()
                if (elongationHeadCount(pCount, pTone) <= 0) disabledAtCount = frozenAt else freezeKeepsTone = false
            }
            r++
        }
        rawCount = full
    }

    /**
     * Kept-tone freeze test (PR #133, Swift `prefixKeepsTone`): the word of the first [n] raw
     * keys carries a letter mark (đ ư ơ â ê ô ă) AND a visible tone, and key [n], parsed
     * normally, only appends one character to that display. Freeze-time only; leaves the
     * parse state built for the full rawCount.
     */
    private fun prefixKeepsTone(n: Int): Boolean {
        val full = rawCount
        rawCount = n
        rebuildParseState()
        var keep = false
        var shown = 0
        var sig = 0
        if (pTone != T.NONE) {
            for (k in 0 until pCount) if (lMark[k] != Mark.NONE) { keep = true; break }
            if (keep) {
                shown = render()
                keep = lastEffTone != T.NONE
                sig = scratchSignature(shown)
            }
        }
        rawCount = full
        rebuildParseState()
        if (keep) keep = render() == shown + 1 && scratchSignature(shown) == sig
        return keep
    }

    private fun scratchSignature(n: Int): Int {
        var h = 0
        for (k in 0 until n) h = h * 1_000_003 + scratch[k]
        return h
    }

    private fun rebuildParseState() {
        pCount = 0
        pTone = T.NONE
        pToneKeyCount = 0
        pCancelled = false
        pToneCancelAt = -1
        pToneCancelSpan = 0
        pMarkCancelReachedBack = false
        upperToneKey = false
        pFreeMarking = freeMarking
        pSimpleTelex = simpleTelex
        pQuickTelex = quickTelex
        pVniMode = vniMode
        pBracketVowels = bracketVowels
        pLiveSpellCheck = liveSpellCheck
        pFreezeLetters = -1
        for (i in 0 until rawCount) rawLetter[i] = -1
        for (i in 0 until rawCount) parseStep(i)
        pProcessed = rawCount
    }

    private fun literal(at: Int, base: Int, upper: Boolean) {
        appendLetter(base, Mark.NONE, upper)
        rawLetter[at] = pCount - 1
    }

    private fun parseStep(at: Int) {
        val key = raw[at]
        val lower = lowercased(key)
        val upper = isUpperAscii(key)
        if (at == disabledAtCount) pFreezeLetters = pCount

        if (pCancelled || (at >= disabledAtCount && !abbreviationDoublerException(lower, upper))) {
            literal(at, lower, upper); return
        }

        if (pBracketVowels) {
            val bb = bracketBase(key)
            if (bb >= 0) {
                appendLetter(bb, Mark.HORN, key == '{'.code || key == '}'.code)
                rawLetter[at] = pCount - 1
                return
            }
        }

        if (pVniMode) {
            parseStepVNI(at, key, lower, upper)
            return
        }

        val t = toneForKey(lower)
        if (t >= 0) {
            if (pFoldTones) { literal(at, lower, upper); return }
            if (hasVowel(pCount)) {
                if (pTone == t) {
                    pTone = T.NONE
                    pCancelled = true; pToneCancelAt = at
                    pToneCancelSpan = if (pToneKeyCount > 0) at - toneKeys[pToneKeyCount - 1] else 1
                    literal(at, lower, upper)
                    for (j in 0 until pToneKeyCount) {
                        if (rawLetter[toneKeys[j]] == -1) rawLetter[toneKeys[j]] = pCount - 1
                    }
                    pToneKeyCount = 0
                } else if (stopCodaRejectsTone(t)) {
                    literal(at, lower, upper)
                } else {
                    pTone = t
                    if (upper && hasLowercaseBefore(at)) upperToneKey = true
                    rawLetter[at] = -1
                    toneKeys[pToneKeyCount] = at; pToneKeyCount++
                }
            } else {
                literal(at, lower, upper)
            }
            return
        }

        if (lower == 'z'.code) {
            if (pTone != T.NONE) {
                pToneCancelAt = at
                pToneCancelSpan = if (pToneKeyCount > 0) at - toneKeys[pToneKeyCount - 1] else 1
                pTone = T.NONE
                if (upper && hasLowercaseBefore(at)) upperToneKey = true
                rawLetter[at] = -1
                toneKeys[pToneKeyCount] = at; pToneKeyCount++
            } else {
                literal(at, lower, upper)
            }
            return
        }

        if (lower == 'w'.code) {
            var tIdx = -1
            var k = pCount - 1
            while (k >= 0) {
                val b = lBase[k]
                if (b == 'a'.code || b == 'o'.code || b == 'u'.code) { tIdx = k; break }
                if (!freeMarking && !isVowelAscii(b)) break
                k--
            }
            if (tIdx >= 1 && lBase[tIdx] == 'a'.code && lMark[tIdx] == Mark.NONE &&
                lBase[tIdx - 1] == 'u'.code && uaUuPredecessorAllowsRetarget(tIdx - 1) &&
                !(tIdx >= 2 && lBase[tIdx - 2] == 'q'.code)
            ) tIdx--
            if (tIdx >= 1 && lBase[tIdx] == 'u'.code && lMark[tIdx] == Mark.NONE &&
                lBase[tIdx - 1] == 'u'.code && uaUuPredecessorAllowsRetarget(tIdx - 1) &&
                !(tIdx >= 2 && lBase[tIdx - 2] == 'q'.code)
            ) tIdx--
            if (tIdx >= 0) {
                val pb = lBase[tIdx]
                val pm = lMark[tIdx]
                if (pm == Mark.NONE && pb == 'a'.code) {
                    lMark[tIdx] = Mark.BREVE; rawLetter[at] = tIdx; return
                }
                if (pm == Mark.NONE && (pb == 'o'.code || pb == 'u'.code)) {
                    lMark[tIdx] = Mark.HORN; rawLetter[at] = tIdx; return
                }
                // Hat → hook/breve swap: w on â/ô replaces the hat, tone kept —
                // "caamw"/"cấmw"→cắm, "tooiw"→tơi. Issue #149.
                if (pm == Mark.CIRCUMFLEX && pb == 'a'.code) {
                    lMark[tIdx] = Mark.BREVE; rawLetter[at] = tIdx; return
                }
                if (pm == Mark.CIRCUMFLEX && pb == 'o'.code) {
                    lMark[tIdx] = Mark.HORN; rawLetter[at] = tIdx; return
                }
                if (pm == Mark.BREVE && pb == 'a'.code) {
                    lMark[tIdx] = Mark.NONE
                    pCancelled = true
                    literal(at, 'w'.code, upper); return
                }
                if (pm == Mark.HORN && (pb == 'o'.code || pb == 'u'.code)) {
                    lMark[tIdx] = Mark.NONE
                    pCancelled = true
                    if (pb == 'u'.code && letterCreatedByW(tIdx)) {
                        lBase[tIdx] = 'w'.code
                        rawLetter[at] = tIdx
                        return
                    }
                    literal(at, 'w'.code, upper); return
                }
            }
            if (!simpleTelex && standaloneHornUAllowed(pCount)) {
                appendLetter('u'.code, Mark.HORN, upper)
            } else {
                appendLetter('w'.code, Mark.NONE, upper)
            }
            rawLetter[at] = pCount - 1
            return
        }

        if (lower == 'a'.code || lower == 'e'.code || lower == 'o'.code) {
            if (pCount > 0) {
                val pIdx = pCount - 1
                if (lBase[pIdx] == lower && lMark[pIdx] == Mark.NONE &&
                    (lower == 'o'.code || !nucleusHasHornVowel(pIdx))
                ) {
                    setCircumflex(pIdx); rawLetter[at] = pIdx; return
                }
                // `o` on ơ (ươ cluster): hook → hat, common IME style ("mơ"+o → mô).
                if (lower == 'o'.code && lBase[pIdx] == lower && lMark[pIdx] == Mark.HORN) {
                    setCircumflex(pIdx); rawLetter[at] = pIdx; return
                }
                // Same swap for `a` on ă ("awa"→â). Issue #149.
                if (lower == 'a'.code && lBase[pIdx] == lower && lMark[pIdx] == Mark.BREVE &&
                    !nucleusHasHornVowel(pIdx)
                ) {
                    setCircumflex(pIdx); rawLetter[at] = pIdx; return
                }
                if (lBase[pIdx] == lower && lMark[pIdx] == Mark.CIRCUMFLEX) {
                    lMark[pIdx] = Mark.NONE
                    pCancelled = true
                    literal(at, lower, upper); return
                }
            }
            if (freeMarking) {
                var k = pCount - 1
                while (k >= 0 && !isVowelAscii(lBase[k])) k--
                val nucleusEnd = k
                val hornBlocksCircumflex = lower != 'o'.code && nucleusHasHornVowel(nucleusEnd)
                while (!hornBlocksCircumflex && k >= 0 && isVowelAscii(lBase[k])) {
                    // "lươn" + o → "luôn": reach-back also retargets a horned o.
                    if (lBase[k] == lower &&
                        (lMark[k] == Mark.NONE || (lower == 'o'.code && lMark[k] == Mark.HORN) ||
                            (lower == 'a'.code && lMark[k] == Mark.BREVE))
                    ) {
                        if (lower == 'o'.code && nucleusEnd == pCount - 1 && k == pCount - 2 &&
                            lMark[k + 1] == Mark.NONE &&
                            (lBase[k + 1] == 'e'.code || lBase[k + 1] == 'a'.code)
                        ) break
                        setCircumflex(k); rawLetter[at] = k; return
                    }
                    if (lBase[k] == lower && lMark[k] == Mark.CIRCUMFLEX) {
                        lMark[k] = Mark.NONE
                        pCancelled = true
                        pMarkCancelReachedBack = true
                        literal(at, lower, upper); return
                    }
                    k--
                }
            }
            literal(at, lower, upper)
            return
        }

        if (lower == 'd'.code) {
            if (pCount > 0) {
                val pIdx = pCount - 1
                if (lBase[pIdx] == 'd'.code && lMark[pIdx] == Mark.NONE) {
                    lMark[pIdx] = Mark.BAR; rawLetter[at] = pIdx; return
                }
                if (lBase[pIdx] == 'd'.code && lMark[pIdx] == Mark.BAR) {
                    lMark[pIdx] = Mark.NONE
                    pCancelled = true
                    literal(at, 'd'.code, upper); return
                }
            }
            if (freeMarking && pCount > 1 && lBase[0] == 'd'.code && lMark[0] == Mark.NONE) {
                lMark[0] = Mark.BAR; rawLetter[at] = 0; return
            }
            if (freeMarking && pCount > 1 && lBase[0] == 'd'.code && lMark[0] == Mark.BAR &&
                lBase[pCount - 1] != 'd'.code
            ) {
                lMark[0] = Mark.NONE
                pCancelled = true
                literal(at, 'd'.code, upper); return
            }
            literal(at, 'd'.code, upper)
            return
        }

        if (quickTelex && pCount == 1 && lBase[0] == lower && lMark[0] == Mark.NONE) {
            val second = quickTelexSecond(lower)
            if (second >= 0) {
                literal(at, second, upper)
                return
            }
        }

        literal(at, lower, upper)
    }

    private fun parseStepVNI(at: Int, key: Int, lower: Int, upper: Boolean) {
        if (!isDigit(key)) { literal(at, lower, upper); return }

        val t = vniTone(key)
        if (pFoldTones && t >= 0) { literal(at, key, false); return }

        if (t >= 0) {
            if (hasVowel(pCount)) {
                if (pTone == t) {
                    pTone = T.NONE
                    pCancelled = true; pToneCancelAt = at
                    pToneCancelSpan = if (pToneKeyCount > 0) at - toneKeys[pToneKeyCount - 1] else 1
                    literal(at, key, false)
                    for (j in 0 until pToneKeyCount) {
                        if (rawLetter[toneKeys[j]] == -1) rawLetter[toneKeys[j]] = pCount - 1
                    }
                    pToneKeyCount = 0
                } else if (stopCodaRejectsTone(t)) {
                    literal(at, key, false)
                } else {
                    pTone = t
                    rawLetter[at] = -1
                    toneKeys[pToneKeyCount] = at; pToneKeyCount++
                }
            } else {
                literal(at, key, false)
            }
            return
        }

        if (key == '0'.code) {
            if (pTone != T.NONE) {
                pToneCancelAt = at
                pToneCancelSpan = if (pToneKeyCount > 0) at - toneKeys[pToneKeyCount - 1] else 1
                pTone = T.NONE
                rawLetter[at] = -1
                toneKeys[pToneKeyCount] = at; pToneKeyCount++
            } else {
                literal(at, key, false)
            }
            return
        }

        val mark = vniMark(key)
        if (mark >= 0) {
            var k = pCount - 1
            while (k >= 0) {
                if (vniMarkAccepts(lBase[k], mark)) {
                    var target = k
                    if (mark == Mark.HORN && target >= 1 &&
                        lBase[target] == 'u'.code && lMark[target] == Mark.NONE &&
                        lBase[target - 1] == 'u'.code &&
                        !(target >= 2 && lBase[target - 2] == 'q'.code)
                    ) target--
                    if (lMark[target] == Mark.NONE) {
                        lMark[target] = mark
                        rawLetter[at] = target
                        return
                    }
                    if (lMark[target] == mark) {
                        lMark[target] = Mark.NONE
                        pCancelled = true
                        literal(at, key, false)
                        return
                    }
                    // Hat ↔ hook/breve swap (issue #149): 8 on â → ă, 6 on ă → â,
                    // 7 on ô → ơ, 6 on ơ → ô (ươ → uô via setCircumflex). Tone kept.
                    if (lMark[target] != Mark.BAR) {
                        if (mark == Mark.CIRCUMFLEX) setCircumflex(target) else lMark[target] = mark
                        rawLetter[at] = target
                        return
                    }
                    break
                }
                k--
            }
            literal(at, key, false)
            return
        }

        literal(at, key, false)
    }

    // MARK: - Tone placement

    private fun toneVowelIndex(count: Int): Int {
        var vcount = 0
        var start = 0
        if (count >= 2 && rBase[0] == 'q'.code && rBase[1] == 'u'.code && rMark[1] == Mark.NONE) {
            start = 2
        } else if (count >= 3 && rBase[0] == 'g'.code && rBase[1] == 'i'.code && rMark[1] == Mark.NONE &&
            isVowelAscii(rBase[2])
        ) {
            start = 2
        }
        for (k in start until count) if (isVowelAscii(rBase[k])) { vowelIdx[vcount] = k; vcount++ }
        if (vcount == 0) {
            for (k in 0 until count) if (isVowelAscii(rBase[k])) return k
            return count - 1
        }
        var lastMarked = -1
        for (j in 0 until vcount) if (rMark[vowelIdx[j]] != Mark.NONE) lastMarked = vowelIdx[j]
        if (lastMarked >= 0) return lastMarked
        if (vcount == 1) return vowelIdx[0]
        val hasCoda = vowelIdx[vcount - 1] < (count - 1)
        if (vcount == 2) {
            if (hasCoda) return vowelIdx[1]
            if (modernTone) {
                val a = rBase[vowelIdx[0]]
                val b = rBase[vowelIdx[1]]
                val glideInitial = (a == 'o'.code && (b == 'a'.code || b == 'e'.code)) ||
                    (a == 'u'.code && b == 'y'.code)
                if (glideInitial) return vowelIdx[1]
            }
            return vowelIdx[0]
        }
        return vowelIdx[1]
    }

    // MARK: - Diffing

    private fun commonPrefixLength(limit: Int): Int {
        var i = 0
        while (i < limit && scratch[i] == out[i]) i++
        return i
    }

    private fun diff(newCount: Int): TelexAction {
        val lcp = commonPrefixLength(minOf(newCount, outCount))
        val backspaces = outCount - lcp
        if (backspaces == 0 && lcp == newCount) return EMPTY_REPLACE
        val sb = StringBuilder(newCount - lcp)
        for (i in lcp until newCount) sb.appendCodePoint(scratch[i])
        return TelexAction.Replace(backspaces, sb.toString())
    }

    // MARK: - Small helpers

    private fun standaloneHornUAllowed(count: Int): Boolean {
        var node = 0
        for (k in 0 until count) {
            node = ONSETS_ALLOWING_STANDALONE_U.step(node, (lBase[k] - 'a'.code) and 0xFF)
            if (node < 0) return false
        }
        return ONSETS_ALLOWING_STANDALONE_U.mask(node) != 0
    }

    private fun hasVowel(count: Int): Boolean {
        for (k in 0 until count) if (isVowelAscii(lBase[k])) return true
        return false
    }

    private fun isUkRime(count: Int): Boolean =
        count >= 2 && rBase[count - 1] == 'k'.code && rBase[count - 2] == 'u'.code && rMark[count - 2] == Mark.HORN

    private fun hasStopCoda(count: Int): Boolean {
        if (count <= 0) return false
        val last = rBase[count - 1]
        if (last == 'p'.code || last == 't'.code || last == 'c'.code || last == 'k'.code) return true
        return last == 'h'.code && count >= 2 && rBase[count - 2] == 'c'.code
    }

    private fun lettersHaveStopCoda(count: Int): Boolean {
        if (count <= 0) return false
        val last = lBase[count - 1]
        if (last == 'p'.code || last == 't'.code || last == 'c'.code || last == 'k'.code) return true
        return last == 'h'.code && count >= 2 && lBase[count - 2] == 'c'.code
    }

    private fun lettersAreUkRime(count: Int): Boolean =
        count >= 2 && lBase[count - 1] == 'k'.code && lBase[count - 2] == 'u'.code && lMark[count - 2] == Mark.HORN

    private fun stopCodaRejectsTone(tone: Int): Boolean {
        if (tone != T.GRAVE && tone != T.HOOK && tone != T.TILDE) return false
        if (!lettersHaveStopCoda(pCount)) return false
        if (tone == T.GRAVE && lettersAreUkRime(pCount)) return false
        return true
    }

    private fun appendLetter(base: Int, mark: Int, upper: Boolean) {
        if (pCount >= CAPACITY) return
        lBase[pCount] = base
        lMark[pCount] = mark
        lUpper[pCount] = upper
        pCount++
    }

    companion object {
        const val CAPACITY = 32
        /** Ngưỡng luật tần suất (Swift frequencyVietnameseFloor / frequencyMargin). */
        const val FREQUENCY_VIETNAMESE_FLOOR = 140
        const val FREQUENCY_MARGIN = 45

        private const val CTX_ENGLISH = 0
        private const val CTX_VIETNAMESE = 1
        private const val CTX_NEUTRAL = 2
        private const val CTX_ENGLISH_FUNCTION = 3

        private val EMPTY_REPLACE = TelexAction.Replace(0, "")

        private const val INITIALS_MIN = 2
        private const val INITIALS_MAX = 4

        /** Swift `hatInitialismExcludedConsonants`: f j w z + stops c k p t g q. */
        private const val HAT_INITIALISM_EXCLUDED = "fjwzckptgq"

        /** Swift `hatInitialismEnglish`: English words / acronyms of the hat-initialism shape. */
        private val HAT_INITIALISM_ENGLISH: IntArray = arrayOf(
            "aah", "eel", "ooh", "owl", "awl", "aad", "oob", "awb", "awd", "uwb",
        ).map { w -> w.fold(0) { acc, ch -> (acc shl 8) or ch.code } }.toIntArray()

        private val ENGLISH_EXCEPTIONS: Array<IntArray> = arrayOf(
            "was".map { it.code }.toIntArray(),
            "wow".map { it.code }.toIntArray(),
            "yes".map { it.code }.toIntArray(),
            "queue".map { it.code }.toIntArray(),   // "quêu" passes the validator but is no Vietnamese word
            "away".map { it.code }.toIntArray(),    // aw+a swaps ă→â (issue #149): "away" would commit "ây"
        )

        private val ONSETS_ALLOWING_STANDALONE_U = ClassTrie(
            listOf(
                "", "b", "c", "ch", "d", "g", "h", "kh", "l", "m", "n", "ng", "nh",
                "ph", "r", "s", "t", "th", "tr", "v", "x", "gi",
            ).map { it to 1 }
        )

        /** Bracket key → horned vowel base ('o'/'u'), or -1. */
        internal fun bracketBase(key: Int): Int = when (key) {
            '['.code, '{'.code -> 'o'.code
            ']'.code, '}'.code -> 'u'.code
            else -> -1
        }

        private fun vniTone(d: Int): Int = when (d) {
            '1'.code -> T.ACUTE
            '2'.code -> T.GRAVE
            '3'.code -> T.HOOK
            '4'.code -> T.TILDE
            '5'.code -> T.DOT
            else -> -1
        }

        private fun vniMark(d: Int): Int = when (d) {
            '6'.code -> Mark.CIRCUMFLEX
            '7'.code -> Mark.HORN
            '8'.code -> Mark.BREVE
            '9'.code -> Mark.BAR
            else -> -1
        }

        private fun vniMarkAccepts(base: Int, mark: Int): Boolean = when (mark) {
            Mark.CIRCUMFLEX -> base == 'a'.code || base == 'e'.code || base == 'o'.code
            Mark.HORN -> base == 'o'.code || base == 'u'.code
            Mark.BREVE -> base == 'a'.code
            Mark.BAR -> base == 'd'.code
            else -> false
        }

        private fun quickTelexSecond(c: Int): Int = when (c) {
            'c'.code, 'k'.code, 'p'.code, 't'.code -> 'h'.code
            'g'.code -> 'i'.code
            'n'.code -> 'g'.code
            'q'.code -> 'u'.code
            else -> -1
        }

        private fun telexToneKey(t: Int): Char? = when (t) {
            T.ACUTE -> 's'; T.GRAVE -> 'f'; T.HOOK -> 'r'; T.TILDE -> 'x'; T.DOT -> 'j'; else -> null
        }

        private fun vniToneKey(t: Int): Char? = when (t) {
            T.ACUTE -> '1'; T.GRAVE -> '2'; T.HOOK -> '3'; T.TILDE -> '4'; T.DOT -> '5'; else -> null
        }

        private fun telexMarkExpansion(c: Int): String? = when (c) {
            'â'.code -> "aa"; 'ă'.code -> "aw"; 'ê'.code -> "ee"; 'ô'.code -> "oo"
            'ơ'.code -> "ow"; 'ư'.code -> "uw"; 'đ'.code -> "dd"; else -> null
        }

        private fun vniMarkExpansion(c: Int): String? = when (c) {
            'â'.code -> "a6"; 'ê'.code -> "e6"; 'ô'.code -> "o6"; 'ơ'.code -> "o7"
            'ư'.code -> "u7"; 'ă'.code -> "a8"; 'đ'.code -> "d9"; else -> null
        }

        /** Keystrokes that would compose `word`, or null if some character can't be typed. */
        private fun seedKeystrokes(word: String, vni: Boolean): String? {
            val sb = StringBuilder()
            var toneKey: Char? = null
            var i = 0
            while (i < word.length) {
                val cp = word.codePointAt(i)
                i += Character.charCount(cp)
                val isUpper = Character.isUpperCase(cp)
                val lower = Character.toLowerCase(cp)
                var toneless = lower
                val d = Tables.detone(lower)
                if (d >= 0) {
                    val t = d and 7
                    if (t != T.NONE) {
                        if (toneKey != null) return null
                        toneKey = if (vni) vniToneKey(t) else telexToneKey(t)
                    }
                    toneless = d shr 3
                }
                val expanded: String = (if (vni) vniMarkExpansion(toneless) else telexMarkExpansion(toneless))
                    ?: run {
                        if (toneless !in 'a'.code..'z'.code) return null
                        toneless.toChar().toString()
                    }
                if (isUpper) {
                    if (vni) {
                        sb.append(expanded[0].uppercaseChar()); sb.append(expanded, 1, expanded.length)
                    } else sb.append(expanded.uppercase())
                } else sb.append(expanded)
            }
            if (toneKey != null) sb.append(toneKey)
            return sb.toString()
        }
    }
}
