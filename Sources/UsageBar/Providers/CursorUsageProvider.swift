import Foundation

/// Cursor has no official personal usage API, so this provider is a
/// documented stub: it always returns `nil` and the UI shows "Not connected"
/// until someone wires up the internal endpoint below.
///
/// How to actually connect this (do this yourself, on your own account):
///   1. Log into https://cursor.com/settings in a browser.
///   2. Open DevTools → Network, then click into the "Spending" / usage tab
///      in the dashboard so it issues its data request.
///   3. Find the internal endpoint the tab calls (as of this writing it's
///      something under `cursor.com/api/...`; Cursor changes this without
///      notice, so it must be re-discovered rather than hardcoded here).
///   4. Copy the `WorkosCursorSessionToken` cookie value from that request.
///   5. Store it locally with `KeychainStore.save(token, account: "cursor")`
///      (e.g. from a one-off debug menu item or a small setup script) —
///      never hardcode it in source.
///   6. Replace the body of `fetch()` below to call that endpoint with the
///      cookie attached, and decode the response into `CursorUsage`.
///
/// Because Cursor's endpoint is unofficial and undocumented, any failure
/// here (missing token, network error, schema change) must be swallowed and
/// reported as "Not connected" — it must never affect the Claude side of the
/// app.
actor CursorUsageProvider {
    private static let keychainAccount = "cursor"

    func fetch() async -> CursorUsage? {
        guard KeychainStore.load(account: Self.keychainAccount) != nil else {
            return nil
        }
        // No known endpoint is wired up yet — see the header comment above
        // for how to fill this in once you've captured the real request.
        return nil
    }
}
