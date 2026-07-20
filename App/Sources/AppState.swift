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

    /// Guards every mutable cache + flag below. Needed since the event tap moved to
    /// its own thread: Settings/controller write on MAIN while the tap callback reads
    /// on the TAP thread (usesTapMode/usesSelectionReplace/shortcuts/flags are on its
    /// per-key path). NSLock (non-recursive!) — public methods lock ONCE and call only
    /// unlocked `_helpers` inside; never call another locked member while holding it.
    /// Uncontended cost is tens of ns, invisible next to the ~ms XPC/event round trips.
    private let lock = NSLock()

    private enum Key {
        static let autoRestore = "autoRestore"
        static let freeMarking = "freeMarking"
        static let modernOrthography = "modernOrthography"
        static let liveSpellCheck = "liveSpellCheck"
        static let simpleTelex = "simpleTelex"
        static let shortcuts = "shortcuts"
        static let fallbackApps = "fallbackApps"      // learned: ignore replacementRange
        static let probedApps = "probedApps"          // learned: verified good
        static let manualModes = "manualAppModes"     // user override: bundleID -> AppMode
    }

    /// A user-forced per-app handling strategy (Settings → Bảng chế độ gõ). Overrides
    /// the learned/probed classification entirely. `.auto` = no override (probe
    /// decides). All 5 typing strategies are selectable; the three tap-family modes
    /// (`tap`, `selection`, `emptyReset`) need Accessibility and fall back to marked
    /// text without it (never silently to in-place — that loses diacritics).
    enum AppMode: String, CaseIterable {
        case auto, inPlace, marked, tap, selection, emptyReset
    }

    // In-memory caches (loaded once). All guarded by `lock` (see above).
    private var shortcutsCache: [String: String]
    private var fallbackAppsCache: Set<String>
    private var probedAppsCache: Set<String>
    private var manualModesCache: [String: String]

    /// Bundle id of the frontmost client, set in activateServer. MAIN-thread only
    /// (IMKit lifecycle + controller + Settings) — the tap thread uses
    /// FrontmostApp.shared.bundleID instead, so this needs no lock.
    var currentBundleID: String?

    // Defaults keys from the old VI/EN enable-disable + hotkey design, no longer read.
    // Removed once on launch so they don't linger in the settings suite.
    private static let legacyKeys = [
        "globalDefault", "perApp", "alwaysOffApps", "hotkeyKeyCode", "hotkeyModifiers",
    ]

    private init() {
        tapNativeFastPath = (defaults.object(forKey: "tapNativeFastPath") as? Bool) ?? true
        _tapModifyEventInPlace = (defaults.object(forKey: "tapModifyEventInPlace") as? Bool) ?? true
        _tapSkipSyntheticKeyUp = (defaults.object(forKey: "tapSkipSyntheticKeyUp") as? Bool) ?? true
        _axSelectionReplace = (defaults.object(forKey: "axSelectionReplace") as? Bool) ?? false
        _tapCascadeBreaker = (defaults.object(forKey: "tapCascadeBreaker") as? Bool) ?? true
        _debugLogging = (defaults.object(forKey: "debugLogging") as? Bool) ?? false
        shortcutsCache = (defaults.dictionary(forKey: Key.shortcuts) as? [String: String]) ?? [:]
        fallbackAppsCache = Set(defaults.stringArray(forKey: Key.fallbackApps) ?? [])
        probedAppsCache = Set(defaults.stringArray(forKey: Key.probedApps) ?? [])
        manualModesCache = (defaults.dictionary(forKey: Key.manualModes) as? [String: String]) ?? [:]
        for key in Self.legacyKeys { defaults.removeObject(forKey: key) }

        // Probe-rule v2 migration (one-time): probedApps learned under the old
        // single-confirmation rule can hold constant-caret false positives — Lark
        // was locked to the broken in-place path exactly this way. Clear the whole
        // learned in-place set; apps re-confirm cheaply (and more strictly) under
        // the two-distinct-offsets rule. fallbackApps is kept: appended verdicts
        // were positive failure evidence and remain trustworthy.
        if !defaults.bool(forKey: "probeV2Reset") {
            probedAppsCache = []
            defaults.removeObject(forKey: Key.probedApps)
            defaults.set(true, forKey: "probeV2Reset")
        }
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
    /// zero window-server round trips. Default ON. Cached in-memory (per-key hot path,
    /// no defaults hit); the setter persists a Settings-toggle change immediately, so it
    /// takes effect live on the next keystroke. Locked: Settings writes on main, the
    /// tap thread reads per key.
    private var _tapModifyEventInPlace: Bool
    var tapModifyEventInPlace: Bool {
        get { lock.withLock { _tapModifyEventInPlace } }
        set { lock.withLock { _tapModifyEventInPlace = newValue }
              defaults.set(newValue, forKey: "tapModifyEventInPlace") }
    }

    /// Task B2 — skip the synthetic keyUp on unicode inserts. Posts only the keyDown
    /// carrying the unicode string, halving posted events per insert to shave terminal
    /// typing latency. Ships ON; the toggle is a kill switch. Safe for the in-flight
    /// accounting: the tap mask is keyDown-only and the counter tracks downs only, so a
    /// dropped up never unbalances it. Locked cache; setter persists live.
    private var _tapSkipSyntheticKeyUp: Bool
    var tapSkipSyntheticKeyUp: Bool {
        get { lock.withLock { _tapSkipSyntheticKeyUp } }
        set { lock.withLock { _tapSkipSyntheticKeyUp = newValue }
              defaults.set(newValue, forKey: "tapSkipSyntheticKeyUp") }
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
    private var _axSelectionReplace: Bool
    var axSelectionReplace: Bool {
        get { lock.withLock { _axSelectionReplace } }
        set { lock.withLock { _axSelectionReplace = newValue }
              defaults.set(newValue, forKey: "axSelectionReplace") }
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
    private var _tapCascadeBreaker: Bool
    var tapCascadeBreaker: Bool {
        get { lock.withLock { _tapCascadeBreaker } }
        set { lock.withLock { _tapCascadeBreaker = newValue }
              defaults.set(newValue, forKey: "tapCascadeBreaker") }
    }

    /// Debug logging (default OFF). Gates the in-memory `DebugLog` ring buffer of tap
    /// health events (create/teardown, breaker trips, emit counts — never typed text),
    /// which the user copies from Settings → Thử Nghiệm to share when reporting a hang.
    /// Off = `DebugLog.log` early-returns, so it costs nothing on the hot path.
    private var _debugLogging: Bool
    var debugLogging: Bool {
        get { lock.withLock { _debugLogging } }
        set { lock.withLock { _debugLogging = newValue }
              defaults.set(newValue, forKey: "debugLogging") }
    }

    // MARK: - Shortcuts (bảng gõ tắt)

    /// Read-only snapshot used at word boundaries (no disk hit).
    var shortcuts: [String: String] { lock.withLock { shortcutsCache } }

    func setShortcuts(_ dict: [String: String]) {
        lock.withLock { shortcutsCache = dict }
        defaults.set(dict, forKey: Key.shortcuts)
    }

    func upsertShortcut(key: String, value: String) {
        guard !key.isEmpty else { return }
        let snapshot = lock.withLock { shortcutsCache[key] = value; return shortcutsCache }
        defaults.set(snapshot, forKey: Key.shortcuts)
    }

    func removeShortcut(key: String) {
        let snapshot = lock.withLock { shortcutsCache.removeValue(forKey: key); return shortcutsCache }
        defaults.set(snapshot, forKey: Key.shortcuts)
    }

    // MARK: - Learned typing strategy (in-place replacementRange vs marked text)

    /// Apps where the in-place replacementRange path is known-broken but the learned
    /// probe can't be trusted to catch it. Two failure classes:
    ///
    ///  • Terminals (Terminal.app, iTerm2) — the CANONICAL fallback apps: they ignore
    ///    in-place `replacementRange` entirely, so they MUST run tap backspace-retype
    ///    (or marked text). They used to rely purely on the learned `fallbackAppsCache`,
    ///    but that cache is per-install UserDefaults: a reinstall/upgrade wipes it, and
    ///    until the app is re-probed (and iff the probe fails, which it doesn't always —
    ///    iTerm2 implements IMKit text input for CJK and can echo the read-back, so
    ///    `probeInPlace` false-positives and locks it to the broken in-place path) the
    ///    user silently loses Vietnamese in their terminal. Terminal support is a core
    ///    promise, so it is built in, never left to the probe.
    ///
    ///  • WhatsApp — a Mac Catalyst app: returns a valid caret (never falls back on a
    ///    NotFound selectedRange) AND echoes inserted text on read-back (so the probe
    ///    false-positives), yet ignores `replacementRange` so diacritics never render.
    ///
    /// TextMate has the same in-place breakage in practice. All force off in-place: →
    /// tap backspace-retype when Accessibility is granted, else marked text. Never probed.
    static let builtInFallbackApps: Set<String> = [
        "net.whatsapp.WhatsApp",
        "com.apple.Terminal",     // Terminal.app
        "com.googlecode.iterm2",  // iTerm2
        "com.macromates.TextMate",// TextMate
        // Lark is NOT pinned any more. The deferred-reprobe experiment (2026-07-21)
        // showed its probe signals aren't smart fakes but a CONSTANT garbage caret
        // (always 1) with no AX text interface at all — the old single-probe rule
        // locked it in-place only when the first tone edit happened at the start of
        // an empty field (expReplace = 1 = the garbage value). The two-distinct-
        // offsets rule (InPlaceProbe.HonorTracker) makes that coincidence unable to
        // commit, so the normal probe now classifies Lark: appended ×2 → fallback
        // (tap with Accessibility, marked text without).
    ]

    /// Apps FORCED to marked-text — never in-place, and never tap (even with
    /// Accessibility). For apps whose in-place is broken AND whose probe signals can't
    /// be trusted (Lark reports a caret at start+len and/or echoes the read-back, so
    /// auto-detection coincidentally locks it to a broken in-place path), but where
    /// tap backspace-retype is more invasive than we want. Marked text renders the
    /// composition via the app's own IME display, independent of its caret coordinates.
    /// If an app here turns out not to draw marked text, move it to builtInFallbackApps
    /// (→ tap) instead.
    static let markedTextApps: Set<String> = [
    ]

    // MARK: - Manual per-app mode override (Experimental → App mode)

    /// Unlocked core of manualMode — call ONLY while holding `lock`.
    private func _manualMode(_ id: String) -> AppMode? {
        guard let raw = manualModesCache[id],
              let m = AppMode(rawValue: raw), m != .auto else { return nil }
        return m
    }

    /// The user-forced mode for `bundleID`, or nil when set to auto / unset.
    func manualMode(_ bundleID: String?) -> AppMode? {
        guard let id = bundleID else { return nil }
        return lock.withLock { _manualMode(id) }
    }
    func setManualMode(_ mode: AppMode, for bundleID: String) {
        let snapshot: [String: String] = lock.withLock {
            if mode == .auto { manualModesCache[bundleID] = nil }
            else { manualModesCache[bundleID] = mode.rawValue }
            return manualModesCache
        }
        defaults.set(snapshot, forKey: Key.manualModes)
    }
    var manualModes: [String: String] { lock.withLock { manualModesCache } }

    /// True if this app already has a fixed (non-auto) mode — a manual override OR a
    /// built-in pin. Used to hide already-configured apps from the "recent apps" picker.
    func isModeConfigured(_ bundleID: String?) -> Bool {
        guard let id = bundleID else { return false }
        return lock.withLock { _manualMode(id) != nil }
            || Self.builtInFallbackApps.contains(id) || Self.markedTextApps.contains(id)
    }

    /// This client ignores in-place replacementRange (e.g. Terminal) -> use marked text.
    func usesMarkedText(_ bundleID: String?) -> Bool {
        guard let id = bundleID else { return false }
        let trusted = Accessibility.isTrusted   // own lock — read BEFORE ours, never nested
        return lock.withLock {
            if let m = _manualMode(id) {         // user override wins
                switch m {
                case .marked: return true
                // Tap-family override without Accessibility: marked text is the safe
                // degradation (in-place would silently drop diacritics on an app the
                // user explicitly said is broken).
                case .tap, .selection, .emptyReset: return !trusted
                case .inPlace, .auto: return false
                }
            }
            return fallbackAppsCache.contains(id) || Self.builtInFallbackApps.contains(id)
                || Self.markedTextApps.contains(id)
        }
    }

    /// Terminal tap-mode: an app that ignores replacementRange (would otherwise get
    /// marked text) gets full CGEvent backspace-retype instead, but only when the
    /// process is Accessibility-trusted (Developer ID build). The sandboxed Mac App
    /// Store build can never be trusted, so it transparently stays on marked text.
    /// markedTextApps are excluded: they must stay on marked text even when trusted.
    func usesTapMode(_ bundleID: String?) -> Bool {
        guard let id = bundleID else { return false }
        // Membership under our lock; Accessibility.isTrusted OUTSIDE it (it has its
        // own lock — never nest them).
        enum Wants { case tap, no, fallback }
        let w: Wants = lock.withLock {
            if let m = _manualMode(id) { return m == .tap ? .tap : .no }  // user override wins
            return (fallbackAppsCache.contains(id) || Self.builtInFallbackApps.contains(id))
                && !Self.markedTextApps.contains(id) ? .fallback : .no
        }
        return w != .no && Accessibility.isTrusted
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
        let wants: Bool = lock.withLock {
            if let m = _manualMode(id) { return m == .selection }   // user override wins
            return Self.selectionApps.contains(id)
        }
        return wants && Accessibility.isTrusted
    }

    /// Office-style empty-character reset before a Backspace-retype (Developer ID only).
    func usesEmptyReset(_ bundleID: String?) -> Bool {
        guard let id = bundleID else { return false }
        let wants: Bool = lock.withLock {
            if let m = _manualMode(id) { return m == .emptyReset }  // user override wins
            return Self.emptyResetApps.contains(id)
        }
        return wants && Accessibility.isTrusted
    }

    /// What Auto currently resolves to for this app — the label shown in the mode
    /// table's "Auto — …" row. Ignores any manual override (that's what the row IS).
    /// nil = not classified yet (probe hasn't seen a real replace here).
    func autoResolvedMode(_ bundleID: String?) -> AppMode? {
        guard let id = bundleID else { return nil }
        let trusted = Accessibility.isTrusted
        return lock.withLock {
            if Self.selectionApps.contains(id) { return trusted ? .selection : .marked }
            if Self.emptyResetApps.contains(id) { return trusted ? .emptyReset : .marked }
            if Self.markedTextApps.contains(id) { return .marked }
            if fallbackAppsCache.contains(id) || Self.builtInFallbackApps.contains(id) {
                return trusted ? .tap : .marked
            }
            if probedAppsCache.contains(id) { return .inPlace }
            return nil
        }
    }

    /// One-shot probe needed: not yet classified either way. Never probe a built-in
    /// fallback app — it's known-broken in-place and would false-positive the probe.
    func needsProbe(_ bundleID: String?) -> Bool {
        guard let id = bundleID else { return false }
        return lock.withLock {
            if _manualMode(id) != nil { return false }   // user pinned it; never probe
            return !fallbackAppsCache.contains(id) && !probedAppsCache.contains(id)
                && !Self.builtInFallbackApps.contains(id) && !Self.markedTextApps.contains(id)
        }
    }

    /// In-place replacement verified working for this app.
    func markInPlaceGood(_ bundleID: String?) {
        guard let id = bundleID else { return }
        guard let snapshot: [String] = lock.withLock({
            guard !probedAppsCache.contains(id) else { return nil }
            probedAppsCache.insert(id)
            return Array(probedAppsCache)
        }) else { return }
        defaults.set(snapshot, forKey: Key.probedApps)
    }

    /// Ground-truth reversal: a deferred AX read proved in-place does NOT work here,
    /// overriding an earlier self-reported honored that may already have committed.
    func unmarkInPlaceGood(_ bundleID: String?) {
        guard let id = bundleID else { return }
        guard let snapshot: [String] = lock.withLock({
            guard probedAppsCache.contains(id) else { return nil }
            probedAppsCache.remove(id)
            return Array(probedAppsCache)
        }) else { return }
        defaults.set(snapshot, forKey: Key.probedApps)
    }

    /// This app must use marked text (in-place replacement doesn't work).
    func markUsesMarkedText(_ bundleID: String?) {
        guard let id = bundleID else { return }
        guard let snapshot: [String] = lock.withLock({
            guard !fallbackAppsCache.contains(id) else { return nil }
            fallbackAppsCache.insert(id)
            return Array(fallbackAppsCache)
        }) else { return }
        defaults.set(snapshot, forKey: Key.fallbackApps)
    }

    /// Learned lists, for the Settings UI (Tương thích ứng dụng).
    var learnedFallbackApps: [String] { lock.withLock { fallbackAppsCache.sorted() } }
    var learnedInPlaceApps: [String] { lock.withLock { probedAppsCache.sorted() } }

    /// Forget everything learned about apps. A bad one-shot probe (app busy during
    /// the read-back) otherwise downgrades an app to marked text forever; this lets
    /// the user re-probe from scratch.
    func resetLearnedApps() {
        lock.withLock {
            fallbackAppsCache = []
            probedAppsCache = []
        }
        defaults.removeObject(forKey: Key.fallbackApps)
        defaults.removeObject(forKey: Key.probedApps)
    }

    /// Would this app type better with Accessibility granted (tap / selection-replace
    /// / empty-reset strategies)? Membership only — ignores the current trust state.
    func wantsAccessibility(_ bundleID: String?) -> Bool {
        guard let id = bundleID else { return false }
        return lock.withLock {
            Self.selectionApps.contains(id) || Self.emptyResetApps.contains(id)
                || fallbackAppsCache.contains(id) || Self.builtInFallbackApps.contains(id)
        }
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
