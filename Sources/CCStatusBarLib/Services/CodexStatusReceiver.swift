import Foundation
import Combine

/// Status of a Codex session
enum CodexStatus: String, Codable {
    case running
    case waitingInput = "waiting_input"
    case stopped
}

/// Reason of Codex waiting_input for color distinction (red/yellow/gray)
enum CodexWaitingReason: String, Codable {
    case permissionPrompt = "permission_prompt"  // red
    case stop = "stop"                           // yellow
    case idle = "idle"                           // gray (alive but idle prompt)
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
    private let stoppedRetention: TimeInterval = 5.0
    /// Safety valve: recover waiting_input to running if stuck longer than this (seconds)
    private let waitingRecoveryTimeout: TimeInterval = 30.0

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
        case "codex-stop":
            handleCodexStop(cwd: cwd, json: json)
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
        let stateSource = Self.stateSource(for: waitingDetection.source)

        statusByCwd[cwd] = CodexSessionStatus(
            status: .waitingInput,
            waitingReason: waitingReason,
            lastEventAt: now,
            threadId: threadId,
            lastSeenAt: now,
            stoppedAt: nil,
            isSyntheticStopped: false,
            stateSource: stateSource
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

        // Fire alert/autofocus for all waiting transitions including idle.
        // idle = task completed, user should be notified.
        // Cooldown prevents repeated firing for the same session.
        if let codexSession = codexSession {
            if let lastFire = lastAlertTime[cwd], now.timeIntervalSince(lastFire) < alertCooldown {
                DebugLog.log("[CodexStatusReceiver] Alert throttled for \(cwd) (\(String(format: "%.1f", now.timeIntervalSince(lastFire)))s < \(Int(alertCooldown))s)")
            } else {
                lastAlertTime[cwd] = now
                SoundPlayer.runAlertCommand(for: codexSession, waitingReason: waitingReason)
            }

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
            isSyntheticStopped: false,
            stateSource: .webhook
        )

        // In hooks mode, register session in CodexHooksSessionStore
        if CodexObserver.useHooksMode {
            let sessionId = json["session_id"] as? String ?? threadId
            let model = json["model"] as? String
            CodexHooksSessionStore.shared.registerSession(cwd: cwd, sessionId: sessionId, model: model)
        }

        objectWillChange.send()
        CodexObserver.invalidateCache()
        DebugLog.log("[CodexStatusReceiver] Session started: \(cwd) thread=\(threadId ?? "nil")")
    }

