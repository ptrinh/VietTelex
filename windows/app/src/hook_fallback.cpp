#include "hook_fallback.h"
#include "app.h"
#include "debug_context.h"
#include "debug_file.h"

#include <windows.h>

#include <memory>
#include <set>
#include <string>
#include <vector>

#include "app_policy.h"
#include "breaker.h"
#include "direct_policy.h"
#include "direct_verify.h"
#include "foreground.h"
#include "hook_watchdog.h"
#include "hook_reopen.h"
#include "hotkey.h"
#include "input_switch.h"
#include "keymap.h"
#include "portable.h"
#include "session.h"
#include <viettelex/vtx_engine.h>
#include "settings_store.h"
#include "setup_helper_logic.h"
#include "typed_word.h"
#include "word_adopt.h"

// Hook threading (1.1.3). The low-level hooks live on their OWN high-priority thread with
// its own message loop, so a busy UI thread (Settings window, dialogs) can never push the
// hook past LowLevelHooksTimeout — after which Windows silently removes it. A watchdog on
// the same thread compares raw input against the hook and reinstalls it if it died
// (hook_watchdog.h). The UI thread only posts commands (install/uninstall, settings,
// foreground app) to the hook thread; all typing state is owned by the hook thread.

// direct_policy.h mirrors these so replayKeyInjection is testable off Windows.
static_assert(vtx::kKeyeventfExtendedKey == KEYEVENTF_EXTENDEDKEY && vtx::kKeyeventfKeyUp == KEYEVENTF_KEYUP &&
              vtx::kLlkhfExtended == LLKHF_EXTENDED);

namespace vtx::app {

namespace {

enum : UINT {
    kCmdConfig = WM_APP + 1,   // lParam: Settings* (hook thread owns it)
    kCmdForeground,            // lParam: Foreground* (hook thread owns it)
    kCmdDisableHere,           // Direct proved unusable in the current field: stop hooking
    kCmdSuspend,               // wParam 1 = game / fullscreen: type nothing (game_mode.cpp)
    kCmdSyncHooks,             // the chord armed / disarmed: add or drop the mouse hook
    kCmdQuit,
};

// ---------------------------------------------------------------- hook-thread state
constexpr UINT_PTR kSplitTimer = 1;  // on HookState::sink: the next pending chunk (Java AWT)
bool isUnicodeInput(const INPUT& in) { return in.type == INPUT_KEYBOARD && (in.ki.dwFlags & KEYEVENTF_UNICODE); }

struct Foreground {
    FgApp app;
    std::wstring exe;
    DWORD tid = 0;
    HWND hwnd = nullptr;
    bool install = false;
    bool direct = false;  // Direct mode (verify echo) vs explicit hookFallback
    bool fresh = false;   // a foreground change (not a mid-focus re-publish)
    bool adopt = false;   // TIP handover: the word in progress reached the app as typed (1.3.16)
    bool inlineAutocomplete = false;  // TIP handover: Chromium address bar (#173)
};

struct HookState {
    Settings settings;
    TypingSession session;
    RateBreaker breaker;
    HookWatchdog watchdog;
    HHOOK kbHook = nullptr;
    HHOOK mouseHook = nullptr;
    HWND sink = nullptr;       // message-only window: raw input for the watchdog
    bool rawInput = false;     // raw input registered (only while the keyboard hook is in)
    DWORD fgThread = 0;
    HWND fgHwnd = nullptr;     // window the hooked typing belongs to
    std::wstring fgExe;        // lowercase
    bool wanted = false;       // hooks should be installed
    bool direct = false;
    FgApp app;
    HookArming arming;
    HWND ackHwnd = nullptr;    // window carrying kDirectOnProp (the TIP stays out there)
    uint64_t editSeq = 0;      // bumps on every injected edit (echo checks use the latest)
    bool suspended = false;    // game / fullscreen / Chế độ game: every key passes through
    // Observe-only Ctrl+Shift watcher (input_switch.h): keeps the keyboard hook installed
    // while the switch hotkey is Ctrl+Shift, so the chord also works while ANOTHER
    // keyboard is the window's input method. Never eats a key. The mouse hook joins only
    // while the chord is armed (hookNeeds).
    bool watchChord = false;
    ModifierChord chord;
    // ⌫ back into the word just typed (hook_reopen.h): what the hook saw typed since the
    // caret was last certain. Dropped on anything it cannot account for.
    ReopenTrail trail;
    // A TIP handover mid-word (WPF list, 1.3.16): the word the TIP let through as typed is
    // taken over at the first key instead of waiting for a boundary (word_adopt.h).
    WordAdoption adoption;
    // Java AWT window (JetBrains, Swing; direct_policy.h splitsCorrection): Backspaces and
    // the text after them go out kSplitCorrectionDelayMs apart; keys typed meanwhile queue
    // behind the pending text. Sent from the hook callback and from kSplitTimer.
    bool splitHost = false;
    SplitInjection<INPUT> split{&isUnicodeInput};
    // Chromium address bar handed over by the TIP (#173, direct_policy.h usesPlaceholderEdit):
    // replaces go out as U+202F, Backspace x (N + 1), text; the user's ⌫ drops the word.
    bool inlineAutocomplete = false;
};
HookState* h = nullptr;        // hook thread only
DWORD g_hookTid = 0;
HANDLE g_hookThread = nullptr;
HANDLE g_hookReady = nullptr;
HWND g_chordTarget = nullptr;  // main window: receives g_chordMsg when the chord completes
UINT g_chordMsg = 0;
bool g_suspendedUi = false;    // UI thread: last hookSetSuspended (replayed to a new hook thread)

// ---------------------------------------------------------------- UI-thread state
struct UiState {
    Settings settings;
    HWINEVENTHOOK fgHook = nullptr;
    bool directFromTip = false;  // TIP asked for direct mode for the current field
    bool adoptTyped = false;     // ...and its word in progress passed as typed (kDirectAdoptTyped)
    bool inlineAutocomplete = false;  // ...and the field is a Chromium address bar (#173)
    std::wstring fgExe;
    FgApp fgApp;
    DWORD fgThread = 0;
};
UiState* u = nullptr;
void (*g_elevationNotify)(const std::wstring&) = nullptr;
std::set<std::wstring> g_warnedExes;

// Collects the edits a TypingSession wants and turns them into ONE SendInput batch:
// backspaces first, then the text — SendInput inserts the whole array atomically, so a
// user key can never land between them (OpenKey batches the same way).
class HookSink final : public TextSink {
public:
    std::vector<INPUT> inputs;
    unsigned backspaces = 0, units = 0;
    bool inlineAutocomplete = false;  // Chromium address bar: the U+202F placeholder sequence
    bool blind() override { return true; }  // nothing can be read back from here
    std::u16string textBeforeCaret(int) override { return {}; }
    char16_t charAfterCaret() override { return 0; }
    bool hasSelection() override { return false; }
    bool replaceBeforeCaret(const std::u16string& expect, const std::u16string& insert) override {
        // VK_BACK as a virtual key (never a Unicode 0x08), then Unicode text: see
        // direct_policy.h directEditEvents (terminals / AI CLIs expect DEL from Backspace).
        // In a Chromium address bar a replace starts with U+202F and deletes it too (#173).
        for (const DirectKeyEvent& e : directEditEvents(static_cast<unsigned>(expect.size()), insert, inlineAutocomplete)) {
            if (e.up) continue;  // addVk / addUnicode emit down + up
            if (e.unicode) addUnicode(static_cast<char16_t>(e.unit));
            else addVk(e.vk);
        }
        backspaces += static_cast<unsigned>(expect.size());
        units += static_cast<unsigned>(insert.size());
        return true;
    }
    bool compositionActive() override { return false; }
    bool setComposition(const std::u16string&, int, bool) override { return false; }
    void endComposition(const std::u16string&) override {}
    void endCompositionAsIs() override {}

