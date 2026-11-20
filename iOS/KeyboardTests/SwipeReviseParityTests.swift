// SwipeReviseParityTests.swift — fixture chung iOS ↔ Android cho sửa lại từ vuốt trước
// (Fixtures/swipe-revise.tsv, sinh bởi android SwipeReviseParityTests với VT_WRITE_FIXTURE=1).
// Mỗi dòng là một quyết định của Kotlin; ở đây tính lại bằng SwipeRevise.swift và phải y hệt:
//   J prev current scored next expected  — sửa chung cặp (cú vuốt kế), hằng số mặc định
//   T prev current scored typed expected — từ kế gõ phím (reviseTyped)
//   P case words expected                — cả câu vuốt đường sạch (SwipeSim seed 7, phím 36×54)
//                                          qua SwipeTyping.finish + EngineBridge như bàn phím
// `scored`/`next` = "từ:điểm" cách dấu phẩy (Float.toString của Kotlin, đọc lại đúng bit);
// "-" = không có / giữ nguyên. Cột cách TAB.
import XCTest

final class SwipeReviseParityTests: XCTestCase {
    private let layout = SwipeLayout.qwerty(keyWidth: 36, rowHeight: 54)

    private func lines() throws -> [[String]] {
        let url = try XCTUnwrap(Bundle(for: SwipeReviseParityTests.self)
            .url(forResource: "swipe-revise", withExtension: "tsv"))
        return try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
            .filter { !$0.hasPrefix("#") && !$0.isEmpty }
            .map { $0.split(separator: "\t", omittingEmptySubsequences: false).map(String.init) }
    }

    private func words(_ s: String) -> [SwipeWord] {
        s.split(separator: ",").map { item in
            let kv = item.split(separator: ":")
            return SwipeWord(word: String(kv[0]), score: Float(String(kv[1]))!)
        }
    }

    private func opt(_ s: String) -> String? { s == "-" ? nil : s }

    /// Cả câu vuốt như KeyboardViewController.swipeEnded (không LM cá nhân, tắt vuốt tiếng Anh):
    /// từ đầu theo `first`, các từ sau chữ thường. Trả chữ trên màn hình (bỏ dấu cách cuối).
    func phrase(_ ws: [String], first: SwipeCase) -> String {
        let s = SwipeTyping()
        s.setLayout(layout, prepare: false)
        let b = EngineBridge(settings: KeyboardSettings())
        let p = MockProxy()
        var committed: [String] = []
        var rec: SwipeTyping.Revisable?
        for (i, w) in ws.enumerated() {
            let sc: SwipeCase = i == 0 ? first : .lower
            let f = SwipeTyping.fold(w)
            let composing = b.isComposing
            let prev = composing ? b.predictedCommit : committed.last
            let prev2 = composing ? committed.last : committed.dropLast().last
            let previous = rec.flatMap { r in
                b.isSwipeWordOpen && b.isFreshSwipeWord && !b.openWordAccepted && !b.isLiteralSwipeWordOpen
                    && b.composedWord == r.word ? r : nil
            }
            rec = nil
            var sim = SwipeSim(seed: 7)
            let out = s.finish(sim.path(f, layout, sigma: 0, jitter: 0), case: sc, contextWords: [],
                               prev: prev, prev2: prev2, previous: previous, bridge: b, proxy: p)
            if let c = out?.committed { committed.append(c.word) }
            if let out, !out.scored.isEmpty, b.isSwipeWordOpen {
                rec = SwipeTyping.Revisable(word: out.word, scored: out.scored, sc: sc)
            }
        }
        return p.text.trimmingCharacters(in: .whitespaces)
    }

    func testFixtureMatchesAndroid() throws {
        var n = (j: 0, t: 0, p: 0, revised: 0)
        var mismatches: [String] = []
        for f in try lines() {
            let line = f.joined(separator: "\t")
            let prev = opt(f[1])
            let got: String?
            let want: String?
            switch f[0] {
            case "J":
                got = SwipeRevise.revise(words(f[3]), current: f[2], prev: prev, next: words(f[4]))
                want = opt(f[5]); n.j += 1
            case "T":
                let t = SwipeRevise.Typed(word: f[2], scored: words(f[3]), sc: .lower, prev: prev)
                let before = (prev.map { $0 + " " } ?? "") + f[2] + " " + f[4] + " "
                got = SwipeRevise.reviseTyped(t, typed: f[4], boundary: " ", before: before)?.new
                want = opt(f[5]); n.t += 1
            case "P":
                got = phrase(f[2].split(separator: " ").map(String.init), first: f[1] == "F" ? .capitalized : .lower)
                want = f[3]; n.p += 1
            default:
                XCTFail("dòng lạ: \(line)"); continue
            }
            if want != nil, f[0] != "P" { n.revised += 1 }
            if got != want { mismatches.append("\(line)  ⇒ iOS: \(got ?? "-")") }
        }
        print("REVISE-PARITY iOS: J \(n.j) T \(n.t) P \(n.p) (sửa \(n.revised)), lệch \(mismatches.count)")
        XCTAssertTrue(mismatches.isEmpty, mismatches.prefix(10).joined(separator: "\n"))
        XCTAssertGreaterThan(n.j, 200)
        XCTAssertGreaterThan(n.t, 150)
        XCTAssertGreaterThan(n.revised, 100)
    }
}
