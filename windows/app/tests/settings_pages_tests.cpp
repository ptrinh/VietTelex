// Settings window page plan (core/settings_pages.h, docs/SETTINGS-CLEANUP-SPEC.md) and the
// UI strings it relies on: where every switch lives, dependents hidden under their parent, the
// profile picker still reaching its switches, the §3 labels, and no other input method
// named in any string.
#include <cstdio>
#include <cwchar>
#include <cwctype>
#include <string>
#include <vector>

#include "onboarding.h"
#include "settings.h"
#include "settings_pages.h"
#include "strings.h"
#include "test.h"

using namespace vtx;
using namespace vtx::app;

namespace {
using Field = bool Settings::*;

// Every switch the window shows (settings_window.cpp kToggles).
const Field kAllToggles[] = {
    &Settings::simpleTelex,      &Settings::freeMarking,        &Settings::quickTelex,
    &Settings::modernOrthography, &Settings::bracketVowels,     &Settings::autoRestore,
    &Settings::liveSpellCheck,   &Settings::contextualEnglish,  &Settings::collisionPrefersVietnamese,
    &Settings::teencode,         &Settings::reEditWord,         &Settings::autoUpdateCheck,
    &Settings::debugLogging,     &Settings::showTrayIcon,       &Settings::textToolsInMenu,
    &Settings::mathResults,      &Settings::numberChips,        &Settings::typoHints,
    &Settings::toneHints,        &Settings::dateHints,          &Settings::underlineMisspelled,
    &Settings::autoOffFullscreen, &Settings::gameMode,          &Settings::filterSensitive,
    &Settings::learnWords,       &Settings::retroactiveEnglish, &Settings::englishByFrequency,
    &Settings::startEnglish,     &Settings::startHidden,        &Settings::switchSound,
    &Settings::autoCircumflex,
};

PageContext allOpen() {
    PageContext c;
    for (bool& e : c.expanded) e = true;
    return c;
}

std::vector<PageRow> allRows(const Settings& s, const PageContext& c) {
    std::vector<PageRow> out;
    for (int p = 0; p < static_cast<int>(SettingsPage::Count); ++p)
        for (const PageRow& r : settingsPageRows(static_cast<SettingsPage>(p), s, c)) out.push_back(r);
    return out;
}

// Every parent on (and Telex): no dependent row is left out.
Settings allParentsOn() {
    Settings s;
    s.vniMode = false;
    s.autoRestore = s.contextualEnglish = s.showTrayIcon = true;
    return s;
}

bool hasControl(const std::vector<PageRow>& rows, PageControl c) {
    for (const PageRow& r : rows)
        if (r.kind == RowKind::Control && r.id == static_cast<int>(c)) return true;
    return false;
}

const PageRow* rowOf(const std::vector<PageRow>& rows, Field f) {
    for (const PageRow& r : rows)
        if (r.kind == RowKind::Toggle && r.field == f) return &r;
    return nullptr;
}

bool placed(Field f, SettingsPage page, int expander) {
    SettingsPage p = SettingsPage::Count;
    int e = -2;
    return findToggle(f, p, e) && p == page && e == expander;
}
int ex(Expander e) { return static_cast<int>(e); }
}  // namespace

TEST(settings_pages_every_switch_once) {
    const std::vector<PageRow> rows = allRows(allParentsOn(), allOpen());
    for (Field f : kAllToggles) {
        int n = 0;
        for (const PageRow& r : rows)
            if (r.kind == RowKind::Toggle && r.field == f) ++n;
        CHECK_EQ(n, 1);
    }
    int toggles = 0;
    for (const PageRow& r : rows)
        if (r.kind == RowKind::Toggle) ++toggles;
    CHECK_EQ(toggles, static_cast<int>(sizeof(kAllToggles) / sizeof(kAllToggles[0])));
}

