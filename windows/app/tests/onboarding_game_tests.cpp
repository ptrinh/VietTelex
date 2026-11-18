// Onboarding (per-user setup, welcome, conflicts, "Chuyển từ UniKey") and games /
// fullscreen / V-E indicator / terminal Direct policy — the portable decisions.
#include <cstdio>
#include <fstream>
#include <iterator>
#include <string>
#include <vector>

#include "app_policy.h"
#include "direct_policy.h"
#include "game_logic.h"
#include "macro_import.h"
#include "onboarding.h"
#include "registration.h"
#include "settings.h"
#include <viettelex/vtx_engine.h>
#include "test.h"

using namespace vtx;

namespace {
std::string readFile(const std::string& path) {
    std::ifstream f(path, std::ios::binary);
    return std::string(std::istreambuf_iterator<char>(f), std::istreambuf_iterator<char>());
}
std::string fixture(const char* name) { return readFile(std::string(VTX_APP_FIXTURES) + "/macros/" + name); }
}  // namespace

// ---------------------------------------------------------------- per-user setup

TEST(setup_user_args) {
    SetupTrigger t;
    CHECK(!parseSetupUserArgs({L"--background"}, t));
    CHECK(parseSetupUserArgs({L"--setup-user"}, t));
    CHECK(t == SetupTrigger::Installer);
    CHECK(parseSetupUserArgs({L"--setup-user", L"--active-setup"}, t));
    CHECK(t == SetupTrigger::ActiveSetup);
}

TEST(setup_user_as_system_does_nothing) {
    // msiexec /qn from the Store / Intune runs as SYSTEM: its HKCU is nobody's.
    UserSetupState s;
    s.systemAccount = true;
    for (SetupTrigger t : {SetupTrigger::Installer, SetupTrigger::ActiveSetup, SetupTrigger::AppStart}) {
        const UserSetupPlan p = planUserSetup(t, s);
        CHECK(!p.addKeyboard && !p.autostart && !p.markDone && !p.welcomePending);
    }
}

TEST(setup_user_active_setup_first_logon) {
    UserSetupState s;  // never set up
    const UserSetupPlan p = planUserSetup(SetupTrigger::ActiveSetup, s);
    CHECK(p.addKeyboard && p.autostart && p.markDone);
    CHECK(p.welcomePending);  // shown by the autostart once the desktop is up, never by the stub
}

TEST(setup_user_is_idempotent_and_respects_removal) {
    UserSetupState s;
    UserSetupPlan p = planUserSetup(SetupTrigger::ActiveSetup, s);
    // Apply it, run again (Active Setup again, or the app starting): nothing more happens —
    // in particular a keyboard the user removed since is NOT re-added.
    s.setupDone = p.markDone;
    for (SetupTrigger t : {SetupTrigger::ActiveSetup, SetupTrigger::AppStart}) {
        p = planUserSetup(t, s);
        CHECK(!p.addKeyboard && !p.autostart && !p.markDone && !p.welcomePending);
    }
}

TEST(setup_user_installer_always_ensures) {
    UserSetupState s;
    UserSetupPlan p = planUserSetup(SetupTrigger::Installer, s);
    CHECK(p.addKeyboard && p.autostart && p.markDone && p.welcomePending);
    // Upgrade / repair by the same user: keyboard + autostart again (InstallLayoutOrTip is
    // idempotent), but no second welcome.
    s.setupDone = true;
    p = planUserSetup(SetupTrigger::Installer, s);
    CHECK(p.addKeyboard && p.autostart && !p.welcomePending);
}

TEST(setup_user_app_start_for_new_user) {
    UserSetupState s;
    const UserSetupPlan p = planUserSetup(SetupTrigger::AppStart, s);
    CHECK(p.addKeyboard && p.autostart && p.markDone);
    CHECK(!p.welcomePending);  // decideWelcome shows it in this same run
    CHECK(decideWelcome(true, false, false, /*setupDoneBefore*/ false) == WelcomeAction::Show);
}

TEST(welcome_decisions) {
    CHECK(decideWelcome(true, true, false, true) == WelcomeAction::Show);       // Active Setup / installer pending
    CHECK(decideWelcome(false, true, false, true) == WelcomeAction::Nothing);   // one-shot command: later
    CHECK(decideWelcome(true, true, true, true) == WelcomeAction::Nothing);     // already shown
    CHECK(decideWelcome(true, false, false, true) == WelcomeAction::MarkShown); // upgrade from pre-onboarding
    CHECK(decideWelcome(false, false, false, true) == WelcomeAction::MarkShown);
}

// ---- Onboarding profiles (docs/ONBOARDING-SPEC.md §2/§3/§5) ------------------------

TEST(onboarding_profile_vi_is_todays_defaults) {
    Settings d;
    Settings s = d;
    s.retroactiveEnglish = s.englishByFrequency = s.startEnglish = true;  // anything applyProfile owns
    s.autoRestore = s.contextualEnglish = s.collisionPrefersVietnamese = false;
    applyProfile(s, TypingProfile::Vi);
    CHECK(s == d);  // operator== compares every bool key, startEnglish included
    CHECK(!s.startEnglish && !s.retroactiveEnglish && !s.englishByFrequency);
}

