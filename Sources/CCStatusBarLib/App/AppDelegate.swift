import AppKit
import Combine

public class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var sessionObserver: SessionObserver!
    private var cancellables = Set<AnyCancellable>()
    private var isMenuOpen = false

    /// Debounce work item for menu rebuilds
    private var menuRebuildWorkItem: DispatchWorkItem?

    /// Static DateFormatter for session time display (avoid repeated allocations)
    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    @MainActor
    public func applicationDidFinishLaunching(_ notification: Notification) {
        DebugLog.log("[AppDelegate] applicationDidFinishLaunching started")

        // Exit if another instance is already running (first one wins)
        if exitIfOtherInstanceRunning() {
            DebugLog.log("[AppDelegate] Exiting due to duplicate instance")
            return
        }
        DebugLog.log("[AppDelegate] No duplicate found, continuing")
        updateSymlinkToSelf()

        // Run setup check (handles first run, app move, repair)
        SetupManager.shared.checkAndRunSetup()

        // Initialize notification manager and request permission
        if AppSettings.notificationsEnabled {
            NotificationManager.shared.requestPermission()
        }

        // Initialize session observer
        DebugLog.log("[AppDelegate] Creating SessionObserver")
        sessionObserver = SessionObserver()

        // Create status item
        DebugLog.log("[AppDelegate] Creating statusItem")
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        DebugLog.log("[AppDelegate] statusItem created: \(statusItem != nil)")

        // Subscribe to session changes (debounced menu rebuild)
        sessionObserver.$sessions
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateStatusTitle()
                self?.scheduleMenuRebuild()
            }
            .store(in: &cancellables)

        // Set initial state
        updateStatusTitle()
        rebuildMenu()

        // Setup global hotkey
        setupHotkey()

        // Start web server if enabled
        if AppSettings.webServerEnabled {
            do {
                try WebServer.shared.start()
            } catch {
                DebugLog.log("[AppDelegate] Failed to start web server: \(error)")
            }
        }

        // Start WebSocket session observation (for iOS app real-time updates)
        WebSocketManager.shared.observeSessions(sessionObserver.$sessions)

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

        // Watch for notification click to focus session (uses same code path as menu click)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleFocusSession(_:)),
            name: .focusSession,
            object: nil
        )
    }

    public func applicationWillTerminate(_ notification: Notification) {
        WebServer.shared.stop()
        DebugLog.log("[AppDelegate] Application will terminate")
    }

    // MARK: - Hotkey

    private func setupHotkey() {
        HotkeyManager.shared.onHotkeyPressed = { [weak self] in
            Task { @MainActor in
                self?.handleHotkeyPressed()
            }
        }
        HotkeyManager.shared.register()
    }

    @MainActor
    private func handleHotkeyPressed() {
        DebugLog.log("[AppDelegate] Hotkey triggered")

        // If menu is open, close it
        if isMenuOpen {
            statusItem.menu?.cancelTracking()
            return
        }

        // Focus the first waiting session (priority: red > yellow)
        let waitingSessions = sessionObserver.sessions.filter {
            $0.status == .waitingInput && !sessionObserver.isAcknowledged(sessionId: $0.id)
        }

        // Priority: permission_prompt (red) first
        let redSessions = waitingSessions.filter { $0.waitingReason == .permissionPrompt }
        let yellowSessions = waitingSessions.filter { $0.waitingReason != .permissionPrompt }

        if let session = redSessions.first ?? yellowSessions.first {
            focusTerminal(for: session)
            sessionObserver.acknowledge(sessionId: session.id)
            refreshUI()
            DebugLog.log("[AppDelegate] Hotkey focused session: \(session.projectName)")
        } else {
            // No waiting sessions (all green or no sessions) - show the menu
            statusItem.button?.performClick(nil)
            DebugLog.log("[AppDelegate] Hotkey opened menu (no waiting sessions)")
        }
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
        let theme = AppSettings.colorTheme
        let ccColor: NSColor
        if redCount > 0 {
            ccColor = theme.redColor
        } else if yellowCount > 0 {
            ccColor = theme.yellowColor
        } else if greenCount > 0 {
            ccColor = theme.greenColor
        } else {
            ccColor = theme.whiteColor
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
                attributes: [.foregroundColor: theme.redColor, .font: font]
            ))
            if yellowCount + greenCount > 0 {
                attributed.append(NSAttributedString(
                    string: "/\(totalCount)",
                    attributes: [.foregroundColor: theme.whiteColor, .font: font]
                ))
            }
        } else if yellowCount > 0 {
            // No red, yellow exists: " 2/5" (yellow count in yellow, /total in white)
            attributed.append(NSAttributedString(string: " "))
            attributed.append(NSAttributedString(
                string: "\(yellowCount)",
                attributes: [.foregroundColor: theme.yellowColor, .font: font]
            ))
            if greenCount > 0 {
                attributed.append(NSAttributedString(
                    string: "/\(totalCount)",
                    attributes: [.foregroundColor: theme.whiteColor, .font: font]
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
        buildMenuItems(into: menu)
        menu.delegate = self
        statusItem.menu = menu
    }

    @MainActor
    private func buildMenuItems(into menu: NSMenu) {
        if sessionObserver.sessions.isEmpty {
            let emptyItem = NSMenuItem(title: "No active sessions", action: nil, keyEquivalent: "")
            emptyItem.isEnabled = false
            menu.addItem(emptyItem)
        } else {
            // Pin as Window option
            let pinItem = NSMenuItem(
                title: "Pin as Window",
                action: #selector(pinSessionList),
                keyEquivalent: ""
            )
            pinItem.target = self
            menu.addItem(pinItem)

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

        // Diagnostics (with warning indicator if issues exist)
        let diagnosticsItem = NSMenuItem(title: "", action: #selector(showDiagnostics), keyEquivalent: "")
        diagnosticsItem.target = self
        diagnosticsItem.attributedTitle = createDiagnosticsMenuTitle()
        menu.addItem(diagnosticsItem)

        menu.addItem(NSMenuItem(
            title: "Quit",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        ))
    }

    // MARK: - NSMenuDelegate

    public func menuWillOpen(_ menu: NSMenu) {
        isMenuOpen = true
    }

    public func menuNeedsUpdate(_ menu: NSMenu) {
        // Rebuild menu with fresh attach states before display
        TmuxHelper.invalidateAttachStatesCache()
        menu.removeAllItems()
        buildMenuItems(into: menu)
    }

    public func menuDidClose(_ menu: NSMenu) {
        isMenuOpen = false
    }

    @MainActor @objc private func showDiagnostics() {
        DiagnosticsWindowController.shared.showWindow()
    }

    @MainActor @objc private func pinSessionList() {
        SessionListWindowController.shared.showWindow(observer: sessionObserver)
    }

    /// Create attributed title for Diagnostics menu item with warning indicator
    @MainActor
    private func createDiagnosticsMenuTitle() -> NSAttributedString {
        let attributed = NSMutableAttributedString()

        let manager = DiagnosticsManager.shared
        if manager.hasErrors {
            attributed.append(NSAttributedString(
                string: "● ",
                attributes: [.foregroundColor: NSColor.systemRed]
            ))
        } else if manager.hasWarnings {
            attributed.append(NSAttributedString(
                string: "● ",
                attributes: [.foregroundColor: NSColor.systemOrange]
            ))
        }

        attributed.append(NSAttributedString(string: "Diagnostics..."))
        return attributed
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

        // Global Hotkey
        let hotkeyEnabled = HotkeyManager.shared.isEnabled
        let hotkeyDesc = hotkeyEnabled ? " (\(HotkeyManager.shared.hotkeyDescription))" : ""
        let hotkeyItem = NSMenuItem(
            title: "Global Hotkey\(hotkeyDesc)",
            action: #selector(toggleGlobalHotkey(_:)),
            keyEquivalent: ""
        )
        hotkeyItem.target = self
        hotkeyItem.state = hotkeyEnabled ? .on : .off
        menu.addItem(hotkeyItem)

        // Color Theme submenu
        let colorThemeItem = NSMenuItem(title: "Color Theme", action: nil, keyEquivalent: "")
        colorThemeItem.submenu = createColorThemeMenu()
        menu.addItem(colorThemeItem)

        menu.addItem(NSMenuItem.separator())

        // vibeterm (iOS app) submenu
        let vibetermItem = NSMenuItem(title: "vibeterm", action: nil, keyEquivalent: "")
        vibetermItem.submenu = createVibetermMenu()
        menu.addItem(vibetermItem)

        // Permissions submenu
        let permissionsItem = NSMenuItem(title: "Permissions", action: nil, keyEquivalent: "")
        permissionsItem.submenu = createPermissionsMenu()
        menu.addItem(permissionsItem)

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

    private func createPermissionsMenu() -> NSMenu {
        let menu = NSMenu()

        // Show current permission status
        let hasAccessibility = PermissionManager.checkAccessibilityPermission()
        let statusText = hasAccessibility ? "✓ Accessibility Granted" : "✗ Accessibility Required"
        let statusItem = NSMenuItem(title: statusText, action: nil, keyEquivalent: "")
        statusItem.isEnabled = false
        menu.addItem(statusItem)

        menu.addItem(NSMenuItem.separator())

        // Open Accessibility Settings
        let accessibilityItem = NSMenuItem(
            title: "Open Accessibility Settings...",
            action: #selector(openAccessibilitySettings),
            keyEquivalent: ""
        )
        accessibilityItem.target = self
        menu.addItem(accessibilityItem)

        return menu
    }

    @objc private func openAccessibilitySettings() {
        PermissionManager.openAccessibilitySettings()
    }

    @objc private func showIOSConnectionSetup() {
        ConnectionSetupWindowController.shared.showWindow()
    }

    @MainActor @objc private func toggleGlobalHotkey(_ sender: NSMenuItem) {
        let newState = !HotkeyManager.shared.isEnabled
        HotkeyManager.shared.isEnabled = newState
        sender.state = newState ? .on : .off
        DebugLog.log("[AppDelegate] Global hotkey \(newState ? "enabled" : "disabled")")
        refreshUI()  // Update menu to show/hide hotkey description
    }

    @MainActor @objc private func toggleWebServer(_ sender: NSMenuItem) {
        let newState = !AppSettings.webServerEnabled
        AppSettings.webServerEnabled = newState
        sender.state = newState ? .on : .off

        if newState {
            do {
                try WebServer.shared.start()
                DebugLog.log("[AppDelegate] Web server started")
            } catch {
                DebugLog.log("[AppDelegate] Failed to start web server: \(error)")
                // Revert setting on failure
                AppSettings.webServerEnabled = false
                sender.state = .off
                showAlert(
                    title: "Web Server Error",
                    message: "Failed to start web server: \(error.localizedDescription)"
                )
            }
        } else {
            WebServer.shared.stop()
            DebugLog.log("[AppDelegate] Web server stopped")
        }

        refreshUI()  // Update menu to show/hide port
    }

    private func createTimeoutMenu() -> NSMenu {
        let menu = NSMenu()
        let currentTimeout = AppSettings.sessionTimeoutMinutes
        let options: [(String, Int)] = [
            ("1 hour", 60),
            ("3 hours", 180),
            ("6 hours", 360),
            ("12 hours", 720),
            ("24 hours", 1440),
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

    private func createVibetermMenu() -> NSMenu {
        let menu = NSMenu()

        // WebSocket toggle
        let serverRunning = WebServer.shared.isRunning
        let serverTitle = serverRunning
            ? "WebSocket :\(WebServer.shared.actualPort)"
            : "WebSocket Off"
        let serverItem = NSMenuItem(
            title: serverTitle,
            action: #selector(toggleWebServer(_:)),
            keyEquivalent: ""
        )
        serverItem.target = self
        serverItem.state = serverRunning ? .on : .off
        menu.addItem(serverItem)

        menu.addItem(NSMenuItem.separator())

        // Show QR Code
        let qrItem = NSMenuItem(
            title: "Show QR Code...",
            action: #selector(showIOSConnectionSetup),
            keyEquivalent: ""
        )
        qrItem.target = self
        menu.addItem(qrItem)

        return menu
    }

    private func createColorThemeMenu() -> NSMenu {
        let menu = NSMenu()
        let currentTheme = AppSettings.colorTheme

        for theme in ColorTheme.allCases {
            let item = NSMenuItem(
                title: "",
                action: #selector(setColorTheme(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = theme
            item.state = (currentTheme == theme) ? .on : .off

            // Build attributed title with 4 color dots + theme name
            let attributed = NSMutableAttributedString()
            let dotFont = NSFont.systemFont(ofSize: 12)
            let textFont = NSFont.systemFont(ofSize: 13)

            // Add 4 color dots: red, yellow, green, white
            for color in [theme.redColor, theme.yellowColor, theme.greenColor, theme.whiteColor] {
                attributed.append(NSAttributedString(
                    string: "●",
                    attributes: [.foregroundColor: color, .font: dotFont]
                ))
            }

            // Add space and theme name
            attributed.append(NSAttributedString(
                string: "  \(theme.displayName)",
                attributes: [.foregroundColor: NSColor.labelColor, .font: textFont]
            ))

            item.attributedTitle = attributed
            menu.addItem(item)
        }

        return menu
    }

    @MainActor @objc private func setColorTheme(_ sender: NSMenuItem) {
        guard let theme = sender.representedObject as? ColorTheme else { return }
        AppSettings.colorTheme = theme
        DebugLog.log("[AppDelegate] Color theme set to: \(theme.displayName)")
        refreshUI()
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

        // Check if tmux session is detached
        var isTmuxDetached = false
        if let tty = session.tty, let paneInfo = TmuxHelper.getPaneInfo(for: tty) {
            isTmuxDetached = !TmuxHelper.isSessionAttached(paneInfo.session)
        }

        // Symbol color: gray for detached tmux, red for permission_prompt, yellow for stop/unknown, green for running/acknowledged
        let theme = AppSettings.colorTheme
        let symbolColor: NSColor
        if isTmuxDetached {
            symbolColor = .tertiaryLabelColor  // Grayed out for detached tmux
        } else if !isAcknowledged && session.status == .waitingInput {
            // Unacknowledged waiting: red for permission_prompt, yellow otherwise
            symbolColor = (session.waitingReason == .permissionPrompt) ? theme.redColor : theme.yellowColor
        } else {
            switch displayStatus {
            case .running:
                symbolColor = theme.greenColor
            case .waitingInput:
                symbolColor = theme.yellowColor  // Fallback (shouldn't reach here if acknowledged)
            case .stopped:
                symbolColor = .systemGray
            }
        }

        // Set icon using NSMenuItem.image (auto-aligned by macOS)
        // Use iconWithBadge to show tab number for Ghostty
        let env = EnvironmentResolver.shared.resolve(session: session)
        if let icon = IconManager.shared.iconWithBadge(for: env, size: 48) {
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

        // Text colors: gray out everything for detached tmux (use tertiaryLabelColor for more visible difference)
        let primaryTextColor: NSColor = isTmuxDetached ? .tertiaryLabelColor : .labelColor
        let secondaryTextColor: NSColor = isTmuxDetached ? .quaternaryLabelColor : .secondaryLabelColor

        let nameAttr = NSAttributedString(
            string: session.displayName,
            attributes: [
                .foregroundColor: primaryTextColor,
                .font: NSFont.boldSystemFont(ofSize: 14)
            ]
        )
        attributed.append(nameAttr)

        // Line 2:   ~/path
        let pathAttr = NSAttributedString(
            string: "\n   \(session.displayPath)",
            attributes: [
                .foregroundColor: secondaryTextColor,
                .font: NSFont.systemFont(ofSize: 12)
            ]
        )
        attributed.append(pathAttr)

        // Line 3:   Environment • Status • HH:mm
        let timeStr = formatTime(session.updatedAt)
        let infoAttr = NSAttributedString(
            string: "\n   \(session.environmentLabel) • \(displayStatus.label) • \(timeStr)",
            attributes: [
                .foregroundColor: secondaryTextColor,
                .font: NSFont.systemFont(ofSize: 12)
            ]
        )
        attributed.append(infoAttr)

        item.attributedTitle = attributed

        // Add submenu for quick actions
        item.submenu = createSessionActionsMenu(session: session, isAcknowledged: isAcknowledged, isTmuxDetached: isTmuxDetached)

        return item
    }

    private func createSessionActionsMenu(session: Session, isAcknowledged: Bool, isTmuxDetached: Bool = false) -> NSMenu {
        let menu = NSMenu()

        // Copy Attach Command (only for detached tmux sessions)
        if isTmuxDetached, let tty = session.tty, let paneInfo = TmuxHelper.getPaneInfo(for: tty) {
            let attachItem = NSMenuItem(
                title: "Copy Attach Command",
                action: #selector(copyAttachCommand(_:)),
                keyEquivalent: ""
            )
            attachItem.target = self
            attachItem.representedObject = paneInfo.session
            menu.addItem(attachItem)

            menu.addItem(NSMenuItem.separator())
        }

        // Open in Finder
        let finderItem = NSMenuItem(
            title: "Open in Finder",
            action: #selector(openInFinder(_:)),
            keyEquivalent: ""
        )
        finderItem.target = self
        finderItem.representedObject = session
        menu.addItem(finderItem)

        // Copy Path
        let copyPathItem = NSMenuItem(
            title: "Copy Path",
            action: #selector(copySessionPath(_:)),
            keyEquivalent: ""
        )
        copyPathItem.target = self
        copyPathItem.representedObject = session
        menu.addItem(copyPathItem)

        // Copy TTY (if available)
        if let tty = session.tty, !tty.isEmpty {
            let copyTtyItem = NSMenuItem(
                title: "Copy TTY",
                action: #selector(copySessionTty(_:)),
                keyEquivalent: ""
            )
            copyTtyItem.target = self
            copyTtyItem.representedObject = session
            menu.addItem(copyTtyItem)
        }

        return menu
    }

    @objc private func openInFinder(_ sender: NSMenuItem) {
        guard let session = sender.representedObject as? Session else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: session.cwd))
        DebugLog.log("[AppDelegate] Opened in Finder: \(session.cwd)")
    }

    @objc private func copySessionPath(_ sender: NSMenuItem) {
        guard let session = sender.representedObject as? Session else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(session.cwd, forType: .string)
        DebugLog.log("[AppDelegate] Copied path: \(session.cwd)")
    }

    @objc private func copySessionTty(_ sender: NSMenuItem) {
        guard let session = sender.representedObject as? Session,
              let tty = session.tty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(tty, forType: .string)
        DebugLog.log("[AppDelegate] Copied TTY: \(tty)")
    }

    @objc private func copyAttachCommand(_ sender: NSMenuItem) {
        guard let sessionName = sender.representedObject as? String else { return }
        let command = "tmux attach -t \(sessionName)"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
        DebugLog.log("[AppDelegate] Copied attach command: \(command)")
    }

    private func formatTime(_ date: Date) -> String {
        return Self.timeFormatter.string(from: date)
    }

    /// Schedule a debounced menu rebuild (100ms delay)
    @MainActor
    private func scheduleMenuRebuild() {
        menuRebuildWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.rebuildMenu()
        }
        menuRebuildWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: workItem)
    }

    @objc private func sessionItemClicked(_ sender: NSMenuItem) {
        guard let session = sender.representedObject as? Session else { return }
        focusTerminal(for: session)
        Task { @MainActor in
            sessionObserver.acknowledge(sessionId: session.id)
            refreshUI()
        }
    }

    // MARK: - Terminal Focus

    private func focusTerminal(for session: Session) {
        let result = FocusManager.shared.focus(session: session)

        // Handle partial success - offer to bind current tab
        if case .partialSuccess(let reason) = result {
            DebugLog.log("[AppDelegate] Focus partial success: \(reason)")
            offerTabBinding(for: session, reason: reason)
        }
    }

    /// Offer to bind current tab when focus fails to find the exact tab
    private func offerTabBinding(for session: Session, reason: String) {
        // Only offer binding for Ghostty without tmux
        let env = EnvironmentResolver.shared.resolve(session: session)
        guard case .ghostty(let hasTmux, _, _) = env, !hasTmux, GhosttyHelper.isRunning else {
            return
        }

        // Don't show binding dialog if already bound
        if session.ghosttyTabIndex != nil {
            return
        }

        // Get current tab index before showing dialog
        guard let currentTabIndex = GhosttyHelper.getSelectedTabIndex() else {
            DebugLog.log("[AppDelegate] Cannot get current tab index for binding")
            return
        }

        // Show binding offer dialog
        DispatchQueue.main.async { [weak self] in
            self?.showBindingAlert(for: session, tabIndex: currentTabIndex)
        }
    }

    private func showBindingAlert(for session: Session, tabIndex: Int) {
        let alert = NSAlert()
        alert.messageText = "Bind Tab?"
        alert.informativeText = "Tab for '\(session.displayName)' was not found automatically.\n\nIs this the correct tab? Binding it will help focus this session in the future."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Bind This Tab")
        alert.addButton(withTitle: "Not Now")

        let response = alert.runModal()

        if response == .alertFirstButtonReturn {
            // Bind the tab
            bindTab(sessionId: session.sessionId, tty: session.tty, tabIndex: tabIndex)
            DebugLog.log("[AppDelegate] User bound tab \(tabIndex) for session '\(session.projectName)'")
        }
    }

    private func bindTab(sessionId: String, tty: String?, tabIndex: Int) {
        // Update session in store with the tab index
        SessionStore.shared.updateTabIndex(sessionId: sessionId, tty: tty, tabIndex: tabIndex)
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

    @objc private func handleFocusSession(_ notification: Notification) {
        guard let sessionId = notification.userInfo?["sessionId"] as? String else { return }

        Task { @MainActor in
            // Find session from observer (same source as menu items)
            guard let session = sessionObserver.sessions.first(where: { $0.id == sessionId }) else {
                DebugLog.log("[AppDelegate] Session not found for focus: \(sessionId)")
                return
            }

            // Use the same code path as menu click
            focusTerminal(for: session)
            sessionObserver.acknowledge(sessionId: sessionId)
            refreshUI()
            DebugLog.log("[AppDelegate] Focused session via notification click: \(session.projectName)")
        }
    }

    // MARK: - Duplicate Instance Prevention

    /// Exit if another CCStatusBar instance is already running (first one wins)
    /// Returns true if exiting (caller should return early)
    private func exitIfOtherInstanceRunning() -> Bool {
        // Use NSWorkspace for safe, non-blocking duplicate detection
        guard let myBundleID = Bundle.main.bundleIdentifier else {
            DebugLog.log("[AppDelegate] exitIfOtherInstanceRunning - no bundle ID, skipping")
            return false
        }

        let myPID = ProcessInfo.processInfo.processIdentifier
        let runningApps = NSWorkspace.shared.runningApplications

        // Check for other instances with same bundle ID
        for app in runningApps {
            if app.bundleIdentifier == myBundleID && app.processIdentifier != myPID {
                DebugLog.log("[AppDelegate] Found duplicate: PID \(app.processIdentifier)")
                let alert = NSAlert()
                alert.messageText = "CC Status Bar is already running"
                alert.informativeText = "Another instance of CC Status Bar is already running. This instance will exit."
                alert.alertStyle = .warning
                alert.addButton(withTitle: "OK")
                alert.runModal()
                NSApp.terminate(nil)
                return true
            }
        }

        DebugLog.log("[AppDelegate] No duplicate found (my PID: \(myPID))")
        return false
    }

    /// Update symlink to point to this executable
    private func updateSymlinkToSelf() {
        let symlinkPath = NSString("~/Library/Application Support/CCStatusBar/bin/CCStatusBar")
            .expandingTildeInPath
        guard let executablePath = Bundle.main.executablePath else {
            DebugLog.log("[AppDelegate] Cannot get executable path for symlink update")
            return
        }

        // Check if symlink already points to self
        if let currentTarget = try? FileManager.default.destinationOfSymbolicLink(atPath: symlinkPath),
           currentTarget == executablePath {
            return  // Already correct
        }

        // Ensure parent directory exists
        let parentDir = (symlinkPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: parentDir, withIntermediateDirectories: true)

        // Update symlink
        try? FileManager.default.removeItem(atPath: symlinkPath)
        do {
            try FileManager.default.createSymbolicLink(atPath: symlinkPath, withDestinationPath: executablePath)
            DebugLog.log("[AppDelegate] Updated symlink to: \(executablePath)")
        } catch {
            DebugLog.log("[AppDelegate] Failed to create symlink: \(error)")
        }
    }
}
