import Darwin
import Foundation
import SystemConfiguration

// Reads aggregate en* interface byte counters and caches active-interface metadata
// such as local address, SSID, MAC address, and negotiated link rate.

public struct NetworkUsageDetail {
    public var upload: Double
    public var download: Double
    public var totalUp: UInt64
    public var totalDown: UInt64
    public var interfaceName: String     // BSD name, e.g. "en0"
    public var displayName: String       // localized, e.g. "Wi-Fi"
    public var macAddress: String        // e.g. "a4:c3:f0:12:34:56"
    public var ssid: String?             // WiFi only
    public var localIP: String
    public var publicIP: String?         // async-fetched; nil until available
    public var transmitRate: Double      // Mbps from ifi_baudrate
    public var isUp: Bool
    public var history: [MetricHistoryPoint<(up: Double, down: Double)>]
    public var historyCapacity: Int
}

public final class NetworkInterfaceReader {
    private var prevUp: UInt64 = 0
    private var prevDown: UInt64 = 0
    private var cumulativeUp: UInt64 = 0
    private var cumulativeDown: UInt64 = 0
    private var lastTime = Date()
    private var history: PairHistory
    private let dynamicStore = SCDynamicStoreCreate(nil, "mactop" as CFString, nil, nil)
    private var primaryInterfaceLastRead = Date.distantPast
    private var cachedPrimaryInterface: String? = nil

    // Interface detail cache — refreshed at most every 15 s
    private var detailsLastRead = Date.distantPast
    private var cachedInterfaceName = ""
    private var cachedLocalIP = ""
    private var cachedIsUp = false
    private var cachedDisplayName = ""
    private var cachedMAC = ""
    private var cachedSSID: String? = nil
    private var cachedTransmitRate: Double = 0

    // Public IP — fetched async, at most every 300 s
    private var publicIPLastFetch = Date.distantPast
    private var cachedPublicIP: String? = nil
    private let publicIPLock = NSLock()
    private let fetchPublicIP: Bool

    public init(updateInterval: Double = 1, fetchPublicIP: Bool = true) {
        self.fetchPublicIP = fetchPublicIP
        history = PairHistory(capacity: metricGraphSampleCapacity(updateInterval: updateInterval))
    }

    public func clearNetworkUsageHistory() {
        prevUp = 0
        prevDown = 0
        cumulativeUp = 0
        cumulativeDown = 0
        lastTime = Date()
        history.removeAll()
    }

    public func readNetworkUsageDetail(includeHistory: Bool = false) -> NetworkUsageDetail {
        let now = Date()
        let preferredIface = activePrimaryInterfaceName()
        let shouldRefreshDetails = now.timeIntervalSince(detailsLastRead) >= 15
        var ifap: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifap) == 0, let head = ifap else {
            return NetworkUsageDetail(upload: 0, download: 0, totalUp: cumulativeUp, totalDown: cumulativeDown,
                             interfaceName: cachedInterfaceName, displayName: cachedDisplayName, macAddress: cachedMAC, ssid: cachedSSID,
                             localIP: cachedLocalIP, publicIP: lockedPublicIP(), transmitRate: cachedTransmitRate, isUp: cachedIsUp,
                             history: includeHistory ? history.orderedValues : [], historyCapacity: history.capacity)
        }
        defer { freeifaddrs(head) }

        var totalUp: UInt64 = 0
        var totalDown: UInt64 = 0
        var linkDetails: [String: (isUp: Bool, mac: String, transmitRate: Double)] = [:]
        var ipByInterface: [String: String] = [:]
        var firstLinkInterface = ""
        var firstIPInterface = ""

