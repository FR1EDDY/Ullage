import Foundation

/// Formats a reset `Date` the way Claude's own usage panel does: relative
/// ("Resets in 55 min") when the reset is coming up soon, absolute
/// ("Resets Fri 8:00 AM") once it's far enough out that a countdown isn't useful.
enum ResetText {
    /// Past this, a weekday name alone is ambiguous — "Wed" could be any of
    /// several Wednesdays — so the absolute format switches to a calendar date.
    /// Claude's reset windows (5-hour, 7-day) never reach this far, but
    /// Cursor's monthly billing-cycle reset routinely does.
    private static let weekdayAmbiguityThreshold: TimeInterval = 6 * 24 * 60 * 60

    static func label(for date: Date?, now: Date = Date()) -> String {
        guard let date else { return "Resets —" }
        let interval = date.timeIntervalSince(now)
        if interval <= 0 {
            return "Resets soon"
        }
        if interval < 36 * 60 * 60 {
            return "Resets in \(relative(interval))"
        }
        return "Resets \(absolute(date, interval: interval))"
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

    private static func absolute(_ date: Date, interval: TimeInterval) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = interval < weekdayAmbiguityThreshold ? "EEE h:mm a" : "MMM d"
        return formatter.string(from: date)
    }
}
