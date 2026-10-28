import Foundation
import Synchronization
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

public final class NetworkInterfaceReader: Sendable {
  private let readSnapshot: @Sendable () -> PlatformNetworkInterfaceSnapshot?
  fileprivate struct State: Sendable {
    var previousUp: UInt64 = 0
    var previousDown: UInt64 = 0
    var cumulativeUp: UInt64 = 0
    var cumulativeDown: UInt64 = 0
    var lastTime = Date()
    var history: PairHistory
  }
  private let state: Mutex<State>

  public convenience init(updateInterval: Double = 1) {
    let platform = NetworkInterfacePlatform()
    self.init(updateInterval: updateInterval) { platform.read() }
  }

  init(
    updateInterval: Double = 1,
    readSnapshot: @escaping @Sendable () -> PlatformNetworkInterfaceSnapshot?
  ) {
    self.readSnapshot = readSnapshot
    state = Mutex(
      State(history: PairHistory(capacity: metricGraphSampleCapacity(updateInterval: updateInterval))))
  }

  public func clearNetworkUsageHistory() {
    state.withLock { s in
      s.previousUp = 0
      s.previousDown = 0
      s.cumulativeUp = 0
      s.cumulativeDown = 0
      s.lastTime = Date()
      s.history.removeAll()
    }
  }

  public func readNetworkUsageDetail(includeHistory: Bool = false) -> NetworkUsageDetail {
    let now = Date()
    guard let snapshot = readSnapshot() else {
      return state.withLock { s in s.detail(includeHistory: includeHistory) }
    }
    return state.withLock { s in s.read(snapshot: snapshot, now: now, includeHistory: includeHistory)
    }
  }
}

fileprivate extension NetworkInterfaceReader.State {
  mutating func read(snapshot: PlatformNetworkInterfaceSnapshot, now: Date, includeHistory: Bool)
    -> NetworkUsageDetail
  {
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

  func detail(includeHistory: Bool) -> NetworkUsageDetail {
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
