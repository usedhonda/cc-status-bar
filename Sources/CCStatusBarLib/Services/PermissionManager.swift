import AppKit
import ApplicationServices

/// Manages system permissions required for terminal control
enum PermissionManager {

    private static let accessibilityPromptLock = NSLock()
    private static var didRequestAccessibilityPromptThisLaunch = false

    // MARK: - Permission Status

    struct PermissionStatus {
        let accessibility: Bool
        let automationGhostty: Bool?
        let automationITerm2: Bool?
        let automationTerminal: Bool?

        var hasRequiredPermissions: Bool {
            accessibility
        }

        var missingPermissions: [String] {
            var missing: [String] = []
            if !accessibility {
                missing.append("Accessibility")
            }
            return missing
        }
    }

    /// Check all required permissions
    static func checkPermissions() -> PermissionStatus {
        return PermissionStatus(
            accessibility: checkAccessibilityPermission(),
            automationGhostty: nil,  // Checked on-demand
            automationITerm2: nil,
            automationTerminal: nil
        )
    }

    // MARK: - Accessibility Permission

    /// Check if accessibility permission is granted (without prompting)
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

    /// Request accessibility permission at most once per app launch.
    /// Prevents repeated dialogs when focus attempts happen in a loop.
    static func requestAccessibilityPermissionOncePerLaunch() {
        guard !checkAccessibilityPermission() else { return }

        accessibilityPromptLock.lock()
        let shouldPrompt = !didRequestAccessibilityPromptThisLaunch
        if shouldPrompt {
            didRequestAccessibilityPromptThisLaunch = true
        }
        accessibilityPromptLock.unlock()

        if shouldPrompt {
            requestAccessibilityPermission()
            DebugLog.log("[PermissionManager] Requested Accessibility permission prompt (once per launch)")
        } else {
            DebugLog.log("[PermissionManager] Accessibility prompt already requested in this launch, skipping")
        }
    }

    // MARK: - Open System Preferences

    /// Open Accessibility preferences pane
    static func openAccessibilitySettings() {
        // Also trigger the native Accessibility prompt if possible.
        requestAccessibilityPermission()

        let candidates = [
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension",
            "x-apple.systempreferences:com.apple.preference.security?Privacy"
        ]

        if openFirstAvailableURL(candidates, logLabel: "Accessibility settings") {
            return
        }

        // Last resort: open System Settings app directly.
        let systemSettingsPath = "/System/Applications/System Settings.app"
        if NSWorkspace.shared.open(URL(fileURLWithPath: systemSettingsPath)) {
            DebugLog.log("[PermissionManager] Opened System Settings app (fallback)")
        } else {
            DebugLog.log("[PermissionManager] Failed to open Accessibility settings")
        }
    }

    /// Open Privacy & Security overview
    static func openPrivacySettings() {
        let candidates = [
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension",
            "x-apple.systempreferences:com.apple.preference.security?Privacy"
        ]
        if openFirstAvailableURL(candidates, logLabel: "Privacy settings") {
            return
        }

        let systemSettingsPath = "/System/Applications/System Settings.app"
        if NSWorkspace.shared.open(URL(fileURLWithPath: systemSettingsPath)) {
            DebugLog.log("[PermissionManager] Opened System Settings app (fallback)")
        } else {
            DebugLog.log("[PermissionManager] Failed to open Privacy settings")
        }
    }

    /// Try URL candidates in order and open the first one that succeeds.
    @discardableResult
    private static func openFirstAvailableURL(_ candidates: [String], logLabel: String) -> Bool {
        for raw in candidates {
            guard let url = URL(string: raw) else { continue }
            if NSWorkspace.shared.open(url) {
                DebugLog.log("[PermissionManager] Opened \(logLabel): \(raw)")
                return true
            }
        }
        return false
    }

    // MARK: - Diagnostics

    /// Get permission status for diagnostics
    static func diagnosticsReport() -> String {
        var lines: [String] = []
        lines.append("-- Permissions --")
        lines.append("Accessibility: \(checkAccessibilityPermission() ? "Granted" : "NOT GRANTED")")

        // Check running terminals that might need control
        if GhosttyHelper.isRunning {
            lines.append("Ghostty: Running (Accessibility API used)")
        }
        if ITerm2Helper.isRunning {
            lines.append("iTerm2: Running (AppleScript used)")
        }

        return lines.joined(separator: "\n")
    }
}
