import XCTest
@testable import TelexCore

/// Type a whole key sequence into a fresh engine and return the composed word.
private func compose(_ keys: String) -> String {
    var e = TelexEngine()
    for ch in keys { _ = e.feed(ch) }
    return e.composed
}

/// Same, with "bỏ dấu tự do" (free mark placement) enabled.
private func composeFree(_ keys: String) -> String {
    var e = TelexEngine()
    e.freeMarking = true
    for ch in keys { _ = e.feed(ch) }
    return e.composed
}

/// Same, with modern-orthography tone placement (hoà, thuý) enabled.
private func composeModern(_ keys: String) -> String {
    var e = TelexEngine()
    e.modernTone = true
    for ch in keys { _ = e.feed(ch) }
    return e.composed
}

/// Same, with live spell-check (stop transforming invalid words) enabled.
private func composeSpell(_ keys: String) -> String {
    var e = TelexEngine()
    e.liveSpellCheck = true
    for ch in keys { _ = e.feed(ch) }
    return e.composed
}

/// Same, in Simple Telex mode (standalone w stays literal).
private func composeSimple(_ keys: String) -> String {
    var e = TelexEngine()
    e.simpleTelex = true
    for ch in keys { _ = e.feed(ch) }
    return e.composed
}

/// Simple Telex + free marking together (the 1.3.1 defaults).
private func composeSimpleFree(_ keys: String) -> String {
    var e = TelexEngine()
    e.simpleTelex = true
    e.freeMarking = true
    for ch in keys { _ = e.feed(ch) }
    return e.composed
}

/// Type keys then commit at a word boundary with auto-restore on.
private func commit(_ keys: String) -> String {
    var e = TelexEngine()
    for ch in keys { _ = e.feed(ch) }
    return e.commitText(autoRestore: true)
}

final class EngineGoldenTests: XCTestCase {

    // B1: "uo" + horn -> ươ (horn BOTH) when the ơ is closed (has a coda/offglide)
    // and the u is not the "qu" glide; stays plain "uơ" when ơ is the last letter
    // (open) or after "qu". Fixes trường/được/nước while keeping thuở/quở correct.
    func testUowHornPropagation() {
        // Closed -> ươ (both horned). Very common words.
        XCTAssertEqual(compose("truowngf"), "trường")
        XCTAssertEqual(compose("dduowcj"), "được")
        XCTAssertEqual(compose("nuowcs"), "nước")
        XCTAssertEqual(compose("thuwowng"), "thương")
        XCTAssertEqual(compose("dduowngf"), "đường")    // w right after uo
        XCTAssertEqual(compose("tuowi"), "tươi")        // offglide i closes it
        XCTAssertEqual(compose("nguowif"), "người")
        XCTAssertEqual(compose("muwowif"), "mười")

        // Open "uơ" -> plain u (ơ is the last letter). Rare but real words.
        XCTAssertEqual(compose("thuowr"), "thuở")
        XCTAssertEqual(compose("huow"), "huơ")

        // "qu" glide -> plain u (u belongs to the onset).
        XCTAssertEqual(compose("quowr"), "quở")
        XCTAssertEqual(compose("quown"), "quơn")        // closed but qu-glide stays u

        // Explicit double-w still works and agrees.
        XCTAssertEqual(compose("nguwowif"), "người")

        // Fast typing can reorder adjacent o/w so the engine sees "uwo" instead of
        // "uow". Both must yield ươ (this is the "được"->"đựoc" fast-typing report).
        XCTAssertEqual(compose("dduowjc"), "được")   // normal order
        XCTAssertEqual(compose("dduwojc"), "được")   // o/w reordered
        XCTAssertEqual(compose("dduwocj"), "được")   // w before o, tone last
        XCTAssertEqual(compose("truwongf"), "trường") // reordered
        XCTAssertEqual(compose("suwong"), "sương")    // reordered
        XCTAssertEqual(compose("nguwoif"), "người")   // reordered
    }

    // "Bỏ dấu tự do" toggle. Default (strict / Minimal Telex):
    // modifiers act only on the adjacent vowel — reach-back over a consonant is off,
    // so English/code types cleanly. Free mode: modifiers reach back over consonants.
    // FREE MARKING: circumflex doublers cross the whole nucleus (UniKey-style) —
    // "daua"→dâu, "dauas"→dấu — never the onset boundary (qu/gi stay safe).

    /// Standalone-w cancel ladder under free marking (user request 2026-07-21):
    /// w→ư, ww→u (cancel yields the bare u, no literal w), www→uw (the press
    /// after a cancel is literal). The classic uw-typed revert is unchanged.
    func testStandaloneWCancelLadder() {
        XCTAssertEqual(composeFree("w"), "ư")
        XCTAssertEqual(composeFree("ww"), "u")
        XCTAssertEqual(composeFree("www"), "uw")
        XCTAssertEqual(composeFree("nhw"), "như")
        XCTAssertEqual(composeFree("nhww"), "nhu")
        // uw-typed horn keeps the classic revert (the u was really typed)
        XCTAssertEqual(composeFree("uw"), "ư")
        XCTAssertEqual(composeFree("uww"), "uw")
    }

