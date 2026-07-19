// SyllableValidator.swift
// Compositional, zero-alloc Vietnamese syllable validator (no dictionary).
// A syllable is valid iff  Onset · (Glide) · Nucleus · (Coda) · Tone  is well-formed:
//   - onset ∈ 28 onsets (incl. "" / qu / gi), each with a spelling gate checked
//     against the first nucleus letter (k/gh/ngh only before e ê i y; c/g/ng never),
//   - nucleus ∈ 30 written vowel sequences,
//   - coda ∈ {∅ p t c ch m n ng nh i y o u}, allowed per-nucleus via a bitmask,
//   - stop codas (p t c ch) require sắc or nặng.
// All tables are packed integers (~280 bytes of static data); validation is a
// single left-to-right pass over the scalars with no heap allocation.
// Used at word boundaries for auto-restore (`isValidSyllable`) and per keystroke
// for live spell-check (`isValidPrefix`).

public enum SyllableValidator {

    /// Longest raw Telex keystroke sequence that still forms a valid syllable
    /// ("nghieengs" → nghiếng-family, 9 keys). Engines may early-out beyond this.
    public static let maxRawSyllableLength = 9

    // MARK: - Letter codes
    // Vowel letters get 4-bit codes (1...12) so a nucleus (≤3 letters) packs into
    // a UInt16; consonants keep folded ascii; đ gets a private pseudo-ascii code.

    private static let dBar: UInt8 = 0x7B  // "đ" pseudo-consonant ('{', not an ascii letter)

    @inline(__always)
    private static func vowelCode(_ base: UInt32) -> UInt8? {
        switch base {
        case 0x61, 0x41:   return 1   // a A
        case 0x103, 0x102: return 2   // ă Ă
        case 0xE2, 0xC2:   return 3   // â Â
        case 0x65, 0x45:   return 4   // e E
        case 0xEA, 0xCA:   return 5   // ê Ê
        case 0x69, 0x49:   return 6   // i I
        case 0x6F, 0x4F:   return 7   // o O
        case 0xF4, 0xD4:   return 8   // ô Ô
        case 0x1A1, 0x1A0: return 9   // ơ Ơ
        case 0x75, 0x55:   return 10  // u U
        case 0x1B0, 0x1AF: return 11  // ư Ư
        case 0x79, 0x59:   return 12  // y Y
        default:           return nil
        }
    }

    /// Front letters for the onset spelling gates: e ê i y.
    @inline(__always)
    private static func isFront(_ v: UInt8) -> Bool { v == 4 || v == 5 || v == 6 || v == 12 }

    /// Fold a vowel code to its bare base letter (ă/â→a, ê→e, ô/ơ→o, ư→u) so an
    /// un-accented Telex intermediate ("uo" on the way to "ươ") matches for
    /// prefix checking. Vowel SHAPE is ignored mid-typing; the skeleton must stay
    /// plausible.
    @inline(__always)
    private static func fold(_ v: UInt8) -> UInt8 {
        switch v {
        case 2, 3:  return 1   // ă â → a
        case 5:     return 4   // ê → e
        case 8, 9:  return 7   // ô ơ → o
        case 11:    return 10  // ư → u
        default:    return v
        }
    }

    // MARK: - Onset table
    // 28 onsets: "" (zero), qu and gi are resolved structurally in the parser;
    // the remaining 25 consonant runs live here, packed ≤3 ascii bytes per key.

    private enum Gate: UInt8 {
        case any        // no restriction
        case frontOnly  // only before e ê i y   (k, gh, ngh)
        case nonFront   // never before e ê i y  (c, ng)
        case gLike      // g: not before e ê y — but "g"+i is the gi onset written
                        // degenerately (gì, gìn), so i passes
    }

    private struct Onset { let key: UInt32; let len: UInt8; let gate: Gate }

    private static let onsetTable: [Onset] = {
        func o(_ s: String, _ g: Gate) -> Onset {
            var k: UInt32 = 0
            for b in s.utf8 { k = k << 8 | UInt32(b) }
            return Onset(key: k, len: UInt8(s.utf8.count), gate: g)
        }
        return [
            o("b", .any), o("c", .nonFront), o("ch", .any), o("d", .any),
            Onset(key: UInt32(dBar), len: 1, gate: .any),  // đ
            o("g", .gLike), o("gh", .frontOnly), o("h", .any), o("k", .frontOnly),
            o("kh", .any), o("l", .any), o("m", .any), o("n", .any),
            o("ng", .nonFront), o("ngh", .frontOnly), o("nh", .any), o("p", .any),
            o("ph", .any), o("r", .any), o("s", .any), o("t", .any),
            o("th", .any), o("tr", .any), o("v", .any), o("x", .any),
        ]
    }()

