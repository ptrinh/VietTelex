// Ưu tiên phím ở mép chung (KeyHitBias, Phil 06/10/2026) — song sinh Android HitBiasTest.kt.
//  1. space thắng "," / "." kề trong dải 30% (gõ cuộn < 150 ms sau chữ: 40%) — từ 04/11/2026
//     (#145) CHỈ ngoài khung nhìn thấy của phím dấu (khe / vùng nở): trong khung luôn là phím dấu;
//  2. (BỎ 10/10/2026 — bug "bấm ⌫ thành m / l") phím chữ KHÔNG lấn ⇧ / ⌫ nữa: phím chức
//     năng có vùng chạm ổn định + khe cùng hàng (SpecialKeyGutter) — xem test cuối file;
//  3. Caps Lock tắt khi rời plane chữ (123 / emoji), về ABC vẫn đánh giá lại viết hoa đầu câu.
import XCTest
import UIKit

final class KeyHitBiasTests: XCTestCase {
    private typealias B = KeyHitBias

    // Hàng đáy iPhone 402pt: space 98…304, khe 6, "," 310…340 (30 rộng), cao 43.
    private let space = CGRect(x: 98, y: 162, width: 206, height: 43)
    private let comma = CGRect(x: 310, y: 162, width: 30, height: 43)

    func testBandTables() {
        XCTAssertEqual(B.spaceBand(sinceLetter: nil), 0.30)
        XCTAssertEqual(B.spaceBand(sinceLetter: 0.10), 0.40)
        XCTAssertEqual(B.spaceBand(sinceLetter: 0.15), 0.30)      // hết cửa sổ cuộn
        XCTAssertEqual(B.spaceBand(sinceLetter: -1), 0.30)
        // Dải luôn < nửa phím ⇒ tâm phím thua không bao giờ bị cướp.
        for b in [B.spaceBand, B.spaceBandRolling] { XCTAssertLessThan(b, 0.5) }
    }

    func testSpaceWinsNearCommaBoundary() {
        let y = comma.midY
        // (x, since, space thắng?)
        let table: [(CGFloat, TimeInterval?, Bool)] = [
            (307, nil, true),            // khe
            (310.5, nil, true),          // sát mép ","
            (318.9, nil, true),          // 29.7% bề rộng ","
            (319.1, nil, false),         // 30.3%
            (321, nil, false),
            (321, 0.10, true),           // gõ cuộn: dải 40% = 12pt
            (322.1, 0.10, false),
            (321, 0.30, false),          // gõ chậm
            (comma.midX, nil, false),    // tâm ","
            (comma.midX, 0.05, false),
            (comma.maxX - 1, 0.05, false),
        ]
        for (x, since, want) in table {
            let got = B.intrudes(CGPoint(x: x, y: y), loser: comma, winner: space,
                                 band: B.spaceBand(sinceLetter: since))
            XCTAssertEqual(got, want, "x=\(x) since=\(String(describing: since))")
        }
        // Đối xứng: "." BÊN TRÁI space (Android plane số [,][😊][space][.]) — chiều ngược.
        let dot = CGRect(x: 62, y: 162, width: 30, height: 43)
        XCTAssertTrue(B.intrudes(CGPoint(x: 85, y: y), loser: dot, winner: space, band: 0.3))
        XCTAssertFalse(B.intrudes(CGPoint(x: dot.midX, y: y), loser: dot, winner: space, band: 0.3))
        // Không kề (cách xa) ⇒ không bao giờ.
        let far = CGRect(x: 360, y: 162, width: 30, height: 43)
        XCTAssertFalse(B.intrudes(CGPoint(x: 361, y: y), loser: far, winner: space, band: 0.45))
    }

