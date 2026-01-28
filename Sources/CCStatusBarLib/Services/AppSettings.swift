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

    /// Bundle ID for shared UserDefaults access (CLI and GUI)
    private static let bundleID = "com.ccstatusbar.app"

    /// Shared UserDefaults accessible from both GUI and CLI processes
    private static var defaults: UserDefaults {
        // Use suite name to access the app's UserDefaults from CLI
        UserDefaults(suiteName: bundleID) ?? UserDefaults.standard
    }

    static var launchAtLogin: Bool {
        get { defaults.bool(forKey: Keys.launchAtLogin) }
        set { defaults.set(newValue, forKey: Keys.launchAtLogin) }
    }

    static var notificationsEnabled: Bool {
        get {
            // Default to false if not set (opt-in)
            if defaults.object(forKey: Keys.notificationsEnabled) == nil {
                return false
            }
            return defaults.bool(forKey: Keys.notificationsEnabled)
        }
        set { defaults.set(newValue, forKey: Keys.notificationsEnabled) }
    }

    static var sessionTimeoutMinutes: Int {
        get {
            // Check if value was explicitly set (0 = Never is valid)
            if defaults.object(forKey: Keys.sessionTimeoutMinutes) == nil {
                return 60  // Default 1 hour
            }
            return defaults.integer(forKey: Keys.sessionTimeoutMinutes)
        }
        set { defaults.set(newValue, forKey: Keys.sessionTimeoutMinutes) }
    }

    static var webServerEnabled: Bool {
        get {
            // Default to false if not set (opt-in)
            if defaults.object(forKey: Keys.webServerEnabled) == nil {
                return false
            }
            return defaults.bool(forKey: Keys.webServerEnabled)
        }
        set { defaults.set(newValue, forKey: Keys.webServerEnabled) }
    }

    static var webServerPort: Int {
        get {
            // Check if value was explicitly set
            if defaults.object(forKey: Keys.webServerPort) == nil {
                return 8080  // Default port
            }
            return defaults.integer(forKey: Keys.webServerPort)
        }
        set { defaults.set(newValue, forKey: Keys.webServerPort) }
    }

    static var colorTheme: ColorTheme {
        get {
            let raw = defaults.string(forKey: Keys.colorTheme) ?? "vibrant"
            return ColorTheme(rawValue: raw) ?? .vibrant
        }
        set { defaults.set(newValue.rawValue, forKey: Keys.colorTheme) }
    }
}
