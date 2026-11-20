package com.viettelex.keyboard

import com.viettelex.telexcore.RetroCorrection
import com.viettelex.telexcore.TelexAction
import com.viettelex.telexcore.TelexEngine

/**
 * Keo giữa TelexEngine và [TextProxy] — port 1:1 iOS EngineBridge. Mỗi phím →
 * diff tối thiểu (xoá N code point + chèn). Không Android API.
 */
class EngineBridge(settings: KeyboardSettings = KeyboardSettings()) {
    private var settings = settings
    private val engine = TelexEngine().also { configure(it, true) }

    /** Ô không autocorrect (mã/username): gõ LITERAL, bỏ engine. */
    var passthrough = false

    /**
     * Ô email (FieldTraits.emailCompose): Telex/VNI BẬT để tìm người nhận theo tên ("Sown" →
     * "Sơn"), nhưng token có "@"/"." được trả về đúng phím thô và gõ thô tới hết token
     * ([EmailTokenGuard]). Không gõ tắt / không với lại từ đã chốt (không viết lại chữ app chèn).
     */
    var emailField = false
        set(v) { field = v; email.invalidate() }
    private val email = EmailTokenGuard()
    private val emailActive: Boolean get() = emailField && !englishMode
    /** Với lại từ đã chốt (⌫ mở lại, phím dấu nạp lại từ trước con trỏ): không ở ô email. */
    private val reEdit: Boolean get() = settings.reEditWords && !emailField

    /** Cho phép gõ tắt ở ô này (session TẮT ở ô URL/omnibox). Mật khẩu/email đã passthrough. */
    var shortcutsAllowed = true

    /** Lần bung gõ tắt gần nhất — ⌫ NGAY SAU đó trả lại đúng chữ đã gõ (một lần). */
    /** [retro] = sửa ngược tiếng Anh vừa TỰ ÁP: typed = chữ cũ (kể cả ranh giới), expansion = chữ mới, boundary rỗng. */
    private class ExpansionUndo(val typed: String, val expansion: String, val boundary: String, val autoCorrect: Boolean = false,
                                val retro: Boolean = false)
    /** Mọi thao tác đổi hoàn tác này (phím kế, reset…) cũng bỏ lời mời sửa ngược. */
    private var expansionUndo: ExpansionUndo? = null
        set(v) { field = v; retroOffer = null }

    // MARK: sửa ngược tiếng Anh (RetroCorrection) — docs/DESIGN.md "Sửa ngược tiếng Anh"
    /** Phép sửa engine vừa đề xuất, công tắc "Tự sửa từ phía trước" TẮT ⇒ session hiện chip tới phím kế. */
    var retroOffer: RetroCorrection? = null
        private set
    /** Phép sửa vừa TỰ ÁP còn hoàn tác được (chip "Khôi phục" / ⌫ ngay sau). */
    val retroUndoAvailable: Boolean get() = expansionUndo?.retro == true
    /** ⌫ / chip vừa trả lại chữ trước lần tự sửa ngược (một lần — session đọc rồi xoá). */
    var revertedRetro = false
    /** boundary() vừa rồi đã bung gõ tắt / tự sửa (session: không mời hoàn tác khôi phục, học nội dung). */
    var expandedAtLastBoundary = false
        private set

    /**
     * Tự sửa từ gõ sai ([AutoCorrect]): phím thô của từ vừa gõ → từ sửa hoặc null. Session chỉ
     * gắn khi công tắc BẬT và ô cho phép; null ⇒ boundary không tốn thêm gì.
     */
    var autoCorrector: ((String) -> String?)? = null
    /** ⌫ / chip vừa trả lại chữ gốc của một lần tự sửa: chữ gốc (một lần — session đọc rồi xoá). */
    var revertedAutoCorrect: String? = null
    /** Lần tự sửa còn hoàn tác được (chữ gốc, từ đã sửa) — chip "↩︎ chữ gốc" trên thanh gợi ý. */
    val autoCorrectUndo: Pair<String, String>? get() = expansionUndo?.takeIf { it.autoCorrect }?.let { it.typed to it.expansion }

    /**
     * Ký tự ngay trước con trỏ là ranh giới CHÍNH MÌNH vừa chèn ⇒ không có từ nào để nạp
     * lại, khỏi đọc context (IPC) ở chữ đầu mỗi từ.
     */
    private var afterOwnBoundary = false

    /**
     * Ghi checkpoint mỗi phím chữ để [undoLastLetter] huỷ được đúng phím đó khi nó hoá ra
     * là đầu một đường VUỐT (gõ vuốt). Tắt (mặc định) ⇒ không tốn gì.
     */
    var trackLetterUndo = false
        set(v) { field = v; if (!v) undo.valid = false }

    /**
     * Checkpoint của phím CHỮ gần nhất (port iOS `LetterUndo`). KHÔNG dùng ⌫ để huỷ:
     * engine.backspace() xoá chữ cuối ĐANG HIỆN chứ không gỡ phím vừa gõ — "tieng" + s
     * rồi ⌫ ra "tiến". Mọi thao tác khác ngoài letter() đều xoá checkpoint.
     * Engine snapshot cấp MỘT lần, copyInto mỗi phím (không cấp phát trên hot path).
     */
    private class LetterUndo {
        val engine = TelexEngine()
        var removed = ""      // chữ phím đó đã xoá khỏi màn hình
        var inserted = ""     // chữ phím đó đã chèn
        var ownBoundary = false
        var valid = false
        var enWord = ""
    }
    private val undo = LetterUndo()

