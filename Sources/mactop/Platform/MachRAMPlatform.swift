import Darwin
import Foundation

public struct PlatformRAMSnapshot: Sendable {
  public let usedBytes: UInt64
  public let appBytes: UInt64
  public let wiredBytes: UInt64
  public let compressedBytes: UInt64
  public let freeBytes: UInt64
  public let swapBytes: UInt64
  public let totalBytes: UInt64
  public let pressureLevel: Int
}

public final class MachRAMPlatform: @unchecked Sendable {
  private let totalBytes: UInt64
  private let pageSize: UInt64
  private var cachedSwapBytes: UInt64 = 0
  private var cachedPressureLevel = 0
  private var slowStatsLastRead = Date.distantPast

  public init() {
    var memory: UInt64 = 0
    var memorySize = MemoryLayout<UInt64>.size
    sysctlbyname("hw.memsize", &memory, &memorySize, nil, 0)
    totalBytes = memory
    var page: vm_size_t = 0
    pageSize = host_page_size(mach_host_self(), &page) == KERN_SUCCESS ? UInt64(page) : 0
  }

  public func read() -> PlatformRAMSnapshot? {
    var stats = vm_statistics64()
    var count = mach_msg_type_number_t(
      MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
    guard
      withUnsafeMutablePointer(
        to: &stats,
        {
          $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
          }
        }) == KERN_SUCCESS, pageSize > 0
    else { return nil }
    let active = saturatingMultiply(UInt64(stats.active_count), pageSize)
    let inactive = saturatingMultiply(UInt64(stats.inactive_count), pageSize)
    let speculative = saturatingMultiply(UInt64(stats.speculative_count), pageSize)
    let wired = saturatingMultiply(UInt64(stats.wire_count), pageSize)
    let compressed = saturatingMultiply(UInt64(stats.compressor_page_count), pageSize)
    let reclaimablePages = saturatingAdd(
      UInt64(stats.purgeable_count), UInt64(stats.external_page_count))
    let reclaimable = saturatingMultiply(reclaimablePages, pageSize)
    let rawUsed = saturatingAdd(
      saturatingAdd(saturatingAdd(active, inactive), speculative),
      saturatingAdd(wired, compressed))
    let used = rawUsed > reclaimable ? rawUsed - reclaimable : 0
    refreshSlowStats()
    return PlatformRAMSnapshot(
      usedBytes: used,
      appBytes: used > saturatingAdd(wired, compressed)
        ? used - saturatingAdd(wired, compressed) : 0,
      wiredBytes: wired,
      compressedBytes: compressed,
      freeBytes: totalBytes > used ? totalBytes - used : 0,
      swapBytes: cachedSwapBytes,
      totalBytes: totalBytes,
      pressureLevel: cachedPressureLevel
    )
  }

  private func refreshSlowStats() {
    let now = Date()
    guard now.timeIntervalSince(slowStatsLastRead) >= 5 else { return }
    slowStatsLastRead = now
    var swap = xsw_usage()
    var swapSize = MemoryLayout<xsw_usage>.size
    if sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0) == 0 {
      cachedSwapBytes = swap.xsu_used
    }
    var pressure: Int32 = 0
    var pressureSize = MemoryLayout<Int32>.size
    if sysctlbyname("kern.memorystatus_vm_pressure_level", &pressure, &pressureSize, nil, 0) == 0 {
      cachedPressureLevel = pressure == 4 ? 2 : (pressure == 2 ? 1 : 0)
    }
  }

  private func saturatingAdd(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
    let (value, overflow) = lhs.addingReportingOverflow(rhs)
    return overflow ? .max : value
  }

  private func saturatingMultiply(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
    let (value, overflow) = lhs.multipliedReportingOverflow(by: rhs)
    return overflow ? .max : value
  }
}
