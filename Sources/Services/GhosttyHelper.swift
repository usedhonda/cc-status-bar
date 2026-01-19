import AppKit
import Carbon
import ApplicationServices

// MARK: - GhosttyHelper (static API)

enum GhosttyHelper {
    static let bundleIdentifier = "com.mitchellh.ghostty"

    /// Check if Ghostty is running
    static var isRunning: Bool {
        !NSRunningApplication.runningApplications(
            withBundleIdentifier: bundleIdentifier
        ).isEmpty
    }

    /// Get Ghostty's PID
    static var ghosttyPid: pid_t? {
        NSRunningApplication.runningApplications(
            withBundleIdentifier: bundleIdentifier
        ).first?.processIdentifier
    }

    /// Activate Ghostty (bring to front)
    @discardableResult
    static func activate() -> Bool {
        guard let app = NSRunningApplication.runningApplications(
            withBundleIdentifier: bundleIdentifier
        ).first else {
            DebugLog.log("[GhosttyHelper] Ghostty not running")
            return false
        }
        app.activate(options: [.activateIgnoringOtherApps])
        DebugLog.log("[GhosttyHelper] Activated Ghostty")
        return true
    }

    // MARK: - Title Matching

    /// Check if tab title matches target session name
    /// Uses strict matching to avoid false positives (e.g., "t" matching "status")
    private static func titleMatches(_ title: String, target: String) -> Bool {
        let lowTitle = title.lowercased()
        let lowTarget = target.lowercased()

        // 1. Exact match
        if lowTitle == lowTarget {
            return true
        }

        // 2. Prefix match with delimiter (e.g., "project:branch" matches "project")
        if lowTitle.hasPrefix(lowTarget + ":") || lowTitle.hasPrefix(lowTarget + " ") {
            return true
        }

        // 3. Component match (split by ":" and check first component)
        let titleComponents = lowTitle.split(separator: ":")
        if let firstComponent = titleComponents.first, String(firstComponent) == lowTarget {
            return true
        }

        // 4. For longer targets (4+ chars), allow contains match
        if lowTarget.count >= 4 && lowTitle.contains(lowTarget) {
            return true
        }

        return false
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

                if titleMatches(title, target: targetTitle) {
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

            if titleMatches(title, target: targetTitle) {
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

    /// Recursively find an element with the specified role (with depth limit to prevent stack overflow)
    private static func findElement(in parent: AXUIElement, role targetRole: String, depth: Int = 0) -> AXUIElement? {
        // Prevent stack overflow - limit recursion depth
        guard depth < 20 else { return nil }

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

            // Recurse with incremented depth
            if let found = findElement(in: child, role: targetRole, depth: depth + 1) {
                return found
            }
        }

        return nil
    }

    // MARK: - Tab Index Operations (Bind-on-start)

    /// Get the title of the currently selected tab
    /// Returns nil if no tab is selected or error occurs
    static func getSelectedTabTitle() -> String? {
        guard let pid = ghosttyPid else {
            return nil
        }

        let appElement = AXUIElementCreateApplication(pid)

        var windowsValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsValue) == .success,
              let windows = windowsValue as? [AXUIElement],
              let window = windows.first else {
            return nil
        }

        guard let tabGroup = findElement(in: window, role: "AXTabGroup") else {
            return nil
        }

        var childrenValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(tabGroup, kAXChildrenAttribute as CFString, &childrenValue) == .success,
              let tabs = childrenValue as? [AXUIElement] else {
            return nil
        }

        // Find the selected tab (AXValue == 1) and get its title
        for tab in tabs {
            var valueRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(tab, kAXValueAttribute as CFString, &valueRef) == .success,
               let value = valueRef as? NSNumber,
               value.intValue == 1 {
                // Get the title
                var titleRef: CFTypeRef?
                if AXUIElementCopyAttributeValue(tab, kAXTitleAttribute as CFString, &titleRef) == .success,
                   let title = titleRef as? String {
                    DebugLog.log("[GhosttyHelper] Selected tab title: '\(title)'")
                    return title
                }
            }
        }

        return nil
    }

    /// Get the index of the currently selected tab (0-based)
    /// Returns nil if no tab is selected or error occurs
    static func getSelectedTabIndex() -> Int? {
        guard let pid = ghosttyPid else {
            DebugLog.log("[GhosttyHelper] Ghostty not running")
            return nil
        }

        let appElement = AXUIElementCreateApplication(pid)

        var windowsValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsValue) == .success,
              let windows = windowsValue as? [AXUIElement],
              let window = windows.first else {
            DebugLog.log("[GhosttyHelper] Could not get windows")
            return nil
        }

        guard let tabGroup = findElement(in: window, role: "AXTabGroup") else {
            DebugLog.log("[GhosttyHelper] Could not find AXTabGroup")
            return nil
        }

        var childrenValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(tabGroup, kAXChildrenAttribute as CFString, &childrenValue) == .success,
              let tabs = childrenValue as? [AXUIElement] else {
            DebugLog.log("[GhosttyHelper] Could not get tabs")
            return nil
        }

        // Find the selected tab (AXValue == 1)
        for (index, tab) in tabs.enumerated() {
            var valueRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(tab, kAXValueAttribute as CFString, &valueRef) == .success,
               let value = valueRef as? NSNumber,
               value.intValue == 1 {
                DebugLog.log("[GhosttyHelper] Selected tab index: \(index)")
                return index
            }
        }

        DebugLog.log("[GhosttyHelper] No selected tab found")
        return nil
    }

