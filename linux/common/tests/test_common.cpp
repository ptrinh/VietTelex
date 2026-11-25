// test_common — unit tests for linux/common: Session (with a mock InputContext),
// settings/shortcuts/hotkey parsing, app policy, app-state store.
// Links the real libtelexcore, so these are end-to-end through the C ABI.

#include "viettelex/app.h"
#include "viettelex/dead_keys.h"
#include "viettelex/gnome.h"
#include "viettelex/keys.h"
#include "viettelex/retro_english.h"
#include "viettelex/session.h"
#include "viettelex/settings.h"
#include "viettelex/surrounding_cache.h"
#include "viettelex/text_tools.h"
#include "viettelex/watcher.h"

#include <telexcore.h>
#include <glib.h>

#include <cstdio>
#include <cstdlib>
#include <functional>
#include <mutex>
#include <random>
#include <string>
#include <sys/stat.h>
#include <unistd.h>
#include <vector>

using namespace viettelex;

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

void popChars(std::string &s, int n) {
    while (n-- > 0 && !s.empty()) {
        size_t i = s.size() - 1;
        while (i > 0 && (static_cast<unsigned char>(s[i]) & 0xc0) == 0x80) --i;
        s.resize(i);
    }
}

// A client: `doc` is the text before the caret; the preedit sits at the caret.
struct Mock : InputContext {
    std::string doc, pre;
    bool surrounding = true;
    bool selection = false;
    int deletes = 0, preeditUpdates = 0;
    std::vector<std::string> log;  // "pre:x" / "commit:x" / "del:n", in call order
    bool misspelled = false;  // style of the current preedit
    int misspelledShows = 0;  // setPreedit calls that asked for the error style
    void setPreedit(const std::string &s, bool bad) override {
        pre = s;
        misspelled = bad;
        if (bad) ++misspelledShows;
        ++preeditUpdates;
        log.push_back("pre:" + s);
    }
    // Draft.js-like host: every commit lands twice.
    bool dup = false;
    void commit(const std::string &s) override {
        doc += s;
        if (dup) doc += s;
        log.push_back("commit:" + s);
    }
    // Stale / lying host: textBeforeCursor reports `reported` instead of `doc`.
    bool hasReported = false;
    std::string reported;
    // GNOME Wayland's check (mutter g_assert): a delete reaching past the start of the last
    // report would abort the shell. Counted here instead.
    int overDeletes = 0;
    void deleteBeforeCursor(int n) override {
        ++deletes;
        long r = reportedCharsBeforeCursor();
        if (r >= 0 && long(n) > r) ++overDeletes;
        popChars(doc, n);
        log.push_back("del:" + std::to_string(n));
    }
    bool textBeforeCursor(std::string &out) override {
        if (!surrounding) return false;
        out = hasReported ? reported : doc;
        return true;
    }
    long reportedCharsBeforeCursor() override {
        if (!surrounding) return -1;
        long n = 0;
        for (unsigned char c : hasReported ? reported : doc) n += (c & 0xc0) != 0x80;
        return n;
    }
    bool hasSelection() override { return selection; }
    // GTK3: the cheap check sees nothing, only the thorough one (PRIMARY at the caret) does.
    bool primarySelection = false;
    int thoroughAsks = 0;
    bool selectionAtCaret() override {
        ++thoroughAsks;
        return selection || primarySelection;
    }
    std::string screen() const { return doc + pre; }
    // Caret suggestion (aux text) currently shown; "" = none.
    std::string hintShown;
    int hintShows = 0;
    void showHint(const std::string &label) override {
        hintShown = label;
        ++hintShows;
    }
    void hideHint() override { hintShown.clear(); }
};

void press(Session &s, Mock &m, uint32_t keysym, uint32_t unicode, uint32_t mods = 0) {
    KeyEvent ev;
    ev.keysym = keysym;
    ev.unicode = unicode;
    ev.mods = mods;
    bool consumed = s.processKey(ev, m);
    ev.release = true;
    s.processKey(ev, m);
    if (consumed || (mods & (VT_MOD_CTRL | VT_MOD_ALT | VT_MOD_SUPER))) return;
    // What the application does with a key the IM let through:
    if (keysym == ks::BackSpace) popChars(m.doc, 1);
    else if (keysym == ks::Return) m.doc += "\n";
    else if (keysym == ks::Tab) m.doc += "\t";
    else if (unicode >= 0x20 && unicode < 0x7f) m.doc += char(unicode);
}

// '<' = BackSpace, '\n' = Return, '\t' = Tab, '>' = Right arrow (navigation);
// everything else is typed as that ASCII key.
void type(Session &s, Mock &m, const std::string &keys) {
    for (char c : keys) {
        switch (c) {
        case '<': press(s, m, ks::BackSpace, 0); break;
        case '\n': press(s, m, ks::Return, '\r'); break;
        case '\t': press(s, m, ks::Tab, '\t'); break;
        case '>': press(s, m, ks::Right, 0); break;
        default: press(s, m, uint32_t((unsigned char)c), uint32_t((unsigned char)c));
        }
    }
}

Settings defaults() { return Settings(); }

std::string run(const std::string &keys, DisplayMode mode, Settings st = defaults(), bool surrounding = true) {
    Session s;
    Mock m;
    m.surrounding = surrounding;
    s.applySettings(st);
    s.setDisplayMode(mode, m);
    type(s, m, keys);
    return m.screen();
}

void bothModes(const std::string &keys, const std::string &want, Settings st = defaults()) {
    for (auto mode : {DisplayMode::Preedit, DisplayMode::Surrounding}) {
        std::string got = run(keys, mode, st);
        if (got == want) { ++g_pass; continue; }
        ++g_fail;
        std::fprintf(stderr, "[%s] %s: got [%s] want [%s]\n", keys.c_str(),
                     mode == DisplayMode::Preedit ? "preedit" : "surrounding", got.c_str(), want.c_str());
    }
}

// MARK: - Session

void testBasicTyping() {
    bothModes("vieejt nam ", "việt nam ");
    bothModes("Tieesng Vieejt", "Tiếng Việt");
    bothModes("dduwowcj ", "được ");
    bothModes("google ", "google ");                 // auto-restore
    bothModes("vieejt\n", "việt\n");                 // Enter commits then passes
    bothModes("vieejt.", "việt.");
    bothModes("khoong<<", "khô");                    // ⌫ deletes displayed chars
    bothModes("toans<", "tóa");                      // tone re-placed after ⌫
}

void testPreeditIsUnderlinedComposition() {
    Session s;
    Mock m;
    type(s, m, "vieej");
    CHECK_EQ(m.doc, std::string(""));
    CHECK_EQ(m.pre, std::string("việ"));
    type(s, m, "t");
    CHECK_EQ(m.pre, std::string("việt"));
    type(s, m, " ");
    CHECK_EQ(m.pre, std::string(""));
    CHECK_EQ(m.doc, std::string("việt "));
    // ⌫ through the whole preedit, then the next ⌫ reaches the app
    type(s, m, "ab<<<");
    CHECK_EQ(m.screen(), std::string("việt"));
}

void testSurroundingHasNoPreedit() {
    Session s;
    Mock m;
    s.setDisplayMode(DisplayMode::Surrounding, m);
    type(s, m, "vieejt ");
    CHECK_EQ(m.preeditUpdates, 0);
    CHECK(m.deletes > 0);
    CHECK_EQ(m.doc, std::string("việt "));
}

void testShortcuts() {
    Settings st;
    auto t = std::make_shared<ShortcutTable>();
    (*t)["ko"] = "không";
    (*t)["cf"] = "cà phê";      // key is the RAW form ("cf" composes away)
    st.shortcuts = t;
    bothModes("ko ", "không ", st);
    bothModes("cf ", "cà phê ", st);
    bothModes("2ko ", "2ko ", st);   // glued to a digit: no expansion (#82)
    // Case follows the typing, as on macOS / iOS / Android (2026-11: "Ko" never expanded).
    bothModes("Ko ", "Không ", st);
    bothModes("KO ", "KHÔNG ", st);
    bothModes("kO ", "kO ", st);     // mixed case: no match
    bothModes("Cf ", "Cà phê ", st); // raw-key path too
    st.shortcutsEnabled = false;
    bothModes("ko ", "ko ", st);
    // The lookup itself.
    ShortcutTable k{{"ko", "không"}, {"dc", "được"}, {"đc", "địa chỉ"}, {"Hn", "Hà Nội"}, {"k2", "kệ hai"}};
    std::string e;
    CHECK(shortcutExpansion(k, "ko", e) && e == "không");
    CHECK(shortcutExpansion(k, "Ko", e) && e == "Không");
    CHECK(shortcutExpansion(k, "KO", e) && e == "KHÔNG");
    CHECK(!shortcutExpansion(k, "kO", e));
    CHECK(shortcutExpansion(k, "DC", e) && e == "ĐƯỢC");
    CHECK(shortcutExpansion(k, "Đc", e) && e == "Địa chỉ");
    CHECK(shortcutExpansion(k, "ĐC", e) && e == "ĐỊA CHỈ");
    CHECK(shortcutExpansion(k, "Hn", e) && e == "Hà Nội");  // a key with capitals: exact only
    CHECK(!shortcutExpansion(k, "hn", e));
    CHECK(shortcutExpansion(k, "K2", e) && e == "Kệ hai");  // token keys too
    CHECK(!shortcutExpansion(k, "", e));
}

// Gõ tắt with symbol keys ("=>" → "⟶", "<>" → "⟷"; Windows field report 1.3.x, same gap
// here): '=' '<' '>' end a word, so such keys never reached the word lookup. Typed
// literally ('<' / '>' are NOT BackSpace / Right here; '\n' = Return).
void typeLiteral(Session &s, Mock &m, const std::string &keys) {
    for (char c : keys) {
        if (c == '\n') press(s, m, ks::Return, '\r');
        else press(s, m, uint32_t((unsigned char)c), uint32_t((unsigned char)c));
    }
}

void testSymbolShortcuts() {
    Settings st;
    auto t = std::make_shared<ShortcutTable>();
    (*t)["=>"] = "⟶";
    (*t)["<>"] = "⟷";
    (*t)["->"] = "→";
    (*t)[":D"] = "😀";
    (*t)["ko"] = "không";
    st.shortcuts = t;
    for (auto mode : {DisplayMode::Preedit, DisplayMode::Surrounding}) {
        auto runLit = [&](const std::string &keys, const std::string &already = std::string()) {
            Session s;
            Mock m;
            m.doc = already;
            s.applySettings(st);
            s.setDisplayMode(mode, m);
            typeLiteral(s, m, keys);
            return m.screen();
        };
        CHECK_EQ(runLit("=> a <> b"), std::string("⟶ a ⟷ b"));
        CHECK_EQ(runLit("<>\n"), std::string("⟷\n"));                 // Enter triggers too
        CHECK_EQ(runLit(":D ko "), std::string("😀 không "));          // run + word in progress
        CHECK_EQ(runLit("x=> a->b =>. =>> "), std::string("x=> a->b =>. =>> "));  // glued / not whitespace
        CHECK_EQ(runLit("=> ", "abc"), std::string("abc=> "));         // text before: not standalone
        CHECK_EQ(runLit("=> ", "abc "), std::string("abc ⟶ "));
        // No surrounding text: nothing can be checked, nothing is replaced.
        Session s;
        Mock m;
        m.surrounding = false;
        s.applySettings(st);
        s.setDisplayMode(mode, m);
        typeLiteral(s, m, "=> ");
        CHECK_EQ(m.screen(), std::string("=> "));
    }
    CHECK(isTokenShortcutKey("=>"));
    CHECK(isTokenShortcutKey("k2"));
    CHECK(!isTokenShortcutKey("ko"));
    CHECK(!isTokenShortcutKey("đc"));
}

void testCtrlChordCommits() {
    Session s;
    Mock m;
    type(s, m, "vieejt");
    press(s, m, 'c', 'c', VT_MOD_CTRL);
    CHECK_EQ(m.pre, std::string(""));
    CHECK_EQ(m.doc, std::string("việt"));
}

// #180: with ctrl_commits_word on, a lone Ctrl tap commits the composition; Ctrl held with
// another key, Ctrl+Shift, and the switch off leave it alone.
void testCtrlTapCommitsWord() {
    auto ctrl = [](Session &s, Mock &m, bool release, uint32_t mods = 0) {
        KeyEvent ev;
        ev.keysym = ks::Control_L;
        ev.mods = mods;
        ev.release = release;
        return s.processKey(ev, m);
    };
    {
        Session s;  // default: off
        Mock m;
        type(s, m, "vieej");
        CHECK(!ctrl(s, m, false));
        CHECK(!ctrl(s, m, true, VT_MOD_CTRL));
        CHECK_EQ(m.pre, std::string("việ"));
        CHECK_EQ(m.doc, std::string(""));
    }
    Settings on;
    on.ctrlCommitsWord = true;
    {
        Session s;
        s.applySettings(on);
        Mock m;
        type(s, m, "@vieej");
        CHECK(!ctrl(s, m, false));              // Ctrl itself is never swallowed
        CHECK_EQ(m.doc, std::string("@"));      // nothing more on the press
        CHECK(!ctrl(s, m, true, VT_MOD_CTRL));
        CHECK_EQ(m.pre, std::string(""));
        CHECK_EQ(m.doc, std::string("@việ"));
        type(s, m, "t");                        // a new word after the commit
        CHECK_EQ(m.pre, std::string("t"));
    }
    {
        Session s;
        s.applySettings(on);
        Mock m;
        type(s, m, "vieej");
        ctrl(s, m, false, VT_MOD_SHIFT);        // Shift already held: not a lone tap
        ctrl(s, m, true, VT_MOD_SHIFT | VT_MOD_CTRL);
        CHECK_EQ(m.pre, std::string("việ"));
        ctrl(s, m, false);
        KeyEvent shift;                         // Ctrl then Shift (layout switch chords)
        shift.keysym = 0xffe1;
        shift.mods = VT_MOD_CTRL;
        s.processKey(shift, m);
        ctrl(s, m, true, VT_MOD_CTRL | VT_MOD_SHIFT);
        CHECK_EQ(m.pre, std::string("việ"));
        CHECK_EQ(m.doc, std::string(""));
    }
    CHECK(parseConfig("[general]\nctrl_commits_word = true\n").ctrlCommitsWord);
    CHECK(!Settings().ctrlCommitsWord);
    CHECK(parseConfig(serializeConfig(on)).ctrlCommitsWord);
}

void testToggleHotkey() {
    Session s;
    Mock m;
    bool last = true;
    s.onToggle = [&](bool vi) { last = vi; };
    type(s, m, "vieej");
    press(s, m, ks::space, ' ', VT_MOD_CTRL);   // Ctrl+Space
    CHECK(!last);
    CHECK(!s.vietnamese());
    CHECK_EQ(m.doc, std::string("việ"));        // composition committed, not lost
    type(s, m, "t vieejt ");
    CHECK_EQ(m.doc, std::string("việt vieejt "));
    press(s, m, ks::space, ' ', VT_MOD_CTRL);
    CHECK(last);
    type(s, m, "vieejt");
    CHECK_EQ(m.screen(), std::string("việt vieejt việt"));
    // custom hotkey
    Settings st;
    st.toggleHotkey = "Alt+z";
    s.applySettings(st);
    press(s, m, ks::space, ' ', VT_MOD_CTRL);   // no longer the hotkey: a chord
    CHECK(s.vietnamese());
    press(s, m, 'z', 'z', VT_MOD_ALT);
    CHECK(!s.vietnamese());
}

void testPasswordLiteral() {
    Session s;
    Mock m;
    s.setPassthrough(true, m);
    type(s, m, "vieejt ");
    CHECK_EQ(m.screen(), std::string("vieejt "));
    s.setPassthrough(false, m);
    type(s, m, "vieejt");
    CHECK_EQ(m.screen(), std::string("vieejt việt"));
}

// Dead keys (#161, U.S. International ' " ` ~ ^): composed by the Session — exactly one
// output per sequence, the composed letter is a literal (never a Telex key), in every mode.
// Built-in table here (deterministic); test_dead_keys covers the locale Compose table.
void testDeadKeys() {
    DeadKeys::setBuiltinOnly(true);
    constexpr uint32_t acute = 0xfe51, diaeresis = 0xfe57;
    for (auto mode : {DisplayMode::Preedit, DisplayMode::Surrounding}) {
        Session s;
        Mock m;
        s.setDisplayMode(mode, m);
        type(s, m, "vieejt ");
        press(s, m, acute, 0);
        CHECK_EQ(m.screen(), std::string("việt "));  // pending: nothing shown, nothing lost
        press(s, m, 'e', 'e');
        CHECK_EQ(m.screen(), std::string("việt é"));
        press(s, m, acute, 0);
        press(s, m, ks::space, ' ');
        CHECK_EQ(m.screen(), std::string("việt é'"));  // dead + Space → the accent alone
        press(s, m, diaeresis, 0);
        press(s, m, 'u', 'u');
        CHECK_EQ(m.screen(), std::string("việt é'ü"));
        press(s, m, acute, 0);
        type(s, m, "x ");
        CHECK_EQ(m.screen(), std::string("việt é'ü'x "));  // not composable: accent + key
        press(s, m, acute, 0);
        press(s, m, ks::Escape, 0x1b);
        type(s, m, "a ");
        CHECK_EQ(m.screen(), std::string("việt é'ü'x a "));  // Esc cancelled it
        // In a word: the word ends, é is a literal and "s" after it is a new word, not a tone.
        type(s, m, "vieej");
        press(s, m, acute, 0);
        press(s, m, 'e', 'e');
        type(s, m, "s");
        CHECK_EQ(m.screen(), std::string("việt é'ü'x a việés"));
        // Focus change drops a pending dead key.
        type(s, m, " ");
        press(s, m, acute, 0);
        s.finish(m);
        s.focusIn();
        type(s, m, "a");
        CHECK_EQ(m.screen(), std::string("việt é'ü'x a việés a"));
    }
    // English (toggle) and passthrough (password) fields compose too.
    {
        Session s;
        Mock m;
        s.setVietnamese(false, m);
        press(s, m, acute, 0);
        press(s, m, 'e', 'e');
        s.setPassthrough(true, m);
        press(s, m, diaeresis, 0);
        press(s, m, 'u', 'u');
        CHECK_EQ(m.screen(), std::string("éü"));
    }
    DeadKeys::setBuiltinOnly(false);
}

void testReopenAfterBoundary() {
    // "tháy" ␣ ⌫ a → "thấy" (issue #40), when the client reports surrounding text
    bothModes("thays <a", "thấy");
    // without surrounding text the word cannot be proven on screen: plain ⌫
    CHECK_EQ(run("thays <a", DisplayMode::Preedit, defaults(), false), std::string("tháya"));
}

void testReEditAfterCaretMove() {
    for (auto mode : {DisplayMode::Preedit, DisplayMode::Surrounding}) {
        Session s;
        Mock m;
        s.setDisplayMode(mode, m);
        m.doc = "toi toan";      // existing text; caret arrives there by navigation
        type(s, m, ">s ");
        CHECK_EQ(m.screen(), std::string("toi toán "));
        Settings st;
        st.reEditWord = false;
        s.applySettings(st);
        m.doc = "toan";
        type(s, m, ">s");
        CHECK_EQ(m.screen(), std::string("toans"));
    }
}

// Verify-before-delete (lesson from fcitx5-lotus): every edit that deletes text before the
// caret first checks the host shows exactly what VietTelex put there.
void testVerifyBeforeDelete() {
    // Normal: matching text, in-place tones and ⌫ reopen still work, nothing distrusted.
    {
        Session s;
        Mock m;
        s.setDisplayMode(DisplayMode::Surrounding, m);
        type(s, m, "toans thays <a");
        CHECK_EQ(m.screen(), std::string("toán thấy"));
        CHECK(!s.surroundingDistrusted());
        CHECK(s.displayMode() == DisplayMode::Surrounding);
    }
    // Stale in-place: the host has not applied the last commit ("n") yet. The channel is
    // ordered, so the edit goes ahead — and the host is not blamed.
    {
        Session s;
        Mock m;
        s.setDisplayMode(DisplayMode::Surrounding, m);
        type(s, m, "toan");
        m.hasReported = true;
        m.reported = "toa";
        type(s, m, "s");
        CHECK_EQ(m.screen(), std::string("toán"));
        m.reported = "toán v";  // only the first letter of the next word applied yet
        type(s, m, " vie");
        type(s, m, "e");
        CHECK_EQ(m.screen(), std::string("toán viê"));
        CHECK(!s.surroundingDistrusted());
        CHECK_EQ(m.overDeletes, 0);
        // (A report holding fewer characters than the delete: testDeleteNeverPastReport.)
    }
    // Stale reopen: the boundary was not applied yet → plain ⌫ (never block, never guess),
    // no distrust; once the host catches up, reopen works again.
    for (auto mode : {DisplayMode::Preedit, DisplayMode::Surrounding}) {
        Session s;
        Mock m;
        s.setDisplayMode(mode, m);
        type(s, m, "thays ");
        m.hasReported = true;
        m.reported = "tháy";
        int deletes = m.deletes;
        type(s, m, "<");
        CHECK_EQ(m.deletes, deletes);
        CHECK_EQ(m.screen(), std::string("tháy"));
        CHECK(!s.surroundingDistrusted());
        m.hasReported = false;
        m.doc.clear();
        type(s, m, "thays <a");
        CHECK_EQ(m.screen(), std::string("thấy"));
    }
    // Mismatch in-place: the app changed the word under us ("toan" → "Toan"): the tone key
    // is typed literally, nothing deleted, and the rest of the focus composes in preedit
    // even though the frontend keeps asking for Surrounding.
    {
        Session s;
        Mock m;
        s.setDisplayMode(DisplayMode::Surrounding, m);
        type(s, m, "toan");
        m.doc = "Toan";
        int deletes = m.deletes;
        type(s, m, "s");
        CHECK_EQ(m.deletes, deletes);
        CHECK_EQ(m.screen(), std::string("Toans"));
        CHECK(s.surroundingDistrusted());
        CHECK(s.displayMode() == DisplayMode::Preedit);
        s.setDisplayMode(DisplayMode::Surrounding, m);  // per-key policy refresh
        s.setSurroundingEdits(true);
        CHECK(s.displayMode() == DisplayMode::Preedit);
        type(s, m, " vieej");
        CHECK_EQ(m.pre, std::string("việ"));
        type(s, m, "t thays <");  // ⌫ reopen is off too
        CHECK_EQ(m.screen(), std::string("Toans việt tháy"));
        // New focus: trusted again (never persisted).
        s.focusIn();
        CHECK(!s.surroundingDistrusted());
        CHECK(s.displayMode() == DisplayMode::Surrounding);
        m.doc.clear();
        type(s, m, "toans");
        CHECK_EQ(m.screen(), std::string("toán"));
        CHECK(m.pre.empty());
    }
    // Mismatch reopen: the word changed, or a different boundary is shown.
    for (auto mode : {DisplayMode::Preedit, DisplayMode::Surrounding}) {
        Session s;
        Mock m;
        s.setDisplayMode(mode, m);
        type(s, m, "thays ");
        m.doc = "thay ";
        int deletes = m.deletes;
        type(s, m, "<");
        CHECK_EQ(m.deletes, deletes);
        CHECK_EQ(m.screen(), std::string("thay"));
        CHECK(s.surroundingDistrusted());
        CHECK(s.displayMode() == DisplayMode::Preedit);
    }
    {
        Session s;
        Mock m;
        type(s, m, "thays,");
        m.doc = "tháy.";
        type(s, m, "<");
        CHECK_EQ(m.screen(), std::string("tháy"));
        CHECK(s.surroundingDistrusted());
    }
    // In-place ⌫ that rewrites the word (classic tone: "toán" ⌫ → "tóa", the tone moves): the
    // app's own ⌫ when the word changed under us.
    {
        Settings st;
        st.modernTone = false;
        Session s;
        Mock m;
        s.applySettings(st);
        s.setDisplayMode(DisplayMode::Surrounding, m);
        type(s, m, "toans<");
        CHECK_EQ(m.screen(), std::string("tóa"));  // the matching case still rewrites
        CHECK(!s.surroundingDistrusted());
        m.doc.clear();
        type(s, m, " toans");
        m.doc = "Toán";
        int deletes = m.deletes;
        type(s, m, "<");
        CHECK_EQ(m.deletes, deletes);
        CHECK_EQ(m.screen(), std::string("Toá"));
        CHECK(s.surroundingDistrusted());
    }
    // Shortcut / auto-restore delete in place: the word changed → left as it is.
    {
        Settings st;
        auto t = std::make_shared<ShortcutTable>();
        (*t)["ko"] = "không";
        st.shortcuts = t;
        Session s;
        Mock m;
        s.applySettings(st);
        s.setDisplayMode(DisplayMode::Surrounding, m);
        type(s, m, "ko");
        m.doc = "kO";
        int deletes = m.deletes;
        type(s, m, " ");
        CHECK_EQ(m.deletes, deletes);
        CHECK_EQ(m.screen(), std::string("kO "));
        CHECK(s.surroundingDistrusted());
    }
    // Host that duplicates commits (Draft.js-like): caught at the first in-place edit, never
    // deletes, then preedit.
    {
        Session s;
        Mock m;
        m.dup = true;
        s.setDisplayMode(DisplayMode::Surrounding, m);
        type(s, m, "toans");
        CHECK_EQ(m.deletes, 0);
        CHECK(s.surroundingDistrusted());
        CHECK(s.displayMode() == DisplayMode::Preedit);
        CHECK_EQ(m.screen(), std::string("ttooaannss"));
    }
    // NFD host: same letters, more code points — deletes counted in characters would be off.
    {
        Session s;
        Mock m;
        type(s, m, "thays ");
        m.doc = "tha\xcc\x81y ";  // tha + U+0301 + y
        type(s, m, "<");
        CHECK_EQ(m.deletes, 0);
        CHECK_EQ(m.screen(), std::string("tha\xcc\x81y"));
        CHECK(s.surroundingDistrusted());
    }
    for (auto mode : {DisplayMode::Preedit, DisplayMode::Surrounding}) {
        Session s;
        Mock m;
        s.setDisplayMode(mode, m);
        m.doc = "toa\xcc\x80n";  // toàn, decomposed; caret arrives by navigation
        type(s, m, ">s");
        CHECK_EQ(m.deletes, 0);
        CHECK_EQ(m.screen(), std::string("toa\xcc\x80ns"));
        CHECK(s.surroundingDistrusted());
    }
}

