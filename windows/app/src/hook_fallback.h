// hook_fallback.h — per-app keyboard-hook fallback (spec §5.3, mode "hookFallback").
//
// For the rare app without usable TSF (old Java/Qt, some games, RDP-like canvases):
// while such an app is in the FOREGROUND, and the VietTelex keyboard (vi-VN) is its
// active input method, and the app is in Vietnamese mode, a WH_KEYBOARD_LL hook runs
// the same TypingSession (in-place) and types with SendInput(KEYEVENTF_UNICODE).
// Everything else: no typing hook. (2026-10) With the Ctrl+Shift switch key the keyboard
// hook also stays in, OBSERVE-ONLY, to see the chord while another keyboard is active
// (input_switch.h); it never eats or sends a key. Self-injected events carry a marker in
// dwExtraInfo and are ignored; a RateBreaker stops any synthetic-event cascade.
#pragma once
#include <windows.h>

#include <string>

#include "settings.h"

namespace vtx::app {

void hookConfigure(const Settings& s);  // (re)apply settings; starts/stops watching
void hookShutdown();
// The TIP found a field it cannot type into without an underline (CUAS/IMM app,
// xterm.js, unflagged console): the hook types there until the foreground changes.
// `adoptTyped` (kDirectAdoptTyped, 1.3.16): the word in progress reached the app as typed
// (WPF list); the hook takes it over at its first key (word_adopt.h).
// `inlineAutocomplete` (kDirectInlineAutocomplete, #173): a Chromium address bar — replaces
// go out as U+202F, Backspace x (N + 1), text (direct_policy.h usesPlaceholderEdit).
void hookSetDirectFromTip(bool on, bool adoptTyped, bool inlineAutocomplete);
// Direct proved unusable in the current field (echo verification): stop hooking it.
void hookDisableCurrentField();
// Called (UI thread) when a hook-mode app is elevated above VietTelex.exe: SendInput
// cannot reach it (UIPI). The app shows a non-modal notice.
void hookSetElevationNotifier(void (*notify)(const std::wstring& exe));
// Game / fullscreen / Chế độ game (game_mode.cpp): the hook types nothing while on.
void hookSetSuspended(bool on);
// Ctrl+Shift watcher (input_switch.h): post `msg` to `wnd` (UI thread) when the chord
// completes, whatever input method is active. Call before hookConfigure.
void hookSetChordTarget(HWND wnd, UINT msg);

}  // namespace vtx::app
