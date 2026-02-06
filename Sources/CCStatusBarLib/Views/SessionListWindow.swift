import SwiftUI
import AppKit

// MARK: - Cursor Tracking (NSTrackingArea-based, reliable)

/// NSViewRepresentable for reliable cursor changes using NSTrackingArea
struct CursorArea: NSViewRepresentable {
    let cursor: NSCursor

    func makeNSView(context: Context) -> CursorTrackingView {
        CursorTrackingView(cursor: cursor)
    }

    func updateNSView(_ nsView: CursorTrackingView, context: Context) {
        nsView.cursor = cursor
        nsView.resetCursorRects()
    }
}

/// NSView that uses resetCursorRects for reliable cursor changes
class CursorTrackingView: NSView {
    var cursor: NSCursor = .arrow

    init(cursor: NSCursor) {
        self.cursor = cursor
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: cursor)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        return nil  // Pass through mouse events to SwiftUI gestures
    }
}

// MARK: - Window Controller

/// Controller for managing the floating session list window
@MainActor
final class SessionListWindowController {
    static let shared = SessionListWindowController()

    private var panel: NSPanel?
    private weak var observer: SessionObserver?

    /// Tracks if user has manually resized the window
    private var userHasResized = false
    /// Session count when user resized (to detect significant changes)
    private var sessionCountAtResize = 0

    private init() {}

    var isVisible: Bool { panel?.isVisible ?? false }

    func showWindow(observer: SessionObserver) {
        self.observer = observer

        if panel == nil {
            let view = SessionListWindowView(observer: observer)
            let hostingController = NSHostingController(rootView: view)

            let newPanel = NSPanel(contentViewController: hostingController)
            newPanel.styleMask = [.borderless, .resizable, .utilityWindow, .nonactivatingPanel]
            newPanel.level = .floating
            newPanel.hidesOnDeactivate = false
            newPanel.isMovableByWindowBackground = true
            newPanel.isOpaque = false
            newPanel.backgroundColor = .clear

            // Dynamic height based on total session count (CC + Codex)
            let codexCount = AppSettings.showCodexSessions ? observer.codexSessions.count : 0
            let sessionCount = observer.sessions.count + codexCount
            let height = Self.calculateWindowHeight(sessionCount: sessionCount)
            let fixedWidth: CGFloat = 260
            newPanel.setContentSize(NSSize(width: fixedWidth, height: height))
            newPanel.minSize = NSSize(width: fixedWidth, height: 100)
            newPanel.maxSize = NSSize(width: fixedWidth, height: CGFloat.greatestFiniteMagnitude)
            newPanel.setFrameAutosaveName("SessionListWindow")

            panel = newPanel
        } else {
            // Re-showing: reset flag and update size
            userHasResized = false
            let codexCount = AppSettings.showCodexSessions ? observer.codexSessions.count : 0
            updateWindowSize(sessionCount: observer.sessions.count + codexCount)
        }

        panel?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func closeWindow() {
        panel?.close()
    }

    func updateWindowSize(sessionCount: Int) {
        guard let panel = panel else { return }

        // Skip auto-resize if user has manually resized
        // Reset flag if session count changed significantly (±3)
        if userHasResized {
            let diff = abs(sessionCount - sessionCountAtResize)
            if diff >= 3 {
                userHasResized = false
            } else {
                return
            }
        }

        let height = Self.calculateWindowHeight(sessionCount: sessionCount)
        var frame = panel.frame
        let heightDiff = height - frame.height
        frame.size.height = height
        frame.origin.y -= heightDiff  // Keep top position stable
        panel.setFrame(frame, display: true, animate: true)
    }

    /// Called when user manually resizes the window
    func markUserResized(sessionCount: Int) {
        userHasResized = true
        sessionCountAtResize = sessionCount
    }

    /// Get current window height for drag gesture start
    func getCurrentHeight() -> CGFloat {
        return panel?.frame.height ?? 0
    }

    /// Set window height to absolute value (for drag gesture)
    func setWindowHeight(_ newHeight: CGFloat, sessionCount: Int) {
        guard let panel = panel else { return }
        var frame = panel.frame
        let clampedHeight = max(panel.minSize.height, min(panel.maxSize.height, newHeight))
        let heightDiff = clampedHeight - frame.height
        frame.size.height = clampedHeight
        frame.origin.y -= heightDiff  // Keep top position stable
        panel.setFrame(frame, display: true, animate: false)

        // Mark as user-resized
        markUserResized(sessionCount: sessionCount)
    }

    private static func calculateWindowHeight(sessionCount: Int) -> CGFloat {
        // Actual layout measurements:
        // - Filter bar: ~36px (padding.top(8) + button(~20) + padding.bottom(4) + spacing)
        // - Icon: 48px + padding.vertical(10*2) = 68px per row
        // - LazyVStack spacing: 6px between rows
        // - ScrollView padding: top(10) + bottom(10) = 20px
        // - ResizeHandle: 16px (now separate, not overlapping)
        let filterBarHeight: CGFloat = 36
        let rowHeight: CGFloat = 68
        let rowSpacing: CGFloat = 6
        let scrollViewPadding: CGFloat = 20
        let resizeHandleHeight: CGFloat = 16

        let n = max(sessionCount, 1)
        let contentHeight = filterBarHeight
            + scrollViewPadding
            + (CGFloat(n) * rowHeight)
            + (n > 1 ? CGFloat(n - 1) * rowSpacing : 0)
            + resizeHandleHeight

        let minHeight: CGFloat = 100

        // Use 90% of screen's visible height as maximum
        let screenHeight = NSScreen.main?.visibleFrame.height ?? 800
        let maxHeight = screenHeight * 0.9

        return min(max(contentHeight, minHeight), maxHeight)
    }
}

// MARK: - SwiftUI Views

struct SessionListWindowView: View {
    @ObservedObject var observer: SessionObserver
    @State private var dragStartHeight: CGFloat = 0
    @AppStorage("showClaudeCodeSessions", store: AppSettings.userDefaultsStore)
    private var showCC: Bool = true
    @AppStorage("showCodexSessions", store: AppSettings.userDefaultsStore)
    private var showCodex: Bool = true

