// TelexEngine.swift
// Simple Telex (strict). Hot path works over fixed-capacity (32) buffers.
//
// Strategy: keep the raw keystroke buffer (letters only). On every key the word is
// re-parsed left-to-right into (letters + tone), then rendered with old-style tone
// placement. Diffing the new render against the previous one yields the minimal
// (backspaces, insert) edit for the input client. Backspace pops one raw key and
// re-parses; the raw buffer also feeds auto-restore of non-Vietnamese words.
//
// Note: fixed-capacity `[UInt8]`/`[UInt32]` buffers are pre-reserved (capacity 32)
// and mutated in place — including the render/parse scratch buffers, which live on
// the instance so the hot path allocates nothing per keystroke. InlineArray would
// give a stronger zero-heap guarantee but requires macOS 26; reserved arrays keep
// the macOS 14 deployment target.

public enum TelexAction: Equatable {
    /// Not handled by the engine; let the system insert the character.
    case passthrough
    /// Replace `backspaces` trailing characters already on screen with `insert`.
    /// `insert` may be empty (pure consume) or `backspaces` may be 0 (pure insert).
    case replace(backspaces: Int, insert: String)
    /// Nothing to do.
    case none
}

/// One output letter before tone placement.
private struct LetterUnit {
    var base: UInt8 = 0     // lowercase ascii
    var mark: Mark = .none
    var upper: Bool = false
}

public struct TelexEngine {

    /// "Bỏ dấu tự do" (free mark placement). When true, modifier keys (circumflex
    /// aa/ee/oo, breve/horn w) reach back over consonants to the target vowel
    /// ("ama"→âm, "trangw"→trăng). When false (default = Minimal Telex / strict), a
    /// modifier only transforms the vowel adjacent to it (across intervening vowels
    /// still, but never a consonant): "ama"→ama, "trangw"→trangw, but "aam"→âm and
    /// "trawng"→trăng. Preserved across `reset()`; the caller sets it from settings.
    public var freeMarking = false

    /// Tone-mark placement style for OPEN glide-initial diphthongs. false (default) =
    /// OLD style (`hòa`, `khỏe`, `thủy`); true = MODERN/new style (`hoà`, `khoẻ`,
    /// `thuý`). Only affects `oa`/`oe`/`uy` open nuclei — every other placement
    /// (ê/ơ magnet, coda, qu/gi glide, `múa`/`mía` falling diphthongs) is identical.
    /// Preserved across `reset()`; the caller sets it from settings.
    public var modernTone = false

    /// Live spell-check. When true, as soon as the word
    /// in progress can no longer become a valid Vietnamese syllable
    /// (`SyllableValidator.isValidPrefix` fails), the engine STOPS transforming: every
    /// further key is emitted literally, so foreign words / URLs stop being mangled
    /// mid-word ("gôgle…" no longer keeps accreting diacritics). Already-applied edits
    /// stay on screen until the word boundary, where auto-restore reverts the whole
    /// token. Preserved across `reset()`; the caller sets it from settings.
    public var liveSpellCheck = false

    /// Simple Telex. When true, a STANDALONE `w` (no adjacent
    /// a/o/u to horn/breve) never becomes `ư` — it stays a literal `w`, so `ư` must be
    /// typed `uw` ("cw"→cw, not cư; "cuw"→cư). `w` still breves/horns an adjacent vowel
    /// (aw→ă, ow→ơ, uw→ư). (Brackets are already literal in
    /// this engine, the other Simple-Telex difference.) Preserved across `reset()`.
    public var simpleTelex = false

    static let capacity = 32

    // Raw keystrokes that make up the current word (ascii, case preserved).
    private var raw: [UInt8]
    private var rawCount = 0

    // Current on-screen composition (scalar values) — kept to diff against.
    private var out: [UInt32]
    private var outCount = 0

    // Scratch buffers reused by render/parse every keystroke (never allocated on
    // the hot path). Valid only during/right after the call that filled them.
    private var scratch: [UInt32]      // render output, diffed against `out`
    private var letters: [LetterUnit]  // parse output
    private var rawLetter: [Int]       // raw index -> display-letter provenance
    private var toneKeys: [Int]        // raw indices of deferred tone/z keys
    private var vowelIdx: [Int]        // vowel positions (tone placement)

