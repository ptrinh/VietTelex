// KeyAlternatesTests — giữ phím chữ ra số / ký hiệu (issue #98). Bảng theo fixture chung
// Fixtures/key-alternates.txt (android KeyAlternatesTests.kt đọc cùng file).
import XCTest
import UIKit

final class KeyAlternatesTests: XCTestCase {
    private func fixture() throws -> [(group: String, key: Character, alt: String)] {
        let url = try XCTUnwrap(Bundle(for: KeyAlternatesTests.self)
            .url(forResource: "key-alternates", withExtension: "txt"))
        return try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
            .filter { !$0.hasPrefix("#") && !$0.isEmpty }
            .map { l in
                let c = l.split(separator: "\t").map(String.init)
                return (c[0], Character(c[1]), c[2])
            }
    }

    func testTablesMatchSharedFixture() throws {
        let f = try fixture()
        var digits: [Character: String] = [:], symbols: [Character: String] = [:]
        for r in f { if r.group == "numbers" { digits[r.key] = r.alt } else { symbols[r.key] = r.alt } }
        XCTAssertEqual(digits, KeyAlternates.digits)
        XCTAssertEqual(symbols, KeyAlternates.symbols)
        XCTAssertEqual(Set(digits.keys), Set("qwertyuiop"))
        XCTAssertEqual(Set(symbols.keys), Set("asdfghjklzxcvbnm"))
    }

    func testNoDuplicateAndNoLetters() {
        let all = Array(KeyAlternates.digits.values) + Array(KeyAlternates.symbols.values)
        XCTAssertEqual(Set(all).count, all.count, "không trùng ký tự phụ")
        for a in all { XCTAssertFalse(a.first!.isLetter, a) }
        // Bản Việt: ' ; ít dùng → % / (ngày tháng, link); $ thay ₫ (₫ ở bàn ký hiệu).
        XCTAssertEqual(KeyAlternates.symbols["d"], "$")
        XCTAssertEqual(KeyAlternates.symbols["c"], "%")
        XCTAssertEqual(KeyAlternates.symbols["b"], "/")
    }

    /// Giữ "," ra "." khi có ít nhất một công tắc giữ phím đang có hiệu lực.
    func testCommaHoldGating() {
        func on(_ n: Bool, _ s: Bool, row: Bool = false, pad: Bool = false, ax: Bool = false) -> Bool {
            KeyAlternates.commaHold(alternates: KeyAlternates.map(numbers: n, symbols: s, numberRow: row,
                                                                  isPad: pad, accessibility: ax))
        }
        XCTAssertTrue(on(true, false))
        XCTAssertTrue(on(false, true))
        XCTAssertTrue(on(true, true))
        XCTAssertFalse(on(false, false))
        XCTAssertFalse(on(true, false, row: true), "công tắc số không hiệu lực khi hàng số bật")
        XCTAssertTrue(on(true, true, row: true))
        XCTAssertFalse(on(true, true, pad: true), "iPad không đổi")
        XCTAssertFalse(on(true, true, ax: true))
        XCTAssertEqual(KeyAlternates.commaAlt, ".")
    }

    func testHoldCommaSwapsPendingCommit() {
        let q = KeyCommitQueue(), id = ObjectIdentifier(q)
        var out = ""
        q.arm(id) { out += "," }
        XCTAssertTrue(KeyAlternates.holdComma(q, id: id) { out += $0 })
        q.release(id)
        XCTAssertEqual(out, ".")
        out = ""
        q.arm(id) { out += "," }
        q.flush()                                               // ngón khác chạm trước khi đủ giờ
        XCTAssertFalse(KeyAlternates.holdComma(q, id: id) { out += $0 })
        q.release(id)
        XCTAssertEqual(out, ",", "đã chốt phẩy thì hết giờ không đổi gì")
    }

    /// "." giữ từ "," chốt từ đang gõ y như "," (cùng đường .text → boundary).
    func testCommaHoldPeriodCommitsComposition() {
        for punct in [",", "."] {
            let p = MockProxy(), b = EngineBridge(settings: KeyboardSettings())
            for ch in "tieengs" { b.letter(ch, proxy: p) }
            XCTAssertTrue(b.isComposing)
            b.boundary(punct, proxy: p)
            XCTAssertFalse(b.isComposing)
            XCTAssertEqual(p.text, "tiếng" + punct)
        }
    }

    func testMapGating() {
        XCTAssertEqual(KeyAlternates.map(numbers: true, symbols: false, numberRow: false), KeyAlternates.digits)
        XCTAssertTrue(KeyAlternates.map(numbers: true, symbols: false, numberRow: true).isEmpty,
                      "hàng số bật ⇒ giữ q ra số vô nghĩa")
        XCTAssertEqual(KeyAlternates.map(numbers: true, symbols: true, numberRow: true), KeyAlternates.symbols)
        XCTAssertEqual(KeyAlternates.map(numbers: true, symbols: true, numberRow: false).count, 26)
        XCTAssertTrue(KeyAlternates.map(numbers: false, symbols: false, numberRow: false).isEmpty)
        XCTAssertTrue(KeyAlternates.map(numbers: true, symbols: true, numberRow: false, isPad: true).isEmpty)
        XCTAssertTrue(KeyAlternates.map(numbers: true, symbols: true, numberRow: false, accessibility: true).isEmpty)
        XCTAssertTrue(KeyAlternates.numbersSettingVisible(numberRow: false))
        XCTAssertFalse(KeyAlternates.numbersSettingVisible(numberRow: true))
    }

    func testHoldStateMachine() {
        var h = KeyAlternates.Hold(alt: "3", start: .zero)
        XCTAssertFalse(h.move(to: CGPoint(x: 6, y: 6)))       // trong slop
        XCTAssertNil(h.commit)                                  // chưa đủ giờ = chạm thường
        XCTAssertTrue(h.fire())
        XCTAssertEqual(h.commit, "3")
        XCTAssertFalse(h.move(to: CGPoint(x: 80, y: 0)))       // đã bắn: trôi không hủy
        h.cancel()
        XCTAssertEqual(h.commit, "3")

        var d = KeyAlternates.Hold(alt: "@", start: .zero)
        XCTAssertTrue(d.move(to: CGPoint(x: KeyAlternates.slop + 1, y: 0)))
        XCTAssertFalse(d.fire(), "trôi trước khi đủ giờ ⇒ không bao giờ thành ký tự phụ")
        XCTAssertNil(d.commit)

        var c = KeyAlternates.Hold(alt: "@", start: .zero)
        c.cancel()                                              // ngón khác / thành vuốt
        XCTAssertFalse(c.fire())
    }

    func testThresholdBetweenTrackpadAndOtherHolds() {
        XCTAssertGreaterThan(KeyAlternates.holdDelay, 0.3)
        XCTAssertLessThan(KeyAlternates.holdDelay, 0.45)
    }

