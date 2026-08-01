import Foundation
import mactopPlatform

// Reads aggregate memory pressure, VM usage, swap usage, and RAM chart history
// from the platform memory snapshot.
public struct RAMUsageDetail: Sendable {
  public var total: Double
  public var appBytes: UInt64
  public var wiredBytes: UInt64
  public var compressedBytes: UInt64
  public var freeBytes: UInt64
  public var swapBytes: UInt64
  public var totalBytes: UInt64
  public var pressureLevel: Int  // 0=normal, 1=warn, 2=critical
  public var history: [MetricHistoryPoint<Double>]
  public var historyCapacity: Int
}

public final class RAMUsageReader: @unchecked Sendable {
  private let platformReader = MachRAMPlatform()
  private var history: ScalarHistory
  public init(updateInterval: Double = 1) {
    history = ScalarHistory(capacity: metricGraphSampleCapacity(updateInterval: updateInterval))
  }

  public func clearRAMUsageHistory() {
    history.removeAll()
  }

  public func readRAMUsageDetail(includeHistory: Bool = false) -> RAMUsageDetail {
    guard let snapshot = platformReader.read() else {
      return RAMUsageDetail(
        total: 0, appBytes: 0, wiredBytes: 0, compressedBytes: 0,
        freeBytes: 0, swapBytes: 0, totalBytes: 0, pressureLevel: 0,
        history: includeHistory ? history.orderedValues : [], historyCapacity: history.capacity)
    }
    let fraction =
      snapshot.totalBytes > 0 ? min(1, Double(snapshot.usedBytes) / Double(snapshot.totalBytes)) : 0
    history.append(fraction)

    return RAMUsageDetail(
      total: fraction,
      appBytes: snapshot.appBytes,
      wiredBytes: snapshot.wiredBytes,
      compressedBytes: snapshot.compressedBytes,
      freeBytes: snapshot.freeBytes,
      swapBytes: snapshot.swapBytes,
      totalBytes: snapshot.totalBytes,
      pressureLevel: snapshot.pressureLevel,
      history: includeHistory ? history.orderedValues : [],
      historyCapacity: history.capacity
    )
  }

}
