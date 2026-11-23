package com.viettelex.keyboard

/**
 * Tên SharedPreferences, key và file dùng chung IME (agent C) + app settings (agent D).
 * Key giữ nguyên tên iOS (App Group `group.com.viettelex`), spec §9.
 */
object Keys {
    const val PREFS = "viettelex"
    /**
     * Prefs RIÊNG cho số đo lúc chạy của IME (cỡ vùng bàn phím dọc cho trình chỉnh ảnh nền) —
     * tách khỏi [PREFS] để IME ghi không bắn listener của chính nó, và không vào sao lưu.
     */
    const val RUNTIME_PREFS = "viettelex_runtime"
    /** "w×h" px của gốc input view lần gần nhất ở hướng dọc. */
    const val IME_PORTRAIT_SIZE = "imePortraitSize"

    // Kiểu Gõ
    const val SIMPLE_TELEX = "simpleTelex"
    const val FREE_MARKING = "freeMarking"
    const val QUICK_TELEX = "quickTelex"
    const val MODERN_TONE = "modernTone"
    const val CONTEXTUAL_ENGLISH = "contextualEnglish"
    /**
     * "Tự sửa từ phía trước" (Bool, thử nghiệm, mặc định TẮT; chỉ hiện khi [CONTEXTUAL_ENGLISH]
     * bật): sửa ngược tiếng Anh TỰ ÁP + chip "Khôi phục" thay vì chỉ MỜI qua chip. Như iOS.
     */
    const val RETRO_ENGLISH_AUTO = "retroactiveEnglish"
    /**
     * "Đoán từ trùng theo tần suất" (Bool, thử nghiệm, mặc định TẮT; chỉ hiện khi
     * [CONTEXTUAL_ENGLISH] bật): engine `englishByFrequency`. Cùng tên key với iOS/macOS.
     */
    const val ENGLISH_BY_FREQUENCY = "englishByFrequency"
    const val RE_EDIT_WORDS = "reEditWords"
    /**
     * "Tự thêm dấu mũ" (Bool, mặc định TẮT, issue #166): engine `autoCircumflex` — vietj → việt,
     * benhj → bệnh khi vần không mũ không tồn tại. Cùng tên key với iOS/macOS.
     */
    const val AUTO_CIRCUMFLEX = "autoCircumflex"
    const val AUTO_FIX_ADJACENT = "autoFixAdjacent"
    const val TEENCODE = "teencode"
    /** Tự động viết hoa đầu câu (Bool, mặc định BẬT) — tắt ⇒ không auto-shift, không đọc context. */
    const val AUTO_CAPITALIZE = "autoCapitalize"
    /** Kiểu gõ VNI (Bool, mặc định false = Telex) — tên như iOS App Group / macOS. */
    const val VNI_MODE = "vniMode"
    // Tính Năng
    const val AUTO_RESTORE = "autoRestore"
    const val LIVE_SPELL_CHECK = "liveSpellCheck"
    /** Gõ vuốt (thử nghiệm, mặc định tắt). */
    const val SWIPE_TYPING = "swipeTyping"
    const val SWIPE_ENGLISH = "swipeEnglish"
    /** Giải mã vuốt bằng mô hình FUTO Swipe (thử nghiệm, mặc định TẮT — FutoSwipe). */
    const val SWIPE_FUTO = "swipeFuto"
    /** Luyện vuốt (app): đồng ý LƯU nét vuốt trên máy để xuất (mặc định TẮT, không gửi mạng). */
    const val SWIPE_PRACTICE_SAVE = "swipePracticeSave"
    /** Chọn phím theo ngữ cảnh lúc chạm (thử nghiệm, mặc định BẬT) — TouchTarget. */
    const val SMART_TOUCH = "smartTouch"
    /** Tự sửa từ gõ sai ở dấu cách (thử nghiệm, mặc định TẮT) — AutoCorrect. */
    const val AUTO_CORRECT = "autoCorrect"
    /** Từ từng hoàn tác tự sửa (chuỗi nhiều dòng) — trạng thái bàn phím, KHÔNG sao lưu. */
    const val AUTO_CORRECT_REJECTED = "autoCorrectRejected"
    /** Id (timestamp ClipDescription) mục clipboard đã mời "Dán" — PasteOfferOnce; không nội dung. */
    const val PASTE_OFFERED_ID = "pasteOfferedId"
    /** Vuốt phím cách đổi Tiếng Việt ↔ Tiếng Anh — mặc định TẮT (tắt ⇒ luôn Tiếng Việt). */
    const val SPACE_SWIPE_LANGUAGE = "spaceSwipeLanguage"
    /** String "slow" | "medium" | "fast" — độ nhạy con trỏ khi giữ phím cách ([TrackpadSpeed]), mặc định "medium". Tên như iOS App Group. */
    const val TRACKPAD_SPEED = "trackpadSpeed"
    /** Vuốt phím chữ thẳng lên ra lệnh sao chép/cắt/dán… ([KeyCommandGesture]) — mặc định TẮT. Giống iOS. */
    const val SWIPE_KEY_COMMANDS = "swipeKeyCommands"
    /** Tự thêm dấu cách sau . , ? ! ; : ([AutoSpace]) — mặc định TẮT. Giống iOS. */
    const val AUTO_SPACE_AFTER_PUNCT = "autoSpaceAfterPunct"
    /** Ngôn ngữ đang gõ ("vi" | "en") — trạng thái bàn phím, KHÔNG sao lưu. */
    const val KEYBOARD_LANGUAGE = "keyboardLanguage"
    /** Gõ Telex bằng bàn phím cứng (tablet, DeX, Chromebook, BT/USB) — mặc định BẬT. */
    const val HARDWARE_TELEX = "hardwareTelex"