TEST(onboarding_profile_mixed_and_en) {
    Settings m;
    applyProfile(m, TypingProfile::Mixed);
    CHECK(m.autoRestore && m.contextualEnglish && m.retroactiveEnglish && m.englishByFrequency &&
          m.collisionPrefersVietnamese);
    CHECK(!m.startEnglish);
    // englishByFrequency reaches the engine (needs the retro flag, which contextualEnglish turns on).
    CHECK((m.engineFlags() & VTX_ENGLISH_BY_FREQUENCY) != 0);
    Settings e;
    applyProfile(e, TypingProfile::En);
    CHECK(e.startEnglish);  // Windows has an English mode: new apps start in it
    e.startEnglish = false;
    CHECK(e == m);
    // Only the mixed-typing switches: nothing else moves.
    Settings other;
    other.vniMode = true;
    other.switchHotkey = "alt-z";
    other.showTrayIcon = true;
    applyProfile(other, TypingProfile::Mixed);
    CHECK(other.vniMode && other.switchHotkey == "alt-z" && other.showTrayIcon);
}

TEST(onboarding_profile_names_and_turned_on) {
    for (TypingProfile p : {TypingProfile::Vi, TypingProfile::Mixed, TypingProfile::En}) {
        TypingProfile back = TypingProfile::Vi;
        CHECK(parseProfile(profileName(p), back) && back == p);
    }
    TypingProfile x = TypingProfile::Mixed;
    CHECK(!parseProfile("custom", x) && x == TypingProfile::Mixed);
    CHECK_EQ(profileTurnedOn(TypingProfile::Vi).size(), size_t(3));     // auto-restore, context, collisions
    CHECK_EQ(profileTurnedOn(TypingProfile::Mixed).size(), size_t(5));
    const auto en = profileTurnedOn(TypingProfile::En);
    CHECK_EQ(en.size(), size_t(6));
    CHECK(en.back() == &Settings::startEnglish);
}

// ---- Quick picker (ONBOARDING-SPEC §4): exact match / Tuỳ chỉnh / confirm / apply --------

TEST(profile_picker_exact_match) {
    TypingProfile m = TypingProfile::En;
    Settings fresh;  // today's defaults = vi
    CHECK(matchProfile(fresh, "", m) && m == TypingProfile::Vi);
    CHECK(matchProfile(fresh, "mixed", m) && m == TypingProfile::Vi);
    for (TypingProfile p : {TypingProfile::Vi, TypingProfile::Mixed, TypingProfile::En}) {
        Settings s;
        s.vniMode = true;  // switches outside the profile do not matter
        s.switchHotkey = "alt-z";
        applyProfile(s, p);
        for (const char* last : {"", "vi", "mixed", "en", "junk"}) {
            CHECK(matchProfile(s, last, m) && m == p);  // mixed and en differ on Windows (startEnglish)
        }
    }
}

TEST(profile_picker_custom_when_any_switch_differs) {
    for (TypingProfile p : {TypingProfile::Vi, TypingProfile::Mixed, TypingProfile::En})
        for (bool Settings::*f : profileFields()) {
            Settings s;
            applyProfile(s, p);
            s.*f = !(s.*f);
            TypingProfile m = TypingProfile::Vi;
            const bool hit = matchProfile(s, profileName(p), m);
            if (f == &Settings::startEnglish && p != TypingProfile::Vi) {
                // Flipping the one switch mixed/en differ on lands exactly on the other profile.
                CHECK(hit && m == (p == TypingProfile::Mixed ? TypingProfile::En : TypingProfile::Mixed));
            } else {
                CHECK(!hit);
            }
        }
}

TEST(profile_picker_confirmation) {
    Settings vi;
    // Matching a profile: switch straight away, even though switches change.
    CHECK_EQ(profileChanges(vi, TypingProfile::Mixed).size(), size_t(2));  // retro + frequency
    CHECK(!profileNeedsConfirmation(vi, TypingProfile::Mixed, ""));
    CHECK(!profileNeedsConfirmation(vi, TypingProfile::En, "vi"));
    // "Tuỳ chỉnh": ask, listing exactly what changes, in profileFields() order.
    Settings custom;
    custom.autoRestore = false;
    const auto ch = profileChanges(custom, TypingProfile::En);
    CHECK_EQ(ch.size(), size_t(4));
    CHECK(ch[0] == &Settings::autoRestore && ch[1] == &Settings::retroactiveEnglish &&
          ch[2] == &Settings::englishByFrequency && ch[3] == &Settings::startEnglish);
    CHECK(profileNeedsConfirmation(custom, TypingProfile::En, "en"));
    CHECK(profileNeedsConfirmation(custom, TypingProfile::Vi, ""));
    CHECK(profileChanges(vi, TypingProfile::Vi).empty());
}

TEST(profile_picker_apply_then_matches) {
    Settings s;
    s.autoRestore = false;
    s.teencode = true;
    TypingProfile m = TypingProfile::Vi;
    CHECK(!matchProfile(s, "", m));
    applyProfile(s, TypingProfile::En);
    CHECK(matchProfile(s, "en", m) && m == TypingProfile::En);
    CHECK(profileChanges(s, TypingProfile::En).empty());
    CHECK(s.teencode);  // nothing outside the profile moves
}

