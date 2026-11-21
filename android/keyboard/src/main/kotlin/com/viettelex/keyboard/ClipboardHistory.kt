package com.viettelex.keyboard

/**
 * "Giữ lịch sử clipboard": 1 giờ (mặc định) / 24 giờ / 7 ngày — pref [Keys.CLIPBOARD_TTL]
 * lưu [id] ("1h"/"24h"/"7d", cùng khoá + id iOS `ClipboardTTL`). Chỉ áp cho mục không ghim,
 * không "trông như bí mật" (mục bí mật giữ 2 phút). IME đọc khi hiện bàn phím / pref đổi.
 */
enum class ClipboardTTL(val id: String, val ms: Long) {
    HOUR_1("1h", 3_600_000L),
    HOURS_24("24h", 24 * 3_600_000L),
    DAYS_7("7d", 7 * 24 * 3_600_000L);

    companion object {
        val DEFAULT = HOUR_1
        val IDS: Set<String> = entries.map { it.id }.toCollection(LinkedHashSet())
        /** Giá trị lạ / thiếu → 1 giờ. */
        fun of(raw: Any?): ClipboardTTL = entries.firstOrNull { it.id == raw } ?: DEFAULT
    }
}

/**
 * Lịch sử clipboard (chỉ trên máy): tối đa [maxItems] mục và [maxTotalChars] ký tự tổng (vượt ⇒
 * bỏ mục không ghim cũ nhất; mục vừa thêm và mục ghim luôn được giữ), mục không ghim hết hạn sau
 * [ttlMs] ([ClipboardTTL], đổi được lúc chạy — áp ở lần [prune] kế tiếp; mục "trông như
 * bí mật" sau [sensitiveTtlMs]); mục ghim không hết hạn.
 * Hàm thuần, không I/O — IME lo đọc/ghi file bằng [serialize]/[deserialize].
 * iOS `ClipboardHistory.swift` port cùng hợp đồng.
 */