    // MARK: - Coda bits (13 codas) + per-nucleus flag

    private static let cE:  UInt16 = 1 << 0   // ∅
    private static let cP:  UInt16 = 1 << 1
    private static let cT:  UInt16 = 1 << 2
    private static let cC:  UInt16 = 1 << 3
    private static let cCH: UInt16 = 1 << 4
    private static let cM:  UInt16 = 1 << 5
    private static let cN:  UInt16 = 1 << 6
    private static let cNG: UInt16 = 1 << 7
    private static let cNH: UInt16 = 1 << 8
    private static let cI:  UInt16 = 1 << 9
    private static let cY:  UInt16 = 1 << 10
    private static let cO:  UInt16 = 1 << 11
    private static let cU:  UInt16 = 1 << 12
    /// Nucleus flag: rime only occurs with the zero onset (ya, yê: yếu, yên…).
    private static let zOnly: UInt16 = 1 << 15
    /// Stop codas require sắc/nặng.
    private static let stops: UInt16 = cP | cT | cC | cCH

    @inline(__always)
    private static func vowelCodaBit(_ v: UInt8) -> UInt16? {
        switch v {
        case 6:  return cI
        case 12: return cY
        case 7:  return cO
        case 10: return cU
        default: return nil
        }
    }

    /// Consonant coda (packed folded ascii, 1–2 letters) → bit, or nil if not a coda.
    @inline(__always)
    private static func consonantCodaBit(_ key: UInt16, _ len: Int) -> UInt16? {
        if len == 1 {
            switch UInt8(key & 0xFF) {
            case UInt8(ascii: "p"): return cP
            case UInt8(ascii: "t"): return cT
            case UInt8(ascii: "c"): return cC
            case UInt8(ascii: "m"): return cM
            case UInt8(ascii: "n"): return cN
            default: return nil
            }
        }
        let c = UInt16(UInt8(ascii: "c")) << 8 | UInt16(UInt8(ascii: "h"))
        let g = UInt16(UInt8(ascii: "n")) << 8 | UInt16(UInt8(ascii: "g"))
        let h = UInt16(UInt8(ascii: "n")) << 8 | UInt16(UInt8(ascii: "h"))
        switch key {
        case c: return cCH
        case g: return cNG
        case h: return cNH
        default: return nil
        }
    }

    // MARK: - Nucleus table (30 written vowel sequences, packed 4-bit codes)

    private struct Nucleus { let key: UInt16; let len: UInt8; let mask: UInt16 }

    private static let nuclei: [Nucleus] = {
        func n(_ codes: [UInt8], _ mask: UInt16) -> Nucleus {
            var k: UInt16 = 0
            for c in codes { k = k << 4 | UInt16(c) }
            return Nucleus(key: k, len: UInt8(codes.count), mask: mask)
        }
        // codes: a=1 ă=2 â=3 e=4 ê=5 i=6 o=7 ô=8 ơ=9 u=10 ư=11 y=12
        return [
            // monophthongs
            n([1],  cE | cP | cT | cC | cCH | cM | cN | cNG | cNH | cI | cY | cO | cU), // a: all
            n([2],  cP | cT | cC | cM | cN | cNG),                    // ă (no bare ă)
            n([3],  cP | cT | cC | cM | cN | cNG | cU | cY),          // â (no bare â)
            n([4],  cE | cP | cT | cC | cM | cN | cNG | cO),          // e (eng/ec: leng keng)
            n([5],  cE | cP | cT | cCH | cM | cN | cNH | cU),         // ê (NO êc/êng)
            n([6],  cE | cP | cT | cCH | cM | cN | cNH | cU),         // i
            n([7],  cE | cP | cT | cC | cM | cN | cNG | cI),          // o
            n([8],  cE | cP | cT | cC | cM | cN | cNG | cI),          // ô
            n([9],  cE | cP | cT | cM | cN | cI),                     // ơ
            n([10], cE | cP | cT | cC | cM | cN | cNG | cI),          // u
            n([11], cE | cT | cC | cNG | cI | cU),                    // ư
            n([12], cE),                                              // y (hy, quý, ỷ)
            // falling diphthongs
            n([6, 1],  cE),                                           // ia (mía)
            n([6, 5],  cP | cT | cC | cM | cN | cNG | cU),            // iê (closed only)
            n([12, 1], cE | zOnly),                                   // ya
            n([12, 5], cT | cM | cN | cNG | cU | zOnly),              // yê (yếu, yên; ∅ onset)
            n([10, 1], cE),                                           // ua (của)
            n([10, 8], cT | cC | cM | cN | cNG | cI),                 // uô (closed only)
            n([11, 1], cE),                                           // ưa (mưa)
            n([11, 9], cP | cT | cC | cM | cN | cNG | cI | cU),       // ươ (closed only)
            n([10, 9], cE),                                           // uơ (huơ, thuở)
            // glide-initial
            n([7, 1],  cE | cP | cT | cC | cCH | cM | cN | cNG | cNH | cI | cY | cO), // oa
            n([7, 2],  cT | cC | cM | cN | cNG),                      // oă (closed only)
            n([7, 4],  cE | cT | cM | cN | cO),                       // oe (khỏe, ngoẻo, ngoém)
            n([7, 7],  cC | cNG),                                     // oo (xoong, soóc)
            n([10, 3], cT | cN | cNG | cY),                           // uâ (closed only)
            n([10, 5], cE | cCH | cNH),                               // uê (quên = qu+ên, not uê+n)
            n([10, 12], cE | cP | cT | cCH | cNH | cU),               // uy (uyp: tuýp)
            n([10, 12, 5], cT | cN),                                  // uyê (uyên, uyêt)
            n([10, 12, 1], cE),                                       // uya (khuya)
        ]
    }()

