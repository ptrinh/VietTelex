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

    func testLexiconDiacriticCompletion() {
        // "nguoi" (đã fold) → ứng viên chỉ-khác-dấu đứng đầu
        let c = VNLexicon.completions(forFolded: "nguoi", limit: 3, excluding: "nguoi")
        XCTAssertEqual(c.first, "người")
        // prefix ngắn: "ng" → có "người"/"ngày" trong top
        let p = VNLexicon.completions(forFolded: "ng", limit: 3, excluding: "ng")
        XCTAssertFalse(p.isEmpty)
        // dưới 2 ký tự: không gợi ý
        XCTAssertTrue(VNLexicon.completions(forFolded: "n", limit: 3, excluding: "n").isEmpty)
    }
}