void testFinishCommitsPreedit() {
    Session s;
    Mock m;
    type(s, m, "vieej");
    s.finish(m);                 // focus out / click
    CHECK_EQ(m.doc, std::string("việ"));
    CHECK_EQ(m.pre, std::string(""));
    type(s, m, "a");
    CHECK_EQ(m.screen(), std::string("việa"));
    Mock m2;
    type(s, m2, "vieej");
    s.finish(m2, false);         // IBus: framework commits the preedit itself
    CHECK_EQ(m2.doc, std::string(""));
    CHECK(!s.composing());
}

void testOverflowNeverLosesText() {
    std::string word(40, 'b');
    bothModes(word + " ", word + " ");
}

void testVniAndLiveSettings() {
    Settings st;
    st.vni = true;
    bothModes("vie65t nam ", "việt nam ", st);
    // settings applied mid-session take effect on the next word
    Session s;
    Mock m;
    type(s, m, "vieejt ");
    s.applySettings(st);
    type(s, m, "vie65t ");
    CHECK_EQ(m.doc, std::string("việt việt "));
}

// #124: numpad digits are never VNI marks — they end the word and reach the app;
// top-row digits keep marking.
void testVniKeypadDigitsAreBoundaries() {
    Settings st;
    st.vni = true;
    for (auto mode : {DisplayMode::Preedit, DisplayMode::Surrounding}) {
        Session s;
        Mock m;
        s.applySettings(st);
        s.setDisplayMode(mode, m);
        type(s, m, "a");
        press(s, m, 0xffb1, '1');  // KP_1
        type(s, m, "a1 ");
        press(s, m, 0xffb0, '0');  // KP_0
        CHECK_EQ(m.screen(), std::string("a1\xc3\xa1 0"));
    }
}

void testModesAgreeOnRandomScripts() {
    std::mt19937 rng(12345);
    const std::string alphabet = "aeoudwsfrxjzntghiycqAEO  <<.";
    for (int i = 0; i < 3000; ++i) {
        std::string keys;
        int n = 1 + int(rng() % 14);
        for (int k = 0; k < n; ++k) keys += alphabet[rng() % alphabet.size()];
        std::string p = run(keys, DisplayMode::Preedit);
        std::string q = run(keys, DisplayMode::Surrounding);
        {
            // An honest host never trips verify-before-delete.
            Session s;
            Mock m;
            s.setDisplayMode(DisplayMode::Surrounding, m);
            type(s, m, keys);
            if (s.surroundingDistrusted()) {
                std::fprintf(stderr, "honest host distrusted for [%s]\n", keys.c_str());
                ++g_fail;
                return;
            }
        }
        if (p != q) {
            std::fprintf(stderr, "mode mismatch for [%s]: preedit=[%s] surrounding=[%s]\n", keys.c_str(),
                         p.c_str(), q.c_str());
            ++g_fail;
            return;
        }
    }
    ++g_pass;
}

// MARK: - Text tools (Công cụ…)

void testTextToolSettings() {
    Settings d = parseConfig("");
    CHECK_EQ(d.uiLanguage, std::string("vi"));  // default Vietnamese whatever the locale is
    CHECK(d.textToolsMenu);
    CHECK_EQ(d.addTonesHotkey, std::string(""));  // hotkey off by default
    Settings s = parseConfig("[general]\nui_language = \"EN\"\ntext_tools_menu = false\nadd_tones_hotkey = \"Ctrl+Alt+t\"\n");
    CHECK_EQ(s.uiLanguage, std::string("en"));
    CHECK(!s.textToolsMenu);
    CHECK_EQ(s.addTonesHotkey, std::string("Ctrl+Alt+t"));
    CHECK_EQ(parseConfig("[general]\nui_language = \"fr\"\n").uiLanguage, std::string("vi"));
    CHECK_EQ(parseConfig("[general]\nui_language = 1\n").uiLanguage, std::string("vi"));
    Settings r = parseConfig(serializeConfig(s));
    CHECK_EQ(r.uiLanguage, std::string("en"));
    CHECK(!r.textToolsMenu);
    CHECK_EQ(r.addTonesHotkey, std::string("Ctrl+Alt+t"));

    // Caret suggestions: defaults = macOS 1.8.2 (all on except tones), round trip.
    CHECK(d.mathResults && d.numberChips && d.typoHints && d.dateHints);
    CHECK(!d.toneHints);
    Settings h = parseConfig("[general]\nmath_results = false\nnumber_chips = false\ntypo_hints = false\n"
                             "tone_hints = true\ndate_hints = false\n");
    CHECK(!h.mathResults && !h.numberChips && !h.typoHints && h.toneHints && !h.dateHints);
    Settings hr = parseConfig(serializeConfig(h));
    CHECK(!hr.mathResults && !hr.numberChips && !hr.typoHints && hr.toneHints && !hr.dateHints);
    CHECK(parseConfig("[general]\nmath_results = \"no\"\n").mathResults);  // wrong type → default
}

void testAddTonesHotkey() {
    Session s;
    Mock m;
    Settings st;
    s.applySettings(st);
    KeyEvent ev;
    ev.keysym = 't';
    ev.unicode = 't';
    ev.mods = VT_MOD_CTRL | VT_MOD_ALT;
    CHECK(!s.isAddTonesHotkey(ev));  // off by default
    st.addTonesHotkey = "Ctrl+Alt+t";
    s.applySettings(st);
    CHECK(s.isAddTonesHotkey(ev));
    ev.keysym = 'T';  // Caps Lock
    CHECK(s.isAddTonesHotkey(ev));
    ev.mods = VT_MOD_CTRL;
    CHECK(!s.isAddTonesHotkey(ev));
    ev.mods = VT_MOD_CTRL | VT_MOD_ALT;
    ev.release = true;
    CHECK(!s.isAddTonesHotkey(ev));
    ev.release = false;
    ev.forwarded = true;
    CHECK(!s.isAddTonesHotkey(ev));
    // Same chord as Việt/Anh: the toggle wins, the tool hotkey is ignored.
    st.addTonesHotkey = "Ctrl+space";
    s.applySettings(st);
    KeyEvent sp;
    sp.keysym = ks::space;
    sp.unicode = ' ';
    sp.mods = VT_MOD_CTRL;
    CHECK(!s.isAddTonesHotkey(sp));
    CHECK(s.isToggleHotkey(sp));
    // A bare printable key would eat typing.
    st.addTonesHotkey = "t";
    s.applySettings(st);
    ev.forwarded = false;
    ev.mods = 0;
    CHECK(!s.isAddTonesHotkey(ev));
    (void)m;
}

void testTextToolNamesAndSelection() {
    // Menu order and CLI ids = macOS TextAction / viettelex-text-tool arguments.
    const char *ids[] = {"addTones", "upper", "lower", "title", "sentence", "stripDiacritics"};
    for (int i = 0; i < kTextToolCount; ++i) {
        TextTool t = textToolAt(i);
        CHECK_EQ(std::string(textToolId(t)), std::string(ids[i]));
        TextTool back = TextTool::Upper;
        CHECK(textToolFromId(ids[i], back));
        CHECK(back == t);
        CHECK(!textToolLabel(t, false).empty());
        CHECK(textToolLabel(t, false) != textToolLabel(t, true) || t == TextTool::Upper);
    }
    TextTool none = TextTool::Upper;
    CHECK(!textToolFromId("bogus", none));
    CHECK_EQ(textToolLabel(TextTool::AddTones, false), std::string("Thêm dấu cho vùng chọn"));
    CHECK_EQ(textToolLabel(TextTool::AddTones, true), std::string("Add tones to selection"));
    // The Vi/En tooltip names the configured hotkey (it was always "Ctrl+Space").
    CHECK_EQ(hotkeyLabel("Ctrl+space"), std::string("Ctrl+Space"));
    CHECK_EQ(hotkeyLabel("Alt+Shift+z"), std::string("Alt+Shift+Z"));
    CHECK_EQ(hotkeyLabel(""), std::string());
    CHECK_EQ(hotkeyLabel("z"), std::string());  // invalid: a bare letter never toggles
    CHECK_EQ(toggleTooltip("Ctrl+space", false), std::string("Chuyển Việt/Anh (Ctrl+Space)"));
    CHECK_EQ(toggleTooltip("Ctrl+Shift+space", true), std::string("Switch Vietnamese/English (Ctrl+Shift+Space)"));
    CHECK_EQ(toggleTooltip("Super+space", false), std::string("Chuyển Việt/Anh"));  // GNOME's, rejected
    CHECK_EQ(toggleTooltip("", false), std::string("Chuyển Việt/Anh"));
    // Every IM menu string the frontends use has an English entry.
    const char *ui[] = {"Tiếng Việt", "English", "Đang gõ tiếng Việt — bấm để chuyển sang English",
                        "Đang gõ English — bấm để chuyển sang tiếng Việt", "Chuyển Việt/Anh",
                        "Cài đặt…", "Mở VietTelex Settings", "Công cụ…", "Công cụ văn bản cho chữ đang bôi đen"};
    for (const char *k : ui) {
        CHECK_EQ(uiText(k, false), std::string(k));
        std::string en = uiText(k, true);
        CHECK(!en.empty());
        // English strings carry no Vietnamese letters (ASCII + typographic punctuation only).
        bool vietnamese = false;
        for (size_t i = 0; i + 1 < en.size(); ++i) {
            unsigned char c = static_cast<unsigned char>(en[i]);
            if (c == 0xc3 || c == 0xc4 || c == 0xc6 || c == 0xe1) vietnamese = true;
        }
        CHECK(!vietnamese);
        if (std::string(k) != "English") CHECK(en != k);
    }
    CHECK(isEnglishUi("en"));
    CHECK(!isEnglishUi("vi"));
    CHECK(!isEnglishUi(""));
    // Selection inside surrounding text (offsets in characters, either direction).
    std::string sel;
    CHECK(selectionFromSurrounding("Tôi đi học", 4, 6, sel));
    CHECK_EQ(sel, std::string("đi"));
    CHECK(selectionFromSurrounding("Tôi đi học", 10, 7, sel));
    CHECK_EQ(sel, std::string("học"));
    CHECK(!selectionFromSurrounding("Tôi đi học", 3, 3, sel));
    CHECK(!selectionFromSurrounding("abc", 1, 9, sel));

    // GTK3: no anchor in surrounding text → PRIMARY only when it touches the caret.
    CHECK(primaryAdjacentToCursor("toi di hoc", 10, "toi di hoc"));   // select all, caret at end
    CHECK(primaryAdjacentToCursor("toi di hoc", 0, "toi di hoc"));    // caret at start
    CHECK(primaryAdjacentToCursor("Tôi đi học", 3, "Tôi"));           // characters, not bytes
    CHECK(primaryAdjacentToCursor("Tôi đi học", 7, "học"));
    CHECK(!primaryAdjacentToCursor("Tôi đi học", 7, "đi"));           // not against the caret
    CHECK(!primaryAdjacentToCursor("toi di hoc", 10, "khac"));        // stale PRIMARY
    CHECK(!primaryAdjacentToCursor("toi di hoc", 10, ""));
    CHECK(!primaryAdjacentToCursor("abc", 9, "abc"));                 // bad offset

    // selectionAtCaret: anchor first; PRIMARY read only when the anchor proves nothing.
    int reads = 0;
    auto primaryIs = [&reads](const std::string &v) {
        return [&reads, v](std::string &out) {
            ++reads;
            out = v;
            return !v.empty();
        };
    };
    CHECK(selectionAtCaret("toi di hoc", 10, 0, primaryIs("")));
    CHECK_EQ(reads, 0);
    CHECK(selectionAtCaret("toi di hoc", 10, 10, primaryIs("toi di hoc")));  // GTK3 select all
    CHECK(selectionAtCaret("toi di hoc", 10, 10, primaryIs("hoc")));
    CHECK(!selectionAtCaret("toi di hoc", 10, 10, primaryIs("di")));   // PRIMARY elsewhere
    CHECK(!selectionAtCaret("toi di hoc", 10, 10, primaryIs("")));     // no PRIMARY / no tool
    CHECK(!selectionAtCaret("toi di hoc", 10, 10, {}));
    CHECK_EQ(reads, 4);

    // Key-path probe: no process spawn when it cannot change the answer.
    reads = 0;
    bool anchorSeen = false;
    const std::string cachedFar = "khac", cachedHere = "hoc", noCache;
    // Cache not against the caret ⇒ no external read at all.
    CHECK(!selectionAtCaretProbe("toi di hoc", 10, 10, anchorSeen, &cachedFar, true, primaryIs("hoc")));
    CHECK(!selectionAtCaretProbe("toi di hoc", 10, 10, anchorSeen, &noCache, true, primaryIs("hoc")));
    CHECK_EQ(reads, 0);
    // Cache against the caret ⇒ confirmed live (stale cache after deselect ⇒ false).
    CHECK(selectionAtCaretProbe("toi di hoc", 10, 10, anchorSeen, &cachedHere, true, primaryIs("hoc")));
    CHECK(!selectionAtCaretProbe("toi di hoc", 10, 10, anchorSeen, &cachedHere, true, primaryIs("")));
    CHECK_EQ(reads, 2);
    // No live tool installed: the cache decides.
    CHECK(selectionAtCaretProbe("toi di hoc", 10, 10, anchorSeen, &cachedHere, false, primaryIs("")));
    CHECK_EQ(reads, 2);
    // No cache (IBus / no clipboard addon) ⇒ live read.
    CHECK(selectionAtCaretProbe("toi di hoc", 10, 10, anchorSeen, nullptr, true, primaryIs("hoc")));
    CHECK_EQ(reads, 3);
    // A host that reported a real anchor once: anchor == cursor means no selection, no probe.
    CHECK(selectionAtCaretProbe("toi di hoc", 10, 7, anchorSeen, nullptr, true, primaryIs("hoc")));
    CHECK(anchorSeen);
    CHECK(!selectionAtCaretProbe("toi di hoc", 10, 10, anchorSeen, nullptr, true, primaryIs("hoc")));
    CHECK(!selectionAtCaretProbe("toi di hoc", 10, 10, anchorSeen, &cachedHere, true, primaryIs("hoc")));
    CHECK_EQ(reads, 3);
}

// readPrimarySelection stops at the first tool that answers (exit 0), even with nothing
// selected: wl-paste answering "" must not cost another 150 ms in xclip.
// IBus frontend: one ibus_engine_get_surrounding_text (a D-Bus signal + a new ref) per
// engine callback instead of 3–5; re-read after our own delete (IBus rewrites its copy).
void testSurroundingCache() {
    int fetches = 0;
    SurroundingCache c([&fetches](SurroundingSnapshot &s) {
        ++fetches;
        s.text = "toi di";
        s.cursor = s.anchor = 6;
        return true;
    });
    for (int i = 0; i < 5; ++i) CHECK(c.get() && c.get()->text == "toi di");
    CHECK_EQ(fetches, 1);
    c.invalidate();
    CHECK(c.get());
    CHECK_EQ(fetches, 2);
    int none = 0;
    SurroundingCache empty([&none](SurroundingSnapshot &) { ++none; return false; });
    CHECK(!empty.get());
    CHECK(!empty.get());
    CHECK_EQ(none, 1);

    // Frontends attach the hint sink at focus-in when the helper appeared after start-up
    // (viettelex-text-tools installed later): they ask hasHintSink() first.
    Session s;
    CHECK(!s.hasHintSink());
    s.setHintSink([](const HintRequest &) {});
    CHECK(s.hasHintSink());
}

void testPrimaryFirstToolWins() {
    char tmpl[] = "/tmp/vt-primary-XXXXXX";
    const char *dir = mkdtemp(tmpl);
    if (!dir) { ++g_fail; return; }
    const std::string d = dir;
    auto script = [&](const std::string &name, const std::string &body) {
        std::string p = d + "/" + name;
        FILE *f = std::fopen(p.c_str(), "w");
        std::fprintf(f, "#!/bin/sh\n%s\n", body.c_str());
        std::fclose(f);
        chmod(p.c_str(), 0755);
    };
    script("wl-paste", "exit 0");                                  // nothing selected
    script("xclip", "touch '" + d + "/xclip-ran'; printf stale");
    const char *oldPath = std::getenv("PATH"), *oldWl = std::getenv("WAYLAND_DISPLAY"),
               *oldX = std::getenv("DISPLAY");
    const std::string savePath = oldPath ? oldPath : "", saveWl = oldWl ? oldWl : "", saveX = oldX ? oldX : "";
    setenv("PATH", (d + ":/usr/bin:/bin").c_str(), 1);
    setenv("WAYLAND_DISPLAY", "wayland-test", 1);
    setenv("DISPLAY", ":99", 1);
    std::string out = "x";
    CHECK(!readPrimarySelection(out, 2000));
    CHECK(out.empty());
    CHECK(access((d + "/xclip-ran").c_str(), F_OK) != 0);
    script("wl-paste", "printf hoc");
    CHECK(readPrimarySelection(out, 2000));
    CHECK_EQ(out, std::string("hoc"));
    script("wl-paste", "exit 1");                                  // no wl-paste answer ⇒ next tool
    CHECK(readPrimarySelection(out, 2000));
    CHECK_EQ(out, std::string("stale"));
    setenv("PATH", savePath.c_str(), 1);
    if (oldWl) setenv("WAYLAND_DISPLAY", saveWl.c_str(), 1); else unsetenv("WAYLAND_DISPLAY");
    if (oldX) setenv("DISPLAY", saveX.c_str(), 1); else unsetenv("DISPLAY");
    for (const char *f : {"wl-paste", "xclip", "xclip-ran"}) std::remove((d + "/" + f).c_str());
    rmdir(dir);
}

// Runs the real viettelex-text-tool when ctest points at it (VIETTELEX_TEXT_TOOL).
void testTextToolHelper() {
    const char *helper = std::getenv("VIETTELEX_TEXT_TOOL");
    if (!helper || !*helper) {
        std::fprintf(stderr, "(viettelex-text-tool not set: helper tests skipped)\n");
        return;
    }
    CHECK(textToolAvailable());
    std::string out;
    CHECK(runTextTool(TextTool::AddTones, "toi di hoc hom nay", out));
    CHECK_EQ(out, std::string("tôi đi học hôm nay"));
    CHECK(runTextTool(TextTool::Upper, "Tiếng Việt", out));
    CHECK_EQ(out, std::string("TIẾNG VIỆT"));
    CHECK(runTextTool(TextTool::Title, "tiếng việt có dấu", out));
    CHECK_EQ(out, std::string("Tiếng Việt Có Dấu"));
    CHECK(runTextTool(TextTool::Sentence, "tiếng việt. có dấu", out));
    CHECK_EQ(out, std::string("Tiếng việt. Có dấu"));
    CHECK(runTextTool(TextTool::StripDiacritics, "Đường phố", out));
    CHECK_EQ(out, std::string("Duong pho"));
    CHECK(!runTextTool(TextTool::Lower, "already lower", out));  // unchanged → false
    CHECK(!runTextTool(TextTool::Upper, "", out));
    CHECK(!runTextTool(TextTool::Upper, "123 ... !!", out) || out == "123 ... !!");
    // Large input (more than a pipe buffer: 3-byte letters, just under the length limit)
    // must not deadlock — stdin and stdout are pumped together.
    std::string big;
    for (size_t i = 0; i < kTextToolMaxChars / 2 - 10; ++i) big += "ệ ";

    CHECK(runTextTool(TextTool::Upper, big, out));
    CHECK_EQ(out.size(), big.size());
    // Too long for the macOS limit → untouched.
    std::string huge(kTextToolMaxChars + 10, 'a');
    CHECK(!runTextTool(TextTool::Upper, huge, out));
    // A missing helper fails closed.
    setenv("VIETTELEX_TEXT_TOOL", "/nonexistent/viettelex-text-tool", 1);
    CHECK(!textToolAvailable());
    CHECK(!runTextTool(TextTool::Upper, "abc", out));
    setenv("VIETTELEX_TEXT_TOOL", helper, 1);

    // TextToolRunner: worker thread → posted back → done(), one job at a time.
    std::vector<std::function<void()>> queue;
    std::mutex mu;
    TextToolRunner runner([&](std::function<void()> f) {
        std::lock_guard<std::mutex> l(mu);
        queue.push_back(std::move(f));
    });
    bool called = false, changed = false;
    std::string input, result;
    CHECK(runner.start(TextTool::AddTones,
                       [](std::string &o) {
                           o = "khong co gi";
                           return true;
                       },
                       [&](bool c, const std::string &in, const std::string &r) {
                           called = true;
                           changed = c;
                           input = in;
                           result = r;
                       }));
    CHECK(!runner.start(TextTool::Upper, nullptr, nullptr));  // busy
    for (int i = 0; i < 500; ++i) {
        {
            std::lock_guard<std::mutex> l(mu);
            if (!queue.empty()) break;
        }
        usleep(10000);
    }
    std::vector<std::function<void()>> q;
    {
        std::lock_guard<std::mutex> l(mu);
        q.swap(queue);
    }
    CHECK_EQ(q.size(), size_t(1));
    for (auto &f : q) f();
    CHECK(called && changed);
    CHECK_EQ(input, std::string("khong co gi"));
    CHECK_EQ(result, std::string("không có gì"));
    CHECK(!runner.busy());
}