    /// Focus a tab by its index (0-based)
    /// Returns true if successful
    static func focusTabByIndex(_ index: Int) -> Bool {
        guard let pid = ghosttyPid else {
            DebugLog.log("[GhosttyHelper] Ghostty not running")
            return false
        }

        // Activate Ghostty first
        activateGhostty(pid: pid)

        let appElement = AXUIElementCreateApplication(pid)

        var windowsValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsValue) == .success,
              let windows = windowsValue as? [AXUIElement],
              let window = windows.first else {
            DebugLog.log("[GhosttyHelper] Could not get windows")
            return false
        }

        guard let tabGroup = findElement(in: window, role: "AXTabGroup") else {
            DebugLog.log("[GhosttyHelper] Could not find AXTabGroup")
            return false
        }

        var childrenValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(tabGroup, kAXChildrenAttribute as CFString, &childrenValue) == .success,
              let tabs = childrenValue as? [AXUIElement] else {
            DebugLog.log("[GhosttyHelper] Could not get tabs")
            return false
        }

        guard index >= 0 && index < tabs.count else {
            DebugLog.log("[GhosttyHelper] Tab index \(index) out of range (0..<\(tabs.count))")
            return false
        }

        let tab = tabs[index]
        let pressResult = AXUIElementPerformAction(tab, kAXPressAction as CFString)
        if pressResult == .success {
            DebugLog.log("[GhosttyHelper] Focused tab at index \(index)")
            return true
        } else {
            DebugLog.log("[GhosttyHelper] Failed to focus tab at index \(index): \(pressResult.rawValue)")
            return false
        }
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

    /// Dump all AX attributes for a tab element (for investigation)
    static func dumpTabAttributes() {
        guard let pid = ghosttyPid else {
            DebugLog.log("[GhosttyHelper] Ghostty not running")
            return
        }

        let appElement = AXUIElementCreateApplication(pid)

        var windowsValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsValue) == .success,
              let windows = windowsValue as? [AXUIElement],
              let window = windows.first else {
            DebugLog.log("[GhosttyHelper] Could not get windows")
            return
        }

        // Find tab group and dump attributes
        if let tabGroup = findElement(in: window, role: "AXTabGroup") {
            var childrenValue: CFTypeRef?
            if AXUIElementCopyAttributeValue(tabGroup, kAXChildrenAttribute as CFString, &childrenValue) == .success,
               let tabs = childrenValue as? [AXUIElement] {
                for (i, tab) in tabs.enumerated() {
                    DebugLog.log("[GhosttyHelper] === Tab \(i) attributes ===")
                    dumpAllAttributes(of: tab)
                }
            }
        }

        // Also dump window attributes
        DebugLog.log("[GhosttyHelper] === Window attributes ===")
        dumpAllAttributes(of: window)
    }

    /// Dump all attributes of an AX element
    private static func dumpAllAttributes(of element: AXUIElement) {
        var namesRef: CFArray?
        let result = AXUIElementCopyAttributeNames(element, &namesRef)
        guard result == .success, let names = namesRef as? [String] else {
            DebugLog.log("[GhosttyHelper] Could not get attribute names")
            return
        }

        for name in names {
            var valueRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, name as CFString, &valueRef) == .success {
                let valueStr = describeValue(valueRef)
                DebugLog.log("[GhosttyHelper]   \(name) = \(valueStr)")
            }
        }
    }

    /// Describe a CFTypeRef value for logging
    private static func describeValue(_ value: CFTypeRef?) -> String {
        guard let value = value else { return "nil" }

        if let str = value as? String {
            return "\"\(str)\""
        } else if let num = value as? NSNumber {
            return "\(num)"
        } else if let url = value as? URL {
            return "URL(\(url.absoluteString))"
        } else if let arr = value as? [Any] {
            return "Array(\(arr.count) items)"
        } else if CFGetTypeID(value) == AXUIElementGetTypeID() {
            var roleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(value as! AXUIElement, kAXRoleAttribute as CFString, &roleRef)
            let role = roleRef as? String ?? "?"
            return "AXUIElement(\(role))"
        } else {
            return "\(type(of: value))"
        }
    }

    /// Check if any tab title matches the given session name
    static func hasTabWithTitle(_ searchString: String) -> Bool {
        return getAllTabTitles().contains { titleMatches($0, target: searchString) }
    }

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
