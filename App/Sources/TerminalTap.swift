// TerminalTap.swift
// Terminal (tap) mode: apps that ignore insertText replacementRange (iTerm,
// Terminal.app…) can't be edited in place, and marked-text holds each keystroke in
// a composition buffer so the shell never sees partial input — autocomplete /
// zsh-autosuggestions die. Worse, such apps also don't honor IMKit's return-true
// suppression without a marked-text op, so an input method literally cannot stop the
// raw key.
//
// So for terminals we bypass IMKit entirely: a CGEventTap
// intercepts the physical key BEFORE the terminal sees it, and we either let it
// through (plain letters — shell sees them live, autocomplete works) or SUPPRESS it
// (return nil) and synthesize real Backspace + Unicode to apply a tone edit. Needs
// Accessibility to create the tap and post events, so it only runs on the
// non-sandboxed Developer ID build; the sandboxed Mac App Store build can't get the
// permission and terminals fall back to marked text.
//
// Re-entrancy: events we post travel back through the same tap and the IME. They are
// stamped via the event SOURCE's userData (kCGEventSourceUserData) — the per-event
// field does NOT survive posting; the source's value does — and passed straight
// through so they never re-drive the engine (that was a 9× Backspace cascade bug).

import Cocoa
import Carbon.HIToolbox
import ApplicationServices
import TelexCore

enum Accessibility {
    // AXIsProcessTrusted() is an out-of-process TCC check; in Chromium apps it was
    // hit up to twice per keystroke (usesSelectionReplace on the hot path). Cache
    // with a short TTL — a grant/revoke shows up within ttlNs, and requestIfNeeded
    // invalidates immediately after prompting.
    // Locked: read on BOTH the main thread (controller/Settings) and the tap thread.
    private static let lock = NSLock()
    private static var cached = false
    private static var lastCheckNs: UInt64 = 0
    // 5s. History: 2s → 500ms during the revoke-wedge hunt (the cache gates
    // synthetic-event posting), then BACK UP once the real protections landed —
    // the com.apple.accessibility.api observer invalidates this cache the moment
    // the permission changes, and the 3s watchdog force-checks fresh. A short TTL
    // here was pure cost: the expiry lands ON the keystroke path, so typing paid
    // a ~10-15ms TCC IPC spike every 500ms for correctness the observer already
    // provides.
    private static let ttlNs: UInt64 = 5_000_000_000

    #if DEBUG
    /// Test-only override for the TCC answer — unit tests can't grant real
    /// Accessibility, and the routing matrix (AppState) must be exercised in BOTH
    /// trust states. nil = ask TCC as normal. Debug builds only; the Release binary
    /// has no override path.
    static var testTrustOverride: Bool?
    #endif

    /// True when the process may create an event tap / post events. Always false in
    /// the sandboxed build — it can never be granted.
    static var isTrusted: Bool {
        #if DEBUG
        if let forced = testTrustOverride { return forced }
        #endif
        let now = DispatchTime.now().uptimeNanoseconds
        let fresh: Bool? = lock.withLock {
            (lastCheckNs != 0 && now &- lastCheckNs < ttlNs) ? cached : nil
        }
        if let fresh { return fresh }
        // TCC check OUTSIDE the lock (out-of-process call; a concurrent duplicate
        // check is harmless, a blocked lock on the key path is not).
        let trusted = AXIsProcessTrusted()
        lock.withLock {
            cached = trusted
            lastCheckNs = now
        }
        return trusted
    }

    static func invalidateCache() { lock.withLock { lastCheckNs = 0 } }

    /// Prompt for Accessibility permission (opens System Settings). Safe when already
    /// trusted (returns true, no prompt).
    @discardableResult
    static func requestIfNeeded() -> Bool {
        invalidateCache()
        if AXIsProcessTrusted() { return true }
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }
}

/// Cached frontmost-app bundle id. `NSWorkspace.shared.frontmostApplication` is an
/// XPC round-trip and was being called on EVERY keystroke in both the tap callback
/// (where slowness trips tapDisabledByTimeout) and the IMKit controller. App
/// activation is an event, not a per-key question — observe it once and read a
/// plain property on the hot path. All access is on the main thread (the tap's run
/// loop source and NSWorkspace notifications both live there).
final class FrontmostApp {
    static let shared = FrontmostApp()

    /// Locked: written by the NSWorkspace observer on MAIN, read per-key on the TAP
    /// thread (and by the controller on main).
    private let lock = NSLock()
    private var _bundleID: String?
    var bundleID: String? { lock.withLock { _bundleID } }

    /// Most-recently-activated apps (newest first, distinct), EXCLUDING VietTelex
    /// itself — so Settings can offer "recent apps" to pin without typing a bundle id.
    /// MAIN-thread only (observer writes, Settings UI reads) — no lock needed.
    private(set) var recent: [(id: String, name: String)] = []
    private static let selfID = "com.viettelex.inputmethod.telex"

    private init() {
        _bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard let self else { return }
            self.lock.withLock { self._bundleID = app?.bundleIdentifier }
            guard let id = app?.bundleIdentifier, id != Self.selfID else { return }
            self.recent.removeAll { $0.id == id }
            self.recent.insert((id, app?.localizedName ?? id), at: 0)
            if self.recent.count > 10 { self.recent.removeLast() }
        }
    }
}

/// Spotlight is a system overlay, not the frontmost APP — its bundle id never shows
/// up in NSWorkspace.frontmostApplication. Detect it by scanning the
/// on-screen window list for a window owned by the "Spotlight" process.
enum SpotlightDetector {
    // CGWindowListCopyWindowInfo enumerates every on-screen window — too heavy to run
    // on the keystroke path (it slowed the tap callback enough to trip
    // tapDisabledByTimeout, leaking keys to the broken IMKit path → intermittent
    // garbage). Cache the result with a short TTL; Spotlight visibility doesn't change
    // per keystroke, so a ~200ms lag is invisible.
    //
    // The scan NEVER runs synchronously on the keystroke: isVisible always returns the
    // cached bool immediately, and when the TTL has expired it kicks ONE background
    // refresh (utility queue) whose result lands back on main. So a fresh scan is
    // observed on the NEXT keystroke, not this one — visibility lags at most one key.
    // That is acceptable: Spotlight open/close is a deliberate user action, never
    // simultaneous with typing into it, so being one keystroke stale is invisible while
    // removing a multi-ms spike from the hot path.
    //
    // Threading: read on both the TAP thread (per key) and MAIN (controller), refresh
    // result lands from the utility queue — so the cached bool + timestamp +
    // `refreshing` gate all live under one lock. Only the CGWindowList call itself
    // runs outside it.
    private static let lock = NSLock()
    private static var cached = false
    private static var lastCheckNs: UInt64 = 0
    private static var refreshing = false
    private static let ttlNs: UInt64 = 200_000_000
    private static let scanQueue = DispatchQueue(label: "com.viettelex.spotlight-scan", qos: .utility)

    static var isVisible: Bool {
        let now = DispatchTime.now().uptimeNanoseconds
        let (stale, value): (Bool, Bool) = lock.withLock {
            let needsRefresh = now &- lastCheckNs >= ttlNs && !refreshing
            if needsRefresh { refreshing = true }
            return (needsRefresh, cached)
        }
        if stale {
            scanQueue.async {
                let visible = scan()                       // heavy call, off the hot path
                lock.withLock {
                    cached = visible
                    lastCheckNs = DispatchTime.now().uptimeNanoseconds
                    refreshing = false
                }
            }
        }
        return value
    }

    private static func scan() -> Bool {
        let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windows = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]]
        else { return false }
        for w in windows {
            // WATCH-ITEM: matches the owning process name literally. This is
            // version-sensitive — a macOS release that renames the Spotlight process
            // would silently break detection (Spotlight edits fall back to Backspace
            // mode) with no error. Revisit if Spotlight support regresses on a new OS.
            if let owner = w[kCGWindowOwnerName as String] as? String, owner == "Spotlight" {
                return true
            }
        }
        return false
    }
}

/// Per-FIELD mode resolution for apps pinned to `.axDetect` (Bảng chế độ gõ →
/// "Tự dò theo ô"): a browser's address/search bar needs selection-replace (its
/// inline autocomplete races in-place edits — the Safari smart-search bug), while
/// fields INSIDE the page work best on the fast IMKit in-place path. Distinguish
/// them structurally through the Accessibility tree: walk the focused element's
/// ancestors — hit AXWebArea → page content (in-place); hit AXToolbar → a chrome/
/// toolbar field (selection). Unknown → selection, the mode that works everywhere
/// (same "when unsure, pick what always works" rule as the probe).
///
/// Same threading/caching design as SpotlightDetector: the AX walk (cross-process,
/// 50ms-capped calls) never runs on a keystroke — reads return the cached verdict
/// and kick ONE background refresh when the 200ms TTL lapses, so a focus change is
/// seen at most one keystroke late. Cache + gate live under one lock (read on both
/// the tap thread and main).
enum FocusedFieldDetector {
    private static let lock = NSLock()
    private static var cached = true            // unknown → selection (always works)
    private static var lastCheckNs: UInt64 = 0
    private static var refreshing = false
    private static let ttlNs: UInt64 = 200_000_000
    private static let scanQueue = DispatchQueue(label: "com.viettelex.field-scan", qos: .userInitiated)

