package com.viettelex.android.ime

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import com.viettelex.keyboard.SpaceSideKey
import com.viettelex.keyboard.EmojiKeyPlacement
import com.viettelex.keyboard.KeyLabelSize
import com.viettelex.keyboard.KeyboardSettings
import org.junit.Assert.assertFalse

class KeyLayoutTest {
    private val d = 1f   // dp = px
    private val W = 390f
    private val H = 218f

    private fun build(plane: Plane, kind: InputKind = InputKind.NORMAL, globe: Boolean = false, tablet: Boolean = false,
                      ret: String = "return") =
        KeyLayout.build(LayoutConfig(plane, W, H, d, kind, globe, tablet, ret))

    private fun near(a: Float, b: Float, eps: Float = 0.01f) = assertEquals(b, a, eps)

    @Test fun heights() {
        // Gboard: 4 hàng × 56 dp dọc, 42 ngang
        near(KeyLayout.keyAreaDp(false, false, 0), 224f)
        near(KeyLayout.keyAreaDp(false, true, 0), 168f)
        near(KeyLayout.keyAreaDp(true, false, 0), 256f)
        near(KeyLayout.keyAreaDp(true, true, 0), 300f)
        near(KeyLayout.keyAreaDp(false, false, 10), 264f)
        near(KeyLayout.keyAreaDp(false, false, -99), 184f)       // kẹp −10
        near(KeyLayout.keyAreaDp(false, false, 18), 296f)        // trần mới +18 (16/10/2026)
        near(KeyLayout.keyAreaDp(false, false, 99), 296f)        // kẹp +18
        near(KeyLayout.stripDp(true, false), 42f)   // #112: tỉ lệ Gboard
        near(KeyLayout.stripDp(true, true), 14f)
        near(KeyLayout.stripDp(false, false), 0f)
        // Dải giữ theo công tắc toàn cục: ô mật khẩu/URL (không gợi ý) cao bằng ô thường (port iOS e72ae43).
        for (collapsed in listOf(false, true)) {
            val normal = KeyLayout.stripDp(KeyLayout.stripReserved(true), collapsed)
            val noSuggestField = KeyLayout.stripDp(KeyLayout.stripReserved(showSuggestionsSetting = true), collapsed)
            near(noSuggestField, normal)
            near(normal, if (collapsed) 14f else 42f)
        }
        near(KeyLayout.stripDp(KeyLayout.stripReserved(false), false), 0f)
    }

    /**
     * "Chiều cao thanh gợi ý": strip mở theo mức, tổng bàn phím (ImeInsets.totalHeight) tăng ĐÚNG phần
     * chênh strip; vùng phím, thu gọn (14) và tắt (0) giữ nguyên. Vừa = 42 dp như trước.
     */
    @Test fun suggestionBarHeightOnlyChangesOpenStrip() {
        val keys = KeyLayout.keyAreaDp(false, false, 0)
        val base = ImeInsets.totalHeight(KeyLayout.stripDp(true, false).toInt(), keys.toInt(), 0)
        near(KeyLayout.stripDp(true, false, com.viettelex.keyboard.SuggestionBarHeight.DEFAULT.openStripDp), 42f)
        for (h in com.viettelex.keyboard.SuggestionBarHeight.entries) {
            val open = h.openStripDp(landscapeCap = false)
            val total = ImeInsets.totalHeight(KeyLayout.stripDp(true, false, open).toInt(), keys.toInt(), 0)
            assertEquals("$h", base + (open - KeyLayout.OPEN_STRIP).toInt(), total)
            near(KeyLayout.stripDp(true, true, open), 14f)
            near(KeyLayout.stripDp(false, false, open), 0f)
            near(KeyLayout.keyAreaDp(false, false, 0), keys)
        }
    }

    @Test fun emojiSearchIsLettersBelowHeader() {
        // Ô tìm emoji: hàng trên 1/5 trống cho EmojiSearchBar, plane chữ đủ phím bên dưới.
        val head = KeyLayout.searchHeaderPx(H)
        near(head, H / 5f)
        val keys = build(Plane.EMOJI_SEARCH)
        val letters = build(Plane.LETTERS)
        assertEquals(letters.map { it.kind to it.label }, keys.map { it.kind to it.label })
        assertTrue(keys.all { it.top >= head && it.bottom <= H + 0.01f })
        val q = keys.first { it.label == "q" }
        // chạm giữa phím q (plane tìm) → q, như plane chữ
        assertEquals("q", KeyLayout.hit(keys, Plane.EMOJI_SEARCH, q.centerX, q.centerY, 0f, d)?.label)
        assertEquals(keys.indices.toList(), keys.map { it.index })
    }

    @Test fun lettersRowsAndIndent() {
        val keys = build(Plane.LETTERS)
        val row1 = keys.filter { it.kind == KeyKind.LETTER && it.label in "qwertyuiop" }
        val row2 = keys.filter { it.kind == KeyKind.LETTER && it.label in "asdfghjkl" }
        assertEquals(10, row1.size); assertEquals(9, row2.size)
        // phím chữ hàng 1 và hàng 2 cùng bề rộng (thụt 0.5 phím mỗi bên)
        near(row1[0].width, row2[0].width)
        near(row1[0].left, 3f)
        near(row2[0].left, 3f + (row1[0].width + KeyLayout.KEY_SPACING) / 2)
        near(row1.last().right, W - 3f)
        // khe giữa phím (Gboard 5 dp)
        near(row1[1].left - row1[0].right, KeyLayout.KEY_SPACING)
        // hàng 54.5 cao: margin 5 trên/dưới
        near(row1[0].top, 5f); near(row1[0].bottom, H / 4 - 5f)
    }

    @Test fun thirdRowShiftBackspaceAreOneAndHalfKeys() {
        val keys = build(Plane.LETTERS)
        val shift = keys.first { it.kind == KeyKind.SHIFT }
        val back = keys.first { it.kind == KeyKind.BACKSPACE }
        val z = keys.first { it.label == "z" }
        near(shift.width, z.width * 1.5f)
        near(back.width, z.width * 1.5f)
        near(back.right, W - 3f)
    }

    @Test fun noPeriodKeyOnPhoneLetters() {
        // Bố cục DUY NHẤT kiểu iPhone (12/10/2026, không công tắc): [?123][😊][space][,][enter];
        // "." = giữ "," (chọn sẵn ".") / space đôi / plane 123.
        val bottom = build(Plane.LETTERS).filter { it.top > 3 * H / 4 - 1 }
        assertEquals(listOf(KeyKind.PLANE, KeyKind.EMOJI, KeyKind.SPACE, KeyKind.PUNCT, KeyKind.RETURN),
            bottom.map { it.kind })
        assertEquals(listOf(","), bottom.filter { it.kind == KeyKind.PUNCT }.map { it.insert })
        near(bottom.last().right, W - 3f, 0.05f)
        // Plane tìm emoji = plane chữ ⇒ cũng không có "."; plane số / mẫu câu giữ ".".
        assertTrue(build(Plane.EMOJI_SEARCH).none { it.kind == KeyKind.PUNCT && it.insert == "." })
        assertTrue(build(Plane.NUMBERS).any { it.kind == KeyKind.PUNCT && it.insert == "." })
        assertTrue(build(Plane.TEMPLATES).any { it.kind == KeyKind.PUNCT && it.insert == "." })
        // Tablet (dư chỗ) giữ phím ".".
        assertTrue(build(Plane.LETTERS, tablet = true).any { it.kind == KeyKind.PUNCT && it.insert == "." })
        // Một tay: cùng quy tắc.
        val one = KeyLayout.build(LayoutConfig(Plane.LETTERS, W, H, d, oneHand = OneHandSide.LEFT))
        assertTrue(one.none { it.kind == KeyKind.PUNCT && it.insert == "." })
    }