    /// Luồng controller cho .replaceLastLetter: huỷ đúng phím chữ (checkpoint, không ⌫) rồi
    /// chốt từ + chèn ký tự phụ như gõ hàng số.
    func testRollbackKeepsTelexComposition() {
        let p = MockProxy(), b = EngineBridge(settings: KeyboardSettings())
        for ch in "tie" { b.letter(ch, proxy: p) }
        b.letter("e", proxy: p)                                 // chạm e: "tiê"
        XCTAssertEqual(p.text, "tiê")
        XCTAssertTrue(b.undoLastLetter(proxy: p))
        b.boundary("3", proxy: p)
        XCTAssertEqual(p.text, "tie3")
        b.letter("a", proxy: p)                                 // từ mới sau ký tự phụ
        XCTAssertEqual(p.text, "tie3a")

        let p2 = MockProxy(), b2 = EngineBridge(settings: KeyboardSettings())
        for ch in "tieng" { b2.letter(ch, proxy: p2) }
        b2.letter("s", proxy: p2)                               // phím dấu: "tiéng"
        XCTAssertTrue(b2.undoLastLetter(proxy: p2))
        b2.boundary("#", proxy: p2)
        XCTAssertEqual(p2.text, "tieng#")
    }

    // MARK: KeyboardView (iPhone)

    @MainActor private func makeKeyboard(numbers: Bool, symbols: Bool, numberRow: Bool = false,
                                         side: SpaceSideKey = .comma,
                                         emoji: EmojiKeyPlacement = .bottom, suggestions: Bool = false,
                                         log: @escaping (String) -> Void) -> (KeyboardView, UIView) {
        let kb = KeyboardView(needsGlobe: false, inputController: nil) { k in
            switch k {
            case .letter(let c): log("L\(c.lowercased())")   // shift đầu ô bật sẵn
            case .replaceLastLetter(let s): log("R\(s)")
            case .text(let s): log("T\(s)")
            default: log("?")
            }
        }
        let host = UIView(frame: CGRect(x: 0, y: 0, width: 390, height: 320))
        host.addSubview(kb)
        kb.frame = host.bounds
        kb.numberRowEnabled = numberRow
        kb.spaceSideKey = side
        kb.emojiKeyPlacement = emoji
        if suggestions { kb.setSuggestionsEnabled(true) }
        kb.configureKeyAlternates(numbers: numbers, symbols: symbols)
        kb.layoutIfNeeded()
        return (kb, host)
    }

