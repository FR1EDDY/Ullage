import XCTest
@testable import UsageBar

final class ResetTextTests: XCTestCase {
    func testNilDate() {
        XCTAssertEqual(ResetText.label(for: nil), "Resets —")
    }

    func testPastOrNowRestsSoon() {
        let now = Date()
        XCTAssertEqual(ResetText.label(for: now, now: now), "Resets soon")
        XCTAssertEqual(ResetText.label(for: now.addingTimeInterval(-10), now: now), "Resets soon")
    }

    func testRelativeMinutes() {
        let now = Date()
        let date = now.addingTimeInterval(55 * 60)
        XCTAssertEqual(ResetText.label(for: date, now: now), "Resets in 55 min")
    }

    func testRelativeHoursAndMinutes() {
        let now = Date()
        let date = now.addingTimeInterval(90 * 60)
        XCTAssertEqual(ResetText.label(for: date, now: now), "Resets in 1 hr 30 min")
    }

    func testRelativeWholeHours() {
        let now = Date()
        let date = now.addingTimeInterval(2 * 60 * 60)
        XCTAssertEqual(ResetText.label(for: date, now: now), "Resets in 2 hr")
    }

    /// 30 hours is under the 36-hour relative/absolute switch, but over 24
    /// hours, so it exercises the "days" branch inside the relative formatter.
    func testRelativeDaysUnderAbsoluteThreshold() {
        let now = Date()
        let date = now.addingTimeInterval(30 * 60 * 60)
        XCTAssertEqual(ResetText.label(for: date, now: now), "Resets in 1 day")
    }

    /// Within the coming week, a bare weekday is unambiguous — this is the
    /// common case for Claude's 5-hour/7-day windows.
    func testAbsoluteWeekdayFormatWithinSixDays() {
        let now = Date()
        let date = now.addingTimeInterval(3 * 24 * 60 * 60)
        let expected = DateFormatter()
        expected.dateFormat = "EEE h:mm a"
        XCTAssertEqual(ResetText.label(for: date, now: now), "Resets \(expected.string(from: date))")
    }

    /// Past six days, a bare weekday recurs and is ambiguous — this is
    /// Cursor's monthly billing-cycle reset, which is what originally exposed
    /// the bug (shown as "Resets Wed 12:29 AM" with no indication of which
    /// Wednesday).
    func testAbsoluteMonthDayFormatBeyondSixDays() {
        let now = Date()
        let date = now.addingTimeInterval(10 * 24 * 60 * 60)
        let expected = DateFormatter()
        expected.dateFormat = "MMM d"
        XCTAssertEqual(ResetText.label(for: date, now: now), "Resets \(expected.string(from: date))")
    }
}
