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
    private var anchorVerified = false  // one-shot re-anchor done for this word?

    // Consecutive failed in-place read-back probes per bundleID. A single failure is
    // usually the app being busy during the probe, not a real incompatibility, so we
    // require TWO in a row before condemning an app to marked text forever. In-memory
    // only (no persistence): a fresh launch re-probes from scratch, which is fine.
    private var probeFailures: [String: Int] = [:]

    // Pending SELF-REPORTED honored confirmations per bundleID: in-place is committed
    // only after honored probes at two DISTINCT expected-caret offsets (a constant
    // garbage caret — Lark reports 1, always — can coincide with one offset but never
    // two). AX-backed honored verdicts skip this and commit immediately. In-memory
    // only, like probeFailures.
    private var probeHonors: [String: InPlaceProbe.HonorTracker] = [:]

    // (Session-field probation was tried here and REMOVED by decision 2026-07-21:
    // without Accessibility there is no field identity, so every focus change
    // re-probed at the cost of 1-2 glitched words — field-tested as "không ổn".
    // The no-AX policy is now simply: known-good in-place apps stay in-place,
    // everything else is marked text, no probing. See AppState.usesMarkedText.)

    // Last per-key routing decision logged (deduped): the strategy chosen in handle()
    // is logged only when it changes, so the debug log shows one line per app/mode
    // transition instead of one per keystroke.
    private var lastDecisionLog = ""
    private var lastEntryLog = ""
    private func logDecision(_ message: @autoclosure () -> String) {
        // @autoclosure: the interpolated string must NOT be built per keystroke when
        // logging is off — these sit on the hot path (an eager String parameter was
        // allocating+formatting on every key).
        guard AppState.shared.debugLogging else { return }
        let s = message()
        // Dedup keeps the ring readable in normal use, but hides the per-key picture
        // during diagnosis — while the debug flag is on, log EVERY decision (400
        // ring lines is plenty for a short repro).
        lastDecisionLog = s
        DebugLog.log(s)
    }

    // Observes the mouse tap's reset signal: a click moved the caret, so drop any
    // composition (the tap can't reach this controller's private engine directly).
    private var resetObserver: NSObjectProtocol?

    // One-shot dump of every TSM hilite style's attribute dict (experiment 3).
    private static var dumpedHiliteDicts = false

    // EXPERIMENT (log-only, gated on debugLogging): deferred re-probe context.
    // Chromium-class apps (Lark) serve AX from an ASYNC browser-side cache that is
    // built lazily on first query — the synchronous read inside probeInPlace can race
    // a stale/optimistic tree, which is the suspected cause of Lark "faking" every
    // probe signal. On the NEXT keyDown (hundreds of ms later, tree settled) re-read
    // the same region + the field length and log whether the verdict would change.
    // Never alters classification — data gathering for a future deferred verdict.
    private var pendingReprobe: (id: String?, start: Int, len: Int, bs: Int,
                                 inserted: String, verdict: InPlaceProbe.Verdict)?

    // Per-FOCUS re-verification of learned-in-place apps (tester log 2026-07-23).
    // Classification is per APP, but Chromium-class apps host many editors: one
    // site honors replacementRange, the next (EditContext-style) APPENDS — and a
    // learned-good app was never probed again, so that field stayed broken until
    // a reload ("gõ không ra gì / tự bôi đen rồi replace"). One verify probe per
    // focus; a failure demotes to marked text for THIS focus only (the global
    // per-app classification is untouched). Both reset on activateServer and on
    // the click/⌘-combo reset notification — the focus anchors we actually get
    // from Chromium, which reports the whole window as one IMK client.
    private var fieldVerified = false
    private var fieldForcedMarked = false

    /// Effective marked-text decision for the CURRENT field: a per-focus demotion
    /// (verify probe failed here) wins over the per-app classification.
    private func usesMarkedNow(_ id: String?) -> Bool {
        fieldForcedMarked || AppState.shared.usesMarkedText(id)
    }

    // MARK: - Event handling (hot path)

    /// Also receive flagsChanged (default is keyDown only): the composition is
    /// committed the moment a ⌘/⌃/⌥ MODIFIER is pressed — see handle() below.
    override func recognizedEvents(_ sender: Any!) -> Int {
        Int(NSEvent.EventTypeMask.keyDown.union(.flagsChanged).rawValue)
    }

    override func handle(_ event: NSEvent!, client sender: Any!) -> Bool {
        guard let event = event else { return false }

        // A ⌘/⌃/⌥ modifier just went DOWN: end any composition NOW, one event cycle
        // BEFORE the shortcut's letter arrives. Committing inside the same cycle as
        // the combo (the old approach) lost the first press — the app swallows a key
        // equivalent delivered while its IME session is open/closing (⌘A while
        // composing did nothing; after the fix for that, the FIRST ⌘A/⌥⌫ still
        // needed a second press). The modifier physically precedes the letter by
        // ~50-100ms, so by the time ⌘A is delivered the session has long been torn
        // down and the app handles it immediately. Side effect (accepted): tapping a
        // lone modifier mid-word finalizes the word.
        if event.type == .flagsChanged {
            if !event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
               !engine.isEmpty, let client = sender as? IMKTextInput {
                logDecision("modifier down mid-composition → early commit")
                endComposition(client)
            }
            return false
        }

        guard event.type == .keyDown,
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
        if entryID != lastEntryLog || AppState.shared.debugLogging {   // no dedupe while debugging
            lastEntryLog = entryID
            let cg = event.cgEvent
            let srcPid = cg?.getIntegerValueField(.eventSourceUnixProcessID) ?? -1
            let ud = cg?.getIntegerValueField(.eventSourceUserData) ?? -1
            DebugLog.log("handle ENTER app=\(entryID) synthetic=\(synth) magic=\(ud == SyntheticKeyboard.magic) "
                + "srcPid=\(srcPid) myPid=\(getpid())")
        }

        if synth { return false }

        // A real key reaching handle() proves VietTelex is the selected source —
        // un-latch a stale imeActive=false so tap-mode apps aren't left dormant
        // (see noteIMKKeyProvesSelected).
        TerminalTapController.shared.noteIMKKeyProvesSelected()

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

        // Passthrough resolution. Manual .passthrough = unconditional IME-off for the
        // app. Remote-desktop / VM / screen-share apps (built-in list) forward raw
        // scancodes for the SESSION canvas — but their OWN chrome (PC-name field,
        // search box) is ordinary text input, so with Accessibility we compose there:
        // only when the focused element's AX role is a real text input; unsure →
        // passthrough (composing into the canvas would type garbage into the guest
        // OS, while the reverse merely loses Vietnamese in a name field).
        // Same as the secure-input branch: drop, never boundary()/rewrite — the
        // anchor belongs to the previous field, and this window forwards raw keys.
        let earlyID = AppState.shared.currentBundleID
        let earlyManual = AppState.shared.manualMode(earlyID)
        if earlyManual == .passthrough {
            logDecision("handle \(earlyID ?? "?"): manual passthrough → discard (raw)")
            discardComposition(); return false
        }
        if earlyManual == nil,
           ClientPolicy.isRemoteDesktop(earlyID)
               || earlyID.map({ AppState.builtInPassthroughApps.contains($0) }) == true,
           !(Accessibility.isTrusted && FocusedFieldDetector.isTextInput) {
            logDecision("handle \(earlyID ?? "?"): remote-desktop → discard (raw passthrough)")
            discardComposition(); return false
        }

        // EXPERIMENT (log-only): deferred re-probe of the previous keystroke's edit,
        // now that the app's AX tree has had time to settle. See `pendingReprobe`.
        if let p = pendingReprobe {
            pendingReprobe = nil
            reprobeDeferred(p, client)
        }

        // Modifier combos (⌘⌃⌥) are never Telex input: finish and pass through.
        let mods = event.modifierFlags.intersection([.command, .control, .option])
        if !mods.isEmpty {
            // Modifier+Delete while a MARKED composition is open: committing and
            // passing the key loses the FIRST press — the just-closing composition
            // session swallows it (Terminal: "goo" → gô, Option+Delete needed two
            // presses to kill the word). The word those shortcuts delete backward IS
            // the composition, so consume the key and kill the composition directly:
            // same net effect, single press. In-place mode has no composition session
            // (text is already real), so it keeps the normal commit-and-pass path.
            if event.keyCode == kDelete, !engine.isEmpty,
               usesMarkedNow(AppState.shared.currentBundleID) {
                client.setMarkedText("", selectionRange: kNoRange, replacementRange: kNoRange)
                engine.reset()
                tracking = false
                spMode = "marked"
                logDecision("marked composition killed by modifier+Delete (single press)")
                return true
            }
            endComposition(client); return false
        }

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
        // Spotlight types IN-PLACE by default (field-verified clean on macOS 26,
        // even with the gray inline suggestion — the historical autocomplete race
        // that forced tap selection-replace is gone; it's in builtInInPlaceApps).
        // Only an explicit tap-family manual pick still routes it to the tap.
        // ORDER MATTERS for CPU: consult the manual pin FIRST — isVisible kicks a
        // CGWindowList background scan every 200ms while typing, which nobody needs
        // unless Spotlight was explicitly pinned to a tap-family mode (rare).
        let spotlightManual = AppState.shared.manualMode(AppState.spotlightBundleID)
        let spotlightDefersToTap = (spotlightManual == .selection
                || spotlightManual == .tap || spotlightManual == .emptyReset)
            && SpotlightDetector.isVisible
        if AppState.shared.usesTapMode(frontID) || AppState.shared.usesTapMode(id)
            || AppState.shared.usesSelectionReplace(frontID) || AppState.shared.usesSelectionReplace(id)
            || AppState.shared.usesEmptyReset(frontID) || AppState.shared.usesEmptyReset(id)
            || spotlightDefersToTap {
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
            + "\(usesMarkedNow(id) ? "marked" : "in-place") "
            + "needsProbe=\(AppState.shared.needsProbe(id))")
        spMode = usesMarkedNow(id) ? "marked"
               : (tracking || engine.isEmpty ? "in-place" : "in-place-per-op")

        // Reflect the current "bỏ dấu tự do" setting before any engine op (feed,
        // backspace and boundary all re-parse `raw` and honor this flag).
        engine.freeMarking = AppState.shared.freeMarking
        engine.modernTone = AppState.shared.modernOrthography
        engine.liveSpellCheck = AppState.shared.liveSpellCheck
        engine.simpleTelex = AppState.shared.simpleTelex
        engine.quickTelex = AppState.shared.quickTelex

        switch event.keyCode {
        case kDelete:
            if engine.isEmpty { return false }   // not composing -> normal delete
            let action = engine.backspace()
            if usesMarkedNow(id) { updateMarked(client); return true }
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
            // KNOWN LIMITATION — while a MARKED composition is open in a terminal,
            // the first boundary press only commits; the second acts ("vậy⏎⏎").
            // Tried and closed (2026-07-21): delivering the key's byte through
            // insertText after the commit — Terminal STRIPS control characters
            // (\r, \n, \t, ESC) from IME-inserted text (paste-bracketing-style
            // sanitizing; branch fired in logs, nothing reached the pty). This
            // two-press behavior is also standard CJK composition UX. Single-press
            // Enter in terminals is what the TAP path provides — grant Accessibility.
            let rewrote = boundary(client)
            // When the commit REWROTE the word (gõ tắt "ko"→"không", auto-restore
            // "thooiiii"), web-view editors (WhatsApp) apply that insertText
            // asynchronously — an immediately-delivered Return fires "send" on the
            // OLD text. With Accessibility we swallow the real key and re-post a
            // stamped COPY of it (HID source intact) so it lands AFTER the edit;
            // the copy re-enters handle() with an empty engine and passes through.
            if rewrote, Accessibility.isTrusted, let cg = event.cgEvent {
                SyntheticKeyboard.postBoundaryCopy(of: cg)
                return true
            }
            return false

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
                anchorVerified = false
                selToClear = sel.length
            } else {
                tracking = false; selToClear = 0
            }
        }

        let action = engine.feed(ch)
        if usesMarkedNow(id) { updateMarked(client); return true }
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
            // One-shot RE-ANCHOR at the word's first replace. Right after a newline
            // (Discord/Slate-class editors) the word-start selectedRange read is
            // STALE — it still reports the pre-newline caret, so the anchor is short
            // and the first tone edit writes into the wrong spot ("thử" typed on a
            // fresh line came out "thuử"). By the first replace the editor has
            // settled, so re-read once; trust the fresh caret ONLY when it is
            // FURTHER RIGHT than expected — a smaller read is the old fast-typing
            // staleness ("được"→"đựoc") that the once-per-word anchor exists to
            // ignore.
            if !anchorVerified {
                anchorVerified = true
                let fresh = client.selectedRange()
                let expected = anchor + onLen
                if fresh.location != NSNotFound, fresh.location > expected {
                    DebugLog.log("re-anchor \(id ?? "?"): stale word-start caret, +\(fresh.location - expected)")
                    anchor += fresh.location - expected
                }
            }
            start = anchor + onLen - bs
            clear = selToClear
            selToClear = 0
        } else {
            let sel = client.selectedRange()
            guard sel.location != NSNotFound, sel.location >= bs else {
                // The key is consumed with NOTHING inserted — if an app lands here on
                // every keystroke, typing shows nothing at all. Log it loudly.
                DebugLog.log("in-place ABORT \(id ?? "?"): selectedRange=\(sel.location == NSNotFound ? "NotFound" : String(sel.location)) bs=\(bs) → marked next word, key swallowed")
                inPlaceFailedHard(id); return
            }
            start = sel.location - bs
        }
        guard start >= 0 else {
            DebugLog.log("in-place ABORT \(id ?? "?"): start=\(start) < 0, key swallowed")
            inPlaceFailedHard(id); return
        }
        client.insertText(insert, replacementRange: NSRange(location: start, length: bs + clear))
        onLen += (insert as NSString).length - bs

        // Probe ONLY on a real, clean replacement (bs > 0, no pending selection).
        // A pure insert (bs == 0) lands identically whether or not the app honors
        // replacementRange, so it must never CONFIRM "in-place good" — that premature
        // confirm on a plain insert was the false-positive that locked iTerm2/WhatsApp
        // onto the broken in-place path. Only a replace distinguishes the two.
        let realProbe = InPlaceProbe.shouldProbe(insertLength: (insert as NSString).length,
                                                 bs: bs, clear: clear,
                                                 needsProbe: AppState.shared.needsProbe(id))
        // EXPERIMENT: with debugLogging on, also SHADOW-probe apps that are already
        // classified (or manually pinned to in-place) — same reads, same logs, but the
        // verdict is never acted on. This is how the deferred re-probe can be exercised
        // against Lark (pin it to In-place in Thử Nghiệm → App mode, enable Debug
        // logging, type a few tone edits, copy the log).
        // Per-focus VERIFY of a learned-in-place app: the first real replacement in
        // each focus re-checks that THIS field honors replacementRange (sites inside
        // one browser differ — see fieldVerified). Passive on good fields (read-only
        // probe of an edit that already happened); a failure demotes this focus to
        // marked text. This is NOT the removed 2026-07-21 session-field probation:
        // unknown apps aren't re-probed per focus — only apps already classified
        // in-place-good get a read-back check, so good fields never glitch.
        let verifyProbe = !realProbe && !fieldVerified
            && AppState.shared.isLearnedInPlace(id)
            && InPlaceProbe.shouldProbe(insertLength: (insert as NSString).length,
                                        bs: bs, clear: clear, needsProbe: true)
        let shadowProbe = !realProbe && !verifyProbe && AppState.shared.debugLogging
            && InPlaceProbe.shouldProbe(insertLength: (insert as NSString).length,
                                        bs: bs, clear: clear, needsProbe: true)
        if realProbe || verifyProbe || shadowProbe {
            probeInPlace(inserted: insert, start: start, bs: bs, client,
                         kind: realProbe ? .real : (verifyProbe ? .verify : .shadow))
        }
    }

    /// In-place aborted before inserting anything (bogus selectedRange): condemn the
    /// app to marked text (persisted) and abandon the composition.
    private func inPlaceFailedHard(_ id: String?) {
        AppState.shared.markUsesMarkedText(id)
        engine.reset()
        tracking = false
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
    /// Serial queue for the probe's Accessibility ground-truth read. The AX call has
    /// a 50ms messaging timeout — running it synchronously inside probeInPlace put a
    /// potential 50ms stall on the keystroke that probes a new app. The verdict only
    /// affects FUTURE keystrokes, so the read is inherently deferrable. Deferring is
    /// also MORE accurate: Chromium-class apps build their AX tree lazily/async, so a
    /// T+0 read races a stale cache (measured — the Lark experiment) while a read a
    /// beat later sees the settled tree.
    private static let axProbeQueue = DispatchQueue(label: "com.viettelex.ax-probe", qos: .userInitiated)

    /// How a probe's verdict is applied: `.real` classifies the app (persisted),
    /// `.shadow` only logs (debugLogging experiment).
    private enum ProbeKind { case real, verify, shadow }

    private func probeInPlace(inserted: String, start: Int, bs: Int, _ client: IMKTextInput,
                              kind: ProbeKind) {
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
        // PRELIMINARY verdict from the self-reported signals only. The Accessibility
        // ground-truth read happens ASYNC below and can override this verdict when it
        // lands (axProbeQueue doc above) — it never blocks the keystroke.
        let verdict = InPlaceProbe.verdict(axRegion: nil, caret: caret, start: start, bs: bs,
                                           insertLength: len, regionReadback: region,
                                           inserted: inserted)
        // Structural diagnostics only — never the typed text itself. `regionMatch`
        // is a bool (did the read-back equal what we inserted), not the content.
        DebugLog.log("probe\(kind == .shadow ? "(shadow)" : (kind == .verify ? "(verify)" : "")) \(AppState.shared.currentBundleID ?? "?"): "
            + "start=\(start) bs=\(bs) len=\(len) "
            + "caret=\(caret.map(String.init) ?? "none") expReplace=\(start + len) expAppend=\(start + bs + len) "
            + "regionMatch=\(region.map { $0 == inserted ? "yes" : "no" } ?? "nil") → \(verdict)")
        let id = AppState.shared.currentBundleID
        // EXPERIMENT: arm the deferred re-read for the next keyDown (debugLogging only —
        // the extra AX calls must never run on a stock hot path).
        if AppState.shared.debugLogging {
            pendingReprobe = (id, start, len, bs, inserted, verdict)
        }

        // Async ground-truth read. Fired for shadow probes too (log-only there).
        Self.axProbeQueue.async { [weak self] in
            let axRegion = AXTextEdit.readString(at: start, length: len)
            guard axRegion != nil else { return }   // AX unavailable → preliminary stands
            DispatchQueue.main.async {
                self?.applyAXVerdict(axRegion: axRegion, inserted: inserted, id: id, kind: kind)
            }
        }

        switch kind {
        case .shadow:
            // Data-gathering only: log + arm the re-read, never touch the
            // classification or the engine.
            return
        case .verify:
            // One verify per focus regardless of outcome; a demotion is sticky for
            // the focus anyway, and re-probing every key would pay the reads for
            // nothing.
            fieldVerified = true
            if verdict == .appended {
                fieldForcedMarked = true
                DebugLog.log("verify: field ignored replacementRange → marked text for this focus")
                engine.reset()
                tracking = false
            }
        case .real:
            applyPreliminaryVerdict(verdict, id: id, expReplace: start + len)
        }
    }

    /// Classification from the SELF-REPORTED signals (caret / read-back) — the part
    /// that must never lock an app in on thin evidence. Honored commits only after two
    /// confirmations at DISTINCT offsets (Lark's constant garbage caret reads honored
    /// whenever expReplace coincides with it — see InPlaceProbe.HonorTracker); appended
    /// needs two in a row (a single failure may just be the app being busy).
    private func applyPreliminaryVerdict(_ verdict: InPlaceProbe.Verdict, id: String?, expReplace: Int) {
        switch verdict {
        case .honored:
            if let id {
                var tracker = probeHonors[id] ?? InPlaceProbe.HonorTracker()
                if tracker.recordHonored(expReplace: expReplace) {
                    AppState.shared.markInPlaceGood(id)
                    probeHonors[id] = nil
                } else {
                    probeHonors[id] = tracker   // keep probing until a distinct offset confirms
                }
                probeFailures[id] = nil         // a good read clears the streak
            }
        case .appended:
            // A failure also voids any half-collected honored confirmation: the next
            // honored (if any) must start the two-distinct-offsets count over.
            if let id {
                probeHonors[id] = nil
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

    /// The deferred Accessibility ground truth landed (main thread). It is
    /// authoritative: it reports the field's REAL content independent of the app's
    /// IMKit self-report, and it read the tree after it settled. It overrides whatever
    /// the preliminary verdict did — including un-committing an in-place promotion.
    private func applyAXVerdict(axRegion: String?, inserted: String, id: String?, kind: ProbeKind) {
        let match = axRegion == inserted
        DebugLog.log("probe(ax\(kind == .shadow ? "·shadow" : (kind == .verify ? "·verify" : ""))) \(id ?? "?"): axMatch=\(match ? "yes" : "no")")
        guard kind != .shadow else { return }
        if kind == .verify {
            // LOG ONLY. Chromium serves AX from an async, lazily-built cache — the
            // read races stale content and axMatch=no false-alarms (the Lark lesson,
            // re-confirmed 2026-07-23: acting on it here demoted healthy Chrome
            // fields MID-WORD and garbled the composition). The preliminary
            // self-report verdict already catches real appenders — the tester's
            // broken field showed regionMatch=no → appended from IMK's own
            // read-back, no AX needed.
            return
        }
        if match {
            AppState.shared.markInPlaceGood(id)
            if let id { probeFailures[id] = nil; probeHonors[id] = nil }
        } else {
            AppState.shared.unmarkInPlaceGood(id)   // reverse a self-report-based commit
            AppState.shared.markUsesMarkedText(id)
            if let id { probeFailures[id] = nil; probeHonors[id] = nil }
            // Abandon the composition ONLY if the user is still in the condemned app —
            // by the time the read lands, focus (and the engine) may belong elsewhere.
            if AppState.shared.currentBundleID == id {
                engine.reset()
                tracking = false
            }
        }
    }

    /// EXPERIMENT (log-only): re-read the previous probe's target region on the NEXT
    /// keyDown — after the app's (possibly lazily-built, async) AX tree has settled —
    /// and log whether each signal now agrees with the t0 verdict. Three outcomes we
    /// are looking for on Lark (pinned to In-place + Debug logging on):
    ///   • axMatch2=no while t0 said honored → the t0 AX read raced a stale cache;
    ///     a deferred verdict WOULD auto-detect Lark (no hardcode needed).
    ///   • axMatch2=yes → Lark's AX genuinely reports the inserted text; per-app /
    ///     per-framework pinning stays the only option.
    ///   • axMatch2=nil → AX unavailable until a real AT connects; same conclusion.
    /// `axLen` is the content-independent cross-check: append leaves the field
    /// longer than a replace by `bs` per edit. Logs carry match booleans and lengths
    /// only — never the typed text.
    private func reprobeDeferred(_ p: (id: String?, start: Int, len: Int, bs: Int,
                                       inserted: String, verdict: InPlaceProbe.Verdict),
                                 _ client: IMKTextInput) {
        let nowID = AppState.shared.currentBundleID ?? FrontmostApp.shared.bundleID
        guard nowID == p.id else {
            DebugLog.log("reprobe \(p.id ?? "?"): skipped (focus now \(nowID ?? "?"))")
            return
        }
        let ax2 = AXTextEdit.readString(at: p.start, length: p.len)
        let axLen = AXTextEdit.readLength()
        var imk2: String? = nil
        if let sub = client.attributedSubstring(from: NSRange(location: p.start, length: p.len)) {
            imk2 = sub.string
        }
        let sel = client.selectedRange()
        DebugLog.log("reprobe \(p.id ?? "?"): t0=\(p.verdict) start=\(p.start) bs=\(p.bs) len=\(p.len) "
            + "axMatch2=\(ax2.map { $0 == p.inserted ? "yes" : "no" } ?? "nil") "
            + "imkMatch2=\(imk2.map { $0 == p.inserted ? "yes" : "no" } ?? "nil") "
            + "axLen=\(axLen.map(String.init) ?? "nil") "
            + "caret2=\(sel.location == NSNotFound ? "none" : String(sel.location))")
    }

    // MARK: - Marked-text mode (fallback for Terminal-like apps)

    /// Show the composed syllable as marked text, caret at the end. Reliable in apps
    /// that ignore in-place replacementRange; shows a brief underline while composing.
    private func updateMarked(_ client: IMKTextInput) {
        let s = engine.composed
        let caret = NSRange(location: (s as NSString).length, length: 0)
        // EXPERIMENT 3 — background instead of underline? TSM styles 6 (BlockFill)
        // and 8 (SelectedText) are BACKGROUND hilite styles; their mark(forStyle:)
        // dicts may carry more than style 9's bare clause segment. Log every style's
        // dict once, render with BlockFill.
        let len = (s as NSString).length
        let range = NSRange(location: 0, length: len)
        if AppState.shared.debugLogging, !Self.dumpedHiliteDicts {
            Self.dumpedHiliteDicts = true
            for style in 2...9 {
                let d = mark(forStyle: style, at: range) as? [NSAttributedString.Key: Any] ?? [:]
                DebugLog.log("markForStyle(\(style)) dict: \(d)")
            }
        }
        // Near-invisible composition underline — SHIPPED (field-accepted 2026-07-21).
        // The formula, derived the hard way: a VALID underline style (1 = thin) so
        // clients honor the span at all — style 0 reads as "unspecified" and falls
        // back to the default black underline (why every earlier attempt failed) —
        // plus a near-invisible color: alpha ≈ 1/255, NOT fully clear (Chromium
        // treats pure transparent as "use the text color"). Attribute transport was
        // proven by field-testing style 5 → visibly thicker underline. Base dict
        // from mark(forStyle:) keeps the clause segment the transport expects.
        // (No Excel special case: Excel paints its own thick composition underline
        // and ignores every attribute variant — field-tested exhaustively 2026-07-21.
        // Its clean path is empty-reset tap, i.e. real characters, not marked text.)
        var attrs = mark(forStyle: 2 /* kTSMHiliteRawText */, at: range)
            as? [NSAttributedString.Key: Any] ?? [:]
        attrs[.underlineStyle] = 1
        attrs[.underlineColor] = NSColor(calibratedWhite: 0, alpha: 0.004)
        let attributed = NSAttributedString(string: s, attributes: attrs)
        client.setMarkedText(attributed, selectionRange: caret, replacementRange: kNoRange)
        DebugLog.log("setMarked \(AppState.shared.currentBundleID ?? "?"): len=\((s as NSString).length)")
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
        if !engine.isEmpty, usesMarkedNow(AppState.shared.currentBundleID) {
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

    @discardableResult
    private func boundary(_ client: IMKTextInput, suppressAutoRestore: Bool = false,
                          allowShortcuts: Bool = true) -> Bool {
        defer { tracking = false; onLen = 0 }
        guard !engine.isEmpty else { engine.reset(); return false }
        let marked = usesMarkedNow(AppState.shared.currentBundleID)
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
        if allowShortcuts, !word.isEmpty,
           let expansion = AppState.shared.shortcuts[word] ?? AppState.shared.shortcuts[rawWord] {
            engine.reset()
            if marked { client.insertText(expansion, replacementRange: kNoRange) }
            else { applyInPlace(bs: onScreen, insert: expansion, client) }
            return true
        }

        // Auto-restore non-Vietnamese words to their raw keystrokes (resets engine).
        // Suppressed next to brackets (code context).
        let autoRestore = AppState.shared.autoRestore && !suppressAutoRestore
        let restored = engine.commitText(autoRestore: autoRestore)
        if marked {
            // Commit the marked text (replaces it with the final word).
            client.insertText(restored, replacementRange: kNoRange)
            return true
        } else if restored != word {
            applyInPlace(bs: onScreen, insert: restored, client)
            return true
        }
        return false
    }

    // MARK: - IMK lifecycle

    override func activateServer(_ sender: Any!) {
        super.activateServer(sender)
        engine.reset()
        tracking = false
        fieldVerified = false
        fieldForcedMarked = false
        if let client = sender as? IMKTextInput {
            AppState.shared.currentBundleID = client.bundleIdentifier()
            // What identifier does this client REPORT? (Catalyst/Electron apps may not
            // report what NSWorkspace says — a mismatch mis-routes every mode lookup.)
            DebugLog.log("activateServer client=\(AppState.shared.currentBundleID ?? "nil") front=\(FrontmostApp.shared.bundleID ?? "?")")
            maybePromptAccessibility(AppState.shared.currentBundleID)
            UpdateCheck.maybeAutoCheck()   // opt-in weekly; two cheap guards inside
        }
        // VietTelex is the active input source now: let the terminal tap act (it must
        // stay dormant when the user switches to ABC/US). ensureRunning() also revives
        // a tap that died (Accessibility toggled off/on invalidates the mach port), so
        // focusing a terminal / re-selecting the source self-heals it.
        TerminalTapController.shared.markActive()
        TerminalTapController.shared.ensureRunning()

        if resetObserver == nil {
            // queue: .main — the poster is the TAP thread now, and this block mutates
            // the controller's engine/tracking, which are MAIN-thread state. Ordering
            // is preserved: the click/⌘-combo that triggers the post physically
            // precedes the next keystroke, so its main-queue block is enqueued before
            // IMK delivers that key to handle() through the same main run loop.
            resetObserver = NotificationCenter.default.addObserver(
                forName: .telexResetComposition, object: nil, queue: .main) { [weak self] _ in
                self?.engine.reset()
                self?.tracking = false
                self?.fieldVerified = false
                self?.fieldForcedMarked = false
                self?.onLen = 0
            }
        }
    }

    override func commitComposition(_ sender: Any!) {
        if let client = sender as? IMKTextInput {
            // NO shortcut expansion here (tester bug 2026-07-23): some apps
            // (omnibox/Spotlight-style fields) force-commit after every
            // keystroke, which expanded a single-letter shortcut ("r"→"rồi")
            // mid-word — "t","r" became "trồi". Expansion belongs to EXPLICIT
            // boundaries only (space/punctuation/Return/Tab).
            boundary(client, allowShortcuts: false)
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

        // Status first. Three states: OK / permission missing / permission STALE
        // (trusted but the tap was refused — needs a remove+re-add, see TerminalTap).
        let statusTitle: String
        if !Accessibility.isTrusted {
            statusTitle = VTLocalized("Status: Permission needed")
        } else if TerminalTapController.shared.trustLooksStale {
            statusTitle = VTLocalized("Status: Permission stale — click to fix")
        } else {
            statusTitle = VTLocalized("Status: OK")
        }
        let status = NSMenuItem(title: statusTitle,
                                action: #selector(showStatus(_:)), keyEquivalent: "")
        status.target = self
        menu.addItem(status)

        // Everything else lives in the Settings window (Chung + Gõ tắt tabs). The menu
        // stays minimal: status + Settings.
        let settings = NSMenuItem(title: VTLocalized("Settings…"), action: #selector(openSettings(_:)), keyEquivalent: "")
        settings.target = self
        menu.addItem(settings)

        // System Settings → Keyboard (Text Input / Input Sources) — where users
        // add/remove the input source and reach the Edit… sheet.
        let sysSettings = NSMenuItem(title: VTLocalized("System Settings…"),
                                     action: #selector(openSystemKeyboardSettings(_:)), keyEquivalent: "")
        sysSettings.target = self
        menu.addItem(sysSettings)

        return menu
    }

    @objc private func openSystemKeyboardSettings(_ sender: Any?) {
        Self.openKeyboardInputSources()
    }

    /// Shared by the IME menu and the Settings window: open System Settings →
    /// Keyboard and (with Accessibility) press through to All Input Sources.
    static func openKeyboardInputSources() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
        // No URL deep-links into the "All Input Sources" Edit… sheet, so with
        // Accessibility we press the button ourselves: in the Keyboard pane the
        // Input-Sources summary line mentions our own name ("… and ViệtTelex") —
        // a locale-independent anchor; the FIRST AXButton after it inside the
        // same row group is Edit… (verified via UI-tree dump on macOS 26; the
        // second is Text Replacements…, and Dictation's own Edit… lives in a
        // different group so it can never match). Without AX, or if the tree
        // changed, fall back to a how-to popup over the open pane.
        guard Accessibility.isTrusted else { showInputSourcesHowTo(); return }
        DispatchQueue.global(qos: .userInitiated).async {
            for attempt in 0..<6 {
                Thread.sleep(forTimeInterval: attempt == 0 ? 1.2 : 0.5)
                if pressInputSourcesEdit() { return }
            }
            DispatchQueue.main.async { showInputSourcesHowTo() }
        }
    }

    /// AX couldn't (or isn't allowed to) press Edit… — tell the user where it is.
    private static func showInputSourcesHowTo() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = VTLocalized("Input sources howto title")
        alert.informativeText = VTLocalized("Input sources howto body")
        alert.addButton(withTitle: VTLocalized("OK"))
        alert.runModal()
    }

    /// Find the Input-Sources row in System Settings' AX tree (anchored on our
    /// own source name, which is locale-independent) and press the single
    /// button inside that row — the Edit… sheet opener. Returns true when
    /// pressed or when the sheet is already up.
    private static func pressInputSourcesEdit() -> Bool {
        guard let settings = NSRunningApplication
                .runningApplications(withBundleIdentifier: "com.apple.systempreferences").first
        else { return false }
        let app = AXUIElementCreateApplication(settings.processIdentifier)
        var winRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXMainWindowAttribute as CFString, &winRef) == .success,
              let window = winRef else { return false }

        // The Edit… press SUCCEEDED on an earlier attempt if a sheet is already
        // up — stop here. Walking again would anchor on the "ViệtTelex" row
        // INSIDE the sheet and press deeper into it (field bug 2026-07-23).
        var sheetsRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(window as! AXUIElement, "AXSheets" as CFString, &sheetsRef) == .success,
           let sheets = sheetsRef as? [AXUIElement], !sheets.isEmpty {
            return true
        }

        // Real tree (dumped on macOS 26, English + Vietnamese OS):
        //   AXGroup                       ← the Input-Sources row
        //     AXStaticText "Input Sources"
        //     AXStaticText "U.S. and ViệtTelex"   ← locale-independent anchor
        //     AXButton  desc="Edit…"              ← what we want
        //     AXButton  desc="Text Replacements…"
        // Rule: inside the anchor's OWN parent group only (never climb — the
        // Dictation row has its own Edit…), press the first button that comes
        // AFTER the anchor in child order. Anything unexpected → press nothing;
        // the caller then shows the how-to popup.
        guard let anchor = findAnchorText(window as! AXUIElement, depth: 0) else { return false }
        var parentRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(anchor, kAXParentAttribute as CFString, &parentRef) == .success,
              let parent = parentRef else { return false }
        let row = parent as! AXUIElement
        var kidsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(row, kAXChildrenAttribute as CFString, &kidsRef) == .success,
              let kids = kidsRef as? [AXUIElement] else { return false }
        guard let anchorIdx = kids.firstIndex(where: { CFEqual($0, anchor) }) else { return false }
        for el in kids.dropFirst(anchorIdx + 1) {
            var roleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &roleRef)
            if roleRef as? String == kAXButtonRole as String {
                return AXUIElementPerformAction(el, kAXPressAction as CFString) == .success
            }
        }
        return false
    }

    /// First static text (reading order) whose value mentions our input source
    /// or the Input-Sources label. "Telex" comes from the enabled-sources
    /// summary ("U.S. and ViệtTelex"), which shows our name in every OS
    /// language; the label strings only help on English/Vietnamese systems.
    private static func findAnchorText(_ el: AXUIElement, depth: Int) -> AXUIElement? {
        if depth > 12 { return nil }
        var roleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &roleRef)
        if roleRef as? String == kAXStaticTextRole as String {
            var valRef: CFTypeRef?
            AXUIElementCopyAttributeValue(el, kAXValueAttribute as CFString, &valRef)
            if let v = valRef as? String,
               v.contains("Telex") || v.contains("Input Sources") || v.contains("Nguồn nhập") {
                return el
            }
        }
        var kidsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &kidsRef) == .success,
              let kids = kidsRef as? [AXUIElement] else { return nil }
        for k in kids {
            if let found = findAnchorText(k, depth: depth + 1) { return found }
        }
        return nil
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
            if !Accessibility.isTrusted { self.grantAccessibility() }
            else if TerminalTapController.shared.trustLooksStale { self.showStaleTrustRepair() }
            else { self.showDebugLog() }
        }
    }

    /// Stale-grant repair: macOS lists VietTelex as allowed but refuses the tap
    /// (typical after a re-signed binary lands under an old grant). The ONLY fix
    /// is user-side: remove the entry and add it back. Walk them through it.
    @objc private func showStaleTrustRepair() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = VTLocalized("Stale permission title")
        alert.informativeText = VTLocalized("Stale permission body")
        alert.addButton(withTitle: VTLocalized("Open Accessibility Settings"))
        alert.addButton(withTitle: VTLocalized("Close"))
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
        TerminalTapController.shared.retryNow()
    }

    /// One-time gentle prompt on the FIRST activation with the permission missing —
    /// no longer waiting for the user to focus a tap-needing app (they'd type happily
    /// in Notes, then hit Terminal days later and think the IME broke). Shown once
    /// ever (axPromptShown); declining is remembered.
    private func maybePromptAccessibility(_ id: String?) {
        guard !AppState.shared.axPromptShown,
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
        let bundle = Bundle(for: TelexInputController.self)
        let ver = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        let lines = [
            "VietTelex \(ver) (build \(build))",
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
