// TelexInputController.swift
// IMKInputController driving TelexCore. NO marked text: each transform is committed
// as real text in place via insertText(_:replacementRange:), so the composing word
// is never underlined and the caret always stays at the end — the behaviour
// Vietnamese typists expect (like OpenKey / EVKey / Unikey). The engine emits a
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
// input method (mirrors Squirrel/RIME's "Squirrel.SquirrelInputController" setup).
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

    // Observes the mouse tap's reset signal: a click moved the caret, so drop any
    // composition (the tap can't reach this controller's private engine directly).
    private var resetObserver: NSObjectProtocol?

    // MARK: - Event handling (hot path)

    override func handle(_ event: NSEvent!, client sender: Any!) -> Bool {
        guard let event = event, event.type == .keyDown,
              let client = sender as? IMKTextInput else { return false }

        // Our own terminal tap-mode output (synthetic Backspace / Unicode) loops back
        // through the input system. Pass it straight to the app WITHOUT re-feeding the
        // engine (a synthetic Backspace would otherwise re-enter as kDelete).
        if SyntheticKeyboard.isSynthetic(event) { return false }

        // Secure input active (password field, or an app holding secure input like
        // some chat apps): finish anything pending, then pass through untouched.
        if IsSecureEventInputEnabled() { boundary(client); return false }

        // Remote-desktop / VM / screen-share apps forward raw scancodes, so a
        // synthesized composition is wrong there — behave as if OFF (technical
        // necessity, kept even though there is no user VI/EN toggle any more).
        if ClientPolicy.isRemoteDesktop(AppState.shared.currentBundleID) {
            boundary(client); return false
        }

        // Modifier combos (⌘⌃⌥) are never Telex input: finish and pass through.
        let mods = event.modifierFlags.intersection([.command, .control, .option])
        if !mods.isEmpty { endComposition(client); return false }

        // No internal enable/disable: if VietTelex is the active input source we always
        // compose. To type English, switch macOS input source (the OS remembers it
        // per app when "automatically switch" is on).

        // Decide tap-defer by the ACTUAL frontmost app — the SAME source the tap uses
        // (NSWorkspace) — not the IMK client id, which can be nil/stale. If the client
        // id is nil we'd otherwise think "unknown app → in-place" and wrongly compose
        // into a terminal the tap is handling; when the tap then leaks a physical key
        // (a brief tapDisabled window), IMKit composes it → intermittent garbage in
        // iTerm/Claude Code. Using the frontmost app keeps controller and tap in sync.
        let frontID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let id = AppState.shared.currentBundleID ?? frontID

        // Apps the CGEvent tap handles (terminals via Backspace, Chromium browsers &
        // Spotlight via Shift+Left selection-replace): the tap already intercepted and
        // synthesized these before the IME, so never compose here — let anything that
        // slipped through insert natively.
        if AppState.shared.usesTapMode(frontID) || AppState.shared.usesTapMode(id)
            || AppState.shared.usesSelectionReplace(frontID) || AppState.shared.usesSelectionReplace(id)
            || AppState.shared.usesEmptyReset(frontID) || AppState.shared.usesEmptyReset(id)
            || SpotlightDetector.isVisible {
            return false
        }

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
            // token isn't "corrected" (matches OpenKey's spell-check-off around
            // [ ] { }). The composed word itself is committed unchanged.
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
    /// position (no per-key selectedRange()). Unclassified apps are probed once
    /// (read-back); apps that ignore replacementRange (Terminal) flip to marked text.
    private func applyInPlace(bs: Int, insert: String, _ client: IMKTextInput) {
        let id = AppState.shared.currentBundleID
        let start: Int
        if tracking {
            start = anchor + onLen - bs
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
        client.insertText(insert, replacementRange: NSRange(location: start, length: bs))
        onLen += (insert as NSString).length - bs

        if !insert.isEmpty, AppState.shared.needsProbe(id) {
            probeInPlace(inserted: insert, client)
        }
    }

    /// After the first in-place replace into an unknown app, read the text back. If
    /// the app ignored replacementRange (valid caret but no actual replace, e.g.
    /// Terminal), remember it and switch to marked-text mode.
    private func probeInPlace(inserted: String, _ client: IMKTextInput) {
        let len = (inserted as NSString).length
        let sel = client.selectedRange()
        var ok = false
        if sel.location != NSNotFound, sel.location >= len {
            let range = NSRange(location: sel.location - len, length: len)
            if let sub = client.attributedSubstring(from: range) {
                ok = (sub.string == inserted)
            }
        }
        if ok {
            AppState.shared.markInPlaceGood(AppState.shared.currentBundleID)
        } else {
            AppState.shared.markUsesMarkedText(AppState.shared.currentBundleID)
            engine.reset()   // abandon the glitched word; next word uses marked text
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
    /// A modifier combo (⌘A, ⌃…) arrived mid-word. Like OpenKey's otherControlKey
    /// path: drop the composition with NO auto-restore and NO shortcut expansion —
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

    private func boundary(_ client: IMKTextInput, suppressAutoRestore: Bool = false) {
        defer { tracking = false; onLen = 0 }
        guard !engine.isEmpty else { engine.reset(); return }
        let marked = AppState.shared.usesMarkedText(AppState.shared.currentBundleID)
        let word = engine.composed
        let onScreen = word.unicodeScalars.count

        // Shortcut expansion (bảng gõ tắt) takes precedence over the composed word.
        if !word.isEmpty, let expansion = AppState.shared.shortcuts[word] {
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
        }
        // VietTelex is the active input source now: let the terminal tap act (it must
        // stay dormant when the user switches to ABC/US). ensureRunning() also revives
        // a tap that died (Accessibility toggled off/on invalidates the mach port), so
        // focusing a terminal / re-selecting the source self-heals it.
        TerminalTapController.shared.imeActive = true
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
        // transform keys, so the user really types English in terminals.
        TerminalTapController.shared.imeActive = false
        super.deactivateServer(sender)
    }

    // MARK: - Input-method menu (IMK-provided, no NSStatusItem)

    override func menu() -> NSMenu! {
        let menu = NSMenu(title: "VietTelex")
        // macOS appends a standard "Edit Text Substitutions…" item to input-method
        // menus. Strip it (and any trailing separator) each time the menu opens.
        menu.delegate = self

        // Status first. OK when Accessibility is granted (terminal tap works), else
        // missing. No checkmark. Click → grant-permission pane if missing, else a debug log.
        let status = NSMenuItem(title: Accessibility.isTrusted ? "Tình trạng: OK" : "Tình trạng: Thiếu quyền",
                                action: #selector(showStatus(_:)), keyEquivalent: "")
        status.target = self
        menu.addItem(status)
        menu.addItem(.separator())

        // Everything else lives in the Settings window (Chung + Gõ tắt tabs). The menu
        // stays minimal: status + Settings.
        let settings = NSMenuItem(title: "Cài đặt…", action: #selector(openSettings(_:)), keyEquivalent: "")
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

    /// Missing permission: prompt + open the Accessibility pane so the user can grant
    /// it. Background input-method agents often can't surface the system dialog, so we
    /// open the pane directly. Once trusted, the terminal tap starts on next keystroke.
    private func grantAccessibility() {
        Accessibility.requestIfNeeded()
        TerminalTapController.shared.ensureRunning()
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Thiếu quyền Trợ năng (Accessibility)"
        alert.informativeText = "VietTelex cần quyền Accessibility để gõ tiếng Việt trong Terminal/iTerm và các trình duyệt.\n\nMở System Settings → Privacy & Security → Accessibility, rồi bật VietTelex (nếu đã có thì bỏ tick và tick lại)."
        alert.addButton(withTitle: "Mở Cài đặt")
        alert.addButton(withTitle: "Đóng")
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
