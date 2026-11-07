import Foundation
import Synchronization
import mactopPlatform

public struct RAMUsageDetail: Sendable {
  public var total: Double
  public var appBytes: UInt64
  public var wiredBytes: UInt64
  public var compressedBytes: UInt64
  public var freeBytes: UInt64
  public var swapBytes: UInt64
  public var swapFileBytes: UInt64
  public var totalBytes: UInt64
  public var pressureLevel: Int  // 0=normal, 1=warn, 2=critical
  public var history: [MetricHistoryPoint<Double>]
  public var appHistory: [MetricHistoryPoint<Double>]
  public var wiredHistory: [MetricHistoryPoint<Double>]
  public var compressedHistory: [MetricHistoryPoint<Double>]
  public var freeHistory: [MetricHistoryPoint<Double>]
  public var historyCapacity: Int
}

public final class RAMUsageReader: Sendable {
  private let platformReader = MachRAMPlatform()
  private struct State: Sendable {
    var history: ScalarHistory
    var appHistory: ScalarHistory
    var wiredHistory: ScalarHistory
    var compressedHistory: ScalarHistory
    var freeHistory: ScalarHistory
  }
  private let state: Mutex<State>

  public init(updateInterval: Double = 1) {
    let capacity = metricGraphSampleCapacity(updateInterval: updateInterval)
    state = Mutex(
      State(
        history: ScalarHistory(capacity: capacity),
        appHistory: ScalarHistory(capacity: capacity),
        wiredHistory: ScalarHistory(capacity: capacity),
        compressedHistory: ScalarHistory(capacity: capacity),
        freeHistory: ScalarHistory(capacity: capacity)))
  }

  public func clearRAMUsageHistory() {
    state.withLock { s in
      s.history.removeAll()
      s.appHistory.removeAll()
      s.wiredHistory.removeAll()
      s.compressedHistory.removeAll()
      s.freeHistory.removeAll()
    }
  }

  public func readRAMUsageDetail(includeHistory: Bool = false) -> RAMUsageDetail {
    guard let snapshot = platformReader.read() else {
      return state.withLock { s in
        RAMUsageDetail(
          total: 0, appBytes: 0, wiredBytes: 0, compressedBytes: 0,
          freeBytes: 0, swapBytes: 0, swapFileBytes: 0, totalBytes: 0, pressureLevel: 0,
          history: includeHistory ? s.history.orderedValues : [],
          appHistory: includeHistory ? s.appHistory.orderedValues : [],
          wiredHistory: includeHistory ? s.wiredHistory.orderedValues : [],
          compressedHistory: includeHistory ? s.compressedHistory.orderedValues : [],
          freeHistory: includeHistory ? s.freeHistory.orderedValues : [],
          historyCapacity: s.history.capacity)
      }
    }
    func fraction(_ bytes: UInt64) -> Double {
      snapshot.totalBytes > 0 ? min(1, Double(bytes) / Double(snapshot.totalBytes)) : 0
    }
    let usedFraction = fraction(snapshot.usedBytes)

    return state.withLock { s in
      s.history.append(usedFraction)
      s.appHistory.append(fraction(snapshot.appBytes))
      s.wiredHistory.append(fraction(snapshot.wiredBytes))
      s.compressedHistory.append(fraction(snapshot.compressedBytes))
      s.freeHistory.append(fraction(snapshot.freeBytes))
      return RAMUsageDetail(
        total: usedFraction,
        appBytes: snapshot.appBytes,
        wiredBytes: snapshot.wiredBytes,
        compressedBytes: snapshot.compressedBytes,
        freeBytes: snapshot.freeBytes,
        swapBytes: snapshot.swapBytes,
        swapFileBytes: snapshot.swapFileBytes,
        totalBytes: snapshot.totalBytes,
        pressureLevel: snapshot.pressureLevel,
        history: includeHistory ? s.history.orderedValues : [],
        appHistory: includeHistory ? s.appHistory.orderedValues : [],
        wiredHistory: includeHistory ? s.wiredHistory.orderedValues : [],
        compressedHistory: includeHistory ? s.compressedHistory.orderedValues : [],
        freeHistory: includeHistory ? s.freeHistory.orderedValues : [],
        historyCapacity: s.history.capacity
      )
    }
  }

}
