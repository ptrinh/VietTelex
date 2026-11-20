package com.viettelex.android.ime

import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.inputmethodservice.InputMethodService
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import android.os.Process
import android.os.SystemClock
import android.text.InputType
import android.util.Log
import android.view.KeyEvent
import android.view.View
import android.view.accessibility.AccessibilityManager
import android.view.inputmethod.EditorInfo
import android.view.inputmethod.InputMethodManager
import androidx.core.view.WindowInsetsControllerCompat
import com.viettelex.android.BuildConfig
import com.viettelex.android.shared.DebugLog
import com.viettelex.android.shared.DiskStamp
import com.viettelex.android.shared.PrefSync
import com.viettelex.android.shared.VTPrefs
import com.viettelex.keyboard.ThemeSettings
import com.viettelex.keyboard.AutoCorrect
import com.viettelex.keyboard.KeyAlternates
import com.viettelex.keyboard.Cancellable
import com.viettelex.keyboard.EmojiData
import com.viettelex.keyboard.ClipboardHistory
import com.viettelex.keyboard.ClipboardTTL
import com.viettelex.keyboard.EmojiRecents
import com.viettelex.keyboard.FieldTraits
import com.viettelex.keyboard.FutoSwipe
import com.viettelex.keyboard.Key
import com.viettelex.keyboard.KeyCommand
import com.viettelex.keyboard.KeyboardData
import com.viettelex.keyboard.KeyboardSession
import com.viettelex.keyboard.KeyboardSettings
import com.viettelex.keyboard.Keys
import com.viettelex.keyboard.MainThread
import com.viettelex.keyboard.SuggestionCase
import com.viettelex.keyboard.SuggestionPlan
import com.viettelex.keyboard.SwipeDecoder
import com.viettelex.keyboard.SwipeEnglish
import com.viettelex.keyboard.SwipeLayout
import com.viettelex.keyboard.SwipePath
import com.viettelex.keyboard.SwipeSuggest
import com.viettelex.keyboard.SyllableLM
import com.viettelex.keyboard.WriteMode
import com.viettelex.keyboard.TemplateItem
import com.viettelex.keyboard.PlusFeature
import com.viettelex.keyboard.PlusGate
import com.viettelex.keyboard.TextTool
import com.viettelex.keyboard.TextToolRunner
import com.viettelex.keyboard.TextTools
import com.viettelex.keyboard.TranslateController
import com.viettelex.keyboard.TranslateJob
import com.viettelex.keyboard.TranslateResult
import com.viettelex.keyboard.TranslateRunner
import com.viettelex.keyboard.TelexKeyPrior
import com.viettelex.keyboard.Templates
import com.viettelex.keyboard.TouchLog
import com.viettelex.keyboard.UserLangModel
import java.io.File
import java.util.BitSet
import java.net.HttpURLConnection
import java.net.URL
import com.viettelex.keyboard.tr
import com.viettelex.keyboard.L10n

/**
 * Bàn phím VietTelex (port iOS KeyboardViewController — phần nối dây; logic nằm ở
 * [KeyboardSession] của module :keyboard). Không Compose, không thư viện ngoài.
 *
 * Luồng: phím (touch-down) → session.handle trong MỘT batch edit → auto-shift ngay
 * lượt main kế → gợi ý sau 30 ms (phím mới huỷ lượt cũ) → phần nặng (VNSuggest +
 * AdjacentKeyFixer) trên HandlerThread "vt-suggest" → kết quả áp nếu còn hiện hành.
 * Không Handler nào được đặt khi không gõ.
 */
class VietTelexIME : InputMethodService(), KeyboardView.Listener, StripView.Listener, ClipboardPane.Listener {

    private val handler = Handler(Looper.getMainLooper())
    private val mainThread = object : MainThread {
        override fun post(r: Runnable) { handler.post(r) }
        override fun postDelayed(delayMs: Long, r: Runnable): Cancellable {
            handler.postDelayed(r, delayMs); return Cancellable { handler.removeCallbacks(r) }
        }
    }
    private lateinit var prefs: SharedPreferences
    private lateinit var model: UserLangModel
    private lateinit var clipboard: AndroidClipboard
    private lateinit var session: KeyboardSession
    private val tracker = SelectionTracker()
    private var portCache: AndroidEditorPort? = null
    private val proxy by lazy { IcProxy({ port() }, tracker) }
    private val swipe by lazy { SwipeDeleteController(proxy) }
    /** Đoạn vừa vuốt ⌫ xoá — ô "Khôi phục" một lượt; phím khác bất kỳ gỡ. */
    private var swipeUndo: String? = null
    /** Công cụ văn bản vừa áp ⇒ ô "↩︎ Hoàn tác" / ⌫ ngay sau (một lượt). */
    private var toolUndo: TextTools.Undo? = null
    /** Dịch trên máy (Plus): controller rẻ; client ML Kit chỉ tạo khi chạm "Dịch", đóng 30 s sau lượt cuối (MlKitBackend). */
    private val translate by lazy {
        TranslateController(com.viettelex.android.translate.TranslateFeature.engineFactory(this) { prefs.getBoolean(Keys.TRANSLATE_AI, false) })
    }
    private var translateUsed = false
    private val clearStatusRun = Runnable { strip?.showStatus(null) }

    /** Test (Robolectric không có InputConnection): ô giả thay ô thật. */
    @androidx.annotation.VisibleForTesting internal var testPort: EditorPort? = null

    /** Wrapper cache theo InputConnection hiện hành (không cấp phát mỗi phím). */
    private fun port(): EditorPort? {
        testPort?.let { return it }
        val ic = currentInputConnection ?: return null
        portCache?.let { if (it.ic === ic) return it }
        return AndroidEditorPort(ic).also { portCache = it }
    }
    private val feedback by lazy { Feedback(this) }
    /** "Âm thanh nét vuốt" — chỉ tạo khi kiểu khác Tắt ([applySwipeSound]). */
    private var swipeSoundPlayer: SwipeSoundPlayer? = null
    private val voice by lazy { VoiceInput(this) }
    private var voiceChecked = false

    private var worker: Handler? = null
    private var workerThread: HandlerThread? = null

    private var root: ImeRootView? = null
    private var keyboard: KeyboardView? = null
    private var strip: StripView? = null
    private var theme: ImeTheme? = null

    private var field = FieldMapping.map(0, 0)
    private var pendingGen = 0

    private val autoShiftRun = Runnable { if (pendingGen == session.generation) applyAutoShift() }
    /**
     * Gợi ý lúc hiện bàn phím (gợi mở đầu / từ đang đứng): 2–12 ms trên emulator (đo 09/11/2026,
     * docs/PERF-IME-SHOW.md) — dời ra SAU khung đầu có phím. Phím gõ trước đó không chờ gì: [handleKey]
     * hạ [firstBarPending] ⇒ lượt hoãn này bỏ qua, lượt gợi ý của chính phím đó lo bar.
     */
    private var firstBarPending = false
    /** Đang trong kb.configure của [startInputView] ⇒ [onPlaneChanged] không auto-shift (làm ở cuối). */
    private var configuringKb = false
    private val firstBarRun = Runnable {
        if (!firstBarPending || !inputShown || pendingGen != session.generation) return@Runnable
        firstBarPending = false
        // Khung đầu dùng initialCapsMode (không có chữ ban đầu tin được): nay đọc chữ thật để xác nhận.
        if (session.autoShiftUnverified) applyAutoShift()
        ImeCost.barRefreshes++
        ImeTrace.begin(ImeTrace.BAR_AFTER_FIRST_FRAME)
        try { refreshBar() } finally { ImeTrace.end() }
    }
    /** Khung kế (callback hoạt ảnh) ⇒ post: chạy sau traversal của chính khung đó (đã vẽ phím). */
    private val firstBarFrame = android.view.Choreographer.FrameCallback {
        handler.post(firstBarRun)
        if (voiceProbePending) { voiceProbePending = false; probeVoice() }
    }

    /** Lần hiện này cần dò lại IME giọng nói (ô mới) — làm sau khung đầu. */
    private var voiceProbePending = false

    /** Dò IME giọng nói trên worker, áp kết quả trên main (giữ lâu "," / menu 😊). */
    private fun probeVoice() {
        ImeCost.voiceProbes++
        val v = voice
        worker().post {
            val t = v.probe()
            handler.post {
                v.apply(t)
                if (inputShown) keyboard?.setVoiceAvailable(v.available && !field.isSecure)
            }
        }
    }

    private fun refreshBarAfterFirstFrame() {
        pendingGen = session.generation
        firstBarPending = true
        handler.removeCallbacks(firstBarRun)
        android.view.Choreographer.getInstance().removeFrameCallback(firstBarFrame)
        android.view.Choreographer.getInstance().postFrameCallback(firstBarFrame)
    }
    private val suggestRun = Runnable {
        if (pendingGen != session.generation) return@Runnable
        ImeTrace.begin(ImeTrace.SUGGEST)
        try { refreshBar() } finally { ImeTrace.end() }
    }
    /**
     * Shift đổi ⇒ vẽ lại bar như Gboard. Trễ bằng [SUGGEST_DELAY_MS] để lượt gợi ý của chính
     * phím vừa gõ (dấu cách ⇒ auto-shift) chạy trước — session thấy bar đã đúng thì bỏ qua.
     */
    private val shiftRun = Runnable {
        syncShift()
        if (session.shiftNeedsRefresh()) refreshBar()
    }

    // --- gõ vuốt ---
    /**
     * Lõi giải mã (KHÔNG thread-safe): mọi truy cập nằm trong synchronized(swipeLock) —
     * prepare() chạy trên worker, setLayout/decode trên main. null khi tính năng tắt (0 RAM).
     */
    private var swipeDecoder: SwipeDecoder? = null
    private val swipeLock = Any()
    private var swipeSetting = false
    /**
     * FUTO Swipe (thử nghiệm, mặc định tắt): null = tắt ⇒ không tải model. Decode/setLayout dưới
     * swipeLock; TẢI weights thì KHÔNG (FutoSwipe tự khoá riêng) ⇒ vuốt lúc đang tải không chặn
     * main — decode thấy model chưa sẵn ⇒ SHARK2.
     */
    @Volatile private var futo: FutoSwipe? = null
    private var futoSetting = false
    private var swipeFieldOk = false
    private var accessibility: AccessibilityManager? = null
    private val touchExplorationListener = AccessibilityManager.TouchExplorationStateChangeListener { updateSwipeTyping() }

    /**
     * Cache setting (prefs.all + parse gõ tắt ≈ vài trăm µs–ms) — trước đây đọc lại 2–3 lần mỗi
     * lần focus ô (onStartInput + onStartInputView + theme). App cài đặt chạy process ":settings"
     * riêng: thay đổi của nó tới qua [PrefSync] (broadcast ⇒ [onPrefChanged]) và lưới an toàn
     * [syncPrefsFromDisk] mỗi lần hiện; thay đổi của chính IME qua [prefListener].
     */
    private var settingsCache: KeyboardSettings? = null
    private fun settings(): KeyboardSettings = settingsCache ?: VTPrefs.settings(prefs).also { settingsCache = it }
    /** Mẫu câu đã nạp (asset YAML / pref JSON) — nạp lười lần đầu cần, xoá khi pref đổi. */
    private var templatesCache: List<TemplateItem>? = null
    /**
     * Nguồn mẫu câu cho bảng ☰ — KeyboardView gọi LƯỜI lúc mở bảng (trước đây đọc + giải YAML và cắt
     * "…" từng mẫu trong onStartInputView dù bảng đóng; lặp lại sau mỗi lần [releaseIdle]).
     */
    private val templatesSource: () -> List<TemplateItem> = {
        if (!settings().templatesEnabled) emptyList()
        else templatesCache ?: run { ImeCost.templateLoads++; VTPrefs.templates(this, prefs) }.also { templatesCache = it }
    }
    /** Pref đổi từ lần so theme trước ⇒ phải dựng lại ImeTheme để so chữ ký. */
    private var themeStale = true
    private var themeUiMode = -1
    /** Ngôn ngữ giao diện lúc dựng input view hiện tại ([L10n]). */
    private var viewLang = L10n.DEFAULT

    private val prefListener = SharedPreferences.OnSharedPreferenceChangeListener { _, key -> onPrefChanged(key) }
    /** Broadcast của process cài đặt ([PrefSync.listen]) — null khi chưa đăng ký. */
    private var prefReceiver: android.content.BroadcastReceiver? = null
    /** Mốc file prefs — đổi mà lỡ broadcast ⇒ đọc lại + bỏ cache lúc hiện bàn phím. */
    private val prefStamp by lazy { val f = PrefSync.file(this); DiskStamp { f.lastModified() to f.length() } }
    /** Mốc "Xóa từ đã học"/sửa từ điển (USERLM_RESET_AT) đã áp cho model trong RAM. */
    private var userLmResetSeen = 0L

    /** Một key prefs đổi (process này hoặc process cài đặt): bỏ cache + áp ngay phần cần áp. */
    private fun onPrefChanged(key: String?) {
        settingsCache = null
        themeStale = true
        if (key == Keys.USER_TEMPLATES || key == Keys.TEMPLATES_ENABLED) templatesCache = null
        // App vừa "Xóa từ đã học": bỏ model trong RAM NGAY (không bao giờ ghi đè lại).
        if (key == Keys.USERLM_RESET_AT) checkUserLmReset()
        // Bật/tắt gõ vuốt trong app khi bàn phím đang mở (ô Thử gõ).
        else if (key == Keys.SWIPE_TYPING) { swipeSetting = settings().swipeTyping; updateSwipeTyping() }
        else if (key == Keys.SWIPE_ENGLISH) session.swipeEnglish = settings().swipeEnglish
        else if (key == Keys.AUTO_CAPITALIZE) session.autoCapitalize = settings().autoCapitalize
        else if (key == Keys.SWIPE_FUTO) { futoSetting = settings().swipeFuto; updateSwipeTyping() }
        else if (key == Keys.SMART_TOUCH) { smartTouchSetting = settings().smartTouch; warmSmartTouch() }
        else if (key == Keys.HARDWARE_TELEX) hwSetting = settings().hardwareTelex
        else if (key == Keys.LONG_PRESS_NUMBERS || key == Keys.LONG_PRESS_SYMBOLS || key == Keys.HOLD_SHIFT_SYMBOLS) updateAlternates()
        // Bật/tắt kiểu gõ trong app khi bàn phím đang mở (ô Thử gõ) → áp ngay, không đợi mở lại.
        else if (key in Keys.ENGINE_KEYS) session.bridge.applySettings(settings())
        // Tắt lịch sử clipboard trong app: bỏ bản RAM (app đã xoá file). Đổi "Giữ lịch sử" ⇒
        // hạn mới cho bản RAM (áp ở lần prune kế tiếp).
        else if (key == Keys.CLIPBOARD_HISTORY || key == Keys.CLIPBOARD_TTL)
            settings().let { syncClipHistory(it.clipboardHistory, it.clipboardTtl) }
        // Bật/tắt thả nổi trong app khi bàn phím đang mở (ô Thử gõ) → áp ngay.
        else if (key == Keys.FLOATING_KEYBOARD && inputShown) applyFloating(settings().floatingKeyboard)
        // Bật/tắt bàn phím tách đôi trong app khi bàn phím đang mở → áp ngay.
        else if (key == Keys.SPLIT_KEYBOARD && inputShown) keyboard?.setSplit(settings().splitKeyboard)
    }

    /**
     * Ghi prefs cài đặt từ IME (thả nổi, một tay, thu gọn bar): đọc lại file trước (process cài
     * đặt có thể vừa ghi) — SharedPreferences ghi CẢ map, map cũ sẽ đè thay đổi của app.
     */
    private fun editPrefs(): SharedPreferences.Editor = PrefSync.reload(this).edit()

