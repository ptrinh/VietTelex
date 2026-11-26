import XCTest
import UIKit

/// Regression (tester iOS 1.2.x): bàn phím / thanh gợi ý co lại ở Notes, Facebook và
/// lúc ngẫu nhiên — phím lùn/ép; tìm emoji cũng làm phím co. Quy tắc: vùng 4 hàng chữ
/// LUÔN đủ keyArea, dù đổi ô, tìm emoji hay host cấp thiếu chiều cao.
final class KeyboardHeightTests: XCTestCase {
    // MARK: Hàm thuần

    func testKeysModeStripOnTop() {
        let c = KeyLayout.chrome(keyArea: 212, strip: 34, mode: .keys)
        XCTAssertEqual(c, KeyLayout.Chrome(rowsTop: 34, rows: 212, total: 246, minTop: KeyLayout.balloonHeadroom))
    }

    func testEmojiGridTakesStripSameTotal() {
        let k = KeyLayout.chrome(keyArea: 212, strip: 34, mode: .keys)
        let e = KeyLayout.chrome(keyArea: 212, strip: 34, mode: .emoji)
        XCTAssertEqual(e.total, k.total)            // vào emoji không đổi chiều cao (Telegram)
        XCTAssertEqual(e.rowsTop, 0)
    }

    /// Bug: ô tìm chen vào keyArea ⇒ 4 hàng chữ còn 4/5 chiều cao.
    func testEmojiSearchKeepsFullKeyArea() {
        for strip: CGFloat in [0, 14, 34] {
            let c = KeyLayout.chrome(keyArea: 212, strip: strip, mode: .emojiSearch)
            let bar = KeyLayout.emojiSearchBarHeight(strip: strip)
            XCTAssertEqual(c.rows - bar, 212, "strip \(strip)")      // phần của hàng chữ
            XCTAssertEqual(c.total, c.rowsTop + c.rows)
            XCTAssertGreaterThanOrEqual(c.total, 212 + strip)         // không bao giờ thấp hơn plane chữ
        }
    }

    /// Bug: ô từ chối gợi ý (autocorrect .no — ô tìm Facebook, trait Notes chập chờn) làm
    /// strip 34 → 0 → 34 khi đang hiện; host không cấp lại ⇒ hàng phím bị ép.
    func testStripFollowsGlobalSettingNotField() {
        XCTAssertEqual(KeyLayout.stripHeight(reserved: true, open: 34), 34)
        XCTAssertEqual(KeyLayout.stripHeight(reserved: false, open: 34), 0)
    }

    func testPhoneLandscapeByWidth() {
        XCTAssertFalse(KeyLayout.isPhoneLandscape(width: 440, sceneLandscape: true))   // scene lệch: vẫn dọc
        XCTAssertFalse(KeyLayout.isPhoneLandscape(width: 375, sceneLandscape: nil))
        XCTAssertTrue(KeyLayout.isPhoneLandscape(width: 874, sceneLandscape: false))
        XCTAssertTrue(KeyLayout.isPhoneLandscape(width: 0, sceneLandscape: true))
        XCTAssertFalse(KeyLayout.isPhoneLandscape(width: 0, sceneLandscape: nil))
    }

    // MARK: View thật

    private var width: CGFloat { UIDevice.current.userInterfaceIdiom == .pad ? 834 : 390 }

    @MainActor private func makeKeyboard(suggestions: Bool = true) -> (KeyboardView, UIView) {
        let kb = KeyboardView(needsGlobe: false, inputController: nil) { _ in }
        let host = UIView(frame: CGRect(x: 0, y: 0, width: width, height: 400))
        host.addSubview(kb)
        kb.frame = CGRect(x: 0, y: 0, width: width, height: 300)
        kb.configureInputKind(.normal)
        kb.setSuggestionsEnabled(suggestions)
        kb.layoutIfNeeded()
        // Host cấp đúng mức xin.
        kb.frame.size.height = kb.debugRequestedHeight
        kb.setNeedsLayout(); kb.layoutIfNeeded()
        return (kb, host)
    }

    @MainActor private func letterRowHeight(_ kb: KeyboardView) throws -> (q: CGFloat, z: CGFloat) {
        (try XCTUnwrap(kb.debugLetterFrame("q")).height, try XCTUnwrap(kb.debugLetterFrame("z")).height)
    }

    @MainActor func testFieldWithoutSuggestionsKeepsHeight() throws {
        let (kb, host) = makeKeyboard()
        _ = host
        let h0 = kb.debugRequestedHeight
        kb.setSuggestionsEnabled(false, reserveStrip: true)   // sang ô mật khẩu / autocorrect .no
        XCTAssertEqual(kb.debugRequestedHeight, h0)
        kb.setSuggestionsEnabled(true, reserveStrip: true)
        XCTAssertEqual(kb.debugRequestedHeight, h0)
    }

    /// Host cấp THIẾU: strip co trước (tới sàn headroom balloon 20pt), phím giữ nguyên;
    /// thiếu quá sàn thì phím mới co — headroom balloon KHÔNG bao giờ mất (Phil 30/09).
    @MainActor func testHostShortfallSqueezesStripNotKeys() throws {
        let (kb, host) = makeKeyboard()
        _ = host
        let full = try letterRowHeight(kb)
        let spare = kb.debugRowsTop - KeyLayout.balloonHeadroom         // 34 − 20
        kb.frame.size.height = kb.debugRequestedHeight - spare
        kb.setNeedsLayout(); kb.layoutIfNeeded()
        let squeezed = try letterRowHeight(kb)
        XCTAssertEqual(squeezed.q, full.q, accuracy: 0.5)
        XCTAssertEqual(squeezed.z, full.z, accuracy: 0.5)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(kb.debugRowFrames().first).minY, KeyLayout.balloonHeadroom - 0.5)
        kb.frame.size.height = kb.debugRequestedHeight - 34 - 20
        kb.setNeedsLayout(); kb.layoutIfNeeded()
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(kb.debugRowFrames().first).minY, KeyLayout.balloonHeadroom - 0.5,
                                    "headroom balloon giữ cả khi host thiếu nhiều")
    }

    /// Host cấp thiếu: icon mép (☰ …) đi theo dòng chữ gợi ý, không đè lên hàng phím đầu.
    @MainActor func testHostShortfallKeepsBarIconsOnTheSuggestionRow() throws {
        let (kb, host) = makeKeyboard()
        _ = host
        XCTAssertEqual(kb.debugBurgerIconMidY, kb.debugSuggestionBarFrame.midY, accuracy: 0.5)
        for cut in [8, 14, 24] as [CGFloat] {
            kb.frame.size.height = kb.debugRequestedHeight - cut
            kb.setNeedsLayout(); kb.layoutIfNeeded()
            let bar = kb.debugSuggestionBarFrame, rowTop = try XCTUnwrap(kb.debugRowFrames().first).minY
            XCTAssertEqual(kb.debugBurgerIconMidY, bar.midY, accuracy: 0.5, "thiếu \(cut)")
            XCTAssertLessThanOrEqual(bar.maxY, rowTop + 0.5, "thiếu \(cut)")
        }
    }

    /// Tìm emoji: 4 hàng chữ cao y như plane chữ.
    @MainActor func testEmojiSearchDoesNotCompressKeys() throws {
        for suggestions in [true, false] {
            let (kb, host) = makeKeyboard(suggestions: suggestions)
            _ = host
            let full = try letterRowHeight(kb)
            let h0 = kb.debugRequestedHeight
            kb.debugEnterEmojiSearch()
            XCTAssertTrue(kb.debugInEmojiSearch)
            XCTAssertGreaterThanOrEqual(kb.debugRequestedHeight, h0)
            kb.frame.size.height = kb.debugRequestedHeight
            kb.setNeedsLayout(); kb.layoutIfNeeded()
            let s = try letterRowHeight(kb)
            XCTAssertEqual(s.q, full.q, accuracy: 0.5, "suggestions \(suggestions)")
            XCTAssertEqual(s.z, full.z, accuracy: 0.5, "suggestions \(suggestions)")
        }
    }
}

