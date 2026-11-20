// Gõ vuốt giai đoạn 1 — tích hợp: bộ phân loại chạm/vuốt (thuần), chèn từ vuốt qua
// EngineBridge (dấu cách treo, huỷ chữ đầu, ⌫ đầu xoá cả từ, phím dấu sửa từ, dấu câu
// dính sát) và luồng đầy đủ qua router KeyboardView (debugTouch).
import XCTest
import UIKit

final class GestureClassifierTests: XCTestCase {
    private let kw: CGFloat = 39
    /// Phím 39×42 quanh (100, 100).
    private let key = CGRect(x: 80.5, y: 79, width: 39, height: 42)

    private func run(from s: CGPoint, to pts: [CGPoint], dt: TimeInterval = 0.016,
                     since: TimeInterval? = nil, second: Bool = false) -> GestureClassifier.Decision {
        var c = GestureClassifier(start: s, time: 10, startKey: key, keyWidth: kw, sinceLastLetter: since)
        if second { c.secondTouch() }
        var t: TimeInterval = 10
        for p in pts { t += dt; c.move(to: p, time: t) }
        return c.decision
    }

    func testQuickTapWithSlideIsNotSwipe() {
        let s = CGPoint(x: 100, y: 100)
        for d in stride(from: 5, through: 15, by: 5) {
            let pts = (1...4).map { CGPoint(x: 100 + CGFloat($0) * CGFloat(d) / 4, y: 100) }
            XCTAssertNotEqual(run(from: s, to: pts), .swipe, "trượt \(d)pt")
        }
        // chạm sát mép phím rồi trượt 15pt ra ngoài phím — vẫn là chạm
        let edge = CGPoint(x: 115, y: 100)
        XCTAssertNotEqual(run(from: edge, to: [CGPoint(x: 122, y: 100), CGPoint(x: 130, y: 100)]), .swipe)
    }

    func testSecondFingerLocksTap() {
        let pts = (1...10).map { CGPoint(x: 100 + CGFloat($0) * 12, y: 100) }
        XCTAssertEqual(run(from: CGPoint(x: 100, y: 100), to: pts), .swipe)
        XCTAssertEqual(run(from: CGPoint(x: 100, y: 100), to: pts, second: true), .tap)
    }

    func testTwoKeySlideRightAfterTapIsNotSwipe() {
        // 2 phím (78pt) trong ~100ms, phím chữ trước chạm 100ms trước ⇒ không vuốt
        let pts = (1...6).map { CGPoint(x: 100 + CGFloat($0) * 13, y: 100) }
        XCTAssertNotEqual(run(from: CGPoint(x: 100, y: 100), to: pts, since: 0.1), .swipe)
        // cùng cử chỉ, không có phím vừa gõ ⇒ vuốt
        XCTAssertEqual(run(from: CGPoint(x: 100, y: 100), to: pts), .swipe)
        // cả hai ngưỡng ×3 ngay sau phím trước, giảm tuyến tính về ×1 ở 350ms
        XCTAssertEqual(GestureClassifier.recentMultiplier(sinceLastLetter: 0), 3, accuracy: 1e-6)
        XCTAssertGreaterThan(GestureClassifier.recentMultiplier(sinceLastLetter: 0.1),
                             GestureClassifier.recentMultiplier(sinceLastLetter: 0.3))
        XCTAssertEqual(GestureClassifier.recentMultiplier(sinceLastLetter: 0.4), 1, accuracy: 1e-6)
        let c = GestureClassifier(start: .zero, time: 0, startKey: key, keyWidth: kw, sinceLastLetter: 0)
        XCTAssertEqual(c.distanceThreshold, 3 * kw, accuracy: 1e-6)
        XCTAssertEqual(c.speedThreshold, 0.3, accuracy: 1e-6)
    }

    func testRealSwipeAndSlowHold() {
        let fast = (1...8).map { CGPoint(x: 100 + CGFloat($0) * 8, y: 100 + CGFloat($0) * 3) }
        XCTAssertEqual(run(from: CGPoint(x: 100, y: 100), to: fast), .swipe)
        // giữ lâu rồi mới kéo (quá 500ms) ⇒ khoá chạm
        var slow = [CGPoint](repeating: CGPoint(x: 101, y: 100), count: 40)
        slow += (1...8).map { CGPoint(x: 100 + CGFloat($0) * 10, y: 100) }
        XCTAssertEqual(run(from: CGPoint(x: 100, y: 100), to: slow), .tap)
    }