    /// Free-marking order tolerance (user request 2026-07-21): late modifier keys
    /// find their target across the word — did→đi, theme→thêm — and w on a "uu"
    /// nucleus horns the FIRST u (luuw→lưu, cuuws→cứu; "uư" is no nucleus).
    func testFreeMarkingOutOfOrderTyping() {
        XCTAssertEqual(composeFree("did"), "đi")
        XCTAssertEqual(composeFree("theme"), "thêm")
        XCTAssertEqual(composeFree("luuw"), "lưu")
        XCTAssertEqual(composeFree("cuuws"), "cứu")
        XCTAssertEqual(composeFree("dad"), "đa")
        // qu glide is excluded from the uu retarget (same as the ua rule)
        XCTAssertEqual(composeFree("quuw"), "quư")
        // no modifier → no reach-back side effects
        XCTAssertEqual(composeFree("luu"), "luu")
        XCTAssertEqual(composeFree("them"), "them")
    }
    func testFreeMarkingDoublerCrossesNucleus() {
        XCTAssertEqual(composeFree("daua"), "dâu")
        XCTAssertEqual(composeFree("dauas"), "dấu")
        XCTAssertEqual(composeFree("mauas"), "mấu")
        // Coda reach-back unchanged.
        XCTAssertEqual(composeFree("coto"), "côt")
        XCTAssertEqual(composeFree("ama"), "âm")
        // Onset boundary is never crossed: no vowel match → literal.
        XCTAssertEqual(composeFree("quao"), "quao")
        // Immediate doubling still wins first (standard Telex, both modes).
        XCTAssertEqual(composeFree("muaa"), "muâ")
        // STRICT mode: nucleus-crossing must NOT happen. (The bare-compose "dauas"
        // → "daúa" is pre-existing strict behavior — tone still applies; with the
        // real default liveSpellCheck ON the invalid word freezes to raw.)
        XCTAssertEqual(compose("daua"), "daua")
        XCTAssertEqual(composeSpell("dauas"), "dauas")
    }

    // TEENCODE: informal onsets validate as their canonical spelling (w→qu, z→d,
    // dz→d) so chat forms survive spell-check + auto-restore, while their rimes
    // still obey the normal rules. English collisions with a TRANSFORMED w (full
    // Telex "was"→ứa) stay force-restored; the Simple-Telex literal-w "wá" is the
    // feature and survives.
    func testTeencodeForms() {
        // Simple Telex: literal w + tone = the wá/wó family (w validates as qu).
        var e = TelexEngine(); e.simpleTelex = true; e.liveSpellCheck = true
        for ch in "was" { _ = e.feed(ch) }
        XCTAssertEqual(e.composed, "wá")
        XCTAssertEqual(e.commitText(autoRestore: true), "wá")   // survives restore
        for ch in "wos" { _ = e.feed(ch) }
        XCTAssertEqual(e.commitText(autoRestore: true), "wó")
        // z / dz forms work in BOTH modes (z is a literal letter everywhere).
        XCTAssertEqual(commit("zoo"), "zô")
        XCTAssertEqual(commit("zij"), "zị")
        XCTAssertEqual(commit("zaayj"), "zậy")
        XCTAssertEqual(commit("dzoo"), "dzô")
        XCTAssertEqual(commit("dzij"), "dzị")
        // Garbage rimes still restore: the onset swap doesn't bless everything.
        XCTAssertEqual(commit("zxkr"), "zxkr")
        // FULL Telex: leading w transforms, and the English exceptions still win.
        XCTAssertEqual(commit("was"), "was")
        XCTAssertEqual(commit("wow"), "wow")
    }

    // Backspacing a frozen (invalid) word must NOT retroactively re-enable
    // transforms: "installer" ⌫ stays "installe", not "intálle" (the freeze is
    // replayed over the shortened word exactly as forward typing computed it).
    func testBackspaceKeepsSpellCheckFreeze() {
        var e = TelexEngine()
        e.liveSpellCheck = true
        e.freeMarking = true
        for ch in "installer" { _ = e.feed(ch) }
        XCTAssertEqual(e.composed, "installer")
        _ = e.backspace()
        XCTAssertEqual(e.composed, "installe")
        _ = e.backspace()
        XCTAssertEqual(e.composed, "install")
    }

    // Abbreviation whitelist: "đc" (= được) survives auto-restore.
    /// ALL-CAPS abbreviations with đ survive auto-restore: ĐSQ stays ĐSQ
    /// (not restored to DDSQ). Lowercase/mixed and marked words keep restoring.
    func testUppercaseDAcronymSurvivesAutoRestore() {
        XCTAssertEqual(commit("DDSQ"), "ĐSQ")      // Đại Sứ Quán
        XCTAssertEqual(commit("DDHQG"), "ĐHQG")    // Đại Học Quốc Gia
        XCTAssertEqual(commit("DDN"), "ĐN")        // Đà Nẵng
        // escape hatch: the double-key cancel still yields a literal DD
        XCTAssertEqual(commit("DDDR"), "DDR")
        // lowercase đ+consonants is now an accepted abbreviation (2026-07-22)…
        XCTAssertEqual(commit("ddsq"), "đsq")
        // …but a vowel after the consonants exits the abbreviation rule and the
        // normal validation restores the invalid word
        XCTAssertEqual(commit("ddsqa"), "ddsqa")
        // vowel marks in caps are NOT covered by the acronym rule; "Â" survives
        // because the validator already accepts it as a syllable (pre-existing)
        XCTAssertEqual(commit("AA"), "Â")
    }

