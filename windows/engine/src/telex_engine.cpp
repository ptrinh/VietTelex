// Port of TelexCore/Sources/TelexCore/TelexEngine.swift — 1:1, same names, same
// order. See the Swift source for the WHY of every rule (field reports, decisions);
// comments here are kept short on purpose and point at the behaviour only.
#include "viettelex/telex_engine.hpp"
#include "generated_tables.hpp"
#include "tables.hpp"

namespace vtx {

using namespace tables;

namespace {

// English word-list lookup (collisions, context words, restore-only, neutral loanwords).
// -DVTX_NO_ENGLISH_TABLES ("lite" build, e.g. the web SDK's @viettelex/core/lite): every
// lookup misses, so the lists are dropped by the linker. Dictionary features become
// no-ops; Telex/VNI, tones, the syllable validator and validator-based auto-restore are
// untouched. The default build is unchanged.
inline bool inEnglishList(const WordSet& set, const char* w, int len) {
#ifdef VTX_NO_ENGLISH_TABLES
    (void)set; (void)w; (void)len;
    return false;
#else
    return set.contains(w, len);
#endif
}

inline int emit(const char32_t* src, int n, char16_t* buf, int cap) {
    if (!buf || cap <= 0) return n;
    int w = n < cap - 1 ? n : cap - 1;
    for (int i = 0; i < w; ++i) buf[i] = static_cast<char16_t>(src[i]);
    buf[w] = 0;
    return n;
}
inline int emitRaw(const uint8_t* src, int n, char16_t* buf, int cap) {
    if (!buf || cap <= 0) return n;
    int w = n < cap - 1 ? n : cap - 1;
    for (int i = 0; i < w; ++i) buf[i] = static_cast<char16_t>(src[i]);
    buf[w] = 0;
    return n;
}
inline void setReplace(Action& a, int backspaces, const char32_t* s, int n) {
    a.kind = Action::Replace;
    a.backspaces = backspaces;
    a.length = n;
    for (int i = 0; i < n; ++i) a.text[i] = static_cast<char16_t>(s[i]);
    a.text[n] = 0;
}
inline void setSimple(Action& a, int32_t kind) {
    a.kind = kind;
    a.backspaces = 0;
    a.length = 0;
    a.text[0] = 0;
}

/// Lowercase ascii-letter word of `src[0..<count]` into `w`; -1 when some char is not
/// an ascii letter or count is out of (0, maxLen].
template <typename T>
inline int lowerAsciiInto(const T* src, int count, int maxLen, char* w) {
    if (count <= 0 || count > maxLen) return -1;
    for (int i = 0; i < count; ++i) {
        uint32_t b = static_cast<uint32_t>(src[i]);
        if (b >= 'A' && b <= 'Z') b |= 0x20;
        if (b < 'a' || b > 'z') return -1;
        w[i] = static_cast<char>(b);
    }
    return count;
}

// Bracket -> horned vowel it types (base, upper); base 0 = not a bracket.
inline uint8_t bracketBase(uint8_t key, bool& upper) {
    switch (key) {
    case '[': upper = false; return 'o';
    case ']': upper = false; return 'u';
    case '{': upper = true; return 'o';
    case '}': upper = true; return 'u';
    default: return 0;
    }
}

inline Tone vniTone(uint8_t d) {
    switch (d) {
    case '1': return Tone::Acute; case '2': return Tone::Grave; case '3': return Tone::Hook;
    case '4': return Tone::Tilde; case '5': return Tone::Dot;
    default: return Tone::None;
    }
}
inline Mark vniMark(uint8_t d) {
    switch (d) {
    case '6': return Mark::Circumflex; case '7': return Mark::Horn;
    case '8': return Mark::Breve; case '9': return Mark::Bar;
    default: return Mark::None;
    }
}
inline bool vniMarkAccepts(uint8_t base, Mark mark) {
    switch (mark) {
    case Mark::Circumflex: return base == 'a' || base == 'e' || base == 'o';
    case Mark::Horn: return base == 'o' || base == 'u';
    case Mark::Breve: return base == 'a';
    case Mark::Bar: return base == 'd';
    default: return false;
    }
}
inline uint8_t quickTelexSecond(uint8_t c) {
    switch (c) {
    case 'c': case 'k': case 'p': case 't': return 'h';
    case 'g': return 'i';
    case 'n': return 'g';
    case 'q': return 'u';
    default: return 0;
    }
}
inline char telexToneKey(Tone t) {
    switch (t) {
    case Tone::Acute: return 's'; case Tone::Grave: return 'f'; case Tone::Hook: return 'r';
    case Tone::Tilde: return 'x'; case Tone::Dot: return 'j'; default: return 0;
    }
}
inline char vniToneKey(Tone t) {
    switch (t) {
    case Tone::Acute: return '1'; case Tone::Grave: return '2'; case Tone::Hook: return '3';
    case Tone::Tilde: return '4'; case Tone::Dot: return '5'; default: return 0;
    }
}
/// Telex / VNI mark expansion of a toneless lowercase letter, nullptr if none.
inline const char* markExpansion(char32_t c, bool vni) {
    switch (c) {
    case U'â': return vni ? "a6" : "aa";
    case U'ă': return vni ? "a8" : "aw";
    case U'ê': return vni ? "e6" : "ee";
    case U'ô': return vni ? "o6" : "oo";
    case U'ơ': return vni ? "o7" : "ow";
    case U'ư': return vni ? "u7" : "uw";
    case U'đ': return vni ? "d9" : "dd";
    default: return nullptr;
    }
}

inline int commonPrefixLength(const char32_t* a, const char32_t* b, int limit) {
    int i = 0;
    while (i < limit && a[i] == b[i]) ++i;
    return i;
}

// "queue": "quêu" passes the validator but is no Vietnamese word.
// "away": aw+a swaps ă -> â (issue #149), so "away" would commit "ây".
const std::string_view kEnglishExceptions[] = {"was", "wow", "yes", "queue", "away"};

} // namespace

TelexEngine::TelexEngine() {
    for (int i = 0; i < kCapacity; ++i) {
        raw_[i] = 0; reopenRaw_[i] = 0; reopenOut_[i] = 0; out_[i] = 0; scratch_[i] = 0;
        basesScratch_[i] = 0; rawLetter_[i] = -1; toneKeys_[i] = 0; vowelIdx_[i] = 0;
    }
}

// MARK: - Public entry points

bool TelexEngine::seed(const char16_t* word, int length) {
    char32_t cps[kCapacity];
    int n = 0;
    for (int i = 0; i < length; ++i) {
        char16_t u = word[i];
        if (u >= 0xD800 && u <= 0xDFFF) { reset(); return false; }   // never typeable
        if (n == kCapacity) { reset(); return false; }
        cps[n++] = u;
    }
    return seed(cps, n);
}

bool TelexEngine::seed(const char32_t* word, int length) {
    reset();
    if (length <= 0 || length > kCapacity / 2) return false;
    // seedKeystrokes: detone -> mark expansion -> trailing tone key.
    // Swift compares `composed == word` under canonical equivalence; the only
    // precomposed code point that is canonically an engine letter is KELVIN SIGN ≡ K.
    char32_t norm[kCapacity / 2];
    for (int i = 0; i < length; ++i) norm[i] = word[i] == 0x212A ? U'K' : word[i];
    word = norm;
    char keys[kCapacity * 2 + 2];
    int k = 0;
    char toneKey = 0;
    for (int i = 0; i < length; ++i) {
        char32_t ch = word[i];
        bool isUpper = isUpperVi(ch);
        char32_t lower = lowerVi(ch);
        char32_t toneless = lower;
        int row; Tone t;
        if (detone(lower, row, t)) {
            if (t != Tone::None) {
                if (toneKey != 0) return false;             // two tones in one syllable
                toneKey = vniMode ? vniToneKey(t) : telexToneKey(t);
            }
            toneless = kTonedGroups[row][0];
        }
        char exp[3] = {0, 0, 0};
        if (const char* e = markExpansion(toneless, vniMode)) {
            exp[0] = e[0]; exp[1] = e[1];
        } else {
            if (toneless < 'a' || toneless > 'z') return false;
            exp[0] = static_cast<char>(toneless);
        }
        for (int j = 0; exp[j]; ++j) {
            char c = exp[j];
            // A mark digit is never uppercased; a mark LETTER follows the letter's case.
            if (isUpper && c >= 'a' && c <= 'z' && (!vniMode || j == 0)) c = static_cast<char>(c - 32);
            keys[k++] = c;
        }
    }
    if (toneKey) keys[k++] = toneKey;
    if (k > kCapacity) { reset(); return false; }
    Action a;
    for (int i = 0; i < k; ++i) feedAscii(static_cast<uint8_t>(keys[i]), a);
    if (!composedEquals(word, length)) { reset(); return false; }
    return true;
}

bool TelexEngine::composedEquals(const char32_t* word, int length) const {
    if (length != outCount_) return false;
    for (int i = 0; i < length; ++i)
        if (out_[i] != word[i]) return false;
    return true;
}

void TelexEngine::feed(char32_t ch, Action& out) {
    hasRestoreUndo_ = false;
    if (ch >= 128) { setSimple(out, Action::Passthrough); return; }
    feedAscii(static_cast<uint8_t>(ch), out);
}

void TelexEngine::takeSnapshots() {
    markCancelled_ = pCancelled_;
    toneCancelAt_ = pToneCancelAt_;
    toneCancelSpan_ = pToneCancelSpan_;
}

void TelexEngine::feedAscii(uint8_t ascii, Action& out) {
    if (rawCount_ == 0 && retroHasPending_) retroHasPending_ = false;
    bool bu;
    if (!(isLetter(ascii) || (vniMode && isDigit(ascii)) || (bracketVowels && bracketBase(ascii, bu) != 0))) {
        setSimple(out, Action::Passthrough);
        return;
    }
    if (rawCount_ >= kCapacity) { overflowed_ = true; setSimple(out, Action::Passthrough); return; }

    if (rawCount_ == 0) {
        reopenRawCount_ = 0; reopenOutCount_ = 0;
        wordGlue_ = pendingGlue_;
        pendingGlue_ = 0;
    }

    raw_[rawCount_] = ascii;
    rawCount_ += 1;

    if (pLiveSpellCheck_ != liveSpellCheck) {
        recomputeFreeze();
        rebuildFrozenAware();
    } else if (pProcessed_ != rawCount_ - 1 || pFreeMarking_ != freeMarking ||
               pSimpleTelex_ != simpleTelex || pQuickTelex_ != quickTelex || pVniMode_ != vniMode ||
               pBracketVowels_ != bracketVowels) {
        rebuildFrozenAware();
    } else {
        parseStep(rawCount_ - 1);
        pProcessed_ = rawCount_;
    }

    int newCount = render();
    takeSnapshots();

    // Uppercase tone key in a mixed-case word: freeze the whole word to raw now.
    if (disabledAtCount_ == kNotDisabled && upperToneKey_) {
        disabledAtCount_ = 0;
        upperToneFrozen_ = true;
        rebuildParseState();
        tonesFolded_ = false;
        newCount = render();
        takeSnapshots();
    }

    // Live spell-check freeze (with the teencode elongation escape).
    if (liveSpellCheck && disabledAtCount_ == kNotDisabled && !prefixIsValid(newCount) &&
        elongationHeadCount(newCount, pTone_) <= 0) {
        disabledAtCount_ = rawCount_;
        freezeKeepsTone_ = false;
        if (eagerRestoreApplies(newCount)) {
            // Eager English restore: the whole word back to raw ("gôg" -> "goog").
            disabledAtCount_ = 0;
            rebuildParseState();
            tonesFolded_ = false;
            newCount = render();
            takeSnapshots();
        } else if (pTone_ != Tone::None && prefixKeepsTone(rawCount_ - 1)) {
            // Marked word + visible tone (PR #133): keep it as shown, this key on literal.
            disabledAtCount_ = rawCount_ - 1;
            freezeKeepsTone_ = true;
            rebuildParseState();
            tonesFolded_ = false;
            newCount = render();
            takeSnapshots();
        } else if (pTone_ != Tone::None) {
            pFoldTones_ = true;
            rebuildParseState();
            pFoldTones_ = false;
            tonesFolded_ = true;
            newCount = render();
            takeSnapshots();
        }
    }

    // Eager English restore, deferred to key kFreezePrefixMinLength when the word froze
    // earlier ("win" -> "ưin", decided at "wind").
    if (eagerEnglishRestore && disabledAtCount_ != kNotDisabled && disabledAtCount_ > 0 &&
        disabledAtCount_ < gen::kFreezePrefixMinLength && rawCount_ == gen::kFreezePrefixMinLength &&
        eagerRestoreApplies(newCount)) {
        disabledAtCount_ = 0;
        rebuildParseState();
        tonesFolded_ = false;
        newCount = render();
        takeSnapshots();
    }

    // Elongation unfreeze.
    if (liveSpellCheck && disabledAtCount_ != kNotDisabled && !upperToneFrozen_ && rawCount_ >= 2 &&
        raw_[rawCount_ - 1] == raw_[rawCount_ - 2]) {
        recomputeFreeze();
        rebuildFrozenAware();
        newCount = render();
        takeSnapshots();
    }

    // Initials suffix (issue #138), decided last — see Swift.
    if (applyInitialsSplit()) {
        newCount = render();
        takeSnapshots();
    }

    // No-transform fast path.
    if (newCount == outCount_ + 1 && scratch_[newCount - 1] == static_cast<char32_t>(ascii) &&
        commonPrefixLength(scratch_, out_, outCount_) == outCount_) {
        copyOut(newCount);
        setSimple(out, Action::Passthrough);
        return;
    }

    diff(newCount, out);
    copyOut(newCount);
}

void TelexEngine::backspace(Action& out) {
    hasRestoreUndo_ = false;
    if (rawCount_ <= 0) {
        // The app deletes committed text: the retro history no longer matches the screen.
        if (retroCount_ > 0 || retroHasPending_) retroClear();
        setSimple(out, Action::Passthrough);
        return;
    }
    if (overflowed_) { setSimple(out, Action::Passthrough); return; }

    rebuildFrozenAware();
    (void)render();

    if (pCount_ == 0) {
        rawCount_ -= 1;
    } else {
        int last = pCount_ - 1;
        int w = 0;
        for (int r = 0; r < rawCount_; ++r)
            if (rawLetter_[r] != last) raw_[w++] = raw_[r];
        rawCount_ = w;
    }

    recomputeFreeze();
    rebuildFrozenAware();
    (void)applyInitialsSplit();
    int newCount = render();
    takeSnapshots();
    diff(newCount, out);
    copyOut(newCount);
}

void TelexEngine::commitBoundary(bool autoRestore, Action& out, char32_t boundary) {
    setSimple(out, Action::None);
    hasRestoreUndo_ = false;
    if (rawCount_ <= 0) { reopenRawCount_ = 0; reopenOutCount_ = 0; resetWord(); return; }
    if (overflowed_) {
        if (contextualEnglish) clearEnglishContext();
        reopenRawCount_ = 0; reopenOutCount_ = 0;
        if (retroCount_ > 0 || retroHasPending_) retroClear();
        resetWord();
        return;
    }
    bool wantsRestore = outCount_ > 0
        && (needsStandaloneWRunRestore() || (autoRestore && shouldRestoreRaw(boundary)));
    if (wantsRestore && compositionDiffersFromRaw()) {
        int limit = rawCount_ < outCount_ ? rawCount_ : outCount_;
        int lcp = 0;
        while (lcp < limit && static_cast<char32_t>(raw_[lcp]) == out_[lcp]) ++lcp;
        out.kind = Action::Replace;
        out.backspaces = outCount_ - lcp;
        out.length = rawCount_ - lcp;
        for (int i = lcp; i < rawCount_; ++i) out.text[i - lcp] = raw_[i];
        out.text[out.length] = 0;
    }
    // Teencode "Dạa" (Swift isToneThenATail): rewrite only the last character.
    const bool elongate = !wantsRestore && outCount_ > 0 && isToneThenATail();
    if (elongate) {
        char32_t tail[2];
        elongatedTail(tail);
        setReplace(out, 1, tail, 2);
    }
    // A restore that changed nothing on screen ("hoc", "tien") keeps its snapshot.
    captureReopen((wantsRestore && compositionDiffersFromRaw()) || elongate);
    noteCommittedWord(wantsRestore);
    if (retroactiveEnglish || retroCount_ > 0) retroRecord(wantsRestore, elongate);
    updateContext(wantsRestore);
    resetWord();
}

// TEENCODE one-letter elongation "Dạa" (Swift `isToneThenATail`): "daja" commits "dạa"
// instead of the invalid bare "dậ" — the tone was placed before the extra `a` came.
bool TelexEngine::isToneThenATail() const {
    if (!teencode || vniMode || markCancelled_ || overflowed_ || pCount_ < 2 || rawCount_ < 3 ||
        lastEffTone_ == Tone::None)
        return false;
    const int last = pCount_ - 1;
    if (letters_[last].base != 'a' || letters_[last].mark != Mark::Circumflex) return false;
    if (lowercased(raw_[rawCount_ - 1]) != 'a' || rawLetter_[rawCount_ - 1] != last) return false;
    if (outCount_ != pCount_) return false;
    if (out_[outCount_ - 1] != applyTone(markedScalar('a', Mark::Circumflex, letters_[last].upper), lastEffTone_))
        return false;
    int r = rawCount_ - 2;
    int tones = 0;
    while (r >= 0 && isToneKeyAt(r)) { ++tones; --r; }
    if (tones == 0 || r < 0 || lowercased(raw_[r]) != 'a' || rawLetter_[r] != last) return false;
    return isValidHead(pCount_, lastEffTone_, true);
}

bool TelexEngine::isToneKeyAt(int r) const {
    switch (lowercased(raw_[r])) {
    case 's': case 'f': case 'r': case 'x': case 'j': break;
    default: return false;
    }
    for (int j = 0; j < pToneKeyCount_; ++j)
        if (toneKeys_[j] == r) return true;
    return false;
}

void TelexEngine::elongatedTail(char32_t* two) const {
    const int last = pCount_ - 1;
    two[0] = applyTone(markedScalar('a', Mark::None, letters_[last].upper), lastEffTone_);
    two[1] = static_cast<char32_t>(raw_[rawCount_ - 1]);
}

int TelexEngine::emitElongated(char16_t* buf, int cap) const {
    char32_t tmp[kCapacity + 1];
    for (int i = 0; i < outCount_ - 1; ++i) tmp[i] = out_[i];
    elongatedTail(tmp + outCount_ - 1);
    return emit(tmp, outCount_ + 1, buf, cap);
}

void TelexEngine::captureReopen(bool restored) {
    if (restored || rawCount_ <= 0) { reopenRawCount_ = 0; reopenOutCount_ = 0; return; }
    for (int i = 0; i < rawCount_; ++i) reopenRaw_[i] = raw_[i];
    for (int i = 0; i < outCount_; ++i) reopenOut_[i] = out_[i];
    reopenRawCount_ = rawCount_;
    reopenOutCount_ = outCount_;
    reopenPrevEnglish_ = previousWordEnglish_;
    reopenCandidate_ = englishCandidate_;
    reopenGateBits_ = previousGateBits_;
}

int TelexEngine::reopenLastCommit(char16_t* buf, int cap) {
    if (!canReopenLastCommit()) return -1;
    int n = reopenRawCount_;
    int expected = reopenOutCount_;
    bool prevEnglish = reopenPrevEnglish_;
    bool prevCandidate = reopenCandidate_;
    uint8_t prevGateBits = reopenGateBits_;
    uint8_t keys[kCapacity];
    char32_t want[kCapacity];
    for (int i = 0; i < n; ++i) keys[i] = reopenRaw_[i];
    for (int i = 0; i < expected; ++i) want[i] = reopenOut_[i];
    reset();
    previousWordEnglish_ = prevEnglish;
    englishCandidate_ = prevCandidate;
    previousGateBits_ = prevGateBits;
    Action a;
    for (int i = 0; i < n; ++i) feedAscii(keys[i], a);
    if (rawCount_ != n || outCount_ != expected) { reset(); return -1; }
    for (int i = 0; i < outCount_; ++i)
        if (out_[i] != want[i]) { reset(); return -1; }
    return emit(out_, outCount_, buf, cap);
}

// A standalone run of three or more `w` keys is literal `www` text, regardless of the
// general auto-restore preference (mirrors Swift needsStandaloneWRunRestore).
bool TelexEngine::needsStandaloneWRunRestore() const {
    if (rawCount_ < 3 || !compositionDiffersFromRaw()) return false;
    for (int i = 0; i < rawCount_; ++i)
        if ((raw_[i] | 0x20) != 'w') return false;
    return true;
}

bool TelexEngine::shouldRestoreRaw(char32_t boundary) const {
    if (shouldRestoreRawBase()) return true;
    if ((boundary == U'\'' || boundary == U'\u2019') && isContractionStemBeforeApostrophe()) return true;
    return englishByFrequency && frequencyPrefersEnglish();
}

// English contraction stem right before an apostrophe (Swift isContractionStemBeforeApostrophe):
// raw keys, or raw minus a final `n` (n't), on EnglishContextWords.contractionStems.
bool TelexEngine::isContractionStemBeforeApostrophe() const {
    if (!compositionDiffersFromRaw()) return false;
    char w[kCapacity];
    int n = lowerAsciiInto(raw_, rawCount_, gen::kEnglishContextMaxLength, w);
    if (n <= 0) return false;
    if (inEnglishList(gen::kContractionStems, w, n)) return true;
    return n >= 2 && w[n - 1] == 'n' && inEnglishList(gen::kContractionStems, w, n - 1);
}

// Every restore rule except the frequency rule (englishByFrequency).
bool TelexEngine::shouldRestoreRawBase() const {
    if (initialsSplitAt_ >= 0) return false;   // "PhươngTH" (issue #138) — see Swift
    if (isListedCapsAcronym()) return true;     // "ASAP", "WWDC" — see Swift
    if (markCancelled_) {
        if (composedIsValidSyllable()) return false;
        if (toneCancelSpan_ > 1) return !composedIsRecognizedEnglish() || rawIsEnglishContextWord();
        if (toneCancelAt_ >= 0 && toneCancelAt_ < rawCount_ - 1 && rawIsEnglishCollision()) return true;
        // Vowel-doubler cancel that reached back ("seemed" -> "semed"): dictionary wins.
        if (pMarkCancelReachedBack_ && rawIsEnglishCollision()) return true;
        if (isTeencodeKeep()) return false;
        // Mark doubler + tone folded at the freeze ("cheese" -> "chese"): restore raw.
        if (toneCancelAt_ < 0 && tonesFolded_) return true;
        return composedHasDiacritic();
    }
    // Flip-back (englishByFrequency): reduplication / known pair with the previous
    // frequency-restored word keeps Vietnamese, ahead of every English restore rule.
    if (englishByFrequency && frequencyKeepsVietnamese()) return false;
    // Glued to a code separator / number ("my_var", "100W") — see Swift glueRestores.
    if (wordGlue_ != 0 && glueRestores()) return true;
    // Tự thêm dấu mũ turned an INVALID syllable (always restored before) into a valid one;
    // keys with an English reading ("diets", "hues") still restore — see Swift.
    if (inferredCircumflex_ && rawHasEnglishReading()) return true;
    // Đuôi -k (ták/ák/rík) không thắng bảng collision (issue #127) — song sinh Swift.
    if (rawIsEnglishCollision() && !(collisionPrefersVietnamese && composedIsValidSyllable() && !composedEndsWithK())) return true;
    // Vietnamese typo ("lanwm" -> "lănm") keeps the screen — Swift isVietnameseTypoKeep.
    if (upperToneKey_ || rawIsEnglishException() ||
        (!composedIsValidSyllable() && !isTeencodeKeep() && !isVietnameseTypoKeep() &&
         !isHatInitialismKeep()))
        return true;
    // ALL-CAPS acronym with a rare reading ("NAS" -> "NÁ") — Swift isRareAllCapsAcronym.
    if (isRareAllCapsAcronym()) return true;
    if (contextualEnglish && previousWordEnglish_ &&
        (rawIsEnglishContextWord(true) || (collisionPrefersVietnamese && rawIsEnglishCollision())) &&
        predecessorGateAllows())
        return true;
    return false;
}

// Swift predecessorGateAllows: a gated word ("been") restores only right after one of its
// predecessors ("has"); every other word is unaffected.
bool TelexEngine::predecessorGateAllows() const {
    char w[kCapacity];
    int n = lowerAsciiInto(raw_, rawCount_, gen::kEnglishContextMaxLength, w);
    if (n <= 0) return true;
    std::string_view key(w, static_cast<size_t>(n));
    for (int i = 0; i < gen::kGateCount; ++i)
        if (gen::kGateWords[i] == key) return (previousGateBits_ & (1u << i)) != 0;
    return true;
}

uint8_t TelexEngine::rawPredecessorBits() const {
    char w[kCapacity];
    int n = lowerAsciiInto(raw_, rawCount_, gen::kEnglishContextMaxLength, w);
    if (n <= 0) return 0;
    std::string_view key(w, static_cast<size_t>(n));
    uint8_t bits = 0;
    for (int i = 0; i < gen::kGateCount; ++i) {
        const auto& p = gen::kGatePredecessors[i];
        for (int k = 0; k < p.count; ++k)
            if (p.words[k] == key) { bits |= static_cast<uint8_t>(1u << i); break; }
    }
    return bits;
}

bool TelexEngine::rawIsFunctionWord() const {
    char w[kCapacity];
    int n = lowerAsciiInto(raw_, rawCount_, gen::kEnglishContextMaxLength, w);
    return n > 0 && inEnglishList(gen::kFunctionWords, w, n);
}

bool TelexEngine::rawIsRunKeeper() const {
    char w[kCapacity];
    int n = lowerAsciiInto(raw_, rawCount_, gen::kEnglishContextMaxLength, w);
    return n > 0 && inEnglishList(gen::kRunKeepers, w, n);
}

bool TelexEngine::rawIsContractionTail() const {
    if (rawCount_ > 2) return false;
    char w[kCapacity];
    int n = lowerAsciiInto(raw_, rawCount_, gen::kEnglishContextMaxLength, w);
    return n > 0 && inEnglishList(gen::kContractionTails, w, n);
}

bool TelexEngine::composedEndsWithK() const {
    return pCount_ > 0 && letters_[pCount_ - 1].base == 'k';
}

bool TelexEngine::composedHasDiacritic() const {
    if (pTone_ != Tone::None) return true;
    for (int k = 0; k < pCount_; ++k)
        if (letters_[k].mark != Mark::None) return true;
    return false;
}

bool TelexEngine::composedIsRecognizedEnglish() const {
    if (outCount_ < 2 || outCount_ > 12) return false;
    char w[kCapacity];
    int n = lowerAsciiInto(out_, outCount_, 12, w);
    if (n < 0) return false;
    return inEnglishList(gen::kEnglishCollisions, w, n) || inEnglishList(gen::kEnglishContextWords, w, n);
}

bool TelexEngine::isRecognizedEnglish() const {
    return rawIsEnglishContextWord() || rawIsEnglishCollision() || rawIsEnglishException();
}

TelexEngine::WordContext TelexEngine::classifyWordContext(bool restored) const {
    // Run keeper (box→bõ, car→cả): stays Vietnamese but must not END an open English run.
    if (!restored && compositionHasDiacritic())
        return previousWordEnglish_ && rawIsRunKeeper() ? WordContext::Neutral : WordContext::Vietnamese;
    if (isRecognizedEnglish())
        return rawIsFunctionWord() ? WordContext::EnglishFunction : WordContext::English;
    {   // composedAsciiWord
        char w[kCapacity];
        int n = -1;
        if (outCount_ > 0 && outCount_ <= gen::kEnglishContextMaxLength) {
            n = outCount_;
            for (int i = 0; i < outCount_; ++i) {
                char32_t c = out_[i];
                if (c > 127) { n = -1; break; }
                if (c >= 'A' && c <= 'Z') c |= 0x20;
                if (c < 'a' || c > 'z') { n = -1; break; }
                w[i] = static_cast<char>(c);
            }
        }
        if (n > 0) {
            bool neutral = inEnglishList(gen::kNeutralLoanwords, w, n);
            if (inEnglishList(gen::kEnglishContextWords, w, n) || inEnglishList(gen::kEnglishCollisions, w, n) || neutral) {
                if (neutral) return WordContext::Neutral;
                return inEnglishList(gen::kFunctionWords, w, n) ? WordContext::EnglishFunction : WordContext::English;
            }
        }
    }
    if (rawIsNeutralLoanword() || rawIsEnglishContextWord(true) || rawIsContractionTail()) return WordContext::Neutral;
    if (!restored && SyllableValidator::isValidSyllable(out_, outCount_, teencode)) return WordContext::Vietnamese;
    if (rawCount_ <= 2) return WordContext::Neutral;
    if (rawIsAllCapsToken()) return WordContext::Neutral;   // acronym ("ASL"): never opens a run
    return WordContext::English;
}

// MARK: - Glue / typo keep / acronyms / restore-undo (Swift: same names)

void TelexEngine::noteGlue(char32_t ch) {
    const bool first = !noteSinceWord_;
    noteSinceWord_ = true;
    if (ch >= 128) { pendingGlue_ = 0; return; }
    if (ch == U'_') pendingGlue_ = 1;
    else if (ch == U'.' || ch == U'/') pendingGlue_ = (first && lastWordKind_ == 2) ? 1 : 0;
    else if (ch >= U'0' && ch <= U'9') pendingGlue_ = 2;
    else pendingGlue_ = 0;
}

void TelexEngine::noteCommittedWord(bool restored) {
    if (rawCount_ <= 0) return;
    const bool keptVietnamese = !restored && (compositionHasDiacritic() || composedIsValidSyllable());
    // A word glued to a number is a quantity ("5k", "2h"): "/" after it starts a Vietnamese unit ("5k/tháng").
    lastWordKind_ = (keptVietnamese || isUpperAscii(raw_[0]) || wordGlue_ == 2) ? 1 : 2;
    noteSinceWord_ = false;
    pendingGlue_ = 0;
    if (restored && wordGlue_ == 0 && compositionDiffersFromRaw() && compositionHasDiacritic() &&
        (composedIsValidSyllable() || isTeencodeKeep())) {
        RestoreUndo& u = restoreUndo_;
        u.restoredLength = emitRaw(raw_, rawCount_, u.restored, kMaxText);
        u.vietnameseLength = emit(out_, outCount_, u.vietnamese, kMaxText);
        hasRestoreUndo_ = true;
    }
}

bool TelexEngine::takeRestoreUndo(RestoreUndo& out) {
    if (!hasRestoreUndo_) return false;
    hasRestoreUndo_ = false;
    out = restoreUndo_;
    return true;
}

bool TelexEngine::pendingRestoreUndo(RestoreUndo& out) const {
    if (!hasRestoreUndo_) return false;
    out = restoreUndo_;
    return true;
}

bool TelexEngine::glueRestores() const {
    if (vniMode || pCount_ <= 0 || !compositionHasDiacritic()) return false;
    if (wordGlue_ == 1) {
        for (int k = 0; k < pCount_; ++k)
            if (renderLetters_[k].mark != Mark::None) return false;
        return true;
    }
    for (int k = 0; k < pCount_; ++k)
        if (renderLetters_[k].base == 'u' && renderLetters_[k].mark == Mark::Horn && letterCreatedByW(k)) return true;
    return false;
}

bool TelexEngine::isVietnameseTypoKeep() const {
    if (vniMode || pCount_ < 3 || rawCount_ < 3) return false;
    const Letter& last = renderLetters_[pCount_ - 1];
    const Letter& prev = renderLetters_[pCount_ - 2];
    if (last.mark != Mark::None || isVowelAscii(last.base) || last.upper != prev.upper) return false;
    int groups = 0;
    bool inVowel = false;
    for (int i = 0; i < rawCount_; ++i) {
        const bool v = isVowelAscii(lowercased(raw_[i]));
        if (v && !inVowel) ++groups;
        inVowel = v;
    }
    if (groups != 1) return false;
    bool hasMark = false;
    for (int k = 0; k < pCount_ - 1; ++k) {
        if (renderLetters_[k].mark == Mark::None) continue;
        if (renderLetters_[k].mark == Mark::Horn && renderLetters_[k].base == 'u' && letterCreatedByW(k)) return false;
        hasMark = true;
    }
    if (!hasMark || !lettersAreCommonSyllable(pCount_ - 1)) return false;
    if (SyllableValidator::isValidPrefix(out_, outCount_, teencode)) return false;
    return !rawHasEnglishReading();
}

// Two-letter hat-vowel initialism ("AAL" -> "ÂL" = âm lịch) — Swift isHatInitialismKeep.
// Exactly 3 raw keys, one case, no tone: vowel + doubler (aa ee oo) or vowel + w (aw ow uw,
// never a standalone-w ư) + one bare consonant (not f j w z, not a stop c k p t g q); no English reading and not on
// the closed hat-shape English list. Boundary-only, allocation-free.
bool TelexEngine::isHatInitialismKeep() const {
    if (vniMode || rawCount_ != 3 || pCount_ != 2 || lastEffTone_ != Tone::None) return false;
    const bool up = isUpperAscii(raw_[0]);
    if (isUpperAscii(raw_[1]) != up || isUpperAscii(raw_[2]) != up) return false;
    const auto v = lowercased(raw_[0]), m = lowercased(raw_[1]), c = lowercased(raw_[2]);
    if (!isVowelAscii(v) || (m != v && m != 'w')) return false;
    if (m == v) { if (v != 'a' && v != 'e' && v != 'o') return false; }
    else if (v != 'a' && v != 'o' && v != 'u') return false;
    if (c < 'a' || c > 'z' || isVowelAscii(c)) return false;
    for (const char* x = "fjwzckptgq"; *x; ++x)
        if (c == static_cast<uint8_t>(*x)) return false;
    const Letter& first = renderLetters_[0];
    const Letter& second = renderLetters_[1];
    if (first.base != v || first.mark == Mark::None || second.base != c || second.mark != Mark::None) return false;
    // Swift hatInitialismEnglish: English words / acronyms of exactly this shape.
    static const char* const kHatInitialismEnglish[] = {
        "aah", "eel", "ooh", "owl", "awl", "aad", "oob", "awb", "awd", "uwb",
    };
    for (const char* e : kHatInitialismEnglish)
        if (e[0] == static_cast<char>(v) && e[1] == static_cast<char>(m) && e[2] == static_cast<char>(c)) return false;
    if (isListedCapsAcronym() || rawIsEnglishCollision()) return false;
    return !rawHasEnglishReading();
}

bool TelexEngine::rawHasEnglishReading() const {
    if (rawIsEnglishContextWord(true) || rawIsNeutralLoanword()) return true;
    char w[kCapacity];
    int n = lowerAsciiInto(raw_, rawCount_, gen::kEnglishContextMaxLength, w);
    if (n > 0 && inEnglishList(gen::kEnglishCollisions, w, n)) return true;
    const int top = rawCount_ < gen::kFreezePrefixMaxLength ? rawCount_ : gen::kFreezePrefixMaxLength;
    if (top < gen::kFreezePrefixMinLength) return false;
    for (int i = 0; i < top; ++i) w[i] = static_cast<char>(lowercased(raw_[i]));
    for (int k = gen::kFreezePrefixMinLength; k <= top; ++k)
        if (inEnglishList(gen::kEnglishFreezePrefixes, w, k)) return true;
    return false;
}

bool TelexEngine::isRareAllCapsAcronym() const {
    if (vniMode || !rawIsAllCapsToken()) return false;
    bool hasVowel = false;
    for (int k = 0; k < pCount_; ++k)
        if (isVowelAscii(renderLetters_[k].base)) { hasVowel = true; break; }
    if (!hasVowel || !compositionHasDiacritic() || !composedIsValidSyllable()) return false;
    // Mid-word tone key = Vietnamese spelling ("DAJA"), unless 3+ raw keys spell a
    // dictionary English word ("NASA" -> NẤ, "USA" -> ÚA).
    if (lastEffTone_ != Tone::None && !isToneKeyAt(rawCount_ - 1) && !(rawCount_ >= 3 && rawIsDictionaryWord()))
        return false;
    // 4+ keys that are no English word = Vietnamese in capitals ("MUTS" -> MÚT) — Swift twin.
    if (rawCount_ >= 4 && !rawIsDictionaryWord()) return false;
    return !lettersAreCommonSyllable(pCount_);
}

// Raw keys are in the collision table or the context dictionary (Swift rawIsDictionaryWord).
bool TelexEngine::rawIsDictionaryWord() const {
    char w[kCapacity];
    int n = lowerAsciiInto(raw_, rawCount_, gen::kEnglishContextMaxLength, w);
    return n > 0 && (inEnglishList(gen::kEnglishCollisions, w, n) || inEnglishList(gen::kEnglishContextWords, w, n));
}

// ALL-CAPS 3-5 keys on EnglishContextWords.capsAcronyms, changed by Telex (Swift twin).
bool TelexEngine::isListedCapsAcronym() const {
    if (vniMode || rawCount_ < 3 || rawCount_ > 5 || !isUpperAscii(raw_[0]) || !rawIsAllCapsToken() ||
        !compositionDiffersFromRaw())
        return false;
    char w[kCapacity];
    int n = lowerAsciiInto(raw_, rawCount_, gen::kEnglishContextMaxLength, w);
    return n > 0 && inEnglishList(gen::kCapsAcronyms, w, n);
}

bool TelexEngine::rawIsAllCapsToken() const {
    if (rawCount_ < 2) return false;
    for (int i = 0; i < rawCount_; ++i)
        if (!isUpperAscii(raw_[i])) return false;
    return pCount_ + (lastEffTone_ == Tone::None ? 0 : 1) >= 2;
}

bool TelexEngine::lettersAreCommonSyllable(int count) const {
    char key[2 * kCapacity + 1];
    int n = 0;
    for (int k = 0; k < count; ++k) {
        const Letter& l = renderLetters_[k];
        key[n++] = static_cast<char>(l.base);
        switch (l.mark) {
        case Mark::None: break;
        case Mark::Circumflex: key[n++] = static_cast<char>(l.base); break;
        case Mark::Breve: case Mark::Horn: key[n++] = 'w'; break;
        case Mark::Bar: key[n++] = 'd'; break;
        }
    }
    switch (lastEffTone_) {
    case Tone::None: break;
    case Tone::Acute: key[n++] = 's'; break;
    case Tone::Grave: key[n++] = 'f'; break;
    case Tone::Hook: key[n++] = 'r'; break;
    case Tone::Tilde: key[n++] = 'x'; break;
    case Tone::Dot: key[n++] = 'j'; break;
    }
    if (n < 1 || n > gen::kCommonSyllableMaxKey) return false;
    return contains(gen::kCommonSyllables, key, n);
}

bool TelexEngine::rawIsNeutralLoanword() const {
    char w[kCapacity];
    int n = lowerAsciiInto(raw_, rawCount_, gen::kEnglishContextMaxLength, w);
    return n > 0 && inEnglishList(gen::kNeutralLoanwords, w, n);
}

void TelexEngine::updateContext(bool restored) {
    if (!contextualEnglish || rawCount_ <= 0) return;
    switch (classifyWordContext(restored)) {
    case WordContext::EnglishFunction: previousWordEnglish_ = true; englishCandidate_ = false; break;
    case WordContext::English: foldEnglishContentWord(); break;
    case WordContext::Vietnamese: clearEnglishContext(); previousWordVietnamese_ = true; return;
    case WordContext::Neutral: break;
    }
    if (previousWordEnglish_) previousWordVietnamese_ = false;   // a run opened (one loanword does not)
    previousGateBits_ = rawPredecessorBits();
}

void TelexEngine::foldEnglishContentWord() {
    if (previousWordEnglish_) return;
    if (englishCandidate_) { previousWordEnglish_ = true; englishCandidate_ = false; }
    else englishCandidate_ = true;
}

void TelexEngine::clearEnglishContext() {
    previousWordEnglish_ = false;
    englishCandidate_ = false;
    previousGateBits_ = 0;
}

bool TelexEngine::rawIsEnglishContextWord(bool includingRestoreOnly) const {
    char w[kCapacity];
    int n = lowerAsciiInto(raw_, rawCount_, gen::kEnglishContextMaxLength, w);
    if (n <= 0) return false;
    if (inEnglishList(gen::kEnglishContextWords, w, n)) return true;
    return includingRestoreOnly && inEnglishList(gen::kEnglishRestoreOnly, w, n);
}

void TelexEngine::reset() {
    if (rawCount_ > 0) { clearEnglishContext(); previousWordVietnamese_ = true; }
    resetWord();
    reopenRawCount_ = 0;
    reopenOutCount_ = 0;
    hasRestoreUndo_ = false;
    clearGlue();
    if (retroCount_ > 0 || retroHasPending_) retroClear();   // caret moved / text unknown
}

void TelexEngine::resetContext() {
    clearEnglishContext();
    previousWordVietnamese_ = false;
    if (retroCount_ > 0 || retroHasPending_) retroClear();
}

// MARK: - Retroactive English correction (Swift RetroEnglish.swift + TelexEngine retro*)

namespace {
constexpr uint8_t kClsP = 1u << 0, kClsO = 1u << 1, kClsD = 1u << 2, kClsB = 1u << 3,
                  kClsR = 1u << 4, kClsC = 1u << 5, kClsX = 1u << 6;
constexpr uint8_t kAnchorMask = kClsP | kClsD | kClsR | kClsC;
constexpr int kRetroWindow = 3;
constexpr int kRetroMaxGap = 2;

uint8_t retroClassBits(const char* w, int n) {
#ifdef VTX_NO_ENGLISH_TABLES
    (void)w; (void)n;
    return 0;
#else
    std::string_view key(w, static_cast<size_t>(n));
    size_t lo = 0, hi = sizeof(gen::kRetroClassBits);
    while (lo < hi) {
        size_t mid = (lo + hi) / 2;
        int c = gen::kRetroClassWords[mid].compare(key);
        if (c == 0) return gen::kRetroClassBits[mid];
        if (c < 0) lo = mid + 1; else hi = mid;
    }
    return 0;
#endif
}

bool retroIsCandidateRaw(const char* w, int n) {
    if (inEnglishList(gen::kEnglishCollisions, w, n) || inEnglishList(gen::kEnglishContextWords, w, n)
        || inEnglishList(gen::kRunKeepers, w, n)) return true;
    std::string_view key(w, static_cast<size_t>(n));
    for (const auto& x : kEnglishExceptions) if (x == key) return true;
    return false;
}

// EnglishFrequency lookups (lite build: always miss, tables dropped by the linker).
bool frequencyScores(const char* w, int n, uint8_t& en, uint8_t& vn) {
#ifdef VTX_NO_ENGLISH_TABLES
    (void)w; (void)n; (void)en; (void)vn;
    return false;
#else
    return gen::kEnglishFrequency.find(w, n, en, vn);
#endif
}

bool frequencyHasPair(const char* p, int n) {
#ifdef VTX_NO_ENGLISH_TABLES
    (void)p; (void)n;
    return false;
#else
    return n >= 3 && n <= gen::kFrequencyMaxPairLength && gen::kFrequencyPairs.contains(p, n);
#endif
}

// Swift RetroEnglish.isStrongRaw: frequent English word with no Vietnamese reading.
bool retroIsStrongRaw(const char* w, int n) {
    uint8_t en, vn;
    return frequencyScores(w, n, en, vn) && vn == 0 && en >= gen::kFrequencyStrongMin;
}

bool retroPairAllowed(uint8_t l, uint8_t r) {
    if (l == 0) return true;
    if (l & (kClsO | kClsB | kClsC)) return true;
    if ((l & kClsP) && (r == 0 || (r & kClsB))) return true;
    if ((l & kClsD) && r == 0) return true;
    if ((l & kClsR) && (r == 0 || (r & (kClsD | kClsP | kClsO)))) return true;
    return false;
}

inline bool appendU16(char16_t* buf, int32_t& len, char32_t c) {
    if (len >= RetroCorrection::kMax - 1) return false;
    buf[len++] = static_cast<char16_t>(c);
    buf[len] = 0;
    return true;
}
} // namespace

void TelexEngine::retroClear() {
    retroCount_ = 0;
    retroPickCount_ = 0;
    retroHasPending_ = false;
    retroGap_ = 0;
}

void TelexEngine::noteBoundaryCharacter(char32_t ch) {
    noteGlue(ch);
    // A sentence ends: the next word starts a phrase (frequency rule only reads this).
    if (previousWordVietnamese_ && (ch == U'.' || ch == U'!' || ch == U'?' || ch == U'\n' || ch == U'\r'))
        previousWordVietnamese_ = false;
    if (!retroactiveEnglish && retroCount_ == 0 && !retroHasPending_) return;
    if (!retroactiveEnglishActive() || rawCount_ != 0 || ch > 0xFFFF) { retroClear(); return; }
    if (retroHasPending_) {
        RetroCorrection& p = retroPending_;
        if (appendU16(p.expected, p.expectedLength, ch) && appendU16(p.insert, p.insertLength, ch)) {
            p.backspaces += 1;
        } else {
            retroHasPending_ = false;   // too long to carry: drop the edit, never a partial one
        }
    }
    if (ch == U' ') {
        ++retroGap_;
    } else {
        retroCount_ = 0;
        retroPickCount_ = 0;
        retroGap_ = 0;
    }
}

bool TelexEngine::takeRetroCorrection(RetroCorrection& out) {
    if (!retroHasPending_) return false;
    retroHasPending_ = false;
    out = retroPending_;
    for (int k = 0; k < retroPickCount_; ++k) {
        int i = retroPicks_[k];
        if (i >= retroCount_) continue;
        RetroWord& w = retroHist_[i];
        if (out.flipBack) {
            for (int j = 0; j < w.altLen; ++j) w.shown[j] = w.alt[j];
            w.shownLen = w.altLen;
            w.english = false;
            w.byFrequency = false;
        } else {
            for (int j = 0; j < w.rawLen; ++j) w.shown[j] = w.raw[j];
            w.shownLen = w.rawLen;
            w.english = true;
            w.candidate = false;
        }
    }
    retroPickCount_ = 0;
    return true;
}

bool TelexEngine::pendingRetroCorrection(RetroCorrection& out) const {
    if (!retroHasPending_) return false;
    out = retroPending_;
    return true;
}

void TelexEngine::retroRecord(bool restored, bool elongated) {
    retroHasPending_ = false;
    retroPickCount_ = 0;
    if (!retroactiveEnglishActive() || rawCount_ <= 0) { retroClear(); return; }
    // Frequency rule (englishByFrequency): was THIS word restored only by it, and does it
    // flip a previous one back? Both read the state the restore decision saw (before the
    // history shifts).
    bool byFrequency = false;
    int flipBack = 0;
    if (englishByFrequency) {
        byFrequency = restored && !elongated && !shouldRestoreRawBase() && !needsStandaloneWRunRestore()
            && frequencyPrefersEnglish();
        flipBack = elongated ? 0 : frequencyFlipDistance(restored);
    }
    if (retroCount_ >= kRetroHistory) {
        for (int i = 1; i < retroCount_; ++i) retroHist_[i - 1] = retroHist_[i];
        --retroCount_;
    }
    const bool hadPrev = retroCount_ > 0;
    const bool prevEnglish = hadPrev && retroHist_[retroCount_ - 1].english;
    RetroWord& w = retroHist_[retroCount_];
    w.rawLen = rawCount_;
    for (int i = 0; i < rawCount_; ++i) w.raw[i] = raw_[i];
    if (restored) {
        w.shownLen = rawCount_;
        for (int i = 0; i < rawCount_; ++i) w.shown[i] = raw_[i];
    } else if (elongated) {
        for (int i = 0; i < outCount_ - 1; ++i) w.shown[i] = out_[i];
        elongatedTail(w.shown + outCount_ - 1);
        w.shownLen = outCount_ + 1;
    } else {
        w.shownLen = outCount_;
        for (int i = 0; i < outCount_; ++i) w.shown[i] = out_[i];
    }
    bool ascii = true;
    for (int i = 0; i < w.shownLen; ++i) if (w.shown[i] >= 128) { ascii = false; break; }
    const WordContext kind = classifyWordContext(restored);
    char lw[kCapacity];
    const int ln = lowerAsciiInto(raw_, rawCount_, gen::kEnglishContextMaxLength, lw);
    w.english = ascii && (kind == WordContext::English || kind == WordContext::EnglishFunction
                          || (rawCount_ == 1 && (raw_[0] | 0x20) == 'a'));
    w.candidate = !ascii && !restored && !elongated && rawCount_ >= 2 && ln > 0 && retroIsCandidateRaw(lw, ln);
    w.cls = ln > 0 ? retroClassBits(lw, ln) : 0;
    w.gap = (hadPrev && retroGap_ >= 1 && retroGap_ <= kRetroMaxGap) ? retroGap_ : 0;
    w.leftNonEnglish = w.gap > 0 && !prevEnglish;
    w.gateBit = 0;
    if (ln > 0) {
        std::string_view key(lw, static_cast<size_t>(ln));
        for (int i = 0; i < gen::kGateCount; ++i)
            if (gen::kGateWords[i] == key) { w.gateBit = static_cast<uint8_t>(1u << i); break; }
    }
    w.predBits = rawPredecessorBits();
    w.strong = w.english && kind == WordContext::English && ln > 0 && retroIsStrongRaw(lw, ln);
    w.byFrequency = byFrequency;
    w.altLen = 0;
    if (byFrequency) {
        for (int i = 0; i < outCount_; ++i) w.alt[i] = out_[i];
        w.altLen = outCount_;
    }
    ++retroCount_;
    retroGap_ = 0;
    if (flipBack > 0 && retroCount_ > flipBack && retroHist_[retroCount_ - 1 - flipBack].byFrequency) {
        int pick = retroCount_ - 1 - flipBack;
        if (retroBuild(&pick, 1, true)) {
            retroHasPending_ = true;
            retroPicks_[0] = pick;
            retroPickCount_ = 1;
        }
        return;
    }
    if (!w.english) return;
    int picks[kRetroHistory];
    int np = retroPlan(picks);
    if (np > 0 && retroBuild(picks, np)) {
        retroHasPending_ = true;
        for (int i = 0; i < np; ++i) retroPicks_[i] = picks[i];
        retroPickCount_ = np;
    }
}

bool TelexEngine::retroLeftIsNonEnglish(int a) const {
    if (retroHist_[a].gap <= 0) return false;
    if (a > 0) return !retroHist_[a - 1].english;
    return retroHist_[a].leftNonEnglish;
}

bool TelexEngine::retroAnchors(int a, const int* picks, int np) const {
    const RetroWord& w = retroHist_[a];
    if (w.cls & kAnchorMask) return true;
    if (w.candidate && (w.cls & kClsB) && a + 1 < retroCount_ && (retroHist_[a + 1].cls & kClsP) && w.gap <= 0)
        return true;
    if (w.english && !w.candidate) {
        for (int k = 0; k < np; ++k) {
            uint8_t c = retroHist_[picks[k]].cls;
            if (!(c & kClsB) || (c & kClsX)) return false;
        }
        return true;
    }
    return false;
}

// Swift RetroEnglish.plan over the history ring. Returns the number of picks (0 = nil).
int TelexEngine::retroPlan(int* picks) const {
    const RetroWord* h = retroHist_;
    const int n = retroCount_;
    if (n < 2 || !h[n - 1].english || h[n - 1].gap <= 0) return 0;
    // A run of ONE strong word ("fast", "very") — needs >= 2 rewritten words below.
    const bool strongEnd = !h[n - 2].english;
    if (strongEnd && !h[n - 1].strong) return 0;
    int s = strongEnd ? n - 1 : n - 2;
    while (s > 0 && h[s].gap > 0 && h[s - 1].english) --s;
    int lo = s, k = 0;
    while (k < kRetroWindow && lo > 0 && h[lo].gap > 0 && (h[lo - 1].candidate || h[lo - 1].english)) { --lo; ++k; }
    if (lo >= s) return 0;
    for (int a = lo; a < s; ++a) {
        int np = 0;
        for (int i = a; i < s; ++i) if (h[i].candidate) picks[np++] = i;
        if (np == 0 || (strongEnd && np < 2) || !retroAnchors(a, picks, np)) continue;
        bool ok = true;
        for (int i = a; i < s && ok; ++i) if (!retroPairAllowed(h[i].cls, h[i + 1].cls)) ok = false;
        for (int q = 0; q < np && ok; ++q) {
            int i = picks[q];
            if (h[i].gateBit == 0) continue;
            if (i == a || (h[i - 1].predBits & h[i].gateBit) == 0) ok = false;
        }
        if (!ok) continue;
        if (h[a].candidate && retroLeftIsNonEnglish(a) && np < 2) continue;
        return np;
    }
    return 0;
}

// Swift RetroEnglish.correction into retroPending_. False if it does not fit.
bool TelexEngine::retroBuild(const int* picks, int np, bool flipBack) {
    RetroCorrection& c = retroPending_;
    char16_t e[RetroCorrection::kMax], r[RetroCorrection::kMax];
    int32_t el = 0, rl = 0;
    const int first = picks[0];
    int q = 0;
    for (int i = first; i < retroCount_; ++i) {
        const RetroWord& w = retroHist_[i];
        if (i > first)
            for (int g = 0; g < w.gap; ++g)
                if (!appendU16(e, el, U' ') || !appendU16(r, rl, U' ')) return false;
        const bool pick = q < np && picks[q] == i;
        if (pick) ++q;
        for (int j = 0; j < w.shownLen; ++j) if (!appendU16(e, el, w.shown[j])) return false;
        if (pick && flipBack) { for (int j = 0; j < w.altLen; ++j) if (!appendU16(r, rl, w.alt[j])) return false; }
        else if (pick) { for (int j = 0; j < w.rawLen; ++j) if (!appendU16(r, rl, w.raw[j])) return false; }
        else { for (int j = 0; j < w.shownLen; ++j) if (!appendU16(r, rl, w.shown[j])) return false; }
    }
    int lcp = 0;
    while (lcp < el && lcp < rl && e[lcp] == r[lcp]) ++lcp;
    c.backspaces = el - lcp;
    c.words = np;
    c.expectedLength = el - lcp;
    c.insertLength = rl - lcp;
    for (int i = lcp; i < el; ++i) c.expected[i - lcp] = e[i];
    c.expected[c.expectedLength] = 0;
    for (int i = lcp; i < rl; ++i) c.insert[i - lcp] = r[i];
    c.insert[c.insertLength] = 0;
    c.flipBack = flipBack;
    return true;
}

int TelexEngine::debugRetroShown(int i, char16_t* buf, int cap) const {
    if (i < 0 || i >= retroCount_) return emit(retroHist_[0].shown, 0, buf, cap);
    return emit(retroHist_[i].shown, retroHist_[i].shownLen, buf, cap);
}

// MARK: - Frequency rule + flip-back (Swift englishByFrequency)

namespace {
constexpr uint8_t kFrequencyVietnameseFloor = 140;
constexpr uint8_t kFrequencyMargin = 45;
} // namespace

// EnglishFrequency scores of the raw keys (boundary-only, allocation-free).
bool TelexEngine::rawFrequencyScores(uint8_t& en, uint8_t& vn) const {
    char w[kCapacity];
    int n = lowerAsciiInto(raw_, rawCount_, gen::kFrequencyMaxWordLength, w);
    return n > 0 && frequencyScores(w, n, en, vn);
}

// Frequency rule: a word at the START of a phrase (no English run, no Vietnamese word
// right before), composed as a valid syllable that differs from the keys, whose syllable
// is rare and whose English word is far more frequent. Off with teencode (see Swift).
bool TelexEngine::frequencyPrefersEnglish() const {
    if (!englishByFrequencyActive() || teencode || previousWordEnglish_ || previousWordVietnamese_ ||
        !compositionDiffersFromRaw() || !composedIsValidSyllable())
        return false;
    uint8_t en, vn;
    if (!rawFrequencyScores(en, vn) || vn == 0) return false;
    return vn < kFrequencyVietnameseFloor && int(en) >= int(vn) + int(kFrequencyMargin);
}

// The previous history word, if the frequency rule restored it and only spaces separate it
// from the word being committed.
const TelexEngine::RetroWord* TelexEngine::frequencyRestoredPrevious() const {
    if (!englishByFrequencyActive() || retroGap_ < 1 || retroGap_ > kRetroMaxGap || retroCount_ == 0) return nullptr;
    const RetroWord& w = retroHist_[retroCount_ - 1];
    return w.byFrequency ? &w : nullptr;
}

// The frequency-restored word TWO back with one Vietnamese word between ("hí ha hí").
const TelexEngine::RetroWord* TelexEngine::frequencyRestoredTwoBack() const {
    const int n = retroCount_;
    if (!englishByFrequencyActive() || n < 2 || retroGap_ < 1 || retroGap_ > kRetroMaxGap ||
        !retroHist_[n - 2].byFrequency || retroHist_[n - 1].gap <= 0 || retroHist_[n - 1].english)
        return nullptr;
    return &retroHist_[n - 2];
}

bool TelexEngine::frequencyKeepsVietnamese() const {
    const RetroWord* prev = frequencyRestoredPrevious();
    if (!prev || !composedIsValidSyllable() || !compositionHasDiacritic()) return false;
    return frequencyPairEvidence(*prev);
}

// Same raw keys as `prev` (case-insensitive) or, unless reduplicationOnly, the pair
// (prev raw, this composition's Telex key) is in gen::kFrequencyPairs. Allocation-free.
bool TelexEngine::frequencyPairEvidence(const RetroWord& prev, bool reduplicationOnly) const {
    char p[4 * kCapacity + 2];
    int n = 0;
    for (int i = 0; i < prev.rawLen; ++i) {
        if (n >= kCapacity) return false;
        uint8_t b = prev.raw[i];
        if (b >= 'A' && b <= 'Z') b |= 0x20;
        p[n++] = static_cast<char>(b);
    }
    if (n == rawCount_) {
        bool same = true;
        for (int i = 0; i < rawCount_; ++i) {
            uint8_t b = raw_[i];
            if (b >= 'A' && b <= 'Z') b |= 0x20;
            if (static_cast<char>(b) != p[i]) { same = false; break; }
        }
        if (same) return true;
    }
    if (reduplicationOnly) return false;
    p[n++] = '>';
    n = appendComposedTelexKey(p, n);
    return frequencyHasPair(p, n);
}

// The composition's Telex key (letters + mark keys, tone last — CommonSyllables spelling).
int TelexEngine::appendComposedTelexKey(char* p, int start) const {
    int n = start;
    for (int k = 0; k < pCount_; ++k) {
        const Letter& l = renderLetters_[k];
        p[n++] = static_cast<char>(l.base);
        switch (l.mark) {
        case Mark::None: break;
        case Mark::Circumflex: p[n++] = static_cast<char>(l.base); break;
        case Mark::Breve: case Mark::Horn: p[n++] = 'w'; break;
        case Mark::Bar: p[n++] = 'd'; break;
        }
    }
    switch (lastEffTone_) {
    case Tone::None: break;
    case Tone::Acute: p[n++] = 's'; break;
    case Tone::Grave: p[n++] = 'f'; break;
    case Tone::Hook: p[n++] = 'r'; break;
    case Tone::Tilde: p[n++] = 'x'; break;
    case Tone::Dot: p[n++] = 'j'; break;
    }
    return n;
}

// At a commit that KEPT Vietnamese: how many words back is the frequency-restored word to
// flip (1 or 2; 0 = none)? Only on evidence — reduplication or a known pair. Two back only
// for an exact repeat across one Vietnamese word.
int TelexEngine::frequencyFlipDistance(bool restored) const {
    if (restored || !composedIsValidSyllable()) return 0;
    if (const RetroWord* prev = frequencyRestoredPrevious()) return frequencyPairEvidence(*prev) ? 1 : 0;
    if (compositionHasDiacritic()) {
        const RetroWord* prev = frequencyRestoredTwoBack();
        if (prev && frequencyPairEvidence(*prev, true)) return 2;
    }
    return 0;
}

int TelexEngine::commitText(bool autoRestore, char16_t* buf, int cap, char32_t boundary) {
    int n;
    hasRestoreUndo_ = false;
    if (overflowed_) {
        if (contextualEnglish) clearEnglishContext();
        reopenRawCount_ = 0; reopenOutCount_ = 0;
        if (retroCount_ > 0 || retroHasPending_) retroClear();
        n = emit(out_, outCount_, buf, cap);
        resetWord();
        return n;
    }
    bool wantsRestore = outCount_ > 0
        && (needsStandaloneWRunRestore() || (autoRestore && shouldRestoreRaw(boundary)));
    const bool elongate = !wantsRestore && outCount_ > 0 && isToneThenATail();
    n = wantsRestore ? emitRaw(raw_, rawCount_, buf, cap)
        : elongate ? emitElongated(buf, cap) : emit(out_, outCount_, buf, cap);
    // A restore that changed nothing on screen ("hoc", "tien") keeps its snapshot.
    captureReopen((wantsRestore && compositionDiffersFromRaw()) || elongate);
    noteCommittedWord(wantsRestore);
    if (retroactiveEnglish || retroCount_ > 0) retroRecord(wantsRestore, elongate);
    updateContext(wantsRestore);
    resetWord();
    return n;
}

int TelexEngine::peekCommitText(bool autoRestore, char16_t* buf, int cap, char32_t boundary) const {
    if (overflowed_) return emit(out_, outCount_, buf, cap);
    if (outCount_ > 0 && needsStandaloneWRunRestore()) return emitRaw(raw_, rawCount_, buf, cap);
    if (autoRestore && outCount_ > 0 && shouldRestoreRaw(boundary)) return emitRaw(raw_, rawCount_, buf, cap);
    if (outCount_ > 0 && isToneThenATail()) return emitElongated(buf, cap);
    return emit(out_, outCount_, buf, cap);
}

bool TelexEngine::rawIsEnglishCollision() const {
    if (!englishWordRestore) return false;
    if (rawCount_ < 2 || rawCount_ > 12) return false;
    if (!compositionDiffersFromRaw()) return false;
    if ((raw_[0] | 0x20) == 'w') {
        bool wTransformed = pCount_ > 0 && renderLetters_[0].base == 'u' && renderLetters_[0].mark == Mark::Horn;
        if (!wTransformed) return false;
    }
    char w[kCapacity];
    int n = lowerAsciiInto(raw_, rawCount_, 12, w);
    return n > 0 && inEnglishList(gen::kEnglishCollisions, w, n);
}

bool TelexEngine::rawIsEnglishException() const {
    if (pCount_ <= 0) return false;
    bool wTransformed = renderLetters_[0].base == 'u' && renderLetters_[0].mark == Mark::Horn;
    for (const auto& word : kEnglishExceptions) {
        if (rawCount_ != static_cast<int>(word.size())) continue;
        if (word[0] == 'w' && !wTransformed) continue;
        bool match = true;
        for (int i = 0; i < rawCount_; ++i)
            if (lowercased(raw_[i]) != static_cast<uint8_t>(word[i])) { match = false; break; }
        if (match) return true;
    }
    return false;
}

int TelexEngine::teencodeOnset() const {
    if (!teencode || pCount_ < 2 || renderLetters_[0].mark != Mark::None) return 0;
    switch (renderLetters_[0].base) {
    case 'w': return 1;
    case 'z': return 2;
    case 'd':
        if (pCount_ >= 3 && renderLetters_[1].base == 'z' && renderLetters_[1].mark == Mark::None) return 3;
        return 0;
    default: return 0;
    }
}

namespace {
inline int onsetSkip(int code) { return code == 3 ? 2 : 1; }
inline int writeCanon(int code, uint8_t* buf) {
    if (code == 1) { buf[0] = 'q' - 'a'; buf[1] = 'u' - 'a'; return 2; }
    buf[0] = 'd' - 'a';
    return 1;
}
} // namespace

bool TelexEngine::isAbbreviationPrefix(bool upper) const {
    if (pCount_ <= 0) return false;
    for (int k = 0; k < pCount_; ++k) {
        const Letter& l = letters_[k];
        if (isVowelAscii(l.base) || l.upper != upper) return false;
    }
    return true;
}

bool TelexEngine::abbreviationDoublerException(uint8_t lower, bool upper) const {
    return !pVniMode_ && lower == 'd' && isAbbreviationPrefix(upper);
}

bool TelexEngine::composedIsValidSyllable() const {
    if (pCount_ >= 1 && lastEffTone_ == Tone::None && renderLetters_[0].base == 'd' &&
        renderLetters_[0].mark == Mark::Bar) {
        bool bareConsonantsOnly = true;
        for (int k = 1; k < pCount_; ++k) {
            const Letter& l = renderLetters_[k];
            if (l.mark != Mark::None || isVowelAscii(l.base)) { bareConsonantsOnly = false; break; }
        }
        if (bareConsonantsOnly) return true;
    }
    if (lastEffTone_ == Tone::None && rawCount_ >= 2) {
        bool sameCase = true;
        bool firstIsUpper = isUpperAscii(raw_[0]);
        for (int i = 0; i < rawCount_; ++i)
            if (isUpperAscii(raw_[i]) != firstIsUpper) { sameCase = false; break; }
        if (sameCase) {
            bool hasBar = false, onlyBar = true;
            for (int k = 0; k < pCount_; ++k) {
                const Letter& l = renderLetters_[k];
                if (isVowelAscii(l.base)) { onlyBar = false; break; }
                if (l.base == 'd' && l.mark == Mark::Bar) hasBar = true;
                else if (l.mark != Mark::None) { onlyBar = false; break; }
            }
            if (hasBar && onlyBar) return true;
        }
    }
    uint8_t buf[kCapacity + 1];
    int onset = teencodeOnset();
    bool stacksTeencodeRime = pCount_ >= 3 && renderLetters_[pCount_ - 2].base == 'i' &&
                              renderLetters_[pCount_ - 2].mark == Mark::None &&
                              renderLetters_[pCount_ - 1].base == 'e' &&
                              renderLetters_[pCount_ - 1].mark == Mark::None && onset != 0 &&
                              onsetSkip(onset) == pCount_ - 2;
    if (!stacksTeencodeRime && pCount_ < kCapacity - 1 && onset != 0) {
        int n = writeCanon(onset, buf);
        for (int k = onsetSkip(onset); k < pCount_; ++k)
            buf[n++] = letterClass(renderLetters_[k].base, renderLetters_[k].mark);
        if (SyllableValidator::isValidSyllable(buf, n, lastEffTone_, teencode)) return true;
    }
    for (int k = 0; k < pCount_; ++k) buf[k] = letterClass(renderLetters_[k].base, renderLetters_[k].mark);
    return SyllableValidator::isValidSyllable(buf, pCount_, lastEffTone_, teencode);
}

int TelexEngine::elongationHeadCount(int count, Tone tone) const {
    const int minRun = 3;
    if (count < minRun + 1) return -1;
    const Letter& last = renderLetters_[count - 1];
    for (int j = count - minRun; j < count - 1; ++j)
        if (renderLetters_[j].base != last.base || renderLetters_[j].mark != last.mark) return -1;
    int runStart = count - minRun;
    while (runStart > 0 && renderLetters_[runStart - 1].base == last.base &&
           renderLetters_[runStart - 1].mark == last.mark) --runStart;
    if (runStart < 1) runStart = 1;
    for (int k = runStart; k <= count - minRun; ++k)
        if (isValidHead(k, tone)) return k;
    return -1;
}

bool TelexEngine::isValidHead(int k, Tone tone, bool plainLast) const {
    if (k < 1 || k > kCapacity) return false;
    Tone t = tone;
    if ((t == Tone::Grave || t == Tone::Hook || t == Tone::Tilde) && hasStopCoda(k) &&
        !(t == Tone::Grave && isUkRime(k))) t = Tone::None;
    uint8_t buf[kCapacity + 1];
    int onset = teencodeOnset();
    if (onset != 0 && onsetSkip(onset) < k) {
        int n = writeCanon(onset, buf);
        for (int j = onsetSkip(onset); j < k; ++j)
            buf[n++] = letterClass(renderLetters_[j].base,
                                   plainLast && j == k - 1 ? Mark::None : renderLetters_[j].mark);
        if (SyllableValidator::isValidSyllable(buf, n, t, teencode)) return true;
    }
    for (int j = 0; j < k; ++j)
        buf[j] = letterClass(renderLetters_[j].base, plainLast && j == k - 1 ? Mark::None : renderLetters_[j].mark);
    return SyllableValidator::isValidSyllable(buf, k, t, teencode);
}

bool TelexEngine::compositionDiffersFromRaw() const {
    if (outCount_ != rawCount_) return true;
    for (int i = 0; i < outCount_; ++i)
        if (out_[i] != static_cast<char32_t>(raw_[i])) return true;
    return false;
}

bool TelexEngine::compositionHasDiacritic() const {
    for (int i = 0; i < outCount_; ++i)
        if (out_[i] > 127) return true;
    return false;
}

bool TelexEngine::letterCreatedByW(int idx) const {
    for (int i = 0; i < rawCount_; ++i)
        if (rawLetter_[i] == idx) return raw_[i] == 'w' || raw_[i] == 'W';
    return false;
}

bool TelexEngine::uaUuPredecessorAllowsRetarget(int pred) const {
    Mark m = letters_[pred].mark;
    return m == Mark::None || (m == Mark::Horn && !letterCreatedByW(pred));
}

bool TelexEngine::hasLowercaseBefore(int at) const {
    for (int i = 0; i < at; ++i)
        if (raw_[i] >= 'a' && raw_[i] <= 'z') return true;
    return false;
}

// ---- Initials suffix ("PhươngTH", "KiênTV", "HùngNV" — issue #138; see Swift) -----

namespace {
constexpr int kInitialsMin = 2;
constexpr int kInitialsMax = 4;
}

int TelexEngine::initialsSplitPoint() const {
    if (rawCount_ < 1 + kInitialsMin || !isUpperAscii(raw_[0]) || !isUpperAscii(raw_[rawCount_ - 1])) return -1;
    int s = rawCount_;
    while (s > 0 && isUpperAscii(raw_[s - 1])) --s;
    const int n = rawCount_ - s;
    if (s < 2 || n < kInitialsMin || n > kInitialsMax) return -1;
    bool hasLower = false;
    for (int i = 1; i < s; ++i) {
        const uint8_t c = raw_[i];
        if (c >= 'a' && c <= 'z') { hasLower = true; continue; }
        if (vniMode && isDigit(c)) continue;
        if (!vniMode && i == 1 && c == 'D' && raw_[0] == 'D') continue;
        return -1;
    }
    return hasLower && !runIsCodeAcronym(s) ? s : -1;
}

// raw[s..<rawCount] is a code acronym ("MaxID"), not initials. A shape rule: probed
// directly (not inEnglishList), so the lite build keeps it too.
bool TelexEngine::runIsCodeAcronym(int s) const {
    char w[kCapacity];
    const int n = rawCount_ - s;
    for (int i = 0; i < n; ++i) w[i] = static_cast<char>(raw_[s + i] | 0x20);
    return gen::kCodeAcronyms.contains(w, n);
}

bool TelexEngine::headIsInitialsSyllable(int s) {
    const int full = rawCount_;
    const int savedDisabled = disabledAtCount_;
    const bool savedKeep = freezeKeepsTone_;
    rawCount_ = s;
    disabledAtCount_ = kNotDisabled;
    freezeKeepsTone_ = false;
    rebuildParseState();
    (void)render();
    bool ok = !pCancelled_;
    if (ok) {
        bool transformed = lastEffTone_ != Tone::None;
        for (int k = 0; k < pCount_; ++k)
            if (renderLetters_[k].mark != Mark::None) { transformed = true; break; }
        ok = transformed && composedIsValidSyllable() && !rawHeadIsEnglish(s);
    }
    rawCount_ = full;
    disabledAtCount_ = savedDisabled;
    freezeKeepsTone_ = savedKeep;
    if (!ok) rebuildFrozenAware();
    return ok;
}

bool TelexEngine::rawHeadIsEnglish(int s) const {
    if (!englishWordRestore) return false;
    char w[kCapacity];
    const int n = lowerAsciiInto(raw_, s, gen::kEnglishContextMaxLength, w);
    if (n <= 0) return false;
    if (inEnglishList(gen::kEnglishCollisions, w, n) || inEnglishList(gen::kEnglishContextWords, w, n)) return true;
    std::string_view key(w, static_cast<size_t>(n));
    for (const auto& x : kEnglishExceptions) if (x == key) return true;
    return false;
}

bool TelexEngine::applyInitialsSplit() {
    const int s = initialsSplitPoint();
    if (s >= 0) {
        if (initialsSplitAt_ == s && disabledAtCount_ == s && freezeKeepsTone_) return false;
        if (headIsInitialsSyllable(s)) {
            initialsSplitAt_ = s;
            disabledAtCount_ = s;
            freezeKeepsTone_ = true;
            upperToneFrozen_ = false;
            rebuildParseState();
            tonesFolded_ = false;
            return true;
        }
        if (initialsSplitAt_ >= 0) {
            recomputeFreeze();
            rebuildFrozenAware();
        }
        return true;   // the head's render overwrote scratch — caller re-renders
    }
    if (initialsSplitAt_ >= 0) {
        recomputeFreeze();
        rebuildFrozenAware();
        return true;
    }
    return false;
}

void TelexEngine::resetWord() {
    rawCount_ = 0;
    outCount_ = 0;
    markCancelled_ = false;
    toneCancelAt_ = -1;
    toneCancelSpan_ = 0;
    upperToneKey_ = false;
    upperToneFrozen_ = false;
    initialsSplitAt_ = -1;
    wordGlue_ = 0;
    overflowed_ = false;
    disabledAtCount_ = kNotDisabled;
    tonesFolded_ = false;
    freezeKeepsTone_ = false;
    pFreezeLetters_ = -1;
    pCount_ = 0;
    pTone_ = Tone::None;
    pToneKeyCount_ = 0;
    pCancelled_ = false;
    pToneCancelAt_ = -1;
    pToneCancelSpan_ = 0;
    pMarkCancelReachedBack_ = false;
    pProcessed_ = 0;
}

bool TelexEngine::prefixIsValid(int n) {
    int o = 0, start = 0;
    if (teencode && n >= 1 && letters_[0].mark == Mark::None && n < kCapacity - 1) {
        switch (letters_[0].base) {
        case 'w': basesScratch_[0] = 'q'; basesScratch_[1] = 'u'; o = 2; start = 1; break;
        case 'z': basesScratch_[0] = 'd'; o = 1; start = 1; break;
        case 'd':
            if (n >= 2 && letters_[1].base == 'z' && letters_[1].mark == Mark::None) {
                basesScratch_[0] = 'd'; o = 1; start = 2;
            }
            break;
        default: break;
        }
    }
    for (int k = start; k < n; ++k)
        basesScratch_[o++] = static_cast<uint8_t>(letters_[k].base | (letters_[k].mark != Mark::None ? 0x80 : 0));
    return SyllableValidator::isValidPrefix(basesScratch_, o, teencode);
}

bool TelexEngine::hasSpellingError(bool autoRestore) const {
    if (rawCount_ == 0 || overflowed_ || outCount_ == 0) return false;
    bool sameAsRaw = outCount_ == rawCount_;
    for (int i = 0; sameAsRaw && i < outCount_; ++i) sameAsRaw = out_[i] == static_cast<char32_t>(raw_[i]);
    if (sameAsRaw) return false;                           // left as typed: English / raw
    if (needsStandaloneWRunRestore() || (autoRestore && shouldRestoreRaw()))
        return false;                                      // boundary restores the raw keys
    return SyllableValidator::isSpellingError(out_, outCount_, teencode);
}

int TelexEngine::composed(char16_t* buf, int cap) const { return emit(out_, outCount_, buf, cap); }
int TelexEngine::rawKeystrokes(char16_t* buf, int cap) const { return emitRaw(raw_, rawCount_, buf, cap); }

// MARK: - Rendering

void TelexEngine::copyOut(int n) {
    for (int i = 0; i < n; ++i) out_[i] = scratch_[i];
    outCount_ = n;
}

int TelexEngine::render() {
    const int count = pCount_;
    for (int k = 0; k < count; ++k) renderLetters_[k] = letters_[k];
    // Kept-tone freeze (PR #133): the literal tail neither attracts the tone nor re-shapes ươ.
    const int headEnd = (freezeKeepsTone_ && pFreezeLetters_ >= 0 && pFreezeLetters_ < count)
                            ? pFreezeLetters_ : count;

    // ươ propagation.
    for (int k = 1; k < (headEnd > 1 ? headEnd : 1); ++k) {
        if (renderLetters_[k - 1].base != 'u' || renderLetters_[k].base != 'o') continue;
        bool prevHorn = renderLetters_[k - 1].mark == Mark::Horn;
        bool curHorn = renderLetters_[k].mark == Mark::Horn;
        if (prevHorn == curHorn) continue;
        bool oIsLast = (k == headEnd - 1);
        bool isQuGlide = (k >= 2 && renderLetters_[k - 2].base == 'q');
        if (!oIsLast && !isQuGlide) {
            renderLetters_[k - 1].mark = Mark::Horn;
            renderLetters_[k].mark = Mark::Horn;
        }
    }

    Tone effTone = pTone_;
    int toneScope = headEnd;
    if (pTone_ != Tone::None && headEnd == count) {
        int head = elongationHeadCount(count, pTone_);
        if (head > 0) toneScope = head;
    }
    int toneIdx = pTone_ == Tone::None ? -1 : toneVowelIndex(toneScope);
    if (toneIdx >= 0 && (effTone == Tone::Grave || effTone == Tone::Hook || effTone == Tone::Tilde) &&
        hasStopCoda(toneScope) && !(effTone == Tone::Grave && isUkRime(toneScope))) {
        effTone = Tone::None;
        toneIdx = -1;
    }
    // Tự thêm dấu mũ (issue #166): after the effective tone is known. The added circumflex is
    // the rime's only marked vowel, so the tone moves onto it.
    inferredCircumflex_ = false;
    if (autoCircumflex && effTone != Tone::None && toneScope == count && inferCircumflex(count, effTone)) {
        inferredCircumflex_ = true;
        toneIdx = toneVowelIndex(toneScope);
    }
    int target = toneIdx >= 0 ? toneIdx : (count - 1 > 0 ? count - 1 : 0);
    for (int j = 0; j < pToneKeyCount_; ++j) rawLetter_[toneKeys_[j]] = target;
    lastEffTone_ = effTone;

    for (int k = 0; k < count; ++k) {
        const Letter& u = renderLetters_[k];
        char32_t scalar = markedScalar(u.base, u.mark, u.upper);
        if (k == toneIdx) scalar = applyTone(scalar, effTone);
        scratch_[k] = scalar;
    }
    return count;
}

// Tự thêm dấu mũ — see autoCircumflex / Swift inferCircumflex. Reads/writes
// renderLetters_[0..count). Exactly ONE vowel cluster, none of it marked, in the listed
// shapes; the plain syllable must be INVALID for this tone and the circumflexed one VALID
// (the validator decides, so "quan", "què", "xẻng", "séc" are untouched).
bool TelexEngine::inferCircumflex(int count, Tone tone) {
    if (count < 2 || count >= kCapacity) return false;
    int first = -1, last = -1;
    for (int k = 0; k < count; ++k) {
        if (!isVowelAscii(renderLetters_[k].base)) continue;
        if (renderLetters_[k].mark != Mark::None) return false;
        if (first < 0) first = k;
        else if (k != last + 1) return false;
        last = k;
    }
    if (first < 0) return false;
    const int n = last - first + 1;
    auto v = [&](int i) { return renderLetters_[first + i].base; };
    int target = -1;
    if (n == 1 && v(0) == 'e') target = first;                                              // ênh, êch
    else if (n == 2 && v(1) == 'e' && (v(0) == 'i' || v(0) == 'y') && last < count - 1) target = first + 1;  // iên, yêt
    else if (n == 2 && v(0) == 'u' && v(1) == 'e') target = first + 1;                      // uê, uênh, uêch
    else if (n == 2 && v(0) == 'e' && v(1) == 'u') target = first;                          // êu
    else if (n == 2 && v(0) == 'u' && v(1) == 'a' && last < count - 1) target = first + 1;  // uân, uât, uâng
    else if (n == 3 && v(0) == 'u' && v(1) == 'y' && v(2) == 'e' && last < count - 1) target = first + 2;  // uyên, uyêt
    else if (n == 3 && (v(0) == 'i' || v(0) == 'y') && v(1) == 'e' && v(2) == 'u') target = first + 1;     // iêu, yêu
    else if (n == 3 && v(0) == 'u' && v(1) == 'a' && v(2) == 'y') target = first + 1;      // uây
    else return false;
    uint8_t buf[kCapacity];
    for (int k = 0; k < count; ++k) buf[k] = letterClass(renderLetters_[k].base, renderLetters_[k].mark);
    if (SyllableValidator::isValidSyllable(buf, count, tone, teencode)) return false;
    buf[target] = letterClass(renderLetters_[target].base, Mark::Circumflex);
    if (!SyllableValidator::isValidSyllable(buf, count, tone, teencode)) return false;
    renderLetters_[target].mark = Mark::Circumflex;
    return true;
}

// MARK: - Incremental parse

void TelexEngine::rebuildFrozenAware() {
    rebuildParseState();
    tonesFolded_ = false;
    if (disabledAtCount_ != kNotDisabled && pTone_ != Tone::None && !freezeKeepsTone_) {
        pFoldTones_ = true;
        rebuildParseState();
        pFoldTones_ = false;
        tonesFolded_ = true;
    }
}

// Circumflex the doubler target; an o inside ươ also un-horns the u (ươ -> uô, UniKey).
void TelexEngine::setCircumflex(int k) {
    letters_[k].mark = Mark::Circumflex;
    if (letters_[k].base == 'o' && k >= 1 && letters_[k - 1].base == 'u' &&
        letters_[k - 1].mark == Mark::Horn)
        letters_[k - 1].mark = Mark::None;
}

bool TelexEngine::nucleusHasHornVowel(int end) const {
    for (int j = end; j >= 0 && isVowelAscii(letters_[j].base); --j)
        if (letters_[j].mark == Mark::Horn) return true;
    return false;
}

// Eager English restore gate (Swift `eagerRestoreApplies`) — only at the freeze moment.
bool TelexEngine::eagerRestoreApplies(int n) const {
    if (!eagerEnglishRestore || vniMode || pCancelled_ || rawCount_ < gen::kFreezePrefixMinLength ||
        rawCount_ > gen::kFreezePrefixMaxLength)
        return false;
    bool differs = n != rawCount_;
    for (int i = 0; !differs && i < n; ++i)
        if (scratch_[i] != static_cast<char32_t>(raw_[i])) differs = true;
    if (!differs) return false;
    char w[kCapacity];
    for (int i = 0; i < rawCount_; ++i) {
        uint8_t b = raw_[i];
        if (b >= 'A' && b <= 'Z') b |= 0x20;
        w[i] = static_cast<char>(b);
    }
    return inEnglishList(gen::kEnglishFreezePrefixes, w, rawCount_);
}

void TelexEngine::recomputeFreeze() {
    const int full = rawCount_;
    disabledAtCount_ = kNotDisabled;
    freezeKeepsTone_ = false;
    upperToneFrozen_ = false;
    initialsSplitAt_ = -1;
    for (int r = 1; r <= full; ++r) {
        rawCount_ = r;
        rebuildParseState();
        // feed()'s upper-case tone freeze, before spell-check and independent of it;
        // nothing lifts it ("VieeJt" ⌫ → "VieeJ") — see Swift.
        if (disabledAtCount_ == kNotDisabled && upperToneKey_) {
            disabledAtCount_ = 0;
            upperToneFrozen_ = true;
            break;
        }
        if (!liveSpellCheck) continue;
        if (disabledAtCount_ == kNotDisabled && pCount_ > 0 && !prefixIsValid(pCount_)) {
            int n = render();
            if (elongationHeadCount(pCount_, pTone_) <= 0) {
                if (eagerRestoreApplies(n)) {
                    disabledAtCount_ = 0;
                } else if (pTone_ != Tone::None && prefixKeepsTone(r - 1)) {
                    disabledAtCount_ = r - 1;   // same kept-tone rule as feed() (PR #133)
                    freezeKeepsTone_ = true;
                } else {
                    disabledAtCount_ = r;
                }
            }
        } else if (eagerEnglishRestore && disabledAtCount_ != kNotDisabled && disabledAtCount_ > 0 &&
                   disabledAtCount_ < gen::kFreezePrefixMinLength && r == gen::kFreezePrefixMinLength) {
            rebuildFrozenAware();
            int n = render();
            if (eagerRestoreApplies(n)) disabledAtCount_ = 0;
        }
        // feed()'s elongation unfreeze, on the key it fires on (exact repeat) — see Swift.
        if (disabledAtCount_ != kNotDisabled && r >= 2 && raw_[r - 1] == raw_[r - 2]) {
            int frozenAt = disabledAtCount_;
            disabledAtCount_ = kNotDisabled;
            rebuildParseState();
            (void)render();
            if (elongationHeadCount(pCount_, pTone_) <= 0) disabledAtCount_ = frozenAt;
            else freezeKeepsTone_ = false;
        }
    }
    rawCount_ = full;
}

// Kept-tone freeze test (PR #133, Swift `prefixKeepsTone`): the word of the first n raw keys
// carries a letter mark (đ ư ơ â ê ô ă) AND a visible tone, and key n, parsed normally, only
// appends one character to that display. Freeze-time only; leaves the parse state built
// for the full rawCount_.
bool TelexEngine::prefixKeepsTone(int n) {
    const int full = rawCount_;
    rawCount_ = n;
    rebuildParseState();
    bool keep = false;
    int shown = 0;
    uint64_t sig = 0;
    if (pTone_ != Tone::None) {
        for (int k = 0; k < pCount_; ++k)
            if (letters_[k].mark != Mark::None) { keep = true; break; }
        if (keep) {
            shown = render();
            keep = lastEffTone_ != Tone::None;
            sig = scratchSignature(shown);
        }
    }
    rawCount_ = full;
    rebuildParseState();
    if (keep) keep = render() == shown + 1 && scratchSignature(shown) == sig;
    return keep;
}

uint64_t TelexEngine::scratchSignature(int n) const {
    uint64_t h = 0;
    for (int k = 0; k < n; ++k) h = h * 1000003u + static_cast<uint64_t>(scratch_[k]);
    return h;
}

void TelexEngine::rebuildParseState() {
    pCount_ = 0;
    pTone_ = Tone::None;
    pToneKeyCount_ = 0;
    pCancelled_ = false;
    pToneCancelAt_ = -1;
    pToneCancelSpan_ = 0;
    pMarkCancelReachedBack_ = false;
    upperToneKey_ = false;
    pFreeMarking_ = freeMarking;
    pSimpleTelex_ = simpleTelex;
    pQuickTelex_ = quickTelex;
    pVniMode_ = vniMode;
    pBracketVowels_ = bracketVowels;
    pLiveSpellCheck_ = liveSpellCheck;
    pFreezeLetters_ = -1;
    for (int i = 0; i < rawCount_; ++i) rawLetter_[i] = -1;
    for (int i = 0; i < rawCount_; ++i) parseStep(i);
    pProcessed_ = rawCount_;
}

void TelexEngine::parseStep(int at) {
    const uint8_t key = raw_[at];
    const uint8_t lower = lowercased(key);
    const bool upper = isUpperAscii(key);
    if (at == disabledAtCount_) pFreezeLetters_ = pCount_;

    if (pCancelled_ || (at >= disabledAtCount_ && !abbreviationDoublerException(lower, upper))) {
        appendLetter(lower, Mark::None, upper);
        rawLetter_[at] = pCount_ - 1;
        return;
    }

    bool bUpper = false;
    if (pBracketVowels_) {
        uint8_t b = bracketBase(key, bUpper);
        if (b != 0) {
            appendLetter(b, Mark::Horn, bUpper);
            rawLetter_[at] = pCount_ - 1;
            return;
        }
    }

    if (pVniMode_) { parseStepVNI(at, key, lower, upper); return; }

    // Tone keys: s f r x j
    Tone t = toneForKey(lower);
    if (t != Tone::None) {
        if (pFoldTones_) {
            appendLetter(lower, Mark::None, upper);
            rawLetter_[at] = pCount_ - 1;
            return;
        }
        if (hasVowel(pCount_)) {
            if (pTone_ == t) {
                pTone_ = Tone::None;
                pCancelled_ = true;
                pToneCancelAt_ = at;
                pToneCancelSpan_ = pToneKeyCount_ > 0 ? at - toneKeys_[pToneKeyCount_ - 1] : 1;
                appendLetter(lower, Mark::None, upper);
                rawLetter_[at] = pCount_ - 1;
                for (int j = 0; j < pToneKeyCount_; ++j)
                    if (rawLetter_[toneKeys_[j]] == -1) rawLetter_[toneKeys_[j]] = pCount_ - 1;
                pToneKeyCount_ = 0;
            } else if (stopCodaRejectsTone(t)) {
                appendLetter(lower, Mark::None, upper);
                rawLetter_[at] = pCount_ - 1;
            } else {
                pTone_ = t;
                if (upper && hasLowercaseBefore(at)) upperToneKey_ = true;
                rawLetter_[at] = -1;
                toneKeys_[pToneKeyCount_++] = at;
            }
        } else {
            appendLetter(lower, Mark::None, upper);
            rawLetter_[at] = pCount_ - 1;
        }
        return;
    }

    // z: clear tone if there is one; otherwise literal.
    if (lower == 'z') {
        if (pTone_ != Tone::None) {
            pToneCancelAt_ = at;
            pToneCancelSpan_ = pToneKeyCount_ > 0 ? at - toneKeys_[pToneKeyCount_ - 1] : 1;
            pTone_ = Tone::None;
            if (upper && hasLowercaseBefore(at)) upperToneKey_ = true;
            rawLetter_[at] = -1;
            toneKeys_[pToneKeyCount_++] = at;
        } else {
            appendLetter(lower, Mark::None, upper);
            rawLetter_[at] = pCount_ - 1;
        }
        return;
    }

    // w: breve / horn modifier, or standalone ư.
    if (lower == 'w') {
        int tIdx = -1;
        for (int k = pCount_ - 1; k >= 0; --k) {
            uint8_t b = letters_[k].base;
            if (b == 'a' || b == 'o' || b == 'u') { tIdx = k; break; }
            if (!freeMarking && !isVowelAscii(b)) break;
        }
        if (tIdx >= 1 && letters_[tIdx].base == 'a' && letters_[tIdx].mark == Mark::None &&
            letters_[tIdx - 1].base == 'u' && uaUuPredecessorAllowsRetarget(tIdx - 1) &&
            !(tIdx >= 2 && letters_[tIdx - 2].base == 'q'))
            tIdx -= 1;
        if (tIdx >= 1 && letters_[tIdx].base == 'u' && letters_[tIdx].mark == Mark::None &&
            letters_[tIdx - 1].base == 'u' && uaUuPredecessorAllowsRetarget(tIdx - 1) &&
            !(tIdx >= 2 && letters_[tIdx - 2].base == 'q'))
            tIdx -= 1;
        if (tIdx >= 0) {
            const Letter p = letters_[tIdx];
            if (p.mark == Mark::None && p.base == 'a') {
                letters_[tIdx].mark = Mark::Breve; rawLetter_[at] = tIdx; return;
            }
            if (p.mark == Mark::None && (p.base == 'o' || p.base == 'u')) {
                letters_[tIdx].mark = Mark::Horn; rawLetter_[at] = tIdx; return;
            }
            // Hat -> hook/breve swap: w on â/ô replaces the hat, tone kept —
            // "caamw"/"cấmw" -> cắm, "tooiw" -> tơi. Issue #149.
            if (p.mark == Mark::Circumflex && p.base == 'a') {
                letters_[tIdx].mark = Mark::Breve; rawLetter_[at] = tIdx; return;
            }
            if (p.mark == Mark::Circumflex && p.base == 'o') {
                letters_[tIdx].mark = Mark::Horn; rawLetter_[at] = tIdx; return;
            }
            if (p.mark == Mark::Breve && p.base == 'a') {
                letters_[tIdx].mark = Mark::None;
                pCancelled_ = true;
                appendLetter('w', Mark::None, upper);
                rawLetter_[at] = pCount_ - 1; return;
            }
            if (p.mark == Mark::Horn && (p.base == 'o' || p.base == 'u')) {
                letters_[tIdx].mark = Mark::None;
                pCancelled_ = true;
                if (p.base == 'u' && letterCreatedByW(tIdx)) {
                    letters_[tIdx].base = 'w';
                    rawLetter_[at] = tIdx;
                    return;
                }
                appendLetter('w', Mark::None, upper);
                rawLetter_[at] = pCount_ - 1; return;
            }
        }
        if (!simpleTelex && standaloneHornUAllowed(pCount_)) appendLetter('u', Mark::Horn, upper);
        else appendLetter('w', Mark::None, upper);
        rawLetter_[at] = pCount_ - 1;
        return;
    }

    // circumflex doublers: a e o
    if (lower == 'a' || lower == 'e' || lower == 'o') {
        if (pCount_ > 0) {
            int pIdx = pCount_ - 1;
            const Letter p = letters_[pIdx];
            if (p.base == lower && p.mark == Mark::None &&
                (lower == 'o' || !nucleusHasHornVowel(pIdx))) {
                setCircumflex(pIdx); rawLetter_[at] = pIdx; return;
            }
            // `o` on ơ (ươ cluster): hook -> hat ("mơ"+o -> mô).
            if (lower == 'o' && p.base == lower && p.mark == Mark::Horn) {
                setCircumflex(pIdx); rawLetter_[at] = pIdx; return;
            }
            // Same swap for `a` on ă ("awa" -> â). Issue #149.
            if (lower == 'a' && p.base == lower && p.mark == Mark::Breve &&
                !nucleusHasHornVowel(pIdx)) {
                setCircumflex(pIdx); rawLetter_[at] = pIdx; return;
            }
            if (p.base == lower && p.mark == Mark::Circumflex) {
                letters_[pIdx].mark = Mark::None;
                pCancelled_ = true;
                appendLetter(lower, Mark::None, upper);
                rawLetter_[at] = pCount_ - 1; return;
            }
        }
        if (freeMarking) {
            int k = pCount_ - 1;
            while (k >= 0 && !isVowelAscii(letters_[k].base)) --k;
            const int nucleusEnd = k;
            const bool hornBlocksCircumflex = lower != 'o' && nucleusHasHornVowel(nucleusEnd);
            while (!hornBlocksCircumflex && k >= 0 && isVowelAscii(letters_[k].base)) {
                // "lươn" + o -> "luôn": the reach-back also retargets a horned o.
                if (letters_[k].base == lower &&
                    (letters_[k].mark == Mark::None || (lower == 'o' && letters_[k].mark == Mark::Horn) ||
                     (lower == 'a' && letters_[k].mark == Mark::Breve))) {
                    if (lower == 'o' && nucleusEnd == pCount_ - 1 && k == pCount_ - 2 &&
                        letters_[k + 1].mark == Mark::None &&
                        (letters_[k + 1].base == 'e' || letters_[k + 1].base == 'a'))
                        break;   // -> literal o ("oeo"/"oao" rimes)
                    setCircumflex(k); rawLetter_[at] = k; return;
                }
                if (letters_[k].base == lower && letters_[k].mark == Mark::Circumflex) {
                    letters_[k].mark = Mark::None;
                    pCancelled_ = true;
                    pMarkCancelReachedBack_ = true;
                    appendLetter(lower, Mark::None, upper);
                    rawLetter_[at] = pCount_ - 1; return;
                }
                --k;
            }
        }
        appendLetter(lower, Mark::None, upper);
        rawLetter_[at] = pCount_ - 1;
        return;
    }

    // d doubler -> đ
    if (lower == 'd') {
        if (pCount_ > 0) {
            int pIdx = pCount_ - 1;
            const Letter p = letters_[pIdx];
            if (p.base == 'd' && p.mark == Mark::None) {
                letters_[pIdx].mark = Mark::Bar; rawLetter_[at] = pIdx; return;
            }
            if (p.base == 'd' && p.mark == Mark::Bar) {
                letters_[pIdx].mark = Mark::None;
                pCancelled_ = true;
                appendLetter('d', Mark::None, upper);
                rawLetter_[at] = pCount_ - 1; return;
            }
        }
        if (freeMarking && pCount_ > 1 && letters_[0].base == 'd' && letters_[0].mark == Mark::None) {
            letters_[0].mark = Mark::Bar; rawLetter_[at] = 0; return;
        }
        if (freeMarking && pCount_ > 1 && letters_[0].base == 'd' && letters_[0].mark == Mark::Bar &&
            letters_[pCount_ - 1].base != 'd') {
            letters_[0].mark = Mark::None;
            pCancelled_ = true;
            appendLetter('d', Mark::None, upper);
            rawLetter_[at] = pCount_ - 1; return;
        }
        appendLetter('d', Mark::None, upper);
        rawLetter_[at] = pCount_ - 1;
        return;
    }

    // Quick Telex: word-initial doubled onset consonant -> digraph.
    if (quickTelex && pCount_ == 1 && letters_[0].base == lower && letters_[0].mark == Mark::None) {
        uint8_t second = quickTelexSecond(lower);
        if (second != 0) {
            appendLetter(second, Mark::None, upper);
            rawLetter_[at] = pCount_ - 1;
            return;
        }
    }

    appendLetter(lower, Mark::None, upper);
    rawLetter_[at] = pCount_ - 1;
}

void TelexEngine::parseStepVNI(int at, uint8_t key, uint8_t lower, bool upper) {
    if (!isDigit(key)) {
        appendLetter(lower, Mark::None, upper);
        rawLetter_[at] = pCount_ - 1;
        return;
    }
    const Tone t = vniTone(key);
    if (pFoldTones_ && t != Tone::None) {
        appendLetter(key, Mark::None, false);
        rawLetter_[at] = pCount_ - 1;
        return;
    }
    if (t != Tone::None) {
        if (hasVowel(pCount_)) {
            if (pTone_ == t) {
                pTone_ = Tone::None;
                pCancelled_ = true;
                pToneCancelAt_ = at;
                pToneCancelSpan_ = pToneKeyCount_ > 0 ? at - toneKeys_[pToneKeyCount_ - 1] : 1;
                appendLetter(key, Mark::None, false);
                rawLetter_[at] = pCount_ - 1;
                for (int j = 0; j < pToneKeyCount_; ++j)
                    if (rawLetter_[toneKeys_[j]] == -1) rawLetter_[toneKeys_[j]] = pCount_ - 1;
                pToneKeyCount_ = 0;
            } else if (stopCodaRejectsTone(t)) {
                appendLetter(key, Mark::None, false);
                rawLetter_[at] = pCount_ - 1;
            } else {
                pTone_ = t;
                rawLetter_[at] = -1;
                toneKeys_[pToneKeyCount_++] = at;
            }
        } else {
            appendLetter(key, Mark::None, false);
            rawLetter_[at] = pCount_ - 1;
        }
        return;
    }
    if (key == '0') {
        if (pTone_ != Tone::None) {
            pToneCancelAt_ = at;
            pToneCancelSpan_ = pToneKeyCount_ > 0 ? at - toneKeys_[pToneKeyCount_ - 1] : 1;
            pTone_ = Tone::None;
            rawLetter_[at] = -1;
            toneKeys_[pToneKeyCount_++] = at;
        } else {
            appendLetter(key, Mark::None, false);
            rawLetter_[at] = pCount_ - 1;
        }
        return;
    }
    const Mark mark = vniMark(key);
    if (mark != Mark::None) {
        for (int k = pCount_ - 1; k >= 0; --k) {
            if (vniMarkAccepts(letters_[k].base, mark)) {
                int target = k;
                if (mark == Mark::Horn && target >= 1 && letters_[target].base == 'u' &&
                    letters_[target].mark == Mark::None && letters_[target - 1].base == 'u' &&
                    !(target >= 2 && letters_[target - 2].base == 'q'))
                    target -= 1;
                if (letters_[target].mark == Mark::None) {
                    letters_[target].mark = mark;
                    rawLetter_[at] = target;
                    return;
                }
                if (letters_[target].mark == mark) {
                    letters_[target].mark = Mark::None;
                    pCancelled_ = true;
                    appendLetter(key, Mark::None, false);
                    rawLetter_[at] = pCount_ - 1;
                    return;
                }
                // Hat <-> hook/breve swap (issue #149): 8 on â -> ă, 6 on ă -> â,
                // 7 on ô -> ơ, 6 on ơ -> ô (ươ -> uô via setCircumflex). Tone kept.
                if (letters_[target].mark != Mark::Bar) {
                    if (mark == Mark::Circumflex) setCircumflex(target);
                    else letters_[target].mark = mark;
                    rawLetter_[at] = target;
                    return;
                }
                break;   // conflicting mark -> literal digit
            }
        }
        appendLetter(key, Mark::None, false);
        rawLetter_[at] = pCount_ - 1;
        return;
    }
    appendLetter(key, Mark::None, false);
    rawLetter_[at] = pCount_ - 1;
}

// MARK: - Tone placement (old style: òa, úy)

int TelexEngine::toneVowelIndex(int count) {
    int vcount = 0;
    int start = 0;
    if (count >= 2 && renderLetters_[0].base == 'q' && renderLetters_[1].base == 'u' &&
        renderLetters_[1].mark == Mark::None) {
        start = 2;
    } else if (count >= 3 && renderLetters_[0].base == 'g' && renderLetters_[1].base == 'i' &&
               renderLetters_[1].mark == Mark::None && isVowelAscii(renderLetters_[2].base)) {
        start = 2;
    }
    for (int k = start; k < count; ++k)
        if (isVowelAscii(renderLetters_[k].base)) vowelIdx_[vcount++] = k;
    if (vcount == 0) {
        for (int k = 0; k < count; ++k)
            if (isVowelAscii(renderLetters_[k].base)) return k;
        return count - 1;
    }
    int lastMarked = -1;
    for (int j = 0; j < vcount; ++j)
        if (renderLetters_[vowelIdx_[j]].mark != Mark::None) lastMarked = vowelIdx_[j];
    if (lastMarked >= 0) return lastMarked;
    if (vcount == 1) return vowelIdx_[0];
    const bool hasCoda = vowelIdx_[vcount - 1] < (count - 1);
    if (vcount == 2) {
        if (hasCoda) return vowelIdx_[1];
        if (modernTone) {
            uint8_t a = renderLetters_[vowelIdx_[0]].base, b = renderLetters_[vowelIdx_[1]].base;
            bool glideInitial = (a == 'o' && (b == 'a' || b == 'e')) || (a == 'u' && b == 'y');
            if (glideInitial) return vowelIdx_[1];
        }
        return vowelIdx_[0];
    }
    return vowelIdx_[1];
}

// MARK: - Diffing

void TelexEngine::diff(int newCount, Action& out) const {
    int lcp = commonPrefixLength(scratch_, out_, newCount < outCount_ ? newCount : outCount_);
    int backspaces = outCount_ - lcp;
    if (backspaces == 0 && lcp == newCount) { setReplace(out, 0, scratch_, 0); return; }
    setReplace(out, backspaces, scratch_ + lcp, newCount - lcp);
}

// MARK: - Small helpers

bool TelexEngine::standaloneHornUAllowed(int count) const {
    int32_t node = 0;
    for (int k = 0; k < count; ++k) {
        node = gen::kStandaloneU.step(node, static_cast<uint8_t>(letters_[k].base - 'a'));
        if (node < 0) return false;
    }
    return gen::kStandaloneU.mask(node) != 0;
}

bool TelexEngine::hasVowel(int count) const {
    for (int k = 0; k < count; ++k)
        if (isVowelAscii(letters_[k].base)) return true;
    return false;
}

bool TelexEngine::isUkRime(int count) const {
    return count >= 2 && renderLetters_[count - 1].base == 'k' && renderLetters_[count - 2].base == 'u' &&
           renderLetters_[count - 2].mark == Mark::Horn;
}

bool TelexEngine::hasStopCoda(int count) const {
    if (count <= 0) return false;
    uint8_t last = renderLetters_[count - 1].base;
    if (last == 'p' || last == 't' || last == 'c' || last == 'k') return true;
    return last == 'h' && count >= 2 && renderLetters_[count - 2].base == 'c';
}

bool TelexEngine::lettersHaveStopCoda(int count) const {
    if (count <= 0) return false;
    uint8_t last = letters_[count - 1].base;
    if (last == 'p' || last == 't' || last == 'c' || last == 'k') return true;
    return last == 'h' && count >= 2 && letters_[count - 2].base == 'c';
}

bool TelexEngine::lettersAreUkRime(int count) const {
    return count >= 2 && letters_[count - 1].base == 'k' && letters_[count - 2].base == 'u' &&
           letters_[count - 2].mark == Mark::Horn;
}

bool TelexEngine::stopCodaRejectsTone(Tone tone) const {
    if (!(tone == Tone::Grave || tone == Tone::Hook || tone == Tone::Tilde)) return false;
    if (!lettersHaveStopCoda(pCount_)) return false;
    if (tone == Tone::Grave && lettersAreUkRime(pCount_)) return false;
    return true;
}

void TelexEngine::appendLetter(uint8_t base, Mark mark, bool upper) {
    if (pCount_ >= kCapacity) return;
    letters_[pCount_] = Letter{base, mark, upper};
    pCount_ += 1;
}

} // namespace vtx