// §4 desktop structure: Gõ phím · Gợi ý & công cụ · Gõ tắt · Ứng dụng · Chung.
TEST(settings_pages_structure) {
    // Kiểu gõ → Nâng cao, teencode included (it was on the Chính tả page).
    for (Field f : {&Settings::simpleTelex, &Settings::freeMarking, &Settings::quickTelex, &Settings::modernOrthography,
                    &Settings::teencode, &Settings::bracketVowels, &Settings::autoCircumflex, &Settings::reEditWord})
        CHECK(placed(f, SettingsPage::Typing, ex(Expander::TypingAdvanced)));
    // Gõ lẫn tiếng Anh → Nâng cao: English detection.
    for (Field f : {&Settings::autoRestore, &Settings::collisionPrefersVietnamese, &Settings::contextualEnglish,
                    &Settings::retroactiveEnglish, &Settings::englishByFrequency})
        CHECK(placed(f, SettingsPage::Typing, ex(Expander::MixedAdvanced)));
    CHECK(placed(&Settings::startEnglish, SettingsPage::Typing, ex(Expander::SwitchAdvanced)));
    CHECK(placed(&Settings::switchSound, SettingsPage::Typing, ex(Expander::SwitchAdvanced)));
    CHECK(placed(&Settings::liveSpellCheck, SettingsPage::Typing, -1));
    CHECK(placed(&Settings::underlineMisspelled, SettingsPage::Typing, -1));
    CHECK(placed(&Settings::numberChips, SettingsPage::Suggestions, -1));
    CHECK(placed(&Settings::learnWords, SettingsPage::Suggestions, -1));
    CHECK(placed(&Settings::textToolsInMenu, SettingsPage::Suggestions, ex(Expander::TextTools)));
    CHECK(placed(&Settings::gameMode, SettingsPage::Apps, ex(Expander::Games)));
    CHECK(placed(&Settings::autoOffFullscreen, SettingsPage::Apps, ex(Expander::Games)));
    CHECK(placed(&Settings::showTrayIcon, SettingsPage::General, ex(Expander::Appearance)));
    CHECK(placed(&Settings::startHidden, SettingsPage::General, ex(Expander::Appearance)));
    CHECK(placed(&Settings::debugLogging, SettingsPage::General, -1));

    // Collapsed (the default): the Typing page's top level is short — sections, the method,
    // the profile rows, the switch key, three expanders and the two spelling switches.
    const PageContext closed;
    const std::vector<PageRow> top = settingsPageRows(SettingsPage::Typing, Settings(), closed);
    int expanders = 0, toggles = 0;
    for (const PageRow& r : top) {
        if (r.kind == RowKind::Expander) ++expanders;
        if (r.kind == RowKind::Toggle) ++toggles;
        CHECK_EQ(r.indent, 0);
    }
    CHECK_EQ(expanders, 3);
    CHECK_EQ(toggles, 2);
    CHECK(top.size() <= 12);
    // The switch key is the main control of "Chuyển Việt/Anh", outside the expander.
    bool sawSwitchSection = false, hotkeyTop = false;
    for (const PageRow& r : top) {
        if (r.kind == RowKind::Section && r.id == static_cast<int>(PageSection::Switch)) sawSwitchSection = true;
        if (sawSwitchSection && r.kind == RowKind::Control && r.id == static_cast<int>(PageControl::SwitchHotkey))
            hotkeyTop = true;
    }
    CHECK(hotkeyTop);
    // The Windows word-prediction setting is a link row, not a switch.
    bool link = false;
    for (const PageRow& r : settingsPageRows(SettingsPage::Suggestions, Settings(), closed))
        if (r.kind == RowKind::Control && r.id == static_cast<int>(PageControl::TextPredictionLink)) link = true;
    CHECK(link);
    // Expanders never nest: every expander row is at page level.
    for (const PageRow& r : allRows(Settings(), allOpen()))
        if (r.kind == RowKind::Expander) CHECK_EQ(r.indent, 0);
}