    private func handleCodexStop(cwd: String?, json: [String: Any]) {
        guard let cwd = cwd else {
            DebugLog.log("[CodexStatusReceiver] codex-stop without cwd")
            return
        }

        let now = Date()

        // Stop = turn complete = idle transition (task completed)
        if var tracked = statusByCwd[cwd] {
            tracked.status = .waitingInput
            tracked.waitingReason = .idle
            tracked.lastEventAt = now
            statusByCwd[cwd] = tracked
        } else {
            statusByCwd[cwd] = CodexSessionStatus(
                status: .waitingInput,
                waitingReason: .idle,
                lastEventAt: now,
                threadId: json["session_id"] as? String,
                lastSeenAt: now,
                stoppedAt: nil,
                isSyntheticStopped: false,
                stateSource: .webhook
            )
        }

        DebugLog.log("[CodexStatusReceiver] Codex stop (idle): \(cwd)")

        // Fire alert + autofocus for task completion
        let codexSession = CodexObserver.getCodexSession(for: cwd)
        if let codexSession = codexSession {
            if let lastFire = lastAlertTime[cwd], now.timeIntervalSince(lastFire) < alertCooldown {
                DebugLog.log("[CodexStatusReceiver] Idle alert throttled for \(cwd)")
            } else {
                lastAlertTime[cwd] = now
                SoundPlayer.runAlertCommand(for: codexSession, waitingReason: CodexWaitingReason.idle)
            }
            AutofocusManager.shared.handleCodexWaitingTransition(codexSession, reason: .idle)
        }

        objectWillChange.send()
        CodexObserver.invalidateCache()
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
                    tracked.stateSource = .paneGuess
                    // Clear autofocus and alert cooldowns when Codex session returns to running
                    let codexId = "codex:\(activeSessions.first { $0.cwd == cwd }?.pid ?? 0)"
                    AutofocusManager.shared.clearCooldown(sessionId: codexId)
                    lastAlertTime.removeValue(forKey: cwd)
                } else if tracked.status == .waitingInput {
                    // Safety valve: recover to running if waiting_input stuck too long
                    let waitingDuration = now.timeIntervalSince(tracked.lastEventAt)
                    if waitingDuration > waitingRecoveryTimeout {
                        // Check pane before recovering — don't recover if still waiting
                        if let session = activeSessions.first(where: { $0.cwd == cwd }),
                           let currentCapture = capturePane(for: session),
                           let detection = Self.detectWaitingInputFromPane(currentCapture) {
                            if detection.reason == .idle && tracked.waitingReason != .idle {
                                // Transitioned to idle — task completed
                                tracked.waitingReason = .idle
                                tracked.lastEventAt = now
                                tracked.stateSource = .paneGuess
                                lastPaneCapture[cwd] = Self.hashPaneTail(currentCapture)
                                DebugLog.log("[CodexStatusReceiver] Waiting transitioned to idle: \(cwd)")
                                // Fire alert + autofocus for task completion
                                if let session = activeSessions.first(where: { $0.cwd == cwd }) {
                                    if let lastFire = lastAlertTime[cwd], now.timeIntervalSince(lastFire) < alertCooldown {
                                        DebugLog.log("[CodexStatusReceiver] Idle alert throttled for \(cwd)")
                                    } else {
                                        lastAlertTime[cwd] = now
                                        SoundPlayer.runAlertCommand(for: session, waitingReason: CodexWaitingReason.idle)
                                    }
                                    AutofocusManager.shared.handleCodexWaitingTransition(session, reason: .idle)
                                }
                                CodexObserver.invalidateCache()
                            } else {
                                // Still showing same waiting markers — extend
                                tracked.lastEventAt = now
                                DebugLog.log("[CodexStatusReceiver] Waiting timeout but still waiting, extending: \(cwd)")
                            }
                        } else {
                            tracked.status = .running
                            tracked.waitingReason = nil
                            tracked.lastEventAt = now
                            lastPaneCapture.removeValue(forKey: cwd)
                            acknowledgedCwds.remove(cwd)
                            DebugLog.log("[CodexStatusReceiver] Waiting timeout (\(String(format: "%.0f", waitingDuration))s), recovering to running: \(cwd)")
                            CodexObserver.invalidateCache()
                        }
                    } else if let session = activeSessions.first(where: { $0.cwd == cwd }) {
                        // Recover only after the waiting markers disappear. Simple hash changes
                        // are not enough because moving selection inside a question prompt
                        // should stay yellow.
                        if let currentCapture = capturePane(for: session) {
                            let currentHash = Self.hashPaneTail(currentCapture)
                            if Self.isLikelyWaitingScreen(currentCapture, waitingReason: tracked.waitingReason) {
                                lastPaneCapture[cwd] = currentHash
                            } else if let detection = Self.detectWaitingInputFromPane(currentCapture),
                                      detection.reason == .idle,
                                      tracked.waitingReason != .idle {
                                // Transitioned from question/permission to idle (task completed)
                                tracked.waitingReason = .idle
                                tracked.lastEventAt = now
                                tracked.stateSource = .paneGuess
                                lastPaneCapture[cwd] = currentHash
                                DebugLog.log("[CodexStatusReceiver] Waiting transitioned to idle: \(cwd)")
                                // Fire alert + autofocus for task completion
                                if let codexSession = CodexObserver.getCodexSession(for: cwd) {
                                    if let lastFire = lastAlertTime[cwd], now.timeIntervalSince(lastFire) < alertCooldown {
                                        DebugLog.log("[CodexStatusReceiver] Idle alert throttled for \(cwd)")
                                    } else {
                                        lastAlertTime[cwd] = now
                                        SoundPlayer.runAlertCommand(for: codexSession, waitingReason: CodexWaitingReason.idle)
                                    }
                                    AutofocusManager.shared.handleCodexWaitingTransition(codexSession, reason: .idle)
                                }
                                CodexObserver.invalidateCache()
                            } else if Self.shouldRecoverToRunning(
                                previousPaneHash: lastPaneCapture[cwd],
                                currentPaneCapture: currentCapture,
                                waitingReason: tracked.waitingReason
                            ) {
                                tracked.status = .running
                                tracked.waitingReason = nil
                                tracked.lastEventAt = now
                                tracked.stateSource = .paneGuess
                                lastPaneCapture.removeValue(forKey: cwd)
                                acknowledgedCwds.remove(cwd)
                                DebugLog.log("[CodexStatusReceiver] Waiting markers disappeared, recovering to running: \(cwd)")
                                CodexObserver.invalidateCache()
                            }
                        } else {
                            DebugLog.log("[CodexStatusReceiver] capturePane failed for waiting session: \(cwd)")
                        }
                    }
                } else if tracked.status == .running {
                    // Proactive waiting detection for running sessions.
                    // Catches permission prompts, question prompts, and idle prompts
                    // even when the Codex notify event fails to fire.
                    if let session = activeSessions.first(where: { $0.cwd == cwd }),
                       let currentCapture = capturePane(for: session),
                       let detection = Self.detectWaitingInputFromPane(currentCapture) {
                        tracked.status = .waitingInput
                        tracked.waitingReason = detection.reason
                        tracked.lastEventAt = now
                        tracked.stateSource = .paneGuess
                        lastPaneCapture[cwd] = Self.hashPaneTail(currentCapture)
                        acknowledgedCwds.remove(cwd)
                        DebugLog.log("[CodexStatusReceiver] Poll detected waiting: \(cwd) reason=\(detection.reason.rawValue) source=poll_\(detection.source)")
                        CodexObserver.invalidateCache()

                        // Alert for all transitions including idle (task completed).
                        // Autofocus only for non-idle (idle = done, no need to switch).
                        let codexSession = CodexObserver.getCodexSession(for: cwd)
                        if let codexSession = codexSession {
                            if let lastFire = lastAlertTime[cwd], now.timeIntervalSince(lastFire) < alertCooldown {
                                DebugLog.log("[CodexStatusReceiver] Alert throttled for \(cwd)")
                            } else {
                                lastAlertTime[cwd] = now
                                SoundPlayer.runAlertCommand(for: codexSession, waitingReason: detection.reason)
                            }
                            AutofocusManager.shared.handleCodexWaitingTransition(codexSession, reason: detection.reason)
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
                    isSyntheticStopped: false,
                    stateSource: .paneGuess
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
                tracked.stateSource = .paneGuess
                statusByCwd[cwd] = tracked
                DebugLog.log("[CodexStatusReceiver] Synthetic stopped: \(cwd)")
            }
        }

        applyTimeTransitions(now: now)
        objectWillChange.send()
    }

