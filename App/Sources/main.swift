// main.swift
// Process entry point. macOS launches this bundle when the user selects the
// Vietnamese input source; we start an IMKServer and run the event loop.
// No timers, no polling — everything is event driven. The one persistent thread
// besides main is the event tap's run loop (TerminalTapController.start), which
// parks in mach_msg at zero CPU and exists so tap callbacks never queue behind
// main-thread IMKit/UI work.

import Cocoa
import InputMethodKit
import Carbon.HIToolbox

// Held for the process lifetime.
var telexServer: IMKServer?
var inputSourceObserver: NSObjectProtocol?

// MUST be "<bundle id>_Connection" (modern macOS NSConnection convention for input
// methods). The old arbitrary name "VietTelex_Connection" silently broke SANDBOXED
// clients: WhatsApp (MAS) could never connect — no activateServer, no menu section,
// every keystroke swallowed — while non-sandboxed apps (Terminal, Chrome) worked.
let connectionName = (Bundle.main.infoDictionary?["InputMethodConnectionName"] as? String)
    ?? "com.viettelex.inputmethod.telex_Connection"

telexServer = IMKServer(name: connectionName, bundleIdentifier: Bundle.main.bundleIdentifier)

// No internal VI/EN toggle: Vietnamese is ON whenever VietTelex is the active macOS
// input source. Switch to another input source (or use macOS's per-app input-source
// memory) to type English — the OS drives everything.

// Prime the frontmost-app cache (registers its NSWorkspace observer) so the per-key
// hot paths never call NSWorkspace.frontmostApplication themselves.
_ = FrontmostApp.shared

// Terminal tap-mode: CGEventTap for apps that ignore replacementRange
// (iTerm, Terminal…). No-op unless Accessibility is granted (Developer ID build);
// re-attempted from activateServer once permission is granted.
TerminalTapController.shared.ensureRunning()

// Authoritative gate for the tap: whenever macOS switches the selected keyboard input
// source, recompute whether VietTelex is active. This catches per-document switching
// (which can restore VietTelex on focus-return without an activateServer call) and
// makes the tap's state independent of the flaky activate/deactivate call ordering.
inputSourceObserver = DistributedNotificationCenter.default().addObserver(
    forName: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
    object: nil, queue: .main) { _ in
    TerminalTapController.shared.selectionChanged(isVietTelex: TelexInputController.isVietTelexSelected())
}

// Accessibility permission toggled (System Settings): react IMMEDIATELY, not on the
// next keystroke. Revoke while the tap is live used to leave a tap macOS keeps
// disabling while we kept re-enabling — a ping-pong that wedged ALL input (keyboard
// AND mouse are in the tap mask). Now: revoked → full teardown (events flow native);
// granted → start the tap without needing an input-source cycle.
var axChangeObserver: NSObjectProtocol?
axChangeObserver = DistributedNotificationCenter.default().addObserver(
    forName: NSNotification.Name("com.apple.accessibility.api"),
    object: nil, queue: .main) { _ in
    // No trust check here — right after the toggle tccd can still report the OLD
    // value (that race skipped the teardown in build 7 and the wedged tap
    // survived). trustMayHaveChanged tears down unconditionally and re-creates
    // ~1.5s later iff genuinely trusted.
    TerminalTapController.shared.trustMayHaveChanged()
}

// Standard editing key equivalents (⌘A/⌘C/⌘V/⌘X/⌘Z, ⌘W) inside our OWN Settings
// window. macOS dispatches key equivalents through the app's main menu — an
// LSUIElement agent has no visible menu bar, but without a mainMenu object the
// events go nowhere and ⌘A in the filter/shortcut fields does nothing. The menu
// is never shown; it exists purely as the responder-chain routing table.
let mainMenu = NSMenu()

let editItem = NSMenuItem()
let editMenu = NSMenu(title: "Edit")
editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
editMenu.addItem(.separator())
editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
editItem.submenu = editMenu
mainMenu.addItem(editItem)

let windowItem = NSMenuItem()
let windowMenu = NSMenu(title: "Window")
windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
windowItem.submenu = windowMenu
mainMenu.addItem(windowItem)

NSApplication.shared.mainMenu = mainMenu

NSApplication.shared.run()
