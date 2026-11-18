// golden_replay — replays android/telexcore/src/test/resources/golden.tsv(.gz) (the
// corpus `swift run gen-golden` writes from the macOS engine) through the C ABI of
// libtelexcore and requires a byte-identical line for every script.
//
// Usage: zcat golden.tsv.gz | golden_replay        (exit 0 = 100% parity)
// The runner is a line-for-line mirror of run() in TelexCore/Sources/GenGolden/main.swift.

#include "telexcore.h"

#include <cstdio>
#include <cstring>
#include <iostream>
#include <string>
#include <vector>

namespace {

std::vector<uint32_t> decode(const std::string &s) {
    std::vector<uint32_t> out;
    for (size_t i = 0; i < s.size();) {
        unsigned char c = s[i];
        uint32_t cp;
        int n;
        if (c < 0x80) { cp = c; n = 1; }
        else if ((c >> 5) == 6) { cp = c & 0x1f; n = 2; }
        else if ((c >> 4) == 14) { cp = c & 0x0f; n = 3; }
        else { cp = c & 0x07; n = 4; }
        for (int k = 1; k < n && i + k < s.size(); ++k) cp = (cp << 6) | (s[i + k] & 0x3f);
        out.push_back(cp);
        i += n;
    }
    return out;
}

void encode(uint32_t cp, std::string &o) {
    if (cp < 0x80) o += char(cp);
    else if (cp < 0x800) { o += char(0xc0 | (cp >> 6)); o += char(0x80 | (cp & 0x3f)); }
    else if (cp < 0x10000) {
        o += char(0xe0 | (cp >> 12)); o += char(0x80 | ((cp >> 6) & 0x3f)); o += char(0x80 | (cp & 0x3f));
    } else {
        o += char(0xf0 | (cp >> 18)); o += char(0x80 | ((cp >> 12) & 0x3f));
        o += char(0x80 | ((cp >> 6) & 0x3f)); o += char(0x80 | (cp & 0x3f));
    }
}

int flagFor(char c) {
    switch (c) {
    case 'F': return VT_FLAG_FREE_MARKING;
    case 'M': return VT_FLAG_MODERN_TONE;
    case 'L': return VT_FLAG_LIVE_SPELL_CHECK;
    case 'S': return VT_FLAG_SIMPLE_TELEX;
    case 't': return VT_FLAG_TEENCODE;          // "t" = teencode OFF
    case 'Q': return VT_FLAG_QUICK_TELEX;
    case 'B': return VT_FLAG_BRACKET_VOWELS;
    case 'V': return VT_FLAG_VNI;
    case 'C': return VT_FLAG_CONTEXTUAL_ENGLISH;
    case 'e': return VT_FLAG_ENGLISH_WORD_RESTORE; // "e" = OFF
    case 'P': return VT_FLAG_COLLISION_PREFERS_VIETNAMESE;
    case 'E': return VT_FLAG_EAGER_ENGLISH_RESTORE;
    default: return -1;
    }
}

std::string tok(const vt_action &a) {
    switch (a.kind) {
    case VT_ACTION_PASSTHROUGH: return "P";
    case VT_ACTION_NONE: return "N";
    default: return "R" + std::to_string(a.backspaces) + "," + std::string(a.insert, a.insert_len);
    }
}

std::string str(size_t (*fn)(const vt_engine *, char *, size_t), const vt_engine *e) {
    char buf[512];
    size_t n = fn(e, buf, sizeof buf);
    return std::string(buf, n < sizeof buf ? n : sizeof buf - 1);
}

void dropLast(std::vector<uint32_t> &screen, size_t n) {
    screen.resize(screen.size() - std::min(n, screen.size()));
}

void applyScreen(std::vector<uint32_t> &screen, const vt_action &a, bool hasLiteral, uint32_t literal) {
    switch (a.kind) {
    case VT_ACTION_PASSTHROUGH:
        if (hasLiteral) screen.push_back(literal); else dropLast(screen, 1);
        break;
    case VT_ACTION_NONE:
        if (!hasLiteral) dropLast(screen, 1);
        break;
    default: {
        dropLast(screen, size_t(a.backspaces));
        auto ins = decode(std::string(a.insert, a.insert_len));
        screen.insert(screen.end(), ins.begin(), ins.end());
    }
    }
}

std::string run(const std::string &flags, const std::string &opsUtf8) {
    vt_engine *e = vt_engine_new();
    bool autoRestore = false;
    for (char c : flags) {
        if (c == 'A') autoRestore = true;
        int f = flagFor(c);
        if (f < 0) continue;
        bool off = (c == 't' || c == 'e');
        vt_engine_set_flag(e, f, !off);
    }
    std::vector<std::string> trace;
    std::vector<uint32_t> screen;
    vt_action a;
    char buf[512];
    if (!opsUtf8.empty() && opsUtf8[0] == '@') {
        bool ok = vt_seed(e, opsUtf8.c_str() + 1);
        trace.push_back(ok ? "1" : "0");
        screen = decode(str(vt_composed, e));
    } else {
        auto it = decode(opsUtf8);
        for (size_t i = 0; i < it.size(); ++i) {
            uint32_t c = it[i];
            switch (c) {
            case ' ': case '.': case ',': case '_': case '/': case '=': case '\'': {
                const uint32_t bch = c == '=' ? uint32_t('1') : c;   // '=' = digit boundary
                // The apostrophe is passed as the word's boundary (contractions).
                const uint32_t ends = c == '\'' ? uint32_t('\'') : 0;
                size_t n = vt_peek_before(e, autoRestore, ends, buf, sizeof buf);
                std::string peek(buf, n);
                vt_commit_before(e, autoRestore, ends, &a);
                if (a.kind == VT_ACTION_REPLACE) {
                    dropLast(screen, size_t(a.backspaces));
                    auto ins = decode(std::string(a.insert, a.insert_len));
                    screen.insert(screen.end(), ins.begin(), ins.end());
                }
                screen.push_back(bch);
                std::string undo;
                vt_restore_undo u;
                if (vt_take_restore_undo(e, &u)) undo = "~" + std::string(u.vietnamese, size_t(u.vietnamese_len));
                vt_note_boundary(e, bch);
                trace.push_back(peek + "=>" + tok(a) + undo);
                break;
            }
            case '<':
                vt_backspace(e, &a);
                applyScreen(screen, a, false, 0);
                trace.push_back(tok(a));
                break;
            case '^': {
                long n = vt_reopen(e, buf, sizeof buf);
                if (n >= 0) {
                    dropLast(screen, 1);
                    trace.push_back("o:" + std::string(buf, size_t(n)));
                } else trace.push_back("o~");
                break;
            }
            case '#': vt_reset(e); trace.push_back("N"); break;
            case '!': vt_reset_context(e); trace.push_back("N"); break;
            case '%': {
                size_t n = vt_commit_text(e, autoRestore, buf, sizeof buf);
                std::string undo;
                vt_restore_undo u;
                if (vt_take_restore_undo(e, &u)) undo = "~" + std::string(u.vietnamese, size_t(u.vietnamese_len));
                trace.push_back("c:" + std::string(buf, n) + undo);
                break;
            }
            case '`':
                if (i + 1 < it.size()) {
                    char t = char(it[i + 1]);
                    if (t == 'A') autoRestore = !autoRestore;
                    else {
                        int f = flagFor(t);
                        if (f >= 0) vt_engine_set_flag(e, f, !vt_engine_get_flag(e, f));
                    }
                    ++i;
                }
                trace.push_back("t");
                break;
            default:
                vt_feed(e, c, &a);
                applyScreen(screen, a, true, c);
                trace.push_back(tok(a));
            }
        }
    }
    std::string line = flags.empty() ? "-" : flags;
    line += '\t'; line += opsUtf8; line += '\t';
    for (size_t i = 0; i < trace.size(); ++i) { if (i) line += '|'; line += trace[i]; }
    line += '\t';
    for (uint32_t cp : screen) encode(cp, line);
    line += '\t'; line += str(vt_composed, e);
    line += '\t'; line += str(vt_raw, e);
    line += '\t'; line += vt_previous_word_english(e) ? "1" : "0";
    vt_engine_free(e);
    return line;
}

// Retroactive English through the C ABI (vt_note_boundary / vt_take_retro, the vt_retro
// layout). Same case as TelexCore RetroEnglishTests.testCorrectionShape ("very" is a strong
// English word: the edit comes at "very"), then FrequencyEnglishTests.testFlipCorrectionShape.
bool retroSmoke() {
    vt_engine *e = vt_engine_new();
    const int on[] = {VT_FLAG_FREE_MARKING, VT_FLAG_LIVE_SPELL_CHECK, VT_FLAG_EAGER_ENGLISH_RESTORE,
                      VT_FLAG_CONTEXTUAL_ENGLISH, VT_FLAG_COLLISION_PREFERS_VIETNAMESE, VT_FLAG_RETRO_ENGLISH};
    for (int f : on) vt_engine_set_flag(e, f, true);
    vt_engine_set_flag(e, VT_FLAG_TEENCODE, false);
    vt_action a;
    vt_retro r;
    bool ok = true;
    const char *words[] = {"His", "car", "is", "very"};
    for (int w = 0; w < 4; ++w) {
        for (const char *p = words[w]; *p; ++p) vt_feed(e, uint32_t(*p), &a);
        vt_commit(e, true, &a);
        vt_note_boundary(e, ' ');
        bool got = vt_take_retro(e, &r);
        if (got != (w == 3)) ok = false;
    }
    ok = ok && r.backspaces == 12 && r.words == 3 && r.flip_back == 0
        && std::string(r.expected, size_t(r.expected_len)) == "\xC3\xAD c\xE1\xBA\xA3 \xC3\xAD very "
        && std::string(r.insert, size_t(r.insert_len)) == "is car is very ";
    ok = ok && !vt_engine_get_flag(e, VT_FLAG_ENGLISH_BY_FREQUENCY);
    vt_engine_set_flag(e, VT_FLAG_CONTEXTUAL_ENGLISH, false);   // feature depends on it
    ok = ok && vt_engine_get_flag(e, VT_FLAG_RETRO_ENGLISH);
    vt_engine_free(e);

    // englishByFrequency: "His " commits as English, "hửng " flips it back (flip_back = 1).
    e = vt_engine_new();
    for (int f : on) vt_engine_set_flag(e, f, true);
    vt_engine_set_flag(e, VT_FLAG_TEENCODE, false);
    vt_engine_set_flag(e, VT_FLAG_ENGLISH_BY_FREQUENCY, true);
    ok = ok && vt_engine_get_flag(e, VT_FLAG_ENGLISH_BY_FREQUENCY);
    const char *flip[] = {"His", "huwngr"};
    for (int w = 0; w < 2; ++w) {
        for (const char *p = flip[w]; *p; ++p) vt_feed(e, uint32_t(*p), &a);
        vt_commit(e, true, &a);
        vt_note_boundary(e, ' ');
        bool got = vt_take_retro(e, &r);
        if (got != (w == 1)) ok = false;
    }
    ok = ok && r.backspaces == 8 && r.words == 1 && r.flip_back == 1
        && std::string(r.expected, size_t(r.expected_len)) == "is h\xE1\xBB\xADng "
        && std::string(r.insert, size_t(r.insert_len)) == "\xC3\xAD h\xE1\xBB\xADng ";
    vt_engine_free(e);
    return ok;
}

// autoCircumflex (issue #166): default OFF; on ⇒ "vietj" composes "việt".
bool autoCircumflexSmoke() {
    vt_engine *e = vt_engine_new();
    vt_action a;
    char buf[64];
    bool ok = !vt_engine_get_flag(e, VT_FLAG_AUTO_CIRCUMFLEX);
    vt_engine_set_flag(e, VT_FLAG_LIVE_SPELL_CHECK, true);
    vt_engine_set_flag(e, VT_FLAG_AUTO_CIRCUMFLEX, true);
    ok = ok && vt_engine_get_flag(e, VT_FLAG_AUTO_CIRCUMFLEX);
    for (const char *p = "vietj"; *p; ++p) vt_feed(e, uint32_t(*p), &a);
    size_t n = vt_composed(e, buf, sizeof buf);
    ok = ok && std::string(buf, n) == "vi\xE1\xBB\x87t";
    vt_engine_free(e);
    return ok;
}

} // namespace