    @Test fun bottomRowProportions() {
        val keys = build(Plane.LETTERS, ret = "go")
        val bottom = keys.filter { it.top > 3 * H / 4 - 1 }
        assertEquals("?123", bottom[0].label)
        near(bottom[0].width, 0.15f * W)
        near(bottom[1].width, 0.10f * W)
        near(bottom[3].width, KeyLayout.PHONE_LETTERS_COMMA * W)   // "," hẹp (06/10/2026)
        near(bottom[4].width, 0.15f * W)
        // space nhận phần còn lại: rộng hơn hàng 5 phím ", ." cũ đúng 0.10 W + 1 khe.
        val gap = KeyLayout.KEY_SPACING
        near(bottom[2].width, W - 2 * KeyLayout.ROW_MARGIN_H - (0.15f + 0.10f + KeyLayout.PHONE_LETTERS_COMMA + 0.15f) * W - 4 * gap)
        assertTrue(bottom[2].width > 0.44f * W)   // Gboard ≈ 0.40 W (có ".")
        near(bottom.last().right, W - 3f, 0.05f)
        // cùng margin như mọi hàng
        near(bottom[0].top, 3 * H / 4 + KeyLayout.ROW_MARGIN_V)
        near(bottom[0].bottom, H - KeyLayout.ROW_MARGIN_V)
        near(bottom[0].height, keys.first { it.label == "q" }.height)
        assertEquals("go", bottom[4].label)
    }

    /**
     * Ma trận loại ô × khổ (dọc / ngang / tablet / một tay): thứ tự phím hàng đáy plane chữ, "."
     * luôn hiện ở ô URL / email, "," ở PHẢI space ở ô thường, space là phím rộng nhất.
     */
    @Test fun bottomRowMatrix() {
        data class Shape(val name: String, val w: Float, val h: Float, val tablet: Boolean, val one: OneHandSide)
        val shapes = listOf(
            Shape("dọc", 390f, 218f, false, OneHandSide.OFF),
            Shape("ngang", 840f, 168f, false, OneHandSide.OFF),
            Shape("tablet", 800f, 256f, true, OneHandSide.OFF),
            Shape("một tay", 390f, 218f, false, OneHandSide.RIGHT),
        )
        for (sh in shapes) for (kind in listOf(InputKind.NORMAL, InputKind.URL, InputKind.EMAIL)) {
            val keys = KeyLayout.build(LayoutConfig(Plane.LETTERS, sh.w, sh.h, d, kind, tablet = sh.tablet, oneHand = sh.one))
            val bottom = keys.filter { it.top > 3 * sh.h / 4 - 1 }.sortedBy { it.left }
            val tag = "${sh.name}/$kind"
            val punct = bottom.filter { it.kind == KeyKind.PUNCT }.map { it.insert }
            val expectPunct = when (kind) {
                InputKind.URL -> listOf("/", ".")
                InputKind.EMAIL -> listOf("@", ".")
                else -> if (sh.tablet) listOf(",", ".") else listOf(",")
            }
            assertEquals(tag, expectPunct, punct)
            val si = bottom.indexOfFirst { it.kind == KeyKind.SPACE }
            if (kind == InputKind.NORMAL && sh.tablet) {
                // Tablet: [?123][😊][,][space][.][↵][ẩn] — dấu câu hai bên space.
                assertEquals(tag, listOf(KeyKind.PLANE, KeyKind.EMOJI, KeyKind.PUNCT), bottom.take(si).map { it.kind })
                assertEquals(tag, ".", bottom[si + 1].insert)
            } else if (kind == InputKind.NORMAL) {
                // [?123][😊][space][,][↵]: không phím nào bên trái space ngoài ?123 / 😊.
                assertEquals(tag, listOf(KeyKind.PLANE, KeyKind.EMOJI), bottom.take(si).map { it.kind })
                assertEquals(tag, ",", bottom[si + 1].insert)
            } else {
                assertEquals(tag, listOf(KeyKind.PLANE, KeyKind.PUNCT, KeyKind.EMOJI), bottom.take(si).map { it.kind })
                assertEquals(tag, ".", bottom[si + 1].insert)
            }
            val space = bottom[si]
            assertTrue(tag, bottom.all { it === space || it.width < space.width })
            // Không chồng nhau, cùng hàng.
            for (i in 1 until bottom.size) assertTrue(tag, bottom[i].left >= bottom[i - 1].right)
        }
    }

    @Test fun emailAndUrlVariants() {
        val email = build(Plane.LETTERS, InputKind.EMAIL).filter { it.kind == KeyKind.PUNCT }
        assertEquals(listOf("@", "."), email.map { it.insert })
        val url = build(Plane.LETTERS, InputKind.URL).filter { it.kind == KeyKind.PUNCT }
        // Issue #113: không phím ".com" — đuôi tên miền ở giữ "."; ô URL / email luôn có ".".
        assertEquals(listOf("/", "."), url.map { it.insert })
        val urlSpace = build(Plane.LETTERS, InputKind.URL).first { it.kind == KeyKind.SPACE }
        val normalSpace = build(Plane.LETTERS).first { it.kind == KeyKind.SPACE }
        // Ô thường: 1 phím "," hẹp thay "/"+"." ⇒ space rộng hơn ô URL đúng 0.10 W + phần cắt + 1 khe.
        near(urlSpace.width + (0.20f - KeyLayout.PHONE_LETTERS_COMMA) * W + KeyLayout.KEY_SPACING, normalSpace.width)
        // plane số không đổi theo kind
        val num = build(Plane.NUMBERS, InputKind.EMAIL).filter { it.kind == KeyKind.PUNCT }
        assertEquals(listOf(",", "."), num.map { it.insert })
    }

    @Test fun globeAndTabletDismiss() {
        val k = build(Plane.LETTERS, globe = true, tablet = true)
        val kinds = k.filter { it.top > 3 * H / 4 - 1 }.map { it.kind }
        assertEquals(listOf(KeyKind.PLANE, KeyKind.GLOBE, KeyKind.EMOJI, KeyKind.PUNCT, KeyKind.SPACE,
            KeyKind.PUNCT, KeyKind.RETURN, KeyKind.DISMISS), kinds)
        // Ô URL / email: "/" "@" vẫn bên trái như cũ.
        val url = build(Plane.LETTERS, InputKind.URL).filter { it.top > 3 * H / 4 - 1 }.map { it.kind }
        assertEquals(listOf(KeyKind.PLANE, KeyKind.PUNCT, KeyKind.EMOJI, KeyKind.SPACE, KeyKind.PUNCT, KeyKind.RETURN), url)
        val space = k.first { it.kind == KeyKind.SPACE }
        assertTrue(space.width > 0.10f * W)
    }

