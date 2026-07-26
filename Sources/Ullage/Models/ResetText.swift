import Foundation

/// The two halves of a reset subtitle: how long you have (`countdown`) and when
/// that actually lands on your own clock (`clock`).
///
/// These used to be one string that showed *either* a countdown or an absolute
/// time depending on distance — "Resets in 55 min" up close, "Resets Fri 8:00 AM"
/// further out. Each answers a different question, though, and a meter row has
/// room for both: "in 3 hr 49 min" tells you whether to keep working, "11:47 PM"
/// tells you whether that's before or after you go to bed.
///
/// Everything below is the display layer, so it is the one place that may use
/// the user's own calendar and time zone — the reset instants themselves are
/// absolute, and stay absolute everywhere else in the app.
enum ResetText {
    /// Past this, a bare weekday recurs and is ambiguous — "Wed" could be any
    /// of several Wednesdays — so the clock switches to a calendar date. This
    /// is what Cursor's monthly billing-cycle reset needs; Claude's 5-hour and
    /// 7-day windows never reach it.
    private static let weekdayAmbiguityThreshold: TimeInterval = 6 * 24 * 60 * 60

    /// Left half — "Resets in 3 hr 49 min".
    static func countdown(for date: Date?, now: Date = Date()) -> String {
        guard let date else { return "Resets —" }
        let interval = date.timeIntervalSince(now)
        guard interval > 0 else { return "Resets soon" }
        return "Resets in \(relative(interval))"
    }

    /// Right half — the wall-clock instant in the user's own time zone, or
    /// `nil` when there's nothing to place (no date, or it has already passed).
    ///
    /// Three shapes, each dropping the detail that stops being useful:
    ///   - later today → `11:47 PM` (a weekday would be noise)
    ///   - within six days → `Fri 8:00 AM`
    ///   - beyond that → `Aug 5` (a precise time three weeks out is noise)
    static func clock(
        for date: Date?,
        now: Date = Date(),
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> String? {
        guard let date else { return nil }
        let interval = date.timeIntervalSince(now)
        guard interval > 0 else { return nil }

        let formatter = DateFormatter()
        // Set before the template is resolved — the template is interpreted
        // against the formatter's locale, so assigning it afterwards would have
        // no effect on the pattern already chosen.
        formatter.locale = locale
        // Rendered in the same zone the same-day comparison below uses.
        // `DateFormatter` otherwise defaults to the system zone independently of
        // the calendar, so the two could disagree and label a reset "today" while
        // printing tomorrow's hour.
        formatter.timeZone = calendar.timeZone
        // Templates rather than literal patterns, so someone on a 24-hour clock
        // sees "23:47" and not "11:47 PM". `dateFormat = "h:mm a"` would have
        // forced 12-hour formatting on every user regardless of their settings.
        if calendar.isDate(date, inSameDayAs: now) {
            formatter.setLocalizedDateFormatFromTemplate("jmm")
        } else if interval < weekdayAmbiguityThreshold {
            formatter.setLocalizedDateFormatFromTemplate("EEEjmm")
        } else {
            formatter.setLocalizedDateFormatFromTemplate("MMMd")
        }
        return formatter.string(from: date)
    }

    /// Both halves on one line, for layouts with no right-hand column to put
    /// the clock in.
    static func label(for date: Date?, now: Date = Date()) -> String {
        let countdown = countdown(for: date, now: now)
        guard let clock = clock(for: date, now: now) else { return countdown }
        return "\(countdown) · \(clock)"
    }

    private static func relative(_ interval: TimeInterval) -> String {
        let totalMinutes = max(1, Int((interval / 60).rounded()))
        if totalMinutes < 60 {
            return "\(totalMinutes) min"
        }
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        if hours < 24 {
            return minutes == 0 ? "\(hours) hr" : "\(hours) hr \(minutes) min"
        }
        let days = hours / 24
        return "\(days) day\(days == 1 ? "" : "s")"
    }
}
