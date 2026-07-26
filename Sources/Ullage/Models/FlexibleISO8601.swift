import Foundation

/// Parses ISO-8601 timestamps with either millisecond or microsecond
/// fractional seconds and either `Z` or `+00:00`-style offsets.
enum FlexibleISO8601 {
    private static let withFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let withoutFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static func date(from string: String) -> Date? {
        if let date = withFractional.date(from: string) {
            return date
        }
        if let date = withoutFractional.date(from: string) {
            return date
        }
        return dateByTruncatingFractionalSeconds(string)
    }

    /// `ISO8601DateFormatter` only accepts up to millisecond precision;
    /// truncate longer fractional seconds (e.g. microseconds) and retry.
    private static func dateByTruncatingFractionalSeconds(_ string: String) -> Date? {
        guard let dotRange = string.range(of: "."),
              let endIndex = string[dotRange.upperBound...].firstIndex(where: { !$0.isNumber })
        else {
            return nil
        }
        let fractional = string[dotRange.upperBound..<endIndex].prefix(3)
        let normalized = string.replacingCharacters(in: dotRange.upperBound..<endIndex, with: String(fractional))
        return withFractional.date(from: normalized)
    }
}
