// TelexEngine.swift
// Simple Telex (strict). Hot path works over fixed-capacity (32) buffers.
//
// Strategy: keep the raw keystroke buffer (letters only) plus an INCREMENTAL parse
// state: each new key is folded into the persistent (letters + tone) state by one
// `parseStep` — the word is no longer re-parsed from scratch per key. Rendering
// copies the letters into a scratch, applies the post-passes (ươ propagation, tone
// placement) on the copy, and diffs against the previous render to yield the
// minimal (backspaces, insert) edit for the input client. Backspace and mid-word
// setting changes fall back to a full rebuild (replay of parseSteps) — identical
// semantics, since the parse is a left-to-right fold over the raw keys.
//
// Note: fixed-capacity `[UInt8]`/`[UInt32]` buffers are pre-reserved (capacity 32)
// and mutated in place — including the render/parse scratch buffers, which live on
// the instance so the hot path allocates nothing per keystroke (the live
// spell-check runs on a flat trie, not Strings). InlineArray would give a stronger
// zero-heap guarantee but requires macOS 26; reserved arrays keep the macOS 14
// deployment target.

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

    // Scratch buffers reused every keystroke (never allocated on the hot path).
    // Valid only during/right after the call that filled them.
    private var scratch: [UInt32]              // render output, diffed against `out`
    private var renderLetters: [LetterUnit]    // render-time copy of `letters` (post-passes)
    private var basesScratch: [UInt8]          // folded bases for the trie prefix check
    private var rawLetter: [Int]               // raw index -> display-letter provenance
    private var toneKeys: [Int]                // raw indices of deferred tone/z keys
    private var vowelIdx: [Int]                // vowel positions (tone placement)

    // MARK: Incremental parse state (the left-to-right fold, persisted per key)
    //
    // `letters[0..<pCount]` + `pTone` are the fold of raw[0..<pProcessed]. feed()
    // advances it by ONE parseStep; backspace / a mid-word setting flip rebuild it
    // by replaying every key (same semantics — the parse is a pure fold). The
    // render post-passes (ươ propagation, tone placement) never mutate this state:
    // they run on the `renderLetters` copy.
    private var letters: [LetterUnit]
    private var pCount = 0
    private var pTone: Tone = .none
    private var pToneKeyCount = 0
    private var pCancelled = false
    private var pProcessed = 0
    private var pWWord = false          // word starts with 'w' -> whole word literal
    private var pFreeMarking = false    // settings snapshot the state was built with
    private var pSimpleTelex = false

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

    // Effective tone of the last render (after the stop-coda drop) — the composed
    // word's tone, used by the zero-alloc boundary validation.
    private var lastEffTone: Tone = .none

    // True when a tone key (s f r x j, or z) was CONSUMED as a tone while typed
    // UPPERCASE. In a mixed-case word that is an English/code signal ("SaaS": the
    // trailing S applies sắc → "Sấ", a *valid* syllable that plain validation
    // would keep), so boundary auto-restore forces the raw keystrokes back. An
    // ALL-CAPS word is exempt — "VIEEJT"→VIỆT types tone keys uppercase
    // legitimately. Mark doublers (DDaay, AAn) are NOT counted: shift held across
    // a doubler is normal typing.
    private var upperToneKey = false

    public init() {
        raw = [UInt8](repeating: 0, count: Self.capacity)
        out = [UInt32](repeating: 0, count: Self.capacity)
        scratch = [UInt32](repeating: 0, count: Self.capacity)
        letters = [LetterUnit](repeating: LetterUnit(), count: Self.capacity)
        renderLetters = [LetterUnit](repeating: LetterUnit(), count: Self.capacity)
        basesScratch = [UInt8](repeating: 0, count: Self.capacity)
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

        // Fold the new key into the incremental parse state — or rebuild it when a
        // setting that changes parse behavior flipped mid-word (rare; the controller
        // re-applies settings every key, they just normally don't change mid-word).
        if pProcessed != rawCount - 1
            || pFreeMarking != freeMarking || pSimpleTelex != simpleTelex {
            rebuildParseState()
        } else {
            parseStep(rawCount - 1)
            pProcessed = rawCount
        }

        var newCount = render()
        markCancelled = pCancelled

        // Uppercase tone/mark key in a MIXED-case word ("OmS", "SaaS", "JavaScript")
        // → this is English/code, not Vietnamese. Freeze the WHOLE word to its raw
        // keystrokes IMMEDIATELY (not just at the boundary) so the tone never even
        // flashes on screen ("OmS" stays "OmS", never briefly "Óm"). Rebuild with
        // transforms disabled from the first key, then re-render.
        if disabledAtCount == Int.max, forceRestoreUpperTone {
            disabledAtCount = 0
            rebuildParseState()
            newCount = render()
            markCancelled = pCancelled
        }

        // Live spell-check: once the word can no longer be valid Vietnamese, freeze
        // transforms from the NEXT key on (current output unchanged). See disabledAtCount.
        if liveSpellCheck, disabledAtCount == Int.max, !prefixIsValid(newCount) {
            disabledAtCount = rawCount
        }

        // No-transform fast path: render is exactly the previous output plus this
        // character. Let the system insert it (cheapest, no flicker).
        if newCount == outCount + 1,
           scratch[newCount - 1] == UInt32(ascii),
           commonPrefixLength(scratch, out, upTo: outCount) == outCount {
            copyOut(newCount)
            return .passthrough
        }

        let action = diff(newCount)
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
        // on the next forward key (backspace itself never adds a transform). The
        // provenance below must come from the UNFROZEN parse (historical semantics),
        // so rebuild + render once with the freeze lifted before filtering.
        disabledAtCount = Int.max
        rebuildParseState()
        _ = render()                             // maps tone-key provenance

        if pCount == 0 {
            rawCount -= 1                        // nothing on screen -> drop one key
        } else {
            let last = pCount - 1
            var w = 0
            for r in 0..<rawCount where rawLetter[r] != last {
                raw[w] = raw[r]; w += 1
            }
            rawCount = w
        }

        rebuildParseState()
        let newCount = render()
        markCancelled = pCancelled
        let action = diff(newCount)
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
        // Validation runs on letter classes + tone (no String); Strings are built
        // only when a restore actually happens.
        if autoRestore, !markCancelled, outCount > 0,
           forceRestoreUpperTone || !composedIsValidSyllable() {
            if compositionDiffersFromRaw() {
                return .replace(backspaces: outCount, insert: rawKeystrokes)
            }
        }
        return .none
    }

    /// Final text to commit at a word boundary, with auto-restore applied
    /// (non-Vietnamese syllables fall back to the raw keystrokes). Resets the engine.
    /// Used by the marked-text controller path.
    public mutating func commitText(autoRestore: Bool) -> String {
        defer { reset() }
        if autoRestore, !markCancelled, outCount > 0,
           forceRestoreUpperTone || !composedIsValidSyllable() {
            return rawKeystrokes
        }
        return composed
    }

    /// Zero-allocation twin of `SyllableValidator.isValidSyllable(String)` on the
    /// current composition: letter classes come from the render copy (post ươ
    /// propagation), the tone from the last render's effective tone.
    private mutating func composedIsValidSyllable() -> Bool {
        for k in 0..<pCount {
            basesScratch[k] = Tables.letterClass(base: renderLetters[k].base,
                                                 mark: renderLetters[k].mark)
        }
        return SyllableValidator.isValidSyllable(classes: basesScratch, count: pCount,
                                                 tone: lastEffTone)
    }

    /// True when the composed scalars differ from the raw keystrokes (i.e. some
    /// transform actually happened) — compared numerically, no Strings.
    private func compositionDiffersFromRaw() -> Bool {
        if outCount != rawCount { return true }
        for i in 0..<outCount where out[i] != UInt32(raw[i]) { return true }
        return false
    }

    /// Uppercase tone key in a MIXED-case word ("SaaS", "JavaScript") → English,
    /// restore even when the composed form happens to be a valid syllable ("Sấ").
    /// All-caps words keep uppercase tone keys ("VIEEJT"→VIỆT).
    private var forceRestoreUpperTone: Bool {
        guard upperToneKey else { return false }
        for i in 0..<rawCount where raw[i] >= UInt8(ascii: "a") && raw[i] <= UInt8(ascii: "z") {
            return true
        }
        return false
    }

    public mutating func reset() {
        rawCount = 0
        outCount = 0
        markCancelled = false
        upperToneKey = false
        disabledAtCount = Int.max
        pCount = 0
        pTone = .none
        pToneKeyCount = 0
        pCancelled = false
        pProcessed = 0
        pWWord = false
    }

    /// True if the current parse state's first `n` letters form a valid Vietnamese
    /// syllable prefix. Walks the validator's flat tries over the letters' folded
    /// bases (bit 7 = carries a mark) — no String, no hashing, no allocation.
    private mutating func prefixIsValid(_ n: Int) -> Bool {
        for k in 0..<n {
            basesScratch[k] = letters[k].base | (letters[k].mark != .none ? 0x80 : 0)
        }
        return SyllableValidator.isValidPrefix(bases: basesScratch, count: n)
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

    /// Render the current parse state into `scratch` (composed scalars) and return
    /// the count. Copies `letters` into `renderLetters` first, then applies the two
    /// post-passes (ươ propagation, tone placement) on the COPY — the persistent
    /// parse state stays exactly the raw fold, so incremental steps never see a
    /// post-pass side effect.
    private mutating func render() -> Int {
        let count = pCount
        for k in 0..<count { renderLetters[k] = letters[k] }

        // ươ propagation: in a "uo" cluster, if EITHER letter is horned, mirror it
        // onto the other so both become ươ — in a closed syllable (coda/offglide
        // after), and not the "qu" glide. This covers both key orders, so fast
        // typing that reorders o/w ("uow" vs "uwo") still yields ươ: trường, được,
        // nước, người, sương. Stays plain "uơ" when the o is the last letter (open:
        // thuở, huơ) or after "qu" (quở, quởn).
        for k in 1..<max(1, count) {
            guard renderLetters[k - 1].base == UInt8(ascii: "u"),
                  renderLetters[k].base == UInt8(ascii: "o") else { continue }
            let prevHorn = renderLetters[k - 1].mark == .horn
            let curHorn = renderLetters[k].mark == .horn
            guard prevHorn != curHorn else { continue }   // exactly one horned
            let oIsLast = (k == count - 1)
            let isQuGlide = (k >= 2 && renderLetters[k - 2].base == UInt8(ascii: "q"))
            if !oIsLast && !isQuGlide {
                renderLetters[k - 1].mark = .horn
                renderLetters[k].mark = .horn
            }
        }

        // Tone placement; map deferred tone/z keys onto the toned vowel (or the
        // last letter when there is no tone, so they group with it for backspace).
        var effTone = pTone
        var toneIdx = pTone == .none ? -1 : toneVowelIndex(count)
        // Stop codas (-c, -ch, -p, -t) only allow sắc (´) and nặng (.). Drop an
        // invalid huyền/hỏi/ngã (e.g. "batf" stays "bat", not "bàt").
        if toneIdx >= 0, effTone == .grave || effTone == .hook || effTone == .tilde,
           hasStopCoda(count) {
            effTone = .none
            toneIdx = -1
        }
        let target = toneIdx >= 0 ? toneIdx : max(0, count - 1)
        for j in 0..<pToneKeyCount { rawLetter[toneKeys[j]] = target }
        lastEffTone = effTone

        for k in 0..<count {
            let u = renderLetters[k]
            var scalar = Tables.markedScalar(base: u.base, mark: u.mark, upper: u.upper)
            if k == toneIdx { scalar = Tables.applyTone(scalar, effTone) }
            scratch[k] = scalar
        }
        return count
    }

    // MARK: - Incremental parse (one fold step per key)

    /// Rebuild the whole parse state by replaying every raw key. Used by backspace
    /// (raw changed non-append) and mid-word parse-setting flips; identical to the
    /// incremental path because the parse is a pure left-to-right fold.
    private mutating func rebuildParseState() {
        pCount = 0
        pTone = .none
        pToneKeyCount = 0
        pCancelled = false
        pWWord = false
        upperToneKey = false
        pFreeMarking = freeMarking
        pSimpleTelex = simpleTelex
        for i in 0..<rawCount { rawLetter[i] = -1 }
        for i in 0..<rawCount { parseStep(i) }
        pProcessed = rawCount
    }

    /// Fold raw key `at` into the parse state (`letters`, `pTone`, provenance…).
    /// This is the single-key body of the historical whole-word parse loop; feeding
    /// keys one at a time through it is equivalent to re-parsing the word.
    private mutating func parseStep(_ at: Int) {
        let key = raw[at]
        let lower = lowercased(key)
        let upper = isUpperAscii(key)

        // A word starting with 'w' is English: Vietnamese has essentially no w-initial
        // syllable, so type it literally with no diacritics ("was"→was, "write"→write).
        // An initial ư is typed "uw", not "w". Applies in both modes.
        if at == 0, lower == UInt8(ascii: "w") { pWWord = true }
        if pWWord {
            appendLetter(base: lower, mark: .none, upper: upper)
            rawLetter[at] = pCount - 1
            return
        }

        // Once a diacritic has been cancelled, the word is English: every further
        // key is literal (no tone/mark), so "messs"→mess (not "més") and the whole
        // token stays as typed. The cancel itself is handled by the branches below,
        // which set `pCancelled`; from the next key on this short-circuits.
        // Cancelled diacritic, OR live spell-check froze the word from here on:
        // emit every remaining key literally (no tone/mark transforms).
        if pCancelled || at >= disabledAtCount {
            appendLetter(base: lower, mark: .none, upper: upper)
            rawLetter[at] = pCount - 1
            return
        }

        // Tone keys: s f r x j
        if let t = toneForKey(lower) {
            if hasVowel(pCount) {
                if pTone == t {
                    pTone = .none // double same tone -> cancel, emit literal
                    pCancelled = true
                    appendLetter(base: lower, mark: .none, upper: upper)
                    rawLetter[at] = pCount - 1
                } else {
                    pTone = t
                    if upper { upperToneKey = true }
                    rawLetter[at] = -1                    // mapped to the toned vowel at render
                    toneKeys[pToneKeyCount] = at; pToneKeyCount += 1
                }
            } else {
                appendLetter(base: lower, mark: .none, upper: upper)
                rawLetter[at] = pCount - 1
            }
            return
        }

        // z: clear tone if there is one; otherwise it's a literal letter. Matching
        // OpenKey (`removeMark(); if !isChanged insertKey`): `z` is NOT an absolute
        // control key — it only vanishes when it actually removes a tone. With no
        // tone to clear it types through ("z"→z, "pizza"→pizza, "xyz"→xyz), instead
        // of being silently swallowed.
        if lower == UInt8(ascii: "z") {
            if pTone != .none {                          // a tone to clear -> consume z
                pCancelled = true
                pTone = .none
                if upper { upperToneKey = true }
                rawLetter[at] = -1
                toneKeys[pToneKeyCount] = at; pToneKeyCount += 1
            } else {                                     // nothing to clear -> literal z
                appendLetter(base: lower, mark: .none, upper: upper)
                rawLetter[at] = pCount - 1
            }
            return
        }

        // w: breve / horn modifier, or standalone ư. The modifier reaches back
        // over any coda to the nearest a/o/u, so "quatw"->quăt, "moiw"->mơi,
        // "nguoiwf"->người even when w is typed after the final consonant.
        if lower == UInt8(ascii: "w") {
            var tIdx = -1
            var k = pCount - 1
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
                    letters[tIdx].mark = .breve; rawLetter[at] = tIdx; return
                }
                if p.mark == .none && (p.base == UInt8(ascii: "o") || p.base == UInt8(ascii: "u")) {
                    letters[tIdx].mark = .horn; rawLetter[at] = tIdx; return
                }
                if p.mark == .breve && p.base == UInt8(ascii: "a") {
                    letters[tIdx].mark = .none
                    pCancelled = true
                    appendLetter(base: UInt8(ascii: "w"), mark: .none, upper: upper)
                    rawLetter[at] = pCount - 1; return
                }
                if p.mark == .horn && (p.base == UInt8(ascii: "o") || p.base == UInt8(ascii: "u")) {
                    letters[tIdx].mark = .none
                    pCancelled = true
                    appendLetter(base: UInt8(ascii: "w"), mark: .none, upper: upper)
                    rawLetter[at] = pCount - 1; return
                }
            }
            // Standalone w -> ư only when the letters so far form an onset that
            // can legally begin a "ư" syllable (cư, thư, giữ, ngư…). After an
            // onset that never precedes ư (k, q, gh, ngh, p) or after another
            // vowel, keep the literal 'w' so English words type through
            // ("kw", "windows", "ew"); auto-restore then leaves them intact.
            // Simple Telex disables this entirely — a lone `w` is always literal
            // (type `uw` for ư).
            if !simpleTelex && standaloneHornUAllowed(pCount) {
                appendLetter(base: UInt8(ascii: "u"), mark: .horn, upper: upper)
            } else {
                appendLetter(base: UInt8(ascii: "w"), mark: .none, upper: upper)
            }
            rawLetter[at] = pCount - 1
            return
        }

        // circumflex doublers: a e o
        if lower == UInt8(ascii: "a") || lower == UInt8(ascii: "e") || lower == UInt8(ascii: "o") {
            if pCount > 0 {
                let pIdx = pCount - 1
                let p = letters[pIdx]
                if p.base == lower && p.mark == .none {
                    letters[pIdx].mark = .circumflex; rawLetter[at] = pIdx; return
                }
                if p.base == lower && p.mark == .circumflex {
                    letters[pIdx].mark = .none
                    pCancelled = true
                    appendLetter(base: lower, mark: .none, upper: upper)
                    rawLetter[at] = pCount - 1; return
                }
            }
            // Free mode ("bỏ dấu tự do"): reach back over a consonant coda to
            // circumflex an earlier bare same-vowel — "ama"→âm, "coto"→côt. Stops
            // at the first vowel from the end, so it never crosses another vowel.
            // Strict mode skips this: "ama"/"coto"/"data" stay literal.
            if freeMarking {
                var k = pCount - 1
                while k >= 0 && !isVowelAscii(letters[k].base) { k -= 1 }
                if k >= 0, letters[k].base == lower, letters[k].mark == .none {
                    letters[k].mark = .circumflex; rawLetter[at] = k; return
                }
            }
            appendLetter(base: lower, mark: .none, upper: upper)
            rawLetter[at] = pCount - 1
            return
        }

        // d doubler -> đ
        if lower == UInt8(ascii: "d") {
            if pCount > 0 {
                let pIdx = pCount - 1
                let p = letters[pIdx]
                if p.base == UInt8(ascii: "d") && p.mark == .none {
                    letters[pIdx].mark = .bar; rawLetter[at] = pIdx; return
                }
                if p.base == UInt8(ascii: "d") && p.mark == .bar {
                    letters[pIdx].mark = .none
                    pCancelled = true
                    appendLetter(base: UInt8(ascii: "d"), mark: .none, upper: upper)
                    rawLetter[at] = pCount - 1; return
                }
            }
            // A trailing d (after a formed syllable) converts the onset d to đ,
            // so "dand"->đan, "duwowngd"->đường even without doubling at the start.
            if pCount > 1, letters[0].base == UInt8(ascii: "d"), letters[0].mark == .none {
                letters[0].mark = .bar; rawLetter[at] = 0; return
            }
            appendLetter(base: UInt8(ascii: "d"), mark: .none, upper: upper)
            rawLetter[at] = pCount - 1
            return
        }

        // ordinary letter
        appendLetter(base: lower, mark: .none, upper: upper)
        rawLetter[at] = pCount - 1
    }

    // MARK: - Tone placement (old style: òa, úy) — reads the render copy

    private mutating func toneVowelIndex(_ count: Int) -> Int {
        var vcount = 0

        var start = 0
        // qu: the u after a leading q is part of the onset.
        if count >= 2, renderLetters[0].base == UInt8(ascii: "q"),
           renderLetters[1].base == UInt8(ascii: "u"), renderLetters[1].mark == .none {
            start = 2
        }
        // gi: the i after a leading g is part of the onset, if a vowel follows.
        else if count >= 3, renderLetters[0].base == UInt8(ascii: "g"),
                renderLetters[1].base == UInt8(ascii: "i"), renderLetters[1].mark == .none,
                isVowelAscii(renderLetters[2].base) {
            start = 2
        }

        for k in start..<count where isVowelAscii(renderLetters[k].base) {
            vowelIdx[vcount] = k
            vcount += 1
        }
        if vcount == 0 {
            for k in 0..<count where isVowelAscii(renderLetters[k].base) { return k }
            return count - 1
        }

        // 1) A marked vowel takes the tone (last one covers ươ -> ơ).
        var lastMarked = -1
        for j in 0..<vcount where renderLetters[vowelIdx[j]].mark != .none { lastMarked = vowelIdx[j] }
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
                let a = renderLetters[vowelIdx[0]].base, b = renderLetters[vowelIdx[1]].base
                let glideInitial =
                    (a == UInt8(ascii: "o") && (b == UInt8(ascii: "a") || b == UInt8(ascii: "e"))) ||
                    (a == UInt8(ascii: "u") && b == UInt8(ascii: "y"))
                if glideInitial { return vowelIdx[1] }
            }
            return vowelIdx[0]                  // open, old style: first vowel (hóa, úy)
        }
        return vowelIdx[1]                      // 3 vowels: middle (oái, ngoáy)
    }

    // MARK: - Diffing (SIMD longest-common-prefix over the scalar buffers)

    /// Length of the common prefix of `a` and `b` within `limit`. Compares 8 scalars
    /// per step with SIMD8<UInt32>; both buffers are fixed capacity-32 allocations,
    /// so reading a full lane past `limit` is always in bounds.
    @inline(__always)
    private func commonPrefixLength(_ a: [UInt32], _ b: [UInt32], upTo limit: Int) -> Int {
        a.withUnsafeBufferPointer { pa in
            b.withUnsafeBufferPointer { pb in
                let ra = UnsafeRawPointer(pa.baseAddress!)
                let rb = UnsafeRawPointer(pb.baseAddress!)
                var i = 0
                while i + 8 <= limit {
                    let va = ra.loadUnaligned(fromByteOffset: i << 2, as: SIMD8<UInt32>.self)
                    let vb = rb.loadUnaligned(fromByteOffset: i << 2, as: SIMD8<UInt32>.self)
                    if any(va .!= vb) {
                        var j = i
                        while pa[j] == pb[j] { j += 1 }
                        return j
                    }
                    i += 8
                }
                while i < limit, pa[i] == pb[i] { i += 1 }
                return i
            }
        }
    }

    private func diff(_ newCount: Int) -> TelexAction {
        let lcp = commonPrefixLength(scratch, out, upTo: min(newCount, outCount))

        let backspaces = outCount - lcp
        if backspaces == 0 && lcp == newCount {
            return .replace(backspaces: 0, insert: "") // consumed no-op
        }
        var s = String.UnicodeScalarView()
        s.reserveCapacity(newCount - lcp)
        for i in lcp..<newCount { s.append(Unicode.Scalar(scratch[i])!) }
        return .replace(backspaces: backspaces, insert: String(s))
    }

    // MARK: - Small helpers

    /// Onsets that can begin a "ư" nucleus, as a flat trie. A standalone `w`
    /// becomes ư only after one of these; after k/q/gh/ngh/p, after "qu", or after
    /// a vowel, `w` stays a literal letter (C3: block spurious "kư" for English
    /// words like "kw").
    private static let onsetsAllowingStandaloneU = ClassTrie([
        "", "b", "c", "ch", "d", "g", "h", "kh", "l", "m", "n", "ng", "nh",
        "ph", "r", "s", "t", "th", "tr", "v", "x", "gi",
    ].map { ($0, UInt8(1)) })

    /// True if the letters typed before a standalone `w` form an onset (built from
    /// base letters, marks ignored — đ reads as "d") that can precede ư.
    private func standaloneHornUAllowed(_ count: Int) -> Bool {
        var node: Int32 = 0
        for k in 0..<count {
            node = Self.onsetsAllowingStandaloneU.step(node, letters[k].base &- UInt8(ascii: "a"))
            if node < 0 { return false }
        }
        return Self.onsetsAllowingStandaloneU.mask(node) != 0
    }

    @inline(__always)
    private func hasVowel(_ count: Int) -> Bool {
        for k in 0..<count where isVowelAscii(letters[k].base) { return true }
        return false
    }

    /// Does the syllable end in a stop coda (-p, -t, -c, -ch)? Such codas only
    /// allow sắc/nặng. Only meaningful when a vowel precedes (checked by caller).
    /// Reads the render copy (post-propagation state).
    @inline(__always)
    private func hasStopCoda(_ count: Int) -> Bool {
        guard count > 0 else { return false }
        let last = renderLetters[count - 1].base
        if last == UInt8(ascii: "p") || last == UInt8(ascii: "t") || last == UInt8(ascii: "c") {
            return true
        }
        // "ch" coda: trailing h preceded by c.
        if last == UInt8(ascii: "h"), count >= 2, renderLetters[count - 2].base == UInt8(ascii: "c") {
            return true
        }
        return false
    }

    @inline(__always)
    private mutating func appendLetter(base: UInt8, mark: Mark, upper: Bool) {
        guard pCount < Self.capacity else { return }
        letters[pCount] = LetterUnit(base: base, mark: mark, upper: upper)
        pCount += 1
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
