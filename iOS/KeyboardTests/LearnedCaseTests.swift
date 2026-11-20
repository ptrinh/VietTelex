// Hoa/thường cho gõ vuốt + gợi ý (10/2026): DisplayCase áp lên từ vuốt (kết hợp Shift / Caps /
// đầu câu), hoa/thường người dùng viết nhất quán giữa câu (CaseTable trong UserLMTables.swift),
// lưu trong userlm.bin (VTL2 flags bit 0 — bản cũ đọc được), xoá cùng "Xoá từ đã học".
// Song sinh Android LearnedCaseTests.kt; fixture userlm-vtl2-case.bin dùng chung.
import XCTest

final class LearnedCaseTests: XCTestCase {
    // MARK: bảng hoa/thường (thuần)

    /// Ghi một từ như controller: bằng chứng = DisplayCase.casingEvidence (giữa câu, không chuỗi).
    private func type(_ m: UserLangModel, _ word: String, after prev: String?, times: Int = 1) {
        for _ in 0..<times {
            m.record(word: word, after: prev, caseEvidence: DisplayCase.casingEvidence(word, prev: prev))
        }
    }

    func testThreeMidSentenceUsesTeachPreferredForm() {
        let m = UserLangModel(appGroup: nil)
        type(m, "SenPrints", after: "ty", times: 2)
        XCTAssertNil(m.learnedCase("senprints"), "2 lần chưa đủ")
        type(m, "SenPrints", after: "ở")
        XCTAssertEqual(m.learnedCase("senprints"), "SenPrints")
        // tên người không có trong DisplayCase
        type(m, "Văn", after: "anh", times: 3)
        XCTAssertEqual(m.learnedCase("văn"), "Văn")
    }

    func testSentenceStartCapitalsAreNotLearned() {
        let m = UserLangModel(appGroup: nil)
        type(m, "Văn", after: nil, times: 6)            // đầu câu / sau dấu câu (lastWord cắt)
        XCTAssertNil(m.learnedCase("văn"))
        XCTAssertEqual(m.debugCaseCount, 0, "không tốn byte nào")
        XCTAssertFalse(DisplayCase.casingEvidence("Văn", prev: nil))
        XCTAssertFalse(DisplayCase.casingEvidence("Văn", prev: ""))
    }

    func testCapsLockAndSingleLettersAreNotLearned() {
        let m = UserLangModel(appGroup: nil)
        type(m, "SENPRINTS", after: "ở", times: 5)
        type(m, "VĂN", after: "anh", times: 5)
        type(m, "A", after: "điểm", times: 5)
        XCTAssertNil(m.learnedCase("senprints"))
        XCTAssertNil(m.learnedCase("văn"))
        XCTAssertNil(m.learnedCase("a"))
        XCTAssertEqual(m.debugCaseCount, 0)
    }

    func testChainCapitalsAreNotEvidence() {
        // "Việt Nam" nhiều lần không dạy "nam" thành tên riêng ở mọi nơi.
        let m = UserLangModel(appGroup: nil)
        type(m, "Nam", after: "Việt", times: 6)
        XCTAssertNil(m.learnedCase("nam"))
        XCTAssertFalse(DisplayCase.casingEvidence("Nam", prev: "việt"))
        XCTAssertTrue(DisplayCase.casingEvidence("Nam", prev: "anh"))
    }

    func testAmbiguousWordNeedsConsistency() {
        // "văn" (văn bản) gõ thường nhiều ⇒ vài lần "Văn" không đủ.
        let m = UserLangModel(appGroup: nil)
        type(m, "văn", after: "bài", times: 20)
        type(m, "Văn", after: "anh", times: 3)
        XCTAssertNil(m.learnedCase("văn"))
        // người dùng chỉ viết "Văn" ⇒ học; xen viết thường dưới 80% ⇒ mất
        let n = UserLangModel(appGroup: nil)
        type(n, "Văn", after: "anh", times: 4)
        XCTAssertEqual(n.learnedCase("văn"), "Văn")
        type(n, "văn", after: "bài")                        // 4/5 = 80% — vẫn giữ
        XCTAssertEqual(n.learnedCase("văn"), "Văn")
        type(n, "văn", after: "bài")                        // 4/6 < 80%
        XCTAssertNil(n.learnedCase("văn"))
    }

