package com.viettelex.android.ime

import android.animation.ValueAnimator
import android.annotation.SuppressLint
import android.content.Context
import android.graphics.Canvas
import android.graphics.Paint
import android.os.SystemClock
import android.view.Choreographer
import android.view.MotionEvent
import android.view.View
import android.view.animation.DecelerateInterpolator
import com.viettelex.android.R
import com.viettelex.keyboard.CommaPopup
import com.viettelex.keyboard.PixelKeys
import com.viettelex.keyboard.Soundhole
import com.viettelex.keyboard.SpaceSideKey
import com.viettelex.keyboard.SymbolReturn
import com.viettelex.keyboard.KeyLabelSize
import com.viettelex.keyboard.KeyLabelFitter
import com.viettelex.keyboard.DomainPopup
import com.viettelex.keyboard.EmojiKeyAction
import com.viettelex.keyboard.EmojiKeyMenu
import com.viettelex.keyboard.KeyAlternates
import com.viettelex.keyboard.KeyVariants
import com.viettelex.keyboard.ShiftHold
import com.viettelex.keyboard.SuggestionCase
import com.viettelex.keyboard.EmojiSearch
import com.viettelex.keyboard.EmojiSearchSession
import com.viettelex.keyboard.GestureClassifier
import com.viettelex.keyboard.Key
import com.viettelex.keyboard.KeyCommand
import com.viettelex.keyboard.KeyCommandGesture
import com.viettelex.keyboard.KeyCommitQueue
import com.viettelex.keyboard.KeyboardLanguage
import com.viettelex.keyboard.SpaceFlick
import com.viettelex.keyboard.SpaceMark
import com.viettelex.keyboard.SwipeLayout
import com.viettelex.keyboard.SwipePath
import com.viettelex.keyboard.SwipeSuggest
import com.viettelex.keyboard.TemplateItem
import com.viettelex.keyboard.TextTool
import com.viettelex.keyboard.TouchGeometry
import com.viettelex.keyboard.TouchLog
import kotlin.math.abs
import com.viettelex.keyboard.tr

/**
 * Vùng PHÍM của bàn phím (port iOS KeyboardView, phần rows): MỘT View vẽ mọi phím
 * bằng Canvas và là MỘT mặt touch multi-pointer (spec §5). Strip gợi ý và balloon là
 * view anh em riêng ([StripView], [BalloonView]) để gõ chữ KHÔNG ghi lại display
 * list của ~40 phím: phím chữ không đổi hình khi bấm (balloon lo), nên chỉ overlay
 * balloon bị invalidate — lớp phím chỉ vẽ lại khi shift / plane / pressed phím chức
 * năng đổi. "Phím sẫm khi bấm" cũng vẽ ở overlay balloon ([keyPressHighlight]).
 *
 * Không Handler/timer nào chạy khi không có ngón trên phím (0% CPU idle).
 */
