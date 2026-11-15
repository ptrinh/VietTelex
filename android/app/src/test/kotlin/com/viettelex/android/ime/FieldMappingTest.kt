package com.viettelex.android.ime

import android.text.InputType.*
import android.view.inputmethod.EditorInfo
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import com.viettelex.keyboard.FieldTraits
import com.viettelex.keyboard.StripMode

class FieldMappingTest {
    private fun m(type: Int, opts: Int = 0) = FieldMapping.map(type, opts)

    @Test fun plainTextTypesTelex() {
        val f = m(TYPE_CLASS_TEXT or TYPE_TEXT_FLAG_CAP_SENTENCES)
        assertFalse(f.passthrough); assertFalse(f.isSecure)
        assertTrue(f.capSentences); assertTrue(f.suggestionsAllowed)
        assertEquals(InputKind.NORMAL, f.kind)
    }

    @Test fun noSuggestionsOnlyHidesBar() {
        // Quyết định §12: nhiều app chat đặt NO_SUGGESTIONS — Telex vẫn chạy.
        val f = m(TYPE_CLASS_TEXT or TYPE_TEXT_FLAG_NO_SUGGESTIONS)
        assertFalse(f.passthrough)
        assertFalse(f.suggestionsAllowed)
    }

    @Test fun passwordsAreSecureLiteral() {
        for (v in listOf(TYPE_TEXT_VARIATION_PASSWORD, TYPE_TEXT_VARIATION_WEB_PASSWORD, TYPE_TEXT_VARIATION_VISIBLE_PASSWORD)) {
            val f = m(TYPE_CLASS_TEXT or v)
            assertTrue(f.isSecure); assertFalse(f.suggestionsAllowed)
        }
        val pin = m(TYPE_CLASS_NUMBER or TYPE_NUMBER_VARIATION_PASSWORD)
        assertTrue(pin.isSecure); assertEquals(InputKind.NUMBER, pin.kind)
    }

    @Test fun passthroughVariations() {
        // Regression: thanh địa chỉ Chrome (URI) và ô tìm (FILTER) phải gõ được tiếng Việt.
        assertFalse(m(TYPE_CLASS_TEXT or TYPE_TEXT_VARIATION_URI).passthrough)
        assertTrue(m(TYPE_CLASS_TEXT or TYPE_TEXT_VARIATION_EMAIL_ADDRESS).passthrough)
        assertTrue(m(TYPE_CLASS_TEXT or TYPE_TEXT_VARIATION_WEB_EMAIL_ADDRESS).passthrough)
        assertTrue(m(TYPE_CLASS_TEXT or TYPE_TEXT_VARIATION_VISIBLE_PASSWORD).passthrough)
        assertFalse(m(TYPE_CLASS_TEXT or TYPE_TEXT_VARIATION_FILTER).passthrough)
        assertFalse(m(TYPE_CLASS_TEXT or TYPE_TEXT_VARIATION_SHORT_MESSAGE).passthrough)
        assertFalse(m(TYPE_CLASS_TEXT or TYPE_TEXT_VARIATION_PERSON_NAME).passthrough)
    }

    /** Ô email (người nhận Gmail/Outlook — cũng tìm danh bạ theo tên): Telex BẬT + bảo vệ địa chỉ. */
    @Test fun emailFieldsComposeWithAddressGuard() {
        for (v in listOf(TYPE_TEXT_VARIATION_EMAIL_ADDRESS, TYPE_TEXT_VARIATION_WEB_EMAIL_ADDRESS)) {
            val f = m(TYPE_CLASS_TEXT or v)
            assertTrue(f.emailCompose)
            assertTrue(f.passthrough)                 // gõ tắt/tự sửa/vuốt/phép tính vẫn tắt
            assertEquals(InputKind.EMAIL, f.kind)     // bàn email (@ .) giữ nguyên
            assertFalse(f.capSentences)
        }
        // FORCE_ASCII / mật khẩu / ô thường / URL / TYPE_NULL: không đổi.
        assertFalse(m(TYPE_CLASS_TEXT or TYPE_TEXT_VARIATION_EMAIL_ADDRESS, EditorInfo.IME_FLAG_FORCE_ASCII).emailCompose)
        assertFalse(m(TYPE_CLASS_TEXT or TYPE_TEXT_VARIATION_PASSWORD).emailCompose)
        assertFalse(m(TYPE_CLASS_TEXT or TYPE_TEXT_VARIATION_VISIBLE_PASSWORD).emailCompose)
        assertFalse(m(TYPE_CLASS_TEXT).emailCompose)
        assertFalse(m(TYPE_CLASS_TEXT or TYPE_TEXT_VARIATION_URI).emailCompose)
        assertFalse(m(TYPE_NULL).emailCompose)
        assertFalse(m(TYPE_CLASS_NUMBER).emailCompose)
        assertFalse(StripMode.learns(true, FieldTraits(emailField = true, emailCompose = true), false))
    }

