// End-to-end plumbing tests: key sequence -> TypingSession -> FakeDocument, in both
// output modes, against the real C++ engine (windows/engine).
#include <viettelex/vtx_engine.h>

#include "caret_hints.h"
#include "fake_document.h"
#include "session.h"
#include "settings.h"
#include "shortcuts.h"
#include "app_policy.h"
#include "tip_caches.h"
#include "typed_word.h"
#include "ipc.h"
#include "test.h"

using namespace vtx;
using vtx::test::FakeDocument;

namespace {

constexpr char kLeft = '\x01';   // Left arrow
constexpr char kCtrlZ = '\x02';  // a Ctrl chord

struct Rig {
    Settings settings;
    TypingSession s;
    FakeDocument doc;
    explicit Rig(OutputMode m) {
        s.setOutputMode(m);
        apply();
    }
    void apply() {
        SessionOptions o;
        o.engineFlags = settings.engineFlags();
        o.autoRestore = settings.autoRestore;
        o.reEditWord = settings.reEditWord;
        o.underlineMisspelled = settings.underlineMisspelled;
        o.retroOffer = retro::modeFor(settings.contextualEnglish, settings.retroactiveEnglish) == retro::Mode::Offer;
        o.shortcuts = &settings.shortcuts;
        s.configure(o);
    }
    void key(char c) {
        KeyInput k;
        if (c == '\b') k.kind = KeyKind::Backspace;
        else if (c == '\n') k.kind = KeyKind::Boundary;
        else if (c == kLeft) k.kind = KeyKind::Navigation;
        else if (c == kCtrlZ) k.kind = KeyKind::Chord;
        else { k.kind = KeyKind::Char; k.ch = static_cast<unsigned char>(c); }
        send(k);
    }
    void send(const KeyInput& k) {
        const bool wanted = s.wantsKey(k);
        if (!wanted) s.noteKeyPassedBy(k);  // the TIP: keys let through still reach the engine
        bool eaten = wanted && s.handleKey(k, doc);
        if (eaten) return;
        // Invariant: a key reaching the app never finds a composition open.
        CHECK(!doc.comp);
        switch (k.kind) {
            case KeyKind::Char: doc.appInsert(static_cast<char16_t>(k.ch)); break;
            case KeyKind::Backspace: doc.appBackspace(); break;
            case KeyKind::Boundary: doc.appInsert(u'\n'); break;
            case KeyKind::Navigation:
                if (doc.caret) doc.caret = doc.anchor = doc.caret - 1;
                s.reset();  // the TIP sees a selection change it did not make
                break;
            default: break;
        }
    }
    void type(const char* keys) {
        for (const char* p = keys; *p; ++p) key(*p);
    }
    std::string text() const { return utf16ToUtf8(doc.text); }
};

void bothModes(const char* keys, const char* want) {
    for (OutputMode m : {OutputMode::Composition, OutputMode::InPlace}) {
        Rig r(m);
        r.type(keys);
        CHECK_EQ(r.text(), std::string(want));
        CHECK(!r.doc.comp || r.s.wordActive());
    }
}

}  // namespace

TEST(session_basic_words) {
    bothModes("tieengs vieetj ", "tiếng việt ");
    bothModes("xin chaof cacs banj.", "xin chào các bạn.");
    bothModes("caacs ", "cấc ");
    bothModes("dduwowngf ", "đường ");
}

TEST(session_composition_holds_word_until_boundary) {
    Rig r(OutputMode::Composition);
    r.type("vieetj");
    CHECK(r.doc.comp);
    CHECK_EQ(r.text(), std::string("việt"));
    r.type(" ");
    CHECK(!r.doc.comp);
    CHECK_EQ(r.text(), std::string("việt "));
}

TEST(session_enter_commits_then_passes) {
    bothModes("vieetj\n", "việt\n");
}

TEST(session_backspace_deletes_displayed_char) {
    bothModes("khoo\b", "kh");
    bothModes("khoo\b\b\ba", "a");
}

TEST(session_auto_restore) {
    bothModes("google ", "google ");
    bothModes("windows ", "windows ");
}

// Acronyms / glued separators reach the engine through every boundary key, retro or not.
TEST(session_acronym_and_glue) {
    for (bool contextual : {true, false}) {
        for (OutputMode m : {OutputMode::Composition, OutputMode::InPlace}) {
            Rig r(m);
            r.settings.contextualEnglish = contextual;   // off: VTX_RETRO_ENGLISH off too
            r.apply();
            r.type("NAS VIEEJT my_var 100W 5trawm ");
            CHECK_EQ(r.text(), std::string("NAS VIỆT my_var 100W 5trăm "));
        }
    }
}

// ⌫ right after a restore-to-English puts the Vietnamese back (one key, verified).
TEST(session_restore_undo) {
    for (bool contextual : {true, false}) {
        for (OutputMode m : {OutputMode::Composition, OutputMode::InPlace}) {
            Rig r(m);
            r.settings.contextualEnglish = contextual;
            r.apply();
            r.type("NAS ");
            CHECK_EQ(r.text(), std::string("NAS "));
            CHECK(r.s.restoreUndoArmed());
            r.key('\b');
            CHECK_EQ(r.text(), std::string("NÁ "));   // boundary kept, like the retro undo
            CHECK_EQ(r.s.restoreUndoCount(), 1);
            CHECK(!r.s.restoreUndoArmed());
            r.key('\b');                               // the next ⌫ is an ordinary one
            CHECK_EQ(r.text(), std::string("NÁ"));

            Rig k(m);                                  // any other key drops the chance
            k.settings.contextualEnglish = contextual;
            k.apply();
            k.type("NAS a\b\b");
            CHECK_EQ(k.text(), std::string("NAS"));
            CHECK_EQ(k.s.restoreUndoCount(), 0);

            Rig e(m);                                  // Enter: no undo (may have sent)
            e.settings.contextualEnglish = contextual;
            e.apply();
            e.type("NAS\n");
            CHECK(!e.s.restoreUndoArmed());

            Rig g(m);                                  // glued to code: ⌫ is editing
            g.settings.contextualEnglish = contextual;
            g.apply();
            g.type("my_var ");
            CHECK(!g.s.restoreUndoArmed());
        }
    }
    // Inside an English run: "he is" restores "is"; ⌫ gives "í" back and ends the run.
    Rig c(OutputMode::InPlace);
    c.type("he is \b");
    CHECK_EQ(c.text(), std::string("he í "));
    CHECK(!c.s.previousWordEnglish());
}

TEST(session_auto_restore_off_keeps_composed) {
    for (OutputMode m : {OutputMode::Composition, OutputMode::InPlace}) {
        Rig r(m);
        r.settings.autoRestore = false;
        r.apply();
        r.type("google ");
        CHECK(r.text() != "google ");
    }
}

TEST(session_shortcut_expansion) {
    for (OutputMode m : {OutputMode::Composition, OutputMode::InPlace}) {
        Rig r(m);
        r.settings.shortcuts[u"vn"] = u"Việt Nam";
        r.apply();
        r.type("vn ");
        CHECK_EQ(r.text(), std::string("Việt Nam "));
    }
}

TEST(session_shortcut_not_after_digit_or_token) {
    for (OutputMode m : {OutputMode::Composition, OutputMode::InPlace}) {
        Rig r(m);
        r.settings.shortcuts[u"h"] = u"giờ";
        r.apply();
        r.type("5h /h #h h ");
        CHECK_EQ(r.text(), std::string("5h /h #h giờ "));
    }
}

TEST(session_reopen_after_space) {
    // issue #40: "tháy ␣ ⌫ a" -> "thấy"
    bothModes("thays \ba", "thấy");
}

// The session hands the apostrophe to the engine: contraction stems stay English
// ("doesn't", not "doén't"), a Vietnamese word in quotes stays Vietnamese.
TEST(session_contraction_at_apostrophe) {
    bothModes("it doesn't ", "it doesn't ");
    bothModes("isn't won't there's ", "isn't won't there's ");
    bothModes("'tieesng' ", "'tiếng' ");
}

// A restore that changed nothing on screen keeps the ⌫ re-open: "hoc ␣ ⌫ j" -> "học".
TEST(session_reopen_after_noop_restore) {
    bothModes("hoc \bj", "học");
    bothModes("tien \bs", "tién");
}

TEST(session_reopen_needs_fresh_boundary) {
    // Typing another char after the space disarms the re-open: the two ⌫ are the
    // app's own, and no word is left open in the engine.
    for (OutputMode m : {OutputMode::Composition, OutputMode::InPlace}) {
        Rig r(m);
        r.type("thays .\b\b");
        CHECK_EQ(r.text(), std::string("tháy"));
        CHECK(!r.s.wordActive());
        CHECK(!r.doc.comp);
        r.type("a");  // 'a' is an ordinary letter: no re-edit either
        CHECK_EQ(r.text(), std::string("tháya"));
    }
}

// The hook's ⌫ re-open (app/core/hook_reopen.h): the caller vouches for the screen; the
// session only takes a word back that its keys compose to exactly, in place, between words.
TEST(session_reopen_committed_blind) {
    Rig r(OutputMode::InPlace);
    r.type("toans ");
    const std::u16string raw = r.s.lastCommitRaw(), text = r.s.lastCommitText();
    CHECK_EQ(text, std::u16string(u"toán"));
    r.doc.appBackspace();  // the ⌫ the app deletes the space with
    CHECK(r.s.reopenCommitted(raw.data(), int(raw.size()), text.data(), int(text.size())));
    CHECK(r.s.wordActive());
    CHECK_EQ(r.s.shown(), text);
    CHECK_EQ(r.s.rawKeys(), raw);
    r.type("f");
    CHECK_EQ(r.text(), std::string("toàn"));
    // A word in progress: refused.
    CHECK(!r.s.reopenCommitted(raw.data(), int(raw.size()), text.data(), int(text.size())));
    // An older word (not the engine's last commit) is replayed from its keys.
    Rig o(OutputMode::InPlace);
    o.type("toan viet ");
    const char16_t k1[] = u"toan";
    CHECK(o.s.reopenCommitted(k1, 4, k1, 4));
    CHECK_EQ(o.s.shown(), std::u16string(u"toan"));
    // Keys that do not compose to the text (restored English, a mismatch): refused, no word.
    Rig m(OutputMode::InPlace);
    const char16_t keys[] = u"toans", restored[] = u"toans";
    CHECK(!m.s.reopenCommitted(keys, 5, restored, 5));
    CHECK(!m.s.wordActive());
    CHECK(!m.s.reopenCommitted(keys, 0, restored, 0));
    // Composition: the word is not plain text on screen — never.
    Rig c(OutputMode::Composition);
    const char16_t t[] = u"toán";
    CHECK(!c.s.reopenCommitted(keys, 5, t, 4));
    CHECK(!c.s.wordActive());
}

TEST(session_reedit_word_before_caret) {
    for (OutputMode m : {OutputMode::Composition, OutputMode::InPlace}) {
        Rig r(m);
        r.doc.setText(u"xin chao");
        r.type("f ");
        CHECK_EQ(r.text(), std::string("xin chào "));
    }
}

TEST(session_reedit_disabled) {
    for (OutputMode m : {OutputMode::Composition, OutputMode::InPlace}) {
        Rig r(m);
        r.settings.reEditWord = false;
        r.apply();
        r.doc.setText(u"chao");
        r.type("f");
        CHECK_EQ(r.text(), std::string("chaof"));
    }
}

TEST(session_reedit_skips_non_transforming_key) {
    for (OutputMode m : {OutputMode::Composition, OutputMode::InPlace}) {
        Rig r(m);
        r.doc.setText(u"ba");
        r.type("n");
        CHECK_EQ(r.text(), std::string("ban"));
    }
}

TEST(session_inplace_external_change_resyncs_at_next_letter) {
    Rig r(OutputMode::InPlace);
    r.type("vie");
    // The app rewrote the text under us (autocorrect, collaborative edit...).
    r.doc.setText(u"xyz");
    r.type("e");  // our word is gone: a NEW word starts at this letter
    CHECK_EQ(r.text(), std::string("xyze"));
    CHECK(r.s.wordActive());
    CHECK(!r.s.contextFellBack());  // a desync is not a reason to give up in-place
    r.type("e ");
    CHECK_EQ(r.text(), std::string("xyzê "));
}

TEST(session_composition_refused_is_literal) {
    Rig r(OutputMode::Composition);
    r.doc.refuseEdits = true;
    r.type("aa");
    CHECK_EQ(r.text(), std::string("aa"));
}

TEST(session_navigation_commits) {
    bothModes("vieetj" "\x01" "x", "việxt");
}

TEST(session_chord_inplace_resets_without_edit) {
    Rig r(OutputMode::InPlace);
    r.type("chao");
    int edits = r.doc.edits;
    r.key(kCtrlZ);
    CHECK_EQ(r.doc.edits, edits);
    CHECK(!r.s.wordActive());
}

TEST(session_chord_composition_commits) {
    Rig r(OutputMode::Composition);
    r.type("vieetj");
    r.key(kCtrlZ);
    CHECK(!r.doc.comp);
    CHECK_EQ(r.text(), std::string("việt"));
}

TEST(session_overflow_passes_rest_raw) {
    std::string keys(40, 'a');
    keys[1] = 'b';  // "abaaaa..." never transforms into one syllable anyway
    for (OutputMode m : {OutputMode::Composition, OutputMode::InPlace}) {
        Rig r(m);
        r.type(keys.c_str());
        r.type(" ");
        CHECK_EQ(r.doc.text.size(), keys.size() + 1);
        CHECK(!r.doc.comp);
    }
}

TEST(session_flush_on_toggle) {
    Rig r(OutputMode::Composition);
    r.type("vieetj");
    r.s.flush(r.doc);
    CHECK(!r.doc.comp);
    CHECK_EQ(r.text(), std::string("việt"));
    r.type("s");  // English now? no: session is mode-agnostic; caller gates on V/E.
}

TEST(session_vni_mode) {
    for (OutputMode m : {OutputMode::Composition, OutputMode::InPlace}) {
        Rig r(m);
        r.settings.vniMode = true;
        r.apply();
        r.type("vie65t ");
        CHECK_EQ(r.text(), std::string("việt "));
    }
}

// #124: numpad digits are never VNI marks — they end the word and reach the app; the
// number row keeps marking.
TEST(session_vni_numpad_digits_are_boundaries) {
    for (OutputMode m : {OutputMode::Composition, OutputMode::InPlace}) {
        Rig r(m);
        r.settings.vniMode = true;
        r.apply();
        r.type("a");
        r.send(classifyKey(vk::Numpad0 + 1, Modifiers{}));
        r.type("a1 ");
        r.send(classifyKey(vk::Numpad0, Modifiers{}));
        CHECK_EQ(r.text(), std::string("a1\xc3\xa1 0"));
        CHECK(!r.doc.comp);
    }
}

TEST(session_uppercase) {
    bothModes("VIEETJ Nam ", "VIỆT Nam ");
}

TEST(session_wants_key_is_superset) {
    Rig r(OutputMode::InPlace);
    KeyInput space{KeyKind::Char, U' '};
    KeyInput bs{KeyKind::Backspace, 0};
    KeyInput nav{KeyKind::Navigation, 0};
    CHECK(!r.s.wantsKey(space));
    CHECK(!r.s.wantsKey(bs));
    CHECK(!r.s.wantsKey(nav));
    r.type("a");
    CHECK(r.s.wantsKey(space));
    CHECK(r.s.wantsKey(bs));
    CHECK(r.s.wantsKey(nav));
}

TEST(session_orphan_composition_is_closed_not_overwritten) {
    Rig r(OutputMode::Composition);
    r.type("vieetj");
    r.s.reset();  // e.g. the TIP lost track (selection moved) before ending it
    CHECK(r.doc.comp);
    r.type("a");
    CHECK_EQ(r.text(), std::string("việta"));
    r.type(" ");
    CHECK_EQ(r.text(), std::string("việta "));
    CHECK(!r.doc.comp);
}

TEST(session_reedit_only_on_diacritic_keys) {
    for (OutputMode m : {OutputMode::Composition, OutputMode::InPlace}) {
        Rig r(m);
        r.doc.setText(u"ca");
        r.type("a");  // doubling letter: ordinary letter, no re-edit
        CHECK_EQ(r.text(), std::string("caa"));
        Rig w(m);
        w.doc.setText(u"tu");
        w.type("w");  // horn: diacritic-only
        CHECK_EQ(w.text(), std::string("tư"));
    }
    CHECK(isDiacriticOnlyKey(U'S', false));
    CHECK(!isDiacriticOnlyKey(U'a', false));
    CHECK(isDiacriticOnlyKey(U'6', true));
    CHECK(!isDiacriticOnlyKey(U's', true));
}

TEST(default_mode_is_in_place) {
    TypingSession t;
    CHECK(t.outputMode() == OutputMode::InPlace);
    std::map<std::string, AppMode> none;
    CHECK(resolveAppMode("notepad.exe", none) == AppMode::InPlace);   // implicit default
    CHECK(resolveAppMode("chrome.exe", none) == AppMode::InPlace);
    CHECK(resolveAppMode("mstsc.exe", none) == AppMode::Off);         // built-ins unchanged
}

TEST(migration_keeps_explicit_choices) {
    // A pre-1.0.9 snapshot: one app pinned to composition, one to hook. Implicit apps now
    // resolve to in-place; the explicit choices survive.
    Settings old;
    old.appModes["word.exe"] = AppMode::Composition;
    old.appModes["game.exe"] = AppMode::HookFallback;
    std::vector<uint8_t> b = serialize(old);
    Settings now;
    CHECK(deserialize(b.data(), b.size(), now));
    CHECK(resolveAppMode("word.exe", now.appModes) == AppMode::Composition);
    CHECK(resolveAppMode("game.exe", now.appModes) == AppMode::HookFallback);
    CHECK(resolveAppMode("excel.exe", now.appModes) == AppMode::InPlace);
}

TEST(in_place_falls_back_to_composition_when_unreadable) {
    Rig r(OutputMode::InPlace);
    r.doc.unreadable = true;
    r.type("vieetj ");
    CHECK_EQ(r.text(), std::string("việt "));   // typed through composition, not corrupted
    CHECK(r.s.contextFellBack());
    r.s.resetContext();                          // new field: in-place again
    CHECK(!r.s.contextFellBack());
}

