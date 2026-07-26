import SwiftUI
import AppKit
import Combine
import CoreImage.CIFilterBuiltins

@main
struct UllageApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuContentView(model: appDelegate.model)
        } label: {
            BadgeLabel(model: appDelegate.model)
        }
        .menuBarExtraStyle(.window)
    }
}

extension NSImage {
    /// Flattens a full-colour app icon into a monochrome stencil so it reads as
    /// a clean menu-bar glyph (adapting to light/dark) instead of a tiny colour
    /// tile. Saturation to zero, contrast pushed hard so the artwork collapses
    /// to black on a black field, then mask-to-alpha lifts the silhouette out.
    func pureStencilMask() -> NSImage {
        guard let cgImage = self.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return self }
        let ciImage = CIImage(cgImage: cgImage)

        let colorControls = CIFilter.colorControls()
        colorControls.inputImage = ciImage
        colorControls.saturation = 0.0
        colorControls.contrast = 3.0    // Push midtones (coral/blue) to black
        colorControls.brightness = -0.5 // Darken so the background falls to pure black

        let maskToAlpha = CIFilter.maskToAlpha()
        maskToAlpha.inputImage = colorControls.outputImage

        let context = CIContext(options: nil)
        guard let output = maskToAlpha.outputImage,
              let resultCGImage = context.createCGImage(output, from: output.extent) else { return self }

        return NSImage(cgImage: resultCGImage, size: self.size)
    }
}

/// The menu-bar label: the real Claude / Cursor marks (as monochrome stencils)
/// paired with each provider's percentage, honouring `badgeDisplayMode`.
///
/// `MenuBarExtra` bridges an Image+Text label straight to the status-bar
/// button's native `image`/`title`, which supports only *one* icon and one
/// title run — a second `Image` is silently dropped and inline icons in a
/// single `Text` render blank. So the whole row is composed in SwiftUI, drawn
/// into one `NSImage` via `ImageRenderer`, and flagged `isTemplate` so the
/// system tints it to match the menu bar. Kept as an `@ObservedObject` view so
/// it re-renders when the model's published usage changes.
private struct BadgeLabel: View {
    @ObservedObject var model: UsageModel

    /// Stencils are expensive to build and never change, so they're cut once
    /// per provider and cached. Driven off the registry rather than named
    /// constants, so a new platform needs no change here.
    private static let stencils: [ProviderID: NSImage] = {
        var result: [ProviderID: NSImage] = [:]
        for descriptor in ProviderRegistry.available {
            if let stencil = descriptor.icon?.pureStencilMask() {
                result[descriptor.id] = stencil
            }
        }
        return result
    }()

    /// The percentage each provider contributes to the badge. This is the one
    /// place a new platform has to say what its headline number is.
    private func badgeText(for id: ProviderID) -> String {
        switch id {
        case .claude:
            return model.session.map { "\(Int($0.percentUsed.rounded()))%" } ?? "…"
        case .cursor:
            return model.cursor.map { "\(Int($0.percentUsed.rounded()))%" } ?? "—"
        case .chatgpt, .gemini:
            return "—"
        }
    }

    @MainActor
    private var renderedImage: NSImage? {
        let selected = model.badgeSelection.providers
        let content = HStack(spacing: 6) {
            ForEach(Array(selected.enumerated()), id: \.element) { index, id in
                if index > 0 {
                    Text("|")
                        .font(.system(size: 14, weight: .light))
                        .foregroundColor(.black.opacity(0.4))
                        .padding(.horizontal, 2)
                }
                HStack(spacing: 2) {
                    if let icon = Self.stencils[id] {
                        Image(nsImage: icon)
                            .resizable()
                            .renderingMode(.template)
                            .foregroundColor(.black)
                            .frame(width: 26, height: 26)
                            .padding(.horizontal, -4)
                    }
                    Text(badgeText(for: id))
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.black)
                }
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)

        let renderer = ImageRenderer(content: content)
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2.0
        guard let cgImage = renderer.cgImage else { return nil }

        let nsImage = NSImage(
            cgImage: cgImage,
            size: NSSize(
                width: CGFloat(cgImage.width) / renderer.scale,
                height: CGFloat(cgImage.height) / renderer.scale
            )
        )
        nsImage.isTemplate = true
        return nsImage
    }

    var body: some View {
        if let img = renderedImage {
            Image(nsImage: img)
        } else {
            // Fallback if rendering ever fails: plain text so the label is
            // never blank. Same providers, same order as the composed badge.
            Text(model.badgeSelection.providers.map(badgeText(for:)).joined(separator: " | "))
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = UsageModel()
    private lazy var hudController = HudWindowController(model: model)
    private var cancellable: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu-bar only: no Dock icon, no app-switcher entry.
        NSApp.setActivationPolicy(.accessory)

        cancellable = model.$isHudVisible
            .sink { [weak self] visible in
                self?.hudController.setVisible(visible)
            }
    }
}
