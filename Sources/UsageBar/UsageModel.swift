import Foundation

/// Single source of truth for both the menu-bar panel and the HUD overlay.
/// A 60-second timer drives `refresh()`, which fetches both providers and
/// publishes the result; failures keep the last known values on screen.
@MainActor
final class UsageModel: ObservableObject {
    @Published private(set) var planName: String?
    @Published private(set) var session: UsageWindow
    @Published private(set) var weeklyAllModels: UsageWindow
    @Published private(set) var cursor: CursorUsage?
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var claudeError: UsageError?
    @Published private(set) var isLaunchAtLoginEnabled: Bool
    @Published var isHudVisible: Bool = false

    private let claudeProvider = ClaudeUsageProvider()
    private let cursorProvider = CursorUsageProvider()
    private var timer: Timer?
    private var refreshTask: Task<Void, Never>?

    init() {
        // Demo values so the UI renders before anything is connected; a real
        // fetch overwrites these as soon as refresh() completes.
        let now = Date()
        let demoSessionReset = Calendar.current.date(byAdding: .minute, value: 55, to: now) ?? now
        let demoWeeklyReset = Self.nextFriday(at: 8, from: now)
        self.planName = "Pro"
        self.session = UsageWindow(percentUsed: 15, resetsAt: demoSessionReset, isActive: true)
        self.weeklyAllModels = UsageWindow(percentUsed: 6, resetsAt: demoWeeklyReset, isActive: true)
        self.cursor = nil
        self.isLaunchAtLoginEnabled = LaunchAtLogin.isEnabled

        startTimer()
        refresh()
    }

    deinit {
        timer?.invalidate()
        refreshTask?.cancel()
    }

    private func startTimer() {
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func refresh() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            guard let self else { return }
            async let claudeResult = self.claudeProvider.fetch()
            async let cursorResult = self.cursorProvider.fetch()
            let (claude, cursorUsage) = await (claudeResult, cursorResult)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                switch claude {
                case .success(let usage):
                    self.planName = usage.planName ?? self.planName
                    self.session = usage.session
                    self.weeklyAllModels = usage.weeklyAllModels
                    self.claudeError = nil
                case .failure(let error):
                    // Keep last known Claude values on screen; only surface the error.
                    self.claudeError = error
                }
                self.cursor = cursorUsage
                self.lastUpdated = Date()
            }
        }
    }

    func toggleLaunchAtLogin() {
        LaunchAtLogin.toggle()
        isLaunchAtLoginEnabled = LaunchAtLogin.isEnabled
    }

    /// Compact menu-bar label, e.g. "CC 15% · Cur —".
    var badgeText: String {
        let sessionText = "\(Int(session.percentUsed.rounded()))%"
        let cursorText = cursor.map { "\(Int($0.percentUsed.rounded()))%" } ?? "—"
        return "CC \(sessionText) · Cur \(cursorText)"
    }

    private static func nextFriday(at hour: Int, from date: Date) -> Date {
        let calendar = Calendar.current
        let weekday = calendar.component(.weekday, from: date)
        let friday = 6
        let daysUntilFriday = (friday - weekday + 7) % 7
        let offset = daysUntilFriday == 0 ? 7 : daysUntilFriday
        let candidateDay = calendar.date(byAdding: .day, value: offset, to: date) ?? date
        var components = calendar.dateComponents([.year, .month, .day], from: candidateDay)
        components.hour = hour
        components.minute = 0
        components.second = 0
        return calendar.date(from: components) ?? date
    }
}