    func testPolicyAndSpacing() {
        let normal = FieldTraits()
        XCTAssertTrue(SwipePolicy.enabled(setting: true, isPad: false, traits: normal, voiceOver: false))
        XCTAssertFalse(SwipePolicy.enabled(setting: false, isPad: false, traits: normal, voiceOver: false))
        XCTAssertFalse(SwipePolicy.enabled(setting: true, isPad: true, traits: normal, voiceOver: false))
        XCTAssertFalse(SwipePolicy.enabled(setting: true, isPad: false, traits: normal, voiceOver: true))
        XCTAssertFalse(SwipePolicy.enabled(setting: true, isPad: false, traits: nil, voiceOver: false))
        var email = FieldTraits(); email.keyboardType = .emailAddress
        var url = FieldTraits(); url.keyboardType = .URL
        var secure = FieldTraits(); secure.secure = true
        var pass = FieldTraits(); pass.contentType = .password
        for t in [email, url, secure, pass] {
            XCTAssertFalse(SwipePolicy.enabled(setting: true, isPad: false, traits: t, voiceOver: false))
        }
        XCTAssertFalse(SwipeSpacing.needsLeadingSpace(before: nil))
        XCTAssertFalse(SwipeSpacing.needsLeadingSpace(before: ""))
        XCTAssertFalse(SwipeSpacing.needsLeadingSpace(before: "xin "))
        XCTAssertFalse(SwipeSpacing.needsLeadingSpace(before: "xin\n"))
        XCTAssertFalse(SwipeSpacing.needsLeadingSpace(before: "("))
        XCTAssertFalse(SwipeSpacing.needsLeadingSpace(before: "a/"))
        XCTAssertTrue(SwipeSpacing.needsLeadingSpace(before: "(xin)"))
        XCTAssertTrue(SwipeSpacing.needsLeadingSpace(before: "số 5"))
        XCTAssertTrue(SwipeSpacing.needsLeadingSpace(before: "xin"))
        XCTAssertTrue(SwipeSpacing.needsLeadingSpace(before: "chào,"))
        XCTAssertEqual(SwipeCase.capitalized.apply("việt"), "Việt")
        XCTAssertEqual(SwipeCase.upper.apply("việt"), "VIỆT")
    }
}

final class SwipeTypingTests: XCTestCase {
    private let layout = SwipeLayout.qwerty(keyWidth: 39, rowHeight: 54)

    /// Đường vuốt sạch qua tâm phím, mỗi ~8pt một điểm.
    private func path(_ word: String) -> SwipePath {
        var p = SwipePath(minDistance: layout.keyWidth / 5)
        let keys = Array(SwipeSim.collapse(word)).map { layout.center(of: $0)! }
        var t = 0.0
        p.add(x: keys[0].x, y: keys[0].y, t: t)
        for i in 1..<keys.count {
            let a = keys[i - 1], b = keys[i]
            let n = max(2, Int(hypot(b.x - a.x, b.y - a.y) / 8))
            for j in 1...n {
                let u = Float(j) / Float(n)
                t += 0.016
                p.add(x: a.x + (b.x - a.x) * u, y: a.y + (b.y - a.y) * u, t: t)
            }
        }
        return p
    }

    private func typed(_ keys: String, _ b: EngineBridge, _ p: MockProxy) {
        for ch in keys {
            if ch == " " { b.boundary(" ", proxy: p) } else { b.letter(ch, proxy: p) }
        }
    }

    private func make() -> (SwipeTyping, EngineBridge, MockProxy) {
        let s = SwipeTyping()
        s.setLayout(layout, prepare: false)
        return (s, EngineBridge(settings: KeyboardSettings()), MockProxy())
    }

    /// Mô phỏng một cú vuốt: chữ đầu hoãn (không chèn lúc chạm, #172), nhấc tay ⇒ chèn từ.
    @discardableResult
    private func swipe(_ word: String, _ s: SwipeTyping, _ b: EngineBridge, _ p: MockProxy,
                       context: [String] = [], case sc: SwipeCase = .lower) -> SwipeTyping.Outcome? {
        return s.finish(path(word), case: sc, contextWords: context, bridge: b, proxy: p)
    }