    /**
     * Chế độ Tiếng Anh (vuốt phím cách): phím chữ chèn NGUYÊN VĂN (không Telex/VNI), từ đang gõ
     * nằm ở [enWord] — gợi ý tiếng Anh, gõ tắt vẫn bung. Đổi giữa chừng qua [setEnglish]. Giống iOS.
     */
    var englishMode = false
        private set
    private var enWord = ""

    /**
     * Đổi Tiếng Việt ↔ Tiếng Anh: chốt từ đang gõ như ranh giới rỗng (auto-restore, không gõ
     * tắt, không chèn ký tự nào) rồi đổi chế độ. Trả từ đã chốt (caller học).
     */
    fun setEnglish(on: Boolean, proxy: TextProxy): String {
        if (on == englishMode) return ""
        val final = if (isComposing) boundary("", proxy, expand = false) else ""
        englishMode = on
        engine.reset(); engine.forgetLastCommit()
        // phím kế là đầu từ MỚI của ngôn ngữ kia — không nạp lại / nối vào từ vừa chốt
        enWord = ""; undo.valid = false; afterOwnBoundary = true
        email.invalidate()
        return final
    }

    /**
     * Vuốt phím cách khi đang gõ dở một từ (ONBOARDING-SPEC §7): đổi chế độ VÀ chuyển luôn từ
     * đang soạn sang ngôn ngữ đích, từ vẫn mở. Sang EN ⇒ thay bằng đúng phím gốc đã gõ ("Hí" →
     * "His", "vẻy" → "very"); sang VI ⇒ chạy lại phím gốc qua Telex/VNI ("His" → "Hí") — kể cả
     * khi engine đã đóng băng tiếng Anh giữa từ. Khứ hồi trả đúng như cũ. Chỉ xoá/chèn đúng từ
     * đó (confirmTail); không có từ đang soạn / ô email / chữ lệch / phím ngoài engine ⇒ false,
     * KHÔNG đổi gì (caller dùng [setEnglish] như cũ).
     */
    fun convertComposing(toEnglish: Boolean, proxy: TextProxy): Boolean {
        if (toEnglish == englishMode || !isComposing || proxy.isSecure || passthrough || emailField) return false
        val shown = typedWord
        if (!proxy.confirmTail(shown)) return false
        val target: String
        if (toEnglish) {
            target = engine.rawKeystrokes
            if (target.isEmpty()) return false
            engine.reset(); engine.forgetLastCommit()
            enWord = target
        } else {
            val raw = enWord
            for (ch in raw) engine.feed(ch)
            if (engine.rawKeystrokes != raw) { engine.reset(); return false }   // phím engine không nhận / tràn
            target = engine.composed
            enWord = ""
        }
        englishMode = toEnglish
        undo.valid = false; expansionUndo = null; afterOwnBoundary = false
        email.invalidate()
        if (target != shown) {
            proxy.deleteCodePoints(Cp.count(shown))
            proxy.insertText(target)
        }
        TouchLog.write("lang flick: convert word → ${if (toEnglish) "en" else "vi"}")
        return true
    }

    private fun checkpoint(ownBoundary: Boolean) {
        if (!trackLetterUndo) return
        engine.copyInto(undo.engine)
        undo.enWord = enWord
        undo.ownBoundary = ownBoundary
    }

    private fun recordUndo(action: TelexAction, before: String, literal: String) {
        if (!trackLetterUndo) return
        when (action) {
            is TelexAction.Replace -> {
                undo.removed = before.substring(Cp.dropLast(before, action.backspaces).length)
                undo.inserted = action.insert
            }
            TelexAction.Passthrough -> { undo.removed = ""; undo.inserted = literal }
            TelexAction.None -> { undo.removed = ""; undo.inserted = "" }
        }
        undo.valid = true
    }

    /**
     * Huỷ phím chữ vừa gõ (chỉ khi chưa có thao tác nào khác xen vào): trả màn hình và
     * engine về đúng trước phím đó. Chữ trước con trỏ không kết thúc bằng thứ phím đó
     * đã chèn ⇒ không sửa gì, trả false (caller tự xử lý).
     */
    fun undoLastLetter(proxy: TextProxy): Boolean {
        expansionUndo = null
        if (!undo.valid) return false
        undo.valid = false
        if (!proxy.confirmTail(undo.inserted)) return false
        val n = Cp.count(undo.inserted)
        if (n > 0) proxy.deleteCodePoints(n)
        if (undo.removed.isNotEmpty()) proxy.insertText(undo.removed)
        undo.engine.copyInto(engine)
        enWord = undo.enWord
        afterOwnBoundary = undo.ownBoundary
        TouchLog.write("undo letter: -$n +${Cp.count(undo.removed)}")
        return true
    }

    /**
     * Từ vừa chèn nguyên khối (gõ vuốt) thành composition đang mở: phím dấu Telex sửa được,
     * ⌫ engine như từ gõ tay. false = từ không round-trip qua engine (engine để trống).
     */
    fun adoptWord(word: String): Boolean {
        undo.valid = false
        expansionUndo = null
        afterOwnBoundary = false
        enWord = ""
        val ok = engine.seed(word)
        if (!ok) engine.reset()
        return ok
    }

