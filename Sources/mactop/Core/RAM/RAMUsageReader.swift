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
  public var historyCapacity: Int
}

public final class RAMUsageReader: Sendable {
  private let platformReader = MachRAMPlatform()
  private struct State: Sendable {
    var history: ScalarHistory
  }
  private let state: Mutex<State>

  public init(updateInterval: Double = 1) {
    state = Mutex(
      State(history: ScalarHistory(capacity: metricGraphSampleCapacity(updateInterval: updateInterval))))
  }

  public func clearRAMUsageHistory() {
    state.withLock { $0.history.removeAll() }
  }

  public func readRAMUsageDetail(includeHistory: Bool = false) -> RAMUsageDetail {
    guard let snapshot = platformReader.read() else {
      return state.withLock { s in
        RAMUsageDetail(
          total: 0, appBytes: 0, wiredBytes: 0, compressedBytes: 0,
          freeBytes: 0, swapBytes: 0, swapFileBytes: 0, totalBytes: 0, pressureLevel: 0,
          history: includeHistory ? s.history.orderedValues : [],
          historyCapacity: s.history.capacity)
      }
    }
    let fraction =
      snapshot.totalBytes > 0 ? min(1, Double(snapshot.usedBytes) / Double(snapshot.totalBytes)) : 0

    return state.withLock { s in
      s.history.append(fraction)
      return RAMUsageDetail(
        total: fraction,
        appBytes: snapshot.appBytes,
        wiredBytes: snapshot.wiredBytes,
        compressedBytes: snapshot.compressedBytes,
        freeBytes: snapshot.freeBytes,
        swapBytes: snapshot.swapBytes,
        swapFileBytes: snapshot.swapFileBytes,
        totalBytes: snapshot.totalBytes,
        pressureLevel: snapshot.pressureLevel,
        history: includeHistory ? s.history.orderedValues : [],
        historyCapacity: s.history.capacity
      )
    }
  }

}
