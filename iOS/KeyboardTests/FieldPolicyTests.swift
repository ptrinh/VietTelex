import XCTest

/// Dải gợi ý theo loại ô (StripMode): ô từ chối gợi ý chữ nhưng không nhạy cảm (thanh địa
/// chỉ Safari) có thanh công cụ thay vì dải trống; mật khẩu/OTP/ẩn danh/bàn số giữ dải trống.
final class StripModeTests: XCTestCase {
    private func mode(_ t: FieldTraits, show: Bool = true, incognito: Bool = false) -> StripMode {
        StripMode.of(showSuggestions: show, traits: t, incognito: incognito)
    }

    func testSafariAddressBarGetsTools() {
        // Safari/Chrome: keyboardType .webSearch + autocorrection .no.
        let omnibox = FieldTraits(keyboardType: .webSearch, autocorrection: .no)
        XCTAssertEqual(mode(omnibox), .tools)
        XCTAssertTrue(omnibox.wantsURLChips)
        let url = FieldTraits(keyboardType: .URL, autocorrection: .no, contentType: .URL)
        XCTAssertEqual(mode(url), .tools)
        XCTAssertTrue(url.wantsURLChips)
        // Ô chữ thường tắt autocorrect (ô tên, chat cấm gợi ý): công cụ, KHÔNG chip URL.
        let plain = FieldTraits(autocorrection: .no)
        XCTAssertEqual(mode(plain), .tools)
        XCTAssertFalse(plain.wantsURLChips)
        XCTAssertEqual(mode(FieldTraits(autocorrection: .no, contentType: .username)), .tools)
    }

    func testFullWhenSuggestionsAllowed() {
        XCTAssertEqual(mode(FieldTraits()), .full)
        XCTAssertEqual(mode(FieldTraits(keyboardType: .webSearch)), .full)   // ô tìm có autocorrect
        XCTAssertEqual(mode(FieldTraits(keyboardType: .emailAddress, autocorrection: .no)), .full) // chip mail
    }

    func testSensitiveFieldsKeepBlankBand() {
        XCTAssertEqual(mode(FieldTraits(secure: true)), .blank)
        XCTAssertEqual(mode(FieldTraits(keyboardType: .URL, autocorrection: .no, secure: true)), .blank)
        XCTAssertEqual(mode(FieldTraits(autocorrection: .no, contentType: .password)), .blank)
        XCTAssertEqual(mode(FieldTraits(autocorrection: .no, contentType: .newPassword)), .blank)
        XCTAssertEqual(mode(FieldTraits(keyboardType: .numberPad, autocorrection: .no,
                                        contentType: .oneTimeCode)), .blank)
        XCTAssertEqual(mode(FieldTraits(keyboardType: .numberPad, autocorrection: .no)), .blank)
        XCTAssertEqual(mode(FieldTraits(keyboardType: .webSearch, autocorrection: .no), incognito: true), .blank)
    }

    func testSettingOffMeansNoStrip() {
        XCTAssertEqual(mode(FieldTraits(), show: false), .off)
        XCTAssertEqual(mode(FieldTraits(keyboardType: .webSearch, autocorrection: .no), show: false), .off)
        XCTAssertFalse(StripMode.off.shown)
        XCTAssertFalse(StripMode.blank.shown)
        XCTAssertTrue(StripMode.tools.shown)
        XCTAssertTrue(StripMode.full.shown)
    }
}

/// #113 "Gợi ý cả khi ứng dụng tắt gợi ý" (mặc định BẬT, như Gboard/Laban): bảng quyết định
/// loại ô × cài đặt → dải gợi ý, tự sửa (luôn tắt ở ô app tắt gợi ý), học từ (luôn tắt ở đó).
/// Song sinh Android SuggestInNoSuggestFieldsTests.
final class SuggestInNoSuggestFieldsTests: XCTestCase {
    private struct Row {
        let name: String, traits: FieldTraits, incognito: Bool
        let on: StripMode, off: StripMode
    }