TEST(onboarding_decisions) {
    // New user: welcome then the profile pages.
    CHECK(decideOnboarding(-1, WelcomeAction::Show) == OnboardingAction::ShowWelcome);
    // Cut short last time (0 written when the welcome opened, welcomeShown already 1).
    CHECK(decideOnboarding(0, WelcomeAction::Nothing) == OnboardingAction::ShowProfile);
    CHECK(decideOnboarding(0, WelcomeAction::Show) == OnboardingAction::ShowWelcome);
    // Upgrades from a version without onboarding: card, no pages, no value changes.
    CHECK(decideOnboarding(-1, WelcomeAction::MarkShown) == OnboardingAction::Upgrade);
    CHECK(decideOnboarding(-1, WelcomeAction::Nothing) == OnboardingAction::Upgrade);
    // Done: never again (even if an installer re-queues the welcome).
    CHECK(decideOnboarding(1, WelcomeAction::Show) == OnboardingAction::Nothing);
    CHECK(decideOnboarding(1, WelcomeAction::Nothing) == OnboardingAction::Nothing);
    // The real upgrade path: set up before, nothing pending -> MarkShown -> Upgrade.
    CHECK(decideOnboarding(-1, decideWelcome(true, false, false, true)) == OnboardingAction::Upgrade);
    // The real fresh path: AppStart on a never-set-up user -> Show -> pages.
    CHECK(decideOnboarding(-1, decideWelcome(true, false, false, false)) == OnboardingAction::ShowWelcome);
}

TEST(onboarding_start_english_snapshot_bit) {
    size_t n = 0;
    const BoolKey* keys = boolKeys(&n);
    CHECK(n <= 64);
    CHECK_EQ(std::string(keys[n - 1].name), std::string("autoCircumflex"));  // appended, never reordered
    CHECK_EQ(std::string(keys[n - 2].name), std::string("switchSound"));
    CHECK_EQ(std::string(keys[n - 3].name), std::string("startHidden"));
    CHECK_EQ(std::string(keys[n - 4].name), std::string("startEnglish"));
    CHECK_EQ(std::string(keys[n - 5].name), std::string("englishByFrequency"));
    Settings d;
    CHECK(!d.startEnglish);
    Settings s;
    s.startEnglish = true;
    std::vector<uint8_t> b = serialize(s);
    Settings r;
    CHECK(deserialize(b.data(), b.size(), r));
    CHECK(r.startEnglish);
    // A snapshot from a version before the bit existed (bool count one lower) reads as
    // "start in Vietnamese", whatever the stray high bit says.
    std::vector<uint8_t> ob = serialize(s);
    ob[6] = static_cast<uint8_t>(n - 4);  // u32 magic, u16 version, u16 bool count (LE)
    ob[7] = 0;
    Settings ro;
    CHECK(deserialize(ob.data(), ob.size(), ro) && !ro.startEnglish);
}

TEST(active_setup_matches_msi_template) {
    // The StubPath / GUID / version the MSI writes must be the ones the app knows.
    const std::string wxs = readFile(VTX_WXS_TEMPLATE);
    CHECK(!wxs.empty());
    const std::string key = std::string("Active Setup\\Installed Components\\") + kActiveSetupGuid;
    CHECK(wxs.find(key) != std::string::npos);
    CHECK(wxs.find(std::string("VietTelex.exe&quot; ") + kActiveSetupArgs) != std::string::npos);
    CHECK(wxs.find(std::string("Value=\"") + kActiveSetupVersion + "\"") != std::string::npos);
    CHECK(wxs.find("Name=\"IsInstalled\" Type=\"integer\" Value=\"1\"") != std::string::npos);
    // The StubPath runs per user at logon: --setup-user must stay a one-shot (main.cpp).
    SetupTrigger t;
    CHECK(parseSetupUserArgs({L"--setup-user", L"--active-setup"}, t) && t == SetupTrigger::ActiveSetup);
}

// ---------------------------------------------------------------- conflicts

TEST(conflict_processes) {
    ConflictKind k;
    CHECK(classifyImeProcess("unikeynt.exe", k) && k == ConflictKind::UniKey);
    CHECK(classifyImeProcess("evkey64.exe", k) && k == ConflictKind::EVKey);
    CHECK(classifyImeProcess("evkey.exe", k) && k == ConflictKind::EVKey);
    CHECK(classifyImeProcess("openkey64.exe", k) && k == ConflictKind::OpenKey);
    CHECK(classifyImeProcess("openkey.exe", k) && k == ConflictKind::OpenKey);
    CHECK(classifyImeProcess("vkey.exe", k) && k == ConflictKind::VKey);
    CHECK(classifyImeProcess("gotiengviet.exe", k) && k == ConflictKind::GoTiengViet);
    CHECK(!classifyImeProcess("viettelex.exe", k));
    CHECK(!classifyImeProcess("unikey-helper-notes.exe", k));
    CHECK(!classifyImeProcess("UniKeyNT.exe", k));  // callers lower-case first
    CHECK(isThirdPartyIme(ConflictKind::UniKey) && !isThirdPartyIme(ConflictKind::MicrosoftVietnamese));
    CHECK(std::string(conflictName(ConflictKind::EVKey)) == "EVKey");
    // Windows' own Ctrl+Shift is a conflict with a fix of its own, not an app to quit.
    CHECK(!isThirdPartyIme(ConflictKind::WindowsHotkey));
    CHECK(std::string(conflictName(ConflictKind::WindowsHotkey)) == "Windows Ctrl+Shift");
}

