// test_auto_text — "văn bản tự động" (auto_text.h + Session): the pure rules ported from macOS
// (AppTests/SystemAutoTextTests.swift golden cases: double-space period, smart quotes, dashes,
// sentence capitals; WordPredictionTests: Esc mute, the helper protocol), and the Session
// wiring per display mode (Preedit / Surrounding / Direct, proven vs blind surrounding,
// password / English / terminals / code editors), all four switches OFF by default. The
// ranking itself (Swift, shared with iOS/macOS) is checked by ctest caret_suggest
// (viettelex-text-tool --self-test); here the real helper answers "predict" end to end when
// VIETTELEX_TEXT_TOOL is set.

#include "viettelex/auto_text.h"
#include "viettelex/caret_hints.h"
#include "viettelex/keys.h"
#include "viettelex/session.h"
#include "viettelex/settings.h"

#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <deque>
#include <functional>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

using namespace viettelex;
using namespace viettelex::autotext;
using Kind = CaretSuggestion::Kind;

static int g_fail = 0, g_pass = 0;
#define CHECK_EQ(a, b)                                                                         \
    do {                                                                                       \
        auto _a = (a);                                                                         \
        auto _b = (b);                                                                         \
        if (_a == _b) ++g_pass;                                                                \
        else {                                                                                 \
            ++g_fail;                                                                          \
            std::fprintf(stderr, "%s:%d: CHECK_EQ(%s, %s) failed\n", __FILE__, __LINE__, #a, #b); \
        }                                                                                      \
    } while (0)
#define CHECK(x) CHECK_EQ(bool(x), true)

namespace {

const uint32_t kRdq = 0x201d, kRsq = 0x2019;

std::string u8(uint32_t cp) {
    std::string o;
    if (cp < 0x80) o += char(cp);
    else if (cp < 0x800) { o += char(0xc0 | (cp >> 6)); o += char(0x80 | (cp & 0x3f)); }
    else { o += char(0xe0 | (cp >> 12)); o += char(0x80 | ((cp >> 6) & 0x3f)); o += char(0x80 | (cp & 0x3f)); }
    return o;
}

void popChars(std::string &s, int n) {
    while (n-- > 0 && !s.empty()) {
        size_t i = s.size() - 1;
        while (i > 0 && (static_cast<unsigned char>(s[i]) & 0xc0) == 0x80) --i;
        s.resize(i);
    }
}

struct Mock : InputContext {
    std::string doc, pre, shown, aux;
    std::string pred;  // the word prediction shown (showPrediction)
    bool surrounding = true, selection = false;
    int hides = 0;
    void setPreedit(const std::string &s, bool) override { pre = s; }
    void commit(const std::string &s) override { doc += s; }
    void deleteBeforeCursor(int n) override { popChars(doc, n); }
    bool textBeforeCursor(std::string &out) override {
        if (!surrounding) return false;
        out = doc;
        return true;
    }
    bool hasSelection() override { return selection; }
    void showHint(const std::string &l) override { shown = l; }
    void showPrediction(const std::string &w, const std::string &a) override {
        pred = w;
        aux = a;
    }
    void hideHint() override {
        shown.clear();
        pred.clear();
        aux.clear();
        ++hides;
    }
    // Direct mode (terminal): forwarded keys land in the document.
    void directReplace(int bs, const std::string &s) override {
        popChars(doc, bs);
        doc += s;
    }
};

int64_t g_now = 1000000;

// Press (and release unless `hold`). Returns whether the IM consumed the key; otherwise does
// what the app would (ASCII only).
bool press(Session &s, Mock &m, uint32_t keysym, uint32_t unicode, bool release = true) {
    KeyEvent ev;
    ev.keysym = keysym;
    ev.unicode = unicode;
    bool consumed = s.processKey(ev, m);
    if (release) {
        ev.release = true;
        s.processKey(ev, m);
    }
    if (consumed) return true;
    if (keysym == ks::BackSpace) popChars(m.doc, 1);
    else if (keysym == ks::Return) m.doc += "\n";
    else if (keysym == ks::Tab) m.doc += "\t";
    else if (unicode >= 0x20 && unicode < 0x7f) m.doc += char(unicode);
    return false;
}

// '<' BackSpace, '\n' Return, '\t' Tab, '~' Escape; 10 ms between keys.
void type(Session &s, Mock &m, const std::string &keys) {
    for (char c : keys) {
        g_now += 10;
        switch (c) {
        case '<': press(s, m, ks::BackSpace, 0); break;
        case '\n': press(s, m, ks::Return, '\r'); break;
        case '\t': press(s, m, ks::Tab, '\t'); break;
        case '~': press(s, m, ks::Escape, 0x1b); break;
        default: press(s, m, uint32_t((unsigned char)c), uint32_t((unsigned char)c));
        }
    }
}

struct Rig {
    Session s;
    Mock m;
    std::vector<HintRequest> reqs;
    Rig(Settings st, DisplayMode mode = DisplayMode::Preedit, bool edits = true, bool sink = true) {
        s.setClockForTesting([] { return g_now; });
        s.applySettings(st);
        s.setDisplayMode(mode, m);
        s.setSurroundingEdits(edits);
        if (sink) s.setHintSink([this](const HintRequest &r) { reqs.push_back(r); });
    }
    std::string last() const { return reqs.empty() ? std::string() : reqs.back().line; }
    void answer(const CaretSuggestion &c) { s.deliverHint(reqs.back().gen, c, m); }
};

Settings with(bool period, bool cap, bool smart, bool predict) {
    Settings s;
    s.mathResults = s.numberChips = s.typoHints = s.dateHints = false;
    s.doubleSpacePeriod = period;
    s.autoCapitalize = cap;
    s.smartPunctuation = smart;
    s.wordPrediction = predict;
    s.learnWords = false;  // "Học từ bạn gõ": its own tests (testLearnSession) turn it on
    return s;
}

std::string req(std::vector<std::string> f) { return hints::request(f); }

CaretSuggestion P(std::string d, std::string r) {
    CaretSuggestion c;
    c.kind = Kind::Predict;
    c.display = d;
    c.replace = std::move(r);
    c.insert = d + " ";
    return c;
}

// MARK: - pure rules (SystemAutoTextTests)

void testSettings() {
    Settings d;
    CHECK(!d.doubleSpacePeriod && !d.autoCapitalize && !d.smartPunctuation && !d.wordPrediction);  // all OFF
    CHECK_EQ(d.quoteStyle, std::string("curly"));
    CHECK(d.filterSensitive);  // "Lọc từ nhạy cảm": ON like iOS / macOS
    CHECK(!parseConfig("[general]\nfilter_sensitive = false\n").filterSensitive);
    CHECK(!parseConfig(serializeConfig(parseConfig("[general]\nfilter_sensitive = false\n"))).filterSensitive);
    Settings p = parseConfig("[general]\ndouble_space_period = true\nauto_capitalize = true\n"
                             "smart_punctuation = true\nword_prediction = true\nquote_style = \"guillemets\"\n");
    CHECK(p.doubleSpacePeriod && p.autoCapitalize && p.smartPunctuation && p.wordPrediction);
    CHECK_EQ(p.quoteStyle, std::string("guillemets"));
    CHECK_EQ(parseConfig("[general]\nquote_style = \"fancy\"\n").quoteStyle, std::string("curly"));
    CHECK(!parseConfig("[general]\nword_prediction = \"yes\"\n").wordPrediction);  // wrong type → default
    Settings rt = parseConfig(serializeConfig(p));
    CHECK(rt.doubleSpacePeriod && rt.autoCapitalize && rt.smartPunctuation && rt.wordPrediction);
    CHECK_EQ(rt.quoteStyle, std::string("guillemets"));
    CHECK(quotesFor("curly") == (Quotes{"“", "”", "‘", "’"}));
    CHECK(quotesFor("low9") == (Quotes{"„", "“", "‚", "‘"}));
    CHECK(quotesFor("guillemets") == (Quotes{"«", "»", "‹", "›"}));
}

void testExcludedApps() {
    for (const char *id : {"gnome-terminal-server", "org.gnome.Ptyxis", "konsole", "kitty", "code", "codium",
                           "cursor", "dev.zed.Zed", "sublime_text", "jetbrains-idea", "jetbrains-pycharm-ce",
                           "org.kde.kate", "com.visualstudio.code"})
        CHECK_EQ(appAllowed(id), false);
    for (const char *id : {"org.gnome.TextEditor", "gedit", "firefox", "google-chrome", "libreoffice-writer",
                           "thunderbird", "slack", "default", ""})
        CHECK_EQ(appAllowed(id), true);
}

void testDoubleSpaceRule() {
    uint32_t p = 0;
    CHECK(doubleSpacePeriod("xin chào ", 200, false, &p));
    CHECK_EQ(p, uint32_t('o'));
    CHECK(doubleSpacePeriod("việt ", 200, false, &p));
    CHECK_EQ(p, uint32_t('t'));
    CHECK(doubleSpacePeriod("năm 2026 ", 200, false, &p));
    CHECK_EQ(p, uint32_t('6'));
    CHECK(doubleSpacePeriod("(xem trên) ", 200, false, &p));
    CHECK_EQ(p, uint32_t(')'));
    CHECK(doubleSpacePeriod("“hay” ", 200, false, &p));
    CHECK_EQ(p, kRdq);
    CHECK(doubleSpacePeriod("Việt\xcc\x81 ", 200, false));  // NFD mark folded into its letter
    for (const char *b : {"hết. ", "hết, ", "hết! ", "hết? ", "hết: ", "hết; ", "a - ", "hết.  ", " ", ""})
        CHECK_EQ(doubleSpacePeriod(b, 100, false), false);
    CHECK_EQ(doubleSpacePeriod("chào", 100, false), false);  // no first space
    CHECK(doubleSpacePeriod("a ", kDoubleSpaceWindowMs, false));
    CHECK_EQ(doubleSpacePeriod("a ", kDoubleSpaceWindowMs + 1, false), false);
    CHECK_EQ(doubleSpacePeriod("a ", 30, true), false);  // held space
    CHECK_EQ(kDoubleSpaceWindowMs, int64_t(1100));
    CHECK_EQ(doubleSpacePeriod("chào. ", 100, false), false);  // after the replacement: no again
}

void testSmartQuoteRule() {
    Quotes q = quotesFor("curly");
    CHECK_EQ(smartQuote('"', 0, false, q), std::string("“"));  // start of the text
    CHECK_EQ(smartQuote('"', ' ', true, q), std::string("“"));
    CHECK_EQ(smartQuote('"', '(', true, q), std::string("“"));
    CHECK_EQ(smartQuote('"', '\n', true, q), std::string("“"));
    CHECK_EQ(smartQuote('"', 'o', true, q), std::string("”"));
    CHECK_EQ(smartQuote('"', '.', true, q), std::string("”"));
    CHECK_EQ(smartQuote('\'', 'n', true, q), std::string("’"));  // don't → don’t
    CHECK_EQ(smartQuote('\'', ' ', true, q), std::string("‘"));
    CHECK_EQ(smartQuote('\'', 0x201c, true, q), std::string("‘"));  // “‘lồng’”
    CHECK_EQ(smartQuote('"', 0x2018, true, q), std::string("“"));
    CHECK_EQ(smartQuote('"', 0x2014, true, q), std::string("“"));  // after an em dash
    CHECK_EQ(smartQuote('"', 0x1ec7, true, q), std::string("”"));  // after "ệ"
    CHECK(smartQuote('-', ' ', true, q).empty());
    Quotes g = quotesFor("guillemets");
    CHECK_EQ(smartQuote('"', ' ', true, g), std::string("«"));
    CHECK_EQ(smartQuote('"', 'a', true, g), std::string("»"));
    CHECK_EQ(smartQuote('\'', 0xab, true, g), std::string("‹"));  // inside « » opens
}

void testDashRule() {
    CHECK(dash("a-", false) == DashEdit::EmDash);
    CHECK(dash("a -", false) == DashEdit::EmDash);
    CHECK(dash("-", false) == DashEdit::EmDash);
    CHECK(dash("a", false) == DashEdit::None);
    CHECK(dash("a--", false) == DashEdit::None);  // already 3+ dashes
    CHECK(dash("<!-", false) == DashEdit::None);  // HTML comment
    CHECK(dash("a—", true) == DashEdit::Restore);  // "---" kept literally
    CHECK(dash("a—", false) == DashEdit::None);   // an existing "—" + "-"
}

void testCapitalizationRule() {
    auto cap = [](const char *b) {
        std::string s(b);
        return capitalization(&s, false);
    };
    CHECK(cap("Xong rồi. ") == CapContext::Capitalize);
    CHECK(cap("Thật sao? ") == CapContext::Capitalize);
    CHECK(cap("Hay quá! ") == CapContext::Capitalize);
    CHECK(cap("Anh nói “đi thôi.” ") == CapContext::Capitalize);
    CHECK(cap("dòng một\n") == CapContext::Capitalize);
    CHECK(cap("dòng một\n  ") == CapContext::Capitalize);
    CHECK(capitalization(nullptr, true) == CapContext::Capitalize);
    CHECK(cap("1. ") == CapContext::Capitalize);
    for (const char *b : {"xin ", "xin, ", "xin", "e.g. ", "Mr. ", "x etc. ", "ở TP. ", "gửi a@b.vn. ",
                          "xem viettelex.com. ", "J. ", "thế... ", "Đ/c ", "gặp Đ/c. "})
        CHECK(cap(b) == CapContext::Keep);
    CHECK(capitalization(nullptr, false) == CapContext::Unknown);
    CHECK(cap("") == CapContext::Unknown);
    CHECK(cap("  ") == CapContext::Unknown);
    CHECK_EQ(capitalized('d'), uint32_t('D'));
    CHECK_EQ(capitalized('D'), uint32_t('D'));
    CHECK_EQ(capitalized('1'), uint32_t('1'));
    CHECK_EQ(capitalized('['), uint32_t('['));
}

void testPredictionGates() {
    CHECK(predictionMuted("đươ", "đư"));
    CHECK(predictionMuted("Đư", "đư"));
    CHECK(!predictionMuted("đa", "đư"));
    CHECK(!predictionMuted("", "đư"));
    CHECK(!predictionMuted("đư", ""));
    CHECK(completionWorthAsking("đư"));
    CHECK(!completionWorthAsking("đ"));
    CHECK(!completionWorthAsking("a1"));
    CHECK(nextWordWorthAsking("cảm "));
    CHECK(!nextWordWorthAsking("hai  "));
    CHECK(!nextWordWorthAsking("xong. "));
    CHECK(!nextWordWorthAsking(" "));
    CHECK_EQ(kPredictIdleMs, 300);
    // Protocol: ONE predict candidate (no list); replace may be empty (next word).
    CaretSuggestion c;
    CHECK(hints::parseAnswer("predict\tđược\tđư\tđược ", c));
    CHECK(c == P("được", "đư"));
    CHECK(hints::parseAnswer("predict\tơn\t\tơn ", c));
    CHECK(c == P("ơn", ""));
    CHECK(!hints::parseAnswer("predict\tđược\tđư\tđược \tđường\tđưa", c));  // the old list form
    CHECK(!hints::parseAnswer("typo\ttôi\ttpoi \ttôi \tx", c));
    CHECK(!hints::parseAnswer("typo\ttôi\t\ttôi ", c));
    CHECK(hints::keyAction(Kind::Predict, ks::Tab, 0) == hints::KeyAction::Accept);
    CHECK(hints::keyAction(Kind::Predict, ks::Return, 0) == hints::KeyAction::DismissPass);  // never Enter
    CHECK(hints::keyAction(Kind::Predict, '1', 0) == hints::KeyAction::DismissPass);  // digits are digits
    CHECK(hints::keyAction(Kind::Predict, ks::Escape, 0) == hints::KeyAction::DismissConsume);
    CHECK(hints::keyAction(Kind::Predict, ks::Tab, VT_MOD_SHIFT) == hints::KeyAction::DismissPass);
}

// MARK: - Session: dấu chấm khi gõ hai dấu cách

void space(Rig &r, int gapMs, bool release = true) {
    g_now += gapMs;
    press(r.s, r.m, ' ', ' ', release);
}

void testDoubleSpaceSession() {
    for (DisplayMode mode : {DisplayMode::Preedit, DisplayMode::Surrounding}) {
        Rig r(with(true, false, false, false), mode);
        type(r.s, r.m, "xin chaof");
        space(r, 100);
        space(r, 200);
        CHECK_EQ(r.m.doc, std::string("xin chào. "));
        space(r, 200);  // a third space is just a space
        CHECK_EQ(r.m.doc, std::string("xin chào.  "));
    }
    // Too slow / held / after punctuation / off / not here.
    Rig slow(with(true, false, false, false));
    type(slow.s, slow.m, "chaof");
    space(slow, 10);
    space(slow, 1200);
    CHECK_EQ(slow.m.doc, std::string("chào  "));
    Rig held(with(true, false, false, false));
    type(held.s, held.m, "chaof");
    space(held, 10, false);
    space(held, 30, false);  // autorepeat: no release in between
    CHECK_EQ(held.m.doc, std::string("chào  "));
    Rig punct(with(true, false, false, false));
    type(punct.s, punct.m, "het,");
    space(punct, 10);
    space(punct, 100);
    CHECK_EQ(punct.m.doc, std::string("het,  "));
    Rig off(with(false, false, false, false));
    type(off.s, off.m, "chaof  ");
    CHECK_EQ(off.m.doc, std::string("chào  "));
    Rig code(with(true, false, false, false));
    code.s.setAutoTextAllowed(false);
    type(code.s, code.m, "x  ");
    CHECK_EQ(code.m.doc, std::string("x  "));
    // Chrome / Firefox (surrounding not proven, forced preedit): cannot replace committed text.
    Rig blind(with(true, false, false, false), DisplayMode::Preedit, false);
    type(blind.s, blind.m, "chaof  ");
    CHECK_EQ(blind.m.doc, std::string("chào  "));
    // The screen changed under us (app autocompleted): plain space.
    Rig moved(with(true, false, false, false));
    type(moved.s, moved.m, "chaof");
    space(moved, 10);
    moved.m.doc = "chàoX ";
    space(moved, 100);
    CHECK_EQ(moved.m.doc, std::string("chàoX  "));
    // Terminal (Direct): never.
    Rig term(with(true, false, false, false), DisplayMode::Direct, false);
    type(term.s, term.m, "ls  ");
    CHECK_EQ(term.m.doc, std::string("ls  "));
    // ⌫ right after deletes the inserted space, never re-opens the word.
    Rig bs(with(true, false, false, false));
    type(bs.s, bs.m, "chaof  <");
    CHECK_EQ(bs.m.doc, std::string("chào."));
}

// MARK: - viết hoa đầu câu

void testCapitalizeSession() {
    Rig r(with(false, true, false, false));
    r.m.doc = "Xong rồi. ";
    type(r.s, r.m, "dduwowcj ");
    CHECK_EQ(r.m.doc, std::string("Xong rồi. Được "));  // Telex still composes
    type(r.s, r.m, "vieejt nam. ddi\nhoc ");
    CHECK_EQ(r.m.doc, std::string("Xong rồi. Được việt nam. Đi\nHoc "));
    // Abbreviations / initials / "..." / mid-sentence: no capital.
    Rig k(with(false, true, false, false));
    k.m.doc = "Mr. ";
    type(k.s, k.m, "smith ");
    CHECK_EQ(k.m.doc, std::string("Mr. smith "));
    // ⌫ the auto capital: the next first letter stays lowercase (user declined).
    Rig d(with(false, true, false, false));
    d.m.doc = "Xong. ";
    type(d.s, d.m, "i");
    CHECK_EQ(d.m.pre, std::string("I"));
    type(d.s, d.m, "<iphone ");
    CHECK_EQ(d.m.doc, std::string("Xong. iphone "));
    // Start of the field: only multi-line fields (Fcitx5 Multiline).
    Rig one(with(false, true, false, false));
    type(one.s, one.m, "google ");
    CHECK_EQ(one.m.doc, std::string("google "));
    Rig multi(with(false, true, false, false));
    multi.s.setMultiline(true);
    type(multi.s, multi.m, "chaof ");
    CHECK_EQ(multi.m.doc, std::string("Chào "));
    // Surrounding (word typed in place).
    Rig sur(with(false, true, false, false), DisplayMode::Surrounding);
    sur.m.doc = "Hay quá! ";
    type(sur.s, sur.m, "vieejt");
    CHECK_EQ(sur.m.doc, std::string("Hay quá! Việt"));
    // Blind field (Chrome): nothing known before the first word; then the keys tell.
    Rig blind(with(false, true, false, false), DisplayMode::Preedit, false);
    blind.m.doc = "Xong. ";
    type(blind.s, blind.m, "xong. dduwowcj ");
    CHECK_EQ(blind.m.doc, std::string("Xong. xong. Được "));
    // Off, code editor, English mode, password: never.
    Rig off(with(false, false, false, false));
    off.m.doc = "Xong. ";
    type(off.s, off.m, "abc ");
    CHECK_EQ(off.m.doc, std::string("Xong. abc "));
    Rig code(with(false, true, false, false));
    code.s.setAutoTextAllowed(false);
    code.m.doc = "x. ";
    type(code.s, code.m, "abc ");
    CHECK_EQ(code.m.doc, std::string("x. abc "));
    Rig en(with(false, true, false, false));
    en.s.setVietnamese(false, en.m);
    en.m.doc = "x. ";
    type(en.s, en.m, "abc ");
    CHECK_EQ(en.m.doc, std::string("x. abc "));
    Rig pw(with(false, true, false, false));
    pw.s.setPassthrough(true, pw.m);
    pw.m.doc = "x. ";
    type(pw.s, pw.m, "abc ");
    CHECK_EQ(pw.m.doc, std::string("x. abc "));
    // Shift already: nothing to do; VNI digits untouched.
    Settings vni = with(false, true, false, false);
    vni.vni = true;
    Rig v(vni);
    v.m.doc = "Xong. ";
    type(v.s, v.m, "d9u7o7c5 ");
    CHECK_EQ(v.m.doc, std::string("Xong. Được "));
}

// MARK: - ngoặc kép cong + gạch dài

void testSmartPunctuationSession() {
    Rig r(with(false, false, true, false));
    type(r.s, r.m, "\"xin chaof\" don't 'a'");
    CHECK_EQ(r.m.doc, std::string("“xin chào” don’t ‘a’"));
    CHECK(r.m.pre.empty());
    // Blind field: the very first quote is unknown → left straight; after typed text it is known.
    Rig blind(with(false, false, true, false), DisplayMode::Preedit, false);
    type(blind.s, blind.m, "\"a \"b\"");
    CHECK_EQ(blind.m.doc, std::string("\"a “b”"));
    // Quote style.
    Settings g = with(false, false, true, false);
    g.quoteStyle = "low9";
    Rig low(g);
    type(low.s, low.m, "\"vieejt\"");
    CHECK_EQ(low.m.doc, std::string("„việt“"));
    // Dashes (surrounding proven): "--" → "—", one more "-" → "---", "<!--" kept.
    for (DisplayMode mode : {DisplayMode::Preedit, DisplayMode::Surrounding}) {
        Rig d(with(false, false, true, false), mode);
        type(d.s, d.m, "a--b");
        CHECK_EQ(d.m.doc + d.m.pre, std::string("a—b"));
        type(d.s, d.m, " ---");
        CHECK_EQ(d.m.doc, std::string("a—b ---"));
        type(d.s, d.m, "- x!--");
        CHECK_EQ(d.m.doc, std::string("a—b ---- x!--"));
    }
    // ⌫ after "—": the em dash goes (one character).
    Rig b(with(false, false, true, false));
    type(b.s, b.m, "x--<");
    CHECK_EQ(b.m.doc, std::string("x"));
    // Blind field: "--" stays (cannot replace committed text).
    Rig bd(with(false, false, true, false), DisplayMode::Preedit, false);
    type(bd.s, bd.m, "a--");
    CHECK_EQ(bd.m.doc, std::string("a--"));
    // Terminal / code editor / off.
    Rig t(with(false, false, true, false), DisplayMode::Direct, false);
    type(t.s, t.m, "echo \"x\" --help");
    CHECK_EQ(t.m.doc, std::string("echo \"x\" --help"));
    Rig c(with(false, false, true, false));
    c.s.setAutoTextAllowed(false);
    type(c.s, c.m, "\"x\" --");
    CHECK_EQ(c.m.doc, std::string("\"x\" --"));
    Rig off(with(false, false, false, false));
    type(off.s, off.m, "\"x\" --");
    CHECK_EQ(off.m.doc, std::string("\"x\" --"));
    // ⌫ right after a curly quote never re-opens the word before it.
    Rig q(with(false, false, true, false));
    type(q.s, q.m, "vieejt\"<");
    CHECK_EQ(q.m.doc, std::string("việt"));
}

// MARK: - gợi ý từ

void testPredictionSession() {
    // Completion while composing (Preedit: the word is the composition).
    Rig r(with(false, false, false, true));
    type(r.s, r.m, "tooi dduw");
    CHECK_EQ(r.last(), req({"predict", "tôi đư", "đư", "dduw", "0"}));
    CHECK_EQ(r.reqs.back().delayMs, kPredictIdleMs);
    r.answer(P("được", "đư"));
    CHECK(r.s.hint() != nullptr);
    CHECK_EQ(r.m.pred, std::string("được"));  // one suggestion
    CHECK_EQ(r.m.aux, std::string("Tab"));
    CHECK(press(r.s, r.m, ks::Tab, '\t'));
    CHECK_EQ(r.m.doc, std::string("tôi được "));
    CHECK(r.m.pre.empty());
    CHECK(r.m.pred.empty());
    CHECK_EQ(r.last(), req({"predict", "tôi được ", "", "", "0"}));  // next word offered
    // Next word: Tab inserts it.
    r.answer(P("không", ""));
    CHECK(press(r.s, r.m, ks::Tab, '\t'));
    CHECK_EQ(r.m.doc, std::string("tôi được không "));

    // Click on it (Fcitx5 CandidateWord::select / IBus candidate_clicked) = Tab.
    Rig c(with(false, false, false, true), DisplayMode::Surrounding);
    type(c.s, c.m, "dduw");
    c.answer(P("được", "đư"));
    CHECK(c.s.chooseHint(c.m));
    CHECK_EQ(c.m.doc, std::string("được "));
    CHECK(!c.s.chooseHint(c.m));  // nothing shown any more

    // Any other key dismisses and goes on; digits are typed, never select.
    Rig k(with(false, false, false, true));
    type(k.s, k.m, "dduw");
    k.answer(P("được", "đư"));
    type(k.s, k.m, "1");
    CHECK_EQ(k.m.doc, std::string("đư1"));
    CHECK(!k.s.hint());
    CHECK(k.m.pred.empty());

    // Esc: hidden, not offered again while the word starts with what was declined.
    Rig e(with(false, false, false, true));
    type(e.s, e.m, "dduw");
    e.answer(P("được", "đư"));
    CHECK(press(e.s, e.m, ks::Escape, 0x1b));
    size_t n = e.reqs.size();
    type(e.s, e.m, "ow");
    CHECK_EQ(e.reqs.size(), n);
    type(e.s, e.m, " ddu");  // next word: offered again
    CHECK_EQ(e.last(), req({"predict", "đươ đu", "đu", "ddu", "0"}));

    // Typing on before the answer: stale (generation moved on).
    Rig g(with(false, false, false, true));
    type(g.s, g.m, "dduw");
    uint64_t gen = g.reqs.back().gen;
    type(g.s, g.m, "o");
    g.s.deliverHint(gen, P("được", "đư"), g.m);
    CHECK(!g.s.hint());
    // The word changed under the answer: not shown.
    Rig w(with(false, false, false, true));
    type(w.s, w.m, "dduw");
    w.answer(P("đang", "đa"));
    CHECK(!w.s.hint());

    // Other caret suggestions win: the next word is only a fallback of the typo request.
    Settings both = with(false, false, false, true);
    both.typoHints = true;
    Rig o(both);
    type(o.s, o.m, "anh tpoi ");
    CHECK_EQ(o.last(), req({"typo", "anh tpoi ", "tpoi", " ", "tpoi", "10100001100"}));
    CHECK_EQ(o.reqs.back().fallback, req({"predict", "anh tpoi ", "", "", "0"}));
    CHECK_EQ(o.reqs.back().fallbackDelayMs, kPredictIdleMs);
    CaretSuggestion typo;
    typo.kind = Kind::Typo;
    typo.display = "tôi";
    typo.replace = "tpoi ";
    typo.insert = "tôi ";
    o.answer(typo);
    o.s.deliverHint(o.reqs.back().gen, P("ơi", ""), o.m);  // late prediction: ignored
    CHECK(o.s.hint() && o.s.hint()->kind == Kind::Typo);
    // …and replace a prediction already shown.
    Rig o2(both);
    type(o2.s, o2.m, "camr ");
    o2.answer(P("ơn", ""));
    CHECK(!o2.m.pred.empty());
    CaretSuggestion date;
    date.kind = Kind::Date;
    date.display = "x";
    date.replace = "cảm ";
    date.insert = "x ";
    o2.answer(date);
    CHECK(o2.s.hint()->kind == Kind::Date);
    CHECK(o2.m.pred.empty());
    CHECK(!o2.m.shown.empty());

    // Blind field (Chrome): completion in the preedit; the text before what was typed since the
    // focus is unknown and NOT marked for prediction (the first word is taken to stand alone).
    Rig b(with(false, false, false, true), DisplayMode::Preedit, false);
    type(b.s, b.m, "camr ");
    CHECK_EQ(b.last(), req({"predict", "cảm ", "", "", "0"}));
    type(b.s, b.m, "xin ch");
    CHECK_EQ(b.last(), req({"predict", "cảm xin ch", "ch", "ch", "0"}));
    CHECK_EQ(b.s.typedBefore(), std::string("\xef\xbf\xbc") + "cảm xin ");  // other hints: still marked
    // English context: the engine's previous-word flag goes along.
    Rig en(with(false, false, false, true));
    type(en.s, en.m, "you beca");
    CHECK_EQ(en.last(), req({"predict", "you beca", "beca", "beca", "1"}));

    // Off / no helper / terminal / code editor / password / English mode / distrusted.
    Rig off(with(false, false, false, false));
    type(off.s, off.m, "tooi dduw cam ");
    CHECK(off.reqs.empty());
    CHECK_EQ(off.s.typedBefore(), std::string("\xef\xbf\xbc"));  // nothing tracked at all
    Rig term(with(false, false, false, true), DisplayMode::Direct, false);
    type(term.s, term.m, "git commit ");
    CHECK(term.reqs.empty());
    Rig code(with(false, false, false, true));
    code.s.setAutoTextAllowed(false);
    type(code.s, code.m, "return valu");
    CHECK(code.reqs.empty());
    Rig pw(with(false, false, false, true));
    pw.s.setPassthrough(true, pw.m);
    type(pw.s, pw.m, "secret word");
    CHECK(pw.reqs.empty());
    Rig eng(with(false, false, false, true));
    eng.s.setVietnamese(false, eng.m);
    type(eng.s, eng.m, "hello wor");
    CHECK(eng.reqs.empty());
    Rig sur(with(false, false, false, true), DisplayMode::Surrounding, false);
    type(sur.s, sur.m, "dduw");
    CHECK(sur.reqs.empty());  // Surrounding without edits: cannot replace the word on screen
}

// MARK: - Học từ bạn gõ (LearnedModel.swift / LearnStore.swift in the helper)

std::vector<std::string> learnLines(const Rig &r) {
    std::vector<std::string> out;
    for (const auto &q : r.reqs)
        if (q.oneway) out.push_back(q.line);
    return out;
}
std::string L(std::string w, std::string p1 = "", std::string p2 = "", int weight = 1) {
    return req({"learn", w, p1, p2, std::to_string(weight)});
}

void testLearnTracker() {
    hints::LearnTracker t;
    hints::LearnTracker::Event e;
    CHECK(!t.commit("Ăn", ' ', true, 1, e));
    CHECK(t.hasPending() && t.pending().word == "ăn");
    CHECK_EQ(t.pending().form, std::string("Ăn"));  // casing kept for the learned-casing table
    CHECK_EQ(hints::learnRequest(t.pending()), L("Ăn"));
    CHECK(t.commit("cơm", ',', true, 1, e) && e.word == "ăn" && e.prev1.empty());
    CHECK(t.prev1().empty());  // punctuation cuts the context
    CHECK(t.commit("rồi", ' ', true, 1, e) && e.word == "cơm" && e.prev1 == "ăn");
    t.discard();
    CHECK(!t.hasPending() && !t.breakContext(e));
    CHECK(!t.commit("đi", ' ', true, 1, e));
    CHECK(t.commit("x1", ' ', true, 1, e) && e.word == "đi");
    CHECK(!t.hasPending());
    CHECK(!t.commit("học", ' ', false, 1, e) && !t.hasPending());
    // typo fix: the fixed form, same context
    hints::LearnTracker f;
    f.commit("tôi", ' ', true, 1, e);
    f.commit("dii", ' ', true, 1, e);
    f.replacePending("đi");
    CHECK(f.pending().word == "đi" && f.pending().prev1 == "tôi" && f.pending().form == "đi");
    CHECK(f.commit("học", ' ', true, 1, e) && e.word == "đi");
    CHECK_EQ(f.pending().prev1, std::string("đi"));
    // = LearnedModel.learnable
    CHECK(hints::learnable("cơm") && hints::learnable("Phúc") && hints::learnable("heey"));
    CHECK(!hints::learnable("heeey") && !hints::learnable("a1") && !hints::learnable(""));
    CHECK(hints::learnable("abcdefghijkl") && !hints::learnable("abcdefghijklm") && !hints::learnable("e-mail"));
}

void testLearnSession() {
    Settings on = with(false, false, false, true);
    on.learnWords = true;
    // Words this Session composed, with the 2 previous words of the same sentence; each held
    // until the next event (Enter makes the last one final).
    Rig r(on);
    type(r.s, r.m, "awn cowm awn cowm\n");
    const std::vector<std::string> want = {L("ăn"), L("cơm", "ăn"), L("ăn", "cơm", "ăn"), L("cơm", "ăn", "cơm")};
    CHECK(learnLines(r) == want);
    // Predict requests say the learned data may be used (filter + learn fields).
    Rig p(on);
    type(p.s, p.m, "tooi dduw");
    CHECK_EQ(p.last(), req({"predict", "tôi đư", "đư", "dduw", "0", "1", "1"}));
    type(p.s, p.m, " ");
    bool sawNext = false;
    for (const auto &q : p.reqs) sawNext = sawNext || q.line == req({"predict", "tôi được ", "", "", "0", "1", "1"}) ||
                                           q.line == req({"predict", "tôi đư ", "", "", "0", "1", "1"});
    CHECK(sawNext);

    // Gates: switch off / prediction off / terminal / code editor / password / English.
    Settings noLearn = on;
    noLearn.learnWords = false;
    Settings noPredict = on;
    noPredict.wordPrediction = false;
    for (const Settings &st : {noLearn, noPredict}) {
        Rig g(st);
        type(g.s, g.m, "awn cowm\n");
        CHECK(learnLines(g).empty());
    }
    Rig term(on, DisplayMode::Direct, false);
    type(term.s, term.m, "awn cowm\n");
    CHECK(learnLines(term).empty());
    Rig code(on);
    code.s.setAutoTextAllowed(false);
    type(code.s, code.m, "awn cowm\n");
    CHECK(learnLines(code).empty());
    Rig pw(on);
    pw.s.setPassthrough(true, pw.m);
    type(pw.s, pw.m, "secret word\n");
    CHECK(learnLines(pw).empty());
    Rig eng(on);
    eng.s.setVietnamese(false, eng.m);
    type(eng.s, eng.m, "hello world\n");
    CHECK(learnLines(eng).empty());
    Rig nosink(on, DisplayMode::Preedit, true, false);
    type(nosink.s, nosink.m, "awn cowm\n");  // no helper: nothing (and nothing crashes)

    // ⌫ right after the boundary: the held word may be edited — dropped.
    // (⌫ may re-open the word into the composition — re-edit; committing it again at a later
    // boundary learns it then, once. Here focus leaves while it is open: nothing more.)
    Rig bs(on);
    type(bs.s, bs.m, "awn cowm <");
    bs.s.finish(bs.m);
    CHECK(learnLines(bs) == std::vector<std::string>{L("ăn")});
    // Comma cuts the sentence context.
    Rig cm(on);
    type(cm.s, cm.m, "awn, cowm\n");
    CHECK(learnLines(cm) == (std::vector<std::string>{L("ăn"), L("cơm")}));
    // Shortcut expansion / digits: not ours — nothing learned, context cut.
    Rig dg(on);
    type(dg.s, dg.m, "awn 123 cowm\n");
    CHECK(learnLines(dg) == (std::vector<std::string>{L("ăn"), L("cơm")}));
    // Accepted typo fix: the fixed form.
    Settings ty = on;
    ty.typoHints = true;
    Rig tf(ty);
    type(tf.s, tf.m, "anh tpoi ");
    CaretSuggestion typo;
    typo.kind = Kind::Typo;
    typo.display = "tôi";
    typo.replace = "tpoi ";
    typo.insert = "tôi ";
    tf.s.deliverHint(tf.reqs.back().gen, typo, tf.m);
    CHECK(press(tf.s, tf.m, ks::Tab, '\t'));
    type(tf.s, tf.m, "\n");
    CHECK(learnLines(tf) == (std::vector<std::string>{L("anh"), L("tôi", "anh")}));
    // Accepted prediction: weight 2.
    Rig ap(on);
    type(ap.s, ap.m, "tooi dduw");
    ap.answer(P("được", "đư"));
    CHECK(press(ap.s, ap.m, ks::Tab, '\t'));
    type(ap.s, ap.m, "\n");
    CHECK(learnLines(ap) == (std::vector<std::string>{L("tôi"), L("được", "tôi", "", 2)}));
    // Focus out (finish): the held word is final.
    Rig fo(on);
    type(fo.s, fo.m, "awn ");
    fo.s.finish(fo.m);
    CHECK(learnLines(fo) == std::vector<std::string>{L("ăn")});
}

// Tab on a prediction inserts "word␣"; the very next key . , ? ! ; : ) attaches to the word and
// the space moves after it, the space after that is swallowed (WordPrediction.swift
// acceptSpaceReplacement — ControllerHarnessTests on macOS).
void testAcceptedSpaceSession() {
    CHECK_EQ(acceptSpaceReplacement('.'), std::string(". "));
    CHECK_EQ(acceptSpaceReplacement(','), std::string(", "));
    CHECK_EQ(acceptSpaceReplacement(')'), std::string(") "));
    CHECK_EQ(acceptSpaceReplacement(0x201D), std::string("\xe2\x80\x9d "));
    CHECK_EQ(acceptSpaceReplacement('/'), std::string("/"));
    CHECK(acceptSpaceReplacement('"').empty() && acceptSpaceReplacement('a').empty() &&
          acceptSpaceReplacement(' ').empty() && acceptSpaceReplacement('(').empty());
    auto accepted = [](Settings st) {
        auto r = std::make_unique<Rig>(st, DisplayMode::Surrounding);
        type(r->s, r->m, "dduw");
        r->answer(P("được", "đư"));
        CHECK(press(r->s, r->m, ks::Tab, '\t'));
        CHECK_EQ(r->m.doc, std::string("được "));
        return r;
    };
    auto a = accepted(with(false, true, false, true));
    type(a->s, a->m, ".");
    CHECK_EQ(a->m.doc, std::string("được. "));
    type(a->s, a->m, " ");
    CHECK_EQ(a->m.doc, std::string("được. "));  // not two spaces
    type(a->s, a->m, "ban");
    CHECK_EQ(a->m.doc, std::string("được. Ban"));  // auto-capitalize after the moved period
    auto b = accepted(with(false, false, false, true));
    type(b->s, b->m, ",ok");
    CHECK_EQ(b->m.doc, std::string("được, ok"));
    auto c = accepted(with(false, false, false, true));
    type(c->s, c->m, "a.");
    CHECK_EQ(c->m.doc, std::string("được a."));  // only the very next key
    auto d = accepted(with(false, false, false, true));
    type(d->s, d->m, "/");
    CHECK_EQ(d->m.doc, std::string("được/"));
    auto e = accepted(with(true, false, false, true));
    type(e->s, e->m, " ");
    CHECK_EQ(e->m.doc, std::string("được. "));  // our space = the first of a double-space period
    auto f = accepted(with(false, false, false, true));
    f->m.doc += "x";  // the app changed the text: read back, untouched
    type(f->s, f->m, ".");
    CHECK_EQ(f->m.doc, std::string("được x."));
    // "Lọc từ nhạy cảm" off: sent to the helper (absent = on).
    Settings off = with(false, false, false, true);
    off.filterSensitive = false;
    Rig o(off);
    type(o.s, o.m, "dduw");
    CHECK_EQ(o.last(), req({"predict", "đư", "đư", "dduw", "0", "0"}));
}

// MARK: - real helper (viettelex-text-tool --serve)

void testHelperEndToEnd() {
    const char *tool = std::getenv("VIETTELEX_TEXT_TOOL");
    if (!tool || !*tool) {
        std::printf("(skip helper: VIETTELEX_TEXT_TOOL unset)\n");
        return;
    }
    std::mutex mu;
    std::deque<std::function<void()>> mainQueue;
    HintService svc([&](std::function<void()> f) {
        std::lock_guard<std::mutex> l(mu);
        mainQueue.push_back(std::move(f));
    });
    std::string ans;
    // Next word: a trigram row for two context words, or an iOS seed pair for one ("cảm " ->
    // ơn); no statistical one-word guess ("Tên " -> nothing, Phil 16/10/2026).
    CHECK(svc.query(req({"predict", "Tên ", "", "", "0"}), ans));
    CHECK_EQ(ans, std::string("-"));
    CHECK(svc.query(req({"predict", "cảm ", "", "", "0"}), ans));
    CHECK_EQ(ans, std::string("predict\tơn\t\tơn "));
    CHECK(svc.query(req({"predict", "vãi ", "", "", "0", "0"}), ans));  // filter off
    CHECK_EQ(ans, std::string("predict\tlồn\t\tlồn "));
    CHECK(svc.query(req({"predict", "vãi ", "", "", "0"}), ans));
    CHECK_EQ(ans, std::string("predict\tcả\t\tcả "));
    CHECK(svc.query(req({"typo", "spellnig ", "spellnig", " ", "spellnig", "1010000110"}), ans));
    CHECK_EQ(ans, std::string("typo\tspelling\tspellnig \tspelling "));
    CHECK(svc.query(req({"predict", "thành phố hồ ", "", "", "0"}), ans));
    CHECK_EQ(ans, std::string("predict\tChí\t\tChí "));
    CHECK(svc.query(req({"predict", "xin ch", "ch", "ch", "0"}), ans));
    CaretSuggestion c;
    CHECK(hints::parseAnswer(ans, c));
    CHECK(c == P("chào", "ch"));  // one suggestion: the top-ranked word
    CHECK(svc.query(req({"predict", "abc.đư", "đư", "dduw", "0"}), ans));
    CHECK_EQ(ans, std::string("-"));
    // Học từ bạn gõ: "learn" lines, then predict with learn = 1 (store in a temp file: main()
    // sets VIETTELEX_LEARN_FILE before the helper starts).
    CHECK(svc.query(L("tôi", "tên"), ans));
    CHECK_EQ(ans, std::string("ok"));
    CHECK(svc.query(L("tôi", "tên"), ans));
    CHECK(svc.query(req({"predict", "Tên ", "", "", "0", "1", "1"}), ans));
    CHECK_EQ(ans, std::string("predict\ttôi\t\ttôi "));
    CHECK(svc.query(req({"predict", "Tên ", "", "", "0", "1"}), ans));
    CHECK_EQ(ans, std::string("-"));  // learn off: not used
    CHECK(svc.query("learnclear", ans));
    CHECK(svc.query(req({"predict", "Tên ", "", "", "0", "1", "1"}), ans));
    CHECK_EQ(ans, std::string("-"));
    // One-way lines (Session learning) are never superseded by the next request.
    HintRequest lr;
    lr.oneway = true;
    lr.line = L("tôi", "tên");
    svc.submit(lr, nullptr);
    svc.submit(lr, nullptr);

    auto drain = [&](int ms) {
        auto until = std::chrono::steady_clock::now() + std::chrono::milliseconds(ms);
        while (std::chrono::steady_clock::now() < until) {
            std::function<void()> f;
            {
                std::lock_guard<std::mutex> l(mu);
                if (!mainQueue.empty()) {
                    f = std::move(mainQueue.front());
                    mainQueue.pop_front();
                }
            }
            if (f) f();
            else std::this_thread::sleep_for(std::chrono::milliseconds(5));
        }
    };
    // Session → HintService (300 ms idle) → helper → candidates → Tab.
    Session s;
    Mock m;
    s.applySettings(with(false, false, false, true));
    s.setSurroundingEdits(true);
    s.setHintSink([&](const HintRequest &r) {
        uint64_t gen = r.gen;
        svc.submit(r, [&, gen](bool ok, const CaretSuggestion &cs) {
            if (ok) s.deliverHint(gen, cs, m);
        });
    });
    type(s, m, "teen ");
    drain(1500);
    CHECK(!s.hint());  // "Tên ": one context word, no seed: no guess
    type(s, m, "camr own ");
    drain(150);
    CHECK(!s.hint());  // still inside the 300 ms pause
    drain(1500);
    CHECK(s.hint() != nullptr);
    CHECK(!m.pred.empty());
    const std::string word = m.pred;
    CHECK(press(s, m, ks::Tab, '\t'));
    CHECK_EQ(m.doc, "tên cảm ơn " + word + " ");
    // The typo request falls back to the prediction when there is no typo fix.
    std::atomic<int> got{0};
    CaretSuggestion fb;
    auto gen = std::make_shared<std::atomic<uint64_t>>(7);
    HintRequest r;
    r.line = req({"number", "hello "});  // no answer
    r.fallback = req({"predict", "xin chào ", "", "", "0"});
    r.fallbackDelayMs = 100;
    r.gen = 7;
    r.liveGen = gen;
    svc.submit(r, [&](bool, const CaretSuggestion &cs) {
        fb = cs;
        ++got;
    });
    drain(1500);
    CHECK_EQ(got.load(), 1);
    CHECK(fb.kind == Kind::Predict);
}

}  // namespace

// MARK: - tên miền email (iOS/Android EmailDomains; same cases as macOS / Windows)

EmailDomain ED(std::string d, std::string r, std::string i) { return EmailDomain{d, r, i}; }

bool email(const std::string &before, EmailDomain &out, const std::string &typed = "", const std::string &raw = "") {
    out = EmailDomain();
    return emailDomainSuggestion(before, typed, raw, out);
}

void testEmailDomainRule() {
    EmailDomain d;
    CHECK(email("user@", d));
    CHECK_EQ(d, ED("gmail.com", "", "gmail.com"));  // gmail first, '@' never repeated
    CHECK(email("user@ic", d, "ic", "ic"));
    CHECK_EQ(d, ED("icloud.com", "", "loud.com"));
    CHECK(email("user@gm", d, "gm", "gm"));
    CHECK_EQ(d, ED("gmail.com", "", "ail.com"));
    CHECK(email("user@gm", d));  // committed (not composing): same
    CHECK_EQ(d, ED("gmail.com", "", "ail.com"));
    CHECK(email("user@GM", d, "GM", "GM"));  // any case; only the missing part
    CHECK_EQ(d, ED("gmail.com", "", "ail.com"));
    CHECK(email("user@gmail.", d));
    CHECK_EQ(d, ED("gmail.com", "", "com"));
    CHECK(email("user@gmail.c", d, "c", "c"));
    CHECK_EQ(d, ED("gmail.com", "", "om"));
    CHECK(email("user@o", d, "o", "o"));
    CHECK_EQ(d, ED("outlook.com", "", "utlook.com"));
    CHECK(email("user@y", d, "y", "y"));
    CHECK_EQ(d, ED("yahoo.com", "", "ahoo.com"));
    CHECK(!email("user@gmail.com", d));  // already whole
    CHECK(!email("user@gmail.com", d, "com", "com"));
    CHECK(!email("user@x", d, "x", "x"));  // no provider
    CHECK(!email("user@gmx", d));
    CHECK(!email("@", d));                 // no local part
    CHECK(!email("hello @", d));
    CHECK(!email("ph\xc3\xba" "c@", d));  // "phúc@": not an address
    CHECK(email("hello user@", d));
    CHECK_EQ(d.display, std::string("gmail.com"));
    CHECK(email("<user@", d));
    CHECK(email("to: a.b_c%d+e-f@", d));
    CHECK(email("x,user@", d));
    CHECK(email("x\xc2\xa0user@", d));     // NBSP
    CHECK(!email("x@y@", d));              // two '@'
    CHECK(!email("a/b@", d));
    CHECK(!email("\xef\xbf\xbcuser@", d)); // unknown text before (U+FFFC): maybe "phúc@"
    CHECK(!email("user@g m", d));
    CHECK(!email("user", d));
    CHECK(!email("user@gm", d, "xx", "xx"));  // the composing word is not what ends the text
    // Telex changed the composing word: "yahoo" shows "yahô" — replace it, not append.
    CHECK(email("user@yah\xc3\xb4", d, "yah\xc3\xb4", "yahoo"));
    CHECK_EQ(d, ED("yahoo.com", "yah\xc3\xb4", "yahoo.com"));
    CHECK(!email("user@yahoo.c\xc3\xb4", d, "c\xc3\xb4", "coo"));  // "yahoo.coo": no provider
    CHECK(email("user@outl\xc3\xb4", d, "outl\xc3\xb4", "outloo"));
    CHECK_EQ(d, ED("outlook.com", "outl\xc3\xb4", "outlook.com"));
    CHECK(!email("user@gmail.\xc3\xb4", d, "\xc3\xb4", "oo"));  // "gmail.oo": no provider
    // Cheap gate.
    CHECK(emailWorthChecking("user@"));
    CHECK(emailWorthChecking("hello user@gmail."));
    CHECK(!emailWorthChecking("hello user"));
    CHECK(!emailWorthChecking("@ and then a long text"));
}

void testEmailDomainSession() {
    // Preedit: '@' → gmail.com at once (no helper round-trip); Tab inserts it raw.
    Rig r(with(false, false, false, true));
    type(r.s, r.m, "abc@");
    CHECK_EQ(r.m.doc, std::string("abc@"));
    CHECK(r.s.hint() != nullptr);
    CHECK(r.s.hint()->kind == Kind::Email);
    CHECK_EQ(r.m.pred, std::string("gmail.com"));
    CHECK_EQ(r.m.aux, std::string("Tab"));
    CHECK(press(r.s, r.m, ks::Tab, '\t'));
    CHECK_EQ(r.m.doc, std::string("abc@gmail.com"));  // no space, no '@' twice
    CHECK(r.m.pred.empty());
    CHECK(!r.s.hint());
    CHECK(!r.s.composing());
    // Typed on after it: a new word, nothing re-toned with the domain.
    type(r.s, r.m, " ok");
    CHECK_EQ(r.m.doc + r.m.pre, std::string("abc@gmail.com ok"));

    // While composing after '@' ("ic" in the preedit): only the missing part follows the word.
    Rig c(with(false, false, false, true));
    type(c.s, c.m, "abc@ic");
    CHECK_EQ(c.m.pred, std::string("icloud.com"));
    CHECK(press(c.s, c.m, ks::Tab, '\t'));
    CHECK_EQ(c.m.doc, std::string("abc@icloud.com"));
    CHECK(c.m.pre.empty());
    CHECK(!c.s.composing());
    // ⌫ right after does not re-open "icloud" as a Telex word: plain delete.
    type(c.s, c.m, "<");
    CHECK_EQ(c.m.doc + c.m.pre, std::string("abc@icloud.co"));

    // Surrounding (in place) + click (= Tab).
    Rig s(with(false, false, false, true), DisplayMode::Surrounding);
    type(s.s, s.m, "abc@gm");
    CHECK_EQ(s.m.pred, std::string("gmail.com"));
    CHECK(s.s.chooseHint(s.m));
    CHECK_EQ(s.m.doc, std::string("abc@gmail.com"));
    CHECK(!s.s.chooseHint(s.m));

    // '.' inside the domain: "gmail." → "com".
    Rig dot(with(false, false, false, true));
    type(dot.s, dot.m, "abc@gmail.");
    CHECK_EQ(dot.m.pred, std::string("gmail.com"));
    CHECK(press(dot.s, dot.m, ks::Tab, '\t'));
    CHECK_EQ(dot.m.doc, std::string("abc@gmail.com"));

    // Whole domain typed / no provider / not an address: nothing; no helper request either.
    Rig w(with(false, false, false, true));
    type(w.s, w.m, "abc@gmail.com");
    CHECK(!w.s.hint());
    type(w.s, w.m, " abc@zz");
    CHECK(!w.s.hint());
    type(w.s, w.m, " @");
    CHECK(!w.s.hint());

    // Esc: not again for this address; a new '@' offers again.
    Rig e(with(false, false, false, true));
    type(e.s, e.m, "abc@~");
    CHECK(!e.s.hint());
    type(e.s, e.m, "g");
    CHECK(!e.s.hint());
    CHECK(e.m.pred.empty());
    type(e.s, e.m, " xyz@");
    CHECK(e.s.hint() != nullptr);

    // Any other key dismisses and goes on; Enter is never taken.
    Rig k(with(false, false, false, true));
    type(k.s, k.m, "abc@\n");
    CHECK_EQ(k.m.doc, std::string("abc@\n"));
    CHECK(!k.s.hint());

    // word_prediction off: nothing at all.
    Rig off(with(false, false, false, false));
    type(off.s, off.m, "abc@gm");
    CHECK(!off.s.hint());
    CHECK(off.m.pred.empty());
    CHECK(off.reqs.empty());
    // Terminal / code editor (frontends: setEmailDomainsAllowed(false)): nothing.
    Rig t(with(false, false, false, true));
    t.s.setEmailDomainsAllowed(false);
    type(t.s, t.m, "abc@");
    CHECK(!t.s.hint());
    // E-mail field (auto text off there): the domain is still offered.
    Rig f(with(false, false, false, true));
    f.s.setAutoTextAllowed(false);
    type(f.s, f.m, "abc@");
    CHECK_EQ(f.m.pred, std::string("gmail.com"));
    // Direct (terminal mode): never.
    Rig d(with(false, false, false, true), DisplayMode::Direct);
    type(d.s, d.m, "abc@");
    CHECK(!d.s.hint());
    // Text before the caret unknown (not readable): the local part is not seen whole — nothing.
    Rig u(with(false, false, false, true));
    u.m.surrounding = false;
    type(u.s, u.m, "abc@");
    CHECK(!u.s.hint());
    type(u.s, u.m, " abc@");  // …but after a space typed here it is
    CHECK_EQ(u.m.pred, std::string("gmail.com"));
}

int main() {
    // The helper's learned-words store: a temp file, never ~/.local/share/viettelex.
    char learnTmpl[] = "/tmp/vt-learn-XXXXXX";
    if (char *d = mkdtemp(learnTmpl)) setenv("VIETTELEX_LEARN_FILE", (std::string(d) + "/learned-words.bin").c_str(), 1);
    testSettings();
    testExcludedApps();
    testDoubleSpaceRule();
    testSmartQuoteRule();
    testDashRule();
    testCapitalizationRule();
    testPredictionGates();
    testDoubleSpaceSession();
    testCapitalizeSession();
    testSmartPunctuationSession();
    testPredictionSession();
    testAcceptedSpaceSession();
    testEmailDomainRule();
    testEmailDomainSession();
    testLearnTracker();
    testLearnSession();
    testHelperEndToEnd();
    std::printf("auto text tests: %d passed, %d failed\n", g_pass, g_fail);
    return g_fail ? 1 : 0;
}
