// EngineBridge unit tests — a scripted mock proxy records the exact
// deleteBackward/insertText stream, so the whole iOS typing path (minus UIKit)
// is verified against the real engine.
import XCTest
import TelexCore

final class MockProxy: TextProxyLike {
    var text = ""
    var isSecure = false
    /// Mô phỏng context host báo: nil (mặc định) = đúng text thật; .some(nil) = host
    /// trả nil; .some("…") = host báo context LỆCH (con trỏ dời, host gán lại text…).
    var fakeContext: String?? = nil
    var contextBeforeInput: String? { fakeContext ?? text }
    /// Chữ sau con trỏ (con trỏ đứng giữa `text` và `textAfter`). fakeAfter như fakeContext.
    var textAfter = ""
    var fakeAfter: String?? = nil
    var contextAfterInput: String? { fakeAfter ?? textAfter }
    var hasSelection = false
    func insertText(_ t: String) { text += t }
    func deleteBackward() { if !text.isEmpty { text.removeLast() } }
}

final class EngineBridgeTests: XCTestCase {

    private func type(_ keys: String, secure: Bool = false,
                      settings: KeyboardSettings = KeyboardSettings()) -> String {
        let proxy = MockProxy()
        proxy.isSecure = secure
        let bridge = EngineBridge(settings: settings)
        for ch in keys {
            if ch == " " { bridge.boundary(" ", proxy: proxy) }
            else if ch == "⌫" { bridge.backspace(proxy: proxy) }
            else { bridge.letter(ch, proxy: proxy) }
        }
        return proxy.text
    }

    /// Ranh giới là mọi phím không phải chữ (số, "_", "/"…), như bàn phím thật.
    private func typeAll(_ keys: String, settings: KeyboardSettings = KeyboardSettings()) -> String {
        let proxy = MockProxy()
        let bridge = EngineBridge(settings: settings)
        for ch in keys {
            if ch == "⌫" { bridge.backspace(proxy: proxy) }
            else if ch.isLetter { bridge.letter(ch, proxy: proxy) }
            else { bridge.boundary(String(ch), proxy: proxy) }
        }
        return proxy.text
    }

    /// Issue #169: `d` khi con trỏ dính liền sau một từ bắt đầu bằng d gạch đ cho từ đó;
    /// sau dấu cách (kể cả dấu cách treo sau từ vuốt) `d` vẫn mở từ mới.
    func testStrokeKeyEditsGluedWordStartingWithD() {
        func glued(_ word: String, _ keys: String) -> String {
            let p = MockProxy(); p.text = word
            let b = EngineBridge(settings: KeyboardSettings())
            for ch in keys { b.letter(ch, proxy: p) }
            return p.text
        }
        XCTAssertEqual(glued("dùng", "d"), "đùng")
        XCTAssertEqual(glued("dùng", "ds"), "đúng")
        XCTAssertEqual(glued("Dung", "d"), "Đung")
        XCTAssertEqual(glued("co", "d"), "cod")          // không bắt đầu bằng d ⇒ nối chữ như cũ
        XCTAssertEqual(glued("ban", "d"), "band")
        XCTAssertEqual(glued("to", "o"), "too")          // a/e/o vẫn không sửa (26/09/2026)
        XCTAssertEqual(glued("đúng", "d"), "đúngd")      // đã có đ: không có gì để gạch
        var vni = KeyboardSettings(); vni.vniMode = true
        let p = MockProxy(); p.text = "dùng"
        EngineBridge(settings: vni).letter("d", proxy: p)
        XCTAssertEqual(p.text, "dùngd")                  // VNI: d là chữ thường
        // Từ vuốt: `d` ngay sau vẫn là từ mới ("dùng đi"); xoá về dính liền rồi mới sửa.
        let q = MockProxy(); let b = EngineBridge(settings: KeyboardSettings())
        b.insertSwipeWord("dùng", proxy: q)
        for ch in "ddi" { b.letter(ch, proxy: q) }
        XCTAssertEqual(q.text, "dùng đi")
        let r = MockProxy(); let c = EngineBridge(settings: KeyboardSettings())
        c.insertSwipeWord("dùng", proxy: r)
        c.letter("d", proxy: r)
        XCTAssertEqual(r.text, "dùng d")
        c.backspace(proxy: r); c.backspace(proxy: r)
        XCTAssertEqual(r.text, "dùng")
        c.letter("d", proxy: r); c.letter("s", proxy: r)
        XCTAssertEqual(r.text, "đúng")
    }

    /// Dấu nháy là ranh giới của từ viết tắt tiếng Anh (07/11/2026; = TelexCore
    /// ContractionCapsReopenTests): bridge chuyển ký tự ranh giới cho engine ⇒ "doesn't" giữ
    /// nguyên, không "doén't"; từ Việt trong nháy giữ dấu.
    func testContractionAtApostrophe() {
        for retro in [false, true] {
            var st = KeyboardSettings()
            st.contextualEnglish = retro
            st.retroEnglishAuto = retro
            XCTAssertEqual(typeAll("it doesn't ", settings: st), "it doesn't ")
            XCTAssertEqual(typeAll("isn't won't there's ", settings: st), "isn't won't there's ")
            XCTAssertEqual(typeAll("'tieesng' ", settings: st), "'tiếng' ")
        }
    }

    /// Viết tắt toàn chữ HOA, từ dính "_"/số (30/10/2026; = TelexCore) — có hay không sửa ngược.
    func testAcronymAndGluedWords() {
        for retro in [false, true] {
            var st = KeyboardSettings()
            st.contextualEnglish = retro
            st.retroEnglishAuto = retro
            XCTAssertEqual(typeAll("NAS ", settings: st), "NAS ")             // "NÁ" hiếm ⇒ viết tắt
            XCTAssertEqual(typeAll("VIEEJT NAM ", settings: st), "VIỆT NAM ")
            XCTAssertEqual(typeAll("DDAF NAWXNG ", settings: st), "ĐÀ NẴNG ")
            XCTAssertEqual(typeAll("my_var ", settings: st), "my_var ")       // không "my_vả"
            XCTAssertEqual(typeAll("vaf/hoawcj ", settings: st), "và/hoặc ")
            XCTAssertEqual(typeAll("100W ", settings: st), "100W ")           // không "100Ư"
            XCTAssertEqual(typeAll("5trawm ", settings: st), "5trăm ")
        }
    }