    /// True → the focused field should use selection-replace; false → in-place.
    static var wantsSelection: Bool {
        let now = DispatchTime.now().uptimeNanoseconds
        let (stale, value): (Bool, Bool) = lock.withLock {
            let needsRefresh = now &- lastCheckNs >= ttlNs && !refreshing
            if needsRefresh { refreshing = true }
            return (needsRefresh, cached)
        }
        if stale {
            scanQueue.async {
                let wants = scan()
                lock.withLock {
                    cached = wants
                    lastCheckNs = DispatchTime.now().uptimeNanoseconds
                    refreshing = false
                }
            }
        }
        return value
    }

    // MARK: is the focused element a REAL text input? (remote-desktop per-field)
    //
    // Remote-desktop apps forward raw scancodes for the SESSION canvas, but their own
    // chrome (PC-name field, search box) is ordinary Cocoa text input where the IME
    // works fine. Distinguish by the focused element's role. Unknown/unavailable →
    // NOT a text input, i.e. passthrough — misclassifying the canvas as a field would
    // compose garbage into the guest OS, while the reverse merely keeps the status quo
    // (no Vietnamese in a name field).
    private static var cachedTextInput = false
    private static var lastTextCheckNs: UInt64 = 0
    private static var refreshingText = false
    private static let textInputRoles: Set<String> =
        ["AXTextField", "AXTextArea", "AXSearchField", "AXComboBox"]

    static var isTextInput: Bool {
        let now = DispatchTime.now().uptimeNanoseconds
        let (stale, value): (Bool, Bool) = lock.withLock {
            let needsRefresh = now &- lastTextCheckNs >= ttlNs && !refreshingText
            if needsRefresh { refreshingText = true }
            return (needsRefresh, cachedTextInput)
        }
        if stale {
            scanQueue.async {
                let isText = scanTextInput()
                lock.withLock {
                    cachedTextInput = isText
                    lastTextCheckNs = DispatchTime.now().uptimeNanoseconds
                    refreshingText = false
                }
            }
        }
        return value
    }

    private static func scanTextInput() -> Bool {
        guard let element = focusedElementForScan() else { return false }
        var roleRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef) == .success,
              let role = roleRef as? String
        else { return false }
        return textInputRoles.contains(role)
    }

    /// System-wide focused element with the 50ms timeout, or nil (untrusted / no
    /// focus). Shared by both scans.
    private static func focusedElementForScan() -> AXUIElement? {
        guard AXIsProcessTrusted() else { return nil }
        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, 0.05)
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
              let focused = focusedRef, CFGetTypeID(focused) == AXUIElementGetTypeID()
        else { return nil }
        let element = focused as! AXUIElement
        AXUIElementSetMessagingTimeout(element, 0.05)
        return element
    }

    private static func scan() -> Bool {
        guard let focused = focusedElementForScan() else { return true }
        // ROLE rules on the focused element itself (gonhanh's detection matrix):
        // combo boxes and search fields carry inline autocomplete that races a
        // backspace burst, whatever app they live in — selection-replace wins.
        // Checked BEFORE the ancestor walk so a search box inside a web area is
        // still treated as autocomplete-prone.
        var roleRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(focused, kAXRoleAttribute as CFString, &roleRef) == .success,
           let role = roleRef as? String {
            if role == "AXComboBox" { return true }
            if role == "AXTextField" {
                var subRef: CFTypeRef?
                if AXUIElementCopyAttributeValue(focused, kAXSubroleAttribute as CFString, &subRef) == .success,
                   let sub = subRef as? String, sub == "AXSearchField" {
                    return true
                }
            }
        }
        var element = focused
        // Walk up a bounded ancestor chain. 12 hops covers real browser hierarchies
        // (web content sits many groups deep) while still bounding the AX round trips.
        for _ in 0..<12 {
            AXUIElementSetMessagingTimeout(element, 0.05)
            roleRef = nil
            if AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef) == .success,
               let role = roleRef as? String {
                if role == "AXWebArea" { return false }   // page content → in-place
                if role == "AXToolbar" { return true }    // address/search bar → selection
            }
            var parentRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &parentRef) == .success,
                  let parent = parentRef, CFGetTypeID(parent) == AXUIElementGetTypeID()
            else { return true }
            element = parent as! AXUIElement
        }
        return true
    }
}

/// How a tone edit is emitted to the app:
/// - `backspace`: Backspace ×N then type (terminals).
/// - `selection`: Shift+Left ×N to select then overtype (Chromium omnibox / Spotlight
///   — where inline autocomplete offsets a plain Backspace).
/// - `emptyReset`: insert U+202F to cancel the inline suggestion, then Backspace ×(N+1)
///   (delete the U+202F too) and type (MS Office — where Shift+Left would select the
///   adjacent cell instead of characters).
enum TapEmit { case backspace, selection, emptyReset }

/// D1 — replace trailing text via the Accessibility API instead of a posted-event
/// burst. For a Chromium omnibox / Spotlight tone edit the `.selection` path posts
/// Shift+Left ×N then an overtype = 2(N+1) window-server round trips (~3ms each, so
/// ~25ms for a 3-char edit). ONE AX edit — set the selected range to the trailing N
/// chars, then set its text — does the same in a single out-of-process round trip.
///
/// ORDERING: the AX write mutates the field the instant it lands, so native letters
/// that already passed the tap and are still queued in the app can reorder against it
/// (the historical "nuwax"→"nuẵ" class). We can't track keys that already went native,
/// which is exactly why the caller gates this on `queueDrained()` and it sits behind a
/// flag. Within one key it is safe: the tap callback is serial and these AX calls are
/// synchronous, so the edit finishes before we return nil for the current keystroke.
enum AXTextEdit {
    /// Replace the `backspaces` chars before the caret with `text` on the system-wide
    /// focused element. Every AX call is checked — ANY failure returns false so the
    /// caller falls back to the posted-events path; returns true only when BOTH the
    /// range set and the text set succeeded.
    static func replaceTrailing(backspaces: Int, with text: String) -> Bool {
        guard backspaces > 0 else { return false }

        // Focused UI element (system-wide, so it works across app boundaries / overlays
        // like Spotlight).
        let systemWide = AXUIElementCreateSystemWide()
        // 50ms messaging timeout — the DEFAULT is seconds, and this runs inside the
        // tap callback: a busy/hung target would block the callback long enough for
        // macOS to disable the tap (leaked keys). Better to time out fast and fall
        // back to the posted-events path than to stall the tap.
        AXUIElementSetMessagingTimeout(systemWide, 0.05)
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
              let focused = focusedRef, CFGetTypeID(focused) == AXUIElementGetTypeID()
        else { return false }
        let element = focused as! AXUIElement
        AXUIElementSetMessagingTimeout(element, 0.05)   // same 50ms cap (not inherited)

        // Current selection (normally a caret: length 0). Read it as an AXValue wrapping
        // a CFRange so we know the caret location to reach back from.
        var rangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
              let rangeVal = rangeRef, CFGetTypeID(rangeVal) == AXValueGetTypeID()
        else { return false }
        var selected = CFRange(location: 0, length: 0)
        guard AXValueGetValue(rangeVal as! AXValue, .cfRange, &selected) else { return false }

        // Target = the N chars before the caret, plus any existing (non-caret) selection.
        // Guard against underflow: if the caret sits at/inside the first N chars we can't
        // reach back that far — bail so the caller uses the posted-events path.
        guard selected.location >= backspaces else { return false }
        var target = CFRange(location: selected.location - backspaces,
                             length: backspaces + selected.length)
        guard let targetVal = AXValueCreate(.cfRange, &target) else { return false }

        // Select the target range, then overwrite it with `text` — one coherent edit.
        guard AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, targetVal) == .success
        else { return false }
        return AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFString) == .success
    }

    /// Ground-truth read for the in-place probe: the ACTUAL text the focused element
    /// holds at `[start, start+length)`, via the Accessibility tree — a channel
    /// INDEPENDENT of the IMKit read-back (attributedSubstring / selectedRange) that
    /// some apps (Lark) fake or report inconsistently. Returns nil if AX is untrusted
    /// or any read fails, so the caller falls back to the read-back signals. Short 50ms
    /// messaging timeout: this runs on the IMKit key path.
    static func readString(at start: Int, length: Int) -> String? {
        guard start >= 0, length > 0, AXIsProcessTrusted() else { return nil }
        guard let element = focusedElement() else { return nil }
        var range = CFRange(location: start, length: length)
        guard let rangeVal = AXValueCreate(.cfRange, &range) else { return nil }
        var result: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
                element, kAXStringForRangeParameterizedAttribute as CFString, rangeVal, &result) == .success,
              let str = result as? String
        else { return nil }
        return str
    }

    /// Deferred-probe experiment: the focused element's total character count via
    /// kAXNumberOfCharacters. Content-independent append detector — an ignored
    /// replacementRange leaves the field `bs` chars LONGER than a compliant replace
    /// would. Log-only for now (see TelexInputController.reprobeDeferred).
    static func readLength() -> Int? {
        guard AXIsProcessTrusted(), let element = focusedElement() else { return nil }
        var numRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXNumberOfCharactersAttribute as CFString, &numRef) == .success,
              let n = numRef as? Int
        else { return nil }
        return n
    }

    /// System-wide focused element with the 50ms messaging timeout applied (the
    /// DEFAULT is seconds; these calls run on key paths, so a hung target must time
    /// out fast). Shared by the read/write helpers above.
    private static func focusedElement() -> AXUIElement? {
        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, 0.05)
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
              let focused = focusedRef, CFGetTypeID(focused) == AXUIElementGetTypeID()
        else { return nil }
        let element = focused as! AXUIElement
        AXUIElementSetMessagingTimeout(element, 0.05)
        return element
    }
}

