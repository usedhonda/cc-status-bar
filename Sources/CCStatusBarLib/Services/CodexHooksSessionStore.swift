import Foundation

/// What a Codex `SessionStart` hook tells us that the process table cannot.
struct CodexHookOverlay: Equatable {
    var sessionId: String?
    var model: String?
}

/// Metadata reported by Codex `SessionStart` hooks, keyed by cwd.
///
/// This store does **not** decide which Codex sessions exist. Existence comes
/// from the process scan in `CodexObserver`, because hook delivery is not
/// guaranteed: `codex resume --last` does not reliably emit `SessionStart`, and
/// an app restart loses every event that fired while it was down. The store
/// only fills in fields a scan cannot observe.
@MainActor
final class CodexHooksSessionStore {
    static let shared = CodexHooksSessionStore()

    /// Hook-reported metadata keyed by cwd.
    private(set) var overlaysByCwd: [String: CodexHookOverlay] = [:]

    /// Record metadata from a SessionStart hook event.
    func registerSession(cwd: String, sessionId: String?, model: String?) {
        overlaysByCwd[cwd] = CodexHookOverlay(sessionId: sessionId, model: model)
        DebugLog.log("[CodexHooksSessionStore] Hook metadata for \(cwd) session=\(sessionId ?? "nil")")
    }

    /// Drop metadata for a cwd.
    func removeSession(cwd: String) {
        if overlaysByCwd.removeValue(forKey: cwd) != nil {
            DebugLog.log("[CodexHooksSessionStore] Dropped hook metadata for \(cwd)")
        }
    }

    /// Clear all metadata
    func reset() {
        overlaysByCwd.removeAll()
    }
}
