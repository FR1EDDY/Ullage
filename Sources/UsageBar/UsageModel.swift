import Foundation
import AppKit

/// Single source of truth for both the menu-bar panel and the HUD overlay.
/// A self-rescheduling timer drives `refresh()`, which fetches both
/// providers and publishes the result; failures keep the last known values
/// on screen.
///
/// Claude's usage endpoint is account-wide and shared with every other
/// client the user is signed into (Claude Code, claude.ai), and its budget
/// is small, so the cadence here is deliberately slow and backs off further
/// under rate limiting, easing back down only gradually. `ClaudeUsageProvider`
/// enforces its own floor on top of this, so no refresh path — including the
/// Refresh button — can outrun it.
@MainActor
final class UsageModel: ObservableObject {
    @Published private(set) var planName: String?
    /// Whether the app can get Claude numbers at all — via in-app sign-in or a
    /// Claude Code token. When false the Claude card shows "Connect Claude".
    @Published private(set) var isClaudeConnected: Bool
    /// True only when the user signed in through this app, so the card can offer
    /// a "Sign out" that has something to clear.
    @Published private(set) var claudeSignedInViaApp: Bool
    /// The stored claude.ai session cookie was rejected (expired/revoked). The
    /// UI turns this into a "Reconnect" prompt, mirroring `cursorNeedsReauth`.
    @Published private(set) var claudeNeedsReauth: Bool = false
    @Published private(set) var session: UsageWindow?
    @Published private(set) var weeklyAllModels: UsageWindow?
    @Published private(set) var cursor: CursorUsage?
    /// Whether a Cursor session credential exists at all. Drives the choice
    /// between a "Connect Cursor" call-to-action and the usual usage display.
    @Published private(set) var isCursorConnected: Bool
    /// The stored Cursor cookie was rejected (expired/revoked). The UI turns this
    /// into a "Reconnect" prompt — the one Cursor failure the user must act on.
    @Published private(set) var cursorNeedsReauth: Bool = false
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var claudeError: UsageError?
    /// When the provider will next permit a network call, or `nil` if one is
    /// permitted right now. Drives the Refresh button's countdown so it can't
    /// offer an action that would be silently swallowed by the cooldown.
    @Published private(set) var claudeRetryAt: Date?
    @Published private(set) var isLaunchAtLoginEnabled: Bool
    @Published var isHudVisible: Bool = false
    /// Which providers appear in the menu-bar badge.
    @Published private(set) var badgeDisplayMode: BadgeDisplayMode
    /// Preferred polling cadence. Rate-limit backoff still widens above this.
    @Published private(set) var refreshIntervalOption: RefreshIntervalOption

    private static let badgeDisplayModeKey = "badgeDisplayMode"
    private static let refreshIntervalKey = "refreshIntervalMinutes"
    private static let maxRefreshInterval: TimeInterval = 1800

    /// How long a retained Cursor reading stays worth showing once fetches stop
    /// succeeding. Cursor's window is the monthly billing cycle, so a reading a
    /// few hours old is still accurate to a fraction of a percent — well within
    /// the point where keeping it beats flashing "Not connected" at every blip.
    /// Past this we admit we've lost the connection.
    private static let cursorMaxServableAge: TimeInterval = 6 * 60 * 60


    private let claudeProvider = ClaudeUsageProvider()
    private let cursorProvider = CursorUsageProvider()
    private var timer: Timer?
    private var refreshTask: Task<Void, Never>?
    private var currentRefreshInterval: TimeInterval
    private var wakeObserver: NSObjectProtocol?
    private var sleepObserver: NSObjectProtocol?
    /// Held so the in-app sign-in window isn't deallocated mid-login.
    private var loginController: LoginWebWindowController?

    private var baseRefreshInterval: TimeInterval { refreshIntervalOption.timeInterval }