TEST(in_place_verification_failure_falls_back_for_the_field) {
    Rig r(OutputMode::InPlace);
    r.doc.refuseReplace = true;  // the control will not take our in-place edit
    r.type("aa");                // replace refused: this key literal, field -> composition
    CHECK_EQ(r.text(), std::string("aa"));
    CHECK(r.s.contextFellBack());
    r.type(" vieetj ");
    CHECK_EQ(r.text(), std::string("aa việt "));
}

TEST(omnibox_autocomplete_suffix_is_never_deleted) {
    // Chrome/Edge address bar: after each typed key the app selects a suggested suffix
    // AFTER the caret. Our edits touch only the word before the insertion point.
    Rig r(OutputMode::InPlace);
    auto suggest = [&](const std::u16string& suffix) {  // app autocompletes
        r.doc.text += suffix;
        r.doc.anchor = r.doc.text.size();                // selection [caret, end]
    };
    r.type("vie");
    suggest(u"tnam.vn");
    r.type("e");                                         // e -> ê before the caret
    CHECK_EQ(r.text(), std::string("viêtnam.vn"));
    CHECK(r.doc.hi() - r.doc.lo() == 7);                 // suffix still selected
    r.type("t");                                         // typing replaces the suggestion
    suggest(u"nam");
    r.type("j");
    CHECK_EQ(r.text(), std::string("việtnam"));
    CHECK(!r.s.contextFellBack());
}

namespace {
// Chrome/Edge omnibox: after every keystroke the app appends a suggestion and selects it
// (forward selection from the caret); a typed key replaces the selection.
struct Omnibox : Rig {
    std::vector<std::u16string> suggestions;  // one per keystroke, "" = none
    size_t k = 0;
    Omnibox() : Rig(OutputMode::InPlace) {}
    void suggest() {
        if (doc.hi() != doc.lo()) {  // previous suggestion still selected: drop it first
            doc.text.erase(doc.lo(), doc.hi() - doc.lo());
            doc.caret = doc.anchor = doc.lo();
        }
        std::u16string sfx = k < suggestions.size() ? suggestions[k] : u"";
        ++k;
        doc.text.insert(doc.caret, sfx);
        doc.anchor = doc.caret + sfx.size();  // selection [caret, caret+len)
    }
    void typeAc(const char* keys) {
        for (const char* p = keys; *p; ++p) {
            key(*p);
            suggest();
        }
    }
    std::string typedText() const {  // what the user typed (without the live suggestion)
        return utf16ToUtf8(doc.text.substr(0, doc.lo()));
    }
};
}  // namespace

TEST(omnibox_inline_autocomplete_thuwr_vieecj) {
    // real-Windows repro (1.0.8): "thuwr vieecj" gave "thử vieecj" — the second word
    // stayed raw because a forward selection counted as an external edit.
    Omnibox o;
    o.suggestions = {u"iết", u"", u"", u"", u"", u" việc có phải", u"iệc có phải", u"ệc có phải", u"c có phải",
                     u"c có phải", u"c có phải", u" có phải"};
    o.typeAc("thuwr vieecj");
    CHECK_EQ(o.typedText(), std::string("thử việc"));
    CHECK(!o.s.contextFellBack());
}

TEST(omnibox_inline_autocomplete_vieejt_nam) {
    Omnibox o;
    o.suggestions = {u"ietnamnet.vn", u"etnamnet.vn", u"tnamnet.vn", u"", u"", u"", u" nam", u"am", u"m", u""};
    o.typeAc("vieejt nam");
    CHECK_EQ(o.typedText(), std::string("việt nam"));
    CHECK(!o.s.contextFellBack());
}

namespace {
// Win10 conhost (cmd.exe / PowerShell) TSF semantics, as in microsoft/terminal's
// ConsoleTSF: the document is only the composition; letters the TIP lets through go
// straight to the shell as WM_CHAR, text inserted outside a composition is sent as
// typed and can never be deleted, and nothing already sent can be read back.
struct ConsoleDoc : TextSink {
    std::u16string shell;     // what cmd.exe received
    std::u16string compText;  // live composition
    bool comp = false;
    std::u16string textBeforeCaret(int) override { return {}; }
    char16_t charAfterCaret() override { return 0; }
    bool hasSelection() override { return false; }
    bool replaceBeforeCaret(const std::u16string& expect, const std::u16string& ins) override {
        if (!expect.empty()) return false;  // nothing to delete in the document
        shell += ins;                       // insert-only
        return true;
    }
    bool compositionActive() override { return comp; }
    bool setComposition(const std::u16string& t, int absorb, bool) override {
        if (absorb) return false;
        comp = true;
        compText = t;
        return true;
    }
    void endComposition(const std::u16string& t) override {
        if (comp) shell += t;
        comp = false;
        compText.clear();
    }
    void endCompositionAsIs() override { endComposition(compText); }
};

std::string typeConsole(TypingSession& s, ConsoleDoc& d, const char* keys) {
    for (const char* p = keys; *p; ++p) {
        KeyInput k;
        k.kind = KeyKind::Char;
        k.ch = static_cast<unsigned char>(*p);
        const bool eaten = s.wantsKey(k) && s.handleKey(k, d);
        if (!eaten) d.shell += static_cast<char16_t>(*p);  // WM_CHAR to the shell
    }
    return utf16ToUtf8(d.shell);
}

void configureDefaults(TypingSession& s, const Settings& st) {
    SessionOptions o;
    o.engineFlags = st.engineFlags();
    o.autoRestore = st.autoRestore;
    o.reEditWord = st.reEditWord;
    o.shortcuts = &st.shortcuts;
    s.configure(o);
}
}  // namespace

TEST(console_cmd_types_vietnamese_via_composition) {
    // 1.1.0 repro on Win10 cmd.exe: "thuwr gox tieengs vieetj" -> "thuưr gox tieengs Vieetj".
    Settings st;
    TypingSession s;  // in-place is the app default...
    configureDefaults(s, st);
    s.setCompositionOnlyContext(true);  // ...but the TIP saw TF_TMAE_CONSOLE / TF_SS_TRANSITORY
    ConsoleDoc d;
    CHECK_EQ(typeConsole(s, d, "thuwr gox tieengs vieetj "), std::string("thử gõ tiếng việt "));
    CHECK(s.wordMode() == OutputMode::Composition);
}

namespace {
// IMM32 app through CUAS (WinForms: MISA SME 2022, #134). The TSF document holds only the
// composition, like a console — but a key the TIP CLAIMED in OnTestKeyDown has already
// become VK_PROCESSKEY: if OnKeyDown lets it through, the app never gets it. A key the
// TIP does not claim reaches the app normally. The rig retypes a claimed, uneaten key the
// way TextService::OnKeyDown does (keymap.h passedKeyRetype) — only when the session says
// the host drops such keys; otherwise the key is lost, as on the reporter's machine.
// '\n' = Enter.
std::string typeImm(TypingSession& s, ConsoleDoc& d, const char* keys, int* lost = nullptr) {
    for (const char* p = keys; *p; ++p) {
        KeyInput k;
        if (*p == '\n') {
            k.kind = KeyKind::Boundary;
        } else {
            k.kind = KeyKind::Char;
            k.ch = static_cast<unsigned char>(*p);
        }
        const bool claimed = s.wantsKey(k);
        const bool eaten = claimed && s.handleKey(k, d);
        if (eaten) continue;
        if (claimed && !(s.hostDropsPassedKeys() && passedKeyRetype(k) != PassedKeyRetype::None)) {
            if (lost) ++*lost;  // VK_PROCESSKEY: gone
            continue;
        }
        d.shell += static_cast<char16_t>(*p);  // WM_CHAR (native or retyped)
    }
    return utf16ToUtf8(d.shell);
}
}  // namespace

TEST(imm_host_in_place_keeps_first_letter_spaces_and_digits) {
    // #134, MISA SME 2022 (WinForms field), app default in-place: the 1st letter was let
    // through (lost), at the 2nd the field "shows none of the typed text" -> composition;
    // then every Space / digit after a word was claimed, let through and lost:
    // "Lươngnhânviênthống", digits missing. Now: the 1st letter is composed with the rest,
    // the boundary goes out with the word, nothing is lost.
    Settings st;
    TypingSession s;
    configureDefaults(s, st);
    ConsoleDoc d;
    // (The rig counts the 1st letter as lost when it is let through; the session composes
    // it again at the 2nd key, so the text is what proves nothing went missing.)
    CHECK_EQ(typeImm(s, d, "Luwowng nhaan vieen thangs 10 nawm 2026."),
             std::string("Lương nhân viên tháng 10 năm 2026."));
    CHECK(s.contextFellBack());
    CHECK(s.hostDropsPassedKeys());
    CHECK(s.wordMode() == OutputMode::Composition);
    // One-letter-first words too ("dd" -> đ is a single letter on screen).
    TypingSession s2;
    configureDefaults(s2, st);
    ConsoleDoc d2;
    CHECK_EQ(typeImm(s2, d2, "ddi dduwowngf "), std::string("đi đường "));
}

TEST(imm_host_cuas_flagged_composes_and_never_loses_boundaries) {
    // The TIP saw a CUAS-emulated context (session.h setHostDropsPassedKeys): composition
    // from the first key, Space/punctuation inside the result string, Enter retyped.
    Settings st;
    TypingSession s;
    configureDefaults(s, st);
    s.setCompositionOnlyContext(true);
    s.setHostDropsPassedKeys(true);
    ConsoleDoc d;
    int lost = 0;
    CHECK_EQ(typeImm(s, d, "chaof 2026, banj\nok 1 2", &lost), std::string("chào 2026, bạn\nok 1 2"));
    CHECK_EQ(lost, 0);
    // ⌫ right after "word␣" is never claimed for a re-open here (it would be lost).
    typeImm(s, d, "thays ");
    KeyInput bs;
    bs.kind = KeyKind::Backspace;
    CHECK(!s.wantsKey(bs));
    // A new field starts over (the TIP re-flags it if it is CUAS too).
    s.resetContext();
    CHECK(!s.hostDropsPassedKeys());
}

TEST(imm_host_without_the_fix_loses_keys) {
    // The pre-#134 model, kept as a guard on the rig itself: a session that never learns
    // the host drops claimed keys loses a key after every word.
    Settings st;
    TypingSession s;
    configureDefaults(s, st);
    s.setCompositionOnlyContext(true);  // composition, but no hostDropsPassedKeys
    ConsoleDoc d;
    int lost = 0;
    CHECK_EQ(typeImm(s, d, "nhaan vieen ", &lost), std::string("nhânviên"));
    CHECK_EQ(lost, 2);
}

TEST(console_never_reads_back_for_reedit_or_reopen) {
    Settings st;
    TypingSession s;
    configureDefaults(s, st);
    s.setCompositionOnlyContext(true);
    ConsoleDoc d;
    typeConsole(s, d, "thays ");
    KeyInput bs;
    bs.kind = KeyKind::Backspace;
    const bool eaten = s.wantsKey(bs) && s.handleKey(bs, d);
    CHECK(!eaten);  // the shell deletes the space itself; no re-open of "tháy"
    CHECK(!s.wordActive());
}

TEST(host_text_policy) {
    ContextInfo c;
    CHECK(classifyContext(c) == HostText::Normal);                 // Word, WPF, Firefox
    c.transitory = true;
    CHECK(classifyContext(c) == HostText::Normal);                 // Chromium: transitory but full (1.1.1 regression)
    c.cuasEmulated = true;
    CHECK(classifyContext(c) == HostText::CompositionOnly);        // IMM32 app via CUAS (Qt, Java, Adobe…)
    c.cuasEmulated = false;
    c.hasParent = true;
    c.parentTransitory = false;
    CHECK(classifyContext(c) == HostText::NormalViaParent);        // classic Edit/RichEdit
    c.parentTransitory = true;
    CHECK(classifyContext(c) == HostText::CompositionOnly);
    ContextInfo con;
    con.console = true;
    con.transitory = true;
    CHECK(classifyContext(con) == HostText::CompositionOnly);      // conhost / Windows Terminal
    ContextInfo ro;
    ro.readOnly = true;
    CHECK(classifyContext(ro) == HostText::Literal);
    ContextInfo dis;
    dis.keyboardDisabled = true;
    CHECK(classifyContext(dis) == HostText::Literal);              // games / canvases
    ContextInfo ansi;
    ansi.unicodeWindow = false;
    CHECK(classifyContext(ansi) == HostText::Literal);             // VBA editor, ANSI apps
    ContextInfo none;
    none.hasContext = false;
    CHECK(classifyContext(none) == HostText::Ignore);
    std::map<std::string, AppMode> no;
    // consoles/terminals: Direct (hook types, no underline; composition if the app is off)
    for (const char* exe : {"conhost.exe", "openconsole.exe", "windowsterminal.exe", "mintty.exe", "alacritty.exe",
                            "wezterm-gui.exe", "conemu64.exe", "putty.exe", "kitty.exe", "tabby.exe"}) {
        CHECK(resolveAppMode(exe, no) == AppMode::Direct);
        CHECK(hookTypes(resolveAppMode(exe, no)));
    }
    for (const char* exe : {"vmware.exe", "vmware-vmx.exe", "vmware-view.exe", "virtualboxvm.exe", "wfica32.exe",
                            "cdviewer.exe", "ultraviewer_desktop.exe", "moonlight.exe"})
        CHECK(resolveAppMode(exe, no) == AppMode::Off);
    // search bars and browsers are ordinary readable stores: in-place, verified, fallback
    for (const char* exe : {"searchhost.exe", "searchapp.exe", "searchui.exe", "explorer.exe", "chrome.exe",
                            "msedge.exe", "systemsettings.exe", "powertoys.powerlauncher.exe", "everything.exe"})
        CHECK(resolveAppMode(exe, no) == AppMode::InPlace);
}

TEST(chromium_shaped_store_stays_in_place) {
    // Chromium reports TF_SS_TRANSITORY yet is fully readable, with a forward-selected
    // omnibox suggestion after each key. Classification keeps it in-place, and typing
    // works through the suggestion without falling back.
    ContextInfo chrome;
    chrome.transitory = true;
    CHECK(classifyContext(chrome) == HostText::Normal);
    Rig r(OutputMode::InPlace);
    for (const char* p = "vieetj"; *p; ++p) {
        r.key(*p);
        if (r.doc.hi() != r.doc.lo()) {  // drop the previous suggestion
            r.doc.text.erase(r.doc.lo(), r.doc.hi() - r.doc.lo());
            r.doc.caret = r.doc.anchor = r.doc.lo();
        }
        r.doc.text += u"nam.vn";
        r.doc.anchor = r.doc.text.size();
    }
    CHECK_EQ(utf16ToUtf8(r.doc.text.substr(0, r.doc.lo())), std::string("việt"));
    CHECK(r.s.wordMode() == OutputMode::InPlace);
    CHECK(!r.s.contextFellBack());
}

namespace {
// Chromium's native address bar as the TIP really sees it (2026-10 field report, Edge:
// "theêz"). OmniboxViewViews selects the inline suggestion REVERSED (cursor at the end of
// the user text, anchor at the end of the suggestion), and TSFTextStore commits an
// in-place SetText as ExtendSelectionAndDelete(n, 0) + InsertText.
// Textfield::ExtendSelectionAndDelete extends the reversed range — [hi - n, lo] — so it
// deletes inside the suggestion and keeps the n characters we meant to replace. The TSF
// call itself succeeds: only the screen afterwards shows what happened.
struct ChromiumOmniboxDoc : FakeDocument {
    bool replaceBeforeCaret(const std::u16string& expect, const std::u16string& ins) override {
        const size_t lo_ = lo(), hi_ = hi(), n = expect.size();
        if (comp || n > lo_ || text.compare(lo_ - n, n, expect) != 0) return false;
        if (hi_ == lo_) return FakeDocument::replaceBeforeCaret(expect, ins);  // no suggestion: fine
        if (hi_ - lo_ >= n) text.erase(lo_, hi_ - lo_ - n);  // deletes [lo, hi - n)
        text.insert(lo_, ins);                               // InsertText at the cursor
        caret = anchor = lo_ + ins.size();
        ++edits;
        return true;
    }
};
}  // namespace

TEST(chromium_omnibox_dropped_deletion_moves_field_to_composition) {
  // async: how the TIP flags a Chromium context since the 2026-10 Messenger report.
  for (bool async : {false, true}) {
    Settings st;
    TypingSession s;
    s.setOutputMode(OutputMode::InPlace);
    SessionOptions o;
    o.engineFlags = st.engineFlags();
    s.configure(o);
    s.setAsyncStore(async);
    ChromiumOmniboxDoc doc;
    auto key = [&](char c) {
        KeyInput k;
        k.kind = KeyKind::Char;
        k.ch = static_cast<unsigned char>(c);
        if (!(s.wantsKey(k) && s.handleKey(k, doc))) doc.appInsert(static_cast<char16_t>(c));
        s.verifyScreen(doc);  // OnEndEdit after the app processed the key
    };
    for (char c : std::string("the")) key(c);
    doc.text += u"verge.com";  // inline autocomplete, selected after the caret
    doc.anchor = doc.text.size();
    key('e');  // engine: replace "e" by "ê" -> the app keeps the "e"
    CHECK_EQ(utf16ToUtf8(doc.text.substr(0, doc.lo())), std::string("theê"));  // the reported damage, once
    CHECK(s.prefersComposition());  // ... and this field now composes
    CHECK(!s.contextFellBack());    // never handed to the hook (Direct races autocomplete)
    CHECK(!s.wordActive());         // the damaged word is dropped, not edited blindly
    // The user clears the bar and types again: composition, suggestion or not.
    doc.setText(u"");
    for (char c : std::string("thees")) {
        key(c);
        if (!doc.comp) {  // the omnibox only suggests outside a composition
            doc.text += u"verge.com";
            doc.anchor = doc.text.size();
        }
    }
    CHECK(s.wordMode() == OutputMode::Composition);
    CHECK_EQ(utf16ToUtf8(doc.text.substr(doc.compStart, doc.compEnd - doc.compStart)), std::string("thế"));
    key(' ');
    CHECK_EQ(utf16ToUtf8(doc.text), std::string("thế "));
    s.resetContext();  // another field: in-place again
    CHECK(!s.prefersComposition());
  }
}

