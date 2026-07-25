import XCTest
@testable import UsageBar

final class ProviderRegistryTests: XCTestCase {
    // MARK: - Registry

    /// The registry is the single list every provider-facing view iterates. If
    /// it can't answer for an id, some view somewhere renders a blank row.
    func testEveryProviderIDHasADescriptor() {
        for id in ProviderID.allCases {
            XCTAssertNotNil(ProviderRegistry.descriptor(id), "no descriptor for \(id.rawValue)")
        }
        XCTAssertEqual(ProviderRegistry.all.count, ProviderID.allCases.count)
    }

    func testAvailableAndPlannedPartitionTheRegistry() {
        let available = Set(ProviderRegistry.available.map(\.id))
        let planned = Set(ProviderRegistry.planned.map(\.id))
        XCTAssertTrue(available.isDisjoint(with: planned))
        XCTAssertEqual(available.union(planned), Set(ProviderID.allCases))
        // The two that actually work today.
        XCTAssertEqual(available, [.claude, .cursor])
    }

    /// Raw values are persisted in the menu-bar selection, so renaming a case
    /// would silently reset everyone's settings.
    func testProviderRawValuesAreStable() {
        XCTAssertEqual(ProviderID.claude.rawValue, "claude")
        XCTAssertEqual(ProviderID.cursor.rawValue, "cursor")
        XCTAssertEqual(ProviderID.chatgpt.rawValue, "chatgpt")
        XCTAssertEqual(ProviderID.gemini.rawValue, "gemini")
    }

    // MARK: - Badge selection (the "max 2" acceptance criterion)

    func testSelectionIsCappedAtTheRegistryLimit() {
        let selection = BadgeSelection([.claude, .cursor, .chatgpt, .gemini])
        XCTAssertEqual(selection.providers.count, ProviderRegistry.maxBadgeProviders)
        XCTAssertEqual(selection.providers, [.claude, .cursor])
        XCTAssertTrue(selection.isFull)
    }

    func testSelectionDeduplicatesAndKeepsOrder() {
        let selection = BadgeSelection([.cursor, .cursor, .claude])
        XCTAssertEqual(selection.providers, [.cursor, .claude], "order is visible in the badge")
    }

    /// Adding a third is refused by the value itself, not just by a disabled
    /// button — so no code path can push the badge past what fits.
    func testTogglingBeyondTheCapIsRefused() {
        let full = BadgeSelection([.claude, .cursor])
        XCTAssertEqual(full.toggling(.chatgpt), full, "a third provider must not be added")
    }

    /// An empty badge would be an invisible menu-bar item the user then can't
    /// click to fix.
    func testTheLastProviderCannotBeRemoved() {
        let single = BadgeSelection([.claude])
        XCTAssertEqual(single.toggling(.claude), single)
        XCTAssertEqual(single.providers, [.claude])
    }

    func testTogglingAddsAndRemovesWithinTheCap() {
        var selection = BadgeSelection([.claude])
        selection = selection.toggling(.cursor)
        XCTAssertEqual(selection.providers, [.claude, .cursor])
        selection = selection.toggling(.claude)
        XCTAssertEqual(selection.providers, [.cursor])
        selection = selection.toggling(.chatgpt)
        XCTAssertEqual(selection.providers, [.cursor, .chatgpt])
    }

    // MARK: - Persistence and migration

    func testSelectionRoundTripsThroughStorage() {
        let original = BadgeSelection([.cursor, .claude])
        let restored = BadgeSelection.fromStorage(original.storageValue)
        XCTAssertEqual(restored, original)
        XCTAssertEqual(original.storageValue, "cursor,claude")
    }

    func testStorageIgnoresGarbageAndEmptyValues() {
        XCTAssertNil(BadgeSelection.fromStorage(nil))
        XCTAssertNil(BadgeSelection.fromStorage(""))
        XCTAssertNil(BadgeSelection.fromStorage("nonsense,alsonotreal"))
        // A partly-readable list keeps what it can rather than resetting.
        XCTAssertEqual(BadgeSelection.fromStorage("claude,bogus")?.providers, [.claude])
    }

