package com.viettelex.android.ime

import com.viettelex.keyboard.SpaceSideKey
import com.viettelex.keyboard.SplitLayout
import com.viettelex.keyboard.TouchGeometry
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Bàn phím tách đôi (Settings → Giao diện, mặc định TẮT) — dựng phím + router, song sinh iOS
 * SplitKeyboardTests (phần "View thật"): G/V lặp, khe giữa chết, một tay bỏ qua, plane 123 tách,
 * TẮT / máy hẹp = y hệt bàn phím cũ.
 */
class SplitKeyboardTest {
    private val W = 801f      // iPhone gập mở (stock đo) ≈ Pixel Fold / Z Fold mở ngang

    private fun cfg(plane: Plane = Plane.LETTERS, w: Float = W, d: Float = 1f, split: Boolean = true,
                    numberRow: Boolean = false, tablet: Boolean = false, kind: InputKind = InputKind.NORMAL,
                    oneHand: OneHandSide = OneHandSide.OFF, needsGlobe: Boolean = false,
                    emojiInStrip: Boolean = false, side: SpaceSideKey = SpaceSideKey.DEFAULT) =
        LayoutConfig(plane, w, d * KeyLayout.keyAreaDp(tablet, true, 0, numberRow), d, kind,
            needsGlobe = needsGlobe, tablet = tablet, numberRow = numberRow, oneHand = oneHand,
            emojiInStrip = emojiInStrip, spaceSideKey = side, split = split)

    private fun letters(keys: List<LaidKey>, s: String) = keys.filter { it.kind == KeyKind.LETTER && it.label == s }
    private fun letter(keys: List<LaidKey>, s: String) = letters(keys, s).first()
    private fun near(exp: Float, act: Float, eps: Float = 0.5f) = assertEquals(exp, act, eps)

    @Test fun activeOnlyWhenWideInDp() {
        assertTrue(KeyLayout.splitActive(cfg()))
        assertFalse(KeyLayout.splitActive(cfg(split = false)))
        assertFalse(KeyLayout.splitActive(cfg(w = 411f)))
        // Ngưỡng theo dp, không theo px: 700 dp ở density 2.625 tách, 500 dp thì không.
        assertTrue(KeyLayout.splitActive(true, 700f * 2.625f, 2.625f))
        assertFalse(KeyLayout.splitActive(true, 500f * 2.625f, 2.625f))
        assertFalse(KeyLayout.splitActive(true, 1000f, 0f))
    }

    @Test fun splitGeometry() {
        for (d in listOf(1f, 2.625f)) {
            val c = cfg(w = W * d, d = d)
            val keys = KeyLayout.build(c)
            assertEquals("26 chữ + G, V lặp", 28, keys.count { it.kind == KeyKind.LETTER })
            val m = KeyLayout.splitMetrics(c)
            val margin = KeyLayout.ROW_MARGIN_H * d
            val q = letter(keys, "q"); val t = letter(keys, "t"); val y = letter(keys, "y"); val p = letter(keys, "p")
            near(m.keyWidth, q.width)
            near(margin, q.left)
            near(W * d - margin, p.right)
            assertTrue("khe giữa", y.left - t.right > 2 * m.pitch)
            // Hàng 2 nửa trái thụt nửa phím: A dưới khe Q/W; nửa phải G ngay mép nửa.
            near(q.left + m.pitch / 2, letter(keys, "a").left)
            near(W * d - margin - m.half, letters(keys, "g").last().left)
            // Hàng 3: ⇧ ở mép trái, ⌫ ở mép phải, M chạm ⌫ đúng một khe.
            val shift = keys.single { it.kind == KeyKind.SHIFT }
            val back = keys.single { it.kind == KeyKind.BACKSPACE }
            near(margin, shift.left); near(W * d - margin, back.right)
            near(KeyLayout.KEY_SPACING * d, back.left - letter(keys, "m").right)
            // Mọi phím (kể cả hàng đáy) cao bằng phím chữ.
            for (k in keys) near(q.height, k.height, 0.5f * d)
            val ret = keys.single { it.kind == KeyKind.RETURN }
            near(W * d - margin, ret.right)
            // Không phím nào lấn vào khe giữa / chồng nhau.
            assertNoOverlapOrGapIntrusion(keys, c)
        }
    }

