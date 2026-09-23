import Foundation

/// Shared contract with the statusline script's keep-warm fallback.
enum KeepWarm {
    /// Prefix both sides recognise, so a keep-alive turn never counts as activity.
    static let marker = "[keep-alive]"
    static let text = "\(marker) Reply with just \"ok\". Do nothing else."
    /// Poke this long before the cache would go cold.
    static let leadTime: TimeInterval = 90

    static func isKeepAlivePrompt(_ prompt: String?) -> Bool {
        prompt?.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix(marker) ?? false
    }

    /// While keep-warm is on here, the statusline script leaves poking to us.
    static var ownershipFile: URL {
        SetupManager.appSupportDir.appendingPathComponent("keepwarm.json")
    }

    /// One poke per (session, cache expiry), shared with the statusline script.
    static var lockDir: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/.cache-poke")
    }
}

enum PokeResult: Equatable {
    case sent
    case skipped(reason: String)
}

/// Keeps a Claude Code session's prompt cache warm by typing one tiny turn into
/// its tmux pane. Reading the cache resets its TTL, which costs a fraction of
/// re-caching the whole history after the cache has gone cold.
///
/// Only a fixed keep-alive text is ever sent, and only into a session that is
/// idle at an empty prompt: never into a permission prompt, a question, a
/// running tool, or a half-typed message.
enum CachePoker {
    /// Why this session must not be poked, from its hook state alone.
    static func blockingReason(_ session: Session) -> String? {
        guard session.status == .waitingInput else { return "not-idle" }
        switch session.waitingReason {
        case .stop, .idle, .none:
            break
        default:
            return "awaiting-user"
        }
        if session.isToolRunning == true { return "tool-running" }
        guard session.tty != nil else { return "no-tty" }
        return nil
    }

    /// Sessions whose cache goes cold within the lead time, idle, and last
    /// prompted by a human less than `hours` ago. Pure.
    static func dueSessions(
        _ sessions: [Session],
        now: Date,
        hours: Double,
        alreadyPoked: [String: Date]
    ) -> [Session] {
        guard hours > 0 else { return [] }
        return sessions.filter { session in
            guard let expiresAt = session.cacheExpiresAt,
                  let lastPrompt = session.lastUserPromptAt else { return false }
            let remaining = expiresAt.timeIntervalSince(now)
            guard remaining > 0, remaining <= KeepWarm.leadTime else { return false }
            guard now.timeIntervalSince(lastPrompt) < hours * 3600 else { return false }
            guard alreadyPoked[session.id] != expiresAt else { return false }
            return blockingReason(session) == nil
        }
    }

    /// When keep-warm stops for this session, if it is running.
    static func keepWarmUntil(_ session: Session, hours: Double) -> Date? {
        guard hours > 0, let lastPrompt = session.lastUserPromptAt else { return nil }
        return lastPrompt.addingTimeInterval(hours * 3600)
    }

    /// Send one keep-alive turn now, after every safety check.
    static func poke(_ session: Session) -> PokeResult {
        if let reason = blockingReason(session) { return .skipped(reason: reason) }
        guard let tty = session.tty, let pane = TmuxHelper.getPaneInfo(for: tty) else {
            return .skipped(reason: "no-tmux-pane")
        }
        let target = "\(pane.session):\(pane.window).\(pane.pane)"
        guard let capture = TmuxHelper.capturePane(target: target, lines: 0, socketPath: pane.socketPath),
              composerIsEmpty(capture) else {
            return .skipped(reason: "composer-not-empty")
        }
        if let expiresAt = session.cacheExpiresAt, !claim(sessionId: session.sessionId, expiresAt: expiresAt) {
            return .skipped(reason: "already-poked")
        }
        TmuxHelper.sendLiteralLine(pane, text: KeepWarm.text)
        DebugLog.log("[CachePoker] Keep-alive sent to \(session.projectName) (\(tty))")
        return .sent
    }

    /// Claude Code's empty prompt line is a lone `❯` near the bottom of the pane.
    static func composerIsEmpty(_ capture: String) -> Bool {
        let lines = capture.components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .suffix(8)
        return lines.contains { $0.trimmingCharacters(in: .whitespaces) == "❯" }
    }

