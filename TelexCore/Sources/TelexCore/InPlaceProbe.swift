// InPlaceProbe.swift
// Pure decision logic for the input controller's "does this app honor
// insertText replacementRange?" probe. Kept here (not in the App target) so it is
// unit-testable without IMKit: the controller feeds it the client's post-edit caret
// and read-back; tests feed it values from simulated clients.
//
// Background: the controller edits text in place with
//   client.insertText(insert, replacementRange: NSRange(location: start, length: bs))
// A compliant app REPLACES the `bs` chars at `start` with `insert`. Some apps
// (Terminal, iTerm2's CJK IMKit path, Mac Catalyst like WhatsApp, Electron/CEF like
// Lark) ignore the range and APPEND `insert` at the caret instead — tone edits then
// pile up without replacing, so diacritics never render.
//
// Detection history — read-back of the inserted TEXT proved unreliable twice:
//   • Old probe read the text BEFORE the caret; that holds `insert` in BOTH cases
//     (compliant: replaced there; append: freshly appended) → false-positive.
//   • Reading the TARGET region [start, start+len) fixes the honest case, but apps
//     that ECHO their read-back (iTerm2, Lark) still return `insert` there → still
//     false-positive.
// The robust signal is the post-edit CARET position, which every IME-aware app must
// report faithfully to place its candidate window. A compliant replace leaves the
// caret at `start + len`; an ignored-range append leaves it `bs` further right, at
// `start + bs + len`. Text read-back is kept only as a fallback when the caret is
// unavailable, and an inconclusive probe never condemns a (probably working) app.

public enum InPlaceProbe {

    public enum Verdict {
        case honored        // app replaced correctly → stay on the in-place path
        case appended       // app ignored the range → switch to marked text
        case inconclusive   // can't tell → leave unclassified, retry, don't condemn
    }

    /// Whether this edit is a usable probe. Only a REAL replace (bs > 0) with no
    /// pending selection (clear == 0) discriminates: a pure insert (bs == 0) lands
    /// identically whether or not the app honors the range, so confirming "in-place
    /// good" on one is exactly the false-positive that locked broken apps in place.
    /// `needsProbe` is the caller's "not yet classified" flag.
    public static func shouldProbe(insertLength: Int, bs: Int, clear: Int, needsProbe: Bool) -> Bool {
        insertLength > 0 && bs > 0 && clear == 0 && needsProbe
    }

    /// Classify a probed replace of `bs` chars at `start` with `insertLength` chars.
    ///
    /// - `caret`: the client's caret location AFTER the edit (`nil` if it reports
    ///   none). This is the primary, hardest-to-fake signal.
    /// - `regionReadback`: text the client returns for `[start, start+insertLength)`
    ///   (`nil` if unavailable). Fallback only — some apps echo it, so it can never
    ///   OVERRIDE a caret that says "appended".
    /// - `inserted`: the string we asked the client to place.
    ///
    /// Caret wins when present: exactly `start+len` → honored, exactly
    /// `start+bs+len` → appended. Only when the caret is absent/ambiguous do we fall
    /// back to the read-back, and a missing read-back stays inconclusive (never a
    /// condemnation — the in-place default is right for the vast majority of apps).
    public static func verdict(caret: Int?, start: Int, bs: Int, insertLength: Int,
                               regionReadback: String?, inserted: String) -> Verdict {
        let expectedReplace = start + insertLength
        let expectedAppend  = start + bs + insertLength
        if let c = caret {
            if bs > 0 && c == expectedAppend { return .appended }
            if c == expectedReplace { return .honored }
            // Caret present but neither expected value — untrusted; fall through to
            // the read-back rather than guessing.
        }
        if let r = regionReadback {
            return r == inserted ? .honored : .appended
        }
        return .inconclusive
    }
}