    func testBasicVietnamese() {
        XCTAssertEqual(type("vieetj "), "việt ")
        XCTAssertEqual(type("Tieengs Vieetj raats hay "), "Tiếng Việt rất hay ")
        XCTAssertEqual(type("dduwowngf "), "đường ")
    }

    func testAutoRestoreAndCollisions() {
        XCTAssertEqual(type("google "), "google ")
        // Chính sách 2026-07-23: collision THẬT thì tiếng Việt thắng (his ≡ hí)
        XCTAssertEqual(type("his "), "hí ")
        // POLICY V2 (31/07/2026): gõ đúp CUỐI từ = huỷ dấu, giữ composed (off→of)
        XCTAssertEqual(type("off "), "of ")
        XCTAssertEqual(type("Deffault "), "Default ")   // cancel keeps composed
    }

    func testBackspace() {
        XCTAssertEqual(type("vieetj⌫"), "việ")
        XCTAssertEqual(type("toans⌫"), "tóa")       // tone re-render on delete (old-style placement)
        XCTAssertEqual(type("a⌫"), "")
        XCTAssertEqual(type("⌫"), "")               // empty engine → plain delete
    }

    func testSecureFieldBypassesEngine() {
        XCTAssertEqual(type("vieejt ", secure: true), "vieejt ")
    }

    func testResetDropsComposition() {
        let proxy = MockProxy()
        let bridge = EngineBridge(settings: KeyboardSettings())
        for ch in "vie" { bridge.letter(ch, proxy: proxy) }
        bridge.reset()
        // new word starts clean: 'e' does not merge into the abandoned "vie"
        for ch in "em" { bridge.letter(ch, proxy: proxy) }
        bridge.boundary(" ", proxy: proxy)
        XCTAssertEqual(proxy.text, "vieem ")
    }

    func testSettingsRespected() {
        var s = KeyboardSettings()
        s.simpleTelex = true
        XCTAssertEqual(type("cw ", settings: s), "cw ")   // simple: lone w stays
        s.simpleTelex = false
        XCTAssertEqual(type("nhw ", settings: s), "như ")
    }

    /// Quyết định theo ngữ cảnh (như macOS, mặc định bật).
    func testContextualEnglish() {
        var s = KeyboardSettings()
        XCTAssertTrue(s.contextualEnglish)
        XCTAssertEqual(type("he is ", settings: s), "he is ")
        XCTAssertEqual(type("sao is ", settings: s), "sao í ")
        s.contextualEnglish = false
        XCTAssertEqual(type("he is ", settings: s), "he í ")
    }

    /// Issue #94 (25/09/2026): teencode spelling is a toggle, default OFF like macOS.
    func testTeencodeToggle() {
        var s = KeyboardSettings()                    // iOS default: Simple Telex ON
        XCTAssertFalse(s.teencode)
        XCTAssertEqual(type("was ", settings: s), "was ")     // English survives
        XCTAssertEqual(type("kos ", settings: s), "kos ")
        s.teencode = true
        XCTAssertEqual(type("was ", settings: s), "wá ")      // chat spelling = quá
        XCTAssertEqual(type("kos ", settings: s), "kó ")
        XCTAssertEqual(type("thiks ", settings: s), "thík ")
    }

    /// Issue #166 (18/11/2026): "Tự thêm dấu mũ" — công tắc, mặc định TẮT như macOS.
    func testAutoCircumflexToggle() {
        var s = KeyboardSettings()
        XCTAssertFalse(s.autoCircumflex)
        s.autoCircumflex = true
        XCTAssertEqual(type("vietj ", settings: s), "việt ")
        XCTAssertEqual(type("benhj ", settings: s), "bệnh ")
        XCTAssertEqual(type("nguyenx ", settings: s), "nguyễn ")
        XCTAssertEqual(type("quan ", settings: s), "quan ")      // vần không mũ có thật: giữ nguyên
    }
}

final class SuggestionTests: XCTestCase {
    func testEmojiSameForViAndEn() {
        // "love"/"yêu" → 3 ứng viên giống nhau (❤️ 💕 💗), như stock QuickType
        XCTAssertEqual(EmojiSuggest.emojis(for: "love").count, 3)
        XCTAssertEqual(EmojiSuggest.emojis(for: "yêu"), EmojiSuggest.emojis(for: "love"))
        XCTAssertEqual(EmojiSuggest.emojis(for: "mèo"), EmojiSuggest.emojis(for: "cat"))
        XCTAssertTrue(EmojiSuggest.emojis(for: "").isEmpty)
    }

    func testInlineDiacriticCompatibleMatch() {
        // spec user 2026-07-24: "to" khớp mọi biến thể; "tô" chỉ khớp họ ô
        let to = VNSuggest.matches("to").map { $0.word }
        XCTAssertTrue(to.contains("tôi"))
        XCTAssertTrue(to.contains("toàn"))
        let toCirc = VNSuggest.matches("tô").map { $0.word }
        XCTAssertTrue(toCirc.contains("tôi"))
        XCTAssertTrue(toCirc.contains("tối") || toCirc.contains("tồi") || toCirc.contains("tội"))
        XCTAssertFalse(toCirc.contains("toàn"))     // quality đã chốt ô
        XCTAssertFalse(toCirc.contains("tơi"))      // ơ ≠ ô
        // tone đã chốt huyền: loại ngang/sắc; quality chưa chốt nên "tồi" vẫn hợp lệ
        let toGrave = VNSuggest.matches("tò").map { $0.word }
        XCTAssertTrue(toGrave.contains("tòa"))
        XCTAssertFalse(toGrave.contains("tôi"))     // ngang ≠ huyền
        XCTAssertFalse(toGrave.contains("tới"))     // sắc ≠ huyền
        // 1 phím: hot-path bucket có kết quả tần suất cao
        XCTAssertTrue(VNSuggest.matches("t").map { $0.word }.contains("tôi"))
        // nguoi → người đứng top nhờ tần suất
        XCTAssertEqual(VNSuggest.matches("nguoi").first?.word, "người")
        // contains: lexicon membership
        XCTAssertTrue(VNSuggest.contains("người"))
        XCTAssertFalse(VNSuggest.contains("nguo"))
    }
}

final class UserLangModelTests: XCTestCase {
    private func freshModel() -> UserLangModel {
        let m = UserLangModel(appGroup: nil)   // in-memory
        m.isKnownWord = { _ in true }          // tests ranking không dính threshold
        return m
    }