    @Test fun kinds() {
        assertEquals(InputKind.EMAIL, m(TYPE_CLASS_TEXT or TYPE_TEXT_VARIATION_EMAIL_ADDRESS).kind)
        assertEquals(InputKind.URL, m(TYPE_CLASS_TEXT or TYPE_TEXT_VARIATION_URI).kind)
        assertEquals(InputKind.PHONE, m(TYPE_CLASS_PHONE).kind)
        assertEquals(InputKind.DATETIME, m(TYPE_CLASS_DATETIME).kind)
        assertEquals(InputKind.NUMBER, m(TYPE_CLASS_NUMBER or TYPE_NUMBER_FLAG_DECIMAL).kind)
        assertEquals(Plane.PHONE, InputKind.PHONE.padPlane)
        assertEquals(Plane.NUMPAD, InputKind.NUMBER.padPlane)
        assertEquals(Plane.NUMPAD, InputKind.DATETIME.padPlane)
        assertEquals(null, InputKind.NORMAL.padPlane)
    }

    @Test fun numberFlags() {
        val plain = m(TYPE_CLASS_NUMBER)
        assertFalse(plain.numberSigned); assertFalse(plain.numberDecimal)
        val web = m(0x6002)   // <input type=number> Chrome: NUMBER | DECIMAL | 0x4000 (không SIGNED)
        assertEquals(InputKind.NUMBER, web.kind)
        assertTrue(web.numberSigned); assertTrue(web.numberDecimal)   // web number cho số âm → có "−"
        val signed = m(TYPE_CLASS_NUMBER or TYPE_NUMBER_FLAG_SIGNED)
        assertTrue(signed.numberSigned); assertFalse(signed.numberDecimal)
        val tel = m(0x4003)   // <input type=tel> Chrome
        assertEquals(InputKind.PHONE, tel.kind)
        assertFalse(tel.numberSigned)
        // cờ số không rò sang lớp khác (bit 0x1000 của TEXT là CAP_CHARACTERS)
        assertFalse(m(TYPE_CLASS_TEXT or 0x1000).numberSigned)
    }

    @Test fun numericPadsAreLiteralWithoutBar() {
        for (t in listOf(TYPE_CLASS_NUMBER, TYPE_CLASS_PHONE, TYPE_CLASS_DATETIME, 0x6002, 0x4003)) {
            val f = m(t)
            assertTrue(f.passthrough); assertFalse(f.suggestionsAllowed)
        }
        val pin = m(TYPE_CLASS_NUMBER or TYPE_NUMBER_VARIATION_PASSWORD)
        assertTrue(pin.isSecure); assertTrue(pin.passthrough)
        assertEquals(Plane.NUMPAD, pin.kind.padPlane)
    }

    @Test fun typeNullIsRawLiteral() {
        val f = m(TYPE_NULL)
        assertTrue(f.rawKeys); assertTrue(f.passthrough); assertFalse(f.suggestionsAllowed)
        assertEquals(0, f.actionId)
    }

    @Test fun returnKeyLabels() {
        val t = TYPE_CLASS_TEXT
        assertEquals("go", m(t, EditorInfo.IME_ACTION_GO).returnLabel)
        assertEquals("search", m(t, EditorInfo.IME_ACTION_SEARCH).returnLabel)
        assertEquals("send", m(t, EditorInfo.IME_ACTION_SEND).returnLabel)
        assertEquals("next", m(t, EditorInfo.IME_ACTION_NEXT).returnLabel)
        assertEquals("done", m(t, EditorInfo.IME_ACTION_DONE).returnLabel)
        assertEquals(EditorInfo.IME_ACTION_SEND, m(t, EditorInfo.IME_ACTION_SEND).actionId)
        assertEquals("return", m(t, EditorInfo.IME_ACTION_UNSPECIFIED).returnLabel)
        assertEquals(0, m(t, EditorInfo.IME_ACTION_NONE).actionId)
    }