    private let table: [Row] = [
        Row(name: "ô thường", traits: FieldTraits(), incognito: false, on: .full, off: .full),
        Row(name: "ô chat tắt gợi ý", traits: FieldTraits(autocorrection: .no), incognito: false, on: .full, off: .tools),
        Row(name: "thanh địa chỉ Safari", traits: FieldTraits(keyboardType: .webSearch, autocorrection: .no),
            incognito: false, on: .full, off: .tools),
        Row(name: "ô tắt gợi ý + ẩn danh", traits: FieldTraits(autocorrection: .no), incognito: true, on: .blank, off: .blank),
        Row(name: "ô URL (literal)", traits: FieldTraits(keyboardType: .URL, autocorrection: .no, contentType: .URL),
            incognito: false, on: .tools, off: .tools),
        Row(name: "username (literal)", traits: FieldTraits(autocorrection: .no, contentType: .username),
            incognito: false, on: .tools, off: .tools),
        Row(name: "mật khẩu", traits: FieldTraits(autocorrection: .no, secure: true), incognito: false, on: .blank, off: .blank),
        Row(name: "mật khẩu mới", traits: FieldTraits(autocorrection: .no, contentType: .newPassword),
            incognito: false, on: .blank, off: .blank),
        Row(name: "OTP", traits: FieldTraits(keyboardType: .numberPad, autocorrection: .no, contentType: .oneTimeCode),
            incognito: false, on: .blank, off: .blank),
        Row(name: "OTP bàn chữ", traits: FieldTraits(autocorrection: .no, contentType: .oneTimeCode),
            incognito: false, on: .blank, off: .blank),
        Row(name: "bàn số", traits: FieldTraits(keyboardType: .numberPad, autocorrection: .no), incognito: false, on: .blank, off: .blank),
        Row(name: "SĐT", traits: FieldTraits(keyboardType: .phonePad, autocorrection: .no), incognito: false, on: .blank, off: .blank),
        Row(name: "email (chip đuôi mail)", traits: FieldTraits(keyboardType: .emailAddress, autocorrection: .no),
            incognito: false, on: .full, off: .full),
    ]

    func testDecisionTable() {
        for r in table {
            XCTAssertEqual(StripMode.of(showSuggestions: true, traits: r.traits, incognito: r.incognito, suggestAnyway: true),
                           r.on, "\(r.name) / BẬT")
            XCTAssertEqual(StripMode.of(showSuggestions: true, traits: r.traits, incognito: r.incognito, suggestAnyway: false),
                           r.off, "\(r.name) / TẮT")
            XCTAssertEqual(StripMode.of(showSuggestions: false, traits: r.traits, incognito: r.incognito, suggestAnyway: true),
                           .off, r.name)
            if r.traits.appNoSuggestions {
                XCTAssertFalse(AutoCorrect.fieldAllows(r.traits), "\(r.name): không tự sửa")
                XCTAssertTrue(StripMode.learns(learnWords: true, traits: r.traits, incognito: false), "\(r.name): vẫn học")
            }
        }
        XCTAssertTrue(StripMode.learns(learnWords: true, traits: FieldTraits(), incognito: false))
        XCTAssertTrue(StripMode.learns(learnWords: true, traits: nil, incognito: false))
        XCTAssertFalse(StripMode.learns(learnWords: true, traits: FieldTraits(), incognito: true))
        XCTAssertFalse(StripMode.learns(learnWords: false, traits: FieldTraits(), incognito: false))
        XCTAssertTrue(StripMode.learns(learnWords: true, traits: FieldTraits(autocorrection: .no), incognito: false))
    }

    func testAppNoSuggestionsOnlyPlainTextFields() {
        XCTAssertTrue(FieldTraits(autocorrection: .no).appNoSuggestions)
        XCTAssertTrue(FieldTraits(keyboardType: .webSearch, autocorrection: .no).appNoSuggestions)
        XCTAssertFalse(FieldTraits().appNoSuggestions)
        XCTAssertFalse(FieldTraits(autocorrection: .yes).appNoSuggestions)
        XCTAssertFalse(FieldTraits(autocorrection: .no, secure: true).appNoSuggestions)
        XCTAssertFalse(FieldTraits(autocorrection: .no, contentType: .oneTimeCode).appNoSuggestions)
        XCTAssertFalse(FieldTraits(keyboardType: .emailAddress, autocorrection: .no).appNoSuggestions)
        XCTAssertFalse(FieldTraits(keyboardType: .decimalPad, autocorrection: .no).appNoSuggestions)
    }