    void addVk(WORD vkey) {
        // A real key event: scan code included (console readers look at it).
        addKeys(replayKeyInjection(vkey, 0, 0, static_cast<uint16_t>(MapVirtualKeyW(vkey, MAPVK_VK_TO_VSC))));
    }
    // The user's own key, replayed after our edits: its scan code and extended bit kept,
    // or an arrow / Home / End / Del / numpad Enter would arrive as its numpad twin.
    void addUserKey(const KBDLLHOOKSTRUCT& kb) {
        addKeys(replayKeyInjection(kb.vkCode, kb.scanCode, kb.flags,
                                   static_cast<uint16_t>(MapVirtualKeyW(kb.vkCode, MAPVK_VK_TO_VSC))));
    }
    void addKeys(const std::array<KeyInjection, 2>& keys) {
        for (const KeyInjection& k : keys) {
            INPUT in = {};
            in.type = INPUT_KEYBOARD;
            in.ki.wVk = k.vk;
            in.ki.wScan = k.scan;
            in.ki.dwFlags = k.flags;
            in.ki.dwExtraInfo = kInjectedMagic;
            inputs.push_back(in);
        }
    }
    void addUnicode(char16_t c) {
        INPUT in[2] = {};
        for (int i = 0; i < 2; ++i) {
            in[i].type = INPUT_KEYBOARD;
            in[i].ki.wScan = static_cast<WORD>(c);
            in[i].ki.dwFlags = KEYEVENTF_UNICODE | (i ? KEYEVENTF_KEYUP : 0);
            in[i].ki.dwExtraInfo = kInjectedMagic;
            inputs.push_back(in[i]);
        }
    }
};

// The VietTelex keyboard is the foreground app's input method and it is in Vietnamese
// (the TIP's kTipLangProp first — the only truth for consoles; see foreground.h).
bool foregroundVietnamese() { return fgVietnamese(h->fgHwnd, h->app); }

void markNoDirect(DWORD tid, const char* why);

// Hook thread: a debug line is queued, never written inside the hook callback (a slow disk
// would hold every key; foreground.h appLogDeferred).
void hookLog(const std::string& msg) { appLogDeferred("hook", msg); }

// The caret may have moved / the text is unknown: forget the word and the ⌫ trail.
void dropWord() {
    h->session.reset();
    h->trail.invalidate();
    h->adoption.drop();
}

// The TIP's record of the word in progress on the foreground root (typed_word.h).
uint32_t typedWordOnForeground() {
    HWND root = h->fgHwnd ? GetAncestor(h->fgHwnd, GA_ROOT) : nullptr;
    return root ? static_cast<uint32_t>(reinterpret_cast<uintptr_t>(GetPropW(root, kTypedWordProp))) : 0;
}

// ---- Java AWT split corrections (direct_policy.h splitsCorrection) ---------------------
void stopSplitTimer() {
    if (h->sink) KillTimer(h->sink, kSplitTimer);
}

void verifyLatestEdit() {
    if (echoCheckedAfterEdit(h->direct, h->inlineAutocomplete) && h->session.wordActive())
        directVerifyAfterEdit(h->fgHwnd, h->fgThread, h->session.shown(), ++h->editSeq);
}

// Pending text no longer belongs where it would land (another window, the hook stopping).
void splitDrop(const char* why) {
    if (!h->split.busy()) return;
    h->split.clear();
    stopSplitTimer();
    dropWord();
    hookLog(std::string("split correction: pending text dropped, word reset (") + why + ")");
}

// One SendInput of a split chunk. Blocked / cut short: like the one-batch path, the screen
// is unknown and this field goes to composition.
SendOutcome splitSend(std::vector<INPUT>& ev) {
    if (ev.empty()) return SendOutcome::Ok;
    const UINT total = static_cast<UINT>(ev.size());
    const UINT sent = SendInput(total, ev.data(), sizeof(INPUT));
    const SendOutcome out = classifySend(sent, total);
    if (out != SendOutcome::Ok) {
        hookLog("SendInput " + std::to_string(sent) + "/" + std::to_string(total) + " events (split correction)");
        h->split.clear();
        stopSplitTimer();
        dropWord();
        markNoDirect(h->fgThread, "SendInput refused");
        PostThreadMessageW(g_hookTid, kCmdDisableHere, 0, 0);
    }
    return out;
}

// A batch the hook would send in one SendInput: what may go now goes, the rest waits for
// kSplitTimer (one chunk per tick: each tick is one pause).
SendOutcome splitSubmit(const std::vector<INPUT>& batch) {
    const bool wasBusy = h->split.busy();
    std::vector<INPUT> now = h->split.submit(batch);
    if (!wasBusy && h->split.busy()) SetTimer(h->sink, kSplitTimer, kSplitCorrectionDelayMs, nullptr);
    return splitSend(now);
}

// Everything pending at once, then `after` (the key that cannot wait: a shortcut, a click).
void splitFlush(const std::vector<INPUT>& after, const char* why) {
    std::vector<INPUT> all = h->split.drain();
    stopSplitTimer();
    if (all.empty() && after.empty()) return;
    if (!all.empty() && appLogging()) hookLog(std::string("split correction: pending text sent at once (") + why + ")");
    all.insert(all.end(), after.begin(), after.end());
    if (splitSend(all) == SendOutcome::Ok) verifyLatestEdit();
}

void splitTick() {
    if (!h->split.busy()) return stopSplitTimer();
    if (!injectionAllowed(reinterpret_cast<uintptr_t>(GetForegroundWindow()), reinterpret_cast<uintptr_t>(h->fgHwnd),
                          false))
        return splitDrop("foreground changed");
    if (!injectionModifiersSafe(GetAsyncKeyState(VK_CONTROL) < 0, GetAsyncKeyState(VK_MENU) < 0,
                                GetAsyncKeyState(VK_LWIN) < 0 || GetAsyncKeyState(VK_RWIN) < 0))
        return splitDrop("modifier held");
    std::vector<INPUT> chunk = h->split.next();
    if (!h->split.busy()) stopSplitTimer();
    if (splitSend(chunk) == SendOutcome::Ok && !h->split.busy()) verifyLatestEdit();
}

// A key the hook lets through as is. Behind pending split text it must not overtake: it
// is eaten and replayed after that text (a shortcut cannot wait: the text goes at once).
LRESULT passKey(int code, WPARAM wp, LPARAM lp, const KBDLLHOOKSTRUCT& kb, const KeyInput& k) {
    if (!h->split.busy()) return CallNextHookEx(nullptr, code, wp, lp);
    HookSink s;
    if (k.kind == KeyKind::Char) s.addUnicode(static_cast<char16_t>(k.ch));
    else s.addUserKey(kb);
    if (k.kind == KeyKind::Chord) splitFlush(s.inputs, "shortcut");
    else splitSubmit(s.inputs);
    return 1;
}

LRESULT CALLBACK keyboardProc(int code, WPARAM wp, LPARAM lp) {
    if (code != HC_ACTION || !h) return CallNextHookEx(nullptr, code, wp, lp);
    const auto* kb = reinterpret_cast<const KBDLLHOOKSTRUCT*>(lp);
    if (isOwnInjected(kb->dwExtraInfo)) return CallNextHookEx(nullptr, code, wp, lp);  // never re-process ours
    h->watchdog.lowLevelKey(GetTickCount64());
    const bool down = wp == WM_KEYDOWN || wp == WM_SYSKEYDOWN;
    if (h->watchChord && !(kb->flags & LLKHF_INJECTED)) {
        // GetAsyncKeyState is not updated for this event yet: apply it ourselves.
        if (isChordModifierVk(kb->vkCode)) {
            uint8_t before = 0;
            if (GetAsyncKeyState(VK_CONTROL) < 0) before |= kModCtrl;
            if (GetAsyncKeyState(VK_SHIFT) < 0) before |= kModShift;
            if (GetAsyncKeyState(VK_MENU) < 0) before |= kModAlt;
            if (GetAsyncKeyState(VK_LWIN) < 0 || GetAsyncKeyState(VK_RWIN) < 0) before |= kModWin;
            const bool wasArmed = h->chord.armed();
            const bool completed = h->chord.note(chordHeldAfter(before, kb->vkCode, down));
            const bool buttonHeld = completed && (GetAsyncKeyState(VK_LBUTTON) < 0 ||
                                                  GetAsyncKeyState(VK_RBUTTON) < 0 ||
                                                  GetAsyncKeyState(VK_MBUTTON) < 0);
            if (chordToggleAllowed(completed, down, h->suspended, buttonHeld) && g_chordTarget)
                PostMessageW(g_chordTarget, g_chordMsg, 0, 0);  // decided on the UI thread
            if (wasArmed != h->chord.armed()) PostThreadMessageW(g_hookTid, kCmdSyncHooks, 0, 0);
        } else if (down && h->chord.armed()) {
            h->chord.disarm();  // Ctrl+Shift+T etc. is not the switch chord
            PostThreadMessageW(g_hookTid, kCmdSyncHooks, 0, 0);
        }
    }
    if (!down) return CallNextHookEx(nullptr, code, wp, lp);
    if (!h->wanted || h->suspended) {  // watching only / game / fullscreen: typing unseen
        h->trail.invalidate();
        return CallNextHookEx(nullptr, code, wp, lp);
    }
    if (kb->flags & LLKHF_INJECTED) {  // someone else's synthetic input: do not compose over it
        splitFlush({}, "other synthetic input");
        dropWord();
        return CallNextHookEx(nullptr, code, wp, lp);
    }
    Modifiers m;
    m.shift = GetAsyncKeyState(VK_SHIFT) < 0;
    m.ctrl = GetAsyncKeyState(VK_CONTROL) < 0;
    m.alt = GetAsyncKeyState(VK_MENU) < 0;
    m.win = GetAsyncKeyState(VK_LWIN) < 0 || GetAsyncKeyState(VK_RWIN) < 0;
    m.capsLock = (GetKeyState(VK_CAPITAL) & 1) != 0;
    KeyInput k = classifyKey(kb->vkCode, m);
    if (k.kind == KeyKind::Modifier || k.kind == KeyKind::Other) {
        // Alt alone (menu bar), Win (Start, Win+Space), F-keys & co: the ⌫ trail is unsure.
        if (k.kind == KeyKind::Other || modifierDropsTrail(kb->vkCode)) h->trail.invalidate();
        // Behind pending split text: Ctrl/Alt/Win or an F-key would act before that text
        // lands (and turn its Backspaces into Ctrl+Backspace): the text goes now, the key
        // right after it. Shift / Caps Lock change nothing pending and pass.
        if (h->split.busy() && !keyPassesPendingSplit(kb->vkCode)) {
            HookSink s;
            s.addUserKey(*kb);
            splitFlush(s.inputs, "modifier / function key");
            return 1;
        }
        return CallNextHookEx(nullptr, code, wp, lp);
    }
    // Engaged mid-focus on a TIP handover whose word passed as typed (WPF list): take that
    // word over at this first key (word_adopt.h) instead of waiting for a boundary.
    if (h->adoption.pending()) {
        if (foregroundVietnamese()) {
            const WordAdoption::Start st = h->adoption.begin(typedWordOnForeground(), k, h->session);
            if (st != WordAdoption::Start::Unknown) h->arming.armNow();
            h->trail.invalidate();
            if (appLogging())
                hookLog(std::string("TIP handover: word in progress ") +
                                   (st == WordAdoption::Start::Adopted   ? (h->adoption.owes() ? "adopted (screen fixed with this key)" : "adopted")
                                    : st == WordAdoption::Start::Nothing ? "none, typing from this key"
                                                                         : "unknown, waiting for a boundary"));
        } else {
            h->adoption.drop();
        }
    }
    // Engaged mid-focus: the TIP may be composing this word — start at the next boundary.
    const bool boundary = k.kind == KeyKind::Boundary || k.kind == KeyKind::Navigation || k.kind == KeyKind::Chord ||
                          (k.kind == KeyKind::Char && k.ch == U' ');
    if (!h->arming.key(boundary) || (!h->session.wordActive() && !foregroundVietnamese())) {
        h->trail.invalidate();  // not typed by us (English, yielding, password field...)
        h->adoption.drop();
        return passKey(code, wp, lp, *kb, k);
    }
    // Chromium address bar (#173): the user's ⌫ may only remove the inline suggestion, not a
    // letter. It goes through; the hook no longer knows the word — forget it (and the trail).
    if (k.kind == KeyKind::Backspace && userBackspaceDropsWord(h->inlineAutocomplete)) {
        dropWord();
        return passKey(code, wp, lp, *kb, k);
    }
    // An adopted word whose raw letters still differ from the session's text: ⌫ deletes the
    // last raw letter (the app does it), the rest is adopted again.
    if (h->adoption.owes() && k.kind == KeyKind::Backspace) {
        h->adoption.backspace(h->session);
        return passKey(code, wp, lp, *kb, k);
    }
    switch (h->trail.before(k, h->session)) {
        case ReopenTrail::Before::Reopened:
            // ⌫ deletes the separator after the last word, which is back in the engine: the
            // app deletes it, the next keys edit the word. Nothing injected.
            if (appLogging()) hookLog("backspace: last word reopened");
            return passKey(code, wp, lp, *kb, k);
        case ReopenTrail::Before::Popped: h->session.noteKeyPassedBy(k); return passKey(code, wp, lp, *kb, k);
        case ReopenTrail::Before::Normal: break;
    }
    HookSink sink;
    sink.inlineAutocomplete = h->inlineAutocomplete;
    // Adopted word: the raw letters on screen become the session's text first, in this
    // key's batch, before the key's own edit (word_adopt.h).
    const bool fixing = h->adoption.owes();
    if (fixing) {
        const WordAdoption::Fix fix = h->adoption.takeFix();
        sink.replaceBeforeCaret(fix.expect, fix.insert);
    }
    bool eaten = false;
    if (!h->session.wantsKey(k)) {
        // Like the TIP: the session still hears a key it lets through ("=" ">" of a "=>"
        // shortcut key, boundaries for the engine's glued separators).
        h->session.noteKeyPassedBy(k);
        if (!fixing) {
            h->trail.after(k, h->session, false, false, false);
            return passKey(code, wp, lp, *kb, k);
        }
        h->trail.invalidate();
    } else {
        eaten = h->session.handleKey(k, sink);
    }
    if (sink.inputs.empty()) {
        h->trail.after(k, h->session, true, eaten, false);
        return eaten ? 1 : passKey(code, wp, lp, *kb, k);
    }
    // Edits + a key that should still reach the app: the key must come AFTER our
    // edits, so swallow it and replay it at the end of the batch.
    if (!eaten) {
        if (k.kind == KeyKind::Char) sink.addUnicode(static_cast<char16_t>(k.ch));
        else sink.addUserKey(*kb);
    }
    if (!h->breaker.allow(GetTickCount64(), static_cast<uint32_t>(sink.inputs.size()))) {
        splitDrop("rate breaker");
        dropWord();
        return CallNextHookEx(nullptr, code, wp, lp);
    }
    // Focus moved between the key and the injection: the edit belongs to another
    // window now — drop it, reset the word, let the key go.
    if (!injectionAllowed(reinterpret_cast<uintptr_t>(GetForegroundWindow()), reinterpret_cast<uintptr_t>(h->fgHwnd),
                          false)) {
        splitDrop("foreground changed");
        dropWord();
        hookLog("foreground changed before injection: edit dropped, word reset");
        return CallNextHookEx(nullptr, code, wp, lp);
    }
    // A modifier pressed since the key (or AltGr) would turn our VK_BACK into Ctrl+Backspace
    // (BS 0x08 in terminals, delete-word elsewhere) / Alt+Backspace: drop the edit instead.
    if (!injectionModifiersSafe(GetAsyncKeyState(VK_CONTROL) < 0, GetAsyncKeyState(VK_MENU) < 0,
                                GetAsyncKeyState(VK_LWIN) < 0 || GetAsyncKeyState(VK_RWIN) < 0)) {
        dropWord();
        hookLog("modifier held at injection: edit dropped, word reset");
        return CallNextHookEx(nullptr, code, wp, lp);
    }
    // Java AWT (JetBrains): the text goes kSplitCorrectionDelayMs after the Backspaces, and
    // behind anything still pending (splitSubmit). Failure handling is splitSend's.
    if (h->splitHost) {
        const SendOutcome out = splitSubmit(sink.inputs);
        if (appLogging())
            hookLog(std::string("split correction: ") + std::to_string(sink.backspaces) + " backspaces, " +
                               std::to_string(sink.units) + " units, " + std::to_string(h->split.pendingChunks()) +
                               " chunk(s) waiting, key class " + std::to_string(static_cast<int>(k.kind)));
        if (out != SendOutcome::Ok) return out == SendOutcome::NothingSent ? CallNextHookEx(nullptr, code, wp, lp) : 1;
        h->trail.after(k, h->session, true, eaten, true);
        if (!h->split.busy()) verifyLatestEdit();  // else when the last chunk is out
        return 1;
    }
    const UINT total = static_cast<UINT>(sink.inputs.size());
    const UINT sent = SendInput(total, sink.inputs.data(), sizeof(INPUT));
    const SendOutcome out = classifySend(sent, total);
    if (appLogging())
        hookLog("SendInput " + std::to_string(sent) + "/" + std::to_string(total) + " events (" +
                           std::to_string(sink.backspaces) + " backspaces, " + std::to_string(sink.units) +
                           " units) key class " + std::to_string(static_cast<int>(k.kind)));
    if (out != SendOutcome::Ok) {
        // Blocked (UIPI, secure input) or cut short: the screen is unknown. This field
        // goes to composition (TIP) for the rest of the focus.
        dropWord();
        markNoDirect(h->fgThread, "SendInput refused");
        PostThreadMessageW(g_hookTid, kCmdDisableHere, 0, 0);
        return out == SendOutcome::NothingSent ? CallNextHookEx(nullptr, code, wp, lp) : 1;
    }
    h->trail.after(k, h->session, true, eaten, true);
    if (echoCheckedAfterEdit(h->direct, h->inlineAutocomplete) && h->session.wordActive())
        directVerifyAfterEdit(h->fgHwnd, h->fgThread, h->session.shown(), ++h->editSeq);
    return 1;
}

LRESULT CALLBACK mouseProc(int code, WPARAM wp, LPARAM lp) {
    if (code == HC_ACTION && h && (wp == WM_LBUTTONDOWN || wp == WM_RBUTTONDOWN || wp == WM_MBUTTONDOWN)) {
        if (h->chord.armed()) {
            h->chord.disarm();  // a click between press and release is not a toggle
            PostThreadMessageW(g_hookTid, kCmdSyncHooks, 0, 0);  // watcher only: drop this hook
        }
        // Pending split text (JetBrains) goes now — best effort: it lands after this click.
        splitFlush({}, "click");
        dropWord();  // caret probably moved
        h->arming.click();
    }
    return CallNextHookEx(nullptr, code, wp, lp);
}

// Marks the focused field of `tid` NoDirect (the TIP composes there) and logs it.
void markNoDirect(DWORD tid, const char* why) {
    GUITHREADINFO gi = {};
    gi.cbSize = sizeof gi;
    HWND field = (tid && GetGUIThreadInfo(tid, &gi)) ? gi.hwndFocus : nullptr;
    if (!field) field = h ? h->fgHwnd : nullptr;
    if (field) SetPropW(field, kNoDirectProp, reinterpret_cast<HANDLE>(1));
    if (h && h->fgHwnd && field != h->fgHwnd) SetPropW(h->fgHwnd, kNoDirectProp, reinterpret_cast<HANDLE>(1));
    appLogDeferred("direct", std::string("direct mode -> composition for this field: ") + why);
}

// kDirectOnProp: the TIP stays out of a window only while this is set (handover ack).
void setAck(HWND w) {
    if (h->ackHwnd == w) return;
    if (h->ackHwnd) RemovePropW(h->ackHwnd, kDirectOnProp);
    h->ackHwnd = w;
    // Value = our main window: the TIP ignores the ack once this app is gone (killed: no
    // cleanup), instead of leaving the field to nobody (app_policy.h propFromLiveApp).
    if (w) SetPropW(w, kDirectOnProp, reinterpret_cast<HANDLE>(g_mainWnd));
}

// Raw input (RIDEV_INPUTSINK: every key system-wide) only feeds the hook watchdog, so it
// is registered exactly while the keyboard hook is installed.
void setRawInput(bool on) {
    if (on == h->rawInput || (on && !h->sink)) return;
    RAWINPUTDEVICE rid = {};
    rid.usUsagePage = 0x01;  // generic desktop
    rid.usUsage = 0x06;      // keyboard
    rid.dwFlags = on ? RIDEV_INPUTSINK : RIDEV_REMOVE;
    rid.hwndTarget = on ? h->sink : nullptr;  // RIDEV_REMOVE requires a null target
    if (RegisterRawInputDevices(&rid, 1, sizeof rid) || !on) h->rawInput = on;
}

void removeHooks() {
    if (h->kbHook) UnhookWindowsHookEx(h->kbHook);
    if (h->mouseHook) UnhookWindowsHookEx(h->mouseHook);
    h->kbHook = h->mouseHook = nullptr;
    setRawInput(false);
}

HookNeeds needs() { return hookNeeds(h->wanted, h->watchChord, h->chord.armed(), h->suspended); }
// Keyboard hook: typing (h->wanted) or the chord watcher, never while suspended.
bool hooksNeeded() { return needs().keyboard; }

void syncHooks() {
    const HookNeeds n = needs();
    HINSTANCE inst = GetModuleHandleW(nullptr);
    if (n.keyboard && !h->kbHook) {
        h->kbHook = SetWindowsHookExW(WH_KEYBOARD_LL, keyboardProc, inst, 0);
        h->watchdog.hookInstalled(GetTickCount64());
    } else if (!n.keyboard && h->kbHook) {
        UnhookWindowsHookEx(h->kbHook);
        h->kbHook = nullptr;
    }
    if (n.mouse && !h->mouseHook) {
        h->mouseHook = SetWindowsHookExW(WH_MOUSE_LL, mouseProc, inst, 0);
    } else if (!n.mouse && h->mouseHook) {
        UnhookWindowsHookEx(h->mouseHook);
        h->mouseHook = nullptr;
    }
    setRawInput(h->kbHook != nullptr);
    if (n.keyboard != h->watchdog.active()) h->watchdog.setActive(n.keyboard, GetTickCount64());
}

// The watchdog saw Windows drop the keyboard hook (LowLevelHooksTimeout): reinstall.
void reinstallHooks() {
    h->trail.invalidate();  // keys typed while the hook was gone were not seen
    removeHooks();
    syncHooks();
    h->watchdog.hookInstalled(GetTickCount64());
}

void applyWanted(bool on) {
    h->trail.invalidate();
    if (on == h->wanted && (!hooksNeeded() || h->kbHook)) return;
    h->wanted = on;
    syncHooks();
    h->session.resetContext();
}

void configureSession(const Settings& s) {
    h->settings = s;
    SessionOptions o;
    // "Tự sửa từ phía trước" needs to read the text back (never blind): off here.
    o.engineFlags = s.engineFlags() & ~static_cast<uint32_t>(VTX_RETRO_ENGLISH);
    o.autoRestore = s.autoRestore;
    // Re-edit / re-open by reading the text back: impossible from here. "Sửa dấu từ đã gõ"
    // works by ⌫ only, from the hook's own trail (hook_reopen.h).
    o.reEditWord = false;
    o.shortcuts = &h->settings.shortcuts;
    h->session.configure(o);
    h->trail.setEnabled(s.reEditWord);
    h->trail.invalidate();
    h->session.setOutputMode(OutputMode::InPlace);
    const bool watch = chordWatcherWanted(parseSwitchHotkey(s.switchHotkey));
    if (watch != h->watchChord) {
        h->watchChord = watch;
        h->chord.disarm();
        syncHooks();
        hookLog(watch ? "Ctrl+Shift watcher on (switches to VietTelex from another keyboard)"
                             : "Ctrl+Shift watcher off");
    }
}

LRESULT CALLBACK sinkProc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp) {
    if (msg == WM_TIMER && wp == kSplitTimer) {
        if (h) splitTick();
        return 0;
    }
    if (msg == WM_INPUT && h && hooksNeeded()) {
        RAWINPUT ri;
        UINT sz = sizeof ri;
        if (GetRawInputData(reinterpret_cast<HRAWINPUT>(lp), RID_INPUT, &ri, &sz, sizeof(RAWINPUTHEADER)) != UINT(-1) &&
            ri.header.dwType == RIM_TYPEKEYBOARD && !(ri.data.keyboard.Flags & RI_KEY_BREAK)) {
            // Raw input sees every key; if the LL hook has not for a while, Windows removed it.
            if (h->watchdog.rawKey(GetTickCount64())) reinstallHooks();
        }
    }
    return DefWindowProcW(hwnd, msg, wp, lp);
}

DWORD WINAPI hookThreadMain(void*) {
    SetThreadPriority(GetCurrentThread(), THREAD_PRIORITY_HIGHEST);
    h = new HookState();
    WNDCLASSW wc = {};
    wc.lpfnWndProc = sinkProc;
    wc.hInstance = GetModuleHandleW(nullptr);
    wc.lpszClassName = L"VietTelexHookSink";
    RegisterClassW(&wc);
    // Raw input is registered by syncHooks, only while a keyboard hook is installed.
    h->sink = CreateWindowExW(0, wc.lpszClassName, L"", 0, 0, 0, 0, 0, HWND_MESSAGE, nullptr, wc.hInstance, nullptr);
    MSG msg;
    PeekMessageW(&msg, nullptr, WM_USER, WM_USER, PM_NOREMOVE);  // create the queue
    SetEvent(g_hookReady);
    while (GetMessageW(&msg, nullptr, 0, 0) > 0) {
        if (msg.hwnd == nullptr) {
            switch (msg.message) {
                case kCmdConfig: {
                    std::unique_ptr<Settings> s(reinterpret_cast<Settings*>(msg.lParam));
                    configureSession(*s);
                    break;
                }
                case kCmdForeground: {
                    std::unique_ptr<Foreground> f(reinterpret_cast<Foreground*>(msg.lParam));
                    const ForegroundUpdate up = foregroundUpdate(reinterpret_cast<uintptr_t>(h->fgHwnd), h->wanted,
                                                                 reinterpret_cast<uintptr_t>(f->hwnd));
                    const bool wasEngaged = up.keepArming;
                    if (!f->install || up.resetWord) splitDrop("foreground changed");
                    if (up.resetWord) {
                        // Another window: the word in progress is the old window's
                        // (applyWanted resets nothing while the hook stays installed).
                        dropWord();
                        h->session.resetContext();
                    }
                    h->splitHost = f->install && splitsCorrection(f->app.windowClass);
                    h->fgExe = f->exe;
                    h->app = f->app;
                    h->fgThread = f->tid;
                    h->fgHwnd = f->hwnd;
                    h->direct = f->direct;
                    applyWanted(f->install);
                    const bool typing = f->install && f->direct;
                    const bool inlineAc = typing && f->inlineAutocomplete;
                    if (inlineAc != h->inlineAutocomplete)
                        hookLog(inlineAc ? "address bar (inline autocomplete): replaces as U+202F + backspaces + text"
                                         : "address bar mode off");
                    h->inlineAutocomplete = inlineAc;
                    HWND root = f->hwnd ? GetAncestor(f->hwnd, GA_ROOT) : nullptr;
                    setAck(typing ? root : nullptr);
                    if (!f->install) {
                        h->arming.disengaged();
                        h->adoption.drop();
                    } else if (!wasEngaged) {  // same window: keep state
                        h->arming.engaged(f->fresh);
                        h->adoption.engaged(!f->fresh && f->adopt);
                    }
                    break;
                }
                case kCmdDisableHere:
                    splitDrop("Direct stopped here");
                    h->trail.invalidate();
                    applyWanted(false);
                    setAck(nullptr);
                    h->arming.disengaged();
                    h->adoption.drop();
                    h->inlineAutocomplete = false;
                    hookLog("stopped for this field (Direct fell back to composition)");
                    break;
                case kCmdSuspend: {
                    const bool on = msg.wParam != 0;
                    if (on == h->suspended) break;
                    if (on) splitDrop("suspended");
                    h->suspended = on;
                    h->trail.invalidate();
                    h->chord.disarm();
                    h->session.resetContext();
                    h->adoption.drop();
                    // Unhooked while suspended (nothing to type, the chord is ignored). A
                    // resume mid-word: typing starts at the next boundary.
                    syncHooks();
                    if (!on && h->wanted) h->arming.engaged(false);
                    hookLog(h->suspended ? "suspended (game / fullscreen): hooks removed" : "resumed");
                    break;
                }
                case kCmdSyncHooks: syncHooks(); break;
                case kCmdQuit: PostQuitMessage(0); break;
                default: break;
            }
            continue;
        }
        DispatchMessageW(&msg);
    }
    removeHooks();
    setAck(nullptr);
    if (h->sink) DestroyWindow(h->sink);
    delete h;
    h = nullptr;
    return 0;
}

// The hook thread starts the first time something needs a hook (the Ctrl+Shift watcher,
// a hook / Direct app in the foreground) and then stays. A new thread gets the current
// settings and suspend state first; foreground updates follow in order.
void ensureHookThread() {
    if (g_hookThread) return;
    g_hookReady = CreateEventW(nullptr, TRUE, FALSE, nullptr);
    g_hookThread = CreateThread(nullptr, 0, hookThreadMain, nullptr, 0, &g_hookTid);
    if (g_hookThread && g_hookReady) WaitForSingleObject(g_hookReady, 2000);
    if (!g_hookThread) return;
    if (u) {
        auto* s = new Settings(u->settings);
        if (!PostThreadMessageW(g_hookTid, kCmdConfig, 0, reinterpret_cast<LPARAM>(s))) delete s;
    }
    if (g_suspendedUi) PostThreadMessageW(g_hookTid, kCmdSuspend, 1, 0);
}

// ---------------------------------------------------------------- UI thread
// Mandatory integrity RID of a process (0x2000 medium, 0x3000 high). False = unreadable.
bool integrityOf(HANDLE process, DWORD& rid) {
    HANDLE tok = nullptr;
    if (!OpenProcessToken(process, TOKEN_QUERY, &tok)) return false;
    BYTE buf[128];
    DWORD len = 0;
    bool ok = GetTokenInformation(tok, TokenIntegrityLevel, buf, sizeof buf, &len);
    if (ok) {
        auto* til = reinterpret_cast<TOKEN_MANDATORY_LABEL*>(buf);
        rid = *GetSidSubAuthority(til->Label.Sid, *GetSidSubAuthorityCount(til->Label.Sid) - 1);
    }
    CloseHandle(tok);
    return ok;
}

bool processIntegrity(DWORD pid, DWORD& rid) {
    bool known = false;
    if (HANDLE p = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid)) {
        known = integrityOf(p, rid);
        CloseHandle(p);
    }
    return known;
}

