import XCTest
@testable import TelexCore

// Keystroke-speed regression gate.
//
// Enforces "no release ships slower than the last". The gate runs in CI, and
// GitHub's macos-15 runners are one consistent hardware class, so we gate on the
// RAW cost — median-of-runs microseconds per Vietnamese keystroke — with the
// ceiling calibrated to that runner. A faster dev machine simply comes in well
// under the ceiling (an upper bound), so the test never false-fails locally.
//
// (An earlier version normalized against a reference workload to be hardware-
// independent; it wasn't — a simple ALU loop doesn't track the engine's branchy,
// table-lookup cost across microarchitectures, so the ratio jumped 87→234 from a
// fast M-series to the CI M1. Raw µs gated to the CI hardware is the honest gate.)
//
// ⚠️ RATCHET: when the engine gets genuinely faster, LOWER `ceilingMicros` to lock
// the win in — otherwise the gate silently lets speed drift back up to the old
// number. Workflow: read the CI log line `KeystrokePerf: … us/keystroke=<X>` from a
// green run, set ceiling to ~1.5× that X, and record the number + date in
// BENCHMARKS.md. Never RAISE the ceiling to make a regression pass — fix the
// regression. Release-only (debug builds are unoptimized and meaningless here).
final class KeystrokePerfTests: XCTestCase {

    /// Upper bound on µs per Vietnamese keystroke, measured on the CI runner
    /// (GitHub macos-15 / Apple Silicon). See BENCHMARKS.md for the calibration.
    static let ceilingMicros = 10.0        // provisional (safe-high); tighten from CI

    override func setUpWithError() throws {
        #if DEBUG
        throw XCTSkip("perf gate is release-only; run: swift test -c release --filter KeystrokePerf")
        #endif
    }

    func testKeystrokeNotSlowerThanBaseline() {
        // min across runs = least-noisy (interference-free) estimate.
        var best = Double.greatestFiniteMagnitude
        for _ in 0..<5 { best = min(best, keystrokeMicros()) }
        print(String(format: "KeystrokePerf: us/keystroke=%.4f  ceiling=%.4f", best, Self.ceilingMicros))
        XCTAssertLessThanOrEqual(best, Self.ceilingMicros,
            "Keystroke path regressed: \(best)µs > ceiling \(Self.ceilingMicros)µs. "
          + "Optimize the engine, or raise the ceiling only if the slowdown is intentional.")
    }

    // Vietnamese keystroke cost (full engine: parse + render + diff + validator).
    private func keystrokeMicros() -> Double {
        let words = ["ddaay","tieengs","vieejt","hoas","huyeenf","nguwowif",
                     "quaan","thuowr","truwowngf","chuyeenr","nghieeng","dduowcj"]
        for w in words { var e = TelexEngine(); for c in w { _ = e.feed(c) }; _ = e.commitBoundary(autoRestore: true) }
        var keys = 0
        let clock = ContinuousClock()
        let elapsed = clock.measure {
            for _ in 0..<3000 {
                for w in words {
                    var e = TelexEngine()
                    for c in w { _ = e.feed(c); keys += 1 }
                    _ = e.commitBoundary(autoRestore: true)
                }
            }
        }
        return nanos(elapsed) / Double(keys) / 1000.0
    }

    private func nanos(_ d: Duration) -> Double {
        Double(d.components.seconds) * 1e9 + Double(d.components.attoseconds) / 1e9
    }
}
