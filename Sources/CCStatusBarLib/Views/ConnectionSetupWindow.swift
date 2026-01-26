import SwiftUI
import CoreImage.CIFilterBuiltins

/// Network type selection for connection setup
enum NetworkType: String, CaseIterable {
    case local = "Local"
    case tailscale = "Tailscale"
}

/// SwiftUI view for iOS connection setup with QR code display
struct ConnectionSetupView: View {
    @State private var selectedNetwork: NetworkType = .local
    @State private var localIP: String = "..."
    @State private var tailscaleIP: String?
    @State private var connectionURL: String?
    @State private var copied = false

    private let networkHelper = NetworkHelper.shared

    var body: some View {
        VStack(spacing: 20) {
            // Title
            Text("iOS Connection Setup")
                .font(.headline)

            // Network selector (only if Tailscale is available)
            if tailscaleIP != nil {
                Picker("Network", selection: $selectedNetwork) {
                    ForEach(NetworkType.allCases, id: \.self) { type in
                        Text(type.rawValue).tag(type)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .onChange(of: selectedNetwork) { _ in
                    updateConnectionInfo()
                }
            }

            // QR Code
            if let url = connectionURL, let qrImage = generateQRCode(from: url) {
                Image(nsImage: qrImage)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 200, height: 200)
                    .padding()
                    .background(Color.white)
                    .cornerRadius(8)
            } else {
                // No QR code available
                VStack(spacing: 8) {
                    Image(systemName: "qrcode")
                        .font(.system(size: 80))
                        .foregroundColor(.secondary)
                    Text("Unable to generate QR code")
                        .foregroundColor(.secondary)
                        .font(.caption)
                    if !WebServer.shared.isRunning {
                        Text("Web Server is not running")
                            .foregroundColor(.orange)
                            .font(.caption)
                    }
                }
                .frame(width: 200, height: 200)
                .padding()
            }

            // Connection info
            VStack(alignment: .leading, spacing: 8) {
                ConnectionInfoRow(label: "Name", value: Host.current().localizedName ?? "Unknown")
                ConnectionInfoRow(
                    label: "Host",
                    value: selectedNetwork == .tailscale
                        ? (tailscaleIP ?? "Not available")
                        : localIP
                )
                ConnectionInfoRow(label: "SSH Port", value: "22")
                ConnectionInfoRow(
                    label: "API Port",
                    value: WebServer.shared.isRunning
                        ? String(WebServer.shared.actualPort)
                        : "Not running"
                )
            }
            .padding()
            .background(Color(nsColor: .controlBackgroundColor))
            .cornerRadius(8)

            // Copy URL button
            Button(action: copyURL) {
                HStack {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    Text(copied ? "Copied!" : "Copy URL")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(connectionURL == nil)

            // Help text
            Text("Scan with vibeterm")
                .font(.caption)
                .foregroundColor(.secondary)

            Spacer()
        }
        .padding()
        .frame(width: 360, height: 480)
        .onAppear {
            loadNetworkInfo()
        }
    }

    // MARK: - Private Methods

    private func loadNetworkInfo() {
        localIP = networkHelper.getLocalIPAddress() ?? "Not available"
        tailscaleIP = networkHelper.getTailscaleIP()

        // Default to Tailscale if available
        if tailscaleIP != nil {
            selectedNetwork = .tailscale
        }

        updateConnectionInfo()
    }

    private func updateConnectionInfo() {
        connectionURL = networkHelper.generateConnectionURL(
            useTailscale: selectedNetwork == .tailscale
        )
    }

    private func copyURL() {
        guard let url = connectionURL else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url, forType: .string)

        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            copied = false
        }

        DebugLog.log("[ConnectionSetup] Copied URL: \(url)")
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
                .frame(width: 80, alignment: .trailing)
            Text(value)
                .fontWeight(.medium)
                .textSelection(.enabled)
            Spacer()
        }
        .font(.system(.body, design: .monospaced))
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
            newWindow.title = "iOS Connection Setup"
            newWindow.styleMask = [.titled, .closable]
            newWindow.setContentSize(NSSize(width: 360, height: 480))
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
