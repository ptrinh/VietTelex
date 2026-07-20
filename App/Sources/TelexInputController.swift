// TelexInputController.swift
// IMKInputController driving TelexCore. NO marked text: each transform is committed
// as real text in place via insertText(_:replacementRange:), so the composing word
// is never underlined and the caret always stays at the end — the behaviour
// Vietnamese typists expect. The engine emits a
// minimal (backspaces, insert) diff; we turn it into an in-place replacement using
// the client's real selection.

import Cocoa
import InputMethodKit
import TelexCore
import Carbon.HIToolbox

private let kNoRange = NSRange(location: NSNotFound, length: 0)

// No explicit @objc name: the class is exposed to the Objective-C runtime as
// "VietTelex.TelexInputController" (module-qualified), which is exactly the string
// Info.plist's InputMethodServerControllerClass declares and what IMK resolves via
// NSClassFromString. An explicit @objc(TelexInputController) renamed it to a bare
// "TelexInputController", so the lookup returned nil and macOS never registered the
// input method.
final class TelexInputController: IMKInputController {

    private var engine = TelexEngine()

    // Virtual keycodes we treat as word boundaries (besides punctuation chars).
    private let kDelete: UInt16 = 51
    private let kReturn: UInt16 = 36
    private let kEnter: UInt16 = 76
    private let kTab: UInt16 = 48
    private let kEscape: UInt16 = 53

    // In-place editing without marked text needs to know where the composed word
    // lives. We track it locally — the composition occupies [anchor, anchor+onLen),
    // caret at the end — and read selectedRange() only ONCE per word (its first
    // key). Reading it after every insert is stale under fast typing and corrupts
    // words ("được" -> "đựoc").
    private var anchor = 0        // document offset where the composition starts
    private var onLen = 0         // UTF-16 length of the composition on screen
    private var tracking = false  // is anchor/onLen valid for the current word?
    private var selToClear = 0    // selection length to overwrite on the first insert

    // Consecutive failed in-place read-back probes per bundleID. A single failure is
    // usually the app being busy during the probe, not a real incompatibility, so we
    // require TWO in a row before condemning an app to marked text forever. In-memory
    // only (no persistence): a fresh launch re-probes from scratch, which is fine.
    private var probeFailures: [String: Int] = [:]

    // Last per-key routing decision logged (deduped): the strategy chosen in handle()
    // is logged only when it changes, so the debug log shows one line per app/mode
    // transition instead of one per keystroke.
    private var lastDecisionLog = ""
    private var lastEntryLog = ""
    private func logDecision(_ s: String) {
        guard s != lastDecisionLog else { return }
        lastDecisionLog = s
        DebugLog.log(s)
    }

    // Observes the mouse tap's reset signal: a click moved the caret, so drop any
    // composition (the tap can't reach this controller's private engine directly).
    private var resetObserver: NSObjectProtocol?

    // MARK: - Event handling (hot path)