    /// Base-folded twin of `nuclei` for prefix matching.
    private static let foldedNuclei: [Nucleus] = nuclei.map { n in
        var k: UInt16 = 0
        for i in stride(from: Int(n.len) - 1, through: 0, by: -1) {
            let code = UInt8((n.key >> (4 * i)) & 0xF)
            k = k << 4 | UInt16(fold(code))
        }
        return Nucleus(key: k, len: n.len, mask: n.mask)
    }

    @inline(__always)
    private static func nucleusMask(_ key: UInt16) -> UInt16? {
        // Codes are 1...12 (never 0), so packed keys are unique across lengths.
        for n in nuclei where n.key == key { return n.mask }
        return nil
    }

    // MARK: - Validation

    /// Returns true if `word` is a well-formed Vietnamese syllable.
    /// Single O(n) pass, no heap allocation.
    public static func isValidSyllable(_ word: String) -> Bool {
        var tone = Tone.none
        var onsetKey: UInt32 = 0
        var onsetLen = 0
        var v0: UInt8 = 0, v1: UInt8 = 0, v2: UInt8 = 0, v3: UInt8 = 0
        var vcount = 0
        var codaKey: UInt16 = 0
        var codaLen = 0
        var state = 0   // 0 = onset, 1 = vowels, 2 = coda
        var total = 0

        for sc in word.unicodeScalars {
            total += 1
            if total > 10 { return false }  // longest valid syllable is 7 letters

            var vc: UInt8 = 0
            var cc: UInt8 = 0
            if let (base, t) = Tables.detoneTable[sc.value] {
                guard let v = vowelCode(base) else { return false }
                if t != .none {
                    if tone != .none { return false }  // two tones
                    tone = t
                }
                vc = v
            } else if sc.value == 0x111 || sc.value == 0x110 {  // đ Đ
                cc = dBar
            } else if sc.value < 128, isLetter(UInt8(sc.value)) {
                cc = lowercased(UInt8(sc.value))    // plain vowels are in detoneTable
            } else {
                return false
            }

            if vc != 0 {
                if state == 2 { return false }      // vowel after coda
                state = 1
                switch vcount {
                case 0: v0 = vc
                case 1: v1 = vc
                case 2: v2 = vc
                case 3: v3 = vc
                default: return false
                }
                vcount += 1
            } else if state == 0 {
                if onsetLen == 3 { return false }
                onsetKey = onsetKey << 8 | UInt32(cc)
                onsetLen += 1
            } else {
                state = 2
                if codaLen == 2 { return false }
                codaKey = codaKey << 8 | UInt16(cc)
                codaLen += 1
            }
        }
        if vcount == 0 { return false }

        @inline(__always) func vAt(_ i: Int) -> UInt8 {
            i == 0 ? v0 : i == 1 ? v1 : i == 2 ? v2 : v3
        }

        // --- Onset + spelling gate ---
        var isQu = false
        var isGi = false
        var nStart = 0
        if onsetLen > 0 {
            if onsetLen == 1, onsetKey == UInt32(UInt8(ascii: "q")) {
                // q only as qu: the u joins the onset, nucleus starts after it.
                guard vcount >= 2, v0 == 10 else { return false }
                isQu = true
                nStart = 1
            } else if onsetLen == 1, onsetKey == UInt32(UInt8(ascii: "g")),
                      vcount >= 2, v0 == 6 {
                // gi + vowel: the i joins the onset (già, giữ). A lone g+i (gì,
                // gìn) falls through to the g entry, whose gate lets i pass.
                isGi = true
                nStart = 1
            } else {
                var gate: Gate? = nil
                for o in onsetTable where o.key == onsetKey {
                    gate = o.gate
                    break
                }
                guard let g = gate else { return false }
                let first = v0
                switch g {
                case .frontOnly: if !isFront(first) { return false }
                case .nonFront:  if isFront(first) { return false }
                case .gLike:     if first == 4 || first == 5 || first == 12 { return false }
                case .any: break
                }
            }
        }

        // --- Coda bit ---
        var cBit = cE
        if codaLen > 0 {
            guard let b = consonantCodaBit(codaKey, codaLen) else { return false }
            cBit = b
        }
        let zeroOnset = (onsetLen == 0)

        @inline(__always) func accept(_ mask: UInt16, _ bit: UInt16) -> Bool {
            if mask & zOnly != 0 && !zeroOnset { return false }
            return mask & bit != 0
        }

        // Try nucleus = codes[nStart...] (optionally with a prepended glide code
        // for the qu/gi retries), consuming either the consonant coda or —
        // in an open run — a trailing vowel coda (i y o u).
        func attempt(_ prepend: UInt8) -> Bool {
            let len = (vcount - nStart) + (prepend != 0 ? 1 : 0)
            if codaLen > 0 {
                guard len >= 1, len <= 3 else { return false }
                var k: UInt16 = prepend != 0 ? UInt16(prepend) : 0
                for i in nStart..<vcount { k = k << 4 | UInt16(vAt(i)) }
                guard let m = nucleusMask(k) else { return false }
                return accept(m, cBit)
            }
            // Whole run as an open nucleus…
            if len >= 1, len <= 3 {
                var k: UInt16 = prepend != 0 ? UInt16(prepend) : 0
                for i in nStart..<vcount { k = k << 4 | UInt16(vAt(i)) }
                if let m = nucleusMask(k), accept(m, cE) { return true }
            }
            // …or nucleus + vowel coda (ai, ươi, oao, khuỷu).
            if len >= 2, len - 1 <= 3, let vb = vowelCodaBit(vAt(vcount - 1)) {
                var k: UInt16 = prepend != 0 ? UInt16(prepend) : 0
                for i in nStart..<(vcount - 1) { k = k << 4 | UInt16(vAt(i)) }
                if let m = nucleusMask(k), accept(m, vb) { return true }
            }
            return false
        }

        var ok = attempt(0)
        // qu + y…: the onset u actually belongs to the nucleus
        // (quỳnh = q+uynh, quýt, quyên). Zero new table entries.
        if !ok, isQu, vAt(nStart) == 12 { ok = attempt(10) }
        // gi + ê…: the onset i actually belongs to the nucleus (giêng, giếc).
        if !ok, isGi, vAt(nStart) == 5 { ok = attempt(6) }
        guard ok else { return false }

        // Stop codas (p t c ch) only allow sắc / nặng.
        if cBit & stops != 0, tone != .acute, tone != .dot { return false }
        return true
    }

