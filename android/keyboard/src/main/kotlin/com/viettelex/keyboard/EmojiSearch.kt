package com.viettelex.keyboard

import com.viettelex.telexcore.TelexEngine
import java.text.Normalizer

/**
 * Tìm emoji bằng tiếng Việt (port iOS EmojiSearch). Khoá = section SKEY của emoji.bin:
 * từ khoá gợi ý emoji sẵn có (EmojiSuggest) + tên/từ khoá CLDR vi. Khớp TIỀN TỐ KHÔNG DẤU
 * tại đầu một từ của khoá; hạng: trùng nguyên khoá có dấu > trùng không dấu > tiền tố có
 * dấu > tiền tố đầu khoá > tiền tố ở từ sau; cùng hạng thì khoá ngắn trước. Quét tuyến
 * tính trên blob mmap (không dựng map). Khoá tiếng Anh (section SKEN, CLDR en) chỉ quét khi
 * câu tìm KHÔNG dấu, hạng luôn sau hạng tiếng Việt tương ứng (nguyên khoá → 1, tiền tố → 5/6)
 * — thứ tự kết quả tiếng Việt không đổi. Gợi ý khi gõ: [typing] (khớp NGUYÊN khoá).
 */
object EmojiSearch {
    /** Luật fold PHẢI khớp Scripts/gen-emoji-data.py: thường, bỏ dấu (đ→d), dấu câu → space. */
    fun fold(s: String): String {
        val n = Normalizer.normalize(s.lowercase().replace('đ', 'd'), Normalizer.Form.NFD)
        val sb = StringBuilder(n.length)
        for (c in n) if (c.code !in 0x300..0x36F) sb.append(c)
        return clean(sb.toString())
    }

    /** Chữ thường NFC, ký tự không phải chữ/số → space, gộp space. */
    fun clean(s: String): String {
        val n = Normalizer.normalize(s.lowercase(), Normalizer.Form.NFC)
        val sb = StringBuilder(n.length)
        var pending = false
        var i = 0
        while (i < n.length) {
            val cp = n.codePointAt(i)
            if (Character.isLetterOrDigit(cp)) {
                if (pending && sb.isNotEmpty()) sb.append(' ')
                pending = false
                sb.appendCodePoint(cp)
            } else pending = true
            i += Character.charCount(cp)
        }
        return sb.toString()
    }

    private class Index {
        val base = EmojiData.section("SKEY")
        val count = EmojiData.u32(base)
        val foldOff = base + 4
        val origOff = foldOff + (count + 1) * 4
        val idOff = origOff + (count + 1) * 4
        val foldBase = idOff + (count + 1) * 4
        val origBase = foldBase + EmojiData.u32(foldOff + count * 4)
        val idBase = origBase + EmojiData.u32(origOff + count * 4)
    }
    private val index by lazy { Index() }

    /** SKEN: u32 m | u16 foldOff[m+1] | u16 idOff[m+1] | fold utf8 | u16 ids. */
    private class EnIndex {
        val base = EmojiData.section("SKEN")
        val count = EmojiData.u32(base)
        val foldOff = base + 4
        val idOff = foldOff + (count + 1) * 2
        val foldBase = idOff + (count + 1) * 2
        val idBase = foldBase + EmojiData.u16(foldOff + count * 2)
        fun fold(k: Int) = foldBase + EmojiData.u16(foldOff + k * 2)
        fun idStart(k: Int) = EmojiData.u16(idOff + k * 2)
    }
    private val en by lazy { EnIndex() }
    private val flagBase by lazy { EmojiData.section("FLG2") }

    val enKeyCount: Int get() = en.count

    val keyCount: Int get() = index.count

    /** Emoji khớp [query]; câu tìm là emoticon ASCII (":)", "<3", "=))"…) ⇒ emoji tương ứng đứng đầu. */
    fun search(query: String, limit: Int = 60, supported: (Int) -> Boolean = EmojiData::isSupported): List<String> {
        val rest = ids(query, limit, supported).map(EmojiData::emoji)
        val emo = emoticon(query)
        if (emo.isEmpty()) return rest
        val seen = emo.toHashSet()
        return (emo + rest.filter { seen.add(it) }).take(limit)
    }