// MARK: - Settings

void testConfigParse() {

    Settings d;
    std::string round = serializeConfig(d);
    Settings r = parseConfig(round);
    CHECK_EQ(serializeConfig(r), round);
    Settings s = parseConfig(
        "# comment\n[typing]\ninput_method = \"vni\"  # trailing\nfree_marking = false\n"
        "teencode = true\nspell_check = maybe\n\n[general]\ndisplay_mode = \"surrounding\"\n"
        "toggle_hotkey = \"Alt+Shift+z\"\nper_app_state = false\n[app_modes]\n\"Org.Gnome.TextEditor\" = \"surrounding\"\n"
        "\"kitty\" = \"off\"\n\"bad\" = \"weird\"\n");
    CHECK(s.vni);
    CHECK(!s.freeMarking);
    CHECK(s.teencode);
    CHECK(s.spellCheck);  // bad value → default
    CHECK(s.displayMode == DisplayMode::Surrounding);
    CHECK_EQ(s.toggleHotkey, std::string("Alt+Shift+z"));
    CHECK(!s.perAppState);
    CHECK_EQ(s.appModes.size(), size_t(2));
    CHECK_EQ(s.appModes["org.gnome.texteditor"], std::string("surrounding"));
    Settings e = parseConfig("");
    CHECK(e.freeMarking && e.spellCheck && e.autoRestore && !e.teencode && e.contextualEnglish &&
          e.collisionPrefersVietnamese && !e.vni && e.displayMode == DisplayMode::Preedit);
}

// writeFileAtomic: a symlinked config.toml stays a symlink (the target is rewritten), the temp
// name is unique (the settings app and the Fcitx5 dialog share the dir), a read-only dir is
// reported as a failure and leaves nothing behind, the file mode is kept.
void testWriteFileAtomic() {
    char tmpl[] = "/tmp/vt-write-XXXXXX";
    const char *d = mkdtemp(tmpl);
    if (!d) { ++g_fail; return; }
    const std::string dir = d, target = dir + "/real.toml", link = dir + "/config.toml";
    CHECK(writeFileAtomic(target, "a\n"));
    chmod(target.c_str(), 0640);
    CHECK(symlink("real.toml", link.c_str()) == 0);
    CHECK(writeFileAtomic(link, "b\n"));
    struct stat st;
    CHECK(lstat(link.c_str(), &st) == 0 && S_ISLNK(st.st_mode));
    std::string text;
    CHECK(readFile(target, text) && text == "b\n");
    CHECK(stat(target.c_str(), &st) == 0 && (st.st_mode & 0777) == 0640);
    // No fixed "<name>.tmp" left over or reused.
    CHECK(access((target + ".tmp").c_str(), F_OK) != 0);
    const std::string ro = dir + "/ro";
    mkdir(ro.c_str(), 0700);
    CHECK(writeFileAtomic(ro + "/config.toml", "x\n"));
    chmod(ro.c_str(), 0500);
    if (geteuid() != 0) {  // root ignores the mode
        CHECK(!writeFileAtomic(ro + "/config.toml", "y\n"));
        CHECK(readFile(ro + "/config.toml", text) && text == "x\n");
    }
    chmod(ro.c_str(), 0700);
    std::remove((ro + "/config.toml").c_str());
    rmdir(ro.c_str());
    std::remove(link.c_str());
    std::remove(target.c_str());
    rmdir(d);
}

void testSetConfigValue() {
    std::string t = "# mine\n[typing]\nfree_marking = true # c\nfuture_key = 3\n\n[general]\nper_app_state = true\n";
    std::string u = setConfigValue(t, "typing", "free_marking", "false");
    CHECK(u.find("# mine") != std::string::npos);
    CHECK(u.find("future_key = 3") != std::string::npos);
    CHECK(!parseConfig(u).freeMarking);
    u = setConfigValue(u, "typing", "input_method", "\"vni\"");
    CHECK(parseConfig(u).vni);
    CHECK(u.find("input_method") < u.find("[general]"));
    u = setConfigValue(u, "app_modes", "org.gnome.gedit", "\"off\"");
    CHECK_EQ(parseConfig(u).appModes["org.gnome.gedit"], std::string("off"));
    CHECK(parseConfig(u).perAppState);
    CHECK_EQ(setConfigValue("", "general", "display_mode", "\"surrounding\""),
             std::string("[general]\ndisplay_mode = \"surrounding\"\n"));
}

void testShortcutFile() {
    std::string text;
    // sample-shortcuts.yml from the repo root must parse (same format as macOS)
    if (readFile(std::string(VT_SOURCE_ROOT) + "/sample-shortcuts.yml", text)) {
        ShortcutTable t = parseShortcuts(text);
        CHECK_EQ(t["ko"], std::string("không"));
        CHECK_EQ(t["đc"], std::string("được"));
        CHECK_EQ(parseShortcuts(exportShortcuts(t)), t);
    } else {
        ++g_fail;
        std::fprintf(stderr, "sample-shortcuts.yml not found\n");
    }
    ShortcutTable t = parseShortcuts("; c\n// c\na: \"  spaced \"\nb:'q'\nwith space: x\nempty:\nurl: http://x\n");
    CHECK_EQ(t["a"], std::string("  spaced "));
    CHECK_EQ(t["b"], std::string("q"));
    CHECK_EQ(t.count("with space"), size_t(0));
    CHECK_EQ(t.count("empty"), size_t(0));
    CHECK_EQ(t["url"], std::string("http://x"));
    CHECK_EQ(parseShortcuts(exportShortcuts(t)), t);
}

// Quoted keys / escaped values, exactly as macOS ShortcutImporter writes them
// (tests/data/shortcuts-macos.yml was produced by macOS exportYAML; the Python settings app
// test reads the same file). Before: ":D" was split at its own ':' and vanished.
void testShortcutFileQuoting() {
    ShortcutTable want = {
        {":D", "😀"}, {"a:b", "x"}, {"#x", "hash"}, {";x", "semi"}, {"//x", "slash"},
        {"\"k", "dq"}, {"'k", "sq"}, {"sig", "Thân mến,\nPhil"}, {"bs", "C:\\temp"},
        {"q", "\"trích\""}, {"sp", " có space "}, {"ko", "không"}, {"url", "http://x"}, {"tab", "a\tb"},
    };
    std::string fixture;
    if (readFile(std::string(VT_SOURCE_ROOT) + "/linux/common/tests/data/shortcuts-macos.yml", fixture)) {
        CHECK_EQ(exportShortcuts(want), fixture);  // byte for byte what macOS writes
        CHECK_EQ(parseShortcuts(fixture), want);
    } else {
        ++g_fail;
        std::fprintf(stderr, "tests/data/shortcuts-macos.yml not found\n");
    }
    CHECK_EQ(parseShortcuts(exportShortcuts(want)), want);
    // Line written by iOS/Android/macOS (macOS AppTests testParsesFilesWrittenByIOSAndAndroid).
    ShortcutTable phone = parseShortcuts(
        "# VietTelex — bảng gõ tắt\n\"->\": →\n\":)\": 🙂\nk2: không hai\nq: \"\"trích\"\"\n"
        "sig: \"Thân mến,\\nPhil\"\nsp: \" có space \"\n");
    ShortcutTable phoneWant = {{"->", "→"}, {":)", "🙂"}, {"k2", "không hai"}, {"q", "\"trích\""},
                               {"sig", "Thân mến,\nPhil"}, {"sp", " có space "}};
    CHECK_EQ(phone, phoneWant);
    // BOM + CRLF; old unquoted files keep loading; unterminated quoted key = old rule.
    ShortcutTable crlf = parseShortcuts("\xEF\xBB\xBFko: không\r\ndc: được\r\n");
    CHECK_EQ(crlf.size(), size_t(2));
    CHECK_EQ(crlf["dc"], std::string("được"));
    ShortcutTable old = parseShortcuts("url: http://x\n\"bad: x\n");
    CHECK_EQ(old["url"], std::string("http://x"));
    CHECK_EQ(old.count(":D"), size_t(0));
    // A quoted key must be followed by ':'.
    CHECK_EQ(parseShortcuts("\":D\" 😀\n").size(), size_t(0));
}

void testHotkeyParse() {
    Hotkey h;
    CHECK(parseHotkey("Ctrl+space", h));
    CHECK_EQ(h.keysym, uint32_t(0x20));
    CHECK_EQ(h.mods, uint32_t(VT_MOD_CTRL));
    CHECK(parseHotkey("ctrl+shift+Z", h));
    CHECK_EQ(h.keysym, uint32_t('z'));
    CHECK_EQ(h.mods, uint32_t(VT_MOD_CTRL | VT_MOD_SHIFT));
    CHECK(parseHotkey("F12", h));
    CHECK_EQ(h.keysym, uint32_t(0xffc9));
    CHECK(!parseHotkey("Super+space", h));   // GNOME's
    CHECK(!parseHotkey("", h));
    CHECK(!parseHotkey("a", h));
    CHECK(!parseHotkey("Hyper+x", h));
    // What the settings app's key capture stores (GTK keyval after Shift = the keysym the
    // frontend receives): Ctrl+Shift+2 on US = "at", Ctrl+Shift+. = "greater", arrows.
    CHECK(parseHotkey("Ctrl+Shift+at", h));
    CHECK_EQ(h.keysym, uint32_t('@'));
    CHECK_EQ(h.mods, uint32_t(VT_MOD_CTRL | VT_MOD_SHIFT));
    CHECK(parseHotkey("Ctrl+Shift+greater", h));
    CHECK_EQ(h.keysym, uint32_t('>'));
    CHECK(parseHotkey("Alt+Left", h));
    CHECK_EQ(h.keysym, uint32_t(ks::Left));
    CHECK(parseHotkey("Ctrl++", h));
    CHECK_EQ(h.keysym, uint32_t('+'));
    CHECK(parseHotkey("Shift+F9", h));
    // Printable keys need Ctrl/Alt/Super (Shift+a would swallow capital A); without any
    // modifier only F1–F24; no duplicate modifiers; F-key names exact.
    CHECK(!parseHotkey("Shift+a", h));
    CHECK(!parseHotkey("Shift+space", h));
    CHECK(!parseHotkey("Shift+exclam", h));
    CHECK(!parseHotkey("Tab", h));
    CHECK(!parseHotkey("Left", h));
    CHECK(!parseHotkey("Ctrl+Ctrl+a", h));
    CHECK(!parseHotkey("Ctrl+F1x", h));
    CHECK(!parseHotkey("Ctrl+F25", h));
    CHECK(!parseHotkey("Ctrl+KP_1", h));
    CHECK_EQ(hotkeyLabel("Ctrl+Shift+at"), std::string("Ctrl+Shift+@"));
    CHECK_EQ(hotkeyLabel("Ctrl++"), std::string("Ctrl++"));
    // The session matches the stored keysym against the delivered one.
    Settings st;
    st.toggleHotkey = "Ctrl+Shift+at";
    Session s;
    s.applySettings(st);
    KeyEvent ev;
    ev.keysym = '@';
    ev.mods = VT_MOD_CTRL | VT_MOD_SHIFT;
    CHECK(s.isToggleHotkey(ev));
    ev.keysym = '2';
    CHECK(!s.isToggleHotkey(ev));
}

// MARK: - Surrounding safety (terminals, generic app ids, selections)

// Like a terminal / conhost behind IBus: advertises surrounding text but only ever reports
// an empty one, and cannot delete before the caret (a delete request is simply dropped).
struct TerminalStore : Mock {
    bool textBeforeCursor(std::string &out) override { out.clear(); return true; }
    long reportedCharsBeforeCursor() override { return 0; }
    void deleteBeforeCursor(int) override { ++deletes; }
};

// What a frontend does on focus: resolve the policy, push it into the Session.
void applyPolicy(Session &s, InputContext &ic, const std::string &app, const Settings &st, bool proven) {
    AppPolicy p = resolveAppPolicy(app, st, proven);
    s.applySettings(st);
    s.setPassthrough(p.off, ic);
    s.setDisplayMode(p.mode, ic);
    s.setSurroundingEdits(p.allowSurroundingEdits);
}

void testUnknownAppIdsArePreeditWithoutEdits() {
    Settings s;
    s.displayMode = DisplayMode::Surrounding;
    for (const char *id : {"", "default", "gnome-shell", "GNOME-Shell", "QIBusInputContext", "xim", "XIM"}) {
        CHECK(isUnknownAppId(id));
        AppPolicy p = resolveAppPolicy(id, s, false);
        CHECK(p.mode == DisplayMode::Preedit);
        CHECK(!p.allowSurroundingEdits);
    }
    CHECK(!isUnknownAppId("gedit"));
    // a "surrounding" pin on a generic id covers every app behind it: ignored
    s.appModes["default"] = "surrounding";
    CHECK(resolveAppPolicy("default", s, false).mode == DisplayMode::Preedit);
    // gnome-shell (GNOME Wayland shared context) stays preedit even with text proven
    AppPolicy gs = resolveAppPolicy("gnome-shell", s, true);
    CHECK(gs.mode == DisplayMode::Preedit);
    CHECK(!gs.allowSurroundingEdits);
    // user picked Preedit: an unproven unknown app still may not read back text
    s.displayMode = DisplayMode::Preedit;
    CHECK(!resolveAppPolicy("default", s, false).allowSurroundingEdits);
    // and the Session honours it: no re-edit, no ⌫ reopen, no delete
    Session ss;
    Mock m;
    applyPolicy(ss, m, "default", s, false);
    m.doc = "toan";
    type(ss, m, ">s");
    CHECK_EQ(m.screen(), std::string("toans"));
    ss.finish(m);
    m.doc.clear();
    type(ss, m, "thays <a");
    CHECK_EQ(m.screen(), std::string("tháya"));
    CHECK_EQ(m.deletes, 0);
}

void testProvenUnknownAppAllowed() {
    Settings s;
    s.displayMode = DisplayMode::Surrounding;
    for (const char *id : {"default", "", "xim", "qibusinputcontext"}) {
        AppPolicy p = resolveAppPolicy(id, s, true);
        CHECK(p.mode == DisplayMode::Surrounding);
        CHECK(p.allowSurroundingEdits);
    }
    s.displayMode = DisplayMode::Preedit;
    CHECK(resolveAppPolicy("default", s, true).allowSurroundingEdits);
    Session ss;
    Mock m;
    applyPolicy(ss, m, "default", s, true);
    m.doc = "toi toan";
    type(ss, m, ">s ");
    CHECK_EQ(m.screen(), std::string("toi toán "));
}

void testTerminalStoreTypesVietnamese() {
    const std::string want = "thử gõ tiếng việt";
    for (auto user : {DisplayMode::Preedit, DisplayMode::Surrounding}) {
        for (const char *app : {"default", "gnome-terminal-server", "org.kde.konsole", "kitty", "xim", "vte-2.91"}) {
            Settings st;
            st.displayMode = user;
            Session s;
            TerminalStore t;
            applyPolicy(s, t, app, st, false);  // nothing proven: the client never sent text
            CHECK(s.displayMode() == DisplayMode::Preedit);
            type(s, t, "thuwr gox tieengs vieetj");
            s.finish(t);
            if (t.doc == want && t.deletes == 0) { ++g_pass; continue; }
            ++g_fail;
            std::fprintf(stderr, "terminal [%s] %s: got [%s] deletes=%d\n", app,
                         user == DisplayMode::Preedit ? "preedit" : "surrounding", t.doc.c_str(), t.deletes);
        }
        // even a terminal claiming proven text is forced to preedit without edits
        Settings st;
        st.displayMode = user;
        AppPolicy p = resolveAppPolicy("kitty", st, true);
        CHECK(p.mode == DisplayMode::Preedit);
        CHECK(!p.allowSurroundingEdits);
    }
}

void testSelectionBlocksDeleteAndReEdit() {
    for (auto mode : {DisplayMode::Preedit, DisplayMode::Surrounding}) {
        // re-edit: caret after "toan", but "toan" is selected (Ctrl+L / autocomplete)
        Session s;
        Mock m;
        s.setDisplayMode(mode, m);
        m.doc = "toan";
        m.selection = true;
        type(s, m, ">s");
        CHECK_EQ(m.deletes, 0);
        CHECK(m.screen() != std::string("toán"));
        // reopen: "tháy" ␣ then a selection appears → ⌫ must go to the app
        Session r;
        Mock n;
        r.setDisplayMode(mode, n);
        type(r, n, "thays ");
        n.selection = true;
        int before = n.deletes;
        type(r, n, "<");
        CHECK_EQ(n.deletes, before);
    }
    // Surrounding mid-word: a key needing a delete while a selection exists is typed
    // literally instead (the delete would eat the selection)
    Session s;
    Mock m;
    s.setDisplayMode(DisplayMode::Surrounding, m);
    type(s, m, "vie");
    m.selection = true;
    int before = m.deletes;
    type(s, m, "e");
    CHECK_EQ(m.deletes, before);
    CHECK_EQ(m.doc, std::string("viee"));
    // ⌫ with a selection: no delete of ours, the app's own ⌫ handles it
    m.selection = false;
    type(s, m, "s");
    m.selection = true;
    before = m.deletes;
    type(s, m, "<");
    CHECK_EQ(m.deletes, before);
}

// GTK3 (no anchor in surrounding text): "toi di hoc" selected (Ctrl+A / mouse), then a tone
// key. Only the thorough check (PRIMARY against the caret) sees the selection — every
// reach-back must honour it, and it must only be asked right before one.
void testGtk3SelectionBlocksReachBack() {
    for (auto mode : {DisplayMode::Preedit, DisplayMode::Surrounding}) {
        // re-edit: the key replaces the selection, "hoc" is not touched
        Session s;
        Mock m;
        s.setDisplayMode(mode, m);
        m.doc = "toi di hoc";
        m.primarySelection = true;
        type(s, m, ">x");
        CHECK_EQ(m.deletes, 0);
        CHECK_EQ(m.screen(), std::string("toi di hocx"));  // the app puts "x" over the selection
        CHECK_EQ(m.thoroughAsks, 1);
        // nothing selected: re-edit as usual
        Session r;
        Mock n;
        r.setDisplayMode(mode, n);
        n.doc = "toi di hoc";
        type(r, n, ">j ");
        CHECK_EQ(n.screen(), std::string("toi di học "));
        CHECK_EQ(n.thoroughAsks, 1);
        // re-edit not possible (no word before the caret): never asked
        Session q;
        Mock o;
        q.setDisplayMode(mode, o);
        o.doc = "toi ";
        o.primarySelection = true;
        type(q, o, ">x");
        CHECK_EQ(o.thoroughAsks, 0);
        // ⌫ reopen: "tháy" ␣, then a selection at the caret → the app's own ⌫
        Session u;
        Mock w;
        u.setDisplayMode(mode, w);
        type(u, w, "thays ");
        w.primarySelection = true;
        int before = w.deletes;
        type(u, w, "<");
        CHECK_EQ(w.deletes, before);
        CHECK_EQ(w.screen(), std::string("tháy"));
        // plain typing never asks (no per-key cost)
        Session v;
        Mock x;
        v.setDisplayMode(mode, x);
        type(v, x, "tieengs vieetj nam ");
        CHECK_EQ(x.screen(), std::string("tiếng việt nam "));
        CHECK_EQ(x.thoroughAsks, 0);
    }
    // Surrounding: shortcut expansion and auto-restore delete the word — not with a selection
    Settings st;
    auto t = std::make_shared<ShortcutTable>();
    (*t)["ko"] = "không";
    st.shortcuts = t;
    {
        Session s;
        Mock m;
        s.applySettings(st);
        s.setDisplayMode(DisplayMode::Surrounding, m);
        type(s, m, "ko");
        m.primarySelection = true;
        int before = m.deletes;
        type(s, m, " ");
        CHECK_EQ(m.deletes, before);
        CHECK_EQ(m.doc, std::string("ko "));
        CHECK_EQ(m.thoroughAsks, 1);
        m.primarySelection = false;
        type(s, m, "ko ");
        CHECK_EQ(m.doc, std::string("ko không "));
    }
    {
        Session s;
        Mock m;
        s.setDisplayMode(DisplayMode::Surrounding, m);
        type(s, m, "google");
        std::string typed = m.doc;
        m.primarySelection = true;
        int before = m.deletes;
        type(s, m, " ");
        CHECK_EQ(m.deletes, before);
        CHECK_EQ(m.doc, typed + " ");
        m.primarySelection = false;
        type(s, m, "google ");
        CHECK_EQ(m.doc, typed + " google ");
    }
    // Preedit: shortcuts / auto-restore commit, no reach-back → never asked
    {
        Session s;
        Mock m;
        s.applySettings(st);
        type(s, m, "ko google ");
        CHECK_EQ(m.doc, std::string("không google "));
        CHECK_EQ(m.thoroughAsks, 0);
    }
}

void testModeSwitchWaitsForWordEnd() {
    // IBus: the first surrounding update (→ Surrounding allowed) lands after key 1 of a word
    for (auto from : {DisplayMode::Preedit, DisplayMode::Surrounding}) {
        auto to = from == DisplayMode::Preedit ? DisplayMode::Surrounding : DisplayMode::Preedit;
        Session s;
        Mock m;
        s.setDisplayMode(from, m);
        type(s, m, "t");
        s.setDisplayMode(to, m);
        CHECK(s.displayMode() == from);   // deferred, word not split
        type(s, m, "huwr ");
        CHECK_EQ(m.screen(), std::string("thử "));
        type(s, m, "gox ");
        CHECK(s.displayMode() == to);
        CHECK_EQ(m.screen(), std::string("thử gõ "));
    }
}

void testForcedPreeditList() {
    for (const char *id : {"firefox", "firefox-esr", "librewolf", "zen", "thunderbird", "gnome-shell",
                           "org.mozilla.firefox", "gnome-terminal-server", "kgx", "ptyxis", "org.gnome.Ptyxis",
                           "konsole", "kitty", "alacritty", "wezterm", "foot", "xterm", "tilix", "code",
                           "codium", "chromium", "chromium-browser", "google-chrome", "brave-browser",
                           "vte-2.91", "/usr/bin/xfce4-terminal"}) {
        if (isForcedPreeditApp(id)) { ++g_pass; continue; }
        ++g_fail;
        std::fprintf(stderr, "not forced preedit: %s\n", id);
    }
    CHECK(!isForcedPreeditApp("gedit"));
    CHECK(!isForcedPreeditApp("org.gnome.texteditor"));
}

void testMoreGenericIdsAndSnap() {
    for (const char *id : {"wayland", "sdl2_application", "SDL3_Application", "gtk-im", "(12345)",
                           "gtk3-im:(4242)", "4242"}) {
        if (isUnknownAppId(id)) { ++g_pass; continue; }
        ++g_fail;
        std::fprintf(stderr, "not unknown: %s\n", id);
    }
    CHECK_EQ(normalizeAppId("gtk3-im:gnome-text-editor"), std::string("gnome-text-editor"));
    CHECK_EQ(normalizeAppId("firefox_firefox"), std::string("firefox"));
    CHECK_EQ(normalizeAppId("code_code"), std::string("code"));
    CHECK_EQ(normalizeAppId("libreoffice_writer"), std::string("libreoffice_writer"));
    CHECK_EQ(normalizeAppId("sdl2_application"), std::string("sdl2_application"));
    CHECK(isForcedPreeditApp("firefox_firefox"));
    CHECK(isForcedPreeditApp("gnome-shell-overview"));
    Settings s;
    s.displayMode = DisplayMode::Surrounding;
    CHECK(resolveAppPolicy("gnome-shell-overview", s, true).mode == DisplayMode::Preedit);
    CHECK(!resolveAppPolicy("wayland", s, false).allowSurroundingEdits);
}

