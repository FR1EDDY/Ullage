import SwiftUI
import AppKit

/// Replaces the usage cards inside the menu-bar panel. Same card chrome and
/// toggle styling as the main view so the swap feels like one surface, not a
/// second window.
struct SettingsView: View {
    @ObservedObject var model: UsageModel
    var onBack: () -> Void

    private static let claudeBrand = Color(red: 0.851, green: 0.467, blue: 0.341)
    private static let cursorBrand = Color(red: 0.298, green: 0.545, blue: 0.965)

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                BackButton(action: onBack)

                Spacer()

                Text("Settings")
                    .font(.headline)

                Spacer()

                // Balances the Back pill so the title stays centered.
                Color.clear
                    .frame(width: 64, height: 1)
            }
            .padding(.horizontal, 2)

            card {
                VStack(alignment: .leading, spacing: 12) {
                    sectionLabel("General")

                    Toggle("Floating HUD", isOn: $model.isHudVisible)
                        .font(.caption)
                        .toggleStyle(.switch)
                        .controlSize(.mini)

                    Toggle(
                        "Launch at login",
                        isOn: Binding(
                            get: { model.isLaunchAtLoginEnabled },
                            set: { _ in model.toggleLaunchAtLogin() }
                        )
                    )
                    .font(.caption)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                }
            }

            card {
                VStack(alignment: .leading, spacing: 10) {
                    sectionLabel("Menu bar")

                    Picker(
                        "Badge",
                        selection: Binding(
                            get: { model.badgeDisplayMode },
                            set: { model.setBadgeDisplayMode($0) }
                        )
                    ) {
                        ForEach(BadgeDisplayMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .controlSize(.small)
                    .frame(maxWidth: .infinity)
                }
            }

            card {
                VStack(alignment: .leading, spacing: 10) {
                    sectionLabel("Refresh")

                    Picker(
                        "Interval",
                        selection: Binding(
                            get: { model.refreshIntervalOption },
                            set: { model.setRefreshIntervalOption($0) }
                        )
                    ) {
                        ForEach(RefreshIntervalOption.allCases) { option in
                            Text(option.title).tag(option)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .controlSize(.small)
                    .frame(maxWidth: .infinity)

                    Text("Claude rate limits still slow polling when needed.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            card {
                VStack(alignment: .leading, spacing: 12) {
                    sectionLabel("Accounts")

                    accountRow(
                        name: "Claude",
                        status: claudeStatus,
                        statusColor: model.claudeNeedsReauth ? .orange : .secondary,
                        brand: Self.claudeBrand,
                        actionTitle: claudeActionTitle,
                        action: performClaudeAction
                    )

                    Divider().opacity(0.5)

                    accountRow(
                        name: "Cursor",
                        status: cursorStatus,
                        statusColor: model.cursorNeedsReauth ? .orange : .secondary,
                        brand: Self.cursorBrand,
                        actionTitle: cursorActionTitle,
                        action: performCursorAction
                    )
                }
            }
        }
    }

    private var claudeStatus: String {
        if model.claudeNeedsReauth { return "Session expired" }
        if model.claudeSignedInViaApp { return "Signed in" }
        if model.isClaudeConnected { return "Via Claude Code" }
        return "Not connected"
    }

    private var claudeActionTitle: String {
        if model.claudeNeedsReauth { return "Reconnect" }
        if model.claudeSignedInViaApp { return "Sign out" }
        if model.isClaudeConnected { return "Sign in" }
        return "Connect"
    }

    private func performClaudeAction() {
        if model.claudeSignedInViaApp && !model.claudeNeedsReauth {
            model.disconnectClaude()
        } else {
            model.connectClaude()
        }
    }

    private var cursorStatus: String {
        if model.cursorNeedsReauth { return "Session expired" }
        if model.isCursorConnected { return "Signed in" }
        return "Not connected"
    }

    private var cursorActionTitle: String {
        if model.cursorNeedsReauth { return "Reconnect" }
        if model.isCursorConnected { return "Sign out" }
        return "Connect"
    }

    private func performCursorAction() {
        if model.isCursorConnected && !model.cursorNeedsReauth {
            model.disconnectCursor()
        } else {
            model.connectCursor()
        }
    }

    private func sectionLabel(_ title: String) -> some View {
        Text(title)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
    }

    private func accountRow(
        name: String,
        status: String,
        statusColor: Color,
        brand: Color,
        actionTitle: String,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.subheadline.weight(.medium))
                Text(status)
                    .font(.caption2)
                    .foregroundStyle(statusColor)
            }
            Spacer()
            SettingsPillButton(tint: brand, action: action) {
                Text(actionTitle)
                    .font(.caption)
            }
        }
    }

    @ViewBuilder
    private func card(@ViewBuilder _ content: () -> some View) -> some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color(NSColor.controlBackgroundColor).opacity(0.5))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.1), lineWidth: 1)
            )
    }
}

private struct BackButton: View {
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Label("Back", systemImage: "chevron.left")
                .font(.caption.weight(.medium))
                .labelStyle(.titleAndIcon)
                .foregroundStyle(isHovering ? .primary : .secondary)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(Color.secondary.opacity(isHovering ? 0.24 : 0.12)))
        .onHover { isHovering = $0 }
    }
}

private struct SettingsPillButton<Content: View>: View {
    var tint: Color = .secondary
    let action: () -> Void
    @ViewBuilder let label: () -> Content

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            label()
                .foregroundStyle(tint)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Capsule().fill(tint.opacity(isHovering ? 0.32 : 0.18)))
        .onHover { isHovering = $0 }
    }
}