    override func handle(_ event: NSEvent!, client sender: Any!) -> Bool {
        guard let event = event, event.type == .keyDown,
              let client = sender as? IMKTextInput else { return false }

        // Signpost the whole IMKit round trip; the end message names the strategy
        // that actually handled this key (see Instrumentation.swift).
        var spMode = "passthrough"
        let spState = Signposts.poster.beginInterval("imk.handle",
                                                     id: Signposts.poster.makeSignpostID())
        // privacy: .public — os_signpost redacts interpolated strings to "<private>"
        // by default, which collapses the per-strategy breakdown in xctrace exports.
        // The label is an internal strategy name, never user text.
        defer { Signposts.poster.endInterval("imk.handle", spState, "\(spMode, privacy: .public)") }

        // Our own terminal tap-mode output (synthetic Backspace / Unicode) loops back
        // through the input system. Pass it straight to the app WITHOUT re-feeding the
        // engine (a synthetic Backspace would otherwise re-enter as kDelete).
        // Confirm handle() is reached BEFORE the synthetic guard, and record whether
        // this real key is being mistaken for one of ours (isSynthetic) and why
        // (source pid vs our pid). Deduped per app so it's one line, not per-key.
        // Recognize OUR output by the magic userData only — NOT the posting pid.
        // Chromium/Electron (Slack, Lark) hand real keys to the IME stamped with our
        // pid, which the pid check dropped as synthetic (untypable Vietnamese).
        let synth = SyntheticKeyboard.isSyntheticMagic(event)
        let entryID = AppState.shared.currentBundleID ?? FrontmostApp.shared.bundleID ?? "?"
        if entryID != lastEntryLog {
            lastEntryLog = entryID
            let cg = event.cgEvent
            let srcPid = cg?.getIntegerValueField(.eventSourceUnixProcessID) ?? -1
            let ud = cg?.getIntegerValueField(.eventSourceUserData) ?? -1
            DebugLog.log("handle ENTER app=\(entryID) synthetic=\(synth) magic=\(ud == SyntheticKeyboard.magic) "
                + "srcPid=\(srcPid) myPid=\(getpid())")
        }

        if synth { return false }

        // Secure input active (password field, or an app holding secure input like
        // some chat apps): DROP the pending composition without rewriting it, then
        // pass through untouched. We must NOT call boundary() here: boundary runs
        // shortcut expansion / auto-restore via applyInPlace, i.e. an insertText into
        // the CURRENT client — now a password field — using a stale anchor from the
        // previous field, which would leak the old word into the secure input. A plain
        // engine drop is the only safe teardown. (endComposition is also wrong: its
        // marked-text branch finalizes with insertText(engine.composed), the very
        // injection we must avoid in a secure field.)
        if IsSecureEventInputEnabled() {
            logDecision("handle \(AppState.shared.currentBundleID ?? "?"): secure-input → discard (raw passthrough)")
            discardComposition(); return false
        }

        // Remote-desktop / VM / screen-share apps forward raw scancodes, so a
        // synthesized composition is wrong there — behave as if OFF (technical
        // necessity, kept even though there is no user VI/EN toggle any more).
        // Same reason as the secure-input branch: drop, never boundary()/rewrite —
        // the anchor belongs to the previous field, and this window forwards raw keys.
        if ClientPolicy.isRemoteDesktop(AppState.shared.currentBundleID) {
            logDecision("handle \(AppState.shared.currentBundleID ?? "?"): remote-desktop → discard (raw passthrough)")
            discardComposition(); return false
        }

        // Modifier combos (⌘⌃⌥) are never Telex input: finish and pass through.
        let mods = event.modifierFlags.intersection([.command, .control, .option])
        if !mods.isEmpty { endComposition(client); return false }

        // No internal enable/disable: if VietTelex is the active input source we always
        // compose. To type English, switch macOS input source (the OS remembers it
        // per app when "automatically switch" is on).

        // Decide tap-defer by the ACTUAL frontmost app — the SAME source the tap uses
        // (FrontmostApp cache) — not the IMK client id, which can be nil/stale. If the
        // client id is nil we'd otherwise think "unknown app → in-place" and wrongly
        // compose into a terminal the tap is handling; when the tap then leaks a
        // physical key (a brief tapDisabled window), IMKit composes it → intermittent
        // garbage in iTerm/Claude Code. Using the frontmost app keeps controller and
        // tap in sync.
        let frontID = FrontmostApp.shared.bundleID
        let id = AppState.shared.currentBundleID ?? frontID

        // Apps the CGEvent tap handles (terminals via Backspace, Chromium browsers &
        // Spotlight via Shift+Left selection-replace): the tap already intercepted and
        // synthesized these before the IME, so never compose here — let anything that
        // slipped through insert natively.
        if AppState.shared.usesTapMode(frontID) || AppState.shared.usesTapMode(id)
            || AppState.shared.usesSelectionReplace(frontID) || AppState.shared.usesSelectionReplace(id)
            || AppState.shared.usesEmptyReset(frontID) || AppState.shared.usesEmptyReset(id)
            || SpotlightDetector.isVisible {
            // NOTE: SpotlightDetector.isVisible defers UNCONDITIONALLY, even when the
            // tap is dormant (Accessibility not trusted / sandboxed build). That means
            // Spotlight typing gets raw passthrough with NO composition at all. This is
            // INTENTIONAL, not a bug: IMKit composing into Spotlight's inline
            // autocomplete corrupts the text, so raw passthrough is the lesser evil.
            // Do not "fix" this by gating on Accessibility.isTrusted.
            spMode = "tap-defer"
            logDecision("handle \(id ?? "?")/front=\(frontID ?? "?"): tap-defer "
                + "(tap=\(AppState.shared.usesTapMode(frontID) || AppState.shared.usesTapMode(id)) "
                + "sel=\(AppState.shared.usesSelectionReplace(frontID) || AppState.shared.usesSelectionReplace(id)) "
                + "empty=\(AppState.shared.usesEmptyReset(frontID) || AppState.shared.usesEmptyReset(id)) "
                + "spotlight=\(SpotlightDetector.isVisible))")
            return false
        }
        logDecision("handle \(id ?? "?")/front=\(frontID ?? "?"): "
            + "\(AppState.shared.usesMarkedText(id) ? "marked" : "in-place") "
            + "needsProbe=\(AppState.shared.needsProbe(id))")
        spMode = AppState.shared.usesMarkedText(id) ? "marked"
               : (tracking || engine.isEmpty ? "in-place" : "in-place-per-op")

        // Reflect the current "bỏ dấu tự do" setting before any engine op (feed,
        // backspace and boundary all re-parse `raw` and honor this flag).
        engine.freeMarking = AppState.shared.freeMarking
        engine.modernTone = AppState.shared.modernOrthography
        engine.liveSpellCheck = AppState.shared.liveSpellCheck
        engine.simpleTelex = AppState.shared.simpleTelex

        switch event.keyCode {
        case kDelete:
            if engine.isEmpty { return false }   // not composing -> normal delete
            let action = engine.backspace()
            if AppState.shared.usesMarkedText(id) { updateMarked(client); return true }
            if tracking {
                // Rewrite the whole composition via insertText (ordered, non-empty);
                // also handles tone re-placement on delete ("toán"->"tóa").
                let composed = engine.composed
                if composed.isEmpty {
                    // Last glyph gone: physical Backspace removes the remaining char
                    // (insertText("", range) is a no-op in some apps).
                    onLen = 0; tracking = false
                    return false
                }
                client.insertText(composed, replacementRange: NSRange(location: anchor, length: onLen))
                onLen = (composed as NSString).length
                return true
            }
            // Non-tracking (per-op selectedRange): apply the diff action.
            switch action {
            case let .replace(_, insert) where insert.isEmpty:
                return false                       // physical Backspace
            case let .replace(bs, insert):
                applyInPlace(bs: bs, insert: insert, client)   // tone re-place: "toán"->"tóa"
                return true
            default:
                return true
            }

        case kReturn, kEnter, kTab, kEscape:
            boundary(client); return false

        default:
            break
        }

        guard let chars = event.characters, let ch = chars.first,
              let ascii = ch.asciiValue, isAsciiLetter(ascii) else {
            // space / punctuation / any non-letter ends the word. Brackets signal a
            // code-ish context (arr[i], {json}, (x)); skip auto-restore there so a
            // token isn't "corrected" (auto-restore is off around [ ] { }).
            // The composed word itself is committed unchanged.
            let boundaryChar = event.characters?.utf8.first
            boundary(client, suppressAutoRestore: boundaryChar.map(isBracket) ?? false)
            return false
        }

        // First key of a new word: anchor the caret once (never again mid-word).
        // If the app can't report a caret here (some Electron apps: Claude), fall
        // back to per-op selectedRange (still in-place, no underline) rather than
        // forcing marked text. Only a failed probe pushes an app to marked text.
        if engine.isEmpty {
            let sel = client.selectedRange()
            if sel.location != NSNotFound {
                // A non-empty selection (e.g. after ⌘A) must be OVERWRITTEN by the
                // first key, not inserted-before. Remember its length and fold it
                // into the first insert's replacementRange below.
                anchor = sel.location; onLen = 0; tracking = true
                selToClear = sel.length
            } else {
                tracking = false; selToClear = 0
            }
        }

        let action = engine.feed(ch)
        if AppState.shared.usesMarkedText(id) { updateMarked(client); return true }
        switch action {
        case .passthrough:
            // Insert the letter ourselves (do NOT return false to let the system
            // insert it): mixing a system passthrough-insert with our insertText
            // transforms races under fast typing and corrupts words ("được"->"đựoc").
            // Every edit must go through the one ordered insertText channel.
            if tracking {
                client.insertText(String(ch), replacementRange: NSRange(location: anchor + onLen, length: selToClear))
                selToClear = 0
                onLen += 1
            } else {
                client.insertText(String(ch), replacementRange: kNoRange)
            }
            return true
        case .none:
            return true
        case let .replace(bs, insert):
            applyInPlace(bs: bs, insert: insert, client)
            return true
        }
    }