    /**
     * Từ vừa chèn NGUYÊN VĂN (vuốt ra từ tiếng Anh): engine không giữ gì (phím dấu Telex
     * không đụng vào từ), ⌫ không mở lại từ chốt trước đó.
     */
    fun adoptLiteral() {
        undo.valid = false
        expansionUndo = null
        afterOwnBoundary = false
        enWord = ""
        engine.reset()
        engine.forgetLastCommit()
    }

    /**
     * Từ nguyên văn vừa được chốt: ngữ cảnh tiếng Anh của engine. Biết chữ thì từ chức năng
     * ("it" rồi gõ "is" giữ "is") mở mạch; từ nội dung ("check") chỉ mở khi là từ Anh thứ hai.
     */
    fun noteExternalWord(english: Boolean, word: String? = null) = engine.noteExternalWord(word, english)

    private fun configure(e: TelexEngine, contextual: Boolean) {
        e.freeMarking = settings.freeMarking
        e.simpleTelex = settings.simpleTelex
        e.liveSpellCheck = settings.liveSpellCheck
        // "goog" thay vì "gôg" giữa từ — chỉ khi tự khôi phục bật (boundary giữ nguyên).
        e.eagerEnglishRestore = settings.autoRestore
        e.quickTelex = settings.quickTelex
        e.modernTone = settings.modernTone
        e.teencode = settings.teencode
        e.vniMode = settings.vniMode
        e.autoCircumflex = settings.autoCircumflex
        if (contextual) {
            e.contextualEnglish = settings.contextualEnglish
            // Cả hai chế độ (mời / tự áp) cần quyết định của engine; contextualEnglish tắt ⇒ không gì cả.
            e.retroactiveEnglish = settings.contextualEnglish
            // Tắt ⇒ engine chỉ thử một Boolean ở mỗi lần chốt từ.
            e.englishByFrequency = settings.englishByFrequency
        }
    }

    /**
     * Settings đổi khi bàn phím ĐANG hiện (Android: app settings cùng màn hình với ô Thử gõ,
     * không có onStartInputView mới) — áp ngay vào engine, không reset chữ đang gõ.
     */
    fun applySettings(s: KeyboardSettings) { settings = s; configure(engine, true) }

    /** Phím chữ (đã theo shift). */
    fun letter(ch: Char, proxy: TextProxy) {
        undo.valid = false
        expansionUndo = null
        if (proxy.isSecure || passthrough) {
            checkpoint(afterOwnBoundary)
            proxy.insertText(ch.toString())
            recordUndo(TelexAction.Passthrough, "", ch.toString())
            return
        }
        if (emailActive) {
            if (!email.synced) email.sync(proxy.contextBeforeInput())
            if (email.literal) {                     // token địa chỉ: phím thô, ⌫ thường
                proxy.insertText(ch.toString())
                email.appended(ch.toString(), ch.toString())
                afterOwnBoundary = false
                return
            }
        }
        if (englishMode) {
            checkpoint(afterOwnBoundary)
            afterOwnBoundary = false
            enWord += ch
            proxy.insertText(ch.toString())
            recordUndo(TelexAction.Passthrough, "", ch.toString())
            return
        }
        val ownBoundary = afterOwnBoundary
        val seedable = reEdit && engine.isEmpty && !afterOwnBoundary &&
            (ReEdit.isTransformKey(ch, settings.vniMode) || strokeSeedable(ch, proxy))
        afterOwnBoundary = false
        checkpoint(ownBoundary)
        if (seedable && trySeed(ch, proxy)) return
        val before = engine.composed
        val action = engine.feed(ch)
        if (action is TelexAction.Replace && action.backspaces > 0 && !proxy.confirmTail(before)) {
            // Chữ trên màn hình không còn là từ engine đang giữ (ô bị đổi mà không được báo):
            // KHÔNG xoá mù — quên từ, bắt đầu từ mới bằng chính phím này.
            TouchLog.write("tail mismatch (letter) → reset")
            reset()
            val fresh = engine.feed(ch)
            if (fresh is TelexAction.Replace && fresh.backspaces > 0) { reset(); proxy.insertText(ch.toString()) }
            else apply(fresh, ch.toString(), proxy)
            return
        }
        apply(action, ch.toString(), proxy)
        recordUndo(action, before, ch.toString())
    }

    /** Kiểu gõ đang là VNI. */
    val vniMode: Boolean get() = settings.vniMode

    /**
     * Phím SỐ ở kiểu gõ VNI (hàng số, plane 123, bàn phím cứng). true = đã xử lý như phím của
     * từ: đang soạn ⇒ feed engine (áp dấu khi áp được, không thì số nằm trong từ — "mp3", như
     * macOS); engine trống ⇒ chỉ thử sửa dấu từ ngay trước con trỏ (1–5/0/7/8). false = ngoài
     * từ ⇒ caller chèn số như ký hiệu (boundary) — "2026" vẫn là số. Telex ⇒ luôn false.
     */
    fun vniDigit(ch: Char, proxy: TextProxy): Boolean {
        if (!settings.vniMode || englishMode || ch !in '0'..'9' || proxy.isSecure || passthrough) return false
        if (emailActive && email.literal) return false  // token địa chỉ: số là số
        if (!engine.isEmpty) { letter(ch, proxy); return true }
        if (!reEdit || afterOwnBoundary || !ReEdit.isTransformKey(ch, true)) return false
        undo.valid = false
        checkpoint(false)
        return trySeed(ch, proxy)
    }

