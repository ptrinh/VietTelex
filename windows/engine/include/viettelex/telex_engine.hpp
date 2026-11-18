// VietTelex engine — C++ port of TelexCore/Sources/TelexCore/TelexEngine.swift (1:1,
// behaviour identical, verified against the Swift golden corpus).
//
// Pure C++17, no platform headers, no exceptions, no RTTI, no heap: every buffer is a
// fixed-capacity (32) member array, so a TelexEngine is a plain value (copyable,
// stack-allocatable) and the hot path (feed / backspace / commitBoundary) never
// allocates. Output text is UTF-16 (char16_t); every character the engine emits is a
// precomposed BMP code point, so one UTF-16 unit == one on-screen character.
//
// For the C ABI (TSF TIP / other languages) see vtx_engine.h.
#pragma once
#include <cstddef>
#include <cstdint>
#include <climits>

namespace vtx {

enum class Tone : uint8_t { None = 0, Acute, Grave, Hook, Tilde, Dot };
enum class Mark : uint8_t { None = 0, Circumflex, Breve, Horn, Bar };

/// Max UTF-16 units any engine string can have (32 keys/letters; room to spare).
constexpr int kMaxText = 64;

/// Swift `TelexAction`. `text` is valid (NUL-terminated) for Replace only.
struct Action {
    enum Kind : int32_t { Passthrough = 0, Replace = 1, None = 2 };
    int32_t kind = Passthrough;
    int32_t backspaces = 0;
    int32_t length = 0;             // UTF-16 units in `text`
    char16_t text[kMaxText] = {};
};

/// Swift `RetroCorrection`: one edit that rewrites the words before the caret. Apply like a
/// Replace action: delete `backspaces` UTF-16 units before the caret, insert `insert`.
/// `expected` is what those units are right now (verify against the document if you can).
struct RetroCorrection {
    static constexpr int kMax = 256;
    int32_t backspaces = 0;
    int32_t words = 0;
    int32_t expectedLength = 0;
    int32_t insertLength = 0;
    char16_t expected[kMax] = {};   // NUL-terminated
    char16_t insert[kMax] = {};     // NUL-terminated
    /// Swift `flipBack`: the edit puts a word the frequency rule (englishByFrequency) had
    /// turned English BACK to Vietnamese ("His hửng" -> "hí hửng"). It undoes the engine's
    /// own guess: integrators apply it AUTOMATICALLY even when retroactive English is in
    /// offer-only mode (and before an Enter goes through) — still after the same
    /// text-before-caret check.
    bool flipBack = false;
};

/// Swift `RestoreUndo`: the commit restored a word to its raw keys although its Vietnamese
/// composition was a real syllable ("hí" -> "his", "NÁ" -> "NAS"). An immediate ⌫ may put
/// `vietnamese` back in place of `restored` (the caller's boundary character follows it).
struct RestoreUndo {
    int32_t restoredLength = 0;
    int32_t vietnameseLength = 0;
    char16_t restored[kMaxText] = {};     // NUL-terminated
    char16_t vietnamese[kMaxText] = {};   // NUL-terminated
};

class TelexEngine {
public:
    static constexpr int kCapacity = 32;

