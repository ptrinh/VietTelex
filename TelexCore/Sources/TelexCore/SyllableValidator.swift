// SyllableValidator.swift
// Rule-based Vietnamese syllable validator. No dictionary file: a syllable is valid
// iff  onset ∈ ONSETS  AND  rime ∈ RIMES  AND  the tone/coda constraint holds.
// Used at word boundaries to decide whether to auto-restore raw keystrokes.

public enum SyllableValidator {

    // Vowel letters (toneless, including marked forms).
    private static let vowels: Set<Character> = [
        "a", "ă", "â", "e", "ê", "i", "o", "ô", "ơ", "u", "ư", "y"
    ]

    // Valid onsets (initial consonant clusters). "" = zero onset.
    static let onsets: Set<String> = [
        "", "b", "c", "ch", "d", "đ", "g", "gh", "gi", "h", "k", "kh", "l",
        "m", "n", "ng", "ngh", "nh", "p", "ph", "qu", "r", "s", "t", "th",
        "tr", "v", "x"
    ]

    // Valid rimes = nucleus (+ coda), toneless, with marks. ~180 entries.
    static let rimes: Set<String> = {
        let list = """
        a ac ach ai am an ang anh ao ap at au ay
        ă ăc ăm ăn ăng ăp ăt
        â âc âm ân âng âp ât âu ây
        e ec em en eng eo ep et
        ê êch êm ên êng ênh êp êt êu
        i ich im in inh ip it iu ia
        iê iêc iêm iên iêng iêp iêt iêu
        o oc oi om on ong op ot
        oa oac oach oai oam oan oang oanh oao oap oat oay
        oă oăc oăm oăn oăng oăt
        oe oem oen oeo oet
        oo oong ooc
        ô ôc ôi ôm ôn ông ôp ôt
        ơ ơi ơm ơn ơp ơt
        u uc ui um un ung up ut ua
        uâ uân uâng uât uây
        uê uêch uên uênh
        uô uôc uôi uôm uôn uông uôt uơ
        uy uya uych uyn uynh uyt uyu uyên uyêt
        ư ưa ưc ưi ưng ưt ưu
        ươ ươi ươm ươn ương ươp ươt ươu ươc
        y yê yêm yên yêng yêt yêu
        """
        var set = Set<String>()
        for token in list.split(whereSeparator: { $0 == " " || $0 == "\n" }) {
            set.insert(String(token))
        }
        return set
    }()

    // Codas that force a stop (only sắc / nặng allowed).
    private static let stopCodas: Set<String> = ["p", "t", "c", "ch"]

    // Valid codas (used only to split rime into nucleus + coda for the tone rule).
    private static let codas: Set<String> = [
        "", "c", "ch", "m", "n", "ng", "nh", "p", "t"
    ]

    /// Returns true if `word` is a well-formed Vietnamese syllable.
    public static func isValidSyllable(_ word: String) -> Bool {
        if word.isEmpty { return false }

        // Decompose: toneless letters + tone.
        var letters: [Character] = []
        letters.reserveCapacity(word.count)
        var tone: Tone = .none

        for ch in word.lowercased() {
            guard let scalar = ch.unicodeScalars.first, ch.unicodeScalars.count == 1 else {
                return false
            }
            if let (base, t) = Tables.detoneTable[scalar.value] {
                letters.append(Character(Unicode.Scalar(base)!))
                if t != .none {
                    if tone != .none { return false } // two tones
                    tone = t
                }
            } else {
                // Only ascii letters and đ are acceptable outside the tone table.
                if isLetterChar(ch) || ch == "đ" {
                    letters.append(ch)
                } else {
                    return false
                }
            }
        }

        let n = letters.count

        // --- Split onset ---
        var pos = 0
        while pos < n && !vowels.contains(letters[pos]) { pos += 1 }
        var onsetEnd = pos

        // qu / gi glide handling.
        if pos >= 1, letters[0] == "q", pos < n, letters[pos] == "u",
           pos + 1 < n, vowels.contains(letters[pos + 1]) {
            // "qu" + vowel: u belongs to onset.
            onsetEnd = pos + 1
        } else if n >= 3, letters[0] == "g", letters[1] == "i", vowels.contains(letters[2]) {
            // "gi" + vowel: i belongs to onset.
            onsetEnd = 2
        }

        let onset = String(letters[0..<onsetEnd])
        guard onsets.contains(onset) else { return false }

        // --- Nucleus + coda ---
        var vEnd = onsetEnd
        while vEnd < n && vowels.contains(letters[vEnd]) { vEnd += 1 }
        let nucleus = String(letters[onsetEnd..<vEnd])
        let coda = String(letters[vEnd..<n])

        if nucleus.isEmpty { return false }
        guard codas.contains(coda) else { return false }

        let rime = nucleus + coda
        guard rimes.contains(rime) else { return false }

        // --- Tone / coda constraint ---
        if stopCodas.contains(coda) {
            if tone != .acute && tone != .dot { return false }
        }

        return true
    }

