import ArgumentParser
import Foundation

public struct SetupCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "setup",
        abstract: "Setup Claude Code hooks for monitoring"
    )

    @Flag(name: .long, help: "Remove hooks and clean up all data")
    var uninstall = false

    @Flag(name: .long, help: "Force setup even if already configured")
    var force = false

    private static let hookEvents = ["Notification", "Stop", "UserPromptSubmit"]

    public init() {}

    public func run() throws {
        if uninstall {
            try performUninstall()
            return
        }

        print("CC Status Bar Setup")
        print("===================")
        print("")

        // Check for Translocation
        if SetupManager.shared.isAppTranslocated() {
            print("Error: App is running from a temporary location (App Translocation).")
            print("Please move the app to /Applications or another permanent location first.")
            throw ExitCode.failure
        }

        let isFirstRun = SetupManager.shared.isFirstRun()

        if !isFirstRun && !force {
            print("Setup already completed. Use --force to reconfigure.")
            return
        }

        print("Setting up hooks...")
        print("")

        // 1. Ensure directories
        let fm = FileManager.default
        try fm.createDirectory(at: SetupManager.appSupportDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: SetupManager.binDir, withIntermediateDirectories: true)

        // 2. Create symlink
        let symlinkURL = try SetupManager.shared.ensureSymlink()
        print("Created symlink: \(symlinkURL.path)")

        // 3. Patch settings.json
        try patchSettings(hookPath: symlinkURL.path)
        print("Updated ~/.claude/settings.json")

        // 4. Mark as complete
        UserDefaults.standard.set(true, forKey: "DidCompleteSetup")
        UserDefaults.standard.set(Bundle.main.bundlePath, forKey: "LastBundlePath")

        print("")
        print("Setup complete!")
        print("")
        print("Please restart Claude Code for the changes to take effect.")
    }

    private func performUninstall() throws {
        print("Removing CC Status Bar configuration...")
        print("")

        do {
            try SetupManager.shared.removeAllData()
            print("Removed hooks from settings.json")
            print("Removed application data")
            print("")
            print("Uninstall complete. You can now delete the app.")
        } catch {
            print("Error during uninstall: \(error.localizedDescription)")
            throw ExitCode.failure
        }
    }

    private func patchSettings(hookPath: String) throws {
        let claudeDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude")
        let settingsFile = claudeDir.appendingPathComponent("settings.json")

        let fm = FileManager.default

        // Ensure .claude directory exists
        if !fm.fileExists(atPath: claudeDir.path) {
            try fm.createDirectory(at: claudeDir, withIntermediateDirectories: true)
        }

        var settings: [String: Any] = [:]

        // Load existing settings if present
        if fm.fileExists(atPath: settingsFile.path) {
            let data = try Data(contentsOf: settingsFile)

            // Create backup with timestamp
            let backupName = "settings.json.bak.\(Int(Date().timeIntervalSince1970))"
            let backupURL = claudeDir.appendingPathComponent(backupName)
            try data.write(to: backupURL)
            print("Created backup: \(backupURL.path)")

            // Parse JSON with explicit error handling
            do {
                if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    settings = json
                } else {
                    // Valid JSON but not a dictionary
                    FileHandle.standardError.write(
                        "Warning: settings.json is not a dictionary, using empty settings\n".data(using: .utf8)!
                    )
                }
            } catch {
                // Invalid JSON - warn and continue with empty settings
                FileHandle.standardError.write(
                    "Warning: Failed to parse settings.json: \(error.localizedDescription)\n".data(using: .utf8)!
                )
                FileHandle.standardError.write(
                    "Backup saved to: \(backupURL.path)\n".data(using: .utf8)!
                )
                FileHandle.standardError.write(
                    "Continuing with empty settings - hooks will be added fresh\n".data(using: .utf8)!
                )
            }
        }

        // Merge hooks
        var hooks = settings["hooks"] as? [String: [[String: Any]]] ?? [:]

        for eventName in Self.hookEvents {
            let entry = createHookEntry(eventName: eventName, hookPath: hookPath)

            // Remove existing CCStatusBar hooks for this event
            if var eventHooks = hooks[eventName] {
                eventHooks = eventHooks.filter { hookEntry in
                    guard let innerHooks = hookEntry["hooks"] as? [[String: Any]] else {
                        return true
                    }
                    return !innerHooks.contains { hook in
                        guard let command = hook["command"] as? String else { return false }
                        return SetupManager.isOwnHookCommand(command)
                    }
                }
                eventHooks.append(entry)
                hooks[eventName] = eventHooks
            } else {
                hooks[eventName] = [entry]
            }

            print("  [add] \(eventName)")
        }

        settings["hooks"] = hooks

        // Write back
        let data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: settingsFile, options: .atomic)
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
}