void testFieldHints() {
    Settings s;
    s.displayMode = DisplayMode::Surrounding;
    FieldHints f;
    f.terminal = true;
    AppPolicy p = resolveAppPolicy("gedit", s, true, f);
    CHECK(p.mode == DisplayMode::Preedit);
    CHECK(!p.allowSurroundingEdits);
    CHECK(!p.passthrough);
    s.appModes["gedit"] = "surrounding";  // a pin does not beat the field type
    CHECK(resolveAppPolicy("gedit", s, true, f).mode == DisplayMode::Preedit);
    s.appModes.clear();
    f = FieldHints();
    f.urlOrEmail = true;
    CHECK(resolveAppPolicy("gedit", s, true, f).mode == DisplayMode::Preedit);
    CHECK(!resolveAppPolicy("gedit", s, true, f).passthrough);
    f = FieldHints();
    f.numeric = true;
    p = resolveAppPolicy("gedit", s, true, f);
    CHECK(p.passthrough);
    CHECK(p.rememberState);
    f = FieldHints();
    f.sensitive = true;
    p = resolveAppPolicy("gedit", s, true, f);
    CHECK(p.passthrough);
    CHECK(!p.rememberState);
    p = resolveAppPolicy("gedit", s, true);
    CHECK(p.mode == DisplayMode::Surrounding);
    CHECK(!p.passthrough);
    CHECK(p.rememberState);
    // and a passthrough field types literally
    Session ss;
    Mock m;
    ss.setPassthrough(resolveAppPolicy("gedit", s, true, f).passthrough, m);
    type(ss, m, "vieejt 123");
    CHECK_EQ(m.screen(), std::string("vieejt 123"));
}

void testDefaultOffApps() {
    Settings s;
    for (const char *id : {"remmina", "org.remmina.Remmina", "AnyDesk", "rustdesk", "VirtualBoxVM", "vmware",
                           "remote-viewer", "gnome-connections", "org.gnome.Connections", "krdc", "xfreerdp",
                           "wlfreerdp", "moonlight", "parsec"}) {
        if (isDefaultOffApp(id) && resolveAppPolicy(id, s, true).off) { ++g_pass; continue; }
        ++g_fail;
        std::fprintf(stderr, "not default-off: %s\n", id);
    }
    CHECK(!isDefaultOffApp("gedit"));
    CHECK(!isDefaultOffApp("wine"));
    CHECK(!resolveAppPolicy("gedit", s, true).off);
    s.appModes["remmina"] = "preedit";  // [app_modes] overrides the built-in list
    CHECK(!resolveAppPolicy("remmina", s, true).off);
}

// Regression (user Zorin OS, 08/10/2026): Word chạy qua Wine gõ ra "he1 lo6" — Wine từng nằm
// trong danh sách mặc định tắt. Wine = app chạy tại máy ⇒ gõ tiếng Việt, ép gạch chân (XIM).
void testWineAppsTypeVietnamese() {
    Settings s;
    for (const char *id : {"wine64-preloader", "wine-preloader", "notepad.exe", "WINWORD.EXE",
                           "C:\\Program Files\\App\\App.EXE"}) {
        CHECK(isWineApp(id));
        CHECK(!isDefaultOffApp(id));
        AppPolicy p = resolveAppPolicy(id, s, true);
        CHECK(!p.off);
        CHECK(p.mode == DisplayMode::Preedit);
        CHECK(!p.allowSurroundingEdits);
    }
    CHECK(!isWineApp("wine"));
    CHECK(!isWineApp("gedit"));
    s.appModes["notepad.exe"] = "off";  // user can still turn it off
    CHECK(resolveAppPolicy("notepad.exe", s, true).off);
}

// Regression (user Zorin OS, Wayland, 08/10/2026): Messenger web trong Cốc Cốc lặp chữ ("đợi đợi")
// và ⌫ sau dấu cách xoá 2 lần — Cốc Cốc không nằm trong nhóm Chromium ⇒ dùng surrounding,
// mà Chromium báo chữ quanh con trỏ không tin được. Mọi trình duyệt Chromium + PWA ⇒ preedit.
void testChromiumFamilyForcedPreedit() {
    Settings s;
    for (const char *id : {"coccoc", "coccoc.desktop", "Coccoc", "coccoc-browser", "yandex-browser",
                           "thorium-browser", "ungoogled-chromium", "microsoft-edge-beta",
                           "cromite", "cromite-browser", "helium", "helium-browser", "slimjet",
                           "slimjet-browser", "flashpeak-slimjet", "net.imput.helium",
                           "crx_bfgdeeglghbfcmhpjlmaajeolejfojjl", "chrome-abcdefghijklmnop-Default",
                           "brave-abcdefghijklmnop-Default", "msedge-abcdefghijklmnop-Default"}) {
        CHECK(isForcedPreeditApp(id));
        AppPolicy p = resolveAppPolicy(id, s, true);
        CHECK(!p.allowSurroundingEdits);
    }
    CHECK(!isForcedPreeditApp("chrome-remote-desktop-host"));
    CHECK(!isForcedPreeditApp("gedit"));
}

// Regression (10/2026): Google Antigravity (Electron, VS Code fork) gạch chân lẫn lộn vì không
// nằm trong nhóm Chromium. Id thật IME thấy: binary/program, WM_CLASS, .desktop, Flatpak, snap.
void testElectronAppsAreChromium() {
    for (const char *id : {
             // AI editors
             "antigravity", "Antigravity", "antigravity.desktop", "windsurf", "Windsurf", "kiro",
             "trae", "Trae", "void", "PearAI", "positron",
             // Flatpak / WM_CLASS forms the shortName rule alone misses or already covers
             "com.google.Chrome", "com.visualstudio.code", "com.microsoft.VSCode", "com.microsoft.VSCode.desktop", "com.discordapp.Discord", "com.slack.Slack",
             "com.brave.Browser", "com.microsoft.Edge", "ru.yandex.Browser", "Vivaldi-flatpak",
             "io.github.ungoogled_software.ungoogled_chromium", "org.signal.Signal", "Signal",
             "im.riot.Riot", "Element", "com.mattermost.Desktop", "chat.rocket.RocketChat",
             "Rocket.Chat", "com.github.IsmaelMartinez.teams_for_linux", "dev.vencord.Vesktop",
             "io.github.mimbrero.WhatsAppDesktop", "com.sindresorhus.Caprine", "org.ferdium.Ferdium",
             "BeeperTexts", "zalo-linux_zalo-linux", "bytedance-feishu-stable", "feishu",
             "com.logseq.Logseq", "net.cozic.joplin_desktop", "appimagekit-joplin",
             "appimagekit_0123456789abcdef0123456789abcdef-Logseq", "io.typora.Typora", "marktext",
             "com.notesnook.Notesnook", "io.anytype.anytype", "com.bitwarden.desktop",
             "bitwarden-desktop", "com.onepassword.OnePassword", "1password", "Postman",
             "rest.insomnia.Insomnia", "io.github.Figma_Linux.figma_linux", "io.github.shiftey.Desktop",
             "io.github.shiftey.Desktop.desktop", "com.mattermost.Desktop.desktop",
             "com.bitwarden.desktop.desktop",
             "github-desktop", "com.axosoft.GitKraken", "com.spotify.Client", "spotify",
             "com.anthropic.Claude", "claude-desktop", "notion-app", "electron37", "Wavebox",
             "min-browser"}) {
        if (isChromiumApp(id) && isForcedPreeditApp(id)) { ++g_pass; continue; }
        ++g_fail;
        std::fprintf(stderr, "not Chromium/Electron: %s\n", id);
    }
    // not Chromium: GTK WebKit / Qt WebEngine wrappers, Gecko, Zed (GPUI), generic Flatpak tails
    for (const char *id : {"com.github.eneshecan.WhatsAppForLinux", "com.rtosta.zapzap", "dev.zed.Zed",
                           "org.mozilla.firefox", "org.gnome.Desktop", "com.example.Browser",
                           "org.kde.Client", "electron-cash", "appimagekit-gimp", "appimagekit"}) {
        if (!isChromiumApp(id)) { ++g_pass; continue; }
        ++g_fail;
        std::fprintf(stderr, "wrongly Chromium: %s\n", id);
    }
}

void testMoreForcedPreedit() {
    for (const char *id : {"krunner", "org.kde.krunner", "plasmashell", "jetbrains-idea", "jetbrains-pycharm",
                           "idea", "java", "wps", "wpp", "et", "wpsoffice", "desktopeditors", "steam"}) {
        if (isForcedPreeditApp(id)) { ++g_pass; continue; }
        ++g_fail;
        std::fprintf(stderr, "not forced preedit: %s\n", id);
    }
}

size_t indexOf(const std::vector<std::string> &v, const std::string &x) {
    for (size_t i = 0; i < v.size(); ++i)
        if (v[i] == x) return i;
    return v.size();
}

void testCommitBeforeHidingPreedit() {
    // endWord (space)
    {
        Session s;
        Mock m;
        type(s, m, "vieejt ");
        size_t c = indexOf(m.log, "commit:việt"), h = indexOf(m.log, "pre:");
        CHECK(c < m.log.size());
        CHECK(c < h);
    }
    // finish (focus out / click)
    {
        Session s;
        Mock m;
        type(s, m, "vieejt");
        s.finish(m);
        size_t c = indexOf(m.log, "commit:việt"), h = indexOf(m.log, "pre:");
        CHECK(c < m.log.size());
        CHECK(c < h);
    }
    // shortcut expansion
    {
        Settings st;
        auto t = std::make_shared<ShortcutTable>();
        (*t)["ko"] = "không";
        st.shortcuts = t;
        Session s;
        Mock m;
        s.applySettings(st);
        type(s, m, "ko ");
        CHECK_EQ(m.screen(), std::string("không "));
        CHECK(indexOf(m.log, "commit:không") < indexOf(m.log, "pre:"));
    }
    // overflow (> 32 keys in one word)
    {
        Session s;
        Mock m;
        type(s, m, std::string(40, 'b'));
        size_t c = m.log.size(), h = m.log.size();
        for (size_t i = 0; i < m.log.size(); ++i) {
            if (c == m.log.size() && m.log[i].rfind("commit:", 0) == 0) c = i;
            if (c != m.log.size() && m.log[i] == "pre:") { h = i; break; }
        }
        CHECK(c < m.log.size());
        CHECK(c < h);
        CHECK(m.screen().size() >= 40);
    }
}

void testDeleteOnlyEditSendsEmptyCommit() {
    // Surrounding ⌫ reopen: delete the space, insert nothing → empty commit follows
    Session s;
    Mock m;
    s.setDisplayMode(DisplayMode::Surrounding, m);
    type(s, m, "thays ");
    m.log.clear();
    type(s, m, "<");
    CHECK(m.log.size() >= 2);
    if (m.log.size() >= 2) {
        CHECK_EQ(m.log[0], std::string("del:1"));
        CHECK_EQ(m.log[1], std::string("commit:"));
    }
    type(s, m, "a");
    CHECK_EQ(m.screen(), std::string("thấy"));
    // a delete that inserts text needs no extra empty commit
    Session s2;
    Mock m2;
    s2.setDisplayMode(DisplayMode::Surrounding, m2);
    type(s2, m2, "vie");
    m2.log.clear();
    type(s2, m2, "e");
    CHECK(indexOf(m2.log, "commit:") == m2.log.size());
}

// MARK: - App policy / state

void testAppPolicy() {
    Settings s;
    CHECK_EQ(normalizeAppId("/usr/bin/Konsole"), std::string("konsole"));
    CHECK_EQ(normalizeAppId("gtk3-im:gedit"), std::string("gedit"));
    CHECK_EQ(normalizeAppId("org.gnome.TextEditor.desktop"), std::string("org.gnome.texteditor"));
    CHECK(resolveAppPolicy("gedit", s, true).mode == DisplayMode::Preedit);   // default preedit
    s.displayMode = DisplayMode::Surrounding;
    CHECK(resolveAppPolicy("gedit", s, true).mode == DisplayMode::Surrounding);
    CHECK(resolveAppPolicy("gedit", s, false).mode == DisplayMode::Preedit);  // no surrounding
    CHECK(resolveAppPolicy("org.kde.konsole", s, true).mode == DisplayMode::Preedit);
    CHECK(resolveAppPolicy("kitty", s, true).mode == DisplayMode::Preedit);
    CHECK(resolveAppPolicy("libreoffice-writer", s, true).mode == DisplayMode::Preedit);
    s.appModes["kitty"] = "surrounding";
    CHECK(resolveAppPolicy("kitty", s, true).mode == DisplayMode::Surrounding);  // user pin wins
    s.displayMode = DisplayMode::Preedit;
    s.appModes["gedit"] = "surrounding";
    CHECK(resolveAppPolicy("gedit", s, true).mode == DisplayMode::Surrounding);
    s.appModes["steam"] = "off";
    CHECK(resolveAppPolicy("Steam", s, true).off);
}

// GetRunningApplications reply bodies, as gnome-shell 42 (Ubuntu 22.04) and 46 (24.04) send
// them (js/misc/introspect.js: key = ShellApp id, "active-on-seats" only on the focused app,
// "sandboxed-app-id" for Flatpak/Snap windows; the format is the same in both versions).
std::vector<gnome::RunningApp> parseFixture(const char *text, bool *ok = nullptr) {
    GError *err = nullptr;
    GVariant *v = g_variant_parse(nullptr, text, nullptr, nullptr, &err);
    std::vector<gnome::RunningApp> apps;
    bool r = false;
    if (v) {
        r = gnome::parseRunningApplications(v, apps);
        g_variant_unref(v);
    } else {
        std::fprintf(stderr, "fixture parse error: %s\n", err->message);
        g_clear_error(&err);
        ++g_fail;
    }
    if (ok) *ok = r;
    return apps;
}

const char *kGnome42Gedit =
    "({'org.gnome.Nautilus.desktop': @a{sv} {}, "
    "'org.gnome.gedit.desktop': {'active-on-seats': <['seat0']>}, "
    "'firefox_firefox.desktop': {'sandboxed-app-id': <'firefox'>}, "
    "'org.gnome.Terminal.desktop': @a{sv} {}},)";
const char *kGnome42Terminal =
    "({'org.gnome.gedit.desktop': @a{sv} {}, "
    "'org.gnome.Terminal.desktop': {'active-on-seats': <['seat0']>}},)";
const char *kGnome46Flatpak =
    "({'org.gnome.TextEditor.desktop': @a{sv} {}, 'window:7': @a{sv} {}, "
    "'org.mozilla.firefox.desktop': {'active-on-seats': <['seat0']>, 'sandboxed-app-id': <'org.mozilla.firefox'>}},)";
const char *kGnome46TextEditor =
    "({'org.gnome.TextEditor.desktop': {'active-on-seats': <['seat0']>}, "
    "'org.gnome.Ptyxis.desktop': @a{sv} {}},)";

void testGnomePayloads() {
    bool ok = false;
    auto a = parseFixture(kGnome42Gedit, &ok);
    CHECK(ok);
    CHECK_EQ(a.size(), size_t(4));
    CHECK_EQ(gnome::focusedAppId(a), std::string("org.gnome.gedit"));
    CHECK_EQ(gnome::focusedAppId(parseFixture(kGnome42Terminal)), std::string("org.gnome.terminal"));
    a = parseFixture(kGnome46Flatpak);
    CHECK_EQ(gnome::focusedAppId(a), std::string("org.mozilla.firefox"));
    bool sandboxSeen = false;
    for (auto &x : a) sandboxSeen = sandboxSeen || x.sandboxedAppId == "org.mozilla.firefox";
    CHECK(sandboxSeen);
    CHECK_EQ(gnome::focusedAppId(parseFixture(kGnome46TextEditor)), std::string("org.gnome.texteditor"));
    // bare a{sa{sv}} (no tuple) is accepted too
    CHECK_EQ(gnome::focusedAppId(parseFixture("{'code_code.desktop': {'active-on-seats': <['seat0']>}}")),
             std::string("code"));
    // window-backed app (no .desktop): no id — unless the sandbox names it
    CHECK_EQ(gnome::focusedAppId(parseFixture("({'window:12': {'active-on-seats': <['seat0']>}},)")), std::string());
    CHECK_EQ(gnome::focusedAppId(parseFixture(
                 "({'window:3': {'active-on-seats': <['seat0']>, 'sandboxed-app-id': <'com.example.Notes'>}},)")),
             std::string("com.example.notes"));
    // nothing focused (desktop / shell popup), empty seat list, two "focused" apps
    CHECK_EQ(gnome::focusedAppId(parseFixture("({'org.gnome.Nautilus.desktop': @a{sv} {}},)")), std::string());
    CHECK_EQ(gnome::focusedAppId(parseFixture("({'org.gnome.gedit.desktop': {'active-on-seats': <@as []>}},)")),
             std::string());
    CHECK_EQ(gnome::focusedAppId(parseFixture("({'a.desktop': {'active-on-seats': <['seat0']>}, "
                                              "'b.desktop': {'active-on-seats': <['seat1']>}},)")),
             std::string());
    // foreign payloads: other gnome-shell replies seen by the monitor
    parseFixture("('ok',)", &ok);
    CHECK(!ok);
    parseFixture("({uint64 1: {'app-id': <'x'>}},)", &ok);  // GetWindows (a{ta{sv}})
    CHECK(!ok);
    CHECK(!gnome::parseRunningApplications(nullptr, a));
}

void testGnomeFocusTracker() {
    gnome::FocusTracker t;
    auto gedit = parseFixture(kGnome42Gedit), term = parseFixture(kGnome42Terminal);
    CHECK_EQ(t.resolve("gnome-shell"), std::string("gnome-shell"));  // nothing known yet
    CHECK_EQ(t.resolve("gtk3-im:gedit"), std::string("gtk3-im:gedit"));
    // focus change: signal → portal calls → reply to the portal
    CHECK(!t.onAppsChanged());
    t.onCall(":1.40", 7);
    CHECK_EQ(t.resolve("default"), std::string("default"));  // pending
    // The monitor parses a gnome-shell reply only when it answers a call seen.
    CHECK(t.expectsReply(":1.40", 7));
    CHECK(!t.expectsReply(":1.41", 7));
    CHECK(!t.expectsReply(":1.40", 8));
    CHECK(!t.onReply(":1.41", 7, gedit));                     // not the caller
    CHECK(!t.onReply(":1.40", 8, gedit));                     // not that call
    CHECK(t.onReply(":1.40", 7, gedit));
    CHECK(!t.expectsReply(":1.40", 7));  // answered
    CHECK_EQ(t.resolve("gnome-shell"), std::string("org.gnome.gedit"));
    CHECK_EQ(t.resolve("default"), std::string("org.gnome.gedit"));  // IBus 1.5.26
    CHECK_EQ(t.resolve("wayland"), std::string("org.gnome.gedit"));
    CHECK_EQ(t.resolve(""), std::string("org.gnome.gedit"));
    CHECK_EQ(t.resolve("kitty"), std::string("kitty"));  // a real id is never replaced
    CHECK(!t.onReply(":1.40", 7, term));                  // answered already
    // next switch: generic again until the new answer (no guessing from the old app)
    CHECK(t.onAppsChanged());
    CHECK_EQ(t.resolve("gnome-shell"), std::string("gnome-shell"));
    t.onCall(":1.40", 9);
    CHECK(t.onReply(":1.40", 9, term));
    CHECK_EQ(t.resolve("gnome-shell"), std::string("org.gnome.terminal"));
    // a call made BEFORE the latest signal: its answer is stale → still pending
    t.onCall(":1.40", 10);
    CHECK(t.onAppsChanged());
    t.onReply(":1.40", 10, gedit);
    CHECK(t.pending());
    CHECK_EQ(t.resolve("gnome-shell"), std::string("gnome-shell"));
    t.onCall(":1.40", 11);
    t.onReply(":1.40", 11, gedit);
    CHECK_EQ(t.resolve("gnome-shell"), std::string("org.gnome.gedit"));
    // overview beats the focused app
    CHECK(t.onOverview(true));
    CHECK(!t.onOverview(true));
    CHECK_EQ(t.resolve("gnome-shell"), std::string("gnome-shell-overview"));
    CHECK_EQ(t.resolve("gtk3-im:gedit"), std::string("gtk3-im:gedit"));
    CHECK(t.onOverview(false));
    CHECK_EQ(t.resolve("gnome-shell"), std::string("org.gnome.gedit"));
    // desktop focused (no active app) → generic
    t.onAppsChanged();
    t.onCall(":1.40", 12);
    t.onReply(":1.40", 12, parseFixture("({'org.gnome.gedit.desktop': @a{sv} {}},)"));
    CHECK_EQ(t.resolve("gnome-shell"), std::string("gnome-shell"));
    // many unanswered calls never grow without bound, and the newest still counts
    for (uint32_t i = 100; i < 200; ++i) t.onCall(":1.40", i);
    CHECK(t.onReply(":1.40", 199, term));
}

void testGnomeResolvedPolicy() {
    // The resolved id goes through the normal policy: no-underline where proven and safe.
    Settings s;
    s.displayMode = DisplayMode::Surrounding;
    gnome::FocusTracker t;
    auto answer = [&t](const char *fixture, uint32_t serial) {
        t.onAppsChanged();
        t.onCall(":1.9", serial);
        t.onReply(":1.9", serial, parseFixture(fixture));
    };
    // unknown: generic → preedit, no edits even with proven surrounding
    CHECK(resolveAppPolicy(t.resolve("gnome-shell"), s, true).mode == DisplayMode::Preedit);
    CHECK(!resolveAppPolicy(t.resolve("gnome-shell"), s, true).allowSurroundingEdits);
    answer(kGnome46TextEditor, 1);
    auto p = resolveAppPolicy(t.resolve("gnome-shell"), s, true);
    CHECK(p.mode == DisplayMode::Surrounding);
    CHECK(p.allowSurroundingEdits);
    CHECK(resolveAppPolicy(t.resolve("gnome-shell"), s, false).mode == DisplayMode::Preedit);  // unproven
    answer(kGnome42Terminal, 2);
    CHECK(resolveAppPolicy(t.resolve("default"), s, true).mode == DisplayMode::Preedit);  // terminal
    answer(kGnome46Flatpak, 3);
    CHECK(resolveAppPolicy(t.resolve("gnome-shell"), s, true).mode == DisplayMode::Preedit);  // Firefox
    answer(kGnome42Gedit, 4);
    t.onOverview(true);
    CHECK(resolveAppPolicy(t.resolve("gnome-shell"), s, true).mode == DisplayMode::Preedit);  // overview
    // per-app pins apply to the resolved id ("gedit" matches org.gnome.gedit's short name)
    t.onOverview(false);
    s.appModes["gedit"] = "off";
    CHECK(resolveAppPolicy(t.resolve("gnome-shell"), s, true).off);
}

void testGnomeSessionDetection() {
    CHECK(gnome::isGnomeWayland("ubuntu:GNOME", "wayland", nullptr));
    CHECK(gnome::isGnomeWayland("GNOME", "wayland", ""));
    CHECK(gnome::isGnomeWayland("GNOME-Classic:GNOME", nullptr, "wayland-0"));
    CHECK(!gnome::isGnomeWayland("ubuntu:GNOME", "x11", "wayland-0"));  // X11 session
    CHECK(!gnome::isGnomeWayland("KDE", "wayland", "wayland-0"));
    CHECK(!gnome::isGnomeWayland("GNOME-Flashback", "wayland", nullptr));
    CHECK(!gnome::isGnomeWayland(nullptr, "wayland", "wayland-0"));
    CHECK(!gnome::isGnomeWayland("GNOME", nullptr, nullptr));
    CHECK(gnome::isSharedShellClientId("gnome-shell"));
    CHECK(gnome::isSharedShellClientId("default"));
    CHECK(gnome::isSharedShellClientId("Wayland"));
    CHECK(gnome::isSharedShellClientId(""));
    CHECK(!gnome::isSharedShellClientId("gtk3-im:gedit"));
    CHECK(!gnome::isSharedShellClientId("gnome-shell-overview"));
    CHECK(!gnome::isSharedShellClientId("xim"));
}

