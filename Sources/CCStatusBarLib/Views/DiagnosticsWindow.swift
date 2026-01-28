import SwiftUI
import AppKit

/// SwiftUI view for displaying diagnostic issues
struct DiagnosticsView: View {
    @ObservedObject var manager = DiagnosticsManager.shared
    @State private var copied = false

    var body: some View {
        VStack(spacing: 16) {
            // Title with status icon
            HStack {
                Image(systemName: statusIcon)
                    .foregroundColor(statusColor)
                    .font(.title2)
                Text("Diagnostics")
                    .font(.headline)
                Spacer()
            }

            Divider()

            // Issues list or success message
            ScrollView {
                if manager.issues.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 48))
                            .foregroundColor(.green)
                        Text("No issues detected")
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)
                } else {
                    VStack(spacing: 12) {
                        ForEach(manager.issues) { issue in
                            IssueCard(issue: issue)
                        }
                    }
                }
            }

            Divider()

            // Action buttons
            HStack(spacing: 12) {
                Button(action: copyDiagnostics) {
                    HStack {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        Text(copied ? "Copied!" : "Copy Full Diagnostics")
                    }
                }
                .buttonStyle(.bordered)

                Spacer()

                Button(action: refresh) {
                    HStack {
                        Image(systemName: "arrow.clockwise")
                        Text("Refresh")
                    }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding()
        .frame(width: 450, height: 500)
        .onAppear {
            manager.runDiagnostics()
        }
    }

    private var statusIcon: String {
        if manager.hasErrors {
            return "exclamationmark.triangle.fill"
        } else if manager.hasWarnings {
            return "exclamationmark.circle.fill"
        } else {
            return "checkmark.circle.fill"
        }
    }

    private var statusColor: Color {
        if manager.hasErrors {
            return .red
        } else if manager.hasWarnings {
            return .orange
        } else {
            return .green
        }
    }

    private func copyDiagnostics() {
        let report = manager.generateReport()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report, forType: .string)

        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            copied = false
        }

        DebugLog.log("[DiagnosticsView] Copied diagnostics report")
    }

    private func refresh() {
        manager.runDiagnostics()
    }
}

/// Card component for displaying a single issue
struct IssueCard: View {
    let issue: DiagnosticIssue
    @State private var isExpanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Title with severity icon
            HStack(alignment: .top) {
                Image(systemName: severityIcon)
                    .foregroundColor(severityColor)
                    .font(.body)

                Text(issue.title)
                    .font(.subheadline.bold())

                Spacer()

                Button(action: { isExpanded.toggle() }) {
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }

            if isExpanded {
                // Description
                Text(issue.description)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .textSelection(.enabled)

                // Solution
                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Solution")
                            .font(.caption.bold())

                        Text(issue.solution)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .lineLimit(nil)
                            .fixedSize(horizontal: false, vertical: true)

                        // Action button for specific issues
                        actionButton
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding()
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(8)
    }

    private var severityIcon: String {
        issue.severity == .error ? "xmark.circle.fill" : "exclamationmark.triangle.fill"
    }

    private var severityColor: Color {
        issue.severity == .error ? .red : .orange
    }

    @ViewBuilder
    private var actionButton: some View {
        switch issue {
        case .accessibilityPermission:
            Button("Open Accessibility Settings") {
                PermissionManager.openAccessibilitySettings()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)

        case .hooksNotConfigured:
            Button("Reconfigure Hooks...") {
                Task { @MainActor in
                    SetupManager.shared.runSetup(force: true)
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)

        case .tmuxDefaultName(let sessionName, let projectName):
            Button("Copy Rename Command") {
                let command = "tmux rename-session -t \(sessionName) \(projectName)"
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(command, forType: .string)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

        default:
            EmptyView()
        }
    }
}

// MARK: - Window Controller

/// Controller for managing the diagnostics window
@MainActor
final class DiagnosticsWindowController {
    static let shared = DiagnosticsWindowController()

    private var window: NSWindow?

    private init() {}

    func showWindow() {
        // Run diagnostics first
        Task { @MainActor in
            DiagnosticsManager.shared.runDiagnostics()
        }

        if window == nil {
            let view = DiagnosticsView()
            let hostingController = NSHostingController(rootView: view)

            let newWindow = NSWindow(contentViewController: hostingController)
            newWindow.title = "Diagnostics"
            newWindow.styleMask = [.titled, .closable, .resizable]
            newWindow.setContentSize(NSSize(width: 450, height: 500))
            newWindow.minSize = NSSize(width: 400, height: 300)
            newWindow.center()

            window = newWindow
        }

        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func closeWindow() {
        window?.close()
        window = nil
    }
}
