// AppState.swift
// Single source of truth for settings. UserDefaults-backed, read on the main
// (input) thread. There is no VI/EN enable/disable: Vietnamese is on whenever
// VietTelex is the active macOS input source; the OS drives switching (and its
// per-app input-source memory).

import Foundation

extension Notification.Name {
    /// Posted by the mouse tap on any click: the caret may have moved, so any active
    /// composition must be abandoned.
    static let telexResetComposition = Notification.Name("com.viettelex.resetComposition")
}

final class AppState: @unchecked Sendable {
    static let shared = AppState()

    private let defaults = UserDefaults(suiteName: "com.viettelex.settings") ?? .standard

    private enum Key {
        static let autoRestore = "autoRestore"
        static let freeMarking = "freeMarking"
        static let modernOrthography = "modernOrthography"
        static let liveSpellCheck = "liveSpellCheck"
        static let simpleTelex = "simpleTelex"
        static let shortcuts = "shortcuts"
        static let fallbackApps = "fallbackApps"      // learned: ignore replacementRange
        static let probedApps = "probedApps"          // learned: verified good
    }

    // In-memory caches (loaded once).
    private var shortcutsCache: [String: String]
    private var fallbackAppsCache: Set<String>
    private var probedAppsCache: Set<String>

    /// Bundle id of the frontmost client, set in activateServer.
    var currentBundleID: String?

    // Defaults keys from the old VI/EN enable-disable + hotkey design, no longer read.
    // Removed once on launch so they don't linger in the settings suite.
    private static let legacyKeys = [
        "globalDefault", "perApp", "alwaysOffApps", "hotkeyKeyCode", "hotkeyModifiers",
    ]

    private init() {
        tapNativeFastPath = (defaults.object(forKey: "tapNativeFastPath") as? Bool) ?? true
        shortcutsCache = (defaults.dictionary(forKey: Key.shortcuts) as? [String: String]) ?? [:]
        fallbackAppsCache = Set(defaults.stringArray(forKey: Key.fallbackApps) ?? [])
        probedAppsCache = Set(defaults.stringArray(forKey: Key.probedApps) ?? [])
        for key in Self.legacyKeys { defaults.removeObject(forKey: key) }
    }

    // MARK: - Options
    // No VI/EN enable/disable: Vietnamese is ON whenever VietTelex is the active macOS
    // input source. English = switch input source (macOS remembers it per app).