/// Regression (Phil 05/10/2026, iPhone thật iOS 27, WhatsApp, theme đen): dải kính xám bo góc
/// lộ phía trên nền mình — container hệ thống cao hơn view. HostFill xin thêm ĐÚNG phần đã cấp,
/// có xác nhận một lượt, không bao giờ thành vòng lặp tăng dần.
final class HostFillTests: XCTestCase {
    private let base: CGFloat = 252, width: CGFloat = 402

    func testAllocatedOnlyWhenBottomAnchored() {
        let container = CGRect(x: 0, y: 0, width: 402, height: 270)
        XCTAssertEqual(HostFill.allocated(viewFrame: CGRect(x: 0, y: 18, width: 402, height: 252),
                                          container: container), 270)
        XCTAssertNil(HostFill.allocated(viewFrame: CGRect(x: 0, y: 0, width: 402, height: 252),
                                        container: container), "neo đỉnh: không phải dải phía trên")
        XCTAssertNil(HostFill.allocated(viewFrame: .zero, container: container))
    }

    func testNoBandDoesNothing() {
        var f = HostFill()
        XCTAssertEqual(f.observe(base: base, viewHeight: base, allocated: base, width: width, animating: false), .none)
        XCTAssertEqual(f.observe(base: base, viewHeight: base, allocated: nil, width: width, animating: false), .none)
        // Host cấp DƯ cho chính view (container = view): không xin thêm (phím đã hấp thụ).
        XCTAssertEqual(f.observe(base: base, viewHeight: base + 25, allocated: base + 25, width: width, animating: false), .none)
        XCTAssertEqual(f.extra, 0)
    }

    func testBandConfirmedNextPassThenMatchesExactly() {
        var f = HostFill()
        XCTAssertEqual(f.observe(base: base, viewHeight: base, allocated: base + 18, width: width, animating: false), .wait)
        XCTAssertEqual(f.observe(base: base, viewHeight: base, allocated: base + 18, width: width, animating: false), .apply(18))
        // Hệ thống chưa kịp cấp lại view (vẫn hở, nhưng ≤ mức đã xin): chờ, không khoá.
        XCTAssertEqual(f.observe(base: base, viewHeight: base, allocated: base + 18, width: width, animating: false), .none)
        XCTAssertFalse(f.locked)
        // Cấp xong: view = container → ổn định, giữ nguyên.
        XCTAssertEqual(f.observe(base: base, viewHeight: base + 18, allocated: base + 18, width: width, animating: false), .none)
        XCTAssertEqual(f.extra, 18)
    }

    func testTransientSizeNotConfirmedIsIgnored() {
        var f = HostFill()
        XCTAssertEqual(f.observe(base: base, viewHeight: base, allocated: base + 30, width: width, animating: false), .wait)
        // Lượt sau khung đã khác (đang settle) ⇒ chờ tiếp, không áp số cũ.
        XCTAssertEqual(f.observe(base: base, viewHeight: base, allocated: base + 12, width: width, animating: false), .wait)
        XCTAssertEqual(f.observe(base: base, viewHeight: base, allocated: base, width: width, animating: false), .none)
        XCTAssertEqual(f.extra, 0)
    }

    func testAnimationOnlyWaits() {
        var f = HostFill()
        for _ in 0..<3 {
            XCTAssertEqual(f.observe(base: base, viewHeight: base, allocated: base + 18, width: width, animating: true), .wait)
        }
        XCTAssertEqual(f.extra, 0)
    }

    func testHugeOrNegativeAllocationIgnored() {
        var f = HostFill()
        for _ in 0..<3 {
            XCTAssertEqual(f.observe(base: base, viewHeight: base, allocated: base + HostFill.maxExtra + 40,
                                     width: width, animating: false), .none)
        }
        XCTAssertEqual(f.extra, 0)
    }

    /// Vòng lặp: container luôn = mức xin + 18 ⇒ tối đa MỘT lần xin thêm rồi trả về 0 và khoá.
    func testFeedbackLoopLocksAfterOneGrow() {
        var f = HostFill()
        var requested = base
        var applies = 0
        for _ in 0..<20 {
            let allocated = requested + 18          // hệ thống "chạy theo" mức xin
            switch f.observe(base: base, viewHeight: requested, allocated: allocated, width: width, animating: false) {
            case .apply(let x): applies += 1; requested = base + x
            case .wait, .none: break
            }
        }
        XCTAssertTrue(f.locked)
        XCTAssertEqual(f.extra, 0)
        XCTAssertEqual(requested, base, "trả về mức xin gốc")
        XCTAssertLessThanOrEqual(applies, 2)
        XCTAssertLessThanOrEqual(requested, base + HostFill.maxExtra)
    }

    func testNeverRequestsBeyondAllocated() {
        for gap: CGFloat in [1, 5, 18, 30, HostFill.maxExtra] {
            var f = HostFill()
            _ = f.observe(base: base, viewHeight: base, allocated: base + gap, width: width, animating: false)
            let d = f.observe(base: base, viewHeight: base, allocated: base + gap, width: width, animating: false)
            XCTAssertEqual(d, .apply(gap), "gap \(gap)")
            XCTAssertLessThanOrEqual(base + f.extra, base + gap)
        }
    }

    func testRotationAndResetDropExtra() {
        var f = HostFill()
        _ = f.observe(base: base, viewHeight: base, allocated: base + 18, width: width, animating: false)
        XCTAssertEqual(f.observe(base: base, viewHeight: base, allocated: base + 18, width: width, animating: false), .apply(18))
        XCTAssertEqual(f.observe(base: 172, viewHeight: 172, allocated: 172, width: 874, animating: false), .apply(0))
        XCTAssertEqual(f.extra, 0)
        f.reset()
        XCTAssertFalse(f.locked)
    }

