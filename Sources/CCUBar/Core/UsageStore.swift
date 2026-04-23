import Foundation
import Combine

@MainActor
final class UsageStore: ObservableObject {
    @Published private(set) var state: FetchState = .idle
    @Published private(set) var lastSuccess: UsageSnapshot?

    private let fetcher: UsageFetching
    private let notifier: NotificationDispatching
    private let settingsProvider: () -> Settings

    private var timer: Timer?
    private var retryTimer: Timer?
    private var consecutiveFailures: Int = 0
    private var notifiedThresholds: Set<Int> = []
    private var currentTask: Task<Void, Never>?

    // Short retry backoff when a fetch fails (e.g. right after login before the
    // bridge binds). Much faster than waiting for the full refresh interval.
    private static let retryBackoffsSeconds: [TimeInterval] = [2, 5, 10, 20]

    init(fetcher: UsageFetching,
         notifier: NotificationDispatching,
         settingsProvider: @escaping () -> Settings) {
        self.fetcher = fetcher
        self.notifier = notifier
        self.settingsProvider = settingsProvider
    }

    func start() {
        restartTimer()
        Task { await refreshNow() }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        retryTimer?.invalidate()
        retryTimer = nil
        currentTask?.cancel()
    }

    func updateInterval(_ seconds: Int) {
        restartTimer(forcedInterval: seconds)
    }

    func refreshNow() async {
        currentTask?.cancel()
        let task = Task { [weak self] in
            guard let self else { return }
            await self.performFetch()
        }
        currentTask = task
        await task.value
    }

    private func restartTimer(forcedInterval: Int? = nil) {
        timer?.invalidate()
        let interval = TimeInterval(forcedInterval ?? settingsProvider().refreshIntervalSeconds)
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { await self?.refreshNow() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func performFetch() async {
        state = .loading
        let settings = settingsProvider()
        do {
            let snap = try await fetcher.fetch()
            handleSnapshot(snap, settings: settings)
            consecutiveFailures = 0
            retryTimer?.invalidate()
            retryTimer = nil
        } catch let error as FetchError {
            state = .failure(error)
            scheduleRetry()
        } catch {
            state = .failure(.parseFailure(String(describing: error)))
            scheduleRetry()
        }
    }

    /// After a failed fetch, queue a retry on a short backoff curve instead of
    /// waiting for the full refresh interval. Resets once a fetch succeeds.
    private func scheduleRetry() {
        retryTimer?.invalidate()
        let idx = min(consecutiveFailures, Self.retryBackoffsSeconds.count - 1)
        let delay = Self.retryBackoffsSeconds[idx]
        consecutiveFailures += 1
        let t = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            Task { await self?.refreshNow() }
        }
        RunLoop.main.add(t, forMode: .common)
        retryTimer = t
    }

    private func handleSnapshot(_ snap: UsageSnapshot, settings: Settings) {
        let previousSnap = lastSuccess
        if didSessionReset(from: previousSnap, to: snap) {
            notifiedThresholds.removeAll()
        }

        if settings.notificationsEnabled {
            let crossed = ThresholdDetector.newlyCrossed(
                previous: previousSnap?.sessionPercent,
                current: snap.sessionPercent,
                alreadyNotified: notifiedThresholds
            )
            let strings = LocalizedStrings(locale: settings.language)
            for threshold in crossed {
                notifiedThresholds.insert(threshold)
                let resetLabel = LocalizedStrings.resetDescription(for: snap.session, strings: strings)
                notifier.dispatch(
                    title: strings.notificationTitle(threshold: threshold),
                    body: strings.notificationBody(
                        currentLabel: GaugeRenderer.percentLabel(snap.sessionPercent),
                        resetLabel: resetLabel
                    )
                )
            }
        }

        state = .success(snap)
        lastSuccess = snap
    }

    private func didSessionReset(from previous: UsageSnapshot?, to current: UsageSnapshot) -> Bool {
        guard let previous else { return false }
        if previous.sessionResetAt != current.sessionResetAt { return true }
        if previous.sessionPercent - current.sessionPercent > 20 { return true }
        return false
    }

}