    func testDcAbbreviationSurvivesAutoRestore() {
        XCTAssertEqual(commit("ddc"), "đc")
        XCTAssertEqual(compose("ddc"), "đc")
        // s here is a literal consonant (no vowel to tone) → still đ+consonants,
        // covered by the generalized abbreviation rule (2026-07-22)
        XCTAssertEqual(commit("ddcs"), "đcs")
    }

    // Word-initial standalone w → ư belongs to FULL Telex (Simple Telex off) —
    // corrected 2026-07-21 after briefly being keyed to free marking. Under Simple
    // Telex a lone w is literal EVERYWHERE, free marking or not; English w-words
    // under full Telex rely on auto-restore at the boundary.
    func testWordInitialWIsFullTelex() {
        XCTAssertEqual(compose("w"), "ư")               // full Telex (engine default)
        XCTAssertEqual(compose("wa"), "ưa")
        XCTAssertEqual(compose("wu"), "ưu")             // "ưu tiên"-class
        XCTAssertEqual(commit("windows"), "windows",
                       "English w-word restores raw at the boundary under full Telex")
        // Simple Telex: literal everywhere, regardless of free marking.
        XCTAssertEqual(composeSimple("w"), "w")
        XCTAssertEqual(composeSimple("wa"), "wa")
        XCTAssertEqual(composeSimpleFree("w"), "w")
        XCTAssertEqual(composeSimpleFree("wa"), "wa")
    }

    func testFreeMarkingToggle() {
        // --- Strict (default): reach-back over a consonant is blocked. ---
        XCTAssertEqual(compose("ama"), "ama")       // circumflex can't cross the m
        XCTAssertEqual(compose("aam"), "âm")        // adjacent doubler still works
        XCTAssertEqual(compose("coto"), "coto")     // vs "coot"→côt
        XCTAssertEqual(compose("coot"), "côt")
        XCTAssertEqual(compose("data"), "data")     // English stays intact
        XCTAssertEqual(compose("trangw"), "trangw") // w can't cross the ng coda
        XCTAssertEqual(compose("trawng"), "trăng")  // w adjacent to a still works
        XCTAssertEqual(compose("quatw"), "quatw")   // strict: no reach-back over t

        // --- Free ("bỏ dấu tự do"): reach-back over a consonant coda. ---
        XCTAssertEqual(composeFree("ama"), "âm")
        XCTAssertEqual(composeFree("aam"), "âm")
        XCTAssertEqual(composeFree("coto"), "côt")
        XCTAssertEqual(composeFree("trangw"), "trăng")
        XCTAssertEqual(composeFree("trawng"), "trăng")
        XCTAssertEqual(composeFree("quatw"), "quăt")

        // --- Both modes: reach-back over a VOWEL offglide stays on (người), and
        // adjacent-vowel rules (ua horn, ươ propagation) are unaffected. ---
        for word in ["nguoiwf", "truowngf", "nuawx", "nuwax", "dduowcj"] {
            XCTAssertEqual(compose(word), composeFree(word), "mode-invariant: \(word)")
        }
        XCTAssertEqual(compose("nguoiwf"), "người")
        XCTAssertEqual(compose("nuawx"), "nữa")
        XCTAssertEqual(compose("truowngf"), "trường")
    }

    // G2 SAFETY (critical): live spell-check must NEVER break a real Vietnamese word
    // mid-typing. Every intermediate Telex state (bare "uo"/"ie"/"uoi" before the
    // diacritic lands) must be accepted as a valid prefix. If any of these regress,
    // isValidPrefix is too strict.
    func testLiveSpellCheckKeepsValidWords() {
        let words = [
            "ddaay", "tieengs", "vieejt", "hoas", "huyeenf", "nguwowif", "quaan",
            "thuowr", "truwowngf", "dduowcj", "nuwowcs", "thuwowng", "dduowngf",
            "nguoiwf", "muwowif", "tuowi", "quocs", "quyeenr", "thuyeenf", "khuya",
            "uoongs", "mias", "cuar", "muaf", "chuyeenj", "nghieeng",
            "ngoaif", "ngoays", "khoer", "thuys", "huowngs", "sawnx",
            "ddoongf", "ddaaus", "gif", "ginf", "quets", "toans", "lamf",
            "ban", "conf", "Vieejt", "Nam",
        ]
        for w in words {
            XCTAssertEqual(composeSpell(w), compose(w),
                           "live spell-check must not alter valid word: \(w)")
        }
        // And they really are the right words (spot checks).
        XCTAssertEqual(composeSpell("nguoiwf"), "người")
        XCTAssertEqual(composeSpell("truwowngf"), "trường")
        XCTAssertEqual(composeSpell("dduowcj"), "được")
    }

    // G2 EFFECT: a foreign word stops accreting diacritics once it can't be Vietnamese.
    func testLiveSpellCheckStopsForeignWords() {
        // "google": goo→gô is a valid prefix, but the 2nd g makes "gôg" impossible →
        // freeze; l,e stay literal. Boundary auto-restore (elsewhere) reverts the token.
        XCTAssertEqual(composeSpell("google"), "gôgle")
        // Keys after the freeze are literal — no tone/circumflex applied.
        XCTAssertEqual(composeSpell("googlex"), "gôglex")   // x not ngã
        XCTAssertEqual(composeSpell("googlee"), "gôglee")   // ee not ê
        XCTAssertEqual(composeSpell("github"), "github")    // never valid past "gith"
        // Without live spell-check the tail WOULD transform (contrast).
        XCTAssertNotEqual(compose("googlex"), "gôglex")
    }

