package com.viettelex.keyboard

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/** Giữ phím bàn số / ký hiệu ra hàng biến thể như stock iOS. Song sinh iOS KeyVariantsTests. */
class KeyVariantsTests {
    /**
     * Phím trên bàn 123 / #+= Android = bàn iOS (#165; android/app KeyLayout NUM1/NUM2/SYM1/SYM2 +
     * hàng 3 ". , ? ! '" + "," "." hàng đáy) — KeyLayoutTest kiểm lại từ layout thật và file Swift.
     */
    private val numbersKeys = listOf("1","2","3","4","5","6","7","8","9","0",
        "-","/",":",";","(",")","\$","&","@","\"", ".",",","?","!","'")
    private val symbolsKeys = listOf("[","]","{","}","#","%","^","*","+","=",
        "_","\\","|","~","<",">","€","¥","₫","•", ".",",","?","!","'")

    /** Mọi phím có biến thể phải có trên bàn; phím trên bàn không bắt buộc có biến thể. */
    @Test fun everyEntryStartsWithItsBaseAndIsOnAPlane() {
        val onPlanes = (numbersKeys + symbolsKeys).toSet()
        for ((key, list) in KeyVariants.table) {
            // ô 0 = ký tự gốc (chọn sẵn); HOLD_PRESELECT: gốc ở ô 1, ô 0 là ký tự chọn sẵn khi giữ.
            assertEquals("ô gốc — $key", key, list[if (key in KeyVariants.HOLD_PRESELECT) 1 else 0])
            assertTrue(key, list.size >= 2)
            assertEquals("$key: trùng biến thể", list.size, list.toSet().size)
            assertTrue("$key không có trên bàn số/ký hiệu", key in onPlanes)
        }
    }

    @Test fun stockOrdering() {
        val t = KeyVariants.table
        assertEquals(listOf("\"", "”", "“", "„", "»", "«"), t["\""])
        assertEquals(listOf("'", "‘", "’", "`"), t["'"])
        assertEquals(listOf("-", "–", "—", "•"), t["-"])
        assertEquals(listOf("0", "°"), t["0"])
        assertEquals(listOf(".", "…"), t["."])
        assertEquals(listOf("?", "¿"), t["?"])
        assertEquals(listOf("!", "¡"), t["!"])
        assertEquals(listOf("/", "=", "\\"), t["/"])
        assertEquals(listOf("&", "§"), t["&"])
        assertEquals(listOf("%", "‰"), t["%"])
        // #165: "$" là phím gốc như iOS; giữ ⇒ ₫ ngay ô kế, rồi € £ ¥ ₩ ₹ ₽ ¢.
        assertEquals(listOf("\$", "₫", "€", "£", "¥", "₩", "₹", "₽", "¢"), t["\$"])
        assertEquals(listOf("=", "≠", "≈"), t["="])
        assertEquals(listOf("+", "±"), t["+"])
        assertEquals(listOf("*", "×"), t["*"])
        assertEquals("₫ (phím gốc bàn #+=) không có hàng biến thể — như iOS", null, t["₫"])
    }

    @Test fun gating() {
        assertEquals(KeyVariants.table["\""], KeyVariants.variants("\"", symbolPlane = true))
        assertEquals("bàn chữ: không", emptyList<String>(), KeyVariants.variants("\"", symbolPlane = false))
        assertEquals("không đè giữ q…p", emptyList<String>(), KeyVariants.variants("e", symbolPlane = false))
        assertEquals("ô số: không", emptyList<String>(), KeyVariants.variants("0", symbolPlane = true, numericField = true))
        assertEquals("phím không có biến thể", emptyList<String>(), KeyVariants.variants("@", symbolPlane = true))
    }

    /** #165: không còn phím nào chọn sẵn ô khác ký tự gốc; cơ chế HOLD_PRESELECT vẫn giữ. */
    @Test fun holdPreselectKeys() {
        assertEquals(emptySet<String>(), KeyVariants.HOLD_PRESELECT)
        assertTrue(KeyVariants.HOLD_PRESELECT.all { it in KeyVariants.table && it in KeyVariants.ANDROID_ONLY })
    }

    /** #165: chạm ⇒ "$"; giữ rồi nhả tại chỗ ⇒ "$"; giữ rồi trượt một ô ⇒ "₫". */
    @Test fun dollarKeyTapAndHold() {
        val choices = KeyVariants.variants("\$", symbolPlane = true)
        val itemW = 38f; val keyX = 120f
        val layout = DomainPopup.layout(keyX, itemW, choices.size, 600f)
        fun hold(slide: Float?): List<String> {
            val commits = KeyCommitQueue(); val key = Any(); val out = ArrayList<String>()
            commits.arm(key) { out += "\$" }
            val h = DomainPopup.Hold(choices)
            assertTrue(h.fire(commits, key, layout, 0f, 100f, keyX, 80f) { out += it })
            if (slide != null) h.move(slide, 80f)
            commits.release(key)
            return out
        }
        assertEquals(listOf("\$"), hold(null))
        assertTrue(!layout.mirrored)
        assertEquals(listOf("₫"), hold(keyX + itemW))       // một ô theo hướng hàng loe ⇒ ₫
        val tap = KeyCommitQueue(); val k = Any(); val out = ArrayList<String>()
        tap.arm(k) { out += "\$" }; tap.release(k)
        assertEquals(listOf("\$"), out)
    }

    /**
     * Hai bảng (Kotlin / Swift) trùng ở mọi phím — đọc thẳng file Swift. Từ #165 bàn 123 / #+=
     * Android có đúng bộ phím iOS nên [KeyVariants.ANDROID_ONLY] / [KeyVariants.IOS_ONLY] rỗng;
     * lệch thêm phím nào phải khai báo ở đó.
     */
    @Test fun matchesSwiftTable() {
        val f = listOf("../../iOS", "../iOS", "iOS").map { File(it, "Keyboard/KeyVariants.swift") }
            .firstOrNull { it.exists() } ?: error("không thấy iOS/Keyboard/KeyVariants.swift")
        val row = Regex("""^\s*"((?:\\.|[^"\\])*)": \[(.*)],\s*$""")
        val item = Regex(""""((?:\\.|[^"\\])*)"""")
        fun unesc(s: String) = s.replace("\\\"", "\"").replace("\\\\", "\\")
        val swift = f.readLines().mapNotNull { row.find(it) }.associate { m ->
            unesc(m.groupValues[1]) to item.findAll(m.groupValues[2]).map { unesc(it.groupValues[1]) }.toList()
        }
        val android = KeyVariants.table
        assertEquals("chỉ Android", KeyVariants.ANDROID_ONLY, android.keys - swift.keys)
        assertEquals("chỉ iOS", KeyVariants.IOS_ONLY, swift.keys - android.keys)
        assertEquals("#165: không lệch", emptySet<String>(), KeyVariants.ANDROID_ONLY + KeyVariants.IOS_ONLY)
        val shared = android.keys intersect swift.keys
        assertTrue(shared.size >= 20)
        for (k in shared) assertEquals("biến thể \"$k\" lệch iOS", swift[k], android[k])
    }
}
