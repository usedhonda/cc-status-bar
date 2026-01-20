import AppKit
import Combine

class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var sessionObserver: SessionObserver!
    private var cancellables = Set<AnyCancellable>()
    private var isMenuOpen = false

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

        // Watch for terminal app activation to auto-acknowledge sessions
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(terminalDidActivate(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )

        // Watch for notification click to acknowledge session
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAcknowledgeSession(_:)),
            name: .acknowledgeSession,
            object: nil
        )
    }

    // MARK: - Status Title

    @MainActor
    private func updateStatusTitle() {
        guard let button = statusItem.button else { return }

        let attributed = NSMutableAttributedString()

        let redCount = sessionObserver.unacknowledgedRedCount
        let yellowCount = sessionObserver.unacknowledgedYellowCount
        let greenCount = sessionObserver.displayedGreenCount
        let totalCount = redCount + yellowCount + greenCount

        // "CC" color: red > yellow > green > white priority
        let ccColor: NSColor
        if redCount > 0 {
            ccColor = .systemRed
        } else if yellowCount > 0 {
            ccColor = .systemYellow
        } else if greenCount > 0 {
            ccColor = .systemGreen
        } else {
            ccColor = .white
        }

        // No spinner in menu bar - just static "CC"

        // "CC" with color
        let ccAttr = NSAttributedString(
            string: "CC",
            attributes: [
                .foregroundColor: ccColor,
                .font: NSFont.systemFont(ofSize: 13, weight: .bold)
            ]
        )
        attributed.append(ccAttr)

        // Count display format
        let font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium)

        if redCount > 0 {
            // Red exists: " 1/5" (red count in red, /total in white)
            attributed.append(NSAttributedString(string: " "))
            attributed.append(NSAttributedString(
                string: "\(redCount)",
                attributes: [.foregroundColor: NSColor.systemRed, .font: font]
            ))
            if yellowCount + greenCount > 0 {
                attributed.append(NSAttributedString(
                    string: "/\(totalCount)",
                    attributes: [.foregroundColor: NSColor.white, .font: font]
                ))
            }
        } else if yellowCount > 0 {
            // No red, yellow exists: " 2/5" (yellow count in yellow, /total in white)
            attributed.append(NSAttributedString(string: " "))
            attributed.append(NSAttributedString(
                string: "\(yellowCount)",
                attributes: [.foregroundColor: NSColor.systemYellow, .font: font]
            ))
            if greenCount > 0 {
                attributed.append(NSAttributedString(
                    string: "/\(totalCount)",
                    attributes: [.foregroundColor: NSColor.white, .font: font]
                ))
            }
        } else if greenCount > 0 {
            // Green only: " 3" (white)
            let countAttr = NSAttributedString(
                string: " \(greenCount)",
                attributes: [.foregroundColor: NSColor.white, .font: font]
            )
            attributed.append(countAttr)
        }

        button.attributedTitle = attributed
    }

    /// Unified UI refresh - ensures status title and menu stay in sync
    @MainActor
    private func refreshUI() {
        updateStatusTitle()
        rebuildMenu()
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

        menu.addItem(NSMenuItem(
            title: "Quit",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        ))

        menu.delegate = self
        statusItem.menu = menu
    }

    // MARK: - NSMenuDelegate

    func menuWillOpen(_ menu: NSMenu) {
        isMenuOpen = true
    }

    func menuDidClose(_ menu: NSMenu) {
        isMenuOpen = false
    }

    @objc private func copyDiagnostics() {
        let diagnostics = DebugLog.collectDiagnostics()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(diagnostics, forType: .string)
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
            ("1 hour", 60),
            ("3 hours", 180),
            ("6 hours", 360),
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
        refreshUI()  // Update checkmark display
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

    @MainActor
    private func createSessionMenuItem(_ session: Session) -> NSMenuItem {
        let item = NSMenuItem(
            title: "",
            action: #selector(sessionItemClicked(_:)),
            keyEquivalent: ""
        )
        item.target = self
        item.representedObject = session

        let attributed = NSMutableAttributedString()

        // Check if session is acknowledged (for display purposes)
        let isAcknowledged = sessionObserver.isAcknowledged(sessionId: session.id)
        let displayStatus: SessionStatus = (isAcknowledged && session.status == .waitingInput)
            ? .running  // Show as green if acknowledged
            : session.status

        // Symbol color: red for permission_prompt, yellow for stop/unknown, green for running/acknowledged
        let symbolColor: NSColor
        if !isAcknowledged && session.status == .waitingInput {
            // Unacknowledged waiting: red for permission_prompt, yellow otherwise
            symbolColor = (session.waitingReason == .permissionPrompt) ? .systemRed : .systemYellow
        } else {
            switch displayStatus {
            case .running:
                symbolColor = .systemGreen
            case .waitingInput:
                symbolColor = .systemYellow  // Fallback (shouldn't reach here if acknowledged)
            case .stopped:
                symbolColor = .systemGray
            }
        }

        // Set icon using NSMenuItem.image (auto-aligned by macOS)
        let env = EnvironmentResolver.shared.resolve(session: session)
        if let icon = IconManager.shared.icon(for: env, size: 48) {
            item.image = icon
        }

        // Line 1: ● project-name (◉ when tool is running)
        let symbol: String
        if session.isToolRunning == true {
            symbol = "◉"  // Tool running indicator
        } else {
            symbol = displayStatus.symbol  // Static symbol (●, ◐, ✓)
        }
        let symbolAttr = NSAttributedString(
            string: "\(symbol) ",
            attributes: [
                .foregroundColor: symbolColor,
                .font: NSFont.systemFont(ofSize: 14)
            ]
        )
        attributed.append(symbolAttr)

        let nameAttr = NSAttributedString(
            string: session.projectName,
            attributes: [
                .font: NSFont.boldSystemFont(ofSize: 14)
            ]
        )
        attributed.append(nameAttr)

        // Line 2:   ~/path
        let pathAttr = NSAttributedString(
            string: "\n   \(session.displayPath)",
            attributes: [
                .foregroundColor: NSColor.secondaryLabelColor,
                .font: NSFont.systemFont(ofSize: 12)
            ]
        )
        attributed.append(pathAttr)

        // Line 3:   Environment • Status • HH:mm
        let timeStr = formatTime(session.updatedAt)
        let infoAttr = NSAttributedString(
            string: "\n   \(session.environmentLabel) • \(displayStatus.label) • \(timeStr)",
            attributes: [
                .foregroundColor: NSColor.secondaryLabelColor,
                .font: NSFont.systemFont(ofSize: 12)
            ]
        )
        attributed.append(infoAttr)

        item.attributedTitle = attributed

        return item
    }

    private func formatTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }

    @objc private func sessionItemClicked(_ sender: NSMenuItem) {
        guard let session = sender.representedObject as? Session else { return }
        focusTerminal(for: session)
    }

    // MARK: - Terminal Focus

    private func focusTerminal(for session: Session) {
        FocusManager.shared.focus(session: session)
    }

    // MARK: - Auto-Acknowledge on Terminal Focus

    @objc private func terminalDidActivate(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              let bundleId = app.bundleIdentifier else {
            DebugLog.log("[AppDelegate] terminalDidActivate: no app info")
            return
        }

        DebugLog.log("[AppDelegate] App activated: \(bundleId)")

        Task { @MainActor in
            switch bundleId {
            case GhosttyHelper.bundleIdentifier:
                acknowledgeActiveGhosttySession()
            case ITerm2Helper.bundleIdentifier:
                acknowledgeActiveITerm2Session()
            default:
                break
            }
        }
    }

    @MainActor
    private func acknowledgeActiveGhosttySession() {
        // Try tab title first (works for tmux sessions)
        var session: Session?

        if let tabTitle = GhosttyHelper.getSelectedTabTitle() {
            DebugLog.log("[AppDelegate] Ghostty tab title: '\(tabTitle)'")
            session = sessionObserver.session(byTabTitle: tabTitle)
        }

        // Fallback to tab index (for non-tmux with bind-on-start)
        if session == nil, let tabIndex = GhosttyHelper.getSelectedTabIndex() {
            DebugLog.log("[AppDelegate] Ghostty tab index: \(tabIndex)")
            session = sessionObserver.session(byTabIndex: tabIndex)
        }

        guard let session = session else {
            DebugLog.log("[AppDelegate] Ghostty: no matching session found")
            return
        }

        DebugLog.log("[AppDelegate] Ghostty session: \(session.projectName), status: \(session.status)")

        guard session.status == .waitingInput else {
            DebugLog.log("[AppDelegate] Ghostty: session not waitingInput")
            return
        }

        sessionObserver.acknowledge(sessionId: session.id)
        refreshUI()
        DebugLog.log("[AppDelegate] Auto-acknowledged Ghostty session: \(session.projectName)")
    }

    @MainActor
    private func acknowledgeActiveITerm2Session() {
        guard let tty = ITerm2Helper.getCurrentTTY(),
              let session = sessionObserver.session(byTTY: tty),
              session.status == .waitingInput else { return }

        sessionObserver.acknowledge(sessionId: session.id)
        refreshUI()
        DebugLog.log("[AppDelegate] Auto-acknowledged iTerm2 session: \(session.projectName)")
    }

    @objc private func handleAcknowledgeSession(_ notification: Notification) {
        guard let sessionId = notification.userInfo?["sessionId"] as? String else { return }

        Task { @MainActor in
            sessionObserver.acknowledge(sessionId: sessionId)
            refreshUI()
            DebugLog.log("[AppDelegate] Acknowledged session via notification click: \(sessionId)")
        }
    }
}
