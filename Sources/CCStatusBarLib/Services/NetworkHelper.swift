import Foundation
import Darwin

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

    /// Generate connection URL for iOS app
    /// - Parameters:
    ///   - useTailscale: If true, use Tailscale IP instead of local IP
    /// - Returns: vibeterm:// URL scheme for iOS app
    func generateConnectionURL(useTailscale: Bool = false) -> String? {
        let host: String?
        if useTailscale {
            host = getTailscaleIP()
        } else {
            host = getLocalIPAddress()
        }

        guard let host = host else { return nil }

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

        return components.string
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