    private fun assertNoOverlapOrGapIntrusion(keys: List<LaidKey>, c: LayoutConfig) {
        val m = KeyLayout.splitMetrics(c)
        val margin = KeyLayout.ROW_MARGIN_H * c.density
        val lEnd = margin + m.half; val rStart = c.widthPx - margin - m.half
        for (k in keys) {
            assertTrue("$k trong một nửa", k.right <= lEnd + 0.01f || k.left >= rStart - 0.01f)
            assertTrue("$k không tràn", k.left >= margin - 0.01f && k.right <= c.widthPx - margin + 0.01f)
            assertTrue("$k rộng > 0", k.width > 0f)
        }
        for (i in keys.indices) for (j in i + 1 until keys.size) {
            val a = keys[i]; val b = keys[j]
            val overlap = a.left < b.right - 0.01f && b.left < a.right - 0.01f &&
                a.top < b.bottom - 0.01f && b.top < a.bottom - 0.01f
            assertFalse("$a chồng $b", overlap)
        }
    }

    /** Chạm: G hai nửa đều ra "g"; khe giữa không ra phím nào; mép phím vẫn nhận phím gần nhất. */
    @Test fun touchesInSplit() {
        val keys = KeyLayout.build(cfg())
        val y0 = TouchGeometry.yOffset
        val gs = letters(keys, "g")
        assertEquals(2, gs.size)
        for (g in gs) assertEquals("g", KeyLayout.hit(keys, Plane.LETTERS, g.centerX, g.centerY + y0, y0, 1f)?.label)
        val t = letter(keys, "t"); val y = letter(keys, "y")
        assertNull("khe giữa là vùng chết như Apple",
            KeyLayout.hit(keys, Plane.LETTERS, (t.right + y.left) / 2, t.centerY, y0, 1f))
        assertEquals("t", KeyLayout.hit(keys, Plane.LETTERS, t.right + 5f, t.centerY + y0, y0, 1f)?.label)
        // Khe giữa hàng đáy: không phím nào.
        val ret = keys.single { it.kind == KeyKind.RETURN }
        assertNull(KeyLayout.hit(keys, Plane.LETTERS, W / 2, ret.centerY, y0, 1f))
        // Hai phím cách cùng gõ dấu cách; phím phải (sau cùng) là phím chính (logo).
        val spaces = keys.filter { it.kind == KeyKind.SPACE }
        assertEquals(2, spaces.size)
        assertTrue(spaces[0].right < W / 2 && spaces[1].left > W / 2)
        for (s in spaces) assertEquals(KeyKind.SPACE, KeyLayout.hit(keys, Plane.LETTERS, s.centerX, s.centerY, y0, 1f)?.kind)
        // Plane số: khe giữa cũng chết.
        val nk = KeyLayout.build(cfg(Plane.NUMBERS))
        val five = nk.single { it.label == "5" }
        assertNull(KeyLayout.hit(nk, Plane.NUMBERS, W / 2, five.centerY, y0, 1f))
    }

    @Test fun oneHandIgnoredWhenSplit() {
        for (side in listOf(OneHandSide.LEFT, OneHandSide.RIGHT)) {
            val keys = KeyLayout.build(cfg(oneHand = side))
            near(KeyLayout.ROW_MARGIN_H, letter(keys, "q").left)
            near(W - KeyLayout.ROW_MARGIN_H, letter(keys, "p").right)
        }
    }