// The "Gõ lẫn tiếng Anh" group: hidden as a whole under VNI (SETTINGS-CLEANUP-SPEC §1).
static const Field kMixedToggles[] = {&Settings::autoRestore, &Settings::collisionPrefersVietnamese,
                               &Settings::contextualEnglish, &Settings::retroactiveEnglish,
                               &Settings::englishByFrequency};
static bool isMixedToggle(Field f) {
    for (Field m : kMixedToggles)
        if (m == f) return true;
    return false;
}

// Telex-only switches under VNI are hidden (they sit in Kiểu gõ → Nâng cao, right under
// the Telex/VNI choice); teencode and bracket vowels work in VNI too and always show.
TEST(settings_pages_vni_hides_telex_only) {
    Settings telex = allParentsOn(), vni = allParentsOn();
    vni.vniMode = true;
    const std::vector<PageRow> a = allRows(telex, allOpen()), b = allRows(vni, allOpen());
    int hidden = 0;
    for (Field f : kAllToggles) {
        if (isMixedToggle(f)) continue;  // the whole group is hidden under VNI (next test)
        CHECK(rowOf(a, f) != nullptr);
        const bool gone = rowOf(b, f) == nullptr;
        if (gone) ++hidden;
        CHECK(gone == isTelexOnly(f));
    }
    CHECK_EQ(hidden, 3);
    CHECK(isTelexOnly(&Settings::simpleTelex) && isTelexOnly(&Settings::freeMarking) &&
          isTelexOnly(&Settings::quickTelex));
    CHECK(!isTelexOnly(&Settings::teencode) && !isTelexOnly(&Settings::bracketVowels));
    CHECK(!isTelexOnly(&Settings::modernOrthography));  // tone placement applies to VNI too
    for (Field f : {&Settings::teencode, &Settings::bracketVowels, &Settings::modernOrthography})
        CHECK(!hiddenByParent(vni, f));
    // Display only: the stored values stay.
    vni.simpleTelex = vni.quickTelex = true;
    (void)allRows(vni, allOpen());
    CHECK(vni.simpleTelex && vni.quickTelex && vni.vniMode);
}

// VNI hides the whole "Gõ lẫn tiếng Anh" group (profile rows + Nâng cao) and shows one
// line in its place; "Chuyển Việt/Anh" stays. Switching back to Telex brings it back as it
// was, and the page plan never writes a setting.
TEST(settings_pages_vni_hides_mixed_group) {
    Settings telex, vni;
    vni.vniMode = true;
    vni.autoRestore = true;  // whatever the stored values, nothing of the group shows
    vni.contextualEnglish = true;
    CHECK(!hidesMixedGroup(telex));
    CHECK(hidesMixedGroup(vni));
    for (const PageContext& c : {PageContext(), allOpen()}) {
        const std::vector<PageRow> v = settingsPageRows(SettingsPage::Typing, vni, c);
        const std::vector<PageRow> t = settingsPageRows(SettingsPage::Typing, telex, c);
        auto has = [](const std::vector<PageRow>& rows, RowKind k, int id) {
            for (const PageRow& r : rows)
                if (r.kind == k && r.id == id) return true;
            return false;
        };
        const int note = static_cast<int>(PageControl::MixedVniNote);
        const int profiles = static_cast<int>(PageControl::ProfileRows);
        const int mixedAdv = static_cast<int>(Expander::MixedAdvanced);
        CHECK(has(v, RowKind::Control, note));
        CHECK(!has(v, RowKind::Control, profiles));
        CHECK(!has(v, RowKind::Expander, mixedAdv));
        CHECK(!has(t, RowKind::Control, note));
        CHECK(has(t, RowKind::Control, profiles));
        CHECK(has(t, RowKind::Expander, mixedAdv));
        for (Field f : kMixedToggles) {
            CHECK(rowOf(v, f) == nullptr);
            if (c.isExpanded(Expander::MixedAdvanced)) CHECK(rowOf(t, f) != nullptr);
        }
        // The note sits right under the "Gõ lẫn tiếng Anh" header, at page level, and the
        // next row is the "Chuyển Việt/Anh" header with its switch key.
        size_t at = v.size();
        for (size_t i = 0; i < v.size(); ++i)
            if (v[i].kind == RowKind::Control && v[i].id == note) at = i;
        CHECK(at > 0 && at + 2 < v.size());
        if (at > 0 && at + 2 < v.size()) {
            CHECK(v[at - 1].kind == RowKind::Section && v[at - 1].id == static_cast<int>(PageSection::Mixed));
            CHECK_EQ(v[at].indent, 0);
            CHECK(v[at + 1].kind == RowKind::Section && v[at + 1].id == static_cast<int>(PageSection::Switch));
            CHECK(v[at + 2].kind == RowKind::Control && v[at + 2].id == static_cast<int>(PageControl::SwitchHotkey));
        }
        CHECK(rowOf(v, &Settings::startEnglish) != nullptr || !c.isExpanded(Expander::SwitchAdvanced));
    }
    // Stored values untouched by building the page.
    CHECK(vni.autoRestore && vni.contextualEnglish && vni.vniMode);
    // The line itself (both languages, one short caption, no other input method named:
    // covered by the generic string tests below).
    setEnglish(false);
    CHECK(std::wcscmp(tr(S::MixedVniNote), L"Gõ VNI không làm đổi từ tiếng Anh nên không cần chỉnh phần này.") == 0);
    setEnglish(true);
    CHECK(std::wcscmp(tr(S::MixedVniNote), L"VNI leaves English words as typed, so there is nothing to set here.") == 0);
    setEnglish(false);
}

