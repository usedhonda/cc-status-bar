import UserNotifications

enum NotificationManager {
    static func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error = error {
                DebugLog.log("[NotificationManager] Permission error: \(error.localizedDescription)")
            } else {
                DebugLog.log("[NotificationManager] Permission granted: \(granted)")
            }
        }
    }

    static func notify(title: String, body: String) {
        guard AppSettings.notificationsEnabled else { return }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                DebugLog.log("[NotificationManager] Failed to send notification: \(error.localizedDescription)")
            }
        }
    }

    static func notifyWaitingInput(projectName: String) {
        notify(
            title: "CC Status Bar",
            body: "\(projectName) is waiting for input"
        )
    }

    static func notifySessionTimeout(projectName: String) {
        notify(
            title: "CC Status Bar",
            body: "\(projectName) session timed out"
        )
    }
}
