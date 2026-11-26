import Foundation
import Darwin

/// One host that answered a Discover packet.
struct ScanResult {
    let address: String      // dotted IPv4
    let platform: UInt8      // 1 mac, 2 windows, 3 linux
    let name: String
}

/// Unicast subnet scan with a plain BSD UDP socket (no multicast entitlement needed):
/// sends an unencrypted Discover packet to every host address of the local subnet and collects Announce replies.
final class SubnetScanner {
    private struct Interface { let ip: UInt32; let mask: UInt32 }   // host byte order

    private let queue = DispatchQueue(label: "lumen.scan", qos: .utility)
    private let listenSeconds = 1.5
    private let batchSize = 64

    /// Runs one scan. `onResult` is called (on the scanner's queue) once per responding address; `completion` when done.
    func scan(onResult: @escaping (ScanResult) -> Void, completion: @escaping () -> Void) {
        queue.async {
            self.run(onResult: onResult)
            completion()
        }
    }

    // MARK: Interfaces

    private static func localInterfaces() -> [Interface] {
        var result = [Interface]()
        var ifap: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifap) == 0, let first = ifap else { return [] }
        defer { freeifaddrs(ifap) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let cur = cursor {
            cursor = cur.pointee.ifa_next
            let flags = UInt32(cur.pointee.ifa_flags)
            guard flags & UInt32(IFF_UP) != 0, flags & UInt32(IFF_RUNNING) != 0,
                  flags & UInt32(IFF_LOOPBACK) == 0,
                  let sa = cur.pointee.ifa_addr, sa.pointee.sa_family == sa_family_t(AF_INET),
                  let nm = cur.pointee.ifa_netmask else { continue }
            let name = String(cString: cur.pointee.ifa_name)
            guard name.hasPrefix("en") else { continue }     // Wi-Fi / Ethernet adapters
            let ip = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            let mask = nm.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            if ip >> 16 == 0xA9FE { continue }               // link-local 169.254/16
            result.append(Interface(ip: ip, mask: mask))
        }
        return result
    }

    /// All host addresses of the interface's subnet, capped at a /22 (about 1000 addresses) around the device.
    private static func hosts(in iface: Interface) -> [UInt32] {
        var mask = iface.mask
        if mask.nonzeroBitCount < 22 { mask = 0xFFFF_FC00 }
        let net = iface.ip & mask
        let bcast = net | ~mask
        guard bcast > net + 1 else { return [] }
        var out = [UInt32]()
        out.reserveCapacity(Int(bcast - net))
        var a = net + 1
        while a < bcast {
            if a != iface.ip { out.append(a) }
            a += 1
        }
        return out
    }

    // MARK: Scan

    private func run(onResult: @escaping (ScanResult) -> Void) {
        let ifaces = SubnetScanner.localInterfaces()
        guard !ifaces.isEmpty else { return }
        var targets = [UInt32]()
        var seenTargets = Set<UInt32>()
        for i in ifaces {
            for a in SubnetScanner.hosts(in: i) where seenTargets.insert(a).inserted { targets.append(a) }
        }
        guard !targets.isEmpty else { return }

        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { return }
        defer { close(fd) }
        let fl = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, fl | O_NONBLOCK)
        var rcvbuf: Int32 = 1 << 18
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &rcvbuf, socklen_t(MemoryLayout<Int32>.size))

        let packet = Wire.encode(PacketHeader(type: .discover))
        var seen = Set<String>()
        let batch = batchSize

        func drain() {
            var buf = [UInt8](repeating: 0, count: 512)
            let cap = buf.count
            while true {
                var from = sockaddr_in()
                var len = socklen_t(MemoryLayout<sockaddr_in>.size)
                let n = withUnsafeMutablePointer(to: &from) { fp -> Int in
                    fp.withMemoryRebound(to: sockaddr.self, capacity: 1) { sp -> Int in
                        recvfrom(fd, &buf, cap, 0, sp, &len)
                    }
                }
                if n <= 0 { break }
                let data = Data(buf[0..<n])
                guard let (h, payload) = Wire.decode(data), h.type == .announce,
                      let info = AnnounceInfo.decode(payload) else { continue }
                var ina = from.sin_addr
                var text = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                guard inet_ntop(AF_INET, &ina, &text, socklen_t(INET_ADDRSTRLEN)) != nil else { continue }
                let address = String(cString: text)
                if seen.insert(address).inserted {
                    onResult(ScanResult(address: address, platform: info.platform,
                                        name: info.name.isEmpty ? address : info.name))
                }
            }
        }

        var sent = 0
        packet.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            for ip in targets {
                var addr = sockaddr_in()
                addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
                addr.sin_family = sa_family_t(AF_INET)
                addr.sin_port = lumenPort.bigEndian
                addr.sin_addr = in_addr(s_addr: ip.bigEndian)
                let r = withUnsafePointer(to: &addr) { ap -> Int in
                    ap.withMemoryRebound(to: sockaddr.self, capacity: 1) { sp -> Int in
                        sendto(fd, base, raw.count, 0, sp, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
                if r < 0 && (errno == ENOBUFS || errno == EAGAIN) { usleep(3000) }
                sent += 1
                if sent % batch == 0 {
                    usleep(4000)
                    drain()
                }
            }
        }

        let deadline = Date().addingTimeInterval(listenSeconds)
        while Date() < deadline {
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            _ = poll(&pfd, 1, 50)
            drain()
        }
    }
}