    /**
     * Emoticon ASCII → emoji (khoá viết thường; bảng thuần, song sinh iOS
     * EmojiSearch.emoticons). Emoji đều thuộc Emoji ≤ 1.0 ⇒ máy nào cũng vẽ được.
     */
    val EMOTICONS: Map<String, List<String>> = mapOf(
        ":)" to listOf("😊", "🙂", "☺️"), ":-)" to listOf("😊", "🙂", "☺️"), "(:" to listOf("🙂", "😊"),
        ":d" to listOf("😄", "😃", "😁"), ":-d" to listOf("😄", "😃", "😁"),
        ":(" to listOf("☹️", "🙁", "😞"), ":-(" to listOf("☹️", "🙁", "😞"),
        ";)" to listOf("😉"), ";-)" to listOf("😉"),
        ":p" to listOf("😛", "😜", "😝"), ":-p" to listOf("😛", "😜", "😝"),
        "<3" to listOf("❤️", "😍", "💕"), "</3" to listOf("💔"),
        "=))" to listOf("😂", "🤣", "😆"), ":))" to listOf("😆", "😂", "😄"), ":)))" to listOf("😂", "🤣", "😆"),
        "^_^" to listOf("😊", "😄"), "^^" to listOf("😊", "😄"), "^.^" to listOf("😊", "😄"),
        "-_-" to listOf("😑", "😒"), "-.-" to listOf("😑", "😒"),
        ":o" to listOf("😮", "😲"), ":-o" to listOf("😮", "😲"),
        "xd" to listOf("😆", "😂"),
        ":'(" to listOf("😢", "😭"), "t_t" to listOf("😭", "😢"), "t.t" to listOf("😭", "😢"), ";(" to listOf("😢"),
        ":*" to listOf("😘"), ":-*" to listOf("😘"), ":|" to listOf("😐"), ":-|" to listOf("😐"),
        ":/" to listOf("😕"), ":-/" to listOf("😕"),
        ">:(" to listOf("😠", "😡"), "o.o" to listOf("😳", "😮"), "b)" to listOf("😎"), "8)" to listOf("😎"),
    )

    /** Emoji cho câu tìm là MỘT emoticon (bỏ space hai đầu, không phân biệt hoa thường). */
    fun emoticon(query: String): List<String> = EMOTICONS[query.trim(' ', '\t').lowercase()].orEmpty()

    fun ids(query: String, limit: Int = 60, supported: (Int) -> Boolean = EmojiData::isSupported): List<Int> {
        val q = clean(query)
        val qf = fold(q).toByteArray(Charsets.UTF_8)
        if (qf.isEmpty()) return emptyList()
        val qo = q.toByteArray(Charsets.UTF_8)
        val x = index
        val buf = EmojiData.buf
        // (rank, len, key) gói vào Long để sort không cấp phát object.
        // Tiếng Anh chỉ khi câu tìm không dấu (gõ "cá" không kéo "cat"/"cake" vào).
        val withEn = qo.contentEquals(qf)
        val y = if (withEn) en else null
        val hits = LongArray(x.count + (y?.count ?: 0))
        var nh = 0
        for (k in 0 until x.count) {
            val fs = x.foldBase + buf.getInt(x.foldOff + k * 4)
            val fe = x.foldBase + buf.getInt(x.foldOff + k * 4 + 4)
            val pos = wordPrefix(fs, fe, qf)
            if (pos < 0) continue
            val os = x.origBase + buf.getInt(x.origOff + k * 4)
            val oe = x.origBase + buf.getInt(x.origOff + k * 4 + 4)
            val exactFold = pos == 0 && fe - fs == qf.size
            val rank = when {
                exactFold && equal(os, oe, qo) -> 0
                exactFold -> 1
                wordPrefix(os, oe, qo) >= 0 -> 2
                pos == 0 -> 3
                else -> 4
            }
            hits[nh++] = (rank.toLong() shl 50) or (minOf(fe - fs, 0xFFFF).toLong() shl 24) or k.toLong()
        }
        if (y != null) for (k in 0 until y.count) {
            val fs = y.fold(k); val fe = y.fold(k + 1)
            val pos = wordPrefix(fs, fe, qf)
            if (pos < 0) continue
            val rank = if (pos == 0 && fe - fs == qf.size) 1 else if (pos == 0) 5 else 6
            hits[nh++] = (rank.toLong() shl 50) or (minOf(fe - fs, 0xFFFF).toLong() shl 24) or (x.count + k).toLong()
        }
        java.util.Arrays.sort(hits, 0, nh)
        val out = ArrayList<Int>()
        val seen = HashSet<Int>()
        for (h in 0 until nh) {
            val k = (hits[h] and 0xFFFFFF).toInt()
            val isEn = k >= x.count
            val s = if (isEn) en.idStart(k - x.count) else buf.getInt(x.idOff + k * 4)
            val e = if (isEn) en.idStart(k - x.count + 1) else buf.getInt(x.idOff + k * 4 + 4)
            for (j in s until e) {
                val id = EmojiData.u16((if (isEn) en.idBase else x.idBase) + j * 2)
                if (seen.add(id) && supported(id)) {
                    out += id
                    if (out.size >= limit) return out
                }
            }
        }
        return out
    }

