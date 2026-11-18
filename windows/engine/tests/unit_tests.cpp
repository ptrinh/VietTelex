// Structural invariants (port of android EngineInvariantTest + Swift ScreenSimulation /
// PeekCommit / Reopen / Seed / Overflow tests) and the zero-allocation guarantee.
#include <atomic>
#include <cstdio>
#include <cstdlib>
#include <new>
#include <string>
#include <utility>
#include "support.hpp"
#include "viettelex/vtx_engine.h"

// ---- allocation counter (whole test binary) ----------------------------------------
static std::atomic<long> gAllocs{0};
void* operator new(std::size_t n) {
    gAllocs.fetch_add(1, std::memory_order_relaxed);
    if (void* p = std::malloc(n ? n : 1)) return p;
    std::abort();
}
void operator delete(void* p) noexcept { std::free(p); }
void operator delete(void* p, std::size_t) noexcept { std::free(p); }

using namespace vt;

namespace {

int gPass = 0, gFail = 0;
volatile int gSink = 0;   // keeps calls whose result is unused from being optimised away
#define CHECK(cond) do { if (cond) ++gPass; else { ++gFail; std::printf("FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond); } } while (0)
#define CHECK_EQ(a, b) do { auto _a = (a); auto _b = (b); if (_a == _b) ++gPass; else { ++gFail; \
    std::printf("FAIL %s:%d: %s == %s  (\"%s\" vs \"%s\")\n", __FILE__, __LINE__, #a, #b, std::string(_a).c_str(), std::string(_b).c_str()); } } while (0)

struct Rng {
    uint64_t s;
    uint64_t next() { s ^= s << 13; s ^= s >> 7; s ^= s << 17; return s; }
    int below(int n) { return static_cast<int>(next() % static_cast<uint64_t>(n)); }
    bool coin() { return next() & 1; }
};

bool isReplace(const vtx::Action& a, int bs, const char* insert) {
    return a.kind == vtx::Action::Replace && a.backspaces == bs && text(a) == insert;
}

void applyScreen(std::u32string& sb, const vtx::Action& a, char32_t ch, bool isBackspace, bool& ok) {
    if (a.kind == vtx::Action::Passthrough) {
        if (!isBackspace) sb.push_back(ch); else if (!sb.empty()) sb.pop_back();
    } else if (a.kind == vtx::Action::Replace) {
        if (static_cast<size_t>(a.backspaces) > sb.size()) { ok = false; return; }
        sb.resize(sb.size() - static_cast<size_t>(a.backspaces));
        for (int i = 0; i < a.length; ++i) sb.push_back(a.text[i]);
    }
}

void screenAlwaysEqualsComposed() {
    Rng rnd{40};
    const std::string keys = "aaeeoouuwwddsfrxjzbcghiklmnpqtvyAEOUWDSF<<<";
    int bad = 0;
    for (int it = 0; it < 20000; ++it) {
        vtx::TelexEngine e;
        e.freeMarking = rnd.coin(); e.simpleTelex = rnd.coin(); e.liveSpellCheck = rnd.coin();
        e.modernTone = rnd.coin(); e.quickTelex = rnd.below(4) == 0; e.teencode = rnd.coin();
        e.vniMode = rnd.below(8) == 0;
        std::u32string sb;
        int n = 1 + rnd.below(24);
        vtx::Action a;
        for (int i = 0; i < n; ++i) {
            char c = keys[static_cast<size_t>(rnd.below(static_cast<int>(keys.size())))];
            bool ok = true;
            if (c == '<') { e.backspace(a); applyScreen(sb, a, 0, true, ok); }
            else { e.feed(static_cast<char32_t>(c), a); applyScreen(sb, a, static_cast<char32_t>(c), false, ok); }
            if (!ok || toUtf8(sb) != composed(e)) { ++bad; break; }
        }
    }
    CHECK(bad == 0);
}

void peekMatchesCommitOnCopy() {
    Rng rnd{7};
    const std::string keys = "aeouwdsfrxjzbchnglmtiyAS";
    int bad = 0;
    for (int it = 0; it < 10000; ++it) {
        vtx::TelexEngine e;
        e.freeMarking = rnd.coin(); e.simpleTelex = rnd.coin(); e.liveSpellCheck = rnd.coin();
        e.contextualEnglish = rnd.coin(); e.collisionPrefersVietnamese = rnd.coin(); e.teencode = rnd.coin();
        vtx::Action a;
        int words = 1 + rnd.below(3);
        for (int w = 0; w < words; ++w) {
            int n = 1 + rnd.below(10);
            for (int i = 0; i < n; ++i) e.feed(static_cast<char32_t>(keys[static_cast<size_t>(rnd.below(static_cast<int>(keys.size())))]), a);
            bool autoRestore = rnd.coin();
            std::string before = composed(e);
            std::string p = peek(e, autoRestore);
            if (before != composed(e)) ++bad;
            vtx::TelexEngine copy = e;
            if (p != commitText(copy, autoRestore)) ++bad;
            commitText(e, autoRestore);
        }
    }
    CHECK(bad == 0);
}

void reopenIssue40() {
    vtx::TelexEngine e;
    e.freeMarking = true; e.simpleTelex = true; e.liveSpellCheck = true;
    feedStr(e, "thasy");
    CHECK_EQ(composed(e), std::string("tháy"));
    vtx::Action a;
    e.commitBoundary(true, a);
    CHECK(a.kind == vtx::Action::None);
    CHECK(e.canReopenLastCommit());
    char16_t b[vtx::kMaxText];
    int n = e.reopenLastCommit(b, vtx::kMaxText);
    CHECK_EQ(toUtf8(b, n > 0 ? n : 0), std::string("tháy"));
    CHECK_EQ(raw(e), std::string("thasy"));
    e.feed(U'a', a);
    CHECK(isReplace(a, 2, "ấy"));
    CHECK_EQ(composed(e), std::string("thấy"));
}

void reopenBackspaceThroughWord() {
    vtx::TelexEngine e;
    e.freeMarking = true; e.simpleTelex = true; e.liveSpellCheck = true;
    feedStr(e, "dduwowngf");
    vtx::Action a;
    e.commitBoundary(true, a);
    char16_t b[vtx::kMaxText];
    int n = e.reopenLastCommit(b, vtx::kMaxText);
    CHECK_EQ(toUtf8(b, n > 0 ? n : 0), std::string("đường"));
    const char* steps[] = {"đườn", "đườ", "đư", "đ", ""};
    for (const char* s : steps) { e.backspace(a); CHECK_EQ(composed(e), std::string(s)); }
    CHECK(!e.canReopenLastCommit());
    CHECK(e.reopenLastCommit(b, vtx::kMaxText) == -1);
}

// ---- Twin of Swift ContractionCapsReopenTests (07/11/2026) ---------------------------

void macFlags(vtx::TelexEngine& e) {   // AppState.EngineFlags
    e.freeMarking = true; e.liveSpellCheck = true; e.contextualEnglish = true;
    e.collisionPrefersVietnamese = true; e.teencode = false; e.eagerEnglishRestore = true;
}
void defaultFlags(vtx::TelexEngine& e) { e.liveSpellCheck = true; }

bool isAsciiLetter(char32_t c) { return (c >= U'a' && c <= U'z') || (c >= U'A' && c <= U'Z'); }

// Host-like replay: a non-letter is the word's boundary (passed to commitBoundary), then inserted.
std::string typedWith(const std::string& s, void (*cfg)(vtx::TelexEngine&), bool passBoundary = true) {
    vtx::TelexEngine e;
    cfg(e);
    std::u32string screen;
    vtx::Action a;
    bool ok = true;
    for (char32_t c : fromUtf8(s)) {
        if (isAsciiLetter(c)) {
            e.feed(c, a);
            applyScreen(screen, a, c, false, ok);
        } else {
            e.commitBoundary(true, a, passBoundary ? c : 0);
            applyScreen(screen, a, 0, false, ok);
            screen.push_back(c);
            e.noteBoundaryCharacter(c);
        }
    }
    e.commitBoundary(true, a);
    applyScreen(screen, a, 0, false, ok);
    return ok ? toUtf8(screen) : std::string("<desync>");
}
std::string typedMac(const std::string& s) { return typedWith(s, macFlags); }

// Marked-text path: commitText(boundary) and peekCommitText(boundary) must agree.
std::string typedMarked(const std::string& s) {
    vtx::TelexEngine e;
    macFlags(e);
    std::string out;
    vtx::Action a;
    char16_t b[vtx::kMaxText];
    for (char32_t c : fromUtf8(s)) {
        if (isAsciiLetter(c)) { e.feed(c, a); continue; }
        std::string p = toUtf8(b, e.peekCommitText(true, b, vtx::kMaxText, c));
        std::string t = toUtf8(b, e.commitText(true, b, vtx::kMaxText, c));
        CHECK_EQ(p, t);
        out += t;
        appendUtf8(out, c);
        e.noteBoundaryCharacter(c);
    }
    return out + commitText(e, true);
}

void contractionsAtApostrophe() {
    const char* cases[] = {"doesn't", "isn't", "hasn't", "didn't", "won't", "there's", "can't", "aren't",
                           "weren't", "wasn't", "haven't", "couldn't", "shouldn't", "wouldn't", "we're",
                           "I'll", "here's", "what's", "who's", "it's", "that's", "let's", "you're", "they've"};
    for (const char* w : cases) {
        CHECK_EQ(typedMac(w), std::string(w));
        CHECK_EQ(typedWith(w, defaultFlags), std::string(w));
        CHECK_EQ(typedMarked(w), std::string(w));
    }
    CHECK_EQ(typedMac("DOESN'T"), std::string("DOESN'T"));
    CHECK_EQ(typedMac("Isn't it"), std::string("Isn't it"));
    CHECK_EQ(typedMac("it doesn’t"), std::string("it doesn’t"));
    // No boundary passed = old behaviour.
    CHECK_EQ(typedWith("doesn't", macFlags, false), std::string("doén't"));
    CHECK_EQ(typedWith("won't", macFlags, false), std::string("ươn't"));
    // Vietnamese in single quotes stays Vietnamese.
    CHECK_EQ(typedMac("'tieesng'"), std::string("'tiếng'"));
    CHECK_EQ(typedMac("'Vieejt Nam'"), std::string("'Việt Nam'"));
    CHECK_EQ(typedMac("'ddi'"), std::string("'đi'"));
    CHECK_EQ(typedMac("cas'"), std::string("cá'"));
    CHECK_EQ(typedMarked("'tieesng'"), std::string("'tiếng'"));
    // Auto-restore off keeps the composition.
    vtx::TelexEngine e;
    macFlags(e);
    feedStr(e, "doesn");
    char16_t b[vtx::kMaxText];
    CHECK_EQ(toUtf8(b, e.commitText(false, b, vtx::kMaxText, U'\'')), std::string("doén"));
    // C ABI entry point.
    vtx_engine* h = vtx_create();
    vtx_set_flags(h, VTX_ENGINE_DEFAULT_FLAGS | VTX_LIVE_SPELL_CHECK);
    vtx_action ca;
    for (char c : std::string("isn")) vtx_feed(h, static_cast<uint32_t>(c), &ca);
    vtx_commit_boundary_before(h, 1, U'\'', &ca);
    CHECK(ca.kind == VTX_REPLACE);
    CHECK_EQ(toUtf8(reinterpret_cast<const char16_t*>(ca.insert), ca.insert_len), std::string("isn"));
    for (char c : std::string("won")) vtx_feed(h, static_cast<uint32_t>(c), &ca);
    uint16_t tb[VTX_MAX_TEXT];
    int32_t tn = vtx_commit_text_before(h, 1, 0x2019, tb, VTX_MAX_TEXT);
    CHECK_EQ(toUtf8(reinterpret_cast<const char16_t*>(tb), tn), std::string("won"));
    vtx_destroy(h);
}

void reachBackVowelCancel() {
    for (const char* w : {"seemed", "deemed", "needed", "deeper", "Seemed"}) CHECK_EQ(typedMac(w), std::string(w));
    CHECK_EQ(typedMac("Deffault"), std::string("Default"));
    CHECK_EQ(typedMac("iss"), std::string("is"));
    CHECK_EQ(typedMac("messs"), std::string("mess"));
    CHECK_EQ(typedMac("themee"), std::string("theme"));
    CHECK_EQ(typedMac("gooogle"), std::string("google"));
    CHECK_EQ(typedWith("Deffault", defaultFlags), std::string("Default"));
    CHECK_EQ(typedWith("iss", defaultFlags), std::string("is"));
    CHECK_EQ(typedWith("messs", defaultFlags), std::string("mess"));
}

void allCapsAcronyms() {
    for (const char* w : {"NASA", "ASAP", "USA", "WWDC", "USSR", "WWF", "ISP", "VISA", "MUST", "TEST", "POST", "TAXI"}) {
        CHECK_EQ(typedMac(w), std::string(w));
        CHECK_EQ(typedWith(w, defaultFlags), std::string(w));
    }
    CHECK_EQ(typedMac("NASA and ASAP"), std::string("NASA and ASAP"));
    CHECK_EQ(typedMac("VDDV"), std::string("VĐV"));
    CHECK_EQ(typedMac("HDDND"), std::string("HĐND"));
    CHECK_EQ(typedMac("BDDS"), std::string("BĐS"));
    CHECK_EQ(typedMac("THOONG"), std::string("THÔNG"));
    CHECK_EQ(typedMac("DDaf Nawngx"), std::string("Đà Nẵng"));
    CHECK_EQ(typedMac("TIEESNG VIEETJ"), std::string("TIẾNG VIỆT"));
    CHECK_EQ(typedMac("CAS"), std::string("CÁ"));
    CHECK_EQ(typedMac("MUTS"), std::string("MÚT"));
    CHECK_EQ(typedMac("VIAS"), std::string("VIAS"));
    CHECK_EQ(typedMac("TETS"), std::string("TÉT"));
    CHECK_EQ(typedMac("TAIX"), std::string("TÃI"));
    CHECK_EQ(typedMac("Os"), std::string("Ó"));
    CHECK_EQ(typedWith("DAJA", defaultFlags), std::string("DẠA"));
    CHECK_EQ(typedMac("HDD"), std::string("HĐ"));
    CHECK_EQ(typedMac("HW"), std::string("HƯ"));
    CHECK_EQ(typedMac("nasa"), std::string("nấ"));
    CHECK_EQ(typedWith("nasa", defaultFlags), std::string("nasa"));
}

// ---- Twin of Swift HatInitialismTests (08/11/2026): "AAL" -> ÂL (âm lịch) -------------

void plainFlags(vtx::TelexEngine&) {}

// (live composition, commitText at a space boundary); peek must agree.
std::pair<std::string, std::string> liveAndCommit(const std::string& w, void (*cfg)(vtx::TelexEngine&)) {
    vtx::TelexEngine e;
    cfg(e);
    feedStr(e, w);
    std::string live = composed(e);
    char16_t b[vtx::kMaxText];
    std::string p = toUtf8(b, e.peekCommitText(true, b, vtx::kMaxText, U' '));
    std::string c = toUtf8(b, e.commitText(true, b, vtx::kMaxText, U' '));
    CHECK_EQ(p, c);
    return {live, c};
}

void hatInitialism() {
    void (*cfgs[])(vtx::TelexEngine&) = {macFlags, plainFlags, defaultFlags};
    struct K { const char* keys; const char* want; };
    const K kept[] = {{"AAL", "ÂL"}, {"aal", "âl"}, {"UWD", "ƯD"}, {"uwd", "ưd"}, {"OWB", "ƠB"}};
    const char* raw[] = {"EEL", "eel", "OOH", "ooh", "EEK", "eek", "BOOK", "book", "COOL", "cool",
                         "LOOK", "look", "FEED", "feed", "OOTD", "ootd", "AAPL", "aapl", "EEG", "eeg",
                         "OOP", "oop", "AAC", "aac", "OWL", "owl", "AWL", "awl", "AAH", "aah",
                         "UWB", "UWP", "AWK", "awk", "aat", "AAT", "eep", "eet", "oog", "OOG", "uwk", "awt", "owp", "uwc", "Aal", "aAL", "AAl", "WL", "wl"};
    for (auto cfg : cfgs) {
        for (const K& k : kept) {
            auto r = liveAndCommit(k.keys, cfg);
            CHECK_EQ(r.first, std::string(k.want));
            CHECK_EQ(r.second, std::string(k.want));
            CHECK_EQ(typedWith(k.keys, cfg), std::string(k.want));
        }
        CHECK_EQ(typedWith("ngayf 15 AAL", cfg), std::string("ngày 15 ÂL"));
        CHECK_EQ(typedWith("BDDS DDT", cfg), std::string("BĐS ĐT"));
        for (const char* w : raw) CHECK_EQ(liveAndCommit(w, cfg).second, std::string(w));
        CHECK_EQ(liveAndCommit("AAAL", cfg).second, std::string("AAL"));   // literal via the AAA cancel
        CHECK_EQ(liveAndCommit("aaal", cfg).second, std::string("aal"));
        CHECK_EQ(liveAndCommit("OOF", cfg).second, std::string("Ồ"));
        CHECK_EQ(liveAndCommit("oof", cfg).second, std::string("ồ"));
        CHECK_EQ(liveAndCommit("AAN", cfg).second, std::string("ÂN"));
        CHECK_EQ(liveAndCommit("OOM", cfg).second, std::string("ÔM"));
    }
}

void reopenAfterNoOpRestore() {
    struct C { const char* w; char32_t tone; const char* expected; };
    const C cases[] = {{"hoc", U'j', "học"}, {"tien", U's', "tién"}, {"nguoi", U'f', "nguòi"},
                       {"viet", U'j', "viẹt"}, {"mot", U'j', "mọt"}};
    char16_t b[vtx::kMaxText];
    vtx::Action a;
    for (const C& c : cases) {
        for (int cfg = 0; cfg < 2; ++cfg) {
            vtx::TelexEngine e;
            if (cfg == 0) macFlags(e); else defaultFlags(e);
            feedStr(e, c.w);
            e.commitBoundary(true, a);
            CHECK(a.kind == vtx::Action::None);
            CHECK(e.canReopenLastCommit());
            int n = e.reopenLastCommit(b, vtx::kMaxText);
            CHECK_EQ(toUtf8(b, n > 0 ? n : 0), std::string(c.w));
            e.feed(c.tone, a);
            CHECK_EQ(composed(e), std::string(c.expected));
        }
    }
    {   // marked-text commit
        vtx::TelexEngine e;
        macFlags(e);
        feedStr(e, "hoc");
        CHECK_EQ(commitText(e, true), std::string("hoc"));
        int n = e.reopenLastCommit(b, vtx::kMaxText);
        CHECK_EQ(toUtf8(b, n > 0 ? n : 0), std::string("hoc"));
        e.feed(U'j', a);
        CHECK_EQ(composed(e), std::string("học"));
    }
    for (const char* w : {"paper", "windows", "after", "github"}) {   // frozen English, no-op restore
        vtx::TelexEngine e;
        e.freeMarking = true; e.simpleTelex = true; e.liveSpellCheck = true;
        feedStr(e, w);
        e.commitBoundary(true, a);
        CHECK(a.kind == vtx::Action::None);
        CHECK(e.canReopenLastCommit());
        int n = e.reopenLastCommit(b, vtx::kMaxText);
        CHECK_EQ(toUtf8(b, n > 0 ? n : 0), std::string(w));
        e.feed(U's', a);
        CHECK_EQ(composed(e), std::string(w) + "s");
        CHECK_EQ(commitText(e, true), std::string(w) + "s");
    }
    {   // a visible restore still drops the snapshot
        vtx::TelexEngine e;
        macFlags(e);
        feedStr(e, "doesn");
        e.commitBoundary(true, a, U'\'');
        CHECK(!e.canReopenLastCommit());
    }
}

void seedRoundTrips() {
    vtx::TelexEngine e;
    vtx::Action a;
    CHECK(seed(e, "toan")); e.feed(U's', a); CHECK(isReplace(a, 2, "án"));
    CHECK(seed(e, "Việt")); CHECK_EQ(composed(e), std::string("Việt"));
    CHECK(!seed(e, "google"));
    CHECK(!seed(e, "hoà"));
    e.modernTone = true;
    CHECK(seed(e, "hoà"));
    e.vniMode = true;
    CHECK(seed(e, "đường")); CHECK_EQ(raw(e), std::string("d9u7o7ng2"));
    e.vniMode = false; e.modernTone = false;
    CHECK(seed(e, "ĐƯỜNG")); CHECK_EQ(raw(e), std::string("DDUWOWNGf"));
    CHECK(!seed(e, "a1"));
    CHECK(!seed(e, "é́"));
    // UTF-16 entry point (what the TIP passes from ITfRange::GetText).
    const char16_t w[] = u"thấy";
    CHECK(e.seed(w, 4)); CHECK_EQ(composed(e), std::string("thấy"));
    const char16_t sur[] = {0xD83D, 0xDE00};
    CHECK(!e.seed(sur, 2)); CHECK(e.isEmpty());
}

void overflowPassesThrough() {
    vtx::TelexEngine e;
    vtx::Action a;
    bool allPass = true;
    for (int i = 0; i < 32; ++i) { e.feed(U'b', a); allPass = allPass && a.kind == vtx::Action::Passthrough; }
    CHECK(allPass);
    CHECK(!e.isOverflowed());
    e.feed(U'b', a); CHECK(a.kind == vtx::Action::Passthrough);
    CHECK(e.isOverflowed());
    e.backspace(a); CHECK(a.kind == vtx::Action::Passthrough);
    e.commitBoundary(true, a); CHECK(a.kind == vtx::Action::None);
    CHECK(e.isEmpty());
}

void nonLetterPassesThrough() {
    vtx::TelexEngine e;
    vtx::Action a;
    for (char32_t c : fromUtf8("1.,!ễ[")) { e.feed(c, a); CHECK(a.kind == vtx::Action::Passthrough); }
    e.feed(0x1F600, a); CHECK(a.kind == vtx::Action::Passthrough);
    CHECK(e.isEmpty());
}

void hotPathDoesNotAllocate() {
    vtx::TelexEngine e;
    e.freeMarking = true; e.liveSpellCheck = true; e.contextualEnglish = true;
    e.collisionPrefersVietnamese = true; e.teencode = false;
    const char* text = "Vieetj Nam laf mootj ddaats nuwowcs xinh ddepj googlee installer thiss is the list "
                       "nguoiwf truwowngf DDHQG hooongggg aaaa<< ddaay<<<";
    vtx::Action a;
    char16_t buf[vtx::kMaxText];
    long before = gAllocs.load();
    for (int rep = 0; rep < 200; ++rep) {
        for (const char* p = text; *p; ++p) {
            if (*p == ' ') { e.peekCommitText(true, buf, vtx::kMaxText); e.commitBoundary(true, a); }
            else if (*p == '<') e.backspace(a);
            else e.feed(static_cast<char32_t>(*p), a);
            gSink += e.hasSpellingError(true) ? 1 : 0;   // opt-in underline: per-key, no heap
        }
        e.commitText(true, buf, vtx::kMaxText);
        // Acronym / typo keep / glue / restore-undo paths (boundary-only, fixed buffers).
        for (const char* p = "NAS lanwm his my_var 100W "; *p; ++p) {
            if (*p == ' ' || *p == '_' || (*p >= '0' && *p <= '9')) {
                e.commitBoundary(true, a);
                vtx::RestoreUndo u;
                gSink += e.takeRestoreUndo(u) ? u.vietnameseLength : 0;
                e.noteBoundaryCharacter(static_cast<char32_t>(*p));
            } else {
                e.feed(static_cast<char32_t>(*p), a);
            }
        }
        e.feed(U'x', a); e.commitBoundary(true, a);
        e.backspace(a); e.reopenLastCommit(buf, vtx::kMaxText); e.reset();
        e.seed(u"thấy", 4); e.reset();
    }
    CHECK(gAllocs.load() - before == 0);
}

// Shared vectors (TelexCore/Tests/TelexCoreTests/Resources/spelling_error_cases.tsv) for
// the opt-in red underline: isValidSyllable / isSpellingError / hasSpellingError.
void spellingErrorCases() {
#ifdef VTX_SPELLING_CASES
    std::FILE* f = std::fopen(VTX_SPELLING_CASES, "rb");
    CHECK(f != nullptr);
    if (!f) return;
    char line[512];
    int rows = 0;
    while (std::fgets(line, sizeof line, f)) {
        std::string l(line);
        while (!l.empty() && (l.back() == '\n' || l.back() == '\r')) l.pop_back();
        if (l.empty() || l[0] == '#') continue;
        std::string col[4];
        int c = 0;
        for (char ch : l) {
            if (ch == '\t') { if (++c > 3) break; continue; }
            col[c].push_back(ch);
        }
        const bool want = col[2] == "1";
        bool got = false;
        if (col[0] == "syllable" || col[0] == "error") {
            std::u32string w = fromUtf8(col[1]);
            const int n = static_cast<int>(w.size());
            got = col[0] == "syllable" ? vtx::SyllableValidator::isValidSyllable(w.data(), n, false)
                                       : vtx::SyllableValidator::isSpellingError(w.data(), n, false);
        } else if (col[0] == "keys") {
            vtx::TelexEngine e;   // app defaults
            e.freeMarking = true; e.contextualEnglish = true; e.collisionPrefersVietnamese = true;
            e.teencode = false;
            e.liveSpellCheck = col[3].find('L') == std::string::npos;
            const bool autoRestore = col[3].find('R') == std::string::npos;
            vtx::Action a;
            for (char k : col[1]) e.feed(static_cast<char32_t>(static_cast<unsigned char>(k)), a);
            got = e.hasSpellingError(autoRestore);
        } else {
            CHECK(!"unknown row kind");
            continue;
        }
        ++rows;
        if (got == want) ++gPass;
        else { ++gFail; std::printf("FAIL spelling case: %s %s want %d\n", col[0].c_str(), col[1].c_str(), want); }
    }
    std::fclose(f);
    CHECK(rows > 50);
#else
    CHECK(!"VTX_SPELLING_CASES not defined");
#endif
    // Never flagged without a word, and the C ABI agrees with the method.
    vtx::TelexEngine empty;
    CHECK(!empty.hasSpellingError(true));
}

// UpperToneBackspaceTests.testBackspaceEqualsRetypeWithoutLastKey (same LCG, same
// sequences as Swift/Kotlin): when the last key was inserted literally, ⌫ == retyping
// the keys without it on a fresh engine with the same settings.
void backspaceEqualsRetypeWithoutLastKey() {
    uint64_t seed = 0x9E3779B97F4A7C15ULL;
    auto next = [&seed]() { seed = seed * 6364136223846793005ULL + 1442695040888963407ULL; return seed >> 33; };
    auto typed = [](int cfg, const std::string& keys) {
        vtx::TelexEngine e;
        e.liveSpellCheck = (cfg & 1) != 0; e.freeMarking = (cfg & 2) != 0;
        e.simpleTelex = (cfg & 4) != 0; e.teencode = (cfg & 8) != 0; e.vniMode = (cfg & 16) != 0;
        feedStr(e, keys);
        return e;
    };
    const std::string telexKeys = "aeiouydwsfrxjzntcghl";
    const std::string vniKeys = "aeiouydntcgh1234567890";
    int checked = 0, bad = 0;
    for (int cfg = 0; cfg < 32; ++cfg) {
        const std::string& keys = (cfg & 16) ? vniKeys : telexKeys;
        for (int it = 0; it < 600; ++it) {
            std::string word;
            const int len = 3 + static_cast<int>(next() % 6);
            for (int i = 0; i < len; ++i) {
                char c = keys[static_cast<size_t>(next() % keys.size())];
                if (next() % 3 == 0 && c >= 'a' && c <= 'z') c = static_cast<char>(c - 'a' + 'A');
                word.push_back(c);
            }
            if (checked == 0) word = "uxuJxwl";
            for (size_t n = 2; n <= word.size(); ++n) {
                const std::string prefix = word.substr(0, n - 1);
                vtx::TelexEngine e = typed(cfg, word.substr(0, n));
                const std::string fresh = composed(typed(cfg, prefix));
                if (composed(e) != fresh + word[n - 1]) continue;
                ++checked;
                vtx::Action a;
                e.backspace(a);
                if (composed(e) != fresh) {
                    if (++bad <= 10) std::printf("FAIL ⌫ cfg=%d keys=%s got %s want %s\n", cfg,
                                                 word.substr(0, n).c_str(), composed(e).c_str(), fresh.c_str());
                }
            }
        }
    }
    for (const char* k : {"VieeJt", "uxuJxwl"}) {
        const std::string keys = k;
        for (int cfg = 0; cfg < 16; ++cfg) {
            vtx::TelexEngine e = typed(cfg, keys);
            vtx::Action a;
            e.backspace(a);
            CHECK_EQ(composed(e), composed(typed(cfg, keys.substr(0, keys.size() - 1))));
        }
    }
    CHECK(bad == 0);
    CHECK(checked > 20000);
}

// Issue #138: Vietnamese name + glued uppercase initials ("PhuwowngTH" → PhươngTH).
// Twin of TelexCore InitialsSuffixTests.swift; the golden corpus covers the rest.
void initialsSuffix() {
    struct Case { const char* keys; const char* want; };
    const Case cases[] = {
        {"PhuwowngTH", "PhươngTH"}, {"KieenTV", "KiênTV"}, {"HungfNV", "HùngNV"},
        {"LinhPTT", "LinhPTT"}, {"KieenSV", "KiênSV"}, {"NguyeenXJ", "NguyênXJ"},
        {"DDinhNV", "ĐinhNV"},
        // guards: unchanged behaviour
        {"KieenS", "KieenS"}, {"SaaS", "SaaS"}, {"iOS", "iOS"}, {"macOS", "macOS"},
        {"PhD", "PhD"}, {"JavaScript", "JavaScript"}, {"GitHub", "GitHub"},
        {"AsJSON", "AsJSON"}, {"HasID", "HasID"}, {"VIEETJ", "VIỆT"}, {"HDDND", "HĐND"},
        {"PhuwowngTHa", "PhuwowngTHa"},
        // code acronym runs are not initials (MaxID used to give MãID)
        {"MaxID", "MaxID"}, {"ResID", "ResID"}, {"PosID", "PosID"}, {"RowID", "RowID"},
        {"TaxID", "TaxID"}, {"BoxID", "BoxID"}, {"LasID", "LasID"}, {"MaxIDS", "MaxIDS"},
        {"TaxURL", "TaxURL"}, {"PosAPI", "PosAPI"}, {"BoxUI", "BoxUI"}, {"RowJSON", "RowJSON"},
        {"ResAPI", "ResAPI"}, {"MaxCSV", "MaxCSV"}, {"hasID", "hasID"}, {"userID", "userID"},
        {"getURL", "getURL"}, {"SetID", "SetID"}, {"DocID", "DocID"}, {"GetURL", "GetURL"},
        {"OrderID", "OrderID"}, {"DataDB", "DataDB"},
        // runs left out of the acronym list (plausible initials) still split
        {"HungfVM", "HùngVM"}, {"TuaansPX", "TuấnPX"}, {"HungfDB", "HùngDB"},
    };
    for (int live = 0; live < 2; ++live) {
        for (const auto& c : cases) {
            vtx::TelexEngine e;
            e.liveSpellCheck = live != 0;
            feedStr(e, c.keys);
            CHECK_EQ(peek(e, true), std::string(c.want));
            CHECK_EQ(commitText(e, true), std::string(c.want));
        }
        vtx::TelexEngine e;
        e.liveSpellCheck = live != 0;
        vtx::Action a;
        feedStr(e, "KieenSV");
        e.backspace(a);
        CHECK_EQ(composed(e), std::string("KieenS"));
        e.feed(U'V', a);
        CHECK_EQ(composed(e), std::string("KiênSV"));
    }
}

// Controller-style replay (Swift ZZ harness / platform sessions): letters compose; any other
// character commits the word, is inserted, and is reported with noteBoundaryCharacter.
// Restore-undo records are appended as "{restored>vietnamese}".
std::string typeLikeController(vtx::TelexEngine& e, const std::string& text) {
    std::u32string in = fromUtf8(text);
    std::string out;
    auto commit = [&] {
        out += commitText(e, true);
    };
    std::string undos;
    auto takeUndo = [&] {
        vtx::RestoreUndo u;
        if (e.takeRestoreUndo(u))
            undos += "{" + toUtf8(u.restored, u.restoredLength) + ">" + toUtf8(u.vietnamese, u.vietnameseLength) + "}";
    };
    vtx::Action a;
    for (char32_t c : in) {
        if ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')) { e.feed(c, a); continue; }
        commit();
        takeUndo();
        std::u32string one(1, c);
        out += toUtf8(one);
        e.noteBoundaryCharacter(c);
    }
    commit();
    takeUndo();
    return out + undos;
}

// Acronyms, Vietnamese typo keep, glued separators/digits, restore-undo (Swift parity:
// TelexCore AcronymTypoGlueTests).
void acronymTypoGlueUndo() {
    struct Case { const char* in; const char* want; };
    const Case suite[] = {   // liveSpellCheck on, everything else engine default
        {"NAS", "NAS{NAS>NÁ}"}, {"OS", "OS{OS>Ó}"}, {"AWS", "AWS{AWS>Ắ}"}, {"TOAS", "TÓA"},
        {"VIEEJT", "VIỆT"}, {"DDAF NAWXNG", "ĐÀ NẴNG"}, {"HDDND", "HĐND"}, {"VNDD", "VNĐ"},
        {"AA", "Â"}, {"COS", "CÓ"}, {"QUYEETS DDINHJ", "QUYẾT ĐỊNH"},
        {"deepseek", "deepseek"}, {"casual", "casual"}, {"tester", "tester"}, {"keep", "keep"},
        {"tieengsm", "tiếngm"},
        {"my_var", "my_var"}, {"MAX_SIZE", "MÃ_SIZE"}, {"ok.ddi", "ok.đi"}, {"haha.thooi", "haha.thôi"},
        {"vaf/hoawcj", "và/hoặc"}, {"anh/chij", "anh/chị"}, {"TP.Hoof", "TP.Hồ"},
        {"100W", "100W"}, {"10kW", "10kW"}, {"5trawm", "5trăm"}, {"2tieengs", "2tiếng"},
        {"100dd", "100đ"}, {"5s", "5s"}, {"4G", "4G"}, {"5tuw", "5tư"},
        {"5k/thangs", "5k/tháng"}, {"100k/nguwowif", "100k/người"}, {"2h/ngayf", "2h/ngày"},
        {"src/bas", "src/bas"},
        {"bene NAS", "bene NAS{NAS>NÁ}"},
    };
    for (const Case& c : suite) {
        vtx::TelexEngine e;
        e.liveSpellCheck = true;
        CHECK_EQ(typeLikeController(e, c.in), std::string(c.want));
    }
    {   // free marking: the typo stays on screen; "lanwm" without it has two vowel groups
        vtx::TelexEngine e;
        e.liveSpellCheck = true; e.freeMarking = true;
        CHECK_EQ(typeLikeController(e, "lanwm"), std::string("lănm"));
        vtx::TelexEngine s;
        s.liveSpellCheck = true;
        CHECK_EQ(typeLikeController(s, "lanwm"), std::string("lanwm"));
    }
    {   // teencode elongation keeps its own rule (all caps too)
        vtx::TelexEngine e;
        CHECK_EQ(typeLikeController(e, "DAJA"), std::string("DẠA"));
    }
    {   // English collision restore offers ⌫-undo; the acronym never opens an English run
        vtx::TelexEngine e;
        e.liveSpellCheck = true; e.contextualEnglish = true;
        CHECK_EQ(typeLikeController(e, "he is"), std::string("he is{is>í}"));
        vtx::TelexEngine r;
        r.liveSpellCheck = true; r.freeMarking = true; r.contextualEnglish = true; r.retroactiveEnglish = true;
        CHECK_EQ(typeLikeController(r, "bene ASL USB"), std::string("bên ASL USB"));
    }
    {   // the record is dropped by the next key, and restoreUndoApplied ends the English run
        vtx::TelexEngine e;
        e.contextualEnglish = true;
        vtx::Action a;
        feedStr(e, "the");
        e.commitBoundary(true, a);
        e.noteBoundaryCharacter(U' ');
        feedStr(e, "NAS");
        e.commitBoundary(true, a);
        vtx::RestoreUndo u;
        CHECK(e.pendingRestoreUndo(u));
        e.feed(U'x', a);
        CHECK(!e.takeRestoreUndo(u));
        e.reset();
        feedStr(e, "he");
        e.commitBoundary(true, a);
        e.noteBoundaryCharacter(U' ');
        feedStr(e, "is");
        e.commitBoundary(true, a);
        CHECK(e.takeRestoreUndo(u));
        CHECK_EQ(toUtf8(u.restored, u.restoredLength), std::string("is"));
        CHECK_EQ(toUtf8(u.vietnamese, u.vietnameseLength), std::string("í"));
        CHECK(e.previousWordEnglish());
        e.restoreUndoApplied();
        CHECK(!e.previousWordEnglish());
        CHECK(!e.takeRestoreUndo(u));
    }
}

// ---- Tự thêm dấu mũ (Swift AutoCircumflexTests.swift, issue #166) ---------------------
vtx::TelexEngine acEngine(bool on, bool live = true, bool teencode = false) {
    vtx::TelexEngine e; e.liveSpellCheck = live; e.teencode = teencode; e.autoCircumflex = on;
    return e;
}
std::string acCommit(const std::string& keys, bool on = true, bool live = true, bool teencode = false) {
    vtx::TelexEngine e = acEngine(on, live, teencode);
    feedStr(e, keys);
    return commitText(e, true);
}
std::string acComposed(const std::string& keys, bool on = true) {
    vtx::TelexEngine e = acEngine(on);
    feedStr(e, keys);
    return composed(e);
}

void autoCircumflex() {
    static const char* const kRows[][2] = {
        // iê, yê, uyê
        {"vietj", "việt"}, {"viejt", "việt"}, {"viecj", "việc"}, {"nguyenx", "nguyễn"},
        {"biets", "biết"}, {"tienf", "tiền"}, {"dieuf", "diều"}, {"ddieemr", "điểm"},
        {"thiengs", "thiếng"}, {"tiepj", "tiệp"}, {"yeus", "yếu"}, {"yenr", "yển"},
        {"yeets", "yết"}, {"chuyenj", "chuyện"}, {"quyets", "quyết"},
        {"ddienj", "điện"}, {"VIETJ", "VIỆT"}, {"Vietj", "Việt"},
        // ê trước nh, ch, u
        {"benhj", "bệnh"}, {"lechj", "lệch"}, {"keuf", "kều"}, {"ddeuf", "đều"},
        // uê
        {"hues", "huế"}, {"thuee", "thuê"}, {"tuechj", "tuệch"},
        // uâ
        {"luanj", "luận"}, {"xuats", "xuất"}, {"khuays", "khuấy"}, {"tuanf", "tuần"},
    };
    // testAddsTheHat
    for (const auto& r : kRows) {
        const std::string keys = r[0], want = r[1];
        if (keys == "hues" || keys == "thuee") continue;
        CHECK_EQ(acCommit(keys), want);
        CHECK_EQ(acCommit(keys, true, false), want);          // no live check
        CHECK_EQ(acCommit(keys, true, true, true), want);     // teencode
    }
    CHECK_EQ(acComposed("hues"), std::string("huế"));

    // testOffChangesNothing
    CHECK(!vtx::TelexEngine().autoCircumflex);
    for (const char* keys : {"vietj", "viejt", "benhj", "luanj", "keuf", "nguyenx"}) {
        vtx::TelexEngine a; a.liveSpellCheck = true;
        vtx::TelexEngine b; b.liveSpellCheck = true; b.autoCircumflex = false;
        feedStr(a, keys); feedStr(b, keys);
        const std::string ca = composed(a);
        CHECK_EQ(ca, composed(b));
        CHECK(ca.find("ệ") == std::string::npos && ca.find("ậ") == std::string::npos &&
              ca.find("ề") == std::string::npos && ca.find("ễ") == std::string::npos);
    }

    // testRealPlainRimesStay: the plain rime is a real one => untouched.
    static const char* const kStay[][2] = {
        {"quanr", "quản"}, {"quats", "quát"}, {"quays", "quáy"}, {"quef", "què"},
        {"xengr", "xẻng"}, {"secs", "séc"}, {"tenf", "tèn"}, {"mets", "mét"},
        {"hoanf", "hoàn"}, {"muaf", "mùa"}, {"kias", "kía"}, {"theer", "thể"},
        {"meof", "mèo"}, {"khoer", "khỏe"}, {"giengs", "giéng"},
    };
    for (const auto& r : kStay) CHECK_EQ(acCommit(r[0]), std::string(r[1]));

    // testNeedsALiveTone: no tone (or a tone the stop coda drops) => no hat.
    CHECK_EQ(acComposed("viet"), std::string("viet"));
    CHECK_EQ(acComposed("benh"), std::string("benh"));
    CHECK_EQ(acComposed("vietf"), acComposed("vietf", false));
    CHECK_EQ(acComposed("vietjj"), acComposed("vietjj", false));   // tone cancelled

    // testParseStateUntouched: render-only — typing on / deleting behave as without it.
    {
        vtx::TelexEngine e = acEngine(true);
        vtx::Action a;
        feedStr(e, "vietj");
        CHECK_EQ(composed(e), std::string("việt"));
        e.backspace(a);   // ⌫ deletes t, tone stays => open rime "ie" gets no hat
        CHECK_EQ(composed(e), std::string("vịe"));
        e.feed(U'c', a);
        CHECK_EQ(composed(e), std::string("việc"));
        // Typing the full "ee" still works as before.
        CHECK_EQ(acCommit("vieetj"), std::string("việt"));
        CHECK_EQ(acCommit("vieejt"), std::string("việt"));
        CHECK_EQ(acCommit("luaanj"), std::string("luận"));
        // Early tone: the hat appears once the rime is complete.
        CHECK_EQ(acComposed("viej"), acComposed("viej", false));
        CHECK_EQ(acComposed("viejt"), std::string("việt"));
    }

    // testEnglishStillRestores: keys that are an English word still restore as before.
    for (const char* w : {"clients", "guest", "reuse", "quest", "use"})
        CHECK_EQ(acCommit(w), acCommit(w, false));
}

} // namespace

int runUnit() {
    acronymTypoGlueUndo();
    initialsSuffix();
    screenAlwaysEqualsComposed();
    peekMatchesCommitOnCopy();
    reopenIssue40();
    reopenBackspaceThroughWord();
    contractionsAtApostrophe();
    reachBackVowelCancel();
    allCapsAcronyms();
    hatInitialism();
    reopenAfterNoOpRestore();
    seedRoundTrips();
    overflowPassesThrough();
    nonLetterPassesThrough();
    hotPathDoesNotAllocate();
    spellingErrorCases();
    backspaceEqualsRetypeWithoutLastKey();
    autoCircumflex();
    std::printf("unit invariants: %d/%d pass\n", gPass, gPass + gFail);
    return gFail == 0 ? 0 : 1;
}