    private var filteredCCSessions: [Session] {
        showCC ? observer.sessions : []
    }

    private var filteredCodexSessions: [CodexSession] {
        showCodex ? observer.codexSessions : []
    }

    private var totalSessionCount: Int {
        filteredCCSessions.count + filteredCodexSessions.count
    }

    var body: some View {
        VStack(spacing: 0) {
            // Main content with clipShape
            Group {
                VStack(spacing: 0) {
                    // Filter toggle bar
                    HStack(spacing: 8) {
                        FilterToggleButton(label: "CC", isOn: showCC) {
                            showCC.toggle()
                        }
                        FilterToggleButton(label: "Codex", isOn: showCodex) {
                            showCodex.toggle()
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 10)
                    .padding(.top, 8)
                    .padding(.bottom, 4)

                    if filteredCCSessions.isEmpty && filteredCodexSessions.isEmpty {
                        VStack(spacing: 16) {
                            Image(systemName: "tray")
                                .font(.system(size: 36, weight: .light))
                                .foregroundColor(.gray)
                            Text("No active sessions")
                                .font(.system(size: 13))
                                .foregroundColor(.gray)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ScrollView {
                            LazyVStack(spacing: 6) {
                                ForEach(filteredCCSessions) { session in
                                    PinnedSessionRowView(session: session, observer: observer)
                                        .id("\(session.id)-\(session.updatedAt.timeIntervalSince1970)-\(session.status)")
                                }
                                ForEach(filteredCodexSessions) { codexSession in
                                    PinnedCodexSessionRowView(codexSession: codexSession)
                                }
                            }
                            .padding(.horizontal, 6)
                            .padding(.vertical, 10)
                        }
                    }
                }
            }
            .background(Color(nsColor: NSColor(calibratedWhite: 0.12, alpha: 0.95)))
            .clipShape(RoundedRectangle(cornerRadius: 12))

            // Resize handle below (not overlapping content)
            ResizeHandleView(sessionCount: totalSessionCount, dragStartHeight: $dragStartHeight)
        }
        .onChange(of: totalSessionCount) { newCount in
            SessionListWindowController.shared.updateWindowSize(sessionCount: newCount)
        }
    }
}

/// Capsule-style filter toggle button (similar to macOS Messages filter bar)
struct FilterToggleButton: View {
    let label: String
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(isOn ? .white : Color(white: 0.5))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(
                    Capsule()
                        .fill(isOn ? Color.accentColor : Color.clear)
                )
                .overlay(
                    Capsule()
                        .stroke(isOn ? Color.clear : Color(white: 0.35), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }
}

/// Resize handle view at the bottom of the floating window
struct ResizeHandleView: View {
    let sessionCount: Int
    @Binding var dragStartHeight: CGFloat
    @State private var isHovering = false
    @GestureState private var isDragging = false  // GestureState for auto-reset

    var body: some View {
        VStack(spacing: 0) {
            // Visual grip indicator
            HStack(spacing: 2) {
                ForEach(0..<3, id: \.self) { _ in
                    Circle()
                        .fill(Color(white: isHovering || isDragging ? 0.5 : 0.3))
                        .frame(width: 4, height: 4)
                }
            }
            .frame(height: 12)
            .frame(maxWidth: .infinity)
            .background(Color.clear)
        }
        .frame(height: 16)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .background(CursorArea(cursor: .resizeUpDown))
        .onHover { hovering in
            isHovering = hovering
        }
        .gesture(
            DragGesture(minimumDistance: 1)
                .updating($isDragging) { _, state, _ in
                    state = true
                }
                .onChanged { value in
                    if dragStartHeight == 0 {
                        dragStartHeight = SessionListWindowController.shared.getCurrentHeight()
                    }
                    let newHeight = dragStartHeight + value.translation.height
                    SessionListWindowController.shared.setWindowHeight(
                        newHeight,
                        sessionCount: sessionCount
                    )
                }
                .onEnded { _ in
                    dragStartHeight = 0
                }
        )
    }
}

struct PinnedSessionRowView: View {
    let session: Session
    @ObservedObject var observer: SessionObserver
    @State private var isHovered = false
    @State private var isPressed = false

    // Watch for sessionDisplayMode changes to trigger re-render
    @AppStorage("sessionDisplayMode", store: AppSettings.userDefaultsStore)
    private var displayModeRaw: String = "project"

    private var env: FocusEnvironment {
        EnvironmentResolver.shared.resolve(session: session)
    }

    /// Computed display text based on sessionDisplayMode setting
    private var displayText: String {
        let mode = SessionDisplayMode(rawValue: displayModeRaw) ?? .projectName
        return session.displayText(for: mode)
    }

    var body: some View {
        HStack(spacing: 8) {
            // Terminal icon with badge
            ZStack(alignment: .topTrailing) {
                if let nsImage = IconManager.shared.iconWithBadge(for: env, size: 48, badgeText: "CC") {
                    Image(nsImage: nsImage)
                        .resizable()
                        .frame(width: 48, height: 48)
                } else {
                    Image(systemName: "terminal")
                        .font(.system(size: 28))
                        .foregroundColor(.gray)
                        .frame(width: 48, height: 48)
                }

                // Status dot overlay
                Circle()
                    .fill(statusColor)
                    .frame(width: 12, height: 12)
                    .overlay(
                        Circle()
                            .stroke(Color(nsColor: NSColor(calibratedWhite: 0.15, alpha: 1.0)), lineWidth: 2)
                    )
                    .offset(x: 0, y: 0)
            }

            // Session info
            VStack(alignment: .leading, spacing: 3) {
                Text(displayText)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)
                    .lineLimit(1)

                Text(session.displayPath)
                    .font(.system(size: 11))
                    .foregroundColor(Color(white: 0.6))
                    .lineLimit(1)

                HStack(spacing: 4) {
                    Text(session.environmentLabel)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(Color(white: 0.5))

                    Text("•")
                        .font(.system(size: 10))
                        .foregroundColor(Color(white: 0.4))

                    Text(displayStatus.label)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(statusColor)
                }
            }

            Spacer()
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isHovered
                    ? Color(white: 0.28)
                    : Color(white: 0.18))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(white: 0.25), lineWidth: 1)
        )
        .contentShape(Rectangle())
        .background(CursorArea(cursor: .pointingHand))
        .scaleEffect(isPressed ? 0.96 : 1.0)
        .animation(.easeOut(duration: 0.05), value: isPressed)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
        .onTapGesture {
            withAnimation(.easeOut(duration: 0.05)) {
                isPressed = true
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                withAnimation(.easeOut(duration: 0.05)) {
                    isPressed = false
                }
                focusSession()
            }
        }
        .contextMenu {
            Button("Open in Finder") {
                NSWorkspace.shared.open(URL(fileURLWithPath: session.cwd))
            }
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(session.cwd, forType: .string)
            }
            if let tty = session.tty, !tty.isEmpty {
                Button("Copy TTY") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(tty, forType: .string)
                }
            }
        }
    }

    private var displayStatus: SessionStatus {
        let isAcknowledged = observer.isAcknowledged(sessionId: session.id)
        if isAcknowledged && session.status == .waitingInput {
            return .running
        }
        return session.status
    }

    private var statusColor: Color {
        let isAcknowledged = observer.isAcknowledged(sessionId: session.id)

        // Check if tmux session is detached
        var isTmuxDetached = false
        if let tty = session.tty, let paneInfo = TmuxHelper.getPaneInfo(for: tty) {
            isTmuxDetached = !TmuxHelper.isSessionAttached(paneInfo.session)
        }

        if isTmuxDetached {
            return Color(white: 0.4)
        }

        if !isAcknowledged && session.status == .waitingInput {
            return session.waitingReason == .permissionPrompt
                ? Color(red: 1.0, green: 0.3, blue: 0.3)
                : Color(red: 1.0, green: 0.7, blue: 0.2)
        }

        switch displayStatus {
        case .running:
            return Color(red: 0.3, green: 0.85, blue: 0.4)
        case .waitingInput:
            return Color(red: 1.0, green: 0.7, blue: 0.2)
        case .stopped:
            return Color(white: 0.5)
        }
    }

    private func focusSession() {
        FocusManager.shared.focus(session: session)
        observer.acknowledge(sessionId: session.id)
        DebugLog.log("[SessionListWindow] Focused session: \(session.projectName)")
    }
}