enum SyntheticKeyboard {
    /// Stamp identifying events we post. "TLXTAP" packed into an Int64.
    static let magic: Int64 = 0x54_4C_58_54_41_50

    /// Private source with `magic` in its userData. The source's userData is what
    /// shows up as kCGEventSourceUserData on our events after they are posted and
    /// re-delivered — the mechanism the tap/IME use to recognize their own output.
    private static let source: CGEventSource? = {
        let src = CGEventSource(stateID: .privateState)
        src?.userData = magic
        return src
    }()

    /// True if `event` (CGEvent) is one we posted.
    ///
    /// Recognizing our own output is LOAD-BEARING for loop prevention: if it ever
    /// returns false for an event we posted, that event re-enters handle(), is fed to
    /// the engine as a real key, and emits MORE synthetic events → an unbounded storm
    /// that consumes every keystroke (dead keyboard, live mouse — the reported hang).
    /// So we check the ROBUST signal first: the posting process id. CGEvent.post stamps
    /// the emitting process's pid into `.eventSourceUnixProcessID`, and it round-trips
    /// reliably — unlike the source `userData` magic (which the file header notes is
    /// fragile, and which is simply absent if the private `source` failed to build).
    /// Only OUR process posts synthetic keys, so pid == getpid() is exact. The magic
    /// stays as a secondary check (harmless, and cheap belt-and-suspenders).
    static func isSynthetic(_ event: CGEvent) -> Bool {
        if event.getIntegerValueField(.eventSourceUnixProcessID) == Int64(getpid()) { return true }
        return event.getIntegerValueField(.eventSourceUserData) == magic
    }

    /// True if `event` (NSEvent, in IMKit handle()) is one we posted.
    static func isSynthetic(_ event: NSEvent) -> Bool {
        event.cgEvent.map(isSynthetic) ?? false
    }