// "Tự sửa từ phía trước" / "Đoán từ trùng theo tần suất": right under "Quyết định theo ngữ
// cảnh", hidden while it is off; "Khi từ vừa Anh vừa Việt" and the frequency guess hidden
// while "Tự khôi phục từ tiếng Anh" is off (§6).
TEST(settings_pages_mixed_dependents_hidden) {
    Settings s = allParentsOn();
    std::vector<PageRow> rows = settingsPageRows(SettingsPage::Typing, s, allOpen());
    size_t parent = rows.size();
    for (size_t i = 0; i < rows.size(); ++i)
        if (rows[i].kind == RowKind::Toggle && rows[i].field == &Settings::contextualEnglish) parent = i;
    CHECK(parent + 2 < rows.size());
    if (parent + 2 < rows.size()) {
        CHECK(rows[parent + 1].field == &Settings::retroactiveEnglish);
        CHECK(rows[parent + 2].field == &Settings::englishByFrequency);
        CHECK(rows[parent + 1].indent > rows[parent].indent);
    }
    // Collision choice sits right under auto-restore.
    for (size_t i = 0; i + 1 < rows.size(); ++i)
        if (rows[i].kind == RowKind::Toggle && rows[i].field == &Settings::autoRestore)
            CHECK(rows[i + 1].field == &Settings::collisionPrefersVietnamese);

    s.contextualEnglish = false;
    rows = settingsPageRows(SettingsPage::Typing, s, allOpen());
    CHECK(rowOf(rows, &Settings::contextualEnglish) != nullptr);
    CHECK(rowOf(rows, &Settings::retroactiveEnglish) == nullptr);
    CHECK(rowOf(rows, &Settings::englishByFrequency) == nullptr);
    CHECK(rowOf(rows, &Settings::collisionPrefersVietnamese) != nullptr);

    s = allParentsOn();
    s.autoRestore = false;
    rows = settingsPageRows(SettingsPage::Typing, s, allOpen());
    CHECK(rowOf(rows, &Settings::autoRestore) != nullptr);
    CHECK(rowOf(rows, &Settings::collisionPrefersVietnamese) == nullptr);
    CHECK(rowOf(rows, &Settings::englishByFrequency) == nullptr);
    CHECK(rowOf(rows, &Settings::contextualEnglish) != nullptr);
    CHECK(rowOf(rows, &Settings::retroactiveEnglish) != nullptr);
    CHECK(!s.autoRestore && s.collisionPrefersVietnamese == Settings().collisionPrefersVietnamese);

    // These parents rebuild the page as soon as they change; plain switches do not.
    CHECK(affectsLayout(&Settings::autoRestore) && affectsLayout(&Settings::contextualEnglish) &&
          affectsLayout(&Settings::showTrayIcon));
    CHECK(!affectsLayout(&Settings::teencode) && !affectsLayout(&Settings::learnWords));
}