struct PinnedCodexSessionRowView: View {
    let codexSession: CodexSession
    @State private var isHovered = false
    @State private var isPressed = false

    // Watch for sessionDisplayMode changes to trigger re-render
    @AppStorage("sessionDisplayMode", store: AppSettings.userDefaultsStore)
    private var displayModeRaw: String = "project"

    /// Computed display text based on sessionDisplayMode setting
    private var displayText: String {
        let mode = SessionDisplayMode(rawValue: displayModeRaw) ?? .projectName
        return codexSession.displayText(for: mode)
    }

    private var env: FocusEnvironment {
        CodexFocusHelper.resolveEnvironmentForIcon(session: codexSession)
    }

    private var status: CodexStatus {
        CodexStatusReceiver.shared.getStatus(for: codexSession.cwd)
    }

    var body: some View {
        HStack(spacing: 8) {
            // Terminal icon with badge
            ZStack(alignment: .topTrailing) {
                if let nsImage = IconManager.shared.iconWithBadge(for: env, size: 48, badgeText: "Cdx") {
                    Image(nsImage: nsImage)
                        .resizable()
                        .frame(width: 48, height: 48)
                } else {
                    Image(systemName: "terminal")
                        .font(.system(size: 28))
                        .foregroundColor(.gray)
                        .frame(width: 48, height: 48)
                }

                // Status dot overlay
                Circle()
                    .fill(statusColor)
                    .frame(width: 12, height: 12)
                    .overlay(
                        Circle()
                            .stroke(Color(nsColor: NSColor(calibratedWhite: 0.15, alpha: 1.0)), lineWidth: 2)
                    )
                    .offset(x: 0, y: 0)
            }

            // Session info
            VStack(alignment: .leading, spacing: 3) {
                Text(displayText)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)
                    .lineLimit(1)

                Text(displayPath)
                    .font(.system(size: 11))
                    .foregroundColor(Color(white: 0.6))
                    .lineLimit(1)

                HStack(spacing: 4) {
                    Text(env.displayName)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(Color(white: 0.5))

                    Text("•")
                        .font(.system(size: 10))
                        .foregroundColor(Color(white: 0.4))

                    Text(statusLabel)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(statusColor)
                }
            }

            Spacer()
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isHovered
                    ? Color(white: 0.28)
                    : Color(white: 0.18))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(white: 0.25), lineWidth: 1)
        )
        .contentShape(Rectangle())
        .background(CursorArea(cursor: .pointingHand))
        .scaleEffect(isPressed ? 0.96 : 1.0)
        .animation(.easeOut(duration: 0.05), value: isPressed)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
        .onTapGesture {
            withAnimation(.easeOut(duration: 0.05)) {
                isPressed = true
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                withAnimation(.easeOut(duration: 0.05)) {
                    isPressed = false
                }
                focusCodexSession()
            }
        }
        .contextMenu {
            Button("Open in Finder") {
                NSWorkspace.shared.open(URL(fileURLWithPath: codexSession.cwd))
            }
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(codexSession.cwd, forType: .string)
            }
            if let tty = codexSession.tty, !tty.isEmpty {
                Button("Copy TTY") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(tty, forType: .string)
                }
            }
        }
    }

    private var displayPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if codexSession.cwd.hasPrefix(home) {
            return "~" + codexSession.cwd.dropFirst(home.count)
        }
        return codexSession.cwd
    }

    private var statusLabel: String {
        status == .waitingInput ? "Waiting" : "Running"
    }

    private var statusColor: Color {
        status == .waitingInput
            ? Color(red: 1.0, green: 0.7, blue: 0.2)
            : Color(red: 0.3, green: 0.85, blue: 0.4)
    }

    private func focusCodexSession() {
        CodexFocusHelper.focus(session: codexSession)
        DebugLog.log("[SessionListWindow] Focused Codex session: \(codexSession.projectName)")
    }
}
