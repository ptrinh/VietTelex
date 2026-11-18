// CaretSuggest.swift — gợi ý cạnh con trỏ cho Linux (port macOS 1.8.2): kết quả phép tính,
// chip số (chỉ dạng tiền), sửa lỗi gõ sai, thêm dấu cho cụm không dấu, ngày giờ.
//
// Logic THUẦN chép 1:1 từ App/Sources/CaretSuggestions.swift + phần thuần của
// App/Sources/MathHint.swift (CaretHintLogic.moneyChip / ShortcutScreen.tokenRange) — hai file
// đó kéo AppKit/AppState nên không symlink được. Phần dùng chung thật (MathResults, NumberChips,
// AutoCorrect, AdjacentKeyFixer, SeedData, VNSuggest, SwipeEnglish, AddTones) là SYMLINK tới
// iOS/Keyboard như mọi file khác của viettelex-text-tool. Khác macOS:
//  • tiếng Anh tra SwipeEnglish.contains (process con này đã giải mã enlexicon cho Thêm dấu;
//    macOS dùng EnglishLite mmap vì chạy trong process IME);
//  • "bây giờ" / "hôm nay": giờ địa phương do frontend gửi (localtime_r) — không cần
//    Calendar/TimeZone (FoundationEssentials tĩnh không mang tzdata);
//  • chạy trong `viettelex-text-tool --serve` (Serve.swift): bộ gõ chỉ lo điểm kích hoạt rẻ
//    (linux/common caret_hints), dữ liệu lexicon/LM không vào process IME.
import Foundation
import TelexCore

/// Một gợi ý: `replace` = đuôi văn bản trước con trỏ sẽ bị thay (rỗng = chỉ chèn — phép
/// tính), `insert` = chữ chèn vào. = CaretSuggestion (MathHint.swift).
struct CaretSuggestion: Equatable {
    enum Kind: String, Equatable { case math, number, typo, tones, date }
    let kind: Kind
    let display: String
    let replace: String
    let insert: String
}

enum CaretHintLogic {
    /// "= 36" (MathHintLogic.label).
    static func mathLabel(_ result: String) -> String { "= " + result }

    /// MathHintLogic.result: văn bản trước con trỏ (đã có "=" cuối) → chữ chèn, nil nếu không.
    static func mathResult(beforeCaret: String) -> String? {
        MathResults.chip(before: beforeCaret)?.insert
    }

    static func math(before: String) -> CaretSuggestion? {
        guard let r = mathResult(beforeCaret: before) else { return nil }
        return CaretSuggestion(kind: .math, display: mathLabel(r), replace: "", insert: r)
    }

    /// Dấu cách vừa gõ sau cụm có chữ số / cụm đơn vị ngay sau cụm số (MathHint.swift).
    static func numberWorthChecking(boundary: String?, run: String, prevRun: String) -> Bool {
        guard boundary == " ", !run.isEmpty else { return false }
        if run.contains(where: \.isNumber) { return true }
        return run.count <= 6 && prevRun.contains(where: \.isNumber)
    }

    /// Chỉ dạng tiền ("1.200.000 ₫") — bỏ "đọc số thành chữ" như macOS.
    static func moneyChip(before: String) -> CaretSuggestion? {
        guard before.hasSuffix(" "), let c = NumberChips.chip(before: before),
              isMoneyFormat(c.display) else { return nil }
        return CaretSuggestion(kind: .number, display: c.display, replace: c.replace, insert: c.insert)
    }

    static func isMoneyFormat(_ display: String) -> Bool {
        let d = display.hasPrefix("-") ? display.dropFirst() : Substring(display)
        return d.first?.isNumber == true
    }

    /// `before` kết thúc đúng bằng `token` (so UTF-16) và token đứng riêng: đầu văn bản hoặc
    /// ngay sau khoảng trắng / xuống dòng (= ShortcutScreen.tokenRange).
    static func standsAlone(before: String, token: String) -> Bool {
        let w = Array(before.utf16), t = Array(token.utf16)
        guard !t.isEmpty, w.count >= t.count, Array(w.suffix(t.count)) == t else { return false }
        if w.count == t.count { return true }
        guard let s = Unicode.Scalar(w[w.count - t.count - 1]) else { return false }
        return Character(s).isWhitespace || Character(s).isNewline
    }
}

// MARK: - 1. Sửa lỗi gõ sai (= TypoFixLogic, CaretSuggestions.swift)

enum TypoFixLogic {
    enum Edit: Equatable, CaseIterable { case sub, swap, del, ins }

