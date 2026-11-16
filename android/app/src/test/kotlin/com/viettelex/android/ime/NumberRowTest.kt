package com.viettelex.android.ime

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** Hàng phím số tuỳ chọn (27/09/2026): 1…0 trên plane chữ; từ 12/10/2026 phím số = 0.8× phím chữ (không tính khe). */
class NumberRowTest {
    private val d = 1f
    private val W = 390f
    private val H4 = KeyLayout.keyAreaDp(false, false, 0)                    // 224
    private val H5 = KeyLayout.keyAreaDp(false, false, 0, numberRow = true)  // 270.8

    private fun build(plane: Plane, numberRow: Boolean, h: Float = if (numberRow) H5 else H4) =
        KeyLayout.build(LayoutConfig(plane, W, h, d, numberRow = numberRow))

    private fun near(a: Float, b: Float, eps: Float = 0.01f) = assertEquals(b, a, eps)

    @Test fun heightAddsNumberRowOfPointEightKeys() {
        // khe 10 + phím 0.8 × 46
        near(H5, 224f + 10f + 0.8f * 46f)
        near(KeyLayout.keyAreaDp(true, true, 0, numberRow = true), 300f + 10f + 0.8f * (75f - 10f))
        near(KeyLayout.keyAreaDp(false, true, 0, numberRow = true), 168f + 10f + 0.8f * (42f - 10f))
        // chỉnh ±dp mỗi hàng: hàng số ăn 0.8 phần (phím), khe giữ nguyên
        near(KeyLayout.keyAreaDp(false, false, 5, numberRow = true), 244f + 10f + 0.8f * 51f)
        near(KeyLayout.rowUnit(H5, true, 1f), 56f)
        near(KeyLayout.rowUnit(H4, false, 1f), 56f)
    }

    /** Chữ cài đặt "+N dp cả bàn phím": 4 hàng chữ + 0.8 phần hàng số. */
    @Test fun adjustTotalCountsNumberRow() {
        assertEquals(0, KeyLayout.adjustTotalDp(0, true))
        assertEquals(20, KeyLayout.adjustTotalDp(5, false))
        assertEquals(24, KeyLayout.adjustTotalDp(5, true))
        assertEquals(-48, KeyLayout.adjustTotalDp(-10, true))
        assertEquals(-40, KeyLayout.adjustTotalDp(-99, false))   // kẹp −10
    }

    /**
     * Mọi cỡ: điện thoại/tablet × dọc/ngang × chỉnh hàng × mật độ × bề ngang × một tay —
     * phím số = 0.8 phím chữ, hàng chữ cao y như khi tắt hàng số, hàng đáy chạm đáy, và
     * rowUnit là nghịch đảo đúng của keyAreaDp (ở px).
     */
    @Test fun ratioHoldsAcrossSizes() {
        for (tablet in listOf(false, true)) for (land in listOf(false, true)) for (adj in listOf(-10, 0, 7))
        for (dens in listOf(1f, 2.75f)) for (w in listOf(320f, 390f, 600f, 900f))
        for (side in listOf(OneHandSide.OFF, OneHandSide.LEFT)) {
            if (tablet && side != OneHandSide.OFF) continue
            val tag = "tablet=$tablet land=$land adj=$adj d=$dens w=$w $side"
            val off = KeyLayout.keyAreaDp(tablet, land, adj) * dens
            val on = KeyLayout.keyAreaDp(tablet, land, adj, numberRow = true) * dens
            assertEquals(tag, off / 4f, KeyLayout.rowUnit(on, true, dens), 0.01f)
            val keys = KeyLayout.build(LayoutConfig(Plane.LETTERS, w * dens, on, dens, tablet = tablet,
                numberRow = true, oneHand = side))
            val ref = KeyLayout.build(LayoutConfig(Plane.LETTERS, w * dens, off, dens, tablet = tablet, oneHand = side))
            val one = keys.first { it.label == "1" }
            val q = keys.first { it.label == "q" }
            assertEquals(tag, 0.8f, one.height / q.height, 0.001f)
            assertEquals(tag, ref.first { it.label == "q" }.height, q.height, 0.01f)
            // khe giữa hàng số và hàng q = khe chuẩn
            assertEquals(tag, KeyLayout.ROW_GAP * dens, q.top - one.bottom, 0.01f)
            assertEquals(tag, on - KeyLayout.BOTTOM_ROW_BOTTOM * dens, keys.first { it.kind == KeyKind.SPACE }.bottom, 0.05f)
        }
    }

