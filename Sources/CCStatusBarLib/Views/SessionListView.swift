import SwiftUI

struct SessionListView: View {
    @ObservedObject var observer: SessionObserver

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if observer.sessions.isEmpty {
                emptyState
            } else {
                sessionList
            }

            Divider()
                .padding(.vertical, 8)

            footerButtons
        }
        .padding(12)
        .frame(width: 280)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "tray")
                .font(.system(size: 24))
                .foregroundColor(.secondary)
            Text("No active sessions")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
    }

    private var sessionList: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(observer.sessions) { session in
                SessionRowView(session: session)
            }
        }
    }

    private var footerButtons: some View {
        HStack {
            Spacer()
            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.plain)
            .foregroundColor(.secondary)
        }
    }
}

struct SessionRowView: View {
    let session: Session

    // Watch for sessionDisplayMode changes to trigger re-render
    @AppStorage("sessionDisplayMode", store: UserDefaults(suiteName: "com.ccstatusbar.app"))
    private var displayModeRaw: String = "project"

    /// Computed display text based on sessionDisplayMode setting
    private var displayText: String {
        let mode = SessionDisplayMode(rawValue: displayModeRaw) ?? .projectName
        return session.displayText(for: mode)
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(session.status.symbol)
                .foregroundColor(session.status.color)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 2) {
                Text(displayText)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)

                Text(session.displayPath)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Text(session.status.label)
                .font(.system(size: 10))
                .foregroundColor(session.status.color)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(Color.primary.opacity(0.05))
        .cornerRadius(6)
    }
}
