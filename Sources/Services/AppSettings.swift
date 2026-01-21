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
        get {
            // Default to false if not set (opt-in)
            if UserDefaults.standard.object(forKey: Keys.notificationsEnabled) == nil {
                return false
            }
            return UserDefaults.standard.bool(forKey: Keys.notificationsEnabled)
        }
        set { UserDefaults.standard.set(newValue, forKey: Keys.notificationsEnabled) }
    }

    static var sessionTimeoutMinutes: Int {
        get {
            // Check if value was explicitly set (0 = Never is valid)
            if UserDefaults.standard.object(forKey: Keys.sessionTimeoutMinutes) == nil {
                return 60  // Default 1 hour
            }
            return UserDefaults.standard.integer(forKey: Keys.sessionTimeoutMinutes)
        }
        set { UserDefaults.standard.set(newValue, forKey: Keys.sessionTimeoutMinutes) }
    }
}
