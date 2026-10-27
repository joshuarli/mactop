import Foundation
import mactopPlatform

public struct NetworkUsageDetail: Sendable {
  public var upload: Double
  public var download: Double
  public var totalUp: UInt64
  public var totalDown: UInt64
  public var interfaceName: String
  public var displayName: String
  public var macAddress: String
  public var ssid: String?
  public var localIP: String
  public var transmitRate: Double
  public var isUp: Bool
  public var history: [MetricHistoryPoint<(up: Double, down: Double)>]
  public var historyCapacity: Int
}

public final class NetworkInterfaceReader: @unchecked Sendable {
  private let readSnapshot: @Sendable () -> PlatformNetworkInterfaceSnapshot?
  private var previousUp: UInt64 = 0
  private var previousDown: UInt64 = 0
  private var cumulativeUp: UInt64 = 0
  private var cumulativeDown: UInt64 = 0
  private var lastTime = Date()
  private var history: PairHistory

  public convenience init(updateInterval: Double = 1) {
    let platform = NetworkInterfacePlatform()
    self.init(updateInterval: updateInterval) { platform.read() }
  }

  init(
    updateInterval: Double = 1,
    readSnapshot: @escaping @Sendable () -> PlatformNetworkInterfaceSnapshot?
  ) {
    self.readSnapshot = readSnapshot
    history = PairHistory(capacity: metricGraphSampleCapacity(updateInterval: updateInterval))
  }

  public func clearNetworkUsageHistory() {
    previousUp = 0
    previousDown = 0
    cumulativeUp = 0
    cumulativeDown = 0
    lastTime = Date()
    history.removeAll()
  }

  public func readNetworkUsageDetail(includeHistory: Bool = false) -> NetworkUsageDetail {
    let now = Date()
    guard let snapshot = readSnapshot() else {
      return detail(includeHistory: includeHistory)
    }
    let elapsed = now.timeIntervalSince(lastTime)
    let upload = networkCounterRate(
      current: snapshot.uploadBytes, previous: previousUp, elapsed: elapsed)
    let download = networkCounterRate(
      current: snapshot.downloadBytes, previous: previousDown, elapsed: elapsed)
    cumulativeUp = networkSessionTotal(
      current: snapshot.uploadBytes, previous: previousUp, total: cumulativeUp)
    cumulativeDown = networkSessionTotal(
      current: snapshot.downloadBytes, previous: previousDown, total: cumulativeDown)
    previousUp = snapshot.uploadBytes
    previousDown = snapshot.downloadBytes
    lastTime = now
    history.append(up: upload, down: download)
    return NetworkUsageDetail(
      upload: upload, download: download, totalUp: cumulativeUp, totalDown: cumulativeDown,
      interfaceName: snapshot.interfaceName, displayName: snapshot.displayName,
      macAddress: snapshot.macAddress, ssid: snapshot.ssid, localIP: snapshot.localIP,
      transmitRate: snapshot.transmitRate, isUp: snapshot.isUp,
      history: includeHistory ? history.orderedValues : [], historyCapacity: history.capacity)
  }

  private func detail(includeHistory: Bool) -> NetworkUsageDetail {
    NetworkUsageDetail(
      upload: 0, download: 0, totalUp: cumulativeUp, totalDown: cumulativeDown, interfaceName: "",
      displayName: "", macAddress: "", ssid: nil, localIP: "", transmitRate: 0, isUp: false,
      history: includeHistory ? history.orderedValues : [], historyCapacity: history.capacity)
  }
}

func networkCounterRate(current: UInt64, previous: UInt64, elapsed: TimeInterval) -> Double {
  guard elapsed > 0, previous > 0, current >= previous else { return 0 }
  let rate = Double(current - previous) / elapsed
  return rate.isFinite ? rate : 0
}

func networkSessionTotal(current: UInt64, previous: UInt64, total: UInt64) -> UInt64 {
  guard previous > 0, current >= previous else { return total }
  return saturatingAdd(total, current - previous)
}

private func saturatingAdd(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
  let (value, overflow) = lhs.addingReportingOverflow(rhs)
  return overflow ? .max : value
}