    /** Mốc sửa từ điển đổi ⇒ nạp lại model từ file (app đã ghi/xoá); trùng mốc ⇒ không làm gì. */
    private fun checkUserLmReset() {
        val at = prefs.getLong(Keys.USERLM_RESET_AT, 0L)
        if (at == userLmResetSeen) return
        userLmResetSeen = at
        model.reloadAfterExternalErase()
    }

    /**
     * Lưới an toàn đa process: file prefs đổi từ lần hiện trước (process cài đặt ghi lúc IME
     * không nhận được broadcast) ⇒ đọc lại từ đĩa, bỏ mọi cache cài đặt/theme/mẫu câu. 2 stat.
     */
    private fun syncPrefsFromDisk() {
        if (!prefStamp.changed()) return
        PrefSync.reload(this)
        settingsCache = null
        themeStale = true
        templatesCache = null
        checkUserLmReset()
    }

    override fun onCreate() {
        ImeTrace.serviceCreated()
        ImeTrace.begin(ImeTrace.ON_CREATE)
        try { createService() } finally { ImeTrace.end() }
    }

    private fun createService() {
        val t0 = SystemClock.elapsedRealtime()
        if (BuildConfig.DEBUG) {
            perfCreatedAt = t0
            // Bản debug: log mọi đọc/ghi đĩa trên main (logcat "StrictMode") — bắt IO lọt vào đường hiện bàn phím.
            android.os.StrictMode.setThreadPolicy(android.os.StrictMode.ThreadPolicy.Builder()
                .detectDiskReads().detectDiskWrites().penaltyLog().build())
        }
        super.onCreate()
        ImeTrace.begin("VT.onCreate.data")
        // Mở cả ba file prefs trước ⇒ nạp song song trên thread nền ([ImePrefFiles]); file cài đặt mở cuối.
        for (name in ImePrefFiles.PRIME_ORDER) {
            val sp = getSharedPreferences(name, MODE_PRIVATE)
            if (name == ImePrefFiles.STATE) stateStoreCache = sp
        }
        prefs = VTPrefs.of(this)
        // Migration mẫu câu động (một lần mỗi máy) chạy NGAY ở đây: để lười tới lúc nạp mẫu câu thì
        // lần ghi cờ đó đánh dấu theme "cũ" + đổi mốc file ⇒ lần mở bàn phím sau dựng lại ImeTheme
        // thừa (ImeRenderBudgetTest.warmReopenRebuildsNothing).
        VTPrefs.migrateDynamicSnippets(prefs, sync = true)
        com.viettelex.android.plus.PlusPrefs.install(this)   // PlusGate đọc cờ Plus từ prefs chung
        KeyboardData.install(AssetBlobs.provider(assets))
        // Emoji mới hơn mức API chắc có → hỏi font hệ thống (ẩn emoji máy không vẽ được).
        EmojiData.trusted = EmojiData.trustedVersion(Build.VERSION.SDK_INT)
        val glyphPaint = android.graphics.Paint()
        EmojiData.glyphCheck = { e -> synchronized(glyphPaint) { glyphPaint.hasGlyph(e) } }
        DebugLog.configure(this, prefs.getBoolean(Keys.DEBUG_TOUCH_LOG, false))
        ImeTrace.end()
        ImeTrace.begin("VT.onCreate.session")
        model = UserLangModel(File(filesDir, Keys.USERLM_FILE), mainThread)
        clipboard = AndroidClipboard(this)
        session = KeyboardSession(model, clipboard)
        ImeTrace.end()
        ImeTrace.begin("VT.onCreate.state")
        // Tự sửa: từ từng hoàn tác (không sửa lại) — trạng thái bàn phím, không sao lưu.
        session.autoCorrectRejected = AutoCorrect.Rejected.decode(stateStore().getString(Keys.AUTO_CORRECT_REJECTED, null))
        session.onAutoCorrectRejected = {
            stateStore().edit().putString(Keys.AUTO_CORRECT_REJECTED, session.autoCorrectRejected.encode()).apply()
        }
        syncClipHistory(prefs.getBoolean(Keys.CLIPBOARD_HISTORY, false), ClipboardTTL.of(prefs.getString(Keys.CLIPBOARD_TTL, null)))
        clipboard.onChanged = { onClipChanged() }
        // Ô địa chỉ + luật không ra địa chỉ ⇒ Gemini Nano (client tạo lười ở lần gọi đầu).
        session.clipAddressAI = com.viettelex.android.ai.GeminiNanoAddress()
        session.onClipAddressReady = { if (inputShown) refreshBar() }
        // Mời dán một lần mỗi mục clipboard: chỉ lưu id (timestamp ClipDescription), không nội dung.
        session.pasteOnce.reload(stateStore().getLong(Keys.PASTE_OFFERED_ID, Long.MIN_VALUE).takeIf { it != Long.MIN_VALUE })
        session.pasteOnce.persist = { stateStore().edit().putLong(Keys.PASTE_OFFERED_ID, it).apply() }
        model.onReady = { refreshBar() }
        ImeTrace.end()
        ImeTrace.begin("VT.onCreate.listeners")
        prefs.registerOnSharedPreferenceChangeListener(prefListener)
        userLmResetSeen = prefs.getLong(Keys.USERLM_RESET_AT, 0L)
        prefStamp.changed()                                  // ghi nhận mốc ban đầu
        PrefSync.forward(this)                               // thay đổi của IME (thả nổi, một tay…) ⇒ app
        prefReceiver = PrefSync.listen(this) { keys -> keys.forEach { onPrefChanged(it) } }
        accessibility = (getSystemService(Context.ACCESSIBILITY_SERVICE) as? AccessibilityManager)?.also {
            it.addTouchExplorationStateChangeListener(touchExplorationListener)
        }
        BuddyView.prewarm(this, prefs)   // atlas Bạn đồng hành giải nền từ giờ ⇒ khung đầu đã có ảnh
        ImeTrace.end()
        if (BuildConfig.DEBUG) Log.d(TAG, "perf onCreate ${SystemClock.elapsedRealtime() - t0} ms")
    }

    override fun onDestroy() {
        cancelTranslate()                              // đóng client ML Kit nếu đang dịch
        prefs.unregisterOnSharedPreferenceChangeListener(prefListener)
        prefReceiver?.let { PrefSync.unlisten(this, it) }; prefReceiver = null
        accessibility?.removeTouchExplorationStateChangeListener(touchExplorationListener)
        accessibility = null
        clipboard.release()
        clipboard.onChanged = null
        feedback.releaseSound()
        swipeSoundPlayer?.release(); swipeSoundPlayer = null
        handler.removeCallbacksAndMessages(null)   // gợi ý / auto-shift / hẹn giờ ẩn còn chờ
        workerThread?.quitSafely()
        session.finishInput()
        // Vỏ service cũ có thể bị framework giữ lâu sau khi đổi IME (pool RecordingCanvas giữ nav
        // bar của IME → context = service này): thả mọi thứ nặng nó đang trỏ tới (RAM-AUDIT #2).
        model.onReady = null
        model.close()                                 // ghi nốt thay đổi chờ, bỏ bảng RAM
        session.clipHistory = null                    // chỉ bản RAM (file giữ nguyên)
        // (dữ liệu cấp process — từ điển Anh, trie, emoji — để service mới dùng tiếp)
        root?.dropWallpaper()
        clipPane?.listener = null
        keyboard?.listener = null; keyboard?.letterPrior = null
        strip?.listener = null
        // Service (mInputView) + khung mInputFrame vẫn giữ cây view ⇒ thay bằng view rỗng, rồi đo lại
        // khung (FrameLayout giữ con cũ trong mMatchParentChildren tới lần onMeasure kế) để cả cây GC được.
        root?.let { r ->
            val frame = r.parent as? View
            runCatching {
                setInputView(View(this))
                val any = View.MeasureSpec.makeMeasureSpec(0, View.MeasureSpec.UNSPECIFIED)
                frame?.measure(any, any)
            }
        }
        root = null; keyboard = null; strip = null; clipPane = null; theme = null
        portCache = null
        synchronized(swipeLock) { swipeDecoder = null; futo = null }
        super.onDestroy()
    }

    /** iOS không có extract mode — luôn hiện bàn phím thường, kể cả ngang. */
    override fun onEvaluateFullscreenMode() = false

    override fun onCreateInputView(): View {
        ImeTrace.begin(ImeTrace.ON_CREATE_INPUT_VIEW)
        try { return createInputView() } finally { ImeTrace.end() }
    }

    private fun createInputView(): View {
        ImeCost.inputViews++
        val t0 = SystemClock.elapsedRealtime()
        // Ngôn ngữ giao diện TRƯỚC khi dựng view (chữ dựng sẵn): process mới có L10n.lang = mặc định ⇒
        // nếu để onStartInputView mới đọc thì người dùng giao diện tiếng Anh bị dựng cả cây view HAI lần.
        L10n.load { prefs.getString(it, null) }
        val th = freshTheme()
        theme = th
        // Theme vừa dựng từ prefs hiện tại ⇒ onStartInputView ngay sau không cần dựng lại để so chữ ký.
        themeStale = false; themeUiMode = resources.configuration.uiMode
        val balloon = BalloonView(this, th)
        val trail = SwipeTrailView(this, th)
        val kb = KeyboardView(this, th, balloon, feedback, trail)
        val st = StripView(this, th, feedback)
        kb.listener = this
        kb.letterPrior = ::smartTouchPrior
        st.listener = this
        st.onPasteOffer = { session.pasteOfferVisible(it) }
        val r = ImeRootView(this, th, kb, st, balloon, trail)
        keyboard = kb; strip = st; root = r
        viewLang = L10n.lang
        kb.setSwitcherHint(switcherHintVisible)
        styleWindow(th, r)
        if (BuildConfig.DEBUG) Log.d(TAG, "perf onCreateInputView ${SystemClock.elapsedRealtime() - t0} ms")
        return r
    }

    /**
     * "Hiệu ứng khi bấm phím" (Plus): kiểu + cổng Plus + Trình tiết kiệm pin + hiệu ứng động hệ thống —
     * đọc MỘT lần mỗi lần hiện. Không ⇒ gỡ overlay (không còn view nào, 0 chi phí mỗi phím).
     */
    private fun applyKeyEffect(setting: com.viettelex.keyboard.KeyEffect, th: ImeTheme, kb: KeyboardView) {
        val r = root ?: return
        val fx = if (setting == com.viettelex.keyboard.KeyEffect.NONE) setting else com.viettelex.keyboard.KeyEffectPolicy.active(
            setting, com.viettelex.keyboard.KeyEffectGate.allows(setting),
            powerSave = (getSystemService(POWER_SERVICE) as? android.os.PowerManager)?.isPowerSaveMode == true)
        // Theme JSON: hạt ("Theo giao diện") + từ khoá tự tạo của theme đang dùng — theme không có ⇒ null (0 chi phí).
        val themeFx = com.viettelex.keyboard.ThemeFx.make(th.settings.effectiveSpec)?.let {
            com.viettelex.keyboard.ThemeFxPolicy.active(it, com.viettelex.keyboard.KeyEffectGate.allows(com.viettelex.keyboard.KeyEffect.THEME),
                powerSave = (getSystemService(POWER_SERVICE) as? android.os.PowerManager)?.isPowerSaveMode == true)
        }
        session.trackBoundaryWord = fx.needsBoundaryWord || themeFx?.keywords != null || root?.buddy != null
        // Biển: mỗi con sóng mới một tiếng sóng vỗ (chỉ khi Âm thanh phím bật). Mẫu chỉ nạp khi Biển được chọn.
        val sea = fx == com.viettelex.keyboard.KeyEffect.SEA
        val goal = fx == com.viettelex.keyboard.KeyEffect.GOAL
        // Tiếng sự kiện (một mẫu, 2 stream): sóng vỗ (Biển) / hò reo (Sút!). Kiểu khác ⇒ nhả.
        feedback.setEventSound(if (sea) Feedback.EventSound.SURF else if (goal) Feedback.EventSound.CHEER else null)
        // Sút!: bộ so cụm cổ vũ ở ranh giới từ — chỉ khi chọn Sút! (kiểu khác ⇒ null, 0 chi phí).
        session.cheer = if (goal) (session.cheer ?: com.viettelex.keyboard.CheerWords.Matcher()) else null
        if (fx == com.viettelex.keyboard.KeyEffect.NONE && themeFx?.keywords == null) {
            r.effects?.onSeaWave = null
            r.effects?.onThemeEvent = null
            r.effects?.halt()
            r.effects?.shakeTarget = null
            r.effects = null; kb.effects = null
            r.beatFlash = null; kb.onBeat = null
            strip?.onShown = null
            return
        }
        val v = r.effects ?: KeyEffectView(this, th.density)
        v.configure(fx, th.action, th.keyFill, th.dark)
        v.setThemeFx(themeFx)
        // Rung combo: rung HÌNH hàng phím (translation) — Giảm chuyển động vẫn rung (như mọi hiệu ứng).
        v.shakeTarget = if (fx == com.viettelex.keyboard.KeyEffect.SHAKE) kb else null
        // Laser: tia bắn từ phím cách thật (khung đọc lúc bắn — đổi bàn số / ký hiệu vẫn đúng).
        // Công đức: cùng khung phím cách làm chỗ đặt nhãn "Công đức hôm nay" (góc trên-trái phím cách).
        val merit = fx == com.viettelex.keyboard.KeyEffect.MERIT
        v.spaceFrame = if (fx == com.viettelex.keyboard.KeyEffect.LASER || merit) { out -> kb.spaceKeyFrame(out, v) } else null
        // Công đức: bộ đếm trong ngày ở prefs ime_state (chỉ hai số; ghi tối đa mỗi 5 s + lúc ẩn bàn phím).
        if (merit) {
            val st = stateStore()
            v.attachMeritStore(load = {
                if (st.contains(com.viettelex.keyboard.MeritCounter.DAY_KEY))
                    st.getInt(com.viettelex.keyboard.MeritCounter.DAY_KEY, 0) to st.getInt(com.viettelex.keyboard.MeritCounter.COUNT_KEY, 0)
                else null
            }, save = { day, count ->
                st.edit().putInt(com.viettelex.keyboard.MeritCounter.DAY_KEY, day)
                    .putInt(com.viettelex.keyboard.MeritCounter.COUNT_KEY, count).apply()
            })
        }
        // Token AI: đích bay (Mắt AI / tâm dải gợi ý) đọc lúc bắn + vệt sáng khi gợi ý đổi. Kiểu khác ⇒ null (0 chi phí).
        val tokens = fx == com.viettelex.keyboard.KeyEffect.TOKENS
        v.tokenTarget = if (tokens) { out -> r.tokenTarget(out, v) } else null
        v.onSeaWave = if (sea) { size -> feedback.surf(size) } else null
        // Chòm sao: cung người dùng chọn (đọc cùng ThemeSettings lúc dựng — 0 chi phí mỗi phím).
        if (fx == com.viettelex.keyboard.KeyEffect.CONSTELLATION) v.zodiacSign = th.settings.variantChoice.zodiac
        // Cầu vồng: màu theo lá cờ người dùng chọn (theme Tự hào).
        if (fx == com.viettelex.keyboard.KeyEffect.RAINBOWBURST) v.prideFlag = th.settings.variantChoice.pride
        v.onThemeEvent = if (goal) ({ feedback.cheer(); Unit }) else null
        // Cho cá ăn: bộ đếm thức ăn theo máy (ime_state) — kiểu khác ⇒ null.
        v.fishPrefs = if (fx == com.viettelex.keyboard.KeyEffect.FISHFEED) stateStore() else null
        strip?.onShown = if (tokens) { set ->
            r.suggestionRect(tokenRect, v)
            val words = ArrayList<String>(8)
            set.word?.let { words.add(it) }; set.word2?.let { words.add(it) }
            words.addAll(set.moreWords); words.addAll(set.nextWords); words.addAll(set.emojis)
            v.suggestionsChanged(words, tokenRect[0], tokenRect[1], tokenRect[2], tokenRect[3])
        } else null
        r.effects = v          // dải dưới / trên phím theo kiểu vừa cấu hình
        kb.effects = v
        // Sàn nhảy LED: flash nền ở phím cách (dưới phím); cổng ≤ 3 lần / giây dùng chung với nháy cả bàn phím.
        if (fx == com.viettelex.keyboard.KeyEffect.DANCEFLOOR) {
            val f = r.beatFlash ?: BeatFlashView(this)
            r.beatFlash = f
            kb.onBeat = { f.kick() }
            v.flashGate = f.gate
        } else {
            r.beatFlash = null; kb.onBeat = null; v.flashGate = null
        }
        r.refreshStringGaps()  // Rung dây: khe hàng cho overlay (đã layout thì đặt ngay)
    }

