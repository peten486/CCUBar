import SwiftUI
import AppKit

@MainActor
final class OnboardingWindowController {
    static let shared = OnboardingWindowController()
    private var window: NSWindow?

    func show(settingsStore: SettingsStore,
              bridgeRunner: BridgeRunner,
              onFinish: @escaping () -> Void) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        var didClose = false
        let close: () -> Void = { [weak self] in
            guard !didClose else { return }
            didClose = true
            self?.window?.close()
            self?.window = nil
            onFinish()
        }

        let view = OnboardingView(
            settingsStore: settingsStore,
            bridgeRunner: bridgeRunner,
            onClose: close
        )
        let hosting = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hosting)
        window.title = "CCU Bar"
        window.styleMask = [.titled, .closable]
        window.setContentSize(NSSize(width: 540, height: 400))
        window.isReleasedWhenClosed = false
        window.center()
        window.level = .floating
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

private enum OnboardingStep: Equatable {
    case language
    case port
    case starting           // spawning bridge + validating it works
    case done               // brief success flash before auto-close
    case failed(String)
}

struct OnboardingView: View {
    @ObservedObject var settingsStore: SettingsStore
    let bridgeRunner: BridgeRunner
    let onClose: () -> Void

    @State private var step: OnboardingStep = .language
    @State private var portText: String
    @State private var progress: Double = 0
    @State private var statusText: String = ""

    init(settingsStore: SettingsStore,
         bridgeRunner: BridgeRunner,
         onClose: @escaping () -> Void) {
        self.settingsStore = settingsStore
        self.bridgeRunner = bridgeRunner
        self.onClose = onClose
        let existing = settingsStore.settings.bridgePort
        let initial = existing > 0 ? existing : BridgeRunner.pickFreePort()
        _portText = State(initialValue: String(initial))
    }

    private var strings: LocalizedStrings {
        LocalizedStrings(locale: settingsStore.settings.language)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            header
            stepIndicator
            Divider()
            stepContent
            Spacer(minLength: 0)
            footer
        }
        .padding(24)
        .frame(width: 540, height: 400)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text("🤖").font(.system(size: 32))
            VStack(alignment: .leading, spacing: 2) {
                Text(strings.onboardingTitle)
                    .font(.title2.bold())
                Text(currentIntro)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var currentIntro: String {
        switch step {
        case .language:                 return strings.onboardingStepLanguageIntro
        case .port:                     return strings.onboardingIntro
        case .starting, .done:          return strings.onboardingStartupCallingAPI
        case .failed:                   return strings.onboardingStartupFailedHint
        }
    }

    private var stepIndicator: some View {
        HStack(spacing: 6) {
            stepDot(filled: true)
            stepDot(filled: step != .language)
            Spacer()
            Text("\(step == .language ? 1 : 2) / 2")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func stepDot(filled: Bool) -> some View {
        Circle()
            .fill(filled ? Color.accentColor : Color.gray.opacity(0.3))
            .frame(width: 8, height: 8)
    }

    @ViewBuilder
    private var stepContent: some View {
        switch step {
        case .language:              languageStep
        case .port:                  portStep
        case .starting:              startingStep
        case .done:                  doneStep
        case .failed(let reason):    failedStep(reason)
        }
    }

    // MARK: Step 1 — Language

    private var languageStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(strings.settingsSectionLanguage)
                .font(.subheadline.weight(.semibold))
            Picker("", selection: languageBinding) {
                Text(AppLocale.en.displayName).tag(AppLocale.en)
                Text(AppLocale.ja.displayName).tag(AppLocale.ja)
                Text(AppLocale.ko.displayName).tag(AppLocale.ko)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
    }

    private var languageBinding: Binding<AppLocale> {
        Binding(
            get: { settingsStore.settings.language },
            set: { settingsStore.settings.language = $0 }
        )
    }

    // MARK: Step 2 — Port

    private var portStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(strings.onboardingBridgeAutoStart)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                Text(strings.settingsScraperPortLabel)
                    .font(.body.weight(.medium))
                TextField("", text: $portText)
                    .frame(maxWidth: 120)
                    .textFieldStyle(.roundedBorder)
                Spacer()
            }
        }
    }

    // MARK: Starting / Done