    /// Health-probe key: keycode 127 (unassigned on Apple keyboards). The watchdog
    /// posts one every tick; the tap callback swallows it and records the arrival.
    /// A probe that never comes back means posts are being DROPPED (Accessibility
    /// grant REMOVED — AXIsProcessTrusted lies true in that state) or the tap is
    /// dead/wedged. No breaker or in-flight bookkeeping: probes are out-of-band.
    static let probeKeycode: Int64 = 90   // kVK_F20 — not on any physical Apple keyboard; keycode 127 gets FILTERED by the OS (never re-enters the tap)
    static func postProbe() {
        guard let src = source else { return }
        guard let ev = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(probeKeycode), keyDown: true) else { return }
        ev.post(tap: .cgSessionEventTap)
    }

    /// IMKit-path recognizer: match ONLY on the private source's `magic` userData,
    /// never the posting pid. Chromium/Electron apps (Slack, Lark) deliver REAL
    /// keydowns to the input method with `eventSourceUnixProcessID == getpid()`, so
    /// the pid-based `isSynthetic` misread them as our own output and dropped them —
    /// Vietnamese became untypable there (raw "vieejt"). Magic is set only by our
    /// source, so a real key never carries it. A false NEGATIVE here is harmless:
    /// our synthetic output only ever targets tap-mode apps, and the controller
    /// defers those to the tap (usesTapMode) before it would ever compose the event.
    /// The pid signal stays PRIMARY in the tap's own cascade guard (`isSynthetic`),
    /// where a synthetic that lost its magic must still be caught to avoid the hang.
    static func isSyntheticMagic(_ event: CGEvent) -> Bool {
        event.getIntegerValueField(.eventSourceUserData) == magic
    }
    static func isSyntheticMagic(_ event: NSEvent) -> Bool {
        event.cgEvent.map(isSyntheticMagic) ?? false
    }

    /// One lock for every mutable static below (stamp, in-flight counter, breaker
    /// window). The posting paths run on the TAP thread; resetBreaker() is called
    /// from MAIN (start/ensureRunning). Uncontended NSLock is tens of ns — noise
    /// next to a window-server post.
    private static let lock = NSLock()

    /// Strictly-increasing timestamp for posted events. CGEvent.post orders delivery
    /// by timestamp, and events we create back-to-back can get equal/near-equal
    /// mach-time stamps — the window server then reorders same-stamp events, so a
    /// later letter overtakes an earlier tone edit ("nuwax" typed fast came out
    /// "nuẵ" = "nuawx"). Stamping each event mach-time-or-last+1 forces FIFO.
    private static var lastStamp: UInt64 = 0
    private static func stamp(_ event: CGEvent) {
        let stampValue: UInt64 = lock.withLock {
            let now = mach_absolute_time()
            lastStamp = now > lastStamp ? now : lastStamp &+ 1
            return lastStamp
        }
        event.timestamp = CGEventTimestamp(stampValue)
    }

    // MARK: In-flight tracking (native fast-path ordering guard)
    //
    // Synthetic keyDowns that were posted but have not yet re-entered the tap.
    // While > 0 a physical key must NOT pass through natively: a native letter
    // delivered ahead of a still-queued synthetic edit reorders the text (the
    // historical "nuwax"→"nuẵ" corruption). Once the queue is drained, plain
    // letters go through natively again — zero synthetic events on the common
    // path. Guarded by `lock` (tap thread posts/observes; main resets).
    private static var inFlightKeyDowns = 0
    private static var lastPostNs: UInt64 = 0

    // MARK: Cascade circuit breaker (Layer 3)
    //
    // Last-resort guard against the dead-keyboard hang: if self-recognition
    // (isSynthetic) ever fails open, every synthetic event we post re-enters handle()
    // as a "real" key, drives the engine, and posts MORE synthetic events → an
    // unbounded storm that eats every keystroke. This breaker does NOT depend on
    // isSynthetic (the thing that can break); it just counts events we POST in a
    // sliding window. A cascade re-enters handle() and drives NEW posts, so counting
    // at the shared post site (notePostedKeyDown, below) catches the runaway whether or
    // not recognition still works.
    //
    // Threshold has a LARGE margin over any legit burst: one apply() posts at most ~33
    // keyDowns (engine caps a word at 32 chars → ≤32 backspaces + 1 insert), and fast
    // typing can stack a few bursts before they drain — realistically < ~100 posts in
    // any 500ms. A human simply cannot generate hundreds of key events in half a second,
    // so > 256 posts within a 500ms window can ONLY be a runaway. Numbers chosen for a
    // clear gap, not precision. On trip we stop emitting and call the controller to
    // disable the tap + reset (keys go native — Vietnamese-in-terminal off, keyboard
    // never dead). Gated behind AppState.tapCascadeBreaker (default ON) as a kill switch.
    // Window state shares `lock` with the in-flight counter above.
    private static let breakerWindowNs: UInt64 = 500_000_000
    private static let breakerThreshold = 256
    private static var windowStartNs: UInt64 = 0
    private static var postsInWindow = 0
    private static var _tripped = false
    static var tripped: Bool { lock.withLock { _tripped } }

    /// Re-arm after the controller has torn down / rebuilt a healthy tap.
    static func resetBreaker() {
        lock.withLock {
            _tripped = false
            inFlightKeyDowns = 0
            postsInWindow = 0
            windowStartNs = 0
        }
    }

    @inline(__always)
    private static func notePostedKeyDown() {
        let breakerEnabled = AppState.shared.tapCascadeBreaker   // own lock — outside ours
        let justTripped: Bool = lock.withLock {
            inFlightKeyDowns += 1
            let now = DispatchTime.now().uptimeNanoseconds
            lastPostNs = now
            // Count one posted keyDown into the sliding window; trip if the post rate
            // is superhuman (see the breaker doc above).
            guard breakerEnabled, !_tripped else { return false }
            if now &- windowStartNs > breakerWindowNs {
                windowStartNs = now
                postsInWindow = 0
            }
            postsInWindow += 1
            if postsInWindow > breakerThreshold {
                _tripped = true
                return true
            }
            return false
        }
        if justTripped {
            Signposts.log.fault("cascade breaker TRIPPED: >\(breakerThreshold, privacy: .public) synthetic posts within \(breakerWindowNs / 1_000_000, privacy: .public)ms — disabling tap, keys pass through natively")
            // Stop the storm at the source: disable the tap + reset the engine now,
            // rather than waiting for the next re-entered event to reach handle().
            // OUTSIDE the lock: emergencyStop takes the controller's state lock.
            TerminalTapController.shared.emergencyStop()
        }
    }

    /// Called by the tap when one of our own keyDowns comes back around.
    static func noteObservedSynthetic() {
        lock.withLock {
            if inFlightKeyDowns > 0 { inFlightKeyDowns -= 1 }
        }
    }

    /// True when no synthetic keyDown is still in flight. Self-heals: if an event
    /// was dropped (tap flapped mid-burst), a 500ms silence resets the counter so
    /// we can't get wedged in all-synthetic mode.
    static func queueDrained() -> Bool {
        lock.withLock {
            if inFlightKeyDowns == 0 { return true }
            if DispatchTime.now().uptimeNanoseconds &- lastPostNs > 500_000_000 {
                inFlightKeyDowns = 0
                return true
            }
            return false
        }
    }

    /// Replace `backspaces` trailing chars with `text`. Two strategies:
    /// - Default (terminals): Backspace ×N, then type.
    /// - `selectionReplace` (Chrome omnibox / Spotlight): Shift+Left ×N to SELECT the
    ///   chars, then type `text` to OVERTYPE the selection — one coherent edit that
    ///   doesn't fight inline autocomplete (a plain Backspace deletes/offsets the
    ///   suggestion). A pure deletion
    ///   (empty `text`) has nothing to overtype, so it falls back to real Backspaces.
    static func apply(backspaces: Int, insert text: String, mode: TapEmit = .backspace) {
        if tripped { return }   // recognition failed — emitting more would storm the keyboard
        // NEVER post from an untrusted process: CGEvent.post without Accessibility
        // can stall/behave unpredictably, and a tap callback stuck inside a post is
        // an unserviced port = system-wide input wedge. Dropping the edit merely
        // loses one tone change during the revoke transition.
        guard Accessibility.isTrusted else { return }
        // Signpost each synthesized edit burst — this is where a tone edit pays
        // real milliseconds (every posted event round-trips the window server).
        let spState = Signposts.poster.beginInterval("tap.emit",
                                                     id: Signposts.poster.makeSignpostID())
        // privacy: .public — counts only (burst size), no user text; without it the
        // xctrace export shows "<private>" and the bs-bucket analysis can't populate.
        defer { Signposts.poster.endInterval("tap.emit", spState, "bs=\(backspaces, privacy: .public) ins=\(text.count, privacy: .public)") }
        if mode == .selection, backspaces > 0, !text.isEmpty {
            // D1 fast path: one AX text edit instead of the Shift+Left ×N select +
            // overtype burst. Only when the synthetic queue is drained — the AX write
            // mutates the field immediately, and native letters that already passed the
            // tap can't be tracked, so taking it mid-burst could reorder ("nuwax"→"nuẵ"
            // class). ANY AX failure → replaceTrailing returns false and we fall through
            // to the posted-events path unchanged. Signpost so measure-signposts.sh can
            // confirm the round trips collapsed to one.
            //
            // SPOTLIGHT ONLY: a Chromium omnibox does NOT register an AX kAXSelectedText
            // mutation as user input, so its autocomplete model keeps the pre-edit text
            // and an immediate Enter submits the stale match ("chó"→"cho"). Browsers must
            // use the posted select+overtype below (real key events Chrome treats as user
            // input). Detect Spotlight (the other .selection app) by the window-list scan;
            // anything else in .selection mode is a browser → skip the AX path.
            if AppState.shared.axSelectionReplace, SpotlightDetector.isVisible,
               SyntheticKeyboard.queueDrained() {
                let axState = Signposts.poster.beginInterval("ax.replace",
                                                             id: Signposts.poster.makeSignpostID())
                let ok = AXTextEdit.replaceTrailing(backspaces: backspaces, with: text)
                // privacy: .public — burst size only, never user text (see tap.emit).
                Signposts.poster.endInterval("ax.replace", axState, "bs=\(backspaces, privacy: .public)")
                if ok { return }
            }
            for _ in 0..<backspaces { postSelectLeft() }
            postUnicode(text)
            return
        }
        if mode == .emptyReset, backspaces > 0 {
            postUnicode("\u{202F}")                                    // cancel inline autocomplete
            for _ in 0..<(backspaces + 1) { postVirtual(CGKeyCode(kVK_Delete)) }  // +1 deletes the U+202F
            if !text.isEmpty { postUnicode(text) }
            return
        }
        for _ in 0..<max(0, backspaces) { postVirtual(CGKeyCode(kVK_Delete)) }
        if !text.isEmpty { postUnicode(text) }
    }

    /// Re-emit a control/whitespace boundary key after a boundary rewrite, so it
    /// lands AFTER the synthesized edit.
    static func postKey(_ key: CGKeyCode) {
        guard Accessibility.isTrusted else { return }   // see apply()
        postVirtual(key)
    }

    /// Re-post a COPY of the user's own boundary keyDown (Return/Tab/Esc) so it
    /// lands AFTER a synthesized rewrite. Unlike postKey/postVirtual this keeps
    /// the ORIGINAL event's HID source state: Electron editors (Discord/Slate)
    /// treat a private-source synthetic Return as "insert newline" instead of
    /// firing their Enter-to-send handler, but an event that is byte-identical
    /// to the hardware one triggers the real action. The copy carries no magic
    /// and no in-flight count on purpose — when it re-enters our tap it must be
    /// handled as a REAL key (by then the engine is empty and the edit burst has
    /// drained, so it passes straight through; ordering is by timestamp).
    /// Only the keyDown is copied: the user's physical keyUp was never
    /// intercepted and reaches the app on its own.
    static func postBoundaryCopy(of event: CGEvent) {
        guard Accessibility.isTrusted else { return }
        guard let down = event.copy() else { return }
        stamp(down)
        down.post(tap: .cgSessionEventTap)
    }

    /// Shift+LeftArrow: extend the selection one char left (used by selectionReplace).
    private static func postSelectLeft() {
        // Layer 2: a nil private source means CGEvent(keyboardEventSource: nil,…) would
        // post an UNSTAMPED event — exactly what feeds the re-entrancy cascade. A nil
        // source is near-impossible, but if it ever happens, dropping the edit (the
        // terminal just gets no tone change) is the safe degradation. Same guard in
        // postVirtual/postUnicode.
        guard source != nil else { return }
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_LeftArrow), keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_LeftArrow), keyDown: false)
        else { return }
        down.flags = .maskShift
        up.flags = .maskShift
        notePostedKeyDown()
        stamp(down); down.post(tap: .cgSessionEventTap)
        stamp(up);   up.post(tap: .cgSessionEventTap)
    }

    private static func postVirtual(_ key: CGKeyCode) {
        guard source != nil else { return }            // Layer 2: never post unstamped (see postSelectLeft)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)
        else { return }
        notePostedKeyDown()
        stamp(down); down.post(tap: .cgSessionEventTap)
        stamp(up);   up.post(tap: .cgSessionEventTap)
    }

    private static func postUnicode(_ text: String) {
        guard source != nil else { return }            // Layer 2: never post unstamped (see postSelectLeft)
        let utf16 = Array(text.utf16)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true)
        else { return }
        utf16.withUnsafeBufferPointer { buf in
            down.keyboardSetUnicodeString(stringLength: buf.count, unicodeString: buf.baseAddress)
        }
        // Task B2 (experimental, default OFF): skip the keyUp on unicode inserts — post
        // only the keyDown carrying the string, halving posted events per insert. The
        // accounting stays balanced: the tap mask is keyDown-only, and the in-flight
        // counter tracks/observes keyDowns only, so a dropped keyUp is never counted and
        // never awaited. Unlike a virtual Delete (postVirtual, where the up matters for
        // key-repeat semantics), a unicode-string keyUp carries no repeat behaviour.
        let up = AppState.shared.tapSkipSyntheticKeyUp
            ? nil : CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
        if let up {
            utf16.withUnsafeBufferPointer { buf in
                up.keyboardSetUnicodeString(stringLength: buf.count, unicodeString: buf.baseAddress)
            }
        }
        notePostedKeyDown()
        stamp(down); down.post(tap: .cgSessionEventTap)
        if let up { stamp(up); up.post(tap: .cgSessionEventTap) }
    }
}