    // G1: modern-orthography toggle. Only oa/oe/uy OPEN nuclei move the tone to the
    // second vowel; everything else is identical to the default old style.
    func testModernOrthography() {
        // Differ: glide-initial open diphthongs.
        XCTAssertEqual(compose("hoas"), "hóa");   XCTAssertEqual(composeModern("hoas"), "hoá")
        XCTAssertEqual(compose("khoer"), "khỏe");  XCTAssertEqual(composeModern("khoer"), "khoẻ")
        XCTAssertEqual(compose("thuys"), "thúy");  XCTAssertEqual(composeModern("thuys"), "thuý")
        XCTAssertEqual(compose("hoef"), "hòe");    XCTAssertEqual(composeModern("hoef"), "hoè")

        // Identical in both styles (falling diphthongs, coda, single vowel, ê/ơ magnet).
        for w in ["muaf", "mias", "cuar", "toans", "hoafng", "tieengs",
                  "as", "banf", "nguowif", "quaf", "giaf"] {
            XCTAssertEqual(composeModern(w), compose(w), "style-invariant: \(w)")
        }
        // Spot-check a couple of the invariants' actual values.
        XCTAssertEqual(composeModern("muaf"), "mùa")   // ua falling: tone stays on u
        XCTAssertEqual(composeModern("toans"), "toán") // closed: second vowel both ways
    }

    // Auto-restore leaves a word alone when the user explicitly CANCELLED a diacritic
    // (double tone / z / double circumflex / double breve-horn / double-d). That
    // gesture means "I want the literal", so "iss"→is must NOT be restored to "iss".
    // Trade-off (accepted): English double-letter words like miss/class also keep the
    // composed (shorter) form rather than restoring the raw keystrokes.
    func testCancelledMarkFollowsValidityRule() {
        // Cancel keeps the composed text (the extra key was an undo gesture) —
        // UNLESS the raw keys are a real English word (dict wins: ass, off…).
        XCTAssertEqual(commit("iss"), "is")
        XCTAssertEqual(commit("ass"), "ass")    // English → dict restore
        XCTAssertEqual(commit("aff"), "af")
        XCTAssertEqual(commit("asz"), "a")      // z-cancel leaves valid "a" -> keep composed
        XCTAssertEqual(commit("aaa"), "aa")

        // After a cancel the rest of the word stays literal (English): a further tone
        // key does NOT re-apply a diacritic. "messs"→mess, not "més".
        XCTAssertEqual(compose("messs"), "mess")
        XCTAssertEqual(compose("asss"), "ass")
        XCTAssertEqual(compose("bossss"), "bosss") // b,o + s(sắc) s(cancel) s s literal
        XCTAssertEqual(commit("messs"), "mess")    // cancel keeps composed (messs not English)

        // Not a cancel: a mangled word (diacritic applied, no cancel) still restores
        // to the raw keystrokes. "school" -> "schôl" (oo→ô) -> restored to "school".
        XCTAssertEqual(commit("school"), "school")

        // Valid Vietnamese is never touched regardless.
        XCTAssertEqual(commit("toans"), "toán")
        XCTAssertEqual(commit("hoas"), "hóa")
    }

    // Uppercase tone/mark key in a MIXED-case word = English/code signal ("OmS",
    // "SaaS", "JavaScript"). The whole word freezes to its raw keystrokes LIVE — the
    // tone never even flashes ("OmS" stays "OmS", not briefly "Óm"). All-caps words
    // are exempt (uppercase tone keys are how you type VIỆT); mark doublers with
    // shift held (DDaay) and lowercase tone keys are untouched.
    func testUpperToneKeyMixedCaseRestores() {
        // Live (while composing), not just at the word boundary.
        XCTAssertEqual(compose("OmS"), "OmS")             // not "Óm" (lowercase before S)
        // But an uppercase tone key that PRECEDES any lowercase is just a capital:
        // keep the tone.
        XCTAssertEqual(compose("OSm"), "Óm")
        XCTAssertEqual(commit("OSm"), "Óm")
        XCTAssertEqual(compose("SaaS"), "SaaS")           // not "Sấ"
        XCTAssertEqual(compose("JavaScript"), "JavaScript")
        XCTAssertEqual(commit("SaaS"), "SaaS")
        XCTAssertEqual(commit("TypeScript"), "TypeScript")
        // All-caps: uppercase tone keys are legitimate Vietnamese.
        XCTAssertEqual(compose("VIEEJT"), "VIỆT")
        XCTAssertEqual(compose("HOAS"), "HÓA")
        // Lowercase tone keys unaffected.
        XCTAssertEqual(compose("hoas"), "hóa")
        XCTAssertEqual(compose("Vieejt"), "Việt")
        // Shift held across a mark doubler is normal typing, still composes.
        XCTAssertEqual(compose("DDaay"), "Đây")
    }

    // C2: the w modifier reaches back to a/o/u. Crossing a VOWEL offglide (i) works
    // in both modes; crossing a CONSONANT coda is free-mode only (see toggle test).
    func testWReachesBackOverCoda() {
        XCTAssertEqual(compose("moiw"), "mơi")     // w after i (vowel) -> horn the o
        XCTAssertEqual(compose("nguoiwf"), "người") // w after i -> ơ, then ươ + tone
        XCTAssertEqual(compose("quaw"), "quă")     // immediate case still fine
        XCTAssertEqual(compose("thw"), "thư")      // no a/o/u -> standalone ư
        XCTAssertEqual(compose("uw"), "ư")
        XCTAssertEqual(composeFree("quatw"), "quăt") // w after t (coda) -> free only
    }