    @MainActor func testHoldReplacesLetterWithAlternate() throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom == .pad, "iPad dùng vuốt xuống")
        var out: [String] = []
        let (kb, host) = makeKeyboard(numbers: true, symbols: true) { out.append($0) }
        XCTAssertEqual(kb.debugAltHint("e"), "3")
        XCTAssertEqual(kb.debugAltHint("a"), "@")
        XCTAssertTrue(kb.debugHold("e"))
        XCTAssertEqual(out.suffix(2), ["Le", "R3"])
        out = []
        kb.debugHold("e", fire: false)                          // nhả trước khi đủ giờ
        XCTAssertEqual(out, ["Le"])
        out = []
        kb.debugHold("e", drift: 30)                            // trôi ⇒ không phải giữ
        XCTAssertEqual(out, ["Le"])
        out = []
        kb.debugHold("m")
        XCTAssertEqual(out, ["Lm", "R?"])
        withExtendedLifetime(host) {}
    }

    /// Đã bắn mà ngón khác chạm: ký tự phụ chốt TRƯỚC phím mới (checkpoint đúng phím).
    @MainActor func testSecondTouchAfterFireCommitsAlternateFirst() throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom == .pad)
        var out: [String] = []
        let (kb, host) = makeKeyboard(numbers: true, symbols: false) { out.append($0) }
        kb.debugHold("q", secondTouch: "a")
        XCTAssertEqual(out, ["Lq", "R1", "La"])
        withExtendedLifetime(host) {}
    }

    /// Gõ vuốt bật (#172): chữ hoãn tới lúc nhấc nhưng giữ ra ký tự phụ cho đúng chuỗi như
    /// tắt — chữ chèn rồi mới thay (không ⌫ oan chữ trước), cả khi ngón khác chạm sau khi bắn.
    @MainActor func testHoldWithSwipeTypingOnSameOutput() throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom == .pad)
        var out: [String] = []
        let (kb, host) = makeKeyboard(numbers: true, symbols: true) { out.append($0) }
        kb.swipeEnabled = true
        XCTAssertTrue(kb.debugHold("e"))
        XCTAssertEqual(out, ["Le", "R3"])
        out = []
        kb.debugHold("e", fire: false)
        XCTAssertEqual(out, ["Le"])
        out = []
        kb.debugHold("q", secondTouch: "a")
        XCTAssertEqual(out, ["Lq", "R1", "La"])
        withExtendedLifetime(host) {}
    }

    @MainActor func testOffMeansNoHintsNoTimer() throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom == .pad)
        var out: [String] = []
        let (kb, host) = makeKeyboard(numbers: false, symbols: false) { out.append($0) }
        XCTAssertNil(kb.debugAltHint("q"))
        XCTAssertFalse(kb.debugHold("q"), "tắt ⇒ không hẹn giờ")
        XCTAssertEqual(out, ["Lq"])
        XCTAssertFalse(kb.altHoldActive)
        // Hàng số bật ⇒ công tắc số không còn tác dụng; ký hiệu vẫn chạy.
        let (kb2, host2) = makeKeyboard(numbers: true, symbols: true, numberRow: true) { _ in }
        XCTAssertNil(kb2.debugAltHint("q"))
        XCTAssertEqual(kb2.debugAltHint("s"), "#")
        withExtendedLifetime((host, host2)) {}
    }

    @MainActor func testCommaHoldTypesPeriod() throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom == .pad, "iPad không đổi")
        var out: [String] = []
        let (kb, host) = makeKeyboard(numbers: true, symbols: false) { out.append($0) }
        XCTAssertEqual(kb.debugCommaHint, ".")
        XCTAssertTrue(kb.debugCommaHold())
        XCTAssertEqual(out, ["T."])
        out = []
        kb.debugCommaHold(fire: false)                          // nhả trước khi đủ giờ
        XCTAssertEqual(out, ["T,"])
        out = []
        kb.debugCommaHold(secondTouch: "a")                     // đã bắn: "." chốt TRƯỚC phím mới
        XCTAssertEqual(out, ["T.", "La"])
        out = []
        kb.debugCommaHold(secondTouch: "a", secondBeforeFire: true)   // ngón khác chạm trước khi đủ giờ
        XCTAssertEqual(out, ["T,", "La"])
        withExtendedLifetime(host) {}
    }

    @MainActor func testCommaHoldOffIsPlainComma() throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom == .pad)
        var out: [String] = []
        let (kb, host) = makeKeyboard(numbers: false, symbols: false) { out.append($0) }
        XCTAssertNil(kb.debugCommaHint)
        XCTAssertFalse(kb.debugCommaHold(), "tắt ⇒ không hẹn giờ")
        XCTAssertEqual(out, ["T,"])
        out = []
        // Chỉ công tắc số mà hàng số bật ⇒ không có hiệu lực ⇒ "," thường.
        let (kb2, host2) = makeKeyboard(numbers: true, symbols: false, numberRow: true) { out.append($0) }
        XCTAssertNil(kb2.debugCommaHint)
        XCTAssertFalse(kb2.debugCommaHold())
        XCTAssertEqual(out, ["T,"])
        // Chỉ ký hiệu ⇒ bật.
        let (kb3, host3) = makeKeyboard(numbers: false, symbols: true) { _ in }
        XCTAssertEqual(kb3.debugCommaHint, ".")
        withExtendedLifetime((host, host2, host3)) {}
    }

    @MainActor func testVoiceOverDisablesAlternates() throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom == .pad)
        let (kb, host) = makeKeyboard(numbers: true, symbols: true) { _ in }
        kb.altAccessibility = true
        kb.layoutIfNeeded()
        XCTAssertNil(kb.debugAltHint("q"))
        XCTAssertNil(kb.debugCommaHint)
        XCTAssertFalse(kb.altHoldActive)
        withExtendedLifetime(host) {}
    }

    // MARK: KeyboardView (iPad) — giữ phím chữ = ký tự phụ in trên phím (bug Phil 27/09:
    // giữ "w" không ra "2"; trước chỉ vuốt xuống được).

    @MainActor private func makePadKeyboard(log: @escaping (String) -> Void) -> (KeyboardView, UIView) {
        let kb = KeyboardView(needsGlobe: true, inputController: nil) { k in
            switch k {
            case .letter(let c): log("L\(c.lowercased())")
            case .replaceLastLetter(let s): log("R\(s)")
            case .text(let s): log("T\(s)")
            default: log("?")
            }
        }
        let host = UIView(frame: CGRect(x: 0, y: 0, width: 834, height: 300))
        host.addSubview(kb)
        kb.frame = host.bounds
        kb.configureKeyAlternates(numbers: false, symbols: false)   // công tắc iPhone không ảnh hưởng iPad
        kb.layoutIfNeeded()
        return (kb, host)
    }

    func testPadMapIsTheHintPrintedOnKeys() {
        XCTAssertEqual(KeyAlternates.padMap().count, 26)
        XCTAssertEqual(KeyAlternates.padMap()["w"], "2")
        XCTAssertEqual(KeyAlternates.padMap()["a"], "@")
        XCTAssertEqual(KeyAlternates.padMap()["f"], "&", "bảng iPad khác iPhone (f → _)")
        for (k, v) in KeyAlternates.padHints { XCTAssertEqual(KeyboardView.padSecondary[String(k)], v) }
    }

    /// Giữ phím 2 tầng "?." / "!," trên trang chữ iPad rồi nhấc ⇒ balloon phải tắt
    /// (trước đây kẹt lại trên phím — Phil 27/09).
    @MainActor func testPadPunctHoldHidesBalloonOnRelease() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad)
        var out: [String] = []
        let (kb, host) = makePadKeyboard { out.append($0) }
        _ = host
        for label in [".", ","] {
            let b = try XCTUnwrap(kb.debugControl(label) as? UIControl, label)
            b.sendActions(for: .touchDown)
            kb.debugChoosePadAlt(b)
            XCTAssertTrue(kb.debugBalloonVisible, "\(label): giữ ⇒ balloon hiện")
            b.sendActions(for: .touchUpInside)
            XCTAssertFalse(kb.debugBalloonVisible, "\(label): nhấc ⇒ balloon tắt")
        }
        XCTAssertEqual(out, ["T?", "T!"])
    }

    @MainActor func testPadHoldTypesHint() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad)
        var out: [String] = []
        let (kb, host) = makePadKeyboard { out.append($0) }
        XCTAssertTrue(kb.altHoldActive, "iPad: nhãn luôn hiện ⇒ giữ luôn bật")
        XCTAssertEqual(kb.debugPadHint("w") ?? kb.debugPadHint("W"), "2")
        XCTAssertTrue(kb.debugHold("w"))
        XCTAssertEqual(out, ["Lw", "R2"])
        out = []
        kb.debugHold("a")
        XCTAssertEqual(out, ["La", "R@"])
        out = []
        kb.debugHold("e")                                        // "tie" + giữ e ⇒ R3 (rollback ở bridge)
        XCTAssertEqual(out, ["Le", "R3"])
        out = []
        kb.debugHold("e", fire: false)                          // chạm thường ⇒ chữ
        XCTAssertEqual(out, ["Le"])
        out = []
        kb.debugHold("e", drift: 30)                            // trôi ngang ⇒ không phải giữ
        XCTAssertEqual(out, ["Le"])
        out = []
        kb.debugHold("q", secondTouch: "s")                     // đã bắn: chốt "1" trước phím mới
        XCTAssertEqual(out, ["Lq", "R1", "Ls"])
        // Vuốt xuống vẫn ra ký tự phụ (không cần đợi giờ giữ).
        out = []
        let x = try XCTUnwrap(kb.debugLetterFrame("x"))
        let c = CGPoint(x: x.midX, y: x.midY)
        kb.debugTouch(from: c, through: [CGPoint(x: c.x, y: c.y + 12), CGPoint(x: c.x, y: c.y + 25)], start: 10)
        XCTAssertEqual(out, ["Lx", "R-"])
        // Chạm thường.
        out = []
        kb.debugTouch(from: c, through: [], start: 20)
        XCTAssertEqual(out, ["Lx"])
        withExtendedLifetime(host) {}
    }

    /// Toàn luồng như controller: "tie" + giữ e trên iPad ⇒ huỷ đúng phím e (checkpoint,
    /// không ⌫) rồi chốt "3" ⇒ "tie3" (giống iPhone).
    @MainActor func testPadHoldRollbackThroughBridge() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad)
        let p = MockProxy(), br = EngineBridge(settings: KeyboardSettings())
        for ch in "tie" { br.letter(ch, proxy: p) }
        let kb = KeyboardView(needsGlobe: true, inputController: nil) { k in
            switch k {
            case .letter(let c): br.letter(Character(c.lowercased()), proxy: p)
            case .replaceLastLetter(let s): if br.undoLastLetter(proxy: p) { _ = br.boundary(s, proxy: p) }
            default: break
            }
        }
        let host = UIView(frame: CGRect(x: 0, y: 0, width: 834, height: 300))
        host.addSubview(kb)
        kb.frame = host.bounds
        kb.layoutIfNeeded()
        kb.debugHold("e")
        XCTAssertEqual(p.text, "tie3")
        withExtendedLifetime(host) {}
    }

    /// Bàn chữ iPad: không phím "," riêng cạnh space (stock), không giữ "," ra ".".
    @MainActor func testPadLettersBottomRowHasNoComma() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad)
        let (kb, host) = makePadKeyboard { _ in }
        for compact in [false, true] {
            kb.debugSetPadStyle(compact: compact)
            kb.layoutIfNeeded()
            let rows = kb.debugRowLabels()
            XCTAssertEqual(rows.last?.count, 6, "\(rows.last ?? [])")
            XCTAssertFalse(rows.last?.contains(",") ?? true)
            XCTAssertEqual(rows.last?.first, "Bàn phím tiếp theo")
            XCTAssertEqual(rows.last?[3], "Dấu cách")
            XCTAssertNil(kb.debugCommaHint)
        }
        withExtendedLifetime(host) {}
    }

    // MARK: "Phím cạnh dấu cách" (16/10/2026) — Dấu phẩy (mặc định) / Dấu chấm / Tắt

    func testSpaceSideKeyPure() {
        XCTAssertEqual(SpaceSideKey.defaultValue, .comma)
        XCTAssertEqual(SpaceSideKey.parse(nil), .comma)
        XCTAssertEqual(SpaceSideKey.parse("dot"), .comma)
        XCTAssertEqual(SpaceSideKey.parse(3), .comma)
        XCTAssertEqual(SpaceSideKey.parse("period"), .period)
        XCTAssertEqual(SpaceSideKey.parse("off"), .off)
        XCTAssertEqual(SpaceSideKey.key, "spaceSideKey")   // cùng khoá Android Keys.SPACE_SIDE_KEY
        XCTAssertEqual(KeyLayout.phoneLettersPuncts(.comma), [","])
        XCTAssertEqual(KeyLayout.phoneLettersPuncts(.period), ["."])
        XCTAssertEqual(KeyLayout.phoneLettersPuncts(.off), [])
        XCTAssertEqual(KeyLayout.phoneLettersPuncts(.both), [",", "."])
        XCTAssertEqual(KeyLayout.phoneLettersSides(.both).left, [","])
        XCTAssertEqual(KeyLayout.phoneLettersSides(.both).right, ["."])
        XCTAssertEqual(KeyLayout.phoneLettersSides(.comma).left, [])
        XCTAssertEqual(KeyLayout.phoneLettersSides(.period).right, ["."])
        XCTAssertEqual(SpaceSideKey.parse("both"), .both)
        XCTAssertEqual(SpaceSideKey.both.char, ",", "phím có giữ phím = ',' bên trái")
        XCTAssertEqual(SpaceSideKey.both.holdAlt, ".")
        XCTAssertEqual(SpaceSideKey.comma.holdAlt, ".")
        XCTAssertEqual(SpaceSideKey.period.holdAlt, ",")
        XCTAssertNil(SpaceSideKey.off.holdAlt)
        // Sao lưu: có Spec, mặc định "comma", đúng 4 giá trị.
        let spec = BackupSettings.all.first { $0.key == SpaceSideKey.key }
        XCTAssertNotNil(spec)
        if case .string(let def, let allowed)? = spec?.kind {
            XCTAssertEqual(def, "comma")
            XCTAssertEqual(Set(allowed), Set(SpaceSideKey.allCases.map(\.rawValue)))
        } else { XCTFail("spaceSideKey phải là .string") }
    }

    func testHoldCommaCustomAlt() {
        let q = KeyCommitQueue(), id = ObjectIdentifier(q)
        var out = ""
        q.arm(id) { out += "." }
        XCTAssertTrue(KeyAlternates.holdComma(q, id: id, alt: ",") { out += $0 })
        q.release(id)
        XCTAssertEqual(out, ",")
    }

    @MainActor private func punctsRightOfSpace(_ kb: KeyboardView) -> [String] {
        let row = kb.debugRowLabels().last ?? []
        guard let si = row.firstIndex(of: "Dấu cách") else { return ["?"] }
        return row[(si + 1)...].filter { [",", ".", "@", "/"].contains($0) }
    }

    @MainActor func testSpaceSideKeyBottomRow() throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom == .pad, "iPad không đổi")
        let (kb, host) = makeKeyboard(numbers: true, symbols: false) { _ in }
        XCTAssertEqual(kb.spaceSideKey, .comma, "mặc định = bố cục cũ")
        XCTAssertEqual(punctsRightOfSpace(kb), [","])
        let row0 = kb.debugRowLabels().last ?? []
        let space0 = try XCTUnwrap(kb.debugControl("Dấu cách"))
        let commaW = try XCTUnwrap(kb.debugKeyButton(",")).bounds.width
        XCTAssertEqual(commaW, 390 * KeyLayout.phoneLettersComma, accuracy: 1)
        let spaceW0 = space0.bounds.width

        let (kbP, hostP) = makeKeyboard(numbers: true, symbols: false, side: .period) { _ in }
        XCTAssertEqual(punctsRightOfSpace(kbP), ["."])
        XCTAssertEqual((kbP.debugRowLabels().last ?? []).count, row0.count, "cùng số phím")
        let dot = try XCTUnwrap(kbP.debugKeyButton("."))
        XCTAssertEqual(dot.bounds.width, commaW, accuracy: 0.5, "cùng cỡ phím ','")
        XCTAssertEqual(try XCTUnwrap(kbP.debugControl("Dấu cách")).bounds.width, spaceW0, accuracy: 0.5)

        let (kbO, hostO) = makeKeyboard(numbers: true, symbols: false, side: .off) { _ in }
        XCTAssertEqual(punctsRightOfSpace(kbO), [])
        XCTAssertNil(kbO.debugKeyButton(","))
        XCTAssertNil(kbO.debugKeyButton("."))
        XCTAssertEqual((kbO.debugRowLabels().last ?? []).count, row0.count - 1)
        XCTAssertGreaterThan(try XCTUnwrap(kbO.debugControl("Dấu cách")).bounds.width, spaceW0 + commaW - 1)
        // Đổi tuỳ chọn khi đang hiện ⇒ dựng lại hàng đáy.
        kb.spaceSideKey = .off
        XCTAssertEqual(punctsRightOfSpace(kb), [])
        kb.spaceSideKey = .period
        XCTAssertEqual(punctsRightOfSpace(kb), ["."])
        withExtendedLifetime((hostP, hostO)) {}

        // Ô email / URL / thanh địa chỉ: giữ nguyên dù tuỳ chọn nào.
        for side in SpaceSideKey.allCases {
            kb.spaceSideKey = side
            kb.configureInputKind(.email); kb.layoutIfNeeded()
            XCTAssertEqual(punctsRightOfSpace(kb), ["@", "."], "\(side)")
            kb.configureInputKind(.url); kb.layoutIfNeeded()
            XCTAssertEqual(punctsRightOfSpace(kb), [".", "/"], "\(side)")
            kb.configureInputKind(.search); kb.layoutIfNeeded()
            XCTAssertEqual(punctsRightOfSpace(kb), ["."], "\(side)")
            kb.configureInputKind(.normal); kb.layoutIfNeeded()
        }
        withExtendedLifetime(host) {}
    }

    /// Dấu chấm: giữ "." ra "," (nhãn "," nhỏ góc phím), chạm thường ra ".".
    @MainActor func testPeriodSideKeyHoldTypesComma() throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom == .pad)
        var out: [String] = []
        let (kb, host) = makeKeyboard(numbers: true, symbols: false, side: .period) { out.append($0) }
        XCTAssertEqual(kb.debugCommaHint, ",")
        XCTAssertTrue(kb.debugCommaHold())
        XCTAssertEqual(out, ["T,"])
        out = []
        kb.debugCommaHold(fire: false)
        XCTAssertEqual(out, ["T."])
        out = []
        kb.debugCommaHold(secondTouch: "a")
        XCTAssertEqual(out, ["T,", "La"])
        // Giữ phím ra ký tự phụ tắt ⇒ "." thường, không nhãn.
        out = []
        let (kb2, host2) = makeKeyboard(numbers: false, symbols: false, side: .period) { out.append($0) }
        XCTAssertNil(kb2.debugCommaHint)
        XCTAssertFalse(kb2.debugCommaHold())
        XCTAssertEqual(out, ["T."])
        // Tắt ⇒ không có phím để giữ.
        kb2.spaceSideKey = .off
        kb2.layoutIfNeeded()
        XCTAssertFalse(kb2.debugCommaHold())
        withExtendedLifetime((host, host2)) {}
    }

    // MARK: "Cả hai" (16/10/2026) — "," trái + "." phải space

    @MainActor private func bottomLabels(_ kb: KeyboardView) -> [String] {
        (kb.debugRowLabels().last ?? []).filter { $0 != "␣" }
    }

    @MainActor func testSpaceSideKeyBothBottomRow() throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom == .pad, "iPad không đổi")
        let (kbC, hostC) = makeKeyboard(numbers: true, symbols: false) { _ in }
        let (kb, host) = makeKeyboard(numbers: true, symbols: false, side: .both) { _ in }
        let row = bottomLabels(kb), rowC = bottomLabels(kbC)
        let si = try XCTUnwrap(row.firstIndex(of: "Dấu cách"))
        XCTAssertEqual(row[si - 1], ",", "',' sát trái space")
        XCTAssertEqual(row[si + 1], ".", "'.' sát phải space")
        XCTAssertEqual(row.count, rowC.count + 1)
        XCTAssertEqual(Array(row.prefix(2)), Array(rowC.prefix(2)), "[123][😊] giữ nguyên")
        XCTAssertEqual(row.last, rowC.last, "return giữ nguyên")
        let comma = try XCTUnwrap(kb.debugKeyButton(",")), dot = try XCTUnwrap(kb.debugKeyButton("."))
        XCTAssertEqual(comma.bounds.width, 390 * KeyLayout.phoneLettersComma, accuracy: 1)
        XCTAssertEqual(dot.bounds.width, comma.bounds.width, accuracy: 0.5)
        let spaceC = try XCTUnwrap(kbC.debugControl("Dấu cách")).bounds.width
        let space = try XCTUnwrap(kb.debugControl("Dấu cách")).bounds.width
        // Space co đúng một phím hẹp + một khe.
        XCTAssertLessThan(space, spaceC - comma.bounds.width + 1)
        XCTAssertGreaterThan(space, spaceC - comma.bounds.width - 12)
        // Ô email: không có "," bên trái.
        kb.configureInputKind(.email); kb.layoutIfNeeded()
        XCTAssertEqual(punctsRightOfSpace(kb), ["@", "."])
        XCTAssertFalse(bottomLabels(kb).contains(","))
        kb.configureInputKind(.normal); kb.layoutIfNeeded()
        withExtendedLifetime((host, hostC)) {}
    }

    /// Cả hai: giữ "," ra "." như mặc định; "." không hẹn giờ giữ (không có popup, như iPad).
    @MainActor func testSpaceSideKeyBothHold() throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom == .pad)
        var out: [String] = []
        let (kb, host) = makeKeyboard(numbers: true, symbols: false, side: .both) { out.append($0) }
        XCTAssertEqual(kb.debugCommaHint, ".")
        XCTAssertTrue(kb.debugCommaHold())
        XCTAssertEqual(out, ["T."])
        out = []
        XCTAssertFalse(kb.debugDomainHold(".", fire: false), "'.' không có giữ phím")
        XCTAssertEqual(out, ["T."])
        withExtendedLifetime(host) {}
    }

    // MARK: "Nút emoji" (16/10/2026) — Hàng dưới (mặc định) / Thanh trên

    func testEmojiKeyPlacementPure() {
        XCTAssertEqual(EmojiKeyPlacement.defaultValue, .bottom)
        XCTAssertEqual(EmojiKeyPlacement.parse(nil), .bottom)
        XCTAssertEqual(EmojiKeyPlacement.parse("toolbar"), .bottom)
        XCTAssertEqual(EmojiKeyPlacement.parse("top"), .top)
        XCTAssertEqual(EmojiKeyPlacement.key, "emojiKeyPlacement")   // cùng khoá Android
        XCTAssertTrue(EmojiKeyPlacement.emojiInBar(.top, barShown: true, pad: false))
        XCTAssertFalse(EmojiKeyPlacement.emojiInBar(.top, barShown: false, pad: false), "thanh ẩn ⇒ 😊 ở hàng đáy")
        XCTAssertFalse(EmojiKeyPlacement.emojiInBar(.top, barShown: true, pad: true), "iPad giữ hàng đáy stock")
        XCTAssertFalse(EmojiKeyPlacement.emojiInBar(.bottom, barShown: true, pad: false))
        // Khung nút: ô cao trọn strip, sát mép phải (không còn ⌄) hoặc bên trái 📋.
        let e = KeyboardView.emojiZoneWidth, c = KeyboardView.clipZoneWidth
        XCTAssertEqual(KeyboardView.emojiBarFrame(width: 390, strip: 36, clip: false),
                       CGRect(x: 390 - e, y: 0, width: e, height: 36))
        XCTAssertEqual(KeyboardView.emojiBarFrame(width: 390, strip: 36, clip: true),
                       CGRect(x: 390 - c - e, y: 0, width: e, height: 36))
        let spec = BackupSettings.all.first { $0.key == EmojiKeyPlacement.key }
        if case .string(let def, let allowed)? = spec?.kind {
            XCTAssertEqual(def, "bottom")
            XCTAssertEqual(Set(allowed), Set(EmojiKeyPlacement.allCases.map(\.rawValue)))
        } else { XCTFail("emojiKeyPlacement phải là .string") }
    }

    @MainActor func testEmojiKeyPlacementBottomRow() throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom == .pad, "iPad không đổi")
        // Mặc định: 😊 ở hàng đáy, không có nút trên thanh.
        let (kb0, host0) = makeKeyboard(numbers: true, symbols: false, suggestions: true) { _ in }
        XCTAssertTrue(bottomLabels(kb0).contains("Emoji"))
        XCTAssertNil(kb0.debugEmojiBarButton)
        let space0 = try XCTUnwrap(kb0.debugControl("Dấu cách")).bounds.width
        let emojiW = try XCTUnwrap(kb0.debugControl("Emoji")).bounds.width

        // Thanh trên + thanh gợi ý bật: 😊 rời hàng đáy, space ăn chỗ, nút 😊 trên thanh.
        let (kb, host) = makeKeyboard(numbers: true, symbols: false, emoji: .top, suggestions: true) { _ in }
        XCTAssertFalse(bottomLabels(kb).contains("Emoji"))
        XCTAssertEqual(bottomLabels(kb).count, bottomLabels(kb0).count - 1)
        let space = try XCTUnwrap(kb.debugControl("Dấu cách")).bounds.width
        XCTAssertGreaterThan(space, space0 + emojiW)
        XCTAssertLessThan(space, space0 + emojiW + 12)
        let btn = try XCTUnwrap(kb.debugEmojiBarButton)
        XCTAssertEqual(btn.frame, KeyboardView.emojiBarFrame(width: 390, strip: btn.frame.height, clip: false))
        // Chạm nút ⇒ plane emoji (thanh ẩn trong plane emoji ⇒ nút ẩn).
        btn.sendActions(for: .touchUpInside)
        kb.layoutIfNeeded()
        XCTAssertEqual(kb.debugPlaneName, "emoji")
        XCTAssertNil(kb.debugEmojiBarButton)

        // Thanh gợi ý tắt (ô này / công tắc) ⇒ 😊 về hàng đáy, không có nút trên thanh.
        let (kbOff, hostOff) = makeKeyboard(numbers: true, symbols: false, emoji: .top, suggestions: false) { _ in }
        XCTAssertTrue(bottomLabels(kbOff).contains("Emoji"))
        XCTAssertNil(kbOff.debugEmojiBarButton)
        kbOff.setSuggestionsEnabled(true); kbOff.layoutIfNeeded()
        XCTAssertFalse(bottomLabels(kbOff).contains("Emoji"), "thanh bật lại ⇒ 😊 lên thanh")
        XCTAssertNotNil(kbOff.debugEmojiBarButton)
        kbOff.setSuggestionsEnabled(false); kbOff.layoutIfNeeded()
        XCTAssertTrue(bottomLabels(kbOff).contains("Emoji"))
        XCTAssertNil(kbOff.debugEmojiBarButton)

        // Đổi tuỳ chọn khi đang hiện ⇒ dựng lại.
        kb0.emojiKeyPlacement = .top; kb0.layoutIfNeeded()
        XCTAssertFalse(bottomLabels(kb0).contains("Emoji"))
        XCTAssertNotNil(kb0.debugEmojiBarButton)
        withExtendedLifetime((host0, host, hostOff)) {}
    }

    /// "Nút ẩn bàn phím" (⌄ góc phải thanh gợi ý, mặc định TẮT — email người dùng 11/2026): phần thuần.
    func testKeyboardDismissButtonPure() {
        XCTAssertFalse(KeyboardDismissButton.defaultValue, "mặc định tắt")
        XCTAssertEqual(KeyboardDismissButton.key, "keyboardDismissButton")   // cùng khoá Android
        XCTAssertFalse(KeyboardDismissButton.load(nil))
        let d = UserDefaults(suiteName: "vt.dismiss.\(UUID().uuidString)")!
        XCTAssertFalse(KeyboardDismissButton.load(d), "chưa đặt ⇒ tắt")
        d.set(true, forKey: KeyboardDismissButton.key)
        XCTAssertTrue(KeyboardDismissButton.load(d))
        // Hiện: bật + dải có chỗ (kể cả ô mật khẩu) + không ở bàn emoji. Tắt Gợi ý (dải 0) ⇒ không.
        XCTAssertTrue(KeyboardDismissButton.shown(enabled: true, stripReserved: true, emojiPlane: false))
        XCTAssertFalse(KeyboardDismissButton.shown(enabled: false, stripReserved: true, emojiPlane: false))
        XCTAssertFalse(KeyboardDismissButton.shown(enabled: true, stripReserved: false, emojiPlane: false))
        XCTAssertFalse(KeyboardDismissButton.shown(enabled: true, stripReserved: true, emojiPlane: true))
        // Tắt ⇒ chừa 0 ⇒ khung 😊 / nhân vật y hệt cũ; bật ⇒ dời trái đúng một ô ☰ (52).
        let z = KeyboardDismissButton.zoneWidth
        XCTAssertEqual(z, KeyboardView.stripZoneWidth)
        XCTAssertEqual(KeyboardDismissButton.rightInset(shown: false), 0)
        XCTAssertEqual(KeyboardDismissButton.rightInset(shown: true), z)
        for clip in [false, true] {
            XCTAssertEqual(KeyboardView.emojiBarFrame(width: 390, strip: 36, clip: clip, dismiss: 0),
                           KeyboardView.emojiBarFrame(width: 390, strip: 36, clip: clip))
            XCTAssertEqual(KeyboardView.emojiBarFrame(width: 390, strip: 36, clip: clip, dismiss: z),
                           KeyboardView.emojiBarFrame(width: 390, strip: 36, clip: clip).offsetBy(dx: -z, dy: 0))
        }
        XCTAssertEqual(KeyboardView.buddyZoneFrame(width: 390, strip: 36, dismiss: z).maxX, 390 - z)
        XCTAssertEqual(KeyboardView.dismissZoneFrame(width: 390, strip: 36), CGRect(x: 390 - z, y: 0, width: z, height: 36))
        let spec = BackupSettings.all.first { $0.key == KeyboardDismissButton.key }
        if case .bool(let def)? = spec?.kind { XCTAssertFalse(def) } else { XCTFail("keyboardDismissButton phải là .bool trong sao lưu") }
    }

    /// Bố cục thật: tắt ⇒ không có nút, thanh y hệt; bật ⇒ ⌄ sát mép phải, 📋 / thanh dời trái, không chồng ⌄;
    /// dải trống (ô mật khẩu, dải giữ chỗ) vẫn có ⌄; Gợi ý tắt (dải 0) ⇒ không. iPhone + iPad (theo công tắc).
    @MainActor func testKeyboardDismissButtonLayout() throws {
        let (kb, host) = makeKeyboard(numbers: true, symbols: false, suggestions: true) { _ in }
        kb.setClipboardButton(visible: true); kb.layoutIfNeeded()
        XCTAssertNil(kb.debugDismissButton, "mặc định tắt ⇒ không có ⌄")
        let off = kb.debugStripLayout()
        let offClip = try XCTUnwrap(off.clip)

        kb.dismissButtonEnabled = true; kb.layoutIfNeeded()
        let btn = try XCTUnwrap(kb.debugDismissButton)
        let z = KeyboardDismissButton.zoneWidth
        XCTAssertEqual(btn.frame, KeyboardView.dismissZoneFrame(width: kb.bounds.width, strip: btn.frame.height))
        XCTAssertEqual(btn.frame.maxX, kb.bounds.width, accuracy: 0.5)
        XCTAssertGreaterThan(btn.frame.height, 0)
        XCTAssertEqual(btn.accessibilityLabel, L("Ẩn bàn phím"))
        let on = kb.debugStripLayout()
        let onClip = try XCTUnwrap(on.clip)
        XCTAssertEqual(on.bar.maxX, off.bar.maxX - z, accuracy: 0.5, "thanh co đúng một ô")
        XCTAssertEqual(onClip, offClip.offsetBy(dx: -z, dy: 0))
        XCTAssertLessThanOrEqual(onClip.maxX, btn.frame.minX + 0.5, "📋 không chồng ⌄")
        XCTAssertLessThanOrEqual(on.bar.maxX, onClip.minX + 0.5)
        for c in on.cells { XCTAssertLessThanOrEqual(c.maxX, btn.frame.minX + 0.5, "ô gợi ý chồng ⌄") }

        // Ô từ chối gợi ý nhưng dải giữ chỗ (mật khẩu): dải trống vẫn có ⌄.
        kb.setSuggestionsEnabled(false, reserveStrip: true); kb.layoutIfNeeded()
        XCTAssertNotNil(kb.debugDismissButton)
        // Tắt Thanh gợi ý (dải 0) ⇒ không có ⌄.
        kb.setSuggestionsEnabled(false, reserveStrip: false); kb.layoutIfNeeded()
        XCTAssertNil(kb.debugDismissButton)

        // Tắt lại ⇒ đúng bố cục cũ (0 chi phí bố cục).
        kb.setSuggestionsEnabled(true); kb.dismissButtonEnabled = false; kb.layoutIfNeeded()
        XCTAssertNil(kb.debugDismissButton)
        let back = kb.debugStripLayout()
        XCTAssertEqual(back.bar, off.bar)
        XCTAssertEqual(back.clip, off.clip)
        withExtendedLifetime(host) {}
    }

    /// Bàn emoji (lưới chiếm dải) ⇒ ẩn ⌄; về bàn chữ ⇒ hiện lại. 😊 Thanh trên sát trái ⌄.
    @MainActor func testKeyboardDismissButtonWithEmojiTop() throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom == .pad, "iPad giữ 😊 hàng đáy")
        let (kb, host) = makeKeyboard(numbers: true, symbols: false, emoji: .top, suggestions: true) { _ in }
        kb.dismissButtonEnabled = true; kb.layoutIfNeeded()
        let dz = try XCTUnwrap(kb.debugDismissButton)
        let em = try XCTUnwrap(kb.debugEmojiBarButton)
        XCTAssertEqual(em.frame, KeyboardView.emojiBarFrame(width: 390, strip: em.frame.height, clip: false,
                                                            dismiss: KeyboardDismissButton.zoneWidth))
        XCTAssertEqual(em.frame.maxX, dz.frame.minX, accuracy: 0.5)
        em.sendActions(for: .touchUpInside); kb.layoutIfNeeded()
        XCTAssertEqual(kb.debugPlaneName, "emoji")
        XCTAssertNil(kb.debugDismissButton, "bàn emoji: ẩn ⌄")
        withExtendedLifetime(host) {}
    }

    /// Tổ hợp Cả hai × Thanh trên: [123][,][space][.][return]; plane số giữ 😊.
    @MainActor func testBothWithEmojiTop() throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom == .pad)
        let (kb, host) = makeKeyboard(numbers: true, symbols: false, side: .both, emoji: .top,
                                      suggestions: true) { _ in }
        let row = bottomLabels(kb)
        XCTAssertEqual(row.count, 5)
        XCTAssertEqual(Array(row[1...3]), [",", "Dấu cách", "."])
        try XCTUnwrap(kb.debugControl("Số")).sendActions(for: .touchDown)
        XCTAssertEqual(kb.debugPlaneName, "numbers")
        XCTAssertTrue(bottomLabels(kb).contains("Emoji"), "plane số giữ 😊")
        XCTAssertNotNil(kb.debugEmojiBarButton, "thanh vẫn có 😊 ở plane số")
        withExtendedLifetime(host) {}
    }
}

