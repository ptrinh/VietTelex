import XCTest
@testable import TelexCore

// Keystroke-speed regression guard.
//
// Perf is measured RELATIVE to a fixed calibration workload run on the SAME
// machine in the same process, so the metric is dimensionless and comparable
// across machines (a fast M-series laptop vs a shared CI runner). The build
// FAILS if the normalized per-keystroke cost exceeds the recorded baseline by
// more than `tolerance` — i.e. a release may not ship slower than the baseline.
//
// When you make the engine genuinely faster, run this test, read the printed
// ratio, and lower `baseline` to lock in the win. Release-only (debug builds
// skip optimizations and are meaningless for perf).
final class KeystrokePerfTests: XCTestCase {

    /// Normalized cost = (ns per Vietnamese keystroke) / (ns per calibration unit).
    /// Baseline captured 2026-07-20 on Apple Silicon, release build. Lower = faster.
    static let baseline = 90.0            // captured 2026-07-20, Apple Silicon release (typical 87–90)
    static let tolerance = 1.40            // +40% headroom for CI noise; catches real (>1.4x) regressions

    override func setUpWithError() throws {
        #if DEBUG
        throw XCTSkip("perf gate is release-only; run: swift test -c release --filter KeystrokePerf")
        #endif
    }

    func testKeystrokeNotSlowerThanBaseline() {
        // min across runs = least-noisy (interference-free) estimate.
        var best = Double.greatestFiniteMagnitude
        for _ in 0..<5 { best = min(best, keystrokeNs() / calibrationNsPerUnit()) }
        print(String(format: "KeystrokePerf: ratio=%.2f  baseline=%.2f  ceiling=%.2f",
                     best, Self.baseline, Self.baseline * Self.tolerance))
        XCTAssertLessThanOrEqual(best, Self.baseline * Self.tolerance,
            "Keystroke path regressed: ratio \(best) > baseline \(Self.baseline)×\(Self.tolerance). "
          + "Optimize the engine, or bump the baseline if the slowdown is intentional.")
    }

    // Vietnamese keystroke cost (full engine: parse + render + diff + validator).
    private func keystrokeNs() -> Double {
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
        return nanos(elapsed) / Double(keys)
    }

    // Deterministic reference workload — index + ALU over a small buffer. Tracks
    // the machine's scalar+memory speed the way the parser does, cancelling out
    // hardware differences when we take the ratio.
    private func calibrationNsPerUnit() -> Double {
        let n = 4_000_000
        var buf = [UInt8](repeating: 0, count: 64)
        for i in 0..<64 { buf[i] = UInt8(truncatingIfNeeded: i &* 7 &+ 1) }
        var acc: UInt64 = 0
        let clock = ContinuousClock()
        let elapsed = clock.measure {
            for i in 0..<n { acc = acc &+ UInt64(buf[i & 63]) &+ (acc >> 1) }
        }
        if acc == 0xDEAD { print("unreachable") }   // keep acc live
        return nanos(elapsed) / Double(n)
    }

    private func nanos(_ d: Duration) -> Double {
        Double(d.components.seconds) * 1e9 + Double(d.components.attoseconds) / 1e9
    }
}
