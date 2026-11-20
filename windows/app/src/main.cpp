// main.cpp — VietTelex.exe: tray icon, settings window, updater, hook fallback, and
// the per-user setup/cleanup the MSI delegates to it. Typing itself lives in the TIP.
//
// App feel (docs/WINDOWS-APP-FEEL-SPEC.md, core/app_feel.h): every start makes sure the
// VietTelex keyboard is in the user's list (added + default + selected when missing / on
// the first run); the tray V/E icon is on for new users, a left click toggles Việt/Anh,
// it shows "off" while another keyboard is selected; tray "Thoát" switches the session
// back to the keyboard used before (or English) — "tắt app là tắt bộ gõ".
//
// Portable build (core/portable.h): a marker file next to the exe. No TIP, no HKLM, no
// keyboard list changes; the hook types in every app; settings.ini next to the exe.
//
// Command line:
//   (none)          open Settings (starting the tray app if needed)
//   --background    no window (autostart; tray icon only if enabled)
//   --settings      open Settings (after an interactive install)
//   --command <n>   run an AppCommand (open Settings / About, check for updates, Telex/VNI)
//   --setup-user    add the keyboard for this user + autostart, then exit (installer);
//                   with --active-setup: Windows' Active Setup at a user's logon (onboarding.h)
//   --cleanup-user  remove keyboard, autostart and all user data, then exit (uninstall)
//   --set-profile-icon <choice>  (elevated) set the keyboard profile icon, then exit
#include <windows.h>
#include <commctrl.h>
#include <mmsystem.h>
#include <shellapi.h>
#include <shlobj.h>

#include <string>
#include <vector>

#include "app.h"
#include "app_feel.h"
#include "app_quit.h"
#include "debug_context.h"
#include "portable.h"
#include "text_action_logic.h"
#include "setup_helper_logic.h"
#include "icons.h"
#include "registration.h"
#include "res/icon_ids.h"
#include "foreground.h"
#include "game_logic.h"
#include "game_mode.h"
#include "input_switch.h"
#include "onboarding.h"
#include "switch_sound.h"
#include "switch_toast.h"
#include "hook_fallback.h"
#include "idle_trim.h"
#include "ipc.h"
#include "settings_store.h"
#include "strings.h"
#include "text_actions.h"
#include "tip_control.h"
#include "updater.h"
#include "uninstall.h"
#include "version.h"

