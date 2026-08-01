import Darwin
import Foundation

// Reads aggregate CPU utilization, per-core utilization, load averages, and uptime
// from Mach and sysctl sources, retaining only the recent chart history window.
public enum CPUCoreKind {
    case efficiency
    case performance
    case unknown
}

public struct CPUUsageDetail {
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

public final class CPUUsageReader {
    private struct Tick { var user, sys, idle, nice: Double }
    private var prev: [Tick] = []
    private var ticks: [Tick] = []
    private var perCore: [Double] = []
    private var history: ScalarHistory
    private let coreKinds = CPUUsageReader.readCoreKinds()
    private let uptimeFormatter: DateComponentsFormatter = {
        let form = DateComponentsFormatter()
        form.maximumUnitCount = 2
        form.unitsStyle = .full
        form.allowedUnits = [.day, .hour, .minute]
        return form
    }()
    private var cachedUptimeMinute = -1
    private var cachedUptime = "Unknown"
    private var cachedLoadAvg = [Double](repeating: 0, count: 3)
    private var loadAvgLastRead = Date.distantPast
    private let loadAvgCacheInterval: TimeInterval = 5

    public init(updateInterval: Double = 1) {
        history = ScalarHistory(capacity: metricGraphSampleCapacity(updateInterval: updateInterval))
    }

    public func clearCPUUsageHistory() {
        prev.removeAll(keepingCapacity: true)
        ticks.removeAll(keepingCapacity: true)
        perCore.removeAll(keepingCapacity: true)
        history.removeAll()
    }

    public func readCPUUsageDetail(includeHistory: Bool = false) -> CPUUsageDetail {
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        var cpuCount: natural_t = 0

        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO,
                                  &cpuCount, &info, &infoCount) == KERN_SUCCESS,
              let info else {
            return CPUUsageDetail(total: 0, system: 0, user: 0, idle: 1, usagePerCore: [],
                             coreKinds: coreKinds,
                             loadAvg1: 0, loadAvg5: 0, loadAvg15: 0, uptime: uptimeString(),
                             history: includeHistory ? history.orderedValues : [], historyCapacity: history.capacity)
        }
        defer {
            vm_deallocate(mach_task_self_,
                          vm_address_t(bitPattern: info),
                          vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride))
        }