    @Test fun multilineOrNoEnterActionIsNewline() {
        val ml = m(TYPE_CLASS_TEXT or TYPE_TEXT_FLAG_MULTI_LINE, EditorInfo.IME_ACTION_SEND)
        assertEquals("return", ml.returnLabel); assertEquals(0, ml.actionId)
        val ne = m(TYPE_CLASS_TEXT, EditorInfo.IME_ACTION_SEND or EditorInfo.IME_FLAG_NO_ENTER_ACTION)
        assertEquals("return", ne.returnLabel); assertEquals(0, ne.actionId)
    }

    @Test fun noPersonalizedLearningFlag() {
        // Regression: Chrome ẩn danh đặt IME_FLAG_NO_PERSONALIZED_LEARNING — trước đây bị bỏ qua.
        val inc = m(TYPE_CLASS_TEXT or TYPE_TEXT_VARIATION_URI, EditorInfo.IME_FLAG_NO_PERSONALIZED_LEARNING)
        assertTrue(inc.noLearning); assertFalse(inc.passthrough); assertTrue(inc.suggestionsAllowed)
        assertFalse(m(TYPE_CLASS_TEXT).noLearning)
    }

    @Test fun allThreeCapModes() {
        // Regression: trước chỉ đọc CAP_SENTENCES.
        assertTrue(m(TYPE_CLASS_TEXT or TYPE_TEXT_FLAG_CAP_WORDS).capWords)
        assertTrue(m(TYPE_CLASS_TEXT or TYPE_TEXT_FLAG_CAP_CHARACTERS).capCharacters)
        val plain = m(TYPE_CLASS_TEXT)
        assertFalse(plain.capSentences); assertFalse(plain.capWords); assertFalse(plain.capCharacters)
        // bit 0x1000 của lớp NUMBER không phải CAP_CHARACTERS
        assertFalse(m(TYPE_CLASS_NUMBER or 0x1000).capCharacters)
    }

    @Test fun pixelLauncherSearchGetsSearchKey() {
        // Regression (HeliBoard #1989): Pixel Launcher đặt MULTI_LINE + NO_ENTER_ACTION cho ô tìm.
        val type = TYPE_CLASS_TEXT or TYPE_TEXT_FLAG_MULTI_LINE
        val opts = EditorInfo.IME_ACTION_SEARCH or EditorInfo.IME_FLAG_NO_ENTER_ACTION
        val px = FieldMapping.map(type, opts, FieldMapping.PIXEL_LAUNCHER)
        assertEquals("search", px.returnLabel); assertEquals(EditorInfo.IME_ACTION_SEARCH, px.actionId)
        // app khác cùng cờ vẫn xuống dòng
        val other = FieldMapping.map(type, opts, "com.example.notes")
        assertEquals("return", other.returnLabel); assertEquals(0, other.actionId)
    }

    @Test fun customActionLabelPerformsCustomActionId() {
        val f = FieldMapping.map(TYPE_CLASS_TEXT, EditorInfo.IME_FLAG_NO_ENTER_ACTION, null,
            hasActionLabel = true, customActionId = 42)
        assertEquals(42, f.actionId); assertEquals("done", f.returnLabel)
        // ô nhiều dòng: vẫn xuống dòng
        val ml = FieldMapping.map(TYPE_CLASS_TEXT or TYPE_TEXT_FLAG_MULTI_LINE, 0, null,
            hasActionLabel = true, customActionId = 42)
        assertEquals(0, ml.actionId)
        // nhãn không kèm actionId → như thường
        assertEquals(EditorInfo.IME_ACTION_SEND, FieldMapping.map(TYPE_CLASS_TEXT, EditorInfo.IME_ACTION_SEND,
            null, hasActionLabel = true, customActionId = 0).actionId)
    }