/// "Giữ Shift để gõ số và ký hiệu" (yêu cầu người dùng Văn Việt, Phil duyệt): giữ ⇧ + chạm
/// q w e ⇒ "123" mà không phải sang bàn số. Máy trạng thái ⇧ THUẦN — cùng bộ ca với Android
/// ShiftHoldTests.kt.
final class ShiftHoldTests: XCTestCase {
    private let digitsOnly = KeyAlternates.shiftMap(enabled: true, numbers: true, symbols: false, numberRow: false)
    private let all = KeyAlternates.shiftMap(enabled: true, numbers: true, symbols: true, numberRow: false)
    private let H = ShiftHold.rollover + 0.05

    /// Chạm nhanh ⇧ = viết hoa một lần; chạm đôi = Caps Lock; chạm thứ hai chậm = tắt (như cũ).
    func testTapDoubleTapUnchanged() {
        var h = ShiftHold()
        var s = h.down(.off, now: 1); XCTAssertEqual(s, .once)
        s = h.up(s); XCTAssertEqual(s, .once)
        s = h.down(s, now: 1.2); XCTAssertEqual(s, .capsLock)
        s = h.up(s); XCTAssertEqual(s, .capsLock)
        s = h.down(s, now: 5); XCTAssertEqual(s, .off)
        s = h.up(s)
        s = h.down(s, now: 9); XCTAssertEqual(s, .once)
        s = h.up(s)
        s = h.down(s, now: 9 + ShiftHold.doubleTap + 0.01); XCTAssertEqual(s, .off, "chậm ⇒ không phải chạm đôi")
    }

