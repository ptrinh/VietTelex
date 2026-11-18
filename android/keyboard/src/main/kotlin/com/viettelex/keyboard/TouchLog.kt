package com.viettelex.keyboard

import java.io.File
import java.io.RandomAccessFile
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.concurrent.Executors

/**
 * Log gỡ lỗi chạm phím (port iOS TouchLog). TẮT mặc định (pref debugTouchLog). Ghi
 * filesDir/touchlog.txt trên thread nền. KÝ TỰ gõ chỉ được ghi khi [recordsCharacters] = true
 * — caller đặt = BuildConfig.DEBUG; bản Release KHÔNG BAO GIỜ ghi nội dung gõ.
 *
 * Gọn: quá [CAP_BYTES] ⇒ giữ ~[KEEP_BYTES] mới nhất (cắt ở đầu dòng) và đặt lại header lên
 * đầu; dòng y hệt dòng trước (trừ giờ) gộp thành "  ×N". File luôn mở đầu bằng header đủ bối
 * cảnh ([headerProvider], app gắn: phiên bản, máy, Android, locale, nguồn cài, setting).
 */
object TouchLog {
    const val CAP_BYTES = 256_000L
    const val KEEP_BYTES = 128_000

    @Volatile var enabled = false
    @Volatile var recordsCharacters = false
        private set
    @Volatile private var file: File? = null
    /** Dòng header (không thông tin cá nhân) — CHỈ gọi khi [enabled], lúc bàn phím hiện. */
    @Volatile var headerProvider: (() -> List<String>)? = null
    private var seq = 0
    private val stamp = DateTimeFormatter.ofPattern("HH:mm:ss.SSS").withZone(ZoneId.systemDefault())
    private val io by lazy {
        Executors.newSingleThreadExecutor { r -> Thread(r, "vt-touchlog").apply { isDaemon = true } }
    }
    /** Chờ ghi xong (test). */
    internal var synchronous = false

    // Trạng thái ghi — chỉ đụng trong [lock] (executor đơn luồng, hoặc caller khi synchronous).
    private val lock = Any()
    private var header: List<String> = emptyList()
    private var headerWritten = false
    private var collapse = TouchLogFormat.Collapser()

    fun configure(file: File?, recordsCharacters: Boolean) {
        synchronized(lock) {
            if (file != this.file) { headerWritten = false; collapse = TouchLogFormat.Collapser() }
            this.file = file
        }
        this.recordsCharacters = recordsCharacters
    }

    fun write(line: String) {
        val f = file
        if (!enabled || f == null) return
        val s = stamp.format(Instant.now())
        run { append(f, s, line, null) }
    }

    private fun run(job: () -> Unit) { if (synchronous) job() else io.execute(job) }

    /** Ghi `line`; `newHeader` != null ⇒ header đổi (ghi lại nếu khác lần trước). */
    private fun append(f: File, s: String, line: String, newHeader: List<String>?) = synchronized(lock) {
        try {
            if (newHeader != null && newHeader != header) { header = newHeader; headerWritten = false }
            if (!f.exists()) { headerWritten = false; collapse = TouchLogFormat.Collapser() }
            if (f.exists() && f.length() > CAP_BYTES) {
                val tail = RandomAccessFile(f, "r").use { raf ->
                    val n = minOf(raf.length(), KEEP_BYTES.toLong()).toInt()
                    raf.seek(raf.length() - n)
                    ByteArray(n).also { raf.readFully(it) }
                }
                f.writeBytes(TouchLogFormat.trimmed(tail, header))
                collapse = TouchLogFormat.Collapser()
                headerWritten = header.isNotEmpty()
            }
            val out = ArrayList<String>()
            if (!headerWritten && header.isNotEmpty()) {
                out += collapse.flush(); out += header
                headerWritten = true
            }
            collapse.push(line).forEach { out += if (it.startsWith(" ")) it else "$s $it" }
            if (out.isNotEmpty()) f.appendText(out.joinToString("\n", postfix = "\n"))
        } catch (_: Exception) {}
    }