    // MARK: - Prefix validity (live spell-check while typing)

    /// Fold a marked vowel to its bare base letter (ô/ơ→o, ư→u, ê→e, ă/â→a, đ→d),
    /// so a Telex intermediate that has not yet received its diacritic ("uo", "ie",
    /// "uoi") matches the bare prefix of a real rime ("ươ", "iê", "ươi"). Vowel SHAPE
    /// is ignored for prefix matching; the base skeleton is what must stay plausible.
    private static func foldBase(_ c: Character) -> Character {
        switch c {
        case "ă", "â": return "a"
        case "ê":      return "e"
        case "ô", "ơ": return "o"
        case "ư":      return "u"
        case "đ":      return "d"
        default:       return c
        }
    }

    /// All prefixes (including "") of every valid onset — for a word still inside its
    /// initial consonant cluster ("ng" on the way to "ngh").
    private static let onsetPrefixes: Set<String> = {
        var set: Set<String> = []
        for o in onsets { var p = ""; set.insert(p); for ch in o { p.append(ch); set.insert(p) } }
        return set
    }()

    /// All prefixes of every base-folded rime — a mid-typing nucleus+coda is plausible
    /// iff it is one of these.
    private static let rimeBasePrefixes: Set<String> = {
        var set: Set<String> = []
        for r in rimes {
            var p = ""; set.insert(p)
            for ch in r { p.append(foldBase(ch)); set.insert(p) }
        }
        return set
    }()

    /// True if `word` (a composition in progress) could still grow into a valid
    /// Vietnamese syllable. PERMISSIVE by design: it must never reject a valid word
    /// mid-typing (that would wrongly stop composing), so it errs toward true —
    /// callers use it only to DISABLE transforms on words that clearly cannot be
    /// Vietnamese (foreign words, URLs). Vowel diacritics are folded away (see
    /// `foldBase`) so un-accented Telex intermediates still pass.
    public static func isValidPrefix(_ word: String) -> Bool {
        if word.isEmpty { return true }

        // Decompose to toneless letters (keep marks); reject non-letters outright.
        var letters: [Character] = []
        letters.reserveCapacity(word.count)
        for ch in word.lowercased() {
            guard let scalar = ch.unicodeScalars.first, ch.unicodeScalars.count == 1 else { return false }
            if let (base, _) = Tables.detoneTable[scalar.value] {
                letters.append(Character(Unicode.Scalar(base)!))
            } else if isLetterChar(ch) || ch == "đ" {
                letters.append(ch)
            } else {
                return false
            }
        }
        let n = letters.count

        // Leading consonants.
        var pos = 0
        while pos < n && !vowels.contains(letters[pos]) { pos += 1 }
        if pos == n {                                   // no vowel yet: partial onset
            return onsetPrefixes.contains(String(letters))
        }

        // Nucleus-start candidates. Default = right after the leading consonants; the
        // qu-/gi- glides give an alternative where the glide vowel joins the onset.
        // Every interpretation is tried and ANY plausible one accepts (permissive).
        var starts: [Int] = [pos]
        if letters[0] == "q", letters[pos] == "u" { starts.append(pos + 1) }      // qu
        if letters[0] == "g", n >= 2, letters[1] == "i" { starts.append(2) }      // gi

        for start in starts where start <= n {
            let onset = String(letters[0..<start])
            guard onsets.contains(onset) else { continue }
            let rest = String(letters[start...].map(foldBase))
            if rimeBasePrefixes.contains(rest) { return true }
        }
        return false
    }
}

@inline(__always)
private func isLetterChar(_ c: Character) -> Bool {
    guard let a = c.asciiValue else { return false }
    return isLetter(a)
}
