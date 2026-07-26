import Foundation
import ServiceManagement

/// Thin wrapper around `SMAppService.mainApp`. Registration only happens
/// when the user flips the toggle in the panel — never automatically.
enum LaunchAtLogin {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func toggle() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            // Registration can fail outside a proper .app bundle (e.g. when
            // running via `swift run`); the toggle just reflects reality
            // next time `isEnabled` is read.
        }
    }
}
