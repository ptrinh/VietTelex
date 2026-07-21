import XCTest
@testable import TelexCore

// A broad matrix of real Vietnamese typing scenarios. Two complementary strategies
// keep the expectations trustworthy (never hand-guessed against the code):
//
//  1. REAL-WORD ROUND-TRIP — the expected value is a real Vietnamese word I write;
//     the test derives the Telex keystrokes FROM that word (detone + mark-expand),
//     feeds them, and asserts the engine composes exactly the word back and does not
//     auto-restore it. Covers all 5 tones on every vowel, circumflex/breve/horn, đ,
//     ươ, qu-/gi- onsets, oa/oe/uy, and coda families.
//
//  2. IDEMPOTENCE — a structural property that needs no expected string at all: for a
//     large generated combo space, whatever VALID syllable the engine composes must
//     re-compose to itself when its own keystrokes are regenerated and replayed. An
//     inconsistency (compose ≠ compose∘detone∘compose) would be an engine bug.
//
// Plus small explicit tables for the documented edge behaviors.
final class TypingMatrixTests: XCTestCase {

    // MARK: - Telex keystroke generator (word -> raw keys)

    private static let markExpansion: [Character: String] = [
        "â": "aa", "ă": "aw", "ê": "ee", "ô": "oo", "ơ": "ow", "ư": "uw", "đ": "dd",
    ]
    private static func toneKey(_ t: Tone) -> Character? {
        switch t {
        case .acute: return "s"; case .grave: return "f"; case .hook: return "r"
        case .tilde: return "x"; case .dot: return "j"; case .none: return nil
        }
    }
    private static func detone(_ lower: Character) -> (Character, Tone) {
        guard lower.unicodeScalars.count == 1, let s = lower.unicodeScalars.first,
              let (base, t) = Tables.detoneTable[s.value] else { return (lower, .none) }
        return (Character(Unicode.Scalar(base)!), t)
    }
    /// "trường" -> "truwowngf". Tone key appended at the end (standard Telex habit).
    /// `upperTone` forces the trailing tone key uppercase (all-caps words: VIEEJT).
    static func telexKeys(_ word: String, upperTone: Bool = false) -> String {
        var out = ""
        var tone: Character?
        for ch in word {
            let isUpper = ch.isUppercase
            let (toneless, t) = detone(Character(ch.lowercased()))
            if t != .none { tone = toneKey(t) }
            let exp = markExpansion[toneless] ?? String(toneless)
            out += isUpper ? exp.uppercased() : exp
        }
        if let tone { out.append(upperTone ? Character(tone.uppercased()) : tone) }
        return out
    }

    private func compose(_ keys: String, _ configure: (inout TelexEngine) -> Void = { _ in }) -> String {
        var e = TelexEngine(); e.englishWordRestore = false; configure(&e)
        for ch in keys { _ = e.feed(ch) }
        return e.composed
    }
    private func commit(_ keys: String) -> String {
        var e = TelexEngine()
        e.englishWordRestore = false   // matrix tests validator behavior, not English policy
        for ch in keys { _ = e.feed(ch) }
        return e.commitText(autoRestore: true)
    }

    // MARK: - 1. Real-word round-trip (default old-style orthography)

