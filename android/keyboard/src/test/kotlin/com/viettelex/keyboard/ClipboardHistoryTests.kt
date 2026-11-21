package com.viettelex.keyboard

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ClipboardHistoryTests {
    private val min = 60_000L

    /** IME đọc file nền: mục chép trong lúc chờ (bản tạm) gộp lên trên bản đọc được, đúng thứ tự. */
    @Test fun absorbNewerKeepsLoadedHistory() {
        val loaded = ClipboardHistory.deserialize(ClipboardHistory().apply {
            add("cũ 1", 1_000); add("cũ 2", 2_000); togglePin("cũ 1")
        }.serialize())
        val tmp = ClipboardHistory()
        assertFalse(loaded.absorb(tmp))                  // bản tạm rỗng: không cần ghi lại
        tmp.add("mới 1", 3_000); tmp.add("cũ 2", 4_000); tmp.add("mới 2", 5_000)
        assertTrue(loaded.absorb(tmp))
        assertEquals(listOf("cũ 1", "mới 2", "cũ 2", "mới 1"), loaded.items(6_000).map { it.text })
        assertTrue(loaded.items(6_000).first().pinned)  // ghim của bản đọc giữ nguyên
    }

    @Test fun pinLimitFromPlusGate() {
        val h = ClipboardHistory()
        for (i in 1..7) h.add("mục $i", i.toLong())
        for (i in 1..5) assertTrue(h.togglePin("mục $i", limit = 5))
        assertFalse(h.togglePin("mục 6", limit = 5))     // miễn phí tối đa 5
        assertEquals(5, h.pinnedCount())
        assertTrue(h.togglePin("mục 1", limit = 5))      // bỏ ghim luôn được
        assertTrue(h.togglePin("mục 6", limit = 5))
        assertTrue(h.togglePin("mục 7", limit = null))   // Plus: không giới hạn
        assertEquals(6, h.pinnedCount())
    }

    @Test fun ttlAndSensitive() {
        val h = ClipboardHistory()
        h.add("xin chào", 0)
        h.add("Xk9#mP2qL", 0)                       // trông như mật khẩu ⇒ 2 phút
        assertEquals(2, h.items(1 * min).size)
        assertEquals(listOf("xin chào"), h.items(3 * min).map { it.text })
        assertEquals(listOf("xin chào"), h.items(59 * min).map { it.text })
        assertTrue(h.items(60 * min).isEmpty())
    }

    @Test fun pinnedNeverExpiresAndListedFirst() {
        val h = ClipboardHistory()
        h.add("a", 0); h.add("b", 1); h.add("c", 2)
        h.togglePin("a")
        assertEquals(listOf("a", "c", "b"), h.items(3).map { it.text })
        assertEquals(listOf("a"), h.items(10 * 60 * min).map { it.text })
    }

    @Test fun dedupeMovesToTopKeepsPin() {
        val h = ClipboardHistory()
        h.add("a", 0); h.add("b", 1); h.togglePin("a")
        h.add("a", 5)
        val a = h.items(6).first()
        assertEquals("a", a.text); assertTrue(a.pinned); assertEquals(5L, a.at)
        assertEquals(2, h.size)
    }

    @Test fun capEvictsOldestUnpinned() {
        val h = ClipboardHistory()
        assertEquals("trần mặc định 100 mục (cùng số với iOS)", 100, h.maxItems)
        h.add("pin", 0); h.togglePin("pin")
        for (i in 1..105) h.add("t$i", i.toLong())
        assertEquals(100, h.size)
        val texts = h.items(200).map { it.text }
        assertTrue("pin" in texts)
        assertFalse("t1" in texts); assertTrue("t105" in texts)
    }

    /** Trần tổng ký tự: vượt thì bỏ mục không ghim cũ nhất, giữ mục ghim và mục vừa thêm. */
    @Test fun totalCharBudgetEvictsOldestUnpinned() {
        assertEquals(200_000, ClipboardHistory.MAX_TOTAL_CHARS)
        val h = ClipboardHistory(maxTotalChars = 1000)
        fun big(c: String) = c.repeat(400)
        h.add(big("p"), 1); h.togglePin(big("p"))
        h.add(big("a"), 2)
        assertEquals(2, h.size)
        h.add(big("b"), 3)
        assertEquals(listOf(big("p"), big("b")), h.items(4).map { it.text })
        assertTrue(h.totalChars() <= 1000)
        h.add("c".repeat(900), 4)
        val texts = h.items(5).map { it.text }
        assertTrue("c".repeat(900) in texts); assertTrue(big("p") in texts); assertFalse(big("b") in texts)
        val n = ClipboardHistory()
        for (i in 0 until 100) n.add("số tài khoản $i", i.toLong())
        assertEquals(100, n.size)
    }

    @Test fun rejectsBlankAndHuge() {
        val h = ClipboardHistory()
        assertFalse(h.add("   ", 0))
        assertFalse(h.add("x".repeat(4001), 0))
        assertTrue(h.add("x".repeat(4000), 0))
    }

    @Test fun clearKeepsPinnedRemoveWorks() {
        val h = ClipboardHistory()
        h.add("a", 0); h.add("b", 0); h.add("c", 0); h.togglePin("b")
        h.remove("c")
        assertEquals(listOf("b", "a"), h.items(1).map { it.text })
        h.clear()
        assertEquals(listOf("b"), h.items(1).map { it.text })
        h.removeAll()
        assertEquals(0, h.size)
    }

    @Test fun latestFresh() {
        val h = ClipboardHistory()
        assertNull(h.latestFresh(0))
        h.add("0912345678", 0)
        assertEquals("0912345678", h.latestFresh(2 * min)?.text)
        assertNull(h.latestFresh(3 * min))
    }

    @Test fun serializeRoundtrip() {
        val h = ClipboardHistory()
        h.add("dòng 1\ndòng 2\tcột\\x\r", 10); h.add("b", 20); h.togglePin("b")
        h.add("Xk9#mP2qL", 30)
        val back = ClipboardHistory.deserialize(h.serialize())
        assertEquals(h.items(31), back.items(31))
        assertEquals(0, ClipboardHistory.deserialize("rác\n\n12\tx").size)
        assertEquals(0, ClipboardHistory.deserialize(null).size)
    }
}