    /** Gõ tắt: bật/tắt (mặc định BẬT) + bảng (String YAML phẳng như macOS, xem [ShortcutFile]). */
    const val SHORTCUTS_ENABLED = "shortcutsEnabled"
    const val SHORTCUTS = "shortcuts"
    /** Mốc thêm/sửa từng gõ tắt (ms) — thứ tự "mới nhất trước" ([ShortcutOrder]); IME không đọc. */
    const val SHORTCUTS_ADDED = "shortcutsAdded"

    /** Key ảnh hưởng engine/EngineBridge — đổi lúc bàn phím đang mở thì áp ngay. */
    val ENGINE_KEYS = setOf(SIMPLE_TELEX, FREE_MARKING, QUICK_TELEX, MODERN_TONE, CONTEXTUAL_ENGLISH, RETRO_ENGLISH_AUTO, ENGLISH_BY_FREQUENCY,
        AUTO_FIX_ADJACENT, TEENCODE, AUTO_RESTORE, LIVE_SPELL_CHECK, AUTO_CIRCUMFLEX, SHORTCUTS_ENABLED, SHORTCUTS, VNI_MODE)
    const val SHOW_SUGGESTIONS = "showSuggestions"
    /**
     * Chip "Thêm dấu" hiện TỰ ĐỘNG trên thanh gợi ý (Bool, mặc định TẮT — ưu tiên gõ trơn):
     * tắt ⇒ không đọc chữ trước con trỏ / không chạy AddTones ở mỗi dấu cách.
     */
    const val ADD_TONES_CHIP = "addTonesChip"
    /** Chip số (đọc số thành chữ / tiền / máy tính nhanh) — mặc định BẬT; tắt ⇒ không đọc context sau chữ số. */
    const val NUMBER_CHIPS = "numberChips"
    /** Int 0…5 — "Số từ gợi ý" ([SuggestionCount]): 0 = Tự động (3 ô). Tên như iOS App Group. */
    const val SUGGESTION_COUNT = "suggestionCount"
    /**
     * Bool — "Nút ẩn bàn phím": ⌄ góc phải thanh gợi ý, chạm = ẩn bàn phím (mặc định TẮT ⇒ thanh y như cũ).
     * Chỉ hiện khi dải gợi ý có chỗ (Thanh gợi ý bật). Tên như iOS App Group.
     */
    const val KEYBOARD_DISMISS_BUTTON = "keyboardDismissButton"
    /** "Hiện kết quả phép tính" (Bool, mặc định BẬT) — chỉ đọc context ngay sau phím "=". */
    const val MATH_RESULTS = "mathResults"
    /**
     * Công cụ văn bản (Plus — thẻ "Công cụ" của bảng ☰ + hàng công cụ bảng sửa văn bản) — Bool,
     * mặc định BẬT; tắt ⇒ không chip, không hàng công cụ, không làm gì. Cùng tên key iOS.
     */
    const val TEXT_TOOLS_ENABLED = "textToolsEnabled"
    /** "Gợi ý cả khi ứng dụng tắt gợi ý" (Bool, mặc định BẬT, #113) — cùng tên key iOS. */
    const val SUGGEST_IN_NO_SUGGEST_FIELDS = "suggestInNoSuggestFields"
    const val FILTER_SENSITIVE = "filterSensitive"
    const val TEMPLATES_ENABLED = "templatesEnabled"
    const val SHOW_SPACE_LOGO = "showSpaceLogo"
    /** Bool — ô phóng to chữ khi bấm phím (balloon); tên như iOS App Group. Mặc định BẬT. */
    const val KEY_PREVIEW = "keyPreviewEnabled"
    /** Bool — "Phím sẫm khi bấm": phím chữ/số/ký hiệu đổi nền khi đè; tên như iOS App Group. Mặc định BẬT. */
    const val KEY_PRESS_HIGHLIGHT = "keyPressHighlight"
    const val HAPTIC_FEEDBACK = "hapticFeedback"
    /** Độ mạnh rung 10…100 % (mặc định 30, [HapticStrength]) — giống iOS. */
    const val HAPTIC_STRENGTH = "hapticStrength"
    /** Bool — âm thanh phím riêng ([KeySoundSynth]), mặc định TẮT (= tiếng hệ thống như cũ). */
    const val KEY_SOUND = "keySound"
    /** Int 0…100 (%) — âm lượng âm phím riêng, mặc định 50. */
    const val KEY_SOUND_VOLUME = "keySoundVolume"
    /** String — kiểu âm phím ([KeySoundStyle.id]): system|subtle|wood|mechanical|typewriter|bubble|rock|pop|water|vintage|phao|jingle|piano|dantranh|trong|boo|guitar|custom, mặc định subtle. */
    const val KEY_SOUND_STYLE = "keySoundStyle"
    /** String — "Hiệu ứng khi bấm phím" ([KeyEffect.id], Plus): none|heart|bubble|ripple|petal|firework|flash|matrix|lightning|emojiword|blossom|combo|ink|wave|snow|meteor|lantern|smoke|string|plasma|shake|laser|glitch|tone|keyword|letters|sand|sea|tokens|dancefloor|tunnel|float, mặc định none. Tên như iOS App Group. */
    const val KEY_EFFECT = "keyEffect"
    /** String — "Bạn đồng hành" ([BuddyCharacter.id], Plus): off|girl|boy|cat|chick, mặc định off. Tên như iOS App Group. */
    const val KEYBOARD_BUDDY = "keyboardBuddy"
    /** + [BuddyCharacter.id] — String kiểu vẽ RIÊNG từng nhân vật ([BuddyStyle.id]): sprite|vector, mặc định sprite. Tên như iOS App Group. */
    const val BUDDY_STYLE_PREFIX = "buddyStyle."
    /** Int 1…10 — cỡ "Bạn đồng hành" ([BuddyPlacement], chung mọi nhân vật), mặc định 5. Tên như iOS App Group. */
    const val BUDDY_SIZE = "buddySize"
    /** Int −10…10 dp — lề phải nhân vật (dương = dời trái), mặc định 0. */
    const val BUDDY_PAD_RIGHT = "buddyPadRight"
    /** Int −10…10 dp — lề trên nhân vật (dương = dời xuống), mặc định 0. */
    const val BUDDY_PAD_TOP = "buddyPadTop"
    /** String — "Hiệu ứng nét vuốt" ([SwipeTrailStyle.id]): none|simple|fire|electric|brush|rainbow|neon|stardust|firework|plasma|kaleidoscope|melt|chroma|keys|calligraphy|comet|firefly|matrix|petals|theme, mặc định simple. Tên như iOS App Group. */
    const val SWIPE_TRAIL = "swipeTrail"
    /** String — "Âm thanh nét vuốt" ([SwipeSoundStyle.id]): none|pencil|brush|chalk|marker, mặc định none. Tên như iOS App Group. */
    const val SWIPE_SOUND = "swipeSound"
    /** Int −10…18 (dp mỗi hàng; [KeyboardSettings.ROW_HEIGHT_MAX], trên +10 còn kẹp theo cao màn hình). */
    const val ROW_HEIGHT_ADJUST = "rowHeightAdjust"
    /** Bool — hàng phím số trên plane chữ (tên như iOS App Group). */
    const val NUMBER_ROW = "numberRow"
    /** Bool — hàng số cao bằng hàng chữ (chỉ khi [NUMBER_ROW] bật), mặc định TẮT (phím số 0.8×). */
    const val NUMBER_ROW_FULL_HEIGHT = "numberRowFullHeight"
    /** Int 0…48 (dp) — nâng bàn phím: đệm nền dưới hàng phím đáy, mặc định 0 (#112). */
    const val KEYBOARD_RAISE = "keyboardRaise"
    /** String "low" | "medium" | "high" — chiều cao thanh gợi ý ([SuggestionBarHeight]), mặc định "medium". Tên như iOS App Group. */
    const val SUGGESTION_BAR_HEIGHT = "suggestionBarHeight"
    /** String "muted" | "bright" — màu chữ gợi ý ([SuggestionInk]), mặc định "muted" (Xám). Tên như iOS App Group. */
    const val SUGGESTION_INK = "suggestionInk"
    /** Bool — giữ q…p ra 1…0 (chỉ khi hàng số tắt), mặc định BẬT — [KeyAlternates]. */
    const val LONG_PRESS_NUMBERS = "longPressNumbers"
    /** Bool — giữ a–l, z–m ra ký hiệu, mặc định TẮT — [KeyAlternates]. */
    const val LONG_PRESS_SYMBOLS = "longPressSymbols"
    /** Bool — giữ ⇧ + phím chữ ra ký tự phụ (số / ký hiệu), mặc định BẬT — [ShiftHold]. */
    const val HOLD_SHIFT_SYMBOLS = "holdShiftSymbols"
    const val FLICK_DOWN_ALTERNATES = "flickDownAlternates"
    /** String "comma" | "period" | "both" | "off" — phím cạnh dấu cách bàn chữ điện thoại ([SpaceSideKey]), mặc định "comma". */
    const val SPACE_SIDE_KEY = "spaceSideKey"
    /** String "auto" | "always" | "off" — về bàn chữ sau ký hiệu ở plane ?123 ([SymbolReturn]), mặc định "off" (từ 10/11/2026). */
    const val SYMBOL_RETURN = "symbolReturn"
    /** Bool — "Phím to" (điện thoại): "," "." hàng đáy rộng bằng phím 😊, mặc định TẮT. Tên như iOS App Group. */
    const val LARGE_KEYS = "largeKeys"
    /** String "bottom" | "top" — nút 😊 ở hàng đáy hay thanh gợi ý ([EmojiKeyPlacement]), mặc định "bottom". Tên như iOS App Group. */
    const val EMOJI_KEY_PLACEMENT = "emojiKeyPlacement"
    /** String "medium" | "large" — cỡ chữ trên phím ([KeyLabelSize], Android), mặc định "medium". */
    const val KEY_LABEL_SIZE = "keyLabelSize"
    /** String "off" | "left" | "right" — chế độ một tay (điện thoại; tên như iOS App Group). */
    const val ONE_HAND_MODE = "oneHandMode"
    /**
     * Bool — bàn phím thả nổi (#112): khung nhỏ kéo đi đâu cũng được, app không bị co. Mặc định
     * TẮT. Có sao lưu; vị trí ([FLOATING_POS_PORTRAIT] / [FLOATING_POS_LANDSCAPE]) thì không.
     */
    const val FLOATING_KEYBOARD = "floatingKeyboard"
    /**
     * Bool — bàn phím tách đôi khi màn hình rộng ([SplitLayout]; Giao diện). Mặc định TẮT. Tên như
     * iOS App Group (`SplitLayout.settingKey`).
     */
    const val SPLIT_KEYBOARD = "splitKeyboard"
    /**
     * String "fx,fy" (0…1, phần khoảng trống ngang/dọc còn lại) — vị trí khung thả nổi theo
     * chiều màn hình. Lưu ở prefs trạng thái IME ("ime_state"), không sao lưu (riêng từng máy).
     */
    const val FLOATING_POS_PORTRAIT = "floatingPosPortrait"
    const val FLOATING_POS_LANDSCAPE = "floatingPosLandscape"
    /** String "vi" | "en" — ngôn ngữ giao diện app + chữ trên bàn phím ([L10n]). Mặc định "vi"
     *  LUÔN (không theo ngôn ngữ máy); tên như iOS App Group. */
    const val UI_LANGUAGE = "uiLanguage"
    /** String "left" | "right" — bên dùng gần nhất (giữ lâu icon con trỏ bật lại bên này). */
    const val ONE_HAND_LAST = "oneHandLastSide"
    /** String JSON `[{"label":…,"text":…}]`; vắng ⇒ mặc định từ assets/ios-mau-cau.yml. */
    const val USER_TEMPLATES = "userTemplates"
    /** Bool — đã chạy migration một lần thêm mẫu động có sẵn ([Templates.migrateDynamicBuiltins]). */
    const val DYNAMIC_SNIPPETS_MIGRATED = "dynamicSnippetsMigrated1"
    const val DEBUG_TOUCH_LOG = "debugTouchLog"
    // Theme & ảnh nền ([ThemeSettings]) — tên như iOS App Group.
    const val KEYBOARD_THEME = "keyboardTheme"
    const val WALLPAPER_ENABLED = "wallpaperEnabled"
    const val WALLPAPER_DIM = "wallpaperDim"
    const val WALLPAPER_BLUR = "wallpaperBlur"
    const val WALLPAPER_VERSION = "wallpaperVersion"
    /** Long — app tải xong tệp của theme (ThemeAssets) ⇒ đổi ⇒ IME dựng lại view. Không sao lưu. */
    const val THEME_ASSETS_STAMP = "themeAssetsStamp"
    /** Khung cắt ảnh nền "x,y,w,h" chuẩn hoá theo ảnh gốc ([WallpaperCrop]); thiếu = cắt giữa. */
    const val WALLPAPER_CROP = "wallpaperCrop"
    /** Độ trong suốt phím (nền + phím) / ký tự trên phím, 0…100. */
    const val KEYBOARD_TRANSPARENCY = "keyboardTransparency"
    const val KEY_LABEL_TRANSPARENCY = "keyLabelTransparency"
    /** Bool — theme Hệ thống dùng màu hình nền Material You (Android 12+); mặc định true ([SystemColors]). */
    const val SYSTEM_MATERIAL_YOU = "systemMaterialYou"
    /**
     * "Tuỳ chỉnh nâng cao" (Plus, [KeyStyle]) — cùng khoá iOS. Màu Int 0xRRGGBB (-1 = theo theme);
     * bo góc 0…100 % nửa cạnh ngắn (-1 = mặc định); cỡ chữ 80…150 % (0 = mặc định);
     * phông "default"|"rounded"|"serif"|"mono"|"condensed"; độ đậm "light"…"heavy".
     */
    const val KEY_LABEL_COLOR = "keyLabelColor"
    const val KEY_FILL_COLOR = "keyFillColor"
    const val KEY_CORNER_RADIUS = "keyCornerRadius"
    const val KEY_FONT_SCALE = "keyFontScale"
    const val KEY_LABEL_FONT = "keyLabelFont"
    const val KEY_LABEL_WEIGHT = "keyLabelWeight"
    /**
     * "Tuỳ chỉnh nâng cao" RIÊNG từng theme (từ 10/2026, thay bộ khoá chung ở trên — chỉ còn để chuyển
     * đổi): String JSON chuẩn [KeyStyleStore], cùng khoá + định dạng iOS.
     */
    const val KEY_STYLES = "keyStyles"
    /** "Giao diện JSON": kho theme tự tạo — String JSON chuẩn {"id": đặc tả, …} ([CustomThemeStore]), cùng iOS. */
    const val CUSTOM_THEMES = "customThemes"
    /** Đặc tả chuẩn của theme tự tạo ĐANG CHỌN ("" = không) — IME chỉ đọc khoá này. Không sao lưu. */
    const val ACTIVE_THEME_SPEC = "activeThemeSpec"
    /** Lịch sử clipboard (mặc định TẮT — riêng tư). */
    const val CLIPBOARD_HISTORY = "clipboardHistory"
    /** "Giữ lịch sử clipboard": "1h" (mặc định) / "24h" / "7d" — [ClipboardTTL]. */
    const val CLIPBOARD_TTL = "clipboardTTL"
    /** Chế độ ẩn danh thủ công: không học từ, không lưu clipboard. */
    const val INCOGNITO = "incognitoMode"
    // nội bộ IME
    /** String, emoji nối bằng '\n' (xem [EmojiRecents]). */
    const val EMOJI_RECENTS = "emojiRecents"
    /** Long ms — app ghi khi user bấm "Xóa từ đã học" (đã xoá [USERLM_FILE]). */
    const val USERLM_RESET_AT = "userlmResetAt"

