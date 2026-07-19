// SyllableValidator.swift
// Rule-based Vietnamese syllable validator. No dictionary file: a syllable is valid
// iff  onset ∈ ONSETS  AND  rime ∈ RIMES  AND  the tone/coda constraint holds.
// Used at word boundaries to decide whether to auto-restore raw keystrokes, and
// per-keystroke (prefix form) by live spell-check.
//
// The rule tables below are the SOURCE; at startup they compile into flat trie
// machines over the 33-letter class alphabet (Tables.letterClass). Even the
// tone/coda rule is data, not code: each rime's accepting node carries a 6-bit
// mask of the tones it allows (stop codas -c/-ch/-p/-t → sắc/nặng only). The hot
// paths walk byte arrays through these tries — no String, no hashing, no heap.

public enum SyllableValidator {

    // MARK: - Rule tables (human-readable source of truth)

    // Valid onsets (initial consonant clusters). "" = zero onset.
    // `z` and the `dz` cluster are not native Vietnamese onsets, but they're
    // included so casual/colloquial words type with diacritics like any consonant
    // ("zoo"→zô, "dzij"→dzị, "dzoo"→dzô — the "dz" spelling iOS Vietnamese accepts).
    // Cost: z-initial English words with a Telex tone letter (zero→zẻo, zoom→zôm)
    // transform instead of restore — the usual Telex trade-off, same as any onset;
    // switch input source for those.
    static let onsets: Set<String> = [
        "", "b", "c", "ch", "d", "đ", "g", "gh", "gi", "h", "k", "kh", "l",
        "m", "n", "ng", "ngh", "nh", "p", "ph", "qu", "r", "s", "t", "th",
        "tr", "v", "x", "z", "dz"
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

    // MARK: - Compiled machines (rules → data, built once)

    /// Allowed-tone bitmask for a rime: bit = Tone.rawValue. Stop codas
    /// (-p/-t/-c/-ch) only permit sắc/nặng; everything else permits all six.
    private static func toneMask(forRime r: String) -> UInt8 {
        let stop = r.hasSuffix("p") || r.hasSuffix("t") || r.hasSuffix("c") || r.hasSuffix("ch")
        return stop ? (1 << Tone.acute.rawValue) | (1 << Tone.dot.rawValue) : 0b0011_1111
    }

    /// Exact matchers (marked letters, đ distinct from d): full-syllable validation.
    static let onsetExact = ClassTrie(onsets.map { ($0, UInt8(1)) })
    static let rimeExact = ClassTrie(rimes.map { ($0, toneMask(forRime: $0)) })

    /// Folded matchers (â/ă→a, ô/ơ→o, ư→u, ê→e, đ→d): prefix plausibility while
    /// typing, where the diacritic may simply not have been typed yet.
    static let onsetFolded = ClassTrie(onsets.map { (String($0.map(foldBase)), UInt8(1)) })
    static let rimeFolded = ClassTrie(rimes.map { (String($0.map(foldBase)), UInt8(1)) })

    /// Fold a marked vowel to its bare base letter (ô/ơ→o, ư→u, ê→e, ă/â→a, đ→d),
    /// so a Telex intermediate that has not yet received its diacritic ("uo", "ie",
    /// "uoi") matches the bare prefix of a real rime ("ươ", "iê", "ươi"). Vowel SHAPE
    /// is ignored for prefix matching; the base skeleton is what must stay plausible.
    static func foldBase(_ c: Character) -> Character {
        switch c {
        case "ă", "â": return "a"
        case "ê":      return "e"
        case "ô", "ơ": return "o"
        case "ư":      return "u"
        case "đ":      return "d"
        default:       return c
        }
    }

    // MARK: - Full-syllable validation

    /// Zero-allocation core: `classes[0..<n]` are letter classes
    /// (`Tables.letterClass`) of the composed word, `tone` its single tone.
    /// Splits onset deterministically (qu-/gi- glides), then: onset exact-accepted
    /// AND rime exact-accepted AND the rime's tone mask allows `tone`.
    public static func isValidSyllable(classes: [UInt8], count n: Int, tone: Tone) -> Bool {
        if n == 0 { return false }
        let q = UInt8(ascii: "q") - UInt8(ascii: "a")
        let u = UInt8(ascii: "u") - UInt8(ascii: "a")
        let g = UInt8(ascii: "g") - UInt8(ascii: "a")
        let i = UInt8(ascii: "i") - UInt8(ascii: "a")

        var pos = 0
        while pos < n && !Tables.isVowelClass(classes[pos]) { pos += 1 }
        var onsetEnd = pos
        // qu / gi glide handling ("qu" + vowel: the unmarked u joins the onset).
        if pos >= 1, classes[0] == q, pos < n, classes[pos] == u,
           pos + 1 < n, Tables.isVowelClass(classes[pos + 1]) {
            onsetEnd = pos + 1
        } else if n >= 3, classes[0] == g, classes[1] == i, Tables.isVowelClass(classes[2]) {
            onsetEnd = 2
        }

        var node: Int32 = 0
        for k in 0..<onsetEnd {
            node = onsetExact.step(node, classes[k])
            if node < 0 { return false }
        }
        guard onsetExact.mask(node) != 0 else { return false }

        var rnode: Int32 = 0
        for k in onsetEnd..<n {
            rnode = rimeExact.step(rnode, classes[k])
            if rnode < 0 { return false }
        }
        let m = rimeExact.mask(rnode)
        return (m >> tone.rawValue) & 1 == 1
    }

    /// Returns true if `word` is a well-formed Vietnamese syllable. String façade
    /// over the class-based core (word-boundary use; not the per-key hot path).
    public static func isValidSyllable(_ word: String) -> Bool {
        if word.isEmpty { return false }
        var classes = [UInt8]()
        classes.reserveCapacity(word.count)
        var tone: Tone = .none
        for ch in word.lowercased() {
            guard let scalar = ch.unicodeScalars.first, ch.unicodeScalars.count == 1 else {
                return false
            }
            var toneless = ch
            if let (base, t) = Tables.detoneTable[scalar.value] {
                toneless = Character(Unicode.Scalar(base)!)
                if t != .none {
                    if tone != .none { return false } // two tones
                    tone = t
                }
            }
            guard let cls = Tables.charClass[toneless] else { return false }
            classes.append(cls)
        }
        return isValidSyllable(classes: classes, count: classes.count, tone: tone)
    }

    // MARK: - Prefix validity (live spell-check while typing)

    /// Zero-allocation core for the engine's per-keystroke path. `bases[i]` is the
    /// lowercase ascii BASE letter of display letter i (ơ→o, ă→a, đ→d…), with bit 7
    /// set when that letter carries a mark. Matching runs over the folded tries —
    /// the mark bit matters only for the qu-glide alternative (a horned ư never
    /// joins a "qu" onset).
    ///
    /// PERMISSIVE by design: it must never reject a valid word mid-typing (that
    /// would wrongly stop composing), so it errs toward true — callers use it only
    /// to DISABLE transforms on words that clearly cannot be Vietnamese.
    public static func isValidPrefix(bases: [UInt8], count n: Int) -> Bool {
        if n == 0 { return true }
        @inline(__always) func cls(_ i: Int) -> UInt8 { (bases[i] & 0x7F) &- UInt8(ascii: "a") }

        var pos = 0
        while pos < n && !isVowelAscii(bases[pos] & 0x7F) { pos += 1 }
        if pos == n {                                   // no vowel yet: partial onset
            var node: Int32 = 0
            for i in 0..<n {
                node = onsetFolded.step(node, cls(i))
                if node < 0 { return false }
            }
            return true                                 // any live trie node = valid prefix
        }

        // Nucleus-start candidates. Default = right after the leading consonants; the
        // qu-/gi- glides give an alternative where the glide vowel joins the onset.
        // Every interpretation is tried and ANY plausible one accepts (permissive).
        let quAlt = (bases[0] & 0x7F == UInt8(ascii: "q")
                     && bases[pos] == UInt8(ascii: "u")) ? pos + 1 : -1   // unmarked u only
        let giAlt = (bases[0] & 0x7F == UInt8(ascii: "g")
                     && n >= 2 && bases[1] == UInt8(ascii: "i")) ? 2 : -1

        for start in [pos, quAlt, giAlt] {
            guard start >= 0, start <= n else { continue }
            var node: Int32 = 0
            var ok = true
            for i in 0..<start {
                node = onsetFolded.step(node, cls(i))
                if node < 0 { ok = false; break }
            }
            guard ok, onsetFolded.mask(node) != 0 else { continue }
            var rnode: Int32 = 0
            ok = true
            for i in start..<n {
                rnode = rimeFolded.step(rnode, cls(i))
                if rnode < 0 { ok = false; break }
            }
            if ok { return true }                        // any live trie node = valid prefix
        }
        return false
    }

    /// String façade over the byte-level prefix check (tests / non-hot callers).
    public static func isValidPrefix(_ word: String) -> Bool {
        if word.isEmpty { return true }
        var bases = [UInt8]()
        bases.reserveCapacity(word.count)
        for ch in word.lowercased() {
            guard let scalar = ch.unicodeScalars.first, ch.unicodeScalars.count == 1 else { return false }
            var toneless = ch
            if let (base, _) = Tables.detoneTable[scalar.value] {
                toneless = Character(Unicode.Scalar(base)!)
            }
            guard Tables.charClass[toneless] != nil else { return false }
            let folded = foldBase(toneless)
            guard let a = folded.asciiValue else { return false }
            bases.append(a | (folded == toneless ? 0 : 0x80))
        }
        return isValidPrefix(bases: bases, count: bases.count)
    }
}

// MARK: - Flat class trie (the compiled rule machine)

/// Flat trie over the 33-letter class alphabet (`Tables.letterClass`). Node i's
/// child for class c lives at next[i * 33 + Int(c)]; -1 = absent. Root = node 0.
/// Reaching a node ⇔ the walked string is a prefix of an inserted word. Each node
/// carries a byte `mask`: 0 = not a full word; nonzero = accepting, and for rime
/// tries the bits are the ALLOWED TONES (bit = Tone.rawValue) — the tone/coda rule
/// compiled into the data. Built once at startup, read-only after.
struct ClassTrie: Sendable {
    private let next: [Int32]
    private let masks: [UInt8]

    /// Build from (word, acceptMask) pairs; characters map through
    /// `Tables.charClass`. Words with unmappable characters are skipped.
    init(_ words: some Sequence<(String, UInt8)>) {
        let stride = Tables.classCount
        var next = [Int32](repeating: -1, count: stride)
        var masks: [UInt8] = [0]
        outer: for (w, accept) in words {
            var path = [Int]()
            for ch in w {
                guard let c = Tables.charClass[ch] else { continue outer }
                path.append(Int(c))
            }
            var node = 0
            for c in path {
                let slot = node * stride + c
                if next[slot] < 0 {
                    next[slot] = Int32(masks.count)
                    next.append(contentsOf: repeatElement(-1, count: stride))
                    masks.append(0)
                }
                node = Int(next[slot])
            }
            masks[node] |= max(accept, 1)
        }
        self.next = next
        self.masks = masks
    }

    /// One transition on a letter class. Returns -1 when absent.
    @inline(__always)
    func step(_ node: Int32, _ cls: UInt8) -> Int32 {
        next[Int(node) * Tables.classCount + Int(cls)]
    }

    /// Accept mask of a node (0 = not a full inserted word).
    @inline(__always)
    func mask(_ node: Int32) -> UInt8 { masks[Int(node)] }
}