package com.viettelex.android.ime

import com.viettelex.keyboard.KeyboardSettings
import com.viettelex.keyboard.TextTool
import com.viettelex.keyboard.tr
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.abs

/**
 * ☰ hiện khi Mẫu câu HOẶC Công cụ văn bản bật; Mẫu câu tắt ⇒ ☰ mở thẳng công cụ (user 10/2026).
 * Tester 11/2026: thanh chọn [Mẫu câu | Công cụ] thay chip "⚒️ Công cụ" / "‹ Mẫu câu"; lưới cột đều.
 */
class TemplatesMenuTest {
    @Test fun leftZoneMatrixWithPlusGate() {
        for (templates in listOf(false, true)) for (toolsSwitch in listOf(false, true))
            for (unlocked in listOf(false, true)) for (secure in listOf(false, true)) {
                val s = KeyboardSettings(textToolsEnabled = toolsSwitch)
                val z = TemplatesMenu.leftZone(templates, s.textToolsActive(unlocked, secure))
                val want = when {
                    templates -> TemplatesMenu.LeftZone.TEMPLATES
                    toolsSwitch && unlocked && !secure -> TemplatesMenu.LeftZone.TOOLS
                    else -> TemplatesMenu.LeftZone.NONE
                }
                assertEquals("templates=$templates tools=$toolsSwitch unlocked=$unlocked secure=$secure", want, z)
            }
    }

    private val toolLabels get() = TextTool.entries.map { it.label } + tr("Thêm dấu")

    /** Chạm ☰ ở chế độ chỉ-công-cụ: lưới = danh sách công cụ, không thanh chọn / ⚙️. */
    @Test fun toolsOnlyTapOpensToolsDirectly() {
        val p = TemplatesMenu.pane(toolsMode = false, templatesEnabled = false, textTools = true, translate = true)
        assertFalse(p.showTemplates); assertFalse(p.gear); assertFalse(p.segmented)
        assertEquals(toolLabels + tr("Dịch"), p.tools.map { it.first })
        assertEquals(TemplatesMenu.TOOLS_ADD_TONES, p.tools[TextTool.entries.size].second)
        assertEquals(TemplatesMenu.TOOLS_TRANSLATE, p.tools.last().second)
        assertTrue(p.tools.dropLast(2).all { TextTool.byId(it.second) != null })
    }

    /** Mẫu câu bật + công cụ: thanh chọn, ⚙️; không còn chip "⚒️ Công cụ" / "‹ Mẫu câu" trong lưới. */
    @Test fun segmentedHeaderReplacesChips() {
        val grid = TemplatesMenu.pane(toolsMode = false, templatesEnabled = true, textTools = true, translate = false)
        assertTrue(grid.showTemplates); assertTrue(grid.gear); assertTrue(grid.segmented)
        assertTrue(grid.tools.isEmpty())
        val tools = TemplatesMenu.pane(toolsMode = true, templatesEnabled = true, textTools = true, translate = false)
        assertFalse(tools.showTemplates); assertTrue(tools.segmented); assertTrue(tools.gear)
        assertEquals(toolLabels, tools.tools.map { it.first })
        assertFalse(tools.tools.any { it.second == TemplatesMenu.TOOLS_BACK || it.second == TemplatesMenu.TOOLS_ENTRY })
        assertEquals(listOf(TemplatesMenu.TOOLS_BACK, TemplatesMenu.TOOLS_ENTRY), TemplatesMenu.segments().map { it.second })
        val noTools = TemplatesMenu.pane(toolsMode = true, templatesEnabled = true, textTools = false, translate = false)
        assertTrue(noTools.showTemplates); assertFalse(noTools.segmented); assertTrue(noTools.tools.isEmpty())
    }

    /** Lưới: cột bằng nhau, khe ngang = khe dọc, phủ đúng bề ngang; công cụ giãn hàng cuối (không ô trống). */
    @Test fun gridAlignedEqualGaps() {
        val l = 6f; val r = 384f; val gap = 6f; val h = 34f
        for (n in 1..23) for (cols in 3..5) for (stretch in listOf(false, true)) {
            val cells = TemplatesMenu.grid(n, cols, l, r, 10f, h, gap, stretch)
            assertEquals(n, cells.size)
            val rows = cells.groupBy { it.t }.toSortedMap()
            val tops = rows.keys.toList()
            for (i in 1 until tops.size) assertEquals(h + gap, tops[i] - tops[i - 1], 0.01f)
            val colW = (r - l - gap * (cols - 1)) / cols
            for ((_, row) in rows) {
                assertTrue(row.size <= cols)
                assertEquals(l, row.first().l, 0.01f)
                for (i in 1 until row.size) assertEquals(gap, row[i].l - row[i - 1].r, 0.01f)
                assertTrue(row.all { abs(it.b - it.t - h) < 0.01f })
                if (row.size == cols || stretch) assertEquals(r, row.last().r, 0.01f)
                if (row.size == cols || !stretch) assertTrue(row.all { abs(it.r - it.l - colW) < 0.01f })
            }
        }
        assertEquals(5, TemplatesMenu.snippetCols(392f))
        assertEquals(5, TemplatesMenu.snippetCols(360f))
        assertEquals(3, TemplatesMenu.toolCols(392f))
    }

    /** #175: thanh gợi ý có chữ thì ẩn 📋 / 🎤 ⇒ đầu bảng ☰ phải có lối vào cả hai, đúng thứ tự, chỉ khi dùng được. */
    @Test fun quickButtonsFollowAvailability() {
        assertEquals(listOf(TemplatesMenu.QUICK_CLIPBOARD, TemplatesMenu.QUICK_VOICE), TemplatesMenu.quick(clip = true, voice = true))
        assertEquals(listOf(TemplatesMenu.QUICK_VOICE), TemplatesMenu.quick(clip = false, voice = true))
        assertEquals(listOf(TemplatesMenu.QUICK_CLIPBOARD), TemplatesMenu.quick(clip = true, voice = false))
        assertTrue(TemplatesMenu.quick(clip = false, voice = false).isEmpty())
    }
}
