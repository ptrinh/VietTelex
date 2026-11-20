// #173: a Chromium address bar handed to the hook (Direct) instead of composed (the browser
// underlines any composition there). A fake address bar with inline autocomplete: typing a
// character replaces the selected suggestion, then a new suggestion may be selected after
// the typed text; Backspace with a suggestion removes ONLY the suggestion (and none comes
// back after a deletion). The hook's batches are the DirectKeyEvents of direct_policy.h,
// applied one event at a time. The TIP side (keys pass as typed until the ack, the hook adopts
// that word) follows text_service.cpp fieldPolicyAtWordStart + word_adopt.h.
#include <viettelex/vtx_engine.h>

#include <string>
#include <vector>

#include "app_policy.h"
#include "direct_policy.h"
#include "keymap.h"
#include "session.h"
#include "settings.h"
#include "test.h"
#include "typed_word.h"
#include "word_adopt.h"

using namespace vtx;
using namespace vtx::app;

namespace {

constexpr char kEnter = '\n';

struct AddressBar {
    std::u16string typed;       // text up to the caret
    std::u16string suggestion;  // inline autocomplete, selected after the caret
    std::vector<std::u16string> history;
    bool placeholderSeen = false;  // U+202F was ever in the field

    void autocomplete() {
        suggestion.clear();
        for (const std::u16string& h : history)
            if (!typed.empty() && h.size() > typed.size() && h.compare(0, typed.size(), typed) == 0) {
                suggestion = h.substr(typed.size());
                return;
            }
    }
    void typeChar(char16_t c) {
        suggestion.clear();  // typing replaces the selection
        typed.push_back(c);
        if (c == kAutocompletePlaceholder) placeholderSeen = true;
        autocomplete();
    }
    void backspace() {
        if (!suggestion.empty()) {
            suggestion.clear();  // only the suggestion goes
            return;
        }
        if (!typed.empty()) typed.pop_back();
    }
    void apply(const std::vector<DirectKeyEvent>& ev) {
        for (const DirectKeyEvent& e : ev) {
            if (e.up) continue;
            if (e.unicode) typeChar(static_cast<char16_t>(e.unit));
            else if (e.vk == kVkBack) backspace();
        }
    }
};

// HookSink (hook_fallback.cpp) over the fake address bar: one batch per key, applied at once.
class BarSink final : public TextSink {
public:
    explicit BarSink(bool inlineAc) : inlineAc_(inlineAc) {}
    bool blind() override { return true; }
    std::u16string textBeforeCaret(int) override { return {}; }
    char16_t charAfterCaret() override { return 0; }
    bool hasSelection() override { return false; }
    bool replaceBeforeCaret(const std::u16string& expect, const std::u16string& insert) override {
        const std::vector<DirectKeyEvent> ev =
            directEditEvents(static_cast<unsigned>(expect.size()), insert, inlineAc_);
        batch.insert(batch.end(), ev.begin(), ev.end());
        return true;
    }
    bool compositionActive() override { return false; }
    bool setComposition(const std::u16string&, int, bool) override { return false; }
    void endComposition(const std::u16string&) override {}
    void endCompositionAsIs() override {}
    std::vector<DirectKeyEvent> batch;

private:
    bool inlineAc_;
};

struct BarRig {
    Settings st;
    TypingSession s;
    HookArming arming;
    WordAdoption adoption;
    TypedWord tip;          // the TIP's record (kTypedWordProp)
    AddressBar bar;
    bool hookIn = false;    // the hook acked (engaged mid-focus, kDirectAdoptTyped)
    bool inlineAc = true;   // kDirectInlineAutocomplete
    int placeholderBatches = 0;

