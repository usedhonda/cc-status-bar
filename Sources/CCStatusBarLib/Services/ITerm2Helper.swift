import AppKit
import Foundation

// MARK: - ITerm2Helper (static API)

enum ITerm2Helper {
    struct TabDescriptor {
        let windowIndex: Int
        let tabIndex: Int
        let name: String
    }

    // MARK: - Cache

    private static let cacheLock = NSLock()
    private static var tabDescriptorsCache: [TabDescriptor]?
    private static var tabDescriptorsCacheTime: Date = .distantPast
    private static var ttyTabIndexCache: [String: Int] = [:]
    private static var ttyTabIndexCacheTime: Date = .distantPast
    private static let cacheTTL: TimeInterval = 3.0

    /// Invalidate all caches (call when tab state changes, e.g., after focus/select)
    static func invalidateCache() {
        cacheLock.lock()
        tabDescriptorsCache = nil
        tabDescriptorsCacheTime = .distantPast
        ttyTabIndexCache.removeAll()
        ttyTabIndexCacheTime = .distantPast
        cacheLock.unlock()
    }

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

        // Check cache
        cacheLock.lock()
        if Date().timeIntervalSince(ttyTabIndexCacheTime) < cacheTTL,
           let cached = ttyTabIndexCache[tty] {
            cacheLock.unlock()
            DebugLog.log("[ITerm2Helper] TTY tab index cache hit for \(tty)")
            return cached
        }
        cacheLock.unlock()

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

        // Update cache
        cacheLock.lock()
        ttyTabIndexCache[tty] = index
        ttyTabIndexCacheTime = Date()
        cacheLock.unlock()

