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
  private let platformReader = NetworkInterfacePlatform()
  private var previousUp: UInt64 = 0
  private var previousDown: UInt64 = 0
  private var cumulativeUp: UInt64 = 0
  private var cumulativeDown: UInt64 = 0
  private var lastTime = Date()
  private var history: PairHistory

  public init(updateInterval: Double = 1) {
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
    guard let snapshot = platformReader.read() else {
      return detail(includeHistory: includeHistory)
    }
    let elapsed = now.timeIntervalSince(lastTime)
    let upload = networkCounterRate(
      current: snapshot.uploadBytes, previous: previousUp, elapsed: elapsed)
    let download = networkCounterRate(
      current: snapshot.downloadBytes, previous: previousDown, elapsed: elapsed)
    if snapshot.uploadBytes >= previousUp {
      cumulativeUp = saturatingAdd(cumulativeUp, snapshot.uploadBytes - previousUp)
    }
    if snapshot.downloadBytes >= previousDown {
      cumulativeDown = saturatingAdd(cumulativeDown, snapshot.downloadBytes - previousDown)
    }
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

private func saturatingAdd(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
  let (value, overflow) = lhs.addingReportingOverflow(rhs)
  return overflow ? .max : value
}