void testAppStateStoreAndWatcher() {
    char tmpl[] = "/tmp/vt-test-XXXXXX";
    std::string dir = mkdtemp(tmpl);
    std::string path = dir + "/state/app-state";
    {
        AppStateStore st(path);
        st.load();
        CHECK(st.vietnamese("gedit", true));
        CHECK(!st.vietnamese("gedit", false));
        st.set("gedit", false);
        st.set("kitty", true);
    }
    AppStateStore st2(path);
    st2.load();
    CHECK(!st2.vietnamese("gedit", true));
    CHECK(st2.vietnamese("kitty", false));

    // live reload through inotify (atomic tmp + rename, as the settings app writes)
    std::string cdir = dir + "/cfg";
    SettingsWatcher w(cdir);
    CHECK(w.fd() >= 0);
    CHECK(!w.settings().vni);
    CHECK(writeFileAtomic(cdir + "/config.toml", "[typing]\ninput_method = \"vni\"\n"));
    CHECK(w.drain());
    CHECK(w.changedOnDisk());
    CHECK(w.reload().vni);
    CHECK(!w.changedOnDisk());
    CHECK(writeFileAtomic(cdir + "/shortcuts.yml", "ko: không\n"));
    CHECK(w.drain());
    CHECK_EQ(w.reload().shortcuts->at("ko"), std::string("không"));
    std::string cmd = "rm -rf '" + dir + "'";
    CHECK_EQ(std::system(cmd.c_str()), 0);
}

// Ids that name no app were stored and applied: GNOME "window:57" (→ "57"), a bare pid, the
// generic "default" / "gnome-shell" — a later app reusing that window number got the state.
void testAppStateStoreSkipsUnknownIds() {
    char tmpl[] = "/tmp/vt-test-XXXXXX";
    std::string dir = mkdtemp(tmpl);
    std::string path = dir + "/app-state";
    // A file written by an older version: the junk lines are dropped on load.
    CHECK(writeFileAtomic(path, "57\ten\n(1234)\ten\ndefault\ten\ngedit\ten\n"));
    AppStateStore st(path);
    st.load();
    CHECK_EQ(st.entries().size(), size_t(1));
    CHECK(!st.vietnamese("gedit", true));
    for (const char *id : {"window:57", "57", "(1234)", "default", "gnome-shell", "", "xim"}) {
        st.set(id, false);
        CHECK(st.vietnamese(id, true));  // never remembered, never looked up
        CHECK(!st.vietnamese(id, false));
    }
    CHECK_EQ(st.entries().size(), size_t(1));
    st.set("kitty", false);
    std::string text;
    CHECK(readFile(path, text));
    CHECK_EQ(text, std::string("gedit\ten\nkitty\ten\n"));
    std::string cmd = "rm -rf '" + dir + "'";
    CHECK_EQ(std::system(cmd.c_str()), 0);
}

// At most kMaxEntries apps; the least recently set one goes first, across restarts.
void testAppStateStoreCap() {
    char tmpl[] = "/tmp/vt-test-XXXXXX";
    std::string dir = mkdtemp(tmpl);
    std::string path = dir + "/app-state";
    const size_t cap = AppStateStore::kMaxEntries;
    {
        AppStateStore st(path);
        st.load();
        for (size_t i = 0; i < cap; ++i) st.set("app" + std::to_string(i), false);
        CHECK_EQ(st.entries().size(), cap);
        st.set("app0", true);  // changed → most recent
        st.set("new1", false);  // evicts app1 (app0 was set again)
        CHECK_EQ(st.entries().size(), cap);
        CHECK(st.vietnamese("app0", false));
        CHECK(st.vietnamese("app1", true) && !st.vietnamese("app1", false));  // gone: fallback
        CHECK(!st.vietnamese("app2", true));
    }
    AppStateStore st2(path);
    st2.load();
    CHECK_EQ(st2.entries().size(), cap);
    st2.set("new2", false);  // the order survived the restart: app2 is now the oldest
    CHECK(!st2.vietnamese("app2", false) && st2.vietnamese("app2", true));
    CHECK(!st2.vietnamese("app3", true));
    CHECK(st2.vietnamese("app0", false));
    CHECK(!st2.vietnamese("new1", true));
    std::string cmd = "rm -rf '" + dir + "'";
    CHECK_EQ(std::system(cmd.c_str()), 0);
}

// The Fcitx5 addon resolves the field policy before each key only when an input changed.
void testPolicyCache() {
    PolicyCache c;
    CHECK(!c.unchanged("gedit", 1, 0x10, true, 0, "dbus", "gedit"));  // first: resolve
    CHECK(c.unchanged("gedit", 1, 0x10, true, 0, "dbus", "gedit"));   // same key after key
    CHECK(!c.unchanged("kitty", 1, 0x10, true, 0, "dbus", "gedit"));  // app
    CHECK(c.unchanged("kitty", 1, 0x10, true, 0, "dbus", "gedit"));
    CHECK(!c.unchanged("kitty", 2, 0x10, true, 0, "dbus", "gedit"));  // settings reloaded
    CHECK(!c.unchanged("kitty", 2, 0x11, true, 0, "dbus", "gedit"));  // capability bits
    CHECK(!c.unchanged("kitty", 2, 0x11, false, 0, "dbus", "gedit"));  // surrounding validity
    CHECK(!c.unchanged("kitty", 2, 0x11, false, 50, "dbus", "gedit"));  // shell version known
    CHECK(!c.unchanged("kitty", 2, 0x11, false, 50, "ibus", "gedit"));  // frontend
    CHECK(!c.unchanged("kitty", 2, 0x11, false, 50, "ibus", "gnome-shell"));  // program
    CHECK(c.unchanged("kitty", 2, 0x11, false, 50, "ibus", "gnome-shell"));
    c.invalidate();  // new focus
    CHECK(!c.unchanged("kitty", 2, 0x11, false, 50, "ibus", "gnome-shell"));
    // Equal inputs give an equal policy (what makes skipping safe).
    Settings s;
    s.noUnderline = NoUnderline::ForwardKeys;
    FieldHints f;
    f.host = ClientHost::FcitxWayland;
    for (const char *app : {"google-chrome", "gedit", "kitty", "window:3"}) {
        AppPolicy a = resolveAppPolicy(app, s, true, f), b = resolveAppPolicy(app, s, true, f);
        CHECK(a.mode == b.mode && a.off == b.off && a.passthrough == b.passthrough &&
              a.allowSurroundingEdits == b.allowSurroundingEdits && a.deleteWithKeys == b.deleteWithKeys);
    }
}

// Settings generation, shortcuts.yml parsed only when it changed, no stat per focus while
// inotify watches the directory.
void testWatcherReloadCosts() {
    char tmpl[] = "/tmp/vt-test-XXXXXX";
    std::string dir = mkdtemp(tmpl);
    std::string cdir = dir + "/cfg";
    CHECK(writeFileAtomic(cdir + "/shortcuts.yml", "ko: không\n"));
    SettingsWatcher w(cdir);
    CHECK(w.watching());
    uint64_t g0 = w.generation();
    CHECK_EQ(w.shortcutParses(), 1);
    auto table = w.settings().shortcuts;
    CHECK(writeFileAtomic(cdir + "/config.toml", "[typing]\ninput_method = \"vni\"\n"));
    CHECK(!w.changedOnDiskUnwatched());  // inotify reports it: no stat at focus-in
    CHECK(w.drain());
    CHECK(w.reload().vni);
    CHECK(w.generation() > g0);
    CHECK_EQ(w.shortcutParses(), 1);  // config.toml alone: same table, not parsed again
    CHECK(w.settings().shortcuts == table);
    CHECK_EQ(w.settings().shortcuts->at("ko"), std::string("không"));
    CHECK(writeFileAtomic(cdir + "/shortcuts.yml", "ko: không\nvn: Việt Nam\n"));
    CHECK(w.drain());
    w.reload();
    CHECK_EQ(w.shortcutParses(), 2);
    CHECK_EQ(w.settings().shortcuts->at("vn"), std::string("Việt Nam"));
    // The directory goes away: the watch is gone → focus-in falls back to the mtime check.
    std::string rm = "rm -rf '" + cdir + "'";
    CHECK_EQ(std::system(rm.c_str()), 0);
    w.drain();
    CHECK(!w.watching());
    CHECK(writeFileAtomic(cdir + "/config.toml", "[typing]\ninput_method = \"telex\"\n"));
    CHECK(w.changedOnDiskUnwatched());
    CHECK(!w.reload().vni);
    CHECK(w.watching());  // re-added once the directory was back
    CHECK(!w.changedOnDiskUnwatched());
    std::string cmd = "rm -rf '" + dir + "'";
    CHECK_EQ(std::system(cmd.c_str()), 0);
}


// MARK: - Direct mode (terminals)

// A terminal behind an ordered forwarded-key channel: it cannot report or delete text
// around the caret, draws no preedit, and applies forwarded keys (BackSpace / characters)
// strictly in order. Every forwarded key also comes back to the IM marked `forwarded`
// (as a client looping IBUS_FORWARD_MASK events would) and must be ignored there.
struct BlindTerminal : InputContext {
    std::string doc;
    int commits = 0, deletes = 0, preedits = 0, forwardedBs = 0, echoesConsumed = 0;
    std::vector<std::string> pending;  // forwarded keys not yet applied: "\b" or one UTF-8 char
    void setPreedit(const std::string &s, bool) override {
        if (!s.empty()) ++preedits;
    }
    void commit(const std::string &s) override {
        ++commits;
        doc += s;
    }
    void deleteBeforeCursor(int) override { ++deletes; }
    bool textBeforeCursor(std::string &) override { return false; }
    bool hasSelection() override { return true; }  // an unreliable answer: Direct must ignore it
    void directReplace(int bs, const std::string &text) override {
        for (int i = 0; i < bs; ++i) pending.push_back("\b");
        forwardedBs += bs;
        for (size_t i = 0; i < text.size();) {
            size_t n = 1;
            while (i + n < text.size() && (static_cast<unsigned char>(text[i + n]) & 0xc0) == 0x80) ++n;
            pending.push_back(text.substr(i, n));
            i += n;
        }
    }
    // The event loop: forwarded keys are delivered (and echoed back) before the next key.
    void flush(Session &s) {
        auto keys = pending;
        pending.clear();
        for (auto &k : keys) {
            KeyEvent ev;
            ev.forwarded = true;
            ev.keysym = k == "\b" ? uint32_t(ks::BackSpace) : uint32_t((unsigned char)k[0]);
            ev.unicode = k == "\b" ? 0 : ev.keysym;
            if (s.processKey(ev, *this)) ++echoesConsumed;
            if (k == "\b") popChars(doc, 1);
            else doc += k;
        }
    }
};

void pressT(Session &s, BlindTerminal &t, uint32_t keysym, uint32_t unicode, uint32_t mods = 0) {
    KeyEvent ev;
    ev.keysym = keysym;
    ev.unicode = unicode;
    ev.mods = mods;
    bool consumed = s.processKey(ev, t);
    t.flush(s);  // the forwarded keys land before the app handles this key
    ev.release = true;
    s.processKey(ev, t);
    if (consumed || (mods & (VT_MOD_CTRL | VT_MOD_ALT | VT_MOD_SUPER))) return;
    if (keysym == ks::BackSpace) popChars(t.doc, 1);
    else if (keysym == ks::Return) t.doc += "\n";
    else if (unicode >= 0x20 && unicode < 0x7f) t.doc += char(unicode);
}

void typeT(Session &s, BlindTerminal &t, const std::string &keys) {
    for (char c : keys) {
        switch (c) {
        case '<': pressT(s, t, ks::BackSpace, 0); break;
        case '\n': pressT(s, t, ks::Return, '\r'); break;
        case '>': pressT(s, t, ks::Right, 0); break;
        default: pressT(s, t, uint32_t((unsigned char)c), uint32_t((unsigned char)c));
        }
    }
}

// A host that keeps forwarded keys in order: IBus GTK3 module, terminal purpose.
FieldHints orderedTerminal() {
    FieldHints f;
    f.terminal = true;
    f.host = ClientHost::IBusGtk;
    return f;
}

void enterDirect(Session &s, BlindTerminal &t, const Settings &st = defaults()) {
    AppPolicy p = resolveAppPolicy("gnome-terminal-server", st, false, orderedTerminal());
    s.applySettings(st);
    s.setDisplayMode(p.mode, t);
    s.setSurroundingEdits(p.allowSurroundingEdits);
    CHECK(s.displayMode() == DisplayMode::Direct);
}

std::string runDirect(const std::string &keys, BlindTerminal *out = nullptr) {
    Session s;
    BlindTerminal t;
    enterDirect(s, t);
    typeT(s, t, keys);
    s.finish(t);
    if (out) *out = t;
    return t.doc;
}

void testDirectBlindTerminal() {
    BlindTerminal t;
    CHECK_EQ(runDirect("thuwr gox tieengs vieetj", &t), std::string("thử gõ tiếng việt"));
    CHECK(t.forwardedBs > 0);        // tones fixed with BackSpace, not by reading back
    CHECK_EQ(t.deletes, 0);          // never delete-surrounding (VTE ignores it)
    CHECK_EQ(t.commits, 0);          // never commit_text: it could overtake a forwarded ⌫
    CHECK_EQ(t.preedits, 0);         // no preedit → no underline
    CHECK_EQ(t.echoesConsumed, 0);   // our own forwarded keys are never re-processed
    CHECK_EQ(runDirect("Tieesng Vieejt\n"), std::string("Tiếng Việt\n"));
    CHECK_EQ(runDirect("dduwowcj khoong"), std::string("được không"));
    CHECK_EQ(runDirect("google "), std::string("google "));   // auto-restore via ⌫ + retype
}

void testDirectBackspaceMidWord() {
    CHECK_EQ(runDirect("toans<"), std::string("tóa"));      // tone re-placed after ⌫
    CHECK_EQ(runDirect("khoong<<"), std::string("khô"));
    CHECK_EQ(runDirect("vieejt<<<<<"), std::string(""));
    for (const char *keys : {"thuwr<r", "tieengs<<a", "dduwowcj<<", "nguwowif<<<", "Vieejt<j"})
        CHECK_EQ(runDirect(keys), run(keys, DisplayMode::Preedit, defaults(), false));
    // Direct agrees with Preedit on random scripts (letters, tones, ⌫, space, punctuation)
    // (Blind preedit never re-opens a word on ⌫; Direct does by keystream trust since #163 —
    // compared with that switched off here, and against Surrounding in
    // testIssue163DirectKeystreamReopen.)
    std::mt19937 rng(777);
    const std::string alphabet = "aeoudwsfrxjzntghiycqAEO  <<.";
    Settings noReopen;
    noReopen.reEditWord = false;
    for (int i = 0; i < 3000; ++i) {
        std::string keys;
        int n = 1 + int(rng() % 14);
        for (int k = 0; k < n; ++k) keys += alphabet[rng() % alphabet.size()];
        std::string p = run(keys, DisplayMode::Preedit, defaults(), false);  // blind preedit
        Session s;
        BlindTerminal t;
        enterDirect(s, t, noReopen);
        typeT(s, t, keys);
        std::string d = t.doc;
        if (p != d) {
            std::fprintf(stderr, "direct mismatch for [%s]: preedit=[%s] direct=[%s]\n", keys.c_str(), p.c_str(),
                         d.c_str());
            ++g_fail;
            return;
        }
    }
    ++g_pass;
}

void testDirectResets() {
    // Enter / arrows end the word: nothing typed later may ⌫ back into it
    BlindTerminal t;
    CHECK_EQ(runDirect("toan>s", &t), std::string("toans"));  // no re-edit (never reads back)
    CHECK_EQ(t.forwardedBs, 0);
    CHECK_EQ(runDirect("vie\ne", &t), std::string("vie\ne"));
    CHECK_EQ(t.forwardedBs, 0);
    // ⌫ right after the boundary re-opens the word by keystream trust (#163, testIssue163...);
    // a key in between (or Enter) ends it for good.
    CHECK_EQ(runDirect("thays .<<a", &t), std::string("tháya"));
    CHECK_EQ(runDirect("thays\n<a", &t), std::string("tháya"));
    // paste / click (the frontend's reset) in the middle of a word: next key starts afresh
    {
        Session s;
        BlindTerminal u;
        enterDirect(s, u);
        typeT(s, u, "vie");
        s.finish(u);     // IBus/Fcitx5 reset: VTE resets the IM on every mouse press
        u.doc += "XYZ";  // pasted text the IM never saw
        typeT(s, u, "e");
        CHECK_EQ(u.doc, std::string("vieXYZe"));
        CHECK_EQ(u.forwardedBs, 0);
    }
    // Ctrl chord (Ctrl+Shift+V paste, Ctrl+W…) ends the word too
    {
        Session s;
        BlindTerminal v;
        enterDirect(s, v);
        typeT(s, v, "vie");
        pressT(s, v, 'V', 'V', VT_MOD_CTRL | VT_MOD_SHIFT);
        v.doc += "XYZ";
        typeT(s, v, "e");
        CHECK_EQ(v.doc, std::string("vieXYZe"));
    }
    // a forwarded key coming back is ignored: the word state does not move
    {
        Session s;
        BlindTerminal w;
        enterDirect(s, w);
        typeT(s, w, "vie");
        KeyEvent echo;
        echo.forwarded = true;
        echo.keysym = echo.unicode = 'e';
        CHECK(!s.processKey(echo, w));
        echo.keysym = ks::BackSpace;
        echo.unicode = 0;
        CHECK(!s.processKey(echo, w));
        CHECK(w.pending.empty());
        typeT(s, w, "e");
        CHECK_EQ(w.doc, std::string("viê"));
    }
}

// MARK: - Issue #163 (macOS c805edce): reach-back decisions, ported

// The note of ONE key event (press only; a release resets it).
template <class IC>
std::string noteOf(Session &s, IC &ic, uint32_t keysym, uint32_t unicode) {
    KeyEvent ev;
    ev.keysym = keysym;
    ev.unicode = unicode;
    s.processKey(ev, ic);
    const char *n = s.reachBackNote();
    return n ? n : "";
}

bool has(const std::string &note, const char *what) { return note.find(what) != std::string::npos; }

// RC2: Direct (terminals) cannot read anything back, but its own keystream proves
// "<word><one boundary>" when ⌫ is the very next key after that boundary.
void testIssue163DirectKeystreamReopen() {
    BlindTerminal t;
    CHECK_EQ(runDirect("thays <a", &t), std::string("thấy"));
    CHECK_EQ(t.deletes, 0);  // never delete-surrounding: the ⌫ is the app's, the edit forwarded
    CHECK_EQ(t.commits, 0);
    CHECK_EQ(runDirect("toan <s"), std::string("toán"));
    CHECK_EQ(runDirect("thays <a "), std::string("thấy "));
    // Anything between the boundary and ⌫ disarms it: another key, Enter, a chord.
    CHECK_EQ(runDirect("thays x<a"), std::string("tháy a"));
    CHECK_EQ(runDirect("thays .<<a"), std::string("tháya"));
    CHECK_EQ(runDirect("thays\n<a"), std::string("tháya"));
    CHECK_EQ(runDirect("thays>  <a"), std::string("tháy a"));
    // Blind Direct ends up exactly where Surrounding (which verifies the screen) does.
    for (const char *keys : {"thays <a", "toan <<s", "hoc <j", "dduwowc <j", "vieet, <j", "thays,<a", "tien <s",
                             "thays x<a", "thays .<<a", "thays\n<a", "toan <s<<f", "a <b <c"})
        CHECK_EQ(runDirect(keys), run(keys, DisplayMode::Surrounding));
    {
        Session s;
        BlindTerminal u;
        enterDirect(s, u);
        typeT(s, u, "thays ");
        pressT(s, u, 'c', 'c', VT_MOD_CTRL);  // Ctrl+C: the shell may print anything
        typeT(s, u, "<a");
        CHECK_EQ(u.doc, std::string("tháya"));
    }
    // A click / caret move (the frontend's reset) or a focus change in between.
    for (int i = 0; i < 2; ++i) {
        Session s;
        BlindTerminal u;
        enterDirect(s, u);
        typeT(s, u, "thays ");
        if (i == 0) s.finish(u);
        else s.focusIn();
        typeT(s, u, "<a");
        CHECK_EQ(u.doc, std::string("tháya"));
    }
    // A word the boundary rewrote (auto-restore) leaves nothing to reopen.
    CHECK_EQ(runDirect("google <s"), std::string("googles"));
    // "Sửa dấu từ đã gõ" off: plain ⌫.
    {
        Settings st;
        st.reEditWord = false;
        Session s;
        BlindTerminal u;
        enterDirect(s, u, st);
        typeT(s, u, "thays <a");
        CHECK_EQ(u.doc, std::string("tháya"));
    }
    // The decision is named for the debug log.
    {
        Session s;
        BlindTerminal u;
        enterDirect(s, u);
        typeT(s, u, "thays ");
        CHECK(has(noteOf(s, u, ks::BackSpace, 0), "keystream trust"));
    }
}

// RC1: every refused re-edit / ⌫ re-open candidate names its reason; other keys none.
void testIssue163ReachBackNotes() {
    // Forced-preedit app / unproven surrounding (resolveAppPolicy → no surrounding edits).
    {
        Session s;
        Mock m;
        s.setSurroundingEdits(false);
        type(s, m, "toan>");
        CHECK(has(noteOf(s, m, 's', 's'), "re-edit: skipped (app policy"));
        Session r;
        Mock n;
        r.setSurroundingEdits(false);
        type(r, n, "thays ");
        CHECK(has(noteOf(r, n, ks::BackSpace, 0), "⌫ re-open: skipped (app policy"));
    }
    for (auto mode : {DisplayMode::Preedit, DisplayMode::Surrounding}) {
        {   // a tone key starting a new word after a space
            Session s;
            Mock m;
            s.setDisplayMode(mode, m);
            type(s, m, "toan ");
            CHECK(has(noteOf(s, m, 's', 's'), "previous key ended a word"));
            CHECK_EQ(noteOf(s, m, 'a', 'a'), std::string());  // plain letter: no candidate
        }
        {   // nothing readable before the caret
            Session s;
            Mock m;
            s.setDisplayMode(mode, m);
            m.doc = "toan";
            type(s, m, ">");
            m.surrounding = false;
            CHECK(has(noteOf(s, m, 's', 's'), "re-edit: skipped (text before the caret unreadable)"));
        }
        {   // no word before the caret
            Session s;
            Mock m;
            s.setDisplayMode(mode, m);
            m.doc = "toan, ";
            type(s, m, ">");
            CHECK(has(noteOf(s, m, 's', 's'), "no word right before the caret"));
        }
        {   // success is named too
            Session s;
            Mock m;
            s.setDisplayMode(mode, m);
            m.doc = "toan";
            type(s, m, ">");
            CHECK(has(noteOf(s, m, 's', 's'), "re-edit: seeded"));
        }
        {   // ⌫ re-open: the word changed under us → distrusted, named
            Session s;
            Mock m;
            s.setDisplayMode(mode, m);
            type(s, m, "thays ");
            m.doc = "thay ";
            CHECK(has(noteOf(s, m, ks::BackSpace, 0), "distrusted"));
        }
        {   // ⌫ re-open: the host has not shown the boundary yet
            Session s;
            Mock m;
            s.setDisplayMode(mode, m);
            type(s, m, "thays ");
            m.hasReported = true;
            m.reported = "tháy";
            CHECK(has(noteOf(s, m, ks::BackSpace, 0), "has not shown the boundary yet"));
        }
        {   // ⌫ re-open succeeded
            Session s;
            Mock m;
            s.setDisplayMode(mode, m);
            type(s, m, "thays ");
            CHECK(has(noteOf(s, m, ks::BackSpace, 0), "⌫ re-open: word back in the engine"));
        }
        {   // distrusted focus: named as such
            Session s;
            Mock m;
            s.setDisplayMode(mode, m);
            type(s, m, "thays ");
            m.doc = "thay ";
            type(s, m, "<");  // mismatch → distrusted
            CHECK(s.surroundingDistrusted());
            type(s, m, "toan>");
            CHECK(has(noteOf(s, m, 's', 's'), "distrusted for this focus"));
        }
    }
    // A release resets it: the note belongs to one key event.
    {
        Session s;
        Mock m;
        type(s, m, "toan ");
        CHECK(!noteOf(s, m, 's', 's').empty());
        KeyEvent rel;
        rel.keysym = rel.unicode = 's';
        rel.release = true;
        s.processKey(rel, m);
        CHECK(s.reachBackNote() == nullptr);
    }
}

