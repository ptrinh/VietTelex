// SwipeReviseTests.swift — sửa lại từ vuốt trước theo ngữ cảnh hai phía (SwipeRevise). Song
// sinh android SwipeReviseTests.kt (+ ca luồng SwipeTypingTests.kt). Đo trên câu giữ lại
// bigram-heldout.txt, vuốt TUẦN TỰ qua SwipeTyping.finish + EngineBridge như bàn phím thật.
import XCTest

final class SwipeReviseTests: XCTestCase {
    private let layout = SwipeLayout.qwerty(keyWidth: 36, rowHeight: 54)

    private func w(_ word: String, _ s: Float) -> SwipeWord { SwipeWord(word: word, score: s) }

    func testRightContextFlipsCloseCall() {
        let scored = [w("có", 1.0), w("cô", 0.95), w("co", 0.5)]
        XCTAssertEqual(SwipeRevise.revise(scored, current: "có", prev: "tôi", next: "giáo"), "cô")
        XCTAssertNil(SwipeRevise.revise(scored, current: "có", prev: "tôi", next: "thể"))
        XCTAssertEqual(SwipeRevise.revise([w("cô", 1.0), w("có", 0.95)], current: "cô", prev: "tôi", next: "thể"), "có")
    }

    func testClearLeadIsKept() {
        XCTAssertNil(SwipeRevise.revise([w("có", 4.0), w("cô", 0.5)], current: "có", prev: "tôi", next: "giáo"))
    }

    func testMarginAndGuards() {
        let scored = [w("có", 1.0), w("cô", 0.95)]
        XCTAssertNil(SwipeRevise.revise(scored, current: "có", prev: "tôi", next: "giáo", margin: 50))
        XCTAssertNil(SwipeRevise.revise(scored, current: "có", prev: "tôi", next: "giáo", lm: nil))
        XCTAssertNil(SwipeRevise.revise(scored, current: "có", prev: "tôi", next: "check"))
        XCTAssertNil(SwipeRevise.revise(scored, current: "cỏ", prev: "tôi", next: "giáo"))
        XCTAssertNil(SwipeRevise.revise(Array(scored.prefix(1)), current: "có", prev: "tôi", next: "giáo"))
        XCTAssertEqual(SwipeRevise.revise(scored, current: "có", prev: nil, next: "giáo"), "cô")
    }

    func testTypedNextWordNeedsExactTail() throws {
        let scored = [w("có", 1.0), w("cô", 0.95), w("cố", 0.9)]
        let t = SwipeRevise.Typed(word: "có", scored: scored, sc: .lower, prev: "tôi")
        let e = try XCTUnwrap(SwipeRevise.reviseTyped(t, typed: "giáo", boundary: " ", before: "tôi có giáo "))
        XCTAssertEqual(e.new, "cô")
        XCTAssertEqual("tôi " + e.tail, "tôi có giáo ")
        XCTAssertEqual(e.replacement, "cô giáo ")
        XCTAssertEqual(SwipeRevise.reviseTyped(t, typed: "giáo", boundary: ",", before: "có giáo,")?.replacement, "cô giáo,")
        XCTAssertNil(SwipeRevise.reviseTyped(t, typed: "giáo", boundary: " ", before: "tôi có giáo  "), "đuôi lệch")
        XCTAssertNil(SwipeRevise.reviseTyped(t, typed: "giáo", boundary: " ", before: "xcó giáo "), "từ vuốt dính chữ trước")
        XCTAssertNil(SwipeRevise.reviseTyped(t, typed: "giáo", boundary: "a", before: "có giáoa"), "ranh giới là chữ")
        XCTAssertNil(SwipeRevise.reviseTyped(t, typed: "giáo", boundary: " ", before: nil), "không đọc được")
        XCTAssertNil(SwipeRevise.reviseTyped(t, typed: "", boundary: " ", before: "có  "), "từ gõ rỗng")
        XCTAssertNil(SwipeRevise.reviseTyped(t, typed: "check", boundary: " ", before: "có check "), "từ gõ tiếng Anh")
        XCTAssertNil(SwipeRevise.reviseTyped(t, typed: "thể", boundary: " ", before: "có thể "), "từ kế ủng hộ từ đang hiện")
        let c = SwipeRevise.Typed(word: "Có", scored: scored, sc: .capitalized, prev: nil)
        XCTAssertEqual(SwipeRevise.reviseTyped(c, typed: "Giáo", boundary: " ", before: "Có Giáo ")?.replacement, "Cô Giáo ")
        // áp lên màn hình: đọc lại đuôi, lệch ⇒ không đụng
        let p = MockProxy()
        p.text = "tôi có giáo "
        XCTAssertTrue(SwipeRevise.apply(e, proxy: p))
        XCTAssertEqual(p.text, "tôi cô giáo ")
        XCTAssertFalse(SwipeRevise.apply(e, proxy: p), "đã sửa ⇒ đuôi cũ không còn")
        XCTAssertTrue(SwipeRevise.apply(e, undo: true, proxy: p))
        XCTAssertEqual(p.text, "tôi có giáo ")
        p.fakeContext = .some(nil)
        XCTAssertFalse(SwipeRevise.apply(e, proxy: p))
        XCTAssertEqual(p.text, "tôi có giáo ")
    }

