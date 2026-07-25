import Foundation

/// What the menu-bar badge renders. Persisted as its `rawValue`.
enum BadgeDisplayMode: String, CaseIterable, Identifiable, Sendable {
    case both
    case claude
    case cursor

    var id: String { rawValue }

    var title: String {
        switch self {
        case .both: return "Both"
        case .claude: return "Claude"
        case .cursor: return "Cursor"
        }
    }
}

/// User-chosen polling cadence. Presets only — free-form seconds would fight
/// Claude's rate limits. Persisted as minutes in `UserDefaults`.
enum RefreshIntervalOption: Int, CaseIterable, Identifiable, Sendable {
    case five = 5
    case ten = 10
    case fifteen = 15

    var id: Int { rawValue }

    var title: String { "\(rawValue) min" }

    var timeInterval: TimeInterval { TimeInterval(rawValue * 60) }
}
