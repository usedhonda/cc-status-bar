import Foundation
import Darwin

/// Tailscale status information retrieved via CLI
struct TailscaleStatus {
    let ip: String           // 100.x.x.x
    let hostname: String     // machine-name.tailnet-name.ts.net (trailing dot removed)
    let isConnected: Bool
}

/// Connection host type for URL generation
enum ConnectionHost: String, CaseIterable {
    case localIP = "Local"
    case tailscaleIP = "TS IP"
    case tailscaleHostname = "TS Host"
}

/// Network utility for discovering local and Tailscale IP addresses
final class NetworkHelper {
    static let shared = NetworkHelper()

    private init() {}

    // MARK: - Public API

    /// Get local IP address (Wi-Fi or Ethernet)
    /// Returns the first valid IPv4 address from en0 (Wi-Fi) or en1 (Ethernet)
    func getLocalIPAddress() -> String? {
        // Priority: en0 (Wi-Fi), en1 (Ethernet)
        for interface in ["en0", "en1"] {
            if let ip = getIPAddress(for: interface) {
                return ip
            }
        }
        return nil
    }

    /// Get Tailscale IP address (100.x.x.x CGNAT range)
    func getTailscaleIP() -> String? {
        return getAllIPAddresses().first { ip in
            // Tailscale uses 100.x.x.x (CGNAT range)
            ip.hasPrefix("100.")
        }
    }

    /// Find Tailscale CLI path
    private func findTailscaleCLI() -> String? {
        let paths = [
            "/usr/local/bin/tailscale",
            "/opt/homebrew/bin/tailscale",
            "/Applications/Tailscale.app/Contents/MacOS/Tailscale"
        ]
        return paths.first { FileManager.default.fileExists(atPath: $0) }
    }

    /// Get Tailscale status via CLI
    /// Returns TailscaleStatus with IP, hostname and connection state
    func getTailscaleStatus() -> TailscaleStatus? {
        guard let cli = findTailscaleCLI() else {
            DebugLog.log("[NetworkHelper] Tailscale CLI not found")
            return nil
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: cli)
        process.arguments = ["status", "--json"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            DebugLog.log("[NetworkHelper] Failed to run Tailscale CLI: \(error)")
            return nil
        }

        guard process.terminationStatus == 0 else {
            DebugLog.log("[NetworkHelper] Tailscale CLI exited with status \(process.terminationStatus)")
            return nil
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            DebugLog.log("[NetworkHelper] Failed to parse Tailscale JSON")
            return nil
        }

        // Check BackendState
        guard let backendState = json["BackendState"] as? String,
              backendState == "Running" else {
            DebugLog.log("[NetworkHelper] Tailscale not running (state: \(json["BackendState"] ?? "unknown"))")
            return nil
        }

        // Get Self info
        guard let selfInfo = json["Self"] as? [String: Any] else {
            DebugLog.log("[NetworkHelper] No Self info in Tailscale status")
            return nil
        }

        // Get IPv4 address
        guard let tailscaleIPs = selfInfo["TailscaleIPs"] as? [String],
              let ip = tailscaleIPs.first(where: { $0.contains(".") }) else {
            DebugLog.log("[NetworkHelper] No IPv4 in TailscaleIPs")
            return nil
        }

        // Get DNS name (remove trailing dot)
        guard let dnsName = selfInfo["DNSName"] as? String else {
            DebugLog.log("[NetworkHelper] No DNSName in Tailscale status")
            return nil
        }

        let hostname = dnsName.hasSuffix(".") ? String(dnsName.dropLast()) : dnsName

        DebugLog.log("[NetworkHelper] Tailscale connected: \(ip), \(hostname)")
        return TailscaleStatus(ip: ip, hostname: hostname, isConnected: true)
    }