TEST(conflict_microsoft_profiles) {
    const std::string ours = reg::kClsid;
    ViProfile p;
    p.langId = 0x042A;
    p.isTip = true;
    p.enabled = true;
    p.clsid = ours;
    CHECK(!isOtherVietnameseProfile(p, ours));  // VietTelex itself
    p.clsid = "{11111111-2222-3333-4444-555555555555}";
    p.profile = "{AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE}";
    CHECK(isOtherVietnameseProfile(p, ours));  // e.g. Microsoft Vietnamese Telex
    CHECK_EQ(layoutOrTipSpec(p),
             std::string("042A:{11111111-2222-3333-4444-555555555555}{AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE}"));
    p.enabled = false;
    CHECK(!isOtherVietnameseProfile(p, ours));  // installed but not in the user's list
    p.enabled = true;
    p.langId = 0x0409;
    CHECK(!isOtherVietnameseProfile(p, ours));  // not Vietnamese
    // Legacy "Vietnamese" keyboard layout (types ă for 1).
    ViProfile l;
    l.langId = 0x042A;
    l.enabled = true;
    l.hkl = 0x042A042Aul;
    CHECK(isOtherVietnameseProfile(l, ours));
    CHECK_EQ(layoutOrTipSpec(l), std::string("042A:0000042A"));
    l.hkl = 0xF012042Aul;  // a variant layout: no simple KLID -> settings page instead
    CHECK(layoutOrTipSpec(l).empty());
    ViProfile bad = p;
    bad.langId = 0x042A;
    bad.clsid = "nope";
    CHECK(layoutOrTipSpec(bad).empty());
}

// ---------------------------------------------------------------- Chuyển từ UniKey

TEST(macro_unikey_windows_file) {
    MacroImport m;
    CHECK(parseMacroFile(fixture("unikey-windows.txt"), m));
    CHECK(m.format == MacroFormat::UniKey);
    CHECK(m.encoding == TextEncoding::Utf8Bom);
    CHECK(!m.viqr);
    CHECK_EQ(m.entries.size(), size_t(5));
    CHECK_EQ(m.entries["vn"], std::string("Việt Nam"));
    CHECK_EQ(m.entries["dc"], std::string("được"));  // CRLF stripped
    CHECK_EQ(m.entries["hcm"], std::string("Thành phố Hồ Chí Minh"));
    CHECK_EQ(m.entries["sig"], std::string("Trân trọng,  "));  // UniKey keeps text as is
    CHECK_EQ(m.skipped, size_t(1));                            // "a b": key with a space
}

TEST(macro_unikey_unix_file_and_colons_in_text) {
    MacroImport m;
    CHECK(parseMacroFile(fixture("unikey-unix.txt"), m));
    CHECK(m.format == MacroFormat::UniKey);
    CHECK(m.encoding == TextEncoding::Utf8);
    CHECK_EQ(m.entries["url"], std::string("https://viettelex.com"));  // split at the FIRST colon
    CHECK_EQ(m.entries["vn"], std::string("Việt Nam"));
}

TEST(macro_unikey_viqr_flagged) {
    MacroImport m;
    CHECK(parseMacroFile(fixture("unikey-viqr.txt"), m));
    CHECK(m.format == MacroFormat::UniKey);
    CHECK(m.viqr);  // the UI warns: not converted
    CHECK_EQ(m.entries["vn"], std::string("Vie^.t Nam"));
}

TEST(macro_openkey_file) {
    MacroImport m;
    CHECK(parseMacroFile(fixture("openkey.txt"), m));
    CHECK(m.format == MacroFormat::OpenKey);
    CHECK(!m.viqr);
    CHECK_EQ(m.entries.size(), size_t(3));
    CHECK_EQ(m.entries[":D"], std::string("cười"));  // OpenKey's leading-colon key rule
    CHECK_EQ(m.entries["hn"], std::string("Hà Nội"));
}

TEST(macro_generic_utf16) {
    MacroImport m;
    CHECK(parseMacroFile(fixture("generic-utf16le-bom.txt"), m));
    CHECK(m.format == MacroFormat::Generic);
    CHECK(m.encoding == TextEncoding::Utf16Le);
    CHECK_EQ(m.entries["vn"], std::string("Việt Nam"));
    CHECK_EQ(m.entries["ko"], std::string("không"));
    MacroImport n;
    CHECK(parseMacroFile(fixture("generic-utf16le-nobom.txt"), n));
    CHECK(n.encoding == TextEncoding::Utf16Le);
    CHECK_EQ(n.entries["ko"], std::string("không"));
    MacroImport b;
    CHECK(parseMacroFile(fixture("generic-utf16be-bom.txt"), b));
    CHECK(b.encoding == TextEncoding::Utf16Be);
    CHECK_EQ(b.entries["vn"], std::string("Việt Nam"));
}

