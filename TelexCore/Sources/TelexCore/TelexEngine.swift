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

/// A boundary that restored a word to its raw keys although its Vietnamese composition
/// was a real syllable ("hí" → "his", "NÁ" → "NAS"). An immediate ⌫ may put `vietnamese`
/// back in place of `restored` (both exactly as the screen shows / showed them; the
/// boundary character the caller inserted follows `restored`). Like macOS autocorrect undo.
public struct RestoreUndo: Equatable {
    public let restored: String
    public let vietnamese: String
    public init(restored: String, vietnamese: String) {
        self.restored = restored
        self.vietnamese = vietnamese
    }
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

    /// EAGER English restore (18/10/2026, maintainer-approved). Only acts together with
    /// `liveSpellCheck`: at the ONE moment the word freezes, if the raw keys so far are
    /// exactly the freeze prefix of a known English word (`EnglishFreezePrefixes`,
    /// generated from enlexicon.bin), the whole word goes back to its raw keys right
    /// away — "goog" instead of "gôg", the rest of "google" types plainly. A raw prefix
    /// NOT in the table keeps the historical behaviour (marks stay until the boundary),
    /// which protects Vietnamese typos and teencode. The check runs once per word, never
    /// per key. Engine default OFF (library contract / golden); callers set it to their
    /// EFFECTIVE auto-restore setting — with auto-restore off the boundary keeps "gôgle",
    /// so restoring early would change the committed text. Preserved across `reset()`.
    public var eagerEnglishRestore = false

    /// Simple Telex. When true, a STANDALONE `w` (no adjacent
    /// a/o/u to horn/breve) never becomes `ư` — it stays a literal `w`, so `ư` must be
    /// typed `uw` ("cw"→cw, not cư; "cuw"→cư). `w` still breves/horns an adjacent vowel
    /// (aw→ă, ow→ơ, uw→ư). (Brackets are already literal in
    /// this engine, the other Simple-Telex difference.) Preserved across `reset()`.
    public var simpleTelex = false

    /// TEENCODE spelling (issue #94, 25/09/2026): informal onsets w→qu ("wá"),
    /// z/dz→d ("zô", "dzị"), k before a/o/u ("kó"), and the informal rimes "ie"
    /// (bíe), "ik" (thík), "ưk" (ừk), "òy"/"-òy" (gòy) and the word "đou". ON = accepted
    /// as Vietnamese; OFF = standard spelling only, so English words stop composing
    /// through them (Simple Telex: was→wá, war→wả). Engine default ON keeps the
    /// library contract and the suite stable; the APP defaults it OFF (maintainer).
    /// Preserved across `reset()`.
    public var teencode = true

    /// Quick Telex ("gõ nhanh"): a doubled onset consonant expands to its digraph —
    /// cc→ch, gg→gi, kk→kh, nn→ng, qq→qu, pp→ph, tt→th. Word-INITIAL pair only
    /// (these are onset digraphs; mid-word doubles like "occur" stay literal).
    /// Default OFF. Preserved across `reset()`; the caller sets it from settings.
    public var quickTelex = false

    /// Bracket vowels (UniKey/macOS-Simple-Telex habit, EXPERIMENTAL, default OFF):
    /// `[` types ơ, `]` types ư, `{`/`}` their uppercase. One keystroke each, so ⌫
    /// removes the whole vowel and auto-restore hands back the BRACKET the user
    /// pressed ("th[" → "thơ", restored → "th[") — the raw buffer keeps the bracket
    /// byte and only the parse translates it, so nothing downstream needs to know.
    ///
    /// A 15-year touch-typing habit for UniKey users (Facebook request 2026-08-14), and
    /// opt-in for a reason: with it on, `[`/`]` are word KEYS, so they no longer end a
    /// word — anyone typing `arr[i]` in code wants this off, which is the default.
    /// Preserved across `reset()`; the caller sets it from settings.
    public var bracketVowels = false

    /// VNI input method. When true the engine parses VNI, not Telex: LETTERS are
    /// always literal, and DIGITS carry the diacritics — 1-5 = sắc/huyền/hỏi/ngã/nặng,
    /// 6 = â/ê/ô (circumflex), 7 = ơ/ư (horn), 8 = ă (breve), 9 = đ, 0 = clear tone.
    /// A digit is a diacritic only when it can apply (a tone needs a vowel; a mark needs
    /// its target letter; 0 needs a tone) — otherwise it types literally ("mp3", "a4"
    /// paper size stays…"a4" only via spell-check freeze; a lone "a4" → "ã", the same
    /// inherent VNI ambiguity every VNI IME has). Preserved across `reset()`.
    public var vniMode = false

    /// Context-based decision (EXPERIMENTAL, default OFF). When the previous committed
    /// word was English, an AMBIGUOUS current word — one whose composition is a valid
    /// Vietnamese syllable but whose raw keys also spell an English word — is restored to
    /// English instead of kept Vietnamese: "he is" → "he is" (not "he í"). After a valid
    /// Vietnamese or undetermined word, the ambiguous word stays Vietnamese: "sao í".
    /// Uses `EnglishContextWords`. Preserved across `reset()`; cleared by `resetContext()`.
    public var contextualEnglish = false

    /// Whether the PREVIOUS committed word was classified English (for `contextualEnglish`).
    /// Cross-word state: survives `reset()` (which runs per word), updated at each commit,
    /// wiped by `resetContext()` (caller: focus / app switch). Read-only to callers/tests.
    /// Since 11/10/2026 this means "an English RUN is open": set by an English FUNCTION
    /// word, or by the SECOND English word in a row — never by one content word alone
    /// (see `EnglishContextWords.functionWords`).
    public private(set) var previousWordEnglish = false

    /// The previous committed word was a lone English CONTENT word ("suggestion",
    /// "commit") while no run was open: one more English word opens the run, a
    /// Vietnamese word clears it. Same lifetime as `previousWordEnglish`.
    private var englishCandidate = false

    /// Which `EnglishContextWords.predecessorGates` rules the previous committed word
    /// satisfies (bit i ⇔ rule i): "has" sets the bit that lets "been" restore.
    private var previousGateBits: UInt8 = 0

    /// Force-restore top-frequency English words that collide with valid
    /// Vietnamese syllables ("his"→hí) at the word boundary. Default ON.
    /// gen-english turns this OFF to regenerate the table against the
    /// validator-only behavior (the table must not observe itself).
    public var englishWordRestore = true
    /// Khi một từ VỪA là tiếng Anh trong bảng collision VỪA gõ ra âm tiết Việt hợp lệ
    /// (last/lát, list/lít, his/hí): true → giữ tiếng Việt, false → khôi phục tiếng
    /// Anh (hành vi cũ). Chỉ gate bảng collision ĐỨNG MỘT MÌNH: trong mạch tiếng Anh
    /// (contextualEnglish + từ trước là English) bảng vẫn khôi phục ("the list"),
    /// âm tiết không hợp lệ vẫn về raw, cử chỉ gõ đúp không đổi. Engine default
    /// false để golden cũ nguyên; AppState default TRUE (maintainer 12/09/2026).
    public var collisionPrefersVietnamese = false

    /// RETROACTIVE English correction (EXPERIMENTAL, default OFF). When an English run
    /// becomes certain (two consecutive words committed as English, the second one just
    /// now), up to 3 words right before it that were composed as Vietnamese only because
    /// their raw keys collide ("His"→Hí, "car"→cả, "is"→í) are rewritten to their raw keys
    /// — if they read as plausible English with the run ("Hí cả í very fast" → "His car is
    /// very fast"; "Mai cả team họp" never changes). Decision: `RetroEnglish.plan`.
    /// DEPENDS ON `contextualEnglish` ("Quyết định theo ngữ cảnh"): inert unless that is on
    /// (and in VNI). Off = zero behaviour change; the only cost is one Bool test per commit.
    /// The caller must report every boundary character it inserts
    /// (`noteBoundaryCharacter`) and fetch the edit right after a commit
    /// (`takeRetroCorrection`). Preserved across `reset()`.
    public var retroactiveEnglish = false

    /// `retroactiveEnglish` is actually in effect (needs contextual English, Telex only).
    public var retroactiveEnglishActive: Bool { retroactiveEnglish && contextualEnglish && !vniMode }

    /// TỪ TRÙNG THEO TẦN SUẤT + LẬT LẠI (EXPERIMENTAL, mặc định TẮT — Cài đặt → Thử nghiệm).
    /// Một từ mà phím gõ vừa là từ tiếng Anh vừa ra âm tiết Việt hợp lệ, ở ĐẦU cụm (không có từ
    /// Việt ngay trước, chưa có mạch tiếng Anh): chọn tiếng Anh khi âm tiết Việt HIẾM (tần suất <
    /// `frequencyVietnameseFloor`) và từ Anh phổ biến hơn ≥ ~10 lần (`frequencyMargin` byte trên
    /// thang log chung — `EnglishFrequency`): "His car is fast." đúng ngay từ "His".
    /// Từ kế tiếp cho thấy câu là tiếng Việt ⇒ LẬT LẠI từ trước về chữ Việt bằng đúng đường sửa
    /// ngược (`RetroCorrection.flipBack`, integrator TỰ ÁP kể cả khi sửa ngược chỉ mời): từ kế
    /// lặp lại y phím (láy / tiếng cười "hí hí", "Hí Hí") hoặc cùng từ trước thành cặp âm tiết
    /// Việt hay đi liền (`EnglishFrequency` PAIRS: "hí hửng", "lát nữa", "thí sinh"). Cần sửa ngược đang chạy (`retroactiveEnglishActive`: integrator báo
    /// ký tự ranh giới và nhận phép sửa) — không thì trơ. Tắt = không đổi gì; chi phí khi tắt: một
    /// phép thử Bool ở mỗi lần chốt từ (RetroBoundaryPerfTests).
    public var englishByFrequency = false

    /// `englishByFrequency` is actually in effect.
    public var englishByFrequencyActive: Bool { englishByFrequency && retroactiveEnglishActive }

    /// Tự thêm dấu mũ (issue #166): khi từ ĐÃ có phím thanh mà vần không mũ không tồn tại trong
    /// tiếng Việt, còn vần có mũ thì hợp lệ, hiện luôn dấu mũ — "vietj"/"viejt" → việt,
    /// "nguyenx" → nguyễn, "benhj" → bệnh, "keuf" → kều, "hues" → huế, "luanj" → luận,
    /// "xuats" → xuất. Bốn nhóm vần: iê/yê/uyê, ê trước nh/ch/u, uê, uâ (sau "qu" thì vần
    /// không mũ là từ thật — quan, quát, què — nên giữ nguyên). Chỉ là một bước ở khâu HIỂN THỊ
    /// (`render`), trạng thái parse không đổi: gõ tiếp "ee"/"aa", xoá, huỷ thanh vẫn y như cũ.
    /// Tắt (mặc định) = không đổi gì; chi phí khi tắt: một phép thử Bool mỗi lần render.
    public var autoCircumflex = false

    /// Ngưỡng luật tần suất (chỉnh trên mô phỏng gõ câu trộn, tập val — docs/REGRESSION.md).
    static let frequencyVietnameseFloor: UInt8 = 140
    static let frequencyMargin: UInt8 = 45

    /// The last committed word in the current phrase was Vietnamese (read only by the
    /// frequency rule: a colliding word right after Vietnamese stays Vietnamese — "sao í",
    /// "cho con bú"). Sentence punctuation / newline / `resetContext` clear it.
    private var previousWordVietnamese = false

    // Retroactive-English session state: the last committed words (oldest first, at most
    // RetroEnglish.historyCapacity), spaces reported since the last commit, and the edit
    // computed by the last commit until the caller takes it (or anything else happens).
    private var retroHistory: [RetroWord] = []
    private var retroGap = 0
    private var retroPending: RetroCorrection?
    private var retroPendingPicks: [Int] = []

    static let capacity = 32

    // Raw keystrokes that make up the current word (ascii, case preserved).
    private var raw: [UInt8]
    private var rawCount = 0

    // Set once `rawCount` hits capacity: the word is longer than the engine can
    // hold, so its 32-char view is a stale prefix of what the caller has on screen.
    // While overflowed the word is treated as non-composable — backspace passes
    // through (the app deletes natively) and the boundary neither auto-restores nor
    // rewrites — so the engine never diffs its short view against the longer screen
    // and silently drops the overflow characters. Reset per word.
    private var overflowed = false

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
    // Distance (in raw keys) from the cancelled tone key to the key that cancelled it:
    // 1 = the classic adjacent double ("iss", "aff"), >1 = the cancel reached back over
    // letters, which means the tone key it kills was itself an eaten letter
    // ("hosts"→hots, "asks"→aks). 0 = no tone cancel in this word.
    private var pToneCancelSpan = 0
    // Raw index of the last TONE-key cancel (ss/ff/rr/xx/jj, z, VNI 1-5/0), -1 if none.
    // A tone cancel means different things depending on WHERE it happened — at the end of
    // the word it's the literal-letter escape, mid-word it ate a letter. See
    // `shouldRestoreRaw`. Mark doublers (aa a, ww, dd d, VNI 6-9) never set it.
    private var pToneCancelAt = -1
    // A circumflex doubler (a/e/o) cancelled a hat it REACHED BACK to across letters (free
    // marking: "seem" → sêm, + e → "seme"), as opposed to the adjacent "eee" escape.
    // Read at the boundary only (`shouldRestoreRawBase`). Reset with the parse state.
    private var pMarkCancelReachedBack = false
    private var pProcessed = 0
    private var pFreeMarking = false    // settings snapshot the state was built with
    private var pSimpleTelex = false
    private var pQuickTelex = false
    private var pVniMode = false
    private var pBracketVowels = false
    // Snapshot of `liveSpellCheck` the freeze state was computed with. Unlike the
    // other parse settings this one does not change how a single key folds — it
    // decides WHERE the word freezes (`disabledAtCount`), which is a function of the
    // whole word, so a mid-word flip has to replay it (see feed()).
    private var pLiveSpellCheck = false

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

    // Snapshots of `pToneCancelAt` / `pToneCancelSpan`, taken with `markCancelled`.
    private var toneCancelAt = -1
    private var toneCancelSpan = 0

    // Rebuild directive: fold every tone key back to its literal letter. Set ONLY
    // for the second pass of a frozen-word rebuild when a tone is still PENDING
    // ("installer": the early s floated as sắc onto the post-freeze a). A CANCELLED
    // tone (ss/ff/…) must NOT fold — forward typing rendered the cancel ("ress" →
    // res), and a rebuild that resurrects both keys as literals ("ress") desyncs
    // the screen: ⌫ on "rese" showed "ress" (tester report 2026-07-24).
    private var pFoldTones = false

    // True while the CURRENT parse was built with that fold (a pending tone key was
    // turned back into its literal letter when live spell-check froze the word).
    // The boundary needs it: the fold wipes the tone, so a mark-doubler cancel that
    // left the tone floating ("cheese": chế + e → "chée", frozen → "chese") looks
    // like a clean deliberate escape ("gooogle") to composedHasDiacritic(). It is
    // not — the user never saw the literal s where it landed. Reset per word.
    private var tonesFolded = false

    // True when live spell-check froze a word that ALREADY carried Vietnamese letter
    // marks (đ ư ơ â ê ô ă) plus a pending tone (PR #133, stevedat): the composed word
    // stays exactly as displayed — tone included — and the breaking key (and every key
    // after it) is appended literally: "dduowcj"+"u" → "đượcu", not the half-folded
    // "đươcju". The freeze then starts AT the breaking key (`disabledAtCount` = its
    // index) and the tone is pinned to the letters before it (`pFreezeLetters`).
    // Words without letter marks still fold the tone back ("installer", "cart").
    // Decided once at the freeze (feed / recomputeFreeze). Reset per word.
    private var freezeKeepsTone = false

    // Parse state: letter count when the parse reached raw index `disabledAtCount`
    // (the first frozen key), -1 before that. Render caps tone placement here when
    // `freezeKeepsTone`, so the kept tone never floats onto the literal tail.
    private var pFreezeLetters = -1

    // Effective tone of the last render (after the stop-coda drop) — the composed
    // word's tone, used by the zero-alloc boundary validation.
    private var lastEffTone: Tone = .none

    // Lần render gần nhất có tự thêm dấu mũ (`autoCircumflex`). Đọc ở ranh giới từ.
    private var inferredCircumflex = false

    // True when a tone key (s f r x j, or z) was CONSUMED as a tone while typed
    // UPPERCASE. In a mixed-case word that is an English/code signal ("SaaS": the
    // trailing S applies sắc → "Sấ", a *valid* syllable that plain validation
    // would keep), so boundary auto-restore forces the raw keystrokes back. An
    // ALL-CAPS word is exempt — "VIEEJT"→VIỆT types tone keys uppercase
    // legitimately. Mark doublers (DDaay, AAn) are NOT counted: shift held across
    // a doubler is normal typing.
    private var upperToneKey = false

    // TRUE once feed() froze the word for an upper-case tone key (`disabledAtCount`
    // = 0, see `forceRestoreUpperTone`). The frozen rebuild parses every key as a
    // literal, so `upperToneKey` itself reads false afterwards — this remembers the
    // freeze reason: the elongation unfreeze must not lift it ("VieeJ"+tt stays
    // "VieeJtt"), and ⌫ recomputes it by replay ("VieeJt" ⌫ → "VieeJ", not "Việ").
    // Reset per word; recomputed by `recomputeFreeze`.
    private var upperToneFrozen = false

    // Raw index where an INITIALS suffix starts ("Phuwowng"+"TH" → PhươngTH, issue
    // #138), -1 = none. While set, the word is frozen there with the head's tone kept
    // (`disabledAtCount` = this, `freezeKeepsTone`) and the boundary keeps the
    // composition. See `applyInitialsSplit`. Reset per word; cleared by recomputeFreeze.
    private var initialsSplitAt = -1

    // MARK: Re-open snapshot (⌫ right after a word boundary — issue #40)
    //
    // The keystrokes of the word the LAST boundary committed, kept only while that
    // word is still exactly what the screen shows: the commit did not auto-restore
    // to raw and did not overflow, so `composed` is on screen character for
    // character. Deleting the boundary character then re-opens the word instead of
    // starting from nothing ("tháy" ␣ ⌫ a → "thấy"), which is what every other
    // Vietnamese IME does. Fixed buffers — the capture runs on the boundary hot
    // path and must not allocate.
    private var reopenRaw: [UInt8]
    private var reopenOut: [UInt32]
    private var reopenRawCount = 0
    private var reopenOutCount = 0
    // `previousWordEnglish` as it was BEFORE the commit folded this word in. Re-opening
    // puts the word back into the buffer, so the context it composes against must be
    // the one from the word BEFORE it, not the one it just produced.
    private var reopenPrevEnglish = false
    private var reopenCandidate = false
    private var reopenGateBits: UInt8 = 0

    // MARK: Undo of a boundary restore-to-English (⌫ right after the commit)
    //
    // Set by the commit that restored a word to its raw keys while its Vietnamese
    // composition was a real alternative (valid syllable): "his"→"hí" restored to "his",
    // "NAS"→"NÁ" restored to "NAS". The caller takes it right after the commit
    // (`takeRestoreUndo`) and arms its own ⌫-undo with it; any other engine call drops it.
    private var restoreUndo: RestoreUndo?

    // MARK: Glued separators (".", "/", "_", digits right before a word)
    //
    // Fed by `noteBoundaryCharacter` (callers report every boundary character they insert).
    // `lastWordKind`: how the last committed word reads for a following "." / "/":
    // 0 = unknown (no word yet / text changed), 1 = Vietnamese or capitalized (TP.Hồ,
    // và/hoặc, anh/chị), 2 = anything else (code-like: os, file, user, src).
    // `noteSinceWord`: a boundary character was already reported after that word, so the
    // next one is not glued to it. `pendingGlue` is what the NEXT word starts glued to, and
    // `wordGlue` the snapshot the current word took at its first key: 0 none, 1 separator,
    // 2 digit. Cross-word state (survives resetWord), wiped by reset().
    private var lastWordKind: UInt8 = 0
    private var noteSinceWord = true
    private var pendingGlue: UInt8 = 0
    private var wordGlue: UInt8 = 0