    /** Plane tìm emoji (chữ đầy đủ dưới ô tìm) giữ cùng tỉ lệ. */
    @Test fun emojiSearchKeepsRatio() {
        val keys = KeyLayout.build(LayoutConfig(Plane.EMOJI_SEARCH, W, H5, d, numberRow = true))
        val one = keys.first { it.label == "1" }
        val q = keys.first { it.label == "q" }
        near(one.height / q.height, 0.8f, 0.001f)
    }

    @Test fun offIsUnchanged() {
        val a = build(Plane.LETTERS, false)
        assertTrue(a.none { it.kind == KeyKind.CHAR })
        val q = a.first { it.label == "q" }
        near(q.top, KeyLayout.ROW_MARGIN_V)
    }

    @Test fun lettersPlaneGetsShortNumberRow() {
        val keys = build(Plane.LETTERS, true)
        val digits = keys.filter { it.kind == KeyKind.CHAR }
        assertEquals(listOf("1", "2", "3", "4", "5", "6", "7", "8", "9", "0"), digits.map { it.label })
        val nr = 10f + 0.8f * 46f   // hàng số (khe + phím)
        val m = KeyLayout.ROW_MARGIN_V
        // hàng số: [0, nr], phím = hàng − 2 margin = 0.8 × phím chữ 46
        near(digits[0].top, m); near(digits[0].bottom, nr - m); near(digits[0].height, 0.8f * 46f)
        // hàng chữ: đúng cao như khi tắt, chỉ dời xuống nr
        val off = build(Plane.LETTERS, false)
        for (k in off) {
            val on = keys.first { it.kind == k.kind && it.label == k.label && it.insert == k.insert }
            near(on.top, k.top + nr, 0.05f); near(on.height, k.height, 0.05f)
            near(on.left, k.left); near(on.width, k.width)
        }
        // 1 thẳng cột q, cùng bề rộng
        val q = keys.first { it.label == "q" }
        near(digits[0].left, q.left); near(digits[0].width, q.width)
        // hàng đáy chạm đáy vùng phím
        val space = keys.first { it.kind == KeyKind.SPACE }
        near(space.bottom, H5 - KeyLayout.BOTTOM_ROW_BOTTOM, 0.05f)
    }

    @Test fun digitsHitAsCharNotLetter() {
        val keys = build(Plane.LETTERS, true)
        val seven = keys.first { it.label == "7" }
        val hit = KeyLayout.hit(keys, Plane.LETTERS, seven.centerX, seven.centerY, 4f, d)
        assertEquals("7", hit?.label); assertEquals(KeyKind.CHAR, hit?.kind)
        // giữa chữ u (hàng dưới) vẫn ra u
        val u = keys.first { it.label == "u" }
        assertEquals("u", KeyLayout.hit(keys, Plane.LETTERS, u.centerX, u.centerY, 4f, d)?.label)
        // khe giữa hàng số và hàng q: không mất chạm
        val gapY = (seven.bottom + u.top) / 2
        assertTrue(KeyLayout.hit(keys, Plane.LETTERS, seven.centerX, gapY, 4f, d) != null)
    }

    /** Tắt hàng số: plane 123 vẫn 4 hàng đều như cũ. */
    @Test fun numbersPlaneWithoutNumberRowUnchanged() {
        val keys = build(Plane.NUMBERS, false)
        val one = keys.first { it.label == "1" }
        near(one.top, KeyLayout.ROW_MARGIN_V); near(one.bottom, H4 / 4f - KeyLayout.ROW_MARGIN_V)
        assertEquals(KeyLayout.symbolicRows(true, false), listOf(KeyLayout.NUM1, KeyLayout.NUM2))
        assertEquals(KeyLayout.symbolicRows(false, false), listOf(KeyLayout.SYM1, KeyLayout.SYM2))
    }

    /** Dải dọc (top, bottom) của từng hàng phím trong một plane. */
    private fun rowBands(keys: List<LaidKey>) =
        keys.map { Math.round(it.top * 100) to Math.round(it.bottom * 100) }.distinct().sortedBy { it.first }

