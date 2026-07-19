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

    /// English-detection Rule A ("tone must be terminal"). Vietnamese places its
    /// tone key at (or effectively at) the end of the word; an English word whose
    /// Telex reading happens to be a valid syllable (test→tét, list→lít, more→mỏe)
    /// betrays itself by consuming a tone key MID-word and then continuing with
    /// literal letters or new marks. When detected, the word is re-rendered
    /// literally right away and commits as typed. Automatically silent when
    /// `freeMarking` is on (tone keys are then legitimately non-terminal) or when
    /// `toneEarlyStyle` was learned. Preserved across `reset()`.
    public var detectEnglishTone = true

    /// Learned kill-switch for Rule A: the user types tone-early style
    /// ("tieesng", "dduwowjc"). Set by the caller once ≥2 clean commits matched
    /// the mark-before-tone + keys-after-tone pattern (see
    /// `lastCommitToneEarlyPattern`); Rule A then goes permanently silent.
    /// Preserved across `reset()`.
    public var toneEarlyStyle = false

    /// True right after `commitBoundary`/`commitText` when the committed word was
    /// a valid syllable typed in the tone-early pattern (a mark consumed BEFORE
    /// the tone key AND keys consumed after it — "tieesng"). The caller counts
    /// these into persistent storage to learn `toneEarlyStyle`.
    public private(set) var lastCommitToneEarlyPattern = false

    /// Auto-restore whitelist: LOWERCASE words that `SyllableValidator` would reject
    /// but must never be reverted to raw keystrokes at a word boundary ("wifi",
    /// proper names). Checked O(1) at the boundary only, case-folded. Preserved
    /// across `reset()`; the caller sets it from settings (Set assignment is CoW —
    /// a retain, not a copy — so refreshing it per keystroke stays allocation-free).
    public var restoreWhitelist: Set<String> = []

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

    // Repeated-key guard: 4+ identical consecutive letter keys ("jjjj" in vim) mean
    // the user is NOT typing Vietnamese. From the 4th key on the word is emitted
    // literally (via disabledAtCount) and boundary auto-restore is suppressed —
    // the keys are intentional, not a word to "fix". Legit Telex doubles/triples
    // (aa, ee, oo, dd, aaa/sss undo-latch) are at most 3 keys, so they never trip it.
    private var repeatGuarded = false

    // Rule A state: the current word tripped English detection (tone key consumed
    // mid-word) and is rendered literally for the rest of the word. Sticky across
    // backspace WITHIN the word (like repeatGuarded); cleared at the boundary or
    // when the word is fully erased.
    private var englishSuspect = false

    // Rule A exemption: the composed word matched the restore whitelist at the
    // moment detection would have fired — the whitelist beats Rule A, and the
    // check is not repeated for the rest of the word.
    private var ruleAExempt = false

    // Positional flags from the LAST parse (valid while transforms were live):
    // raw index of the first key consumed as a tone / as a diacritic mark, and
    // whether some later key was consumed as a literal letter or a new non-bar
    // mark AFTER the first tone. Zero extra passes — filled inside parse().
    private var flagFirstTone = Int.max
    private var flagFirstMark = Int.max
    private var flagTrigger = false

    // Ctrl-tap temp bypass: the user asked for the CURRENT word to be literal
    // (no transforms, no live spell-check, no boundary auto-restore). Cleared by
    // `reset()`, i.e. at the next word boundary.
    private var wordBypassed = false

    // Resume-after-commit slot: raw keystrokes of the last CLEANLY committed word
    // (committed exactly as composed — no auto-restore, no shortcut expansion), so
    // a Backspace right after the boundary can silently re-open it for editing
    // ("hoa␣" + ⌫ + "f" → "hoà"). Preallocated; survives `reset()`. Cleared by
    // `clearSavedWord()` (caller: mouse click / focus change / app switch) or by a
    // non-clean commit.
    private var savedRaw: [UInt8]
    private var savedRawCount = 0
    // Whether the saved word had tripped Rule A (its clean commit was the LITERAL
    // raw render). Resuming must reproduce that literal render, or the engine's
    // idea of the screen would diverge from what was committed.
    private var savedSuspect = false

    public init() {
        raw = [UInt8](repeating: 0, count: Self.capacity)
        out = [UInt32](repeating: 0, count: Self.capacity)
        scratch = [UInt32](repeating: 0, count: Self.capacity)
        letters = [LetterUnit](repeating: LetterUnit(), count: Self.capacity)
        rawLetter = [Int](repeating: -1, count: Self.capacity)
        toneKeys = [Int](repeating: 0, count: Self.capacity)
        vowelIdx = [Int](repeating: 0, count: Self.capacity)
        savedRaw = [UInt8](repeating: 0, count: Self.capacity)
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

        // Repeated-key guard: 4+ identical trailing keys (case-insensitive) —
        // modal-editor spam like vim's "jjjj". Freeze transforms for the rest of
        // the word and suppress boundary auto-restore. O(run), zero heap.
        if !repeatGuarded, rawCount >= 4 {
            let cur = lowercased(ascii)
            var run = 1
            var k = rawCount - 2
            while k >= 0, lowercased(raw[k]) == cur { run += 1; k -= 1 }
            if run >= 4 { repeatGuarded = true }
        }
        if repeatGuarded, disabledAtCount > rawCount - 1 {
            disabledAtCount = rawCount - 1   // this key (and all later ones) literal
        }

        var cancelled = false
        var newCount = render(cancelled: &cancelled)
        markCancelled = cancelled

        // Live spell-check: once the word can no longer be valid Vietnamese, freeze
        // transforms from the NEXT key on (current output unchanged). See disabledAtCount.
        // A leading loanword consonant z/j/f/w is tolerated (OpenKey's
        // vAllowConsonantZFWJ): validity is judged on the rest of the word, so slang /
        // loanwords like "zô", "fở" keep receiving diacritics instead of freezing at
        // the first key.
        if liveSpellCheck, disabledAtCount == Int.max, !prefixIsValidTolerant(newCount) {
            disabledAtCount = rawCount
        }

        // Rule A (English tone-position detection): a tone key was consumed
        // mid-word — a later key landed as a literal letter or a new mark — and no
        // mark preceded the tone (protects the tone-early style "tieesng"). This
        // word is English (test, list, more, here…): re-render it literally NOW so
        // the user sees "test" live, not "tét"-then-restore at the boundary. The
        // restore whitelist beats Rule A (one String lookup, only at the moment
        // detection fires). Disabled under free marking (tone keys are then
        // legitimately non-terminal), after the tone-early kill-switch, for a
        // Ctrl-tap bypassed word, and after an explicit cancel gesture.
        if detectEnglishTone, !toneEarlyStyle, !freeMarking, !wordBypassed,
           !englishSuspect, !ruleAExempt, !cancelled,
           flagFirstTone != Int.max, flagTrigger, flagFirstMark > flagFirstTone {
            if !restoreWhitelist.isEmpty,
               restoreWhitelist.contains(scratchWord(newCount).lowercased()) {
                ruleAExempt = true
            } else {
                englishSuspect = true
                disabledAtCount = 0
                var c = false
                newCount = render(cancelled: &c)
                markCancelled = c
            }
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
        // on the next forward key (backspace itself never adds a transform). A
        // Ctrl-tap bypass — or a word Rule A already flagged as English — keeps
        // the whole word literal until the boundary (sticky, like repeatGuarded).
        disabledAtCount = (wordBypassed || englishSuspect) ? 0 : Int.max

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
        if rawCount == 0 {                       // word fully erased: Rule A re-arms
            englishSuspect = false
            ruleAExempt = false
            disabledAtCount = wordBypassed ? 0 : Int.max
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
    /// A CLEAN commit (word left exactly as composed) is saved for backspace-resume.
    public mutating func commitBoundary(autoRestore: Bool) -> TelexAction {
        defer { reset() }
        noteToneEarlyPattern()
        guard rawCount > 0 else { return .none }
        if let restored = restoreTarget(autoRestore: autoRestore) {
            savedRawCount = 0            // screen ≠ composed render: not resumable
            return .replace(backspaces: outCount, insert: restored)
        }
        saveForResume()
        return .none
    }

    /// Final text to commit at a word boundary, with auto-restore applied
    /// (non-Vietnamese syllables fall back to the raw keystrokes). Resets the engine.
    /// Used by the marked-text controller path.
    /// A CLEAN commit (word left exactly as composed) is saved for backspace-resume.
    public mutating func commitText(autoRestore: Bool) -> String {
        defer { reset() }
        noteToneEarlyPattern()
        guard rawCount > 0 else { return "" }
        if let restored = restoreTarget(autoRestore: autoRestore) {
            savedRawCount = 0
            return restored
        }
        saveForResume()
        return composed
    }

    /// The raw keystrokes to restore to at a boundary, or nil when the composed word
    /// stands (valid syllable, deliberate cancel gesture, Ctrl-tap bypass,
    /// repeated-key spam, whitelisted word, or restore would be a no-op).
    private func restoreTarget(autoRestore: Bool) -> String? {
        guard autoRestore, !markCancelled, !wordBypassed, !repeatGuarded else { return nil }
        let word = composed
        guard !word.isEmpty, !SyllableValidator.isValidSyllable(word) else { return nil }
        // Whitelist ("wifi", proper names): never restore these. O(1), case-folded;
        // the lowercased() allocation only happens at a boundary with a non-empty list.
        if !restoreWhitelist.isEmpty, restoreWhitelist.contains(word.lowercased()) {
            return nil
        }
        let restored = rawKeystrokes
        return restored == word ? nil : restored
    }

    public mutating func reset() {
        rawCount = 0
        outCount = 0
        markCancelled = false
        disabledAtCount = Int.max
        repeatGuarded = false
        wordBypassed = false        // Ctrl-tap bypass lasts until the word boundary
        englishSuspect = false
        ruleAExempt = false
        flagFirstTone = Int.max
        flagFirstMark = Int.max
        flagTrigger = false
        // lastCommitToneEarlyPattern intentionally survives reset(): commits set it
        // and the caller reads it right after.
    }

    /// Tone-early pattern detector for the kill-switch: the word being committed
    /// consumed a mark BEFORE its (first) tone key AND consumed keys after the
    /// tone ("tieesng", "dduwowjc"), and it is a valid Vietnamese syllable — the
    /// signature of a tone-early typist that Rule A must learn to leave alone.
    private mutating func noteToneEarlyPattern() {
        lastCommitToneEarlyPattern = false
        guard rawCount > 0,
              flagFirstTone != Int.max, flagTrigger, flagFirstMark < flagFirstTone,
              !markCancelled, !wordBypassed, !repeatGuarded, !englishSuspect
        else { return }
        if SyllableValidator.isValidSyllable(composed) {
            lastCommitToneEarlyPattern = true
        }
    }

    // MARK: - Backspace-resume of the last committed word

    /// A cleanly committed word is available to re-open.
    public var hasSavedWord: Bool { savedRawCount > 0 }

    /// Forget the resume slot. Callers invoke this when the caret can no longer be
    /// right after "word + boundary char": mouse click, focus change, app switch,
    /// or a shortcut expansion replaced the word.
    public mutating func clearSavedWord() { savedRawCount = 0 }

    /// Re-open the last cleanly committed word: the raw keystrokes are reloaded and
    /// re-rendered so typing continues exactly where the word left off ("hoa␣" +
    /// Backspace + "f" → "hoà"). The caller must have already removed the boundary
    /// character from screen (it lets the physical Backspace delete the space).
    /// Returns false when there is nothing to resume.
    @discardableResult
    public mutating func resumeLastWord() -> Bool {
        guard savedRawCount > 0 else { return false }
        for i in 0..<savedRawCount { raw[i] = savedRaw[i] }
        rawCount = savedRawCount
        savedRawCount = 0
        repeatGuarded = false
        wordBypassed = false
        // A word that had tripped Rule A resumes in its literal state (so the
        // re-render below matches the committed text); erasing it fully re-arms
        // detection, and other words re-evaluate normally.
        englishSuspect = savedSuspect
        ruleAExempt = false
        disabledAtCount = savedSuspect ? 0 : Int.max // spell-check re-evaluates next key
        var cancelled = false
        let n = render(cancelled: &cancelled)
        markCancelled = cancelled
        copyOut(n)
        return true
    }

    /// Copy the current word into the preallocated resume slot (clean commits only).
    private mutating func saveForResume() {
        for i in 0..<rawCount { savedRaw[i] = raw[i] }
        savedRawCount = rawCount
        savedSuspect = englishSuspect
    }

    // MARK: - Ctrl-tap temp bypass

    /// The user tapped Ctrl alone: make the CURRENT word literal — re-render it as
    /// the raw keystrokes (undoing any on-screen transforms), stop all further
    /// transforms and live spell-check for this word, and suppress boundary
    /// auto-restore. State clears at the next word boundary (`reset()`). Returns the
    /// screen edit needed (`.none` when nothing is composing).
    public mutating func bypassCurrentWord() -> TelexAction {
        wordBypassed = true
        disabledAtCount = 0
        guard rawCount > 0 else { return .none }
        var cancelled = false
        let n = render(cancelled: &cancelled)
        markCancelled = cancelled
        let action = diff(scratch, n)
        copyOut(n)
        return action
    }

    /// True if the first `n` scalars of `scratch` form a valid Vietnamese syllable
    /// prefix, tolerating ONE leading loanword consonant z/j/f/w (validity is then
    /// judged on the remainder): "zô", "jú", "fở" keep composing instead of tripping
    /// live spell-check on the very first key. No legitimate Vietnamese syllable
    /// starts with these letters, so the tolerance can't mask a real word.
    private func prefixIsValidTolerant(_ n: Int) -> Bool {
        var start = 0
        if n > 0, isLoanConsonant(scratch[0]) { start = 1 }
        var s = String.UnicodeScalarView()
        s.reserveCapacity(n - start)
        for i in start..<n { s.append(Unicode.Scalar(scratch[i])!) }
        return SyllableValidator.isValidPrefix(String(s))
    }

    /// z / j / f / w (either case) — consonants Vietnamese lacks but loanwords use.
    @inline(__always)
    private func isLoanConsonant(_ v: UInt32) -> Bool {
        let lower = (v >= 65 && v <= 90) ? v + 32 : v
        switch lower {
        case UInt32(UInt8(ascii: "z")), UInt32(UInt8(ascii: "j")),
             UInt32(UInt8(ascii: "f")), UInt32(UInt8(ascii: "w")):
            return true
        default:
            return false
        }
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

        // Rule A positional flags, recomputed by every parse (see detectEnglishTone).
        flagFirstTone = Int.max
        flagFirstMark = Int.max
        flagTrigger = false

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
                        if flagFirstTone == Int.max { flagFirstTone = at }
                        toneKeys[toneKeyCount] = at; toneKeyCount += 1
                    }
                } else {
                    appendLetter(&letterCount, base: lower, mark: .none, upper: upper)
                    rawLetter[at] = letterCount - 1
                }
                continue
            }

            // z: clear tone. Only meaningful once a vowel exists; before that it is a
            // literal letter, so z-initial loanwords type through ("zalo", "zô") —
            // mirrors the tone keys s/f/r/x/j just above.
            if lower == UInt8(ascii: "z") {
                if hasVowel(letterCount) {
                    if tone != .none { cancelled = true }
                    tone = .none
                    toneKeys[toneKeyCount] = at; toneKeyCount += 1
                } else {
                    appendLetter(&letterCount, base: lower, mark: .none, upper: upper)
                    rawLetter[at] = letterCount - 1
                }
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
                        letters[tIdx].mark = .breve; rawLetter[at] = tIdx
                        noteMark(at, trigger: true); continue
                    }
                    if p.mark == .none && (p.base == UInt8(ascii: "o") || p.base == UInt8(ascii: "u")) {
                        letters[tIdx].mark = .horn; rawLetter[at] = tIdx
                        noteMark(at, trigger: true); continue
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
                noteLiteral(at)
                continue
            }

            // circumflex doublers: a e o
            if lower == UInt8(ascii: "a") || lower == UInt8(ascii: "e") || lower == UInt8(ascii: "o") {
                if letterCount > 0 {
                    let pIdx = letterCount - 1
                    let p = letters[pIdx]
                    if p.base == lower && p.mark == .none {
                        letters[pIdx].mark = .circumflex; rawLetter[at] = pIdx
                        noteMark(at, trigger: true); continue
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
                        letters[k].mark = .circumflex; rawLetter[at] = k
                        noteMark(at, trigger: true); continue
                    }
                }
                appendLetter(&letterCount, base: lower, mark: .none, upper: upper)
                rawLetter[at] = letterCount - 1
                noteLiteral(at)
                continue
            }

            // d doubler -> đ
            if lower == UInt8(ascii: "d") {
                if letterCount > 0 {
                    let pIdx = letterCount - 1
                    let p = letters[pIdx]
                    if p.base == UInt8(ascii: "d") && p.mark == .none {
                        // Rule A: the trailing d of dd→đ never counts as a trigger.
                        letters[pIdx].mark = .bar; rawLetter[at] = pIdx
                        noteMark(at, trigger: false); continue
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
                    letters[0].mark = .bar; rawLetter[at] = 0
                    noteMark(at, trigger: false); continue   // trailing-d exclusion
                }
                appendLetter(&letterCount, base: UInt8(ascii: "d"), mark: .none, upper: upper)
                rawLetter[at] = letterCount - 1
                noteLiteral(at)
                continue
            }

            // ordinary letter
            appendLetter(&letterCount, base: lower, mark: .none, upper: upper)
            rawLetter[at] = letterCount - 1
            noteLiteral(at)
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

    // MARK: - Rule A flag bookkeeping (inside parse, zero extra passes)

    /// A key was consumed as a diacritic mark. Marks after the first tone key are
    /// Rule A triggers ("here" → h e r(tone) e(new ê mark)) — except the trailing
    /// d of dd→đ, which is a normal Vietnamese afterthought ("dansd").
    @inline(__always)
    private mutating func noteMark(_ at: Int, trigger: Bool) {
        if at < flagFirstMark { flagFirstMark = at }
        if trigger, flagFirstTone < at { flagTrigger = true }
    }

    /// A key was consumed as a literal letter while transforms were live. Literal
    /// letters after the first tone key are Rule A triggers ("test", "list").
    @inline(__always)
    private mutating func noteLiteral(_ at: Int) {
        if flagFirstTone < at { flagTrigger = true }
    }

    /// String view of the first `n` scalars of the render scratch buffer.
    /// Allocates — used only at the single moment Rule A fires (whitelist check).
    private func scratchWord(_ n: Int) -> String {
        var s = String.UnicodeScalarView()
        s.reserveCapacity(n)
        for i in 0..<n { s.append(Unicode.Scalar(scratch[i])!) }
        return String(s)
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
