import XCTest
@testable import TelexCore

// The input controller edits text in place with insertText(_:replacementRange:).
// A compliant app REPLACES; some apps (Terminal, iTerm2's CJK IMKit path, Mac
// Catalyst like WhatsApp) ignore the range and APPEND at the caret, so tone edits
// pile up without replacing and diacritics never render.
//
// These tests drive the REAL TelexEngine and replay its actions through two
// simulated clients — one honoring the range, one appending — then feed the exact
// read-backs to InPlaceProbe. They pin down that:
//   • reading the TARGET region [start, start+len) catches the append app, and
//   • the OLD approach (reading before the CARET) would have false-positived it —
//     the precise regression that silently broke iTerm2/WhatsApp.
final class InPlaceProbeTests: XCTestCase {

    /// Simulated input client. NSString offsets match IMKit; every composed
    /// Vietnamese scalar is a single BMP UTF-16 unit, so offsets line up 1:1.
    private final class Client {
        let honorsRange: Bool
        let doc = NSMutableString()
        var caret = 0
        init(honorsRange: Bool) { self.honorsRange = honorsRange }
        func insert(_ s: String, at loc: Int, length bs: Int) {
            if honorsRange {
                doc.replaceCharacters(in: NSRange(location: loc, length: bs), with: s)
                caret = loc + (s as NSString).length
            } else {
                doc.insert(s, at: caret)             // ignores range → append at caret
                caret += (s as NSString).length
            }
        }
        func readback(at loc: Int, length len: Int) -> String? {
            guard loc >= 0, len >= 0, loc + len <= doc.length else { return nil }
            return doc.substring(with: NSRange(location: loc, length: len))
        }
    }

    private struct ProbePoint {
        let start: Int
        let inserted: String
        let regionGood: String?     // compliant client, TARGET region read-back (the fix)
        let regionBad: String?      // append client,   TARGET region read-back (the fix)
        let caretBad: String?       // append client,   BEFORE-caret read-back (the old probe)
    }

    /// Replay the controller's TRACKING in-place applier over `keys` (fresh empty
    /// field: anchor 0, no selection), feeding a compliant and an append client.
    /// Returns the first probe-eligible replace and the read-backs at that instant.
    private func firstProbe(_ keys: String) -> ProbePoint? {
        var e = TelexEngine(); e.liveSpellCheck = true; e.simpleTelex = true
        let good = Client(honorsRange: true)
        let bad = Client(honorsRange: false)
        var onLen = 0
        for ch in keys {
            switch e.feed(ch) {
            case .passthrough:
                let s = String(ch)
                good.insert(s, at: onLen, length: 0)
                bad.insert(s, at: onLen, length: 0)
                onLen += (s as NSString).length
            case let .replace(bs, insert):
                let start = onLen - bs
                good.insert(insert, at: start, length: bs)
                bad.insert(insert, at: start, length: bs)
                let insLen = (insert as NSString).length
                onLen += insLen - bs
                if InPlaceProbe.shouldProbe(insertLength: insLen, bs: bs, clear: 0, needsProbe: true) {
                    return ProbePoint(
                        start: start, inserted: insert,
                        regionGood: good.readback(at: start, length: insLen),
                        regionBad: bad.readback(at: start, length: insLen),
                        caretBad: bad.readback(at: bad.caret - insLen, length: insLen))
                }
            case .none:
                break
            }
        }
        return nil
    }

    // A spread of Telex sequences whose first modifier/tone key is a real replace.
    private let cases = [
        "cas", "caf", "awn", "cowm", "thuw", "ddi", "gox", "maj",
        "vieejt", "truowngf", "hoas", "nguoiwf", "dduowngf", "quaf",
    ]

    func testCompliantAppReadsBackInserted() {
        for keys in cases {
            guard let p = firstProbe(keys) else { XCTFail("no probe point: \(keys)"); continue }
            XCTAssertNotNil(p.regionGood, "compliant read-back nil: \(keys)")
            XCTAssertTrue(InPlaceProbe.inPlaceHonored(readback: p.regionGood ?? "", inserted: p.inserted),
                          "compliant app should look honored for \(keys)")
        }
    }

    func testAppendAppDetectedByRegionReadback() {
        for keys in cases {
            guard let p = firstProbe(keys) else { XCTFail("no probe point: \(keys)"); continue }
            // The fix: the target region still holds the OLD char, so it is NOT honored.
            XCTAssertFalse(InPlaceProbe.inPlaceHonored(readback: p.regionBad ?? "", inserted: p.inserted),
                           "append app must NOT look honored under region read-back: \(keys)")
        }
    }

    func testOldCaretReadbackWouldFalsePositiveAppendApp() {
        // Why the fix was needed: reading before the CARET, the append app's text IS
        // the inserted string — so the old probe confirmed these broken apps "good".
        for keys in cases {
            guard let p = firstProbe(keys) else { XCTFail("no probe point: \(keys)"); continue }
            XCTAssertTrue(InPlaceProbe.inPlaceHonored(readback: p.caretBad ?? "", inserted: p.inserted),
                          "documents the old false-positive (before-caret read-back) for \(keys)")
        }
    }

    func testShouldProbeGating() {
        // Only a real, clean replace of an unclassified app is a usable probe.
        XCTAssertTrue(InPlaceProbe.shouldProbe(insertLength: 1, bs: 1, clear: 0, needsProbe: true))
        XCTAssertFalse(InPlaceProbe.shouldProbe(insertLength: 1, bs: 0, clear: 0, needsProbe: true),
                       "pure insert (bs==0) must never confirm — this was the false-positive")
        XCTAssertFalse(InPlaceProbe.shouldProbe(insertLength: 1, bs: 1, clear: 2, needsProbe: true),
                       "pending selection (clear>0) is not a clean replace")
        XCTAssertFalse(InPlaceProbe.shouldProbe(insertLength: 0, bs: 1, clear: 0, needsProbe: true),
                       "empty insert is not a probe")
        XCTAssertFalse(InPlaceProbe.shouldProbe(insertLength: 1, bs: 1, clear: 0, needsProbe: false),
                       "already classified — do not re-probe")
    }

    func testInsertedFirstCharDiffersFromOldCharAtStart() {
        // The discriminator relies on the engine stripping the common prefix, so
        // inserted[0] differs from the old char at `start`. Verify that structurally:
        // the append client's region read-back (old chars) never equals inserted[0..].
        for keys in cases {
            guard let p = firstProbe(keys), let bad = p.regionBad, let good = p.regionGood else {
                XCTFail("no probe point: \(keys)"); continue
            }
            XCTAssertNotEqual(bad.first, good.first,
                              "first char of target region must differ (replace vs append) for \(keys)")
        }
    }
}
