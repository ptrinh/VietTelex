import XCTest

/// #171 — trượt từ phím 123: phần quyết định thuần.
final class PlaneSlideTests: XCTestCase {
    func testMoveReportsOnlyChanges() {
        var s = PlaneSlide<String>()
        XCTAssertNil(s.move(over: nil), "còn trên phím 123 / khe: không đổi")
        let a = s.move(over: "2")
        XCTAssertEqual(a?.leave, nil); XCTAssertEqual(a?.enter, "2")
        XCTAssertNil(s.move(over: "2"), "trong cùng phím: không vẽ lại")
        let b = s.move(over: "3")
        XCTAssertEqual(b?.leave, "2"); XCTAssertEqual(b?.enter, "3")
        let c = s.move(over: nil)
        XCTAssertEqual(c?.leave, "3"); XCTAssertEqual(c?.enter, nil)
        XCTAssertNil(s.over)
    }

    func testLiftInsertsOnlyOverInsertableKeyAndNotCancelled() {
        XCTAssertEqual(PlaneSlide<String>.lift(over: "2", cancelled: false), "2")
        XCTAssertNil(PlaneSlide<String>.lift(over: nil, cancelled: false), "khe / phím không chèn: không gì")
        XCTAssertNil(PlaneSlide<String>.lift(over: "2", cancelled: true), "huỷ: không gì")
    }
}

/// #171 — luồng thật qua KeyboardView: chạm 123 đổi plane lúc chạm, trượt sang phím rồi nhấc.
final class PlaneSlideKeyboardFlowTests: XCTestCase {
    private final class Log { var keys: [String] = [] }

    @MainActor private func harness(vni: Bool = false) -> (KeyboardView, UIView, MockProxy, Log) {
        let p = MockProxy(), log = Log()
        var settings = KeyboardSettings(); settings.vniMode = vni
        let b = EngineBridge(settings: settings)
        let kb = KeyboardView(needsGlobe: false, inputController: nil) { key in
            log.keys.append("\(key)")
            switch key {
            case .letter(let c): b.letter(c, proxy: p)
            case .space: b.boundary(" ", proxy: p)
            case .text(let t):                         // như controller: số trong từ VNI = phím dấu
                if t.count == 1, let d = t.first, b.vniDigit(d, proxy: p) { break }
                b.boundary(t, proxy: p)
            case .backspace: b.backspace(proxy: p)
            default: break
            }
        }
        let host = UIView(frame: CGRect(x: 0, y: 0, width: 390, height: 320))
        host.addSubview(kb)
        kb.frame = host.bounds
        kb.layoutIfNeeded()
        return (kb, host, p, log)
    }

    /// Gõ chữ qua router (chạm thường).
    @MainActor private func type(_ s: String, _ kb: KeyboardView) {
        var t: TimeInterval = 50
        for c in s {
            guard let f = kb.debugLetterFrame(String(c)) else { XCTFail("phím \(c)"); return }
            kb.debugTouch(from: CGPoint(x: f.midX, y: f.midY + TouchGeometry.yOffset), through: [], start: t)
            t += 1
        }
    }

    @MainActor private func center(_ kb: KeyboardView, _ title: String) throws -> CGPoint {
        kb.layoutIfNeeded()
        let b = try XCTUnwrap(kb.debugKeyButton(title), "phím \(title)")
        let f = kb.convert(b.bounds, from: b)
        return CGPoint(x: f.midX, y: f.midY)
    }

    @MainActor private func controlCenter(_ kb: KeyboardView, _ label: String) throws -> CGPoint {
        kb.layoutIfNeeded()
        let c = try XCTUnwrap(kb.debugControl(label), "phím \(label)")
        let f = kb.convert(c.bounds, from: c)
        return CGPoint(x: f.midX, y: f.midY)
    }