    // Raw index from which keys are emitted literally because live spell-check found
    // the word can no longer be valid Vietnamese. Int.max = not disabled. Unlike
    // `markCancelled` this does NOT suppress boundary auto-restore (foreign words
    // still revert to raw). Reset per word.
    private var disabledAtCount = Int.max

    // True when the current word's parse involved an explicit diacritic CANCELLATION
    // (double tone key ss/ff/rr/xx/jj, z, double circumflex aaa/eee/ooo, double
    // breve/horn aww, double-d ddd). That is a deliberate "I want the literal letter"
    // gesture, so auto-restore leaves the word alone even when it isn't a valid
    // Vietnamese syllable: "iss"→is (not restored to "iss"), "ass"→as.
    private var markCancelled = false

    public init() {
        raw = [UInt8](repeating: 0, count: Self.capacity)
        out = [UInt32](repeating: 0, count: Self.capacity)
        scratch = [UInt32](repeating: 0, count: Self.capacity)
        letters = [LetterUnit](repeating: LetterUnit(), count: Self.capacity)
        rawLetter = [Int](repeating: -1, count: Self.capacity)
        toneKeys = [Int](repeating: 0, count: Self.capacity)
        vowelIdx = [Int](repeating: 0, count: Self.capacity)
    }

    public var isEmpty: Bool { rawCount == 0 }

    // MARK: - Public entry points

    /// Feed one typed character. Only ascii letters compose; other characters
    /// should be routed through `commitBoundary` by the caller.
    public mutating func feed(_ ch: Character) -> TelexAction {
        guard let ascii = ch.asciiValue, isLetter(ascii) else {
            return .passthrough
        }
        guard rawCount < Self.capacity else { return .passthrough }

        raw[rawCount] = ascii
        rawCount += 1

        var cancelled = false
        let newCount = render(cancelled: &cancelled)
        markCancelled = cancelled

        // Live spell-check: once the word can no longer be valid Vietnamese, freeze
        // transforms from the NEXT key on (current output unchanged). See disabledAtCount.
        if liveSpellCheck, disabledAtCount == Int.max, !prefixIsValid(scratch, newCount) {
            disabledAtCount = rawCount
        }

        // No-transform fast path: render is exactly the previous output plus this
        // character. Let the system insert it (cheapest, no flicker).
        if newCount == outCount + 1,
           scratch[newCount - 1] == UInt32(ascii),
           prefixMatches(scratch, upTo: outCount) {
            copyOut(newCount)
            return .passthrough
        }

        let action = diff(scratch, newCount)
        copyOut(newCount)
        return action
    }

    /// Backspace: delete the whole last DISPLAYED character (not just undo one
    /// keystroke), then reconcile the screen. Typing "khoo" shows "khô"; one
    /// backspace gives "kh", not "kho". Achieved by dropping every raw key that
    /// produced the last displayed letter (tracked via `rawLetter` provenance).
    public mutating func backspace() -> TelexAction {
        guard rawCount > 0 else { return .passthrough }

        // Editing the word re-opens transforms; a still-invalid word simply re-disables
        // on the next forward key (backspace itself never adds a transform).
        disabledAtCount = Int.max

        var cancelledIgnored = false
        let (letterCount, _, _) = parse(cancelled: &cancelledIgnored)

        if letterCount == 0 {
            rawCount -= 1                        // nothing on screen -> drop one key
        } else {
            let last = letterCount - 1
            var w = 0
            for r in 0..<rawCount where rawLetter[r] != last {
                raw[w] = raw[r]; w += 1
            }
            rawCount = w
        }

        var cancelled = false
        let newCount = render(cancelled: &cancelled)
        markCancelled = cancelled
        let action = diff(scratch, newCount)
        copyOut(newCount)
        return action
    }

