import Foundation

/// A single usage window (e.g. the 5-hour session limit, or the weekly
/// all-models limit) normalized to a 0...100 percentage.
struct UsageWindow: Equatable {
    var percentUsed: Double
    var resetsAt: Date?
    var isActive: Bool

    static let empty = UsageWindow(percentUsed: 0, resetsAt: nil, isActive: false)
}

/// Whole-account Claude usage — shared across claude.ai, Claude Code, and Cowork.
struct ClaudeUsage: Equatable {
    var planName: String?
    var session: UsageWindow
    var weeklyAllModels: UsageWindow
}

struct CursorUsage: Equatable {
    var percentUsed: Double
    var resetsAt: Date?
    var cycleLabel: String?
}

enum UsageError: Error, LocalizedError, Equatable {
    case missingCredentials
    case httpStatus(Int)
    case decoding(String)
    case network(String)

    var errorDescription: String? {
        switch self {
        case .missingCredentials:
            return "Not signed in to Claude Code"
        case .httpStatus(let code):
            return "Claude usage request failed (\(code))"
        case .decoding(let detail):
            return "Couldn't parse Claude usage response (\(detail))"
        case .network(let detail):
            return detail
        }
    }
}