    private fun chars(s: String?): String = if (recordsCharacters && s != null) " [$s]" else ""

    fun touchBegan(active: Int, batch: Int, lagMs: Double, hit: Boolean, y: Double, key: String? = null) {
        if (!enabled) return
        seq++
        val where = if (hit) "hit" else String.format("MISS y=%.0f", y)
        write(String.format("#%d BEGAN batch=%d active=%d lag=%.1fms ", seq, batch, active, lagMs) + where + chars(key))
    }

    fun buttonDown(name: String, lagMs: Double?) {
        if (!enabled) return
        write("$name DOWN lag=" + (lagMs?.let { String.format("%.1fms", it) } ?: "?"))
    }

    fun hitTest(target: String, y: Double) {
        if (!enabled) return
        write(String.format("HIT %s y=%.0f", target, y))
    }

    fun touchEnded(cancelled: Boolean, routed: Boolean) {
        if (!enabled) return
        write("${if (cancelled) "CANCELLED" else "ended"} routed=${if (routed) 1 else 0}")
    }

    fun key(kind: String, composing: Boolean, lagMs: Double, char: String? = null) {
        if (!enabled) return
        write(String.format("key %s comp=%d %.2fms", kind, if (composing) 1 else 0, lagMs) + chars(char))
    }

    fun edit(bs: Int, insertLen: Int, insert: String? = null) {
        if (!enabled) return
        write("edit bs=$bs ins=$insertLen" + chars(insert))
    }

    fun host(event: String, applyingEdit: Boolean, composing: Boolean) {
        if (!enabled) return
        write("host $event edit=${if (applyingEdit) 1 else 0} comp=${if (composing) 1 else 0}")
    }

    /**
     * Mỗi lần bàn phím hiện: header ([headerProvider] + [settingsLines]) — ghi lại CHỈ khi khác
     * header trước (hoặc file mới / vừa cắt), rồi một dòng "=== appear" ngắn.
     */
    fun session(appear: String, settingsLines: List<String> = emptyList()) {
        val f = file
        if (!enabled || f == null) return
        val h = (headerProvider?.invoke() ?: emptyList()) + settingsLines
        val s = stamp.format(Instant.now())
        run { append(f, s, "=== appear $appear", h) }
    }

    /** N dòng cuối. */
    fun tail(lines: Int = 80, f: File? = file): String {
        if (f == null || !f.exists()) return ""
        return try { f.readLines().takeLast(lines).joinToString("\n") } catch (_: Exception) { "" }
    }

    fun clear(f: File? = file) { try { f?.delete() } catch (_: Exception) {} }
}

/**
 * Phần thuần của log Debug mode (test: TouchLogTests): dòng setting, gộp dòng lặp, cắt file.
 * PRIVACY: chỉ phiên bản / máy / setting / SỐ LƯỢNG — không nội dung gõ, không cặp gõ tắt.
 */
object TouchLogFormat {
    private fun b(v: Boolean) = if (v) "1" else "0"

    /** Bối cảnh máy + app (app điền từ BuildConfig / Build / PackageManager) — không tên máy. */
    data class Context(
        val version: String = "?", val build: String = "?",
        val android: String = "?",      // "16 (API 36)"
        val device: String = "?",       // "Google Pixel 9" (hãng + model, không phải tên người dùng đặt)
        val abi: String = "?",
        val install: String = "?",      // play / sideload / mã installer
        val locales: String = "?",      // LocaleList hệ thống "vi-VN,en-US"
        val uiLanguage: String = "?",
        val theme: String = "?",
        val debugBuild: Boolean = false,
    )

    fun contextLines(c: Context): List<String> = listOf(
        "=== VietTelex Android ${c.version} (${c.build})${if (c.debugBuild) " debug" else ""} keyboard debug log",
        "device: ${c.device} · ${c.abi} · Android ${c.android} · install ${c.install}",
        "locale: ${c.locales} · ui ${c.uiLanguage} · theme ${c.theme}",
    )