    struct Cand: Equatable {
        let word: String
        let freq: Int
        let edit: Edit
    }

    struct Params: Equatable {
        var minLen: Int
        var minFreq: Int
        var margin: Int
        var edits: Set<Edit>
        var rivals: Set<Edit> = []
    }

    /// = macOS (TypoFixEvalTests, 28/09/2026: DEV P 98.5% R 17.6%).
    static let defaults = Params(minLen: 3, minFreq: 150, margin: 80, edits: [.sub, .swap], rivals: [.del, .ins])

    static func worthChecking(boundary: String?, raw: String, word: String, minLen: Int = defaults.minLen) -> Bool {
        guard let b = boundary, AutoCorrect.triggers(b),
              (minLen...10).contains(raw.count),
              raw.unicodeScalars.allSatisfy({ ($0.value | 0x20) >= 97 && ($0.value | 0x20) <= 122 }),
              !word.isEmpty, word.allSatisfy(\.isLetter) else { return false }
        return !SyllableValidator.isValidSyllable(word)
    }

    private static let letters = Array("abcdefghijklmnopqrstuvwxyz")

    static func candidates(_ lower: String, compose: (String) -> String, frequency: (String) -> Int?,
                           hasCompletion: (String) -> Bool, edits: Set<Edit> = Set(Edit.allCases)) -> [Cand] {
        var out: [Cand] = []
        if edits.contains(.sub) {
            out += AdjacentKeyFixer.oneEditCandidates(lower, compose: compose, frequency: frequency,
                                                      hasCompletion: hasCompletion,
                                                      neighbors: AdjacentKeyFixer.physicalNeighbors)
                .map { Cand(word: $0.word, freq: $0.freq, edit: .sub) }
        }
        let c0 = Array(lower), current = compose(lower)
        func consider(_ c: [Character], _ e: Edit) {
            let w = compose(String(c))
            guard w != current, let f = frequency(w) else { return }
            out.append(Cand(word: w, freq: f, edit: e))
        }
        if edits.contains(.swap) {
            for i in 0..<max(0, c0.count - 1) where c0[i] != c0[i + 1] {
                var c = c0; c.swapAt(i, i + 1); consider(c, .swap)
            }
        }
        if edits.contains(.del), c0.count > 2 {
            for i in c0.indices where i == 0 || c0[i] != c0[i - 1] {
                var c = c0; c.remove(at: i); consider(c, .del)
            }
        }
        if edits.contains(.ins), c0.count < 10 {
            for i in 0...c0.count {
                for l in letters where i == 0 || c0[i - 1] != l {
                    var c = c0; c.insert(l, at: i); consider(c, .ins)
                }
            }
        }
        return out
    }

    static func pick(_ cands: [Cand], p: Params = defaults) -> Cand? {
        var best: [String: Cand] = [:]
        var proposable: Set<String> = []
        for c in cands where p.edits.contains(c.edit) || p.rivals.contains(c.edit) {
            if p.edits.contains(c.edit) { proposable.insert(c.word) }
            if let b = best[c.word], b.freq >= c.freq { continue }
            best[c.word] = c
        }
        let sorted = best.values.sorted { $0.freq != $1.freq ? $0.freq > $1.freq : $0.word < $1.word }
        guard let top = sorted.first, proposable.contains(top.word), top.freq >= p.minFreq else { return nil }
        if sorted.count > 1, top.freq - sorted[1].freq < p.margin { return nil }
        return top
    }

    // MARK: Tiếng Anh ("spellnig" → spelling — Phil 16/10/2026)

    /// Sửa tiếng Anh: chỉ khi KHÔNG có bản sửa tiếng Việt. Ứng viên MỘT sửa trên PHÍM THÔ (không
    /// qua Telex) có trong enlexicon: thay phím kề / đảo hai phím liền nhau luôn được đề xuất;
    /// bỏ phím thừa / thêm phím sót chỉ đề xuất khi từ ≥ `insDelMinLen` chữ (ngắn hơn: đối thủ).
    /// Ứng viên tiếng Việt (mọi loại sửa) là ĐỐI THỦ — hai lexicon cùng thang tần suất 0–255.
    /// Dò bằng TypoFixEvalTests.testEnglishTuneGridOnDev (câu Anh Tatoeba DEV).
    /// Từ dài (≥ `longMinLen` chữ) hiếm khi cách một từ thật đúng MỘT sửa một cách tình cờ ⇒ ngưỡng
    /// tần suất riêng, thấp hơn (`longMinFreq`: "spellnig" → spelling, tần suất 99).
    struct EnglishParams: Equatable {
        var minFreq: Int
        var margin: Int
        var insDelMinLen: Int
        var longMinLen: Int = 99
        var longMinFreq: Int = 255
    }