    func testDecodesCleanPaths() {
        let (s, _, _) = make()
        for w in ["viet", "nam", "chao", "khong", "nguoi"] {
            XCTAssertEqual(s.resolve(path(w), contextWords: [], case: .lower)
                .map { SwipeTyping.fold($0.word) }, w)
        }
        // không ngữ cảnh: tần suất lexicon ⇒ "viết" trước, "việt" nằm ở thanh gợi ý
        let plain = s.resolve(path("viet"), contextWords: [], case: .lower)
        XCTAssertEqual(plain?.word, "viết")
        XCTAssertTrue(plain?.alternatives.contains("việt") == true, "\(plain?.alternatives ?? [])")
        // ngữ cảnh chọn dấu: sau "tiếng" (nextWords có "việt") là "việt"
        XCTAssertEqual(s.resolve(path("viet"), contextWords: ["việt", "anh"], case: .lower)?.word, "việt")
        // từ hay gõ cũng kéo được dấu (count cá nhân, trần 1.5)
        XCTAssertEqual(s.resolve(path("viet"), contextWords: [], count: { $0 == "việt" ? 200 : 0 },
                                 case: .lower)?.word, "việt")
        XCTAssertEqual(SwipeTyping.contextScore("x", next: [], count: { _ in 100_000 }), 1.5, accuracy: 1e-6)
        XCTAssertEqual(SwipeTyping.fold("Đường"), "duong")
    }

    func testSwipeInSentenceSpacingAndFirstLetterUndone() {
        let (s, b, p) = make()
        typed("Tooi hocj tieengs", b, p)                 // "tiếng" đang gõ dở
        let out = swipe("viet", s, b, p, context: ["việt"])
        XCTAssertEqual(p.text, "Tôi học tiếng việt")
        XCTAssertEqual(out?.committed?.word, "tiếng")      // từ trước được chốt để học
        XCTAssertTrue(b.isSwipeWordOpen)
        XCTAssertEqual(b.composedWord, "việt")

        // cú vuốt kế: chữ đầu (n) chạm xuống ⇒ dấu cách treo tạm, huỷ sạch, rồi chèn
        let out2 = swipe("nam", s, b, p, context: ["nam"])
        XCTAssertEqual(p.text, "Tôi học tiếng việt nam")
        XCTAssertEqual(out2?.committed?.word, "việt")
        XCTAssertNil(b.takeSettledCommit(), "không được học 'việt' hai lần")
    }

    // MARK: dấu cách treo trước số / ký hiệu sau từ vuốt (bug "mua2")

    func testSymbolSpaceRule() {
        XCTAssertTrue(SwipeSpacing.spaceBefore("2", afterSwipe: true, before: "mua"))
        XCTAssertTrue(SwipeSpacing.spaceBefore("2", afterSwipe: true, before: nil))
        XCTAssertFalse(SwipeSpacing.spaceBefore("2", afterSwipe: false, before: "mua"))
        XCTAssertFalse(SwipeSpacing.spaceBefore("2", afterSwipe: true, before: "mua "))
        for p in [".", ",", "!", "?", ")", "\"", "'", "-", "%", "/", "@", "\u{201D}", "²"] {
            XCTAssertFalse(SwipeSpacing.spaceBefore(p, afterSwipe: true, before: "mua"), p)
        }
        for o in ["(", "[", "\u{201C}", "$", "€", "😀", "❤️", "👍🏽"] {
            XCTAssertTrue(SwipeSpacing.spaceBefore(o, afterSwipe: true, before: "mua"), o)
        }
        XCTAssertFalse(SwipeSpacing.spaceBefore("", afterSwipe: true, before: "mua"))
    }

    func testDigitAfterSwipeGetsSpace() {
        let (s, b, p) = make()
        swipe("viet", s, b, p)
        XCTAssertEqual(p.text, "viết")
        b.symbolBoundary("2", proxy: p)
        XCTAssertEqual(p.text, "viết 2")
        b.symbolBoundary("0", proxy: p)
        XCTAssertEqual(p.text, "viết 20")                 // số kế: không thêm nữa
        b.backspace(proxy: p); b.backspace(proxy: p)
        XCTAssertEqual(p.text, "viết ")                    // ⌫ xoá số trước…
        b.backspace(proxy: p)
        XCTAssertEqual(p.text, "viết")                     // …rồi dấu cách treo
    }

