package com.viettelex.android.ime

import com.viettelex.keyboard.BarLayout
import com.viettelex.keyboard.SuggestionSet
import com.viettelex.keyboard.SuggestionSlots
import com.viettelex.keyboard.ClipChip
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

/** Lỗi iOS 27/09/2026: thẻ Dán vẽ chồng chữ gợi ý, slot đổi bề rộng theo nội dung. */
class StripGeometryTest {
    @Test fun threeEqualContiguousSlots() {
        val l = FloatArray(3); val r = FloatArray(3)
        StripGeometry.thirds(100f, 400f, l, r)
        assertEquals(100f, l[0]); assertEquals(400f, r[2])
        for (i in 0..2) assertEquals(100f, r[i] - l[i], 0.001f)
        assertEquals(r[0], l[1]); assertEquals(r[1], l[2])
    }

    /** "Số từ gợi ý": n ô bằng nhau, liền nhau, ô cuối chạm mép phải; thirds = cells(3). */
    @Test fun nEqualContiguousSlots() {
        for (n in 1..5) {
            val l = FloatArray(5); val r = FloatArray(5)
            StripGeometry.cells(100f, 400f, n, l, r)
            assertEquals(100f, l[0]); assertEquals(400f, r[n - 1])
            for (i in 0 until n) assertEquals(300f / n, r[i] - l[i], 0.001f)
            for (i in 1 until n) assertEquals(r[i - 1], l[i])
        }
        // máy hẹp 300 dp, bar có gợi ý (icon con trỏ/📋 ẩn), nút 😊 trên thanh: 5 ô không vừa 44 dp ⇒ 4
        val shown = StripGeometry.toolsShown(hasContent = true, editOpen = false, clipOpen = false)
        val barL = StripGeometry.barLeft(KeyLayout.STRIP_ZONE_W, StripGeometry.TOOL_W, shown)
        val plain = StripGeometry.barRight(300f, StripGeometry.CLIP_W, true, shown) - barL
        val emoji = StripGeometry.barRight(300f, StripGeometry.CLIP_W, true, shown, emojiButton = true) - barL
        assertEquals(5, com.viettelex.keyboard.SuggestionCount.fit(5, plain))
        assertEquals(4, com.viettelex.keyboard.SuggestionCount.fit(5, emoji))
    }

    @Test fun gboardProportions() {
        // #112: strip 42 dp ≈ 0.75 hàng phím chuẩn (56 dp); pill / ô nhấn nằm gọn trong dải.
        val row = KeyLayout.keyAreaDp(false, false, 0) / 4f
        assertEquals(0.75f, KeyLayout.OPEN_STRIP / row, 0.01f)
        val half = StripGeometry.PILL_H / 2
        assertTrue(KeyLayout.BAR_CY - half >= 0f && KeyLayout.BAR_CY + half <= KeyLayout.OPEN_STRIP)
        // Mọi mức "Chiều cao thanh gợi ý": pill / ô nhấn vẫn gọn trong dải.
        for (h in com.viettelex.keyboard.SuggestionBarHeight.entries) {
            val cy = KeyLayout.barCy(h.openStripDp)
            assertTrue("$h", cy - half >= 0f && cy + half <= h.openStripDp)
        }
        assertEquals(KeyLayout.BAR_CY, KeyLayout.barCy(KeyLayout.OPEN_STRIP), 0f)
        assertTrue(StripGeometry.WORD_SP >= 16f)
        // Icon: 22 dp (📋 bớt 1); hàm nội suy (di sản trạng thái thu gọn) kẹp 0…1.
        assertEquals(14f, StripGeometry.iconDp(0f), 0.001f)
        assertEquals(22f, StripGeometry.iconDp(1f), 0.001f)
        assertEquals(20f, StripGeometry.iconDp(1f, delta = 2f), 0.001f)
        assertEquals(18f, StripGeometry.iconDp(0.5f), 0.001f)
        assertEquals(22f, StripGeometry.iconDp(3f), 0.001f)
    }

    @Test fun pasteCardReplacesWholeBar() {
        // Có chữ gợi ý + thẻ Dán ⇒ chỉ thẻ Dán (không slot nào vẽ chồng).
        val set = SuggestionSet(literal = "xin", word = "xin", word2 = "xinh", paste = true)
        assertSame(BarLayout.PasteCard, SuggestionSlots.arrange(set, undoAsPill = true, bestInMiddle = true))
    }