    @Test fun contradictoryNoSuggestionsIgnored() {
        // Regression: Google Keep đặt NO_SUGGESTIONS kèm AUTO_CORRECT/AUTO_COMPLETE → bar phải hiện.
        assertTrue(m(TYPE_CLASS_TEXT or TYPE_TEXT_FLAG_NO_SUGGESTIONS or TYPE_TEXT_FLAG_AUTO_CORRECT).suggestionsAllowed)
        assertTrue(m(TYPE_CLASS_TEXT or TYPE_TEXT_FLAG_NO_SUGGESTIONS or TYPE_TEXT_FLAG_AUTO_COMPLETE).suggestionsAllowed)
        assertFalse(m(TYPE_CLASS_TEXT or TYPE_TEXT_FLAG_NO_SUGGESTIONS).suggestionsAllowed)
    }

    @Test fun forceAsciiIsLiteral() {
        val f = m(TYPE_CLASS_TEXT, EditorInfo.IME_FLAG_FORCE_ASCII)
        assertTrue(f.passthrough); assertFalse(f.isSecure); assertFalse(f.suggestionsAllowed)
    }

    @Test fun multilineVisiblePasswordIsChatNotPassword() {
        // Regression: app RN/Flutter dùng VISIBLE_PASSWORD để tắt gợi ý ô chat → vẫn gõ Telex.
        val chat = m(TYPE_CLASS_TEXT or TYPE_TEXT_VARIATION_VISIBLE_PASSWORD or TYPE_TEXT_FLAG_MULTI_LINE)
        assertFalse(chat.isSecure); assertFalse(chat.passthrough); assertFalse(chat.suggestionsAllowed)
        val pw = m(TYPE_CLASS_TEXT or TYPE_TEXT_VARIATION_VISIBLE_PASSWORD)
        assertTrue(pw.isSecure); assertTrue(pw.passthrough)
    }

    // Giữ lâu Enter = xuống dòng thật: chỉ ô chữ nhiều dòng.

    @Test fun holdNewlineOnlyInMultiLineText() {
        // Ô chat Zalo/Messenger: multi-line + actionSend ⇒ chạm = xuống dòng/KEYCODE_ENTER
        // (app bắt thành "Gửi"), giữ lâu = "\n" thật.
        val chat = m(TYPE_CLASS_TEXT or TYPE_TEXT_FLAG_MULTI_LINE or TYPE_TEXT_FLAG_CAP_SENTENCES,
            EditorInfo.IME_ACTION_SEND)
        assertTrue(chat.holdNewline); assertEquals(0, chat.actionId)
        assertTrue(m(TYPE_CLASS_TEXT or TYPE_TEXT_FLAG_MULTI_LINE, EditorInfo.IME_FLAG_NO_ENTER_ACTION).holdNewline)
        // Chat RN/Flutter dùng VISIBLE_PASSWORD + MULTI_LINE để tắt gợi ý: vẫn là ô chat.
        assertTrue(m(TYPE_CLASS_TEXT or TYPE_TEXT_VARIATION_VISIBLE_PASSWORD or TYPE_TEXT_FLAG_MULTI_LINE).holdNewline)
    }

    @Test fun holdNewlineOffInSingleLineFields() {
        assertFalse(m(TYPE_CLASS_TEXT).holdNewline)
        assertFalse(m(TYPE_CLASS_TEXT, EditorInfo.IME_ACTION_SEARCH).holdNewline)
        assertFalse(m(TYPE_CLASS_TEXT, EditorInfo.IME_ACTION_SEND).holdNewline)
        assertFalse(m(TYPE_CLASS_TEXT, EditorInfo.IME_FLAG_NO_ENTER_ACTION).holdNewline)
        assertFalse(m(TYPE_CLASS_TEXT or TYPE_TEXT_VARIATION_URI, EditorInfo.IME_ACTION_GO).holdNewline)
        assertFalse(m(TYPE_NULL).holdNewline)
        assertFalse(m(TYPE_CLASS_NUMBER).holdNewline)
        assertFalse(m(TYPE_CLASS_TEXT or TYPE_TEXT_VARIATION_PASSWORD or TYPE_TEXT_FLAG_MULTI_LINE).holdNewline)
        // Pixel Launcher gỡ MULTI_LINE ⇒ ô tìm một dòng.
        assertFalse(FieldMapping.map(TYPE_CLASS_TEXT or TYPE_TEXT_FLAG_MULTI_LINE,
            EditorInfo.IME_ACTION_SEARCH or EditorInfo.IME_FLAG_NO_ENTER_ACTION, FieldMapping.PIXEL_LAUNCHER).holdNewline)
    }

