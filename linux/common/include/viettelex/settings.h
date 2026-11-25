// settings.h — VietTelex Linux settings (contract: linux/common/SETTINGS.md).
// Pure parsing/serialisation, no I/O except the explicit load*/save* helpers.
#pragma once

#include <cstdint>
#include <map>
#include <memory>
#include <string>

namespace viettelex {

// Preedit: composition shown by the client. Surrounding: edit committed text through
// delete-surrounding + commit. Direct (terminals, only on hosts whose forwarded keys reach
// the app in order — see app.h): type committed text and fix it with forwarded BackSpace
// keys, never reading anything back. Direct is chosen per app/field, never globally.
enum class DisplayMode { Preedit, Surrounding, Direct };

// [experimental] no_underline (linux/docs/NO-UNDERLINE-SPIKE.md). ForwardKeys: in Chromium /
// Electron on a host that delivers the IM's forwarded keys in order with its commits (GNOME
// Wayland via IBus, KWin via Fcitx5's Wayland frontend), words are typed in place and fixed
// with forwarded BackSpace KEY events instead of delete-surrounding (which web editors like
// Draft.js / Lexical cannot follow). Off (default): those apps keep the preedit.
enum class NoUnderline { Off, ForwardKeys };

using ShortcutTable = std::map<std::string, std::string>;

struct Settings {
    // [typing] — defaults mirror the macOS app (AppState.swift)
    bool vni = false;
    bool simpleTelex = false;
    bool freeMarking = true;
    bool modernTone = false;
    bool quickTelex = false;
    bool spellCheck = true;
    bool autoRestore = true;
    bool teencode = false;
    // "Tự thêm dấu mũ" (auto_circumflex, default OFF; engine autoCircumflex, issue #166):
    // vietj → việt, benhj → bệnh when the plain rime is not a syllable but the hatted one is.
    bool autoCircumflex = false;
    bool contextualEnglish = true;
    // "Tự sửa từ phía trước" (retroactive_english, EXPERIMENTAL, default OFF; needs
    // contextual_english): on = "Hí cả í very fast" → "His car is very fast" at the boundary,
    // ⌫ next reverts it; off = offered as a caret suggestion, Tab applies (retro_english.h).
    bool retroactiveEnglish = false;
    // "Đoán từ trùng theo tần suất" (english_by_frequency, EXPERIMENTAL, default OFF; engine
    // englishByFrequency; needs contextual_english like retroactive_english): his → "His" at
    // the start of a phrase, flipped back automatically when the next word shows Vietnamese
    // ("hí hửng", "hí hí") — also in offer mode and before Enter.
    bool englishByFrequency = false;
    bool collisionPrefersVietnamese = true;
    bool bracketVowels = false;
    bool shortcutsEnabled = true;
    bool reEditWord = true;
    // [general]
    DisplayMode displayMode = DisplayMode::Preedit;  // Preedit | Surrounding only
    bool preeditUnderline = false;  // "Hiện gạch chân chữ đang gõ" (clients that honour attributes)
    // "Gạch đỏ âm tiết sai chính tả khi gõ": preedit of a word that cannot become a syllable
    // gets the error style (IBus: error underline + red text; Fcitx5: underline). Preedit only.
    bool underlineMisspelled = false;
    bool terminalDirect = true;     // terminals on ordered hosts: Direct instead of Preedit
    std::string toggleHotkey = "Ctrl+space";
    // "Bấm Ctrl một mình để chốt từ đang gõ" (#180): a lone Ctrl tap commits the composition,
    // so the app sees the text (mention pickers in web apps only read committed text). Off by
    // default.
    bool ctrlCommitsWord = false;
    bool perAppState = true;
    // "Phát tiếng khi đổi Việt/Anh" (switch_sound, default OFF): switch_sound.h.
    bool switchSound = false;
    bool defaultVietnamese = true;
    // UI language of the IM menu + settings app: "vi" (DEFAULT, whatever the system locale
    // is) | "en". Anything else reads as "vi".
    std::string uiLanguage = "vi";
    bool textToolsMenu = true;        // "Công cụ…" submenu (text tools) in the IM menu
    std::string addTonesHotkey;       // "Thêm dấu cho vùng chọn" hotkey; "" = off (default)
    // Caret suggestions (caret_hints.h) — defaults = macOS 1.8.2. Tab applies, never automatic.
    bool mathResults = true;          // "12*3=" → "= 36"
    bool numberChips = true;          // "1tr2␣" → "1.200.000 ₫"
    bool typoHints = true;            // "tpoi␣" → "tôi"
    bool toneHints = false;           // "toi di hoc." → "tôi đi học."
    bool dateHints = true;            // "hôm nay␣" → "28/09/2026", "bây giờ␣" → "21:35"
    // Auto text (macOS follows its Text Input settings; Linux has none → VietTelex switches,
    // all OFF by default: Linux users type in terminals / code a lot). See auto_text.h.
    bool doubleSpacePeriod = false;   // double_space_period: "chào␣␣" → "chào. "
    bool autoCapitalize = false;      // auto_capitalize: first letter of a sentence
    bool smartPunctuation = false;    // smart_punctuation: " ' → “ ” ‘ ’, "--" → "—"
    std::string quoteStyle = "curly"; // quote_style: "curly" “”‘’ | "low9" „“‚‘ | "guillemets" «»‹›
    bool wordPrediction = false;      // word_prediction: complete the word / next word (Tab)
    bool filterSensitive = true;      // filter_sensitive: "Lọc từ nhạy cảm" (iOS/macOS; default on)
    bool learnWords = true;           // learn_words: "Học từ bạn gõ" (iOS/macOS; default on, needs word_prediction)
    // [app_modes] app id (lowercase) -> "preedit" | "surrounding" | "direct" | "off"
    std::map<std::string, std::string> appModes;
    // [experimental]
    NoUnderline noUnderline = NoUnderline::Off;  // no_underline = "off" | "forward-keys"
    // shortcuts.yml (never null after load)
    std::shared_ptr<const ShortcutTable> shortcuts = std::make_shared<ShortcutTable>();
};

// config.toml subset → Settings. Unknown keys / bad values fall back to defaults.
Settings parseConfig(const std::string &toml);
// Sets `key = literal` inside [section] of an existing config.toml text, preserving every
// other line (comments, unknown keys); appends the key/section when missing.
// `literal` is already TOML (`true`, `"vni"`).
std::string setConfigValue(const std::string &toml, const std::string &section, const std::string &key,
                           const std::string &literal);
// Settings → config.toml (canonical form, used by tests and as a reference writer).
std::string serializeConfig(const Settings &s);

// shortcuts.yml (flat YAML, same rules as macOS ShortcutImporter line parser).
ShortcutTable parseShortcuts(const std::string &yaml);
std::string exportShortcuts(const ShortcutTable &t);
// Symbol / digit keys ("=>", "<>", "->", ":D", "k2"): not letters only (ASCII, Latin-1 /
// Extended-A/B, combining marks, the Vietnamese block). The engine never composes them as
// one word (Telex: = < > - : and digits end a word), so they are matched against the run of
// non-whitespace text before the caret at a whitespace boundary (Session::tryTokenShortcut,
// macOS ShortcutTable.tokenExpansion).
bool isTokenShortcutKey(const std::string &utf8Key);
// Expansion for `typed` with the case of the typing carried over (macOS / iOS / Android
// ShortcutTable.expansion): the key exactly as typed first; else a lowercase key — "Ko" ->
// first letter capitalized ("Không"), "KO" (>= 2 letters, all caps) -> all caps ("KHÔNG"),
// mixed case ("kO") -> no match. Case mapping: ASCII, Latin-1, Latin Extended-A, Ơ Ư, the
// Vietnamese block. (2026-11: before, only the exact key matched — "Ko" never expanded.)
bool shortcutExpansion(const ShortcutTable &t, const std::string &typed, std::string &out);

// Hotkey "Ctrl+Shift+space". Returns false for an empty/invalid string.
struct Hotkey {
    uint32_t keysym = 0;  // lowercase keysym
    uint32_t mods = 0;    // VT_MOD_* bits (keys.h)
};
bool parseHotkey(const std::string &s, Hotkey &out);

// Paths ($XDG_CONFIG_HOME / $XDG_STATE_HOME aware).
std::string configDir();                // …/viettelex
std::string configPath();               // …/viettelex/config.toml
std::string shortcutsPath();            // …/viettelex/shortcuts.yml
std::string stateDir();                 // …/viettelex (state)
std::string appStatePath();             // …/viettelex/app-state

bool readFile(const std::string &path, std::string &out);
bool writeFileAtomic(const std::string &path, const std::string &data);  // tmp + rename
bool mkdirs(const std::string &dir);

// Loads config.toml + shortcuts.yml from the config dir (missing files = defaults).
Settings loadSettings(const std::string &dir);

}  // namespace viettelex