int main() {
    if (vt_abi_version() != VT_ABI_VERSION) { std::fprintf(stderr, "ABI mismatch\n"); return 2; }
    if (!retroSmoke()) { std::fprintf(stderr, "retro smoke FAILED\n"); return 3; }
    if (!autoCircumflexSmoke()) { std::fprintf(stderr, "autoCircumflex smoke FAILED\n"); return 3; }
    std::string line;
    size_t total = 0, bad = 0;
    while (std::getline(std::cin, line)) {
        if (line.empty() || line[0] == '#') continue;
        size_t t1 = line.find('\t');
        size_t t2 = line.find('\t', t1 + 1);
        if (t1 == std::string::npos || t2 == std::string::npos) continue;
        std::string flags = line.substr(0, t1);
        if (flags == "-") flags.clear();
        std::string ops = line.substr(t1 + 1, t2 - t1 - 1);
        std::string got = run(flags, ops);
        ++total;
        if (got != line) {
            if (++bad <= 20) std::fprintf(stderr, "MISMATCH\n  want: %s\n  got:  %s\n", line.c_str(), got.c_str());
        }
    }
    std::printf("golden: %zu scripts, %zu mismatches (%s)\n", total, bad, bad ? "FAIL" : "100% parity");
    return (bad || total == 0) ? 1 : 0;
}