        ticks.removeAll(keepingCapacity: true)
        if ticks.capacity < Int(cpuCount) {
            ticks.reserveCapacity(Int(cpuCount))
        }
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
        if includeHistory {
            perCore.removeAll(keepingCapacity: true)
            if perCore.capacity < ticks.count {
                perCore.reserveCapacity(ticks.count)
            }
        }

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
                    if includeHistory {
                        perCore.append(min(1, max(0, coreUsage)))
                    }
                } else if includeHistory {
                    perCore.append(0)
                }
            }
            let n = Double(ticks.count)
            totalUsage  /= n
            systemUsage /= n
            userUsage   /= n
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

    private func uptimeString() -> String {
        let elapsed = Int(Date().timeIntervalSince(Self.bootDate))
        let minute = elapsed / 60
        guard minute != cachedUptimeMinute else { return cachedUptime }
        cachedUptimeMinute = minute
        cachedUptime = uptimeFormatter.string(from: TimeInterval(elapsed)) ?? "Unknown"
        return cachedUptime
    }

    private func loadAverage() -> [Double] {
        let now = Date()
        guard now.timeIntervalSince(loadAvgLastRead) >= loadAvgCacheInterval else {
            return cachedLoadAvg
        }
        loadAvgLastRead = now
        getloadavg(&cachedLoadAvg, 3)
        return cachedLoadAvg
    }

    private static let bootDate: Date = {
        var bootTime = timeval()
        var size = MemoryLayout<timeval>.size
        sysctlbyname("kern.boottime", &bootTime, &size, nil, 0)
        return Date(timeIntervalSince1970: Double(bootTime.tv_sec))
    }()

    private static func readCoreKinds() -> [CPUCoreKind] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleARMPE"), &iterator) == KERN_SUCCESS else {
            return []
        }
        defer { IOObjectRelease(iterator) }

        var cores: [(id: Int32, kind: CPUCoreKind)] = []
        while true {
            let service = IOIteratorNext(iterator)
            guard service != 0 else { break }
            defer { IOObjectRelease(service) }

            var childIterator: io_iterator_t = 0
            guard IORegistryEntryGetChildIterator(service, kIOServicePlane, &childIterator) == KERN_SUCCESS else { continue }
            defer { IOObjectRelease(childIterator) }

            while true {
                let child = IOIteratorNext(childIterator)
                guard child != 0 else { break }
                defer { IOObjectRelease(child) }

                var nameBuffer = [CChar](repeating: 0, count: 128)
                guard IORegistryEntryGetName(child, &nameBuffer) == KERN_SUCCESS else { continue }
                let name = String(cString: nameBuffer)
                guard name.range(of: #"^cpu\d+"#, options: .regularExpression) != nil else { continue }

                var unmanagedProperties: Unmanaged<CFMutableDictionary>?
                guard IORegistryEntryCreateCFProperties(child, &unmanagedProperties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                      let properties = unmanagedProperties?.takeRetainedValue() as? [String: Any] else { continue }

                let id = Self.cpuID(from: properties["logical-cpu-id"])
                    ?? Self.cpuID(from: properties["cpu-id"])
                    ?? Int32(cores.count)
                let rawType = (properties["cluster-type"] as? Data).flatMap { String(data: $0, encoding: .utf8) }?
                    .trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters))
                let kind: CPUCoreKind
                switch rawType {
                case "E": kind = .efficiency
                case "P", "M": kind = .performance
                default: kind = .unknown
                }
                cores.append((id: id, kind: kind))
            }
        }

        let maxID = cores.map(\.id).max() ?? -1
        guard maxID >= 0 else { return fallbackCoreKinds() }

        var kinds = Array(repeating: CPUCoreKind.unknown, count: Int(maxID) + 1)
        for core in cores where core.id >= 0 {
            kinds[Int(core.id)] = core.kind
        }
        if kinds.allSatisfy({ $0 == .unknown }) {
            return fallbackCoreKinds()
        }
        return kinds
    }

    private static func cpuID(from value: Any?) -> Int32? {
        if let value = value as? Int32 { return value }
        if let value = value as? Int { return Int32(value) }
        guard let data = value as? Data, !data.isEmpty else { return nil }
        var result: Int32 = 0
        for (shift, byte) in data.prefix(4).enumerated() {
            result |= Int32(byte) << Int32(shift * 8)
        }
        return result
    }

    private static func fallbackCoreKinds() -> [CPUCoreKind] {
        let performanceCount = perfLevelCPUCount(named: "Performance")
        let efficiencyCount = perfLevelCPUCount(named: "Efficiency")
        guard efficiencyCount > 0 || performanceCount > 0 else { return [] }
        return Array(repeating: .efficiency, count: efficiencyCount)
            + Array(repeating: .performance, count: performanceCount)
    }

    private static func perfLevelCPUCount(named name: String) -> Int {
        for level in 0..<4 {
            var nameBuffer = [CChar](repeating: 0, count: 64)
            var nameSize = nameBuffer.count
            guard sysctlbyname("hw.perflevel\(level).name", &nameBuffer, &nameSize, nil, 0) == 0,
                  String(cString: nameBuffer) == name else { continue }

            var count: Int32 = 0
            var countSize = MemoryLayout<Int32>.size
            guard sysctlbyname("hw.perflevel\(level).physicalcpu", &count, &countSize, nil, 0) == 0 else { return 0 }
            return max(0, Int(count))
        }
        return 0
    }
}

// MARK: - RAM
