import SwiftUI
import AppKit

/// Cursor's half of the Cost panel: spend for the current billing cycle,
/// straight out of the response we already fetch for its meter.
///
/// Mirrors the three tiles Cursor's own dashboard leads with (Total spend /
/// Included / On-demand) so the numbers are recognisably the same ones — this
/// card has to survive being checked against the source, and a figure the user
/// can't reconcile is worse than no figure.
///
/// It deliberately shows no chart. Cursor gives us a cycle total, not a daily
/// series, and drawing a shape we can't actually derive would be inventing
/// detail. Claude's card has a chart because Claude's data supports one.
struct CursorCostSectionView: View {
    let usage: CursorUsage
    let brandColor: Color
    let brandGradient: LinearGradient

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                if let icon = ProviderRegistry.descriptor(.cursor)?.icon {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 32, height: 32)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                Text("Cursor")
                    .font(.headline)
                Spacer()
                Text("this cycle")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            HStack(alignment: .firstTextBaseline, spacing: 20) {
                figure(label: "Spend", amount: usage.totalSpend ?? 0, prominent: true)
                if let onDemand = usage.onDemandSpend {
                    figure(label: "On-demand", amount: onDemand, prominent: false)
                }
                Spacer()
            }

            if let allowanceLine {
                Text(allowanceLine)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    // Wraps rather than truncating. This line can be the most
                    // consequential thing on the card — "your allowance is gone"
                    // clipped to "…now on…" is worse than two lines.
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let constraintLine {
                Text(constraintLine)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let blockedWarning {
                // The one combination that stops work outright, stated before
                // it happens rather than discovered when Cursor refuses.
                HStack(alignment: .top, spacing: 5) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 9))
                    Text(blockedWarning)
                }
                .font(.caption2)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            }

            if let resetsAt = usage.resetsAt {
                Text(ResetText.label(for: resetsAt))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func figure(label: String, amount: Double, prominent: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(CostSectionView.currency(amount))
                .font(.system(size: prominent ? 22 : 17, weight: .semibold, design: .rounded))
                .foregroundStyle(prominent ? AnyShapeStyle(brandGradient) : AnyShapeStyle(.primary))
                .monospacedDigit()
        }
    }

    /// "Your included allowance is gone, the rest is bonus credit" is a
    /// materially different situation from "you've used some of it", and the
    /// dashboard's headline tiles don't distinguish them.
    /// Test seams. These two lines encode real rules about when to speak and
    /// when to stay quiet, which is exactly the part worth pinning.
    var constraintLineForTesting: String? { constraintLine }
    var blockedWarningForTesting: String? { blockedWarning }

    /// Which of the two pools runs out first. Cursor meters first-party ("auto")
    /// and named/API models against separate budgets, so the blended total can
    /// look comfortable while one half is nearly gone — the binding constraint
    /// is the one worth naming.
    private var constraintLine: String? {
        let auto = usage.firstPartyPercentUsed
        let api = usage.apiPercentUsed
        guard max(auto, api) > 0 else { return nil }
        // Only worth saying when the two genuinely diverge; otherwise the
        // blended figure above already tells the whole story.
        guard abs(auto - api) >= 15 else { return nil }
        return api > auto
            ? "Binding limit: API models at \(Int(api.rounded()))% (first-party \(Int(auto.rounded()))%)"
            : "Binding limit: first-party at \(Int(auto.rounded()))% (API \(Int(api.rounded()))%)"
    }

    /// Allowance spent *and* no on-demand billing configured. Cursor won't bill
    /// past the allowance, so once any bonus credit is gone the work simply
    /// stops. Stated as the fact it is, with no advice attached.
    private var blockedWarning: String? {
        guard usage.onDemandEnabled == false else { return nil }
        guard let remaining = usage.includedRemaining, remaining <= 0 else { return nil }
        return "On-demand is off — usage stops when credit runs out."
    }

    private var allowanceLine: String? {
        guard let allowance = usage.includedAllowance, allowance > 0 else { return nil }
        let allowanceText = CostSectionView.currency(allowance)
        guard let remaining = usage.includedRemaining else {
            return "\(allowanceText) included allowance"
        }
        if remaining <= 0 {
            return "\(allowanceText) included allowance spent — now on credit"
        }
        return "\(CostSectionView.currency(remaining)) of \(allowanceText) included left"
    }
}