TEST(macro_generic_tabs_and_refusals) {
    MacroImport m;
    CHECK(parseMacroFile(fixture("generic-tabs.txt"), m));
    CHECK_EQ(m.entries["vn"], std::string("Việt Nam"));
    CHECK_EQ(m.entries["ko"], std::string("không"));
    MacroImport bad;
    CHECK(!parseMacroFile(fixture("cp1258.txt"), bad));  // not UTF-8/16: refuse, no mojibake
    CHECK(!parseMacroFile("", bad));
    CHECK(!parseMacroFile(std::string(";DO NOT DELETE THIS LINE*** version=1 ***\r\n"), bad));  // header only
    std::string out;
    CHECK(!decodeTextFile(std::string("a\0b", 3), out));  // odd-length binary
}

// ---------------------------------------------------------------- games / fullscreen

TEST(fullscreen_only_exclusive_d3d_by_default) {
    ForegroundProbe p;
    p.quns = static_cast<int>(Quns::D3DFullScreen);
    p.coversMonitor = true;
    p.hasCaption = false;
    CHECK(fullscreenSuspends(true, p));
    CHECK(!fullscreenSuspends(false, p));  // setting off
    // Chrome F11 / YouTube fullscreen / video players report QUNS_BUSY: keep typing.
    p.quns = static_cast<int>(Quns::Busy);
    CHECK(!fullscreenSuspends(true, p));
    p.quns = static_cast<int>(Quns::AcceptsNotifications);
    CHECK(!fullscreenSuspends(true, p));  // a borderless window covering the monitor alone: no
    // Presentation mode: only for a captionless fullscreen foreground (slideshow).
    p.quns = static_cast<int>(Quns::PresentationMode);
    CHECK(fullscreenSuspends(true, p));
    p.hasCaption = true;
    CHECK(!fullscreenSuspends(true, p));
    p.hasCaption = false;
    p.coversMonitor = false;
    CHECK(!fullscreenSuspends(true, p));
    // Our own windows and the desktop never.
    p.quns = static_cast<int>(Quns::D3DFullScreen);
    p.ownProcess = true;
    CHECK(!fullscreenSuspends(true, p));
    p.ownProcess = false;
    p.shellOrDesktop = true;
    CHECK(!fullscreenSuspends(true, p));
}

TEST(fullscreen_covers_monitor) {
    const Rect mon{0, 0, 1920, 1080};
    CHECK(coversMonitor({0, 0, 1920, 1080}, mon));
    CHECK(coversMonitor({-8, -8, 1928, 1088}, mon));  // maximised-style overhang
    CHECK(!coversMonitor({0, 0, 1920, 1040}, mon));   // taskbar visible
    CHECK(!coversMonitor({0, 0, 1920, 1080}, Rect{}));
    const Rect second{1920, 0, 3840, 1080};
    CHECK(coversMonitor({1920, 0, 3840, 1080}, second));
    CHECK(!coversMonitor({0, 0, 1920, 1080}, second));
}

TEST(fullscreen_recheck_is_bounded) {
    ForegroundProbe p;
    p.coversMonitor = true;
    CHECK(fullscreenRecheckWanted(true, p, false));
    CHECK(!fullscreenRecheckWanted(false, p, false));  // setting off: zero cost
    CHECK(!fullscreenRecheckWanted(true, p, true));    // already suspended
    p.coversMonitor = false;
    CHECK(!fullscreenRecheckWanted(true, p, false));   // a normal window: no timers at all
    CHECK(kFullscreenRecheckCount >= 1 && kFullscreenRecheckCount <= 4);
    unsigned prev = 0;
    for (unsigned d : kFullscreenRecheckDelaysMs) {
        CHECK(d > prev);
        prev = d;
    }
    CHECK(prev <= 10000);
}

TEST(fullscreen_tracker_restores_on_leave) {
    FullscreenTracker t;
    FullscreenTracker::Step s = t.update(0x100, false);
    CHECK(s.resume == 0 && s.suspend == 0);
    s = t.update(0x100, true);  // the game went exclusive
    CHECK(s.resume == 0 && s.suspend == 0x100);
    s = t.update(0x100, true);  // re-check: no repeat message
    CHECK(s.resume == 0 && s.suspend == 0);
    s = t.update(0x200, false);  // Alt+Tab to the browser: give the game its keys back... to us
    CHECK(s.resume == 0x100 && s.suspend == 0);
    CHECK(t.suspended() == 0);
    s = t.update(0x100, true);  // back into the game
    CHECK(s.suspend == 0x100);
    s = t.update(0x300, true);  // straight into another fullscreen game
    CHECK(s.resume == 0x100 && s.suspend == 0x300);
    s = t.clear();  // setting turned off / quitting
    CHECK(s.resume == 0x300 && t.suspended() == 0);
    s = t.clear();
    CHECK(s.resume == 0);
}