    /**
     * Space / return / dấu câu: boundary → auto-restore rồi chèn [text]. Trả từ ĐÃ
     * CHỐT (sau auto-restore) để model học đúng thứ nằm trên màn hình.
     */
    fun boundary(text: String, proxy: TextProxy, lineBreak: Boolean = false, expand: Boolean = true): String {
        // [lineBreak]: [text] là "\n" chèn thật ([TextProxy.insertLineBreak]), không gửi action.
        // [expand] = false: không gõ tắt (từ vuốt — từ từ điển, không phải chữ tắt).
        fun put(text: String) = if (lineBreak) proxy.insertLineBreak() else proxy.insertText(text)
        undo.valid = false
        expansionUndo = null
        expandedAtLastBoundary = false
        if (proxy.isSecure || passthrough) { put(text); return "" }
        afterOwnBoundary = text.isNotEmpty() && !Character.isLetterOrDigit(text.codePointBefore(text.length))
        if (emailActive) return emailBoundary(text, proxy, ::put)
        // Gõ tắt TRƯỚC tự khôi phục tiếng Anh.
        if (expand) tryExpandShortcut(text, proxy, ::put)?.let { return it }
        if (englishMode) {
            val word = enWord
            enWord = ""
            put(text)
            return word
        }
        if (expand) autoCorrector?.let { ac -> tryAutoCorrect(ac, text, proxy, ::put)?.let { return it } }
        val before = engine.composed
        // Ký tự kết thúc từ: dấu nháy giữ gốc từ viết tắt tiếng Anh ("doesn't").
        val action = engine.commitBoundary(settings.autoRestore, text.firstOrNull() ?: '\u0000')
        if (action is TelexAction.Replace && action.backspaces > 0 && !proxy.confirmTail(before)) {
            // Auto-restore cần xoá nhưng chữ trước con trỏ không khớp: bỏ restore, không học.
            TouchLog.write("tail mismatch (boundary) → reset")
            reset()
            put(text)
            return ""
        }
        var final = before
        if (action is TelexAction.Replace) final = Cp.dropLast(before, action.backspaces) + action.insert
        apply(action, "", proxy)
        // Lật lại (englishByFrequency): sửa đoán của chính engine ("His hửng" → "hí hửng") ⇒ tự áp
        // TRƯỚC khi ký tự ranh giới vào — kể cả Enter (chưa gửi) và khi sửa ngược chỉ mời.
        engine.pendingRetroCorrection?.let { if (it.flipBack) applyFlipBack(it, proxy) }
        put(text)
        // Engine cần MỌI ký tự ranh giới (dính "my_var" / "100W"), có sửa ngược hay không.
        // (⌫ sau khôi phục phím thô: session mời chữ Việt trên thanh gợi ý — restoreUndoRaw.)
        if (engine.retroactiveEnglish) retroAfterBoundary(text, proxy)
        else for (ch in text) engine.noteBoundaryCharacter(ch)
        return final
    }

    /**
     * Bước 2–3 của luồng tích hợp sửa ngược: báo MỌI ký tự ranh giới vừa chèn, rồi mời (công tắc
     * tắt) hoặc tự áp (bật) — chỉ khi chữ trước con trỏ đúng `expected`. Enter không sửa (có thể
     * đã gửi tin / performEditorAction).
     */
    private fun retroAfterBoundary(text: String, proxy: TextProxy) {
        for (ch in text) engine.noteBoundaryCharacter(ch)
        val c = engine.pendingRetroCorrection ?: return
        // Lật lại đã thử trước khi chèn ranh giới (applyFlipBack); lệch thì bỏ, không mời.
        if (c.flipBack || text.contains('\n') || proxy.hasSelection) return
        if (!settings.retroEnglishAuto) { retroOffer = c; return }
        if (!retroMatches(c.expected, proxy.contextBeforeInput())) {
            TouchLog.write("retro: screen disagrees → không sửa")
            return
        }
        engine.takeRetroCorrection()
        if (TouchLog.enabled) TouchLog.edit(c.backspaces, Cp.count(c.insert), c.insert)
        proxy.deleteCodePoints(c.backspaces)
        proxy.insertText(c.insert)
        expansionUndo = ExpansionUndo(c.expected, c.insert, "", retro = true)
    }

    /**
     * Áp phép LẬT LẠI ngay sau khi chốt từ (chưa chèn ranh giới): cùng kiểm chữ trước con trỏ như
     * sửa ngược; lệch / có vùng chọn ⇒ bỏ (phép sửa hết hạn ở lệnh engine kế tiếp). Không chip
     * "Khôi phục": phép này chỉ trả lại đúng chữ Việt người dùng gõ.
     */
    private fun applyFlipBack(c: RetroCorrection, proxy: TextProxy) {
        if (proxy.hasSelection || !retroMatches(c.expected, proxy.contextBeforeInput())) {
            TouchLog.write("flip-back: screen disagrees → không sửa")
            return
        }
        engine.takeRetroCorrection()
        if (TouchLog.enabled) TouchLog.edit(c.backspaces, Cp.count(c.insert), c.insert)
        proxy.deleteCodePoints(c.backspaces)
        proxy.insertText(c.insert)
    }

