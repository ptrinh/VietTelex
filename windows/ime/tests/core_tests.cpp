#include <cmath>
#include <utility>

#include "app_policy.h"
#include "game_ipc.h"
#include "ipc.h"
#include "hotkey.h"
#include "keymap.h"
#include "settings.h"
#include "shortcuts.h"
#include "text_tool_ipc.h"
#include "tip_caches.h"
#include "test.h"

#include <viettelex/vtx_engine.h>

using namespace vtx;

TEST(keymap_letters_shift_caps) {
    Modifiers m;
    CHECK_EQ(classifyKey('A', m).ch, U'a');
    m.shift = true;
    CHECK_EQ(classifyKey('A', m).ch, U'A');
    m.capsLock = true;
    CHECK_EQ(classifyKey('A', m).ch, U'a');  // Shift XOR Caps
    m.shift = false;
    CHECK_EQ(classifyKey('A', m).ch, U'A');
    CHECK_EQ(classifyKey('1', m).ch, U'1');  // Caps never shifts digits
}

TEST(keymap_us_punctuation_not_vietnamese_layout) {
    Modifiers m;
    CHECK_EQ(classifyKey('1', m).ch, U'1');
    CHECK_EQ(classifyKey(vk::Oem4, m).ch, U'[');
    CHECK_EQ(classifyKey(vk::Oem6, m).ch, U']');
    m.shift = true;
    CHECK_EQ(classifyKey('2', m).ch, U'@');
    CHECK_EQ(classifyKey(vk::Oem7, m).ch, U'"');
    CHECK_EQ(classifyKey(vk::Oem4, m).ch, U'{');
}

// #121: what ToUnicodeEx reports for the number row under the stock "Vietnamese" layout
// (KLID 0000042A), as in the report: 1..0 -> ă â ê ô, five combining tones, đ.
static const char16_t kViNumberRow[10] = {u'đ', u'ă', u'â', u'ê', u'ô',
                                          u'̀', u'̉', u'̃', u'́', u'̣'};  // VK '0'..'9'
constexpr uintptr_t kHklVietnamese = 0x042A042A;  // vi-VN, Vietnamese layout
constexpr uintptr_t kHklViSubstUs = 0x0409042A;   // vi-VN on a US layout (substitute applied)
constexpr uintptr_t kHklUs = 0x04090409;

TEST(layout_types_us) {
    const char16_t one = u'1', a = u'a';
    CHECK(layoutTypesUs(U'1', 1, &one));
    CHECK(layoutTypesUs(U'a', 1, &a));
    CHECK(!layoutTypesUs(U'1', 1, &kViNumberRow[1]));  // ă
    CHECK(!layoutTypesUs(U'5', 1, &kViNumberRow[5]));  // combining grave
    CHECK(!layoutTypesUs(U'1', -1, &one));             // dead key
    CHECK(!layoutTypesUs(U'1', 0, nullptr));           // layout types nothing
    const char16_t two[2] = {u'1', u'1'};
    CHECK(!layoutTypesUs(U'1', 2, two));               // two characters (ligature key)
    const char16_t pair[2] = {0xD83D, 0xDE00};         // U+1F600 as a surrogate pair
    CHECK(layoutTypesUs(U'\U0001F600', 2, pair));
}

TEST(retype_number_row_under_vietnamese_layout) {
    Modifiers m;
    for (uint32_t d = 0; d < 10; ++d) {
        KeyInput k = classifyKey('0' + d, m);
        LayoutMatch lm = layoutTypesUs(k.ch, 1, &kViNumberRow[d]) ? LayoutMatch::Same : LayoutMatch::Differs;
        CHECK(shouldRetypeAsUs(k, kHklVietnamese, lm));
        CHECK_EQ(k.ch, static_cast<char32_t>(U'0' + d));  // ...and what we type is the digit
    }
    // A key the Vietnamese layout already types like US is left to the app.
    const char16_t a = u'a';
    KeyInput ka = classifyKey('A', m);
    CHECK(!shouldRetypeAsUs(ka, kHklVietnamese, layoutTypesUs(ka.ch, 1, &a) ? LayoutMatch::Same : LayoutMatch::Differs));
    // Never before ToUnicodeEx answered, never for another language, never for non-printables.
    KeyInput k1 = classifyKey('1', m);
    CHECK(!shouldRetypeAsUs(k1, kHklVietnamese, LayoutMatch::Unknown));
    CHECK(!shouldRetypeAsUs(k1, kHklUs, LayoutMatch::Differs));
    CHECK(shouldRetypeAsUs(k1, kHklViSubstUs, LayoutMatch::Differs));
    CHECK(!shouldRetypeAsUs(classifyKey(vk::Return, m), kHklVietnamese, LayoutMatch::Differs));
    Modifiers ctrl;
    ctrl.ctrl = true;  // Ctrl+1 is an app shortcut: the VK goes through untouched
    CHECK(!shouldRetypeAsUs(classifyKey('1', ctrl), kHklVietnamese, LayoutMatch::Differs));
    CHECK(isVietnameseHkl(kHklVietnamese) && isVietnameseHkl(kHklViSubstUs) && !isVietnameseHkl(kHklUs));
}

TEST(retype_after_composition_in_browser) {
    // #173: Enter on a word still composing in a web chat box added a line instead of sending.
    Modifiers m;
    const KeyInput enter = classifyKey(vk::Return, m);
    CHECK(retypeAfterComposition(enter, true, true, false));
    CHECK(retypeAfterComposition(classifyKey(vk::Tab, m), true, true, false));
    CHECK(retypeAfterComposition(classifyKey(vk::Escape, m), true, true, false));
    CHECK(!retypeAfterComposition(enter, true, false, false));   // no word composing: genuine key
    CHECK(!retypeAfterComposition(enter, true, true, true));     // composition still open
    CHECK(!retypeAfterComposition(enter, false, true, false));   // not a browser store
    CHECK(!retypeAfterComposition(classifyKey(vk::Space, m), true, true, false));  // typed by the app
    CHECK(!retypeAfterComposition(classifyKey(vk::Left, m), true, true, false));
    CHECK(!retypeAfterComposition(classifyKey(vk::Back, m), true, true, false));
}

TEST(retyped_key_is_not_a_repeat) {
    // #173 (1.3.32 retest): the retyped Enter reached the page as "keydown Enter repeat=true"
    // because the physical Enter was still down; the chat box did not send. Release first.
    const RetypeStrokes r = retypeStrokes(true);
    CHECK(r.count == 3);
    CHECK(r.up[0] && !r.up[1] && r.up[2]);
    const RetypeStrokes plain = retypeStrokes(false);  // #134 IMM hosts: unchanged
    CHECK(plain.count == 2);
    CHECK(!plain.up[0] && plain.up[1]);
}