    /// Existing installs stored a three-way enum. Migration has to preserve the
    /// choice, or everyone's menu bar silently changes on update.
    func testLegacyBadgeModeMigratesToTheEquivalentSelection() {
        XCTAssertEqual(BadgeDisplayMode.both.providers, [.claude, .cursor])
        XCTAssertEqual(BadgeDisplayMode.claude.providers, [.claude])
        XCTAssertEqual(BadgeDisplayMode.cursor.providers, [.cursor])

        XCTAssertEqual(BadgeSelection(BadgeDisplayMode.cursor.providers).providers, [.cursor])
    }

    // MARK: - Connection status

    /// Button wording and weight are derived from the state so the three cases
    /// can't drift apart between providers.
    func testActionTitlesAndWeightsFollowTheState() {
        XCTAssertEqual(ProviderConnectionStatus.notConnected.actionTitle, "Connect")
        XCTAssertEqual(ProviderConnectionStatus.connected.actionTitle, "Sign out")
        XCTAssertEqual(ProviderConnectionStatus.sessionExpired.actionTitle, "Reconnect")
        XCTAssertEqual(ProviderConnectionStatus.connectedViaFallback("Via Claude Code").actionTitle, "Sign in")

        // Neutral to sign out, amber only when something needs fixing.
        XCTAssertTrue(ProviderConnectionStatus.connected.isDestructive)
        XCTAssertFalse(ProviderConnectionStatus.notConnected.isDestructive)
        XCTAssertTrue(ProviderConnectionStatus.sessionExpired.needsAttention)
        XCTAssertFalse(ProviderConnectionStatus.connected.needsAttention)
        XCTAssertFalse(ProviderConnectionStatus.notConnected.needsAttention)
    }

    func testFallbackStatusCarriesItsOwnWording() {
        let status = ProviderConnectionStatus.connectedViaFallback("Via Claude Code")
        XCTAssertEqual(status.summary, "Via Claude Code")
        // Borrowed credentials work, so this is not an attention state — but it
        // isn't "signed in" either, and the button offers an upgrade.
        XCTAssertFalse(status.needsAttention)
        XCTAssertFalse(status.isDestructive)
    }

    /// The roadmap sentence has to stay grammatical whether there are two
    /// planned platforms or one.
    func testPlannedSentenceReadsAsASentence() {
        let sentence = SettingsView.plannedSentence
        XCTAssertTrue(sentence.hasSuffix("planned."), sentence)
        for provider in ProviderRegistry.planned {
            XCTAssertTrue(sentence.contains(provider.displayName), sentence)
        }
        // Two planned today, so the plural verb.
        XCTAssertTrue(sentence.contains(" are planned."), sentence)
        XCTAssertFalse(sentence.contains(", Gemini are"), "expected a conjunction, got a bare list: \(sentence)")
    }

    /// Planned platforms are declared, but not wired to anything — the
    /// registry must say so, or the Connections list would offer a Connect
    /// button that does nothing.
    ///
    /// Deliberately asserted against the registry rather than a live
    /// `UsageModel`: constructing one starts a refresh that reads the Keychain,
    /// and a freshly-compiled test binary isn't on that item's ACL, so macOS
    /// raises a modal prompt no headless run will ever answer. A unit test that
    /// can block forever on a GUI dialog is not a unit test.
    func testPlannedProvidersAreMarkedUnavailable() {
        XCTAssertFalse(ProviderRegistry.planned.isEmpty, "the roadmap row needs something to list")
        for provider in ProviderRegistry.planned {
            XCTAssertFalse(provider.isAvailable, provider.displayName)
            XCTAssertFalse(ProviderRegistry.available.contains { $0.id == provider.id })
        }
    }
}