    /// Regression (11/2026, Facebook / Messenger / Telegram, ảnh nền): tắt/mở màn hình khi bàn
    /// phím đang hiện ⇒ hệ thống dựng lại container theo mức xin HIỆN TẠI + dải kính. Phần xin
    /// thêm đã có hiệu lực ⇒ đó là cấp lại, KHÔNG phải vòng lặp: lấp tiếp, không khoá về 0.
    func testReallocationAfterSettledFillRefills() {
        var f = HostFill()
        _ = f.observe(base: base, viewHeight: base, allocated: base + 18, width: width, animating: false)
        XCTAssertEqual(f.observe(base: base, viewHeight: base, allocated: base + 18, width: width, animating: false), .apply(18))
        XCTAssertEqual(f.observe(base: base, viewHeight: base + 18, allocated: base + 18, width: width, animating: false), .none)
        XCTAssertTrue(f.settled)
        // Mở màn hình: container = mức xin (base+18) + 18, view vẫn base+18.
        XCTAssertEqual(f.observe(base: base, viewHeight: base + 18, allocated: base + 36, width: width, animating: false), .wait)
        XCTAssertEqual(f.observe(base: base, viewHeight: base + 18, allocated: base + 36, width: width, animating: false), .apply(36))
        XCTAssertFalse(f.locked)
        XCTAssertEqual(f.observe(base: base, viewHeight: base + 36, allocated: base + 36, width: width, animating: false), .none)
        XCTAssertEqual(f.extra, 36)
        // Lần cấp lại kế mà vượt trần ⇒ giữ nguyên (không kéo cao vô hạn, không khoá).
        for _ in 0..<3 {
            XCTAssertEqual(f.observe(base: base, viewHeight: base + 36, allocated: base + 54, width: width, animating: false), .none)
        }
        XCTAssertEqual(f.extra, 36)
        XCTAssertLessThanOrEqual(f.extra, HostFill.maxExtra)
    }

    /// Khung tạm lúc animation (mở màn hình / hiện lại) khi đã có phần xin thêm: chỉ chờ, không khoá.
    func testTransientTallerContainerWhileAnimatingDoesNotLock() {
        var f = HostFill()
        _ = f.observe(base: base, viewHeight: base, allocated: base + 18, width: width, animating: false)
        XCTAssertEqual(f.observe(base: base, viewHeight: base, allocated: base + 18, width: width, animating: false), .apply(18))
        for _ in 0..<3 {
            XCTAssertEqual(f.observe(base: base, viewHeight: base, allocated: base + 40, width: width, animating: true), .wait)
        }
        XCTAssertFalse(f.locked)
        XCTAssertEqual(f.extra, 18)
        // Khung tạm chưa xác nhận (lượt sau đã khác) cũng không khoá.
        XCTAssertEqual(f.observe(base: base, viewHeight: base, allocated: base + 40, width: width, animating: false), .wait)
        XCTAssertEqual(f.observe(base: base, viewHeight: base + 18, allocated: base + 18, width: width, animating: false), .none)
        XCTAssertFalse(f.locked)
        XCTAssertEqual(f.extra, 18)
    }

    /// Sau một lần lấp có hiệu lực, vòng lặp thật (container đuổi theo mức xin, phần thêm mới
    /// chưa từng có hiệu lực) vẫn bị khoá về 0.
    func testLoopAfterSettledFillStillLocks() {
        var f = HostFill()
        _ = f.observe(base: base, viewHeight: base, allocated: base + 10, width: width, animating: false)
        XCTAssertEqual(f.observe(base: base, viewHeight: base, allocated: base + 10, width: width, animating: false), .apply(10))
        _ = f.observe(base: base, viewHeight: base + 10, allocated: base + 10, width: width, animating: false)
        var requested = base + 10
        for _ in 0..<20 {
            switch f.observe(base: base, viewHeight: requested, allocated: requested + 10, width: width, animating: false) {
            case .apply(let x): requested = base + x
            case .wait, .none: break
            }
        }
        XCTAssertTrue(f.locked)
        XCTAssertEqual(f.extra, 0)
        XCTAssertEqual(requested, base)
    }

    /// Phần xin thêm cộng vào mức xin; strip / headroom balloon giữ nguyên, phím hấp thụ.
    @MainActor func testExtraRaisesRequestKeepsStrip() throws {
        let kb = KeyboardView(needsGlobe: false, inputController: nil) { _ in }
        let host = UIView(frame: CGRect(x: 0, y: 0, width: 390, height: 400))
        host.addSubview(kb)
        kb.frame = CGRect(x: 0, y: 0, width: 390, height: 300)
        kb.configureInputKind(.normal)
        kb.setSuggestionsEnabled(true)
        kb.layoutIfNeeded()
        let h0 = kb.debugRequestedHeight, top0 = kb.debugRowsTop
        XCTAssertEqual(kb.baseRequestedHeight, h0)
        kb.hostFillExtra = 18
        XCTAssertEqual(kb.debugRequestedHeight, h0 + 18)
        XCTAssertEqual(kb.baseRequestedHeight, h0)
        XCTAssertEqual(kb.debugRowsTop, top0)
        kb.frame.size.height = kb.debugRequestedHeight
        kb.setNeedsLayout(); kb.layoutIfNeeded()
        let rows = try XCTUnwrap(kb.debugRowFrames().first)
        XCTAssertEqual(rows.minY, top0, accuracy: 0.5, "strip không dời")
        kb.hostFillExtra = 0
        XCTAssertEqual(kb.debugRequestedHeight, h0)
        withExtendedLifetime(host) {}
    }
}

/// Regression (Phil 30/09/2026, máy thật sau 1.2.3): giữ "e" ra "3" — balloon bị cắt nửa ở
/// mép trên bàn phím khi KHÔNG có thanh gợi ý phía trên (tắt gợi ý / thu gọn / host cấp
/// thiếu làm strip nhường hết). Extension không vẽ ra ngoài inputView ⇒ balloon hàng đầu
/// phải nằm TRỌN trong view, chữ không bị cắt.
final class BalloonHeadroomTests: XCTestCase {
    private var width: CGFloat { UIDevice.current.userInterfaceIdiom == .pad ? 834 : 390 }

    @MainActor private func assertBalloonFits(_ kb: KeyboardView, _ what: String) throws {
        kb.setNeedsLayout(); kb.layoutIfNeeded()
        for (key, text) in [("e", "3"), ("q", "1"), ("p", "0"), ("e", "E")] {
            let b = try XCTUnwrap(kb.debugBalloon(letter: key, text: text), what)
            XCTAssertGreaterThanOrEqual(b.frame.minY, -0.01, "\(what) \(key): balloon vượt mép trên")
            XCTAssertLessThanOrEqual(b.frame.maxY, kb.bounds.height + 0.01, what)
            XCTAssertGreaterThanOrEqual(b.label.minY, -0.01, "\(what) \(key): chữ bị cắt")
            XCTAssertLessThanOrEqual(b.fontSize, b.label.height, "\(what) \(key): chữ cao hơn bubble")
        }
    }

