// EngineBridge unit tests — a scripted mock proxy records the exact
// deleteBackward/insertText stream, so the whole iOS typing path (minus UIKit)
// is verified against the real engine.
import XCTest
import TelexCore

final class MockProxy: TextProxyLike {
    var text = ""
    var isSecure = false
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

    func testBasicVietnamese() {
        XCTAssertEqual(type("vieetj "), "việt ")
        XCTAssertEqual(type("Tieengs Vieetj raats hay "), "Tiếng Việt rất hay ")
        XCTAssertEqual(type("dduwowngf "), "đường ")
    }

    func testAutoRestoreAndCollisions() {
        XCTAssertEqual(type("google "), "google ")
        // Chính sách 2026-07-23: collision THẬT thì tiếng Việt thắng (his ≡ hí)
        XCTAssertEqual(type("his "), "hí ")
        XCTAssertEqual(type("off "), "off ")
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

final class SensitiveWordsTests: XCTestCase {
    func testFilterGate() {
        let words = ["vcl", "vui", "đcm", "cảm"]
        XCTAssertEqual(SensitiveWords.filter(words, enabled: true), ["vui", "cảm"])
        XCTAssertEqual(SensitiveWords.filter(words, enabled: false), words)
        // từ bạo lực phổ thông KHÔNG bị lọc (từ vựng đời thường/báo chí)
        XCTAssertEqual(SensitiveWords.filter(["cướp", "giết"], enabled: true), ["cướp", "giết"])
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
