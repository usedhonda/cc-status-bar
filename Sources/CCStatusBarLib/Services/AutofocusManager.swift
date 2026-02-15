import Foundation
import AppKit

/// Automatically focuses the terminal when a session transitions to waitingInput.
/// Opt-in feature (default OFF). Uses debounce + per-session cooldown to avoid focus storms.
@MainActor
final class AutofocusManager {
    static let shared = AutofocusManager()

    /// Reference to session observer for acknowledge calls
    weak var sessionObserver: SessionObserver?

    /// Per-session cooldown: sessionId -> last autofocus time
    private var cooldowns: [String: Date] = [:]
    private let cooldownInterval: TimeInterval = 30  // 30 seconds per session

    /// Debounce: only focus 1 session per 500ms window
    private var debounceWorkItem: DispatchWorkItem?
    private let debounceInterval: TimeInterval = 0.5

    private init() {}

    // MARK: - Public API

    /// Called when sessions transition to waitingInput.
    /// Debounces and picks the highest-priority candidate to focus.
    func handleWaitingTransitions(_ sessions: [Session]) {
        guard AppSettings.autofocusEnabled else { return }

        let candidates = sessions.filter { session in
            session.status == .waitingInput &&
            session.isAcknowledged != true &&
            !isOnCooldown(sessionId: session.id)
        }

        guard !candidates.isEmpty else { return }

        // Cancel previous debounce
        debounceWorkItem?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            self?.performAutofocus(candidates: candidates)
        }
        debounceWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + debounceInterval, execute: workItem)
    }

    /// Called when a Codex session transitions to waitingInput.
    /// Uses the same debounce window as CC sessions.
    func handleCodexWaitingTransition(_ codexSession: CodexSession, reason: CodexWaitingReason) {
        guard AppSettings.autofocusEnabled else { return }
        let key = codexSession.id
        guard !isOnCooldown(sessionId: key) else { return }

        // Cancel previous debounce (shared with CC sessions)
        debounceWorkItem?.cancel()

        let isRed = reason == .permissionPrompt
        let workItem = DispatchWorkItem { [weak self] in
            self?.performCodexAutofocus(codexSession: codexSession, isRed: isRed)
        }
        debounceWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + debounceInterval, execute: workItem)
    }

    /// Clear cooldown when a session returns to running
    func clearCooldown(sessionId: String) {
        cooldowns.removeValue(forKey: sessionId)
    }

    // MARK: - Private

    private func isOnCooldown(sessionId: String) -> Bool {
        guard let lastTime = cooldowns[sessionId] else { return false }
        return Date().timeIntervalSince(lastTime) < cooldownInterval
    }

    private func performAutofocus(candidates: [Session]) {
        guard AppSettings.autofocusEnabled else { return }

        // Filter out detached tmux sessions (no terminal to focus)
        let focusable = candidates.filter { session in
            guard let tty = session.tty,
                  let paneInfo = TmuxHelper.getPaneInfo(for: tty) else {
                return true  // Non-tmux sessions are always focusable
            }
            return TmuxHelper.isSessionAttached(paneInfo.session, socketPath: paneInfo.socketPath)
        }

        guard !focusable.isEmpty else {
            DebugLog.log("[AutofocusManager] All candidates are detached tmux, skipping")
            return
        }

        // Priority: red (permissionPrompt) > yellow, then by updatedAt descending
        let sorted = focusable.sorted { a, b in
            let aIsRed = a.waitingReason == .permissionPrompt
            let bIsRed = b.waitingReason == .permissionPrompt
            if aIsRed != bIsRed { return aIsRed }
            return a.updatedAt > b.updatedAt
        }

        guard let target = sorted.first else { return }

        DebugLog.log("[AutofocusManager] Autofocusing session: \(target.projectName) (reason: \(target.waitingReason?.rawValue ?? "unknown"))")

        let result = FocusManager.shared.focus(session: target)

        switch result {
        case .success:
            cooldowns[target.id] = Date()
            sessionObserver?.acknowledge(sessionId: target.id)
            DebugLog.log("[AutofocusManager] Autofocus success + acknowledged: \(target.projectName)")
        case .partialSuccess(let reason):
            cooldowns[target.id] = Date()
            sessionObserver?.acknowledge(sessionId: target.id)
            DebugLog.log("[AutofocusManager] Autofocus partial success (\(reason)): \(target.projectName)")
        case .notFound(let hint):
            DebugLog.log("[AutofocusManager] Autofocus failed (\(hint)): \(target.projectName)")
        case .notRunning:
            DebugLog.log("[AutofocusManager] Autofocus failed (terminal not running): \(target.projectName)")
        }
    }

    private func performCodexAutofocus(codexSession: CodexSession, isRed: Bool) {
        guard AppSettings.autofocusEnabled else { return }

        // Skip detached tmux sessions
        if let tty = codexSession.tty,
           let paneInfo = TmuxHelper.getPaneInfo(for: tty),
           !TmuxHelper.isSessionAttached(paneInfo.session, socketPath: paneInfo.socketPath) {
            DebugLog.log("[AutofocusManager] Codex candidate is detached tmux, skipping")
            return
        }

        let reasonStr = isRed ? "permission_prompt" : "stop"
        DebugLog.log("[AutofocusManager] Autofocusing Codex session: \(codexSession.projectName) (reason: \(reasonStr))")

        let result = CodexFocusHelper.focus(session: codexSession)
        let key = codexSession.id

        switch result {
        case .success, .partialSuccess:
            cooldowns[key] = Date()
            DebugLog.log("[AutofocusManager] Codex autofocus success: \(codexSession.projectName)")
        case .notFound(let hint):
            DebugLog.log("[AutofocusManager] Codex autofocus failed (\(hint)): \(codexSession.projectName)")
        case .notRunning:
            DebugLog.log("[AutofocusManager] Codex autofocus failed (terminal not running): \(codexSession.projectName)")
        }
    }
}