    @MainActor private func make(suggestions: Bool, reserve: Bool? = nil,
                                 shortfall: CGFloat = 0) -> (KeyboardView, UIView) {
        let kb = KeyboardView(needsGlobe: false, inputController: nil) { _ in }
        let host = UIView(frame: CGRect(x: 0, y: 0, width: width, height: 400))
        host.overrideUserInterfaceStyle = .light
        host.addSubview(kb)
        kb.frame = CGRect(x: 0, y: 0, width: width, height: 300)
        kb.applyAppearance(.light, style: .light)
        kb.configureInputKind(.normal)
        kb.setSuggestionsEnabled(suggestions, reserveStrip: reserve)
        kb.layoutIfNeeded()
        kb.frame.size.height = kb.debugRequestedHeight - shortfall
        return (kb, host)
    }

    @MainActor func testBalloonInsideBoundsAllConfigs() throws {
        let configs: [(String, Bool, Bool?, CGFloat)] = [
            ("gợi ý bật", true, nil, 0),
            ("gợi ý tắt", false, nil, 0),
            ("ô từ chối gợi ý", false, true, 0),
            ("host thiếu 34pt", true, nil, 34),
            ("host thiếu 60pt", true, nil, 60),
            ("gợi ý tắt + host thiếu", false, nil, 20),
        ]
        for (what, sug, reserve, short) in configs {
            let (kb, host) = make(suggestions: sug, reserve: reserve, shortfall: short)
            try assertBalloonFits(kb, what)
            withExtendedLifetime(host) {}
        }
        let (kb, host) = make(suggestions: true)
        kb.debugEnterEmojiSearch()
        kb.frame.size.height = kb.debugRequestedHeight
        try assertBalloonFits(kb, "tìm emoji")
        withExtendedLifetime(host) {}
    }

    /// Mọi strip (tắt 0 / thu gọn 14 / mở 34) đều chừa headroom balloon phía trên phím.
    func testHeadroomAlwaysReserved() {
        for strip: CGFloat in [0, 14, 34] {
            let c = KeyLayout.chrome(keyArea: 212, strip: strip, mode: .keys)
            XCTAssertGreaterThanOrEqual(c.rowsTop, KeyLayout.balloonHeadroom)
            XCTAssertGreaterThanOrEqual(c.minTop, KeyLayout.balloonHeadroom)
        }
    }
}

/// Regression (11/2026, iPhone, Facebook / Messenger / Telegram, ảnh nền phím): tắt rồi mở màn
/// hình khi bàn phím đang hiện ⇒ dải xám lộ phía trên ảnh nền (vùng thanh gợi ý). Ảnh nền luôn
/// = bounds KeyboardView, KeyboardView = view gốc; dải xám là container hệ thống CAO HƠN view
/// (HostFill). Controller THẬT: lấp dải lần đầu → container dựng lại cao hơn (mở màn hình) →
/// bàn phím phải phủ trọn container lần nữa, ảnh nền / nền theme = trọn bàn phím.
@MainActor
final class HostFillResumeTests: XCTestCase {
    private let suite = "vt-hostfill-resume-tests"

    final class Host: UIViewController {
        override var shouldAutomaticallyForwardAppearanceMethods: Bool { false }
    }

    private struct Rig {
        let win: UIWindow, container: UIView, vc: KeyboardViewController
        var kb: KeyboardView { vc.debugKeyboard }
        /// Một lượt layout hệ thống (viewDidLayoutSubviews → checkHostFill).
        func pass() { vc.view.setNeedsLayout(); vc.view.layoutIfNeeded() }
        /// Container (dải kính hệ thống) cao `h`, view neo đáy cao `v`.
        func host(container h: CGFloat, view v: CGFloat) {
            let H = win.bounds.height
            container.frame = CGRect(x: 0, y: H - h, width: win.bounds.width, height: h)
            vc.view.frame = CGRect(x: 0, y: h - v, width: win.bounds.width, height: v)
        }
        /// Hệ thống cấp cho view đúng mức xin; container giữ nguyên (không thấp hơn mức xin).
        func grantRequest() {
            let req = kb.debugRequestedHeight
            host(container: max(container.bounds.height, req), view: req)
            pass()
        }
    }

    private func makeRig() -> Rig {
        let w: CGFloat = 402, H: CGFloat = 874
        let win = UIWindow(frame: CGRect(x: 0, y: 0, width: w, height: H))
        let hostVC = Host()
        win.rootViewController = hostVC
        win.isHidden = false
        hostVC.view.layoutIfNeeded()
        let container = UIView()
        hostVC.view.addSubview(container)
        let vc = KeyboardViewController()
        vc.debugProxy = KeyboardBenchTests.BenchProxy()
        vc.debugFullAccess = false
        vc.loadViewIfNeeded()
        hostVC.addChild(vc)
        container.addSubview(vc.view)
        vc.didMove(toParent: hostVC)
        vc.debugKeyboard.debugScreenSize = CGSize(width: w, height: H)
        vc.debugKeyboard.debugSetSafeBottom(0)
        return Rig(win: win, container: container, vc: vc)
    }

    private func assertCoversContainer(_ r: Rig, _ what: String, file: StaticString = #filePath, line: UInt = #line) {
        let kbInContainer = r.kb.convert(r.kb.bounds, to: r.container)
        XCTAssertEqual(kbInContainer.minY, 0, accuracy: 0.5, "\(what): dải hệ thống lộ phía trên bàn phím", file: file, line: line)
        XCTAssertEqual(kbInContainer.height, r.container.bounds.height, accuracy: 0.5, what, file: file, line: line)
        for f in r.kb.debugBackdrop.frames {
            XCTAssertEqual(f, r.kb.bounds, "\(what): nền / ảnh nền không phủ trọn bàn phím", file: file, line: line)
        }
    }