    func testLearnAndSuggest() {
        let m = freshModel()
        for _ in 0..<3 { m.record(word: "anh", after: nil) }
        for _ in 0..<3 { m.record(word: "ơi", after: "anh") }
        m.record(word: "đang", after: "anh")
        m.record(word: "chào", after: nil)
        // đầu câu: top từ hay dùng
        XCTAssertEqual(m.topWords(limit: 1), ["anh"])
        // sau "anh": bigram cá nhân thắng, seed vẫn có mặt
        let next = m.nextWords(after: "anh", limit: 4)
        XCTAssertEqual(next.first, "ơi")
        XCTAssertTrue(next.contains("đang"))
        // seed thuần khi chưa học gì
        XCTAssertEqual(freshModel().nextWords(after: "cảm", limit: 1), ["ơn"])
        // shrinkage: MỘT lần gõ nhầm không đè nổi seed đầu bảng
        let m2 = freshModel()
        m2.record(word: "xong", after: "cảm")
        XCTAssertEqual(m2.nextWords(after: "cảm", limit: 1), ["ơn"])
        // không học rác
        m.record(word: "abc123", after: "anh")
        XCTAssertEqual(m.count(of: "abc123"), 0)
        XCTAssertFalse(UserLangModel.learnable("heeeyyy"))
    }

    func testTrigramContext(){
        let m = freshModel()
        // nền bigram (cảm→ơn) đủ 2 rồi trigram (cảm,ơn)→nhiều mới được ghi
        for _ in 0..<2 { m.record(word: "ơn", after: "cảm") }
        for _ in 0..<3 { m.record(word: "nhiều", after: "ơn", prev2: "cảm") }
        m.record(word: "anh", after: "ơn", prev2: "cảm")
        XCTAssertEqual(m.nextWords(after: "ơn", prev2: "cảm", limit: 1), ["nhiều"])
    }

    func testUnknownWordThreshold() {
        let m = UserLangModel(appGroup: nil)   // isKnownWord = false mặc định
        m.record(word: "blib", after: nil)
        m.record(word: "blib", after: nil)
        XCTAssertTrue(m.topWords(limit: 3).isEmpty)      // 2 lần: chưa được gợi ý
        m.record(word: "blib", after: nil)
        XCTAssertEqual(m.topWords(limit: 3), ["blib"])   // lần 3: đủ ngưỡng
    }

    func testTriggerExpansion() {
        // research 2026-07-24: done/xong/hoàn thành cùng bộ với đúng
        XCTAssertEqual(EmojiSuggest.emojis(for: "done"), EmojiSuggest.emojis(for: "đúng"))
        XCTAssertEqual(EmojiSuggest.emojis(for: "xong"), EmojiSuggest.emojis(for: "đúng"))
        XCTAssertEqual(EmojiSuggest.emojis(for: "hoàn thành"), EmojiSuggest.emojis(for: "đúng"))
        XCTAssertEqual(EmojiSuggest.emojis(for: "failed"), EmojiSuggest.emojis(for: "sai"))
        XCTAssertFalse(EmojiSuggest.emojis(for: "trời ơi").isEmpty)   // cụm 2 token
        XCTAssertFalse(EmojiSuggest.emojis(for: "hoan thanh").isEmpty) // folded cụm
    }

    func testEmojiFoldedKeys() {
        // gõ mộc không dấu cũng ra emoji: yeu ≡ yêu
        XCTAssertEqual(EmojiSuggest.emojis(for: "yeu"), EmojiSuggest.emojis(for: "yêu"))
        XCTAssertFalse(EmojiSuggest.emojis(for: "meo").isEmpty)
    }
}

final class SeedDataTests: XCTestCase {
    func testSeedInjection() {
        let m = UserLangModel(appGroup: nil)
        m.seedIfEmpty(unigrams: SeedData.unigrams, bigrams: SeedData.bigrams)
        // seed nạp được và có mặt trong gợi ý
        XCTAssertFalse(m.topWords(limit: 3).isEmpty)
        XCTAssertTrue(m.nextWords(after: "cảm", limit: 2).contains("ơn"))
        XCTAssertTrue(m.nextWords(after: "hôm", limit: 2).contains("nay"))
        // đã có dữ liệu → seed lần hai là no-op
        let before = m.count(of: "không")
        m.seedIfEmpty(unigrams: ["xxx": 99], bigrams: [])
        XCTAssertEqual(m.count(of: "không"), before)
        XCTAssertEqual(m.count(of: "xxx"), 0)
        // weight hợp đồng: max seed ≤ 50
        XCTAssertLessThanOrEqual(SeedData.unigrams.values.max() ?? 0, 50)
    }
}

final class DisplayCaseTests: XCTestCase {
    func testProperNounDisplay() {
        XCTAssertEqual(DisplayCase.apply("senprints"), "SenPrints")
        XCTAssertEqual(DisplayCase.apply("printik"), "Printik")
        XCTAssertEqual(DisplayCase.apply("iphone"), "iPhone")
        XCTAssertEqual(DisplayCase.apply("macos"), "macOS")
        XCTAssertEqual(DisplayCase.apply("nguyễn"), "Nguyễn")
        XCTAssertEqual(DisplayCase.apply("github"), "GitHub")
        XCTAssertEqual(DisplayCase.apply("chatgpt"), "ChatGPT")
        XCTAssertEqual(DisplayCase.apply("claude"), "Claude")
        // từ thường giữ nguyên; token nhập nhằng KHÔNG được hoa
        XCTAssertEqual(DisplayCase.apply("cảm"), "cảm")
        XCTAssertEqual(DisplayCase.apply("trang"), "trang")
        // theo ngữ cảnh chuỗi: hà→Nội, nha→Trang; đơn lẻ vẫn thường
        XCTAssertEqual(DisplayCase.apply("nội", after: "hà"), "Nội")
        XCTAssertEqual(DisplayCase.apply("nội", after: "Hà"), "Nội")
        XCTAssertEqual(DisplayCase.apply("nội"), "nội")
        XCTAssertEqual(DisplayCase.apply("trang", after: "nha"), "Trang")
        XCTAssertEqual(DisplayCase.apply("văn", after: "nguyễn"), "Văn")
        XCTAssertEqual(DisplayCase.apply("văn"), "văn")
        XCTAssertEqual(DisplayCase.apply("vũ"), "vũ")
    }

    func testLearningStaysCaseFolded() {
        // bấm nhận "SenPrints" → datastore vẫn đếm dưới khóa thường
        let m = UserLangModel(appGroup: nil)
        m.record(word: "SenPrints", after: nil)
        XCTAssertEqual(m.count(of: "senprints"), 1)
        XCTAssertEqual(m.count(of: "SenPrints"), 1)   // count(of:) tự lowercase
    }
}

