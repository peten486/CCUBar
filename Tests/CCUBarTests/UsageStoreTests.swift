import XCTest
@testable import CCUBar

@MainActor
final class UsageStoreTests: XCTestCase {
    func testThresholdNotifiedOnceAndResetOnSessionReset() async {
        let fetcher = ScriptedFetcher()
        let notifier = RecordingNotifier()
        let settings = Settings()
        let store = UsageStore(
            fetcher: fetcher,
            notifier: notifier,
            settingsProvider: { settings }
        )

        let resetA = Date().addingTimeInterval(3600)
        let resetB = Date().addingTimeInterval(5 * 3600)

        fetcher.queue = [
            snap(70, resetAt: resetA),
            snap(76, resetAt: resetA),
            snap(77, resetAt: resetA),
            snap(30, resetAt: resetB),
            snap(80, resetAt: resetB)
        ]

        for _ in 0..<5 {
            await store.refreshNow()
        }

        XCTAssertEqual(notifier.dispatched.count, 2)
        XCTAssertTrue(notifier.dispatched.allSatisfy { $0.title.contains("75%") })
    }

    func testFailureDoesNotCrash() async {
        let fetcher = ScriptedFetcher(throwing: true)
        let notifier = RecordingNotifier()
        let settings = Settings()
        let store = UsageStore(
            fetcher: fetcher,
            notifier: notifier,
            settingsProvider: { settings }
        )
        await store.refreshNow()
        if case .failure = store.state {
            // OK
        } else {
            XCTFail("expected failure state, got \(store.state)")
        }
    }

    private func snap(_ percent: Double, resetAt: Date? = nil) -> UsageSnapshot {
        UsageSnapshot(
            session: UsageMetric(percent: percent, resetAt: resetAt, remainingMinutes: nil),
            weekly: nil,
            sonnetWeekly: nil,
            fetchedAt: Date(),
            rawOutput: ""
        )
    }
}

// MARK: - Test doubles

private final class ScriptedFetcher: UsageFetching, @unchecked Sendable {
    var queue: [UsageSnapshot] = []
    let throwing: Bool

    init(throwing: Bool = false) {
        self.throwing = throwing
    }

    func fetch() async throws -> UsageSnapshot {
        if throwing { throw FetchError.claudeNotFound }
        guard !queue.isEmpty else { throw FetchError.timeout }
        return queue.removeFirst()
    }
}

private final class RecordingNotifier: NotificationDispatching, @unchecked Sendable {
    var dispatched: [(title: String, body: String)] = []
    func requestAuthorization() async {}
    func dispatch(title: String, body: String) {
        dispatched.append((title, body))
    }
}
