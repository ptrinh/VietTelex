// DebugLog.swift
// Opt-in, in-memory ring buffer for field-diagnosing the terminal tap — above all
// the keyboard-hang class (synthetic-event cascade / tap wedge). OFF by default
// (AppState.debugLogging); while off, log() is a cheap early return, so call sites
// are safe to leave on the hot path. While on it keeps the last N timestamped lines
// in memory only (no file I/O) that the user copies from Settings → Thử Nghiệm and
// pastes to the developer.
//
// PRIVACY: records ONLY lifecycle / health events (tap create/teardown, breaker
// trips, active-state, emit bursts as COUNTS) — never the characters typed. Keep it
// that way: this buffer is meant to be shared.

import Foundation

enum DebugLog {
    private static let capacity = 400
    private static var lines: [String] = []
    private static let lock = NSLock()          // tap callback is main; Spotlight scan is off-main
    private static let startNs = DispatchTime.now().uptimeNanoseconds

    /// Append a health event. The message is an @autoclosure so nothing is built when
    /// logging is off (the common case). Never pass user-typed text.
    static func log(_ message: @autoclosure () -> String) {
        guard AppState.shared.debugLogging else { return }
        let ms = Double(DispatchTime.now().uptimeNanoseconds &- startNs) / 1_000_000
        let text = message()
        let line = String(format: "%10.1f  %@", ms, text)
        lock.lock()
        lines.append(line)
        if lines.count > capacity { lines.removeFirst(lines.count - capacity) }
        lock.unlock()
        // Mirror to the unified log: the in-memory ring DIES with the process, which
        // is exactly when it is needed most (hang → reboot / relaunch wiped the
        // evidence of the build-7 revoke wedge). Structural events only, never typed
        // text — same privacy contract as the ring buffer.
        Signposts.log.notice("\(text, privacy: .public)")
    }

    static func clear() { lock.lock(); lines.removeAll(); lock.unlock() }

    /// `header` (current runtime state) followed by the ring buffer, ready to copy.
    static func snapshot(header: [String]) -> String {
        lock.lock(); let body = lines; lock.unlock()
        let tail = body.isEmpty
            ? ["(log empty — bật “Ghi nhật ký gỡ lỗi” rồi tái hiện lỗi)"]
            : body
        return (header + ["", "— log (\(body.count)/\(capacity) dòng, ms kể từ khi bật app) —"] + tail)
            .joined(separator: "\n")
    }
}