    @Test fun allowsHoldNewlinePure() {
        assertTrue(FieldMapping.allowsHoldNewline(multiLine = true, secure = false, rawKeys = false))
        assertFalse(FieldMapping.allowsHoldNewline(multiLine = false, secure = false, rawKeys = false))
        assertFalse(FieldMapping.allowsHoldNewline(multiLine = true, secure = true, rawKeys = false))
        assertFalse(FieldMapping.allowsHoldNewline(multiLine = true, secure = false, rawKeys = true))
    }

    /** Ô thật → dải hiện gì (như VietTelexIME.configureField: FieldConfig → FieldTraits → StripMode). */
    private fun strip(type: Int, opts: Int = 0, incognito: Boolean = false): StripMode {
        val f = m(type, opts)
        return StripMode.of(true, FieldTraits(isSecure = f.isSecure, passthrough = f.passthrough,
            suggestionsAllowed = f.suggestionsAllowed, noLearning = f.noLearning,
            emailField = f.kind == InputKind.EMAIL, stripTools = f.stripTools), incognito || f.noLearning)
    }

    @Test fun stripToolsInNoSuggestionFields() {
        // #113: Messenger chat với Trang — NO_SUGGESTIONS ⇒ ☰/con trỏ/📋/⌄ + Dán, không chữ.
        assertEquals(StripMode.TOOLS, strip(TYPE_CLASS_TEXT or TYPE_TEXT_FLAG_MULTI_LINE or
            TYPE_TEXT_FLAG_CAP_SENTENCES or TYPE_TEXT_FLAG_NO_SUGGESTIONS))
        assertEquals(StripMode.TOOLS, strip(TYPE_CLASS_TEXT or TYPE_TEXT_VARIATION_VISIBLE_PASSWORD or
            TYPE_TEXT_FLAG_MULTI_LINE))                                    // ô chat "VISIBLE_PASSWORD" giả
        assertEquals(StripMode.TOOLS, strip(TYPE_CLASS_TEXT, EditorInfo.IME_FLAG_FORCE_ASCII))
        assertEquals(StripMode.FULL, strip(TYPE_CLASS_TEXT or TYPE_TEXT_FLAG_CAP_SENTENCES))
        assertEquals(StripMode.FULL, strip(TYPE_CLASS_TEXT or TYPE_TEXT_VARIATION_URI))
        assertEquals(StripMode.FULL, strip(TYPE_CLASS_TEXT or TYPE_TEXT_VARIATION_EMAIL_ADDRESS))
    }

    @Test fun stripBlankInSensitiveFields() {
        for (v in listOf(TYPE_TEXT_VARIATION_PASSWORD, TYPE_TEXT_VARIATION_WEB_PASSWORD, TYPE_TEXT_VARIATION_VISIBLE_PASSWORD))
            assertEquals(StripMode.BLANK, strip(TYPE_CLASS_TEXT or v))
        assertEquals(StripMode.BLANK, strip(TYPE_CLASS_NUMBER or TYPE_NUMBER_VARIATION_PASSWORD))
        // Bàn số (15/11/2026, như Gboard): thanh công cụ có Dán (số đã lọc) — không còn dải trống.
        assertEquals(StripMode.TOOLS, strip(TYPE_CLASS_NUMBER))
        assertEquals(StripMode.TOOLS, strip(TYPE_CLASS_PHONE))
        assertEquals(StripMode.BLANK, strip(TYPE_NULL))                      // terminal
        assertEquals(StripMode.BLANK, strip(TYPE_CLASS_TEXT or TYPE_TEXT_FLAG_NO_SUGGESTIONS,
            EditorInfo.IME_FLAG_NO_PERSONALIZED_LEARNING))                   // ẩn danh (Chrome…)
        assertEquals(StripMode.BLANK, strip(TYPE_CLASS_TEXT or TYPE_TEXT_FLAG_NO_SUGGESTIONS, incognito = true))
    }