// Tray icon off: "Kiểu biểu tượng khay" and the tray menu's "Hiện công cụ văn bản trong menu"
// are hidden (main.cpp builds no tray, so no menu).
TEST(settings_pages_tray_dependents_hidden) {
    Settings on = allParentsOn(), off = allParentsOn();
    off.showTrayIcon = false;
    const std::vector<PageRow> gOn = settingsPageRows(SettingsPage::General, on, allOpen());
    const std::vector<PageRow> gOff = settingsPageRows(SettingsPage::General, off, allOpen());
    CHECK(hasControl(gOn, PageControl::TrayStyle));
    CHECK(!hasControl(gOff, PageControl::TrayStyle));
    CHECK(rowOf(gOff, &Settings::showTrayIcon) != nullptr);
    // Right under the tray switch.
    for (size_t i = 0; i + 1 < gOn.size(); ++i)
        if (gOn[i].kind == RowKind::Toggle && gOn[i].field == &Settings::showTrayIcon)
            CHECK(gOn[i + 1].kind == RowKind::Control && gOn[i + 1].id == static_cast<int>(PageControl::TrayStyle));
    CHECK(rowOf(settingsPageRows(SettingsPage::Suggestions, on, allOpen()), &Settings::textToolsInMenu) != nullptr);
    const std::vector<PageRow> sOff = settingsPageRows(SettingsPage::Suggestions, off, allOpen());
    CHECK(rowOf(sOff, &Settings::textToolsInMenu) == nullptr);
    CHECK(hasControl(sOff, PageControl::AddTonesHotkey));  // the hotkey works without the tray
    // Default (tray off since 1.0.5): hidden.
    CHECK(hiddenByParent(Settings(), &Settings::textToolsInMenu));
}

// The one-time upgrade card: hidden under VNI (its "Xem" points at the hidden group), back
// after switching to Telex — the page plan never clears the flag.
TEST(settings_pages_mixed_card_follows_vni) {
    Settings telex, vni;
    vni.vniMode = true;
    PageContext c;
    c.mixedCardPending = true;
    CHECK(showsMixedCard(telex, c));
    CHECK(!showsMixedCard(vni, c));
    CHECK(hasControl(settingsPageRows(SettingsPage::Typing, telex, c), PageControl::MixedCard));
    CHECK(!hasControl(settingsPageRows(SettingsPage::Typing, vni, c), PageControl::MixedCard));
    CHECK(c.mixedCardPending);
    c.mixedCardPending = false;
    CHECK(!showsMixedCard(telex, c));
}

