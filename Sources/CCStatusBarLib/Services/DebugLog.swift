import Foundation
import Darwin
import os

enum DebugLog {
    enum Level: Int {
        case debug = 0
        case info = 1
    }

    private static let maxLogBytes: UInt64 = 50 * 1024 * 1024
    private static let logger = Logger(subsystem: "com.ccstatusbar.app", category: "debug")
    private static let stateLock = NSLock()
    private static let timestampLock = NSLock()
    private static var logDirectoryCreated = false
    private static var fileHandle: FileHandle?
    private static let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let debugOnlyPatterns = [
        "Cache hit",
        "cache hit",
        "Found pane",
        "Found tmux pane",
        "Found Codex PID",
        "Detected terminal for Codex",
        "Tab titles cache hit",
        "Tab descriptors cache hit",
        "TTY tab index cache hit",
        "Terminal cache hit",
        "isUserTyping check",
        "Keystroke detected"
    ]

    static func log(_ message: String, level explicitLevel: Level? = nil) {
        let level = explicitLevel ?? inferredLevel(for: message)
        guard shouldWrite(message: message, explicitLevel: explicitLevel) else { return }

        // Visible in Console.app
        switch level {
        case .debug:
            logger.debug("\(message, privacy: .public)")
        case .info:
            logger.info("\(message, privacy: .public)")
        }
        NSLog("[CCStatusBar] \(message)")

        // Append to log file
        guard let data = "[\(timestamp())] \(message)\n".data(using: .utf8) else { return }
        stateLock.lock()
        defer { stateLock.unlock() }

        if let url = logFileURL(createDirectoryIfNeeded: true) {
            rotateLogIfNeeded(at: url, maxBytes: maxLogBytes)
            append(data, to: url)
        }
    }

    static func shouldWrite(
        message: String,
        explicitLevel: Level? = nil,
        verbose: Bool = verboseLoggingEnabled()
    ) -> Bool {
        let level = explicitLevel ?? inferredLevel(for: message)
        return verbose || level.rawValue >= Level.info.rawValue
    }

    static func inferredLevel(for message: String) -> Level {
        debugOnlyPatterns.contains { message.contains($0) } ? .debug : .info
    }

    private static func verboseLoggingEnabled() -> Bool {
        let env = ProcessInfo.processInfo.environment["CCSTATUSBAR_DEBUG_LOG_VERBOSE"]
        if env == "1" || env?.lowercased() == "true" {
            return true
        }
        return UserDefaults.standard.bool(forKey: "CCStatusBarDebugVerboseLogging")
    }

    private static func logFileURL(createDirectoryIfNeeded: Bool) -> URL? {
        let fm = FileManager.default
        guard let dir = fm.urls(for: .libraryDirectory, in: .userDomainMask).first else { return nil }
        let folder = dir.appendingPathComponent("Logs/CCStatusBar", isDirectory: true)
        if createDirectoryIfNeeded, !logDirectoryCreated {
            do {
                try fm.createDirectory(at: folder, withIntermediateDirectories: true)
                logDirectoryCreated = true
            } catch {
                return nil
            }
        }
        return folder.appendingPathComponent("debug.log")
    }

    static func rotateLogIfNeeded(at url: URL, maxBytes: UInt64) {
        let fm = FileManager.default
        guard
            let attrs = try? fm.attributesOfItem(atPath: url.path),
            let fileSize = attrs[.size] as? NSNumber,
            fileSize.uint64Value >= maxBytes
        else {
            return
        }

        try? fileHandle?.close()
        fileHandle = nil

        let rotatedURL = url.deletingLastPathComponent()
            .appendingPathComponent("\(url.lastPathComponent).1")
        if fm.fileExists(atPath: rotatedURL.path) {
            try? fm.removeItem(at: rotatedURL)
        }
        try? fm.moveItem(at: url, to: rotatedURL)
    }

    private static func append(_ data: Data, to url: URL) {
        if fileHandle == nil {
            let fd = open(url.path, O_WRONLY | O_CREAT | O_APPEND, S_IRUSR | S_IWUSR | S_IRGRP | S_IROTH)
            if fd < 0 {
                return
            }
            fileHandle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        }
        try? fileHandle?.write(contentsOf: data)
    }

    private static func timestamp() -> String {
        timestampLock.lock()
        defer { timestampLock.unlock() }
        return timestampFormatter.string(from: Date())
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
        if let logURL = logFileURL(createDirectoryIfNeeded: true) {
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