/// Global keyDown tap that handles terminal-class apps. Owns its own
/// engine, separate from the IMKit controller's (they never process the same app at
/// once: the tap suppresses terminal keys before the IME, and passes everything else
/// through for the IME to handle).
final class TerminalTapController {
    static let shared = TerminalTapController()

    /// Whether VietTelex is the active input source: the tap only transforms keys
    /// while true (so switching to ABC/US inside a terminal really types English).
    /// Driven by IMK activate/deactivate AND the TIS selection notification, resolved
    /// through `IMEActivation` so an out-of-order deactivate can't clobber it (see
    /// IMEActivation.swift). Locked: the mark* lifecycle calls run on MAIN, the
    /// per-key read runs on the TAP thread.
    private let activationLock = NSLock()
    private var activation = IMEActivation()
    var imeActive: Bool { activationLock.withLock { activation.isActive } }

    /// activateServer: VietTelex active for the focused client.
    func markActive() {
        let active = activationLock.withLock { activation.activate(); return activation.isActive }
        DebugLog.log("markActive → imeActive=\(active)")
    }

    /// deactivateServer: `stillSelected` = is VietTelex still the OS-selected source
    /// right now (queried via TIS by the caller). Ignores a stale late deactivate.
    func markInactive(stillSelected: Bool) {
        let active = activationLock.withLock {
            activation.deactivate(stillSelected: stillSelected); return activation.isActive
        }
        DebugLog.log("markInactive(stillSelected=\(stillSelected)) → imeActive=\(active)")
    }

    /// TIS selection-changed notification: authoritative recompute.
    func selectionChanged(isVietTelex: Bool) {
        let active = activationLock.withLock {
            activation.selectionChanged(isVietTelex: isVietTelex); return activation.isActive
        }
        DebugLog.log("selectionChanged(isVietTelex=\(isVietTelex)) → imeActive=\(active)")
    }

    /// TAP-thread confined: only ever touched inside the tap callback (and
    /// emergencyStop, which fires from the posting path on the same thread).
    private var engine = TelexEngine()

    /// Tap machinery. Guarded by `stateLock`: lifecycle (start/ensureRunning/teardown)
    /// runs on MAIN, while the callback's rare tapEnable branches (tripped / re-enable
    /// after timeout) and emergencyStop run on the TAP thread.
    private let stateLock = NSLock()

    // Grant-removal ping-pong detector (tap thread confined).
    private var lastDisableNs: UInt64 = 0
    private var disableBurst = 0

    // Functional health probe (stateLock): watchdog bumps probeSentTick and posts;
    // the callback copies it into probeSeenTick on arrival. Sent != seen for two
    // consecutive watchdog ticks ⇒ posts are dropped or the tap is wedged.
    private var probeSentTick: UInt64 = 0
    private var probeSeenTick: UInt64 = 0
    private var probeMisses = 0

    // Backoff after a FAILED trust cycle (probe missed / tap refused): without
    // it, the stale-TRUE AXIsProcessTrusted drives an infinite create→probe-fail
    // →teardown loop every ~8s (observed live 2026-07-22), eating keys in
    // tap-mode apps during each ~6s window. While quarantined we do NOT
    // auto-retry; an explicit user action (menu repair, grant re-add firing the
    // TCC notification, input-source activation after the window) retries.
    private var quarantineUntilNs: UInt64 = 0
    private func quarantine(_ seconds: UInt64) {
        quarantineUntilNs = DispatchTime.now().uptimeNanoseconds &+ seconds &* 1_000_000_000
    }
    private var quarantined: Bool {
        DispatchTime.now().uptimeNanoseconds < quarantineUntilNs
    }
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    /// The dedicated thread's run loop, captured at thread start; nil while stopped.
    private var tapRunLoop: CFRunLoop?

    /// True only if the tap exists AND is actually enabled/intercepting. A tap object
    /// can linger after its mach port dies (e.g. Accessibility was toggled off/on),
    /// so `tap != nil` alone is misleading — check `tapIsEnabled`.
    var isRunning: Bool {
        guard let tap = stateLock.withLock({ tap }) else { return false }
        return CGEvent.tapIsEnabled(tap: tap)
    }

    /// LAST-RESORT watchdog (main thread, alive ONLY while a tap exists — created in
    /// start(), invalidated in teardown()). Every 3s it makes a FRESH trust check;
    /// on revoke it forces the unconditional teardown. This is the layer that needs
    /// no cooperation from anything else: not from the TCC notification (may race /
    /// not arrive), not from the tap callback (which can be BLOCKED inside a
    /// synthetic-event post the instant trust vanishes — the suspected build-7 wedge:
    /// a stuck callback never sees tapDisabledBy* and a stuck thread's own runloop
    /// timer would be just as stuck, which is why this lives on MAIN). Worst case the
    /// user's input stalls ≤3s before the port is invalidated and everything flows
    /// natively again. The "no polling" design rule is deliberately bent here: the
    /// timer exists only while an Accessibility-trusted event tap does — the exact
    /// window in which a wedge can take the whole machine's input down.
    private var watchdog: Timer?

    private func startWatchdog() {
        watchdog?.invalidate()
        let t = Timer(timeInterval: 3, repeats: true) { [weak self] _ in
            guard let self else { return }
            if !AXIsProcessTrusted() {
                Signposts.log.fault("watchdog: Accessibility revoked with a live tap — forcing teardown")
                self.trustMayHaveChanged()
                return
            }
            // Trusted but the tap silently died: the tapDisabledByTimeout event is
            // NOT guaranteed to arrive (a callback blocked mid-post never sees it —
            // same field data as gonhanh's watchdog). ensureRunning is a single
            // tapIsEnabled read when healthy; re-enables or rebuilds when not.
            // Without this a dead tap only healed on the next activateServer
            // (app switch) — typing in the SAME app stayed broken up to that point.
            self.ensureRunning()

            // FUNCTIONAL probe — the only signal that survives a LYING
            // AXIsProcessTrusted (grant REMOVED via −, field bug 2026-07-22):
            // post a keycode-127 marker at ourselves; the callback swallows it
            // and acks. Two consecutive unanswered probes ⇒ posts are being
            // dropped (revoked) or the callback is wedged ⇒ unconditional
            // teardown, keys flow natively again.
            let (sent, seen): (UInt64, UInt64) = self.stateLock.withLock {
                (self.probeSentTick, self.probeSeenTick)
            }
            if sent != seen {
                self.probeMisses += 1
                if self.probeMisses >= 2 {
                    Signposts.log.fault("health probe unanswered ×\(self.probeMisses) — posts dropped or tap wedged; tearing down (quarantine 60s)")
                    DebugLog.log("health probe missed ×\(self.probeMisses) → teardown + quarantine 60s")
                    self.probeMisses = 0
                    self.trustLooksStale = true          // menu shows the repair line
                    self.quarantine(60)
                    self.trustMayHaveChanged()
                    return
                }
            } else {
                self.probeMisses = 0
            }
            if let tap = self.stateLock.withLock({ self.tap }), CGEvent.tapIsEnabled(tap: tap) {
                self.stateLock.withLock { self.probeSentTick &+= 1 }
                SyntheticKeyboard.postProbe()
            }
        }
        t.tolerance = 1
        RunLoop.main.add(t, forMode: .common)
        watchdog = t
    }

    /// Emit mode for the CURRENT key: false = Backspace+retype (terminals), true =
    /// Shift+Left select + overtype (Chrome omnibox / Spotlight). Set per event in
    /// handle() before any edit is emitted. TAP-thread confined.
    private var emitMode: TapEmit = .backspace

    // Throttle for the imeActive self-heal reconcile (see handle()). TAP-thread
    // confined (only touched inside the callback).
    private var lastReconcileNs: UInt64 = 0
    private let reconcileWindowNs: UInt64 = 750_000_000

    private let kDelete = 51, kReturn = 36, kEnter = 76, kTab = 48, kEscape = 53

    private init() {}

    /// Create and enable the tap. No-op if already running or not Accessibility-
    /// trusted (sandboxed build, or permission not yet granted). Idempotent — called
    /// at launch and again on activate so granting AX later starts it without relaunch.
    ///
    /// THREADING: the tap's run loop source lives on a DEDICATED thread, not main.
    /// On main it queued behind every ~2ms IMKit XPC round trip and any Settings UI
    /// work — jittering terminal keystrokes and, worse, risking the slow-callback
    /// path where macOS disables the tap (tapDisabledByTimeout → leaked keys). The
    /// thread is event-driven (parked in mach_msg, zero CPU when idle) — it is the
    /// tap's equivalent of the main run loop, not a polling worker, so it does not
    /// violate the "no persistent background work" rule in DESIGN.md.
    /// TRUE when the last tap-create attempt failed WHILE AXIsProcessTrusted said
    /// yes — the classic stale TCC grant after a re-signed upgrade: the checkbox
    /// looks on, but the system refuses the tap. Cleared the moment a tap is
    /// created. The menu turns this into a self-serve repair instruction
    /// (remove + re-add in Accessibility) instead of silently typing English.
    private(set) var trustLooksStale = false

