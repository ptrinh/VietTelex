// InPlaceProbe.swift
// Pure decision logic for the input controller's "does this app honor
// insertText replacementRange?" probe. Kept here (not in the App target) so it is
// unit-testable without IMKit: the controller feeds it read-backs from the real
// client; tests feed it read-backs from a simulated client.
//
// Background: the controller edits text in place with
//   client.insertText(insert, replacementRange: NSRange(location: start, length: bs))
// A compliant app REPLACES the `bs` chars at `start` with `insert`. Some apps
// (Terminal, iTerm2's CJK IMKit path, Mac Catalyst apps like WhatsApp) ignore the
// range and APPEND `insert` at the caret instead — tone edits then pile up without
// replacing, so diacritics never render.
//
// The old probe read back the text right BEFORE the caret; that region holds
// `insert` in BOTH cases (compliant: it replaced there; append: it's the freshly
// appended text), so the probe false-positived append-apps as "good". The fix reads
// the TARGET region [start, start+len) and requires two things (below).

public enum InPlaceProbe {

    /// Whether this edit is a usable probe. Only a REAL replace (bs > 0) with no
    /// pending selection (clear == 0) discriminates: a pure insert (bs == 0) lands
    /// identically whether or not the app honors the range, so confirming "in-place
    /// good" on one is exactly the false-positive that locked iTerm2/WhatsApp onto
    /// the broken path. `needsProbe` is the caller's "not yet classified" flag.
    public static func shouldProbe(insertLength: Int, bs: Int, clear: Int, needsProbe: Bool) -> Bool {
        insertLength > 0 && bs > 0 && clear == 0 && needsProbe
    }

    /// Verdict from the read-back of the TARGET region [start, start+insertLength).
    /// A compliant app now holds `inserted` there; an app that appended still holds
    /// the OLD characters. Because the engine strips the longest common prefix from a
    /// `.replace`, `inserted`'s first character is guaranteed to differ from the old
    /// character at `start`, so this discriminates even on a one-character window.
    public static func inPlaceHonored(readback: String, inserted: String) -> Bool {
        readback == inserted
    }
}