    /// Word boundary reached. Optionally auto-restore the raw keystrokes when the
    /// composed word is not a valid Vietnamese syllable. Resets the engine.
    /// The caller inserts the boundary character itself afterwards.
    public mutating func commitBoundary(autoRestore: Bool) -> TelexAction {
        defer { reset() }
        guard rawCount > 0 else { return .none }
        // Skip restore when the user cancelled a diacritic on purpose ("iss"→is).
        if autoRestore, !markCancelled {
            let word = composed
            if !word.isEmpty, !SyllableValidator.isValidSyllable(word) {
                let restored = rawKeystrokes
                if restored != word {
                    return .replace(backspaces: outCount, insert: restored)
                }
            }
        }
        return .none
    }

    /// Final text to commit at a word boundary, with auto-restore applied
    /// (non-Vietnamese syllables fall back to the raw keystrokes). Resets the engine.
    /// Used by the marked-text controller path.
    public mutating func commitText(autoRestore: Bool) -> String {
        defer { reset() }
        let word = composed
        if autoRestore, !markCancelled, !word.isEmpty, !SyllableValidator.isValidSyllable(word) {
            return rawKeystrokes
        }
        return word
    }

    public mutating func reset() {
        rawCount = 0
        outCount = 0
        markCancelled = false
        disabledAtCount = Int.max
    }

    /// True if the first `n` scalars of `out` form a valid Vietnamese syllable prefix.
    private func prefixIsValid(_ out: [UInt32], _ n: Int) -> Bool {
        var s = String.UnicodeScalarView()
        s.reserveCapacity(n)
        for i in 0..<n { s.append(Unicode.Scalar(out[i])!) }
        return SyllableValidator.isValidPrefix(String(s))
    }

    // MARK: - Test / caller helpers

    /// Current composed word.
    public var composed: String {
        var s = String.UnicodeScalarView()
        s.reserveCapacity(outCount)
        for i in 0..<outCount { s.append(Unicode.Scalar(out[i])!) }
        return String(s)
    }

    /// The raw keystrokes typed for the current word.
    public var rawKeystrokes: String {
        var s = String.UnicodeScalarView()
        s.reserveCapacity(rawCount)
        for i in 0..<rawCount { s.append(Unicode.Scalar(raw[i])) }
        return String(s)
    }

    // MARK: - Rendering

    @inline(__always)
    private mutating func copyOut(_ n: Int) {
        for i in 0..<n { out[i] = scratch[i] }
        outCount = n
    }

    /// Re-parse `raw` and render composed scalars into `scratch`. Returns count.
    /// `cancelled` is set true if the parse hit an explicit diacritic-cancel gesture.
    private mutating func render(cancelled: inout Bool) -> Int {
        let (letterCount, toneIdx, tone) = parse(cancelled: &cancelled)

        var n = 0
        for k in 0..<letterCount {
            let u = letters[k]
            var scalar = Tables.markedScalar(base: u.base, mark: u.mark, upper: u.upper)
            if k == toneIdx { scalar = Tables.applyTone(scalar, tone) }
            scratch[n] = scalar
            n += 1
        }
        return n
    }