    func start() {
        guard !quarantined else { return }
        guard stateLock.withLock({ tap == nil }), Accessibility.isTrusted else { return }
        let mask = CGEventMask((1 << CGEventType.keyDown.rawValue)
                             | (1 << CGEventType.leftMouseDown.rawValue)
                             | (1 << CGEventType.rightMouseDown.rawValue))
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let me = Unmanaged<TerminalTapController>.fromOpaque(refcon).takeUnretainedValue()
                return me.handle(type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            // Trusted but the system refused the tap → stale grant (field case
            // 2026-07-22: dev re-sign; can also follow unusual upgrade paths).
            trustLooksStale = true
            quarantine(60)
            Signposts.log.fault("tap create FAILED while trusted — stale Accessibility grant; remove + re-add VietTelex in System Settings")
            DebugLog.log("tap create failed while trusted → stale TCC grant (retry in 60s)")
            return
        }
        trustLooksStale = false

        let src = CFMachPortCreateRunLoopSource(nil, tap, 0)
        // Park the source on the dedicated thread's run loop. Wait (bounded) for the
        // run loop reference so teardown() always has something to stop — the thread
        // reaches the semaphore in microseconds.
        let ready = DispatchSemaphore(value: 0)
        let thread = Thread { [weak self] in
            let rl = CFRunLoopGetCurrent()
            self?.stateLock.withLock { self?.tapRunLoop = rl }
            CFRunLoopAddSource(rl, src, .commonModes)
            ready.signal()
            CFRunLoopRun()   // returns after CFRunLoopStop in teardown()
        }
        thread.name = "com.viettelex.event-tap"
        thread.qualityOfService = .userInteractive
        thread.start()
        _ = ready.wait(timeout: .now() + 2)
        engine.reset()   // stale composition from a previous tap life; safe pre-enable
        CGEvent.tapEnable(tap: tap, enable: true)
        stateLock.withLock {
            self.tap = tap
            self.source = src
        }
        SyntheticKeyboard.resetBreaker()   // fresh machinery — clear any prior trip
        startWatchdog()
        DebugLog.log("tap created + enabled (dedicated thread)")
    }

    /// Ensure a HEALTHY (enabled) tap. Recovers from the two ways a tap silently dies:
    /// (1) disabled by timeout/user-input → re-enable; (2) mach port invalidated after
    /// Accessibility was toggled off/on → the object lingers but `tapEnable` won't
    /// stick, so tear it down and create a fresh one. Called on every activateServer,
    /// so switching input source / focusing a terminal self-heals a dead tap.
    func ensureRunning() {
        guard Accessibility.isTrusted else { return }
        if let tap = stateLock.withLock({ tap }) {
            // A tripped breaker disabled the tap on purpose. Re-enabling + re-arming is
            // safe now: pid-based isSynthetic no longer fails open, so the cascade that
            // tripped it can't recur. Clear the breaker whenever we leave with a healthy
            // enabled tap, or the next keystroke would just disable it again.
            if CGEvent.tapIsEnabled(tap: tap), !SyntheticKeyboard.tripped { return }  // healthy
            CGEvent.tapEnable(tap: tap, enable: true)       // try a simple re-enable
            if CGEvent.tapIsEnabled(tap: tap) { SyntheticKeyboard.resetBreaker(); return }
            teardown()                                      // dead port -> recreate
        }
        start()
    }

    /// The Accessibility permission MAY have changed (TCC notification, or a
    /// disabled-tap event with an untrusted read). MAIN thread — lifecycle owner.
    ///
    /// Tear down UNCONDITIONALLY, then re-create after a beat if genuinely trusted.
    /// The build-7 hang taught why there must be no guard here: immediately after
    /// the toggle, tccd can still report the OLD trust value — the previous
    /// `guard !isTrusted else return` skipped the teardown on exactly that race and
    /// left the wedged tap alive. Rebuilding a healthy tap ~1.5s later costs
    /// nothing; guessing wrong costs the user's keyboard and mouse.
    /// Called from the menu repair flow / TCC change notification: the user just
    /// DID something about the permission — drop the backoff and re-evaluate now.
    func retryNow() {
        quarantineUntilNs = 0
        trustLooksStale = false
        Accessibility.invalidateCache()
        ensureRunning()
    }

    /// A REAL trust-change signal (TCC notification): outranks the backoff.
    func trustChangedExternally() {
        quarantineUntilNs = 0
        trustMayHaveChanged()
    }

