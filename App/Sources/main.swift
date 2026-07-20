// main.swift
// Process entry point. macOS launches this bundle when the user selects the
// Vietnamese input source; we start an IMKServer and run the event loop.
// No timers, no background threads — everything is event driven.

import Cocoa
import InputMethodKit
import Carbon.HIToolbox

// Held for the process lifetime.
var telexServer: IMKServer?
var inputSourceObserver: NSObjectProtocol?

let connectionName = (Bundle.main.infoDictionary?["InputMethodConnectionName"] as? String)
    ?? "VietTelex_Connection"

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

NSApplication.shared.run()
