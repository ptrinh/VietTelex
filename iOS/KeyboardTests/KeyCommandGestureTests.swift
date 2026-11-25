// "Vuốt phím để sao chép/dán" (KeyCommandGesture): bộ phân loại thuần (bật/tắt/huỷ theo
// ngưỡng, đường dọc vs gõ vuốt, phím → lệnh, công tắc tắt = không bao giờ bật), chạy lệnh
// trên proxy/clipboard giả, và luồng qua router KeyboardView (chữ huỷ / hoãn, gõ vuốt vẫn
// chạy). Bản Kotlin song sinh: android/keyboard/src/test/.../KeyCommandGestureTests.kt.
import XCTest
import UIKit

final class KeyCommandGestureTests: XCTestCase {
    private let pitch: CGFloat = 37.5
    private let top: CGFloat = 60            // đỉnh vùng phím
    private let c = CGPoint(x: 150, y: 250)  // tâm phím C (hàng dưới)

    private func gesture(_ key: Character = "c", enabled: Bool = true) -> KeyCommandGesture? {
        KeyCommandGesture.begin(enabled: enabled, key: key, start: c, keyAreaTop: top, keyPitch: pitch)
    }

    /// Đi qua `pts` rồi nhấc ở điểm cuối.
    private func run(_ pts: [CGPoint], key: Character = "c") -> KeyCommand? {
        guard var g = gesture(key) else { return nil }
        for p in pts.dropLast() { g.move(to: p) }
        return g.end(at: pts.last ?? c)
    }

    /// Thẳng đứng từ C lên tới y.
    private func up(to y: CGFloat, dx: CGFloat = 0, steps: Int = 8) -> [CGPoint] {
        (1...steps).map { i in
            let u = CGFloat(i) / CGFloat(steps)
            return CGPoint(x: c.x + dx * u, y: c.y + (y - c.y) * u)
        }
    }

    // MARK: phím → lệnh

    func testMappingByPhysicalKeyOnlyCXV() {
        XCTAssertEqual(KeyCommand.forKey("c"), .copy)
        XCTAssertEqual(KeyCommand.forKey("X"), .cut)
        XCTAssertEqual(KeyCommand.forKey("v"), .paste)
        // iOS: không chọn hết / hoàn tác / làm lại (Apple không cho bàn phím) ⇒ A/Z/Y là phím thường.
        for k: Character in ["a", "z", "y", "s", "e", "w", "f"] { XCTAssertNil(KeyCommand.forKey(k), "\(k)") }
        XCTAssertEqual(KeyCommand.copy.viLabel, "Sao chép")
        XCTAssertEqual(KeyCommand.cut.viLabel, "Cắt")
        XCTAssertEqual(KeyCommand.paste.viLabel, "Dán")
    }

    func testSettingOffOrUnmappedNeverArms() {
        XCTAssertNil(gesture(enabled: false))
        XCTAssertNil(gesture("a"))
        XCTAssertNil(KeyCommandGesture.begin(enabled: true, key: "c", start: c, keyAreaTop: top, keyPitch: 0))
        XCTAssertNil(run(up(to: 0), key: "a"))
    }

    // MARK: ngưỡng bật / tắt

    func testCommandlessGestureArmsTheSameWay() {
        var g = KeyCommandGesture.beginUp(start: c, keyAreaTop: top, keyPitch: pitch)!
        XCTAssertNil(g.command)
        for p in up(to: 20) { g.move(to: p) }
        XCTAssertTrue(g.isArmed)
        XCTAssertTrue(g.endArmed(at: CGPoint(x: c.x, y: 20)))
        var inside = KeyCommandGesture.beginUp(start: c, keyAreaTop: top, keyPitch: pitch)!
        XCTAssertFalse(inside.endArmed(at: CGPoint(x: c.x, y: 100)))
        XCTAssertNil(KeyCommandGesture.beginUp(start: c, keyAreaTop: top, keyPitch: 0))
    }

    func testStraightUpPastTopFires() {
        XCTAssertEqual(run(up(to: 20)), .copy)
        XCTAssertEqual(run(up(to: 20), key: "x"), .cut)
        XCTAssertEqual(run(up(to: 20), key: "v"), .paste)
        // nghiêng nhẹ vẫn được
        XCTAssertEqual(run(up(to: 20, dx: 40)), .copy)
    }