/// Feedback 10/2026: bật Shift mà gợi ý không viết hoa như Gboard. SuggestionCase thuần
/// (song sinh Android SuggestionCaseTests).
final class SuggestionCaseTests: XCTestCase {
    private func d(_ w: String, _ s: SuggestionCase.Shift, _ typed: String = "") -> String {
        SuggestionCase.display(w, shift: s, typed: typed)
    }

    /// Chưa gõ (gợi ý từ kế tiếp): Shift tắt / một-lần / Caps Lock.
    func testShiftStatesWithEmptyComposing() {
        XCTAssertEqual(d("bên", .off), "bên")
        XCTAssertEqual(d("bên", .once), "Bên")
        XCTAssertEqual(d("bên", .capsLock), "BÊN")
        // chữ Việt: đ/ư/ơ/ă có dạng hoa dựng sẵn
        XCTAssertEqual(d("đi", .once), "Đi")
        XCTAssertEqual(d("đường", .capsLock), "ĐƯỜNG")
        XCTAssertEqual(d("ước", .once), "Ước")
        XCTAssertEqual(d("ăn", .once), "Ăn")
        // NFD (dấu tổ hợp) vẫn hoa đúng cụm đầu
        XCTAssertEqual(d("e\u{0300}m", .once), "E\u{0300}m")
    }

    /// Đang gõ dở: hoa/thường theo chữ đã gõ, Shift (một-lần) không còn quyết định.
    func testTypedPrefixCasingWins() {
        XCTAssertEqual(d("bên", .off, "Bê"), "Bên")
        XCTAssertEqual(d("bên", .off, "B"), "Bên")
        XCTAssertEqual(d("bên", .off, "BÊ"), "BÊN")
        XCTAssertEqual(d("bên", .off, "bê"), "bên")
        XCTAssertEqual(d("bên", .once, "bê"), "bên")       // shift bật giữa từ: cho phím kế
        XCTAssertEqual(d("bên", .capsLock, "B"), "BÊN")    // Caps: 1 chữ cũng HOA HẾT
        XCTAssertEqual(d("đường", .off, "Đư"), "Đường")
        XCTAssertEqual(d("đường", .off, "ĐƯ"), "ĐƯỜNG")
        XCTAssertEqual(d("bên", .off, "bÊ"), "bên")        // chữ đầu thường ⇒ giữ
    }

    /// Không phá tên riêng / viết tắt / emoji / số / chip URL-email.
    func testLeavesSpecialCandidatesAlone() {
        XCTAssertEqual(d("iPhone", .once), "iPhone")
        XCTAssertEqual(d("SenPrints", .once), "SenPrints")
        XCTAssertEqual(d("FPT", .once), "FPT")
        XCTAssertEqual(d("Nguyễn", .off), "Nguyễn")
        XCTAssertEqual(d("iPhone", .capsLock), "IPHONE")
        XCTAssertEqual(d("😀", .once), "😀")
        XCTAssertEqual(d("😀", .capsLock), "😀")
        XCTAssertEqual(d("100.000", .capsLock), "100.000")
        XCTAssertEqual(d("@gmail.com", .capsLock), "@gmail.com")
        XCTAssertEqual(d("", .once), "")
    }

    func testModeTable() {
        XCTAssertEqual(SuggestionCase.mode(shift: .off, typed: ""), .asIs)
        XCTAssertEqual(SuggestionCase.mode(shift: .once, typed: ""), .capitalized)
        XCTAssertEqual(SuggestionCase.mode(shift: .capsLock, typed: ""), .upper)
        XCTAssertEqual(SuggestionCase.mode(shift: .off, typed: "A"), .capitalized)
        XCTAssertEqual(SuggestionCase.mode(shift: .off, typed: "AB"), .upper)
        XCTAssertEqual(SuggestionCase.mode(shift: .off, typed: "Ab"), .capitalized)
    }
}

final class SensitiveWordsTests: XCTestCase {
    func testFilterGate() {
        let words = ["vcl", "vui", "đcm", "cảm"]
        XCTAssertEqual(SensitiveWords.filter(words, enabled: true), ["vui", "cảm"])
        XCTAssertEqual(SensitiveWords.filter(words, enabled: false), words)
        // từ bạo lực phổ thông KHÔNG bị lọc (từ vựng đời thường/báo chí)
        XCTAssertEqual(SensitiveWords.filter(["cướp", "giết"], enabled: true), ["cướp", "giết"])
    }

    /// Cặp tục/tình dục bổ sung 18/10/2026 (bú lồn, địt nhau, đéo biết, holy shit…): nằm trong seed nhưng
    /// bật lọc (mặc định) thì từ kế tiếp KHÔNG BAO GIỜ là từ nhạy cảm; tắt lọc mới hiện.
    func testSeedVulgarPairsGated() {
        XCTAssertTrue(Set(SensitiveWords.english).isSubset(of: SensitiveWords.set))
        for w in SensitiveWords.set { XCTAssertGreaterThan(SeedData.unigrams[w] ?? 0, 0, "từ lọc thiếu trong seed: \(w)") }
        XCTAssertFalse(SensitiveWords.set.contains("damn"), "từ nhẹ không lọc")
        let m = UserLangModel(appGroup: nil)
        m.isKnownWord = { VNSuggest.contains($0) }
        m.seedIfEmpty(unigrams: SeedData.unigrams, bigrams: SeedData.bigrams)
        for prev in Set(SeedData.bigrams.map(\.0)) {
            let on = SensitiveWords.filter(m.nextWords(after: prev, limit: 24), enabled: true)
            XCTAssertTrue(on.allSatisfy { !SensitiveWords.set.contains($0.lowercased()) }, "\(prev): \(on)")
        }
        XCTAssertEqual(SensitiveWords.filter(m.nextWords(after: "bú", limit: 6), after: "bú", enabled: true), ["đá"],
                       "bú cu: SensitivePairs; bú đá (tiếng lóng ma tuý) hiện")
        XCTAssertEqual(m.nextWords(after: "bú", limit: 6).first, "lồn")
        XCTAssertEqual(SensitiveWords.filter(m.nextWords(after: "đầu", limit: 3), enabled: true), ["tiên", "tư"])
        XCTAssertEqual(m.nextWords(after: "sờ", limit: 1), ["vào"], "chim/cu không đứng đầu sau sờ")
        XCTAssertEqual(m.nextWords(after: "nâng", limit: 1), ["cao"], "bi không đứng đầu sau nâng")
        XCTAssertEqual(m.nextWords(after: "thank", limit: 1), ["you"])
        XCTAssertEqual(SensitiveWords.filter(m.nextWords(after: "holy", limit: 3), enabled: true), [])
    }