    /** Ảnh chụp setting bàn phím (cùng nhóm với header iOS). */
    fun settingsLines(s: KeyboardSettings): List<String> {
        val method = if (s.vniMode) "vni" else if (s.simpleTelex) "telex-simple" else "telex"
        return listOf(
            "typing: method=$method free=${b(s.freeMarking)} modern=${b(s.modernTone)} quick=${b(s.quickTelex)}" +
                " spell=${b(s.liveSpellCheck)} restore=${b(s.autoRestore)} teen=${b(s.teencode)}" +
                " ctxEn=${b(s.contextualEnglish)} retroEn=${b(s.retroEnglishAuto)} freqEn=${b(s.englishByFrequency)}" +
                " reEdit=${b(s.reEditWords)} hat=${b(s.autoCircumflex)} adjFix=${b(s.autoFixAdjacent)} autoCorrect=${b(s.autoCorrect)}" +
                " caps=${b(s.autoCapitalize)} spaceAfterPunct=${b(s.autoSpaceAfterPunct)} hwTelex=${b(s.hardwareTelex)}",
            "suggest: on=${b(s.showSuggestions)} count=${s.suggestionCount} filter=${b(s.filterSensitive)}" +
                " learn=${b(s.learnWords)} noSuggestFields=${b(s.suggestInNoSuggestFields)}" +
                " numbers=${b(s.numberChips)} math=${b(s.mathResults)} addTones=${b(s.addTonesChip)}" +
                " tools=${b(s.textToolsEnabled)} clipHistory=${b(s.clipboardHistory)} incognito=${b(s.incognito)}",
            "input: swipe=${b(s.swipeTyping)} swipeEn=${b(s.swipeEnglish)} futo=${b(s.swipeFuto)}" +
                " smartTouch=${b(s.smartTouch)} spaceLang=${b(s.spaceSwipeLanguage)} keyCmds=${b(s.swipeKeyCommands)}" +
                " trackpad=${s.trackpadSpeed.id} holdShift=${b(s.holdShiftSymbols)}" +
                " lpNumbers=${b(s.longPressNumbers)} lpSymbols=${b(s.longPressSymbols)}",
            "ui: effect=${s.keyEffect.id} buddy=${s.buddy.id} oneHand=${s.oneHandMode} floating=${b(s.floatingKeyboard)}" +
                " split=${b(s.splitKeyboard)} numberRow=${b(s.numberRow)} large=${b(s.largeKeys)}" +
                " rowAdjust=${s.rowHeightAdjust} raise=${s.keyboardRaise} preview=${b(s.keyPreview)}" +
                " haptic=${b(s.hapticFeedback)}:${s.hapticStrength} sound=${b(s.keySound)}:${s.keySoundStyle}:${s.keySoundVolume}",
            // Đếm thôi: cặp gõ tắt là nội dung người dùng.
            "shortcuts: ${if (s.shortcutsEnabled) "on" else "off"}:${s.shortcuts.entries.size}" +
                " templates=${b(s.templatesEnabled)}",
        )
    }

    /**
     * Gộp dòng y hệt dòng trước: dòng đầu in ngay, dòng lặp không in, hết chuỗi in "  ×N"
     * (N = tổng số lần) trước dòng mới.
     */
    class Collapser {
        private var last: String? = null
        private var repeats = 0

        fun push(line: String): List<String> {
            if (line == last) { repeats++; return emptyList() }
            val out = flush() + line
            last = line
            return out
        }

        fun flush(): List<String> {
            if (repeats == 0) return emptyList()
            val out = listOf("  ×${repeats + 1}")
            repeats = 0; last = null
            return out
        }
    }

    /** Bỏ mảnh dòng dở đầu `tail` (đã cắt theo byte), đặt header + dòng đánh dấu lên đầu. */
    fun trimmed(tail: ByteArray, header: List<String>): ByteArray {
        val nl = tail.indexOf('\n'.code.toByte())
        val body = if (nl >= 0) tail.copyOfRange(nl + 1, tail.size) else tail
        val head = (if (header.isEmpty()) "" else header.joinToString("\n", postfix = "\n")) +
            "… (older lines trimmed)\n"
        return head.toByteArray() + body
    }
}
