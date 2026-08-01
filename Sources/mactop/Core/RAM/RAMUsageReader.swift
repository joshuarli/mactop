import Darwin
import Foundation

// Reads aggregate memory pressure, VM usage, swap usage, and RAM chart history
// from Mach VM statistics and sysctl.
struct RAMUsageDetail {
    var total: Double
    var appBytes: UInt64
    var wiredBytes: UInt64
    var compressedBytes: UInt64
    var freeBytes: UInt64
    var swapBytes: UInt64
    var totalBytes: UInt64
    var pressureLevel: Int   // 0=normal, 1=warn, 2=critical
    var history: [MetricHistoryPoint<Double>]
    var historyCapacity: Int
}

final class RAMUsageReader {
    private let totalBytes: UInt64 = {
        var n: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        sysctlbyname("hw.memsize", &n, &size, nil, 0)
        return n
    }()
    private var history: ScalarHistory
    private var cachedSwapBytes: UInt64 = 0
    private var cachedPressureLevel = 0
    private var slowStatsLastRead = Date.distantPast
    private let slowStatsCacheInterval: TimeInterval = 5

    init(updateInterval: Double = 1) {
        history = ScalarHistory(capacity: metricGraphSampleCapacity(updateInterval: updateInterval))
    }

    func clearRAMUsageHistory() {
        history.removeAll()
    }

    func readRAMUsageDetail(includeHistory: Bool = false) -> RAMUsageDetail {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size
        )
        guard withUnsafeMutablePointer(to: &stats, {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }) == KERN_SUCCESS else {
            return RAMUsageDetail(total: 0, appBytes: 0, wiredBytes: 0, compressedBytes: 0,
                             freeBytes: 0, swapBytes: 0, totalBytes: totalBytes, pressureLevel: 0,
                             history: includeHistory ? history.orderedValues : [], historyCapacity: history.capacity)
        }

        let page = UInt64(vm_page_size)
        let active      = UInt64(stats.active_count)          * page
        let inactive    = UInt64(stats.inactive_count)        * page
        let speculative = UInt64(stats.speculative_count)     * page
        let wired       = UInt64(stats.wire_count)            * page
        let compressed  = UInt64(stats.compressor_page_count) * page
        let purgeable   = UInt64(stats.purgeable_count)       * page
        let external    = UInt64(stats.external_page_count)   * page

        // Stats' formula: used excludes purgeable (reclaimable) and external (file-backed) pages
        let rawUsed = active + inactive + speculative + wired + compressed
        let reclaimable = purgeable + external
        let used = rawUsed > reclaimable ? rawUsed - reclaimable : 0
        let app  = used > wired + compressed ? used - wired - compressed : 0
        let free = totalBytes > used ? totalBytes - used : 0

        refreshCachedRAMSystemStatsIfNeeded()

        let fraction = totalBytes > 0 ? min(1, Double(used) / Double(totalBytes)) : 0
        history.append(fraction)

        return RAMUsageDetail(
            total: fraction,
            appBytes: app,
            wiredBytes: wired,
            compressedBytes: compressed,
            freeBytes: free,
            swapBytes: cachedSwapBytes,
            totalBytes: totalBytes,
            pressureLevel: cachedPressureLevel,
            history: includeHistory ? history.orderedValues : [],
            historyCapacity: history.capacity
        )
    }

    private func refreshCachedRAMSystemStatsIfNeeded() {
        let now = Date()
        guard now.timeIntervalSince(slowStatsLastRead) >= slowStatsCacheInterval else { return }
        slowStatsLastRead = now

        var swap = xsw_usage()
        var swapSize = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0) == 0 {
            cachedSwapBytes = swap.xsu_used
        }

        var pressureRaw: Int32 = 0
        var pressureSize = MemoryLayout<Int32>.size
        if sysctlbyname("kern.memorystatus_vm_pressure_level", &pressureRaw, &pressureSize, nil, 0) == 0 {
            switch pressureRaw {
            case 4: cachedPressureLevel = 2
            case 2: cachedPressureLevel = 1
            default: cachedPressureLevel = 0
            }
        }
    }
}