    private val tokenRect = FloatArray(4)

    /**
     * "Âm thanh nét vuốt": kiểu + cổng Plus + Trình tiết kiệm pin + âm lượng Âm thanh phím — đọc MỘT lần mỗi lần hiện.
     * Tắt / âm lượng 0 / gõ vuốt tắt ⇒ nhả SoundPool, KeyboardView không giữ gì (đường vuốt chỉ đọc một biến null).
     */
    private fun applySwipeSound(settings: KeyboardSettings, kb: KeyboardView) {
        val setting = if (settings.swipeTyping) settings.swipeSound else com.viettelex.keyboard.SwipeSoundStyle.NONE
        val powerSave = setting.isPlus &&
            (getSystemService(POWER_SERVICE) as? android.os.PowerManager)?.isPowerSaveMode == true
        val style = com.viettelex.keyboard.SwipeSoundPolicy.active(setting,
            com.viettelex.keyboard.SwipeSoundGate.allows(setting), powerSave, settings.keySoundVolume)
        if (style == com.viettelex.keyboard.SwipeSoundStyle.NONE) {
            swipeSoundPlayer?.release(); swipeSoundPlayer = null
            kb.swipeSound = null
            return
        }
        val p = swipeSoundPlayer ?: SwipeSoundPlayer(this).also { swipeSoundPlayer = it }
        // Nốt nhạc theo phím: nhạc cụ của Âm thanh phím (Piano / Đàn tranh / Ghi-ta), kiểu khác ⇒ Đàn tranh.
        val instrument = com.viettelex.keyboard.KeyInstrument.of(settings.keySoundStyle) ?: com.viettelex.keyboard.KeyInstrument.DANTRANH
        p.configure(style, settings.keySoundVolume, instrument) { worker().post(it) }
        kb.swipeSound = p
    }

    /**
     * "Hiệu ứng nét vuốt": kiểu + cổng Plus + Trình tiết kiệm pin; "Theo giao diện" ⇒ "swipe" của theme đang dùng —
     * đọc MỘT lần mỗi lần hiện. Tắt ⇒ KeyboardView không giữ vệt (không add/vẽ gì), view ẩn.
     */
    private fun applySwipeTrail(setting: com.viettelex.keyboard.SwipeTrailStyle, th: ImeTheme, kb: KeyboardView) {
        val r = root ?: return
        val style = if (!setting.isPlus) setting else com.viettelex.keyboard.SwipeTrailPolicy.active(
            setting, com.viettelex.keyboard.SwipeTrailGate.allows(setting),
            themeSwipe = if (setting == com.viettelex.keyboard.SwipeTrailStyle.THEME) th.settings.effectiveKeyStyle.swipe else null,
            powerSave = (getSystemService(POWER_SERVICE) as? android.os.PowerManager)?.isPowerSaveMode == true)
        if (style == com.viettelex.keyboard.SwipeTrailStyle.NONE) {
            r.trail.clear()
            r.trail.visibility = View.GONE
            kb.trail = null
            return
        }
        r.trail.configure(style)
        r.trail.visibility = View.VISIBLE
        kb.trail = r.trail
    }

    /**
     * "Bạn đồng hành" (Plus): nhân vật + cổng Plus + Trình tiết kiệm pin + mùa lễ (theme lễ / ngày) — đọc MỘT lần
     * mỗi lần hiện. Tắt ⇒ gỡ view, strip không chừa ô (0 chi phí mỗi phím).
     */
    private fun applyBuddy(setting: com.viettelex.keyboard.BuddyCharacter, style: com.viettelex.keyboard.BuddyStyle,
                           placement: com.viettelex.keyboard.BuddyPlacement, th: ImeTheme, st: StripView) {
        val r = root ?: return
        val c = com.viettelex.keyboard.BuddyPolicy.active(setting, com.viettelex.keyboard.BuddyGate.allows(setting))
        if (c == com.viettelex.keyboard.BuddyCharacter.OFF) {
            r.buddy = null; r.aiEye = null; st.buddyDp = 0f; keyboard?.eyeLook = null
            BuddyView.SpriteAssets.drop()   // tắt ⇒ không giữ atlas cấp process
            session.trackBoundaryWord = r.effects?.wantsBoundaryWord == true
            return
        }
        val low = (getSystemService(POWER_SERVICE) as? android.os.PowerManager)?.isPowerSaveMode == true
        // Mắt AI: view riêng (không khung hình / điệu nhảy, không tra từ) — cùng ô + "Vị trí & cỡ".
        if (c == com.viettelex.keyboard.BuddyCharacter.AI) {
            r.buddy = null; BuddyView.SpriteAssets.drop()
            val e = r.aiEye ?: AIEyeView(this, th.density, low)
            e.lowPower = low
            r.aiEye = e
            keyboard?.eyeLook = { x, y -> e.keyPressed(x, y) }
            r.buddyPlacement = placement
            st.buddyDp = placement.zoneWidth(StripGeometry.BUDDY_W.toDouble()).toFloat()
            session.trackBoundaryWord = r.effects?.wantsBoundaryWord == true
            return
        }
        r.aiEye = null; keyboard?.eyeLook = null
        val cal = java.util.Calendar.getInstance()
        val season = com.viettelex.keyboard.BuddySeason.resolve(th.settings.effectiveTheme.id,
            cal.get(java.util.Calendar.YEAR), cal.get(java.util.Calendar.MONTH) + 1, cal.get(java.util.Calendar.DAY_OF_MONTH))
        val old = r.buddy
        // Kiểu vẽ riêng nhân vật (Hoạt hình mặc định / Vẽ nét) — đổi ⇒ dựng view mới, chỉ nạp tài nguyên kiểu đó.
        val stamp = cal.get(java.util.Calendar.YEAR) * 10000 + (cal.get(java.util.Calendar.MONTH) + 1) * 100 + cal.get(java.util.Calendar.DAY_OF_MONTH)
        val part = com.viettelex.keyboard.BuddyClock.part(cal.get(java.util.Calendar.HOUR_OF_DAY), cal.get(java.util.Calendar.MINUTE))
        if (old != null && old.character == c && old.season == season && old.artStyle == style && old.appearanceDay == stamp &&
            (style != com.viettelex.keyboard.BuddyStyle.VECTOR || season != null || old.outfitClockPart == part)) {
            old.lowPower = low; old.setBar(com.viettelex.keyboard.BuddyHalo.opaque(th.bg, th.dark))
        } else {
            r.buddy = BuddyView(this, c, th.density, com.viettelex.keyboard.BuddyHalo.opaque(th.bg, th.dark), low, season,
                artStyle = style).apply { onTimeChanged = { this@VietTelexIME.applyBuddy(setting, style, placement, th, st) } }
            if (r.buddy?.wantsAtlas != true) BuddyView.SpriteAssets.drop()   // Vẽ nét ⇒ không cần atlas
        }
        r.buddyPlacement = placement
        st.buddyDp = placement.zoneWidth(StripGeometry.BUDDY_W.toDouble()).toFloat()
        session.trackBoundaryWord = true
    }

    /** Bạn đồng hành: phản ứng theo từ vừa chốt (tra O(1), chỉ ở ranh giới). */
    private fun buddyBoundary() {
        val b = root?.buddy ?: return
        val w = session.boundaryWord ?: return
        b.wordCommitted(w, session.boundaryPrev, session.boundaryPrev2)
    }

    /**
     * Đập chuột (theme có "game":"mole" — [com.viettelex.keyboard.MoleGame]): theme + Plus + không tiết kiệm pin + không
     * TalkBack — đọc MỘT lần mỗi lần hiện. Không ⇒ gỡ view (0 chi phí mỗi phím), không nạp mẫu "éc".
     */
    private fun applyMole(th: ImeTheme, kb: KeyboardView) {
        val r = root ?: return
        // Pin chỉ đọc khi theme thật sự có trò chơi (và tối đa một lần mỗi lần hiện — [powerSaveShow]).
        val on = th.keyStyle.game == com.viettelex.keyboard.MoleGame.THEME_GAME &&
            com.viettelex.keyboard.MolePolicy.active(th.keyStyle.game,
            PlusGate.isUnlocked(PlusFeature.PREMIUM_THEMES),
            powerSave = powerSaveShow.get(),
            talkBack = accessibility?.isTouchExplorationEnabled == true)
        feedback.setSqueakEnabled(on)
        if (!on) { r.mole = null; kb.mole = null; return }
        val v = r.mole ?: MoleView(this, th.density)
        v.keyFrame = { c, out -> kb.moleKeyFrame(c, out, v) }
        v.context = {
            val set = strip?.shownSet
            session.bridge.composedWord to (listOfNotNull(set?.word, set?.word2) + (set?.nextWords ?: emptyList()))
        }
        if (r.mole == null) moleStats = MoleStatsFile.read(this)
        v.onHit = { streak ->
            feedback.squeak()
            val st = moleStats.record(1, streak, com.viettelex.keyboard.MoleStats.dayNumber())
            moleStats = st
            worker().post { MoleStatsFile.write(this, st) }
            st.today
        }
        r.mole = v
        kb.mole = v
    }

    /**
     * Đèn rọi (theme có "photoFx":"spotlight" — [com.viettelex.keyboard.SpotlightPolicy]): theme + Plus + không tiết kiệm
     * pin — đọc MỘT lần mỗi lần hiện. Không ⇒ gỡ view (0 chi phí mỗi phím).
     */
    private fun applySpotlight(th: ImeTheme, kb: KeyboardView, buddy: com.viettelex.keyboard.BuddyCharacter) {
        val r = root ?: return
        val on = th.keyStyle.photoFx == com.viettelex.keyboard.ThemeExtraIds.SPOTLIGHT &&
            com.viettelex.keyboard.SpotlightPolicy.active(th.keyStyle.photoFx,
            PlusGate.isUnlocked(PlusFeature.PREMIUM_THEMES), lowPower = powerSaveShow.get())
        if (!on) { r.spotlight = null; kb.spotlight = null; return }
        val v = r.spotlight ?: SpotlightView(this, th.density)
        v.dancer = com.viettelex.keyboard.NightDancer.character(buddy)   // người nhảy: chàng trai nếu đang chọn, không thì cô gái
        r.spotlight = v
        kb.spotlight = v
    }

    /**
     * "Lơ lửng" ([com.viettelex.keyboard.FloatPolicy]): hiệu ứng "float" HOẶC theme "keyMotion":"float" + Plus + không tiết
     * kiệm pin — đọc MỘT lần mỗi lần hiện. Giảm chuyển động / tỉ lệ hoạt ảnh 0 KHÔNG tắt (Phil 11/2026: mọi hiệu ứng vẫn
     * chạy; [KeyFloatDriver] theo đồng hồ thật, không qua ValueAnimator). Không ⇒ null (0 chi phí).
     */
    private fun applyKeyFloat(setting: com.viettelex.keyboard.KeyEffect, th: ImeTheme, kb: KeyboardView) {
        // Pin chỉ quyết định khi có yêu cầu "lơ lửng" (hiệu ứng hoặc theme); không ⇒ không đọc.
        val wants = setting == com.viettelex.keyboard.KeyEffect.FLOAT ||
            th.keyStyle.keyMotion == com.viettelex.keyboard.ThemeExtraIds.FLOAT_MOTION
        val powerSave = wants && powerSaveShow.get()
        val fx = com.viettelex.keyboard.KeyEffectPolicy.active(setting, com.viettelex.keyboard.KeyEffectGate.allows(setting), powerSave)
        val on = com.viettelex.keyboard.FloatPolicy.active(fx, th.keyStyle.keyMotion,
            plus = PlusGate.isUnlocked(PlusFeature.PREMIUM_THEMES), lowPower = powerSave)
        kb.keyFloat = if (on) kb.keyFloat ?: KeyFloatDriver() else null
    }

    /**
     * Trình tiết kiệm pin cho Đập chuột / Đèn rọi / Lơ lửng: MỘT binder mỗi lần hiện, chỉ khi theme / hiệu
     * ứng cần (trước đây 3 lần đọc mỗi lần hiện kể cả khi không tính năng nào bật).
     */
    @androidx.annotation.VisibleForTesting internal val powerSaveShow =
        PerShowFlag { (getSystemService(POWER_SERVICE) as? android.os.PowerManager)?.isPowerSaveMode == true }

    /** Thống kê Đập chuột trong RAM (đọc file lúc gắn view, ghi file trên worker mỗi lần đập). */
    private var moleStats = com.viettelex.keyboard.MoleStats()

    /** "Emoji theo chữ" / "Từ khoá": phím ranh giới vừa chốt từ ⇒ tra bảng O(1) (chỉ khi chọn kiểu đó). */
    private fun fxBoundaryEmoji() {
        buddyBoundary()
        val fx = root?.effects ?: return
        // Từ khoá tự tạo của theme ([com.viettelex.keyboard.ThemeFx]): nổ THÊM, cùng mọi hiệu ứng. Không có ⇒ null, không tra.
        fx.themeFx?.keywords?.let { table ->
            session.boundaryWord?.let { w -> table.lookup(w, session.boundaryPrev)?.let { fx.queueThemeKeyword(it) } }
        }
        when (fx.effect) {
            com.viettelex.keyboard.KeyEffect.EMOJIWORD -> {
                val w = session.boundaryWord ?: return
                com.viettelex.keyboard.EmojiWords.lookup(w, session.boundaryPrev)?.let { fx.queueEmoji(it) }
            }
            com.viettelex.keyboard.KeyEffect.KEYWORD -> {
                val w = session.boundaryWord ?: return
                if (!swipeCombo.boundary(w)) return   // từ vuốt đã nổ lúc vuốt: không nổ lần hai
                com.viettelex.keyboard.KeywordBursts.lookup(w, session.boundaryPrev)?.let { fx.queueKeyword(it) }
            }
            com.viettelex.keyboard.KeyEffect.REPS -> {   // Rep (Gym): "gym", "tập", "beast mode"… ⇒ BEAST MODE
                val w = session.boundaryWord ?: return
                if (com.viettelex.keyboard.RepsFx.isKeyword(w, session.boundaryPrev, session.boundaryPrev2)) fx.queueBeastMode()
            }
            // Tự hào: "love is love", "tự hào", "pride", "yêu là yêu" ⇒ cờ phấp phới + tim.
            com.viettelex.keyboard.KeyEffect.RAINBOWBURST -> {
                val w = session.boundaryWord ?: return
                if (com.viettelex.keyboard.PrideKeywords.matches(w, session.boundaryPrev, session.boundaryPrev2)) fx.queuePride()
            }
            else -> {}
        }
    }