    /// #145 (Phil 04/11/2026, "bấm , toàn trượt sang space"): space KHÔNG lấy điểm nào trong
    /// khung nhìn thấy của "," / "." — kể cả sát mép space, kể cả gõ cuộn; khe + vùng nở ngoài
    /// khung (dưới phím) vẫn theo dải cũ.
    func testSpaceNeverClaimsInsidePunct() {
        let y = comma.midY
        let bands = [B.spaceBand(sinceLetter: nil), B.spaceBand(sinceLetter: 0.01), B.spaceBand(sinceLetter: 0.10)]
        for band in bands {
            for fx in stride(from: 0.0, through: 1.0, by: 0.05) {
                for fy in [0.0, 0.5, 1.0] {
                    let p = CGPoint(x: comma.minX + fx * comma.width, y: comma.minY + fy * comma.height)
                    XCTAssertFalse(B.spaceClaims(p, punct: comma, space: space, band: band), "\(p) band=\(band)")
                }
            }
            // Khe (ngoài khung) ⇒ space như trước.
            XCTAssertTrue(B.spaceClaims(CGPoint(x: 307, y: y), punct: comma, space: space, band: band))
            XCTAssertTrue(B.spaceClaims(CGPoint(x: 309.9, y: y), punct: comma, space: space, band: band))
            // Vùng nở dưới "," (ngoài khung), trong dải ⇒ space; ngoài dải ⇒ ",".
            XCTAssertTrue(B.spaceClaims(CGPoint(x: 312, y: comma.maxY + 2), punct: comma, space: space, band: band))
            XCTAssertFalse(B.spaceClaims(CGPoint(x: comma.midX, y: comma.maxY + 2), punct: comma, space: space, band: band))
        }
        // "." BÊN TRÁI space: mép phải "." (sát space) vẫn là ".".
        let dot = CGRect(x: 62, y: 162, width: 30, height: 43)
        XCTAssertFalse(B.spaceClaims(CGPoint(x: dot.maxX, y: y), punct: dot, space: space, band: 0.4))
        XCTAssertFalse(B.spaceClaims(CGPoint(x: 85, y: y), punct: dot, space: space, band: 0.4))
        XCTAssertTrue(B.spaceClaims(CGPoint(x: 95, y: y), punct: dot, space: space, band: 0.4))
        XCTAssertTrue(B.insidePunct(CGPoint(x: dot.maxX, y: dot.maxY), punct: dot))
        XCTAssertFalse(B.insidePunct(CGPoint(x: dot.maxX + 0.1, y: y), punct: dot))
    }

    // MARK: KeyboardView thật (iPhone 402pt) — đường hitTest / router

    @MainActor private func makeKeyboard(side: SpaceSideKey = .comma,
                                         onKey: @escaping (KeyboardView.Key) -> Void = { _ in })
        -> (KeyboardView, UIView) {
        let kb = KeyboardView(needsGlobe: false, inputController: nil, onKey: onKey)
        kb.spaceSideKey = side
        let host = UIView(frame: CGRect(x: 0, y: 0, width: 402, height: 212))
        host.addSubview(kb)
        kb.frame = host.bounds
        kb.configureInputKind(.normal)
        kb.layoutIfNeeded()
        host.frame.size.height = kb.debugRequestedHeight; kb.frame = host.bounds
        kb.layoutIfNeeded()
        return (kb, host)
    }

