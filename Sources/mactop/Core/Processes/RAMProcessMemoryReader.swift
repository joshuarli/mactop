import Foundation
import mactopPlatform

public final class RAMProcessMemoryReader: @unchecked Sendable {
  private var nameCache: [Int32: String] = [:]

  public init() {}

  public func readTopRAMProcessMetrics(count limit: Int = 8) -> [RankedProcessMetric] {
    let pids = ProcessPlatform.allProcessIDs()
    var top: [RankedProcessMetric] = []
    var activePIDs = Set<Int32>()

    for pid in pids {
      activePIDs.insert(pid)
      // Try physical footprint first (matches Activity Monitor); fall back to resident memory.
      let mem: UInt64
      if let ru = processRusage(pid: pid), ru.physicalFootprint > 0 {
        mem = ru.physicalFootprint
      } else {
        guard let resident = ProcessPlatform.residentMemory(pid: pid) else { continue }
        mem = resident
      }

      guard Double(mem).isFinite else { continue }
      insertRankedMetric(
        RankedProcessMetric(pid: pid, name: processName(pid: pid), value: Double(mem)), into: &top,
        count: limit
      ) {
        $0.value > $1.value
      }
    }
    nameCache = nameCache.filter { activePIDs.contains($0.key) }
    return top
  }

  private func processName(pid: Int32) -> String {
    if let cached = nameCache[pid] { return cached }

    let name = processDisplayName(pid: pid)
    nameCache[pid] = name
    return name
  }
}
