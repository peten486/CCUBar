import AppKit
import Combine
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var settingsStore: SettingsStore!
    private var usageStore: UsageStore!
    private var menuBarController: MenuBarController!
    private var notifier: Notifier!
    private let bridgeRunner = BridgeRunner()
    private var cancellables: Set<AnyCancellable> = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Single-instance guard: if another CCU Bar is already running, surface it
        // and terminate this process so notification clicks / Launch Services /
        // multiple bundle paths can't spawn a second copy.
        if Self.activateExistingInstanceIfRunning() {
            NSApp.terminate(nil)
            return
        }

        NSApp.setActivationPolicy(.accessory)

        let settingsStore = SettingsStore()
        self.settingsStore = settingsStore

        let notifier = Notifier()
        self.notifier = notifier

        let fetcher = BridgeFetcher(settingsProvider: { settingsStore.settings })
        let usageStore = UsageStore(
            fetcher: fetcher,
            notifier: notifier,
            settingsProvider: { settingsStore.settings }
        )
        self.usageStore = usageStore

        let controller = MenuBarController(store: usageStore, settingsStore: settingsStore)
        self.menuBarController = controller

        // Show onboarding if we don't have a working port yet.
        if !settingsStore.settings.onboardingComplete || settingsStore.settings.bridgePort <= 0 {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                OnboardingWindowController.shared.show(
                    settingsStore: settingsStore,
                    bridgeRunner: self.bridgeRunner,
                    onFinish: { [weak self] in
                        Task { await self?.usageStore?.refreshNow() }
                    }
                )
            }
        } else {
            bootstrapBridgeAndFetch()
        }

        // propagate refresh interval changes
        settingsStore.$settings
            .map(\.refreshIntervalSeconds)
            .removeDuplicates()
            .dropFirst()
            .sink { [weak usageStore] seconds in
                usageStore?.updateInterval(seconds)
            }
            .store(in: &cancellables)

        // restart bridge + refresh when the port changes
        settingsStore.$settings
            .map(\.bridgePort)
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in
                self?.bootstrapBridgeAndFetch()
            }
            .store(in: &cancellables)

        Task { await notifier.requestAuthorization() }

        usageStore.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        usageStore?.stop()
        bridgeRunner.stop()
    }

    /// Returns `true` if another instance of the same bundle is already running and
    /// we've asked it to come to the front. The caller should then terminate.
    private static func activateExistingInstanceIfRunning() -> Bool {
        guard let bundleId = Bundle.main.bundleIdentifier else { return false }
        let myPid = ProcessInfo.processInfo.processIdentifier
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId)
            .filter { $0.processIdentifier != myPid }
        guard let existing = others.first else { return false }
        existing.activate(options: [.activateIgnoringOtherApps])
        return true
    }

    // MARK: - Bridge process lifecycle

    /// Starts (or restarts) the bridge Python service to match the current Settings.
    /// Subprocess work runs on a detached task so this never blocks the main thread.
    private func syncBridge() {
        let port = settingsStore.settings.bridgePort
        Task { [weak self] in
            guard let self else { return }
            guard port > 0 else {
                await self.bridgeRunner.stopAsync()
                return
            }
            do {
                try await self.bridgeRunner.start(port: port)
            } catch {
                NSLog("[CCUBar] bridge start failed: \(error)")
            }
        }
    }

    /// Spin up the bridge and wait for the port to start listening before kicking
    /// off the first usage fetch. Fixes the login-time race where the first fetch
    /// fires against a bridge that isn't ready yet and the user then has to hit
    /// Refresh manually.
    private func bootstrapBridgeAndFetch() {
        let port = settingsStore.settings.bridgePort
        Task { [weak self] in
            guard let self else { return }
            guard port > 0 else {
                await self.bridgeRunner.stopAsync()
                return
            }
            do {
                try await self.bridgeRunner.start(port: port)
            } catch {
                NSLog("[CCUBar] bridge start failed: \(error)")
                // Even on failure still try a fetch — timer + retry will handle recovery.
                await self.usageStore?.refreshNow()
                return
            }

            // Wait up to 30s for the bridge to bind its port. Poll every 250ms.
            let deadline = Date().addingTimeInterval(30.0)
            while Date() < deadline {
                if BridgeRunner.isPortListening(port: port) { break }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
            await self.usageStore?.refreshNow()
        }
    }
}