    /**
     * Field report 18/10/2026 ("hàng phím số khi bấm shift lại bị mất dẫn đến hụt hàng… khoảng cách
     * các phím ko cân đối khi chuyển dễ bị bấm nhầm"): bật hàng số, chuyển ABC ↔ 123 ↔ #+= phải giữ
     * ĐÚNG 5 hàng cùng dải dọc, hàng 1…0 đứng yên (cùng khung), phím hàng 3 / hàng đáy không nhảy dọc.
     * Trước đây ?123 = 4 hàng giãn cả vùng ⇒ "1" cao ~1,2×, mọi hàng dời.
     */
    @Test fun numbersAndSymbolsPlanesKeepLettersRowGeometry() {
        for (full in listOf(false, true)) for (tablet in listOf(false, true)) for (dens in listOf(1f, 2.75f))
        for (side in listOf(OneHandSide.OFF, OneHandSide.RIGHT)) {
            if (tablet && side != OneHandSide.OFF) continue
            val tag = "full=$full tablet=$tablet d=$dens $side"
            val h = KeyLayout.keyAreaDp(tablet, false, 0, numberRow = true, numberRowFull = full) * dens
            fun b(p: Plane) = KeyLayout.build(LayoutConfig(p, W * dens, h, dens, tablet = tablet,
                numberRow = true, numberRowFull = full, oneHand = side))
            val letters = b(Plane.LETTERS)
            val bands = rowBands(letters)
            assertEquals(tag, 5, bands.size)
            val digits = letters.filter { it.label in KeyLayout.NUM1 && it.kind == KeyKind.CHAR }
            assertEquals(tag, 10, digits.size)
            for (p in listOf(Plane.NUMBERS, Plane.SYMBOLS)) {
                val keys = b(p)
                assertEquals("$tag $p", bands, rowBands(keys))
                for (dk in digits) {
                    val o = keys.single { it.label == dk.label }
                    near(o.left, dk.left); near(o.top, dk.top); near(o.right, dk.right); near(o.bottom, dk.bottom)
                }
                // ⌫ / hàng đáy cùng chỗ như plane chữ (ngón đã quen vị trí).
                for (kind in listOf(KeyKind.BACKSPACE, KeyKind.SPACE, KeyKind.RETURN)) {
                    val a = letters.first { it.kind == kind }; val o = keys.first { it.kind == kind }
                    near(o.top, a.top, 0.05f); near(o.bottom, a.bottom, 0.05f)
                }
                // Phím ký tự đúng bộ iOS: 3 hàng [KeyLayout.symbolicRows] + hàng 3 ". , ? ! '" (#165).
                val chars = keys.filter { it.kind == KeyKind.CHAR }.map { it.insert }
                assertEquals("$tag $p", KeyLayout.symbolicRows(p == Plane.NUMBERS, true).flatten() + KeyLayout.THIRD, chars)
            }
        }
    }

    /** Shift không bao giờ đổi hàng số: phím số có nhãn hoa = nhãn thường (không thành !@#), và
     *  KeyLayout.build không phụ thuộc shift ⇒ khung phím y hệt ở mọi trạng thái Shift. */
    @Test fun shiftNeverChangesNumberRow() {
        for (p in listOf(Plane.LETTERS, Plane.NUMBERS, Plane.SYMBOLS))
            for (k in build(p, true).filter { it.label in KeyLayout.NUM1 })
                assertEquals(k.label, k.upper)
    }