    /// Return active sessions augmented with synthetic placeholders for tracked waiting/stopped states.
    ///
    /// Pure read: does NOT mutate state or fire `objectWillChange`. Safe to call from
    /// SwiftUI `body` evaluation. Callers responsible for state transitions (idle/stopped
    /// promotion, prune) must call `reconcileActiveSessions(_:)` separately on a timer
    /// or notification path — never from inside view body.
    func withSyntheticStoppedSessions(activeSessions: [CodexSession], now: Date = Date()) -> [CodexSession] {
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

    /// Detect waiting state from pane capture only (no webhook JSON).
    /// Returns nil if no waiting state detected (i.e. all detectors returned the default fallback).
    static func detectWaitingInputFromPane(_ paneCapture: String) -> (reason: CodexWaitingReason, source: String)? {
        let result = detectWaitingInput(from: [:], paneCapture: paneCapture)
        if result.source == "default" { return nil }
        return result
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

        // Question before idle — idle pattern (› + % left) is always visible,
        // so it would false-positive during active question prompts.
        // Question detector is tail-limited (15 lines) to avoid stale scrollback matches.
        if CodexQuestionSignalDetector.isHighConfidenceQuestionPrompt(paneCapture: paneCapture) {
            return (.stop, "pane_question_prompt")
        }

        if CodexIdlePromptDetector.isIdlePrompt(paneCapture: paneCapture) {
            return (.idle, "pane_idle_prompt")
        }

        return (.stop, "default")
    }

    static func stateSource(for detectionSource: String) -> SessionStateSource {
        detectionSource == "default" || detectionSource == "notify" ? .webhook : .paneGuess
    }

    static func isLikelyWaitingScreen(_ paneCapture: String?, waitingReason: CodexWaitingReason?) -> Bool {
        guard let paneCapture, !paneCapture.isEmpty else { return false }
        if waitingReason == .permissionPrompt {
            return CodexRedSignalDetector.isHighConfidencePermissionPrompt(paneCapture: paneCapture)
        }
        if waitingReason == .idle {
            return CodexIdlePromptDetector.isIdlePrompt(paneCapture: paneCapture)
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

    /// Only check the last 15 lines to avoid matching stale question markers in scrollback.
    static func isHighConfidenceQuestionPrompt(paneCapture: String?) -> Bool {
        guard let paneCapture, !paneCapture.isEmpty else { return false }
        let lines = paneCapture.components(separatedBy: .newlines)
        let tail = lines.suffix(15).joined(separator: "\n")
        let normalized = tail
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

private enum CodexIdlePromptDetector {
    /// Detect Codex idle prompt (waiting for user input at the main prompt).
    /// The idle prompt has `›` and `% left` both in the last 3 lines.
    /// During running/active states, `›` scrolls up and `% left` stays at the bottom
    /// but they are far apart — checking last 3 lines only avoids false positives.
    static func isIdlePrompt(paneCapture: String?) -> Bool {
        guard let paneCapture, !paneCapture.isEmpty else { return false }
        let lines = paneCapture.components(separatedBy: .newlines)
        let tailLines = lines.suffix(3)
        let tail = tailLines.joined(separator: "\n")
        let hasPromptArrow = tail.contains("\u{203A}")  // ›
        let hasPercentLeft = tail.contains("% left")
        return hasPromptArrow && hasPercentLeft
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
    var stateSource: SessionStateSource
}
