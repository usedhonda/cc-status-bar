import Foundation

enum AppSettings {
    private enum Keys {
        static let launchAtLogin = "launchAtLogin"
        static let notificationsEnabled = "notificationsEnabled"
        static let sessionTimeoutMinutes = "sessionTimeoutMinutes"
        static let webServerEnabled = "webServerEnabled"
        static let webServerPort = "webServerPort"
        static let colorTheme = "colorTheme"
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

    static var webServerEnabled: Bool {
        get {
            // Default to false if not set (opt-in)
            if UserDefaults.standard.object(forKey: Keys.webServerEnabled) == nil {
                return false
            }
            return UserDefaults.standard.bool(forKey: Keys.webServerEnabled)
        }
        set { UserDefaults.standard.set(newValue, forKey: Keys.webServerEnabled) }
    }

    static var webServerPort: Int {
        get {
            // Check if value was explicitly set
            if UserDefaults.standard.object(forKey: Keys.webServerPort) == nil {
                return 8080  // Default port
            }
            return UserDefaults.standard.integer(forKey: Keys.webServerPort)
        }
        set { UserDefaults.standard.set(newValue, forKey: Keys.webServerPort) }
    }

    static var colorTheme: ColorTheme {
        get {
            let raw = UserDefaults.standard.string(forKey: Keys.colorTheme) ?? "vibrant"
            return ColorTheme(rawValue: raw) ?? .vibrant
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: Keys.colorTheme) }
    }
}
