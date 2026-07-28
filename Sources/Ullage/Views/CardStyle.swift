import SwiftUI

/// The bounded card every panel surface is built from.
///
/// This lived as three byte-identical private `card(_:)` helpers in
/// `MenuContentView`, `SettingsView` and `CostView`, which meant any change to
/// the panel's look had to be made three times and kept in sync by hand.
///
/// The half-opacity fill over the menu-bar window's own material is
/// deliberate, not an oversight: it's what makes the panel read as part of the
/// menu bar rather than a floating box, and it's the look the app is designed
/// around. It does mean a saturated desktop picture tints the panel — that's
/// the accepted cost of the translucency, not a bug to scrim away.
///
/// The border is the one thing that changed: `Color.white.opacity(0.1)` is
/// invisible on a light card, so in Light Mode the cards lost their edges
/// entirely. `Color.primary` resolves per appearance and reads in both.
struct CardStyle: ViewModifier {
    var cornerRadius: CGFloat = 16

    func body(content: Content) -> some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color(NSColor.controlBackgroundColor).opacity(0.5))
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
            )
    }
}

extension View {
    func cardStyle(cornerRadius: CGFloat = 16) -> some View {
        modifier(CardStyle(cornerRadius: cornerRadius))
    }
}
