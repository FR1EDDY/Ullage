import SwiftUI

/// A single meter row: title + "N% used" on top, a rounded capsule bar, and
/// a muted reset subtitle below — echoing Claude's own usage settings panel.
struct UsageBarView: View {
    let title: String
    let window: UsageWindow
    var compact: Bool = false

    private var color: Color {
        switch window.percentUsed {
        case ..<50: return .blue
        case 50..<80: return .yellow
        default: return .red
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .font(compact ? .caption : .subheadline)
                    .foregroundStyle(.primary)
                Spacer()
                Text("\(Int(window.percentUsed.rounded()))% used")
                    .font(compact ? .caption2 : .caption)
                    .foregroundStyle(.secondary)
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(color.opacity(0.18))
                    Capsule()
                        .fill(color)
                        .frame(width: proxy.size.width * fraction)
                }
            }
            .frame(height: compact ? 5 : 7)
            Text(ResetText.label(for: window.resetsAt))
                .font(.caption2)
                .foregroundStyle(.tertiary)
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