// Portable build (core/portable.h): no TIP behind the hook, so the hook types in EVERY app
// except "Luôn tiếng Anh" apps and password boxes, and stays out wherever the installed
// VietTelex keyboard (or another Vietnamese keyboard) is active. fgVietnamese re-checks the
// yield and the password box at each word start (Win+Space / Tab within one window).
void publishForegroundPortable(bool fresh) {
    const AppMode mode = resolveAppMode(narrow(u->fgExe), u->settings.appModes);
    HWND fg = GetForegroundWindow();
    DWORD pid = 0, fgRid = 0, ourRid = 0x2000;
    if (fg) GetWindowThreadProcessId(fg, &pid);
    const bool known = processIntegrity(pid, fgRid);
    integrityOf(GetCurrentProcess(), ourRid);
    const bool yieldHere = portable::yields(fgTipProp(fg), fgLangId(u->fgApp));
    const bool password = focusedPasswordField(u->fgThread);
    const portable::HookPlan plan = portable::hookPlan(mode, password, yieldHere);
    bool hookOn = plan.install;
    const char* why = hookOn ? "portable" : yieldHere ? "Vietnamese keyboard active (yield)"
                                          : password  ? "password field"
                                                      : "always English";
    if (hookOn && !directUsable(known, fgRid, ourRid)) {
        hookOn = false;
        why = known ? "target integrity higher (UIPI)" : "target integrity unreadable";
        if (g_elevationNotify && !u->fgExe.empty() && !g_warnedExes.count(u->fgExe)) {
            g_warnedExes.insert(u->fgExe);
            g_elevationNotify(u->fgExe);
        }
    }
    if (appLogging())
        appLog("hook", "portable foreground " + narrowAscii(u->fgExe) + " class " + u->fgApp.windowClass + " -> " +
                           (hookOn ? "hook" : "no hook") + " (" + why + ")" + (fresh ? "" : " [mid-focus]"));
    if (!hookOn && !g_hookThread) return;
    ensureHookThread();
    auto* f = new Foreground{u->fgApp, u->fgExe, u->fgThread, fg, hookOn, plan.direct, fresh};
    if (!PostThreadMessageW(g_hookTid, kCmdForeground, 0, reinterpret_cast<LPARAM>(f))) delete f;
}

