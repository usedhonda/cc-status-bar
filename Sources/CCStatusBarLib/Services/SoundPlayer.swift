import AppKit
import Foundation

struct AlertCommandContext: Equatable {
    let source: String
    let sessionID: String
    let project: String
    let displayName: String
    let cwd: String
    let tty: String
    let waitingReason: String
    let terminal: String
    let tmuxSession: String
    let tmuxWindowIndex: String
    let tmuxWindowName: String
    let tmuxPaneIndex: String
    let tmuxPaneTarget: String

    static func from(
        session: Session,
        paneInfoProvider: (String) -> TmuxHelper.PaneInfo? = { TmuxHelper.getPaneInfo(for: $0) }
    ) -> AlertCommandContext {
        let paneInfo = session.tty.flatMap { paneInfoProvider($0) }
        let tmuxSession = paneInfo?.session ?? ""
        let tmuxWindowIndex = paneInfo?.window ?? ""
        let tmuxWindowName = paneInfo?.windowName ?? ""
        let tmuxPaneIndex = paneInfo?.pane ?? ""
        let tmuxPaneTarget = [tmuxSession, tmuxWindowIndex, tmuxPaneIndex].allSatisfy { !$0.isEmpty }
            ? "\(tmuxSession):\(tmuxWindowIndex).\(tmuxPaneIndex)"
            : ""

        return AlertCommandContext(
            source: "claude_code",
            sessionID: session.sessionId,
            project: session.projectName,
            displayName: session.displayName,
            cwd: session.cwd,
            tty: session.tty ?? "",
            waitingReason: session.waitingReason?.rawValue ?? "",
            terminal: session.environmentLabel,
            tmuxSession: tmuxSession,
            tmuxWindowIndex: tmuxWindowIndex,
            tmuxWindowName: tmuxWindowName,
            tmuxPaneIndex: tmuxPaneIndex,
            tmuxPaneTarget: tmuxPaneTarget
        )
    }

    static func from(
        codexSession: CodexSession,
        waitingReason: WaitingReason,
        paneInfoProvider: (String) -> TmuxHelper.PaneInfo? = { TmuxHelper.getPaneInfo(for: $0) }
    ) -> AlertCommandContext {
        let paneInfo = codexSession.tty.flatMap { paneInfoProvider($0) }
        let tmuxSession = paneInfo?.session ?? codexSession.tmuxSession ?? ""
        let tmuxWindowIndex = paneInfo?.window ?? codexSession.tmuxWindow ?? ""
        let tmuxWindowName = paneInfo?.windowName ?? ""
        let tmuxPaneIndex = paneInfo?.pane ?? codexSession.tmuxPane ?? ""
        let tmuxPaneTarget = [tmuxSession, tmuxWindowIndex, tmuxPaneIndex].allSatisfy { !$0.isEmpty }
            ? "\(tmuxSession):\(tmuxWindowIndex).\(tmuxPaneIndex)"
            : ""

        return AlertCommandContext(
            source: "codex",
            sessionID: codexSession.sessionId ?? "",
            project: codexSession.projectName,
            displayName: codexSession.projectName,
            cwd: codexSession.cwd,
            tty: codexSession.tty ?? "",
            waitingReason: waitingReason.rawValue,
            terminal: codexSession.terminalApp ?? "",
            tmuxSession: tmuxSession,
            tmuxWindowIndex: tmuxWindowIndex,
            tmuxWindowName: tmuxWindowName,
            tmuxPaneIndex: tmuxPaneIndex,
            tmuxPaneTarget: tmuxPaneTarget
        )
    }
}

struct AlertCommandLaunchInfo: Equatable {
    let executableURL: URL
    let arguments: [String]
    let environment: [String: String]
    let currentDirectoryURL: URL?
}

/// Plays alert sounds and sends BEL to tmux clients when sessions need attention.
enum SoundPlayer {
    private static func normalizedAlertCommand(_ command: String?) -> String? {
        guard let command = command?.trimmingCharacters(in: .whitespacesAndNewlines),
              !command.isEmpty else {
            return nil
        }
        return command
    }

    static func buildAlertCommandLaunch(
        command: String? = AppSettings.alertCommand,
        enabled: Bool = AppSettings.isAlertCommandEnabled,
        context: AlertCommandContext,
        baseEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) -> AlertCommandLaunchInfo? {
        guard enabled else { return nil }
        guard let command = normalizedAlertCommand(command) else { return nil }

        var environment = baseEnvironment
        environment["CCSB_SOURCE"] = context.source
        environment["CCSB_SESSION_ID"] = context.sessionID
        environment["CCSB_PROJECT"] = context.project
        environment["CCSB_DISPLAY_NAME"] = context.displayName
        environment["CCSB_CWD"] = context.cwd
        environment["CCSB_TTY"] = context.tty
        environment["CCSB_WAITING_REASON"] = context.waitingReason
        environment["CCSB_TERMINAL"] = context.terminal
        environment["CCSB_TMUX_SESSION"] = context.tmuxSession
        environment["CCSB_TMUX_WINDOW_INDEX"] = context.tmuxWindowIndex
        environment["CCSB_TMUX_WINDOW_NAME"] = context.tmuxWindowName
        environment["CCSB_TMUX_PANE_INDEX"] = context.tmuxPaneIndex
        environment["CCSB_TMUX_PANE_TARGET"] = context.tmuxPaneTarget

        let currentDirectoryURL = context.cwd.isEmpty ? nil : URL(fileURLWithPath: context.cwd)
        return AlertCommandLaunchInfo(
            executableURL: URL(fileURLWithPath: "/bin/zsh"),
            arguments: ["-lc", command],
            environment: environment,
            currentDirectoryURL: currentDirectoryURL
        )
    }

