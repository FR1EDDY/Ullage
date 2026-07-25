import SwiftUI

/// Spend broken down by project — the unit people actually think in.
///
/// "Which model cost the most" is interesting; "which repo cost the most" is
/// the question someone asks when they're deciding where the money went. It's
/// available for free: every log line carries the `cwd` it ran in.
struct ProjectCostSectionView: View {
    let projects: [ProjectCost]
    let total: Double
    let brandGradient: LinearGradient

    /// Enough to see where the money is, few enough to keep the panel short.
    private static let visibleCount = 4

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "folder")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                Text("By project")
                    .font(.headline)
                Spacer()
                Text("30 days")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            let shown = Array(projects.prefix(Self.visibleCount))
            let peak = shown.first?.cost ?? 0

            ForEach(shown) { project in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(Self.displayName(project.name))
                            .font(.caption)
                            .lineLimit(1)
                            .truncationMode(.head)   // keep the folder, drop the path
                        Spacer(minLength: 6)
                        Text(CostSectionView.currency(project.cost))
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(.primary)
                    }
                    // A proportional bar rather than a percentage: the relative
                    // shape is the whole message, and a second number per row
                    // would bury it.
                    GeometryReader { proxy in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.secondary.opacity(0.12))
                            Capsule()
                                .fill(brandGradient)
                                .frame(width: proxy.size.width * (peak > 0 ? project.cost / peak : 0))
                        }
                    }
                    .frame(height: 4)
                }
                .help("\(project.requestCount) request\(project.requestCount == 1 ? "" : "s") · \(project.name)")
            }

            if let remainder {
                Text(remainder)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    /// The rest, folded into one honest line — dropping them silently would
    /// make the visible rows look like the whole bill.
    private var remainder: String? {
        guard projects.count > Self.visibleCount else { return nil }
        let rest = projects.dropFirst(Self.visibleCount)
        let restCost = rest.reduce(0) { $0 + $1.cost }
        return "+ \(rest.count) more · \(CostSectionView.currency(restCost))"
    }

    /// `/Users/me/Desktop/UsageTracker` → `UsageTracker`. The full path is in
    /// the tooltip for when two projects share a folder name.
    static func displayName(_ path: String) -> String {
        let name = (path as NSString).lastPathComponent
        return name.isEmpty ? path : name
    }
}
