import Foundation
import os

enum DebugLog {
    private static let logger = Logger(subsystem: "com.ccstatusbar.app", category: "debug")

    static func log(_ message: String) {
        // Visible in Console.app
        logger.info("\(message, privacy: .public)")
        NSLog("[CCStatusBar] \(message)")

        // Append to log file
        if let url = logFileURL() {
            let line = "[\(timestamp())] \(message)\n"
            append(line, to: url)
        }
    }

    private static func logFileURL() -> URL? {
        let fm = FileManager.default
        guard let dir = fm.urls(for: .libraryDirectory, in: .userDomainMask).first else { return nil }
        let folder = dir.appendingPathComponent("Logs/CCStatusBar", isDirectory: true)
        do { try fm.createDirectory(at: folder, withIntermediateDirectories: true) } catch { return nil }
        return folder.appendingPathComponent("debug.log")
    }

    private static func append(_ line: String, to url: URL) {
        if let data = line.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: url.path) {
                if let handle = try? FileHandle(forWritingTo: url) {
                    _ = try? handle.seekToEnd()
                    try? handle.write(contentsOf: data)
                    try? handle.close()
                }
            } else {
                try? data.write(to: url)
            }
        }
    }

    private static func timestamp() -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: Date())
    }

    // MARK: - Diagnostics

    /// Mask user-specific paths for privacy
    private static func maskPath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.replacingOccurrences(of: home, with: "~")
    }

    /// Mask TTY to show only device name (e.g., /dev/ttys001 -> ttys001)
    private static func maskTTY(_ tty: String) -> String {
        if tty.hasPrefix("/dev/") {
            return String(tty.dropFirst(5))
        }
        return tty
    }

    static func collectDiagnostics() -> String {
        var info: [String] = []
        let fm = FileManager.default

        info.append("=== CC Status Bar Diagnostics ===")
        info.append("Timestamp: \(timestamp())")
        info.append("")

        // App info
        info.append("-- App Info --")
        info.append("Bundle Path: \(maskPath(Bundle.main.bundlePath))")
        info.append("Is Translocated: \(SetupManager.shared.isAppTranslocated())")
        info.append("Is First Run: \(SetupManager.shared.isFirstRun())")
        info.append("")

        // Symlink info
        info.append("-- Symlink --")
        let symlinkPath = SetupManager.symlinkURL.path
        info.append("Symlink Path: \(maskPath(symlinkPath))")
        if fm.fileExists(atPath: symlinkPath) {
            if let target = try? fm.destinationOfSymbolicLink(atPath: symlinkPath) {
                info.append("Symlink Target: \(maskPath(target))")
                info.append("Target Exists: \(fm.fileExists(atPath: target))")
            } else {
                info.append("Symlink Target: (not a symlink)")
            }
        } else {
            info.append("Symlink: Not found")
        }
        info.append("")

        // Sessions file
        info.append("-- Sessions --")
        let sessionsPath = SetupManager.sessionsFile.path
        info.append("Sessions File: \(maskPath(sessionsPath))")
        info.append("Sessions File Exists: \(fm.fileExists(atPath: sessionsPath))")
        info.append("")

        // Settings file
        info.append("-- Settings --")
        let settingsPath = fm.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json").path
        info.append("Settings File: \(maskPath(settingsPath))")
        info.append("Settings File Exists: \(fm.fileExists(atPath: settingsPath))")

        // Check for hooks (only report presence, not content)
        if fm.fileExists(atPath: settingsPath),
           let data = try? Data(contentsOf: URL(fileURLWithPath: settingsPath)),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let hooks = json["hooks"] as? [String: Any] {
            let hasHooks = hooks.values.contains { entries in
                guard let arr = entries as? [[String: Any]] else { return false }
                return arr.contains { entry in
                    guard let innerHooks = entry["hooks"] as? [[String: Any]] else { return false }
                    return innerHooks.contains { hook in
                        guard let command = hook["command"] as? String else { return false }
                        return SetupManager.isOwnHookCommand(command)
                    }
                }
            }
            info.append("CCStatusBar Hooks Found: \(hasHooks)")
        } else {
            info.append("CCStatusBar Hooks Found: (unable to check)")
        }
        info.append("")

        // Log file
        info.append("-- Log File --")
        if let logURL = logFileURL() {
            info.append("Log File: \(maskPath(logURL.path))")
            info.append("Log File Exists: \(fm.fileExists(atPath: logURL.path))")
        }
        info.append("")

        // Permissions
        info.append(PermissionManager.diagnosticsReport())
        info.append("")

        // Running Terminals
        info.append("-- Running Terminals --")
        info.append("Ghostty: \(GhosttyHelper.isRunning ? "Running" : "Not running")")
        info.append("iTerm2: \(ITerm2Helper.isRunning ? "Running" : "Not running")")

        return info.joined(separator: "\n")
    }
}
