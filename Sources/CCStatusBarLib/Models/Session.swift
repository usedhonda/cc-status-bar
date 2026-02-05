import Foundation

enum WaitingReason: String, Codable {
    case permissionPrompt = "permission_prompt"  // Red - permission/choice waiting
    case stop = "stop"                           // Yellow - command completion waiting
    case unknown = "unknown"                     // Yellow - legacy/unknown reason
}

struct Session: Codable, Identifiable, Equatable {
    let sessionId: String
    let cwd: String
    let tty: String?
    var status: SessionStatus
    let createdAt: Date
    var updatedAt: Date
    var ghosttyTabIndex: Int?  // Bind-on-start: tab index at session start
    var termProgram: String?   // TERM_PROGRAM environment variable (legacy, kept for compatibility)
    var actualTermProgram: String?  // Actual terminal when inside tmux (detected from client parent)
    var editorBundleID: String?  // Detected editor bundle ID via PPID chain (e.g., "com.todesktop.230313mzl4w4u92" for Cursor)
    var editorPID: pid_t?  // Editor process ID for direct activation (reliable for multiple instances)
    var waitingReason: WaitingReason?  // Reason for waitingInput status (permissionPrompt=red, stop/unknown=yellow)
    var isToolRunning: Bool?  // true during PreToolUse..PostToolUse (show spinner)
    var isAcknowledged: Bool?  // true if user has seen this waiting session (show as green)
    var displayOrder: Int?  // Display order in menu (stable across restarts, inherited on TTY reuse)
    var isDisambiguated: Bool?  // true if project name was expanded to parent/child format due to duplicate basenames

    var id: String {
        tty.map { "\(sessionId):\($0)" } ?? sessionId
    }

    /// Basename of cwd (for logging/search)
    var projectName: String {
        URL(fileURLWithPath: cwd).lastPathComponent
    }

    /// Display name: basename or parent/child format if disambiguated
    var displayName: String {
        if isDisambiguated == true {
            // parent/child format for disambiguation
            let components = cwd.split(separator: "/")
            if components.count >= 2 {
                return components.suffix(2).joined(separator: "/")
            }
        }
        return projectName
    }

    /// Search terms for window title matching (high precision -> fallback order)
    var searchTerms: [String] {
        let components = cwd.split(separator: "/")
        var terms: [String] = []
        // parent/child format first (higher precision)
        if components.count >= 2 {
            terms.append(components.suffix(2).joined(separator: "/"))
        }
        // basename as fallback
        terms.append(projectName)
        return terms
    }

    var displayPath: String {
        cwd.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~")
    }

    /// Environment label showing terminal and tmux status
    /// e.g., "Ghostty/tmux", "iTerm2", "Ghostty", "VS Code", "Cursor", "Zed"
    /// Delegates to EnvironmentResolver for single source of truth
    var environmentLabel: String {
        EnvironmentResolver.shared.resolve(session: self).displayName
    }

    /// Display text based on session display mode setting
    /// - Parameters:
    ///   - mode: The session display mode
    ///   - paneInfo: Optional pre-fetched pane info (avoids redundant lookups)
    func displayText(for mode: SessionDisplayMode, paneInfo: TmuxHelper.PaneInfo? = nil) -> String {
        let info = paneInfo ?? tty.flatMap { TmuxHelper.getPaneInfo(for: $0) }
        switch mode {
        case .projectName:
            return displayName
        case .tmuxWindow:
            return info?.windowName ?? displayName
        case .tmuxSession:
            return info?.session ?? displayName
        case .tmuxSessionWindow:
            guard let info = info else { return displayName }
            return "\(info.session):\(info.windowName)"
        }
    }

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case cwd
        case tty
        case status
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case ghosttyTabIndex = "ghostty_tab_index"
        case termProgram = "term_program"
        case actualTermProgram = "actual_term_program"
        case editorBundleID = "editor_bundle_id"
        case editorPID = "editor_pid"
        case waitingReason = "waiting_reason"
        case isToolRunning = "is_tool_running"
        case isAcknowledged = "is_acknowledged"
        case displayOrder = "display_order"
        case isDisambiguated = "is_disambiguated"
    }
}