    // ---- Settings (Swift property names and ENGINE defaults) --------------------
    bool freeMarking = false;
    bool modernTone = false;
    bool liveSpellCheck = false;
    bool simpleTelex = false;
    bool teencode = true;
    bool quickTelex = false;
    bool bracketVowels = false;
    bool vniMode = false;
    bool contextualEnglish = false;
    bool englishWordRestore = true;
    bool collisionPrefersVietnamese = false;
    /// Swift `eagerEnglishRestore`: at the live-spell-check freeze moment, a raw prefix in
    /// gen::kEnglishFreezePrefixes restores the whole word to raw ("goog", not "gôg").
    /// Callers pass their effective auto-restore. Engine default OFF.
    bool eagerEnglishRestore = false;
    /// Swift `retroactiveEnglish` (EXPERIMENTAL, default OFF): when an English run becomes
    /// certain, collision words composed as Vietnamese right before it are rewritten to their
    /// raw keys ("Hí cả í very fast" -> "His car is very fast"). Inert unless
    /// contextualEnglish is on (and in VNI). See noteBoundaryCharacter / takeRetroCorrection.
    bool retroactiveEnglish = false;
    /// Swift `englishByFrequency` (EXPERIMENTAL, default OFF): at the start of a phrase a
    /// word whose keys are both an English word and a RARE Vietnamese syllable becomes
    /// English when the English word is far more frequent ("His car…"); a following word
    /// that shows the phrase is Vietnamese (reduplication / known pair: "hí hí", "hí hửng")
    /// flips it back through a RetroCorrection with flipBack = true. Inert unless
    /// retroactiveEnglishActive(). Off = one bool test per commit.
    bool englishByFrequency = false;
    /// Swift `autoCircumflex` (issue #166, default OFF) — "Tự thêm dấu mũ": when the word
    /// already has a live tone and the plain rime is not a Vietnamese syllable while the
    /// circumflexed one is, render the circumflex ("vietj"/"viejt" -> việt, "nguyenx" ->
    /// nguyễn, "benhj" -> bệnh, "keuf" -> kều, "hues" -> huế, "luanj" -> luận). Render-only:
    /// parse state is untouched. Off = one bool test per render.
    bool autoCircumflex = false;

    TelexEngine();

    // ---- Keystrokes --------------------------------------------------------------
    /// Feed one typed character (UTF-32). Only ascii letters compose (+ digits in VNI,
    /// + [ ] { } with bracketVowels); anything else -> Passthrough.
    void feed(char32_t ch, Action& out);
    /// Delete the whole last DISPLAYED character.
    void backspace(Action& out);
    /// Word boundary: optional auto-restore; resets the word.
    /// `boundary` = the character ending the word when the caller knows it (0 = unknown,
    /// the old behaviour). An apostrophe restores an English contraction stem ("doesn"
    /// before 't) — Swift commitBoundary(autoRestore:boundary:).
    void commitBoundary(bool autoRestore, Action& out, char32_t boundary = 0);
    /// Final text to commit (restore applied); resets the word. Returns UTF-16 length,
    /// writes at most cap-1 units + NUL.
    int commitText(bool autoRestore, char16_t* buf, int cap, char32_t boundary = 0);
    /// Non-mutating twin of commitText.
    int peekCommitText(bool autoRestore, char16_t* buf, int cap, char32_t boundary = 0) const;

    // ---- State -------------------------------------------------------------------
    int composed(char16_t* buf, int cap) const;
    int rawKeystrokes(char16_t* buf, int cap) const;
    bool isEmpty() const { return rawCount_ == 0; }
    bool isOverflowed() const { return overflowed_; }
    bool previousWordEnglish() const { return previousWordEnglish_; }
    /// Swift `hasSpellingError(autoRestore:)`: the composed word is Vietnamese the engine
    /// produced (differs from the raw keys, not restored at the boundary) and
    /// SyllableValidator::isSpellingError says it cannot be completed into a syllable.
    bool hasSpellingError(bool autoRestore) const;

    void reset();
    void resetContext();

    // ---- Retroactive English correction (Swift retroactiveEnglish) ------------------
    bool retroactiveEnglishActive() const { return retroactiveEnglish && contextualEnglish && !vniMode; }
    bool englishByFrequencyActive() const { return englishByFrequency && retroactiveEnglishActive(); }
    /// The caller inserted boundary character `ch` after a commit (space, punctuation…).
    void noteBoundaryCharacter(char32_t ch);
    /// The edit the last commit decided; true = `out` filled and the caller applies it.
    bool takeRetroCorrection(RetroCorrection& out);
    /// Non-consuming look at the pending edit.
    bool pendingRetroCorrection(RetroCorrection& out) const;

    // ---- Undo of a boundary restore-to-English (Swift takeRestoreUndo) --------------
    /// The ⌫-undo record of the commit that JUST happened; true = `out` filled (consumed).
    /// Valid right after commitBoundary / commitText (and noteBoundaryCharacter); any key,
    /// ⌫, reset or the next commit drops it.
    bool takeRestoreUndo(RestoreUndo& out);
    /// Non-consuming look.
    bool pendingRestoreUndo(RestoreUndo& out) const;
    /// The caller put the Vietnamese word back (⌫ right after a restore): reset + end any
    /// English run.
    void restoreUndoApplied() { reset(); clearEnglishContext(); }

