#include "app_policy.h"

#include <algorithm>
#include <cstring>

namespace vtx {

const char* appModeName(AppMode m) {
    switch (m) {
        case AppMode::Composition: return "composition";
        case AppMode::InPlace: return "inPlace";
        case AppMode::HookFallback: return "hookFallback";
        case AppMode::Off: return "off";
        case AppMode::Direct: return "direct";
    }
    return "composition";
}

bool parseAppMode(const std::string& s, AppMode& out) {
    if (s == "composition") { out = AppMode::Composition; return true; }
    if (s == "inPlace") { out = AppMode::InPlace; return true; }
    if (s == "hookFallback") { out = AppMode::HookFallback; return true; }
    if (s == "off") { out = AppMode::Off; return true; }
    if (s == "direct") { out = AppMode::Direct; return true; }
    return false;
}

std::string normalizeExeName(const std::string& p) {
    size_t slash = p.find_last_of("\\/");
    std::string name = slash == std::string::npos ? p : p.substr(slash + 1);
    for (char& c : name)
        if (c >= 'A' && c <= 'Z') c = static_cast<char>(c - 'A' + 'a');
    return name;
}

namespace {
struct Rule {
    const char* exe;
    AppMode mode;
};
// Built-in defaults. Kept deliberately short: everything not listed uses in-place
// (the default since 1.0.9; composition is a per-app choice). Entries
// here are apps where typing Vietnamese locally is wrong by design (the remote
// machine's IME types) — same reasoning as macOS's remote-desktop passthrough.
// Candidates for InPlace/HookFallback are learned from the §5.2 manual matrix on
// real hardware and added here with a comment naming the symptom.
constexpr Rule kRules[] = {
    // Consoles/terminals: their TSF document holds only the composition (text typed so
    // far is already in the shell), so in-place can never verify or replace — 1.1.0 in
    // cmd.exe typed "thuưr gox". Direct = the hook types (no underline); without
    // VietTelex.exe running the TIP composes instead.
    {"conhost.exe", AppMode::Direct},        // cmd, PowerShell, WSL console window
    {"openconsole.exe", AppMode::Direct},    // Windows Terminal's bundled conhost
    {"windowsterminal.exe", AppMode::Direct},
    {"mintty.exe", AppMode::Direct},         // Git Bash / MSYS2 / Cygwin (IMM only)
    // Other terminals: GPU/own-rendered, IMM or partial TSF, no readable history.
    {"alacritty.exe", AppMode::Direct},
    {"wezterm-gui.exe", AppMode::Direct},
    {"conemu64.exe", AppMode::Direct},
    {"conemu.exe", AppMode::Direct},
    {"putty.exe", AppMode::Direct},
    {"kitty.exe", AppMode::Direct},        // KiTTY (PuTTY fork)
    {"tabby.exe", AppMode::Direct},
    // Remote / virtual machines: the guest's input method types.
    {"vmware.exe", AppMode::Off},
    {"vmware-vmx.exe", AppMode::Off},
    {"vmware-view.exe", AppMode::Off},
    {"virtualboxvm.exe", AppMode::Off},
    {"wfica32.exe", AppMode::Off},              // Citrix Workspace
    {"cdviewer.exe", AppMode::Off},             // Citrix Desktop Viewer
    {"ultraviewer_desktop.exe", AppMode::Off},
    {"moonlight.exe", AppMode::Off},
    {"mstsc.exe", AppMode::Off},          // Remote Desktop Connection
    {"msrdc.exe", AppMode::Off},          // Remote Desktop (Store/AVD client)
    {"vmconnect.exe", AppMode::Off},      // Hyper-V console
    {"anydesk.exe", AppMode::Off},
    {"teamviewer.exe", AppMode::Off},
    {"rustdesk.exe", AppMode::Off},
    {"parsecd.exe", AppMode::Off},
    {"vncviewer.exe", AppMode::Off},
};
}  // namespace

std::string appIdentity(const std::string& processExe, const std::string& rootOwnerExe) {
    if (processExe == "msedgewebview2.exe" && !rootOwnerExe.empty() && rootOwnerExe != processExe)
        return rootOwnerExe;
    return processExe;
}

bool builtInAppMode(const std::string& exe, AppMode& out) {
    for (const Rule& r : kRules) {
        if (exe == r.exe) { out = r.mode; return true; }
    }
    return false;
}

AppMode resolveAppMode(const std::string& exe, const std::map<std::string, AppMode>& overrides) {
    auto it = overrides.find(exe);
    if (it != overrides.end()) return it->second;
    AppMode m;
    if (builtInAppMode(exe, m)) return m;
    // Default since 1.0.9: in-place (verified edits of the text before the caret; falls
    // back to composition per field when the text cannot be read or verified).
    return AppMode::InPlace;
}

HostText classifyContext(const ContextInfo& c) {
    if (!c.hasContext) return HostText::Ignore;
    if (c.keyboardDisabled || c.readOnly || !c.unicodeWindow) return HostText::Literal;
    if (c.console) return HostText::CompositionOnly;
    if (!c.transitory) return HostText::Normal;
    if (c.hasParent) return c.parentTransitory ? HostText::CompositionOnly : HostText::NormalViaParent;
    if (c.cuasEmulated) return HostText::CompositionOnly;
    return HostText::Normal;  // Chromium & co: transitory by convention, fully readable
}

bool isEditControlClass(const std::u16string& realClass, const std::u16string& className) {
    auto has = [](const std::u16string& s, const char* needle) {
        const size_t n = std::strlen(needle);
        if (s.size() < n) return false;
        for (size_t i = 0; i + n <= s.size(); ++i) {
            size_t j = 0;
            for (; j < n; ++j) {
                char16_t c = s[i + j];
                if (c >= u'A' && c <= u'Z') c = static_cast<char16_t>(c - u'A' + u'a');
                if (c != static_cast<char16_t>(needle[j])) break;
            }
            if (j == n) return true;
        }
        return false;
    };
    return has(realClass, "edit") || has(className, "edit") || has(realClass, "memo") || has(className, "memo");
}

bool isWpfWindowClass(const std::u16string& className) {
    static const std::u16string kPrefix = u"HwndWrapper[";
    return className.size() > kPrefix.size() && className.compare(0, kPrefix.size(), kPrefix) == 0;
}

bool wpfOwnsClaimedKeys(const ContextInfo& c, HostText host) {
    return c.wpf && host == HostText::Normal && !c.transitory && !c.console && !c.cuasEmulated;
}

bool wpfDefaultStore(const ContextInfo& c, HostText host) {
    return c.wpf && host == HostText::NormalViaParent && !c.editControl && !c.console && !c.cuasEmulated;
}

bool directSurvivesFocusChange(uintptr_t requestedFocus, bool requestedInWpf, uintptr_t newFocus,
                               bool newFocusInForeground) {
    return requestedInWpf && requestedFocus != 0 && newFocus == requestedFocus && newFocusInForeground;
}

std::string describeContext(const ContextInfo& c, HostText host, const std::u16string& focusClass) {
    auto b = [](bool v) { return v ? " 1" : " 0"; };
    std::string s = "context:";
    if (!c.hasContext) s += " none";
    s += std::string(" transitory") + b(c.transitory) + " hasParent" + b(c.hasParent) + " parentTransitory" +
         b(c.parentTransitory) + " editControl" + b(c.editControl) + " wpf" + b(c.wpf) + " cuasEmulated" +
         b(c.cuasEmulated) + " readOnly" + b(c.readOnly) + " host " + std::to_string(static_cast<int>(host)) +
         " class ";
    for (char16_t ch : focusClass) s += (ch >= 0x20 && ch < 0x7F) ? static_cast<char>(ch) : '?';
    if (focusClass.empty()) s += "-";
    return s;
}

bool passedKeysReachApp(const ContextInfo& c, HostText host) {
    if (c.console || c.cuasEmulated) return false;
    if (wpfOwnsClaimedKeys(c, host)) return false;
    switch (host) {
        case HostText::Normal: return !c.transitory;
        case HostText::NormalViaParent: return !c.editControl;
        default: return false;
    }
}

FieldPolicy classifyInputScopes(const int* scopes, size_t count) {
    for (size_t i = 0; i < count; ++i) {
        switch (scopes[i]) {
            case 4:   // IS_EMAIL_USERNAME
            case 5:   // IS_EMAIL_SMTPEMAILADDRESS
            case 28:  // IS_DIGITS
            case 29:  // IS_NUMBER
            case 31:  // IS_PASSWORD
            case 32: case 33: case 34: case 35:  // IS_TELEPHONE_*
            case 39:  // IS_NUMBER_FULLWIDTH
            case 40:  // IS_ALPHANUMERIC_HALFWIDTH (IDs, codes)
            case 63:  // IS_NUMERIC_PASSWORD
            case 64:  // IS_NUMERIC_PIN
            case 65:  // IS_ALPHANUMERIC_PIN
            case 66:  // IS_ALPHANUMERIC_PIN_SET
                return FieldPolicy::Literal;
            // Deliberately NOT literal:
            //  * IS_URL (1): Chrome/Edge tag the address bar IS_URL, and that is where
            //    people type Vietnamese searches. Auto-restore already turns "google",
            //    "github" etc. back into ASCII at the boundary.
            //  * IS_PRIVATE (61): Edge InPrivate / Chrome incognito mean "do not learn";
            //    VietTelex learns nothing, so Vietnamese must keep working there.
            default: break;
        }
    }
    return FieldPolicy::Normal;
}

bool isChromiumNativeOmniboxBrowser(const std::string& exe) {
    static const char* const kBrowsers[] = {
        "msedge.exe",    // Microsoft Edge (field report 2026-10)
        "chrome.exe",    // Google Chrome (same OmniboxViewViews code)
        "brave.exe",
        "chromium.exe",
        "browser.exe",   // Cốc Cốc, Yandex Browser (Chromium shells, native omnibox)
        "opera.exe",
        "thorium.exe",
    };
    for (const char* b : kBrowsers)
        if (exe == b) return true;
    return false;
}

bool omniboxNeedsPageUrl(const std::string& exe, const int* scopes, size_t count) {
    return count == 1 && scopes[0] == 61 /* IS_PRIVATE */ && isChromiumNativeOmniboxBrowser(exe);
}

bool fieldPrefersComposition(const std::string& exe, const int* scopes, size_t count, PageUrl pageUrl) {
    if (!isChromiumNativeOmniboxBrowser(exe)) return false;
    for (size_t i = 0; i < count; ++i)
        if (scopes[i] == 1) return true;  // IS_URL
    // Private window: no IS_URL to go by; the browser's own text field has no page URL.
    return pageUrl == PageUrl::Empty && omniboxNeedsPageUrl(exe, scopes, count);
}

bool shellSearchPrefersComposition(const std::string& app, bool asyncStore) {
    if (!asyncStore) return false;
    return app == "searchhost.exe" || app == "searchapp.exe" || app == "searchui.exe" ||
           app == "startmenuexperiencehost.exe";
}

bool officeUiPrefersComposition(const std::string& exe, const std::u16string& focusClass, bool asyncStore) {
    return !asyncStore && exe == "winword.exe" && (focusClass == u"NetUIHWND" || focusClass == u"RICHEDIT60W");
}

}  // namespace vtx
