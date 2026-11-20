// Gõ tắt trong gõ vuốt (10/2026): khoá gõ tắt thuần chữ vuốt được (chèn nội dung bung như gõ khoá +
// dấu cách, ⌫ đầu trả lại khoá), từ của nội dung ngắn (≤ 3 từ) vào từ vựng vuốt đúng hoa/thường.
// Song sinh Android SwipeShortcutTests.kt; fixture chung Fixtures/swipe-shortcuts.tsv.
import XCTest

final class SwipeShortcutTests: XCTestCase {
    private let layout = SwipeLayout.qwerty(keyWidth: 39, rowHeight: 54)

    override func tearDown() {
        SwipeVocab.setShortcuts(nil)
        super.tearDown()
    }

    private struct Fixture {
        var table: [String: String] = [:]
        var entries: [(String, Int)] = []
        var swipes: [(path: String, sc: SwipeCase, want: String)] = []
    }

    private func fixture() throws -> Fixture {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "swipe-shortcuts", withExtension: "tsv"))
        var f = Fixture(), section = ""
        for line in try String(contentsOf: url, encoding: .utf8).split(separator: "\n") {
            if line.hasPrefix("#") || line.isEmpty { continue }
            if line.hasPrefix("[") { section = String(line); continue }
            let c = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            switch section {
            case "[table]": f.table[c[0]] = c[1]
            case "[entries]": f.entries.append((c[0], Int(c[1])!))
            case "[swipe]":
                let sc: SwipeCase = c[1] == "upper" ? .upper : c[1] == "capitalized" ? .capitalized : .lower
                f.swipes.append((c[0], sc, c[2]))
            default: break
            }
        }
        return f
    }

    func testEntriesMatchSharedFixture() throws {
        let f = try fixture()
        let got = SwipeVocab.shortcutEntries(ShortcutTable(f.table))
        XCTAssertEqual(got.map(\.word), f.entries.map(\.0))
        XCTAssertEqual(got.map(\.freq), f.entries.map(\.1))
    }

    func testCapAndNoChangeNoRebuild() {
        var big: [String: String] = [:]
        var i = 0
        for a in "abcdefghijklmnopqrstuvwxyz" { for b in "abcdefghijklmnopqrstuvwxyz" {
            big["q" + String(a) + String(b)] = "Xyzq\(i)"; i += 1
        } }
        XCTAssertEqual(SwipeVocab.shortcutEntries(ShortcutTable(big)).count, SwipeVocab.shortcutCap)
        let t = ShortcutTable(["vn": "Việt Nam"])
        XCTAssertTrue(SwipeVocab.setShortcuts(t))
        let v = SwipeVocab.current
        XCTAssertFalse(SwipeVocab.setShortcuts(t), "bảng không đổi ⇒ không dựng lại")
        XCTAssertTrue(SwipeVocab.current === v)
        XCTAssertNotNil(v.index(of: "vn"))
        XCTAssertTrue(SwipeVocab.setShortcuts(nil))
        XCTAssertNil(SwipeVocab.current.index(of: "vn"), "tắt Gõ tắt ⇒ khoá không vuốt được nữa")
    }

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

    private func bridge(_ table: [String: String], enabled: Bool = true) -> EngineBridge {
        var s = KeyboardSettings()
        s.shortcuts = ShortcutTable(table)
        s.shortcutsEnabled = enabled
        return EngineBridge(settings: s)
    }

    private func swipe(_ w: String, _ s: SwipeTyping, _ b: EngineBridge, _ p: MockProxy,
                       case sc: SwipeCase = .lower) -> SwipeTyping.Outcome? {
        return s.finish(path(w), case: sc, contextWords: [], bridge: b, proxy: p)
    }

    func testSwipesFromSharedFixture() throws {
        let f = try fixture()
        SwipeVocab.setShortcuts(ShortcutTable(f.table))
        let s = SwipeTyping()
        s.setLayout(layout, prepare: false)
        for (w, sc, want) in f.swipes {
            let b = bridge(f.table), p = MockProxy()
            let out = swipe(w, s, b, p, case: sc)
            XCTAssertEqual(out?.word, want, "\(w) \(sc)")
            XCTAssertEqual(p.text, want, "\(w) \(sc)")
        }
    }

    func testBackspaceRestoresKeyAndAlternativeKeepsKey() throws {
        let table = ["vn": "Việt Nam"]
        SwipeVocab.setShortcuts(ShortcutTable(table))
        let s = SwipeTyping()
        s.setLayout(layout, prepare: false)
        let b = bridge(table), p = MockProxy()
        p.text = "yêu"
        let out = try XCTUnwrap(swipe("vn", s, b, p))
        XCTAssertEqual(p.text, "yêu Việt Nam")
        XCTAssertEqual(out.alternatives.first, "vn", "khoá đứng đầu phương án")
        XCTAssertTrue(out.englishAlternatives.contains("vn"), "chọn khoá ⇒ chèn nguyên văn")
        b.backspace(proxy: p)                                 // như hoàn tác gõ tắt gõ tay
        XCTAssertEqual(p.text, "yêu vn")
        b.boundary(" ", proxy: p)                              // từ vuốt ⇒ không bung lại
        XCTAssertEqual(p.text, "yêu vn ")
        // chọn phương án "vn" trên thanh: thay nguyên văn
        let b2 = bridge(table), p2 = MockProxy()
        _ = swipe("vn", s, b2, p2)
        XCTAssertTrue(b2.replaceSwipeWord(with: "vn", literal: true, proxy: p2))
        XCTAssertEqual(p2.text, "vn")
    }

    func testShortcutsOffOrFieldDisallowedInsertsKeyNotExpansion() throws {
        let table = ["vn": "Việt Nam"]
        let s = SwipeTyping()
        s.setLayout(layout, prepare: false)
        // công tắc tắt: bridge không bung (từ vựng do controller bỏ — mô phỏng còn khoá)
        SwipeVocab.setShortcuts(ShortcutTable(table))
        let off = bridge(table, enabled: false), p = MockProxy()
        XCTAssertNil(off.swipeShortcutExpansion(for: "vn"))
        XCTAssertEqual(swipe("vn", s, off, p)?.word, "vn")
        // ô omnibox (shortcutsAllowed = false)
        let omni = bridge(table)
        omni.shortcutsAllowed = false
        XCTAssertNil(omni.swipeShortcutExpansion(for: "vn"))
        // khoá ký hiệu/chữ+số không bao giờ là từ vuốt
        XCTAssertNil(bridge(["k2": "x", "->": "→"]).swipeShortcutExpansion(for: "k2"))
        XCTAssertEqual(bridge(table).swipeShortcutExpansion(for: "Vn"), "Việt Nam")
        XCTAssertEqual(bridge(table).swipeShortcutExpansion(for: "VN"), "VIỆT NAM")
    }

    /// Bộ nhớ template: thêm ~13 dạng từ bảng gõ tắt (in số đo để báo cáo).
    func testTemplateMemoryDelta() {
        let d = SwipeDecoder()
        d.setLayout(layout)
        SwipeVocab.setShortcuts(nil)
        d.prepare()
        let before = d.templateBytes
        var big: [String: String] = [:]
        var i = 0
        for a in "abcdefghijklmnopqrstuvwxyz" { for b in "abcdefghijklmnopqrstuvwxyz" {
            big["q" + String(a) + String(b)] = "Xyzq\(i)"; i += 1
        } }
        SwipeVocab.setShortcuts(ShortcutTable(big))
        d.prepare()
        let after = d.templateBytes
        print("SWIPE-SHORTCUTS: templates \(before) → \(after) B (+\(after - before) B cho \(SwipeVocab.shortcutCap) mục)")
        XCTAssertGreaterThan(after, before)
        XCTAssertLessThan(after - before, 300_000)
    }
}
