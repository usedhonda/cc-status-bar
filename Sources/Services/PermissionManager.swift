import AppKit
import ApplicationServices

/// Manages system permissions required for terminal control
enum PermissionManager {

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

    // MARK: - Open System Preferences

    /// Open Accessibility preferences pane
    static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
            DebugLog.log("[PermissionManager] Opened Accessibility settings")
        }
    }

    /// Open Privacy & Security overview
    static func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy") {
            NSWorkspace.shared.open(url)
            DebugLog.log("[PermissionManager] Opened Privacy settings")
        }
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