    static func runAlertCommand(for session: Session) {
        let context = AlertCommandContext.from(session: session)
        runAlertCommand(context: context)
    }

    static func runAlertCommand(for codexSession: CodexSession, waitingReason: WaitingReason) {
        let context = AlertCommandContext.from(codexSession: codexSession, waitingReason: waitingReason)
        runAlertCommand(context: context)
    }

    static func runAlertCommand(for codexSession: CodexSession, waitingReason: CodexWaitingReason) {
        let mappedReason: WaitingReason
        switch waitingReason {
        case .permissionPrompt:
            mappedReason = .permissionPrompt
        case .stop:
            mappedReason = .stop
        case .unknown:
            mappedReason = .unknown
        }
        runAlertCommand(for: codexSession, waitingReason: mappedReason)
    }

    static func runAlertCommand(context: AlertCommandContext) {
        guard AppSettings.alertsEnabled else {
            DebugLog.log("[SoundPlayer] Skipped alert command (alertsEnabled=false)")
            return
        }

        guard AppSettings.isAlertCommandConfigured else {
            DebugLog.log("[SoundPlayer] Skipped alert command (alertCommand not configured)")
            return
        }

        guard let launch = buildAlertCommandLaunch(context: context) else {
            DebugLog.log("[SoundPlayer] Failed to build alert command launch")
            return
        }

        let process = Process()
        process.executableURL = launch.executableURL
        process.arguments = launch.arguments
        process.environment = launch.environment
        process.currentDirectoryURL = launch.currentDirectoryURL
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            DebugLog.log("[SoundPlayer] Ran alert command for \(context.project)")
        } catch {
            DebugLog.log("[SoundPlayer] Alert command failed: \(error.localizedDescription)")
        }
    }

    /// Resolve the file to play for alert sounds.
    /// Returns nil only when no file fallback exists and system beep should be used.
    static func resolveSoundPath(
        setting: String?,
        defaultSoundPath: String = AppSettings.defaultAlertSoundPath,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> String? {
        let normalized = setting?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        // Custom file selected by user.
        if !normalized.isEmpty, normalized != "beep" {
            if fileExists(normalized) {
                return normalized
            }
            // If custom file vanished, try packaged default before falling back to system beep.
            return fileExists(defaultSoundPath) ? defaultSoundPath : nil
        }

        // "beep" / nil / empty -> prefer default sound file for better device compatibility.
        return fileExists(defaultSoundPath) ? defaultSoundPath : nil
    }

    private static func playSystemBeep(reason: String) {
        NSSound.beep()
        DebugLog.log("[SoundPlayer] Played system beep (\(reason))")
    }

    /// Play alert sound if sound is enabled.
    static func playAlertSound() {
        guard AppSettings.soundEnabled else {
            DebugLog.log("[SoundPlayer] Skipped alert sound (soundEnabled=false)")
            return
        }

        let setting = AppSettings.alertSoundPath
        guard let path = resolveSoundPath(setting: setting) else {
            playSystemBeep(reason: "no playable file (setting=\(setting ?? "nil"))")
            return
        }

        if let sound = NSSound(contentsOfFile: path, byReference: true) {
            sound.play()
            DebugLog.log("[SoundPlayer] Played sound: \(path)")
        } else {
            playSystemBeep(reason: "failed to load sound file: \(path)")
        }
    }

    /// Preview the current alert sound (ignores soundEnabled setting).
    static func previewSound() {
        let setting = AppSettings.alertSoundPath
        guard let path = resolveSoundPath(setting: setting) else {
            playSystemBeep(reason: "preview no playable file (setting=\(setting ?? "nil"))")
            return
        }

        if let sound = NSSound(contentsOfFile: path, byReference: true) {
            sound.play()
            DebugLog.log("[SoundPlayer] Previewed sound: \(path)")
        } else {
            playSystemBeep(reason: "preview failed to load sound file: \(path)")
        }
    }

    /// Send BEL character to the tmux client TTY for a given pane TTY.
    /// This triggers terminal visual/audio bell (e.g. tmux visual-bell, iTerm badge).
    static func sendBell(tty: String) {
        guard AppSettings.isAlertCommandEnabled else { return }

        // Get pane info to find socket path and session name
        guard let paneInfo = TmuxHelper.getPaneInfo(for: tty) else {
            DebugLog.log("[SoundPlayer] No tmux pane for TTY \(tty), skipping BEL")
            return
        }

        guard let clientTTY = TmuxHelper.getClientTTY(
            for: paneInfo.session,
            socketPath: paneInfo.socketPath
        ) else {
            DebugLog.log("[SoundPlayer] No client TTY for session \(paneInfo.session), skipping BEL")
            return
        }

        // Write BEL (\a = 0x07) to client TTY
        guard let fh = FileHandle(forWritingAtPath: clientTTY) else {
            DebugLog.log("[SoundPlayer] Cannot open client TTY \(clientTTY) for writing")
            return
        }
        defer { fh.closeFile() }

        let bel = Data([0x07])
        fh.write(bel)
        DebugLog.log("[SoundPlayer] Sent BEL to \(clientTTY)")
    }
}