void publishForeground(bool fresh) {
    if (portableMode()) return publishForegroundPortable(fresh);
    const AppMode mode = resolveAppMode(narrow(u->fgExe), u->settings.appModes);
    HWND fg = GetForegroundWindow();
    DWORD pid = 0, fgRid = 0, ourRid = 0x2000;
    if (fg) GetWindowThreadProcessId(fg, &pid);
    const bool known = processIntegrity(pid, fgRid);
    integrityOf(GetCurrentProcess(), ourRid);
    const bool direct = mode == AppMode::Direct || u->directFromTip;
    bool hookOn = mode == AppMode::HookFallback || direct;
    const char* why = hookOn ? "rule/handover" : "no hook rule";
    // A field already marked NoDirect keeps composing. A console's reported thread is
    // cmd's (no GUI info): check the window itself too.
    GUITHREADINFO gi = {};
    gi.cbSize = sizeof gi;
    HWND field = (u->fgThread && GetGUIThreadInfo(u->fgThread, &gi) && gi.hwndFocus) ? gi.hwndFocus : fg;
    if (direct && ((field && GetPropW(field, kNoDirectProp)) || (fg && GetPropW(fg, kNoDirectProp)))) {
        hookOn = false;
        why = "field marked NoDirect";
    }
    // UIPI: SendInput cannot reach a higher-integrity app. Direct simply does not run
    // there — the TIP (in-process) composes instead. Explicit hookFallback apps get the
    // one-time notice, since nothing else types for them.
    if (hookOn && !directUsable(known, fgRid, ourRid)) {
        hookOn = false;
        why = known ? "target integrity higher (UIPI)" : "target integrity unreadable";
        if (!direct && g_elevationNotify && !u->fgExe.empty() && !g_warnedExes.count(u->fgExe)) {
            g_warnedExes.insert(u->fgExe);
            g_elevationNotify(u->fgExe);
        }
    }
    if (appLogging()) {
        char rid[48];
        wsprintfA(rid, " integrity 0x%lx/0x%lx", fgRid, ourRid);
        appLog("hook", "foreground " + narrowAscii(u->fgExe) + " class " + u->fgApp.windowClass + " rule " +
                           std::to_string(static_cast<int>(mode)) + (u->directFromTip ? " +tip-handover" : "") +
                           (u->directFromTip && u->inlineAutocomplete ? " (address bar)" : "") +
                           " -> " + (hookOn ? (direct ? "DIRECT (hook types)" : "hookFallback") : "no hook") + " (" +
                           why + ")" + rid + (fresh ? "" : " [mid-focus]"));
    }
    directVerifyFocusChanged();
    if (!hookOn && !g_hookThread) return;  // nothing to hook, and no hook thread to tell
    ensureHookThread();
    auto* f = new Foreground{u->fgApp, u->fgExe, u->fgThread, fg,          hookOn,
                             direct,   fresh,    u->adoptTyped, u->directFromTip && u->inlineAutocomplete};
    if (!PostThreadMessageW(g_hookTid, kCmdForeground, 0, reinterpret_cast<LPARAM>(f))) delete f;
}