    // 18/10/2026 (tần suất vnlexicon corpus hội thoại — đối thủ Việt mạnh lên): minFreq 140 → 135 giữ recall DEV
    // (35,9 → 36,0 %; 140: 35,4 %), oan trên tập giữ nguyên 20 → 14, EN P 95,4 → 95,2 %.
    static let englishDefaults = EnglishParams(minFreq: 135, margin: 60, insDelMinLen: 5, longMinLen: 7, longMinFreq: 60)

    /// Mọi chuỗi MỘT sửa của `lower` (a–z) có trong enlexicon (`frequency`), khác chính nó.
    static func englishCandidates(_ lower: String, frequency: (String) -> Int?) -> [Cand] {
        let c0 = Array(lower)
        var out: [Cand] = []
        func consider(_ c: [Character], _ e: Edit) {
            let w = String(c)
            guard w != lower, let f = frequency(w) else { return }
            out.append(Cand(word: w, freq: f, edit: e))
        }
        for i in c0.indices {
            for n in AdjacentKeyFixer.physicalNeighbors[c0[i]] ?? [] where n != c0[i] {
                var c = c0; c[i] = n; consider(c, .sub)
            }
        }
        for i in 0..<max(0, c0.count - 1) where c0[i] != c0[i + 1] {
            var c = c0; c.swapAt(i, i + 1); consider(c, .swap)
        }
        if c0.count > 2 {
            for i in c0.indices where i == 0 || c0[i] != c0[i - 1] {
                var c = c0; c.remove(at: i); consider(c, .del)
            }
        }
        for i in 0...c0.count {
            for l in letters where i == 0 || c0[i - 1] != l {
                var c = c0; c.insert(l, at: i); consider(c, .ins)
            }
        }
        return out
    }

    /// Từ tiếng Anh đứng đầu (theo tần suất) trong `en` ∪ `rivals` (tiếng Việt), nếu đề xuất
    /// được, phổ biến (≥ minFreq) và hơn từ thứ hai ≥ margin. nil = không.
    static func englishPick(_ en: [Cand], rivals: [Cand], typedLen: Int,
                            p: EnglishParams = englishDefaults) -> Cand? {
        var best: [String: Cand] = [:]
        var proposable: Set<String> = []
        let insDel = typedLen >= p.insDelMinLen
        for c in en {
            if c.edit == .sub || c.edit == .swap || insDel { proposable.insert(c.word) }
            if let b = best[c.word], b.freq >= c.freq { continue }
            best[c.word] = c
        }
        for c in rivals {
            if let b = best[c.word], b.freq >= c.freq { continue }
            best[c.word] = c
        }
        let sorted = best.values.sorted { $0.freq != $1.freq ? $0.freq > $1.freq : $0.word < $1.word }
        let minFreq = typedLen >= p.longMinLen ? min(p.minFreq, p.longMinFreq) : p.minFreq
        guard let top = sorted.first, proposable.contains(top.word), top.freq >= minFreq else { return nil }
        if sorted.count > 1, top.freq - sorted[1].freq < p.margin { return nil }
        return top
    }

    /// Bản sửa cho từ (phím thô `raw`) hoặc nil. `isKnown`: dạng chữ thường (phím thô và dạng
    /// engine ra) là từ đã biết — tiếng Anh / chat / từng Esc ⇒ không gợi ý. `englishFrequency`
    /// (enlexicon) ≠ nil ⇒ không có bản sửa tiếng Việt thì thử bản sửa tiếng Anh.
    static func correction(raw: String, compose: (String) -> String, frequency: (String) -> Int?,
                           hasCompletion: (String) -> Bool, isKnown: (String) -> Bool,
                           englishFrequency: ((String) -> Int?)? = nil, filterSensitive: Bool = true,
                           p: Params = defaults, ep: EnglishParams = englishDefaults) -> String? {
        guard (p.minLen...10).contains(raw.count), raw.allSatisfy({ $0.isASCII && $0.isLetter }) else { return nil }
        let lower = raw.lowercased()
        if isKnown(lower) { return nil }
        let current = compose(lower)
        if current != lower, isKnown(current.lowercased()) { return nil }
        if frequency(current) != nil || hasCompletion(current) { return nil }
        let vn = candidates(lower, compose: compose, frequency: frequency,
                            hasCompletion: hasCompletion, edits: p.edits.union(p.rivals))
        let best: Cand
        if let b = pick(vn, p: p) {
            best = b
        } else if let ef = englishFrequency,
                  let b = englishPick(englishCandidates(lower, frequency: ef), rivals: vn, typedLen: lower.count, p: ep) {
            best = b
        } else {
            return nil
        }
        // "Lọc từ nhạy cảm" bật (như thanh gợi ý iOS): không chủ động đưa từ tục — bỏ hẳn lượt
        // này (không lùi về ứng viên thứ hai: nó chưa chắc hơn đủ xa).
        if SensitiveWords.filter([best.word], enabled: filterSensitive).isEmpty { return nil }
        if raw.first?.isUppercase == true, let f = best.word.first {
            return f.uppercased() + best.word.dropFirst()
        }
        return best.word
    }

