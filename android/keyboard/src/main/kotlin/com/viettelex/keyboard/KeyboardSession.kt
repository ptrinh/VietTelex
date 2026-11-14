package com.viettelex.keyboard


/** Phím gửi vào [KeyboardSession.handle] (≈ KeyboardView.Key iOS). */
sealed class Key {
    /** Phím chữ, đã theo shift. */
    data class Letter(val ch: Char) : Key()
    /**
     * Số / ký hiệu / dấu câu (boundary + ngắt câu). [replacesLetter]: ký tự phụ của cú giữ
     * phím chữ ([KeyAlternates]) — huỷ đúng phím chữ vừa chèn lúc chạm trước khi chèn.
     * [numpad]: số từ bàn phím số (numpad) của phím cứng — KHÔNG BAO GIỜ mang dấu VNI, luôn
     * là ranh giới như các bộ gõ phổ biến (#124). Cũng dùng cho ký tự phụ khi giữ ⇧ + phím chữ ([ShiftHold.key]).
     */
    data class Text(val text: String, val replacesLetter: Boolean = false, val numpad: Boolean = false) : Key()
    object Space : Key()
    /** Space thứ 2 trong < 0.35 s (IME đo nhịp). */
    object DoubleSpacePeriod : Key()
    object Newline : Key()
    /**
     * Giữ lâu Enter: chèn "\n" THẬT (commitText) — không performEditorAction, không
     * KEYCODE_ENTER (Zalo/Messenger bắt phím Enter thành "Gửi"). Chốt/học từ như [Newline].
     */
    object LineBreak : Key()
    object Backspace : Key()
    /** Trackpad: session reset; IME tự dời con trỏ [delta] ký tự, hoặc [delta] dòng
     *  khi [vertical] (âm = trái/lên). */
    data class MoveCursor(val delta: Int, val vertical: Boolean = false) : Key()
    /** 🗑 plane mẫu câu: xoá sạch ô (qua [TextProxy.clearAll]). */
    object ClearField : Key()
}

/** Đặc tính ô nhập (từ EditorInfo). */
data class FieldTraits(
    val isSecure: Boolean = false,
    /** Gõ literal, bỏ Telex (spec §12: URI/EMAIL/VISIBLE_PASSWORD/FILTER). */
    val passthrough: Boolean = false,
    /** TYPE_TEXT_FLAG_CAP_SENTENCES — auto-shift đầu câu. */
    val capSentences: Boolean = false,
    /** Ô cho phép thanh gợi ý (không secure, không passthrough, …). */
    val suggestionsAllowed: Boolean = true,
    /** TYPE_TEXT_FLAG_CAP_WORDS — auto-shift đầu mỗi từ (ô tên người, tiêu đề…). */
    val capWords: Boolean = false,
    /** TYPE_TEXT_FLAG_CAP_CHARACTERS — luôn viết hoa (mã, biển số…). */
    val capCharacters: Boolean = false,
    /**
     * EditorInfo.initialCapsMode ≠ 0 — editor tự tính lúc mở ô. Chỉ dùng khi KHÔNG đọc
     * được chữ trước con trỏ (getTextBeforeCursor = null) và chưa gõ phím nào.
     */
    val initialCaps: Boolean = false,
    /**
     * IME_FLAG_NO_PERSONALIZED_LEARNING (Chrome ẩn danh, app nhạy cảm): KHÔNG ghi từ vào
     * UserLangModel. Gợi ý vẫn hiện (chỉ đọc).
     */
    val noLearning: Boolean = false,
    /** EditorInfo.packageName — tra bảng [WriteMode]. */
    val packageName: String? = null,
    /** Ô URL (TYPE_TEXT_VARIATION_URI — omnibox tự hoàn tất): không gõ tắt. */
    val urlField: Boolean = false,
    /** Ô email (TYPE_TEXT_VARIATION_(WEB_)EMAIL_ADDRESS): thanh gợi ý chỉ hiện chip đuôi mail ([EmailDomains]). */
    val emailField: Boolean = false,
    /**
     * Ô email gõ Telex có bảo vệ địa chỉ ([EmailTokenGuard]; FieldMapping: email không FORCE_ASCII /
     * mật khẩu / TYPE_NULL). [passthrough] vẫn true ở ô này cho các tính năng khác (gõ tắt, tự sửa,
     * vuốt, phép tính, tự thêm dấu cách: vẫn TẮT) — chỉ engine bỏ literal. Song sinh iOS emailCompose.
     */
    val emailCompose: Boolean = false,
    /**
     * Ô CHỮ (không mật khẩu, không TYPE_NULL, không bàn số) — được hiện thanh công cụ
     * (☰/con trỏ/📋/⌄ + lời mời Dán) dù cấm gợi ý chữ (NO_SUGGESTIONS: Messenger chat với
     * Trang, #113). FieldMapping.map tính; mặc định false = như cũ (dải trống).
     */
    val stripTools: Boolean = false,
    /**
     * Ô địa chỉ / tìm kiếm (FieldMapping.isAddressOrSearch — thanh địa chỉ Firefox, #113): gợi ý
     * luôn chữ thường (không tên riêng [DisplayCase], không hoa đầu câu) và không auto-shift.
     */
    val lowercaseSuggestions: Boolean = false,
    /**
     * App tắt gợi ý ở ô CHỮ không nhạy cảm (TYPE_TEXT_FLAG_NO_SUGGESTIONS / VISIBLE_PASSWORD giả ở
     * ô chat — không mật khẩu, không passthrough). Cài đặt "Gợi ý cả khi ứng dụng tắt gợi ý" bật ⇒
     * vẫn gợi ý chữ đầy đủ (như Gboard, #113) nhưng KHÔNG tự sửa và KHÔNG học từ.
     */
    val appNoSuggestions: Boolean = false,
    /**
     * Ô địa chỉ / SĐT (EditorInfo inputType + hintText — FieldMapping.clipPreference): chip
     * clipboard loại đó lên đầu ([ClipDetect.prioritize]). Song sinh iOS preferredClipKind.
     */
    val clipPreference: ClipChip.Kind? = null,
    /** Bàn số (ô điện thoại / số / ngày giờ): không chip địa chỉ (ô không nhận chữ). */
    val numericPad: Boolean = false,
) {
    /** Cách ghi chữ vào ô theo app (bảng [WriteMode.forPackage]). */
    val writeMode: WriteMode get() = WriteMode.forPackage(packageName)
}

/** Dải gợi ý hiện gì ở ô hiện tại ([StripMode.of]). */
enum class StripMode {
    /** Tắt "Thanh gợi ý" trong cài đặt: không có dải. */
    OFF,
    /** Mật khẩu / ẩn danh / ô không phải chữ: dải trống giữ chiều cao, không UI clipboard. */
    BLANK,
    /** Ô cấm gợi ý chữ (NO_SUGGESTIONS, FORCE_ASCII…): ☰/con trỏ/📋/⌄ + Dán/chip clipboard, không chữ/tự sửa. */
    TOOLS,
    /** Gợi ý đầy đủ. */
    FULL;

    /** Dải có vẽ nội dung (thanh công cụ ± gợi ý). */
    val shown: Boolean get() = this == TOOLS || this == FULL

    companion object {
        /**
         * Ô app tắt gợi ý nhưng vẫn gợi ý chữ ("Gợi ý cả khi ứng dụng tắt gợi ý" [suggestAnyway],
         * #113). Không bao giờ ở mật khẩu / passthrough (email, số, FORCE_ASCII, TYPE_NULL) / ẩn danh.
         */
        fun overridesAppNoSuggest(suggestAnyway: Boolean, f: FieldTraits, incognito: Boolean): Boolean =
            suggestAnyway && f.appNoSuggestions && !f.isSecure && !f.passthrough && !incognito

        /** Gợi ý chữ được bật ở ô (kể cả chip đuôi mail ô email) = [KeyboardSession.suggestionsActive]. */
        fun wordsActive(showSuggestions: Boolean, f: FieldTraits, overrideNoSuggest: Boolean = false): Boolean = showSuggestions &&
            ((f.suggestionsAllowed && !f.isSecure && !f.passthrough) || (f.emailField && !f.isSecure) || overrideNoSuggest)

        /**
         * THUẦN: ô + cài đặt → dải hiện gì. [incognito] = ẩn danh thủ công HOẶC NO_PERSONALIZED_LEARNING.
         * [suggestAnyway] = cài đặt "Gợi ý cả khi ứng dụng tắt gợi ý" ([overridesAppNoSuggest]).
         */
        fun of(showSuggestions: Boolean, field: FieldTraits, incognito: Boolean, suggestAnyway: Boolean = false): StripMode = when {
            !showSuggestions -> OFF
            wordsActive(true, field, overridesAppNoSuggest(suggestAnyway, field, incognito)) -> FULL
            field.isSecure || incognito || !field.stripTools -> BLANK
            else -> TOOLS
        }

        /**
         * THUẦN: học từ ở ô này? Ô app tắt gợi ý ([FieldTraits.appNoSuggestions]) VẪN học như ô
         * thường (Phil 05/10: ô chat Messenger là nơi gõ nhiều nhất); ô nhạy cảm (mật khẩu, OTP, số)
         * không bao giờ thành appNoSuggestions và đã không học ở tầng khác; ẩn danh thì không học.
         */
        fun learns(learnWords: Boolean, field: FieldTraits, incognito: Boolean): Boolean =
            learnWords && !incognito && !field.emailCompose   // ô email: không học tên/địa chỉ
    }
}

/**
 * Cách lớp ghi (IcProxy) đẩy chữ vào ô — vài editor văn phòng xử lý sai
 * commitText/deleteSurroundingText.
 *
 * IcProxy.writeMode áp bảng này (VietTelexIME.onStartInputView):
 *  - [COMMIT]: commitText + deleteSurroundingTextInCodePoints.
 *  - [DEL_VIA_KEY_EVENT]: commitText nhưng xoá bằng KEYCODE_DEL (ONLYOFFICE bỏ qua deleteSurroundingText).
 *  - [KEY_ONLY]: mọi thứ qua key event (WPS bản Xiaomi/Huawei, HSL).
 */
enum class WriteMode {
    COMMIT, DEL_VIA_KEY_EVENT, KEY_ONLY;

    companion object {
        private val KEY_ONLY_PKGS = listOf("com.huawei.hsl", "cn.wps.huawei")

        fun forPackage(pkg: String?): WriteMode {
            if (pkg.isNullOrEmpty()) return COMMIT
            fun under(base: String) = pkg == base || pkg.startsWith("$base.")
            return when {
                pkg.startsWith("com.xiaomi.wps") || KEY_ONLY_PKGS.any(::under) -> KEY_ONLY
                pkg.startsWith("com.onlyoffice.") -> DEL_VIA_KEY_EVENT
                else -> COMMIT
            }
        }
    }
}

/** Kiểu viết hoa tự động của ô (TYPE_TEXT_FLAG_CAP_*). */
enum class CapMode { NONE, SENTENCES, WORDS, CHARACTERS }

/** Kết quả một phím: IME dùng [generation] để coalesce auto-shift + gợi ý 30 ms. */
data class KeyOutcome(val needsAutoShift: Boolean, val generation: Int)

/** Nội dung thanh gợi ý (≈ KeyboardView.SuggestionSet). */
data class SuggestionSet(
    val literal: String? = null,
    val word: String? = null,
    /** Ứng viên inline thứ hai (khi không có emoji). */
    val word2: String? = null,
    val emojis: List<String> = emptyList(),
    /** Gợi ý khi CHƯA gõ (đầu câu / sau space / email / TLD). */
    val nextWords: List<String> = emptyList(),
    /** Thẻ Dán thay cả bar. */
    val paste: Boolean = false,
    val pasteIsImage: Boolean = false,
    /** Chip số (NumberChips) — luôn ở slot GIỮA; chạm gửi [NUMBER_TOKEN]. */
    val number: String? = null,
    /** Kết quả phép tính "…=" ([MathResults]) — slot ĐẦU; chạm gửi [MATH_TOKEN]. */
    val math: String? = null,
    /** Chip tách số (OTP/SĐT/STK) từ nội dung vừa copy — thay thẻ Dán. */
    val clipChips: List<ClipChip> = emptyList(),
    /** Chip hành động ở slot trái khi chưa gõ ("Thêm dấu" / "↩︎ Hoàn tác") — payload [action]. */
    val actionLabel: String? = null,
    val action: String? = null,
    /**
     * Chưa có ngữ cảnh gõ (ô trống / chưa có từ trước, không đang soạn) — từ phổ biến chỉ là
     * đệm. StripView (#113): idle ⇒ vẫn hiện icon con trỏ + 📋 như Gboard khi chưa gõ.
     */
    val idle: Boolean = false,
    /** Ứng viên inline thứ 3, 4… (chỉ khi "Số từ gợi ý" > 3 — [SuggestionCount]). */
    val moreWords: List<String> = emptyList(),
    /**
     * ONBOARDING-SPEC §8: từ đang soạn gõ sai và [word] là bản tự sửa đủ chắc — ô [word] tô nền
     * (dấu cách sẽ thay đúng chữ này khi "Tự sửa từ gõ sai" bật), [literal] trong ngoặc kép, chạm
     * gửi [KEEP_TYPED_PREFIX] + chữ gốc (giữ nguyên + không sửa lại).
     */
    val correction: Boolean = false,
) {
    val isEmpty: Boolean get() = literal == null && word == null && word2 == null && moreWords.isEmpty() && emojis.isEmpty() &&
        nextWords.isEmpty() && number == null && math == null
    /** So để bỏ vẽ lại khi không đổi. */
    fun signature(): String = listOf(literal, word, word2, emojis.joinToString("\u0002"),
        nextWords.joinToString("\u0002"), paste.toString(), number, math,
        clipChips.joinToString("\u0002") { it.label + "\u0003" + it.value }, action, actionLabel, idle.toString(),
        moreWords.joinToString("\u0002"), correction.toString()).joinToString("\u0001")

    companion object {
        /** Payload chạm thẻ Dán → truyền vào acceptSuggestion. */
        const val PASTE_TOKEN = "paste"
        const val PASTE_IMAGE_TOKEN = "pasteImage"
        /** Payload chạm chip số (session giữ NumberChip: đuôi cần thay + chữ chèn). */
        const val NUMBER_TOKEN = "\uE000number"
        /** Payload chạm chip kết quả phép tính (session giữ chữ cần chèn). */
        const val MATH_TOKEN = "\uE000math"
        /** Payload chip tách số clipboard: tiền tố + giá trị cần dán (không space, không học). */
        const val CLIP_CHIP_PREFIX = "\uE000clip:"
        /** Chip "Thêm dấu" / "Hoàn tác" (ký tự Private Use — không thể là từ thật). */
        const val ADD_TONES_TOKEN = "\uE000addTones"
        const val UNDO_TONES_TOKEN = "\uE000undoTones"
        /** Chip "↩︎ từ cũ": hoàn tác lần vuốt vừa sửa lại từ vuốt trước (SwipeRevise). */
        const val UNDO_REVISE_TOKEN = "\uE000undoRevise"
        /** Chip "↩︎ chữ gốc": trả lại chữ đã gõ của lần tự sửa vừa rồi ([AutoCorrect]). */
        const val UNDO_AUTOCORRECT_TOKEN = "\uE000undoAutoCorrect"
        /** Chip sửa ngược tiếng Anh ("His car is") — công tắc "Tự sửa từ phía trước" TẮT. */
        const val RETRO_OFFER_TOKEN = "\uE000retroOffer"
        /** Chip "↩︎ Khôi phục" sau khi tự sửa ngược (công tắc BẬT). */
        const val UNDO_RETRO_TOKEN = "\uE000undoRetro"
        /** Chạm ô ngoặc kép khi có ô tô nền (§8): tiền tố + chữ gốc — giữ nguyên, ghi "từng hoàn tác tự sửa". */
        const val KEEP_TYPED_PREFIX = "\uE000keep:"
    }
}

