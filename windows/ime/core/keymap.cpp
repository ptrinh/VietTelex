#include "keymap.h"

namespace vtx {

char32_t usQwertyChar(uint32_t v, bool shift, bool caps) {
    if (v >= 'A' && v <= 'Z') {
        bool upper = shift != caps;
        return upper ? static_cast<char32_t>(v) : static_cast<char32_t>(v - 'A' + 'a');
    }
    if (v >= '0' && v <= '9') {
        static const char kShifted[] = ")!@#$%^&*(";
        return shift ? static_cast<char32_t>(kShifted[v - '0']) : static_cast<char32_t>(v);
    }
    if (v >= vk::Numpad0 && v <= vk::Numpad9) return static_cast<char32_t>('0' + (v - vk::Numpad0));
    switch (v) {
        case vk::Space: return U' ';
        case vk::Multiply: return U'*';
        case vk::Add: return U'+';
        case vk::Subtract: return U'-';
        case vk::Decimal: return U'.';
        case vk::Divide: return U'/';
        case vk::Oem1: return shift ? U':' : U';';
        case vk::OemPlus: return shift ? U'+' : U'=';
        case vk::OemComma: return shift ? U'<' : U',';
        case vk::OemMinus: return shift ? U'_' : U'-';
        case vk::OemPeriod: return shift ? U'>' : U'.';
        case vk::Oem2: return shift ? U'?' : U'/';
        case vk::Oem3: return shift ? U'~' : U'`';
        case vk::Oem4: return shift ? U'{' : U'[';
        case vk::Oem5: return shift ? U'|' : U'\\';
        case vk::Oem6: return shift ? U'}' : U']';
        case vk::Oem7: return shift ? U'"' : U'\'';
        case vk::Oem102: return shift ? U'|' : U'\\';
        default: return 0;
    }
}

KeyInput classifyKey(uint32_t v, const Modifiers& m) {
    KeyInput k;
    if (isModifierVk(v)) { k.kind = KeyKind::Modifier; return k; }
    if (v == vk::ProcessKey || v == vk::Packet) { k.kind = KeyKind::Other; return k; }
    // Any Ctrl/Alt/Win combination is an app shortcut. (US layout has no AltGr.)
    if (m.ctrl || m.alt || m.win) {
        k.kind = KeyKind::Chord;
        return k;
    }
    switch (v) {
        case vk::Back: k.kind = KeyKind::Backspace; return k;
        case vk::Return:
        case vk::Tab:
        case vk::Escape: k.kind = KeyKind::Boundary; return k;
        case vk::Left: case vk::Right: case vk::Up: case vk::Down:
        case vk::Home: case vk::End: case vk::Prior: case vk::Next:
        case vk::Delete: case vk::Insert:
            k.kind = KeyKind::Navigation; return k;
        default: break;
    }
    char32_t c = usQwertyChar(v, m.shift, m.capsLock);
    if (c) {
        k.kind = KeyKind::Char;
        k.ch = c;
        k.numpad = v >= vk::Numpad0 && v <= vk::Numpad9;
        return k;
    }
    k.kind = KeyKind::Other;
    return k;
}

bool layoutTypesUs(char32_t us, int count, const char16_t* units) {
    if (count <= 0 || !units) return false;  // dead key or nothing: not what US types
    char32_t c = units[0];
    int used = 1;
    if (c >= 0xD800 && c <= 0xDBFF && count >= 2 && units[1] >= 0xDC00 && units[1] <= 0xDFFF) {
        c = 0x10000 + ((c - 0xD800) << 10) + (units[1] - 0xDC00);
        used = 2;
    }
    return count == used && c == us;
}

namespace {
int cacheRow(bool shift, bool capsLock) { return (shift ? 1 : 0) | (capsLock ? 2 : 0); }
}  // namespace

LayoutMatch LayoutMatchCache::get(uintptr_t hkl, uint32_t v, bool shift, bool capsLock) const {
    if (hkl != hkl_ || v > 0xFF) return LayoutMatch::Unknown;
    return m_[cacheRow(shift, capsLock)][v];
}

void LayoutMatchCache::put(uintptr_t hkl, uint32_t v, bool shift, bool capsLock, LayoutMatch m) {
    if (v > 0xFF) return;
    if (hkl != hkl_) {
        for (auto& row : m_)
            for (auto& x : row) x = LayoutMatch::Unknown;
        hkl_ = hkl;
    }
    m_[cacheRow(shift, capsLock)][v] = m;
}

bool shouldRetypeAsUs(const KeyInput& k, uintptr_t hkl, LayoutMatch m) {
    return k.kind == KeyKind::Char && k.ch != 0 && isVietnameseHkl(hkl) && m == LayoutMatch::Differs;
}

PassedKeyRetype passedKeyRetype(const KeyInput& k) {
    switch (k.kind) {
        case KeyKind::Char:
            return k.ch != 0 && k.ch <= 0xFFFF ? PassedKeyRetype::Unicode : PassedKeyRetype::None;
        case KeyKind::Backspace:
        case KeyKind::Boundary:
        case KeyKind::Navigation:
        case KeyKind::Chord:
            return PassedKeyRetype::VirtualKey;
        case KeyKind::Modifier:
        case KeyKind::Other:
            return PassedKeyRetype::None;
    }
    return PassedKeyRetype::None;
}

bool retypeAfterComposition(const KeyInput& k, bool asyncStore, bool composingBefore, bool composingAfter) {
    return asyncStore && composingBefore && !composingAfter && k.kind == KeyKind::Boundary;
}

RetypeStrokes retypeStrokes(bool releaseFirst) {
    return releaseFirst ? RetypeStrokes{3, {true, false, true}} : RetypeStrokes{2, {false, true, false}};
}

}  // namespace vtx
