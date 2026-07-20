// IMEActivation.swift
// Tracks whether VietTelex is the active input source, robust to IMK calling
// activateServer / deactivateServer OUT OF ORDER across clients.
//
// The hazard: when focus moves between two clients that both use VietTelex (common
// with macOS "automatically switch to a document's input source" enabled), IMK may
// call the NEW client's activateServer BEFORE the OLD client's deactivateServer.
// Both write one shared "is VietTelex active" flag, so a naive `deactivate → false`
// clobbers the fresh activate: the tap goes dormant while VietTelex is STILL the
// selected input source, and typing silently passes through until a clean focus
// cycle re-runs activateServer last. (Reproduced in iTerm2: leave to another app and
// come back and Vietnamese typing works again, with nothing else changed.)
//
// Fix: the OS-selected input source is the single source of truth; the lifecycle
// calls are only hints. deactivate() turns the flag off ONLY when VietTelex is no
// longer the OS-selected source, so a stale out-of-order deactivate can't clobber it.
// A TIS selection-changed notification recomputes authoritatively (and covers the
// case where per-document switching skips activateServer entirely).
public struct IMEActivation: Sendable, Equatable {
    public private(set) var isActive: Bool

    public init(isActive: Bool = false) { self.isActive = isActive }

    /// activateServer: VietTelex is active for the focused client.
    public mutating func activate() { isActive = true }

    /// deactivateServer: a client lost VietTelex. `stillSelected` = whether VietTelex
    /// is STILL the OS-selected keyboard input source at this instant. A late,
    /// out-of-order deactivate from a previously focused client fires while VietTelex
    /// is still selected → ignore it so it can't turn the tap off under our feet.
    public mutating func deactivate(stillSelected: Bool) {
        if !stillSelected { isActive = false }
    }

    /// TIS "selected keyboard input source changed" notification — authoritative.
    public mutating func selectionChanged(isVietTelex: Bool) {
        isActive = isVietTelex
    }
}