    // ---- gợi ý khi gõ (thanh gợi ý) — chỉ gọi khi bảng EmojiSuggest không có từ này

    /** Khoá tiếng Anh có nhiều emoji hơn mức này là quá chung ("face", "flag"…) — không gợi ý khi gõ. */
    const val TYPING_MAX_IDS = 24

    /**
     * Emoji cho từ đang gõ từ khoá tiếng Anh (SKEN) + mã nước in hoa (FLG2).
     * - "JP"/"VN"/"US" (đúng 2 chữ IN HOA, Telex không biến đổi) → cờ. Chữ thường/"Jp" không
     *   tra: 65/259 mã trùng âm tiết Việt không dấu (la, ma, to, do, ca, co…).
     * - Từ chỉ gồm chữ ASCII (tiếng Việt có dấu thì thôi): khớp NGUYÊN khoá, thử cụm "từ trước
     *   + từ này" ("hot dog", "united states") rồi từ này, rồi raw. Khoá trùng âm tiết Việt
     *   không dấu / ngắn < 3 chữ đã bị script lọc nên "an", "ban", "me" không ra.
     */
    fun typing(prev: String?, composed: String, raw: String, limit: Int = 3,
               supported: (Int) -> Boolean = EmojiData::isSupported): List<String> {
        if (composed.length == 2 && composed == raw && composed.all { it in 'A'..'Z' }) {
            val id = flag(composed[0], composed[1])
            return if (id >= 0 && supported(id)) listOf(EmojiData.emoji(id)) else emptyList()
        }
        if (!isAsciiWord(composed)) return emptyList()
        val c = composed.lowercase()
        if (prev != null && isAsciiWord(prev)) {
            val r = exact(prev.lowercase() + " " + c, limit, supported)
            if (r.isNotEmpty()) return r
        }
        if (c.length >= 3) {
            val r = exact(c, limit, supported)
            if (r.isNotEmpty()) return r
        }
        if (raw != composed && raw.length >= 3 && isAsciiWord(raw)) return exact(raw.lowercase(), limit, supported)
        return emptyList()
    }

    private fun isAsciiWord(s: String) = s.isNotEmpty() && s.all { it in 'a'..'z' || it in 'A'..'Z' }

