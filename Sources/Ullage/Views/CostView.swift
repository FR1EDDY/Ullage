import SwiftUI
import AppKit

/// The Cost panel — reached from the `$` button in the footer, and structured
/// like `SettingsView` so the swap reads as one surface rather than a second
/// window.
///
/// Cost lives here rather than in the main panel because it answers a different
/// question from the meters: those are "how close am I to a limit", this is
/// "what has it cost". Keeping them apart keeps the default view calm, and
/// gives spend a home that can hold **every** provider rather than hanging off
/// the Claude card — the unified cost surface is the whole point of the wedge.
struct CostView: View {
    @ObservedObject var model: UsageModel
    var onBack: () -> Void

    private static let claudeBrand = ProviderRegistry.descriptor(.claude)?.brand ?? Color(red: 0.851, green: 0.467, blue: 0.341)
    private static let claudeGradient = LinearGradient(
        colors: [Color(red: 0.9, green: 0.5, blue: 0.3), Color(red: 0.8, green: 0.35, blue: 0.25)],
        startPoint: .leading,
        endPoint: .trailing
    )
    private static let cursorBrand = ProviderRegistry.descriptor(.cursor)?.brand ?? Color(red: 0.298, green: 0.545, blue: 0.965)
    private static let cursorGradient = LinearGradient(
        colors: [Color(red: 0.3, green: 0.7, blue: 1.0), Color(red: 0.1, green: 0.4, blue: 0.9)],
        startPoint: .leading,
        endPoint: .trailing
    )

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                BackButton(action: onBack)

                Spacer()

                Text("Cost")
                    .font(.headline)

                Spacer()

                // Balances the Back pill so the title stays centred.
                Color.clear
                    .frame(width: 64, height: 1)
            }
            .padding(.horizontal, 2)

            if let cost = model.cost, !cost.isEmpty {
                card {
                    CostSectionView(
                        summary: cost,
                        brandColor: Self.claudeBrand,
                        brandGradient: Self.claudeGradient
                    )
                }
            }

            if let cost = model.cost, cost.byProject.count > 1 {
                // Only worth a card when there's more than one project — a
                // single bar showing 100% of the bill says nothing.
                card {
                    ProjectCostSectionView(
                        projects: cost.byProject,
                        total: cost.last30Days,
                        brandGradient: Self.claudeGradient
                    )
                }
            }

            // Cursor's spend comes from the response we already fetch for its
            // meter, so this card costs no extra request. It only appears once
            // that response actually carried a spend figure.
            if let cursor = model.cursor, cursor.hasSpend {
                card {
                    CursorCostSectionView(
                        usage: cursor,
                        brandColor: Self.cursorBrand,
                        brandGradient: Self.cursorGradient
                    )
                }
            }

            if !CostView.hasAnySpend(model) {
                card {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("No spend to show yet.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("Claude Code costs are read from ~/.claude/projects — no network needed. Cursor spend arrives with its usage.")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }

    /// Drives both this panel's empty state and whether the `$` button appears
    /// at all, so the button can never open a panel with nothing in it.
    static func hasAnySpend(_ model: UsageModel) -> Bool {
        if let cost = model.cost, !cost.isEmpty { return true }
        if let cursor = model.cursor, cursor.hasSpend { return true }
        return false
    }

    @ViewBuilder
    private func card(@ViewBuilder _ content: () -> some View) -> some View {
        content().cardStyle()
    }
}