    func testRightScoreClamped() throws {
        let lm = try XCTUnwrap(SyllableLM.shared)
        let id = { (s: String) in SyllableLM.id(of: s) ?? -1 }
        let r = SwipeRevise.rightScore(lm, prev: -1, cand: id("hôm"), next: id("nay"))
        XCTAssertTrue(r > 0 && r <= SwipeRevise.rightCap)
        XCTAssertGreaterThanOrEqual(SwipeRevise.rightScore(lm, prev: -1, cand: id("hôm"), next: id("xịch")),
                                    SwipeRevise.rightFloor)
        XCTAssertEqual(SwipeRevise.rightScore(lm, prev: -1, cand: -1, next: id("nay")), 0)
    }

    func testScoredSkipsEnglishAndIsSorted() {
        let en = [SwipeCandidate(folded: "check", score: 1, lang: .en), SwipeCandidate(folded: "chec", score: 0)]
        XCTAssertTrue(SwipeRevise.scored(en, context: nil, lambdaFreq: 2.5).isEmpty)
        let vi = [SwipeCandidate(folded: "co", score: 2), SwipeCandidate(folded: "cho", score: 1.5)]
        let sc = SwipeRevise.scored(vi, context: nil, lambdaFreq: 2.5)
        XCTAssertEqual(sc.first?.word, SwipeDecoder.expand("co", limit: 1).first?.word)
        XCTAssertTrue((2...SwipeRevise.maxCandidates).contains(sc.count))
        XCTAssertTrue(zip(sc, sc.dropFirst()).allSatisfy { $0.score >= $1.score })
        let re = SwipeRevise.rerank(vi, old: nil, oldLambda: 2.5, new: { $0 == "chó" ? 5 : 0 }, newLambda: 2.5)
        XCTAssertEqual(re.first?.folded, "cho")
    }

    // MARK: luồng SwipeTyping + EngineBridge (như KeyboardViewController.swipeEnded)

    private final class Flow {
        let s = SwipeTyping()
        let b = EngineBridge(settings: KeyboardSettings())
        let p = MockProxy()
        var rec: SwipeTyping.Revisable?
        var committed: [String] = []
        var last: SwipeTyping.Outcome?
        var englishWords: Set<String> = []
        /// Thời gian chỉ riêng SwipeTyping.finish (đường chốt cú vuốt), giây.
        var finishTime: Double = 0

        init(_ layout: SwipeLayout) { s.setLayout(layout, prepare: false) }

