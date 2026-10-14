import Foundation
import mactopPlatform

public final class RAMProcessMemoryReader: @unchecked Sendable {
  private var nameCache: [Int32: String] = [:]

  public init() {}

  public func readTopRAMProcessMetrics(count limit: Int = 8) -> [RankedProcessMetric] {
    let pids = ProcessPlatform.allProcessIDs()
    var candidates: [(pid: Int32, memory: Double)] = []
    var activePIDs = Set<Int32>()

    for pid in pids {
      activePIDs.insert(pid)
      let mem: UInt64
      if let ru = processRusage(pid: pid), ru.physicalFootprint > 0 {
        mem = ru.physicalFootprint
      } else {
        guard let resident = ProcessPlatform.residentMemory(pid: pid) else { continue }
        mem = resident
      }

      guard Double(mem).isFinite else { continue }
      candidates.append((pid: pid, memory: Double(mem)))
    }

    candidates.sort { $0.memory > $1.memory }
    nameCache = nameCache.filter { activePIDs.contains($0.key) }
    guard limit > 0 else { return [] }
    return candidates.prefix(limit).map { item in
      RankedProcessMetric(pid: item.pid, name: processName(pid: item.pid), value: item.memory)
    }
  }

  private func processName(pid: Int32) -> String {
    if let cached = nameCache[pid] { return cached }

    let name = processDisplayName(pid: pid)
    nameCache[pid] = name
    return name
  }
}