    func trustMayHaveChanged() {
        Accessibility.invalidateCache()
        teardown()
        SyntheticKeyboard.resetBreaker()
        DebugLog.log("trust-change signal → tap torn down; re-checking in 1.5s")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            Accessibility.invalidateCache()
            self?.ensureRunning()   // recreates only if AXIsProcessTrusted by then
        }
    }

    private func teardown() {
        watchdog?.invalidate()
        watchdog = nil
        let (tap, source, runLoop) = stateLock.withLock {
            let t = (self.tap, self.source, self.tapRunLoop)
            self.tap = nil
            self.source = nil
            self.tapRunLoop = nil
            return t
        }
        if let tap {
            // Best effort — this CGS call FAILS once Accessibility is revoked…
            CGEvent.tapEnable(tap: tap, enable: false)
            // …so the AUTHORITATIVE removal is invalidating the mach port: the window
            // server unhooks a dead port exactly as if the process had exited, and it
            // needs no permission. Without this line, a revoked process that then
            // stops its tap thread leaves an ENABLED tap nobody services — every
            // keyDown/leftMouseDown/rightMouseDown in the session queues into the
            // void: keyboard dead, clicks dead, mouse still moves (not in the mask),
            // reboot territory. This was the v1.3.0(6) hang: the revoke handler tore
            // the thread down but could no longer disable the tap it orphaned.
            CFMachPortInvalidate(tap)
        }
        if let runLoop {
            if let source { CFRunLoopRemoveSource(runLoop, source, .commonModes) }
            CFRunLoopStop(runLoop)   // ONLY after the port is invalid — never orphan a live tap
        }
        DebugLog.log("tap torn down (port invalidated)")
    }

    /// Layer 3 — hard stop when the cascade breaker trips. Disable the tap (keys pass
    /// through NATIVELY — degraded, never a dead keyboard) and drop any composition,
    /// immediately, at the moment of the trip rather than on the next re-entered event.
    /// The tap object is kept so a later activateServer → ensureRunning() can re-enable
    /// and re-arm the breaker once the machinery is healthy again. Called from
    /// SyntheticKeyboard's post site — i.e. on the TAP thread, so touching `engine`
    /// (tap-thread confined) here is safe.
    func emergencyStop() {
        if let tap = stateLock.withLock({ tap }) { CGEvent.tapEnable(tap: tap, enable: false) }
        engine.reset()
        DebugLog.log("EMERGENCY STOP — cascade breaker tripped, tap disabled, keys native")
    }

    // Returning nil suppresses the key; returning the event passes it through.
    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)

        // Watchdog health probe (our own keycode-127 keyDown): swallow it before
        // ANY other logic — no app ever sees it, no counter counts it.
        if type == .keyDown,
           event.getIntegerValueField(.keyboardEventKeycode) == SyntheticKeyboard.probeKeycode,
           SyntheticKeyboard.isSynthetic(event)
            || event.getIntegerValueField(.eventSourceUnixProcessID) == Int64(getpid()) {
            stateLock.withLock { probeSeenTick = probeSentTick }
            return nil
        }

        // Circuit breaker tripped: synthetic events stopped being recognized as ours
        // and were cascading (the dead-keyboard hang). DISABLE the tap immediately so
        // every key — real and any still-queued synthetic — passes through natively;
        // the keyboard is never dead. A later activateServer → ensureRunning()
        // re-enables and re-arms the breaker once the machinery is healthy again.
        // Checked before the tapDisabled re-enable below so a tripped tap stays down.
        if SyntheticKeyboard.tripped {
            engine.reset()
            if let tap = stateLock.withLock({ tap }) { CGEvent.tapEnable(tap: tap, enable: false) }
            return pass
        }

        // The system disables a tap that is too slow or gets user input; re-enable —
        // but ONLY while still Accessibility-trusted. When the user REVOKES the
        // permission, macOS disables the tap with tapDisabledByUserInput and will
        // disable it again on every re-enable; blindly re-enabling fought the OS in
        // a ping-pong that wedged ALL input (keyboard + mouse are both in our mask)
        // — the reported full-input hang. Revoked → tear the whole tap down (on
        // main; lifecycle is main-owned) and let every event flow natively.
        // Direct AXIsProcessTrusted() call, NOT the TTL cache — the cache can say
        // "trusted" for up to 2s after the toggle, which re-arms the fight.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            // GRANT-REMOVAL guard (field bug 2026-07-22): when the user REMOVES the
            // Accessibility entry (−, not a toggle), AXIsProcessTrusted() keeps
            // returning a stale TRUE — so the old code re-enabled, the OS disabled
            // again, and the ping-pong wedged ALL input. Three disables inside 2s
            // can only be that fight: tear down regardless of what trust claims.
            let now = DispatchTime.now().uptimeNanoseconds
            if now &- lastDisableNs < 2_000_000_000 { disableBurst += 1 } else { disableBurst = 1 }
            lastDisableNs = now
            if disableBurst >= 3 {
                engine.reset()
                Signposts.log.fault("tap disable ping-pong (\(self.disableBurst)x/2s) — grant likely REMOVED, tearing down")
                DebugLog.log("tap disable ping-pong → teardown (grant removed?)")
                DispatchQueue.main.async { TerminalTapController.shared.trustMayHaveChanged() }
                return pass
            }
            if AXIsProcessTrusted() {
                if let tap = stateLock.withLock({ tap }) { CGEvent.tapEnable(tap: tap, enable: true) }
            } else {
                Accessibility.invalidateCache()
                engine.reset()
                DebugLog.log("tap disabled + Accessibility revoked → full teardown, input native")
                DispatchQueue.main.async { TerminalTapController.shared.trustMayHaveChanged() }
            }
            return pass
        }

        // A mouse click moves the caret, so any composition in progress is stale:
        // abandon it. We do NOT emit backspaces/
        // edits — the caret is elsewhere now and the typed text is already real. Also
        // signal the IMKit controller (other apps) to drop its composition.
        if type == .leftMouseDown || type == .rightMouseDown {
            engine.reset()
            if imeActive { NotificationCenter.default.post(name: .telexResetComposition, object: nil) }
            return pass
        }

        guard type == .keyDown else { return pass }

        // Our own synthesized output: never re-process it (but note its arrival —
        // it drains the in-flight counter that gates the native fast path).
        if SyntheticKeyboard.isSynthetic(event) {
            SyntheticKeyboard.noteObservedSynthetic()
            return pass
        }

        // Self-heal the latched imeActive against the authoritative selected source.
        // imeActive is a cache flipped by activate / deactivate / the TIS notification,
        // and every OFF path depends on isVietTelexSelected() →
        // TISCopyCurrentKeyboardInputSource(), which can still report the OUTGOING
        // source at the instant of a switch. So a VietTelex→English switch can be missed
        // by BOTH the deactivate and notification paths, latching imeActive true — the
        // tap then transforms in English forever ("gõ ra dấu" in English mode). Nothing
        // else re-checks, so re-verify here, throttled. Only while active: the common
        // English case (imeActive already false) returns just below at zero cost; the
        // turn-ON direction stays covered by the unconditional activateServer→markActive.
        // TIS copy runs at most once per window — but TIS is NOT documented safe off
        // the main thread, so with the tap on its own thread the check hops to MAIN
        // asynchronously. The correction lands via the locked selectionChanged() and
        // takes effect on the NEXT keystroke — one key later than the old synchronous
        // check, which is fine for a ≤750ms-throttled self-heal of an already-stale flag.
        if imeActive {
            let now = DispatchTime.now().uptimeNanoseconds
            if now &- lastReconcileNs > reconcileWindowNs {
                lastReconcileNs = now
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    if !TelexInputController.isVietTelexSelected() {
                        self.selectionChanged(isVietTelex: false)
                        DebugLog.log("reconcile: VietTelex not selected → tap dormant (healed stale imeActive)")
                    }
                }
            }
        }

        guard imeActive else {
            // Went inactive with a word half-composed (e.g. the async reconcile above
            // just corrected a stale flag): abandon it so a later re-activate can't
            // resume a stale composition. `engine` is tap-thread confined — reset here,
            // never from the main-thread paths that flip the flag.
            if !engine.isEmpty { engine.reset() }
            return pass
        }

        // A ⌘/⌃/⌥ combo (⌘A select-all, ⌘C, ⌃C…) is never Telex input, and IMK does
        // NOT route ⌘-combos to the IMKit controller — so the controller cannot drop
        // its composition on its own (that was the "⌘A then type edits the old word
        // instead of replacing the selection" bug). The tap sees every key globally:
        // reset our engine AND signal the controller.
        // Runs for ALL apps, before the tap-mode gate.
        let flags = event.flags
        if flags.contains(.maskCommand) || flags.contains(.maskControl) || flags.contains(.maskAlternate) {
            if !engine.isEmpty { engine.reset() }   // skip the no-op reset when nothing composes
            // ALWAYS notify: the IMKit controller's engine state is invisible from here,
            // so we cannot gate this on our own emptiness.
            NotificationCenter.default.post(name: .telexResetComposition, object: nil)
            return pass
        }

        // Decide whether the tap handles this app, and with which emit mode:
        //  - Spotlight (window-list) / Chromium → Shift+Left selection-replace.
        //  - MS Office → empty-char reset (Shift+Left would select adjacent cells).
        //  - Terminals (fallbackApps) → Backspace+retype.
        //  - Anything else → the IMKit in-place path handles it (pass through).
        let id = FrontmostApp.shared.bundleID
        // Spotlight is IN-PLACE by default (builtInInPlaceApps) — the tap engages
        // only for an explicit tap-family manual pick. Manual pin consulted FIRST:
        // isVisible kicks a CGWindowList background scan every 200ms while typing,
        // which nobody should pay for unless Spotlight was actually pinned.
        let spotlightManual = AppState.shared.manualMode(AppState.spotlightBundleID)
        if (spotlightManual == .selection || spotlightManual == .tap
                || spotlightManual == .emptyReset),
           SpotlightDetector.isVisible {
            switch spotlightManual {
            case .selection: emitMode = .selection
            case .tap: emitMode = .backspace
            case .emptyReset: emitMode = .emptyReset
            default: engine.reset(); return pass
            }
        } else if AppState.shared.usesSelectionReplace(id) {
            emitMode = .selection
        } else if AppState.shared.usesEmptyReset(id) {
            emitMode = .emptyReset
        } else if AppState.shared.usesTapMode(id) {
            emitMode = .backspace
        } else {
            engine.reset(); return pass
        }
        if IsSecureEventInputEnabled() { engine.reset(); return pass }

        // Reflect the current "bỏ dấu tự do" setting (feed/backspace/boundary all
        // re-parse `raw` and honor it).
        engine.freeMarking = AppState.shared.freeMarking
        engine.modernTone = AppState.shared.modernOrthography
        engine.liveSpellCheck = AppState.shared.liveSpellCheck
        engine.simpleTelex = AppState.shared.simpleTelex

        // Signpost the tap-handled keystroke; message = emit mode (see Instrumentation).
        let spState = Signposts.poster.beginInterval("tap.handle",
                                                     id: Signposts.poster.makeSignpostID())
        defer {
            let mode = emitMode == .selection ? "selection"
                     : emitMode == .emptyReset ? "emptyReset" : "backspace"
            // privacy: .public — internal emit-mode name, never user text (see imk.handle).
            Signposts.poster.endInterval("tap.handle", spState, "\(mode, privacy: .public)")
        }

        let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))

        if keyCode == kDelete {
            if engine.isEmpty {
                // Not composing -> real Backspace, unless a synthetic burst is still
                // draining (it must land first or the delete hits the wrong char).
                if SyntheticKeyboard.queueDrained() { return pass }
                SyntheticKeyboard.postKey(CGKeyCode(kVK_Delete))
                return nil
            }
            if case let .replace(bs, insert) = engine.backspace() {
                SyntheticKeyboard.apply(backspaces: bs, insert: insert, mode: emitMode)
            }
            return nil
        }
        if keyCode == kReturn || keyCode == kEnter || keyCode == kTab || keyCode == kEscape {
            // Commit the composed word, then prefer passing the REAL key through: a
            // synthetic (isTrusted=false) Tab/Return doesn't trigger the app's own
            // handling — shell Tab-completion never fires, web/Electron "Enter to send"
            // is ignored (falls back to newline), TUIs (Claude Code) treat it oddly.
            // Since in tap mode EVERY key is composed, the buffer is rarely empty when
            // Tab is pressed mid-token (e.g. "cd Doc⇥"), so the old empty-check wasn't
            // enough. Only when auto-restore ACTUALLY rewrote the word (emitBoundary →
            // true) do we suppress + re-emit synthetically, so the boundary key lands
            // AFTER the async edit; otherwise the real key passes through untouched.
            if engine.isEmpty, SyntheticKeyboard.queueDrained() { return pass }
            if emitBoundary(suppressAutoRestore: false) || !SyntheticKeyboard.queueDrained() {
                reemit(keyCode: keyCode, string: nil, original: event)
                return nil
            }
            return pass
        }

        // Read the typed character.
        var len = 0
        var buf = [UniChar](repeating: 0, count: 4)
        event.keyboardGetUnicodeString(maxStringLength: 4, actualStringLength: &len, unicodeString: &buf)
        guard len >= 1, let scalar = Unicode.Scalar(buf[0]) else {
            // Dead/function key: flush the word, let the odd key through.
            emitBoundary(suppressAutoRestore: false)
            return pass
        }
        // Navigation / function keys (←↑→↓, Home/End/PageUp/PageDown, forward-delete,
        // F1-F12): iTerm delivers arrows as CONTROL chars 0x1C–0x1F (not the 0xF700
        // function-key range as elsewhere). Anything reaching here with a control char
        // (< 0x20; Return/Tab/Esc/Backspace were already handled by keycode) or a
        // function-key codepoint is navigation, NOT text: flush the word and PASS THE
        // REAL KEY THROUGH so cursor/history work — never re-emit it as inserted text
        // (re-emitting arrows as 0x1C killed arrow-key navigation).
        if buf[0] < 0x20 || (buf[0] >= 0xF700 && buf[0] <= 0xF8FF) {
            emitBoundary(suppressAutoRestore: false)
            return pass
        }
        let ch = Character(scalar)
        guard let ascii = ch.asciiValue, isLetterAscii(ascii) else {
            // Non-letter boundary (space, digit, punctuation). Brackets skip
            // auto-restore (code context). Mirror the Return/Tab handling above: only
            // when a rewrite ACTUALLY happened (emitBoundary → true) or a synthetic
            // burst is still draining must we suppress + re-emit synthetically, so the
            // boundary key lands AFTER the async edit. Otherwise pass the REAL keyDown
            // through — no two window-server round trips per space, and the app sees a
            // genuine key (keycode intact), not a text-only keycode-0 event. Respects
            // tapNativeFastPath like the letter fast-path below. (modifyInPlace adds
            // nothing here: with no rewrite pending the untouched event is already
            // exactly what should land, in every emit mode.)
            let rewrote = emitBoundary(suppressAutoRestore: isBracketUnichar(buf[0]))
            if !rewrote, AppState.shared.tapNativeFastPath, SyntheticKeyboard.queueDrained() {
                return pass
            }
            reemit(keyCode: keyCode, string: String(ch))
            return nil
        }

        // Ordering rule: a native letter must never race ahead of a still-queued
        // synthetic edit ("nuwax" showed as "nuẵ" because native 'a' landed before
        // the synthetic ư from 'w'). Historically EVERY key was therefore suppressed
        // and re-emitted synthetically — 2 posted events per plain letter, each a
        // real window-server round trip. The in-flight counter restores the native
        // fast path safely: a NON-TRANSFORMING letter passes through untouched
        // whenever no synthetic keyDown is still in flight (the common case), and
        // only falls back to the synthetic channel while a burst is draining. The
        // tap callback is serial, so the decision itself cannot race.
        switch engine.feed(ch) {
        case .passthrough:
            if AppState.shared.tapNativeFastPath, SyntheticKeyboard.queueDrained() {
                return pass                               // native: zero synthetic events
            }
            SyntheticKeyboard.apply(backspaces: 0, insert: String(ch), mode: emitMode)
        case .none:
            break
        case let .replace(bs, insert):
            // B1: a single-char transform (w→ư) rewrites this event in place; anything
            // with backspaces, multi-char, or a draining burst keeps the synthetic path.
            if modifyInPlace(event: event, backspaces: bs, insert: insert) { return pass }
            SyntheticKeyboard.apply(backspaces: bs, insert: insert, mode: emitMode)
        }
        return nil
    }

    /// Task B1 — modify the physical CGEvent in place instead of suppress + post.
    /// When a tone edit is a pure single-character insert (0 backspaces) in .backspace
    /// emit mode and no synthetic burst is still draining, rewrite the event the tap
    /// callback is holding via keyboardSetUnicodeString and let it PASS. The event
    /// keeps its real keycode and timing, so ZERO synthetic events are posted — two
    /// window-server round trips saved per w→ư / boundary re-emit. Because it is never
    /// posted it does NOT count as in-flight synthetic (correct: nothing to observe).
    /// The modified NSEvent still reaches the IMKit controller, but terminals are
    /// tap-mode-deferred there (usesTapMode → handle returns false) so the app inserts
    /// it natively — never double-composed.
    ///
    /// Restricted to .backspace mode on purpose: .selection needs a Shift+Left select
    /// first and .emptyReset needs the U+202F dance, neither expressible as a single
    /// in-place rewrite. The queueDrained() guard preserves ordering — while a burst is
    /// draining we decline so the caller keeps the old suppress+post path and the edit
    /// still lands after the queued events.
    /// Returns true iff it rewrote `event` (caller should then return it as pass).
    @inline(__always)
    private func modifyInPlace(event: CGEvent, backspaces: Int, insert: String) -> Bool {
        guard AppState.shared.tapModifyEventInPlace,
              emitMode == .backspace,
              backspaces == 0,
              insert.count == 1,               // single character (any UTF-16 length)
              SyntheticKeyboard.queueDrained()
        else { return false }
        let utf16 = Array(insert.utf16)
        utf16.withUnsafeBufferPointer { buf in
            event.keyboardSetUnicodeString(stringLength: buf.count, unicodeString: buf.baseAddress)
        }
        return true
    }

    /// Emit a shortcut expansion / auto-restore rewrite for the composed word. Returns
    /// true if anything was rewritten (caller then re-emits the boundary key after it).
    @discardableResult
    private func emitBoundary(suppressAutoRestore: Bool) -> Bool {
        guard !engine.isEmpty else { engine.reset(); return false }
        // Capture BOTH forms before reset() wipes them. The composed word is what's on
        // screen (drives the backspace count); the raw keystrokes are what the user
        // actually typed.
        let word = engine.composed
        let rawWord = engine.rawKeystrokes
        let onScreen = word.unicodeScalars.count
        // Shortcut expansion: try the COMPOSED form first, then fall back to the RAW
        // keystrokes. A shortcut key containing Telex triggers (s f r x j w, doubled
        // vowels) is transformed by composition and so can NEVER match on `composed`
        // ("ddc" composes to "đc"); the raw form recovers it. Backspaces are always the
        // on-screen composed scalar count regardless of which form matched.
        if let expansion = (word.isEmpty ? nil : AppState.shared.shortcuts[word])
                        ?? AppState.shared.shortcuts[rawWord] {
            engine.reset()
            SyntheticKeyboard.apply(backspaces: onScreen, insert: expansion, mode: emitMode)
            return true
        }
        let restore = AppState.shared.autoRestore && !suppressAutoRestore
        if case let .replace(bs, insert) = engine.commitBoundary(autoRestore: restore) {
            SyntheticKeyboard.apply(backspaces: bs, insert: insert, mode: emitMode)
            return true
        }
        return false
    }

    private func reemit(keyCode: Int, string: String?, original: CGEvent? = nil) {
        switch keyCode {
        case kReturn, kEnter, kTab, kEscape:
            // Prefer a stamped COPY of the user's own keyDown (HID source intact):
            // Electron editors newline on a private-source synthetic Return but run
            // their real Enter-to-send handler on a hardware-identical one.
            if let original {
                SyntheticKeyboard.postBoundaryCopy(of: original)
            } else if keyCode == kTab {
                SyntheticKeyboard.postKey(CGKeyCode(kVK_Tab))
            } else if keyCode == kEscape {
                SyntheticKeyboard.postKey(CGKeyCode(kVK_Escape))
            } else {
                SyntheticKeyboard.postKey(CGKeyCode(kVK_Return))
            }
        default:              if let s = string { SyntheticKeyboard.apply(backspaces: 0, insert: s, mode: emitMode) }
        }
    }
}

@inline(__always)
private func isLetterAscii(_ c: UInt8) -> Bool {
    (c >= UInt8(ascii: "a") && c <= UInt8(ascii: "z")) ||
    (c >= UInt8(ascii: "A") && c <= UInt8(ascii: "Z"))
}

@inline(__always)
private func isBracketUnichar(_ c: UInt16) -> Bool {
    switch c {
    case UInt16(UInt8(ascii: "[")), UInt16(UInt8(ascii: "]")),
         UInt16(UInt8(ascii: "{")), UInt16(UInt8(ascii: "}")),
         UInt16(UInt8(ascii: "(")), UInt16(UInt8(ascii: ")")):
        return true
    default:
        return false
    }
}
