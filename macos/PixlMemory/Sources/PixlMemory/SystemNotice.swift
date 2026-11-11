import Foundation
import UserNotifications

/// A macOS notification, for the notices the Pixl can't show itself (hidden, or fullscreen).
/// Asks for permission the first time.
enum SystemNotice {
    static func post(_ text: String) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { ok, _ in
            guard ok else { return }
            let c = UNMutableNotificationContent()
            c.title = "Pixl Memory"
            c.body = text
            center.add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
        }
    }
}