TEST(stale_screen_without_dropped_deletion_keeps_in_place) {
    // A click / app rewrite is not the dropped-deletion signature: forget the word only.
    Rig r(OutputMode::InPlace);
    r.type("vieet");
    r.doc.setText(u"something else");
    r.s.verifyScreen(r.doc);
    CHECK(!r.s.wordActive());
    CHECK(!r.s.prefersComposition());
    r.type(" thees ");
    CHECK_EQ(r.text(), std::string("something else thế "));
    CHECK(r.s.wordMode() == OutputMode::InPlace);
}

TEST(omnibox_field_prefers_composition_through_selected_suggestion) {
    // The TIP's rule for the address bar: composition from the first letter. A suggestion
    // already selected when a word starts is replaced by the composition (= typing over it).
    Rig r(OutputMode::InPlace);
    r.s.setPreferComposition(true);
    r.type("thees ");
    r.doc.text += u"giới thiệu";  // suggestion after "thế "
    r.doc.anchor = r.doc.text.size();
    r.type("gioiws ");
    CHECK_EQ(r.text(), std::string("thế giới "));
    CHECK(!r.s.contextFellBack());
}

TEST(field_prefers_composition_only_for_chromium_address_bars) {
    const int url[] = {1};
    const int urlAndDefault[] = {0, 1};
    const int plain[] = {0};
    const int search[] = {50};
    CHECK(fieldPrefersComposition("msedge.exe", url, 1));
    CHECK(fieldPrefersComposition("chrome.exe", urlAndDefault, 2));
    CHECK(fieldPrefersComposition("brave.exe", url, 1));
    CHECK(fieldPrefersComposition("browser.exe", url, 1));      // Cốc Cốc
    CHECK(!fieldPrefersComposition("msedge.exe", plain, 1));    // web page text fields stay in-place
    CHECK(!fieldPrefersComposition("msedge.exe", search, 1));
    CHECK(!fieldPrefersComposition("msedge.exe", nullptr, 0));  // scopes unknown
    CHECK(!fieldPrefersComposition("vivaldi.exe", url, 1));     // web-UI address bar: fine per report
    CHECK(!fieldPrefersComposition("firefox.exe", url, 1));
    CHECK(!fieldPrefersComposition("notepad.exe", url, 1));
    CHECK(!fieldPrefersComposition("msedgewebview2.exe", url, 1));  // WebView2 has no omnibox
}

// (#173) InPrivate / incognito: every field answers {IS_PRIVATE}; the address bar is the one
// without a page URL ("oong" came out "oôngm" there, typed in-place over the suggestion).
TEST(private_window_address_bar_is_the_field_without_a_page_url) {
    const int priv[] = {61};
    const int privAndDefault[] = {61, 0};
    const int plain[] = {0};
    CHECK(omniboxNeedsPageUrl("msedge.exe", priv, 1));
    CHECK(!omniboxNeedsPageUrl("msedge.exe", plain, 1));          // normal window: scopes say it all
    CHECK(!omniboxNeedsPageUrl("msedge.exe", privAndDefault, 2));
    CHECK(!omniboxNeedsPageUrl("msedge.exe", nullptr, 0));
    CHECK(!omniboxNeedsPageUrl("firefox.exe", priv, 1));
    CHECK(fieldPrefersComposition("msedge.exe", priv, 1, PageUrl::Empty));     // address bar
    CHECK(fieldPrefersComposition("chrome.exe", priv, 1, PageUrl::Empty));
    CHECK(!fieldPrefersComposition("msedge.exe", priv, 1, PageUrl::Present));  // page field: in-place
    CHECK(!fieldPrefersComposition("msedge.exe", priv, 1, PageUrl::Unknown));  // attribute unsupported
    CHECK(!fieldPrefersComposition("msedge.exe", priv, 1));
    CHECK(!fieldPrefersComposition("msedge.exe", plain, 1, PageUrl::Empty));   // normal window UI field
    CHECK(!fieldPrefersComposition("firefox.exe", priv, 1, PageUrl::Empty));
    CHECK(!fieldPrefersComposition("msedgewebview2.exe", priv, 1, PageUrl::Empty));
}

// #173: the address bar first goes to the hook (the browser underlines any composition);
// composition is the fallback whenever the hook cannot take it.
TEST(address_bar_step_hook_first_composition_as_fallback) {
    CHECK(omniboxStepAtWordStart(DirectAsk::Acked, 0) == OmniboxStep::HookTypes);
    CHECK(omniboxStepAtWordStart(DirectAsk::Acked, 10000) == OmniboxStep::HookTypes);
    // No VietTelex.exe, UIPI, the field marked NoDirect (echo mismatch / SendInput refused):
    // composition, as before #173 — at once, never after a wait.
    CHECK(omniboxStepAtWordStart(DirectAsk::Refused, 0) == OmniboxStep::Compose);
    CHECK(omniboxStepAtWordStart(DirectAsk::Refused, 10000) == OmniboxStep::Compose);
    // Asked, no ack yet: the key reaches the field as typed (the hook adopts the word); the
    // TIP never composes a word the hook could type over.
    CHECK(omniboxStepAtWordStart(DirectAsk::Pending, 0) == OmniboxStep::PassAsTyped);
    CHECK(omniboxStepAtWordStart(DirectAsk::Pending, kOmniboxAckWaitMs - 1) == OmniboxStep::PassAsTyped);
    // The app never acked (hung): give up, release the request, compose.
    CHECK(omniboxStepAtWordStart(DirectAsk::Pending, kOmniboxAckWaitMs) == OmniboxStep::GiveUp);
    CHECK(omniboxStepAtWordStart(DirectAsk::Pending, 60000) == OmniboxStep::GiveUp);
}

// 1.3.31 (#173 follow-up): after one lagging web field every async store of the browser
// prefers composition (setAsyncStore) — the address bar must still go to the hook.
TEST(address_bar_offered_to_hook_despite_inherited_composition_preference) {
    TypingSession s;
    s.setOutputMode(OutputMode::InPlace);
    CHECK(s.inPlaceButForPreference());
    s.setPreferComposition(true);  // what setAsyncStore does once a web store lagged
    CHECK(s.prefersComposition());
    CHECK(s.inPlaceButForPreference());
    CHECK(omniboxOfferedToHook(true, s.inPlaceButForPreference(), false));
    // Refused / GiveUp settled composition for this focus: not asked again at every word.
    CHECK(!omniboxOfferedToHook(true, s.inPlaceButForPreference(), true));
    CHECK(!omniboxOfferedToHook(false, s.inPlaceButForPreference(), false));  // not an address bar
    // No readable store: composition is not a preference there.
    s.setCompositionOnlyContext(true);
    CHECK(!s.inPlaceButForPreference());
    CHECK(!omniboxOfferedToHook(true, s.inPlaceButForPreference(), false));
}

// 1.3.31 (#173 follow-up): a host that offers keys to OnKeyDown only left the record empty
// (first letter not adopted: "onw" -> "onư"). OnKeyDown feeds it unless OnTestKeyDown did.
TEST(typed_key_note_feeds_once_per_key) {
    TypedKeyNote n;
    CHECK(!n.takeAtKeyDown('O'));  // no OnTestKeyDown: OnKeyDown feeds the record
    CHECK(!n.takeAtKeyDown('N'));
    n.fedAtTest('O');
    CHECK(n.takeAtKeyDown('O'));   // fed in OnTestKeyDown: not twice
    CHECK(!n.takeAtKeyDown('O'));  // the same key again, no test before it: a new press
    n.fedAtTest('O');              // declined in OnTestKeyDown (no OnKeyDown), then another key
    CHECK(!n.takeAtKeyDown('N'));
    n.fedAtTest('W');
    n.reset();                     // focus change
    CHECK(!n.takeAtKeyDown('W'));
    TypedWord w;
    KeyInput o;
    o.kind = KeyKind::Char;
    o.ch = U'o';
    w.note(o);
    CHECK_EQ(w.length(), 1);
    w.invalidate();
    CHECK_EQ(w.length(), -1);
}

TEST(direct_mode_request_bits_decode) {
    DirectModeRequest r = decodeDirectMode(kDirectOn | kDirectAdoptTyped | kDirectInlineAutocomplete);
    CHECK(r.on && r.adoptTyped && r.inlineAutocomplete);
    r = decodeDirectMode(kDirectOn);
    CHECK(r.on && !r.adoptTyped && !r.inlineAutocomplete);
    r = decodeDirectMode(kDirectOn | kDirectAdoptTyped);  // WPF list (1.3.16): unchanged
    CHECK(r.on && r.adoptTyped && !r.inlineAutocomplete);
    // A release carries no flags; stray flag bits without kDirectOn mean nothing.
    r = decodeDirectMode(0);
    CHECK(!r.on && !r.adoptTyped && !r.inlineAutocomplete);
    r = decodeDirectMode(kDirectAdoptTyped | kDirectInlineAutocomplete);
    CHECK(!r.on && !r.adoptTyped && !r.inlineAutocomplete);
}

TEST(shell_search_composes_from_the_first_letter_only_on_an_async_store) {
    for (const char* app : {"searchhost.exe", "searchapp.exe", "searchui.exe", "startmenuexperiencehost.exe"}) {
        CHECK(shellSearchPrefersComposition(app, true));
        CHECK(!shellSearchPrefersComposition(app, false));  // a XAML / Win32 box: in-place as before
    }
    for (const char* app : {"msedge.exe", "chrome.exe", "msedgewebview2.exe", "explorer.exe", "notepad.exe",
                            "powertoys.powerlauncher.exe", "ms-teams.exe"})
        CHECK(!shellSearchPrefersComposition(app, true));
}

TEST(search_box_rewriting_its_text_each_key_stays_in_sync) {
    // Explorer / Settings / Start search boxes re-set their own text on every keystroke
    // (same text, caret at the end). That is not a change of OUR word: keep composing.
    Rig r(OutputMode::InPlace);
    for (const char* p = "tieengs vieetj"; *p; ++p) {
        r.key(*p);
        std::u16string t = r.doc.text;  // app re-sets identical text, caret to end
        r.doc.setText(t);
    }
    CHECK_EQ(r.text(), std::string("tiếng việt"));
    CHECK(!r.s.contextFellBack());
}

TEST(webview2_resolves_to_owning_app) {
    CHECK_EQ(appIdentity("msedgewebview2.exe", "ms-teams.exe"), std::string("ms-teams.exe"));
    CHECK_EQ(appIdentity("msedgewebview2.exe", "olk.exe"), std::string("olk.exe"));
    CHECK_EQ(appIdentity("msedgewebview2.exe", ""), std::string("msedgewebview2.exe"));
    CHECK_EQ(appIdentity("chrome.exe", "chrome.exe"), std::string("chrome.exe"));
    CHECK_EQ(appIdentity("notepad.exe", "explorer.exe"), std::string("notepad.exe"));  // only WebView2 hosts
}

namespace {
// What SendInput does to a console / IMM app: backspaces delete, Unicode inserts, and
// NOTHING can be read back (blind sink, like the hook's).
struct BlindKeyboardDoc : TextSink {
    std::u16string screen;
    int batches = 0;
    bool blind() override { return true; }
    std::u16string textBeforeCaret(int) override { return {}; }
    char16_t charAfterCaret() override { return 0; }
    bool hasSelection() override { return false; }
    bool replaceBeforeCaret(const std::u16string& expect, const std::u16string& ins) override {
        ++batches;  // one SendInput batch: backspaces first, then the text
        for (size_t i = 0; i < expect.size() && !screen.empty(); ++i) screen.pop_back();
        screen += ins;
        return true;
    }
    bool compositionActive() override { return false; }
    bool setComposition(const std::u16string&, int, bool) override { return false; }
    void endComposition(const std::u16string&) override {}
    void endCompositionAsIs() override {}
};

std::string typeBlind(TypingSession& s, BlindKeyboardDoc& d, const char* keys) {
    for (const char* p = keys; *p; ++p) {
        KeyInput k;
        if (*p == '\b') k.kind = KeyKind::Backspace;
        else {
            k.kind = KeyKind::Char;
            k.ch = static_cast<unsigned char>(*p);
        }
        const bool eaten = s.wantsKey(k) && s.handleKey(k, d);
        if (!eaten) {  // the real key reaches the app
            if (k.kind == KeyKind::Backspace) {
                if (!d.screen.empty()) d.screen.pop_back();
            } else {
                d.screen += static_cast<char16_t>(*p);
            }
        }
    }
    return utf16ToUtf8(d.screen);
}
}  // namespace

TEST(direct_mode_console_types_without_underline) {
    // Direct mode (hook, SendInput): no composition at all, no read-back.
    Settings st;
    TypingSession s;
    configureDefaults(s, st);  // in-place
    BlindKeyboardDoc d;
    CHECK_EQ(typeBlind(s, d, "thuwr gox tieengs vieetj "), std::string("thử gõ tiếng việt "));
    CHECK(!s.contextFellBack());      // blind sinks never trip the verification fallback
    CHECK(s.wordMode() == OutputMode::InPlace);
}

TEST(direct_mode_backspace_mid_word) {
    Settings st;
    TypingSession s;
    configureDefaults(s, st);
    BlindKeyboardDoc d;
    // "tieengs" -> "tiếng"; ⌫ deletes the displayed 'g'; "s" is no longer... retype "g"
    CHECK_EQ(typeBlind(s, d, "tieengs\b"), std::string("tiến"));
    CHECK_EQ(typeBlind(s, d, "g "), std::string("tiếng "));
    BlindKeyboardDoc d2;
    TypingSession s2;
    configureDefaults(s2, st);
    CHECK_EQ(typeBlind(s2, d2, "khoo\ba "), std::string("kha "));
}

TEST(own_injected_events_are_ignored) {
    CHECK(isOwnInjected(kInjectedMagic));
    CHECK(!isOwnInjected(0));
    CHECK(!isOwnInjected(1));  // OpenKey/UniKey's marker is someone else's input
}

// ---- "Gạch đỏ âm tiết sai chính tả khi gõ" (opt-in red squiggle on the composition) ----

TEST(underline_off_by_default_asks_for_no_attribute) {
    Rig r(OutputMode::Composition);
    CHECK(!r.settings.underlineMisspelled);
    r.type("ddc");                       // "đc": flagged when the option is on
    CHECK(r.doc.comp);
    CHECK(!r.doc.misspelled);
    CHECK_EQ(r.doc.misspelledSets, 0);
    r.type(" ");
    CHECK_EQ(r.text(), std::string("đc "));
}

TEST(underline_follows_the_composed_word) {
    Rig r(OutputMode::Composition);
    r.settings.underlineMisspelled = true;
    r.apply();
    r.type("dd");
    CHECK(r.doc.comp && !r.doc.misspelled);   // "đ": still being typed
    r.type("c");
    CHECK(r.doc.misspelled);                  // "đc": no letter can fix it
    r.key('\b');
    CHECK(r.doc.comp && !r.doc.misspelled);   // back to "đ"
    r.type("c");
    CHECK(r.doc.misspelled);
    r.type(" ");                              // committed text carries no attribute
    CHECK(!r.doc.comp && !r.doc.misspelled);
    CHECK_EQ(r.text(), std::string("đc "));
}

TEST(underline_never_marks_valid_english_or_restored_words) {
    Rig r(OutputMode::Composition);
    r.settings.underlineMisspelled = true;
    r.apply();
    r.type("dduwowcj nghieengf khuya quoocs gif gieengs hello hopsng kaf ");
    CHECK_EQ(r.doc.misspelledSets, 0);
    CHECK_EQ(r.text(), std::string("được nghiềng khuya quốc gì giếng hello hopsng kaf "));
}

TEST(underline_judges_kept_words_when_auto_restore_is_off) {
    Rig r(OutputMode::Composition);
    r.settings.underlineMisspelled = true;
    r.settings.autoRestore = false;
    r.apply();
    r.type("kaf");                            // "kà" stays at the boundary now
    CHECK(r.doc.misspelled);
}

TEST(underline_in_place_does_nothing) {
    Rig r(OutputMode::InPlace);
    r.settings.underlineMisspelled = true;
    r.apply();
    r.type("ddc ");
    CHECK_EQ(r.text(), std::string("đc "));
    CHECK_EQ(r.doc.misspelledSets, 0);
}

TEST(underline_reopened_word_keeps_its_mark) {
    Rig r(OutputMode::Composition);
    r.settings.underlineMisspelled = true;
    r.apply();
    r.type("ddc \b");                       // ⌫ right after the space re-opens "đc"
    CHECK(r.doc.comp);
    CHECK_EQ(r.text(), std::string("đc"));
    CHECK(r.doc.misspelled);
}

// Gợi ý từ (word prediction): what the TIP reads from the session when it arms a
// prediction, and accepting a completion over the word being typed in place
// (caret_hints.h predictSuggestion / hintStillValid; the TIP's applyHint does exactly
// replaceBeforeCaret(replace, insert) + session reset).
TEST(session_prediction_replaces_word_in_progress) {
    Rig r(OutputMode::InPlace);
    r.type("tooi dduw");
    CHECK(r.s.wordActive());
    CHECK(r.s.wordMode() == OutputMode::InPlace);
    CHECK_EQ(utf16ToUtf8(r.s.shown()), std::string("đư"));
    CHECK_EQ(utf16ToUtf8(r.s.rawKeys()), std::string("dduw"));
    CHECK_EQ(r.text(), std::string("tôi đư"));
    const std::u32string before = hints::toU32(r.doc.textBeforeCaret(64));
    auto sug = hints::predictSuggestion(before, hints::toU32(r.s.shown()), u"được");
    CHECK(sug.has_value());
    if (!sug) return;
    CHECK(hints::hintStillValid(*sug, before));
    // Tab / click: the one suggestion
    CHECK(r.doc.replaceBeforeCaret(sug->replace, sug->insert));
    r.s.reset();
    CHECK_EQ(r.text(), std::string("tôi được "));
    r.type("ddi ");  // typing goes on normally after the accepted word
    CHECK_EQ(r.text(), std::string("tôi được đi "));
    // next-word suggestion right after the space: insert only
    auto next = hints::predictSuggestion(hints::toU32(r.doc.textBeforeCaret(64)), U"", u"đâu");
    CHECK(next && next->replace.empty() && next->insert == u"đâu ");
    CHECK(r.doc.replaceBeforeCaret(next->replace, next->insert));
    CHECK_EQ(r.text(), std::string("tôi được đi đâu "));
}

