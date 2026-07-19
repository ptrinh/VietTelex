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
    private static var cached = false
    private static var lastCheckNs: UInt64 = 0
    private static let ttlNs: UInt64 = 2_000_000_000

    /// True when the process may create an event tap / post events. Always false in
    /// the sandboxed build — it can never be granted.
    static var isTrusted: Bool {
        let now = DispatchTime.now().uptimeNanoseconds
        if lastCheckNs != 0, now &- lastCheckNs < ttlNs { return cached }
        lastCheckNs = now
        cached = AXIsProcessTrusted()
        return cached
    }

    static func invalidateCache() { lastCheckNs = 0 }

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

    private(set) var bundleID: String?

    private init() {
        bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            self?.bundleID = app?.bundleIdentifier
        }
    }
}

/// Spotlight is a system overlay, not the frontmost APP — its bundle id never shows
/// up in NSWorkspace.frontmostApplication. Detect it by scanning the
/// on-screen window list for a window owned by the "Spotlight" process.
enum SpotlightDetector {
    // CGWindowListCopyWindowInfo enumerates every on-screen window — too heavy to run
    // on every keystroke (it slowed the tap callback enough to trip
    // tapDisabledByTimeout, leaking keys to the broken IMKit path → intermittent
    // garbage). Cache the result with a short TTL; Spotlight visibility doesn't change
    // per keystroke, so a ~200ms lag is invisible.
    private static var cached = false
    private static var lastCheckNs: UInt64 = 0
    private static let ttlNs: UInt64 = 200_000_000

    static var isVisible: Bool {
        let now = DispatchTime.now().uptimeNanoseconds
        if now &- lastCheckNs < ttlNs { return cached }
        lastCheckNs = now
        cached = scan()
        return cached
    }

    private static func scan() -> Bool {
        let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windows = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]]
        else { return false }
        for w in windows {
            if let owner = w[kCGWindowOwnerName as String] as? String, owner == "Spotlight" {
                return true
            }
        }
        return false
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
    static func isSynthetic(_ event: CGEvent) -> Bool {
        event.getIntegerValueField(.eventSourceUserData) == magic
    }

    /// True if `event` (NSEvent, in IMKit handle()) is one we posted.
    static func isSynthetic(_ event: NSEvent) -> Bool {
        event.cgEvent.map(isSynthetic) ?? false
    }

    /// Strictly-increasing timestamp for posted events. CGEvent.post orders delivery
    /// by timestamp, and events we create back-to-back can get equal/near-equal
    /// mach-time stamps — the window server then reorders same-stamp events, so a
    /// later letter overtakes an earlier tone edit ("nuwax" typed fast came out
    /// "nuẵ" = "nuawx"). Stamping each event mach-time-or-last+1 forces FIFO.
    private static var lastStamp: UInt64 = 0
    private static func stamp(_ event: CGEvent) {
        let now = mach_absolute_time()
        lastStamp = now > lastStamp ? now : lastStamp &+ 1
        event.timestamp = CGEventTimestamp(lastStamp)
    }

    /// Replace `backspaces` trailing chars with `text`. Two strategies:
    /// - Default (terminals): Backspace ×N, then type.
    /// - `selectionReplace` (Chrome omnibox / Spotlight): Shift+Left ×N to SELECT the
    ///   chars, then type `text` to OVERTYPE the selection — one coherent edit that
    ///   doesn't fight inline autocomplete (a plain Backspace deletes/offsets the
    ///   suggestion). A pure deletion
    ///   (empty `text`) has nothing to overtype, so it falls back to real Backspaces.
    static func apply(backspaces: Int, insert text: String, mode: TapEmit = .backspace) {
        // Signpost each synthesized edit burst — this is where a tone edit pays
        // real milliseconds (every posted event round-trips the window server).
        let spState = Signposts.poster.beginInterval("tap.emit",
                                                     id: Signposts.poster.makeSignpostID())
        defer { Signposts.poster.endInterval("tap.emit", spState, "bs=\(backspaces) ins=\(text.count)") }
        if mode == .selection, backspaces > 0, !text.isEmpty {
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
    static func postKey(_ key: CGKeyCode) { postVirtual(key) }

    /// Shift+LeftArrow: extend the selection one char left (used by selectionReplace).
    private static func postSelectLeft() {
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_LeftArrow), keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_LeftArrow), keyDown: false)
        else { return }
        down.flags = .maskShift
        up.flags = .maskShift
        stamp(down); down.post(tap: .cgSessionEventTap)
        stamp(up);   up.post(tap: .cgSessionEventTap)
    }

    private static func postVirtual(_ key: CGKeyCode) {
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)
        else { return }
        stamp(down); down.post(tap: .cgSessionEventTap)
        stamp(up);   up.post(tap: .cgSessionEventTap)
    }

    private static func postUnicode(_ text: String) {
        let utf16 = Array(text.utf16)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
        else { return }
        utf16.withUnsafeBufferPointer { buf in
            down.keyboardSetUnicodeString(stringLength: buf.count, unicodeString: buf.baseAddress)
            up.keyboardSetUnicodeString(stringLength: buf.count, unicodeString: buf.baseAddress)
        }
        stamp(down); down.post(tap: .cgSessionEventTap)
        stamp(up);   up.post(tap: .cgSessionEventTap)
    }
}

/// Global keyDown tap that handles terminal-class apps. Owns its own
/// engine, separate from the IMKit controller's (they never process the same app at
/// once: the tap suppresses terminal keys before the IME, and passes everything else
/// through for the IME to handle).
final class TerminalTapController {
    static let shared = TerminalTapController()

