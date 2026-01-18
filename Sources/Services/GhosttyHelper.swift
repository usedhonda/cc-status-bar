import AppKit
import Carbon
import ApplicationServices

enum GhosttyHelper {
    /// Check if Ghostty is running
    static var isRunning: Bool {
        !NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.mitchellh.ghostty"
        ).isEmpty
    }

    /// Get Ghostty's PID
    static var ghosttyPid: pid_t? {
        NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.mitchellh.ghostty"
        ).first?.processIdentifier
    }

    // MARK: - Accessibility API based tab control (Gemini recommended)

    /// Focus the tab containing the target tmux session using Accessibility API
    /// This method searches tabs by title and clicks directly using AXPress
    static func focusSession(_ targetSession: String) -> Bool {
        guard let pid = ghosttyPid else {
            DebugLog.log("[GhosttyHelper] Ghostty not running")
            return false
        }

        // Activate Ghostty first
        activateGhostty(pid: pid)

        // Try to find and click the tab with matching title
        if focusTabByTitle(targetSession, pid: pid) {
            DebugLog.log("[GhosttyHelper] Successfully focused tab for session '\(targetSession)'")
            return true
        }

        DebugLog.log("[GhosttyHelper] Could not find tab for session '\(targetSession)'")
        return false
    }

    /// Check if accessibility permission is granted
    static func checkAccessibilityPermission() -> Bool {
        let checkOptPrompt = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [checkOptPrompt: false] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// Request accessibility permission (shows system dialog)
    static func requestAccessibilityPermission() {
        let checkOptPrompt = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [checkOptPrompt: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    /// Find and click a tab by its title using Accessibility API
    private static func focusTabByTitle(_ targetTitle: String, pid: pid_t) -> Bool {
        // Check accessibility permission first
        if !checkAccessibilityPermission() {
            DebugLog.log("[GhosttyHelper] Accessibility permission not granted")
            requestAccessibilityPermission()
            return false
        }

        let appElement = AXUIElementCreateApplication(pid)

        // Get the focused window
        var windowValue: CFTypeRef?
        let windowResult = AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedWindowAttribute as CFString,
            &windowValue
        )

        // If no focused window, try getting windows array
        var window: AXUIElement?
        if windowResult == .success {
            window = (windowValue as! AXUIElement)
        } else {
            var windowsValue: CFTypeRef?
            if AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsValue) == .success,
               let windows = windowsValue as? [AXUIElement],
               let firstWindow = windows.first {
                window = firstWindow
            }
        }

        guard let targetWindow = window else {
            DebugLog.log("[GhosttyHelper] Could not get Ghostty window")
            return false
        }

        // Find the tab group in the window
        guard let tabGroup = findElement(in: targetWindow, role: "AXTabGroup") else {
            DebugLog.log("[GhosttyHelper] Could not find AXTabGroup in window")
            // Try alternative: look for toolbar or other container
            return focusTabByTitleAlternative(targetTitle, window: targetWindow)
        }

        // Get tabs from the tab group
        var childrenValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(tabGroup, kAXChildrenAttribute as CFString, &childrenValue) == .success,
              let tabs = childrenValue as? [AXUIElement] else {
            DebugLog.log("[GhosttyHelper] Could not get tabs from AXTabGroup")
            return false
        }

        DebugLog.log("[GhosttyHelper] Found \(tabs.count) tabs in AXTabGroup")

        // Search for the tab with matching title
        for (index, tab) in tabs.enumerated() {
            var titleValue: CFTypeRef?
            if AXUIElementCopyAttributeValue(tab, kAXTitleAttribute as CFString, &titleValue) == .success,
               let title = titleValue as? String {
                DebugLog.log("[GhosttyHelper] Tab \(index + 1): '\(title)'")

                if title.contains(targetTitle) {
                    // Found it! Perform AXPress action to click the tab
                    let pressResult = AXUIElementPerformAction(tab, kAXPressAction as CFString)
                    if pressResult == .success {
                        DebugLog.log("[GhosttyHelper] Pressed tab \(index + 1) with title '\(title)'")
                        return true
                    } else {
                        DebugLog.log("[GhosttyHelper] AXPress failed with error: \(pressResult.rawValue)")
                    }
                }
            }
        }

        return false
    }

    /// Alternative method: search through all UI elements for tab-like things
    private static func focusTabByTitleAlternative(_ targetTitle: String, window: AXUIElement) -> Bool {
        // Get all children recursively and look for elements with matching title
        var allTabs: [(element: AXUIElement, title: String, role: String)] = []
        collectTabElements(from: window, into: &allTabs)

        DebugLog.log("[GhosttyHelper] Alternative search found \(allTabs.count) tab-like elements")

        for (element, title, role) in allTabs {
            DebugLog.log("[GhosttyHelper] Element: role=\(role), title='\(title)'")

            if title.contains(targetTitle) {
                let pressResult = AXUIElementPerformAction(element, kAXPressAction as CFString)
                if pressResult == .success {
                    DebugLog.log("[GhosttyHelper] Pressed element with title '\(title)'")
                    return true
                }
            }
        }

        return false
    }

    /// Recursively collect tab-like elements (AXRadioButton, AXButton with titles)
    private static func collectTabElements(
        from element: AXUIElement,
        into results: inout [(element: AXUIElement, title: String, role: String)]
    ) {
        var roleValue: CFTypeRef?
        var titleValue: CFTypeRef?

        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleValue)
        AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &titleValue)

        let role = roleValue as? String ?? ""
        let title = titleValue as? String ?? ""

        // Tab elements are typically AXRadioButton or AXButton in a tab group
        if (role == "AXRadioButton" || role == "AXButton") && !title.isEmpty {
            results.append((element, title, role))
        }

        // Recurse into children
        var childrenValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenValue) == .success,
           let children = childrenValue as? [AXUIElement] {
            for child in children {
                collectTabElements(from: child, into: &results)
            }
        }
    }

    /// Recursively find an element with the specified role
    private static func findElement(in parent: AXUIElement, role targetRole: String) -> AXUIElement? {
        var childrenValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(parent, kAXChildrenAttribute as CFString, &childrenValue) == .success,
              let children = childrenValue as? [AXUIElement] else {
            return nil
        }

        for child in children {
            var roleValue: CFTypeRef?
            AXUIElementCopyAttributeValue(child, kAXRoleAttribute as CFString, &roleValue)

            if let role = roleValue as? String, role == targetRole {
                return child
            }

            // Recurse
            if let found = findElement(in: child, role: targetRole) {
                return found
            }
        }

        return nil
    }

    // MARK: - Activation

    /// Activate Ghostty using NSRunningApplication
    static func activateGhostty(pid: pid_t) {
        if let app = NSRunningApplication(processIdentifier: pid) {
            app.activate(options: [.activateIgnoringOtherApps])
            DebugLog.log("[GhosttyHelper] Activated Ghostty (PID: \(pid))")
        }
    }

    // MARK: - Debug helpers

    /// Get all tab titles for debugging
    static func getAllTabTitles() -> [String] {
        guard let pid = ghosttyPid else { return [] }

        let appElement = AXUIElementCreateApplication(pid)

        var windowsValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsValue) == .success,
              let windows = windowsValue as? [AXUIElement],
              let window = windows.first else {
            return []
        }

        guard let tabGroup = findElement(in: window, role: "AXTabGroup") else {
            return []
        }

        var childrenValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(tabGroup, kAXChildrenAttribute as CFString, &childrenValue) == .success,
              let tabs = childrenValue as? [AXUIElement] else {
            return []
        }

        var titles: [String] = []
        for tab in tabs {
            var titleValue: CFTypeRef?
            if AXUIElementCopyAttributeValue(tab, kAXTitleAttribute as CFString, &titleValue) == .success,
               let title = titleValue as? String {
                titles.append(title)
            }
        }

        return titles
    }

    /// Debug: Print Ghostty's UI hierarchy
    static func debugPrintUIHierarchy() {
        guard let pid = ghosttyPid else {
            DebugLog.log("[GhosttyHelper] Ghostty not running")
            return
        }

        let appElement = AXUIElementCreateApplication(pid)

        var windowsValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsValue) == .success,
              let windows = windowsValue as? [AXUIElement] else {
            DebugLog.log("[GhosttyHelper] Could not get windows")
            return
        }

        for (i, window) in windows.enumerated() {
            var titleValue: CFTypeRef?
            AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleValue)
            let title = titleValue as? String ?? "(no title)"
            DebugLog.log("[GhosttyHelper] Window \(i): '\(title)'")

            printElementHierarchy(window, indent: 2, maxDepth: 5)
        }
    }

    private static func printElementHierarchy(_ element: AXUIElement, indent: Int, maxDepth: Int) {
        guard maxDepth > 0 else { return }

        var roleValue: CFTypeRef?
        var titleValue: CFTypeRef?
        var descValue: CFTypeRef?

        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleValue)
        AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &titleValue)
        AXUIElementCopyAttributeValue(element, kAXDescriptionAttribute as CFString, &descValue)

        let role = roleValue as? String ?? "?"
        let title = titleValue as? String ?? ""
        let desc = descValue as? String ?? ""

        let prefix = String(repeating: " ", count: indent)
        DebugLog.log("\(prefix)[\(role)] title='\(title)' desc='\(desc)'")

        var childrenValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenValue) == .success,
           let children = childrenValue as? [AXUIElement] {
            for child in children {
                printElementHierarchy(child, indent: indent + 2, maxDepth: maxDepth - 1)
            }
        }
    }
}