    private fun rows(keys: List<LaidKey>, h: Float = H) = (0 until 4).map { r ->
        keys.filter { it.top >= r * h / 4 && it.top < (r + 1) * h / 4 }.sortedBy { it.left }
    }
    private fun typed(keys: List<LaidKey>) =
        keys.filter { it.kind == KeyKind.CHAR || it.kind == KeyKind.PUNCT }.map { it.insert }

    /** #113: bàn 123 kiểu Gboard — đúng hàng, đúng thứ tự, không ký tự nào lặp (kể cả hàng đáy). */
    @Test fun numbersPlaneGboardNoDuplicates() {
        val n = build(Plane.NUMBERS)
        val (r1, r2, r3, bottom) = rows(n)
        assertEquals("1 2 3 4 5 6 7 8 9 0".split(" "), r1.map { it.label })
        assertEquals("@ # \$ _ & - + ( ) /".split(" "), r2.map { it.label })
        assertEquals(listOf("=\\<", "*", "\"", "'", ":", ";", "!", "?", ""), r3.map { it.label })
        assertEquals(KeyKind.MORE, r3.first().kind); assertEquals(KeyKind.BACKSPACE, r3.last().kind)
        assertEquals(listOf(KeyKind.PLANE, KeyKind.PUNCT, KeyKind.EMOJI, KeyKind.SPACE, KeyKind.PUNCT, KeyKind.RETURN),
            bottom.map { it.kind })
        assertEquals(listOf("ABC", ",", "", "", ".", "return"), bottom.map { it.label })
        val t = typed(n)
        assertEquals("trùng: ${t.groupBy { it }.filter { it.value.size > 1 }.keys}", t.size, t.toSet().size)
        assertTrue(t.containsAll(listOf("#", "*", "+", "@", "\$", ",", ".")))
        assertTrue("₫ chỉ còn ở giữ \$ (#165)", "₫" !in t)
        // hàng 3 khít hai mép, ⇧-cỡ 1.5 phím như plane chữ
        near(r3.first().left, 3f); near(r3.last().right, W - 3f)
        near(r3.first().width, r3.last().width)
        for (k in r3.subList(1, r3.size - 1)) near(k.width, r3[1].width)
    }

    @Test fun symbolsPlaneComplete() {
        val s = build(Plane.SYMBOLS)
        val (r1, r2, r3, bottom) = rows(s)
        assertEquals("~ ` | • √ π ÷ × ¶ ∆".split(" "), r1.map { it.label })
        assertEquals("/ £ € ¥ ^ ° = { } \\".split(" "), r2.map { it.label })
        assertEquals(listOf("?123", "%", "©", "®", "™", "✓", "[", "]", "<", ">", ""), r3.map { it.label })
        assertEquals(KeyKind.MORE, r3.first().kind); assertEquals(KeyKind.BACKSPACE, r3.last().kind)
        assertEquals(listOf("ABC", ",", "", "", ".", "return"), bottom.map { it.label })
        val t = typed(s)
        assertEquals(t.size, t.toSet().size)
        assertEquals(29 + 2, t.size)
        near(r3.last().right, W - 3f)
        assertTrue(r3[1].width > 20f)
    }

    /** Tablet: giữ phím phụ (🌐, ẩn bàn phím) nhưng vẫn không lặp ký tự. */
    @Test fun numbersPlaneTabletNoDuplicates() {
        for (plane in listOf(Plane.NUMBERS, Plane.SYMBOLS)) {
            val k = build(plane, globe = true, tablet = true)
            val bottom = rows(k)[3]
            assertEquals(listOf(KeyKind.PLANE, KeyKind.PUNCT, KeyKind.GLOBE, KeyKind.EMOJI, KeyKind.SPACE,
                KeyKind.PUNCT, KeyKind.RETURN, KeyKind.DISMISS), bottom.map { it.kind })
            val t = typed(k)
            assertEquals(t.size, t.toSet().size)
            near(bottom.last().right, W - 3f, 0.05f)
        }
        // một tay / hàng số bật / ô email: cùng bộ phím
        val base = typed(build(Plane.NUMBERS)).toSet()
        assertEquals(base, typed(KeyLayout.build(LayoutConfig(Plane.NUMBERS, W, H, d, oneHand = OneHandSide.LEFT))).toSet())
        assertEquals(base, typed(build(Plane.NUMBERS, InputKind.EMAIL)).toSet())
    }

    /** ABC về plane chữ; MORE đổi qua lại; "." (hàng đáy) chèn "." ⇒ auto-space ". " / auto-shift như cũ. */
    @Test fun planeKeysAndPeriod() {
        val n = build(Plane.NUMBERS)
        assertEquals("ABC", n.first { it.kind == KeyKind.PLANE }.insert)
        assertEquals("=\\<", n.first { it.kind == KeyKind.MORE }.insert)
        assertEquals("?123", build(Plane.SYMBOLS).first { it.kind == KeyKind.MORE }.insert)
        assertEquals(1, n.count { it.insert == "." }); assertEquals(KeyKind.PUNCT, n.first { it.insert == "." }.kind)
        assertTrue(PlanePolicy.reevaluatesShift(Plane.LETTERS))
        assertTrue(!PlanePolicy.reevaluatesShift(Plane.NUMBERS) && !PlanePolicy.reevaluatesShift(Plane.SYMBOLS))
    }

    /** Mọi khoá bảng biến thể có trên bàn 123 / ký hiệu; phím mới có biến thể; "," không có menu ở đây. */
    @Test fun variantsCoverNewKeys() {
        val onPlanes = (typed(build(Plane.NUMBERS)) + typed(build(Plane.SYMBOLS))).toSet()
        for (key in com.viettelex.keyboard.KeyVariants.table.keys) assertTrue("$key không có trên plane", key in onPlanes)
        val v = { s: String -> com.viettelex.keyboard.KeyVariants.variants(s, symbolPlane = true) }
        assertEquals(listOf("\$", "₫", "€", "£", "¥", "₩", "₹", "₽", "¢"), v("\$"))   // giữ $ ⇒ ₫ ngay ô kế (#165)
        assertEquals(listOf("-", "–", "—", "•"), v("-"))
        assertEquals(listOf("\"", "”", "“", "„", "»", "«"), v("\""))
        assertEquals(listOf("'", "‘", "’", "`"), v("'"))
        assertEquals(listOf("!", "¡"), v("!")); assertEquals(listOf("?", "¿"), v("?"))
        assertEquals(listOf(".", "…"), v(".")); assertEquals(listOf("0", "°"), v("0"))
        assertEquals(listOf("%", "‰"), v("%")); assertEquals(listOf("*", "×"), v("*"))
        assertEquals(listOf("=", "≠", "≈"), v("=")); assertEquals(listOf("+", "±"), v("+"))
        assertEquals(listOf("/", "=", "\\"), v("/")); assertEquals(listOf("&", "§"), v("&"))
        assertEquals(emptyList<String>(), v(","))
    }