    /// SensitivePairs (seed-curated [sensitive-bigram]): cặp chửi/tục ghép từ hai TỪ THƯỜNG. Bật lọc ⇒ với
    /// MỌI cặp (prev, word): từ kế tiếp sau prev (nextWords cá nhân/seed + SuggestRank.nextFill) không có
    /// word, cặp không thưởng ngữ cảnh vuốt (SwipeTyping.contextSet), không thưởng Thêm dấu; tắt lọc ⇒ có.
    func testSensitivePairsGated() {
        let m = UserLangModel(appGroup: nil)
        m.isKnownWord = { VNSuggest.contains($0) }
        m.seedIfEmpty(unigrams: SeedData.unigrams, bigrams: SeedData.bigrams)
        let pairs = SensitiveWords.pairs.flatMap { p, ws in ws.map { (p, $0) } }
        XCTAssertGreaterThanOrEqual(pairs.count, 30)
        let seedPairs = Set(SeedData.bigrams.map { "\($0.0) \($0.1)" })
        for (prev, w) in pairs {
            XCTAssertTrue(seedPairs.contains("\(prev) \(w)"), "cặp nhạy cảm phải có trong seed: \(prev) \(w)")
            XCTAssertFalse(SensitiveWords.set.contains(w))
            let raw = m.nextWords(after: prev, limit: 24)
            XCTAssertTrue(raw.contains(w), "tắt lọc: \(prev) → \(w) phải hiện (\(raw))")
            let on = SensitiveWords.filter(raw, after: prev, enabled: true)
            XCTAssertFalse(on.contains(w), "\(prev): \(on)")
            let next = SuggestRank.nextFill(prev, prev2: nil, personal: on, triCount: { _ in 0 },
                                            filter: { SensitiveWords.filter($0, after: prev, enabled: true) }, need: 5)
            XCTAssertFalse(next.contains(w), "nextFill \(prev): \(next)")
            XCTAssertFalse(SwipeTyping.contextSet(raw, prev: prev, filter: true).contains(w), "vuốt \(prev) → \(w)")
            XCTAssertTrue(SwipeTyping.contextSet(raw, prev: prev, filter: false).contains(w))
        }
        XCTAssertEqual(SensitiveWords.filter(m.nextWords(after: "sờ", limit: 6), after: "sờ", enabled: true), ["vào"])
        XCTAssertEqual(m.nextWords(after: "sờ", limit: 3), ["vào", "chim", "cu"])
        XCTAssertFalse(SensitiveWords.filter(m.nextWords(after: "nâng", limit: 6), after: "nâng", enabled: true).contains("bi"))
        XCTAssertFalse(SensitiveWords.filter(m.nextWords(after: "thằng", limit: 24), after: "Thằng", enabled: true).contains("chó"))
        XCTAssertEqual(m.nextWords(after: "đậu", limit: 1), ["má"])
        XCTAssertEqual(m.nextWords(after: "phang", limit: 1), ["nhau"])
        // giữ hiện cho mọi người: từ vựng trung tính
        for (a, b) in [("lăng", "nhăng"), ("lăng", "loàn"), ("hãm", "hiếp"), ("lừa", "đảo"), ("khốn", "nạn")] {
            XCTAssertFalse(SensitiveWords.isPair(a, b))
            XCTAssertTrue(SensitiveWords.filter(m.nextWords(after: a, limit: 24), after: a, enabled: true).contains(b), "\(a) \(b)")
        }
        // Thêm dấu: cặp nhạy cảm không thưởng khi lọc bật (closure như KeyboardViewController.addTonesPlan)
        let pair: (Bool) -> (String, String) -> Int = { fs in { fs && SensitiveWords.isPair($0, $1) ? 0 : m.bigramCount($0, $1) } }
        XCTAssertGreaterThan(pair(false)("sờ", "chim"), 0)
        XCTAssertEqual(pair(true)("sờ", "chim"), 0)
    }

    /// Chuỗi chửi BA từ (seed-curated [sensitive-trigram], 19/10/2026). Tắt lọc ⇒ từ thứ ba nằm trong 3 ô từ kế
    /// tiếp sau đúng hai từ đầu (người dùng mới: nextWords seed + SensitiveWords.chain + SuggestRank.nextFill);
    /// bật lọc ⇒ không ở đâu (từ kế tiếp, hoàn thành từ, ngữ cảnh vuốt); cặp thường cuối ("như chó", "mất dạy",
    /// "bã đậu"…) vẫn hiện khi bật lọc.
    static let insultChains = [
        "địt mẹ mày", "địt con mẹ", "con mẹ mày", "lồn mẹ mày", "thằng mặt lồn", "ngu như chó", "óc bã đậu",
        "bố tiên sư", "thằng mất dạy", "con mất dạy", "cái máu lồn", "đồ mất dạy", "con đĩ mẹ", "đĩ mẹ mày",
        "đụ má mày", "đụ mẹ mày", "đù má mày", "địt cụ mày", "đéo hiểu sao", "đéo quan tâm", "đéo ai thèm",
        "vãi cả lồn", "đồ mặt lồn", "đm cuộc đời", "đcm thằng này", "vcl thật sự", "mặt lồn ra", "mẹ kiếp mày",
        "tiên sư bố", "tổ cha mày", "mả cha mày", "mả mẹ mày", "cha mày chứ", "cút mẹ mày", "cút con mẹ",
        "thằng chó chết", "đồ chó má", "đồ con lợn", "đồ ăn hại", "đồ khốn nạn", "thằng khốn nạn", "ngu như bò",
        "ngu như lợn", "mặt dày vãi", "thằng ất ơ", "câm mồm lại", "im mồm đi", "bố mày đây", "ông mày đây",
    ]