    private var startingStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            ProgressView(value: progress, total: 1.0)
                .progressViewStyle(.linear)
                .animation(.easeInOut(duration: 0.3), value: progress)

            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(statusText)
                    .font(.body)
                Spacer()
                Text("\(Int(progress * 100))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var doneStep: some View {
        VStack(spacing: 16) {
            Spacer(minLength: 8)
            Text("✅")
                .font(.system(size: 52))
            Text(strings.onboardingCompleteTitle)
                .font(.title2.bold())
            Text(strings.onboardingCompleteBody)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
        }
        .frame(maxWidth: .infinity)
    }

    private func failedStep(_ reason: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("❌").font(.title3)
                Text(strings.onboardingStartupFailedTitle)
                    .font(.body.weight(.semibold))
            }
            Text(reason)
                .font(.caption.monospaced())
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.red.opacity(0.08))
                .cornerRadius(6)
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            Button(strings.onboardingLaterButton) {
                settingsStore.settings.onboardingComplete = true
                onClose()
            }
            .disabled(step == .starting || step == .done)
            .opacity(step == .done ? 0 : 1)
            Spacer()
            switch step {
            case .language:
                Button(strings.onboardingNext) { step = .port }
                    .keyboardShortcut(.defaultAction)
            case .port:
                Button(strings.onboardingBack) { step = .language }
                Button(strings.onboardingPrimaryButton) { savePort() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSavePort)
            case .starting:
                EmptyView()
            case .done:
                Button(strings.onboardingCompleteConfirm) { onClose() }
                    .keyboardShortcut(.defaultAction)
            case .failed:
                Button(strings.onboardingInstallDeps) {
                    Task { await installDepsAndRetry() }
                }
                Button(strings.onboardingRetry) { startSequence() }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private var canSavePort: Bool {
        guard let p = Int(portText), (1...65535).contains(p) else { return false }
        return true
    }

    private func savePort() {
        guard let port = Int(portText) else { return }
        settingsStore.settings.bridgePort = port
        startSequence()
    }

    private func startSequence() {
        progress = 0.05
        statusText = strings.onboardingStartupSpawning
        step = .starting
        Task { await runStartupSequence() }
    }

    private func installDepsAndRetry() async {
        progress = 0.2
        statusText = strings.onboardingInstallingProgress
        step = .starting
        do {
            try await PipInstaller.installRequirements()
            statusText = strings.onboardingInstallSucceeded
            try? await Task.sleep(nanoseconds: 500_000_000)
            startSequence()
        } catch {
            step = .failed("pip install failed: \(error)")
        }
    }

    private func runStartupSequence() async {
        let port = settingsStore.settings.bridgePort
        guard port > 0 else {
            step = .failed("port not set")
            return
        }

        // 1. Spawn the bridge process directly from the onboarding — don't rely
        //    on Combine observers that may have already consumed the emission.
        progress = 0.15
        do {
            try await bridgeRunner.start(port: port)
        } catch {
            step = .failed("BridgeRunner.start failed: \(error)")
            return
        }
        try? await Task.sleep(nanoseconds: 400_000_000)

        // 2. Wait for port to listen (up to 20s — Python imports + Flask boot).
        progress = 0.25
        statusText = strings.onboardingStartupWaitingPort
        let portDeadline = Date().addingTimeInterval(20)
        while Date() < portDeadline {
            if BridgeRunner.isPortListening(port: port) {
                break
            }
            try? await Task.sleep(nanoseconds: 300_000_000)
            progress = min(0.55, progress + 0.01)
        }
        guard BridgeRunner.isPortListening(port: port) else {
            step = .failed("bridge did not open port \(port) within 20s")
            return
        }

        // 3. Exercise /api/usage end to end.
        progress = 0.7
        statusText = strings.onboardingStartupCallingAPI
        let url = URL(string: "http://127.0.0.1:\(port)/api/usage")!
        // First call is slow: cookie extraction + Keychain prompt + Cloudflare handshake.
        let fetcher = HttpUsageFetcher(endpoint: url, timeout: 30)
        do {
            _ = try await fetcher.fetch()
        } catch {
            step = .failed("first /api/usage call failed: \(error)")
            return
        }

        // 4. Done — stay on the success screen until the user confirms.
        progress = 1.0
        step = .done
        settingsStore.settings.onboardingComplete = true
    }
}
