import Foundation
import Combine

/// Status of a Codex session
enum CodexStatus: String, Codable {
    case running
    case waitingInput = "waiting_input"
    case stopped
}

/// Reason of Codex waiting_input for color distinction (red/yellow)
enum CodexWaitingReason: String, Codable {
    case permissionPrompt = "permission_prompt"  // red
    case stop = "stop"                           // yellow
    case unknown = "unknown"                     // yellow fallback
}

/// Tracks status received from Codex notify events
/// Provides cwd -> status mapping with timeout-based state machine
@MainActor
final class CodexStatusReceiver: ObservableObject {
    static let shared = CodexStatusReceiver()

    // MARK: - Configuration

    /// Grace period before considering a missing Codex session as stopped (seconds)
    private let pidDisappearGrace: TimeInterval = 3.0
    /// Keep synthetic stopped sessions for this long before pruning (seconds)
    private let stoppedRetention: TimeInterval = 90.0

    // MARK: - State

    /// cwd -> last event info
    private var statusByCwd: [String: CodexSessionStatus] = [:]
    /// cwds that have been acknowledged by user (click/focus)
    private var acknowledgedCwds: Set<String> = []
    /// cwd -> hash of pane content at last observed waiting screen
    private var lastPaneCapture: [String: Int] = [:]
    /// cwd -> last alert command fire time (throttle rapid-fire from Codex)
    private var lastAlertTime: [String: Date] = [:]
    /// Minimum interval between alert fires for the same cwd
    private let alertCooldown: TimeInterval = 10.0
    /// cwd -> token usage from webhook (higher priority than JSONL file parse)
    private var tokenUsageByCwd: [String: CodexTokenUsage] = [:]

    private init() {}

    // MARK: - Event Handling