    /** Binary search khớp nguyên khoá trong SKEN (sort theo byte của fold); query ASCII. */
    private fun exact(q: String, limit: Int, supported: (Int) -> Boolean): List<String> {
        val y = en
        val buf = EmojiData.buf
        fun cmp(k: Int): Int {
            var i = y.fold(k); val end = y.fold(k + 1); var j = 0
            while (i < end && j < q.length) {
                val a = buf.get(i).toInt() and 0xFF; val b = q[j].code
                if (a != b) return if (a < b) -1 else 1
                i++; j++
            }
            return if (i < end) 1 else if (j < q.length) -1 else 0
        }
        var lo = 0; var hi = y.count
        while (lo < hi) { val mid = (lo + hi) ushr 1; if (cmp(mid) < 0) lo = mid + 1 else hi = mid }
        if (lo >= y.count || cmp(lo) != 0) return emptyList()
        val s = y.idStart(lo); val e = y.idStart(lo + 1)
        if (e - s > TYPING_MAX_IDS) return emptyList()
        val out = ArrayList<String>(limit)
        for (j in s until e) {
            val id = EmojiData.u16(y.idBase + j * 2)
            if (supported(id)) { out += EmojiData.emoji(id); if (out.size >= limit) break }
        }
        return out
    }

    /** FLG2: u32 n | n × 2B mã in hoa (sort) | u16 id[n] → id cờ, −1 nếu không có. */
    private fun flag(a: Char, b: Char): Int {
        val base = flagBase
        val buf = EmojiData.buf
        val n = EmojiData.u32(base)
        var lo = 0; var hi = n
        while (lo < hi) {
            val mid = (lo + hi) ushr 1
            val x = buf.get(base + 4 + mid * 2).toInt(); val y = buf.get(base + 5 + mid * 2).toInt()
            if (x == a.code && y == b.code) return EmojiData.u16(base + 4 + n * 2 + mid * 2)
            if (x < a.code || (x == a.code && y < b.code)) lo = mid + 1 else hi = mid
        }
        return -1
    }

    /** Vị trí nơi [q] là tiền tố của một từ trong [s, e) (đầu khoá hoặc sau space); −1 nếu không. */
    private fun wordPrefix(s: Int, e: Int, q: ByteArray): Int {
        val buf = EmojiData.buf
        val n = q.size
        var i = s
        while (i + n <= e) {
            if (i == s || buf.get(i - 1) == 0x20.toByte()) {
                var j = 0
                while (j < n && buf.get(i + j) == q[j]) j++
                if (j == n) return i - s
            }
            i++
        }
        return -1
    }

    private fun equal(s: Int, e: Int, q: ByteArray): Boolean {
        if (e - s != q.size) return false
        val buf = EmojiData.buf
        for (j in q.indices) if (buf.get(s + j) != q[j]) return false
        return true
    }
}

/**
 * Ô tìm emoji tự vẽ: gõ bằng chính phím VietTelex, có Telex (engine RIÊNG — không đụng
 * composition của ô nhập thật). Thuần logic; KeyboardView lo vẽ.
 */
class EmojiSearchSession(settings: KeyboardSettings = KeyboardSettings()) {
    private val engine = TelexEngine().apply {
        freeMarking = settings.freeMarking
        simpleTelex = settings.simpleTelex
        liveSpellCheck = settings.liveSpellCheck
        eagerEnglishRestore = settings.autoRestore
        quickTelex = settings.quickTelex
        modernTone = settings.modernTone
        teencode = settings.teencode
        autoCircumflex = settings.autoCircumflex
    }
    private val committed = StringBuilder()

    /** Chuỗi đang hiện trong ô tìm. */
    val query: String get() = committed.toString() + engine.peekCommitText(false)

    fun type(ch: Char) {
        val c = ch.lowercaseChar()
        if (c in 'a'..'z') engine.feed(c)
        else { commitWord(); committed.append(c) }
    }

    fun insert(s: String) { for (c in s) type(c) }

    fun space() {
        commitWord()
        if (committed.isNotEmpty() && committed.last() != ' ') committed.append(' ')
    }

    fun backspace() {
        if (!engine.isEmpty) engine.backspace()
        else if (committed.isNotEmpty()) committed.setLength(committed.length - 1)
    }

    fun clear() { engine.reset(); committed.setLength(0) }

    private fun commitWord() {
        if (engine.isEmpty) return
        committed.append(engine.commitText(true))
    }
}