TEST(session_prediction_never_replaces_a_composition) {
    Rig r(OutputMode::Composition);
    r.type("dduw");
    CHECK(r.doc.comp);
    CHECK(r.s.wordMode() == OutputMode::Composition);  // the TIP arms no completion here
    // and the document refuses an in-place replace while composing (applyHint bails too)
    CHECK(!r.doc.replaceBeforeCaret(u"đư", u"được "));
}

TEST(session_prediction_english_context) {
    Rig r(OutputMode::InPlace);
    r.type("this is the ");
    CHECK(r.s.previousWordEnglish());
    Rig v(OutputMode::InPlace);
    v.type("xin ");
    CHECK(!v.s.previousWordEnglish());
}

// ---------------------------------------------------------------- Tự sửa từ phía trước
// (retroactiveEnglish, core/retro_english.h). Desktop: auto-apply at the boundary when the
// text before the caret verifies, ⌫ next reverts; switch off = nothing.
// "very" is a STRONG English word (engine, 05/11/2026): "His car is very" already completes
// the run, so the cases below end there.

namespace {
struct RetroRig : Rig {
    RetroRig(OutputMode m, bool on, bool contextual = true) : Rig(m) {
        settings.retroactiveEnglish = on;
        settings.contextualEnglish = contextual;
        apply();
    }
};
}  // namespace

TEST(retro_settings_gate) {
    Settings s;
    CHECK(!s.retroactiveEnglish);  // experimental: default OFF (= offer as a caret hint)
    CHECK(s.contextualEnglish);
    CHECK(s.engineFlags() & VTX_RETRO_ENGLISH);  // the engine flag follows contextualEnglish
    s.retroactiveEnglish = true;
    CHECK(s.engineFlags() & VTX_RETRO_ENGLISH);
    s.contextualEnglish = false;  // depends on Quyết định theo ngữ cảnh
    CHECK(!(s.engineFlags() & VTX_RETRO_ENGLISH));
    s.retroactiveEnglish = false;
    CHECK(!(s.engineFlags() & VTX_RETRO_ENGLISH));
    CHECK(retro::modeFor(true, true) == retro::Mode::Auto);
    CHECK(retro::modeFor(true, false) == retro::Mode::Offer);
    CHECK(retro::modeFor(false, true) == retro::Mode::Off);
    CHECK(retro::modeFor(false, false) == retro::Mode::Off);
    CHECK(retro::flagWanted(true, false));
    CHECK(!retro::flagWanted(false, true));
}

TEST(retro_auto_applies_both_modes) {
    for (OutputMode m : {OutputMode::Composition, OutputMode::InPlace}) {
        RetroRig r(m, true);
        r.type("His car is very ");
        CHECK_EQ(r.text(), std::string("His car is very "));
        CHECK(r.s.retroUndoArmed());
        CHECK(r.s.retroOffer().empty());  // auto: applied, nothing offered
        RetroRig off(m, false);
        off.type("His car is very ");
        CHECK_EQ(off.text(), std::string("Hí cả í very "));
        CHECK(!off.s.retroUndoArmed());
        RetroRig noCtx(m, true, false);  // contextualEnglish off: the switch is inert
        RetroRig noCtxOff(m, false, false);
        noCtx.type("His car is very ");
        noCtxOff.type("His car is very ");
        CHECK_EQ(noCtx.text(), noCtxOff.text());
    }
}

TEST(retro_punctuation_boundary) {
    RetroRig r(OutputMode::InPlace, true);
    r.type("His car is very.");
    CHECK_EQ(r.text(), std::string("His car is very."));
    // Enter / Tab only end the phrase: no rewrite behind the user's back, no undo.
    for (OutputMode m : {OutputMode::Composition, OutputMode::InPlace}) {
        RetroRig e(m, true);
        e.type("His car is very\n");
        CHECK_EQ(e.text(), std::string("Hí cả í very\n"));
        CHECK(!e.s.retroUndoArmed());
    }
}

TEST(retro_backspace_reverts) {
    for (OutputMode m : {OutputMode::Composition, OutputMode::InPlace}) {
        RetroRig r(m, true);
        r.type("His car is very \b");
        CHECK_EQ(r.text(), std::string("Hí cả í very "));  // exact previous text, boundary kept
        CHECK(!r.s.retroUndoArmed());
        r.key('\b');  // a second ⌫ is an ordinary one
        CHECK_EQ(r.text(), std::string("Hí cả í very"));
        // Reverted: the phrase is not rewritten again by the next words.
        RetroRig q(m, true);
        q.type("His car is very \bfast ");
        CHECK_EQ(q.text(), std::string("Hí cả í very fast "));
    }
}

TEST(retro_undo_only_for_the_next_key) {
    RetroRig r(OutputMode::InPlace, true);
    r.type("His car is very fast x\b");
    CHECK_EQ(r.text(), std::string("His car is very fast "));
    r.key('\b');  // not armed any more: plain ⌫
    CHECK_EQ(r.text(), std::string("His car is very fast"));
}

TEST(retro_undo_skipped_when_text_changed) {
    RetroRig r(OutputMode::InPlace, true);
    r.type("His car is very fast ");
    r.doc.setText(r.doc.text + u"!");  // something the session did not see
    r.key('\b');
    CHECK_EQ(r.text(), std::string("His car is very fast "));  // ordinary ⌫ deleted "!"
}

TEST(retro_skipped_when_text_does_not_verify) {
    for (OutputMode m : {OutputMode::Composition, OutputMode::InPlace}) {
        RetroRig r(m, true);
        r.type("His car is ");
        // The app changed text the engine counts on ("cả" -> "ca"): never rewrite blindly.
        std::u16string t = r.doc.text;
        const size_t at = t.find(u"cả");
        CHECK(at != std::u16string::npos);
        if (at == std::u16string::npos) continue;
        t.replace(at, 2, u"ca");
        r.doc.setText(t);
        r.type("very ");
        CHECK_EQ(r.text(), std::string("Hí ca í very "));
        CHECK(!r.s.retroUndoArmed());
    }
}

TEST(retro_skipped_in_unreadable_or_composition_only_fields) {
    RetroRig r(OutputMode::Composition, true);
    r.s.setCompositionOnlyContext(true);  // console / transitory document
    r.type("His car is very fast ");
    CHECK_EQ(r.text(), std::string("Hí cả í very fast "));
    RetroRig u(OutputMode::Composition, true);
    u.doc.unreadable = true;
    u.type("His car is very fast ");
    CHECK_EQ(u.text(), std::string("Hí cả í very fast "));
}

TEST(retro_decide_apply) {
    const std::u16string before = u"Hí cả í very fast", expected = u"í cả í very fast";
    const int n = static_cast<int>(expected.size());
    retro::Field f;
    CHECK(retro::decideApply(f, before, expected, n) == retro::Apply::Apply);
    CHECK(retro::decideApply(f, u"Hí ca í very fast", expected, n) == retro::Apply::Mismatch);
    CHECK(retro::decideApply(f, u"í very fast", expected, n) == retro::Apply::Mismatch);
    CHECK(retro::decideApply(f, before, expected, n - 1) == retro::Apply::Mismatch);
    CHECK(retro::decideApply(f, u"", u"", 0) == retro::Apply::Mismatch);
    retro::Field g = f;
    g.blind = true;
    CHECK(retro::decideApply(g, before, expected, n) == retro::Apply::Unverifiable);
    g = f;
    g.compositionOnly = true;
    CHECK(retro::decideApply(g, before, expected, n) == retro::Apply::Unverifiable);
    g = f;
    g.canRead = false;
    CHECK(retro::decideApply(g, before, expected, n) == retro::Apply::Unverifiable);
    g = f;
    g.hasSelection = true;
    CHECK(retro::decideApply(g, before, expected, n) == retro::Apply::Unverifiable);
    g = f;
    g.compositionActive = true;
    CHECK(retro::decideApply(g, before, expected, n) == retro::Apply::Unverifiable);
}

TEST(retro_undo_decision) {
    const retro::Undo u = retro::makeUndo(u"í cả í very fast", u"is car is very fast", u' ');
    CHECK(u.armed());
    CHECK(u.applied == u"is car is very fast ");
    CHECK(u.original == u"í cả í very fast ");
    retro::Field f;
    CHECK(retro::undoApplies(u, f, u"His car is very fast "));
    CHECK(!retro::undoApplies(u, f, u"His car is very fast !"));
    CHECK(!retro::undoApplies(u, f, u"His car is very fast"));
    retro::Field sel = f;
    sel.hasSelection = true;
    CHECK(!retro::undoApplies(u, sel, u"His car is very fast "));
    retro::Field blind = f;
    blind.blind = true;
    CHECK(!retro::undoApplies(u, blind, u"His car is very fast "));
    CHECK(!retro::makeUndo(u"í", u"is", 0).armed());  // Enter / Tab ended the word: no undo
    retro::Undo none;
    CHECK(!retro::undoApplies(none, f, u"anything"));
}

// ---- offer mode (switch OFF, contextualEnglish ON): the correction becomes a caret hint

TEST(retro_offer_vs_auto_vs_none) {
    for (OutputMode m : {OutputMode::Composition, OutputMode::InPlace}) {
        RetroRig offer(m, false);
        offer.type("His car is very ");
        CHECK_EQ(offer.text(), std::string("Hí cả í very "));  // nothing changed
        const retro::Offer& o = offer.s.retroOffer();
        CHECK(!o.empty());
        CHECK(o.display == u"His car is");
        CHECK(o.replace == u"í cả í very ");   // boundary included: the app typed it
        CHECK(o.insert == u"is car is very ");
        CHECK(!offer.s.retroUndoArmed());
        CHECK_EQ(offer.s.lastRetroWords(), 0);
        RetroRig autoRig(m, true);
        autoRig.type("His car is very ");
        CHECK_EQ(autoRig.text(), std::string("His car is very "));
        CHECK(autoRig.s.retroOffer().empty());
        RetroRig none(m, false, false);  // contextualEnglish off: nothing at all
        none.type("His car is very ");
        CHECK_EQ(none.text(), std::string("Hí cả í very "));
        CHECK(none.s.retroOffer().empty());
        RetroRig noneOn(m, true, false);
        noneOn.type("His car is very ");
        CHECK(noneOn.s.retroOffer().empty());
    }
}

TEST(retro_offer_lasts_one_key_and_never_on_enter) {
    RetroRig r(OutputMode::InPlace, false);
    r.type("His car is very ");
    CHECK(!r.s.retroOffer().empty());
    r.key('x');  // the next key: gone (the hint hides with it)
    CHECK(r.s.retroOffer().empty());
    RetroRig e(OutputMode::InPlace, false);
    e.type("His car is very\n");
    CHECK(e.s.retroOffer().empty());
    // A key the session lets through (second space) also clears it.
    RetroRig s2(OutputMode::InPlace, false);
    s2.type("His car is very ");
    s2.key(' ');
    CHECK(s2.s.retroOffer().empty());
}

TEST(retro_offer_accept_applies_through_verified_replace) {
    for (OutputMode m : {OutputMode::Composition, OutputMode::InPlace}) {
        RetroRig r(m, false);
        r.type("His car is very ");
        const retro::Offer o = r.s.retroOffer();
        const hints::Suggestion sug = hints::retroHint(o.display, o.replace, o.insert);
        // What the TIP does on Tab (replaceForHint): re-read, check, replace.
        const std::u16string before = r.doc.textBeforeCaret(static_cast<int>(sug.replace.size()) + 2);
        CHECK(hints::hintStillValid(sug, hints::toU32(before)));
        CHECK(r.doc.replaceBeforeCaret(sug.replace, sug.insert));
        r.s.reset();  // afterHintApplied
        CHECK_EQ(r.text(), std::string("His car is very "));
        r.type("fast ");
        CHECK_EQ(r.text(), std::string("His car is very fast "));
    }
}

TEST(retro_offer_mismatch_no_hint) {
    for (OutputMode m : {OutputMode::Composition, OutputMode::InPlace}) {
        RetroRig r(m, false);
        r.type("His car is ");
        std::u16string t = r.doc.text;
        const size_t at = t.find(u"cả");
        CHECK(at != std::u16string::npos);
        if (at == std::u16string::npos) continue;
        t.replace(at, 2, u"ca");
        r.doc.setText(t);
        r.type("very ");
        CHECK(r.s.retroOffer().empty());  // the text before the caret disagrees: no hint
    }
    // Unreadable / console fields: never offered either.
    RetroRig u(OutputMode::Composition, false);
    u.doc.unreadable = true;
    u.type("His car is very fast ");
    CHECK(u.s.retroOffer().empty());
    RetroRig c(OutputMode::Composition, false);
    c.s.setCompositionOnlyContext(true);
    c.type("His car is very fast ");
    CHECK(c.s.retroOffer().empty());
    // Shown later only if the screen still ends with what it replaces.
    const hints::Suggestion sug = hints::retroHint(u"His car is", u"í cả í very fast ", u"is car is very fast ");
    CHECK(hints::retroSuggestion(U"Hí cả í very fast ", sug).has_value());
    CHECK(!hints::retroSuggestion(U"Hí cả í very fast x", sug).has_value());
    CHECK(!hints::retroSuggestion(U"Hí ca í very fast ", sug).has_value());
    CHECK(!hints::hintStillValid(sug, U"Hí cả í very fast"));
}

TEST(retro_offer_wins_over_other_hints) {
    hints::Trigger typo;
    typo.kind = hints::TriggerKind::Typo;
    typo.raw = U"fats";
    CHECK(hints::withRetro(typo, true).kind == hints::TriggerKind::Retro);
    CHECK(hints::withRetro(typo, false).kind == hints::TriggerKind::Typo);
    hints::Trigger none;
    CHECK(hints::withRetro(none, true).kind == hints::TriggerKind::Retro);
    CHECK(hints::withRetro(none, false).kind == hints::TriggerKind::None);
    // Tab accepts it, Enter never does, Esc dismisses.
    CHECK(hints::action(hints::Kind::Retro, hints::kVkTab, true) == hints::KeyAction::Accept);
    CHECK(hints::action(hints::Kind::Retro, hints::kVkReturn, true) == hints::KeyAction::DismissPass);
    CHECK(hints::action(hints::Kind::Retro, hints::kVkEscape, true) == hints::KeyAction::DismissConsume);
}

TEST(retro_offer_display) {
    CHECK(retro::offerDisplay(u"Hí cả í very fast", u"í cả í very fast", u"is car is very fast") == u"His car is");
    CHECK(retro::offerDisplay(u"winter í coming", u"í coming", u"is coming") == u"is");
    CHECK(retro::offerDisplay(u"x", u"same", u"same").empty());
    CHECK(retro::makeOffer(u"Hí cả í very fast", u"í cả í very fast", u"is car is very fast", 0, 3).empty());
    CHECK(retro::makeOffer(u"Hí ca í very fast", u"í cả í very fast", u"is car is very fast", u' ', 3).empty());
    const retro::Offer o = retro::makeOffer(u"Hí cả í very fast", u"í cả í very fast", u"is car is very fast", u',', 3);
    CHECK(o.replace == u"í cả í very fast,");
    CHECK(o.insert == u"is car is very fast,");
    CHECK_EQ(o.words, 3);
}

TEST(retro_passed_by_keys_reach_the_engine) {
    // Keys the session lets through (no edit session) still end the phrase: "fast" then
    // Enter-less punctuation / navigation are reported via noteKeyPassedBy.
    RetroRig r(OutputMode::InPlace, true);
    KeyInput space{KeyKind::Char, U' '};
    KeyInput nav{KeyKind::Navigation, 0};
    KeyInput enter{KeyKind::Boundary, 0};
    // Cost: with the flag on, a boundary with no word / nothing armed needs no edit session.
    CHECK(!r.s.wantsKey(space));
    CHECK(!r.s.wantsKey(nav));
    CHECK(!r.s.wantsKey(enter));
    RetroRig n(OutputMode::InPlace, true);
    n.type("His car is ");
    n.s.noteKeyPassedBy(nav);  // e.g. an arrow the TIP let through: the phrase ends
    n.type("very fast ");
    CHECK_EQ(n.text(), std::string("Hí cả í very fast "));
}

TEST(retro_never_in_terminals_or_remote_viewers) {
    CHECK(!retro::allowedForApp("windowsterminal.exe"));
    CHECK(!retro::allowedForApp("conhost.exe"));
    CHECK(!retro::allowedForApp("mintty.exe"));
    CHECK(!retro::allowedForApp("mstsc.exe"));
    CHECK(retro::allowedForApp("notepad.exe"));
    CHECK(retro::allowedForApp("chrome.exe"));
}

TEST(retro_snapshot_bit_roundtrip) {
    Settings s;
    s.retroactiveEnglish = true;
    const std::vector<uint8_t> b = serialize(s);
    Settings t;
    CHECK(deserialize(b.data(), b.size(), t));
    CHECK(t.retroactiveEnglish);
    CHECK(t == s);
}

// ---------------------------------------------------------------- Đoán từ trùng theo tần suất
// (englishByFrequency, experimental): "His" at the start of a phrase commits as English; the
// next word showing the phrase is Vietnamese flips it back — AUTOMATICALLY, in offer mode
// too, and before an Enter goes through.

namespace {
struct FreqRig : RetroRig {
    FreqRig(OutputMode m, bool autoApply, bool frequency = true) : RetroRig(m, autoApply) {
        settings.englishByFrequency = frequency;
        apply();
    }
};
}  // namespace

