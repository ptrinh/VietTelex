// typed_word.h — the word in progress that reached the app AS TYPED (1.3.16, WPF list).
//
// In WPF's default store (a file list with type-to-filter, app_policy.h wpfDefaultStore) the
// TIP composes nothing: every key goes to the app as typed and the TIP asks VietTelex.exe's
// hook to take over (Direct). The hook acks a few milliseconds later, normally after the
// first letter of the word already reached the list. It used to wait for a word boundary
// before typing; One Commander's filter is ONE word (Space ends it), so it was never accented.
// Now the TIP records the raw keys of the current word and publishes them on its focus root
// (kTypedWordProp) while that context lasts; the hook reads them once, at the first key it
// handles after such a handover, feeds them to its engine and treats the raw letters as what
// the screen shows (app/core/word_adopt.h). Pure, header-only; unit-tested on any OS.
//
// The value fits a window property on 32-bit processes too (x86 TIP): 5 slots of 6 bits
// (bits 0..29, first key lowest; code 0 = empty slot), bit 30 = "a word is in progress but
// its keys are unknown" (too long, a key that is no ASCII letter/digit, a key retyped by
// VietTelex): the hook then keeps its old rule and waits for a boundary. 0 = no word.
#pragma once
#include <cstdint>
#include <string>

#include "keymap.h"

namespace vtx {

// Set by the TIP on its focus root window in WPF's default store; read by the hook.
constexpr const wchar_t* kTypedWordProp = L"VietTelex.TypedWord";

constexpr uint32_t kTypedWordUnknown = 1u << 30;
constexpr int kTypedWordMax = 5;

// 6-bit code of a key that may be part of a word: a-z 1..26, A-Z 27..52, 0-9 53..62; 0 = none.
inline uint32_t typedWordCode(char32_t c) {
    if (c >= U'a' && c <= U'z') return 1 + static_cast<uint32_t>(c - U'a');
    if (c >= U'A' && c <= U'Z') return 27 + static_cast<uint32_t>(c - U'A');
    if (c >= U'0' && c <= U'9') return 53 + static_cast<uint32_t>(c - U'0');
    return 0;
}

inline char16_t typedWordChar(uint32_t code) {
    if (code >= 1 && code <= 26) return static_cast<char16_t>(u'a' + (code - 1));
    if (code >= 27 && code <= 52) return static_cast<char16_t>(u'A' + (code - 27));
    if (code >= 53 && code <= 62) return static_cast<char16_t>(u'0' + (code - 53));
    return 0;
}

struct DecodedTypedWord {
    bool unknown = false;  // a word is in progress, its keys are not known
    std::u16string raw;    // the keys (= the characters on screen), empty = no word
};

inline DecodedTypedWord decodeTypedWord(uint32_t v) {
    DecodedTypedWord d;
    if (v & kTypedWordUnknown) {
        d.unknown = true;
        return d;
    }
    for (int i = 0; i < kTypedWordMax; ++i) {
        const uint32_t code = (v >> (6 * i)) & 0x3F;
        if (!code) break;
        const char16_t c = typedWordChar(code);
        if (!c) {  // 63: never written
            d.unknown = true;
            d.raw.clear();
            return d;
        }
        d.raw.push_back(c);
    }
    return d;
}

// The TIP's record, fed every key it sees (OnTestKeyDown), in this order of the app.
class TypedWord {
public:
    void note(const KeyInput& k) {
        switch (k.kind) {
            case KeyKind::Char: {
                const uint32_t code = k.numpad ? 0 : typedWordCode(k.ch);
                if (code) {
                    if (unknown_) return;
                    if (len_ >= kTypedWordMax) return invalidate();
                    keys_ |= code << (6 * len_);
                    ++len_;
                } else if (k.ch == U'[' || k.ch == U']' || k.ch == U'{' || k.ch == U'}') {
                    invalidate();  // a bracket vowel key (ơ / ư) may continue the word
                } else {
                    clear();  // space, punctuation: the word ended as typed
                }
                return;
            }
            case KeyKind::Backspace:
                // The app deleted the last character. Nothing typed yet: the ⌫ went to the
                // app (a list goes up a folder), the next letter starts a word.
                if (unknown_ || !len_) return;
                --len_;
                keys_ &= ~(0x3Fu << (6 * len_));
                return;
            case KeyKind::Modifier: return;  // Shift for a capital, Ctrl+Shift...
            case KeyKind::Boundary:
            case KeyKind::Navigation:
            case KeyKind::Chord:
            case KeyKind::Other: clear(); return;
        }
    }
    // A key whose effect is not known (retyped / injected by VietTelex, English typing):
    // the word goes on, its keys do not.
    void invalidate() {
        keys_ = 0;
        len_ = 0;
        unknown_ = true;
    }
    void clear() {
        keys_ = 0;
        len_ = 0;
        unknown_ = false;
    }
    uint32_t encoded() const { return unknown_ ? kTypedWordUnknown : keys_; }
    bool empty() const { return !unknown_ && !len_; }
    int length() const { return unknown_ ? -1 : len_; }  // log only: -1 = unknown keys

private:
    uint32_t keys_ = 0;
    int len_ = 0;
    bool unknown_ = false;
};

// Which key event the record was last fed for (1.3.31, #173). The TIP feeds it in
// OnTestKeyDown; a host that offers a key to OnKeyDown only left the record empty, the hook
// adopted nothing and the first letter of the word was lost ("onw" -> "onư" in the address
// bar). OnKeyDown feeds the record itself unless this very event (key + message time) was
// (the key OnTestKeyDown saw last) was already fed — once: the next OnKeyDown of that key
// with no OnTestKeyDown before it is a new press.
class TypedKeyNote {
public:
    void fedAtTest(uint64_t key) {
        key_ = key;
        armed_ = true;
    }
    // OnKeyDown: true = OnTestKeyDown fed the record for this key (nothing to do).
    bool takeAtKeyDown(uint64_t key) {
        const bool fed = armed_ && key_ == key;
        armed_ = false;
        return fed;
    }
    void reset() { armed_ = false; }

private:
    uint64_t key_ = 0;
    bool armed_ = false;
};

// What the TIP publishes on its focus root: the word only in a context where every key
// passes to the app as typed (WPF's default store), else nothing (property removed).
inline uint32_t typedWordToPublish(bool keysPassAsTyped, const TypedWord& w) {
    return keysPassAsTyped ? w.encoded() : 0;
}

}  // namespace vtx
