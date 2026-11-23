package com.viettelex.android.ime

import org.junit.Assert.assertEquals
import org.junit.Test

class ImeInsetsTest {
    @Test fun gestureNavAndroid15ReservesStripForImeButtons() {
        // nút ⌄/🌐 hệ thống: navigationBars = 0 ở một số bản, tappableElement = 48dp×2.625
        assertEquals(126, ImeInsets.bottomPad(36, 0, 126, 132, insetsKnown = true))
        assertEquals(126, ImeInsets.bottomPad(36, 126, 63, 132, insetsKnown = true))
    }

    @Test fun android15CaptionBarStripCoversImeButtons() {
        // API 36 điều hướng cử chỉ (báo cáo thật): navigationBars 63, captionBar 126 ⇒ đệm 126, không 189.
        assertEquals(126, ImeInsets.bottomPad(36, 63, 0, 132, insetsKnown = true, captionBottom = 126))
        assertEquals(126, ImeInsets.bottomPad(35, 63, 63, 132, insetsKnown = true, captionBottom = 126))
        // caption thấp hơn nav / bằng nhau: giữ phần lớn hơn, không cộng dồn
        assertEquals(126, ImeInsets.bottomPad(36, 126, 0, 132, insetsKnown = true, captionBottom = 63))
        assertEquals(126, ImeInsets.bottomPad(36, 126, 126, 132, insetsKnown = true, captionBottom = 126))
        // chỉ caption báo ⇒ vẫn chừa dải; âm bỏ qua
        assertEquals(126, ImeInsets.bottomPad(36, 0, 0, 132, insetsKnown = true, captionBottom = 126))
        assertEquals(0, ImeInsets.bottomPad(36, 0, 0, 132, insetsKnown = true, captionBottom = -4))
    }

    @Test fun threeButtonNav() {
        assertEquals(126, ImeInsets.bottomPad(35, 126, 126, 132, insetsKnown = true))
    }

    /** #176 (Android 13): insets gốc của cửa sổ IME vẫn báo nav bar dù hệ thống đã đặt bàn phím trên nó ⇒ không đệm thêm. */
    @Test fun beforeAndroid15ReportedNavBarIsNotPaddedAgain() {
        assertEquals(0, ImeInsets.bottomPad(33, 132, 132, 132, insetsKnown = true))
        assertEquals(0, ImeInsets.bottomPad(30, 126, 126, 132, insetsKnown = true))
        assertEquals(0, ImeInsets.bottomPad(34, 63, 0, 132, insetsKnown = true, captionBottom = 126))
        // "Nâng bàn phím" vẫn cộng được trên 0.
        assertEquals(63, ImeInsets.bottomPad(33, 132, 132, 132, insetsKnown = true) + ImeInsets.raisePx(24, 2.625f))
    }

    @Test fun olderAndroidNeverDoublePads() {
        // < 35: hệ thống đã đặt IME trên nav bar
        assertEquals(0, ImeInsets.bottomPad(34, 0, 0, 132, insetsKnown = false))
        assertEquals(0, ImeInsets.bottomPad(26, 0, 0, 132, insetsKnown = true))
    }

    @Test fun android15FallbackOnlyWhenInsetsNeverArrived() {
        assertEquals(132, ImeInsets.bottomPad(35, 0, 0, 132, insetsKnown = false))
        assertEquals(0, ImeInsets.bottomPad(35, 0, 0, 132, insetsKnown = true))   // immersive / không nav
        assertEquals(0, ImeInsets.bottomPad(35, -5, 0, 0, insetsKnown = false))
    }

    @Test fun keyboardRaiseAddsBackgroundPadBelowKeys() {
        // #112: 0 ⇒ không tốn gì; dp → px làm tròn; kẹp 0…48 dp.
        assertEquals(0, ImeInsets.raisePx(0, 2.625f))
        assertEquals(63, ImeInsets.raisePx(24, 2.625f))
        assertEquals(126, ImeInsets.raisePx(48, 2.625f))
        assertEquals(126, ImeInsets.raisePx(200, 2.625f))
        assertEquals(0, ImeInsets.raisePx(-8, 2.625f))
        // Nâng cộng dồn trên đệm nav bar: cả khung cao thêm đúng raisePx, vùng phím không đổi.
        val nav = ImeInsets.bottomPad(35, 126, 126, 132, insetsKnown = true)
        val raise = ImeInsets.raisePx(24, 2.625f)
        assertEquals(ImeInsets.totalHeight(89, 588, nav) + raise, ImeInsets.totalHeight(89, 588, nav + raise))
    }

    @Test fun totalHeight() {
        // 34 strip + 218 phím + 48 dải nút hệ thống (dp = px)
        assertEquals(300, ImeInsets.totalHeight(34, 218, 48))
        assertEquals(218, ImeInsets.totalHeight(0, 218, 0))
    }
}