    init() {
        let storedBadge = UserDefaults.standard.string(forKey: Self.badgeDisplayModeKey)
            .flatMap(BadgeDisplayMode.init(rawValue:)) ?? .both
        let storedMinutes = UserDefaults.standard.object(forKey: Self.refreshIntervalKey) as? Int
        let storedInterval = storedMinutes.flatMap(RefreshIntervalOption.init(rawValue:)) ?? .five
        self.badgeDisplayMode = storedBadge
        self.refreshIntervalOption = storedInterval
        self.currentRefreshInterval = storedInterval.timeInterval

        // Seed from the last persisted reading. These are real numbers with a
        // real timestamp — the footer dates them, and the first fetch replaces
        // them within a second on the happy path. Inventing placeholder numbers
        // would be indistinguishable from actual usage, but showing nothing at
        // all leaves the meters stuck on "Loading…" for as long as the endpoint
        // stays unavailable, which is precisely when the last known reading is
        // the most useful thing we have.
        let lastReading = ClaudeUsageCache.loadReading()
        self.planName = lastReading?.planName
        self.isClaudeConnected = ClaudeUsageProvider.hasAnyCredentials() || lastReading != nil
        self.claudeSignedInViaApp = ClaudeUsageProvider.hasStoredLogin()
        self.session = lastReading?.session
        self.weeklyAllModels = lastReading?.weeklyAllModels
        self.lastUpdated = lastReading?.observedAt
        // Seed Cursor from its last persisted reading too, for the same reason:
        // a cold start shows the last real number, dated, rather than "Not
        // connected" until the first poll of this launch lands.
        self.cursor = CursorUsageCache.loadReading()
        self.isCursorConnected = KeychainStore.load(account: CursorUsageProvider.keychainAccount) != nil
        self.isLaunchAtLoginEnabled = LaunchAtLogin.isEnabled

        registerSleepWakeObservers()
        refresh()
    }

    deinit {
        timer?.invalidate()
        refreshTask?.cancel()
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        if let sleepObserver { NSWorkspace.shared.notificationCenter.removeObserver(sleepObserver) }
    }