        DebugLog.log("[ITerm2Helper] Found tab index \(index) for TTY '\(tty)'")
        return index
    }

    /// Get tab index by searching for a matching session name (0-based)
    /// Searches tabs in the first window
    /// - Parameter sessionName: The session name to search for (e.g., tmux session name)
    /// - Returns: Tab index (0-based) if found, nil otherwise
    static func getTabIndexByName(_ sessionName: String) -> Int? {
        guard let descriptor = findMatchingTab(for: sessionName) else {
            return nil
        }
        let index = descriptor.tabIndex - 1
        DebugLog.log("[ITerm2Helper] Found tab index \(index) for '\(sessionName)'")
        return index
    }

    /// Focus session by name/title (for tmux sessions)
    /// Searches all tabs in all windows for a session whose name contains the search term
    /// - Parameter sessionName: The session name to search for (e.g., tmux session name)
    /// - Returns: true if successfully focused
    static func focusSessionByName(_ sessionName: String) -> Bool {
        guard let descriptor = findMatchingTab(for: sessionName) else {
            if let descriptors = listTabDescriptors() {
                let samples = descriptors.prefix(5).map { $0.name }.joined(separator: " | ")
                DebugLog.log("[ITerm2Helper] Name search miss '\(sessionName)'; sampled tabs: \(samples)")
            } else {
                DebugLog.log("[ITerm2Helper] Name search miss '\(sessionName)'; failed to enumerate tabs")
            }
            return false
        }

        if selectTab(windowIndex: descriptor.windowIndex, tabIndex: descriptor.tabIndex) {
            invalidateCache()  // Tab state changed
            DebugLog.log("[ITerm2Helper] Successfully focused session with name '\(sessionName)'")
            return true
        }

        DebugLog.log("[ITerm2Helper] Failed to select matched tab for '\(sessionName)'")
        return false
    }

    static func normalizeNameForMatching(_ value: String) -> String {
        var text = value.lowercased()

        // Drop obvious decorative leading symbols/emoji and normalize separators.
        text = text.replacingOccurrences(
            of: "[^\\p{L}\\p{N}:/._\\-\\s]+",
            with: " ",
            options: .regularExpression
        )
        text = text.replacingOccurrences(
            of: "\\s+",
            with: " ",
            options: .regularExpression
        )
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func tabNameMatches(_ tabName: String, searchTerm: String) -> Bool {
        let normalizedTab = normalizeNameForMatching(tabName)
        let normalizedSearch = normalizeNameForMatching(searchTerm)
        guard !normalizedTab.isEmpty, !normalizedSearch.isEmpty else { return false }

        if normalizedTab.contains(normalizedSearch) {
            return true
        }

        let escaped = NSRegularExpression.escapedPattern(for: normalizedSearch)
        let pattern = "(^|[\\s:/._-])\(escaped)($|[\\s:/._-])"
        return normalizedTab.range(of: pattern, options: .regularExpression) != nil
    }

    private static func findMatchingTab(for searchTerm: String) -> TabDescriptor? {
        guard let descriptors = listTabDescriptors() else {
            return nil
        }
        return descriptors.first { tabNameMatches($0.name, searchTerm: searchTerm) }
    }

    private static func listTabDescriptors() -> [TabDescriptor]? {
        guard isRunning else { return nil }

        // Check cache
        cacheLock.lock()
        if Date().timeIntervalSince(tabDescriptorsCacheTime) < cacheTTL,
           let cached = tabDescriptorsCache {
            cacheLock.unlock()
            DebugLog.log("[ITerm2Helper] Tab descriptors cache hit")
            return cached
        }
        cacheLock.unlock()

        let script = """
            tell application "iTerm"
                try
                    set outText to ""
                    repeat with wi from 1 to count of windows
                        set w to item wi of windows
                        repeat with ti from 1 to count of tabs of w
                            set t to item ti of tabs of w
                            set tabName to ""
                            try
                                set tabName to name of current session of t
                            end try
                            set outText to outText & (wi as string) & tab & (ti as string) & tab & tabName & linefeed
                        end repeat
                    end repeat
                    return outText
                on error errMsg
                    return "error: " & errMsg
                end try
            end tell
            """

        guard let appleScript = NSAppleScript(source: script) else {
            DebugLog.log("[ITerm2Helper] Failed to create AppleScript for tab enumeration")
            return nil
        }

        var error: NSDictionary?
        let result = appleScript.executeAndReturnError(&error)
        if let error = error {
            DebugLog.log("[ITerm2Helper] AppleScript error (tab enumeration): \(error)")
            return nil
        }

        let output = result.stringValue ?? ""
        if output.hasPrefix("error:") {
            DebugLog.log("[ITerm2Helper] Tab enumeration returned error: \(output)")
            return nil
        }

        var descriptors: [TabDescriptor] = []
        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let parts = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 3,
                  let windowIndex = Int(parts[0]),
                  let tabIndex = Int(parts[1]) else {
                continue
            }
            descriptors.append(
                TabDescriptor(
                    windowIndex: windowIndex,
                    tabIndex: tabIndex,
                    name: parts[2]
                )
            )
        }

        // Update cache
        cacheLock.lock()
        tabDescriptorsCache = descriptors
        tabDescriptorsCacheTime = Date()
        cacheLock.unlock()

        return descriptors
    }

    private static func selectTab(windowIndex: Int, tabIndex: Int) -> Bool {
        let script = """
            tell application "iTerm"
                try
                    set w to item \(windowIndex) of windows
                    set t to item \(tabIndex) of tabs of w
                    select t
                    select w
                    activate
                    return "true"
                on error errMsg
                    return "error: " & errMsg
                end try
            end tell
            """

        guard let appleScript = NSAppleScript(source: script) else {
            DebugLog.log("[ITerm2Helper] Failed to create AppleScript for tab selection")
            return false
        }

        var error: NSDictionary?
        let result = appleScript.executeAndReturnError(&error)
        if let error = error {
            DebugLog.log("[ITerm2Helper] AppleScript error (tab selection): \(error)")
            return false
        }
        let resultStr = result.stringValue ?? ""
        if resultStr == "true" {
            return true
        }
        if !resultStr.isEmpty {
            DebugLog.log("[ITerm2Helper] Tab selection failed: \(resultStr)")
        }
        return false
    }
}