        @discardableResult
        func swipe(_ word: String, _ layout: SwipeLayout, sim: inout SwipeSim, sigma: Double = 0,
                   case sc: SwipeCase = .lower, revise: Bool = true, english: Bool = false,
                   natural: Bool = false) -> SwipeTyping.Outcome? {
            let f = SwipeTyping.fold(word)
            let composing = b.isComposing
            let prev = composing ? b.predictedCommit : committed.last
            let prev2 = composing ? committed.last : committed.dropLast().last
            let previous = revise ? rec.flatMap { r in
                b.isSwipeWordOpen && b.isFreshSwipeWord && !b.openWordAccepted && !b.isLiteralSwipeWordOpen
                    && b.composedWord == r.word ? r : nil
            } : nil
            rec = nil
            let path = natural ? sim.natural(f, layout)
                : sigma == 0 ? sim.path(f, layout, sigma: 0, jitter: 0) : sim.path(f, layout, sigma: sigma)
            // ngôn ngữ theo 2 từ trước (từ Anh vừa vuốt mang nhãn) — như KeyboardViewController
            let prior: SwipeEnglishPrior? = english ? SwipeLangContext.prior(
                prev1: SwipeLangContext.classify(prev, swipedEnglish: prev.map { englishWords.contains($0) } ?? false),
                prev2: SwipeLangContext.classify(prev2, swipedEnglish: prev2.map { englishWords.contains($0) } ?? false))
                : nil
            let t0 = CFAbsoluteTimeGetCurrent()
            let out = s.finish(path, case: sc, contextWords: [], prev: prev, prev2: prev2, english: prior,
                               previous: previous, bridge: b, proxy: p)
            finishTime += CFAbsoluteTimeGetCurrent() - t0
            if let out, out.english { englishWords.insert(out.word) }
            if let c = out?.committed { committed.append(c.word) }
            if let out, !out.scored.isEmpty, b.isSwipeWordOpen {
                rec = SwipeTyping.Revisable(word: out.word, scored: out.scored, sc: sc)
            }
            last = out
            return out
        }
    }

    /// Báo lỗi người dùng 28/09/2026: vuốt "ví dụ như thế này" không ra từ nào đúng. Trước: "vì dù
    /// như thế này" cả với đường sạch. Sửa chung cặp + ứng viên rộng ⇒ đúng; "the" sau từ Việt
    /// ra "thế". Song sinh SwipeReviseTests.kt phraseViDuNhuTheNay (bật vuốt tiếng Anh).
    func testPhraseViDuNhuTheNay() {
        let words = "ví dụ như thế này".split(separator: " ").map(String.init)
        let f = Flow(layout)
        var sim = SwipeSim(seed: 1)
        for w in words { f.swipe(w, layout, sim: &sim, english: true) }
        f.b.boundary(" ", proxy: f.p)
        XCTAssertEqual(f.p.text.trimmingCharacters(in: .whitespaces), words.joined(separator: " "))
        // đường "tự nhiên" (nhịp + lố như nét thật), 30 lần
        var nsim = SwipeSim(seed: 77)
        var ok = 0, theEn = 0
        for _ in 0..<30 {
            let g = Flow(layout)
            for w in words { g.swipe(w, layout, sim: &nsim, english: true, natural: true) }
            g.b.boundary(" ", proxy: g.p)
            let got = g.p.text.split(separator: " ").map(String.init)
            ok += zip(got, words).filter { $0 == $1 }.count
            if got.count > 3 && got[2] == "như" && got[3] == "the" { theEn += 1 }   // sau "như" đúng
        }
        let n = 30 * words.count
        print(String(format: "REVISE câu \"ví dụ như thế này\" iOS (đường tự nhiên ×30, bật EN): đúng %.3f từ, the Anh (sau \"như\") %d",
                     Double(ok) / Double(n), theEn))
        XCTAssertGreaterThanOrEqual(Double(ok), Double(n) * 0.7)
        XCTAssertEqual(theEn, 0)
    }