sealed class SuggestionPlan {
    /** Vẽ ngay; [set] null = không vẽ gì (bar tắt / thu gọn). */
    data class Ready(val set: SuggestionSet?) : SuggestionPlan()
    /** Chạy [SuggestJob.compute] ở thread nền, rồi [KeyboardSession.completeSuggestions] trên main. */
    class Background(val job: SuggestJob) : SuggestionPlan()
}

/** Phần nặng của gợi ý khi đang gõ dở (VNSuggest + AdjacentKeyFixer) — thread-safe. */
class SuggestJob internal constructor(
    internal val req: Int, internal val gen: Int, internal val bridge: EngineBridge,
    val composed: String, val raw: String, internal val predicted: String, private val wantFix: Boolean,
    /** Âm tiết liền trước (bigram tĩnh). */
    private val prev: String? = null,
    internal val number: String? = null,
    internal val math: String? = null,
    /** Âm tiết trước nữa (trigram tĩnh). */
    private val prev2: String? = null,
    /** Tô nền gợi ý sửa (§8) bật: từ không khớp gì ⇒ tính luôn [AutoCorrect.plan] ở thread nền. */
    private val wantPlan: Boolean = false,
) {
    class Result(val pool: List<VNSuggest.Match>, val fix: String?, val pmi: FloatArray? = null,
                 /** Trượt vào phím thanh mà vẫn ra từ ("casn" → cân) — slot 3. */
                 val slip: String? = null,
                 /** Từ tiếng Anh giữa câu Việt ([EnglishAssist]) — null khi từ rõ là tiếng Việt. */
                 val english: EnglishAssist.Result? = null,
                 /** Phần thuần của tự sửa ([AutoCorrect.plan]) — chỉ khi từ không khớp gì. */
                 val plan: AutoCorrect.Plan? = null)
    fun compute(): Result {
        // Chế độ Tiếng Anh: hoàn thành từ enlexicon, không sửa chạm trượt / bigram Việt.
        if (bridge.englishMode) return Result(SwipeEnglish.completions(composed, 24), null)
        val pool = VNSuggest.matches(composed, poolLimit = 24, excluding = composed.lowercase())
        val fix = if (pool.isEmpty() && wantFix) AdjacentKeyFixer.lexiconCorrection(raw, bridge) else null
        val slip = if (fix == null && wantFix) AdjacentKeyFixer.lexiconToneSlip(raw, bridge) else null
        // Từ tiếng Anh giữa câu Việt: hoàn thành / sửa chính tả theo phím thô; từ rõ là tiếng Việt ⇒
        // null trước khi chạm lexicon tiếng Anh.
        val english = if (EnglishAssist.eligible(raw))
            EnglishAssist.suggest(raw, composed, pool, VNSuggest.frequency(composed)) else null
        val plan = if (wantPlan && pool.isEmpty()) AutoCorrect.plan(raw, compose = { bridge.composeTrial(it) },
            frequency = { VNSuggest.frequency(it) },
            hasCompletion = { VNSuggest.matches(it, poolLimit = 1).isNotEmpty() }) else null
        // Có plan ⇒ main sắp hỏi "từ tiếng Anh?" ([AutoCorrect.isEnglishIfLoaded], không nạp): nạp ở đây.
        if (plan != null) SwipeEnglish.warm()
        return Result(pool, fix, SuggestRank.inlinePmi(pool, prev, prev2 = prev2), slip, english, plan)
    }
}

/**
 * "Bộ não" controller — port 1:1 phần logic của KeyboardViewController.swift (không UI):
 * engine bridge, học từ, gợi ý 6 tầng, backspace-undo auto-restore, nút Dán, xoá theo
 * từ, mẫu câu. Mọi hàm gọi trên MAIN thread, trừ [SuggestJob.compute].
 */