    func testBandAfterScreenOffOnIsFilledAgain() throws {
        guard UIDevice.current.userInterfaceIdiom == .phone,
              ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26 else {
            throw XCTSkip("HostFill chỉ chạy trên iPhone iOS 26+")
        }
        let saved = UserDefaultsProvider.shared
        defer {
            UserDefaultsProvider.shared = saved
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        }
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        d.set(true, forKey: "showSuggestions")
        d.set(KeyboardTheme.oled.rawValue, forKey: ThemeSettings.themeKey)   // nền đục (như ảnh nền)
        UserDefaultsProvider.shared = d

        let r = makeRig()
        defer {
            r.vc.beginAppearanceTransition(false, animated: false)
            r.vc.endAppearanceTransition()
            r.vc.willMove(toParent: nil); r.vc.view.removeFromSuperview(); r.vc.removeFromParent()
            r.win.isHidden = true
        }
        r.vc.beginAppearanceTransition(true, animated: false)
        let base = r.kb.debugRequestedHeight
        XCTAssertGreaterThan(base, 0)
        r.vc.endAppearanceTransition()
        XCTAssertTrue(r.kb.paintsBackdrop)

        // Hiện lần đầu: container cao hơn view 18pt ⇒ xác nhận một lượt rồi xin thêm đúng 18.
        r.host(container: base + 18, view: base)
        r.pass(); r.pass()
        XCTAssertEqual(r.kb.debugRequestedHeight, base + 18)
        r.grantRequest()
        assertCoversContainer(r, "lần đầu")
        XCTAssertTrue(r.vc.debugHostFill.settled)

        // Tắt / mở màn hình: hệ thống dựng lại container = mức xin hiện tại + dải kính.
        r.host(container: base + 18 + 18, view: base + 18)
        r.pass(); r.pass()
        XCTAssertFalse(r.vc.debugHostFill.locked, "cấp lại sau mở màn hình không phải vòng lặp")
        XCTAssertEqual(r.kb.debugRequestedHeight, base + 36)
        r.grantRequest()
        assertCoversContainer(r, "sau mở màn hình")

        // Đổi sáng/tối lúc mở khoá (trait) + vài lượt layout nữa: vẫn phủ trọn.
        r.kb.updateDark(true); r.pass()
        r.kb.updateDark(false); r.pass()
        assertCoversContainer(r, "sau đổi sáng/tối")

        // Chu kỳ ẩn/hiện đầy đủ (xé + dựng lại), container giữ cỡ cũ: lần hiện mới lấp lại.
        r.vc.beginAppearanceTransition(false, animated: false)
        r.vc.endAppearanceTransition()
        r.vc.beginAppearanceTransition(true, animated: false)
        r.vc.endAppearanceTransition()
        let base2 = r.kb.debugRequestedHeight
        XCTAssertEqual(base2, base)
        r.host(container: base + 36, view: base2)
        r.pass(); r.pass()
        r.grantRequest()
        assertCoversContainer(r, "sau ẩn/hiện")
    }
}

/// Chờ chiều cao host ổn định trước khi hiện (HeightSettleGuard): hiện ngay khi không còn gì chờ,
/// chờ khi đã xin thêm mà host chưa cấp, và KHÔNG BAO GIỜ giữ ẩn quá trần.
final class HeightSettleGuardTests: XCTestCase {
    private let base: CGFloat = 252

    func testRevealsImmediatelyWhenNothingPending() {
        var g = HeightSettleGuard()
        g.arm(now: 0)
        XCTAssertTrue(g.hidden)
        XCTAssertTrue(g.shouldReveal(decision: .none, base: base, extra: 0, viewHeight: base, inWindow: true, now: 0.001))
        XCTAssertFalse(g.hidden)
        XCTAssertFalse(g.shouldReveal(decision: .none, base: base, extra: 0, viewHeight: base, inWindow: true, now: 0.002),
                       "chỉ báo hiện một lần")
    }

    func testWaitsForBandConfirmationAndGrant() {
        var g = HeightSettleGuard()
        g.arm(now: 0)
        XCTAssertFalse(g.shouldReveal(decision: .wait, base: base, extra: 0, viewHeight: base, inWindow: true, now: 0.01))
        XCTAssertFalse(g.shouldReveal(decision: .apply(18), base: base, extra: 18, viewHeight: base, inWindow: true, now: 0.16))
        // Host chưa cấp phần xin thêm: HostFill .none nhưng view còn thấp ⇒ chờ.
        XCTAssertFalse(g.shouldReveal(decision: .none, base: base, extra: 18, viewHeight: base, inWindow: true, now: 0.17))
        XCTAssertTrue(g.shouldReveal(decision: .none, base: base, extra: 18, viewHeight: base + 18, inWindow: true, now: 0.2))
    }

    func testNotInWindowOrZeroHeightWaits() {
        var g = HeightSettleGuard()
        g.arm(now: 0)
        XCTAssertFalse(g.shouldReveal(decision: .none, base: base, extra: 0, viewHeight: base, inWindow: false, now: 0.01))
        XCTAssertFalse(g.shouldReveal(decision: .none, base: base, extra: 0, viewHeight: 0, inWindow: true, now: 0.02))
    }

    func testHostShortfallWithoutExtraIsFinal() {
        var g = HeightSettleGuard()
        g.arm(now: 0)
        XCTAssertTrue(g.shouldReveal(decision: .none, base: base, extra: 0, viewHeight: base - 30, inWindow: true, now: 0.01),
                      "cấp thiếu (strip co) là chiều cao cuối — không chờ tới trần")
    }

    func testCapAlwaysReveals() {
        var g = HeightSettleGuard()
        g.arm(now: 10)
        XCTAssertFalse(g.reveal(now: 10.1), "chưa tới trần")
        XCTAssertTrue(g.hidden)
        XCTAssertFalse(g.shouldReveal(decision: .wait, base: base, extra: 0, viewHeight: base, inWindow: true, now: 10.2))
        XCTAssertTrue(g.shouldReveal(decision: .wait, base: base, extra: 0, viewHeight: base, inWindow: true,
                                     now: 10 + HeightSettleGuard.cap), "quá trần ⇒ hiện bất kể")
        g.arm(now: 20)
        XCTAssertTrue(g.reveal(now: 20 + HeightSettleGuard.cap), "hẹn giờ trần")
        g.arm(now: 30)
        XCTAssertTrue(g.reveal(now: 30, force: true), "chạm / ẩn: hiện ngay")
        XCTAssertFalse(g.reveal(now: 31, force: true), "không giữ ẩn ⇒ không làm gì")
        XCTAssertLessThanOrEqual(HeightSettleGuard.cap, 0.3)
    }

    /// Controller thật: nền đục (theme đen) trên iPhone iOS 26+ — chưa có lượt layout nào xác nhận
    /// (view chưa vào cửa sổ) ⇒ giữ ẩn; hẹn giờ trần hiện lại dù không còn lượt layout nào.
    @MainActor func testControllerNeverStaysInvisible() throws {
        guard UIDevice.current.userInterfaceIdiom == .phone,
              ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26 else {
            throw XCTSkip("HostFill chỉ chạy trên iPhone iOS 26+")
        }
        let suite = "vt-settle-guard-tests"
        let saved = UserDefaultsProvider.shared
        defer {
            UserDefaultsProvider.shared = saved
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        }
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        d.set(KeyboardTheme.oled.rawValue, forKey: ThemeSettings.themeKey)
        UserDefaultsProvider.shared = d

        let vc = KeyboardViewController()
        vc.debugProxy = KeyboardBenchTests.BenchProxy()
        vc.debugFullAccess = false
        vc.loadViewIfNeeded()
        vc.view.frame = CGRect(x: 0, y: 0, width: 402, height: 300)
        vc.beginAppearanceTransition(true, animated: false)
        XCTAssertTrue(vc.debugKeyboard.paintsBackdrop)
        vc.view.layoutIfNeeded()
        XCTAssertTrue(vc.debugContentHeld, "chưa vào cửa sổ: hình học chưa đáng tin ⇒ chờ")
        XCTAssertEqual(vc.debugKeyboard.alpha, 0)
        RunLoop.main.run(until: Date().addingTimeInterval(HeightSettleGuard.cap + 0.1))
        XCTAssertFalse(vc.debugContentHeld, "trần cứng: luôn hiện lại")
        XCTAssertEqual(vc.debugKeyboard.alpha, 1)
        vc.endAppearanceTransition()
        vc.beginAppearanceTransition(false, animated: false)
        vc.endAppearanceTransition()
    }