    /// Set by the IMKit controller: only act while VietTelex is the active input
    /// source (so switching to ABC/US inside a terminal really types English).
    var imeActive = false

    private var engine = TelexEngine()
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?

    /// True only if the tap exists AND is actually enabled/intercepting. A tap object
    /// can linger after its mach port dies (e.g. Accessibility was toggled off/on),
    /// so `tap != nil` alone is misleading — check `tapIsEnabled`.
    var isRunning: Bool {
        guard let tap else { return false }
        return CGEvent.tapIsEnabled(tap: tap)
    }

    /// Emit mode for the CURRENT key: false = Backspace+retype (terminals), true =
    /// Shift+Left select + overtype (Chrome omnibox / Spotlight). Set per event in
    /// handle() before any edit is emitted.
    private var emitMode: TapEmit = .backspace

    private let kDelete = 51, kReturn = 36, kEnter = 76, kTab = 48, kEscape = 53

    private init() {}

    /// Create and enable the tap. No-op if already running or not Accessibility-
    /// trusted (sandboxed build, or permission not yet granted). Idempotent — called
    /// at launch and again on activate so granting AX later starts it without relaunch.
    func start() {
        guard tap == nil, Accessibility.isTrusted else { return }
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
        ) else { return }

        let src = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.source = src
    }

    /// Ensure a HEALTHY (enabled) tap. Recovers from the two ways a tap silently dies:
    /// (1) disabled by timeout/user-input → re-enable; (2) mach port invalidated after
    /// Accessibility was toggled off/on → the object lingers but `tapEnable` won't
    /// stick, so tear it down and create a fresh one. Called on every activateServer,
    /// so switching input source / focusing a terminal self-heals a dead tap.
    func ensureRunning() {
        guard Accessibility.isTrusted else { return }
        if let tap {
            if CGEvent.tapIsEnabled(tap: tap) { return }   // healthy
            CGEvent.tapEnable(tap: tap, enable: true)       // try a simple re-enable
            if CGEvent.tapIsEnabled(tap: tap) { return }
            teardown()                                      // dead port -> recreate
        }
        start()
    }

    private func teardown() {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        source = nil
        tap = nil
    }

    // Returning nil suppresses the key; returning the event passes it through.
    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)

        // The system disables a tap that is too slow or gets user input; re-enable.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
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

        // Our own synthesized output: never re-process it.
        if SyntheticKeyboard.isSynthetic(event) { return pass }

        guard imeActive else { return pass }

        // A ⌘/⌃/⌥ combo (⌘A select-all, ⌘C, ⌃C…) is never Telex input, and IMK does
        // NOT route ⌘-combos to the IMKit controller — so the controller cannot drop
        // its composition on its own (that was the "⌘A then type edits the old word
        // instead of replacing the selection" bug). The tap sees every key globally:
        // reset our engine AND signal the controller.
        // Runs for ALL apps, before the tap-mode gate.
        let flags = event.flags
        if flags.contains(.maskCommand) || flags.contains(.maskControl) || flags.contains(.maskAlternate) {
            engine.reset()
            NotificationCenter.default.post(name: .telexResetComposition, object: nil)
            return pass
        }

        // Decide whether the tap handles this app, and with which emit mode:
        //  - Spotlight (window-list) / Chromium → Shift+Left selection-replace.
        //  - MS Office → empty-char reset (Shift+Left would select adjacent cells).
        //  - Terminals (fallbackApps) → Backspace+retype.
        //  - Anything else → the IMKit in-place path handles it (pass through).
        let id = FrontmostApp.shared.bundleID
        if SpotlightDetector.isVisible {
            emitMode = .selection
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
            Signposts.poster.endInterval("tap.handle", spState, "\(mode)")
        }

        let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))

        if keyCode == kDelete {
            if engine.isEmpty { return pass }        // not composing -> real Backspace
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
            if engine.isEmpty { return pass }
            if emitBoundary(suppressAutoRestore: false) {
                reemit(keyCode: keyCode, string: nil)
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
            // Non-letter boundary. Brackets skip auto-restore (code context).
            emitBoundary(suppressAutoRestore: isBracketUnichar(buf[0]))
            reemit(keyCode: keyCode, string: String(ch))
            return nil
        }

        // EVERY key is suppressed and re-emitted through the one ordered synthetic
        // channel — never mix native passthrough with synthetic edits, or a later
        // native letter races ahead of an earlier synthetic tone edit ("nuwax" showed
        // as "nuẵ" because native 'a' landed before the synthetic ư from 'w').
        switch engine.feed(ch) {
        case .passthrough:
            SyntheticKeyboard.apply(backspaces: 0, insert: String(ch), mode: emitMode)
        case .none:
            break
        case let .replace(bs, insert):
            SyntheticKeyboard.apply(backspaces: bs, insert: insert, mode: emitMode)
        }
        return nil
    }

    /// Emit a shortcut expansion / auto-restore rewrite for the composed word. Returns
    /// true if anything was rewritten (caller then re-emits the boundary key after it).
    @discardableResult
    private func emitBoundary(suppressAutoRestore: Bool) -> Bool {
        guard !engine.isEmpty else { engine.reset(); return false }
        let word = engine.composed
        let onScreen = word.unicodeScalars.count
        if !word.isEmpty, let expansion = AppState.shared.shortcuts[word] {
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

    private func reemit(keyCode: Int, string: String?) {
        switch keyCode {
        case kReturn, kEnter: SyntheticKeyboard.postKey(CGKeyCode(kVK_Return))
        case kTab:            SyntheticKeyboard.postKey(CGKeyCode(kVK_Tab))
        case kEscape:         SyntheticKeyboard.postKey(CGKeyCode(kVK_Escape))
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
