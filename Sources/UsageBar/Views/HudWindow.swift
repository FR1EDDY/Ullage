import AppKit
import SwiftUI

/// Non-activating, always-on-top panel that mirrors the same `UsageModel`
/// as the dropdown — it never fetches on its own.
private final class HudPanel: NSPanel {
    init(model: UsageModel) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 220, height: 110),
            styleMask: [.nonactivatingPanel, .fullSizeContentView, .titled],
            backing: .buffered,
            defer: false
        )
        contentViewController = NSHostingController(rootView: HudContentView(model: model))
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isReleasedWhenClosed = false
        standardWindowButton(.closeButton)?.isHidden = true
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private struct HudContentView: View {
    @ObservedObject var model: UsageModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Claude")
                .font(.caption.bold())
                .foregroundStyle(.primary)
            UsageBarView(title: "Session", window: model.session, compact: true)
            UsageBarView(title: "Weekly", window: model.weeklyAllModels, compact: true)
        }
        .padding(12)
        .frame(width: 220, height: 110, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08))
        )
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
                let origin = NSPoint(x: screenFrame.maxX - 260, y: screenFrame.maxY - 160)
                newPanel.setFrameOrigin(origin)
            }
            panel = newPanel
        }
        panel?.orderFrontRegardless()
    }
}
