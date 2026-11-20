// app_policy.h — per-application typing mode (spec §5.1), equivalent of macOS
// manualAppModes + the shipped typing-modes table.
//
//   InPlace      (default since 1.0.9) no composition; verified edits of the text
//                before the caret. Per field it falls back to composition when that text
//                cannot be read or does not verify.
//   Composition  TSF composition with an invisible display attribute (per-app choice).
//   HookFallback the TIP stays out of the way; VietTelex.exe's low-level keyboard
//                hook types for this app while it is in the foreground.
//   Off          always English (games, remote-desktop clients).
#pragma once
#include <cstdint>
#include <map>
#include <string>

namespace vtx {

//   Direct       (1.1.3) no underline where TSF cannot edit in place (consoles, IMM/CUAS
//                apps, xterm.js): like UniKey/OpenKey, VietTelex.exe's low-level hook
//                eats the key and sends N backspaces + Unicode text in one SendInput
//                batch; the engine tracks the word itself. Needs VietTelex.exe running —
//                otherwise the TIP composes.
enum class AppMode : uint8_t { Composition = 0, InPlace = 1, HookFallback = 2, Off = 3, Direct = 4 };
// Keys typed by the hook itself carry this in dwExtraInfo; nobody (hook, TIP) may
// process them again.
constexpr uintptr_t kInjectedMagic = 0x56545831;  // "VTX1"
inline bool isOwnInjected(uintptr_t extraInfo) { return extraInfo == kInjectedMagic; }
// Window property VietTelex.exe sets on a field where Direct mode proved unusable
// (echo mismatches, SendInput refused): the TIP composes there instead (1.1.4).
constexpr const wchar_t* kNoDirectProp = L"VietTelex.NoDirect";
// (1.1.5) Set by VietTelex.exe's hook thread on the foreground top-level window while it
// types there in Direct mode. The TIP stays out of a field ONLY when this is present —
// never on the strength of a rule or a request alone (the handover race left words raw).
constexpr const wchar_t* kDirectOnProp = L"VietTelex.DirectOn";
// (1.1.5) Set by the TIP on its focus root window: 1 = active + Vietnamese, 2 = active +
// English; removed on deactivation. The hook and the tray read it — a console window's
// GetWindowThreadProcessId names the CLIENT (cmd.exe) thread, whose keyboard layout says
// nothing about conhost's input method.
constexpr const wchar_t* kTipLangProp = L"VietTelex.Lang";
// (2026-11) kDirectOnProp and kSuspendProp (game_ipc.h) sit on OTHER processes' windows and
// are removed only by a clean exit of VietTelex.exe. Their value is the app's main window
// (kAppWindowClass), and the TIP honours one only while that is the live app window: after
// the app was killed, a stale DirectOn would leave a field to nobody and a stale Suspend
// would pass every key there. Compared on 32 bits: a WOW64 (x86) TIP reads a 64-bit app's
// value truncated, and HWNDs fit in 32 bits.
inline bool propFromLiveApp(uintptr_t propValue, uintptr_t liveAppWindow) {
    return static_cast<uint32_t>(liveAppWindow) != 0 &&
           static_cast<uint32_t>(propValue) == static_cast<uint32_t>(liveAppWindow);
}
// The hook (not the TIP) types for this mode.
inline bool hookTypes(AppMode m) { return m == AppMode::HookFallback || m == AppMode::Direct; }

const char* appModeName(AppMode m);
bool parseAppMode(const std::string& s, AppMode& out);

// "C:\\Program Files\\App\\Foo.EXE" -> "foo.exe" (ASCII lowercase; non-ASCII kept).
std::string normalizeExeName(const std::string& pathOrName);

// Which app a TSF context belongs to. Inside msedgewebview2.exe (new Teams, new Outlook,
// many WebView2 apps) the process says nothing: use the exe owning the root window.
// Both arguments normalized; `rootOwnerExe` may be empty (unknown).
std::string appIdentity(const std::string& processExe, const std::string& rootOwnerExe);

// Built-in default for `exe` (normalized), or false when the table has no entry.
bool builtInAppMode(const std::string& exe, AppMode& out);

// User override first, then built-in table, then InPlace (explicit per-app choices —
// including "composition" picked before 1.0.9 — are kept as they are).
AppMode resolveAppMode(const std::string& exe, const std::map<std::string, AppMode>& overrides);

// What a text CONTEXT allows, decided per focused field at each word start.
//   TF_SS_TRANSITORY alone means NOTHING about readability: Chromium's TSF store
//   (Chrome, Edge, Brave, Electron, WebView2) always reports TRANSITORY|NOHIDDENTEXT and
//   is fully readable (1.1.1 regression). Mozc's rule (tip_transitory_extension.cc):
//     not transitory                      -> full context
//     transitory + TRANSITORYEXTENSION    -> use the PARENT context if it is not transitory
//       parent (classic Edit / RichEdit)     (full), else none
//     transitory + CUAS-emulated          -> legacy IMM32 app: no surrounding text
//       (compartment {A94C5FD2-...} & 1)
//     transitory, otherwise               -> TSF app that says transitory: full (Chromium)
struct ContextInfo {
    bool hasContext = true;       // a focused document/context exists
    bool keyboardDisabled = false;// GUID_COMPARTMENT_KEYBOARD_DISABLED / EMPTYCONTEXT set
    bool readOnly = false;        // TF_SD_READONLY
    bool console = false;         // TIP activated with TF_TMAE_CONSOLE
    bool transitory = false;      // TF_SS_TRANSITORY on this context
    bool cuasEmulated = false;    // IMM32 app through CUAS (focused field not Edit/RichEdit)
    bool hasParent = false;       // GUID_COMPARTMENT_TRANSITORYEXTENSION_PARENT document
    bool parentTransitory = true; // that parent's context status
    bool unicodeWindow = true;    // IsWindowUnicode(focus); ANSI windows mangle Unicode
    bool editControl = true;      // focus window is an Edit / RichEdit (isEditControlClass)
    bool wpf = false;             // focus window is a WPF HwndSource (isWpfWindowClass)
};

enum class HostText : uint8_t {
    Normal,           // app policy decides (in-place by default, verified)
    NormalViaParent,  // read / edit through the transitory-extension parent context
    CompositionOnly,  // no usable surrounding text: compose, never read back
    Literal,          // keys pass through untouched (read-only, disabled, ANSI window)
    Ignore,           // no context at all: do not eat keys
};
HostText classifyContext(const ContextInfo& c);

// Focus window is a classic Edit / RichEdit control or a superclass of one (WinForms
// "WindowsForms10.EDIT…", "RichEdit20W", "RICHEDIT50W", Delphi "TEdit" / "TMemo"…):
// `realClass` = RealGetWindowClassW (the system class a superclass derives from),
// `className` = GetClassNameW. Case-insensitive "edit" / "memo" in either.
bool isEditControlClass(const std::u16string& realClass, const std::u16string& className);

// Focus window is a WPF window (an HwndSource: class "HwndWrapper[<app>;<…>;<guid>]").
// WPF hosts all of its elements in that one window; a Win32 control hosted inside it
// (HwndHost: a WinForms / Edit child) has its own window and class.
bool isWpfWindowClass(const std::u16string& className);

// WPF feeds keys to TSF itself (TextServicesManager): a key the TIP claims in OnTestKeyDown
// is marked Key.ImeProcessed and, when OnKeyDown then lets it through, WPF marks its KeyDown
// handled — the message is never translated, no TextInput: the TextBox never gets it.
// In-place typing lets the first letter of every word (and the Space / "@" / "." / Enter
// ending it) through, so in a WPF TextBox nearly every key was lost (One Commander field
// report, 1.3.14: an e-mail address, a folder rename). True for a WPF element's OWN text
// store (not transitory: TextBox, RichTextBox, PasswordBox…): compose from the first key
// and never let a claimed key through — the boundary goes out with the word, other keys
// are retyped (session.h setHostDropsPassedKeys, the #134 path). A transitory-extension
// parent (a WPF list on WPF's default store) keeps the passedKeysReachApp rule.
bool wpfOwnsClaimedKeys(const ContextInfo& c, HostText host);

// WPF's default text store (1.3.16): a WPF window whose focused element has no text of its
// own (a file list with type-to-filter, One Commander) — WPF keeps a transitory context with
// a non-transitory transitory-extension parent there (NormalViaParent, no Edit). The app
// takes the keys as text input; the store never shows them, and a composition there types
// nothing. The TIP latches "not a text field" at the FIRST word start (session.h
// markNotTextField: keys pass as typed) and asks the hook (Direct: backspaces + Unicode,
// which the list does take) — instead of losing two words to the empty-store evidence.
bool wpfDefaultStore(const ContextInfo& c, HostText host);

// (1.3.16) Does a Direct handover survive a TSF focus change (ITfThreadMgrEventSink::
// OnSetFocus)? WPF hosts every element in one HwndSource and moves TSF focus between its
// own documents inside it (the filter bar appearing, a list refresh): the handover asked
// for that window stays. Released when the focus window changes, when the window is no
// longer the foreground one, or when the handover was not asked for a WPF window — a
// Chromium / Electron window (VS Code: xterm.js terminal and the editor share one HWND)
// must re-evaluate its next field, where the hook's blind retype would lose letters.
// Window handles as integers; 0 = none.
bool directSurvivesFocusChange(uintptr_t requestedFocus, bool requestedInWpf, uintptr_t newFocus,
                               bool newFocusInForeground);

// One debug-log line describing a classified context (1.3.16, once per focus change):
// "context: transitory 1 hasParent 1 parentTransitory 0 editControl 0 wpf 1 cuasEmulated 0
// host 1 class HwndWrapper[...]". Non-ASCII class characters are written as '?'.
std::string describeContext(const ContextInfo& c, HostText host, const std::u16string& focusClass);

// Does a key the TIP claims (OnTestKeyDown) and then lets through still reach the app in
// this context? Decides what "the store shows none of the letters let through" means
// (session.h setPassedKeysReachApp):
//   Normal, not transitory      a TSF-native app's own store (Word, Firefox): the app
//                               always gets an uneaten key -> the store is not the focused
//                               element's text. Not WPF (wpfOwnsClaimedKeys): there a
//                               claimed key let through is lost.
//   NormalViaParent, no Edit    a transitory-extension parent that is not a classic Edit's
//                               mirror (WPF's default text store keeps that extension) -> same.
//   everything else             IMM32 hosts through CUAS (transitory): the claimed key may
//                               have become VK_PROCESSKEY and be gone (#134) -> compose.
bool passedKeysReachApp(const ContextInfo& c, HostText host);

// Can VietTelex.exe's hook (SendInput) type into THIS process? UIPI drops input from a
// LOWER-integrity sender, so not when this process runs above the app (an app started
// "as administrator": MISA SME, #134), nor when the app's integrity cannot be read.
// Integrity = mandatory-label RID (0x1000 low, 0x2000 medium, 0x3000 high, 0x4000 system).
// The TIP itself runs inside the process, so it is never blocked: there it composes.
inline bool hookReachesThisProcess(bool appIntegrityKnown, uint32_t appIntegrity, uint32_t ownIntegrity) {
    return appIntegrityKnown && ownIntegrity <= appIntegrity;
}

// Input-scope policy (spec §4.2). Values are InputScope enum numbers from InputScope.h.
enum class FieldPolicy : uint8_t { Normal, Literal };
FieldPolicy classifyInputScopes(const int* scopes, size_t count);

// Chromium's NATIVE address bar (views::Textfield / OmniboxViewViews) cannot take an
// in-place replace while inline autocomplete shows (2026-10 field report, Edge: "thế" ->
// "theêz"). The suggestion is selected REVERSED — OnInlineAutocompleteTextMaybeChanged
// selects {text end, user text end} — and TSFTextStore commits our SetText as
// ExtendSelectionAndDelete(n, 0) + InsertText; Textfield::ExtendSelectionAndDelete extends
// that reversed range, so it deletes inside the suggestion and the typed "e" survives.
// Composition never deletes outside its range, and the omnibox moves the suggestion out
// of the text while an IME composes (SetImeInlineAutocompletion) — the path every CJK IME
// uses there. So: Chromium-family browser process + IS_URL field (the omnibox reports
// TEXT_INPUT_TYPE_URL -> IS_URL for non-CJK input locales) -> compose this field.
// Not Vivaldi/Firefox: their address bars are not views::Textfield (both fine per report).
bool isChromiumNativeOmniboxBrowser(const std::string& exe);
bool fieldPrefersComposition(const std::string& exe, const int* scopes, size_t count);

// (#173) But the browser's native text field draws an underline under ANY composition,
// whatever the display attribute says (Edge, Windows 10 22H2). So in that field the TIP
// first hands the field to VietTelex.exe's hook (Direct, AppCommand::DirectMode with
// kDirectAdoptTyped | kDirectInlineAutocomplete): the hook types every replace as U+202F
// (cancels the inline suggestion), Backspace x (N + 1), text — direct_policy.h
// directEditEvents. Composition (as before #173) stays the fallback. Decided at each word
// start while the field is offered to the hook (omniboxOfferedToHook below):
//   Refused   (no VietTelex.exe, UIPI, the field marked NoDirect) -> Compose (as before)
//   Acked     (kDirectOnProp from the live app on the window)     -> HookTypes: key passes
//   Pending   (asked, no ack yet), waited < kOmniboxAckWaitMs      -> PassAsTyped: the key
//             reaches the field raw and is recorded (typed_word.h); the hook adopts the
//             word at its first key (word_adopt.h). The TIP never composes a word the hook
//             could then type over — the handover race of 1.1.5.
//   Pending   for kOmniboxAckWaitMs or more (app hung)             -> GiveUp: release the
//             request, compose for the rest of the focus.
// (1.3.31) Offered at every word start of the address bar until composition was settled for
// this focus (Refused / GiveUp), whatever composition preference the field inherited: one
// lagging web field made every async store of the browser prefer composition
// (session.h setAsyncStore), the address bar with them, until the browser restarted.
// `inPlaceButForPreference` = session.h; `composeSettled` = Refused / GiveUp this focus.
inline bool omniboxOfferedToHook(bool isOmnibox, bool inPlaceButForPreference, bool composeSettled) {
    return isOmnibox && inPlaceButForPreference && !composeSettled;
}
enum class DirectAsk : uint8_t { Refused, Pending, Acked };
enum class OmniboxStep : uint8_t { Compose, PassAsTyped, HookTypes, GiveUp };
constexpr uint64_t kOmniboxAckWaitMs = 500;
inline OmniboxStep omniboxStepAtWordStart(DirectAsk ask, uint64_t waitedMs) {
    switch (ask) {
        case DirectAsk::Acked: return OmniboxStep::HookTypes;
        case DirectAsk::Pending: return waitedMs < kOmniboxAckWaitMs ? OmniboxStep::PassAsTyped : OmniboxStep::GiveUp;
        case DirectAsk::Refused: break;
    }
    return OmniboxStep::Compose;
}

// Windows search (Start / taskbar search: SearchHost, SearchApp, StartMenuExperienceHost)
// on an ASYNC store (a Chromium/WebView2 context: transitory, readable). 2026-11 field
// report: the first word lost its tone key after "aa" ("taafng" -> "tâfng", "taangf" ->
// "tângf") while every later word worked — the #139 path: the store lags right after the
// first in-place replace, the edit key goes through as typed, and only then the field
// composes. The search box is opened afresh for each search, so each search paid that
// first word. There the TIP composes from the first letter (as the later words already
// did). `app` = the app identity (WebView2: the owning app). Sync stores: unchanged.
bool shellSearchPrefersComposition(const std::string& app, bool asyncStore);

// (2026-11, 1.3.19 report) Word's own UI text boxes — the Navigation pane search box
// (Ctrl+F), the ribbon search. The debug log of 1.3.18–1.3.20 shows the Navigation search
// box as focus class "RICHEDIT60W" (Office's RichEdit, its own TSF store, sync, not
// transitory); "NetUIHWND" (the NetUI host) is kept. The document body is "_WwG": not this.
// That box offers every key we let through a second time before inserting it (tip_caches.h
// KeyEventRepeat), and re-sets its text while a search runs, so in place it lost marks
// ("đầu mối" -> "đâù môí"); composition never lets a letter through or edits committed
// text: compose there from the first letter. Sync stores only; `exe` = lowercase name.
bool officeUiPrefersComposition(const std::string& exe, const std::u16string& focusClass, bool asyncStore);

// (2026-11) Control kinds of THIS app where in-place proved unreliable on a sync store
// (session.h takeFieldUnreliable: the app undid our replace, or dropped its deletion — Word's
// Navigation search box). One TIP instance serves one app, so the key is the focus window
// class alone; the next time such a control gets focus it composes from the first letter
// instead of paying one damaged word again. In memory only (gone when the app quits); a
// few entries at most (an unknown / empty class is never remembered).
class UnreliableControls {
public:
    void remember(const std::u16string& cls) {
        if (cls.empty() || has(cls)) return;
        if (n_ == kMax) n_ = 0;  // full: overwrite from the oldest (never grows)
        cls_[n_++] = cls;
        if (count_ < kMax) ++count_;
    }
    bool has(const std::u16string& cls) const {
        if (cls.empty()) return false;
        for (size_t i = 0; i < count_; ++i)
            if (cls_[i] == cls) return true;
        return false;
    }
    size_t size() const { return count_; }

private:
    static constexpr size_t kMax = 8;
    std::u16string cls_[kMax];
    size_t n_ = 0, count_ = 0;
};

}  // namespace vtx