TEST(game_mode_hotkey_choices) {
    CHECK_EQ(gameModeHotkeyIndex("off"), size_t(0));
    CHECK_EQ(gameModeHotkeyIndex("bogus"), size_t(0));
    unsigned mods = 0, vk = 0;
    CHECK(!gameModeHotkeyKeys("off", mods, vk));  // default: nothing registered
    CHECK(gameModeHotkeyKeys("ctrl-alt-g", mods, vk));
    CHECK(mods == (0x2u | 0x1u) && vk == 'G');
    for (const GameHotkeyChoice& c : kGameModeHotkeys) {
        if (!c.vk) continue;
        CHECK(!(c.mods & 0x8u));                 // no Win+…: Xbox Game Bar owns Win+G / Win+Alt+G
        CHECK(c.mods != (0x2u | 0x4u));          // never plain Ctrl+Shift+<key> family clash with the chord
        CHECK(c.vk != 'T');                      // Thêm dấu hotkey choices use T
        CHECK(c.mods & 0x1u);                    // always with Alt: not a shortcut apps commonly use
    }
}

TEST(switch_indicator_defaults) {
    CHECK(parseSwitchIndicator("auto") == SwitchIndicator::Auto);
    CHECK(parseSwitchIndicator("") == SwitchIndicator::Auto);
    CHECK(parseSwitchIndicator("on") == SwitchIndicator::On);
    CHECK(parseSwitchIndicator("off") == SwitchIndicator::Off);
    CHECK(std::string(switchIndicatorName(SwitchIndicator::Auto)) == "auto");
    const int normal = static_cast<int>(Quns::AcceptsNotifications);
    // auto: on while the tray icon is hidden (the default), off when the tray shows the state
    CHECK(showSwitchToast(SwitchIndicator::Auto, false, false, normal));
    CHECK(!showSwitchToast(SwitchIndicator::Auto, true, false, normal));
    CHECK(showSwitchToast(SwitchIndicator::On, true, false, normal));
    CHECK(!showSwitchToast(SwitchIndicator::Off, false, false, normal));
    // never over a game / slideshow, never while keys pass through
    CHECK(!showSwitchToast(SwitchIndicator::On, false, false, static_cast<int>(Quns::D3DFullScreen)));
    CHECK(!showSwitchToast(SwitchIndicator::On, false, false, static_cast<int>(Quns::PresentationMode)));
    CHECK(!showSwitchToast(SwitchIndicator::On, false, true, normal));
    // a fullscreen browser/video (QUNS_BUSY) is fine
    CHECK(showSwitchToast(SwitchIndicator::On, false, false, static_cast<int>(Quns::Busy)));
}

TEST(switch_toast_position) {
    const Rect wa{0, 0, 1920, 1040};
    Point p = toastPosition(true, Rect{100, 200, 102, 220}, wa, 48, 40, 8);
    CHECK(p.x == 100 && p.y == 228);  // below the caret
    p = toastPosition(true, Rect{100, 1020, 102, 1038}, wa, 48, 40, 8);
    CHECK(p.y == 1020 - 8 - 40);  // no room below: above
    p = toastPosition(true, Rect{1915, 200, 1917, 220}, wa, 48, 40, 8);
    CHECK(p.x == 1920 - 8 - 48);  // kept inside the work area
    p = toastPosition(false, Rect{}, wa, 48, 40, 8);
    CHECK(p.x == 1920 - 8 - 48 && p.y == 1040 - 8 - 40);  // corner
    const Rect second{1920, 0, 3840, 1040};
    p = toastPosition(false, Rect{}, second, 48, 40, 8);
    CHECK(p.x == 3840 - 8 - 48);
}

// ---------------------------------------------------------------- terminals / AI CLIs

TEST(direct_backspace_is_a_virtual_key_never_unicode_bs) {
    // Claude Code / Gemini CLI in Windows Terminal expect DEL (0x7F) for Backspace; the
    // terminal produces it from a VK_BACK key event. A Unicode 0x08 would arrive as BS.
    const std::vector<DirectKeyEvent> ev = directEditEvents(2, u"ệ");
    CHECK_EQ(ev.size(), size_t(6));
    for (size_t i = 0; i < 4; ++i) {
        CHECK(ev[i].vk == kVkBack);
        CHECK(!ev[i].unicode);
        CHECK(ev[i].up == (i % 2 == 1));  // down, up, down, up
    }
    CHECK(ev[4].unicode && ev[4].unit == u'ệ' && !ev[4].up);
    CHECK(ev[5].unicode && ev[5].up);
    // No Unicode event ever carries a control character.
    const std::vector<DirectKeyEvent> all = directEditEvents(3, u"tiếng");
    for (const DirectKeyEvent& e : all) {
        if (e.unicode) CHECK(e.unit >= 0x20);
        else CHECK(e.vk == kVkBack);
    }
    CHECK(directEditEvents(0, u"").empty());
}

