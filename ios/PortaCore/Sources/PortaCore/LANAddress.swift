#if canImport(Darwin)
import Foundation
import Darwin

/// LANAddress picks a reasonable IPv4 address to advertise to the receiver.
/// We prefer en0 (Wi-Fi) and fall back to the first non-loopback IPv4 we can
/// find. This is best-effort — the sender can also share the Bonjour
/// `<hostname>.local` URL, which is what LANHost advertises.
public enum LANAddress {
    /// Returns the IPv4 string of the first running Wi-Fi (`en0`) interface.
    /// Returns `nil` if no suitable address is found.
    public static func ipv4() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }

        var preferred: String?
        var fallback: String?

        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let ptr = cursor {
            defer { cursor = ptr.pointee.ifa_next }

            let flags = Int32(ptr.pointee.ifa_flags)
            guard (flags & (IFF_UP | IFF_RUNNING)) == (IFF_UP | IFF_RUNNING) else { continue }
            guard (flags & IFF_LOOPBACK) == 0 else { continue }

            let family = ptr.pointee.ifa_addr.pointee.sa_family
            guard family == UInt8(AF_INET) else { continue }

            guard let name = String(validatingUTF8: ptr.pointee.ifa_name) else { continue }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let rc = getnameinfo(
                ptr.pointee.ifa_addr,
                socklen_t(ptr.pointee.ifa_addr.pointee.sa_len),
                &host, socklen_t(host.count),
                nil, 0,
                NI_NUMERICHOST
            )
            guard rc == 0 else { continue }
            let ip = String(cString: host)
            guard !ip.isEmpty else { continue }

            if name == "en0" {
                preferred = ip
            } else if fallback == nil {
                fallback = ip
            }
        }

        return preferred ?? fallback
    }

    /// Constructs an `http://<ip>:<port>/` URL string. Falls back to
    /// `http://localhost:<port>/` when no LAN IP is available — useful in
    /// the simulator where Bonjour works but interface enumeration is noisy.
    public static func shareURL(port: UInt16) -> String {
        let host = ipv4() ?? "localhost"
        return "http://\(host):\(port)/"
    }
}
#endif