    /// Giữ ⇧ + q w e ⇒ 1 2 3; nhả KHÔNG để lại viết hoa một lần; lần chạm kế không thành chạm đôi.
    func testHeldShiftTypesDigitsAndLeavesNoOneShot() {
        var h = ShiftHold()
        var s = h.down(.off, now: 1)
        var out = ""
        for (i, c) in "qwe".enumerated() { out += h.symbol(c, map: digitsOnly, now: 1 + H + Double(i) * 0.1) ?? "?" }
        XCTAssertEqual(out, "123")
        s = h.up(s)
        XCTAssertEqual(s, .off)
        XCTAssertFalse(h.held)
        s = h.down(s, now: 1 + H + 0.25); XCTAssertEqual(s, .once)
    }

    /// Caps Lock đang bật: giữ ⇧ gõ ký hiệu ⇒ nhả vẫn Caps Lock; chạm đôi rồi giữ ⇒ vẫn Caps.
    func testCapsLockPreserved() {
        var h = ShiftHold()
        XCTAssertNil(h.symbol("q", map: all, now: 0), "không giữ ⇧ ⇒ chữ như cũ")
        var s = h.down(.capsLock, now: 10)
        XCTAssertEqual(s, .off)
        XCTAssertEqual(h.symbol("a", map: all, now: 10 + H), "@")
        XCTAssertEqual(h.up(s), .capsLock)
        s = h.down(.off, now: 20); s = h.up(s)
        s = h.down(s, now: 20.1); XCTAssertEqual(s, .capsLock)
        XCTAssertEqual(h.symbol("w", map: all, now: 20.1 + H), "2")
        XCTAssertEqual(h.up(s), .capsLock)
    }