    func testPunctuationAfterSwipeStaysGluedOpenerSpaced() {
        for (sym, expect) in [(".", "viết."), (",", "viết,"), ("(", "viết ("), ("😀", "viết 😀")] {
            let (s, b, p) = make()
            swipe("viet", s, b, p)
            b.symbolBoundary(sym, proxy: p)
            XCTAssertEqual(p.text, expect)
        }
    }

    func testDigitAfterTypedWordOrSpaceUnchanged() {
        let (_, b, p) = make()
        typed("mua", b, p)
        b.symbolBoundary("2", proxy: p)
        XCTAssertEqual(p.text, "mua2")                     // từ gõ tay: không đổi
        let (s2, b2, p2) = make()
        swipe("viet", s2, b2, p2)
        b2.boundary(" ", proxy: p2)
        b2.symbolBoundary("2", proxy: p2)
        XCTAssertEqual(p2.text, "viết 2")                  // đã có dấu cách: không thành 2
    }

    func testHeldDigitAfterSwipeGetsSpace() {
        let (s, b, p) = make()
        swipe("viet", s, b, p)
        b.letter("q", proxy: p)                            // chạm phím chữ…
        XCTAssertTrue(b.undoLastLetter(proxy: p))          // …giữ ra số: gỡ phím chữ
        b.symbolBoundary("2", proxy: p)
        XCTAssertEqual(p.text, "viết 2")
    }

    func testTelexFirstLetterUndoneCleanly() {
        for (prefix, first, word, expect) in [
            ("tieng", "s", "sao", "tieng sao"),        // s = dấu sắc lên "tiếng"
            ("di", "d", "dung", "di "),                 // d = đ ("đi")
            ("tu", "w", "wifi", "tu "),                 // w = móc ("tư")
        ] {
            let (s, b, p) = make()
            typed(prefix, b, p)
            b.letter(Character(first), proxy: p)
            XCTAssertNotEqual(p.text, prefix + first, "\(first) phải biến đổi từ trước")
            XCTAssertTrue(b.undoLastLetter(proxy: p))
            XCTAssertEqual(p.text, prefix, "chữ đầu \(first) chưa huỷ sạch")
            if word == "sao" {
                _ = s.finish(path(word), case: .lower, contextWords: [], bridge: b, proxy: p)
                XCTAssertEqual(SwipeTyping.fold(p.text), expect)
                XCTAssertTrue(p.text.hasPrefix("tieng "), p.text)
            }
        }
        // chữ đầu là phím dấu sửa TỪ VUỐT đang mở — huỷ trả lại từ vuốt còn mở
        let (s, b, p) = make()
        swipe("viet", s, b, p, context: ["việt"])
        b.letter("s", proxy: p)
        XCTAssertEqual(p.text, "viết")
        XCTAssertTrue(b.undoLastLetter(proxy: p))
        XCTAssertEqual(p.text, "việt")
        XCTAssertTrue(b.isSwipeWordOpen)
    }

    func testFirstBackspaceDeletesWholeWord() {
        let (s, b, p) = make()
        typed("xin ", b, p)
        swipe("chao", s, b, p)
        XCTAssertEqual(SwipeTyping.fold(p.text), "xin chao")
        b.backspace(proxy: p)
        XCTAssertEqual(p.text, "xin ")
        b.backspace(proxy: p)
        XCTAssertEqual(p.text, "xin")                     // ⌫ sau như thường
        XCTAssertFalse(b.isSwipeWordOpen)
    }

    func testToneKeyAfterSwipeChangesTone() {
        let (s, b, p) = make()
        typed("tieengs ", b, p)
        swipe("viet", s, b, p, context: ["việt"])
        XCTAssertEqual(p.text, "tiếng việt")
        b.letter("s", proxy: p)
        XCTAssertEqual(p.text, "tiếng viết")
        b.backspace(proxy: p)                              // đã sửa ⇒ ⌫ thường (engine)
        XCTAssertNotEqual(p.text, "tiếng ")
        b.letter("j", proxy: p)
        b.boundary(" ", proxy: p)
        XCTAssertTrue(p.text.hasSuffix(" "))
    }

    func testPunctuationSticksAndNextSwipeSpaces() {
        let (s, b, p) = make()
        swipe("viet", s, b, p, context: ["việt"], case: .capitalized)
        XCTAssertEqual(p.text, "Việt")                      // đầu ô: không dấu cách
        let committed = b.boundary(",", proxy: p)
        XCTAssertEqual(committed, "Việt")
        XCTAssertEqual(p.text, "Việt,")
        swipe("nam", s, b, p, context: ["nam"])
        XCTAssertEqual(p.text, "Việt, nam")
        b.boundary("\n", proxy: p)
        swipe("anh", s, b, p)
        XCTAssertEqual(SwipeTyping.fold(p.text), "viet, nam\nanh")
    }