    /**
     * Field report 18/10/2026 ("dấu bằng để rất sâu" — "Hiện kết quả phép tính" bất tiện): bàn ?123
     * không có phím "=" (nó ở bàn =\<) ⇒ giữ "/" rồi trượt một ô ra "=", cả khi bật hàng số.
     */
    @Test fun equalsReachableFromNumbersPlane() {
        for (numberRow in listOf(false, true)) {
            val keys = typed(KeyLayout.build(LayoutConfig(Plane.NUMBERS, W, H, d, numberRow = numberRow)))
            assertTrue("plane ?123 chưa có phím = (numberRow=$numberRow)", "=" !in keys)
            assertTrue("/" in keys)
            val holders = keys.filter { "=" in com.viettelex.keyboard.KeyVariants.variants(it, symbolPlane = true) }
            assertEquals(listOf("/"), holders)
            assertEquals("=", com.viettelex.keyboard.KeyVariants.variants("/", symbolPlane = true)[1])
        }
    }

    @Test fun templatesBottomRowOnly() {
        val t = build(Plane.TEMPLATES)
        assertTrue(t.any { it.kind == KeyKind.CLEAR })
        assertTrue(t.none { it.kind == KeyKind.EMOJI || it.kind == KeyKind.LETTER })
        near(t[0].top, H - H / 4 + KeyLayout.BOTTOM_ROW_TOP)
    }

    // --- router ---

    @Test fun letterWinsOverShiftExpandedArea() {
        val keys = build(Plane.LETTERS)
        val z = keys.first { it.label == "z" }
        // mép trái của z, trong vùng nở 3 dp của shift
        val hit = KeyLayout.hit(keys, Plane.LETTERS, z.left + 1f, z.centerY, 4f, d)
        assertEquals("z", hit?.label)
    }

    @Test fun gapBetweenKeysRoutesToNearest() {
        val keys = build(Plane.LETTERS)
        val q = keys.first { it.label == "q" }; val w = keys.first { it.label == "w" }
        val midGapX = (q.right + w.left) / 2
        assertNotNull(KeyLayout.hit(keys, Plane.LETTERS, midGapX, q.centerY, 4f, d))
        // khe giữa hàng 1 và 2 (dời lên 4 dp ⇒ hàng trên)
        val a = keys.first { it.label == "a" }
        val gapY = (q.bottom + a.top) / 2
        assertEquals("q", KeyLayout.hit(keys, Plane.LETTERS, q.centerX, gapY, 4f, d)?.label)
    }

    @Test fun yOffsetShiftsSelectionUp() {
        val keys = build(Plane.LETTERS)
        val a = keys.first { it.label == "a" }
        // chạm 2 dp dưới mép trên của a: điểm chọn dời lên 4 dp ⇒ vẫn trong footprint nở
        // của hàng trên (q/w) — y hệt iOS keySelectionPoint.
        val hit = KeyLayout.hit(keys, Plane.LETTERS, a.centerX, a.top + 1f, 4f, d)
        assertTrue(hit?.label == "a" || hit?.label == "q" || hit?.label == "w")
    }

    @Test fun noDeadGapAboveBottomRow() {
        val keys = build(Plane.LETTERS)
        val shift = keys.first { it.kind == KeyKind.SHIFT }
        val plane = keys.first { it.kind == KeyKind.PLANE }
        // khe giữa hàng 3 và hàng đáy: mọi điểm phải trúng một phím
        var y = shift.bottom
        while (y < plane.top) {
            assertNotNull("dead at y=$y", KeyLayout.hit(keys, Plane.LETTERS, plane.centerX, y, 4f, d))
            y += 0.5f
        }
    }

    @Test fun controlKeysByExpandedArea() {
        val keys = build(Plane.NUMBERS)
        val one = keys.first { it.label == "1" }
        assertEquals("1", KeyLayout.hit(keys, Plane.NUMBERS, one.left - 2f, one.top - 4f, 4f, d)?.label)
        val space = keys.first { it.kind == KeyKind.SPACE }
        assertEquals(KeyKind.SPACE, KeyLayout.hit(keys, Plane.NUMBERS, space.centerX, space.bottom - 1f, 4f, d)?.kind)
    }

    @Test fun farPointMisses() {
        val keys = build(Plane.LETTERS)
        assertNull(KeyLayout.nearestLetter(keys, W / 2, -40f, d))
    }

    // --- bàn số ---

    private fun pad(plane: Plane, kind: InputKind, signed: Boolean = false, decimal: Boolean = false, ret: String = "done") =
        KeyLayout.build(LayoutConfig(plane, W, H, d, kind, returnLabel = ret, numberSigned = signed, numberDecimal = decimal))

    private fun padLabels(keys: List<LaidKey>) = keys.filter { it.kind == KeyKind.PAD }.map { it.label }.toSet()

    @Test fun phonePadGridHintsAndSides() {
        val k = pad(Plane.PHONE, InputKind.PHONE)
        assertEquals(setOf("1","2","3","4","5","6","7","8","9","*","0","#","+","-","(",")",",",";"), padLabels(k))
        assertEquals("ABC", k.first { it.label == "2" }.hint)
        assertEquals("WXYZ", k.first { it.label == "9" }.hint)
        assertEquals("", k.first { it.label == "1" }.hint)
        // lưới 3 cột bằng nhau, 0 giữa * và #
        val star = k.first { it.label == "*" }; val zero = k.first { it.label == "0" }; val hash = k.first { it.label == "#" }
        near(star.width, zero.width); near(zero.width, hash.width)
        assertTrue(star.right < zero.left && zero.right < hash.left)
        near(zero.centerX, k.first { it.label == "5" }.centerX)
        // cột phải: ⌫ trên cùng, enter dưới cùng; có space + toggle ?123
        val bs = k.first { it.kind == KeyKind.BACKSPACE }; val ret = k.first { it.kind == KeyKind.RETURN }
        assertTrue(bs.top < ret.top && bs.left > hash.right && ret.left > hash.right)
        assertTrue(k.any { it.kind == KeyKind.SPACE })
        assertEquals("?123", k.first { it.kind == KeyKind.MORE }.label)
        assertTrue(k.first { it.label == "+" }.side)
        assertTrue(!k.first { it.label == "5" }.side)
    }

