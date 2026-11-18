package com.viettelex.telexcore

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Test
import java.text.Normalizer

/**
 * Port of TelexCore AutoCircumflexTests.swift — issue #166 (18/11/2026): "Tự thêm dấu mũ", công
 * tắc TẮT mặc định. Khi từ đã có phím thanh mà vần không mũ không tồn tại, còn vần có mũ hợp
 * lệ, hiện luôn dấu mũ.
 */
class AutoCircumflexTest {

    private fun engine(on: Boolean, live: Boolean = true, teencode: Boolean = false) = TelexEngine().apply {
        liveSpellCheck = live; this.teencode = teencode; autoCircumflex = on
    }

    private fun commit(keys: String, on: Boolean = true, live: Boolean = true, teencode: Boolean = false): String {
        val e = engine(on, live, teencode)
        for (ch in keys) e.feed(ch)
        return e.commitText(true)
    }

    private fun composed(keys: String, on: Boolean = true): String {
        val e = engine(on)
        for (ch in keys) e.feed(ch)
        return e.composed
    }

    private fun nfc(s: String) = Normalizer.normalize(s, Normalizer.Form.NFC)

    private val rows = listOf(
        // iê, yê, uyê
        "vietj" to "việt", "viejt" to "việt", "viecj" to "việc", "nguyenx" to "nguyễn",
        "biets" to "biết", "tienf" to "tiền", "dieuf" to "diều", "ddieemr" to "điểm",
        "thiengs" to "thiếng", "tiepj" to "tiệp", "yeus" to "yếu", "yenr" to "yển",
        "yeets" to "yết", "chuyenj" to "chuyện", "quyets" to "quyết",
        "ddienj" to "điện", "VIETJ" to "VIỆT", "Vietj" to "Việt",
        // ê trước nh, ch, u
        "benhj" to "bệnh", "lechj" to "lệch", "keuf" to "kều", "ddeuf" to "đều",
        // uê
        "hues" to "huế", "thuee" to "thuê", "tuechj" to "tuệch",
        // uâ
        "luanj" to "luận", "xuats" to "xuất", "khuays" to "khuấy", "tuanf" to "tuần",
    )

    @Test fun testAddsTheHat() {
        for ((keys, want) in rows) {
            if (keys == "hues" || keys == "thuee") continue
            assertEquals(keys, want, commit(keys))
            assertEquals("no live check: $keys", want, commit(keys, live = false))
            assertEquals("teencode: $keys", want, commit(keys, teencode = true))
        }
        assertEquals("huế", composed("hues"))
    }

    @Test fun testOffChangesNothing() {
        assertFalse(TelexEngine().autoCircumflex)
        for (keys in listOf("vietj", "viejt", "benhj", "luanj", "keuf", "nguyenx")) {
            val a = TelexEngine().apply { liveSpellCheck = true }
            val b = TelexEngine().apply { liveSpellCheck = true; autoCircumflex = false }
            for (ch in keys) { a.feed(ch); b.feed(ch) }
            assertEquals(a.composed, b.composed)
            assertFalse(keys, a.composed.contains("ệ") || a.composed.contains("ậ") ||
                a.composed.contains("ề") || a.composed.contains("ễ"))
        }
    }

    /** Vần không mũ là vần thật ⇒ không đụng tới. */
    @Test fun testRealPlainRimesStay() {
        val rows = listOf(
            "quanr" to "quản", "quats" to "quát", "quays" to "quáy", "quef" to "què",
            "xengr" to "xẻng", "secs" to "séc", "tenf" to "tèn", "mets" to "mét",
            "hoanf" to "hoàn", "muaf" to "mùa", "kias" to "kía", "theer" to "thể",
            "meof" to "mèo", "khoer" to "khỏe", "giengs" to "giéng",
        )
        for ((keys, want) in rows) assertEquals(keys, nfc(want), nfc(commit(keys)))
    }

    /** Không có thanh (hoặc thanh bị vần tắc loại) ⇒ không thêm mũ. */
    @Test fun testNeedsALiveTone() {
        assertEquals("viet", composed("viet"))
        assertEquals("benh", composed("benh"))
        assertEquals(composed("vietf", on = false), composed("vietf"))
        assertEquals(composed("vietjj", on = false), composed("vietjj"))   // huỷ thanh
    }

    /** Chỉ là bước hiển thị: gõ tiếp, xoá vẫn y như không có tính năng. */
    @Test fun testParseStateUntouched() {
        val e = engine(true)
        for (ch in "vietj") e.feed(ch)
        assertEquals("việt", e.composed)
        e.backspace()                           // ⌫ xoá chữ t, thanh còn ⇒ vần mở "ie" không thêm mũ
        assertEquals("vịe", e.composed)
        e.feed('c')
        assertEquals("việc", e.composed)
        // Người quen tay vẫn gõ đủ "ee": kết quả như cũ.
        assertEquals("việt", commit("vieetj"))
        assertEquals("việt", commit("vieejt"))
        assertEquals("luận", commit("luaanj"))
        // Thanh gõ sớm, mũ hiện khi vần đủ.
        assertEquals(composed("viej", on = false), composed("viej"))
        assertEquals("việt", composed("viejt"))
    }

    /** Phím gốc là từ tiếng Anh ⇒ vẫn trả về phím gốc như trước. */
    @Test fun testEnglishStillRestores() {
        for (w in listOf("clients", "guest", "reuse", "quest", "use")) {
            assertEquals(w, commit(w, on = false), commit(w))
        }
    }

    /** copy() mang theo công tắc (checkpoint của EngineBridge.undoLastLetter). */
    @Test fun testCopyKeepsFlag() {
        val e = engine(true)
        for (ch in "vietj") e.feed(ch)
        val c = e.copy()
        assertEquals("việt", c.composed)
        c.feed('s')
        assertEquals("viết", c.composed)
    }
}