    /// Parse `raw` into the `letters` scratch buffer. Also records, for each raw key,
    /// the index of the display letter it produced or modified (`rawLetter[i]`); tone
    /// / z keys map to the toned vowel. Returns letter count, tone-target letter
    /// index, tone.
    private mutating func parse(cancelled: inout Bool) -> (count: Int, toneIdx: Int, tone: Tone) {
        var letterCount = 0
        var tone: Tone = .none
        var toneKeyCount = 0
        for i in 0..<rawCount { rawLetter[i] = -1 }

        // A word starting with 'w' is English: Vietnamese has essentially no w-initial
        // syllable, so type it literally with no diacritics ("was"→was, "write"→write).
        // An initial ư is typed "uw", not "w". Applies in both modes.
        if rawCount >= 1, lowercased(raw[0]) == UInt8(ascii: "w") {
            for k in 0..<rawCount {
                appendLetter(&letterCount,
                             base: lowercased(raw[k]), mark: .none, upper: isUpperAscii(raw[k]))
                rawLetter[k] = k
            }
            return (letterCount, -1, .none)
        }

        var i = 0
        while i < rawCount {
            let at = i
            let key = raw[i]
            i += 1
            let lower = lowercased(key)
            let upper = isUpperAscii(key)

            // Once a diacritic has been cancelled, the word is English: every further
            // key is literal (no tone/mark), so "messs"→mess (not "més") and the whole
            // token stays as typed. The cancel itself is handled by the branches below,
            // which set `cancelled`; from the next key on this short-circuits.
            // Cancelled diacritic, OR live spell-check froze the word from here on:
            // emit every remaining key literally (no tone/mark transforms).
            if cancelled || at >= disabledAtCount {
                appendLetter(&letterCount, base: lower, mark: .none, upper: upper)
                rawLetter[at] = letterCount - 1
                continue
            }

            // Tone keys: s f r x j
            if let t = toneForKey(lower) {
                if hasVowel(letterCount) {
                    if tone == t {
                        tone = .none // double same tone -> cancel, emit literal
                        cancelled = true
                        appendLetter(&letterCount, base: lower, mark: .none, upper: upper)
                        rawLetter[at] = letterCount - 1
                    } else {
                        tone = t
                        toneKeys[toneKeyCount] = at; toneKeyCount += 1
                    }
                } else {
                    appendLetter(&letterCount, base: lower, mark: .none, upper: upper)
                    rawLetter[at] = letterCount - 1
                }
                continue
            }

            // z: clear tone (always consumed)
            if lower == UInt8(ascii: "z") {
                if tone != .none { cancelled = true }
                tone = .none
                toneKeys[toneKeyCount] = at; toneKeyCount += 1
                continue
            }

            // w: breve / horn modifier, or standalone ư. The modifier reaches back
            // over any coda to the nearest a/o/u, so "quatw"->quăt, "moiw"->mơi,
            // "nguoiwf"->người even when w is typed after the final consonant.
            if lower == UInt8(ascii: "w") {
                var tIdx = -1
                var k = letterCount - 1
                while k >= 0 {
                    let b = letters[k].base
                    if b == UInt8(ascii: "a") || b == UInt8(ascii: "o") || b == UInt8(ascii: "u") { tIdx = k; break }
                    // Strict (Minimal Telex): the horn/breve may cross intervening
                    // vowels (offglides: người) but NOT a consonant coda, so "trangw"
                    // and "quatw" stay literal. Free mode scans all the way back.
                    if !freeMarking && !isVowelAscii(b) { break }
                    k -= 1
                }
                // "ua" nucleus: w horns the u (→ ưa: mưa, chưa, nữa), not breve the a
                // — "uă" is not a valid Vietnamese nucleus. So an unmarked 'a' target
                // whose immediate predecessor is a REAL, unmarked 'u' vowel retargets
                // to that u. Excludes the "qu" glide ("quatw"→quăt) and "oa" (→ oă:
                // hoăc), where breve on a is correct. Makes marks order-free:
                // "nuawx" and "nuwax" both give "nữa".
                if tIdx >= 1,
                   letters[tIdx].base == UInt8(ascii: "a"), letters[tIdx].mark == .none,
                   letters[tIdx - 1].base == UInt8(ascii: "u"), letters[tIdx - 1].mark == .none,
                   !(tIdx >= 2 && letters[tIdx - 2].base == UInt8(ascii: "q")) {
                    tIdx -= 1
                }
                if tIdx >= 0 {
                    let p = letters[tIdx]
                    if p.mark == .none && p.base == UInt8(ascii: "a") {
                        letters[tIdx].mark = .breve; rawLetter[at] = tIdx; continue
                    }
                    if p.mark == .none && (p.base == UInt8(ascii: "o") || p.base == UInt8(ascii: "u")) {
                        letters[tIdx].mark = .horn; rawLetter[at] = tIdx; continue
                    }
                    if p.mark == .breve && p.base == UInt8(ascii: "a") {
                        letters[tIdx].mark = .none
                        cancelled = true
                        appendLetter(&letterCount, base: UInt8(ascii: "w"), mark: .none, upper: upper)
                        rawLetter[at] = letterCount - 1; continue
                    }
                    if p.mark == .horn && (p.base == UInt8(ascii: "o") || p.base == UInt8(ascii: "u")) {
                        letters[tIdx].mark = .none
                        cancelled = true
                        appendLetter(&letterCount, base: UInt8(ascii: "w"), mark: .none, upper: upper)
                        rawLetter[at] = letterCount - 1; continue
                    }
                }
                // Standalone w -> ư only when the letters so far form an onset that
                // can legally begin a "ư" syllable (cư, thư, giữ, ngư…). After an
                // onset that never precedes ư (k, q, gh, ngh, p) or after another
                // vowel, keep the literal 'w' so English words type through
                // ("kw", "windows", "ew"); auto-restore then leaves them intact.
                // Simple Telex disables this entirely — a lone `w` is always literal
                // (type `uw` for ư).
                if !simpleTelex && standaloneHornUAllowed(letterCount) {
                    appendLetter(&letterCount, base: UInt8(ascii: "u"), mark: .horn, upper: upper)
                } else {
                    appendLetter(&letterCount, base: UInt8(ascii: "w"), mark: .none, upper: upper)
                }
                rawLetter[at] = letterCount - 1
                continue
            }

            // circumflex doublers: a e o
            if lower == UInt8(ascii: "a") || lower == UInt8(ascii: "e") || lower == UInt8(ascii: "o") {
                if letterCount > 0 {
                    let pIdx = letterCount - 1
                    let p = letters[pIdx]
                    if p.base == lower && p.mark == .none {
                        letters[pIdx].mark = .circumflex; rawLetter[at] = pIdx; continue
                    }
                    if p.base == lower && p.mark == .circumflex {
                        letters[pIdx].mark = .none
                        cancelled = true
                        appendLetter(&letterCount, base: lower, mark: .none, upper: upper)
                        rawLetter[at] = letterCount - 1; continue
                    }
                }
                // Free mode ("bỏ dấu tự do"): reach back over a consonant coda to
                // circumflex an earlier bare same-vowel — "ama"→âm, "coto"→côt. Stops
                // at the first vowel from the end, so it never crosses another vowel.
                // Strict mode skips this: "ama"/"coto"/"data" stay literal.
                if freeMarking {
                    var k = letterCount - 1
                    while k >= 0 && !isVowelAscii(letters[k].base) { k -= 1 }
                    if k >= 0, letters[k].base == lower, letters[k].mark == .none {
                        letters[k].mark = .circumflex; rawLetter[at] = k; continue
                    }
                }
                appendLetter(&letterCount, base: lower, mark: .none, upper: upper)
                rawLetter[at] = letterCount - 1
                continue
            }

            // d doubler -> đ
            if lower == UInt8(ascii: "d") {
                if letterCount > 0 {
                    let pIdx = letterCount - 1
                    let p = letters[pIdx]
                    if p.base == UInt8(ascii: "d") && p.mark == .none {
                        letters[pIdx].mark = .bar; rawLetter[at] = pIdx; continue
                    }
                    if p.base == UInt8(ascii: "d") && p.mark == .bar {
                        letters[pIdx].mark = .none
                        cancelled = true
                        appendLetter(&letterCount, base: UInt8(ascii: "d"), mark: .none, upper: upper)
                        rawLetter[at] = letterCount - 1; continue
                    }
                }
                // A trailing d (after a formed syllable) converts the onset d to đ,
                // so "dand"->đan, "duwowngd"->đường even without doubling at the start.
                if letterCount > 1, letters[0].base == UInt8(ascii: "d"), letters[0].mark == .none {
                    letters[0].mark = .bar; rawLetter[at] = 0; continue
                }
                appendLetter(&letterCount, base: UInt8(ascii: "d"), mark: .none, upper: upper)
                rawLetter[at] = letterCount - 1
                continue
            }

            // ordinary letter
            appendLetter(&letterCount, base: lower, mark: .none, upper: upper)
            rawLetter[at] = letterCount - 1
        }

        // ươ propagation: in a "uo" cluster, if EITHER letter is horned, mirror it
        // onto the other so both become ươ — in a closed syllable (coda/offglide
        // after), and not the "qu" glide. This covers both key orders, so fast
        // typing that reorders o/w ("uow" vs "uwo") still yields ươ: trường, được,
        // nước, người, sương. Stays plain "uơ" when the o is the last letter (open:
        // thuở, huơ) or after "qu" (quở, quởn).
        for k in 1..<max(1, letterCount) {
            guard letters[k - 1].base == UInt8(ascii: "u"),
                  letters[k].base == UInt8(ascii: "o") else { continue }
            let prevHorn = letters[k - 1].mark == .horn
            let curHorn = letters[k].mark == .horn
            guard prevHorn != curHorn else { continue }   // exactly one horned
            let oIsLast = (k == letterCount - 1)
            let isQuGlide = (k >= 2 && letters[k - 2].base == UInt8(ascii: "q"))
            if !oIsLast && !isQuGlide {
                letters[k - 1].mark = .horn
                letters[k].mark = .horn
            }
        }

        // Tone placement; map deferred tone/z keys onto the toned vowel (or the
        // last letter when there is no tone, so they group with it for backspace).
        var effTone = tone
        var toneIdx = tone == .none ? -1 : toneVowelIndex(letterCount)
        // Stop codas (-c, -ch, -p, -t) only allow sắc (´) and nặng (.). Drop an
        // invalid huyền/hỏi/ngã (e.g. "batf" stays "bat", not "bàt").
        if toneIdx >= 0, effTone == .grave || effTone == .hook || effTone == .tilde,
           hasStopCoda(letterCount) {
            effTone = .none
            toneIdx = -1
        }
        let target = toneIdx >= 0 ? toneIdx : max(0, letterCount - 1)
        for j in 0..<toneKeyCount { rawLetter[toneKeys[j]] = target }
        return (letterCount, toneIdx, effTone)
    }