TEST(retyped_enter_waits_after_the_composition) {
    // #173 (1.3.33 retest): "compositionend, keydown Enter 13 repeat=false" in one instant and
    // the chat box still did not send. Enter is pressed again a moment later; Tab / Esc and the
    // #134 IMM path are not delayed.
    CHECK(retypeDelayMs(vk::Return, true) == kRetypeEnterDelayMs);
    CHECK(kRetypeEnterDelayMs >= 30 && kRetypeEnterDelayMs <= 150);
    CHECK(retypeDelayMs(vk::Tab, true) == 0);
    CHECK(retypeDelayMs(vk::Escape, true) == 0);
    CHECK(retypeDelayMs(vk::Return, false) == 0);
}

TEST(passed_key_retype_kinds) {
    // #134: what the TIP retypes for a claimed key it let through in an IMM32 host.
    Modifiers m;
    CHECK(passedKeyRetype(classifyKey(vk::Space, m)) == PassedKeyRetype::Unicode);
    CHECK(passedKeyRetype(classifyKey('1', m)) == PassedKeyRetype::Unicode);
    CHECK(passedKeyRetype(classifyKey(vk::OemPeriod, m)) == PassedKeyRetype::Unicode);
    CHECK(passedKeyRetype(classifyKey(vk::Return, m)) == PassedKeyRetype::VirtualKey);
    CHECK(passedKeyRetype(classifyKey(vk::Back, m)) == PassedKeyRetype::VirtualKey);
    CHECK(passedKeyRetype(classifyKey(vk::Left, m)) == PassedKeyRetype::VirtualKey);
    Modifiers ctrl;
    ctrl.ctrl = true;
    CHECK(passedKeyRetype(classifyKey('V', ctrl)) == PassedKeyRetype::VirtualKey);  // Ctrl+V stays a chord
    CHECK(passedKeyRetype(classifyKey(vk::Shift, m)) == PassedKeyRetype::None);
    CHECK(passedKeyRetype(classifyKey(0x70, m)) == PassedKeyRetype::None);  // F1
}

TEST(hook_reaches_this_process_uipi) {
    // #134: MISA SME run as administrator (0x3000) with VietTelex.exe at medium (0x2000):
    // the hook cannot type there, so the TIP never asks for a Direct handover.
    CHECK(!hookReachesThisProcess(true, 0x2000, 0x3000));
    CHECK(hookReachesThisProcess(true, 0x2000, 0x2000));
    CHECK(hookReachesThisProcess(true, 0x2000, 0x1000));  // low-IL host (AppContainer)
    CHECK(hookReachesThisProcess(true, 0x3000, 0x3000));  // both elevated
    CHECK(!hookReachesThisProcess(false, 0x3000, 0x2000)); // unreadable token: assume blocked
}

TEST(layout_match_cache) {
    LayoutMatchCache c;
    CHECK(c.get(kHklVietnamese, '1', false, false) == LayoutMatch::Unknown);
    c.put(kHklVietnamese, '1', false, false, LayoutMatch::Differs);
    c.put(kHklVietnamese, 'A', true, true, LayoutMatch::Same);
    CHECK(c.get(kHklVietnamese, '1', false, false) == LayoutMatch::Differs);
    CHECK(c.get(kHklVietnamese, '1', true, false) == LayoutMatch::Unknown);  // Shift is its own entry
    CHECK(c.get(kHklVietnamese, 'A', true, true) == LayoutMatch::Same);
    CHECK(c.get(kHklUs, '1', false, false) == LayoutMatch::Unknown);         // other HKL: not known
    c.put(kHklUs, '1', false, false, LayoutMatch::Same);                     // switching forgets the old HKL
    CHECK(c.get(kHklVietnamese, '1', false, false) == LayoutMatch::Unknown);
    CHECK(c.get(kHklUs, '1', false, false) == LayoutMatch::Same);
    c.put(kHklUs, 0x1FF, false, false, LayoutMatch::Differs);                // out of range: ignored
    CHECK(c.get(kHklUs, 0x1FF, false, false) == LayoutMatch::Unknown);
}

TEST(keymap_kinds) {
    Modifiers m;
    CHECK(classifyKey(vk::Back, m).kind == KeyKind::Backspace);
    CHECK(classifyKey(vk::Return, m).kind == KeyKind::Boundary);
    CHECK(classifyKey(vk::Tab, m).kind == KeyKind::Boundary);
    CHECK(classifyKey(vk::Left, m).kind == KeyKind::Navigation);
    CHECK(classifyKey(vk::Delete, m).kind == KeyKind::Navigation);
    CHECK(classifyKey(vk::Shift, m).kind == KeyKind::Modifier);
    CHECK(classifyKey(vk::LWin, m).kind == KeyKind::Modifier);
    CHECK(classifyKey(0x70 /*F1*/, m).kind == KeyKind::Other);
    CHECK(classifyKey(vk::Space, m).kind == KeyKind::Char);
    CHECK(classifyKey(vk::Numpad0 + 5, m).ch == U'5');
    CHECK(classifyKey(vk::Numpad0 + 5, m).numpad);  // #124
    CHECK(!classifyKey('5', m).numpad);
    m.ctrl = true;
    CHECK(classifyKey('C', m).kind == KeyKind::Chord);
    m.ctrl = false;
    m.alt = true;
    CHECK(classifyKey('Z', m).kind == KeyKind::Chord);
}

TEST(hotkey_parse_and_default) {
    CHECK(parseSwitchHotkey("ctrl-shift") == SwitchHotkey::CtrlShift);
    CHECK(parseSwitchHotkey("win-space") == SwitchHotkey::WinSpace);
    CHECK(parseSwitchHotkey("alt-z") == SwitchHotkey::AltZ);
    CHECK(parseSwitchHotkey("off") == SwitchHotkey::Off);
    CHECK(parseSwitchHotkey("") == SwitchHotkey::CtrlShift);
    CHECK(parseSwitchHotkey("garbage") == SwitchHotkey::CtrlShift);
    CHECK_EQ(std::string(switchHotkeyName(SwitchHotkey::WinSpace)), std::string("win-space"));
}