    func testCompetingCapitalFormsCancel() {
        let m = UserLangModel(appGroup: nil)
        type(m, "SenPrints", after: "ở", times: 3)
        type(m, "Senprints", after: "ở", times: 2)
        XCTAssertNil(m.learnedCase("senprints"))
        type(m, "Senprints", after: "ở", times: 4)
        XCTAssertNil(m.learnedCase("senprints"), "4 dạng mới / 9 < 80%")
    }

    func testCountersSaturateKeepingRatio() {
        var c = CaseTable()
        for _ in 0..<600 { c.observe("VietTelex", key: "viettelex", priorCount: 0) }
        let s = try! XCTUnwrap(c.stats["viettelex"])
        XCTAssertLessThanOrEqual(s.total, CaseTable.maxCount)
        XCTAssertEqual(s.hits, s.total)
        XCTAssertEqual(c.preferred("viettelex"), "VietTelex")
        XCTAssertEqual(CaseTable.kind("iPhone"), .mixed)
        XCTAssertEqual(CaseTable.kind("Đà"), .mixed)
        XCTAssertEqual(CaseTable.kind("ĐÀ"), .ignored)
        XCTAssertEqual(CaseTable.kind("đà"), .lower)
    }

    func testRecordWithoutEvidenceNeverTouchesCaseTable() {
        let m = UserLangModel(appGroup: nil)
        for _ in 0..<5 { m.record(word: "SenPrints", after: "ở") }   // mặc định caseEvidence=false
        XCTAssertEqual(m.debugCaseCount, 0)
        XCTAssertNil(m.learnedCase("senprints"))
    }

    // MARK: xoá

    func testClearLearnedWordsClearsCasing() {
        let m = UserLangModel(appGroup: nil)
        type(m, "Văn", after: "anh", times: 3)
        type(m, "SenPrints", after: "ở", times: 3)
        XCTAssertTrue(m.removeWord("văn"))
        XCTAssertNil(m.learnedCase("văn"))
        XCTAssertEqual(m.learnedCase("senprints"), "SenPrints")
        m.eraseAll()
        XCTAssertNil(m.learnedCase("senprints"))
        XCTAssertEqual(m.debugCaseCount, 0)
    }