    func testArmLineNeedsMarginAboveKeyArea() {
        var g = gesture()!
        XCTAssertEqual(g.move(to: CGPoint(x: c.x, y: top + 10)), .none)   // còn trong hàng trên
        XCTAssertEqual(g.move(to: CGPoint(x: c.x, y: top - 2)), .none)    // chưa đủ 4pt
        XCTAssertFalse(g.isArmed)
        XCTAssertEqual(g.move(to: CGPoint(x: c.x, y: top - 4)), .armed)
        XCTAssertTrue(g.isArmed)
        XCTAssertEqual(g.move(to: CGPoint(x: c.x, y: top - 30)), .none)   // đã bật: không bắn lại
    }

    func testStopInsideKeyAreaDoesNothing() {
        XCTAssertNil(run(up(to: top + 15)))
        XCTAssertNil(run([c]))                                               // chạm thường
    }

    func testComingBackDownCancelsAndCanReArm() {
        var g = gesture()!
        for p in up(to: 30) { g.move(to: p) }
        XCTAssertTrue(g.isArmed)
        XCTAssertEqual(g.move(to: CGPoint(x: c.x, y: top + 1)), .disarmed)
        XCTAssertFalse(g.isArmed)
        XCTAssertTrue(g.isCandidate)
        XCTAssertNil(g.end(at: CGPoint(x: c.x, y: top + 20)))                // nhấc trong vùng phím = huỷ
        var h = gesture()!
        for p in up(to: 30) { h.move(to: p) }
        h.move(to: CGPoint(x: c.x, y: top + 20))
        XCTAssertEqual(h.move(to: CGPoint(x: c.x, y: top - 10)), .armed)     // lên lại ⇒ bật lại
        XCTAssertEqual(h.end(at: CGPoint(x: c.x, y: top - 10)), .copy)
    }

    // MARK: đường dọc vs gõ vuốt

    func testDiagonalPathIsRejectedForGood() {
        var g = gesture()!
        // c → h kiểu gõ vuốt: sang phải nhiều hơn lên
        XCTAssertEqual(g.move(to: CGPoint(x: c.x + 60, y: c.y - 40)), .rejected)
        XCTAssertFalse(g.isCandidate)
        // quay về thẳng đứng rồi lên quá đỉnh: vẫn không sống lại
        XCTAssertEqual(g.move(to: CGPoint(x: c.x, y: 0)), .none)
        XCTAssertNil(g.end(at: CGPoint(x: c.x, y: 0)))
    }

    func testSlopeTolerance() {
        let g = gesture()!
        // dy = 150 ⇒ cho phép |dx| ≤ 0.5·37.5 + 0.45·150 = 86.25
        XCTAssertTrue(g.isVertical(CGPoint(x: c.x + 86, y: c.y - 150)))
        XCTAssertFalse(g.isVertical(CGPoint(x: c.x - 87, y: c.y - 150)))
        // sát chỗ chạm: nửa phím dung sai
        XCTAssertTrue(g.isVertical(CGPoint(x: c.x + 18, y: c.y)))
        XCTAssertFalse(g.isVertical(CGPoint(x: c.x + 19, y: c.y)))
        // kéo xuống quá nửa phím ⇒ không dọc-lên
        XCTAssertTrue(g.isVertical(CGPoint(x: c.x, y: c.y + 18)))
        XCTAssertFalse(g.isVertical(CGPoint(x: c.x, y: c.y + 19)))
    }

    func testRejectByOutsideEvents() {
        var g = gesture()!
        for p in up(to: 30) { g.move(to: p) }
        XCTAssertEqual(g.reject(), .rejected)     // ngón thứ hai / popup ký tự phụ
        XCTAssertEqual(g.reject(), .none)
        XCTAssertNil(g.end(at: CGPoint(x: c.x, y: 30)))
    }

    // MARK: chạy lệnh (proxy + clipboard giả)

    private final class Host: KeyCommandHost {
        var before: String, selected: String
        init(_ before: String, selected: String = "") { self.before = before; self.selected = selected }
        var selectedText: String? { selected.isEmpty ? nil : selected }
        func insertText(_ t: String) { selected = ""; before += t }
        func deleteBackward() {
            if !selected.isEmpty { selected = ""; return }
            if !before.isEmpty { before.removeLast() }
        }
    }
    private final class Clip: KeyCommandClipboard { var string: String? }