    static let chatWords: Set<String> = Set(SeedData.unigrams.keys.filter { w in
        w.allSatisfy { $0.isASCII && $0.isLetter } && !VNSuggest.contains(w)
    })

    static func isEnglish(_ w: String) -> Bool {
        SwipeEnglish.contains(w) || EnglishContextLookup.opensEnglishRun(w)
    }

    static func isKnown(_ w: String) -> Bool { isEnglish(w) || chatWords.contains(w) }

    /// Cờ engine của bộ gõ (thứ tự = trường `flags` của yêu cầu typo, Serve.swift).
    struct EngineFlags: Equatable {
        var freeMarking = true, modernTone = false, liveSpellCheck = true
        var simpleTelex = false, quickTelex = false, vniMode = false
        var bracketVowels = false, contextualEnglish = true
        var collisionPrefersVietnamese = true
        var teencode = false
        var autoCircumflex = false

        /// "1011…" (11 chữ số 0/1); thiếu/lạ ⇒ mặc định (chuỗi 10 chữ số cũ: autoCircumflex tắt).
        init() {}
        init(bits: String) {
            let b = Array(bits)
            func at(_ i: Int, _ d: Bool) -> Bool { i < b.count ? b[i] == "1" : d }
            freeMarking = at(0, true); modernTone = at(1, false); liveSpellCheck = at(2, true)
            simpleTelex = at(3, false); quickTelex = at(4, false); vniMode = at(5, false)
            bracketVowels = at(6, false); contextualEnglish = at(7, true)
            collisionPrefersVietnamese = at(8, true); teencode = at(9, false)
            autoCircumflex = at(10, false)
        }
    }

    static func composer(_ f: EngineFlags) -> (String) -> String {
        { raw in
            var e = TelexEngine()
            e.freeMarking = f.freeMarking; e.modernTone = f.modernTone; e.liveSpellCheck = f.liveSpellCheck
            e.simpleTelex = f.simpleTelex; e.quickTelex = f.quickTelex; e.vniMode = f.vniMode
            e.bracketVowels = f.bracketVowels; e.contextualEnglish = f.contextualEnglish
            e.collisionPrefersVietnamese = f.collisionPrefersVietnamese; e.teencode = f.teencode
            e.autoCircumflex = f.autoCircumflex
            for ch in raw { _ = e.feed(ch) }
            return e.composed
        }
    }

    static func lexiconCorrection(raw: String, flags: EngineFlags, filterSensitive: Bool = true) -> String? {
        correction(raw: raw, compose: composer(flags),
                   frequency: { VNSuggest.frequency(of: $0) },
                   hasCompletion: { !VNSuggest.matches($0, poolLimit: 1).isEmpty },
                   isKnown: isKnown, englishFrequency: { SwipeEnglish.frequency(of: $0) },
                   filterSensitive: filterSensitive)
    }

    static func suggestion(before: String, word: String, boundary: String, raw: String,
                           fix: String) -> CaretSuggestion? {
        let replace = word + boundary
        guard fix != word, CaretHintLogic.standsAlone(before: before, token: replace) else { return nil }
        let head = String(before.unicodeScalars.dropLast(replace.unicodeScalars.count))
        guard AutoCorrect.caseAllows(raw, sentenceStart: AutoCorrect.isSentenceStart(head)) else { return nil }
        return CaretSuggestion(kind: .typo, display: fix, replace: replace, insert: fix + boundary)
    }
}

