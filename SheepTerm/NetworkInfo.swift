import Darwin
import Foundation
import SystemConfiguration

enum NetworkInfo {
    /// "This Mac: 192.168.1.45 · en0" — prefers en0, falls back to the first
    /// non-loopback IPv4 interface that is up.
    static func summary() -> String {
        guard let (ip, interface) = primaryIPv4() else { return String(localized: "This Mac: no IPv4") }
        return String(localized: "This Mac: \(ip) · \(interface)")
    }

    static func primaryIPv4() -> (ip: String, interface: String)? {
        var ifaddrPointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrPointer) == 0, let first = ifaddrPointer else { return nil }
        defer { freeifaddrs(ifaddrPointer) }

        var fallback: (String, String)?
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = pointer.pointee
            guard let sa = ifa.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) else { continue }
            let flags = UInt32(ifa.ifa_flags)
            // Up AND actually running; loopback excluded by flag, not name.
            guard (flags & UInt32(IFF_UP)) != 0,
                  (flags & UInt32(IFF_RUNNING)) != 0,
                  (flags & UInt32(IFF_LOOPBACK)) == 0 else { continue }
            let name = String(cString: ifa.ifa_name)

            // Copy sa_len bytes into a storage — a plain sockaddr is only 16
            // bytes and would truncate a future IPv6 branch of this code.
            var storage = sockaddr_storage()
            let length = Int(sa.pointee.sa_len)
            guard length <= MemoryLayout<sockaddr_storage>.size else { continue }
            memcpy(&storage, sa, length)

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let sockLength = socklen_t(length)
            let status = withUnsafePointer(to: &storage) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPointer in
                    getnameinfo(saPointer, sockLength,
                                &host, socklen_t(host.count),
                                nil, 0, NI_NUMERICHOST)
                }
            }
            guard status == 0 else { continue }
            let ipBytes = host.prefix { $0 != 0 }.map(UInt8.init(bitPattern:))
            let ip = String(decoding: ipBytes, as: UTF8.self)
            // utun* are VPN tunnels and 169.254.x is link-local — neither is
            // a useful "This Mac" address, en0 included: an en0 that is up
            // without a lease must not shadow a real address elsewhere.
            guard !name.hasPrefix("utun"), !ip.hasPrefix("169.254.") else { continue }
            if name == "en0" { return (ip, name) }
            if fallback == nil { fallback = (ip, name) }
        }
        return fallback
    }

    /// Every interface that is up and running with an IPv4, loopback left
    /// out, its first IPv4 each, in the system's order — the File Server
    /// popover's address menu. Named by SystemConfiguration's localized
    /// display name (Wi-Fi, Ethernet, USB 10/100/1000 LAN…), else the BSD name.
    static func ipv4Interfaces() -> [FileServerPlan.Interface] {
        var names: [String: String] = [:]
        if let all = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] {
            for interface in all {
                guard let bsd = SCNetworkInterfaceGetBSDName(interface) as String?,
                      let shown = SCNetworkInterfaceGetLocalizedDisplayName(interface) as String? else { continue }
                names[bsd] = shown
            }
        }
        var ifaddrPointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrPointer) == 0, let first = ifaddrPointer else { return [] }
        defer { freeifaddrs(ifaddrPointer) }
        var out: [FileServerPlan.Interface] = []
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = pointer.pointee
            guard let sa = ifa.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) else { continue }
            let flags = UInt32(ifa.ifa_flags)
            guard (flags & UInt32(IFF_UP)) != 0, (flags & UInt32(IFF_RUNNING)) != 0,
                  (flags & UInt32(IFF_LOOPBACK)) == 0 else { continue }
            let bsd = String(cString: ifa.ifa_name)
            guard !out.contains(where: { $0.bsdName == bsd }) else { continue }
            var address = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
            var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            guard inet_ntop(AF_INET, &address, &buffer, socklen_t(buffer.count)) != nil else { continue }
            let ip = String(decoding: buffer.prefix { $0 != 0 }.map(UInt8.init(bitPattern:)), as: UTF8.self)
            out.append(.init(bsdName: bsd, displayName: names[bsd] ?? bsd, ip: ip))
        }
        return out
    }
}