TEST(frequency_settings_gate) {
    Settings s;
    CHECK(!s.englishByFrequency);  // experimental: default OFF
    CHECK(!(s.engineFlags() & VTX_ENGLISH_BY_FREQUENCY));
    s.englishByFrequency = true;
    CHECK(s.engineFlags() & VTX_ENGLISH_BY_FREQUENCY);  // with the retro flag (contextualEnglish)
    s.contextualEnglish = false;
    CHECK(!(s.engineFlags() & VTX_ENGLISH_BY_FREQUENCY));
    CHECK(!(s.engineFlags() & VTX_RETRO_ENGLISH));
    Settings t;
    t.englishByFrequency = true;
    const std::vector<uint8_t> b = serialize(t);
    Settings u;
    CHECK(deserialize(b.data(), b.size(), u));
    CHECK(u.englishByFrequency);
    CHECK(!u.retroactiveEnglish);
    CHECK(u == t);
}

TEST(frequency_flip_back_applies_in_offer_and_auto_mode) {
    for (OutputMode m : {OutputMode::Composition, OutputMode::InPlace}) {
        for (bool autoApply : {false, true}) {
            FreqRig r(m, autoApply);
            r.type("His ");
            CHECK_EQ(r.text(), std::string("His "));   // frequency rule: English at the start
            r.type("huwngr ");
            CHECK_EQ(r.text(), std::string("Hí hửng "));   // flipped back, no hint needed
            FreqRig l(m, autoApply);
            l.type("his huwngr ");
            CHECK_EQ(l.text(), std::string("hí hửng "));
            CHECK(r.s.retroOffer().empty());
            FreqRig d(m, autoApply);
            d.type("his his ");
            CHECK_EQ(d.text(), std::string("hí hí "));
            // Off: the plain retro behaviour (no frequency rule, nothing to flip).
            FreqRig off(m, autoApply, false);
            off.type("His huwngr ");
            CHECK_EQ(off.text(), std::string("Hí hửng "));
        }
    }
}

TEST(frequency_flip_back_before_enter) {
    for (OutputMode m : {OutputMode::Composition, OutputMode::InPlace}) {
        for (bool autoApply : {false, true}) {
            FreqRig r(m, autoApply);
            r.type("his huwngr\n");
            CHECK_EQ(r.text(), std::string("hí hửng\n"));   // the flip lands before the newline
            CHECK(!r.s.retroUndoArmed());                    // Enter: no ⌫-undo
        }
    }
}

TEST(frequency_flip_back_skipped_when_text_does_not_verify) {
    FreqRig r(OutputMode::InPlace, false);
    r.type("His ");
    r.doc.setText(u"Hiss ");   // something the session did not see
    r.type("huwngr ");
    CHECK_EQ(r.text(), std::string("Hiss hửng "));
}

// ---- Gõ tắt with symbol keys ("=>" -> "⟶", "<>" -> "⟷"; Windows field report 1.3.x) ----
// Before: '=' '<' '>' are not word keys, so "=>" never became a word and the space after
// it was not even claimed: such keys never expanded anywhere on Windows.

TEST(shortcut_symbol_keys_expand_at_whitespace) {
    for (OutputMode m : {OutputMode::Composition, OutputMode::InPlace}) {
        Rig r(m);
        r.settings.shortcuts[u"=>"] = u"⟶";
        r.settings.shortcuts[u"<>"] = u"⟷";
        r.apply();
        r.type("=> a <> b");
        CHECK_EQ(r.text(), std::string("⟶ a ⟷ b"));
        r.type(" <>\n=>");
        CHECK_EQ(r.text(), std::string("⟶ a ⟷ b ⟷\n=>"));  // Enter triggers too
        r.key('\n');
        CHECK_EQ(r.text(), std::string("⟶ a ⟷ b ⟷\n⟶\n"));
    }
}

TEST(shortcut_symbol_keys_only_standalone_and_at_whitespace) {
    for (OutputMode m : {OutputMode::Composition, OutputMode::InPlace}) {
        Rig r(m);
        r.settings.shortcuts[u"=>"] = u"⟶";
        r.settings.shortcuts[u"->"] = u"→";
        r.apply();
        r.type("x=> a->b =>. =>> ");
        CHECK_EQ(r.text(), std::string("x=> a->b =>. =>> "));
        // Text the session never saw before the caret: re-read, still has to stand alone.
        Rig r2(m);
        r2.settings = r.settings;
        r2.apply();
        r2.doc.setText(u"abc");
        r2.type("=> ");
        CHECK_EQ(r2.text(), std::string("abc=> "));
        r2.doc.setText(u"abc ");
        r2.type("=> ");
        CHECK_EQ(r2.text(), std::string("abc ⟶ "));
    }
}

TEST(shortcut_symbol_key_ending_in_a_word) {
    // ":D" / "k2": the run before the caret + the word in progress.
    for (OutputMode m : {OutputMode::Composition, OutputMode::InPlace}) {
        Rig r(m);
        r.settings.shortcuts[u":D"] = u"😀";
        r.settings.shortcuts[u"k2"] = u"khối 2";
        r.settings.shortcuts[u"ko"] = u"không";
        r.apply();
        r.type(":D k2 ko ");
        CHECK_EQ(r.text(), std::string("😀 khối 2 không "));
        CHECK(!r.doc.comp);
    }
}

TEST(shortcut_symbol_key_space_claimed_only_for_a_match) {
    Rig r(OutputMode::InPlace);
    r.settings.shortcuts[u"=>"] = u"⟶";
    r.apply();
    KeyInput sp;
    sp.kind = KeyKind::Char;
    sp.ch = U' ';
    r.type("=");
    CHECK(!r.s.wantsKey(sp));   // "=" is no key: the space is not even claimed
    r.type(">");
    CHECK(r.s.wantsKey(sp));
    r.type("> ");
    CHECK(!r.s.wantsKey(sp));
    CHECK_EQ(r.text(), std::string("=>> "));
}

namespace {
// The hook (Direct mode): nothing can be read back.
struct BlindDoc : test::FakeDocument {
    bool blind() override { return true; }
    std::u16string textBeforeCaret(int) override { return {}; }
};

void feed(TypingSession& s, test::FakeDocument& d, const char* keys) {
    for (const char* p = keys; *p; ++p) {
        KeyInput k;
        if (*p == '\n') {
            k.kind = KeyKind::Boundary;
        } else {
            k.kind = KeyKind::Char;
            k.ch = static_cast<unsigned char>(*p);
        }
        const bool wanted = s.wantsKey(k);
        if (!wanted) s.noteKeyPassedBy(k);
        if (wanted && s.handleKey(k, d)) continue;
        d.appInsert(static_cast<char16_t>(*p));
    }
}
}  // namespace

TEST(shortcut_symbol_keys_blind_needs_a_seen_space) {
    Settings st;
    st.shortcuts[u"=>"] = u"⟶";
    TypingSession s;
    configureDefaults(s, st);
    BlindDoc d;
    d.setText(u"abc");
    feed(s, d, "=> ");               // what stands before "=>" is unknown: left alone
    CHECK_EQ(utf16ToUtf8(d.text), std::string("abc=> "));
    feed(s, d, "=> x=> ");           // after a space it saw: expanded; glued: not
    CHECK_EQ(utf16ToUtf8(d.text), std::string("abc=> ⟶ x=> "));
    s.reset();                        // a click: the run is unknown again
    feed(s, d, "=> ");
    CHECK_EQ(utf16ToUtf8(d.text), std::string("abc=> ⟶ x=> => "));
}

TEST(shortcut_token_key_classification) {
    CHECK(isTokenShortcutKey(u"=>"));
    CHECK(isTokenShortcutKey(u"<>"));
    CHECK(isTokenShortcutKey(u"k2"));
    CHECK(isTokenShortcutKey(u":D"));
    CHECK(!isTokenShortcutKey(u"ko"));
    CHECK(!isTokenShortcutKey(u"đc"));
    CHECK(!isTokenShortcutKey(u""));
    std::map<std::u16string, std::u16string> t{{u"=>", u"⟶"}, {u"ko", u"không"}};
    CHECK(findTokenShortcut(t, u"=>"));
    CHECK(!findTokenShortcut(t, u"ko"));  // letter keys: the word lookup only
    CHECK(!findTokenShortcut(t, u"=>>"));
    std::map<std::u16string, std::u16string> k{{u"k2", u"kệ hai"}};
    std::u16string e;
    CHECK(findTokenShortcut(k, u"K2", &e) && e == u"Kệ hai");  // case carried (macOS tokenExpansion)
}

TEST(shortcut_typed_with_a_capital_expands_with_one) {
    // 2026-11 Windows report (TIP and portable hook share this session): key "ko" ->
    // "không"; typing "Ko" left "Ko". Both output modes, the hook's blind sink included.
    for (OutputMode m : {OutputMode::Composition, OutputMode::InPlace}) {
        Rig r(m);
        r.settings.shortcuts[u"ko"] = u"không";
        r.apply();
        r.type("ko Ko KO kO ");
        CHECK_EQ(r.text(), std::string("không Không KHÔNG kO "));
    }
}

TEST(shortcut_key_with_dd_typed_with_a_capital_expands) {
    // 2026-11 Windows report (1.3.20): key "đc" -> "được"; "đc" expanded, "Đc" stayed "Đc".
    for (OutputMode m : {OutputMode::Composition, OutputMode::InPlace}) {
        Rig r(m);
        r.settings.shortcuts[u"đc"] = u"được";
        r.apply();
        r.type("ddc Ddc DDc DDC ");
        CHECK_EQ(r.text(), std::string("được Được Được ĐƯỢC "));
    }
}

// ---- Not a text field: a WPF list with type-to-filter (Windows field report 1.3.x) ----
namespace {
// The focused element is a file list. Its TSF store (WPF's default one) never holds text;
// keys the TIP does not eat reach the app as text input and filter the list ("Contains:
// mar"). Whatever the TIP composes or writes into the store goes nowhere.
struct ListStore : TextSink {
    std::u16string filter;     // what the app received
    int lostKeys = 0;          // keys the TIP ate (composed into nothing)
    bool comp = false;
    std::u16string textBeforeCaret(int) override { return {}; }
    char16_t charAfterCaret() override { return 0; }
    bool hasSelection() override { return false; }
    bool replaceBeforeCaret(const std::u16string& expect, const std::u16string&) override { return expect.empty(); }
    bool compositionActive() override { return comp; }
    bool compositionText(std::u16string& out) override {  // a composition holds nothing here
        out.clear();
        return comp;
    }
    bool setComposition(const std::u16string&, int, bool) override { return comp = true; }
    void endComposition(const std::u16string&) override { comp = false; }
    void endCompositionAsIs() override { comp = false; }
};

std::string typeList(TypingSession& s, ListStore& d, const char* keys) {
    for (const char* p = keys; *p; ++p) {
        KeyInput k;
        k.kind = KeyKind::Char;
        k.ch = static_cast<unsigned char>(*p);
        const bool wanted = s.wantsKey(k);
        if (!wanted) s.noteKeyPassedBy(k);
        if (wanted && s.handleKey(k, d)) {
            ++d.lostKeys;
            continue;
        }
        d.filter += static_cast<char16_t>(*p);  // TSF-native: an uneaten key reaches the app
    }
    return utf16ToUtf8(d.filter);
}
}  // namespace

TEST(not_a_text_field_keys_pass_through) {
    Settings st;
    TypingSession s;
    configureDefaults(s, st);
    s.setPassedKeysReachApp(true);  // the TIP: TSF-native store (app_policy passedKeysReachApp)
    ListStore d;
    CHECK_EQ(typeList(s, d, "markdown"), std::string("markdown"));
    CHECK_EQ(d.lostKeys, 0);
    CHECK(s.notTextField());
    CHECK(!d.comp);
    // From now on nothing is even claimed — Vietnamese keys included.
    CHECK_EQ(typeList(s, d, " vieetj"), std::string("markdown vieetj"));
    CHECK_EQ(d.lostKeys, 0);
    // A new field (focus change) is evaluated afresh.
    s.resetContext();
    CHECK(!s.notTextField());
}

TEST(not_a_text_field_without_the_fix_loses_keys) {
    // Guard on the rig: the old answer to "the store shows none of the typed text" (compose,
    // #134's IMM32 path) eats every key after the first into a store nobody reads.
    Settings st;
    TypingSession s;
    configureDefaults(s, st);
    ListStore d;
    CHECK_EQ(typeList(s, d, "markdown"), std::string("m"));
    CHECK_EQ(d.lostKeys, 7);
}

TEST(not_a_text_field_needs_two_words_of_evidence) {
    // A real field whose store is one update late once (first word in an empty field): that
    // word goes on as typed, the field is not given up.
    Rig r(OutputMode::InPlace);
    r.s.setPassedKeysReachApp(true);
    r.type("t");
    r.doc.blankReads = 1;
    r.type("ieengs vieetj ");
    CHECK(!r.s.notTextField());
    r.type("dduwowngf ");
    CHECK(!r.s.notTextField());
    const std::string t = r.text();
    CHECK(t.size() >= std::string("việt đường ").size() &&
          t.compare(t.size() - std::string("việt đường ").size(), std::string::npos, "việt đường ") == 0);
}

TEST(passed_keys_reach_app_policy) {
    CHECK(isEditControlClass(u"Edit", u"WindowsForms10.EDIT.app.0.141b42a_r6_ad1"));
    CHECK(isEditControlClass(u"Edit", u"ThunderRT6TextBox"));
    CHECK(isEditControlClass(u"RichEdit20W", u"RichEdit20W"));
    CHECK(isEditControlClass(u"RICHEDIT50W", u"RICHEDIT50W"));
    CHECK(isEditControlClass(u"TMemo", u"TMemo"));
    CHECK(!isEditControlClass(u"HwndWrapper[App;;1]", u"HwndWrapper[App;;1]"));
    ContextInfo c;  // not transitory: Word, WPF (a TextBox, or the default store behind a list)
    CHECK(passedKeysReachApp(c, classifyContext(c)));
    c.transitory = true;  // Chromium & co: async store, never "not a text field"
    CHECK(!passedKeysReachApp(c, classifyContext(c)));
    c.hasParent = true;   // transitory-extension parent...
    c.parentTransitory = false;
    c.editControl = true;  // ...of a classic Edit in an IMM32 app (MISA, #134): keys may be dropped
    CHECK(!passedKeysReachApp(c, classifyContext(c)));
    c.editControl = false;  // ...that is no Edit's mirror (WPF's default text store)
    CHECK(passedKeysReachApp(c, classifyContext(c)));
    ContextInfo cuas;
    cuas.transitory = true;
    cuas.cuasEmulated = true;
    CHECK(!passedKeysReachApp(cuas, classifyContext(cuas)));
    ContextInfo con;
    con.console = true;
    CHECK(!passedKeysReachApp(con, classifyContext(con)));
}

// ---- WPF TextBox: a claimed key let through never arrives (One Commander, 1.3.14) ----
namespace {
// WPF feeds keys to TSF itself: a key the TIP claims in OnTestKeyDown becomes
// Key.ImeProcessed, and when OnKeyDown lets it through WPF marks its KeyDown handled — no
// TextInput, the TextBox never sees it. A key the TIP does not claim types normally. Like
// TextService::OnKeyDown, the rig retypes a claimed, uneaten key (SendInput, arrives as an
// unclaimed key) only when the session says the host drops such keys. '\n' = Enter.
struct WpfBox {
    Settings st;  // outlives the session (it keeps a pointer to the shortcuts)
    TypingSession s;
    FakeDocument doc;
    int lost = 0;
    WpfBox() { configureDefaults(s, st); }  // app default: in-place
    // What TextService::evaluateHost tells the session at a word start.
    void evaluate(bool withFix) {
        ContextInfo c;  // a WPF TextBox: its own TSF store, not transitory
        c.wpf = true;
        c.editControl = false;
        const HostText h = classifyContext(c);
        if (!withFix) {  // 1.3.14: WPF was any TSF-native store
            s.setPassedKeysReachApp(true);
            return;
        }
        s.setPassedKeysReachApp(passedKeysReachApp(c, h));
        if (wpfOwnsClaimedKeys(c, h) && !s.notTextField()) {
            s.setHostDropsPassedKeys(true);
            s.setCompositionMustShow(true);
            s.setPreferComposition(true);
        }
    }
    void type(const char* keys, bool withFix = true) {
        for (const char* p = keys; *p; ++p) {
            KeyInput k;
            if (*p == '\n') {
                k.kind = KeyKind::Boundary;
            } else {
                k.kind = KeyKind::Char;
                k.ch = static_cast<unsigned char>(*p);
            }
            if (!s.wordActive()) evaluate(withFix);
            const bool claimed = s.wantsKey(k);
            if (!claimed) s.noteKeyPassedBy(k);
            if (claimed && s.handleKey(k, doc)) continue;
            if (claimed && !(s.hostDropsPassedKeys() && passedKeyRetype(k) != PassedKeyRetype::None)) {
                ++lost;  // ImeProcessed, KeyDown handled: gone
                continue;
            }
            CHECK(!doc.comp);
            doc.appInsert(*p == '\n' ? u'\n' : static_cast<char16_t>(*p));
        }
    }
    std::string text() const { return utf16ToUtf8(doc.text); }
};
}  // namespace

TEST(wpf_textbox_without_the_fix_loses_keys) {
    // Guard on the rig: 1.3.14 typed WPF in place, letting the first letter of every word
    // through — gone. The report: an e-mail address showed almost nothing.
    WpfBox b;
    b.type("phuc@example.com", false);
    // Empty field: "phuc" is gone; the 2nd empty-store word latches notTextField (1.3.12),
    // the rest passes raw.
    CHECK_EQ(b.lost, 4);
    CHECK_EQ(b.text(), std::string("@example.com"));
    // Text already before the caret: the store never ends with the word, so every word
    // restarts at every key and each key is let through — all of them gone.
    WpfBox c;
    c.doc.setText(u"Ghi chu: ");
    c.type("xin chao", false);
    CHECK_EQ(c.lost, 8);  // the space too: it ends a word, so it is claimed
    CHECK_EQ(c.text(), std::string("Ghi chu: "));  // nothing typed at all
}

TEST(wpf_textbox_composes_and_loses_nothing) {
    WpfBox b;
    b.type("phuc@example.com");
    CHECK_EQ(b.text(), std::string("phuc@example.com"));
    CHECK_EQ(b.lost, 0);
    CHECK(!b.s.notTextField());
    CHECK(b.s.wordMode() == OutputMode::Composition);
    b.type(" tieengs vieetj, ddi\nok 1 2");
    CHECK_EQ(b.text(), std::string("phuc@example.com tiếng việt, đi\nok 1 2"));
    CHECK_EQ(b.lost, 0);
}