/// Tần suất enlexicon (0–255) — = EnglishLite.frequency của macOS (process con này đã giải mã
/// enlexicon thành SwipeEnglish.lexicon cho Thêm dấu).
extension SwipeEnglish {
    static func frequency(of word: String) -> Int? { index(of: word).map { Int(lexicon.freq[$0]) } }
}

// MARK: - 2. Thêm dấu cho cụm không dấu (= ToneRunLogic)

enum ToneRunLogic {
    static let minSyllables = 3
    static let maxSyllables = 40
    static let window = 320

    enum Trigger: Equatable { case sentenceEnd, pause }

    private static let edgePunct = Set(",;:\"'()[]…“”‘’.!?")

    static func isUnaccentedSyllable(_ chunk: Substring) -> Bool {
        var c = chunk
        while let f = c.first, edgePunct.contains(f) { c = c.dropFirst() }
        while let l = c.last, edgePunct.contains(l) { c = c.dropLast() }
        guard !c.isEmpty, c.count <= 7,
              c.unicodeScalars.allSatisfy({ ($0.value >= 97 && $0.value <= 122) || ($0.value >= 65 && $0.value <= 90) }),
              !c.dropFirst().contains(where: \.isUppercase) || c.allSatisfy(\.isUppercase) else { return false }
        let w = c.lowercased()
        guard !EnglishContextLookup.opensEnglishRun(w) else { return false }
        if SyllableValidator.isValidSyllable(w, teencode: false) { return true }
        guard let i = w.firstIndex(where: { "aeiouy".contains($0) }) else { return false }
        let acute = (String(w[...i]) + "\u{301}" + String(w[w.index(after: i)...])).precomposedStringWithCanonicalMapping
        return SyllableValidator.isValidSyllable(acute, teencode: false)
    }

    /// Bộ đếm ở ranh giới — bản chạy thật nằm ở frontend (linux/common caret_hints.cpp,
    /// cùng quy tắc); bản này giữ cho self-test so khớp macOS.
    struct Tracker: Equatable {
        private(set) var count = 0
        mutating func reset() { count = 0 }

        mutating func feed(chunk: String, boundary: String) -> Trigger? {
            guard let b = boundary.first, boundary.count == 1 else { count = 0; return nil }
            if b.isNewline { count = 0; return nil }
            if b.isWhitespace {
                if chunk.isEmpty { return nil }
                if let l = chunk.last, ".!?".contains(l) { count = 0; return nil }
                count = isUnaccentedSyllable(Substring(chunk)) ? min(count + 1, maxSyllables) : 0
                return count >= minSyllables ? .pause : nil
            }
            if ".!?".contains(b) {
                let ok = !chunk.isEmpty && isUnaccentedSyllable(Substring(chunk))
                let n = ok ? count + 1 : 0
                count = 0
                return n >= minSyllables ? .sentenceEnd : nil
            }
            return nil
        }
    }

    static func run(before: String) -> String? {
        let s = Array(before.unicodeScalars)
        var end = s.count
        var start = end, n = 0
        func isWs(_ c: Unicode.Scalar) -> Bool { c == " " || c == "\t" || c == "\u{00A0}" }
        func isNl(_ c: Unicode.Scalar) -> Bool { c == "\n" || c == "\r" }
        while end > 0 {
            var ws = end
            while ws > 0, isWs(s[ws - 1]) { ws -= 1 }
            if ws > 0, isNl(s[ws - 1]) { break }
            if ws == 0 { break }
            var cs = ws
            while cs > 0, !isWs(s[cs - 1]), !isNl(s[cs - 1]) { cs -= 1 }
            var u = String.UnicodeScalarView(); u.append(contentsOf: s[cs..<ws])
            let chunk = String(u)
            if n > 0, let l = chunk.last, ".!?".contains(l) { break }
            guard isUnaccentedSyllable(Substring(chunk)) else { break }
            n += 1
            start = cs
            end = cs
            if n >= maxSyllables { break }
        }
        guard n >= minSyllables else { return nil }
        var u = String.UnicodeScalarView(); u.append(contentsOf: s[start...])
        return String(u)
    }

    static func suggestion(run: String, restored: String) -> CaretSuggestion? {
        guard !run.isEmpty, restored != run,
              restored.unicodeScalars.count == run.unicodeScalars.count else { return nil }
        var display = String(restored.drop { $0 == " " || $0 == "\t" }.reversed().drop { $0 == " " || $0 == "\t" }.reversed())
        if display.count > 60 { display = "…" + display.suffix(59) }
        return CaretSuggestion(kind: .tones, display: display, replace: run, insert: restored)
    }
}

