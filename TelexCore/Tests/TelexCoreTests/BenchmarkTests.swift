import XCTest
@testable import TelexCore

final class BenchmarkTests: XCTestCase {

    // Representative keystroke stream (words with tones, marks, restore triggers).
    private let words = [
        "ddaay", "tieengs", "vieejt", "hoas", "huyeenf", "nguwowif",
        "quaan", "thuowr", "truwowngf", "chuyeenr", "nghieeng", "ngoaif",
        "windows", "hello", "programming",
    ]

    /// Average engine latency per keystroke must stay under 50µs.
    func testPerKeystrokeLatencyUnder50Microseconds() {
        // Warm up (also warms the static tables).
        runOnce()

        let iterations = 2000
        var totalKeystrokes = 0
        let clock = ContinuousClock()

        let elapsed = clock.measure {
            for _ in 0..<iterations {
                totalKeystrokes += runOnce()
            }
        }

        let nanos = Double(elapsed.components.seconds) * 1_000_000_000
            + Double(elapsed.components.attoseconds) / 1_000_000_000
        let perKey = nanos / Double(totalKeystrokes)
        let perKeyMicros = perKey / 1000.0

        print(String(format: "Benchmark: %.3f µs/keystroke over %d keystrokes",
                     perKeyMicros, totalKeystrokes))
        XCTAssertLessThan(perKeyMicros, 50.0,
                          "avg keystroke latency \(perKeyMicros)µs exceeds 50µs budget")
    }

    /// Feed every word once (fresh engine per word, boundary commit). Returns keystrokes.
    @discardableResult
    private func runOnce() -> Int {
        var count = 0
        for w in words {
            var e = TelexEngine()
            for ch in w {
                _ = e.feed(ch)
                count += 1
            }
            _ = e.commitBoundary(autoRestore: true)
        }
        return count
    }

    // XCTest's own reporting harness for reference numbers.
    func testMeasureBlock() {
        measure {
            for _ in 0..<200 { runOnce() }
        }
    }
}