    /// Generate connection URL for iOS app
    /// - Parameters:
    ///   - useTailscale: If true, use Tailscale IP instead of local IP (legacy parameter)
    /// - Returns: vibeterm:// URL scheme for iOS app
    func generateConnectionURL(useTailscale: Bool = false) -> String? {
        let host: String?
        if useTailscale {
            host = getTailscaleIP()
        } else {
            host = getLocalIPAddress()
        }

        guard let host = host else { return nil }

        return buildConnectionURL(host: host)
    }

    /// Generate connection URL with specified host type
    /// - Parameters:
    ///   - hostType: The type of host to use (local IP, Tailscale IP, or Tailscale hostname)
    ///   - tailscaleStatus: Optional pre-fetched Tailscale status
    /// - Returns: vibeterm:// URL scheme for iOS app
    func generateConnectionURL(hostType: ConnectionHost, tailscaleStatus: TailscaleStatus? = nil) -> String? {
        let host: String?

        switch hostType {
        case .localIP:
            host = getLocalIPAddress()
        case .tailscaleIP:
            host = tailscaleStatus?.ip ?? getTailscaleIP()
        case .tailscaleHostname:
            host = tailscaleStatus?.hostname
        }

        guard let host = host else { return nil }

        return buildConnectionURL(host: host)
    }

    /// Build vibeterm:// URL with given host
    private func buildConnectionURL(host: String) -> String {
        let user = ProcessInfo.processInfo.userName
        let apiPort = WebServer.shared.actualPort

        var components = URLComponents()
        components.scheme = "vibeterm"
        components.host = "connect"
        components.queryItems = [
            URLQueryItem(name: "host", value: host),
            URLQueryItem(name: "port", value: "22"),
            URLQueryItem(name: "user", value: user),
            URLQueryItem(name: "api_port", value: String(apiPort))
        ]

        return components.string ?? ""
    }

    /// Check if Tailscale IP is available
    var hasTailscale: Bool {
        getTailscaleIP() != nil
    }

    // MARK: - Private Helpers

    /// Get IPv4 address for a specific interface
    private func getIPAddress(for interfaceName: String) -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?

        guard getifaddrs(&ifaddr) == 0 else {
            return nil
        }
        defer { freeifaddrs(ifaddr) }

        var ptr = ifaddr
        while let current = ptr {
            defer { ptr = current.pointee.ifa_next }

            let interface = current.pointee
            let family = interface.ifa_addr.pointee.sa_family

            // Check for IPv4
            guard family == UInt8(AF_INET) else { continue }

            // Check interface name
            let name = String(cString: interface.ifa_name)
            guard name == interfaceName else { continue }

            // Get IP address
            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = getnameinfo(
                interface.ifa_addr,
                socklen_t(interface.ifa_addr.pointee.sa_len),
                &hostname,
                socklen_t(hostname.count),
                nil,
                0,
                NI_NUMERICHOST
            )

            if result == 0 {
                return String(cString: hostname)
            }
        }

        return nil
    }

    /// Get all IPv4 addresses from all interfaces
    private func getAllIPAddresses() -> [String] {
        var addresses: [String] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?

        guard getifaddrs(&ifaddr) == 0 else {
            return addresses
        }
        defer { freeifaddrs(ifaddr) }

        var ptr = ifaddr
        while let current = ptr {
            defer { ptr = current.pointee.ifa_next }

            let interface = current.pointee
            let family = interface.ifa_addr.pointee.sa_family

            // Check for IPv4
            guard family == UInt8(AF_INET) else { continue }

            // Get IP address
            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = getnameinfo(
                interface.ifa_addr,
                socklen_t(interface.ifa_addr.pointee.sa_len),
                &hostname,
                socklen_t(hostname.count),
                nil,
                0,
                NI_NUMERICHOST
            )

            if result == 0 {
                let ip = String(cString: hostname)
                // Skip loopback
                if !ip.hasPrefix("127.") {
                    addresses.append(ip)
                }
            }
        }

        return addresses
    }
}