TEST(wpf_rename_box_replaces_the_selected_name) {
    // Inline folder rename: the whole old name is selected; typing replaces it.
    WpfBox b;
    b.doc.setText(u"New folder");
    b.doc.anchor = 0;
    b.type("Taif lieeuj");
    CHECK_EQ(b.text(), std::string("Tài liệu"));
    CHECK_EQ(b.lost, 0);
}

TEST(wpf_store_holding_no_composition_is_not_a_text_field) {
    // Safety net: should a WPF element without text (a list's empty default store) be
    // classified as a TextBox, the first composition reads back empty -> keys pass from
    // that very key on, nothing lost (what the list got in 1.3.12).
    Settings st;
    TypingSession s;
    configureDefaults(s, st);
    s.setHostDropsPassedKeys(true);
    s.setCompositionMustShow(true);
    s.setPreferComposition(true);
    ListStore d;
    CHECK_EQ(typeList(s, d, "markdown"), std::string("markdown"));
    CHECK_EQ(d.lostKeys, 0);
    CHECK(s.notTextField());
    CHECK(!s.hostDropsPassedKeys());
    CHECK(!d.comp);
    s.resetContext();
    CHECK(!s.notTextField());
}

TEST(wpf_policy) {
    CHECK(isWpfWindowClass(u"HwndWrapper[OneCommander.exe;;3f2a9c1e-0b7d-4d4e-9a51-1f0e2c7b9a10]"));
    CHECK(isWpfWindowClass(u"HwndWrapper[App;;1]"));
    CHECK(!isWpfWindowClass(u"HwndWrapper["));
    CHECK(!isWpfWindowClass(u"Edit"));
    CHECK(!isWpfWindowClass(u"WindowsForms10.EDIT.app.0.141b42a_r6_ad1"));
    CHECK(!isWpfWindowClass(u"Chrome_RenderWidgetHostHWND"));
    ContextInfo box;  // WPF TextBox: own store, not transitory
    box.wpf = true;
    box.editControl = false;
    CHECK(wpfOwnsClaimedKeys(box, classifyContext(box)));
    CHECK(!passedKeysReachApp(box, classifyContext(box)));
    ContextInfo list = box;  // WPF list: transitory-extension parent, no Edit (1.3.12 rule kept)
    list.transitory = true;
    list.hasParent = true;
    list.parentTransitory = false;
    CHECK(!wpfOwnsClaimedKeys(list, classifyContext(list)));
    CHECK(passedKeysReachApp(list, classifyContext(list)));
    ContextInfo word;  // Word / Firefox: unchanged
    CHECK(!wpfOwnsClaimedKeys(word, classifyContext(word)));
    CHECK(passedKeysReachApp(word, classifyContext(word)));
    ContextInfo ro = box;  // read-only WPF box: literal, nothing claimed anyway
    ro.readOnly = true;
    CHECK(!wpfOwnsClaimedKeys(ro, classifyContext(ro)));
}

// ---- WPF list (default store): not a text field from the first word (1.3.16) ----------
namespace {
ContextInfo wpfListContext() {  // One Commander's file list: host 1 (NormalViaParent), wpf, no Edit
    ContextInfo c;
    c.wpf = true;
    c.editControl = false;
    c.transitory = true;
    c.hasParent = true;
    c.parentTransitory = false;
    return c;
}
}  // namespace

TEST(wpf_default_store_policy) {
    const ContextInfo list = wpfListContext();
    CHECK(classifyContext(list) == HostText::NormalViaParent);
    CHECK(wpfDefaultStore(list, classifyContext(list)));
    ContextInfo box;  // WPF TextBox: its own store -> composition (wpfOwnsClaimedKeys), not this
    box.wpf = true;
    box.editControl = false;
    CHECK(!wpfDefaultStore(box, classifyContext(box)));
    ContextInfo edit = list;  // classic Edit's parent mirror (MISA, #134): not WPF
    edit.wpf = false;
    edit.editControl = true;
    CHECK(!wpfDefaultStore(edit, classifyContext(edit)));
    ContextInfo other = list;  // a non-WPF TSF-native parent: keeps the two-word evidence
    other.wpf = false;
    CHECK(!wpfDefaultStore(other, classifyContext(other)));
    ContextInfo ro = list;  // read-only: literal, nothing to decide
    ro.readOnly = true;
    CHECK(!wpfDefaultStore(ro, classifyContext(ro)));
    ContextInfo parentTrans = list;  // transitory parent: composition only
    parentTrans.parentTransitory = true;
    CHECK(!wpfDefaultStore(parentTrans, classifyContext(parentTrans)));
}

TEST(wpf_list_first_word_passes_as_typed) {
    // 1.3.15: two whole words went out unaccented before "not a text field" (and the
    // handover was dropped at once). Now the TIP latches it at the first word start.
    Settings st;
    TypingSession s;
    configureDefaults(s, st);
    ListStore d;
    // What TextService::evaluateHost does at the word start.
    const ContextInfo c = wpfListContext();
    const HostText h = classifyContext(c);
    s.setPassedKeysReachApp(passedKeysReachApp(c, h));
    CHECK(wpfDefaultStore(c, h));
    s.markNotTextField();
    CHECK(s.notTextField());
    CHECK(!s.hostDropsPassedKeys());
    // Until the hook acks, every key reaches the list as typed: nothing composed, nothing lost.
    CHECK_EQ(typeList(s, d, "tieengs"), std::string("tieengs"));
    CHECK_EQ(d.lostKeys, 0);
    CHECK(!d.comp);
    CHECK(!s.wordActive());
    // A new field (focus change) is evaluated afresh.
    s.resetContext();
    CHECK(!s.notTextField());
}

TEST(mark_not_text_field_ends_a_word_in_progress) {
    Settings st;
    TypingSession s;
    configureDefaults(s, st);
    ListStore d;
    KeyInput k;
    k.kind = KeyKind::Char;
    k.ch = U'a';
    CHECK(s.wantsKey(k));
    s.markNotTextField();
    CHECK(!s.wantsKey(k));
    CHECK(!s.handleKey(k, d));
    CHECK(!s.wordActive());
}

TEST(direct_handover_survives_focus_moves_inside_a_wpf_window) {
    const uintptr_t wpfWnd = 0x1234, other = 0x5678;
    // One Commander: the filter bar appears / the list refreshes — same HwndSource.
    CHECK(directSurvivesFocusChange(wpfWnd, true, wpfWnd, true));
    // Another window (a dialog, an HwndHost child): released, evaluated afresh.
    CHECK(!directSurvivesFocusChange(wpfWnd, true, other, true));
    // The app lost the foreground (focus NULL, or the window is no longer in front).
    CHECK(!directSurvivesFocusChange(wpfWnd, true, 0, false));
    CHECK(!directSurvivesFocusChange(wpfWnd, true, wpfWnd, false));
    // Not asked for a WPF window (VS Code: the terminal and the editor share one HWND).
    CHECK(!directSurvivesFocusChange(wpfWnd, false, wpfWnd, true));
    // Nothing recorded.
    CHECK(!directSurvivesFocusChange(0, true, 0, true));
}

TEST(describe_context_log_line) {
    const ContextInfo c = wpfListContext();
    const std::string line = describeContext(c, classifyContext(c), u"HwndWrapper[OneCommander.exe;;ab]");
    CHECK_EQ(line, std::string("context: transitory 1 hasParent 1 parentTransitory 0 editControl 0 wpf 1 "
                               "cuasEmulated 0 readOnly 0 host 1 class HwndWrapper[OneCommander.exe;;ab]"));
    ContextInfo none;
    none.hasContext = false;
    const std::string n = describeContext(none, classifyContext(none), u"éx");
    CHECK(n.find("context: none ") == 0);
    CHECK(n.find(" host 4 class ?x") != std::string::npos);
}

// ---- WPF list: the TIP's record of the word passed as typed (typed_word.h, 1.3.16) -----
namespace {
KeyInput charKey(char32_t c) {
    KeyInput k;
    k.kind = KeyKind::Char;
    k.ch = c;
    return k;
}
KeyInput kindKey(KeyKind kind) {
    KeyInput k;
    k.kind = kind;
    return k;
}
TypedWord typedOf(const char* keys) {
    TypedWord w;
    for (const char* p = keys; *p; ++p)
        w.note(*p == '\b' ? kindKey(KeyKind::Backspace) : charKey(static_cast<unsigned char>(*p)));
    return w;
}
}  // namespace

TEST(typed_word_round_trip) {
    CHECK_EQ(typedOf("").encoded(), 0u);
    CHECK(decodeTypedWord(typedOf("doj").encoded()).raw == u"doj");
    CHECK(decodeTypedWord(typedOf("Tie9Z").encoded()).raw == u"Tie9Z");
    const uint32_t v = typedOf("zzzzz").encoded();  // the largest value still < bit 30
    CHECK(v < kTypedWordUnknown);
    CHECK(decodeTypedWord(v).raw == u"zzzzz");
    // Too long for the record: unknown (the hook keeps waiting for a boundary).
    CHECK(decodeTypedWord(typedOf("tieeng").encoded()).unknown);
    CHECK(decodeTypedWord(typedOf("tieeng\b").encoded()).unknown);  // stays unknown
}

TEST(typed_word_follows_the_app) {
    CHECK(decodeTypedWord(typedOf("dox\b").encoded()).raw == u"do");  // ⌫ deletes one
    CHECK_EQ(typedOf("\bd").encoded(), typedOf("d").encoded());         // ⌫ on nothing
    CHECK_EQ(typedOf("abc ").encoded(), 0u);                            // space ends the word
    CHECK(decodeTypedWord(typedOf("abc.do").encoded()).raw == u"do");   // punctuation too
    CHECK(decodeTypedWord(typedOf("o[").encoded()).unknown);             // bracket vowel key
    TypedWord w = typedOf("do");
    w.note(kindKey(KeyKind::Modifier));  // Shift for the next capital
    CHECK(decodeTypedWord(w.encoded()).raw == u"do");
    for (KeyKind k : {KeyKind::Boundary, KeyKind::Navigation, KeyKind::Chord, KeyKind::Other}) {
        TypedWord x = typedOf("do");
        x.note(kindKey(k));
        CHECK_EQ(x.encoded(), 0u);
    }
    KeyInput pad = charKey(U'1');  // numpad digit: never a word key
    pad.numpad = true;
    TypedWord y = typedOf("do");
    y.note(pad);
    CHECK_EQ(y.encoded(), 0u);
    TypedWord z = typedOf("do");
    z.invalidate();  // a key retyped / injected by VietTelex
    CHECK(decodeTypedWord(z.encoded()).unknown);
    z.note(charKey(U'c'));
    CHECK(decodeTypedWord(z.encoded()).unknown);
    z.note(charKey(U' '));
    CHECK_EQ(z.encoded(), 0u);
}

TEST(typed_word_published_only_where_keys_pass_as_typed) {
    const TypedWord w = typedOf("do");
    CHECK_EQ(typedWordToPublish(false, w), 0u);
    CHECK_EQ(typedWordToPublish(true, w), w.encoded());
    // The WPF list context (wpfDefaultStore) is that context.
    const ContextInfo c = wpfListContext();
    CHECK(wpfDefaultStore(c, classifyContext(c)));
}

TEST(direct_mode_param_bits) {
    CHECK_EQ(kDirectOn, 1u);
    CHECK_EQ(kDirectAdoptTyped, 2u);
    CHECK(((kDirectOn | kDirectAdoptTyped) & kDirectOn) != 0);
}

// ---- Win10 Notepad (classic Edit) with text in it: the parent store misreads (2026-11) ----
namespace {
// The Edit itself (`app`: CRLF line breaks, caret anywhere) and the TSF store the TIP reads
// it through. `parentBlind` = the transitory-extension parent as the tester's log showed it
// with text in the file: it reads nothing before the caret, a composition set there "works"
// yet shows nowhere. `keystroke` = the TIP left the parent (storeMisreads): the CUAS
// keystroke context — never read back, its composition is the Edit's own IME composition,
// shown at the caret. `windowView` = the sink answers appTextEndsWith from the Edit's own
// line (EM_GETSEL + EM_GETLINE); false = the TIP before the fix.
struct NotepadEdit : TextSink {
    FakeDocument app;
    bool parentBlind = false;
    bool keystroke = false;
    bool windowView = true;
    bool hiddenComp = false;  // a composition in the blind parent: shown nowhere
    std::u16string hidden;
    bool compHidden = true;   // false: the blind store's composition does show (MISA, #134)
    bool readsNothing() const { return keystroke || parentBlind; }
    bool shownStore() const { return keystroke || !parentBlind || !compHidden; }

    std::u16string textBeforeCaret(int max) override {
        return readsNothing() ? std::u16string() : app.textBeforeCaret(max);
    }
    char16_t charAfterCaret() override { return readsNothing() ? 0 : app.charAfterCaret(); }
    bool hasSelection() override { return app.hasSelection(); }
    bool replaceBeforeCaret(const std::u16string& expect, const std::u16string& ins) override {
        if (parentBlind && !keystroke) return false;  // the read-back check fails
        if (keystroke) {
            if (!expect.empty()) return false;
            for (char16_t c : ins) app.appInsert(c);
            return true;
        }
        return app.replaceBeforeCaret(expect, ins);
    }
    bool compositionActive() override { return shownStore() ? app.comp : hiddenComp; }
    bool compositionText(std::u16string& out) override {
        if (shownStore()) return app.compositionText(out);
        if (!hiddenComp) return false;
        out = hidden;
        return true;
    }
    bool setComposition(const std::u16string& t, int absorb, bool bad) override {
        if (shownStore()) return (keystroke && absorb) ? false : app.setComposition(t, absorb, bad);
        hiddenComp = true;
        hidden = t;
        return true;
    }
    void endComposition(const std::u16string& t) override {
        if (shownStore()) return app.endComposition(t);
        hiddenComp = false;
        hidden.clear();
    }
    void endCompositionAsIs() override {
        if (shownStore()) return app.endCompositionAsIs();
        hiddenComp = false;
        hidden.clear();
    }
    AppView appTextEndsWith(const std::u16string& tail) override {
        if (!windowView || app.hasSelection()) return AppView::Unknown;
        const size_t caret = app.lo();
        size_t start = caret;
        while (start > 0 && app.text[start - 1] != u'\n') --start;
        size_t end = caret;
        while (end < app.text.size() && app.text[end] != u'\r' && app.text[end] != u'\n') ++end;
        return editLineEndsWith(app.text.substr(start, end - start), caret - start, tail);
    }
};

// The TIP around the session, as TextService::OnTestKeyDown / OnKeyDown: a key not claimed
// reaches the Edit; a claimed key the session lets through reaches it too (Notepad), unless
// `dropsClaimed` (an IMM32 app where it became VK_PROCESSKEY, #134 — then only a key the TIP
// retypes arrives). Once the session says the store misreads, the TIP leaves the parent:
// keystroke context, composition only, CUAS (claimed keys retyped). '\n' = Enter (CRLF).
std::string typeNotepad(TypingSession& s, NotepadEdit& d, const char* keys, bool dropsClaimed = false) {
    for (const char* p = keys; *p; ++p) {
        KeyInput k;
        if (*p == '\n') {
            k.kind = KeyKind::Boundary;
        } else {
            k.kind = KeyKind::Char;
            k.ch = static_cast<unsigned char>(*p);
        }
        const bool claimed = s.wantsKey(k);
        if (!claimed) s.noteKeyPassedBy(k);
        const bool eaten = claimed && s.handleKey(k, d);
        if (s.storeMisreads() && !d.keystroke) {
            d.keystroke = true;
            s.setCompositionOnlyContext(true);
            s.setHostDropsPassedKeys(true);
        }
        if (eaten) continue;
        CHECK(!d.compositionActive());  // a key reaching the app never finds a composition
        if (claimed && dropsClaimed && !(s.hostDropsPassedKeys() && passedKeyRetype(k) != PassedKeyRetype::None))
            continue;  // VK_PROCESSKEY: gone
        if (k.kind == KeyKind::Boundary) {
            d.app.appInsert(u'\r');
            d.app.appInsert(u'\n');
        } else {
            d.app.appInsert(static_cast<char16_t>(k.ch));
        }
    }
    return utf16ToUtf8(d.app.text);
}

void notepadSession(TypingSession& s, const Settings& st) {
    configureDefaults(s, st);
    s.setOutputMode(OutputMode::InPlace);  // the app default
    // The TIP for "transitory 1 hasParent 1 parentTransitory 0 editControl 1 cuasEmulated 1
    // host 1": NormalViaParent; as far as it knows, passed keys may be dropped there (#134).
    ContextInfo c;
    c.hasContext = true;
    c.transitory = true;
    c.cuasEmulated = true;
    c.hasParent = true;
    c.parentTransitory = false;
    c.editControl = true;
    CHECK(classifyContext(c) == HostText::NormalViaParent);
    s.setPassedKeysReachApp(passedKeysReachApp(c, classifyContext(c)));
}

const std::string kNotepadLine1 = "D\xc3\xb2ng m\xe1\xbb\x99t\r\n";     // "Dòng một\r\n"
const std::string kNotepadText = kNotepadLine1 + "D\xc3\xb2ng hai\r\n";  // + "Dòng hai\r\n"
}  // namespace

TEST(edit_line_ends_with) {
    CHECK(editLineEndsWith(u"abc tie", 7, u"tie") == AppView::Shows);
    CHECK(editLineEndsWith(u"abc tie more", 7, u"tie") == AppView::Shows);  // caret mid-line
    CHECK(editLineEndsWith(u"abc tix", 7, u"tie") == AppView::Lacks);
    CHECK(editLineEndsWith(u"ti", 1, u"ti") == AppView::Unknown);   // would start on an earlier line
    CHECK(editLineEndsWith(u"abc", 7, u"bc") == AppView::Unknown);  // the copy stops short of the caret
    CHECK(editLineEndsWith(u"abc", 3, u"") == AppView::Unknown);
}