TEST(hotkey_altz_latch_one_toggle_per_press) {
    PressLatch l;
    CHECK(l.fire());   // Alt+Z: toggle
    CHECK(!l.fire());  // auto-repeat: ignored
    l.noteKey('Z', true);  // a repeat that also reached the key sink keeps the latch
    CHECK(!l.fire());
    l.noteKey('Z', false);  // Z released
    CHECK(l.fire());        // Alt still held, Z pressed again: toggles once more
    CHECK(!l.fire());
    l.noteKey(0x12, false);  // Alt (VK_MENU) released
    CHECK(l.fire());
    CHECK(!l.fire());
    l.noteKey(0xA4, true);  // missed key-up, but a fresh Alt (VK_LMENU) press re-arms
    CHECK(l.fire());
    l.noteKey('A', true);  // any other key re-arms too
    CHECK(l.fire());
    l.reset();
    CHECK(!l.latched());
}

TEST(hotkey_chord_clean_press_release) {
    ModifierChord c;
    CHECK(!c.note(kModCtrl));
    CHECK(!c.note(kModCtrl | kModShift));  // armed
    CHECK(c.note(kModCtrl));               // release shift -> fire
    CHECK(!c.note(0));                     // already fired
}

TEST(hotkey_chord_other_key_disarms) {
    ModifierChord c;
    c.note(kModCtrl | kModShift);
    c.disarm();  // Ctrl+Shift+C
    CHECK(!c.note(0));
}

TEST(hotkey_chord_extra_modifier_disarms) {
    ModifierChord c;
    c.note(kModCtrl | kModShift);
    CHECK(!c.note(kModCtrl | kModShift | kModAlt));
    CHECK(!c.note(0));
}

TEST(hotkey_chord_shift_first_order_irrelevant) {
    ModifierChord c;
    c.note(kModShift);
    c.note(kModShift | kModCtrl);
    CHECK(c.note(0));
}

TEST(settings_defaults_match_macos) {
    Settings s;
    CHECK(s.freeMarking);
    CHECK(s.autoRestore);
    CHECK(s.liveSpellCheck);
    CHECK(s.contextualEnglish);
    CHECK(s.collisionPrefersVietnamese);
    CHECK(s.reEditWord);
    CHECK(!s.vniMode);
    CHECK(!s.simpleTelex);
    CHECK(!s.quickTelex);
    CHECK(!s.modernOrthography);
    CHECK(!s.bracketVowels);
    CHECK(!s.autoCircumflex);   // Tự thêm dấu mũ (#166): opt-in
    CHECK(!s.teencode);
    CHECK(!s.autoUpdateCheck);
    CHECK(!s.debugLogging);
    CHECK(!s.showTrayIcon);  // tray icon hidden by default (1.0.5)
    CHECK(!s.underlineMisspelled);  // red squiggle is opt-in
    CHECK_EQ(s.switchHotkey, std::string("ctrl-shift"));
    CHECK_EQ(s.uiLanguage, std::string("vi"));
    uint32_t f = s.engineFlags();
    CHECK(f & VTX_FREE_MARKING);
    CHECK(f & VTX_LIVE_SPELL_CHECK);
    CHECK(f & VTX_CONTEXTUAL_ENGLISH);
    CHECK(f & VTX_COLLISION_PREFERS_VI);
    CHECK(f & VTX_ENGLISH_WORD_RESTORE);
    CHECK(f & VTX_EAGER_ENGLISH_RESTORE);  // follows autoRestore (default ON)
    CHECK(!(f & VTX_TEENCODE));  // app default OFF even though the engine default is ON
    CHECK(!(f & VTX_VNI));
}

TEST(settings_snapshot_roundtrip) {
    Settings s;
    s.vniMode = true;
    s.autoRestore = false;
    s.debugLogging = true;
    s.showTrayIcon = true;
    s.underlineMisspelled = true;
    s.switchHotkey = "win-space";
    s.uiLanguage = "en";
    s.shortcuts[u"vn"] = u"Việt Nam";
    s.shortcuts[u"ko"] = u"không";
    s.appModes["code.exe"] = AppMode::InPlace;
    s.appModes["game.exe"] = AppMode::Off;
    std::vector<uint8_t> b = serialize(s);
    Settings r;
    CHECK(deserialize(b.data(), b.size(), r));
    CHECK(r == s);
}

TEST(settings_snapshot_rejects_garbage) {
    Settings r;
    r.vniMode = true;
    uint8_t junk[] = {1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12};
    CHECK(!deserialize(junk, sizeof junk, r));
    CHECK(r == Settings{});
    Settings s;
    s.shortcuts[u"a"] = u"b";
    std::vector<uint8_t> b = serialize(s);
    for (size_t cut = 0; cut < b.size(); ++cut) CHECK(!deserialize(b.data(), cut, r));
    CHECK(!deserialize(nullptr, 0, r));
}

TEST(json_flat_roundtrip) {
    StringMap m{{"vn", "Việt Nam"}, {"q\"x", "a\\b\nc"}, {"e", ""}};
    StringMap r;
    CHECK(parseFlatJson(toFlatJson(m), r));
    CHECK(r == m);
    CHECK(parseFlatJson("  { }  ", r) && r.empty());
    CHECK(parseFlatJson("{\"a\":\"\\u1ec7\"}", r));
    CHECK_EQ(r["a"], std::string("ệ"));
    CHECK(!parseFlatJson("{\"a\":1}", r));
    CHECK(!parseFlatJson("{\"a\":\"b\"", r));
    CHECK(!parseFlatJson("[]", r));
}

TEST(shortcut_import_formats) {
    StringMap r;
    CHECK(parseShortcutFile("{\"vn\":\"Việt Nam\"}", r));
    CHECK_EQ(r["vn"], std::string("Việt Nam"));
    CHECK(parseShortcutFile("# c\n; c\n// c\nvn: Việt Nam\nko:không\nq: \"  spaced \"\nbad key: x\n", r));
    CHECK_EQ(r.size(), size_t(3));
    CHECK_EQ(r["ko"], std::string("không"));
    CHECK_EQ(r["q"], std::string("  spaced "));
    CHECK(!parseShortcutFile("<?xml version=\"1.0\"?>\n<!DOCTYPE plist PUBLIC>\n", r));
    StringMap back;
    StringMap m{{"vn", "Việt Nam"}, {"sp", " x"}};
    CHECK(parseShortcutFile(exportShortcutsYaml(m), back));
    CHECK(back == m);
}