    /**
     * "Từ khoá" cho từ vuốt: từ vừa vuốt (đang mở) khớp bảng ⇒ chùm nổ ngay ở chỗ nhấc tay; phím ranh giới chốt đúng từ
     * đó sau thì không nổ lại ([com.viettelex.keyboard.SwipeKeywordCombo]). Kiểu khác ⇒ một phép so sánh. = iOS.
     */
    private val swipeCombo = com.viettelex.keyboard.SwipeKeywordCombo()

    private fun fxSwipeKeyword(path: SwipePath) {
        val fx = root?.effects ?: return
        if (fx.effect != com.viettelex.keyboard.KeyEffect.KEYWORD) return
        val w = session.openSwipe ?: return
        val k = swipeCombo.swiped(w, session.lastCommitted) ?: return
        fx.queueKeyword(k)
        keyboard?.burstAtSwipeLift(path)
    }

    /**
     * "Dấu thanh" / "Chữ bay": so từ đang soạn trước/sau phím (dấu vừa bỏ / đúng chữ vừa ra). Kiểu khác ⇒ [composeBefore]
     * trả null, không đọc gì (0 chi phí).
     */
    private fun composeBefore(key: Key): String? {
        val fx = root?.effects ?: return null
        if (!fx.effect.needsComposeDiff) return null
        if (key !is Key.Letter && key !is Key.Text) return null
        return session.bridge.composedWord
    }

    private fun fxComposeDiff(key: Key, before: String) {
        val fx = root?.effects ?: return
        val after = session.bridge.composedWord
        when (fx.effect) {
            com.viettelex.keyboard.KeyEffect.TONE ->
                com.viettelex.keyboard.ToneMarks.detect(before, after)?.let { fx.queueTone(it) }
            com.viettelex.keyboard.KeyEffect.LETTERS -> {
                val typed = when (key) { is Key.Letter -> key.ch.toString(); is Key.Text -> key.text; else -> null }
                com.viettelex.keyboard.FlyingLetters.glyph(before, after, typed)?.let { fx.queueLetter(it) }
            }
            com.viettelex.keyboard.KeyEffect.TOKENS -> {
                val typed = when (key) { is Key.Letter -> key.ch.toString(); is Key.Text -> key.text; else -> null }
                com.viettelex.keyboard.FlyingLetters.glyph(before, after, typed)?.let { fx.queueToken(it) }
            }
            else -> {}
        }
    }

    /** Theme từ cài đặt hiện tại (rẻ: vài lần đọc màu resource, không giải ảnh). */
    private fun freshTheme(): ImeTheme {
        ImeCost.themes++
        val all = prefs.all
        return ImeTheme(this, ThemeSettings.load { all[it] }, File(filesDir, Keys.WALLPAPER_FILE).exists())
    }

    @Suppress("DEPRECATION")
    private fun styleWindow(th: ImeTheme, v: View) {
        val w = window?.window ?: return
        // Thả nổi: dải nav bar trong suốt (app bên dưới lộ ra, khung không dính đáy).
        if (Build.VERSION.SDK_INT < 35) w.navigationBarColor = if (floatingNow) android.graphics.Color.TRANSPARENT else th.bg
        if (Build.VERSION.SDK_INT >= 29) w.isNavigationBarContrastEnforced = false
        WindowInsetsControllerCompat(w, v).isAppearanceLightNavigationBars = !th.dark
    }

    override fun onStartInputView(info: EditorInfo, restarting: Boolean) {
        ImeTrace.showStarted()
        ImeTrace.begin(ImeTrace.ON_START_INPUT_VIEW)
        try { startInputView(info, restarting) } finally { ImeTrace.end() }
    }

    private fun startInputView(info: EditorInfo, restarting: Boolean) {
        val t0 = SystemClock.elapsedRealtime()
        ImeTrace.begin("VT.startInput.prefs")
        super.onStartInputView(info, restarting)
        handler.removeCallbacks(idleRelease)
        syncPrefsFromDisk()
        ImeTrace.end()
        // Đổi theme/ảnh nền trong app → dựng lại input view (màu/Paint tạo sẵn trong view).
        // Chỉ dựng ImeTheme để so khi pref đổi hoặc sáng/tối hệ thống đổi (không mỗi lần focus ô).
        val uiMode = resources.configuration.uiMode
        // Ngôn ngữ giao diện (Tính Năng → Ngôn ngữ): đọc MỘT lần mỗi lần hiện bàn phím; view đang
        // giữ chữ dựng sẵn (Dán, Khôi phục, …) ⇒ đổi ngôn ngữ thì dựng lại view. 0 chi phí mỗi phím.
        L10n.load { prefs.getString(it, null) }
        // Theo giờ: giờ đã sang mục lịch khác (bình minh → ngày …) ⇒ dựng lại; theme không lịch không đọc đồng hồ.
        if (theme != null && (viewLang != L10n.lang ||
                ((themeStale || uiMode != themeUiMode || theme?.scheduleChanged() == true) &&
                    freshTheme().signature != theme?.signature)))
            setInputView(onCreateInputView())
        themeStale = false; themeUiMode = uiMode
        rewarmAfterIdle()
        val kb = keyboard ?: return
        val st = strip ?: return
        val th = theme ?: return
        val settings = settings()
        DebugLog.configure(this, settings.debugTouchLog)
        // Đã gõ phím cứng trên ô này (onStartInput đã dựng ô, tracker/engine đang sống):
        // KHÔNG dựng lại từ EditorInfo cũ (initialSel đã lỗi thời) — chỉ lo phần giao diện.
        if (!hwTyped) {
            ImeTrace.begin("VT.startInput.field")
            try { configureField(info, settings) } finally { ImeTrace.end() }
        }
        kb.holdNewline = field.holdNewline   // giữ lâu Enter = xuống dòng (ô nhiều dòng)
        feedback.hapticsEnabled = settings.hapticFeedback
        feedback.hapticStrength = settings.hapticStrength
        // Âm thanh phím riêng: TẮT ⇒ nhả/không dựng gì (tiếng hệ thống như cũ).
        feedback.configureSound(settings.keySound, settings.keySoundVolume, settings.keySoundStyle) { worker().post(it) }
        if (session.warmEnglishOnShow && !SwipeEnglish.isLoaded) worker().post { SwipeEnglish.warm() }   // Tự sửa: main chỉ tra không nạp
        kb.searchSettings = settings
        syncClipHistory(settings.clipboardHistory, settings.clipboardTtl)
        // Quyền đọc clipboard theo focus: ClipDescription nhớ theo mục clip, đọc lại một lần mỗi lần hiện.
        clipboard.invalidateFacts()
        // Copy lúc process IME chưa sống (listener không thấy) → bù khi hiện, không làm mới mục cũ.
        if (session.recordClip(field.isSecure, onlyIfNew = true)) saveClipHistory()
        closeClipboardPane()
        swipeSetting = settings.swipeTyping
        futoSetting = settings.swipeFuto
        // Chỉ ô chữ ghi COMMIT thường: không secure/passthrough (URI, email, mật khẩu hiện,
        // filter), không TYPE_NULL, không ô URL, không app phải ghi bằng key event.
        swipeFieldOk = !field.isSecure && !field.passthrough && !field.rawKeys && !proxy.uriField &&
            proxy.writeMode == WriteMode.COMMIT
        // Chọn phím theo ngữ cảnh: chỉ ô chữ thường (email/URL/mật khẩu gõ literal ⇒ router cũ).
        smartTouchSetting = settings.smartTouch
        smartTouchFieldOk = !field.isSecure && !field.passthrough && !proxy.uriField
        warmSmartTouch()

        inputShown = true
        // Debug mode: hiện/ẩn trong CHÍNH app cài đặt (báo lỗi 13/11/2026 "bàn phím hay bị ẩn, chỉ trong
        // app cài đặt") — phân biệt app đóng bàn phím (hide ngay sau show) với bàn phím không được gọi.
        if (TouchLog.enabled && info.packageName == packageName) TouchLog.write("settingsApp show restarting=$restarting")
        // Nút ⌄ thu gọn đã bỏ (10/2026): bar luôn mở; khoá "suggestionBarCollapsed" cũ không còn đọc.
        session.barCollapsed = false
        // Ô cấm gợi ý chữ nhưng không nhạy cảm (StripMode.TOOLS): vẫn ☰/con trỏ/📋 + Dán (#113).
        val barOn = session.stripMode.shown
        // "Nút emoji" = Thanh trên: chỉ khi strip CÓ vẽ (barOn) — không thì 😊 ở lại hàng đáy.
        // TalkBack: strip không đọc được (importantForAccessibility NO) ⇒ giữ phím 😊 cho người dùng trợ năng.
        val emojiInStrip = com.viettelex.keyboard.EmojiKeyPlacement.inStrip(settings.emojiKeyPlacement,
            barOn && accessibility?.isTouchExplorationEnabled != true)
        st.configure(barOn, settings.templatesEnabled,
            reserved = KeyLayout.stripReserved(settings.showSuggestions), emojiButton = emojiInStrip,
            slotSetting = settings.suggestionCount,
            // "Chiều cao thanh gợi ý" — điện thoại ngang kẹp ở Vừa (màn thấp).
            barHeight = settings.suggestionBarHeight, landscapeCap = th.landscape && !th.tablet,
            suggestionInk = settings.suggestionInk,
            // "Nút ẩn bàn phím" (mặc định tắt): ⌄ góc phải dải → onDismissKeyboard (requestHideSelf).
            dismissButton = settings.keyboardDismissButton)
        applyFloating(settings.floatingKeyboard, settings)
        kb.setEditHasSelection(info.initialSelStart >= 0 && info.initialSelStart != info.initialSelEnd)
        st.setExtras(clipButton = settings.clipboardHistory, open = false)
        ImeTrace.begin("VT.startInput.kbConfigure")
        configuringKb = true
        try { kb.configure(field.returnLabel, field.kind, needsGlobe(), settings.showSpaceLogo,
            settings.templatesEnabled, templatesSource,
            th.dp(KeyLayout.keyAreaDp(th.tablet, th.landscape, settings.rowHeightAdjust, settings.numberRow,
                settings.numberRowFullHeight, resources.configuration.screenHeightDp.toFloat())),
            field.numberSigned, field.numberDecimal, settings.numberRow, settings.numberRowFullHeight,
            settings.spaceSideKey, emojiInStrip, settings.keyLabelSize, settings.splitKeyboard, settings.largeKeys)
        } finally { configuringKb = false }
        ImeTrace.end()
        ImeTrace.begin("VT.startInput.extras")
        powerSaveShow.reset()   // Trình tiết kiệm pin: đọc lại tối đa một lần cho lần hiện này
        kb.keyPreview = settings.keyPreview
        kb.keyPressHighlight = settings.keyPressHighlight
        applyKeyEffect(settings.keyEffect, th, kb)
        applyBuddy(settings.buddy, settings.buddyStyle, settings.buddyPlacement, th, st)
        applySwipeTrail(settings.swipeTrail, th, kb)
        applySwipeSound(settings, kb)
        applyMole(th, kb)
        applySpotlight(th, kb, settings.buddy)
        applyKeyFloat(settings.keyEffect, th, kb)
        kb.configureSpaceFlick(settings.spaceSwipeLanguage, session.language)
        kb.trackpadSpeed = settings.trackpadSpeed
        kb.symbolReturn = settings.symbolReturn
        if (session.language == com.viettelex.keyboard.KeyboardLanguage.EN) warmEnglish()
        // Plus + công tắc "Công cụ văn bản" (mặc định bật) + không phải ô mật khẩu.
        kb.textToolsEnabled = settings.textToolsActive(PlusGate.isUnlocked(PlusFeature.TEXT_TOOLS), field.isSecure)
        // Dịch nằm trong Công cụ ⇒ tắt Công cụ là tắt luôn Dịch.
        kb.translateEnabled = kb.textToolsEnabled && PlusGate.isUnlocked(PlusFeature.TRANSLATE)
        st.toolsEnabled = kb.textToolsEnabled || kb.translateEnabled   // ☰ khi Mẫu câu tắt
        st.setPlane(kb.plane)
        // Giữ lâu "," = gõ giọng nói: chỉ khi máy có IME giọng nói (đọc lại khi vào ô mới —
        // user có thể bật/tắt trong Cài đặt), không ở ô mật khẩu.
        // Dò IME giọng nói = 1 + N binder (enabledInputMethodList + subtype từng IME): KHÔNG trước khung đầu —
        // khung đầu dùng kết quả lần trước, dò lại trên worker sau khung đầu ([firstBarFrame] → [probeVoice]).
        if (!restarting || !voiceChecked) { voiceProbePending = true; voiceChecked = true }
        kb.setVoiceAvailable(voice.available && !field.isSecure)
        updateSwipeTyping()
        ImeTrace.end()
        root?.refreshInsets()
        root?.requestLayout()

        session.invalidatePasteCache()
        if (!restarting) session.pasteOnce.ended()   // ô mới: lời mời dán đang hiện coi như bỏ qua
        // Không đọc ô trước khung đầu (getTextBeforeCursor chặn trên UI thread của app — lúc app đang mở
        // activity thì chờ lâu): chữ ban đầu hệ thống gửi kèm (API 30+, đã đối chiếu initialSel) hoặc
        // initialCapsMode; trường hợp sau được xác nhận bằng chữ thật ngay sau khung đầu ([firstBarRun]).
        applyAutoShift(allowRead = false)
        refreshBarAfterFirstFrame()   // ô trống → gợi mở đầu, ngay SAU khung có phím
        if (BuildConfig.DEBUG) {
            Log.d(TAG, "perf onStartInputView ${SystemClock.elapsedRealtime() - t0} ms")
            logFirstFrame(t0)   // sau setInputView (nếu dựng lại) ⇒ gắn đúng cây view sẽ vẽ
        }
    }

