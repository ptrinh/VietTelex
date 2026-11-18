#include "settings.h"

#include <viettelex/vtx_engine.h>

#include "retro_english.h"
#include "utf.h"

namespace vtx {

namespace {
// Bit order == on-disk format. Append only.
const BoolKey kBoolKeys[] = {
    {"vniMode", &Settings::vniMode},
    {"simpleTelex", &Settings::simpleTelex},
    {"freeMarking", &Settings::freeMarking},
    {"quickTelex", &Settings::quickTelex},
    {"modernOrthography", &Settings::modernOrthography},
    {"bracketVowels", &Settings::bracketVowels},
    {"autoRestore", &Settings::autoRestore},
    {"liveSpellCheck", &Settings::liveSpellCheck},
    {"contextualEnglish", &Settings::contextualEnglish},
    {"collisionPrefersVietnamese", &Settings::collisionPrefersVietnamese},
    {"teencode", &Settings::teencode},
    {"reEditWord", &Settings::reEditWord},
    {"autoUpdateCheck", &Settings::autoUpdateCheck},
    {"debugLogging", &Settings::debugLogging},
    {"showTrayIcon", &Settings::showTrayIcon},
    {"textToolsInMenu", &Settings::textToolsInMenu},
    {"mathResults", &Settings::mathResults},
    {"numberChips", &Settings::numberChips},
    {"typoHints", &Settings::typoHints},
    {"toneHints", &Settings::toneHints},
    {"dateHints", &Settings::dateHints},
    {"underlineMisspelled", &Settings::underlineMisspelled},
    {"autoOffFullscreen", &Settings::autoOffFullscreen},
    {"gameMode", &Settings::gameMode},
    {"systemTextPrediction", &Settings::systemTextPrediction},
    {"filterSensitive", &Settings::filterSensitive},
    {"learnWords", &Settings::learnWords},
    {"retroactiveEnglish", &Settings::retroactiveEnglish},
    {"englishByFrequency", &Settings::englishByFrequency},
    {"startEnglish", &Settings::startEnglish},
    {"startHidden", &Settings::startHidden},
    {"switchSound", &Settings::switchSound},
    // ---- extension word (bit 32 on): see serialize() ----
    {"autoCircumflex", &Settings::autoCircumflex},
};
constexpr size_t kBoolCount = sizeof(kBoolKeys) / sizeof(kBoolKeys[0]);
constexpr uint32_t kMagic = 0x53585456;  // "VTXS"
constexpr uint16_t kVersion = 1;
constexpr size_t kMaxEntries = 20000;
static_assert(kBoolCount <= 64, "two snapshot words");

struct Writer {
    std::vector<uint8_t> b;
    void u8(uint8_t v) { b.push_back(v); }
    void u16(uint16_t v) { u8(v & 0xFF); u8(v >> 8); }
    void u32(uint32_t v) { u16(v & 0xFFFF); u16(v >> 16); }
    void str(const std::string& s) {
        size_t n = s.size() > 0xFFFF ? 0xFFFF : s.size();
        u16(static_cast<uint16_t>(n));
        b.insert(b.end(), s.begin(), s.begin() + static_cast<std::ptrdiff_t>(n));
    }
};

struct Reader {
    const uint8_t* p;
    size_t n, i = 0;
    bool ok = true;
    bool need(size_t k) { if (!ok || n - i < k) ok = false; return ok; }
    uint8_t u8() { if (!need(1)) return 0; return p[i++]; }
    uint16_t u16() { uint16_t lo = u8(); return static_cast<uint16_t>(lo | (u8() << 8)); }
    uint32_t u32() { uint32_t lo = u16(); return lo | (static_cast<uint32_t>(u16()) << 16); }
    std::string str() {
        uint16_t len = u16();
        if (!need(len)) return {};
        std::string s(reinterpret_cast<const char*>(p + i), len);
        i += len;
        return s;
    }
};
}  // namespace

bool isSystemMirror(const BoolKey& k) { return k.field == &Settings::systemTextPrediction; }

const BoolKey* boolKeys(size_t* count) {
    if (count) *count = kBoolCount;
    return kBoolKeys;
}

uint32_t Settings::engineFlags() const {
    uint32_t f = VTX_ENGLISH_WORD_RESTORE;
    if (freeMarking) f |= VTX_FREE_MARKING;
    if (modernOrthography) f |= VTX_MODERN_TONE;
    if (liveSpellCheck) f |= VTX_LIVE_SPELL_CHECK;
    if (simpleTelex) f |= VTX_SIMPLE_TELEX;
    if (teencode) f |= VTX_TEENCODE;
    if (quickTelex) f |= VTX_QUICK_TELEX;
    if (bracketVowels) f |= VTX_BRACKET_VOWELS;
    if (autoCircumflex) f |= VTX_AUTO_CIRCUMFLEX;
    if (vniMode) f |= VTX_VNI;
    if (contextualEnglish) f |= VTX_CONTEXTUAL_ENGLISH;
    if (collisionPrefersVietnamese) f |= VTX_COLLISION_PREFERS_VI;
    if (retro::flagWanted(contextualEnglish, retroactiveEnglish)) {
        f |= VTX_RETRO_ENGLISH;
        if (englishByFrequency) f |= VTX_ENGLISH_BY_FREQUENCY;   // inert without the retro flag
    }
    // "goog" not "gôg" mid-word — only with auto-restore (else the boundary keeps "gôgle").
    if (autoRestore) f |= VTX_EAGER_ENGLISH_RESTORE;
    return f;
}

bool Settings::operator==(const Settings& o) const {
    for (const BoolKey& k : kBoolKeys)
        if (this->*k.field != o.*k.field) return false;
    return switchHotkey == o.switchHotkey && menuIcon == o.menuIcon &&
           uiLanguage == o.uiLanguage && shortcuts == o.shortcuts && appModes == o.appModes;
}

std::vector<uint8_t> serialize(const Settings& s) {
    Writer w;
    w.u32(kMagic);
    w.u16(kVersion);
    w.u16(static_cast<uint16_t>(kBoolCount));
    uint32_t bits = 0, ext = 0;
    for (size_t i = 0; i < kBoolCount; ++i)
        if (s.*kBoolKeys[i].field) {
            if (i < 32) bits |= 1u << i;
            else ext |= 1u << (i - 32);
        }
    w.u32(bits);
    w.str(s.switchHotkey);
    w.str(s.menuIcon);
    w.str(s.uiLanguage);
    w.u32(static_cast<uint32_t>(s.shortcuts.size()));
    for (const auto& kv : s.shortcuts) {
        w.str(utf16ToUtf8(kv.first));
        w.str(utf16ToUtf8(kv.second));
    }
    w.u32(static_cast<uint32_t>(s.appModes.size()));
    for (const auto& kv : s.appModes) {
        w.str(kv.first);
        w.u8(static_cast<uint8_t>(kv.second));
    }
    // Bools 32..63: appended so a parser that knows only 32 bools reads the rest unchanged.
    if constexpr (kBoolCount > 32) w.u32(ext);
    return w.b;
}

bool deserialize(const uint8_t* data, size_t len, Settings& out) {
    out = Settings{};
    if (!data) return false;
    Reader r{data, len};
    if (r.u32() != kMagic || !r.ok) return false;
    uint16_t version = r.u16();
    if (version != kVersion) return false;
    uint16_t boolCount = r.u16();
    uint32_t bits = r.u32();
    if (!r.ok) return false;
    Settings s;
    for (size_t i = 0; i < kBoolCount && i < boolCount && i < 32; ++i)
        s.*kBoolKeys[i].field = (bits >> i) & 1u;
    s.switchHotkey = r.str();
    s.menuIcon = r.str();
    s.uiLanguage = r.str();
    uint32_t n = r.u32();
    if (!r.ok || n > kMaxEntries) return false;
    for (uint32_t i = 0; i < n && r.ok; ++i) {
        std::string k = r.str(), v = r.str();
        if (r.ok && !k.empty()) s.shortcuts[utf8ToUtf16(k)] = utf8ToUtf16(v);
    }
    uint32_t m = r.u32();
    if (!r.ok || m > kMaxEntries) return false;
    for (uint32_t i = 0; i < m && r.ok; ++i) {
        std::string exe = r.str();
        uint8_t mode = r.u8();
        if (r.ok && mode <= static_cast<uint8_t>(AppMode::Direct))
            s.appModes[exe] = static_cast<AppMode>(mode);
    }
    if (!r.ok) return false;
    // Extension word (bools 32..63), present when the writer had more than 32 bools.
    if (boolCount > 32) {
        uint32_t ext = r.u32();
        if (!r.ok) return false;
        for (size_t i = 32; i < kBoolCount && i < boolCount && i < 64; ++i)
            s.*kBoolKeys[i].field = (ext >> (i - 32)) & 1u;
    }
    out = std::move(s);
    return true;
}

}  // namespace vtx
