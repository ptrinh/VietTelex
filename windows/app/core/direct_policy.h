// direct_policy.h — when Direct mode (hook + SendInput) may type in a field, and when a
// field falls back to composition. Pure; unit-tested. See hook_fallback.cpp and
// direct_verify.cpp for the Win32 side.
#pragma once
#include <array>
#include <cstdint>
#include <deque>
#include <map>
#include <string>
#include <utility>
#include <vector>

namespace vtx {

// (1) UIPI: SendInput from VietTelex.exe cannot reach a HIGHER-integrity process, and a
// token we cannot read is treated as higher. Integrity = mandatory-label RID
// (0x1000 low, 0x2000 medium, 0x3000 high, 0x4000 system).
bool directUsable(bool targetIntegrityKnown, unsigned long targetIntegrity, unsigned long hookIntegrity);

// (3) SendInput result for one batch.
enum class SendOutcome {
    Ok,             // all events inserted
    NothingSent,    // 0 of n (blocked): pass the user's key through, reset, fall back
    Partial,        // screen now unknown: reset the word, fall back
};
SendOutcome classifySend(unsigned sent, unsigned total);

// (3) Injection guard at the moment of SendInput: the foreground must still be the
// window the word started in, and the input desktop the normal one.
bool injectionAllowed(uintptr_t foregroundNow, uintptr_t foregroundOfWord, bool secureDesktop);

// (2026-11 audit) A foreground update reaches the hook thread. `resetWord`: it names another
// window than the one the hooked word belongs to (two hooked windows: Notepad, then Win ->
// Start search) — the word in progress and the engine context are the old window's; kept,
// the next key would continue that word and its backspaces would land in the new window.
// `keepArming`: the same window, already hooked (a mid-focus re-publish, a TIP handover) —
// its state stays as it is. Window handles as integers.
struct ForegroundUpdate {
    bool resetWord = false;
    bool keepArming = false;
};
inline ForegroundUpdate foregroundUpdate(uintptr_t wordWindow, bool hookWanted, uintptr_t newWindow) {
    ForegroundUpdate u;
    u.resetWord = wordWindow != newWindow;
    u.keepArming = hookWanted && wordWindow == newWindow;
    return u;
}

// (2) Echo verification. `before` = text the host shows immediately before the caret
// (console buffer row up to the cursor, UIA text range); `expected` = the word Direct
// typed. Console rows are padded with spaces only AFTER the cursor, so compare exactly.
bool echoMatches(const std::u16string& before, const std::u16string& expected);

// UIA ValuePattern gives the whole field value (caret position unknown): the typed word
// must appear in it somewhere.
bool echoInValue(const std::u16string& value, const std::u16string& expected);

enum class Echo { Match, Mismatch, Unverifiable };

// Per field (window handle + control id): 2 mismatches -> composition for the rest of
// the focus. Unverifiable hosts keep Direct (never fall back blindly). A check whose
// edit was overtaken by newer keys (seq moved on) is not evidence either way.
class EchoPolicy {
public:
    static constexpr int kMismatchesToFallBack = 2;
    // Returns true when THIS result makes the field fall back.
    bool record(uintptr_t window, int control, Echo e);
    bool fellBack(uintptr_t window, int control) const;
    void focusChanged();  // new focus: counters and fallbacks start over
private:
    std::map<std::pair<uintptr_t, int>, int> mismatches_;
    std::map<std::pair<uintptr_t, int>, bool> fallen_;
};

// (1.1.5) Which app a foreground window is, for per-app rules and Việt/Anh memory. A
// console window (ConsoleWindowClass) is drawn by conhost.exe but GetWindowThreadProcessId
// reports its CLIENT (cmd.exe, powershell.exe…): the TIP runs in conhost.exe and keys
// everything by that name, so the hook and the tray must too. Lower-case in and out.
std::string hostIdentity(const std::string& windowClass, const std::string& ownerExe);
inline bool isConsoleWindowClass(const std::string& cls) { return cls == "ConsoleWindowClass"; }

// (1.1.5) Is the foreground app in Vietnamese for the hook / tray?
//   tipProp: kTipLangProp on the foreground root (0 absent, 1 Vietnamese, 2 English) —
//            authoritative when present;
//   console: without the prop a console is NOT trusted (its reported thread is cmd's);
//   else     vi-VN keyboard layout on the window's thread AND the stored per-app state.
bool foregroundLanguage(int tipProp, bool console, bool hklIsVietTelex, bool storedVietnamese);

// (1.1.5) When the hook starts typing in a window. Engaged by a foreground change: at once
// (nothing is mid-word). Engaged mid-focus (the TIP handed a field over): the TIP may be
// composing a word right now — wait for a word boundary so the two never type one word.
class HookArming {
public:
    void engaged(bool freshWindow) { armed_ = freshWindow; }
    void disengaged() { armed_ = false; }
    // Called for every user key before the hook acts; true = the hook may handle it.
    // `boundary`: space, Enter, Tab, Esc, navigation, a chord, or a mouse click.
    bool key(bool boundary) {
        if (armed_) return true;
        if (boundary) armed_ = true;
        return false;
    }
    void click() { armed_ = true; }
    // (1.3.16) A TIP handover whose word in progress the hook adopted (word_adopt.h): the
    // TIP composes nothing there, the hook types from this key on.
    void armNow() { armed_ = true; }
    bool armed() const { return armed_; }

private:
    bool armed_ = false;
};

// (1.1.5) The TIP's side of the handover, decided at each word start: stay out (the hook
// types) only when Direct is wanted here AND the hook confirmed it types in this window.
inline bool tipStaysOut(bool directWanted, bool hookAcked, bool fieldNoDirect, bool integrityOk) {
    return directWanted && hookAcked && !fieldNoDirect && integrityOk;
}

// Only verify an edit that is still the latest one when the check runs.
inline bool checkStillRelevant(uint64_t editSeqAtSend, uint64_t editSeqNow) { return editSeqAtSend == editSeqNow; }

// ---- What one Direct edit sends (terminals and AI CLIs, 1.1.x) -----------------------
// The bug class seen with other IMEs in terminals: a CLI that reads the pty (Claude Code,
// Gemini CLI, other Node/Ink apps) expects Backspace as DEL 0x7F; if the IME's "backspace"
// reaches it as BS 0x08 (a Unicode 0x08 character, or VK_BACK while Ctrl is down — Windows
// Terminal and conhost's VT input send 0x08 for Ctrl+Backspace) the app does not delete,
// and the retyped word lands after the old one: doubled characters.
// What VietTelex sends, by construction:
//   * each backspace = VK_BACK as a VIRTUAL KEY with its scan code (0x0E), down + up —
//     exactly what the physical key produces. Windows Terminal / conhost therefore
//     translate it like a real Backspace (DEL 0x7F in VT input mode); a legacy console
//     reader gets the same KEY_EVENT record a real key gives.
//   * never KEYEVENTF_UNICODE for a control character (that is how 0x08 would leak);
//   * text = KEYEVENTF_UNICODE (VK_PACKET), one down/up per UTF-16 unit;
//   * no modifier events, and the batch is only sent when no Ctrl/Alt/Win key is held
//     (injectionModifiersSafe) — otherwise VK_BACK becomes Ctrl+Backspace (0x08, or
//     "delete word" in GUI apps) / Alt+Backspace (ESC DEL = delete word in readline).
// Residual risk (documented, not fixable from here): a CLI that parses one pty read as ONE
// key would see "DEL DEL text" arriving together. For such an app set the terminal to
// "Khung soạn" (composition) on the Ứng dụng page: then only committed text is sent.
struct DirectKeyEvent {
    uint16_t vk = 0;       // virtual key (0 for Unicode events)
    uint16_t unit = 0;     // UTF-16 unit for Unicode events
    bool unicode = false;  // KEYEVENTF_UNICODE
    bool up = false;       // KEYEVENTF_KEYUP
};
constexpr uint16_t kVkBack = 0x08;
// N backspaces then `text`, as the SendInput batch HookSink builds (scan codes added there).
std::vector<DirectKeyEvent> directEditEvents(unsigned backspaces, const std::u16string& text);

// ---- Chromium address bar: the placeholder sequence (#173, macOS .emptyReset since 1.4.14) --
// The TIP hands a Chromium-family browser's native address bar (IS_URL, app_policy.h
// omniboxStepAtWordStart) to the hook, so the browser draws no composition underline. There
// inline autocomplete keeps a suggestion SELECTED after the typed text: the first Backspace
// of a plain edit only removes that suggestion, every later one lands one character short
// and the retype doubles a letter ("thế" -> "theế"). So a replace goes out as
//   U+202F (typing replaces the selected suggestion = cancels inline autocomplete),
//   Backspace x (N + 1) (the +1 removes the U+202F), the text — one SendInput batch.
// Only a real replace needs it: a plain append (0 backspaces) replaces the suggestion like
// any typed letter, and a pure deletion (no text) must not flash a stray character (macOS
// tester report 2026-07-27): plain Backspaces there.
constexpr char16_t kAutocompletePlaceholder = u' ';  // NARROW NO-BREAK SPACE
inline bool usesPlaceholderEdit(bool inlineAutocompleteField, unsigned backspaces, bool textEmpty) {
    return inlineAutocompleteField && backspaces > 0 && !textEmpty;
}
std::vector<DirectKeyEvent> directEditEvents(unsigned backspaces, const std::u16string& text,
                                             bool inlineAutocompleteField);
// The user's own Backspace in such a field: with a suggestion showing, the browser removes
// only the suggestion, not a letter — what the hook believes is on screen is unsure from
// then on. The ⌫ goes through untouched, the hook forgets the word in progress and its ⌫
// trail (hook_reopen.h); the next letters start afresh.
inline bool userBackspaceDropsWord(bool inlineAutocompleteField) { return inlineAutocompleteField; }
// One SendInput keyboard event (KEYBDINPUT without time / extra info), portable so the
// events HookSink builds are unit-tested. Flag values are the Win32 ones (checked by
// static_assert in hook_fallback.cpp).
struct KeyInjection {
    uint16_t vk = 0;
    uint16_t scan = 0;
    uint32_t flags = 0;  // KEYEVENTF_*
};
constexpr uint32_t kKeyeventfExtendedKey = 0x0001;  // KEYEVENTF_EXTENDEDKEY
constexpr uint32_t kKeyeventfKeyUp = 0x0002;        // KEYEVENTF_KEYUP
constexpr uint32_t kLlkhfExtended = 0x01;           // KBDLLHOOKSTRUCT::flags LLKHF_EXTENDED
// Down + up replaying a user key the hook swallowed (it must land after our edits), from
// its KBDLLHOOKSTRUCT: the key's own scan code and extended bit. Without the extended bit
// an arrow / Home / End / PgUp / PgDn / Ins / Del / numpad Enter / right Ctrl+Alt is
// injected as its numpad / left twin (Del becomes numpad "." with Num Lock on).
// `mappedScan` (MapVirtualKeyW) is used only when the hook reported no scan code.
std::array<KeyInjection, 2> replayKeyInjection(uint32_t vk, uint32_t scanCode, uint32_t llFlags,
                                               uint16_t mappedScan);

// ---- Java AWT hosts: Backspaces and text in separate SendInput batches (1.3.17) -------
// JetBrains IDEs (IntelliJ IDEA, PyCharm, Android Studio, Rider, WebStorm, CLion, GoLand…)
// and other Java Swing/AWT apps reach VietTelex through CUAS, so the TIP hands their
// fields to the hook (Direct). AWT turns VK_BACK into a KEY_PRESSED the editor runs as an
// ACTION, and the Unicode text (VK_PACKET -> WM_CHAR) into KEY_TYPED events inserted by
// another path on its event-dispatch thread. When both arrive in one SendInput batch the
// editor loses characters; with the text some tens of ms after the Backspaces it behaves.
// Keyed on the top-level window class (every AWT window class starts with "SunAwt":
// SunAwtFrame, SunAwtDialog…), so every JetBrains product and any Swing app is covered
// without an exe list.
bool splitsCorrection(const std::string& topLevelWindowClass);
// The pause before text that follows a key event (Backspace or a replayed user key) in
// such a host. A WM_TIMER on the hook thread: the real pause is this rounded up to the
// system tick (~15.6 ms), i.e. 50-63 ms. 50 ms is the separation reported to work.
constexpr unsigned kSplitCorrectionDelayMs = 50;
// A key pressed while text is pending that may still go straight to the app: it changes
// no text and no later Backspace (Shift, Caps Lock — the hook's replayed letters are
// already cased). Ctrl / Alt / Win, F-keys and the like must not overtake the pending
// text: the hook sends all of it at once, then that key.
inline bool keyPassesPendingSplit(uint32_t vk) {
    return vk == 0x10 || vk == 0xA0 || vk == 0xA1 || vk == 0x14;  // Shift, LShift, RShift, Caps Lock
}

// The hook's injection queue for such a host. `submit` takes one batch the hook would have
// sent in ONE SendInput and returns what goes now: everything up to the first text event
// that follows a key event. The rest waits; the caller sends `next()` after each pause.
// While anything waits, a new batch (a correction, or a key the hook would have let
// through, replayed) goes entirely behind it — a key typed during the pause never
// overtakes the pending text. Pure (T = INPUT on Windows); the caller owns the timer.
template <class T>
class SplitInjection {
public:
    using IsText = bool (*)(const T&);
    explicit SplitInjection(IsText isText) : isText_(isText) {}