    /** Chạm chip sửa ngược (công tắc tắt): áp phép sửa đang mời. false = hết mời / chữ đã khác ⇒ không sửa. */
    fun applyRetroOffer(proxy: TextProxy): Boolean {
        val c = retroOffer ?: return false
        retroOffer = null
        if (proxy.isSecure || passthrough || proxy.hasSelection || !retroMatches(c.expected, proxy.contextBeforeInput())) {
            TouchLog.write("retro offer: screen disagrees → không sửa")
            return false
        }
        // Còn trong engine ⇒ lấy để lịch sử ghi các từ là tiếng Anh; không thì quên lịch sử.
        if (engine.pendingRetroCorrection == c) engine.takeRetroCorrection() else engine.resetContext()
        if (TouchLog.enabled) TouchLog.edit(c.backspaces, Cp.count(c.insert), c.insert)
        proxy.deleteCodePoints(c.backspaces)
        proxy.insertText(c.insert)
        return true
    }

    /** Chip "Khôi phục" (công tắc bật): trả lại đúng chữ trước lần tự sửa ngược (như ⌫ ngay sau). */
    fun revertRetro(proxy: TextProxy): Boolean {
        val u = expansionUndo?.takeIf { it.retro } ?: return false
        expansionUndo = null
        return undoExpansion(u, proxy)
    }

    /** `d` dính liền sau từ bắt đầu bằng d (xem [ReEdit.isStrokeKey]); chỉ đọc context khi phím là d. */
    private fun strokeSeedable(ch: Char, proxy: TextProxy): Boolean {
        if (settings.vniMode || (ch != 'd' && ch != 'D')) return false
        val word = proxy.contextBeforeInput()?.let { ReEdit.trailingWord(it) } ?: return false
        return ReEdit.isStrokeKey(ch, word)
    }

    /**
     * Phím dấu/mũ khi engine rỗng, con trỏ ở CUỐI một từ đã có trên màn hình ("viet|" + j):
     * seed engine bằng từ đó rồi feed phím ⇒ "việt". Chỉ nhận khi seed khớp đúng từ VÀ phím
     * thật sự biến đổi nó; mọi trường hợp khác trả false (caller gõ literal như cũ).
     */
    private fun trySeed(ch: Char, proxy: TextProxy): Boolean {
        if (!proxy.canReEdit) return false
        val before = proxy.contextBeforeInput() ?: return false
        val word = ReEdit.trailingWord(before) ?: return false
        val after = proxy.contextAfterInput() ?: return false
        if (!ReEdit.atWordEnd(after) || proxy.hasSelection) return false
        if (!engine.seed(word)) return false
        val action = engine.feed(ch)
        if (action !is TelexAction.Replace || action.backspaces <= 0 ||
            engine.composed == word + ch) {
            engine.reset()
            return false
        }
        TouchLog.write("re-edit: seeded ${Cp.count(word)} chars")
        apply(action, ch.toString(), proxy)
        // Checkpoint = engine TRỐNG trước seed; màn hình: đuôi từ bị thay ↔ phần chèn.
        recordUndo(action, word, ch.toString())
        return true
    }

    /**
     * ⌫. Trả true khi vừa MỞ LẠI từ chốt trước: ⌫ xoá ký tự ranh giới như thường và
     * engine giữ lại đúng từ đó ("tháy" ␣ ⌫ a → "thấy"). Chỉ khi chữ trước con trỏ khớp
     * đúng từ + ranh giới; lệch ⇒ quên từ, ⌫ thường.
     */
    fun backspace(proxy: TextProxy): Boolean {
        undo.valid = false
        retroOffer = null
        expansionUndo?.let { u ->
            expansionUndo = null
            if (undoExpansion(u, proxy)) return false
        }
        if (proxy.isSecure || passthrough) { proxy.deleteBackward(); return false }
        afterOwnBoundary = false
        if (englishMode) {
            if (enWord.isNotEmpty()) enWord = enWord.dropLast(1)
            proxy.deleteBackward()
            return false
        }
        if (engine.isEmpty) {
            if (emailActive) email.deletedOne()
            val reopened = reEdit && engine.canReopenLastCommit && tryReopen(proxy)
            if (!reopened) { engine.forgetLastCommit(); proxy.deleteBackward() }
            return reopened
        }
        val before = engine.composed
        when (val a = engine.backspace()) {
            is TelexAction.Replace -> {
                if (a.backspaces > 0 && !proxy.confirmTail(before)) {
                    // Từ đang soạn không còn trên màn hình: ⌫ thường, quên từ.
                    TouchLog.write("tail mismatch (backspace) → reset")
                    reset()
                    proxy.deleteBackward()
                    return false
                }
                if (a.backspaces > 0) proxy.deleteCodePoints(a.backspaces)
                if (a.insert.isNotEmpty()) proxy.insertText(a.insert)
            }
            else -> proxy.deleteBackward()
        }
        return false
    }

    private fun tryReopen(proxy: TextProxy): Boolean {
        // canReopen (không canReEdit): ô URI/omnibox cũng mở lại được (#148 "go␣⌫s" → "gó").
        if (!proxy.canReopen || proxy.hasSelection) return false
        val before = proxy.contextBeforeInput() ?: return false
        val word = engine.reopenLastCommit() ?: return false
        if (!ReEdit.endsWithWordThenBoundary(before, word)) {
            // App nuốt ranh giới / tự sửa chữ / con trỏ lệch: không sửa màn hình.
            TouchLog.write("re-open: screen disagrees → reset")
            engine.reset()
            return false
        }
        proxy.deleteBackward()          // xoá ký tự ranh giới
        TouchLog.write("re-open: ${Cp.count(word)} chars back")
        return true
    }

    /** Bỏ snapshot mở lại (Enter có thể đã gửi tin / xuống dòng mà ⌫ không đảo được). */
    fun forgetLastCommit() { engine.forgetLastCommit(); expansionUndo = null }