    /// Gõ chồng ngón nhanh (⇧ rồi chữ, ⇧ chưa nhả) vẫn là chữ hoa — không thành số.
    func testRolloverStaysCapital() {
        var h = ShiftHold()
        _ = h.down(.off, now: 1)
        XCTAssertNil(h.symbol("q", map: all, now: 1.06))
        XCTAssertEqual(h.up(.off), .off)
        _ = h.down(.off, now: 5)
        XCTAssertNil(h.symbol("q", map: all, now: 5.1))
        XCTAssertEqual(h.symbol("w", map: all, now: 5 + H), "2")
        XCTAssertEqual(h.up(.off), .off)
    }

    /// Tắt cài đặt (bảng rỗng) / phím không có ký tự phụ ⇒ hành vi cũ.
    func testSettingOffAndNoHintFallBack() {
        let off = KeyAlternates.shiftMap(enabled: false, numbers: true, symbols: true, numberRow: false)
        XCTAssertTrue(off.isEmpty)
        var h = ShiftHold()
        _ = h.down(.off, now: 0)
        XCTAssertNil(h.symbol("q", map: off, now: H))
        XCTAssertNil(h.symbol("a", map: digitsOnly, now: H), "a không có ký tự phụ khi chỉ bật số")
        XCTAssertEqual(h.up(.once), .once, "không dùng ký tự phụ ⇒ nhả không đụng shift")
        _ = h.down(.off, now: 10); h.cancel()
        XCTAssertFalse(h.held)
        XCTAssertNil(h.symbol("q", map: all, now: 10 + H))
    }

