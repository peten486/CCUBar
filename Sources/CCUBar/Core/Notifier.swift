import AppKit
import Foundation
import UserNotifications

protocol NotificationDispatching: AnyObject {
    func requestAuthorization() async
    func dispatch(title: String, body: String)
}

final class Notifier: NSObject, NotificationDispatching, UNUserNotificationCenterDelegate {
    override init() {
        super.init()
        // Route notification clicks through this delegate so they activate the
        // existing app instead of launching a new one.
        UNUserNotificationCenter.current().delegate = self
    }

    func requestAuthorization() async {
        do {
            _ = try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound])
        } catch {
            // Best-effort; we degrade silently.
        }
    }

    func dispatch(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// Show the banner/sound even while CCU Bar is in the foreground. Without this
    /// macOS suppresses notifications whenever our process is active.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    /// Called when the user clicks the notification. Just bring the running app to
    /// the front — do NOT spawn a new instance.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
        }
        completionHandler()
    }
}

/// Centralized threshold-crossing detector.
/// Returns threshold values (e.g. 75, 90) that were newly crossed upward.
struct ThresholdDetector {
    static let thresholds: [Int] = [75, 90]

    static func newlyCrossed(previous: Double?, current: Double, alreadyNotified: Set<Int>) -> [Int] {
        let prev = previous ?? -1 // treat no-previous as below all thresholds
        return thresholds
            .filter { !alreadyNotified.contains($0) }
            .filter { prev < Double($0) && current >= Double($0) }
    }
}
