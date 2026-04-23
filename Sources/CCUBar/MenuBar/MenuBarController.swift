import AppKit
import Combine
import SwiftUI

@MainActor
final class MenuBarController {
    private let statusItem: NSStatusItem
    private let popover: NSPopover
    private let store: UsageStore
    private let settingsStore: SettingsStore
    private let progressView: StatusItemProgressView
    private var cancellables: Set<AnyCancellable> = []

    init(store: UsageStore, settingsStore: SettingsStore) {
        self.store = store
        self.settingsStore = settingsStore
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.progressView = StatusItemProgressView(frame: .zero)

        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 360, height: 360)
        popover.animates = true
        popover.appearance = NSAppearance(named: .darkAqua)
        self.popover = popover

        configureButton()
        configurePopover()
        subscribe()
        progressView.displayMode = settingsStore.settings.menuBarDisplay
        progressView.showIcon = settingsStore.settings.showMenuBarIcon
        applyState(store.state)
    }

    private var strings: LocalizedStrings {
        LocalizedStrings(locale: settingsStore.settings.language)
    }

    private func configureButton() {
        guard let button = statusItem.button else { return }
        button.target = self
        button.action = #selector(statusItemClicked(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.title = ""
        button.imagePosition = .imageOnly
        button.toolTip = strings.menuBarTooltipTitle

        progressView.translatesAutoresizingMaskIntoConstraints = false
        button.addSubview(progressView)
        NSLayoutConstraint.activate([
            progressView.centerYAnchor.constraint(equalTo: button.centerYAnchor),
            progressView.leadingAnchor.constraint(equalTo: button.leadingAnchor),
            progressView.heightAnchor.constraint(equalToConstant: NSStatusBar.system.thickness)
        ])
        syncStatusItemWidth()
    }

    private func syncStatusItemWidth() {
        let width = progressView.intrinsicContentSize.width
        // Round up and set length so the menu bar slot shrinks/grows with content.
        statusItem.length = max(20, ceil(width))
    }

    private func configurePopover() {
        let rootView = PopoverView(store: store, settingsStore: settingsStore, onQuit: { [weak self] in
            self?.quit()
        }, onOpenSettings: { [weak self] in
            self?.openSettings()
        })
        popover.contentViewController = NSHostingController(rootView: rootView)
    }

    private func subscribe() {
        store.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                self?.applyState(state)
            }
            .store(in: &cancellables)

        settingsStore.$settings
            .map(\.menuBarDisplay)
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] mode in
                self?.progressView.displayMode = mode
                self?.syncStatusItemWidth()
            }
            .store(in: &cancellables)

        settingsStore.$settings
            .map(\.showMenuBarIcon)
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] show in
                self?.progressView.showIcon = show
                self?.syncStatusItemWidth()
            }
            .store(in: &cancellables)
    }

    // MARK: - Actions

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { togglePopover(); return }
        if event.type == .rightMouseUp || event.modifierFlags.contains(.control) {
            showContextMenu()
        } else {
            togglePopover()
        }
    }

    private func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
        } else if let button = statusItem.button {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    private func showContextMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: strings.manualRefresh, action: #selector(refreshNow), keyEquivalent: "r").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "\(strings.openSettings)…", action: #selector(openSettingsMenuAction), keyEquivalent: ",").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: strings.quit, action: #selector(quitMenuAction), keyEquivalent: "q").target = self
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func refreshNow() {
        Task { await store.refreshNow() }
    }

    @objc private func openSettingsMenuAction() { openSettings() }
    @objc private func quitMenuAction() { quit() }

    private func openSettings() {
        SettingsWindowController.shared.show(settingsStore: settingsStore)
    }

    private func quit() {
        NSApplication.shared.terminate(nil)
    }

    // MARK: - State rendering

    private func applyState(_ state: FetchState) {
        switch state {
        case .idle, .loading:
            if case .success(let snap) = state {
                renderSuccess(snap)
            } else if let last = store.lastSuccess {
                renderSuccess(last)
            } else {
                progressView.update(mode: .loading)
                statusItem.button?.toolTip = "Loading…"
            }

        case .success(let snap):
            renderSuccess(snap)

        case .failure(let error):
            progressView.update(mode: .error(short: shortLabel(for: error)))
            statusItem.button?.toolTip = tooltip(for: error)
        }
        syncStatusItemWidth()
    }

    private func renderSuccess(_ snap: UsageSnapshot) {
        let tier = GaugeRenderer.tier(for: snap.session.percent)
        progressView.update(mode: .progress(percent: snap.session.percent, tier: tier))
        statusItem.button?.toolTip = detailTooltip(for: snap)
    }

    private func shortLabel(for error: FetchError) -> String {
        switch error {
        case .claudeNotFound: return "Setup"
        case .timeout: return "…"
        case .parseFailure: return "Parse"
        case .processFailed: return "Err"
        }
    }

    private func tooltip(for error: FetchError) -> String {
        switch error {
        case .claudeNotFound: return strings.claudeNotFound
        case .timeout: return strings.claudeTimeout
        case .parseFailure: return strings.claudeParseFailed
        case .processFailed: return strings.claudeProcessFailed
        }
    }

    private func detailTooltip(for snap: UsageSnapshot) -> String {
        let s = strings
        var lines = [s.tooltipSession(GaugeRenderer.percentLabel(snap.session.percent))]
        if let weekly = snap.weekly {
            lines.append(s.tooltipWeekly(GaugeRenderer.percentLabel(weekly.percent)))
        }
        if let sonnet = snap.sonnetWeekly {
            lines.append(s.tooltipSonnet(GaugeRenderer.percentLabel(sonnet.percent)))
        }
        return lines.joined(separator: " · ")
    }
}
