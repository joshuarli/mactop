import Darwin
import Foundation

// MARK: - CPU process reader
// Two paths selected once at init by probing proc_pid_rusage on PID 1 (root-owned launchd):
//
// Native path (com.apple.system-task-ports.read or setuid root):
//   Same-user procs → proc_pid_rusage ns delta (true instantaneous %).
//   Cross-user procs → sysctl p_pctcpu decay average (best available natively).
//
// PS path (no entitlement — the common case):
//   Runs /bin/ps -Aceo pid,pcpu,comm -r (setuid root, so sees all processes).
//   Returns p_pctcpu-based values for every process, consistent across users.

final class CPUProcessUsageReader {
    // Probe cross-user rusage access once. proc_pid_rusage on PID 1 (launchd, always
    // root-owned) succeeds only with com.apple.system-task-ports.read or setuid root.
    private let nativeCrossUser: Bool = {
        var ru = RusageInfoV2()
        return withUnsafeMutablePointer(to: &ru) { ptr in
            ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { riPtr in
                proc_pid_rusage(1, 2, riPtr) == 0
            }
        }
    }()

    private var previous: [Int32: (time: UInt64, start: UInt64)] = [:]
    private var previousTime: TimeInterval?
    private var nameCache: [Int32: String] = [:]

    func readTopCPUProcessMetrics(count limit: Int = 8) -> [RankedProcessMetric] {
        nativeCrossUser ? readNativeCPUProcessMetrics(count: limit) : readPSCPUProcessMetrics(count: limit)
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
                let totalTime = rusage.ri_user_time + rusage.ri_system_time
                current[pid] = (time: totalTime, start: rusage.ri_proc_start_abstime)

                guard let old = previous[pid],
                      let pct = calculateCPUProcessUsagePercent(
                          current: (time: totalTime, start: rusage.ri_proc_start_abstime),
                          previous: old,
                          elapsed: elapsed
                      ) else { continue }
                insertRankedMetric(RankedProcessMetric(pid: pid, name: processName(pid: pid), value: pct), into: &top, count: limit) {
                    $0.value > $1.value
                }
            } else if let pctcpu = kinfo[pid], pctcpu > 0 {
                let pct = Double(pctcpu) / kFScale * 100.0
                insertRankedMetric(RankedProcessMetric(pid: pid, name: processName(pid: pid), value: pct), into: &top, count: limit) {
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
            RankedProcessMetric(pid: entry.pid, name: processName(pid: entry.pid, fallback: entry.comm), value: entry.pct)
        }
    }

    private func processName(pid: Int32, fallback: String = "") -> String {
        if let cached = nameCache[pid] { return cached }
        let name = processDisplayName(pid: pid)
        // displayName returns "pid NNN" when proc_name yields nothing; prefer ps comm in that case
        let resolved = name == "pid \(pid)" && !fallback.isEmpty ? fallback : name
        nameCache[pid] = resolved
        return resolved
    }
}