@SuppressLint("ViewConstructor")
class KeyboardView(
    context: Context,
    private val theme: ImeTheme,
    private val balloon: BalloonView,
    private val feedback: Feedback,
    /** Vệt gõ vuốt (overlay cùng toạ độ); null = không vẽ ("Hiệu ứng nét vuốt" = Tắt — IME đặt lúc hiện). */
    var trail: SwipeTrailView? = null,
) : View(context) {
    /** "Âm thanh nét vuốt": null = Tắt (IME đặt lúc hiện) ⇒ đường vuốt chỉ đọc một biến null. Gán ⇒ nhận tâm phím hiện có. */
    var swipeSound: SwipeSoundPlayer? = null
        set(v) { field = v; swipeLayout?.let { v?.setLayout(it, d) } }

    interface Listener {
        fun onKey(key: Key)
        /** Ký tự ngay trước con trỏ — chỉ hỏi khi chạm "." "," ":" ở plane 123 / #+= (PlanePolicy). */
        fun charBeforeCursor(): Char? = null
        /** Điểm chạm của phím chữ sắp [onKey] (lệch so với tâm phím, theo cỡ phím) — cho tự sửa. */
        fun onLetterTouch(dx: Float, dy: Float) {}
        /**
         * Trackpad: bước đã gom theo frame (≤ 1 lần/frame). Mặc định = phím MoveCursor;
         * IME dời con trỏ NHẸ (không auto-shift/gợi ý mỗi bước) tới [onTrackpadEnd].
         */
        fun onTrackpadMove(delta: Int, vertical: Boolean) { onKey(Key.MoveCursor(delta, vertical)) }
        /** Nhả trackpad (sau bước cuối): IME cập nhật auto-shift + gợi ý một lần. */
        fun onTrackpadEnd() {}
        /** Trackpad trong lúc GIỮ ⇧: mở rộng vùng chọn [delta] grapheme / dòng (thay vì dời con trỏ). */
        fun onTrackpadSelect(delta: Int, vertical: Boolean) { onTrackpadMove(delta, vertical) }

        // --- "Vuốt phím để sao chép/dán" (chỉ gọi khi [keyCommands] bật) ---
        /** Ô đang có vùng chọn (chạm phím có lệnh: chữ chờ nhấc mới chèn để vùng chọn còn nguyên). */
        fun keyCommandHasSelection(): Boolean = false
        /** Nhãn xem trước khi lệnh vừa bật: tên lệnh, hoặc lý do không chạy được ("Chưa chọn chữ"). */
        fun keyCommandLabel(cmd: KeyCommand): String = tr(cmd.label)
        /** Nhấc tay lúc lệnh đang bật. [letterDeferred] = chữ của phím CHƯA chèn (không phải huỷ). */
        fun onKeyCommand(cmd: KeyCommand, letterDeferred: Boolean) {}
        /** Vuốt nhanh phím cách (chỉ khi [configureSpaceFlick] bật): đổi Tiếng Việt ↔ Tiếng Anh. */
        fun onSpaceFlick() {}
        /** Giữ ⌫ > 3 s — xoá theo từ. */
        fun onDeleteWord()
        /** Vuốt trái trên ⌫ vừa vượt ngưỡng; false ⇒ không hỗ trợ ở ô này (bỏ lượt vuốt). */
        fun onSwipeDeleteStart(): Boolean
        /** Số từ muốn chọn theo quãng kéo; trả số từ thực chọn. */
        fun onSwipeDeleteUpdate(words: Int): Int
        /** Nhấc tay ([commit]) hoặc huỷ (ACTION_CANCEL / bàn phím ẩn). */
        fun onSwipeDeleteEnd(commit: Boolean)
        fun onGlobe(longPress: Boolean)
        /** Gõ giọng nói: mục 🎤 menu giữ 😊 (TalkBack: giữ lâu ","), chỉ khi [setVoiceAvailable]. */
        fun onVoiceInput()
        /** Nút 📋 đầu bảng ☰ (#175): mở lịch sử clipboard (IME tự đóng bảng ☰). */
        fun onToggleClipboard() {}
        /** Mục ✋ menu giữ 😊: bật/tắt một tay (IME nhớ bên cũ). */
        fun onToggleOneHand()
        /** Mục 🪟 menu giữ 😊: bật/tắt bàn phím thả nổi (#112). */
        fun onToggleFloating() {}
        /** Mục ⚙ menu giữ 😊: mở app VietTelex. */
        fun onOpenSettings()
        fun onDismissKeyboard()
        /** 📋 bàn số (PHONE / NUMPAD): dán clipboard đã lọc theo loại ô. */
        fun onPadPaste() {}
        fun onTemplate(item: TemplateItem)
        fun onOpenTemplates()
        /** Chạm một thao tác công cụ văn bản (Plus) trong lưới mẫu câu. */
        fun onTextTool(tool: TextTool)
        /** Chạm "Dịch" (dịch trên máy, Plus) — lưới công cụ hoặc hàng công cụ bảng sửa. */
        fun onTranslate() {}
        /** Chạm "Thêm dấu" (AddTones, Plus) — lưới công cụ hoặc hàng công cụ bảng sửa. */
        fun onAddTones() {}
        fun onPlaneChanged(plane: Plane)
        /** Recents emoji (đọc/ghi pref). */
        fun emojiRecents(): List<String>
        fun noteEmojiUsed(e: String)

        // --- gõ vuốt (chỉ gọi khi [swipeTyping] bật) ---
        /** Tâm phím a–z theo toạ độ view (đổi cỡ / xoay / plane chữ dựng lại). */
        fun onSwipeLayout(layout: SwipeLayout)
        /** Ngón vừa thành VUỐT (chữ đầu hoãn, chưa chèn — #172). false ⇒ coi như chạm (bỏ vuốt). */
        fun onSwipeTypingStart(): Boolean
        /** Nhấc tay: [path] toạ độ view (đã dời điểm chọn như hit-test), [case] theo shift. */
        fun onSwipeTypingEnd(path: SwipePath, case: SwipeSuggest.Case)
        /** Huỷ (ACTION_CANCEL / bàn phím ẩn) sau khi cú vuốt đã bắt đầu. */
        fun onSwipeTypingCancel()

        // --- bảng sửa văn bản / một tay ---
        /** Ô bảng sửa (trừ SELECT/CLOSE — view tự lo); [selecting] = chế độ chọn đang bật. */
        fun onEditAction(action: EditAction, selecting: Boolean)
        /** Rail / nút một tay đổi chế độ — IME lưu prefs rồi gọi lại [setOneHand]. */
        fun onOneHandChange(side: OneHandSide)
        /** Shift/Caps Lock vừa đổi (tay, đầu câu, nhả sau một chữ, rời plane chữ…) — bar gợi ý theo Shift. */
        fun onShiftChanged() {}
    }

    var listener: Listener? = null

    enum class Shift { OFF, ON, CAPS }

    // --- cấu hình (đặt bởi IME mỗi lần hiện; rebuild khi chữ ký đổi) ---
    var plane = Plane.LETTERS; private set
    var shift = Shift.ON
        private set(v) {
            if (field == v) return
            val old = field
            field = v
            // Đang vuốt: shift đổi tạm quanh cú vuốt — lượt gợi ý sau vuốt tự vẽ lại bar.
            if (!swiping) listener?.onShiftChanged()
            if (old == Shift.CAPS) feedback.shiftChanged(pedalShift(v))   // Piano: Caps tắt ⇒ damper
        }

    private fun pedalShift(s: Shift): com.viettelex.keyboard.PianoPedal.Shift = when (s) {
        Shift.OFF -> com.viettelex.keyboard.PianoPedal.Shift.OFF
        Shift.ON -> com.viettelex.keyboard.PianoPedal.Shift.ON
        Shift.CAPS -> com.viettelex.keyboard.PianoPedal.Shift.CAPS
    }
    private var returnLabel = "return"
    private var inputKind = InputKind.NORMAL
    private var needsGlobe = false
    private var showLogo = true
    /** Ô phóng to chữ khi bấm (Keys.KEY_PREVIEW); tắt ⇒ không show balloon phím chữ/ký tự. */
    var keyPreview = true

    /**
     * "Phím sẫm khi bấm" (Keys.KEY_PRESS_HIGHLIGHT, IME đặt mỗi lần hiện — đọc 1 lần): phím chữ /
     * số / ký hiệu (LETTER, CHAR) sẫm khi đè; "," "." bàn số đã sẫm sẵn (k.pressed). Trạng thái
     * + vẽ ở [BalloonView.press] ⇒ không ghi lại display list phím. TẮT ⇒ [pressHL] null, đường
     * chạm chỉ còn một phép so null.
     */
    var keyPressHighlight: Boolean
        get() = pressHL != null
        set(v) {
            if (v == (pressHL != null)) return
            if (!v) balloon.clearPress()
            pressHL = if (v) balloon.press else null
        }
    private var pressHL: KeyPressHighlight? = null

    private fun pressDown(pid: Int, k: LaidKey) {
        val p = pressHL ?: return
        val y = top.toFloat()
        if (p.down(pid, k.left, k.top + y, k.right, k.bottom + y)) balloon.invalidatePress(pid)
    }

    private fun pressUp(pid: Int) {
        val p = pressHL ?: return
        if (p.up(pid)) balloon.invalidatePress(pid)
    }

    // --- giữ phím chữ ra ký tự phụ (KeyAlternates, issue #98) ---
    /** Bảng đang dùng (IME đặt theo cài đặt + hàng số + TalkBack). Rỗng ⇒ không nhãn, không hẹn giờ. */
    private var alts: Map<Char, String> = emptyMap()
    fun setAlternates(map: Map<Char, String>) {
        if (map == alts) return
        alts = map
        dropAlt()
        if (plane == Plane.LETTERS || plane == Plane.EMOJI_SEARCH) invalidate()
    }
    /** "Giữ Shift để gõ số và ký hiệu" ([ShiftHold], [KeyAlternates.shiftMap]) — rỗng khi tắt. */
    private var shiftAlts: Map<Char, String> = emptyMap()
    fun setShiftAlternates(map: Map<Char, String>) { shiftAlts = map }
    /** "Vuốt phím xuống ra ký tự phụ" ([KeyAlternates.flickDownEnabled]) — IME đặt theo cài đặt. */
    var flickDownSetting = false
    private var flickPid = -1
    private var flickX0 = 0f
    private var flickY0 = 0f
    private var altHold: KeyAlternates.Hold? = null
    private var altPid = -1
    private var altKey: LaidKey? = null
    private var altShiftWas = Shift.OFF
    private val altRun = Runnable { fireAlt() }
    private var templatesEnabled = true
    /**
     * Mẫu câu: nguồn LƯỜI — chỉ gọi khi bảng ☰ thật sự mở ([syncTemplatesPane]); bảng đóng thì không đọc /
     * giải YAML, không cắt "…" từng mẫu trước khung đầu (docs/PERF-IME-SHOW.md, đợt 10/11/2026).
     */
    private var templates: () -> List<TemplateItem> = { emptyList() }
    /** Nội dung lưới mẫu câu cần dựng lại (nguồn / công cụ / chế độ đổi) — làm ở lần mở bảng kế. */
    private var templatesPaneStale = true

    // --- popup nhiều lựa chọn kiểu stock iOS (DomainPopup / KeyVariants) ---
    // Giữ "." bàn chữ ô URL / email ⇒ đuôi tên miền; giữ "," bàn chữ ⇒ dấu câu (CommaPopup);
    // giữ 😊 ⇒ menu icon (EmojiKeyMenu, cuối file); giữ phím bàn số / ký hiệu ⇒ biến thể
    // (" → ” “ „ » «, $ → ₫ € …). Ô gốc chọn sẵn, trượt chọn, nhấc chèn, trượt xa huỷ.
    /** IME tắt khi TalkBack / touch exploration (giữ là cử chỉ của trình đọc). */
    var popoversEnabled = true
        set(v) { if (field != v) { field = v; if (!v) { dropPopover(); dropEmojiMenu() }; invalidate() } }
    private var popHold: DomainPopup.Hold? = null
    private var popPid = -1
    private var popKey: LaidKey? = null
    private var popVariants = false
    private var popX = 0f
    private var popY = 0f
    private val popRun = Runnable { firePopover() }

    /**
     * Công cụ văn bản (PlusGate TEXT_TOOLS) — hai lối vào: hàng công cụ cuối bảng sửa văn
     * bản (EditPanel, ô [EditPanel.TOOL_PREFIX]…, gọi thẳng [Listener.onTextTool] và ở lại
     * bảng) và chip đầu lưới mẫu câu (☰). Đổi cờ ⇒ chữ ký layout đổi ⇒ bảng sửa dựng lại.
     */
    var textToolsEnabled = false
        set(v) {
            if (field != v) {
                field = v; if (!v && !translateEnabled) textToolsMode = false
                closeEmptyToolsOnly()
                refreshTemplatesPane()
                if (plane == Plane.EDIT) rebuild()
            }
        }
    private var textToolsMode = false

    /** "Dịch" trên máy (PlusGate TRANSLATE) — thêm vào cùng hai lối vào với công cụ văn bản. */
    var translateEnabled = false
        set(v) {
            if (field != v) {
                field = v; if (!v && !textToolsEnabled) textToolsMode = false
                closeEmptyToolsOnly()
                refreshTemplatesPane()
                if (plane == Plane.EDIT) rebuild()
            }
        }

    /** Ô ☰ (TemplatesMenu): mẫu câu / chỉ công cụ (Mẫu câu tắt) / ẩn. */
    val leftZone get() = TemplatesMenu.leftZone(templatesEnabled, textToolsEnabled || translateEnabled)

    /** Chỉ-công-cụ đang mở mà công cụ vừa tắt ⇒ lưới rỗng: về bàn phím chữ. */
    private fun closeEmptyToolsOnly() {
        if (plane == Plane.TEMPLATES && leftZone == TemplatesMenu.LeftZone.NONE) setPlane(Plane.LETTERS)
    }

    private fun refreshTemplatesPane() {
        templatesPaneStale = true
        if (plane == Plane.TEMPLATES) rebuild()
    }

    /** Bảng ☰ đang hiện: nạp mẫu câu (lần đầu) + đặt chip. Bảng khác ⇒ không gọi. */
    private fun syncTemplatesPane() {
        if (!templatesPaneStale) return
        templatesPaneStale = false
        val p = TemplatesMenu.pane(textToolsMode, templatesEnabled, textToolsEnabled, translateEnabled)
        templatesPane.setItems(if (p.showTemplates) templates() else emptyList())
        templatesPane.setExtras(p.tools, gear = p.gear, segmented = p.segmented, toolsTab = p.tab == TemplatesMenu.Tab.TOOLS)
        templatesPane.setQuick(TemplatesMenu.quick(clipAvailable, voiceAvailable))
        templatesPane.setListMode(templatesAsList)
    }
    /** "Hiện mẫu câu theo dòng" (#175): bảng ☰ mỗi mẫu một dòng, nhãn + nội dung. */
    var templatesAsList = false
        set(v) { if (field != v) { field = v; refreshTemplatesPane() } }
    /** Lịch sử clipboard đang bật ⇒ bảng ☰ có nút 📋 (#175). IME đặt cùng nút 📋 của thanh gợi ý. */
    var clipAvailable = false
        set(v) { if (field != v) { field = v; refreshTemplatesPane() } }
    var keyAreaPx = theme.dp(218f); private set

    private var keys: List<LaidKey> = emptyList()
    private var builtSig = ""
    private var planeCache = HashMap<Plane, List<LaidKey>>()
    /**
     * Cache bố cục HAI TẦNG: chữ ký (loại ô, nhãn Enter, bề ngang, …) → plane → phím đã xếp. Giữ
     * [LAYOUT_SIGS] chữ ký gần nhất (LRU) ⇒ qua lại giữa các ô quen (chat ↔ tìm kiếm ↔ URL) hay xoay
     * máy rồi xoay lại không dựng lại bố cục. Vài chục LaidKey mỗi plane — RAM không đáng kể.
     */
    private val layoutCache = object : LinkedHashMap<String, HashMap<Plane, List<LaidKey>>>(8, 0.75f, true) {
        override fun removeEldestEntry(eldest: MutableMap.MutableEntry<String, HashMap<Plane, List<LaidKey>>>) =
            size > LAYOUT_SIGS
    }

    private val commits = KeyCommitQueue()
    /** Chạm / chạm đôi / GIỮ ⇧ (THUẦN, ShiftHoldTests). */
    private val shiftHold = ShiftHold()
    private var lastSpaceTap = 0L

    // --- pointer → phím (id pointer ≤ 31) ---
    private val ptrKey = arrayOfNulls<LaidKey>(MAX_PTR)
    private val ptrDownX = FloatArray(MAX_PTR)
    private val ptrDownY = FloatArray(MAX_PTR)
    /** Pointer đang thuộc pane emoji/mẫu câu thay vì phím. */
    private val ptrPane = BooleanArray(MAX_PTR)
    /** Pointer chạm xuống trong dải cử chỉ hệ thống trái/phải (EdgeTouch): chữ / ⌫ chờ nhấc, huỷ ⇒ bỏ. */
    private val ptrEdge = BooleanArray(MAX_PTR)
    /** Shift lúc chạm của pointer mép (huỷ ⇒ trả Shift một-lần đã nhả). */
    private val ptrEdgeShiftOn = BooleanArray(MAX_PTR)
    private val edgeLoc = IntArray(2)
    private var balloonOwner: LaidKey? = null

    // --- paint (tạo 1 lần) ---
    private val d = theme.density
    private val radius = theme.dp(KeyLayout.KEY_RADIUS)
    private val facePaint = theme.fill(theme.keyFill)
    /** Viền 1dp (theme tương phản cao / kính) — stroke thường, không offscreen. */
    private val borderPaint = theme.keyBorder?.let { c ->
        Paint(Paint.ANTI_ALIAS_FLAG).apply { color = c; style = Paint.Style.STROKE; strokeWidth = theme.dp(1f) }
    }
    // Gboard: chữ 22 sp regular, nhãn chức năng 14 sp medium (font hệ thống sans-serif).
    // "Cỡ chữ trên phím" = Lớn ⇒ [applyLabelSize] đổi textSize (lúc cấu hình, không mỗi phím).
    private val letterPaint = theme.text(LETTER_SP)
    private val controlPaint = theme.text(CONTROL_SP, color = theme.fnInk, medium = true)
    private val badgePaint = theme.text(14f, color = theme.spaceInk, medium = true)
    private val iconPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = theme.ink }
    private var letterOff = theme.centerOffset(letterPaint)
    private var controlOff = theme.centerOffset(controlPaint)
    /** Nhãn chữ bảng sửa — [fitEditLabels]. */
    private val editPaint = Paint(Paint.ANTI_ALIAS_FLAG)
    private var editOff = 0f
    private val digitPaint = theme.text(DIGIT_SP)
    private var digitOff = theme.centerOffset(digitPaint)
    private val sidePaint = theme.text(SIDE_SP)
    private var sideOff = theme.centerOffset(sidePaint)
    private val hintPaint = theme.text(HINT_SP, medium = true)
    private var hintOff = theme.centerOffset(hintPaint)
    /** Tuỳ chỉnh nâng cao (Plus): phông/độ đậm nhãn phím — đặt MỘT lần ở đây (null = như cũ). */
    private val styledLabels = theme.keyStyle.customizesLabels
    init {
        theme.keyTypeface?.let { tf ->
            for (p in arrayOf(letterPaint, controlPaint, digitPaint, sidePaint, hintPaint)) p.typeface = tf
            letterOff = theme.centerOffset(letterPaint); controlOff = theme.centerOffset(controlPaint)
            digitOff = theme.centerOffset(digitPaint); sideOff = theme.centerOffset(sidePaint)
            hintOff = theme.centerOffset(hintPaint)
        }
    }
    /** Hệ số icon trên phím (⇧ ⌫ 😊 🌐 ↵ …) theo "Cỡ chữ trên phím". */
    private var iconScale = 1f
    private val largeHintDrop = theme.dp(2f)
    private var labelSize = KeyLabelSize.DEFAULT
    /** Thanh "Cỡ chữ trên phím" (Plus) đã áp cho paint (một lần mỗi view). */
    private var labelStyleApplied = false
    /** Cỡ chữ cái đã kẹp theo bề ngang phím chữ hẹp nhất (px) — chỉ tính lại khi đổi. */
    private var fittedKeyW = -1f
    private val hintLift = theme.dp(6f)
    private val hintDrop = theme.dp(12f)
    private val keyPressed = theme.pressed(theme.keyFill)
    private val specialPressed = theme.pressed(theme.fnFill)
    private val spacePressed = theme.pressed(theme.spaceFill)
    private val actionPressed = theme.blend(theme.action, theme.actionInk, 0.12f)
    /** Skin phím của theme (ảnh 9-slice tải về) theo vai [ThemeKeyRole]; null = vẽ màu như cũ (không đọc gì). */
    private val skins: Array<LoadedSkin?>? = theme.assets?.skins
    private val skinPainter: SkinPainter? = if (skins != null) SkinPainter() else null
    /**
     * Dáng phím điểm ảnh (theme JSON "keyShape":"pixel" — [PixelKeys], iOS cùng hình học): vài hình chữ nhật RỜI NHAU mỗi
     * phím (viền + bóng màu viền, lõi màu phím), không khử răng cưa, mảng ghi sẵn ⇒ 0 cấp phát mỗi khung. Theme khác:
     * null ⇒ đường bo góc cũ y nguyên.
     */
    private val pixelRects: FloatArray? = if (theme.pixelKeys) FloatArray(PixelKeys.FLOATS) else null
    private val pixelPaint: Paint? = if (theme.pixelKeys) Paint().apply { style = Paint.Style.FILL } else null
    private val pixelInk: Int = theme.keyBorder?.takeIf { android.graphics.Color.alpha(it) > 0 } ?: theme.ink
    /**
     * Ô kính màu ("keyShape":"glass" — [com.viettelex.keyboard.GlassKeys], iOS cùng màu): mặt màu theo chữ + MỘT shader
     * gradient trong (ma trận đặt lại mỗi phím, không cấp phát) + viền chì. Theme khác: null ⇒ đường cũ y nguyên.
     */
    private val glassFill: Paint? = if (theme.glassKeys) Paint(Paint.ANTI_ALIAS_FLAG).apply { style = Paint.Style.FILL } else null
    private val glassSheen: Paint? = if (theme.glassKeys) Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.FILL
        shader = android.graphics.LinearGradient(0f, 0f, 0f, 1f,
            intArrayOf(android.graphics.Color.argb((255 * com.viettelex.keyboard.GlassKeys.HIGHLIGHT).toInt(), 255, 255, 255),
                0x00FFFFFF, android.graphics.Color.argb((255 * com.viettelex.keyboard.GlassKeys.SHADE).toInt(), 0, 0, 0)),
            floatArrayOf(0f, 0.55f, 1f), android.graphics.Shader.TileMode.CLAMP)
    } else null
    private val glassLead: Paint? = if (theme.glassKeys) Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.STROKE
        color = theme.keyBorder?.takeIf { android.graphics.Color.alpha(it) > 0 } ?: (com.viettelex.keyboard.GlassKeys.LEAD or (0xFF shl 24))
    } else null
    private val glassMatrix: android.graphics.Matrix? = if (theme.glassKeys) android.graphics.Matrix() else null
    // Logo Vᴛ mờ ở góc phải phím space như iOS (thay nhãn "Tiếng Việt").
    private val logoPaint = Paint(Paint.ANTI_ALIAS_FLAG or Paint.FILTER_BITMAP_FLAG).apply {
        colorFilter = android.graphics.PorterDuffColorFilter(theme.withAlpha(theme.spaceInk, 0.16f), android.graphics.PorterDuff.Mode.SRC_IN)
    }
    private val logo: android.graphics.Bitmap? by lazy { android.graphics.BitmapFactory.decodeResource(resources, R.drawable.ime_space_logo) }
    private val logoEn: android.graphics.Bitmap? by lazy { android.graphics.BitmapFactory.decodeResource(resources, R.drawable.ime_space_logo_en) }
    private val logoRect = android.graphics.RectF()
    /** Mã "VI"/"EN" góc dưới-phải phím cách khi bật vuốt đổi ngôn ngữ (SpaceMark) — mờ như stock. */
    private val codeColor = theme.withAlpha(theme.spaceInk, 0.45f)
    private val codePaint = theme.text(if (theme.tablet) 12f else 10.5f, color = codeColor, medium = true,
        align = Paint.Align.RIGHT)

    /**
     * Chọn phím theo ngữ cảnh (thử nghiệm, SmartTouch): IME trả P(phím | từ đang gõ) lúc
     * chạm, null = không biết / tắt. null (mặc định) ⇒ router gần-nhất như cũ.
     */
    var letterPrior: (() -> ((Char) -> Float?)?)? = null

    // --- gõ vuốt ---
    /** IME bật khi setting + loại ô + không TalkBack. Tắt ⇒ không tính layout, không theo dõi ngón. */
    var swipeTyping = false
        set(v) {
            if (field == v) return
            field = v
            if (v) publishSwipeLayout() else { abortSwipe(); swipeLayout = null; swipePath = null }
        }
    private val classifier = GestureClassifier()
    private var swipePid = -1
    private var swiping = false
    private var swipeShift = Shift.OFF
    private var swipeKey: LaidKey? = null
    private var swipePath: SwipePath? = null
    private var swipeLayout: SwipeLayout? = null
    private var lastLetterDownT = Long.MIN_VALUE / 2

    // --- vuốt phím chữ thẳng lên ⇒ lệnh (KeyCommandGesture, Keys.SWIPE_KEY_COMMANDS) ---
    /** IME đặt theo cài đặt (tắt khi TalkBack). Tắt ⇒ một phép so bool mỗi chạm phím chữ. */
    var keyCommands = false
        set(v) { if (field != v) { field = v; if (!v) endKeyCmd() } }
    private var keyCmd: KeyCommandGesture? = null
    private var keyCmdPid = -1
    private var keyCmdDeferred = false
    private var keyCmdShiftWas = Shift.OFF
    private var keyCmdShown = false
    /** Giữ ⇧ (ngón đang đè phím shift) — trackpad thành chọn chữ. */
    private var shiftPtr = -1
    private fun toCase(s: Shift) = when (s) {
        Shift.OFF -> SuggestionCase.Shift.OFF; Shift.ON -> SuggestionCase.Shift.ONCE; Shift.CAPS -> SuggestionCase.Shift.CAPS_LOCK
    }
    private fun fromCase(s: SuggestionCase.Shift) = when (s) {
        SuggestionCase.Shift.OFF -> Shift.OFF; SuggestionCase.Shift.ONCE -> Shift.ON; SuggestionCase.Shift.CAPS_LOCK -> Shift.CAPS
    }
    private var trackpadSelect = false
    private val yOffPx = TouchGeometry.yOffset * d

    internal val emojiPane = EmojiPane(this, theme, feedback)
    // Tìm emoji (27/09/2026): plane EMOJI_SEARCH = ô tìm + plane chữ; phím vào [search]
    // (Telex riêng), không tới ô nhập. return / 😊 → về lưới emoji; ?123 → plane số.
    private val searchBar = EmojiSearchBar(this, theme)
    private var search = EmojiSearchSession()
    /** Cài đặt engine cho ô tìm (IME đặt mỗi lần hiện). */
    var searchSettings = com.viettelex.keyboard.KeyboardSettings()
    private val templatesPane = TemplatesPane(this, theme, feedback)

    // --- trackpad / giữ phím ---
    private var trackpad = false
    private var spaceKey: LaidKey? = null
    /** Phím cách ngón [spacePtr] đang giữ (tách đôi: một trong hai phím cách). */
    private var spaceDownKey: LaidKey? = null
    private var trackpadGesture = TrackpadGesture()
    /** "Độ nhạy con trỏ" — IME đặt lúc dựng bàn phím (KeyboardSettings); áp khi bắt đầu kéo. */
    var trackpadSpeed = com.viettelex.keyboard.TrackpadSpeed.DEFAULT
    /** Gom bước theo frame: ≤ 1 lệnh dời con trỏ (IPC) mỗi vsync. */
    private val trackpadBatch = TrackpadBatcher()
    private var trackpadFramePosted = false
    private val trackpadFrame = Choreographer.FrameCallback {
        trackpadFramePosted = false
        trackpadBatch.drain()?.let { sendTrackpadStep(it) }
    }
    private var spacePtr = -1
    private var bsPtr = -1
    private var bsHoldStart = 0L
    private var bsTick = 0
    private var bsRepeating = false
    /** Vuốt ⌫: 0 chưa, 1 đang vuốt, -1 ô không hỗ trợ (lượt này). */
    private var bsSwipe = 0
    private var bsSwipeAsked = 0
    private var bsSwipeWords = 0
    private var globePtr = -1
    private var globeFired = false
    private val slop = theme.dp(10f)   // allowableMovement của UILongPressGestureRecognizer

    private val spaceHoldRun = Runnable { beginTrackpad() }
    private val bsStartRun = Runnable {
        ptrKey.getOrNull(bsPtr)?.let { commits.release(it) }   // ⌫ chạm ở mép: giữ lâu ⇒ chốt lần đầu
        bsRepeating = true; bsHoldStart = SystemClock.uptimeMillis(); bsTick = 0
        postDelayed(bsTickRun, BS_INTERVAL)
    }
    private val bsTickRun = object : Runnable {
        override fun run() {
            val held = SystemClock.uptimeMillis() - bsHoldStart
            if (held > 3000 && plane != Plane.EMOJI_SEARCH) {
                bsTick++
                if (bsTick % 4 == 1) listener?.onDeleteWord()
            } else {
                emit(Key.Backspace)
                if (held > 1600) emit(Key.Backspace)
            }
            postDelayed(this, BS_INTERVAL)
        }
    }
    private val hintInset = theme.dp(9f)
    private var switcherHint = false
    fun setSwitcherHint(on: Boolean) {
        if (on == switcherHint) return
        switcherHint = on
        keys.firstOrNull { it.kind == KeyKind.EMOJI }?.let { invalidateKey(it) }
    }
    private val globeLongRun = Runnable { globeFired = true; listener?.onGlobe(true) }

    // --- giữ lâu "," = gõ giọng nói (kiểu Gboard; chỉ khi có IME giọng nói) ---
    private var voiceAvailable = false
    private var commaPtr = -1
    private var commaKey: LaidKey? = null
    private val voiceLongRun = Runnable {
        val k = commaKey ?: return@Runnable
        commits.disarm(k)                 // không chèn "," khi nhấc tay
        commaPtr = -1
        listener?.onVoiceInput()
    }
    fun setVoiceAvailable(on: Boolean) {
        if (on == voiceAvailable) return
        voiceAvailable = on
        refreshTemplatesPane()
        keys.firstOrNull { it.kind == KeyKind.PUNCT && it.label == "," }?.let { invalidateKey(it) }
    }
    // Popup bật (không TalkBack): giữ "," = popup dấu câu (CommaPopup); hai hành vi cũ dưới chỉ còn cho TalkBack.
    /** "," bàn chữ có popup dấu câu (không TalkBack). */
    private fun isCommaPopup(k: LaidKey) = popoversEnabled && plane == Plane.LETTERS && k.kind == KeyKind.PUNCT && k.label == ","
    /** "." cạnh space (Dấu chấm) có popup dấu câu ("," chọn sẵn) — như [isCommaPopup]. */
    private fun isPeriodPopup(k: LaidKey) = periodSideKey && popoversEnabled && plane == Plane.LETTERS && k.kind == KeyKind.PUNCT && k.label == "."
    private fun isVoiceComma(k: LaidKey) = !popoversEnabled && voiceAvailable && plane == Plane.LETTERS && k.kind == KeyKind.PUNCT && k.label == ","
    // --- giữ "," ra "." (KeyAlternates.commaHold: bảng ký tự phụ không rỗng) — chỉ khi "," KHÔNG
    // phải phím giọng nói (có IME giọng nói ⇒ giữ nguyên hành động cũ, không ra ".") ---
    private var periodFired = false
    private fun isPeriodComma(k: LaidKey) =
        !popoversEnabled && plane == Plane.LETTERS && k.kind == KeyKind.PUNCT && k.label == "," && KeyAlternates.commaHold(alts, voiceAvailable)
    /** Hết giờ mà "," còn chờ chốt ⇒ đổi thành "." (chốt lúc nhấc / khi ngón khác chạm, như ","). */
    private val periodRun = Runnable {
        val k = commaKey ?: return@Runnable
        if (!KeyAlternates.holdComma(commits, k, ::textFire)) return@Runnable
        periodFired = true
        feedback.longPress(this)
        showBalloon(k, KeyAlternates.COMMA_ALT)
    }
    private fun cancelCommaHold() {
        if (commaPtr < 0) return
        removeCallbacks(voiceLongRun); removeCallbacks(periodRun)
        if (periodFired) commaKey?.let { hideBalloon(it) }
        periodFired = false
        commaPtr = -1; commaKey = null
    }

    /** Ô cho giữ lâu Enter = xuống dòng thật (IME đặt theo [FieldConfig.holdNewline]). */
    var holdNewline = false
    private var returnPtr = -1
    private val returnHoldRun = Runnable {
        val k = ptrKey.getOrNull(returnPtr)
        // Ngón khác chạm xuống đã flush (chốt) phím Enter ⇒ không còn là giữ lâu.
        if (k == null || k.kind != KeyKind.RETURN || !commits.isArmed(k)) return@Runnable
        commits.disarm(k)                 // nhả tay KHÔNG gửi action
        feedback.longPress(this)
        showBalloon(k, "↵")
        emit(Key.LineBreak)
    }

    // --- badge "ViệtTelex" ---
    private var badgeAlpha = 0f
    private var badgeAnim: ValueAnimator? = null
    private val badgeText = context.getString(R.string.ime_badge)

    private val spaceFire: () -> Unit = {
        val now = SystemClock.uptimeMillis()
        // Bàn số: space luôn literal (không double-space → ". ").
        val pad = plane == Plane.PHONE || plane == Plane.NUMPAD
        val dbl = !pad && now - lastSpaceTap < DOUBLE_SPACE_MS
        if (dbl) feedback.sentenceEnd()           // ". " tự chèn = kết câu ⇒ vòng hợp âm cách (Piano / Ghi-ta) về đầu
        emit(if (dbl) Key.DoubleSpacePeriod else Key.Space)
        lastSpaceTap = now
    }
    private val newlineFire: () -> Unit = { emit(Key.Newline) }
    /** Phím CHAR: hàng số trên plane chữ chốt xong nhả Shift một-lần (#143) — lúc CHỐT, không lúc chạm. */
    private fun charFire(k: LaidKey) = if (plane == Plane.LETTERS) lettersCharFire(k.insert) else textFire(k.insert)
    private val textFires = HashMap<String, () -> Unit>()
    private fun textFire(s: String) = textFires.getOrPut(s) { val k = Key.Text(s); { emit(k) } }
    private val lettersCharFires = HashMap<String, () -> Unit>()
    /** Phím CHAR arm trên plane chữ (hàng số): chèn rồi nhả Shift một-lần như phím chữ (#143). */
    private fun lettersCharFire(s: String) = lettersCharFires.getOrPut(s) {
        val k = Key.Text(s)
        val fire: () -> Unit = {
            emit(k)
            val next = PlanePolicy.shiftAfterCharKey(Plane.LETTERS, shift)
            if (next != shift) { shift = next; invalidate() }
        }
        fire
    }

    /**
     * "Hiệu ứng khi bấm phím" ([KeyEffectView], Plus) — null = tắt (mặc định): đường phím chỉ đọc một
     * biến null. Bật: lúc chạm ghi tâm phím ([fxMark]); [emit] chèn chữ TRƯỚC rồi mới báo overlay.
     */
    var effects: KeyEffectView? = null
        set(v) { field = v; fxPending = false }
    /** "Sàn nhảy LED": phím cách (hết một từ) ⇒ flash nền ([BeatFlashView.kick]). null = kiểu khác (0 chi phí). */
    var onBeat: (() -> Unit)? = null
    /** "Mắt AI": tâm phím vừa chạm (toạ độ view cha) — IME đặt khi nhân vật là Mắt AI; null = 0 chi phí. */
    var eyeLook: ((Float, Float) -> Unit)? = null
    private var fxPending = false
    private var fxX = 0f
    private var fxY = 0f
    private var fxW = 0f
    private var fxH = 0f
    /** Phím sáng: chữ đang hiện trên phím vừa chạm + paint nhãn của nó (kiểu khác ⇒ null). */
    private var fxGlyph: String? = null
    private var fxGlyphPaint: Paint? = null

    /** "Đèn rọi" (theme "photoFx":"spotlight", [SpotlightView]) — null = theme khác: đường phím chỉ đọc một biến null. */
    var spotlight: SpotlightView? = null
        set(v) { field = v; fxPending = false }

    private fun fxMark(k: LaidKey) {
        hueMarked = hueFill != null
        if (effects == null && spotlight == null && hueFill == null) return
        fxPending = when (k.kind) {
            KeyKind.LETTER, KeyKind.CHAR, KeyKind.PAD, KeyKind.PUNCT, KeyKind.SPACE -> true
            KeyKind.RETURN -> effects?.effect == com.viettelex.keyboard.KeyEffect.GOAL   // Sút!: Enter sút bóng
            else -> false
        }
        // Toạ độ view CHA (ImeRootView) = toạ độ phím + vị trí view này; overlay trừ gốc của chính nó lúc bắn.
        fxX = (k.left + k.right) / 2f + left
        fxY = (k.top + k.bottom) / 2f + top
        // Chỉ TOẠ ĐỘ + cỡ phím: hiệu ứng (vd mảnh vỡ Tia sét) vẽ trên overlay, không đụng phím thật.
        fxW = k.right - k.left; fxH = k.bottom - k.top
        // Phím sáng: chữ + paint nhãn đúng như đang vẽ (kiểu khác ⇒ chỉ một phép so sánh).
        if (effects?.effect == com.viettelex.keyboard.KeyEffect.KEYGLOW) {
            fxGlyph = when (k.kind) {
                KeyKind.LETTER -> if (shift == Shift.OFF) k.label else k.upper
                KeyKind.CHAR, KeyKind.PUNCT, KeyKind.PAD -> k.label
                else -> null
            }
            fxGlyphPaint = if (k.kind == KeyKind.PAD && k.hint.isEmpty()) (if (k.side) sidePaint else digitPaint)
                else if (k.kind == KeyKind.PAD) digitPaint else letterPaint
        } else {
            fxGlyph = null
        }
    }

    /** Sau khi phím đã tới IME: chữ / ký tự / dấu cách mới mang hiệu ứng. */
    private fun fxAfter(k: Key) {
        if (!fxPending) return
        fxPending = false
        if (k == Key.Space || k == Key.DoubleSpacePeriod) onBeat?.invoke()   // Sàn nhảy LED: flash nền ở phím cách
        if (isReturnKey(k)) { effects?.let { it.burst(fxX - it.left, fxY - it.top, fxW, fxH, isReturn = true) }; return }
        if (k is Key.Letter || k is Key.Text || k == Key.Space || k == Key.DoubleSpacePeriod) {
            effects?.let {
                val g = fxGlyph
                if (g != null) fxGlyphPaint?.let { p -> it.keyGlowStyle(p.textSize, p.typeface) }
                it.burst(fxX - it.left, fxY - it.top, fxW, fxH, glyph = g)
            }
            spotlight?.let { it.light(fxX - it.left, fxY - it.top, fxW) }   // Đèn rọi: theme khác ⇒ null
        }
    }

    /** "Laser": khung phím cách theo toạ độ [target] (con của cùng view cha) vào [out]; false ⇒ không có phím cách. O(1). */
    fun spaceKeyFrame(out: android.graphics.RectF, target: View): Boolean {
        val k = spaceKey ?: return false
        if (k.width <= 0f || k.height <= 0f) return false
        val dx = left - target.left; val dy = top - target.top
        out.set(k.left + dx, k.top + dy, k.right + dx, k.bottom + dy)
        return true
    }

    /** Đập chuột (theme "game":"mole", [MoleView]) — null = theme khác: đường phím chỉ đọc một biến null. */
    var mole: MoleView? = null

    /** Phím chữ ⇒ chữ thường a–z; khác ⇒ null. O(1), không cấp phát. */
    private fun moleLetter(k: Key): Char? {
        if (k !is Key.Letter) return null
        val c = k.ch
        return when (c) { in 'a'..'z' -> c; in 'A'..'Z' -> c + 32; else -> null }
    }

    /** Khung phím chữ [c] theo toạ độ [target] (con của cùng view cha) vào [out]; null ⇒ không ở bảng chữ / chưa xếp. */
    fun moleKeyFrame(c: Char, out: android.graphics.RectF, target: View): Float? {
        if (plane != Plane.LETTERS) return null
        val s = c.toString()
        val k = keys.firstOrNull { it.kind == KeyKind.LETTER && it.label == s } ?: return null
        if (k.width <= 0f || k.height <= 0f) return null
        val dx = left - target.left; val dy = top - target.top
        out.set(k.left + dx, k.top + dy, k.right + dx, k.bottom + dy)
        return theme.keyRadius(k.width, k.height, radius)
    }

    /** Viền cầu vồng (theme Gaming RGB, [RainbowBorderView]) — null = theme khác: đường phím chỉ đọc một biến null. */
    var rainbow: RainbowBorderView? = null
    /** Nền đổi sắc "Ảo giác" ([RainbowBorderView] kiểu HUEFLOW_FILL, view anh em) — null = theme khác. */
    var hueFill: RainbowBorderView? = null
    /** Phím vừa chạm có toạ độ cho gợn sóng màu (fxX / fxY) — chỉ khi [hueFill] có. */
    private var hueMarked = false

    /** Viền mọi phím đang hiện (toạ độ view này) thụt [inset] — mặt nạ của [RainbowBorderView]. Bo góc như [drawKey]. */
    fun keyOutlines(out: android.graphics.Path, inset: Float) {
        out.reset()
        for (k in keys) {
            if (k.width <= 2 * inset || k.height <= 2 * inset) continue
            val r = if (k.kind == KeyKind.RETURN && theme.keyStyle.corner == null) minOf(k.width, k.height) / 2
                else theme.keyRadius(k.width, k.height, radius)
            val rr = maxOf(0f, r - inset)
            out.addRoundRect(k.left + inset, k.top + inset, k.right - inset, k.bottom - inset, rr, rr, android.graphics.Path.Direction.CW)
        }
    }

    /** Mọi phím đi qua đây: plane tìm emoji giữ phím cho ô tìm, còn lại tới IME. */
    private fun emit(k: Key) {
        if (plane != Plane.EMOJI_SEARCH) {
            // Plane 123 / #+=: "." "," ":" cần ký tự TRƯỚC khi chèn ("2.5" ở lại) — chỉ đọc cho ba phím đó.
            val sym = k is Key.Text && (plane == Plane.NUMBERS || plane == Plane.SYMBOLS)
            val before = if (sym && PlanePolicy.needsBefore((k as Key.Text).text, symbolReturn)) listener?.charBeforeCursor() else null
            listener?.onKey(k); fxAfter(k); rainbow?.poke()
            hueFill?.let { h -> h.poke(if (hueMarked) fxX - h.left else Float.NaN, fxY - h.top); hueMarked = false }   // Ảo giác
            keyFloat?.let { it.poke(); invalidate() }      // Lơ lửng: khác ⇒ null
            mole?.typed(moleLetter(k), android.os.SystemClock.uptimeMillis() / 1000.0)   // Đập chuột: theme khác ⇒ null
            if (sym) typedInSymbolPlane = true
            // Ký hiệu ⇒ về chữ ngay theo "Về bàn chữ sau ký hiệu" (IME đánh giá lại viết hoa ở onPlaneChanged, như chạm ABC).
            if (sym && PlanePolicy.returnToLettersAfterSymbol((k as Key.Text).text, plane,
                    numericField = inputKind.padPlane != null, before = before, mode = symbolReturn)) setPlane(Plane.LETTERS)
            // Space sau khi đã gõ ở 123 / #+= ⇒ về chữ như iOS (mọi chế độ; ô số ở lại).
            else if ((k == Key.Space || k == Key.DoubleSpacePeriod) && PlanePolicy.returnToLettersOnSpace(plane,
                    typedInSymbolPlane, numericField = inputKind.padPlane != null)) setPlane(Plane.LETTERS)
            return
        }
        fxPending = false
        when (k) {
            is Key.Letter -> search.type(k.ch)
            is Key.Text -> { if (k.replacesLetter) search.backspace(); search.insert(k.text) }
            Key.Space, Key.DoubleSpacePeriod -> search.space()
            Key.Backspace -> search.backspace()
            Key.Newline, Key.LineBreak -> { setPlane(Plane.EMOJI); return }
            else -> return
        }
        refreshSearch()
    }

    private fun refreshSearch() {
        val q = search.query
        searchBar.update(q, if (q.isBlank()) listener?.emojiRecents() ?: emptyList() else EmojiSearch.search(q))
        invalidate()
    }

    internal fun searchClear() {
        feedback.click(Feedback.MODIFIER, this)
        search.clear()
        refreshSearch()
    }

    /** Test/debug: query + kết quả đang hiện của ô tìm. */
    internal val searchState: Pair<String, List<String>> get() = search.query to searchBar.results

    init {
        isHapticFeedbackEnabled = true
    }

    // MARK: trợ năng (TalkBack)

    /** Phím TalkBack vừa kích hoạt — [down] dùng thẳng, không hit-test/chọn phím thông minh. */
    private var a11yKey: LaidKey? = null
    private val a11y = KeyA11yHelper()

    init {
        // TalkBack: mỗi phím là một nút ảo (ExploreByTouchHelper) — chỉ chạy khi dịch vụ trợ năng
        // hỏi (hover / node), 0 chi phí mỗi phím khi tắt.
        androidx.core.view.ViewCompat.setAccessibilityDelegate(this, a11y)
    }

    override fun dispatchHoverEvent(event: MotionEvent): Boolean =
        a11y.dispatchHoverEvent(event) || super.dispatchHoverEvent(event)

    /** Chạm ảo đúng phím [k] (nhấn rồi nhả ở tâm) — cùng đường với ngón tay thật. */
    private fun a11yTap(k: LaidKey) {
        val t = SystemClock.uptimeMillis()
        val pid = MAX_PTR - 1
        val x = k.centerX; val y = k.centerY
        val ev = MotionEvent.obtain(t, t, MotionEvent.ACTION_DOWN, x, y, 0)
        try {
            a11yKey = k
            down(pid, x, y, ev)
        } finally { a11yKey = null; ev.recycle() }
        up(pid, x, y, cancelled = false, t = t)
    }

    private inner class KeyA11yHelper : androidx.customview.widget.ExploreByTouchHelper(this@KeyboardView) {
        private fun keyAt(id: Int): LaidKey? = keys.getOrNull(id)

        override fun getVirtualViewAt(x: Float, y: Float): Int {
            for (i in keys.indices) if (keys[i].contains(x, y)) return i
            return INVALID_ID
        }

        override fun getVisibleVirtualViews(ids: MutableList<Int>) { for (i in keys.indices) ids.add(i) }

        override fun onPopulateNodeForVirtualView(id: Int, node: androidx.core.view.accessibility.AccessibilityNodeInfoCompat) {
            val k = keyAt(id)
            if (k == null) {   // danh sách phím vừa đổi: nút rỗng hợp lệ
                node.contentDescription = ""
                node.setBoundsInParent(android.graphics.Rect(0, 0, 1, 1))
                return
            }
            node.contentDescription = KeyA11y.describe(k.kind, k.label, k.upper, k.insert, shift != Shift.OFF, returnLabel)
            node.className = android.widget.Button::class.java.name
            node.setBoundsInParent(android.graphics.Rect(k.left.toInt(), k.top.toInt(), k.right.toInt(), k.bottom.toInt()))
            node.addAction(androidx.core.view.accessibility.AccessibilityNodeInfoCompat.ACTION_CLICK)
        }

        override fun onPerformActionForVirtualView(id: Int, action: Int, args: android.os.Bundle?): Boolean {
            if (action != androidx.core.view.accessibility.AccessibilityNodeInfoCompat.ACTION_CLICK) return false
            val k = keyAt(id) ?: return false
            a11yTap(k)
            invalidateRoot()           // nhãn có thể đổi (shift, plane)
            return true
        }
    }

    // MARK: cấu hình

    fun configure(returnLabel: String, kind: InputKind, needsGlobe: Boolean, showLogo: Boolean,
                  templatesEnabled: Boolean, templates: () -> List<TemplateItem>, keyAreaPx: Float,
                  numberSigned: Boolean = false, numberDecimal: Boolean = false, numberRow: Boolean = false,
                  numberRowFull: Boolean = false, spaceSideKey: SpaceSideKey = SpaceSideKey.DEFAULT,
                  emojiInStrip: Boolean = false, labelSize: KeyLabelSize = KeyLabelSize.DEFAULT,
                  split: Boolean = false, largeKeys: Boolean = false) {
        this.splitSetting = split
        this.largeKeys = largeKeys
        this.numberRow = numberRow
        this.spaceSideKey = spaceSideKey
        this.emojiInStrip = emojiInStrip
        if (labelSize != this.labelSize || (theme.keyStyle.fontScale != null && !labelStyleApplied)) {
            this.labelSize = labelSize; labelStyleApplied = true; applyLabelSize()
        }
        this.numberRowFull = numberRowFull
        this.numberSigned = numberSigned
        this.numberDecimal = numberDecimal
        this.returnLabel = returnLabel
        this.needsGlobe = needsGlobe
        this.showLogo = showLogo
        this.templatesEnabled = templatesEnabled
        this.templates = templates
        if (this.keyAreaPx != keyAreaPx) { this.keyAreaPx = keyAreaPx; requestLayout() }
        // Loại ô: số ⇒ plane 123; chữ ⇒ shift ON (nếu có) rớt về OFF như iOS configureInputKind.
        inputKind = kind
        plane = kind.padPlane ?: Plane.LETTERS
        if (plane == Plane.LETTERS && shift == Shift.ON) shift = Shift.OFF
        // Tab [Mẫu câu | Công cụ] nhớ lựa chọn cuối (cả phiên IME) — không đặt lại ở đây.
        refreshTemplatesPane()
        rebuild()
        listener?.onPlaneChanged(plane)
    }

    fun setNeedsGlobe(on: Boolean) {
        if (on == needsGlobe) return
        needsGlobe = on
        rebuild()
    }

    /** Auto-shift đầu câu: chỉ nâng OFF→ON, không bao giờ hạ CAPS. */
    fun setAutoShift(on: Boolean) {
        if (shift == Shift.CAPS || plane == Plane.EMOJI_SEARCH) return
        val want = if (on) Shift.ON else Shift.OFF
        if (shift != want) { shift = want; if (plane == Plane.LETTERS) invalidate() }
    }

    fun setPlane(p: Plane) {
        if (p == Plane.TEMPLATES && leftZone == TemplatesMenu.LeftZone.NONE) return
        if (plane == p) return
        ImeTrace.begin(ImeTrace.PLANE_SWITCH)
        try { switchPlane(p) } finally { ImeTrace.end() }
    }

    private fun switchPlane(p: Plane) {
        // Vào 123 / #+= từ plane khác: chưa gõ gì ở đó (space chưa về chữ) — như iOS typedInSymbolPlane.
        if (plane != Plane.NUMBERS && plane != Plane.SYMBOLS) typedInSymbolPlane = false
        // Rời plane chữ sang 123 / #+= / emoji: tắt Caps Lock + shift một-lần (như iOS stock;
        // Phil 06/10/2026). Về chữ IME đánh giá lại viết hoa đầu câu (onPlaneChanged).
        if (plane == Plane.LETTERS && PlanePolicy.clearsShiftLeavingLetters(p)) shift = Shift.OFF
        plane = p
        if (p == Plane.LETTERS && shift == Shift.ON) shift = Shift.OFF
        if (p == Plane.EMOJI) emojiPane.open(listener?.emojiRecents() ?: emptyList())
        if (p == Plane.EMOJI_SEARCH) {
            search = EmojiSearchSession(searchSettings)
            shift = Shift.OFF
            searchBar.reset()
        }
        if (p == Plane.TEMPLATES) templatesPane.resetScroll()
        editSelecting = false
        mole?.hideNow()                     // Đập chuột: đổi bảng phím ⇒ dẹp chuột
        rebuild()
        listener?.onPlaneChanged(p)
    }

    /** Một tay: dựng lại plane ở bề ngang hẹp (planeCache theo chữ ký). */
    fun setOneHand(side: OneHandSide) {
        if (side == oneHand) return
        cancelAllTouches()
        oneHand = side
        rebuild()
    }

    /** Bật / tắt "Bàn phím tách đôi" khi bàn phím đang mở (ô Thử gõ) — dựng lại nếu đổi. */
    fun setSplit(on: Boolean) {
        if (on == splitSetting) return
        cancelAllTouches()
        splitSetting = on
        rebuild()
    }

    /** Icon con trỏ trên thanh gợi ý: mở / đóng bảng sửa văn bản. */
    fun toggleEditPanel() {
        setPlane(if (plane == Plane.EDIT) Plane.LETTERS else Plane.EDIT)
    }

    /** IME báo ô đang có vùng chọn (onUpdateSelection) — ô Sao chép / Cắt sáng lên. */
    fun setEditHasSelection(on: Boolean) {
        if (on == editHasSelection) return
        editHasSelection = on
        if (plane == Plane.EDIT) invalidate()
    }

    /** ☰: mẫu câu, hoặc (Mẫu câu tắt) thẳng danh sách công cụ — TemplatesMenu.pane. */
    fun toggleTemplates() {
        if (leftZone == TemplatesMenu.LeftZone.NONE) return
        setPlane(if (plane == Plane.TEMPLATES) Plane.LETTERS else Plane.TEMPLATES)
    }

    private var numberSigned = false
    private var numberDecimal = false
    private var numberRow = false
    private var numberRowFull = false
    /** "Phím cạnh dấu cách" (Settings) — trong chữ ký layout, đọc lúc dựng (0 chi phí mỗi phím). */
    private var spaceSideKey = SpaceSideKey.DEFAULT
    /** "Về bàn chữ sau ký hiệu" (IME đặt lúc hiện, như [trackpadSpeed]) — không đổi bố cục. */
    var symbolReturn: SymbolReturn = SymbolReturn.DEFAULT
    /** Đã gõ ít nhất một ký tự ở 123 / #+= kể từ lúc vào plane đó — space mới về chữ. */
    private var typedInSymbolPlane = false
    /** Layout đang hiện có phím "." cạnh space thay "," (Dấu chấm) ⇒ giữ "." ra popup dấu câu. */
    private var periodSideKey = false
    /** "Nút emoji" = Thanh trên và strip hiện ⇒ bàn chữ không có 😊 (nút ở StripView). Trong chữ ký layout. */
    private var emojiInStrip = false
    /** "Phím to" (Settings, mặc định TẮT — [KeyLayout.largeKeysActive]). Trong chữ ký layout, chỉ đọc lúc dựng. */
    private var largeKeys = false
    /** Chế độ một tay (IME chỉ đặt khác OFF trên điện thoại). */
    var oneHand = OneHandSide.OFF; private set
    /**
     * Công tắc "Bàn phím tách đôi" (Settings, mặc định TẮT). Tắt ⇒ [splitNow] false ngay (một phép
     * AND mỗi lần dựng, không gì trong đường chạm).
     */
    private var splitSetting = false
    /**
     * Đang tách ở bề ngang hiện tại (công tắc + ≥ SplitLayout.MIN_WIDTH_DP) — tính lại mỗi lần dựng,
     * nên xoay / gập-mở (onSizeChanged) tự vào / ra kiểu tách. Khi tách: gõ vuốt + một tay tạm tắt.
     */
    private var splitNow = false
    /** IME / test: bàn phím đang tách đôi (một tay, gõ vuốt tạm tắt). */
    val splitActive: Boolean get() = splitNow
    /** Một tay thực dùng: tách đôi đã chia hai bên ⇒ một tay vô nghĩa (như iOS). */
    private val oneHandNow: OneHandSide get() = if (splitNow) OneHandSide.OFF else oneHand
    private fun signature() = "$returnLabel|$inputKind|$needsGlobe|$width|$keyAreaPx|$numberSigned|$numberDecimal|$numberRow|$numberRowFull|$spaceSideKey|$emojiInStrip|$oneHand|$textToolsEnabled|$translateEnabled|$splitNow|$largeKeys"

    private fun rebuild() {
        if (width == 0) return
        dropAlt()                         // phím có thể dời / đổi plane
        dropPopover()
        balloon.clearPress()              // khung phím sẫm cũ không còn đúng
        splitNow = splitSetting && KeyLayout.splitActive(true, width.toFloat(), d)
        val sig = signature()
        if (sig != builtSig) { planeCache = layoutCache.getOrPut(sig) { HashMap() }; builtSig = sig }
        val cfg = LayoutConfig(plane, width.toFloat(), keyAreaPx, d, inputKind, needsGlobe,
            theme.tablet, returnLabel, numberSigned, numberDecimal, numberRow, oneHandNow,
            editTools = textToolsEnabled, numberRowFull = numberRowFull, editTranslate = translateEnabled,
            spaceSideKey = spaceSideKey, emojiInStrip = emojiInStrip, split = splitNow, largeKeys = largeKeys)
        keys = planeCache.getOrPut(plane) {
            ImeCost.layoutBuilds++
            ImeTrace.begin(ImeTrace.LAYOUT_BUILD)
            try { KeyLayout.build(cfg) } finally { ImeTrace.end() }
        }
        fitLetterLabels()
        if (plane == Plane.EDIT) fitEditLabels()
        periodSideKey = KeyLayout.sideKey(cfg) == SpaceSideKey.PERIOD
        railSpan = if (OneHand.appliesTo(plane)) OneHand.rail(width.toFloat(), oneHandNow) else null
        a11y.invalidateRoot()             // TalkBack tắt ⇒ trả về ngay (manager không bật)
        // Tách đôi có hai phím cách: phím PHẢI (sau cùng) mang logo / badge như iOS. Không tách: một phím.
        spaceKey = keys.lastOrNull { it.kind == KeyKind.SPACE }
        spaceKey?.let {
            val sz = theme.dp(22f)
            logoRect.set(it.right - theme.dp(10f) - sz, it.centerY - sz / 2, it.right - theme.dp(10f), it.centerY + sz / 2)
        }
        // Bảng mẫu câu / emoji chỉ dàn khi đang hiện (bảng chữ lúc hiện bàn phím không trả phí của chúng).
        if (plane == Plane.TEMPLATES) {
            syncTemplatesPane()
            templatesPane.layout(width.toFloat(), keyAreaPx - KeyLayout.rowUnit(keyAreaPx, numberRow, d, numberRowFull))
        }
        emojiPane.layout(width.toFloat(), keyAreaPx)
        searchBar.layout(width.toFloat(), KeyLayout.searchHeaderPx(keyAreaPx))
        if (plane == Plane.EMOJI_SEARCH) refreshSearch()
        publishSwipeLayout()
        onKeysLaidOut?.invoke()
        invalidate()
    }

    /** Gọi sau mỗi lần dựng phím (hoạ tiết nền theme đặt motif vào khe giữa các hàng). null = không làm gì. */
    var onKeysLaidOut: (() -> Unit)? = null
    /** Khung dọc [top, bottom] (px, toạ độ view này) của mọi phím đang hiện. */
    fun keySpans(): List<DoubleArray> = keys.map { doubleArrayOf(it.top.toDouble(), it.bottom.toDouble()) }

    override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
        setMeasuredDimension(MeasureSpec.getSize(widthMeasureSpec), Math.round(keyAreaPx))
    }

    override fun onSizeChanged(w: Int, h: Int, oldw: Int, oldh: Int) {
        rebuild()
    }

    /** Bàn phím ẩn: dọn mọi pointer/timer — không để Handler nào sống. */
    /** Hẹn giờ ẩn (VietTelexIME.releaseIdle): nhả dữ liệu emoji nếu không đang ở lưới emoji. */
    fun releaseIdleCaches() { if (plane != Plane.EMOJI) emojiPane.releaseData() }

    fun onHidden() {
        cancelAllTouches()
        badgeAnim?.cancel(); badgeAlpha = 0f
        flickAnim?.cancel(); flickAnim = null; carouselOn = false
        emojiPane.onHidden()
        searchBar.reset()
        templatesPane.onHidden()
    }

    // MARK: badge ngôn ngữ

    /** "ViệtTelex" giữa space 0.7 s rồi fade 0.3 s; logo Vᴛ ẩn trong lúc đó. */
    fun showLanguageBadge() {
        badgeAnim?.cancel()
        badgeAlpha = 1f
        badgeAnim = ValueAnimator.ofFloat(1f, 0f).apply {
            startDelay = 700; duration = 300
            interpolator = DecelerateInterpolator()
            addUpdateListener { badgeAlpha = it.animatedValue as Float; invalidateSpace() }
            start()
        }
        invalidateSpace()
    }

    /**
     * Nội dung phím cách (badge / logo / nhãn vuốt đổi ngôn ngữ) đổi: CHỈ ghi lại lớp động — lưới
     * phím tĩnh ([gridNode]) giữ nguyên. Badge hiện mỗi lần mở bàn phím (~1 s, ~20 khung).
     */
    private fun invalidateSpace() {
        if (spaceKey == null) return
        super.invalidate()
    }

    // MARK: lưới phím tĩnh (RenderNode, API 29+)

    /**
     * Lưới phím (nền + nhãn mọi phím, trừ nội dung phím cách) ghi một lần vào RenderNode riêng; mỗi
     * khung KeyboardView chỉ phát lại node + vẽ lớp động (nội dung phím cách, rail một tay). Mọi
     * [invalidate] khác (shift, plane, phím chức năng nhấn, theme, …) đánh dấu lưới bẩn ⇒ ghi lại —
     * mặc định an toàn: chỉ [invalidateSpace] được bỏ qua lưới. Canvas phần mềm / API < 29: vẽ thẳng.
     */
    private val gridNode: android.graphics.RenderNode? =
        if (android.os.Build.VERSION.SDK_INT >= 29) android.graphics.RenderNode("vt-key-grid") else null
    private var gridDirty = true
    /** Test: lưới cần ghi lại ở lượt vẽ kế. */
    internal val gridStale: Boolean get() = gridDirty

    override fun invalidate() { gridDirty = true; super.invalidate() }
    @Deprecated("Deprecated in Java")
    @Suppress("DEPRECATION")
    override fun invalidate(l: Int, t: Int, r: Int, b: Int) { gridDirty = true; super.invalidate(l, t, r, b) }
    @Deprecated("Deprecated in Java")
    @Suppress("DEPRECATION")
    override fun invalidate(dirty: android.graphics.Rect) { gridDirty = true; super.invalidate(dirty) }

    override fun onDetachedFromWindow() {
        super.onDetachedFromWindow()
        gridNode?.discardDisplayList(); gridDirty = true
    }

    private fun drawGrid(c: Canvas) {
        ImeCost.gridRecords++
        val ks = keys
        val f = keyFloat
        if (f != null && floating) {
            // Lơ lửng: dời HÌNH từng phím (canvas) — vùng nhận chạm vẫn theo khung gốc trong `keys`.
            val d = theme.dp(1f)
            for (i in ks.indices) { val k = ks[i]; c.save(); f.apply(c, i, floatT, k.centerX, k.centerY, d); drawKey(c, k); c.restore() }
        } else for (i in ks.indices) drawKey(c, ks[i])
    }

    /**
     * "Lơ lửng" ([KeyFloatDriver], hiệu ứng "float" hoặc theme "keyMotion":"float") — null = tắt: đường phím chỉ đọc một
     * biến null. Đang trôi / về chỗ: mỗi khung ghi lại lưới phím có dời hình; xong ⇒ ghi lại một lần ở chỗ cũ rồi thôi.
     */
    var keyFloat: KeyFloatDriver? = null
        set(v) { if (field !== v) { field?.halt(); field = v; floating = false; invalidate() } }
    private var floating = false
    private var floatT = 0.0

    @Suppress("DEPRECATION")
    private fun invalidateKey(k: LaidKey) =
        invalidate(k.left.toInt() - 1, k.top.toInt() - 1, k.right.toInt() + 1, k.bottom.toInt() + 1)

    // MARK: vẽ

    override fun onDraw(c: Canvas) {
        ImeCost.keyboardDraws++
        ImeTrace.begin(ImeTrace.KEYBOARD_DRAW)
        try { drawKeys(c) } finally { ImeTrace.end() }
        ImeTrace.drew(keys = true)
    }

    private fun drawKeys(c: Canvas) {
        when (plane) {
            Plane.EMOJI -> { emojiPane.draw(c); return }
            Plane.TEMPLATES -> templatesPane.draw(c)
            Plane.EMOJI_SEARCH -> searchBar.draw(c)
            else -> Unit
        }
        val fl = keyFloat
        val was = floating
        floating = fl != null && fl.frame(fl.now().also { floatT = it })
        if (floating || was) gridDirty = true            // trôi: ghi lại mỗi khung; vừa dừng: ghi lại ở chỗ cũ một lần
        val node = gridNode
        if (node != null && c.isHardwareAccelerated) {
            if (gridDirty || !node.hasDisplayList()) {
                ImeTrace.begin(ImeTrace.GRID_RECORD)
                node.setPosition(0, 0, width, height)
                val rc = node.beginRecording(width, height)
                try { drawGrid(rc) } finally { node.endRecording(); ImeTrace.end() }
            }
            c.drawRenderNode(node)
        } else drawGrid(c)
        gridDirty = false
        val sk = spaceKey
        if (floating && fl != null && sk != null) {
            c.save(); fl.apply(c, keys.indexOf(sk), floatT, sk.centerX, sk.centerY, theme.dp(1f)); drawSpaceContent(c); c.restore()
        } else drawSpaceContent(c)
        railSpan?.let { drawRail(c, it) }
        if (floating) postInvalidateOnAnimation()
    }

    // MARK: một tay — rail (dải trống: nút đổi bên + thoát)

    private var railSpan: Pair<Float, Float>? = null
    private var railPressed = -1
    private var railPtr = -1
    private val railFill = theme.fill(theme.specialFill)

    private fun railCenter(i: Int): Pair<Float, Float> {
        val r = railSpan ?: return 0f to 0f
        return (r.first + r.second) / 2 to keyAreaPx * (if (i == 0) 0.3f else 0.7f)
    }

    private fun drawRail(c: Canvas, r: Pair<Float, Float>) {
        val rad = minOf((r.second - r.first) / 2 - theme.dp(4f), theme.dp(22f))
        if (rad <= 0f) return
        for (i in 0..1) {
            val (cx, cy) = railCenter(i)
            railFill.color = if (railPressed == i) specialPressed else theme.specialFill
            c.drawCircle(cx, cy, rad, railFill)
            icon(c, if (i == 0) ImeIcons.SWAP else ImeIcons.EXPAND, cx, cy, 20f, theme.ink, (255 * theme.labelAlpha).toInt())
        }
    }

    // MARK: bảng sửa văn bản

    /** Chế độ chọn của bảng sửa (ô "Chọn"). */
    private var editSelecting = false
    private var editHasSelection = false
    private var editPtr = -1
    private var editRepeatKey: LaidKey? = null
    private val editRepeatRun = object : Runnable {
        override fun run() {
            val k = editRepeatKey ?: return
            fireEdit(k)
            postDelayed(this, EDIT_REPEAT_MS)
        }
    }

    private fun editEnabled(a: EditAction) = !a.needsSelection || editHasSelection

    private fun fireEdit(k: LaidKey) {
        if (k.insert == EditPanel.TRANSLATE_INSERT) { listener?.onTranslate(); return }   // ở lại bảng sửa
        if (k.insert == EditPanel.ADD_TONES_INSERT) { listener?.onAddTones(); return }    // ở lại bảng sửa
        EditPanel.toolOf(k.insert)?.let { listener?.onTextTool(it); return }   // ở lại bảng sửa
        val a = EditAction.of(k.insert) ?: return
        when (a) {
            EditAction.SELECT -> { editSelecting = !editSelecting; invalidate() }
            EditAction.CLOSE -> setPlane(Plane.LETTERS)
            EditAction.DELETE -> listener?.onKey(Key.Backspace)
            else -> if (editEnabled(a)) listener?.onEditAction(a, editSelecting)
        }
    }

    private fun drawEditKey(c: Canvas, k: LaidKey, alpha: Int) {
        // Mọi ô công cụ (TextTool, Thêm dấu, Dịch) — trước đây ô "Dịch" không khớp toolOf nên
        // không vẽ nhãn (ô trống tester thấy cuối hàng).
        if (EditPanel.isToolCell(k.insert)) {
            drawLabel(c, k.label, k.centerX, k.centerY, editPaint, editOff, alpha); return
        }
        val a = EditAction.of(k.insert) ?: return
        val cx = k.centerX; val cy = k.centerY
        val al = if (editEnabled(a)) alpha else (alpha * 0.35f).toInt()
        when {
            a == EditAction.DELETE -> icon(c, ImeIcons.DELETE, cx, cy, 22f, theme.ink, al)
            EditPanel.isGlyph(a) -> drawLabel(c, k.label, cx, cy, letterPaint, letterOff, al)
            else -> drawLabel(c, k.label, cx, cy, editPaint, editOff, al)
        }
    }

    /** Ghi-ta ("spaceDeco":"soundhole"): Paint cấp một lần; theme khác ⇒ null (một phép so mỗi lần vẽ phím). */
    private val soundholePaint: Paint? = if (theme.palette.spaceSoundhole) Paint(Paint.ANTI_ALIAS_FLAG) else null

    /** Lỗ thoát âm + hai vành hoa văn trên phím cách — hình học [Soundhole] (= iOS), vẽ cùng nền phím (display list). */
    private fun drawSoundhole(c: Canvas, k: LaidKey) {
        val p = soundholePaint ?: return
        val r = Soundhole.radius(k.width.toDouble(), k.height.toDouble()).toFloat()
        val a = theme.palette.surfaceAlpha
        p.style = Paint.Style.FILL
        p.color = android.graphics.Color.BLACK; p.alpha = (255 * Soundhole.HOLE_ALPHA * a).toInt()
        c.drawCircle(k.centerX, k.centerY, r, p)
        p.style = Paint.Style.STROKE
        val rings = Soundhole.RINGS
        p.color = theme.action; p.alpha = (255 * 0.85f * a).toInt()
        p.strokeWidth = (rings[0][1] * r).toFloat(); c.drawCircle(k.centerX, k.centerY, (rings[0][0] * r).toFloat(), p)
        p.color = theme.fnInk; p.alpha = (255 * 0.45f * a).toInt()
        p.strokeWidth = (rings[1][1] * r).toFloat(); c.drawCircle(k.centerX, k.centerY, (rings[1][0] * r).toFloat(), p)
    }

    /** Test: phím cách có lỗ thoát âm (theme Ghi-ta). */
    internal val hasSoundhole: Boolean get() = soundholePaint != null

    /** Test: tâm phím có nhãn [label] (chữ thường) ở plane hiện tại, null nếu không có. */
    internal fun keyCenter(label: String): android.graphics.PointF? =
        keys.firstOrNull { it.label == label }?.let { android.graphics.PointF(it.centerX, it.centerY) }
    /** Test: tâm phím cách (toạ độ view này). */
    internal fun spaceCenter(): android.graphics.PointF? = spaceKey?.let { android.graphics.PointF(it.centerX, it.centerY) }

    private fun drawKey(c: Canvas, k: LaidKey) {
        // Gboard: phím phẳng bo góc, KHÔNG bóng; phím chức năng tô màu phụ (secondary
        // container); enter là pill màu nhấn. Nhấn = state layer ink 12%.
        val special = KeyKind.isSpecial(k.kind) && k.kind != KeyKind.RETURN
        // Dáng điểm ảnh: bấm = phím LÚN một khối (không đổi màu); ⇧ bật/Caps cũng lún (như iOS skin điểm ảnh).
        val pixel = pixelRects != null && !trackpad
        val sunk = pixel && (k.pressed || (k.kind == KeyKind.SHIFT && shift != Shift.OFF))
        val pressed = k.pressed && !pixel
        var face = when {
            k.kind == KeyKind.RETURN -> if (pressed) actionPressed else theme.action
            // Màu nhấn người dùng chọn ⇒ ⇧ bật/Caps tô màu nhấn, glyph actionInk (accentShift); mặc định như cũ.
            k.kind == KeyKind.SHIFT && theme.accentShift && shift != Shift.OFF -> theme.action
            k.kind == KeyKind.SHIFT && shift == Shift.CAPS -> theme.chip
            k.kind == KeyKind.EDIT && editSelecting && k.insert == "SELECT" -> theme.chip
            special -> if (pressed) specialPressed else theme.fnFill
            k.kind == KeyKind.LETTER || k.kind == KeyKind.CHAR -> theme.keyFill   // popup lo phản hồi
            k.kind == KeyKind.PAD && k.side -> if (pressed) specialPressed else theme.fnFill
            // Phím cách: như phím chữ, trừ theme tô phím chức năng riêng (Xanh lá).
            k.kind == KeyKind.SPACE -> if (pressed) spacePressed else theme.spaceFill
            else -> if (pressed) keyPressed else theme.keyFill
        }
        if (trackpad) face = theme.keyFill
        // Skin của theme (ảnh tải về): thay nền phím; đè ⇒ ảnh "pressed" (⇧ bật cũng vậy). Chữ vẫn vẽ đè lên.
        val skin = if (skins != null && !trackpad) skins[ThemeKeyRole.index(k.kind, k.label, k.side)] else null
        if (skin != null) {
            skinPainter?.draw(c, skin, k.pressed || (k.kind == KeyKind.SHIFT && shift != Shift.OFF), k.left, k.top, k.right, k.bottom)
        } else if (pixel) {
            drawPixelKey(c, k, face, sunk)
        } else if (glassFill != null && !trackpad) {
            drawGlassKey(c, k, face)
        } else {
            facePaint.color = face
            // Bo góc tuỳ chỉnh (Plus) áp mọi phím kể cả enter; mặc định enter là viên thuốc như cũ.
            val r = if (k.kind == KeyKind.RETURN && theme.keyStyle.corner == null) minOf(k.width, k.height) / 2
                else theme.keyRadius(k.width, k.height, radius)
            c.drawRoundRect(k.left, k.top, k.right, k.bottom, r, r, facePaint)
            borderPaint?.let { bp ->
                val h = bp.strokeWidth / 2
                c.drawRoundRect(k.left + h, k.top + h, k.right - h, k.bottom - h, r, r, bp)
            }
            if (soundholePaint != null && k.kind == KeyKind.SPACE && !trackpad) drawSoundhole(c, k)
        }

        // 0.2 khi trackpad; × độ trong suốt ký tự (alpha paint — không offscreen).
        val contentAlpha = ((if (trackpad) 51 else 255) * theme.labelAlpha).toInt()
        // Nhãn / icon theo tâm MẶT phím điểm ảnh (thường −khối/2, lún +khối/2).
        val ps = if (pixel) PixelKeys.labelShift(pixelBlock(k).toDouble(), sunk).toFloat() else 0f
        val cx = k.centerX + ps; val cy = k.centerY + ps
        when (k.kind) {
            KeyKind.LETTER -> {
                val alt = if (alts.isNotEmpty()) alts[k.label[0]] else null
                // Chữ Lớn + ký tự phụ góc trên ⇒ hạ chữ chính một chút để không chạm ký tự phụ.
                val ly = if (alt != null && (labelSize != KeyLabelSize.MEDIUM || theme.keyStyle.letterScale > 1f)) cy + largeHintDrop else cy
                drawLabel(c, if (shift == Shift.OFF) k.label else k.upper, cx, ly, letterPaint, letterOff, contentAlpha)
                // Ký tự phụ nhỏ, mờ ở góc trên-phải như Gboard.
                alt?.let {
                    drawLabel(c, it, k.right - hintInset + theme.dp(2f), k.top + hintInset, hintPaint, hintOff, (contentAlpha * 0.55f).toInt())
                }
            }
            KeyKind.CHAR -> drawLabel(c, k.label, cx, cy, letterPaint, letterOff, contentAlpha)
            KeyKind.PAD -> if (k.hint.isEmpty()) {
                drawLabel(c, k.label, cx, cy, if (k.side) sidePaint else digitPaint, if (k.side) sideOff else digitOff, contentAlpha)
            } else {
                // Số + chữ nhỏ bên dưới (bàn điện thoại Gboard)
                drawLabel(c, k.label, cx, cy - hintLift, digitPaint, digitOff, contentAlpha)
                drawLabel(c, k.hint, cx, cy + hintDrop, hintPaint, hintOff, (contentAlpha * 0.7f).toInt())
            }
            KeyKind.PUNCT -> {
                drawLabel(c, k.label, cx, cy, letterPaint, letterOff, contentAlpha)
                // Gợi ý giữ lâu kiểu Gboard ở góc trên-phải phím ",": "." (popup dấu câu); TalkBack: 🎤.
                if (isVoiceComma(k)) icon(c, ImeIcons.MIC, k.right - hintInset, k.top + hintInset, 10f, theme.ink, (contentAlpha * 0.55f).toInt())
                else if (isPeriodComma(k) || isCommaPopup(k)) drawLabel(c, KeyAlternates.COMMA_ALT, k.right - hintInset + theme.dp(2f), k.top + hintInset, hintPaint, hintOff, (contentAlpha * 0.55f).toInt())
                else if (isPeriodPopup(k)) drawLabel(c, ",", k.right - hintInset + theme.dp(2f), k.top + hintInset, hintPaint, hintOff, (contentAlpha * 0.55f).toInt())
            }
            KeyKind.PLANE, KeyKind.MORE -> drawLabel(c, k.label, cx, cy, controlPaint, controlOff, contentAlpha)
            KeyKind.SHIFT -> {
                val id = when (shift) { Shift.CAPS -> ImeIcons.CAPS; Shift.ON -> ImeIcons.SHIFT_FILL; Shift.OFF -> ImeIcons.SHIFT }
                icon(c, id, cx, cy, 22f, if (theme.accentShift && shift != Shift.OFF) theme.actionInk else theme.fnInk, contentAlpha)
            }
            KeyKind.BACKSPACE -> {
                if (k.pressed && !trackpad) {
                    icon(c, ImeIcons.DELETE_FILL, cx, cy, 22f, theme.fnInk, contentAlpha)
                    icon(c, ImeIcons.DELETE_X, cx, cy, 22f, face, 255)
                } else icon(c, ImeIcons.DELETE, cx, cy, 22f, theme.fnInk, contentAlpha)
                // Vuốt ⌫: số từ sẽ xoá ở góc trên-phải (xem trước khi không bôi đen được).
                if (bsSwipe == 1 && bsSwipeWords > 0)
                    drawLabel(c, "−$bsSwipeWords", k.right - hintInset - theme.dp(2f), k.top + hintInset, hintPaint, hintOff, contentAlpha)
            }
            KeyKind.GLOBE -> icon(c, ImeIcons.GLOBE, cx, cy, 21f, theme.fnInk, contentAlpha)
            KeyKind.EMOJI -> {
                icon(c, ImeIcons.FACE, cx, cy, 22f, theme.fnInk, contentAlpha)
                // Gợi ý giữ lâu kiểu Gboard: 🌐 nhỏ, mờ ở góc trên-phải — chỉ khi thanh điều hướng
                // KHÔNG có nút đổi bàn phím (Android 16 báo qua onCustomImeSwitcherButtonRequestedVisible).
                if (switcherHint) icon(c, ImeIcons.GLOBE, k.right - hintInset, k.top + hintInset, 10f, theme.fnInk, (contentAlpha * 0.55f).toInt())
            }
            KeyKind.CLEAR -> icon(c, ImeIcons.TRASH, cx, cy, 21f, theme.fnInk, contentAlpha)
            KeyKind.PASTE -> icon(c, ImeIcons.CLIPBOARD, cx, cy, 20f, theme.fnInk, contentAlpha)
            KeyKind.EDIT -> drawEditKey(c, k, contentAlpha)
            KeyKind.DISMISS -> icon(c, ImeIcons.KB_DISMISS, cx, cy, 22f, theme.fnInk, contentAlpha)
            KeyKind.RETURN -> {
                val id = when (returnLabel) {
                    "search" -> ImeIcons.SEARCH
                    "send" -> ImeIcons.SEND
                    "done" -> ImeIcons.CHECK
                    "go", "next" -> ImeIcons.ARROW_RIGHT
                    else -> ImeIcons.RETURN
                }
                icon(c, id, cx, cy, 22f, theme.actionInk, contentAlpha)
            }
            KeyKind.SPACE -> Unit   // nội dung: [drawSpaceContent] (lớp động, ngoài lưới tĩnh)
        }
    }

    /** Ô kính màu: chữ a–z ⇒ màu ô theo chữ ([GlassKeys.paneColor]); phím khác giữ [face] (fn / nhấn / "key"). */
    private fun drawGlassKey(c: Canvas, k: LaidKey, face: Int) {
        val fp = glassFill ?: return
        val sp = glassSheen ?: return
        val lp = glassLead ?: return
        val m = glassMatrix ?: return
        val G = com.viettelex.keyboard.GlassKeys
        val letter = k.kind == KeyKind.LETTER && k.label.length == 1 && k.label[0].lowercaseChar() in 'a'..'z'
        var col = if (letter) G.paneColor(k.label) or (0xFF shl 24) else face
        if (k.pressed && letter) col = G.pressed(col and 0xFFFFFF) or (0xFF shl 24)
        val lw = G.leadWidth(k.height.toDouble()).toFloat()
        val r = theme.keyRadius(k.width, k.height, radius)
        fp.color = col
        c.drawRoundRect(k.left, k.top, k.right, k.bottom, r, r, fp)
        m.setScale(1f, k.height); m.postTranslate(0f, k.top)
        sp.shader?.setLocalMatrix(m)
        c.drawRoundRect(k.left, k.top, k.right, k.bottom, r, r, sp)
        lp.strokeWidth = lw
        val h = lw / 2
        c.drawRoundRect(k.left + h, k.top + h, k.right - h, k.bottom - h, maxOf(r - h, 0f), maxOf(r - h, 0f), lp)
    }

    /** Khối điểm ảnh của phím: chiều cao / [PixelKeys.CELLS], làm tròn về px nguyên (khối sắc, ≥ 1 px). */
    private fun pixelBlock(k: LaidKey): Float = maxOf(1f, Math.round(k.height / PixelKeys.CELLS).toFloat())

    /** Phím điểm ảnh: dải viền + bóng ([pixelInk]) rồi dải lõi ([face]) — rời nhau, không chồng alpha. */
    private fun drawPixelKey(c: Canvas, k: LaidKey, face: Int, sunk: Boolean) {
        val r = pixelRects ?: return
        val p = pixelPaint ?: return
        val n = PixelKeys.write(r, k.left, k.top, k.right, k.bottom, pixelBlock(k), sunk)
        p.color = pixelInk
        for (i in 0 until (n and 0xFF)) {
            val o = PixelKeys.INK + 4 * i
            c.drawRect(r[o], r[o + 1], r[o + 2], r[o + 3], p)
        }
        p.color = face
        for (i in 0 until (n shr 8)) {
            val o = PixelKeys.FILL + 4 * i
            c.drawRect(r[o], r[o + 1], r[o + 2], r[o + 3], p)
        }
    }

    /** Badge "ViệtTelex" / nhãn vuốt đổi ngôn ngữ / logo trên phím cách — vẽ SAU lưới phím, mỗi khung. */
    private fun drawSpaceContent(c: Canvas) {
        val k = spaceKey ?: return
        if (plane == Plane.EMOJI) return
        val contentAlpha = ((if (trackpad) 51 else 255) * theme.labelAlpha).toInt()
        val cx = k.centerX; val cy = k.centerY
        // Bàn số: phím cách mang ký hiệu ␣ như Gboard (trước đây không nhãn — người dùng tưởng ô trống).
        if (!languageOnSpace) { drawLabel(c, "\u2423", cx, cy, controlPaint, controlOff, contentAlpha); return }
        // Badge "ViệtTelex" lúc hiện rồi mờ dần về logo Vᴛ (như iOS). Kẹp trong phím (vẽ sau phím kề).
        if (badgeAlpha > 0f) {
            badgePaint.alpha = (badgeAlpha * contentAlpha).toInt()
            c.save()
            c.clipRect(k.left, k.top, k.right, k.bottom)
            c.drawText(if (spaceLanguage == KeyboardLanguage.EN) KeyboardLanguage.EN.displayName else badgeText,
                cx, cy + badgeOff, badgePaint)
            c.restore()
        }
        if (carouselOn) { drawCarousel(c, k, contentAlpha); return }
        if (badgeAlpha < 1f) when (val m = SpaceMark.choose(spaceFlickEnabled, showLogo, spaceLanguage)) {
            is SpaceMark.Code -> {
                codePaint.alpha = (android.graphics.Color.alpha(codeColor) * (1f - badgeAlpha) * contentAlpha / 255f).toInt()
                c.drawText(m.text, k.right - theme.dp(if (theme.tablet) 10f else 7f),
                    k.bottom - theme.dp(if (theme.tablet) 7f else 5f), codePaint)
            }
            is SpaceMark.Logo -> {
                val bmp = if (m.language == KeyboardLanguage.EN) logoEn else logo
                if (bmp != null) {
                    logoPaint.alpha = ((1f - badgeAlpha) * contentAlpha).toInt()
                    c.drawBitmap(bmp, null, logoRect, logoPaint)
                }
            }
            SpaceMark.None -> {}
        }
    }

    private val badgeOff = theme.centerOffset(badgePaint)

    // MARK: vuốt phím cách đổi Tiếng Việt ↔ Tiếng Anh (SpaceFlick, kiểu HeliBoard)
    // Kéo ngang: nhãn ngôn ngữ hiện tại trượt theo ngón + mờ dần, nhãn kia trượt vào từ phía
    // đối diện. Nhấc nhanh (trước ngưỡng trackpad) đủ ~1 phím ⇒ đổi: nhãn mới vào giữa, sáng
    // một nhịp rồi mờ đi, logo Vᴛ/E đổi theo. Không đủ ⇒ trượt về, mờ đi. Giống iOS.
    private var spaceFlickEnabled = false
    /**
     * Bàn số (ô điện thoại / ô số) chỉ gõ số: phím cách KHÔNG mang nhãn VI/EN, logo hay badge, và vuốt
     * phím cách không đổi ngôn ngữ — tester 15/11/2026 tưởng góc "VI" là nút chuyển Anh/Việt thừa.
     */
    private val languageOnSpace: Boolean get() = !KeyLayout.isNumberPad(plane)
    var spaceLanguage = KeyboardLanguage.VI
        set(v) { if (field != v) { field = v; invalidateSpace() } }
    private var flickDownT = 0L
    /** Ngón đã trượt quá slop trước khi giữ đủ SPACE_HOLD_MS ⇒ trackpad không thể bật trong lần
     *  chạm này ⇒ kéo chậm vẫn đổi ngôn ngữ (#147). */
    private var spaceHoldGone = false
    private var carouselOn = false
    private var carouselFrom = KeyboardLanguage.VI
    private var carQ = 0f
    private var carCurA = 0f
    private var carNextA = 0f
    private var flickAnim: android.animation.Animator? = null
    private val flickPaint = theme.text(16f, color = theme.spaceInk)
    private val flickOff = theme.centerOffset(flickPaint)

    fun configureSpaceFlick(enabled: Boolean, language: KeyboardLanguage) {
        spaceFlickEnabled = enabled
        if (!enabled && carouselOn) { flickAnim?.cancel(); carouselOn = false }
        spaceLanguage = language
        invalidateSpace()
    }

    /** Bề rộng phím chữ (dp) — thước ngưỡng flick. */
    private fun flickKeyWidthDp(): Float =
        (keys.firstOrNull { it.kind == KeyKind.LETTER || it.kind == KeyKind.CHAR }?.width ?: (width / 10f)) / d

    private fun moveFlick(dx: Float, dy: Float) {
        val q = SpaceFlick.progress(dx / d, dy / d, SystemClock.uptimeMillis() - flickDownT,
            SpaceFlick.previewSpan(flickKeyWidthDp()), trackpadPossible = !spaceHoldGone)
        if (q == 0f) { if (carouselOn && flickAnim == null) retractCarousel(); return }
        if (!carouselOn || flickAnim != null) { flickAnim?.cancel(); flickAnim = null; carouselOn = true; carouselFrom = spaceLanguage }
        setCarousel(q)
    }

    private fun setCarousel(q: Float) {
        carQ = q; carCurA = 0.6f * (1 - abs(q)); carNextA = 0.6f * abs(q)
        invalidateSpace()
    }

    private fun endFlick(k: LaidKey, dx: Float, dy: Float, t: Long, cancelled: Boolean) {
        val dir = if (cancelled || !commits.isArmed(k) || plane == Plane.EMOJI_SEARCH) null
            else SpaceFlick.classify(dx / d, dy / d, t - flickDownT, flickKeyWidthDp(), trackpadPossible = !spaceHoldGone)
        if (dir == null) { if (carouselOn) retractCarousel(); return }
        commits.disarm(k)                 // flick không ra dấu cách
        feedback.tick(this)
        if (!carouselOn) { carouselOn = true; carouselFrom = spaceLanguage; setCarousel(if (dir == SpaceFlick.Direction.LEFT) -0.2f else 0.2f) }
        listener?.onSpaceFlick()
        // nhãn mới vào giữa, sáng một nhịp (~0,5 s) rồi mờ — như HeliBoard
        val q0 = carQ; val n0 = carNextA; val c0 = carCurA
        val target = if (dir == SpaceFlick.Direction.LEFT) -1f else 1f
        val slide = ValueAnimator.ofFloat(0f, 1f).apply {
            duration = 180; interpolator = DecelerateInterpolator()
            addUpdateListener { val f = it.animatedValue as Float
                carQ = q0 + (target - q0) * f; carNextA = n0 + (1 - n0) * f; carCurA = c0 * (1 - f); invalidateSpace() }
        }
        val fade = ValueAnimator.ofFloat(1f, 0f).apply {
            startDelay = 500; duration = 300
            addUpdateListener { carNextA = it.animatedValue as Float; invalidateSpace() }
        }
        runCarousel(android.animation.AnimatorSet().apply { playSequentially(slide, fade) })
    }

    private fun retractCarousel() {
        val q0 = carQ; val n0 = carNextA; val c0 = carCurA
        runCarousel(ValueAnimator.ofFloat(1f, 0f).apply {
            duration = 150
            addUpdateListener { val f = it.animatedValue as Float
                carQ = q0 * f; carNextA = n0 * f; carCurA = c0 * f; invalidateSpace() }
        })
    }

    private fun runCarousel(a: android.animation.Animator) {
        flickAnim?.cancel()
        flickAnim = a
        a.addListener(object : android.animation.AnimatorListenerAdapter() {
            private var canceled = false
            override fun onAnimationCancel(animation: android.animation.Animator) { canceled = true }
            override fun onAnimationEnd(animation: android.animation.Animator) {
                if (flickAnim === a) flickAnim = null
                if (!canceled) { carouselOn = false; invalidateSpace() }
            }
        })
        a.start()
    }

    /** q ∈ [-1, 1]: nhãn hiện tại lệch q·W/2 theo ngón, nhãn kia theo sau một nửa bề ngang. */
    private fun drawCarousel(c: Canvas, k: LaidKey, contentAlpha: Int) {
        val w = k.width
        val off = carQ * w / 2
        val y = k.centerY + flickOff
        c.save()
        c.clipRect(k.left, k.top, k.right, k.bottom)
        flickPaint.alpha = (carCurA * contentAlpha).toInt()
        if (flickPaint.alpha > 0) c.drawText(carouselFrom.displayName, k.centerX + off, y, flickPaint)
        flickPaint.alpha = (carNextA * contentAlpha).toInt()
        if (flickPaint.alpha > 0)
            c.drawText(carouselFrom.toggled.displayName, k.centerX + off - (if (carQ < 0) -1 else 1) * w / 2, y, flickPaint)
        c.restore()
    }

    private fun drawLabel(c: Canvas, s: String, cx: Float, cy: Float, p: Paint, off: Float, alpha: Int) {
        p.alpha = alpha
        c.drawText(s, cx, cy + off, p)
    }

    private fun icon(c: Canvas, id: Int, cx: Float, cy: Float, sizeDp: Float, color: Int, alpha: Int) {
        iconPaint.color = color
        iconPaint.alpha = (android.graphics.Color.alpha(color) * alpha) / 255
        ImeIcons.draw(c, id, cx, cy, sizeDp * d * iconScale, iconPaint)
    }

    /** "Cỡ chữ trên phím": đặt lại cỡ mọi paint nhãn phím (lúc cấu hình — 0 chi phí mỗi phím). */
    private fun applyLabelSize() {
        // Plus đặt thanh "Cỡ chữ trên phím" ⇒ thắng Vừa/Lớn ([KeyStyle.fontScale]).
        val st = theme.keyStyle
        val slider = st.fontScale != null
        val controlScale = if (slider) st.controlScale else labelSize.controlScale
        val hintScale = if (slider) st.hintScale else labelSize.hintScale
        controlPaint.textSize = theme.sp(CONTROL_SP * controlScale)
        digitPaint.textSize = theme.sp(DIGIT_SP * controlScale)
        sidePaint.textSize = theme.sp(SIDE_SP * controlScale)
        hintPaint.textSize = theme.sp(HINT_SP * hintScale)
        controlOff = theme.centerOffset(controlPaint)
        digitOff = theme.centerOffset(digitPaint)
        sideOff = theme.centerOffset(sidePaint)
        hintOff = theme.centerOffset(hintPaint)
        iconScale = controlScale
        fittedKeyW = -1f
        fitLetterLabels()
        invalidate()
    }

    /**
     * Chữ cái / số / dấu câu: cỡ theo [labelSize], KẸP để chữ rộng nhất ("W") còn chừa lề trong phím
     * chữ hẹp nhất (một tay, máy hẹp, cỡ chữ hệ thống lớn) — [KeyLabelFit]. Gọi sau mỗi lần dựng layout.
     */
    /**
     * Nhãn chữ bảng sửa: MỘT cỡ chung cho mọi ô (cỡ phím chức năng, thu nhỏ đều khi nhãn dài
     * nhất không vừa ô hẹp nhất — một tay / máy hẹp), không cắt chữ, không ô nào lệch cỡ.
     */
    private fun fitEditLabels() {
        editPaint.set(controlPaint)
        val pad = theme.dp(6f)
        var scale = 1f
        for (k in keys) {
            if (k.kind != KeyKind.EDIT || k.label.isEmpty()) continue
            val a = EditAction.of(k.insert)
            if (a != null && EditPanel.isGlyph(a)) continue
            val w = editPaint.measureText(k.label)
            if (w > 0f) scale = minOf(scale, (k.width - 2 * pad) / w)
        }
        if (scale < 1f) editPaint.textSize = controlPaint.textSize * maxOf(scale, 0.6f)
        editOff = theme.centerOffset(editPaint)
    }

    private fun fitLetterLabels() {
        var kw = Float.MAX_VALUE
        var kh = Float.MAX_VALUE
        for (k in keys) if (k.kind == KeyKind.LETTER || k.kind == KeyKind.CHAR) {
            if (k.width < kw) kw = k.width
            if (k.height < kh) kh = k.height
        }
        if (kw == Float.MAX_VALUE) { kw = 0f; kh = 0f }
        if (kw == fittedKeyW && kh == fittedKeyH) return
        fittedKeyW = kw; fittedKeyH = kh
        val st = theme.keyStyle
        val want = theme.sp(LETTER_SP * if (st.fontScale != null) st.letterScale else labelSize.letterScale)
        letterPaint.textSize = want
        if (kw > 0f && styledLabels) {
            // Tuỳ chỉnh nâng cao: kẹp theo chữ rộng nhất + mực dấu mũ/móc và phần dưới dòng (lúc
            // dựng layout — KeyLabelFitter, test JVM).
            letterPaint.textSize = fitStyled(letterPaint, want, KeyLabelFitter.KEY_SAMPLE, kw, kh)
        } else if (kw > 0f && labelSize != KeyLabelSize.MEDIUM) {
            letterPaint.textSize = KeyLabelFit.fit(want, theme.sp(LETTER_SP), letterPaint.measureText("W"), kw, theme.dp(KeyLabelFit.PAD_DP))
        }
        letterOff = theme.centerOffset(letterPaint)
    }
    private var fittedKeyH = -1f

    /** Đo [sample] bằng [p] ở cỡ [want] rồi kẹp vừa phím [kw]×[kh] (chữ căn giữa hộp dòng). */
    private fun fitStyled(p: Paint, want: Float, sample: String, kw: Float, kh: Float): Float {
        p.textSize = want
        var w = 0f
        var above = 0f; var below = 0f
        val b = android.graphics.Rect()
        for (i in sample.indices) {
            val g = sample.substring(i, i + 1)
            w = maxOf(w, p.measureText(g))
            p.getTextBounds(g, 0, 1, b)
            above = maxOf(above, -b.top.toFloat()); below = maxOf(below, b.bottom.toFloat())
        }
        val fm = p.fontMetrics
        val f = KeyLabelFitter
        val byWidth = f.size(want, w / want, above / want, below / want, kw, kh, theme.dp(f.SIDE_PAD_DP), theme.dp(f.V_PAD_DP))
        return minOf(byWidth, f.centeredSize(want, -fm.ascent / want, fm.descent / want, above / want, below / want,
            kh - 2 * theme.dp(f.V_PAD_DP)))
    }

    // MARK: touch

    @SuppressLint("ClickableViewAccessibility")
    override fun onTouchEvent(e: MotionEvent): Boolean {
        if (plane == Plane.EMOJI) emojiPane.track(e) else if (plane == Plane.TEMPLATES) templatesPane.track(e)
        when (e.actionMasked) {
            MotionEvent.ACTION_DOWN, MotionEvent.ACTION_POINTER_DOWN -> {
                ImeTrace.keyDown()
                val i = e.actionIndex
                down(e.getPointerId(i), e.getX(i), e.getY(i), e)
            }
            MotionEvent.ACTION_MOVE -> for (i in 0 until e.pointerCount) {
                val pid = e.getPointerId(i)
                if (pid == altPid) altMove(e.getX(i), e.getY(i))
                if (pid == keyCmdPid) keyCmdMove(e.getX(i), e.getY(i))
                if (pid == swipePid) swipeMove(e, i) else move(pid, e.getX(i), e.getY(i))
            }
            MotionEvent.ACTION_UP, MotionEvent.ACTION_POINTER_UP -> {
                val i = e.actionIndex
                // API 33+: hệ thống có thể huỷ MỘT ngón bằng UP mang FLAG_CANCELED thay vì CANCEL.
                up(e.getPointerId(i), e.getX(i), e.getY(i), cancelled = EdgeTouch.upCancelled(e.flags), t = e.eventTime)
            }
            MotionEvent.ACTION_CANCEL -> for (i in 0 until e.pointerCount)
                up(e.getPointerId(i), e.getX(i), e.getY(i), cancelled = true)
        }
        return true
    }

    /**
     * [x] (toạ độ view) nằm trong dải cử chỉ hệ thống trái/phải của cửa sổ IME (vuốt từ mép =
     * Quay lại). Nav 3 nút / API < 29: insets = 0 ⇒ false ngay, không tốn gì thêm.
     */
    private fun inSystemGestureEdge(x: Float): Boolean {
        if (android.os.Build.VERSION.SDK_INT < 29) return false
        val wi = rootWindowInsets ?: return false
        val l: Int; val r: Int
        if (android.os.Build.VERSION.SDK_INT >= 30) {
            val g = wi.getInsets(android.view.WindowInsets.Type.systemGestures()); l = g.left; r = g.right
        } else {
            @Suppress("DEPRECATION") val g = wi.systemGestureInsets; l = g.left; r = g.right
        }
        if (l <= 0 && r <= 0) return false
        getLocationInWindow(edgeLoc)
        return EdgeTouch.inGestureZone(x + edgeLoc[0], rootView.width, l, r)
    }

    private fun down(pid: Int, x: Float, y: Float, e: MotionEvent) {
        if (pid !in 0 until MAX_PTR) return
        if (planeSlidePid >= 0 && pid != planeSlidePid) endPlaneSlide(0f, 0f, cancelled = true)   // ngón thứ hai: bỏ trượt 123
        ptrEdge[pid] = false; ptrEdgeShiftOn[pid] = false
        // Trackpad (giữ phím cách): ngón THỨ HAI chạm bất kỳ đâu ⇒ chuyển sang chọn chữ như bàn
        // phím Apple — không gõ phím dưới ngón đó. Ngoài trackpad: một phép so bool.
        if (TrackpadTouch.swallows(trackpad, pid == spacePtr)) { beginTrackpadSelect(); return }
        // Đang vuốt: ngón khác bỏ qua (không gõ chữ lạc); đang chờ phân loại: khoá là chạm.
        if (swiping) return
        if (swipePid >= 0 && pid != swipePid) { classifier.pointerAdded(); stopSwipeTracking() }
        if (keyCmdPid >= 0 && pid != keyCmdPid) rejectKeyCmd()   // ngón thứ hai ⇒ không phải lệnh
        settleAlt()                       // ký tự phụ đang giữ chốt TRƯỚC phím mới
        settlePopover()                   // popup đang mở chốt ô đang chọn TRƯỚC phím mới
        ptrDownX[pid] = x; ptrDownY[pid] = y
        if (plane == Plane.EMOJI) { commits.flush(); ptrPane[pid] = true; emojiPane.down(pid, x, y); return }
        if (plane == Plane.TEMPLATES && templatesPane.contains(x, y)) {
            commits.flush(); ptrPane[pid] = true; templatesPane.down(pid, x, y); return
        }
        if (plane == Plane.EMOJI_SEARCH && searchBar.contains(y)) {
            commits.flush(); ptrPane[pid] = true; searchBar.down(pid, x); return
        }
        if (railSpan != null && railPtr < 0) {
            val b = OneHand.railButton(width.toFloat(), keyAreaPx, oneHand, x, y)
            if (b >= 0) {
                commits.flush()
                feedback.click(Feedback.MODIFIER, this)
                railPtr = pid; railPressed = b; invalidate()
                return
            }
        }
        val forced = a11yKey
        // ĐẦU TIÊN: chốt các phím nhấc-mới-chốt đang đè (thứ tự khi gõ chồng ngón). Chốt space /
        // dấu ở ?123 có thể về ABC ⇒ tra lại phím ở bố cục mới (FlushRoute).
        val hit = FlushRoute.resolve(
            { forced ?: KeyLayout.hit(keys, plane, x, y, TouchGeometry.yOffset * d, d, e.eventTime - lastLetterDownT) },
            { commits.flush(it) }, { keys })
        cancelCommaHold()                 // ngón khác chạm ⇒ "," đang giữ là gõ thường
        if (TouchLog.enabled) {
            val lag = (SystemClock.uptimeMillis() - e.eventTime).toDouble()
            TouchLog.touchBegan(activeCount(), e.pointerCount, lag, hit != null, (y / d).toDouble(),
                hit?.let { if (it.kind == KeyKind.LETTER) it.label else null })
        }
        if (hit == null) return
        // Chọn phím theo ngữ cảnh (thử nghiệm) — SAU flush để prior thấy từ đang gõ mới nhất.
        // Giữ ⇧ + phím có ký tự phụ ⇒ gõ ký tự phụ: không chọn phím theo ngữ cảnh chữ.
        val shiftSym = if (shiftPtr >= 0 && hit.kind == KeyKind.LETTER && shiftAlts.isNotEmpty())
            shiftHold.symbol(hit.label[0], shiftAlts, e.eventTime) else null
        val prior = if (shiftSym == null && forced == null && hit.kind == KeyKind.LETTER && plane == Plane.LETTERS) letterPrior?.invoke() else null
        val k = if (prior != null) SmartTouch.refine(keys, hit, x, y - TouchGeometry.yOffset * d, prior) else hit
        ptrKey[pid] = k
        // Chạm ở dải mép cử chỉ hệ thống ⇒ tạm: chữ / ⌫ chờ nhấc; chữ, ⌫, space, return bị huỷ ⇒ bỏ.
        val edge = forced == null && (k.kind == KeyKind.LETTER || k.kind == KeyKind.BACKSPACE ||
            k.kind == KeyKind.SPACE || k.kind == KeyKind.RETURN) && inSystemGestureEdge(x)
        ptrEdge[pid] = edge
        if (effects != null || spotlight != null) fxMark(k)
        eyeLook?.let { look ->   // Mắt AI: nhìn về tâm phím (toạ độ view cha) — nhân vật khác ⇒ null
            if (k.kind == KeyKind.LETTER || k.kind == KeyKind.CHAR || k.kind == KeyKind.PAD || k.kind == KeyKind.PUNCT ||
                k.kind == KeyKind.SPACE) look((k.left + k.right) / 2f + left, (k.top + k.bottom) / 2f + top)
        }
        when (k.kind) {
            KeyKind.LETTER -> if (shiftSym != null) {
                // Giữ ⇧: ký tự phụ nguyên văn (VNI không bỏ dấu); không vuốt / lệnh / giữ ký tự phụ.
                feedback.clickKey(k.label, Feedback.LETTER, this)
                pressDown(pid, k)
                if (keyPreview) showBalloon(k, shiftSym)
                if (edge) { val sk = ShiftHold.key(shiftSym); commits.arm(k) { emit(sk) } } else emit(ShiftHold.key(shiftSym))
                lastLetterDownT = e.eventTime
            } else {
                feedback.clickKey(k.label, Feedback.LETTER, this)
                pressDown(pid, k)
                if (keyPreview) showBalloon(k, if (shift == Shift.OFF) k.label else k.upper)
                val ch = (if (shift == Shift.OFF) k.label else k.upper)[0]
                val shiftWas = shift
                // Vuốt phím ra lệnh: chỉ phím có lệnh (c x v a z y). Ô đang có vùng chọn ⇒ chữ CHỜ
                // nhấc mới chèn (KeyCommitQueue) để sao chép/cắt còn vùng chọn; lượt này không gõ
                // vuốt, không ký tự phụ (cả hai cần chữ đã chèn để huỷ).
                val cmdGesture = if (keyCommands && plane == Plane.LETTERS && forced == null && activeCount() == 1)
                    KeyCommandGesture.start(true, k.label[0], x / d, y / d, keyAreaTop() / d, (k.right - k.left) / d)
                    else null
                val selDefer = cmdGesture != null && listener?.keyCommandHasSelection() == true
                // Gõ vuốt bật + chạm có thể thành vuốt ⇒ HOÃN chữ tới lúc nhấc (#172): ngón còn đè
                // thì chưa ghi gì vào ô; chạm ⇒ chữ chèn lúc nhấc (hoặc khi ngón khác chạm xuống),
                // vuốt ⇒ chỉ từ vuốt. Tắt gõ vuốt ⇒ chèn ngay lúc chạm như cũ (không trễ).
                val swipeDefer = !selDefer && !edge && swipeTyping && !splitNow && plane == Plane.LETTERS &&
                    activeCount() == 1 && swipeLayout != null && swipePath != null
                val defer = selDefer || edge || swipeDefer
                ptrEdgeShiftOn[pid] = shiftWas == Shift.ON
                if (selDefer) {
                    val letter = Key.Letter(ch)
                    commits.arm(k) { emit(letter) }
                } else if (edge || swipeDefer) {
                    // Dải mép / gõ vuốt: chữ chốt lúc nhấc / khi ngón khác chạm; mép bị huỷ (vuốt
                    // Quay lại) ⇒ không gõ; thành vuốt ⇒ bỏ (beginSwipe).
                    val letter = Key.Letter(ch)
                    val lt = plane == Plane.LETTERS
                    val dx = (x - (k.left + k.right) / 2) / (k.right - k.left)
                    val dy = (y - TouchGeometry.yOffset * d - (k.top + k.bottom) / 2) / (k.bottom - k.top)
                    commits.arm(k) { if (lt) listener?.onLetterTouch(dx, dy); emit(letter) }
                } else {
                    if (plane == Plane.LETTERS) listener?.onLetterTouch(
                        (x - (k.left + k.right) / 2) / (k.right - k.left),
                        (y - TouchGeometry.yOffset * d - (k.top + k.bottom) / 2) / (k.bottom - k.top))
                    emit(Key.Letter(ch))
                }
                if (shift == Shift.ON) { shift = Shift.OFF; invalidate() }
                val since = e.eventTime - lastLetterDownT
                lastLetterDownT = e.eventTime
                if (cmdGesture != null) {
                    keyCmd = cmdGesture; keyCmdPid = pid; keyCmdDeferred = defer; keyCmdShiftWas = shiftWas
                }
                if (swipeDefer) startSwipeTracking(pid, k, x, y, e.eventTime, since, shiftWas)
                // Mép: vẫn giữ ra ký tự phụ (chữ gốc chốt trước khi ký tự phụ thay nó — settleAlt / up).
                if (!selDefer && alts.isNotEmpty()) armAlt(pid, k, x, y, shiftWas)
            }
            KeyKind.CHAR -> {
                feedback.clickKey(k.label, Feedback.LETTER, this)
                pressDown(pid, k)
                if (keyPreview) showBalloon(k, k.label)
                commits.arm(k, charFire(k))
                armPopover(pid, k, x, y)
            }
            KeyKind.PAD -> {
                feedback.clickKey(k.label, Feedback.LETTER, this)
                press(k)
                commits.arm(k, textFire(k.insert))
            }
            KeyKind.PUNCT -> {
                feedback.clickKey(k.label, Feedback.LETTER, this)
                press(k)
                commits.arm(k, textFire(k.insert))
                if (isVoiceComma(k)) {
                    commaPtr = pid; commaKey = k
                    postDelayed(voiceLongRun, GLOBE_HOLD_MS)
                } else if (isPeriodComma(k)) {
                    commaPtr = pid; commaKey = k; periodFired = false
                    postDelayed(periodRun, KeyAlternates.HOLD_MS)
                } else armPopover(pid, k, x, y)
            }
            KeyKind.SPACE -> {
                feedback.click(Feedback.SPACE, this)
                press(k)
                commits.arm(k, spaceFire)
                spacePtr = pid
                spaceDownKey = k
                flickDownT = e.eventTime
                spaceHoldGone = false
                removeCallbacks(spaceHoldRun)
                postDelayed(spaceHoldRun, SPACE_HOLD_MS)
            }
            KeyKind.RETURN -> {
                feedback.click(Feedback.RETURN, this)
                press(k)
                commits.arm(k, newlineFire)
                if (holdNewline) {
                    returnPtr = pid
                    removeCallbacks(returnHoldRun)
                    postDelayed(returnHoldRun, RETURN_HOLD_MS)
                }
            }
            KeyKind.SHIFT -> {
                shift = fromCase(shiftHold.down(toCase(shift), e.eventTime))
                // Sau khi đổi: Piano cần biết Shift một-lần hay Caps (pedal); kiểu khác = tiếng chức năng.
                feedback.shiftPressed(pedalShift(shift), this)
                shiftPtr = pid
                k.pressed = true
                invalidate()   // mọi nhãn chữ đổi hoa/thường
            }
            KeyKind.BACKSPACE -> {
                feedback.click(Feedback.DELETE, this)
                press(k)
                if (edge) commits.arm(k) { emit(Key.Backspace) } else emit(Key.Backspace)
                bsPtr = pid; bsRepeating = false
                bsSwipe = 0; bsSwipeAsked = 0; bsSwipeWords = 0
                removeCallbacks(bsStartRun); removeCallbacks(bsTickRun)
                postDelayed(bsStartRun, BS_HOLD_MS)
            }
            KeyKind.EDIT -> {
                feedback.click(Feedback.MODIFIER, this)
                press(k)
                val a = EditAction.of(k.insert)
                // Mũi tên / xoá: chạy NGAY lúc chạm (như ⌫), giữ thì lặp; ô khác chạy lúc nhấc.
                if (a != null && a.repeats) {
                    fireEdit(k)
                    editPtr = pid; editRepeatKey = k
                    removeCallbacks(editRepeatRun)
                    postDelayed(editRepeatRun, EDIT_HOLD_MS)
                }
            }
            KeyKind.GLOBE, KeyKind.EMOJI -> {
                // 😊: bấm = plane emoji (lúc nhấc), giữ lâu = danh sách bàn phím (thay phím 🌐).
                feedback.click(Feedback.MODIFIER, this)
                press(k)
                globePtr = pid; globeFired = false
                removeCallbacks(globeLongRun); removeCallbacks(emojiMenuRun)
                // 😊 + popup bật: giữ = menu (🌐 🎤 ✋ ⚙); 🌐 thật / TalkBack: danh sách bàn phím như cũ.
                if (k.kind == KeyKind.EMOJI && popoversEnabled) { menuX = x; menuY = y; postDelayed(emojiMenuRun, KeyAlternates.HOLD_MS) }
                else postDelayed(globeLongRun, GLOBE_HOLD_MS)
            }
            KeyKind.PLANE -> {
                feedback.click(Feedback.MODIFIER, this)
                if (plane == Plane.LETTERS && forced == null) {
                    // #171: 123 ở plane chữ đổi sang plane số NGAY lúc chạm; ngón trượt sang phím ký
                    // tự rồi nhấc ⇒ chèn + về chữ (PlaneSlide). Nhấc tại chỗ ⇒ ở lại plane số như cũ.
                    ptrKey[pid] = null
                    planeSlidePid = pid
                    planeSlide = PlaneSlide()
                    controlAction(k)
                } else press(k)   // ABC / TalkBack: hành động lúc nhấc như cũ
            }
            else -> {   // MORE, EMOJI, CLEAR, DISMISS: hành động lúc nhấc
                feedback.click(Feedback.MODIFIER, this)
                press(k)
            }
        }
    }

    private fun move(pid: Int, x: Float, y: Float) {
        if (pid !in 0 until MAX_PTR) return
        if (pid == planeSlidePid) { planeSlideMove(pid, x, y); return }
        if (ptrPane[pid]) {
            when (plane) {
                Plane.EMOJI -> emojiPane.move(pid, x, y)
                Plane.EMOJI_SEARCH -> searchBar.move(pid, x)
                else -> templatesPane.move(pid, x, y)
            }
            return
        }
        // Trôi khỏi phím chữ / số (sang phím khác) ⇒ bỏ sẫm.
        pressHL?.let { if (it.drift(pid, x, y + top, slop)) balloon.invalidatePress(pid) }
        if (pid == popPid) popoverMove(x, y)
        if (pid == globePtr) { menuX = x; menuY = y; emojiMenuMove(x, y) }
        val k = ptrKey[pid] ?: return
        val movedFar = abs(x - ptrDownX[pid]) > slop || abs(y - ptrDownY[pid]) > slop
        when {
            k.kind == KeyKind.SPACE && pid == spacePtr -> {
                if (trackpad) {
                    // dp: cùng ngưỡng với iOS (pt). Trục/tăng tốc: TrackpadGesture.
                    trackpadGesture.move(x / d, y / d, SystemClock.uptimeMillis())?.let {
                        trackpadBatch.add(it)?.let { prev -> sendTrackpadStep(prev) }
                        if (!trackpadFramePosted) {
                            trackpadFramePosted = true
                            Choreographer.getInstance().postFrameCallback(trackpadFrame)
                        }
                    }
                } else {
                    if (movedFar) { removeCallbacks(spaceHoldRun); spaceHoldGone = true }
                    if (spaceFlickEnabled && plane != Plane.EMOJI_SEARCH && languageOnSpace) moveFlick(x - ptrDownX[pid], y - ptrDownY[pid])
                }
            }
            k.kind == KeyKind.BACKSPACE && pid == bsPtr -> moveBackspace(k, x - ptrDownX[pid], y - ptrDownY[pid], movedFar)
            pid == commaPtr && movedFar && !periodFired -> cancelCommaHold()   // đã ra "." thì trôi không huỷ
        }
    }

    private fun up(pid: Int, x: Float, y: Float, cancelled: Boolean, t: Long = SystemClock.uptimeMillis()) {
        if (pid !in 0 until MAX_PTR) return
        if (pid == planeSlidePid) { endPlaneSlide(x, y, cancelled); return }
        if (ptrPane[pid]) {
            ptrPane[pid] = false
            if (plane == Plane.EMOJI) emojiPane.up(pid, x, y, cancelled)
            else if (plane == Plane.TEMPLATES) templatesPane.up(pid, x, y, cancelled)
            else if (plane == Plane.EMOJI_SEARCH) searchBar.up(pid, x, cancelled)
            return
        }
        if (pid == railPtr) {
            val b = railPressed
            railPtr = -1; railPressed = -1; invalidate()
            if (!cancelled && OneHand.railButton(width.toFloat(), keyAreaPx, oneHand, x, y) == b) {
                listener?.onOneHandChange(if (b == 0) OneHand.switched(oneHand) else OneHandSide.OFF)
            }
            return
        }
        pressUp(pid)
        if (pid == keyCmdPid && keyCmdUp(pid, x, y, cancelled, t)) return
        if (pid == swipePid) {
            val wasSwiping = swiping
            stopSwipeTracking()
            if (wasSwiping) { finishSwipe(pid, x, y, t, cancelled); return }
        }
        val k = ptrKey[pid] ?: run { if (TouchLog.enabled) TouchLog.touchEnded(cancelled, false); return }
        ptrKey[pid] = null
        val edge = ptrEdge[pid]
        ptrEdge[pid] = false
        if (TouchLog.enabled) TouchLog.touchEnded(cancelled, true)
        when (k.kind) {
            KeyKind.LETTER -> {
                hideBalloon(k)
                // chữ chờ nhấc (vuốt-ra-lệnh khi có vùng chọn / chạm ở dải mép); thường là no-op.
                // Chạm mép bị huỷ (vuốt Quay lại) ⇒ bỏ chữ + ký tự phụ, trả Shift một-lần.
                val kept = EdgeTouch.settle(commits, k, edge, cancelled)
                var alt: String? = null
                if (pid == altPid) {
                    alt = altHold?.commit
                    dropAlt()
                    if (alt != null && kept) commitAlt(alt, k)   // cancel ngoài mép vẫn chốt như chữ thường
                }
                // "Vuốt phím xuống ra ký tự phụ": chưa thành giữ, nhấc ở dưới điểm chạm ⇒ cùng đường thay chữ.
                if (pid == flickPid) {
                    flickPid = -1
                    if (alt == null && kept && !cancelled &&
                        KeyAlternates.flickDownEnabled(flickDownSetting, swipeTyping, alts) &&
                        KeyAlternates.isFlickDown((x - flickX0) / d, (y - flickY0) / d)) {
                        alts[k.label[0]]?.let { commitAlt(it, k) }
                    }
                }
                if (!kept && ptrEdgeShiftOn[pid] && shift == Shift.OFF) { shift = Shift.ON; invalidate() }
            }
            KeyKind.CHAR -> {
                hideBalloon(k); commits.release(k)   // popup đã mở ⇒ chèn ô đang chọn
                if (pid == popPid) dropPopover()
            }
            KeyKind.PUNCT, KeyKind.PAD -> {
                if (pid == commaPtr) cancelCommaHold()
                commits.release(k)        // giữ lâu giọng nói ⇒ disarm rồi, không chèn gì; giữ ra "." ⇒ chèn "."
                if (pid == popPid) dropPopover()
            }
            KeyKind.RETURN -> {
                if (pid == returnPtr) { removeCallbacks(returnHoldRun); returnPtr = -1; hideBalloon(k) }
                // đã giữ lâu ⇒ đã disarm, không có gì để chốt; chạm mép bị huỷ ⇒ không gửi
                EdgeTouch.settle(commits, k, edge, cancelled)
            }
            KeyKind.SPACE -> {
                if (pid == spacePtr) {
                    removeCallbacks(spaceHoldRun); spacePtr = -1
                    if (spaceFlickEnabled && !trackpad && languageOnSpace) endFlick(k, x - ptrDownX[pid], y - ptrDownY[pid], t, cancelled)
                    // Cancel VẪN chốt (KeyCommitQueue) — trừ chạm ở dải mép (vuốt Quay lại);
                    // trackpad đã disarm nên không có space.
                    EdgeTouch.settle(commits, k, edge, cancelled)
                    if (trackpad) endTrackpad()
                } else EdgeTouch.settle(commits, k, edge, cancelled)
            }
            KeyKind.BACKSPACE -> if (pid == bsPtr) {
                EdgeTouch.settle(commits, k, edge, cancelled)   // ⌫ chạm ở mép: chốt lúc nhấc, huỷ ⇒ bỏ
                removeCallbacks(bsStartRun); removeCallbacks(bsTickRun)
                bsPtr = -1; bsRepeating = false
                endSwipe(commit = !cancelled)
            }
            KeyKind.GLOBE -> if (pid == globePtr) {
                removeCallbacks(globeLongRun); globePtr = -1
                if (!globeFired && !cancelled) listener?.onGlobe(false)
            }
            KeyKind.EMOJI -> if (pid == globePtr) {
                removeCallbacks(globeLongRun); removeCallbacks(emojiMenuRun); globePtr = -1
                val menu = menuHold
                if (menu != null) {
                    val a = menu.selection?.let { menuActions.getOrNull(it) }
                    dropEmojiMenu()
                    k.pressed = false; invalidateKey(k)
                    if (a != null && !cancelled) runMenuAction(a)
                } else if (!globeFired && !cancelled) controlAction(k)
            }
            KeyKind.SHIFT -> if (pid == shiftPtr) {
                shiftPtr = -1
                // ⇧ vừa làm phím bổ trợ: chọn chữ ⇒ trả shift như trước khi chạm; ký tự phụ ⇒ không
                // để lại một-lần (Caps Lock giữ nguyên) — ShiftHold.up.
                val s = fromCase(shiftHold.up(toCase(shift)))
                if (s != shift) shift = s
            }
            KeyKind.EDIT -> if (pid == editPtr) {
                removeCallbacks(editRepeatRun); editPtr = -1; editRepeatKey = null
            } else if (!cancelled) fireEdit(k)
            else -> if (!cancelled) controlAction(k)
        }
        if (k.pressed) { k.pressed = false; if (k.kind == KeyKind.SHIFT) invalidate() else invalidateKey(k) }
    }

    // MARK: vuốt ⌫ xoá theo từ (kiểu Gboard)

    /** Bước kéo = bề rộng một phím chữ (plane số/ký hiệu: phím CHAR). */
    private fun swipeStepPx(): Float =
        maxOf(theme.dp(24f), keys.firstOrNull { it.kind == KeyKind.LETTER || it.kind == KeyKind.CHAR }?.width ?: theme.dp(32f))

    private fun moveBackspace(k: LaidKey, dx: Float, dy: Float, movedFar: Boolean) {
        if (bsRepeating || plane == Plane.EMOJI_SEARCH) return   // giữ-lặp / ô tìm: không vuốt xoá từ
        if (movedFar) removeCallbacks(bsStartRun)
        val step = swipeStepPx()
        val act = SwipeDelete.activatePx(step, theme.dp(16f))
        if (bsSwipe == 0 && SwipeDelete.activates(dx, dy, act)) {
            commits.release(k)            // ⌫ chạm ở mép: như chạm thường, ⌫ đầu chạy trước khi vuốt xoá
            bsSwipe = if (listener?.onSwipeDeleteStart() == true) 1 else -1
        }
        if (bsSwipe != 1) return
        val want = SwipeDelete.words(-dx, act, step)
        if (want == bsSwipeAsked) return
        bsSwipeAsked = want
        val got = listener?.onSwipeDeleteUpdate(want) ?: 0
        if (got != bsSwipeWords) {
            bsSwipeWords = got
            feedback.tick(this)
            invalidateKey(k)
        }
    }

    private fun endSwipe(commit: Boolean) {
        val was = bsSwipe
        bsSwipe = 0; bsSwipeAsked = 0; bsSwipeWords = 0
        if (was == 1) listener?.onSwipeDeleteEnd(commit)
    }

    // MARK: trượt từ phím 123 (#171) — PlaneSlide

    private var planeSlidePid = -1
    private var planeSlide: PlaneSlide<LaidKey>? = null

    /** Phím ký tự (CHAR, chèn được) của plane hiện tại chứa điểm — khe / phím khác ⇒ null. */
    private fun slideInsertKey(x: Float, y: Float): LaidKey? {
        for (i in keys.indices) { val k = keys[i]; if (k.kind == KeyKind.CHAR && k.contains(x, y)) return k }
        return null
    }

    private fun planeSlideMove(pid: Int, x: Float, y: Float) {
        val s = planeSlide ?: return
        val c = s.move(slideInsertKey(x, y)) ?: return
        c.leave?.let { pressUp(pid); hideBalloon(it); it.pressed = false; invalidateKey(it) }
        c.enter?.let { pressDown(pid, it); press(it); if (keyPreview) showBalloon(it, it.label) }
    }

    /** Kết thúc trượt: nhấc trên phím ký tự ⇒ chèn như chạm thường rồi về chữ; còn lại không gì. */
    private fun endPlaneSlide(x: Float, y: Float, cancelled: Boolean) {
        val s = planeSlide ?: return
        val pid = planeSlidePid
        planeSlide = null; planeSlidePid = -1
        s.over?.let { pressUp(pid); hideBalloon(it); it.pressed = false; invalidateKey(it) }
        val k = PlaneSlide.lift(if (cancelled) null else slideInsertKey(x, y), cancelled) ?: return
        // Đúng đường chạm thường của phím CHAR: âm/rung, hiệu ứng, KeyCommitQueue, emit (PlanePolicy).
        fxMark(k)
        feedback.clickKey(k.label, Feedback.LETTER, this)
        commits.flush()
        commits.arm(k, charFire(k))
        commits.release(k)
        if (plane != Plane.LETTERS) setPlane(Plane.LETTERS)   // như chạm ABC
    }

    /** Test: tâm phím đổi plane (123 / ABC) đang hiện. */
    internal fun planeKeyCenter(): android.graphics.PointF? =
        keys.firstOrNull { it.kind == KeyKind.PLANE }?.let { android.graphics.PointF(it.centerX, it.centerY) }
    /** Test: tâm phím ⌫. */
    internal fun backspaceCenter(): android.graphics.PointF? =
        keys.firstOrNull { it.kind == KeyKind.BACKSPACE }?.let { android.graphics.PointF(it.centerX, it.centerY) }

    private fun controlAction(k: LaidKey) {
        when (k.kind) {
            KeyKind.PLANE -> setPlane(if (plane == Plane.LETTERS || plane == Plane.EMOJI_SEARCH) Plane.NUMBERS
                                      else inputKind.padPlane ?: Plane.LETTERS)
            KeyKind.MORE -> setPlane(if (plane == Plane.NUMBERS) Plane.SYMBOLS else Plane.NUMBERS)
            KeyKind.EMOJI -> setPlane(Plane.EMOJI)
            KeyKind.CLEAR -> emit(Key.ClearField)
            KeyKind.DISMISS -> listener?.onDismissKeyboard()
            KeyKind.PASTE -> listener?.onPadPaste()
        }
    }

    private fun press(k: LaidKey) { k.pressed = true; invalidateKey(k) }

    private fun activeCount(): Int { var n = 0; for (k in ptrKey) if (k != null) n++; return n }

    private fun cancelAllTouches() {
        endPlaneSlide(0f, 0f, cancelled = true)
        abortSwipe()
        endKeyCmd()
        shiftPtr = -1; shiftHold.cancel()
        dropAlt()
        // Bàn phím ẩn / đổi một tay giữa lúc popup mở: không chèn đuôi đang chọn (flush dưới).
        popKey?.let { if (popHold?.fired == true) commits.disarm(it) }
        dropPopover()
        dropEmojiMenu()
        for (i in 0 until MAX_PTR) {
            // Chạm ở dải mép chưa nhấc mà bàn phím ẩn (Quay lại tới trước CANCEL) ⇒ huỷ, không chốt.
            if (ptrEdge[i]) ptrKey[i]?.let { EdgeTouch.settle(commits, it, edge = true, cancelled = true) }
            ptrEdge[i] = false
            ptrKey[i]?.pressed = false
            ptrKey[i] = null; ptrPane[i] = false
        }
        commits.flush()
        endSwipe(commit = false)
        removeCallbacks(spaceHoldRun); removeCallbacks(bsStartRun); removeCallbacks(bsTickRun)
        removeCallbacks(globeLongRun); removeCallbacks(emojiMenuRun); removeCallbacks(returnHoldRun); removeCallbacks(editRepeatRun)
        cancelCommaHold()
        spacePtr = -1; bsPtr = -1; globePtr = -1; returnPtr = -1; bsRepeating = false
        editPtr = -1; editRepeatKey = null; railPtr = -1; railPressed = -1
        if (trackpad) endTrackpad()
        balloon.hide(); balloonOwner = null
        balloon.clearPress()
        invalidate()
    }

    // MARK: gõ vuốt

    /** Tâm phím chữ a–z (plane chữ) → decoder; bước phím = khoảng cách tâm q→w. */
    private fun publishSwipeLayout() {
        if (!swipeTyping || plane != Plane.LETTERS || keys.isEmpty()) return
        // Tách đôi: gõ vuốt tạm tắt (G/V lặp, khe giữa) — không phát layout, không theo dõi ngón.
        if (splitNow) { abortSwipe(); return }
        val m = KeyLayout.letterCenters(keys)
        val q = m['q'] ?: return
        val w = m['w'] ?: return
        val kw = w.first - q.first
        if (kw <= 0f) return
        val l = SwipeLayout(kw, m)
        if (l == swipeLayout) return
        abortSwipe()
        swipeLayout = l
        swipePath = SwipePath(minDistance = kw / 5f)
        swipeSound?.setLayout(l, d)   // âm nét vuốt dò phím (Nốt nhạc theo phím, Sáo trúc)
        listener?.onSwipeLayout(l)
    }

    private fun startSwipeTracking(pid: Int, k: LaidKey, x: Float, y: Float, t: Long, since: Long, shiftWas: Shift) {
        val l = swipeLayout ?: return
        val p = swipePath ?: return
        classifier.begin(x / d, y / d, t, k.left / d, k.top / d, k.right / d, k.bottom / d, l.keyWidth / d, since)
        p.reset()
        p.add(x, y - yOffPx, t / 1000.0)
        swipePid = pid; swipeKey = k; swipeShift = shiftWas
    }

    private fun stopSwipeTracking() {
        classifier.end()
        swipePid = -1
        swiping = false
        swipeKey = null
    }

    /** ACTION_MOVE của ngón đang theo dõi: duyệt cả điểm lịch sử (vuốt nhanh gộp nhiều mẫu/khung). */
    private fun swipeMove(e: MotionEvent, i: Int) {
        for (h in 0 until e.historySize) {
            swipePoint(e.getHistoricalX(i, h), e.getHistoricalY(i, h), e.getHistoricalEventTime(h))
            if (swipePid < 0) return
        }
        swipePoint(e.getX(i), e.getY(i), e.eventTime)
    }

    private fun swipePoint(x: Float, y: Float, t: Long) {
        val p = swipePath ?: return
        p.add(x, y - yOffPx, t / 1000.0)
        if (swiping) { trail?.add(x, y, t); swipeSound?.move(x / d, (y - yOffPx) / d, t); return }   // cùng toạ độ swipePath (begin)
        // Đang là ứng viên vuốt-lên-ra-lệnh: chưa cho thành gõ vuốt (bị loại ⇒ chạy tiếp với cả đường).
        if (swipePid == keyCmdPid && keyCmd?.live == true) return
        when (classifier.move(x / d, y / d, t)) {
            GestureClassifier.State.SWIPE -> beginSwipe(p)
            GestureClassifier.State.TAP -> stopSwipeTracking()
            else -> Unit
        }
    }

    private fun beginSwipe(p: SwipePath) {
        if (listener?.onSwipeTypingStart() != true) { stopSwipeTracking(); return }
        swiping = true
        dropAlt()
        pressUp(swipePid)
        swipeKey?.let { hideBalloon(it); commits.disarm(it) }   // chữ đầu hoãn: bỏ, chưa từng chèn
        // Chữ đầu bỏ ⇒ shift một-lần bị nhả lúc chạm phải bật lại (từ vuốt viết hoa).
        if (swipeShift == Shift.ON && shift == Shift.OFF) { shift = Shift.ON; invalidate() }
        swipeSound?.let { s ->
            // Từ điểm chạm đầu, đưa nốt các điểm đã có: Nốt nhạc theo phím gảy cả phím bắt đầu + phím đi qua lúc phân loại.
            if (p.count > 0) s.begin(p.xs[0] / d, p.ys[0] / d, (p.ts[0] * 1000).toLong())
            for (j in 1 until p.count) s.move(p.xs[j] / d, p.ys[j] / d, (p.ts[j] * 1000).toLong())
        }
        val tr = trail ?: return
        // Phím sáng theo đường / Ma trận: khung phím chữ — một lần mỗi cú vuốt (kiểu khác: 0 việc).
        if (tr.style.usesKeys) tr.setKeys(keys, yOffPx)
        tr.begin()
        for (j in 0 until p.count) tr.add(p.xs[j], p.ys[j] + yOffPx, (p.ts[j] * 1000).toLong())
    }

    private fun finishSwipe(pid: Int, x: Float, y: Float, t: Long, cancelled: Boolean) {
        ptrKey[pid]?.let { hideBalloon(it) }
        ptrKey[pid] = null
        val p = swipePath
        swipeSound?.let { s ->
            if (cancelled || p == null) s.end()   // huỷ: không có tiếng nhấc tay
            else { s.move(x / d, (y - yOffPx) / d, t); s.end(liftAtMs = t) }
        }
        if (cancelled || p == null) {
            trail?.end(fade = false)
            listener?.onSwipeTypingCancel()
            return
        }
        p.add(x, y - yOffPx, t / 1000.0, force = true)
        trail?.end(fade = true)
        val case = when (shift) {
            Shift.CAPS -> SwipeSuggest.Case.ALL
            Shift.ON -> SwipeSuggest.Case.FIRST
            Shift.OFF -> SwipeSuggest.Case.LOWER
        }
        listener?.onSwipeTypingEnd(p, case)
        if (shift == Shift.ON) { shift = Shift.OFF; invalidate() }
    }

    /** Controller đã chốt từ vuốt ⇒ "Pháo hoa cuối nét" ở chỗ nhấc tay (kiểu khác: 0 việc). */
    fun swipeCommitted() { trail?.commitBurst() }

    /** "Từ khoá" theo từ vuốt: hẹn chùm (đã xếp ở overlay) tại chỗ nhấc tay — toạ độ overlay như [fxAfter]. */
    fun burstAtSwipeLift(path: SwipePath) {
        val j = path.count - 1
        if (j < 0) return
        effects?.let { it.burst(path.xs[j] + left - it.left, path.ys[j] + yOffPx + top - it.top) }
    }

    /** Bỏ lượt vuốt đang dở (ẩn bàn phím / đổi layout / tắt tính năng). */
    private fun abortSwipe() {
        val was = swiping
        val pid = swipePid
        stopSwipeTracking()
        if (!was) return
        if (pid in 0 until MAX_PTR) { ptrKey[pid]?.let { hideBalloon(it) }; ptrKey[pid] = null }
        trail?.end(fade = false)
        swipeSound?.end()
        listener?.onSwipeTypingCancel()
    }

    // MARK: vuốt phím thẳng lên ⇒ lệnh (KeyCommandGesture)

    /** Mép trên hàng phím (kể cả hàng số) — toạ độ view. Chỉ gọi lúc chạm phím CÓ lệnh. */
    private fun keyAreaTop(): Float {
        var t = Float.MAX_VALUE
        for (k in keys) if (k.top < t) t = k.top
        return if (t == Float.MAX_VALUE) 0f else t
    }

    private fun keyCmdMove(x: Float, y: Float) {
        val g = keyCmd ?: return
        when (g.move(x / d, y / d)) {
            KeyCommandGesture.Event.ARMED -> showKeyCmd(g.command, x)
            KeyCommandGesture.Event.DISARMED -> hideKeyCmd()
            KeyCommandGesture.Event.REJECTED -> rejectKeyCmd()
            KeyCommandGesture.Event.NONE -> Unit
        }
    }

    /** Nhãn lệnh nổi trên hàng phím đầu (ngón đang ở thanh gợi ý nên không che) + rung nhẹ. */
    private fun showKeyCmd(cmd: KeyCommand, x: Float) {
        ptrKey[keyCmdPid]?.let { hideBalloon(it) }
        dropAlt()
        val label = listener?.keyCommandLabel(cmd) ?: tr(cmd.label)
        val w = theme.dp(132f); val h = theme.dp(if (theme.tablet) 52f else 46f)
        val l = (x - w / 2).coerceIn(0f, maxOf(0f, width - w))
        val t = keyAreaTop() + top + theme.dp(4f)
        balloon.showPopup(l, t, l + w, t + h, floatArrayOf(l + theme.dp(4f)), w - theme.dp(8f), listOf(label), 17f, 0)
        keyCmdShown = true
        feedback.tick(this)
    }

    private fun hideKeyCmd() {
        if (!keyCmdShown) return
        keyCmdShown = false
        balloon.hidePopup()
    }

    /** Không còn là lệnh (ngón thứ hai / lệch ngang / kéo xuống / popup): chữ giữ nguyên như chạm thường. */
    private fun rejectKeyCmd() {
        keyCmd?.reject()
        hideKeyCmd()
        keyCmd = null; keyCmdPid = -1
        // Chữ đang chờ (vùng chọn) vẫn trong commits: chèn ở lúc nhấc / phím kế như phím thường.
    }

    private fun endKeyCmd() {
        hideKeyCmd()
        keyCmd = null; keyCmdPid = -1; keyCmdDeferred = false
    }

    /**
     * Nhấc ngón đang theo dõi lệnh. true = lệnh đã chạy. false = chạm/vuốt thường tiếp tục ở
     * [up]; ứng viên chưa bật mà gõ vuốt đang chờ ⇒ cho bộ phân loại xem điểm cuối (vuốt dọc
     * "xe" nhấc trong vùng phím vẫn là gõ vuốt).
     */
    private fun keyCmdUp(pid: Int, x: Float, y: Float, cancelled: Boolean, t: Long): Boolean {
        val g = keyCmd ?: return false
        val wasLive = g.live
        val cmd = if (cancelled) null else g.release(x / d, y / d)
        val deferred = keyCmdDeferred
        endKeyCmd()
        if (cmd == null) {
            if (wasLive && pid == swipePid && !swiping) swipePoint(x, y, t)
            return false
        }
        if (pid == swipePid) stopSwipeTracking()
        if (pid == altPid) dropAlt()
        val k = ptrKey[pid]
        ptrKey[pid] = null
        if (k != null) {
            hideBalloon(k)
            if (deferred) commits.disarm(k)
            if (k.pressed) { k.pressed = false; invalidateKey(k) }
        }
        // Chữ đầu đã nhả shift một lần — trả lại (lệnh không gõ chữ).
        if (keyCmdShiftWas == Shift.ON && shift == Shift.OFF) { shift = Shift.ON; invalidate() }
        listener?.onKeyCommand(cmd, deferred)
        return true
    }

    // MARK: giữ phím ra ký tự phụ

    /** Chạm phím có ký tự phụ: hẹn giờ [KeyAlternates.HOLD_MS]; chữ đã chèn lúc chạm (hoãn ⇒ chèn trước khi thay). */
    private fun armAlt(pid: Int, k: LaidKey, x: Float, y: Float, shiftWas: Shift) {
        val alt = alts[k.label[0]] ?: return
        altHold = KeyAlternates.Hold(alt, x / d, y / d)
        altPid = pid; altKey = k; altShiftWas = shiftWas
        flickPid = pid; flickX0 = x; flickY0 = y
        removeCallbacks(altRun)
        postDelayed(altRun, KeyAlternates.HOLD_MS)
    }

    private fun altMove(x: Float, y: Float) {
        if (altHold?.move(x / d, y / d) == true) dropAlt()
    }

    /** Hết giờ, ngón chưa trôi / chưa thành vuốt ⇒ balloon hiện ký tự phụ (kể cả khi tắt phóng to chữ). */
    private fun fireAlt() {
        val h = altHold ?: return
        val k = altKey ?: return
        if (swiping || !h.fire()) return
        if (swipePid == altPid) stopSwipeTracking()   // đã là giữ: trôi sau đó không thành vuốt
        if (keyCmdPid == altPid) rejectKeyCmd()       // popup ký tự phụ ⇒ không phải lệnh
        feedback.longPress(this)
        showBalloon(k, h.alt)
    }

    /** Ngón mới chạm: giữ chưa đủ giờ ⇒ chỉ là chạm; đã bắn ⇒ chốt NGAY (checkpoint đúng phím). */
    private fun settleAlt() {
        val h = altHold ?: return
        val k = altKey
        dropAlt()
        val alt = h.commit ?: return
        // Chữ gốc còn chờ (chạm ở dải mép) ⇒ chốt trước để ký tự phụ thay đúng nó.
        if (k != null) { hideBalloon(k); commits.release(k); commitAlt(alt, k) }
    }

    private fun dropAlt() {
        if (altHold == null) return
        removeCallbacks(altRun)
        altHold = null; altPid = -1; altKey = null
    }

    private fun commitAlt(alt: String, k: LaidKey) {
        hideBalloon(k)
        if (altShiftWas == Shift.ON && shift == Shift.OFF) { shift = Shift.ON; invalidate() }
        emit(Key.Text(alt, replacesLetter = true))
    }

    // MARK: popup nhiều lựa chọn (DomainPopup / KeyVariants)

    /** Lựa chọn của phím [k] trên plane hiện tại; rỗng ⇒ không hẹn giờ (0 chi phí). */
    private fun popoverChoices(k: LaidKey): List<String> {
        if (!popoversEnabled) return emptyList()
        return when (plane) {
            Plane.LETTERS -> if (k.kind != KeyKind.PUNCT) emptyList() else DomainPopup.choices(
                when (inputKind) {
                    InputKind.URL -> DomainPopup.Field.URL
                    InputKind.EMAIL -> DomainPopup.Field.EMAIL
                    else -> DomainPopup.Field.NORMAL
                }, k.label, lettersPlane = true).ifEmpty { CommaPopup.choices(k.label, lettersPlane = true, periodKey = periodSideKey) }
            Plane.NUMBERS, Plane.SYMBOLS -> KeyVariants.variants(k.label, symbolPlane = true,
                numericField = inputKind.padPlane != null)
            else -> emptyList()
        }
    }

    /** Chạm phím có popup (đã arm ký tự gốc): hẹn giờ như giữ phím chữ. */
    private fun armPopover(pid: Int, k: LaidKey, x: Float, y: Float) {
        val choices = popoverChoices(k)
        if (choices.isEmpty()) return
        dropPopover()
        popHold = DomainPopup.Hold(choices)
        popPid = pid; popKey = k; popX = x; popY = y
        popVariants = plane != Plane.LETTERS || k.label == "," || isPeriodPopup(k)    // ô hẹp, chữ lớn như biến thể ký tự
        postDelayed(popRun, KeyAlternates.HOLD_MS)
    }

    /** Hết giờ: phím còn chờ chốt ⇒ mở popup (ô gốc chọn sẵn), nhấc/ngón khác chạm chèn ô đang chọn. */
    private fun firePopover() {
        val h = popHold ?: return
        val k = popKey ?: return
        val n = h.choices.size
        val wDp = width / d
        // "," bàn chữ: 10 ô ⇒ ô hẹp hơn để hàng loe từ phím (cạnh phải space) sang trái gọn.
        val comma = plane == Plane.LETTERS && (k.label == "," || isPeriodPopup(k))
        val itemW = if (comma) CommaPopup.itemWidthDp(theme.tablet)
            else if (popVariants) (if (theme.tablet) 56f else 38f) else (if (theme.tablet) 68f else 56f)
        // Toạ độ dp theo overlay (strip + phím): popup được phép lấn lên strip, kẹp ở 0.
        val off = top / d
        val panelH = if (theme.tablet) 52f else 46f
        val keyTop = k.top / d + off
        // Chật một hàng ⇒ hai hàng chồng lên (#154) — chỉ khi phía trên đủ chỗ cho cả hai.
        val l = DomainPopup.layout(k.centerX / d, itemW, n, wDp, rowHeight = panelH,
            maxRows = if (keyTop - 8f - 2 * panelH >= 0f) 2 else 1)
        val popTop = maxOf(keyTop - 8f - panelH * l.rows, 0f)
        val ok = h.fire(commits, k, l, popTop, k.bottom / d + off, popX / d, popY / d + off) { s -> emit(Key.Text(s)) }
        if (!ok) { dropPopover(); return }
        hideBalloon(k)
        val inset = 4f
        balloon.showPopup((l.originX - inset) * d, popTop * d, (l.originX + l.width + inset) * d, (popTop + panelH * l.rows) * d,
            FloatArray(n) { l.slotMinX(it) * d }, l.itemWidth * d, h.choices,
            if (popVariants) (if (theme.tablet) 26f else 24f) else (if (theme.tablet) 20f else 18f),
            h.selection ?: -1, rowH = panelH * d, slotRows = IntArray(n) { l.rows - 1 - l.rowOf(it) })
        feedback.tick(this)
    }

    private fun popoverMove(x: Float, y: Float) {
        popX = x; popY = y
        val h = popHold ?: return
        if (!h.fired || !h.move(x / d, y / d + top / d)) return
        balloon.selectPopup(h.selection ?: -1)
        if (h.selection != null) feedback.tick(this)
    }

    /** Ngón khác chạm: chưa đủ giờ ⇒ chỉ là chạm (ký tự gốc chốt bởi flush); đã mở ⇒ chốt ô đang chọn NGAY. */
    private fun settlePopover() {
        val h = popHold ?: return
        val k = popKey
        if (h.fired && k != null) commits.release(k)
        dropPopover()
    }

    private fun dropPopover() {
        if (popHold == null) return
        removeCallbacks(popRun)
        if (popHold?.fired == true) balloon.hidePopup()
        popHold = null; popPid = -1; popKey = null
    }

    // MARK: menu giữ 😊 (EmojiKeyMenu) — cùng hàng ô DomainPopup, ô là icon, chạy lúc nhấc

    private var menuHold: DomainPopup.Hold? = null
    private var menuActions: List<EmojiKeyAction> = emptyList()
    private var menuX = 0f
    private var menuY = 0f
    private val emojiMenuRun = Runnable { openEmojiMenu() }

    private fun menuIcon(a: EmojiKeyAction): Int = when (a) {
        EmojiKeyAction.SWITCH_KEYBOARD -> ImeIcons.GLOBE
        EmojiKeyAction.VOICE -> ImeIcons.MIC
        // Đang một tay ⇒ mục là "thoát" (icon ↔ đầy bề ngang như rail).
        EmojiKeyAction.ONE_HAND -> if (oneHand != OneHandSide.OFF) ImeIcons.EXPAND else ImeIcons.ONE_HAND
        EmojiKeyAction.FLOATING -> if (floatingOn) ImeIcons.DOCK else ImeIcons.FLOAT
        EmojiKeyAction.SETTINGS -> ImeIcons.SETTINGS
    }

    /** Bàn phím đang thả nổi (IME đặt) — menu giữ 😊: 🪟 thành "gắn lại", ẩn ✋ một tay. */
    var floatingOn = false

    private fun openEmojiMenu() {
        val k = ptrKey.getOrNull(globePtr)?.takeIf { it.kind == KeyKind.EMOJI } ?: return
        if (!showEmojiMenu(k.centerX, k.top, k.bottom, below = false)) return
        globeFired = true                 // nhấc không mở plane emoji
    }

    /**
     * Mở menu giữ 😊 neo vào phím / nút có tâm ngang [anchorCx], mép [anchorTop]…[anchorBottom]
     * (px, toạ độ view này — âm = phía trên, tức nút 😊 trên strip). [below] ⇒ hàng ô nằm DƯỚI nút
     * (nút strip ở đỉnh cửa sổ, không có chỗ phía trên). Ngón hiện ở [menuX], [menuY].
     */
    private fun showEmojiMenu(anchorCx: Float, anchorTop: Float, anchorBottom: Float, below: Boolean): Boolean {
        val acts = EmojiKeyMenu.actions(voiceAvailable, oneHandAvailable = !theme.tablet && !floatingOn && !splitNow,
            floatingAvailable = true)
        val h = DomainPopup.Hold(acts.map { EmojiKeyMenu.label(it, oneHand != OneHandSide.OFF, floatingOn) })
        val n = acts.size
        val wDp = width / d
        val itemW = if (theme.tablet) 56f else 48f
        val l = DomainPopup.layout(anchorCx / d, itemW, n, wDp, maxRows = 1)   // ≤ 5 ô: một hàng
        val off = top / d
        val panelH = if (theme.tablet) 52f else 46f
        val popTop = if (below) maxOf(anchorBottom / d + off + 4f, 0f)
                     else maxOf((anchorTop / d + off) - 8f - panelH, 0f)
        val holdTop = if (below) anchorTop / d + off else popTop
        val holdBottom = if (below) popTop + panelH else anchorBottom / d + off
        if (!h.open(l, holdTop, holdBottom, menuX / d, menuY / d + off)) return false
        menuHold = h; menuActions = acts
        val inset = 4f
        balloon.showPopup((l.originX - inset) * d, popTop * d, (l.originX + l.width + inset) * d, (popTop + panelH) * d,
            FloatArray(n) { l.slotMinX(it) * d }, l.itemWidth * d, h.choices, 18f, h.selection ?: -1,
            icons = IntArray(n) { menuIcon(acts[it]) })
        feedback.longPress(this)
        return true
    }

    // --- nút 😊 trên strip ("Nút emoji" = Thanh trên): giữ = cùng menu, hàng ô dưới nút ---

    /** Giữ nút 😊 strip đủ lâu. Toạ độ px của view NÀY (y âm = trên vùng phím). true = menu mở. */
    fun stripEmojiHold(anchorCx: Float, anchorTop: Float, anchorBottom: Float, x: Float, y: Float): Boolean {
        dropEmojiMenu()
        menuX = x; menuY = y
        return showEmojiMenu(anchorCx, anchorTop, anchorBottom, below = true)
    }

    fun stripEmojiMove(x: Float, y: Float) = emojiMenuMove(x, y)

    /** Nhấc ([cancel] = false ⇒ chạy mục đang chọn) / huỷ. */
    fun stripEmojiRelease(cancel: Boolean) {
        val menu = menuHold ?: return
        val a = menu.selection?.let { menuActions.getOrNull(it) }
        dropEmojiMenu()
        if (a != null && !cancel) runMenuAction(a)
    }

    private fun emojiMenuMove(x: Float, y: Float) {
        val h = menuHold ?: return
        if (!h.move(x / d, y / d + top / d)) return
        balloon.selectPopup(h.selection ?: -1)
        if (h.selection != null) feedback.tick(this)
    }

    private fun dropEmojiMenu() {
        removeCallbacks(emojiMenuRun)
        if (menuHold == null) return
        balloon.hidePopup()
        menuHold = null; menuActions = emptyList()
    }

    private fun runMenuAction(a: EmojiKeyAction) {
        feedback.click(Feedback.MODIFIER, this)
        when (a) {
            EmojiKeyAction.SWITCH_KEYBOARD -> listener?.onGlobe(true)
            EmojiKeyAction.VOICE -> listener?.onVoiceInput()
            EmojiKeyAction.ONE_HAND -> listener?.onToggleOneHand()
            EmojiKeyAction.FLOATING -> listener?.onToggleFloating()
            EmojiKeyAction.SETTINGS -> listener?.onOpenSettings()
        }
    }

    /** Test/debug: menu giữ 😊 đang mở + mục chọn. */
    internal val emojiMenuState: Pair<Boolean, EmojiKeyAction?> get() =
        (menuHold != null) to menuHold?.selection?.let { menuActions.getOrNull(it) }

    /** Test/debug: popup đang hiện + ô chọn. */
    internal val popoverState: Pair<Boolean, String?> get() = balloon.popupVisible to popHold?.chosen

    // MARK: trackpad

    private fun beginTrackpad() {
        // Phím cách ĐANG giữ (tách đôi có hai phím cách) — disarm đúng phím đó.
        val k = spaceDownKey ?: spaceKey ?: return
        if (spacePtr < 0) return
        trackpad = true
        if (carouselOn) { flickAnim?.cancel(); carouselOn = false }
        trackpadBatch.clear()
        if (trackpadGesture.curve != trackpadSpeed.curve) trackpadGesture = TrackpadGesture(trackpadSpeed)
        trackpadGesture.begin(lastX[spacePtr] / d, lastY[spacePtr] / d, SystemClock.uptimeMillis())
        balloon.hide(); balloonOwner = null
        // Nhả ra KHÔNG có dấu cách (stock), kể cả khi chưa di con trỏ.
        commits.disarm(k)
        invalidate()
    }

    private var lastX = FloatArray(MAX_PTR)
    private var lastY = FloatArray(MAX_PTR)

    override fun dispatchTouchEvent(e: MotionEvent): Boolean {
        for (i in 0 until e.pointerCount) {
            val id = e.getPointerId(i)
            if (id in 0 until MAX_PTR) { lastX[id] = e.getX(i); lastY[id] = e.getY(i) }
        }
        return super.dispatchTouchEvent(e)
    }

    private fun sendTrackpadStep(s: TrackpadGesture.Step) {
        if (plane == Plane.EMOJI_SEARCH) return
        // Giữ ⇧ lúc kéo (chỉ khi bật "Vuốt phím để sao chép/dán") ⇒ chọn chữ; chốt tới khi nhả trackpad.
        if (keyCommands && shiftPtr >= 0) { trackpadSelect = true; shiftHold.markSelect() }
        if (trackpadSelect) listener?.onTrackpadSelect(s.count, s.axis == TrackpadGesture.Axis.V)
        else listener?.onTrackpadMove(s.count, s.axis == TrackpadGesture.Axis.V)
    }

    /** Ngón thứ hai lúc trackpad: phần dời đã gom gửi như dời con trỏ, từ đây kéo = mở rộng vùng
     *  chọn từ vị trí con trỏ (neo) tới khi nhả trackpad. */
    private fun beginTrackpadSelect() {
        if (trackpadSelect || plane == Plane.EMOJI_SEARCH) return
        trackpadBatch.drain()?.let { sendTrackpadStep(it) }
        trackpadSelect = true
        feedback.tick(this)
    }

    /** Test: trackpad đang ở chế độ chọn chữ. */
    internal val trackpadSelecting: Boolean get() = trackpadSelect

    private fun endTrackpad() {
        trackpad = false
        if (trackpadFramePosted) { Choreographer.getInstance().removeFrameCallback(trackpadFrame); trackpadFramePosted = false }
        trackpadBatch.drain()?.let { sendTrackpadStep(it) }
        trackpadSelect = false
        listener?.onTrackpadEnd()
        invalidate()
    }

    // MARK: balloon

    private fun showBalloon(k: LaidKey, text: String) {
        balloonOwner = k
        balloon.show(k.left, k.top + top, k.right, k.bottom + top, text,
            skins?.get(ThemeKeyRole.index(k.kind, k.label, k.side)))
    }

    private fun hideBalloon(k: LaidKey) {
        if (balloonOwner === k) { balloon.hide(); balloonOwner = null }
    }

    // MARK: pane callbacks

    internal fun paneEmoji(e: String) {
        listener?.noteEmojiUsed(e)
        listener?.onKey(Key.Text(e))
    }
    internal fun paneBackspace() = listener?.onKey(Key.Backspace)
    internal fun paneABC() = setPlane(Plane.LETTERS)
    internal fun paneSearch() = setPlane(Plane.EMOJI_SEARCH)
    internal fun paneKaomoji(s: String) = listener?.onKey(Key.Text(s))
    internal fun paneTemplate(item: TemplateItem) {
        setPlane(Plane.LETTERS)
        listener?.onTemplate(item)
    }
    internal fun paneGear() = listener?.onOpenTemplates()
    internal fun paneExtra(id: String) {
        when (id) {
            TOOLS_ENTRY, TOOLS_BACK -> {
                if (textToolsMode == (id == TOOLS_ENTRY)) return
                textToolsMode = id == TOOLS_ENTRY
                templatesPane.resetScroll()
                refreshTemplatesPane()
            }
            TemplatesMenu.QUICK_CLIPBOARD -> listener?.onToggleClipboard()
            TemplatesMenu.QUICK_VOICE -> {
                setPlane(Plane.LETTERS)
                listener?.onVoiceInput()
            }
            TOOLS_TRANSLATE -> {
                setPlane(Plane.LETTERS)
                listener?.onTranslate()
            }
            TemplatesMenu.TOOLS_ADD_TONES -> {
                setPlane(Plane.LETTERS)
                listener?.onAddTones()
            }
            else -> {
                val tool = TextTool.byId(id) ?: return
                setPlane(Plane.LETTERS)
                listener?.onTextTool(tool)
            }
        }
    }

    override fun computeScroll() {
        if (plane == Plane.EMOJI) emojiPane.computeScroll()
        else if (plane == Plane.TEMPLATES) templatesPane.computeScroll()
    }

    companion object {
        /** Phím Enter (Sút!: sút bóng từ phím này) — iOS KeyboardView.isReturnKey. */
        fun isReturnKey(k: Key): Boolean = k == Key.Newline || k == Key.LineBreak
        private const val MAX_PTR = 32
        /** Số chữ ký bố cục giữ trong [layoutCache]. */
        private const val LAYOUT_SIGS = 4
        /** Cỡ nhãn phím chuẩn (sp, "Cỡ chữ trên phím" = Vừa) — Lớn nhân [KeyLabelSize]. */
        const val LETTER_SP = 22f
        const val CONTROL_SP = 14f
        const val DIGIT_SP = 24f
        const val SIDE_SP = 20f
        const val HINT_SP = 10f
        const val DOUBLE_SPACE_MS = 350L
        const val SPACE_HOLD_MS = 300L
        const val BS_HOLD_MS = 500L
        const val BS_INTERVAL = 90L
        const val GLOBE_HOLD_MS = 500L
        const val RETURN_HOLD_MS = 450L
        private const val TOOLS_ENTRY = TemplatesMenu.TOOLS_ENTRY
        private const val TOOLS_BACK = TemplatesMenu.TOOLS_BACK
        private const val TOOLS_TRANSLATE = TemplatesMenu.TOOLS_TRANSLATE
        const val EDIT_HOLD_MS = 400L
        const val EDIT_REPEAT_MS = 70L
    }
}