    /// Real Vietnamese single syllables spanning every category. Each must (a) be a
    /// valid syllable, (b) compose exactly from its generated keys, (c) survive
    /// auto-restore unchanged (valid → never reverted).
    private static let realWords: [String] = [
        // ---- 5 tones across the vowel space ----
        "ba", "bà", "bá", "bả", "bã", "bạ",
        "me", "mé", "mè", "mẻ", "mẽ", "mẹ",
        "ly", "lý", "lỳ", "lỷ", "lỹ", "lỵ",
        "cô", "cố", "cồ", "cổ", "cỗ", "cộ",
        "mơ", "mớ", "mờ", "mở", "mỡ", "mợ",
        "thư", "thứ", "thừ", "thử", "thữ", "thự",
        "bê", "bế", "bề", "bể", "bễ", "bệ",
        "ăn", "ắng", "ằng", "ẳng", "ẵng", "ặng",
        "âm", "ấm", "ầm", "ẩm", "ẫm", "ậm",
        // ---- circumflex / breve / horn / đ ----
        "đây", "đâu", "đông", "được", "đường", "đủ", "đỏ",
        "tây", "tăng", "tơ", "tư", "cân", "sân",
        // ---- ươ propagation ----
        "trường", "nước", "người", "sương", "thương", "mười", "tươi", "mượn", "vượt",
        // ---- open uơ / qu glide ----
        "thuở", "huơ", "quở", "quờ",
        // ---- ua/ưa/ia falling diphthongs ----
        "mùa", "múa", "của", "chưa", "mưa", "nữa", "bữa", "mía", "kia", "tia",
        // ---- qu / gi onsets ----
        "quý", "quà", "quân", "quốc", "quyển", "già", "giữ", "gì", "giá", "giường",
        // ---- oa / oe / uy (old style) ----
        "hóa", "hòa", "khỏe", "hòe", "thúy", "thủy", "khuya", "tuyển",
        // ---- coda families / all tones on sonorant codas ----
        "bàn", "bãng", "bảnh", "làm", "còn", "cảng", "sáng", "vàng", "mảnh",
        // ---- stop coda + legal tone ----
        "bát", "bạt", "sách", "học", "cáp", "việt", "ngọc", "tập", "một",
        // ---- triphthongs ----
        "ngoài", "ngoáy", "nguyễn", "khuyên", "chuyện", "nghiêng", "tiếng",
        // ---- misc common ----
        "nam", "con", "ban", "cám", "đồng", "đấu", "chuyển", "nghĩ", "nghe", "yêu", "uống",
    ]

    func testRealWordRoundTrip() {
        for word in Self.realWords {
            let keys = Self.telexKeys(word)
            XCTAssertTrue(SyllableValidator.isValidSyllable(word),
                          "test word not a valid syllable (fix the test list): \(word)")
            XCTAssertEqual(compose(keys), word, "compose(\(keys)) for word \(word)")
            XCTAssertEqual(commit(keys), word, "auto-restore wrongly reverted valid word \(word) [keys=\(keys)]")
        }
    }

    /// Uppercase (all-caps) round-trip: VIET keys all uppercase incl. the tone key.
    func testAllCapsRoundTrip() {
        for word in ["VIỆT", "NƯỚC", "ĐƯỜNG", "NGƯỜI", "HÓA", "TRƯỜNG", "ĐÂY", "QUỐC"] {
            let keys = Self.telexKeys(word, upperTone: true)
            XCTAssertEqual(compose(keys), word, "all-caps compose(\(keys))")
        }
    }

    // MARK: - 2. Idempotence over a generated combo space (no expected strings)

    // For every onset × vowel × coda × tone combo, whatever VALID syllable the engine
    // composes must be a fixed point of "regenerate keys from the output, replay":
    // compose(keys) == compose(telexKeys(compose(keys))). This exercises far more of
    // the tone-placement / propagation machine than any hand table, and can only fail
    // if the engine composes the same sound two different ways.
    func testComposeIsIdempotentOverValidCombos() {
        let onsets = ["", "b", "c", "m", "t", "th", "tr", "ng", "nh", "kh", "ph", "d", "dd", "qu", "gi"]
        let vowels = ["a", "aa", "aw", "e", "ee", "i", "o", "oo", "ow", "u", "uw", "y",
                      "oa", "oe", "uy", "uo", "uow", "ie", "ye", "ai", "ao", "au", "ay", "oi", "ua"]
        // Offglide vowels i/u/y are included as codas for diphthong coverage; the
        // vowel letter 'o' is deliberately NOT a coda here — appended after an "oo"
        // vowel it forms the triple-o CANCEL gesture ("ooo"→literal "oo"), and a
        // cancel-only literal cannot be reproduced by telexKeys(), so it isn't a fair
        // idempotence subject (that behavior is asserted directly elsewhere).
        let codas = ["", "n", "ng", "nh", "m", "c", "t", "p", "ch", "i", "u", "y"]
        let tones = ["", "s", "f", "r", "x", "j"]
        var checked = 0
        for on in onsets {
            for v in vowels {
                for co in codas {
                    for to in tones {
                        let keys = on + v + co + to
                        guard keys.count <= 12 else { continue }
                        let x = compose(keys)
                        guard !x.isEmpty, SyllableValidator.isValidSyllable(x) else { continue }
                        let x2 = compose(Self.telexKeys(x))
                        XCTAssertEqual(x, x2, "not idempotent: keys=\(keys) -> \(x) -> \(x2)")
                        // A valid composition must never be auto-restored away.
                        XCTAssertEqual(commit(keys), x, "valid \(x) restored (keys=\(keys))")
                        checked += 1
                    }
                }
            }
        }
        XCTAssertGreaterThan(checked, 400, "combo space unexpectedly small (\(checked))")
    }