    func testEraseAllRemovesCasingFromDisk() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("userlm.plist")
        let m = UserLangModel(fileURL: url, synchronous: true)
        type(m, "SenPrints", after: "ở", times: 3)
        m.saveSync()
        UserLangModel.removeStore(at: url)                  // nút "Xoá từ đã học" của app
        let r = UserLangModel(fileURL: url, synchronous: true)
        XCTAssertNil(r.learnedCase("senprints"))
    }

    func testDecayPruneDropsCasingOfForgottenWords() {
        let m = UserLangModel(appGroup: nil)
        type(m, "Văn", after: "anh", times: 3)
        m.decayIfDue(now: Date().addingTimeInterval(52 * 7 * 86400))   // count → 0
        XCTAssertEqual(m.count(of: "văn"), 0)
        XCTAssertNil(m.learnedCase("văn"))
        XCTAssertEqual(m.debugCaseCount, 0)
    }

    // MARK: lưu

    func testPersistenceRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("userlm.plist")
        let m = UserLangModel(fileURL: url, synchronous: true)
        type(m, "SenPrints", after: "ở", times: 3)
        type(m, "Văn", after: "anh", times: 2)
        m.saveSync()
        let r = UserLangModel(fileURL: url, synchronous: true)
        XCTAssertEqual(r.learnedCase("senprints"), "SenPrints")
        XCTAssertNil(r.learnedCase("văn"))
        XCTAssertEqual(r.debugCaseStat("văn"), CaseStat(form: "Văn", hits: 2, total: 2))
        type(r, "Văn", after: "anh")                         // đếm tiếp sau khi nạp
        XCTAssertEqual(r.learnedCase("văn"), "Văn")
    }

    func testNoCasingKeepsOldBytesAndOldFilesLoad() throws {
        // Không có mục hoa/thường ⇒ flags = 0, byte y như định dạng cũ (fixture chéo nền tảng).
        let old = try Data(contentsOf: fixture("userlm-vtl2", "bin"))
        let d = try XCTUnwrap(UserLMCodec.decode(old))
        XCTAssertTrue(d.cases.isEmpty)
        XCTAssertEqual(UserLMCodec.encode(d.tables, lastDecay: d.lastDecay, manual: d.manual, cases: d.cases), old)
        XCTAssertEqual(old[6], 0); XCTAssertEqual(old[7], 0)
    }

    func testCrossPlatformCaseFixture() throws {
        // Dựng bằng Python (Scripts không đổi): words senprints/văn/nam, cases senprints (3,3), văn (1,21).
        let data = try Data(contentsOf: fixture("userlm-vtl2-case", "bin"))
        let d = try XCTUnwrap(UserLMCodec.decode(data))
        XCTAssertEqual(d.tables.uniDict(), ["senprints": 3, "văn": 21, "nam": 4])
        XCTAssertEqual(d.cases.stats["senprints"], CaseStat(form: "SenPrints", hits: 3, total: 3))
        XCTAssertEqual(d.cases.stats["văn"], CaseStat(form: "Văn", hits: 1, total: 21))
        XCTAssertNil(d.cases.stats["nam"])
        XCTAssertEqual(d.cases.preferred("senprints"), "SenPrints")
        XCTAssertNil(d.cases.preferred("văn"))
        XCTAssertEqual(UserLMCodec.encode(d.tables, lastDecay: d.lastDecay, manual: d.manual, cases: d.cases), data)
        // hỏng phần hoa/thường ⇒ nil (CRC / biên)
        for i in stride(from: data.count - 30, to: data.count, by: 1) {
            var bad = data; bad[i] ^= 0x40
            XCTAssertNil(UserLMCodec.decode(bad), "byte \(i)")
        }
    }

    func testCodecRejectsInvalidCaseRows() {
        var t = UserLMTables()
        t.setUni(t.intern("văn"), 5)
        t.setUni(t.intern("senprints"), 3)
        let good = UserLMCodec.encode(t, lastDecay: Date(timeIntervalSince1970: 0), manual: [],
                                      cases: CaseTable(["văn": CaseStat(form: "Văn", hits: 2, total: 6),
                                                        "senprints": CaseStat(form: "SenPrints", hits: 3, total: 3)]))
        XCTAssertEqual(good[6], 1, "flags bit 0")
        XCTAssertEqual(UserLMCodec.decode(good)?.cases.count, 2)
        // mục của từ không có trong bảng ⇒ không ghi
        let orphan = UserLMCodec.encode(t, lastDecay: Date(timeIntervalSince1970: 0), manual: [],
                                        cases: CaseTable(["xyz": CaseStat(form: "Xyz", hits: 3, total: 3)]))
        XCTAssertEqual(orphan[6], 0)
        // hits > total ⇒ nil (sửa byte rồi tính lại CRC)
        func patched(_ d: Data, _ edit: (inout [UInt8]) -> Void) -> Data {
            var b = [UInt8](d.dropLast(4)); edit(&b)
            let c = UserLMCodec.crc32(b)
            return Data(b + [UInt8(c & 0xFF), UInt8(c >> 8 & 0xFF), UInt8(c >> 16 & 0xFF), UInt8(c >> 24)])
        }
        let n = good.count - 4
        XCTAssertNotNil(UserLMCodec.decode(patched(good) { _ in }))
        XCTAssertNil(UserLMCodec.decode(patched(good) { $0[n - 4] = 9; $0[n - 3] = 0 }), "hits > total")
        XCTAssertNil(UserLMCodec.decode(patched(good) { $0[n - 2] = 0; $0[n - 1] = 0 }), "total 0")
        XCTAssertNil(UserLMCodec.decode(patched(good) { $0[6] = 0 }), "flag tắt mà còn dữ liệu")
    }

    private func fixture(_ name: String, _ ext: String) throws -> URL {
        try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: ext))
    }

    // MARK: vuốt — DisplayCase + Shift + học

    func testSwipeCaseAppliesProperFormThenShift() {
        let proper: (String) -> String = { DisplayCase.resolve($0) }
        XCTAssertEqual(SwipeCase.lower.apply("iphone", proper: proper), "iPhone")
        XCTAssertEqual(SwipeCase.capitalized.apply("iphone", proper: proper), "iPhone", "không hạ / không đổi dạng hoa")
        XCTAssertEqual(SwipeCase.upper.apply("iphone", proper: proper), "IPHONE")
        XCTAssertEqual(SwipeCase.lower.apply("london", proper: proper), "London")
        XCTAssertEqual(SwipeCase.lower.apply("nguyễn", proper: proper), "Nguyễn")
        XCTAssertEqual(SwipeCase.capitalized.apply("chào", proper: proper), "Chào")
        XCTAssertEqual(SwipeCase.lower.apply("chào", proper: proper), "chào")
        let chain: (String) -> String = { DisplayCase.resolve($0, after: "việt") }
        XCTAssertEqual(SwipeCase.lower.apply("nam", proper: chain), "Nam")
        XCTAssertEqual(SwipeCase.upper.apply("nam", proper: chain), "NAM")
        let learned: (String) -> String = { DisplayCase.resolve($0, learned: { $0 == "văn" ? "Văn" : nil }) }
        XCTAssertEqual(SwipeCase.lower.apply("văn", proper: learned), "Văn")
        XCTAssertEqual(SwipeCase.capitalized.apply("văn", proper: learned), "Văn")
        XCTAssertEqual(SwipeCase.upper.apply("văn", proper: learned), "VĂN")
        XCTAssertEqual(SwipeCase.capitalized.apply("chào"), "Chào", "API cũ chỉ Shift")
    }

    func testPickAppliesDisplayCaseLikeBar() {
        let en = [SwipeCandidate(folded: "iphone", score: 0, lang: .en)]
        XCTAssertEqual(SwipeTyping.pick(en, context: .init(next: []), case: .lower)?.word, "iPhone")
        XCTAssertEqual(SwipeTyping.pick(en, context: .init(next: []), case: .capitalized)?.word, "iPhone")
        XCTAssertEqual(SwipeTyping.pick(en, context: .init(next: []), case: .upper)?.word, "IPHONE")
        // ô địa chỉ / tìm kiếm: chỉ Shift
        XCTAssertEqual(SwipeTyping.pick(en, context: .init(next: [], properNouns: false), case: .lower)?.word, "iphone")
        // học được: từ tiếng Anh ngoài DisplayCase
        let lark = [SwipeCandidate(folded: "lark", score: 0, lang: .en)]
        XCTAssertEqual(SwipeTyping.pick(lark, context: .init(next: []), case: .lower)?.word, "lark")
        let ctx = SwipeTyping.Context(next: [], learnedCase: { $0 == "lark" ? "Lark" : nil })
        XCTAssertEqual(SwipeTyping.pick(lark, context: ctx, case: .lower)?.word, "Lark")
    }
}