    // MARK: - In-place mode (default: no marked text, caret stays at end)

    /// Replace `bs` chars before the caret with `insert`, using our locally tracked
    /// position (no per-key selectedRange()). Unclassified apps are probed on the
    /// first real replace (read-back at the target region); apps that ignore
    /// replacementRange (Terminal) flip to marked text.
    private func applyInPlace(bs: Int, insert: String, _ client: IMKTextInput) {
        let id = AppState.shared.currentBundleID
        let start: Int
        // A pending selection (e.g. after ⌘A) must be overwritten by this first
        // replacement, exactly as the .passthrough branch does. selToClear is only set
        // while tracking; fold it into the replacementRange so the selection is removed
        // by the same insert, then clear it (a later insert must not re-scope to it).
        // On a first-key replace bs == 0, so start == anchor and the range is
        // (anchor, selToClear) — the whole selection. onLen must NOT subtract
        // selToClear: the selection was never part of the composition length, so
        // `onLen += insert.length - bs` stays correct after the removal.
        var clear = 0
        if tracking {
            start = anchor + onLen - bs
            clear = selToClear
            selToClear = 0
        } else {
            let sel = client.selectedRange()
            guard sel.location != NSNotFound, sel.location >= bs else {
                AppState.shared.markUsesMarkedText(id); engine.reset(); return
            }
            start = sel.location - bs
        }
        guard start >= 0 else {
            AppState.shared.markUsesMarkedText(id); engine.reset(); return
        }
        client.insertText(insert, replacementRange: NSRange(location: start, length: bs + clear))
        onLen += (insert as NSString).length - bs

        // Probe ONLY on a real, clean replacement (bs > 0, no pending selection).
        // A pure insert (bs == 0) lands identically whether or not the app honors
        // replacementRange, so it must never CONFIRM "in-place good" — that premature
        // confirm on a plain insert was the false-positive that locked iTerm2/WhatsApp
        // onto the broken in-place path. Only a replace distinguishes the two.
        if InPlaceProbe.shouldProbe(insertLength: (insert as NSString).length,
                                    bs: bs, clear: clear,
                                    needsProbe: AppState.shared.needsProbe(id)) {
            probeInPlace(inserted: insert, start: start, bs: bs, client)
        }
    }

