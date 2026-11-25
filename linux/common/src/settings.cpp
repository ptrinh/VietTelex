// settings.cpp — see settings.h / SETTINGS.md.
#include "viettelex/settings.h"

#include "viettelex/keys.h"

#include <cerrno>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <sstream>
#include <sys/stat.h>
#include <unistd.h>
#include <vector>

namespace viettelex {

namespace {

std::string trim(const std::string &s) {
    size_t b = 0, e = s.size();
    while (b < e && (s[b] == ' ' || s[b] == '\t' || s[b] == '\r')) ++b;
    while (e > b && (s[e - 1] == ' ' || s[e - 1] == '\t' || s[e - 1] == '\r')) --e;
    return s.substr(b, e - b);
}

std::string lower(std::string s) {
    for (auto &c : s)
        if (c >= 'A' && c <= 'Z') c = char(c - 'A' + 'a');
    return s;
}

// Parse a TOML basic string starting at s[i] == '"'. Sets `end` past the closing quote.
bool parseQuoted(const std::string &s, size_t i, std::string &out, size_t &end) {
    if (i >= s.size() || s[i] != '"') return false;
    out.clear();
    for (size_t k = i + 1; k < s.size(); ++k) {
        char c = s[k];
        if (c == '\\' && k + 1 < s.size()) {
            char n = s[++k];
            switch (n) {
            case 'n': out += '\n'; break;
            case 't': out += '\t'; break;
            case '"': out += '"'; break;
            case '\\': out += '\\'; break;
            default: out += n; break;
            }
        } else if (c == '"') {
            end = k + 1;
            return true;
        } else {
            out += c;
        }
    }
    return false;
}

std::string quote(const std::string &v) {
    std::string o = "\"";
    for (char c : v) {
        switch (c) {
        case '"': o += "\\\""; break;
        case '\\': o += "\\\\"; break;
        case '\n': o += "\\n"; break;
        case '\t': o += "\\t"; break;
        default: o += c;
        }
    }
    return o + "\"";
}

struct Value {
    enum { None, Bool, Str, Int } kind = None;
    bool b = false;
    std::string s;
};

Value parseValue(const std::string &raw) {
    Value v;
    std::string t = trim(raw);
    if (t.empty()) return v;
    if (t[0] == '"') {
        size_t end = 0;
        if (parseQuoted(t, 0, v.s, end)) v.kind = Value::Str;
        return v;
    }
    // strip trailing comment for bare values
    size_t hash = t.find('#');
    if (hash != std::string::npos) t = trim(t.substr(0, hash));
    if (t == "true") { v.kind = Value::Bool; v.b = true; }
    else if (t == "false") { v.kind = Value::Bool; v.b = false; }
    else if (!t.empty() && (isdigit((unsigned char)t[0]) || t[0] == '-')) { v.kind = Value::Int; v.s = t; }
    return v;
}

void setBool(bool &dst, const Value &v) {
    if (v.kind == Value::Bool) dst = v.b;
}

bool isWhitespace(char c) { return c == ' ' || c == '\t' || c == '\r' || c == '\n'; }

size_t utf8Count(const std::string &s) {
    size_t n = 0;
    for (unsigned char c : s)
        if ((c & 0xc0) != 0x80) ++n;
    return n;
}

bool startsWith(const std::string &s, const char *p) { return s.rfind(p, 0) == 0; }

std::string envOr(const char *var, const std::string &fallbackUnderHome) {
    const char *v = std::getenv(var);
    if (v && *v) return v;
    const char *home = std::getenv("HOME");
    return std::string(home ? home : "") + "/" + fallbackUnderHome;
}

}  // namespace

// MARK: - config.toml

Settings parseConfig(const std::string &toml) {
    Settings s;
    std::istringstream in(toml);
    std::string line, section;
    while (std::getline(in, line)) {
        std::string t = trim(line);
        if (t.empty() || t[0] == '#') continue;
        if (t[0] == '[') {
            size_t close = t.find(']');
            if (close != std::string::npos) section = trim(t.substr(1, close - 1));
            continue;
        }
        // key
        std::string key;
        size_t pos;
        if (t[0] == '"') {
            size_t end = 0;
            if (!parseQuoted(t, 0, key, end)) continue;
            pos = t.find('=', end);
        } else {
            pos = t.find('=');
            if (pos == std::string::npos) continue;
            key = trim(t.substr(0, pos));
        }
        if (pos == std::string::npos) continue;
        Value v = parseValue(t.substr(pos + 1));
        if (section == "typing") {
            if (key == "input_method") {
                if (v.kind == Value::Str) s.vni = lower(v.s) == "vni";
            }
            else if (key == "simple_telex") setBool(s.simpleTelex, v);
            else if (key == "free_marking") setBool(s.freeMarking, v);
            else if (key == "modern_tone") setBool(s.modernTone, v);
            else if (key == "quick_telex") setBool(s.quickTelex, v);
            else if (key == "spell_check") setBool(s.spellCheck, v);
            else if (key == "auto_restore") setBool(s.autoRestore, v);
            else if (key == "teencode") setBool(s.teencode, v);
            else if (key == "auto_circumflex") setBool(s.autoCircumflex, v);
            else if (key == "contextual_english") setBool(s.contextualEnglish, v);
            else if (key == "retroactive_english") setBool(s.retroactiveEnglish, v);
            else if (key == "english_by_frequency") setBool(s.englishByFrequency, v);
            else if (key == "collision_prefers_vietnamese") setBool(s.collisionPrefersVietnamese, v);
            else if (key == "bracket_vowels") setBool(s.bracketVowels, v);
            else if (key == "shortcuts_enabled") setBool(s.shortcutsEnabled, v);
            else if (key == "re_edit_word") setBool(s.reEditWord, v);
        } else if (section == "general") {
            if (key == "display_mode") {
                if (v.kind == Value::Str) {
                    std::string m = lower(v.s);
                    if (m == "surrounding") s.displayMode = DisplayMode::Surrounding;
                    else if (m == "preedit") s.displayMode = DisplayMode::Preedit;
                }
            } else if (key == "toggle_hotkey") {
                if (v.kind == Value::Str) s.toggleHotkey = v.s;
            }
            else if (key == "preedit_underline") setBool(s.preeditUnderline, v);
            else if (key == "underline_misspelled") setBool(s.underlineMisspelled, v);
            else if (key == "terminal_direct") setBool(s.terminalDirect, v);
            else if (key == "ctrl_commits_word") setBool(s.ctrlCommitsWord, v);
            else if (key == "per_app_state") setBool(s.perAppState, v);
            else if (key == "switch_sound") setBool(s.switchSound, v);
            else if (key == "default_vietnamese") setBool(s.defaultVietnamese, v);
            else if (key == "ui_language") {
                if (v.kind == Value::Str) s.uiLanguage = lower(trim(v.s)) == "en" ? "en" : "vi";
            }
            else if (key == "text_tools_menu") setBool(s.textToolsMenu, v);
            else if (key == "math_results") setBool(s.mathResults, v);
            else if (key == "number_chips") setBool(s.numberChips, v);
            else if (key == "typo_hints") setBool(s.typoHints, v);
            else if (key == "tone_hints") setBool(s.toneHints, v);
            else if (key == "date_hints") setBool(s.dateHints, v);
            else if (key == "double_space_period") setBool(s.doubleSpacePeriod, v);
            else if (key == "auto_capitalize") setBool(s.autoCapitalize, v);
            else if (key == "smart_punctuation") setBool(s.smartPunctuation, v);
            else if (key == "quote_style") {
                if (v.kind == Value::Str) {
                    std::string q = lower(trim(v.s));
                    if (q == "curly" || q == "low9" || q == "guillemets") s.quoteStyle = q;
                }
            }
            else if (key == "word_prediction") setBool(s.wordPrediction, v);
            else if (key == "filter_sensitive") setBool(s.filterSensitive, v);
            else if (key == "learn_words") setBool(s.learnWords, v);
            else if (key == "add_tones_hotkey") {
                if (v.kind == Value::Str) s.addTonesHotkey = v.s;
            }
        } else if (section == "experimental") {
            if (key == "no_underline" && v.kind == Value::Str) {
                std::string m = lower(trim(v.s));
                s.noUnderline = m == "forward-keys" ? NoUnderline::ForwardKeys : NoUnderline::Off;
            }
        } else if (section == "app_modes") {
            if (v.kind == Value::Str && !key.empty()) {
                std::string m = lower(v.s);
                if (m == "preedit" || m == "surrounding" || m == "direct" || m == "off") s.appModes[lower(key)] = m;
            }
        }
    }
    return s;
}

std::string serializeConfig(const Settings &s) {
    auto b = [](bool v) { return v ? "true" : "false"; };
    std::ostringstream o;
    o << "[typing]\n"
      << "input_method = " << (s.vni ? "\"vni\"" : "\"telex\"") << "\n"
      << "simple_telex = " << b(s.simpleTelex) << "\n"
      << "free_marking = " << b(s.freeMarking) << "\n"
      << "modern_tone = " << b(s.modernTone) << "\n"
      << "quick_telex = " << b(s.quickTelex) << "\n"
      << "spell_check = " << b(s.spellCheck) << "\n"
      << "auto_restore = " << b(s.autoRestore) << "\n"
      << "teencode = " << b(s.teencode) << "\n"
      << "auto_circumflex = " << b(s.autoCircumflex) << "\n"
      << "contextual_english = " << b(s.contextualEnglish) << "\n"
      << "retroactive_english = " << b(s.retroactiveEnglish) << "\n"
      << "english_by_frequency = " << b(s.englishByFrequency) << "\n"
      << "collision_prefers_vietnamese = " << b(s.collisionPrefersVietnamese) << "\n"
      << "bracket_vowels = " << b(s.bracketVowels) << "\n"
      << "shortcuts_enabled = " << b(s.shortcutsEnabled) << "\n"
      << "re_edit_word = " << b(s.reEditWord) << "\n"
      << "\n[general]\n"
      << "display_mode = " << (s.displayMode == DisplayMode::Surrounding ? "\"surrounding\"" : "\"preedit\"") << "\n"
      << "preedit_underline = " << b(s.preeditUnderline) << "\n"
      << "underline_misspelled = " << b(s.underlineMisspelled) << "\n"
      << "terminal_direct = " << b(s.terminalDirect) << "\n"
      << "toggle_hotkey = " << quote(s.toggleHotkey) << "\n"
      << "ctrl_commits_word = " << b(s.ctrlCommitsWord) << "\n"
      << "per_app_state = " << b(s.perAppState) << "\n"
      << "switch_sound = " << b(s.switchSound) << "\n"
      << "default_vietnamese = " << b(s.defaultVietnamese) << "\n"
      << "ui_language = " << quote(s.uiLanguage == "en" ? "en" : "vi") << "\n"
      << "text_tools_menu = " << b(s.textToolsMenu) << "\n"
      << "add_tones_hotkey = " << quote(s.addTonesHotkey) << "\n"
      << "math_results = " << b(s.mathResults) << "\n"
      << "number_chips = " << b(s.numberChips) << "\n"
      << "typo_hints = " << b(s.typoHints) << "\n"
      << "tone_hints = " << b(s.toneHints) << "\n"
      << "date_hints = " << b(s.dateHints) << "\n"
      << "double_space_period = " << b(s.doubleSpacePeriod) << "\n"
      << "auto_capitalize = " << b(s.autoCapitalize) << "\n"
      << "smart_punctuation = " << b(s.smartPunctuation) << "\n"
      << "quote_style = " << quote(s.quoteStyle) << "\n"
      << "word_prediction = " << b(s.wordPrediction) << "\n"
      << "filter_sensitive = " << b(s.filterSensitive) << "\n"
      << "learn_words = " << b(s.learnWords) << "\n"
      << "\n[experimental]\n"
      << "no_underline = " << (s.noUnderline == NoUnderline::ForwardKeys ? "\"forward-keys\"" : "\"off\"") << "\n"
      << "\n[app_modes]\n";
    for (auto &kv : s.appModes) o << quote(kv.first) << " = " << quote(kv.second) << "\n";
    return o.str();
}

std::string setConfigValue(const std::string &toml, const std::string &section, const std::string &key,
                           const std::string &literal) {
    std::vector<std::string> lines;
    {
        std::istringstream in(toml);
        std::string l;
        while (std::getline(in, l)) lines.push_back(l);
    }
    std::string cur;
    int sectionStart = -1, sectionEnd = -1;  // [start, end) line indexes of the section body
    for (size_t i = 0; i < lines.size(); ++i) {
        std::string t = trim(lines[i]);
        if (!t.empty() && t[0] == '[') {
            if (cur == section && sectionEnd < 0) sectionEnd = int(i);
            size_t close = t.find(']');
            cur = close == std::string::npos ? "" : trim(t.substr(1, close - 1));
            if (cur == section && sectionStart < 0) sectionStart = int(i) + 1;
            continue;
        }
        if (cur != section || t.empty() || t[0] == '#') continue;
        std::string k;
        size_t eq;
        if (t[0] == '"') {
            size_t end = 0;
            if (!parseQuoted(t, 0, k, end)) continue;
            eq = t.find('=', end);
        } else {
            eq = t.find('=');
            if (eq == std::string::npos) continue;
            k = trim(t.substr(0, eq));
        }
        if (eq != std::string::npos && k == key) {
            std::string keyText = (key.find_first_of(" .\"") != std::string::npos) ? quote(key) : key;
            lines[i] = keyText + " = " + literal;
            std::string out;
            for (auto &x : lines) out += x + "\n";
            return out;
        }
    }
    if (cur == section && sectionEnd < 0) sectionEnd = int(lines.size());
    std::string keyText = (key.find_first_of(" .\"") != std::string::npos) ? quote(key) : key;
    std::string newLine = keyText + " = " + literal;
    if (sectionStart < 0) {
        if (!lines.empty() && !trim(lines.back()).empty()) lines.push_back("");
        lines.push_back("[" + section + "]");
        lines.push_back(newLine);
    } else {
        // insert after the last non-blank line of the section
        int at = sectionEnd;
        while (at > sectionStart && trim(lines[size_t(at - 1)]).empty()) --at;
        lines.insert(lines.begin() + at, newLine);
    }
    std::string out;
    for (auto &x : lines) out += x + "\n";
    return out;
}

// MARK: - shortcuts.yml

bool isTokenShortcutKey(const std::string &k) {
    if (k.empty()) return false;
    for (size_t i = 0; i < k.size();) {
        const unsigned char b = static_cast<unsigned char>(k[i]);
        uint32_t cp;
        size_t n;
        if (b < 0x80) { cp = b; n = 1; }
        else if ((b >> 5) == 6) { cp = b & 0x1f; n = 2; }
        else if ((b >> 4) == 14) { cp = b & 0x0f; n = 3; }
        else { cp = b & 0x07; n = 4; }
        for (size_t j = 1; j < n && i + j < k.size(); ++j) cp = (cp << 6) | (static_cast<unsigned char>(k[i + j]) & 0x3f);
        i += n;
        const bool letter = (cp >= 'a' && cp <= 'z') || (cp >= 'A' && cp <= 'Z') ||
                            (cp >= 0xc0 && cp <= 0x24f && cp != 0xd7 && cp != 0xf7) ||
                            (cp >= 0x300 && cp <= 0x36f) || (cp >= 0x1e00 && cp <= 0x1eff);
        if (!letter) return true;
    }
    return false;
}

namespace {

std::vector<uint32_t> scDecode(const std::string &s) {
    std::vector<uint32_t> out;
    for (size_t i = 0; i < s.size();) {
        const unsigned char b = static_cast<unsigned char>(s[i]);
        uint32_t cp;
        size_t n;
        if (b < 0x80) { cp = b; n = 1; }
        else if ((b >> 5) == 6) { cp = b & 0x1f; n = 2; }
        else if ((b >> 4) == 14) { cp = b & 0x0f; n = 3; }
        else { cp = b & 0x07; n = 4; }
        for (size_t j = 1; j < n && i + j < s.size(); ++j) cp = (cp << 6) | (static_cast<unsigned char>(s[i + j]) & 0x3f);
        i += n;
        out.push_back(cp);
    }
    return out;
}

std::string scEncode(const std::vector<uint32_t> &cps) {
    std::string o;
    for (uint32_t c : cps) {
        if (c < 0x80) {
            o += char(c);
        } else if (c < 0x800) {
            o += char(0xc0 | (c >> 6));
            o += char(0x80 | (c & 0x3f));
        } else if (c < 0x10000) {
            o += char(0xe0 | (c >> 12));
            o += char(0x80 | ((c >> 6) & 0x3f));
            o += char(0x80 | (c & 0x3f));
        } else {
            o += char(0xf0 | (c >> 18));
            o += char(0x80 | ((c >> 12) & 0x3f));
            o += char(0x80 | ((c >> 6) & 0x3f));
            o += char(0x80 | (c & 0x3f));
        }
    }
    return o;
}

uint32_t scLower(uint32_t c) {
    if (c >= 'A' && c <= 'Z') return c + 32;
    if (c >= 0xC0 && c <= 0xDE && c != 0xD7) return c + 0x20;
    if (c >= 0x100 && c <= 0x137 && c != 0x130 && (c % 2) == 0) return c + 1;
    if (c >= 0x139 && c <= 0x148 && (c % 2) == 1) return c + 1;
    if (c >= 0x14A && c <= 0x177 && (c % 2) == 0) return c + 1;
    if (c == 0x178) return 0xFF;
    if (c >= 0x179 && c <= 0x17E && (c % 2) == 1) return c + 1;
    if (c == 0x1A0) return 0x1A1;  // Ơ
    if (c == 0x1AF) return 0x1B0;  // Ư
    if (((c >= 0x1E00 && c <= 0x1E95) || (c >= 0x1EA0 && c <= 0x1EFF)) && (c % 2) == 0) return c + 1;
    return c;
}

uint32_t scUpper(uint32_t c) {
    if (c >= 'a' && c <= 'z') return c - 32;
    if (c >= 0xE0 && c <= 0xFE && c != 0xF7) return c - 0x20;
    if (c == 0xFF) return 0x178;
    if (c >= 0x101 && c <= 0x137 && c != 0x131 && (c % 2) == 1) return c - 1;
    if (c >= 0x13A && c <= 0x148 && (c % 2) == 0) return c - 1;
    if (c >= 0x14B && c <= 0x177 && (c % 2) == 1) return c - 1;
    if (c >= 0x17A && c <= 0x17E && (c % 2) == 0) return c - 1;
    if (c == 0x1A1) return 0x1A0;  // ơ
    if (c == 0x1B0) return 0x1AF;  // ư
    if (((c >= 0x1E01 && c <= 0x1E95) || (c >= 0x1EA1 && c <= 0x1EFF)) && (c % 2) == 1) return c - 1;
    return c;
}

bool scLetter(uint32_t cp) {
    return (cp >= 'a' && cp <= 'z') || (cp >= 'A' && cp <= 'Z') || (cp >= 0xc0 && cp <= 0x24f && cp != 0xd7 && cp != 0xf7) ||
           (cp >= 0x300 && cp <= 0x36f) || (cp >= 0x1e00 && cp <= 0x1eff);
}

}  // namespace

bool shortcutExpansion(const ShortcutTable &t, const std::string &typed, std::string &out) {
    if (typed.empty()) return false;
    auto it = t.find(typed);
    if (it != t.end()) {
        out = it->second;
        return true;
    }
    const std::vector<uint32_t> cps = scDecode(typed);
    std::vector<uint32_t> low(cps), up(cps), letters;
    for (auto &c : low) c = scLower(c);
    for (auto &c : up) c = scUpper(c);
    if (low == cps) return false;
    it = t.find(scEncode(low));
    if (it == t.end()) return false;
    for (uint32_t c : cps)
        if (scLetter(c)) letters.push_back(c);
    std::vector<uint32_t> e = scDecode(it->second);
    if (letters.empty()) {
        out = it->second;
        return true;
    }
    if (letters.size() >= 2 && up == cps) {  // KO -> KHÔNG
        for (auto &c : e) c = scUpper(c);
        out = scEncode(e);
        return true;
    }
    bool restLower = true;
    for (size_t i = 1; i < letters.size(); ++i) restLower = restLower && scLower(letters[i]) == letters[i];
    if (scLower(letters[0]) != letters[0] && restLower) {  // Ko -> Không
        if (!e.empty()) e[0] = scUpper(e[0]);
        out = scEncode(e);
        return true;
    }
    return false;  // kO: mixed case
}

// Port 1:1 of macOS ShortcutImporter (App/Sources/AppState.swift): a key containing ':' or
// starting with # ; // " ' is written double-quoted; a double-quoted value is escaped
// (\\ \" \n) and unescaped on read (\n \t \\ \"). Files written by either side round-trip on
// the other; old unquoted files read as before.
namespace {

std::string scEscape(const std::string &s) {
    std::string out;
    for (size_t i = 0; i < s.size(); ++i) {
        char c = s[i];
        if (c == '\\') out += "\\\\";
        else if (c == '"') out += "\\\"";
        else if (c == '\r') {
            if (i + 1 < s.size() && s[i + 1] == '\n') ++i;
            out += "\\n";
        } else if (c == '\n') out += "\\n";
        else out += c;
    }
    return out;
}

std::string scUnescape(const std::string &s) {
    if (s.find('\\') == std::string::npos) return s;
    std::string out;
    for (size_t i = 0; i < s.size(); ++i) {
        char c = s[i];
        if (c != '\\') { out += c; continue; }
        if (i + 1 >= s.size()) { out += '\\'; break; }
        char n = s[++i];
        switch (n) {
        case 'n': out += '\n'; break;
        case 't': out += '\t'; break;
        case '\\': out += '\\'; break;
        case '"': out += '"'; break;
        default: out += '\\'; out += n;
        }
    }
    return out;
}

// `"…"` at the start of `s` → unescaped content + index past the closing quote.
bool scQuotedPrefix(const std::string &s, std::string &out, size_t &after) {
    std::string raw;
    for (size_t i = 1; i < s.size(); ++i) {
        char c = s[i];
        if (c == '\\') {
            if (i + 1 >= s.size()) return false;
            raw += c;
            raw += s[++i];
            continue;
        }
        if (c == '"') {
            out = scUnescape(raw);
            after = i + 1;
            return true;
        }
        raw += c;
    }
    return false;
}


std::string scQuoteKey(const std::string &k) {
    bool needs = k.find(':') != std::string::npos || startsWith(k, "#") || startsWith(k, ";") ||
                 startsWith(k, "//") || startsWith(k, "\"") || startsWith(k, "'");
    return needs ? "\"" + scEscape(k) + "\"" : k;
}

std::string scQuoteValue(const std::string &v) {
    if (v.find('\n') != std::string::npos || v.find('\r') != std::string::npos) return "\"" + scEscape(v) + "\"";
    bool needs = !v.empty() && (v.front() == ' ' || v.back() == ' ' || v.front() == '\'' ||
                                v.front() == '"' || v.front() == '#');
    return needs ? "\"" + scEscape(v) + "\"" : v;
}

}  // namespace

ShortcutTable parseShortcuts(const std::string &yamlIn) {
    ShortcutTable out;
    const std::string yaml = startsWith(yamlIn, "\xEF\xBB\xBF") ? yamlIn.substr(3) : yamlIn;
    size_t pos = 0;
    while (pos < yaml.size()) {
        size_t nl = yaml.find_first_of("\r\n", pos);
        std::string raw = yaml.substr(pos, nl == std::string::npos ? std::string::npos : nl - pos);
        if (nl == std::string::npos) pos = yaml.size();
        else pos = (yaml[nl] == '\r' && nl + 1 < yaml.size() && yaml[nl + 1] == '\n') ? nl + 2 : nl + 1;
        std::string line = trim(raw);
        if (line.empty() || line[0] == ';' || line[0] == '#' || startsWith(line, "//")) continue;
        std::string key, rest, quotedKey;
        size_t after = 0;
        if (line[0] == '"' && scQuotedPrefix(line, quotedKey, after)) {
            size_t r = after;
            while (r < line.size() && (line[r] == ' ' || line[r] == '\t')) ++r;
            if (r >= line.size() || line[r] != ':') continue;
            key = quotedKey;
            rest = line.substr(r + 1);
        } else {
            size_t colon = line.find(':');
            if (colon == std::string::npos) continue;
            key = line.substr(0, colon);
            rest = line.substr(colon + 1);
        }
        key = trim(key);
        std::string value = trim(rest);
        if (utf8Count(value) >= 2 && value.front() == '"' && value.back() == '"')
            value = scUnescape(value.substr(1, value.size() - 2));
        else if (utf8Count(value) >= 2 && value.front() == '\'' && value.back() == '\'')
            value = value.substr(1, value.size() - 2);
        if (key.empty() || value.empty() || utf8Count(key) > 64) continue;
        bool ws = false;
        for (char c : key) ws |= isWhitespace(c);
        if (ws) continue;
        out[key] = value;
    }
    return out;
}

std::string exportShortcuts(const ShortcutTable &t) {
    std::string out = "# VietTelex — bảng gõ tắt\n";
    for (auto &kv : t)  // std::map: sorted by key (byte order, like Swift's sorted())
        out += scQuoteKey(kv.first) + ": " + scQuoteValue(kv.second) + "\n";
    return out;
}

// MARK: - hotkey

bool parseHotkey(const std::string &spec, Hotkey &out) {
    std::string s = trim(spec);
    if (s.empty()) return false;
    std::vector<std::string> parts;
    size_t start = 0;
    // split on '+', but a trailing "+" key ("Ctrl++") is the plus key
    for (size_t i = 0; i < s.size(); ++i) {
        if (s[i] == '+' && i > start) { parts.push_back(s.substr(start, i - start)); start = i + 1; }
    }
    parts.push_back(s.substr(start));
    Hotkey hk;
    for (size_t i = 0; i + 1 < parts.size(); ++i) {
        std::string m = lower(trim(parts[i]));
        uint32_t bit;
        if (m == "ctrl" || m == "control") bit = VT_MOD_CTRL;
        else if (m == "alt") bit = VT_MOD_ALT;
        else if (m == "shift") bit = VT_MOD_SHIFT;
        else if (m == "super" || m == "meta") bit = VT_MOD_SUPER;
        else return false;
        if (hk.mods & bit) return false;  // "Ctrl+Ctrl+a" (settings app rejects it too)
        hk.mods |= bit;
    }
    std::string key = trim(parts.back());
    std::string lk = lower(key);
    // X keysym names (lowercased). The settings app stores the keysym GTK reports, which is
    // the keysym the frontend later receives — Ctrl+Shift+2 on a US layout is
    // "Ctrl+Shift+at" — so every printable ASCII keysym name is here. The settings app
    // mirrors this table (config.HOTKEY_NAMES; a test compares the two).
    static const std::map<std::string, uint32_t> names = {
        {"space", 0x20}, {"grave", 0x60}, {"tab", ks::Tab}, {"return", ks::Return},
        {"escape", ks::Escape}, {"backspace", ks::BackSpace}, {"comma", ','}, {"period", '.'},
        {"slash", '/'}, {"semicolon", ';'}, {"apostrophe", '\''}, {"minus", '-'}, {"equal", '='},
        {"bracketleft", '['}, {"bracketright", ']'}, {"backslash", '\\'}, {"plus", '+'},
        {"exclam", '!'}, {"quotedbl", '"'}, {"numbersign", '#'}, {"dollar", '$'},
        {"percent", '%'}, {"ampersand", '&'}, {"parenleft", '('}, {"parenright", ')'},
        {"asterisk", '*'}, {"colon", ':'}, {"less", '<'}, {"greater", '>'}, {"question", '?'},
        {"at", '@'}, {"asciicircum", '^'}, {"underscore", '_'}, {"braceleft", '{'},
        {"bar", '|'}, {"braceright", '}'}, {"asciitilde", '~'},
        {"left", ks::Left}, {"right", ks::Right}, {"up", ks::Up}, {"down", ks::Down},
    };
    auto it = names.find(lk);
    if (it != names.end()) hk.keysym = it->second;
    else if (key.size() == 1 && (unsigned char)key[0] > 0x20 && (unsigned char)key[0] < 0x7f)
        hk.keysym = (uint32_t)(unsigned char)lower(key)[0];
    else if ((lk.size() == 2 || lk.size() == 3) && lk[0] == 'f' && isdigit((unsigned char)lk[1]) &&
             (lk.size() == 2 || isdigit((unsigned char)lk[2]))) {
        int n = std::atoi(lk.c_str() + 1);
        if (n < 1 || n > 24) return false;
        hk.keysym = 0xffbe + uint32_t(n - 1);  // XK_F1
    } else return false;
    // Super+space belongs to GNOME's input-source switcher (spec §4/§6).
    if (hk.keysym == 0x20 && hk.mods == VT_MOD_SUPER) return false;
    // A printable key needs Ctrl/Alt/Super: bare or Shift-only ("Shift+a") would eat typing
    // (capital A). Without any modifier only F1–F24 (a bare Tab / Return / arrow would too).
    bool printable = hk.keysym >= 0x20 && hk.keysym < 0x7f;
    if (printable && !(hk.mods & (VT_MOD_CTRL | VT_MOD_ALT | VT_MOD_SUPER))) return false;
    if (hk.mods == 0 && !(hk.keysym >= 0xffbe && hk.keysym <= 0xffd5)) return false;
    out = hk;
    return true;
}

// MARK: - files

std::string configDir() { return envOr("XDG_CONFIG_HOME", ".config") + "/viettelex"; }
std::string configPath() { return configDir() + "/config.toml"; }
std::string shortcutsPath() { return configDir() + "/shortcuts.yml"; }
std::string stateDir() { return envOr("XDG_STATE_HOME", ".local/state") + "/viettelex"; }
std::string appStatePath() { return stateDir() + "/app-state"; }

bool readFile(const std::string &path, std::string &out) {
    std::ifstream f(path, std::ios::binary);
    if (!f) return false;
    std::ostringstream ss;
    ss << f.rdbuf();
    out = ss.str();
    return true;
}

bool mkdirs(const std::string &dir) {
    if (dir.empty()) return false;
    std::string cur;
    for (size_t i = 0; i <= dir.size(); ++i) {
        if (i == dir.size() || dir[i] == '/') {
            if (!cur.empty() && ::mkdir(cur.c_str(), 0700) != 0 && errno != EEXIST) return false;
        }
        if (i < dir.size()) cur += dir[i];
    }
    return true;
}

bool writeFileAtomic(const std::string &pathIn, const std::string &data) {
    // A symlinked config.toml (dotfiles repo) stays a symlink: write through to its target.
    std::string path = pathIn;
    if (char *real = ::realpath(pathIn.c_str(), nullptr)) {
        path = real;
        std::free(real);
    }
    size_t slash = path.rfind('/');
    if (slash != std::string::npos) mkdirs(path.substr(0, slash));
    // Unique temp name: the settings app and the Fcitx5 dialog may write at the same time.
    std::string tmpl = path + ".XXXXXX";
    std::vector<char> buf(tmpl.begin(), tmpl.end());
    buf.push_back('\0');
    int fd = ::mkstemp(buf.data());
    if (fd < 0) return false;
    const std::string tmp(buf.data());
    struct stat st;
    mode_t mode = 0644;
    if (::stat(path.c_str(), &st) == 0) mode = st.st_mode & 07777;
    else {
        mode_t um = ::umask(0);
        ::umask(um);
        mode = 0666 & ~um;
    }
    (void)::fchmod(fd, mode);  // best effort: mkstemp's 0600 is still safe
    bool ok = true;
    size_t off = 0;
    while (ok && off < data.size()) {
        ssize_t w = ::write(fd, data.data() + off, data.size() - off);
        if (w < 0 && errno == EINTR) continue;
        if (w <= 0) ok = false;
        else off += size_t(w);
    }
    if (ok && ::fsync(fd) != 0) ok = false;
    if (::close(fd) != 0) ok = false;
    if (ok && std::rename(tmp.c_str(), path.c_str()) == 0) return true;
    ::unlink(tmp.c_str());
    return false;
}

Settings loadSettings(const std::string &dir) {
    std::string text;
    Settings s = readFile(dir + "/config.toml", text) ? parseConfig(text) : Settings();
    std::string sc;
    if (readFile(dir + "/shortcuts.yml", sc)) s.shortcuts = std::make_shared<ShortcutTable>(parseShortcuts(sc));
    return s;
}

}  // namespace viettelex