    // MARK: - 3. Explicit edge tables (documented behaviors)

    // Tone key typed BEFORE the coda still lands on the nucleus (Telex allows the tone
    // key anywhere after the vowel). "casp" and "caps" both give cáp.
    func testTonePositionRelativeToCoda() {
        XCTAssertEqual(compose("casp"), "cáp")     // tone before the p
        XCTAssertEqual(compose("caps"), "cáp")     // tone after the p
        XCTAssertEqual(compose("batj"), "bạt")
        XCTAssertEqual(compose("bajt"), "bạt")     // nặng before the t
        XCTAssertEqual(compose("toasn"), "toán")   // sắc before the n
        XCTAssertEqual(compose("toans"), "toán")
        XCTAssertEqual(compose("hoafng"), "hoàng") // grave mid-word, closed -> 2nd vowel
        XCTAssertEqual(compose("hoangf"), "hoàng")
    }

    // ươ propagation is order-free for BOTH the w/o interleaving AND the tone key
    // position. All spellings of "được"/"trường" must converge.
    func testUowConvergence() {
        // All reorder the o/w and the tone key, but never move w before the u exists.
        for keys in ["dduowcj", "dduwocj", "dduwojc", "dduowjc"] {
            XCTAssertEqual(compose(keys), "được", "keys=\(keys)")
        }
        for keys in ["truowngf", "truwongf", "truwowngf"] {
            XCTAssertEqual(compose(keys), "trường", "keys=\(keys)")
        }
        XCTAssertEqual(compose("nuwowcs"), "nước")
        XCTAssertEqual(compose("nguwowif"), "người")
    }

    // Modern-orthography tone placement — the four rimes that move, plus invariants.
    func testModernToneTable() {
        let modern: [(String, String)] = [
            ("hoas", "hoá"), ("hoaf", "hoà"), ("khoer", "khoẻ"), ("hoef", "hoè"),
            ("thuys", "thuý"), ("thuyr", "thuỷ"), ("quys", "quý"),   // quy is qu-glide+y: unaffected
        ]
        for (keys, exp) in modern {
            XCTAssertEqual(compose(keys) { $0.modernTone = true }, exp, "modern keys=\(keys)")
        }
        // Falling diphthongs and closed nuclei are identical to old style.
        for keys in ["muaf", "mias", "cuar", "toans", "tieengs", "nguowif"] {
            XCTAssertEqual(compose(keys) { $0.modernTone = true }, compose(keys), "invariant \(keys)")
        }
    }

    // Trailing-d đ conversion across a formed syllable, with and without a tone.
    func testTrailingDConversion() {
        XCTAssertEqual(compose("dand"), "đan")
        XCTAssertEqual(compose("dangd"), "đang")
        XCTAssertEqual(compose("duwowngd"), "đương")
        XCTAssertEqual(compose("duwowngdf"), "đường")
        XCTAssertEqual(compose("dieemd"), "điêm")     // no tone
        XCTAssertEqual(compose("dieemdr"), "điểm")     // + hỏi
    }
}
