import SwiftUI
import CoreImage.CIFilterBuiltins

/// SwiftUI view for iOS connection setup with QR code display
struct ConnectionSetupView: View {
    @State private var selectedHost: ConnectionHost = .localIP
    @State private var localIP: String = "..."
    @State private var tailscaleStatus: TailscaleStatus?
    @State private var connectionURL: String?
    @State private var copiedURL = false
    @State private var copiedWebSocket = false
    @State private var serverErrorMessage: String?

    private let networkHelper = NetworkHelper.shared
    private static let appStoreURL = URL(string: "https://apps.apple.com/jp/app/vibeterm/id6758266443")!

    /// Check if Tailscale is available and connected
    private var hasTailscale: Bool {
        tailscaleStatus != nil
    }

    /// Current host value to display
    private var currentHostValue: String {
        switch selectedHost {
        case .localIP:
            return localIP
        case .tailscaleIP:
            return tailscaleStatus?.ip ?? "Not available"
        case .tailscaleHostname:
            return tailscaleStatus?.hostname ?? "Not available"
        }
    }

    private var currentHostForConnection: String? {
        switch selectedHost {
        case .localIP:
            return localIP == "Not available" ? nil : localIP
        case .tailscaleIP:
            return tailscaleStatus?.ip
        case .tailscaleHostname:
            return tailscaleStatus?.hostname
        }
    }

    private var serverStatusValue: String {
        if WebServer.shared.isRunning {
            return "Running"
        }
        if let message = serverErrorMessage, !message.isEmpty {
            return "Failed"
        }
        return "Not running"
    }

    private var websocketEndpointURL: String? {
        guard WebServer.shared.isRunning else { return nil }
        guard let host = currentHostForConnection else { return nil }
        return "ws://\(host):\(WebServer.shared.actualPort)/ws/sessions"
    }

    private var websocketEndpointValue: String {
        if let endpoint = websocketEndpointURL {
            return endpoint
        }
        if !WebServer.shared.isRunning {
            return "Not running"
        }
        return "Host unavailable"
    }

    var body: some View {
        VStack(spacing: 10) {
            // Header - clickable to App Store
            Link(destination: Self.appStoreURL) {
                HStack(spacing: 6) {
                    Image(systemName: "iphone")
                        .font(.system(size: 16))
                    Text("Connect VibeTerm")
                        .font(.headline)
                }
            }
            .padding(.top, 2)

            // Network selector (3 options)
            HStack(spacing: 0) {
                ForEach(ConnectionHost.allCases, id: \.self) { host in
                    hostButton(for: host)
                }
            }
            .background(Color(nsColor: .controlBackgroundColor))
            .cornerRadius(6)
            .padding(.horizontal, 4)

            // QR Code
            if let url = connectionURL, let qrImage = generateQRCode(from: url) {
                Link(destination: Self.appStoreURL) {
                    Image(nsImage: qrImage)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 180, height: 180)
                        .padding(8)
                        .background(Color.white)
                        .cornerRadius(8)
                }
                .onHover { inside in
                    if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                }
            } else {
                // No QR code available
                VStack(spacing: 8) {
                    Image(systemName: "qrcode")
                        .font(.system(size: 68))
                        .foregroundColor(.secondary)
                    Text("Unable to generate QR code")
                        .foregroundColor(.secondary)
                        .font(.caption)
                    if !WebServer.shared.isRunning {
                        Text("Web Server is not running")
                            .foregroundColor(.orange)
                            .font(.caption)
                    }
                    if let serverErrorMessage {
                        Text(serverErrorMessage)
                            .foregroundColor(.secondary)
                            .font(.caption2)
                            .multilineTextAlignment(.center)
                            .lineLimit(3)
                    }
                }
                .frame(width: 180, height: 180)
                .padding(8)
            }

            // Connection info
            VStack(alignment: .leading, spacing: 6) {
                ConnectionInfoRow(label: "Host", value: currentHostValue)
                ConnectionInfoRow(
                    label: "API Port",
                    value: WebServer.shared.isRunning
                        ? String(WebServer.shared.actualPort)
                        : "Not running"
                )
                ConnectionInfoRow(label: "Server", value: serverStatusValue)
                ConnectionInfoRow(label: "WebSocket", value: websocketEndpointValue)
            }
            .padding(10)
            .background(Color(nsColor: .controlBackgroundColor))
            .cornerRadius(8)

            // Copy buttons
            HStack(spacing: 8) {
                Button(action: copyURL) {
                    HStack {
                        Image(systemName: copiedURL ? "checkmark" : "doc.on.doc")
                        Text(copiedURL ? "Copied URL" : "Copy URL")
                    }
                    .font(.caption)
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(connectionURL == nil)

                Button(action: copyWebSocketURL) {
                    HStack {
                        Image(systemName: copiedWebSocket ? "checkmark" : "link")
                        Text(copiedWebSocket ? "Copied WS" : "Copy WS")
                    }
                    .font(.caption)
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(websocketEndpointURL == nil)
            }

            // Footer - clickable to App Store
            Link(destination: Self.appStoreURL) {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.down.app")
                        .font(.caption2)
                    Text("Download VibeTerm on App Store")
                        .font(.caption2)
                }
            }
        }
        .padding(12)
        .frame(width: 320, height: 460)
        .onAppear {
            loadNetworkInfo()
            ensureWebServerRunning()
        }
    }