    @MainActor func testTapOn123StaysOnNumbers() throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom == .pad, "iPad giữ như cũ")
        let (kb, host, p, log) = harness()
        XCTAssertTrue(kb.debugPlaneSlideBegin())
        XCTAssertEqual(kb.debugPlaneName, "numbers", "đổi plane ngay lúc chạm")
        // nhấc ngay chỗ 123 cũ (giờ là ABC): không chèn, ở lại plane số
        kb.debugPlaneSlideLift(at: try controlCenter(kb, L("Chữ")))
        XCTAssertEqual(kb.debugPlaneName, "numbers")
        XCTAssertEqual(p.text, "")
        XCTAssertTrue(log.keys.isEmpty)
        withExtendedLifetime(host) {}
    }

    @MainActor func testSlideToDigitInsertsAndReturnsToLetters() throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom == .pad)
        let (kb, host, p, log) = harness()
        XCTAssertTrue(kb.debugPlaneSlideBegin())
        let two = try center(kb, "2"), three = try center(kb, "3")
        kb.debugPlaneSlideMove(to: three)
        XCTAssertEqual(kb.debugPlaneSlideOver, "3")
        XCTAssertTrue(kb.debugBalloonVisible, "phím dưới ngón hiện xem trước")
        kb.debugPlaneSlideMove(to: two)
        XCTAssertEqual(kb.debugPlaneSlideOver, "2")
        XCTAssertTrue(log.keys.isEmpty, "đang trượt: chưa chèn gì")
        kb.debugPlaneSlideLift(at: two)
        XCTAssertEqual(p.text, "2")
        XCTAssertEqual(log.keys, ["text(\"2\")"])
        XCTAssertEqual(kb.debugPlaneName, "letters", "tự về plane chữ")
        XCTAssertFalse(kb.debugPlaneSlideActive)
        withExtendedLifetime(host) {}
    }

    @MainActor func testSlideToSymbolInsertsAndReturnsToLetters() throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom == .pad)
        let (kb, host, p, _) = harness()
        XCTAssertTrue(kb.debugPlaneSlideBegin())
        let at = try center(kb, "@")
        kb.debugPlaneSlideMove(to: at)
        kb.debugPlaneSlideLift(at: at)
        XCTAssertEqual(p.text, "@")
        XCTAssertEqual(kb.debugPlaneName, "letters")
        withExtendedLifetime(host) {}
    }

    @MainActor func testLiftOnNonInsertableKeyInsertsNothing() throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom == .pad)
        let (kb, host, p, log) = harness()
        XCTAssertTrue(kb.debugPlaneSlideBegin())
        kb.debugPlaneSlideMove(to: try center(kb, "1"))
        let bs = try controlCenter(kb, L("Xoá"))
        kb.debugPlaneSlideMove(to: bs)
        XCTAssertNil(kb.debugPlaneSlideOver, "⌫ không phải phím chèn được")
        kb.debugPlaneSlideLift(at: bs)
        XCTAssertEqual(p.text, "")
        XCTAssertTrue(log.keys.isEmpty, "không ⌫, không ký tự")
        XCTAssertEqual(kb.debugPlaneName, "numbers")
        withExtendedLifetime(host) {}
    }

    @MainActor func testLiftOutsideKeysInsertsNothing() throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom == .pad)
        let (kb, host, p, _) = harness()
        XCTAssertTrue(kb.debugPlaneSlideBegin())
        kb.debugPlaneSlideMove(to: try center(kb, "9"))
        kb.debugPlaneSlideLift(at: CGPoint(x: -40, y: -40))
        XCTAssertEqual(p.text, "")
        XCTAssertEqual(kb.debugPlaneName, "numbers")
        withExtendedLifetime(host) {}
    }

    @MainActor func testCancelledSlideInsertsNothing() throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom == .pad)
        let (kb, host, p, _) = harness()
        XCTAssertTrue(kb.debugPlaneSlideBegin())
        let five = try center(kb, "5")
        kb.debugPlaneSlideMove(to: five)
        kb.debugPlaneSlideLift(at: five, cancelled: true)
        XCTAssertEqual(p.text, "")
        XCTAssertEqual(kb.debugPlaneName, "numbers")
        withExtendedLifetime(host) {}
    }

    @MainActor func testSecondFingerEndsSlideWithoutInserting() throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom == .pad)
        let (kb, host, p, _) = harness()
        XCTAssertTrue(kb.debugPlaneSlideBegin())
        let seven = try center(kb, "7")
        kb.debugPlaneSlideMove(to: seven)
        kb.debugPlaneSlideSecondTouch()
        XCTAssertFalse(kb.debugPlaneSlideActive)
        XCTAssertNil(kb.debugPlaneSlideOver)
        kb.debugPlaneSlideLift(at: seven)                 // ngón đầu nhấc sau đó: đã hết trượt
        XCTAssertEqual(p.text, "")
        XCTAssertEqual(kb.debugPlaneName, "numbers")
        withExtendedLifetime(host) {}
    }

    /// VNI: số trượt tới = đúng như chạm phím số đó (cùng phím gửi đi, cùng kết quả trong từ).
    @MainActor func testVNIDigitViaSlideMatchesTap() throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom == .pad)
        // chạm thường: 123 → "1" → ABC
        let (kb1, host1, p1, log1) = harness(vni: true)
        type("viet", kb1)
        XCTAssertTrue(kb1.debugPlaneSlideBegin())
        kb1.debugPlaneSlideLift(at: try controlCenter(kb1, L("Chữ")))     // chạm 123 thường: ở plane số
        let one = try XCTUnwrap(kb1.debugKeyButton("6"))
        one.sendActions(for: .touchDown); one.sendActions(for: .touchUpInside)
        let tapText = p1.text, tapKeys = log1.keys
        // trượt: 123 ⇢ "6" nhấc
        let (kb2, host2, p2, log2) = harness(vni: true)
        type("viet", kb2)
        XCTAssertTrue(kb2.debugPlaneSlideBegin())
        let six = try center(kb2, "6")
        kb2.debugPlaneSlideMove(to: six)
        kb2.debugPlaneSlideLift(at: six)
        XCTAssertEqual(p2.text, tapText)
        XCTAssertEqual(log2.keys, tapKeys)
        XCTAssertEqual(SwipeTyping.fold(p2.text).lowercased(), "viet")
        XCTAssertNotEqual(p2.text.lowercased(), "viet6", "VNI: 6 là dấu mũ, không phải chữ số")
        XCTAssertEqual(kb2.debugPlaneName, "letters")
        withExtendedLifetime([host1, host2]) {}
    }
}
