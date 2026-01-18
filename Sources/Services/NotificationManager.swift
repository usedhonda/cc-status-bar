import UserNotifications

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
        guard AppSettings.notificationsEnabled else {
            DebugLog.log("[NotificationManager] Notifications disabled, skipping")
            return
        }

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

    func notifyWaitingInput(projectName: String) {
        notify(
            title: projectName,
            body: "Waiting for input",
            sessionName: projectName
        )
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

        if let sessionName = userInfo["sessionName"] as? String {
            DebugLog.log("[NotificationManager] Focusing session: \(sessionName)")
            // Focus the Ghostty tab for this session
            DispatchQueue.main.async {
                _ = GhosttyHelper.focusSession(sessionName)
            }
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
