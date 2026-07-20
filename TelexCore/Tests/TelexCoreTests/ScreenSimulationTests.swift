import XCTest
@testable import TelexCore

// The strongest invariant in the codebase: whatever TelexAction the engine emits,
// a dumb input client that applies it (passthrough appends the char; replace(bs,
// insert) drops `bs` trailing chars then appends `insert`) MUST end up showing
// exactly `engine.composed` after EVERY keystroke. A mismatch here is precisely the
// class of bug that corrupts text on screen — the diff said one thing, the engine
// believes another.
//
// The screen is modeled as [Character]; every composed scalar in this engine is a
// single precomposed Unicode scalar, so one screen Character == one engine output
// scalar. Backspace() is included: on .passthrough the app deletes the last char
// natively, on .replace it edits the tail.
//
// All inputs are kept under the 32-key capacity so the engine never "overflows"
// (past capacity its 32-char view is intentionally a stale prefix of the screen and
// the invariant no longer holds — that path is covered in EngineTests overflow tests).
final class ScreenSimulationTests: XCTestCase {

    /// A simulated input client's visible text.
    private struct Screen {
        var chars: [Character] = []

        mutating func apply(_ action: TelexAction, feedChar: Character?) {
            switch action {
            case .passthrough:
                if let c = feedChar {
                    chars.append(c)            // forward key: system inserts it
                } else {
                    if !chars.isEmpty { chars.removeLast() }  // backspace: native delete
                }
            case .replace(let bs, let insert):
                precondition(bs <= chars.count, "diff asked to delete \(bs) but only \(chars.count) on screen")
                chars.removeLast(bs)
                chars.append(contentsOf: insert)
            case .none:
                break
            }
        }

        var text: String { String(chars) }
    }

    /// Feed the whole key string, asserting screen == engine.composed after each key.
    private func assertScreenTracks(_ keys: String, file: StaticString = #filePath, line: UInt = #line) {
        var e = TelexEngine()
        var screen = Screen()
        for ch in keys {
            let action = e.feed(ch)
            screen.apply(action, feedChar: ch)
            XCTAssertEqual(screen.text, e.composed,
                           "after feeding '\(ch)' in \"\(keys)\": screen=\"\(screen.text)\" composed=\"\(e.composed)\"",
                           file: file, line: line)
        }
    }

    /// Same but with a scripted mix of feeds and backspaces (true = backspace).
    private func assertScreenTracksWithBackspaces(
        _ ops: [(feed: Character?, backspace: Bool)],
        settings: (TelexEngine) -> TelexEngine = { $0 },
        file: StaticString = #filePath, line: UInt = #line
    ) {
        var e = settings(TelexEngine())
        var screen = Screen()
        for (i, op) in ops.enumerated() {
            let action: TelexAction
            if op.backspace {
                action = e.backspace()
                screen.apply(action, feedChar: nil)
            } else {
                action = e.feed(op.feed!)
                screen.apply(action, feedChar: op.feed!)
            }
            XCTAssertEqual(screen.text, e.composed,
                           "op #\(i) (\(op.backspace ? "BS" : String(op.feed!))): screen=\"\(screen.text)\" composed=\"\(e.composed)\"",
                           file: file, line: line)
        }
    }

    // MARK: - Corpus: every category from the typing matrix, forward-typed only.

    private static let corpus: [String] = [
        // ươ propagation both key orders
        "truowngf", "truwongf", "dduowcj", "dduwocj", "nuowcs", "nuwocs",
        "nguowif", "nguwoif", "suwowng", "suwong", "dduowngf", "muwowif",
        // open uơ / qu-glide
        "thuowr", "huow", "quowr", "quown", "quowrn",
        // ua nucleus retarget
        "nuawx", "nuwax", "muaw", "chuaw", "buawx", "tuawj",
        // qu + a + w
        "quawt", "quaw", "hoaw", "hoawcj",
        // tones on all vowels
        "as", "af", "ar", "ax", "aj", "es", "is", "os", "us", "ys",
        // circumflex / breve / horn / đ
        "aa", "aw", "ee", "oo", "ow", "uw", "dd", "ddaay",
        // qu / gi onsets
        "quys", "quaf", "giaf", "giuwx", "gif", "ginf",
        // oa/oe/uy
        "hoas", "hoaf", "khoer", "thuys", "hoef",
        // stop-coda tone restriction
        "bats", "batj", "batf", "batr", "batx", "sachs", "sachf", "caps", "capr", "hocj", "hocf",
        // trailing-d
        "dand", "duwowngd", "duwowngdf",
        // real words
        "tieengs", "vieejt", "huyeenf", "quaan", "nghieeng", "ngoaif", "ngoays",
        "chuyeenr", "ddoongf", "ddaaus", "cuar", "muaf", "muas", "mias", "toans",
        "khuya", "uoongs", "ban", "banf", "conf", "lamf", "cams",
        // cancellation gestures
        "iss", "ass", "aff", "arr", "axx", "ajj", "aaa", "eee", "ooo", "ddd",
        "aww", "oww", "uww", "asz", "messs", "bossss", "huyeenfz", "pizza", "xyz",
        // English / code that freezes or restores
        "google", "github", "windows", "keyword", "was", "web", "write", "data",
        "SaaS", "JavaScript", "OmS", "OSm", "TypeScript",
        // uppercase / mixed
        "VIEEJT", "HOAS", "DDAAY", "Ddaay", "ddAAy", "Vieejt",
        // z as onset
        "zoo", "zaay", "zaajy", "zui", "dzij", "dzoo",
    ]