    /// Trường hợp thường (không dải hở, view trong cửa sổ): hiện ngay ở lượt layout đầu — không trễ.
    @MainActor func testControllerRevealsAtFirstLayoutWhenSettled() throws {
        guard UIDevice.current.userInterfaceIdiom == .phone,
              ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26 else {
            throw XCTSkip("HostFill chỉ chạy trên iPhone iOS 26+")
        }
        let suite = "vt-settle-guard-tests-2"
        let saved = UserDefaultsProvider.shared
        defer {
            UserDefaultsProvider.shared = saved
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        }
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        d.set(KeyboardTheme.oled.rawValue, forKey: ThemeSettings.themeKey)
        UserDefaultsProvider.shared = d

        let r = KeyboardStartupTests.Rig(fullAccess: false, appear: false)
        defer { r.close() }
        XCTAssertTrue(r.vc.debugKeyboard.paintsBackdrop)
        XCTAssertFalse(r.vc.debugContentHeld, "khung đầu: đã hiện")
        XCTAssertEqual(r.vc.debugKeyboard.alpha, 1)
    }
}

/// Regression #151 (iOS 1.2.29, Telegram): hiện bàn phím / đổi sang bằng 🌐, thỉnh thoảng bàn phím
/// CAO hơn hẳn — thanh gợi ý trên đỉnh, dải trống ~150–350pt, hàng phím (đã giãn +60) dưới đáy; kẹt
/// tới lần hiện sau. Hệ thống chỉ đo lại chiều cao extension khi cỡ fitting của view đổi
/// (systemLayoutFittingSizeDidChange lên controller cha); khung tạm cao mà không còn lượt đổi cỡ nào
/// ⇒ kẹt. Quy tắc: view cao hơn mức xin quá phần phím hấp thụ ⇒ bàn phím phải xin host đo lại
/// (có giới hạn số lần); host cấp dư bình thường (~25pt) ⇒ không làm gì.
final class HostOversizeTests: XCTestCase {
    private let req: CGFloat = 255

    func testThresholdMatchesRowsAbsorbCap() {
        XCTAssertEqual(HostOversize.threshold, KeyRowLayout.absorbMax)
        // Đúng ngưỡng: phím hấp thụ hết, chưa có dải trống.
        let a = KeyRowLayout.rowsArea(viewHeight: req + HostOversize.threshold, bottomInset: 0, top: 45,
                                      rows: req - 45, minTop: 10)
        XCTAssertEqual(a.top, 45, accuracy: 0.001)
    }

    func testNormalOversupplyIsIgnored() {
        var o = HostOversize()
        for _ in 0..<5 {
            XCTAssertEqual(o.observe(requested: req, viewHeight: req + 25, inWindow: true, animating: false), .none)
            XCTAssertEqual(o.observe(requested: req, viewHeight: req, inWindow: true, animating: false), .none)
            XCTAssertEqual(o.observe(requested: req, viewHeight: req - 30, inWindow: true, animating: false), .none)
        }
        XCTAssertEqual(o.nudges, 0)
    }

    func testStuckTallFrameRemeasuresThenBumpsThenStops() {
        var o = HostOversize()
        let tall = req + 195
        XCTAssertEqual(o.observe(requested: req, viewHeight: tall, inWindow: true, animating: false), .wait,
                       "lượt đầu: có thể là khung tạm — chờ xác nhận")
        XCTAssertEqual(o.observe(requested: req, viewHeight: tall, inWindow: true, animating: false), .remeasure)
        XCTAssertEqual(o.observe(requested: req, viewHeight: tall, inWindow: true, animating: false), .wait)
        XCTAssertEqual(o.observe(requested: req, viewHeight: tall, inWindow: true, animating: false), .bump)
        for _ in 0..<5 {
            XCTAssertEqual(o.observe(requested: req, viewHeight: tall, inWindow: true, animating: false), .none,
                           "host cố ý cấp dư: thôi, không lặp")
        }
        o.reset()
        XCTAssertEqual(o.nudges, 0)
        XCTAssertEqual(o.observe(requested: req, viewHeight: tall, inWindow: true, animating: false), .wait)
    }

    func testTransientFramesAndAnimationOnlyWait() {
        var o = HostOversize()
        XCTAssertEqual(o.observe(requested: req, viewHeight: req + 300, inWindow: true, animating: false), .wait)
        XCTAssertEqual(o.observe(requested: req, viewHeight: req + 200, inWindow: true, animating: false), .wait,
                       "khung đổi giữa hai lượt = đang settle")
        XCTAssertEqual(o.observe(requested: req, viewHeight: req + 200, inWindow: true, animating: true), .wait)
        XCTAssertEqual(o.observe(requested: req, viewHeight: req + 200, inWindow: true, animating: false), .wait,
                       "animation xoá xác nhận cũ")
        XCTAssertEqual(o.observe(requested: req, viewHeight: req, inWindow: true, animating: false), .none,
                       "host tự cấp lại đúng: hết")
        XCTAssertEqual(o.observe(requested: req, viewHeight: req + 200, inWindow: false, animating: false), .none)
        XCTAssertEqual(o.nudges, 0)
    }
}

/// #151 ở mức controller thật: host giữ view cao hơn mức xin ~195pt qua nhiều lượt layout ⇒ controller
/// báo controller cha (đúng đường UIKit dùng khi cỡ fitting đổi) — trước bản sửa: 0 lần báo, kẹt mãi.
final class HostOversizeControllerTests: XCTestCase {
    private let suite = "vt-host-oversize-tests"

    final class Host: UIViewController {
        var fittingChanges = 0
        override var shouldAutomaticallyForwardAppearanceMethods: Bool { false }
        override func systemLayoutFittingSizeDidChange(forChildContentContainer container: UIContentContainer) {
            fittingChanges += 1
            super.systemLayoutFittingSizeDidChange(forChildContentContainer: container)
        }
    }