// Quoted keys (":D", "a:b", "#x"…) and escaped multi-line values, as macOS ShortcutImporter
// writes them — linux/common/tests/data/shortcuts-macos.yml is macOS exportYAML output.
TEST(shortcut_quoted_keys_like_macos) {
    StringMap want{
        {":D", "😀"}, {"a:b", "x"}, {"#x", "hash"}, {";x", "semi"}, {"//x", "slash"},
        {"\"k", "dq"}, {"'k", "sq"}, {"sig", "Thân mến,\nPhil"}, {"bs", "C:\\temp"},
        {"q", "\"trích\""}, {"sp", " có space "}, {"ko", "không"}, {"url", "http://x"}, {"tab", "a\tb"},
    };
    const std::string mac =
        "# VietTelex — bảng gõ tắt\n\"\\\"k\": dq\n\"#x\": hash\n\"'k\": sq\n\"//x\": slash\n"
        "\":D\": 😀\n\";x\": semi\n\"a:b\": x\nbs: C:\\temp\nko: không\nq: \"\\\"trích\\\"\"\n"
        "sig: \"Thân mến,\\nPhil\"\nsp: \" có space \"\ntab: a\tb\nurl: http://x\n";
    CHECK_EQ(exportShortcutsYaml(want), mac);
    StringMap r;
    CHECK(parseShortcutFile(mac, r));
    CHECK(r == want);
    CHECK(parseShortcutFile("\xEF\xBB\xBFko: không\r\ndc: được\r\n", r));
    CHECK_EQ(r.size(), size_t(2));
    CHECK_EQ(r["dc"], std::string("được"));
}

TEST(shortcut_lookup_rules) {
    std::map<std::u16string, std::u16string> t{{u"vn", u"Việt Nam"}, {u"cf", u"cà phê"}};
    std::u16string e;
    CHECK(findShortcut(t, u"vn", u"vn", 0, e));
    CHECK(e == u"Việt Nam");
    CHECK(findShortcut(t, u"c", u"cf", u' ', e));  // raw fallback ("cf" composes away)
    CHECK(e == u"cà phê");
    CHECK(!findShortcut(t, u"vn", u"vn", u'5', e));
    CHECK(!findShortcut(t, u"vn", u"vn", u'#', e));
    CHECK(!findShortcut(t, u"xx", u"xx", 0, e));
}

TEST(shortcut_case_follows_typing) {
    // 2026-11 Windows report: key "ko" -> "không"; "ko" expanded, "Ko" stayed "Ko".
    // Same rules as macOS / iOS / Android ShortcutTable.expansion.
    std::map<std::u16string, std::u16string> t{
        {u"ko", u"không"}, {u"dc", u"được"}, {u"vn", u"Việt Nam"}, {u"Hn", u"Hà Nội"}, {u"đc", u"địa chỉ"}};
    std::u16string e;
    CHECK(shortcutExpansion(t, u"ko", e) && e == u"không");
    CHECK(shortcutExpansion(t, u"Ko", e) && e == u"Không");
    CHECK(shortcutExpansion(t, u"KO", e) && e == u"KHÔNG");
    CHECK(!shortcutExpansion(t, u"kO", e));                       // mixed case: no match
    CHECK(shortcutExpansion(t, u"Dc", e) && e == u"Được");         // ư ơ -> Ư Ơ
    CHECK(shortcutExpansion(t, u"DC", e) && e == u"ĐƯỢC");
    CHECK(shortcutExpansion(t, u"VN", e) && e == u"VIỆT NAM");
    CHECK(shortcutExpansion(t, u"Vn", e) && e == u"Việt Nam");
    CHECK(shortcutExpansion(t, u"Đc", e) && e == u"Địa chỉ");      // Đ / đ
    CHECK(shortcutExpansion(t, u"ĐC", e) && e == u"ĐỊA CHỈ");
    CHECK(shortcutExpansion(t, u"Hn", e) && e == u"Hà Nội");       // a key with capitals: exact
    CHECK(!shortcutExpansion(t, u"hn", e));                         // ...only (as on macOS)
    CHECK(!shortcutExpansion(t, u"", e));
    // The word lookup (composed, then raw keys) carries the case too.
    CHECK(findShortcut(t, u"Ko", u"Ko", 0, e) && e == u"Không");
    CHECK(findShortcut(t, u"Đc", u"Ddc", 0, e) && e == u"Địa chỉ");
    CHECK(findShortcut(t, u"KO", u"KO", u' ', e) && e == u"KHÔNG");
    CHECK(!findShortcut(t, u"Ko", u"Ko", u'5', e));  // glued to a digit: still never
    CHECK(shortcutUpper(u"ăâđêôơưàảãáạằẳẵắặầẩẫấậèẻẽéẹềểễếệìỉĩíịòỏõóọồổỗốộờởỡớợùủũúụừửữứựỳỷỹýỵ") ==
          u"ĂÂĐÊÔƠƯÀẢÃÁẠẰẲẴẮẶẦẨẪẤẬÈẺẼÉẸỀỂỄẾỆÌỈĨÍỊÒỎÕÓỌỒỔỖỐỘỜỞỠỚỢÙỦŨÚỤỪỬỮỨỰỲỶỸÝỴ");
    CHECK(shortcutLower(u"ĂÂĐÊÔƠƯÀẢÃÁẠẰẲẴẮẶẦẨẪẤẬÈẺẼÉẸỀỂỄẾỆÌỈĨÍỊÒỎÕÓỌỒỔỖỐỘỜỞỠỚỢÙỦŨÚỤỪỬỮỨỰỲỶỸÝỴ") ==
          u"ăâđêôơưàảãáạằẳẵắặầẩẫấậèẻẽéẹềểễếệìỉĩíịòỏõóọồổỗốộờởỡớợùủũúụừửữứựỳỷỹýỵ");
}

TEST(app_policy_resolution) {
    CHECK_EQ(normalizeExeName("C:\\Program Files\\Foo\\Code.EXE"), std::string("code.exe"));
    CHECK_EQ(normalizeExeName("notepad.exe"), std::string("notepad.exe"));
    std::map<std::string, AppMode> o;
    CHECK(resolveAppMode("notepad.exe", o) == AppMode::InPlace);  // default since 1.0.9
    CHECK(resolveAppMode("mstsc.exe", o) == AppMode::Off);
    o["mstsc.exe"] = AppMode::Composition;  // user override beats built-in
    CHECK(resolveAppMode("mstsc.exe", o) == AppMode::Composition);
    o["code.exe"] = AppMode::InPlace;
    CHECK(resolveAppMode("code.exe", o) == AppMode::InPlace);
    AppMode m;
    CHECK(parseAppMode("hookFallback", m) && m == AppMode::HookFallback);
    CHECK(!parseAppMode("bogus", m));
    for (AppMode x : {AppMode::Composition, AppMode::InPlace, AppMode::HookFallback, AppMode::Off})
        CHECK(parseAppMode(appModeName(x), m) && m == x);
}