    func testCopyKeepsTextAndFillsClipboard() {
        let h = Host("xin ", selected: "chào"), cb = Clip()
        XCTAssertEqual(KeyCommandRunner.run(.copy, host: h, clipboard: cb, fullAccess: true, paste: { nil }),
                       .copied("chào"))
        XCTAssertEqual(cb.string, "chào")
        XCTAssertEqual(h.before + h.selected, "xin chào")
    }

    func testCutCopiesThenDeletesSelection() {
        let h = Host("xin ", selected: "chào"), cb = Clip()
        XCTAssertEqual(KeyCommandRunner.run(.cut, host: h, clipboard: cb, fullAccess: true, paste: { nil }),
                       .cut("chào"))
        XCTAssertEqual(cb.string, "chào")
        XCTAssertEqual(h.before, "xin ")
        XCTAssertEqual(h.selected, "")
    }

    func testNothingSelectedDoesNotTouchFieldOrClipboard() {
        let h = Host("xin chào"), cb = Clip()
        cb.string = "cũ"
        for cmd in [KeyCommand.copy, .cut] {
            XCTAssertEqual(KeyCommandRunner.run(cmd, host: h, clipboard: cb, fullAccess: true, paste: { nil }),
                           .nothingSelected)
        }
        XCTAssertEqual(cb.string, "cũ")
        XCTAssertEqual(h.before, "xin chào")
        XCTAssertEqual(KeyCommandRunner.hint(.nothingSelected), "Chưa chọn chữ")
    }

    func testNoFullAccessBlocksEverything() {
        let h = Host("a", selected: "b"), cb = Clip()
        var pasted = false
        for cmd in KeyCommand.allCases {
            XCTAssertEqual(KeyCommandRunner.run(cmd, host: h, clipboard: cb, fullAccess: false,
                                                paste: { pasted = true; return "x" }), .needsFullAccess)
        }
        XCTAssertFalse(pasted)
        XCTAssertNil(cb.string)
        XCTAssertEqual(h.before + h.selected, "ab")
        XCTAssertEqual(KeyCommandRunner.hint(.needsFullAccess), "Cần Truy cập đầy đủ")
        XCTAssertEqual(KeyCommandRunner.precheck(.copy, selectedText: "b", fullAccess: false), .needsFullAccess)
        XCTAssertNil(KeyCommandRunner.precheck(.copy, selectedText: "b", fullAccess: true))
        XCTAssertNil(KeyCommandRunner.precheck(.paste, selectedText: nil, fullAccess: true))
    }

    func testPasteGoesThroughSharedPastePath() {
        let h = Host("a"), cb = Clip()
        XCTAssertEqual(KeyCommandRunner.run(.paste, host: h, clipboard: cb, fullAccess: true, paste: { "bc" }),
                       .pasted("bc"))
        XCTAssertEqual(KeyCommandRunner.run(.paste, host: h, clipboard: cb, fullAccess: true, paste: { nil }),
                       .clipboardEmpty)
        XCTAssertEqual(KeyCommandRunner.hint(.clipboardEmpty), "Clipboard trống")
        XCTAssertNil(KeyCommandRunner.hint(.pasted("bc")))
        XCTAssertEqual(KeyCommandRunner.logKind(.copied("bí mật")), "copied")   // nhật ký không có nội dung
    }

    func testPolicy() {
        XCTAssertFalse(KeyCommandPolicy.enabled(setting: false, traits: FieldTraits(), voiceOver: false))
        XCTAssertTrue(KeyCommandPolicy.enabled(setting: true, traits: FieldTraits(), voiceOver: false))
        XCTAssertTrue(KeyCommandPolicy.enabled(setting: true, traits: nil, voiceOver: false))
        XCTAssertFalse(KeyCommandPolicy.enabled(setting: true, traits: FieldTraits(secure: true), voiceOver: false))
        XCTAssertFalse(KeyCommandPolicy.enabled(setting: true, traits: FieldTraits(), voiceOver: true))
    }

    // MARK: cài đặt