    @MainActor func testStuckTallHostFrameAsksHostToRemeasure() {
        let saved = UserDefaultsProvider.shared
        let savedPaywall = PlusGate.paywallEnabled
        defer {
            UserDefaultsProvider.shared = saved
            PlusGate.paywallEnabled = savedPaywall
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        }
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        d.set(true, forKey: "showSuggestions")
        PlusGate.paywallEnabled = false
        d.set(BuddyCharacter.cat.rawValue, forKey: BuddyCharacter.key)          // như máy reporter
        d.set(KeyboardTheme.oled.rawValue, forKey: ThemeSettings.themeKey)     // nền đục
        d.set(KeyEffect.lightning.rawValue, forKey: KeyEffect.key)            // video 08/11: tia sét
        UserDefaultsProvider.shared = d

        let w: CGFloat = 402, H: CGFloat = 874
        let win = UIWindow(frame: CGRect(x: 0, y: 0, width: w, height: H))
        let host = Host()
        win.rootViewController = host
        win.isHidden = false
        host.view.layoutIfNeeded()
        let vc = KeyboardViewController()
        vc.debugProxy = KeyboardBenchTests.BenchProxy()
        vc.debugFullAccess = false
        vc.loadViewIfNeeded()
        host.addChild(vc)
        host.view.addSubview(vc.view)
        vc.didMove(toParent: host)
        vc.debugKeyboard.debugScreenSize = CGSize(width: w, height: H)
        vc.debugKeyboard.debugSetSafeBottom(0)
        defer {
            vc.beginAppearanceTransition(false, animated: false)
            vc.endAppearanceTransition()
            vc.willMove(toParent: nil); vc.view.removeFromSuperview(); vc.removeFromParent()
            win.isHidden = true
        }
        func pass(_ wait: TimeInterval = 0.2) {
            vc.view.setNeedsLayout(); vc.view.layoutIfNeeded()
            RunLoop.main.run(until: Date(timeIntervalSinceNow: wait))   // recheck hẹn giờ / trả lệch 1px
            vc.view.layoutIfNeeded()
        }

        // Trước viewWillAppear: host đặt khung cả màn hình cho controller (log WhatsApp 07/11) —
        // không được xin host đo lại lúc này.
        vc.view.frame = CGRect(x: 0, y: 0, width: w, height: H)
        pass(); pass(); pass()
        XCTAssertEqual(host.fittingChanges, 0, "chưa hiện: không xin host đo lại")

        vc.beginAppearanceTransition(true, animated: false)
        let req = vc.debugKeyboard.debugRequestedHeight
        XCTAssertGreaterThan(req, 0)
        vc.endAppearanceTransition()

        // Host cấp dư bình thường (~25pt): không xin gì.
        vc.view.frame = CGRect(x: 0, y: H - req - 25, width: w, height: req + 25)
        pass(); pass()
        XCTAssertEqual(host.fittingChanges, 0, "cấp dư bình thường: không đụng host")

        // Khung tạm cao (ảnh issue: ~195pt) kẹt lại.
        let tall = req + 195
        vc.view.frame = CGRect(x: 0, y: H - tall, width: w, height: tall)
        for _ in 0..<6 { pass() }
        XCTAssertGreaterThanOrEqual(host.fittingChanges, 1, "kẹt khung cao: phải xin host đo lại")
        XCTAssertLessThanOrEqual(host.fittingChanges, 3, "giới hạn: báo lại + 1px đi/về, không lặp")
        XCTAssertEqual(vc.debugKeyboard.debugRequestedHeight, req, "lệch 1px đã trả về")
        XCTAssertEqual(vc.view.systemLayoutSizeFitting(CGSize(width: w, height: 0),
                                                       withHorizontalFittingPriority: .required,
                                                       verticalFittingPriority: .fittingSizeLevel).height,
                       req, accuracy: 0.5, "đo lại ra đúng mức xin")

        // Trong lúc khung còn cao (ảnh issue 07/11, 1 khung hình trên 1.2.31): phần dư nằm TRÊN thanh
        // gợi ý (nền theme phủ), thanh gợi ý + hàng phím xếp y như khung cao vừa đủ — không dải trống
        // giữa thanh gợi ý và hàng phím, đáy hàng phím vẫn sát đáy view.
        let kb = vc.debugKeyboard
        func qFrame() -> CGRect? { kb.debugDomainKeyFrame("q") ?? kb.debugDomainKeyFrame("Q") }
        let capH = req + KeyRowLayout.absorbMax
        vc.view.frame = CGRect(x: 0, y: H - capH, width: w, height: capH); pass()
        XCTAssertEqual(kb.oversizeShift, 0)
        let qRef = try! XCTUnwrap(qFrame())
        vc.view.frame = CGRect(x: 0, y: H - tall, width: w, height: tall); pass()
        XCTAssertEqual(kb.oversizeShift, tall - req - KeyRowLayout.absorbMax, accuracy: 1)
        let qTall = try! XCTUnwrap(qFrame())
        XCTAssertEqual(qTall.minY, qRef.minY, accuracy: 1, "chrome trên hàng phím xếp như khung vừa đủ")
        XCTAssertEqual(qTall.height, qRef.height, accuracy: 1)
        XCTAssertEqual(kb.bounds.minY, -kb.oversizeShift, accuracy: 0.01, "phần dư nằm trên đỉnh nội dung")
        // Video 08/11 (1.2.32): tia sét đánh lên thanh trạng thái. Mọi lớp phủ trọn bàn phím (hiệu ứng
        // phím, ô phóng to, game) vẽ theo toạ độ KeyboardView ⇒ phải cùng hệ toạ độ, cả khi cao tạm
        // lẫn khi về vừa đủ; ô phóng to phải nằm ngay trên phím được bấm.
        let qKey = try! XCTUnwrap(kb.debugDomainKeyView("q") ?? kb.debugDomainKeyView("Q"))
        kb.debugShowBalloon(over: qKey, text: "q")
        func checkFx(_ why: String) {
            guard kb.keyEffects != nil else { return XCTFail("tia sét phải bật: \(why)") }
            XCTAssertTrue(kb.debugBalloonMade, why)
            for o in kb.debugCoordinateOverlays {
                XCTAssertEqual(o.convert(qTall, from: kb), qTall, "\(type(of: o)) lệch toạ độ: \(why)")
                XCTAssertEqual(o.frame, kb.bounds, "\(type(of: o)) phủ trọn bàn phím: \(why)")
            }
            if let bf = kb.debugBalloonFrame, let host = kb.debugCoordinateOverlays.first(where: { $0.subviews.contains { $0.frame == bf } }) {
                let inKb = kb.convert(bf, from: host)
                let key = kb.convert(qKey.bounds, from: qKey)
                XCTAssertEqual(inKb.midX, key.midX, accuracy: key.width, "ô phóng to trên phím q: \(why)")
                XCTAssertLessThanOrEqual(inKb.minY, key.minY, "ô phóng to nhô lên trên phím: \(why)")
                XCTAssertGreaterThanOrEqual(inKb.maxY, key.minY, "ô phóng to chạm phím: \(why)")
            }
        }
        checkFx("khung cao tạm")
        vc.view.frame = CGRect(x: 0, y: H - req, width: w, height: req); pass()
        XCTAssertEqual(kb.oversizeShift, 0)
        checkFx("về khung vừa đủ")

        // Lần hiện mới: đếm lại từ đầu.
        vc.beginAppearanceTransition(false, animated: false); vc.endAppearanceTransition()
        vc.beginAppearanceTransition(true, animated: false); vc.endAppearanceTransition()
        vc.view.frame = CGRect(x: 0, y: H - req, width: w, height: req)
        pass()
        let before = host.fittingChanges
        vc.view.frame = CGRect(x: 0, y: H - tall, width: w, height: tall)
        for _ in 0..<3 { pass() }
        XCTAssertGreaterThan(host.fittingChanges, before, "lần hiện mới lại được xin đo lại")
    }