    public init() {
        raw = [UInt8](repeating: 0, count: Self.capacity)
        reopenRaw = [UInt8](repeating: 0, count: Self.capacity)
        reopenOut = [UInt32](repeating: 0, count: Self.capacity)
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

    /// RE-EDIT an already committed word: rebuild the engine state from TEXT that is
    /// already on screen, so the next keystroke can add a diacritic to it ("toan" + `s`
    /// → "toán"). Returns true only when the word round-trips EXACTLY.
    ///
    /// How: the word is turned back into the keystrokes that would have produced it
    /// (detone → mark expansion → trailing tone key, or the VNI digits in VNI mode) and
    /// those keys are replayed through `feed`. Everything downstream — tone placement,
    /// ươ propagation, ⌫ mapping, boundary restore — therefore behaves exactly as if the
    /// user had just typed the word, with no second code path to keep in sync.
    ///
    /// The round-trip check is the SAFETY: if replaying the keys does not reproduce the
    /// word character-for-character, the engine is reset and false is returned, so the
    /// caller must leave the text alone. That is what refuses
    ///   • non-Vietnamese text ("google" → keys "google" → composes "gôgle" ✗),
    ///   • a tone-placement style the current settings spell differently
    ///     ("hòa" on screen while `modernTone` produces "hoà" ✗),
    ///   • anything with a character no keystroke can produce (digits, symbols, é/ñ…),
    ///   • DECOMPOSED (NFD) text ("ta\u{302}n"): the engine always composes NFC, and
    ///     Swift's `String ==` / Character hashing are canonical-equivalence, so a plain
    ///     `==` would ACCEPT it — then every later edit's ⌫ count (derived from the NFC
    ///     buffer) would be short of what is really on screen, mangling the word.
    ///     Hence the scalar-exact comparison below, not `==`.
    /// Refusing costs the user nothing (the word simply isn't re-editable); guessing
    /// would rewrite text they never asked to change.
    public mutating func seed(_ word: String) -> Bool {
        reset()
        guard !word.isEmpty, word.count <= Self.capacity / 2 else { return false }
        guard let keys = Self.seedKeystrokes(for: word, vni: vniMode) else { return false }
        guard keys.count <= Self.capacity else { reset(); return false }
        for ch in keys { _ = feed(ch) }
        guard composed.unicodeScalars.elementsEqual(word.unicodeScalars) else {
            reset(); return false
        }
        return true
    }

    /// Keystrokes that would compose `word`, or nil if some character can't be typed.
    /// Telex: marks expand (â→aa, ư→uw, đ→dd) and the tone key goes last, the way the
    /// generator in the typing-matrix tests does it. VNI: letters stay literal, marks
    /// are digits (6 circumflex, 7 horn, 8 breve, 9 đ) and tones are 1-5, also last.
    private static func seedKeystrokes(for word: String, vni: Bool) -> String? {
        var out = ""
        var toneKey: Character?
        for ch in word {
            let isUpper = ch.isUppercase
            let lower = Character(ch.lowercased())
            // Strip the tone first: "ấ" → ("â", acute).
            var toneless = lower
            if lower.unicodeScalars.count == 1, let sc = lower.unicodeScalars.first,
               let (base, t) = Tables.detoneTable[sc.value] {
                if t != .none {
                    guard toneKey == nil else { return nil }   // two tones in one syllable
                    toneKey = vni ? Self.vniToneKey(t) : Self.telexToneKey(t)
                }
                toneless = Character(Unicode.Scalar(base)!)
            }
            let expanded: String
            if let e = (vni ? Self.vniMarkExpansion : Self.telexMarkExpansion)[toneless] {
                expanded = e
            } else {
                guard toneless.isASCII, toneless.isLetter else { return nil }
                expanded = String(toneless)
            }
            // A mark digit is never uppercased; a mark LETTER follows the letter's case.
            out += isUpper ? (vni ? Self.upperFirst(expanded) : expanded.uppercased()) : expanded
        }
        if let toneKey { out.append(toneKey) }
        return out
    }

    private static let telexMarkExpansion: [Character: String] = [
        "â": "aa", "ă": "aw", "ê": "ee", "ô": "oo", "ơ": "ow", "ư": "uw", "đ": "dd",
    ]
    private static let vniMarkExpansion: [Character: String] = [
        "â": "a6", "ê": "e6", "ô": "o6", "ơ": "o7", "ư": "u7", "ă": "a8", "đ": "d9",
    ]
    private static func telexToneKey(_ t: Tone) -> Character? {
        switch t {
        case .acute: return "s"; case .grave: return "f"; case .hook: return "r"
        case .tilde: return "x"; case .dot: return "j"; case .none: return nil
        }
    }
    private static func vniToneKey(_ t: Tone) -> Character? {
        switch t {
        case .acute: return "1"; case .grave: return "2"; case .hook: return "3"
        case .tilde: return "4"; case .dot: return "5"; case .none: return nil
        }
    }
    /// "a6" → "A6" (only the LETTER takes the case; the mark digit must stay a digit).
    private static func upperFirst(_ s: String) -> String {
        guard let f = s.first else { return s }
        return String(f).uppercased() + String(s.dropFirst())
    }

    /// Feed one typed character. Only ascii letters compose; other characters
    /// should be routed through `commitBoundary` by the caller.
    public mutating func feed(_ ch: Character) -> TelexAction {
        if restoreUndo != nil { restoreUndo = nil }
        guard let ascii = ch.asciiValue,
              isLetter(ascii) || (vniMode && isDigit(ascii))
                || (bracketVowels && Self.bracketVowel(ascii) != nil) else {
            return .passthrough
        }
        guard rawCount < Self.capacity else { overflowed = true; return .passthrough }

        // First key of a NEW word: whatever the last boundary committed is now two
        // edits away from the caret, so a later ⌫ must not re-open it (typing then
        // backspacing all the way back would otherwise resurrect the wrong word).
        if rawCount == 0 {
            reopenRawCount = 0; reopenOutCount = 0
            if retroPending != nil { retroPending = nil }
            wordGlue = pendingGlue
            pendingGlue = 0
        }

        raw[rawCount] = ascii
        rawCount += 1

        // Fold the new key into the incremental parse state — or rebuild it when a
        // setting that changes parse behavior flipped mid-word (rare; the controller
        // re-applies settings every key, they just normally don't change mid-word).
        if pLiveSpellCheck != liveSpellCheck {
            // liveSpellCheck flipped mid-word. The freeze point depends on the WHOLE
            // word, not on this key, so recompute it with the same replay ⌫ uses:
            // turning the flag ON must freeze a word that already went invalid
            // ("googl" + 'e' → "gôgle", frozen from the 4th key, not from the 6th),
            // turning it OFF must lift a stale freeze instead of leaving the tail
            // literal until the boundary.
            recomputeFreeze()
            rebuildFrozenAware()
        } else if pProcessed != rawCount - 1
            || pFreeMarking != freeMarking || pSimpleTelex != simpleTelex
            || pQuickTelex != quickTelex || pVniMode != vniMode
            || pBracketVowels != bracketVowels {
            rebuildFrozenAware()
        } else {
            parseStep(rawCount - 1)
            pProcessed = rawCount
        }

        var newCount = render()
        markCancelled = pCancelled
        toneCancelAt = pToneCancelAt
        toneCancelSpan = pToneCancelSpan

        // Uppercase tone/mark key in a MIXED-case word ("OmS", "SaaS", "JavaScript")
        // → this is English/code, not Vietnamese. Freeze the WHOLE word to its raw
        // keystrokes IMMEDIATELY (not just at the boundary) so the tone never even
        // flashes on screen ("OmS" stays "OmS", never briefly "Óm"). Rebuild with
        // transforms disabled from the first key, then re-render.
        if disabledAtCount == Int.max, forceRestoreUpperTone {
            disabledAtCount = 0
            upperToneFrozen = true
            rebuildParseState()
            tonesFolded = false
            newCount = render()
            markCancelled = pCancelled
        toneCancelAt = pToneCancelAt
        toneCancelSpan = pToneCancelSpan
        }

        // Live spell-check: once the word can no longer be valid Vietnamese, freeze
        // transforms from the NEXT key on. Letter MARKS applied so far stay
        // ("gôgle" — historical, cosmetic until boundary restore), but a pending
        // TONE is CANCELLED: the word cannot be Vietnamese, so a floating tone has
        // no meaning and would otherwise land on whatever vowel follows in the
        // frozen tail — "installer" rendered "intáller" (the s applied as sắc onto
        // the post-freeze a; user report via its ⌫ variant "intálle").
        // TEENCODE elongation escape: a word that is "valid syllable + a run of one
        // repeated letter" ("hôngggg", "cóaaaa", "đẹpppp") is not a foreign word — it is
        // a chat spelling of a real syllable, so the freeze must NOT fire (it would fold
        // the tone back to a literal key and show raw "cosaaaa"/"ddepjpppp").
        if liveSpellCheck, disabledAtCount == Int.max, !prefixIsValid(newCount),
           elongationHeadCount(newCount, tone: pTone) <= 0 {
            disabledAtCount = rawCount
            freezeKeepsTone = false
            if eagerRestoreApplies(newCount) {
                // EAGER English restore: freeze from the FIRST key, i.e. the whole word
                // back to raw ("gôg" → "goog"). Same rebuild the upper-tone freeze uses;
                // a pending tone cannot float either (every key is literal now).
                disabledAtCount = 0
                rebuildParseState()
                tonesFolded = false
                newCount = render()
                markCancelled = pCancelled
                toneCancelAt = pToneCancelAt
                toneCancelSpan = pToneCancelSpan
            } else if pTone != .none, prefixKeepsTone(rawCount - 1) {
                // The word as displayed BEFORE this key already carries letter marks
                // (đ ư ơ â ê ô ă) and a visible tone: it is a Vietnamese word the user
                // finished, not an English word half-converted — keep it exactly as
                // shown, tone included, and type this key (and the rest) literally:
                // "dduowcj"+"u" → "đượcu" (PR #133), not "đươcju".
                disabledAtCount = rawCount - 1
                freezeKeepsTone = true
                rebuildParseState()
                tonesFolded = false
                newCount = render()
                markCancelled = pCancelled
                toneCancelAt = pToneCancelAt
                toneCancelSpan = pToneCancelSpan
            } else if pTone != .none {
                // Rebuild with pFoldTones: parseStep folds every TONE key back
                // to its literal letter (see the tone branch), so the s in
                // "installer" comes back as 's' instead of floating as sắc.
                pFoldTones = true
                rebuildParseState()
                pFoldTones = false
                tonesFolded = true
                newCount = render()
                // The fold rewrote the cancel bookkeeping (a tone key that used to
                // float is now a literal letter), so the snapshots taken before the
                // freeze are stale — shouldRestoreRaw() would decide keep-vs-restore
                // at the boundary on pre-freeze data. Re-take them, exactly like the
                // upper-tone freeze above and ⌫ already do.
                markCancelled = pCancelled
                toneCancelAt = pToneCancelAt
                toneCancelSpan = pToneCancelSpan
            }
        }

        // Eager English restore, deferred: the word froze BEFORE the table's minimum
        // length ("wi"+n → "ưin" for "windows", "awe" → "ăe" for "awesome"), so the
        // decision waits for the 4th key — still one table lookup per word.
        if eagerEnglishRestore, disabledAtCount != Int.max, disabledAtCount > 0,
           disabledAtCount < EnglishFreezePrefixes.minLength,
           rawCount == EnglishFreezePrefixes.minLength, eagerRestoreApplies(newCount) {
            disabledAtCount = 0
            rebuildParseState()
            tonesFolded = false
            newCount = render()
            markCancelled = pCancelled
            toneCancelAt = pToneCancelAt
            toneCancelSpan = pToneCancelSpan
        }

        // Elongation UNFREEZE: the FIRST extra character can't be told apart from a
        // typo, so the word legitimately freezes there ("quafa" after "quàa" — one
        // stray 'a' is not yet an elongation). The moment the repeat arrives the shape
        // is unambiguous, so re-evaluate the freeze from scratch and lift it, which
        // re-renders the tone in ONE keystroke ("quàaa"). Gated on "frozen AND this key
        // repeats the previous one", so it never runs on ordinary typing.
        if liveSpellCheck, disabledAtCount != Int.max, !upperToneFrozen,
           rawCount >= 2, raw[rawCount - 1] == raw[rawCount - 2] {
            recomputeFreeze()
            rebuildFrozenAware()
            newCount = render()
            markCancelled = pCancelled
            toneCancelAt = pToneCancelAt
            toneCancelSpan = pToneCancelSpan
        }

        // Initials suffix ("PhuwowngTH" → PhươngTH, issue #138): decided LAST so it
        // overrides whatever freeze the keys above settled on, and lifted again the
        // moment the shape breaks ("PhươngTH" + a). Cheap exit on ordinary keys.
        if applyInitialsSplit() {
            newCount = render()
            markCancelled = pCancelled
            toneCancelAt = pToneCancelAt
            toneCancelSpan = pToneCancelSpan
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
        if restoreUndo != nil { restoreUndo = nil }
        guard rawCount > 0 else {
            // The app deletes committed text: the retro history no longer matches the screen.
            if !retroHistory.isEmpty || retroPending != nil { retroClear() }
            return .passthrough
        }
        // Overflowed: the engine's 32-char view is a stale prefix of the screen, so
        // any rebuild/diff would rewrite the whole range with the short composition
        // and drop the overflow. Let the app delete the last char natively instead.
        if overflowed { return .passthrough }

        // Provenance must reflect what the user SEES — i.e. the CURRENT freeze
        // state. (It briefly ran unfrozen "for historical semantics", which mis-
        // deleted on frozen words: unfrozen "installer" consumes the trailing r as
        // a hỏi tone, so "last displayed letter" pointed at the e and ⌫ produced
        // "installr".)
        rebuildFrozenAware()
        _ = render()                             // maps tone-key provenance

        if pCount == 0 {
            // Safety net, UNREACHABLE by construction (uncovered in coverage runs
            // and that's fine): pCount == 0 with rawCount > 0 would need every raw
            // key consumed as a tone (rawLetter == -1), but a tone key is only
            // consumed when a vowel LETTER precedes it — so some key always maps to
            // a letter. Kept in case a future parse rule breaks that invariant.
            rawCount -= 1                        // nothing on screen -> drop one key
        } else {
            let last = pCount - 1
            var w = 0
            for r in 0..<rawCount where rawLetter[r] != last {
                raw[w] = raw[r]; w += 1
            }
            rawCount = w
        }

        // Re-freeze exactly as forward typing would have computed it over the
        // SHORTENED word. Lifting the freeze permanently re-applied transforms
        // retroactively: frozen "installer" ⌫ became "intálle" once free marking
        // could reach the 'a'. The replay is bounded (≤32 keys, parseStep is ~ns)
        // and runs only on ⌫.
        recomputeFreeze()
        rebuildFrozenAware()
        _ = applyInitialsSplit()                 // "LinhPTTx" ⌫ → LinhPTT split again
        let newCount = render()
        markCancelled = pCancelled
        toneCancelAt = pToneCancelAt
        toneCancelSpan = pToneCancelSpan
        let action = diff(newCount)
        copyOut(newCount)
        return action
    }

    /// A standalone run of three or more `w` keys is literal `www` text, regardless
    /// of the general auto-restore preference.
    private func needsStandaloneWRunRestore() -> Bool {
        guard rawCount >= 3, compositionDiffersFromRaw() else { return false }
        for i in 0..<rawCount where raw[i] | 0x20 != UInt8(ascii: "w") { return false }
        return true
    }

    /// Word boundary reached. Optionally auto-restore the raw keystrokes when the
    /// composed word is not a valid Vietnamese syllable. Resets the engine.
    /// The caller inserts the boundary character itself afterwards.
    /// `boundary` = the character that ends the word, when the caller knows it. Only the
    /// apostrophe matters today: an English contraction stem right before it ("doesn",
    /// "isn", "there") comes back as typed — see `isContractionStemBeforeApostrophe`.
    /// nil (the default) = unknown, exactly the old behaviour.
    public mutating func commitBoundary(autoRestore: Bool, boundary: Character? = nil) -> TelexAction {
        defer { resetWord() }
        restoreUndo = nil
        guard rawCount > 0 else { reopenRawCount = 0; reopenOutCount = 0; return .none }
        // Overflowed: the 32-char view is stale vs. the screen, so `outCount`
        // backspaces would hit the wrong characters. No restore, no rewrite.
        if overflowed {
            if contextualEnglish { clearEnglishContext() }   // undetermined → Vietnamese
            reopenRawCount = 0; reopenOutCount = 0                 // stale prefix: never re-open
            if !retroHistory.isEmpty || retroPending != nil { retroClear() }
            return .none
        }
        // Skip restore when the user cancelled a diacritic on purpose ("iss"→is).
        // Validation runs on letter classes + tone (no String); Strings are built
        // only when a restore actually happens. shouldRestoreRaw() reads the PREVIOUS
        // word's context; previousWordEnglish is refreshed for the NEXT word after.
        let wantsRestore = outCount > 0
            && (needsStandaloneWRunRestore() || (autoRestore && shouldRestoreRaw(before: boundary)))
        var action: TelexAction = .none
        if wantsRestore, compositionDiffersFromRaw() {
            // Strip the shared leading run, exactly like diff() does per keystroke:
            // an unchanged prefix (the "g" in "gôgle"→"google") must NOT be
            // deleted+retyped. Re-typing a still-correct leading char surfaces as a
            // duplicate ("ggoogle") when the editor offsets our deletion — Chrome's
            // omnibox inline-autocomplete absorbs one Shift+Left in .selection mode.
            let limit = min(rawCount, outCount)
            var lcp = 0
            while lcp < limit, UInt32(raw[lcp]) == out[lcp] { lcp += 1 }
            let backspaces = outCount - lcp
            var s = String.UnicodeScalarView()
            s.reserveCapacity(rawCount - lcp)
            for i in lcp..<rawCount { s.append(Unicode.Scalar(raw[i])) }
            action = .replace(backspaces: backspaces, insert: String(s))
        }
        // Teencode one-letter elongation ("daja" → "dạa", not the invalid "dậ"): only the
        // last character changes, so rewrite exactly that one.
        let elongate = !wantsRestore && outCount > 0 && isToneThenATail()
        if elongate { action = .replace(backspaces: 1, insert: elongatedTail()) }
        // The screen no longer shows `composed` (and no keystrokes re-compose "dạa"), so a
        // ⌫ on the boundary must not re-open it — same as a restored word. A restore that
        // changed nothing on screen (raw keys == composition: "hoc", "tien", "github")
        // leaves exactly `composed` there, so it keeps its snapshot.
        captureReopen(restored: (wantsRestore && compositionDiffersFromRaw()) || elongate)
        noteCommittedWord(restored: wantsRestore)
        if retroactiveEnglish || !retroHistory.isEmpty { retroRecord(restored: wantsRestore, elongated: elongate) }
        updateContext(restored: wantsRestore)
        return action
    }

    /// TEENCODE one-letter elongation "Dạa" (maintainer 18/10/2026). Telex reads the second
    /// `a` of "daja" as the aa-circumflex and shows "dậ" — but a bare "â" never ends a
    /// Vietnamese syllable (only ân/âng/âm/âp/ât/âc/âu/ây), and the key ORDER says what the
    /// user meant: the tone was already placed ("dạ") when the extra `a` came, i.e. the
    /// chat spelling "dạa" (= dạ), "màa", "hảa". At the boundary such a word commits as
    /// the base syllable with its tone + a literal `a`.
    /// Only when `teencode` is on (off = historical "dậ"), Telex only, no cancel, the last
    /// raw key is the `a` that made the â, every key between the target `a` and it was a
    /// TONE key, the â carries the word's tone, and the head ("dạ") is a valid syllable.
    /// Plain "daa" (no tone in between) is the ordinary way to type â and stays "dâ".
    /// "ă" is not covered: it only comes from `w`, which is no elongation of `a`.
    /// Boundary-only, NON-mutating, allocation-free.
    private func isToneThenATail() -> Bool {
        guard teencode, !vniMode, !markCancelled, !overflowed, pCount >= 2, rawCount >= 3,
              lastEffTone != .none else { return false }
        let last = pCount - 1
        guard letters[last].base == UInt8(ascii: "a"), letters[last].mark == .circumflex,
              lowercased(raw[rawCount - 1]) == UInt8(ascii: "a"),
              rawLetter[rawCount - 1] == last,
              outCount == pCount,
              out[outCount - 1] == Tables.applyTone(
                  Tables.markedScalar(base: UInt8(ascii: "a"), mark: .circumflex, upper: letters[last].upper),
                  lastEffTone) else { return false }
        // Walk back over the tone keys right before the final `a` (at least one), then the
        // target `a` itself must sit there.
        var r = rawCount - 2
        var tones = 0
        while r >= 0, isToneKey(r) { tones += 1; r -= 1 }
        guard tones > 0, r >= 0, lowercased(raw[r]) == UInt8(ascii: "a"), rawLetter[r] == last
        else { return false }
        return isValidHead(pCount, tone: lastEffTone, plainLast: true)
    }

    /// Raw key `r` was consumed as a deferred tone key (s f r x j).
    private func isToneKey(_ r: Int) -> Bool {
        switch lowercased(raw[r]) {
        case UInt8(ascii: "s"), UInt8(ascii: "f"), UInt8(ascii: "r"),
             UInt8(ascii: "x"), UInt8(ascii: "j"): break
        default: return false
        }
        for j in 0..<pToneKeyCount where toneKeys[j] == r { return true }
        return false
    }

    /// The rewritten last character(s) for `isToneThenATail`: "ậ" → "ạa" (case kept: the
    /// toned vowel takes the â's case, the extra letter the final key's case).
    private func elongatedTail() -> String {
        let last = pCount - 1
        let toned = Tables.applyTone(
            Tables.markedScalar(base: UInt8(ascii: "a"), mark: .none, upper: letters[last].upper), lastEffTone)
        var v = String.UnicodeScalarView()
        v.append(Unicode.Scalar(toned)!)
        v.append(Unicode.Scalar(raw[rawCount - 1]))
        return String(v)
    }

    /// `composed` with the elongation rewrite applied (commitText / peek).
    private func composedElongated() -> String {
        var s = String.UnicodeScalarView()
        for i in 0..<(outCount - 1) { s.append(Unicode.Scalar(out[i])!) }
        s.append(contentsOf: elongatedTail().unicodeScalars)
        return String(s)
    }

    /// Remember the just-committed word so a ⌫ on the boundary character can put it
    /// back (see `reopenLastCommit`). Only when the screen ends up showing `composed`:
    /// a restore-to-raw ("google") or a caller-side rewrite leaves other text there,
    /// and re-opening would desync the buffer from the screen. Allocation-free.
    private mutating func captureReopen(restored: Bool) {
        guard !restored, rawCount > 0 else { reopenRawCount = 0; reopenOutCount = 0; return }
        for i in 0..<rawCount { reopenRaw[i] = raw[i] }
        for i in 0..<outCount { reopenOut[i] = out[i] }
        reopenRawCount = rawCount
        reopenOutCount = outCount
        reopenPrevEnglish = previousWordEnglish
        reopenCandidate = englishCandidate
        reopenGateBits = previousGateBits
    }

    /// Discard the re-open snapshot: the boundary character the caller inserted after
    /// a commit is no longer the thing a ⌫ would delete (shortcut expansion, a
    /// caller-side rewrite, a dropped composition). Cheaper and clearer at the call
    /// site than a full `reset()`, which also throws away the live word.
    public mutating func forgetLastCommit() {
        reopenRawCount = 0
        reopenOutCount = 0
        restoreUndo = nil
        clearGlue()
        if !retroHistory.isEmpty || retroPending != nil { retroClear() }   // text changed under us
    }

    /// True while `reopenLastCommit()` has something to put back.
    public var canReopenLastCommit: Bool { rawCount == 0 && reopenRawCount > 0 }

    /// RE-OPEN the word the last boundary committed — the ⌫ counterpart of `seed`.
    /// The user typed a word, ended it, then deleted the boundary character; the word
    /// is still on screen and they expect to keep editing it ("tháy" ␣ ⌫ then `a` →
    /// "thấy", issue #40). Replays the remembered keystrokes so tone placement, ươ
    /// propagation, ⌫ mapping and the boundary decision all behave exactly as if the
    /// word had never been committed.
    ///
    /// Returns the composed word now in the buffer — which is byte-for-byte what the
    /// screen shows, so the caller can point its tracking window at it — or nil when
    /// there is nothing to re-open. Like `seed`, the replay is VERIFIED: if a setting
    /// changed since the commit and the word no longer composes the same, the engine
    /// resets and nil is returned rather than compose against text it cannot match.
    /// The snapshot is consumed either way — one ⌫ gets one chance.
    public mutating func reopenLastCommit() -> String? {
        guard canReopenLastCommit else { return nil }
        let n = reopenRawCount
        let expected = reopenOutCount
        let prevEnglish = reopenPrevEnglish
        let prevCandidate = reopenCandidate
        let prevGateBits = reopenGateBits
        reset()                                   // consume the snapshot before replaying
        previousWordEnglish = prevEnglish         // compose against the word BEFORE this one
        englishCandidate = prevCandidate
        previousGateBits = prevGateBits
        for i in 0..<n { _ = feed(Character(Unicode.Scalar(reopenRaw[i]))) }
        guard rawCount == n, outCount == expected else { reset(); return nil }
        for i in 0..<outCount where out[i] != reopenOut[i] { reset(); return nil }
        return composed
    }

    /// Boundary restore decision, shared by both commit paths.
    /// Order matters: the English-collision table wins over EVERYTHING, including
    /// a cancel — that is what restores "off"/"office"/"class" (their raw doubles
    /// are real English). After that, a deliberate double-key cancel normally KEEPS
    /// the composed text: the user pressed the extra key to undo an unwanted
    /// diacritic and may keep typing ("Deffault" keys → Default, field report
    /// 2026-07-22 — an earlier validity-based rule here restored the raw double-f).
    /// TWO exceptions, both meaning the cancel did NOT leave clean text:
    ///  1. the composition still carries a Vietnamese diacritic — free-marking reached
    ///     back BEFORE the cancel ("excess"→"êcs") → restore the raw keys; while
    ///     "iss"→"is", "messs"→"mess" (plain ascii after the cancel) are kept;
    ///  2. a TONE-key cancel that REACHED BACK over letters (the killed tone key was
    ///     typed keys earlier, so it is itself a letter the word lost): "hosts"→hots,
    ///     "asks"→aks → restore. An escape gesture is ALWAYS an adjacent double, so a
    ///     reach-back cancel is never one.
    /// Only then do the standard validity/exception rules decide.
    /// NON-mutating (scratch-free) so `peekCommitText` can share it verbatim.
    private func shouldRestoreRaw(before boundary: Character? = nil) -> Bool {
        if shouldRestoreRawBase() { return true }
        if let b = boundary, Self.isApostrophe(b), isContractionStemBeforeApostrophe() { return true }
        return englishByFrequency && frequencyPrefersEnglish()
    }

    /// ' typed, or ’ (a smart quote some hosts / mobile keyboards insert for it).
    static func isApostrophe(_ ch: Character) -> Bool { ch == "'" || ch == "\u{2019}" }

    /// ENGLISH CONTRACTION at the apostrophe: the word right before `'` is the stem of
    /// "doesn't", "isn't", "won't", "there's", "I'll"… Committed on its own the stem reads
    /// as Telex ("doesn" → doén, "isn" → ín, "won" → ươn, "there" → thể) — only the tail
    /// ("t", "s", "ll") is known to be English. With the apostrophe RIGHT AFTER the word,
    /// the raw keys come back when they — or they minus one final `n` (the n of n't) — are
    /// on the closed `EnglishContextWords.contractionStems` list. A Vietnamese word in
    /// single quotes ('tiếng') is not on it and stays Vietnamese. Boundary-only.
    private func isContractionStemBeforeApostrophe() -> Bool {
        guard compositionDiffersFromRaw(), let w = rawLowerWord() else { return false }
        if EnglishContextWords.contractionStems.contains(w) { return true }
        guard w.count >= 2, w.hasSuffix("n") else { return false }
        return EnglishContextWords.contractionStems.contains(String(w.dropLast()))
    }

    /// Every restore rule except the frequency rule (`englishByFrequency`).
    private func shouldRestoreRawBase() -> Bool {
        // Vietnamese syllable + literal initials ("PhươngTH", issue #138): the head was
        // vetted when the split was taken (valid syllable, no cancel, not an English
        // word) and the suffix is exactly what was typed — keep the screen.
        if initialsSplitAt >= 0 { return false }
        // A listed ALL-CAPS acronym ("ASAP" → ẤP, "WWDC" → WDC) is what the user typed, even
        // when Telex reads a common syllable or a cancel into it (closed list, see
        // `EnglishContextWords.capsAcronyms`).
        if isListedCapsAcronym() { return true }
        // ORDER IS THE POLICY. The cancel branch comes FIRST: a TRAILING escape
        // gesture (adjacent double modifier as the word's final keystroke — the user
        // is LOOKING at the screen and said "no diacritic, keep the letter") outranks
        // the English dictionary, so "pass"→pas, "off"→of commit exactly what the
        // screen showed. Decided 2026-07-31 (maintainer): screen-truth wins over
        // English-protection — this REVERSES the PR #3-era verdicts that restored
        // trailing-double English words ("pass"/"miss"/"boss") for blind English
        // typists; the cost (a blind-typed "pass" loses its last letter) is accepted
        // because the escape hatch must be reliable: under the old order, literal
        // "pas" was UNTYPEABLE. Scope is TRAILING only — a mid-word double
        // ("office"/"message"/"sorry") still consults the dictionary: nobody escapes
        // mid-word to type "ofice"/"sory", those commits would be pure misspellings.
        // English protection is also untouched where no cancel happened at all
        // ("his"→hís restores "his") and for accidental reach-back cancels
        // ("hosts", span > 1).
        if markCancelled {
            if composedIsValidSyllable() { return false }
            // A TONE-key cancel that REACHED BACK over letters (span > 1): the tone key
            // it killed was typed keys ago, so that key is itself a letter the word lost
            // — "hosts"→hots, "asks"→aks, "discs"→dics, "buses"→bues. NOT the deliberate
            // escape (that is the adjacent double, span == 1) — treat as accident:
            // restore the raw keys unless the result is a real English word whose raw
            // keys are not.
            if toneCancelSpan > 1 {
                return !composedIsRecognizedEnglish() || rawIsEnglishContextWord()
            }
            // MID-WORD adjacent double whose raw keys spell a real English word:
            // dictionary wins ("office"→ofice would be a misspelling nobody asked
            // for). Trailing cancels (toneCancelAt == last raw key) skip this — the
            // escape is the final, deliberate act. Mark doublers (toneCancelAt == -1)
            // stay screen-truth as before ("gooogle", "DDDR", "uw").
            if toneCancelAt >= 0, toneCancelAt < rawCount - 1, rawIsEnglishCollision() {
                return true
            }
            // VOWEL-DOUBLER cancel that REACHED BACK over letters (free marking: "seem" →
            // sêm, then the next `e` undid the hat across the m — "seemed" → "semed"): like
            // the reach-back tone cancel above it is no escape gesture (that is always the
            // adjacent "eee"), so when the raw keys are a dictionary English word the
            // dictionary wins ("seemed", "deemed", "needed"). "theme"+e ("themee") is no
            // English word and keeps "theme".
            if pMarkCancelReachedBack, rawIsEnglishCollision() { return true }
            // Chat elongation whose tail came from a mark doubler that cancelled
            // ("cosaaaaaaa" → "cóaaaaaa", "ajaaaaaaa" → "ạaaaaaa"): the composition is
            // a valid syllable plus the repeated tail, i.e. exactly what the user meant
            // — keep it even though a diacritic survived the cancel.
            if isTeencodeKeep() { return false }
            // Mark doubler whose cancel left a TONE floating that live spell-check then
            // folded back to a literal key at the freeze ("cheese": chế + e → "chée" →
            // "chese", "geese"→"gese"): the cancel did not clean the word, the freeze
            // did — and it lost a letter the user typed. Restore the raw keys, like the
            // stuck-diacritic case below would have without the fold. A real escape
            // ("gooogle", "aaa") has no pending tone, so it never folds.
            if toneCancelAt < 0, tonesFolded { return true }
            // The deliberate literal-letter escape — keep the screen ("pas", "tessted"→
            // tested, "Deffault"→Default: field reports 2026-07-26 / 07-22). Unless
            // free-marking left a diacritic stuck before the cancel, i.e. the cancel
            // did NOT clean the word up ("excess"→"êcs", "lenses"→"lêns").
            return composedHasDiacritic()
        }
        // Lật lại (englishByFrequency): từ trước vừa bị luật tần suất đổi sang tiếng Anh, từ này
        // lặp lại y phím ("His His" = hí hí) hoặc cùng nó thành cặp âm tiết Việt hay gặp ⇒ GIỮ
        // tiếng Việt (rồi từ trước được lật lại ở retroRecord), trước mọi luật khôi phục Anh.
        if englishByFrequency, frequencyKeepsVietnamese() { return false }
        // Ưu tiên tiếng Việt khi trùng (collisionPrefersVietnamese): từ Việt hợp lệ
        // thắng bảng collision khi đứng một mình; trong mạch tiếng Anh xem nhánh
        // context bên dưới (bảng vẫn khôi phục ở đó).
        // Đuôi -k (ák/ták/rík: rime Tây Nguyên Đắk/Lắk + teencode ik) KHÔNG phải từ Việt
        // thường dùng ⇒ không được "thắng" bảng collision: "task"→ták, "ask"→ák, "risk"→rík
        // (issue #127, 19/10/2026).
        // Glued to a code separator or a number (see `noteGlue`): "my_var" must not
        // commit "my_vả", "100W" not "100Ư".
        if wordGlue != 0, glueRestores() { return true }
        // Tự thêm dấu mũ biến một âm tiết SAI (trước đây luôn được trả về phím gốc) thành âm
        // tiết đúng, nên bảng collision chưa biết các từ này: phím gốc có cách đọc tiếng Anh
        // ("diets", "hues") thì trả về phím gốc như trước khi có tính năng.
        if inferredCircumflex, rawHasEnglishReading() { return true }
        if rawIsEnglishCollision(),
           !(collisionPrefersVietnamese && composedIsValidSyllable() && !composedEndsWithK()) { return true }
        // `isTeencodeKeep()` runs AFTER the English table above on purpose: the dictionary
        // still wins ("google" restores), and only a word that no dictionary claims gets
        // kept as "valid syllable + repeated tail" ("hôngggg", "vângggg", "đẹpppp").
        // A Vietnamese TYPO (one vowel group carrying a mark the user typed, no English
        // reading: "lanwm" → "lănm") keeps what the screen shows, so the user sees and
        // fixes the typo instead of getting raw keys back.
        if forceRestoreUpperTone || rawIsEnglishException()
            || (!composedIsValidSyllable() && !isTeencodeKeep() && !isVietnameseTypoKeep()
                && !isHatInitialismKeep()) { return true }
        // ALL-CAPS acronym whose Telex reading is a RARE syllable: "NAS" → "NÁ", "OS" → "Ó"
        // restore; "VIỆT", "ĐÀ NẴNG", "CÓ" (common) stay.
        if isRareAllCapsAcronym() { return true }
        // Context-based (experimental): after an English word, an ambiguous word whose raw
        // keys spell an English word is restored to English ("he is" → "is", not "í").
        // Gated so vniMode/default typing pays nothing (the String build only runs when the
        // flag is on AND the previous word was English).
        // A gated word ("been") additionally needs its required predecessor right
        // before it ("has been"), or the Vietnamese composition stands ("bên").
        if contextualEnglish, previousWordEnglish,
           rawIsEnglishContextWord(includingRestoreOnly: true)
               || (collisionPrefersVietnamese && rawIsEnglishCollision()),
           predecessorGateAllows() { return true }
        return false
    }

    // MARK: - Frequency rule + flip-back (englishByFrequency)

    /// Lowercased raw keys into `buf`; false if not all ascii letters or too long.
    private func lowerRaw(into buf: UnsafeMutablePointer<UInt8>, limit: Int) -> Bool {
        guard rawCount > 0, rawCount <= limit else { return false }
        for i in 0..<rawCount {
            var b = raw[i]
            if b >= 0x41, b <= 0x5A { b |= 0x20 }
            guard b >= 0x61, b <= 0x7A else { return false }
            buf[i] = b
        }
        return true
    }

    /// `EnglishFrequency` scores of the raw keys (boundary-only, allocation-free).
    private func rawFrequencyScores() -> (en: UInt8, vn: UInt8)? {
        withUnsafeTemporaryAllocation(of: UInt8.self, capacity: Self.capacity) { buf in
            guard let p = buf.baseAddress, lowerRaw(into: p, limit: EnglishFrequency.maxWordLength) else { return nil }
            return EnglishFrequency.scores(UnsafeBufferPointer(start: p, count: rawCount), count: rawCount)
        }
    }

    /// Luật tần suất: từ ĐẦU cụm (không mạch Anh, không từ Việt ngay trước), chữ trên màn hình là
    /// âm tiết Việt hợp lệ có biến đổi, âm tiết đó hiếm và từ Anh phổ biến hơn hẳn. NON-mutating.
    /// Không chạy khi bật teencode: tần suất Việt đếm trên corpus đã CHUẨN HOÁ teencode
    /// (bít → biết), nên "bít", "wá"… trông hiếm oan ("bít gòi" → "bits gòi").
    private func frequencyPrefersEnglish() -> Bool {
        guard englishByFrequencyActive, !teencode, !previousWordEnglish, !previousWordVietnamese,
              compositionDiffersFromRaw(), composedIsValidSyllable(),
              let sc = rawFrequencyScores(), sc.vn > 0 else { return false }
        return sc.vn < Self.frequencyVietnameseFloor && Int(sc.en) >= Int(sc.vn) + Int(Self.frequencyMargin)
    }

    /// The previous history word, if the frequency rule restored it and only spaces separate
    /// it from the word being committed.
    private var frequencyRestoredPrevious: RetroWord? {
        guard englishByFrequencyActive, retroGap >= 1, retroGap <= RetroEnglish.maxGap,
              let w = retroHistory.last, w.byFrequency else { return nil }
        return w
    }

    /// The frequency-restored word TWO back ("His ha" + this word), with a Vietnamese word
    /// between and only spaces around it — for the laughter pattern "hí ha hí hửng".
    private var frequencyRestoredTwoBack: RetroWord? {
        let n = retroHistory.count
        guard englishByFrequencyActive, n >= 2, retroGap >= 1, retroGap <= RetroEnglish.maxGap,
              retroHistory[n - 2].byFrequency, retroHistory[n - 1].gap > 0,
              !retroHistory[n - 1].english else { return nil }
        return retroHistory[n - 2]
    }

    /// Reduplication or a known Vietnamese pair with the frequency-restored previous word.
    private func frequencyKeepsVietnamese() -> Bool {
        guard let prev = frequencyRestoredPrevious, composedIsValidSyllable(),
              compositionHasDiacritic() else { return false }
        return frequencyPairEvidence(prev)
    }

    /// Same raw keys as `prev` (case-insensitive: "His His", "hí hí") or, unless
    /// `reduplicationOnly`, (prev, this composition) is in `EnglishFrequency` PAIRS.
    /// Allocation-free.
    private func frequencyPairEvidence(_ prev: RetroWord, reduplicationOnly: Bool = false) -> Bool {
        withUnsafeTemporaryAllocation(of: UInt8.self, capacity: 4 * Self.capacity + 2) { buf in
            guard let p = buf.baseAddress else { return false }
            var n = 0
            for var b in prev.raw.utf8 {
                guard n < Self.capacity else { return false }
                if b >= 0x41, b <= 0x5A { b |= 0x20 }
                p[n] = b; n += 1
            }
            // Reduplication: identical raw keys.
            if n == rawCount {
                var same = true
                for i in 0..<rawCount {
                    var b = raw[i]
                    if b >= 0x41, b <= 0x5A { b |= 0x20 }
                    if b != p[i] { same = false; break }
                }
                if same { return true }
            }
            if reduplicationOnly { return false }
            p[n] = UInt8(ascii: ">"); n += 1
            n = appendComposedTelexKey(p, n)
            return EnglishFrequency.hasPair(UnsafeBufferPointer(start: p, count: n), count: n)
        }
    }

    /// Append the composition's Telex key (letters with mark keys, tone last — the
    /// `CommonSyllables` spelling: "hửng" → "huwngr") at `p[n...]`; returns the new length.
    private func appendComposedTelexKey(_ p: UnsafeMutablePointer<UInt8>, _ start: Int) -> Int {
        var n = start
        for k in 0..<pCount {
            let l = renderLetters[k]
            p[n] = l.base; n += 1
            switch l.mark {
            case .none: break
            case .circumflex: p[n] = l.base; n += 1
            case .breve, .horn: p[n] = UInt8(ascii: "w"); n += 1
            case .bar: p[n] = UInt8(ascii: "d"); n += 1
            }
        }
        switch lastEffTone {
        case .none: break
        case .acute: p[n] = UInt8(ascii: "s"); n += 1
        case .grave: p[n] = UInt8(ascii: "f"); n += 1
        case .hook: p[n] = UInt8(ascii: "r"); n += 1
        case .tilde: p[n] = UInt8(ascii: "x"); n += 1
        case .dot: p[n] = UInt8(ascii: "j"); n += 1
        }
        return n
    }

    /// At a commit that KEPT Vietnamese: should the frequency-restored previous word flip
    /// back? Only on EVIDENCE for the Vietnamese reading — reduplication or a known pair.
    /// "Any clearly-Vietnamese next word" was measured too (05/11/2026, mixed-eval val):
    /// it also flips a deliberate English loanword at the start of a Vietnamese sentence
    /// ("test thế này…" → "tét thế này…") and fixes nothing the pair table misses.
    /// Boundary-only.
    /// Returns how many words back the flipped word is (1 or 2; 0 = no flip). Two back only
    /// for an exact repeat across one Vietnamese word ("hí ha hí").
    private func frequencyFlipDistance(restored: Bool) -> Int {
        guard !restored, composedIsValidSyllable() else { return 0 }
        if let prev = frequencyRestoredPrevious { return frequencyPairEvidence(prev) ? 1 : 0 }
        if compositionHasDiacritic(), let prev = frequencyRestoredTwoBack,
           frequencyPairEvidence(prev, reduplicationOnly: true) { return 2 }
        return 0
    }

    /// Glue rule (boundary-only, non-mutating):
    ///  • separator-glued ("_", or "." / "/" right after a code-like word): a TONE-ONLY
    ///    composition goes back to the raw keys ("my_var" not "my_vả", "self.bar" not
    ///    "self.bả"). A composition carrying a letter mark (â ê ô ă ơ ư đ) stays — those
    ///    keys were typed on purpose and code rarely spells them ("ok.ddi" → "ok.đi").
    ///  • digit-glued: a standalone-w ư (no u typed) is a unit, not Vietnamese ("100W",
    ///    "10kW", "5w"). Everything else composes ("5trăm", "2tiếng", "100đ"); a lone
    ///    tone letter has nothing to transform ("5s").
    private func glueRestores() -> Bool {
        guard !vniMode, pCount > 0, compositionHasDiacritic() else { return false }
        if wordGlue == 1 {
            for k in 0..<pCount where renderLetters[k].mark != .none { return false }
            return true
        }
        for k in 0..<pCount where renderLetters[k].base == UInt8(ascii: "u")
            && renderLetters[k].mark == .horn && letterCreatedByW(k) { return true }
        return false
    }

    /// Vietnamese typo keep (boundary-only, non-mutating): the composition is not a valid
    /// syllable, but it is ONE slip away from one that carries a Vietnamese-only letter the
    /// user produced (â ê ô ă ơ ư đ): a valid marked syllable plus a single stray plain
    /// consonant of the same case ("lanwm" → "lăn"+"m", "vieetk" → "viêt"+"k",
    /// "tieengsm" → "tiếng"+"m"), and the raw keys have no English reading. Such a word is
    /// Vietnamese with a typo — keep what the screen shows. Anything else (two vowel groups
    /// "deepseek"/"teamwork", two stray letters "thơzz", a capital after lowercase
    /// "PhươngT", a stray đ) still restores every raw key.
    private func isVietnameseTypoKeep() -> Bool {
        guard !vniMode, pCount >= 3, rawCount >= 3 else { return false }
        let last = renderLetters[pCount - 1]
        let prev = renderLetters[pCount - 2]
        guard last.mark == .none, !isVowelAscii(last.base), last.upper == prev.upper else { return false }
        // ONE vowel group in the KEYS typed, not just on screen: free marking can fold two
        // groups into one ("casual" → "cấul", "tester" → "tếtr") — that is English.
        var groups = 0
        var inVowel = false
        for i in 0..<rawCount {
            let v = isVowelAscii(lowercased(raw[i]))
            if v, !inVowel { groups += 1 }
            inVowel = v
        }
        guard groups == 1 else { return false }
        // The mark must be one the user built on a typed vowel (aa ee oo aw ow uw dd); a
        // standalone-w ư is English-leaning ("wal" → "ưal", "wan").
        var hasMark = false
        for k in 0..<(pCount - 1) where renderLetters[k].mark != .none {
            if renderLetters[k].mark == .horn, renderLetters[k].base == UInt8(ascii: "u"),
               letterCreatedByW(k) { return false }
            hasMark = true
        }
        // The head must be a REAL common syllable, not merely one the (permissive) validator
        // accepts: "đă"+"k", "ghơ"+"b", "ưi"+"n" are not typos of anything.
        guard hasMark, lettersAreCommonSyllable(pCount - 1) else { return false }
        // A stray letter that still reads as a coda waiting for its tone ("kêp", "mêt",
        // "rôt" — keep/meet/root) is English double-vowel spelling, not a slip.
        if SyllableValidator.isValidPrefix(composed.lowercased(), teencode: teencode) { return false }
        return !rawHasEnglishReading()
    }

    /// Two-letter Vietnamese initialism whose first letter is a HAT vowel ("ÂL" = âm lịch,
    /// typed "AAL"): the sibling of the DD→Đ abbreviation rule in `composedIsValidSyllable`,
    /// for the hat letters. Kept deliberately NARROW (maintainer spec 2026-11-08): exactly
    /// three raw keys, ONE case throughout (never mixed), no tone, shaped vowel + doubler
    /// (aa ee oo) or vowel + w (aw ow uw — never a standalone-w ư) + ONE bare Vietnamese
    /// consonant letter — not f j w z, and not a stop c k p t g q (vowel + stop with no tone
    /// is a half-typed syllable: "aat", "eep", "oog", "uwk" restore) — and the raw keys have no English reading — neither
    /// in the engine's dictionaries nor on `hatInitialismEnglish`, the closed list of
    /// English words / acronyms of exactly this shape that those dictionaries lack ("EEL",
    /// "EEK", "OOH", "OWL", "EEG", "OOP", "AAC" restore). The composition is not a valid
    /// syllable (callers check). 3+ letter forms ("OOTD", "AAPL") are out of scope and
    /// restore. Literal "AAL" stays reachable via the AAA cancel. Boundary-only,
    /// non-mutating, allocation-free.
    private func isHatInitialismKeep() -> Bool {
        guard !vniMode, rawCount == 3, pCount == 2, lastEffTone == .none else { return false }
        let up = isUpperAscii(raw[0])
        guard isUpperAscii(raw[1]) == up, isUpperAscii(raw[2]) == up else { return false }
        let v = lowercased(raw[0]), m = lowercased(raw[1]), c = lowercased(raw[2])
        guard isVowelAscii(v), m == v || m == UInt8(ascii: "w") else { return false }
        if m == v { guard v == UInt8(ascii: "a") || v == UInt8(ascii: "e") || v == UInt8(ascii: "o") else { return false } }
        else { guard v == UInt8(ascii: "a") || v == UInt8(ascii: "o") || v == UInt8(ascii: "u") else { return false } }
        guard c >= UInt8(ascii: "a"), c <= UInt8(ascii: "z"), !isVowelAscii(c),
              !Self.hatInitialismExcludedConsonants.contains(c) else { return false }
        let first = renderLetters[0], second = renderLetters[1]
        guard first.base == v, first.mark != .none, second.base == c, second.mark == .none else { return false }
        let key = UInt32(v) << 16 | UInt32(m) << 8 | UInt32(c)
        if Self.hatInitialismEnglish.contains(key) { return false }
        if isListedCapsAcronym() || rawIsEnglishCollision() { return false }
        return !rawHasEnglishReading()
    }

    /// Lowercase raw keys (packed v<<16 | m<<8 | c) of the `isHatInitialismKeep` shape that
    /// read as English: words (aah eel ooh owl awl) and acronyms (aad oob awb awd uwb).
    /// Stop-consonant forms (eek eeg oop aac…) never reach it. Mirrored in Kotlin and C++.
    /// Third keys `isHatInitialismKeep` never keeps: non-Vietnamese letters (f j w z) and
    /// stops (c k p t g q).
    private static let hatInitialismExcludedConsonants: [UInt8] = Array("fjwzckptgq".utf8)

    private static let hatInitialismEnglish: [UInt32] = [
        "aah", "eel", "ooh", "owl", "awl", "aad", "oob", "awb", "awd", "uwb",
    ].map { s in s.utf8.reduce(UInt32(0)) { $0 << 8 | UInt32($1) } }

    /// The raw keys spell, or begin like, a known English word: any dictionary the engine
    /// carries, or a freeze prefix of the English lexicon ("seed…", "good…"). Boundary-only.
    private func rawHasEnglishReading() -> Bool {
        if rawIsEnglishContextWord(includingRestoreOnly: true) || rawIsNeutralLoanword() { return true }
        if let w = rawLowerWord(), EnglishCollisions.words.contains(w) { return true }
        let top = min(rawCount, EnglishFreezePrefixes.maxLength)
        guard top >= EnglishFreezePrefixes.minLength else { return false }
        for n in EnglishFreezePrefixes.minLength...top
        where raw.withUnsafeBufferPointer({ EnglishFreezePrefixes.contains($0, count: n) }) { return true }
        return false
    }

    /// ALL-CAPS token with two or more capitals (a DD→Đ pair counts as one) whose Telex
    /// reading is a valid but RARE syllable: an acronym ("NAS"→NÁ, "OS"→Ó, "AWS"→Ắ).
    /// Common syllables (`CommonSyllables`) stay Vietnamese ("VIỆT", "CÓ", "ĐÀ NẴNG");
    /// vowel-less initialisms are the đ-abbreviation's business ("HĐND", "VNĐ").
    /// Boundary-only, non-mutating, allocation-free.
    private func isRareAllCapsAcronym() -> Bool {
        guard !vniMode, rawIsAllCapsToken() else { return false }
        var hasVowel = false
        for k in 0..<pCount where isVowelAscii(renderLetters[k].base) { hasVowel = true; break }
        guard hasVowel, compositionHasDiacritic(), composedIsValidSyllable() else { return false }
        // An acronym's tone letter is its LAST letter ("NAS", "AWS"); a tone key typed
        // mid-word is Vietnamese spelling ("DAJA" → "DẠA", "DDAFN"), not an acronym —
        // unless the 3+ raw keys spell a dictionary English word ("NASA" → NẤ, "USA" → ÚA).
        if lastEffTone != .none, !isToneKey(rawCount - 1), !(rawCount >= 3 && rawIsDictionaryWord()) {
            return false
        }
        // Acronyms with a Vietnamese-looking reading are short ("NAS", "AWS", "OS"). From
        // 4 keys on, a token that is no English word is Vietnamese typed in capitals
        // ("MUTS" → MÚT, "VIAS" → VÍA, "TAIX" → TÃI); English words ("MUST", "TEST") stay.
        if rawCount >= 4, !rawIsDictionaryWord() { return false }
        return !composedIsCommonSyllable()
    }

    /// Raw keys (lowercased) are in the collision table or the context dictionary. Unlike
    /// `rawIsEnglishCollision` this ignores `englishWordRestore` and the w rules — it only
    /// asks "is this an English word?". Boundary-only (one String).
    private func rawIsDictionaryWord() -> Bool {
        guard let w = rawLowerWord() else { return false }
        return EnglishCollisions.words.contains(w) || EnglishContextWords.words.contains(w)
    }

    /// ALL-CAPS 3+ keys on `EnglishContextWords.capsAcronyms`, and Telex changed them.
    /// Boundary-only; byte pre-filters before the one String.
    private func isListedCapsAcronym() -> Bool {
        guard !vniMode, rawCount >= 3, rawCount <= 5, isUpperAscii(raw[0]), rawIsAllCapsToken(),
              compositionDiffersFromRaw(), let w = rawLowerWord() else { return false }
        return EnglishContextWords.capsAcronyms.contains(w)
    }

    /// Every raw key is an uppercase letter and the token has at least two capitals:
    /// letters on screen plus a tone key ("OS" → Ó = 2, "NAS" = 3). A mark doubler is part
    /// of its letter (DD→Đ, AA→Â count once), so "AA"→Â / "DD"→Đ are single letters, not
    /// acronyms. Boundary-only.
    private func rawIsAllCapsToken() -> Bool {
        guard rawCount >= 2 else { return false }
        for i in 0..<rawCount where !isUpperAscii(raw[i]) { return false }
        return pCount + (lastEffTone == .none ? 0 : 1) >= 2
    }

    /// True when the composition (letters + tone) is in `CommonSyllables`. The key is the
    /// Telex spelling with the tone last, so old/new tone placement read the same.
    private func composedIsCommonSyllable() -> Bool { lettersAreCommonSyllable(pCount) }

    /// `renderLetters[0..<count]` + the word's effective tone is a common syllable.
    private func lettersAreCommonSyllable(_ count: Int) -> Bool {
        withUnsafeTemporaryAllocation(of: UInt8.self, capacity: 2 * Self.capacity + 1) { buf in
            var n = 0
            for k in 0..<count {
                let l = renderLetters[k]
                buf[n] = l.base; n += 1
                switch l.mark {
                case .none: break
                case .circumflex: buf[n] = l.base; n += 1
                case .breve, .horn: buf[n] = UInt8(ascii: "w"); n += 1
                case .bar: buf[n] = UInt8(ascii: "d"); n += 1
                }
            }
            switch lastEffTone {
            case .none: break
            case .acute: buf[n] = UInt8(ascii: "s"); n += 1
            case .grave: buf[n] = UInt8(ascii: "f"); n += 1
            case .hook: buf[n] = UInt8(ascii: "r"); n += 1
            case .tilde: buf[n] = UInt8(ascii: "x"); n += 1
            case .dot: buf[n] = UInt8(ascii: "j"); n += 1
            }
            return CommonSyllables.contains(buf, count: n)
        }
    }

    /// `EnglishContextWords.predecessorGates`: true unless the raw word is gated and the
    /// previous committed word is not one of its predecessors. NON-mutating, boundary-only.
    private func predecessorGateAllows() -> Bool {
        guard let w = rawLowerWord(), let i = EnglishContextWords.gateIndex(of: w) else { return true }
        return previousGateBits & (UInt8(1) << UInt8(i)) != 0
    }

    /// Raw keystrokes as a lowercase ascii word (nil if empty, too long for any English
    /// table, or containing a non-letter). Boundary-only (allocates one String).
    private func rawLowerWord() -> String? {
        guard rawCount > 0, rawCount <= EnglishContextWords.maxLength else { return nil }
        var v = String.UnicodeScalarView()
        v.reserveCapacity(rawCount)
        for i in 0..<rawCount {
            var b = raw[i]
            if b >= UInt8(ascii: "A"), b <= UInt8(ascii: "Z") { b |= 0x20 }
            guard b >= UInt8(ascii: "a"), b <= UInt8(ascii: "z") else { return nil }
            v.append(Unicode.Scalar(b))
        }
        return String(v)
    }

    /// True if the current composition still carries any Vietnamese diacritic — a mark
    /// (â/ê/ô/ơ/ư/ă/đ) on any letter, or a pending tone. NON-mutating.
    /// Âm tiết kết thúc bằng phụ âm k (Đắk, teencode thík) — không bao giờ là từ Việt
    /// phổ thông nên không thắng bảng collision tiếng Anh.
    private func composedEndsWithK() -> Bool {
        pCount > 0 && letters[pCount - 1].base == UInt8(ascii: "k")
    }

    private func composedHasDiacritic() -> Bool {
        if pTone != .none { return true }
        for k in 0..<pCount where letters[k].mark != .none { return true }
        return false
    }

    /// True if the composed form is itself a recognized English word (collision table or
    /// context whitelist) — the tone-cancel escape ("iss"→is, "Deffault"→Default) vs a
    /// mangled letter-drop ("possess"→posess). NON-mutating; boundary-only (one String).
    private func composedIsRecognizedEnglish() -> Bool {
        guard outCount >= 2, outCount <= 12 else { return false }
        var v = String.UnicodeScalarView()
        v.reserveCapacity(outCount)
        for i in 0..<outCount {
            var b = out[i]
            if b >= 0x41, b <= 0x5A { b |= 0x20 }
            guard b >= 0x61, b <= 0x7A else { return false }   // non-ascii ⇒ not English
            v.append(Unicode.Scalar(b)!)
        }
        let w = String(v)
        return EnglishCollisions.words.contains(w) || EnglishContextWords.words.contains(w)
    }

    /// How a committed word affects the NEXT word's context. FOUR-way, not binary:
    /// - `.englishFunction` — an English function word (`EnglishContextWords.functionWords`:
    ///                   the, is, he, of, and…): opens (or continues) an English run.
    /// - `.english`   — any other English word (dictionary or structural: "suggestion",
    ///                   "commit"): continues an open run; with no run open it only
    ///                   becomes a CANDIDATE, and a second English word opens the run
    ///                   (11/10/2026: one loanword in a Vietnamese sentence must not).
    /// - `.vietnamese`— a valid Vietnamese syllable: end the English run (context = VN).
    /// - `.neutral`   — a loanword / foreign / brand token that is neither (e.g. "email",
    ///                   "app", "wifi"): PRESERVE the current context. This is what makes
    ///                   "email bán" stay Vietnamese (email doesn't start an English run)
    ///                   while "the email is" keeps the English run "the" opened.
    enum WordContext { case englishFunction, english, vietnamese, neutral }
    /// Classify by what was ACTUALLY committed (so it never disagrees with the screen):
    /// - restored to raw ascii → English if it's a recognized English word, else `.neutral`
    ///   (a loanword/foreign token like "email" that was only restored because it isn't a
    ///   VN syllable — must NOT open an English run);
    /// - kept a composition WITH a Vietnamese diacritic ("lít", "được") → `.vietnamese`;
    /// - kept plain ascii (no transform): English if recognized ("he", "the"), else VN.
    private func isRecognizedEnglish() -> Bool {
        rawIsEnglishContextWord() || rawIsEnglishCollision() || rawIsEnglishException()
    }
    private func classifyWordContext(restored: Bool) -> WordContext {
        // A Vietnamese diacritic actually ON SCREEN outranks everything. Tested on the
        // OUTPUT, not on "differs from raw": a cancelled transform ("thiss" → plain
        // ascii "this") also differs, and calling that Vietnamese is what made
        // "thiss is" come out "this í" (field report 2026-08-14).
        // Exception: an English word that collides with COMMON Vietnamese ("box" → bõ,
        // "car" → cả) stays Vietnamese on screen, but inside an open English run it must
        // not END the run — or the next function word flips too ("my car is" → "my cả í").
        if !restored, compositionHasDiacritic() {
            return previousWordEnglish && rawIsRunKeeper() ? .neutral : .vietnamese
        }
        if isRecognizedEnglish() {                              // "he", "the", collisions
            return rawIsFunctionWord() ? .englishFunction : .english
        }
        // Escape-typed English: the doubled key that cancels the transform leaves the
        // real word on screen while the RAW keys ("thiss", "gooogle") are in no
        // dictionary. Ask the same dictionaries about what the user actually SEES.
        if let word = composedAsciiWord(),
           EnglishContextWords.words.contains(word)
            || EnglishCollisions.words.contains(word)
            || EnglishContextWords.neutralLoanwords.contains(word) {
            if EnglishContextWords.neutralLoanwords.contains(word) { return .neutral }
            return EnglishContextWords.functionWords.contains(word) ? .englishFunction : .english
        }
        // Neutral loanwords ("email", "app", "wifi") and restore-only interjections
        // ("ok", "wow", "hi" — designed to never OPEN a run, see restoreOnly):
        // Vietnamese sentences use them constantly — preserve the context (neither
        // open nor end a run), or "email bans" would keep "bans" instead of "bán"
        // and "ok cams" would keep "cams" instead of "cám".
        // Contraction tails ("I've" → "ve") likewise: toneless "ve"/"re" would otherwise
        // read as Vietnamese and end the run right before "been".
        if rawIsNeutralLoanword() || rawIsEnglishContextWord(includingRestoreOnly: true)
            || rawIsContractionTail() {
            return .neutral
        }
        // Toneless-Vietnamese typing ("sao", "khong") keeps the context Vietnamese.
        if !restored, SyllableValidator.isValidSyllable(composed.lowercased(), teencode: teencode) { return .vietnamese }
        // 1–2 letter tokens that no dictionary knows are chat abbreviations, not
        // English ("b" = bạn, "c" = chị, "k", "mn", "dc", "ng", "vk", "ae"… — issue
        // #93, 25/09/2026: "b is" kept "is" instead of "í"). Every real 1–2 letter
        // English word (is, it, he, on, to, of, my, we, up…) is in the dictionaries
        // and was classified above, so the structural English fallback below only
        // ever caught abbreviations here. Neutral: preserve context, never open a run.
        if rawCount <= 2 { return .neutral }
        // An unknown ALL-CAPS token is an acronym ("ASL", "NAS" restored): neither English
        // nor Vietnamese — it must not open an English run (and so never flips the word
        // before it: "bên ASL" keeps "bên").
        if rawIsAllCapsToken() { return .neutral }
        // Everything left is a word NO Vietnamese syllable can be — untouched
        // ("github") or restored-to-raw ("position", whose restore is a textual
        // no-op) — and that structure is as strong an English-run signal as a
        // dictionary hit. The dictionaries deliberately can't carry these: the
        // collision table only holds words the engine MANGLES, and a word the
        // validator refuses to compose is exactly the word that never gets mangled.
        // Field report 2026-08-14: "position is" → "position í" — "position" fell
        // to the old defaults (.neutral when restored, .vietnamese when untouched)
        // and never opened the English run.
        return .english
    }

    /// Raw keystrokes spell a neutral loanword (see EnglishContextWords.neutralLoanwords).
    private func rawIsNeutralLoanword() -> Bool {
        guard rawCount > 0, rawCount <= EnglishContextWords.maxLength else { return false }
        var v = String.UnicodeScalarView()
        v.reserveCapacity(rawCount)
        for i in 0..<rawCount {
            var b = raw[i]
            if b >= UInt8(ascii: "A"), b <= UInt8(ascii: "Z") { b |= 0x20 }
            guard b >= UInt8(ascii: "a"), b <= UInt8(ascii: "z") else { return false }
            v.append(Unicode.Scalar(b))
        }
        return EnglishContextWords.neutralLoanwords.contains(String(v))
    }

    private func rawIsFunctionWord() -> Bool {
        guard let w = rawLowerWord() else { return false }
        return EnglishContextWords.functionWords.contains(w)
    }

    /// `EnglishContextWords.runKeepers`. Boundary-only; called only inside an open run.
    private func rawIsRunKeeper() -> Bool {
        guard let w = rawLowerWord() else { return false }
        return EnglishContextWords.runKeepers.contains(w)
    }

    private func rawIsContractionTail() -> Bool {
        guard rawCount <= 2, let w = rawLowerWord() else { return false }
        return EnglishContextWords.contractionTails.contains(w)
    }

    /// Fold the just-committed word into the cross-word context (only when the feature is on).
    /// Run state machine: function word → open; content word → continue an open run,
    /// else candidate, else (second English word in a row) open; Vietnamese → close
    /// everything; neutral → preserve run AND candidate.
    private mutating func updateContext(restored: Bool) {
        guard contextualEnglish, rawCount > 0 else { return }
        switch classifyWordContext(restored: restored) {
        case .englishFunction: previousWordEnglish = true; englishCandidate = false
        case .english:         foldEnglishContentWord()
        case .vietnamese:      clearEnglishContext(); previousWordVietnamese = true; return
        case .neutral:         break                  // loanword/foreign: preserve
        }
        if previousWordEnglish { previousWordVietnamese = false }     // a run opened (one loanword does not)
        previousGateBits = rawLowerWord().map(EnglishContextWords.predecessorBits(of:)) ?? 0
    }

    /// An English CONTENT word was committed: continue an open run; otherwise the second
    /// one in a row opens it ("fix bug"), the first only marks a candidate ("suggestion").
    private mutating func foldEnglishContentWord() {
        if previousWordEnglish { return }
        if englishCandidate { previousWordEnglish = true; englishCandidate = false } else { englishCandidate = true }
    }

    /// Raw keystrokes spell a common English word (see EnglishContextWords). NON-mutating.
    /// `includingRestoreOnly` also accepts the interjection layer (wow/ok/hey…): those
    /// must be RESTORED inside an English run but must never OPEN one, so the context
    /// classifier calls this with the default (false) and only the restore decision
    /// passes true.
    private func rawIsEnglishContextWord(includingRestoreOnly: Bool = false) -> Bool {
        guard rawCount > 0, rawCount <= EnglishContextWords.maxLength else { return false }
        var v = String.UnicodeScalarView()
        v.reserveCapacity(rawCount)
        for i in 0..<rawCount {
            var b = raw[i]
            if b >= UInt8(ascii: "A"), b <= UInt8(ascii: "Z") { b |= 0x20 }
            guard b >= UInt8(ascii: "a"), b <= UInt8(ascii: "z") else { return false }
            v.append(Unicode.Scalar(b))
        }
        let w = String(v)
        if EnglishContextWords.words.contains(w) { return true }
        return includingRestoreOnly && EnglishContextWords.restoreOnly.contains(w)
    }

    /// Clear the cross-word English context (caller: focus change / app switch), so a new
    /// typing context doesn't inherit the previous field's last word.
    public mutating func resetContext() {
        clearEnglishContext()
        previousWordVietnamese = false
        if !retroHistory.isEmpty || retroPending != nil { retroClear() }
    }

    // MARK: - Retroactive English correction (retroactiveEnglish)

    /// The caller inserted boundary character `ch` after a commit (space, punctuation,
    /// newline, apostrophe…). Spaces keep the next word in the same phrase; anything else
    /// starts a new one. A pending correction is extended to cover `ch`, so it stays
    /// relative to the caret. No-op while the feature is inactive.
    public mutating func noteBoundaryCharacter(_ ch: Character) {
        noteGlue(ch)
        // A sentence ends: the next word starts a phrase (frequency rule only reads this).
        if previousWordVietnamese, ch == "." || ch == "!" || ch == "?" || ch == "\n" || ch == "\r" {
            previousWordVietnamese = false
        }
        guard retroactiveEnglish || !retroHistory.isEmpty || retroPending != nil else { return }
        // One BMP scalar only: the edit counts characters as UTF-16 units on every platform.
        guard retroactiveEnglishActive, rawCount == 0, ch.unicodeScalars.count == 1,
              let sc = ch.unicodeScalars.first, sc.value <= 0xFFFF else { retroClear(); return }
        if let p = retroPending {
            retroPending = RetroCorrection(backspaces: p.backspaces + 1,
                                           expected: p.expected + String(ch),
                                           insert: p.insert + String(ch), words: p.words,
                                           flipBack: p.flipBack)
        }
        if ch == " " {
            retroGap += 1
        } else {
            retroHistory.removeAll(keepingCapacity: true)
            retroPendingPicks.removeAll()
            retroGap = 0
        }
    }

    /// Glued-separator bookkeeping for `noteBoundaryCharacter` (always on, a few byte
    /// compares). What the NEXT word starts glued to:
    ///  • "_" — always a code identifier ("my_var", "MAX_SIZE").
    ///  • "." / "/" — only when it is the FIRST character right after a code-like word
    ///    ("os.path", "user/repo", "self.var"); after Vietnamese or a capitalized word it
    ///    is ordinary text ("và/hoặc", "anh/chị", "TP.Hồ", "Ừ...thôi").
    ///  • a digit — the word is glued to a number ("100W", "4G", "5trăm").
    /// Anything else (space, newline, other punctuation) ends the glue.
    private mutating func noteGlue(_ ch: Character) {
        let first = !noteSinceWord
        noteSinceWord = true
        guard let a = ch.asciiValue else { pendingGlue = 0; return }
        switch a {
        case UInt8(ascii: "_"):
            pendingGlue = 1
        case UInt8(ascii: "."), UInt8(ascii: "/"):
            pendingGlue = first && lastWordKind == 2 ? 1 : 0
        case UInt8(ascii: "0")...UInt8(ascii: "9"):
            pendingGlue = 2
        default:
            pendingGlue = 0
        }
    }

    private mutating func clearGlue() {
        lastWordKind = 0
        noteSinceWord = true
        pendingGlue = 0
    }

    /// Commit bookkeeping shared by both commit paths (before resetWord): what the word
    /// left on screen for the glue rule, and the ⌫-undo record when a REAL Vietnamese
    /// alternative was restored to raw keys. Boundary-only.
    private mutating func noteCommittedWord(restored: Bool) {
        guard rawCount > 0 else { return }
        let keptVietnamese = !restored && (compositionHasDiacritic() || composedIsValidSyllable())
        // A word glued to a number is a quantity ("5k", "100m", "2h"): a "/" after it starts a
        // Vietnamese unit ("5k/tháng", "2h/ngày"), not a code path.
        lastWordKind = keptVietnamese || isUpperAscii(raw[0]) || wordGlue == 2 ? 1 : 2
        noteSinceWord = false
        pendingGlue = 0
        // Not for a word glued to code/number ("self.bar", "100W"): a ⌫ there is editing.
        if restored, wordGlue == 0, compositionDiffersFromRaw(), compositionHasDiacritic(),
           composedIsValidSyllable() || isTeencodeKeep() {
            restoreUndo = RestoreUndo(restored: rawKeystrokes, vietnamese: composed)
        }
    }

    /// The ⌫-undo record of the commit that JUST happened (nil = it restored nothing a
    /// Vietnamese reader would want back). Taking it consumes it. Valid only right after
    /// `commitBoundary` / `commitText` (and `noteBoundaryCharacter`); any key, ⌫, reset or
    /// the next commit drops it.
    public mutating func takeRestoreUndo() -> RestoreUndo? {
        let u = restoreUndo
        restoreUndo = nil
        return u
    }

    /// Non-consuming look at `takeRestoreUndo`.
    public var pendingRestoreUndo: RestoreUndo? { restoreUndo }

    /// The caller put the Vietnamese word back on screen (⌫ right after a restore): the
    /// committed word is now Vietnamese. Drop the composition, re-open snapshot and retro
    /// history (the text changed under them) and end any English run.
    public mutating func restoreUndoApplied() {
        reset()
        clearEnglishContext()
    }

    /// The edit the LAST commit decided (nil = nothing to rewrite). Taking it means the
    /// caller APPLIES it: the history then records the rewritten words as English.
    /// Valid right after the commit (and after any `noteBoundaryCharacter` calls); any
    /// other engine call (next key, ⌫, reset…) discards it.
    public mutating func takeRetroCorrection() -> RetroCorrection? {
        guard let c = retroPending else { return nil }
        retroPending = nil
        for i in retroPendingPicks where i < retroHistory.count {
            if c.flipBack {
                retroHistory[i].shown = retroHistory[i].alt
                retroHistory[i].english = false
                retroHistory[i].byFrequency = false
            } else {
                retroHistory[i].shown = retroHistory[i].raw
                retroHistory[i].english = true
                retroHistory[i].candidate = false
            }
        }
        retroPendingPicks.removeAll()
        return c
    }

    /// Non-consuming look at the pending edit.
    public var pendingRetroCorrection: RetroCorrection? { retroPending }

    private mutating func retroClear() {
        retroHistory.removeAll()
        retroPendingPicks.removeAll()
        retroPending = nil
        retroGap = 0
    }

    /// Record the word being committed (BEFORE `updateContext`: the classifier reads the
    /// previous word's context) and decide. Boundary-only; allocates a few small Strings.
    private mutating func retroRecord(restored: Bool, elongated: Bool) {
        retroPending = nil
        retroPendingPicks.removeAll()
        guard retroactiveEnglishActive, rawCount > 0 else { retroClear(); return }
        let rawText = rawKeystrokes
        let shown = restored ? rawText : (elongated ? composedElongated() : composed)
        // Frequency rule (englishByFrequency): was THIS word restored only by it, and does it
        // flip the previous one back? Both read the state the restore decision saw.
        var byFrequency = false, flipBack = 0
        if englishByFrequency {
            byFrequency = restored && !elongated && !shouldRestoreRawBase() && !needsStandaloneWRunRestore()
                && frequencyPrefersEnglish()
            flipBack = elongated ? 0 : frequencyFlipDistance(restored: restored)
        }
        let ascii = shown.unicodeScalars.allSatisfy { $0.isASCII }
        let kind = classifyWordContext(restored: restored)
        let lower = rawLowerWord()
        // The article "a" is restore-only for the context machinery (it never opens a
        // run: "a" = anh in chat) but inside the retro history it IS English text.
        let english = ascii && (kind == .english || kind == .englishFunction
                                || (rawCount == 1 && raw[0] | 0x20 == UInt8(ascii: "a")))
        let candidate = !ascii && !restored && !elongated && rawCount >= 2
            && (lower.map(RetroEnglish.isCandidateRaw) ?? false)
        let gap = (!retroHistory.isEmpty && retroGap >= 1 && retroGap <= RetroEnglish.maxGap) ? retroGap : 0
        let leftNonEnglish = gap > 0 && !(retroHistory.last?.english ?? true)
        if retroHistory.count >= RetroEnglish.historyCapacity { retroHistory.removeFirst() }
        let gateBit: UInt8 = lower.flatMap(EnglishContextWords.gateIndex(of:)).map { UInt8(1) << UInt8($0) } ?? 0
        let strong = english && kind == .english && (lower.map(RetroEnglish.isStrongRaw) ?? false)
        retroHistory.append(RetroWord(raw: rawText, shown: shown, english: english, candidate: candidate,
                                      cls: lower.map(RetroEnglish.classBits) ?? 0, gap: gap,
                                      leftNonEnglish: leftNonEnglish, gateBit: gateBit,
                                      predBits: lower.map(EnglishContextWords.predecessorBits(of:)) ?? 0,
                                      strong: strong, byFrequency: byFrequency,
                                      alt: byFrequency ? composed : ""))
        retroGap = 0
        if flipBack > 0, retroHistory.count > flipBack, retroHistory[retroHistory.count - 1 - flipBack].byFrequency {
            let picks = [retroHistory.count - 1 - flipBack]
            if let c = RetroEnglish.correction(retroHistory, picks, flipBack: true) {
                retroPending = c
                retroPendingPicks = picks
            }
            return
        }
        guard english, let picks = RetroEnglish.plan(retroHistory),
              let c = RetroEnglish.correction(retroHistory, picks) else { return }
        retroPending = c
        retroPendingPicks = picks
    }

    /// Test-only: the history the retroactive check sees.
    var debugRetroHistory: [RetroWord] { retroHistory }

    /// Previous word unknown / Vietnamese: no run, no pending content word, no gate.
    private mutating func clearEnglishContext() {
        previousWordEnglish = false
        englishCandidate = false
        previousGateBits = 0
    }

    /// Caller vừa chèn NGUYÊN VĂN một từ ngoài engine (gõ vuốt ra từ tiếng Anh): cập nhật
    /// ngữ cảnh chéo từ như thể từ đó vừa được chốt. `english == false` ⇒ ngữ cảnh Việt.
    /// Không biết chữ ⇒ coi là từ Anh NỘI DUNG (một mình không mở mạch).
    public mutating func noteExternalWord(english: Bool) { noteExternalWord(nil, english: english) }

    /// Như trên nhưng biết chữ: từ chức năng vuốt ra ("it", "the") mở mạch — "it" vuốt
    /// rồi gõ "is" giữ "is"; từ nội dung ("check") chỉ mở mạch khi đi sau một từ Anh
    /// khác; "has" vuốt rồi gõ "been" giữ "been" (predecessor gate).
    public mutating func noteExternalWord(_ word: String?, english: Bool) {
        guard contextualEnglish else { return }
        guard english else { clearEnglishContext(); return }
        let w = word?.lowercased()
        if let w, EnglishContextWords.functionWords.contains(w) {
            previousWordEnglish = true; englishCandidate = false
        } else {
            foldEnglishContentWord()
        }
        previousGateBits = w.map(EnglishContextWords.predecessorBits(of:)) ?? 0
    }

    /// Final text to commit at a word boundary, with auto-restore applied
    /// (non-Vietnamese syllables fall back to the raw keystrokes). Resets the engine.
    /// Used by the marked-text controller path.
    public mutating func commitText(autoRestore: Bool, boundary: Character? = nil) -> String {
        defer { resetWord() }
        restoreUndo = nil
        // Overflowed: never restore to `rawKeystrokes` (only the first 32 keys) —
        // return the composed prefix unchanged; the caller keeps the rest on screen.
        if overflowed {
            if contextualEnglish { clearEnglishContext() }
            reopenRawCount = 0; reopenOutCount = 0                 // stale prefix: never re-open
            if !retroHistory.isEmpty || retroPending != nil { retroClear() }
            return composed
        }
        // Decide with the PREVIOUS word's context, then refresh it for the NEXT word
        // (reusing the restore decision — no repeated checks).
        let wantsRestore = outCount > 0
            && (needsStandaloneWRunRestore() || (autoRestore && shouldRestoreRaw(before: boundary)))
        let elongate = !wantsRestore && outCount > 0 && isToneThenATail()
        let text = wantsRestore ? rawKeystrokes : (elongate ? composedElongated() : composed)
        captureReopen(restored: (wantsRestore && compositionDiffersFromRaw()) || elongate)
        noteCommittedWord(restored: wantsRestore)
        if retroactiveEnglish || !retroHistory.isEmpty { retroRecord(restored: wantsRestore, elongated: elongate) }
        updateContext(restored: wantsRestore)
        return text
    }

    /// Non-mutating twin of `commitText(autoRestore:)`: điều boundary SẼ chốt,
    /// không reset, không đụng state — caller (suggestion bar iOS) peek mỗi phím
    /// trực tiếp trên engine, khỏi COW-copy cả struct (~10 buffer cố định mỗi
    /// lần copy khi `commitText` mutate). Phải trả về byte-identical với
    /// `{ var e = self; return e.commitText(autoRestore:) }`.
    public func peekCommitText(autoRestore: Bool, boundary: Character? = nil) -> String {
        // Overflowed: mirror commitText — composed prefix, không bao giờ restore.
        if overflowed { return composed }
        if outCount > 0, needsStandaloneWRunRestore() {
            return rawKeystrokes
        }
        if autoRestore, outCount > 0, shouldRestoreRaw(before: boundary) {
            return rawKeystrokes
        }
        if outCount > 0, isToneThenATail() { return composedElongated() }
        return composed
    }

    /// Common English words whose FULL-Telex transform collides with a VALID
    /// Vietnamese syllable, so validity-based auto-restore keeps the Vietnamese
    /// ("was"→ứa, "wow"→Ươ). Force-restored at the boundary instead — the reverse
    /// of the "đc" whitelist. Zero-alloc byte compare on the raw keys; extend as
    /// field reports arrive (candidate for a user-editable list later).
    private static let englishExceptions: [[UInt8]] = [
        Array("was".utf8), Array("wow".utf8),
        Array("yes".utf8),   // "ýe" slips through the validator as a syllable
        Array("queue".utf8), // "quêu" passes the validator but is no Vietnamese word
        Array("away".utf8),  // aw+a swaps ă→â (issue #149): "away" would commit "ây"
    ]
    /// Generated English-collision table (EnglishCollisions.swift, gen-english):
    /// top-frequency English words whose default-Telex transform yields a VALID
    /// Vietnamese syllable, so validity-based restore can't catch them
    /// ("his"→hí, "this"→thí, "see"→sê). Boundary-only; the String is built only
    /// after cheap byte pre-filters, never on the per-key hot path.
    private func rawIsEnglishCollision() -> Bool {
        guard englishWordRestore else { return false }
        guard rawCount >= 2, rawCount <= 12 else { return false }
        guard compositionDiffersFromRaw() else { return false }   // untouched words can't collide
        // w-entries count only when the w actually BECAME ư (full Telex) — in
        // Simple Telex the literal-w teencode forms ("wá" = quá) must survive.
        if (raw[0] | 0x20) == UInt8(ascii: "w") {
            let wTransformed = pCount > 0 && renderLetters[0].base == UInt8(ascii: "u")
                && renderLetters[0].mark == .horn
            if !wTransformed { return false }
        }
        var v = String.UnicodeScalarView()
        v.reserveCapacity(rawCount)
        for i in 0..<rawCount {
            var b = raw[i]
            if b >= UInt8(ascii: "A"), b <= UInt8(ascii: "Z") { b |= 0x20 }
            guard b >= UInt8(ascii: "a"), b <= UInt8(ascii: "z") else { return false }
            v.append(Unicode.Scalar(b))
        }
        return EnglishCollisions.words.contains(String(v))
    }

    private func rawIsEnglishException() -> Bool {
        guard pCount > 0 else { return false }
        // w-initiated entries apply ONLY when the w actually BECAME ư (full Telex):
        // in Simple Telex the literal-w teencode forms ("wá" = quá) are the point
        // and must survive. Non-w entries (yes) apply in every mode.
        let wTransformed = renderLetters[0].base == UInt8(ascii: "u")
            && renderLetters[0].mark == .horn
        outer: for word in Self.englishExceptions {
            guard word.count == rawCount else { continue }
            if word[0] == UInt8(ascii: "w"), !wTransformed { continue }
            for i in 0..<rawCount where lowercased(raw[i]) != word[i] { continue outer }
            return true
        }
        return false
    }

    /// Zero-allocation twin of `SyllableValidator.isValidSyllable(String)` on the
    /// current composition: letter classes come from the render copy (post ươ
    /// propagation), the tone from the last render's effective tone.
    /// TEENCODE onsets folded to their canonical spelling FOR VALIDATION ONLY
    /// (rendering keeps the literal letters): w→qu ("wá"=quá, "wó"), z→d/gi/v-class
    /// ("zô", "zị", "zậy"), dz→d ("dzô", "dzị"). The informal onset is swapped and
    /// the REST of the syllable still has to pass the normal rime+tone rules, so
    /// English/garbage stays restorable. f→ph was considered and dropped: it makes
    /// the common English "fair" a valid syllable (fải).
    /// Returns the canonical onset's ascii letters + how many leading letters it
    /// replaces, or nil when the word has no informal onset.
    private func teencodeOnset() -> (canonical: [UInt8], skip: Int)? {
        guard teencode, pCount >= 2, renderLetters[0].mark == .none else { return nil }
        switch renderLetters[0].base {
        case UInt8(ascii: "w"): return ([UInt8(ascii: "q"), UInt8(ascii: "u")], 1)
        case UInt8(ascii: "z"): return ([UInt8(ascii: "d")], 1)
        case UInt8(ascii: "d")
            where pCount >= 3 && renderLetters[1].base == UInt8(ascii: "z")
               && renderLetters[1].mark == .none:
            return ([UInt8(ascii: "d")], 2)
        default: return nil
        }
    }

    /// True when every letter parsed so far is a bare CONSONANT (no vowel — a
    /// rendered Đ counts as its consonant base, not a mark exception) and shares
    /// ONE case with `upper`. This is the shape of a Vietnamese initialism typed
    /// with dd for Đ ANYWHERE in the string — "VNĐ", "HTĐ", "HĐND" — not just at
    /// the start ("ĐSQ"/"ĐHQG" already worked: the live-spell-check freeze hadn't
    /// triggered yet when their doubler ran, since a leading 'd' alone doesn't
    /// invalidate any prefix). No real English or Vietnamese WORD is ever
    /// multiple letters with zero vowels — "add"/"odd"/"ladder"/"kidding"/"middle"
    /// all carry a vowel before their "dd" — so this can never fire on them.
    private func isAbbreviationPrefix(upper: Bool) -> Bool {
        guard pCount > 0 else { return false }
        for k in 0..<pCount {
            let l = letters[k]
            if isVowelAscii(l.base) || l.upper != upper { return false }
        }
        return true
    }

    /// Live-spell-check freeze exception (2026-08-06, maintainer-specified feature):
    /// a 'd' that continues a bare-consonant, single-case prefix keeps folding to
    /// Đ even after the word has frozen — see `isAbbreviationPrefix`. VNI spells
    /// Đ with a digit, not by doubling, so it is untouched.
    private func abbreviationDoublerException(lower: UInt8, upper: Bool) -> Bool {
        !pVniMode && lower == UInt8(ascii: "d") && isAbbreviationPrefix(upper: upper)
    }

    /// NON-mutating: letter classes go into a small STACK buffer
    /// (`withUnsafeTemporaryAllocation`, ≤33 bytes — no heap), not `basesScratch`,
    /// so the boundary decision is shareable by `peekCommitText` per keystroke.
    private func composedIsValidSyllable() -> Bool {
        // Đ-initial ABBREVIATIONS (chat shorthand), not real syllables: đ, đc, đm,
        // đk, đkm… survive auto-restore — typing "ddm" keeps đm instead of
        // reverting to raw (generalized from the đc whitelist, user decision
        // 2026-07-22). Shape: leading đ (from dd) + ZERO or more bare consonants,
        // no tone. Vowelled words (đi, đau) take the normal validation path;
        // a literal lowercase "dd…" remains reachable via the ddd cancel.
        if pCount >= 1, lastEffTone == .none,
           renderLetters[0].base == UInt8(ascii: "d"), renderLetters[0].mark == .bar {
            var bareConsonantsOnly = true
            for k in 1..<pCount {
                let l = renderLetters[k]
                if l.mark != .none || isVowelAscii(l.base) { bareConsonantsOnly = false; break }
            }
            if bareConsonantsOnly { return true }
        }
        // Single-case abbreviation whose only transform is DD→Đ ("ĐSQ" = Đại Sứ
        // Quán, "ĐHQG", "VNĐ", "HTĐ", "HĐND"…): the doubled D was deliberate,
        // restoring to raw is strictly worse (ALL-CAPS: user report 2026-07-21;
        // generalized to all-lowercase, "vnđ" etc.: maintainer spec 2026-08-06 —
        // ONE case throughout, never mixed, since a mixed-case word is a real
        // typing attempt, not an initialism). Conditions: every raw key the SAME
        // case, no tone, EVERY letter a bare consonant except the đ bar — a
        // VOWEL anywhere exits the rule (that's a real word attempt, not an
        // initialism: "address"/"ladder" have a vowel before their "dd" and MUST
        // still restore to raw; "ddsqa" — consonants then a trailing vowel — is
        // the same exit, tested explicitly). A literal DD is still reachable
        // through the double-key cancel: DDD → DD (so DDDR → DDR, "ddd" → "dd").
        if lastEffTone == .none, rawCount >= 2 {
            var sameCase = true
            let firstIsUpper = isUpperAscii(raw[0])
            for i in 0..<rawCount where isUpperAscii(raw[i]) != firstIsUpper {
                sameCase = false
                break
            }
            if sameCase {
                var hasBar = false
                var onlyBar = true
                for k in 0..<pCount {
                    let l = renderLetters[k]
                    if isVowelAscii(l.base) { onlyBar = false; break }
                    if l.base == UInt8(ascii: "d"), l.mark == .bar { hasBar = true }
                    else if l.mark != .none { onlyBar = false; break }
                }
                if hasBar, onlyBar { return true }
            }
        }
        // Teencode onset: validate as if spelled canonically ("wá" checks as quá).
        // n ≤ pCount + 1 (canon ≤ 2, skip ≥ 1) nên capacity + 1 luôn đủ.
        return withUnsafeTemporaryAllocation(of: UInt8.self, capacity: Self.capacity + 1) { buf in
            // MỘT đặc cách teencode mỗi từ (19/08/2026, field case "wise.com"→"wíe.com"
            // ở Simple Telex): onset teencode (w→qu) CHỒNG rime teencode ("ie") cho
            // "wíe" validate thành "quíe" → boundary không restore, "wise"/"wife" chết
            // thành wíe/wìe. Rime teencode CÓ THANH duy nhất chạm được từ ascii trần
            // là "ie" ("oy" đòi zero-onset, "ưm/ưn" đòi ư có dấu, "ou" chỉ nhận
            // không-thanh nên composed ≡ raw — không stack được) nên guard shape đó:
            // phần sau onset là đúng hai chữ i-e trần → bỏ nhánh teencode-onset,
            // để đường validate thường (onset 'w' không hợp lệ) từ chối và restore.
            let stacksTeencodeRime = pCount >= 3
                && renderLetters[pCount - 2].base == UInt8(ascii: "i")
                && renderLetters[pCount - 2].mark == .none
                && renderLetters[pCount - 1].base == UInt8(ascii: "e")
                && renderLetters[pCount - 1].mark == .none
                && teencodeOnset().map { $0.skip == pCount - 2 } ?? false
            if !stacksTeencodeRime, pCount < Self.capacity - 1, let (canon, skip) = teencodeOnset() {
                var n = 0
                for c in canon { buf[n] = Tables.letterClass(base: c, mark: .none); n += 1 }
                for k in skip..<pCount {
                    buf[n] = Tables.letterClass(base: renderLetters[k].base,
                                                mark: renderLetters[k].mark)
                    n += 1
                }
                if SyllableValidator.isValidSyllable(classes: buf, count: n,
                                                     tone: lastEffTone, teencode: teencode) { return true }
            }
            for k in 0..<pCount {
                buf[k] = Tables.letterClass(base: renderLetters[k].base,
                                            mark: renderLetters[k].mark)
            }
            return SyllableValidator.isValidSyllable(classes: buf, count: pCount,
                                                     tone: lastEffTone, teencode: teencode)
        }
    }

    // MARK: - Teencode elongation ("hôngggg", "cóaaaa", "ạaaaa", "đẹpppp")

    /// Chat elongation: the letters split as a VALID syllable HEAD followed by a TAIL
    /// that is a run of ONE repeated letter ("hôn"+"gggg", "có"+"aaaa", "ạ"+"aaaa",
    /// "đẹp"+"pppp"). Returns the head letter count, or -1 when the word has no such
    /// shape.
    ///
    /// The run must be at least THREE letters. Two was the first design (2026-08-04) and
    /// it cost 24 English words in the regression suite: English doubles letters all the
    /// time, so "wall"→ưall, "balls"→báll, "eggs"→égg, "apps"→ápp, "ascii"→ácii,
    /// "wifi"→ừii all became "valid syllable + run of 2" and stopped restoring. NO
    /// English or Vietnamese word TRIPLES a letter, so ≥3 is the shape that means "the
    /// user is leaning on a key" and nothing else. Cost: "hoongg" (2 g's) still restores
    /// to raw — one repeat short of an elongation.
    ///
    /// The SHORTEST valid head wins. That is what keeps the tone where the user saw it
    /// before the elongation started: "cosaaaaaaa" has both splits "co"+"aaaaaa" and
    /// "coa"+"aaaaa" (both heads are real rimes), and only the shortest one puts the
    /// sắc back on the o — "cóaaaaaa", not "coáaaaa". The longest tail also matches the
    /// intent: everything after the syllable is the user leaning on one key.
    ///
    /// NON-mutating; reads `renderLetters` (post ươ-propagation), so callers must have
    /// rendered first. Allocation-free (the head check uses a stack buffer).
    private func elongationHeadCount(_ count: Int, tone: Tone) -> Int {
        let minRun = 3
        guard count >= minRun + 1 else { return -1 }
        // Cheap gate first: the word must END in `minRun` copies of one letter.
        // Everything else (validator work) sits behind this, so ordinary typing pays a
        // couple of byte compares per keystroke.
        let last = renderLetters[count - 1]
        for j in (count - minRun)..<(count - 1) {
            guard renderLetters[j].base == last.base,
                  renderLetters[j].mark == last.mark else { return -1 }
        }
        var runStart = count - minRun
        while runStart > 0,
              renderLetters[runStart - 1].base == last.base,
              renderLetters[runStart - 1].mark == last.mark { runStart -= 1 }
        if runStart < 1 { runStart = 1 }          // the head needs at least one letter
        var k = runStart
        while k <= count - minRun {               // tail length ≥ minRun
            if isValidHead(k, tone: tone) { return k }
            k += 1
        }
        return -1
    }

    /// Valid-syllable check over `renderLetters[0..<k]` with an explicit tone — the head
    /// half of the elongation split. Teencode onsets (w→qu, z→d, dz→d) fold exactly like
    /// `composedIsValidSyllable`, and the stop-coda tone rule is applied to the HEAD's
    /// coda. NON-mutating, stack buffer, no heap.
    private func isValidHead(_ k: Int, tone: Tone, plainLast: Bool = false) -> Bool {
        guard k >= 1, k <= Self.capacity else { return false }
        // `plainLast`: judge the head with its LAST letter's mark dropped ("dậ" as "dạ").
        func mark(_ j: Int) -> Mark { plainLast && j == k - 1 ? .none : renderLetters[j].mark }
        var t = tone
        if t == .grave || t == .hook || t == .tilde, hasStopCoda(k),
           !(t == .grave && isUkRime(k)) { t = .none }     // lockstep với render path
        return withUnsafeTemporaryAllocation(of: UInt8.self, capacity: Self.capacity + 1) { buf in
            if let (canon, skip) = teencodeOnset(), skip < k {
                var n = 0
                for c in canon { buf[n] = Tables.letterClass(base: c, mark: .none); n += 1 }
                for j in skip..<k {
                    buf[n] = Tables.letterClass(base: renderLetters[j].base, mark: mark(j))
                    n += 1
                }
                if SyllableValidator.isValidSyllable(classes: buf, count: n, tone: t, teencode: teencode) { return true }
            }
            for j in 0..<k {
                buf[j] = Tables.letterClass(base: renderLetters[j].base, mark: mark(j))
            }
            return SyllableValidator.isValidSyllable(classes: buf, count: k, tone: t, teencode: teencode)
        }
    }

    /// Boundary keep rule for chat elongation: the composition is not a valid syllable
    /// on its own, but it IS one plus a repeated tail the user typed on purpose
    /// ("hôngggg", "cóaaaa", "ạaaaa", "đẹpppp") — commit what is on screen instead of
    /// snapping back to the raw keystrokes. Boundary-only (one word), NON-mutating.
    private func isTeencodeKeep() -> Bool {
        elongationHeadCount(pCount, tone: lastEffTone) > 0
    }

    /// True when the composed scalars differ from the raw keystrokes (i.e. some
    /// transform actually happened) — compared numerically, no Strings.
    private func compositionDiffersFromRaw() -> Bool {
        if outCount != rawCount { return true }
        for i in 0..<outCount where out[i] != UInt32(raw[i]) { return true }
        return false
    }

    /// Is there a Vietnamese diacritic ACTUALLY ON SCREEN? Non-ascii output is exactly
    /// that: every Telex transform that survives to the screen produces a non-ascii
    /// scalar (â ê ô ơ ư đ + tones), and nothing else can.
    ///
    /// Distinct from `compositionDiffersFromRaw()`, which is also true when the diff is
    /// a CANCELLED transform — "thiss" (doubled s to escape the tone) composes plain
    /// ascii "this" yet differs from its raw keys. The context classifier needs THIS
    /// question; using the other one called escaped English words Vietnamese (field
    /// report 2026-08-14: "thiss is" → "this í").
    private func compositionHasDiacritic() -> Bool {
        for i in 0..<outCount where out[i] > 127 { return true }
        return false
    }

    /// The composed text, lowercased ascii, when it is PURE ascii — the form an escaped
    /// English word ends up in ("thiss" → "this", "gooogle" → "google"). nil when the
    /// composition carries a diacritic (then it is Vietnamese, not a dictionary word) or
    /// is longer than any word we look up. Lets the English dictionaries answer for the
    /// escape class, whose RAW keys ("thiss") no dictionary can carry.
    private func composedAsciiWord() -> String? {
        guard outCount > 0, outCount <= EnglishContextWords.maxLength else { return nil }
        var v = String.UnicodeScalarView()
        v.reserveCapacity(outCount)
        for i in 0..<outCount {
            var c = out[i]
            if c > 127 { return nil }
            if c >= UInt32(UInt8(ascii: "A")), c <= UInt32(UInt8(ascii: "Z")) { c |= 0x20 }
            guard c >= UInt32(UInt8(ascii: "a")), c <= UInt32(UInt8(ascii: "z")),
                  let scalar = Unicode.Scalar(c) else { return nil }
            v.append(scalar)
        }
        return String(v)
    }

    /// Uppercase tone/mark key preceded by a lowercase letter (camelCase like
    /// "SaaS", "OmS", "JavaScript") → English/code, freeze/restore to raw even if
    /// the composed form is a valid syllable. `upperToneKey` already encodes the
    /// "a lowercase came before it" test (see `hasLowercaseBefore`), so an uppercase
    /// tone key that is first ("OSm") or in an all-caps word ("VIEEJT") never sets it.
    private var forceRestoreUpperTone: Bool { upperToneKey }

    /// True if any raw keystroke before index `at` is a lowercase ascii letter.
    /// True if the FIRST raw key that produced letter `idx` was a w — i.e. the
    /// letter is a standalone-w ư, not a typed u that a later w horned.
    @inline(__always)
    private func letterCreatedByW(_ idx: Int) -> Bool {
        for i in 0..<rawCount where rawLetter[i] == idx {
            return raw[i] == UInt8(ascii: "w") || raw[i] == UInt8(ascii: "W")
        }
        return false
    }

    /// ua/uu retarget may land on a predecessor `u` that is unmarked (first w → ư)
    /// or already horned (second w CANCELS that ư: huaww→huaw, luuww→luuw).
    /// A standalone-w ư is excluded: a later w must breve/horn the leftover
    /// vowel (waw→ưă, wuw→ưư) instead of consuming w at a distance (waw→wa).
    @inline(__always)
    private func uaUuPredecessorAllowsRetarget(_ pred: Int) -> Bool {
        let m = letters[pred].mark
        return m == .none || (m == .horn && !letterCreatedByW(pred))
    }

    @inline(__always)
    private func hasLowercaseBefore(_ at: Int) -> Bool {
        for i in 0..<at where raw[i] >= UInt8(ascii: "a") && raw[i] <= UInt8(ascii: "z") {
            return true
        }
        return false
    }

    // MARK: - Initials suffix ("PhươngTH", "KiênTV", "HùngNV" — issue #138)

    /// Shortest / longest initials run glued after the name. ONE trailing capital keeps
    /// the historical behaviour on purpose: "SaaS"/"OmS"/"PhD" are camelCase English, and
    /// a lone capital is indistinguishable from them. Two or more are initials.
    static let initialsMin = 2
    static let initialsMax = 4

    /// Raw index where the word splits into HEAD + INITIALS, or -1. Shape only (no
    /// parse): the head is Title-case — an uppercase first key, then lowercase keys
    /// (VNI: or digits; Telex: the second D of a "DD" Đ) — and the word ENDS with a run
    /// of `initialsMin...initialsMax` uppercase letters right after a lowercase key.
    /// ALL-CAPS words ("VIEETJ", "HDDND"), lowercase-initial identifiers ("iOS",
    /// "macOS") and anything ending lowercase ("JavaScript", "McDonald") never match,
    /// nor does a run that is a code acronym ("MaxID", "PosURL": `runIsCodeAcronym`).
    /// O(1) exit on the common case (first key lowercase, or last key lowercase).
    private func initialsSplitPoint() -> Int {
        guard rawCount >= 1 + Self.initialsMin, isUpperAscii(raw[0]),
              isUpperAscii(raw[rawCount - 1]) else { return -1 }
        var s = rawCount
        while s > 0, isUpperAscii(raw[s - 1]) { s -= 1 }
        let n = rawCount - s
        guard s >= 2, n >= Self.initialsMin, n <= Self.initialsMax else { return -1 }
        var hasLower = false
        for i in 1..<s {
            let c = raw[i]
            if c >= UInt8(ascii: "a"), c <= UInt8(ascii: "z") { hasLower = true; continue }
            if vniMode, isDigit(c) { continue }
            if !vniMode, i == 1, c == UInt8(ascii: "D"), raw[0] == UInt8(ascii: "D") { continue }
            return -1
        }
        guard hasLower, !runIsCodeAcronym(s) else { return -1 }
        return s
    }

    /// raw[s..<rawCount] (uppercase, 2–4 keys) is a code acronym ("MaxID", "TaxURL"),
    /// not a name's initials — EnglishContextWords.codeAcronyms. Shape-level: applies
    /// whatever the English-restore settings. ≤4 letters: a small string, no heap.
    private func runIsCodeAcronym(_ s: Int) -> Bool {
        var v = String.UnicodeScalarView()
        for i in s..<rawCount { v.append(Unicode.Scalar(lowercased(raw[i]))) }
        return EnglishContextWords.codeAcronyms.contains(String(v))
    }

    /// Is raw[0..<s], typed ALONE, a Vietnamese syllable the boundary would keep?
    /// Valid syllable, actually transformed (a mark or a tone — an untouched head
    /// commits the same either way, "AnhNT"), no cancel gesture, and not an English
    /// word (collision / context / exception tables: "AsJSON", "HasID" keep the old
    /// whole-word restore). Re-parses the head in place, then restores the word's parse
    /// state. Runs only for a split CANDIDATE that is not yet applied — rare.
    private mutating func headIsInitialsSyllable(_ s: Int) -> Bool {
        let full = rawCount
        let savedDisabled = disabledAtCount
        let savedKeep = freezeKeepsTone
        rawCount = s
        disabledAtCount = Int.max
        freezeKeepsTone = false
        rebuildParseState()
        _ = render()
        var ok = !pCancelled
        if ok {
            var transformed = lastEffTone != .none
            for k in 0..<pCount where renderLetters[k].mark != .none { transformed = true; break }
            ok = transformed && composedIsValidSyllable() && !rawHeadIsEnglish(s)
        }
        rawCount = full
        disabledAtCount = savedDisabled
        freezeKeepsTone = savedKeep
        if !ok { rebuildFrozenAware() }      // the caller rebuilds itself when it splits
        return ok
    }

    private func rawHeadIsEnglish(_ s: Int) -> Bool {
        guard englishWordRestore, s <= EnglishContextWords.maxLength else { return false }
        var v = String.UnicodeScalarView()
        v.reserveCapacity(s)
        for i in 0..<s {
            let b = lowercased(raw[i])
            guard b >= UInt8(ascii: "a"), b <= UInt8(ascii: "z") else { return false }
            v.append(Unicode.Scalar(b))
        }
        let w = String(v)
        if EnglishCollisions.words.contains(w) || EnglishContextWords.words.contains(w) { return true }
        for e in Self.englishExceptions where e.count == s && String(decoding: e, as: UTF8.self) == w {
            return true
        }
        return false
    }

    /// Take, keep or lift the initials split for the CURRENT raw keys. Taking it freezes
    /// the word at the split with the head's tone kept (the PR #133 kept-tone freeze),
    /// so the initials are literal letters — an uppercase S/F/R/X/J/W/D there is a
    /// letter, never a tone/mark ("KieenSV" → KiênSV) — and the boundary keeps it.
    /// Lifting replays the freeze from scratch (what forward typing would have had).
    /// Returns true when the parse state changed (caller re-renders).
    private mutating func applyInitialsSplit() -> Bool {
        let s = initialsSplitPoint()
        if s >= 0 {
            if initialsSplitAt == s, disabledAtCount == s, freezeKeepsTone { return false }
            if headIsInitialsSyllable(s) {
                initialsSplitAt = s
                disabledAtCount = s
                freezeKeepsTone = true
                upperToneFrozen = false
                rebuildParseState()
                tonesFolded = false
                return true
            }
            // Rejected head: the parse state is back, but the head's render overwrote
            // the scratch buffers — fall through so the caller re-renders either way.
            if initialsSplitAt >= 0 {
                recomputeFreeze()
                rebuildFrozenAware()
            }
            return true
        }
        if initialsSplitAt >= 0 {
            recomputeFreeze()                    // clears initialsSplitAt
            rebuildFrozenAware()
            return true
        }
        return false
    }

    /// Drop the current word AND the re-open snapshot. What callers use when the
    /// composition is abandoned (focus change, app switch, caret moved): after this
    /// no ⌫ may re-open anything, because the text before the caret is unknown.
    public mutating func reset() {
        // Composition dropped MID-WORD (buffer still holds letters, no commit ran):
        // the word on screen never updated the cross-word context, so whatever the
        // word BEFORE it seeded would leak past it. Issue #91 (22/09/2026, Lark):
        // "done rồi as" → "rồi" dropped between its last key and the space → "as"
        // decided on "done" → restored to English. Previous word is now unknown →
        // Vietnamese default, same call the ⌫-into-committed-text path makes.
        if rawCount > 0 { clearEnglishContext(); previousWordVietnamese = true }
        resetWord()
        reopenRawCount = 0
        reopenOutCount = 0
        restoreUndo = nil
        clearGlue()
        if !retroHistory.isEmpty || retroPending != nil { retroClear() }   // caret moved / text unknown
    }

    /// Word state only; the re-open snapshot survives. The boundary commits capture
    /// the snapshot and then clear the word through THIS — a full `reset()` would
    /// wipe what they just captured.
    private mutating func resetWord() {
        rawCount = 0
        outCount = 0
        markCancelled = false
        toneCancelAt = -1
        toneCancelSpan = 0
        upperToneKey = false
        upperToneFrozen = false
        initialsSplitAt = -1
        wordGlue = 0
        overflowed = false
        disabledAtCount = Int.max
        tonesFolded = false
        freezeKeepsTone = false
        pFreezeLetters = -1
        pCount = 0
        pTone = .none
        pToneKeyCount = 0
        pCancelled = false
        pToneCancelAt = -1
        pToneCancelSpan = 0
        pMarkCancelReachedBack = false
        pProcessed = 0
    }

    /// True if the current parse state's first `n` letters form a valid Vietnamese
    /// syllable prefix. Walks the validator's flat tries over the letters' folded
    /// bases (bit 7 = carries a mark) — no String, no hashing, no allocation.
    private mutating func prefixIsValid(_ n: Int) -> Bool {
        // Teencode onsets validate as their canonical spelling ("w…" as "qu…",
        // "z…"/"dz…" as "d…") so live spell-check doesn't freeze "wá"/"zô"-class
        // words at their very first key. Mirrors teencodeOnset() on the PARSE
        // letters (render hasn't happened yet on this path).
        var out = 0
        var start = 0
        if teencode, n >= 1, letters[0].mark == .none, n < Self.capacity - 1 {
            switch letters[0].base {
            case UInt8(ascii: "w"):
                basesScratch[0] = UInt8(ascii: "q"); basesScratch[1] = UInt8(ascii: "u")
                out = 2; start = 1
            case UInt8(ascii: "z"):
                basesScratch[0] = UInt8(ascii: "d"); out = 1; start = 1
            case UInt8(ascii: "d")
                where n >= 2 && letters[1].base == UInt8(ascii: "z") && letters[1].mark == .none:
                basesScratch[0] = UInt8(ascii: "d"); out = 1; start = 2
            default: break
            }
        }
        for k in start..<n {
            basesScratch[out] = letters[k].base | (letters[k].mark != .none ? 0x80 : 0)
            out += 1
        }
        return SyllableValidator.isValidPrefix(bases: basesScratch, count: out, teencode: teencode)
    }

    /// Eager English restore gate, evaluated ONLY at the live-spell-check freeze moment
    /// (forward typing, or its ⌫/replay twin in `recomputeFreeze`) — once per word.
    /// `n` = letters just rendered into `scratch` for `raw[0..<rawCount]`.
    /// Restores only when: the flag is on (caller's effective auto-restore), Telex (VNI
    /// raw holds digits, never an English prefix), no deliberate cancel happened (a
    /// cancel is the user's own escape — "gooogle" keeps its screen-truth), the screen
    /// actually differs from the raw keys (else nothing to restore), and the raw keys are
    /// exactly an English freeze prefix (table min length 4).
    private func eagerRestoreApplies(_ n: Int) -> Bool {
        guard eagerEnglishRestore, !vniMode, !pCancelled,
              rawCount >= EnglishFreezePrefixes.minLength,
              rawCount <= EnglishFreezePrefixes.maxLength else { return false }
        var differs = n != rawCount
        if !differs {
            for i in 0..<n where scratch[i] != UInt32(raw[i]) { differs = true; break }
        }
        guard differs else { return false }
        return raw.withUnsafeBufferPointer { EnglishFreezePrefixes.contains($0, count: rawCount) }
    }

    // MARK: - Test / caller helpers

    /// Raw index from which live spell-check froze the current word (0 = the whole word
    /// is literal: eager English restore or a mixed-case upper-tone freeze), nil = not
    /// frozen. For the gen-freeze-prefixes generator and callers' diagnostics.
    public var spellCheckFreezeAt: Int? { disabledAtCount == Int.max ? nil : disabledAtCount }

    /// TRUE while the current word has exceeded the 32-key capacity. Callers need this
    /// to tell an overflow `.passthrough` (key NOT recorded — the app must render and
    /// delete natively) from an ordinary literal-letter `.passthrough` (key recorded,
    /// composition still live). The action alone cannot distinguish the two.
    public var isOverflowed: Bool { overflowed }

    /// Opt-in "red underline" (Windows TSF / Linux preedit): TRUE when the word being
    /// composed should be marked as misspelled. Only Vietnamese the engine actually
    /// produced is judged — a word left as typed (composed == raw keys: English, code,
    /// frozen by live spell-check) or one the boundary will restore to raw keys
    /// (auto-restore / English context) is never flagged. Callers only ask when the
    /// setting is on; the cost is one peek + one validator walk over ≤32 letters.
    public func hasSpellingError(autoRestore: Bool) -> Bool {
        if rawCount == 0 || overflowed || outCount == 0 { return false }
        let shown = composed
        if shown == rawKeystrokes { return false }
        if peekCommitText(autoRestore: autoRestore) != shown { return false }
        return SyllableValidator.isSpellingError(shown, teencode: teencode)
    }

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

    /// Test-only (internal): the cancel snapshots `shouldRestoreRaw` decides on, and the
    /// live parse state they must mirror. Any freeze/rebuild that changes the parse has
    /// to re-take the snapshots — a stale pair makes the boundary commit decide on
    /// pre-freeze data. Compared key-by-key by the regression tests; not part of the
    /// public API.
    var debugCancelSnapshot: (cancelled: Bool, at: Int, span: Int) {
        (markCancelled, toneCancelAt, toneCancelSpan)
    }
    var debugParseCancelState: (cancelled: Bool, at: Int, span: Int) {
        (pCancelled, pToneCancelAt, pToneCancelSpan)
    }
    /// Test-only (internal): raw index from which live spell-check froze the word
    /// (`Int.max` = not frozen).
    var debugFreezeAt: Int { disabledAtCount }

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
        // Kept-tone freeze (PR #133): the word before the freeze is shown exactly as it
        // was — the literal tail neither attracts the tone nor re-shapes ươ.
        let headEnd = freezeKeepsTone && pFreezeLetters >= 0 ? min(count, pFreezeLetters) : count

        // ươ propagation: in a "uo" cluster, if EITHER letter is horned, mirror it
        // onto the other so both become ươ — in a closed syllable (coda/offglide
        // after), and not the "qu" glide. This covers both key orders, so fast
        // typing that reorders o/w ("uow" vs "uwo") still yields ươ: trường, được,
        // nước, người, sương. Stays plain "uơ" when the o is the last letter (open:
        // thuở, huơ) or after "qu" (quở, quởn).
        for k in 1..<max(1, headEnd) {
            guard renderLetters[k - 1].base == UInt8(ascii: "u"),
                  renderLetters[k].base == UInt8(ascii: "o") else { continue }
            let prevHorn = renderLetters[k - 1].mark == .horn
            let curHorn = renderLetters[k].mark == .horn
            guard prevHorn != curHorn else { continue }   // exactly one horned
            let oIsLast = (k == headEnd - 1)
            let isQuGlide = (k >= 2 && renderLetters[k - 2].base == UInt8(ascii: "q"))
            if !oIsLast && !isQuGlide {
                renderLetters[k - 1].mark = .horn
                renderLetters[k].mark = .horn
            }
        }

        // Tone placement; map deferred tone/z keys onto the toned vowel (or the
        // last letter when there is no tone, so they group with it for backspace).
        var effTone = pTone
        // TEENCODE elongation: a repeated tail ("cosaaaaaaa", "ajaaaa") is NOT part of
        // the syllable, so it must not attract the tone — place the mark inside the
        // valid head only ("cóaaaaaa", "ạaaaaaa"; without the cap free-marking drifts
        // the tone onto the first tail vowel: "coáaaaa", "aạaaaa"). Gated on "a tone is
        // pending AND the word ends in a doubled letter", so normal words pay nothing.
        var toneScope = headEnd
        if pTone != .none, headEnd == count {
            let head = elongationHeadCount(count, tone: pTone)
            if head > 0 { toneScope = head }
        }
        var toneIdx = pTone == .none ? -1 : toneVowelIndex(toneScope)
        // Stop codas (-c, -ch, -p, -t) only allow sắc (´) and nặng (.). Drop an
        // invalid huyền/hỏi/ngã (e.g. "batf" stays "bat", not "bàt").
        if toneIdx >= 0, effTone == .grave || effTone == .hook || effTone == .tilde,
           hasStopCoda(toneScope),
           !(effTone == .grave && isUkRime(toneScope)) {   // ừk/hừk: huyền sống trên ưk
            effTone = .none
            toneIdx = -1
        }
        // Tự thêm dấu mũ (issue #166): sau khi biết thanh nào còn hiệu lực. Mũ vừa thêm là
        // nguyên âm có dấu duy nhất của vần nên thanh đặt lại lên nó.
        inferredCircumflex = false
        if autoCircumflex, effTone != .none, toneScope == count,
           inferCircumflex(count, tone: effTone) {
            inferredCircumflex = true
            toneIdx = toneVowelIndex(toneScope)
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

    /// Tự thêm dấu mũ — xem `autoCircumflex`. Đọc/ghi `renderLetters[0..<count]`. Trả về true
    /// khi đã đặt mũ. Điều kiện: đúng MỘT cụm nguyên âm, chưa chữ nào trong cụm mang dấu, cụm
    /// thuộc danh sách dưới; âm tiết không mũ KHÔNG hợp lệ với thanh này còn âm tiết có mũ thì
    /// hợp lệ (validator quyết định, nên "quan", "què", "xẻng", "séc" không bị đụng tới).
    private mutating func inferCircumflex(_ count: Int, tone: Tone) -> Bool {
        guard count >= 2, count < Self.capacity else { return false }
        var first = -1, last = -1
        for k in 0..<count where isVowelAscii(renderLetters[k].base) {
            if renderLetters[k].mark != .none { return false }
            if first < 0 { first = k } else if k != last + 1 { return false }
            last = k
        }
        guard first >= 0 else { return false }
        let n = last - first + 1
        @inline(__always) func v(_ i: Int) -> UInt8 { renderLetters[first + i].base }
        let a = UInt8(ascii: "a"), e = UInt8(ascii: "e"), i = UInt8(ascii: "i")
        let u = UInt8(ascii: "u"), y = UInt8(ascii: "y")
        var target = -1
        switch n {
        case 1 where v(0) == e:                                    // ênh, êch
            target = first
        case 2 where v(1) == e && (v(0) == i || v(0) == y) && last < count - 1:   // iên, yêt…
            target = first + 1
        case 2 where v(0) == u && v(1) == e:                       // uê, uênh, uêch
            target = first + 1
        case 2 where v(0) == e && v(1) == u:                       // êu
            target = first
        case 2 where v(0) == u && v(1) == a && last < count - 1:   // uân, uât, uâng
            target = first + 1
        case 3 where v(0) == u && v(1) == y && v(2) == e && last < count - 1:   // uyên, uyêt
            target = first + 2
        case 3 where (v(0) == i || v(0) == y) && v(1) == e && v(2) == u:   // iêu, yêu
            target = first + 1
        case 3 where v(0) == u && v(1) == a && v(2) == y:          // uây
            target = first + 1
        default:
            return false
        }
        let tc = teencode
        let ok: Bool = withUnsafeTemporaryAllocation(of: UInt8.self, capacity: Self.capacity) { buf in
            for k in 0..<count {
                buf[k] = Tables.letterClass(base: renderLetters[k].base, mark: renderLetters[k].mark)
            }
            if SyllableValidator.isValidSyllable(classes: buf, count: count, tone: tone, teencode: tc) {
                return false
            }
            buf[target] = Tables.letterClass(base: renderLetters[target].base, mark: .circumflex)
            return SyllableValidator.isValidSyllable(classes: buf, count: count, tone: tone, teencode: tc)
        }
        guard ok else { return false }
        renderLetters[target].mark = .circumflex
        return true
    }

    // MARK: - Incremental parse (one fold step per key)

    /// Rebuild the whole parse state by replaying every raw key. Used by backspace
    /// (raw changed non-append) and mid-word parse-setting flips; identical to the
    /// incremental path because the parse is a pure left-to-right fold.
    /// Rebuild reproducing what forward typing PUT ON SCREEN for the current raw
    /// keys + freeze state: keys replay faithfully (a cancelled tone stays a
    /// cancel), then — only if the frozen word still carries a pending tone — a
    /// second pass folds the tone keys to literals, exactly like feed() did at the
    /// freeze site. One-pass for the common cases; the second pass is ⌫-only cost.
    private mutating func rebuildFrozenAware() {
        rebuildParseState()
        tonesFolded = false
        if disabledAtCount != Int.max, pTone != .none, !freezeKeepsTone {
            pFoldTones = true
            rebuildParseState()
            pFoldTones = false
            tonesFolded = true
        }
    }

    /// Circumflex the doubler's target letter. An `o` target inside the ươ cluster
    /// (a u right before it that carries the horn — typed "uwo", "uwow" or reached
    /// through render's ươ mirroring) takes the u's horn off too: ươ → uô, never the
    /// invalid "ưô" ("lươn" + o → "luôn", "lượn" + o → "luộn": the tone stays, on ô).
    /// That is UniKey's behaviour for the hat key on ươ.
    private mutating func setCircumflex(_ k: Int) {
        letters[k].mark = .circumflex
        if letters[k].base == UInt8(ascii: "o"), k >= 1,
           letters[k - 1].base == UInt8(ascii: "u"), letters[k - 1].mark == .horn {
            letters[k - 1].mark = .none
        }
    }

    /// True when the contiguous vowel nucleus ending at `end` already carries a horn
    /// (`ư` or `ơ`). Vietnamese never combines `ư`/`ơ` with `â`/`ê` in one nucleus, so
    /// `a`/`e` doublers after a horned vowel stay literal (`uwfaaa` → `ừaaa`,
    /// `owfaaa` → `ờaaa`) while `o` still swaps `ơ`/`ươ` → `ô`/`uô`.
    @inline(__always)
    private func nucleusHasHornVowel(endingAt end: Int) -> Bool {
        var j = end
        while j >= 0 && isVowelAscii(letters[j].base) {
            if letters[j].mark == .horn { return true }
            j -= 1
        }
        return false
    }

    /// Recompute the live-spell-check freeze point (`disabledAtCount`) from scratch by
    /// replaying the word one key at a time — exactly what forward typing computed
    /// incrementally. Needed whenever the freeze can no longer be extended from the
    /// previous state: ⌫ (the word SHRANK — lifting the freeze permanently re-applied
    /// transforms retroactively, frozen "installer" ⌫ became "intálle") and a mid-word
    /// `liveSpellCheck` flip (the flag's verdict covers the whole word). The replay is
    /// bounded (≤32 keys, parseStep is ~ns) and never runs on the hot per-key path.
    /// Leaves the parse state built for the FULL word but possibly not fold-aware —
    /// callers must follow with `rebuildFrozenAware()`.
    private mutating func recomputeFreeze() {
        let full = rawCount
        disabledAtCount = Int.max
        freezeKeepsTone = false
        upperToneFrozen = false
        initialsSplitAt = -1
        var r = 1
        while r <= full {
            rawCount = r
            rebuildParseState()
            // feed()'s upper-case tone freeze (mixed-case English/code), checked BEFORE
            // spell-check exactly like forward typing and independent of it. Nothing
            // lifts it, so the replay stops here: "VieeJt" ⌫ → "VieeJ", not "Việ".
            if disabledAtCount == Int.max, forceRestoreUpperTone {
                disabledAtCount = 0
                upperToneFrozen = true
                break
            }
            if !liveSpellCheck {
                r += 1
                continue
            }
            if disabledAtCount == Int.max, pCount > 0, !prefixIsValid(pCount) {
                // Same teencode-elongation escape forward typing applies. render()
                // fills `renderLetters` for the split check; every buffer it touches is
                // rebuilt by the caller's `rebuildFrozenAware()` + `render()` after.
                let n = render()
                if elongationHeadCount(pCount, tone: pTone) <= 0 {
                    // Eager English restore decides on exactly what forward typing saw
                    // at this key (raw[0..<r] + its render), so the replay agrees.
                    if eagerRestoreApplies(n) {
                        disabledAtCount = 0
                    } else if pTone != .none, prefixKeepsTone(r - 1) {
                        // Same keep-the-marked-word rule as feed() (PR #133).
                        disabledAtCount = r - 1
                        freezeKeepsTone = true
                    } else {
                        disabledAtCount = r
                    }
                }
            } else if eagerEnglishRestore, disabledAtCount != Int.max, disabledAtCount > 0,
                      disabledAtCount < EnglishFreezePrefixes.minLength,
                      r == EnglishFreezePrefixes.minLength {
                // Deferred twin of feed(): render what forward typing showed at key 4
                // (fold-aware, like the frozen word on screen) and decide there.
                rebuildFrozenAware()
                let n = render()
                if eagerRestoreApplies(n) { disabledAtCount = 0 }
            }
            // feed()'s elongation UNFREEZE, at the same key it fires on (a key that
            // repeats the previous one byte-for-byte): a freeze the extra characters
            // have since EXPLAINED is lifted — "quafa" freezes on the first stray 'a',
            // the second turns the tail into an elongation ("quàaa"). Replayed per key,
            // not once on the whole word: forward typing may lift the freeze mid-word
            // and later re-freeze for an upper-case tone key ("Ynnn"+S → "YnnnS"), and
            // it never lifts on a case-differing repeat ("ASUU"+u stays "ASUUu").
            if disabledAtCount != Int.max, r >= 2, raw[r - 1] == raw[r - 2] {
                let frozenAt = disabledAtCount
                disabledAtCount = Int.max
                rebuildParseState()
                _ = render()
                if elongationHeadCount(pCount, tone: pTone) <= 0 {
                    disabledAtCount = frozenAt
                } else {
                    freezeKeepsTone = false
                }
            }
            r += 1
        }
        rawCount = full
    }

    /// Kept-tone freeze test (PR #133). True when the word typed by the first `n` raw
    /// keys — what the screen showed before key `n` broke it — carries a Vietnamese
    /// LETTER mark (đ ư ơ â ê ô ă) AND a VISIBLE tone, and key `n`, parsed normally,
    /// only APPENDS one character to that display. Then the word is kept as shown and
    /// key `n` onward is typed literally ("được"+u → "đượcu", "người"+w → "ngườiw").
    /// - A tone render dropped (huyền/hỏi/ngã on a stop coda: "chả"+a+c shows
    ///   "châc") is not on screen: folding it loses nothing the user saw and brings
    ///   the English letter back ("character", "arkansas", "software" unchanged).
    /// - A key that visibly re-shaped the word is a deliberate Telex gesture, not an
    ///   append: "coấ"+a (aaa cancel → "cóaa", teencode "cosaaa"), "chế"+e
    ///   ("cheese" → "chée") keep their historical fold.
    /// Freeze-time only (once per word): replays + renders the prefix and the full
    /// word, leaving the parse state built for the full `rawCount` (callers re-render).
    /// No allocation.
    private mutating func prefixKeepsTone(_ n: Int) -> Bool {
        let full = rawCount
        rawCount = n
        rebuildParseState()
        var keep = false
        var shown = 0
        var sig = 0
        if pTone != .none {
            for k in 0..<pCount where letters[k].mark != .none { keep = true; break }
            if keep {
                shown = render()
                keep = lastEffTone != .none
                sig = scratchSignature(shown)
            }
        }
        rawCount = full
        rebuildParseState()
        if keep {
            keep = render() == shown + 1 && scratchSignature(shown) == sig
        }
        return keep
    }

    /// Order-sensitive digest of the first `n` rendered scalars (n ≤ 32).
    private func scratchSignature(_ n: Int) -> Int {
        var h = 0
        for k in 0..<n { h = h &* 1_000_003 &+ Int(scratch[k]) }
        return h
    }

    private mutating func rebuildParseState() {
        pCount = 0
        pTone = .none
        pToneKeyCount = 0
        pCancelled = false
        pToneCancelAt = -1
        pToneCancelSpan = 0
        pMarkCancelReachedBack = false
        upperToneKey = false
        pFreeMarking = freeMarking
        pSimpleTelex = simpleTelex
        pQuickTelex = quickTelex
        pVniMode = vniMode
        pBracketVowels = bracketVowels
        pLiveSpellCheck = liveSpellCheck
        pFreezeLetters = -1
        for i in 0..<rawCount { rawLetter[i] = -1 }
        for i in 0..<rawCount { parseStep(i) }
        pProcessed = rawCount
    }

    /// Fold raw key `at` into the parse state (`letters`, `pTone`, provenance…).
    /// This is the single-key body of the historical whole-word parse loop; feeding
    /// keys one at a time through it is equivalent to re-parsing the word.
    /// Bracket → the horned vowel it types, or nil. `{`/`}` are the shifted keys, so
    /// they carry the uppercase flag. Pure + static so both `feed`'s gate and the parse
    /// read one definition.
    static func bracketVowel(_ key: UInt8) -> (base: UInt8, upper: Bool)? {
        switch key {
        case UInt8(ascii: "["): return (UInt8(ascii: "o"), false)   // ơ
        case UInt8(ascii: "]"): return (UInt8(ascii: "u"), false)   // ư
        case UInt8(ascii: "{"): return (UInt8(ascii: "o"), true)    // Ơ
        case UInt8(ascii: "}"): return (UInt8(ascii: "u"), true)    // Ư
        default: return nil
        }
    }

    private mutating func parseStep(_ at: Int) {
        let key = raw[at]
        let lower = lowercased(key)
        let upper = isUpperAscii(key)
        if at == disabledAtCount { pFreezeLetters = pCount }

        // (The historical pWWord "leading w = English word" guard is GONE — it
        // blocked the teencode w-forms in Simple Telex ("wá" = quá, "wó"…). English
        // w-words are protected by englishExceptions + auto-restore instead.)

        // Once a diacritic has been cancelled, the word is English: every further
        // key is literal (no tone/mark), so "messs"→mess (not "més") and the whole
        // token stays as typed. The cancel itself is handled by the branches below,
        // which set `pCancelled`; from the next key on this short-circuits.
        // Cancelled diacritic, OR live spell-check froze the word from here on:
        // emit every remaining key literally (no tone/mark transforms) — UNLESS
        // this 'd' continues a bare-consonant abbreviation prefix (VNĐ, HTĐ,
        // HĐND…), where dd→Đ must still fire (see abbreviationDoublerException).
        if pCancelled || (at >= disabledAtCount && !abbreviationDoublerException(lower: lower, upper: upper)) {
            appendLetter(base: lower, mark: .none, upper: upper)
            rawLetter[at] = pCount - 1
            return
        }

        // Bracket vowels (opt-in): `[`→ơ, `]`→ư, `{`/`}` uppercase. Emitted as a
        // FINISHED horned letter, not as an o+w pair — one keystroke, one letter, so ⌫
        // removes the whole vowel and ươ words compose from the letters themselves
        // ("tr" + ] + [ + "ng" → letters t,r,ư,ơ,n,g = trương, no propagation needed).
        // AFTER the freeze/cancel branch above on purpose: in a word already frozen as
        // English/code the bracket must stay the literal character it is.
        if pBracketVowels, let bracket = Self.bracketVowel(key) {
            appendLetter(base: bracket.base, mark: .horn, upper: bracket.upper)
            rawLetter[at] = pCount - 1
            return
        }

        // VNI: letters literal, digits carry the diacritics. Separate fold entirely —
        // none of the Telex letter transforms (tone letters, w, doublers, dd) apply.
        if pVniMode {
            parseStepVNI(at, key: key, lower: lower, upper: upper)
            return
        }

        // Tone keys: s f r x j
        if let t = toneForKey(lower) {
            // Second pass of a frozen-word rebuild with a PENDING tone: every
            // tone key folds back to its literal letter, even those typed BEFORE
            // the freeze point — a tone has no meaning on a non-Vietnamese word,
            // and keeping it made "installer" render "intáller" (the early s
            // floated as sắc onto the post-freeze a). Gated on pFoldTones (not the
            // freeze itself): a rebuild of a frozen word must otherwise replay
            // history faithfully — in particular a CANCELLED tone stays cancelled,
            // see pFoldTones.
            if pFoldTones {
                appendLetter(base: lower, mark: .none, upper: upper)
                rawLetter[at] = pCount - 1
                return
            }
            if hasVowel(pCount) {
                if pTone == t {
                    pTone = .none // double same tone -> cancel, emit literal
                    pCancelled = true; pToneCancelAt = at
                pToneCancelSpan = pToneKeyCount > 0 ? at - toneKeys[pToneKeyCount - 1] : 1
                    appendLetter(base: lower, mark: .none, upper: upper)
                    rawLetter[at] = pCount - 1
                    // The canceled tone's ORIGINAL key(s) are orphaned now: with no
                    // tone, render mapped them to the LAST letter of the word — so
                    // a later ⌫ on an unrelated trailing letter dragged them out of
                    // raw too, and the re-parse RESURRECTED the tone ("airrw" ⌫
                    // gave ải instead of air — tester bug 2026-07-23). Pair them
                    // with this literal letter instead: ⌫ on the displayed 'r'
                    // removes both r keys, ⌫ on anything else leaves them alone.
                    for j in 0..<pToneKeyCount where rawLetter[toneKeys[j]] == -1 {
                        rawLetter[toneKeys[j]] = pCount - 1
                    }
                    pToneKeyCount = 0
                } else if stopCodaRejectsTone(t) {
                    // OpenKey (`if !isChanged insertKey`): huyền/hỏi/ngã on a
                    // stop coda are a no-op — render() would drop them and the
                    // key vanished ("sec"+"r" stayed "sec", so "secret" needed
                    // a doubled r). Type the letter instead. Tone-THEN-coda
                    // ("baft"→bat) still drops at render: the tone was legal
                    // when typed.
                    appendLetter(base: lower, mark: .none, upper: upper)
                    rawLetter[at] = pCount - 1
                } else {
                    pTone = t
                    // English/code signal ONLY when a lowercase letter came BEFORE
                    // this uppercase tone key (camelCase: "OmS"). If the uppercase
                    // tone key is first / precedes any lowercase ("OSm", "VIEEJT"),
                    // it's just a capital, so keep the tone ("OSm"→Óm).
                    if upper && hasLowercaseBefore(at) { upperToneKey = true }
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
                // NOT pCancelled: z là lệnh "xóa dấu" tường minh của Telex, khác cử
                // chỉ gõ-đúp (ss/ff) = "từ này tiếng Anh". Latch pCancelled từng
                // khóa mọi dấu sau z: "tooiszs" ra "tôis" thay vì "tối" (issue #78,
                // 11/09/2026). Giữ pToneCancelAt/Span cho provenance ⌫.
                pToneCancelAt = at
                pToneCancelSpan = pToneKeyCount > 0 ? at - toneKeys[pToneKeyCount - 1] : 1
                pTone = .none
                if upper && hasLowercaseBefore(at) { upperToneKey = true }
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
            // whose immediate predecessor is a REAL 'u' vowel retargets to that u.
            // If that typed u is already horned, the same retarget lets a second w
            // CANCEL ư (huaw→hưa, huaww→huaw) instead of breving the leftover a
            // (hưă). A standalone-w ư is not a typed u — leave it so waw→ưă.
            // Excludes the "qu" glide ("quatw"→quăt) and "oa" (→ oă:
            // hoăc), where breve on a is correct. Makes marks order-free:
            // "nuawx" and "nuwax" both give "nữa".
            if tIdx >= 1,
               letters[tIdx].base == UInt8(ascii: "a"), letters[tIdx].mark == .none,
               letters[tIdx - 1].base == UInt8(ascii: "u"),
               uaUuPredecessorAllowsRetarget(tIdx - 1),
               !(tIdx >= 2 && letters[tIdx - 2].base == UInt8(ascii: "q")) {
                tIdx -= 1
            }
            // "uu" nucleus: w horns the FIRST u (→ ưu: lưu, cứu, hưu) — "uư" is not
            // a valid Vietnamese nucleus, so "luuw"→lưu / "cuuws"→cứu instead of
            // the useless "luư". A second w cancels the same way ("luuww"→luuw).
            // Same standalone-w guard (wuw→ưư) and "qu" exclusion.
            if tIdx >= 1,
               letters[tIdx].base == UInt8(ascii: "u"), letters[tIdx].mark == .none,
               letters[tIdx - 1].base == UInt8(ascii: "u"),
               uaUuPredecessorAllowsRetarget(tIdx - 1),
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
                // Hat → hook/breve swap: w on a circumflexed â/ô REPLACES
                // the hat instead of typing a literal w — "caamw"/"cấmw"→cắm,
                // "tooiw"→tơi, "muoonw"→mươn (render mirrors the horn onto the u).
                // The tone stays where it was. Issue #149 (05/11/2026).
                if p.mark == .circumflex && p.base == UInt8(ascii: "a") {
                    letters[tIdx].mark = .breve; rawLetter[at] = tIdx; return
                }
                if p.mark == .circumflex && p.base == UInt8(ascii: "o") {
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
                    // The ư was CREATED by a standalone w (full Telex, no typed u
                    // behind it): cancelling reverts the letter ITSELF to a
                    // literal w — w→ư, ww→w, www→ww (user decision 2026-07-22).
                    // A 'w' letter is never a horn target, so the third w
                    // appends literally with no extra state. A "uw"-typed horn
                    // keeps the classic revert (uww→uw).
                    if p.base == UInt8(ascii: "u"), letterCreatedByW(tIdx) {
                        letters[tIdx].base = UInt8(ascii: "w")
                        rawLetter[at] = tIdx
                        return
                    }
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
            // (type `uw` for ư). Full Telex converts, including word-initial w
            // (English w-words recover via englishExceptions + auto-restore).
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
                if p.base == lower && p.mark == .none,
                   lower == UInt8(ascii: "o") || !nucleusHasHornVowel(endingAt: pIdx) {
                    setCircumflex(pIdx); rawLetter[at] = pIdx; return
                }
                // `o` on a HORNED o (ơ, the ươ cluster): hook → hat, UniKey-style —
                // "mơ"+o → mô, "luwowo" → luô (the ư loses its horn with it, see
                // setCircumflex). A horned o is otherwise never an o-doubler target.
                if lower == UInt8(ascii: "o"), p.base == lower, p.mark == .horn {
                    setCircumflex(pIdx); rawLetter[at] = pIdx; return
                }
                // Same swap for `a` on ă: breve → hat ("awa"→â, "cawsa"→cấ). Issue #149.
                if lower == UInt8(ascii: "a"), p.base == lower, p.mark == .breve,
                   !nucleusHasHornVowel(endingAt: pIdx) {
                    setCircumflex(pIdx); rawLetter[at] = pIdx; return
                }
                if p.base == lower && p.mark == .circumflex {
                    letters[pIdx].mark = .none
                    pCancelled = true
                    appendLetter(base: lower, mark: .none, upper: upper)
                    rawLetter[at] = pCount - 1; return
                }
            }
            // Free mode ("bỏ dấu tự do"): reach back over a consonant coda AND
            // across the whole NUCLEUS (contiguous vowel run) to circumflex an
            // earlier bare same-vowel — "ama"→âm, "coto"→côt, and since 1.3.1 also
            // "daua"→dâu / "dauas"→dấu (the doubling `a` crosses the `u`, matching
            // UniKey's free-marking). The scan never crosses into the onset
            // (consonant boundary), so qu/gi glides and English words stay safe
            // ("quao" stays literal). Strict mode skips all of this: "ama"/"coto"/
            // "data"/"daua" stay as typed.
            if freeMarking {
                var k = pCount - 1
                while k >= 0 && !isVowelAscii(letters[k].base) { k -= 1 }   // skip coda
                let nucleusEnd = k
                let hornBlocksCircumflex = lower != UInt8(ascii: "o")
                    && nucleusHasHornVowel(endingAt: nucleusEnd)
                while !hornBlocksCircumflex, k >= 0, isVowelAscii(letters[k].base) { // walk nucleus
                    // "lươn" + o → "luôn": the reach-back also turns a
                    // horned o into ô — same hook→hat retarget as the adjacent case
                    // (and the same oeo/oao guard below).
                    if letters[k].base == lower,
                       letters[k].mark == .none
                           || (lower == UInt8(ascii: "o") && letters[k].mark == .horn)
                           || (lower == UInt8(ascii: "a") && letters[k].mark == .breve) {
                        // "oeo"/"oao" are REAL rimes (ngoèo, khoèo, ngoáo): an `o`
                        // that would fold ACROSS the middle bare e/a is the user
                        // typing the rime's last vowel, not a circumflex — issue
                        // #58 25/08/2026 ("ngoeof" came out "ngồe"). Literal wins
                        // in exactly that shape: contiguous run at the word's end
                        // (no coda skipped), one intervening bare e/a. Everything
                        // else keeps the 1.3.1 fold ("daua"→dâu, "coio"→côi).
                        if lower == UInt8(ascii: "o"),
                           nucleusEnd == pCount - 1, k == pCount - 2,
                           letters[k + 1].mark == .none,
                           letters[k + 1].base == UInt8(ascii: "e")
                               || letters[k + 1].base == UInt8(ascii: "a") {
                            break                                    // → literal o
                        }
                        setCircumflex(k); rawLetter[at] = k; return
                    }
                    // Cancel mirror of the reach-back (tester bug 2026-07-23):
                    // "theme"→thêm, then a third e must UNDO the mark and go
                    // literal — "theme" — exactly like the adjacent "ee" cancel.
                    // Without this the e appended ("thême") and boundary
                    // auto-restore emitted the raw keys: "themee".
                    if letters[k].base == lower, letters[k].mark == .circumflex {
                        letters[k].mark = .none
                        pCancelled = true
                        pMarkCancelReachedBack = true
                        appendLetter(base: lower, mark: .none, upper: upper)
                        rawLetter[at] = pCount - 1; return
                    }
                    k -= 1
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
            // so "did"->đi, "dand"->đan, "duwowngd"->đường even without doubling
            // at the start. FREE MARKING ONLY (user decision 2026-07-22): with
            // strict placement off…on, "did"/"dand" must stay literal English.
            if freeMarking, pCount > 1,
               letters[0].base == UInt8(ascii: "d"), letters[0].mark == .none {
                letters[0].mark = .bar; rawLetter[at] = 0; return
            }
            // Cancel mirror: "did"→đi, then a third d undoes the bar and goes
            // literal ("did"), same family as the circumflex reach-back cancel.
            if freeMarking, pCount > 1,
               letters[0].base == UInt8(ascii: "d"), letters[0].mark == .bar,
               letters[pCount - 1].base != UInt8(ascii: "d") {
                letters[0].mark = .none
                pCancelled = true
                appendLetter(base: UInt8(ascii: "d"), mark: .none, upper: upper)
                rawLetter[at] = pCount - 1; return
            }
            appendLetter(base: UInt8(ascii: "d"), mark: .none, upper: upper)
            rawLetter[at] = pCount - 1
            return
        }

        // Quick Telex: doubled onset consonant → digraph (cc→ch, gg→gi, kk→kh,
        // nn→ng, qq→qu, pp→ph, tt→th). Word-initial pair ONLY (pCount == 1): the
        // targets are onset digraphs, and the guard keeps mid-word doubles
        // ("occur", "running") literal. The second letter's case carries over
        // ("Cc"→"Ch", "CC"→"CH"). No special revert: a literal word-initial
        // double is vanishingly rare and auto-restore returns the raw keys.
        if quickTelex, pCount == 1,
           letters[0].base == lower, letters[0].mark == .none,
           let second = Self.quickTelexSecond(lower) {
            appendLetter(base: second, mark: .none, upper: upper)
            rawLetter[at] = pCount - 1
            return
        }

        // ordinary letter
        appendLetter(base: lower, mark: .none, upper: upper)
        rawLetter[at] = pCount - 1
    }

    /// VNI fold step. LETTERS are always literal (case preserved); DIGITS carry the
    /// diacritics. A digit only transforms when it can apply — otherwise it's a literal
    /// digit, so numbers ("mp3", years, "A4") survive. Reuses the SAME tone-deferral
    /// (`pTone`/`toneKeys`), mark-on-letter, cancel and `rawLetter` machinery as Telex,
    /// so tone placement, ươ propagation, boundary restore and backspace all just work.
    private mutating func parseStepVNI(_ at: Int, key: UInt8, lower: UInt8, upper: Bool) {
        // Non-digit → literal letter. (No Telex transforms in VNI.)
        guard isDigit(key) else {
            appendLetter(base: lower, mark: .none, upper: upper)
            rawLetter[at] = pCount - 1
            return
        }

        // Frozen-rebuild with a pending tone: fold the tone digit back to a literal
        // digit (mirrors the Telex tone branch's pFoldTones path).
        if pFoldTones, Self.vniTone(key) != nil {
            appendLetter(base: key, mark: .none, upper: false)
            rawLetter[at] = pCount - 1
            return
        }

        // Tone digits 1-5. Deferred onto the toned vowel at render (rawLetter = -1),
        // exactly like a Telex s/f/r/x/j. Same digit again cancels (→ literal digit).
        if let t = Self.vniTone(key) {
            if hasVowel(pCount) {
                if pTone == t {
                    pTone = .none
                    pCancelled = true; pToneCancelAt = at
                pToneCancelSpan = pToneKeyCount > 0 ? at - toneKeys[pToneKeyCount - 1] : 1
                    appendLetter(base: key, mark: .none, upper: false)
                    rawLetter[at] = pCount - 1
                    for j in 0..<pToneKeyCount where rawLetter[toneKeys[j]] == -1 {
                        rawLetter[toneKeys[j]] = pCount - 1
                    }
                    pToneKeyCount = 0
                } else if stopCodaRejectsTone(t) {
                    appendLetter(base: key, mark: .none, upper: false)
                    rawLetter[at] = pCount - 1
                } else {
                    pTone = t
                    rawLetter[at] = -1
                    toneKeys[pToneKeyCount] = at; pToneKeyCount += 1
                }
            } else {                                    // no vowel to tone → literal digit
                appendLetter(base: key, mark: .none, upper: false)
                rawLetter[at] = pCount - 1
            }
            return
        }

        // 0 → clear tone (like Telex z): consume only when there's a tone to remove.
        if key == UInt8(ascii: "0") {
            if pTone != .none {
                // Cùng luật với Telex z (issue #78): 0 xóa dấu, dấu sau đó vẫn gõ được.
                pToneCancelAt = at
                pToneCancelSpan = pToneKeyCount > 0 ? at - toneKeys[pToneKeyCount - 1] : 1
                pTone = .none
                rawLetter[at] = -1
                toneKeys[pToneKeyCount] = at; pToneKeyCount += 1
            } else {
                appendLetter(base: key, mark: .none, upper: false)
                rawLetter[at] = pCount - 1
            }
            return
        }

        // Mark digits 6/7/8/9. Scan back to the nearest applicable letter (VNI types
        // the digit right after its target; reach-back over a coda handles "viet6"→việt
        // and onset-d "d…9"→đ). Same digit again on an already-marked target cancels.
        if let mark = Self.vniMark(key) {
            var k = pCount - 1
            while k >= 0 {
                if Self.vniMarkAccepts(base: letters[k].base, mark: mark) {
                    // "uu" nucleus: 7 (horn) đặt lên chữ u ĐẦU (→ ưu: lưu, cứu, hưu)
                    // — "uư" không phải nhân âm tiếng Việt. Cùng luật với w-handler
                    // Telex ("luuw"→lưu, "luuww"→luuw): predecessor u may already
                    // be horned so the second 7 CANCELS that ư ("luu77"→luu7), and
                    // cancel must use `target` not `k` or the leftover u gets
                    // horned instead. Cùng ngoại lệ "qu". Issue #66 (29/08/2026).
                    var target = k
                    if mark == .horn, target >= 1,
                       letters[target].base == UInt8(ascii: "u"), letters[target].mark == .none,
                       letters[target - 1].base == UInt8(ascii: "u"),
                       !(target >= 2 && letters[target - 2].base == UInt8(ascii: "q")) {
                        target -= 1
                    }
                    if letters[target].mark == .none {
                        letters[target].mark = mark
                        rawLetter[at] = target
                        return
                    }
                    if letters[target].mark == mark {   // re-applied → cancel, literal digit
                        letters[target].mark = .none
                        pCancelled = true
                        appendLetter(base: key, mark: .none, upper: false)
                        rawLetter[at] = pCount - 1
                        return
                    }
                    // Hat ↔ hook/breve swap (Telex w/aa/oo twin, issue #149): 8 on â →
                    // ă, 6 on ă → â, 7 on ô → ơ, 6 on ơ → ô (ươ → uô via setCircumflex).
                    // The tone stays. 7 never targets a, 8 never o, so the scan only
                    // lands here on a real swap.
                    if letters[target].mark != .bar {
                        if mark == .circumflex { setCircumflex(target) } else { letters[target].mark = mark }
                        rawLetter[at] = target
                        return
                    }
                    break                                // conflicting mark → literal digit
                }
                k -= 1
            }
            appendLetter(base: key, mark: .none, upper: false)
            rawLetter[at] = pCount - 1
            return
        }

        // Any other digit → literal.
        appendLetter(base: key, mark: .none, upper: false)
        rawLetter[at] = pCount - 1
    }

    /// VNI tone digit → Tone (1 sắc, 2 huyền, 3 hỏi, 4 ngã, 5 nặng). nil otherwise.
    @inline(__always)
    private static func vniTone(_ d: UInt8) -> Tone? {
        switch d {
        case UInt8(ascii: "1"): return .acute
        case UInt8(ascii: "2"): return .grave
        case UInt8(ascii: "3"): return .hook
        case UInt8(ascii: "4"): return .tilde
        case UInt8(ascii: "5"): return .dot
        default:                return nil
        }
    }

    /// VNI mark digit → Mark (6 circumflex, 7 horn, 8 breve, 9 bar/đ). nil otherwise.
    @inline(__always)
    private static func vniMark(_ d: UInt8) -> Mark? {
        switch d {
        case UInt8(ascii: "6"): return .circumflex
        case UInt8(ascii: "7"): return .horn
        case UInt8(ascii: "8"): return .breve
        case UInt8(ascii: "9"): return .bar
        default:                return nil
        }
    }

    /// Which base letters a VNI mark can attach to: circumflex→a/e/o, horn→o/u,
    /// breve→a, bar→d.
    @inline(__always)
    private static func vniMarkAccepts(base: UInt8, mark: Mark) -> Bool {
        switch mark {
        case .circumflex: return base == UInt8(ascii: "a") || base == UInt8(ascii: "e") || base == UInt8(ascii: "o")
        case .horn:       return base == UInt8(ascii: "o") || base == UInt8(ascii: "u")
        case .breve:      return base == UInt8(ascii: "a")
        case .bar:        return base == UInt8(ascii: "d")
        case .none:       return false
        }
    }

    /// Quick-Telex digraph table: the letter the SECOND key of a doubled onset
    /// consonant becomes (cc→c+h, gg→g+i, …). nil = not a Quick-Telex consonant.
    @inline(__always)
    private static func quickTelexSecond(_ c: UInt8) -> UInt8? {
        switch c {
        case UInt8(ascii: "c"), UInt8(ascii: "k"), UInt8(ascii: "p"), UInt8(ascii: "t"):
            return UInt8(ascii: "h")
        case UInt8(ascii: "g"): return UInt8(ascii: "i")
        case UInt8(ascii: "n"): return UInt8(ascii: "g")
        case UInt8(ascii: "q"): return UInt8(ascii: "u")
        default: return nil
        }
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

    /// Does the syllable end in a stop coda (-p, -t, -c, -ch, -k)? Such codas only
    /// allow sắc/nặng. Only meaningful when a vowel precedes (checked by caller).
    /// Reads the render copy (post-propagation state).
    /// `-k` is in here to stay in lockstep with `SyllableValidator.toneMask`, which
    /// also treats it as a stop (the ak/ăk/ưk rimes: Đắk, Lắk). Without it "bakf"
    /// rendered "bàk" and got auto-restored at the boundary instead of silently
    /// dropping the invalid huyền like "batf"→"bat".
    /// Vần teencode "ưk" (ừk/hừk — 19/08/2026): ư (u+horn) ngay trước coda k.
    /// Ngoại lệ DUY NHẤT cho luật stop-coda-chặn-huyền; lockstep với mask huyền-only
    /// của "ưk" trong SyllableValidator.toneMask.
    @inline(__always)
    private func isUkRime(_ count: Int) -> Bool {
        count >= 2 && renderLetters[count - 1].base == UInt8(ascii: "k")
            && renderLetters[count - 2].base == UInt8(ascii: "u")
            && renderLetters[count - 2].mark == .horn
    }

    @inline(__always)
    private func hasStopCoda(_ count: Int) -> Bool {
        guard count > 0 else { return false }
        let last = renderLetters[count - 1].base
        if last == UInt8(ascii: "p") || last == UInt8(ascii: "t")
            || last == UInt8(ascii: "c") || last == UInt8(ascii: "k") {
            return true
        }
        // "ch" coda: trailing h preceded by c.
        if last == UInt8(ascii: "h"), count >= 2, renderLetters[count - 2].base == UInt8(ascii: "c") {
            return true
        }
        return false
    }

    /// Parse-time twin of `hasStopCoda` — `renderLetters` is stale inside parseStep.
    @inline(__always)
    private func lettersHaveStopCoda(_ count: Int) -> Bool {
        guard count > 0 else { return false }
        let last = letters[count - 1].base
        if last == UInt8(ascii: "p") || last == UInt8(ascii: "t")
            || last == UInt8(ascii: "c") || last == UInt8(ascii: "k") {
            return true
        }
        if last == UInt8(ascii: "h"), count >= 2, letters[count - 2].base == UInt8(ascii: "c") {
            return true
        }
        return false
    }

    /// Parse-time twin of `isUkRime`.
    @inline(__always)
    private func lettersAreUkRime(_ count: Int) -> Bool {
        count >= 2 && letters[count - 1].base == UInt8(ascii: "k")
            && letters[count - 2].base == UInt8(ascii: "u")
            && letters[count - 2].mark == .horn
    }

    /// True when applying `tone` now would be silently dropped by render()
    /// (huyền/hỏi/ngã on a stop coda, except ừk). The key should be a letter.
    @inline(__always)
    private func stopCodaRejectsTone(_ tone: Tone) -> Bool {
        guard tone == .grave || tone == .hook || tone == .tilde else { return false }
        guard lettersHaveStopCoda(pCount) else { return false }
        if tone == .grave && lettersAreUkRime(pCount) { return false }
        return true
    }

    @inline(__always)
    private mutating func appendLetter(base: UInt8, mark: Mark, upper: Bool) {
        guard pCount < Self.capacity else { return }
        letters[pCount] = LetterUnit(base: base, mark: mark, upper: upper)
        pCount += 1
    }
}

// MARK: - Validator buffer twin (peek path)

private extension SyllableValidator {
    /// Buffer-pointer twin of `isValidSyllable(classes:count:tone:)` — the exact
    /// same deterministic onset split + trie walk, but over a caller-provided
    /// STACK buffer so `composedIsValidSyllable` stays non-mutating and
    /// heap-free (dùng cho cả commit lẫn `peekCommitText` mỗi phím).
    /// Keep in lockstep with the Array version in SyllableValidator.swift.
    static func isValidSyllable(classes: UnsafeMutableBufferPointer<UInt8>,
                                count n: Int, tone: Tone, teencode: Bool) -> Bool {
        if n == 0 { return false }
        // TEENCODE "òy" — lockstep with the Array twin (zero-onset "oy" only).
        if teencode, n == 2, classes[0] == UInt8(ascii: "o") - UInt8(ascii: "a"),
           classes[1] == UInt8(ascii: "y") - UInt8(ascii: "a") {
            return true
        }
        // TEENCODE "-òy" — lockstep with the Array twin (huyền-only, onset g/r/z/dz/ch).
        if teencode, n >= 3, tone == .grave,
           classes[n - 2] == UInt8(ascii: "o") - UInt8(ascii: "a"),
           classes[n - 1] == UInt8(ascii: "y") - UInt8(ascii: "a") {
            let gC = UInt8(ascii: "g") - UInt8(ascii: "a")
            let rC = UInt8(ascii: "r") - UInt8(ascii: "a")
            let zC = UInt8(ascii: "z") - UInt8(ascii: "a")
            let dC = UInt8(ascii: "d") - UInt8(ascii: "a")
            let cC = UInt8(ascii: "c") - UInt8(ascii: "a")
            let hC = UInt8(ascii: "h") - UInt8(ascii: "a")
            if n == 3, classes[0] == gC || classes[0] == rC || classes[0] == zC
                    || classes[0] == hC /* hòy */ { return true }
            if n == 4, (classes[0] == dC && classes[1] == zC)
                    || (classes[0] == cC && classes[1] == hC) { return true }
        }
        // TEENCODE "đou" — lockstep with the Array twin (đúng một từ, xem comment ở đó).
        if teencode, n == 3, tone == .none, classes[0] == 32 /* đ */,
           classes[1] == UInt8(ascii: "o") - UInt8(ascii: "a"),
           classes[2] == UInt8(ascii: "u") - UInt8(ascii: "a") {
            return true
        }
        let onsetT = teencode ? onsetExact : onsetExactStd
        let rimeT = teencode ? rimeExact : rimeExactStd
        let kC = UInt8(ascii: "k") - UInt8(ascii: "a")
        let q = UInt8(ascii: "q") - UInt8(ascii: "a")
        let u = UInt8(ascii: "u") - UInt8(ascii: "a")
        let g = UInt8(ascii: "g") - UInt8(ascii: "a")
        let i = UInt8(ascii: "i") - UInt8(ascii: "a")

        var pos = 0
        while pos < n && !Tables.isVowelClass(classes[pos]) { pos += 1 }
        var onsetEnd = pos
        var quGlide = false
        // qu / gi glide handling ("qu" + vowel: the unmarked u joins the onset).
        if pos >= 1, classes[0] == q, pos < n, classes[pos] == u,
           pos + 1 < n, Tables.isVowelClass(classes[pos + 1]) {
            onsetEnd = pos + 1
            quGlide = true
        } else if n >= 3, classes[0] == g, classes[1] == i, Tables.isVowelClass(classes[2]) {
            onsetEnd = 2
        }

        @inline(__always) func accepts(onsetEnd: Int, rimeStart: Int) -> Bool {
            var node: Int32 = 0
            for k in 0..<onsetEnd {
                node = onsetT.step(node, classes[k])
                if node < 0 { return false }
            }
            guard onsetT.mask(node) != 0 else { return false }
            if !teencode, onsetEnd == 1, classes[0] == kC, rimeStart < n,
               !kOnsetAllows(rimeFirst: classes[rimeStart]) { return false }
            var rnode: Int32 = 0
            for k in rimeStart..<n {
                rnode = rimeT.step(rnode, classes[k])
                if rnode < 0 { return false }
            }
            return (rimeT.mask(rnode) >> tone.rawValue) & 1 == 1
        }

        // Every reading is tried (see the Array twin for why): the qu- glide's u counted
        // twice ("quýt" = qu + uyt), and the plain split as a fallback so the glide
        // reading can't shadow it ("giếc" = g + iêc, not gi + êc).
        if accepts(onsetEnd: onsetEnd, rimeStart: onsetEnd) { return true }
        if quGlide, accepts(onsetEnd: onsetEnd, rimeStart: pos) { return true }
        return onsetEnd != pos && accepts(onsetEnd: pos, rimeStart: pos)
    }
}

// MARK: - ascii helpers

@inline(__always)
func isLetter(_ c: UInt8) -> Bool {
    (c >= UInt8(ascii: "a") && c <= UInt8(ascii: "z")) ||
    (c >= UInt8(ascii: "A") && c <= UInt8(ascii: "Z"))
}

@inline(__always)
func isDigit(_ c: UInt8) -> Bool {
    c >= UInt8(ascii: "0") && c <= UInt8(ascii: "9")
}

@inline(__always)
func isUpperAscii(_ c: UInt8) -> Bool {
    c >= UInt8(ascii: "A") && c <= UInt8(ascii: "Z")
}

@inline(__always)
func lowercased(_ c: UInt8) -> UInt8 {
    isUpperAscii(c) ? c &+ 32 : c
}