void testDirectPolicyTable() {
    // client names → host
    CHECK(ibusClientHost("gtk3-im:gnome-terminal-server") == ClientHost::IBusGtk);
    CHECK(ibusClientHost("gtk-im:xfce4-terminal") == ClientHost::IBusGtk);
    CHECK(ibusClientHost("gtk4-im:ptyxis") == ClientHost::IBusGtk4);
    CHECK(ibusClientHost("QIBusInputContext") == ClientHost::IBusQt);
    CHECK(ibusClientHost("xim") == ClientHost::IBusXim);
    CHECK(ibusClientHost("gnome-shell") == ClientHost::IBusWayland);
    CHECK(ibusClientHost("default") == ClientHost::Unknown);
    CHECK(ibusClientHost("") == ClientHost::Unknown);
    CHECK(fcitxClientHost("dbus", true) == ClientHost::FcitxOrdered);
    CHECK(fcitxClientHost("dbus", false) == ClientHost::FcitxUnordered);
    CHECK(fcitxClientHost("xim", false) == ClientHost::FcitxXim);
    CHECK(fcitxClientHost("wayland_v2", false) == ClientHost::FcitxWaylandV2);
    CHECK(fcitxClientHost("wayland", false) == ClientHost::FcitxWayland);
    CHECK(fcitxClientHost("ibus", true) == ClientHost::FcitxIBus);
    for (auto h : {ClientHost::IBusGtk, ClientHost::FcitxOrdered}) CHECK(hostSupportsDirect(h));
    for (auto h : {ClientHost::Unknown, ClientHost::IBusGtk4, ClientHost::IBusQt, ClientHost::IBusXim,
                   ClientHost::IBusWayland, ClientHost::FcitxUnordered, ClientHost::FcitxXim,
                   ClientHost::FcitxWayland, ClientHost::FcitxIBus, ClientHost::FcitxWaylandV2})
        CHECK(!hostSupportsDirect(h));

    struct Row {
        const char *what, *app;
        ClientHost host;
        bool terminalField;
        DisplayMode want;
    };
    const Row rows[] = {
        {"X11 IBus GTK3 VTE (gnome-terminal)", "gnome-terminal-server", ClientHost::IBusGtk, true, DisplayMode::Direct},
        {"X11 IBus GTK3 tilix, no purpose", "tilix", ClientHost::IBusGtk, false, DisplayMode::Direct},
        {"X11 IBus GTK3 pid-only app, terminal purpose", "(4242)", ClientHost::IBusGtk, true, DisplayMode::Direct},
        {"X11 IBus GTK3 gedit", "gedit", ClientHost::IBusGtk, false, DisplayMode::Preedit},
        {"IBus GTK4 VTE (ptyxis): forwarded BackSpace lost", "ptyxis", ClientHost::IBusGtk4, true,
         DisplayMode::Preedit},
        {"GNOME Wayland (gnome-shell text-input-v3)", "gnome-terminal-server", ClientHost::IBusWayland, true,
         DisplayMode::Preedit},
        {"IBus Qt konsole", "qibusinputcontext", ClientHost::IBusQt, false, DisplayMode::Preedit},
        {"IBus XIM xterm", "xim", ClientHost::IBusXim, false, DisplayMode::Preedit},
        {"IBus < 1.5.28 (no client name)", "default", ClientHost::Unknown, true, DisplayMode::Preedit},
        {"Fcitx5 fcitx5-qt konsole (X11 or KDE Wayland)", "konsole", ClientHost::FcitxOrdered, false,
         DisplayMode::Direct},
        {"Fcitx5 fcitx5-gtk3 VTE", "xfce4-terminal", ClientHost::FcitxOrdered, true, DisplayMode::Direct},
        {"Fcitx5 fcitx5-gtk4 VTE: forwardKey no-op", "ptyxis", ClientHost::FcitxUnordered, true,
         DisplayMode::Preedit},
        {"Fcitx5 Wayland text-input (KDE/wlroots)", "kitty", ClientHost::FcitxWayland, false, DisplayMode::Preedit},
        {"Fcitx5 XIM xterm", "xterm", ClientHost::FcitxXim, false, DisplayMode::Preedit},
        {"Fcitx5 IBus emulation", "alacritty", ClientHost::FcitxIBus, false, DisplayMode::Preedit},
    };
    for (auto user : {DisplayMode::Preedit, DisplayMode::Surrounding}) {
        for (const auto &r : rows) {
            Settings s;
            s.displayMode = user;
            FieldHints f;
            f.terminal = r.terminalField;
            f.host = r.host;
            AppPolicy p = resolveAppPolicy(r.app, s, true, f);
            DisplayMode want = r.want;
            if (want == DisplayMode::Preedit && user == DisplayMode::Surrounding && !r.terminalField &&
                !isForcedPreeditApp(r.app))
                want = DisplayMode::Surrounding;  // an ordinary app keeps the user's choice
            bool ok = p.mode == want && (p.mode != DisplayMode::Direct || !p.allowSurroundingEdits);
            if (ok) { ++g_pass; continue; }
            ++g_fail;
            std::fprintf(stderr, "policy [%s]: mode=%d want=%d edits=%d\n", r.what, int(p.mode), int(want),
                         int(p.allowSurroundingEdits));
        }
    }
    // user switches: terminal_direct off, per-app pins
    Settings s;
    FieldHints f = orderedTerminal();
    s.terminalDirect = false;
    CHECK(resolveAppPolicy("gnome-terminal-server", s, false, f).mode == DisplayMode::Preedit);
    s.terminalDirect = true;
    s.appModes["gnome-terminal-server"] = "preedit";
    CHECK(resolveAppPolicy("gnome-terminal-server", s, false, f).mode == DisplayMode::Preedit);
    s.appModes.clear();
    s.appModes["gedit"] = "direct";  // any app may be pinned Direct on an ordered host
    FieldHints plain;
    plain.host = ClientHost::IBusGtk;
    CHECK(resolveAppPolicy("gedit", s, true, plain).mode == DisplayMode::Direct);
    CHECK(!resolveAppPolicy("gedit", s, true, plain).allowSurroundingEdits);
    plain.host = ClientHost::IBusGtk4;
    CHECK(resolveAppPolicy("gedit", s, true, plain).mode == DisplayMode::Preedit);  // unordered: no
    s.appModes["default"] = "direct";  // a generic id covers many apps: ignored
    plain.host = ClientHost::IBusGtk;
    CHECK(resolveAppPolicy("default", s, true, plain).mode != DisplayMode::Direct);
    FieldHints url = orderedTerminal();
    url.urlOrEmail = true;
    CHECK(resolveAppPolicy("gnome-terminal-server", Settings(), false, url).mode == DisplayMode::Preedit);
    // the global display mode can never be Direct
    Settings g = parseConfig("[general]\ndisplay_mode = \"direct\"\n");
    CHECK(g.displayMode == DisplayMode::Preedit);
    CHECK(resolveAppPolicy("gedit", g, true, plain).mode == DisplayMode::Preedit);
    CHECK(isTerminalApp("org.kde.konsole") && isTerminalApp("vte-2.91") && isTerminalApp("com.mitchellh.ghostty"));
    CHECK(!isTerminalApp("code") && !isTerminalApp("gedit"));
}

void testUnderlineAndDirectSettings() {
    Settings d;
    CHECK(!d.preeditUnderline);
    CHECK(d.terminalDirect);
    Settings s = parseConfig("[general]\npreedit_underline = true\nterminal_direct = false\n[app_modes]\n"
                             "\"Kitty\" = \"direct\"\n");
    CHECK(s.preeditUnderline);
    CHECK(!s.terminalDirect);
    CHECK_EQ(s.appModes["kitty"], std::string("direct"));
    CHECK_EQ(serializeConfig(parseConfig(serializeConfig(s))), serializeConfig(s));
}

// MARK: - Gạch đỏ âm tiết sai chính tả khi gõ (opt-in error style on the preedit)

Settings underlineOn() {
    Settings st;
    st.underlineMisspelled = true;
    return st;
}

void testUnderlineMisspelledOffByDefault() {
    CHECK(!Settings().underlineMisspelled);
    Session s;
    Mock m;
    type(s, m, "ddc");  // "đc": flagged when the option is on
    CHECK_EQ(m.pre, std::string("đc"));
    CHECK(!m.misspelled);
    CHECK_EQ(m.misspelledShows, 0);
    CHECK(!s.preeditMisspelled());
}

void testUnderlineMisspelledFollowsPreedit() {
    Session s;
    Mock m;
    s.applySettings(underlineOn());
    type(s, m, "dd");
    CHECK(!m.misspelled);  // "đ": still being typed
    type(s, m, "c");
    CHECK_EQ(m.pre, std::string("đc"));
    CHECK(m.misspelled);
    type(s, m, "<");
    CHECK_EQ(m.pre, std::string("đ"));
    CHECK(!m.misspelled);
    type(s, m, "c ");
    CHECK_EQ(m.pre, std::string(""));
    CHECK(!m.misspelled);  // hidden preedit carries no style
    CHECK_EQ(m.doc, std::string("đc "));
}

void testUnderlineMisspelledSkipsValidAndEnglish() {
    Session s;
    Mock m;
    s.applySettings(underlineOn());
    type(s, m, "dduwowcj nghieengf khuya quoocs gif gieengs hello hopsng kaf ");
    CHECK_EQ(m.misspelledShows, 0);
    CHECK_EQ(m.doc, std::string("được nghiềng khuya quốc gì giếng hello hopsng kaf "));
    // auto-restore off: "kà" stays at the boundary, so it is judged
    Settings st = underlineOn();
    st.autoRestore = false;
    Session s2;
    Mock m2;
    s2.applySettings(st);
    type(s2, m2, "kaf");
    CHECK(m2.misspelled);
}

void testUnderlineMisspelledPreeditOnly() {
    Session s;
    Mock m;
    s.applySettings(underlineOn());
    s.setDisplayMode(DisplayMode::Surrounding, m);
    type(s, m, "ddc ");
    CHECK_EQ(m.preeditUpdates, 0);
    CHECK_EQ(m.misspelledShows, 0);
    CHECK_EQ(m.doc, std::string("đc "));
}

void testUnderlineMisspelledConfig() {
    Settings s = parseConfig("[general]\nunderline_misspelled = true\n");
    CHECK(s.underlineMisspelled);
    CHECK(serializeConfig(s).find("underline_misspelled = true") != std::string::npos);
    CHECK(serializeConfig(Settings()).find("underline_misspelled = false") != std::string::npos);
    CHECK(parseConfig(serializeConfig(s)).underlineMisspelled);
}

// The vectors shared with the Swift engine and the Windows C++ port, through the C ABI.
void testUnderlineMisspelledSharedVectors() {
    std::string text;
    CHECK(readFile(std::string(VT_SOURCE_ROOT) + "/TelexCore/Tests/TelexCoreTests/Resources/spelling_error_cases.tsv",
                   text));
    int rows = 0;
    size_t at = 0;
    while (at < text.size()) {
        size_t nl = text.find('\n', at);
        std::string line = text.substr(at, nl == std::string::npos ? std::string::npos : nl - at);
        at = nl == std::string::npos ? text.size() : nl + 1;
        if (line.empty() || line[0] == '#') continue;
        std::vector<std::string> f(1);
        for (char c : line) {
            if (c == '\t') f.emplace_back();
            else f.back() += c;
        }
        if (f.size() < 3) continue;
        const bool want = f[2] == "1";
        const std::string opts = f.size() > 3 ? f[3] : "";
        bool got = false;
        if (f[0] == "syllable") got = vt_is_valid_syllable(f[1].c_str(), false);
        else if (f[0] == "error") got = vt_is_spelling_error(f[1].c_str(), false);
        else if (f[0] == "keys") {
            vt_engine *e = vt_engine_new();
            vt_engine_set_flag(e, VT_FLAG_FREE_MARKING, true);
            vt_engine_set_flag(e, VT_FLAG_LIVE_SPELL_CHECK, opts.find('L') == std::string::npos);
            vt_engine_set_flag(e, VT_FLAG_CONTEXTUAL_ENGLISH, true);
            vt_engine_set_flag(e, VT_FLAG_COLLISION_PREFERS_VIETNAMESE, true);
            vt_engine_set_flag(e, VT_FLAG_TEENCODE, false);
            vt_action a;
            for (char c : f[1]) vt_feed(e, uint32_t((unsigned char)c), &a);
            got = vt_has_spelling_error(e, opts.find('R') == std::string::npos);
            vt_engine_free(e);
        } else {
            CHECK(false);
            continue;
        }
        ++rows;
        if (got == want) ++g_pass;
        else {
            ++g_fail;
            std::fprintf(stderr, "spelling case %s %s: got %d want %d\n", f[0].c_str(), f[1].c_str(), got, want);
        }
    }
    CHECK(rows > 50);
}


// MARK: - [experimental] no_underline = "forward-keys" (docs/NO-UNDERLINE-SPIKE.md)

// A host that applies what it receives LATER, in the order received (the compositor's IM
// queue + the app), and reports its text before the caret only once applied — like Chromium
// behind GNOME Shell / KWin. Faults: lost / doubled forwarded BackSpace, duplicated commit,
// reports that stop updating.
struct AsyncHost : InputContext {
    struct Op {
        char kind;  // 'b' forwarded BackSpace, 'B' the app's own BackSpace, 't' text
        std::string text;
    };
    std::string doc;       // the app's text before the caret (applied ops)
    std::string reported;  // last surrounding text sent to the IM
    std::string pre;
    std::vector<Op> queue;
    std::vector<std::string> log;  // "bs:n" / "commit:x" / "del:n" / "pre:x", in call order
    bool reports = true, freezeReports = false, selection = false;
    int dropBackspaces = 0, extraBackspaces = 0, dupCommits = 0;
    int preeditUpdates = 0;
    void setPreedit(const std::string &s, bool) override {
        pre = s;
        ++preeditUpdates;
        log.push_back("pre:" + s);
    }
    void commit(const std::string &s) override {
        log.push_back("commit:" + s);
        queue.push_back({'t', s});
    }
    void deleteBeforeCursor(int n) override {
        log.push_back("del:" + std::to_string(n));
        for (int i = 0; i < n; ++i) queue.push_back({'B', ""});
    }
    void forwardBackspaces(int n) override {
        log.push_back("bs:" + std::to_string(n));
        for (int i = 0; i < n; ++i) queue.push_back({'b', ""});
    }
    bool textBeforeCursor(std::string &out) override {
        if (!reports) return false;
        out = reported;
        return true;
    }
    bool hasSelection() override { return selection; }
    bool selectionAtCaret() override { return selection; }
    // The compositor + app catch up with everything sent so far.
    void apply() {
        char prev = 0;
        for (const Op &op : queue) {
            char kind = op.kind;
            if (op.kind == 't') {
                doc += op.text;
                if (dupCommits > 0 && prev == 'b') {  // the replacement text of a key edit
                    --dupCommits;
                    doc += op.text;
                }
            } else if (op.kind == 'b' && dropBackspaces > 0) {
                --dropBackspaces;
            } else {
                popChars(doc, 1);
                if (op.kind == 'b' && extraBackspaces > 0) {
                    --extraBackspaces;
                    popChars(doc, 1);
                }
            }
            prev = kind;
        }
        queue.clear();
        if (!freezeReports) reported = doc;
    }
    std::string screen() const { return doc + pre; }
    int count(const std::string &prefix) const {
        int n = 0;
        for (auto &l : log) n += l.compare(0, prefix.size(), prefix) == 0;
        return n;
    }
};

struct FakeClock {
    int64_t ms = 1000;
    std::function<int64_t()> fn() {
        return [this] { return ms; };
    }
};

void forwardKeysSession(Session &s, AsyncHost &h, FakeClock &clock) {
    s.setClockForTesting(clock.fn());
    s.setDisplayMode(DisplayMode::Surrounding, h);
    s.setDeleteWithKeys(true);
    s.setSurroundingEdits(false);  // resolveAppPolicy: no re-edit / reopen on this path
}

// '<' = BackSpace; everything else is that ASCII key. The host catches up every `every` keys
// (0 = never; the caller applies).
void typeAsync(Session &s, AsyncHost &h, const std::string &keys, int every = 1) {
    int n = 0;
    for (char c : keys) {
        KeyEvent ev;
        ev.keysym = c == '<' ? ks::BackSpace : uint32_t((unsigned char)c);
        ev.unicode = c == '<' ? 0 : uint32_t((unsigned char)c);
        bool consumed = s.processKey(ev, h);
        ev.release = true;
        s.processKey(ev, h);
        if (!consumed) h.queue.push_back(c == '<' ? AsyncHost::Op{'B', ""} : AsyncHost::Op{'t', std::string(1, c)});
        if (every > 0 && ++n % every == 0) h.apply();
    }
}

// What the delete-surrounding path types for `keys` with reach-back edits off (the policy of
// the key path: no re-edit, no ⌫ reopen) on an honest synchronous host.
std::string surroundingNoEdits(const std::string &keys, const std::string &prefix = std::string()) {
    Session s;
    Mock m;
    m.doc = prefix;
    s.setDisplayMode(DisplayMode::Surrounding, m);
    s.setSurroundingEdits(false);
    type(s, m, keys);
    return m.screen();
}

void testForwardKeysTypesInPlace() {
    FakeClock clock;
    Session s;
    AsyncHost h;
    forwardKeysSession(s, h, clock);
    typeAsync(s, h, "tieesng vieejt dduwowcj ");
    h.apply();
    CHECK_EQ(h.screen(), std::string("tiếng việt được "));
    CHECK_EQ(h.preeditUpdates, 0);       // no underline: nothing ever composed as preedit
    CHECK_EQ(h.count("del:"), 0);        // never delete-surrounding
    CHECK(h.count("bs:") > 0);
    CHECK(!s.surroundingDistrusted());
    // Every key edit: the BackSpaces first, then (right after) its text.
    for (size_t i = 0; i < h.log.size(); ++i)
        if (h.log[i].compare(0, 3, "bs:") == 0) CHECK(i + 1 < h.log.size() && h.log[i + 1].compare(0, 7, "commit:") == 0);
    typeAsync(s, h, "a");  // the next key confirms the last edit
    CHECK(!s.keyEditUnconfirmed());
}

void testForwardKeysHostLags() {
    // The host applies (and reports) only every 3 keys, or reports nothing for a while: the
    // ordered channel keeps the result right, and lagging is never mistaken for a fault.
    for (int every : {2, 3, 5}) {
        FakeClock clock;
        Session s;
        AsyncHost h;
        forwardKeysSession(s, h, clock);
        typeAsync(s, h, "Tieesng Vieejt laf ngoon nguwx cuar chungs tooi ", every);
        h.apply();
        CHECK_EQ(h.screen(), std::string("Tiếng Việt là ngôn ngữ của chúng tôi "));
        CHECK(!s.surroundingDistrusted());
        if (s.surroundingDistrusted() || h.screen() != "Tiếng Việt là ngôn ngữ của chúng tôi ") {
            std::fprintf(stderr, "lag %d: [%s]\n", every, h.screen().c_str());
            for (auto &l : h.log) std::fprintf(stderr, "  %s\n", l.c_str());
        }
        CHECK_EQ(h.count("del:"), 0);
    }
    {
        FakeClock clock;
        Session s;
        AsyncHost h;
        forwardKeysSession(s, h, clock);
        h.reports = false;  // no surrounding text at all yet
        typeAsync(s, h, "vieej", 0);
        h.reports = true;
        h.apply();
        typeAsync(s, h, "t ");
        h.apply();
        CHECK_EQ(h.screen(), std::string("việt "));
        CHECK(!s.surroundingDistrusted());
    }
    // The user's own ⌫ while an edit is unconfirmed is tracked too.
    {
        FakeClock clock;
        Session s;
        AsyncHost h;
        forwardKeysSession(s, h, clock);
        typeAsync(s, h, "vieejt<<", 0);
        h.apply();
        typeAsync(s, h, "ej ");
        h.apply();
        CHECK_EQ(h.screen(), surroundingNoEdits("vieejt<<ej "));
        CHECK(!s.surroundingDistrusted());
    }
}

// A fault shows up at the next key: the field is distrusted, the key and the rest of the
// word go on as preedit, no more BackSpaces are sent. focusIn() gives the field a new chance.
void checkFaultFallsBack(Session &s, AsyncHost &h) {
    int bsBefore = h.count("bs:");
    typeAsync(s, h, "s");
    CHECK(s.surroundingDistrusted());
    CHECK(s.displayMode() == DisplayMode::Preedit);
    CHECK_EQ(h.pre, std::string("s"));  // the key itself is composed again (preedit)
    typeAsync(s, h, "ao ");
    CHECK_EQ(h.count("bs:"), bsBefore);  // nothing reaches back any more
    CHECK(!s.keyEditUnconfirmed());
    s.focusIn();
    CHECK(!s.surroundingDistrusted());
    CHECK(s.displayMode() == DisplayMode::Surrounding);
}

void testForwardKeysLostBackspace() {
    FakeClock clock;
    Session s;
    AsyncHost h;
    forwardKeysSession(s, h, clock);
    typeAsync(s, h, "tie");
    h.dropBackspaces = 1;  // the compositor / app loses the forwarded BackSpace
    typeAsync(s, h, "e");
    CHECK_EQ(h.doc, std::string("tieê"));
    checkFaultFallsBack(s, h);
    CHECK_EQ(h.screen(), std::string("tieêsao "));
}

void testForwardKeysDoubledBackspace() {
    FakeClock clock;
    Session s;
    AsyncHost h;
    forwardKeysSession(s, h, clock);
    typeAsync(s, h, "tie");
    h.extraBackspaces = 1;  // the page deletes twice (the Messenger "⌫ xoá 2 lần" symptom)
    typeAsync(s, h, "e");
    CHECK_EQ(h.doc, std::string("tê"));
    checkFaultFallsBack(s, h);
}

void testForwardKeysDuplicatedCommit() {
    FakeClock clock;
    Session s;
    AsyncHost h;
    forwardKeysSession(s, h, clock);
    typeAsync(s, h, "tie");
    h.dupCommits = 1;  // Draft.js-like duplication of the replacement text
    typeAsync(s, h, "e");
    CHECK_EQ(h.doc, std::string("tiêê"));
    checkFaultFallsBack(s, h);
}

void testForwardKeysTimeout() {
    // Reports stop updating after an edit: consistent but never confirmed. Within the
    // timeout the Session keeps going (no waiting, no sleeping); past it, the field is
    // distrusted at the next key.
    FakeClock clock;
    Session s;
    AsyncHost h;
    forwardKeysSession(s, h, clock);
    typeAsync(s, h, "tie");
    h.freezeReports = true;  // stays "tie"
    typeAsync(s, h, "e");
    CHECK(s.keyEditUnconfirmed());
    clock.ms += Session::kKeyEditAckTimeoutMs / 2;
    typeAsync(s, h, "n");  // lagging, still within the timeout: typed in place
    CHECK(!s.surroundingDistrusted());
    CHECK_EQ(h.doc, std::string("tiên"));
    clock.ms += Session::kKeyEditAckTimeoutMs;
    checkFaultFallsBack(s, h);
    // Reports come back: confirmation works again after focusIn.
    h.freezeReports = false;
    h.apply();
    typeAsync(s, h, " vieej");
    typeAsync(s, h, "t");
    CHECK(!s.surroundingDistrusted());
    CHECK(!s.keyEditUnconfirmed());
}

