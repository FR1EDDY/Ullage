import SwiftUI
import AppKit

/// The dropdown panel shown when the menu-bar badge is clicked. Mirrors the
/// HUD's card-per-app layout — each app is its own bounded card rather than
/// one continuous list — so the two surfaces read as the same design.
struct MenuContentView: View {
    @ObservedObject var model: UsageModel
    @State private var showingSettings = false
    @State private var showingCost = false

    // Branding comes from the registry so a colour lives in exactly one
    // place. The literals remain only as a fallback if a descriptor is ever
    // missing — the UI degrades to a plausible tint rather than nothing.
    private static let claudeBrand = ProviderRegistry.descriptor(.claude)?.brand ?? Color(red: 0.851, green: 0.467, blue: 0.341)
    private static let claudeGradient = ProviderRegistry.descriptor(.claude)?.gradient ?? LinearGradient(colors: [Color(red: 0.9, green: 0.5, blue: 0.3), Color(red: 0.8, green: 0.35, blue: 0.25)], startPoint: .leading, endPoint: .trailing)
    private static let cursorBrand = ProviderRegistry.descriptor(.cursor)?.brand ?? Color(red: 0.298, green: 0.545, blue: 0.965)
    private static let cursorGradient = ProviderRegistry.descriptor(.cursor)?.gradient ?? LinearGradient(colors: [Color(red: 0.3, green: 0.7, blue: 1.0), Color(red: 0.1, green: 0.4, blue: 0.9)], startPoint: .leading, endPoint: .trailing)