    /**
     * #142 (cùng iOS): bật hàng số, plane 123 giữ thứ tự hàng như khi tắt / bàn phím gốc — hàng
     * - / : ; ( ) $ & @ " nằm NGAY TRÊN hàng 3 (thứ 3 từ dưới lên, sát trên hàng ". , ? ! '"),
     * hàng ký hiệu mượn thêm ([ ] { } …) nằm ngay dưới hàng số. Cả bàn tách đôi.
     */
    @Test fun numbersPlaneKeepsStockRowOrder() {
        assertEquals(listOf(KeyLayout.NUM1, KeyLayout.SYM1, KeyLayout.NUM2), KeyLayout.symbolicRows(true, true))
        for ((w, split) in listOf(W to false, 801f to true)) {
            val h = KeyLayout.keyAreaDp(false, split, 0, numberRow = true)
            val keys = KeyLayout.build(LayoutConfig(Plane.NUMBERS, w, h, d, numberRow = true, split = split))
            val rows = keys.groupBy { Math.round(it.top * 100) }.toSortedMap().values
                .map { r -> r.sortedBy { it.left }.filter { it.kind == KeyKind.CHAR }.map { it.label } }
            assertEquals("split=$split", 5, rows.size)
            assertEquals("split=$split", KeyLayout.NUM1, rows[0])
            assertEquals("split=$split", KeyLayout.SYM1, rows[1])
            assertEquals("split=$split thứ 3 từ dưới", KeyLayout.NUM2, rows[2])
            assertEquals("split=$split", KeyLayout.THIRD, rows[3])
            // Tắt hàng số: NUM2 cũng là hàng thứ 3 từ dưới.
            val off = KeyLayout.build(LayoutConfig(Plane.NUMBERS, w, KeyLayout.keyAreaDp(false, split, 0), d, split = split))
            val offRows = off.groupBy { Math.round(it.top * 100) }.toSortedMap().values.toList()
            assertEquals(KeyLayout.NUM2, offRows[offRows.size - 3].sortedBy { it.left }.map { it.label })
        }
    }

    @Test fun symbolicRowsWithNumberRow() {
        val all = (KeyLayout.NUM1 + KeyLayout.NUM2 + KeyLayout.SYM1 + KeyLayout.SYM2 + KeyLayout.THIRD).toSet()
        val on = mutableSetOf<String>()
        for (num in listOf(true, false)) {
            val rows = KeyLayout.symbolicRows(num, true)
            assertEquals(3, rows.size)
            assertEquals(KeyLayout.NUM1, rows[0])
            rows.forEach { assertEquals(10, it.size) }
            on += rows.flatten() + KeyLayout.THIRD
        }
        assertEquals("không mất ký tự nào so với 4 hàng", all, on)
    }

    /** #165: luật bật hàng số = iOS phoneSymbolicRows (đọc thẳng file Swift), cả 4 tổ hợp. */
    @Test fun symbolicRowsMatchIosRule() {
        val named = mapOf("digits" to KeyLayout.NUM1,
            "phoneNumberRows[0]" to IosPlanes.numberRows[0], "phoneNumberRows[1]" to IosPlanes.numberRows[1],
            "phoneSymbolRows[0]" to IosPlanes.symbolRows[0], "phoneSymbolRows[1]" to IosPlanes.symbolRows[1])
        val (numOn, symOn) = IosPlanes.numberRowRuleSource
        assertEquals(numOn.map { named.getValue(it) }, KeyLayout.symbolicRows(true, true))
        assertEquals(symOn.map { named.getValue(it) }, KeyLayout.symbolicRows(false, true))
        assertEquals(IosPlanes.numberRows, KeyLayout.symbolicRows(true, false))
        assertEquals(IosPlanes.symbolRows, KeyLayout.symbolicRows(false, false))
        // Bật hàng số: plane 123 có cả "=" lẫn "$" là phím gốc như iOS.
        assertTrue(KeyLayout.symbolicRows(true, true).flatten().containsAll(listOf("=", "\$")))
    }

    @Test fun templatesBottomRowIsOneStandardRow() {
        val keys = build(Plane.TEMPLATES, true)
        val space = keys.first { it.kind == KeyKind.SPACE }
        near(space.top, H5 - 56f + KeyLayout.BOTTOM_ROW_TOP, 0.05f)
    }