        var cursor: UnsafeMutablePointer<ifaddrs>? = head
        while let iface = cursor {
            defer { cursor = iface.pointee.ifa_next }
            let name = String(cString: iface.pointee.ifa_name)
            guard name.hasPrefix("en") else { continue }

            if let addr = iface.pointee.ifa_addr,
               addr.pointee.sa_family == UInt8(AF_LINK),
               let raw = iface.pointee.ifa_data {
                let ifData = raw.assumingMemoryBound(to: if_data.self).pointee
                totalUp   += UInt64(ifData.ifi_obytes)
                totalDown += UInt64(ifData.ifi_ibytes)

                if shouldRefreshDetails {
                    var mac = ""
                    addr.withMemoryRebound(to: sockaddr_dl.self, capacity: 1) { sdl in
                        let alen = Int(sdl.pointee.sdl_alen)
                        let nlen = Int(sdl.pointee.sdl_nlen)
                        if alen == 6 {
                            mac = withUnsafeBytes(of: sdl.pointee.sdl_data) { raw in
                                Self.macString(bytes: raw, offset: nlen)
                            }
                        }
                    }
                    linkDetails[name] = (
                        isUp: (iface.pointee.ifa_flags & UInt32(IFF_UP)) != 0,
                        mac: mac,
                        transmitRate: Double(ifData.ifi_baudrate) / 1_000_000
                    )
                    if firstLinkInterface.isEmpty { firstLinkInterface = name }
                }
            }

            if shouldRefreshDetails,
               let addr = iface.pointee.ifa_addr,
               addr.pointee.sa_family == UInt8(AF_INET),
               ipByInterface[name] == nil {
                var rawAddr = addr.pointee
                var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                withUnsafeMutablePointer(to: &rawAddr) {
                    $0.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                        var inAddr = $0.pointee.sin_addr
                        inet_ntop(AF_INET, &inAddr, &buf, socklen_t(INET_ADDRSTRLEN))
                    }
                }
                ipByInterface[name] = String(cString: buf)
                if firstIPInterface.isEmpty { firstIPInterface = name }
            }
        }

        if shouldRefreshDetails {
            refreshCachedInterfaceDetails(
                preferredIface: preferredIface,
                linkDetails: linkDetails,
                ipByInterface: ipByInterface,
                firstLinkInterface: firstLinkInterface,
                firstIPInterface: firstIPInterface
            )
        }

        let elapsed = now.timeIntervalSince(lastTime)
        var upRate = 0.0
        var downRate = 0.0

        if elapsed > 0 && (prevUp > 0 || prevDown > 0) {
            let dUp   = totalUp   >= prevUp   ? Double(totalUp   - prevUp)   : 0
            let dDown = totalDown >= prevDown ? Double(totalDown - prevDown) : 0
            upRate   = dUp   / elapsed
            downRate = dDown / elapsed
            cumulativeUp   += totalUp   >= prevUp   ? (totalUp   - prevUp)   : 0
            cumulativeDown += totalDown >= prevDown ? (totalDown - prevDown) : 0
        }

        prevUp = totalUp
        prevDown = totalDown
        lastTime = now

        history.append(up: upRate, down: downRate)

        if fetchPublicIP {
            refreshPublicIP()
        }

        return NetworkUsageDetail(
            upload: upRate,
            download: downRate,
            totalUp: cumulativeUp,
            totalDown: cumulativeDown,
            interfaceName: cachedInterfaceName,
            displayName: cachedDisplayName,
            macAddress: cachedMAC,
            ssid: cachedSSID,
            localIP: cachedLocalIP,
            publicIP: lockedPublicIP(),
            transmitRate: cachedTransmitRate,
            isUp: cachedIsUp,
            history: includeHistory ? history.orderedValues : [],
            historyCapacity: history.capacity
        )
    }

    private func refreshCachedInterfaceDetails(
        preferredIface: String?,
        linkDetails: [String: (isUp: Bool, mac: String, transmitRate: Double)],
        ipByInterface: [String: String],
        firstLinkInterface: String,
        firstIPInterface: String
    ) {
        let interfaceName: String
        if let preferredIface, linkDetails[preferredIface] != nil {
            interfaceName = preferredIface
        } else if !firstIPInterface.isEmpty {
            interfaceName = firstIPInterface
        } else {
            interfaceName = firstLinkInterface
        }

        cachedInterfaceName = interfaceName
        cachedLocalIP = ipByInterface[interfaceName] ?? ""
        if let link = linkDetails[interfaceName] {
            cachedIsUp = link.isUp
            if !link.mac.isEmpty { cachedMAC = link.mac }
            if link.transmitRate > 0 { cachedTransmitRate = link.transmitRate }
        }
        refreshCachedNetworkInterfaceDetails(interfaceName: interfaceName)
    }

    private func activePrimaryInterfaceName() -> String? {
        let now = Date()
        guard now.timeIntervalSince(primaryInterfaceLastRead) >= 15 else {
            return cachedPrimaryInterface
        }
        primaryInterfaceLastRead = now

        guard let dynamicStore,
              let global = SCDynamicStoreCopyValue(dynamicStore, "State:/Network/Global/IPv4" as CFString) as? [String: Any],
              let iface = global["PrimaryInterface"] as? String,
              !iface.isEmpty else { return nil }
        cachedPrimaryInterface = iface
        return iface
    }

    // Reads display name and SSID via SystemConfiguration — throttled to 15 s
    private func refreshCachedNetworkInterfaceDetails(interfaceName: String) {
        guard !interfaceName.isEmpty, Date().timeIntervalSince(detailsLastRead) >= 15 else { return }
        detailsLastRead = Date()

        for case let scIface as SCNetworkInterface in SCNetworkInterfaceCopyAll() as NSArray {
            guard let bsd = SCNetworkInterfaceGetBSDName(scIface) as String?,
                  bsd == interfaceName else { continue }
            cachedDisplayName = SCNetworkInterfaceGetLocalizedDisplayName(scIface) as String? ?? interfaceName
            // SSID for WiFi interfaces via SCDynamicStore
            let ifType = SCNetworkInterfaceGetInterfaceType(scIface) as String?
            if ifType == (kSCNetworkInterfaceTypeIEEE80211 as String) {
                let key = "State:/Network/Interface/\(interfaceName)/AirPort" as CFString
                if let dynamicStore,
                   let info = SCDynamicStoreCopyValue(dynamicStore, key) as? [String: Any] {
                    cachedSSID = info["SSID_STR"] as? String
                }
            } else {
                cachedSSID = nil
            }
            break
        }
    }

    // Fetches public IPv4 from ipify — throttled to 300 s, non-blocking
    private func refreshPublicIP() {
        guard Date().timeIntervalSince(publicIPLastFetch) >= 300,
              let publicIPURL = Self.publicIPURL else { return }
        publicIPLastFetch = Date()
        URLSession.shared.dataTask(with: publicIPURL) { [weak self] data, _, _ in
            guard let self, let data,
                  let ip = String(data: data, encoding: .utf8) else { return }
            self.publicIPLock.lock()
            self.cachedPublicIP = ip.trimmingCharacters(in: .whitespacesAndNewlines)
            self.publicIPLock.unlock()
        }.resume()
    }

    private func lockedPublicIP() -> String? {
        publicIPLock.lock()
        defer { publicIPLock.unlock() }
        return cachedPublicIP
    }

    private static let publicIPURL = URL(string: "https://api.ipify.org")

    private static func macString(bytes: UnsafeRawBufferPointer, offset: Int) -> String {
        guard offset + 5 < bytes.count else { return "" }
        let digits = Array("0123456789abcdef".utf8)
        var output = [UInt8]()
        output.reserveCapacity(17)
        for i in 0..<6 {
            let byte = bytes[offset + i]
            if i > 0 { output.append(58) }
            output.append(digits[Int(byte >> 4)])
            output.append(digits[Int(byte & 0x0f)])
        }
        return String(decoding: output, as: UTF8.self)
    }
}