    // ---- Re-open / re-edit -------------------------------------------------------
    void forgetLastCommit() {
        reopenRawCount_ = 0; reopenOutCount_ = 0;
        hasRestoreUndo_ = false;
        clearGlue();
        if (retroCount_ > 0 || retroHasPending_) retroClear();   // text changed under us
    }
    bool canReopenLastCommit() const { return rawCount_ == 0 && reopenRawCount_ > 0; }
    /// Re-open the last committed word. Returns its UTF-16 length, or -1 (nil).
    int reopenLastCommit(char16_t* buf, int cap);
    /// Rebuild state from a word already on screen; true only on exact round-trip.
    bool seed(const char32_t* word, int length);
    bool seed(const char16_t* word, int length);   // UTF-16 (surrogates rejected)

    // ---- Test-only introspection (mirrors the Swift internal debug accessors) ------
    struct CancelState { bool cancelled; int at; int span; };
    CancelState debugCancelSnapshot() const { return {markCancelled_, toneCancelAt_, toneCancelSpan_}; }
    CancelState debugParseCancelState() const { return {pCancelled_, pToneCancelAt_, pToneCancelSpan_}; }
    int debugFreezeAt() const { return disabledAtCount_; }
    /// Swift `spellCheckFreezeAt` (-1 = not frozen; 0 = whole word literal).
    int spellCheckFreezeAt() const { return disabledAtCount_ == kNotDisabled ? -1 : disabledAtCount_; }
    /// Swift `debugRetroHistory`: number of recorded words, and word i's shown text / english.
    int debugRetroCount() const { return retroCount_; }
    int debugRetroShown(int i, char16_t* buf, int cap) const;
    bool debugRetroEnglish(int i) const { return i >= 0 && i < retroCount_ && retroHist_[i].english; }

private:
    struct Letter { uint8_t base = 0; Mark mark = Mark::None; bool upper = false; };
    static constexpr int kNotDisabled = INT_MAX;

    // raw keystrokes (ascii, case preserved)
    uint8_t raw_[kCapacity];
    int rawCount_ = 0;
    bool overflowed_ = false;

    // on-screen composition (scalar values)
    char32_t out_[kCapacity];
    int outCount_ = 0;

    // scratch
    char32_t scratch_[kCapacity];
    Letter renderLetters_[kCapacity];
    uint8_t basesScratch_[kCapacity];
    int rawLetter_[kCapacity];
    int toneKeys_[kCapacity];
    int vowelIdx_[kCapacity];

    // incremental parse state
    Letter letters_[kCapacity];
    int pCount_ = 0;
    Tone pTone_ = Tone::None;
    int pToneKeyCount_ = 0;
    bool pCancelled_ = false;
    int pToneCancelSpan_ = 0;
    int pToneCancelAt_ = -1;
    // A circumflex doubler cancelled a hat it reached back to across letters ("seem" + e).
    bool pMarkCancelReachedBack_ = false;
    int pProcessed_ = 0;
    bool pFreeMarking_ = false;
    bool pSimpleTelex_ = false;
    bool pQuickTelex_ = false;
    bool pVniMode_ = false;
    bool pBracketVowels_ = false;
    bool pLiveSpellCheck_ = false;

    int disabledAtCount_ = kNotDisabled;
    bool markCancelled_ = false;
    int toneCancelAt_ = -1;
    int toneCancelSpan_ = 0;
    bool pFoldTones_ = false;
    bool tonesFolded_ = false;   // current parse built with pFoldTones_ (freeze folded a tone)
    // Kept-tone freeze (PR #133): a marked word + visible tone stays as shown — see Swift.
    bool freezeKeepsTone_ = false;
    int pFreezeLetters_ = -1;    // letter count when the parse reached disabledAtCount_
    Tone lastEffTone_ = Tone::None;
    bool inferredCircumflex_ = false;   // last render added a circumflex (autoCircumflex)
    bool upperToneKey_ = false;
    bool upperToneFrozen_ = false;   // word frozen by feed()'s upper-case tone rule — see Swift
    int initialsSplitAt_ = -1;       // initials suffix start ("PhuwowngTH", issue #138) — see Swift