    /// Phiên thật trên CÙNG instance: chạm, giữ-gõ số, chạm đôi, Caps + giữ, tắt Caps.
    func testRealisticSessionSequence() {
        var h = ShiftHold()
        var t: TimeInterval = 100
        var s = h.down(.off, now: t); s = h.up(s); XCTAssertEqual(s, .once)
        s = .off                                                     // gõ "A"
        t += 1
        s = h.down(s, now: t)
        XCTAssertEqual((h.symbol("q", map: all, now: t + H) ?? "") + (h.symbol("w", map: all, now: t + H) ?? ""), "12")
        s = h.up(s); XCTAssertEqual(s, .off)
        t += 0.1
        s = h.down(s, now: t); XCTAssertEqual(s, .once, "không thành chạm đôi"); s = h.up(s)
        t += 0.15
        s = h.down(s, now: t); XCTAssertEqual(s, .capsLock); s = h.up(s)
        t += 2
        s = h.down(s, now: t); XCTAssertEqual(h.symbol("m", map: all, now: t + H), "?"); s = h.up(s)
        XCTAssertEqual(s, .capsLock)
        t += 2
        s = h.down(s, now: t); s = h.up(s); XCTAssertEqual(s, .off)
    }

    /// Bảng giữ ⇧ = đúng ký tự phụ giữ lâu (KeyAlternates); hàng số bật vẫn có số; iPad/VoiceOver tắt.
    func testMapParityWithAlternates() {
        for n in [true, false] { for sym in [true, false] {
            XCTAssertEqual(KeyAlternates.shiftMap(enabled: true, numbers: n, symbols: sym, numberRow: false),
                           KeyAlternates.map(numbers: n, symbols: sym, numberRow: false))
            let row = KeyAlternates.shiftMap(enabled: true, numbers: n, symbols: sym, numberRow: true)
            for (k, v) in KeyAlternates.digits { XCTAssertEqual(row[k], v, "hàng số bật: giữ ⇧+\(k) vẫn ra \(v)") }
            if sym { for (k, v) in KeyAlternates.symbols { XCTAssertEqual(row[k], v) } }
            else { XCTAssertTrue(KeyAlternates.symbols.keys.allSatisfy { row[$0] == nil }) }
            XCTAssertTrue(KeyAlternates.shiftMap(enabled: true, numbers: n, symbols: sym, numberRow: false, isPad: true).isEmpty)
            XCTAssertTrue(KeyAlternates.shiftMap(enabled: true, numbers: n, symbols: sym, numberRow: false, accessibility: true).isEmpty)
        } }
    }