    func testSensitiveTrigramChains() {
        let m = UserLangModel(appGroup: nil)
        m.isKnownWord = { VNSuggest.contains($0) }
        m.seedIfEmpty(unigrams: SeedData.unigrams, bigrams: SeedData.bigrams)
        func next(_ p2: String, _ p: String, _ fs: Bool, need: Int = 3) -> [String] {
            let personal = SensitiveWords.filter(m.nextWords(after: p, prev2: p2, limit: 6), after: p, prev2: p2, enabled: fs)
            let chain = SensitiveWords.filter(SensitiveWords.chain(after: p, prev2: p2), after: p, prev2: p2, enabled: fs)
            return SuggestRank.nextFill(p, prev2: p2, personal: personal, triCount: { m.trigramCount(p2, p, $0) },
                                        filter: { SensitiveWords.filter($0, after: p, prev2: p2, enabled: fs) },
                                        need: need, chain: chain)
        }
        for phrase in Self.insultChains {
            let w = phrase.split(separator: " ").map(String.init)
            XCTAssertTrue(next(w[0], w[1], false).contains(w[2]), "tắt lọc: \(phrase) — \(next(w[0], w[1], false))")
            XCTAssertFalse(next(w[0], w[1], true, need: 5).contains(w[2]), "bật lọc: \(phrase) — \(next(w[0], w[1], true, need: 5))")
            XCTAssertTrue(SensitiveWords.filter([w[2]], after: w[1], prev2: w[0], enabled: true).isEmpty, phrase)
            let ctx = m.nextWords(after: w[1], prev2: w[0], limit: 24)   // contextSet thêm chuỗi seed
            if SensitiveWords.isTriple(w[0], w[1], w[2]) {   // từ tục: vuốt đã bỏ theo từ (SwipeDecoder.expand)
                XCTAssertFalse(SwipeTyping.contextSet(ctx, prev: w[1], prev2: w[0], filter: true).contains(w[2]), "vuốt: \(phrase)")
            }
            if SensitiveWords.chain(after: w[1], prev2: w[0]).contains(w[2]) {
                XCTAssertTrue(SwipeTyping.contextSet(ctx, prev: w[1], prev2: w[0], filter: false).contains(w[2]), "vuốt tắt lọc: \(phrase)")
            }
        }
        // mọi bộ ba của bảng chặn: từ ba thường, cặp cuối không phải cặp nhạy cảm (chặn đúng mức BA từ)
        for (k, ws) in SensitiveWords.triples {
            let p = k.split(separator: " ").map(String.init)
            XCTAssertEqual(p.count, 2)
            for w in ws {
                XCTAssertFalse(SensitiveWords.set.contains(w), "\(k) \(w)")
                XCTAssertFalse(SensitiveWords.isPair(p[1], w), "\(k) \(w)")
                XCTAssertTrue(SensitiveWords.isTriple(p[0].uppercased(), p[1], w.uppercased()))
                XCTAssertEqual(SensitiveWords.dropPairs([w, "và"], after: p[1], prev2: p[0], enabled: true), ["và"])
                XCTAssertEqual(SensitiveWords.dropPairs([w], after: p[1], prev2: p[0], enabled: false), [w])
            }
        }
        // cặp thường vẫn hiện khi BẬT lọc (chỉ bộ ba bị chặn)
        for (p, w) in [("như", "chó"), ("mất", "dạy"), ("bã", "đậu"), ("tiên", "sư"), ("khốn", "nạn"), ("con", "lợn"),
                       ("ăn", "hại"), ("như", "bò"), ("mồm", "đi")] {
            XCTAssertFalse(SensitiveWords.isPair(p, w), "\(p) \(w)")
            XCTAssertEqual(SensitiveWords.filter([w], after: p, enabled: true), [w], "\(p) \(w)")
            XCTAssertEqual(SensitiveWords.filter([w], after: p, prev2: "anh", enabled: true), [w], "anh \(p) \(w)")
        }
        XCTAssertTrue(SensitiveWords.filter(m.nextWords(after: "mất", limit: 24), after: "mất", enabled: true).contains("dạy"))
        XCTAssertFalse(SeedData.bigrams.contains { $0.0 == "như" && $0.1 == "chó" }, "như chó bỏ khỏi seed (chặn ở bộ ba)")
        // lóng vui hiện cho mọi người
        XCTAssertEqual(next("vãi", "cả", true).first, "chưởng")
        XCTAssertEqual(next("não", "cá", true).first, "vàng")
    }

