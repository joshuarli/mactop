import Darwin
import Foundation
import IOKit

// MARK: - CPU

struct CPUDetail {
    var total: Double
    var system: Double
    var user: Double
    var idle: Double
    var usagePerCore: [Double]
    var loadAvg1: Double
    var loadAvg5: Double
    var loadAvg15: Double
    var uptime: String
    var history: [Double]
}

final class CPUReader {
    private struct Tick { var user, sys, idle, nice: Double }
    private var prev: [Tick] = []
    private var history: [Double] = []

    func read() -> CPUDetail {
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        var cpuCount: natural_t = 0

        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO,
                                  &cpuCount, &info, &infoCount) == KERN_SUCCESS,
              let info else {
            return CPUDetail(total: 0, system: 0, user: 0, idle: 1, usagePerCore: [],
                             loadAvg1: 0, loadAvg5: 0, loadAvg15: 0, uptime: uptimeString(), history: history)
        }
        defer {
            vm_deallocate(mach_task_self_,
                          vm_address_t(bitPattern: info),
                          vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride))
        }

        var ticks: [Tick] = []
        for i in 0..<Int(cpuCount) {
            let b = i * Int(CPU_STATE_MAX)
            ticks.append(Tick(
                user: Double(info[b + Int(CPU_STATE_USER)]),
                sys:  Double(info[b + Int(CPU_STATE_SYSTEM)]),
                idle: Double(info[b + Int(CPU_STATE_IDLE)]),
                nice: Double(info[b + Int(CPU_STATE_NICE)])
            ))
        }

        var totalUsage = 0.0
        var systemUsage = 0.0
        var userUsage = 0.0
        var perCore: [Double] = []

        if prev.count == ticks.count {
            for i in 0..<ticks.count {
                let du = ticks[i].user - prev[i].user
                let ds = ticks[i].sys  - prev[i].sys
                let di = ticks[i].idle - prev[i].idle
                let dn = ticks[i].nice - prev[i].nice
                let total = du + ds + di + dn
                if total > 0 {
                    let coreUsage = (du + ds + dn) / total
                    totalUsage  += coreUsage
                    systemUsage += ds / total
                    userUsage   += (du + dn) / total
                    perCore.append(min(1, max(0, coreUsage)))
                } else {
                    perCore.append(0)
                }
            }
            let n = Double(ticks.count)
            totalUsage  /= n
            systemUsage /= n
            userUsage   /= n
        }

        prev = ticks

        let total = min(1, max(0, totalUsage))
        history.append(total)
        if history.count > 180 { history.removeFirst() }

        var loadAvgRaw = [Double](repeating: 0, count: 3)
        getloadavg(&loadAvgRaw, 3)

        return CPUDetail(
            total: total,
            system: min(1, max(0, systemUsage)),
            user: min(1, max(0, userUsage)),
            idle: min(1, max(0, 1 - totalUsage)),
            usagePerCore: perCore,
            loadAvg1: loadAvgRaw[0],
            loadAvg5: loadAvgRaw[1],
            loadAvg15: loadAvgRaw[2],
            uptime: uptimeString(),
            history: history
        )
    }

    private func uptimeString() -> String {
        var bootTime = timeval()
        var size = MemoryLayout<timeval>.size
        sysctlbyname("kern.boottime", &bootTime, &size, nil, 0)
        let bootDate = Date(timeIntervalSince1970: Double(bootTime.tv_sec))
        let form = DateComponentsFormatter()
        form.maximumUnitCount = 2
        form.unitsStyle = .full
        form.allowedUnits = [.day, .hour, .minute]
        return form.string(from: bootDate, to: Date()) ?? "Unknown"
    }
}

// MARK: - RAM

struct RAMDetail {
    var total: Double
    var appBytes: UInt64
    var wiredBytes: UInt64
    var compressedBytes: UInt64
    var freeBytes: UInt64
    var swapBytes: UInt64
    var totalBytes: UInt64
    var pressureLevel: Int   // 0=normal, 1=warn, 2=critical
    var history: [Double]
}

final class RAMReader {
    private let totalBytes: UInt64 = {
        var n: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        sysctlbyname("hw.memsize", &n, &size, nil, 0)
        return n
    }()
    private var history: [Double] = []

    func read() -> RAMDetail {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size
        )
        guard withUnsafeMutablePointer(to: &stats, {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }) == KERN_SUCCESS else {
            return RAMDetail(total: 0, appBytes: 0, wiredBytes: 0, compressedBytes: 0,
                             freeBytes: 0, swapBytes: 0, totalBytes: totalBytes, pressureLevel: 0, history: history)
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
        let used = active + inactive + speculative + wired + compressed - purgeable - external
        let app  = used > wired + compressed ? used - wired - compressed : 0
        let free = totalBytes > used ? totalBytes - used : 0

        var swap: xsw_usage = xsw_usage()
        var swapSize = MemoryLayout<xsw_usage>.size
        sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0)

        var pressureRaw: Int32 = 0
        var pressureSize = MemoryLayout<Int32>.size
        sysctlbyname("kern.memorystatus_vm_pressure_level", &pressureRaw, &pressureSize, nil, 0)
        let pressureLevel: Int
        switch pressureRaw {
        case 4: pressureLevel = 2
        case 2: pressureLevel = 1
        default: pressureLevel = 0
        }

        let fraction = totalBytes > 0 ? min(1, Double(used) / Double(totalBytes)) : 0
        history.append(fraction)
        if history.count > 180 { history.removeFirst() }