TEST(input_scope_policy) {
    int pw[] = {31};
    int def[] = {0};
    int url[] = {1};
    int priv[] = {61, 0};
    int mixed[] = {0, 29};
    int email[] = {5};
    CHECK(classifyInputScopes(pw, 1) == FieldPolicy::Literal);
    CHECK(classifyInputScopes(def, 1) == FieldPolicy::Normal);
    CHECK(classifyInputScopes(url, 1) == FieldPolicy::Normal);   // Chrome omnibox
    CHECK(classifyInputScopes(priv, 2) == FieldPolicy::Normal);  // InPrivate windows
    CHECK(classifyInputScopes(mixed, 2) == FieldPolicy::Literal);
    CHECK(classifyInputScopes(email, 1) == FieldPolicy::Literal);
    CHECK(classifyInputScopes(nullptr, 0) == FieldPolicy::Normal);
}

TEST(utf_roundtrip) {
    std::string s = "Tiếng Việt 😀";
    CHECK_EQ(utf16ToUtf8(utf8ToUtf16(s)), s);
    CHECK_EQ(utf8ToUtf16("ệ").size(), size_t(1));
}

#include "com_path.h"

TEST(arm64x_com_server_path) {
    const std::wstring a = L"C:\\Program Files\\VietTelex\\VietTelexTIP_arm64.dll";
    const std::wstring x = L"C:\\Program Files\\VietTelex\\viettelextip_X64.DLL";
    const std::wstring f = L"C:\\Program Files\\VietTelex\\VietTelexTIP.dll";
    CHECK(comServerPath(a, true) == f);
    CHECK(comServerPath(x, true) == f);
    CHECK(comServerPath(a, false) == a);  // no forwarder installed: register self
    CHECK(comServerPath(f, true) == f);   // plain x64/x86 DLL
    CHECK(forwarderCandidate(L"C:\\x\\VietTelexTIP.dll").empty());
    CHECK(forwarderCandidate(L"VietTelexTIP_arm64.dll") == L"VietTelexTIP.dll");
    // version-named release DLLs (1.0.6+)
    CHECK(forwarderCandidate(L"C:\\VT\\VietTelexTIP_arm64_1_0_6.dll") == L"C:\\VT\\VietTelexTIP_1_0_6.dll");
    CHECK(forwarderCandidate(L"VietTelexTIP_x64_1_0_6.dll") == L"VietTelexTIP_1_0_6.dll");
    CHECK(forwarderCandidate(L"VietTelexTIP_1_0_6.dll").empty());
    CHECK(forwarderCandidate(L"VietTelexTIP_arm64_x.dll").empty());
}

#include "registration.h"

TEST(registration_data_shape) {
    auto e = vtx::reg::tipRegistryEntries("C:\\VT\\VietTelexTIP.dll", "C:\\VT\\icon.dll");
    CHECK_EQ(e.size(), size_t(9 + 2 * vtx::reg::kCategoryCount));
    bool apartment = false, inproc = false, subst = false, enable = false;
    size_t catKeys = 0, itemKeys = 0;
    const std::string clsid = vtx::reg::kClsid;
    for (const auto& r : e) {
        if (r.name == "ThreadingModel") apartment = r.sz == "Apartment";
        if (r.key == "SOFTWARE\\Classes\\CLSID\\" + clsid + "\\InprocServer32" && r.name.empty())
            inproc = r.sz == "C:\\VT\\VietTelexTIP.dll";
        if (r.name == "SubstituteLayout") subst = r.dword == 0x04090409;
        if (r.name == "Enable" && r.key == vtx::reg::languageProfileKey()) enable = r.dword == 1;
        if (r.type == vtx::reg::ValueType::Key) {
            if (r.key.find("\\Category\\Category\\") != std::string::npos) ++catKeys;
            if (r.key.find("\\Category\\Item\\" + clsid + "\\") != std::string::npos) ++itemKeys;
        }
    }
    CHECK(apartment && inproc && subst && enable);
    CHECK_EQ(catKeys, vtx::reg::kCategoryCount);
    CHECK_EQ(itemKeys, vtx::reg::kCategoryCount);
    CHECK_EQ(vtx::reg::languageProfileKey(), std::string("SOFTWARE\\Microsoft\\CTF\\TIP\\") + clsid +
                                                 "\\LanguageProfile\\0x0000042a\\" + vtx::reg::kProfile);
}

#include "res/icon_ids.h"

TEST(icon_choice_mapping) {
    CHECK(parseIconChoice("vt") == IconChoice::Vt);
    CHECK(parseIconChoice("star") == IconChoice::Star);
    CHECK(parseIconChoice("flag") == IconChoice::Flag);
    CHECK(parseIconChoice("logo") == IconChoice::Logo);
    CHECK(parseIconChoice("vi") == IconChoice::Vi);
    CHECK(parseIconChoice("letter") == IconChoice::Vt);  // retired "V / E" migrates to Vᴛ
    CHECK(parseIconChoice("") == IconChoice::Vt);
    for (int i = 0; i < kIconChoiceCount; ++i) {
        IconChoice c = static_cast<IconChoice>(i);
        CHECK(parseIconChoice(iconChoiceName(c)) == c);
    }
    // dynamic indicator icon
    CHECK_EQ(indicatorIcon(IconChoice::Vt, true, false).resourceId, IDI_GLYPH_VT_V_DARK);
    CHECK_EQ(indicatorIcon(IconChoice::Vt, false, true).resourceId, IDI_GLYPH_VT_E_LIGHT);
    CHECK_EQ(indicatorIcon(IconChoice::Star, true, true).resourceId, IDI_GLYPH_STAR_V_LIGHT);
    CHECK_EQ(indicatorIcon(IconChoice::Flag, false, false).resourceId, IDI_GLYPH_FLAG_E_DARK);
    CHECK_EQ(indicatorIcon(IconChoice::Logo, true, false).resourceId, IDI_APP);
    CHECK(!indicatorIcon(IconChoice::Logo, true, false).dim);
    CHECK(indicatorIcon(IconChoice::Logo, false, false).dim);  // English = dimmed logo
    CHECK_EQ(indicatorIcon(IconChoice::Vi, true, true).resourceId, 0);
    CHECK_EQ(std::string(indicatorIcon(IconChoice::Vi, true, true).text), std::string("VI"));
    CHECK_EQ(std::string(indicatorIcon(IconChoice::Vi, false, true).text), std::string("EN"));
    // static profile icon: resource id and index in the DLL
    CHECK_EQ(profileIconId(IconChoice::Vt), IDI_PROFILE_VT);
    CHECK_EQ(profileIconId(IconChoice::Vi), IDI_PROFILE_VI);
    CHECK_EQ(profileIconIndex(IconChoice::Vt), 13);
    CHECK_EQ(profileIconIndex(IconChoice::Vi), 17);
    CHECK_EQ(static_cast<int>(vtx::reg::kIconIndex), profileIconIndex(IconChoice::Vt));
    // kAllIconIds must be ascending (Windows' icon-group index order)
    for (size_t i = 1; i < sizeof(kAllIconIds) / sizeof(kAllIconIds[0]); ++i) CHECK(kAllIconIds[i - 1] < kAllIconIds[i]);
}