    /// After a real in-place REPLACE into an unknown app, verify the old characters
    /// were actually replaced (not appended). Read back the region we targeted,
    /// `[start, start+len)`: a compliant app now holds `inserted` there; an app that
    /// ignored `replacementRange` (Terminal, iTerm2's CJK IMKit path, Catalyst) still
    /// holds the OLD characters. Because the engine strips the common prefix, the
    /// first char of `inserted` is guaranteed to differ from the old char at `start`,
    /// so this discriminates even on a 1-char window — unlike the old probe, which
    /// read back the text before the CARET (present in BOTH cases → false-positive).
    /// A failure switches the app to marked-text mode.
    private func probeInPlace(inserted: String, start: Int, bs: Int, _ client: IMKTextInput) {
        let len = (inserted as NSString).length
        // Primary signal: the post-edit caret (hard for an app to fake — it needs it
        // to place its candidate window). Fallback: the target-region read-back, used
        // only when the caret is unavailable (some apps echo it, so it must never
        // override a caret that says "appended").
        let sel = client.selectedRange()
        let caret: Int? = sel.location == NSNotFound ? nil : sel.location
        var region: String? = nil
        if start >= 0, let sub = client.attributedSubstring(from: NSRange(location: start, length: len)) {
            region = sub.string
        }
        let verdict = InPlaceProbe.verdict(caret: caret, start: start, bs: bs,
                                           insertLength: len, regionReadback: region,
                                           inserted: inserted)
        // Structural diagnostics only — never the typed text itself. `regionMatch`
        // is a bool (did the read-back equal what we inserted), not the content.
        DebugLog.log("probe \(AppState.shared.currentBundleID ?? "?"): start=\(start) bs=\(bs) len=\(len) "
            + "caret=\(caret.map(String.init) ?? "none") expReplace=\(start + len) expAppend=\(start + bs + len) "
            + "regionMatch=\(region.map { $0 == inserted ? "yes" : "no" } ?? "nil") → \(verdict)")
        let id = AppState.shared.currentBundleID
        switch verdict {
        case .honored:
            AppState.shared.markInPlaceGood(id)
            if let id { probeFailures[id] = nil }   // a good read clears the streak
        case .appended:
            // Don't condemn on a single failure (the app may just have been busy):
            // count consecutive failures and only switch to marked text on the 2nd.
            // Either way abandon the glitched word so it doesn't linger half-written;
            // on the first failure leave the app UNCLASSIFIED so the next word re-probes.
            if let id {
                let n = (probeFailures[id] ?? 0) + 1
                if n >= 2 {
                    probeFailures[id] = nil
                    AppState.shared.markUsesMarkedText(id)
                } else {
                    probeFailures[id] = n
                }
            } else {
                AppState.shared.markUsesMarkedText(id)
            }
            engine.reset()
            tracking = false
        }
    }

