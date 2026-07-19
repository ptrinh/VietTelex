import XCTest
import Darwin
@testable import TelexCore

// Dynamic enforcement of the engine's zero-heap-allocation hot-path invariant.
//
// Why not @_noAllocation? The compiler-checked annotation cannot be satisfied with
// safe CoW `Array` buffers (every write is a *potential* copy-allocation as far as
// static analysis goes) — it needs InlineArray (macOS 26) or unsafe pointers. So
// the invariant is locked HERE instead: malloc statistics are sampled around a
// large batch of keystrokes and the test fails if the hot path ever starts
// allocating. Anyone who reintroduces a String/Array allocation into feed()/
// parseStep()/render()/the validators breaks this test immediately.
final class ZeroAllocationTests: XCTestCase {

    override func setUpWithError() throws {
        // The invariant is a property of OPTIMIZED code (debug builds skip
        // small-string/UnicodeScalarView fast paths and do allocate). Run with:
        //   swift test -c release --filter ZeroAllocation
        #if DEBUG
        throw XCTSkip("zero-allocation invariant is release-only; run swift test -c release")
        #endif
    }

    private func chunksUsed() -> Int { Int(mstats().chunks_used) }

    /// Warm everything once: lazy static tries, table globals, engine buffers,
    /// String small-string paths — so the measured phase sees steady state.
    private func warmUp(_ e: inout TelexEngine) {
        for w in ["truowngf", "nguwowif", "ddaay", "hoas", "windows", "hello", "SaaS"] {
            for ch in w { _ = e.feed(ch) }
            _ = e.commitBoundary(autoRestore: true)
        }
        for ch in "0123456789" { _ = e.feed(ch) }
    }

    /// Passthrough + English letters: the pure fast path MUST be allocation-free.
    func testEnglishAndPassthroughPathIsAllocationFree() {
        var e = TelexEngine()
        e.liveSpellCheck = true
        warmUp(&e)

        let before = chunksUsed()
        for _ in 0..<2_000 {
            for w in ["hello", "keyboard", "performance"] {
                for ch in w { _ = e.feed(ch) }
                e.reset()
            }
            for ch in ",./;'123 " { _ = e.feed(ch) }
        }
        let delta = chunksUsed() - before
        // Tolerate a handful of unrelated lazy-runtime chunks, nothing per-key:
        // ~100k keystrokes with even 1 alloc/key would show ~100k here.
        XCTAssertLessThan(delta, 50,
            "English/passthrough hot path allocated (\(delta) chunks over ~100k keys)")
    }

    /// Vietnamese typing: scratch work is allocation-free; the only permitted
    /// allocations are the returned insert Strings — which are small enough for
    /// Swift's inline small-string form, so in practice this path is also ~zero.
    func testVietnameseTypingPathAllocationBudget() {
        var e = TelexEngine()
        e.liveSpellCheck = true
        warmUp(&e)

        let words = ["truowngf", "nguwowif", "ddaay", "tieengs", "vieejt", "hoas"]
        let before = chunksUsed()
        var keys = 0
        for _ in 0..<2_000 {
            for w in words {
                for ch in w { _ = e.feed(ch); keys += 1 }
                _ = e.commitBoundary(autoRestore: true)
            }
        }
        let delta = chunksUsed() - before
        // Budget: far under 1 allocation per 100 keystrokes (steady-state noise only).
        XCTAssertLessThan(Double(delta), Double(keys) / 100.0,
            "Vietnamese hot path allocating: \(delta) chunks over \(keys) keys")
        print("ZeroAlloc: Vietnamese path \(delta) malloc chunks over \(keys) keystrokes")
    }
}
