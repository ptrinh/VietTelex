// main.swift
// Process entry point. macOS launches this bundle when the user selects the
// Vietnamese input source; we start an IMKServer and run the event loop.
// No timers, no background threads — everything is event driven.

import Cocoa
import InputMethodKit

// Held for the process lifetime.
var telexServer: IMKServer?

let connectionName = (Bundle.main.infoDictionary?["InputMethodConnectionName"] as? String)
    ?? "VietTelex_Connection"

telexServer = IMKServer(name: connectionName, bundleIdentifier: Bundle.main.bundleIdentifier)

// No internal VI/EN toggle: Vietnamese is ON whenever VietTelex is the active macOS
// input source. Switch to another input source (or use macOS's per-app input-source
// memory) to type English — the OS drives everything.

// Prime the frontmost-app cache (registers its NSWorkspace observer) so the per-key
// hot paths never call NSWorkspace.frontmostApplication themselves.
_ = FrontmostApp.shared

// Terminal tap-mode: OpenKey-style CGEventTap for apps that ignore replacementRange
// (iTerm, Terminal…). No-op unless Accessibility is granted (Developer ID build);
// re-attempted from activateServer once permission is granted.
TerminalTapController.shared.ensureRunning()

NSApplication.shared.run()