    /**
     * #113: thanh địa chỉ Firefox gõ "bình" hiện "Thường | Tĩnh | Dương" ⇒ ô địa chỉ / tìm kiếm
     * gợi ý chữ thường. inputType/imeOptions thật của Firefox chưa đo được — phủ các dạng
     * omnibox hay gặp: textUri + actionGo (Fenix toolbar), URI có cờ CAP/AUTO_COMPLETE, web
     * edit text / text thường với Go/Search, FILTER.
     */
    @Test fun addressAndSearchFieldsLowercaseSuggestions() {
        val ui = EditorInfo.IME_FLAG_NO_EXTRACT_UI or EditorInfo.IME_FLAG_NO_FULLSCREEN
        val omni = listOf(
            m(TYPE_CLASS_TEXT or TYPE_TEXT_VARIATION_URI, EditorInfo.IME_ACTION_GO or ui),
            m(TYPE_CLASS_TEXT or TYPE_TEXT_VARIATION_URI or TYPE_TEXT_FLAG_AUTO_COMPLETE, EditorInfo.IME_ACTION_GO or ui or
                EditorInfo.IME_FLAG_NO_PERSONALIZED_LEARNING),                       // Firefox riêng tư
            m(TYPE_CLASS_TEXT or TYPE_TEXT_VARIATION_URI or TYPE_TEXT_FLAG_CAP_SENTENCES),
            m(TYPE_CLASS_TEXT or TYPE_TEXT_VARIATION_WEB_EDIT_TEXT, EditorInfo.IME_ACTION_GO),
            m(TYPE_CLASS_TEXT or TYPE_TEXT_VARIATION_WEB_EDIT_TEXT, EditorInfo.IME_ACTION_SEARCH),
            m(TYPE_CLASS_TEXT or TYPE_TEXT_FLAG_CAP_SENTENCES, EditorInfo.IME_ACTION_SEARCH or ui),
            m(TYPE_CLASS_TEXT or TYPE_TEXT_VARIATION_FILTER),
        )
        for (c in omni) {
            assertTrue(c.lowercaseSuggestions)
            assertTrue("vẫn có gợi ý", c.suggestionsAllowed)
            assertFalse("vẫn gõ Telex", c.passthrough)
        }
        // Ô chữ thường / chat / mật khẩu / email / nhiều dòng (Enter xuống dòng): giữ hoa/thường như cũ.
        for (c in listOf(
            m(TYPE_CLASS_TEXT or TYPE_TEXT_FLAG_CAP_SENTENCES),
            m(TYPE_CLASS_TEXT or TYPE_TEXT_FLAG_CAP_SENTENCES, EditorInfo.IME_ACTION_SEND),
            m(TYPE_CLASS_TEXT or TYPE_TEXT_VARIATION_WEB_EDIT_TEXT, EditorInfo.IME_ACTION_DONE),
            m(TYPE_CLASS_TEXT or TYPE_TEXT_FLAG_MULTI_LINE, EditorInfo.IME_ACTION_SEARCH),
            m(TYPE_CLASS_TEXT, EditorInfo.IME_ACTION_SEARCH or EditorInfo.IME_FLAG_NO_ENTER_ACTION),
            m(TYPE_CLASS_TEXT or TYPE_TEXT_VARIATION_PASSWORD, EditorInfo.IME_ACTION_GO),
            m(TYPE_CLASS_TEXT or TYPE_TEXT_VARIATION_EMAIL_ADDRESS),
            m(TYPE_CLASS_NUMBER, EditorInfo.IME_ACTION_SEARCH),
        )) assertFalse(c.lowercaseSuggestions)
        // Chrome omnibox: NO_SUGGESTIONS ⇒ không có gợi ý chữ (chỉ thanh công cụ), vẫn đánh dấu ô địa chỉ.
        val chrome = m(TYPE_CLASS_TEXT or TYPE_TEXT_VARIATION_URI or TYPE_TEXT_FLAG_NO_SUGGESTIONS, EditorInfo.IME_ACTION_GO)
        assertFalse(chrome.suggestionsAllowed); assertTrue(chrome.lowercaseSuggestions)
    }