    // #113: đang gõ có gợi ý ⇒ ẩn icon con trỏ + 📋, 3 slot ăn phần trống; ☰ giữ nguyên.
    private fun slotWidth(width: Float, clipButton: Boolean, tools: Boolean): Float {
        val l = FloatArray(3); val r = FloatArray(3)
        val zone = KeyLayout.STRIP_ZONE_W
        StripGeometry.thirds(StripGeometry.barLeft(zone, StripGeometry.TOOL_W, tools),
            StripGeometry.barRight(width, StripGeometry.CLIP_W, clipButton, tools), l, r)
        for (i in 0..2) assertEquals(r[0] - l[0], r[i] - l[i], 0.001f)   // vẫn 3 ô bằng nhau
        return r[0] - l[0]
    }

    @Test fun suggestionsWidenSlotsByHidingTools() {
        val w = 411f
        // Idle (không gợi ý): ☰ zone + con trỏ 44 + … + 📋 40 sát mép phải (không còn zone ⌄).
        assertEquals((w - 52f - 44f - 40f) / 3f, slotWidth(w, clipButton = true, tools = true), 0.001f)
        assertEquals((w - 52f - 44f) / 3f, slotWidth(w, clipButton = false, tools = true), 0.001f)
        // Có gợi ý: chỉ trừ zone ☰ — bar chạm mép phải; mỗi slot rộng thêm (44 + 40) / 3 dp.
        val wide = slotWidth(w, clipButton = true, tools = false)
        assertEquals((w - 52f) / 3f, wide, 0.001f)
        assertEquals(w, StripGeometry.barRight(w, StripGeometry.CLIP_W, true, false), 0.001f)
        assertEquals(28f, wide - slotWidth(w, clipButton = true, tools = true), 0.001f)
        assertEquals(wide, slotWidth(w, clipButton = false, tools = false), 0.001f)
        assertEquals(52f, StripGeometry.barLeft(52f, 44f, toolsShown = false), 0.001f)
    }

    @Test fun toolsHiddenOnlyWhileContent() {
        assertTrue(StripGeometry.toolsShown(hasContent = false, editOpen = false, clipOpen = false))
        assertFalse(StripGeometry.toolsShown(hasContent = true, editOpen = false, clipOpen = false))
        // Bảng sửa / lịch sử clipboard đang mở ⇒ icon vẫn hiện để đóng được.
        assertTrue(StripGeometry.toolsShown(hasContent = true, editOpen = true, clipOpen = false))
        assertTrue(StripGeometry.toolsShown(hasContent = true, editOpen = false, clipOpen = true))
    }

    private fun content(set: SuggestionSet) =
        StripGeometry.hasContent(SuggestionSlots.arrange(set, undoAsPill = true, bestInMiddle = true), set.idle)

    @Test fun whatCountsAsContent() {
        assertFalse(content(SuggestionSet()))                                       // trống
        assertFalse(content(SuggestionSet(nextWords = listOf("tôi", "em", "anh"), idle = true)))  // ô trống: chữ đệm
        assertTrue(content(SuggestionSet(literal = "xin", word = "xin", word2 = "xinh")))         // đang soạn
        assertTrue(content(SuggestionSet(nextWords = listOf("chào", "bạn", "anh"))))              // sau một từ
        assertTrue(content(SuggestionSet(nextWords = listOf("gmail.com", "yahoo.com"))))          // chip email @
        assertTrue(content(SuggestionSet(number = "1.000")))                                      // chip số
        assertTrue(content(SuggestionSet(math = "= 4")))                                          // phép tính
        assertTrue(content(SuggestionSet(paste = true, idle = true)))                             // thẻ Dán
        assertTrue(content(SuggestionSet(paste = true, clipChips = listOf(ClipChip(ClipChip.Kind.OTP, "482913", "OTP 482913")))))
        assertTrue(content(SuggestionSet(emojis = listOf("😀"))))
    }
    /** "Nút emoji" = Thanh trên: ô 😊 40 dp sát mép phải LUÔN trừ khỏi bar (cả khi có gợi ý), 📋 bên trái nó. */
    @Test fun emojiButtonAlwaysReserved() {
        val w = 411f; val zone = KeyLayout.STRIP_ZONE_W
        for (tools in listOf(true, false)) for (clip in listOf(true, false)) {
            val plain = StripGeometry.barRight(w, StripGeometry.CLIP_W, clip, tools)
            val emoji = StripGeometry.barRight(w, StripGeometry.CLIP_W, clip, tools, emojiButton = true)
            assertEquals(StripGeometry.EMOJI_W, plain - emoji, 0.001f)
            assertEquals(w - emoji, StripGeometry.rightExtraW(StripGeometry.CLIP_W, clip, tools, emojiButton = true), 0.001f)
        }
        // Có gợi ý (tools ẩn): chỉ còn 😊 bên phải; 3 slot vẫn bằng nhau.
        val l = FloatArray(3); val r = FloatArray(3)
        StripGeometry.thirds(StripGeometry.barLeft(zone, StripGeometry.TOOL_W, false),
            StripGeometry.barRight(w, StripGeometry.CLIP_W, true, false, emojiButton = true), l, r)
        assertEquals((w - zone - StripGeometry.EMOJI_W) / 3f, r[0] - l[0], 0.001f)
        assertEquals(w - StripGeometry.EMOJI_W, r[2], 0.001f)   // ô cuối sát 😊, 😊 sát mép phải
        assertEquals(0f, StripGeometry.rightExtraW(StripGeometry.CLIP_W, false, true), 0.001f)
    }

