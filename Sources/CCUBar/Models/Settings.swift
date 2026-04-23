import Foundation

enum MenuBarDisplayMode: String, Codable, CaseIterable {
    case numeric    // only "29%"
    case bar        // only the progress bar
    case both       // bar + "29%" (default)
}

struct Settings: Codable, Equatable {
    var refreshIntervalSeconds: Int = 60
    var notificationsEnabled: Bool = true
    var launchAtLogin: Bool = false
    var language: AppLocale = .ko
    var menuBarDisplay: MenuBarDisplayMode = .both
    var showMenuBarIcon: Bool = true

    // Local bridge (ccubar / claude_usage_scraper compatible) HTTP port
    var bridgePort: Int = 0

    var onboardingComplete: Bool = false
    var schemaVersion: Int = 7

    static let allowedIntervals: [Int] = [30, 60, 300]

    enum CodingKeys: String, CodingKey {
        case refreshIntervalSeconds, notificationsEnabled, launchAtLogin,
             language, menuBarDisplay, showMenuBarIcon,
             bridgePort, onboardingComplete, schemaVersion
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.refreshIntervalSeconds = (try? c.decode(Int.self, forKey: .refreshIntervalSeconds)) ?? 60
        self.notificationsEnabled = (try? c.decode(Bool.self, forKey: .notificationsEnabled)) ?? true
        self.launchAtLogin = (try? c.decode(Bool.self, forKey: .launchAtLogin)) ?? false
        self.language = (try? c.decode(AppLocale.self, forKey: .language)) ?? .ko
        self.menuBarDisplay = (try? c.decode(MenuBarDisplayMode.self, forKey: .menuBarDisplay)) ?? .both
        self.showMenuBarIcon = (try? c.decode(Bool.self, forKey: .showMenuBarIcon)) ?? true
        self.bridgePort = (try? c.decode(Int.self, forKey: .bridgePort)) ?? 0
        self.onboardingComplete = (try? c.decode(Bool.self, forKey: .onboardingComplete)) ?? false
        self.schemaVersion = (try? c.decode(Int.self, forKey: .schemaVersion)) ?? 1
    }
}
