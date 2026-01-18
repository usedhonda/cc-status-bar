import Foundation

enum AppSettings {
    private enum Keys {
        static let launchAtLogin = "launchAtLogin"
        static let notificationsEnabled = "notificationsEnabled"
        static let sessionTimeoutMinutes = "sessionTimeoutMinutes"
    }

    static var launchAtLogin: Bool {
        get { UserDefaults.standard.bool(forKey: Keys.launchAtLogin) }
        set { UserDefaults.standard.set(newValue, forKey: Keys.launchAtLogin) }
    }

    static var notificationsEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: Keys.notificationsEnabled) }
        set { UserDefaults.standard.set(newValue, forKey: Keys.notificationsEnabled) }
    }

    static var sessionTimeoutMinutes: Int {
        get {
            let value = UserDefaults.standard.integer(forKey: Keys.sessionTimeoutMinutes)
            return value > 0 ? value : 30  // Default 30 minutes
        }
        set { UserDefaults.standard.set(newValue, forKey: Keys.sessionTimeoutMinutes) }
    }
}