    /** Ô nhập → FieldMapping, IcProxy, tracker, session. Gọi ở onStartInputView (và onStartInput khi có phím cứng). */
    private fun configureField(info: EditorInfo, settings: KeyboardSettings) {
        field = FieldMapping.map(info.inputType, info.imeOptions, info.packageName,
            hasActionLabel = info.actionLabel != null, customActionId = info.actionId)
        proxy.secure = field.isSecure
        proxy.rawKeys = field.rawKeys
        proxy.multiLine = field.multiLine
        proxy.writeMode = com.viettelex.keyboard.WriteMode.forPackage(info.packageName)
        proxy.actionId = field.actionId
        proxy.uriField = (info.inputType and InputType.TYPE_MASK_CLASS) == InputType.TYPE_CLASS_TEXT &&
            (info.inputType and InputType.TYPE_MASK_VARIATION) == InputType.TYPE_TEXT_VARIATION_URI
        startTracking(info)
        handler.removeCallbacks(autoShiftRun); handler.removeCallbacks(suggestRun); handler.removeCallbacks(shiftRun)
        clearSwipeUndo()

        session.startInput(settings, FieldTraits(
            isSecure = field.isSecure, passthrough = field.passthrough,
            capSentences = field.capSentences, suggestionsAllowed = field.suggestionsAllowed,
            capWords = field.capWords, capCharacters = field.capCharacters,
            initialCaps = info.initialCapsMode != 0, noLearning = field.noLearning,
            packageName = info.packageName, urlField = proxy.uriField,
            emailField = field.kind == InputKind.EMAIL, stripTools = field.stripTools,
            lowercaseSuggestions = field.lowercaseSuggestions, appNoSuggestions = field.appNoSuggestions,
            emailCompose = field.emailCompose,
            numericPad = field.kind == InputKind.PHONE || field.kind == InputKind.NUMBER || field.kind == InputKind.DATETIME,
            clipPreference = FieldMapping.clipPreference(info.inputType, info.hintText)))
        // Bảng gõ tắt đổi ⇒ từ vựng vuốt mới: dựng lại template ở nền (cú vuốt kế khỏi chờ).
        if (session.takeSwipeVocabChanged()) swipeDecoder?.let { dec ->
            if (dec.layout != null) worker().post { synchronized(swipeLock) { if (swipeDecoder === dec) dec.prepare() } }
        }
        // Ngôn ngữ (vuốt phím cách) lưu riêng: ghi không đụng prefs cài đặt (listener/theme).
        // Hồ sơ vừa chọn trong app (ONBOARDING-SPEC §3, "Chủ yếu tiếng Anh") ⇒ đặt ngôn ngữ khởi đầu
        // MỘT lần; sau đó vuốt phím cách đổi như thường.
        prefs.getString(com.viettelex.keyboard.KeyboardLanguageRequest.KEY, null)?.let { req ->
            val st = stateStore()
            com.viettelex.keyboard.KeyboardLanguageRequest.pending(req,
                st.getString(com.viettelex.keyboard.KeyboardLanguageRequest.APPLIED_KEY, null))?.let { lang ->
                st.edit().putString(Keys.KEYBOARD_LANGUAGE, lang.id)
                    .putString(com.viettelex.keyboard.KeyboardLanguageRequest.APPLIED_KEY, req).apply()
            }
        }
        session.restoreLanguage(stateStore().getString(Keys.KEYBOARD_LANGUAGE, null), proxy)
        hwSetting = settings.hardwareTelex
        fieldReady = true
    }

    /**
     * initialSel không tin tuyệt đối: đối chiếu độ dài getInitialTextBeforeCursor (API 30+);
     * lệch ⇒ con trỏ không biết. Khớp ⇒ nạp luôn shadow (khỏi IPC lượt đầu).
     */
    private fun startTracking(info: EditorInfo) {
        val before = if (Build.VERSION.SDK_INT >= 30 && !field.isSecure)
            info.getInitialTextBeforeCursor(IcProxy.CONTEXT_CAP, 0) else null
        val s = info.initialSelStart; val e = info.initialSelEnd
        val ok = InitialSelection.trusted(s, e, before?.length, IcProxy.CONTEXT_CAP)
        if (ok) tracker.reset(s, e) else tracker.reset(-1, -1)
        if (!ok && s >= 0 && TouchLog.enabled) TouchLog.write("initialSel $s..$e lệch initialTextBefore len=${before?.length}")
        proxy.startInput(if (ok) before else null,
            ok && before != null && InitialSelection.reachesFieldStart(s, e, before.length))
    }

    override fun onWindowShown() {
        super.onWindowShown()
        root?.refreshInsets()           // Android 15+: chừa dải cho nút ⌄/🌐 của hệ thống
        keyboard?.showLanguageBadge()   // "ViệtTelex" thoáng trên space như stock
        keyboard?.setNeedsGlobe(needsGlobe())
        if (BuildConfig.DEBUG) logMemory()
    }

    override fun onFinishInputView(finishingInput: Boolean) {
        super.onFinishInputView(finishingInput)
        if (TouchLog.enabled && currentInputEditorInfo?.packageName == packageName)
            TouchLog.write("settingsApp hide finishingInput=$finishingInput")
        cancelTranslate()
        swipeFieldOk = false
        // FUTO Swipe / từ điển Anh / ảnh nền / emoji: GIỮ qua các lần hiện (giải lại mỗi lần hiện
        // tốn ~4.7 MB cấp phát) — nhả khi ẩn lâu ([idleRelease]; onTrimMemory hầu như không tới).
        handler.removeCallbacks(idleRelease)
        handler.postDelayed(idleRelease, IDLE_RELEASE_MS)
        handler.removeCallbacks(firstBarRun)
        android.view.Choreographer.getInstance().removeFrameCallback(firstBarFrame)
        handler.removeCallbacks(autoShiftRun); handler.removeCallbacks(suggestRun); handler.removeCallbacks(shiftRun)
        trackpadMoved = false                  // ô đóng: không auto-shift/gợi ý lúc nhả trackpad
        keyboard?.onHidden()
        feedback.onHidden()                    // âm phím riêng: dừng tiếng đang kêu, GIỮ mẫu đã nạp (nhả ở releaseIdle)
        swipeSoundPlayer?.onHidden()           // âm thanh nét vuốt: dừng vòng lặp, GIỮ mẫu (nhả ở releaseIdle)
        closeClipboardPane()
        inputShown = false
        session.pasteOnce.ended()              // ẩn bàn phím: lời mời dán đang hiện coi như bỏ qua
        clearSwipeUndo()
        strip?.onHidden()
        root?.balloon?.hide()
        root?.effects?.halt()                  // Matrix…: ẩn bàn phím ⇒ dừng hẳn, không còn khung hình
        root?.buddy?.halt()                    // Bạn đồng hành: không hẹn giờ khi ẩn
        root?.aiEye?.halt()                    // Mắt AI: lim dim, không hẹn giờ
        root?.rainbow?.halt()                  // Gaming RGB: đứng yên ở cầu vồng tĩnh
        root?.hueFill?.halt()                  // Ảo giác: nền đứng yên, hết gợn sóng
        session.finishInput()
    }

    /**
     * Hệ thống thiếu RAM: như hẹn giờ ẩn ([releaseIdle]) nhưng ngay. API 34+ gần như không gửi
     * (IME đang chọn ở oom_adj 100) ⇒ đường chính là [idleRelease]. Trie chọn phím thông minh là
     * asset mmap (0 heap) ⇒ KHÔNG nhả (trước đây nhả 0.86 MB, lần hiện sau tốn 31 MB rác).
     */
    override fun onTrimMemory(level: Int) {
        super.onTrimMemory(level)
        // FUTO Swipe (thử nghiệm): nhả ~3.4 MB khi THIẾU RAM thật (tải lại lười ở lần vuốt/hiện sau).
        // KHÔNG nhả ở UI_HIDDEN (gửi mỗi lần bàn phím ẩn ⇒ giải lại weights mỗi lần hiện).
        if (ImeTrim.releaseFuto(level)) synchronized(swipeLock) { futo?.release() }
        if (!ImeTrim.releaseIdle(level, inputShown)) return
        releaseIdle()
        settingsCache = null
    }

    /** API cũ (≈ TRIM_MEMORY_COMPLETE): bàn phím đang ẩn ⇒ nhả như hẹn giờ ẩn (gồm SoundPool). */
    @Deprecated("Deprecated in Java")
    override fun onLowMemory() {
        @Suppress("DEPRECATION") super.onLowMemory()
        if (!inputShown) releaseIdle()
    }

    /** Hẹn giờ ẩn (RAM-AUDIT #6): bàn phím ẩn liền [IDLE_RELEASE_MS] ⇒ nhả dữ liệu nạp lại được. */
    private val idleRelease = Runnable { if (!inputShown) releaseIdle() }

    /** Đã nhả gì ở [releaseIdle] ⇒ lần hiện kế nạp lại NỀN ([rewarmAfterIdle]). */
    private var englishReleased = false
    private var wallpaperReleased = false

    /**
     * Nhả dữ liệu dựng lại được: model FUTO (~3.4 MB), từ điển Anh (~1.4 MB), template gõ vuốt,
     * ảnh nền (bitmap), String emoji, bảng clipboard (view), cache mẫu câu. Tất cả có đường dự
     * phòng khi chưa nạp lại xong (SHARK2, nền màu theme, …) — không chặn phím đầu.
     */
    private fun releaseIdle() {
        synchronized(swipeLock) { futo?.release(); swipeDecoder = null }
        if (SwipeEnglish.isLoaded) { SwipeEnglish.release(); englishReleased = true }
        if (root?.dropWallpaper() == true) wallpaperReleased = true
        WallpaperBitmap.drop()
        EmojiData.releaseCategories()
        keyboard?.releaseIdleCaches()
        clipPane?.let { if (it.visibility != View.VISIBLE) { it.listener = null; root?.overlay = null; clipPane = null } }
        templatesCache = null
        // RAM 10/11/2026: SoundPool giữ qua các lần ẩn ngắn, nhả ở đây; cache từ vựng vuốt theo decoder vừa bỏ.
        feedback.releaseSound()
        swipeSoundPlayer?.release()            // lần hiện kế applySwipeSound nạp lại
        com.viettelex.keyboard.SwipeVocab.release()
        // RAM-AUDIT 10/11/2026: atlas Bạn đồng hành (view đã nhả ở dropWallpaper — cùng người nhảy Night Club, ảnh hiệu
        // ứng phím; nạp lại ở reloadWallpaper trên vt-rewarm) ⇒ bỏ luôn bản cache cấp process.
        BuddyView.SpriteAssets.drop()
    }

    /**
     * Hiện lại sau [releaseIdle]: nạp lại những gì đã nhả trên MỘT luồng nền ưu tiên thấp riêng
     * (không chen hàng đợi gợi ý của worker ⇒ phím/gợi ý đầu không chờ). Hiếm: ≤ 1 lần / 3 phút ẩn.
     */
    private fun rewarmAfterIdle() {
        val english = englishReleased; val wall = wallpaperReleased
        if (!english && !wall) return
        englishReleased = false; wallpaperReleased = false
        val jobs = ArrayList<Runnable>(2)
        if (english) jobs += Runnable { SwipeEnglish.warm() }
        if (wall) root?.reloadWallpaper { jobs += it }
        if (jobs.isEmpty()) return
        Thread({ jobs.forEach { it.run() } }, "vt-rewarm").apply { priority = Thread.MIN_PRIORITY + 1 }.start()
    }

    override fun onComputeInsets(outInsets: InputMethodService.Insets) {
        super.onComputeInsets(outInsets)
        val r = root
        if (r != null && r.floating && !r.panel.isEmpty && r.isAttachedToWindow) {
            // Thả nổi (#112, như Gboard): app không co (content/visible top = đáy cửa sổ), chỉ khung
            // nhận chạm — ngoài khung chạm rơi xuống app.
            val decorH = window?.window?.decorView?.height ?: 0
            val top = FloatingKeyboard.contentTopInsets(decorH)
            outInsets.contentTopInsets = top
            outInsets.visibleTopInsets = top
            r.getLocationInWindow(insetsLoc)
            val p = r.panel
            val g = FloatingKeyboard.touchRegion(insetsLoc[0], insetsLoc[1], p.left, p.top, p.right, p.bottom)
            outInsets.touchableInsets = InputMethodService.Insets.TOUCHABLE_INSETS_REGION
            outInsets.touchableRegion.set(g[0], g[1], g[2], g[3])
            return
        }
        // Toàn khung input view nhận touch — chạm vào khe không rơi sang app (§5).
        outInsets.touchableInsets = InputMethodService.Insets.TOUCHABLE_INSETS_CONTENT
    }
    private val insetsLoc = IntArray(2)

    // MARK: thả nổi (#112)

    /** Thả nổi đang áp ở input view hiện tại. */
    private val floatingNow: Boolean get() = root?.floating == true

    /**
     * Áp chế độ thả nổi lên view hiện tại: vị trí theo chiều màn hình (prefs trạng thái), một tay
     * tắt (menu ✋ ẩn), "Nâng bàn phím" bỏ qua. Tắt ⇒ y như cũ (một tay + nâng theo cài đặt).
     */
    private fun applyFloating(on: Boolean, settings: KeyboardSettings = settings()) {
        val r = root ?: return
        val th = theme ?: return
        val kb = keyboard ?: return
        val st = strip ?: return
        if (on) {
            val (fx, fy) = FloatingKeyboard.load(th.landscape) { stateStore().getString(it, null) }
            r.onFloatMoved = { x, y -> FloatingKeyboard.save(th.landscape, x, y) { k, v -> stateStore().edit().putString(k, v).apply() } }
            r.onFloatExit = { setFloatingPref(false) }
            r.setFloating(true, fx, fy)
            r.raisePx = 0
        } else {
            r.setFloating(false)
            r.onFloatMoved = null; r.onFloatExit = null
            r.raisePx = ImeInsets.raisePx(settings.keyboardRaise, th.density)
        }
        kb.floatingOn = on
        st.oneHandAvailable = !th.tablet && !on
        kb.setOneHand(if (th.tablet || on) OneHandSide.OFF else OneHandSide.fromPref(settings.oneHandMode))
        styleWindow(th, r)
    }

    /** Ghi công tắc (app + sao lưu thấy) rồi áp ngay. */
    private fun setFloatingPref(on: Boolean) {
        editPrefs().putBoolean(Keys.FLOATING_KEYBOARD, on).apply()
        applyFloating(on)
    }

    override fun onToggleFloating() = setFloatingPref(!floatingNow)

    override fun onUpdateSelection(oldSelStart: Int, oldSelEnd: Int, newSelStart: Int, newSelEnd: Int,
                                   candidatesStart: Int, candidatesEnd: Int) {
        super.onUpdateSelection(oldSelStart, oldSelEnd, newSelStart, newSelEnd, candidatesStart, candidatesEnd)
        // Mình không dùng composing text: span còn (app/IME trước để sót) ⇒ chốt ở phím kế.
        if (candidatesStart != -1) proxy.finishComposingOnNextEdit()
        if (newSelStart < 0) proxy.invalidateShadow()   // "không biết": không reset engine, chỉ đọc lại chữ
        keyboard?.setEditHasSelection(newSelStart >= 0 && newSelStart != newSelEnd)
        if (!tracker.onUpdate(newSelStart, newSelEnd)) return
        // Đổi từ NGOÀI (chạm chỗ khác, select-all, app tự sửa): quên từ + ngữ cảnh.
        proxy.invalidateShadow()
        session.externalSelectionChange()
        clearSwipeUndo()
        applyAutoShift()
        refreshBar()
    }

    // MARK: bàn phím cứng

    /** Công tắc "Telex cho bàn phím cứng" (Keys.HARDWARE_TELEX). */
    private var hwSetting = true
    /** configureField đã chạy cho ô hiện tại. */
    private var fieldReady = false
    /** Đã tiêu thụ ít nhất một phím cứng trên ô hiện tại. */
    private var hwTyped = false
    /** keyCode đã nuốt ở ACTION_DOWN ⇒ nuốt luôn ACTION_UP (app không nhận up mồ côi). */
    private val hwConsumed = BitSet()

    /**
     * Có phím cứng thì bàn phím ảo thường KHÔNG hiện (onEvaluateInputViewShown mặc định) ⇒
     * onStartInputView không chạy: dựng ô ngay ở đây để tracker theo dõi từ đầu. Không có
     * phím cứng ⇒ để onStartInputView lo như cũ (không tốn gì thêm cho người chỉ gõ chạm).
     */
    override fun onStartInput(attribute: EditorInfo, restarting: Boolean) {
        super.onStartInput(attribute, restarting)
        fieldReady = false
        hwTyped = false
        hwConsumed.clear()
        syncPrefsFromDisk()
        val settings = settings()
        hwSetting = settings.hardwareTelex
        if (hwSetting && hardKeyboardPresent()) configureField(attribute, settings)
    }

    override fun onFinishInput() {
        if (hwTyped) session.finishInput()     // bàn phím ảo không hiện ⇒ onFinishInputView không lưu model
        fieldReady = false
        hwTyped = false
        hwConsumed.clear()
        super.onFinishInput()
    }