    @Test fun numpadFlagsControlSideKeys() {
        val plain = padLabels(pad(Plane.NUMPAD, InputKind.NUMBER))
        assertEquals(setOf("0","1","2","3","4","5","6","7","8","9"), plain)
        val signed = padLabels(pad(Plane.NUMPAD, InputKind.NUMBER, signed = true))
        assertTrue("-" in signed && "." !in signed && "," !in signed)
        val dec = padLabels(pad(Plane.NUMPAD, InputKind.NUMBER, decimal = true))
        assertTrue("." in dec && "," in dec && "-" !in dec)
        val both = pad(Plane.NUMPAD, InputKind.NUMBER, signed = true, decimal = true)
        assertTrue(padLabels(both).containsAll(listOf("-", ".", ",")))
        // 0 ở hàng dưới, giữa cột
        val zero = both.first { it.label == "0" }
        near(zero.centerX, both.first { it.label == "8" }.centerX)
        assertTrue(zero.top > both.first { it.label == "8" }.bottom)
        // không DECIMAL ⇒ 0 nở phủ cả hàng lưới dưới (không ô trống)
        val p = pad(Plane.NUMPAD, InputKind.NUMBER)
        val z = p.first { it.label == "0" }
        near(z.left, p.first { it.label == "7" }.left); near(z.right, p.first { it.label == "9" }.right)
        // Như Gboard (15/11/2026): KHÔNG cột trái ở ô số; "−" ở cột phải, ", ." kẹp hai bên 0.
        near(p.first { it.label == "1" }.width, both.first { it.label == "1" }.width)
        val minus = both.first { it.label == "-" }
        assertTrue(minus.left > both.first { it.label == "3" }.right)
        near(minus.top, both.first { it.label == "3" }.top)
        assertTrue(both.first { it.label == "," }.right <= zero.left && both.first { it.label == "." }.left >= zero.right)
        // ␣ ⌫ enter luôn có; ⌫ hàng 3, enter hàng 4 dù có "−" hay không; KHÔNG ?123 (ô số từ chối ký hiệu).
        for (k in listOf(p, both)) {
            assertTrue(k.any { it.kind == KeyKind.SPACE } && k.any { it.kind == KeyKind.RETURN })
            near(k.first { it.kind == KeyKind.BACKSPACE }.top, k.first { it.label == "7" }.top)
            near(k.first { it.kind == KeyKind.RETURN }.top, k.first { it.label == "0" }.top)
            assertTrue(k.none { it.kind == KeyKind.MORE })
        }
        // không "−" ⇒ ␣ cao 2 hàng (không ô trống)
        val sp = p.first { it.kind == KeyKind.SPACE }
        near(sp.top, p.first { it.label == "1" }.top); near(sp.bottom, p.first { it.label == "4" }.bottom)
    }

    /** 15/11/2026: Dán lên thanh trên (StripMode.TOOLS) ⇒ bàn số không còn phím 📋; phím cách chiếm trọn khe. */
    @Test fun numberPadsHaveNoPasteKey() {
        for (k in listOf(pad(Plane.PHONE, InputKind.PHONE), pad(Plane.NUMPAD, InputKind.NUMBER),
                         pad(Plane.NUMPAD, InputKind.DATETIME), pad(Plane.NUMPAD, InputKind.NUMBER, signed = true, decimal = true))) {
            assertTrue(k.none { it.kind == KeyKind.PASTE })
            val space = k.single { it.kind == KeyKind.SPACE }
            val ret = k.single { it.kind == KeyKind.RETURN }
            near(space.left, ret.left); near(space.right, ret.right)
        }
        // Ô điện thoại giữ ?123 (cần + * # , ;); ô ngày giờ không.
        assertTrue(pad(Plane.PHONE, InputKind.PHONE).any { it.kind == KeyKind.MORE })
        assertTrue(pad(Plane.NUMPAD, InputKind.DATETIME).none { it.kind == KeyKind.MORE })
    }

    @Test fun datetimePadHasSeparators() {
        val k = padLabels(pad(Plane.NUMPAD, InputKind.DATETIME))
        assertTrue(k.containsAll(listOf("/", ":", "-")))
        assertTrue("." !in k)
    }

    @Test fun padKeysDoNotOverlapAndNoDeadGaps() {
        for (k in listOf(pad(Plane.PHONE, InputKind.PHONE), pad(Plane.NUMPAD, InputKind.DATETIME),
                         pad(Plane.NUMPAD, InputKind.NUMBER), pad(Plane.NUMPAD, InputKind.NUMBER, signed = true, decimal = true))) {
            for (a in k) for (b in k) if (a !== b) {
                val overlap = a.left < b.right && b.left < a.right && a.top < b.bottom && b.top < a.bottom
                assertTrue("overlap $a / $b", !overlap)
            }
            var y = 1f
            while (y < H - 1f) {
                var x = 1f
                while (x < W - 1f) {
                    assertNotNull("dead at $x,$y", KeyLayout.hit(k, Plane.NUMPAD, x, y, 4f, d)); x += 7f
                }
                y += 3f
            }
        }
    }

    @Test fun symbolsPlaneReturnsToPadForNumericFields() {
        val n = KeyLayout.build(LayoutConfig(Plane.NUMBERS, W, H, d, InputKind.PHONE))
        assertEquals("123", n.first { it.kind == KeyKind.PLANE }.label)
        val t = KeyLayout.build(LayoutConfig(Plane.NUMBERS, W, H, d, InputKind.NORMAL))
        assertEquals("ABC", t.first { it.kind == KeyKind.PLANE }.label)
    }

