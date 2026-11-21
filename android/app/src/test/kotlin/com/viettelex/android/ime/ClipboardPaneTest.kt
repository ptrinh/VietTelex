package com.viettelex.android.ime

import android.view.View
import androidx.test.core.app.ApplicationProvider
import com.viettelex.keyboard.ClipboardHistory
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

/**
 * Bảng clipboard tái dùng dòng (lịch sử 20 → 100 mục, 22/11/2026): 100 mục không dựng 100 dòng view một lượt.
 * iOS ClipboardHistoryTests.testPanelBuildsOnlyVisibleRows.
 */
@RunWith(RobolectricTestRunner::class)
class ClipboardPaneTest {
    private val ctx get() = ApplicationProvider.getApplicationContext<android.content.Context>()

    private fun pane() = ClipboardPane(ctx, ImeTheme(ctx)).also { layout(it) }

    private fun layout(v: View) {
        v.measure(View.MeasureSpec.makeMeasureSpec(400, View.MeasureSpec.EXACTLY), View.MeasureSpec.makeMeasureSpec(300, View.MeasureSpec.EXACTLY))
        v.layout(0, 0, 400, 300)
    }

    @Test fun buildsOnlyVisibleRows() {
        val p = pane()
        val items = (0 until 100).map { ClipboardHistory.Item("mục $it", it.toLong(), pinned = it == 0, sensitive = false) }
        p.show(items, enabled = true, incognito = false)
        layout(p)
        assertEquals(100, p.rowCount)
        assertTrue("có dòng được dựng", p.builtRowCount > 0)
        assertTrue("chỉ dựng các dòng đang thấy: ${p.builtRowCount}", p.builtRowCount < 30)
    }

    @Test fun emptyNoticeAndIncognitoRows() {
        val p = pane()
        p.show(emptyList(), enabled = true, incognito = false)
        assertEquals(1, p.rowCount)
        val one = listOf(ClipboardHistory.Item("a", 1, pinned = false, sensitive = false))
        p.show(one, enabled = true, incognito = true)
        assertEquals("mục + dòng ẩn danh", 2, p.rowCount)
        p.showNotice("Tối đa 5 mục ghim")
        assertEquals(3, p.rowCount)
        p.show(one, enabled = true, incognito = false)
        assertEquals("nạp lại bỏ thông báo", 1, p.rowCount)
        layout(p)
        assertEquals(1, p.builtRowCount)
    }
}