// A key the hook swallowed and replays after its edits keeps its scan code and extended
// bit: an arrow (VK_LEFT 0x25, scan 0x4B, LLKHF_EXTENDED) must not arrive as numpad 4.
TEST(direct_replay_key_keeps_extended_flag_and_scan) {
    const auto arrow = replayKeyInjection(0x25, 0x4B, kLlkhfExtended, 0x4B);
    CHECK_EQ(arrow[0].vk, uint16_t{0x25});
    CHECK_EQ(arrow[0].scan, uint16_t{0x4B});
    CHECK_EQ(arrow[0].flags, kKeyeventfExtendedKey);
    CHECK_EQ(arrow[1].flags, kKeyeventfExtendedKey | kKeyeventfKeyUp);
    CHECK_EQ(arrow[1].scan, uint16_t{0x4B});
    // Numpad Enter: VK_RETURN + extended; main Enter: no extended bit.
    CHECK_EQ(uint32_t{replayKeyInjection(0x0D, 0x1C, kLlkhfExtended, 0x1C)[0].flags}, kKeyeventfExtendedKey);
    CHECK_EQ(uint32_t{replayKeyInjection(0x0D, 0x1C, 0, 0x1C)[0].flags}, uint32_t{0});
    // Other LLKHF bits (injected 0x10, alt 0x20, up 0x80) never leak into KEYEVENTF.
    CHECK_EQ(uint32_t{replayKeyInjection(0x0D, 0x1C, 0x10 | 0x20, 0x1C)[0].flags}, uint32_t{0});
    // The hook's own scan code wins over the mapped one; the mapped one only fills a 0.
    CHECK_EQ(uint16_t{replayKeyInjection(0x2E, 0x53, kLlkhfExtended, 0x99)[0].scan}, uint16_t{0x53});
    CHECK_EQ(uint16_t{replayKeyInjection(0x2E, 0, kLlkhfExtended, 0x53)[1].scan}, uint16_t{0x53});
}

// ---------------------------------------------------------------- Java AWT (JetBrains)

namespace {
bool isTextEvent(const DirectKeyEvent& e) { return e.unicode; }
std::vector<DirectKeyEvent> textEvents(const std::u16string& s) { return directEditEvents(0, s); }
std::vector<DirectKeyEvent> keyEvents(uint16_t vk) {
    return {DirectKeyEvent{vk, 0, false, false}, DirectKeyEvent{vk, 0, false, true}};
}
std::vector<DirectKeyEvent> cat(std::vector<DirectKeyEvent> a, const std::vector<DirectKeyEvent>& b) {
    a.insert(a.end(), b.begin(), b.end());
    return a;
}
bool sameEvents(const std::vector<DirectKeyEvent>& a, const std::vector<DirectKeyEvent>& b) {
    if (a.size() != b.size()) return false;
    for (size_t i = 0; i < a.size(); ++i)
        if (a[i].vk != b[i].vk || a[i].unit != b[i].unit || a[i].unicode != b[i].unicode || a[i].up != b[i].up)
            return false;
    return true;
}
}  // namespace

TEST(split_correction_hosts_are_awt_window_classes) {
    // Every JetBrains IDE (and any Swing app): AWT top-level windows.
    CHECK(splitsCorrection("SunAwtFrame"));
    CHECK(splitsCorrection("SunAwtDialog"));
    CHECK(splitsCorrection("SunAwtWindow"));
    CHECK(splitsCorrection("SunAwtCanvas"));
    // Not AWT: no pause anywhere else (consoles, Chromium, WPF, Qt).
    CHECK(!splitsCorrection("ConsoleWindowClass"));
    CHECK(!splitsCorrection("CASCADIA_HOSTING_WINDOW_CLASS"));
    CHECK(!splitsCorrection("Chrome_WidgetWin_1"));
    CHECK(!splitsCorrection("HwndWrapper[OneCommander;;1]"));
    CHECK(!splitsCorrection("Qt5152QWindowIcon"));
    CHECK(!splitsCorrection("SunAw"));
    CHECK(!splitsCorrection(""));
    CHECK(kSplitCorrectionDelayMs >= 20 && kSplitCorrectionDelayMs <= 100);
}

TEST(split_correction_backspaces_now_text_after_pause) {
    SplitInjection<DirectKeyEvent> q(&isTextEvent);
    // "viet" + j -> ⌫⌫ "ệt": the Backspaces go now, the text after one pause.
    const std::vector<DirectKeyEvent> now = q.submit(directEditEvents(2, u"ệt"));
    CHECK(sameEvents(now, directEditEvents(2, u"")));
    CHECK(q.busy());
    CHECK_EQ(q.pendingChunks(), size_t(1));
    CHECK(sameEvents(q.next(), textEvents(u"ệt")));
    CHECK(!q.busy());
    CHECK(q.next().empty());
    // Text with no key before it (a plain retyped word, no Backspace): all at once.
    CHECK(sameEvents(q.submit(textEvents(u"đ")), textEvents(u"đ")));
    CHECK(!q.busy());
    // Text, then a replayed key (Enter after an auto-restored word): no pause needed.
    const auto restore = cat(textEvents(u"a"), keyEvents(0x0D));
    CHECK(sameEvents(q.submit(restore), restore));
    CHECK(!q.busy());
}