    // MARK: - Marked-text mode (fallback for Terminal-like apps)

    /// Show the composed syllable as marked text, caret at the end. Reliable in apps
    /// that ignore in-place replacementRange; shows a brief underline while composing.
    private func updateMarked(_ client: IMKTextInput) {
        let s = engine.composed
        let caret = NSRange(location: (s as NSString).length, length: 0)
        client.setMarkedText(s, selectionRange: caret, replacementRange: kNoRange)
    }

    // MARK: - Word boundary (shortcuts + auto-restore), then reset

    /// Commit the pending word AND fully tear down the IME composition session
    /// before a shortcut is forwarded. In marked-text apps (Electron/Claude) a
    /// still-open composition swallows ⌘-shortcuts — ⌘A "select all" did nothing
    /// while a word was composing. Clearing the marked text explicitly after the
    /// commit ends the session so the shortcut reaches the app.
    /// A modifier combo (⌘A, ⌃…) arrived mid-word:
    /// drop the composition with NO auto-restore and NO shortcut expansion —
    /// leave the word EXACTLY as composed — then let the shortcut key pass through.
    /// In-place text is already on screen (we insert every key), so a reset suffices;
    /// marked text isn't real yet, so finalize it to the composed word first.
    private func endComposition(_ client: IMKTextInput) {
        if !engine.isEmpty, AppState.shared.usesMarkedText(AppState.shared.currentBundleID) {
            client.insertText(engine.composed, replacementRange: kNoRange)
            client.setMarkedText("", selectionRange: kNoRange, replacementRange: kNoRange)
        }
        engine.reset()
        tracking = false
        onLen = 0
    }

