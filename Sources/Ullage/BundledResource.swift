import Foundation

/// Finds a file shipped in `Sources/Ullage/Resources` at runtime.
///
/// **Why this exists instead of `Bundle.module`.** SwiftPM synthesizes that
/// accessor with a `fatalError` when the resource bundle can't be located, so
/// an app packaged by hand — `Scripts/package_app.sh` assembles the `.app` with
/// a shell script, not Xcode — would *crash on launch* rather than degrade.
/// Every caller here can survive a miss, so a nil is always better than a trap.
///
/// This was `ModelPricing.bundledURL()`, private and hardcoded to one JSON
/// file. The provider icons need the same search, and the list of candidate
/// locations is the sort of thing that must not exist twice: it encodes how
/// three different build layouts happen to place resources, and a copy would
/// silently rot the moment one of them changed.
enum BundledResource {
    /// Every place a bundled file might plausibly live, across `swift run`,
    /// `swift test`, and a hand-assembled `.app`. Checked in order; the first
    /// one that exists wins.
    static func url(named name: String, extension fileExtension: String) -> URL? {
        var candidates: [URL] = []
        let filename = "\(name).\(fileExtension)"

        for bundle in [Bundle.main] + Bundle.allBundles {
            if let direct = bundle.url(forResource: name, withExtension: fileExtension) {
                candidates.append(direct)
            }
            // SwiftPM emits `Ullage_Ullage.bundle` beside the built executable;
            // a packaged .app copies resources into Contents/Resources. The
            // SwiftPM bundle is flat on a command-line build and wrapped in
            // `Contents/Resources` when it's a real bundle, so try both.
            for root in [bundle.resourceURL, bundle.bundleURL, bundle.bundleURL.deletingLastPathComponent()].compactMap({ $0 }) {
                candidates.append(root.appendingPathComponent(filename))
                let spm = root.appendingPathComponent("Ullage_Ullage.bundle", isDirectory: true)
                candidates.append(spm.appendingPathComponent(filename))
                candidates.append(spm.appendingPathComponent("Contents/Resources/\(filename)"))
            }
        }

        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }
}
