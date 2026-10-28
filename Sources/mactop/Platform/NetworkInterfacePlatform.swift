import Darwin
import Foundation
import Synchronization
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

public final class NetworkInterfacePlatform: Sendable {
  fileprivate struct State: Sendable {
    var primaryInterfaceLastRead = Date.distantPast
    var cachedPrimaryInterface: String?
    var detailsLastRead = Date.distantPast
    var cachedInterfaceName = ""
    var cachedLocalIP = ""
    var cachedIsUp = false
    var cachedDisplayName = ""
    var cachedMAC = ""
    var cachedSSID: String?
    var cachedTransmitRate = 0.0
  }
  private let state = Mutex(State())

  public init() {}

  public func read() -> PlatformNetworkInterfaceSnapshot? {
    state.withLock { s in s.read() }
  }
}

fileprivate extension NetworkInterfacePlatform.State {
  mutating func read() -> PlatformNetworkInterfaceSnapshot? {
    let now = Date()
    let preferred = activePrimaryInterfaceName()
    let refresh = now.timeIntervalSince(detailsLastRead) >= 15
    guard let counters = loadInterfaceCounters() else { return nil }
    var up: UInt64 = 0
    var down: UInt64 = 0
    for (name, counter) in counters where name.hasPrefix("en") {
      up = saturatingAdd(up, counter.outputBytes)
      down = saturatingAdd(down, counter.inputBytes)
    }
    var ifap: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&ifap) == 0, let head = ifap else { return nil }
    defer { freeifaddrs(head) }
    var links: [String: (Bool, String, Double)] = [:]
    var ips: [String: String] = [:]
    var firstLink = ""
    var firstIP = ""
    var cursor: UnsafeMutablePointer<ifaddrs>? = head
    while let iface = cursor {
      defer { cursor = iface.pointee.ifa_next }
      let name = decodeCString(iface.pointee.ifa_name)
      guard name.hasPrefix("en") else { continue }
      if let address = iface.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_LINK) {
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
          let baudrate = counters[name]?.baudrate ?? 0
          links[name] = (
            (iface.pointee.ifa_flags & UInt32(IFF_UP)) != 0, mac, Double(baudrate) / 1_000_000)
          if firstLink.isEmpty { firstLink = name }
        }
      }
      if refresh, let address = iface.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET)
      {
        var raw = address.pointee
        let ip = withUnsafeTemporaryAllocation(of: CChar.self, capacity: Int(INET_ADDRSTRLEN)) {
          buffer -> String in
          guard let base = buffer.baseAddress else { return "" }
          let written: UnsafePointer<CChar>? = withUnsafeMutablePointer(to: &raw) {
            pointer in
            pointer.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { address in
              var value = address.pointee.sin_addr
              return inet_ntop(AF_INET, &value, base, socklen_t(INET_ADDRSTRLEN))
            }
          }
          guard written != nil else { return "" }
          return decodeCString(UnsafePointer(base))
        }
        ips[name] = ip
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

  mutating func activePrimaryInterfaceName() -> String? {
    let now = Date()
    guard now.timeIntervalSince(primaryInterfaceLastRead) >= 15 else {
      return cachedPrimaryInterface
    }
    primaryInterfaceLastRead = now
    guard
      let dynamicStore = SCDynamicStoreCreate(nil, "mactop" as CFString, nil, nil),
      let global = SCDynamicStoreCopyValue(dynamicStore, "State:/Network/Global/IPv4" as CFString)
        as? [String: Any],
      let interface = global["PrimaryInterface"] as? String, !interface.isEmpty
    else { return nil }
    cachedPrimaryInterface = interface
    return interface
  }

  mutating func refreshInterfaceDetails(
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
        == (kSCNetworkInterfaceTypeIEEE80211 as String),
        let dynamicStore = SCDynamicStoreCreate(nil, "mactop" as CFString, nil, nil),
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

  private func loadInterfaceCounters() -> [String: InterfaceData64Counters]? {
    var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
    var size = 0
    guard sysctl(&mib, 6, nil, &size, nil, 0) == 0, size > 0 else { return nil }
    for _ in 0..<3 {
      let loaded = withUnsafeTemporaryAllocation(of: UInt8.self, capacity: size) { buffer in
        var actual = buffer.count
        guard let base = buffer.baseAddress else { return InterfaceCounterLoad.failed }
        guard sysctl(&mib, 6, base, &actual, nil, 0) == 0 else {
          return errno == ENOMEM ? InterfaceCounterLoad.retry : InterfaceCounterLoad.failed
        }
        guard actual >= 0, actual <= buffer.count else { return InterfaceCounterLoad.failed }
        return InterfaceCounterLoad.ready(
          interfaceData64Counters(in: UnsafeRawBufferPointer(start: base, count: actual)))
      }
      switch loaded {
      case .ready(let counters): return counters
      case .failed: return nil
      case .retry:
        guard sysctl(&mib, 6, nil, &size, nil, 0) == 0, size > 0 else { return nil }
      }
    }
    return nil
  }
}

private enum InterfaceCounterLoad {
  case ready([String: InterfaceData64Counters])
  case retry
  case failed
}

struct InterfaceData64Counters {
  var inputBytes: UInt64
  var outputBytes: UInt64
  var baudrate: UInt64
}

func interfaceData64Counters(in buffer: UnsafeRawBufferPointer) -> [String: InterfaceData64Counters] {
  var counters: [String: InterfaceData64Counters] = [:]
  let headerSize = MemoryLayout<if_msghdr2>.size
  var offset = 0
  while offset + 4 <= buffer.count {
    let length = Int(buffer.loadUnaligned(fromByteOffset: offset, as: UInt16.self))
    let type = buffer.loadUnaligned(fromByteOffset: offset + 3, as: UInt8.self)
    guard length >= 4, offset + length <= buffer.count else { break }
    if type == UInt8(RTM_IFINFO2), length >= headerSize,
      let name = interfaceName(in: buffer, range: (offset + headerSize)..<(offset + length))
    {
      let header = buffer.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
      counters[name] = InterfaceData64Counters(
        inputBytes: header.ifm_data.ifi_ibytes, outputBytes: header.ifm_data.ifi_obytes,
        baudrate: header.ifm_data.ifi_baudrate)
    }
    offset += length
  }
  return counters
}

private func interfaceName(in buffer: UnsafeRawBufferPointer, range: Range<Int>) -> String? {
  guard range.count >= 8 else { return nil }
  let family = buffer.loadUnaligned(fromByteOffset: range.lowerBound + 1, as: UInt8.self)
  let length = Int(buffer.loadUnaligned(fromByteOffset: range.lowerBound + 5, as: UInt8.self))
  let data = range.lowerBound + 8
  guard family == UInt8(AF_LINK), length > 0, data + length <= range.upperBound else { return nil }
  let bytes = UnsafeRawBufferPointer(rebasing: buffer[data..<(data + length)])
  return String(decoding: bytes, as: UTF8.self)
}