    /// Auto-restore: at a word boundary, if the composed word is not a valid
    /// Vietnamese syllable (rule-based `SyllableValidator`, no dictionary), revert to
    /// the raw keystrokes — so English/typos come out as typed ("retore"→retỏe→
    /// retore). Default ON. Users who explicitly turned it off keep their choice.
    var autoRestore: Bool {
        get { defaults.object(forKey: Key.autoRestore) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.autoRestore) }
    }

    /// "Bỏ dấu tự do" (free mark placement). When ON, modifier keys
    /// (circumflex aa/ee/oo, breve/horn w) reach back over consonants to the target
    /// vowel: "ama"→âm, "trangw"→trăng. When OFF (default = Minimal Telex / strict),
    /// a modifier only acts on the adjacent vowel, so English/code types cleanly
    /// ("ama"→ama, "trangw"→trangw; type "coot"/"trawng" to get the diacritic).
    var freeMarking: Bool {
        get { defaults.object(forKey: Key.freeMarking) as? Bool ?? false }
        set { defaults.set(newValue, forKey: Key.freeMarking) }
    }

    /// Tone-placement style. false (default) = old style (hòa, thủy); true = modern
    /// (hoà, thuý). See `TelexEngine.modernTone`.
    var modernOrthography: Bool {
        get { defaults.object(forKey: Key.modernOrthography) as? Bool ?? false }
        set { defaults.set(newValue, forKey: Key.modernOrthography) }
    }

    /// Live spell-check: stop transforming a word mid-typing once it can't be valid
    /// Vietnamese (foreign words / URLs). Default ON. See `TelexEngine.liveSpellCheck`.
    var liveSpellCheck: Bool {
        get { defaults.object(forKey: Key.liveSpellCheck) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.liveSpellCheck) }
    }

    /// Simple Telex: a standalone `w` stays literal (type `uw` for ư). Default ON.
    /// See `TelexEngine.simpleTelex`.
    var simpleTelex: Bool {
        get { defaults.object(forKey: Key.simpleTelex) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.simpleTelex) }
    }

    /// UI language override for the Settings window + menu, independent of the
    /// system language: "system" (follow macOS), "en", or "vi". Default "system".
    /// Read by `VTLocalized`.
    var uiLanguage: String {
        get { defaults.string(forKey: "uiLanguage") ?? "system" }
        set { defaults.set(newValue, forKey: "uiLanguage") }
    }

    /// Tap-mode native fast path: non-transforming letters pass through natively
    /// (zero synthetic events) when no synthetic burst is in flight. Default ON.
    /// Kill switch if reordering ever reappears on some setup:
    ///   defaults write com.viettelex.settings tapNativeFastPath -bool false
    /// Read once at launch (per-key hot path).
    let tapNativeFastPath: Bool

    // MARK: - Shortcuts (bảng gõ tắt)

    /// Read-only snapshot used at word boundaries (no disk hit).
    var shortcuts: [String: String] { shortcutsCache }

    func setShortcuts(_ dict: [String: String]) {
        shortcutsCache = dict
        defaults.set(dict, forKey: Key.shortcuts)
    }

    func upsertShortcut(key: String, value: String) {
        guard !key.isEmpty else { return }
        shortcutsCache[key] = value
        defaults.set(shortcutsCache, forKey: Key.shortcuts)
    }

    func removeShortcut(key: String) {
        shortcutsCache.removeValue(forKey: key)
        defaults.set(shortcutsCache, forKey: Key.shortcuts)
    }

    // MARK: - Learned typing strategy (in-place replacementRange vs marked text)

    /// This client ignores in-place replacementRange (e.g. Terminal) -> use marked text.
    func usesMarkedText(_ bundleID: String?) -> Bool {
        guard let id = bundleID else { return false }
        return fallbackAppsCache.contains(id)
    }

    /// Terminal tap-mode: an app that ignores replacementRange (would otherwise get
    /// marked text) gets full CGEvent backspace-retype instead, but only when the
    /// process is Accessibility-trusted (Developer ID build). The sandboxed Mac App
    /// Store build can never be trusted, so it transparently stays on marked text.
    func usesTapMode(_ bundleID: String?) -> Bool {
        guard let id = bundleID else { return false }
        return fallbackAppsCache.contains(id) && Accessibility.isTrusted
    }

    /// Chromium browsers: inline omnibox autocomplete corrupts a Backspace-retype
    /// ("gôgleogle"). Fixed with Shift+Left selection-replace via the tap. Spotlight
    /// gets the same (detected by window list, not bundle id).
    private static let selectionApps: Set<String> = [
        "com.google.Chrome", "com.google.Chrome.canary", "com.google.Chrome.beta",
        "org.chromium.Chromium", "com.brave.Browser", "com.brave.Browser.beta",
        "com.microsoft.edgemac", "com.microsoft.edgemac.Beta", "com.microsoft.Edge",
        "com.vivaldi.Vivaldi", "com.operasoftware.Opera", "company.thebrowser.Browser",
    ]

    /// Excel: cell autocomplete (from column values) races a Backspace-retype
    /// ("Tiếngếng Việt"), but Shift+Left in a cell selects the ADJACENT CELL, not
    /// characters — so it uses the empty-character trick (insert U+202F to cancel the
    /// suggestion, then a normal Backspace-retype).
    /// Only Excel: Word/PowerPoint body text has no inline autocomplete race, so they
    /// stay on the fast IMKit in-place path (routing them through the tap only added
    /// per-key latency → laggy cursor).
    private static let emptyResetApps: Set<String> = [
        "com.microsoft.Excel",
    ]

    /// Chromium/Spotlight-style Shift+Left selection-replace (Developer ID only).
    func usesSelectionReplace(_ bundleID: String?) -> Bool {
        guard let id = bundleID else { return false }
        return Self.selectionApps.contains(id) && Accessibility.isTrusted
    }

    /// Office-style empty-character reset before a Backspace-retype (Developer ID only).
    func usesEmptyReset(_ bundleID: String?) -> Bool {
        guard let id = bundleID else { return false }
        return Self.emptyResetApps.contains(id) && Accessibility.isTrusted
    }

    /// One-shot probe needed: not yet classified either way.
    func needsProbe(_ bundleID: String?) -> Bool {
        guard let id = bundleID else { return false }
        return !fallbackAppsCache.contains(id) && !probedAppsCache.contains(id)
    }

    /// In-place replacement verified working for this app.
    func markInPlaceGood(_ bundleID: String?) {
        guard let id = bundleID, !probedAppsCache.contains(id) else { return }
        probedAppsCache.insert(id)
        defaults.set(Array(probedAppsCache), forKey: Key.probedApps)
    }

    /// This app must use marked text (in-place replacement doesn't work).
    func markUsesMarkedText(_ bundleID: String?) {
        guard let id = bundleID, !fallbackAppsCache.contains(id) else { return }
        fallbackAppsCache.insert(id)
        defaults.set(Array(fallbackAppsCache), forKey: Key.fallbackApps)
    }

    /// Learned lists, for the Settings UI (Tương thích ứng dụng).
    var learnedFallbackApps: [String] { fallbackAppsCache.sorted() }
    var learnedInPlaceApps: [String] { probedAppsCache.sorted() }

    /// Forget everything learned about apps. A bad one-shot probe (app busy during
    /// the read-back) otherwise downgrades an app to marked text forever; this lets
    /// the user re-probe from scratch.
    func resetLearnedApps() {
        fallbackAppsCache = []
        probedAppsCache = []
        defaults.removeObject(forKey: Key.fallbackApps)
        defaults.removeObject(forKey: Key.probedApps)
    }

    /// Would this app type better with Accessibility granted (tap / selection-replace
    /// / empty-reset strategies)? Membership only — ignores the current trust state.
    func wantsAccessibility(_ bundleID: String?) -> Bool {
        guard let id = bundleID else { return false }
        return Self.selectionApps.contains(id) || Self.emptyResetApps.contains(id)
            || fallbackAppsCache.contains(id)
    }

    /// One-time "grant Accessibility" prompt already shown (first focus of an app
    /// that needs the event tap while the permission is missing).
    var axPromptShown: Bool {
        get { defaults.bool(forKey: "axPromptShown") }
        set { defaults.set(newValue, forKey: "axPromptShown") }
    }
}

/// Look up a UI string honoring the user's chosen `AppState.uiLanguage`. Keys are
/// the English source strings (dev region = en); "vi" reads vi.lproj, "en" falls
/// back to the key (= English), "system" uses the system-resolved main bundle.
/// Used by both the SwiftUI Settings window and the AppKit menu/alerts so an
/// explicit language pick applies everywhere, immediately (views re-render via the
/// SettingsModel's @Published language).
func VTLocalized(_ key: String) -> String {
    let lang = AppState.shared.uiLanguage
    if lang != "system",
       let path = Bundle.main.path(forResource: lang, ofType: "lproj"),
       let bundle = Bundle(path: path) {
        return bundle.localizedString(forKey: key, value: key, table: nil)
    }
    return Bundle.main.localizedString(forKey: key, value: key, table: nil)
}
