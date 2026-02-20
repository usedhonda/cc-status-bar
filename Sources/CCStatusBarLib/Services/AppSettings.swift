import Foundation

/// Session display mode for menu items
enum SessionDisplayMode: String, CaseIterable {
    case projectName = "project"              // Project name (default)
    case tmuxWindow = "tmux_window"           // tmux window name
    case tmuxSession = "tmux_session"         // tmux session name
    case tmuxSessionWindow = "tmux_sess_win"  // tmux session:window format

    var label: String {
        switch self {
        case .projectName: return "Project Name"
        case .tmuxWindow: return "tmux Window Name"
        case .tmuxSession: return "tmux Session Name"
        case .tmuxSessionWindow: return "tmux Session/Window"
        }
    }
}

enum AppSettings {
    private enum Keys {
        static let launchAtLogin = "launchAtLogin"
        static let notificationsEnabled = "notificationsEnabled"
        static let sessionTimeoutMinutes = "sessionTimeoutMinutes"
        static let webServerEnabled = "webServerEnabled"
        static let webServerPort = "webServerPort"
        static let colorTheme = "colorTheme"
        static let showClaudeCodeSessions = "showClaudeCodeSessions"
        static let showCodexSessions = "showCodexSessions"
        static let sessionDisplayMode = "sessionDisplayMode"
        static let autofocusEnabled = "autofocusEnabled"
        static let soundEnabled = "soundEnabled"
        static let alertSoundPath = "alertSoundPath"
    }

    /// Bundle ID for shared UserDefaults access (CLI and GUI)
    private static let bundleID = "com.ccstatusbar.app"

    /// Shared UserDefaults accessible from both GUI and CLI processes
    private static var defaults: UserDefaults {
        // Use suite name to access the app's UserDefaults from CLI
        UserDefaults(suiteName: bundleID) ?? UserDefaults.standard
    }

    /// Shared UserDefaults store (for @AppStorage)
    static var userDefaultsStore: UserDefaults {
        defaults
    }

    /// Default alert sound path assigned on startup for first-time users.
    static let defaultAlertSoundPath = "/System/Library/Sounds/Ping.aiff"

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

    static var showClaudeCodeSessions: Bool {
        get {
            // Default to true if not set
            if defaults.object(forKey: Keys.showClaudeCodeSessions) == nil {
                return true
            }
            return defaults.bool(forKey: Keys.showClaudeCodeSessions)
        }
        set { defaults.set(newValue, forKey: Keys.showClaudeCodeSessions) }
    }

    static var showCodexSessions: Bool {
        get {
            // Default to true if not set
            if defaults.object(forKey: Keys.showCodexSessions) == nil {
                return true
            }
            return defaults.bool(forKey: Keys.showCodexSessions)
        }
        set { defaults.set(newValue, forKey: Keys.showCodexSessions) }
    }

    static var autofocusEnabled: Bool {
        get {
            // Default to false if not set (opt-in)
            if defaults.object(forKey: Keys.autofocusEnabled) == nil {
                return false
            }
            return defaults.bool(forKey: Keys.autofocusEnabled)
        }
        set { defaults.set(newValue, forKey: Keys.autofocusEnabled) }
    }

    static var soundEnabled: Bool {
        get {
            // Default to true if not set (opt-in by default)
            if defaults.object(forKey: Keys.soundEnabled) == nil {
                return true
            }
            return defaults.bool(forKey: Keys.soundEnabled)
        }
        set { defaults.set(newValue, forKey: Keys.soundEnabled) }
    }

    /// Alert sound path. "beep"/nil/empty = default alert file (with system beep fallback),
    /// other path = custom/system file.
    /// nil/empty means uninitialized (startup will assign default once).
    static var alertSoundPath: String? {
        get { defaults.string(forKey: Keys.alertSoundPath) }
        set { defaults.set(newValue, forKey: Keys.alertSoundPath) }
    }

    /// Initialize alertSoundPath once for first-time users only.
    /// Existing values (including "beep" and custom paths) are preserved.
    static func initializeDefaultAlertSoundIfNeeded(
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) {
        if let current = alertSoundPath, !current.isEmpty {
            return
        }

        if fileExists(defaultAlertSoundPath) {
            alertSoundPath = defaultAlertSoundPath
        } else {
            alertSoundPath = "beep"
        }
    }

    static var sessionDisplayMode: SessionDisplayMode {
        get {
            let raw = defaults.string(forKey: Keys.sessionDisplayMode) ?? "project"
            return SessionDisplayMode(rawValue: raw) ?? .projectName
        }
        set { defaults.set(newValue.rawValue, forKey: Keys.sessionDisplayMode) }
    }
}