    func testNextSwipeRevisesPrevious() {
        let f = Flow(layout)
        var sim = SwipeSim(seed: 7)
        f.swipe("co", layout, sim: &sim)
        XCTAssertEqual(f.p.text, "có")
        let out = f.swipe("gang", layout, sim: &sim)
        XCTAssertEqual(f.p.text, "cố gắng")
        XCTAssertEqual(out?.revised, SwipeTyping.Revision(old: "có", new: "cố"))
        XCTAssertEqual(out?.committed?.word, "cố", "học từ mới, không học từ cũ")
        XCTAssertFalse(out?.committed?.accepted ?? true)
        // chip "↩︎ có": trả lại đúng từ cũ, từ vuốt mới vẫn mở
        XCTAssertTrue(f.b.restoreRevisedWord(old: "có", new: "cố", proxy: f.p))
        XCTAssertEqual(f.p.text, "có gắng")
        XCTAssertTrue(f.b.isSwipeWordOpen)
        XCTAssertFalse(f.b.restoreRevisedWord(old: "có", new: "cố", proxy: f.p), "đuôi đã khác ⇒ không đụng")
        f.b.boundary(" ", proxy: f.p)
        XCTAssertEqual(f.p.text, "có gắng ")
    }

    /// Phil 18/10/2026: vuốt "ngay" đầu câu ra "Này" (n-a-y ≈ n-g-a-y, này hay gặp hơn); vuốt
    /// "mai" kế ⇒ "Ngày mai" (trigram "ngày mai" ≫ "này mai"), giữ chữ hoa đầu câu; chip ↩︎ trả
    /// "Này". Song sinh android SwipeTypingTests.nayRevisedToNgayMaiAtSentenceStart.
    func testNayRevisedToNgayMaiAtSentenceStart() {
        let f = Flow(layout)
        var sim = SwipeSim(seed: 7)
        f.swipe("ngay", layout, sim: &sim, case: .capitalized)
        XCTAssertEqual(f.p.text, "Này")
        let out = f.swipe("mai", layout, sim: &sim)
        XCTAssertEqual(f.p.text, "Ngày mai")
        XCTAssertEqual(out?.revised, SwipeTyping.Revision(old: "Này", new: "Ngày"))
        XCTAssertEqual(out?.committed?.word, "Ngày", "học từ mới, không học từ cũ")
        XCTAssertTrue(f.b.restoreRevisedWord(old: "Này", new: "Ngày", proxy: f.p))
        XCTAssertEqual(f.p.text, "Này mai")
        // "ngay" rồi "xưa"/"nay": cũng là "ngày"; vuốt "nay" thật thì "mai" không kéo sang "ngày"
        for (next, want) in [("xua", "Ngày xưa"), ("nay", "Ngày nay")] {
            let g = Flow(layout)
            g.swipe("ngay", layout, sim: &sim, case: .capitalized)
            g.swipe(next, layout, sim: &sim)
            XCTAssertEqual(g.p.text, want)
        }
        // 18/10/2026 (tần suất vnlexicon corpus hội thoại: dạng "ngay" 196 → 206, "nay" 228 → 227) — vuốt
        // "nay" rồi "mai" nay cũng sửa thành "Ngày mai" (trước giữ "Này "); chip ↩︎ vẫn trả lại được.
        let h = Flow(layout)
        h.swipe("nay", layout, sim: &sim, case: .capitalized)
        h.swipe("mai", layout, sim: &sim)
        XCTAssertEqual(h.p.text, "Ngày mai")
        XCTAssertTrue(h.b.restoreRevisedWord(old: "Này", new: "Ngày", proxy: h.p))
        XCTAssertEqual(h.p.text, "Này mai")
    }