    func testPlainLetterAfterSwipeStartsNewWordAndSettles() {
        let (s, b, p) = make()
        swipe("viet", s, b, p, context: ["việt"])
        b.letter("a", proxy: p)
        XCTAssertEqual(p.text, "việt a")
        XCTAssertEqual(b.takeSettledCommit()?.word, "việt")
        XCTAssertFalse(b.isSwipeWordOpen)
    }

    func testAlternativeReplacesAndKeepsOpen() {
        let (s, b, p) = make()
        typed("xin ", b, p)
        let out = swipe("viet", s, b, p, context: ["việt"])
        XCTAssertEqual(out?.word, "việt")
        XCTAssertTrue(out?.alternatives.contains("viết") == true, "\(out?.alternatives ?? [])")
        XCTAssertTrue(b.replaceSwipeWord(with: "viết", proxy: p))
        XCTAssertEqual(p.text, "xin viết")
        XCTAssertTrue(b.openWordAccepted)
        b.backspace(proxy: p)                               // vẫn "tươi" ⇒ xoá cả từ
        XCTAssertEqual(p.text, "xin ")
    }

    // MARK: giai đoạn 3 — từ tiếng Anh

    /// Vuốt với ngữ cảnh ngôn ngữ như controller (prev1/prev2 = từ trên màn hình).
    @discardableResult
    private func swipeEn(_ word: String, _ s: SwipeTyping, _ b: EngineBridge, _ p: MockProxy,
                         prev1: String?, prev1English: Bool = false, prev2: String? = nil,
                         case sc: SwipeCase = .lower) -> SwipeTyping.Outcome? {
        let prior = SwipeLangContext.prior(
            prev1: SwipeLangContext.classify(prev1, swipedEnglish: prev1English),
            prev2: SwipeLangContext.classify(prev2))
        return s.finish(path(word), case: sc, contextWords: [], english: prior, bridge: b, proxy: p)
    }

    /// Vuốt với tiền nghiệm liên tục ngôn ngữ như controller: `recent` = từ đã chốt (cũ → mới).
    @discardableResult
    private func swipeRun(_ word: String, _ s: SwipeTyping, _ b: EngineBridge, _ p: MockProxy,
                          recent: [String]) -> SwipeTyping.Outcome? {
        let prior = SwipeLangContext.prior(SwipeLangContext.kinds(
            composing: false, pending: nil, pendingEnglish: false, recent: recent, english: { _ in false }))
        return s.finish(path(word), case: .lower, contextWords: [], prev: recent.last,
                        prev2: recent.dropLast().last, english: prior, bridge: b, proxy: p)
    }

    func testContinuityTheAfterEnglishWords() {
        let (s, b, p) = make()
        typed("i like big ", b, p)
        let out = swipeRun("the", s, b, p, recent: ["i", "like", "big"])
        XCTAssertEqual(out?.english, true, "\(String(describing: out))")
        XCTAssertEqual(out?.word, "the")
    }

    func testContinuityTheAfterVietnameseWords() {
        let (s, b, p) = make()
        typed("vis duj nhuw ", b, p)
        XCTAssertEqual(p.text, "ví dụ như ")
        let out = swipeRun("the", s, b, p, recent: ["ví", "dụ", "như"])
        XCTAssertEqual(out?.english, false, "\(String(describing: out))")
        XCTAssertEqual(out?.word, "thế")
        XCTAssertTrue(out?.englishAlternatives.contains("the") == true, "\(String(describing: out))")
        // một từ Anh chen giữa câu Việt vẫn ra
        let (s2, b2, p2) = make()
        typed("minhf ddang ", b2, p2)
        let m = swipeRun("check", s2, b2, p2, recent: ["mình", "đang"])
        XCTAssertEqual(m?.english, true, "\(String(describing: m))")
        XCTAssertEqual(m?.word, "check")
    }