    // English RUN open (function word, or 2nd English word in a row); a lone content
    // word is only a candidate; gate bits = predecessorGates the previous word satisfies.
    bool previousWordEnglish_ = false;
    bool englishCandidate_ = false;
    uint8_t previousGateBits_ = 0;
    // The last committed word in the phrase was Vietnamese (frequency rule only).
    bool previousWordVietnamese_ = false;

    // re-open snapshot
    uint8_t reopenRaw_[kCapacity];
    char32_t reopenOut_[kCapacity];
    int reopenRawCount_ = 0;
    int reopenOutCount_ = 0;
    bool reopenPrevEnglish_ = false;
    bool reopenCandidate_ = false;
    uint8_t reopenGateBits_ = 0;

    // ⌫-undo of a boundary restore (Swift restoreUndo).
    bool hasRestoreUndo_ = false;
    RestoreUndo restoreUndo_;

    // Glued separators (Swift lastWordKind / noteSinceWord / pendingGlue / wordGlue):
    // 0 none, 1 separator, 2 digit; lastWordKind 0 unknown, 1 VN/capitalized, 2 code-like.
    uint8_t lastWordKind_ = 0;
    bool noteSinceWord_ = true;
    uint8_t pendingGlue_ = 0;
    uint8_t wordGlue_ = 0;
    void noteGlue(char32_t ch);
    void clearGlue() { lastWordKind_ = 0; noteSinceWord_ = true; pendingGlue_ = 0; }
    void noteCommittedWord(bool restored);
    bool glueRestores() const;
    bool isVietnameseTypoKeep() const;
    bool isHatInitialismKeep() const;
    bool rawHasEnglishReading() const;
    bool isRareAllCapsAcronym() const;
    bool rawIsDictionaryWord() const;
    bool isListedCapsAcronym() const;
    bool isContractionStemBeforeApostrophe() const;
    bool rawIsAllCapsToken() const;
    bool lettersAreCommonSyllable(int count) const;

    // retroactive English: history ring (oldest first), spaces since the last commit,
    // the pending edit and the history indices it rewrites.
    struct RetroWord {
        uint8_t raw[kCapacity];
        char32_t shown[kCapacity + 1];
        int rawLen = 0;
        int shownLen = 0;
        bool english = false;
        bool candidate = false;
        uint8_t cls = 0;
        int gap = 0;
        bool leftNonEnglish = false;
        uint8_t gateBit = 0;
        uint8_t predBits = 0;
        bool strong = false;        // strong English (EnglishFrequency: en >= strongMin, vn = 0)
        bool byFrequency = false;   // restored by the frequency rule; alt = its composition
        char32_t alt[kCapacity + 1];
        int altLen = 0;
    };
    static constexpr int kRetroHistory = 6;
    RetroWord retroHist_[kRetroHistory];
    int retroCount_ = 0;
    int retroGap_ = 0;
    bool retroHasPending_ = false;
    RetroCorrection retroPending_;
    int retroPicks_[kRetroHistory] = {};
    int retroPickCount_ = 0;
    void retroClear();
    void retroRecord(bool restored, bool elongated);
    int retroPlan(int* picks) const;
    bool retroAnchors(int a, const int* picks, int np) const;
    bool retroLeftIsNonEnglish(int a) const;
    bool retroBuild(const int* picks, int np, bool flipBack = false);
    // englishByFrequency (Swift "Frequency rule + flip-back")
    bool shouldRestoreRawBase() const;
    bool rawFrequencyScores(uint8_t& en, uint8_t& vn) const;
    bool frequencyPrefersEnglish() const;
    const RetroWord* frequencyRestoredPrevious() const;
    const RetroWord* frequencyRestoredTwoBack() const;
    bool frequencyKeepsVietnamese() const;
    bool frequencyPairEvidence(const RetroWord& prev, bool reduplicationOnly = false) const;
    int appendComposedTelexKey(char* p, int start) const;
    int frequencyFlipDistance(bool restored) const;

