import Foundation
import Darwin

/// View → Network Info… (5.0 (17)): this Mac's interfaces and IPv4 neighbour
/// (ARP) table, read IN the app process.
///
/// Why it exists: since macOS 27 a program started from a tab of an app
/// without an Apple Developer ID sees `02:00:00:00:00:00` for every link
/// address and an empty ARP table (`ifconfig`, `arp -an`, `ndp -an`,
/// `netstat -I` in a local tab). The app itself is still allowed to read
/// them, so this sheet shows what the system grants the app — it does not
/// work around the redaction for the shell, and must not try to.
/// `sudo ifconfig` / `sudo arp -an` in a tab still show everything.
///
/// Pure reading (getifaddrs + one sysctl), no AppKit, harness-tested.
enum NetworkTables {
    struct Interface: Equatable, Identifiable {
        var id: String { name }
        var name: String
        var mac: String?
        var ipv4: [String] = []
        var ipv6: [String] = []
        var isUp = false
    }

    struct Neighbor: Equatable, Identifiable {
        var id: String { ip + "%" + interface }
        var ip: String
        var mac: String
        var interface: String
        var permanent: Bool

        /// The ARP table's Interface cell: "en0", or "en0 · permanent" (no
        /// separate, mostly blank column for the flag).
        var interfaceCell: String { permanent ? String(localized: "\(interface) · permanent") : interface }
    }

    static func formatMAC(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined(separator: ":")
    }

    /// Every interface with a link address or an IP, `en*` first in number
    /// order, then the rest by name.
    static func interfaces() -> [Interface] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }
        var byName: [String: Interface] = [:]
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            let name = String(cString: entry.ifa_name)
            var item = byName[name] ?? Interface(name: name)
            item.isUp = item.isUp || (Int32(entry.ifa_flags) & IFF_UP) != 0
            if let addr = entry.ifa_addr {
                switch Int32(addr.pointee.sa_family) {
                case AF_LINK:
                    if let mac = linkAddress(addr) { item.mac = mac }
                case AF_INET:
                    if let text = numericHost(addr) { item.ipv4.append(text) }
                case AF_INET6:
                    if let text = numericHost(addr) { item.ipv6.append(text) }
                default:
                    break
                }
            }
            byName[name] = item
        }
        return byName.values
            .filter { $0.mac != nil || !$0.ipv4.isEmpty || !$0.ipv6.isEmpty }
            .sorted(by: interfaceOrder)
    }

    static func interfaceOrder(_ a: Interface, _ b: Interface) -> Bool {
        let ea = a.name.hasPrefix("en"), eb = b.name.hasPrefix("en")
        if ea != eb { return ea }
        return a.name.compare(b.name, options: .numeric) == .orderedAscending
    }

    /// A 6-byte link address from a `sockaddr_dl`, read through its own
    /// `sa_len` (the address sits after the name and may run past the
    /// declared 12-byte `sdl_data`).
    private static func linkAddress(_ addr: UnsafeMutablePointer<sockaddr>) -> String? {
        let total = Int(addr.pointee.sa_len)
        let raw = UnsafeRawBufferPointer(start: UnsafeRawPointer(addr), count: max(total, 8))
        return parseLinkSockaddr(Array(raw))?.mac
    }

    /// (interface index, MAC) from the bytes of a `sockaddr_dl`; nil unless
    /// it holds a 6-byte address inside its own length.
    static func parseLinkSockaddr(_ b: [UInt8]) -> (index: Int, mac: String)? {
        guard b.count >= 8, Int32(b[1]) == AF_LINK else { return nil }
        let len = min(Int(b[0]), b.count)
        let index = Int(b[2]) | Int(b[3]) << 8
        let nlen = Int(b[5]), alen = Int(b[6])
        let start = 8 + nlen
        guard alen == 6, start + alen <= len else { return nil }
        return (index, formatMAC(Array(b[start..<(start + alen)])))
    }

    private static func numericHost(_ addr: UnsafeMutablePointer<sockaddr>) -> String? {
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        guard getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0
        else { return nil }
        return String(cString: host)
    }

    /// The IPv4 neighbour table, as `arp -an` would print it.
    static func arpTable() -> [Neighbor] {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, AF_INET, NET_RT_FLAGS, RTF_LLINFO]
        var size = 0
        guard sysctl(&mib, 6, nil, &size, nil, 0) == 0, size > 0 else { return [] }
        size += size / 2 + 512          // the table may grow between the two calls
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 6, &buffer, &size, nil, 0) == 0 else { return [] }
        return parseRouteDump(Array(buffer.prefix(size))) { index in
            var name = [CChar](repeating: 0, count: Int(IF_NAMESIZE) + 1)
            return if_indextoname(UInt32(index), &name) != nil ? String(cString: name) : "if\(index)"
        }
    }

    /// Parses a `NET_RT_FLAGS` dump: each message is an `rt_msghdr`, then a
    /// `sockaddr_in` (destination), then a `sockaddr_dl` (the link address).
    /// Bounds-checked throughout: a short or malformed message ends the walk
    /// (or is skipped) instead of reading past the buffer.
    static func parseRouteDump(_ buffer: [UInt8], interfaceName: (Int) -> String) -> [Neighbor] {
        var out: [Neighbor] = []
        let headerSize = MemoryLayout<rt_msghdr>.size
        let flagsOffset = MemoryLayout<rt_msghdr>.offset(of: \rt_msghdr.rtm_flags)!
        var offset = 0
        while offset + headerSize <= buffer.count {
            let msgLen = Int(buffer[offset]) | Int(buffer[offset + 1]) << 8
            guard msgLen >= headerSize, offset + msgLen <= buffer.count else { break }
            defer { offset += msgLen }
            let f = offset + flagsOffset
            let flags = Int32(bitPattern: UInt32(buffer[f]) | UInt32(buffer[f + 1]) << 8
                              | UInt32(buffer[f + 2]) << 16 | UInt32(buffer[f + 3]) << 24)
            let end = offset + msgLen
            var at = offset + headerSize
            guard at + 8 <= end, Int32(buffer[at + 1]) == AF_INET else { continue }
            let dstLen = Int(buffer[at])
            guard dstLen >= 8, at + dstLen <= end else { continue }
            let ip = "\(buffer[at + 4]).\(buffer[at + 5]).\(buffer[at + 6]).\(buffer[at + 7])"
            at += (dstLen + 3) & ~3
            guard at < end, let link = parseLinkSockaddr(Array(buffer[at..<end])) else { continue }
            out.append(Neighbor(ip: ip, mac: link.mac, interface: interfaceName(link.index),
                                permanent: flags & RTF_STATIC != 0))
        }
        return out
    }

    /// Plain text for Copy, in the shapes `ifconfig` / `arp -an` print.
    static func report(interfaces: [Interface], neighbors: [Neighbor]) -> String {
        var lines = ["Interfaces"]
        for i in interfaces {
            var parts = [i.name, i.isUp ? "up" : "down"]
            if let mac = i.mac { parts.append("ether \(mac)") }
            parts += i.ipv4.map { "inet \($0)" } + i.ipv6.map { "inet6 \($0)" }
            lines.append("  " + parts.joined(separator: "  "))
        }
        lines.append("ARP")
        for n in neighbors {
            lines.append("  ? (\(n.ip)) at \(n.mac) on \(n.interface)\(n.permanent ? " permanent" : "")")
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
