import AppKit

/// Each platform's real app icon, bundled — the app's only icon source.
///
/// Ullage used to read the icon straight off the installed `Claude.app` /
/// `Cursor.app` and treat these files as a fallback. That failed in both
/// directions. A user who runs Claude in a browser and Cursor from the CLI has
/// neither app on disk, and every icon call site is an `if let` that silently
/// renders nothing — so the panel, the HUD, Settings and the menu-bar badge all
/// lost their branding on exactly the machines least likely to have anything
/// else identifying them. (This shipped: v0.1.0 had no bundled copy at all, and
/// on a Mac without both apps it drew no provider icons anywhere.) In the other
/// direction, when the apps *were* present we fed whatever was on disk into
/// `pureStencilMask()`, whose contrast curve is tuned for this exact artwork.
///
/// These files are extracted from the shipping apps at the 256pt size — four
/// times the largest place either is drawn — so they're the real marks, not
/// lookalikes. Reading only these makes the app look identical everywhere.
///
/// See `Scripts/refresh_provider_icons.sh` for how they were extracted and how
/// to update them when either vendor changes their icon.
enum ProviderIcon {
    /// Decoding a PNG is cheap but not free, and `ProviderDescriptor.icon` is a
    /// computed property SwiftUI re-reads on every body pass. Nil is cached too,
    /// so a missing resource doesn't re-walk the bundle search on every frame.
    private static var cache: [ProviderID: NSImage?] = [:]

    static func image(for id: ProviderID) -> NSImage? {
        if let cached = cache[id] { return cached }
        let image = load(id)
        cache[id] = image
        return image
    }

    private static func load(_ id: ProviderID) -> NSImage? {
        guard let name = resourceName(for: id),
              let url = BundledResource.url(named: name, extension: "png")
        else { return nil }
        return NSImage(contentsOf: url)
    }

    /// Only the two implemented platforms ship artwork. ChatGPT and Gemini are
    /// listed in the registry as planned, and are never drawn with an icon
    /// until they're real.
    private static func resourceName(for id: ProviderID) -> String? {
        switch id {
        case .claude: return "claude-icon"
        case .cursor: return "cursor-icon"
        case .chatgpt, .gemini: return nil
        }
    }
}
