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

        statusItem.menu = menu
    }

    @objc private func copyDiagnostics() {
        let diagnostics = DebugLog.collectDiagnostics()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(diagnostics, forType: .string)
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
        focusTerminal(at: session.cwd, tty: session.tty)
    }

    // MARK: - Terminal Focus

    private func focusTerminal(at path: String, tty: String?) {
        _ = path // path reserved for future use

        // Try iTerm2 first, then Terminal.app
        let script: String
        if let tty = tty {
            let escapedTty = tty.replacingOccurrences(of: "\"", with: "\\\"")
            script = """
                tell application "System Events"
                    if exists process "iTerm2" then
                        tell application "iTerm"
                            activate
                            repeat with w in windows
                                repeat with t in tabs of w
                                    repeat with s in sessions of t
                                        if tty of s contains "\(escapedTty)" then
                                            select w
                                            select t
                                            return
                                        end if
                                    end repeat
                                end repeat
                            end repeat
                        end tell
                    else if exists process "Terminal" then
                        tell application "Terminal"
                            activate
                            repeat with w in windows
                                repeat with t in tabs of w
                                    if tty of t contains "\(escapedTty)" then
                                        set frontmost of w to true
                                        set selected tab of w to t
                                        return
                                    end if
                                end repeat
                            end repeat
                        end tell
                    end if
                end tell
                """
        } else {
            // Fallback: just activate terminal
            script = """
                tell application "System Events"
                    if exists process "iTerm2" then
                        tell application "iTerm" to activate
                    else if exists process "Terminal" then
                        tell application "Terminal" to activate
                    end if
                end tell
                """
        }

        if let appleScript = NSAppleScript(source: script) {
            var error: NSDictionary?
            appleScript.executeAndReturnError(&error)
        }
    }
}