    /** Đổi ô / con trỏ dời / ẩn bàn phím → quên từ + ngữ cảnh tiếng Anh. */
    fun reset() {
        engine.reset(); engine.resetContext(); afterOwnBoundary = false; undo.valid = false; expansionUndo = null; enWord = ""
        email.invalidate()
    }

    // MARK: ô email ([EmailTokenGuard]) — port iOS EngineBridge.emailBoundary

    /**
     * Ranh giới ở ô email. Token chưa là địa chỉ + phím không phải "@"/"." ⇒ chốt như thường
     * (auto-restore). Phím "@"/"." ⇒ phần token mình gõ + từ đang soạn trả về ĐÚNG phím thô
     * (fail-safe confirmTail: chỉ khi chữ trước con trỏ đúng là nó; không thì chỉ từ đang soạn;
     * không nữa thì không sửa gì), chèn ranh giới, gõ thô tới hết token. Không gõ tắt / tự sửa.
     */
    private fun emailBoundary(text: String, proxy: TextProxy, put: (String) -> Unit): String {
        if (!email.synced) email.sync(proxy.contextBeforeInput())
        if (!email.needsRestore(text)) {
            val before = engine.composed
            val raw = engine.rawKeystrokes
            val action = engine.commitBoundary(settings.autoRestore)
            if (action is TelexAction.Replace && action.backspaces > 0 && !proxy.confirmTail(before)) {
                TouchLog.write("tail mismatch (email boundary) → reset")
                reset()
                put(text)
                return ""
            }
            var final = before
            if (action is TelexAction.Replace) final = Cp.dropLast(before, action.backspaces) + action.insert
            apply(action, "", proxy)
            put(text)
            email.appended(final, raw, text)
            return final
        }
        val composed = engine.composed
        val composedRaw = engine.rawKeystrokes
        engine.reset()
        engine.forgetLastCommit()
        val plan = email.restorePlan(composed, composedRaw)
        when {
            plan == null -> { put(text); email.appended(composed, composedRaw, text) }
            proxy.confirmTail(plan.first) -> {
                TouchLog.write("email: restore raw -${Cp.count(plan.first)} +${Cp.count(plan.second)}")
                proxy.deleteCodePoints(Cp.count(plan.first))
                proxy.insertText(plan.second)
                put(text)
                email.restored(plan.second, text)
            }
            composed != composedRaw && proxy.confirmTail(composed) -> {
                TouchLog.write("email: restore word only -${Cp.count(composed)} +${Cp.count(composedRaw)}")
                proxy.deleteCodePoints(Cp.count(composed))
                proxy.insertText(composedRaw)
                put(text)
                email.appended(composedRaw, composedRaw, text)
            }
            else -> {
                TouchLog.write("email: screen disagrees → no rewrite")
                put(text)
                email.appended(composed, composedRaw, text)
            }
        }
        return ""
    }

    // MARK: gõ tắt (port iOS EngineBridge.tryExpandShortcut)

    /**
     * Bung gõ tắt ở ranh giới [text] nếu khớp ([ShortcutTable]): xoá chữ đã gõ (chỉ khi chữ
     * trước con trỏ đúng là nó — confirmTail, không xoá mù), chèn nội dung rồi ranh giới qua
     * [put]. Trả nội dung đã bung, null = không bung.
     */
    private fun tryExpandShortcut(text: String, proxy: TextProxy, put: (String) -> Unit): String? {
        val table = settings.shortcuts
        if (!settings.shortcutsEnabled || !shortcutsAllowed || table.isEmpty) return null
        if (!typedEmpty && ShortcutTable.triggersWord(text)) {
            val composed = typedWord
            val e = table.wordExpansion(composed, typedRaw)
            if (e != null) {
                val ctx = proxy.contextBeforeInput()
                val glued = ShortcutTable.isGlued(composed, ctx)
                if (!glued && proxy.confirmTail(composed)) return applyExpansion(composed, e, text, proxy, put)
                // Dính trước ("2fa": "fa" sau số) — cả cụm có thể là khoá chữ+số (#109).
                if (!glued) return null
            }
        }
        // Khoá ký hiệu/số: khoảng trắng/Enter. Khoá chữ+số (#109): cả dấu câu, như khoá chữ.
        val tokenTrigger = ShortcutTable.triggersToken(text)
        if (table.hasTokenKeys && (tokenTrigger || ShortcutTable.triggersAlnum(text)) && !proxy.hasSelection) {
            val ctx = proxy.contextBeforeInput() ?: return null
            val (token, e) = table.tokenExpansion(ctx) ?: return null
            if (!tokenTrigger && !ShortcutTable.isAlnumKey(token)) return null
            if (!typedEmpty && !token.endsWith(typedWord)) return null
            return applyExpansion(token, e, text, proxy, put)
        }
        return null
    }

    private fun applyExpansion(typed: String, expansion: String, text: String, proxy: TextProxy,
                               put: (String) -> Unit): String {
        engine.reset()
        enWord = ""
        engine.forgetLastCommit()                 // ⌫ không mở lại chữ tắt qua engine
        engine.noteExternalWord(false)
        val n = Cp.count(typed)
        if (TouchLog.enabled) TouchLog.edit(n, Cp.count(expansion), expansion)
        proxy.deleteCodePoints(n)
        proxy.insertText(expansion)
        put(text)
        expandedAtLastBoundary = true
        // Enter có thể đã gửi tin — không hứa hoàn tác qua nó.
        if (!text.contains('\n')) expansionUndo = ExpansionUndo(typed, expansion, text)
        return expansion
    }