    // MARK: - Tone placement (old style: òa, úy)

    private mutating func toneVowelIndex(_ count: Int) -> Int {
        var vcount = 0

        var start = 0
        // qu: the u after a leading q is part of the onset.
        if count >= 2, letters[0].base == UInt8(ascii: "q"),
           letters[1].base == UInt8(ascii: "u"), letters[1].mark == .none {
            start = 2
        }
        // gi: the i after a leading g is part of the onset, if a vowel follows.
        else if count >= 3, letters[0].base == UInt8(ascii: "g"),
                letters[1].base == UInt8(ascii: "i"), letters[1].mark == .none,
                isVowelAscii(letters[2].base) {
            start = 2
        }

        for k in start..<count where isVowelAscii(letters[k].base) {
            vowelIdx[vcount] = k
            vcount += 1
        }
        if vcount == 0 {
            for k in 0..<count where isVowelAscii(letters[k].base) { return k }
            return count - 1
        }

        // 1) A marked vowel takes the tone (last one covers ươ -> ơ).
        var lastMarked = -1
        for j in 0..<vcount where letters[vowelIdx[j]].mark != .none { lastMarked = vowelIdx[j] }
        if lastMarked >= 0 { return lastMarked }

        // 2) No marked vowel.
        if vcount == 1 { return vowelIdx[0] }

        let hasCoda = vowelIdx[vcount - 1] < (count - 1)
        if vcount == 2 {
            if hasCoda { return vowelIdx[1] }   // closed: second vowel (toàn)
            // Open nucleus. OLD style: first vowel (hóa, khỏe, thúy). MODERN style:
            // second vowel BUT only for a /w/-glide-initial diphthong (oa, oe, uy →
            // hoà, khoẻ, uý). Falling diphthongs (ua, ưa, ia, ai, oi…) keep the first
            // vowel in both styles (múa, mía, tài), so only oa/oe/uy differ.
            if modernTone {
                let a = letters[vowelIdx[0]].base, b = letters[vowelIdx[1]].base
                let glideInitial =
                    (a == UInt8(ascii: "o") && (b == UInt8(ascii: "a") || b == UInt8(ascii: "e"))) ||
                    (a == UInt8(ascii: "u") && b == UInt8(ascii: "y"))
                if glideInitial { return vowelIdx[1] }
            }
            return vowelIdx[0]                  // open, old style: first vowel (hóa, úy)
        }
        return vowelIdx[1]                      // 3 vowels: middle (oái, ngoáy)
    }