/// Luồng vuốt đầy đủ qua EngineBridge: "viet nam" → "Việt Nam" (chuỗi tên riêng hoa luôn từ vuốt trước).
final class SwipeProperCaseFlowTests: XCTestCase {
    private let layout = SwipeLayout.qwerty(keyWidth: 39, rowHeight: 54)

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

    func testSwipeVietNamCapitalizesChain() throws {
        let s = SwipeTyping()
        s.setLayout(layout, prepare: false)
        let b = EngineBridge(settings: KeyboardSettings()), p = MockProxy()
        p.text = "tôi yêu "
        let first = try XCTUnwrap(s.finish(path("viet"), case: .lower, contextWords: ["việt"], prev: "yêu",
                                           bridge: b, proxy: p))
        XCTAssertEqual(first.word, "việt")
        XCTAssertEqual(p.text, "tôi yêu việt")
        let prev = SwipeTyping.Revisable(word: first.word, scored: first.scored, sc: .lower)
        let out = try XCTUnwrap(s.finish(path("nam"), case: .lower, contextWords: ["nam"], prev: "việt",
                                         prev2: "yêu", previous: prev, bridge: b, proxy: p))
        XCTAssertEqual(out.word, "Nam")
        XCTAssertEqual(p.text, "tôi yêu Việt Nam")
        XCTAssertEqual(out.revised, SwipeTyping.Revision(old: "việt", new: "Việt"))
        XCTAssertEqual(out.committed?.word, "Việt")
    }

    func testSwipeProperNounWithShiftAndCaps() throws {
        let s = SwipeTyping()
        s.setLayout(layout, prepare: false)
        for (sc, want) in [(SwipeCase.lower, "London"), (.capitalized, "London"), (.upper, "LONDON")] {
            let b = EngineBridge(settings: KeyboardSettings()), p = MockProxy()
            let out = s.finish(path("london"), case: sc, contextWords: [], english: SwipeLangContext.onlyEnglishPrior,
                               englishOnly: true, bridge: b, proxy: p)
            XCTAssertEqual(out?.word, want, "\(sc)")
        }
    }
}
