#include "direct_policy.h"

namespace vtx {

bool directUsable(bool known, unsigned long target, unsigned long hook) { return known && target <= hook; }

SendOutcome classifySend(unsigned sent, unsigned total) {
    if (sent >= total) return SendOutcome::Ok;
    return sent == 0 ? SendOutcome::NothingSent : SendOutcome::Partial;
}

bool injectionAllowed(uintptr_t now, uintptr_t word, bool secureDesktop) {
    return !secureDesktop && now != 0 && now == word;
}

bool echoMatches(const std::u16string& before, const std::u16string& expected) {
    if (expected.empty()) return true;
    return before.size() >= expected.size() && before.compare(before.size() - expected.size(), expected.size(), expected) == 0;
}

bool echoInValue(const std::u16string& value, const std::u16string& expected) {
    return expected.empty() || value.find(expected) != std::u16string::npos;
}

std::string hostIdentity(const std::string& windowClass, const std::string& ownerExe) {
    if (isConsoleWindowClass(windowClass)) return "conhost.exe";
    return ownerExe;
}

bool foregroundLanguage(int tipProp, bool console, bool hklIsVietTelex, bool storedVietnamese) {
    if (tipProp == 1) return true;
    if (tipProp == 2) return false;
    if (console) return false;
    return hklIsVietTelex && storedVietnamese;
}

bool EchoPolicy::record(uintptr_t w, int c, Echo e) {
    const auto key = std::make_pair(w, c);
    if (fallen_[key]) return false;
    if (e == Echo::Match) {
        mismatches_[key] = 0;
        return false;
    }
    if (e == Echo::Unverifiable) return false;
    if (++mismatches_[key] >= kMismatchesToFallBack) {
        fallen_[key] = true;
        return true;
    }
    return false;
}

bool EchoPolicy::fellBack(uintptr_t w, int c) const {
    auto it = fallen_.find(std::make_pair(w, c));
    return it != fallen_.end() && it->second;
}

void EchoPolicy::focusChanged() {
    mismatches_.clear();
    fallen_.clear();
}

std::vector<DirectKeyEvent> directEditEvents(unsigned backspaces, const std::u16string& text) {
    std::vector<DirectKeyEvent> v;
    v.reserve(2 * (backspaces + text.size()));
    for (unsigned i = 0; i < backspaces; ++i)
        for (bool up : {false, true}) v.push_back(DirectKeyEvent{kVkBack, 0, false, up});
    for (char16_t c : text)
        for (bool up : {false, true}) v.push_back(DirectKeyEvent{0, static_cast<uint16_t>(c), true, up});
    return v;
}

std::vector<DirectKeyEvent> directEditEvents(unsigned backspaces, const std::u16string& text,
                                             bool inlineAutocompleteField) {
    if (!usesPlaceholderEdit(inlineAutocompleteField, backspaces, text.empty()))
        return directEditEvents(backspaces, text);
    std::vector<DirectKeyEvent> v = directEditEvents(0, std::u16string(1, kAutocompletePlaceholder));
    const std::vector<DirectKeyEvent> rest = directEditEvents(backspaces + 1, text);
    v.insert(v.end(), rest.begin(), rest.end());
    return v;
}

bool splitsCorrection(const std::string& cls) { return cls.compare(0, 6, "SunAwt") == 0; }

std::array<KeyInjection, 2> replayKeyInjection(uint32_t vk, uint32_t scanCode, uint32_t llFlags,
                                               uint16_t mappedScan) {
    KeyInjection down;
    down.vk = static_cast<uint16_t>(vk);
    down.scan = scanCode ? static_cast<uint16_t>(scanCode) : mappedScan;
    down.flags = (llFlags & kLlkhfExtended) ? kKeyeventfExtendedKey : 0;
    KeyInjection up = down;
    up.flags |= kKeyeventfKeyUp;
    return {down, up};
}

}  // namespace vtx