void testForwardKeysSelectionAndKeys() {
    FakeClock clock;
    Session s;
    AsyncHost h;
    forwardKeysSession(s, h, clock);
    typeAsync(s, h, "tie");
    h.selection = true;  // never send BackSpaces into a selection
    typeAsync(s, h, "e");
    CHECK_EQ(h.count("bs:"), 0);
    h.selection = false;
    // Enter / Ctrl chords end the word: nothing to confirm afterwards.
    typeAsync(s, h, " ");
    typeAsync(s, h, "vieej", 0);  // the host lags: the edits stay unconfirmed
    CHECK(s.keyEditUnconfirmed());
    KeyEvent ret;
    ret.keysym = ks::Return;
    ret.unicode = '\r';
    s.processKey(ret, h);
    CHECK(!s.keyEditUnconfirmed());
    CHECK(!s.surroundingDistrusted());
    h.apply();
    // Turning the path off mid-way (policy change) drops the tracking too.
    typeAsync(s, h, "vie");  // after Enter the host has caught up with the new word…
    typeAsync(s, h, "ej", 0);  // …then lags again
    CHECK(s.keyEditUnconfirmed());
    s.setDeleteWithKeys(false);
    CHECK(!s.keyEditUnconfirmed());
}

void testForwardKeysPolicy() {
    Settings s;
    s.noUnderline = NoUnderline::ForwardKeys;
    FieldHints gnome;
    gnome.host = ClientHost::IBusWayland;
    FieldHints kwin;
    kwin.host = ClientHost::FcitxWayland;
    for (const char *id : {"google-chrome", "chromium", "code", "slack", "coccoc", "crx_abcdef",
                           "chrome-abcdefghijklmnop-Default", "brave-browser"}) {
        for (const FieldHints &f : {gnome, kwin}) {
            AppPolicy p = resolveAppPolicy(id, s, true, f);
            CHECK(p.mode == DisplayMode::Surrounding);
            CHECK(p.deleteWithKeys);
            CHECK(!p.allowSurroundingEdits);
            // surrounding not proven for this focus: preedit
            CHECK(resolveAppPolicy(id, s, false, f).mode == DisplayMode::Preedit);
            CHECK(!resolveAppPolicy(id, s, false, f).deleteWithKeys);
        }
    }
    // off by default
    CHECK(Settings().noUnderline == NoUnderline::Off);
    CHECK(!resolveAppPolicy("google-chrome", Settings(), true, gnome).deleteWithKeys);
    CHECK(resolveAppPolicy("google-chrome", Settings(), true, gnome).mode == DisplayMode::Preedit);
    // hosts that do not keep forwarded keys in order with commits
    for (ClientHost hst : {ClientHost::Unknown, ClientHost::IBusGtk, ClientHost::IBusGtk4, ClientHost::IBusQt,
                           ClientHost::IBusXim, ClientHost::FcitxOrdered, ClientHost::FcitxUnordered,
                           ClientHost::FcitxXim, ClientHost::FcitxIBus, ClientHost::FcitxWaylandV2}) {
        FieldHints f;
        f.host = hst;
        CHECK(!hostOrdersForwardedKeys(hst));
        AppPolicy p = resolveAppPolicy("google-chrome", s, true, f);
        CHECK(p.mode == DisplayMode::Preedit && !p.deleteWithKeys);
    }
    CHECK(hostOrdersForwardedKeys(ClientHost::IBusWayland) && hostOrdersForwardedKeys(ClientHost::FcitxWayland));
    // not Chromium (GTK / Qt / Gecko reorder keys and commits client-side), generic ids
    for (const char *id : {"firefox", "org.gnome.texteditor", "libreoffice-writer", "gnome-shell", "default", ""}) {
        AppPolicy p = resolveAppPolicy(id, s, true, gnome);
        CHECK(!p.deleteWithKeys);
    }
    CHECK(isChromiumApp("google-chrome") && isChromiumApp("code") && !isChromiumApp("firefox") &&
          !isChromiumApp("gedit") && !isChromiumApp("chrome-remote-desktop-host"));
    // field types win
    FieldHints url = gnome;
    url.urlOrEmail = true;  // omnibox: autocomplete selects the tail
    CHECK(resolveAppPolicy("google-chrome", s, true, url).mode == DisplayMode::Preedit);
    FieldHints term = kwin;
    term.terminal = true;
    CHECK(!resolveAppPolicy("code", s, true, term).deleteWithKeys);
    FieldHints num = gnome;
    num.numeric = true;
    CHECK(!resolveAppPolicy("google-chrome", s, true, num).deleteWithKeys);
    // a pin wins
    Settings pinned = s;
    pinned.appModes["google-chrome"] = "preedit";
    CHECK(resolveAppPolicy("google-chrome", pinned, true, gnome).mode == DisplayMode::Preedit);
    pinned.appModes["google-chrome"] = "surrounding";  // the user's choice: delete-surrounding
    AppPolicy ps = resolveAppPolicy("google-chrome", pinned, true, gnome);
    CHECK(ps.mode == DisplayMode::Surrounding && !ps.deleteWithKeys);
    pinned.appModes["google-chrome"] = "off";
    CHECK(!resolveAppPolicy("google-chrome", pinned, true, gnome).deleteWithKeys);
    // Chromium stays in the forced-preedit list (the default path is unchanged)
    CHECK(isForcedPreeditApp("google-chrome") && isForcedPreeditApp("crx_abcdef"));
}

// Fcitx5 on GNOME Wayland (Zorin OS, Ubuntu + im-config fcitx5): gnome-shell talks IBus to
// Fcitx5's "ibus" frontend, which also serves X11/XWayland apps with GTK_IM_MODULE=ibus.
// Only gnome-shell's own context (or Fcitx5's per-app virtual contexts under it) is the
// ordered gnome-shell → mutter path; everything else stays FcitxIBus (preedit).
void testMutterForwardedKeys() {
    using namespace viettelex::gnome;
    CHECK(shellMajorFromVersion("50.1") == 50);
    CHECK(shellMajorFromVersion("46.0") == 46);
    CHECK(shellMajorFromVersion("51.beta") == 51);
    CHECK(shellMajorFromVersion("42") == 42);
    CHECK(shellMajorFromVersion("") == 0);
    CHECK(shellMajorFromVersion(nullptr) == 0);
    CHECK(shellMajorFromVersion("x50") == 0);
    CHECK(shellMajorFromVersion("50x") == 0);
    // mutter 50.x: the forwarded key event has no device and is dropped (#4853, fixed in 51)
    CHECK(!mutterDeliversForwardedKeys(50));
    CHECK(!mutterDeliversForwardedKeys(0));  // unknown: do not vouch for it
    for (int v : {42, 45, 46, 47, 48, 49, 51, 52}) CHECK(mutterDeliversForwardedKeys(v));
    // IBus on GNOME Wayland: same gate
    Settings s;
    s.noUnderline = NoUnderline::ForwardKeys;
    FieldHints f;
    f.host = ClientHost::IBusWayland;
    CHECK(resolveAppPolicy("chromium", s, true, f).deleteWithKeys);
    f.forwardedKeysDropped = true;
    CHECK(!resolveAppPolicy("chromium", s, true, f).deleteWithKeys);
    CHECK(resolveAppPolicy("chromium", s, true, f).mode == DisplayMode::Preedit);
}

void testFcitxGnomeWaylandHost() {
    // classification: gnome-shell's context, by program name, only in a GNOME Wayland session
    CHECK(fcitxIBusIsGnomeShell("gnome-shell", true));
    CHECK(fcitxIBusIsGnomeShell("GNOME-Shell", true));
    CHECK(!fcitxIBusIsGnomeShell("gnome-shell", false));  // GNOME X11: shell entries only
    // Fcitx5's own GNOME app monitor: virtual contexts named by the ShellApp id
    CHECK(fcitxIBusIsGnomeShell("google-chrome.desktop", true));
    CHECK(fcitxIBusIsGnomeShell("org.gnome.TextEditor.desktop", true));
    CHECK(fcitxIBusIsGnomeShell("window:12", true));
    CHECK(!fcitxIBusIsGnomeShell("google-chrome.desktop", false));
    // X11 / XWayland IBus clients through the same frontend
    for (const char *prog : {"", "chrome", "code", "gtk3-im:google-chrome", "gtk-im", "gtk3-im:foo.desktop",
                             "QIBusInputContext", "xim", "/usr/bin/gnome-shell", "gnome-shell-x", "window:",
                             "window:1a", ".desktop", "x.desktop y", ":1.42"}) {
        CHECK(!fcitxIBusIsGnomeShell(prog, true));
        CHECK(fcitxClientHost("ibus", false, prog, true) == ClientHost::FcitxIBus);
    }
    CHECK(fcitxClientHost("ibus", false, "gnome-shell", true) == ClientHost::FcitxGnomeWayland);
    CHECK(fcitxClientHost("ibus", true, "gnome-shell", true) == ClientHost::FcitxGnomeWayland);
    CHECK(fcitxClientHost("ibus", false, "google-chrome.desktop", true) == ClientHost::FcitxGnomeWayland);
    CHECK(fcitxClientHost("ibus", false, "gnome-shell", false) == ClientHost::FcitxIBus);
    CHECK(fcitxClientHost("ibus", false) == ClientHost::FcitxIBus);  // no program given
    // the program only matters for the ibus frontend
    CHECK(fcitxClientHost("dbus", true, "gnome-shell", true) == ClientHost::FcitxOrdered);
    CHECK(fcitxClientHost("wayland", false, "gnome-shell", true) == ClientHost::FcitxWayland);
    CHECK(fcitxClientHost("xim", false, "gnome-shell", true) == ClientHost::FcitxXim);
    CHECK(hostOrdersForwardedKeys(ClientHost::FcitxGnomeWayland));
    CHECK(!hostOrdersForwardedKeys(ClientHost::FcitxIBus));
    CHECK(!hostSupportsDirect(ClientHost::FcitxGnomeWayland));  // Direct: still no

    // policy
    Settings s;
    s.noUnderline = NoUnderline::ForwardKeys;
    FieldHints shell;
    shell.host = fcitxClientHost("ibus", false, "gnome-shell", true);
    FieldHints x11;
    x11.host = fcitxClientHost("ibus", false, "chrome", true);
    // Chromium app id resolved by GnomeAppMonitor (old Fcitx5) or the virtual context's own
    // program (new Fcitx5, "google-chrome.desktop" → "google-chrome") + proven surrounding
    for (const char *id : {"google-chrome", "google-chrome.desktop", "code", "chromium", "coccoc"}) {
        AppPolicy p = resolveAppPolicy(id, s, true, shell);
        CHECK(p.mode == DisplayMode::Surrounding && p.deleteWithKeys && !p.allowSurroundingEdits);
        CHECK(resolveAppPolicy(id, s, false, shell).mode == DisplayMode::Preedit);  // not proven
        CHECK(!resolveAppPolicy(id, s, false, shell).deleteWithKeys);
        CHECK(!resolveAppPolicy(id, Settings(), true, shell).deleteWithKeys);  // flag off
        // the same Chromium app over X11/XWayland through the ibus frontend: preedit
        AppPolicy px = resolveAppPolicy(id, s, true, x11);
        CHECK(px.mode == DisplayMode::Preedit && !px.deleteWithKeys);
    }
    // gnome-shell with no real app id (monitor pending / portal missing / overview / Alt+F2):
    // generic ⇒ preedit
    for (const char *id : {"gnome-shell", "gnome-shell-overview", "default", "", "window:12", "12"}) {
        AppPolicy p = resolveAppPolicy(id, s, true, shell);
        CHECK(p.mode == DisplayMode::Preedit && !p.deleteWithKeys);
    }
    // non-Chromium apps on the shell path keep their usual policy
    CHECK(!resolveAppPolicy("org.gnome.texteditor", s, true, shell).deleteWithKeys);
    CHECK(!resolveAppPolicy("firefox", s, true, shell).deleteWithKeys);
    // field types and pins still win
    FieldHints url = shell;
    url.urlOrEmail = true;
    CHECK(resolveAppPolicy("google-chrome", s, true, url).mode == DisplayMode::Preedit);
    FieldHints pw = shell;
    pw.sensitive = true;
    CHECK(!resolveAppPolicy("google-chrome", s, true, pw).deleteWithKeys);
    Settings pinned = s;
    pinned.appModes["code"] = "preedit";
    CHECK(resolveAppPolicy("code", pinned, true, shell).mode == DisplayMode::Preedit);
    // mutter 50 drops forwarded keys (or the shell version is not known yet): preedit
    FieldHints dropped = shell;
    dropped.forwardedKeysDropped = true;
    CHECK(resolveAppPolicy("google-chrome", s, true, dropped).mode == DisplayMode::Preedit);
    CHECK(!resolveAppPolicy("google-chrome", s, true, dropped).deleteWithKeys);
}

void testForwardKeysConfig() {
    CHECK(parseConfig("[experimental]\nno_underline = \"forward-keys\"\n").noUnderline == NoUnderline::ForwardKeys);
    CHECK(parseConfig("[experimental]\nno_underline = \"FORWARD-KEYS\"\n").noUnderline == NoUnderline::ForwardKeys);
    CHECK(parseConfig("[experimental]\nno_underline = \"off\"\n").noUnderline == NoUnderline::Off);
    CHECK(parseConfig("[experimental]\nno_underline = \"gnome-ext\"\n").noUnderline == NoUnderline::Off);
    CHECK(parseConfig("[experimental]\nno_underline = true\n").noUnderline == NoUnderline::Off);
    CHECK(parseConfig("[general]\nno_underline = \"forward-keys\"\n").noUnderline == NoUnderline::Off);
    Settings s;
    s.noUnderline = NoUnderline::ForwardKeys;
    CHECK(parseConfig(serializeConfig(s)).noUnderline == NoUnderline::ForwardKeys);
    CHECK(serializeConfig(Settings()).find("no_underline = \"off\"") != std::string::npos);
    std::string t = setConfigValue("[general]\ndisplay_mode = \"preedit\"\n", "experimental", "no_underline",
                                   "\"forward-keys\"");
    CHECK(parseConfig(t).noUnderline == NoUnderline::ForwardKeys);
}

// Rounds of the random forward-keys tests (VT_STRESS_ROUNDS to run more locally).
int stressRounds() {
    const char *e = std::getenv("VT_STRESS_ROUNDS");
    int n = e ? std::atoi(e) : 0;
    return n > 0 ? n : 1000;
}

// Text already in the field before the caret (the host shows it, the Session never typed it).
const char *const kFieldPrefixes[] = {"", "xin chào ", "a", "Tiếng Việt\n", "ê ê ê ", "oo"};

// The other modes are unchanged by the key-edit path: random scripts give the same text, and
// an honest host (lagging 0–2 keys) never makes the Session fall back.
void testForwardKeysAgreesWithSurrounding() {
    std::mt19937 rng(7);
    const std::string alphabet = "aeiouydwsfrxjzcnghtq <";
    for (int round = 0, rounds = stressRounds(); round < rounds; ++round) {
        std::string keys;
        int len = 3 + int(rng() % 14);
        for (int i = 0; i < len; ++i) keys += alphabet[rng() % alphabet.size()];
        std::string prefix = kFieldPrefixes[rng() % (sizeof kFieldPrefixes / sizeof *kFieldPrefixes)];
        std::string want = surroundingNoEdits(keys, prefix);
        FakeClock clock;
        Session s;
        AsyncHost h;
        h.doc = h.reported = prefix;
        forwardKeysSession(s, h, clock);
        // Lagging hosts only at the start of the field: before any of our text is confirmed, a
        // host that shows older text than the word is not told from a wrong one (falls back).
        int lagRand = 1 + int(rng() % 3);
        typeAsync(s, h, keys, prefix.empty() ? lagRand : 1);
        h.apply();
        if (h.screen() == want && !s.surroundingDistrusted()) {
            ++g_pass;
            continue;
        }
        ++g_fail;
        std::fprintf(stderr, "forward-keys [%s]: got [%s] want [%s] distrusted=%d\n", keys.c_str(),
                     h.screen().c_str(), want.c_str(), int(s.surroundingDistrusted()));
        for (auto &l : h.log) std::fprintf(stderr, "  %s\n", l.c_str());
    }
}

// One fault (lost / doubled BackSpace, duplicated commit) somewhere in a random script, the
// host lagging 1–3 keys: once the host has applied it, the next key must notice — either the
// text came out right anyway, or the field is distrusted. Never a silent wrong edit after.
void testForwardKeysRandomFaults() {
    std::mt19937 rng(11);
    const std::string alphabet = "aeiouydwsfrxjnghtc ";
    int detected = 0;
    for (int round = 0, rounds = stressRounds(); round < rounds; ++round) {
        std::string keys;
        int len = 4 + int(rng() % 12);
        for (int i = 0; i < len; ++i) keys += alphabet[rng() % alphabet.size()];
        std::string prefix = kFieldPrefixes[rng() % (sizeof kFieldPrefixes / sizeof *kFieldPrefixes)];
        FakeClock clock;
        Session s;
        AsyncHost h;
        h.doc = h.reported = prefix;
        forwardKeysSession(s, h, clock);
        int every = 1 + int(rng() % 3), at = int(rng() % keys.size()), fault = int(rng() % 3);
        for (int i = 0; i < int(keys.size()); ++i) {
            if (i == at) {
                if (fault == 0) h.dropBackspaces = 1;
                else if (fault == 1) h.extraBackspaces = 1;
                else h.dupCommits = 1;
            }
            typeAsync(s, h, keys.substr(size_t(i), 1), 0);
            if ((i + 1) % every == 0) h.apply();
        }
        h.apply();
        bool fired = h.dropBackspaces == 0 && h.extraBackspaces == 0 && h.dupCommits == 0;
        typeAsync(s, h, "a");  // the next key reads the host back
        std::string want = surroundingNoEdits(keys + "a", prefix);
        bool ok = !fired || s.surroundingDistrusted() || h.screen() == want;
        if (fired && s.surroundingDistrusted()) ++detected;
        if (ok) {
            ++g_pass;
            continue;
        }
        ++g_fail;
        std::fprintf(stderr, "fault %d at %d [%s%s] every %d: got [%s] want [%s]\n", fault, at, prefix.c_str(),
                     keys.c_str(), every, h.screen().c_str(), want.c_str());
        for (auto &l : h.log) std::fprintf(stderr, "  %s\n", l.c_str());
    }
    CHECK(detected > stressRounds() / 10);  // the faults do fire and get caught
}

// MARK: - Crash guard: never delete more than the client last reported

void testClampDeleteToReport() {
    CHECK_EQ(clampDeleteToReport(3, 5), 3);
    CHECK_EQ(clampDeleteToReport(3, 3), 3);
    CHECK_EQ(clampDeleteToReport(3, 2), 2);   // cut to what was reported
    CHECK_EQ(clampDeleteToReport(3, 0), 0);   // empty report: no delete at all
    CHECK_EQ(clampDeleteToReport(3, -1), 3);  // no surrounding text: no limit known
    CHECK_EQ(clampDeleteToReport(0, 5), 0);
    CHECK_EQ(clampDeleteToReport(-2, 5), 0);
}

// GNOME Wayland, "Sửa thẳng trong ô" (Surrounding), typing fast at the very start of an empty
// field: the app's report still says "" while "vie" is on its way. A delete then would reach
// past the start of the report (mutter g_assert → gnome-shell aborts, the user is logged out).
void testDeleteNeverPastReport() {
    {
        Session s;
        Mock m;
        s.setDisplayMode(DisplayMode::Surrounding, m);
        m.hasReported = true;
        m.reported = "";  // the client lags: nothing of ours reported yet
        type(s, m, "vie");
        type(s, m, "e");  // "ê" would delete 1 character, the report holds 0
        CHECK_EQ(m.deletes, 0);
        CHECK_EQ(m.overDeletes, 0);
        CHECK(s.surroundingDistrusted());
        CHECK(s.displayMode() == DisplayMode::Preedit);
        CHECK_EQ(m.screen(), std::string("viee"));  // the key as typed, never a half edit
        type(s, m, "tj ");  // the field goes on in preedit: no delete ever
        CHECK_EQ(m.deletes, 0);
        CHECK_EQ(m.screen(), std::string("vieetj "));
        type(s, m, "vieejt ");
        CHECK_EQ(m.screen(), std::string("vieetj việt "));
        CHECK_EQ(m.deletes, 0);
        s.focusIn();  // a new focus gets a new chance
        CHECK(!s.surroundingDistrusted());
    }
    // A report lagging but holding enough characters (start of the field, "v" of "vie"
    // applied): the delete fits, typed in place as before.
    {
        Session s;
        Mock m;
        s.setDisplayMode(DisplayMode::Surrounding, m);
        type(s, m, "vie");
        m.hasReported = true;
        m.reported = "v";
        type(s, m, "e");
        CHECK_EQ(m.screen(), std::string("viê"));
        CHECK_EQ(m.overDeletes, 0);
        CHECK(!s.surroundingDistrusted());
    }
    // The client takes surrounding text but reports nothing readable (IBus before the field
    // is proven): the Session cannot read, the frontend's limit is 0 — no delete.
    struct Unread : Mock {
        bool textBeforeCursor(std::string &) override { return false; }
        long reportedCharsBeforeCursor() override { return 0; }
    };
    {
        Session s;
        Unread m;
        s.setDisplayMode(DisplayMode::Surrounding, m);
        type(s, m, "toan");
        type(s, m, "s");
        CHECK_EQ(m.deletes, 0);
        CHECK(s.surroundingDistrusted());
        CHECK_EQ(m.screen(), std::string("toans"));
    }
    // No surrounding text at all (-1): nothing limits the delete — unchanged.
    {
        Session s;
        Mock m;
        s.setDisplayMode(DisplayMode::Surrounding, m);
        m.surrounding = false;
        type(s, m, "toans");
        CHECK_EQ(m.screen(), std::string("toán"));
        CHECK(!s.surroundingDistrusted());
    }
}

// Random typing in Surrounding with a client whose report lags 0–3 keys behind: never a delete
// past the report; whenever the field was not distrusted, the text is the honest-host text.
void testDeleteNeverPastReportStress() {
    std::mt19937 rng(23);
    const std::string alphabet = "aeiouydwsfrxjzcnghtq <";
    int fellBack = 0;
    for (int round = 0, rounds = stressRounds(); round < rounds; ++round) {
        std::string keys;
        int len = 2 + int(rng() % 14);
        for (int i = 0; i < len; ++i) keys += alphabet[rng() % alphabet.size()];
        std::string prefix = kFieldPrefixes[rng() % (sizeof kFieldPrefixes / sizeof *kFieldPrefixes)];
        Session s;
        Mock m;
        m.doc = prefix;
        s.setDisplayMode(DisplayMode::Surrounding, m);
        s.setSurroundingEdits(false);
        m.hasReported = true;
        std::vector<std::string> states{m.doc};
        for (char c : keys) {
            size_t lag = rng() % 4;
            m.reported = states[states.size() > lag ? states.size() - 1 - lag : 0];
            type(s, m, std::string(1, c));
            states.push_back(m.doc);
        }
        if (s.surroundingDistrusted()) ++fellBack;
        bool ok = m.overDeletes == 0 && (s.surroundingDistrusted() || m.screen() == surroundingNoEdits(keys, prefix));
        if (ok) {
            ++g_pass;
            continue;
        }
        ++g_fail;
        std::fprintf(stderr, "lagging report [%s%s]: got [%s] overDeletes=%d\n", prefix.c_str(), keys.c_str(),
                     m.screen().c_str(), m.overDeletes);
    }
    CHECK(fellBack > 0);  // the start-of-field case does come up
}

}  // namespace