class ClipboardHistory(
    val maxItems: Int = MAX_ITEMS,
    var ttlMs: Long = ClipboardTTL.DEFAULT.ms,
    val sensitiveTtlMs: Long = 120_000,
    val maxTotalChars: Int = MAX_TOTAL_CHARS,
) {
    data class Item(val text: String, val at: Long, val pinned: Boolean, val sensitive: Boolean)

    /** Mới nhất ở đầu. */
    private val list = ArrayList<Item>()

    val size: Int get() = list.size

    /** Thêm/đưa lên đầu. Trả false nếu bỏ qua (rỗng, quá dài). */
    fun add(text: String, now: Long, sensitive: Boolean = ClipSensitivity.looksSecret(text)): Boolean {
        if (text.isBlank() || text.length > MAX_TEXT) return false
        val i = list.indexOfFirst { it.text == text }
        val pinned = i >= 0 && list[i].pinned
        if (i >= 0) list.removeAt(i)
        list.add(0, Item(text, now, pinned, sensitive))
        while (list.size > maxItems) {
            val k = list.indexOfLast { !it.pinned }
            if (k < 0) break
            list.removeAt(k)
        }
        // Trần tổng ký tự: bỏ dần mục không ghim cũ nhất, trừ mục vừa thêm (vị trí 0).
        var total = totalChars()
        while (total > maxTotalChars) {
            val k = list.indexOfLast { !it.pinned }
            if (k <= 0) break
            total -= list[k].text.length
            list.removeAt(k)
        }
        return true
    }

    fun totalChars(): Int = list.sumOf { it.text.length }

    /** Bỏ mục không ghim quá hạn. Trả true nếu có thay đổi. */
    fun prune(now: Long): Boolean = list.removeAll { !it.pinned && now - it.at >= if (it.sensitive) sensitiveTtlMs else ttlMs }

    /** Danh sách hiển thị: ghim lên trên, trong mỗi nhóm mới nhất trước. */
    fun items(now: Long): List<Item> {
        prune(now)
        return list.filter { it.pinned } + list.filter { !it.pinned }
    }

    fun contains(text: String) = list.any { it.text == text }

    /**
     * Ghim/bỏ ghim. [limit] = số mục ghim tối đa (null = không giới hạn — Plus
     * `PlusGate.pinnedClipLimit`); đầy thì KHÔNG ghim thêm, trả false (bỏ ghim luôn được).
     */
    fun togglePin(text: String, limit: Int? = null): Boolean {
        val i = list.indexOfFirst { it.text == text }
        if (i < 0) return false
        if (!list[i].pinned && limit != null && pinnedCount() >= limit) return false
        list[i] = list[i].copy(pinned = !list[i].pinned)
        return true
    }

    fun pinnedCount(): Int = list.count { it.pinned }

    fun remove(text: String): Boolean = list.removeAll { it.text == text }

    /** "Xoá hết": bỏ mục không ghim, giữ mục ghim. */
    fun clear() { list.removeAll { !it.pinned } }

    fun removeAll() { list.clear() }

    /** Mục mới nhất nếu vừa thêm trong [windowMs] (chip "vừa copy"). */
    fun latestFresh(now: Long, windowMs: Long = 180_000): Item? =
        list.firstOrNull()?.takeIf { now - it.at in 0 until windowMs }

    /**
     * Gộp các mục của [newer] (bản RAM tạm, ghi trong lúc bản này còn đang đọc từ file trên nền)
     * lên trên, cũ → mới theo thời gian, giữ ghim. Trả true nếu có mục được gộp (cần ghi lại file).
     */
    fun absorb(newer: ClipboardHistory): Boolean {
        if (newer.list.isEmpty()) return false
        for (item in newer.list.sortedBy { it.at }) {
            add(item.text, item.at, item.sensitive)
            if (item.pinned) list.indexOfFirst { it.text == item.text }
                .takeIf { it >= 0 && !list[it].pinned }?.let { list[it] = list[it].copy(pinned = true, sensitive = false) }
        }
        return true
    }

    /** Mỗi dòng: `at\tpinned\tsensitive\ttext` (text escape `\\`, `\n`, `\t`, `\r`). */
    fun serialize(): String = buildString {
        for (it in list) {
            append(it.at).append('\t').append(if (it.pinned) '1' else '0').append('\t')
                .append(if (it.sensitive) '1' else '0').append('\t').append(escape(it.text)).append('\n')
        }
    }

    companion object {
        const val MAX_TEXT = 4000
        /** Trần số mục (20 → 100 theo phản hồi người dùng 22/11/2026) — cùng số với iOS. */
        const val MAX_ITEMS = 100
        /** Trần tổng ký tự (cả mục ghim) — cùng số với iOS `defaultMaxTotalChars`. */
        const val MAX_TOTAL_CHARS = 200_000

        fun deserialize(s: String?, maxItems: Int = MAX_ITEMS, ttlMs: Long = ClipboardTTL.DEFAULT.ms): ClipboardHistory {
            val h = ClipboardHistory(maxItems, ttlMs)
            if (s.isNullOrEmpty()) return h
            for (line in s.split('\n')) {
                val p = line.split('\t', limit = 4)
                if (p.size != 4) continue
                val at = p[0].toLongOrNull() ?: continue
                val text = unescape(p[3])
                if (text.isEmpty()) continue
                h.list += Item(text, at, p[1] == "1", p[2] == "1")
            }
            while (h.list.size > maxItems) h.list.removeAt(h.list.size - 1)
            return h
        }

        internal fun escape(t: String) = buildString(t.length) {
            for (c in t) when (c) {
                '\\' -> append("\\\\"); '\n' -> append("\\n"); '\t' -> append("\\t"); '\r' -> append("\\r")
                else -> append(c)
            }
        }

        internal fun unescape(t: String) = buildString(t.length) {
            var i = 0
            while (i < t.length) {
                val c = t[i]
                if (c == '\\' && i + 1 < t.length) {
                    when (t[i + 1]) { 'n' -> append('\n'); 't' -> append('\t'); 'r' -> append('\r'); else -> append(t[i + 1]) }
                    i += 2
                } else { append(c); i++ }
            }
        }
    }
}
