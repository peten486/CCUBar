import Foundation

struct UsageMetric: Equatable {
    let percent: Double
    let resetAt: Date?
    let remainingMinutes: Int?
}

struct UsageSnapshot: Equatable {
    /// 5-hour rolling session.
    let session: UsageMetric
    /// 7-day combined window (may be nil for Pro plans).
    let weekly: UsageMetric?
    /// 7-day Sonnet-specific quota (optional).
    let sonnetWeekly: UsageMetric?
    let fetchedAt: Date
    let rawOutput: String

    // Legacy convenience accessors for older call sites / tests.
    var sessionPercent: Double { session.percent }
    var weeklyPercent: Double? { weekly?.percent }
    var sessionResetAt: Date? { session.resetAt }
}
