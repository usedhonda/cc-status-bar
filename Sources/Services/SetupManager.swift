import Foundation
import AppKit

final class SetupManager {
    static let shared = SetupManager()

    // MARK: - Constants

    private enum Keys {
        static let didCompleteSetup = "DidCompleteSetup"
        static let lastBundlePath = "LastBundlePath"
        static let lastConfiguredVersion = "LastConfiguredVersion"
    }

    private static let hookEvents = ["Notification", "Stop", "UserPromptSubmit"]

    // MARK: - Paths

    static var appSupportDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("CCStatusBar", isDirectory: true)
    }

    static var binDir: URL {
        appSupportDir.appendingPathComponent("bin", isDirectory: true)
    }

    static var symlinkURL: URL {
        binDir.appendingPathComponent("CCStatusBar")
    }

    static var sessionsFile: URL {
        appSupportDir.appendingPathComponent("sessions.json")
    }

    private static let claudeDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude")
    private static let settingsFile = claudeDir.appendingPathComponent("settings.json")

    private init() {}

    // MARK: - Public API

    /// Check and run setup if needed. Call this on app launch.
    @MainActor
    func checkAndRunSetup() {
        // Check for App Translocation
        if isAppTranslocated() {
            showTranslocationAlert()
            return
        }

        // Always update symlink (handles app move)
        do {
            try ensureSymlink()
        } catch {
            print("Failed to update symlink: \(error)")
        }

        // Check if first run or settings need repair
        if isFirstRun() {
            showSetupWizard()
        } else if needsRepair() {
            repairSettingsSilently()
        } else {
            // Check if app was moved
            checkAndUpdateIfMoved()
        }
    }

    // MARK: - Translocation Detection

    func isAppTranslocated() -> Bool {
        guard let bundlePath = Bundle.main.bundlePath as String? else { return false }
        return bundlePath.contains("AppTranslocation")
    }

    @MainActor
    private func showTranslocationAlert() {
        let alert = NSAlert()
        alert.messageText = "Please move CC Status Bar"
        alert.informativeText = "For security reasons, macOS is running this app from a temporary location. Please move CC Status Bar to your Applications folder or another permanent location, then relaunch it."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open Applications Folder")
        alert.addButton(withTitle: "Quit")

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications"))
        }
        NSApp.terminate(nil)
    }

    @MainActor
    private func showParseErrorAlert(backupPath: String?) {
        let alert = NSAlert()
        alert.messageText = "Settings file was corrupted"
        alert.informativeText = """
            Your ~/.claude/settings.json file could not be parsed.

            \(backupPath.map { "A backup has been saved to:\n\($0)" } ?? "")

            CC Status Bar will add its hooks to a fresh configuration.
            You may want to manually restore other settings from the backup.
            """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    // MARK: - First Run Detection

    func isFirstRun() -> Bool {
        !UserDefaults.standard.bool(forKey: Keys.didCompleteSetup)
    }

    private func needsRepair() -> Bool {
        // Check if our hooks exist in settings.json
        guard FileManager.default.fileExists(atPath: Self.settingsFile.path) else {
            return true
        }

        do {
            let data = try Data(contentsOf: Self.settingsFile)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let hooks = json["hooks"] as? [String: [[String: Any]]] else {
                return true
            }

            // Check if at least one of our hooks exists
            for eventName in Self.hookEvents {
                if let eventHooks = hooks[eventName] {
                    for hookEntry in eventHooks {
                        if let innerHooks = hookEntry["hooks"] as? [[String: Any]] {
                            for hook in innerHooks {
                                if let command = hook["command"] as? String,
                                   command.contains("CCStatusBar hook") {
                                    return false // Found our hook
                                }
                            }
                        }
                    }
                }
            }
            return true // Our hooks not found
        } catch {
            return true
        }
    }

    // MARK: - Setup Wizard

    @MainActor
    private func showSetupWizard() {
        let alert = NSAlert()
        alert.messageText = "Setup CC Status Bar"
        alert.informativeText = "CC Status Bar needs to configure Claude Code hooks to monitor your sessions.\n\nThis will:\n- Add hooks to ~/.claude/settings.json\n- Create a backup of your current settings\n\nDo you want to continue?"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Setup")
        alert.addButton(withTitle: "Later")

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            performSetup()
        }
    }

    private func performSetup() {
        do {
            // 1. Ensure directories exist
            try FileManager.default.createDirectory(at: Self.appSupportDir, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: Self.binDir, withIntermediateDirectories: true)

            // 2. Create/update symlink
            try ensureSymlink()

            // 3. Backup and patch settings.json
            try backupAndPatchSettings()

            // 4. Mark setup as complete
            UserDefaults.standard.set(true, forKey: Keys.didCompleteSetup)
            UserDefaults.standard.set(Bundle.main.bundlePath, forKey: Keys.lastBundlePath)

            // 5. Show success
            DispatchQueue.main.async {
                let alert = NSAlert()
                alert.messageText = "Setup Complete"
                alert.informativeText = "CC Status Bar is now configured. You may need to restart Claude Code for the changes to take effect."
                alert.alertStyle = .informational
                alert.runModal()
            }
        } catch {
            DispatchQueue.main.async {
                let alert = NSAlert()
                alert.messageText = "Setup Failed"
                alert.informativeText = "Error: \(error.localizedDescription)"
                alert.alertStyle = .critical
                alert.runModal()
            }
        }
    }

    // MARK: - Symlink Management

    @discardableResult
    func ensureSymlink() throws -> URL {
        let fm = FileManager.default

        // Ensure directories exist
        try fm.createDirectory(at: Self.binDir, withIntermediateDirectories: true)

        guard let targetPath = Bundle.main.executableURL?.path else {
            throw SetupError.noExecutablePath
        }

        let linkPath = Self.symlinkURL.path

        // Remove existing symlink or file
        if fm.fileExists(atPath: linkPath) {
            try fm.removeItem(atPath: linkPath)
        }

        // Create new symlink
        try fm.createSymbolicLink(atPath: linkPath, withDestinationPath: targetPath)

        return Self.symlinkURL
    }

    // MARK: - Settings Management

    private func backupAndPatchSettings() throws {
        let fm = FileManager.default

        // Ensure .claude directory exists
        if !fm.fileExists(atPath: Self.claudeDir.path) {
            try fm.createDirectory(at: Self.claudeDir, withIntermediateDirectories: true)
        }

        var settings: [String: Any] = [:]
        var backupURL: URL?

        // Load existing settings if present
        if fm.fileExists(atPath: Self.settingsFile.path) {
            let data = try Data(contentsOf: Self.settingsFile)

            // Create backup with timestamp
            let backupName = "settings.json.bak.\(Int(Date().timeIntervalSince1970))"
            backupURL = Self.claudeDir.appendingPathComponent(backupName)
            try data.write(to: backupURL!)

            // Parse JSON with explicit error handling
            do {
                if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    settings = json
                } else {
                    // Valid JSON but not a dictionary
                    DebugLog.log("[SetupManager] settings.json is not a dictionary, using empty settings")
                    DispatchQueue.main.async {
                        self.showParseErrorAlert(backupPath: backupURL?.path)
                    }
                }
            } catch {
                // Invalid JSON - notify user and continue with empty settings
                DebugLog.log("[SetupManager] JSON parse failed: \(error.localizedDescription)")
                DispatchQueue.main.async {
                    self.showParseErrorAlert(backupPath: backupURL?.path)
                }
                // Continue with empty settings - hooks will be added fresh
            }
        }

        // Get hook command path (use symlink path)
        let hookPath = Self.symlinkURL.path

        // Merge hooks
        var hooks = settings["hooks"] as? [String: [[String: Any]]] ?? [:]

        for eventName in Self.hookEvents {
            let entry = createHookEntry(eventName: eventName, hookPath: hookPath)

            // Check if we already have this hook
            var alreadyExists = false
            if let eventHooks = hooks[eventName] {
                for hookEntry in eventHooks {
                    if let innerHooks = hookEntry["hooks"] as? [[String: Any]] {
                        for hook in innerHooks {
                            if let command = hook["command"] as? String,
                               command.contains("CCStatusBar hook \(eventName)") {
                                alreadyExists = true
                                break
                            }
                        }
                    }
                }
            }

            if !alreadyExists {
                if var existing = hooks[eventName] {
                    existing.append(entry)
                    hooks[eventName] = existing
                } else {
                    hooks[eventName] = [entry]
                }
            }
        }

        settings["hooks"] = hooks

        // Write back
        let data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: Self.settingsFile, options: .atomic)
    }

    private func createHookEntry(eventName: String, hookPath: String) -> [String: Any] {
        // Quote the path to handle spaces in Application Support
        var entry: [String: Any] = [
            "hooks": [
                ["type": "command", "command": "\"\(hookPath)\" hook \(eventName)"]
            ]
        ]
        if eventName != "UserPromptSubmit" {
            entry["matcher"] = ""
        }
        return entry
    }

    // MARK: - Move Detection

    private func checkAndUpdateIfMoved() {
        let currentPath = Bundle.main.bundlePath
        let savedPath = UserDefaults.standard.string(forKey: Keys.lastBundlePath)

        if savedPath != currentPath {
            // App was moved, update symlink
            DebugLog.log("[SetupManager] App moved: \(savedPath ?? "nil") -> \(currentPath)")
            do {
                try ensureSymlink()
                UserDefaults.standard.set(currentPath, forKey: Keys.lastBundlePath)
                DebugLog.log("[SetupManager] Symlink updated successfully")
            } catch {
                DebugLog.log("[SetupManager] Symlink update failed: \(error.localizedDescription)")
                DispatchQueue.main.async {
                    self.showSymlinkUpdateError(error)
                }
            }
        }
    }

    @MainActor
    private func showSymlinkUpdateError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Hook configuration update failed"
        alert.informativeText = """
            CC Status Bar was moved but failed to update its configuration.

            Error: \(error.localizedDescription)

            Claude Code hooks may not work correctly.
            Please try running 'CCStatusBar setup --force' or reinstall the app.
            """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func repairSettingsSilently() {
        do {
            try ensureSymlink()
            try backupAndPatchSettings()
            UserDefaults.standard.set(true, forKey: Keys.didCompleteSetup)
            UserDefaults.standard.set(Bundle.main.bundlePath, forKey: Keys.lastBundlePath)
        } catch {
            print("Failed to repair settings: \(error)")
        }
    }

    // MARK: - Cleanup (for uninstall)

    func removeHooksFromSettings() throws {
        guard FileManager.default.fileExists(atPath: Self.settingsFile.path) else {
            return
        }

        let data = try Data(contentsOf: Self.settingsFile)
        guard var settings = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              var hooks = settings["hooks"] as? [String: [[String: Any]]] else {
            return
        }

        // Remove our hooks
        for eventName in Self.hookEvents {
            if let eventHooks = hooks[eventName] {
                let filtered = eventHooks.filter { entry in
                    guard let innerHooks = entry["hooks"] as? [[String: Any]] else {
                        return true
                    }
                    return !innerHooks.contains { hook in
                        guard let command = hook["command"] as? String else { return false }
                        return command.contains("CCStatusBar hook")
                    }
                }
                if filtered.isEmpty {
                    hooks.removeValue(forKey: eventName)
                } else {
                    hooks[eventName] = filtered
                }
            }
        }

        settings["hooks"] = hooks

        let outData = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
        try outData.write(to: Self.settingsFile, options: .atomic)
    }

    func removeAllData() throws {
        let fm = FileManager.default

        // Remove hooks from settings
        try removeHooksFromSettings()

        // Remove Application Support folder
        if fm.fileExists(atPath: Self.appSupportDir.path) {
            try fm.removeItem(at: Self.appSupportDir)
        }

        // Clear UserDefaults
        UserDefaults.standard.removeObject(forKey: Keys.didCompleteSetup)
        UserDefaults.standard.removeObject(forKey: Keys.lastBundlePath)
        UserDefaults.standard.removeObject(forKey: Keys.lastConfiguredVersion)
    }
}

// MARK: - Errors

enum SetupError: LocalizedError {
    case noExecutablePath
    case settingsParseError(reason: String)
    case symlinkCreationFailed(underlying: Error)
    case settingsWriteFailed(underlying: Error)
    case permissionDenied(path: String)

    var errorDescription: String? {
        switch self {
        case .noExecutablePath:
            return "Could not determine executable path"
        case .settingsParseError(let reason):
            return "Failed to parse settings.json: \(reason)"
        case .symlinkCreationFailed(let error):
            return "Failed to create symlink: \(error.localizedDescription)"
        case .settingsWriteFailed(let error):
            return "Failed to write settings.json: \(error.localizedDescription)"
        case .permissionDenied(let path):
            return "Permission denied: \(path)"
        }
    }
}
