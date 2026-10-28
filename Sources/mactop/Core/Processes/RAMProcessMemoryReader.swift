import Foundation
import Synchronization
import mactopPlatform

public final class RAMProcessMemoryReader: Sendable {
  private struct State: Sendable {
    var nameCache: [Int32: String] = [:]
  }
  private let state = Mutex(State())

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
    guard limit > 0 else { return [] }
    return state.withLock { s in
      s.nameCache = s.nameCache.filter { activePIDs.contains($0.key) }
      return candidates.prefix(limit).map { item in
        let name: String
        if let cached = s.nameCache[item.pid] {
          name = cached
        } else {
          name = processDisplayName(pid: item.pid)
          s.nameCache[item.pid] = name
        }
        return RankedProcessMetric(pid: item.pid, name: name, value: item.memory)
      }
    }
  }
}