    /// Tear the composition down WITHOUT any rewrite, insertText, or setMarkedText —
    /// used at boundaries where touching the client is unsafe (secure input, remote
    /// desktop): the anchor may belong to a previous field and the target window must
    /// not receive injected text. Unlike endComposition this never finalizes marked
    /// text (no insertText(composed)); unlike boundary it never expands shortcuts or
    /// auto-restores. Whatever was already on screen stays as-is; the engine forgets it.
    private func discardComposition() {
        engine.reset()
        tracking = false
        onLen = 0
    }

    private func boundary(_ client: IMKTextInput, suppressAutoRestore: Bool = false) {
        defer { tracking = false; onLen = 0 }
        guard !engine.isEmpty else { engine.reset(); return }
        let marked = AppState.shared.usesMarkedText(AppState.shared.currentBundleID)
        let word = engine.composed
        // Raw keystrokes must be read BEFORE engine.reset() clears them. A shortcut key
        // that contains Telex triggers (s f r x j w, doubled vowels) never survives
        // composition — "vn"→"vn" but "cf" composes away — so a shortcut whose key IS
        // the raw form could never match on `word` alone.
        let rawWord = engine.rawKeystrokes
        let onScreen = word.unicodeScalars.count

        // Shortcut expansion (bảng gõ tắt) takes precedence over the composed word.
        // Try the composed word first, then fall back to the raw keystrokes so a
        // shortcut key containing trigger letters still matches. On-screen backspace
        // count stays `onScreen` (the composed scalar count) either way.
        if !word.isEmpty,
           let expansion = AppState.shared.shortcuts[word] ?? AppState.shared.shortcuts[rawWord] {
            engine.reset()
            if marked { client.insertText(expansion, replacementRange: kNoRange) }
            else { applyInPlace(bs: onScreen, insert: expansion, client) }
            return
        }

        // Auto-restore non-Vietnamese words to their raw keystrokes (resets engine).
        // Suppressed next to brackets (code context).
        let autoRestore = AppState.shared.autoRestore && !suppressAutoRestore
        let restored = engine.commitText(autoRestore: autoRestore)
        if marked {
            // Commit the marked text (replaces it with the final word).
            client.insertText(restored, replacementRange: kNoRange)
        } else if restored != word {
            applyInPlace(bs: onScreen, insert: restored, client)
        }
    }

    // MARK: - IMK lifecycle

    override func activateServer(_ sender: Any!) {
        super.activateServer(sender)
        engine.reset()
        tracking = false
        if let client = sender as? IMKTextInput {
            AppState.shared.currentBundleID = client.bundleIdentifier()
            maybePromptAccessibility(AppState.shared.currentBundleID)
        }
        // VietTelex is the active input source now: let the terminal tap act (it must
        // stay dormant when the user switches to ABC/US). ensureRunning() also revives
        // a tap that died (Accessibility toggled off/on invalidates the mach port), so
        // focusing a terminal / re-selecting the source self-heals it.
        TerminalTapController.shared.markActive()
        TerminalTapController.shared.ensureRunning()

        if resetObserver == nil {
            // queue: nil → runs synchronously on the poster's thread (the tap's main-
            // thread callback), so the reset lands BEFORE the next key is handled.
            resetObserver = NotificationCenter.default.addObserver(
                forName: .telexResetComposition, object: nil, queue: nil) { [weak self] _ in
                self?.engine.reset()
                self?.tracking = false
                self?.onLen = 0
            }
        }
    }

    override func commitComposition(_ sender: Any!) {
        if let client = sender as? IMKTextInput {
            boundary(client)
        } else {
            engine.reset()
            tracking = false
        }
    }