    // MARK: - Diffing

    @inline(__always)
    private func prefixMatches(_ newOut: [UInt32], upTo n: Int) -> Bool {
        for i in 0..<n where newOut[i] != out[i] { return false }
        return true
    }

    private func diff(_ newOut: [UInt32], _ newCount: Int) -> TelexAction {
        var lcp = 0
        let limit = min(newCount, outCount)
        while lcp < limit && newOut[lcp] == out[lcp] { lcp += 1 }

        let backspaces = outCount - lcp
        if backspaces == 0 && lcp == newCount {
            return .replace(backspaces: 0, insert: "") // consumed no-op
        }
        var s = String.UnicodeScalarView()
        s.reserveCapacity(newCount - lcp)
        for i in lcp..<newCount { s.append(Unicode.Scalar(newOut[i])!) }
        return .replace(backspaces: backspaces, insert: String(s))
    }

    // MARK: - Small helpers

    /// Onsets that can begin a "ư" nucleus. A standalone `w` becomes ư only after
    /// one of these; after k/q/gh/ngh/p, after "qu", or after a vowel, `w` stays a
    /// literal letter (C3: block spurious "kư" for English words like "kw").
    private static let onsetsAllowingStandaloneU: Set<String> = [
        "", "b", "c", "ch", "d", "g", "h", "kh", "l", "m", "n", "ng", "nh",
        "ph", "r", "s", "t", "th", "tr", "v", "x", "gi",
    ]