// Portable (keyboard hook, no TIP): every switch that only the TIP makes work is hidden,
// the "Gợi ý cạnh con trỏ" group as a whole (one line instead), the installed build shows
// everything as before. Display only: no value changes.
TEST(settings_pages_portable_hides_tip_only_rows) {
    const Field kTipOnly[] = {&Settings::retroactiveEnglish, &Settings::englishByFrequency,
                              &Settings::underlineMisspelled, &Settings::mathResults,
                              &Settings::numberChips,        &Settings::typoHints,
                              &Settings::toneHints,          &Settings::dateHints,
                              &Settings::filterSensitive,    &Settings::learnWords};
    auto tipOnly = [&](Field f) {
        for (Field t : kTipOnly)
            if (t == f) return true;
        return false;
    };
    PageContext installed = allOpen(), portable = allOpen();
    portable.portable = true;
    const Settings s = allParentsOn();
    const std::vector<PageRow> a = allRows(s, installed), b = allRows(s, portable);
    for (Field f : kAllToggles) {
        CHECK(rowOf(a, f) != nullptr);
        CHECK((rowOf(b, f) == nullptr) == tipOnly(f));
        CHECK(hiddenInPortable(f) == tipOnly(f));
    }
    // "Sửa dấu từ đã gõ" works in portable (⌫ back into the word, hook_reopen.h): it stays.
    CHECK(rowOf(b, &Settings::reEditWord) != nullptr);
    // Their groups keep the switches that do work: Quyết định theo ngữ cảnh, Chính tả.
    CHECK(rowOf(b, &Settings::contextualEnglish) != nullptr);
    CHECK(rowOf(b, &Settings::liveSpellCheck) != nullptr);

    // Gợi ý & công cụ: the hints group is gone (header, learned-words reset, Windows' prediction
    // link), one note line stands in, Công cụ văn bản stays.
    for (const PageContext& base : {PageContext(), allOpen()}) {
        PageContext pc = base, ic = base;
        pc.portable = true;
        const std::vector<PageRow> p = settingsPageRows(SettingsPage::Suggestions, s, pc);
        const std::vector<PageRow> i = settingsPageRows(SettingsPage::Suggestions, s, ic);
        bool pHints = false, iHints = false;
        for (const PageRow& r : p)
            if (r.kind == RowKind::Section && r.id == static_cast<int>(PageSection::Hints)) pHints = true;
        for (const PageRow& r : i)
            if (r.kind == RowKind::Section && r.id == static_cast<int>(PageSection::Hints)) iHints = true;
        CHECK(!pHints && iHints);
        CHECK(hasControl(p, PageControl::PortableHintsNote));
        CHECK(!hasControl(i, PageControl::PortableHintsNote));
        CHECK(!hasControl(p, PageControl::ClearLearned) && hasControl(i, PageControl::ClearLearned));
        CHECK(!hasControl(p, PageControl::TextPredictionLink) && hasControl(i, PageControl::TextPredictionLink));
        CHECK(!p.empty() && p.front().kind == RowKind::Control &&
              p.front().id == static_cast<int>(PageControl::PortableHintsNote) && p.front().indent == 0);
        bool tools = false;
        for (const PageRow& r : p)
            if (r.kind == RowKind::Expander && r.id == static_cast<int>(Expander::TextTools)) tools = true;
        CHECK(tools);
        if (base.isExpanded(Expander::TextTools)) {
            CHECK(hasControl(p, PageControl::AddTonesHotkey));
            CHECK(rowOf(p, &Settings::textToolsInMenu) != nullptr);
        }
    }
    // Where a switch lives is unchanged (findToggle uses the installed plan).
    for (Field f : kTipOnly) {
        SettingsPage pg = SettingsPage::Count;
        int e = -2;
        CHECK(findToggle(f, pg, e));
    }
    // The note line and the portable caption of "Sửa dấu từ đã gõ", both languages.
    setEnglish(false);
    CHECK(std::wcscmp(tr(S::PortableHintsNote), L"Bản portable không có gợi ý từ — dùng bản cài để có gợi ý.") == 0);
    CHECK(std::wcsstr(tr(S::ReEditWordPortableDesc), L"toán") != nullptr);
    setEnglish(true);
    CHECK(std::wcscmp(tr(S::PortableHintsNote),
                      L"The portable version has no suggestions — use the installed version for them.") == 0);
    CHECK(std::wcsstr(tr(S::ReEditWordPortableDesc), L"Backspace") != nullptr);
    setEnglish(false);
}

