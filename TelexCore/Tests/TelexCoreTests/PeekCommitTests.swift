import XCTest
@testable import TelexCore

// `peekCommitText` là twin non-mutating của `commitText`: phải trả về
// byte-identical với `{ var e = engine; return e.commitText(...) }` tại MỌI
// prefix của mọi chuỗi phím, và tuyệt đối không đổi state (peek nhiều lần ==
// không peek). Chạy trên cả 3 cấu hình chính (macOS strict, iOS defaults,
// full Telex + spell-check) × autoRestore on/off.
final class PeekCommitTests: XCTestCase {

    private struct Config {
        var name: String
        var freeMarking = false
        var simpleTelex = false
        var liveSpellCheck = false
        var quickTelex = false
        var modernTone = false
        var englishWordRestore = true
    }

    private let configs: [Config] = [
        Config(name: "macOS-strict"),
        Config(name: "iOS-defaults", freeMarking: true, simpleTelex: true, liveSpellCheck: true),
        Config(name: "full-telex", freeMarking: true, liveSpellCheck: true, modernTone: true),
        Config(name: "quick-telex", quickTelex: true),
        Config(name: "no-english-table", liveSpellCheck: true, englishWordRestore: false),
    ]

    // " " = word boundary (commitBoundary giữa chừng, engine reset rồi gõ tiếp).
    private let sequences: [String] = [
        // tone / restore cases từ yêu cầu
        "his", "hi s", "vieejt", "ddaayj",
        // Việt điển hình
        "hoas", "truowngf", "nguwowif", "tieengs", "ddaay", "quas", "hoawcj",
        "luuw", "cuuws", "muaw", "nuawx", "thuowr", "khoer", "thuys",
        // teencode / w-z onsets
        "was", "wow", "wa", "waf", "zoo", "dzoo", "zaayj",
        // cancel / double-key
        "iss", "messs", "ass", "airrw", "Deffault", "themee", "ddd", "www", "aaa",
        // English / code
        "windows", "installer", "SaaS", "OmS", "JavaScript", "pizza", "xyz",
        "off", "class", "yes", "hello",
        // đ-abbrev + ALL-CAPS
        "ddm", "ddc", "DDSQ", "DDHQG", "VIEEJT", "DDDR",
        // nhiều từ + boundary giữa chừng
        "toi yeu vieejt nam", "hoas ddaayj his",
        // overflow (> 32 phím)
        "supercalifragilisticexpialidocious",
        String(repeating: "truowngf", count: 6),
    ]

    private func makeEngine(_ c: Config) -> TelexEngine {
        var e = TelexEngine()
        e.freeMarking = c.freeMarking
        e.simpleTelex = c.simpleTelex
        e.liveSpellCheck = c.liveSpellCheck
        e.quickTelex = c.quickTelex
        e.modernTone = c.modernTone
        e.englishWordRestore = c.englishWordRestore
        return e
    }

    /// peek == copy+commit tại mọi prefix (kể cả engine rỗng và sau boundary).
    func testPeekMatchesCopyCommitAtEveryPrefix() {
        for c in configs {
            for autoRestore in [true, false] {
                for seq in sequences {
                    var e = makeEngine(c)
                    assertPeekMatches(&e, autoRestore: autoRestore, at: "\(c.name)/\(seq)/empty")
                    for (i, ch) in seq.enumerated() {
                        if ch == " " {
                            _ = e.commitBoundary(autoRestore: autoRestore)
                        } else {
                            _ = e.feed(ch)
                        }
                        assertPeekMatches(&e, autoRestore: autoRestore,
                                          at: "\(c.name)/\(seq)/key\(i)")
                    }
                }
            }
        }
    }

    private func assertPeekMatches(_ e: inout TelexEngine, autoRestore: Bool, at ctx: String) {
        var copy = e
        let expected = copy.commitText(autoRestore: autoRestore)
        XCTAssertEqual(e.peekCommitText(autoRestore: autoRestore), expected,
                       "peek != copy+commit @ \(ctx) autoRestore=\(autoRestore)")
    }

    /// Peek không đổi state: engine bị peek 2×/phím phải cho ra đúng từng
    /// TelexAction, composed, rawKeystrokes và kết quả commit cuối như engine
    /// đối chứng không hề peek.
    func testPeekDoesNotMutateEngine() {
        for c in configs {
            for seq in sequences {
                var peeked = makeEngine(c)
                var control = makeEngine(c)
                for ch in seq {
                    if ch == " " {
                        _ = peeked.peekCommitText(autoRestore: true)
                        let a = peeked.commitBoundary(autoRestore: true)
                        let b = control.commitBoundary(autoRestore: true)
                        XCTAssertEqual(a, b, "\(c.name)/\(seq): boundary diverged after peek")
                        continue
                    }
                    _ = peeked.peekCommitText(autoRestore: true)
                    _ = peeked.peekCommitText(autoRestore: false)
                    let a = peeked.feed(ch)
                    let b = control.feed(ch)
                    XCTAssertEqual(a, b, "\(c.name)/\(seq): action diverged after peek")
                    XCTAssertEqual(peeked.composed, control.composed,
                                   "\(c.name)/\(seq): composed diverged after peek")
                    XCTAssertEqual(peeked.rawKeystrokes, control.rawKeystrokes,
                                   "\(c.name)/\(seq): raw diverged after peek")
                }
                _ = peeked.peekCommitText(autoRestore: true)
                XCTAssertEqual(peeked.commitText(autoRestore: true),
                               control.commitText(autoRestore: true),
                               "\(c.name)/\(seq): final commit diverged after peek")
            }
        }
    }

    /// Peek xen giữa backspace cũng không lệch (backspace rebuild parse state).
    func testPeekDoesNotMutateAcrossBackspace() {
        for c in configs {
            for seq in ["airrw", "vieejt", "installer", "nguwowif"] {
                var peeked = makeEngine(c)
                var control = makeEngine(c)
                for ch in seq { _ = peeked.feed(ch); _ = control.feed(ch) }
                _ = peeked.peekCommitText(autoRestore: true)
                let a = peeked.backspace()
                let b = control.backspace()
                XCTAssertEqual(a, b, "\(c.name)/\(seq): backspace diverged after peek")
                _ = peeked.peekCommitText(autoRestore: true)
                XCTAssertEqual(peeked.commitText(autoRestore: true),
                               control.commitText(autoRestore: true),
                               "\(c.name)/\(seq): commit after ⌫ diverged after peek")
            }
        }
    }
}