    /// True if the letters typed before a standalone `w` form an onset (built from
    /// base letters, marks ignored — đ reads as "d") that can precede ư.
    private func standaloneHornUAllowed(_ count: Int) -> Bool {
        if count == 0 { return true }
        var s = String.UnicodeScalarView()
        s.reserveCapacity(count)
        for k in 0..<count { s.append(Unicode.Scalar(letters[k].base)) }
        return Self.onsetsAllowingStandaloneU.contains(String(s))
    }

    @inline(__always)
    private func hasVowel(_ count: Int) -> Bool {
        for k in 0..<count where isVowelAscii(letters[k].base) { return true }
        return false
    }

    /// Does the syllable end in a stop coda (-p, -t, -c, -ch)? Such codas only
    /// allow sắc/nặng. Only meaningful when a vowel precedes (checked by caller).
    @inline(__always)
    private func hasStopCoda(_ count: Int) -> Bool {
        guard count > 0 else { return false }
        let last = letters[count - 1].base
        if last == UInt8(ascii: "p") || last == UInt8(ascii: "t") || last == UInt8(ascii: "c") {
            return true
        }
        // "ch" coda: trailing h preceded by c.
        if last == UInt8(ascii: "h"), count >= 2, letters[count - 2].base == UInt8(ascii: "c") {
            return true
        }
        return false
    }

    @inline(__always)
    private mutating func appendLetter(_ count: inout Int,
                                       base: UInt8, mark: Mark, upper: Bool) {
        guard count < Self.capacity else { return }
        letters[count] = LetterUnit(base: base, mark: mark, upper: upper)
        count += 1
    }
}

// MARK: - ascii helpers

@inline(__always)
func isLetter(_ c: UInt8) -> Bool {
    (c >= UInt8(ascii: "a") && c <= UInt8(ascii: "z")) ||
    (c >= UInt8(ascii: "A") && c <= UInt8(ascii: "Z"))
}

@inline(__always)
func isUpperAscii(_ c: UInt8) -> Bool {
    c >= UInt8(ascii: "A") && c <= UInt8(ascii: "Z")
}

@inline(__always)
func lowercased(_ c: UInt8) -> UInt8 {
    isUpperAscii(c) ? c &+ 32 : c
}
