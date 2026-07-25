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
                Text(ResetText.label(for: window.resetsAt))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
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
