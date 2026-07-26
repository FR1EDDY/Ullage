import Foundation

/// The pre-registry menu-bar setting: a fixed three-way choice over exactly two
/// providers. Kept **only** to migrate existing installs to `BadgeSelection`,
/// which generalises to any number of platforms. Nothing new should use it.
enum BadgeDisplayMode: String, Sendable {
    case both
    case claude
    case cursor

    var providers: [ProviderID] {
        switch self {
        case .both: return [.claude, .cursor]
        case .claude: return [.claude]
        case .cursor: return [.cursor]
        }
    }
}

/// Which platforms appear in the menu bar, in order, capped at
/// `ProviderRegistry.maxBadgeProviders`.
///
/// An ordered array rather than a `Set` because the order is visible — it's the
/// left-to-right order of the badge — and a set would let it shuffle between
/// launches.
struct BadgeSelection: Equatable, Sendable {
    private(set) var providers: [ProviderID]

    init(_ providers: [ProviderID]) {
        // Deduplicated and capped on the way in, so no other code has to trust
        // its caller: the invariant lives with the value.
        var seen: Set<ProviderID> = []
        self.providers = providers
            .filter { seen.insert($0).inserted }
            .prefix(ProviderRegistry.maxBadgeProviders)
            .map { $0 }
    }

    var isFull: Bool { providers.count >= ProviderRegistry.maxBadgeProviders }

    func contains(_ id: ProviderID) -> Bool { providers.contains(id) }

    /// Toggling the last remaining provider is a no-op: an empty badge would be
    /// an invisible menu-bar item the user then can't click to fix.
    func toggling(_ id: ProviderID) -> BadgeSelection {
        if providers.contains(id) {
            guard providers.count > 1 else { return self }
            return BadgeSelection(providers.filter { $0 != id })
        }
        guard !isFull else { return self }
        return BadgeSelection(providers + [id])
    }

    // MARK: - Persistence

    /// Stored as a comma-joined list of raw values — readable in `defaults
    /// read`, and trivially forward-compatible with more providers.
    var storageValue: String { providers.map(\.rawValue).joined(separator: ",") }

    static func fromStorage(_ value: String?) -> BadgeSelection? {
        guard let value, !value.isEmpty else { return nil }
        let parsed = value.split(separator: ",").compactMap { ProviderID(rawValue: String($0)) }
        return parsed.isEmpty ? nil : BadgeSelection(parsed)
    }

    static let `default` = BadgeSelection([.claude, .cursor])
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
