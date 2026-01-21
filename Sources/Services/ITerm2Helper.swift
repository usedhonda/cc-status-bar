import AppKit

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

    /// Focus session by TTY using AppleScript
    /// - Parameter tty: The TTY device path (e.g., "/dev/ttys002")
    /// - Returns: true if successfully focused
    static func focusSessionByTTY(_ tty: String) -> Bool {
        // Escape the TTY string for AppleScript
        let escapedTTY = tty.replacingOccurrences(of: "\"", with: "\\\"")

        // Iterate through all sessions to find matching TTY,
        // then explicitly select session, tab, and window
        let script = """
            tell application "iTerm"
                try
                    repeat with w in windows
                        repeat with t in tabs of w
                            repeat with s in sessions of t
                                if tty of s is "\(escapedTTY)" then
                                    tell s to select
                                    select t
                                    select w
                                    activate
                                    return "true"
                                end if
                            end repeat
                        end repeat
                    end repeat
                    return "false"
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

    /// Get the TTY of the currently focused session
    /// - Returns: TTY path (e.g., "/dev/ttys002") or nil
    static func getCurrentTTY() -> String? {
        guard isRunning else { return nil }

        let script = """
            tell application "iTerm"
                try
                    return tty of current session of current tab of current window
                on error
                    return ""
                end try
            end tell
            """

        guard let appleScript = NSAppleScript(source: script) else {
            DebugLog.log("[ITerm2Helper] Failed to create AppleScript for getCurrentTTY")
            return nil
        }

        var error: NSDictionary?
        let result = appleScript.executeAndReturnError(&error)

        if let error = error {
            DebugLog.log("[ITerm2Helper] getCurrentTTY error: \(error)")
            return nil
        }

        guard let tty = result.stringValue, !tty.isEmpty else {
            return nil
        }

        DebugLog.log("[ITerm2Helper] Current TTY: \(tty)")
        return tty
    }

    /// Activate iTerm2 (bring to front)
    /// - Returns: true if successfully activated
    @discardableResult
    static func activate() -> Bool {
        guard let app = runningApp else {
            DebugLog.log("[ITerm2Helper] iTerm2 not running")
            return false
        }

        app.activate(options: [.activateIgnoringOtherApps])
        DebugLog.log("[ITerm2Helper] Activated iTerm2")
        return true
    }

    /// Get tab index by TTY (0-based)
    /// Searches sessions in the current window by TTY device path
    /// - Parameter tty: The TTY device path (e.g., "/dev/ttys001")
    /// - Returns: Tab index (0-based) if found, nil otherwise
    static func getTabIndexByTTY(_ tty: String) -> Int? {
        guard isRunning else { return nil }

        let escapedTTY = tty.replacingOccurrences(of: "\"", with: "\\\"")

        // Search for session with matching TTY and return its tab index
        let script = """
            tell application "iTerm"
                try
                    set w to current window
                    if w is missing value then return "-1"
                    set tabList to tabs of w
                    repeat with i from 1 to count of tabList
                        set t to item i of tabList
                        repeat with s in sessions of t
                            if tty of s is "\(escapedTTY)" then
                                return (i - 1) as string
                            end if
                        end repeat
                    end repeat
                    return "-1"
                on error errMsg
                    return "-1"
                end try
            end tell
            """

        guard let appleScript = NSAppleScript(source: script) else {
            return nil
        }

        var error: NSDictionary?
        let result = appleScript.executeAndReturnError(&error)

        if error != nil {
            return nil
        }

        guard let indexStr = result.stringValue,
              let index = Int(indexStr),
              index >= 0 else {
            return nil
        }

        DebugLog.log("[ITerm2Helper] Found tab index \(index) for TTY '\(tty)'")
        return index
    }

    /// Get tab index by searching for a matching session name (0-based)
    /// Searches tabs in the first window
    /// - Parameter sessionName: The session name to search for (e.g., tmux session name)
    /// - Returns: Tab index (0-based) if found, nil otherwise
    static func getTabIndexByName(_ sessionName: String) -> Int? {
        guard isRunning else { return nil }

        let escapedName = sessionName.replacingOccurrences(of: "\"", with: "\\\"")

        // Search for tab whose name contains the session name and return its index
        let script = """
            tell application "iTerm"
                try
                    set w to current window
                    if w is missing value then return "-1"
                    set tabList to tabs of w
                    repeat with i from 1 to count of tabList
                        set t to item i of tabList
                        set tabName to name of current session of t
                        if tabName contains "\(escapedName)" then
                            return (i - 1) as string
                        end if
                    end repeat
                    return "-1"
                on error errMsg
                    return "-1"
                end try
            end tell
            """

        guard let appleScript = NSAppleScript(source: script) else {
            return nil
        }

        var error: NSDictionary?
        let result = appleScript.executeAndReturnError(&error)

        if error != nil {
            return nil
        }

        guard let indexStr = result.stringValue,
              let index = Int(indexStr),
              index >= 0 else {
            return nil
        }

        DebugLog.log("[ITerm2Helper] Found tab index \(index) for '\(sessionName)'")
        return index
    }

    /// Focus session by name/title (for tmux sessions)
    /// Searches all tabs in all windows for a session whose name contains the search term
    /// - Parameter sessionName: The session name to search for (e.g., tmux session name)
    /// - Returns: true if successfully focused
    static func focusSessionByName(_ sessionName: String) -> Bool {
        let escapedName = sessionName.replacingOccurrences(of: "\"", with: "\\\"")

        // Search for tab whose name contains the session name
        let script = """
            tell application "iTerm"
                try
                    repeat with w in windows
                        repeat with t in tabs of w
                            set tabName to name of current session of t
                            if tabName contains "\(escapedName)" then
                                select t
                                select w
                                activate
                                return "true"
                            end if
                        end repeat
                    end repeat
                    return "false"
                on error errMsg
                    return "error: " & errMsg
                end try
            end tell
            """

        guard let appleScript = NSAppleScript(source: script) else {
            DebugLog.log("[ITerm2Helper] Failed to create AppleScript for name search")
            return false
        }

        var error: NSDictionary?
        let result = appleScript.executeAndReturnError(&error)

        if let error = error {
            DebugLog.log("[ITerm2Helper] AppleScript error (name search): \(error)")
            return false
        }

        let resultStr = result.stringValue ?? ""
        if resultStr == "true" {
            DebugLog.log("[ITerm2Helper] Successfully focused session with name '\(sessionName)'")
            return true
        } else {
            DebugLog.log("[ITerm2Helper] Could not find session with name '\(sessionName)': \(resultStr)")
            return false
        }
    }
}