    /// Chi phí thêm trên đường chốt cú vuốt (Debug, simulator): SwipeTyping.finish khi có từ vuốt
    /// trước để chấm lại (nextPool + revise, và rerank khi đổi) so với tắt — cùng các câu đường
    /// sạch, đo xen kẽ nhiều vòng, lấy min. Không có chi phí ở đường phím chữ.
    /// iOS Debug 18/10/2026 (simulator, 323 cú vuốt): 7.28 → 7.82 ms/vuốt (+0.54 ms).
    func testRevisionLatencyOnSwipeCommit() throws {
        try SlowTests.require()
        let url = try XCTUnwrap(Bundle(for: SwipeReviseTests.self).url(forResource: "bigram-heldout", withExtension: "txt"))
        let chains = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
            .filter { !$0.hasPrefix("#") && !$0.isEmpty }.prefix(40)
            .map { $0.split(separator: " ").map(String.init) }
        func run(_ revise: Bool) -> (ms: Double, n: Int, revised: Int) {
            var t = 0.0, n = 0, revised = 0
            for chain in chains {
                let f = Flow(layout)
                var sim = SwipeSim(seed: 7)
                for w in chain {
                    if f.swipe(w, layout, sim: &sim, revise: revise)?.revised != nil { revised += 1 }
                    // chỉ tính cú vuốt có từ vuốt trước (cú đầu câu như nhau ở cả hai bên)
                }
                t += f.finishTime
                n += chain.count
            }
            return (t * 1000, n, revised)
        }
        _ = run(true)                                       // làm nóng (prepare decoder, LM)
        var best = (off: Double.infinity, on: Double.infinity)
        var n = 0, revised = 0
        for _ in 0..<3 {
            let a = run(false), b = run(true)
            best.off = min(best.off, a.ms); best.on = min(best.on, b.ms)
            n = b.n; revised = b.revised
        }
        let per = (off: best.off / Double(n), on: best.on / Double(n))
        print(String(format: "REVISE-LATENCY iOS (Debug, %d cú vuốt, sửa %d): finish %.3f → %.3f ms/vuốt (+%.3f ms)",
                     n, revised, per.off, per.on, per.on - per.off))
        XCTAssertLessThan(per.on - per.off, 5, "chấm lại phải rẻ so với giải mã")
    }

    func testCaseKeptAndOnlyOnce() {
        let f = Flow(layout)
        var sim = SwipeSim(seed: 7)
        f.swipe("co", layout, sim: &sim, case: .capitalized)
        f.swipe("gang", layout, sim: &sim)
        XCTAssertEqual(f.p.text, "Cố gắng")
        f.swipe("len", layout, sim: &sim)
        XCTAssertTrue(f.p.text.hasPrefix("Cố gắng "), f.p.text)
    }

    func testNoRevisionAfterToneEditOrChoice() {
        // phím dấu Telex sửa từ vuốt ⇒ không còn nguyên
        do {
            let f = Flow(layout)
            var sim = SwipeSim(seed: 7)
            f.swipe("co", layout, sim: &sim)
            f.b.letter("f", proxy: f.p)                     // có → cò
            XCTAssertEqual(f.p.text, "cò")
            f.swipe("gang", layout, sim: &sim)
            XCTAssertTrue(f.p.text.hasPrefix("cò "), f.p.text)
        }
        // chọn phương án ⇒ user đã quyết (controller bỏ rec; bridge đánh dấu accepted)
        do {
            let f = Flow(layout)
            var sim = SwipeSim(seed: 7)
            f.swipe("co", layout, sim: &sim)
            let alt = f.last!.alternatives.first { $0 != "cố" }!
            XCTAssertTrue(f.b.replaceSwipeWord(with: alt, proxy: f.p))
            f.swipe("gang", layout, sim: &sim)
            XCTAssertTrue(f.p.text.hasPrefix(alt + " "), f.p.text)
        }
    }

