import SwiftUI
import AppKit
import Combine

extension Notification.Name {
    static let settingsWindowShown = Notification.Name("ccubar.settings.windowShown")
}

@MainActor
final class SettingsWindowController {
    static let shared = SettingsWindowController()
    private var window: NSWindow?
    private var cancellables: Set<AnyCancellable> = []

    func show(settingsStore: SettingsStore) {
        if let window {
            updateTitle(for: settingsStore.settings.language)
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            // Ensure any leftover draft state is refreshed to the live settings.
            NotificationCenter.default.post(name: .settingsWindowShown, object: nil)
            return
        }
        let hosting = NSHostingController(rootView: SettingsView(settingsStore: settingsStore))
        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable, .resizable]
        window.setContentSize(NSSize(width: 520, height: 620))
        window.minSize = NSSize(width: 480, height: 520)
        window.isReleasedWhenClosed = false
        self.window = window
        updateTitle(for: settingsStore.settings.language)

        settingsStore.$settings
            .map(\.language)
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] locale in
                self?.updateTitle(for: locale)
            }
            .store(in: &cancellables)

        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func updateTitle(for locale: AppLocale) {
        window?.title = LocalizedStrings(locale: locale).settingsWindowTitle
    }
}

struct SettingsView: View {
    @ObservedObject var settingsStore: SettingsStore
    @State private var portDraft: String = ""
    @State private var bridgeRunning: Bool = false
    private let runningPoll = Timer.publish(every: 2.0, on: .main, in: .common).autoconnect()

    private var strings: LocalizedStrings {
        LocalizedStrings(locale: settingsStore.settings.language)
    }

    var body: some View {
        Form {
            // 1. Data source — the most important setting up top
            Section {
                HStack(spacing: 8) {
                    Text(strings.settingsScraperPortLabel)
                    TextField("", text: $portDraft)
                        .labelsHidden()
                        .frame(maxWidth: 100)
                        .onSubmit { applyPortDraft() }
                    StatusChip(
                        kind: bridgeRunning ? .online : .offline,
                        label: bridgeRunning ? strings.settingsBridgeRunning : strings.settingsBridgeStopped
                    )
                    Spacer()
                    Button(strings.settingsRandomizePort) {
                        portDraft = String(BridgeRunner.pickFreePort())
                    }
                    Button(strings.settingsApplyPort) {
                        applyPortDraft()
                    }
                    .disabled(!isPortDraftDirty)
                    .keyboardShortcut(.defaultAction)
                }
                Text(strings.settingsSourceHelpLocal)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                sectionHeader(strings.settingsSectionSource)
            }

            // 2. Menu bar appearance
            Section {
                Picker(strings.settingsSectionMenuBar, selection: menuBarDisplayBinding) {
                    Text(strings.settingsMenuBarNumeric).tag(MenuBarDisplayMode.numeric)
                    Text(strings.settingsMenuBarBar).tag(MenuBarDisplayMode.bar)
                    Text(strings.settingsMenuBarBoth).tag(MenuBarDisplayMode.both)
                }
                .pickerStyle(.segmented)
                Toggle(strings.settingsMenuBarIcon, isOn: $settingsStore.settings.showMenuBarIcon)
            } header: {
                sectionHeader(strings.settingsSectionMenuBar)
            }

            // 3. Refresh cadence
            Section {
                Picker(strings.settingsRefreshInterval, selection: intervalBinding) {
                    Text(strings.settingsInterval30s).tag(30)
                    Text(strings.settingsInterval60s).tag(60)
                    Text(strings.settingsInterval5m).tag(300)
                }
                .pickerStyle(.segmented)
            } header: {
                sectionHeader(strings.settingsSectionRefresh)
            }

            // 4. Notifications
            Section {
                Toggle(strings.settingsNotificationsToggle,
                       isOn: $settingsStore.settings.notificationsEnabled)
            } header: {
                sectionHeader(strings.settingsSectionNotifications)
            }

            // 5. Startup
            Section {
                Toggle(strings.settingsLaunchAtLogin, isOn: loginAtStartBinding)
            } header: {
                sectionHeader(strings.settingsSectionStartup)
            }

            // 6. Language (least frequently touched — at the bottom)
            Section {
                Picker("", selection: languageBinding) {
                    Text(AppLocale.en.displayName).tag(AppLocale.en)
                    Text(AppLocale.ja.displayName).tag(AppLocale.ja)
                    Text(AppLocale.ko.displayName).tag(AppLocale.ko)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            } header: {
                sectionHeader(strings.settingsSectionLanguage)
            }

            // 7. Support / Report issue
            Section {
                HStack {
                    Button(strings.settingsReportIssue) {
                        IssueReporter.openGitHubIssue()
                    }
                    Spacer()
                }
                Text(strings.settingsReportIssueHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                sectionHeader(strings.settingsSectionSupport)
            }

            // Footer
            Section {
                HStack {
                    Spacer()
                    Text(strings.settingsVersionLabel)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 480, minHeight: 520)
        .onAppear {
            syncPortDraft()
            refreshRunningStatus()
        }
        .onChange(of: settingsStore.settings.bridgePort) { newValue in
            // Underlying port changed (e.g. onboarding or another settings pass) —
            // always pull the draft back into sync so the field reflects reality.
            if newValue > 0 { portDraft = String(newValue) }
            refreshRunningStatus()
        }
        .onReceive(NotificationCenter.default.publisher(for: .settingsWindowShown)) { _ in
            syncPortDraft()
            refreshRunningStatus()
        }
        .onReceive(runningPoll) { _ in
            refreshRunningStatus()
        }
    }

    private func syncPortDraft() {
        portDraft = settingsStore.settings.bridgePort > 0
            ? String(settingsStore.settings.bridgePort)
            : ""
    }

    private func refreshRunningStatus() {
        let port = settingsStore.settings.bridgePort
        bridgeRunning = port > 0 && BridgeRunner.isPortListening(port: port)
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.top, 6)
    }

    // MARK: - Bindings

    private var intervalBinding: Binding<Int> {
        Binding(
            get: { settingsStore.settings.refreshIntervalSeconds },
            set: { settingsStore.settings.refreshIntervalSeconds = $0 }
        )
    }

    private var languageBinding: Binding<AppLocale> {
        Binding(
            get: { settingsStore.settings.language },
            set: { settingsStore.settings.language = $0 }
        )
    }

    private var menuBarDisplayBinding: Binding<MenuBarDisplayMode> {
        Binding(
            get: { settingsStore.settings.menuBarDisplay },
            set: { settingsStore.settings.menuBarDisplay = $0 }
        )
    }

    private var isPortDraftDirty: Bool {
        guard let p = Int(portDraft), (1...65535).contains(p) else { return false }
        return p != settingsStore.settings.bridgePort
    }

    private func applyPortDraft() {
        guard let p = Int(portDraft), (1...65535).contains(p),
              p != settingsStore.settings.bridgePort else { return }
        settingsStore.settings.bridgePort = p
    }

    private var loginAtStartBinding: Binding<Bool> {
        Binding(
            get: { settingsStore.settings.launchAtLogin },
            set: { newValue in
                let result = LoginItemManager.setEnabled(newValue)
                switch result {
                case .success:
                    settingsStore.settings.launchAtLogin = newValue
                case .failure:
                    settingsStore.settings.launchAtLogin = LoginItemManager.isRegistered
                }
            }
        )
    }

    private static let portFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .none
        f.minimum = 0
        f.maximum = 65535
        f.allowsFloats = false
        return f
    }()
}