    // "ua" nucleus: w horns the u (→ ưa), never breves the a ("uă" is invalid).
    // Marks become order-free — w typed AFTER the a still lands on u.
    func testUaNucleusHornsU() {
        XCTAssertEqual(compose("nuawx"), "nữa")    // w+tone typed after the a
        XCTAssertEqual(compose("nuwax"), "nữa")    // w typed right after u — same result
        XCTAssertEqual(compose("muaw"), "mưa")
        XCTAssertEqual(compose("chuaw"), "chưa")
        XCTAssertEqual(compose("buawx"), "bữa")
        XCTAssertEqual(compose("tuawj"), "tựa")
        // "oa" still breves the a (o is not a u vowel): hoă / hoặc.
        XCTAssertEqual(compose("hoaw"), "hoă")
        XCTAssertEqual(compose("hoawcj"), "hoặc")
        // "qu" glide keeps breve on a (the u belongs to the onset, not retargeted).
        XCTAssertEqual(compose("quawt"), "quăt")   // w adjacent to a -> breve, not horn-u
        XCTAssertEqual(compose("quaw"), "quă")
    }

    // Simple Telex: a standalone w is ALWAYS literal — type `uw` for ư.
    // `w` still horns/breves an ADJACENT vowel. Only this differs from full Telex; the
    // bracket rule already matches (this engine never made [ / ] into ơ / ư).
    func testSimpleTelex() {
        // Standalone w -> literal (was cư/thư/sư/ngư in full Telex).
        XCTAssertEqual(composeSimple("cw"), "cw")
        XCTAssertEqual(composeSimple("thw"), "thw")
        XCTAssertEqual(composeSimple("sw"), "sw")
        XCTAssertEqual(composeSimple("ngw"), "ngw")
        XCTAssertEqual(composeSimple("w"), "w")
        XCTAssertEqual(composeSimple("giw"), "giw")
        // Explicit `uw` still gives ư; w on an adjacent vowel still works.
        XCTAssertEqual(composeSimple("uw"), "ư")
        XCTAssertEqual(composeSimple("cuw"), "cư")
        XCTAssertEqual(composeSimple("aw"), "ă")
        XCTAssertEqual(composeSimple("ow"), "ơ")
        // Real words that already type the u are unaffected.
        XCTAssertEqual(composeSimple("nguwowif"), "người")
        XCTAssertEqual(composeSimple("chuaw"), "chưa")   // ua nucleus (adjacent vowel)
        XCTAssertEqual(composeSimple("dduwowngf"), "đường")
        // Contrast: full Telex (default) still turns a lone w into ư.
        XCTAssertEqual(compose("cw"), "cư")
        XCTAssertEqual(compose("thw"), "thư")
    }

    // C3: a standalone w (no a/o/u to modify) becomes ư ONLY after an onset that
    // can begin a "ư" syllable. After k/q/gh/ngh/p, after "qu", or after another
    // vowel, w stays literal so English words type through unmangled.
    func testStandaloneWBlocking() {
        // Blocked -> literal w (was wrongly "kư", "qư"…).
        XCTAssertEqual(compose("kw"), "kw")
        XCTAssertEqual(compose("qw"), "qw")
        XCTAssertEqual(compose("ghw"), "ghw")
        XCTAssertEqual(compose("nghw"), "nghw")
        XCTAssertEqual(compose("pw"), "pw")
        XCTAssertEqual(compose("ew"), "ew")     // vowel before -> block
        XCTAssertEqual(compose("iw"), "iw")

        // Leading 'w' under FULL Telex converts (corrected 2026-07-21: the English
        // guard is Simple-Telex-only now); English w-words are recovered by
        // auto-restore at the word boundary instead of being blocked up front.
        XCTAssertEqual(compose("w"), "ư")
        // Valid-Vietnamese collisions ("was"→ứa, "Wow"→Ươ) are covered by the
        // englishExceptions force-restore list, so common English w-words come
        // back intact at the boundary; invalid ones restore via the validator.
        XCTAssertEqual(commit("was"), "was")
        XCTAssertEqual(commit("web"), "web")
        XCTAssertEqual(commit("win"), "win")
        XCTAssertEqual(commit("write"), "write")
        XCTAssertEqual(commit("Wow"), "Wow")
        XCTAssertEqual(commit("would"), "would")
        // The exception list must not shadow REAL typing of those syllables:
        // "ưas"-by-hand ("uwas") still commits Vietnamese.
        XCTAssertEqual(commit("uwas"), "ứa")

        // Allowed -> ư (valid Vietnamese onsets, must NOT regress).
        XCTAssertEqual(compose("cw"), "cư")
        XCTAssertEqual(compose("sw"), "sư")
        XCTAssertEqual(compose("thw"), "thư")
        XCTAssertEqual(compose("chw"), "chư")
        XCTAssertEqual(compose("ngw"), "ngư")
        XCTAssertEqual(compose("nhw"), "như")
        XCTAssertEqual(compose("trw"), "trư")
        XCTAssertEqual(compose("phw"), "phư")
        XCTAssertEqual(compose("khw"), "khư")
        XCTAssertEqual(compose("giw"), "giư")    // gi onset -> giữ family
        XCTAssertEqual(compose("dw"), "dư")
        XCTAssertEqual(compose("ddw"), "đư")     // đ onset (base d)

        // Horn/breve of a real a/o/u is unaffected (not the standalone path).
        XCTAssertEqual(compose("uw"), "ư")
        XCTAssertEqual(compose("ow"), "ơ")
        XCTAssertEqual(compose("aw"), "ă")
    }