// (a) The profile picker writes the same keys as before, and each one is on the page that
// holds the picker.
TEST(settings_pages_profile_switches_reachable) {
    for (Field f : profileFields()) {
        SettingsPage p = SettingsPage::Count;
        int e = -2;
        CHECK(findToggle(f, p, e));
        CHECK(p == SettingsPage::Typing);
    }
    Settings s;
    applyProfile(s, TypingProfile::En);
    CHECK(s.startEnglish && s.contextualEnglish && s.englishByFrequency);
    applyProfile(s, TypingProfile::Vi);
    CHECK(!s.startEnglish);
    // The page plan never writes settings.
    Settings before;
    (void)allRows(before, allOpen());
    TypingProfile m = TypingProfile::En;
    CHECK(matchProfile(before, "", m) && m == TypingProfile::Vi);
}

// (d) §3 labels (vi) and the new page/group names.
TEST(settings_strings_labels) {
    setEnglish(false);
    CHECK(std::wcscmp(tr(S::FreeMarking), L"Bỏ dấu tự do") == 0);
    CHECK(std::wcscmp(tr(S::ModernOrthography), L"Bỏ dấu kiểu mới (oà, uý)") == 0);
    CHECK(std::wcscmp(tr(S::ReEditWord), L"Sửa dấu từ đã gõ") == 0);
    CHECK(std::wcscmp(tr(S::NumberChips), L"Gợi ý số tiền") == 0);
    CHECK(std::wcscmp(tr(S::AutoRestore), L"Tự khôi phục từ tiếng Anh") == 0);
    CHECK(std::wcsstr(tr(S::AutoRestoreDesc), L"google, github") != nullptr);
    CHECK(std::wcscmp(tr(S::SecMixed), L"Gõ lẫn tiếng Anh") == 0);
    CHECK(std::wcscmp(tr(S::SecSwitch), L"Chuyển Việt/Anh") == 0);
    CHECK(std::wcscmp(tr(S::Advanced), L"Nâng cao") == 0);
    CHECK(std::wcsstr(tr(S::CollisionPrefersViDesc), L"lisst → list") != nullptr);
    CHECK(std::wcscmp(tr(S::TabTyping), L"Gõ phím") == 0);
    CHECK(std::wcscmp(tr(S::TabSpelling), L"Gợi ý & công cụ") == 0);
    CHECK(std::wcscmp(tr(S::TabShortcuts), L"Gõ tắt") == 0);
    CHECK(std::wcscmp(tr(S::TabApps), L"Ứng dụng") == 0);
    CHECK(std::wcscmp(tr(S::TabAbout), L"Chung") == 0);
    CHECK(std::wcsstr(tr(S::ProfileIntro), L"Gõ phím → Gõ lẫn tiếng Anh") != nullptr);
    CHECK(std::wcsstr(tr(S::MixedCardDesc), L"Gõ lẫn tiếng Anh") != nullptr);
    setEnglish(true);
    CHECK(std::wcscmp(tr(S::SecMixed), L"Mixed Vietnamese/English typing") == 0);
    setEnglish(false);
}

// (c) No string names another Vietnamese input method (names stored ROT13 so this file
// does not spell them either).
TEST(settings_strings_no_other_input_method_names) {
    const char* const kRot13[] = {"havxrl", "bcraxrl", "rixrl", "ivrgxrl", "tbgvrativrg", "ynonaxrl", "onzobb", "kxrl"};
    std::vector<std::wstring> names;
    for (const char* r : kRot13) {
        std::wstring n;
        for (const char* c = r; *c; ++c) n.push_back(static_cast<wchar_t>((*c - 'a' + 13) % 26 + 'a'));
        names.push_back(n);
    }
    for (int en = 0; en < 2; ++en) {
        setEnglish(en != 0);
        for (int i = 0; i < static_cast<int>(S::Count); ++i) {
            std::wstring s;
            for (const wchar_t* p = tr(static_cast<S>(i)); *p; ++p)
                s.push_back(*p < 128 ? static_cast<wchar_t>(std::towlower(*p)) : *p);  // ASCII case-fold
            for (const std::wstring& n : names)
                if (s.find(n) != std::wstring::npos) {
                    std::printf("  string %d (%s) names another input method\n", i, en ? "en" : "vi");
                    CHECK(false);
                }
        }
    }
    setEnglish(false);
}