    private fun hardKeyboardPresent(): Boolean {
        val c = resources.configuration
        return c.keyboard != android.content.res.Configuration.KEYBOARD_NOKEYS &&
            c.hardKeyboardHidden != android.content.res.Configuration.HARDKEYBOARDHIDDEN_YES
    }

    override fun onKeyDown(keyCode: Int, event: KeyEvent): Boolean =
        onHardwareKeyDown(keyCode, event) || super.onKeyDown(keyCode, event)

    override fun onKeyUp(keyCode: Int, event: KeyEvent): Boolean {
        if (keyCode >= 0 && hwConsumed.get(keyCode)) { hwConsumed.clear(keyCode); return true }
        return super.onKeyUp(keyCode, event)
    }

    /**
     * Phím cứng → cùng đường với phím chạm ([onKey]: batch IcProxy, confirmTail, tracker,
     * WriteMode). Chữ hoa/thường CHỈ theo Shift/CapsLock thật của KeyEvent — không đọc shift
     * của bàn phím ảo, không auto-shift (Funput #462: shift một lần phải nhả ngay).
     */
    private fun onHardwareKeyDown(keyCode: Int, event: KeyEvent): Boolean {
        if (!hwSetting || currentInputConnection == null) return false
        if (!fieldReady) configureField(currentInputEditorInfo ?: return false, settings())
        if (!hwSetting || field.isSecure || (field.passthrough && !field.emailCompose) || field.rawKeys) return false
        val meta = event.metaState
        val k = HardwareKeys.classify(keyCode, meta, event.getUnicodeChar(meta))
        when (k) {
            HwKey.Pass -> {
                // Ctrl+C, mũi tên, Tab, Esc…: app tự xử lý; từ đang soạn coi như xong.
                if (session.bridge.isComposing) session.externalSelectionChange()
                return false
            }
            HwKey.Enter -> {
                // Chốt từ (auto-restore) rồi để Enter thật tới app: Shift+Enter, "Enter để gửi",
                // IME action của TextView đều giữ nguyên hành vi bàn phím cứng.
                clearSwipeUndo()
                if (proxy.begin()) try { session.commitComposing(proxy) } finally { proxy.end() }
                resetIfEditFailed()
                return false
            }
            else -> {}
        }
        val key = HardwareKeys.sessionKey(k, session.bridge.isComposing) ?: return false
        hwTyped = true
        hwConsumed.set(keyCode)
        onKey(key)
        // Bàn phím ảo đang hiện song song: shift một-lần của nó nhả NGAY khi gõ chữ cứng.
        if (key is Key.Letter) keyboard?.setAutoShift(false)
        return true
    }

    // MARK: phím

    private var stateStoreCache: SharedPreferences? = null
    private fun stateStore(): SharedPreferences =
        stateStoreCache ?: getSharedPreferences(ImePrefFiles.STATE, MODE_PRIVATE).also { stateStoreCache = it }

    /** enlexicon + bảng từ phổ biến nạp nền (lần đầu vào Tiếng Anh), khỏi trễ phím đầu. */
    private fun warmEnglish() { worker().post { com.viettelex.keyboard.SwipeEnglish.top } }

    /** Vuốt phím cách: đổi Tiếng Việt ↔ Tiếng Anh (chuyển/chốt từ đang gõ, lưu trạng thái). */
    override fun onSpaceFlick() {
        clearSwipeUndo()
        if (!proxy.begin()) return
        // Từ đang soạn chuyển luôn sang ngôn ngữ đích (ONBOARDING-SPEC §7) — chỉ ở bảng chữ;
        // bảng số/emoji/… ⇒ như cũ (chốt từ rồi đổi).
        val convert = keyboard?.plane == Plane.LETTERS
        val lang = try { session.toggleLanguage(proxy, convert) } finally { proxy.end() }
        resetIfEditFailed()
        if (lang == null) return
        stateStore().edit().putString(Keys.KEYBOARD_LANGUAGE, lang.id).apply()
        keyboard?.spaceLanguage = lang
        if (lang == com.viettelex.keyboard.KeyboardLanguage.EN) warmEnglish()
        pendingGen = session.generation
        handler.removeCallbacks(suggestRun)
        refreshBar()
    }

    /** Điểm chạm phím chữ sắp emit (chỉ giữ khi tự sửa bật) — [onKey] chuyển cho session. */
    private var pendingTouch: AutoCorrect.Touch? = null

    override fun onLetterTouch(dx: Float, dy: Float) {
        pendingTouch = if (session.wantsTouches) AutoCorrect.Touch(dx, dy) else null
    }

    override fun onKey(key: Key) {
        ImeTrace.begin(ImeTrace.ON_KEY)
        try { handleKey(key) } finally { ImeTrace.end() }
    }

    private fun handleKey(key: Key) {
        val touch = if (key is Key.Letter) pendingTouch else null
        pendingTouch = null
        if (key == Key.Backspace && toolUndo != null) { undoTextTool(); return }   // ⌫ ngay sau = hoàn tác
        clearSwipeUndo()
        if (!proxy.begin()) return
        val fxBefore = composeBefore(key)
        val out = try { session.handle(key, proxy, touch) } finally { proxy.end() }
        if (fxBefore != null) fxComposeDiff(key, fxBefore)
        if (session.trackBoundaryWord) fxBoundaryEmoji()
        swipeCombo.reset()                                  // phím bất kỳ: từ vuốt đã nổ không còn "vừa vuốt"
        if (session.cheerHit) root?.effects?.queueCheer()   // Sút!: cụm cổ vũ ⇒ pháo sáng + cờ ở lượt vẽ kế
        root?.buddy?.let { buddy ->
            if (key == Key.Backspace) buddy.deletePressed() else buddy.keyPressed()
            if (key is Key.Text) buddy.emojiInserted(key.text)
        }
        if (key is Key.MoveCursor) {
            if (key.vertical) proxy.moveCursorVertical(key.delta) else proxy.moveCursor(key.delta)
        }
        resetIfEditFailed()
        if (key is Key.Letter) strip?.hidePasteCard()
        pendingGen = out.generation
        firstBarPending = false                // lượt gợi ý của phím này thay lượt hoãn lúc hiện
        if (out.needsAutoShift) { handler.removeCallbacks(autoShiftRun); handler.post(autoShiftRun) }
        handler.removeCallbacks(suggestRun)
        handler.postDelayed(suggestRun, SUGGEST_DELAY_MS)
    }

    /** Đang kéo trackpad: đã reset session ở bước đầu, auto-shift/gợi ý hoãn tới lúc nhả. */
    private var trackpadMoved = false

    /**
     * Bước trackpad (đã gom theo frame ở KeyboardView). Bước đầu: reset session như phím
     * MoveCursor; các bước sau chỉ dời con trỏ (1 IPC setSelection, không batch/đọc lại/
     * auto-shift/gợi ý) — [onTrackpadEnd] cập nhật một lần.
     */
    override fun onTrackpadMove(delta: Int, vertical: Boolean) {
        if (!trackpadMoved) {
            clearSwipeUndo()
            if (!proxy.begin()) return
            try { pendingGen = session.handle(Key.MoveCursor(delta, vertical), proxy).generation } finally { proxy.end() }
            handler.removeCallbacks(autoShiftRun); handler.removeCallbacks(suggestRun)
            trackpadMoved = true
        }
        if (vertical) proxy.moveCursorVertical(delta) else proxy.moveCursor(delta)
        resetIfEditFailed()
    }

    /** Giữ ⇧ + kéo phím cách: vùng chọn đang mở rộng (đọc văn bản một lần ở bước đầu). */
    private var shiftSelect: ShiftSelect? = null
    private var shiftSelectTried = false

    override fun onTrackpadSelect(delta: Int, vertical: Boolean) {
        if (!trackpadMoved) {
            clearSwipeUndo()
            if (!proxy.begin()) return
            try { session.commitComposing(proxy) } finally { proxy.end() }
            handler.removeCallbacks(autoShiftRun); handler.removeCallbacks(suggestRun)
            trackpadMoved = true
        }
        if (vertical) {          // lên/xuống theo dòng hiển thị: app tự mở rộng (Shift+↑/↓)
            shiftSelect = null; shiftSelectTried = true
            proxy.shiftArrow(if (delta < 0) EditorPort.PortKey.UP else EditorPort.PortKey.DOWN, kotlin.math.abs(delta))
            return
        }
        if (!shiftSelectTried) { shiftSelectTried = true; shiftSelect = proxy.beginShiftSelect() }
        val sel = shiftSelect
        if (sel == null) {
            proxy.shiftArrow(if (delta < 0) EditorPort.PortKey.LEFT else EditorPort.PortKey.RIGHT, kotlin.math.abs(delta))
            return
        }
        if (sel.move(delta) != null && !proxy.applyShiftSelect(sel)) shiftSelect = null
        resetIfEditFailed()
    }

    override fun onTrackpadEnd() {
        shiftSelect = null; shiftSelectTried = false
        if (!trackpadMoved) return
        trackpadMoved = false
        applyAutoShift()
        refreshBar()
    }

    override fun onDeleteWord() {
        root?.buddy?.deletePressed()
        clearSwipeUndo()
        if (!proxy.begin()) return
        try { session.deleteWordBackward(proxy) } finally { proxy.end() }
        resetIfEditFailed()
        applyAutoShift()
        refreshBar()
    }

    // MARK: chọn phím theo ngữ cảnh (thử nghiệm)

    private var smartTouchSetting = true
    private var smartTouchFieldOk = false

    /** Dựng trie prior (~vài chục ms) trên worker một lần; chưa xong ⇒ router cũ. */
    private fun warmSmartTouch() {
        if (!smartTouchSetting) { TelexKeyPrior.release(); return }   // tắt ⇒ nhả trie (0 RAM)
        if (TelexKeyPrior.sharedIfReady == null) worker().post { if (smartTouchSetting) TelexKeyPrior.warmUp() }
    }

    /** Gọi lúc chạm phím chữ (main): P(phím | từ đang gõ), null = không đổi phím. */
    private fun smartTouchPrior(): ((Char) -> Float?)? {
        if (!smartTouchSetting || !smartTouchFieldOk || !::session.isInitialized) return null
        val b = session.bridge
        if (b.passthrough) return null
        return TelexKeyPrior.sharedIfReady?.forTyping(b.rawWord, b.vniMode)
    }

    // MARK: gõ vuốt

    /** Bật khi: setting + ô hợp lệ + KHÔNG TalkBack/touch exploration. Tắt ⇒ bỏ decoder (template GC được). */
    private fun updateSwipeTyping() {
        updateAlternates()
        val allowed = swipeSetting && accessibility?.isTouchExplorationEnabled != true
        val on = allowed && swipeFieldOk
        if (!on) {
            keyboard?.swipeTyping = false
            if (::session.isInitialized) session.setSwipeTyping(false)
            // Tắt hẳn ⇒ bỏ (0 RAM). Chỉ ô này không cho vuốt (mật khẩu, URL…) ⇒ giữ decoder + FUTO
            // cho ô kế (khỏi giải lại weights); hẹn giờ ẩn vẫn nhả.
            if (!allowed) synchronized(swipeLock) { swipeDecoder = null; futo = null }
            return
        }
        val fresh = swipeDecoder == null
        if (fresh) synchronized(swipeLock) { swipeDecoder = SwipeDecoder() }
        updateFuto()
        session.setSwipeTyping(true)
        if (fresh) keyboard?.swipeTyping = false   // decoder mới (sau onTrimMemory) ⇒ phát lại layout
        keyboard?.swipeTyping = true      // → onSwipeLayout khi plane chữ đã dựng
    }

    /** Giữ phím chữ ra ký tự phụ (KeyAlternates): tắt khi TalkBack (giữ là cử chỉ của trình đọc). */
    private fun updateAlternates() {
        if (!::session.isInitialized) return
        val st = settings()
        val m = KeyAlternates.map(st.longPressNumbers, st.longPressSymbols, st.numberRow,
            accessibility = accessibility?.isTouchExplorationEnabled == true)
        keyboard?.setAlternates(m)
        keyboard?.setShiftAlternates(KeyAlternates.shiftMap(st.holdShiftSymbols, st.longPressNumbers, st.longPressSymbols,
            st.numberRow, accessibility = accessibility?.isTouchExplorationEnabled == true))
        keyboard?.popoversEnabled = accessibility?.isTouchExplorationEnabled != true
        session.setLetterAlternates(m.isNotEmpty())
        // "Vuốt phím để sao chép/dán": tắt khi TalkBack (vuốt là cử chỉ của trình đọc).
        val kc = st.swipeKeyCommands && accessibility?.isTouchExplorationEnabled != true
        keyboard?.keyCommands = kc
        session.setKeyCommands(kc)
    }

    /** Công tắc FUTO Swipe: bật ⇒ tạo + tải model ở nền (nhả lúc ẩn thì tải lại); tắt ⇒ bỏ. */
    private fun updateFuto() {
        val f = synchronized(swipeLock) {
            if (!futoSetting) { futo = null; return }
            futo ?: FutoSwipe { AssetBlobs.provider(assets)(Keys.ASSET_FUTO) }.also { f ->
                swipeDecoder?.layout?.let { f.setLayout(it) }
                futo = f
            }
        }
        worker().post { if (futo === f) f.load() }
    }

    override fun onSwipeLayout(layout: SwipeLayout) {
        val dec = swipeDecoder ?: return
        synchronized(swipeLock) { dec.setLayout(layout); futo?.setLayout(layout) }
        // Dựng template nền (~320 KB) — một luồng nhờ swipeLock; decode chờ nếu chưa xong.
        worker().post {
            synchronized(swipeLock) { if (swipeDecoder === dec) dec.prepare() }
            if (session.swipeEnglish) SwipeEnglish.warm(swipe = true)   // từ điển Anh + bảng vuốt ở nền (lazy, thread-safe)
            SyllableLM.shared       // map mô hình trigram (vnlm.bin — thanh gợi ý + Thêm dấu cũng dùng)
        }
    }

    override fun onSwipeTypingStart(): Boolean {
        if (!session.swipeTypingActive) return false
        clearSwipeUndo()
        // Chữ đầu cú vuốt chưa từng chèn (KeyboardView hoãn tới lúc nhấc, #172) ⇒ không gì để huỷ.
        handler.removeCallbacks(suggestRun); handler.removeCallbacks(autoShiftRun)
        return true
    }

    override fun onSwipeTypingEnd(path: SwipePath, case: SwipeSuggest.Case) {
        val dec = swipeDecoder ?: return
        val ctx = session.swipeContext()
        val t0 = if (TouchLog.enabled) System.nanoTime() else 0L
        // ctx.english != null ⇒ thêm ứng viên tiếng Anh (công tắc "Vuốt từ tiếng Anh"); điểm
        // cá nhân của từ tiếng Anh = ctx.englishWord (không có bigram tĩnh — chỉ cho âm tiết Việt).
        val cands = synchronized(swipeLock) {
            val enCtx = if (ctx.english != null) ctx.englishWord else null
            // FUTO Swipe (thử nghiệm): null khi tắt / model chưa sẵn ⇒ SHARK2 như cũ
            futo?.decode(path, SwipeSuggest.TOP_K, ctx.folded, ctx.english, enCtx, dec)
                ?: dec.decode(path, SwipeSuggest.TOP_K, ctx.folded, ctx.english, enCtx).also {
                    futo?.let { f -> worker().post { if (futo === f) f.load() } }
                }
        }
        // chọn từ + (nếu có) sửa lại từ vuốt trước theo ngữ cảnh hai phía (SwipeRevise)
        val res = session.resolveSwipe(cands, ctx, case)
        if (TouchLog.enabled) TouchLog.write(String.format(java.util.Locale.ROOT, "swipe decode %.1fms pts=%d cands=%d",
            (System.nanoTime() - t0) / 1e6, path.count, cands.size))
        if (res == null || !proxy.begin()) { applyAutoShift(); refreshBar(); return }
        val out = try { session.commitSwipe(res, proxy) } finally { proxy.end() }
        keyboard?.swipeCommitted()          // "Pháo hoa cuối nét" (kiểu khác: 0 việc)
        fxSwipeKeyword(path)                // "Từ khoá" theo từ vuốt (kiểu khác: một phép so sánh)
        resetIfEditFailed()
        strip?.hidePasteCard()
        pendingGen = out.generation
        applyAutoShift()
        refreshBar()
    }

