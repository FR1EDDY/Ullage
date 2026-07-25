import AppKit

/// Looks up the real icon of an installed app (e.g. Claude, Cursor) so the
/// HUD can show authentic branding without embedding any logo assets.
enum AppIcon {
    private static var cache: [String: NSImage] = [:]

    static func icon(forAppNamed name: String, bundleID: String) -> NSImage? {
        if let cached = cache[bundleID] {
            return cached
        }
        let path = "/Applications/\(name).app"
        let resolvedPath: String?
        if FileManager.default.fileExists(atPath: path) {
            resolvedPath = path
        } else {
            resolvedPath = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)?.path
        }
        guard let resolvedPath else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: resolvedPath)
        cache[bundleID] = icon
        return icon
    }
}