    /// Ký tự phụ nguyên văn: VNI chốt từ rồi chèn số (controller bỏ qua vniDigit khi literal).
    func testHeldDigitIsLiteralInVNI() {
        var st = KeyboardSettings(); st.vniMode = true
        let p = MockProxy(), b = EngineBridge(settings: st)
        b.letter("a", proxy: p)
        b.boundary("1", proxy: p)                 // đường literal của controller
        XCTAssertEqual(p.text, "a1")
        XCTAssertFalse(b.isComposing)
        let p2 = MockProxy(), b2 = EngineBridge(settings: st)
        b2.letter("a", proxy: p2)
        XCTAssertTrue(b2.vniDigit("1", proxy: p2), "đối chứng: số thường (không giữ ⇧) vẫn là dấu VNI")
        XCTAssertEqual(p2.text, "á")
    }

    // MARK: KeyboardView (iPhone) — đường router thật

    @MainActor private func makeKeyboard(holdShift: Bool, symbols: Bool = true, numberRow: Bool = false,
                                         log: @escaping (String, Bool) -> Void) -> (KeyboardView, UIView) {
        var kbRef: KeyboardView?
        let kb = KeyboardView(needsGlobe: false, inputController: nil) { k in
            let lit = kbRef?.literalTextInFlight ?? false
            switch k {
            case .letter(let c): log("L\(c)", lit)
            case .text(let s): log("T\(s)", lit)
            case .replaceLastLetter(let s): log("R\(s)", lit)
            default: log("?", lit)
            }
        }
        kbRef = kb
        let host = UIView(frame: CGRect(x: 0, y: 0, width: 390, height: 320))
        host.addSubview(kb)
        kb.frame = host.bounds
        kb.numberRowEnabled = numberRow
        kb.configureKeyAlternates(numbers: true, symbols: symbols, holdShift: holdShift)
        kb.setAutoShift(false)
        kb.layoutIfNeeded()
        return (kb, host)
    }

    @MainActor func testHoldShiftTypesHintsLiterally() throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom == .pad, "iPad: ⇧ như cũ")
        var out: [String] = [], literal: [Bool] = []
        let (kb, host) = makeKeyboard(holdShift: true) { out.append($0); literal.append($1) }
        kb.debugShiftDown(at: 100)
        XCTAssertTrue(kb.debugShiftOn)
        for (i, c) in ["q", "w", "e", "a"].enumerated() { kb.debugTapLetter(c, at: 100.3 + Double(i) * 0.2) }
        XCTAssertEqual(out, ["T1", "T2", "T3", "T@"])
        XCTAssertEqual(literal, [true, true, true, true], "controller chèn nguyên văn (VNI không bỏ dấu)")
        kb.debugShiftUp()
        XCTAssertFalse(kb.debugShiftOn, "nhả ⇧ không để lại viết hoa một lần")
        out = []; literal = []
        kb.debugTapLetter("q", at: 102)
        XCTAssertEqual(out, ["Lq"])
        XCTAssertEqual(literal, [false])
        withExtendedLifetime(host) {}
    }

    /// Hàng số bật (số không còn là nhãn phụ): giữ ⇧ + q vẫn ra 1 — nhất quán.
    @MainActor func testHoldShiftNumberRowConsistent() throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom == .pad)
        var out: [String] = []
        let (kb, host) = makeKeyboard(holdShift: true, symbols: false, numberRow: true) { s, _ in out.append(s) }
        kb.debugShiftDown(at: 100)
        kb.debugTapLetter("q", at: 100.4)
        kb.debugTapLetter("a", at: 100.6)        // không ký tự phụ ⇒ chữ hoa như cũ
        kb.debugShiftUp()
        XCTAssertEqual(out, ["T1", "LA"])
        XCTAssertFalse(kb.debugShiftOn)
        withExtendedLifetime(host) {}
    }

    /// Tắt cài đặt ⇒ giữ ⇧ + chữ là chữ hoa (một lần) như cũ; rollover nhanh cũng là chữ hoa.
    @MainActor func testSettingOffAndRolloverKeepCapitals() throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom == .pad)
        var out: [String] = []
        let (kb, host) = makeKeyboard(holdShift: false) { s, _ in out.append(s) }
        kb.debugShiftDown(at: 100)
        kb.debugTapLetter("q", at: 100.4)
        kb.debugTapLetter("w", at: 100.6)
        kb.debugShiftUp()
        XCTAssertEqual(out, ["LQ", "Lw"])
        let (kb2, host2) = makeKeyboard(holdShift: true) { s, _ in out.append(s) }
        out = []
        kb2.debugShiftDown(at: 200)
        kb2.debugTapLetter("q", at: 200.05)      // chồng ngón
        kb2.debugShiftUp()
        XCTAssertEqual(out, ["LQ"])
        withExtendedLifetime((host, host2)) {}
    }
}
