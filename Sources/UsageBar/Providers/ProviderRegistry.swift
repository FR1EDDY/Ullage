import SwiftUI
import AppKit

/// Stable identity for a platform. The raw value is persisted (menu-bar
/// selection), so **never rename a case** — add a new one instead.
enum ProviderID: String, CaseIterable, Codable, Sendable, Identifiable {
    case claude
    case cursor
    case chatgpt
    case gemini

    var id: String { rawValue }
}

/// Everything the UI needs to draw a platform, in one place.
///
/// This exists so that adding ChatGPT or Gemini is a *listing* change rather
/// than a refactor: the settings list, the menu-bar picker, and the connections
/// rows all iterate `ProviderRegistry.all` instead of hardcoding two providers
/// between them. Before this, "add a provider" meant touching every view that
/// mentioned Claude or Cursor by name.
struct ProviderDescriptor: Identifiable, Sendable {
    let id: ProviderID
    let displayName: String
    /// Name and bundle id used to find the real app icon on disk.
    let appName: String
    let bundleID: String
    let brand: Color
    let gradient: LinearGradient
    /// Whether this platform is actually implemented. Planned entries are
    /// listed and visibly marked rather than hidden — the roadmap is more
    /// useful to a user than a silently short list, and it keeps the registry
    /// honest about what "supported" means.
    let isAvailable: Bool

    var icon: NSImage? {
        AppIcon.icon(forAppNamed: appName, bundleID: bundleID)
    }
}

enum ProviderRegistry {
    /// Adding a platform starts here: one entry, plus its provider file, plus a
    /// case in `UsageModel.connection(for:)` to map its live state. No view
    /// changes.
    static let all: [ProviderDescriptor] = [
        ProviderDescriptor(
            id: .claude,
            displayName: "Claude",
            appName: "Claude",
            bundleID: "com.anthropic.claudefordesktop",
            // Anthropic's coral/terracotta brand tone.
            brand: Color(red: 0.851, green: 0.467, blue: 0.341),
            gradient: LinearGradient(
                colors: [Color(red: 0.9, green: 0.5, blue: 0.3), Color(red: 0.8, green: 0.35, blue: 0.25)],
                startPoint: .leading,
                endPoint: .trailing
            ),
            isAvailable: true
        ),
        ProviderDescriptor(
            id: .cursor,
            displayName: "Cursor",
            appName: "Cursor",
            bundleID: "com.todesktop.230313mzl4w4u92",
            // Cursor has no single dominant brand colour; a cool blue keeps it
            // visually distinct from Claude's warm tone.
            brand: Color(red: 0.298, green: 0.545, blue: 0.965),
            gradient: LinearGradient(
                colors: [Color(red: 0.3, green: 0.7, blue: 1.0), Color(red: 0.1, green: 0.4, blue: 0.9)],
                startPoint: .leading,
                endPoint: .trailing
            ),
            isAvailable: true
        ),
        ProviderDescriptor(
            id: .chatgpt,
            displayName: "ChatGPT",
            appName: "ChatGPT",
            bundleID: "com.openai.chat",
            brand: Color(red: 0.06, green: 0.65, blue: 0.53),
            gradient: LinearGradient(
                colors: [Color(red: 0.12, green: 0.75, blue: 0.62), Color(red: 0.04, green: 0.55, blue: 0.45)],
                startPoint: .leading,
                endPoint: .trailing
            ),
            isAvailable: false
        ),
        ProviderDescriptor(
            id: .gemini,
            displayName: "Gemini",
            appName: "Gemini",
            bundleID: "com.google.gemini",
            brand: Color(red: 0.26, green: 0.52, blue: 0.96),
            gradient: LinearGradient(
                colors: [Color(red: 0.36, green: 0.62, blue: 1.0), Color(red: 0.16, green: 0.42, blue: 0.86)],
                startPoint: .leading,
                endPoint: .trailing
            ),
            isAvailable: false
        )
    ]

    /// Platforms that actually work today — what the menu bar and connections
    /// list offer as real choices.
    static var available: [ProviderDescriptor] { all.filter(\.isAvailable) }

    /// Announced but not yet implemented.
    static var planned: [ProviderDescriptor] { all.filter { !$0.isAvailable } }

    static func descriptor(_ id: ProviderID) -> ProviderDescriptor? {
        all.first { $0.id == id }
    }

    /// The menu bar fits two logos and their percentages before it starts
    /// crowding everything else up there. Enforced in the picker rather than
    /// silently truncated at render time, so the limit is something the user
    /// sees rather than discovers.
    static let maxBadgeProviders = 2
}

/// How a platform's credentials currently stand. Deliberately a closed set:
/// every provider answers the same four questions, which is what lets one row
/// view render all of them.
enum ProviderConnectionStatus: Equatable, Sendable {
    /// Signed in through this app.
    case connected
    /// Working, but on credentials borrowed from somewhere else (a Claude Code
    /// token on disk). Usable, yet worth offering a first-class sign-in.
    case connectedViaFallback(String)
    /// Credentials were rejected. The one state the user must act on.
    case sessionExpired
    case notConnected

    var summary: String {
        switch self {
        case .connected: return "Signed in"
        case .connectedViaFallback(let detail): return detail
        case .sessionExpired: return "Session expired"
        case .notConnected: return "Not connected"
        }
    }

    /// Button wording and weight follow the state, so the three cases can't
    /// drift apart between providers: neutral **Sign out** when nothing is
    /// wrong, accent **Connect** to opt in, amber **Reconnect** when action is
    /// required.
    var actionTitle: String {
        switch self {
        case .connected: return "Sign out"
        case .connectedViaFallback: return "Sign in"
        case .sessionExpired: return "Reconnect"
        case .notConnected: return "Connect"
        }
    }

    var isDestructive: Bool {
        if case .connected = self { return true }
        return false
    }

    var needsAttention: Bool {
        if case .sessionExpired = self { return true }
        return false
    }
}
