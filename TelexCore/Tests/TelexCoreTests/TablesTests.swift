import XCTest
@testable import TelexCore

// White-box coverage for Tables' scalar fallback: the default branch handles a
// plain (unmarked) letter and any (base, mark) combo without a precomposed form —
// engine paths route plain letters elsewhere, so only a direct call exercises it.
final class TablesTests: XCTestCase {

    func testScalarFallbackForPlainAndUnknownCombos() {
        // Plain letters: lowercase passes through, uppercase folds via ASCII math.
        XCTAssertEqual(Tables.markedScalar(base: UInt8(ascii: "a"), mark: .none, upper: false),
                       UInt32(UInt8(ascii: "a")))
        XCTAssertEqual(Tables.markedScalar(base: UInt8(ascii: "a"), mark: .none, upper: true),
                       UInt32(UInt8(ascii: "A")))
        // A combo with no precomposed form (e + horn does not exist in Vietnamese)
        // falls back to the bare letter rather than crashing.
        XCTAssertEqual(Tables.markedScalar(base: UInt8(ascii: "e"), mark: .horn, upper: false),
                       UInt32(UInt8(ascii: "e")))
        // Sanity: a real precomposed pair still resolves.
        XCTAssertEqual(Tables.markedScalar(base: UInt8(ascii: "d"), mark: .bar, upper: true),
                       "Đ".unicodeScalars.first!.value)
    }

    func testApplyToneGuards() {
        // tone == .none and unknown scalars return the input unchanged.
        XCTAssertEqual(Tables.applyTone(UInt32(UInt8(ascii: "x")), .none),
                       UInt32(UInt8(ascii: "x")))
        XCTAssertEqual(Tables.applyTone(UInt32(UInt8(ascii: "x")), .acute),
                       UInt32(UInt8(ascii: "x")))
    }
}
