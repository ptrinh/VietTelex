// keys.h — X11 keysym values (shared by Fcitx5 and IBus) and VietTelex modifier bits.
// Values are the X11 protocol constants, so no X11 headers are needed.
#pragma once

#include <cstdint>

namespace viettelex {

enum : uint32_t {
    VT_MOD_SHIFT = 1u << 0,
    VT_MOD_CTRL = 1u << 1,
    VT_MOD_ALT = 1u << 2,
    VT_MOD_SUPER = 1u << 3,
};

namespace ks {
constexpr uint32_t BackSpace = 0xff08, Tab = 0xff09, Return = 0xff0d, Escape = 0xff1b,
                   Delete = 0xffff, Home = 0xff50, Left = 0xff51, Up = 0xff52, Right = 0xff53,
                   Down = 0xff54, PageUp = 0xff55, PageDown = 0xff56, End = 0xff57,
                   KP_Enter = 0xff8d, ISO_Left_Tab = 0xfe20, space = 0x20;
constexpr uint32_t Control_L = 0xffe3, Control_R = 0xffe4;
// Modifier-only keys (Shift_L … Hyper_R) and friends: pressing them alone never ends
// a word.
inline bool isModifierOnly(uint32_t k) {
    return (k >= 0xffe1 && k <= 0xffee)             // Shift/Control/Caps/Shift_Lock/Meta/Alt/Super/Hyper
           || (k >= 0xfe01 && k <= 0xfe0f)          // ISO_Lock, ISO_Level3_Shift, ISO_Group…
           || k == 0xff7e                           // Mode_switch
           || k == 0xff7f                           // Num_Lock
           || k == 0xff14;                          // Scroll_Lock
}
// Keypad keys (KP_Space 0xff80 … KP_9 0xffb9, KP_Equal 0xffbd): their unicode is a plain
// digit/operator, but like UniKey they never act as VNI marks — always a boundary (#124).
inline bool isKeypad(uint32_t k) { return k >= 0xff80 && k <= 0xffbd; }
}  // namespace ks

struct KeyEvent {
    uint32_t keysym = 0;
    uint32_t unicode = 0;  // character after layout (0 = none)
    uint32_t mods = 0;     // VT_MOD_*
    bool release = false;
    // A key this IM forwarded itself (IBus IBUS_FORWARD_MASK) coming back: never processed.
    bool forwarded = false;
};

}  // namespace viettelex
