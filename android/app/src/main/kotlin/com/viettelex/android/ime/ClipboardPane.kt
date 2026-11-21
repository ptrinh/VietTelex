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
import android.view.ViewGroup
import android.widget.BaseAdapter
import android.widget.ListView
import android.widget.TextView
import com.viettelex.keyboard.ClipboardHistory
import com.viettelex.keyboard.tr

/**
 * Bảng lịch sử clipboard — phủ đúng vùng phím (ImeRootView overlay), mở bằng nút 📋 trên
 * strip. ListView tái dùng dòng (lịch sử tới 100 mục — chỉ dựng các dòng đang thấy). Chạm dòng = dán; 📌 ghim/bỏ
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
    private sealed class Row {
        data class Note(val text: String, val sp: Float, val alpha: Float, val center: Boolean) : Row()
        data class Clip(val item: ClipboardHistory.Item) : Row()
    }
    private var rows: List<Row> = emptyList()
    private val adapter = object : BaseAdapter() {
        override fun getCount() = rows.size
        override fun getItem(position: Int): Any = rows[position]
        override fun getItemId(position: Int) = position.toLong()
        override fun getViewTypeCount() = 2
        override fun getItemViewType(position: Int) = if (rows[position] is Row.Clip) 1 else 0
        override fun isEnabled(position: Int) = false       // dòng tự bắt chạm
        override fun areAllItemsEnabled() = false
        override fun getView(position: Int, convertView: View?, parent: ViewGroup?): View =
            when (val r = rows[position]) {
                is Row.Clip -> ((convertView as? ClipRow) ?: ClipRow()).also { it.bind(r.item) }
                is Row.Note -> ((convertView as? TextView) ?: label("", r.sp)).also { bindNote(it, r) }
            }
    }
    private val scroll = ListView(context).apply {
        isVerticalScrollBarEnabled = true
        divider = null; dividerHeight = 0
        selector = android.graphics.drawable.ColorDrawable(0)
        cacheColorHint = 0
        adapter = this@ClipboardPane.adapter
    }
    /** Test: số dòng của danh sách / số dòng view đang được dựng. */
    internal val rowCount: Int get() = rows.size
    internal val builtRowCount: Int get() = scroll.childCount
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

    /** Nạp lại danh sách (ghim trên, mới nhất trước). */
    fun show(items: List<ClipboardHistory.Item>, enabled: Boolean, incognito: Boolean) {
        rows = if (items.isEmpty()) {
            val msg = when {
                !enabled -> tr("Lịch sử clipboard đang tắt — bật trong app VietTelex › Tính Năng › Riêng tư & sao lưu.")
                incognito -> tr("Đang ẩn danh — không lưu mục mới.")
                else -> tr("Chưa có mục nào — copy gì đó rồi mở lại. Ghim để giữ lâu.")
            }
            listOf(Row.Note(msg, 14f, 0.6f, center = true))
        } else {
            items.map { Row.Clip(it) } +
                (if (incognito) listOf(Row.Note(tr("Đang ẩn danh — không lưu mục mới."), 12f, 0.6f, center = false)) else emptyList())
        }
        adapter.notifyDataSetChanged()
    }

    fun scrollTop() { scroll.setSelection(0) }

    /** Thông báo ngắn đầu danh sách (vd đã đủ số mục ghim miễn phí). */
    fun showNotice(msg: String) {
        rows = listOf<Row>(Row.Note(msg, 13f, 0.8f, center = false)) + rows
        adapter.notifyDataSetChanged()
        scrollTop()
    }

    private fun bindNote(v: TextView, r: Row.Note) {
        v.text = r.text
        v.setTextSize(TypedValue.COMPLEX_UNIT_SP, r.sp)
        v.setTextColor(theme.withAlpha(theme.ink, r.alpha))
        v.gravity = if (r.center) Gravity.CENTER else Gravity.START
        val pad = if (r.center) dp(16f) else dp(6f)
        v.setPadding(dp(16f), pad, dp(16f), if (r.center) pad else dp(8f))
    }

    /** Một dòng mục clipboard — view dựng một lần, [bind] khi tái dùng. Lề ngoài nằm ở khung bọc (ListView bỏ margin). */
    private inner class ClipRow : FrameLayout(context) {
        private var item: ClipboardHistory.Item? = null
        private val text = label("", 15f).apply {
            maxLines = 2; ellipsize = TextUtils.TruncateAt.END
            setPadding(0, dp(6f), dp(4f), dp(6f))
        }
        private var pinId = ImeIcons.PIN
        private var pinAlpha = 0.6f
        // Icon thay chữ "Ghim" (tester 15/11/2026: gọn hơn, nhường chỗ cho nội dung) — như iOS pin / pin.fill.
        private val pin = iconButton({ pinId }, { pinAlpha }) { item?.let { listener?.onClipTogglePin(it.text) } }
        private val del = iconButton({ ImeIcons.DELETE_X }, { 0.6f }, size = 22f) { item?.let { listener?.onClipRemove(it.text) } }
            .apply { contentDescription = tr("Xoá mục") }

        init {
            val r = LinearLayout(context).apply {
                orientation = LinearLayout.HORIZONTAL
                gravity = Gravity.CENTER_VERTICAL
                background = GradientDrawable().apply { cornerRadius = theme.dp(8f); setColor(theme.keyFill) }
                setPadding(dp(12f), dp(2f), dp(2f), dp(2f))
                minimumHeight = dp(44f)
                setOnClickListener { item?.let { listener?.onClipPick(it.text) } }
            }
            r.addView(text, LinearLayout.LayoutParams(0, -2, 1f))
            r.addView(pin); r.addView(del)
            addView(r, LayoutParams(-1, -2).apply { setMargins(dp(8f), dp(3f), dp(8f), dp(3f)) })
        }

        fun bind(it: ClipboardHistory.Item) {
            item = it
            text.text = it.text.replace('\n', ' ').take(300)
            text.contentDescription = tr("Dán: %s", it.text.take(80))
            pinId = if (it.pinned) ImeIcons.PIN_FILL else ImeIcons.PIN
            pinAlpha = if (it.pinned) 1f else 0.6f
            pin.contentDescription = if (it.pinned) tr("Bỏ ghim") else tr("Ghim")
            pin.invalidate()
        }
    }

    private fun label(s: String, sp: Float, bold: Boolean = false, alpha: Float = 1f) = TextView(context).apply {
        text = s
        setTextSize(TypedValue.COMPLEX_UNIT_SP, sp)
        setTextColor(theme.withAlpha(theme.ink, alpha))
        if (bold) setTypeface(typeface, android.graphics.Typeface.BOLD)
    }

    /** Nút icon vuông 40 dp (vùng chạm ≥ 40 dp) — vẽ [ImeIcons] màu chữ của theme. */
    private fun iconButton(id: () -> Int, alpha: () -> Float, size: Float = 20f, onClick: () -> Unit) = object : View(context) {
        private val paint = android.graphics.Paint(android.graphics.Paint.ANTI_ALIAS_FLAG)
        override fun onDraw(c: android.graphics.Canvas) {
            paint.color = theme.withAlpha(theme.ink, alpha())
            ImeIcons.draw(c, id(), width / 2f, height / 2f, dp(size).toFloat(), paint)
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