    // C4: rare-but-valid syllables must round-trip through auto-restore untouched,
    // and their composed form must validate (so auto-restore leaves them alone).
    func testAutoRestoreKeepsRareValidWords() {
        // These compose to valid Vietnamese -> validator true -> no restore.
        for (keys, word) in [("sw","sư"), ("thw","thư"), ("cw","cư"),
                             ("quowrn","quởn"), ("giuwx","giữ"), ("uw","ư")] {
            var e = TelexEngine()
            for ch in keys { _ = e.feed(ch) }
            XCTAssertEqual(e.composed, word, "keys=\(keys)")
            XCTAssertTrue(SyllableValidator.isValidSyllable(word), "invalid: \(word)")
            // commitText with auto-restore on keeps the Vietnamese word.
            var e2 = TelexEngine()
            for ch in keys { _ = e2.feed(ch) }
            XCTAssertEqual(e2.commitText(autoRestore: true), word, "restored wrongly: \(keys)")
        }

        // Blocked-w English words are invalid syllables -> restore to raw keys
        // (which already equal the literal composition, so it's a clean no-op).
        var k = TelexEngine()
        for ch in "kw" { _ = k.feed(ch) }
        XCTAssertEqual(k.composed, "kw")
        XCTAssertFalse(SyllableValidator.isValidSyllable("kw"))
        XCTAssertEqual(k.commitText(autoRestore: true), "kw")

        // Whole-word English (w opens on an empty buffer -> ư, then mangles): the
        // safety net here is auto-restore at the boundary, not C3.
        for eng in ["windows", "keyword"] {
            var e = TelexEngine()
            for ch in eng { _ = e.feed(ch) }
            XCTAssertFalse(SyllableValidator.isValidSyllable(e.composed), "unexpectedly valid: \(eng)")
            XCTAssertEqual(e.commitText(autoRestore: true), eng, "not restored: \(eng)")
        }
    }

    /// Auto-restore ON: keystrokes whose composed form is not a valid Vietnamese
    /// syllable revert to the raw keys at the boundary ("retore"→retỏe→"retore").
    /// With it OFF, the (invalid) composed form is kept.
    func testAutoRestoreRevertsInvalidWords() {
        // (keys, composed-display, restored-to-raw)
        let cases = [("retore", "retỏe"), ("user", "ủe"), ("paper", "pảpe"),
                     ("after", "ảte"), ("strongs", "stróng"), ("codej", "cọde"),
                     ("helloj", "hẹllo")]
        for (keys, display) in cases {
            var on = TelexEngine()
            for ch in keys { _ = on.feed(ch) }
            XCTAssertEqual(on.composed, display, "display \(keys)")
            XCTAssertFalse(SyllableValidator.isValidSyllable(display), "should be invalid: \(display)")
            XCTAssertEqual(on.commitText(autoRestore: true), keys, "should restore: \(keys)")

            var off = TelexEngine()
            for ch in keys { _ = off.feed(ch) }
            XCTAssertEqual(off.commitText(autoRestore: false), display, "off keeps VN: \(keys)")
        }

        // "test"→tét is a VALID syllable the validator can't refuse — the
        // English-collision table (EnglishCollisions.swift) now restores it.
        var t = TelexEngine()
        for ch in "test" { _ = t.feed(ch) }
        XCTAssertEqual(t.composed, "tét")
        XCTAssertTrue(SyllableValidator.isValidSyllable("tét"))
        XCTAssertEqual(t.commitText(autoRestore: true), "test")
        // …unless the table is switched off (gen-english measurement mode).
        var t2 = TelexEngine()
        t2.englishWordRestore = false
        for ch in "test" { _ = t2.feed(ch) }
        XCTAssertEqual(t2.commitText(autoRestore: true), "tét")
    }

    // C1: a trailing d converts the onset d to đ.
    func testTrailingDMakesDbar() {
        XCTAssertEqual(compose("dand"), "đan")
        XCTAssertEqual(compose("duwowngd"), "đương")   // no tone key -> no tone
        XCTAssertEqual(compose("duwowngdf"), "đường")  // + huyền
        // Existing dd behavior is unchanged.
        XCTAssertEqual(compose("dd"), "đ")
        XCTAssertEqual(compose("ddd"), "dd")
        XCTAssertEqual(compose("add"), "ađ")
    }

    // B2: stop codas -p, -t, -c, -ch only allow sắc (´) and nặng (.). An invalid
    // huyền/hỏi/ngã is dropped (the syllable keeps no tone) rather than composing
    // an illegal word like "bàt".
    func testStopCodaToneConstraint() {
        // Allowed: sắc / nặng.
        XCTAssertEqual(compose("bats"), "bát")
        XCTAssertEqual(compose("batj"), "bạt")
        XCTAssertEqual(compose("sachs"), "sách")
        XCTAssertEqual(compose("hocj"), "học")
        XCTAssertEqual(compose("caps"), "cáp")

        // Rejected on stop coda -> tone dropped.
        XCTAssertEqual(compose("batf"), "bat")   // no huyền on -t
        XCTAssertEqual(compose("batr"), "bat")   // no hỏi on -t
        XCTAssertEqual(compose("batx"), "bat")   // no ngã on -t
        XCTAssertEqual(compose("sachf"), "sach") // no huyền on -ch
        XCTAssertEqual(compose("capr"), "cap")   // no hỏi on -p
        XCTAssertEqual(compose("hocf"), "hoc")   // no huyền on -c

        // Non-stop codas (-n, -ng, -nh, -m) still allow every tone.
        XCTAssertEqual(compose("banf"), "bàn")
        XCTAssertEqual(compose("bangx"), "bãng")
        XCTAssertEqual(compose("banhr"), "bảnh")
        XCTAssertEqual(compose("lamf"), "làm")
    }