// MARK: - Tự sửa từ phía trước (retroactive_english, retro_english.h)
// "so fast", not "very fast": "very" is a STRONG English word (engine, 05/11/2026) that already
// completes the run on its own; with "so" the edit still comes at the last word, as these
// cases need.

Settings retroSettings(bool on, bool contextual = true) {
    Settings st;
    st.retroactiveEnglish = on;
    st.contextualEnglish = contextual;
    return st;
}

void testRetroSettingsGate() {
    Settings d;
    CHECK(!d.retroactiveEnglish);  // experimental: default OFF (= offered as a caret suggestion)
    CHECK(d.contextualEnglish);
    CHECK(retro::modeFor(true, true) == retro::Mode::Auto);
    CHECK(retro::modeFor(true, false) == retro::Mode::Offer);
    CHECK(retro::modeFor(false, true) == retro::Mode::Off);
    CHECK(retro::modeFor(false, false) == retro::Mode::Off);
    CHECK(retro::flagWanted(true, true));
    CHECK(retro::flagWanted(true, false));  // the engine flag follows contextual_english
    CHECK(!retro::flagWanted(false, true));
    Settings p = parseConfig("[typing]\nretroactive_english = true\n");
    CHECK(p.retroactiveEnglish);
    CHECK(parseConfig(serializeConfig(p)).retroactiveEnglish);
    // contextual_english off: the switch is inert (same text as with it off).
    for (auto mode : {DisplayMode::Preedit, DisplayMode::Surrounding})
        CHECK_EQ(run("His car is so fast ", mode, retroSettings(true, false)),
                 run("His car is so fast ", mode, retroSettings(false, false)));
}

void testRetroAutoApplies() {
    bothModes("His car is so fast ", "His car is so fast ", retroSettings(true));
    bothModes("His car is so fast ", "Hí cả í so fast ", retroSettings(false));
    bothModes("His car is so fast.", "His car is so fast.", retroSettings(true));
    // Enter / Tab only end the phrase: no rewrite behind the user's back.
    bothModes("His car is so fast\n", "Hí cả í so fast\n", retroSettings(true));
}

void testRetroBackspaceReverts() {
    bothModes("His car is so fast <", "Hí cả í so fast ", retroSettings(true));
    bothModes("His car is so fast <<", "Hí cả í so fast", retroSettings(true));     // 2nd ⌫: plain
    bothModes("His car is so fast x<", "His car is so fast ", retroSettings(true)); // next key only
    bothModes("His car is so fast <now ", "Hí cả í so fast now ", retroSettings(true));
    for (auto mode : {DisplayMode::Preedit, DisplayMode::Surrounding}) {
        Session s;
        Mock m;
        s.applySettings(retroSettings(true));
        s.setDisplayMode(mode, m);
        type(s, m, "His car is so fast ");
        CHECK(s.retroUndoArmed());
        m.doc += "!";  // something the Session did not see
        type(s, m, "<");
        CHECK_EQ(m.screen(), std::string("His car is so fast "));  // ordinary ⌫ deleted "!"
    }
}

// ⌫ right after a restore-to-English puts the Vietnamese rendering back (one key only),
// with retro English on or off; acronyms / glued tokens never compose (30/10/2026).
void testRestoreUndoBackspace() {
    for (bool retro : {false, true}) {
        Settings st = retroSettings(retro);
        bothModes("NAS ", "NAS ", st);           // rare syllable "NÁ": an acronym
        bothModes("NAS <", "NÁ ", st);           // ⌫ = undo the restore, boundary kept
        bothModes("NAS <<", "NÁ", st);           // the 2nd ⌫ is an ordinary one
        bothModes("NAS x<", "NAS ", st);         // any other key drops the chance
        bothModes("NAS <a ", "NÁ a ", st);
        bothModes("google <", "google", st);     // "gôgle" is no Vietnamese: ordinary ⌫
        bothModes("VIEEJT NAM ", "VIỆT NAM ", st);
        bothModes("my_var ", "my_var ", st);     // glued to "_": no Vietnamese tone
        bothModes("100W ", "100W ", st);         // a unit, not "100Ư"
        bothModes("5trawm ", "5trăm ", st);
    }
    for (auto mode : {DisplayMode::Preedit, DisplayMode::Surrounding}) {
        Session s;
        Mock m;
        s.applySettings(defaults());
        s.setDisplayMode(mode, m);
        type(s, m, "NAS ");
        CHECK(s.restoreUndoArmed());
        m.doc += "!";  // something the Session did not see
        type(s, m, "<");
        CHECK_EQ(m.screen(), std::string("NAS "));
    }
}

void testRetroSkippedWhenUnverifiable() {
    for (auto mode : {DisplayMode::Preedit, DisplayMode::Surrounding}) {
        // No surrounding text: never rewrite blindly.
        CHECK_EQ(run("His car is so fast ", mode, retroSettings(true), false), std::string("Hí cả í so fast "));
        // The app changed a word the engine counts on.
        Session s;
        Mock m;
        s.applySettings(retroSettings(true));
        s.setDisplayMode(mode, m);
        type(s, m, "His car is so ");
        const size_t at = m.doc.find("cả");
        CHECK(at != std::string::npos);
        if (at != std::string::npos) m.doc.replace(at, std::string("cả").size(), "ca");
        type(s, m, "fast ");
        CHECK_EQ(m.screen(), std::string("Hí ca í so fast "));
        CHECK(!s.retroUndoArmed());
        // Policy forbids reaching back into committed text (terminal / generic app id).
        Session t;
        Mock n;
        t.applySettings(retroSettings(true));
        t.setDisplayMode(mode, n);
        t.setSurroundingEdits(false);
        type(t, n, "His car is so fast ");
        CHECK_EQ(n.screen(), std::string("Hí cả í so fast "));
    }
}

void testRetroHostLagsBehindTheLastWord() {
    // IBus / Fcitx5 surrounding text follows our commits asynchronously: the word committed
    // by this very key may be missing — the rewritten words must still all be there.
    Session s;
    Mock m;
    s.applySettings(retroSettings(true));
    type(s, m, "His car is so ");
    m.hasReported = true;
    m.reported = m.doc;  // the host has not shown "fast" yet
    type(s, m, "fast ");
    CHECK_EQ(m.screen(), std::string("His car is so fast "));
    // Lagging further (the rewritten words not shown): skip.
    Session t;
    Mock n;
    t.applySettings(retroSettings(true));
    type(t, n, "His car is ");
    n.hasReported = true;
    n.reported = n.doc;
    type(t, n, "so fast ");
    CHECK_EQ(n.screen(), std::string("Hí cả í so fast "));
}

// Offer mode (retroactive_english off, contextual_english on): a caret suggestion, Tab applies.
void testRetroOfferMode() {
    for (auto mode : {DisplayMode::Preedit, DisplayMode::Surrounding}) {
        Session s;
        Mock m;
        s.applySettings(retroSettings(false));
        s.setDisplayMode(mode, m);
        type(s, m, "His car is so fast ");
        CHECK_EQ(m.screen(), std::string("Hí cả í so fast "));  // nothing changed yet
        CHECK(s.hint() && s.hint()->kind == CaretSuggestion::Kind::Retro);
        if (s.hint()) {
            CHECK_EQ(s.hint()->display, std::string("His car is"));
            CHECK_EQ(s.hint()->replace, std::string("í cả í so fast "));
            CHECK_EQ(s.hint()->insert, std::string("is car is so fast "));
        }
        CHECK_EQ(m.hintShown, std::string("His car is   Tab"));
        CHECK(!s.retroUndoArmed());
        type(s, m, "\t");  // accept: the verified rewrite, the Tab is consumed
        CHECK_EQ(m.screen(), std::string("His car is so fast "));
        CHECK(!s.hint());
        CHECK(m.hintShown.empty());
        type(s, m, "now ");
        CHECK_EQ(m.screen(), std::string("His car is so fast now "));

        // Any other key dismisses it and goes on as usual.
        Session t;
        Mock n;
        t.applySettings(retroSettings(false));
        t.setDisplayMode(mode, n);
        type(t, n, "His car is so fast x");
        CHECK(!t.hint());
        CHECK(n.hintShown.empty());
        CHECK_EQ(n.screen(), std::string("Hí cả í so fast x"));

        // Auto: applied, nothing offered. contextual_english off: nothing at all.
        Session a;
        Mock am;
        a.applySettings(retroSettings(true));
        a.setDisplayMode(mode, am);
        type(a, am, "His car is so fast ");
        CHECK(!a.hint());
        CHECK_EQ(am.hintShows, 0);
        for (bool sw : {false, true}) {
            Session o;
            Mock om;
            o.applySettings(retroSettings(sw, false));
            o.setDisplayMode(mode, om);
            type(o, om, "His car is so fast ");
            CHECK(!o.hint());
            CHECK_EQ(om.screen(), std::string("Hí cả í so fast "));
        }
        // Enter never offers (it may have sent the message).
        Session e;
        Mock em;
        e.applySettings(retroSettings(false));
        e.setDisplayMode(mode, em);
        type(e, em, "His car is so fast\n");
        CHECK(!e.hint());
    }
}

void testRetroOfferNeedsVerifiedText() {
    for (auto mode : {DisplayMode::Preedit, DisplayMode::Surrounding}) {
        // The app changed a word the engine counts on: no suggestion.
        Session s;
        Mock m;
        s.applySettings(retroSettings(false));
        s.setDisplayMode(mode, m);
        type(s, m, "His car is so ");
        const size_t at = m.doc.find("cả");
        CHECK(at != std::string::npos);
        if (at != std::string::npos) m.doc.replace(at, std::string("cả").size(), "ca");
        type(s, m, "fast ");
        CHECK(!s.hint());
        // No surrounding text / edits not allowed here (terminal, generic app id): none either.
        Session t;
        Mock n;
        n.surrounding = false;
        t.applySettings(retroSettings(false));
        t.setDisplayMode(mode, n);
        type(t, n, "His car is so fast ");
        CHECK(!t.hint());
        Session u;
        Mock p;
        u.applySettings(retroSettings(false));
        u.setDisplayMode(mode, p);
        u.setSurroundingEdits(false);
        type(u, p, "His car is so fast ");
        CHECK(!u.hint());
        // Shown, then the text changed before Tab: not applied, the Tab goes on.
        Session v;
        Mock q;
        v.applySettings(retroSettings(false));
        v.setDisplayMode(mode, q);
        type(v, q, "His car is so fast ");
        CHECK(v.hint());
        q.doc += "!";
        type(v, q, "\t");
        CHECK_EQ(q.screen(), std::string("Hí cả í so fast !\t"));
    }
    // The host lags by the word this key committed: offered (the head "H" still found).
    Session s;
    Mock m;
    s.applySettings(retroSettings(false));
    s.setDisplayMode(DisplayMode::Surrounding, m);
    type(s, m, "His car is so ");
    m.hasReported = true;
    m.reported = m.doc;
    type(s, m, "fast ");
    CHECK(s.hint() && s.hint()->display == "His car is");
}

void testRetroOfferWinsOverOtherSuggestions() {
    for (bool offer : {true, false}) {
        Settings st = retroSettings(false, offer);  // offer: contextual on; control: off
        st.wordPrediction = true;
        Session s;
        Mock m;
        std::vector<HintRequest> reqs;
        s.setHintSink([&reqs](const HintRequest &r) { reqs.push_back(r); });
        s.applySettings(st);
        s.setDisplayMode(DisplayMode::Surrounding, m);
        type(s, m, "His car is so fast ");
        CHECK(!reqs.empty());  // the next-word request after the space
        if (reqs.empty()) continue;
        CaretSuggestion typo;
        typo.kind = CaretSuggestion::Kind::Typo;
        typo.display = "fát";
        typo.replace = "fast ";
        typo.insert = "fát ";
        s.deliverHint(reqs.back().gen, typo, m);
        CHECK(s.hint() != nullptr);
        if (!s.hint()) continue;
        if (offer) {
            CHECK(s.hint()->kind == CaretSuggestion::Kind::Retro);  // the retro offer wins
            CHECK_EQ(m.hintShown, std::string("His car is   Tab"));
        } else {
            CHECK(s.hint()->kind == CaretSuggestion::Kind::Typo);  // control: the path works
        }
    }
}

// MARK: - Đoán từ trùng theo tần suất (english_by_frequency, engine englishByFrequency)

Settings frequencySettings(bool retroAuto, bool frequency = true, bool contextual = true) {
    Settings st = retroSettings(retroAuto, contextual);
    st.englishByFrequency = frequency;
    return st;
}

void testFrequencySettingsGate() {
    Settings d;
    CHECK(!d.englishByFrequency);  // experimental: default OFF
    Settings p = parseConfig("[typing]\nenglish_by_frequency = true\n");
    CHECK(p.englishByFrequency);
    CHECK(parseConfig(serializeConfig(p)).englishByFrequency);
    CHECK(!parseConfig(serializeConfig(d)).englishByFrequency);
    // contextual_english off: inert (same text as with it off).
    for (auto mode : {DisplayMode::Preedit, DisplayMode::Surrounding})
        CHECK_EQ(run("his huwngr ", mode, frequencySettings(false, true, false)),
                 run("his huwngr ", mode, frequencySettings(false, false, false)));
}

// MARK: - Tự thêm dấu mũ (auto_circumflex, engine autoCircumflex, issue #166)

void testAutoCircumflexSetting() {
    Settings d;
    CHECK(!d.autoCircumflex);  // default OFF
    Settings p = parseConfig("[typing]\nauto_circumflex = true\n");
    CHECK(p.autoCircumflex);
    CHECK(parseConfig(serializeConfig(p)).autoCircumflex);
    CHECK(!parseConfig(serializeConfig(d)).autoCircumflex);
    for (auto mode : {DisplayMode::Preedit, DisplayMode::Surrounding})
        CHECK(run("vietj ", mode, d) != "việt ");   // off: no circumflex added
    bothModes("vietj ", "việt ", p);
    bothModes("benhj ", "bệnh ", p);
    bothModes("quan ", "quan ", p);             // real plain rime stays
}

// The flip-back is applied AUTOMATICALLY: in offer mode (retroactive_english off) too.
void testFrequencyFlipBack() {
    for (bool retroAuto : {false, true}) {
        Settings st = frequencySettings(retroAuto);
        bothModes("His ", "His ", st);                 // start of a phrase: English
        bothModes("his huwngr ", "hí hửng ", st);      // known pair: flipped back
        bothModes("His huwngr ", "Hí hửng ", st);
        bothModes("his his ", "hí hí ", st);           // reduplication
        bothModes("His huwngr ", "Hí hửng ", frequencySettings(retroAuto, false));  // off
    }
    for (auto mode : {DisplayMode::Preedit, DisplayMode::Surrounding}) {
        Session s;
        Mock m;
        s.applySettings(frequencySettings(false));
        s.setDisplayMode(mode, m);
        type(s, m, "his huwngr ");
        CHECK(!s.hint());  // applied, not offered
        CHECK_EQ(m.screen(), std::string("hí hửng "));
    }
}

// Enter: the flip lands BEFORE the newline (a regular retro edit never applies there).
void testFrequencyFlipBackBeforeEnter() {
    for (bool retroAuto : {false, true}) {
        bothModes("his huwngr\n", "hí hửng\n", frequencySettings(retroAuto));
        for (auto mode : {DisplayMode::Preedit, DisplayMode::Surrounding}) {
            Session s;
            Mock m;
            s.applySettings(frequencySettings(retroAuto));
            s.setDisplayMode(mode, m);
            type(s, m, "his huwngr\n");
            CHECK(!s.retroUndoArmed());  // Enter: no ⌫-undo
        }
    }
}

void testFrequencyFlipBackNeedsVerifiedText() {
    for (auto mode : {DisplayMode::Preedit, DisplayMode::Surrounding}) {
        // No surrounding text: never rewrite blindly.
        CHECK_EQ(run("his huwngr ", mode, frequencySettings(false), false), std::string("his hửng "));
        Session s;
        Mock m;
        s.applySettings(frequencySettings(false));
        s.setDisplayMode(mode, m);
        type(s, m, "his ");
        m.doc = "hiss ";  // something the Session did not see
        type(s, m, "huwngr ");
        CHECK_EQ(m.screen(), std::string("hiss hửng "));
    }
}

void testRetroOfferDisplay() {
    CHECK_EQ(retro::offerDisplay("Hí cả í very fast", "í cả í very fast", "is car is very fast", 0),
             std::string("His car is"));
    CHECK_EQ(retro::offerDisplay("Hí cả í very ", "í cả í very fast", "is car is very fast", 4),
             std::string("His car is"));  // host lag
    CHECK_EQ(retro::offerDisplay("winter í coming", "í coming", "is coming", 0), std::string("is"));
    CHECK(retro::offerDisplay("x", "same", "same", 0).empty());
    CHECK(retro::makeOffer("Hí cả í very fast", "í cả í very fast", "is car is very fast", 0, 3, 0).empty());
    const retro::Offer o = retro::makeOffer("Hí cả í very fast", "í cả í very fast", "is car is very fast", ',', 3, 0);
    CHECK_EQ(o.replace, std::string("í cả í very fast,"));
    CHECK_EQ(o.insert, std::string("is car is very fast,"));
    CHECK_EQ(o.words, 3);
    CHECK(hints::keyAction(CaretSuggestion::Kind::Retro, ks::Tab, 0) == hints::KeyAction::Accept);
    CHECK(hints::keyAction(CaretSuggestion::Kind::Retro, ks::Return, 0) == hints::KeyAction::DismissPass);
    CHECK(hints::keyAction(CaretSuggestion::Kind::Retro, ks::Escape, 0) == hints::KeyAction::DismissConsume);
}

void testRetroDecisions() {
    using retro::Apply;
    const std::string before = "Hí cả í very fast", expected = "í cả í very fast";
    CHECK(retro::decideApply(true, true, false, before, expected, 0) == Apply::Apply);
    CHECK(retro::decideApply(true, true, false, "Hí ca í very fast", expected, 0) == Apply::Mismatch);
    CHECK(retro::decideApply(true, true, false, "Hí cả í very ", expected, 4) == Apply::Apply);
    CHECK(retro::decideApply(true, true, false, "Hí cả í very ", expected, 0) == Apply::Mismatch);
    CHECK(retro::decideApply(true, true, false, "Hí cả í ", expected, 4) == Apply::Mismatch);
    CHECK(retro::decideApply(true, true, false, "", expected, 4) == Apply::Unverifiable);
    CHECK(retro::decideApply(false, true, false, before, expected, 0) == Apply::Unverifiable);
    CHECK(retro::decideApply(true, false, false, before, expected, 0) == Apply::Unverifiable);
    CHECK(retro::decideApply(true, true, true, before, expected, 0) == Apply::Unverifiable);
    CHECK(retro::decideApply(true, true, false, before, "", 0) == Apply::Mismatch);
    const retro::Undo u = retro::makeUndo(expected, "is car is very fast", ' ');
    CHECK_EQ(u.applied, std::string("is car is very fast "));
    CHECK_EQ(u.original, std::string("í cả í very fast "));
    CHECK(retro::undoApplies(u, true, true, false, "His car is very fast "));
    CHECK(!retro::undoApplies(u, true, true, false, "His car is very fast !"));
    CHECK(!retro::undoApplies(u, true, true, true, "His car is very fast "));
    CHECK(!retro::undoApplies(u, false, true, false, "His car is very fast "));
    CHECK(!retro::undoApplies(u, true, false, false, "His car is very fast "));
    CHECK(!retro::makeUndo(expected, "is", 0).armed());
}

int main() {
    testRetroSettingsGate();
    testRetroAutoApplies();
    testRetroBackspaceReverts();
    testRestoreUndoBackspace();
    testRetroSkippedWhenUnverifiable();
    testRetroHostLagsBehindTheLastWord();
    testRetroDecisions();
    testRetroOfferMode();
    testRetroOfferNeedsVerifiedText();
    testRetroOfferWinsOverOtherSuggestions();
    testAutoCircumflexSetting();
    testFrequencySettingsGate();
    testFrequencyFlipBack();
    testFrequencyFlipBackBeforeEnter();
    testFrequencyFlipBackNeedsVerifiedText();
    testRetroOfferDisplay();
    testBasicTyping();
    testPreeditIsUnderlinedComposition();
    testSurroundingHasNoPreedit();
    testShortcuts();
    testSymbolShortcuts();
    testCtrlChordCommits();
    testToggleHotkey();
    testPasswordLiteral();
    testDeadKeys();
    testReopenAfterBoundary();
    testReEditAfterCaretMove();
    testVerifyBeforeDelete();
    testFinishCommitsPreedit();
    testOverflowNeverLosesText();
    testVniAndLiveSettings();
    testVniKeypadDigitsAreBoundaries();
    testModesAgreeOnRandomScripts();
    testConfigParse();
    testSetConfigValue();
    testWriteFileAtomic();
    testShortcutFile();
    testShortcutFileQuoting();
    testHotkeyParse();
    testAppPolicy();
    testUnknownAppIdsArePreeditWithoutEdits();
    testProvenUnknownAppAllowed();
    testTerminalStoreTypesVietnamese();
    testSelectionBlocksDeleteAndReEdit();
    testGtk3SelectionBlocksReachBack();
    testForcedPreeditList();
    testModeSwitchWaitsForWordEnd();
    testMoreGenericIdsAndSnap();
    testFieldHints();
    testDefaultOffApps();
    testWineAppsTypeVietnamese();
    testMoreForcedPreedit();
    testChromiumFamilyForcedPreedit();
    testElectronAppsAreChromium();
    testCommitBeforeHidingPreedit();
    testDeleteOnlyEditSendsEmptyCommit();
    testAppStateStoreAndWatcher();
    testAppStateStoreSkipsUnknownIds();
    testAppStateStoreCap();
    testPolicyCache();
    testWatcherReloadCosts();
    testGnomePayloads();
    testGnomeFocusTracker();
    testGnomeResolvedPolicy();
    testGnomeSessionDetection();
    testDirectBlindTerminal();
    testDirectBackspaceMidWord();
    testDirectResets();
    testIssue163DirectKeystreamReopen();
    testIssue163ReachBackNotes();
    testDirectPolicyTable();
    testUnderlineAndDirectSettings();
    testCtrlTapCommitsWord();
    testUnderlineMisspelledOffByDefault();
    testUnderlineMisspelledFollowsPreedit();
    testUnderlineMisspelledSkipsValidAndEnglish();
    testUnderlineMisspelledPreeditOnly();
    testUnderlineMisspelledConfig();
    testUnderlineMisspelledSharedVectors();
    testTextToolSettings();
    testAddTonesHotkey();
    testTextToolNamesAndSelection();
    testPrimaryFirstToolWins();
    testSurroundingCache();
    testTextToolHelper();
    testForwardKeysTypesInPlace();
    testForwardKeysHostLags();
    testForwardKeysLostBackspace();
    testForwardKeysDoubledBackspace();
    testForwardKeysDuplicatedCommit();
    testForwardKeysTimeout();
    testForwardKeysSelectionAndKeys();
    testForwardKeysPolicy();
    testFcitxGnomeWaylandHost();
    testMutterForwardedKeys();
    testForwardKeysConfig();
    testForwardKeysAgreesWithSurrounding();
    testForwardKeysRandomFaults();
    testClampDeleteToReport();
    testDeleteNeverPastReport();
    testDeleteNeverPastReportStress();
    std::printf("common tests: %d passed, %d failed\n", g_pass, g_fail);
    return g_fail ? 1 : 0;
}