    var body: some View {
        VStack(spacing: 10) {
            if showingSettings {
                SettingsView(model: model) {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showingSettings = false
                    }
                }
            } else if showingCost {
                CostView(model: model) {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showingCost = false
                    }
                }
            } else {
                usageContent
            }
        }
        .padding(14)
        .frame(width: 320)
    }

    @ViewBuilder
    private var usageContent: some View {
        card {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    if let icon = ProviderRegistry.descriptor(.claude)?.icon {
                        Image(nsImage: icon)
                            .resizable()
                            .frame(width: 32, height: 32)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    Text("Claude")
                        .font(.headline)
                    if model.claudeError == nil && !model.claudeNeedsReauth {
                        Circle()
                            .fill(Color.green)
                            .frame(width: 6, height: 6)
                            .shadow(color: .green.opacity(0.5), radius: 2)
                    }
                    if let plan = model.planName {
                        Text(plan)
                            .font(.caption)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.secondary.opacity(0.15)))
                    }
                    Spacer()
                    if model.claudeSignedInViaApp {
                        signOutButton { model.disconnectClaude() }
                    } else if model.isClaudeConnected && !model.claudeNeedsReauth {
                        // Connected via a borrowed Claude Code token. Offer an
                        // explicit app sign-in so the app can stand on its own
                        // credentials, independent of Claude Code being installed.
                        signInButton(tint: Self.claudeBrand) { model.connectClaude() }
                    }
                }

                if model.claudeNeedsReauth {
                    // A dead cookie: keep the last numbers visible (if any)
                    // but make the fix a single click.
                    connectRow(title: "Session expired", action: "Reconnect", highlighted: true, brand: Self.claudeBrand) {
                        model.connectClaude()
                    }
                } else if !model.isClaudeConnected {
                    connectRow(title: nil, action: "Connect Claude", highlighted: false, brand: Self.claudeBrand) {
                        model.connectClaude()
                    }
                } else {
                    usageRow(
                        title: "Current session",
                        window: model.session,
                        forecast: model.forecasts.claudeSession.map {
                            ForecastLine(
                                text: $0.label,
                                detail: $0.detail,
                                confidence: $0.confidence,
                                isAlarming: model.forecasts.anomalyFiring
                            )
                        }
                    )
                    usageRow(
                        title: "Weekly · all models",
                        window: model.weeklyAllModels,
                        forecast: model.forecasts.claudeWeekly.map {
                            ForecastLine(text: $0.label, detail: $0.detail, confidence: $0.confidence)
                        }
                    )

                    if let error = model.claudeError {
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                            Text(error.errorDescription ?? "Claude usage unavailable")
                        }
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.orange.opacity(0.15))
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                }
            }
        }

        card {
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
                    if model.cursor != nil && !model.cursorNeedsReauth {
                        Circle()
                            .fill(Color.green)
                            .frame(width: 6, height: 6)
                            .shadow(color: .green.opacity(0.5), radius: 2)
                    }
                    Spacer()
                    if model.isCursorConnected && !model.cursorNeedsReauth {
                        signOutButton { model.disconnectCursor() }
                    }
                }

                if model.cursorNeedsReauth {
                    // A dead cookie: keep the last number visible (if any) but
                    // make the fix a single click.
                    connectRow(title: "Session expired", action: "Reconnect", highlighted: true, brand: Self.cursorBrand) {
                        model.connectCursor()
                    }
                } else if !model.isCursorConnected {
                    connectRow(title: nil, action: "Connect Cursor", highlighted: false, brand: Self.cursorBrand) {
                        model.connectCursor()
                    }
                } else if let cursor = model.cursor {
                    UsageMeterView(
                        // "Total" — matches Cursor's own settings page,
                        // where this is the blended figure across
                        // first-party-model and API usage, not a single
                        // category ("This cycle" read as if it were).
                        title: cursor.cycleLabel ?? "Total usage",
                        window: UsageWindow(percentUsed: cursor.percentUsed, resetsAt: cursor.resetsAt, isActive: true),
                        brandColor: Self.cursorBrand,
                        brandGradient: Self.cursorGradient,
                        forecast: model.forecasts.cursorCycle.map {
                            ForecastLine(text: $0.label, detail: $0.detail, confidence: $0.confidence)
                        }
                    )
                    // The breakdown behind that blended total. A caption
                    // line rather than two more full bars — repeating the
                    // same reset date three times would be pure clutter.
                    Text("\(Int(cursor.firstPartyPercentUsed.rounded()))% first-party models · \(Int(cursor.apiPercentUsed.rounded()))% API")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                } else {
                    Text("Loading…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }

        VStack(alignment: .leading, spacing: 10) {
            Divider()

            // Four controls plus a timestamp don't fit at 320pt with text
            // labels — they were clipping to "Re…" and "Q…". Refresh and Quit
            // are icons with tooltips instead: both are unambiguous glyphs, and
            // the only text either ever needs to show is the cooldown
            // countdown, which is genuinely new information.
            //
            // The per-second clock is scoped to just the countdown and the
            // "Updated" label. It used to wrap this whole row, which rebuilt
            // every button once a second — a rebuild landing between press and
            // release can swallow the click, and these are the buttons the user
            // reaches for most.
            HStack(spacing: 6) {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let cooldown = cooldownRemaining(now: context.date)

                    HStack(spacing: 6) {
                        // Disabled during a cooldown rather than left tappable:
                        // the provider would suppress the request anyway, so an
                        // enabled button would just be a lie that does nothing.
                        PillButton(action: { model.refresh() }) { _ in
                            if let cooldown {
                                Label("\(cooldown)s", systemImage: "arrow.clockwise")
                                    .font(.caption)
                            } else {
                                Image(systemName: "arrow.clockwise")
                            }
                        }
                        .disabled(cooldown != nil)
                        .opacity(cooldown == nil ? 1 : 0.5)
                        .help(cooldown == nil ? "Refresh" : "Waiting out Claude's rate limit")

                        Text(updatedLabel(now: context.date))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .padding(.leading, 2)
                    }
                }

                Spacer(minLength: 4)

                // The HUD is something you flick on and off while working, not
                // something you configure once — so it belongs here rather than
                // three clicks deep in Settings. The filled icon is the entire
                // state readout it needs.
                PillButton(action: { model.isHudVisible.toggle() }) { _ in
                    Image(systemName: model.isHudVisible ? "rectangle.fill.on.rectangle.fill" : "rectangle.on.rectangle")
                }
                .help(model.isHudVisible ? "Hide floating HUD" : "Show floating HUD")

                // Shown only when there's spend to look at, so the button
                // never opens an empty panel.
                if CostView.hasAnySpend(model) {
                    PillButton(action: {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            showingCost = true
                        }
                    }) { _ in
                        Image(systemName: "dollarsign.circle")
                    }
                    .help("Cost")
                }

                PillButton(action: {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showingSettings = true
                    }
                }) { _ in
                    Image(systemName: "gearshape")
                }
                .help("Settings")

                PillButton(action: { NSApplication.shared.terminate(nil) }) { _ in
                    Image(systemName: "power")
                }
                .help("Quit Ullage")
            }
        }
        .padding(.horizontal, 4)
    }

    @ViewBuilder
    private func usageRow(title: String, window: UsageWindow?, forecast: ForecastLine? = nil) -> some View {
        if let window {
            UsageMeterView(
                title: title,
                window: window,
                brandColor: Self.claudeBrand,
                brandGradient: Self.claudeGradient,
                forecast: forecast
            )
        } else {
            HStack {
                Text(title)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                Spacer()
                Text("Loading…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// A call-to-action row used when a provider isn't usable yet — never
    /// connected, or the session expired. One tap opens that provider's in-app
    /// sign-in. Shared by both Claude and Cursor so the two read identically.
    @ViewBuilder
    private func connectRow(
        title: String?,
        action: String,
        highlighted: Bool,
        brand: Color,
        onTap: @escaping () -> Void
    ) -> some View {
        HStack {
            if let title {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(highlighted ? .orange : .secondary)
            }
            Spacer()
            PillButton(tint: brand, baseOpacity: 0.18, hoverOpacity: 0.32, horizontalPadding: 10, verticalPadding: 5, action: onTap) { _ in
                Label(action, systemImage: "person.crop.circle.badge.plus")
                    .font(.caption)
            }
        }
    }

    /// A small "Sign out" affordance for a card header. Plain text with no
    /// background reads as an inert label rather than a button; the faint
    /// hover-darkening capsule makes it unambiguously clickable without
    /// competing visually with the primary actions below it.
    private func signOutButton(action: @escaping () -> Void) -> some View {
        PillButton(baseOpacity: 0.12, hoverOpacity: 0.24, horizontalPadding: 8, verticalPadding: 3, action: action) { isHovering in
            Text("Sign out")
                .font(.caption2)
                .foregroundStyle(isHovering ? .primary : .secondary)
        }
    }

    /// Offered when a provider is already usable via a fallback (a borrowed
    /// Claude Code token) so the app can stand on its own credentials instead.
    private func signInButton(tint: Color, action: @escaping () -> Void) -> some View {
        PillButton(tint: tint, baseOpacity: 0.12, hoverOpacity: 0.24, horizontalPadding: 8, verticalPadding: 3, action: action) { _ in
            Text("Sign in")
                .font(.caption2)
                .foregroundStyle(tint)
        }
    }

    @ViewBuilder
    private func card(@ViewBuilder _ content: () -> some View) -> some View {
        content()
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

    /// Seconds until the provider will accept another request, or `nil` if it
    /// will accept one now.
    private func cooldownRemaining(now: Date) -> Int? {
        guard let retryAt = model.claudeRetryAt else { return nil }
        let seconds = Int(retryAt.timeIntervalSince(now).rounded(.up))
        return seconds > 0 ? seconds : nil
    }

    /// A reading restored from disk at launch can be hours old, so this has to
    /// stay readable well past the seconds range it used to assume.
    private func updatedLabel(now: Date) -> String {
        guard let lastUpdated = model.lastUpdated else { return "Not yet updated" }
        let seconds = max(0, Int(now.timeIntervalSince(lastUpdated)))
        switch seconds {
        case ..<60:
            return "Updated \(seconds)s ago"
        case ..<3600:
            return "Updated \(seconds / 60)m ago"
        case ..<86_400:
            return "Updated \(seconds / 3600)h ago"
        default:
            return "Updated \(seconds / 86_400)d ago"
        }
    }
}

/// A capsule button with a hover-darkening background — the affordance this
/// app uses for every clickable pill instead of a pointing-hand cursor. macOS
/// doesn't switch the cursor for buttons (that's a web/iOS convention); native
/// controls signal clickability entirely through a hover highlight, so every
/// pill-shaped button in the menu goes through this one view for a consistent,
/// genuinely native feel.
private struct PillButton<Content: View>: View {
    var tint: Color = .secondary
    var baseOpacity: Double = 0.1
    var hoverOpacity: Double = 0.2
    var horizontalPadding: CGFloat = 8
    var verticalPadding: CGFloat = 4
    let action: () -> Void
    @ViewBuilder let label: (_ isHovering: Bool) -> Content

    @State private var isHovering = false

    /// The padding, background and `contentShape` all live **inside** the
    /// button's label. That ordering is load-bearing, not stylistic: applied
    /// outside the `Button` they wrap it instead of growing it, so the capsule
    /// you can see ends up larger than the region that accepts a click — about
    /// two thirds of an icon-only pill was dead space that hover-highlighted
    /// like a button and then ignored you. `contentShape` finishes the job by
    /// making the whole capsule hit-testable including its translucent parts.
    var body: some View {
        Button(action: action) {
            label(isHovering)
                .padding(.horizontal, horizontalPadding)
                .padding(.vertical, verticalPadding)
                .background(Capsule().fill(tint.opacity(isHovering ? hoverOpacity : baseOpacity)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

#Preview {
    MenuContentView(model: UsageModel())
}