// MARK: - 3. Ngày giờ (= DateHintLogic)

enum DateHintLogic {
    enum Phrase: Equatable { case today, tomorrow, yesterday, now, lunar, tet }

    private static let vietnamese: [String: [String: Phrase]] = [
        "hôm": ["nay": .today, "qua": .yesterday],
        "ngày": ["mai": .tomorrow, "âm": .lunar],
        "bây": ["giờ": .now],
        "âm": ["lịch": .lunar],
    ]
    /// Một từ đứng riêng (từ trước bất kỳ): "ÂL␣" ⇒ âm lịch hôm nay; "Tết␣" ⇒ ngày dương của
    /// mùng 1 Tết kế tiếp (Tab GIỮ chữ "Tết" như đã gõ, nối ngày: "Tết 06/02/2027 ").
    private static let single: [String: Phrase] = ["âl": .lunar, "tết": .tet]

    private static func isPair(prevRun: String, run: String) -> Bool {
        vietnamese[prevRun.lowercased().precomposedStringWithCanonicalMapping]?[
            run.lowercased().precomposedStringWithCanonicalMapping] != nil
    }
    private static let english: [String: Phrase] = [
        "today": .today, "tomorrow": .tomorrow, "yesterday": .yesterday, "now": .now,
    ]

    static func detect(boundary: String?, prevRun: String, run: String,
                       isEnglish: (String) -> Bool) -> Phrase? {
        guard boundary == " ", !run.isEmpty, run.count <= 9 else { return nil }
        let w = run.lowercased().precomposedStringWithCanonicalMapping
        let p = prevRun.lowercased().precomposedStringWithCanonicalMapping
        if let m = vietnamese[p]?[w] { return m }
        if let m = single[w] { return m }
        if let m = english[w], !p.isEmpty, p.allSatisfy({ $0.isASCII && $0.isLetter }), isEnglish(p) { return m }
        return nil
    }

    /// Giờ địa phương lúc kích hoạt (frontend: localtime_r).
    struct LocalTime: Equatable {
        var year: Int, month: Int, day: Int, hour: Int, minute: Int
    }

    /// Ngày Gregorian ↔ số ngày (thuật toán civil của H. Hinnant).
    private static func days(_ y0: Int, _ m: Int, _ d: Int) -> Int {
        let y = m <= 2 ? y0 - 1 : y0
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let doy = (153 * (m + (m > 2 ? -3 : 9)) + 2) / 5 + d - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146097 + doe - 719468
    }

    private static func civil(_ z0: Int) -> (Int, Int, Int) {
        let z = z0 + 719468
        let era = (z >= 0 ? z : z - 146096) / 146097
        let doe = z - era * 146097
        let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let d = doy - (153 * mp + 2) / 5 + 1
        let m = mp < 10 ? mp + 3 : mp - 9
        return (yoe + era * 400 + (m <= 2 ? 1 : 0), m, d)
    }

    private static func pad(_ n: Int, _ w: Int) -> String {
        let s = String(n)
        return s.count >= w ? s : String(repeating: "0", count: w - s.count) + s
    }

    /// "28/09/2026" (ngày), "21:35" (giờ), âm lịch hôm nay "30/9 năm Bính Ngọ", Tết kế tiếp
    /// "06/02/2027".
    static func format(_ p: Phrase, now t: LocalTime) -> String {
        let delta: Int
        switch p {
        case .now: return pad(t.hour, 2) + ":" + pad(t.minute, 2)
        case .lunar: return LunarCalendar.text(day: t.day, month: t.month, year: t.year)
        case .tet: return LunarCalendar.nextTetText(day: t.day, month: t.month, year: t.year)
        case .today: delta = 0
        case .tomorrow: delta = 1
        case .yesterday: delta = -1
        }
        let (y, m, d) = civil(days(t.year, t.month, t.day) + delta)
        return pad(d, 2) + "/" + pad(m, 2) + "/" + pad(y, 4)
    }

    static func suggestion(before: String, prevRun: String, run: String, phrase: Phrase,
                           now: LocalTime) -> CaretSuggestion? {
        let replace = (isPair(prevRun: prevRun, run: run) ? prevRun + " " : "") + run + " "
        guard CaretHintLogic.standsAlone(before: before, token: replace) else { return nil }
        let value = format(phrase, now: now)
        let insert = phrase == .tet ? run + " " + value + " " : value + " "
        return CaretSuggestion(kind: .date, display: value, replace: replace, insert: insert)
    }
}