void onForeground(HWND hwnd) {
    if (!u || !hwnd) return;
    u->fgApp = describeWindow(hwnd);
    u->fgExe = u->fgApp.identity;
    u->fgThread = u->fgApp.tid;
    u->directFromTip = false;  // a new window: the TIP re-evaluates its field
    u->adoptTyped = false;
    u->inlineAutocomplete = false;
    publishForeground(true);
}

void CALLBACK winEventProc(HWINEVENTHOOK, DWORD event, HWND hwnd, LONG idObject, LONG, DWORD, DWORD) {
    if (event == EVENT_SYSTEM_FOREGROUND && idObject == OBJID_WINDOW) onForeground(hwnd);
}

}  // namespace

void hookConfigure(const Settings& s) {
    if (!u) u = new UiState();
    u->settings = s;
    debugContextApply(s);  // appSetLogging + the debug-log header
    if (g_hookThread) {
        auto* copy = new Settings(s);
        if (!PostThreadMessageW(g_hookTid, kCmdConfig, 0, reinterpret_cast<LPARAM>(copy))) delete copy;
    } else if (chordWatcherWanted(parseSwitchHotkey(s.switchHotkey))) {
        ensureHookThread();  // posts these settings
    }
    // Always watch the foreground: built-in Direct rules (consoles, terminals) exist.
    // Portable: our own windows too (the welcome's try box, Settings' fields) — there is no
    // TIP to type in them.
    if (!u->fgHook)
        u->fgHook = SetWinEventHook(EVENT_SYSTEM_FOREGROUND, EVENT_SYSTEM_FOREGROUND, nullptr, winEventProc, 0, 0,
                                    WINEVENT_OUTOFCONTEXT | (portableMode() ? 0 : WINEVENT_SKIPOWNPROCESS));
    onForeground(GetForegroundWindow());
}

