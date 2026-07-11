import SwiftUI
import AppKit

/// The dropdown panel shown when the menu-bar badge is clicked.
struct MenuContentView: View {
    @ObservedObject var model: UsageModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Claude")
                    .font(.headline)
                if let plan = model.planName {
                    Text(plan)
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.secondary.opacity(0.15)))
                }
                Spacer()
            }

            UsageBarView(title: "Current session", window: model.session)
            UsageBarView(title: "Weekly · all models", window: model.weeklyAllModels)

            if let error = model.claudeError {
                Text(error.errorDescription ?? "Claude usage unavailable")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }

            Divider()

            Text("Cursor")
                .font(.headline)

            if let cursor = model.cursor {
                UsageBarView(
                    title: cursor.cycleLabel ?? "This cycle",
                    window: UsageWindow(percentUsed: cursor.percentUsed, resetsAt: cursor.resetsAt, isActive: true)
                )
            } else {
                Text("Not connected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            Toggle("Floating HUD", isOn: $model.isHudVisible)
                .font(.caption)

            Toggle(
                "Launch at login",
                isOn: Binding(
                    get: { model.isLaunchAtLoginEnabled },
                    set: { _ in model.toggleLaunchAtLogin() }
                )
            )
            .font(.caption)

            Divider()

            HStack {
                Button("Refresh") {
                    model.refresh()
                }
                .buttonStyle(.bordered)

                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(updatedLabel(now: context.date))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(16)
        .frame(width: 320)
    }

    private func updatedLabel(now: Date) -> String {
        guard let lastUpdated = model.lastUpdated else { return "Not yet updated" }
        let seconds = max(0, Int(now.timeIntervalSince(lastUpdated)))
        return "Updated \(seconds)s ago"
    }
}

#Preview {
    MenuContentView(model: UsageModel())
}
