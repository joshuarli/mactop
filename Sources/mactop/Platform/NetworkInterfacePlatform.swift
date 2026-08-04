import Darwin
import Foundation
import SystemConfiguration

public struct PlatformNetworkInterfaceSnapshot: Sendable {
  public let uploadBytes: UInt64
  public let downloadBytes: UInt64
  public let interfaceName: String
  public let displayName: String
  public let macAddress: String
  public let ssid: String?
  public let localIP: String
  public let transmitRate: Double
  public let isUp: Bool
}

public final class NetworkInterfacePlatform: @unchecked Sendable {
  private let dynamicStore = SCDynamicStoreCreate(nil, "mactop" as CFString, nil, nil)
  private var primaryInterfaceLastRead = Date.distantPast
  private var cachedPrimaryInterface: String?
  private var detailsLastRead = Date.distantPast
  private var cachedInterfaceName = ""
  private var cachedLocalIP = ""
  private var cachedIsUp = false
  private var cachedDisplayName = ""
  private var cachedMAC = ""
  private var cachedSSID: String?
  private var cachedTransmitRate = 0.0

  public init() {}

  public func read() -> PlatformNetworkInterfaceSnapshot? {
    let now = Date()
    let preferred = activePrimaryInterfaceName()
    let refresh = now.timeIntervalSince(detailsLastRead) >= 15
    var ifap: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&ifap) == 0, let head = ifap else { return nil }
    defer { freeifaddrs(head) }
    var up: UInt64 = 0
    var down: UInt64 = 0
    var links: [String: (Bool, String, Double)] = [:]
    var ips: [String: String] = [:]
    var firstLink = ""
    var firstIP = ""
    var cursor: UnsafeMutablePointer<ifaddrs>? = head
    while let iface = cursor {
      defer { cursor = iface.pointee.ifa_next }
      let name = decodeCString(iface.pointee.ifa_name)
      guard name.hasPrefix("en") else { continue }
      if let address = iface.pointee.ifa_addr,
        address.pointee.sa_family == UInt8(AF_LINK),
        let raw = iface.pointee.ifa_data
      {
        let data = raw.assumingMemoryBound(to: if_data.self).pointee
        up = saturatingAdd(up, UInt64(data.ifi_obytes))
        down = saturatingAdd(down, UInt64(data.ifi_ibytes))
        if refresh {
          var mac = ""
          address.withMemoryRebound(to: sockaddr_dl.self, capacity: 1) { pointer in
            let sdl = pointer.pointee
            if sdl.sdl_alen == 6 {
              mac = withUnsafeBytes(of: sdl.sdl_data) {
                macString(bytes: $0, offset: Int(sdl.sdl_nlen))
              }
            }
          }
          links[name] = (
            (iface.pointee.ifa_flags & UInt32(IFF_UP)) != 0, mac,
            Double(data.ifi_baudrate) / 1_000_000
          )
          if firstLink.isEmpty { firstLink = name }
        }
      }
      if refresh, let address = iface.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET)
      {
        var raw = address.pointee
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        withUnsafeMutablePointer(to: &raw) { pointer in
          pointer.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { address in
            var value = address.pointee.sin_addr
            inet_ntop(AF_INET, &value, &buffer, socklen_t(INET_ADDRSTRLEN))
          }
        }
        ips[name] = decodeCString(buffer)
        if firstIP.isEmpty { firstIP = name }
      }
    }
    if refresh {
      refreshInterfaceDetails(
        preferred: preferred, links: links, ips: ips, firstLink: firstLink, firstIP: firstIP)
    }
    return PlatformNetworkInterfaceSnapshot(
      uploadBytes: up, downloadBytes: down, interfaceName: cachedInterfaceName,
      displayName: cachedDisplayName, macAddress: cachedMAC, ssid: cachedSSID,
      localIP: cachedLocalIP, transmitRate: cachedTransmitRate, isUp: cachedIsUp)
  }

  private func activePrimaryInterfaceName() -> String? {
    let now = Date()
    guard now.timeIntervalSince(primaryInterfaceLastRead) >= 15 else {
      return cachedPrimaryInterface
    }
    primaryInterfaceLastRead = now
    guard let dynamicStore,
      let global = SCDynamicStoreCopyValue(dynamicStore, "State:/Network/Global/IPv4" as CFString)
        as? [String: Any],
      let interface = global["PrimaryInterface"] as? String, !interface.isEmpty
    else { return nil }
    cachedPrimaryInterface = interface
    return interface
  }

  private func refreshInterfaceDetails(
    preferred: String?, links: [String: (Bool, String, Double)], ips: [String: String],
    firstLink: String, firstIP: String
  ) {
    let name =
      preferred.flatMap { links[$0] == nil ? nil : $0 } ?? (firstIP.isEmpty ? firstLink : firstIP)
    cachedInterfaceName = name
    cachedLocalIP = ips[name] ?? ""
    if let link = links[name] {
      cachedIsUp = link.0
      if !link.1.isEmpty { cachedMAC = link.1 }
      if link.2 > 0 { cachedTransmitRate = link.2 }
    }
    guard !name.isEmpty, Date().timeIntervalSince(detailsLastRead) >= 15 else { return }
    detailsLastRead = Date()
    for case let interface as SCNetworkInterface in SCNetworkInterfaceCopyAll() as NSArray {
      guard SCNetworkInterfaceGetBSDName(interface) as String? == name else { continue }
      cachedDisplayName = SCNetworkInterfaceGetLocalizedDisplayName(interface) as String? ?? name
      if SCNetworkInterfaceGetInterfaceType(interface) as String?
        == (kSCNetworkInterfaceTypeIEEE80211 as String), let dynamicStore,
        let info = SCDynamicStoreCopyValue(
          dynamicStore, "State:/Network/Interface/\(name)/AirPort" as CFString) as? [String: Any]
      {
        cachedSSID = info["SSID_STR"] as? String
      } else {
        cachedSSID = nil
      }
      break
    }
  }

  private func decodeCString(_ pointer: UnsafePointer<CChar>) -> String {
    let length = unsafe strlen(pointer)
    let bytes = unsafe UnsafeBufferPointer(start: pointer, count: length)
    return String(decoding: unsafe bytes.map { UInt8(bitPattern: $0) }, as: UTF8.self)
  }

  private func decodeCString(_ bytes: [CChar]) -> String {
    String(decoding: bytes.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
  }

  private func macString(bytes: UnsafeRawBufferPointer, offset: Int) -> String {
    let values = Array(bytes)
    guard offset + 5 < values.count else { return "" }
    return (0..<6).map { String(format: "%02x", values[offset + $0]) }.joined(separator: ":")
  }

  private func saturatingAdd(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
    let (value, overflow) = lhs.addingReportingOverflow(rhs)
    return overflow ? .max : value
  }
}
