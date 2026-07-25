import XCTest
@testable import UsageBar

final class ResetTextTests: XCTestCase {
    // MARK: - Countdown (left half)

    func testNilDate() {
        XCTAssertEqual(ResetText.countdown(for: nil), "Resets —")
        XCTAssertNil(ResetText.clock(for: nil))
        XCTAssertEqual(ResetText.label(for: nil), "Resets —")
    }

    func testPastOrNowResetsSoon() {
        let now = Date()
        XCTAssertEqual(ResetText.countdown(for: now, now: now), "Resets soon")
        XCTAssertEqual(ResetText.countdown(for: now.addingTimeInterval(-10), now: now), "Resets soon")
        // Nothing to place on a clock once it's already gone.
        XCTAssertNil(ResetText.clock(for: now, now: now))
        XCTAssertEqual(ResetText.label(for: now, now: now), "Resets soon")
    }

    func testRelativeMinutes() {
        let now = Date()
        XCTAssertEqual(ResetText.countdown(for: now.addingTimeInterval(55 * 60), now: now), "Resets in 55 min")
    }

    func testRelativeHoursAndMinutes() {
        let now = Date()
        XCTAssertEqual(ResetText.countdown(for: now.addingTimeInterval(90 * 60), now: now), "Resets in 1 hr 30 min")
    }

    func testRelativeWholeHours() {
        let now = Date()
        XCTAssertEqual(ResetText.countdown(for: now.addingTimeInterval(2 * 60 * 60), now: now), "Resets in 2 hr")
    }

    /// Every row now carries a countdown, including the far-out ones that used
    /// to show only an absolute date (Claude's weekly window, Cursor's month).
    func testRelativeDaysForFarOutResets() {
        let now = Date()
        XCTAssertEqual(ResetText.countdown(for: now.addingTimeInterval(30 * 60 * 60), now: now), "Resets in 1 day")
        XCTAssertEqual(ResetText.countdown(for: now.addingTimeInterval(4 * 86_400), now: now), "Resets in 4 days")
        XCTAssertEqual(ResetText.countdown(for: now.addingTimeInterval(10 * 86_400), now: now), "Resets in 10 days")
    }

    // MARK: - Clock (right half)

    /// The case this feature exists for: a reset a few hours out, answered as a
    /// time of day. A weekday would be noise when it's still today.
    func testClockLaterTodayIsTimeOnly() throws {
        let calendar = Calendar.current
        let now = try XCTUnwrap(calendar.date(bySettingHour: 10, minute: 0, second: 0, of: Date()))
        let date = try XCTUnwrap(calendar.date(bySettingHour: 14, minute: 30, second: 0, of: now))

        let expected = DateFormatter()
        expected.setLocalizedDateFormatFromTemplate("jmm")
        XCTAssertEqual(ResetText.clock(for: date, now: now), expected.string(from: date))
    }

    /// Crossing midnight — a 4-hour window opened at 22:00 resets tomorrow, and
    /// the weekday is the whole point.
    func testClockTomorrowCarriesTheWeekday() throws {
        let calendar = Calendar.current
        let now = try XCTUnwrap(calendar.date(bySettingHour: 22, minute: 0, second: 0, of: Date()))
        let date = now.addingTimeInterval(4 * 60 * 60)

        let expected = DateFormatter()
        expected.setLocalizedDateFormatFromTemplate("EEEjmm")
        XCTAssertEqual(ResetText.clock(for: date, now: now), expected.string(from: date))
    }

    /// Within the coming week a bare weekday is unambiguous — the common case
    /// for Claude's 7-day window.
    func testClockWeekdayFormatWithinSixDays() {
        let now = Date()
        let date = now.addingTimeInterval(3 * 86_400)
        let expected = DateFormatter()
        expected.setLocalizedDateFormatFromTemplate("EEEjmm")
        XCTAssertEqual(ResetText.clock(for: date, now: now), expected.string(from: date))
    }

    /// Past six days a bare weekday recurs and is ambiguous — this is Cursor's
    /// monthly billing-cycle reset, which originally exposed the bug (shown as
    /// "Resets Wed 12:29 AM" with no indication of *which* Wednesday). Splitting
    /// the label in two must not reintroduce it.
    func testClockMonthDayFormatBeyondSixDays() {
        let now = Date()
        let date = now.addingTimeInterval(10 * 86_400)
        let expected = DateFormatter()
        expected.setLocalizedDateFormatFromTemplate("MMMd")
        XCTAssertEqual(ResetText.clock(for: date, now: now), expected.string(from: date))
    }

    /// Uses a localized template rather than a literal "h:mm a", so a user on a
    /// 24-hour clock isn't forced into 12-hour formatting. The previous
    /// implementation hardcoded the 12-hour pattern and would fail the British
    /// half of this outright.
    func testClockFollowsTheLocalesHourCycle() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = Date(timeIntervalSince1970: 1_784_120_400)          // 13:00 UTC
        let date = now.addingTimeInterval(4 * 60 * 60 + 47 * 60)      // 17:47 UTC

        let american = try XCTUnwrap(
            ResetText.clock(for: date, now: now, calendar: calendar, locale: Locale(identifier: "en_US"))
        )
        let british = try XCTUnwrap(
            ResetText.clock(for: date, now: now, calendar: calendar, locale: Locale(identifier: "en_GB"))
        )

        XCTAssertTrue(american.contains("PM"), "expected a 12-hour clock for en_US, got \(american)")
        XCTAssertFalse(british.contains("PM"), "expected a 24-hour clock for en_GB, got \(british)")
        XCTAssertTrue(british.contains("17"), "expected 24-hour hour for en_GB, got \(british)")
    }

    // MARK: - Combined single-line form

    /// For layouts with no right-hand column (the Cursor cost card).
    func testLabelJoinsBothHalves() {
        let now = Date()
        let date = now.addingTimeInterval(10 * 86_400)
        let clock = ResetText.clock(for: date, now: now) ?? ""
        XCTAssertEqual(ResetText.label(for: date, now: now), "Resets in 10 days · \(clock)")
    }
}
