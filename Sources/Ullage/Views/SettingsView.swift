import SwiftUI
import AppKit

/// Replaces the usage cards inside the menu-bar panel. Same card chrome and
/// toggle styling as the main view so the swap feels like one surface, not a
/// second window.
///
/// Three groups, in the order someone actually reaches for them: **General**
/// (how the app behaves), **Menu bar** (what it shows), **Connections** (who
/// it talks to). The Floating HUD toggle deliberately isn't here — it's a
/// thing you flick on and off while working, so it lives in the main popover
/// where it's one click away rather than three.
///
/// Every provider-specific list below iterates `ProviderRegistry`, so adding a
/// platform changes no code in this file.
struct SettingsView: View {
    @ObservedObject var model: UsageModel
    var onBack: () -> Void

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

                    Divider().opacity(0.5)

                    HStack {
                        Text("Refresh every")
                            .font(.caption)
                        Spacer()
                    }

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
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .firstTextBaseline) {
                        sectionLabel("Menu bar")
                        Spacer()
                        // A live counter rather than a silent cap: the limit is
                        // something you can see before you hit it.
                        Text("\(model.badgeSelection.providers.count) of \(ProviderRegistry.maxBadgeProviders)")
                            .font(.caption2)
                            .foregroundStyle(model.badgeSelection.isFull ? .secondary : .tertiary)
                            .monospacedDigit()
                    }

                    Text("Choose which platforms show their percentage up top.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)

                    ForEach(ProviderRegistry.available) { provider in
                        badgeToggleRow(provider)
                    }
                }
            }

            card {
                VStack(alignment: .leading, spacing: 12) {
                    sectionLabel("Connections")

                    ForEach(Array(ProviderRegistry.available.enumerated()), id: \.element.id) { index, provider in
                        if index > 0 { Divider().opacity(0.5) }
                        connectionRow(provider)
                    }

                    if !ProviderRegistry.planned.isEmpty {
                        Divider().opacity(0.5)
                        plannedRow
                    }
                }
            }
        }
    }

    // MARK: - Menu bar

    /// A checkbox-style row per platform. Unselected rows go disabled once the
    /// cap is reached, and the *last* selected row can't be turned off — an
    /// empty badge would be an invisible menu-bar item you then can't click to
    /// fix.
    @ViewBuilder
    private func badgeToggleRow(_ provider: ProviderDescriptor) -> some View {
        let isOn = model.badgeSelection.contains(provider.id)
        let isLastOne = isOn && model.badgeSelection.providers.count == 1
        let blockedByCap = !isOn && model.badgeSelection.isFull
        let disabled = isLastOne || blockedByCap

        Button {
            model.toggleBadgeProvider(provider.id)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 13))
                    .foregroundStyle(isOn ? AnyShapeStyle(provider.brand) : AnyShapeStyle(.tertiary))

                if let icon = provider.icon {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 16, height: 16)
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                }

                Text(provider.displayName)
                    .font(.caption)
                    .foregroundStyle(.primary)

                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled && !isOn ? 0.4 : 1)
        .help(
            isLastOne
                ? "At least one platform has to stay in the menu bar."
                : blockedByCap
                    ? "The menu bar fits \(ProviderRegistry.maxBadgeProviders). Turn one off first."
                    : "Show \(provider.displayName) in the menu bar"
        )
    }

    // MARK: - Connections

    private func connectionRow(_ provider: ProviderDescriptor) -> some View {
        let status = model.connection(for: provider.id)
        return HStack(spacing: 8) {
            if let icon = provider.icon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 22, height: 22)
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(provider.displayName)
                    .font(.subheadline.weight(.medium))
                Text(status.summary)
                    .font(.caption2)
                    .foregroundStyle(status.needsAttention ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
            }
            Spacer()
            // Weight follows meaning: neutral to sign out, the platform's own
            // accent to connect, amber when something needs fixing. Previously
            // every one of these was tinted the brand colour, so "Sign out" and
            // "Reconnect" looked equally inviting.
            SettingsPillButton(
                tint: status.needsAttention ? .orange : (status.isDestructive ? .secondary : provider.brand),
                action: { model.performConnectionAction(for: provider.id) }
            ) {
                Text(status.actionTitle)
                    .font(.caption)
            }
        }
    }

    /// Platforms on the roadmap, listed rather than hidden. A user deciding
    /// whether this app fits gets more from an honest "not yet" than from a
    /// short list that looks complete.
    private var plannedRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "plus.circle")
                    .font(.system(size: 12))
                Text("Add a platform")
                    .font(.caption)
                Spacer()
            }
            .foregroundStyle(.secondary)

            Text(Self.plannedSentence)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    /// "ChatGPT and Gemini are planned" — a list formatter rather than a
    /// `joined(separator:)`, so the sentence stays grammatical as the roadmap
    /// grows or shrinks to one entry.
    static var plannedSentence: String {
        let names = ProviderRegistry.planned.map(\.displayName)
        let list = ListFormatter.localizedString(byJoining: names)
        return names.count == 1 ? "\(list) is planned." : "\(list) are planned."
    }

    private func sectionLabel(_ title: String) -> some View {
        Text(title)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
    }

    @ViewBuilder
    private func card(@ViewBuilder _ content: () -> some View) -> some View {
        content().cardStyle()
    }
}

/// Shared with `CostView` — both are full-panel swaps that need the same way
/// back, and two copies would be two things to keep in visual sync.
struct BackButton: View {
    let action: () -> Void
    @State private var isHovering = false

    /// Padding and background go *inside* the label — see `PillButton` for why
    /// the ordering matters (outside, the capsule is bigger than the clickable
    /// region and roughly half of this button silently ignored clicks).
    var body: some View {
        Button(action: action) {
            Label("Back", systemImage: "chevron.left")
                .font(.caption.weight(.medium))
                .labelStyle(.titleAndIcon)
                .foregroundStyle(isHovering ? .primary : .secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Capsule().fill(Color.secondary.opacity(isHovering ? 0.24 : 0.12)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

private struct SettingsPillButton<Content: View>: View {
    var tint: Color = .secondary
    let action: () -> Void
    @ViewBuilder let label: () -> Content

    @State private var isHovering = false

    /// Same inside-the-label ordering as `PillButton` and `BackButton`, for the
    /// same reason: outside the `Button`, the capsule is decoration that can't
    /// be clicked.
    var body: some View {
        Button(action: action) {
            label()
                .foregroundStyle(tint)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Capsule().fill(tint.opacity(isHovering ? 0.32 : 0.18)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}