    func testSettingDefaultOffLoadsAndBacksUp() {
        XCTAssertFalse(KeyboardSettings().swipeKeyCommands)
        XCTAssertEqual(BackupSettings.byKey["swipeKeyCommands"]?.kind, .bool(false))
        let d = UserDefaults(suiteName: "vt-keycmd")!
        d.removePersistentDomain(forName: "vt-keycmd")
        d.set(true, forKey: "swipeKeyCommands")
        let saved = UserDefaultsProvider.shared
        UserDefaultsProvider.shared = d
        defer { UserDefaultsProvider.shared = saved }
        XCTAssertTrue(KeyboardSettings.load().swipeKeyCommands)
    }
}

/// Luồng qua router KeyboardView: chữ của phím bị huỷ khi thành lệnh, vùng chọn ⇒ chữ hoãn,
/// gõ vuốt (kể cả từ vuốt dọc "xe") vẫn chạy khi công tắc bật.
final class KeyCommandKeyboardFlowTests: XCTestCase {
    private struct Rig {
        let kb: KeyboardView, host: UIView, p: MockProxy, b: EngineBridge
        var commands: [(KeyCommand, Bool)] { box.commands }
        var letters: Int { box.letters }
        let box: Box
    }
    private final class Box { var commands: [(KeyCommand, Bool)] = []; var letters = 0 }

    @MainActor private func rig(commands on: Bool = true, swipe: Bool = true, selection: Bool = false) -> Rig {
        let p = MockProxy(), b = EngineBridge(settings: KeyboardSettings()), s = SwipeTyping()
        let box = Box()
        let kb = KeyboardView(needsGlobe: false, inputController: nil) { key in
            switch key {
            case .letter(let ch): box.letters += 1; b.letter(ch, proxy: p)
            case .space: b.boundary(" ", proxy: p)
            default: break
            }
        }
        let host = UIView(frame: CGRect(x: 0, y: 0, width: 390, height: 320))
        host.addSubview(kb)
        kb.frame = host.bounds
        kb.layoutIfNeeded()
        kb.swipeEnabled = swipe
        kb.onSwipeEnded = { path, sc in _ = s.finish(path, case: sc, contextWords: [], bridge: b, proxy: p) }
        if let l = kb.swipeLayout() { s.setLayout(l, prepare: false) }
        kb.keyCommandsEnabled = on
        kb.keyCommandHasSelection = { selection }
        kb.onKeyCommand = { cmd, deferred in
            box.commands.append((cmd, deferred))
            if !deferred { _ = b.undoLastLetter(proxy: p) }      // như controller
        }
        return Rig(kb: kb, host: host, p: p, b: b, box: box)
    }

    @MainActor private func center(_ kb: KeyboardView, _ ch: Character) -> CGPoint {
        let f = kb.debugLetterFrame(String(ch))!
        return CGPoint(x: f.midX, y: f.midY)
    }

    /// Thẳng lên từ `a` tới y, mỗi bước ≤ 8pt.
    private func vertical(from a: CGPoint, to y: CGFloat) -> [CGPoint] {
        let n = max(2, Int(abs(a.y - y) / 8))
        return (1...n).map { CGPoint(x: a.x, y: a.y + (y - a.y) * CGFloat($0) / CGFloat(n)) }
    }

    @MainActor func testSwipeUpOnCCopiesAndRemovesLetter() {
        // Gõ vuốt tắt: "c" chèn lúc chạm rồi bị huỷ. Bật: "c" hoãn tới lúc nhấc (#172) ⇒ không
        // bao giờ chèn, lệnh nhận letterDeferred = true (controller không huỷ gì).
        for swipe in [false, true] {
            let r = rig(swipe: swipe)
            r.b.letter("a", proxy: r.p)
            let top = r.kb.debugKeyAreaTop()
            let start = center(r.kb, "c")
            XCTAssertFalse(r.kb.debugTouch(from: start, through: vertical(from: start, to: top - 20), start: 100))
            XCTAssertEqual(r.commands.map(\.0), [.copy])
            XCTAssertEqual(r.commands.first?.1, swipe)
            XCTAssertEqual(r.letters, swipe ? 0 : 1)          // gõ vuốt bật: "c" chưa từng tới engine
            XCTAssertEqual(r.p.text, "a")
            XCTAssertNil(r.kb.debugKeyCommandPill)               // nhãn xem trước ẩn sau khi nhấc
            withExtendedLifetime(r.host) {}
        }
    }