    /**
     * "Bạn đồng hành": ô nhân vật sát mép phải (không còn ⌄), không bao giờ chồng ô gợi ý / 😊 / 📋, cao đúng strip (không lấn
     * hàng phím) — điện thoại dọc, ngang, máy tính bảng; có / không 😊 📋.
     */
    @Test fun buddySlotNeverOverlapsChipsOrKeys() {
        val zone = KeyLayout.STRIP_ZONE_W
        for (w in listOf(320f, 360f, 393f, 412f, 480f, 640f, 800f, 915f, 1280f)) for (emoji in listOf(false, true)) for (clip in listOf(false, true)) {
            val bl = StripGeometry.buddyLeft(w)
            val br = bl + StripGeometry.BUDDY_W
            assertEquals(w, br, 0.001f)                              // sát mép phải, không vượt
            val barR = StripGeometry.barRight(w, StripGeometry.CLIP_W, clip, true, emoji, StripGeometry.BUDDY_W)
            assertEquals(bl, barR + (extras(clip, emoji) - StripGeometry.BUDDY_W), 0.001f)   // 😊/📋 nằm sát ô nhân vật
            val extras = StripGeometry.rightExtraW(StripGeometry.CLIP_W, clip, true, emoji, StripGeometry.BUDDY_W)
            assertTrue("$w: ô gợi ý kết thúc trước 😊/📋/nhân vật", barR <= bl - (extras - StripGeometry.BUDDY_W) + 0.001f)
            val l = FloatArray(5); val r = FloatArray(5)
            StripGeometry.cells(StripGeometry.barLeft(zone, StripGeometry.TOOL_W, true), barR, 3, l, r)
            for (i in 0 until 3) assertTrue("$w: ô $i chồng nhân vật", r[i] <= bl + 0.001f)
            // Không có nhân vật ⇒ y như cũ.
            assertEquals(StripGeometry.barRight(w, StripGeometry.CLIP_W, clip, true, emoji),
                barR + StripGeometry.BUDDY_W, 0.001f)
        }
    }

    private fun extras(clip: Boolean, emoji: Boolean) =
        StripGeometry.rightExtraW(StripGeometry.CLIP_W, clip, true, emoji, StripGeometry.BUDDY_W)

    /** Phil 20/10: nhân vật "bé quá" — ô cao hơn strip, tràn xuống hàng phím đầu (= iOS buddyFrame). */
    @Test fun buddyOverflowsIntoFirstKeyRow() {
        org.junit.Assert.assertEquals(66, StripGeometry.buddyHeight(40))
        org.junit.Assert.assertTrue(StripGeometry.buddyHeight(40) - 40 <= 0.7 * 40)
        org.junit.Assert.assertEquals(66, StripGeometry.buddyDrawWidth(40, 34))   // dáng ngủ nằm ngang không bị cắt
    }