TEST(glyph_icon_ids) {
    CHECK_EQ(glyphIconId("vt", true, false), IDI_GLYPH_VT_V_DARK);
    CHECK_EQ(glyphIconId("vt", true, true), IDI_GLYPH_VT_V_LIGHT);
    CHECK_EQ(glyphIconId("vt", false, false), IDI_GLYPH_VT_E_DARK);
    CHECK_EQ(glyphIconId("star", false, true), IDI_GLYPH_STAR_E_LIGHT);
    CHECK_EQ(glyphIconId("flag", true, false), IDI_GLYPH_FLAG_V_DARK);
    CHECK_EQ(glyphIconId("garbage", true, true), IDI_GLYPH_VT_V_LIGHT);  // unknown -> default
    CHECK_EQ(glyphIconId("letter", true, true), IDI_GLYPH_VT_V_LIGHT);   // retired -> Vᴛ
    CHECK_EQ(glyphIconId("logo", true, true), IDI_APP);
    CHECK_EQ(glyphIconId("vi", true, true), 0);
}

namespace {
double relLuminance(unsigned rgb) {
    auto ch = [](unsigned v) {
        const double c = v / 255.0;
        return c <= 0.03928 ? c / 12.92 : std::pow((c + 0.055) / 1.055, 2.4);
    };
    return 0.2126 * ch((rgb >> 16) & 0xFF) + 0.7152 * ch((rgb >> 8) & 0xFF) + 0.0722 * ch(rgb & 0xFF);
}
double contrast(unsigned a, unsigned b) {
    double la = relLuminance(a), lb = relLuminance(b);
    if (la < lb) std::swap(la, lb);
    return (la + 0.05) / (lb + 0.05);
}
}  // namespace

// 2026-10 field report: "biểu tượng không hiện rõ đang là E hay V". The tray badge must
// say V or E in letters, differ in colour, and stay readable (WCAG AA) on any taskbar.
TEST(tray_badge_is_clear_v_or_e) {
    const TrayBadge v = trayBadge(true), e = trayBadge(false);
    CHECK(v.letter == L'V');
    CHECK(e.letter == L'E');
    CHECK(v.bg != e.bg);
    CHECK(contrast(v.fg, v.bg) >= 4.5);
    CHECK(contrast(e.fg, e.bg) >= 4.5);
    // An opaque badge reads on the light (white-ish) and the dark (near-black) taskbar.
    CHECK(contrast(v.bg, 0xF3F3F3) >= 3.0 && contrast(e.bg, 0xF3F3F3) >= 3.0);
    // Style: "letter" is the default; anything unknown falls back to it.
    CHECK(parseTrayStyle("") == TrayStyle::Letter);
    CHECK(parseTrayStyle("garbage") == TrayStyle::Letter);
    CHECK(parseTrayStyle("keyboard") == TrayStyle::Keyboard);
    CHECK(parseTrayStyle(trayStyleName(TrayStyle::Letter)) == TrayStyle::Letter);
    CHECK(parseTrayStyle(trayStyleName(TrayStyle::Keyboard)) == TrayStyle::Keyboard);
    CHECK_EQ(Settings().trayIconStyle, std::string("letter"));
}

TEST(display_attribute_provider_is_registered) {
    // No-underline composition depends on TSF finding our ITfDisplayAttributeProvider,
    // which it does ONLY through this category (Chrome underlines otherwise).
    bool found = false;
    for (size_t i = 0; i < vtx::reg::kCategoryCount; ++i)
        if (std::string(vtx::reg::kCategories[i].guid) == "{046B8C80-1647-40F7-9B21-B93B81AABC1B}") found = true;
    CHECK(found);
    bool rows = false;
    for (const auto& e : vtx::reg::tipRegistryEntries("x", "y"))
        if (e.key.find("\\Category\\Category\\{046B8C80-1647-40F7-9B21-B93B81AABC1B}\\") != std::string::npos) rows = true;
    CHECK(rows);  // ...and the MSI writes it (release.sh diffs the built MSI against these rows)
}

TEST(ipc_state_changed_is_internal) {
    // TIP -> app Việt/Anh notification (tray icon is the only state indicator since 1.0.8);
    // accepted on the window message, never from the command line.
    CHECK(isValidAppCommand(static_cast<unsigned>(AppCommand::StateChanged)));
    CHECK(!isUserCommand(static_cast<unsigned>(AppCommand::StateChanged)));
    CHECK(isUserCommand(static_cast<unsigned>(AppCommand::OpenSettings)));
    CHECK(isValidAppCommand(static_cast<unsigned>(AppCommand::DirectMode)));
    CHECK(!isUserCommand(static_cast<unsigned>(AppCommand::DirectMode)));
    CHECK(isValidAppCommand(static_cast<unsigned>(AppCommand::SetAppLanguage)));
    CHECK(!isUserCommand(static_cast<unsigned>(AppCommand::SetAppLanguage)));
    CHECK(isValidAppCommand(static_cast<unsigned>(AppCommand::TextToolReply)));
    CHECK(!isUserCommand(static_cast<unsigned>(AppCommand::TextToolReply)));
    CHECK(isValidAppCommand(static_cast<unsigned>(AppCommand::UserSwitched)));
    CHECK(!isUserCommand(static_cast<unsigned>(AppCommand::UserSwitched)));
    CHECK(!isValidAppCommand(0) && !isValidAppCommand(11));
}

TEST(text_tool_ipc_roundtrip) {
    // Công cụ văn bản: TIP <-> app payloads (text_tool_ipc.h)
    const std::u16string t = u"toi di hoc \U0001F600 Việt";
    std::vector<uint8_t> b = packTextToolData(0x0ABCDEF1u, 3, t);
    uint32_t req = 0, tool = 0;
    std::u16string out;
    CHECK(unpackTextToolData(b.data(), b.size(), req, tool, out));
    CHECK_EQ(req, 0x0ABCDEF1u);
    CHECK_EQ(tool, 3u);
    CHECK(out == t);
    CHECK(unpackTextToolData(b.data(), 8, req, tool, out) && out.empty());
    CHECK(!unpackTextToolData(b.data(), 7, req, tool, out));
    CHECK(!unpackTextToolData(b.data(), b.size() - 1, req, tool, out));  // odd size
    CHECK(!unpackTextToolData(nullptr, 0, req, tool, out));
    std::vector<uint8_t> big = packTextToolData(1, 0, std::u16string(kTextToolMaxLength + 1, u'a'));
    CHECK(!unpackTextToolData(big.data(), big.size(), req, tool, out));  // over the cap
    const uint32_t lp = textToolReplyParam(0x1234567u, TextToolStatus::Refused);
    CHECK_EQ(textToolReplyRequest(lp), 0x1234567u);
    CHECK(textToolReplyStatus(lp) == TextToolStatus::Refused);
    CHECK_EQ(textToolReplyRequest(textToolReplyParam(0xFFFFFFFFu, TextToolStatus::Replaced)), kTextToolRequestMask);
    CHECK(isSecretInputScope(31) && isSecretInputScope(64) && !isSecretInputScope(5) && !isSecretInputScope(1));
}

