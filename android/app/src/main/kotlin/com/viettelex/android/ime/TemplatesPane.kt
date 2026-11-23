package com.viettelex.android.ime

import android.graphics.Canvas
import android.text.TextPaint
import android.text.TextUtils
import android.view.MotionEvent
import android.view.VelocityTracker
import android.view.ViewConfiguration
import android.widget.OverScroller
import com.viettelex.keyboard.TemplateItem
import kotlin.math.abs

/**
 * Plane mẫu câu / công cụ (☰, spec §10.2): lưới ô cột đều, khe đều ([TemplatesMenu.grid] —
 * tester 11/2026: chip rộng hẹp lộn xộn, hàng không thẳng), cuộn dọc, vẽ trên Canvas của
 * [KeyboardView]. Có label ⇒ chỉ hiện label, không thì text; dài quá ô thì cắt "…".
 * Đầu bảng (khi cả Mẫu câu lẫn Công cụ bật): thanh chọn [Mẫu câu | Công cụ] + ⚙️ bên phải,
 * đứng yên khi cuộn. Không thanh chọn ⇒ ⚙️ là ô cuối lưới mẫu câu. Hàng đáy do KeyboardView vẽ.
 */
class TemplatesPane(
    private val host: KeyboardView,
    private val theme: ImeTheme,
    private val feedback: Feedback,
) {
    /** [extraId] != null: ô công cụ / đoạn thanh chọn — chạm gửi id qua [KeyboardView.paneExtra]. */
    private class Chip(val item: TemplateItem?, val shown: String, val extraId: String? = null, val icon: Int = -1) {
        var l = 0f; var t = 0f; var r = 0f; var b = 0f
    }

    private val d = theme.density
    private var items: List<TemplateItem> = emptyList()
    /** Ô công cụ (hiển thị, id) — rỗng ở tab Mẫu câu. */
    private var extras: List<Pair<String, String>> = emptyList()
    private var showGear = true
    private var segmented = false
    private var toolsTab = false
    /** Nút nhanh đầu bảng (#175): id [TemplatesMenu.quick]. */
    private var quick: List<String> = emptyList()
    private var chips: List<Chip> = emptyList()
    /** Thanh chọn + ⚙️ (không cuộn). */
    private var header: List<Chip> = emptyList()
    private var headerH = 0f
    private var width = 0f
    private var bottom = 0f
    private var contentH = 0f
    private var scrollY = 0f
    private val scroller = OverScroller(host.context)
    private var velocity: VelocityTracker? = null
    private val touchSlop = ViewConfiguration.get(host.context).scaledTouchSlop
    private val maxFling = ViewConfiguration.get(host.context).scaledMaximumFlingVelocity.toFloat()

    private val textPaint = TextPaint(theme.text(16f))
    private val textOff = theme.centerOffset(textPaint)
    private val segPaint = TextPaint(theme.text(14f, medium = true))
    private val segOff = theme.centerOffset(segPaint)
    private val chipPaint = theme.fill(theme.keyFill)
    private val selPaint = theme.fill(theme.chip)
    private val iconPaint = theme.fill(theme.ink)

    private var ptr = -1
    private var dragging = false
    private var downX = 0f; private var downY = 0f; private var lastY = 0f

    fun setItems(list: List<TemplateItem>) {
        if (list == items) return
        items = list
        width = 0f   // ép dàn lại ở layout kế
    }

    /**
     * Đổi nội dung: [list] = ô công cụ (tab Công cụ), [gear] = có ⚙️, [segmented] = có thanh
     * chọn, [toolsTab] = đoạn đang chọn là Công cụ.
     */
    fun setExtras(list: List<Pair<String, String>>, gear: Boolean, segmented: Boolean = false, toolsTab: Boolean = false) {
        if (list == extras && gear == showGear && segmented == this.segmented && toolsTab == this.toolsTab) return
        extras = list; showGear = gear; this.segmented = segmented; this.toolsTab = toolsTab
        width = 0f
    }

    fun setQuick(list: List<String>) {
        if (list == quick) return
        quick = list
        width = 0f
    }

    fun resetScroll() { scrollY = 0f; scroller.forceFinished(true) }

    fun contains(x: Float, y: Float) = y < bottom

    fun layout(w: Float, paneBottom: Float) {
        if (w == width && paneBottom == bottom && (chips.isNotEmpty() || header.isNotEmpty())) return
        width = w; bottom = paneBottom
        val padH = 6 * d; val padV = 7 * d
        val fm = textPaint.fontMetrics
        val chipH = padV * 2 + (fm.descent - fm.ascent)
        val gap = 6 * d
        val left = 6 * d; val right = w - 6 * d
        // Đầu bảng: [Mẫu câu | Công cụ] giãn hết, ⚙️ vuông bên phải (cùng cao ô lưới).
        // #175: nút nhanh 📋 / 🎤 — có thanh chọn ⇒ ô vuông giữa thanh chọn và ⚙️; không ⇒ giãn đều cả hàng, kèm nhãn.
        val head = ArrayList<Chip>(5)
        val hasHeader = segmented || quick.isNotEmpty()
        if (hasHeader) {
            val top = 8 * d
            val sq = chipH * 1.4f
            val headGear = showGear && (segmented || extras.isEmpty())
            var x = right
            if (headGear) { head += Chip(null, "⚙️").apply { l = x - sq; r = x; t = top; b = top + chipH }; x -= sq + gap }
            if (segmented) {
                for (id in quick.asReversed()) {
                    head += Chip(null, "", id, quickIcon(id)).apply { l = x - sq; r = x; t = top; b = top + chipH }
                    x -= sq + gap
                }
                val segs = TemplatesMenu.segments()
                val segW = (x + gap - left) / segs.size
                for ((i, sg) in segs.withIndex()) {
                    head += Chip(null, sg.first, sg.second).apply {
                        l = left + i * segW; r = l + segW; t = top; b = top + chipH
                    }
                }
            } else {
                val each = (x + gap - left - gap * quick.size) / quick.size
                for ((i, id) in quick.withIndex()) {
                    head += Chip(null, fit(TemplatesMenu.quickLabel(id), each - 2 * padH - 26 * d), id, quickIcon(id)).apply {
                        l = left + i * (each + gap); r = l + each; t = top; b = top + chipH
                    }
                }
            }
            headerH = top + chipH
        } else headerH = 0f
        header = head
        // Lưới: công cụ (giãn hàng cuối) hoặc mẫu câu (+ ⚙️ cuối khi không có thanh chọn).
        val list = ArrayList<Chip>(extras.size + items.size + 1)
        val tools = extras.isNotEmpty()
        val gearCell = !hasHeader && showGear && !tools
        val n = if (tools) extras.size else items.size + if (gearCell) 1 else 0
        val wDp = w / d
        val cols = if (tools) TemplatesMenu.toolCols(wDp) else TemplatesMenu.snippetCols(wDp)
        val cells = TemplatesMenu.grid(n, cols, left, right, headerH + 8 * d, chipH, gap, stretchLast = tools)
        for ((i, c) in cells.withIndex()) {
            val maxText = c.r - c.l - 2 * padH
            val chip = when {
                tools -> extras[i].let { Chip(null, fit(it.first, maxText), it.second) }
                i < items.size -> items[i].let {
                    val s = if (it.label.isEmpty()) it.text else it.label
                    Chip(it, fit(s.replace('\n', ' '), maxText))
                }
                else -> Chip(null, "⚙️")
            }
            chip.l = c.l; chip.t = c.t; chip.r = c.r; chip.b = c.b
            list += chip
        }
        chips = list
        contentH = (cells.lastOrNull()?.b ?: headerH) + 8 * d
        scrollY = scrollY.coerceIn(0f, maxScroll())
    }

    private fun quickIcon(id: String) = if (id == TemplatesMenu.QUICK_VOICE) ImeIcons.MIC else ImeIcons.CLIPBOARD

    private fun fit(s: String, maxW: Float): String =
        TextUtils.ellipsize(s, textPaint, maxOf(maxW, 0f), TextUtils.TruncateAt.END).toString()

    private fun maxScroll() = maxOf(0f, contentH - bottom)

    fun draw(c: Canvas) {
        val rad = 8 * d
        // Đầu bảng đứng yên: nền chung một khối, đoạn đang chọn sáng màu chip.
        if (header.isNotEmpty()) {
            val segs = header.filter { it.extraId != null && it.icon < 0 }
            if (segs.isNotEmpty()) {
                c.drawRoundRect(segs.first().l, segs.first().t, segs.last().r, segs.last().b, rad, rad, chipPaint)
                for (s in segs) {
                    val on = (s.extraId == TemplatesMenu.TOOLS_ENTRY) == toolsTab
                    if (on) c.drawRoundRect(s.l + 2 * d, s.t + 2 * d, s.r - 2 * d, s.b - 2 * d, rad - 2 * d, rad - 2 * d, selPaint)
                    segPaint.alpha = if (on) 255 else 170
                    c.drawText(s.shown, (s.l + s.r) / 2, (s.t + s.b) / 2 + segOff, segPaint)
                }
            }
            header.firstOrNull { it.extraId == null }?.let { g ->
                c.drawRoundRect(g.l, g.t, g.r, g.b, rad, rad, chipPaint)
                c.drawText(g.shown, (g.l + g.r) / 2, (g.t + g.b) / 2 + textOff, textPaint)
            }
            for (q in header) {
                if (q.icon < 0) continue
                c.drawRoundRect(q.l, q.t, q.r, q.b, rad, rad, chipPaint)
                val cy = (q.t + q.b) / 2; val ic = 20 * d
                iconPaint.color = textPaint.color
                if (q.shown.isEmpty()) ImeIcons.draw(c, q.icon, (q.l + q.r) / 2, cy, ic, iconPaint)
                else {
                    // icon + nhãn canh giữa ô như một khối
                    val tw = segPaint.measureText(q.shown); val sp = 6 * d
                    val x0 = (q.l + q.r) / 2 - (ic + sp + tw) / 2
                    ImeIcons.draw(c, q.icon, x0 + ic / 2, cy, ic, iconPaint)
                    segPaint.alpha = 255
                    c.drawText(q.shown, x0 + ic + sp + tw / 2, cy + segOff, segPaint)
                }
            }
        }
        c.save()
        c.clipRect(0f, headerH, width, bottom)
        val list = chips
        for (i in list.indices) {
            val ch = list[i]
            val t = ch.t - scrollY; val b = ch.b - scrollY
            if (b < headerH || t > bottom) continue
            c.drawRoundRect(ch.l, t, ch.r, b, rad, rad, chipPaint)
            c.drawText(ch.shown, (ch.l + ch.r) / 2, (t + b) / 2 + textOff, textPaint)
        }
        c.restore()
    }

    fun track(e: MotionEvent) { if (ptr >= 0) velocity?.addMovement(e) }

    fun down(pid: Int, x: Float, y: Float) {
        if (ptr >= 0) return
        ptr = pid; dragging = false
        downX = x; downY = y; lastY = y
        scroller.forceFinished(true)
        velocity?.recycle(); velocity = VelocityTracker.obtain()
    }

    fun move(pid: Int, x: Float, y: Float) {
        if (pid != ptr) return
        if (!dragging && abs(y - downY) > touchSlop) { dragging = true; lastY = y }
        if (dragging) {
            val ny = (scrollY + (lastY - y)).coerceIn(0f, maxScroll())
            lastY = y
            if (ny != scrollY) { scrollY = ny; host.invalidate() }
        }
    }

    fun up(pid: Int, x: Float, y: Float, cancelled: Boolean) {
        if (pid != ptr) return
        ptr = -1
        val v = velocity
        if (dragging && v != null) {
            v.computeCurrentVelocity(1000, maxFling)
            scroller.fling(0, scrollY.toInt(), 0, (-v.getYVelocity(pid)).toInt(), 0, 0, 0, maxScroll().toInt())
            host.postInvalidateOnAnimation()
        } else if (!cancelled) {
            val inHeader = downY < headerH + 3 * d && header.isNotEmpty()
            val cy = if (inHeader) downY else downY + scrollY
            val hit = (if (inHeader) header else chips)
                .firstOrNull { downX >= it.l - 3 * d && downX < it.r + 3 * d && cy >= it.t - 4 * d && cy < it.b + 4 * d }
            if (hit != null && abs(x - downX) < 24 * d && abs(y - downY) < 24 * d) {
                val item = hit.item
                val extra = hit.extraId
                if (extra != null) { feedback.click(Feedback.MODIFIER, host); host.paneExtra(extra) }
                else if (item == null) { feedback.click(Feedback.MODIFIER, host); host.paneGear() }
                else { feedback.click(Feedback.LETTER, host); host.paneTemplate(item) }
            }
        }
        velocity?.recycle(); velocity = null
        dragging = false
    }

    fun computeScroll() {
        if (scroller.computeScrollOffset()) {
            scrollY = scroller.currY.toFloat().coerceIn(0f, maxScroll())
            host.postInvalidateOnAnimation()
        }
    }

    fun onHidden() {
        scroller.forceFinished(true)
        velocity?.recycle(); velocity = null
        ptr = -1
    }
}
