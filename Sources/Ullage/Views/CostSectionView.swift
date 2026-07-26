import SwiftUI

/// The Cost card: what Claude Code actually cost, read from local transcripts.
///
/// Deliberately two numbers and a shape rather than a table. "Today" is the one
/// people check reflexively; "30 days" is the one that tells them whether today
/// was normal. The chart exists to answer that second question at a glance, so
/// it carries no axis, no labels, and no legend — it is a sparkline, not a
/// report.
struct CostSectionView: View {
    let summary: CostSummary
    let brandColor: Color
    let brandGradient: LinearGradient

    /// How many days the chart shows. Matches the "30 days" figure beside it.
    private static let chartDays = 30

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Names the provider, not the concept — the panel it sits in is
            // already titled "Cost", and this card will one day have siblings.
            HStack(spacing: 10) {
                if let icon = ProviderRegistry.descriptor(.claude)?.icon {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 32, height: 32)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                } else {
                    Image(systemName: "dollarsign.circle.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(brandColor)
                        .frame(width: 32, height: 32)
                }
                Text("Claude Code")
                    .font(.headline)
                Spacer()
                Text("local")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            if summary.isEmpty {
                Text("No local Claude Code usage found yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 20) {
                    figure(label: "Today", amount: summary.today, prominent: true)
                    figure(label: "30 days", amount: summary.last30Days, prominent: false)
                    Spacer()
                }

                chart

                Text(footnote)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)

                if let cacheLine {
                    Divider().opacity(0.5)
                    // A fact about the bill you already paid, not a projection.
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: summary.cache.net >= 0 ? "arrow.down.circle" : "arrow.up.circle")
                            .font(.system(size: 9))
                        Text(cacheLine)
                        Spacer(minLength: 4)
                    }
                    .font(.caption2)
                    .foregroundStyle(summary.cache.net >= 0 ? AnyShapeStyle(.secondary) : AnyShapeStyle(.orange))
                    .lineLimit(1)
                    .help(cacheDetail)
                }

                if let alternativesLine {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(alternativesLine)
                        Spacer(minLength: 4)
                    }
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    // Wraps rather than truncating — a clipped price is worse
                    // than a second line.
                    .fixedSize(horizontal: false, vertical: true)
                    .help(
                        """
                        The same \(Self.tokens(summary.last30DaysTokens.total)) tokens priced at each model's rate.

                        This is arithmetic, not a suggestion — it assumes the token counts would be identical, and a different model may need more attempts or produce longer output.
                        """
                    )
                }

                if !summary.unpricedModels.isEmpty {
                    // Never folded into the totals as $0 — an unpriced model is
                    // missing information, and saying so is the honest version
                    // of a number the user is meant to trust.
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "questionmark.circle")
                        Text("\(summary.unpricedRequests) request\(summary.unpricedRequests == 1 ? "" : "s") unpriced (\(summary.unpricedModels.joined(separator: ", ")))")
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func figure(label: String, amount: Double, prominent: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(Self.currency(amount))
                .font(.system(size: prominent ? 22 : 17, weight: .semibold, design: .rounded))
                .foregroundStyle(prominent ? AnyShapeStyle(brandGradient) : AnyShapeStyle(.primary))
                .monospacedDigit()
        }
    }

    /// One bar per day, including the empty ones — a gap is information (a day
    /// you didn't work), and compressing it out would silently distort the
    /// shape into something that reads as continuous usage.
    private var chart: some View {
        let days = Self.filledDays(from: summary, count: Self.chartDays)
        let peak = days.map(\.cost).max() ?? 0

        // A continuous baseline behind the bars, rather than drawing idle days
        // as stub bars. As stubs they read as broken dashes — a rendering
        // fault, not an idle week. An axis they rise from says the same thing
        // and looks deliberate.
        return ZStack(alignment: .bottom) {
            Rectangle()
                .fill(Color.secondary.opacity(0.18))
                .frame(height: 1)

            HStack(alignment: .bottom, spacing: 2) {
                ForEach(days) { day in
                    let fraction = peak > 0 ? day.cost / peak : 0
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(day.cost > 0 ? AnyShapeStyle(brandGradient) : AnyShapeStyle(Color.clear))
                        // A floor of 2pt so a real-but-tiny day stays visible
                        // rather than rounding away into the baseline.
                        .frame(height: day.cost > 0 ? max(2, 28 * fraction) : 1)
                }
            }
        }
        .frame(height: 28, alignment: .bottom)
        .help("Daily spend over the last \(Self.chartDays) days")
    }

    /// Prompt caching's actual effect on the bill. Hidden below a cent, where
    /// the number would be noise rather than information.
    private var cacheLine: String? {
        let net = summary.cache.net
        guard abs(net) >= 0.01 else { return nil }
        return net >= 0
            ? "Caching saved \(Self.currency(net))"
            : "Caching cost \(Self.currency(-net)) more than it saved"
    }

    /// The break-even arithmetic, for the tooltip. A one-hour cache write is
    /// billed at 2× the input rate and needs roughly 1.1 reads per written
    /// token to pay for itself; the five-minute TTL needs about 0.28.
    private var cacheDetail: String {
        var lines = [
            "Reads saved \(Self.currency(summary.cache.savedByReads)); writes cost \(Self.currency(summary.cache.premiumOnWrites)) extra.",
            "\(Self.tokens(summary.cache.readTokens)) read · \(Self.tokens(summary.cache.writeTokens5m)) written at 5-min · \(Self.tokens(summary.cache.writeTokens1h)) at 1-hour."
        ]
        if let ratio = summary.cache.readsPerWrittenToken {
            lines.append(String(format: "Each cached token was read back %.2f times on average.", ratio))
        }
        return lines.joined(separator: "\n\n")
    }

    /// Only shown once there's enough volume for the comparison to mean
    /// anything — a re-pricing of four requests is a rounding error.
    ///
    /// The model you're already using is dropped: re-pricing your tokens at the
    /// rate you actually paid is a comparison with itself. Two alternatives is
    /// also all that fits on one line, and rounding to whole dollars matches the
    /// precision the comparison genuinely has.
    private var alternativesLine: String? {
        guard summary.requestCount >= 20 else { return nil }
        let currentFamily = summary.topModel.map(Self.displayName)
        let others = summary.alternatives
            .filter { Self.displayName($0.model) != currentFamily }
            .prefix(2)
        guard !others.isEmpty else { return nil }

        let parts = others.map {
            "\(Self.displayName($0.model)) \(Self.wholeDollars($0.cost))"
        }
        return "Same tokens: " + parts.joined(separator: " · ")
    }

    /// Whole dollars. Cents on a hypothetical are false precision.
    static func wholeDollars(_ amount: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "USD"
        formatter.locale = Locale(identifier: "en_US")
        formatter.maximumFractionDigits = 0
        return formatter.string(from: NSNumber(value: amount)) ?? "$0"
    }

    private var footnote: String {
        var parts = ["\(Self.tokens(summary.last30DaysTokens.total)) tokens"]
        if let top = summary.topModel {
            parts.append("\(Self.displayName(top)) \(Self.currency(summary.topModelCost))")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Formatting

    /// The summary only carries days that had usage, so the chart fills the
    /// rest here — in the view, where "day" is a local-calendar idea.
    static func filledDays(from summary: CostSummary, count: Int, calendar: Calendar = .current, now: Date = Date()) -> [DailyCost] {
        let byDay = Dictionary(summary.daily.map { ($0.day, $0) }, uniquingKeysWith: { first, _ in first })
        let today = calendar.startOfDay(for: now)
        return (0..<count).reversed().compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: -offset, to: today) else { return nil }
            return byDay[day] ?? DailyCost(day: day, cost: 0, tokens: 0)
        }
    }

    static func currency(_ amount: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "USD"
        // Pinned to en_US so this reads "$45.67" rather than the "US$ 45.67"
        // a non-US locale produces. Both Anthropic's and Cursor's own dashboards
        // say "$", and these figures exist to be checked against them — matching
        // their notation matters more than matching the system locale. It also
        // buys back three characters in a panel that is genuinely width-bound.
        formatter.locale = Locale(identifier: "en_US")
        // Sub-cent precision below a cent, so a genuinely tiny spend reads as a
        // small number rather than the "$0.00" that looks like a broken meter.
        formatter.maximumFractionDigits = (amount > 0 && amount < 0.01) ? 4 : 2
        formatter.minimumFractionDigits = 2
        return formatter.string(from: NSNumber(value: amount)) ?? "$0.00"
    }

    static func tokens(_ count: Int) -> String {
        switch count {
        case ..<1_000: return "\(count)"
        case ..<1_000_000: return String(format: "%.1fK", Double(count) / 1_000)
        case ..<1_000_000_000: return String(format: "%.1fM", Double(count) / 1_000_000)
        default: return String(format: "%.2fB", Double(count) / 1_000_000_000)
        }
    }

    /// `claude-opus-4-8` → `Opus 4.8`. The card is about *your* spend, and the
    /// full API id is noise once you know which family it is.
    static func displayName(_ model: String) -> String {
        var name = ModelPricing.strippingDateSuffix(model) ?? model
        if name.hasPrefix("claude-") { name.removeFirst("claude-".count) }
        let parts = name.split(separator: "-").map(String.init)
        guard let family = parts.first else { return model }
        let version = parts.dropFirst().joined(separator: ".")
        let capitalized = family.prefix(1).uppercased() + family.dropFirst()
        return version.isEmpty ? capitalized : "\(capitalized) \(version)"
    }
}
