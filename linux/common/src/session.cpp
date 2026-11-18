// session.cpp — see session.h. Behaviour is ported from the macOS controller
// (App/Sources/TelexInputController.swift): the marked-text path maps to Preedit, the
// in-place path to Surrounding.
#include "viettelex/session.h"

#include "telexcore.h"

#include <algorithm>
#include <chrono>
#include <cstring>
#include <ctime>
#include <vector>

namespace viettelex {

namespace {

size_t utf8Chars(const std::string &s) {
    size_t n = 0;
    for (unsigned char c : s)
        if ((c & 0xc0) != 0x80) ++n;
    return n;
}

std::string encode(uint32_t cp) {
    std::string o;
    if (cp < 0x80) o += char(cp);
    else if (cp < 0x800) { o += char(0xc0 | (cp >> 6)); o += char(0x80 | (cp & 0x3f)); }
    else if (cp < 0x10000) {
        o += char(0xe0 | (cp >> 12)); o += char(0x80 | ((cp >> 6) & 0x3f)); o += char(0x80 | (cp & 0x3f));
    } else {
        o += char(0xf0 | (cp >> 18)); o += char(0x80 | ((cp >> 12) & 0x3f));
        o += char(0x80 | ((cp >> 6) & 0x3f)); o += char(0x80 | (cp & 0x3f));
    }
    return o;
}

// Removes the last UTF-8 character of s into `last`; false if s is empty.
bool popChar(std::string &s, std::string &last) {
    if (s.empty()) return false;
    size_t i = s.size() - 1;
    while (i > 0 && (static_cast<unsigned char>(s[i]) & 0xc0) == 0x80) --i;
    last = s.substr(i);
    s.resize(i);
    return true;
}

uint32_t decodeOne(const std::string &c) {
    unsigned char b = c[0];
    uint32_t cp;
    size_t n;
    if (b < 0x80) return b;
    if ((b >> 5) == 6) { cp = b & 0x1f; n = 2; }
    else if ((b >> 4) == 14) { cp = b & 0x0f; n = 3; }
    else { cp = b & 0x07; n = 4; }
    for (size_t k = 1; k < n && k < c.size(); ++k) cp = (cp << 6) | (c[k] & 0x3f);
    return cp;
}

bool isAsciiLetter(uint32_t c) { return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z'); }
bool isDigit(uint32_t c) { return c >= '0' && c <= '9'; }
bool isBracket(uint32_t c) { return c == '[' || c == ']' || c == '{' || c == '}' || c == '(' || c == ')'; }
bool isBracketVowelKey(uint32_t c) { return c == '[' || c == ']' || c == '{' || c == '}'; }
// TelexInputController.gluesShortcutToken — #82 số, #87 / # @
bool gluesShortcutToken(uint32_t c) { return isDigit(c) || c == '/' || c == '#' || c == '@'; }

// A letter a Vietnamese word on screen can contain (for re-edit's trailing-word scan).
bool isWordLetter(uint32_t c) {
    return isAsciiLetter(c) || (c >= 0xc0 && c <= 0x24f && c != 0xd7 && c != 0xf7) ||
           (c >= 0x1ea0 && c <= 0x1ef9);
}

// TelexInputController.isDiacriticOnlyKey
bool isDiacriticOnlyKey(uint32_t c, bool vni) {
    if (vni) return isDigit(c);
    switch (c | 0x20) {
    case 's': case 'f': case 'r': case 'x': case 'j': case 'z': case 'w': return true;
    default: return false;
    }
}

bool isNewlineKey(uint32_t k) { return k == ks::Return || k == ks::KP_Enter; }

bool endsWithBytes(const std::string &s, const std::string &suffix) {
    return s.size() >= suffix.size() && s.compare(s.size() - suffix.size(), suffix.size(), suffix) == 0;
}

// A combining mark (U+0300–U+036F): the host keeps the text decomposed (NFD).
bool isCombiningMark(uint32_t c) { return c >= 0x300 && c <= 0x36f; }

// Verify-before-delete: what the host reports right before the caret vs. `expected`, the
// text the Session put there. Byte-exact on purpose: deletes count characters, so an NFD
// host (same letters, more code points) is a mismatch, not a match.
//   Match    — the expected text is there.
//   Stale    — the host has not applied our latest commits yet: it ends with a strict prefix
//              of `expected` (or reports nothing at all). The IM channel is ordered, so a
//              delete sent now still lands after those commits — but nothing proves it.
//   Mismatch — anything else: the text was changed under us.
// Never waits for the host to catch up (fcitx5-lotus #487: sleeping in the key path).
// `expected` is one word (<= 32 keys): the prefix scan is a handful of short compares.
enum class Screen { Match, Stale, Mismatch };
Screen checkScreen(const std::string &before, const std::string &expected) {
    if (endsWithBytes(before, expected)) return Screen::Match;
    if (before.empty()) return Screen::Stale;
    size_t k = expected.size();
    while (k > 0) {
        --k;
        while (k > 0 && (static_cast<unsigned char>(expected[k]) & 0xc0) == 0x80) --k;
        if (k > 0 && before.size() >= k && before.compare(before.size() - k, k, expected, 0, k) == 0)
            return Screen::Stale;
    }
    return Screen::Mismatch;
}

}  // namespace

bool InputContext::textBeforeCursorTail(size_t maxChars, std::string &out) {
    if (!textBeforeCursor(out)) return false;
    size_t i = out.size();
    for (size_t n = 0; i > 0 && n < maxChars; ++n) {
        --i;
        while (i > 0 && (static_cast<unsigned char>(out[i]) & 0xc0) == 0x80) --i;
    }
    out.erase(0, i);
    return true;
}

Session::Session() : e_(vt_engine_new()) {
    nowMs_ = [] {
        using namespace std::chrono;
        return int64_t(duration_cast<milliseconds>(steady_clock::now().time_since_epoch()).count());
    };
    applySettings(Settings());
}

void Session::distrust() {
    if (distrusted_) return;
    distrusted_ = true;
    surroundingEdits_ = false;
    ackDrop();
    if (mode_ == DisplayMode::Surrounding) {
        // Callers have just dropped the word (vt_reset): switch now, else at the word's end.
        pendingMode_ = DisplayMode::Preedit;
        hasPendingMode_ = true;
        applyPendingMode();
    } else if (hasPendingMode_ && pendingMode_ == DisplayMode::Surrounding) {
        pendingMode_ = DisplayMode::Preedit;
    }
}

int clampDeleteToReport(int requested, long reportedBefore) {
    if (requested <= 0) return 0;
    if (reportedBefore < 0) return requested;  // no surrounding text: no limit known
    return reportedBefore < long(requested) ? int(reportedBefore) : requested;
}

bool Session::deleteFitsReport(InputContext &ic, int n) {
    return n <= 0 || clampDeleteToReport(n, ic.reportedCharsBeforeCursor()) == n;
}

bool Session::inPlaceAllowed(InputContext &ic, const std::string &expected, int deletes) {
    if (mode_ != DisplayMode::Surrounding || expected.empty()) return true;
    // Key edits not shown yet, but everything the host shows is one of the states our
    // ordered operations pass through (checkKeyEdit, this key event): BackSpaces sent now
    // land after them.
    if (deleteWithKeys_ && ackLagging_) return true;
    // Delete-surrounding: never reach past the start of what the client last reported (GNOME
    // Wayland aborts the shell). A report still lagging behind our commits at the start of
    // the field ("" while "vie" is on its way) is the usual case: Stale below would let it
    // through. The field goes to preedit; this key is typed as is (the caller).
    if (!deleteWithKeys_ && !deleteFitsReport(ic, deletes < 0 ? int(utf8Chars(expected)) : deletes)) {
        distrust();
        return false;
    }
    // Key edits keep a trail of what was typed before the word too: a host still behind the
    // boundary ("việt" shown, "việt l" typed) is then recognised as lagging, not as wrong.
    const std::string &want = deleteWithKeys_ && endsWithBytes(ackTrail_, expected) ? ackTrail_ : expected;
    std::string before;
    // A host that reports nothing cannot be checked: as before (Surrounding is only chosen
    // where the text was proven).
    if (!ic.textBeforeCursorTail(utf8Chars(want), before)) return true;
    if (checkScreen(before, want) != Screen::Mismatch) return true;  // Stale: ordered channel
    distrust();
    return false;
}

void Session::replace(InputContext &ic, int backspaces, const std::string &insert, const std::string &base) {
    if (mode_ == DisplayMode::Direct) {
        if (backspaces > 0 || !insert.empty()) ic.directReplace(backspaces, insert);
    } else {
        replaceBeforeCursor(ic, backspaces, insert, base);
    }
}

// Surrounding-mode edit. A delete with nothing to insert is followed by an empty commit:
// Wayland text-input-v3 applies delete_surrounding_text only together with a commit
// (Keyman engine.c apply_changes). Key edits need no such commit.
void Session::replaceBeforeCursor(InputContext &ic, int backspaces, const std::string &insert,
                                  const std::string &base) {
    if (deleteWithKeys_ && mode_ == DisplayMode::Surrounding) {
        if (backspaces > 0) ic.forwardBackspaces(backspaces);
        if (!insert.empty()) ic.commit(insert);
        if (backspaces > 0) ackArm(base, backspaces, insert);
        else if (!insert.empty()) ackAppend(insert);
        return;
    }
    if (!deleteFitsReport(ic, backspaces)) {
        // Callers check inPlaceAllowed / read the text back first: this is the last line for
        // the rest (no read possible). No delete (crash guard), and no half edit either.
        distrust();
        return;
    }
    if (backspaces > 0) ic.deleteBeforeCursor(backspaces);
    if (!insert.empty()) ic.commit(insert);
    else if (backspaces > 0) ic.commit("");
}

// MARK: - key-edit confirmation ([experimental] no_underline = "forward-keys")

namespace {
constexpr size_t kAckKeepChars = 48;  // a word + its boundary + the next word, more than enough
constexpr size_t kAckMaxStates = 16;  // a host lagging further than this is not followed
constexpr size_t kAckContext = 8;     // host text kept before our own, once confirmed

// Keeps the last kAckKeepChars characters; false when something was cut.
bool keepTail(std::string &s) {
    if (utf8Chars(s) <= kAckKeepChars) return true;
    size_t i = s.size();
    for (size_t n = 0; i > 0 && n < kAckKeepChars; ++n) {
        --i;
        while (i > 0 && (static_cast<unsigned char>(s[i]) & 0xc0) == 0x80) --i;
    }
    s.erase(0, i);
    return false;
}
}  // namespace

bool Session::tracking() const { return deleteWithKeys_ && mode_ == DisplayMode::Surrounding; }

void Session::ackTrim() {
    if (!keepTail(ackTrail_)) ackWhole_ = false;
}

void Session::ackPushTrail() {
    // "" would match any host text: an empty trail is simply not a state.
    if (ackTrail_.empty() || (!ackStates_.empty() && ackStates_.back() == ackTrail_)) return;
    ackStates_.push_back(ackTrail_);
    if (ackStates_.size() > kAckMaxStates) ackStates_.erase(ackStates_.begin());
}

void Session::ackArm(const std::string &base, int backspaces, const std::string &insert) {
    // The trail lost track of what is before the caret (caret moved mid-word…): restart from
    // the word itself, unanchored.
    if (!endsWithBytes(ackTrail_, base)) {
        ackStates_.clear();
        ackTrail_ = base;
        ackAnchored_ = ackWhole_ = ackSeeded_ = false;  // the seed was for another start
    }
    ackPushTrail();  // the host may not have applied this edit yet
    if (!ackPending_) {
        ackPending_ = true;
        ackSinceMs_ = nowMs_ ? nowMs_() : 0;
    }
    std::string last;
    for (int i = 0; i < backspaces; ++i) {
        if (!popChar(ackTrail_, last)) {  // deleting past what we know: the result is unknown
            ackDrop();
            return;
        }
        ackPushTrail();  // the app handles each BackSpace key on its own
    }
    ackTrail_ += insert;
    ackTrim();
    ackPushTrail();
}

void Session::ackAppend(const std::string &s) {
    if (!tracking() || s.empty()) return;
    if (ackStates_.empty()) ackPushTrail();
    ackTrail_ += s;
    ackTrim();
    ackPushTrail();
}

void Session::ackPop() {
    if (!tracking()) return;
    std::string last;
    if (!popChar(ackTrail_, last) || ackTrail_.empty()) {
        ackDrop();  // ⌫ past the text we know: nothing left to compare
        return;
    }
    ackPushTrail();
}

Session::Ack Session::checkKeyEdit(InputContext &ic) {
    // Nothing typed since the host last showed the trail, and it is anchored: nothing to do.
    if (ackStates_.size() < 2 && !ackPending_ && (ackAnchored_ || ackTrail_.empty())) return Ack::None;
    // Not anchored yet but seeded: every state is preceded by what the host showed when the
    // trail started. Without that, "yỳ" would pass for "ỳ" (the first edit's BackSpace lost)
    // and a lone " " would match the host's own space.
    const bool seeded = !ackAnchored_ && ackSeeded_;
    const std::string prefix = seeded ? ackSeed_ : std::string();
    // All the text there is before the caret is known: compare whole strings, not suffixes.
    const bool whole = ackAnchored_ ? ackWhole_ : seeded && ackSeedWhole_;
    size_t longest = utf8Chars(ackTrail_);  // an older state may be longer ("yfn" → "ỳ")
    for (const std::string &st : ackStates_) longest = std::max(longest, utf8Chars(st));
    const size_t asked = utf8Chars(prefix) + longest + kAckContext;
    std::string before;
    // A host that stops reporting (or reports nothing) cannot confirm: lagging until timeout.
    bool reported = ic.textBeforeCursorTail(asked, before) && !before.empty();
    auto shows = [&](const std::string &st) {
        std::string full = prefix + st;
        return whole ? before == full : endsWithBytes(before, full);
    };
    if (reported && shows(ackTrail_)) {
        // The host shows everything we sent: from here the trail also covers the host's own
        // text before it (a BackSpace lost there later shows up).
        ackTrail_ = before;
        ackWhole_ = utf8Chars(before) < asked;
        ackAnchored_ = true;
        ackSeeded_ = false;
        ackTrim();
        ackStates_.assign(1, ackTrail_);
        ackPending_ = false;
        return Ack::Confirmed;
    }
    // Lagging = the host shows exactly one of the states our ordered operations passed through
    // (every BackSpace, commit and app-typed key is one), or — seeded — none of them yet.
    // Unanchored and unseeded (the host reported nothing when the trail started), a strict
    // prefix of the oldest state also counts (checkScreen's Stale).
    bool consistent = !reported;
    for (size_t i = 0; reported && !consistent && i < ackStates_.size(); ++i) consistent = shows(ackStates_[i]);
    if (reported && !consistent && seeded) consistent = whole ? before == prefix : endsWithBytes(before, prefix);
    if (reported && !consistent && !ackAnchored_ && !seeded && !ackStates_.empty())
        consistent = checkScreen(before, ackStates_.front()) == Screen::Stale;
    if (!consistent) {
        if (ackPending_) return Ack::Failed;
        // Only plain typing since the last confirmation: the page changed its own text
        // (autocomplete, emoji…) — nothing of ours to blame. Start over.
        ackDrop();
        return Ack::None;
    }
    int64_t now = nowMs_ ? nowMs_() : 0;
    if (ackPending_ && now - ackSinceMs_ > kKeyEditAckTimeoutMs) return Ack::Failed;  // doubt
    return Ack::Lagging;
}

// The host's text is not what our key edits made (lost / doubled BackSpace, duplicated or
// dropped commit, the page rewrote it) or never caught up: stop editing in place for this
// focus. The word being typed is left on screen as it is; the next keys compose in preedit.
void Session::failKeyEdit() {
    ackDrop();
    vt_reset(e_);
    preedit_.clear();
    distrust();
}

Session::~Session() { vt_engine_free(e_); }

void Session::applySettings(const Settings &s) {
    vt_engine_set_flag(e_, VT_FLAG_FREE_MARKING, s.freeMarking);
    vt_engine_set_flag(e_, VT_FLAG_MODERN_TONE, s.modernTone);
    vt_engine_set_flag(e_, VT_FLAG_LIVE_SPELL_CHECK, s.spellCheck);
    vt_engine_set_flag(e_, VT_FLAG_SIMPLE_TELEX, s.simpleTelex);
    vt_engine_set_flag(e_, VT_FLAG_TEENCODE, s.teencode);
    vt_engine_set_flag(e_, VT_FLAG_AUTO_CIRCUMFLEX, s.autoCircumflex);
    vt_engine_set_flag(e_, VT_FLAG_QUICK_TELEX, s.quickTelex);
    vt_engine_set_flag(e_, VT_FLAG_BRACKET_VOWELS, s.bracketVowels);
    vt_engine_set_flag(e_, VT_FLAG_VNI, s.vni);
    vt_engine_set_flag(e_, VT_FLAG_CONTEXTUAL_ENGLISH, s.contextualEnglish);
    // "Tự sửa từ phía trước": only with contextual_english (the engine ignores it otherwise).
    // Off = nothing; on = the engine flag, the switch picks auto-apply vs offer (Tab).
    retroMode_ = retro::modeFor(s.contextualEnglish, s.retroactiveEnglish);
    retroOn_ = retroMode_ != retro::Mode::Off;
    vt_engine_set_flag(e_, VT_FLAG_RETRO_ENGLISH, retroOn_);
    // "Đoán từ trùng theo tần suất": only with the retro flag (inert without it).
    vt_engine_set_flag(e_, VT_FLAG_ENGLISH_BY_FREQUENCY, retroOn_ && s.englishByFrequency);
    if (retroMode_ != retro::Mode::Auto) retroUndo_.clear();
    vt_engine_set_flag(e_, VT_FLAG_COLLISION_PREFERS_VIETNAMESE, s.collisionPrefersVietnamese);
    // "goog" not "gôg" mid-word — only with auto-restore (else the boundary keeps "gôgle").
    vt_engine_set_flag(e_, VT_FLAG_EAGER_ENGLISH_RESTORE, s.autoRestore);
    autoRestore_ = s.autoRestore;
    underlineMisspelled_ = s.underlineMisspelled;
    shortcutsEnabled_ = s.shortcutsEnabled;
    reEdit_ = s.reEditWord;
    vni_ = s.vni;
    bracketVowels_ = s.bracketVowels;
    shortcuts_ = s.shortcuts ? s.shortcuts : std::make_shared<ShortcutTable>();
    hasTokenKeys_ = false;
    for (const auto &kv : *shortcuts_)
        if (isTokenShortcutKey(kv.first)) { hasTokenKeys_ = true; break; }
    Hotkey hk;
    hotkeyValid_ = parseHotkey(s.toggleHotkey, hk);
    hotkeySym_ = hk.keysym;
    hotkeyMods_ = hk.mods;
    Hotkey at;
    addTonesValid_ = parseHotkey(s.addTonesHotkey, at) &&
                     !(hotkeyValid_ && at.keysym == hotkeySym_ && at.mods == hotkeyMods_);
    addTonesSym_ = at.keysym;
    addTonesMods_ = at.mods;
    hintFlags_.math = s.mathResults;
    hintFlags_.number = s.numberChips;
    hintFlags_.typo = s.typoHints;
    hintFlags_.tones = s.toneHints;
    hintFlags_.date = s.dateHints;
    // TypoFixLogic.EngineFlags(bits:) order (Serve.swift) — the helper composes candidates
    // with the same engine settings as the typing engine.
    const bool bits[] = {s.freeMarking, s.modernTone,      s.spellCheck,        s.simpleTelex,
                         s.quickTelex,  s.vni,             s.bracketVowels,     s.contextualEnglish,
                         s.collisionPrefersVietnamese,      s.teencode,          s.autoCircumflex};
    engineBits_.clear();
    for (bool b : bits) engineBits_ += b ? '1' : '0';
    period_ = s.doubleSpacePeriod;
    capitalize_ = s.autoCapitalize;
    smart_ = s.smartPunctuation;
    predict_ = s.wordPrediction;
    filter_ = s.filterSensitive;
    learnWords_ = s.learnWords;
    quotes_ = autotext::quotesFor(s.quoteStyle);
    if (!predict_) {
        declinedPrediction_.clear();
        declinedEmail_ = false;
    }
    if (!learnOn()) learn_.discard();
    if (!period_) lastSpaceMs_ = -1;
    if (!smart_) lastEmDashOurs_ = false;
    if (!capitalize_) autoCappedWord_ = suppressAutoCap_ = false;
    updateHintsOn();
    if (!hintsOn_) tailReset();
}

// MARK: - caret suggestions (caret_hints.h)

namespace {
constexpr size_t kTailKeep = 320;  // ToneRunLogic.window
const char *const kUnknownHead = "\xef\xbf\xbc";  // U+FFFC: text before the tail is unknown

bool endsWith(const std::string &s, const std::string &suffix) {
    return s.size() >= suffix.size() && s.compare(s.size() - suffix.size(), suffix.size(), suffix) == 0;
}

// Byte offset of the last `n` characters of s (0 when s is shorter).
size_t lastCharsOffset(const std::string &s, size_t n) {
    size_t i = s.size();
    while (i > 0 && n > 0) {
        --i;
        while (i > 0 && (static_cast<unsigned char>(s[i]) & 0xc0) == 0x80) --i;
        --n;
    }
    return i;
}

bool isTailSpace(char c) { return c == ' ' || c == '\t' || c == '\n' || c == '\r'; }
}  // namespace

void Session::setHintSink(std::function<void(const HintRequest &)> sink) {
    hintSink_ = std::move(sink);
    updateHintsOn();
    if (!hintsOn_) tailReset();
}

std::string Session::typedBefore() const {
    switch (tailHead_) {
    case TailHead::Start: return tail_;
    case TailHead::Newline: return "\n" + tail_;
    default: return kUnknownHead + tail_;
    }
}

void Session::tailReset() {
    tail_.clear();
    tailHead_ = TailHead::Unknown;
    tailSeeded_ = false;
    toneTracker_.reset();
}

void Session::tailAppend(const std::string &s) {
    tail_ += s;
    if (tail_.size() > kTailKeep * 4 || utf8Chars(tail_) > kTailKeep + 64) {
        tail_.erase(0, lastCharsOffset(tail_, kTailKeep));
        tailHead_ = TailHead::Unknown;
    }
}

void Session::tailPop(size_t chars) {
    if (utf8Chars(tail_) < chars) {
        // Deleting into text we never saw: what is before the caret is unknown now.
        tail_.clear();
        tailHead_ = TailHead::Unknown;
        return;
    }
    tail_.resize(lastCharsOffset(tail_, chars));
}

// First key after the caret moved: the text before it, when the client reports it reliably.
void Session::seedTail(InputContext &ic) {
    tailSeeded_ = true;
    tail_.clear();
    tailHead_ = TailHead::Unknown;
    std::string before;
    // Mid-word (hints just turned on): the word is not on screen as such — start blind.
    // One character more than kept: getting it back means there is text before the tail.
    // (The tail only: a long paragraph is never copied whole.)
    if (!vt_is_empty(e_) || mode_ == DisplayMode::Direct || !surroundingEdits_ ||
        !ic.textBeforeCursorTail(kTailKeep + 1, before))
        return;
    if (utf8Chars(before) <= kTailKeep) {
        tail_ = before;
        tailHead_ = TailHead::Start;
    } else {
        tail_ = before.substr(lastCharsOffset(before, kTailKeep));
    }
}

void Session::requestHint(std::vector<std::string> fields, int delayMs, std::vector<std::string> fallback,
                          int fallbackDelayMs) {
    if (!hintSink_) return;
    HintRequest r;
    r.line = hints::request(fields);
    r.delayMs = delayMs;
    r.gen = keyGen_->load();
    r.liveGen = keyGen_;
    if (!fallback.empty()) {
        r.fallback = hints::request(fallback);
        r.fallbackDelayMs = fallbackDelayMs;
    }
    hintSink_(r);
}

// Context of a word-prediction request. Unlike the other suggestions, an unknown text before
// the typed tail is NOT marked (U+FFFC): the first word typed after a focus / click in a field
// whose text is not readable (Chrome, Firefox, Electron — preedit) is taken to stand alone, so
// "cảm␣" there still offers "ơn". Only a suggestion; nothing is replaced but the word being
// typed (macOS reads the screen instead, which Linux cannot do in those fields).
std::string Session::predictBefore() const { return tailHead_ == TailHead::Newline ? "\n" + tail_ : tail_; }

// Word prediction after a space ("cảm ␣" → ơn): the helper request, or {} when not asked.
std::vector<std::string> Session::nextWordRequest() {
    if (!predict_ || !hintSink_ || !autoTextHere() || !vt_is_empty(e_) || !autotext::nextWordWorthAsking(tail_))
        return {};
    declinedPrediction_.clear();  // a new word: the old Esc no longer applies
    std::vector<std::string> r = {"predict", predictBefore(), "", "", vt_previous_word_english(e_) ? "1" : "0"};
    if (!filter_ || learnOn()) r.push_back(filter_ ? "1" : "0");  // "Lọc từ nhạy cảm" (absent = on)
    if (learnOn()) r.push_back("1");                                // "Học từ bạn gõ" (absent = off)
    return r;
}

// Completion of the word being typed ("đư" → được / đường / đưa), after kPredictIdleMs of no
// typing (HintService waits; any key moves the generation on and cancels it).
void Session::schedulePrediction(const std::string &typed, const std::string &rawKeys) {
    // Preedit: the word is the composition (nothing on screen to replace); Surrounding: it is
    // on screen and only replaced where the Session may edit.
    if (!autoTextHere() || (mode_ == DisplayMode::Surrounding && !surroundingEdits_)) return;
    if (!autotext::completionWorthAsking(typed) || autotext::predictionMuted(typed, declinedPrediction_)) return;
    std::vector<std::string> r = {"predict", predictBefore() + typed, typed, rawKeys,
                                  vt_previous_word_english(e_) ? "1" : "0"};
    if (!filter_ || learnOn()) r.push_back(filter_ ? "1" : "0");  // "Lọc từ nhạy cảm" (absent = on)
    if (learnOn()) r.push_back("1");                                // "Học từ bạn gõ" (absent = off)
    requestHint(std::move(r), autotext::kPredictIdleMs);
}

// A printable boundary (or Enter / Tab / navigation) was just handled: keep the typed tail
// in step with the screen, then fire the cheap triggers (MathHint.swift afterEquals /
// afterNumberSpace, CaretSuggestions.swift afterWord — same order: date, typo, tones).
// Word prediction after a space comes last, as a fallback: any other suggestion wins.
void Session::afterBoundary(uint32_t ch, uint32_t keysym, const std::string *typed) {
    if (learnOn()) learnAtBoundary(ch, keysym);
    else if (learn_.hasPending() || !learn_.prev1().empty()) learn_.discard();
    if (isNewlineKey(keysym)) {
        tail_.clear();
        tailHead_ = TailHead::Newline;
        tailSeeded_ = true;
        toneTracker_.reset();
        return;
    }
    if (ch == 0x1b || ch == 0x7f) return;  // Esc / Delete: nothing typed, caret stays
    if (ch < 0x20 || keysym == ks::Tab) {  // navigation, Tab (focus may move), other keys
        tailReset();
        return;
    }
    // The run just committed before this boundary, and the one before it (ShortcutTail.run).
    size_t end = tail_.size(), s = end;
    while (s > 0 && !isTailSpace(tail_[s - 1])) --s;
    std::string run = tail_.substr(s);
    size_t pe = s;
    while (pe > 0 && isTailSpace(tail_[pe - 1])) --pe;
    size_t ps = pe;
    while (ps > 0 && !isTailSpace(tail_[ps - 1])) --ps;
    std::string prevRun = tail_.substr(ps, pe - ps);
    std::string boundary = typed ? *typed : encode(ch);
    tailAppend(boundary);

    hints::ToneTrigger tt = hintFlags_.tones ? toneTracker_.feed(run, ch) : hints::ToneTrigger::None;
    // The text the helper sees is built only when a trigger fires.
    if (ch == '=') {
        if (hintFlags_.math) requestHint({"math", typedBefore()});
        return;
    }
    std::vector<std::string> primary;
    int delayMs = 0;
    // Everything else replaces committed text: only where the Session may edit before the
    // caret (surrounding proven, or Direct's blind BackSpaces) — macOS `canReplace`.
    if (mode_ != DisplayMode::Direct && !surroundingEdits_) {
    } else if (hintFlags_.number && hints::numberWorthChecking(ch, run, prevRun)) {
        primary = {"number", typedBefore()};
    } else if (hintFlags_.date && hints::dateCandidate(ch, prevRun, run)) {
        std::time_t t = std::time(nullptr);
        std::tm lt{};
        localtime_r(&t, &lt);
        primary = {"date", typedBefore(), prevRun, run, boundary, std::to_string(lt.tm_year + 1900),
                   std::to_string(lt.tm_mon + 1), std::to_string(lt.tm_mday), std::to_string(lt.tm_hour),
                   std::to_string(lt.tm_min)};
    } else if (hintFlags_.typo && lastEnded_.ended && !lastEnded_.raw.empty() && lastEnded_.text == run &&
               hints::typoWorthChecking(ch, lastEnded_.raw, run) && !rejectedTypos_.contains(run) &&
               // An unaccented syllable ("hoc" = học/hóc) is never a typo for TypoFixLogic (the
               // lexicon has a toned completion); skipping it here keeps it from masking Thêm dấu.
               !vt_is_unaccented_syllable(run.c_str())) {
        // An English word of the engine's list: the helper would answer "no fix" (isKnown) —
        // same outcome without waking it (it stays asleep while typing English).
        if (!hints::typoKnownEnglish(lastEnded_.raw)) {
            primary = {"typo", typedBefore(), run, boundary, lastEnded_.raw, engineBits_};
            if (!filter_) primary.push_back("0");  // "Lọc từ nhạy cảm" off (absent = on)
        }
    } else if (tt != hints::ToneTrigger::None) {
        primary = {"tones", typedBefore()};
        delayMs = tt == hints::ToneTrigger::Pause ? 900 : 0;  // ToneRunLogic.pauseDelay
    }
    std::vector<std::string> next;
    if (ch == ' ' && predict_) next = nextWordRequest();
    if (!primary.empty()) requestHint(std::move(primary), delayMs, std::move(next), autotext::kPredictIdleMs);
    else if (!next.empty()) requestHint(std::move(next), autotext::kPredictIdleMs);
}

// MARK: Học từ bạn gõ

// The word this Session just composed and committed at this boundary (endWord: lastEnded_, with
// raw keys — "" for a shortcut expansion, never learned) is the last run of the typed tail; it
// stands alone there by construction (the run starts after a space / where the tail starts).
void Session::learnAtBoundary(uint32_t ch, uint32_t keysym) {
    size_t s = tail_.size();
    while (s > 0 && !isTailSpace(tail_[s - 1])) --s;
    const std::string run = tail_.substr(s);
    const bool ours = lastEnded_.ended && !lastEnded_.raw.empty() && lastEnded_.text == run;
    const std::string word = ours ? run : std::string();
    hints::LearnTracker::Event e;
    const bool keepsLine = ch >= 0x20 && ch != 0x7f && keysym != ks::Tab && !isNewlineKey(keysym);
    if (keepsLine) {
        if (learn_.commit(word, ch, true, 1, e)) learnSend(e);
        return;
    }
    // Enter / Tab / Esc / navigation: the word is final, the sentence context ends.
    if (!word.empty() && learn_.commit(word, '\n', true, 1, e)) learnSend(e);
    if (learn_.breakContext(e)) learnSend(e);
}

void Session::learnSend(const hints::LearnTracker::Event &e) {
    if (!hintSink_) return;
    HintRequest r;
    r.line = hints::learnRequest(e);
    r.oneway = true;
    hintSink_(r);
}

void Session::learnFlush() {
    hints::LearnTracker::Event e;
    if (learn_.breakContext(e) && learnOn()) learnSend(e);
}

void Session::deliverHint(uint64_t gen, const CaretSuggestion &s, InputContext &ic) {
    if (!hintsOn_ || gen != keyGen_->load() || passthrough_ || !vietnamese_) return;
    if (hint_ && hint_->kind == CaretSuggestion::Kind::Retro) return;  // the retro offer wins
    if (s.kind == CaretSuggestion::Kind::Predict) {
        // Every other suggestion wins (CaretHint.present); never in terminals.
        if (!predict_ || hint_ || mode_ == DisplayMode::Direct) return;
        if (s.replace.empty()) {
            if (!vt_is_empty(e_) || !endsWith(tail_, " ")) return;  // next word: right after the space
        } else {
            // completion: the word being composed is still exactly what was asked about
            if (vt_is_empty(e_) || composed() != s.replace) return;
            if (mode_ == DisplayMode::Surrounding && !surroundingEdits_) return;
            if (autotext::predictionMuted(s.replace, declinedPrediction_)) return;
        }
        hint_ = s;
        ic.showPrediction(s.display, "Tab");
        return;
    }
    if (!vt_is_empty(e_)) return;
    if (!s.replace.empty() && mode_ != DisplayMode::Direct && !surroundingEdits_) return;
    if (!endsWith(tail_, s.replace)) return;  // the typed text moved on
    if (s.kind == CaretSuggestion::Kind::Tones && !declinedTones_.empty() &&
        s.replace.compare(0, declinedTones_.size(), declinedTones_) == 0)
        return;
    if (hint_) ic.hideHint();  // a word prediction was shown: this one replaces it
    hint_ = s;
    ic.showHint(hints::label(s));
}

bool Session::chooseHint(InputContext &ic) {
    if (!hint_ || (hint_->kind != CaretSuggestion::Kind::Predict && hint_->kind != CaretSuggestion::Kind::Email))
        return false;
    selectionMemo_ = -1;
    if (hintsOn_) keyGen_->fetch_add(1);
    if (hint_->kind == CaretSuggestion::Kind::Email) return applyEmailDomain(ic);
    return applyPrediction(hint_->display, ic);
}

// Email-domain suggestion ("user@" → gmail.com, "user@ic" → icloud.com; iOS/Android
// EmailDomains): after '@' / '.' / '-' and after each letter composed behind them. Shown at once —
// a string check on the last few characters, no helper, no pause. True = the text before the caret
// is an address being typed (shown, or declined / not replaceable here): no word prediction then.
// The local part must be seen whole: an unknown text before the typed tail (U+FFFC in
// typedBefore) is not a delimiter, so "<unknown>user@" offers nothing (it may be "phúc@").
bool Session::offerEmailDomain(InputContext &ic) {
    if (!predict_ || !hintsOn_ || !emailAllowed_ || mode_ == DisplayMode::Direct || hint_) return false;
    if (!autotext::emailWorthChecking(tail_)) {
        declinedEmail_ = false;
        return false;
    }
    const bool composing = !vt_is_empty(e_);
    const std::string typed = composing ? composed() : std::string();
    autotext::EmailDomain d;
    if (!autotext::emailDomainSuggestion(typedBefore() + typed, typed, composing ? raw() : std::string(), d)) {
        declinedEmail_ = false;
        return false;
    }
    if (declinedEmail_) return true;
    // Replacing the composing word in place needs a field where the Session may edit.
    if (!d.replace.empty() && mode_ == DisplayMode::Surrounding && !surroundingEdits_) return true;
    CaretSuggestion s;
    s.kind = CaretSuggestion::Kind::Email;
    s.display = d.display;
    s.replace = d.replace;
    s.insert = d.insert;
    hint_ = s;
    ic.showPrediction(s.display, "Tab");
    return true;
}

// Tab / click on an email domain: the missing part goes in RAW (the composing word stays as
// shown, or — Telex changed it, "yahô" — is replaced). The engine is reset so nothing typed next
// is toned with it and ⌫ does not re-open it; no space added, nothing learned, no next word.
bool Session::applyEmailDomain(InputContext &ic) {
    CaretSuggestion s = *hint_;
    dismissHint(ic);
    if (!vt_is_empty(e_)) {
        const std::string word = composed();
        if (!s.replace.empty() && word != s.replace) return false;
        const std::string shown = s.replace.empty() ? word + s.insert : s.insert;
        if (mode_ == DisplayMode::Preedit) {
            vt_reset(e_);
            ic.commit(shown);  // before hiding the preedit (see finish)
            hidePreedit(ic);
        } else if (mode_ == DisplayMode::Surrounding) {
            if (!s.replace.empty() && (ic.hasSelection() || !inPlaceAllowed(ic, s.replace))) return false;
            replace(ic, int(utf8Chars(s.replace)), s.insert, s.replace);
            vt_reset(e_);
            preedit_.clear();
        } else {
            return false;
        }
        applyPendingMode();
        tailAppend(shown);
    } else {
        if (!s.replace.empty() || mode_ == DisplayMode::Direct) return false;
        replace(ic, 0, s.insert, std::string());
        tailAppend(s.insert);
    }
    vt_forget_last_commit(e_);
    learn_.discard();  // an address is not a word to learn
    lastWasBoundaryChar_ = false;
    lastEnded_ = EndedWord();
    toneTracker_.reset();
    gluedToDigit_ = false;
    caretMoved_ = false;
    autoCappedWord_ = suppressAutoCap_ = false;
    lastSpaceMs_ = -1;
    acceptedSpace_.clear();
    carriedSpace_.clear();
    return true;
}

// Tab / click on a word prediction: the word being composed (or nothing, after a space) becomes
// `word` + a space; then the next word is offered as after a typed space.
bool Session::applyPrediction(const std::string &word, InputContext &ic) {
    CaretSuggestion s = *hint_;
    dismissHint(ic);
    const std::string insert = word + " ";
    if (!s.replace.empty()) {
        if (vt_is_empty(e_) || composed() != s.replace) return false;
        if (mode_ == DisplayMode::Preedit) {
            vt_reset(e_);
            ic.commit(insert);  // before hiding the preedit (see finish)
            hidePreedit(ic);
        } else if (mode_ == DisplayMode::Surrounding) {
            if (ic.hasSelection() || !inPlaceAllowed(ic, s.replace)) return false;
            replace(ic, int(utf8Chars(s.replace)), insert, s.replace);
            vt_reset(e_);
            preedit_.clear();
        } else {
            return false;
        }
        applyPendingMode();
    } else {
        if (!vt_is_empty(e_) || mode_ == DisplayMode::Direct) return false;
        replace(ic, 0, insert, std::string());
    }
    tailAppend(insert);
    vt_forget_last_commit(e_);  // ⌫ must not re-open the word that was replaced
    lastWasBoundaryChar_ = false;
    lastEnded_ = EndedWord();
    toneTracker_.reset();
    {  // Học từ bạn gõ: an accepted prediction counts double (iOS weight 2)
        hints::LearnTracker::Event e;
        if (!learnOn()) learn_.discard();
        else if (learn_.commit(word, ' ', true, 2, e)) learnSend(e);
    }
    gluedToDigit_ = false;
    caretMoved_ = false;
    autoCappedWord_ = suppressAutoCap_ = false;
    // Our space counts as the first space of a double-space period, and the very next key may
    // attach punctuation to the word (acceptedSpaceKey).
    lastSpaceMs_ = period_ ? (nowMs_ ? nowMs_() : 0) : -1;
    acceptedSpace_ = insert;
    carriedSpace_.clear();
    std::vector<std::string> next = nextWordRequest();
    if (!next.empty()) requestHint(std::move(next), autotext::kPredictIdleMs);
    return true;
}

// The key right after accepting a prediction ("được␣"): punctuation attaches to the word and
// our space moves after it (autotext::acceptSpaceReplacement); the space right after that is
// swallowed. The screen is read back first (like every replacement); anything else → -1 (the
// key is handled as usual, the state is gone). 1 = consumed.
int Session::acceptedSpaceKey(const KeyEvent &ev, InputContext &ic) {
    std::string inserted, carried;
    inserted.swap(acceptedSpace_);
    carried.swap(carriedSpace_);
    if (!vietnamese_ || passthrough_ || !vt_is_empty(e_) || mode_ == DisplayMode::Direct ||
        (ev.mods & (VT_MOD_CTRL | VT_MOD_ALT | VT_MOD_SUPER)) || ev.unicode == 0)
        return -1;
    auto screenEnds = [&](const std::string &t) {
        std::string before;
        return !ic.hasSelection() && ic.textBeforeCursorTail(utf8Chars(t), before) && endsWith(before, t);
    };
    if (!carried.empty()) {
        if (ev.unicode != ' ' || !screenEnds(carried)) return -1;
        lastSpaceMs_ = -1;
        return 1;  // "được. " + space: not two spaces
    }
    const std::string out = autotext::acceptSpaceReplacement(ev.unicode);
    if (inserted.empty() || out.empty() || !screenEnds(inserted)) return -1;
    if (mode_ == DisplayMode::Surrounding && !surroundingEdits_) return -1;
    replace(ic, 1, out, " ");
    tailPop(1);
    tailAppend(out);
    vt_forget_last_commit(e_);
    learnFlush();  // the punctuation ends the sentence context
    lastSpaceMs_ = -1;
    lastWasBoundaryChar_ = false;
    if (out.back() == ' ') carriedSpace_ = out;
    return 1;
}

void Session::dismissHint(InputContext &ic) {
    if (!hint_) return;
    hint_.reset();
    ic.hideHint();
}

// Esc: sửa lỗi gõ ⇒ không gợi ý lại từ đó trong phiên; thêm dấu ⇒ không mời lại cụm bắt đầu
// bằng cụm vừa từ chối (CaretHint.decline).
void Session::declineHint(InputContext &ic) {
    if (!hint_) return;
    if (hint_->kind == CaretSuggestion::Kind::Typo) {
        std::string w = hint_->replace, last;
        popChar(w, last);  // drop the boundary
        rejectedTypos_.add(w);
    } else if (hint_->kind == CaretSuggestion::Kind::Tones) {
        declinedTones_ = hint_->replace;
    } else if (hint_->kind == CaretSuggestion::Kind::Predict && !hint_->replace.empty()) {
        declinedPrediction_ = hint_->replace;  // not again while the word starts with it
    } else if (hint_->kind == CaretSuggestion::Kind::Email) {
        declinedEmail_ = true;  // not again for this address
    }
    dismissHint(ic);
}

// Tab (math: Enter too). False = the screen no longer matches: dismissed, key goes on.
bool Session::applyHint(InputContext &ic) {
    if (hint_->kind == CaretSuggestion::Kind::Retro) {
        const CaretSuggestion s = *hint_;
        dismissHint(ic);
        return applyRetroOffer(s, ic);
    }
    if (hint_->kind == CaretSuggestion::Kind::Predict) return applyPrediction(hint_->display, ic);
    if (hint_->kind == CaretSuggestion::Kind::Email) return applyEmailDomain(ic);
    CaretSuggestion s = *hint_;
    dismissHint(ic);
    if (!s.replace.empty() && mode_ != DisplayMode::Direct) {
        // Read the screen back before replacing (macOS: like shortcuts / number chips) —
        // just the characters it would replace, not the whole paragraph.
        std::string before;
        if (ic.textBeforeCursorTail(utf8Chars(s.replace), before) && !endsWith(before, s.replace)) return false;
        if (ic.hasSelection()) return false;
    }
    size_t n = utf8Chars(s.replace);
    replace(ic, int(n), s.insert, s.replace);
    tailPop(n);
    tailAppend(s.insert);
    // Học từ bạn gõ: an accepted typo fix learns the fixed form; any other hint replaced the
    // committed text (tones, date, number) — the held word is dropped.
    if (s.kind == CaretSuggestion::Kind::Typo) learn_.replacePending(s.display);
    else learn_.discard();
    vt_forget_last_commit(e_);  // ⌫ must not re-open the word that was replaced
    lastWasBoundaryChar_ = false;
    lastEnded_ = EndedWord();
    toneTracker_.reset();
    return true;
}

void Session::setDisplayMode(DisplayMode m, InputContext &ic) {
    requestedMode_ = m;
    if (distrusted_ && m == DisplayMode::Surrounding) m = DisplayMode::Preedit;
    hasPendingMode_ = false;
    if (m == mode_) return;
    ackDrop();
    if (!vt_is_empty(e_)) {
        pendingMode_ = m;
        hasPendingMode_ = true;
        return;
    }
    finish(ic);
    mode_ = m;
}

void Session::applyPendingMode() {
    if (!hasPendingMode_ || !vt_is_empty(e_)) return;
    hasPendingMode_ = false;
    mode_ = pendingMode_;
}

void Session::setPassthrough(bool on, InputContext &ic) {
    if (on && !passthrough_) finish(ic);
    passthrough_ = on;
}

void Session::setVietnamese(bool on, InputContext &ic) {
    if (!on && vietnamese_) finish(ic);
    vietnamese_ = on;
}

bool Session::composing() const { return !vt_is_empty(e_); }

std::string Session::composed() const {
    char buf[256];
    size_t n = vt_composed(e_, buf, sizeof buf);
    return std::string(buf, n < sizeof buf ? n : sizeof buf - 1);
}

std::string Session::raw() const {
    char buf[256];
    size_t n = vt_raw(e_, buf, sizeof buf);
    return std::string(buf, n < sizeof buf ? n : sizeof buf - 1);
}

void Session::showPreedit(InputContext &ic) {
    std::string c = composed();
    // Off = no validation call at all.
    const bool bad = underlineMisspelled_ && vt_has_spelling_error(e_, autoRestore_);
    if (c == preedit_ && bad == preeditMisspelled_) return;
    preedit_ = c;
    preeditMisspelled_ = bad;
    ic.setPreedit(c, bad);
}

void Session::hidePreedit(InputContext &ic) {
    if (preedit_.empty()) return;
    preedit_.clear();
    preeditMisspelled_ = false;
    ic.setPreedit("", false);
}

const char *Session::noEditsReason(bool reopen) const {
    if (distrusted_)
        return reopen ? "⌫ re-open: skipped (surrounding text distrusted for this focus)"
                      : "re-edit: skipped (surrounding text distrusted for this focus)";
    if (mode_ == DisplayMode::Direct)
        return reopen ? "⌫ re-open: skipped (Direct mode)" : "re-edit: skipped (Direct mode reads nothing back)";
    // resolveAppPolicy: forced-preedit app, terminal field, forward-keys, or the client has
    // not delivered surrounding text for this focus yet.
    return reopen ? "⌫ re-open: skipped (app policy: no surrounding edits here)"
                  : "re-edit: skipped (app policy: no surrounding edits here)";
}

void Session::focusIn() {
    vt_reset_context(e_);
    deadKeys_.reset();  // a dead key pressed in the previous field never lands here
    if (distrusted_) {
        distrusted_ = false;
        surroundingEdits_ = requestedEdits_;
        if (requestedMode_ != mode_) {
            pendingMode_ = requestedMode_;
            hasPendingMode_ = true;
            applyPendingMode();
        }
    }
    ackDrop();
    learnFlush();
    hint_.reset();  // the frontend hid it on focus-out (finish)
    if (hintsOn_) keyGen_->fetch_add(1);
    tailReset();
    lastSpaceMs_ = -1;
    lastEmDashOurs_ = autoCappedWord_ = suppressAutoCap_ = false;
    acceptedSpace_.clear();
    carriedSpace_.clear();
    declinedPrediction_.clear();
    caretMoved_ = true;
    lastWasBoundaryChar_ = false;
}

void Session::finish(InputContext &ic, bool commitPreedit) {
    dismissHint(ic);
    deadKeys_.reset();  // focus left / caret moved: a pending dead key is dropped
    learnFlush();  // caret moved / focus left: the held word is final, the context ends
    if (hintsOn_) keyGen_->fetch_add(1);  // answers still on their way are stale now
    tailReset();
    lastSpaceMs_ = -1;
    lastEmDashOurs_ = autoCappedWord_ = suppressAutoCap_ = false;
    acceptedSpace_.clear();
    carriedSpace_.clear();
    ackDrop();  // the caret moved / focus left: nothing to compare any more
    if (mode_ == DisplayMode::Preedit && !vt_is_empty(e_)) {
        std::string text = composed();
        vt_reset(e_);
        // Commit BEFORE hiding the preedit: Messenger / Draft.js / Google Docs drop the
        // word when the composition is cleared first (bamboo engine_preedit.go).
        if (commitPreedit && !text.empty()) ic.commit(text);
        hidePreedit(ic);
    } else {
        vt_reset(e_);
        preedit_.clear();
    }
    gluedToDigit_ = false;
    caretMoved_ = true;
    lastWasBoundaryChar_ = false;
    applyPendingMode();
}

bool Session::selectionAtCaret(InputContext &ic) {
    if (selectionMemo_ < 0) selectionMemo_ = ic.selectionAtCaret() ? 1 : 0;
    return selectionMemo_ == 1;
}

bool Session::isWordKey(uint32_t ch) const {
    return isAsciiLetter(ch) || (vni_ && isDigit(ch)) || (bracketVowels_ && isBracketVowelKey(ch));
}

void Session::finishRetro(InputContext &ic, uint32_t ch, bool lineEnd) {
    vt_retro r;
    if (vt_take_retro(e_, &r)) {
        const std::string expected(r.expected, size_t(r.expected_len > 0 && r.expected_len < VT_RETRO_CAP ? r.expected_len : 0));
        const std::string insert(r.insert, size_t(r.insert_len > 0 && r.insert_len < VT_RETRO_CAP ? r.insert_len : 0));
        // Flip-back ("Đoán từ trùng theo tần suất": "His hửng" → "hí hửng") undoes the
        // engine's own guess: applied automatically even in offer mode, and also at Enter /
        // Tab / Esc (`lineEnd`) — before the key goes through.
        const bool flip = r.flip_back != 0;
        // Only where the Session may reach back into committed text (never Direct /
        // terminals / distrusted fields) and only after a printable boundary (Enter / Tab may
        // send the message or leave the field: no rewrite behind the user's back — except a
        // flip-back, see above).
        const bool edits = surroundingEdits_ && !passthrough_ && mode_ != DisplayMode::Direct &&
                           (ch != 0 || (flip && lineEnd)) && r.backspaces == int(utf8Chars(expected)) &&
                           !insert.empty();
        std::string before;
        const bool offer = retroMode_ == retro::Mode::Offer && !flip;
        // Offer: a few more characters, for the start of the first word ("H" of "Hí").
        const bool have = edits && ic.textBeforeCursorTail(utf8Chars(expected) + (offer ? 24 : 0), before);
        const bool sel = edits && have && (ic.hasSelection() || selectionAtCaret(ic));
        bool applied = false;
        if (retro::decideApply(edits, have, sel, before, expected, retroInflight_) == retro::Apply::Apply) {
            if (offer) {
                // Shown once this key event is done (processKey): Tab applies it.
                retroOffer_ = retro::makeOffer(before, expected, insert, char(ch), r.words, retroInflight_);
            } else if (mode_ == DisplayMode::Surrounding) {
                replaceBeforeCursor(ic, r.backspaces, insert, expected);
            } else {
                ic.deleteBeforeCursor(r.backspaces);
                ic.commit(insert);
            }
            applied = !offer;
        }
        if (applied) {
            lastRetroWords_ = r.words;
            retroUndo_ = retro::makeUndo(expected, insert, char(ch));
            vt_forget_last_commit(e_);  // ⌫ next reverts the rewrite, never re-opens a word
            if (hintsOn_) tailReset();  // the typed tail no longer matches the screen
        } else {
            // The engine recorded those words as English already (offer: Tab resets the
            // engine anyway): end the phrase.
            vt_note_boundary(e_, '\n');
        }
    }
    // After the take: `expected` / `insert` must not contain the key the app types next.
    vt_note_boundary(e_, ch ? ch : '\n');
}

void Session::armRestoreUndo(uint32_t ch) {
    vt_restore_undo u;
    if (!vt_take_restore_undo(e_, &u) || retroUndo_.armed()) return;
    retroUndo_ = retro::makeUndo(std::string(u.vietnamese, size_t(u.vietnamese_len)),
                                 std::string(u.restored, size_t(u.restored_len)), char(ch));
    undoIsRestore_ = retroUndo_.armed();
}

bool Session::tryRetroUndo(const retro::Undo &u, InputContext &ic, bool restoreUndo) {
    const bool edits = surroundingEdits_ && !passthrough_ && mode_ != DisplayMode::Direct;
    std::string before;
    const bool have = edits && ic.textBeforeCursorTail(utf8Chars(u.applied), before);
    const bool sel = edits && have && (ic.hasSelection() || selectionAtCaret(ic));
    if (!retro::undoApplies(u, edits, have, sel, before)) return false;
    if (mode_ == DisplayMode::Surrounding) {
        replaceBeforeCursor(ic, int(utf8Chars(u.applied)), u.original, u.applied);
    } else {
        ic.deleteBeforeCursor(int(utf8Chars(u.applied)));
        ic.commit(u.original);
    }
    // Restore undo: the word is Vietnamese again (ends the English run too).
    if (restoreUndo) vt_restore_undo_applied(e_);
    else vt_reset(e_);  // the word history says English; the screen holds the old text again
    if (hintsOn_) tailReset();
    return true;
}

// Tab on the offered correction: read the text back (it must still end with what the offer
// replaces, the boundary key included), then the same edit auto mode makes. False = the text
// moved on / cannot be read here: dismissed, the Tab goes on as usual.
bool Session::applyRetroOffer(const CaretSuggestion &s, InputContext &ic) {
    const bool edits = surroundingEdits_ && !passthrough_ && mode_ != DisplayMode::Direct && vt_is_empty(e_) &&
                       !s.replace.empty() && !s.insert.empty();
    if (!edits) return false;
    const size_t n = utf8Chars(s.replace);
    std::string before;
    if (!ic.textBeforeCursorTail(n, before) || !endsWith(before, s.replace)) return false;
    if (ic.hasSelection() || selectionAtCaret(ic)) return false;
    if (mode_ == DisplayMode::Surrounding) {
        replaceBeforeCursor(ic, int(n), s.insert, s.replace);
    } else {
        ic.deleteBeforeCursor(int(n));
        ic.commit(s.insert);
    }
    vt_reset(e_);  // the engine's word history no longer matches the text
    if (hintsOn_) tailReset();
    learn_.discard();
    lastWasBoundaryChar_ = false;
    lastEnded_ = EndedWord();
    toneTracker_.reset();
    return true;
}

// TelexInputController.boundary(): shortcut first (composed, then raw keys), then the
// auto-restore decision.
void Session::endWord(InputContext &ic, bool suppressRestore, bool allowShortcuts, uint32_t endChar) {
    if (vt_is_empty(e_)) {
        vt_reset(e_);
        return;
    }
    std::string word = composed();
    std::string rawWord = raw();
    size_t onScreen = utf8Chars(word);
    // What stays on screen for this word — the typed tail of caret suggestions.
    auto ended = [this](const std::string &text, const std::string &rawKeys) {
        if (!hintsOn_) return;
        lastEnded_.ended = true;
        lastEnded_.text = text;
        lastEnded_.raw = rawKeys;
        tailAppend(text);
    };
    if (allowShortcuts && shortcutsEnabled_ && !word.empty() && shortcuts_) {
        // Case follows the typing (ko/Ko/KO — shortcutExpansion, as on macOS).
        std::string expansion;
        const bool found = shortcutExpansion(*shortcuts_, word, expansion) ||
                           (rawWord != word && shortcutExpansion(*shortcuts_, rawWord, expansion));
        // Surrounding deletes the word to expand it: never with a selection at the caret.
        if (found && (mode_ != DisplayMode::Surrounding ||
                      (!selectionAtCaret(ic) && inPlaceAllowed(ic, word)))) {
            vt_reset(e_);
            ended(expansion, std::string());
            if (mode_ == DisplayMode::Preedit) {
                if (!expansion.empty()) ic.commit(expansion);
                hidePreedit(ic);
            } else {
                replace(ic, int(onScreen), expansion, word);
            }
            return;
        }
    }
    bool autoRestore = autoRestore_ && !suppressRestore;
    if (mode_ == DisplayMode::Preedit) {
        char buf[256];
        size_t n = vt_commit_text_before(e_, autoRestore, endChar, buf, sizeof buf);
        std::string text(buf, n < sizeof buf ? n : sizeof buf - 1);
        retroInflight_ = text.size();
        if (!text.empty()) ic.commit(text);
        hidePreedit(ic);
        ended(text, rawWord);
    } else {
        std::string finalText;
        if (hintsOn_) {
            char buf[256];
            size_t n = vt_peek_before(e_, autoRestore, endChar, buf, sizeof buf);
            finalText.assign(buf, n < sizeof buf ? n : sizeof buf - 1);
        }
        vt_action a;
        vt_commit_before(e_, autoRestore, endChar, &a);
        // Typed in place letter by letter: the host may still lag by the whole word.
        retroInflight_ = word.size() + size_t(a.insert_len > 0 ? a.insert_len : 0);
        // Auto-restore deletes the word: with a selection at the caret the delete would hit
        // the selection — leave the word as typed.
        if (mode_ == DisplayMode::Surrounding && a.kind == VT_ACTION_REPLACE && a.backspaces > 0 &&
            (selectionAtCaret(ic) || !inPlaceAllowed(ic, word, a.backspaces))) {
            vt_reset(e_);
            ended(word, rawWord);
            return;
        }
        ended(finalText, rawWord);
        if (a.kind == VT_ACTION_REPLACE)
            replace(ic, a.backspaces, std::string(a.insert, size_t(a.insert_len > 0 ? a.insert_len : 0)), word);
    }
}

bool Session::processKey(const KeyEvent &ev, InputContext &ic) {
    reachBackNote_ = nullptr;  // per key event, releases and echoes included
    if (ev.forwarded) return false;  // our own forwarded key: the app must get it untouched
    if (ev.release) {
        // Double-space period: a held space (autorepeat — frameworks send no repeat flag)
        // presses again without a release in between.
        if (ev.keysym == ks::space) spaceReleased_ = true;
        return false;
    }
    if (ks::isModifierOnly(ev.keysym)) return false;
    // Dead keys / Compose key (#161): the framework's keyboard engine that would compose them
    // does not run while we are the input method — compose here, in every mode (English and
    // passthrough too), exactly one output per sequence. Ordinary keys: one range check.
    if (deadKeys_.wants(ev.keysym)) {
        std::string lit;
        switch (deadKeys_.feed(ev.keysym, ev.unicode, ev.mods, lit)) {
        case DeadKeys::Step::Consumed: return true;
        case DeadKeys::Step::Commit: typeLiteral(lit, ic); return true;
        case DeadKeys::Step::CommitThenKey: typeLiteral(lit, ic); break;
        case DeadKeys::Step::Pass: break;
        }
    }
    selectionMemo_ = -1;
    // A retro rewrite can be reverted by the very next key only.
    const retro::Undo undo = std::move(retroUndo_);
    const bool undoIsRestore = undoIsRestore_;
    retroUndo_.clear();
    undoIsRestore_ = false;
    lastRetroWords_ = 0;
    retroInflight_ = 0;
    retroOffer_ = retro::Offer();
    // Auto text state of the previous key: every real key consumes it (macOS periodSpaceNs /
    // lastEmDashOurs).
    const int64_t prevSpaceMs = lastSpaceMs_;
    const bool prevEmDashOurs = lastEmDashOurs_;
    lastSpaceMs_ = -1;
    lastEmDashOurs_ = false;
    const bool spaceHeld = ev.keysym == ks::space && !spaceReleased_;
    if (ev.keysym == ks::space) spaceReleased_ = false;
    applyPendingMode();
    // Key edits ([experimental] no_underline): confirm the last ones before anything else.
    ackLagging_ = false;
    if (!ackStates_.empty() || ackPending_) {
        if (!tracking()) {
            ackDrop();
        } else {
            switch (checkKeyEdit(ic)) {
            case Ack::Failed: failKeyEdit(); break;
            case Ack::Lagging: ackLagging_ = true; break;
            default: break;
            }
        }
    }
    // A trail starts with this key: remember what the host shows before it (see checkKeyEdit).
    if (ackTrail_.empty() && !ackSeeded_ && tracking() && vietnamese_ && !passthrough_) {
        std::string before;
        if (ic.textBeforeCursorTail(kAckContext, before)) {
            ackSeed_ = before;
            ackSeedWhole_ = utf8Chars(before) < kAckContext;
            ackSeeded_ = true;
        }
    }

    // Caret suggestion showing: Tab applies (math: Enter too), Esc declines, any other key
    // dismisses it and is handled as usual (CaretHintLogic.action).
    if (hintsOn_) keyGen_->fetch_add(1);
    if (hint_) {
        switch (hints::keyAction(hint_->kind, ev.keysym, ev.mods)) {
        case hints::KeyAction::Accept:
            if (applyHint(ic)) return true;
            break;
        case hints::KeyAction::DismissConsume:
            declineHint(ic);
            return true;
        case hints::KeyAction::DismissPass:
            dismissHint(ic);
            break;
        }
    }

    // The space we inserted when a prediction was accepted: the very next key decides.
    if (!acceptedSpace_.empty() || !carriedSpace_.empty()) {
        const int r = acceptedSpaceKey(ev, ic);
        if (r >= 0) return r != 0;
    }

    // Vi/En toggle hotkey (Ctrl+Space by default).
    if (isToggleHotkey(ev)) {
        finish(ic);
        vietnamese_ = !vietnamese_;
        if (onToggle) onToggle(vietnamese_);
        return true;
    }

    if (!vietnamese_ || passthrough_) {
        ackDrop();
        if (!vt_is_empty(e_)) finish(ic);
        if (tailSeeded_) tailReset();
        return false;
    }
    if (hintsOn_ && !tailSeeded_) seedTail(ic);
    lastEnded_.ended = false;

    // Shortcut chords (Ctrl/Alt/Super + key): commit the word, hand the key to the app.
    if (ev.mods & (VT_MOD_CTRL | VT_MOD_ALT | VT_MOD_SUPER)) {
        learn_.discard();  // Ctrl+Z / Ctrl+Backspace may undo / delete it: never learned
        endWord(ic, false, false);
        if (retroOn_) finishRetro(ic, 0);  // a chord may change the text: never rewrite, end the phrase
        ackDrop();  // Ctrl+V / Ctrl+Z / Ctrl+left: the text before the caret is unknown
        vt_forget_last_commit(e_);
        if (hintsOn_) tailReset();  // Ctrl+V / Ctrl+Z / Ctrl+←: the text before the caret is unknown
        gluedToDigit_ = false;
        caretMoved_ = true;
        lastWasBoundaryChar_ = false;
        return false;
    }

    if (ev.keysym == ks::BackSpace) {
        if (undo.armed() && vt_is_empty(e_) && tryRetroUndo(undo, ic, undoIsRestore)) {
            lastWasBoundaryChar_ = false;
            return true;
        }
        if (vt_is_empty(e_)) learn_.discard();  // ⌫ into the committed word: maybe being edited
        bool r = handleBackspace(ic);
        if (!r) ackPop();  // the app's own BackSpace removes one character
        lastWasBoundaryChar_ = false;
        return r;
    }

    uint32_t ch = ev.unicode;
    // Numpad digits are never VNI marks (#124): they end the word like any boundary.
    if (ch && isWordKey(ch) && !ks::isKeypad(ev.keysym)) {
        bool r = handleLetter(ch, ic);
        caretMoved_ = false;
        lastWasBoundaryChar_ = false;
        // Word prediction: complete the word being typed after a pause (off = one bool).
        // Typing an address ("user@gm"): the email domain instead.
        if (predict_ && !offerEmailDomain(ic) && hintSink_ && !vt_is_empty(e_)) schedulePrediction(composed(), raw());
        return r;
    }

    // Boundary: space, punctuation, digits (Telex), Enter/Tab/Esc, navigation, …
    bool printable = ch >= 0x20 && ch < 0x7f;
    bool newline = isNewlineKey(ev.keysym);
    autoCappedWord_ = suppressAutoCap_ = false;
    // Double-space period / "--" → "—": the second key arrives once the word is committed and
    // replaces committed text (only where the Session may edit; screen read back first).
    if (printable && (ch == ' ' ? period_ : (ch == '-' && smart_)) && !ks::isKeypad(ev.keysym) &&
        vt_is_empty(e_) && tryAutoReplace(ch == ' ', prevSpaceMs, spaceHeld, prevEmDashOurs, ic)) {
        learnFlush();  // Học từ bạn gõ: ". " / "—" ends the sentence context
        if (retroOn_) vt_note_boundary(e_, '.');  // ". " / "—": not a space between words
        gluedToDigit_ = false;
        lastWasBoundaryChar_ = false;
        caretMoved_ = false;
        return true;
    }
    // Symbol / digit shortcut keys ("=>" → "⟶"): only at whitespace (space, Enter, Tab) —
    // before the word path, which never sees them as a word.
    if ((ch == ' ' || newline || ev.keysym == ks::Tab) && tryTokenShortcut(ic)) gluedToDigit_ = false;
    endWord(ic, printable && isBracket(ch), !gluedToDigit_, printable ? ch : 0);
    // The engine needs EVERY boundary character (glued "my_var" / "100W"), retro or not.
    if (retroOn_)
        finishRetro(ic, printable ? ch : 0,
                    !printable && (newline || ev.keysym == ks::Tab || ev.keysym == ks::ISO_Left_Tab ||
                                   ev.keysym == ks::Escape));
    else vt_note_boundary(e_, printable ? ch : '\n');
    armRestoreUndo(printable ? ch : 0);
    if (newline) vt_reset_context(e_);   // a new line has no preceding word
    // Smart quotes: “ ” ‘ ’ instead of the key (inserted, nothing replaced).
    std::string quoted;
    if (printable && (ch == '"' || ch == '\'') && smart_ && autoTextHere() && smartQuoteFor(ch, ic, quoted))
        ic.commit(quoted);
    if (hintsOn_) afterBoundary(ch, ev.keysym, quoted.empty() ? nullptr : &quoted);
    // Email domain right after '@' ("user@" → gmail.com) or '.' / '-' inside the domain.
    if (predict_ && (ch == '@' || ch == '.' || ch == '-') && !ks::isKeypad(ev.keysym)) {
        if (ch == '@') declinedEmail_ = false;  // a new address
        offerEmailDomain(ic);
    }
    // "Tự sửa từ phía trước" offered: wins over every other suggestion of this key (helper
    // answers for it are dropped in deliverHint while it shows).
    if (!retroOffer_.empty()) {
        if (hint_) ic.hideHint();
        CaretSuggestion s;
        s.kind = CaretSuggestion::Kind::Retro;
        s.display = retroOffer_.display;
        s.replace = retroOffer_.replace;
        s.insert = retroOffer_.insert;
        hint_ = s;
        ic.showHint(hints::label(s));
        retroOffer_ = retro::Offer();
    }
    if (printable && mode_ == DisplayMode::Surrounding)
        ackAppend(quoted.empty() ? encode(ch) : quoted);  // the app types it / we committed it
    else ackDrop();
    if (!quoted.empty()) {
        vt_forget_last_commit(e_);  // ⌫ re-open compares word + the key: not what is on screen
        gluedToDigit_ = false;
        lastWasBoundaryChar_ = false;
        caretMoved_ = false;
        return true;
    }
    if (ch == ' ' && period_ && !ks::isKeypad(ev.keysym)) lastSpaceMs_ = nowMs_ ? nowMs_() : 0;
    if (printable) {
        gluedToDigit_ = gluesShortcutToken(ch);
        lastWasBoundaryChar_ = true;
        lastBoundary_ = char(ch);
        caretMoved_ = false;
    } else {
        // Keys that do not leave exactly one character after the word (Enter, Tab,
        // arrows, Delete, non-ASCII) must not let ⌫ re-open it (issue #40).
        vt_forget_last_commit(e_);
        gluedToDigit_ = false;
        lastWasBoundaryChar_ = false;
        caretMoved_ = (ch == 0);  // navigation / Delete / Esc: caret may now sit after a word
    }
    return false;
}

void Session::typeLiteral(const std::string &text, InputContext &ic) {
    for (size_t i = 0; i < text.size();) {
        // UTF-8 → code point (the compose table's output is valid UTF-8).
        const unsigned char c = static_cast<unsigned char>(text[i]);
        const size_t n = c < 0x80 ? 1 : c < 0xe0 ? 2 : c < 0xf0 ? 3 : 4;
        uint32_t cp = n == 1 ? c : n == 2 ? (c & 0x1f) : n == 3 ? (c & 0x0f) : (c & 0x07);
        for (size_t k = 1; k < n && i + k < text.size(); ++k)
            cp = (cp << 6) | (static_cast<unsigned char>(text[i + k]) & 0x3f);
        const std::string one = text.substr(i, n);
        i += n;
        KeyEvent k;
        // Latin-1 keysyms are the code point; the rest use the Unicode keysym range.
        k.keysym = (cp >= 0x20 && cp < 0x7f) || (cp >= 0xa0 && cp < 0x100) ? cp : 0x1000000 | cp;
        // Never a Telex/VNI key: a composed letter (é) is a literal, and an ASCII result
        // (´ Space → ') is punctuation — an ASCII letter/digit only comes from a Multi_key
        // sequence, and it must not start a Telex word either.
        const bool alnum = (cp >= 'a' && cp <= 'z') || (cp >= 'A' && cp <= 'Z') || (cp >= '0' && cp <= '9');
        k.unicode = alnum ? 0 : cp;  // 0 = a plain boundary
        if (processKey(k, ic)) continue;  // the Session typed it (smart quote…)
        if (mode_ == DisplayMode::Direct) ic.directReplace(0, one);
        else ic.commit(one);
    }
}

bool Session::isToggleHotkey(const KeyEvent &ev) const {
    if (!hotkeyValid_ || ev.release) return false;
    uint32_t sym = ev.keysym;
    if (sym >= 'A' && sym <= 'Z') sym += 0x20;
    return sym == hotkeySym_ &&
           (ev.mods & (VT_MOD_CTRL | VT_MOD_ALT | VT_MOD_SHIFT | VT_MOD_SUPER)) == hotkeyMods_;
}

bool Session::isAddTonesHotkey(const KeyEvent &ev) const {
    if (!addTonesValid_ || ev.release || ev.forwarded) return false;
    uint32_t sym = ev.keysym;
    if (sym >= 'A' && sym <= 'Z') sym += 0x20;
    return sym == addTonesSym_ &&
           (ev.mods & (VT_MOD_CTRL | VT_MOD_ALT | VT_MOD_SHIFT | VT_MOD_SUPER)) == addTonesMods_;
}

bool Session::handleLetter(uint32_t ch, InputContext &ic) {
    // RE-EDIT: a diacritic-only key right where the caret landed after a move, directly
    // after a word on screen, adds the diacritic to that word ("toan" + s → "toán").
    // Never with a selection at the caret (Ctrl+A / double-click, then a tone key): the key
    // replaces the selection like any letter — the delete would eat the wrong text. Asked
    // last, only when a word really sits before the caret.
    // Issue #163: every refusal of a CANDIDATE (empty engine, feature on, tone key) names its
    // reason (reachBackNote); every other key stops at the first three tests, as before.
    if (vt_is_empty(e_) && reEdit_ && isDiacriticOnlyKey(ch, vni_)) {
        if (!surroundingEdits_) {
            reachBackNote_ = noEditsReason(false);
        } else if (!caretMoved_) {
            reachBackNote_ = "re-edit: skipped (previous key ended a word, caret not moved)";
        } else if (ic.hasSelection()) {
            reachBackNote_ = "re-edit: skipped (selection)";
        } else {
            std::string before;
            if (!ic.textBeforeCursorTail(14, before)) {
                reachBackNote_ = "re-edit: skipped (text before the caret unreadable)";
            } else {
                std::string word, c;
                size_t n = 0;
                bool tooLong = false, decomposed = false;
                while (popChar(before, c)) {
                    uint32_t cp = decodeOne(c);
                    if (!isWordLetter(cp)) {
                        // NFD host ("toa" U+0300 "n"): the scan would stop inside the word and the
                        // delete count (in characters) would not match what is shown.
                        decomposed = isCombiningMark(cp);
                        break;
                    }
                    word.insert(0, c);
                    if (++n > 12) { tooLong = true; break; }
                }
                if (decomposed) {
                    distrust();
                    reachBackNote_ = "re-edit: skipped (decomposed text before the caret, distrusted)";
                } else if (word.empty()) {
                    reachBackNote_ = "re-edit: skipped (no word right before the caret)";
                } else if (tooLong) {
                    reachBackNote_ = "re-edit: skipped (word before the caret too long)";
                } else if (selectionAtCaret(ic)) {
                    reachBackNote_ = "re-edit: skipped (selection at the caret)";
                } else if (!vt_seed(e_, word.c_str())) {
                    reachBackNote_ = "re-edit: skipped (word before the caret does not round-trip)";
                } else {
                    reachBackNote_ = "re-edit: seeded the word before the caret";
                    if (hintsOn_) tailPop(n);  // the word is being edited again (back in the engine)
                    if (mode_ == DisplayMode::Preedit) {
                        ic.deleteBeforeCursor(int(n));
                        preedit_.clear();
                    }
                }
            }
        }
    }

    // Sentence capital (auto_capitalize): decided ONCE, on the first letter of a word, by
    // feeding the engine the uppercase key — Telex still composes ("Dduwowcj" → "Được").
    if (capitalize_ && vt_is_empty(e_)) {
        autoCappedWord_ = false;
        if (ch >= 'a' && ch <= 'z' && autoTextHere()) {
            if (suppressAutoCap_) {
                suppressAutoCap_ = false;  // the user deleted the last auto capital: keep this one
            } else if (shouldCapitalize(ic)) {
                ch = autotext::capitalized(ch);
                autoCappedWord_ = true;
            }
        }
    }

    // The word as it is on screen right now (Surrounding: what we committed), for
    // verify-before-delete. O(word), like showPreedit's per-key composed() in Preedit.
    std::string shown;
    if (mode_ == DisplayMode::Surrounding && !vt_is_empty(e_)) shown = composed();
    vt_action a;
    vt_feed(e_, ch, &a);
    if (a.kind == VT_ACTION_PASSTHROUGH && vt_is_overflowed(e_)) {
        if (hintsOn_) tailReset();
        // Word longer than the engine's 32 keys: never lose text. Preedit: finalise what
        // is composed and continue the tail as a fresh word (macOS commitAndPassThrough).
        if (mode_ == DisplayMode::Preedit) {
            std::string text = composed();
            vt_reset(e_);
            ic.commit(text + encode(ch));
            hidePreedit(ic);
        } else if (mode_ == DisplayMode::Direct) {
            ic.directReplace(0, encode(ch));
        } else {
            ic.commit(encode(ch));
            ackAppend(encode(ch));
        }
        return true;
    }
    if (mode_ == DisplayMode::Preedit) {
        showPreedit(ic);
        return true;
    }
    if (mode_ == DisplayMode::Direct) {
        // Blind: the engine's own record of the word is the only truth, no selection check
        // (a terminal has none) and no read-back. Even an unchanged letter goes through the
        // forwarded-key channel so it cannot overtake an earlier forwarded BackSpace.
        if (a.kind == VT_ACTION_PASSTHROUGH) ic.directReplace(0, encode(ch));
        else if (a.kind == VT_ACTION_REPLACE)
            replace(ic, a.backspaces, std::string(a.insert, size_t(a.insert_len > 0 ? a.insert_len : 0)),
                    std::string());
        return true;
    }
    switch (a.kind) {
    case VT_ACTION_PASSTHROUGH:
        ic.commit(encode(ch));
        ackAppend(encode(ch));
        break;
    case VT_ACTION_REPLACE:
        if (a.backspaces > 0 && (ic.hasSelection() || !inPlaceAllowed(ic, shown, a.backspaces))) {
            // Never delete into a selection, nor text that is not what we typed (the Session
            // then composes in preedit): type the key literally, start a new word.
            vt_reset(e_);
            applyPendingMode();  // distrusted: this very key already goes on as preedit text
            if (hintsOn_ && distrusted_) tailReset();
            ackDrop();  // typed over a selection (or distrusted): nothing to compare
            ic.commit(encode(ch));
            break;
        }
        replaceBeforeCursor(ic, a.backspaces, std::string(a.insert, size_t(a.insert_len > 0 ? a.insert_len : 0)),
                            shown);
        break;
    default: break;
    }
    return true;
}

bool Session::handleBackspace(InputContext &ic) {
    if (vt_is_empty(e_)) {
        // ⌫ over the boundary right after a word re-opens it ("tháy" ␣ ⌫ a → "thấy",
        // issue #40) — only when the client's text proves the word is still there.
        // Verify-before-delete: the host must show exactly the word AND the boundary we
        // typed. Stale (our commit / the boundary not applied yet) → plain ⌫, no reopen;
        // anything else → plain ⌫ and the surrounding text is distrusted for this focus.
        const bool candidate = vt_can_reopen(e_) && lastWasBoundaryChar_ && lastBoundary_;
        // Issue #163 RC2 (macOS ReopenKeystreamTrust): Direct mode (terminals) can read
        // nothing back, but its OWN keystream proves the screen — the word was typed through
        // the ordered forwarded-key channel, then ONE printable ASCII boundary passed, and this
        // ⌫ is the very next key (any other key, a chord, a click / caret move (finish) or a
        // focus change clears lastWasBoundaryChar_ / the engine's re-open snapshot; a shortcut
        // expansion or auto-restore never leaves a snapshot). The ⌫ itself goes to the app and
        // deletes that boundary; the next keys edit the word with forwarded BackSpaces, the
        // same blind trust Direct already gives the word in progress.
        // Accepted risk (as on macOS): a shell that rewrites the word on space by itself
        // (fish abbreviations) gets the next tone key's BackSpaces in the wrong place.
        if (candidate && mode_ == DisplayMode::Direct) {
            if (!reEdit_) {
                vt_forget_last_commit(e_);
                if (hintsOn_) tailPop(1);
                return false;
            }
            char buf[256];
            long n = vt_reopen(e_, buf, sizeof buf);
            if (n > 0 && size_t(n) < sizeof buf) {
                reachBackNote_ = "⌫ re-open: word back in the engine (Direct, keystream trust)";
                if (hintsOn_) tailPop(1 + utf8Chars(std::string(buf, size_t(n))));
                gluedToDigit_ = false;
            } else {
                reachBackNote_ = "⌫ re-open: skipped (replay mismatch)";
                vt_reset(e_);
                if (hintsOn_) tailPop(1);
            }
            return false;  // the app's own ⌫ deletes the boundary
        }
        const bool selected = candidate && surroundingEdits_ && ic.hasSelection();
        if (candidate && !surroundingEdits_) reachBackNote_ = noEditsReason(true);
        else if (selected) reachBackNote_ = "⌫ re-open: skipped (selection)";
        if (candidate && surroundingEdits_ && !selected) {
            std::string before;
            reachBackNote_ = "⌫ re-open: skipped (text before the caret unreadable)";
            if (ic.textBeforeCursorTail(64, before)) {
                reachBackNote_ = "⌫ re-open: skipped (replay mismatch)";
                char buf[256];
                long n = vt_reopen(e_, buf, sizeof buf);
                if (n > 0 && size_t(n) < sizeof buf) {
                    std::string word(buf, size_t(n));
                    Screen v = checkScreen(before, word + lastBoundary_);
                    if (v == Screen::Mismatch) distrust();
                    reachBackNote_ = v == Screen::Mismatch ? "⌫ re-open: skipped (screen is not the word + boundary, distrusted)"
                                     : v == Screen::Stale  ? "⌫ re-open: skipped (host has not shown the boundary yet)"
                                                           : "⌫ re-open: skipped (selection at the caret)";
                    if (v == Screen::Match && !selectionAtCaret(ic)) {
                        reachBackNote_ = "⌫ re-open: word back in the engine";
                        if (hintsOn_) tailPop(1 + utf8Chars(word));  // boundary gone, word back in the engine
                        if (mode_ == DisplayMode::Surrounding) {
                            replaceBeforeCursor(ic, 1, std::string(), word + lastBoundary_);
                        } else {
                            ic.deleteBeforeCursor(int(1 + utf8Chars(word)));
                            preedit_.clear();
                            showPreedit(ic);
                        }
                        gluedToDigit_ = false;
                        return true;
                    }
                }
                vt_reset(e_);
                applyPendingMode();
                if (hintsOn_) tailPop(1);
                return false;
            }
        }
        vt_forget_last_commit(e_);
        if (hintsOn_) tailPop(1);  // the app's own ⌫ deletes one character
        return false;
    }
    std::string shown;
    if (mode_ == DisplayMode::Surrounding) shown = composed();
    vt_action a;
    vt_backspace(e_, &a);
    // ⌫ took away exactly the auto capital: the user declined it — the next first letter stays.
    if (autoCappedWord_ && vt_is_empty(e_)) {
        suppressAutoCap_ = true;
        autoCappedWord_ = false;
    }
    if (mode_ == DisplayMode::Preedit) {
        if (vt_is_empty(e_)) {
            vt_reset(e_);
            hidePreedit(ic);
        } else {
            showPreedit(ic);
        }
        return true;
    }
    // Surrounding / Direct: .none / .passthrough / a pure one-char delete → the app's own ⌫.
    if (a.kind != VT_ACTION_REPLACE) return false;
    if (a.insert_len == 0 && a.backspaces == 1) return false;
    if (mode_ == DisplayMode::Surrounding && a.backspaces > 0 &&
        (ic.hasSelection() || !inPlaceAllowed(ic, shown, a.backspaces))) {
        vt_reset(e_);  // the app's own ⌫ removes the selection / one character
        applyPendingMode();
        return false;
    }
    replace(ic, a.backspaces, std::string(a.insert, size_t(a.insert_len > 0 ? a.insert_len : 0)), shown);
    return true;
}

// MARK: - auto text (auto_text.h)

namespace {
uint32_t lastCodePoint(const std::string &s) {
    if (s.empty()) return 0;
    size_t i = s.size() - 1;
    while (i > 0 && (static_cast<unsigned char>(s[i]) & 0xc0) == 0x80) --i;
    return decodeOne(s.substr(i));
}
}  // namespace

// First letter of a word: is it a sentence start? Decided from the typed tail (`atStart` = the
// tail starts the field and is empty — a sentence start only in a multi-line field), else from
// up to 24 characters read back where the client's text is proven.
bool Session::shouldCapitalize(InputContext &ic) {
    std::string before;
    bool known = true, atStart = false;
    if (tailHead_ == TailHead::Start) {
        before = tail_;
        atStart = tail_.empty();
    } else if (tailHead_ == TailHead::Newline) {
        before = "\n" + tail_;
    } else if (!tail_.empty()) {
        before = tail_;
    } else {
        known = false;
    }
    autotext::CapContext c =
        known ? autotext::capitalization(&before, atStart && multiline_) : autotext::CapContext::Unknown;
    // Not known from the keys (just clicked / focused): read up to 24 characters once, where
    // the client's text is proven (SystemAutoText: only the first letter after a click).
    if (c == autotext::CapContext::Unknown && surroundingEdits_ && mode_ != DisplayMode::Direct) {
        std::string screen;
        if (ic.textBeforeCursorTail(24, screen))
            c = screen.empty() ? autotext::capitalization(nullptr, multiline_)
                               : autotext::capitalization(&screen, false);
    }
    return c == autotext::CapContext::Capitalize;
}

// Smart quote for the " / ' key: the character before the caret from the tail, else (proven
// surrounding only) one character read back. False = unknown → the key stays as it is.
bool Session::smartQuoteFor(uint32_t ch, InputContext &ic, std::string &out) {
    uint32_t prev = 0;
    bool hasPrev = false;
    if (!tail_.empty()) {
        prev = lastCodePoint(tail_);
        hasPrev = true;
    } else if (tailHead_ == TailHead::Newline) {
        prev = '\n';
        hasPrev = true;
    } else if (tailHead_ != TailHead::Start) {
        std::string b;
        if (!surroundingEdits_ || mode_ == DisplayMode::Direct || !ic.textBeforeCursorTail(1, b)) return false;
        if (!b.empty()) {
            prev = lastCodePoint(b);
            hasPrev = true;
        }
    }
    out = autotext::smartQuote(ch, prev, hasPrev, quotes_);
    return !out.empty();
}

// Second space → ". " / second "-" → "—" / "—" + "-" → "---" (engine empty). Decided from the
// typed tail; the characters to replace are read back from the screen and must match.
bool Session::tryTokenShortcut(InputContext &ic) {
    constexpr size_t kMaxKeyChars = 64;  // longest key (parseShortcuts)
    if (!hasTokenKeys_ || !shortcutsEnabled_ || !shortcuts_ || !surroundingEdits_) return false;
    if (mode_ == DisplayMode::Direct) return false;  // nothing can be read back
    const std::string word = vt_is_empty(e_) ? std::string() : composed();
    const bool preedit = mode_ == DisplayMode::Preedit;
    std::string before;
    if (!ic.textBeforeCursorTail(kMaxKeyChars + 1, before)) return false;
    // Surrounding: the word in progress is already on screen; Preedit: it is not.
    if (!preedit && !endsWithBytes(before, word)) return false;
    const std::string screen = preedit ? before + word : before;
    size_t start = screen.size();
    while (start > 0 && screen[start - 1] != ' ' && screen[start - 1] != '\t' && screen[start - 1] != '\n' &&
           screen[start - 1] != '\r')
        --start;
    // No whitespace in what was read and more than a key's length: where the run starts is unknown.
    if (start == 0 && utf8Chars(before) > kMaxKeyChars) return false;
    const std::string token = screen.substr(start);
    if (token.size() <= word.size() || !isTokenShortcutKey(token)) return false;  // the word path's
    std::string expansion;
    if (!shortcutExpansion(*shortcuts_, token, expansion)) return false;
    if (ic.hasSelection() || selectionAtCaret(ic)) return false;
    if (!preedit && !inPlaceAllowed(ic, word, int(utf8Chars(token)))) return false;
    // Committed part of the run ("=>" / ":" of ":D"); in Surrounding the word goes too.
    const std::string onScreen = preedit ? token.substr(0, token.size() - word.size()) : token;
    vt_reset(e_);
    if (preedit) hidePreedit(ic);
    replace(ic, int(utf8Chars(onScreen)), expansion, onScreen);
    if (hintsOn_) tailReset();
    learn_.discard();
    lastEnded_ = EndedWord();
    lastWasBoundaryChar_ = false;
    return true;
}

bool Session::tryAutoReplace(bool space, int64_t prevSpaceMs, bool spaceHeld, bool prevEmDashOurs,
                             InputContext &ic) {
    if (!autoTextHere() || !surroundingEdits_) return false;
    if (space && prevSpaceMs < 0) return false;
    // Two characters are needed; a shorter tail with unknown text before it: read them back.
    std::string before = tail_;
    if (utf8Chars(before) < 2 && tailHead_ == TailHead::Unknown && !ic.textBeforeCursorTail(2, before)) return false;
    if (before.empty()) return false;
    std::string expect, insert;
    if (space) {
        uint32_t prev = 0;
        int64_t now = nowMs_ ? nowMs_() : 0;
        if (!autotext::doubleSpacePeriod(before, now - prevSpaceMs, spaceHeld, &prev)) return false;
        expect = encode(prev) + " ";
        insert = ". ";
    } else {
        switch (autotext::dash(before, prevEmDashOurs)) {
        case autotext::DashEdit::None: return false;
        case autotext::DashEdit::EmDash:
            expect = before.substr(lastCharsOffset(before, 2));
            insert = "\xe2\x80\x94";  // —
            break;
        case autotext::DashEdit::Restore:
            expect = "\xe2\x80\x94";
            insert = "---";
            break;
        }
    }
    std::string screen;
    if (!ic.textBeforeCursorTail(utf8Chars(expect), screen) || !endsWith(screen, expect)) return false;
    if (ic.hasSelection()) return false;
    replace(ic, 1, insert, expect);
    if (hintsOn_) {
        tailPop(1);
        tailAppend(insert);
    }
    vt_forget_last_commit(e_);  // ⌫ deletes what was inserted, it does not re-open a word
    lastEnded_ = EndedWord();
    lastEmDashOurs_ = !space && insert != "---";
    return true;
}

}  // namespace viettelex
