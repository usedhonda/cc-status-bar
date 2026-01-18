import Foundation
import SwiftUI
import AppKit
import ArgumentParser

// CLI Commands
struct CCStatusBarCLI: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "CCStatusBar",
        abstract: "CC Status Bar - Claude Code session monitor",
        version: "1.0.0",
        subcommands: [HookCommand.self, SetupCommand.self, ListCommand.self]
    )
}

// Check if we have real CLI arguments (not system args like -psn_)
let cliCommands = ["hook", "setup", "list", "--help", "-h", "--version"]
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
    let delegate = AppDelegate()
    appDelegateHolder = delegate
    app.delegate = delegate
    app.run()
}
