import Foundation
import UserNotifications

protocol NotificationDispatching: AnyObject {
    func requestAuthorization() async
    func dispatch(title: String, body: String)
}

final class Notifier: NotificationDispatching {
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