    /**
     * "Phím cạnh dấu cách" (16/10/2026): mỗi tuỳ chọn ⇒ hàng đáy bàn chữ điện thoại ô thường.
     * Dấu phẩy = bố cục cũ; Dấu chấm = cùng chỗ cùng cỡ; Tắt = không phím, space ăn chỗ.
     * Không bao giờ hàng hai phím ", ." (Phil 12/10/2026). Ô URL / email, tablet, plane số giữ nguyên.
     */
    @Test fun spaceSideKeyOptions() {
        fun cfg(side: SpaceSideKey, plane: Plane = Plane.LETTERS, kind: InputKind = InputKind.NORMAL,
                tablet: Boolean = false, one: OneHandSide = OneHandSide.OFF) =
            LayoutConfig(plane, W, H, d, kind, tablet = tablet, oneHand = one, spaceSideKey = side)
        fun bottom(c: LayoutConfig) = KeyLayout.build(c).filter { it.top > 3 * c.keyAreaPx / 4 - 1 }.sortedBy { it.left }
        fun kinds(c: LayoutConfig) = bottom(c).map { if (it.kind == KeyKind.PUNCT) it.insert else it.kind.toString() }
        val P = KeyKind.PLANE.toString(); val E = KeyKind.EMOJI.toString()
        val S = KeyKind.SPACE.toString(); val R = KeyKind.RETURN.toString()
        assertEquals(SpaceSideKey.COMMA, SpaceSideKey.DEFAULT)
        assertEquals(SpaceSideKey.COMMA, LayoutConfig(Plane.LETTERS, W, H, d).spaceSideKey)
        assertEquals(listOf(P, E, S, ",", R), kinds(cfg(SpaceSideKey.COMMA)))
        assertEquals(listOf(P, E, S, ".", R), kinds(cfg(SpaceSideKey.PERIOD)))
        assertEquals(listOf(P, E, S, R), kinds(cfg(SpaceSideKey.OFF)))
        // Mặc định không đổi bố cục cũ (từng phím, từng toạ độ).
        assertEquals(build(Plane.LETTERS).map { it.toString() }, KeyLayout.build(cfg(SpaceSideKey.COMMA)).map { it.toString() })
        // Dấu chấm: cùng hình học với dấu phẩy.
        val comma = bottom(cfg(SpaceSideKey.COMMA)); val period = bottom(cfg(SpaceSideKey.PERIOD))
        for (i in comma.indices) { near(period[i].left, comma[i].left); near(period[i].right, comma[i].right) }
        near(period[3].width, KeyLayout.PHONE_LETTERS_COMMA * W)
        // Tắt: space rộng thêm đúng phím hẹp + 1 khe; ↵ giữ nguyên chỗ.
        val off = bottom(cfg(SpaceSideKey.OFF))
        near(off[2].width, comma[2].width + KeyLayout.PHONE_LETTERS_COMMA * W + KeyLayout.KEY_SPACING)
        near(off[3].left, comma[4].left); near(off[3].right, comma[4].right)
        // Một tay / ô tìm emoji cùng quy tắc.
        assertEquals(listOf(P, E, S, ".", R), kinds(cfg(SpaceSideKey.PERIOD, one = OneHandSide.LEFT)))
        assertEquals(listOf(P, E, S, R), kinds(cfg(SpaceSideKey.OFF, one = OneHandSide.RIGHT)))
        assertTrue(KeyLayout.build(cfg(SpaceSideKey.OFF, plane = Plane.EMOJI_SEARCH)).none { it.kind == KeyKind.PUNCT })
        // Không áp: URL / email (cả tablet) / plane số, ký hiệu, mẫu câu — giống hệt mặc định.
        for (side in SpaceSideKey.entries) {
            for (c in listOf(cfg(side, kind = InputKind.URL), cfg(side, kind = InputKind.EMAIL),
                    cfg(side, kind = InputKind.URL, tablet = true), cfg(side, kind = InputKind.EMAIL, tablet = true),
                    cfg(side, plane = Plane.NUMBERS, tablet = true),
                    cfg(side, plane = Plane.NUMBERS), cfg(side, plane = Plane.SYMBOLS), cfg(side, plane = Plane.TEMPLATES),
                    cfg(side, plane = Plane.NUMBERS, kind = InputKind.EMAIL))) {
                assertEquals("$side ${c.plane} ${c.kind} tablet=${c.tablet}",
                    KeyLayout.build(c.copy(spaceSideKey = SpaceSideKey.COMMA)).map { it.toString() },
                    KeyLayout.build(c).map { it.toString() })
                assertNull(KeyLayout.sideKey(c))
            }
            assertEquals(side, KeyLayout.sideKey(cfg(side)))
            // Tablet: không phải "phím hẹp" (popup "." của Dấu chấm chỉ điện thoại).
            assertNull(KeyLayout.sideKey(cfg(side, tablet = true)))
        }
    }

    /**
     * Tablet bàn chữ ô thường (16/10/2026): space ĐÚNG GIỮA hàng và rộng; Dấu phẩy = Dấu chấm (cả
     * "," lẫn "." hai bên); Tắt ⇒ không dấu câu, space rộng hơn, vẫn giữa. Có / không 🌐, dọc / ngang.
     */
    @Test fun tabletBottomRowCentred() {
        data class Shape(val w: Float, val h: Float)
        for (sh in listOf(Shape(800f, 256f), Shape(1280f, 300f), Shape(600f, 256f)))
        for (globe in listOf(false, true)) for (side in SpaceSideKey.entries) {
            val c = LayoutConfig(Plane.LETTERS, sh.w, sh.h, d, needsGlobe = globe, tablet = true, spaceSideKey = side)
            val keys = KeyLayout.build(c)
            val bottom = keys.filter { it.top > 3 * sh.h / 4 - 1 }.sortedBy { it.left }
            val tag = "${sh.w} globe=$globe $side"
            val space = bottom.single { it.kind == KeyKind.SPACE }
            val leftGap = space.left; val rightGap = sh.w - space.right
            assertTrue("$tag lệch ${leftGap - rightGap}", kotlin.math.abs(leftGap - rightGap) < 0.01f * sh.w)
            near(space.centerX, sh.w / 2, 0.5f)
            val punct = bottom.filter { it.kind == KeyKind.PUNCT }.map { it.insert }
            val P = KeyKind.PLANE; val G = KeyKind.GLOBE; val E = KeyKind.EMOJI; val S = KeyKind.SPACE
            val U = KeyKind.PUNCT; val R = KeyKind.RETURN; val X = KeyKind.DISMISS
            val head = if (globe) listOf(P, G, E) else listOf(P, E)
            if (side == SpaceSideKey.OFF) {
                assertEquals(tag, emptyList<String>(), punct)
                assertEquals(tag, head + listOf(S, R, X), bottom.map { it.kind })
                assertTrue(tag, space.width > (if (globe) 0.48f else 0.58f) * sh.w)
            } else {
                assertEquals(tag, listOf(",", "."), punct)
                assertEquals(tag, head + listOf(U, S, U, R, X), bottom.map { it.kind })
                assertTrue(tag, space.width > (if (globe) 0.28f else 0.38f) * sh.w)
                // "," "." rộng đúng một phím chữ, kề sát space.
                val q = keys.first { it.label == "q" }
                for (p in bottom.filter { it.kind == KeyKind.PUNCT }) near(p.width, q.width, 0.05f)
                val si = bottom.indexOf(space)
                near(space.left - bottom[si - 1].right, KeyLayout.KEY_SPACING)
                near(bottom[si + 1].left - space.right, KeyLayout.KEY_SPACING)
            }
            // Dấu chấm ≡ Dấu phẩy trên tablet.
            if (side == SpaceSideKey.PERIOD) assertEquals(tag,
                KeyLayout.build(c.copy(spaceSideKey = SpaceSideKey.COMMA)).map { it.toString() }, keys.map { it.toString() })
            // Space là phím rộng nhất; khít hai mép; không chồng nhau; ↵ ở mép phải trước ẩn.
            assertTrue(tag, bottom.all { it === space || it.width < space.width })
            near(bottom.first().left, KeyLayout.ROW_MARGIN_H, 0.05f)
            near(bottom.last().right, sh.w - KeyLayout.ROW_MARGIN_H, 0.05f)
            for (i in 1 until bottom.size) near(bottom[i].left - bottom[i - 1].right, KeyLayout.KEY_SPACING, 0.05f)
            assertEquals(tag, KeyKind.RETURN, bottom[bottom.size - 2].kind)
            // Mép phím thẳng cột với hàng q…p: mép trái space trùng mép một nửa / cả phím hàng 1.
            val row1 = keys.filter { it.kind == KeyKind.LETTER && it.label in "qwertyuiop" }
            val pitch = row1[1].left - row1[0].left
            val units = (space.left - KeyLayout.ROW_MARGIN_H) / pitch
            near(units * 4, Math.round(units * 4).toFloat(), 0.01f)
            // Ô tìm emoji (plane chữ bên dưới) cùng bố cục.
            assertEquals(tag, bottom.map { it.kind },
                KeyLayout.build(c.copy(plane = Plane.EMOJI_SEARCH)).filter { it.top > 0.8f * sh.h - 1 }
                    .sortedBy { it.left }.map { it.kind })
        }
    }
    private fun cfg(side: SpaceSideKey = SpaceSideKey.DEFAULT, plane: Plane = Plane.LETTERS, kind: InputKind = InputKind.NORMAL,
                    tablet: Boolean = false, one: OneHandSide = OneHandSide.OFF, emojiInStrip: Boolean = false) =
        LayoutConfig(plane, W, H, d, kind, tablet = tablet, oneHand = one, spaceSideKey = side, emojiInStrip = emojiInStrip)
    private fun bottomOf(c: LayoutConfig) = KeyLayout.build(c).filter { it.top > 3 * c.keyAreaPx / 4 - 1 }.sortedBy { it.left }
    private fun kindsOf(c: LayoutConfig) = bottomOf(c).map { if (it.kind == KeyKind.PUNCT) it.insert else it.kind.toString() }
    private val kP = KeyKind.PLANE.toString(); private val kE = KeyKind.EMOJI.toString()
    private val kS = KeyKind.SPACE.toString(); private val kR = KeyKind.RETURN.toString()
    private val kX = KeyKind.DISMISS.toString()