    /// Lô 2–3 (Phil 18/10/2026): tiếng lóng / từ báo chí (ma tuý, cờ bạc, mại dâm, tội phạm) và cảm thán nói
    /// tránh hiện cho mọi người; cặp nói thẳng tình dục / chửi ghép từ thường (kích dục, chơi cave, óc lợn,
    /// láo chó…) chỉ khi tắt lọc; cc / đb / lìn lọc theo từ.
    func testSlangAndInsultBatches() {
        let m = UserLangModel(appGroup: nil)
        m.isKnownWord = { VNSuggest.contains($0) }
        m.seedIfEmpty(unigrams: SeedData.unigrams, bigrams: SeedData.bigrams)
        func on(_ p: String) -> [String] { SensitiveWords.filter(m.nextWords(after: p, limit: 24), after: p, enabled: true) }
        XCTAssertEqual(on("lạng").first, "lách")
        XCTAssertEqual(on("sugar"), ["baby", "daddy"])
        XCTAssertEqual(on("karaoke").first, "tay")
        XCTAssertEqual(on("đếch").first, "biết")
        XCTAssertTrue(on("rửa").contains("tiền"))
        XCTAssertTrue(on("chơi").contains("coin"))
        for w in ["nồi", "đạn", "linh"] { XCTAssertTrue(on("vãi").contains(w), w) }
        for (p, w) in [("kích", "dục"), ("massage", "kích"), ("chơi", "cave"), ("chơi", "gái"), ("óc", "lợn"),
                       ("não", "phẳng"), ("láo", "chó"), ("quay", "tay"), ("phim", "heo"),
                       ("clip", "nóng"), ("lộ", "clip"), ("như", "cột"),
                       ("cái", "mâm"), ("lùn", "tịt"), ("cò", "hương"), ("chúa", "phòng")] {
            XCTAssertTrue(SensitiveWords.isPair(p, w))
            XCTAssertFalse(on(p).contains(w), "\(p) \(w)")
            XCTAssertTrue(m.nextWords(after: p, limit: 24).contains(w), "tắt lọc: \(p) \(w)")
        }
        // Phil bỏ lọc 18/10/2026: nghĩa đen quá thường ⇒ không phải SensitivePairs; "con chó" (corpus) và
        // "óc chó" (hạt) vẫn gợi ý khi BẬT lọc; "như heo/bò/lợn", "con gà" bỏ khỏi seed.
        for (p, w) in [("con", "chó"), ("con", "gà"), ("óc", "chó"), ("như", "heo"), ("như", "bò"), ("như", "lợn")] {
            XCTAssertFalse(SensitiveWords.isPair(p, w), "\(p) \(w)")
        }
        XCTAssertTrue(on("con").contains("chó"), "con → chó không bị lọc khi bật lọc")
        XCTAssertEqual(on("óc").first, "chó")
        for w in ["cc", "đb", "lìn"] { XCTAssertTrue(SensitiveWords.set.contains(w)); XCTAssertNotNil(SeedData.unigrams[w]) }
        // lô 4–5 hiện: tiếng lóng đời thường; cặp NEO giữ cách đọc thường đứng đầu sau từ rất thường
        for (p, w) in [("cà", "khịa"), ("trẻ", "trâu"), ("sống", "ảo"), ("gen", "z"), ("báo", "thủ"), ("ô", "dề"), ("xu", "cà"),
                       ("phong", "bì"), ("check", "var"), ("anti", "fan"), ("xin", "link"), ("phòng", "trọ"), ("que", "tăm"),
                       ("mong", "manh"), ("gầy", "như")] {
            XCTAssertTrue(on(p).contains(w), "\(p) \(w)")
        }
        for (p, w) in [("nước", "ngoài"), ("bóng", "đá"), ("cá", "nhân"), ("hàng", "hóa"), ("lên", "tới"), ("xin", "lỗi"),
                       ("khẩu", "trang"), ("đào", "tạo")] {
            XCTAssertEqual(on(p).first, w, p)
        }
        XCTAssertEqual(DisplayCase.resolve("z", after: "gen"), "Z")
        XCTAssertEqual(DisplayCase.resolve("canada", after: "ma"), "Canada")
        XCTAssertEqual(DisplayCase.resolve("gen"), "gen", "gen di truyền")
        XCTAssertEqual(on("gét").first, "gô")
        XCTAssertTrue(VNSuggest.contains("khum") && VNSuggest.contains("dề") && VNSuggest.contains("na"), "teencode trong vnlexicon (gõ + vuốt)")
        XCTAssertFalse(SensitiveWords.isPair("phòng", "trọ") || SensitiveWords.isPair("cột", "nhà") || SensitiveWords.isPair("nhà", "cháy"))
        XCTAssertFalse(SensitiveWords.set.contains("lol"), "LOL tiếng Anh")
        XCTAssertFalse(SensitiveWords.set.contains("đếch") || SensitiveWords.set.contains("méo"))
    }

    /// Tiền pháp định + mã tiền tệ (18/10/2026): "tiền pháp" → định; hiển thị USD/VNĐ/VND/USDT, Bitcoin;
    /// crypto/fiat giữ thường.
    func testFiatAndCurrencyCase() {
        let m = UserLangModel(appGroup: nil)
        m.isKnownWord = { VNSuggest.contains($0) }
        m.seedIfEmpty(unigrams: SeedData.unigrams, bigrams: SeedData.bigrams)
        XCTAssertEqual(m.nextWords(after: "pháp", prev2: "tiền", limit: 1), ["định"])
        XCTAssertTrue(m.nextWords(after: "tiền", limit: 3).contains("pháp"))
        for (w, d) in [("usd", "USD"), ("usdt", "USDT"), ("vnđ", "VNĐ"), ("vnd", "VND"), ("bitcoin", "Bitcoin"),
                       ("crypto", "crypto"), ("fiat", "fiat")] {
            XCTAssertEqual(DisplayCase.resolve(w), d)
            XCTAssertNotNil(SeedData.unigrams[w], w)
        }
        // công nghệ / AI / tài chính: enlexicon (gen-enlexicon SUPPLEMENT) + DisplayCase
        for (w, d) in [("gemini", "Gemini"), ("grok", "Grok"), ("ubuntu", "Ubuntu"), ("copilot", "Copilot"),
                       ("docker", "Docker"), ("kubernetes", "Kubernetes"), ("javascript", "JavaScript"),
                       ("typescript", "TypeScript"), ("llm", "LLM"), ("nft", "NFT"), ("etf", "ETF"), ("ipo", "IPO"),
                       ("defi", "DeFi"), ("chatgpt", "ChatGPT"), ("github", "GitHub"), ("cursor", "cursor"),
                       ("stablecoin", "stablecoin"), ("cloudflare", "Cloudflare"), ("golang", "Golang"), ("vpn", "VPN"),
                       ("kotlin", "Kotlin"), ("panadol", "Panadol"), ("viettelex", "VietTelex"), ("telex", "telex"),
                       ("keto", "keto"), ("rust", "rust")] {
            XCTAssertEqual(DisplayCase.resolve(w), d)
            XCTAssertTrue(SwipeEnglish.contains(w), "enlexicon: \(w)")
        }
        func on(_ p: String) -> [String] { SensitiveWords.filter(m.nextWords(after: p, limit: 24), after: p, enabled: true) }
        for (p, w) in [("bắt", "đáy"), ("đu", "đỉnh"), ("khối", "ngoại"), ("ví", "lạnh"), ("call", "margin"), ("vàng", "nhẫn")] {
            XCTAssertTrue(on(p).contains(w), "\(p) \(w)")
        }
        XCTAssertEqual(on("ví").first, "dụ", "NEO: ví dụ vẫn đứng đầu")
        // y tế
        for (p, w) in [("chụp", "x"), ("x", "quang"), ("tập", "gym"), ("hậu", "covid"), ("test", "nhanh"), ("sinh", "thường")] {
            XCTAssertTrue(on(p).contains(w), "\(p) \(w)")
        }
        XCTAssertEqual(DisplayCase.resolve("x", after: "chụp"), "X")
        XCTAssertEqual(DisplayCase.resolve("covid"), "Covid")
        // tác giả: Phil Trinh (không dấu sau Phil)
        XCTAssertEqual(on("phil").first, "trinh")
        XCTAssertEqual(DisplayCase.resolve("phil"), "Phil")
        XCTAssertEqual(DisplayCase.resolve("trinh", after: "Phil"), "Trinh")
        XCTAssertEqual(DisplayCase.resolve("trinh"), "trinh")
    }
}

final class SeedOrderTests: XCTestCase {
    func testEmptyFieldTop3() {
        let m = UserLangModel(appGroup: nil)
        m.isKnownWord = { _ in true }
        m.seedIfEmpty(unigrams: SeedData.unigrams, bigrams: SeedData.bigrams)
        XCTAssertEqual(m.topWords(limit: 3), ["em", "anh", "tôi"])
    }
}