    @MainActor func testSelectionDefersLetterSoCutKeepsSelection() {
        let r = rig(selection: true)
        let top = r.kb.debugKeyAreaTop()
        let x = center(r.kb, "x")
        XCTAssertFalse(r.kb.debugTouch(from: x, through: vertical(from: x, to: top - 20), start: 100))
        XCTAssertEqual(r.commands.map(\.0), [.cut])
        XCTAssertEqual(r.commands.first?.1, true)
        XCTAssertEqual(r.letters, 0)                         // chữ x không bao giờ chèn (vùng chọn còn)
        // không thành lệnh ⇒ chữ hoãn chèn lúc nhấc
        XCTAssertFalse(r.kb.debugTouch(from: x, through: [], start: 101))
        XCTAssertEqual(r.letters, 1)
        XCTAssertEqual(r.p.text.lowercased(), "x")
        withExtendedLifetime(r.host) {}
    }

    @MainActor func testComingBackDownTypesTheLetter() {
        let r = rig(swipe: false)
        let top = r.kb.debugKeyAreaTop()
        let v = center(r.kb, "v")
        let path = vertical(from: v, to: top - 20) + vertical(from: CGPoint(x: v.x, y: top - 20), to: v.y)
        XCTAssertFalse(r.kb.debugTouch(from: v, through: path, start: 100))
        XCTAssertTrue(r.commands.isEmpty)
        XCTAssertEqual(r.p.text.lowercased(), "v")
        withExtendedLifetime(r.host) {}
    }

    @MainActor func testSettingOffNeverFires() {
        let r = rig(commands: false, swipe: false)
        let top = r.kb.debugKeyAreaTop()
        let c = center(r.kb, "c")
        _ = r.kb.debugTouch(from: c, through: vertical(from: c, to: top - 20), start: 100)
        XCTAssertTrue(r.commands.isEmpty)
        XCTAssertEqual(r.p.text.lowercased(), "c")
        withExtendedLifetime(r.host) {}
    }

    @MainActor func testOtherKeysUnaffected() {
        let r = rig(swipe: false)
        let top = r.kb.debugKeyAreaTop()
        let a = center(r.kb, "a")
        _ = r.kb.debugTouch(from: a, through: vertical(from: a, to: top - 20), start: 100)
        XCTAssertTrue(r.commands.isEmpty)                    // iOS: A không có lệnh
        withExtendedLifetime(r.host) {}
    }

    @MainActor func testSwipeTypingStillWorksWithCommandsOn() {
        let r = rig()
        // vuốt chéo c → h → a → o: bị loại khỏi cử chỉ lệnh ngay, gõ vuốt tiếp quản
        let keys = Array("chao").map { center(r.kb, $0) }
        var pts: [CGPoint] = []
        for i in 1..<keys.count {
            let a = keys[i - 1], b = keys[i]
            let n = max(2, Int(hypot(b.x - a.x, b.y - a.y) / 8))
            for j in 1...n { let u = CGFloat(j) / CGFloat(n); pts.append(CGPoint(x: a.x + (b.x - a.x) * u, y: a.y + (b.y - a.y) * u)) }
        }
        XCTAssertTrue(r.kb.debugTouch(from: keys[0], through: pts, start: 100))
        XCTAssertTrue(r.commands.isEmpty)
        XCTAssertEqual(SwipeTyping.fold(r.p.text), "chao")
        withExtendedLifetime(r.host) {}
    }

    @MainActor func testVerticalSwipeWordLiftingInsideKeysStillSwipes() {
        let r = rig()
        // x thẳng lên hàng trên rồi nhấc trong vùng phím: cử chỉ lệnh chưa bật ⇒ lúc nhấc bộ
        // phân loại gõ vuốt được xét điểm cuối ⇒ vẫn là cú vuốt (không thành chạm "x").
        let x = center(r.kb, "x"), e = center(r.kb, "e")
        XCTAssertTrue(r.kb.debugTouch(from: x, through: vertical(from: x, to: e.y), start: 100))
        XCTAssertTrue(r.commands.isEmpty)
        XCTAssertNotEqual(r.p.text.lowercased(), "x")
        withExtendedLifetime(r.host) {}
    }
}
