// AppState.swift
// Single source of truth for settings. UserDefaults-backed, read on the main
// (input) thread. There is no VI/EN enable/disable: Vietnamese is on whenever
// VietTelex is the active macOS input source; the OS drives switching (and its
// per-app input-source memory).

import Foundation
import TelexCore   // ClientPolicy (remote-desktop passthrough class)

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
    /// `.axDetect` resolves per focused FIELD via the Accessibility tree (address
    /// bar → selection-replace, page content → in-place); see FocusedFieldDetector.
    /// `.passthrough` = IME behaves as OFF (remote-desktop class — raw scancodes).
    enum AppMode: String, CaseIterable {
        case auto, inPlace, marked, tap, selection, emptyReset, axDetect, passthrough
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
        // D1 default ON since 2026-07-21 (was opt-in after the v1.2.1 hang scare):
        // field-run for a day with the queueDrained gate + 50ms AX timeout + posted-
        // events fallback and no stalls observed.
        _axSelectionReplace = (defaults.object(forKey: "axSelectionReplace") as? Bool) ?? true
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
        // Default ON since 1.3.1 (user decision 2026-07-21). Users who explicitly
        // turned it off keep their choice (stored value wins).
        get { defaults.object(forKey: Key.freeMarking) as? Bool ?? true }
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

    /// Simple Telex: a standalone `w` stays literal (type `uw` for ư). Default OFF
    /// since 1.3.3 (user decision 2026-07-21 — full Telex incl. word-initial w→ư;
    /// English w-words rely on live spell-check + auto-restore). An explicit user
    /// choice is preserved. See `TelexEngine.simpleTelex`.
    var simpleTelex: Bool {
        get { defaults.object(forKey: Key.simpleTelex) as? Bool ?? false }
        set { defaults.set(newValue, forKey: Key.simpleTelex) }
    }

    /// UI language override for the Settings window + menu, independent of the
    /// system language: "system" (follow macOS), "en", or "vi". Default "system".
    /// Read by `VTLocalized`.
    var uiLanguage: String {
        get { defaults.string(forKey: "uiLanguage") ?? "system" }
        set { defaults.set(newValue, forKey: "uiLanguage") }
    }

    /// Weekly auto update check — OPT-IN, default OFF, preserving the "no network
    /// unless you ask" stance (the toggle IS the ask). Main-thread only.
    var autoUpdateCheck: Bool {
        get { defaults.bool(forKey: "autoUpdateCheck") }
        set { defaults.set(newValue, forKey: "autoUpdateCheck") }
    }
    var lastAutoUpdateCheckAt: Double {
        get { defaults.double(forKey: "lastAutoUpdateCheckAt") }
        set { defaults.set(newValue, forKey: "lastAutoUpdateCheckAt") }
    }
    /// Newest version the user has already been alerted about (never nag twice).
    var lastNotifiedUpdateVersion: String {
        get { defaults.string(forKey: "lastNotifiedUpdateVersion") ?? "" }
        set { defaults.set(newValue, forKey: "lastNotifiedUpdateVersion") }
    }

    /// Show the power-user surface (Bảng chế độ gõ + Thử Nghiệm tabs). Default OFF —
    /// the philosophy is "cài xong là gõ"; per-app strategy names are implementation
    /// vocabulary most users never need. Settings-UI only (main thread), no lock.
    var advancedFeatures: Bool {
        get { defaults.bool(forKey: "advancedFeatures") }
        set { defaults.set(newValue, forKey: "advancedFeatures") }
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
            || Self.builtInInPlaceApps.contains(id)
    }

    /// This client ignores in-place replacementRange (e.g. Terminal) -> use marked text.
    ///
    /// WITHOUT Accessibility the policy is deliberately blunt (decision 2026-07-21,
    /// after field-testing subtler schemes): in-place ONLY for apps positively known
    /// good (probed while trusted, built-in verified list, or a manual In-place pin);
    /// EVERYTHING else — including never-probed apps — is marked text, and no probing
    /// happens (needsProbe is false untrusted). Marked always renders correctly;
    /// "đơn giản, an toàn" beats clever-but-glitchy here.
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
                case .tap, .selection, .emptyReset, .axDetect: return !trusted
                case .inPlace, .auto, .passthrough: return false
                }
            }
            if fallbackAppsCache.contains(id) || Self.builtInFallbackApps.contains(id)
                || Self.markedTextApps.contains(id) { return true }
            if trusted { return false }
            // Untrusted default: marked, unless positively known in-place-good.
            // (Remote-desktop passthrough is resolved in the controller BEFORE this.)
            return !(probedAppsCache.contains(id) || Self.builtInInPlaceApps.contains(id))
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

    // MARK: - Built-in typing-mode rules (typing-modes.plist)
    //
    // The per-app DEFAULTS ship as data, not code: typing-modes.plist at the repo
    // root is bundled as a resource and attached to every GitHub release —
    // contributors add rules without touching Swift, and its String→String format
    // is exactly what Bảng cơ chế gõ's "Nhập từ plist…" imports, so users can also
    // apply an edited copy locally as manual pins. The field lore that used to
    // live in comments here (Lark's edge-of-word breakage, Excel's unfixable
    // marked underline, Spotlight on macOS 26, WhatsApp's native rewrite) moved
    // into the plist header where contributors will actually see it.
    // Values are AppMode raw values; unknown values are logged and skipped.
    private static let builtInRules: [String: AppMode] = {
        guard let url = Bundle.main.url(forResource: "typing-modes", withExtension: "plist"),
              let data = try? Data(contentsOf: url),
              let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String]
        else {
            // Missing/corrupt resource: fall back to the CORE PROMISE alone —
            // Vietnamese-in-terminal must survive anything.
            Signposts.log.fault("typing-modes.plist missing/corrupt — terminal-only fallback")
            return ["com.apple.Terminal": .tap, "com.googlecode.iterm2": .tap]
        }
        var out: [String: AppMode] = [:]
        for (id, raw) in dict {
            if let m = AppMode(rawValue: raw), m != .auto { out[id] = m }
            else { Signposts.log.fault("typing-modes.plist: unknown mode for \(id, privacy: .public)") }
        }
        return out
    }()
    private static func builtInIDs(_ mode: AppMode) -> Set<String> {
        Set(builtInRules.compactMap { $0.value == mode ? $0.key : nil })
    }

    static let builtInFallbackApps = builtInIDs(.tap)
    static let builtInInPlaceApps = builtInIDs(.inPlace)
    static let markedTextApps = builtInIDs(.marked)
    private static let selectionApps = builtInIDs(.axDetect)   // per-field browsers
    private static let emptyResetApps = builtInIDs(.emptyReset)
    /// Extends ClientPolicy's compiled-in remote-desktop floor (kept as the safety
    /// net) with plist-declared passthrough apps.
    static let builtInPassthroughApps = builtInIDs(.passthrough)

    /// Terminals proper — byte-pipe apps with their own controller semantics.
    /// Stays in CODE (not the plist): it is behavior classification, not a rule
    /// users should move an app in or out of.
    static let terminalApps: Set<String> = [
        "com.apple.Terminal", "com.googlecode.iterm2",
    ]

    /// Chromium/Spotlight-style Shift+Left selection-replace (Developer ID only).
    /// For `.axDetect` apps the answer flips per focused FIELD (address bar yes,
    /// page content no) — resolved OUTSIDE our lock (the detector has its own).
    func usesSelectionReplace(_ bundleID: String?) -> Bool {
        guard let id = bundleID else { return false }
        enum Want { case yes, no, perField }
        let w: Want = lock.withLock {
            if let m = _manualMode(id) {                            // user override wins
                if m == .selection { return .yes }
                if m == .axDetect { return .perField }
                return .no
            }
            return Self.isPerFieldByDefault(id) ? .perField : .no
        }
        switch w {
        case .no: return false
        case .yes: return Accessibility.isTrusted
        case .perField: return Accessibility.isTrusted && FocusedFieldDetector.wantsSelection
        }
    }

    /// Browsers resolve per field BY DEFAULT (no manual pin needed): omnibox/smart
    /// search → selection-replace, page content → in-place. Shipped after the
    /// Safari per-field pilot (2026-07-21) proved the AX field walk in the field.
    private static func isPerFieldByDefault(_ id: String) -> Bool {
        Self.selectionApps.contains(id)
    }

    /// Spotlight's REAL bundle id — IMKit reports it as the client while the overlay
    /// is focused (field-verified in the debug log), so manual modes key off it like
    /// any other app. Only the tap-side DETECTION needs the window scan (the
    /// frontmost app stays whatever is behind the overlay).
    static let spotlightBundleID = "com.apple.Spotlight"

    /// Apps with a built-in special strategy (per-field browsers, forced-marked like
    /// Excel), for the Settings mode table — it lists the installed ones so their
    /// default is visible.
    static var builtInSpecialApps: Set<String> {
        selectionApps.union(emptyResetApps).union(markedTextApps)
            .union(builtInPassthroughApps)
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

    /// What Auto WANTS for this app — the IDEAL mode, independent of the current
    /// Accessibility state. Shown in the mode table's "Detected" column; the UI adds
    /// a "missing permission" suffix when the mode needs AX and it isn't granted
    /// (showing the degraded mode instead proved misleading: Chrome displayed
    /// "chưa dò" and Spotlight looked "locked to tap" whenever AX was off).
    /// nil = not classified yet (probe hasn't seen a real replace here).
    func autoResolvedMode(_ bundleID: String?) -> AppMode? {
        guard let id = bundleID else { return nil }
        if ClientPolicy.isRemoteDesktop(id) || Self.builtInPassthroughApps.contains(id) { return .passthrough }
        return lock.withLock {
            if Self.isPerFieldByDefault(id) { return .axDetect }
            if Self.emptyResetApps.contains(id) { return .emptyReset }
            if Self.markedTextApps.contains(id) { return .marked }
            if fallbackAppsCache.contains(id) || Self.builtInFallbackApps.contains(id) {
                return .tap
            }
            if probedAppsCache.contains(id) || Self.builtInInPlaceApps.contains(id) { return .inPlace }
            return nil
        }
    }

    /// One-shot probe needed: not yet classified either way. Never probe a built-in
    /// fallback app — it's known-broken in-place and would false-positive the probe.
    func needsProbe(_ bundleID: String?) -> Bool {
        guard let id = bundleID else { return false }
        // No probing while untrusted: the untrusted default is marked text (which
        // needs no verification), and a probe would require the in-place trial we
        // just decided not to risk.
        guard Accessibility.isTrusted else { return false }
        return lock.withLock {
            if _manualMode(id) != nil { return false }   // user pinned it; never probe
            return !fallbackAppsCache.contains(id) && !probedAppsCache.contains(id)
                && !Self.builtInFallbackApps.contains(id) && !Self.markedTextApps.contains(id)
                && !Self.builtInInPlaceApps.contains(id) // verified good — skip the probe
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

    /// Forget ALL user data for ONE app: the manual pin and any learned
    /// classification — the row's built-in default (if any) takes over again.
    func forgetApp(_ id: String) {
        setManualMode(.auto, for: id)
        let snapshots: (fb: [String]?, pr: [String]?) = lock.withLock {
            var f: [String]? = nil, p: [String]? = nil
            if fallbackAppsCache.remove(id) != nil { f = Array(fallbackAppsCache) }
            if probedAppsCache.remove(id) != nil { p = Array(probedAppsCache) }
            return (f, p)
        }
        if let f = snapshots.fb { defaults.set(f, forKey: Key.fallbackApps) }
        if let p = snapshots.pr { defaults.set(p, forKey: Key.probedApps) }
    }

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


/// Universal shortcut-table parser: accepts every format users bring from other
/// IMEs (field request 2026-07-22) — plist/XML, JSON, flat YAML ("key: value"),
/// and the GõNhanh/EVKey text style ("key:value", ";" or "#" comments). Returns
/// nil when nothing parseable is found.
enum ShortcutImporter {
    static func parse(_ data: Data) -> [String: String]? {
        // 1. plist (our own export format; also covers generic XML dictionaries)
        if let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String],
           !dict.isEmpty {
            return dict
        }
        // 2. JSON object of strings
        if let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String],
           !dict.isEmpty {
            return dict
        }
        // 3. Line-based: GõNhanh txt ("key:value", ";" comments) and flat YAML
        //    ("key: value", "#" comments). One entry per line, first ":" splits.
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        var out: [String: String] = [:]
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix(";") || line.hasPrefix("#") || line.hasPrefix("//") { continue }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            var value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            // YAML niceties: strip a matching pair of quotes
            if value.count >= 2,
               (value.hasPrefix("\"") && value.hasSuffix("\"")) || (value.hasPrefix("'") && value.hasSuffix("'")) {
                value = String(value.dropFirst().dropLast())
            }
            guard !key.isEmpty, !value.isEmpty, key.count <= 32 else { continue }
            out[key] = value
        }
        return out.isEmpty ? nil : out
    }
}