    @Test fun numberAndSymbolPlanesSplit() {
        for (numberRow in listOf(false, true)) {
            val c = cfg(Plane.NUMBERS, numberRow = numberRow)
            val keys = KeyLayout.build(c)
            val five = keys.single { it.label == "5" }; val six = keys.single { it.label == "6" }
            assertTrue(six.left - five.right > 100f)
            assertNotNull(keys.singleOrNull { it.kind == KeyKind.MORE && it.label == "#+=" })
            assertNotNull(keys.singleOrNull { it.kind == KeyKind.BACKSPACE })
            assertNotNull(keys.singleOrNull { it.kind == KeyKind.PLANE && it.label == "ABC" })
            // "," "." ở hàng 3 (như iOS) + hàng đáy — không mất khi tách.
            assertEquals(2, keys.count { it.label == "," }); assertEquals(2, keys.count { it.label == "." })
            // Hàng 3 như iOS buildSplitPlane: [#+=] . , | ? ! ' [⌫]; ký tự đúng cột hai hàng trên.
            val r3 = keys.filter { it.top == keys.single { k -> k.kind == KeyKind.MORE }.top }.sortedBy { it.left }
            assertEquals(listOf("#+=", ".", ",", "?", "!", "'", ""), r3.map { it.label })
            val above = keys.filter { it.kind == KeyKind.CHAR && it.top < r3[0].top }
            for (k in r3.subList(1, 6)) assertTrue(k.label, above.any { Math.abs(it.left - k.left) < 0.01f && Math.abs(it.right - k.right) < 0.01f })
            val half = KeyLayout.splitMetrics(c).half
            assertTrue(r3[2].right < KeyLayout.ROW_MARGIN_H + half + 0.01f)
            assertTrue(r3[3].left > W - KeyLayout.ROW_MARGIN_H - half - 0.01f)
            // Không mất / lặp ký tự nào so với bản không tách.
            val plain = KeyLayout.build(c.copy(split = false))
            assertEquals(plain.filter { it.kind == KeyKind.CHAR }.map { it.label }.sorted(),
                keys.filter { it.kind == KeyKind.CHAR }.map { it.label }.sorted())
            // Hàng giữ đúng toạ độ dọc như bản không tách (hàng số / hàng đáy không nhảy khi bật).
            assertEquals(plain.map { it.top }.toSet(), keys.map { it.top }.toSet())
            assertNoOverlapOrGapIntrusion(keys, c)
            val sym = KeyLayout.build(c.copy(plane = Plane.SYMBOLS))
            assertNotNull(sym.singleOrNull { it.kind == KeyKind.MORE && it.label == "123" })
            assertNoOverlapOrGapIntrusion(sym, c.copy(plane = Plane.SYMBOLS))
        }
    }

    @Test fun numberRowOnLettersSplits() {
        val c = cfg(numberRow = true)
        val keys = KeyLayout.build(c)
        val digits = keys.filter { it.kind == KeyKind.CHAR && it.label.length == 1 && it.label[0].isDigit() }
        assertEquals(10, digits.size)
        assertTrue(keys.single { it.label == "6" }.left - keys.single { it.label == "5" }.right > 100f)
        val plain = KeyLayout.build(c.copy(split = false))
        assertEquals("cùng các hàng như bản không tách", plain.map { it.top }.toSet(), keys.map { it.top }.toSet())
        assertNoOverlapOrGapIntrusion(keys, c)
    }

