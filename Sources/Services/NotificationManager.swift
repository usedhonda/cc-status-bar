import UserNotifications
import Foundation

extension NSNotification.Name {
    static let acknowledgeSession = NSNotification.Name("acknowledgeSession")
    static let focusSession = NSNotification.Name("focusSession")
}

final class NotificationManager: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationManager()

    override init() {
        super.init()
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        DebugLog.log("[NotificationManager] Initialized with delegate")
    }

    func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if granted {
                DebugLog.log("[NotificationManager] Permission granted")
            } else if let error = error {
                DebugLog.log("[NotificationManager] Permission error: \(error.localizedDescription)")
            } else {
                DebugLog.log("[NotificationManager] Permission denied")
            }
        }
    }

    func notify(title: String, body: String, sessionName: String? = nil) {
        guard AppSettings.notificationsEnabled else { return }

        DebugLog.log("[NotificationManager] Sending: \(title) - \(body)")

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        // Store session name for click callback
        if let sessionName = sessionName {
            content.userInfo = ["sessionName": sessionName]
        }

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )

        // Send via UNUserNotificationCenter
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                DebugLog.log("[NotificationManager] UNUserNotification failed: \(error.localizedDescription)")
            }
        }
    }

    func notifyWaitingInput(session: Session) {
        guard AppSettings.notificationsEnabled else { return }

        DebugLog.log("[NotificationManager] Sending: \(session.projectName) - Waiting for input")

        let content = UNMutableNotificationContent()
        content.title = session.projectName
        content.body = "Waiting for input • \(session.environmentLabel)"
        content.sound = .default

        // Store full session info for click callback
        content.userInfo = [
            "sessionId": session.sessionId,
            "cwd": session.cwd,
            "tty": session.tty ?? "",
            "ghosttyTabIndex": session.ghosttyTabIndex ?? -1
        ]

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                DebugLog.log("[NotificationManager] UNUserNotification failed: \(error.localizedDescription)")
            }
        }
    }

    func notifySessionTimeout(projectName: String) {
        notify(
            title: projectName,
            body: "Session timed out",
            sessionName: projectName
        )
    }

    // MARK: - UNUserNotificationCenterDelegate

    // Show notification even when app is active
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        DebugLog.log("[NotificationManager] willPresent called")
        completionHandler([.banner, .sound])
    }

    // Handle notification click
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        DebugLog.log("[NotificationManager] Notification clicked: \(userInfo)")

        // Extract session key from userInfo
        guard let sessionId = userInfo["sessionId"] as? String else {
            DebugLog.log("[NotificationManager] Missing sessionId in notification")
            completionHandler()
            return
        }

        let ttyString = userInfo["tty"] as? String
        let tty = (ttyString?.isEmpty == false) ? ttyString : nil

        // Build session key (same format as Session.id)
        let sessionKey = tty.map { "\(sessionId):\($0)" } ?? sessionId

        DebugLog.log("[NotificationManager] Delegating focus to AppDelegate for session: \(sessionKey)")

        // Delegate to AppDelegate to use the same code path as menu click
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .focusSession,
                object: nil,
                userInfo: ["sessionId": sessionKey]
            )
        }

        completionHandler()
    }

    // MARK: - Fallback

    private func notifyViaOsascript(title: String, body: String) {
        let escapedTitle = title.replacingOccurrences(of: "\"", with: "\\\"")
        let escapedBody = body.replacingOccurrences(of: "\"", with: "\\\"")

        let script = "display notification \"\(escapedBody)\" with title \"\(escapedTitle)\" sound name \"default\""

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]

        do {
            try process.run()
            DebugLog.log("[NotificationManager] Fallback osascript sent")
        } catch {
            DebugLog.log("[NotificationManager] osascript failed: \(error.localizedDescription)")
        }
    }
}
