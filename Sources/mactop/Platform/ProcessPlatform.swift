import Darwin
import Foundation

public struct PlatformProcessUsageSnapshot: Sendable {
  public let userTime: UInt64
  public let systemTime: UInt64
  public let physicalFootprint: UInt64
  public let startTime: UInt64
}

public enum ProcessPlatform {
  public static func canReadRootProcess() -> Bool {
    readUsage(pid: 1) != nil
  }

  public static func readUsage(pid: Int32) -> PlatformProcessUsageSnapshot? {
    var usage = RusageInfoV2()
    let result = withUnsafeMutablePointer(to: &usage) { pointer in
      pointer.withMemoryRebound(
        to: rusage_info_t?.self,
        capacity: MemoryLayout<RusageInfoV2>.size / MemoryLayout<integer_t>.stride
      ) { rebound in
        proc_pid_rusage(pid, 2, rebound)
      }
    }
    guard result == 0 else { return nil }
    return PlatformProcessUsageSnapshot(
      userTime: usage.ri_user_time, systemTime: usage.ri_system_time,
      physicalFootprint: usage.ri_phys_footprint, startTime: usage.ri_proc_start_abstime)
  }

  public static func residentMemory(pid: Int32) -> UInt64? {
    var info = ProcTaskInfo()
    guard proc_pidinfo(pid, 4, 0, &info, Int32(MemoryLayout<ProcTaskInfo>.size)) > 0,
      info.pti_resident_size > 0
    else { return nil }
    return info.pti_resident_size
  }

  public static func allProcessIDs() -> [Int32] {
    let initialBytes = proc_listallpids(nil, 0)
    guard initialBytes > 0 else { return [] }
    var capacity = Int(initialBytes) / MemoryLayout<Int32>.size + 16
    guard capacity > 16, capacity <= 1_000_000 else { return [] }
    for _ in 0..<3 {
      var pids = [Int32](repeating: 0, count: Int(capacity))
      let copied = proc_listallpids(
        &pids, Int32(pids.count * MemoryLayout<Int32>.size))
      guard copied >= 0 else { return [] }
      let copiedCount = Int(copied) / MemoryLayout<Int32>.size
      if copiedCount < capacity {
        return pids.prefix(copiedCount).filter { $0 > 0 }
      }
      capacity = copiedCount + 16
      guard capacity <= 1_000_000 else { return [] }
    }
    return []
  }

  public static func allDecayCPUPercentages() -> [Int32: UInt32] {
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
    var size = 0
    guard sysctl(&mib, 4, nil, &size, nil, 0) == 0, size > 0 else { return [:] }
    let stride = MemoryLayout<kinfo_proc>.stride
    var processes = [kinfo_proc](repeating: kinfo_proc(), count: size / stride + 4)
    var actualSize = processes.count * stride
    guard sysctl(&mib, 4, &processes, &actualSize, nil, 0) == 0,
      actualSize >= 0, actualSize <= processes.count * stride
    else { return [:] }
    return processes.prefix(actualSize / stride).reduce(into: [:]) { result, process in
      if process.kp_proc.p_pid > 0 {
        result[process.kp_proc.p_pid] = UInt32(process.kp_proc.p_pctcpu)
      }
    }
  }

  public static func processName(pid: Int32) -> String {
    var buffer = [CChar](repeating: 0, count: 1024)
    proc_name(pid, &buffer, UInt32(buffer.count))
    return String(
      decoding: buffer.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
  }

  public static func processPath(pid: Int32) -> String? {
    var buffer = [CChar](repeating: 0, count: 4096)
    guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
    return String(
      decoding: buffer.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
  }

  private struct RusageInfoV2 {
    var ri_uuid = (
      UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0),
      UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0)
    )
    var ri_user_time: UInt64 = 0
    var ri_system_time: UInt64 = 0
    var ri_pkg_idle_wkups: UInt64 = 0
    var ri_interrupt_wkups: UInt64 = 0
    var ri_pageins: UInt64 = 0
    var ri_wired_size: UInt64 = 0
    var ri_resident_size: UInt64 = 0
    var ri_phys_footprint: UInt64 = 0
    var ri_proc_start_abstime: UInt64 = 0
    var ri_proc_exit_abstime: UInt64 = 0
    var ri_child_user_time: UInt64 = 0
    var ri_child_system_time: UInt64 = 0
    var ri_child_pkg_idle_wkups: UInt64 = 0
    var ri_child_interrupt_wkups: UInt64 = 0
    var ri_child_pageins: UInt64 = 0
    var ri_child_elapsed_abstime: UInt64 = 0
    var ri_diskio_bytesread: UInt64 = 0
    var ri_diskio_byteswritten: UInt64 = 0
  }

  private struct ProcTaskInfo {
    var pti_virtual_size: UInt64 = 0
    var pti_resident_size: UInt64 = 0
    var pti_total_user: UInt64 = 0
    var pti_total_system: UInt64 = 0
    var pti_threads_user: UInt64 = 0
    var pti_threads_system: UInt64 = 0
    var pti_policy: Int32 = 0
    var pti_faults: Int32 = 0
    var pti_pageins: Int32 = 0
    var pti_cow_faults: Int32 = 0
    var pti_messages_sent: Int32 = 0
    var pti_messages_received: Int32 = 0
    var pti_syscalls_mach: Int32 = 0
    var pti_syscalls_unix: Int32 = 0
    var pti_csw: Int32 = 0
    var pti_threadnum: Int32 = 0
    var pti_numrunning: Int32 = 0
    var pti_priority: Int32 = 0
  }
}