    bool busy() const { return !chunks_.empty(); }
    size_t pendingChunks() const { return chunks_.size(); }

    std::vector<T> submit(const std::vector<T>& batch) {
        std::vector<std::vector<T>> parts(1);
        // What went just before this batch: the tail of what waits (else sent long ago).
        bool afterKey = busy() && !chunks_.back().empty() && !isText_(chunks_.back().back());
        for (const T& e : batch) {
            const bool text = isText_(e);
            if (text && afterKey) parts.emplace_back();  // a pause before this event
            parts.back().push_back(e);
            afterKey = !text;
        }
        std::vector<T> now;
        if (!busy()) now = std::move(parts[0]);
        else chunks_.back().insert(chunks_.back().end(), parts[0].begin(), parts[0].end());
        for (size_t i = 1; i < parts.size(); ++i) chunks_.push_back(std::move(parts[i]));
        return now;
    }
    // A pause is over: the next chunk (empty when nothing waits).
    std::vector<T> next() {
        if (chunks_.empty()) return {};
        std::vector<T> c = std::move(chunks_.front());
        chunks_.pop_front();
        return c;
    }
    // Everything that waits, in order, at once (a chord, a click: it cannot wait).
    std::vector<T> drain() {
        std::vector<T> all;
        for (std::vector<T>& c : chunks_) all.insert(all.end(), c.begin(), c.end());
        chunks_.clear();
        return all;
    }
    void clear() { chunks_.clear(); }

private:
    IsText isText_;
    std::deque<std::vector<T>> chunks_;
};

// UI Automation timeouts for the echo check (direct_verify.cpp, IUIAutomation2). The
// defaults are 20 s each: a hung target app would stall the verify worker that long, and
// a result that late is useless (the user has typed on).
constexpr unsigned long kUiaConnectionTimeoutMs = 1000;
constexpr unsigned long kUiaTransactionTimeoutMs = 2000;

// A Direct batch may only be injected while no modifier that changes Backspace is held.
inline bool injectionModifiersSafe(bool ctrlDown, bool altDown, bool winDown) {
    return !ctrlDown && !altDown && !winDown;
}

}  // namespace vtx
