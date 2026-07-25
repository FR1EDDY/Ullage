import AppKit
import SwiftUI

/// A single meter row: title + "N% used" on top, a rounded capsule bar, and
/// a muted reset subtitle below — echoing Claude's own usage settings panel.
struct UsageBarView: View {
    let title: String
    let window: UsageWindow
    var compact: Bool = false
    /// Per-app brand tint (e.g. Claude's coral, Cursor's blue). When set, the
    /// bar uses this instead of the blue/yellow/red severity scale, except
    /// once a window is genuinely near its cap — the danger signal still
    /// needs to cut through the branding.
    var brandColor: Color? = nil
    var brandGradient: LinearGradient? = nil
    /// The app's real icon, looked up live from the installed app on disk.
    var icon: NSImage? = nil
    var inactive: Bool = false
    /// Where this window is heading. Shown under the reset row, and never
    /// without its confidence qualifier.
    var forecast: ForecastLine? = nil

    private var color: Color {
        guard let brandColor else {
            switch window.percentUsed {
            case ..<50: return .blue
            case 50..<80: return .yellow
            default: return .red
            }
        }
        return window.percentUsed >= 80 ? .red : brandColor
    }

    var body: some View {
        HStack(alignment: .top, spacing: compact ? 10 : 8) {
            if let icon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: compact ? 28 : 18, height: compact ? 28 : 18)
                    .clipShape(RoundedRectangle(cornerRadius: compact ? 7 : 4, style: .continuous))
                    .opacity(inactive ? 0.8 : 1.0)
                    .mask(
                        Group {
                            if inactive {
                                Image(nsImage: icon)
                                    .resizable()
                                    .luminanceToAlpha()
                            } else {
                                Rectangle()
                            }
                        }
                    )
            }
            VStack(alignment: .leading, spacing: compact ? 4 : 4) {
                HStack {
                    Text(title)
                        .font(compact ? .subheadline.weight(.semibold) : .subheadline)
                        .foregroundStyle(.primary)
                    Spacer()
                    Text("\(Int(window.percentUsed.rounded()))% used")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(color.opacity(0.18))
                        if window.percentUsed < 80, let brandGradient {
                            Capsule()
                                .fill(brandGradient)
                                .frame(width: proxy.size.width * fraction)
                                .shadow(color: color.opacity(0.3), radius: 3, x: 0, y: 0)
                        } else {
                            Capsule()
                                .fill(color)
                                .frame(width: proxy.size.width * fraction)
                                .shadow(color: color.opacity(0.3), radius: 3, x: 0, y: 0)
                        }
                    }
                }
                .frame(height: compact ? 6 : 7)
                // Countdown left, wall-clock right — the row already had the
                // width, and the two answer different questions ("how long
                // have I got" vs "what time is that").
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(ResetText.countdown(for: window.resetsAt))
                    Spacer(minLength: 4)
                    if let clock = ResetText.clock(for: window.resetsAt) {
                        Text(clock)
                    }
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)

                // The forecast mirrors the reset row's two-column shape — the
                // claim on the left, its qualifier on the right — so the card
                // reads as one grid rather than a stack of unrelated lines.
                if let forecast {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        if forecast.isAlarming {
                            Image(systemName: "bolt.fill")
                                .font(.system(size: 8))
                        }
                        Text(forecast.text)
                        Spacer(minLength: 4)
                        if let chip = forecast.confidence.chip {
                            Text(chip)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .font(.caption2)
                    // A runaway session shifts the accent rather than raising a
                    // banner: it's a heads-up, not an error, and the calm of
                    // this panel is worth more than a louder alert.
                    .foregroundStyle(forecast.isAlarming ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
                    .help(forecast.tooltip)
                }
            }
        }
    }

    private var fraction: CGFloat {
        CGFloat(min(max(window.percentUsed / 100, 0), 1))
    }
}

#Preview {
    VStack(spacing: 16) {
        UsageBarView(
            title: "Current session",
            window: UsageWindow(percentUsed: 15, resetsAt: Date().addingTimeInterval(3300), isActive: true)
        )
        UsageBarView(
            title: "Weekly · all models",
            window: UsageWindow(percentUsed: 82, resetsAt: Date().addingTimeInterval(86_400 * 3), isActive: true)
        )
    }
    .padding()
    .frame(width: 300)
}