    /**
     * Tự sửa ở ranh giới [text]: chỉ khi ô đọc/sửa được, chữ trước con trỏ đúng là từ đang soạn
     * (không dính URL/email/số — [ShortcutTable.isGlued]), chữ hoa hợp lệ ([AutoCorrect.caseAllows]).
     * Thay từ + ranh giới; ⌫ ngay sau trả lại đúng chữ boundary lẽ ra đã chốt (như hoàn tác gõ tắt).
     */
    private fun tryAutoCorrect(ac: (String) -> String?, text: String, proxy: TextProxy, put: (String) -> Unit): String? {
        if (engine.isEmpty || !AutoCorrect.triggers(text) || !proxy.canReEdit || proxy.hasSelection) return null
        val fix = ac(engine.rawKeystrokes) ?: return null
        val original = autoCorrectOriginal(fix, proxy) ?: return null
        val shown = engine.composed
        engine.reset()
        engine.forgetLastCommit()
        engine.noteExternalWord(false)
        TouchLog.write("autocorrect: -${Cp.count(shown)} +${Cp.count(fix)}")
        proxy.deleteCodePoints(Cp.count(shown))
        proxy.insertText(fix)
        put(text)
        expandedAtLastBoundary = true
        expansionUndo = ExpansionUndo(original, fix, text, autoCorrect = true)
        return fix
    }

    /**
     * Điều kiện theo CHỮ TRÊN MÀN HÌNH để thay từ đang soạn bằng [fix] ở ranh giới: không dính
     * URL/email/số ([ShortcutTable.isGlued]), chữ trước con trỏ đúng là từ đang soạn, chữ hoa hợp lệ
     * ([AutoCorrect.caseAllows]), [fix] khác chữ ranh giới sẽ chốt. Trả chữ đó (chữ gốc) hoặc null.
     */
    private fun autoCorrectOriginal(fix: String, proxy: TextProxy): String? {
        val raw = engine.rawKeystrokes
        val shown = engine.composed
        val ctx = proxy.contextBeforeInput() ?: return null
        if (ShortcutTable.isGlued(shown, ctx) || !proxy.confirmTail(shown)) return null
        if (!AutoCorrect.caseAllows(raw, AutoCorrect.isSentenceStart(Cp.dropLast(ctx, Cp.count(shown))))) return null
        val original = engine.peekCommitText(settings.autoRestore)
        return if (fix == original) null else original
    }

    /**
     * ONBOARDING-SPEC §8 — dấu cách lúc này có thay từ đang soạn bằng [fix] không (cùng điều kiện
     * [boundary] → [tryAutoCorrect], không đổi gì). Thanh gợi ý chỉ tô nền ô [fix] khi true; trả chữ
     * gốc (ô ngoặc kép) hoặc null. Không xét công tắc tự sửa (tắt: ô tô nền chỉ là gợi ý).
     */
    fun autoCorrectPreview(fix: String, proxy: TextProxy): String? {
        if (engine.isEmpty || englishMode || emailActive || passthrough || proxy.isSecure) return null
        if (!proxy.canReEdit || proxy.hasSelection || shortcutPreview != null) return null
        return autoCorrectOriginal(fix, proxy)
    }

    /** Chip "↩︎ chữ gốc": trả lại chữ gốc của lần tự sửa vừa rồi (như ⌫ ngay sau). */
    fun revertAutoCorrect(proxy: TextProxy): Boolean {
        val u = expansionUndo?.takeIf { it.autoCorrect } ?: return false
        expansionUndo = null
        return undoExpansion(u, proxy)
    }

    /** ⌫ ngay sau khi bung: màn hình phải kết thúc ĐÚNG bằng nội dung + ranh giới. */
    private fun undoExpansion(u: ExpansionUndo, proxy: TextProxy): Boolean {
        if (proxy.isSecure || passthrough || proxy.hasSelection) return false
        val tail = u.expansion + u.boundary
        val ctx = proxy.contextBeforeInput()
        if (ctx == null || !ctx.endsWith(tail) || u.retro && tail.isEmpty()) {
            TouchLog.write("shortcut undo: screen disagrees → ⌫ thường")
            return false
        }
        proxy.deleteCodePoints(Cp.count(tail))
        proxy.insertText(u.typed + u.boundary)
        engine.reset()
        enWord = ""
        engine.forgetLastCommit()
        afterOwnBoundary = u.boundary.isNotEmpty() && !Character.isLetterOrDigit(u.boundary.codePointBefore(u.boundary.length))
        TouchLog.write("shortcut undo: -${Cp.count(u.expansion)} +${Cp.count(u.typed)}")
        if (u.autoCorrect) revertedAutoCorrect = u.typed
        if (u.retro) {
            engine.resetContext()          // màn hình lại là chữ Việt cũ: lịch sử engine không còn khớp
            afterOwnBoundary = u.typed.isNotEmpty() && !Character.isLetterOrDigit(u.typed.codePointBefore(u.typed.length))
            revertedRetro = true
        }
        return true
    }

    /** Bảng gõ tắt hiệu lực (từ vựng vuốt: [SwipeVocab.setShortcuts]) — rỗng khi tắt Gõ tắt. */
    val effectiveShortcuts: ShortcutTable
        get() = if (settings.shortcutsEnabled) settings.shortcuts else ShortcutTable()