    BarRig() {
        SessionOptions o;  // hook_fallback.cpp configureSession
        o.engineFlags = st.engineFlags() & ~static_cast<uint32_t>(VTX_RETRO_ENGLISH);
        o.autoRestore = st.autoRestore;
        o.reEditWord = false;
        o.shortcuts = &st.shortcuts;
        s.configure(o);
        s.setOutputMode(OutputMode::InPlace);
        bar.history = {u"theverge.com", u"google.com", u"thế giới", u"vietnamnet.vn", u"việt nam"};
    }
    static KeyInput classify(char c) {
        KeyInput k;
        if (c == '\b') k.kind = KeyKind::Backspace;
        else if (c == kEnter) k.kind = KeyKind::Boundary;
        else {
            k.kind = KeyKind::Char;
            k.ch = static_cast<unsigned char>(c);
        }
        return k;
    }
    // A key that reached the browser as typed (the TIP records it).
    void browser(const KeyInput& k) {
        if (k.kind == KeyKind::Char) bar.typeChar(static_cast<char16_t>(k.ch));
        if (k.kind == KeyKind::Backspace) bar.backspace();
        tip.note(k);
    }
    void engage() {
        s.resetContext();
        arming.engaged(false);  // mid-focus: the TIP's request
        adoption.engaged(true);
        hookIn = true;
    }
    // hook_fallback.cpp keyboardProc order.
    void key(char c) {
        const KeyInput k = classify(c);
        if (!hookIn) return browser(k);  // the TIP passes it as typed (PassAsTyped)
        if (adoption.pending()) {
            if (adoption.begin(tip.encoded(), k, s) != WordAdoption::Start::Unknown) arming.armNow();
        }
        const bool boundary = k.kind == KeyKind::Boundary || (k.kind == KeyKind::Char && k.ch == U' ');
        if (!arming.key(boundary)) {
            adoption.drop();
            return browser(k);
        }
        if (k.kind == KeyKind::Backspace && userBackspaceDropsWord(inlineAc)) {
            s.reset();
            adoption.drop();
            return browser(k);
        }
        if (adoption.owes() && k.kind == KeyKind::Backspace) {
            adoption.backspace(s);
            return browser(k);
        }
        BarSink sink(inlineAc);
        if (adoption.owes()) {
            const WordAdoption::Fix f = adoption.takeFix();
            sink.replaceBeforeCaret(f.expect, f.insert);
        }
        bool eaten = false;
        if (!s.wantsKey(k)) s.noteKeyPassedBy(k);
        else eaten = s.handleKey(k, sink);
        if (sink.batch.empty()) {
            if (!eaten) browser(k);
            return;
        }
        // The key that still goes to the app is replayed at the end of the batch.
        if (!eaten && k.kind == KeyKind::Char) {
            const std::vector<DirectKeyEvent> ev = directEditEvents(0, std::u16string(1, static_cast<char16_t>(k.ch)));
            sink.batch.insert(sink.batch.end(), ev.begin(), ev.end());
        }
        for (const DirectKeyEvent& e : sink.batch)
            if (e.unicode && e.unit == kAutocompletePlaceholder && !e.up) ++placeholderBatches;
        tip.invalidate();  // the TIP sees our injected edits
        bar.apply(sink.batch);
    }
    void type(const char* keys) {
        for (const char* p = keys; *p; ++p) key(*p);
    }
    std::string typed() const { return utf16ToUtf8(bar.typed); }
};

// The hook acks after `before` reached the field as typed.
std::string run(const char* before, const char* after, bool inlineAc = true) {
    BarRig r;
    r.inlineAc = inlineAc;
    r.type(before);
    r.engage();
    r.type(after);
    return r.typed();
}

}  // namespace

TEST(address_bar_placeholder_only_for_a_real_replace) {
    CHECK(usesPlaceholderEdit(true, 1, false));
    CHECK(usesPlaceholderEdit(true, 5, false));
    CHECK(!usesPlaceholderEdit(true, 0, false));   // plain append: typing replaces the suggestion anyway
    CHECK(!usesPlaceholderEdit(true, 2, true));    // pure deletion: no stray character (macOS 2026-07-27)
    CHECK(!usesPlaceholderEdit(false, 2, false));  // any other Direct field: unchanged
    CHECK(userBackspaceDropsWord(true));
    CHECK(!userBackspaceDropsWord(false));
    // The address bar is never echo-checked (no UI Automation on the browser); other Direct
    // fields are as before, and explicit hook-fallback apps never were.
    CHECK(!echoCheckedAfterEdit(true, true));
    CHECK(echoCheckedAfterEdit(true, false));
    CHECK(!echoCheckedAfterEdit(false, false));
    CHECK(!echoCheckedAfterEdit(false, true));
}

