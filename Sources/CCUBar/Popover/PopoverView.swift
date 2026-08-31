import SwiftUI
import AppKit

struct PopoverView: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var settingsStore: SettingsStore
    let onQuit: () -> Void
    let onOpenSettings: () -> Void

    @State private var showRawOutput = false
    @State private var tick: Int = 0
    private let tickTimer = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    private var strings: LocalizedStrings {
        LocalizedStrings(locale: settingsStore.settings.language)
    }

    var body: some View {
        ZStack {
            VisualEffectBackground()
            content
                .padding(20)
        }
        .frame(width: 360)
        .preferredColorScheme(.dark)
        .onReceive(tickTimer) { _ in tick &+= 1 }
    }

    // MARK: - Layout

    @ViewBuilder
    private var content: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            featuredSession
            secondaryMetrics
            footer
            if showRawOutput, let raw = currentRawOutput {
                rawOutputView(raw)
            }
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            Text("🤖")
                .font(.title2)
            Text(strings.appTitle)
                .font(.title2.weight(.bold))
                .foregroundStyle(.primary)
            Spacer()
            StatusChip(kind: statusKind, label: statusLabel)
        }
    }

    // MARK: - Featured 5-hour session

    private var featuredSession: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(strings.fiveHourSession)
                .font(.caption)
                .foregroundStyle(.secondary)

            percentHeadline

            ProgressBar(percent: sessionPercent, tier: GaugeRenderer.tier(for: sessionPercent))
                .frame(height: 10)

            metaLine
        }
    }

    private var percentHeadline: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(percentText)
                .font(.system(size: 36, weight: .bold))
                .foregroundStyle(.primary)
            Text(strings.used.trimmingCharacters(in: .whitespaces))
                .font(.title3)
                .foregroundStyle(.secondary)
        }
    }

    private var metaLine: some View {
        HStack(spacing: 6) {
            Text("🕐")
            Text(sessionResetText)
                .foregroundStyle(.primary)
            Spacer()
        }
        .font(.system(size: 12))
    }

    // MARK: - Secondary metrics (7-day + sonnet)

    @ViewBuilder
    private var secondaryMetrics: some View {
        if currentSnapshot?.weekly != nil || currentSnapshot?.sonnetWeekly != nil
            || !(currentSnapshot?.modelWeekly.isEmpty ?? true) {
            VStack(alignment: .leading, spacing: 10) {
                Divider().overlay(Color.white.opacity(0.12))

                if let weekly = currentSnapshot?.weekly {
                    MetricRow(
                        title: strings.weeklyQuotaTitle,
                        metric: weekly,
                        tick: tick,
                        strings: strings
                    )
                }

                ForEach(currentSnapshot?.modelWeekly ?? [], id: \.name) { entry in
                    MetricRow(
                        title: strings.modelWeeklyTitle(entry.name),
                        metric: entry.metric,
                        tick: tick,
                        strings: strings
                    )
                }

                if let sonnet = currentSnapshot?.sonnetWeekly {
                    MetricRow(
                        title: strings.sonnetSevenDayTitle,
                        metric: sonnet,
                        tick: tick,
                        strings: strings
                    )
                }
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            HStack(spacing: 6) {
                Text("🔄")
                Text(autoLabel)
                    .foregroundStyle(.secondary)
            }
            .font(.system(size: 11))
            Spacer()
            Button(action: {
                Task { await store.refreshNow() }
            }) {
                Text(strings.autoRefreshAction)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(accentGreen)
            }
            .buttonStyle(.plain)
            .contextMenu {
                Button(strings.openSettings, action: onOpenSettings)
                Button(strings.showRawToggle) { showRawOutput.toggle() }
                Divider()
                Button(strings.quit, action: onQuit)
            }
        }
        .padding(.top, 2)
    }

    private func rawOutputView(_ raw: String) -> some View {
        DisclosureGroup(strings.rawOutput) {
            ScrollView {
                Text(raw)
                    .font(.system(size: 10, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
            }
            .frame(maxHeight: 150)
            .background(Color.black.opacity(0.3))
            .cornerRadius(6)
        }
        .font(.caption)
    }

    // MARK: - Derived

    private var currentSnapshot: UsageSnapshot? {
        if case .success(let snap) = store.state { return snap }
        return store.lastSuccess
    }

    private var sessionPercent: Double {
        currentSnapshot?.session.percent ?? 0
    }

    private var currentTier: GaugeTier {
        GaugeRenderer.tier(for: sessionPercent)
    }

    private var percentText: String {
        if currentSnapshot != nil {
            return GaugeRenderer.percentLabel(sessionPercent)
        }
        if case .failure = store.state { return "--%" }
        return "…"
    }

    private var statusKind: StatusChip.Kind {
        switch store.state {
        case .idle:
            return currentSnapshot != nil ? .online : .loading
        case .loading:
            return currentSnapshot != nil ? .online : .loading
        case .success:
            return .online
        case .failure:
            return .offline
        }
    }

    private var statusLabel: String {
        switch statusKind {
        case .online: return strings.statusOnline
        case .loading: return strings.statusLoading
        case .offline: return strings.statusOffline
        }
    }

    private var sessionResetText: String {
        _ = tick
        if let snap = currentSnapshot,
           let desc = LocalizedStrings.resetDescription(for: snap.session, strings: strings) {
            return desc
        }
        if case .failure(let err) = store.state {
            return failureReason(err)
        }
        return strings.resetPending
    }

    private var autoLabel: String {
        _ = tick
        guard let snap = currentSnapshot else { return "--" }
        let elapsed = max(0, Int(Date().timeIntervalSince(snap.fetchedAt)))
        return strings.autoAgo(seconds: elapsed)
    }

    private var currentRawOutput: String? {
        currentSnapshot?.rawOutput
    }

    private func failureReason(_ error: FetchError) -> String {
        switch error {
        case .claudeNotFound: return strings.claudeNotFound
        case .timeout: return strings.claudeTimeout
        case .parseFailure: return strings.claudeParseFailed
        case .processFailed: return strings.claudeProcessFailed
        }
    }

    fileprivate var accentGreen: Color {
        Color(red: 0.22, green: 0.82, blue: 0.40)
    }
}

extension LocalizedStrings {
    /// Returns a localized "N 후 리셋" style string for the given metric, or nil if unknown.
    static func resetDescription(for metric: UsageMetric, strings: LocalizedStrings) -> String? {
        if let remaining = metric.remainingMinutes, remaining > 0 {
            return strings.resetSuffix(duration: strings.duration(totalMinutes: remaining))
        }
        if let reset = metric.resetAt {
            let interval = reset.timeIntervalSince(Date())
            guard interval > 0 else { return nil }
            return strings.resetSuffix(duration: strings.duration(totalMinutes: Int(interval / 60)))
        }
        return nil
    }
}

// MARK: - Compact metric row

struct MetricRow: View {
    let title: String
    let metric: UsageMetric
    let tick: Int
    let strings: LocalizedStrings

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(percentLabel)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.primary)
                    .monospacedDigit()
            }
            ProgressBar(percent: metric.percent, tier: GaugeRenderer.tier(for: metric.percent))
                .frame(height: 6)
            if let reset = resetText {
                HStack(spacing: 5) {
                    Text("🕐").font(.system(size: 10))
                    Text(reset)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var percentLabel: String {
        GaugeRenderer.percentLabel(metric.percent)
    }

    private var resetText: String? {
        _ = tick
        return LocalizedStrings.resetDescription(for: metric, strings: strings)
    }
}

// MARK: - Status chip

struct StatusChip: View {
    enum Kind {
        case online, loading, offline
    }

    let kind: Kind
    let label: String

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(dotColor)
                .frame(width: 8, height: 8)
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(textColor)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            Capsule().fill(backgroundColor)
        )
        .overlay(
            Capsule().stroke(borderColor, lineWidth: 1)
        )
    }

    private var dotColor: Color {
        switch kind {
        case .online: return Color(red: 0.22, green: 0.82, blue: 0.40)
        case .loading: return Color(red: 0.55, green: 0.62, blue: 0.72)
        case .offline: return Color(red: 0.98, green: 0.30, blue: 0.30)
        }
    }

    private var textColor: Color {
        switch kind {
        case .online: return Color(red: 0.32, green: 0.92, blue: 0.50)
        case .loading: return Color(red: 0.75, green: 0.80, blue: 0.88)
        case .offline: return Color(red: 1.0, green: 0.45, blue: 0.45)
        }
    }

    private var backgroundColor: Color {
        switch kind {
        case .online: return Color(red: 0.22, green: 0.82, blue: 0.40).opacity(0.15)
        case .loading: return Color.white.opacity(0.08)
        case .offline: return Color(red: 0.98, green: 0.30, blue: 0.30).opacity(0.15)
        }
    }

    private var borderColor: Color {
        switch kind {
        case .online: return Color(red: 0.22, green: 0.82, blue: 0.40).opacity(0.35)
        case .loading: return Color.white.opacity(0.15)
        case .offline: return Color(red: 0.98, green: 0.30, blue: 0.30).opacity(0.35)
        }
    }
}

// MARK: - Progress bar

struct ProgressBar: View {
    let percent: Double
    let tier: GaugeTier

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.1))
                Capsule()
                    .fill(Self.color(for: tier))
                    .frame(width: max(6, geo.size.width * min(1.0, max(0.0, percent / 100.0))))
                    .animation(.easeInOut(duration: 0.3), value: percent)
            }
        }
    }

    static func color(for tier: GaugeTier) -> Color {
        switch tier {
        case .normal: return Color(red: 0.22, green: 0.82, blue: 0.40)
        case .warning: return Color(red: 0.99, green: 0.75, blue: 0.24)
        case .critical: return Color(red: 0.98, green: 0.30, blue: 0.30)
        }
    }
}

// MARK: - Background

struct VisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        view.isEmphasized = true
        view.appearance = NSAppearance(named: .vibrantDark)
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
