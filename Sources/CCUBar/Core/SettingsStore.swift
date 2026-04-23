import Foundation
import Combine

@MainActor
final class SettingsStore: ObservableObject {
    @Published var settings: Settings {
        didSet { save() }
    }

    private let defaults: UserDefaults
    private let key: String

    init(defaults: UserDefaults = .standard, key: String = "ccubar.settings.v1") {
        self.defaults = defaults
        self.key = key
        // Prefer new key; fall back to legacy "ccbar.settings.v1" on first launch after rename.
        if let data = defaults.data(forKey: key) ?? defaults.data(forKey: "ccbar.settings.v1"),
           let decoded = try? JSONDecoder().decode(Settings.self, from: data) {
            self.settings = decoded
        } else {
            self.settings = Settings()
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(settings) {
            defaults.set(data, forKey: key)
        }
    }
}