void hookSetDirectFromTip(bool on, bool adoptTyped, bool inlineAutocomplete) {
    if (!u || u->directFromTip == on) return;
    u->directFromTip = on;
    u->adoptTyped = on && adoptTyped;
    u->inlineAutocomplete = on && inlineAutocomplete;
    appLog("hook", std::string("TIP handover: direct ") + (on ? "requested" : "released") +
                       (u->adoptTyped ? " (word in progress passed as typed)" : "") +
                       (u->inlineAutocomplete ? " (address bar)" : ""));
    publishForeground(false);
}

void hookSetElevationNotifier(void (*notify)(const std::wstring& exe)) { g_elevationNotify = notify; }

void hookSetChordTarget(HWND wnd, UINT msg) {
    g_chordTarget = wnd;
    g_chordMsg = msg;
}

void hookDisableCurrentField() {
    if (g_hookTid) PostThreadMessageW(g_hookTid, kCmdDisableHere, 0, 0);
}

void hookSetSuspended(bool on) {
    g_suspendedUi = on;
    if (g_hookThread) PostThreadMessageW(g_hookTid, kCmdSuspend, on ? 1 : 0, 0);
}

void hookShutdown() {
    directVerifyShutdown();
    if (u && u->fgHook) UnhookWinEvent(u->fgHook);
    if (g_hookThread) {
        PostThreadMessageW(g_hookTid, kCmdQuit, 0, 0);
        WaitForSingleObject(g_hookThread, 2000);
        CloseHandle(g_hookThread);
        g_hookThread = nullptr;
    }
    appLogDrain();  // the hook thread's queued lines (debugFileFlush below them at exit)
    if (appLogging()) debugFileFlush();
    if (g_hookReady) CloseHandle(g_hookReady);
    g_hookReady = nullptr;
    delete u;
    u = nullptr;
}

}  // namespace vtx::app
