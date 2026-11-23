// keymap.h — classify a Win32 virtual-key event into what the typing session needs.
//
// Pure (no Win32 headers): VK codes are plain numbers. Telex composes on the US
// QWERTY layout — the TIP registers its profile with the US layout as substitute
// (hklSubstitute = 0x04090409), and translates keys itself with this table so the
// result never depends on whichever layout Windows would otherwise pair with vi-VN
// (the stock "Vietnamese" layout puts ă â ê ô on the number row — typing "1" would
// give "ă"). Same idea as macOS KeyboardLayoutOverride pinning an ASCII layout.
// Keys the TIP does NOT eat are still typed by the app through the thread's layout: see
// "Keys the TIP lets through" below (#121: the substitute is not always what you get).
#pragma once
#include <cstdint>

namespace vtx {

struct Modifiers {
    bool shift = false;
    bool ctrl = false;
    bool alt = false;
    bool win = false;
    bool capsLock = false;
};

enum class KeyKind : uint8_t {
    Char,        // printable character (letter, digit, punctuation, space) -> `ch`
    Backspace,
    Boundary,    // Enter, Tab, Esc: ends the word, key goes to the app
    Navigation,  // arrows, Home/End, PgUp/PgDn, Delete, Insert: ends the word
    Chord,       // Ctrl/Alt/Win + key: app shortcut; ends the word
    Modifier,    // Shift/Ctrl/Alt/Win/Caps alone: ignored (fed to hotkey recognizer)
    Other,       // F-keys, media keys, ...: ignored, never touches the word
};

struct KeyInput {
    KeyKind kind = KeyKind::Other;
    char32_t ch = 0;   // Char only
    bool numpad = false;  // Char from the numeric keypad: never a VNI mark key (#124)
};

// VK constants used by the classifier (values from WinUser.h).
namespace vk {
constexpr uint32_t Back = 0x08, Tab = 0x09, Return = 0x0D, Shift = 0x10, Control = 0x11,
                   Menu = 0x12, Pause = 0x13, Capital = 0x14, Escape = 0x1B, Space = 0x20,
                   Prior = 0x21, Next = 0x22, End = 0x23, Home = 0x24, Left = 0x25, Up = 0x26,
                   Right = 0x27, Down = 0x28, Insert = 0x2D, Delete = 0x2E, LWin = 0x5B,
                   RWin = 0x5C, Apps = 0x5D, Numpad0 = 0x60, Numpad9 = 0x69, Multiply = 0x6A,
                   Add = 0x6B, Subtract = 0x6D, Decimal = 0x6E, Divide = 0x6F, LShift = 0xA0,
                   RShift = 0xA1, LControl = 0xA2, RControl = 0xA3, LMenu = 0xA4, RMenu = 0xA5,
                   Oem1 = 0xBA, OemPlus = 0xBB, OemComma = 0xBC, OemMinus = 0xBD,
                   OemPeriod = 0xBE, Oem2 = 0xBF, Oem3 = 0xC0, Oem4 = 0xDB, Oem5 = 0xDC,
                   Oem6 = 0xDD, Oem7 = 0xDE, Oem102 = 0xE2, ProcessKey = 0xE5, Packet = 0xE7;
}  // namespace vk

// US-QWERTY character for `vkCode` (0 if not printable). Letters honour Shift XOR Caps.
char32_t usQwertyChar(uint32_t vkCode, bool shift, bool capsLock);

KeyInput classifyKey(uint32_t vkCode, const Modifiers& m);

inline bool isModifierVk(uint32_t v) {
    return v == vk::Shift || v == vk::Control || v == vk::Menu || v == vk::LShift ||
           v == vk::RShift || v == vk::LControl || v == vk::RControl || v == vk::LMenu ||
           v == vk::RMenu || v == vk::LWin || v == vk::RWin || v == vk::Capital;
}

// ---- Keys the TIP lets through (#121) ----------------------------------------------
// Digits, punctuation, English mode, Direct fields...: every key the TIP does not eat is
// turned into a character by the APP, through the thread's keyboard layout
// (TranslateMessage / ToUnicode). If that layout is the stock Microsoft "Vietnamese" one
// (KLID 0000042A) — the profile's US substitute layout not applied, e.g. when the user
// also has that keyboard under Tiếng Việt — the number row comes out as
// ă â ê ô ̀ ̉ ̃ ́ ̣ đ. The TIP then eats such a key and types its US-QWERTY character
// itself. Keys the layout types like US (letters, space, most punctuation) are never
// touched, so on a US-mapped thread none of this changes anything.

// Does the thread's layout type `us` for this key? `count`/`units` are what
// ToUnicodeEx(..., flags 0x4) returned: < 0 dead key, 0 nothing, else UTF-16 units.
bool layoutTypesUs(char32_t us, int count, const char16_t* units);

enum class LayoutMatch : uint8_t { Unknown = 0, Same, Differs };

// layoutTypesUs per (key, Shift, Caps), remembered for the current HKL: one ToUnicodeEx
// per distinct key, not per keystroke. A different HKL forgets everything.
class LayoutMatchCache {
public:
    LayoutMatch get(uintptr_t hkl, uint32_t vkCode, bool shift, bool capsLock) const;
    void put(uintptr_t hkl, uint32_t vkCode, bool shift, bool capsLock, LayoutMatch m);

private:
    uintptr_t hkl_ = 0;
    LayoutMatch m_[4][256] = {};
};

// Input language of an HKL (its low word) is Vietnamese (0x042A).
inline bool isVietnameseHkl(uintptr_t hkl) { return (hkl & 0xFFFF) == 0x042A; }

// Should the TIP type `k` itself (as k.ch) instead of letting the app type it? Only a
// printable, non-chord key; only under a Vietnamese-language HKL (another language's
// layout is never second-guessed); only when that layout would type something else.
bool shouldRetypeAsUs(const KeyInput& k, uintptr_t hkl, LayoutMatch m);

// ---- Keys claimed, then let through, in an IMM32 host (#134) -----------------------
// In an IMM32 app reached through CUAS (WinForms: MISA SME), a key OnTestKeyDown claims is
// turned into VK_PROCESSKEY before the app sees it; if OnKeyDown then does not eat it, no
// WM_CHAR / WM_KEYDOWN for it ever arrives: the key is gone (first letter lost, Space
// after a word lost). In such a host the TIP retypes the key itself:
//   Unicode     printable character -> KEYEVENTF_UNICODE (VK_PACKET -> WM_CHAR)
//   VirtualKey  Backspace / Enter / Tab / Esc / navigation / chord -> the same VK again
//               (modifiers still held physically: Ctrl+V stays Ctrl+V)
//   None        modifiers and keys the session never claims
enum class PassedKeyRetype : uint8_t { None, Unicode, VirtualKey };
PassedKeyRetype passedKeyRetype(const KeyInput& k);

// ---- Enter / Tab / Esc ending a composing word in a browser (#173) ------------------
// In a Chromium text store (async: Chrome, Edge, Electron, WebView2) a key during which the
// TIP edits the document reaches the page as keydown 229 ("Process"), not as itself. A word
// still composing when Enter comes is committed inside that key, so a page whose handler
// only knows the genuine keydown never saw Enter: the default action ran instead (a web
// chat box got a new line where Enter sends; adding a space first made it send). There the
// TIP commits the word, eats the key and types the same key again: a key of its own, with
// no edit inside it. Only Enter / Tab / Esc; only when this very key closed the composition.
bool retypeAfterComposition(const KeyInput& k, bool asyncStore, bool composingBefore, bool composingAfter);

// The key events that retype a virtual key. The physical key is still held when the TIP
// retypes it, so a bare key-down reaches the app as an auto-repeat (lParam bit 30; a page
// sees KeyboardEvent.repeat = true) and web chat boxes do not send on a repeated Enter
// (#173, measured in Edge: "keydown Enter 13 repeat=true"). Releasing the key first makes
// the retyped key-down a first press. up[i]: event i is a key-up.
struct RetypeStrokes {
    int count;
    bool up[3];
};
RetypeStrokes retypeStrokes(bool releaseFirst);

// How long after the composition closed the retyped key-down is sent (#173, 1.3.33 retest).
// The retyped Enter was then a clean first press ("keydown Enter 13 repeat=false") yet web
// chat boxes still did not send: it reached the page in the same instant as compositionend,
// where a second Enter typed by hand (which does send) comes a moment later. So Enter is
// released at once and pressed again after this delay. Tab / Esc stay immediate: a letter
// typed right after Tab must not reach the field Tab is leaving.
constexpr unsigned kRetypeEnterDelayMs = 60;
unsigned retypeDelayMs(uint32_t vkey, bool releaseFirst);

}  // namespace vtx
