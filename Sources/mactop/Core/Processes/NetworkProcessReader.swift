import Foundation
import mactopPlatform

public final class NetworkProcessReader: @unchecked Sendable {
  private lazy var platformReader = PlatformNetworkProcessReader()
  private var accounting = NetworkProcessAccounting()
  private var previousTime = Date.distantPast

  public init() {}

  public func readTopNetworkProcessMetrics(count limit: Int = 8) -> [RankedProcessMetric] {
    guard let platformReader else { return [] }
    platformReader.refresh()
    let counters = platformReader.counters()
    let now = Date()
    let elapsed = now.timeIntervalSince(previousTime)
    defer { previousTime = now }
    return accounting.metrics(counters: counters, elapsed: elapsed, limit: limit)
  }
}

struct NetworkProcessAccounting {
  private var previous: [UUID: PlatformNetworkProcessCounter] = [:]

  mutating func metrics(
    counters: [PlatformNetworkProcessCounter], elapsed: TimeInterval, limit: Int
  ) -> [RankedProcessMetric] {
    defer { previous = Dictionary(uniqueKeysWithValues: counters.map { ($0.sourceID, $0) }) }
    guard elapsed.isFinite, elapsed > 0 else { return [] }
    var processes: [Int32: RankedProcessMetric] = [:]
    for counter in counters {
      guard let old = previous[counter.sourceID], old.pid == counter.pid,
        counter.inputBytes >= old.inputBytes, counter.outputBytes >= old.outputBytes
      else { continue }
      let bytes = Double(counter.inputBytes - old.inputBytes)
        + Double(counter.outputBytes - old.outputBytes)
      let rate = bytes / elapsed
      guard rate.isFinite, rate > 0 else { continue }
      let total = (processes[counter.pid]?.value ?? 0) + rate
      let name = counter.name.isEmpty ? processes[counter.pid]?.name ?? "" : counter.name
      processes[counter.pid] = RankedProcessMetric(
        pid: counter.pid, name: name, value: total)
    }
    var top: [RankedProcessMetric] = []
    for metric in processes.values where !metric.name.isEmpty {
      insertRankedMetric(metric, into: &top, count: limit) {
        $0.value == $1.value ? $0.pid < $1.pid : $0.value > $1.value
      }
    }
    return top
  }
}
