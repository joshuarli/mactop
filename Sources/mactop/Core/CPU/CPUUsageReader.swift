import Foundation
import Synchronization
import mactopPlatform

public enum CPUCoreKind: Sendable {
  case efficiency
  case performance
  case unknown
}

public struct CPUUsageDetail: Sendable {
  public var total: Double
  public var system: Double
  public var user: Double
  public var idle: Double
  public var usagePerCore: [Double]
  public var coreKinds: [CPUCoreKind]
  public var loadAvg1: Double
  public var loadAvg5: Double
  public var loadAvg15: Double
  public var uptime: String
  public var history: [MetricHistoryPoint<Double>]
  public var historyCapacity: Int
}

public final class CPUUsageReader: Sendable {
  fileprivate struct Tick: Sendable { var user, sys, idle, nice: Double }
  fileprivate struct State: Sendable {
    var prev: [Tick] = []
    var ticks: [Tick] = []
    var perCore: [Double] = []
    var history: ScalarHistory
    var coreKinds: [CPUCoreKind]
    var uptimeFormatter: DateComponentsFormatter
    var cachedUptimeMinute = -1
    var cachedUptime = "Unknown"
    var cachedLoadAvg = [Double](repeating: 0, count: 3)
    var loadAvgLastRead = Date.distantPast
    var loadAvgCacheInterval: TimeInterval = 5
  }
  private let state: Mutex<State>

  public init(updateInterval: Double = 1) {
    let coreKinds: [CPUCoreKind] =
      MachCPUPlatform.readHardwareSnapshot()?.coreKinds.map { kind in
        switch kind {
        case .efficiency: return .efficiency
        case .performance: return .performance
        case .unknown: return .unknown
        }
      } ?? []
    let form = DateComponentsFormatter()
    form.maximumUnitCount = 2
    form.unitsStyle = .full
    form.allowedUnits = [.day, .hour, .minute]
    state = Mutex(
      State(
        history: ScalarHistory(capacity: metricGraphSampleCapacity(updateInterval: updateInterval)),
        coreKinds: coreKinds,
        uptimeFormatter: form))
  }

  public func clearCPUUsageHistory() {
    state.withLock { s in
      s.prev.removeAll(keepingCapacity: true)
      s.ticks.removeAll(keepingCapacity: true)
      s.perCore.removeAll(keepingCapacity: true)
      s.history.removeAll()
    }
  }

  public func readCPUUsageDetail(includeHistory: Bool = false) -> CPUUsageDetail {
    state.withLock { s in s.read(includeHistory: includeHistory) }
  }
}

fileprivate extension CPUUsageReader.State {
  mutating func read(includeHistory: Bool) -> CPUUsageDetail {
    guard let snapshot = MachCPUPlatform.readHardwareSnapshot() else {
      return CPUUsageDetail(
        total: 0, system: 0, user: 0, idle: 1, usagePerCore: [],
        coreKinds: coreKinds,
        loadAvg1: 0, loadAvg5: 0, loadAvg15: 0, uptime: uptimeString(),
        history: includeHistory ? history.orderedValues : [], historyCapacity: history.capacity)
    }
    ticks.removeAll(keepingCapacity: true)
    ticks.append(
      contentsOf: snapshot.ticks.map {
        CPUUsageReader.Tick(user: $0.user, sys: $0.system, idle: $0.idle, nice: $0.nice)
      })
    guard !ticks.isEmpty else {
      return CPUUsageDetail(
        total: 0, system: 0, user: 0, idle: 1, usagePerCore: [],
        coreKinds: coreKinds,
        loadAvg1: 0, loadAvg5: 0, loadAvg15: 0, uptime: uptimeString(),
        history: includeHistory ? history.orderedValues : [], historyCapacity: history.capacity)
    }
    var totalUsage = 0.0
    var systemUsage = 0.0
    var userUsage = 0.0
    if includeHistory {
      perCore.removeAll(keepingCapacity: true)
      if perCore.capacity < ticks.count {
        perCore.reserveCapacity(ticks.count)
      }
    }

    if prev.count == ticks.count {
      for i in 0..<ticks.count {
        let du = ticks[i].user - prev[i].user
        let ds = ticks[i].sys - prev[i].sys
        let di = ticks[i].idle - prev[i].idle
        let dn = ticks[i].nice - prev[i].nice
        let total = du + ds + di + dn
        if total > 0 {
          let coreUsage = (du + ds + dn) / total
          totalUsage += coreUsage
          systemUsage += ds / total
          userUsage += (du + dn) / total
          if includeHistory {
            perCore.append(min(1, max(0, coreUsage)))
          }
        } else if includeHistory {
          perCore.append(0)
        }
      }
      let n = Double(ticks.count)
      totalUsage /= n
      systemUsage /= n
      userUsage /= n
    }

    swap(&prev, &ticks)

    let total = min(1, max(0, totalUsage))
    history.append(total)

    let loadAvg = loadAverage()

    return CPUUsageDetail(
      total: total,
      system: min(1, max(0, systemUsage)),
      user: min(1, max(0, userUsage)),
      idle: min(1, max(0, 1 - totalUsage)),
      usagePerCore: includeHistory ? perCore : [],
      coreKinds: coreKinds,
      loadAvg1: loadAvg[0],
      loadAvg5: loadAvg[1],
      loadAvg15: loadAvg[2],
      uptime: uptimeString(),
      history: includeHistory ? history.orderedValues : [],
      historyCapacity: history.capacity
    )
  }

  mutating func uptimeString() -> String {
    let elapsed = Int(Date().timeIntervalSince(MachCPUPlatform.bootDate))
    let minute = elapsed / 60
    guard minute != cachedUptimeMinute else { return cachedUptime }
    cachedUptimeMinute = minute
    cachedUptime = uptimeFormatter.string(from: TimeInterval(elapsed)) ?? "Unknown"
    return cachedUptime
  }

  mutating func loadAverage() -> [Double] {
    let now = Date()
    guard now.timeIntervalSince(loadAvgLastRead) >= loadAvgCacheInterval else {
      return cachedLoadAvg
    }
    loadAvgLastRead = now
    cachedLoadAvg = MachCPUPlatform.loadAverage()
    return cachedLoadAvg
  }
}