    // The golden table from DESIGN.md plus a broad set of real Vietnamese words.
    func testGoldenTable() {
        let cases: [(String, String)] = [
            // DESIGN.md golden cases
            ("ddaay", "đây"),
            ("tieengs", "tiếng"),
            ("vieejt", "việt"),
            ("hoas", "hóa"),
            ("huyeenf", "huyền"),
            ("nguwowif", "người"),
            ("quaan", "quân"),
            ("thuowr", "thuở"),

            // Single transforms
            ("aa", "â"), ("aw", "ă"), ("ee", "ê"), ("oo", "ô"),
            ("ow", "ơ"), ("uw", "ư"), ("w", "ư"), ("dd", "đ"),   // initial w → ư (full Telex, 1.3.3)

            // Bare tones on 'a'
            ("as", "á"), ("af", "à"), ("ar", "ả"), ("ax", "ã"), ("aj", "ạ"),

            // Old-style tone placement
            ("hoaf", "hòa"), ("khoer", "khỏe"), ("thuys", "thúy"),
            ("toans", "toán"), ("muaf", "mùa"), ("muas", "múa"),
            ("mias", "mía"), ("cuar", "của"),

            // qu / gi onsets (glide belongs to onset)
            ("quys", "quý"), ("quaf", "quà"), ("giaf", "già"),

            // Marked vowel attracts tone
            ("ddaaus", "đấu"), ("nuwowcs", "nước"), ("ddoongf", "đồng"),
            ("chuyeenr", "chuyển"), ("nghieeng", "nghiêng"),

            // Triphthongs (tone on middle vowel)
            ("ngoaif", "ngoài"), ("ngoays", "ngoáy"),

            // Stop coda + valid tone
            ("hocj", "học"), ("caps", "cáp"), ("vieetj", "việt"),

            // Change tone / clear tone mid-sequence
            ("asf", "à"), ("asz", "a"),

            // More words
            ("Vieejt", "Việt"), ("Nam", "Nam"),
            ("cams", "cám"),
            ("ban", "ban"), ("banf", "bàn"), ("conf", "còn"),
            ("truwowngf", "trường"),
        ]
        for (input, expected) in cases {
            XCTAssertEqual(compose(input), expected, "input=\(input)")
        }
    }

    // `z` is a tone-CLEAR key, not an absolute control key (OpenKey parity): it
    // only vanishes when it removes a tone; with nothing to clear it types through.
    func testZClearsToneOrTypesLiteral() {
        // Nothing to clear -> literal z (was silently swallowed before).
        XCTAssertEqual(compose("z"), "z")
        XCTAssertEqual(compose("az"), "az")
        XCTAssertEqual(compose("xyz"), "xyz")
        XCTAssertEqual(compose("pizza"), "pizza")
        // A tone present -> z clears it and is consumed.
        XCTAssertEqual(compose("asz"), "a")       // á -> a
        XCTAssertEqual(compose("huyeenfz"), "huyên")  // huyền -> huyên
    }

    // z is allowed as an initial consonant (casual Vietnamese: zô, zậy, zui), so
    // diacritics apply after it and the word is a valid syllable (no auto-restore).
    func testZAsInitialConsonant() {
        XCTAssertEqual(compose("zoo"), "zô")       // oo -> ô after z
        XCTAssertEqual(commit("zoo"), "zô")        // valid syllable, not restored
        XCTAssertEqual(compose("zaay"), "zây")     // aa -> â
        XCTAssertEqual(compose("zaajy"), "zậy")    // colloquial "zậy"
        XCTAssertEqual(compose("zui"), "zui")
        XCTAssertTrue(SyllableValidator.isValidSyllable("zô"))
        // Still restores true non-syllables that merely start with z.
        XCTAssertEqual(commit("zip"), "zip")       // stop coda -p with no tone -> invalid
    }

    // The "dz" cluster works as an onset (iOS Vietnamese parity): dzô, dzị, dzậy.
    func testDzCluster() {
        XCTAssertEqual(compose("dzij"), "dzị")
        XCTAssertEqual(commit("dzij"), "dzị")      // valid syllable, not restored
        XCTAssertEqual(compose("dzoo"), "dzô")
        XCTAssertEqual(compose("dzaay"), "dzây")
        XCTAssertTrue(SyllableValidator.isValidSyllable("dzị"))
    }

    func testDoubleKeyCancel() {
        let cases: [(String, String)] = [
            ("aaa", "aa"),
            ("eee", "ee"),
            ("ooo", "oo"),
            ("ddd", "dd"),
            ("aww", "aw"),
            ("ass", "as"),   // double sắc cancels, literal s
            ("aff", "af"),
            ("arr", "ar"),
            ("axx", "ax"),
            ("ajj", "aj"),
            ("az", "az"),    // z with no tone to clear -> literal letter (OpenKey parity)
        ]
        for (input, expected) in cases {
            XCTAssertEqual(compose(input), expected, "input=\(input)")
        }
    }

