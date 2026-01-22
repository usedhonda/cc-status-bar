import Foundation
import SwiftUI
import AppKit
import ArgumentParser
import CCStatusBarLib

// CLI Commands
struct CCStatusBarCLI: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "CCStatusBar",
        abstract: "CC Status Bar - Claude Code session monitor",
        version: "1.0.0",
        subcommands: [HookCommand.self, SetupCommand.self, ListCommand.self, EmitCommand.self, FocusCommand.self, DictationCommand.self]
    )
}

// Check if we have real CLI arguments (not system args like -psn_)
let cliCommands = ["hook", "setup", "list", "emit", "focus", "dictation", "--help", "-h", "--version"]
let hasCliCommand = CommandLine.arguments.dropFirst().contains { arg in
    cliCommands.contains(arg) || cliCommands.contains(where: { arg.hasPrefix($0) })
}

// Hold AppDelegate globally (weak app.delegate alone would get deallocated)
var appDelegateHolder: AppDelegate?

if hasCliCommand {
    CCStatusBarCLI.main()
} else {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)

    // Initialize NotificationManager before app.run() (Gemini's advice)
    // This ensures the delegate is set up before any notifications are sent
    _ = NotificationManager.shared

    let delegate = AppDelegate()
    appDelegateHolder = delegate
    app.delegate = delegate
    app.run()
}