TEST(text_tools_settings_defaults) {
    Settings s;
    CHECK(s.textToolsInMenu);                              // macOS textToolsInMenu default ON
    CHECK_EQ(s.addTonesHotkey, std::string("off"));        // hotkey default OFF
    CHECK_EQ(s.uiLanguage, std::string("vi"));             // Vietnamese UI regardless of locale
    s.textToolsInMenu = false;
    std::vector<uint8_t> b = serialize(s);
    Settings r;
    CHECK(deserialize(b.data(), b.size(), r));
    CHECK(!r.textToolsInMenu);
}

TEST(settings_underline_misspelled_snapshot_bit) {
    size_t n = 0;
    const BoolKey* keys = boolKeys(&n);
    CHECK(n <= 64);                      // snapshot bits fit the two u32 words
    // Appended, never reordered: bit 21, then the game bits (game_ipc.h) after it.
    CHECK(n >= 24);
    CHECK_EQ(std::string(keys[21].name), std::string("underlineMisspelled"));
    CHECK_EQ(std::string(keys[22].name), std::string("autoOffFullscreen"));
    CHECK_EQ(std::string(keys[23].name), std::string("gameMode"));
    Settings on;
    on.underlineMisspelled = true;
    std::vector<uint8_t> b = serialize(on);
    Settings r;
    CHECK(deserialize(b.data(), b.size(), r));
    CHECK(r.underlineMisspelled);
    CHECK(!(r == Settings{}));
}

TEST(settings_snapshot_game_bits) {
    // Games / fullscreen: appended snapshot bits (game_ipc.h). The TIP reads gameMode from
    // the snapshot; autoOffFullscreen defaults ON.
    Settings d;
    CHECK(d.autoOffFullscreen);
    CHECK(!d.gameMode);
    Settings s;
    s.gameMode = true;
    s.autoOffFullscreen = false;
    std::vector<uint8_t> b = serialize(s);
    Settings r;
    CHECK(deserialize(b.data(), b.size(), r));
    CHECK(r.gameMode && !r.autoOffFullscreen);
    // A snapshot from before these bits (22 of them) leaves both at their defaults.
    CHECK(b.size() > 8);
    b[6] = 22;
    b[7] = 0;
    CHECK(deserialize(b.data(), b.size(), r));
    CHECK(!r.gameMode && r.autoOffFullscreen);
    // Registry-only strings are not in the snapshot.
    s.gameModeHotkey = "ctrl-alt-g";
    s.switchIndicator = "off";
    s.trayIconStyle = "keyboard";
    b = serialize(s);
    CHECK(deserialize(b.data(), b.size(), r));
    CHECK_EQ(r.gameModeHotkey, std::string("off"));
    CHECK_EQ(r.switchIndicator, std::string("auto"));
    CHECK_EQ(r.trayIconStyle, std::string("letter"));
}

TEST(tip_suspension_reasons) {
    CHECK(!tipSuspended(0, false));
    CHECK(tipSuspended(kSuspendFullscreen, false));
    CHECK(tipSuspended(0, true));  // Chế độ game reaches every TIP through the snapshot
    CHECK(tipSuspended(kSuspendFullscreen | kSuspendGameMode, false));
    CHECK(!tipSuspended(0x100, false));  // unknown bits are ignored
    // The suspend message must not collide with the TIP window's other messages
    // (kTipTextToolMsg; text_service.cpp uses WM_APP + 0x59..0x5C internally).
    CHECK(kTipSuspendMsg != kTipTextToolMsg);
    CHECK(kTipSuspendMsg > 0x8000u + 0x5Cu && kTipSuspendMsg < 0xC000u);
}

// ---- TIP per-key / per-focus caches (tip_caches.h, 2026-10 perf audit) ----------------

// M3: an in-place replace read the text before the caret, then read it AGAIN to verify
// the deletion — inside one edit session, where nothing else can change it.
TEST(before_caret_cache_proves_tail_until_written) {
    BeforeCaretCache c;
    CHECK(!c.proves(u""));  // nothing read yet
    c.remember(u"xin cha", true);
    CHECK(c.proves(u"a"));
    CHECK(c.proves(u"cha"));
    CHECK(c.proves(u""));
    CHECK(!c.proves(u"chà"));
    CHECK(!c.proves(u"xxin cha"));  // longer than what was read: unknown
    c.invalidate();                 // a write of ours
    CHECK(!c.proves(u"a"));
    // Hidden text / embedded objects: fewer units than positions -> never trusted.
    c.remember(u"ab", false);
    CHECK(!c.proves(u"b"));
}

// 1.3.36 (Excel cell): the hook's ack lands between OnTestKeyDown and OnKeyDown of the key
// that starts a word. The key claimed at the test stays the TIP's; the next key does not.
TEST(test_claim_holds_for_the_same_key_only) {
    TestClaim c;
    CHECK(!c.holds(1));
    c.claimed(7);
    CHECK(c.holds(7));   // OnKeyDown of that key
    CHECK(!c.holds(8));  // the next key is decided afresh
    c.reset();
    CHECK(!c.holds(7));
}

// M4: evaluateHost ran in OnTestKeyDown AND OnKeyDown of the same key.
TEST(per_key_once_reuses_test_evaluation_once) {
    PerKeyOnce once;
    int ctxA = 0, ctxB = 0;
    CHECK(!once.takeForKeyDown(1, &ctxA));  // a host without OnTestKeyDown: evaluate
    once.noteTest(2, &ctxA);
    CHECK(once.takeForKeyDown(2, &ctxA));   // same key, same context: reuse
    CHECK(!once.takeForKeyDown(2, &ctxA));  // at most once
    once.noteTest(3, &ctxA);
    CHECK(!once.takeForKeyDown(4, &ctxA));  // another key
    once.noteTest(5, &ctxA);
    CHECK(!once.takeForKeyDown(5, &ctxB));  // another context
    once.noteTest(6, &ctxA);
    once.invalidate();                      // focus change
    CHECK(!once.takeForKeyDown(6, &ctxA));
}