        return RAMDetail(
            total: fraction,
            appBytes: app,
            wiredBytes: wired,
            compressedBytes: compressed,
            freeBytes: free,
            swapBytes: swap.xsu_used,
            totalBytes: totalBytes,
            pressureLevel: pressureLevel,
            history: history
        )
    }
}

// MARK: - GPU

struct GPUDetail {
    var total: Double
    var render: Double
    var tiler: Double
    var model: String
    var history: [Double]
}

final class GPUReader {
    private var history: [Double] = []

    // Read once — brand string never changes at runtime
    private static let modelName: String = {
        var buf = [CChar](repeating: 0, count: 256)
        var size = buf.count
        sysctlbyname("machdep.cpu.brand_string", &buf, &size, nil, 0)
        let brand = String(cString: buf)
        return brand.isEmpty ? "GPU" : brand + " GPU"
    }()

    func read() -> GPUDetail {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault,
            IOServiceMatching("IOAccelerator"),
            &iterator
        ) == KERN_SUCCESS else { return GPUDetail(total: 0, render: 0, tiler: 0, model: Self.modelName, history: history) }
        defer { IOObjectRelease(iterator) }

        while true {
            let service = IOIteratorNext(iterator)
            guard service != 0 else { break }
            defer { IOObjectRelease(service) }

            var props: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                  let dict = props?.takeRetainedValue() as? [String: Any],
                  let perf = dict["PerformanceStatistics"] as? [String: Any] else { continue }

            // Intel uses "Device Utilization %", Apple Silicon uses "GPU Activity(%)"
            let pct = perf["Device Utilization %"] as? Double
                   ?? perf["GPU Activity(%)"] as? Double
                   ?? 0
            let render = (perf["Renderer Utilization %"] as? Double ?? 0) / 100.0
            let tiler  = (perf["Tiler Utilization %"]   as? Double ?? 0) / 100.0
            let total  = pct / 100.0

            history.append(total)
            if history.count > 180 { history.removeFirst() }

            return GPUDetail(total: total, render: render, tiler: tiler, model: Self.modelName, history: history)
        }
        return GPUDetail(total: 0, render: 0, tiler: 0, model: Self.modelName, history: history)
    }
}

// MARK: - Network

struct NetDetail {
    var upload: Double
    var download: Double
    var totalUp: UInt64
    var totalDown: UInt64
    var interfaceName: String
    var localIP: String
    var isUp: Bool
    var history: [(up: Double, down: Double)]
}

final class NetReader {
    private var prevUp: UInt64 = 0
    private var prevDown: UInt64 = 0
    private var cumulativeUp: UInt64 = 0
    private var cumulativeDown: UInt64 = 0
    private var lastTime = Date()
    private var history: [(up: Double, down: Double)] = []

    func read() -> NetDetail {
        var ifap: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifap) == 0, let head = ifap else {
            return NetDetail(upload: 0, download: 0, totalUp: cumulativeUp, totalDown: cumulativeDown,
                             interfaceName: "", localIP: "", isUp: false, history: history)
        }
        defer { freeifaddrs(head) }

        var totalUp: UInt64 = 0
        var totalDown: UInt64 = 0
        var primaryIface = ""
        var localIP = ""
        var isUp = false

        var cursor: UnsafeMutablePointer<ifaddrs>? = head
        while let iface = cursor {
            defer { cursor = iface.pointee.ifa_next }
            let name = String(cString: iface.pointee.ifa_name)
            guard name.hasPrefix("en") else { continue }

            if iface.pointee.ifa_addr?.pointee.sa_family == UInt8(AF_LINK),
               let raw = iface.pointee.ifa_data {
                let data = raw.assumingMemoryBound(to: if_data.self).pointee
                totalUp   += UInt64(data.ifi_obytes)
                totalDown += UInt64(data.ifi_ibytes)
                if primaryIface.isEmpty { primaryIface = name }
                isUp = (iface.pointee.ifa_flags & UInt32(IFF_UP)) != 0
            }

            if iface.pointee.ifa_addr?.pointee.sa_family == UInt8(AF_INET),
               localIP.isEmpty {
                var addr = iface.pointee.ifa_addr!.pointee
                var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                withUnsafeMutablePointer(to: &addr) {
                    $0.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                        var inAddr = $0.pointee.sin_addr
                        inet_ntop(AF_INET, &inAddr, &buf, socklen_t(INET_ADDRSTRLEN))
                    }
                }
                localIP = String(cString: buf)
            }
        }

        let now = Date()
        let elapsed = now.timeIntervalSince(lastTime)
        var upRate = 0.0
        var downRate = 0.0

        if elapsed > 0 && (prevUp > 0 || prevDown > 0) {
            let dUp   = totalUp   >= prevUp   ? Double(totalUp   - prevUp)   : 0
            let dDown = totalDown >= prevDown ? Double(totalDown - prevDown) : 0
            upRate   = dUp   / elapsed
            downRate = dDown / elapsed
            cumulativeUp   += totalUp   >= prevUp   ? (totalUp   - prevUp)   : 0
            cumulativeDown += totalDown >= prevDown ? (totalDown - prevDown) : 0
        }

        prevUp = totalUp
        prevDown = totalDown
        lastTime = now

        history.append((up: upRate, down: downRate))
        if history.count > 180 { history.removeFirst() }

        return NetDetail(
            upload: upRate,
            download: downRate,
            totalUp: cumulativeUp,
            totalDown: cumulativeDown,
            interfaceName: primaryIface,
            localIP: localIP,
            isUp: isUp,
            history: history
        )
    }
}