/// Ô email (người nhận Gmail/Outlook, iOS 1.2.15): gõ tên tiếng Việt để tìm danh bạ, nhưng địa chỉ
/// phải đúng phím thô. Phím đi như controller: chữ → letter, số (VNI) → vniDigit rồi boundary,
/// ký hiệu/"@"/"." → boundary, "⌫" → backspace, "␣" → dấu cách. Song sinh Android EmailFieldTest.
final class EmailFieldBridgeTests: XCTestCase {
    private func bridge(email: Bool = true, passthrough: Bool = false,
                        settings: KeyboardSettings = KeyboardSettings()) -> EngineBridge {
        let b = EngineBridge(settings: settings)
        b.passthrough = passthrough
        b.emailField = email
        b.reachBackAllowed = !email
        b.shortcutsAllowed = !email
        return b
    }

    private func feed(_ keys: String, _ b: EngineBridge, _ p: MockProxy) {
        for ch in keys {
            switch ch {
            case "⌫": b.backspace(proxy: p)
            case "␣": b.boundary(" ", proxy: p)
            default:
                if ch.isLetter { b.letter(ch, proxy: p) }
                else if ch.isNumber, b.vniDigit(ch, proxy: p) {}
                else { b.boundary(String(ch), proxy: p) }
            }
        }
    }

    private func type(_ keys: String, email: Bool = true, passthrough: Bool = false,
                      settings: KeyboardSettings = KeyboardSettings()) -> String {
        let p = MockProxy()
        feed(keys, bridge(email: email, passthrough: passthrough, settings: settings), p)
        return p.text
    }

    func testVietnameseNameComposes() {
        XCTAssertEqual(type("Sown"), "Sơn")
        XCTAssertEqual(type("Nguyeenx␣Sown"), "Nguyễn Sơn")
        XCTAssertEqual(type("Sown,"), "Sơn,")
    }

    func testAddressesStayRaw() {
        XCTAssertEqual(type("phuc.nguyen@gmail.com"), "phuc.nguyen@gmail.com")
        XCTAssertEqual(type("dduc@vn.com"), "dduc@vn.com")
        XCTAssertEqual(type("tuan.anh@"), "tuan.anh@")
        XCTAssertEqual(type("nguyeenx@"), "nguyeenx@")           // quy tắc: đúng phím thô
        XCTAssertEqual(type("Sown.nguyeenx@gmail.com"), "Sown.nguyeenx@gmail.com")
        XCTAssertEqual(type("tuaans_anh1@vn.vn"), "tuaans_anh1@vn.vn")
        XCTAssertEqual(type("ddax-ddi+1@x.com"), "ddax-ddi+1@x.com")
        XCTAssertEqual(type("viet.nam"), "viet.nam")             // "." cũng khoá token
        XCTAssertEqual(type("hoaf@ddaif.vn"), "hoaf@ddaif.vn")
    }

    func testDigitsAndSymbolsComposeUntilMark() {
        XCTAssertEqual(type("tuaans_anh"), "tuấn_anh")           // chưa có @ / . ⇒ vẫn soạn
        XCTAssertEqual(type("tuaans_anh␣"), "tuấn_anh ")
    }

    func testTokenAfterSeparatorComposesAgain() {
        XCTAssertEqual(type("an@x.com,␣Sown"), "an@x.com, Sơn")
        XCTAssertEqual(type("an@x.com;Sown"), "an@x.com;Sơn")
        XCTAssertEqual(type("an@x.com␣Sown"), "an@x.com Sơn")
    }

    func testBackspaceInsideAddressAndAcrossMark() {
        XCTAssertEqual(type("ddu@⌫c"), "dduc")                  // xoá "@" ⇒ token lại là chữ
        XCTAssertEqual(type("ddu@⌫c@"), "dduc@")
        XCTAssertEqual(type("phuc@gmx⌫ail.com"), "phuc@gmail.com")
    }

    func testPasswordAndLiteralFieldsUnchanged() {
        XCTAssertEqual(type("Sown", passthrough: true), "Sown")          // ô URL/username: literal
        let p = MockProxy(); p.isSecure = true
        feed("Sown@", bridge(), p)
        XCTAssertEqual(p.text, "Sown@")                                    // mật khẩu
        XCTAssertEqual(type("Sown@", email: false), "Sơn@")               // ô thường: như cũ
    }

    func testNeverRewritesTextTheAppInserted() {
        // Gmail biến người nhận thành chip / chèn chữ: bridge reset, chữ có sẵn không bị viết lại.
        let p = MockProxy()
        let b = bridge()
        p.text = "Đức"                      // app chèn (không phải phím của mình)
        b.reset()
        feed("@vn.com", b, p)
        XCTAssertEqual(p.text, "Đức@vn.com")
        // host gán lại chữ trong lúc đang soạn (không báo): fail-safe, không xoá mù
        let q = MockProxy()
        let c = bridge()
        feed("dduc", c, q)
        q.text = "Đức Nguyễn <"
        feed("@", c, q)
        XCTAssertEqual(q.text, "Đức Nguyễn <@")
    }

    func testExistingAddressTokenStaysRawAfterReset() {
        let p = MockProxy()
        let b = bridge()
        p.text = "phuc@gmail.co"
        b.reset()                             // con trỏ dời tới cuối địa chỉ có sẵn
        feed("om", b, p)
        XCTAssertEqual(p.text, "phuc@gmail.coom")
    }

    func testVNIDigitsInAddress() {
        var s = KeyboardSettings(); s.vniMode = true
        XCTAssertEqual(type("So7n", settings: s), "Sơn")
        XCTAssertEqual(type("d9uc1@vn.com", settings: s), "d9uc1@vn.com")
        XCTAssertEqual(type("an@x2.com", settings: s), "an@x2.com")
    }

    func testEmailChipInsertionRestoresFirst() {
        // acceptEmailChip đi qua boundary(chip.insert)
        let p = MockProxy()
        let b = bridge()
        feed("dduc", b, p)
        b.boundary("@gmail.com", proxy: p)
        XCTAssertEqual(p.text, "dduc@gmail.com")
    }

    func testNoShortcutPreviewAndNothingToLearnAtMark() {
        let p = MockProxy()
        let b = bridge()
        feed("an", b, p)
        XCTAssertNil(b.shortcutPreview)
        XCTAssertEqual(b.boundary("@", proxy: p), "")
    }
}