    override fun onSwipeTypingCancel() {
        applyAutoShift()
        refreshBar()
    }

    // MARK: vuốt ⌫ xoá theo từ

    override fun onSwipeDeleteStart(): Boolean {
        clearSwipeUndo()
        if (!swipe.start()) return false
        // Từ đang soạn là "từ thứ nhất" trên màn hình (ranh giới tính từ chữ thật): quên nó trong engine.
        handler.removeCallbacks(suggestRun)
        session.externalSelectionChange()
        return true
    }

    override fun onSwipeDeleteUpdate(words: Int): Int {
        val n = swipe.update(words)
        if (!swipe.selecting) strip?.showSwipePreview(swipe.preview)
        return n
    }

    override fun onSwipeDeleteEnd(commit: Boolean) {
        strip?.showSwipePreview(null)
        val deleted = if (proxy.begin()) try { swipe.finish(commit) } finally { proxy.end() } else { swipe.finish(false); null }
        resetIfEditFailed()
        swipeUndo = deleted
        strip?.showRestore(deleted != null)
        applyAutoShift()
        refreshBar()
    }

    override fun onRestoreDeleted() {
        if (toolUndo != null) { undoTextTool(); return }
        val text = swipeUndo ?: return
        clearSwipeUndo()
        if (!proxy.begin()) return
        try { session.externalSelectionChange(); proxy.insertText(text) } finally { proxy.end() }
        resetIfEditFailed()
        applyAutoShift()
        refreshBar()
    }

    private fun clearSwipeUndo() {
        if (swipeUndo == null && toolUndo == null) return
        swipeUndo = null
        toolUndo = null
        strip?.showRestore(false)
    }

    // MARK: công cụ văn bản (Plus) — logic thuần ở keyboard/TextTools.kt

    /**
     * Áp [tool] lên vùng chọn (getSelectedText) hoặc đoạn trước con trỏ (tới xuống dòng).
     * Lối vào hiện tại: chip đầu lưới mẫu câu; bảng sửa văn bản gộp sau gọi thẳng hàm này.
     */
    override fun onTextTool(tool: TextTool) {
        if (keyboard?.textToolsEnabled != true) return   // Plus + công tắc (đặt lúc vào ô)
        clearSwipeUndo()
        handler.removeCallbacks(suggestRun)
        if (!proxy.begin()) return
        val out = try {
            session.commitComposing(proxy)          // từ đang soạn chốt trước (thuộc đoạn cần đổi)
            TextToolRunner.apply(tool, proxy, IcProxy.CONTEXT_CAP)
        } finally { proxy.end() }
        resetIfEditFailed()
        when (out) {
            is TextToolRunner.Outcome.Applied -> {
                toolUndo = out.undo
                strip?.showRestore(true, tr("Hoàn tác"))
            }
            TextToolRunner.Outcome.FailSafe -> TouchLog.write("failsafe: text tool ${tool.id} tail mismatch → skip")
            else -> {}
        }
        applyAutoShift()
        refreshBar()
    }

    /**
     * Nút "Thêm dấu" (thẻ Công cụ của ☰ / hàng công cụ bảng sửa): thêm dấu cho vùng chọn, không
     * thì đoạn không dấu cuối trước con trỏ — AddTones trên máy, không mạng. Gate: nằm trong nhóm
     * công cụ văn bản (Plus + công tắc, đặt lúc vào ô) + Plus "Thêm dấu cả câu"; KHÔNG cần công tắc
     * chip tự hiện (addTonesChip — công tắc đó chỉ để tránh chạy AddTones mỗi dấu cách).
     * Hoàn tác như công cụ văn bản: ô "↩︎ Hoàn tác" / ⌫ ngay sau.
     */
    override fun onAddTones() {
        if (keyboard?.textToolsEnabled != true || !PlusGate.isUnlocked(PlusFeature.SENTENCE_DIACRITICS)) return
        clearSwipeUndo()
        handler.removeCallbacks(suggestRun)
        if (!proxy.begin()) return
        val out = try {
            session.commitComposing(proxy)
            TextToolRunner.addTones(proxy, session.addTonesPersonal(), IcProxy.CONTEXT_CAP)
        } finally { proxy.end() }
        resetIfEditFailed()
        when (out) {
            is TextToolRunner.Outcome.Applied -> {
                session.externalSelectionChange()
                toolUndo = out.undo
                strip?.showRestore(true, tr("Hoàn tác"))
            }
            TextToolRunner.Outcome.FailSafe -> TouchLog.write("failsafe: add tones button tail mismatch → skip")
            else -> {}
        }
        applyAutoShift()
        refreshBar()
    }

    // MARK: dịch trên máy (Plus) — logic thuần ở keyboard/Translate.kt, ML Kit ở app/…/translate/MlKitBackend.kt

    /**
     * Dịch vùng chọn / đoạn trước con trỏ (giống công cụ văn bản) sang ngôn ngữ đích đã chọn
     * trong app ([Keys.TRANSLATE_TARGET]); đoạn đã là ngôn ngữ đích ⇒ dịch sang tiếng Việt.
     * Chạy nền (ML Kit), thanh gợi ý hiện "Đang dịch…"; kết quả chỉ ghi nếu ô chưa đổi.
     */
    override fun onTranslate() {
        if (!PlusGate.isUnlocked(PlusFeature.TRANSLATE) || proxy.isSecure) return
        clearSwipeUndo()
        handler.removeCallbacks(suggestRun)
        if (!proxy.begin()) return
        val job = try {
            session.commitComposing(proxy)
            TranslateRunner.prepare(proxy, prefs.getString(Keys.TRANSLATE_TARGET, null), IcProxy.CONTEXT_CAP)
        } finally { proxy.end() }
        resetIfEditFailed()
        if (job == null) { refreshBar(); return }
        translateUsed = true
        showTranslateStatus(tr("Đang dịch…"), 0)
        translate.start(job) { j, r -> onTranslated(j, r) }
    }

    private fun onTranslated(job: TranslateJob, r: TranslateResult) {
        when (r) {
            is TranslateResult.Ok -> {
                showTranslateStatus(null, 0)
                if (!proxy.begin()) return
                val out = try { TranslateRunner.commit(job, r.text, proxy) } finally { proxy.end() }
                resetIfEditFailed()
                when (out) {
                    is TextToolRunner.Outcome.Applied -> {
                        session.externalSelectionChange()
                        toolUndo = out.undo
                        strip?.showRestore(true, tr("Hoàn tác"))
                    }
                    TextToolRunner.Outcome.FailSafe -> TouchLog.write("failsafe: translate field changed → drop result")
                    else -> {}
                }
                applyAutoShift()
                refreshBar()
            }
            TranslateResult.MissingModel -> showTranslateStatus(tr("Mở app VietTelex để tải gói dịch"), 3500)
            is TranslateResult.Failed -> {
                // Chỉ tên lớp lỗi (phần trước ":"): thông điệp exception có thể kèm nội dung.
                TouchLog.write("translate failed: ${r.reason.substringBefore(':').take(80)}")
                showTranslateStatus(tr("Không dịch được — thử lại sau"), 2500)
            }
        }
    }

    /** [text] null = gỡ; [ms] > 0 = tự gỡ sau chừng đó. */
    private fun showTranslateStatus(text: String?, ms: Long) {
        handler.removeCallbacks(clearStatusRun)
        strip?.showStatus(text)
        if (text != null && ms > 0) handler.postDelayed(clearStatusRun, ms)
    }

    /** Ô đóng / IME huỷ: bỏ lượt đang dịch, đóng client. Chưa từng dịch ⇒ không đụng gì (0 chi phí). */
    private fun cancelTranslate() {
        if (!translateUsed) return
        translate.cancel()
        showTranslateStatus(null, 0)
    }

    private fun undoTextTool() {
        val u = toolUndo ?: return
        clearSwipeUndo()
        if (!proxy.begin()) return
        val ok = try { TextToolRunner.undo(u, proxy) } finally { proxy.end() }
        if (!ok) TouchLog.write("failsafe: text tool undo tail moved → skip")
        resetIfEditFailed()
        session.externalSelectionChange()
        applyAutoShift()
        refreshBar()
    }

    /** commitText/deleteSurroundingText trả false: màn hình không còn chắc khớp engine ⇒ quên từ. */
    private fun resetIfEditFailed() {
        if (proxy.takeFailure()) session.externalSelectionChange()
    }

    override fun onGlobe(longPress: Boolean) {
        val imm = getSystemService(Context.INPUT_METHOD_SERVICE) as InputMethodManager
        if (longPress) { imm.showInputMethodPicker(); return }
        if (Build.VERSION.SDK_INT >= 28) switchToNextInputMethod(false)
        else {
            val token = window?.window?.attributes?.token ?: return
            @Suppress("DEPRECATION") imm.switchToNextInputMethod(token, false)
        }
    }

    /** Không có phím 🌐 trên bàn phím (user chốt 26/09): đổi bàn phím bằng nút của thanh điều hướng hệ thống. */
    private fun needsGlobe(): Boolean = false

    /**
     * API 36: hệ thống báo khi thanh điều hướng KHÔNG vẽ nút đổi bàn phím → hiện gợi ý 🌐 nhỏ
     * trên phím 😊 (giữ lâu = chọn bàn phím). Có nút hệ thống thì ẩn gợi ý. Dưới API 36 thanh
     * điều hướng luôn có nút khi máy có ≥2 bàn phím → không hiện gợi ý.
     */
    override fun onCustomImeSwitcherButtonRequestedVisible(visible: Boolean) {
        switcherHintVisible = visible
        keyboard?.setSwitcherHint(visible)
    }
    private var switcherHintVisible = false

    override fun onDismissKeyboard() = requestHideSelf(0)

    /** 📋 bàn số: dán clipboard đã lọc theo ô ("0903 389 710" → "0903389710" ở ô số / điện thoại). */
    override fun onPadPaste() {
        val f = when (field.kind) {
            InputKind.PHONE -> com.viettelex.keyboard.NumericPaste.Field.PHONE
            InputKind.DATETIME -> com.viettelex.keyboard.NumericPaste.Field.DATETIME
            else -> if (field.numberDecimal) com.viettelex.keyboard.NumericPaste.Field.DECIMAL
                    else com.viettelex.keyboard.NumericPaste.Field.NUMBER
        }
        clearSwipeUndo()
        if (!proxy.begin()) return
        val got = try {
            session.pasteFiltered(proxy) { com.viettelex.keyboard.NumericPaste.clean(it, f, field.numberSigned) }
        } finally { proxy.end() }
        if (TouchLog.enabled) TouchLog.write("padPaste field=$f inserted=${got.length}")
        resetIfEditFailed()
        applyAutoShift()
        refreshBar()
    }

    override fun onVoiceInput() {
        if (!voice.launch()) { voice.refresh(); keyboard?.setVoiceAvailable(voice.available && !field.isSecure) }
    }

    /** "." "," ":" ở plane ?123: ngay sau chữ số thì ở lại ("2.5"). Shadow tin được ⇒ không IPC. */
    override fun charBeforeCursor(): Char? = proxy.contextBeforeInput()?.lastOrNull()

    override fun onPlaneChanged(plane: Plane) {
        strip?.setPlane(plane)
        // Về chữ: viết hoa đầu câu theo context lúc đó (". " tự thêm ở plane 123 ⇒ hoa) —
        // một lần đọc context mỗi lần đổi plane, không mỗi phím.
        // Trong kb.configure lúc hiện: bỏ — startInputView tự auto-shift MỘT lần ở cuối (không đọc ô hai lần).
        if (inputShown && fieldReady && !configuringKb && PlanePolicy.reevaluatesShift(plane)) applyAutoShift()
    }

    /** Recents emoji ở prefs trạng thái (không kích listener cài đặt/theme); bản cũ chuyển một lần. */
    override fun emojiRecents(): List<String> = EmojiRecents.load(
        state = { stateStore().getString(Keys.EMOJI_RECENTS, null) },
        legacy = { prefs.getString(Keys.EMOJI_RECENTS, null) },
        store = { stateStore().edit().putString(Keys.EMOJI_RECENTS, it).apply() },
        dropLegacy = { editPrefs().remove(Keys.EMOJI_RECENTS).apply() })

    override fun noteEmojiUsed(e: String) {
        val next = EmojiRecents.noteUsed(emojiRecents(), e)
        stateStore().edit().putString(Keys.EMOJI_RECENTS, EmojiRecents.encode(next)).apply()
    }

    // MARK: mẫu câu

    override fun onTemplate(item: TemplateItem) {
        val text = item.text
        if (!Templates.isDynamic(text)) { insertTemplate(text); return }
        // Mẫu động: fetch lúc chạm (timeout 4 s); HTTP ≠ 200 / lỗi / rỗng ⇒ chèn chính URL.
        // Đọc 1 byte quá giới hạn để [Templates.bodyFromResponse] biết bị cắt (lùi về ranh giới UTF-8).
        val w = worker()
        w.post {
            val body = try {
                val c = URL(text).openConnection() as HttpURLConnection
                c.connectTimeout = Templates.FETCH_TIMEOUT_MS
                c.readTimeout = Templates.FETCH_TIMEOUT_MS
                try {
                    val status = c.responseCode
                    if (status != 200) null else c.inputStream.use { ins ->
                        val buf = ByteArray(Templates.FETCH_MAX_BYTES + 1)
                        var n = 0
                        while (n < buf.size) { val r = ins.read(buf, n, buf.size - n); if (r < 0) break; n += r }
                        Templates.bodyFromResponse(buf.copyOf(n), status)
                    }
                } finally { c.disconnect() }
            } catch (_: Exception) { null }
            handler.post { insertTemplate(body ?: text) }
        }
    }

    private fun insertTemplate(text: String) {
        if (!proxy.begin()) return
        try { session.insertTemplate(text, proxy) } finally { proxy.end() }
        resetIfEditFailed()
        applyAutoShift()
        refreshBar()
    }