TEST(split_correction_keys_during_pause_come_after_the_text) {
    SplitInjection<DirectKeyEvent> q(&isTextEvent);
    CHECK(sameEvents(q.submit(directEditEvents(1, u"ệ")), directEditEvents(1, u"")));
    // Typed during the pause: "n" (a key the hook would let through, replayed as text),
    // then ⌫ (replayed as a key). Nothing goes now.
    CHECK(q.submit(textEvents(u"n")).empty());
    CHECK(q.submit(keyEvents(kVkBack)).empty());
    // A correction during the pause: "ê" again after one ⌫ -> waits behind it all, with a
    // pause after its Backspace.
    CHECK(q.submit(directEditEvents(1, u"ê")).empty());
    // A letter after it: still behind.
    CHECK(q.submit(textEvents(u"m")).empty());
    CHECK_EQ(q.pendingChunks(), size_t(2));
    // Tick 1: the pending text, then the keys typed meanwhile up to the next text-after-key.
    CHECK(sameEvents(q.next(), cat(cat(textEvents(u"ện"), keyEvents(kVkBack)), keyEvents(kVkBack))));
    // Tick 2: "ê" + "m" (text after the ⌫ + correction ⌫ waited one pause).
    CHECK(sameEvents(q.next(), textEvents(u"êm")));
    CHECK(!q.busy());
}

TEST(split_correction_preserves_total_order) {
    // Whatever the batches, the events come out in submission order, each exactly once.
    SplitInjection<DirectKeyEvent> q(&isTextEvent);
    const std::vector<std::vector<DirectKeyEvent>> batches = {
        directEditEvents(3, u"tiế"), textEvents(u"n"), keyEvents(0x25), directEditEvents(2, u"ng"),
        keyEvents(0x0D), textEvents(u"a"), directEditEvents(1, u"ă"), textEvents(u" "),
    };
    std::vector<DirectKeyEvent> want, got;
    for (size_t i = 0; i < batches.size(); ++i) {
        want = cat(want, batches[i]);
        got = cat(got, q.submit(batches[i]));
        if (i == 4) got = cat(got, q.next());  // one tick in the middle
    }
    // No chunk that waits starts with a key: each pause is before text.
    while (q.busy()) {
        const std::vector<DirectKeyEvent> c = q.next();
        CHECK(!c.empty() && c.front().unicode);
        got = cat(got, c);
    }
    CHECK(sameEvents(got, want));
}

TEST(split_correction_drain_sends_everything_in_order) {
    SplitInjection<DirectKeyEvent> q(&isTextEvent);
    q.submit(directEditEvents(2, u"ữ"));
    q.submit(textEvents(u"a"));
    q.submit(directEditEvents(1, u"â"));
    CHECK(sameEvents(q.drain(), cat(cat(textEvents(u"ữa"), directEditEvents(1, u"")), textEvents(u"â"))));
    CHECK(!q.busy());
    q.submit(directEditEvents(1, u"ô"));
    q.clear();
    CHECK(!q.busy());
    CHECK(q.next().empty());
}

TEST(split_correction_which_keys_may_pass_pending_text) {
    CHECK(keyPassesPendingSplit(0x10));   // Shift
    CHECK(keyPassesPendingSplit(0xA0));   // LShift
    CHECK(keyPassesPendingSplit(0xA1));   // RShift
    CHECK(keyPassesPendingSplit(0x14));   // Caps Lock
    CHECK(!keyPassesPendingSplit(0x11));  // Ctrl: Ctrl+Backspace / Ctrl+Z before the text
    CHECK(!keyPassesPendingSplit(0xA2));
    CHECK(!keyPassesPendingSplit(0x12));  // Alt
    CHECK(!keyPassesPendingSplit(0x5B));  // Win
    CHECK(!keyPassesPendingSplit(0x74));  // F5
}

// The echo check must give up on a hung app in seconds, not UIA's 20 s default.
TEST(direct_uia_timeouts_are_short) {
    CHECK(kUiaConnectionTimeoutMs > 0 && kUiaConnectionTimeoutMs <= 2000);
    CHECK(kUiaTransactionTimeoutMs >= kUiaConnectionTimeoutMs && kUiaTransactionTimeoutMs <= 3000);
}

TEST(direct_injection_modifier_guard) {
    // Ctrl+Backspace = BS 0x08 in terminals / delete-word in GUI apps; Alt+Backspace =
    // ESC DEL (readline: delete word). Never inject while those are held.
    CHECK(injectionModifiersSafe(false, false, false));
    CHECK(!injectionModifiersSafe(true, false, false));
    CHECK(!injectionModifiersSafe(false, true, false));
    CHECK(!injectionModifiersSafe(false, false, true));
}

TEST(terminal_policy_user_can_choose_composition) {
    // Built-in: terminals are Direct (no underline). For a CLI that mis-parses a batch of
    // DEL + text arriving in one read, the user picks composition for the terminal on the
    // Ứng dụng page — the override must win over the built-in rule.
    CHECK(resolveAppMode("windowsterminal.exe", {}) == AppMode::Direct);
    CHECK(resolveAppMode("conhost.exe", {}) == AppMode::Direct);
    std::map<std::string, AppMode> o{{"windowsterminal.exe", AppMode::Composition}};
    CHECK(resolveAppMode("windowsterminal.exe", o) == AppMode::Composition);
    CHECK(!hookTypes(resolveAppMode("windowsterminal.exe", o)));  // the hook stays out: only committed text
}