    /** "Hàng số cao bằng hàng chữ" (tuỳ chọn, mặc định tắt): bàn phím = đúng 5 hàng chuẩn. */
    @Test fun fullHeightNumberRowIsOneLetterRow() {
        near(KeyLayout.keyAreaDp(false, false, 0, numberRow = true, numberRowFull = true), 5 * 56f)
        near(KeyLayout.keyAreaDp(true, true, 0, numberRow = true, numberRowFull = true), 300f * 5 / 4)
        // chỉnh hàng: cả 5 hàng ăn ±dp
        near(KeyLayout.keyAreaDp(false, false, 5, numberRow = true, numberRowFull = true), 5 * 61f)
        assertEquals(25, KeyLayout.adjustTotalDp(5, true, numberRowFull = true))
        assertEquals(24, KeyLayout.adjustTotalDp(5, true, numberRowFull = false))
        // tắt hàng số ⇒ cờ full vô hiệu (không tốn gì)
        near(KeyLayout.keyAreaDp(false, false, 0, numberRow = false, numberRowFull = true), H4)
        near(KeyLayout.rowUnit(H4, false, 1f, numberRowFull = true), 56f)
        // mặc định (0.8×) không đổi
        near(KeyLayout.keyAreaDp(false, false, 0, numberRow = true, numberRowFull = false), H5)
    }

    @Test fun fullHeightRatioHoldsAcrossSizes() {
        for (tablet in listOf(false, true)) for (land in listOf(false, true)) for (adj in listOf(-10, 0, 7))
        for (dens in listOf(1f, 2.75f)) for (w in listOf(320f, 390f, 900f))
        for (side in listOf(OneHandSide.OFF, OneHandSide.LEFT)) {
            if (tablet && side != OneHandSide.OFF) continue
            val tag = "tablet=$tablet land=$land adj=$adj d=$dens w=$w $side"
            val off = KeyLayout.keyAreaDp(tablet, land, adj) * dens
            val on = KeyLayout.keyAreaDp(tablet, land, adj, numberRow = true, numberRowFull = true) * dens
            near(on, off * 5f / 4f, 0.01f)
            assertEquals(tag, off / 4f, KeyLayout.rowUnit(on, true, dens, numberRowFull = true), 0.01f)
            val keys = KeyLayout.build(LayoutConfig(Plane.LETTERS, w * dens, on, dens, tablet = tablet,
                numberRow = true, numberRowFull = true, oneHand = side))
            val ref = KeyLayout.build(LayoutConfig(Plane.LETTERS, w * dens, off, dens, tablet = tablet, oneHand = side))
            val one = keys.first { it.label == "1" }
            val q = keys.first { it.label == "q" }
            assertEquals(tag, q.height, one.height, 0.01f)
            assertEquals(tag, ref.first { it.label == "q" }.height, q.height, 0.01f)
            assertEquals(tag, KeyLayout.ROW_GAP * dens, q.top - one.bottom, 0.01f)
            assertEquals(tag, on - KeyLayout.BOTTOM_ROW_BOTTOM * dens, keys.first { it.kind == KeyKind.SPACE }.bottom, 0.05f)
        }
    }

    /** Plane 123 / tìm emoji / mẫu câu với hàng số đủ cao: 123 = 5 hàng bằng nhau như plane chữ, emoji tìm giữ tỉ lệ 1:1, mẫu câu hàng đáy = 1 hàng. */
    @Test fun fullHeightOtherPlanes() {
        val h = KeyLayout.keyAreaDp(false, false, 0, numberRow = true, numberRowFull = true)   // 280
        fun b(p: Plane) = KeyLayout.build(LayoutConfig(p, W, h, d, numberRow = true, numberRowFull = true))
        val one = b(Plane.NUMBERS).first { it.label == "1" }
        near(one.bottom, h / 5f - KeyLayout.ROW_MARGIN_V)
        val search = b(Plane.EMOJI_SEARCH)
        near(search.first { it.label == "1" }.height, search.first { it.label == "q" }.height)
        near(b(Plane.TEMPLATES).first { it.kind == KeyKind.SPACE }.top, h - 56f + KeyLayout.BOTTOM_ROW_TOP, 0.05f)
    }

    /** Gõ vuốt lấy tâm a–z: vẫn đủ 26 chữ, bước phím như cũ. */
    @Test fun swipeCentersStillLetters() {
        val keys = build(Plane.LETTERS, true)
        val letters = keys.filter { it.kind == KeyKind.LETTER }
        assertEquals(26, letters.size)
        val off = build(Plane.LETTERS, false).filter { it.kind == KeyKind.LETTER }
        near(letters.first { it.label == "w" }.centerX - letters.first { it.label == "q" }.centerX,
            off.first { it.label == "w" }.centerX - off.first { it.label == "q" }.centerX)
    }
}