TEST(notepad_with_text_store_misreads_letters_appear) {
    // 2026-11 report (Win10 Notepad, a file with text in it): "in-place: the field shows none
    // of the typed text -> composition" then "letters let through never reached the app (IMM
    // host)" — but they had: the Edit showed them, its parent store did not. The composition
    // went to that store and showed nowhere: no Vietnamese letter ever appeared. Now the
    // Edit's own line proves the letters arrived: that word goes on as typed (the hook adopts
    // it in the real TIP), the field leaves the parent and composes in the keystroke context.
    Settings st;
    TypingSession s;
    notepadSession(s, st);
    NotepadEdit d;
    d.app.setText(utf8ToUtf16(kNotepadText));  // caret at the end, after the last CRLF
    d.parentBlind = true;
    typeNotepad(s, d, "tie");
    CHECK(s.storeMisreads());
    CHECK(s.passingWord());
    CHECK_EQ(typeNotepad(s, d, "engs vieetj nhaf\nddi "),
             kNotepadText + "tieengs vi\xe1\xbb\x87t nh\xc3\xa0\r\n\xc4\x91i ");  // "tieengs việt nhà\r\nđi "
    CHECK(!s.passingWord());  // the Space ended the word passed as typed
    CHECK(!d.hiddenComp);     // nothing composed into the blind store
}

TEST(notepad_with_text_store_misreads_caret_mid_document) {
    // Same, the caret at the start of the second line (CRLF before it, text after it).
    Settings st;
    TypingSession s;
    notepadSession(s, st);
    NotepadEdit d;
    d.app.setText(utf8ToUtf16(kNotepadText));
    d.app.caret = d.app.anchor = utf8ToUtf16(kNotepadLine1).size();
    d.parentBlind = true;
    CHECK_EQ(typeNotepad(s, d, "xin chaof "),
             kNotepadLine1 + "xin ch\xc3\xa0o D\xc3\xb2ng hai\r\n");  // "xin chào "
    CHECK(s.storeMisreads());
}

TEST(notepad_with_text_store_misreads_without_the_fix_shows_nothing) {
    // Guard on the rig: a TIP that cannot look at the Edit (the 1.3.15 path) composes into the
    // blind store — after the first letter, nothing typed appears.
    Settings st;
    TypingSession s;
    notepadSession(s, st);
    NotepadEdit d;
    d.app.setText(utf8ToUtf16(kNotepadText));
    d.parentBlind = true;
    d.windowView = false;
    CHECK_EQ(typeNotepad(s, d, "tieengs vieetj "), kNotepadText + "t");
    CHECK(!s.storeMisreads());
    CHECK(s.contextFellBack());
}

TEST(notepad_readable_store_stays_in_place_with_crlf_text) {
    // A parent store that does read the Edit (the empty file in the report; here text with
    // CRLF, caret at the end and in the middle): in-place as before, no fallback.
    for (bool middle : {false, true}) {
        Settings st;
        TypingSession s;
        notepadSession(s, st);
        NotepadEdit d;
        d.app.setText(utf8ToUtf16(kNotepadText));
        if (middle) d.app.caret = d.app.anchor = utf8ToUtf16(kNotepadLine1).size();
        const std::string got = typeNotepad(s, d, "tieengs vieetj\nddi ");
        const std::string typed = "ti\xe1\xba\xbfng vi\xe1\xbb\x87t\r\n\xc4\x91i ";  // "tiếng việt\r\nđi "
        CHECK_EQ(got, middle ? kNotepadLine1 + typed + "D\xc3\xb2ng hai\r\n" : kNotepadText + typed);
        CHECK(!s.storeMisreads());
        CHECK(!s.contextFellBack());
        CHECK(s.wordMode() == OutputMode::InPlace);
        CHECK(d.app.edits > 0);  // the accents were edited in place
    }
}

TEST(edit_dropping_claimed_keys_still_composes_them) {
    // #134 kept: an IMM32 Edit that DROPS a claimed key let through (MISA SME): the store
    // shows none of the letters and neither does the Edit's own line -> the letters are
    // composed with the rest of the word (that store's composition shows), nothing lost,
    // nothing doubled.
    Settings st;
    TypingSession s;
    notepadSession(s, st);
    NotepadEdit d;
    d.app.setText(utf8ToUtf16("M\xc3\xa3: "));  // "Mã: " — text before the caret, same line
    d.parentBlind = true;
    d.compHidden = false;
    CHECK_EQ(typeNotepad(s, d, "Luwowng nhaan vieen ", true),
             std::string("M\xc3\xa3: L\xc6\xb0\xc6\xa1ng nh\xc3\xa2n vi\xc3\xaan "));  // "Mã: Lương nhân viên "
    CHECK(!s.storeMisreads());
    CHECK(s.hostDropsPassedKeys());
}

TEST(edit_dropping_claimed_keys_after_existing_text_composes_them) {
    // 2026-11 report (Edge's Save As on Windows 10, the file name edited at its end): the
    // parent store READS the Edit, the Edit drops claimed keys let through. The store showed
    // the old text, not empty -> "no longer ends with the word -> word dropped" on every
    // key ("read 1, word 1"), each key lost the same way: no key typed anything while
    // Vietnamese was on. Now the unchanged text before the caret proves the first letter
    // never arrived: the word is composed whole.
    Settings st;
    TypingSession s;
    notepadSession(s, st);
    NotepadEdit d;
    const std::string name = "H\xc4\x90 s\xe1\xbb\xad" "a (YKT\xc4\x90)";  // "HĐ sửa (YKTĐ)"
    d.app.setText(utf8ToUtf16(name));
    CHECK_EQ(typeNotepad(s, d, " cos comment thaamr ddinhj ", true),
             name + " c\xc3\xb3 comment th\xe1\xba\xa9m \xc4\x91\xe1\xbb\x8bnh ");  // " có comment thẩm định "
    CHECK(s.hostDropsPassedKeys());
    CHECK(s.contextFellBack());
    CHECK(!s.storeMisreads());
}

TEST(edit_caret_moved_after_the_first_letter_is_not_an_imm_host) {
    // The letter DID arrive, then the caret moved (a click): the text before the caret is
    // not what it was when the word started -> the word is dropped as before, in place.
    Settings st;
    TypingSession s;
    notepadSession(s, st);
    NotepadEdit d;
    d.app.setText(utf8ToUtf16("abc def"));
    typeNotepad(s, d, "t");
    d.app.caret = d.app.anchor = 3;  // after "abc"
    typeNotepad(s, d, "i");
    CHECK(!s.hostDropsPassedKeys());
    CHECK(!s.contextFellBack());
    CHECK_EQ(utf16ToUtf8(d.app.text), std::string("abci deft"));
}

TEST(passing_word_ends_at_a_non_word_key_and_with_the_focus) {
    Settings st;
    TypingSession s;
    notepadSession(s, st);
    NotepadEdit d;
    d.app.setText(utf8ToUtf16(kNotepadText));
    d.parentBlind = true;
    typeNotepad(s, d, "vie");
    CHECK(s.passingWord());
    KeyInput shift;
    shift.kind = KeyKind::Modifier;  // Shift for a capital: the word goes on
    CHECK(!s.wantsKey(shift));
    s.noteKeyPassedBy(shift);
    CHECK(s.passingWord());
    KeyInput bs;
    bs.kind = KeyKind::Backspace;  // ⌫: not claimed (no word), ends the word passed as typed
    CHECK(!s.wantsKey(bs));
    s.noteKeyPassedBy(bs);
    CHECK(!s.passingWord());
    CHECK(s.storeMisreads());
    s.resetContext();  // a new focus: the store gets another chance
    CHECK(!s.storeMisreads());
    CHECK(!s.passingWord());
}

// ---------------------------------------------------------------- tự kiểm sau mỗi lần sửa
// 2026-11 (Windows 1.3.18, Word desktop, ô tìm kiếm của khung Navigation — Ctrl+F): "đầu
// mối" ra "đàu môi". Mô hình: ô nhận lần thay tại chỗ rồi tự đặt lại chữ cũ (search-as-you-
// type). Trước bản sửa mô hình ra ĐÚNG chuỗi báo lỗi: "ddaafu" với lần thay thứ 2 (a->â) bị
// ô bỏ -> "f" thấy màn hình lệch, bỏ từ, re-edit "đa"+f = "đà", "u" -> "đàu"; "moois" với lần
// thay thứ 2 (dấu sắc, lần cuối của từ) bị bỏ, không còn phím nào sau nó -> "môi".

namespace {
// Replaces the engine makes for `keys` in a normal field (to pick which one the app undoes).
int replacesFor(const char* keys) {
    Rig r(OutputMode::InPlace);
    r.type(keys);
    return r.doc.replaces;
}
std::string* gUndoLog = nullptr;
}  // namespace

TEST(field_undoing_a_replace_keeps_the_word_and_composes_after) {
    // The 2nd replace of "ddaafu" (a -> â) is undone by the app (before the fix: "đàu").
    Rig r(OutputMode::InPlace);
    std::string log;
    gUndoLog = &log;
    SessionOptions o;
    o.engineFlags = r.settings.engineFlags();
    o.autoRestore = r.settings.autoRestore;
    o.reEditWord = r.settings.reEditWord;
    o.log = [](const char* m) {
        if (gUndoLog) *gUndoLog += std::string(m) + "\n";
    };
    r.s.configure(o);
    r.doc.undoReplaces = {2};
    r.type("ddaafu ");
    CHECK_EQ(r.text(), std::string("đầu "));
    CHECK(r.s.prefersComposition());
    CHECK(r.s.takeFieldUnreliable());
    CHECK(!r.s.takeFieldUnreliable());  // one event
    CHECK(!r.s.contextFellBack());      // never handed to the hook: composition only
    CHECK(log.find("undid our last replace") != std::string::npos);
    r.type("moois");
    CHECK(r.s.wordMode() == OutputMode::Composition);
    r.type(" ");
    CHECK_EQ(r.text(), std::string("đầu mối "));
    r.s.resetContext();  // another field: in-place again (the TIP remembers the control kind)
    CHECK(!r.s.prefersComposition());
    gUndoLog = nullptr;
}

TEST(field_undoing_the_last_replace_of_a_word_is_repaired_at_the_boundary) {
    // "moois": the tone replace is the word's last edit, nothing typed after it but the space.
    const int n = replacesFor("moois");
    Rig r(OutputMode::InPlace);
    r.doc.undoReplaces = {n};
    r.type("moois");
    CHECK_EQ(n, 2);
    CHECK_EQ(r.text(), std::string("môi"));  // what the tester saw (until the boundary)
    r.type(" ");
    CHECK_EQ(r.text(), std::string("mối "));
    CHECK(r.s.takeFieldUnreliable());
}

TEST(field_undoing_a_replace_seen_at_end_edit_keeps_the_word) {
    // OnEndEdit (verifyScreen) sees the undone text first: the word is kept, not dropped.
    Rig r(OutputMode::InPlace);
    r.doc.undoReplaces = {2};
    for (const char* p = "ddaafu moois "; *p; ++p) {
        r.key(*p);
        r.s.verifyScreen(r.doc);
    }
    CHECK_EQ(r.text(), std::string("đầu mối "));
}

TEST(normal_and_rewriting_fields_never_report_unreliable) {
    // A normal field and a search box re-setting the SAME text each key: no event, in-place.
    Rig r(OutputMode::InPlace);
    r.type("tieengs vieetj ddaauf moois ");
    CHECK_EQ(r.text(), std::string("tiếng việt đầu mối "));
    CHECK(!r.s.takeFieldUnreliable());
    CHECK(!r.s.prefersComposition());
    Rig b(OutputMode::InPlace);
    for (const char* p = "ddaauf moois "; *p; ++p) {
        b.key(*p);
        std::u16string t = b.doc.text;
        b.doc.setText(t);
        b.s.verifyScreen(b.doc);
    }
    CHECK_EQ(b.text(), std::string("đầu mối "));
    CHECK(!b.s.takeFieldUnreliable());
    // A click elsewhere is no undo: the word is dropped as before, nothing remembered.
    Rig c(OutputMode::InPlace);
    c.type("vieet");
    c.doc.setText(u"something else");
    c.s.verifyScreen(c.doc);
    CHECK(!c.s.wordActive());
    CHECK(!c.s.takeFieldUnreliable());
}

// 1.3.19 report: with the installed edition (TSF) Word's Navigation search box still gave
// "đàu môi" (the portable hook was fine). Through TSF the app putting its text back is
// several edits; OnEndEdit saw the first one (field emptied / all selected / part of the
// word) — neither the word nor the undone signature — and dropped the word, so the next
// tone key re-edited the unaccented word ("đa" + f -> "đà") and the last word was lost.
TEST(field_undoing_a_replace_through_tsf_rewrite_steps_types_the_phrase) {
    using RW = FakeDocument::Rewrite;
    for (RW style : {RW::Atomic, RW::ClearThenSet, RW::SelectAllThenCollapse, RW::Piecewise}) {
        // Replaces of "ddaafu moois": 1 dd, 2 aa, 3 f, 4 oo, 5 s. Undone: "aa" (the report's
        // "đàu"), only the last word's tone (its "môi", seen at the commit), all but the 1st.
        for (int variant = 0; variant < 3; ++variant) {
            Rig r(OutputMode::InPlace);
            r.s.setPassedKeysReachApp(true);  // a TSF-native store (Word)
            r.doc.rewrite = style;
            if (variant == 0) r.doc.undoReplaces = {2};
            if (variant == 1) r.doc.undoReplaces = {5};
            if (variant == 2)
                for (int i = 2; i < 64; ++i) r.doc.undoReplaces.insert(i);
            for (const char* p = "ddaafu moois "; *p; ++p) {
                r.key(*p);
                r.doc.appRewrite([&] { r.s.verifyScreen(r.doc); });
                r.s.verifyScreen(r.doc);
            }
            CHECK_EQ(r.text(), std::string("đầu mối "));
            CHECK(r.s.prefersComposition());
            CHECK(r.s.takeFieldUnreliable());
            CHECK(!r.s.notTextField());
        }
    }
}

TEST(field_rewriting_the_same_text_in_steps_keeps_the_word_in_place) {
    // A search box that re-sets the SAME text after every key, in TSF steps: nothing undone,
    // the words stay in place (before: the emptied step dropped the word mid-way).
    using RW = FakeDocument::Rewrite;
    for (RW style : {RW::ClearThenSet, RW::SelectAllThenCollapse, RW::Piecewise}) {
        Rig r(OutputMode::InPlace);
        r.s.setPassedKeysReachApp(true);
        r.doc.rewrite = style;
        for (const char* p = "ddaauf moois "; *p; ++p) {
            r.key(*p);
            r.doc.undidReplace = true;  // the app re-sets its (unchanged) text
            r.doc.appRewrite([&] { r.s.verifyScreen(r.doc); });
        }
        CHECK_EQ(r.text(), std::string("đầu mối "));
        CHECK(!r.s.takeFieldUnreliable());
        CHECK(!r.s.prefersComposition());
    }
}

TEST(field_seen_mid_rewrite_then_changed_drops_the_word_cleanly) {
    // Emptied (or a click at the field's start) after a replace, then something else: the
    // word is dropped at the next key as before — not "the store never shows the keys"
    // (not-a-text-field), not composed, the key typed normally.
    Rig r(OutputMode::InPlace);
    r.s.setPassedKeysReachApp(true);
    r.type("vieet");
    r.doc.caret = r.doc.anchor = 0;  // click at the start of the field
    r.s.verifyScreen(r.doc);
    CHECK(r.s.wordActive());  // undecided: the field may be re-setting its text
    r.type("ab ");
    CHECK_EQ(r.text(), std::string("ab viêt"));
    CHECK(!r.s.notTextField());
    CHECK(!r.s.prefersComposition());
    CHECK(!r.s.takeFieldUnreliable());
    // ...and at a boundary: the field emptied, then other text: nothing committed or expanded.
    Rig b(OutputMode::InPlace);
    b.settings.shortcuts[u"vieet"] = u"X";
    b.settings.shortcuts[u"viêt"] = u"X";
    b.apply();
    b.type("vieet");
    b.doc.setText(u"");
    b.s.verifyScreen(b.doc);
    b.doc.setText(u"other");
    b.type(" ");
    CHECK_EQ(b.text(), std::string("other "));
    CHECK(!b.s.wordActive());
}

TEST(word_ui_text_boxes_compose_from_the_first_letter) {
    CHECK(officeUiPrefersComposition("winword.exe", u"NetUIHWND", false));  // Navigation search
    CHECK(!officeUiPrefersComposition("winword.exe", u"_WwG", false));      // the document
    CHECK(!officeUiPrefersComposition("winword.exe", u"NetUIHWND", true));  // async store
    CHECK(!officeUiPrefersComposition("winword.exe", u"", false));
    CHECK(!officeUiPrefersComposition("notepad.exe", u"NetUIHWND", false));
    CHECK(officeUiPrefersComposition("winword.exe", u"RICHEDIT60W", false));  // the box in the log
    CHECK(!officeUiPrefersComposition("winword.exe", u"RICHEDIT60W", true));
    CHECK(!officeUiPrefersComposition("excel.exe", u"RICHEDIT60W", false));    // Word only
    CHECK(!officeUiPrefersComposition("winword.exe", u"RichEdit20W", false));
    // Composing there (setPreferComposition, as the TIP does): the phrase comes out whole
    // even when the box undoes every replace.
    Rig r(OutputMode::InPlace);
    r.s.setPreferComposition(true);
    for (int i = 1; i < 64; ++i) r.doc.undoReplaces.insert(i);
    r.type("ddaafu moois ");
    CHECK_EQ(r.text(), std::string("đầu mối "));
    CHECK_EQ(r.doc.replaces, 0);  // never edited in place
}