    /** Hàng đáy: dấu câu theo loại ô / "Phím cạnh dấu cách"; 😊 lên thanh; 🌐; máy tính bảng có nút ẩn. */
    @Test fun bottomRowVariants() {
        fun puncts(c: LayoutConfig) = KeyLayout.build(c).filter { it.kind == KeyKind.PUNCT }.map { it.label }
        assertEquals(listOf(","), puncts(cfg()))
        assertEquals(listOf("."), puncts(cfg(side = SpaceSideKey.PERIOD)))
        assertEquals(listOf(",", "."), puncts(cfg(side = SpaceSideKey.BOTH)))
        assertEquals(emptyList<String>(), puncts(cfg(side = SpaceSideKey.OFF)))
        assertEquals(listOf("@", "."), puncts(cfg(kind = InputKind.EMAIL)))
        assertEquals(listOf("/", "."), puncts(cfg(kind = InputKind.URL)))
        assertEquals(SpaceSideKey.PERIOD, KeyLayout.sideKey(cfg(tablet = true, side = SpaceSideKey.PERIOD)))
        val strip = KeyLayout.build(cfg(emojiInStrip = true))
        assertEquals(0, strip.count { it.kind == KeyKind.EMOJI })
        val full = KeyLayout.build(cfg(needsGlobe = true, tablet = true, kind = InputKind.EMAIL, w = 1194f))
        assertEquals(1, full.count { it.kind == KeyKind.GLOBE })
        assertEquals(1, full.count { it.kind == KeyKind.DISMISS })
        for (s in full.filter { it.kind == KeyKind.SPACE }) assertTrue("$s", s.width > 0.5f * KeyLayout.splitMetrics(cfg(w = 1194f)).keyWidth)
        assertNoOverlapOrGapIntrusion(full, cfg(w = 1194f, tablet = true))
        // Bề ngang tối thiểu + 🌐 + ô email: phím cách vẫn còn chỗ.
        val tight = KeyLayout.build(cfg(w = 600f, needsGlobe = true, kind = InputKind.EMAIL))
        assertNoOverlapOrGapIntrusion(tight, cfg(w = 600f))
    }

    /** Công tắc TẮT (mặc định) hoặc máy hẹp: bố cục y hệt bàn phím không có tính năng này. */
    @Test fun offOrNarrowIsUnchanged() {
        for (plane in listOf(Plane.LETTERS, Plane.NUMBERS, Plane.SYMBOLS)) {
            val off = KeyLayout.build(cfg(plane, split = false))
            assertEquals(if (plane == Plane.LETTERS) 26 else 0, off.count { it.kind == KeyKind.LETTER })
            assertEquals(1, off.count { it.kind == KeyKind.SPACE })
            val narrow = KeyLayout.build(cfg(plane, w = 402f))
            val plain = KeyLayout.build(cfg(plane, w = 402f, split = false))
            assertEquals(plain.toString(), narrow.toString())
        }
        // Một tay vẫn chạy khi máy hẹp dù công tắc bật.
        val oh = KeyLayout.build(cfg(w = 402f, oneHand = OneHandSide.RIGHT))
        assertTrue(letter(oh, "q").left > 402f * (1 - OneHand.RATIO) - 1f)
    }

    /** Emoji, mẫu câu, tìm emoji, bảng sửa, bàn số: giữ đầy bề ngang như iOS. */
    @Test fun otherPlanesFullWidth() {
        for (plane in listOf(Plane.TEMPLATES, Plane.EMOJI_SEARCH, Plane.EDIT, Plane.PHONE, Plane.NUMPAD)) {
            assertEquals("$plane", KeyLayout.build(cfg(plane, split = false)).toString(),
                KeyLayout.build(cfg(plane)).toString())
        }
        assertEquals(26, KeyLayout.build(cfg(Plane.EMOJI_SEARCH)).count { it.kind == KeyKind.LETTER })
    }

    /** Xoay / gập-mở: cùng công tắc, bề ngang qua ngưỡng ⇒ vào / ra kiểu tách (view dựng lại theo bề ngang). */
    @Test fun widthChangeTogglesSplit() {
        assertEquals(26, KeyLayout.build(cfg(w = 466f)).count { it.kind == KeyKind.LETTER })
        val wide = KeyLayout.build(cfg(w = 801f))
        assertEquals(28, wide.count { it.kind == KeyKind.LETTER })
        near(801f - KeyLayout.ROW_MARGIN_H, letter(wide, "p").right)
        assertEquals(SplitLayout.MIN_WIDTH_DP, 600f, 0f)
    }
}
