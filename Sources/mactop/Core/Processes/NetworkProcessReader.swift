import Foundation
import mactopPlatform

// Reads per-process network byte counters from the typed private-ABI platform boundary.
public final class NetworkProcessReader: @unchecked Sendable {
  private lazy var platformReader = PlatformNetworkProcessReader()
  private var previous: [Int32: (name: String, input: UInt64, output: UInt64)] = [:]
  private var previousTime = Date.distantPast

  public init() {}

  public func readTopNetworkProcessMetrics(count limit: Int = 8) -> [RankedProcessMetric] {
    guard let platformReader else { return [] }
    let now = Date()
    let elapsed = now.timeIntervalSince(previousTime)
    platformReader.refresh()
    let current: [Int32: (name: String, input: UInt64, output: UInt64)] = platformReader.counters()
      .reduce(into: [:]) { result, counter in
        result[counter.pid] = (counter.name, counter.inputBytes, counter.outputBytes)
      }
    defer {
      previous = current
      previousTime = now
    }
    guard elapsed > 0, !previous.isEmpty else { return [] }
    var top: [(pid: Int32, rate: Double)] = []
    for (pid, value) in current {
      guard let old = previous[pid] else { continue }
      let input = value.input >= old.input ? value.input - old.input : 0
      let output = value.output >= old.output ? value.output - old.output : 0
      let rate = Double(input + output) / elapsed
      guard rate > 0 else { continue }
      insertRankedMetric((pid: pid, rate: rate), into: &top, count: limit) { $0.rate > $1.rate }
    }
    return top.compactMap { item in
      guard let name = current[item.pid]?.name, !name.isEmpty else { return nil }
      return RankedProcessMetric(pid: item.pid, name: name, value: item.rate)
    }
  }
}