    override fun onOpenSettings() {
        try {
            val i = packageManager.getLaunchIntentForPackage(packageName) ?: return
            startActivity(i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP))
        } catch (e: Exception) {
            Log.w(TAG, "open settings: $e")
        }
    }

    override fun onOpenTemplates() {
        try {
            startActivity(Intent(Intent.ACTION_VIEW, Uri.parse("viettelex://maucau"))
                .setPackage(packageName)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP))
        } catch (e: Exception) {
            Log.w(TAG, "open templates: $e")
        }
    }

    // MARK: strip

    override fun onSuggestion(item: String) {
        // Bàn số: "Dán" trên thanh = dán số đã lọc như phím 📋 cũ (1.456.464 VND → 1456464).
        if (item == com.viettelex.keyboard.SuggestionSet.PASTE_TOKEN && field.isNumberPad) { onPadPaste(); return }
        clearSwipeUndo()
        if (!proxy.begin()) return
        syncShift()
        try { session.acceptSuggestion(item, proxy) } finally { proxy.end() }
        root?.buddy?.cheer()
        root?.buddy?.emojiInserted(item)
        resetIfEditFailed()
        // Chọn gợi ý = gõ một từ: Shift một-lần nhả (session đã hạ keyboardShift), Caps giữ.
        if (session.keyboardShift == SuggestionCase.Shift.OFF) keyboard?.setAutoShift(false)
        applyAutoShift()
        refreshBar()
    }

    override fun onToggleTemplates() { closeClipboardPane(); keyboard?.toggleTemplates() }

    // MARK: lịch sử clipboard

    /** Bàn phím đang hiện (ô hiện tại có ý nghĩa cho luật "ô mật khẩu"). */
    private var inputShown = false
    private var clipPane: ClipboardPane? = null
    private val clipFile by lazy { File(filesDir, Keys.CLIPBOARD_FILE) }

    /**
     * Bật ⇒ nạp file (một lần) + áp hạn [ttl] ("Giữ lịch sử clipboard") rồi prune — rút ngắn
     * hạn ⇒ mục quá hạn bị bỏ ngay lần hiện kế tiếp; tắt ⇒ bỏ RAM + xoá file.
     */
    private fun syncClipHistory(enabled: Boolean, ttl: ClipboardTTL) {
        if (!enabled) {
            clipLoadGen++   // lượt đọc nền còn chờ: bỏ
            if (session.clipHistory != null || clipFile.exists()) { session.clipHistory = null; clipFile.delete() }
            strip?.setExtras(clipButton = false, open = false)
            closeClipboardPane()
            return
        }
        session.clipHistory?.let { h ->
            if (h.ttlMs != ttl.ms) { h.ttlMs = ttl.ms; if (h.prune(System.currentTimeMillis())) saveClipHistory(h) }
            return
        }
        // Đọc + giải file trên worker (onCreate không chờ IO). Cùng HandlerThread với
        // saveClipHistory ⇒ lượt đọc xếp TRƯỚC mọi lượt ghi của bản tạm — không đọc phải file vừa
        // bị bản tạm ghi đè.
        val placeholder = ClipboardHistory(ttlMs = ttl.ms)
        session.clipHistory = placeholder
        val gen = ++clipLoadGen
        val f = clipFile
        worker().post {
            val text = try { if (f.exists()) f.readText() else null } catch (_: Exception) { null }
            val loaded = ClipboardHistory.deserialize(text, ttlMs = ttl.ms)
            handler.post { finishClipLoad(gen, placeholder, loaded) }
        }
    }
    /** Thế hệ lượt đọc lịch sử clipboard nền (đổi ⇒ kết quả cũ bị bỏ). */
    private var clipLoadGen = 0

    /**
     * Đọc + giải file lịch sử clipboard đã xong trên worker. [placeholder] = bản RAM rỗng gắn tạm lúc
     * chờ (nút 📋 / ghi clip vẫn chạy); mục chép trong lúc chờ gộp lên trên bản đọc được (đúng thứ
     * tự thời gian), rồi ghi lại. Lần sync khác / tắt / onDestroy chen giữa ⇒ bỏ kết quả.
     */
    private fun finishClipLoad(gen: Int, placeholder: ClipboardHistory, loaded: ClipboardHistory) {
        if (gen != clipLoadGen || session.clipHistory !== placeholder) return
        val now = System.currentTimeMillis()
        loaded.ttlMs = placeholder.ttlMs
        var changed = loaded.prune(now)
        if (loaded.absorb(placeholder)) { loaded.prune(now); changed = true }
        session.clipHistory = loaded
        if (changed) saveClipHistory(loaded)
        if (clipPane?.visibility == View.VISIBLE) refreshClipboardPane()
        if (inputShown) { session.invalidatePasteCache(); refreshBar() }
    }

    /** Ghi nền (file nhỏ ≤ 20 mục × 4000 ký tự); chụp chuỗi trên main trước. */
    private fun saveClipHistory(h: ClipboardHistory? = session.clipHistory) {
        val data = h?.serialize() ?: return
        val f = clipFile
        worker().post {
            try {
                val tmp = File(f.parentFile, f.name + ".tmp")
                tmp.writeText(data)
                if (!tmp.renameTo(f)) { f.writeText(data); tmp.delete() }
            } catch (e: Exception) { Log.w(TAG, "clip save: $e") }
        }
    }

    private fun onClipChanged() {
        // Ô mật khẩu chỉ tính khi bàn phím đang hiện ở ô đó; ẩn ⇒ copy ở app khác.
        if (session.recordClip(inputShown && field.isSecure)) {
            saveClipHistory()
            if (clipPane?.visibility == View.VISIBLE) refreshClipboardPane()
        }
        if (inputShown) { session.invalidatePasteCache(); refreshBar() }
    }

    override fun onToggleClipboard() {
        if (clipPane?.visibility == View.VISIBLE) { closeClipboardPane(); return }
        val th = theme ?: return
        val r = root ?: return
        if (keyboard?.plane == Plane.TEMPLATES) keyboard?.toggleTemplates()
        val pane = clipPane ?: ClipboardPane(this, th).also { it.listener = this; clipPane = it; r.overlay = it }
        pane.visibility = View.VISIBLE
        refreshClipboardPane()
        pane.scrollTop()
        strip?.setExtras(clipButton = true, open = true)
    }

    private fun refreshClipboardPane() {
        val h = session.clipHistory
        clipPane?.show(h?.items(System.currentTimeMillis()) ?: emptyList(), h != null, session.incognito)
    }

    private fun closeClipboardPane() {
        val p = clipPane ?: return
        if (p.visibility != View.VISIBLE) return
        p.visibility = View.GONE
        strip?.setExtras(clipButton = session.clipHistory != null, open = false)
    }

    override fun onClipPick(text: String) {
        closeClipboardPane()
        clearSwipeUndo()
        if (!proxy.begin()) return
        try { session.insertClip(text, proxy) } finally { proxy.end() }
        resetIfEditFailed()
        applyAutoShift()
        refreshBar()
    }

    override fun onClipTogglePin(text: String) {
        val h = session.clipHistory ?: return
        val limit = PlusGate.pinnedClipLimit
        if (h.togglePin(text, limit)) { saveClipHistory(); refreshClipboardPane() }
        else if (limit != null && h.contains(text)) {
            clipPane?.showNotice(tr("Tối đa %d mục ghim — VietTelex Plus ghim không giới hạn.", limit))
        }
    }

    override fun onClipRemove(text: String) {
        if (session.clipHistory?.remove(text) == true) { saveClipHistory(); refreshClipboardPane() }
    }

    override fun onClipClearAll() {
        session.clipHistory?.clear()
        saveClipHistory(); refreshClipboardPane()
    }

    override fun onClipClose() = closeClipboardPane()

    // MARK: bảng sửa văn bản + một tay

    override fun onToggleEditPanel() { keyboard?.toggleEditPanel() }

    // --- nút 😊 trên strip ("Nút emoji" = Thanh trên) ---
    override fun onEmojiButton() { keyboard?.setPlane(Plane.EMOJI) }
    override fun onBuddyTickle() { root?.buddy?.tickle(); root?.aiEye?.tickle() }

    /** Toạ độ StripView → KeyboardView (cùng cha ImeRootView, kể cả thả nổi). */
    private fun stripToKbDy(): Float {
        val st = strip ?: return 0f; val kb = keyboard ?: return 0f
        return (st.top - kb.top).toFloat()
    }
    private fun stripToKbDx(): Float {
        val st = strip ?: return 0f; val kb = keyboard ?: return 0f
        return (st.left - kb.left).toFloat()
    }

    override fun onEmojiButtonHold(anchorCx: Float, anchorTop: Float, anchorBottom: Float, x: Float, y: Float): Boolean {
        val kb = keyboard ?: return false
        val dx = stripToKbDx(); val dy = stripToKbDy()
        return kb.stripEmojiHold(anchorCx + dx, anchorTop + dy, anchorBottom + dy, x + dx, y + dy)
    }
    override fun onEmojiButtonHoldMove(x: Float, y: Float) { keyboard?.stripEmojiMove(x + stripToKbDx(), y + stripToKbDy()) }
    override fun onEmojiButtonHoldEnd(cancel: Boolean) { keyboard?.stripEmojiRelease(cancel) }

    override fun onEditAction(action: EditAction, selecting: Boolean) {
        clearSwipeUndo()
        if (!proxy.begin()) return
        try {
            session.commitComposing(proxy)          // từ đang gõ chốt trước khi dời / cắt / dán
            EditCommands.run(action, selecting, proxy, tracker)
        } finally { proxy.end() }
        resetIfEditFailed()
        applyAutoShift()
        refreshBar()
    }

    // MARK: vuốt phím thẳng lên ⇒ lệnh (KeyCommandGesture)

    override fun keyCommandHasSelection(): Boolean = proxy.hasSelection

    override fun keyCommandLabel(cmd: KeyCommand): String =
        if (cmd.needsSelection && !proxy.hasSelection) tr("Chưa chọn chữ") else tr(cmd.label)

    /**
     * Nhấc tay lúc lệnh đang bật: gỡ chữ của phím (đã chèn lúc chạm — checkpoint như gõ vuốt;
     * không được thì ⌫), chốt từ đang gõ, rồi chạy lệnh của bảng sửa (performContextMenuAction,
     * dự phòng Ctrl+phím). [letterDeferred] ⇒ chữ chưa chèn, vùng chọn còn nguyên.
     */
    override fun onKeyCommand(cmd: KeyCommand, letterDeferred: Boolean) {
        clearSwipeUndo()
        if (!proxy.begin()) return
        try {
            if (!letterDeferred && !session.undoLastLetter(proxy)) session.handle(Key.Backspace, proxy)
            session.commitComposing(proxy)
            if (!cmd.needsSelection || proxy.hasSelection) EditCommands.run(KeyCommands.editAction(cmd), false, proxy, tracker)
        } finally { proxy.end() }
        resetIfEditFailed()
        handler.removeCallbacks(suggestRun)
        applyAutoShift()
        refreshBar()
    }

    override fun onToggleOneHand() {
        val kb = keyboard ?: return
        if (kb.splitActive) return          // tách đôi: một tay tạm tắt (như iOS)
        val last = OneHandSide.fromPref(prefs.getString(Keys.ONE_HAND_LAST, null))
        onOneHandChange(OneHand.toggled(kb.oneHand, last))
    }

    override fun onOneHandChange(side: OneHandSide) {
        if (theme?.tablet == true) return
        val e = editPrefs().putString(Keys.ONE_HAND_MODE, side.pref)
        if (side != OneHandSide.OFF) e.putString(Keys.ONE_HAND_LAST, side.pref)
        e.apply()
        if (floatingNow) return             // một tay tắt khi thả nổi (lưu lại, áp khi gắn lại)
        keyboard?.setOneHand(side)
    }

    // MARK: auto-shift + gợi ý

    /** [allowRead] = false: khung đầu lúc hiện — không đọc ô (xem [KeyboardSession.autoShiftUnverified]). */
    private fun applyAutoShift(allowRead: Boolean = true) {
        val on = session.updateAutoShift(proxy, allowRead) ?: return
        keyboard?.setAutoShift(on)
    }

    override fun onShiftChanged() {
        handler.removeCallbacks(shiftRun)
        handler.postDelayed(shiftRun, SUGGEST_DELAY_MS)
    }

    /** Shift thật của bàn phím ảo → session (hoa/thường gợi ý, SuggestionCase). */
    private fun syncShift() {
        val kb = keyboard ?: return
        session.keyboardShift = when (kb.shift) {
            KeyboardView.Shift.OFF -> SuggestionCase.Shift.OFF
            KeyboardView.Shift.ON -> SuggestionCase.Shift.ONCE
            KeyboardView.Shift.CAPS -> SuggestionCase.Shift.CAPS_LOCK
        }
    }

    private fun refreshBar() {
        val st = strip ?: return
        if (!session.stripMode.shown || session.barCollapsed) return
        syncShift()
        when (val plan = session.requestSuggestions(proxy)) {
            is SuggestionPlan.Ready -> st.show(plan.set)
            is SuggestionPlan.Background -> {
                val job = plan.job
                worker().post {
                    ImeTrace.begin(ImeTrace.SUGGEST_BG)
                    val r = try { job.compute() } finally { ImeTrace.end() }
                    handler.post { session.completeSuggestions(job, r, proxy)?.let { strip?.show(it) } }
                }
            }
        }
    }

    private fun worker(): Handler = worker ?: run {
        val t = HandlerThread("vt-suggest", Process.THREAD_PRIORITY_DEFAULT).also { it.start() }
        workerThread = t
        Handler(t.looper).also { worker = it }
    }

    /** DEBUG: mốc onCreate (process / service mới) — lần hiện đầu sau đó là "cold". */
    private var perfCreatedAt = 0L
    private var perfShownOnce = false

    /**
     * DEBUG "perf firstFrame": onStartInputView → lượt vẽ đầu của cây view bàn phím (pre-draw);
     * cold = lần hiện đầu sau onCreate (kèm thời gian tính từ onCreate). Cạnh log perf onCreate/…
     */
    private fun logFirstFrame(t0: Long) {
        val r = root ?: return
        val cold = !perfShownOnce
        perfShownOnce = true
        r.viewTreeObserver.addOnPreDrawListener(object : android.view.ViewTreeObserver.OnPreDrawListener {
            override fun onPreDraw(): Boolean {
                if (r.viewTreeObserver.isAlive) r.viewTreeObserver.removeOnPreDrawListener(this)
                val now = SystemClock.elapsedRealtime()
                val tag = if (cold) "cold, since onCreate ${now - perfCreatedAt} ms" else "warm"
                Log.d(TAG, "perf firstFrame ${now - t0} ms ($tag)")
                return true
            }
        })
    }

    private fun logMemory() {
        val rt = Runtime.getRuntime()
        val heap = (rt.totalMemory() - rt.freeMemory()) / 1_048_576.0
        val pss = android.os.Debug.getPss() / 1024.0
        Log.d(TAG, String.format("mem: heap %.1f MB, pss %.1f MB", heap, pss))
    }

    companion object {
        private const val TAG = "VTKB"
        const val SUGGEST_DELAY_MS = 30L
        /** Bàn phím ẩn liền bấy lâu ⇒ [releaseIdle] — xem [ImeTrim.IDLE_RELEASE_MS]. */
        const val IDLE_RELEASE_MS = ImeTrim.IDLE_RELEASE_MS
    }
}

/** Chính sách onTrimMemory (hàm thuần để test; số = hằng ComponentCallbacks2). */
object ImeTrim {
    /**
     * Ẩn liền bấy lâu ⇒ nhả dữ liệu nạp lại được. 3 phút (trước 45 s — RAM-AUDIT #6): 45 s làm
     * người gõ ngắt quãng (chat) parse lại enlexicon 1.4 MB + giải lại weights FUTO gần như mỗi
     * lần mở bàn phím; 3 phút vẫn trả RAM khi thực sự thôi gõ.
     */
    const val IDLE_RELEASE_MS = 180_000L
    private const val RUNNING_LOW = 10
    private const val RUNNING_CRITICAL = 15
    private const val BACKGROUND = 40

    /** Thiếu RAM thật (RUNNING_LOW/CRITICAL — API < 34 — hoặc BACKGROUND+); UI_HIDDEN (20) thì không. */
    fun releaseFuto(level: Int): Boolean = level in RUNNING_LOW..RUNNING_CRITICAL || level >= BACKGROUND

    /** Nhả như hẹn giờ ẩn: BACKGROUND+ và bàn phím đang ẩn. */
    fun releaseIdle(level: Int, inputShown: Boolean): Boolean = level >= BACKGROUND && !inputShown
}