// MARK: - Recent hosts

struct RecentHost: Codable, Hashable, Identifiable {
    var name: String
    var address: String
    var key: String          // pairing-secret key (host name, or the typed address)
    var id: String { address }
}

enum RecentHosts {
    private static let defaultsKey = "recentHosts"
    private static let limit = 5

    static func load() -> [RecentHost] {
        guard let d = UserDefaults.standard.data(forKey: defaultsKey),
              let list = try? JSONDecoder().decode([RecentHost].self, from: d) else { return [] }
        return list
    }

    private static func save(_ list: [RecentHost]) {
        if let d = try? JSONEncoder().encode(list) { UserDefaults.standard.set(d, forKey: defaultsKey) }
    }

    static func add(_ host: RecentHost) {
        var list = load().filter { $0.address != host.address }
        list.insert(host, at: 0)
        if list.count > limit { list = Array(list.prefix(limit)) }
        save(list)
    }

    static func remove(address: String) {
        save(load().filter { $0.address != address })
    }
}

// MARK: - Bonjour (NetServiceBrowser works on iOS 12; NWBrowser needs iOS 13)

struct BonjourEntry {
    var name: String
    var address: String?     // dotted IPv4 once resolved
}

/// Browses `_lumen._udp` and resolves each service to an IPv4 address. Main thread only.
final class BonjourBrowser: NSObject, NetServiceBrowserDelegate, NetServiceDelegate {
    var onUpdate: (([BonjourEntry]) -> Void)?

    private var browser: NetServiceBrowser?
    private var services: [String: NetService] = [:]
    private var addresses: [String: String] = [:]

    func start() {
        guard browser == nil else { return }
        let b = NetServiceBrowser()
        b.delegate = self
        b.searchForServices(ofType: lumenBonjourType + ".", inDomain: "local.")
        browser = b
    }

    func stop() {
        browser?.stop()
        browser = nil
        services.removeAll()
        addresses.removeAll()
        publish()
    }

    private func publish() {
        let list = services.keys.map { BonjourEntry(name: $0, address: addresses[$0]) }
        onUpdate?(list)
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        services[service.name] = service
        service.delegate = self
        service.resolve(withTimeout: 5)
        if !moreComing { publish() }
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        services[service.name] = nil
        addresses[service.name] = nil
        service.stop()
        if !moreComing { publish() }
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String: NSNumber]) {
        // Try again shortly (for example right after the local-network permission was granted).
        self.browser = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.start() }
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        guard let list = sender.addresses else { return }
        for data in list {
            if let text = BonjourBrowser.ipv4(from: data) {
                addresses[sender.name] = text
                publish()
                return
            }
        }
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        let name = sender.name
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self = self, let s = self.services[name], self.addresses[name] == nil else { return }
            s.resolve(withTimeout: 5)
        }
    }

    private static func ipv4(from data: Data) -> String? {
        guard data.count >= MemoryLayout<sockaddr_in>.size else { return nil }
        var sin = sockaddr_in()
        withUnsafeMutableBytes(of: &sin) { dst in
            if let base = dst.baseAddress {
                data.copyBytes(to: base.assumingMemoryBound(to: UInt8.self), count: MemoryLayout<sockaddr_in>.size)
            }
        }
        guard sin.sin_family == sa_family_t(AF_INET) else { return nil }
        var addr = sin.sin_addr
        var text = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        guard inet_ntop(AF_INET, &addr, &text, socklen_t(INET_ADDRSTRLEN)) != nil else { return nil }
        return String(cString: text)
    }
}