    func testCollisionAfterVietnameseStaysVietnamese() {
        let (s, b, p) = make()
        typed("tooi ", b, p)
        let out = swipeEn("the", s, b, p, prev1: "tôi")
        XCTAssertEqual(out?.english, false)
        // dạng Việt "the" (dấu nào do tần suất/ngữ cảnh: thể/thế — xem bigram giai đoạn 2)
        let vi = out?.word ?? ""
        XCTAssertEqual(SwipeTyping.fold(vi), "the")
        XCTAssertNotEqual(vi, "the")
        XCTAssertTrue(out?.englishAlternatives.contains("the") == true, "\(String(describing: out))")
        XCTAssertEqual(p.text, "tôi " + vi)
        // chọn "the" trên thanh gợi ý ⇒ tiếng Anh nguyên văn (engine trống)
        XCTAssertTrue(b.replaceSwipeWord(with: "the", literal: true, proxy: p))
        XCTAssertEqual(p.text, "tôi the")
        XCTAssertTrue(b.isLiteralSwipeWordOpen)
        XCTAssertEqual(b.composedWord, "the")
    }

    func testEnglishRunCheckMail() {
        let (s, b, p) = make()
        typed("minhf ddang ", b, p)
        let o1 = swipeEn("check", s, b, p, prev1: "đang", prev2: "mình")
        XCTAssertEqual(o1?.english, true, "\(String(describing: o1))")
        XCTAssertEqual(p.text, "mình đang check")
        XCTAssertTrue(o1?.alternatives.contains { !(o1?.englishAlternatives.contains($0) ?? true) } == true)
        let o2 = swipeEn("mail", s, b, p, prev1: b.predictedCommit, prev1English: true, prev2: "đang")
        XCTAssertEqual(o2?.english, true)
        XCTAssertEqual(o2?.committed?.word, "check")        // từ trước được chốt để học
        XCTAssertEqual(p.text, "mình đang check mail")
        XCTAssertEqual(b.boundary(" ", proxy: p), "mail")   // space chốt từ Anh nguyên văn
        XCTAssertEqual(p.text, "mình đang check mail ")
    }

    func testEnglishWordBackspaceLetterUndoAndCase() {
        let (s, b, p) = make()
        typed("guiwr ", b, p)
        XCTAssertEqual(swipeEn("file", s, b, p, prev1: "gửi")?.english, true)
        XCTAssertEqual(p.text, "gửi file")
        b.backspace(proxy: p)                                // ⌫ đầu xoá cả từ
        XCTAssertEqual(p.text, "gửi ")
        swipeEn("file", s, b, p, prev1: "gửi")
        b.letter("s", proxy: p)                              // phím dấu KHÔNG sửa từ Anh
        XCTAssertEqual(p.text, "gửi file s")
        XCTAssertTrue(b.undoLastLetter(proxy: p))            // "s" hoá ra giữ ra ký tự phụ ⇒ huỷ sạch
        XCTAssertEqual(p.text, "gửi file")
        XCTAssertTrue(b.isLiteralSwipeWordOpen)
        b.letter("a", proxy: p)
        XCTAssertEqual(b.takeSettledCommit()?.word, "file")
        let (s2, b2, p2) = make()
        XCTAssertEqual(swipeEn("check", s2, b2, p2, prev1: nil, case: .capitalized)?.word, "Check")
        XCTAssertEqual(p2.text, "Check")
    }

    func testPickAlternativesMixVariantsAndOtherForms() {
        let r = SwipeTyping.pick(["cho", "co", "chi"], contextWords: [], case: .lower)
        XCTAssertNotNil(r)
        XCTAssertEqual(SwipeTyping.fold(r!.word), "cho")
        XCTAssertLessThanOrEqual(r!.alternatives.count, 3)
        XCTAssertFalse(r!.alternatives.contains(r!.word))
        XCTAssertTrue(r!.alternatives.contains { SwipeTyping.fold($0) == "co" }, "\(r!.alternatives)")
    }
}

/// Luồng đầy đủ qua router KeyboardView: chạm chèn chữ, vuốt huỷ chữ đầu + chèn từ.
final class SwipeKeyboardFlowTests: XCTestCase {
    @MainActor private func harness() -> (KeyboardView, UIView, MockProxy, EngineBridge, SwipeTyping) {
        let p = MockProxy(), b = EngineBridge(settings: KeyboardSettings()), s = SwipeTyping()
        let kb = KeyboardView(needsGlobe: false, inputController: nil) { key in
            switch key {
            case .letter(let c): b.letter(c, proxy: p)
            case .space: b.boundary(" ", proxy: p)
            case .text(let t): b.boundary(t, proxy: p)
            case .backspace: b.backspace(proxy: p)
            default: break
            }
        }
        let host = UIView(frame: CGRect(x: 0, y: 0, width: 390, height: 320))
        host.addSubview(kb)
        kb.frame = host.bounds
        kb.layoutIfNeeded()
        kb.swipeEnabled = true
        kb.onSwipeEnded = { path, sc in
            _ = s.finish(path, case: sc, contextWords: [], bridge: b, proxy: p)
        }
        if let l = kb.swipeLayout() { s.setLayout(l, prepare: false) }
        return (kb, host, p, b, s)
    }

