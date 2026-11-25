// debug_log.cpp — see debug_log.h.
#include "viettelex/debug_log.h"

#include <cstdlib>
#include <dirent.h>
#include <fstream>
#include <sys/stat.h>
#include <sys/utsname.h>

namespace viettelex::debuglog {

bool enabled() {
    static const bool on = std::getenv("VIETTELEX_DEBUG") != nullptr;
    return on;
}

namespace {

std::string env(const char *name) {
    const char *v = std::getenv(name);
    return v ? v : "";
}

bool exists(const char *path) {
    struct stat st;
    return ::stat(path, &st) == 0;
}

bool hasEntryWithPrefix(const char *dir, const char *prefix) {
    DIR *d = ::opendir(dir);
    if (!d) return false;
    bool found = false;
    std::string p(prefix);
    while (dirent *e = ::readdir(d))
        if (std::string(e->d_name).rfind(p, 0) == 0) { found = true; break; }
    ::closedir(d);
    return found;
}

std::string osRelease() {
    std::ifstream f("/etc/os-release");
    std::string line;
    while (std::getline(f, line)) {
        if (line.rfind("PRETTY_NAME=", 0) != 0) continue;
        std::string v = line.substr(12);
        if (v.size() >= 2 && (v.front() == '"' || v.front() == '\'')) v = v.substr(1, v.size() - 2);
        return v;
    }
    return "";
}

const char *b(bool v) { return v ? "1" : "0"; }
std::string orQ(const std::string &s) { return s.empty() ? "?" : s; }

const char *modeName(DisplayMode m) {
    switch (m) {
    case DisplayMode::Preedit: return "preedit";
    case DisplayMode::Surrounding: return "surrounding";
    case DisplayMode::Direct: return "direct";
    }
    return "?";
}

}  // namespace

Env readEnv() {
    Env e;
    e.os = osRelease();
    struct utsname u;
    if (::uname(&u) == 0) {
        e.arch = u.machine;
        e.kernel = u.release;
    }
    e.desktop = env("XDG_CURRENT_DESKTOP");
    e.sessionType = env("XDG_SESSION_TYPE");
    e.waylandDisplay = !env("WAYLAND_DISPLAY").empty();
    e.x11Display = !env("DISPLAY").empty();
    e.locale = env("LC_ALL");
    if (e.locale.empty()) e.locale = env("LC_CTYPE");
    if (e.locale.empty()) e.locale = env("LANG");
    // Which package manager owns the frontends (binary package names of linux/packaging/).
    // .deb is the only package that installs the engine under the Debian multiarch dir
    // (debian/libviettelex-core.install: usr/lib/*/viettelex). Don't read /var/lib/dpkg:
    // lintian fails the build on uses-dpkg-database-directly.
    bool deb = exists("/usr/lib/x86_64-linux-gnu/viettelex/libtelexcore.so") ||
               exists("/usr/lib/aarch64-linux-gnu/viettelex/libtelexcore.so");
    bool packaged = deb || exists("/usr/lib/viettelex/libtelexcore.so") || exists("/usr/lib64/viettelex/libtelexcore.so");
    if (deb) e.install = "deb";
    else if (packaged && hasEntryWithPrefix("/var/lib/pacman/local", "viettelex")) e.install = "pacman";
    else if (packaged && exists("/var/lib/rpm")) e.install = "rpm";
    else e.install = packaged ? "package" : "source";
    return e;
}

std::string settingsLine(const Settings &s) {
    std::string o = "settings: method=";
    o += s.vni ? "vni" : (s.simpleTelex ? "telex-simple" : "telex");
    o += std::string(" free=") + b(s.freeMarking) + " modern=" + b(s.modernTone) + " quick=" + b(s.quickTelex) +
         " spell=" + b(s.spellCheck) + " restore=" + b(s.autoRestore) + " teen=" + b(s.teencode) + " hat=" + b(s.autoCircumflex) +
         " ctxEn=" + b(s.contextualEnglish) + " retroEn=" + b(s.retroactiveEnglish) +
         " freqEn=" + b(s.englishByFrequency) + " collVN=" + b(s.collisionPrefersVietnamese) +
         " bracket=" + b(s.bracketVowels) + " reEdit=" + b(s.reEditWord);
    o += std::string(" | display=") + modeName(s.displayMode) + " underline=" + b(s.preeditUnderline) +
         " redMisspelled=" + b(s.underlineMisspelled) + " termDirect=" + b(s.terminalDirect) + " ctrlCommit=" + b(s.ctrlCommitsWord) +
         " perApp=" + b(s.perAppState) + " sound=" + b(s.switchSound) + " defVi=" + b(s.defaultVietnamese) + " ui=" + s.uiLanguage +
         " noUnderline=" + (s.noUnderline == NoUnderline::ForwardKeys ? "forward-keys" : "off");
    o += std::string(" | auto: dblSpace=") + b(s.doubleSpacePeriod) + " caps=" + b(s.autoCapitalize) +
         " smartPunct=" + b(s.smartPunctuation) + " predict=" + b(s.wordPrediction) +
         " | hints: math=" + b(s.mathResults) + " number=" + b(s.numberChips) + " typo=" + b(s.typoHints) +
         " tone=" + b(s.toneHints) + " date=" + b(s.dateHints) + " tools=" + b(s.textToolsMenu) +
         " addTonesKey=" + b(!s.addTonesHotkey.empty());
    // Counts only: shortcut triggers/expansions are user content.
    o += " | shortcuts=" + std::string(s.shortcutsEnabled ? "on:" : "off:") +
         std::to_string(s.shortcuts ? s.shortcuts->size() : 0) + " appModes=" + std::to_string(s.appModes.size());
    return o;
}

std::vector<std::string> headerLines(const std::string &version, const Frontend &fe, const Env &env,
                                     const Settings &s) {
    std::vector<std::string> h;
    h.push_back("=== VietTelex Linux " + version + " debug log — " + fe.name + " " + orQ(fe.version));
    h.push_back("os: " + orQ(env.os) + " | " + orQ(env.arch) + " | kernel " + orQ(env.kernel) +
                " | install " + orQ(env.install));
    std::string session = orQ(env.sessionType);
    session += std::string(" (wayland=") + b(env.waylandDisplay) + " x11=" + b(env.x11Display) + ")";
    h.push_back("desktop: " + orQ(env.desktop) + " | session " + session +
                (fe.gnomeShell > 0 ? " | gnome-shell " + std::to_string(fe.gnomeShell) : std::string()));
    h.push_back("locale: " + orQ(env.locale) + " | layouts: " + orQ(fe.layouts));
    h.push_back(settingsLine(s));
    return h;
}

std::vector<std::string> Collapser::push(const std::string &line) {
    if (line == last_) {
        ++repeats_;
        return {};
    }
    std::vector<std::string> out = flush();
    out.push_back(line);
    last_ = line;
    return out;
}

std::vector<std::string> Collapser::flush() {
    if (repeats_ == 0) return {};
    std::vector<std::string> out{"  ×" + std::to_string(repeats_ + 1)};
    repeats_ = 0;
    last_.clear();
    return out;
}

void Logger::context(const std::string &version, const Frontend &fe, const Settings &s) {
    if (!headerDone_) {
        headerDone_ = true;
        lastSettings_ = settingsLine(s);
        out(collapse_.flush());
        out(headerLines(version, fe, readEnv(), s));
        return;
    }
    std::string now = settingsLine(s);
    if (now == lastSettings_) return;
    lastSettings_ = now;
    line(now);
}

void Logger::line(const std::string &l) { out(collapse_.push(l)); }

void Logger::out(const std::vector<std::string> &ls) {
    for (const auto &l : ls) sink_("vt " + l);
}

}  // namespace viettelex::debuglog