    /// A refresh `Timer` is suspended by the OS while the machine sleeps and
    /// fires late (and coalesced) on wake, so without this the panel would show
    /// hours-old numbers until the next lazy tick happened to come around.
    ///
    /// On wake we force an immediate refresh; the provider's own request floor
    /// and persisted cooldown absorb any burst (a lid opened repeatedly, several
    /// displays reconnecting) so this can't hammer the endpoint. On sleep we
    /// cancel any in-flight fetch, which would otherwise hang across the sleep
    /// and resolve into a stale, misleading "network error" on wake.
    private func registerSleepWakeObservers() {
        let center = NSWorkspace.shared.notificationCenter
        wakeObserver = center.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        sleepObserver = center.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.timer?.invalidate()
                self?.refreshTask?.cancel()
            }
        }
    }

    /// The regular cadence is jittered so we don't march in lockstep with the
    /// other clients polling this same account-wide endpoint (Claude Code,
    /// claude.ai) and collide with them on every tick. A wake-up timed to the
    /// end of a cooldown is not jittered — jitter could land it *before* the
    /// cooldown expires, which just burns a wake-up that the provider would
    /// suppress anyway.
    private func scheduleNextRefresh(after delay: TimeInterval, jittered: Bool = true) {
        timer?.invalidate()
        let interval = jittered ? delay * Double.random(in: 0.85...1.15) : delay
        let timer = Timer(timeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func refresh() {
        timer?.invalidate()
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            guard let self else { return }
            let attemptStartedAt = Date()
            async let claudeResult = self.claudeProvider.fetch()
            async let cursorResult = self.cursorProvider.fetch()
            let (claude, cursor) = await (claudeResult, cursorResult)
            let retryAvailableAt = await self.claudeProvider.retryAvailableAt()
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self.apply(
                    claude: claude,
                    cursor: cursor,
                    attemptStartedAt: attemptStartedAt,
                    retryAvailableAt: retryAvailableAt
                )
            }
        }
    }

    /// Folds one refresh's results into the published state and decides when to
    /// come back. The last known Claude values stay on screen through every
    /// failure — they're minutes old at worst on windows measured in hours.
    private func apply(
        claude: Result<ClaudeUsage, UsageError>,
        cursor: CursorFetchResult,
        attemptStartedAt: Date,
        retryAvailableAt: Date?
    ) {
        claudeRetryAt = retryAvailableAt
        var nextDelay = currentRefreshInterval
        var jittered = true

        switch claude {
        case .success(let usage):
            planName = usage.planName ?? planName
            session = usage.session
            weeklyAllModels = usage.weeklyAllModels
            claudeError = nil
            claudeNeedsReauth = false
            // Date the reading from when it came off the wire rather than now —
            // it may have been served from the provider's cache. This is the
            // only staleness cue the UI has, since rate limits stay silent.
            lastUpdated = usage.observedAt
            // Only a reading we actually just fetched is evidence the endpoint
            // is happy again, so only that may walk the interval back down. A
            // cached serve proves nothing. Ease back rather than snapping to
            // full speed, which is what used to make this oscillate: recover,
            // immediately re-trip the limit, back off, repeat.
            if usage.observedAt >= attemptStartedAt {
                currentRefreshInterval = max(baseRefreshInterval, currentRefreshInterval / 2)
            }
            nextDelay = currentRefreshInterval


        case .failure(.rateLimited(let retryAfter)):
            // A 429 that genuinely came off the wire: we are in fact asking too
            // often, so widen the interval.
            let backedOff = min(currentRefreshInterval * 2, Self.maxRefreshInterval)
            currentRefreshInterval = max(retryAfter ?? 0, backedOff)
            // A rate limit says nothing about the user's usage and needs no
            // action from them — surfacing it as an error is just noise next to
            // numbers that are still good. Only admit to it if we've never had
            // a reading at all.
            claudeError = session == nil ? .rateLimited(retryAfter: retryAfter) : nil
            nextDelay = currentRefreshInterval

        case .failure(.coolingDown(let retryAfter)):
            // We never made a request — our own floor suppressed it, and the
            // server said nothing. Widening the interval here is self-inflicted:
            // it used to double on every suppressed call (and on every press of
            // Refresh), walking the next *real* attempt out to half an hour
            // while the endpoint was answering fine. Leave the cadence alone and
            // simply come back when the floor lifts.
            claudeError = session == nil ? .coolingDown(retryAfter: retryAfter) : nil
            nextDelay = max(retryAfter, 1) + 2
            jittered = false

        case .failure(.sessionExpired):
            // The cookie is dead. Keep the last reading on screen — it's not
            // wrong, just aging — and raise the flag so the UI offers
            // Reconnect instead of a generic error banner.
            claudeNeedsReauth = true
            nextDelay = currentRefreshInterval

        case .failure(let error):
            // Same reasoning as rate limits: an error that says nothing about
            // the user's usage and needs no action from them is just noise
            // stacked on top of numbers that are still good. A transient 401 is
            // the common case — Claude's OAuth access token expired and Claude
            // Code will mint a fresh one in the background, so the very next
            // poll reads it from disk and succeeds. `missingCredentials` is the
            // exception: it's genuinely actionable ("sign in to Claude Code"),
            // so it always shows. Everything else surfaces only when we have no
            // reading to fall back on.
            let actionable = error == .missingCredentials
            claudeError = (actionable || session == nil) ? error : nil
            if Self.isServerError(error) {
                currentRefreshInterval = min(currentRefreshInterval * 2, Self.maxRefreshInterval)
            }
            nextDelay = currentRefreshInterval
        }

        switch cursor {
        case .success(let usage):
            self.cursor = usage
            CursorUsageCache.saveReading(usage)
            isCursorConnected = true
            cursorNeedsReauth = false
        case .unauthorized:
            // The cookie is dead. Keep the last number on screen so the panel
            // isn't blank, but raise the flag so the UI can offer Reconnect —
            // this is the case the old "everything is Not connected" design
            // could never recover from without the hand-run script.
            cursorNeedsReauth = true
        case .unavailable:
            // Transient, or simply not connected. Retain the last good reading
            // through blips; only give it up once it's too old to trust.
            if let existing = self.cursor,
               Date().timeIntervalSince(existing.observedAt) > Self.cursorMaxServableAge {
                self.cursor = nil
            }
        }

        // Recompute Claude connection state each cycle: a reading (or any live
        // credential) means connected; a refresh token the server killed will
        // have been cleared by the provider, flipping this back to false so the
        // card offers "Connect Claude" again instead of a dead error.
        isClaudeConnected = session != nil || ClaudeUsageProvider.hasAnyCredentials()
        claudeSignedInViaApp = ClaudeUsageProvider.hasStoredLogin()

        scheduleNextRefresh(after: nextDelay, jittered: jittered)
    }


    private static func isServerError(_ error: UsageError) -> Bool {
        if case .httpStatus(let code) = error {
            return (500...599).contains(code)
        }
        return false
    }

    func toggleLaunchAtLogin() {
        LaunchAtLogin.toggle()
        isLaunchAtLoginEnabled = LaunchAtLogin.isEnabled
    }

    func setBadgeDisplayMode(_ mode: BadgeDisplayMode) {
        badgeDisplayMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: Self.badgeDisplayModeKey)
    }

    func setRefreshIntervalOption(_ option: RefreshIntervalOption) {
        refreshIntervalOption = option
        UserDefaults.standard.set(option.rawValue, forKey: Self.refreshIntervalKey)
        currentRefreshInterval = option.timeInterval
        scheduleNextRefresh(after: option.timeInterval)
    }

    /// Opens the in-app Cursor sign-in window. On success the session cookie is
    /// lifted into the Keychain and we refresh immediately, so the meter fills
    /// in within a second of the window closing — no restart, no script.
    func connectCursor() {
        let controller = LoginWebWindowController(
            title: "Sign in to Cursor",
            startURL: URL(string: "https://cursor.com/login")!,
            captureCookie: { cookies in
                guard let cookie = cookies.first(where: { $0.name == "WorkosCursorSessionToken" }),
                      !cookie.value.isEmpty else { return nil }
                return cookie.value
            },
            onCapture: { [weak self] token in
                guard let self else { return }
                KeychainStore.save(token, account: CursorUsageProvider.keychainAccount)
                self.isCursorConnected = true
                self.cursorNeedsReauth = false
                self.refresh()
            },
            onDismiss: { [weak self] in self?.loginController = nil }
        )
        self.loginController = controller
        controller.show()
    }

    /// Forgets the Cursor session entirely — clears the Keychain item and any
    /// cached reading so the panel returns to a clean "Connect Cursor" state.
    func disconnectCursor() {
        KeychainStore.delete(account: CursorUsageProvider.keychainAccount)
        CursorUsageCache.clear()
        cursor = nil
        isCursorConnected = false
        cursorNeedsReauth = false
    }

    /// Opens the in-app Claude sign-in window. On success the claude.ai session
    /// cookie is lifted into the Keychain and we refresh immediately — the same
    /// mechanism as `connectCursor()`. (An OAuth "connect an app" flow was tried
    /// first and abandoned: claude.ai's authorize endpoint requires bot-attestation
    /// fields — `arkose_session_token`, `client_attestation` — that only
    /// Anthropic's own signed clients can produce, confirmed live 2026-07-15.
    /// The cookie path works because it's an ordinary authenticated page load,
    /// not a third-party grant, so none of that machinery applies.)
    func connectClaude() {
        let controller = LoginWebWindowController(
            title: "Sign in to Claude",
            startURL: URL(string: "https://claude.ai/login")!,
            captureCookie: { cookies in
                guard let cookie = cookies.first(where: { $0.name == "sessionKey" }),
                      !cookie.value.isEmpty else { return nil }
                return cookie.value
            },
            onCapture: { [weak self] sessionKey in
                guard let self else { return }
                ClaudeCookieStore.saveSessionKey(sessionKey)
                self.isClaudeConnected = true
                self.claudeSignedInViaApp = true
                self.claudeNeedsReauth = false
                self.claudeError = nil
                self.refresh()
            },
            onDismiss: { [weak self] in self?.loginController = nil }
        )
        self.loginController = controller
        controller.show()
    }

    /// Signs out of the in-app Claude login. If a Claude Code token still exists
    /// the app keeps working through that fallback — this only forgets the login
    /// the user performed here.
    func disconnectClaude() {
        ClaudeCookieStore.clearSessionKey()
        claudeSignedInViaApp = false
        claudeNeedsReauth = false
        isClaudeConnected = ClaudeUsageProvider.hasAnyCredentials()
        if !isClaudeConnected {
            session = nil
            weeklyAllModels = nil
            planName = nil
        }
    }
}
