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
        // didSet does not fire on init assignment, so these read the stored value
        // without writing it back. (See the property docs below.)
        tapModifyEventInPlace = (defaults.object(forKey: "tapModifyEventInPlace") as? Bool) ?? true
        tapSkipSyntheticKeyUp = (defaults.object(forKey: "tapSkipSyntheticKeyUp") as? Bool) ?? true
        axSelectionReplace = (defaults.object(forKey: "axSelectionReplace") as? Bool) ?? false
        tapCascadeBreaker = (defaults.object(forKey: "tapCascadeBreaker") as? Bool) ?? true
        debugLogging = (defaults.object(forKey: "debugLogging") as? Bool) ?? false
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

    /// Task B1 — tap modify-event-in-place. When a tone edit is a pure single-char
    /// insert (0 backspaces) in Backspace-emit mode and no synthetic burst is draining,
    /// the tap rewrites the physical CGEvent's unicode string and lets it pass instead
    /// of suppressing it and posting 2 synthetic events — real keycode/timing kept,
    /// zero window-server round trips. Default ON. Cached stored var (per-key hot path,
    /// no defaults hit); the didSet persists a Settings-toggle change immediately, so it
    /// takes effect live on the next keystroke.
    var tapModifyEventInPlace: Bool {
        didSet { defaults.set(tapModifyEventInPlace, forKey: "tapModifyEventInPlace") }
    }

    /// Task B2 — skip the synthetic keyUp on unicode inserts. Posts only the keyDown
    /// carrying the unicode string, halving posted events per insert to shave terminal
    /// typing latency. Ships ON; the toggle is a kill switch. Safe for the in-flight
    /// accounting: the tap mask is keyDown-only and the counter tracks downs only, so a
    /// dropped up never unbalances it. Cached stored var; didSet persists live.
    var tapSkipSyntheticKeyUp: Bool {
        didSet { defaults.set(tapSkipSyntheticKeyUp, forKey: "tapSkipSyntheticKeyUp") }
    }

    /// D1 — AX selection-replace. For Chromium/Spotlight tone edits (`.selection` emit
    /// mode) collapse the Shift+Left ×N select + overtype burst — 2(N+1) posted events,
    /// ~3ms each — into ONE Accessibility text edit on the focused element. Default OFF:
    /// it runs a synchronous cross-process AX call INSIDE the tap callback, i.e. new
    /// hang surface, and it shipped right after a keyboard-hang fix — so it stays opt-in
    /// (Settings → Advanced) until proven not to stall the callback in the field. When
    /// on it only fires with the synthetic queue drained (the AX write mutates the field
    /// immediately while native keys already past the tap can't be tracked — the
    /// "nuwax"→"nuẵ" reorder class) and any AX failure falls back to the posted-events
    /// path. Cached stored var (hot path, no defaults hit); didSet persists live.
    var axSelectionReplace: Bool {
        didSet { defaults.set(axSelectionReplace, forKey: "axSelectionReplace") }
    }

    /// Layer 3 — cascade circuit breaker. Kill switch (default ON) for the runaway
    /// guard in SyntheticKeyboard: if the tap posts more key events than any human
    /// could in a short window (> ~256 within 500ms), synthetic self-recognition has
    /// failed and our own events are storming back through handle() — the dead-keyboard
    /// hang. The breaker stops emitting, resets the engine, and disables the tap so keys
    /// pass through NATIVELY (Vietnamese-in-terminal off, but the keyboard is never
    /// dead). ON by default; flip OFF only if it ever misfires:
    ///   defaults write com.viettelex.settings tapCascadeBreaker -bool false
    /// Cached stored var (hot path, no defaults hit); didSet persists live.
    var tapCascadeBreaker: Bool {
        didSet { defaults.set(tapCascadeBreaker, forKey: "tapCascadeBreaker") }
    }

    /// Debug logging (default OFF). Gates the in-memory `DebugLog` ring buffer of tap
    /// health events (create/teardown, breaker trips, emit counts — never typed text),
    /// which the user copies from Settings → Thử Nghiệm to share when reporting a hang.
    /// Off = `DebugLog.log` early-returns, so it costs nothing on the hot path.
    var debugLogging: Bool {
        didSet { defaults.set(debugLogging, forKey: "debugLogging") }
    }

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