    override func deactivateServer(_ sender: Any!) {
        engine.reset()
        tracking = false
        if let obs = resetObserver { NotificationCenter.default.removeObserver(obs); resetObserver = nil }
        // Input source switched away from VietTelex (or focus lost): the tap must not
        // transform keys, so the user really types English in terminals. BUT with
        // per-document input switching, IMK can call this on a stale client AFTER the
        // newly focused client's activateServer — so only turn the tap off if VietTelex
        // is genuinely no longer the OS-selected source (else we'd clobber the fresh
        // activate and typing would pass through until a focus cycle; see IMEActivation).
        TerminalTapController.shared.markInactive(stillSelected: Self.isVietTelexSelected())
        super.deactivateServer(sender)
    }

    /// True when the CURRENTLY selected keyboard input source is VietTelex — the single
    /// source of truth the flaky activate/deactivate ordering must defer to. Called
    /// only on lifecycle transitions / TIS notifications, never on the keystroke hot
    /// path, so the Carbon TIS copy is fine here. Matches both the input source and its
    /// `.vi` input mode by bundle-id prefix.
    static func isVietTelexSelected() -> Bool {
        guard let src = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let ptr = TISGetInputSourceProperty(src, kTISPropertyInputSourceID) else { return false }
        let id = Unmanaged<CFString>.fromOpaque(ptr).takeUnretainedValue() as String
        return id.hasPrefix("com.viettelex.inputmethod.telex")
    }

    // MARK: - Input-method menu (IMK-provided, no NSStatusItem)

