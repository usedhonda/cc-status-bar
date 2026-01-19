import AppKit

// MARK: - ITerm2Adapter (TerminalAdapter conformance)

/// Adapter implementation for iTerm2 terminal
final class ITerm2Adapter: TerminalAdapter {
    let name = "iTerm2"
    let bundleIdentifier = ITerm2Helper.bundleIdentifier
    let capabilities: TerminalCapabilities = [.focusByTTY, .activateOnly]

    var isRunning: Bool {
        ITerm2Helper.isRunning
    }

    func focusSession(_ sessionName: String) -> Bool {
        // iTerm2 does not support title-based search in this implementation
        // Use focusByTTY instead
        false
    }

    func focusByTTY(_ tty: String) -> Bool {
        ITerm2Helper.focusSessionByTTY(tty)
    }

    func activate() -> Bool {
        ITerm2Helper.activate()
    }
}

// MARK: - ITerm2Helper (static API)

enum ITerm2Helper {
    static let bundleIdentifier = "com.googlecode.iterm2"

    /// Check if iTerm2 is running
    static var isRunning: Bool {
        !NSRunningApplication.runningApplications(
            withBundleIdentifier: bundleIdentifier
        ).isEmpty
    }

    /// Get iTerm2's running application instance
    static var runningApp: NSRunningApplication? {
        NSRunningApplication.runningApplications(
            withBundleIdentifier: bundleIdentifier
        ).first
    }

    /// Focus session by TTY using AppleScript whose clause (Gemini optimized)
    /// - Parameter tty: The TTY device path (e.g., "/dev/ttys002")
    /// - Returns: true if successfully focused
    static func focusSessionByTTY(_ tty: String) -> Bool {
        // Escape the TTY string for AppleScript
        let escapedTTY = tty.replacingOccurrences(of: "\"", with: "\\\"")

        let script = """
            tell application "iTerm"
                try
                    set targetSession to (first session of every tab of every window whose tty is "\(escapedTTY)")
                    tell targetSession
                        select
                    end tell
                    activate
                    return "true"
                on error errMsg
                    return "false"
                end try
            end tell
            """

        guard let appleScript = NSAppleScript(source: script) else {
            DebugLog.log("[ITerm2Helper] Failed to create AppleScript")
            return false
        }

        var error: NSDictionary?
        let result = appleScript.executeAndReturnError(&error)

        if let error = error {
            DebugLog.log("[ITerm2Helper] AppleScript error: \(error)")
            return false
        }

        let success = result.stringValue == "true"
        if success {
            DebugLog.log("[ITerm2Helper] Successfully focused session with TTY '\(tty)'")
        } else {
            DebugLog.log("[ITerm2Helper] Could not find session with TTY '\(tty)'")
        }

        return success
    }

    /// Activate iTerm2 (bring to front)
    /// - Returns: true if successfully activated
    static func activate() -> Bool {
        guard let app = runningApp else {
            DebugLog.log("[ITerm2Helper] iTerm2 not running")
            return false
        }

        app.activate(options: [.activateIgnoringOtherApps])
        DebugLog.log("[ITerm2Helper] Activated iTerm2")
        return true
    }
}
