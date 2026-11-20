// ipc.h — messages to VietTelex.exe's hidden window (PostMessage(kAppCommandMsg, cmd,
// lParam)) or `VietTelex.exe --command <n>` when the app is not running. The TIP never
// writes settings itself (spec §9).
//   StateChanged (TIP -> app): lParam 1 = Vietnamese, 0 = English, for the app that has
//   focus — drives the optional tray icon, the only Việt/Anh indicator since 1.0.8.
#pragma once

namespace vtx {

enum class AppCommand : unsigned {
    OpenSettings = 1,
    CheckUpdate = 2,
    SetTelex = 3,
    SetVni = 4,
    OpenAbout = 5,
    StateChanged = 6,
    // TIP -> app: lParam bit 0 = let the hook type in this field (no underline); bit 1
    // (kDirectAdoptTyped, 1.3.16) = the keys of the word in progress reached the app as typed
    // and are on the focus root (typed_word.h): the hook adopts that word instead of waiting
    // for a boundary. Bit 2 (kDirectInlineAutocomplete, #173) = the field is a Chromium
    // address bar with inline autocomplete: every replace goes out as U+202F, Backspace x
    // (N + 1), text (direct_policy.h directEditEvents). 0 = released.
    DirectMode = 7,
    // TIP -> app after an in-TIP Việt/Anh switch (1.1.5): bit 0 = Vietnamese, bit 1 = the
    // TIP could not store it (AppContainer / low IL): store it for the foreground app.
    // The app then refreshes the applang.txt mirror AppContainers read.
    SetAppLanguage = 8,
    // TIP -> app (Công cụ văn bản): lParam = textToolReplyParam(request, status), see
    // text_tool_ipc.h.
    TextToolReply = 9,
    // TIP -> app: the USER switched Việt/Anh (Ctrl+Shift, Alt+Z) — not a focus change.
    // lParam 1 = Vietnamese, 0 = English. Drives the floating V/E indicator; costs nothing
    // on the typing path (posted only on a switch).
    UserSwitched = 10,
};

constexpr unsigned kDirectOn = 1, kDirectAdoptTyped = 2, kDirectInlineAutocomplete = 4;  // DirectMode lParam bits

// AppCommand::DirectMode lParam, decoded by VietTelex.exe. The flags mean nothing without
// kDirectOn (a release carries 0).
struct DirectModeRequest {
    bool on = false;
    bool adoptTyped = false;
    bool inlineAutocomplete = false;
};
inline DirectModeRequest decodeDirectMode(unsigned long lp) {
    DirectModeRequest r;
    r.on = (lp & kDirectOn) != 0;
    r.adoptTyped = r.on && (lp & kDirectAdoptTyped) != 0;
    r.inlineAutocomplete = r.on && (lp & kDirectInlineAutocomplete) != 0;
    return r;
}

inline bool isValidAppCommand(unsigned v) { return v >= 1 && v <= 10; }
// Commands a user may pass as `--command <n>` (StateChanged is TIP-internal).
inline bool isUserCommand(unsigned v) { return v >= 1 && v <= 5; }

}  // namespace vtx