// 1.3.20 report (installed TIP, reinstalled, Word restarted): the Navigation search box
// still gave wrong marks. Its debug log (1.3.18, 1.3.19 and 1.3.20 alike) shows focus class
// "RICHEDIT60W" — not "NetUIHWND", so officeUiPrefersComposition never matched — a sync,
// non-transitory store, in-place, and per word three "word dropped" lines on consecutive keys
// with no rewrite / undo line at all. Model that reproduces those lines EXACTLY (same order,
// same read / word lengths, the last word holding 2 keys at the focus change): every key the
// TIP lets through is offered to the keystroke manager a second time before the box inserts
// it (Word's loop, then the RichEdit). The second offer sees the word without that letter.
namespace {
std::string* gNavLog = nullptr;
struct WordNavSearch : Rig {
    KeyEventRepeat rep;
    bool guard = true;  // the TIP's KeyEventRepeat (OnTestKeyDown / OnKeyDown / key-up)
    uint32_t clock = 0;
    std::string log;
    explicit WordNavSearch(OutputMode m) : Rig(m) {
        settings.freeMarking = false;  // the tester's settings in that log
        settings.underlineMisspelled = true;
        SessionOptions o;
        o.engineFlags = settings.engineFlags();
        o.autoRestore = settings.autoRestore;
        o.reEditWord = settings.reEditWord;
        o.underlineMisspelled = settings.underlineMisspelled;
        o.shortcuts = &settings.shortcuts;
        o.log = [](const char* m) {
            if (gNavLog) *gNavLog += std::string(m) + "\n";
        };
        s.configure(o);
        s.setPassedKeysReachApp(true);  // TSF-native store (app_policy passedKeysReachApp)
        gNavLog = &log;
    }
    ~WordNavSearch() { gNavLog = nullptr; }
    // One offer = OnTestKeyDown + OnKeyDown, as text_service.cpp calls the guard.
    bool offer(const KeyInput& k, const KeyEventRepeat::Id& id) {
        if (guard && rep.atTest(id)) return false;
        if (guard) rep.begin(id);
        if (!s.wantsKey(k)) {
            s.noteKeyPassedBy(k);
            if (guard) rep.testDeclined(id);
            return false;
        }
        if (guard && rep.atKeyDown(id)) return false;
        const bool eaten = s.handleKey(k, doc);
        if (guard) rep.keyDownDone(id, eaten);
        return eaten;
    }
    void typeKeys(const char* keys) {
        for (const char* p = keys; *p; ++p) {
            KeyInput k;
            k.kind = KeyKind::Char;
            k.ch = static_cast<unsigned char>(*p);
            const KeyEventRepeat::Id id{static_cast<uint64_t>(*p), 1, clock += 120};  // one press
            bool eaten = offer(k, id);
            if (!eaten) eaten = offer(k, id);  // the box hands the same key event over again
            if (!eaten) {
                CHECK(!doc.comp);
                doc.appInsert(static_cast<char16_t>(*p));
            }
            if (guard) rep.keyUp(id.wp);
        }
    }
};
}  // namespace

TEST(word_navigation_search_offering_passed_keys_twice_reproduces_the_log) {
    // Unguarded: exactly the tester's log lines (lengths only) and the damaged phrase.
    WordNavSearch r(OutputMode::InPlace);
    r.guard = false;
    r.typeKeys("ddaauf moois");
    const std::string dropped = "in-place: text before the caret no longer ends with the word -> word dropped, "
                                "this key starts a new word ";
    CHECK_EQ(r.log, std::string("in-place: the store shows none of the typed keys although the app got them -> "
                                "word as typed\n") +
                        dropped + "(read 1, word 2)\n" + dropped + "(read 2, word 2)\n" +  // đầu
                        dropped + "(read 1, word 1)\n" + dropped + "(read 2, word 2)\n" +  // mối
                        dropped + "(read 2, word 2)\n");
    CHECK_EQ(r.s.rawKeys().size(), static_cast<size_t>(2));  // "focus changed mid-word (2 keys)"
    CHECK_EQ(r.text(), std::string("đâù môí"));
}

TEST(word_navigation_search_second_offer_is_ignored) {
    // The TIP ignores the second offer of a key it let through: in place, nothing dropped.
    WordNavSearch r(OutputMode::InPlace);
    r.typeKeys("tieengs vieetj ddaauf moois ");
    CHECK_EQ(r.text(), std::string("tiếng việt đầu mối "));
    CHECK_EQ(r.log, std::string());
    // Composing from the first letter (officeUiPrefersComposition: the box's class) works even
    // if the second offer slipped through (a host where the message time differs).
    WordNavSearch c(OutputMode::InPlace);
    c.guard = false;
    CHECK(officeUiPrefersComposition("winword.exe", u"RICHEDIT60W", false));
    c.s.setPreferComposition(true);
    c.typeKeys("tieengs vieetj ddaauf moois ");
    CHECK_EQ(c.text(), std::string("tiếng việt đầu mối "));
    CHECK_EQ(c.doc.replaces, 0);
}

TEST(key_event_repeat_only_matches_the_same_passed_event) {
    KeyEventRepeat r;
    const KeyEventRepeat::Id a{'D', 0x00200001, 1000};
    r.begin(a);
    CHECK(!r.atTest(a));
    CHECK(!r.atKeyDown(a));       // OnKeyDown right after OnTestKeyDown: the same offer
    r.keyDownDone(a, true);       // claimed: never offered again, nothing to ignore
    CHECK(!r.atTest(a));
    r.keyDownDone(a, false);      // let through
    CHECK(r.atTest(a));
    CHECK(r.atKeyDown(a));
    const KeyEventRepeat::Id later{'D', 0x00200001, 1016};  // a new press of the same key
    CHECK(!r.atTest(later));
    const KeyEventRepeat::Id repeat{'D', 0x40200001, 1000};  // auto-repeat: another lParam
    CHECK(!r.atTest(repeat));
    r.keyUp('E');
    CHECK(r.atTest(a));
    r.keyUp('D');                 // the press ended
    CHECK(!r.atTest(a));
    r.begin(a);
    r.testDeclined(a);            // OnTestKeyDown let it through
    CHECK(r.atTest(a));           // a second OnTestKeyDown: ignored
    CHECK(!r.atKeyDown(a));       // OnKeyDown of that same offer still runs
    r.reset();
    CHECK(!r.atTest(a));
}

TEST(unreliable_controls_are_remembered_by_class) {
    UnreliableControls u;
    CHECK(!u.has(u"NetUIHWND"));
    u.remember(u"NetUIHWND");
    u.remember(u"NetUIHWND");
    CHECK(u.has(u"NetUIHWND"));
    CHECK_EQ(u.size(), static_cast<size_t>(1));
    CHECK(!u.has(u"_WwG"));  // Word's document body: another kind, stays in-place
    u.remember(u"");         // unknown class: never remembered
    CHECK(!u.has(u""));
    CHECK_EQ(u.size(), static_cast<size_t>(1));
    for (int i = 0; i < 20; ++i) u.remember(u"C" + std::u16string(1, static_cast<char16_t>(u'a' + i)));
    CHECK_EQ(u.size(), static_cast<size_t>(8));  // bounded
}

TEST(hard_field_matrix_types_the_phrase) {
    // Every known kind of "hard" synchronous field, same phrase: Vietnamese comes out whole.
    // (Async / Chromium stores: chromium_store_tests.cpp; read-only / disabled / no context:
    // the TIP never hands those keys to the session — host_text_policy; IMM hosts, consoles,
    // WPF, Notepad's misreading store: their own tests above.)
    // A TSF-native store (Word & co): keys let through reach the app (passedKeysReachApp).
    const char* keys = "tieengs vieetj ddaafu moois ddaauf ";
    const std::string whole = "tiếng việt đầu mối đầu ";
    struct Kind {
        void (*setup)(FakeDocument&);
        bool rewriteEachKey;
        const char* want;  // nullptr = whole
    };
    const Kind kinds[] = {
        {[](FakeDocument&) {}, false, nullptr},                                   // normal
        {[](FakeDocument&) {}, true, nullptr},                                    // re-sets its text
        {[](FakeDocument& d) { d.unreadable = true; }, false, nullptr},           // reads nothing
        {[](FakeDocument& d) { d.undoReplaces = {2}; }, false, nullptr},          // undoes one
        {[](FakeDocument& d) { for (int i = 2; i < 64; ++i) d.undoReplaces.insert(i); }, false, nullptr},  // all but 1st
        {[](FakeDocument& d) { for (int i = 1; i < 64; ++i) d.undoReplaces.insert(i); }, false, nullptr},  // all
        // Not ready at the first key (its first read sees nothing): no letter doubled or lost.
        {[](FakeDocument& d) { d.blankReads = 1; }, false, nullptr},
        // (Several empty reads in a row look like WPF's empty default store — "not a text
        // field", keys pass as typed: wpf_* / not_a_text_field_* tests. Deliberately not
        // re-tuned here.)
    };
    for (const Kind& k : kinds) {
        const std::string want = k.want ? k.want : whole;
        for (bool endEdit : {false, true}) {
            Rig r(OutputMode::InPlace);
            r.s.setPassedKeysReachApp(true);
            k.setup(r.doc);
            for (const char* p = keys; *p; ++p) {
                r.key(*p);
                if (k.rewriteEachKey) {
                    std::u16string t = r.doc.text;
                    r.doc.setText(t);
                }
                if (endEdit) r.s.verifyScreen(r.doc);
            }
            CHECK_EQ(r.text(), want);
        }
    }
}

// ---- 2026-11: Gmail's "#" (delete) did nothing in V mode -------------------------------
// A key Telex does not transform, with no word in progress, is never claimed: the app (a web
// page's single-key shortcut) gets the genuine key event, not one the TIP let through.

TEST(punctuation_with_no_word_passes_through) {
    const char32_t keys[] = {U'#', U'?', U'!', U'/', U'[', U']', U'1', U'0', U'.', U',', U'*', U'@'};
    const KeyInput enter{KeyKind::Boundary, 0}, nav{KeyKind::Navigation, 0}, chord{KeyKind::Chord, 0};
    for (OutputMode m : {OutputMode::Composition, OutputMode::InPlace}) {
        Rig r(m);
        for (char32_t c : keys) CHECK(!r.s.wantsKey(KeyInput{KeyKind::Char, c}));
        CHECK(!r.s.wantsKey(enter));
        CHECK(!r.s.wantsKey(nav));
        CHECK(!r.s.wantsKey(chord));
        // Right after a committed word (⌫ re-open armed): still not claimed.
        r.type("vieetj ");
        CHECK_EQ(r.text(), std::string("việt "));
        for (char32_t c : keys) CHECK(!r.s.wantsKey(KeyInput{KeyKind::Char, c}));
        CHECK(!r.s.wantsKey(enter));
        CHECK(!r.s.wantsKey(nav));
        CHECK(!r.s.wantsKey(chord));
        // Letters still are (a word may start), and so is ⌫ (it re-opens the word).
        CHECK(r.s.wantsKey(KeyInput{KeyKind::Char, U'j'}));
        CHECK(r.s.wantsKey(KeyInput{KeyKind::Backspace, 0}));
    }
}

TEST(shift3_in_noneditable_context_passes) {
    // Gmail's list: "#" with nothing typed — not claimed, in either mode, retro English on
    // or off.
    for (bool retroOn : {false, true}) {
        for (OutputMode m : {OutputMode::Composition, OutputMode::InPlace}) {
            RetroRig r(m, retroOn);
            const KeyInput hash{KeyKind::Char, U'#'};
            CHECK(!r.s.wantsKey(hash));
            r.send(hash);
            CHECK_EQ(r.text(), std::string("#"));
            CHECK(!r.s.wantsKey(hash));  // "##"
        }
    }
}

TEST(passed_key_disarms_reopen_and_retro_undo) {
    for (OutputMode m : {OutputMode::Composition, OutputMode::InPlace}) {
        // ⌫ right after "việt␣" re-opens the word; after "việt␣#" it only deletes "#".
        Rig r(m);
        r.type("vieetj #");
        CHECK_EQ(r.text(), std::string("việt #"));
        CHECK(!r.s.wantsKey(KeyInput{KeyKind::Backspace, 0}));
        r.type("\b\b");
        CHECK_EQ(r.text(), std::string("việt"));
        CHECK(!r.s.wordActive());
        // A passed arrow disarms it the same way.
        Rig e(m);
        e.type("vieetj ");
        e.send(KeyInput{KeyKind::Navigation, 0});
        CHECK(!e.s.wantsKey(KeyInput{KeyKind::Backspace, 0}));
        // Retro English: the one-key ⌫ undo dies with a passed punctuation key.
        RetroRig q(m, true);
        q.type("His car is very ");
        CHECK(q.s.retroUndoArmed());
        q.type("?");
        CHECK(!q.s.retroUndoArmed());
        q.key('\b');
        CHECK_EQ(q.text(), std::string("His car is very "));
    }
}

TEST(punctuation_after_word_still_commits_first) {
    // A symbol ending a word is still claimed: the word is committed before the symbol
    // reaches the app (ordering); auto-restore and tone keys unchanged.
    bothModes("vieetj#", "việt#");
    bothModes("tieengs?", "tiếng?");
    bothModes("google!", "google!");
    bothModes("dduwowngf/", "đường/");
    bothModes("xin chaof, cacs banj.", "xin chào, các bạn.");
    for (OutputMode m : {OutputMode::Composition, OutputMode::InPlace}) {
        Rig r(m);
        r.type("vieet");
        CHECK(r.s.wantsKey(KeyInput{KeyKind::Char, U'#'}));
        CHECK(r.s.wantsKey(KeyInput{KeyKind::Char, U'j'}));  // tone key after a word
    }
}

// #163 (ported from macOS c805edce): every refusal of a re-edit / ⌫ re-open CANDIDATE names
// its reason in the debug log — silent exits made "Sửa dấu từ đã gõ" look dead in the field.
// Lengths and kinds only, never typed text.
namespace {
std::string* g163Log = nullptr;
void log163(const char* m) {
    if (g163Log) *g163Log += std::string(m) + "\n";
}
struct LogRig : Rig {
    std::string log;
    explicit LogRig(OutputMode m) : Rig(m) {
        SessionOptions o;
        o.engineFlags = settings.engineFlags();
        o.autoRestore = settings.autoRestore;
        o.reEditWord = settings.reEditWord;
        o.shortcuts = &settings.shortcuts;
        o.log = log163;
        o.verboseLog = true;
        s.configure(o);
        g163Log = &log;
    }
    ~LogRig() { g163Log = nullptr; }
    bool has(const char* what) const { return log.find(what) != std::string::npos; }
};
}  // namespace

TEST(issue163_reedit_refusals_are_logged) {
    for (OutputMode m : {OutputMode::Composition, OutputMode::InPlace}) {
        {  // a tone key starting a word after a space: nothing to reach back into
            LogRig r(m);
            r.type("toan s");
            CHECK(r.has("re-edit: skipped (no word right before the caret)"));
        }
        {  // caret inside a word ("toa|n")
            LogRig r(m);
            r.doc.text = u"toan";
            r.doc.caret = r.doc.anchor = 3;
            r.type("s");
            CHECK(r.has("re-edit: skipped (caret inside a word)"));
        }
        {  // glued to a token opener ("#toan")
            LogRig r(m);
            r.doc.text = u"#toan";
            r.doc.caret = r.doc.anchor = 5;
            r.type("s");
            CHECK(r.has("re-edit: skipped (word glued to a token opener)"));
        }
        {  // re-edit itself still works and logs what it did
            LogRig r(m);
            r.doc.text = u"toan";
            r.doc.caret = r.doc.anchor = 4;
            r.type("s ");
            CHECK_EQ(r.text(), std::string("toán "));
            CHECK(r.has("re-edit: a tone key reached back"));
        }
        // Never typed text in the log.
        LogRig r(m);
        r.type("toan s");
        CHECK(r.log.find("toan") == std::string::npos);
    }
}

TEST(issue163_reopen_refusals_are_logged) {
    for (OutputMode m : {OutputMode::Composition, OutputMode::InPlace}) {
        {  // the screen no longer shows "<word><boundary>" (edited outside the TIP)
            LogRig r(m);
            r.type("thays ");
            r.doc.text = u"thay ";
            r.doc.caret = r.doc.anchor = 5;
            r.type("\b");
            CHECK_EQ(r.text(), std::string("thay"));
            CHECK(!r.s.wordActive());
            CHECK(r.has("⌫ re-open: skipped (text before the caret is not the word + boundary)"));
        }
        {  // a selection: ⌫ deletes it, nothing re-opened
            LogRig r(m);
            r.type("thays ");
            r.doc.anchor = 0;
            KeyInput bs{KeyKind::Backspace, 0};
            CHECK(!(r.s.wantsKey(bs) && r.s.handleKey(bs, r.doc)));
            CHECK(!r.s.wordActive());
            CHECK(r.has("⌫ re-open: skipped (selection)"));
        }
        {  // success is logged too (lengths only)
            LogRig r(m);
            r.type("thays \ba");
            CHECK_EQ(r.text(), std::string("thấy"));
            CHECK(r.has("⌫ re-open: 4 chars back in the engine"));
            CHECK(r.log.find("thay") == std::string::npos);
        }
    }
}

TEST(issue163_reopen_refused_in_console_is_logged) {
    Settings st;
    TypingSession s;
    std::string log;
    g163Log = &log;
    SessionOptions o;
    o.engineFlags = st.engineFlags();
    o.autoRestore = st.autoRestore;
    o.reEditWord = st.reEditWord;
    o.log = log163;
    s.configure(o);
    s.setCompositionOnlyContext(true);
    ConsoleDoc d;
    typeConsole(s, d, "thays ");
    KeyInput bs;
    bs.kind = KeyKind::Backspace;
    CHECK(!(s.wantsKey(bs) && s.handleKey(bs, d)));
    CHECK(!s.wordActive());
    CHECK(log.find("⌫ re-open: skipped (composition-only context") != std::string::npos);
    g163Log = nullptr;
}

// ---------------------------------------------------------------- Tự thêm dấu mũ (#166)
// Settings::autoCircumflex reaches the engine: "vietj" types việt, "benhj" bệnh; off (the
// default) leaves the old behaviour.
TEST(session_auto_circumflex) {
    for (OutputMode m : {OutputMode::Composition, OutputMode::InPlace}) {
        Rig on(m);
        on.settings.autoCircumflex = true;
        on.apply();
        on.type("vietj benhj luanj quanr ");
        CHECK_EQ(on.text(), std::string("việt bệnh luận quản "));
        Rig off(m);
        off.type("vietj ");
        CHECK(off.text() != std::string("việt "));
    }
}