    // MARK: - Prefix validity (live spell-check while typing)

    /// True if `word` (a composition in progress) could still grow into a valid
    /// Vietnamese syllable. PERMISSIVE by design: it must never reject a valid word
    /// mid-typing (that would wrongly stop composing) — vowel marks are folded to
    /// base letters so un-accented Telex intermediates ("uo", "ie", "uoi") pass,
    /// tones are ignored, and onset spelling gates / zero-onset flags are not
    /// enforced. Callers use it only to DISABLE transforms on words that clearly
    /// cannot be Vietnamese (foreign words, URLs). Zero heap allocation.
    public static func isValidPrefix(_ word: String) -> Bool {
        if word.isEmpty { return true }
        var onsetKey: UInt32 = 0
        var onsetLen = 0
        var v0: UInt8 = 0, v1: UInt8 = 0, v2: UInt8 = 0, v3: UInt8 = 0
        var vcount = 0
        var codaKey: UInt16 = 0
        var codaLen = 0
        var state = 0

        for sc in word.unicodeScalars {
            var vc: UInt8 = 0
            var cc: UInt8 = 0
            if let (base, _) = Tables.detoneTable[sc.value] {
                guard let v = vowelCode(base) else { return false }
                vc = fold(v)
            } else if sc.value == 0x111 || sc.value == 0x110 {
                cc = UInt8(ascii: "d")              // đ folds to d
            } else if sc.value < 128, isLetter(UInt8(sc.value)) {
                cc = lowercased(UInt8(sc.value))
            } else {
                return false
            }

            if vc != 0 {
                if state == 2 { return false }
                state = 1
                switch vcount {
                case 0: v0 = vc
                case 1: v1 = vc
                case 2: v2 = vc
                case 3: v3 = vc
                default: return false               // no rime has >4 vowel letters
                }
                vcount += 1
            } else if state == 0 {
                if onsetLen == 3 { return false }
                onsetKey = onsetKey << 8 | UInt32(cc)
                onsetLen += 1
            } else {
                state = 2
                if codaLen == 2 { return false }    // no coda has >2 letters
                codaKey = codaKey << 8 | UInt16(cc)
                codaLen += 1
            }
        }

        @inline(__always) func vAt(_ i: Int) -> UInt8 {
            i == 0 ? v0 : i == 1 ? v1 : i == 2 ? v2 : v3
        }

        // Still inside the initial consonant cluster: any onset prefix passes.
        if vcount == 0 {
            if onsetKey == UInt32(UInt8(ascii: "q")) { return true }  // → qu
            for o in onsetTable where Int(o.len) >= onsetLen {
                if o.key >> (8 * (UInt32(o.len) - UInt32(onsetLen))) == onsetKey {
                    return true
                }
            }
            return false
        }

        // The typed consonant coda so far must be a prefix of SOME allowed coda
        // ("uen" mid-way to "uênh": n is a prefix of nh).
        func codaPrefixOK(_ mask: UInt16) -> Bool {
            if codaLen == 1 {
                switch UInt8(codaKey & 0xFF) {
                case UInt8(ascii: "p"): return mask & cP != 0
                case UInt8(ascii: "t"): return mask & cT != 0
                case UInt8(ascii: "c"): return mask & (cC | cCH) != 0
                case UInt8(ascii: "m"): return mask & cM != 0
                case UInt8(ascii: "n"): return mask & (cN | cNG | cNH) != 0
                default: return false
                }
            }
            return consonantCodaBit(codaKey, codaLen).map { mask & $0 != 0 } ?? false
        }

        // Folded vowel run [s..<e) packed.
        func packedV(_ s: Int, _ e: Int) -> UInt16 {
            var k: UInt16 = 0
            for i in s..<e { k = k << 4 | UInt16(vAt(i)) }
            return k
        }

        // Is codes[s...] (+ trailing consonants) a plausible partial rime?
        func rimePlausible(_ s: Int) -> Bool {
            let vlen = vcount - s
            if vlen == 0 { return codaLen == 0 }
            if vlen > 4 { return false }
            let full = packedV(s, vcount)
            for nf in foldedNuclei {
                let fl = Int(nf.len)
                if fl >= vlen {
                    if nf.key >> (4 * (fl - vlen)) != full { continue }
                    if fl > vlen { if codaLen == 0 { return true } }
                    else if codaLen == 0 || codaPrefixOK(nf.mask) { return true }
                } else if fl == vlen - 1, codaLen == 0,
                          nf.key == packedV(s, vcount - 1),
                          let vb = vowelCodaBit(vAt(vcount - 1)),
                          nf.mask & vb != 0 {
                    return true                     // nucleus + vowel coda (a|i, ươ|i)
                }
            }
            return false
        }

        // Every onset interpretation is tried; ANY plausible one accepts.
        // 1) Onset = the consonant run itself (or zero onset).
        var runIsOnset = (onsetLen == 0)
        if onsetLen > 0 {
            for o in onsetTable where o.key == onsetKey {
                runIsOnset = true
                break
            }
        }
        if runIsOnset, rimePlausible(0) { return true }
        // 2) qu: glide u joins the onset — and (retry semantics) u kept in the
        //    nucleus, so quỳnh/quýt keep composing (q + uynh).
        if onsetLen == 1, onsetKey == UInt32(UInt8(ascii: "q")), v0 == 10 {
            if rimePlausible(1) { return true }
            if rimePlausible(0) { return true }
        }
        // 3) gi: glide i joins the onset (già, giường).
        if onsetLen == 1, onsetKey == UInt32(UInt8(ascii: "g")), v0 == 6 {
            if rimePlausible(1) { return true }
        }
        return false
    }
}