    static func claim(sessionId: String, expiresAt: Date) -> Bool {
        let fm = FileManager.default
        let dir = KeepWarm.lockDir
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let name = "\(sessionId)-\(Int(expiresAt.timeIntervalSince1970))"
        let fd = open(dir.appendingPathComponent(name).path, O_CREAT | O_EXCL | O_WRONLY, 0o644)
        guard fd >= 0 else { return false }
        close(fd)
        if let entries = try? fm.contentsOfDirectory(atPath: dir.path) {
            for entry in entries where entry.hasPrefix("\(sessionId)-") && entry != name {
                try? fm.removeItem(at: dir.appendingPathComponent(entry))
            }
        }
        return true
    }

    /// Advertise (or withdraw) ownership of keep-warm to the statusline script.
    static func writeOwnership(enabled: Bool) {
        var state: [String: Any] = ["enabled": enabled, "pid": Int(getpid())]
        if KeepWarmServer.shared.port > 0 {
            state["api_port"] = Int(KeepWarmServer.shared.port)
        }
        guard let data = try? JSONSerialization.data(withJSONObject: state) else { return }
        try? FileManager.default.createDirectory(
            at: KeepWarm.ownershipFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: KeepWarm.ownershipFile, options: .atomic)
    }

    /// Per-session state for external callers (HTTP / CLI).
    static func status(_ session: Session, hours: Double, now: Date) -> [String: Any] {
        var dict: [String: Any] = [
            "session_id": session.sessionId,
            "project": session.projectName,
            "status": session.status.rawValue,
            "pokeable": blockingReason(session) == nil,
        ]
        dict["tty"] = session.tty
        dict["waiting_reason"] = session.waitingReason?.rawValue
        dict["blocking_reason"] = blockingReason(session)
        dict["cache_expires_at"] = session.cacheExpiresAt.map { Int($0.timeIntervalSince1970) }
        dict["recache_tokens_if_cold"] = session.cacheRecacheTokens
        dict["last_user_prompt_at"] = session.lastUserPromptAt.map { Int($0.timeIntervalSince1970) }
        dict["keep_warm_until"] = keepWarmUntil(session, hours: hours).map { Int($0.timeIntervalSince1970) }
        return dict
    }
}

/// The external surface for keep-warm, shared by the HTTP server and the CLI.
/// Callers decide which sessions to keep warm and when; this only reports
/// state and performs one safety-checked poke.
enum KeepWarmAPI {
    static func isLoopback(_ address: String?) -> Bool {
        guard let address else { return false }
        return ["127.0.0.1", "::1", "::ffff:127.0.0.1", "localhost"].contains(address)
    }

    static func findSession(_ sessions: [Session], sessionId: String?, tty: String?) -> Session? {
        let matches = sessions.filter { session in
            if let tty, !tty.isEmpty { return TmuxHelper.normalizeTTY(session.tty ?? "") == TmuxHelper.normalizeTTY(tty) }
            if let sessionId, !sessionId.isEmpty { return session.sessionId == sessionId }
            return false
        }
        return matches.first { $0.tty != nil } ?? matches.first
    }

    static func statusPayload(_ sessions: [Session], now: Date = Date()) -> [String: Any] {
        let hours = Double(AppSettings.cacheKeepWarmHours)
        return [
            "keep_warm_hours": AppSettings.cacheKeepWarmHours,
            "sessions": sessions.map { CachePoker.status($0, hours: hours, now: now) },
        ]
    }

    /// `{"session_id": "..."}` or `{"tty": "/dev/ttys012"}` → poke result.
    static func poke(body: Data, sessions: [Session]) -> (status: Int, payload: [String: Any]) {
        let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
        guard let session = findSession(sessions, sessionId: json["session_id"] as? String, tty: json["tty"] as? String) else {
            return (404, ["result": "skipped", "reason": "session-not-found"])
        }
        switch CachePoker.poke(session) {
        case .sent:
            return (200, ["result": "sent", "session_id": session.sessionId])
        case .skipped(let reason):
            return (200, ["result": "skipped", "reason": reason, "session_id": session.sessionId])
        }
    }

    static func json(_ object: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])) ?? Data("{}".utf8)
    }
}
