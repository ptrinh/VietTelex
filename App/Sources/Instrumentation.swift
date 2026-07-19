// Instrumentation.swift
// os_signpost intervals for measuring REAL keystroke handling latency per
// strategy (in-place / marked / tap-backspace / tap-selection / tap-emptyReset)
// — the milliseconds live in the IMKit/CGEvent round trips, not the engine.
//
// Signposts are buffered by the OS and near-free when no tool is recording, so
// they ship enabled in release builds.
//
// To record: Instruments → "os_signpost" instrument (or Logging template) →
// filter subsystem "com.viettelex.inputmethod.telex". Or from a terminal:
//   xcrun xctrace record --template 'Logging' --attach VietTelex --output /tmp/vt.trace
// Intervals:
//   imk.handle — one IMKit keystroke, message = strategy that handled it
//   tap.handle — one CGEventTap keystroke (terminal-class apps)
//   tap.emit   — one synthesized edit burst (backspaces+insert posted)

import os

enum Signposts {
    static let poster = OSSignposter(subsystem: "com.viettelex.inputmethod.telex",
                                     category: "keystroke")
}
