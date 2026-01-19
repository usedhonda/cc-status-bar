import AppKit
import Combine

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var sessionObserver: SessionObserver!
    private var cancellables = Set<AnyCancellable>()

    @MainActor
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Run setup check (handles first run, app move, repair)
        SetupManager.shared.checkAndRunSetup()

        // Initialize notification manager and request permission
        if AppSettings.notificationsEnabled {
            NotificationManager.shared.requestPermission()
        }

        // Initialize session observer
        sessionObserver = SessionObserver()

        // Create status item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        // Subscribe to session changes
        sessionObserver.$sessions
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateStatusTitle()
                self?.rebuildMenu()
            }
            .store(in: &cancellables)

        // Set initial state
        updateStatusTitle()
        rebuildMenu()
    }

    // MARK: - Status Title

    @MainActor
    private func updateStatusTitle() {
        guard let button = statusItem.button else { return }

        let attributed = NSMutableAttributedString()

        // Color and count should match
        let ccColor: NSColor
        let count: Int

        if sessionObserver.waitingCount > 0 {
            ccColor = .systemYellow
            count = sessionObserver.waitingCount  // Yellow = waiting count
        } else if sessionObserver.runningCount > 0 {
            ccColor = .systemGreen
            count = sessionObserver.runningCount  // Green = running count
        } else {
            ccColor = .white
            count = 0
        }

        // "CC" with color
        let ccAttr = NSAttributedString(
            string: "CC",
            attributes: [
                .foregroundColor: ccColor,
                .font: NSFont.systemFont(ofSize: 13, weight: .bold)
            ]
        )
        attributed.append(ccAttr)

        // Add count if > 0
        if count > 0 {
            let countAttr = NSAttributedString(
                string: " \(count)",
                attributes: [
                    .foregroundColor: NSColor.white,
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium)
                ]
            )
            attributed.append(countAttr)
        }

        button.attributedTitle = attributed
    }

    // MARK: - Menu Building

    @MainActor
    private func rebuildMenu() {
        let menu = NSMenu()

        if sessionObserver.sessions.isEmpty {
            let emptyItem = NSMenuItem(title: "No active sessions", action: nil, keyEquivalent: "")
            emptyItem.isEnabled = false
            menu.addItem(emptyItem)
        } else {
            // Header
            let header = NSMenuItem(
                title: "Sessions (\(sessionObserver.sessions.count))",
                action: nil,
                keyEquivalent: ""
            )
            header.isEnabled = false
            menu.addItem(header)
            menu.addItem(NSMenuItem.separator())

            // Session list
            for session in sessionObserver.sessions {
                menu.addItem(createSessionMenuItem(session))
            }
        }

        menu.addItem(NSMenuItem.separator())

        // Settings submenu
        let settingsItem = NSMenuItem(title: "Settings", action: nil, keyEquivalent: "")
        settingsItem.submenu = createSettingsMenu()
        menu.addItem(settingsItem)

        // Copy Diagnostics
        let diagnosticsItem = NSMenuItem(
            title: "Copy Diagnostics",
            action: #selector(copyDiagnostics),
            keyEquivalent: ""
        )
        diagnosticsItem.target = self
        menu.addItem(diagnosticsItem)

        // Debug: Dump Ghostty AX Attributes
        let dumpAXItem = NSMenuItem(
            title: "Debug: Dump Ghostty AX",
            action: #selector(dumpGhosttyAX),
            keyEquivalent: ""
        )
        dumpAXItem.target = self
        menu.addItem(dumpAXItem)

        menu.addItem(NSMenuItem(
            title: "Quit",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        ))

        statusItem.menu = menu
    }

    @objc private func copyDiagnostics() {
        let diagnostics = DebugLog.collectDiagnostics()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(diagnostics, forType: .string)
    }

    @objc private func dumpGhosttyAX() {
        DebugLog.log("[AppDelegate] === Dumping Ghostty AX Attributes ===")
        GhosttyHelper.dumpTabAttributes()
        DebugLog.log("[AppDelegate] === Dump complete. Check debug.log ===")

        // Show alert to user
        let alert = NSAlert()
        alert.messageText = "AX Attributes Dumped"
        alert.informativeText = "Check ~/Library/Logs/CCStatusBar/debug.log"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    // MARK: - Settings Menu

    private func createSettingsMenu() -> NSMenu {
        let menu = NSMenu()

        // Launch at Login
        let launchItem = NSMenuItem(
            title: "Launch at Login",
            action: #selector(toggleLaunchAtLogin(_:)),
            keyEquivalent: ""
        )
        launchItem.target = self
        launchItem.state = LaunchManager.isEnabled ? .on : .off
        menu.addItem(launchItem)

        // Notifications
        let notifyItem = NSMenuItem(
            title: "Notifications",
            action: #selector(toggleNotifications(_:)),
            keyEquivalent: ""
        )
        notifyItem.target = self
        notifyItem.state = AppSettings.notificationsEnabled ? .on : .off
        menu.addItem(notifyItem)

        // Session Timeout submenu
        let timeoutItem = NSMenuItem(title: "Session Timeout", action: nil, keyEquivalent: "")
        timeoutItem.submenu = createTimeoutMenu()
        menu.addItem(timeoutItem)

        menu.addItem(NSMenuItem.separator())

        // Reconfigure Hooks
        let reconfigureItem = NSMenuItem(
            title: "Reconfigure Hooks...",
            action: #selector(reconfigureHooks),
            keyEquivalent: ""
        )
        reconfigureItem.target = self
        menu.addItem(reconfigureItem)

        return menu
    }

    private func createTimeoutMenu() -> NSMenu {
        let menu = NSMenu()
        let currentTimeout = AppSettings.sessionTimeoutMinutes
        let options: [(String, Int)] = [
            ("15 minutes", 15),
            ("30 minutes", 30),
            ("60 minutes", 60),
            ("Never", 0)
        ]

        for (title, minutes) in options {
            let item = NSMenuItem(
                title: title,
                action: #selector(setSessionTimeout(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.tag = minutes
            item.state = (currentTimeout == minutes || (minutes == 30 && currentTimeout == 30)) ? .on : .off
            // Handle "Never" case: currentTimeout == 0 means Never
            if minutes == 0 && currentTimeout == 0 {
                item.state = .on
            } else if minutes == currentTimeout {
                item.state = .on
            } else {
                item.state = .off
            }
            menu.addItem(item)
        }

        return menu
    }

    @objc private func toggleLaunchAtLogin(_ sender: NSMenuItem) {
        do {
            let newState = !LaunchManager.isEnabled
            try LaunchManager.setEnabled(newState)
            sender.state = newState ? .on : .off
        } catch {
            DebugLog.log("[AppDelegate] Failed to toggle launch at login: \(error)")
            showAlert(
                title: "Launch at Login Error",
                message: "Failed to change login item setting: \(error.localizedDescription)"
            )
        }
    }

    @objc private func toggleNotifications(_ sender: NSMenuItem) {
        let newState = !AppSettings.notificationsEnabled
        AppSettings.notificationsEnabled = newState
        sender.state = newState ? .on : .off

        if newState {
            NotificationManager.shared.requestPermission()
        }
    }

    @MainActor @objc private func setSessionTimeout(_ sender: NSMenuItem) {
        AppSettings.sessionTimeoutMinutes = sender.tag
        DebugLog.log("[AppDelegate] Session timeout set to: \(sender.tag) minutes")
        rebuildMenu()  // Update checkmark display
    }

    @objc private func reconfigureHooks() {
        Task { @MainActor in
            SetupManager.shared.runSetup(force: true)
        }
    }

    private func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func createSessionMenuItem(_ session: Session) -> NSMenuItem {
        let item = NSMenuItem(
            title: "",
            action: #selector(sessionItemClicked(_:)),
            keyEquivalent: ""
        )
        item.target = self
        item.representedObject = session

        let attributed = NSMutableAttributedString()

        // Symbol color
        let symbolColor: NSColor
        switch session.status {
        case .running:
            symbolColor = .systemGreen
        case .waitingInput:
            symbolColor = .systemYellow
        case .stopped:
            symbolColor = .systemGray
        }

        // Line 1: ● project-name
        let symbolAttr = NSAttributedString(
            string: "\(session.status.symbol) ",
            attributes: [
                .foregroundColor: symbolColor,
                .font: NSFont.systemFont(ofSize: 13)
            ]
        )
        attributed.append(symbolAttr)

        let nameAttr = NSAttributedString(
            string: session.projectName,
            attributes: [
                .font: NSFont.boldSystemFont(ofSize: 13)
            ]
        )
        attributed.append(nameAttr)

        // Line 2:   ~/path • Status • 5s ago
        let relativeTime = formatRelativeTime(session.updatedAt)
        let detailText = "\n   \(session.displayPath) • \(session.status.label) • \(relativeTime)"
        let detailAttr = NSAttributedString(
            string: detailText,
            attributes: [
                .foregroundColor: NSColor.secondaryLabelColor,
                .font: NSFont.systemFont(ofSize: 11)
            ]
        )
        attributed.append(detailAttr)

        item.attributedTitle = attributed

        return item
    }

    private func formatRelativeTime(_ date: Date) -> String {
        let seconds = Int(-date.timeIntervalSinceNow)
        if seconds < 60 {
            return "\(seconds)s ago"
        } else if seconds < 3600 {
            return "\(seconds / 60)m ago"
        } else {
            return "\(seconds / 3600)h ago"
        }
    }

    @objc private func sessionItemClicked(_ sender: NSMenuItem) {
        guard let session = sender.representedObject as? Session else { return }
        focusTerminal(for: session)
    }

    // MARK: - Terminal Focus

    private func focusTerminal(for session: Session) {
        let projectName = session.projectName

        // 1. Try tmux pane selection if TTY is available
        var tmuxSessionName: String?
        if let tty = session.tty, let paneInfo = TmuxHelper.getPaneInfo(for: tty) {
            _ = TmuxHelper.selectPane(paneInfo)
            tmuxSessionName = paneInfo.session
            DebugLog.log("[AppDelegate] Selected tmux pane in session '\(paneInfo.session)'")
        }

        // 2. Try iTerm2 TTY-based search (most reliable)
        if ITerm2Helper.isRunning, let tty = session.tty {
            if ITerm2Helper.focusSessionByTTY(tty) {
                DebugLog.log("[AppDelegate] Focused iTerm2 session by TTY '\(tty)'")
                return
            }
        }

        // 3. Try Ghostty tab focus
        if GhosttyHelper.isRunning {
            // 3a. Try Bind-on-start tab index (for non-tmux sessions)
            if let tabIndex = session.ghosttyTabIndex {
                if GhosttyHelper.focusTabByIndex(tabIndex) {
                    DebugLog.log("[AppDelegate] Focused Ghostty tab by index \(tabIndex)")
                    return
                }
            }

            // 3b. Try title-based search (tmux session name or project name)
            let searchTerm = tmuxSessionName ?? projectName
            if GhosttyHelper.focusSession(searchTerm) {
                DebugLog.log("[AppDelegate] Focused Ghostty tab for '\(searchTerm)'")
                return
            }

            // If tmux session name didn't work, try project name as fallback
            if tmuxSessionName != nil && GhosttyHelper.focusSession(projectName) {
                DebugLog.log("[AppDelegate] Focused Ghostty tab for project '\(projectName)'")
                return
            }
        }

        // 4. Fallback: just activate terminal app
        DebugLog.log("[AppDelegate] Fallback: activating terminal app")
        activateTerminalApp()
    }

    private func activateTerminalApp() {
        // Find running terminal app
        let findScript = """
            tell application "System Events"
                if exists process "Ghostty" then
                    return "Ghostty"
                else if exists process "iTerm2" then
                    return "iTerm"
                else if exists process "Terminal" then
                    return "Terminal"
                end if
            end tell
            return ""
            """

        var appName: String?
        if let appleScript = NSAppleScript(source: findScript) {
            var error: NSDictionary?
            if let result = appleScript.executeAndReturnError(&error).stringValue {
                appName = result.isEmpty ? nil : result
            }
            if let error = error {
                DebugLog.log("[AppDelegate] AppleScript find error: \(error)")
            }
        }

        // Activate the found app
        guard let app = appName else {
            DebugLog.log("[AppDelegate] No terminal app found")
            return
        }

        let activateScript = "tell application \"\(app)\" to activate"
        if let appleScript = NSAppleScript(source: activateScript) {
            var error: NSDictionary?
            appleScript.executeAndReturnError(&error)
            if let error = error {
                DebugLog.log("[AppDelegate] AppleScript activate error: \(error)")
            }
        }
    }
}
