package com.viettelex.android.ime

import android.annotation.SuppressLint
import android.content.Context
import android.graphics.drawable.GradientDrawable
import android.text.TextUtils
import android.util.TypedValue
import android.view.Gravity
import android.view.View
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import com.viettelex.keyboard.ClipboardHistory
import com.viettelex.keyboard.tr

/**
 * Bảng lịch sử clipboard — phủ đúng vùng phím (ImeRootView overlay), mở bằng nút 📋 trên
 * strip. Widget chuẩn (≤20 dòng, dựng lại khi mở/đổi — rẻ). Chạm dòng = dán; 📌 ghim/bỏ
 * ghim; ✕ xoá; "Xoá hết" giữ mục ghim; "ABC" về bàn phím chữ.
 */
@SuppressLint("ViewConstructor")
class ClipboardPane(context: Context, private val theme: ImeTheme) : FrameLayout(context) {

    interface Listener {
        fun onClipPick(text: String)
        fun onClipTogglePin(text: String)
        fun onClipRemove(text: String)
        fun onClipClearAll()
        fun onClipClose()
    }

    var listener: Listener? = null
    private val list = LinearLayout(context).apply { orientation = LinearLayout.VERTICAL }
    private val scroll = ScrollView(context).apply { isVerticalScrollBarEnabled = true; addView(list) }
    private fun dp(v: Float) = theme.dp(v).toInt()

    init {
        setBackgroundColor(theme.paneBg)
        isClickable = true              // chạm vùng trống không rơi xuống phím
        val col = LinearLayout(context).apply { orientation = LinearLayout.VERTICAL }
        val header = LinearLayout(context).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(dp(12f), dp(4f), dp(4f), dp(2f))
        }
        header.addView(label("Clipboard", 15f, bold = true), LinearLayout.LayoutParams(0, -2, 1f))
        header.addView(button(tr("Xoá hết")) { listener?.onClipClearAll() })
        header.addView(button("ABC") { listener?.onClipClose() })
        col.addView(header, LinearLayout.LayoutParams(-1, -2))
        col.addView(scroll, LinearLayout.LayoutParams(-1, 0, 1f))
        addView(col, LayoutParams(-1, -1))
    }

    /** Dựng lại danh sách (ghim trên, mới nhất trước). */
    fun show(items: List<ClipboardHistory.Item>, enabled: Boolean, incognito: Boolean) {
        list.removeAllViews()
        if (items.isEmpty()) {
            val msg = when {
                !enabled -> tr("Lịch sử clipboard đang tắt — bật trong app VietTelex › Tính Năng › Riêng tư & sao lưu.")
                incognito -> tr("Đang ẩn danh — không lưu mục mới.")
                else -> tr("Chưa có mục nào — copy gì đó rồi mở lại. Ghim để giữ lâu.")
            }
            list.addView(label(msg, 14f, alpha = 0.6f).apply {
                setPadding(dp(16f), dp(16f), dp(16f), dp(16f)); gravity = Gravity.CENTER
            }, LinearLayout.LayoutParams(-1, -2))
            return
        }
        for (it in items) list.addView(row(it))
        if (incognito) list.addView(label(tr("Đang ẩn danh — không lưu mục mới."), 12f, alpha = 0.6f).apply {
            setPadding(dp(16f), dp(6f), dp(16f), dp(8f))
        })
    }

    fun scrollTop() { scroll.scrollTo(0, 0) }

    /** Thông báo ngắn đầu danh sách (vd đã đủ số mục ghim miễn phí). */
    fun showNotice(msg: String) {
        list.addView(label(msg, 13f, alpha = 0.8f).apply {
            setPadding(dp(16f), dp(6f), dp(16f), dp(6f))
        }, 0, LinearLayout.LayoutParams(-1, -2))
        scrollTop()
    }

    private fun row(item: ClipboardHistory.Item): View {
        val r = LinearLayout(context).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            background = GradientDrawable().apply { cornerRadius = theme.dp(8f); setColor(theme.keyFill) }
            setPadding(dp(12f), dp(2f), dp(2f), dp(2f))
            minimumHeight = dp(44f)
        }
        val text = label(item.text.replace('\n', ' ').take(300), 15f).apply {
            maxLines = 2; ellipsize = TextUtils.TruncateAt.END
            setPadding(0, dp(6f), dp(4f), dp(6f))
            contentDescription = tr("Dán: %s", item.text.take(80))
        }
        r.addView(text, LinearLayout.LayoutParams(0, -2, 1f))
        r.setOnClickListener { listener?.onClipPick(item.text) }
        // Icon thay chữ "Ghim" (tester 15/11/2026: gọn hơn, nhường chỗ cho nội dung) — như iOS pin / pin.fill.
        r.addView(iconButton(if (item.pinned) ImeIcons.PIN_FILL else ImeIcons.PIN, alpha = if (item.pinned) 1f else 0.6f) {
            listener?.onClipTogglePin(item.text)
        }.apply { contentDescription = if (item.pinned) tr("Bỏ ghim") else tr("Ghim") })
        r.addView(iconButton(ImeIcons.DELETE_X, alpha = 0.6f, size = 22f) { listener?.onClipRemove(item.text) }
            .apply { contentDescription = tr("Xoá mục") })
        val lp = LinearLayout.LayoutParams(-1, -2).apply { setMargins(dp(8f), dp(3f), dp(8f), dp(3f)) }
        r.layoutParams = lp
        return r
    }

    private fun label(s: String, sp: Float, bold: Boolean = false, alpha: Float = 1f) = TextView(context).apply {
        text = s
        setTextSize(TypedValue.COMPLEX_UNIT_SP, sp)
        setTextColor(theme.withAlpha(theme.ink, alpha))
        if (bold) setTypeface(typeface, android.graphics.Typeface.BOLD)
    }

    /** Nút icon vuông 40 dp (vùng chạm ≥ 40 dp) — vẽ [ImeIcons] màu chữ của theme. */
    private fun iconButton(id: Int, alpha: Float, size: Float = 20f, onClick: () -> Unit) = object : View(context) {
        private val paint = android.graphics.Paint(android.graphics.Paint.ANTI_ALIAS_FLAG).apply {
            color = theme.withAlpha(theme.ink, alpha)
        }
        override fun onDraw(c: android.graphics.Canvas) {
            ImeIcons.draw(c, id, width / 2f, height / 2f, dp(size).toFloat(), paint)
        }
    }.apply {
        layoutParams = LinearLayout.LayoutParams(dp(40f), dp(40f))
        isClickable = true
        setOnClickListener { onClick() }
    }

    private fun button(s: String, alpha: Float = 0.85f, onClick: () -> Unit) = label(s, 14f, alpha = alpha).apply {
        gravity = Gravity.CENTER
        minWidth = dp(44f); minHeight = dp(40f)
        setPadding(dp(10f), 0, dp(10f), 0)
        setOnClickListener { onClick() }
    }
}