    override func menu() -> NSMenu! {
        let menu = NSMenu(title: "VietTelex")
        // macOS appends a standard "Edit Text Substitutions…" item to input-method
        // menus. Strip it (and any trailing separator) each time the menu opens.
        menu.delegate = self

        // Status first. OK when Accessibility is granted (terminal tap works), else
        // missing. No checkmark. Click → grant-permission pane if missing, else a debug log.
        let status = NSMenuItem(title: Accessibility.isTrusted ? VTLocalized("Status: OK") : VTLocalized("Status: Permission needed"),
                                action: #selector(showStatus(_:)), keyEquivalent: "")
        status.target = self
        menu.addItem(status)

        // Everything else lives in the Settings window (Chung + Gõ tắt tabs). The menu
        // stays minimal: status + Settings.
        let settings = NSMenuItem(title: VTLocalized("Settings…"), action: #selector(openSettings(_:)), keyEquivalent: "")
        settings.target = self
        menu.addItem(settings)

        return menu
    }


    @objc private func openSettings(_ sender: Any?) {
        SettingsWindowController.shared.show(tab: .general)
    }

    @objc private func showStatus(_ sender: Any?) {
        // Defer to the next runloop tick: the input-method menu is still dismissing
        // when this fires, and running an NSAlert modal synchronously from that context
        // in a background (accessory) agent doesn't surface the window. Async + activate
        // makes it appear reliably.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if Accessibility.isTrusted { self.showDebugLog() }
            else { self.grantAccessibility() }
        }
    }

    /// One-time gentle prompt: the user just focused an app that needs the event tap
    /// (terminal-class / Chromium / Excel) but Accessibility is missing — exactly the
    /// moment typing would misbehave. Otherwise the permission is only discoverable
    /// through the input-method menu. Shown once ever (axPromptShown).
    private func maybePromptAccessibility(_ id: String?) {
        guard !AppState.shared.axPromptShown,
              AppState.shared.wantsAccessibility(id),
              !Accessibility.isTrusted else { return }
        AppState.shared.axPromptShown = true
        DispatchQueue.main.async { [weak self] in
            self?.grantAccessibility()
        }
    }

    /// Missing permission: show OUR explanatory popup. We deliberately do NOT call
    /// `AXIsProcessTrustedWithOptions(prompt:)` here — that fires the system TCC
    /// dialog too, so clicking the status opened Settings AND our popup at once. The
    /// popup's "Mở Cài đặt" button opens the Accessibility pane on demand instead.
    private func grantAccessibility() {
        NSApp.setActivationPolicy(.regular)
        let alert = NSAlert()
        alert.messageText = VTLocalized("Accessibility permission needed")
        alert.informativeText = VTLocalized("VietTelex needs Accessibility to type Vietnamese in Terminal/iTerm and browsers.\n\nOpen System Settings → Privacy & Security → Accessibility and enable VietTelex (if it’s already there, untick then tick it again).")
        alert.addButton(withTitle: VTLocalized("Open Settings"))
        alert.addButton(withTitle: VTLocalized("Close"))
        // We're an accessory (agent) app, so a plain runModal() can open the alert
        // BEHIND the frontmost app — the user then has to click our Dock icon to find
        // it (the reported bug). Activate the app AND force the alert window frontmost
        // (float level + orderFrontRegardless) right before running it modally.
        NSApp.activate(ignoringOtherApps: true)
        alert.window.level = .floating
        alert.window.orderFrontRegardless()
        alert.window.makeKeyAndOrderFront(nil)
        let resp = alert.runModal()
        if resp == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
        NSApp.setActivationPolicy(.accessory)
    }

    /// Permission OK: show a debug snapshot of the runtime state.
    private func showDebugLog() {
        let id = AppState.shared.currentBundleID ?? "?"
        let mode: String
        if AppState.shared.usesSelectionReplace(id) { mode = "tap · selection-replace (Chromium)" }
        else if AppState.shared.usesTapMode(id) { mode = "tap · backspace (terminal)" }
        else if AppState.shared.usesMarkedText(id) { mode = "IMKit · marked text" }
        else { mode = "IMKit · in-place" }
        let s = AppState.shared
        let lines = [
            "Accessibility: \(Accessibility.isTrusted ? "OK" : "thiếu")",
            "Terminal tap: \(TerminalTapController.shared.isRunning ? "đang chạy" : "tắt")",
            "Spotlight đang mở: \(SpotlightDetector.isVisible ? "có" : "không")",
            "App hiện tại: \(id)",
            "Cách xử lý: \(mode)",
            "",
            "Simple Telex: \(s.simpleTelex ? "bật" : "tắt")",
            "Bỏ dấu tự do: \(s.freeMarking ? "bật" : "tắt")",
            "Bỏ dấu kiểu mới: \(s.modernOrthography ? "bật" : "tắt")",
            "Kiểm tra chính tả khi gõ: \(s.liveSpellCheck ? "bật" : "tắt")",
            "Tự khôi phục: \(s.autoRestore ? "bật" : "tắt")",
        ]
        // No popup — just copy the debug snapshot to the clipboard so the user can
        // paste it straight away (typing is unreliable when something's wrong).
        let text = lines.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

}

extension TelexInputController: NSMenuDelegate {
    // Remove the system-appended "Edit Text Substitutions…" item (+ dangling
    // separator). Try both hooks: menuNeedsUpdate (early) and menuWillOpen (right
    // before display, after the system has appended its items).
    func menuNeedsUpdate(_ menu: NSMenu) { stripSystemItems(menu) }
    func menuWillOpen(_ menu: NSMenu) { stripSystemItems(menu) }

    private func stripSystemItems(_ menu: NSMenu) {
        let subs = Selector(("orderFrontSubstitutionsPanel:"))
        for item in menu.items where item.action == subs || item.title.localizedCaseInsensitiveContains("substitution") {
            menu.removeItem(item)
        }
        while let last = menu.items.last, last.isSeparatorItem {
            menu.removeItem(last)
        }
    }
}

@inline(__always)
private func isAsciiLetter(_ c: UInt8) -> Bool {
    (c >= UInt8(ascii: "a") && c <= UInt8(ascii: "z")) ||
    (c >= UInt8(ascii: "A") && c <= UInt8(ascii: "Z"))
}

@inline(__always)
private func isBracket(_ c: UInt8) -> Bool {
    switch c {
    case UInt8(ascii: "["), UInt8(ascii: "]"),
         UInt8(ascii: "{"), UInt8(ascii: "}"),
         UInt8(ascii: "("), UInt8(ascii: ")"):
        return true
    default:
        return false
    }
}