    // VietTelex Plus (xem [PlusGate]) — app ghi, IME chỉ đọc.
    /** Boolean: đã mua Plus (Play Billing xác nhận + acknowledge). */
    const val PLUS_UNLOCKED = "plusUnlocked"
    /** Boolean: giả lập đã mua — chỉ bản debug nghe. */
    const val PLUS_DEBUG_OVERRIDE = "plusDebugOverride"
    /** Dịch trên máy (Plus): ngôn ngữ đích, mã ML Kit (String, mặc định "en"; xem [TranslateLangs]). */
    const val TRANSLATE_TARGET = "translateTarget"
    /** Dịch trên máy: chỉ tải gói ngôn ngữ qua Wi-Fi (Bool, mặc định BẬT). */
    const val TRANSLATE_WIFI_ONLY = "translateWifiOnly"
    /**
     * Dịch bằng AI trên máy (Gemini Nano, thử nghiệm — Bool, mặc định TẮT): hỏi model trước, lỗi /
     * quá hạn / kết quả bất thường ⇒ ML Kit. Chỉ hiện công tắc khi máy có Gemini Nano.
     */
    const val TRANSLATE_AI = "translateAI"

    // file trong filesDir
    const val USERLM_FILE = "userlm.bin"
    const val TOUCHLOG_FILE = "touchlog.txt"
    /**
     * Ảnh nền đã CẮT theo khung/thu nhỏ/mờ/nén cho IME; bản gốc (≤2048 px, chưa mờ, chưa cắt)
     * để đổi độ mờ / chỉnh khung không cần chọn lại. Cả hai KHÔNG vào sao lưu.
     */
    const val WALLPAPER_FILE = "wallpaper.jpg"
    const val WALLPAPER_SRC_FILE = "wallpaper-src.jpg"
    const val CLIPBOARD_FILE = "clipboard-history.txt"

    // assets
    const val ASSET_LEXICON = "vnlexicon.bin"
    const val ASSET_EN_LEXICON = "enlexicon.bin"
    const val ASSET_LM = "vnlm.bin"
    /** Encoder FUTO Swipe fp16 (FUTO Model Weights License 1.0 — chỉ đọc khi bật SWIPE_FUTO). */
    const val ASSET_FUTO = "futoswipe.bin"
    const val ASSET_EMOJI_SUGGEST = "emojisuggest.bin"
    const val ASSET_SEED = "seed.tsv"
    /** Emoji + khoá tìm tiếng Việt + kaomoji (Scripts/gen-emoji-data.py, chung iOS). */
    const val ASSET_EMOJI_DATA = "emoji.bin"
    /** Trie chọn phím thông minh dựng sẵn (KeyPriorBlob; sinh bằng KeyPriorBlobTests). */
    const val ASSET_KEY_PRIOR = "keyprior.bin"
    const val ASSET_TEMPLATES_YAML = "ios-mau-cau.yml"
}