    /**
     * Nội dung sẽ chèn khi VUỐT ra [word] (đã áp Shift: "vn" / "Vn" / "VN") — đúng như gõ [word] +
     * dấu cách: chỉ khoá thuần chữ, theo công tắc Gõ tắt + ô cho phép (không passthrough / URL /
     * email). null = không phải khoá. = iOS EngineBridge.swipeShortcutExpansion.
     */
    fun swipeShortcutExpansion(word: String): String? {
        if (!settings.shortcutsEnabled || !shortcutsAllowed || passthrough || emailField ||
            settings.shortcuts.isEmpty || !ShortcutTable.isWordKey(word)) return null
        return settings.shortcuts.expansion(word)
    }

    /** Nội dung sẽ bung nếu gõ ranh giới ngay bây giờ (thanh gợi ý). Chỉ khoá chữ. */
    val shortcutPreview: String?
        get() {
            if (!settings.shortcutsEnabled || !shortcutsAllowed || passthrough || emailField || typedEmpty || settings.shortcuts.isEmpty) return null
            return settings.shortcuts.wordExpansion(typedWord, typedRaw)
        }

    /** Từ đang gõ tay (engine, hoặc nguyên văn ở chế độ Tiếng Anh) — cho gõ tắt. */
    private val typedEmpty: Boolean get() = if (englishMode) enWord.isEmpty() else engine.isEmpty
    private val typedWord: String get() = if (englishMode) enWord else engine.composed
    private val typedRaw: String get() = if (englishMode) enWord else engine.rawKeystrokes

    val isComposing: Boolean get() = !typedEmpty
    val composedWord: String get() = typedWord
    val rawWord: String get() = typedRaw
    val autoFixAdjacent: Boolean get() = settings.autoFixAdjacent

    /** Cache AdjacentKeyFixer theo raw — sống cùng bridge (cùng setting). */
    val adjacentFixCache = AdjacentKeyFixer.Cache()

    /**
     * Dạng hiển thị engine SẼ ra cho [raw] với đúng setting — engine scratch riêng
     * (như iOS: KHÔNG set contextualEnglish). Gọi được ngoài main thread.
     */
    fun composeTrial(raw: String): String {
        // Một engine scratch MỖI LUỒNG (main + vt-suggest), đưa về đúng trạng thái engine mới
        // bằng copyInto từ bản gốc — không cấp phát ~12 IntArray mỗi ứng viên (RAM-AUDIT #8).
        val e = trialEngine.get()!!
        PRISTINE.copyInto(e)
        configure(e, false)
        for (ch in raw) e.feed(ch)
        return e.composed
    }

    companion object {
        /** Chữ trước con trỏ kết thúc ĐÚNG bằng [expected]. null (không đọc được) ⇒ không sửa. */
        fun retroMatches(expected: String, ctx: String?): Boolean = ctx != null && expected.isNotEmpty() && ctx.endsWith(expected)

        /**
         * Nhãn chip mời: các từ ĐỔI sau khi sửa, trọn từ ("Hí cả í very fast " → "His car is").
         * [context] = chữ trước con trỏ (lấy phần đầu từ không nằm trong phép sửa); null/lệch ⇒ chỉ `insert`.
         */
        fun retroLabel(c: RetroCorrection, context: String?): String {
            val exp = c.expected; val ins = c.insert
            var suf = 0
            while (suf < exp.length && suf < ins.length && exp[exp.length - 1 - suf] == ins[ins.length - 1 - suf]) suf++
            val pre = if (context != null && retroMatches(exp, context)) context.dropLast(exp.length).takeLast(64) else ""
            val full = pre + ins
            fun inWord(ch: Char) = ch.isLetterOrDigit() || ch == '\'' || ch == '\u2019'
            var start = pre.length
            var end = maxOf(start, full.length - suf)
            while (start > 0 && inWord(full[start - 1])) start--
            while (end < full.length && inWord(full[end])) end++
            val label = full.substring(start, end).trim()
            return label.ifEmpty { ins.trim() }
        }

        /** Nhãn chip "Khôi phục" sau khi tự sửa ngược. Không qua tr(): khoá "Khôi phục" đã dịch "Restore". */
        val RETRO_UNDO_LABEL: String get() = "↩\uFE0E " + (if (L10n.isEnglish) "Undo" else "Khôi phục")

        /** Engine chưa từng gõ — chỉ đọc (copyInto không ghi vào nguồn). */
        private val PRISTINE = TelexEngine()
        private val trialEngine: ThreadLocal<TelexEngine> = ThreadLocal.withInitial { TelexEngine() }
    }

    /** Từ boundary SẼ chốt (peek non-mutating). */
    val predictedCommit: String get() = if (englishMode) enWord else engine.peekCommitText(settings.autoRestore)

    private fun apply(action: TelexAction, literal: String, proxy: TextProxy) {
        when (action) {
            is TelexAction.Replace -> {
                if (TouchLog.enabled) TouchLog.edit(action.backspaces, Cp.count(action.insert), action.insert)
                if (action.backspaces > 0) proxy.deleteCodePoints(action.backspaces)
                if (action.insert.isNotEmpty()) proxy.insertText(action.insert)
            }
            TelexAction.Passthrough -> {
                if (TouchLog.enabled) TouchLog.edit(0, Cp.count(literal), literal)
                if (literal.isNotEmpty()) proxy.insertText(literal)
            }
            TelexAction.None -> {}
        }
    }
}
