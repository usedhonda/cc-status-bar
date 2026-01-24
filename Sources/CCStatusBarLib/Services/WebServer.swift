import Foundation
import Swifter

/// Web server for remote session monitoring and access
/// Designed for access via Tailscale from mobile devices
final class WebServer {
    static let shared = WebServer()

    private var server: HttpServer?
    private(set) var actualPort: UInt16 = 0
    private let basePort: UInt16 = 8080
    private let maxPortAttempts = 10

    private init() {}

    // MARK: - Public API

    /// Start the web server, automatically finding an available port
    func start() throws {
        guard server == nil else {
            DebugLog.log("[WebServer] Already running on port \(actualPort)")
            return
        }

        let httpServer = HttpServer()

        // WebSocket /ws/sessions - Real-time session updates
        httpServer["/ws/sessions"] = websocket(
            connected: { wsSession in
                Task { @MainActor in
                    WebSocketManager.shared.subscribe(wsSession)
                }
            },
            disconnected: { wsSession in
                Task { @MainActor in
                    WebSocketManager.shared.unsubscribe(wsSession)
                }
            }
        )

        // Try ports starting from basePort
        var lastError: Error?
        for offset in 0..<maxPortAttempts {
            let port = basePort + UInt16(offset)
            do {
                try httpServer.start(port, forceIPv4: false, priority: .default)
                server = httpServer
                actualPort = port
                DebugLog.log("[WebServer] Started on port \(port)")
                return
            } catch {
                lastError = error
                DebugLog.log("[WebServer] Port \(port) unavailable, trying next...")
            }
        }

        // All ports failed
        throw lastError ?? WebServerError.noAvailablePort
    }

    /// Stop the web server
    func stop() {
        server?.stop()
        server = nil
        let port = actualPort
        actualPort = 0
        DebugLog.log("[WebServer] Stopped (was on port \(port))")
    }

    /// Check if server is running
    var isRunning: Bool {
        server != nil
    }

    enum WebServerError: Error, LocalizedError {
        case noAvailablePort

        var errorDescription: String? {
            switch self {
            case .noAvailablePort:
                return "No available port found (tried \(WebServer.shared.basePort)-\(WebServer.shared.basePort + UInt16(WebServer.shared.maxPortAttempts) - 1))"
            }
        }
    }

}