    func testLowercaseSuggestionsInAddressAndSearchFields() {
        XCTAssertTrue(FieldTraits(keyboardType: .webSearch, autocorrection: .no).lowercaseSuggestions)
        XCTAssertTrue(FieldTraits(keyboardType: .URL).lowercaseSuggestions)
        XCTAssertTrue(FieldTraits(returnKeyType: .search).lowercaseSuggestions)
        XCTAssertTrue(FieldTraits(returnKeyType: .go).lowercaseSuggestions)
        XCTAssertFalse(FieldTraits().lowercaseSuggestions)
        XCTAssertFalse(FieldTraits(returnKeyType: .send).lowercaseSuggestions)
        XCTAssertFalse(FieldTraits(returnKeyType: .search, secure: true).lowercaseSuggestions)
    }

    /// Ô URL/tìm ở chế độ đầy đủ: chip URL chỉ khi ô trống / đang gõ tên miền; còn lại gợi ý chữ.
    func testURLChipsOnlyAtDomainPositions() {
        XCTAssertTrue(StripMode.prefersURLChips(before: "", after: ""))
        XCTAssertTrue(StripMode.prefersURLChips(before: "github.", after: ""))
        XCTAssertTrue(StripMode.prefersURLChips(before: "https://", after: ""))
        XCTAssertTrue(StripMode.prefersURLChips(before: "xem vnexpress.net", after: ""))
        XCTAssertFalse(StripMode.prefersURLChips(before: "bình", after: ""))
        XCTAssertFalse(StripMode.prefersURLChips(before: "thời tiết ", after: ""))
        XCTAssertFalse(StripMode.prefersURLChips(before: "", after: "abc"))
    }

    func testDefaultOnAndBackedUp() {
        XCTAssertTrue(KeyboardSettings().suggestInNoSuggestFields)
        guard case .bool(true)? = BackupSettings.byKey["suggestInNoSuggestFields"]?.kind else {
            return XCTFail("thiếu spec sao lưu suggestInNoSuggestFields (bool, mặc định true)")
        }
    }
}

/// Regression: không gõ được tiếng Việt ở thanh địa chỉ Safari/Chrome và Spotlight
/// (ô tìm kiếm tắt autocorrect) — passthrough không còn dựa vào autocorrect.
final class FieldPolicyTests: XCTestCase {
    func testSearchFieldsKeepTelex() {
        XCTAssertFalse(FieldPolicy.passthrough(keyboardType: .webSearch, contentType: nil))
        XCTAssertFalse(FieldPolicy.passthrough(keyboardType: .default, contentType: nil))
    }
    func testLiteralFields() {
        XCTAssertTrue(FieldPolicy.passthrough(keyboardType: .emailAddress, contentType: nil))
        XCTAssertTrue(FieldPolicy.passthrough(keyboardType: .URL, contentType: nil))
        XCTAssertTrue(FieldPolicy.passthrough(keyboardType: .default, contentType: .username))
        XCTAssertTrue(FieldPolicy.passthrough(keyboardType: .default, contentType: .oneTimeCode))
    }
}

/// Regression: ô không khai báo autocapitalization (nil) → ô trống vẫn chữ thường.
final class AutoShiftTests: XCTestCase {
    func testUndeclaredFieldCapitalizesSentenceStart() {
        XCTAssertEqual(FieldPolicy.autoShift(autocap: nil, before: ""), true)
        XCTAssertEqual(FieldPolicy.autoShift(autocap: nil, before: "Xin chào. "), true)
        XCTAssertEqual(FieldPolicy.autoShift(autocap: nil, before: "Xin chào "), false)
    }
    func testNoneLeavesShiftAlone() {
        XCTAssertNil(FieldPolicy.autoShift(autocap: UITextAutocapitalizationType.none, before: ""))
    }
    func testWordsAndAllCharacters() {
        XCTAssertEqual(FieldPolicy.autoShift(autocap: .words, before: "Nguyễn "), true)
        XCTAssertEqual(FieldPolicy.autoShift(autocap: .words, before: "Nguy"), false)
        XCTAssertEqual(FieldPolicy.autoShift(autocap: .allCharacters, before: "AB"), true)
    }

