import Darwin
import Foundation

// Shared process-row types and ranking/parsing helpers used by CPU, RAM, and network
// process readers. These helpers are not tied to any one metric source.

struct RankedProcessMetric {
    var pid: Int32
    var name: String
    var value: Double   // CPU: percent (0–100); RAM: bytes

    init(pid: Int32 = 0, name: String, value: Double) {
        self.pid = pid
        self.name = name
        self.value = value
    }
}
// FSCALE on Darwin/macOS: 1 << FSHIFT where FSHIFT=11, so FSCALE=2048.
let kFScale: Double = 2048.0

func allKinfoPctcpu() -> [Int32: UInt32] {
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
    var size = 0
    guard sysctl(&mib, 4, nil, &size, nil, 0) == 0, size > 0 else { return [:] }
    let stride = MemoryLayout<kinfo_proc>.stride
    let capacity = size / stride + 4
    var buf = [kinfo_proc](repeating: kinfo_proc(), count: capacity)
    var actualSize = capacity * stride
    guard sysctl(&mib, 4, &buf, &actualSize, nil, 0) == 0 else { return [:] }
    let found = actualSize / stride
    var result = [Int32: UInt32]()
    result.reserveCapacity(found)
    for p in buf.prefix(found) {
        let pid = p.kp_proc.p_pid
        guard pid > 0 else { continue }
        result[pid] = UInt32(p.kp_proc.p_pctcpu)
    }
    return result
}
// Mirrors rusage_info_v2 from <sys/resource.h> exactly (160 bytes).
struct RusageInfoV2 {
    var ri_uuid: (UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,
                  UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8) = (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0)
    var ri_user_time:             UInt64 = 0
    var ri_system_time:           UInt64 = 0
    var ri_pkg_idle_wkups:        UInt64 = 0
    var ri_interrupt_wkups:       UInt64 = 0
    var ri_pageins:               UInt64 = 0
    var ri_wired_size:            UInt64 = 0
    var ri_resident_size:         UInt64 = 0
    var ri_phys_footprint:        UInt64 = 0
    var ri_proc_start_abstime:    UInt64 = 0
    var ri_proc_exit_abstime:     UInt64 = 0
    var ri_child_user_time:       UInt64 = 0
    var ri_child_system_time:     UInt64 = 0
    var ri_child_pkg_idle_wkups:  UInt64 = 0
    var ri_child_interrupt_wkups: UInt64 = 0
    var ri_child_pageins:         UInt64 = 0
    var ri_child_elapsed_abstime: UInt64 = 0
    var ri_diskio_bytesread:      UInt64 = 0
    var ri_diskio_byteswritten:   UInt64 = 0
}

struct ProcTaskInfo {
    var pti_virtual_size: UInt64   = 0
    var pti_resident_size: UInt64  = 0
    var pti_total_user: UInt64     = 0
    var pti_total_system: UInt64   = 0
    var pti_threads_user: UInt64   = 0
    var pti_threads_system: UInt64 = 0
    var pti_policy: Int32          = 0
    var pti_faults: Int32          = 0
    var pti_pageins: Int32         = 0
    var pti_cow_faults: Int32      = 0
    var pti_messages_sent: Int32   = 0
    var pti_messages_received: Int32 = 0
    var pti_syscalls_mach: Int32   = 0
    var pti_syscalls_unix: Int32   = 0
    var pti_csw: Int32             = 0
    var pti_threadnum: Int32       = 0
    var pti_numrunning: Int32      = 0
    var pti_priority: Int32        = 0
}

let PROC_PIDTASKINFO: Int32 = 4

func processRusage(pid: Int32) -> RusageInfoV2? {
    var ru = RusageInfoV2()
    let ret = withUnsafeMutablePointer(to: &ru) { ptr in
        ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 20) { riPtr in
            proc_pid_rusage(pid, 2, riPtr)
        }
    }
    return ret == 0 ? ru : nil
}

func insertRankedMetric<T>(_ value: T, into top: inout [T], count: Int, by areInDescendingOrder: (T, T) -> Bool) {
    guard count > 0 else { return }
    top.append(value)
    top.sort(by: areInDescendingOrder)
    if top.count > count { top.removeLast() }
}

// Returns CPU% for one process given two rusage snapshots, or nil if the delta is unusable
// (elapsed zero, PID reused since last sample, or time went backwards).
func calculateCPUProcessUsagePercent(
    current: (time: UInt64, start: UInt64),
    previous: (time: UInt64, start: UInt64),
    elapsed: TimeInterval
) -> Double? {
    guard elapsed > 0,
          current.start == previous.start,
          current.time > previous.time else { return nil }
    return Double(current.time - previous.time) / 1_000_000_000.0 / elapsed * 100.0
}

// Parses /bin/ps -Aceo pid,pcpu,comm -r output into raw (pid, pct, comm) tuples.
// Skips the header line, stops at the first 0% entry (output is sorted descending),
// and handles comma decimal separators for non-English locales.
func parsePSProcessOutput(_ output: String, count: Int) -> [(pid: Int32, pct: Double, comm: String)] {
    var results: [(pid: Int32, pct: Double, comm: String)] = []
    var skipHeader = true
    for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
        if skipHeader { skipHeader = false; continue }
        let parts = line.trimmingCharacters(in: .whitespaces)
                        .components(separatedBy: .whitespaces)
                        .filter { !$0.isEmpty }
        guard parts.count >= 3,
              let pid = Int32(parts[0]),
              let pct = Double(parts[1].replacingOccurrences(of: ",", with: "."))
        else { continue }
        guard pct > 0 else { break }
        results.append((pid: pid, pct: pct, comm: parts[2...].joined(separator: " ")))
        if results.count >= count { break }
    }
    return results
}