    /// Handle incoming Codex notify event
    /// - Parameter data: JSON data from POST body
    func handleEvent(_ data: Data) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            DebugLog.log("[CodexStatusReceiver] Failed to parse event JSON")
            return
        }

        // Expected format: { "type": "agent-turn-complete", "cwd": "...", "thread-id": "..." }
        guard let eventType = json["type"] as? String else {
            DebugLog.log("[CodexStatusReceiver] Missing event type")
            return
        }

        let cwd = json["cwd"] as? String

        switch eventType {
        case "agent-turn-complete":
            handleAgentTurnComplete(cwd: cwd, json: json)
        case "codex-token-usage":
            handleTokenUsage(cwd: cwd, json: json)
        case "codex-session-start":
            handleSessionStart(cwd: cwd, json: json)
        default:
            DebugLog.log("[CodexStatusReceiver] Unknown event type: \(eventType)")
        }
    }

    private func handleAgentTurnComplete(cwd: String?, json: [String: Any]) {
        guard let cwd = cwd else {
            DebugLog.log("[CodexStatusReceiver] agent-turn-complete without cwd")
            return
        }

        let threadId = json["thread-id"] as? String
        let now = Date()
        let codexSession = CodexObserver.getCodexSession(for: cwd)
        let paneCapture = capturePane(for: codexSession)
        let waitingDetection = Self.detectWaitingInput(from: json, paneCapture: paneCapture)
        let waitingReason = waitingDetection.reason

        statusByCwd[cwd] = CodexSessionStatus(
            status: .waitingInput,
            waitingReason: waitingReason,
            lastEventAt: now,
            threadId: threadId,
            lastSeenAt: now,
            stoppedAt: nil,
            isSyntheticStopped: false
        )

        // Clear acknowledge on new waiting event so it shows as yellow/red again
        acknowledgedCwds.remove(cwd)

        objectWillChange.send()

        // Save pane capture hash for later comparison (running recovery detection)
        if let paneCapture = paneCapture {
            lastPaneCapture[cwd] = Self.hashPaneTail(paneCapture)
        } else {
            lastPaneCapture.removeValue(forKey: cwd)
        }

        DebugLog.log("[CodexStatusReceiver] Codex waiting_input: \(cwd) reason=\(waitingReason.rawValue) source=\(waitingDetection.source)")

        // Run alert command for Codex waiting transition (throttled per cwd).
        if let lastFire = lastAlertTime[cwd], now.timeIntervalSince(lastFire) < alertCooldown {
            DebugLog.log("[CodexStatusReceiver] Alert throttled for \(cwd) (\(String(format: "%.1f", now.timeIntervalSince(lastFire)))s < \(Int(alertCooldown))s)")
        } else {
            lastAlertTime[cwd] = now
            SoundPlayer.runAlertCommand(for: codexSession ?? CodexSession(pid: 0, cwd: cwd), waitingReason: waitingReason)
        }

        // Trigger autofocus for this Codex session
        if let codexSession = codexSession {
            AutofocusManager.shared.handleCodexWaitingTransition(codexSession, reason: waitingReason)
        }

        // Invalidate CodexObserver cache to trigger WebSocket update
        CodexObserver.invalidateCache()

        // Broadcast update to WebSocket clients (with pane capture for waiting_input)
        Task {
            if let codexSession = codexSession {
                var dict = WebSocketManager.shared.codexSessionToDict(codexSession)
                if let paneCapture {
                    dict["pane_capture"] = paneCapture
                }
                let event = WebSocketEvent(type: .sessionUpdated, session: dict)
                WebSocketManager.shared.broadcast(event: event)
            }
        }
    }

    private func handleTokenUsage(cwd: String?, json: [String: Any]) {
        guard let cwd = cwd else {
            DebugLog.log("[CodexStatusReceiver] codex-token-usage without cwd")
            return
        }

        guard let tokenData = json["token_usage"] as? [String: Any] else {
            DebugLog.log("[CodexStatusReceiver] codex-token-usage without token_usage payload")
            return
        }

        let input = tokenData["input_tokens"] as? Int ?? 0
        let output = tokenData["output_tokens"] as? Int ?? 0
        let total = tokenData["total_tokens"] as? Int ?? (input + output)
        let usage = CodexTokenUsage(inputTokens: input, outputTokens: output, totalTokens: total)
        tokenUsageByCwd[cwd] = usage

        objectWillChange.send()
        DebugLog.log("[CodexStatusReceiver] Token usage updated: \(cwd) -> \(usage.formattedTotal)")
    }

    private func handleSessionStart(cwd: String?, json: [String: Any]) {
        guard let cwd = cwd else {
            DebugLog.log("[CodexStatusReceiver] codex-session-start without cwd")
            return
        }

        let threadId = json["thread-id"] as? String
        let now = Date()

        statusByCwd[cwd] = CodexSessionStatus(
            status: .running,
            waitingReason: nil,
            lastEventAt: now,
            threadId: threadId,
            lastSeenAt: now,
            stoppedAt: nil,
            isSyntheticStopped: false
        )

        objectWillChange.send()
        CodexObserver.invalidateCache()
        DebugLog.log("[CodexStatusReceiver] Session started: \(cwd) thread=\(threadId ?? "nil")")
    }

    // MARK: - Token Usage Query

    /// Get token usage for a cwd (webhook priority, then fallback to session file)
    func getTokenUsage(for cwd: String) -> CodexTokenUsage? {
        return tokenUsageByCwd[cwd]
    }

    // MARK: - Status Query

    /// Get effective status for a cwd (applies timeout logic)
    /// - Parameter cwd: Working directory
    /// - Returns: Current status or .running if unknown
    func getStatus(for cwd: String) -> CodexStatus {
        applyTimeTransitions(now: Date())
        guard let sessionStatus = statusByCwd[cwd] else {
            return .running
        }
        return sessionStatus.status
    }

    /// Get full status info for a cwd
    func getSessionStatus(for cwd: String) -> CodexSessionStatus? {
        applyTimeTransitions(now: Date())
        return statusByCwd[cwd]
    }

    /// Get waiting reason for a cwd
    func getWaitingReason(for cwd: String) -> CodexWaitingReason? {
        guard let sessionStatus = getSessionStatus(for: cwd),
              sessionStatus.status == .waitingInput else {
            return nil
        }
        return sessionStatus.waitingReason ?? .unknown
    }

    // MARK: - Acknowledge

    /// Mark a Codex session as acknowledged (user clicked/focused it)
    func acknowledge(cwd: String) {
        acknowledgedCwds.insert(cwd)
        objectWillChange.send()
    }

    /// Check if a Codex session has been acknowledged
    func isAcknowledged(cwd: String) -> Bool {
        acknowledgedCwds.contains(cwd)
    }

    /// Remove status tracking for a cwd (when session ends)
    func removeStatus(for cwd: String) {
        statusByCwd.removeValue(forKey: cwd)
        acknowledgedCwds.remove(cwd)
        lastPaneCapture.removeValue(forKey: cwd)
        lastAlertTime.removeValue(forKey: cwd)
        tokenUsageByCwd.removeValue(forKey: cwd)
        objectWillChange.send()
    }

    /// Clear all status tracking
    func clearAll() {
        statusByCwd.removeAll()
        acknowledgedCwds.removeAll()
        lastPaneCapture.removeAll()
        lastAlertTime.removeAll()
        tokenUsageByCwd.removeAll()
        objectWillChange.send()
    }

    /// Reconcile internal status tracking with currently active Codex sessions.
    func reconcileActiveSessions(_ activeSessions: [CodexSession], now: Date = Date()) {
        let activeCwds = Set(activeSessions.map(\.cwd))

        for cwd in activeCwds {
            if var tracked = statusByCwd[cwd] {
                tracked.lastSeenAt = now
                if tracked.status == .stopped {
                    tracked.status = .running
                    tracked.waitingReason = nil
                    tracked.stoppedAt = nil
                    tracked.isSyntheticStopped = false
                    tracked.lastEventAt = now
                    // Clear autofocus and alert cooldowns when Codex session returns to running
                    let codexId = "codex:\(activeSessions.first { $0.cwd == cwd }?.pid ?? 0)"
                    AutofocusManager.shared.clearCooldown(sessionId: codexId)
                    lastAlertTime.removeValue(forKey: cwd)
                } else if tracked.status == .waitingInput {
                    // Recover only after the waiting markers disappear. Simple hash changes
                    // are not enough because moving selection inside a question prompt
                    // should stay yellow.
                    if let session = activeSessions.first(where: { $0.cwd == cwd }),
                       let currentCapture = capturePane(for: session) {
                        let currentHash = Self.hashPaneTail(currentCapture)
                        if Self.isLikelyWaitingScreen(currentCapture, waitingReason: tracked.waitingReason) {
                            lastPaneCapture[cwd] = currentHash
                        } else if Self.shouldRecoverToRunning(
                            previousPaneHash: lastPaneCapture[cwd],
                            currentPaneCapture: currentCapture,
                            waitingReason: tracked.waitingReason
                        ) {
                            tracked.status = .running
                            tracked.waitingReason = nil
                            tracked.lastEventAt = now
                            lastPaneCapture.removeValue(forKey: cwd)
                            acknowledgedCwds.remove(cwd)
                            DebugLog.log("[CodexStatusReceiver] Waiting markers disappeared, recovering to running: \(cwd)")

                            // Invalidate CodexObserver cache to trigger WebSocket update
                            CodexObserver.invalidateCache()
                        }
                    }
                }
                statusByCwd[cwd] = tracked
            } else {
                statusByCwd[cwd] = CodexSessionStatus(
                    status: .running,
                    waitingReason: nil,
                    lastEventAt: now,
                    threadId: nil,
                    lastSeenAt: now,
                    stoppedAt: nil,
                    isSyntheticStopped: false
                )
            }
        }

        // Mark missing sessions as synthetic stopped after grace period.
        for cwd in statusByCwd.keys where !activeCwds.contains(cwd) {
            guard var tracked = statusByCwd[cwd] else { continue }
            let missingDuration = now.timeIntervalSince(tracked.lastSeenAt)
            if tracked.status != .stopped && missingDuration >= pidDisappearGrace {
                tracked.status = .stopped
                tracked.waitingReason = nil
                tracked.stoppedAt = now
                tracked.isSyntheticStopped = true
                statusByCwd[cwd] = tracked
                DebugLog.log("[CodexStatusReceiver] Synthetic stopped: \(cwd)")
            }
        }

        applyTimeTransitions(now: now)
        objectWillChange.send()
    }

    /// Return active sessions augmented with synthetic placeholders for tracked waiting/stopped states.
    func withSyntheticStoppedSessions(activeSessions: [CodexSession], now: Date = Date()) -> [CodexSession] {
        reconcileActiveSessions(activeSessions, now: now)

        var result = activeSessions
        let activeCwds = Set(activeSessions.map(\.cwd))
        for (cwd, tracked) in statusByCwd where tracked.status != .running && !activeCwds.contains(cwd) {
            var synthetic = CodexSession(pid: 0, cwd: cwd)
            synthetic.terminalApp = "Codex"
            synthetic.sessionId = tracked.threadId
            result.append(synthetic)
        }

        return result.sorted {
            let lhsStopped = statusByCwd[$0.cwd]?.status == .stopped
            let rhsStopped = statusByCwd[$1.cwd]?.status == .stopped
            if lhsStopped != rhsStopped {
                return !lhsStopped && rhsStopped
            }
            return $0.cwd < $1.cwd
        }
    }

    /// Snapshot for diagnostics/tests.
    func getRenderableStatuses(now: Date = Date()) -> [String: CodexSessionStatus] {
        applyTimeTransitions(now: now)
        return statusByCwd
    }

    private func applyTimeTransitions(now: Date) {
        for (cwd, tracked) in statusByCwd {
            if tracked.status == .stopped,
               let stoppedAt = tracked.stoppedAt,
               now.timeIntervalSince(stoppedAt) > stoppedRetention {
                statusByCwd.removeValue(forKey: cwd)
            }
        }
    }

    // MARK: - Reason Inference

    /// Infer waiting reason from raw Codex notify payload.
    /// Default is yellow (stop). Red is allowed only for high-confidence signals.
    static func inferWaitingReason(from json: [String: Any], paneCapture: String? = nil) -> CodexWaitingReason {
        detectWaitingInput(from: json, paneCapture: paneCapture).reason
    }

    static func detectWaitingInput(from json: [String: Any], paneCapture: String? = nil) -> (reason: CodexWaitingReason, source: String) {
        if let type = (json["notification_type"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
           type == "permission_prompt" {
            return (.permissionPrompt, "notify")
        }

        if CodexRedSignalDetector.isHighConfidencePermissionPrompt(paneCapture: paneCapture) {
            return (.permissionPrompt, "pane_permission_prompt")
        }

        if CodexQuestionSignalDetector.isHighConfidenceQuestionPrompt(paneCapture: paneCapture) {
            return (.stop, "pane_question_prompt")
        }

        return (.stop, "default")
    }

    static func isLikelyWaitingScreen(_ paneCapture: String?, waitingReason: CodexWaitingReason?) -> Bool {
        guard let paneCapture, !paneCapture.isEmpty else { return false }
        if waitingReason == .permissionPrompt {
            return CodexRedSignalDetector.isHighConfidencePermissionPrompt(paneCapture: paneCapture)
        }
        return CodexQuestionSignalDetector.isHighConfidenceQuestionPrompt(paneCapture: paneCapture)
            || CodexRedSignalDetector.isHighConfidencePermissionPrompt(paneCapture: paneCapture)
    }

    static func shouldRecoverToRunning(
        previousPaneHash: Int?,
        currentPaneCapture: String,
        waitingReason: CodexWaitingReason?
    ) -> Bool {
        guard let previousPaneHash else { return false }
        guard !isLikelyWaitingScreen(currentPaneCapture, waitingReason: waitingReason) else {
            return false
        }
        return hashPaneTail(currentPaneCapture) != previousPaneHash
    }

    /// Hash the last N lines of pane output for comparison
    static func hashPaneTail(_ content: String, tailLines: Int = 10) -> Int {
        let lines = content.split(separator: "\n", omittingEmptySubsequences: false)
        let tail = lines.suffix(tailLines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .joined(separator: "\n")
        return tail.hashValue
    }

    private func capturePane(for codexSession: CodexSession?) -> String? {
        guard let codexSession,
              let tmuxSession = codexSession.tmuxSession,
              let tmuxWindow = codexSession.tmuxWindow,
              let tmuxPane = codexSession.tmuxPane else {
            return nil
        }
        let target = "\(tmuxSession):\(tmuxWindow).\(tmuxPane)"
        return TmuxHelper.capturePane(target: target, socketPath: codexSession.tmuxSocketPath)
    }
}

private enum CodexRedSignalDetector {
    static func isHighConfidencePermissionPrompt(paneCapture: String?) -> Bool {
        guard let paneCapture, !paneCapture.isEmpty else { return false }
        let normalized = paneCapture
            .lowercased()
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        let hasPrompt = normalized.contains("implement this plan?")
        let hasYesOption = normalized.contains("1. yes, implement this")
        let hasNoOption = normalized.contains("2. no, stay in plan mode")
        return hasPrompt && hasYesOption && hasNoOption
    }
}

private enum CodexQuestionSignalDetector {
    private static let questionCounterRegex = try! NSRegularExpression(pattern: #"question\s+\d+\s*/\s*\d+"#)

    static func isHighConfidenceQuestionPrompt(paneCapture: String?) -> Bool {
        guard let paneCapture, !paneCapture.isEmpty else { return false }
        let normalized = paneCapture
            .lowercased()
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        let range = NSRange(normalized.startIndex..<normalized.endIndex, in: normalized)
        let hasQuestionCounter = questionCounterRegex.firstMatch(in: normalized, options: [], range: range) != nil
        let hasSubmitHint = normalized.contains("enter to submit answer")
        let hasUnanswered = normalized.contains("unanswered")
        let hasNotesHint = normalized.contains("tab to add notes")

        return hasQuestionCounter && (hasSubmitHint || hasUnanswered || hasNotesHint)
    }
}

/// Status tracking for a single Codex session
struct CodexSessionStatus {
    var status: CodexStatus
    var waitingReason: CodexWaitingReason?
    var lastEventAt: Date
    var threadId: String?
    var lastSeenAt: Date
    var stoppedAt: Date?
    var isSyntheticStopped: Bool
}