    /** #113 "Gợi ý cả khi ứng dụng tắt gợi ý": chỉ ô CHỮ app tắt gợi ý, không nhạy cảm/passthrough. */
    @Test fun appNoSuggestionsMarksOnlyPlainTextFields() {
        val ui = EditorInfo.IME_ACTION_GO
        for (c in listOf(
            m(TYPE_CLASS_TEXT or TYPE_TEXT_FLAG_MULTI_LINE or TYPE_TEXT_FLAG_NO_SUGGESTIONS),         // chat Messenger
            m(TYPE_CLASS_TEXT or TYPE_TEXT_VARIATION_VISIBLE_PASSWORD or TYPE_TEXT_FLAG_MULTI_LINE),  // chat "VISIBLE_PASSWORD" giả
            m(TYPE_CLASS_TEXT or TYPE_TEXT_VARIATION_URI or TYPE_TEXT_FLAG_NO_SUGGESTIONS, ui),      // Chrome omnibox
            m(TYPE_CLASS_TEXT or TYPE_TEXT_FLAG_NO_SUGGESTIONS, EditorInfo.IME_FLAG_NO_PERSONALIZED_LEARNING),
        )) { assertTrue(c.appNoSuggestions); assertFalse(c.suggestionsAllowed) }
        for (c in listOf(
            m(TYPE_CLASS_TEXT),
            m(TYPE_CLASS_TEXT or TYPE_TEXT_FLAG_NO_SUGGESTIONS or TYPE_TEXT_FLAG_AUTO_CORRECT),      // Keep: muốn gợi ý
            m(TYPE_CLASS_TEXT or TYPE_TEXT_VARIATION_PASSWORD or TYPE_TEXT_FLAG_NO_SUGGESTIONS),
            m(TYPE_CLASS_TEXT or TYPE_TEXT_VARIATION_VISIBLE_PASSWORD),
            m(TYPE_CLASS_TEXT or TYPE_TEXT_VARIATION_EMAIL_ADDRESS or TYPE_TEXT_FLAG_NO_SUGGESTIONS),
            m(TYPE_CLASS_TEXT or TYPE_TEXT_FLAG_NO_SUGGESTIONS, EditorInfo.IME_FLAG_FORCE_ASCII),
            m(TYPE_CLASS_NUMBER), m(TYPE_CLASS_PHONE), m(TYPE_CLASS_DATETIME), m(TYPE_NULL),
        )) assertFalse(c.appNoSuggestions)
        // Ô địa chỉ tắt gợi ý ⇒ bật cài đặt thì gợi ý đầy đủ, vẫn chữ thường.
        val chrome = m(TYPE_CLASS_TEXT or TYPE_TEXT_VARIATION_URI or TYPE_TEXT_FLAG_NO_SUGGESTIONS, ui)
        val t = FieldTraits(isSecure = chrome.isSecure, passthrough = chrome.passthrough,
            suggestionsAllowed = chrome.suggestionsAllowed, stripTools = chrome.stripTools,
            lowercaseSuggestions = chrome.lowercaseSuggestions, appNoSuggestions = chrome.appNoSuggestions)
        assertEquals(StripMode.FULL, StripMode.of(true, t, incognito = false, suggestAnyway = true))
        assertEquals(StripMode.TOOLS, StripMode.of(true, t, incognito = false, suggestAnyway = false))
        assertTrue(t.lowercaseSuggestions)
    }

    /** Ô số trơn có hint tiền (MoMo / MB Bank) ⇒ đủ − , .; số trơn khác (OTP, PIN, STK) ⇒ chỉ số. */
    @Test fun moneyHintOnPlainNumberField() {
        val n = TYPE_CLASS_NUMBER
        for (h in listOf("Số tiền chuyển", "Nhập số tiền", "Amount", "Số tiền (VND)", "Giá", "Tổng tiền"))
            assertTrue(h, FieldMapping.looksLikeMoney(n, h))
        for (h in listOf(null, "", "Mã OTP", "Nhập mã PIN", "Số tài khoản", "Số điện thoại", "Số lượng"))
            assertFalse(h.toString(), FieldMapping.looksLikeMoney(n, h))
        assertFalse(FieldMapping.looksLikeMoney(TYPE_CLASS_TEXT, "Số tiền"))                       // ô chữ: không bàn số
        assertFalse(FieldMapping.looksLikeMoney(n or TYPE_NUMBER_VARIATION_PASSWORD, "Số tiền"))   // mật khẩu số
    }
}