    // ---- internals (names follow the Swift source) --------------------------------
    void feedAscii(uint8_t ascii, Action& out);
    void takeSnapshots();
    void captureReopen(bool restored);
    bool needsStandaloneWRunRestore() const;
    bool shouldRestoreRaw(char32_t boundary = 0) const;
    bool composedEndsWithK() const;
    bool composedHasDiacritic() const;
    bool composedIsRecognizedEnglish() const;
    bool isRecognizedEnglish() const;
    enum class WordContext { EnglishFunction, English, Vietnamese, Neutral };
    WordContext classifyWordContext(bool restored) const;
    bool rawIsNeutralLoanword() const;
    void updateContext(bool restored);
    void foldEnglishContentWord();
    void clearEnglishContext();
    bool predecessorGateAllows() const;
    uint8_t rawPredecessorBits() const;
    bool rawIsFunctionWord() const;
    bool rawIsContractionTail() const;
    bool rawIsRunKeeper() const;
    bool rawIsEnglishContextWord(bool includingRestoreOnly = false) const;
    bool rawIsEnglishCollision() const;
    bool rawIsEnglishException() const;
    int teencodeOnset() const;        // 0 none, 1 w->qu, 2 z->d, 3 dz->d
    bool isAbbreviationPrefix(bool upper) const;
    bool abbreviationDoublerException(uint8_t lower, bool upper) const;
    bool composedIsValidSyllable() const;
    int elongationHeadCount(int count, Tone tone) const;
    bool isValidHead(int k, Tone tone, bool plainLast = false) const;
    bool isToneThenATail() const;
    bool isToneKeyAt(int r) const;
    void elongatedTail(char32_t* two) const;
    int emitElongated(char16_t* buf, int cap) const;
    bool isTeencodeKeep() const { return elongationHeadCount(pCount_, lastEffTone_) > 0; }
    bool compositionDiffersFromRaw() const;
    bool compositionHasDiacritic() const;
    bool letterCreatedByW(int idx) const;
    bool uaUuPredecessorAllowsRetarget(int pred) const;
    bool hasLowercaseBefore(int at) const;
    int initialsSplitPoint() const;
    bool headIsInitialsSyllable(int s);
    bool rawHeadIsEnglish(int s) const;
    bool runIsCodeAcronym(int s) const;
    bool applyInitialsSplit();
    void resetWord();
    bool prefixIsValid(int n);
    bool eagerRestoreApplies(int n) const;
    void copyOut(int n);
    int render();
    bool inferCircumflex(int count, Tone tone);
    void rebuildFrozenAware();
    void setCircumflex(int k);
    bool nucleusHasHornVowel(int end) const;
    void recomputeFreeze();
    bool prefixKeepsTone(int n);
    uint64_t scratchSignature(int n) const;
    void rebuildParseState();
    void parseStep(int at);
    void parseStepVNI(int at, uint8_t key, uint8_t lower, bool upper);
    int toneVowelIndex(int count);
    void diff(int newCount, Action& out) const;
    bool standaloneHornUAllowed(int count) const;
    bool hasVowel(int count) const;
    bool isUkRime(int count) const;
    bool hasStopCoda(int count) const;
    bool lettersHaveStopCoda(int count) const;
    bool lettersAreUkRime(int count) const;
    bool stopCodaRejectsTone(Tone tone) const;
    void appendLetter(uint8_t base, Mark mark, bool upper);
    bool composedEquals(const char32_t* word, int length) const;
};

/// SyllableValidator (Swift public API) — string façades over UTF-32 input.
namespace SyllableValidator {
bool isValidSyllable(const char32_t* word, int length, bool teencode = true);
bool isValidPrefix(const char32_t* word, int length, bool teencode = true);
bool isValidSyllable(const uint8_t* classes, int n, Tone tone, bool teencode);
bool isValidPrefix(const uint8_t* bases, int n, bool teencode);
/// Swift `isSpellingError`: the opt-in red-underline decision for a composed word.
bool isSpellingError(const char32_t* word, int length, bool teencode = true);
} // namespace SyllableValidator

/// EnglishContextLookup (TelexCore EnglishContextWords.swift): lowercase ASCII words that
/// are recognized English (the, is, you, people…) — the same table `contextualEnglish` uses.
/// (Since 11/10/2026 the engine opens a run only on a function word or two English words.)
namespace EnglishContextLookup {
bool opensEnglishRun(const char* word, int length);
} // namespace EnglishContextLookup

} // namespace vtx