// Every caption the settings window shows is ONE short line (maintainer 06/11/2026: "too wordy,
// cramped"): <= 95 characters in both languages, same limit as macOS SettingsCleanupTests.
TEST(settings_captions_are_short) {
    const S kCaptions[] = {
        S::InputMethodDesc, S::SimpleTelexDesc, S::FreeMarkingDesc, S::QuickTelexDesc,
        S::ModernOrthographyDesc, S::BracketVowelsDesc, S::AutoRestoreDesc, S::LiveSpellCheckDesc,
        S::ContextualEnglishDesc, S::CollisionPrefersViDesc, S::TeencodeDesc, S::ReEditWordDesc,
        S::SwitchHotkeyDesc, S::MenuIconDesc, S::ShowTrayDesc, S::UiLanguageDesc, S::AutoUpdateCheckDesc,
        S::DebugLoggingDesc, S::CheckNowDesc, S::UninstallDesc, S::ShortcutsDesc, S::AppsDesc,
        S::HotkeyNoteWinPerApp, S::HotkeyNoteWinGlobal, S::HotkeyNoteWinUnknown,
        S::PerAppWinOn, S::PerAppWinOff, S::PerAppWinUnknown,
        S::TextToolsInMenuDesc, S::AddTonesHotkeyDesc, S::TextToolsSummary,
        S::MathResultsDesc, S::NumberChipsDesc, S::TypoHintsDesc, S::ToneHintsDesc, S::DateHintsDesc,
        S::FilterSensitiveDesc, S::UnderlineMisspelledDesc, S::AutoOffFullscreenDesc, S::GameModeDesc,
        S::GameModeHotkeyDesc, S::SwitchIndicatorDesc, S::ConflictDesc, S::WinHotkeyDesc,
        S::DefaultInputDesc, S::TextToolsNoTray, S::LearnWordsDesc, S::ClearLearnedDesc, S::TrayStyleDesc,
        S::RetroEnglishDesc, S::EnglishByFrequencyDesc, S::StartEnglishDesc, S::StartHiddenDesc, S::SwitchSoundDesc, S::AutoCircumflexDesc, S::MixedCardDesc,
        S::ProfilePickerIntro, S::ProfileCustomDesc, S::ProfileViEx, S::ProfileMixedEx, S::ProfileEnEx,
        S::TypingAdvancedSummary, S::MixedAdvancedSummary, S::SwitchAdvancedSummary, S::GamesSummary,
        S::AppearanceSummary, S::MixedVniNote, S::PortableHintsNote, S::ReEditWordPortableDesc,
        S::ModeComposition, S::ModeInPlace, S::ModeHook, S::ModeOff, S::ModeDirect,
    };
    for (int en = 0; en < 2; ++en) {
        setEnglish(en != 0);
        for (S id : kCaptions) {
            const size_t n = std::wcslen(tr(id));
            if (n > 95) {
                std::printf("  caption %d (%s) is %zu chars\n", static_cast<int>(id), en ? "en" : "vi", n);
                CHECK(false);
            }
        }
        // The text-prediction row joins the state and its caption.
        CHECK(textPredictionDesc(true).size() <= 95);
        CHECK(textPredictionDesc(false).size() <= 95);
    }
    setEnglish(false);
    // Per-app mode names describe the symptom, not the mechanism (same spirit as Linux/macOS).
    for (S id : {S::ModeComposition, S::ModeInPlace, S::ModeHook, S::ModeDirect})
        for (const wchar_t* jargon : {L"Composition", L"hook", L"Dự phòng"}) CHECK(std::wcsstr(tr(id), jargon) == nullptr);
}
