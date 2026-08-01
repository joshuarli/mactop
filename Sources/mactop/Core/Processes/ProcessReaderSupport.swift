import Foundation
import mactopPlatform

public struct RankedProcessMetric: Sendable {
  public var pid: Int32
  public var name: String
  public var value: Double

  public init(pid: Int32 = 0, name: String, value: Double) {
    self.pid = pid
    self.name = name
    self.value = value
  }
}

let kFScale: Double = 2048.0

func allKinfoPctcpu() -> [Int32: UInt32] {
  ProcessPlatform.allDecayCPUPercentages()
}

func processRusage(pid: Int32) -> PlatformProcessUsageSnapshot? {
  ProcessPlatform.readUsage(pid: pid)
}

func insertRankedMetric<T>(
  _ value: T, into top: inout [T], count: Int, by areInDescendingOrder: (T, T) -> Bool
) {
  guard count > 0 else { return }
  top.append(value)
  top.sort(by: areInDescendingOrder)
  if top.count > count { top.removeLast() }
}

func calculateCPUProcessUsagePercent(
  current: (time: UInt64, start: UInt64),
  previous: (time: UInt64, start: UInt64),
  elapsed: TimeInterval
) -> Double? {
  guard elapsed > 0, current.start == previous.start, current.time > previous.time else {
    return nil
  }
  return Double(current.time - previous.time) / 1_000_000_000.0 / elapsed * 100.0
}

func parsePSProcessOutput(_ output: String, count: Int) -> [(pid: Int32, pct: Double, comm: String)]
{
  var results: [(pid: Int32, pct: Double, comm: String)] = []
  var skipHeader = true
  for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
    if skipHeader {
      skipHeader = false
      continue
    }
    let parts = line.trimmingCharacters(in: .whitespaces).components(separatedBy: .whitespaces)
      .filter { !$0.isEmpty }
    guard parts.count >= 3, let pid = Int32(parts[0]),
      let pct = Double(parts[1].replacingOccurrences(of: ",", with: "."))
    else { continue }
    guard pct > 0 else { break }
    results.append((pid: pid, pct: pct, comm: parts[2...].joined(separator: " ")))
    if results.count >= count { break }
  }
  return results
}