namespace vtx::app {

HINSTANCE g_inst = nullptr;
HWND g_mainWnd = nullptr;
Settings g_settings;

namespace {
constexpr UINT_PTR kTimerIdleTrim = 0x5601;  // core/idle_trim.h
int g_trimRetries = 0;
}  // namespace

void requestIdleTrim() {
    g_trimRetries = 0;
    if (g_mainWnd) SetTimer(g_mainWnd, kTimerIdleTrim, vtx::idletrim::kDelayMs, nullptr);
}

namespace {

// Keep in sync with ime/src/globals.h (kAppWindowClass, kAppCommandMsg).
constexpr wchar_t kAppWindowClass[] = L"VietTelexAppWindow";
constexpr UINT kAppCommandMsg = WM_APP + 0x56;
constexpr UINT kTrayMsg = WM_APP + 0x57;
// Setting switchSound: a rising tone for Việt, a falling one for Anh, for a switch the USER
// made (hotkey, tray click) — never for a per-app change on focus. Async, from memory.
static void playSwitchSound(bool vietnamese) {
    if (!vtx::playsSwitchSound(g_settings.switchSound, gameSuspendedNow())) return;
    static const std::vector<uint8_t> vi = vtx::switchSoundWav(true), en = vtx::switchSoundWav(false);
    PlaySoundW(reinterpret_cast<LPCWSTR>((vietnamese ? vi : en).data()), nullptr,
               SND_MEMORY | SND_ASYNC | SND_NODEFAULT);
}

static_assert(kAppCommandMsg == kAppCommand && kTrayMsg == kTrayCallback, "app_messages.h is the list");
constexpr UINT kTrayId = 1;
UINT g_taskbarCreated = 0;

// ---- idle working-set trim (core/idle_trim.h) -----------------------------------------
void onIdleTrimTimer(HWND h) {
    KillTimer(h, kTimerIdleTrim);
    vtx::idletrim::State s;
    s.windowOpen = settingsWindowOpen() || welcomeWindowOpen();
    s.textJobBusy = textActionsBusy();
    LASTINPUTINFO li = {sizeof li, 0};
    s.idleMs = GetLastInputInfo(&li) ? GetTickCount() - li.dwTime : vtx::idletrim::kQuietMs;
    s.retries = g_trimRetries;
    switch (vtx::idletrim::decide(s)) {
        case vtx::idletrim::Decision::Trim:
            g_trimRetries = 0;
            SetProcessWorkingSetSize(GetCurrentProcess(), static_cast<SIZE_T>(-1), static_cast<SIZE_T>(-1));
            break;
        case vtx::idletrim::Decision::Wait:
            ++g_trimRetries;
            SetTimer(h, kTimerIdleTrim, vtx::idletrim::kRetryMs, nullptr);
            break;
        case vtx::idletrim::Decision::Drop: g_trimRetries = 0; break;
    }
}

enum TrayCmd : UINT {
    kTraySettings = 1,
    kTrayUpdate,
    kTrayAbout,
    kTrayHideTray,  // "Ẩn biểu tượng khay" (the app keeps running)
    kTrayGameMode,
    kTrayExit,       // "Thoát VietTelex": back to the previous keyboard, then quit
    kTrayAutostart,  // portable only: "Khởi động cùng Windows" (HKCU Run -> this copy)
    kTrayToolBase = 100 /* +6 text tools */
};

const wchar_t* appWindowClass() { return portableMode() ? vtx::portable::kWindowClass : kAppWindowClass; }

// Tray glyph = the keyboard icon chosen in settings, for the current taskbar theme.
// Việt/Anh state of the app in the foreground — the tray icon is the only state indicator
// (1.0.8: the taskbar shows just the keyboard-profile icon). Fed by the TIP
// (AppCommand::StateChanged) and by foreground changes (fgWinEvent). Off = another
// keyboard is selected there (installed) / portable yields there (app_feel.h).
vtx::TrayState g_trayState = vtx::TrayState::Vietnamese;
bool g_stateVietnamese = true;  // == (g_trayState == Vietnamese)
HWND g_lastAppWnd = nullptr;    // last foreground window that was not a shell surface
HWINEVENTHOOK g_fgHook = nullptr;
void CALLBACK fgWinEvent(HWINEVENTHOOK, DWORD, HWND, LONG, LONG, DWORD, DWORD);

// Default style: the V/E badge (icon_ids.h trayBadge); "keyboard" = the chosen glyph.
// Off: the V glyph, faded.
HICON trayIcon() {
    const bool off = g_trayState == vtx::TrayState::Off;
    const bool vi = off || g_stateVietnamese;
    HICON base = parseTrayStyle(g_settings.trayIconStyle) == TrayStyle::Letter
                     ? tip::CreateBadgeIcon(vi)
                     : tip::CreateStateIcon(g_inst, g_settings.menuIcon, vi);
    if (!off || !base) return base;
    HICON dim = tip::CreateDimmedIcon(base, GetSystemMetrics(SM_CXSMICON), 0.35f);
    DestroyIcon(base);
    return dim;
}

bool g_trayShown = false;
bool g_trayV4 = false;  // NIM_SETVERSION 4 accepted: clicks arrive as NIN_SELECT

// Tooltip: "VietTelex — bộ gõ tiếng Việt: Tiếng Việt (V)" — the state in words too.
void setTrayTip(NOTIFYICONDATAW& nid) {
    const S state = g_trayState == vtx::TrayState::Off
                        ? (portableMode() ? S::TrayStatePortableOff : S::TrayStateOff)
                        : (g_stateVietnamese ? S::TrayStateVi : S::TrayStateEn);
    const std::wstring tip = std::wstring(tr(portableMode() ? S::TrayTipPortable : S::TrayTip)) + L": " + tr(state);
    lstrcpynW(nid.szTip, tip.c_str(), ARRAYSIZE(nid.szTip));
}

void addTrayIcon() {
    NOTIFYICONDATAW nid = {};
    nid.cbSize = sizeof nid;
    nid.hWnd = g_mainWnd;
    nid.uID = kTrayId;
    nid.uFlags = NIF_ICON | NIF_TIP | NIF_MESSAGE | NIF_SHOWTIP;
    nid.uCallbackMessage = kTrayMsg;
    nid.hIcon = trayIcon();
    setTrayTip(nid);
    g_trayShown = Shell_NotifyIconW(NIM_ADD, &nid) != FALSE;
    nid.uVersion = NOTIFYICON_VERSION_4;
    g_trayV4 = Shell_NotifyIconW(NIM_SETVERSION, &nid) != FALSE;
    if (nid.hIcon) DestroyIcon(nid.hIcon);
}

void removeTrayIcon() {
    NOTIFYICONDATAW nid = {};
    nid.cbSize = sizeof nid;
    nid.hWnd = g_mainWnd;
    nid.uID = kTrayId;
    Shell_NotifyIconW(NIM_DELETE, &nid);
    g_trayShown = false;
}

// The tray icon (settings showTrayIcon): ON for new users (app_feel.h applyNewUserDefaults),
// existing users keep their saved choice. It is the only lasting Việt/Anh indicator — the
// taskbar shows the static keyboard icon. Start menu -> VietTelex opens Settings.
void syncTrayIcon() {
    if (!g_mainWnd) return;
    if (!g_settings.showTrayIcon) {
        if (g_trayShown) removeTrayIcon();
        if (g_fgHook) {
            UnhookWinEvent(g_fgHook);
            g_fgHook = nullptr;
        }
        return;
    }
    if (!g_fgHook)
        g_fgHook = SetWinEventHook(EVENT_SYSTEM_FOREGROUND, EVENT_SYSTEM_FOREGROUND, nullptr, fgWinEvent, 0, 0,
                                   WINEVENT_OUTOFCONTEXT | WINEVENT_SKIPOWNPROCESS);
    if (!g_trayShown) {
        addTrayIcon();
        return;
    }
    NOTIFYICONDATAW nid = {};
    nid.cbSize = sizeof nid;
    nid.hWnd = g_mainWnd;
    nid.uID = kTrayId;
    nid.uFlags = NIF_ICON | NIF_TIP | NIF_SHOWTIP;
    nid.hIcon = trayIcon();
    setTrayTip(nid);
    Shell_NotifyIconW(NIM_MODIFY, &nid);
    if (nid.hIcon) DestroyIcon(nid.hIcon);
}

void quitFromTray();

void showTrayMenu() {
    HMENU m = CreatePopupMenu();
    // Công cụ văn bản first (settings textToolsInMenu): the menu's most frequent action.
    if (g_settings.textToolsInMenu) {
        appendTextToolsMenu(m, kTrayToolBase);
        AppendMenuW(m, MF_SEPARATOR, 0, nullptr);
    }
    AppendMenuW(m, MF_STRING | (g_settings.gameMode ? MF_CHECKED : MF_UNCHECKED), kTrayGameMode, tr(S::MenuGameMode));
    AppendMenuW(m, MF_SEPARATOR, 0, nullptr);
    AppendMenuW(m, MF_STRING, kTraySettings, tr(S::MenuSettings));
    AppendMenuW(m, MF_STRING, kTrayUpdate, tr(S::MenuCheckUpdate));
    AppendMenuW(m, MF_STRING, kTrayAbout, tr(S::MenuAbout));
    if (portableMode()) {
        const bool here = vtx::portable::autostartPointsHere(autostartValue(), selfExePath());
        AppendMenuW(m, MF_STRING | (here ? MF_CHECKED : MF_UNCHECKED), kTrayAutostart, tr(S::MenuAutostart));
    }
    AppendMenuW(m, MF_SEPARATOR, 0, nullptr);
    AppendMenuW(m, MF_STRING, kTrayHideTray, tr(S::MenuHideTray));
    AppendMenuW(m, MF_STRING, kTrayExit, tr(S::MenuExit));
    POINT pt;
    GetCursorPos(&pt);
    SetForegroundWindow(g_mainWnd);
    UINT cmd = TrackPopupMenu(m, TPM_RETURNCMD | TPM_RIGHTBUTTON | TPM_NONOTIFY, pt.x, pt.y, 0, g_mainWnd, nullptr);
    // TrackPopupMenu docs (KB135788): after a notification-icon menu, post a benign message
    // to the owner — together with SetForegroundWindow above, this is what makes a click
    // outside the menu close it instead of leaving it open until the next click.
    PostMessageW(g_mainWnd, WM_NULL, 0, 0);
    DestroyMenu(m);
    switch (cmd) {
        case kTraySettings: showSettings(Tab::Typing); break;
        case kTrayUpdate: startUpdateCheck(g_mainWnd, true); break;
        case kTrayAbout: showSettings(Tab::About); break;
        case kTrayGameMode: toggleGameMode(); break;
        case kTrayHideTray:  // "Ẩn biểu tượng khay": the app keeps running, just without the icon
            g_settings.showTrayIcon = false;
            settingsChanged();
            refreshSettingsWindow();
            break;
        case kTrayAutostart: {  // portable: point HKCU Run at this copy, or remove it
            const bool here = vtx::portable::autostartPointsHere(autostartValue(), selfExePath());
            setAutostart(!here);
            appLog("app", std::string("portable autostart ") + (here ? "off" : "on"));
            break;
        }
        case kTrayExit: quitFromTray(); break;
        default: runTextToolMenuCommand(cmd, kTrayToolBase); break;  // (DestroyMenu freed the submenu too)
    }
}

// Non-modal notice (notification-area balloon) that hook mode cannot type into an
// elevated app — shown once per app; uses a temporary icon when the tray icon is off.
void showElevationNotice(const std::wstring& exe) {
    NOTIFYICONDATAW nid = {};
    nid.cbSize = sizeof nid;
    nid.hWnd = g_mainWnd;
    nid.uID = g_trayShown ? kTrayId : kTrayId + 1;
    nid.uFlags = NIF_INFO | NIF_ICON | NIF_TIP;
    nid.hIcon = trayIcon();
    lstrcpynW(nid.szTip, tr(S::TrayTip), ARRAYSIZE(nid.szTip));
    lstrcpynW(nid.szInfoTitle, tr(S::AppName), ARRAYSIZE(nid.szInfoTitle));
    std::wstring msg = std::wstring(tr(S::ElevatedHookNotice)) + L" (" + exe + L")";
    lstrcpynW(nid.szInfo, msg.c_str(), ARRAYSIZE(nid.szInfo));
    nid.dwInfoFlags = NIIF_WARNING;
    Shell_NotifyIconW(g_trayShown ? NIM_MODIFY : NIM_ADD, &nid);
    if (nid.hIcon) DestroyIcon(nid.hIcon);
    if (!g_trayShown) SetTimer(g_mainWnd, 77, 15000, nullptr);  // drop the temporary icon
}

void setTrayStateEx(vtx::TrayState s) {
    if (s == g_trayState) return;
    g_trayState = s;
    g_stateVietnamese = s == vtx::TrayState::Vietnamese;
    syncTrayIcon();
}

void setTrayState(bool vietnamese) {
    setTrayStateEx(vietnamese ? vtx::TrayState::Vietnamese : vtx::TrayState::English);
}

bool isShellSurface(HWND hwnd) {
    char cls[64] = {};
    GetClassNameA(hwnd, cls, sizeof cls);
    return vtx::isShellSurfaceClass(cls);
}

// The tray state of a window (app_feel.h trayStateFor).
vtx::TrayState trayStateOf(HWND hwnd) {
    const FgApp app = describeWindow(hwnd);
    const vtx::AppMode mode = vtx::resolveAppMode(narrow(app.identity), g_settings.appModes);
    return vtx::trayStateFor(portableMode(), fgTipProp(hwnd), app.console, fgLangId(app),
                             storedVietnamese(app.identity), mode == vtx::AppMode::Off);
}

// Foreground app changed: its Việt/Anh state. The TIP's kTipLangProp on the window when
// present (the only truth for consoles, whose reported thread is cmd's), else whether the
// VietTelex keyboard is selected on that thread plus the remembered per-app state
// (foreground.h). Shell surfaces (the taskbar itself, when the tray icon is clicked) keep
// the state of the app the user came from.
void CALLBACK fgWinEvent(HWINEVENTHOOK, DWORD, HWND hwnd, LONG idObject, LONG, DWORD, DWORD) {
    if (idObject != OBJID_WINDOW || !hwnd) return;
    textActionsNoteForeground(hwnd);  // tray text tools act on the app the user came from
    if (isShellSurface(hwnd)) return;
    g_lastAppWnd = hwnd;
    const vtx::TrayState s = trayStateOf(hwnd);
    // Logged on change only: the hook's "foreground" line already names every switch.
    static int loggedState = -1;  // UI thread only
    if (appLogging() && static_cast<int>(s) != loggedState) {
        loggedState = static_cast<int>(s);
        appLog("app", std::string("tray state: ") +
                          (s == vtx::TrayState::Off ? "off" : s == vtx::TrayState::Vietnamese ? "vi" : "en"));
    }
    setTrayStateEx(s);
}

// The keyboard in use before VietTelex is selected (Thoát goes back to it).
void rememberPreviousKeyboard() {
    const uintptr_t hkl = g_lastAppWnd ? static_cast<uintptr_t>(reinterpret_cast<ULONG_PTR>(GetKeyboardLayout(
                                             GetWindowThreadProcessId(g_lastAppWnd, nullptr))))
                                       : defaultInputHkl();
    if (vtx::rememberableLayout(hkl)) writeQword(L"previousKeyboard", hkl);
}

// Installed: make VietTelex the input method of the session and of `wnd`'s thread (the
// window the user came from), in Việt for that app. Not run on real Windows yet.
void selectVietTelexNow(HWND wnd) {
    bool registered = false;
    if (!vietTelexInUserList(registered) && registered) addKeyboardForUser();
    rememberPreviousKeyboard();
    const bool session = selectVietTelexForSession();
    bool posted = false;
    if (wnd) {
        const FgApp app = describeWindow(wnd);
        storeVietnamese(app.identity, true);
        mirrorAppLanguage();
        const std::vector<uintptr_t> hkls = keyboardLayouts();
        const uintptr_t vi = vtx::pickVietnameseHkl(hkls.data(), hkls.size());
        posted = requestInputLanguage(wnd, vi);
    }
    appLog("app", std::string("select VietTelex: session ") + (session ? "ok" : "failed") + ", window " +
                      (posted ? "asked" : "not asked"));
}

// Left click on the tray icon (app_feel.h trayClickAction). The click made the taskbar
// the foreground: act on the app the user came from, then give it the focus back (the
// TIP re-reads the per-app Việt/Anh memory on that focus change).
void trayLeftClick() {
    HWND wnd = g_lastAppWnd && IsWindow(g_lastAppWnd) ? g_lastAppWnd : nullptr;
    const vtx::TrayState state = wnd ? trayStateOf(wnd) : g_trayState;
    switch (vtx::trayClickAction(state, portableMode())) {
        case vtx::TrayClick::ToggleLanguage: {
            if (!wnd) {
                showSettings(Tab::Typing);  // no app to switch: open Settings as before
                return;
            }
            const FgApp app = describeWindow(wnd);
            const bool on = state != vtx::TrayState::Vietnamese;
            storeVietnamese(app.identity, on);
            mirrorAppLanguage();
            setTrayState(on);
            appLog("app", std::string("tray click: ") + (on ? "vi" : "en"));
            break;
        }
        case vtx::TrayClick::SelectVietTelex:
            selectVietTelexNow(wnd);
            setTrayState(true);
            break;
        case vtx::TrayClick::SwitchToEnglishKeys: {
            // Portable, yielding: give that window a non-Vietnamese layout so the hook types.
            const std::vector<uintptr_t> hkls = keyboardLayouts();
            const uintptr_t en = vtx::pickExitLayout(hkls.data(), hkls.size(), 0);
            if (vtx::portable::yieldClick(en) == vtx::portable::YieldClick::ExplainNoOtherKeyboard) {
                // Only Vietnamese keyboards in the list: say what to do (was a silent no-op).
                appLog("app", "portable tray click: only Vietnamese keyboards in the list");
                MessageBoxW(nullptr, tr(S::PortableNoOtherKeyboard), tr(S::AppName), MB_OK | MB_ICONINFORMATION);
                break;
            }
            const bool ok = requestInputLanguage(wnd, en);
            appLog("app", std::string("portable tray click: English layout ") + (ok ? "requested" : "unavailable"));
            if (ok) setTrayState(storedVietnamese(describeWindow(wnd).identity));
            break;
        }
    }
    if (wnd) SetForegroundWindow(wnd);
    if (showSwitchToast(parseSwitchIndicator(g_settings.switchIndicator), g_trayShown, gameSuspendedNow(),
                        currentNotificationState()) &&
        g_trayState != vtx::TrayState::Off)
        toastShow(g_stateVietnamese ? L"V" : L"E");
    if (g_trayState != vtx::TrayState::Off) playSwitchSound(g_stateVietnamese);
}

// Tray "Thoát VietTelex" (§5): installed -> the session goes back to the keyboard used
// before VietTelex (else English) and the next start selects VietTelex again; then quit.
void quitFromTray() {
    if (!portableMode()) {
        const std::vector<uintptr_t> hkls = keyboardLayouts();
        const uintptr_t back = vtx::pickExitLayout(hkls.data(), hkls.size(),
                                                   static_cast<uintptr_t>(readQword(L"previousKeyboard", 0)));
        bool ok = false;
        if (back) {
            ok = activateLayoutForSession(back);
            if (g_lastAppWnd && IsWindow(g_lastAppWnd)) requestInputLanguage(g_lastAppWnd, back);
        }
        writeFlag(L"reselectOnStart", true);
        appLog("app", std::string("quit from tray: previous keyboard ") + (back ? (ok ? "selected" : "failed") : "none"));
    }
    PostMessageW(g_mainWnd, WM_CLOSE, 0, 0);
}

// Portable Ctrl+Shift (the observe-only watcher saw the chord): toggle the foreground
// app's own memory — unless a Vietnamese keyboard is active there (it switches itself).
void portableChord() {
    HWND fg = GetForegroundWindow();
    if (!fg || gameSuspendedNow()) return;
    const FgApp app = describeWindow(fg);
    const int prop = fgTipProp(fg);
    const unsigned lang = fgLangId(app);
    if (vtx::portable::yields(prop, lang)) {
        // Not a silent mystery in the log (báo lỗi 1.3.17 "không chuyển được"): who has the window.
        appLog("app", std::string("portable Ctrl+Shift ignored: ") +
                          (prop ? "installed VietTelex keyboard active" : "a Vietnamese keyboard is selected") +
                          " in " + narrowAscii(app.identity) + " (lang " + std::to_string(lang) + ")");
        return;
    }
    const bool on = !storedVietnamese(app.identity);
    storeVietnamese(app.identity, on);
    setTrayState(on);
    appLog("app", std::string("portable Ctrl+Shift: ") + (on ? "vi" : "en"));
    if (showSwitchToast(parseSwitchIndicator(g_settings.switchIndicator), g_trayShown, gameSuspendedNow(),
                        currentNotificationState()))
        toastShow(on ? L"V" : L"E");
    playSwitchSound(on);
}

// In-TIP Việt/Anh switch (Ctrl+Shift, Alt+Z): store it for hosts that cannot (bit 1:
// AppContainer / low IL — keyed by the foreground app, where the switch happened) and
// refresh the mirror those hosts read.
void onAppLanguage(LPARAM lp) {
    const bool on = (lp & 1) != 0;
    if (lp & 2) {
        const FgApp app = describeWindow(GetForegroundWindow());
        storeVietnamese(app.identity, on);
        appLog("app", "applang stored for " + narrowAscii(app.identity) + " (TIP could not): " + (on ? "vi" : "en"));
    }
    mirrorAppLanguage();
    setTrayState(on);
}

void runCommand(unsigned cmd, LPARAM lp = 0) {
    if (!isValidAppCommand(cmd)) return;
    switch (static_cast<AppCommand>(cmd)) {
        case AppCommand::StateChanged: setTrayState(lp != 0); break;
        case AppCommand::UserSwitched:  // Ctrl+Shift / Alt+Z: the floating V/E indicator
            setTrayState(lp != 0);
            if (showSwitchToast(parseSwitchIndicator(g_settings.switchIndicator), g_trayShown, gameSuspendedNow(),
                                currentNotificationState()))
                toastShow(lp ? L"V" : L"E");
            playSwitchSound(lp != 0);
            break;
        case AppCommand::DirectMode: {
            const DirectModeRequest r = decodeDirectMode(static_cast<unsigned long>(lp));
            hookSetDirectFromTip(r.on, r.adoptTyped, r.inlineAutocomplete);
            break;
        }
        case AppCommand::SetAppLanguage: onAppLanguage(lp); break;
        case AppCommand::TextToolReply: textActionsTipReply(lp); break;
        case AppCommand::OpenSettings: showSettings(Tab::Typing); break;
        case AppCommand::CheckUpdate: startUpdateCheck(g_mainWnd, true); break;
        case AppCommand::OpenAbout: showSettings(Tab::About); break;
        case AppCommand::SetTelex:
        case AppCommand::SetVni:
            g_settings.vniMode = static_cast<AppCommand>(cmd) == AppCommand::SetVni;
            settingsChanged();
            refreshSettingsWindow();
            break;
    }
}

wchar_t g_pendingVersion[32] = {};  // version being installed (names the msiexec log)

// ---- automatic update check: once a day, also for a PC that never restarts the app -----
// One-shot timer to the next due time (no polling), re-armed after each automatic check and
// on resume from sleep (update_check.h autoCheckDelayMs).
constexpr UINT_PTR kTimerAutoUpdate = 0x5602;

void armAutoUpdateTimer() {
    if (!g_mainWnd) return;
    KillTimer(g_mainWnd, kTimerAutoUpdate);
    if (!g_settings.autoUpdateCheck) return;
    const unsigned delay = autoCheckDelay();
    SetTimer(g_mainWnd, kTimerAutoUpdate, delay ? delay : 60000, nullptr);  // due: retry in a minute
}

// App start, the timer, resume from sleep: check if due, else wait for the rest.
void autoUpdateTick() {
    if (g_mainWnd) KillTimer(g_mainWnd, kTimerAutoUpdate);
    if (!g_settings.autoUpdateCheck) return;
    if (autoCheckDue() && updateFlow().phase() == UpdateFlow::Phase::Idle) {
        startUpdateCheck(g_mainWnd, false);  // its result re-arms the timer
        if (updateFlow().phase() == UpdateFlow::Phase::Checking) return;
    }
    armAutoUpdateTimer();
}

// Yes / No box for a failed update: Yes opens the download page.
void offerDownloadPage(S text) {
    if (MessageBoxW(nullptr, tr(text), tr(S::AppName), MB_YESNO | MB_ICONWARNING | MB_SETFOREGROUND) == IDYES)
        ShellExecuteW(nullptr, L"open", vtx::kWindowsDownloadPageUrl, nullptr, nullptr, SW_SHOWNORMAL);
}

void onUpdateChecked(UpdateInfo* info) {
    // Interactive when any request it answered was (a click joining an automatic check).
    const bool interactive = updateFlow().checkDone() || info->interactive;
    if (!info->interactive) {
        markAutoChecked();
        armAutoUpdateTimer();
    }
    // The automatic check's prompt pops up unasked, maybe while the user types: No is the
    // default, so a key typed as it appears cannot start an install.
    const UINT ask = MB_YESNO | MB_ICONINFORMATION | MB_SETFOREGROUND | (interactive ? 0 : MB_DEFBUTTON2);
    if (info->available && portableMode()) {
        // Portable: no self-update — the download page has the new zip.
        const bool show = interactive || readString(L"lastNotifiedUpdateVersion") != info->version;
        if (show && updateFlow().beginPrompt()) {
            writeString(L"lastNotifiedUpdateVersion", info->version);
            wchar_t msg[256];
            wsprintfW(msg, tr(S::PortableUpdateAvailable), info->version);
            if (MessageBoxW(nullptr, msg, tr(S::AppName), ask) == IDYES)
                ShellExecuteW(nullptr, L"open", vtx::portable::kDownloadPageUrl, nullptr, nullptr, SW_SHOWNORMAL);
            updateFlow().promptDone(false);
        }
    } else if (info->available) {
        wchar_t msg[256];
        wsprintfW(msg, tr(S::UpdateAvailable), info->version);
        // Auto-check notifies once per version (lastNotifiedUpdateVersion, as macOS).
        bool show = interactive || readString(L"lastNotifiedUpdateVersion") != info->version;
        if (show && updateFlow().beginPrompt()) {
            writeString(L"lastNotifiedUpdateVersion", info->version);
            bool downloading = false;
            if (MessageBoxW(nullptr, msg, tr(S::AppName), ask) == IDYES) {
                lstrcpynW(g_pendingVersion, info->version, 32);
                downloading = startDownload(g_mainWnd, info->url);
            }
            updateFlow().promptDone(downloading);
        }
    } else if (interactive) {
        MessageBoxW(nullptr, info->ok ? tr(S::UpToDate) : tr(S::UpdateFailed), tr(S::AppName),
                    MB_OK | (info->ok ? MB_ICONINFORMATION : MB_ICONWARNING) | MB_SETFOREGROUND);
    }
    delete info;
}

void onDownloaded(WPARAM status, wchar_t* path) {
    if (status == kDownloadOk && path) {
        // Hand off and leave NOW: saves nothing pending (settings are saved on change),
        // WM_DESTROY removes the tray icon, WinMain releases the single-instance mutex.
        const bool started = runInstaller(path, g_pendingVersion);
        updateFlow().downloadDone(started);
        if (started) PostMessageW(g_mainWnd, WM_CLOSE, 0, 0);
        else offerDownloadPage(S::UpdateDownloadFailed);
    } else {
        updateFlow().downloadDone(false);
        if (status == kDownloadBadSignature)
            MessageBoxW(nullptr, tr(S::UpdateBadSignature), tr(S::AppName), MB_OK | MB_ICONWARNING | MB_SETFOREGROUND);
        else
            offerDownloadPage(status == kDownloadUnverified ? S::UpdateUnverified : S::UpdateDownloadFailed);
    }
    delete[] path;
}

LRESULT CALLBACK mainProc(HWND h, UINT msg, WPARAM wp, LPARAM lp) {
    if (msg == g_taskbarCreated && g_taskbarCreated) {
        g_trayShown = false;  // Explorer restarted: the old icon is gone
        syncTrayIcon();
        return 0;
    }
    LRESULT handled = 0;
    if (gameMessage(msg, wp, lp, handled)) return handled;          // Chế độ game hotkey, fullscreen re-checks
    if (textActionsMessage(msg, wp, lp, handled)) return handled;  // hotkey, TIP selection, timers  // hotkey, TIP selection, timers
    switch (msg) {
        case kAppCommandMsg: runCommand(static_cast<unsigned>(wp), lp); return 0;
        case kMsgSwitchChord:
            // Ctrl+Shift seen by the watcher. Inside VietTelex the TIP toggles by itself;
            // on another keyboard, bring VietTelex in (in Việt) for this window.
            // Portable: the chord IS the switch (no TIP) — never touch the keyboard list.
            if (portableMode()) {
                portableChord();
                return 0;
            }
            if (activateVietTelexForChord(parseSwitchHotkey(g_settings.switchHotkey), gameSuspendedNow())) {
                setTrayState(true);
                if (showSwitchToast(parseSwitchIndicator(g_settings.switchIndicator), g_trayShown, gameSuspendedNow(),
                                    currentNotificationState()))
                    toastShow(L"V");
                playSwitchSound(true);
            }
            return 0;
        // Restart Manager / logoff / an upgrade closing us: agree, then exit cleanly
        // (settings are saved on every change, so there is nothing left to flush).
        case WM_TIMER:
            if (wp == kTimerIdleTrim) {
                onIdleTrimTimer(h);
                return 0;
            }
            if (wp == kTimerAutoUpdate) {
                autoUpdateTick();
                return 0;
            }
            if (wp == 77) {
                KillTimer(h, 77);
                NOTIFYICONDATAW nid = {};
                nid.cbSize = sizeof nid;
                nid.hWnd = h;
                nid.uID = kTrayId + 1;
                Shell_NotifyIconW(NIM_DELETE, &nid);
            }
            return 0;
        case WM_POWERBROADCAST:  // back from sleep: the daily check may be due
            if (wp == PBT_APMRESUMEAUTOMATIC) autoUpdateTick();
            return TRUE;
        case WM_QUERYENDSESSION: return TRUE;
        case WM_ENDSESSION:
            if (wp) DestroyWindow(h);
            return 0;
        case WM_CLOSE: DestroyWindow(h); return 0;
        case kTrayMsg:
            // Left click / Enter: toggle Việt/Anh (or turn VietTelex back on); double click:
            // Settings. NOTIFYICON_VERSION_4 sends NIN_SELECT after WM_LBUTTONUP: handle one.
            switch (LOWORD(lp)) {
                case WM_LBUTTONUP:
                    if (!g_trayV4) trayLeftClick();
                    break;
                case NIN_SELECT:
                case NIN_KEYSELECT:
                    if (g_trayV4) trayLeftClick();
                    break;
                case WM_LBUTTONDBLCLK: showSettings(Tab::Typing); break;
                case WM_CONTEXTMENU:
                case WM_RBUTTONUP: showTrayMenu(); break;
                default: break;
            }
            return 0;
        case WM_SETTINGCHANGE:  // taskbar switched light/dark
            if (lp && lstrcmpW(reinterpret_cast<LPCWSTR>(lp), L"ImmersiveColorSet") == 0) syncTrayIcon();
            return 0;
        case kMsgUpdateChecked: onUpdateChecked(reinterpret_cast<UpdateInfo*>(lp)); return 0;
        case kMsgUpdateDownloaded: onDownloaded(wp, reinterpret_cast<wchar_t*>(lp)); return 0;
        case WM_DESTROY:
            debugContextShutdown();
            gameShutdown();
            toastShutdown();
            removeTrayIcon();
            textActionsShutdown();
            predictionWatchStop();
            hookShutdown();
            PostQuitMessage(0);
            return 0;
        default: break;
    }
    return DefWindowProcW(h, msg, wp, lp);
}

bool snapshotMissing() {
    wchar_t buf[MAX_PATH];
    DWORD n = GetEnvironmentVariableW(L"LOCALAPPDATA", buf, MAX_PATH);
    if (n == 0 || n >= MAX_PATH) return false;
    std::wstring p = std::wstring(buf) + L"\\VietTelex\\settings.bin";
    return GetFileAttributesW(p.c_str()) == INVALID_FILE_ATTRIBUTES;
}

// Undocumented but stable since 1903: uxtheme ordinal 135 SetPreferredAppMode —
// makes the tray/context menus follow the dark theme. Skipped when unavailable.
void allowDarkMenus() {
    HMODULE ux = LoadLibraryExW(L"uxtheme.dll", nullptr, LOAD_LIBRARY_SEARCH_SYSTEM32);
    if (!ux) return;
    using Fn = int(WINAPI*)(int);
    if (auto fn = reinterpret_cast<Fn>(reinterpret_cast<void*>(GetProcAddress(ux, MAKEINTRESOURCEA(135)))))
        fn(1 /* AllowDark */);
    using Refresh = void(WINAPI*)();  // #104 RefreshImmersiveColorPolicyState
    if (auto r = reinterpret_cast<Refresh>(reinterpret_cast<void*>(GetProcAddress(ux, MAKEINTRESOURCEA(104))))) r();
}

std::string g_profileIconArg;

// Elevated helper (run with the "runas" verb by Settings when the icon choice changes):
// point the keyboard profile's IconIndex (HKLM, 64- and 32-bit views) at the choice's
// icon in VietTelexTIP.dll. Chosen over a user-writable icon FILE because the profile
// icon is loaded into every process incl. elevated ones and the secure desktop — no
// user-writable file should ever be parsed there. Cost: one UAC prompt per change.
int setProfileIcon(const std::string& name) {
    const DWORD index = static_cast<DWORD>(profileIconIndex(parseIconChoice(name)));
    const std::wstring key = widen(reg::languageProfileKey());
    int written = 0;
    for (REGSAM view : {KEY_WOW64_64KEY, KEY_WOW64_32KEY}) {
        HKEY k;
        if (RegOpenKeyExW(HKEY_LOCAL_MACHINE, key.c_str(), 0, KEY_SET_VALUE | view, &k) == ERROR_SUCCESS) {
            if (RegSetValueExW(k, L"IconIndex", 0, REG_DWORD, reinterpret_cast<const BYTE*>(&index), sizeof index) ==
                ERROR_SUCCESS)
                ++written;
            RegCloseKey(k);
        }
    }
    // Explorer / the input switcher cache icons: nudge them (new processes re-read anyway).
    SHChangeNotify(SHCNE_ASSOCCHANGED, SHCNF_IDLIST, nullptr, nullptr);
    DWORD_PTR r;
    SendMessageTimeoutW(HWND_BROADCAST, WM_SETTINGCHANGE, 0, reinterpret_cast<LPARAM>(L"intl"), SMTO_ABORTIFHUNG, 2000,
                        &r);
    return written > 0 ? 0 : 1;
}

// `--wait-install <pid>` (a copy of this exe in %TEMP%): wait for msiexec, then start the
// installed VietTelex if the MSI's LaunchApp did not (UAC cancelled, install failed).
// Appends one line to %LOCALAPPDATA%\VietTelex\update-watcher.log (evidence for reports).
// `createFolder` false (after an uninstall): only into a folder that still exists — "gỡ sạch"
// just erased it.
void watcherLog(const std::wstring& line, bool createFolder) {
    wchar_t dir[MAX_PATH];
    DWORD n = GetEnvironmentVariableW(L"LOCALAPPDATA", dir, MAX_PATH);
    if (n == 0 || n >= MAX_PATH) return;
    std::wstring folder = std::wstring(dir) + L"\\VietTelex";
    if (createFolder) CreateDirectoryW(folder.c_str(), nullptr);
    else if (GetFileAttributesW(folder.c_str()) == INVALID_FILE_ATTRIBUTES) return;
    HANDLE f = CreateFileW((folder + L"\\" + vtx::kWatcherLogName).c_str(), FILE_APPEND_DATA, FILE_SHARE_READ,
                           nullptr, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (f == INVALID_HANDLE_VALUE) return;
    SYSTEMTIME t;
    GetLocalTime(&t);
    wchar_t stamp[40];
    wsprintfW(stamp, L"%04u-%02u-%02u %02u:%02u:%02u ", t.wYear, t.wMonth, t.wDay, t.wHour, t.wMinute, t.wSecond);
    std::string u = narrow(stamp + line + L"\r\n");
    DWORD w = 0;
    WriteFile(f, u.data(), static_cast<DWORD>(u.size()), &w, nullptr);
    CloseHandle(f);
}

// `--wait-install <pid>` (a copy of this exe in %TEMP%): wait for msiexec, then — only if
// it FAILED or was cancelled — start the installed VietTelex (success: the MSI's
// LaunchApp already started the new version; starting another would race it).
// `uninstall` ("Gỡ cài đặt VietTelex", msiexec /x): cancelled = the app comes back; done =
// nothing is installed, nothing starts.
int waitInstall(unsigned long pid, bool uninstall) {
    bool known = false;
    DWORD code = 0;
    if (HANDLE p = OpenProcess(SYNCHRONIZE | PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid)) {
        WaitForSingleObject(p, 2 * 60 * 60 * 1000);
        known = GetExitCodeProcess(p, &code) && code != STILL_ACTIVE;
        CloseHandle(p);
    }
    Sleep(3000);  // LaunchApp runs at the very end of the install
    wchar_t exe[MAX_PATH] = {};
    DWORD sz = sizeof exe;
    const bool have = RegGetValueW(HKEY_LOCAL_MACHINE, L"SOFTWARE\\VietTelex", L"AppPath",
                                   RRF_RT_REG_SZ | RRF_SUBKEY_WOW6464KEY, nullptr, exe, &sz) == ERROR_SUCCESS &&
                      GetFileAttributesW(exe) != INVALID_FILE_ATTRIBUTES;
    HWND runningWnd = FindWindowW(kAppWindowClass, nullptr);
    wchar_t title[64] = {};
    if (runningWnd) GetWindowTextW(runningWnd, title, 64);
    const vtx::AfterInstall act = vtx::afterInstallAction(known, code, runningWnd != nullptr, have);
    wchar_t line[512];
    wsprintfW(line, L"watcher %s%s: msiexec pid %lu exit %s%lu, running=\"%s\", installed=%s -> %s",
              VTX_VER_STRING_W, uninstall ? L" (uninstall)" : L"", pid, known ? L"" : L"unknown/", static_cast<unsigned long>(code), title,
              have ? exe : L"(none)", act == vtx::AfterInstall::LaunchInstalled ? L"relaunch installed app" : L"nothing");
    watcherLog(line, !uninstall);
    if (act == vtx::AfterInstall::LaunchInstalled)
        ShellExecuteW(nullptr, L"open", exe, L"--settings", nullptr, SW_SHOWNORMAL);
    return 0;
}

unsigned long g_waitPid = 0;
bool g_waitUninstall = false;  // --wait-install <pid> --uninstall
SetupTrigger g_setupTrigger = SetupTrigger::Installer;
bool g_settingsArg = false;  // --settings: opens Settings even with "start hidden" on (#159)

unsigned parseCommandArg(const wchar_t* cmdLine, bool& background, int& oneShot) {
    int argc = 0;
    wchar_t** argv = CommandLineToArgvW(cmdLine, &argc);
    unsigned cmd = 0;
    {
        std::vector<std::wstring> all;
        for (int i = 1; argv && i < argc; ++i) all.push_back(argv[i]);
        if (vtx::parseWaitInstallArg(all, g_waitPid)) {
            oneShot = 4;
            g_waitUninstall = vtx::parseWatcherUninstallArg(all);
        }
        vtx::parseSetupUserArgs(all, g_setupTrigger);
    }
    for (int i = 1; argv && i < argc; ++i) {
        std::wstring a = argv[i];
        if (a == L"--background") background = true;
        else if (a == L"--settings") {  // installer: open Settings
            background = false;
            g_settingsArg = true;
        }
        else if (a == L"--setup-user") oneShot = 1;
        else if (a == L"--cleanup-user") oneShot = 2;
        else if (a == L"--set-profile-icon" && i + 1 < argc) {
            oneShot = 3;
            g_profileIconArg = narrow(argv[++i]);
        }
        else if (a == L"--command" && i + 1 < argc) {
            cmd = static_cast<unsigned>(_wtoi(argv[++i]));
            if (!vtx::isUserCommand(cmd)) cmd = 0;
        }
    }
    if (argv) LocalFree(argv);
    return cmd;
}

}  // namespace

void settingsChanged() {
    saveSettings(g_settings);
    setPortableDefaultVietnamese(!g_settings.startEnglish);
    syncTrayIcon();
    setEnglish(g_settings.uiLanguage == "en");
    hookConfigure(g_settings);
    textActionsConfigure();
    gameConfigure();
    armAutoUpdateTimer();  // "Tự kiểm tra cập nhật" turned on / off
}

// Per-user setup (onboarding.h planUserSetup): keyboard in the user's list, autostart, the
// welcome window flag. Idempotent; nothing at all when running as SYSTEM.
void runUserSetup(SetupTrigger trigger) {
    UserSetupState st;
    st.systemAccount = runningAsSystem();
    st.setupDone = readFlag(L"userSetupDone");
    st.welcomeShown = readFlag(L"welcomeShown");
    const UserSetupPlan plan = planUserSetup(trigger, st);
    appLog("app", std::string("per-user setup (") +
                      (trigger == SetupTrigger::ActiveSetup ? "active setup"
                       : trigger == SetupTrigger::Installer ? "installer"
                                                            : "app start") +
                      "): " + (st.systemAccount ? "SYSTEM, skipped" : plan.addKeyboard ? "set up" : "already set up"));
    if (plan.addKeyboard) addKeyboardForUser();
    if (plan.autostart) setAutostart(true);
    if (plan.markDone) writeFlag(L"userSetupDone", true);
    if (plan.welcomePending) writeFlag(L"welcomePending", true);
}

namespace {

// A folder we can create files in (portable settings.ini next to the exe).
bool dirWritable(const std::wstring& dir) {
    if (dir.empty()) return false;
    const std::wstring probe = vtx::portable::joinPath(dir, L".viettelex-write-test");
    HANDLE f = CreateFileW(probe.c_str(), GENERIC_WRITE, 0, nullptr, CREATE_ALWAYS,
                           FILE_ATTRIBUTE_TEMPORARY | FILE_FLAG_DELETE_ON_CLOSE, nullptr);
    if (f == INVALID_HANDLE_VALUE) return false;
    CloseHandle(f);
    return true;
}

std::wstring envDir(const wchar_t* name) {
    wchar_t buf[MAX_PATH];
    const DWORD n = GetEnvironmentVariableW(name, buf, MAX_PATH);
    return (n == 0 || n >= MAX_PATH) ? std::wstring() : std::wstring(buf, n);
}

// Portable mode (core/portable.h): decided before anything reads or writes settings.
bool setUpPortable() {
    const std::wstring dir = vtx::portable::exeDirOf(selfExePath());
    const bool on = vtx::portable::detectPortable(
        dir, [](const std::wstring& p) { return GetFileAttributesW(p.c_str()) != INVALID_FILE_ATTRIBUTES; });
    initStorage(on, on ? vtx::portable::settingsPath(dir, dirWritable(dir), envDir(L"APPDATA")) : std::wstring());
    return on;
}

// §1: VietTelex in the list, default and selected when it was missing / on the first run /
// after tray Thoát (app_feel.h planKeyboardAtStart). Installed build only.
void ensureKeyboardAtStart(bool firstRun) {
    vtx::KeyboardStatus ks;
    ks.portable = portableMode();
    if (!ks.portable) {
        ks.systemAccount = runningAsSystem();
        bool registered = false;
        ks.inUserList = vietTelexInUserList(registered);
        ks.tipRegistered = registered;
    }
    ks.firstRun = firstRun;
    ks.reselectPending = readFlag(L"reselectOnStart");
    const vtx::KeyboardPlan p = vtx::planKeyboardAtStart(ks);
    if (p.rememberPrevious) rememberPreviousKeyboard();
    bool added = false, made = false, selected = false;
    if (p.add) added = addKeyboardForUser();
    if (p.makeDefault) made = setDefaultKeyboardForUser();
    if (p.select) selected = selectVietTelexForSession();
    if (ks.reselectPending) writeFlag(L"reselectOnStart", false);
    appLog("app", std::string("keyboard at start: ") + (ks.portable ? "portable, untouched"
                                                       : !ks.tipRegistered ? "TIP not registered"
                                                       : ks.inUserList ? "in list" : "missing") +
                      (p.add ? (added ? ", added" : ", add failed") : "") +
                      (p.makeDefault ? (made ? ", default" : ", default failed") : "") +
                      (p.select ? (selected ? ", selected" : ", select failed") : ""));
}

}  // namespace

}  // namespace vtx::app

using namespace vtx::app;

int WINAPI wWinMain(HINSTANCE inst, HINSTANCE, PWSTR, int) {
    g_inst = inst;
    bool background = false;
    int oneShot = 0;
    unsigned cmd = parseCommandArg(GetCommandLineW(), background, oneShot);
    const bool isPortable = setUpPortable();
    // Installer / uninstaller / elevated helpers / update watcher: never for a portable copy
    // (no MSI, no HKLM, no keyboard list).
    if (isPortable && oneShot != 0) return 0;
    if (isPortable &&
        vtx::portable::decideStart(FindWindowW(kAppWindowClass, nullptr) != nullptr) ==
            vtx::portable::StartAction::ExitInstalledRunning) {
        g_settings = loadSettings();
        setEnglish(g_settings.uiLanguage == "en");
        appSetLogging(g_settings.debugLogging);
        appLog("app", std::string("portable ") + VTX_VER_STRING + ": installed VietTelex is running -> quit");
        MessageBoxW(nullptr, tr(S::PortableInstalledRunning), tr(S::AppName), MB_OK | MB_ICONINFORMATION);
        return 0;
    }
    // Started from inside the zip (Explorer copied only the exe, no portable.ini): it would
    // run as the installed build from a throwaway folder (portable.h launchedFromArchive).
    // Plain starts only — the update watcher's own copy in %TEMP% is oneShot 4.
    if (!isPortable && oneShot == 0 && vtx::portable::launchedFromArchive(selfExePath())) {
        MessageBoxW(nullptr, tr(S::RunFromArchive), tr(S::AppName), MB_OK | MB_ICONWARNING);
        return 0;
    }

    if (oneShot == 1) {  // installer (as the installing user, or SYSTEM) / Active Setup at logon
        if (runningAsSystem()) return 0;  // HKCU of SYSTEM: nobody's; Active Setup reaches the users
        // A brand-new user starts with the tray icon on (app_feel.h); existing users keep theirs.
        const bool newUser = vtx::isNewUser(settingsStored(), readFlag(L"userSetupDone"), readFlag(L"welcomeShown"));
        g_settings = loadSettings();
        if (newUser) vtx::applyNewUserDefaults(g_settings);
        appSetLogging(g_settings.debugLogging);
        saveSettings(g_settings);  // publish the snapshot for the TIP
        runUserSetup(g_setupTrigger);
        return 0;  // never UI here: Active Setup runs before the desktop exists
    }
    if (oneShot == 3) return setProfileIcon(g_profileIconArg);  // elevated helper
    if (oneShot == 4) return waitInstall(g_waitPid, g_waitUninstall);             // detached update watcher
    if (oneShot == 2) {  // uninstaller: "gỡ sạch"
        // Wait for a running app to exit first: it saves learned words at exit, which would
        // put a file back after the erase below.
        closeRunningApps(GetCurrentProcessId(), vtx::kQuitGraceMs);
        removeKeyboardForUser();
        setAutostart(false);
        eraseUserData();
        // So that a later reinstall runs the per-user setup (Active Setup) for this user again.
        const std::wstring as = std::wstring(L"Software\\Microsoft\\Active Setup\\Installed Components\\") +
                                widen(vtx::kActiveSetupGuid);
        RegDeleteTreeW(HKEY_CURRENT_USER, as.c_str());
        return 0;
    }

    // Single instance: a second launch hands its request to the first and leaves
    // ("yield, not kill" — macOS SingleInstance) — unless the running one is OLDER (an
    // upgrade just replaced the files): then it is asked to quit and this one takes over.
    // Portable copies use their own mutex + window class: the installed TIP never finds them.
    HANDLE mutex = CreateMutexW(nullptr, TRUE, isPortable ? vtx::portable::kMutexName : L"Local\\VietTelex.App");
    if (mutex && GetLastError() == ERROR_ALREADY_EXISTS) {
        HWND h = FindWindowW(appWindowClass(), nullptr);
        wchar_t title[64] = {};
        if (h) GetWindowTextW(h, title, 64);
        // Portable: always hand off (no upgrade replaces files under a running copy).
        if (h && (isPortable ||
                  vtx::decideHandoff(title, vtx::versionForDisplay(VTX_VER_STRING)) == vtx::Handoff::PassToRunning)) {
            AllowSetForegroundWindow(ASFW_ANY);
            PostMessageW(h, kAppCommandMsg,
                         cmd ? cmd : (background ? 0 : static_cast<unsigned>(vtx::AppCommand::OpenSettings)), 0);
            CloseHandle(mutex);
            return 0;
        }
        if (!isPortable) closeRunningApps(GetCurrentProcessId(), vtx::kQuitGraceMs);  // older instance: replace it
    }

    INITCOMMONCONTROLSEX icc = {sizeof icc, ICC_TAB_CLASSES | ICC_LISTVIEW_CLASSES | ICC_LINK_CLASS |
                                                ICC_STANDARD_CLASSES};
    InitCommonControlsEx(&icc);
    allowDarkMenus();

    // A brand-new user (nothing stored yet: Store / per-machine install this user never set
    // up, or a fresh portable copy) starts with the tray icon on (app_feel.h).
    const bool newUser = vtx::isNewUser(settingsStored(), readFlag(L"userSetupDone"), readFlag(L"welcomeShown"));
    g_settings = loadSettings();
    if (newUser) vtx::applyNewUserDefaults(g_settings);
    appSetLogging(g_settings.debugLogging);
    setEnglish(g_settings.uiLanguage == "en");
    setPortableDefaultVietnamese(!g_settings.startEnglish);
    // Chế độ game never survives a restart (or a reboot): a forgotten "every key passes
    // through" would look like a broken keyboard.
    const bool staleGameMode = g_settings.gameMode;
    g_settings.gameMode = false;
    debugContextApply(g_settings);  // debug log on: the header before the first app lines
    // Windows' text-suggestion setting (word prediction) may have changed while we were not
    // running: republish the snapshot then.
    const bool predictionStale = readFlag(L"systemTextPredictionPublished") != g_settings.systemTextPrediction;
    if (newUser || (!isPortable && snapshotMissing()) || staleGameMode || predictionStale) saveSettings(g_settings);
    // Another user on a per-machine install (Store / SYSTEM install before their next logon).
    const bool setupDoneBefore = readFlag(L"userSetupDone");
    if (isPortable) writeFlag(L"userSetupDone", true);  // nothing to set up: no keyboard, no autostart
    else runUserSetup(vtx::SetupTrigger::AppStart);
    const vtx::WelcomeAction welcome =
        vtx::decideWelcome(true, readFlag(L"welcomePending"), readFlag(L"welcomeShown"), setupDoneBefore);
    if (welcome == vtx::WelcomeAction::MarkShown) writeFlag(L"welcomeShown", true);
    // Onboarding (docs/ONBOARDING-SPEC.md): users set up by a version without onboarding get
    // the one-time "Gõ lẫn tiếng Anh" card in Settings — their values are never touched. New
    // users no longer get the profile pages (WINDOWS-APP-FEEL-SPEC §4: the welcome is one
    // page; the profile stays in Settings): they start with the defaults (= profile `vi`).
    const vtx::OnboardingAction onboarding = vtx::decideOnboarding(readFlagState(L"onboardingDone"), welcome);
    if (onboarding == vtx::OnboardingAction::Upgrade) {
        writeFlag(L"onboardingDone", true);
        writeFlag(L"mixedCardPending", true);
    } else if (onboarding == vtx::OnboardingAction::ShowWelcome || onboarding == vtx::OnboardingAction::ShowProfile) {
        writeFlag(L"onboardingDone", true);
    }
    // §1: the keyboard is there, the default and selected — before any window shows.
    ensureKeyboardAtStart(welcome == vtx::WelcomeAction::Show);

    WNDCLASSEXW wc = {};
    wc.cbSize = sizeof wc;
    wc.lpfnWndProc = mainProc;
    wc.hInstance = inst;
    wc.lpszClassName = appWindowClass();
    RegisterClassExW(&wc);
    // Hidden top-level window (not HWND_MESSAGE: those are invisible to FindWindow,
    // which is how the TIP and a second instance reach us).
    const std::wstring mainTitle = vtx::mainWindowTitle(vtx::versionForDisplay(VTX_VER_STRING));  // version for handoff
    g_mainWnd = CreateWindowExW(WS_EX_TOOLWINDOW, appWindowClass(), mainTitle.c_str(), WS_POPUP, 0, 0, 0, 0, nullptr,
                                nullptr, inst, nullptr);
    if (!g_mainWnd) return 1;
    // The TIP posts from inside other apps, some at lower integrity (UIPI).
    ChangeWindowMessageFilterEx(g_mainWnd, kAppCommandMsg, MSGFLT_ALLOW, nullptr);
    // Công cụ văn bản: the TIP hands over the selection with WM_COPYDATA (text_tool_ipc.h).
    ChangeWindowMessageFilterEx(g_mainWnd, WM_COPYDATA, MSGFLT_ALLOW, nullptr);
    g_taskbarCreated = RegisterWindowMessageW(L"TaskbarCreated");
    // The tray's first state: the app in front now (it may be on another keyboard: "off").
    if (HWND fg = GetForegroundWindow(); fg && !isShellSurface(fg)) {
        DWORD pid = 0;
        GetWindowThreadProcessId(fg, &pid);
        if (pid != GetCurrentProcessId()) {
            g_lastAppWnd = fg;
            g_trayState = trayStateOf(fg);
            g_stateVietnamese = g_trayState == vtx::TrayState::Vietnamese;
        }
    }
    syncTrayIcon();
    hookSetElevationNotifier(showElevationNotice);
    hookSetChordTarget(g_mainWnd, kMsgSwitchChord);
    hookConfigure(g_settings);
    textActionsConfigure();
    predictionWatchStart();
    gameConfigure();
    mirrorAppLanguage();  // AppContainer hosts read the per-app Việt/Anh memory from here
    appLog("app", std::string("started ") + VTX_VER_STRING);

    if (welcome == vtx::WelcomeAction::Show) {
        // first run: instead of Settings (it has an "Open Settings" button)
        showWelcome();
        if (cmd && cmd != static_cast<unsigned>(vtx::AppCommand::OpenSettings)) runCommand(cmd);
    } else if (cmd) {
        runCommand(cmd);
    } else if (vtx::opensSettingsAtStart(background, g_settingsArg, g_settings.startHidden)) {
        showSettings(Tab::Typing);
    }
    autoUpdateTick();  // due: check now; else a one-shot timer for the rest of the day
    requestIdleTrim();  // a window shown above drops it; its closing asks again

    MSG msg;
    while (GetMessageW(&msg, nullptr, 0, 0) > 0) {
        if (settingsDialogMessage(&msg)) continue;
        if (welcomeDialogMessage(&msg)) continue;
        TranslateMessage(&msg);
        DispatchMessageW(&msg);
    }
    if (mutex) CloseHandle(mutex);
    return 0;
}