    /// WhatsApp quay lại từ nền (log máy Phil 07/11/2026): host dựng controller MỚI và đo nó ở khung cả
    /// màn hình TRƯỚC viewWillAppear. View chưa cấu hình phải xin đúng chiều cao lần hiện trước (267),
    /// không phải chiều cao mặc định chưa có thanh gợi ý (232) — đo sai lúc đó WhatsApp giữ khung kính
    /// cao sai (dải xám) tới khi bị tắt hẳn.
    @MainActor func testUnconfiguredControllerRequestsLastShownHeight() {
        let saved = UserDefaultsProvider.shared
        let savedPaywall = PlusGate.paywallEnabled
        let savedLast = KeyboardView.lastConfiguredHeight
        defer {
            UserDefaultsProvider.shared = saved
            PlusGate.paywallEnabled = savedPaywall
            KeyboardView.lastConfiguredHeight = savedLast
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        }
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        d.set(true, forKey: "showSuggestions")
        PlusGate.paywallEnabled = false
        UserDefaultsProvider.shared = d
        KeyboardView.lastConfiguredHeight = 0

        let w: CGFloat = 375, H: CGFloat = 812
        let win = UIWindow(frame: CGRect(x: 0, y: 0, width: w, height: H))
        let host = Host()
        win.rootViewController = host
        win.isHidden = false
        func attach() -> KeyboardViewController {
            let vc = KeyboardViewController()
            vc.debugProxy = KeyboardBenchTests.BenchProxy()
            vc.debugFullAccess = false
            vc.loadViewIfNeeded()
            host.addChild(vc); host.view.addSubview(vc.view); vc.didMove(toParent: host)
            vc.debugKeyboard.debugScreenSize = CGSize(width: w, height: H)
            vc.debugKeyboard.debugSetSafeBottom(0)
            return vc
        }
        func detach(_ vc: KeyboardViewController) {
            vc.beginAppearanceTransition(false, animated: false); vc.endAppearanceTransition()
            vc.willMove(toParent: nil); vc.view.removeFromSuperview(); vc.removeFromParent()
        }
        defer { win.isHidden = true }

        // Lần hiện đầu (sau khi mở app): cấu hình xong ⇒ mức xin có thanh gợi ý.
        let first = attach()
        first.beginAppearanceTransition(true, animated: false); first.endAppearanceTransition()
        first.view.frame = CGRect(x: 0, y: 0, width: w, height: 300); first.view.layoutIfNeeded()
        let shown = first.debugKeyboard.debugRequestedHeight
        XCTAssertGreaterThan(shown, 0)
        detach(first)

        // Quay lại từ nền: controller mới, host đo ở khung cả màn hình trước willAppear.
        let again = attach()
        again.view.frame = CGRect(x: 0, y: 0, width: w, height: H)
        again.view.setNeedsLayout(); again.view.layoutIfNeeded()
        XCTAssertEqual(again.debugKeyboard.debugRequestedHeight, shown, accuracy: 0.5,
                       "chưa cấu hình: xin đúng chiều cao lần hiện trước")
        again.beginAppearanceTransition(true, animated: false); again.endAppearanceTransition()
        again.view.frame = CGRect(x: 0, y: 0, width: w, height: shown); again.view.layoutIfNeeded()
        XCTAssertEqual(again.debugKeyboard.debugRequestedHeight, shown, accuracy: 0.5)
        detach(again)
    }

    /// Zalo (log máy tester 22/11/2026): iOS tắt process bàn phím giữa hai lần hiện, process mới xin
    /// chiều cao chưa cấu hình (251) rồi mới lên 266 ⇒ ô nhập Zalo nằm thấp 15pt, bị che. Chiều cao
    /// lần hiện trước phải sống qua process mới (ở đây: xoá biến tĩnh, giữ defaults).
    @MainActor func testColdProcessRequestsStoredHeight() {
        let saved = UserDefaultsProvider.shared
        let savedPaywall = PlusGate.paywallEnabled
        let savedLast = KeyboardView.lastConfiguredHeight
        let savedStore = KeyboardView.primedDefaults
        let storeSuite = "vt-primed-height-tests"
        defer {
            UserDefaultsProvider.shared = saved
            PlusGate.paywallEnabled = savedPaywall
            KeyboardView.lastConfiguredHeight = savedLast
            KeyboardView.primedDefaults = savedStore
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
            UserDefaults(suiteName: storeSuite)?.removePersistentDomain(forName: storeSuite)
        }
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        d.set(true, forKey: "showSuggestions")
        PlusGate.paywallEnabled = false
        UserDefaultsProvider.shared = d
        let store = UserDefaults(suiteName: storeSuite)!
        store.removePersistentDomain(forName: storeSuite)
        KeyboardView.primedDefaults = store
        KeyboardView.lastConfiguredHeight = 0

        let w: CGFloat = 375, H: CGFloat = 812
        let win = UIWindow(frame: CGRect(x: 0, y: 0, width: w, height: H))
        let host = Host()
        win.rootViewController = host
        win.isHidden = false
        defer { win.isHidden = true }
        func attach() -> KeyboardViewController {
            let vc = KeyboardViewController()
            vc.debugProxy = KeyboardBenchTests.BenchProxy()
            vc.debugFullAccess = false
            vc.loadViewIfNeeded()
            host.addChild(vc); host.view.addSubview(vc.view); vc.didMove(toParent: host)
            vc.debugKeyboard.debugScreenSize = CGSize(width: w, height: H)
            vc.debugKeyboard.debugSetSafeBottom(0)
            return vc
        }
        func detach(_ vc: KeyboardViewController) {
            vc.beginAppearanceTransition(false, animated: false); vc.endAppearanceTransition()
            vc.willMove(toParent: nil); vc.view.removeFromSuperview(); vc.removeFromParent()
        }

        let first = attach()
        let unconfigured = first.debugKeyboard.debugRequestedHeight
        first.beginAppearanceTransition(true, animated: false); first.endAppearanceTransition()
        first.view.frame = CGRect(x: 0, y: 0, width: w, height: 300); first.view.layoutIfNeeded()
        let shown = first.debugKeyboard.debugRequestedHeight
        XCTAssertNotEqual(unconfigured, shown, "tiền đề: chưa cấu hình xin khác mức có thanh gợi ý")
        detach(first)

        KeyboardView.lastConfiguredHeight = 0   // process mới: biến tĩnh mất, defaults còn
        let cold = attach()
        cold.view.frame = CGRect(x: 0, y: 0, width: w, height: H)
        cold.view.setNeedsLayout(); cold.view.layoutIfNeeded()
        XCTAssertEqual(cold.debugKeyboard.debugRequestedHeight, shown, accuracy: 0.5,
                       "process mới, chưa cấu hình: xin đúng chiều cao lần hiện trước")
        detach(cold)

        store.removePersistentDomain(forName: storeSuite)   // chưa từng hiện: không có gì để mượn
        KeyboardView.lastConfiguredHeight = 0
        XCTAssertEqual(KeyboardView.storedPrimedHeight(screen: UIScreen.main.bounds.size), 0)
    }
}