    /**
     * "Cả hai" (16/10/2026): điện thoại [?123][😊][,][space][.][↵] — "," trái, "." phải, mỗi phím
     * hẹp như phím cạnh space; space co đúng một phím hẹp + một khe so với Dấu phẩy.
     */
    @Test fun spaceSideBoth() {
        assertEquals(SpaceSideKey.BOTH, SpaceSideKey.of("both"))
        assertEquals(listOf(kP, kE, ",", kS, ".", kR), kindsOf(cfg(SpaceSideKey.BOTH)))
        val comma = bottomOf(cfg(SpaceSideKey.COMMA)); val both = bottomOf(cfg(SpaceSideKey.BOTH))
        near(both[2].width, KeyLayout.PHONE_LETTERS_COMMA * W)
        near(both[4].width, KeyLayout.PHONE_LETTERS_COMMA * W)
        near(both[3].width, comma[2].width - KeyLayout.PHONE_LETTERS_COMMA * W - KeyLayout.KEY_SPACING)
        // ?123, 😊, ↵ không dời; "." đúng chỗ "," cũ.
        near(both[0].left, comma[0].left); near(both[1].right, comma[1].right)
        near(both[4].left, comma[3].left); near(both[5].right, comma[4].right)
        // Một tay cùng quy tắc; ô URL / email / tablet / plane số như Dấu phẩy.
        assertEquals(listOf(kP, kE, ",", kS, ".", kR), kindsOf(cfg(SpaceSideKey.BOTH, one = OneHandSide.LEFT)))
        for (c in listOf(cfg(SpaceSideKey.BOTH, kind = InputKind.URL), cfg(SpaceSideKey.BOTH, kind = InputKind.EMAIL),
                cfg(SpaceSideKey.BOTH, tablet = true), cfg(SpaceSideKey.BOTH, plane = Plane.NUMBERS))) {
            assertEquals(KeyLayout.build(c.copy(spaceSideKey = SpaceSideKey.COMMA)).map { it.toString() },
                KeyLayout.build(c).map { it.toString() })
        }
        // Tablet "Cả hai" ≡ Dấu phẩy: "," và "." hai bên space.
        assertEquals(listOf(kP, kE, ",", kS, ".", kR, kX), kindsOf(cfg(SpaceSideKey.BOTH, tablet = true)))
        assertEquals(SpaceSideKey.BOTH, KeyLayout.sideKey(cfg(SpaceSideKey.BOTH)))
        assertEquals(".", SpaceSideKey.BOTH.right); assertEquals(",", SpaceSideKey.BOTH.left)
        assertNull(SpaceSideKey.COMMA.left); assertNull(SpaceSideKey.PERIOD.left); assertNull(SpaceSideKey.OFF.right)
    }

    /**
     * "Nút emoji" = Thanh trên: bàn chữ bỏ 😊, space ăn đúng phím 😊 + một khe; mọi tổ hợp
     * phím cạnh dấu cách; plane số, ô tìm emoji, mẫu câu giữ nguyên.
     */
    @Test fun emojiInStripLayouts() {
        val expect = mapOf(
            SpaceSideKey.COMMA to listOf(kP, kS, ",", kR), SpaceSideKey.PERIOD to listOf(kP, kS, ".", kR),
            SpaceSideKey.BOTH to listOf(kP, ",", kS, ".", kR), SpaceSideKey.OFF to listOf(kP, kS, kR))
        for ((side, kinds) in expect) {
            val top = cfg(side, emojiInStrip = true)
            assertEquals("$side", kinds, kindsOf(top))
            val withEmoji = bottomOf(cfg(side)); val without = bottomOf(top)
            val emoji = withEmoji.first { it.kind == KeyKind.EMOJI }
            val sp0 = withEmoji.first { it.kind == KeyKind.SPACE }; val sp1 = without.first { it.kind == KeyKind.SPACE }
            near(sp1.width, sp0.width + emoji.width + KeyLayout.KEY_SPACING)
            near(without.last().right, withEmoji.last().right)   // ↵ không dời
        }
        // URL / email: cũng không có 😊 (strip hiện ⇒ nút ở strip).
        assertEquals(listOf(kP, "/", kS, ".", kR), kindsOf(cfg(kind = InputKind.URL, emojiInStrip = true)))
        // Tablet: space vẫn giữa hàng (?123 nở bù phần 😊).
        val tab = bottomOf(cfg(tablet = true, emojiInStrip = true))
        assertEquals(listOf(kP, ",", kS, ".", kR, kX), tab.map { if (it.kind == KeyKind.PUNCT) it.insert else it.kind.toString() })
        val sp = tab.first { it.kind == KeyKind.SPACE }
        near((sp.left + sp.right) / 2, W / 2, 0.01f)
        // Plane số / ký hiệu, ô tìm emoji: giữ 😊; mẫu câu giữ 🗑.
        for (pl in listOf(Plane.NUMBERS, Plane.SYMBOLS, Plane.EMOJI_SEARCH))
            assertTrue("$pl", KeyLayout.build(cfg(plane = pl, emojiInStrip = true)).any { it.kind == KeyKind.EMOJI })
        assertTrue(KeyLayout.build(cfg(plane = Plane.TEMPLATES, emojiInStrip = true)).any { it.kind == KeyKind.CLEAR })
        // Mặc định không đổi gì.
        assertFalse(LayoutConfig(Plane.LETTERS, W, H, d).emojiInStrip)
        assertEquals(build(Plane.LETTERS).map { it.toString() }, KeyLayout.build(cfg()).map { it.toString() })
    }