    /// Từ kế GÕ PHÍM ngay sau từ vuốt (dấu cách treo của phím chữ, hoặc dấu cách) — như
    /// KeyboardViewController.handle: chốt từ gõ xong mới chấm lại, rồi ⌫ vẫn mở lại từ gõ.
    func testTypedNextWordRevisesViaBridge() throws {
        for viaSpace in [false, true] {
            let f = Flow(layout)
            var sim = SwipeSim(seed: 7)
            f.swipe("co", layout, sim: &sim)
            let rec = try XCTUnwrap(f.rec)
            let t = SwipeRevise.Typed(word: rec.word, scored: rec.scored, sc: rec.sc, prev: nil)
            if viaSpace { f.b.boundary(" ", proxy: f.p) }
            for ch in "gawngs" { f.b.letter(ch, proxy: f.p) }
            XCTAssertEqual(f.p.text, "có gắng")
            let typed = f.b.boundary(" ", proxy: f.p)
            XCTAssertEqual(typed, "gắng")
            let e = try XCTUnwrap(SwipeRevise.reviseTyped(t, typed: typed, boundary: " ", before: f.p.contextBeforeInput))
            XCTAssertEqual(e.new, "cố")
            XCTAssertTrue(SwipeRevise.apply(e, proxy: f.p))
            XCTAssertEqual(f.p.text, "cố gắng ")
            XCTAssertTrue(f.b.backspace(proxy: f.p), "⌫ vẫn mở lại từ gõ")
            XCTAssertEqual(f.p.text, "cố gắng")
            f.b.boundary(" ", proxy: f.p)
            XCTAssertTrue(SwipeRevise.apply(e, undo: true, proxy: f.p), "chip ↩︎ có")
            XCTAssertEqual(f.p.text, "có gắng ")
        }
    }

    func testFailSafeWhenContextDiffers() {
        let f = Flow(layout)
        var sim = SwipeSim(seed: 7)
        f.swipe("co", layout, sim: &sim)
        f.p.fakeContext = .some(nil)                        // host không cho đọc context
        f.swipe("gang", layout, sim: &sim)
        XCTAssertFalse(f.p.text.contains("cố"), f.p.text)
        XCTAssertNil(f.last?.revised)
    }

    // MARK: đo trên câu giữ lại

    private func heldout() throws -> [[String]] {
        let url = try XCTUnwrap(Bundle(for: SwipeReviseTests.self)
            .url(forResource: "bigram-heldout", withExtension: "txt"))
        return try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
            .filter { !$0.hasPrefix("#") && !$0.isEmpty }
            .map { $0.split(separator: " ").map(String.init) }
    }

    private func measure(_ chains: [[String]], revise: Bool) -> (n: Int, ok: Int, revised: Int) {
        var sim = SwipeSim(seed: 2027)
        var n = 0, ok = 0, revised = 0
        for chain in chains {
            let f = Flow(layout)
            for w in chain {
                if f.swipe(w, layout, sim: &sim, sigma: 0.25, revise: revise)?.revised != nil { revised += 1 }
            }
            let got = f.p.text.split(separator: " ").map(String.init)
            n += chain.count
            ok += zip(got, chain).filter { $0 == $1 }.count
        }
        return (n, ok, revised)
    }

