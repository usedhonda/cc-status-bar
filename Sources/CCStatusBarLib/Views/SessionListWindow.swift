import SwiftUI
import AppKit

// MARK: - Window Controller

/// Controller for managing the floating session list window
@MainActor
final class SessionListWindowController {
    static let shared = SessionListWindowController()

    private var panel: NSPanel?
    private weak var observer: SessionObserver?

    private init() {}

    var isVisible: Bool { panel?.isVisible ?? false }

    func showWindow(observer: SessionObserver) {
        self.observer = observer

        if panel == nil {
            let view = SessionListWindowView(observer: observer)
            let hostingController = NSHostingController(rootView: view)

            let newPanel = NSPanel(contentViewController: hostingController)
            newPanel.title = "Sessions"
            newPanel.styleMask = [.titled, .closable, .utilityWindow, .nonactivatingPanel]
            newPanel.level = .floating
            newPanel.hidesOnDeactivate = false
            newPanel.isMovableByWindowBackground = true
            newPanel.backgroundColor = NSColor(calibratedWhite: 0.1, alpha: 0.95)

            // Dark titlebar
            newPanel.titlebarAppearsTransparent = true
            newPanel.titleVisibility = .hidden

            // Dynamic height based on session count
            let sessionCount = observer.sessions.count
            let height = Self.calculateWindowHeight(sessionCount: sessionCount)
            newPanel.setContentSize(NSSize(width: 260, height: height))
            newPanel.minSize = NSSize(width: 240, height: 100)
            newPanel.setFrameAutosaveName("SessionListWindow")

            panel = newPanel
        }

        panel?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func closeWindow() {
        panel?.close()
    }

    func updateWindowSize(sessionCount: Int) {
        guard let panel = panel else { return }
        let height = Self.calculateWindowHeight(sessionCount: sessionCount)
        var frame = panel.frame
        let heightDiff = height - frame.height
        frame.size.height = height
        frame.origin.y -= heightDiff  // Keep top position stable
        panel.setFrame(frame, display: true, animate: true)
    }

    private static func calculateWindowHeight(sessionCount: Int) -> CGFloat {
        // Row height: 10 padding + ~58 content + 10 padding = 78
        // Header/footer padding: 12 * 2 = 24
        let rowHeight: CGFloat = 78
        let headerPadding: CGFloat = 24
        let contentHeight = CGFloat(max(sessionCount, 1)) * rowHeight + headerPadding
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

    var body: some View {
        Group {
            if observer.sessions.isEmpty {
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
                        ForEach(observer.sessions) { session in
                            PinnedSessionRowView(session: session, observer: observer)
                                .id("\(session.id)-\(session.updatedAt.timeIntervalSince1970)-\(session.status)")
                        }
                    }
                    .padding(6)
                }
            }
        }
        .background(Color(nsColor: NSColor(calibratedWhite: 0.12, alpha: 1.0)))
        .onChange(of: observer.sessions.count) { newCount in
            SessionListWindowController.shared.updateWindowSize(sessionCount: newCount)
        }
    }
}

struct PinnedSessionRowView: View {
    let session: Session
    @ObservedObject var observer: SessionObserver
    @State private var isHovered = false
    @State private var isPressed = false

    private var env: FocusEnvironment {
        EnvironmentResolver.shared.resolve(session: session)
    }

    var body: some View {
        HStack(spacing: 8) {
            // Terminal icon with badge
            ZStack(alignment: .topTrailing) {
                if let nsImage = IconManager.shared.iconWithBadge(for: env, size: 48) {
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
                Text(session.displayName)
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
        .scaleEffect(isPressed ? 0.96 : 1.0)
        .animation(.easeOut(duration: 0.05), value: isPressed)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
            if hovering {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
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
