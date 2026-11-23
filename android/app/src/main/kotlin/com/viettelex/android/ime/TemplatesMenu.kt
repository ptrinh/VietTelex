package com.viettelex.android.ime

import com.viettelex.keyboard.tr

/**
 * Ô ☰ mép trái thanh gợi ý + nội dung bảng mẫu câu / công cụ — THUẦN (TemplatesMenuTest).
 * Song sinh iOS KeyboardView.leftZone / buildTemplates / TemplateGrid.
 *
 * ☰ hiện khi Mẫu câu HOẶC Công cụ văn bản bật (user 10/2026: tắt Mẫu câu làm mất lối vào
 * Công cụ). Mẫu câu tắt + Công cụ bật ⇒ chạm ☰ mở THẲNG danh sách công cụ (không thanh
 * chọn, không ⚙️). Cả hai bật ⇒ đầu bảng là thanh chọn [Mẫu câu | Công cụ] + ⚙️ bên phải
 * (tester 11/2026: chip "⚒️ Công cụ" / "‹ Mẫu câu" trông như trùng chức năng với ☰ — bỏ
 * hai chip, thay bằng thanh chọn). `toolsEnabled` = Plus mở khoá + công tắc + không phải ô
 * mật khẩu (KeyboardSettings.textToolsActive).
 *
 * Bố cục: lưới cột đều, khe đều ([grid]) — mẫu câu [snippetCols] cột (điện thoại 5), công
 * cụ [toolCols] cột (điện thoại 3); hàng công cụ cuối thiếu ô thì các ô giãn đều phủ kín.
 */
object TemplatesMenu {
    enum class LeftZone { TEMPLATES, TOOLS, NONE }

    fun leftZone(templatesEnabled: Boolean, toolsEnabled: Boolean): LeftZone = when {
        templatesEnabled -> LeftZone.TEMPLATES
        toolsEnabled -> LeftZone.TOOLS
        else -> LeftZone.NONE
    }

    /** id đoạn "Công cụ" của thanh chọn. */
    const val TOOLS_ENTRY = "tools"
    /** id đoạn "Mẫu câu" của thanh chọn. */
    const val TOOLS_BACK = "back"
    const val TOOLS_TRANSLATE = "translate"
    /** Ô "Thêm dấu" (AddTones, PlusGate SENTENCE_DIACRITICS) — đi cùng nhóm công cụ văn bản. */
    const val TOOLS_ADD_TONES = "addTones"

    enum class Tab { TEMPLATES, TOOLS }

    /** id nút nhanh đầu bảng ☰ (#175): lịch sử clipboard, gõ giọng nói. */
    const val QUICK_CLIPBOARD = "quickClipboard"
    const val QUICK_VOICE = "quickVoice"

    /**
     * #175: thanh gợi ý có chữ thì ẩn 📋 / 🎤 (#113) ⇒ đang gõ dở không còn lối mở. Đầu bảng ☰ luôn có hai nút
     * này (theo thứ tự) khi tính năng tương ứng dùng được: [clip] = lịch sử clipboard bật, [voice] = máy có bộ
     * nhận giọng nói và không phải ô mật khẩu.
     */
    fun quick(clip: Boolean, voice: Boolean): List<String> = buildList {
        if (clip) add(QUICK_CLIPBOARD)
        if (voice) add(QUICK_VOICE)
    }

    /** Nhãn nút nhanh (đầu bảng không có thanh chọn ⇒ nút giãn, hiện icon + nhãn). */
    fun quickLabel(id: String): String = if (id == QUICK_VOICE) tr("Giọng nói") else tr("Clipboard")

    /**
     * Nội dung bảng: [tab] đang hiện; [segmented] = có thanh chọn [Mẫu câu | Công cụ] ở đầu;
     * [tools] = ô công cụ (nhãn, id) khi [tab] = TOOLS; [gear] = có nút ⚙️ (quản lý mẫu câu).
     */
    data class Pane(val tab: Tab, val segmented: Boolean, val tools: List<Pair<String, String>>, val gear: Boolean) {
        val showTemplates: Boolean get() = tab == Tab.TEMPLATES
    }

    /** Ô công cụ theo thứ tự (cùng [EditPanel.toolCells]): TextTool…, Thêm dấu, Dịch. */
    fun toolItems(textTools: Boolean, translate: Boolean): List<Pair<String, String>> =
        EditPanel.toolCells(textTools, translate).map { (label, ins) ->
            label to when (ins) {
                EditPanel.ADD_TONES_INSERT -> TOOLS_ADD_TONES
                EditPanel.TRANSLATE_INSERT -> TOOLS_TRANSLATE
                else -> ins.removePrefix(EditPanel.TOOL_PREFIX)
            }
        }

    fun pane(toolsMode: Boolean, templatesEnabled: Boolean, textTools: Boolean, translate: Boolean): Pane {
        val anyTools = textTools || translate
        val tab = if ((toolsMode || !templatesEnabled) && anyTools) Tab.TOOLS else Tab.TEMPLATES
        return Pane(tab, segmented = templatesEnabled && anyTools,
            tools = if (tab == Tab.TOOLS) toolItems(textTools, translate) else emptyList(),
            gear = templatesEnabled)
    }

    /** Hai đoạn của thanh chọn: (nhãn, id). */
    fun segments(): List<Pair<String, String>> = listOf(tr("Mẫu câu") to TOOLS_BACK, tr("Công cụ") to TOOLS_ENTRY)

    /** Số cột lưới mẫu câu theo bề ngang (dp): điện thoại 5, rộng hơn thêm cột, 4…8. */
    fun snippetCols(widthDp: Float): Int = (widthDp / 72f).toInt().coerceIn(4, 8)

    /** Số cột lưới công cụ: điện thoại 3, tablet / ngang 4. */
    fun toolCols(widthDp: Float): Int = if (widthDp >= 560f) 4 else 3

    /** Một ô lưới (px). */
    data class Cell(val l: Float, val t: Float, val r: Float, val b: Float)

    /**
     * Lưới [n] ô, [cols] cột bằng nhau phủ đúng [left]…[right], khe ngang = khe dọc = [gap],
     * hàng cao [cellH] bắt đầu từ [top]. Hàng cuối thiếu ô: [stretchLast] ⇒ các ô giãn đều phủ
     * kín hàng (công cụ — không chỗ trống), không thì giữ đúng cột, canh trái (danh sách mẫu câu).
     */
    fun grid(n: Int, cols: Int, left: Float, right: Float, top: Float, cellH: Float, gap: Float,
             stretchLast: Boolean): List<Cell> {
        if (n <= 0 || cols <= 0) return emptyList()
        val out = ArrayList<Cell>(n)
        val colW = (right - left - gap * (cols - 1)) / cols
        val sizes = EditPanel.rowSizes(n, cols)
        for ((r, k) in sizes.withIndex()) {
            val t = top + r * (cellH + gap)
            val w = if (k < cols && stretchLast) (right - left - gap * (k - 1)) / k else colW
            for (i in 0 until k) {
                val l = left + i * (w + gap)
                out += Cell(l, t, l + w, t + cellH)
            }
        }
        return out
    }
}
