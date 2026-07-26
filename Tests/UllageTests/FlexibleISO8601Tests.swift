import XCTest
@testable import Ullage

final class FlexibleISO8601Tests: XCTestCase {
    /// Claude's endpoint returns microsecond precision (e.g.
    /// "2026-07-11T17:50:00.022049+00:00"), which `ISO8601DateFormatter`
    /// cannot parse directly — this is the exact case the truncation path
    /// exists for.
    func testMicrosecondFractionalSeconds() {
        XCTAssertNotNil(FlexibleISO8601.date(from: "2026-07-11T17:50:00.022049+00:00"))
    }

    func testMillisecondFractionalSeconds() {
        XCTAssertNotNil(FlexibleISO8601.date(from: "2026-07-11T17:50:00.022+00:00"))
    }

    /// Cursor's `billingCycleEnd` uses "Z" with millisecond precision.
    func testZuluOffsetWithFractionalSeconds() {
        XCTAssertNotNil(FlexibleISO8601.date(from: "2026-08-04T21:29:55.000Z"))
    }

    func testNoFractionalSeconds() {
        XCTAssertNotNil(FlexibleISO8601.date(from: "2026-07-17T04:59:59+00:00"))
    }

    func testInvalidStringReturnsNil() {
        XCTAssertNil(FlexibleISO8601.date(from: "not-a-date"))
    }

    /// Truncating microseconds to milliseconds should round to the same
    /// second, not shift the timestamp — regression guard for the truncation
    /// logic itself.
    func testMicrosecondPrecisionMatchesMillisecondTruncation() throws {
        let micro = try XCTUnwrap(FlexibleISO8601.date(from: "2026-07-11T17:50:00.999999+00:00"))
        let milli = try XCTUnwrap(FlexibleISO8601.date(from: "2026-07-11T17:50:00.999+00:00"))
        XCTAssertEqual(milli.timeIntervalSince1970.rounded(), micro.timeIntervalSince1970.rounded())
    }
}
