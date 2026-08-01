import Foundation
import mactopPlatform

// MARK: - CPU process reader
// Two paths selected once at init by probing root-process telemetry:
//
// Native path (com.apple.system-task-ports.read or setuid root):
//   Same-user procs → nanosecond deltas (true instantaneous %).
//   Cross-user procs → decay-average percentages (best available natively).
//
// PS path (no entitlement — the common case):
//   Runs /bin/ps -Aceo pid,pcpu,comm -r (setuid root, so sees all processes).
//   Returns p_pctcpu-based values for every process, consistent across users.

public final class CPUProcessUsageReader: @unchecked Sendable {
  // Probe cross-user telemetry access once through the platform boundary.
  private let nativeCrossUser = ProcessPlatform.canReadRootProcess()

  private var previous: [Int32: (time: UInt64, start: UInt64)] = [:]
  private var previousTime: TimeInterval?
  private var nameCache: [Int32: String] = [:]

  public init() {}

  public func readTopCPUProcessMetrics(count limit: Int = 8) -> [RankedProcessMetric] {
    nativeCrossUser
      ? readNativeCPUProcessMetrics(count: limit) : readPSCPUProcessMetrics(count: limit)
  }

  private func readNativeCPUProcessMetrics(count limit: Int) -> [RankedProcessMetric] {
    let now = ProcessInfo.processInfo.systemUptime
    let kinfo = allKinfoPctcpu()
    guard !kinfo.isEmpty else { return [] }

    var current: [Int32: (time: UInt64, start: UInt64)] = [:]
    current.reserveCapacity(kinfo.count)
    var top: [RankedProcessMetric] = []
    let elapsed = previousTime.map { now - $0 } ?? 0

    for pid in kinfo.keys {
      if let rusage = processRusage(pid: pid) {
        let totalTime = rusage.userTime + rusage.systemTime
        current[pid] = (time: totalTime, start: rusage.startTime)

        guard let old = previous[pid],
          let pct = calculateCPUProcessUsagePercent(
            current: (time: totalTime, start: rusage.startTime),
            previous: old,
            elapsed: elapsed
          )
        else { continue }
        insertRankedMetric(
          RankedProcessMetric(pid: pid, name: processName(pid: pid), value: pct), into: &top,
          count: limit
        ) {
          $0.value > $1.value
        }
      } else if let pctcpu = kinfo[pid], pctcpu > 0 {
        let pct = Double(pctcpu) / kFScale * 100.0
        insertRankedMetric(
          RankedProcessMetric(pid: pid, name: processName(pid: pid), value: pct), into: &top,
          count: limit
        ) {
          $0.value > $1.value
        }
      }
    }

    previous = current
    nameCache = nameCache.filter { kinfo[$0.key] != nil }
    previousTime = now
    return top
  }

  private func readPSCPUProcessMetrics(count limit: Int) -> [RankedProcessMetric] {
    let task = Process()
    task.launchPath = "/bin/ps"
    task.arguments = ["-Aceo", "pid,pcpu,comm", "-r"]
    let outPipe = Pipe()
    task.standardOutput = outPipe
    task.standardError = Pipe()
    defer {
      outPipe.fileHandleForReading.closeFile()
      (task.standardError as? Pipe)?.fileHandleForReading.closeFile()
    }
    do { try task.run() } catch { return [] }
    let data = outPipe.fileHandleForReading.readDataToEndOfFile()
    task.waitUntilExit()
    guard let output = String(data: data, encoding: .utf8) else { return [] }
    return parsePSProcessOutput(output, count: limit).map { entry in
      RankedProcessMetric(
        pid: entry.pid, name: processName(pid: entry.pid, fallback: entry.comm), value: entry.pct)
    }
  }

  private func processName(pid: Int32, fallback: String = "") -> String {
    if let cached = nameCache[pid] { return cached }
    let name = processDisplayName(pid: pid)
    // The platform display name returns "pid NNN" when no process name exists; prefer ps comm then.
    let resolved = name == "pid \(pid)" && !fallback.isEmpty ? fallback : name
    nameCache[pid] = resolved
    return resolved
  }
}