    @MainActor private func center(_ kb: KeyboardView, _ ch: Character) -> CGPoint {
        let f = kb.debugLetterFrame(String(ch))!
        return CGPoint(x: f.midX, y: f.midY + TouchGeometry.yOffset)
    }

    @MainActor private func points(_ kb: KeyboardView, _ word: String) -> [CGPoint] {
        let keys = Array(SwipeSim.collapse(word)).map { center(kb, $0) }
        var out: [CGPoint] = []
        for i in 1..<keys.count {
            let a = keys[i - 1], b = keys[i]
            let n = max(2, Int(hypot(b.x - a.x, b.y - a.y) / 8))
            for j in 1...n {
                let u = CGFloat(j) / CGFloat(n)
                out.append(CGPoint(x: a.x + (b.x - a.x) * u, y: a.y + (b.y - a.y) * u))
            }
        }
        return out
    }

    @MainActor func testTapTapSwipeThroughRouter() throws {
        let (kb, host, p, b, _) = harness()
        let layout = try XCTUnwrap(kb.swipeLayout())
        XCTAssertGreaterThan(layout.keyWidth, 30)
        var t: TimeInterval = 100
        for ch in "xin" {                                   // chạm thường (shift đầu câu)
            XCTAssertFalse(kb.debugTouch(from: center(kb, ch), through: [], start: t))
            t += 1
        }
        XCTAssertEqual(p.text, "Xin")
        let swiped = kb.debugTouch(from: center(kb, "c"), through: points(kb, "chao"), start: t)
        XCTAssertTrue(swiped)
        XCTAssertEqual(SwipeTyping.fold(p.text), "xin chao")
        XCTAssertTrue(b.isSwipeWordOpen)
        withExtendedLifetime(host) {}
    }

    @MainActor func testSlideTapAndQuickFollowUpStayTaps() {
        let (kb, host, p, _, _) = harness()
        let a = center(kb, "a")
        // chạm có trượt 12pt: vẫn là chữ a
        XCTAssertFalse(kb.debugTouch(from: a, through: [CGPoint(x: a.x + 6, y: a.y),
                                                        CGPoint(x: a.x + 12, y: a.y)], start: 200))
        XCTAssertEqual(p.text.lowercased(), "a")
        // chạm s rồi 100ms sau kéo 2 phím từ d → g: không vuốt (gõ nhanh kéo lê)
        XCTAssertFalse(kb.debugTouch(from: center(kb, "s"), through: [], start: 300))
        let d = center(kb, "d"), g = center(kb, "g")
        let drag = (1...6).map { CGPoint(x: d.x + (g.x - d.x) * CGFloat($0) / 6, y: d.y) }
        XCTAssertFalse(kb.debugTouch(from: d, through: drag, start: 300.1))
        XCTAssertEqual(p.text.lowercased(), "asd")
        withExtendedLifetime(host) {}
    }

    // MARK: #172 — gõ vuốt bật: ngón còn đè thì không ghi gì vào ô

    @MainActor func testSwipeWritesNothingWhileFingerDown() {
        let (kb, host, p, _, _) = harness()
        var t: TimeInterval = 100
        for ch in "xin" { kb.debugTouch(from: center(kb, ch), through: [], start: t); t += 1 }
        let before = p.text
        var began = 0
        kb.onSwipeBegan = { began += 1 }
        let token = NSObject(), id = ObjectIdentifier(token)
        let pts = points(kb, "chao")
        kb.debugRouteDown(id, at: center(kb, "c"), time: t)
        XCTAssertEqual(p.text, before, "chạm xuống: chữ đầu chưa được chèn")
        XCTAssertTrue(kb.debugBalloonVisible, "phản hồi (balloon) vẫn ngay lúc chạm")
        XCTAssertTrue(kb.debugRouteMove(id, through: pts, start: t))
        XCTAssertEqual(began, 1)
        XCTAssertEqual(p.text, before, "đang vuốt: không chữ nào hiện rồi mất")
        kb.debugRouteUp(id, at: pts.last!, time: t + 1)
        XCTAssertEqual(SwipeTyping.fold(p.text), "xin chao")
        withExtendedLifetime(token) {}
        withExtendedLifetime(host) {}
    }