    /** Thanh trên nhưng strip không hiện (tắt gợi ý / ô mật khẩu) ⇒ 😊 ở lại hàng đáy. */
    @Test fun emojiPlacementFallback() {
        assertTrue(EmojiKeyPlacement.inStrip(EmojiKeyPlacement.TOP, stripShown = true))
        assertFalse(EmojiKeyPlacement.inStrip(EmojiKeyPlacement.TOP, stripShown = false))
        assertFalse(EmojiKeyPlacement.inStrip(EmojiKeyPlacement.BOTTOM, stripShown = true))
        assertFalse(EmojiKeyPlacement.inStrip(EmojiKeyPlacement.BOTTOM, stripShown = false))
        for (shown in listOf(true, false)) for (p in EmojiKeyPlacement.entries) {
            val inStrip = EmojiKeyPlacement.inStrip(p, shown)
            val hasKey = KeyLayout.build(cfg(emojiInStrip = inStrip)).any { it.kind == KeyKind.EMOJI }
            assertEquals("$p shown=$shown", !inStrip, hasKey)
            assertTrue("$p shown=$shown: 😊 luôn có lối vào", hasKey || shown)
        }
    }

    /** Trần chiều cao hàng +18; trên +10 kẹp theo nửa màn hình, tới +10 không bao giờ kẹp. */
    @Test fun rowHeightRangeAndClamp() {
        assertEquals(-10, KeyboardSettings.ROW_HEIGHT_MIN)
        assertEquals(18, KeyboardSettings.ROW_HEIGHT_MAX)
        // Không biết màn hình ⇒ không kẹp.
        assertEquals(18, KeyLayout.effectiveRowAdjust(false, false, 18))
        assertEquals(18, KeyLayout.effectiveRowAdjust(false, false, 30))
        // Điện thoại dọc 800 dp: 224 + 72 = 296 ≤ 400 ⇒ đủ +18 (phím 46 → 64 dp).
        assertEquals(18, KeyLayout.effectiveRowAdjust(false, false, 18, screenHeightDp = 800f))
        near(KeyLayout.keyAreaDp(false, false, 18, screenHeightDp = 800f), 296f)
        // Máy thấp 680 dp + hàng số: +14 là mức cao nhất còn ≤ 340 dp (280 + 58 = 338; +15 ⇒ 342.8).
        assertEquals(14, KeyLayout.effectiveRowAdjust(false, false, 18, numberRow = true, screenHeightDp = 680f))
        assertTrue(KeyLayout.keyAreaDp(false, false, 18, numberRow = true, screenHeightDp = 680f) <= 340f)
        // Máy nhỏ 600 dp + hàng số đủ cao: +10 đã vượt nửa màn hình ⇒ dừng ở +10 (không thấp hơn trần cũ).
        near(KeyLayout.keyAreaDp(false, false, 18, numberRow = true, numberRowFull = true, screenHeightDp = 600f),
            KeyLayout.keyAreaDp(false, false, 10, numberRow = true, numberRowFull = true))
        // Ngang 360 dp: không vượt +10 (≡ trần cũ), cũng không thấp hơn +10.
        assertEquals(10, KeyLayout.effectiveRowAdjust(false, true, 18, screenHeightDp = 360f))
        near(KeyLayout.keyAreaDp(false, true, 18, screenHeightDp = 360f), KeyLayout.keyAreaDp(false, true, 10))
        // Tới +10: luôn như cũ dù màn hình thấp.
        assertEquals(10, KeyLayout.effectiveRowAdjust(false, true, 10, screenHeightDp = 200f))
        assertEquals(-4, KeyLayout.effectiveRowAdjust(false, true, -4, screenHeightDp = 200f))
        // Tablet dọc 1280 dp: đủ +18.
        assertEquals(18, KeyLayout.effectiveRowAdjust(true, false, 18, screenHeightDp = 1280f))
        // Nhãn cài đặt "+N dp cả bàn phím".
        assertEquals(72, KeyLayout.adjustTotalDp(18, numberRow = false))
    }

    /** "Cỡ chữ trên phím" = Lớn: kẹp theo phím hẹp, không nhỏ hơn cỡ chuẩn. */
    @Test fun keyLabelFit() {
        // Vừa phím ⇒ giữ nguyên cỡ muốn.
        near(KeyLabelFit.fit(want = 26.84f, min = 22f, glyphW = 20f, keyW = 31f, pad = 3f), 26.84f)
        // Tràn ⇒ thu tỉ lệ cho vừa (31 − 6 = 25 chỗ, chữ 30 ⇒ × 25/30).
        near(KeyLabelFit.fit(want = 30f, min = 22f, glyphW = 30f, keyW = 31f, pad = 3f), 25f)
        // Phím cực hẹp ⇒ không nhỏ hơn cỡ chuẩn (Vừa).
        near(KeyLabelFit.fit(want = 26.84f, min = 22f, glyphW = 40f, keyW = 20f, pad = 3f), 22f)
        // Hệ số Lớn ~ +20–25 % chữ, phím chức năng ít hơn.
        val big = KeyLabelSize.LARGE
        assertTrue(big.letterScale in 1.2f..1.25f)
        assertTrue(big.controlScale in 1.05f..big.letterScale)
        assertEquals(1f, KeyLabelSize.MEDIUM.letterScale, 0f)
        assertEquals(KeyLabelSize.MEDIUM, KeyLabelSize.of(null))
        assertEquals(KeyLabelSize.LARGE, KeyLabelSize.of("large"))
        // Phím chữ hẹp nhất (320–411 dp, một tay) — sau kẹp "W" (≈ 0.9 em) luôn vừa chỗ hoặc về cỡ chuẩn.
        for (width in listOf(320f, 360f, 411f)) for (one in listOf(OneHandSide.OFF, OneHandSide.LEFT)) {
            val keys = KeyLayout.build(LayoutConfig(Plane.LETTERS, width, H, d, oneHand = one))
            val kw = keys.filter { it.kind == KeyKind.LETTER }.minOf { it.width }
            val want = 22f * big.letterScale
            val size = KeyLabelFit.fit(want, 22f, 0.9f * want, kw, KeyLabelFit.PAD_DP)
            assertTrue("$width $one", 0.9f * size <= kw - 2 * KeyLabelFit.PAD_DP + 0.01f || size == 22f)
        }
    }

    /** Tester 15/11/2026: bàn số không có nhãn VI/EN trên phím cách (tưởng nút chuyển Anh/Việt thừa). */
    @Test fun numberPadSpaceCarriesNoLanguage() {
        assertTrue(KeyLayout.isNumberPad(Plane.PHONE))
        assertTrue(KeyLayout.isNumberPad(Plane.NUMPAD))
        for (p in listOf(Plane.LETTERS, Plane.NUMBERS, Plane.SYMBOLS)) assertFalse(KeyLayout.isNumberPad(p))
        // Nối dây: vẽ nhãn và vuốt đổi ngôn ngữ đều đi qua languageOnSpace.
        val src = listOf(java.io.File("src/main/kotlin"), java.io.File("app/src/main/kotlin")).first { it.isDirectory }
            .resolve("com/viettelex/android/ime/KeyboardView.kt").readText()
        assertTrue("!KeyLayout.isNumberPad(plane)" in src)
        assertEquals(2, Regex("&& languageOnSpace\\)").findAll(src).count())   // moveFlick + endFlick
        assertTrue("if (!languageOnSpace) { drawLabel(c, \"\\u2423\"" in src)          // drawSpaceContent: ␣ thay nhãn VI/EN
    }
}