    func testUppercaseAndMixedCase() {
        XCTAssertEqual(compose("DDAAY"), "ĐÂY")
        XCTAssertEqual(compose("Ddaay"), "Đây")
        XCTAssertEqual(compose("ddAAy"), "đÂy")
        XCTAssertEqual(compose("HOAS"), "HÓA")
        XCTAssertEqual(compose("Tieengs"), "Tiếng")
    }

    func testBackspaceDeletesWholeGlyph() {
        // Reported bug: "khoo" -> "khô"; one backspace must delete the whole "ô"
        // (giving "kh"), not just undo the circumflex (which gave "kho").
        var e = TelexEngine()
        for ch in "khoo" { _ = e.feed(ch) }
        XCTAssertEqual(e.composed, "khô")
        _ = e.backspace()
        XCTAssertEqual(e.composed, "kh")

        // "aa" -> "â"; backspace deletes the whole composed glyph -> ""
        var a = TelexEngine()
        _ = a.feed("a"); _ = a.feed("a")
        XCTAssertEqual(a.composed, "â")
        _ = a.backspace()
        XCTAssertEqual(a.composed, "")

        // "vieejt" -> "việt"; delete 't' -> "việ"; delete whole "ệ" -> "vi"
        var f = TelexEngine()
        for ch in "vieejt" { _ = f.feed(ch) }
        XCTAssertEqual(f.composed, "việt")
        _ = f.backspace()
        XCTAssertEqual(f.composed, "việ")
        _ = f.backspace()
        XCTAssertEqual(f.composed, "vi")

        // "dduwowngf" -> "đường"; delete 'g' -> "đườn"; 'n' -> "đườ"; whole "ờ" -> "đư".
        var d = TelexEngine()
        for ch in "dduwowngf" { _ = d.feed(ch) }
        XCTAssertEqual(d.composed, "đường")
        _ = d.backspace()               // delete 'g'
        XCTAssertEqual(d.composed, "đườn")
        _ = d.backspace()               // delete 'n'
        XCTAssertEqual(d.composed, "đườ")
        _ = d.backspace()               // delete whole "ờ"
        XCTAssertEqual(d.composed, "đư")

        // backspace on empty is passthrough
        var g = TelexEngine()
        XCTAssertEqual(g.backspace(), .passthrough)
    }

    // Data-loss guard: past capacity (32 raw keys) the word is "overflowed" — its
    // 32-char engine view is a stale prefix of the longer on-screen text. The engine
    // must stop composing so it never diffs the short view against the screen and
    // drops the overflow: overflow keys pass through, backspace passes through, and
    // the boundary neither auto-restores nor rewrites (would scramble/delete text).
    func testOverflowStopsComposing() {
        // A word with an early transform ("nguyeenx"→"nguyễn") plus filler past 32.
        let word = "nguyeenx" + String(repeating: "a", count: 32)   // 40 keys
        var e = TelexEngine()
        var pastCapAllPassthrough = true
        for (i, ch) in word.enumerated() {
            let action = e.feed(ch)
            // (a) every key from the 33rd on passes through (never recorded/diffed).
            if i >= 32, action != .passthrough { pastCapAllPassthrough = false }
        }
        XCTAssertTrue(pastCapAllPassthrough, "keys past capacity must pass through")

        // (b) backspace after overflow passes through (app deletes natively).
        XCTAssertEqual(e.backspace(), .passthrough)

        // (c) boundary must not restore/rewrite: commitBoundary -> .none,
        // commitText -> composed (never rawKeystrokes).
        var b = TelexEngine()
        for ch in word { _ = b.feed(ch) }
        XCTAssertEqual(b.commitBoundary(autoRestore: true), .none)

        var t = TelexEngine()
        for ch in word { _ = t.feed(ch) }
        let composedBefore = t.composed          // commitText resets, so snapshot first
        let rawBefore = t.rawKeystrokes
        let committed = t.commitText(autoRestore: true)
        XCTAssertEqual(committed, composedBefore)
        XCTAssertNotEqual(committed, rawBefore)
    }

    // No regression: a normal (non-overflowed) invalid word still auto-restores.
    func testOverflowDoesNotBreakNormalRestore() {
        var e = TelexEngine()
        for ch in "retore" { _ = e.feed(ch) }
        XCTAssertEqual(e.composed, "retỏe")
        XCTAssertEqual(e.commitText(autoRestore: true), "retore")
    }

    func testActionShapes() {
        var e = TelexEngine()
        // plain consonant -> passthrough (system inserts)
        XCTAssertEqual(e.feed("b"), .passthrough)
        // vowel -> passthrough
        XCTAssertEqual(e.feed("a"), .passthrough)
        // second 'a' forms â -> replace last 1 char
        XCTAssertEqual(e.feed("a"), .replace(backspaces: 1, insert: "â"))
        // tone key modifies in place
        XCTAssertEqual(e.feed("s"), .replace(backspaces: 1, insert: "ấ"))
    }

    func testRawKeystrokesPreserved() {
        var e = TelexEngine()
        for ch in "nguwowif" { _ = e.feed(ch) }
        XCTAssertEqual(e.composed, "người")
        XCTAssertEqual(e.rawKeystrokes, "nguwowif")
    }
}
