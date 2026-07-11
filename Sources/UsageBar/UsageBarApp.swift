import SwiftUI
import AppKit
import Combine

@main
struct UsageBarApp: App {
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

/// Small wrapper view so the menu-bar label re-renders when the model's
/// published usage values change (the App struct itself doesn't observe them).
private struct BadgeLabel: View {
    @ObservedObject var model: UsageModel

    var body: some View {
        Text(model.badgeText)
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