    private var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }

    @MainActor func testSpaceBarStealsCommaEdgeInKeyboard() throws {
        try XCTSkipIf(isPad)
        let (kb, host) = makeKeyboard()
        _ = host
        let space = try XCTUnwrap(kb.debugControl("Dấu cách"))
        let comma = try XCTUnwrap(kb.debugKeyButton(","))
        let cf = kb.convert(comma.bounds, from: comma), sf = kb.convert(space.bounds, from: space)
        // Hình phím: "," hẹp (0.071 W), space nhận phần dư; tâm space/"," vẫn là chính nó.
        XCTAssertEqual(cf.width, 402 * KeyLayout.phoneLettersComma, accuracy: 1)
        XCTAssertTrue(kb.hitTest(CGPoint(x: sf.midX, y: sf.midY), with: nil) === space)
        XCTAssertTrue(kb.hitTest(CGPoint(x: cf.midX, y: cf.midY), with: nil) === comma)
        XCTAssertTrue(kb.hitTest(CGPoint(x: cf.minX + 0.2 * cf.width, y: cf.midY), with: nil) === comma)
        XCTAssertTrue(kb.hitTest(CGPoint(x: cf.minX + 0.5, y: cf.midY), with: nil) === comma)
        XCTAssertTrue(kb.hitTest(CGPoint(x: cf.minX - 1, y: cf.midY), with: nil) === space, "khe")
        XCTAssertTrue(kb.hitTest(CGPoint(x: cf.minX + 0.4 * cf.width, y: cf.midY), with: nil) === comma)
    }

    /// "Cả hai": space thắng dải mép của CẢ "," (trái) lẫn "." (phải); tâm mỗi phím vẫn là nó.
    @MainActor func testSpaceBarStealsBothSideKeyEdges() throws {
        try XCTSkipIf(isPad)
        let (kb, host) = makeKeyboard(side: .both)
        _ = host
        let space = try XCTUnwrap(kb.debugControl("Dấu cách"))
        let comma = try XCTUnwrap(kb.debugKeyButton(","))
        let dot = try XCTUnwrap(kb.debugKeyButton("."))
        let cf = kb.convert(comma.bounds, from: comma), df = kb.convert(dot.bounds, from: dot)
        let sf = kb.convert(space.bounds, from: space)
        XCTAssertLessThan(cf.maxX, sf.minX); XCTAssertGreaterThan(df.minX, sf.maxX)
        XCTAssertEqual(cf.width, 402 * KeyLayout.phoneLettersComma, accuracy: 1)
        XCTAssertEqual(df.width, cf.width, accuracy: 0.5)
        XCTAssertTrue(kb.hitTest(CGPoint(x: cf.midX, y: cf.midY), with: nil) === comma)
        XCTAssertTrue(kb.hitTest(CGPoint(x: df.midX, y: df.midY), with: nil) === dot)
        // "," bên TRÁI space: mép PHẢI của "," vẫn là "," (#145); khe mới là space.
        XCTAssertTrue(kb.hitTest(CGPoint(x: cf.maxX - 0.2 * cf.width, y: cf.midY), with: nil) === comma)
        XCTAssertTrue(kb.hitTest(CGPoint(x: cf.maxX - 0.5, y: cf.midY), with: nil) === comma)
        XCTAssertTrue(kb.hitTest(CGPoint(x: cf.maxX + 1, y: cf.midY), with: nil) === space, "khe")
        XCTAssertTrue(kb.hitTest(CGPoint(x: cf.maxX - 0.4 * cf.width, y: cf.midY), with: nil) === comma)
        // "." bên PHẢI space: mép TRÁI của "." vẫn là "."; khe mới là space.
        XCTAssertTrue(kb.hitTest(CGPoint(x: df.minX + 0.2 * df.width, y: df.midY), with: nil) === dot)
        XCTAssertTrue(kb.hitTest(CGPoint(x: df.minX + 0.5, y: df.midY), with: nil) === dot)
        XCTAssertTrue(kb.hitTest(CGPoint(x: df.minX - 1, y: df.midY), with: nil) === space, "khe")
        XCTAssertTrue(kb.hitTest(CGPoint(x: df.minX + 0.4 * df.width, y: df.midY), with: nil) === dot)
    }

    /// #145 (Phil 04/11/2026): MỌI điểm trong khung nhìn thấy của phím dấu câu kề space (lưới
    /// 9×9 tới sát mép) ra đúng phím đó — gõ chậm lẫn gõ cuộn (10 / 100 ms sau một chữ) — ở mọi
    /// bố cục: ",", ".", Cả hai, ô email / URL, phím to, một tay, tách đôi, plane 123. Khe giữa
    /// phím dấu và space vẫn là space.
    @MainActor func testInsidePunctNeverSpaceAllLayouts() throws {
        try XCTSkipIf(isPad)
        struct Cfg { var side: SpaceSideKey; var kind: KeyboardView.InputKind = .normal
                     var large = false; var oneHand: OneHandSide = .off; var split = false; var numbers = false }
        var cfgs: [Cfg] = []
        for side in SpaceSideKey.allCases {
            for kind in [KeyboardView.InputKind.normal, .email, .url, .search] { cfgs.append(Cfg(side: side, kind: kind)) }
            cfgs.append(Cfg(side: side, large: true))
            cfgs.append(Cfg(side: side, numbers: true))
            cfgs.append(Cfg(side: side, split: true))
        }
        for oh in [OneHandSide.left, .right] { cfgs.append(Cfg(side: .both, oneHand: oh)) }
        cfgs.append(Cfg(side: .both, large: true, oneHand: .left))
        let puncts: Set<String> = [",", ".", "@", "/", ".com", "-", "_", ":"]
        let fr: [CGFloat] = [0, 0.01, 0.1, 0.3, 0.35, 0.4, 0.5, 0.9, 0.999]
        var checked = 0
        for c in cfgs {
            let width: CGFloat = c.split ? 801 : 402
            let kb = KeyboardView(needsGlobe: false, inputController: nil, onKey: { _ in })
            kb.spaceSideKey = c.side
            kb.largeKeys = c.large
            let host = UIView(frame: CGRect(x: 0, y: 0, width: width, height: 500))
            host.addSubview(kb)
            kb.frame = CGRect(x: 0, y: 0, width: width, height: 260)
            if c.split { kb.debugScreenSize = CGSize(width: 951, height: 669) }
            kb.configureInputKind(c.kind)
            kb.layoutIfNeeded()
            if c.split { kb.debugSetSplit(true) }
            if c.numbers { kb.debugSetPlane(numbers: true) }
            kb.configureOneHand(c.oneHand)
            kb.frame.size.height = kb.debugRequestedHeight
            kb.setNeedsLayout(); kb.layoutIfNeeded()
            let all = kb.debugAllKeyButtons().filter { !$0.isHidden }
            let spaces = all.filter { $0.accessibilityLabel == "Dấu cách" }.map { ($0, kb.convert($0.bounds, from: $0)) }
            let letter = kb.debugLetterFrame("a") ?? kb.debugLetterFrame("1")
            var t: TimeInterval = 1000
            for b in all {
                guard let title = b.currentTitle, puncts.contains(title) else { continue }
                let f = kb.convert(b.bounds, from: b)
                guard let (sp, sf) = spaces.first(where: { _, s in
                    min(s.maxY, f.maxY) - max(s.minY, f.minY) > 0.5 * min(s.height, f.height) &&
                        ((s.minX - f.maxX >= 0 && s.minX - f.maxX <= B.maxGap) || (f.minX - s.maxX >= 0 && f.minX - s.maxX <= B.maxGap))
                }) else { continue }
                let tag = "side=\(c.side) kind=\(c.kind) large=\(c.large) oneHand=\(c.oneHand) split=\(c.split) numbers=\(c.numbers) '\(title)'"
                for fx in fr { for fy in fr {
                    let p = CGPoint(x: f.minX + fx * f.width, y: f.minY + fy * f.height)
                    XCTAssertTrue(kb.hitTest(p, with: nil) === b, "\(tag) \(p) chậm")
                    for dt in [0.01, 0.10] {
                        if let l = letter { kb.benchTap(at: CGPoint(x: l.midX, y: l.midY), time: t) }
                        XCTAssertTrue(kb.debugHitTest(p, time: t + dt) === b, "\(tag) \(p) cuộn \(dt)")
                        t += 1
                    }
                } }
                // Khe giữa phím dấu và space ⇒ space.
                let gx = sf.minX >= f.maxX ? (f.maxX + sf.minX) / 2 : (sf.maxX + f.minX) / 2
                XCTAssertTrue(kb.hitTest(CGPoint(x: gx, y: f.midY), with: nil) === sp, "\(tag) khe")
                checked += 1
            }
            withExtendedLifetime(host) {}
        }
        XCTAssertGreaterThan(checked, 30)
    }

    // MARK: Caps Lock tắt khi đổi plane

    func testPolicyClearsShiftOnlyForSymbolAndEmojiPlanes() {
        XCTAssertTrue(PlanePolicy.clearsShiftLeavingLetters(to: .symbols))
        XCTAssertTrue(PlanePolicy.clearsShiftLeavingLetters(to: .emoji))
        XCTAssertTrue(PlanePolicy.clearsShiftLeavingLetters(to: .emojiSearch))
        XCTAssertFalse(PlanePolicy.clearsShiftLeavingLetters(to: .templates))
        XCTAssertFalse(PlanePolicy.clearsShiftLeavingLetters(to: .letters))
    }

    @MainActor private func capsLock(_ kb: KeyboardView) throws {
        let shift = try XCTUnwrap(kb.debugControl("Shift"))
        kb.setAutoShift(false)
        shift.sendActions(for: .touchDown)
        try XCTUnwrap(kb.debugControl("Shift")).sendActions(for: .touchDown)   // chạm đôi
        XCTAssertTrue(kb.debugShiftCaps)
    }

    @MainActor func testShiftTouchedByHandFlag() throws {
        let (kb, host) = makeKeyboard()
        _ = host
        kb.setAutoShift(false)
        XCTAssertFalse(kb.shiftTouchedByHand)
        try XCTUnwrap(kb.debugControl("Shift")).sendActions(for: .touchDown)
        XCTAssertTrue(kb.shiftTouchedByHand, "chạm ⇧ ⇒ controller biết để không đè bằng tiếng vọng host")
        kb.setAutoShift(false)                                        // quyết định mới của chính phím mình
        XCTAssertFalse(kb.shiftTouchedByHand)
        XCTAssertFalse(kb.debugShiftOn)
    }

    @MainActor func testCapsLockOffAfter123RoundTrip() throws {
        let (kb, host) = makeKeyboard()
        _ = host
        try capsLock(kb)
        kb.autoShiftProbe = { false }                                 // giữa câu
        try XCTUnwrap(kb.debugControl("Số")).sendActions(for: .touchDown)
        XCTAssertEqual(kb.debugPlaneName, "numbers")
        XCTAssertFalse(kb.debugShiftOn)
        try XCTUnwrap(kb.debugControl("Chữ")).sendActions(for: .touchDown)
        XCTAssertEqual(kb.debugPlaneName, "letters")
        XCTAssertFalse(kb.debugShiftCaps, "Caps Lock phải tắt sau 123 → ABC")
        XCTAssertFalse(kb.debugShiftOn)
    }

    @MainActor func testCapsLockRoundTripStillAutoCapitalizes() throws {
        let (kb, host) = makeKeyboard()
        _ = host
        try capsLock(kb)
        kb.autoShiftProbe = { true }                                  // đầu câu
        try XCTUnwrap(kb.debugControl("Số")).sendActions(for: .touchDown)
        try XCTUnwrap(kb.debugControl("Chữ")).sendActions(for: .touchDown)
        XCTAssertFalse(kb.debugShiftCaps)
        XCTAssertTrue(kb.debugShiftOn, "về ABC đầu câu: shift một-lần")
    }

    @MainActor func testOneShotShiftClearedByEmojiAndReevaluatedOnABC() throws {
        let (kb, host) = makeKeyboard()
        _ = host
        kb.setAutoShift(true)
        XCTAssertTrue(kb.debugShiftOn)
        kb.debugShowEmojiPlane()
        XCTAssertFalse(kb.debugShiftOn)
        kb.autoShiftProbe = { true }
        kb.debugEmojiABC()
        XCTAssertEqual(kb.debugPlaneName, "letters")
        XCTAssertTrue(kb.debugShiftOn)
    }

    // MARK: ⌫ / ⇧ vùng chạm ổn định (bug tester 1.2.6/1.2.7: "bấm ⌫ hay thành chữ m hoặc l")
    // Gốc: KeyHitBias 06/10 cho phím chữ lấn 20 % (gõ nhanh < 200 ms: 35 %) mép trái ⌫ (→ m)
    // và ĐỈNH ⌫ dưới l (→ l), cộng trọn khe giữa hai hàng; khe m↔⌫ (12pt) router chữ ăn nửa.

    /// Hàm thuần — hình học iPhone 402: ⌫ 353…395.5, m 308…341 (hàng 3), l 347.9…381.2 (hàng 2,
    /// đáy 98); ⇧ 6.5…49, z 61…94.
    func testSpecialKeyGutterPure() {
        let back = CGRect(x: 353, y: 108, width: 42.5, height: 43)
        let shift = CGRect(x: 6.5, y: 108, width: 42.5, height: 43)
        let m = CGRect(x: 308, y: 108, width: 33.3, height: 43)
        let z = CGRect(x: 61, y: 108, width: 33.3, height: 43)
        let l = CGRect(x: 347.9, y: 54, width: 33.3, height: 44)
        let a = CGRect(x: 26.3, y: 54, width: 33.3, height: 44)
        let letters = [a, l, z, m]
        let specials = [shift, back]
        let y = back.midY
        // (điểm, chủ mong đợi: 0 = ⇧, 1 = ⌫, nil = để router chữ quyết)
        let table: [(CGPoint, Int?)] = [
            (CGPoint(x: back.midX, y: y), 1),
            (CGPoint(x: 353.5, y: y), 1),               // mép trái ⌫ (cũ: m)
            (CGPoint(x: 360, y: y), 1),                 // 16 % (cũ: m khi gõ nhanh)
            (CGPoint(x: 365, y: 108.5), 1),             // đỉnh ⌫ ngay dưới l (cũ: l)
            (CGPoint(x: 370, y: 120), 1),               // 28 % chiều cao (cũ: l khi gõ nhanh)
            (CGPoint(x: 395, y: 150.5), 1),             // góc dưới phải
            (CGPoint(x: 347, y: y), 1),                 // khe m↔⌫ giữa
            (CGPoint(x: 344.5, y: y), 1),               // khe, 3.5pt từ m
            (CGPoint(x: 343.5, y: y), nil),             // ≤ 3pt sát m ⇒ của m
            (CGPoint(x: 400, y: y), 1),                 // mép màn hình bên phải ⌫
            (CGPoint(x: m.midX, y: y), nil),            // lõi m
            (CGPoint(x: 341, y: y), nil),               // mép phải m (trong hình m)
            (CGPoint(x: 365, y: 100), nil),             // khe giữa hai hàng, nửa trên ⇒ router (l)
            (CGPoint(x: 365, y: 103), 1),               // khe giữa hai hàng, ≤ 5.5pt trên ⌫
            (CGPoint(x: 20, y: shift.midY), 0),
            (CGPoint(x: 48.5, y: shift.midY), 0),       // mép phải ⇧ (cũ: z)
            (CGPoint(x: 40, y: 108.5), 0),              // đỉnh ⇧ dưới a (cũ: a)
            (CGPoint(x: 55, y: shift.midY), 0),         // khe ⇧↔z
            (CGPoint(x: 58.5, y: shift.midY), nil),     // ≤ 3pt sát z
            (CGPoint(x: 2, y: shift.midY), 0),          // mép màn hình trái
        ]
        for (p, want) in table {
            XCTAssertEqual(SpecialKeyGutter.owner(p, specials: specials, letters: letters), want, "p=\(p)")
        }
        // Khe xa hơn maxGap ⇒ không thuộc.
        XCTAssertNil(SpecialKeyGutter.owner(CGPoint(x: back.maxX + 17, y: y), specials: [back], letters: []))
    }

    /// Một cấu hình bàn phím thật: bề ngang view, màn hình giả, safe area đáy, tách đôi.
    private struct Form {
        let name: String; let width: CGFloat; let screen: CGSize
        var safe: CGFloat = 0; var split = false
    }
    private var forms: [Form] { [
        Form(name: "SE 375", width: 375, screen: CGSize(width: 375, height: 667)),
        Form(name: "390", width: 390, screen: CGSize(width: 390, height: 844)),
        Form(name: "393", width: 393, screen: CGSize(width: 393, height: 852)),
        Form(name: "402", width: 402, screen: CGSize(width: 402, height: 874)),
        Form(name: "430", width: 430, screen: CGSize(width: 430, height: 932)),
        Form(name: "440", width: 440, screen: CGSize(width: 440, height: 956)),
        Form(name: "ngang 667", width: 667, screen: CGSize(width: 667, height: 375)),
        Form(name: "ngang 750", width: 750, screen: CGSize(width: 852, height: 393)),
        Form(name: "ngang 874", width: 874, screen: CGSize(width: 874, height: 402)),
        Form(name: "Duo gập", width: 466, screen: CGSize(width: 466, height: 678)),
        Form(name: "Duo gập ngang", width: 528, screen: CGSize(width: 678, height: 466), safe: 18),
        Form(name: "Duo mở", width: 801, screen: CGSize(width: 951, height: 669), safe: 18),
        Form(name: "Duo mở dọc", width: 669, screen: CGSize(width: 669, height: 951), safe: 18),
        Form(name: "Duo mở tách đôi", width: 801, screen: CGSize(width: 951, height: 669), safe: 18, split: true),
    ] }

    @MainActor private func makeKeyboard(_ f: Form, onKey: @escaping (KeyboardView.Key) -> Void)
        -> (KeyboardView, UIView) {
        let kb = KeyboardView(needsGlobe: false, inputController: nil, onKey: onKey)
        let host = UIView(frame: CGRect(x: 0, y: 0, width: f.width, height: 500))
        host.addSubview(kb)
        kb.frame = CGRect(x: 0, y: 0, width: f.width, height: 300)
        kb.debugScreenSize = f.screen
        kb.configureInputKind(.normal)
        kb.setSuggestionsEnabled(true)
        kb.debugSetSafeBottom(f.safe)
        if f.split { kb.debugSetSplit(true) }
        kb.layoutIfNeeded()
        kb.frame.size.height = kb.debugRequestedHeight
        kb.setNeedsLayout(); kb.layoutIfNeeded()
        return (kb, host)
    }

    private func grid(_ r: CGRect) -> [CGPoint] {
        let fr: [CGFloat] = [0.01, 0.1, 0.2, 0.34, 0.5, 0.8, 0.99]
        return fr.flatMap { fx in fr.map { fy in CGPoint(x: r.minX + fx * r.width, y: r.minY + fy * r.height) } }
    }

    /// Mọi điểm trong hình ⌫ / ⇧ (lưới 7×7 kể cả sát mép) và khe cùng hàng cạnh nó ra ĐÚNG
    /// phím chức năng — gõ chậm lẫn gõ cuộn (chạm 50 ms sau m / l / z / a), ở mọi bề ngang
    /// iPhone dọc / ngang / máy gập / tách đôi. Lõi m / l / z / a (và 2pt ngoài mép) vẫn ra chữ.
    @MainActor func testBackspaceAndShiftNeverStolenByLetters() throws {
        try XCTSkipIf(isPad)
        for f in forms {
            var typed: [Character] = []
            let (kb, host) = makeKeyboard(f) { if case .letter(let c) = $0 { typed.append(Character(c.lowercased())) } }
            _ = host
            let back = try XCTUnwrap(kb.debugControl("Xoá"), f.name)
            let shift = try XCTUnwrap(kb.debugControl("Shift"), f.name)
            let bf = kb.convert(back.bounds, from: back), sf = kb.convert(shift.bounds, from: shift)
            let mf = try XCTUnwrap(kb.debugLetterFrames("m").last, f.name)
            let zf = try XCTUnwrap(kb.debugLetterFrames("z").first, f.name)
            XCTAssertLessThan(mf.maxX, bf.minX, f.name)
            XCTAssertGreaterThan(zf.minX, sf.maxX, f.name)
            // Khe cùng hàng: m.maxX + 3.5 … ⌫, z − 3.5 … ⇧; mép màn hình.
            var backPts = grid(bf), shiftPts = grid(sf)
            var x = mf.maxX + 3.5
            while x < bf.minX { backPts.append(CGPoint(x: x, y: bf.midY)); x += 1 }
            if bf.maxX + 1 < kb.bounds.width {
                backPts.append(CGPoint(x: min(bf.maxX + 4, kb.bounds.width - 0.5), y: bf.midY))
            }
            x = zf.minX - 3.5
            while x > sf.maxX { shiftPts.append(CGPoint(x: x, y: sf.midY)); x -= 1 }
            // Khe trên ⌫ / ⇧: phần sát phím (≤ 5pt) vẫn là phím chức năng như trước 1.2.6.
            backPts.append(CGPoint(x: bf.midX, y: bf.minY - 4.5))
            shiftPts.append(CGPoint(x: sf.midX, y: sf.minY - 4.5))
            var t: TimeInterval = 100
            for prev in ["m", "l", "z", "a", nil] as [String?] {
                if let prev, let pf = kb.debugLetterFrames(prev).first {
                    kb.debugTouch(from: CGPoint(x: pf.midX, y: pf.midY), through: [], start: t)
                }
                t += 0.05                                          // gõ cuộn: 50 ms sau chữ
                for p in backPts {
                    XCTAssertTrue(kb.debugHitTest(p, time: t) === back,
                                  "\(f.name): ⌫ bị cướp tại \(p) sau \(prev ?? "-") → \(kb.debugHitTest(p, time: t).map { ($0 as? UIControl)?.accessibilityLabel ?? String(describing: type(of: $0)) } ?? "nil")")
                }
                for p in shiftPts {
                    XCTAssertTrue(kb.debugHitTest(p, time: t) === shift,
                                  "\(f.name): ⇧ bị cướp tại \(p) sau \(prev ?? "-") → \(kb.debugHitTest(p, time: t).map { ($0 as? UIControl)?.accessibilityLabel ?? String(describing: type(of: $0)) } ?? "nil")")
                }
                XCTAssertTrue(kb.hitTest(CGPoint(x: bf.minX + 1, y: bf.minY + 1), with: nil) === back, f.name)
                t += 1
            }
            // Phím chữ kề vẫn là của chúng: lõi, và 2pt ngoài mép phía phím chức năng.
            typed.removeAll()
            for s in ["m", "l", "z", "a"] {
                let lf = try XCTUnwrap(kb.debugLetterFrames(s).last, f.name)
                let p = CGPoint(x: lf.midX, y: lf.midY)
                XCTAssertTrue(kb.debugHitTest(p, time: t) === kb, "\(f.name): lõi \(s)")
                kb.debugTouch(from: p, through: [], start: t); t += 1
            }
            let nearM = CGPoint(x: mf.maxX + 2, y: mf.midY), nearZ = CGPoint(x: zf.minX - 2, y: zf.midY)
            XCTAssertTrue(kb.debugHitTest(nearM, time: t) === kb, "\(f.name): 2pt phải m")
            kb.debugTouch(from: nearM, through: [], start: t); t += 1
            XCTAssertTrue(kb.debugHitTest(nearZ, time: t) === kb, "\(f.name): 2pt trái z")
            kb.debugTouch(from: nearZ, through: [], start: t); t += 1
            XCTAssertEqual(String(typed), "mlzamz", f.name)
        }
    }

    /// Lăn ngón: chạm m, chưa nhấc đã chạm ⌫ ⇒ m chèn trước, ⌫ xoá sau (đúng thứ tự), nhấc
    /// ngón m không phát lại m. (Phím chữ chèn lúc chạm; ⌫ chốt phím đang đè trước khi xoá.)
    @MainActor func testRolloverLetterThenBackspaceOrder() throws {
        try XCTSkipIf(isPad)
        var keys: [String] = []
        let (kb, host) = makeKeyboard(forms[3]) { k in
            switch k {
            case .letter(let c): keys.append(String(c).lowercased())
            case .backspace: keys.append("⌫")
            default: break
            }
        }
        _ = host
        let back = try XCTUnwrap(kb.debugControl("Xoá"))
        let mf = try XCTUnwrap(kb.debugLetterFrame("m"))
        let bf = kb.convert(back.bounds, from: back)
        let token = NSObject()
        let id = ObjectIdentifier(token)
        kb.debugRouteDown(id, at: CGPoint(x: mf.midX, y: mf.midY), time: 10)
        XCTAssertTrue(kb.debugHitTest(CGPoint(x: bf.minX + 2, y: bf.minY + 2), time: 10.04) === back)
        back.sendActions(for: .touchDown)                  // flush phím đang đè (baseButton)
        kb.debugBackspaceSwipe(from: bf.midX, through: []) // ⌫ xoá (backspaceDown → tapped)
        kb.debugRouteUp(id, at: CGPoint(x: mf.midX + 6, y: mf.midY), time: 10.08)   // nhấc m (trôi 6pt)
        withExtendedLifetime(token) {}
        XCTAssertEqual(keys, ["m", "⌫"])
    }

    /// "Phím cạnh dấu cách" = Dấu chấm: "." như "," — trong khung luôn là "." (#145), khe là
    /// space; Tắt: không phím để lấn.
    @MainActor func testSpaceBarStealsPeriodSideKeyEdge() throws {
        try XCTSkipIf(isPad)
        let (kb, host) = makeKeyboard(side: .period)
        _ = host
        let space = try XCTUnwrap(kb.debugControl("Dấu cách"))
        let dot = try XCTUnwrap(kb.debugKeyButton("."))
        let df = kb.convert(dot.bounds, from: dot)
        XCTAssertEqual(df.width, 402 * KeyLayout.phoneLettersComma, accuracy: 1)
        XCTAssertTrue(kb.hitTest(CGPoint(x: df.midX, y: df.midY), with: nil) === dot)
        XCTAssertTrue(kb.hitTest(CGPoint(x: df.minX + 0.2 * df.width, y: df.midY), with: nil) === dot)
        XCTAssertTrue(kb.hitTest(CGPoint(x: df.minX - 1, y: df.midY), with: nil) === space, "khe")
        XCTAssertTrue(kb.hitTest(CGPoint(x: df.minX + 0.4 * df.width, y: df.midY), with: nil) === dot)
        let (kbO, hostO) = makeKeyboard(side: .off)
        XCTAssertNil(kbO.debugKeyButton("."))
        XCTAssertNil(kbO.debugKeyButton(","))
        let sp = try XCTUnwrap(kbO.debugControl("Dấu cách"))
        let sf = kbO.convert(sp.bounds, from: sp)
        XCTAssertTrue(kbO.hitTest(CGPoint(x: sf.maxX - 1, y: sf.midY), with: nil) === sp)
        withExtendedLifetime(hostO) {}
    }
}