    @MainActor func testTapCommitsOnLift() {
        let (kb, host, p, _, _) = harness()
        let token = NSObject(), id = ObjectIdentifier(token)
        let a = center(kb, "a")
        kb.debugRouteDown(id, at: a, time: 10)
        XCTAssertEqual(p.text, "")
        XCTAssertTrue(kb.debugBalloonVisible)
        kb.debugRouteUp(id, at: a, time: 10.08)
        XCTAssertEqual(p.text.lowercased(), "a")
        withExtendedLifetime(token) {}
        withExtendedLifetime(host) {}
    }

    @MainActor func testOverlappingTapsKeepDownOrder() {
        let (kb, host, p, _, _) = harness()
        let t1 = NSObject(), t2 = NSObject(), t3 = NSObject()
        let (i1, i2, i3) = (ObjectIdentifier(t1), ObjectIdentifier(t2), ObjectIdentifier(t3))
        // a đè, n chạm (a chưa nhấc) ⇒ a chốt trước n; n nhấc trước a vẫn "an"
        kb.debugRouteDown(i1, at: center(kb, "a"), time: 20)
        XCTAssertEqual(p.text, "")
        kb.debugRouteDown(i2, at: center(kb, "n"), time: 20.05)
        XCTAssertEqual(p.text.lowercased(), "an")
        kb.debugRouteUp(i2, at: center(kb, "n"), time: 20.08)
        kb.debugRouteUp(i1, at: center(kb, "a"), time: 20.09)
        XCTAssertEqual(p.text.lowercased(), "an")
        // h đè (một ngón ⇒ hoãn), ngón khác chạm o trước khi h nhấc ⇒ "ho", không mất chữ
        kb.debugRouteDown(i3, at: center(kb, "h"), time: 21)
        XCTAssertEqual(p.text.lowercased(), "an")
        kb.debugRouteDown(i1, at: center(kb, "o"), time: 21.04)
        kb.debugRouteUp(i3, at: center(kb, "h"), time: 21.06)
        kb.debugRouteUp(i1, at: center(kb, "o"), time: 21.07)
        XCTAssertEqual(p.text.lowercased(), "anho")
        withExtendedLifetime([t1, t2, t3]) {}
        withExtendedLifetime(host) {}
    }

    @MainActor func testCancelledTapStillCommits() {
        // Hệ thống huỷ touch (hàng sát home indicator…) — như trước: chữ không bị nuốt.
        let (kb, host, p, _, _) = harness()
        let token = NSObject(), id = ObjectIdentifier(token)
        kb.debugRouteDown(id, at: center(kb, "e"), time: 30)
        XCTAssertEqual(p.text, "")
        kb.debugRouteCancel(id, at: center(kb, "e"), time: 30.05)
        XCTAssertEqual(p.text.lowercased(), "e")
        withExtendedLifetime(token) {}
        withExtendedLifetime(host) {}
    }

    @MainActor func testSwipeOffInsertsOnTouchDown() {
        let (kb, host, p, _, _) = harness()
        kb.swipeEnabled = false
        let token = NSObject(), id = ObjectIdentifier(token)
        kb.debugRouteDown(id, at: center(kb, "a"), time: 40)
        XCTAssertEqual(p.text.lowercased(), "a", "tắt gõ vuốt: chèn ngay lúc chạm như cũ")
        kb.debugRouteUp(id, at: center(kb, "a"), time: 40.08)
        XCTAssertEqual(p.text.lowercased(), "a")
        withExtendedLifetime(token) {}
        withExtendedLifetime(host) {}
    }

    @MainActor func testDisabledDoesNotTrack() {
        let (kb, host, p, _, _) = harness()
        kb.swipeEnabled = false
        XCTAssertFalse(kb.debugTouch(from: center(kb, "c"), through: points(kb, "chao"), start: 500))
        XCTAssertEqual(p.text.lowercased(), "c")
        withExtendedLifetime(host) {}
    }
}
