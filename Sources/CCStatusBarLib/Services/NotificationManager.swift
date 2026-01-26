import UserNotifications
import Foundation

extension NSNotification.Name {
    static let acknowledgeSession = NSNotification.Name("acknowledgeSession")
    static let focusSession = NSNotification.Name("focusSession")
}

public final class NotificationManager: NSObject, UNUserNotificationCenterDelegate {
    public static let shared = NotificationManager()

    // Notification action identifiers
    private static let focusActionIdentifier = "FOCUS_TERMINAL"
    private static let categoryIdentifier = "SESSION_WAITING"

    // Cooldown tracking: sessionId -> (lastStatus, lastNotificationTime)
    private var notificationCooldowns: [String: (SessionStatus, Date)] = [:]
    private let cooldownInterval: TimeInterval = 5 * 60  // 5 minutes

    override init() {
        super.init()
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        setupNotificationActions()
        DebugLog.log("[NotificationManager] Initialized with delegate")
    }

    private func setupNotificationActions() {
        // Create "Focus Terminal" action
        let focusAction = UNNotificationAction(
            identifier: Self.focusActionIdentifier,
            title: "Focus Terminal",
            options: [.foreground]
        )

        // Create category with the action
        let category = UNNotificationCategory(
            identifier: Self.categoryIdentifier,
            actions: [focusAction],
            intentIdentifiers: [],
            options: []
        )

        // Register the category
        UNUserNotificationCenter.current().setNotificationCategories([category])
        DebugLog.log("[NotificationManager] Registered notification category with Focus action")
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

        // Check cooldown
        if let (lastStatus, lastTime) = notificationCooldowns[session.id] {
            let elapsed = Date().timeIntervalSince(lastTime)
            if lastStatus == session.status && elapsed < cooldownInterval {
                DebugLog.log("[NotificationManager] Cooldown active for \(session.displayName), skipping notification")
                return
            }
        }

        DebugLog.log("[NotificationManager] Sending: \(session.displayName) - Waiting for input")

        let content = UNMutableNotificationContent()
        content.title = session.displayName
        content.body = "Waiting for input • \(session.environmentLabel)"
        content.sound = .default
        content.categoryIdentifier = Self.categoryIdentifier  // Enable quick actions

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

        UNUserNotificationCenter.current().add(request) { [weak self] error in
            if let error = error {
                DebugLog.log("[NotificationManager] UNUserNotification failed: \(error.localizedDescription)")
            } else {
                // Update cooldown on successful send
                self?.notificationCooldowns[session.id] = (session.status, Date())
            }
        }
    }

    /// Clear cooldown for a session (called when status changes to running)
    func clearCooldown(sessionId: String) {
        notificationCooldowns.removeValue(forKey: sessionId)
    }

    /// Clear all cooldowns (for testing/debugging)
    func clearAllCooldowns() {
        notificationCooldowns.removeAll()
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
    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        DebugLog.log("[NotificationManager] willPresent called")
        completionHandler([.banner, .sound])
    }

    // Handle notification click and action buttons
    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        let actionIdentifier = response.actionIdentifier

        DebugLog.log("[NotificationManager] Notification response: action=\(actionIdentifier)")

        // Handle both notification click and Focus action button
        let shouldFocus = actionIdentifier == UNNotificationDefaultActionIdentifier ||
                          actionIdentifier == Self.focusActionIdentifier

        guard shouldFocus else {
            DebugLog.log("[NotificationManager] Action not handled: \(actionIdentifier)")
            completionHandler()
            return
        }

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
