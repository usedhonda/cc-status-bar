import Foundation
import Swifter

/// Loopback-only HTTP API for prompt-cache keep-warm.
///
/// Kept off the main WebServer on purpose: that one listens on every interface
/// for Tailscale peers, a poke types into a terminal, and Swifter cannot report
/// the peer address of an IPv6 (dual-stack) connection, so it cannot tell a
/// local caller from a remote one. This server binds 127.0.0.1 only. Its port
/// is published in keepwarm.json as `api_port`.
final class KeepWarmServer {
    static let shared = KeepWarmServer()

    private var server: HttpServer?
    private(set) var port: UInt16 = 0
    private let basePort: UInt16 = 8180
    private let maxPortAttempts: UInt16 = 10

    private init() {}

    func start() {
        guard server == nil else { return }
        let httpServer = HttpServer()
        httpServer.listenAddressIPv4 = "127.0.0.1"

        httpServer.GET["/api/cache"] = { request in
            guard KeepWarmAPI.isLoopback(request.address) else { return .forbidden }
            let payload = KeepWarmAPI.statusPayload(SessionStore.shared.getSessions())
            return .ok(.data(KeepWarmAPI.json(payload), contentType: "application/json"))
        }
        httpServer.POST["/api/poke"] = { request in
            guard KeepWarmAPI.isLoopback(request.address) else { return .forbidden }
            let result = KeepWarmAPI.poke(body: Data(request.body), sessions: SessionStore.shared.getSessions())
            let body = KeepWarmAPI.json(result.payload)
            if result.status == 404 {
                return .raw(404, "Not Found", ["Content-Type": "application/json"]) { try $0.write(body) }
            }
            return .ok(.data(body, contentType: "application/json"))
        }

        for offset in 0..<maxPortAttempts {
            let candidate = basePort + offset
            if (try? httpServer.start(candidate, forceIPv4: true, priority: .default)) != nil {
                server = httpServer
                port = candidate
                DebugLog.log("[KeepWarmServer] Listening on 127.0.0.1:\(candidate)")
                return
            }
        }
        DebugLog.log("[KeepWarmServer] No free port in \(basePort)-\(basePort + maxPortAttempts - 1)")
    }
}