    /// Công tắc "Tự động viết hoa đầu câu" TẮT (công tắc iOS không áp cho bàn phím bên
    /// thứ ba): không auto-shift ở đầu câu và KHÔNG đọc context.
    func testSettingOffNeverShiftsAndSkipsContextRead() {
        var reads = 0
        for cap: UITextAutocapitalizationType? in [nil, .sentences, .words, .allCharacters] {
            XCTAssertNil(FieldPolicy.autoShift(enabled: false, autocap: cap, before: { reads += 1; return "" }))
        }
        XCTAssertEqual(reads, 0)
    }
    func testSettingOnUnchanged() {
        var reads = 0
        XCTAssertEqual(FieldPolicy.autoShift(enabled: true, autocap: nil, before: { reads += 1; return "Xin chào. " }), true)
        XCTAssertEqual(FieldPolicy.autoShift(enabled: true, autocap: .sentences, before: { reads += 1; return "Xin " }), false)
        XCTAssertEqual(reads, 2)
    }

    /// "Hello" ␣ ⇧ h: tiếng vọng textDidChange của dấu cách tới SAU khi chạm ⇧ không được hạ ⇧.
    func testLateHostEchoKeepsHandShift() {
        XCTAssertTrue(FieldPolicy.hostEchoKeepsHandShift(byHand: true, before: "Hello ", decidedOn: "Hello "))
        // Chưa chạm ⇧ / chữ đã đổi thật (host xoá ô, dời con trỏ) / chưa có lần quyết định ⇒ tính lại.
        XCTAssertFalse(FieldPolicy.hostEchoKeepsHandShift(byHand: false, before: "Hello ", decidedOn: "Hello "))
        XCTAssertFalse(FieldPolicy.hostEchoKeepsHandShift(byHand: true, before: "", decidedOn: "Hello "))
        XCTAssertFalse(FieldPolicy.hostEchoKeepsHandShift(byHand: true, before: "Hello ", decidedOn: nil))
        XCTAssertFalse(FieldPolicy.hostEchoKeepsHandShift(byHand: true, before: nil, decidedOn: nil))
    }

    /// Thanh địa chỉ (.webSearch): phím "," đổi thành "." như stock, nhưng vẫn là ô chữ tự do
    /// (gõ Telex / vuốt) và vẫn không tự thêm dấu cách / tự sửa.
    func testWebSearchFieldGetsDotKey() {
        let t = FieldTraits(keyboardType: .webSearch)
        XCTAssertEqual(t.inputKind, .search)
        XCTAssertTrue(t.inputKind.isFreeText)
        XCTAssertFalse(t.allowsAutoSpace)
        XCTAssertFalse(AutoCorrect.fieldAllows(t))
        XCTAssertTrue(FieldTraits().inputKind.isFreeText)
        XCTAssertFalse(FieldTraits(keyboardType: .URL).inputKind.isFreeText)
    }
}

/// Ô email (người nhận Gmail/Outlook — cũng là ô tìm danh bạ theo tên): Telex BẬT + bảo vệ địa chỉ.
/// Song sinh Android EmailTokenGuardTest.
final class EmailFieldPolicyTests: XCTestCase {
    func testEmailFieldsCompose() {
        XCTAssertTrue(FieldPolicy.emailCompose(keyboardType: .emailAddress, contentType: nil))
        XCTAssertTrue(FieldPolicy.emailCompose(keyboardType: .emailAddress, contentType: .emailAddress))
        XCTAssertTrue(FieldPolicy.emailCompose(keyboardType: .default, contentType: .emailAddress))
        let t = FieldTraits(keyboardType: .emailAddress, autocorrection: .no)
        XCTAssertTrue(t.emailCompose)
        XCTAssertFalse(t.telexLiteral)
        XCTAssertTrue(t.passthrough)          // tính năng khác (gõ tắt, tự sửa, vuốt…) vẫn tắt
        XCTAssertFalse(t.allowsAutoSpace)
        XCTAssertFalse(t.allowsMathResults)
        XCTAssertFalse(AutoCorrect.fieldAllows(t))
        XCTAssertEqual(t.inputKind, .email)   // bàn phím email (@ .) giữ nguyên
        XCTAssertFalse(StripMode.learns(learnWords: true, traits: t, incognito: false))
    }