class KeyboardSession(
    val langModel: UserLangModel,
    private val clipboard: ClipboardSource? = null,
    /** Đồng hồ ms (nút Dán: 180 s / cache 2 s). */
    private val clock: () -> Long = System::currentTimeMillis,
) {
    var bridge = EngineBridge(); private set
    private var lastWord: String? = null
    private var lastWord2: String? = null
    /**
     * "Emoji theo chữ" ([EmojiWords]): IME bật khi chọn kiểu đó ⇒ ở RANH GIỚI TỪ (dấu cách / dấu câu) ghi
     * từ vừa chốt + từ liền trước. Tắt (mặc định) ⇒ không ghi gì.
     */
    var trackBoundaryWord = false
    /**
     * Sút! (theme Bóng đá): bộ so cụm cổ vũ ([CheerWords.Matcher]) — IME đặt CHỈ khi hiệu ứng Sút! đang chọn (null = 0
     * chi phí). [cheerHit] = phím vừa rồi gõ xong một cụm ⇒ IME xếp pháo sáng + cờ. iOS KeyboardViewController.fxCheer.
     */
    var cheer: CheerWords.Matcher? = null
    var cheerHit = false; private set
    /** Từ vừa chốt ở phím ranh giới gần nhất (null = phím vừa rồi không phải ranh giới có từ). */
    var boundaryWord: String? = null; private set
    var boundaryPrev: String? = null; private set
    /** Từ trước nữa (bộ ba tục — Bạn đồng hành). */
    var boundaryPrev2: String? = null; private set
    private var learnEnabled = true
    /** Ẩn danh (thủ công HOẶC IME_FLAG_NO_PERSONALIZED_LEARNING): không học, không lưu clipboard. */
    var incognito = false; private set
    /** Lịch sử clipboard — null khi tắt (IME set theo setting, lo đọc/ghi file). */
    var clipHistory: ClipboardHistory? = null
    private var filterSensitive = true
    private var traits = FieldTraits()
    private var lastResetAt: Long? = null
    /** Chưa gõ phím nào từ startInput — [FieldTraits.initialCaps] còn hiệu lực. */
    private var initialCapsPending = true
    /**
     * Lần [updateAutoShift] gần nhất chạy KHÔNG đọc ô (allowRead = false, khung đầu) và không có chữ
     * sẵn ⇒ shift là phỏng đoán theo [FieldTraits.initialCaps]; IME gọi lại có đọc sau khung đầu.
     */
    var autoShiftUnverified = false; private set

    /** Tăng mỗi phím — IME so với KeyOutcome.generation để bỏ lượt cũ. */
    var generation = 0; private set
    private var suggestReq = 0
    private var lastInsertWasSpace = false
    /** Auto-shift đang bật (gợi ý viết hoa chữ đầu). */
    var autoShiftOn = false; private set
    /**
     * Shift THẬT của bàn phím ảo (IME báo trước mỗi lượt gợi ý / khi Shift đổi) — hoa/thường
     * gợi ý theo [SuggestionCase] như Gboard. null = không có bàn phím ảo (test thuần / chỉ
     * phím cứng) ⇒ suy từ [autoShiftOn].
     */
    var keyboardShift: SuggestionCase.Shift? = null
    /** Shift lúc tính bar lần cuối — đổi Shift mà bar đã đúng thì khỏi tính lại. */
    private var barShift = SuggestionCase.Shift.OFF
    /** Công tắc "Tự động viết hoa đầu câu" ([KeyboardSettings.autoCapitalize]). */
    var autoCapitalize = true
    /** Bar tắt ở setting hoặc ô cấm. */
    var suggestionsActive = true; private set
    /** Dải hiện gì ở ô này — TOOLS: chỉ thanh công cụ + lời mời Dán (không chữ). */
    var stripMode = StripMode.FULL; private set
    /**
     * Ô email (literal): thanh chỉ hiện chip đuôi mail sau "@" ([EmailDomains], như iOS) — đọc
     * context mỗi lượt gợi ý CHỈ ở ô email; ô khác không qua nhánh này (0 chi phí).
     */
    private var emailBar = false
    /** Bar thu gọn — pipeline gợi ý ngừng. Nút ⌄ đã bỏ (10/2026): IME luôn đặt false. */
    var barCollapsed = false
    private var lastKeyWasEmailTrigger = false
    /** Số dấu cách kể từ chữ số/phép tính cuối (≤1 → đáng đọc context tìm chip số). */
    private var numberSpaces = 99
    /** Chip số đang hiện — payload [SuggestionSet.NUMBER_TOKEN]. */
    private var numberChip: NumberChip? = null
    private var restoreUndoRaw: String? = null
    private var restoreUndoComposed: String? = null
    private var undoOfferActive = false
    private var ctxCacheKey: String? = null
    /** Từ chốt gần nhất + biên nhận học — ⌫ mở lại từ đó thì rút lại lượt học (không học trùng). */
    private class LastCommit(val word: String, val prev1: String?, val prev2: String?, val learned: UserLangModel.Learned?)
    private var lastCommit: LastCommit? = null
    private var ctxCache: Set<String> = emptySet()
    /** Thêm dấu vừa áp (chip "Hoàn tác" / ⌫ ngay sau) — sống tới phím kế. */
    private var tonesUndo: AddTones.Plan? = null
    /**
     * Gợi ý vừa nhận đã chèn chuỗi này ("từ "): phím kế là . , ? ! ) hay nháy đóng ⇒ xoá dấu
     * cách đó (AutoSpace.snapsSuggestionSpace). Mọi phím / đổi con trỏ khác bỏ.
     */
    private var suggestionSnap: String? = null
    /** Đoạn vừa hoàn tác — không mời lại đúng đoạn đó. */
    private var tonesDismissed: String? = null
    private var tonesCacheBefore: String? = null
    private var tonesCachePlan: AddTones.Plan? = null
    /** Công tắc chip "Thêm dấu" tự hiện ([KeyboardSettings.addTonesChip]) — tắt ⇒ 0 việc mỗi dấu cách. */
    private var addTonesChip = false
    /** Công tắc chip số ([KeyboardSettings.numberChips]) — tắt ⇒ không đọc context sau chữ số. */
    private var numberChipsOn = true
    /**
     * Số ứng viên xin cho thanh gợi ý ("Số từ gợi ý", Tự động = 3). StripView có thể hiện ít hơn
     * khi chật ([SuggestionCount.fit]) — phần dư bỏ, không tốn thêm gì ngoài ≤ 5 ứng viên.
     */
    private var slotWant = SuggestionCount.AUTO_SLOTS
    /** "Hiện kết quả phép tính" ([KeyboardSettings.mathResults]) + ô cho phép (không mật khẩu/URL/email). */
    private var mathOn = true
    /** Phím vừa gõ là "=" — chỉ khi đó mới đọc context tìm kết quả phép tính; phím khác ⇒ 0 việc. */
    private var mathArmed = false
    /** Chip kết quả phép tính đang hiện — payload [SuggestionSet.MATH_TOKEN]. */
    private var mathChip: NumberChip? = null

    /** Từ vựng vuốt vừa đổi ở [startInput] (bảng gõ tắt) — IME lấy một lần để dựng lại template nền. */
    private var swipeVocabChanged = false
    fun takeSwipeVocabChanged(): Boolean = swipeVocabChanged.also { swipeVocabChanged = false }

    /** Gõ vuốt bật cho ô hiện tại (IME quyết: setting + loại ô + TalkBack). */
    var swipeTypingActive = false
        private set
    /** Từ vừa vuốt, còn là composition đang mở (null khi phím/thao tác khác xen vào). */
    private var swipeWord: String? = null
    private var swipeAlts: List<String> = emptyList()
    /** Từ vuốt đang mở là tiếng Anh chèn NGUYÊN VĂN (engine trống — không seed Telex). */
    private var swipeLiteral = false
    /** Phương án tiếng Anh trong [swipeAlts] (chèn nguyên văn khi chọn). */
    private var swipeEnglishAlts: Set<String> = emptySet()
    /**
     * Vuốt KHOÁ gõ tắt ("vn"): [swipeWord] là nội dung đã bung (nguyên văn), đây là khoá (đúng hoa/
     * thường như vuốt) — ⌫ đầu trả lại khoá như hoàn tác gõ tắt gõ tay. = iOS SwipeOpen.shortcutKey.
     */
    private var swipeShortcutKey: String? = null
    /** Từ TIẾNG ANH vừa vuốt bị phím chữ chốt (+ dấu cách) — phím đó là chạm đầu của cú vuốt mới. */
    private var literalAfterLetter: String? = null
    /** Sau khi gỡ phím chữ đó (cú vuốt mới bắt đầu): từ Anh đứng ngay trước "từ ␠" — để viết hoa
     *  ngược chuỗi tên riêng ("new" + "york" → "New York"). Hết hạn ở phím kế ([clearSwipe]). */
    private var swipedLiteralPrev: String? = null
    /** Vuốt ra từ tiếng Anh (công tắc con, [KeyboardSettings.swipeEnglish]). */
    var swipeEnglish = true
    /**
     * Từ vuốt Việt vừa chèn + ứng viên đã chấm — cú vuốt NGAY SAU được sửa lại nó theo ngữ
     * cảnh hai phía (SwipeRevise). Chỉ sống qua đúng một phím chữ bị huỷ thành đầu cú vuốt kế.
     */
    private class Revisable(val word: String, val scored: List<SwipeWord>, val case: SwipeSuggest.Case)
    private var revisable: Revisable? = null
    private var revisableAfterLetter: Revisable? = null
    /** Phím vừa xử lý là phím chữ ĐẦU sau từ vuốt Việt — giữ phím đó ra số thì vẫn là "ngay sau vuốt". */
    private var letterAfterSwipe = false
    /** Vừa sửa lại từ trước: (từ cũ, từ mới) — chip "↩︎ từ cũ", sống khi từ vuốt kế còn mở. */
    private var reviseUndo: Pair<String, String>? = null
    /**
     * Từ vuốt Việt còn nguyên vừa được dấu cách chốt ⇒ chờ từ GÕ PHÍM kế tiếp: ranh giới chốt
     * từ đó thì chấm lại từ vuốt ([SwipeRevise.reviseTyped]). [learned] = lượt học của từ vuốt
     * (rút lại khi thay). Sống qua các phím chữ / ⌫ trong từ gõ; phím/thao tác khác ⇒ bỏ.
     */
    private class TypedPending(val rev: SwipeRevise.Typed, val learned: LastCommit?)
    private var typedPending: TypedPending? = null
    /** Vừa sửa lại từ vuốt khi từ gõ kế được chốt — chip "↩︎ từ cũ", sống tới phím kế. */
    private class TypedUndo(val edit: SwipeRevise.TypedEdit, val newLearned: LastCommit?, val sentenceBreak: Boolean)
    private var typedUndo: TypedUndo? = null
    /** Vài từ tiếng Anh vừa vuốt ra (chữ thường) — ngữ cảnh ngôn ngữ cho cú vuốt kế. */
    private val recentEnglish = ArrayDeque<String>()
    /**
     * ≤ 3 từ vừa chốt (cũ → mới) cho tiền nghiệm liên tục ngôn ngữ của gõ vuốt — KHÔNG xoá ở dấu
     * câu (đang viết đoạn tiếng Anh thì câu sau vẫn là tiếng Anh), chỉ xoá khi đổi ô / con trỏ
     * nhảy. Chỉ đẩy một tham chiếu chuỗi mỗi từ.
     */
    private val langRecent = ArrayDeque<String>()
    /** Vuốt phím cách đổi Tiếng Việt ↔ Tiếng Anh ([KeyboardSettings.spaceSwipeLanguage]). */
    var spaceFlickEnabled = false; private set
    /** Ngôn ngữ đang gõ; công tắc tắt ⇒ luôn VI. */
    var language = KeyboardLanguage.VI; private set
    /** "Tự thêm dấu cách sau dấu câu" bật VÀ ô cho phép (không mật khẩu/email/URL/số). */
    private var autoSpaceOn = false
    /** Dấu câu/ngoặc vừa được thêm dấu cách tự động ([AutoSpace]) — sống tới phím kế. */
    private var autoSpacePunct: Char? = null
    /** Phím chữ gõ ngay sau dấu cách tự thêm — giữ phím ra dấu câu huỷ phím chữ đó. */
    private var autoSpaceUnderLetter: Char? = null

    /**
     * Tự sửa (Thử nghiệm): điểm chạm từng phím của từ đang gõ ([AutoCorrect.Touch]). Hỏng
     * ([wordTouchesOk] = false) khi có phím không kèm điểm chạm, ⌫ giữa từ, từ nạp lại… ⇒ từ đó
     * không tự sửa. Chỉ ghi khi công tắc bật ([autoCorrectOn]).
     */
    private val wordTouches = ArrayList<AutoCorrect.Touch>(12)
    private var wordTouchesOk = false
    private var autoCorrectOn = false
    /**
     * ONBOARDING-SPEC §8 — tô nền gợi ý sửa: thanh gợi ý chữ đang bật ở ô tự sửa được (không VNI).
     * Bật cả khi công tắc tự sửa TẮT (ô tô nền chỉ là gợi ý); thanh tắt ⇒ false, 0 việc.
     */
    private var correctionHintOn = false
    /** IME chỉ cần gửi điểm chạm phím chữ khi tự sửa / tô nền gợi ý sửa bật ở ô này (tắt ⇒ 0 cấp phát). */
    val wantsTouches: Boolean get() = autoCorrectOn || correctionHintOn
    /** Quyết định tự sửa của từ đang soạn (phím thô → bản sửa) — ô tô nền và dấu cách dùng CHUNG. */
    private var acMemo: Pair<String, String?>? = null
    /**
     * ONBOARDING-SPEC §8 — thanh gợi ý vừa hiện gì cho từ đang soạn (phím thô → ô tô nền, null =
     * không tô). Dấu cách dùng ĐÚNG cái này khi thanh đã dựng cho từ này ([autoCorrection]) ⇒ không
     * bao giờ sửa khác ô tô nền, không tô ⇒ không sửa. Phím chữ mới / đổi ô ⇒ null.
     */
    private var shownCorrection: Pair<String, String?>? = null
    /** Từ từng hoàn tác tự sửa — không bao giờ sửa lại (IME nạp/lưu, [onAutoCorrectRejected]). */
    var autoCorrectRejected = AutoCorrect.Rejected()
    /** Vừa thêm một từ vào [autoCorrectRejected] — IME lưu [AutoCorrect.Rejected.encode]. */
    var onAutoCorrectRejected: (() -> Unit)? = null

    init {
        langModel.isKnownWord = { VNSuggest.contains(it) }
        langModel.seedIfEmpty(SeedData::load)
    }

    // MARK: vòng đời

    /** onStartInputView: settings mới, bridge mới, reset trạng thái (viewWillAppear). */
    fun startInput(settings: KeyboardSettings, field: FieldTraits) {
        if (lastResetAt != null && lastResetAt != settings.userlmResetAt) langModel.reloadAfterExternalErase()
        lastResetAt = settings.userlmResetAt
        if (TouchLog.enabled) {
            fun b(v: Boolean) = if (v) 1 else 0
            TouchLog.session("secure=${b(field.isSecure)} pass=${b(field.passthrough)} sugg=${b(field.suggestionsAllowed)}" +
                " email=${b(field.emailCompose)} url=${b(field.urlField)}", TouchLogFormat.settingsLines(settings))
        }
        bridge = EngineBridge(settings)
        // Ô email: Telex BẬT + bảo vệ địa chỉ; không gõ tắt (app đổi chữ thành chip người nhận).
        bridge.passthrough = field.passthrough && !field.emailCompose
        bridge.emailField = field.emailCompose
        bridge.shortcutsAllowed = !field.urlField && !field.emailCompose
        traits = field
        lastKeyWasEmailTrigger = false
        clearUndo()
        incognito = settings.incognito || field.noLearning
        learnEnabled = StripMode.learns(settings.learnWords, field, incognito)
        initialCapsPending = true
        filterSensitive = settings.filterSensitive
        SwipeVocab.filterSensitive = settings.filterSensitive   // gõ vuốt theo cùng công tắc
        SwipeVocab.teencode = settings.teencode && !settings.vniMode   // er → ẻ (nét Telex)
        // Gõ tắt vuốt được (khoá + từ của nội dung): bảng đổi ⇒ IME dựng lại template một lần (nền).
        if (settings.swipeTyping && SwipeVocab.setShortcuts(bridge.effectiveShortcuts)) swipeVocabChanged = true
        swipeEnglish = settings.swipeEnglish
        autoCapitalize = settings.autoCapitalize
        recentEnglish.clear(); langRecent.clear()
        emailBar = settings.showSuggestions && field.emailField && !field.isSecure
        clipPreference = field.clipPreference
        numericPad = field.numericPad
        suggestionsActive = StripMode.wordsActive(settings.showSuggestions, field,
            StripMode.overridesAppNoSuggest(settings.suggestInNoSuggestFields, field, incognito))
        stripMode = StripMode.of(settings.showSuggestions, field, incognito, settings.suggestInNoSuggestFields)
        lastWord = null; lastWord2 = null
        lastInsertWasSpace = false
        lastCommit = null
        clearSwipe()
        setSwipeTyping(false)
        tonesUndo = null; tonesDismissed = null; tonesCacheBefore = null; tonesCachePlan = null
        suggestionSnap = null
        addTonesChip = settings.addTonesChip
        numberChipsOn = settings.numberChips
        slotWant = SuggestionCount.resolved(settings.suggestionCount)
        mathOn = settings.mathResults && !field.isSecure && !field.passthrough && !field.urlField
        mathArmed = false; mathChip = null
        spaceFlickEnabled = settings.spaceSwipeLanguage
        language = KeyboardLanguage.VI
        autoSpaceOn = settings.autoSpaceAfterPunct && !field.isSecure && !field.passthrough && !field.urlField
        autoSpacePunct = null; autoSpaceUnderLetter = null
        // Tự sửa: không ở ô mật khẩu/email/URL/không-gợi-ý (kể cả khi vẫn gợi ý bất chấp app — chỉ gợi ý), ô tên (viết hoa mỗi từ), VNI.
        autoCorrectOn = settings.autoCorrect && !settings.vniMode && AutoCorrect.fieldAllows(field)
        correctionHintOn = suggestionsActive && stripMode == StripMode.FULL && !settings.vniMode && AutoCorrect.fieldAllows(field)
        wordTouches.clear(); wordTouchesOk = false; acMemo = null; shownCorrection = null
        bridge.autoCorrector = if (autoCorrectOn) ::autoCorrection else null
    }

    /**
     * [EngineBridge.autoCorrector]: chỉ khi có đủ điểm chạm cho đúng các phím của từ. Thanh gợi ý đã
     * dựng cho đúng từ này ⇒ áp ĐÚNG ô đã tô (không tô ⇒ không sửa); chưa dựng / thanh tắt ⇒ tính.
     */
    private fun autoCorrection(raw: String): String? {
        if (!wordTouchesOk || wordTouches.size != raw.length) return null
        if (suggestionsActive && correctionHintOn && !barCollapsed) shownCorrection?.let { (r, fix) -> if (r == raw) return fix }
        return correctionDecision(raw, null)
    }

    /**
     * Quyết định tự sửa cho từ đang soạn [raw] — MỘT nguồn cho ô tô nền (thanh gợi ý) và dấu cách
     * (ONBOARDING-SPEC §8): tính một lần cho mỗi bộ (phím thô, điểm chạm), lần sau dùng lại ⇒ dấu
     * cách không bao giờ ra chữ khác ô đã tô. [plan]: phần thuần thanh gợi ý đã tính ở thread nền.
     */
    private fun correctionDecision(raw: String, plan: AutoCorrect.Plan?): String? {
        if (!wordTouchesOk || wordTouches.size != raw.length) return null
        acMemo?.let { (r, fix) -> if (r == raw) return fix }
        val b = bridge
        val pl = plan?.takeIf { it.raw == raw } ?: AutoCorrect.plan(raw, compose = { b.composeTrial(it) },
            frequency = { VNSuggest.frequency(it) },
            hasCompletion = { VNSuggest.matches(it, poolLimit = 1).isNotEmpty() })
        val fix = pl?.let { AutoCorrect.decide(it, wordTouches, ::isKnownForAutoCorrect) }
        acMemo = raw to fix
        return fix
    }

    /**
     * MAIN thread ⇒ KHÔNG nạp enlexicon ([AutoCorrect.isEnglishIfLoaded]). Chưa nạp (đầu phiên / vừa
     * nhả lúc ẩn lâu, worker chưa hâm xong) ⇒ coi là ĐÃ BIẾT ⇒ không sửa: thà bỏ lỡ một lần sửa còn
     * hơn sửa nhầm từ tiếng Anh sang tiếng Việt. Worker hâm nóng trước khi thanh gợi ý cần
     * ([SuggestJob.compute] khi có plan; IME lúc hiện khi bật Tự sửa — [warmEnglishOnShow]).
     */
    private fun isKnownForAutoCorrect(w: String): Boolean =
        w in autoCorrectRejected || langModel.isUserWord(w) || (AutoCorrect.isEnglishIfLoaded(w) ?: true)

    /**
     * Tự sửa ở dấu cách (Thử nghiệm) bật ⇒ IME hâm nóng enlexicon trên worker lúc hiện
     * ([SwipeEnglish.warm]) — kể cả khi thanh gợi ý tắt (không có [SuggestJob] nào hâm). Chỉ tô nền
     * sửa (mặc định) thì [SuggestJob.compute] hâm lười khi có plan — phiên mặc định không nạp sẵn.
     */
    val warmEnglishOnShow: Boolean get() = autoCorrectOn

    /** ⌫ / chip vừa trả lại chữ gốc: nhớ để không sửa lại, học chữ gốc thay từ đã sửa. */
    private fun onAutoCorrectReverted(original: String, fixed: String?) {
        if (autoCorrectRejected.add(original)) onAutoCorrectRejected?.invoke()
        acMemo = null
        val lc = lastCommit
        lastCommit = null
        if (lc != null && lc.word == fixed) {
            lc.learned?.let { langModel.retract(it) }
            lastWord = lc.prev1; lastWord2 = lc.prev2
        }
        commitAndLearn(original)
    }

    /** Sau [startInput]: khôi phục ngôn ngữ đã lưu ([Keys.KEYBOARD_LANGUAGE]). */
    fun restoreLanguage(stored: String?, proxy: TextProxy) {
        language = KeyboardLanguage.effective(stored, spaceFlickEnabled)
        bridge.setEnglish(language == KeyboardLanguage.EN, proxy)
    }

    /**
     * Vuốt phím cách: đổi Tiếng Việt ↔ Tiếng Anh. Trả ngôn ngữ mới (IME lưu + vẽ), null khi
     * công tắc tắt.
     *
     * Đang gõ dở một từ (ONBOARDING-SPEC §7) ⇒ CHUYỂN luôn từ đó sang ngôn ngữ đích, từ vẫn mở
     * ([EngineBridge.convertComposing]: "Hí" ⇄ "His"). Không áp ([convertWord] = false — IME
     * đang ở bảng số/emoji), từ vuốt còn mở (gõ vuốt: từ từ điển, phím gốc là phím tổng hợp
     * ⇒ chốt nguyên như cũ), hay không chuyển được ⇒ như cũ: chốt từ (học như ranh giới, không
     * chèn gì) rồi đổi.
     */
    fun toggleLanguage(proxy: TextProxy, convertWord: Boolean = true): KeyboardLanguage? {
        if (!spaceFlickEnabled) return null
        val swiped = openSwipeWord()
        val literal = if (swipeLiteral) swiped else null
        clearSwipe(); clearUndo(); tonesUndo = null
        if (literal != null) settleLiteral(literal)
        language = language.toggled
        val toEnglish = language == KeyboardLanguage.EN
        val converted = convertWord && swiped == null && bridge.convertComposing(toEnglish, proxy)
        if (!converted) {
            val committed = bridge.setEnglish(toEnglish, proxy)
            if (literal == null) commitAndLearn(committed)
        }
        lastInsertWasSpace = false
        generation++
        return language
    }

    /** IME bật/tắt gõ vuốt cho ô hiện tại (sau [startInput]). Tắt ⇒ bridge thôi ghi checkpoint. */
    fun setSwipeTyping(on: Boolean) {
        swipeTypingActive = on
        bridge.trackLetterUndo = on || letterAlternates || keyCommands
        if (!on) clearSwipe()
    }

    /** Giữ phím chữ ra ký tự phụ đang bật ([KeyAlternates]) — cần checkpoint huỷ phím chữ. */
    private var letterAlternates = false
    fun setLetterAlternates(on: Boolean) {
        letterAlternates = on
        bridge.trackLetterUndo = swipeTypingActive || on || keyCommands
    }

    /** "Vuốt phím để sao chép/dán" bật ở ô này ([KeyCommandGesture]) — cần checkpoint huỷ phím chữ. */
    private var keyCommands = false
    fun setKeyCommands(on: Boolean) {
        keyCommands = on
        bridge.trackLetterUndo = swipeTypingActive || letterAlternates || on
    }

    private fun clearSwipe() {
        swipeWord = null; swipeAlts = emptyList(); swipeLiteral = false; swipeEnglishAlts = emptySet()
        swipeShortcutKey = null
        swipedLiteralPrev = null
        letterAfterSwipe = false
        revisable = null; reviseUndo = null
        typedPending = null; typedUndo = null
    }

    /** Từ vuốt còn mở: từ engine đang soạn, hoặc từ tiếng Anh nguyên văn. */
    private fun openSwipeWord(): String? = swipeWord?.takeIf { swipeLiteral || it == bridge.composedWord }

    /** "Từ khoá" theo từ vuốt (IME): từ vuốt đang mở + từ chốt ngay trước nó. */
    val openSwipe: String? get() = openSwipeWord()
    val lastCommitted: String? get() = lastWord

    /** Chốt từ tiếng Anh nguyên văn đang mở (học + ngữ cảnh), trước khi phím kế chèn gì. */
    private fun settleLiteral(word: String) {
        commitAndLearn(word)
        bridge.noteExternalWord(true, word)
        recentEnglish.addLast(word.lowercase())
        while (recentEnglish.size > 4) recentEnglish.removeFirst()
    }

    /** onFinishInputView (viewWillDisappear). */
    fun finishInput() { langModel.saveNow() }

    /** Con trỏ/selection đổi từ NGOÀI (textWillChange): quên từ + ngữ cảnh. */
    fun externalSelectionChange() {
        TouchLog.host("selectionChanged", false, bridge.isComposing)
        bridge.reset(); lastWord = null; lastWord2 = null
        langRecent.clear()
        clearUndo()
        lastCommit = null
        clearSwipe()
        tonesUndo = null
        suggestionSnap = null
        autoSpacePunct = null; autoSpaceUnderLetter = null
    }

    /** Dấu cách tự thêm sau [p] còn ngay trước con trỏ? Không đọc được ⇒ tin state. */
    private fun autoSpaceStillThere(p: Char, proxy: TextProxy): Boolean =
        proxy.contextBeforeInput()?.endsWith("$p ") ?: true

    /**
     * Sau phím chèn [s]: thêm dấu cách nếu bật + ô cho phép + [AutoSpace.shouldAdd]; [carry] =
     * dời dấu cách tự thêm ra sau ngoặc đóng vừa gõ. Tắt ⇒ không đọc context.
     */
    private fun applyAutoSpace(s: String, carry: Boolean, proxy: TextProxy) {
        if (!autoSpaceOn) return
        val c = s.singleOrNull() ?: return
        if (!carry) {
            if (c !in AutoSpace.TRIGGERS) return
            val before = proxy.contextBeforeInput() ?: return
            if (!AutoSpace.shouldAdd(s, before, proxy.contextAfterInput())) return
        }
        proxy.insertText(" ")
        autoSpacePunct = c
    }

    /**
     * Bàn phím cứng: phím sắp đi THẲNG tới app (Enter thật — Shift+Enter, "Enter để gửi"):
     * chốt từ đang soạn (auto-restore + học) mà KHÔNG chèn gì; như [Key.Newline], ⌫ sau đó
     * không mở lại từ cũ.
     */
    fun commitComposing(proxy: TextProxy) {
        val literal = if (swipeLiteral) openSwipeWord() else null
        clearSwipe()
        if (literal != null) settleLiteral(literal)
        else if (bridge.isComposing) commitAndLearn(bridge.boundary("", proxy))
        bridge.forgetLastCommit()
        lastWord = null; lastWord2 = null; clearUndo()
        lastInsertWasSpace = false
        generation++
    }

    /** Ghi điểm chạm phím chữ vừa gõ; [fresh] = phím đầu của từ mới. */
    private fun noteTouch(fresh: Boolean, touch: AutoCorrect.Touch?) {
        acMemo = null; shownCorrection = null
        if (fresh) { wordTouches.clear(); wordTouchesOk = true }
        if (touch == null) wordTouchesOk = false else if (wordTouchesOk) wordTouches.add(touch)
        if (wordTouches.size != bridge.rawWord.length) wordTouchesOk = false   // nạp lại từ cũ, phím ngoài engine…
    }

    private fun clearUndo() { restoreUndoRaw = null; restoreUndoComposed = null; undoOfferActive = false }

    /**
     * Auto-shift theo cờ CAP_* của ô: trả true/false; null = không đụng shift (ô không cờ
     * CAP, hoặc KHÔNG đọc được chữ trước con trỏ — null ≠ ô trống, trước đây coi null là ""
     * nên bật shift sai giữa câu). Chỉ nâng OFF→ON là việc của IME (không hạ CAPS).
     */
    fun updateAutoShift(proxy: TextProxy, allowRead: Boolean = true): Boolean? {
        autoShiftUnverified = false
        // Tắt: không đọc context; chỉ hạ shift do chính mình bật trước đó (shift tay giữ nguyên).
        if (!autoCapitalize) return if (autoShiftOn) { autoShiftOn = false; false } else null
        // Ô địa chỉ / tìm kiếm: không bao giờ hoa đầu câu — chỉ hạ shift do mình bật (kể cả còn
        // sót từ ô trước); shift tay giữ nguyên.
        if (traits.lowercaseSuggestions) return if (autoShiftOn) { autoShiftOn = false; false } else null
        val mode = capMode(traits)
        if (mode == CapMode.NONE) return null
        val before = proxy.contextForShift(allowRead)
        // Không đọc (khung đầu) và không có chữ sẵn ⇒ đoán theo initialCapsMode, IME xác nhận sau khung đầu.
        autoShiftUnverified = before == null && !allowRead && mode != CapMode.CHARACTERS
        val auto = when {
            before != null -> autoShiftFor(before, mode)
            mode == CapMode.CHARACTERS -> true
            initialCapsPending -> traits.initialCaps
            else -> return null
        }
        autoShiftOn = auto
        return auto
    }

    // MARK: phím

    /** [touch]: điểm chạm của phím chữ (bàn phím cảm ứng) — cho tự sửa; null = không biết. */
    fun handle(key: Key, proxy: TextProxy, touch: AutoCorrect.Touch? = null): KeyOutcome {
        mathArmed = false
        cheerHit = false
        if (trackBoundaryWord) boundaryWord = null
        val t0 = if (TouchLog.enabled) System.nanoTime() else 0L
        val underLetter = autoSpaceUnderLetter
        val pendingSpace = autoSpacePunct
        autoSpaceUnderLetter = null; autoSpacePunct = null
        val snap = suggestionSnap               // chỉ phím NGAY sau khi nhận gợi ý
        suggestionSnap = null
        // Gợi ý vừa chèn "từ " + phím . , ? ! ) / nháy đóng ⇒ "từ." như bàn phím iOS gốc: xoá THẲNG
        // dấu cách của gợi ý (không ⌫ qua engine — ⌫ là mở lại từ / hoàn tác), rồi quên lần chốt.
        if (snap != null && key is Key.Text && !key.replacesLetter &&
            AutoSpace.snapsSuggestionSpace(key.text, proxy.contextBeforeInput(), snap)) {
            proxy.deleteCodePoints(1)
            bridge.forgetLastCommit()
            lastCommit = null
            clearUndo()
            lastInsertWasSpace = false
        }
        // Giữ phím ra ký tự phụ: gỡ phím chữ bằng checkpoint (không ⌫ — phím dấu Telex đã đổi
        // từ); không được (ô đổi / thao tác xen) thì ⌫ như iOS.
        // Phím chữ bị gỡ là phím ĐẦU sau từ vuốt Việt ⇒ ký tự phụ (số giữ phím) coi như ngay sau vuốt.
        val heldAfterSwipe = letterAfterSwipe && key is Key.Text && key.replacesLetter
        letterAfterSwipe = false
        if (key is Key.Text && key.replacesLetter && !undoLastLetter(proxy)) bridge.backspace(proxy)
        // Tự thêm dấu cách sau dấu câu: phím ngay sau quyết định số phận dấu cách đó.
        var autoSpaceCarry = false
        val sp = pendingSpace ?: underLetter?.takeIf { key is Key.Text && key.replacesLetter }
        if (sp != null && autoSpaceStillThere(sp, proxy)) when (key) {
            Key.Space, Key.DoubleSpacePeriod -> {          // đã có dấu cách: nuốt, không thành 2
                generation++
                return KeyOutcome(false, generation)
            }
            Key.Backspace -> {                              // ⌫ chỉ xoá dấu cách tự thêm
                proxy.deleteCodePoints(1)
                lastInsertWasSpace = false
                generation++
                return KeyOutcome(autoCapitalize, generation)
            }
            Key.Newline, Key.LineBreak -> proxy.deleteCodePoints(1)
            is Key.Text -> when (AutoSpace.reaction(key.text)) {
                AutoSpace.Reaction.KEEP -> {}
                AutoSpace.Reaction.REMOVE -> proxy.deleteCodePoints(1)
                AutoSpace.Reaction.CARRY -> { proxy.deleteCodePoints(1); autoSpaceCarry = true }
            }
            is Key.Letter -> autoSpaceUnderLetter = sp
            else -> {}
        }
        // ⌫ NGAY SAU khi thêm dấu = hoàn tác (một lần); phím khác bỏ lời mời hoàn tác.
        if (key == Key.Backspace && tonesUndo != null && !bridge.isComposing && openSwipeWord() == null) {
            undoAddTones(proxy)
            generation++
            return KeyOutcome(true, generation)
        }
        tonesUndo = null
        val swiped = openSwipeWord()
        val literal = if (swipeLiteral) swiped else null
        val shortcutKey = swipeShortcutKey
        revisableAfterLetter = revisable?.takeIf { key is Key.Letter && it.word == swiped }
        literalAfterLetter = if (key is Key.Letter && shortcutKey == null) literal else null
        // Sửa lại từ vuốt khi từ kế GÕ PHÍM: dấu cách chốt từ vuốt còn nguyên ⇒ chờ; đang chờ ⇒
        // phím chữ / ⌫ trong từ gõ giữ, ranh giới thử sửa, phím khác bỏ (clearSwipe).
        val typedArm = revisable?.takeIf { key == Key.Space && literal == null && it.word == swiped && !bridge.englishMode }
        val typedWait = typedPending
        val composingBefore = bridge.isComposing
        val prevBefore = lastWord
        val prev2Before = lastWord2
        var typedCommit: Pair<String, String>? = null      // (từ gõ đã chốt, ranh giới)
        clearSwipe()
        letterAfterSwipe = key is Key.Letter && swiped != null && literal == null
        // Từ tiếng Anh vuốt ra đang mở: phím chữ/ranh giới chốt nó (học), phím chữ thêm dấu
        // cách treo trước (không dính "mailx"; huỷ được nếu phím đó là đầu cú vuốt mới).
        if (literal != null && (key is Key.Letter || key is Key.Text || key == Key.Space ||
                key == Key.DoubleSpacePeriod || key == Key.Newline || key == Key.LineBreak)) {
            settleLiteral(literal)
            if (key is Key.Letter) bridge.boundary(" ", proxy, expand = false)
        }
        // Từ vuốt không bao giờ là chữ tắt.
        val expand = swiped == null && !heldAfterSwipe
        when (key) {
            is Key.Letter -> {
                val fresh = !bridge.isComposing
                bridge.letter(key.ch, proxy); clearUndo()
                if (wantsTouches) noteTouch(fresh, touch)
            }
            is Key.Text -> {
                // VNI: số trong lúc soạn từ (hàng số / plane 123 / phím cứng) mang dấu — phím
                // của từ. Sau từ tiếng Anh vuốt nguyên văn thì số chỉ là số.
                val d = key.text.singleOrNull()
                if (literal == null && d != null && !key.numpad && bridge.vniDigit(d, proxy)) {
                    clearUndo()
                    if (typedWait != null && bridge.isComposing) typedPending = typedWait
                } else {
                    // Dấu cách treo: số / emoji / ngoặc mở ngay sau từ vuốt ⇒ " " trước ("mua 2").
                    // ⌫ xoá số rồi dấu cách như gõ tay. Chỉ đọc context khi đúng trường hợp đó.
                    val afterSwipe = swiped != null || heldAfterSwipe
                    val text = if (afterSwipe && SwipeSpacing.startsWord(key.text) &&
                        SwipeSpacing.spaceBefore(key.text, true, proxy.contextBeforeInput())) " " + key.text else key.text
                    val committed = bridge.boundary(text, proxy, expand = expand)
                    if (trackBoundaryWord) { boundaryWord = committed; boundaryPrev = prevBefore; boundaryPrev2 = prev2Before }
                    cheer?.let { if (it.feed(committed, key.text)) cheerHit = true }
                    commitAndLearn(committed)
                    lastWord = null; lastWord2 = null
                    clearUndo()
                    typedCommit = committed to key.text
                    applyAutoSpace(key.text, autoSpaceCarry, proxy)
                }
            }
            Key.Space -> {
                val composedBefore = bridge.composedWord
                val committed = bridge.boundary(" ", proxy, expand = expand)
                // (Gõ tắt vừa bung thì không: ⌫ kế tiếp tự trả lại chữ tắt trong bridge.)
                if (composedBefore.isNotEmpty() && committed != composedBefore && !bridge.expandedAtLastBoundary) {
                    restoreUndoRaw = committed; restoreUndoComposed = composedBefore
                } else { restoreUndoRaw = null; restoreUndoComposed = null }
                undoOfferActive = false
                if (trackBoundaryWord) { boundaryWord = committed; boundaryPrev = prevBefore; boundaryPrev2 = prev2Before }
                cheer?.let { if (it.feed(committed, end = true)) cheerHit = true }
                if (literal == null) commitAndLearn(committed)
                if (typedArm != null && committed == typedArm.word)
                    typedPending = TypedPending(SwipeRevise.Typed(typedArm.word, typedArm.scored, typedArm.case, prevBefore),
                        lastCommit?.takeIf { it.word == committed })
                typedCommit = committed to " "
            }
            Key.DoubleSpacePeriod -> {
                val ctx = proxy.contextBeforeInput() ?: ""
                if (TypingHeuristics.doubleSpaceMakesPeriod(ctx, lastInsertWasSpace)) {
                    // Xoá space bằng deleteSurroundingText (qua deleteCodePoints), KHÔNG
                    // deleteBackward: KEYCODE_DEL đi đường key event bất đồng bộ (ViewRootImpl
                    // post Message) nên có thể tới SAU commitText(". ") → "chữ ." thay vì "chữ. ".
                    proxy.deleteCodePoints(1)
                    proxy.insertText(". ")
                    lastWord = null; lastWord2 = null
                    cheer?.let { if (it.feed("", ".")) cheerHit = true }
                } else {
                    val w = bridge.boundary(" ", proxy, expand = expand)
                    cheer?.let { if (it.feed(w, end = true)) cheerHit = true }
                    commitAndLearn(w)
                }
                // Space đôi có thể đã thành ". ": ⌫ sau đó không được mở lại từ.
                bridge.forgetLastCommit()
                clearUndo()
            }
            is Key.MoveCursor -> {
                bridge.reset(); lastWord = null; lastWord2 = null; clearUndo()
                cheer?.reset()
            }
            Key.Newline, Key.LineBreak -> {
                val committed = bridge.boundary("\n", proxy, lineBreak = key == Key.LineBreak, expand = expand)
                cheer?.let { if (it.feed(committed, end = true)) cheerHit = true }
                commitAndLearn(committed)
                typedCommit = committed to "\n"
                // Enter có thể là "gửi"/performEditorAction: ⌫ sau đó không mở lại từ cũ.
                bridge.forgetLastCommit()
                lastWord = null; lastWord2 = null; clearUndo()
            }
            Key.ClearField -> {
                proxy.clearAll()
                bridge.reset(); lastWord = null; lastWord2 = null; clearUndo()
            }
            Key.Backspace -> if (swiped != null && shortcutKey != null && proxy.confirmTail(swiped)) {
                // ⌫ đầu ngay sau vuốt khoá gõ tắt: trả lại khoá (như hoàn tác gõ tắt gõ tay) — khoá
                // nằm lại thành chữ thường trên màn hình (engine trống ⇒ dấu cách sau không bung lại).
                proxy.deleteCodePoints(Cp.count(swiped))
                proxy.insertText(shortcutKey)
                bridge.reset()
                bridge.forgetLastCommit()
                clearUndo()
                TouchLog.write("shortcut undo (vuốt): -${Cp.count(swiped)} +${Cp.count(shortcutKey)}")
            } else if (swiped != null && proxy.confirmTail(swiped)) {
                // ⌫ ĐẦU TIÊN ngay sau vuốt: xoá cả từ vuốt (từ chưa chốt ⇒ ngữ cảnh giữ nguyên).
                proxy.deleteCodePoints(Cp.count(swiped))
                bridge.reset()
                clearUndo()
            } else {
                if (!bridge.isComposing && lastInsertWasSpace && restoreUndoRaw != null) undoOfferActive = true
                else clearUndo()
                wordTouchesOk = false
                val acUndo = bridge.autoCorrectUndo
                if (bridge.backspace(proxy)) onReopened()
                else if (!bridge.isComposing) { lastWord = null; lastWord2 = null }
                bridge.revertedAutoCorrect?.let { bridge.revertedAutoCorrect = null; onAutoCorrectReverted(it, acUndo?.second) }
                // ⌫ ngay sau tự sửa ngược = "Khôi phục" (bridge đã trả lại chữ cũ): không mời hoàn tác khôi phục.
                if (bridge.revertedRetro) { bridge.revertedRetro = false; clearUndo() }
            }
        }
        if (typedWait != null) when {
            typedCommit != null -> if (composingBefore && !bridge.englishMode) typedCommit.let { (w, b) ->
                reviseTypedPrev(typedWait, w, b, proxy, sentenceBreak = b != " ") }
            key is Key.Letter || key == Key.Backspace && composingBefore ->
                if (bridge.isComposing) typedPending = typedWait
            else -> {}
        }
        // Chip số: chỉ đọc context khi token này / token ngay trước có chữ số/phép tính.
        numberSpaces = when (key) {
            is Key.Text -> if (key.text.firstOrNull()?.let { it.isDigit() || it in "=+-*/×÷:%().," } == true) 0 else 99
            Key.Space, Key.DoubleSpacePeriod -> numberSpaces + 1
            Key.Backspace -> 0
            is Key.Letter -> numberSpaces
            else -> 99
        }
        // Kết quả phép tính: ngay sau "=", hoặc chip ngầm khi phím vừa ra chữ số / ")" / "%" hay ⌫
        // (biểu thức có thể kết thúc ở con trỏ). Phím khác / công tắc tắt ⇒ không đọc context.
        mathArmed = mathOn && when (key) {
            is Key.Text -> key.text.lastOrNull()?.let { it in '0'..'9' || it in "=)%" } == true
            Key.Backspace -> true
            else -> false
        }
        lastInsertWasSpace = key == Key.Space || key == Key.DoubleSpacePeriod
        lastKeyWasEmailTrigger = key is Key.Text && (key.text == "@" || key.text == ".")
        initialCapsPending = false
        val needsAutoShift = autoCapitalize && when (key) {
            Key.Space, Key.Newline, Key.LineBreak, Key.DoubleSpacePeriod, Key.Backspace, is Key.MoveCursor, Key.ClearField -> true
            // CAP_CHARACTERS: shift ON bị bàn phím hạ sau mỗi chữ → bật lại. ". " tự thêm ⇒ tính lại.
            else -> traits.capCharacters || autoSpacePunct != null
        }
        if (TouchLog.enabled) {
            val (kind, ch) = when (key) {
                is Key.Letter -> "letter" to key.ch.toString()
                is Key.Text -> "text" to key.text
                Key.Space -> "space" to null
                Key.DoubleSpacePeriod -> "doubleSpace" to null
                Key.Backspace -> "backspace" to null
                Key.Newline -> "newline" to null
                Key.LineBreak -> "linebreak" to null
                is Key.MoveCursor -> "cursor" to null
                Key.ClearField -> "clear" to null
            }
            TouchLog.key(kind, bridge.isComposing, (System.nanoTime() - t0) / 1e6, ch)
        }
        generation++
        return KeyOutcome(needsAutoShift, generation)
    }

    // MARK: gõ vuốt

    /**
     * Ngón vừa chuyển từ chạm sang VUỐT: huỷ phím chữ đã chèn lúc chạm xuống (checkpoint
     * engine, không ⌫). false ⇒ không huỷ được (ô đổi / thao tác khác xen) — IME coi là chạm.
     */
    fun undoLastLetter(proxy: TextProxy): Boolean {
        val ok = bridge.undoLastLetter(proxy)
        wordTouchesOk = false
        typedPending = null
        revisable = if (ok) revisableAfterLetter else null
        revisableAfterLetter = null
        swipedLiteralPrev = if (ok) literalAfterLetter else null
        literalAfterLetter = null
        generation++
        return ok
    }

    /** Từ chọn cho một cú vuốt; [revisedPrev] = từ vuốt trước cần thay (đã theo chữ hoa của nó). */
    class SwipeResolved(val choice: SwipeChoice, val scored: List<SwipeWord>, val case: SwipeSuggest.Case,
                        val revisedPrev: String? = null)

    /**
     * Ứng viên decoder → từ chèn. Cú vuốt ngay sau một từ vuốt Việt còn nguyên (chưa sửa, chưa
     * chọn phương án): chấm lại từ đó theo ngữ cảnh hai phía; đổi thì chọn lại từ này theo ngữ
     * cảnh trái mới. Chỉ vài lần bung dấu + tra LM — sau nhấc tay, không ở đường phím.
     */
    fun resolveSwipe(all: List<SwipeCandidate>, ctx: SwipeSuggest.Context,
                     case: SwipeSuggest.Case = SwipeSuggest.Case.LOWER): SwipeResolved? {
        // Chế độ Tiếng Anh (vuốt phím cách): chỉ ứng viên tiếng Anh
        val cands = if (bridge.englishMode) SwipeSuggest.englishOnly(all) else all
        val choice = SwipeSuggest.choose(cands, ctx.word, case, ctx.lambdaFreq, ctx.proper) ?: return null
        val scored = if (choice.english) emptyList() else SwipeRevise.scored(cands, ctx.word, ctx.lambdaFreq)
        // Từ TIẾNG ANH vừa vuốt còn mở ("new" + "york"): chỉ viết hoa ngược chuỗi tên riêng. = iOS.
        val lit = if (swipeLiteral) swipeWord else swipedLiteralPrev
        if (lit != null && swipeShortcutKey == null)
            return chainCapitalizePrev(SwipeResolved(choice, scored, case), lit, ctx, case)
        val rec = revisable
        if (rec == null || swipeLiteral || !bridge.isComposing || bridge.composedWord != rec.word)
            return SwipeResolved(choice, scored, case)
        if (choice.english) return chainCapitalizePrev(SwipeResolved(choice, scored, case), rec.word, ctx, case)
        // sửa chung cặp (từ vuốt trước, cú vuốt này) — ứng viên từ kế rộng hơn scored
        val new = SwipeRevise.revise(rec.scored, rec.word.lowercase(), lastWord,
            SwipeRevise.nextPool(cands, ctx.word, ctx.lambdaFreq))
            ?: return chainCapitalizePrev(SwipeResolved(choice, scored, case), rec.word, ctx, case)
        val nctx = SwipeSuggest.context(langModel, new, lastWord, ctx.english, properNouns = ctx.properNouns)
        val re = SwipeRevise.rerank(cands, ctx.word, ctx.lambdaFreq, nctx.word, nctx.lambdaFreq)
        val c = SwipeSuggest.choose(re, nctx.word, case, nctx.lambdaFreq, nctx.proper) ?: choice
        val prevProper: (String) -> String = { if (ctx.properNouns) DisplayCase.resolve(it, lastWord, ctx.learnedCase) else it }
        return chainCapitalizePrev(SwipeResolved(c, if (c.english) emptyList() else SwipeRevise.scored(re, nctx.word, nctx.lambdaFreq),
            case, SwipeSuggest.applyCase(new, rec.case, prevProper)), rec.word, ctx, case)
    }

    /**
     * Chuỗi tên riêng: từ vuốt này viết hoa vì từ vuốt trước còn mở ("việt" + "nam" → "Nam") ⇒ hoa
     * luôn từ trước ("Việt Nam", không "việt Nam") — qua đường thay từ trước của [commitSwipe]
     * (chip "↩︎ từ cũ" như sửa lại). Caps Lock: từ trước đã hoa sẵn. = iOS SwipeTyping.finish.
     */
    private fun chainCapitalizePrev(r: SwipeResolved, prevWord: String, ctx: SwipeSuggest.Context,
                                    case: SwipeSuggest.Case): SwipeResolved {
        if (!ctx.properNouns || case == SwipeSuggest.Case.ALL) return r
        val onScreen = r.revisedPrev ?: prevWord
        if (onScreen.isEmpty()) return r
        val f = onScreen.codePointAt(0)
        if (Character.isUpperCase(f) || Character.isTitleCase(f)) return r
        if (!DisplayCase.chainCapitalizes(r.choice.word.lowercase(), onScreen)) return r
        return SwipeResolved(r.choice, r.scored, r.case, Cp.capitalizeFirst(onScreen))
    }

    fun commitSwipe(r: SwipeResolved, proxy: TextProxy): KeyOutcome =
        commitSwipe(r.choice, proxy, r.revisedPrev, r.scored, r.case)

    /** Điểm ngữ cảnh cho decoder: từ trước = từ đang soạn (sẽ được chốt) hoặc từ chốt gần nhất. */
    fun swipeContext(): SwipeSuggest.Context {
        val lit = if (swipeLiteral) swipeWord else null
        val composing = bridge.isComposing || lit != null
        val pending = when {
            lit != null -> lit
            bridge.isComposing -> bridge.predictedCommit.takeIf { UserLangModel.learnable(it) }
            else -> null
        }
        val p1 = if (composing) pending else lastWord
        val p2 = if (composing) (if (pending != null) lastWord else null) else lastWord2
        // Ngôn ngữ theo ≤ 3 từ trước (qua cả dấu câu): từ Anh vừa vuốt (nhãn) chắc nhất, rồi
        // bảng từ của engine + từ điển. Tắt vuốt tiếng Anh ⇒ không tính gì.
        val english = if (bridge.englishMode) SwipeLangContext.ONLY_ENGLISH else if (!swipeEnglish) null else SwipeLangContext.prior(
            SwipeLangContext.kinds(composing, pending, lit != null || isRecentEnglish(pending), langRecent, ::isRecentEnglish))
        return SwipeSuggest.context(langModel, p1, p2, english, properNouns = !traits.lowercaseSuggestions)
    }

    private fun isRecentEnglish(w: String?) = w != null && w.lowercase() in recentEnglish

    /**
     * Nhấc tay khỏi đường vuốt: chốt từ đang soạn (nếu có, kèm dấu cách), dấu cách treo
     * nếu liền trước là chữ, chèn [choice] rồi seed engine bằng nó ⇒ composition đang mở
     * (phím dấu Telex sửa được, ⌫ đầu xoá cả từ, thanh gợi ý hiện biến thể).
     */
    fun commitSwipe(choice0: SwipeChoice, proxy: TextProxy, revisedPrev: String? = null,
                    scored0: List<SwipeWord> = emptyList(), case: SwipeSuggest.Case = SwipeSuggest.Case.LOWER): KeyOutcome {
        tonesUndo = null
        // Khoá gõ tắt ("vn", từ vựng vuốt SwipeVocab.shortcutEntries): chèn nội dung bung như gõ khoá +
        // dấu cách (⌫ đầu trả lại khoá). Khoá đứng đầu phương án — chạm để giữ nguyên khoá. = iOS finish.
        var choice = choice0
        var scored = scored0
        var shortcutKey: String? = null
        val key = choice0.shifted
        val e = if (key.isEmpty()) null else bridge.swipeShortcutExpansion(key)
        if (e != null && e != key) {
            shortcutKey = key
            choice = SwipeChoice(e, (listOf(key) + choice0.alternatives.filter { it != key && it != e }).take(3),
                english = false, englishAlternatives = choice0.englishAlternatives + key, shifted = key)
            scored = emptyList()
            TouchLog.write("swipe: khoá gõ tắt (${Cp.count(key)}→${Cp.count(e)} chars)")
        }
        val lit = if (swipeLiteral) swipeWord else null
        val prevWord = revisable?.word
        val prevLit = swipedLiteralPrev
        clearUndo(); clearSwipe()
        var revised: Pair<String, String>? = null
        // Từ Anh vừa vuốt đã chốt kèm " " (chạm đầu cú vuốt này): viết hoa ngược chuỗi tên riêng.
        if (lit == null && revisedPrev != null && prevLit != null && !bridge.isComposing &&
            proxy.confirmTail("$prevLit ")) {
            proxy.deleteCodePoints(Cp.count(prevLit) + 1)
            proxy.insertText("$revisedPrev ")
            revised = prevLit to revisedPrev
        }
        if (lit != null) {
            // từ tiếng Anh vuốt trước còn mở: chốt nó + dấu cách. Chuỗi tên riêng ("new" + "york")
            // ⇒ thay nó bằng dạng viết hoa trước (chỉ khi đuôi màn hình đúng là nó).
            var settled = lit
            if (revisedPrev != null && proxy.confirmTail(lit)) {
                proxy.deleteCodePoints(Cp.count(lit))
                proxy.insertText(revisedPrev)
                revised = lit to revisedPrev
                settled = revisedPrev
            }
            settleLiteral(settled)
            bridge.boundary(" ", proxy, expand = false)
        } else if (bridge.isComposing) {
            // Sửa lại từ vuốt trước (ngữ cảnh hai phía): chỉ khi đuôi màn hình đúng là nó.
            if (revisedPrev != null && prevWord != null && prevWord == bridge.composedWord &&
                proxy.confirmTail(prevWord)) {
                proxy.deleteCodePoints(Cp.count(prevWord))
                proxy.insertText(revisedPrev)
                revised = prevWord to revisedPrev
                if (!bridge.adoptWord(revisedPrev)) commitAndLearn(revisedPrev)
            }
            // dấu cách tự chèn trước từ vuốt: không phải ranh giới người dùng gõ → không gõ tắt
            if (bridge.isComposing) commitAndLearn(bridge.boundary(" ", proxy, expand = false))
            else bridge.boundary(" ", proxy, expand = false)
        } else if (SwipeSuggest.needsLeadingSpace(proxy.contextBeforeInput())) {
            bridge.boundary(" ", proxy, expand = false)
        }
        proxy.insertText(choice.word)
        if (shortcutKey != null) {
            // nội dung bung: nguyên văn như từ Anh vuốt (engine trống), nhưng không phải ngữ cảnh Anh
            bridge.adoptLiteral()
            swipeWord = choice.word
            swipeLiteral = true
            swipeAlts = choice.alternatives
            swipeEnglishAlts = choice.englishAlternatives
            swipeShortcutKey = shortcutKey
        } else if (choice.english) {
            // tiếng Anh: chèn nguyên văn, engine trống (không seed Telex, không bung dấu)
            bridge.adoptLiteral()
            swipeWord = choice.word
            swipeLiteral = true
            swipeAlts = choice.alternatives
            swipeEnglishAlts = choice.englishAlternatives
        } else if (bridge.adoptWord(choice.word)) {
            swipeWord = choice.word
            // lọc bật: phương án tạo cặp nhạy cảm với từ trước (SensitiveWords.pairs) không hiện
            swipeAlts = SensitiveWords.dropPairs(choice.alternatives, lastWord, filterSensitive, lastWord2)
            swipeEnglishAlts = choice.englishAlternatives
            if (scored.isNotEmpty()) revisable = Revisable(choice.word, scored, case)
            reviseUndo = revised
        }
        if (revised != null) TouchLog.write("swipe: sửa từ trước (${Cp.count(revised.first)}→${Cp.count(revised.second)} chars)")
        lastInsertWasSpace = false
        lastKeyWasEmailTrigger = false
        initialCapsPending = false
        TouchLog.write("swipe: ${Cp.count(choice.word)} chars, ${choice.alternatives.size} alts")
        generation++
        return KeyOutcome(true, generation)
    }

    /** Đang hiện biến thể của từ vừa vuốt (test / IME). */
    val swipeAlternatives: List<String>? get() = openSwipeWord()?.let { swipeAlts }

    /** Từ vuốt đang mở là tiếng Anh nguyên văn (test / IME). */
    val swipeWordIsEnglish: Boolean get() = swipeLiteral && swipeWord != null

    /** Giữ ⌫ > 3 s: xoá theo TỪ (khoảng trắng đuôi rồi tới đầu từ). */
    fun deleteWordBackward(proxy: TextProxy) {
        tonesUndo = null
        bridge.reset(); lastWord = null; lastWord2 = null; clearUndo()
        val before = proxy.contextBeforeInput() ?: ""
        if (before.isEmpty()) return
        var end = before.length
        var count = 0
        fun lastCp() = before.codePointBefore(end)
        while (end > 0 && (lastCp() == ' '.code || lastCp() == '\n'.code)) { end--; count++ }
        while (end > 0 && !(lastCp() == ' '.code || lastCp() == '\n'.code)) {
            end -= Character.charCount(lastCp()); count++
        }
        proxy.deleteCodePoints(maxOf(count, 1))
    }

    /**
     * Mẫu câu (sau khi IME đã fetch mẫu động): xoá từ đang soạn, chèn nguyên văn,
     * reset engine, KHÔNG học. IME gọi updateAutoShift + refresh bar sau đó.
     */
    fun insertTemplate(text: String, proxy: TextProxy) {
        tonesUndo = null
        val n = Cp.count(bridge.composedWord)
        if (n > 0 && proxy.confirmTail(bridge.composedWord)) proxy.deleteCodePoints(n)
        proxy.insertText(text)
        bridge.reset(); lastWord = null; lastWord2 = null; clearUndo()
    }

    /**
     * ⌫ vừa mở lại từ chốt trước: từ đó quay về trạng thái "đang gõ" — rút lượt học của nó
     * (chốt lại sẽ học đúng một lần, kể cả khi đã sửa dấu) và trả ngữ cảnh về trước nó.
     */
    private fun onReopened() {
        clearUndo()
        val lc = lastCommit
        lastCommit = null
        if (lc != null && lc.word == bridge.composedWord) {
            lc.learned?.let { langModel.retract(it) }
            lastWord = lc.prev1; lastWord2 = lc.prev2
        } else { lastWord = null; lastWord2 = null }
    }

    private fun commitAndLearn(word: String, accepted: Boolean = false) {
        lastCommit = null
        if (word.isEmpty()) return
        // Nội dung gõ tắt nhiều từ ("mọi người"): học lần lượt từng từ (bigram trong cụm).
        val parts = ShortcutFile.words(word)
        if (parts.size != 1 || parts[0] != word) {
            for (p in parts) commitAndLearn(p, accepted)
            if (parts.isEmpty()) { lastWord = null; lastWord2 = null }
            return
        }
        val learned = if (learnEnabled)
            langModel.record(word, lastWord, lastWord2, if (accepted) 2 else 1, casingEvidence(word)) else null
        lastCommit = LastCommit(word, lastWord, lastWord2, learned)
        if (UserLangModel.learnable(word)) {
            lastWord2 = lastWord; lastWord = word
            if (swipeTypingActive && swipeEnglish) {   // tắt vuốt / vuốt tiếng Anh ⇒ 0 chi phí
                langRecent.addLast(word)
                if (langRecent.size > SwipeLangContext.WINDOW) langRecent.removeFirst()
            }
        } else { lastWord = null; lastWord2 = null }
    }

    /**
     * Hoa/thường của [word] có được dạy bảng hoa/thường đã học không ([CaseTable]): chỉ GIỮA CÂU
     * (lastWord còn — đầu ô / dấu câu / xuống dòng / dời con trỏ đã cắt nó), không do chuỗi tên
     * riêng, và từ CÓ chữ hoa thì ô không tự hoa mỗi từ / mọi chữ (CAP_WORDS / CAP_CHARACTERS).
     * = iOS casingEvidence.
     */
    private fun casingEvidence(word: String): Boolean {
        if (!DisplayCase.casingEvidence(word, lastWord)) return false
        if (word.codePoints().noneMatch { Character.isUpperCase(it) || Character.isTitleCase(it) }) return true
        return !traits.capWords && !traits.capCharacters
    }

    // MARK: gợi ý

    /** Shift cho hoa/thường gợi ý. Ô địa chỉ / tìm kiếm: bỏ Shift một-lần (Caps Lock vẫn theo). */
    private val suggestionShift: SuggestionCase.Shift get() {
        val s = keyboardShift ?: if (autoShiftOn) SuggestionCase.Shift.ONCE else SuggestionCase.Shift.OFF
        return if (traits.lowercaseSuggestions && s == SuggestionCase.Shift.ONCE) SuggestionCase.Shift.OFF else s
    }

    /** Hoa/thường theo Shift + chữ đang gõ ([SuggestionCase]): "Em, Anh, Tôi" / "EM" / "Bê" ⇒ "Bên". */
    private fun caseForContext(w: String, typed: String = ""): String =
        SuggestionCase.display(if (traits.lowercaseSuggestions) w.lowercase() else w, suggestionShift, typed)

    /**
     * Shift/Caps vừa đổi (IME gọi sau khi gán [keyboardShift]): true ⇒ vẽ lại bar ngay như Gboard.
     * false khi bar đã tính với Shift này (lượt gợi ý của phím chữ vừa nhả Shift đã chạy), hoặc
     * đang gõ dở mà không dính Caps Lock (lúc đó hoa/thường theo chữ đã gõ).
     */
    fun shiftNeedsRefresh(): Boolean {
        val s = suggestionShift
        if (s == barShift || !suggestionsActive || barCollapsed) return false
        if (bridge.composedWord.isNotEmpty() && s != SuggestionCase.Shift.CAPS_LOCK &&
            barShift != SuggestionCase.Shift.CAPS_LOCK) { barShift = s; return false }
        return true
    }

    /**
     * Hoa/thường hiển thị của gợi ý: hoa/thường người dùng đã viết nhất quán ([UserLangModel.learnedCase])
     * > [DisplayCase] (tên riêng); từ đã có chữ hoa giữ nguyên; ô địa chỉ / tìm kiếm ⇒ chữ thường.
     */
    private fun displayCase(w: String, after: String? = null) =
        if (traits.lowercaseSuggestions) w.lowercase() else DisplayCase.resolve(w, after) { langModel.learnedCase(it) }

    /** [afterWord] = ô "từ kế tiếp" sau [lastWord]: từ trước tiếng Anh ⇒ không đệm topWords mà lấp bằng bảng
     *  từ kế tiếp tiếng Anh [EnglishNext] (#146, [SuggestRank.padsWithTopWords] / [SuggestRank.englishNextFill]). */
    private fun padWords(base: List<String>, need: Int, typed: String = "", afterWord: Boolean = false): List<String> {
        if (base.size >= need) return base.take(need)
        val prev = lastWord
        if (afterWord && prev != null && !SuggestRank.padsWithTopWords(prev, bridge.englishMode))
            return SuggestRank.englishNextFill(base, EnglishNext.next(prev), need, typed,
                { SensitiveWords.filter(it, filterSensitive, after = prev, prev2 = lastWord2) },
                { caseForContext(displayCase(it), typed) })
        // Tiếng Anh: không chặn main chờ nạp/sắp từ điển (IME hâm nóng nền khi vào EN) — chưa có ⇒ không đệm.
        val top = if (bridge.englishMode) SwipeEnglish.topIfReady ?: emptyList() else langModel.topWords(need + 12)
        val cands = SensitiveWords.filter(top, filterSensitive, after = lastWord, prev2 = lastWord2)
            .map { caseForContext(displayCase(it), typed) }
        return SuggestionFill.pad(base, cands, need, typed)
    }

    /** Gọi sau debounce 30 ms (hoặc khi hiện bàn phím / selection đổi / bật bar). */
    fun requestSuggestions(proxy: TextProxy): SuggestionPlan {
        suggestReq++
        barShift = suggestionShift
        numberChip = null; mathChip = null
        if (barCollapsed) return SuggestionPlan.Ready(null)
        if (!suggestionsActive) return SuggestionPlan.Ready(if (stripMode == StripMode.TOOLS) toolsOnlySet(proxy) else null)
        if (emailBar) return SuggestionPlan.Ready(SuggestionSet(
            nextWords = proxy.contextBeforeInput()?.let { b -> EmailDomains.chips(b).map { it.label } } ?: emptyList()))
        swipeAlternatives?.let { alts ->
            val u = reviseUndo
            return SuggestionPlan.Ready(SuggestionSet(nextWords = alts, actionLabel = u?.let { "↩\uFE0E ${it.first}" },
                action = u?.let { SuggestionSet.UNDO_REVISE_TOKEN }))
        }
        val composed = bridge.composedWord
        var literal: String? = null
        if (composed.isEmpty() && undoOfferActive) literal = restoreUndoComposed
        if (composed.isEmpty() && lastKeyWasEmailTrigger) {
            val before = proxy.contextBeforeInput()
            val last = before?.split(' ')?.lastOrNull { it.isNotEmpty() }
            if (last != null) {
                if (last.endsWith("@") && Cp.count(last) > 1)
                    return SuggestionPlan.Ready(SuggestionSet(nextWords = EMAIL_SUFFIXES))
                if (last.endsWith(".") && Cp.count(last) > 1 &&
                    last.dropLast(1).codePoints().allMatch { Character.isLetterOrDigit(it) })
                    return SuggestionPlan.Ready(SuggestionSet(nextWords = DOMAIN_TLDS))
            }
        }
        if (composed.isNotEmpty()) {
            val b = bridge
            return SuggestionPlan.Background(SuggestJob(suggestReq, generation, b, composed,
                b.rawWord, b.predictedCommit, b.autoFixAdjacent, lastWord, refreshNumberChip(proxy), refreshMathChip(proxy),
                lastWord2, wantPlan = correctionHintOn && wordTouchesOk))
        }
        val prev = lastWord
        val next: List<String> = if (bridge.englishMode) {
            // Tiếng Anh: từ kế tiếp cá nhân chỉ giữ từ tiếng Anh; đầu ô đệm bằng từ Anh phổ biến,
            // sau một từ thì KHÔNG (#146: "they" → "the of and" là top unigram, không phải ngữ cảnh)
            val personal = if (prev != null) langModel.nextWords(prev, lastWord2, 12) else emptyList()
            padWords(SensitiveWords.filter(personal.filter { SwipeEnglish.containsIfLoaded(it.lowercase()) }, filterSensitive, after = prev, prev2 = lastWord2)
                .take(slotWant).map { caseForContext(it) }, slotWant, afterWord = true)
        } else if (prev != null) {
            // SuggestRank.nextFill: có trigram tĩnh (prev2, prev) ⇒ bộ ba người dùng đã gõ, rồi trigram,
            // rồi cá nhân/seed; không ⇒ cá nhân/seed trước, lấp bằng bigram tĩnh; rồi mới topWords
            val p2 = lastWord2
            // + chuỗi seed ba từ (SensitiveWords.chain — "óc bã" → đậu; lọc bật bỏ bộ ba nhạy cảm)
            val personal = SensitiveWords.filter(langModel.nextWords(prev, p2, 6), filterSensitive, after = prev, prev2 = p2)
            val chain = SensitiveWords.filter(SensitiveWords.chain(prev, p2), filterSensitive, after = prev, prev2 = p2)
            val n = SuggestRank.nextFill(prev, p2, personal, { w -> if (p2 == null) 0 else langModel.trigramCount(p2, prev, w) },
                { SensitiveWords.filter(it, filterSensitive, after = prev, prev2 = p2) }, need = slotWant, chain = chain)
            padWords(n.map { caseForContext(displayCase(it, prev)) }, slotWant, afterWord = true)
        } else {
            val top = SensitiveWords.filter(langModel.topWords(maxOf(6, slotWant + 3)), filterSensitive)
                .take(slotWant).map { caseForContext(displayCase(it)) }
            padWords(top, slotWant)
        }
        val number = refreshNumberChip(proxy, idle = true)
        val math = refreshMathChip(proxy)
        val paste = pasteOffer(proxy)
        // Chip tách STK/SĐT/OTP = Clipboard nâng cao (Plus; paywall tắt ⇒ mở cho mọi người).
        val chips = if (paste && !incognito && PlusGate.isUnlocked(PlusFeature.ADVANCED_CLIPBOARD)) clipChips() else emptyList()
        // "Hoàn tác" thêm dấu (vừa bấm) thắng thẻ Dán; "Thêm dấu" nhường thẻ Dán (StripView/SuggestionSlots).
        typedUndo?.let { u ->
            return SuggestionPlan.Ready(SuggestionSet(nextWords = next, number = number, math = math,
                actionLabel = "\u21A9\uFE0E ${u.edit.old}", action = SuggestionSet.UNDO_REVISE_TOKEN))
        }
        // Sửa ngược tiếng Anh (docs/DESIGN.md): công tắc tắt ⇒ chip mời "His car is"; bật và vừa
        // tự sửa ⇒ chip "↩︎ Khôi phục". Bridge xoá cả hai ở phím kế.
        bridge.retroOffer?.let { c ->
            return SuggestionPlan.Ready(SuggestionSet(nextWords = next, number = number, math = math,
                actionLabel = EngineBridge.retroLabel(c, proxy.contextBeforeInput()), action = SuggestionSet.RETRO_OFFER_TOKEN))
        }
        if (bridge.retroUndoAvailable) return SuggestionPlan.Ready(SuggestionSet(nextWords = next, number = number, math = math,
            actionLabel = EngineBridge.RETRO_UNDO_LABEL, action = SuggestionSet.UNDO_RETRO_TOKEN))
        bridge.autoCorrectUndo?.let { (orig, _) ->
            return SuggestionPlan.Ready(SuggestionSet(nextWords = next, number = number, math = math,
                actionLabel = "\u21A9\uFE0E $orig", action = SuggestionSet.UNDO_AUTOCORRECT_TOKEN))
        }
        if (tonesUndo != null) return SuggestionPlan.Ready(SuggestionSet(literal = literal, nextWords = next,
            number = number, math = math, actionLabel = UNDO_TONES_LABEL, action = SuggestionSet.UNDO_TONES_TOKEN))
        val offer = literal == null && !bridge.englishMode && addTonesPlan(proxy) != null
        return SuggestionPlan.Ready(SuggestionSet(literal = literal, nextWords = next, paste = paste,
            number = number, math = math, clipChips = chips,
            actionLabel = if (offer) ADD_TONES_LABEL else null, action = if (offer) SuggestionSet.ADD_TONES_TOKEN else null,
            idle = prev == null && literal == null && number == null && math == null && !offer))
    }

    /**
     * Ô [StripMode.TOOLS]: chỉ lời mời Dán (một lần mỗi mục — [pasteOnce]) + chip tách số
     * (Clipboard nâng cao — Plus); không chữ ⇒ bar rỗng thì hiện icon con trỏ/📋.
     */
    private fun toolsOnlySet(proxy: TextProxy): SuggestionSet {
        val paste = pasteOffer(proxy)
        val chips = if (paste && !incognito && PlusGate.isUnlocked(PlusFeature.ADVANCED_CLIPBOARD)) clipChips() else emptyList()
        return SuggestionSet(paste = paste, clipChips = chips, idle = true)
    }

    /**
     * Chạm chip đuôi mail: chèn phần còn thiếu — tính lại từ context lúc chạm (con trỏ có thể
     * đã dời), không khớp chip nào ⇒ bỏ (không chèn mù).
     */
    private fun acceptEmailChip(label: String, proxy: TextProxy) {
        val before = proxy.contextBeforeInput() ?: return
        val chip = EmailDomains.chips(before, EmailDomains.providers.size).firstOrNull { it.label == label } ?: return
        // Qua bridge: ô email đang soạn ("dduc") ⇒ trả về phím thô trước khi chèn "@gmail.com".
        bridge.boundary(chip.insert, proxy, expand = false)
        bridge.reset()
        lastWord = null; lastWord2 = null
    }

    /** Chip số cho token trước con trỏ (đọc chữ / định dạng tiền / máy tính nhanh). */
    private fun refreshNumberChip(proxy: TextProxy, idle: Boolean = false): String? {
        numberChip = null
        // Ngày âm lịch ("âm lịch" / "ngày âm" / "ÂL" vừa chốt): lọc bằng so chuỗi từ vừa chốt, chỉ đọc
        // context + tính ngày âm khi khớp (cache theo ngày) — dùng chung slot + đường thay của chip số.
        if (idle && numberChipsOn && LunarDate.mayTrigger(lastWord)) {
            proxy.contextBeforeInput()?.let { LunarDate.chip(it) }?.let { numberChip = it; return it.display }
        }
        if (!numberChipsOn || numberSpaces > 1) return null
        val before = proxy.contextBeforeInput() ?: return null
        numberChip = NumberChips.chip(before)
        // Không còn chữ số trong 2 token cuối ⇒ phím chữ/cách sau đó không thể tạo chip: thôi
        // đọc context (copy ≤256 ký tự) mỗi phím cho tới chữ số/ký hiệu/⌫ kế ([handle]).
        if (numberChip == null && !NumberChips.tailHasDigit(before)) numberSpaces = 99
        return numberChip?.display
    }

    /**
     * Chip kết quả phép tính — chỉ đọc context khi phím vừa gõ là "=" (chip thường) hoặc chữ số / ")" /
     * "%" / ⌫ (chip ngầm "= 36"); đọc lại mỗi lượt (con trỏ dời ⇒ mất).
     */
    private fun refreshMathChip(proxy: TextProxy): String? {
        mathChip = null
        if (!mathArmed) return null
        val before = proxy.contextBeforeInput() ?: return null
        mathChip = MathResults.chipAtCaret(before)
        return mathChip?.display
    }

    /**
     * Áp kết quả nền; null nếu đã lỗi thời (phím mới / lượt mới / từ khác / bar tắt). [proxy]: để
     * kiểm điều kiện tự sửa theo chữ trên màn hình (ô tô nền §8) — null ⇒ không tô.
     */
    fun completeSuggestions(job: SuggestJob, result: SuggestJob.Result, proxy: TextProxy? = null): SuggestionSet? {
        if (job.req != suggestReq || job.gen != generation || bridge !== job.bridge ||
            job.bridge.composedWord != job.composed || !suggestionsActive || barCollapsed) return null
        val set = composingSuggestions(job.composed, job.raw, job.predicted, result.pool, result.fix, result.pmi, result.slip,
            result.english)
            .copy(number = job.number, math = job.math)
        return withCorrectionHint(set, job.raw, result.plan, proxy)
    }

    /**
     * ONBOARDING-SPEC §8 — tô nền gợi ý sửa: từ đang soạn gõ sai + có bản sửa đủ chắc (cùng quyết
     * định với dấu cách — [correctionDecision]) + dấu cách lúc này sẽ áp được
     * ([EngineBridge.autoCorrectPreview]) ⇒ [CorrectionHint.apply]. Còn lại: [set] như cũ.
     */
    private fun withCorrectionHint(set: SuggestionSet, raw: String, plan: AutoCorrect.Plan?, proxy: TextProxy?): SuggestionSet {
        shownCorrection = raw to null
        if (plan == null || proxy == null || !correctionHintOn) return set
        val fix = correctionDecision(raw, plan) ?: return set
        val original = bridge.autoCorrectPreview(fix, proxy) ?: return set
        val hinted = CorrectionHint.apply(set, typed = original, fix = fix, need = slotWant - 1)
        if (hinted.correction) shownCorrection = raw to fix
        return hinted
    }

    /** Đồng bộ (test / debug): tính luôn trên thread gọi. */
    fun suggestionsNow(proxy: TextProxy): SuggestionSet? = when (val p = requestSuggestions(proxy)) {
        is SuggestionPlan.Ready -> p.set
        is SuggestionPlan.Background -> completeSuggestions(p.job, p.job.compute(), proxy)
    }

    private fun composingSuggestions(composed: String, raw: String, predicted: String,
                                     pool: List<VNSuggest.Match>, fix: String?,
                                     pmi: FloatArray? = null, slip: String? = null,
                                     english: EnglishAssist.Result? = null): SuggestionSet {
        val literal = if (predicted == composed) raw else composed
        var word: String? = null
        var word2: String? = null
        var more: List<String> = emptyList()
        // Từ thêm tay (Từ điển cá nhân) khớp tiền tố: đứng đầu pool (freq cao) — lexicon
        // không có tên riêng/thuật ngữ nên VNSuggest không bao giờ đưa ra.
        val manualHits = langModel.manualCompletions(composed)
        val pool = if (manualHits.isEmpty()) pool else {
            val low = manualHits.mapTo(HashSet()) { it.lowercase() }
            manualHits.map { VNSuggest.Match(it, MANUAL_FREQ) } + pool.filter { it.word.lowercase() !in low }
        }
        if (pool.isNotEmpty()) {
            val ctxKey = (lastWord ?: "") + "\u0001" + (lastWord2 ?: "") + (if (filterSensitive) "\u0001" else "")
            if (ctxKey != ctxCacheKey) {
                // + cặp chọn tay (CuratedPairs) — chỉ xếp gợi ý đang gõ dở, không thêm từ kế tiếp.
                // Lọc bật: cặp / bộ ba nhạy cảm (SensitiveWords.pairs / triples) không thưởng ngữ cảnh.
                // + chuỗi seed ba từ (SensitiveWords.chain) sau (lastWord2, lastWord).
                val p2 = lastWord2
                ctxCache = lastWord?.let {
                    CuratedPairs.withNext(SensitiveWords.dropPairs(SensitiveWords.chain(it, p2) + langModel.nextWords(it, p2, 24),
                        it, filterSensitive, p2), it, p2).toSet()
                } ?: emptySet()
                ctxCacheKey = ctxKey
            }
            val ctx = ctxCache
            val ranked = SensitiveWords.filter(
                SuggestRank.rankInline(pool, pmi, Cp.count(composed), langModel::count, ctx), filterSensitive, after = lastWord,
                prev2 = lastWord2)
            val words = EnglishAssist.merge(ranked, EnglishAssist.filtered(english, lastWord, lastWord2, filterSensitive))
            word = words.firstOrNull()?.let { caseForContext(displayCase(it, lastWord), composed) }
            word2 = words.getOrNull(1)?.let { caseForContext(displayCase(it, lastWord), composed) }
            // "Số từ gợi ý" 4–5: ứng viên hạng 3… (ô 1 = nguyên văn, ô 2–3 = word/word2)
            if (slotWant > 3) more = words.drop(2).take(slotWant - 3).map { caseForContext(displayCase(it, lastWord), composed) }
        } else if (fix != null || english != null) {
            // Không âm tiết Việt nào khớp: bản sửa chạm trượt (nếu có) rồi từ tiếng Anh ([EnglishAssist]).
            val words = EnglishAssist.merge(listOfNotNull(fix), EnglishAssist.filtered(english, lastWord, lastWord2, filterSensitive))
            word = words.firstOrNull()?.let { caseForContext(displayCase(it, lastWord), composed) }
            word2 = words.getOrNull(1)?.let { caseForContext(displayCase(it, lastWord), composed) }
            if (slotWant > 3) more = words.drop(2).take(slotWant - 3).map { caseForContext(displayCase(it, lastWord), composed) }
        }
        // Trượt vào phím thanh mà vẫn ra từ ("casn" → cán, ý là cân): bản sửa vào slot 3.
        val slip = slip?.let { caseForContext(it, composed) }
        if (slip != null && slip != word) { if (word == null) word = slip else word2 = slip }
        var emojis: List<String> = emptyList()
        val cLow = composed.lowercase()
        lastWord?.let { emojis = EmojiSuggest.emojis(it.lowercase() + " " + cLow) }
        if (emojis.isEmpty()) emojis = EmojiSuggest.emojis(composed)
        if (emojis.isEmpty()) emojis = EmojiSuggest.emojis(raw.lowercase())
        // Bảng biên soạn không có → từ khoá tiếng Anh CLDR ("japan", "pizza") + mã nước IN HOA
        // ("JP"). Từ có dấu / âm tiết Việt không dấu không bao giờ khớp (EmojiSearch.typing).
        if (emojis.isEmpty()) emojis = EmojiSearch.typing(lastWord, composed, raw)
        // Không có emoji lấp ô cuối → đệm cho đủ ô (literal + slotWant−1 từ). 1 ô: không đệm — ô
        // duy nhất hiện ứng viên thật, không có thì nguyên văn (SuggestionSlots.arrange).
        if (emojis.isEmpty() && slotWant > 1) {
            val words = padWords(listOfNotNull(word, word2) + more, slotWant - 1, composed)
            word = words.firstOrNull()
            word2 = words.getOrNull(1)
            more = words.drop(2)
        }
        // Đang gõ đúng một chữ tắt: slot chính hiện nội dung sẽ bung (chạm = bung ngay).
        // Nội dung nhiều dòng không lên bar (gõ ranh giới vẫn bung).
        val preview = bridge.shortcutPreview
        if (preview != null && !preview.contains('\n') && word != preview) {
            if (word != null && word2 != null && more.isNotEmpty()) more = listOf(word2!!) + more
            word2 = word ?: word2; word = preview
        }
        return SuggestionSet(literal = literal, word = word, word2 = word2, emojis = emojis, moreWords = more)
    }

    // MARK: nút Dán

    private var pasteSeenChange = -1
    /** Debug mode: dòng "paste:" chỉ ghi khi (cc, used, has, kết quả) đổi. */
    private var pasteLogKey = ""
    private var pasteSeenAt = Long.MIN_VALUE / 2
    private var pasteUsedChange = -1
    private var pasteCheckedAt = Long.MIN_VALUE / 2
    private var pasteCached = false
    /** Id ([ClipboardSource.clipId]) của mục mà [pasteCached] tính cho. */
    private var pasteId = Long.MIN_VALUE

    /** Mời dán một lần mỗi mục clipboard — IME gắn [PasteOfferOnce.persist] + id đã lưu. */
    val pasteOnce = PasteOfferOnce()

    /** StripView báo lời mời dán thực sự hiện (true) / rời bar (false). */
    fun pasteOfferVisible(on: Boolean) { if (on) pasteOnce.displayed(pasteId) else pasteOnce.ended() }

    /** Bàn phím vừa hiện hẳn / clipboard đổi: bỏ cache 2 s. */
    fun invalidatePasteCache() { pasteCheckedAt = Long.MIN_VALUE / 2 }

    /** Kết quả nút Dán gần nhất (IME so trước/sau invalidate để quyết refresh). */
    val pasteCachedValue: Boolean get() = pasteCached

    internal fun pasteOffer(proxy: TextProxy): Boolean {
        val cb = clipboard ?: return false
        val last = proxy.contextBeforeInput()?.let { Cp.lastCodePoint(it) }
        if (last != null && !Character.isWhitespace(last)) return false
        val now = clock()
        if (now - pasteCheckedAt < 2000) return pasteCached && pasteOnce.canOffer(pasteId)
        pasteCheckedAt = now
        val cc = cb.changeCount
        if (cc != pasteSeenChange) { pasteSeenChange = cc; pasteSeenAt = now }
        val has = cb.hasText()
        pasteCached = cc != pasteUsedChange && has && now - pasteSeenAt < 180_000
        if (pasteCached) { pasteId = cb.clipId(); pasteCached = pasteOnce.canOffer(pasteId) }
        // Chỉ khi trạng thái đổi (kiểm 2 s/lần mỗi lần refresh bar ⇒ dòng y hệt trừ tuổi là rác).
        if (TouchLog.enabled) {
            val key = "$cc/$pasteUsedChange/$has/$pasteCached"
            if (key != pasteLogKey) {
                pasteLogKey = key
                TouchLog.write("paste: cc=$cc used=$pasteUsedChange has=${if (has) 1 else 0} " +
                    "age=${(now - pasteSeenAt) / 1000}s → ${if (pasteCached) 1 else 0}")
            }
        }
        return pasteCached
    }

    // MARK: chip số + lịch sử clipboard

    private var clipPreference: ClipChip.Kind? = null
    private var numericPad = false
    /** Gemini Nano trích địa chỉ (app đặt; null = không có). */
    var clipAddressAI: ClipAddressAI? = null
    /** AI vừa trả địa chỉ ⇒ IME vẽ lại thanh. */
    var onClipAddressReady: (() -> Unit)? = null
    private var aiAddrFor = -1
    private var aiAddr: String? = null
    private var aiAddrInFlight = -1
    private var chipsText: String? = null
    private var chipsForChange = -1
    private var chipsCached: List<ClipChip> = emptyList()

    /** Chip của clip hiện tại (đọc nội dung 1 lần mỗi changeCount); clip nhạy cảm → không chip. */
    internal fun clipChips(): List<ClipChip> {
        val cb = clipboard ?: return emptyList()
        val cc = cb.changeCount
        if (cc != chipsForChange) {
            chipsForChange = cc
            chipsText = if (cb.isSensitive()) null else cb.readText()
            chipsCached = chipsText?.let { ClipDetect.detect(it) } ?: emptyList()
        }
        var chips = if (numericPad) chipsCached.filter { it.kind != ClipChip.Kind.ADDRESS } else chipsCached
        if (clipPreference == ClipChip.Kind.ADDRESS && chips.none { it.kind == ClipChip.Kind.ADDRESS }) {
            aiAddress(cc)?.let { chips = chips + ClipChip(ClipChip.Kind.ADDRESS, it, ClipDetect.label(ClipChip.Kind.ADDRESS, it)) }
        }
        return ClipDetect.prioritize(chips, clipPreference)
    }

    /**
     * Ô địa chỉ mà luật không ra: hỏi Gemini Nano NỀN, một lần mỗi nội dung clipboard ([cc]); trả
     * kết quả đã có hoặc null ngay (không chặn gõ). Xong ⇒ [onClipAddressReady] vẽ lại thanh.
     */
    private fun aiAddress(cc: Int): String? {
        if (aiAddrFor == cc) return aiAddr
        val ai = clipAddressAI ?: return null
        val text = chipsText ?: return null
        if (aiAddrInFlight == cc) return null
        aiAddrInFlight = cc
        ai.extract(AIAddress.INSTRUCTIONS, AIAddress.prompt(text)) { out ->
            if (aiAddrInFlight != cc) return@extract
            aiAddrInFlight = -1
            aiAddrFor = cc
            aiAddr = out?.let { AIAddress.validate(it, text) }
            if (aiAddr != null) onClipAddressReady?.invoke()
        }
        return null
    }

    /**
     * Clip vừa đổi (listener) hoặc bàn phím vừa hiện: ghi vào lịch sử nếu được phép —
     * lịch sử bật, không ẩn danh, ô đang hiện không phải mật khẩu ([fieldSecure]), clip
     * không đánh dấu nhạy cảm. [onlyIfNew]: bỏ qua nếu nội dung đã có (lúc hiện bàn phím,
     * không làm mới hạn của mục cũ). Trả true nếu lịch sử đổi (IME ghi file).
     */
    fun recordClip(fieldSecure: Boolean, onlyIfNew: Boolean = false): Boolean {
        val h = clipHistory ?: return false
        val cb = clipboard ?: return false
        if (incognito || fieldSecure || cb.isSensitive()) return false
        val text = cb.readText() ?: return false
        if (onlyIfNew && h.contains(text)) return false
        val now = clock()
        // Thêm mục ⇒ prune luôn (hạn "Giữ lịch sử" vừa rút ngắn áp ngay, không đợi mở bảng).
        return h.add(text, now).also { if (it) h.prune(now) }
    }

    /** Chạm một mục trong bảng lịch sử: chèn nguyên văn, không học, không space. */
    fun insertClip(text: String, proxy: TextProxy) {
        clearSwipe(); clearUndo()
        if (text.isNotEmpty()) proxy.insertText(text)
        bridge.reset(); lastWord = null; lastWord2 = null
        lastCommit = null
    }

    /**
     * Phím 📋 bàn số: dán clipboard sau khi [filter] (vd [NumericPaste.clean]) — như nút Dán trên
     * dải (đánh dấu mục đã dùng ⇒ lời mời Dán không hiện lại). Trả chữ đã chèn ("" = không chèn).
     */
    fun pasteFiltered(proxy: TextProxy, filter: (String) -> String): String {
        clearSwipe(); clearUndo()
        val cb = clipboard
        val s = cb?.readText()?.let(filter).orEmpty()
        if (s.isNotEmpty()) proxy.insertText(s)
        pasteUsedChange = cb?.changeCount ?: -1
        pasteOnce.used(pasteId)
        pasteCached = false
        bridge.reset(); lastWord = null; lastWord2 = null
        lastCommit = null
        return s
    }

    // MARK: chạm gợi ý

    /**
     * Chạm slot (QuickType): emoji thay từ; từ thay từ + space (học weight 2); fragment
     * (`gmail.com`, `com`) chèn không space; [SuggestionSet.PASTE_TOKEN] dán clipboard.
     * Sau đó IME gọi updateAutoShift + refresh bar, phát click.
     */
    fun acceptSuggestion(item: String, proxy: TextProxy) {
        suggestionSnap = null
        if (emailBar) { acceptEmailChip(item, proxy); return }
        if (item == SuggestionSet.PASTE_IMAGE_TOKEN) {
            pasteUsedChange = clipboard?.changeCount ?: -1; pasteCached = false
            pasteOnce.used(pasteId)
            return
        }
        if (item == SuggestionSet.ADD_TONES_TOKEN) { applyAddTones(proxy); return }
        if (item == SuggestionSet.UNDO_TONES_TOKEN) { undoAddTones(proxy); return }
        if (item == SuggestionSet.UNDO_REVISE_TOKEN) { undoRevise(proxy); return }
        if (item == SuggestionSet.RETRO_OFFER_TOKEN) { bridge.applyRetroOffer(proxy); clearUndo(); return }
        if (item == SuggestionSet.UNDO_RETRO_TOKEN) {
            bridge.revertRetro(proxy); bridge.revertedRetro = false; clearUndo(); return
        }
        if (item.startsWith(SuggestionSet.KEEP_TYPED_PREFIX)) {
            // Ô ngoặc kép cạnh ô tô nền (§8): giữ chữ đã gõ + không bao giờ tự sửa lại từ này.
            val typed = item.substring(SuggestionSet.KEEP_TYPED_PREFIX.length)
            if (autoCorrectRejected.add(typed)) onAutoCorrectRejected?.invoke()
            acMemo = null
            acceptSuggestion(typed, proxy)
            return
        }
        if (item == SuggestionSet.UNDO_AUTOCORRECT_TOKEN) {
            val fixed = bridge.autoCorrectUndo?.second
            if (bridge.revertAutoCorrect(proxy)) bridge.revertedAutoCorrect?.let { bridge.revertedAutoCorrect = null; onAutoCorrectReverted(it, fixed) }
            return
        }
        tonesUndo = null
        if (item.startsWith(SuggestionSet.CLIP_CHIP_PREFIX)) {
            proxy.insertText(item.substring(SuggestionSet.CLIP_CHIP_PREFIX.length))
            pasteUsedChange = clipboard?.changeCount ?: -1
            pasteOnce.used(pasteId)
            pasteCached = false
            bridge.reset(); lastWord = null; lastWord2 = null
            return
        }
        if (item == SuggestionSet.PASTE_TOKEN) {
            val cb = clipboard
            val s = cb?.readText()
            if (!s.isNullOrEmpty()) proxy.insertText(s)
            pasteUsedChange = cb?.changeCount ?: -1
            pasteOnce.used(pasteId)
            pasteCached = false
            bridge.reset(); lastWord = null; lastWord2 = null
            return
        }
        if (item == SuggestionSet.NUMBER_TOKEN) { acceptNumberChip(proxy); return }
        if (item == SuggestionSet.MATH_TOKEN) { acceptMathChip(proxy); return }
        val sw = openSwipeWord()
        if (sw != null && item in swipeAlts) {
            // Chạm biến thể của từ vừa vuốt: thay từ, vẫn là composition mở (chưa học — học khi chốt).
            if (!proxy.confirmTail(sw)) { clearSwipe(); bridge.reset(); return }
            proxy.deleteCodePoints(Cp.count(sw))
            proxy.insertText(item)
            val itemEnglish = item in swipeEnglishAlts
            // phương án chéo đổi chỗ với từ cũ (từ cũ tiếng Anh ⇒ vẫn là phương án tiếng Anh)
            val eng = swipeEnglishAlts - item + (if (swipeLiteral) setOf(sw) else emptySet())
            val alts = swipeAlts.map { if (it == item) sw else it }
            revisable = null                       // user đã chọn: cú vuốt kế không sửa lại từ này
            swipeShortcutKey = null                // đã chọn phương án: ⌫ thường
            if (itemEnglish) {
                bridge.adoptLiteral()
                swipeWord = item; swipeLiteral = true; swipeAlts = alts; swipeEnglishAlts = eng
            } else if (bridge.adoptWord(item)) {
                swipeWord = item; swipeLiteral = false; swipeAlts = alts; swipeEnglishAlts = eng
            } else clearSwipe()
            return
        }
        clearSwipe()
        val uRaw = restoreUndoRaw; val uComposed = restoreUndoComposed
        if (undoOfferActive && uRaw != null && uComposed != null && item == uComposed && bridge.composedWord.isEmpty()) {
            if (!proxy.confirmTail(uRaw)) {
                // Chữ vừa chốt không còn trước con trỏ: không xoá mù, bỏ lời mời hoàn tác.
                clearUndo(); bridge.reset()
                return
            }
            proxy.deleteCodePoints(Cp.count(uRaw))
            proxy.insertText("$uComposed ")
            suggestionSnap = "$uComposed "
            clearUndo()
            bridge.reset()
            commitAndLearn(uComposed, accepted = true)
            return
        }
        clearUndo()
        val isFragment = item.contains('.') || item.contains('@')
        val isWord = !isFragment && item.isNotEmpty() && Character.isLetter(item.codePointAt(0))
        val n = Cp.count(bridge.composedWord)
        // Fail-safe: từ đang soạn không còn trước con trỏ ⇒ chèn, không xoá mù.
        if (n > 0 && proxy.confirmTail(bridge.composedWord)) proxy.deleteCodePoints(n)
        proxy.insertText(if (isWord) "$item " else item)
        if (isWord) suggestionSnap = "$item "
        bridge.reset()
        // Chèn đúng dạng đang hiện ("Bên" khi Shift); học dạng thường (record lowercase).
        if (isWord) commitAndLearn(item, accepted = true) else { lastWord = null; lastWord2 = null }
        // Như gõ một chữ: Shift một-lần nhả (IME hạ phím Shift), Caps Lock giữ.
        keyboardShift = keyboardShift?.let { SuggestionCase.afterCommit(it) }
    }

    /**
     * Chip "↩︎ từ cũ": trả từ vuốt trước về như lúc vuốt (đuôi phải đúng "từ mới + từ đang
     * mở", lệch ⇒ bỏ) và học lại từ cũ thay từ mới.
     */
    private fun undoRevise(proxy: TextProxy) {
        typedUndo?.let { typedUndo = null; undoTypedRevise(it, proxy); return }
        val (old, new) = reviseUndo ?: return
        reviseUndo = null
        revisable = null
        val sw = openSwipeWord() ?: return
        val tail = "$new $sw"
        if (!proxy.confirmTail(tail)) return
        proxy.deleteCodePoints(Cp.count(tail))
        proxy.insertText("$old $sw")
        bridge.forgetLastCommit()
        val lc = lastCommit
        if (lc != null && lc.word == new) {
            lc.learned?.let { langModel.retract(it) }
            lastWord = lc.prev1; lastWord2 = lc.prev2
        }
        commitAndLearn(old, accepted = true)
    }

    /**
     * Từ gõ [typed] vừa được [boundary] chốt ngay sau từ vuốt đang chờ: chấm lại từ vuốt; đổi thì
     * thay đúng đuôi "từ vuốt ␠ từ gõ ranh giới" (kiểm lại trước khi xoá) và học lại cả hai từ
     * theo thứ tự mới. [sentenceBreak] = ranh giới là dấu câu/xuống dòng (ngữ cảnh đã xoá).
     */
    private fun reviseTypedPrev(p: TypedPending, typed: String, boundary: String, proxy: TextProxy,
                                sentenceBreak: Boolean) {
        val e = SwipeRevise.reviseTyped(p.rev, typed, boundary, proxy.contextBeforeInput(),
            learnedCase = { langModel.learnedCase(it) }, properNouns = !traits.lowercaseSuggestions) ?: return
        proxy.deleteCodePoints(Cp.count(e.tail))
        proxy.insertText(e.replacement)
        val newLearned = relearnPair(p.learned, e.new, typed)
        typedUndo = TypedUndo(e, newLearned, sentenceBreak)
        if (sentenceBreak) { lastWord = null; lastWord2 = null }
        TouchLog.write("swipe: sửa từ vuốt trước theo từ gõ (${Cp.count(e.old)}→${Cp.count(e.new)} chars)")
    }

    /**
     * Rút lượt học của từ gõ vừa chốt ([lastCommit]) và của từ đứng trước nó ([before]), học lại
     * [first] (cùng ngữ cảnh trái cũ) rồi [typed]. Trả lượt học của [first].
     */
    private fun relearnPair(before: LastCommit?, first: String, typed: String, accepted: Boolean = false): LastCommit? {
        val lc = lastCommit
        if (lc != null && lc.word == typed) lc.learned?.let { langModel.retract(it) }
        if (before != null) {
            before.learned?.let { langModel.retract(it) }
            lastWord = before.prev1; lastWord2 = before.prev2
        } else { lastWord = null; lastWord2 = null }
        commitAndLearn(first, accepted)
        val firstLearned = lastCommit
        commitAndLearn(typed)
        return firstLearned
    }

    /** Chip "↩︎ từ cũ" sau khi sửa theo từ gõ: trả từ vuốt về như lúc vuốt (đuôi phải khớp). */
    private fun undoTypedRevise(u: TypedUndo, proxy: TextProxy) {
        val e = u.edit
        val now = e.replacement
        if (proxy.contextBeforeInput()?.endsWith(now) != true) return
        proxy.deleteCodePoints(Cp.count(now))
        proxy.insertText(e.tail)
        // lượt học của typed/new hiện là lastCommit/u.newLearned: rút, học lại old (user chọn) + typed
        relearnPair(u.newLearned, e.old, e.typed, accepted = true)
        if (u.sentenceBreak) { lastWord = null; lastWord2 = null }
    }

    /** Chạm chip số: thay đúng đuôi đã tính (kiểm lại đuôi trước khi xoá — lệch thì bỏ). */
    private fun acceptNumberChip(proxy: TextProxy) {
        val c = numberChip ?: return
        numberChip = null
        if (c.replace.isNotEmpty()) {
            if (!proxy.confirmTail(c.replace)) { TouchLog.write("failsafe: number chip tail mismatch → skip"); return }
            proxy.deleteCodePoints(Cp.count(c.replace))
        }
        proxy.insertText(c.insert)
        bridge.reset()
        lastWord = null; lastWord2 = null
        clearUndo(); clearSwipe()
        numberSpaces = 0          // kết quả mới cũng là số → chip kế trong chuỗi (tiền → chữ)
    }

    /** Chạm chip kết quả phép tính: tính lại từ context lúc chạm — khác chip đang hiện thì bỏ. */
    private fun acceptMathChip(proxy: TextProxy) {
        val c = mathChip ?: return
        mathChip = null; mathArmed = false
        if (MathResults.chipAtCaret(proxy.contextBeforeInput() ?: "") != c) {
            TouchLog.write("failsafe: math chip context mismatch → skip"); return
        }
        proxy.insertText(c.insert)
        bridge.reset()
        lastWord = null; lastWord2 = null
        clearUndo(); clearSwipe()
        numberSpaces = 0
    }

    // MARK: thêm dấu cho câu không dấu (chỉ khi người dùng bấm chip — AddTones.kt)

    /** Lọc bật: cặp nhạy cảm (SensitiveWords.pairs, có trong seed) không thưởng khi chọn dấu. */
    private fun tonesPersonal(): AddTones.Personal {
        val fs = filterSensitive
        return AddTones.Personal(langModel::count) { a, b -> if (fs && SensitiveWords.isPair(a, b)) 0 else langModel.bigramCount(a, b) }
    }

    /** Dữ liệu cá nhân cho nút "Thêm dấu" bấm tay (thẻ Công cụ / bảng sửa — TextToolRunner.addTones). */
    fun addTonesPersonal(): AddTones.Personal = tonesPersonal()

    /** Kế hoạch thêm dấu cho chữ trước con trỏ (cache theo văn bản); null = không mời. */
    private fun addTonesPlan(proxy: TextProxy): AddTones.Plan? {
        if (!addTonesChip) return null
        if (!PlusGate.isUnlocked(PlusFeature.SENTENCE_DIACRITICS)) return null
        if (bridge.isComposing || !proxy.canReEdit || proxy.hasSelection) return null
        val before = proxy.contextBeforeInput()
        if (before.isNullOrEmpty()) return null
        if (before != tonesCacheBefore) {
            tonesCacheBefore = before
            tonesCachePlan = AddTones.plan(before, tonesPersonal())?.takeIf { it.original != tonesDismissed }
        }
        return tonesCachePlan
    }

    /** Chạm "Thêm dấu": thay đuôi không dấu bằng bản có dấu (fail-safe confirmTail, không xoá mù). */
    fun applyAddTones(proxy: TextProxy) {
        tonesCacheBefore = null
        val plan = addTonesPlan(proxy) ?: return
        tonesCacheBefore = null
        if (!proxy.confirmTail(plan.original)) return
        proxy.deleteCodePoints(Cp.count(plan.original))
        proxy.insertText(plan.replacement)
        bridge.reset(); lastWord = null; lastWord2 = null; clearUndo(); lastCommit = null
        tonesUndo = plan
    }

    /** "Hoàn tác" / ⌫ ngay sau: trả lại bản gốc nếu chữ trước con trỏ vẫn là bản vừa thay. */
    fun undoAddTones(proxy: TextProxy) {
        val u = tonesUndo ?: return
        tonesUndo = null
        tonesCacheBefore = null
        if (!proxy.canReEdit || !proxy.confirmTail(u.replacement)) return
        proxy.deleteCodePoints(Cp.count(u.replacement))
        proxy.insertText(u.original)
        tonesDismissed = u.original
        bridge.reset(); lastWord = null; lastWord2 = null; clearUndo(); lastCommit = null
    }

    companion object {
        /** Nhãn chip theo ngôn ngữ giao diện ([L10n.lang] đặt một lần mỗi lần hiện bàn phím). */
        val ADD_TONES_LABEL: String get() = tr("Thêm dấu")
        val UNDO_TONES_LABEL: String get() = "↩\uFE0E " + tr("Hoàn tác")
        /** freq giả cho từ thêm tay trong pool hoàn thiện = trần freq lexicon (255). */
        const val MANUAL_FREQ = 255
        val EMAIL_SUFFIXES = listOf("gmail.com", "yahoo.com", "outlook.com")
        val DOMAIN_TLDS = listOf("com", "vn", "net")

        /** Auto-shift thuần: ô trống, hoặc " " sau .!?, hoặc sau \n. */
        fun autoShiftFor(before: String): Boolean {
            if (before.isEmpty() || before.endsWith("\n")) return true
            if (!before.endsWith(" ")) return false
            // Duyệt ngược qua ' '/'\t' (không copy chuỗi bằng trim — RAM-AUDIT #8).
            var i = before.length - 1
            while (i >= 0 && (before[i] == ' ' || before[i] == '\t')) i--
            if (i < 0) return false
            val c = before[i]
            return c == '.' || c == '!' || c == '?'
        }

        /** Mode mạnh nhất của ô (≈ bitmask TextUtils.getCapsMode: có bit nào là shift). */
        fun capMode(t: FieldTraits): CapMode = when {
            t.capCharacters -> CapMode.CHARACTERS
            t.capWords -> CapMode.WORDS
            t.capSentences -> CapMode.SENTENCES
            else -> CapMode.NONE
        }

        /**
         * Auto-shift thuần theo mode (logic tương đương TextUtils.getCapsMode, không cần
         * android.jar): CHARACTERS luôn hoa; WORDS đầu ô hoặc sau khoảng trắng (bỏ qua
         * ngoặc/nháy mở như getCapsMode: `("` rồi mới tới chữ); SENTENCES như [autoShiftFor].
         */
        fun autoShiftFor(before: String, mode: CapMode): Boolean = when (mode) {
            CapMode.NONE -> false
            CapMode.CHARACTERS -> true
            CapMode.SENTENCES -> autoShiftFor(before)
            CapMode.WORDS -> {
                val t = before.trimEnd('"', '\'', '(', '[', '{', '“', '‘', '«')
                t.isEmpty() || t.last().isWhitespace()
            }
        }
    }
}
