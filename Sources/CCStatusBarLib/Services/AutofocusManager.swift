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

    /// Typing detection: suppress autofocus while user is typing
    private var lastKeystrokeTime: Date?
    private var eventTap: CFMachPort?
    private var keyMonitor: Any?  // NSEvent fallback
    private let typingCooldown: TimeInterval = 5.0
    private var lastKeystrokeLogTime: Date?
    private let maxAutofocusRetries = 3

    /// Known terminal app bundle IDs (don't suppress autofocus for their text fields)
    private let terminalBundleIds: Set<String> = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "com.mitchellh.ghostty",
        "dev.warp.Warp-Stable",
        "io.alacritty",
        "com.github.wez.wezterm",
        "net.kovidgoyal.kitty",
    ]

    private init() {
        startKeyMonitor()
    }

    private func startKeyMonitor() {
        let eventMask: CGEventMask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.flagsChanged.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .tailAppendEventTap,
            options: .listenOnly,
            eventsOfInterest: eventMask,
            callback: { _, type, event, refcon -> Unmanaged<CGEvent>? in
                if let refcon = refcon {
                    let manager = Unmanaged<AutofocusManager>.fromOpaque(refcon).takeUnretainedValue()
                    DispatchQueue.main.async {
                        manager.lastKeystrokeTime = Date()
                        // Throttled logging: only log every 5 seconds
                        let now = Date()
                        if manager.lastKeystrokeLogTime == nil || now.timeIntervalSince(manager.lastKeystrokeLogTime!) >= 5.0 {
                            manager.lastKeystrokeLogTime = now
                            DebugLog.log("[AutofocusManager] Keystroke detected (CGEventTap)")
                        }
                    }
                }
                return Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            DebugLog.log("[AutofocusManager] Failed to create CGEventTap — falling back to NSEvent monitor")
            startNSEventKeyMonitor()
            return
        }

        eventTap = tap
        let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        DebugLog.log("[AutofocusManager] CGEventTap key monitor started")
    }

    /// Fallback: NSEvent-based key monitor (less reliable on newer macOS)
    private func startNSEventKeyMonitor() {
        keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] _ in
            DispatchQueue.main.async {
                self?.lastKeystrokeTime = Date()
            }
        }
        DebugLog.log("[AutofocusManager] NSEvent key monitor registered (fallback): \(keyMonitor != nil)")
    }

    private func isUserTyping() -> Bool {
        DebugLog.log("[AutofocusManager] isUserTyping check: lastKeystrokeTime=\(lastKeystrokeTime?.description ?? "nil")")

        // Recent keystroke check
        if let last = lastKeystrokeTime {
            let elapsed = Date().timeIntervalSince(last)
            if elapsed < typingCooldown {
                DebugLog.log("[AutofocusManager] isUserTyping: keystroke \(String(format: "%.1f", elapsed))s ago (< \(typingCooldown)s cooldown)")
                return true
            }
        }

        // Active text field check in non-terminal apps (extended cooldown window)
        if isFrontAppTextFieldActive(), let last = lastKeystrokeTime {
            let elapsed = Date().timeIntervalSince(last)
            if elapsed < typingCooldown * 2 {
                DebugLog.log("[AutofocusManager] isUserTyping: text field active + keystroke \(String(format: "%.1f", elapsed))s ago")
                return true
            }
        }

        // IME composition check (marked text in focused element)
        let systemWide = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        let focusResult = AXUIElementCopyAttributeValue(
            systemWide, kAXFocusedUIElementAttribute as CFString, &focusedRef
        )
        guard focusResult == .success else {
            DebugLog.log("[AutofocusManager] isUserTyping: failed to get focused element (error: \(focusResult.rawValue))")
            return false
        }
        var markedRangeRef: CFTypeRef?
        let markedResult = AXUIElementCopyAttributeValue(
            focusedRef as! AXUIElement, "AXMarkedTextRange" as CFString, &markedRangeRef
        )
        let hasMarkedText = markedResult == .success && markedRangeRef != nil
        if hasMarkedText {
            DebugLog.log("[AutofocusManager] isUserTyping: IME composition in progress (marked text detected)")
        }
        return hasMarkedText
    }

    /// Check if the frontmost non-terminal app has an active text input field
    private func isFrontAppTextFieldActive() -> Bool {
        guard let frontApp = NSWorkspace.shared.frontmostApplication,
              let bundleId = frontApp.bundleIdentifier else {
            return false
        }
        // Don't suppress autofocus for terminal text fields (they're always "active")
        if terminalBundleIds.contains(bundleId) {
            return false
        }
        let systemWide = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success else {
            return false
        }
        var roleRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(focusedRef as! AXUIElement, kAXRoleAttribute as CFString, &roleRef) == .success else {
            return false
        }
        let role = roleRef as? String ?? ""
        return ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"].contains(role)
    }

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

    private func performAutofocus(candidates: [Session], retryCount: Int = 0) {
        guard AppSettings.autofocusEnabled else { return }

        if isUserTyping() {
            if retryCount < maxAutofocusRetries {
                DebugLog.log("[AutofocusManager] User typing, retrying in \(typingCooldown)s (attempt \(retryCount + 1)/\(maxAutofocusRetries))")
                let retryItem = DispatchWorkItem { [weak self] in
                    self?.performAutofocus(candidates: candidates, retryCount: retryCount + 1)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + typingCooldown, execute: retryItem)
            } else {
                DebugLog.log("[AutofocusManager] User typing, max retries reached — dropping autofocus")
            }
            return
        }

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

    private func performCodexAutofocus(codexSession: CodexSession, isRed: Bool, retryCount: Int = 0) {
        guard AppSettings.autofocusEnabled else { return }

        if isUserTyping() {
            if retryCount < maxAutofocusRetries {
                DebugLog.log("[AutofocusManager] User typing, retrying Codex autofocus in \(typingCooldown)s (attempt \(retryCount + 1)/\(maxAutofocusRetries))")
                let retryItem = DispatchWorkItem { [weak self] in
                    self?.performCodexAutofocus(codexSession: codexSession, isRed: isRed, retryCount: retryCount + 1)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + typingCooldown, execute: retryItem)
            } else {
                DebugLog.log("[AutofocusManager] User typing, max retries reached — dropping Codex autofocus")
            }
            return
        }

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