// M1: every focus change posted StateChanged to VietTelex.exe (FindWindow + wake-up),
// though only the optional tray icon (default off) uses it.
TEST(focus_state_notify_only_tray_and_changes) {
    FocusStateNotify n;
    CHECK(!n.shouldPost(false, true, 10));  // tray off (default): never
    CHECK(n.shouldPost(true, true, 10));    // tray on: first time
    CHECK(!n.shouldPost(true, true, 10));   // same field / window, same state
    CHECK(n.shouldPost(true, false, 10));   // state changed (another process toggled)
    CHECK(n.shouldPost(true, false, 11));   // another window of this thread
    n.notePosted(true, 11);                 // the user switched (always posted)
    CHECK(!n.shouldPost(true, true, 11));
    CHECK(!n.shouldPost(false, true, 11));  // tray turned off...
    CHECK(n.shouldPost(true, true, 11));    // ...and on again: tell it afresh
    n.reset();
    CHECK(n.shouldPost(true, true, 11));
}

TEST(effective_game_mode_asks_app_only_when_on) {
    int asked = 0;
    CHECK(!effectiveGameMode(false, [&] { ++asked; return true; }));
    CHECK(asked == 0);  // off: no FindWindow
    CHECK(effectiveGameMode(true, [&] { ++asked; return true; }));
    CHECK(!effectiveGameMode(true, [&] { ++asked; return false; }));  // app gone: stale "on" ignored
    CHECK(asked == 2);
}

// ---- 2026-11 audit: window properties left by a killed VietTelex.exe -------------------

// VietTelex.Suspend / VietTelex.DirectOn on another process's window outlive a killed app
// (TerminateProcess: no cleanup). Their value is the app's main window; the TIP honours one
// only while it is the LIVE app window.
TEST(window_props_honoured_only_from_the_live_app) {
    const uintptr_t app = 0x000A0B2Cu;
    CHECK(propFromLiveApp(app, app));
    CHECK(!propFromLiveApp(0, app));            // no property
    CHECK(!propFromLiveApp(app, 0));            // app not running: a stale property is ignored
    CHECK(!propFromLiveApp(app, 0x000C0D2Eu));  // app restarted: another window
    CHECK(!propFromLiveApp(1, app));            // the pre-fix value (1 / reason bits): stale
    CHECK(!propFromLiveApp(0, 0));
#if UINTPTR_MAX > 0xFFFFFFFFu
    // A WOW64 (x86) TIP reads a 64-bit app's value truncated to 32 bits; HWNDs fit.
    CHECK(propFromLiveApp(app, static_cast<uintptr_t>(0xFFFFFFFF00000000ull) | app));
    CHECK(!propFromLiveApp(static_cast<uintptr_t>(0x100000000ull), static_cast<uintptr_t>(0x100000000ull)));
#endif
}

// The TIP re-derived "can the hook reach this process" on every key in a Direct field
// (FindWindow, OpenProcessToken on itself, OpenProcess + token on the app).
TEST(hook_reach_cache_per_app_window_and_pid) {
    HookReachCache c;
    bool r = true;
    CHECK(!c.lookup(10, 100, r));  // nothing yet: ask
    c.store(10, 100, false);
    r = true;
    CHECK(c.lookup(10, 100, r) && !r);
    CHECK(!c.lookup(11, 100, r));  // another app window
    CHECK(!c.lookup(10, 101, r));  // another app process (restarted, window handle reused)
    c.store(10, 101, true);
    CHECK(c.lookup(10, 101, r) && r);
    c.reset();  // focus change
    CHECK(!c.lookup(10, 101, r));
}

// 2026-11 (Gmail "#"): a browser context with no editable element claims no key until a
// probe finds a caret again, a focus change or an edit report.
TEST(no_editable_context_suspects_until_caret_or_focus) {
    NoEditableContext n;
    int a = 0, b = 0;
    CHECK(!n.suspects(&a));
    CHECK(n.afterProbe(&a, false));  // not suspected: claim as usual
    n.note(&a);
    CHECK(n.suspects(&a));
    CHECK(!n.suspects(&b));          // another context is not
    CHECK(!n.afterProbe(&a, false)); // still no caret: claim nothing
    CHECK(n.suspects(&a));
    CHECK(n.afterProbe(&a, true));   // a field got focus inside the page
    CHECK(!n.suspects(&a));
    n.note(&a);
    n.clear();                       // focus change / the store reported an edit
    CHECK(!n.suspects(&a));
    CHECK(!n.suspects(nullptr));
}

// Tự thêm dấu mũ (#166): bit 32, the first bool of the snapshot's extension word (after the
// appModes block). Older parsers stop at bit 31 and ignore it; a 32-bool snapshot (from an
// older VietTelex.exe) leaves it at its default.
TEST(settings_auto_circumflex_extension_bit) {
    size_t n = 0;
    const BoolKey* keys = boolKeys(&n);
    CHECK(n >= 33);
    CHECK_EQ(std::string(keys[31].name), std::string("switchSound"));
    CHECK_EQ(std::string(keys[32].name), std::string("autoCircumflex"));
    Settings d;
    CHECK(!d.autoCircumflex);
    CHECK(!(d.engineFlags() & VTX_AUTO_CIRCUMFLEX));
    Settings s;
    s.autoCircumflex = true;
    s.switchSound = true;
    s.appModes["notepad.exe"] = AppMode::Composition;
    CHECK(s.engineFlags() & VTX_AUTO_CIRCUMFLEX);
    std::vector<uint8_t> b = serialize(s);
    Settings r;
    CHECK(deserialize(b.data(), b.size(), r));
    CHECK(r.autoCircumflex && r.switchSound);
    CHECK(r == s);
    // Off round-trips too (and differs from on).
    Settings off = s;
    off.autoCircumflex = false;
    b = serialize(off);
    CHECK(deserialize(b.data(), b.size(), r));
    CHECK(!r.autoCircumflex && r.switchSound);
    CHECK(!(r == s));
    // A 32-bool snapshot (older writer): no extension word, the bit keeps its default.
    b = serialize(s);
    CHECK(b.size() > 12);
    b[6] = 32;
    b[7] = 0;
    b.resize(b.size() - 4);
    CHECK(deserialize(b.data(), b.size(), r));
    CHECK(!r.autoCircumflex && r.switchSound);
    CHECK_EQ(r.appModes.size(), size_t(1));
    // Claims 33 bools but the extension word is cut off: malformed.
    b[6] = 33;
    CHECK(!deserialize(b.data(), b.size(), r));
}
