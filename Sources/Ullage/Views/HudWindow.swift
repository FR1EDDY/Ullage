import AppKit
import SwiftUI

struct HudHoverState {
    var card: Bool
    var closeButton: Bool

    var isInteractive: Bool { card || closeButton }
}

/// Non-activating, always-on-top panel that mirrors the same `UsageModel`
/// as the dropdown — it never fetches on its own.
private final class HudPanel: NSPanel {
    init(model: UsageModel) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 220, height: 100),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        let hostingController = NSHostingController(rootView: HudContentView(model: model))
        hostingController.sizingOptions = .preferredContentSize
        contentViewController = hostingController
        setContentSize(hostingController.view.fittingSize)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovableByWindowBackground = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isReleasedWhenClosed = false
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// A single card holding both apps — same background treatment as one of
/// the dropdown's cards, just as one shared block instead of two.
private struct HudContentView: View {
    @ObservedObject var model: UsageModel
    @State private var isHoveringCard = false
    @State private var isHoveringCloseButton = false

    /// Anthropic's coral/terracotta brand tone.
    private static let claudeBrand = ProviderRegistry.descriptor(.claude)?.brand ?? Color(red: 0.851, green: 0.467, blue: 0.341)
    private static let claudeGradient = LinearGradient(colors: [Color(red: 0.9, green: 0.5, blue: 0.3), Color(red: 0.8, green: 0.35, blue: 0.25)], startPoint: .leading, endPoint: .trailing)
    /// Cursor has no single dominant brand color; a cool blue keeps it
    /// visually distinct from Claude's warm tone.
    private static let cursorBrand = ProviderRegistry.descriptor(.cursor)?.brand ?? Color(red: 0.298, green: 0.545, blue: 0.965)
    private static let cursorGradient = LinearGradient(colors: [Color(red: 0.3, green: 0.7, blue: 1.0), Color(red: 0.1, green: 0.4, blue: 0.9)], startPoint: .leading, endPoint: .trailing)

    private var hoverState: HudHoverState {
        HudHoverState(card: isHoveringCard, closeButton: isHoveringCloseButton)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let session = model.session {
                UsageMeterView(
                    title: "Claude",
                    window: session,
                    compact: true,
                    brandColor: Self.claudeBrand,
                    brandGradient: Self.claudeGradient,
                    icon: ProviderRegistry.descriptor(.claude)?.icon,
                    inactive: !hoverState.isInteractive
                )
            } else {
                HStack(spacing: 10) {
                    if let icon = ProviderRegistry.descriptor(.claude)?.icon {
                        Image(nsImage: icon)
                            .resizable()
                            .frame(width: 28, height: 28)
                            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    }
                    Text("Claude")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Spacer()
                    Text("Loading…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let cursor = model.cursor {
                UsageMeterView(
                    title: "Cursor",
                    window: UsageWindow(percentUsed: cursor.percentUsed, resetsAt: cursor.resetsAt, isActive: true),
                    compact: true,
                    brandColor: Self.cursorBrand,
                    brandGradient: Self.cursorGradient,
                    icon: ProviderRegistry.descriptor(.cursor)?.icon,
                    inactive: !hoverState.isInteractive
                )
            } else {
                HStack(spacing: 10) {
                    if let icon = ProviderRegistry.descriptor(.cursor)?.icon {
                        Image(nsImage: icon)
                            .resizable()
                            .frame(width: 28, height: 28)
                            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    }
                    Text("Cursor")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Spacer()
                    Text("Not connected")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(10)
        .frame(width: 200, alignment: .topLeading)
        .fixedSize(horizontal: false, vertical: true)
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .grayscale(hoverState.isInteractive ? 0.0 : 1.0)
        .opacity(hoverState.isInteractive ? 1.0 : 0.6)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.ultraThinMaterial)
                .opacity(hoverState.isInteractive ? 0.7 : 0.3)
        )
        // `Color.primary` rather than white: the HUD floats over the user's
        // own windows, so in Light Mode a white hairline was invisible against
        // everything it was meant to separate the card from.
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(hoverState.isInteractive ? Color.primary.opacity(0.08) : Color.clear, lineWidth: 0.5)
        )
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.2)) {
                isHoveringCard = hovering
            }
        }
        .overlay(alignment: .topTrailing) {
            Button(action: { model.isHudVisible = false }) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(hoverState.isInteractive ? .secondary : .tertiary)
                    .padding(6)
                    .background(Circle().fill(Color.black.opacity(isHoveringCloseButton ? 0.14 : 0.001)))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .padding(6)
            .opacity(hoverState.isInteractive ? 1 : 0)
            .allowsHitTesting(hoverState.isInteractive)
            .onHover { hovering in
                withAnimation(.easeInOut(duration: 0.2)) {
                    isHoveringCloseButton = hovering
                }
            }
        }
        .shadow(color: Color.black.opacity(hoverState.isInteractive ? 0.3 : 0.0), radius: 10, x: 0, y: 4)
        .padding(15)
    }
}

/// Owns the HUD panel's lifecycle; toggled from `UsageModel.isHudVisible`.
@MainActor
final class HudWindowController {
    private var panel: HudPanel?
    private let model: UsageModel

    init(model: UsageModel) {
        self.model = model
    }

    func setVisible(_ visible: Bool) {
        guard visible else {
            panel?.orderOut(nil)
            return
        }
        if panel == nil {
            let newPanel = HudPanel(model: model)
            if let screenFrame = NSScreen.main?.visibleFrame {
                let origin = NSPoint(
                    x: screenFrame.maxX - newPanel.frame.width - 5,
                    y: screenFrame.maxY - newPanel.frame.height + 5
                )
                newPanel.setFrameOrigin(origin)
            }
            panel = newPanel
        }
        panel?.orderFrontRegardless()
    }
}
