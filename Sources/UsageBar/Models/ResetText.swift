import Foundation

/// Formats a reset `Date` the way Claude's own usage panel does: relative
/// ("Resets in 55 min") when the reset is coming up soon, absolute
/// ("Resets Fri 8:00 AM") once it's far enough out that a countdown isn't useful.
enum ResetText {
    static func label(for date: Date?, now: Date = Date()) -> String {
        guard let date else { return "Resets —" }
        let interval = date.timeIntervalSince(now)
        if interval <= 0 {
            return "Resets soon"
        }
        if interval < 36 * 60 * 60 {
            return "Resets in \(relative(interval))"
        }
        return "Resets \(absolute(date))"
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

    private static func absolute(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE h:mm a"
        return formatter.string(from: date)
    }
}