    func testOtherLiteralFieldsUnchanged() {
        // Ô đăng nhập / mật khẩu / OTP / URL dùng bàn email: vẫn literal.
        for c: UITextContentType in [.username, .password, .newPassword, .oneTimeCode, .URL] {
            XCTAssertFalse(FieldPolicy.emailCompose(keyboardType: .emailAddress, contentType: c), c.rawValue)
            XCTAssertTrue(FieldTraits(keyboardType: .emailAddress, contentType: c).telexLiteral, c.rawValue)
        }
        XCTAssertFalse(FieldPolicy.emailCompose(keyboardType: .URL, contentType: .emailAddress))
        XCTAssertFalse(FieldTraits(keyboardType: .emailAddress, secure: true).emailCompose)
        XCTAssertTrue(FieldTraits(keyboardType: .URL).telexLiteral)
        XCTAssertTrue(FieldTraits(contentType: .username).telexLiteral)
        XCTAssertTrue(FieldTraits(keyboardType: .numberPad, contentType: .oneTimeCode).telexLiteral)
        XCTAssertFalse(FieldTraits().telexLiteral)
        XCTAssertFalse(FieldTraits().emailCompose)
        XCTAssertTrue(StripMode.learns(learnWords: true, traits: FieldTraits(), incognito: false))
    }
}

/// Quyết định thuần của EmailTokenGuard.
final class EmailTokenGuardTests: XCTestCase {
    func testTokenTailAndMarks() {
        XCTAssertEqual(EmailTokenGuard.tokenTail("Sơn, phuc@gm"), "phuc@gm")
        XCTAssertEqual(EmailTokenGuard.tokenTail("a;b"), "b")
        XCTAssertEqual(EmailTokenGuard.tokenTail("abc "), "")
        XCTAssertEqual(EmailTokenGuard.tokenTail("abc"), "abc")
        XCTAssertTrue(EmailTokenGuard.hasMark("a.b"))
        XCTAssertTrue(EmailTokenGuard.hasMark("@"))
        XCTAssertFalse(EmailTokenGuard.hasMark("tuan_anh-1+2"))
    }

    func testSyncReadsExistingToken() {
        var g = EmailTokenGuard()
        XCTAssertFalse(g.synced)
        g.sync(context: "Sơn, an@x")
        XCTAssertTrue(g.synced); XCTAssertTrue(g.literal)
        g.sync(context: "an@x.com, ")
        XCTAssertFalse(g.literal)
        g.sync(context: nil)
        XCTAssertTrue(g.synced); XCTAssertFalse(g.literal)
    }

    func testRestorePlanCoversCommittedPiecesAndOpenWord() {
        var g = EmailTokenGuard()
        g.sync(context: "")
        XCTAssertFalse(g.needsRestore("_"))
        XCTAssertTrue(g.needsRestore("@"))
        XCTAssertTrue(g.needsRestore("."))
        g.appended(shown: "tuấn", raw: "tuaans", text: "_")
        XCTAssertFalse(g.literal)
        let plan = g.restorePlan(composed: "ạnh", composedRaw: "anhj")
        XCTAssertEqual(plan?.shown, "tuấn_ạnh")
        XCTAssertEqual(plan?.raw, "tuaans_anhj")
        g.restored(to: "tuaans_anhj", text: "@")
        XCTAssertTrue(g.literal)
        XCTAssertFalse(g.needsRestore("."))
        // dấu phẩy ⇒ token mới
        g.appended(shown: "", raw: "", text: ", ")
        XCTAssertFalse(g.literal)
        XCTAssertEqual(g.shown, "")
    }

    func testNoPlanWhenAlreadyRaw() {
        var g = EmailTokenGuard()
        g.sync(context: "")
        g.appended(shown: "phuc", raw: "phuc", text: "")
        XCTAssertNil(g.restorePlan(composed: "", composedRaw: ""))
        XCTAssertNil(g.restorePlan(composed: "nguyen", composedRaw: "nguyen"))
    }

    func testBackspaceTracking() {
        var g = EmailTokenGuard()
        g.sync(context: "")
        g.restored(to: "an", text: "@")
        XCTAssertTrue(g.literal)
        g.deletedOne()                         // xoá "@" ⇒ token lại là chữ
        XCTAssertFalse(g.literal)
        XCTAssertEqual(g.shown, "an")
        g = EmailTokenGuard(); g.sync(context: "")
        g.appended(shown: "tuấn", raw: "tuaans", text: "")
        g.deletedOne()                         // "n" ≠ "s": phần còn lại thành chữ có sẵn
        XCTAssertEqual(g.shown, "")
        XCTAssertNil(g.restorePlan(composed: "", composedRaw: ""))
        g.deletedOne()                         // xoá vào chữ có sẵn ⇒ đọc lại context
        XCTAssertFalse(g.synced)
    }
}