TEST(address_bar_placeholder_sequence_is_one_batch) {
    // "thê" -> "thế": U+202F, Backspace x 2 (the 1 letter + the placeholder), "ế".
    const std::vector<DirectKeyEvent> ev = directEditEvents(1, u"ế", true);
    CHECK_EQ(ev.size(), size_t(2 + 4 + 2));
    CHECK(ev[0].unicode && ev[0].unit == 0x202F && !ev[0].up);
    CHECK(ev[1].unicode && ev[1].unit == 0x202F && ev[1].up);
    for (size_t i = 2; i < 6; ++i) {
        CHECK(!ev[i].unicode);
        CHECK(ev[i].vk == kVkBack);  // a virtual key, never a Unicode 0x08
        CHECK(ev[i].up == (i % 2 == 1));
    }
    CHECK(ev[6].unicode && ev[6].unit == u'ế' && !ev[6].up);
    CHECK(ev[7].unicode && ev[7].up);
    // Same edit outside an address bar: exactly the old batch.
    CHECK(directEditEvents(1, u"ế", false).size() == directEditEvents(1, u"ế").size());
    // Pure deletion and plain append: no placeholder at all.
    for (const DirectKeyEvent& e : directEditEvents(3, u"", true)) CHECK(!e.unicode);
    CHECK_EQ(directEditEvents(3, u"", true).size(), size_t(6));
    const std::vector<DirectKeyEvent> app = directEditEvents(0, u"ư", true);
    CHECK_EQ(app.size(), size_t(2));
    CHECK(app[0].unit == u'ư');
}

TEST(address_bar_tone_while_a_suggestion_shows) {
    // "the" + suggestion "verge.com"; e, s: the field report's word.
    BarRig r;
    r.engage();
    r.type("the");
    CHECK_EQ(utf16ToUtf8(r.bar.suggestion), std::string("verge.com"));
    r.type("es");
    CHECK_EQ(r.typed(), std::string("thế"));
    CHECK(r.placeholderBatches >= 1);
    // Without the placeholder (a plain Direct field) the first Backspace only removes the
    // suggestion: the very corruption #173 must not bring back.
    CHECK(run("", "thees", false) != std::string("thế"));
    CHECK_EQ(run("", "thees", true), std::string("thế"));
}

TEST(address_bar_words_and_autorestore) {
    CHECK_EQ(run("", "vieetj nam"), std::string("việt nam"));
    CHECK_EQ(run("", "thees giowis"), std::string("thế giới"));
    // English with an inline suggestion: "google" stays "google" (macOS "gooogle" report).
    BarRig r;
    r.engage();
    r.type("google");
    r.key(kEnter);
    CHECK_EQ(r.typed(), std::string("google"));
}

TEST(address_bar_ack_after_letters_typed_as_typed) {
    // The TIP passes keys as typed until the hook acks; the hook adopts them at its first key.
    CHECK_EQ(run("t", "hees"), std::string("thế"));
    CHECK_EQ(run("th", "ees"), std::string("thế"));
    CHECK_EQ(run("the", "es"), std::string("thế"));
    CHECK_EQ(run("thee", "s"), std::string("thế"));  // "thee" raw + suggestion: fixed in one batch
    CHECK_EQ(run("vieet", "j"), std::string("việt"));
}

TEST(address_bar_user_backspace_never_edits_blind) {
    // ⌫ while a suggestion shows removes only the suggestion: the hook forgets the word, so
    // no later edit deletes letters it cannot account for.
    BarRig r;
    r.engage();
    r.type("the");
    CHECK(!r.bar.suggestion.empty());
    r.key('\b');
    CHECK_EQ(r.typed(), std::string("the"));  // the browser kept the letters
    CHECK(!r.s.wordActive());
    r.key('\b');                              // now a letter goes, as typed
    CHECK_EQ(r.typed(), std::string("th"));
    r.type("ees");                            // a new word from here: nothing before it is touched
    CHECK(r.bar.typed.compare(0, 2, u"th") == 0);
    // The user's ⌫ (a pure deletion) never types the placeholder.
    BarRig d;
    d.engage();
    d.type("vieet");
    CHECK_EQ(d.typed(), std::string("viêt"));
    d.bar.placeholderSeen = false;
    d.type("\b\b");
    CHECK(!d.bar.placeholderSeen);
    CHECK_EQ(d.typed(), std::string("vi"));
}

TEST(address_bar_no_suggestion_and_text_before_the_word) {
    // No history match: the sequence still lands exactly (the placeholder is typed and deleted).
    BarRig r;
    r.bar.history.clear();
    r.engage();
    r.type("dduwowngf");
    CHECK_EQ(r.typed(), std::string("đường"));
    CHECK(r.bar.suggestion.empty());
    // Text already in the field before the word (typed earlier, caret at the end).
    BarRig m;
    m.bar.history.clear();
    m.bar.typed = u"abc ";
    m.engage();
    m.type("xin chaof");
    CHECK_EQ(m.typed(), std::string("abc xin chào"));
}