    /**
     * "Nút ẩn bàn phím" (⌄ góc phải, mặc định TẮT — email người dùng 11/2026): TẮT ⇒ mọi khung y hệt khi chưa có
     * nút (0 chi phí bố cục); BẬT ⇒ ô ⌄ = ô ☰ (52 dp) sát mép phải, 😊 / 📋 / nhân vật / slot dời trái đúng bấy
     * nhiêu, không chồng ⌄ — điện thoại dọc, ngang, máy tính bảng; có / không gợi ý, 😊, 📋, nhân vật.
     */
    @Test fun dismissButtonReservesRightEdgeOnlyWhenOn() {
        val zone = KeyLayout.STRIP_ZONE_W
        assertEquals(0f, StripGeometry.dismissW(false), 0f)
        assertEquals(zone, StripGeometry.dismissW(true), 0f)
        for (w in listOf(320f, 360f, 411f, 640f, 915f, 1280f)) for (tools in listOf(true, false))
            for (clip in listOf(true, false)) for (emoji in listOf(true, false)) for (buddy in listOf(0f, StripGeometry.BUDDY_W)) {
                // Tắt: đúng con số cũ (không truyền dismiss).
                val off = StripGeometry.barRight(w, StripGeometry.CLIP_W, clip, tools, emoji, buddy, StripGeometry.dismissW(false))
                assertEquals(StripGeometry.barRight(w, StripGeometry.CLIP_W, clip, tools, emoji, buddy), off, 0f)
                assertEquals(StripGeometry.buddyLeft(w), StripGeometry.buddyLeft(w, StripGeometry.dismissW(false)), 0f)
                // Bật: bar co đúng 52 dp; ô nhân vật kết thúc ngay trái ⌄; slot cuối kết thúc trước 😊/📋/nhân vật/⌄.
                val dz = StripGeometry.dismissW(true)
                val on = StripGeometry.barRight(w, StripGeometry.CLIP_W, clip, tools, emoji, buddy, dz)
                assertEquals(zone, off - on, 0.001f)
                assertEquals(w - zone, StripGeometry.buddyLeft(w, dz) + StripGeometry.BUDDY_W, 0.001f)
                val extras = StripGeometry.rightExtraW(StripGeometry.CLIP_W, clip, tools, emoji, buddy, dz)
                assertEquals(w - on, extras, 0.001f)
                val l = FloatArray(5); val r = FloatArray(5)
                StripGeometry.cells(StripGeometry.barLeft(zone, StripGeometry.TOOL_W, tools), on, 3, l, r)
                assertTrue("$w: ô cuối chồng ⌄", r[2] <= w - zone + 0.001f)
                assertTrue("$w: ô cuối chồng 😊/📋/nhân vật", r[2] <= w - zone - (extras - zone) + 0.001f)
            }
    }

    /** ⌄ chỉ hiện khi bật + dải có chỗ (kể cả ô mật khẩu, dải trống) + không ở bàn emoji; Gợi ý tắt (dải 0) ⇒ không. */
    @Test fun dismissButtonVisibility() {
        assertTrue(StripGeometry.dismissShown(enabled = true, reserved = true, emojiPlane = false))
        assertFalse(StripGeometry.dismissShown(enabled = false, reserved = true, emojiPlane = false))   // mặc định tắt
        assertFalse(StripGeometry.dismissShown(enabled = true, reserved = false, emojiPlane = false))   // Thanh gợi ý tắt
        assertFalse(StripGeometry.dismissShown(enabled = true, reserved = true, emojiPlane = true))     // lưới emoji chiếm dải
    }

    /** Mặc định TẮT: cài đặt mới và prefs trống đều không có ⌄. */
    @Test fun dismissButtonDefaultsOff() {
        assertFalse(com.viettelex.keyboard.KeyboardSettings().keyboardDismissButton)
        assertFalse(com.viettelex.keyboard.KeyboardSettings.load { null }.keyboardDismissButton)
        assertTrue(com.viettelex.keyboard.KeyboardSettings.load {
            if (it == com.viettelex.keyboard.Keys.KEYBOARD_DISMISS_BUTTON) true else null }.keyboardDismissButton)
    }

    /** #175: 🎤 nằm trái 📋, cùng cụm công cụ mép phải — chừa đúng bề ngang, và ẩn cùng 📋 khi có gợi ý. */
    @Test fun micButtonSharesTheRightToolZone() {
        assertEquals(0f, StripGeometry.rightToolsW(clip = false, voice = false), 0.001f)
        assertEquals(StripGeometry.MIC_W, StripGeometry.rightToolsW(clip = false, voice = true), 0.001f)
        val both = StripGeometry.rightToolsW(clip = true, voice = true)
        assertEquals(StripGeometry.CLIP_W + StripGeometry.MIC_W, both, 0.001f)
        assertEquals(360f - both, StripGeometry.barRight(360f, both, clipButton = true, toolsShown = true), 0.001f)
        assertEquals(360f, StripGeometry.barRight(360f, both, clipButton = true, toolsShown = false), 0.001f)
    }

    /** #178: từ dài co chữ cho vừa ô trước, chỉ cắt "…" khi co hết mức vẫn không vừa. */
    @Test fun longWordShrinksBeforeItIsCut() {
        assertEquals(1f, StripGeometry.fitScale(80f, 100f), 0.001f)
        assertEquals(1f, StripGeometry.fitScale(100f, 100f), 0.001f)
        assertEquals(0.8f, StripGeometry.fitScale(125f, 100f), 0.001f)      // co vừa đủ
        assertEquals(StripGeometry.MIN_WORD_SCALE, StripGeometry.fitScale(400f, 100f), 0.001f)  // hết mức ⇒ cắt
        assertEquals(1f, StripGeometry.fitScale(0f, 100f), 0.001f)
    }
}
