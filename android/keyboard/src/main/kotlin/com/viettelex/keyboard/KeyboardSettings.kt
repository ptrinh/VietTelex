package com.viettelex.keyboard

/**
 * Setting bàn phím — mặc định y iOS (khác macOS: simpleTelex BẬT). Đọc lại mỗi lần
 * bàn phím hiện ([load]).
 */
data class KeyboardSettings(
    var freeMarking: Boolean = true,
    var simpleTelex: Boolean = true,
    var liveSpellCheck: Boolean = true,
    var autoRestore: Boolean = true,
    var quickTelex: Boolean = false,
    var modernTone: Boolean = false,
    /** Chính tả teencode — mặc định TẮT (issue #94). */
    var teencode: Boolean = false,
    /**
     * Kiểu gõ VNI — mặc định TẮT (Telex). Số 1–9/0 mang dấu KHI ĐANG SOẠN TỪ (hoặc sửa dấu
     * từ ngay trước con trỏ); ngoài từ vẫn là số. Engine giống macOS (`vniMode`).
     */
    var vniMode: Boolean = false,
    var showSuggestions: Boolean = true,
    /** Chip "Thêm dấu" tự hiện khi chữ trước con trỏ không dấu — mặc định TẮT (hiệu năng thắng). */
    var addTonesChip: Boolean = false,
    /** Chip số trên thanh gợi ý — mặc định BẬT (chỉ đọc context ngay sau chữ số/phép tính). */
    var numberChips: Boolean = true,
    /** "Số từ gợi ý" ([SuggestionCount]): 0 = Tự động (3 ô), 1…5. */
    var suggestionCount: Int = SuggestionCount.AUTO,
    /** "Nút ẩn bàn phím" (⌄ góc phải thanh gợi ý) — mặc định TẮT. Giống iOS (KeyboardDismissButton). */
    var keyboardDismissButton: Boolean = false,
    /** "Hiện kết quả phép tính" (12*3= → chip 36 ở slot đầu) — mặc định BẬT; chỉ đọc context ngay sau "=". */
    var mathResults: Boolean = true,
    /** Công cụ văn bản (Plus) — mặc định BẬT; hiện thật khi [textToolsActive]. Giống iOS. */
    var textToolsEnabled: Boolean = true,
    /**
     * "Gợi ý cả khi ứng dụng tắt gợi ý" (#113, như Gboard) — mặc định BẬT: ô chữ đặt
     * NO_SUGGESTIONS (không mật khẩu/ẩn danh/số) vẫn gợi ý chữ, nhưng không tự sửa, không học từ.
     * Tắt ⇒ như cũ: chỉ thanh công cụ ([StripMode.TOOLS]).
     */
    var suggestInNoSuggestFields: Boolean = true,
    /** Đi theo showSuggestions (không có toggle riêng). */
    var learnWords: Boolean = true,
    var filterSensitive: Boolean = true,
    var hapticFeedback: Boolean = false,
    /** Độ mạnh rung 10…100 % ([HapticStrength]) — chỉ dùng khi hapticFeedback bật. */
    var hapticStrength: Int = HapticStrength.DEFAULT,
    /** Âm thanh phím riêng — mặc định TẮT (tắt ⇒ AudioManager.playSoundEffect như cũ, 0 chi phí). */
    var keySound: Boolean = false,
    /** Âm lượng âm phím riêng 0…100 %. */
    var keySoundVolume: Int = 50,
    /** Kiểu âm phím ([KeySoundStyle.id]) — mặc định "subtle" (Nhẹ nhàng). */
    var keySoundStyle: String = KeySoundStyle.DEFAULT.id,
    /** Gợi ý sửa lỗi chạm trượt (AdjacentKeyFixer) — mặc định BẬT. */
    var autoFixAdjacent: Boolean = true,
    /** Quyết định theo ngữ cảnh ("he is" giữ tiếng Anh) — mặc định BẬT. */
    var contextualEnglish: Boolean = true,
    /**
     * "Tự sửa từ phía trước" (thử nghiệm, mặc định TẮT): engine luôn quyết định sửa ngược tiếng
     * Anh khi [contextualEnglish] bật (docs/DESIGN.md "Sửa ngược tiếng Anh"); công tắc này chọn
     * TỰ ÁP (+ chip "Khôi phục", ⌫ ngay sau trả lại) thay vì chỉ MỜI qua chip. Giống iOS.
     */
    var retroEnglishAuto: Boolean = false,
    /**
     * "Đoán từ trùng theo tần suất" (thử nghiệm, mặc định TẮT): engine `englishByFrequency` — đầu
     * cụm "his" → His khi âm tiết Việt hiếm; từ kế cho thấy tiếng Việt ⇒ LẬT LẠI ("hí hửng"). Phép
     * lật lại luôn tự áp (kể cả khi [retroEnglishAuto] tắt, kể cả Enter — áp trước khi chèn ký tự).
     */
    var englishByFrequency: Boolean = false,
    /** Sửa dấu từ đã gõ xong (⌫ mở lại từ; phím dấu thanh nạp lại từ trước con trỏ) — mặc định BẬT. */
    var reEditWords: Boolean = true,
    /** "Tự thêm dấu mũ" (issue #166) — engine `autoCircumflex`, mặc định TẮT (tắt ⇒ một phép thử Bool mỗi lần render). */
    var autoCircumflex: Boolean = false,
    /** Gõ vuốt (thử nghiệm) — mặc định TẮT; tắt ⇒ không dựng template, không ghi checkpoint. */
    var swipeTyping: Boolean = false,
    /**
     * Vuốt ra từ tiếng Anh (công tắc con của gõ vuốt) — mặc định BẬT: câu Việt chen từ
     * Anh rất thường (check mail, gửi file); decoder nghiêng Việt + biên độ nên chỉ ra
     * tiếng Anh khi hình vuốt thắng rõ / đang trong mạch Anh, và từ điển chỉ nạp khi gõ
     * vuốt đang bật. Giống iOS.
     */
    var swipeEnglish: Boolean = true,
    /** Giải mã vuốt bằng mô hình FUTO Swipe (thử nghiệm, mặc định TẮT — [FutoSwipe]). Giống iOS. */
    var swipeFuto: Boolean = false,
    /** Chọn phím theo ngữ cảnh lúc chạm vùng biên 2 phím (TouchTarget) — thử nghiệm, mặc định BẬT. */
    var smartTouch: Boolean = true,
    /** Tự sửa từ gõ sai ở dấu cách ([AutoCorrect]) — thử nghiệm, mặc định TẮT. Giống iOS. */
    var autoCorrect: Boolean = false,
    /** Tự động viết hoa đầu câu (auto-shift theo cờ CAP_* của ô) — mặc định BẬT. */
    var autoCapitalize: Boolean = true,
    /** Vuốt phím cách đổi Tiếng Việt ↔ Tiếng Anh — mặc định TẮT. Giống iOS. */
    var spaceSwipeLanguage: Boolean = false,
    /** "Độ nhạy con trỏ" khi giữ phím cách: Chậm / Vừa (mặc định) / Nhanh ([TrackpadSpeed]). Giống iOS. */
    var trackpadSpeed: TrackpadSpeed = TrackpadSpeed.DEFAULT,
    /** Vuốt phím chữ thẳng lên ⇒ sao chép/cắt/dán/chọn hết/hoàn tác/làm lại ([KeyCommandGesture]) — mặc định TẮT. */
    var swipeKeyCommands: Boolean = false,
    /** Tự thêm dấu cách sau . , ? ! ; : ([AutoSpace]) — mặc định TẮT; tắt ⇒ không đọc context. */
    var autoSpaceAfterPunct: Boolean = false,
    /** Telex cho bàn phím cứng — mặc định BẬT; tắt ⇒ IME không đụng KeyEvent. */
    var hardwareTelex: Boolean = true,
    /** Gõ tắt — mặc định BẬT, bảng mặc định RỖNG (như macOS; "Thêm bộ gợi ý" trong app). */
    var shortcutsEnabled: Boolean = true,
    var shortcuts: ShortcutTable = ShortcutTable(),
    // Phần UI (iOS đọc rải rác trong KeyboardView) — gom về đây cho IME.
    var templatesEnabled: Boolean = true,
    var showSpaceLogo: Boolean = true,
    /** Ô phóng to chữ khi bấm phím — mặc định BẬT; tắt ⇒ không tạo/vẽ balloon. */
    var keyPreview: Boolean = true,
    /** Phím sẫm khi bấm (phím chữ/số/ký hiệu) — mặc định BẬT như iOS; tắt ⇒ đường chạm không thêm việc. */
    var keyPressHighlight: Boolean = true,
    /** "Hiệu ứng khi bấm phím" (Plus) — mặc định Không ⇒ IME không tạo overlay. */
    var keyEffect: KeyEffect = KeyEffect.DEFAULT,
    /** "Bạn đồng hành" (Plus) — mặc định Tắt ⇒ IME không tạo view. */
    var buddy: BuddyCharacter = BuddyCharacter.DEFAULT,
    /** Kiểu vẽ của [buddy] (cài đặt riêng từng nhân vật, [BuddyStyle.key]) — mặc định Hoạt hình. */
    var buddyStyle: BuddyStyle = BuddyStyle.DEFAULT,
    /** "Vị trí & cỡ" nhân vật (chung mọi nhân vật) — mặc định cỡ 5, lề 0. */
    var buddyPlacement: BuddyPlacement = BuddyPlacement.STANDARD,
    /** "Hiệu ứng nét vuốt" — mặc định Đơn giản; Tắt ⇒ IME không gắn vệt vuốt. */
    var swipeTrail: SwipeTrailStyle = SwipeTrailStyle.DEFAULT,
    /** "Âm thanh nét vuốt" — mặc định Tắt ⇒ IME không dựng SoundPool tiếng vuốt. */
    var swipeSound: SwipeSoundStyle = SwipeSoundStyle.DEFAULT,
    /** [ROW_HEIGHT_MIN]…[ROW_HEIGHT_MAX] dp mỗi hàng (IME kẹp thêm phần trên +10 theo cao màn hình — KeyLayout.effectiveRowAdjust). */
    var rowHeightAdjust: Int = 0,
    /** Hàng phím số 1…0 trên hàng chữ — mặc định TẮT. */
    var numberRow: Boolean = false,
    /** Hàng số cao bằng hàng chữ (chỉ có tác dụng khi [numberRow]) — mặc định TẮT. */
    var numberRowFullHeight: Boolean = false,
    /** Nâng bàn phím 0…[KEYBOARD_RAISE_MAX] dp (đệm nền dưới hàng đáy) — mặc định 0. */
    var keyboardRaise: Int = 0,
    /** "Chiều cao thanh gợi ý": Thấp / Vừa (mặc định) / Cao ([SuggestionBarHeight]). */
    var suggestionBarHeight: SuggestionBarHeight = SuggestionBarHeight.DEFAULT,
    /** "Màu chữ gợi ý": Xám (mặc định, như bàn phím Apple) / Sáng ([SuggestionInk]). */
    var suggestionInk: SuggestionInk = SuggestionInk.DEFAULT,
    /** Giữ q…p ra 1…0 (chỉ khi hàng số tắt) — mặc định BẬT. Giống iOS. */
    var longPressNumbers: Boolean = true,
    /** Giữ a–l, z–m ra ký hiệu — mặc định TẮT. Giống iOS. */
    var longPressSymbols: Boolean = false,
    /** "Giữ Shift để gõ số và ký hiệu" ([ShiftHold]) — mặc định BẬT. Giống iOS. */
    var holdShiftSymbols: Boolean = true,
    /** Phím cạnh dấu cách (bàn chữ ô thường; tablet: có / không "," "." hai bên space) — mặc định "," ([SpaceSideKey]). */
    var spaceSideKey: SpaceSideKey = SpaceSideKey.DEFAULT,
    /** "Về bàn chữ sau ký hiệu": Tự động / Luôn / Tắt (mặc định) ([SymbolReturn]). Giống iOS. */
    var symbolReturn: SymbolReturn = SymbolReturn.DEFAULT,
    /** "Phím to" (điện thoại): "," "." cạnh space rộng bằng phím 😊 — mặc định TẮT. Giống iOS (LargeKeys). */
    var largeKeys: Boolean = false,
    /** Nút 😊: hàng đáy (mặc định) / thanh gợi ý ([EmojiKeyPlacement]). */
    var emojiKeyPlacement: EmojiKeyPlacement = EmojiKeyPlacement.DEFAULT,
    /** Cỡ chữ trên phím: Vừa (mặc định) / Lớn ([KeyLabelSize]). */
    var keyLabelSize: KeyLabelSize = KeyLabelSize.DEFAULT,
    /** Chế độ một tay: "off" | "left" | "right" — mặc định tắt (tablet bỏ qua). */
    var oneHandMode: String = "off",
    /** Bàn phím thả nổi (#112) — mặc định TẮT; bật ⇒ một tay + nâng bàn phím bị bỏ qua. */
    var floatingKeyboard: Boolean = false,
    /** Bàn phím tách đôi khi rộng ≥ [SplitLayout.MIN_WIDTH_DP] — mặc định TẮT (tắt ⇒ 0 chi phí). */
    var splitKeyboard: Boolean = false,
    var debugTouchLog: Boolean = false,
    /** Lịch sử clipboard — mặc định TẮT. */
    var clipboardHistory: Boolean = false,
    /** "Giữ lịch sử clipboard" (mục không ghim, không bí mật) — mặc định 1 giờ. */
    var clipboardTtl: ClipboardTTL = ClipboardTTL.DEFAULT,
    /** Ẩn danh thủ công: không học từ, không lưu clipboard. */
    var incognito: Boolean = false,
    /** Giá trị Keys.USERLM_RESET_AT (0 = chưa từng xoá). */
    var userlmResetAt: Long = 0,
) {
    /**
     * Công cụ văn bản hiện thật: đã mở khoá Plus, công tắc người dùng bật, ô không phải
     * mật khẩu. Tắt ⇒ không chip đầu lưới mẫu câu, không hàng công cụ ở bảng sửa văn bản.
     */
    fun textToolsActive(unlocked: Boolean, secureField: Boolean): Boolean =
        unlocked && textToolsEnabled && !secureField

    companion object {
        /** Trần thanh "Nâng bàn phím" (dp). */
        const val KEYBOARD_RAISE_MAX = 48
        /**
         * "Chiều cao hàng phím" (dp mỗi hàng). Trần +10 → +18 (16/10/2026, tester: phím vẫn nhỏ ở
         * mức lớn nhất ⇒ hàng 56 → 74 dp, phím 46 → 64 dp ≈ +14 % so với trần cũ). Phần trên +10
         * kẹp theo cao màn hình (KeyLayout.effectiveRowAdjust) cho máy nhỏ / màn ngang.
         */
        const val ROW_HEIGHT_MIN = -10
        const val ROW_HEIGHT_MAX = 18
        /** Trần cũ — tới mức này không bao giờ bị kẹp theo màn hình (không thụt lùi người đang dùng). */
        const val ROW_HEIGHT_UNCLAMPED_MAX = 10
        fun clampRaise(dp: Int): Int = dp.coerceIn(0, KEYBOARD_RAISE_MAX)

        /** [get] trả giá trị thô của key (vd `prefs.all[key]`), null nếu vắng. */
        fun load(get: (String) -> Any?): KeyboardSettings {
            val s = KeyboardSettings()
            fun b(key: String, cur: Boolean): Boolean = (get(key) as? Boolean) ?: cur
            s.freeMarking = b(Keys.FREE_MARKING, s.freeMarking)
            s.simpleTelex = b(Keys.SIMPLE_TELEX, s.simpleTelex)
            s.liveSpellCheck = b(Keys.LIVE_SPELL_CHECK, s.liveSpellCheck)
            s.autoRestore = b(Keys.AUTO_RESTORE, s.autoRestore)
            s.quickTelex = b(Keys.QUICK_TELEX, s.quickTelex)
            s.modernTone = b(Keys.MODERN_TONE, s.modernTone)
            s.teencode = b(Keys.TEENCODE, s.teencode)
            s.vniMode = b(Keys.VNI_MODE, s.vniMode)
            s.showSuggestions = b(Keys.SHOW_SUGGESTIONS, s.showSuggestions)
            s.filterSensitive = b(Keys.FILTER_SENSITIVE, s.filterSensitive)
            s.addTonesChip = b(Keys.ADD_TONES_CHIP, s.addTonesChip)
            s.numberChips = b(Keys.NUMBER_CHIPS, s.numberChips)
            s.suggestionCount = SuggestionCount.parse(get(Keys.SUGGESTION_COUNT))
            s.keyboardDismissButton = b(Keys.KEYBOARD_DISMISS_BUTTON, s.keyboardDismissButton)
            s.mathResults = b(Keys.MATH_RESULTS, s.mathResults)
            s.textToolsEnabled = b(Keys.TEXT_TOOLS_ENABLED, s.textToolsEnabled)
            s.suggestInNoSuggestFields = b(Keys.SUGGEST_IN_NO_SUGGEST_FIELDS, s.suggestInNoSuggestFields)
            s.hapticFeedback = b(Keys.HAPTIC_FEEDBACK, s.hapticFeedback)
            s.hapticStrength = HapticStrength.clamp((get(Keys.HAPTIC_STRENGTH) as? Number)?.toInt() ?: HapticStrength.DEFAULT)
            s.keySound = b(Keys.KEY_SOUND, s.keySound)
            s.keySoundVolume = ((get(Keys.KEY_SOUND_VOLUME) as? Number)?.toInt() ?: s.keySoundVolume).coerceIn(0, 100)
            s.keySoundStyle = (get(Keys.KEY_SOUND_STYLE) as? String)?.takeIf { it in KeySoundStyle.IDS } ?: KeySoundStyle.DEFAULT.id
            s.autoFixAdjacent = b(Keys.AUTO_FIX_ADJACENT, s.autoFixAdjacent)
            s.contextualEnglish = b(Keys.CONTEXTUAL_ENGLISH, s.contextualEnglish)
            s.retroEnglishAuto = b(Keys.RETRO_ENGLISH_AUTO, s.retroEnglishAuto)
            s.englishByFrequency = b(Keys.ENGLISH_BY_FREQUENCY, s.englishByFrequency)
            s.reEditWords = b(Keys.RE_EDIT_WORDS, s.reEditWords)
            s.autoCircumflex = b(Keys.AUTO_CIRCUMFLEX, s.autoCircumflex)
            s.swipeTyping = b(Keys.SWIPE_TYPING, s.swipeTyping)
            s.swipeEnglish = b(Keys.SWIPE_ENGLISH, s.swipeEnglish)
            s.swipeFuto = b(Keys.SWIPE_FUTO, s.swipeFuto)
            s.smartTouch = b(Keys.SMART_TOUCH, s.smartTouch)
            s.autoCorrect = b(Keys.AUTO_CORRECT, s.autoCorrect)
            s.autoCapitalize = b(Keys.AUTO_CAPITALIZE, s.autoCapitalize)
            s.spaceSwipeLanguage = b(Keys.SPACE_SWIPE_LANGUAGE, s.spaceSwipeLanguage)
            s.trackpadSpeed = TrackpadSpeed.of(get(Keys.TRACKPAD_SPEED))
            s.swipeKeyCommands = b(Keys.SWIPE_KEY_COMMANDS, s.swipeKeyCommands)
            s.autoSpaceAfterPunct = b(Keys.AUTO_SPACE_AFTER_PUNCT, s.autoSpaceAfterPunct)
            s.hardwareTelex = b(Keys.HARDWARE_TELEX, s.hardwareTelex)
            s.shortcutsEnabled = b(Keys.SHORTCUTS_ENABLED, s.shortcutsEnabled)
            if (s.shortcutsEnabled) s.shortcuts = ShortcutTable(ShortcutFile.parse(get(Keys.SHORTCUTS) as? String))
            s.templatesEnabled = b(Keys.TEMPLATES_ENABLED, s.templatesEnabled)
            s.showSpaceLogo = b(Keys.SHOW_SPACE_LOGO, s.showSpaceLogo)
            s.keyPreview = b(Keys.KEY_PREVIEW, s.keyPreview)
            s.keyPressHighlight = b(Keys.KEY_PRESS_HIGHLIGHT, s.keyPressHighlight)
            s.keyEffect = KeyEffect.of(get(Keys.KEY_EFFECT))
            s.buddy = BuddyCharacter.of(get(Keys.KEYBOARD_BUDDY))
            s.buddyStyle = BuddyStyle.of(get(BuddyStyle.key(s.buddy))).resolved(s.buddy)
            s.buddyPlacement = BuddyPlacement.of(get(Keys.BUDDY_SIZE), get(Keys.BUDDY_PAD_RIGHT), get(Keys.BUDDY_PAD_TOP))
            s.swipeTrail = SwipeTrailStyle.of(get(Keys.SWIPE_TRAIL))
            s.swipeSound = SwipeSoundStyle.of(get(Keys.SWIPE_SOUND))
            s.debugTouchLog = b(Keys.DEBUG_TOUCH_LOG, s.debugTouchLog)
            s.numberRow = b(Keys.NUMBER_ROW, s.numberRow)
            s.numberRowFullHeight = b(Keys.NUMBER_ROW_FULL_HEIGHT, s.numberRowFullHeight)
            s.keyboardRaise = clampRaise((get(Keys.KEYBOARD_RAISE) as? Number)?.toInt() ?: 0)
            s.longPressNumbers = b(Keys.LONG_PRESS_NUMBERS, s.longPressNumbers)
            s.longPressSymbols = b(Keys.LONG_PRESS_SYMBOLS, s.longPressSymbols)
            s.holdShiftSymbols = b(Keys.HOLD_SHIFT_SYMBOLS, s.holdShiftSymbols)
            s.spaceSideKey = SpaceSideKey.of(get(Keys.SPACE_SIDE_KEY))
            s.symbolReturn = SymbolReturn.of(get(Keys.SYMBOL_RETURN))
            s.largeKeys = b(Keys.LARGE_KEYS, s.largeKeys)
            s.suggestionBarHeight = SuggestionBarHeight.of(get(Keys.SUGGESTION_BAR_HEIGHT))
            s.suggestionInk = SuggestionInk.of(get(Keys.SUGGESTION_INK))
            s.emojiKeyPlacement = EmojiKeyPlacement.of(get(Keys.EMOJI_KEY_PLACEMENT))
            s.keyLabelSize = KeyLabelSize.of(get(Keys.KEY_LABEL_SIZE))
            s.oneHandMode = (get(Keys.ONE_HAND_MODE) as? String)?.takeIf { it == "left" || it == "right" } ?: "off"
            s.floatingKeyboard = b(Keys.FLOATING_KEYBOARD, s.floatingKeyboard)
            s.splitKeyboard = b(Keys.SPLIT_KEYBOARD, s.splitKeyboard)
            s.clipboardHistory = b(Keys.CLIPBOARD_HISTORY, s.clipboardHistory)
            s.clipboardTtl = ClipboardTTL.of(get(Keys.CLIPBOARD_TTL))
            s.incognito = b(Keys.INCOGNITO, s.incognito)
            s.rowHeightAdjust = ((get(Keys.ROW_HEIGHT_ADJUST) as? Number)?.toInt() ?: 0).coerceIn(ROW_HEIGHT_MIN, ROW_HEIGHT_MAX)
            s.userlmResetAt = (get(Keys.USERLM_RESET_AT) as? Number)?.toLong() ?: 0
            s.learnWords = s.showSuggestions   // bật gợi ý = bật học (quyết định 2026-07-24)
            return s
        }
    }
}

/** "Tự sửa từ phía trước" — phần dùng chung app ↔ bàn phím (song sinh iOS RetroEnglishUI). */
object RetroEnglishUI {
    /**
     * Công tắc chỉ hiện khi "Quyết định theo ngữ cảnh" bật (engine chỉ sửa ngược khi đó), và
     * không ở VNI (engine chỉ sửa ngược ở Telex — như teencode).
     */
    fun switchVisible(contextualEnglish: Boolean, vniMode: Boolean = false): Boolean = contextualEnglish && !vniMode
}
