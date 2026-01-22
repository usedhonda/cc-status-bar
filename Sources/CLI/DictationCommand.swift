import ArgumentParser
import Foundation
import Cocoa

/// Toggle macOS dictation for Stream Deck integration.
///
/// # Implementation History (macOS Sequoia 15.x)
///
/// Multiple approaches were tested before settling on the current implementation:
///
/// | Method | Result | Reason |
/// |--------|--------|--------|
/// | `notifyutil` | ❌ | Sequoia blocks non-privileged process notifications |
/// | CGEvent (Fn×2) | ❌ | Fn key is `flagsChanged`, not `keyDown` - CGEvent can't simulate |
/// | AXStartDictation | ✅ | Works on most apps (recommended by Gemini) |
/// | AppleScript menu | ✅ | Reliable fallback for apps that don't support AXAction |
///
/// # Known Limitations
/// - Secure Input fields (passwords) block all programmatic dictation (macOS security)
/// - Some apps may not support AXStartDictation action
///
/// # Related Documentation
/// - `docs/STREAMDECK.md` - Troubleshooting section
/// - `docs/ask/gemini/9736101c5689c45e/029-*` - AI discussion on CGEvent Fn key
struct DictationCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "dictation",
        abstract: "Toggle macOS dictation (via AXStartDictation action)"
    )

    func run() {
        // Primary: AXStartDictation accessibility action
        // Recommended by Gemini as "bulletproof" solution for Sequoia
        if toggleDictationWithAXAction() {
            print("Dictation toggled")
            return
        }

        // Fallback: AppleScript via Edit menu
        printError("AXAction failed, trying AppleScript fallback...")
        if toggleDictationWithAppleScript() {
            print("Dictation toggled (via AppleScript)")
        } else {
            printError("Failed to toggle dictation")
        }
    }

    /// Toggle dictation using AXStartDictation accessibility action
    /// Returns true if successful
    private func toggleDictationWithAXAction() -> Bool {
        // Get the frontmost application
        guard let frontApp = NSWorkspace.shared.frontmostApplication else {
            printError("No frontmost application")
            return false
        }

        let appElement = AXUIElementCreateApplication(frontApp.processIdentifier)

        // Perform the AXStartDictation action directly
        let result = AXUIElementPerformAction(appElement, "AXStartDictation" as CFString)

        return result == .success
    }

    /// Toggle dictation using AppleScript (menu-based fallback)
    /// Returns true if successful
    private func toggleDictationWithAppleScript() -> Bool {
        // Try to click "Start Dictation" or "Stop Dictation" menu item by name
        let script = """
        tell application "System Events"
            set frontApp to first process whose frontmost is true
            set editMenus to {"Edit", "編集"}
            set dictationItems to {"Start Dictation", "Start Dictation…", "Stop Dictation", "Stop Dictation…", "音声入力を開始", "音声入力を開始…", "音声入力を停止", "音声入力を停止…"}

            repeat with editName in editMenus
                try
                    set editMenu to menu bar item editName of menu bar 1 of frontApp
                    set theMenu to menu 1 of editMenu
                    repeat with itemName in dictationItems
                        try
                            click menu item itemName of theMenu
                            return
                        end try
                    end repeat
                end try
            end repeat
        end tell
        """

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-e", script]

        do {
            try task.run()
            task.waitUntilExit()
            return task.terminationStatus == 0
        } catch {
            return false
        }
    }

    private func printError(_ message: String) {
        FileHandle.standardError.write(Data("Error: \(message)\n".utf8))
    }
}