    /// Vuốt/gõ xen kẽ (vị trí i vuốt khi i % 2 == phase; từ gõ = đáp án, chèn thẳng như đã
    /// gõ xong + dấu cách): chốt từ gõ ⇒ SwipeRevise.reviseTyped + apply. Đo các từ vuốt có từ
    /// gõ ngay sau. Song sinh SwipeReviseTests.kt measureTyped.
    private func measureTyped(_ chains: [[String]], revise: Bool)
        -> (n: Int, ok: Int, fixed: Int, broke: Int, revised: Int) {
        var sim = SwipeSim(seed: 2027)
        var n = 0, ok = 0, fixed = 0, broke = 0, revised = 0
        for chain in chains {
            for phase in 0...1 {
                let f = Flow(layout)
                var before: [Int: String] = [:]
                var words: [String] = []          // từ trên màn hình theo vị trí ("" = vuốt không ra gì)
                var pending: SwipeRevise.Typed?
                for (i, word) in chain.enumerated() {
                    if i % 2 != phase {
                        if f.b.isComposing { f.committed.append(f.b.boundary(" ", proxy: f.p)) }
                        f.p.insertText(word + " ")
                        f.committed.append(word)
                        if revise, let t = pending,
                           let e = SwipeRevise.reviseTyped(t, typed: word, boundary: " ", before: f.p.contextBeforeInput),
                           SwipeRevise.apply(e, proxy: f.p) {
                            f.committed[f.committed.count - 2] = e.new
                            words[i - 1] = e.new
                        }
                        words.append(word)
                        pending = nil
                        f.rec = nil
                        continue
                    }
                    let out = f.swipe(word, layout, sim: &sim, sigma: 0.25, revise: false)
                    if i + 1 < chain.count { before[i] = out?.word ?? "" }
                    words.append(out?.word ?? "")
                    pending = f.rec.map { SwipeRevise.Typed(word: $0.word, scored: $0.scored, sc: $0.sc,
                                                             prev: f.committed.last) }
                }
                XCTAssertEqual(words.filter { !$0.isEmpty }.joined(separator: " "),
                               f.p.text.trimmingCharacters(in: .whitespaces))
                for (i, b) in before {
                    n += 1
                    let now = words[i]
                    if now == chain[i] { ok += 1 }
                    if now != b { revised += 1; if now == chain[i] { fixed += 1 }; if b == chain[i] { broke += 1 } }
                }
            }
        }
        return (n, ok, fixed, broke, revised)
    }

    /// Từ kế gõ phím, cùng tập đo. 27/09/2026: iOS 0.853 → 0.934 (+328 −15); JVM 0.857 → 0.942 (+341 −15).
    func testHeldoutTypedRevisionGain() throws {
        try SlowTests.require()
        let test = try heldout().enumerated().filter { $0.offset % 3 == 0 }.map(\.element)
        let base = measureTyped(test, revise: false)
        let rev = measureTyped(test, revise: true)
        let a = Double(base.ok) / Double(base.n), b = Double(rev.ok) / Double(rev.n)
        print(String(format: "REVISE-TYPED heldout iOS (vuốt xen gõ, σ0.25): trước %.4f | sau %.4f (+%.2f điểm, n=%d, sửa %d: +%d −%d)",
                     a, b, (b - a) * 100, rev.n, rev.revised, rev.fixed, rev.broke))
        XCTAssertGreaterThanOrEqual(b - a, 0.01)
        XCTAssertLessThanOrEqual(rev.broke * 5, rev.fixed)
    }

    /// Cùng tập đo với Kotlin (offset % 3 == 0). Android JVM 27/09/2026: 0.809 → 0.855; 28/09 (sửa
    /// chung cặp + nhịp): 0.809 → 0.913, iOS 0.780 → 0.882.
    func testHeldoutRevisionGain() throws {
        try SlowTests.require()
        let test = try heldout().enumerated().filter { $0.offset % 3 == 0 }.map(\.element)
        let t0 = CFAbsoluteTimeGetCurrent()
        let base = measure(test, revise: false)
        let t1 = CFAbsoluteTimeGetCurrent()
        let rev = measure(test, revise: true)
        let t2 = CFAbsoluteTimeGetCurrent()
        let a = Double(base.ok) / Double(base.n), b = Double(rev.ok) / Double(rev.n)
        print(String(format: "REVISE heldout iOS (tuần tự, σ0.25): trước %.4f | sau %.4f (+%.2f điểm, sửa %d, n=%d) | %.2f → %.2f ms/vuốt (Debug)",
                     a, b, (b - a) * 100, rev.revised, rev.n,
                     (t1 - t0) * 1000 / Double(base.n), (t2 - t1) * 1000 / Double(rev.n)))
        XCTAssertGreaterThanOrEqual(b - a, 0.01)
    }
}