    func testScreenTracksComposedForCorpus() {
        for w in Self.corpus { assertScreenTracks(w) }
    }

    // Same corpus but under each setting flag — the diff must stay consistent
    // regardless of composition policy.
    func testScreenTracksUnderEverySetting() {
        let configs: [(String, (inout TelexEngine) -> Void)] = [
            ("free", { $0.freeMarking = true }),
            ("modern", { $0.modernTone = true }),
            ("spell", { $0.liveSpellCheck = true }),
            ("simple", { $0.simpleTelex = true }),
            ("all", { $0.freeMarking = true; $0.modernTone = true; $0.liveSpellCheck = true; $0.simpleTelex = true }),
        ]
        for (name, cfg) in configs {
            for w in Self.corpus {
                var e = TelexEngine(); cfg(&e)
                var screen = Screen()
                for ch in w {
                    let a = e.feed(ch)
                    screen.apply(a, feedChar: ch)
                    XCTAssertEqual(screen.text, e.composed, "[\(name)] \"\(w)\" @'\(ch)'")
                }
            }
        }
    }

    // MARK: - Backspace interleaving

    // Backspace at every position of a long word, then continue typing — the screen
    // must track the engine through the destructive edits.
    func testScreenTracksBackspaceThenRetype() {
        let words = ["dduwowngf", "nguwowif", "truowngf", "vieejt", "khoo", "tieengs"]
        for w in words {
            for cut in 1...w.count {
                var ops: [(Character?, Bool)] = w.map { ($0, false) }
                for _ in 0..<cut { ops.append((nil, true)) }        // backspaces
                for c in "as" { ops.append((c, false)) }             // retype a little
                assertScreenTracksWithBackspaces(ops.map { (feed: $0.0, backspace: $0.1) })
            }
        }
    }

    // MARK: - Deterministic pseudo-random fuzzing (seeded — fully reproducible).

    /// Tiny LCG so the corpus is identical on every run (no Date/Random seeds).
    private struct LCG {
        var state: UInt64
        mutating func next() -> UInt64 { state = state &* 6364136223846793005 &+ 1442695040888963407; return state }
        mutating func int(_ n: Int) -> Int { Int(next() >> 33) % n }
    }

    func testScreenTracksRandomLetterSequences() {
        // Letters heavy on Telex-significant keys so transforms actually fire.
        // Letters only: a raw space would be a passthrough the engine doesn't record
        // (the real controller routes it through commitBoundary), so it isn't modeled here.
        let alphabet = Array("aeiouyaeiouwdsfrxjqhngtcbmlpvWDSAA")
        var rng = LCG(state: 0xF00D_CAFE_1234_5678)
        for _ in 0..<4000 {
            let len = 1 + rng.int(20)          // < 32, never overflows
            var s = ""
            for _ in 0..<len { s.append(alphabet[rng.int(alphabet.count)]) }
            assertScreenTracks(s)
        }
    }

    // Random sequences WITH interleaved backspaces — the destructive path (rebuild +
    // provenance filter) must keep the screen and engine in lockstep.
    func testScreenTracksRandomWithBackspaces() {
        let alphabet = Array("aeiouywdsfrxjqhngtcbmlpAAWDD")
        var rng = LCG(state: 0x1357_9BDF_2468_ACE0)
        for _ in 0..<4000 {
            let len = 1 + rng.int(24)
            var ops: [(feed: Character?, backspace: Bool)] = []
            for _ in 0..<len {
                if rng.int(4) == 0 {
                    ops.append((feed: nil, backspace: true))
                } else {
                    ops.append((feed: alphabet[rng.int(alphabet.count)], backspace: false))
                }
            }
            assertScreenTracksWithBackspaces(ops)
        }
    }

    // Random sequences with live spell-check on (the freeze path changes the diff
    // shape mid-word) — the invariant must still hold.
    func testScreenTracksRandomWithLiveSpellCheck() {
        let alphabet = Array("aeiouywdsfrxjqhngtcbmlp")
        var rng = LCG(state: 0x0BAD_F00D_D00D_FEED)
        for _ in 0..<3000 {
            let len = 1 + rng.int(20)
            var ops: [(feed: Character?, backspace: Bool)] = []
            for _ in 0..<len { ops.append((feed: alphabet[rng.int(alphabet.count)], backspace: false)) }
            assertScreenTracksWithBackspaces(ops, settings: { var e = $0; e.liveSpellCheck = true; return e })
        }
    }
}