    // MARK: - Private Views

    @ViewBuilder
    private func hostButton(for host: ConnectionHost) -> some View {
        let isSelected = selectedHost == host
        let isDisabled = !isHostAvailable(host)

        Button(action: {
            if !isDisabled {
                selectedHost = host
                updateConnectionInfo()
            }
        }) {
            Text(host.rawValue)
                .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                .foregroundColor(isDisabled ? .secondary.opacity(0.5) : (isSelected ? .white : .primary))
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(isSelected ? Color.accentColor : Color.clear)
                .cornerRadius(4)
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
    }

    private func isHostAvailable(_ host: ConnectionHost) -> Bool {
        switch host {
        case .localIP:
            return localIP != "Not available"
        case .tailscaleIP, .tailscaleHostname:
            return hasTailscale
        }
    }

    // MARK: - Private Methods

    private func loadNetworkInfo() {
        localIP = networkHelper.getLocalIPAddress() ?? "Not available"
        tailscaleStatus = networkHelper.getTailscaleStatus()

        // Default to Tailscale hostname if available, otherwise local IP
        if hasTailscale {
            selectedHost = .tailscaleHostname
        } else {
            selectedHost = .localIP
        }

        updateConnectionInfo()
    }

    private func updateConnectionInfo() {
        guard WebServer.shared.isRunning else {
            connectionURL = nil
            return
        }
        connectionURL = networkHelper.generateConnectionURL(
            hostType: selectedHost,
            tailscaleStatus: tailscaleStatus
        )
    }

    private func ensureWebServerRunning() {
        guard !WebServer.shared.isRunning else {
            serverErrorMessage = nil
            updateConnectionInfo()
            return
        }

        do {
            try WebServer.shared.start()
            serverErrorMessage = nil
            DebugLog.log("[ConnectionSetup] Web server started")
        } catch {
            serverErrorMessage = error.localizedDescription
            DebugLog.log("[ConnectionSetup] Failed to start web server: \(error)")
        }

        updateConnectionInfo()
    }

    private func copyURL() {
        guard let url = connectionURL else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url, forType: .string)

        copiedURL = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            copiedURL = false
        }

        DebugLog.log("[ConnectionSetup] Copied URL: \(url)")
    }

    private func copyWebSocketURL() {
        guard let endpoint = websocketEndpointURL else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(endpoint, forType: .string)

        copiedWebSocket = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            copiedWebSocket = false
        }

        DebugLog.log("[ConnectionSetup] Copied WebSocket URL: \(endpoint)")
    }

    private func generateQRCode(from string: String) -> NSImage? {
        let context = CIContext()
        let filter = CIFilter.qrCodeGenerator()

        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"

        guard let outputImage = filter.outputImage else {
            return nil
        }

        // Scale up for better resolution
        let scale: CGFloat = 10
        let scaledImage = outputImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

        guard let cgImage = context.createCGImage(scaledImage, from: scaledImage.extent) else {
            return nil
        }

        return NSImage(cgImage: cgImage, size: NSSize(width: 200, height: 200))
    }
}

/// Row component for connection info display
struct ConnectionInfoRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label + ":")
                .foregroundColor(.secondary)
                .frame(width: 70, alignment: .trailing)
            Text(value)
                .fontWeight(.medium)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Spacer()
        }
        .font(.system(size: 12, design: .monospaced))
    }
}

// MARK: - Window Controller

/// Controller for managing the connection setup window
final class ConnectionSetupWindowController {
    static let shared = ConnectionSetupWindowController()

    private var window: NSWindow?

    private init() {}

    func showWindow() {
        if window == nil {
            let view = ConnectionSetupView()
            let hostingController = NSHostingController(rootView: view)

            let newWindow = NSWindow(contentViewController: hostingController)
            newWindow.title = "VibeTerm"
            newWindow.styleMask = [.titled, .closable]
            newWindow.setContentSize(NSSize(width: 320, height: 460))
            newWindow.center()

            // Keep reference to prevent deallocation
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
