import Darwin
import Foundation
import IOKit
import SystemConfiguration

private struct ScalarHistory {
    private var values: [Float]
    private var nextIndex = 0
    private var isFull = false

    init(capacity: Int) {
        values = Array(repeating: 0, count: max(capacity, 1))
    }

    mutating func append(_ value: Double) {
        values[nextIndex] = Float(value)
        nextIndex = (nextIndex + 1) % values.count
        if nextIndex == 0 { isFull = true }
    }

    var orderedValues: [Double] {
        let ordered: [Float]
        if isFull {
            ordered = Array(values[nextIndex..<values.count] + values[0..<nextIndex])
        } else {
            ordered = Array(values[0..<nextIndex])
        }
        return ordered.map(Double.init)
    }
}

private struct PairHistory {
    private var upValues: [Float]
    private var downValues: [Float]
    private var nextIndex = 0
    private var isFull = false

    init(capacity: Int) {
        upValues = Array(repeating: 0, count: max(capacity, 1))
        downValues = Array(repeating: 0, count: max(capacity, 1))
    }

    mutating func append(up: Double, down: Double) {
        upValues[nextIndex] = Float(up)
        downValues[nextIndex] = Float(down)
        nextIndex = (nextIndex + 1) % upValues.count
        if nextIndex == 0 { isFull = true }
    }

    var orderedValues: [(up: Double, down: Double)] {
        let upOrdered: [Float]
        let downOrdered: [Float]
        if isFull {
            upOrdered = Array(upValues[nextIndex..<upValues.count] + upValues[0..<nextIndex])
            downOrdered = Array(downValues[nextIndex..<downValues.count] + downValues[0..<nextIndex])
        } else {
            upOrdered = Array(upValues[0..<nextIndex])
            downOrdered = Array(downValues[0..<nextIndex])
        }
        return zip(upOrdered, downOrdered).map { (up: Double($0), down: Double($1)) }
    }
}

// MARK: - CPU

enum CPUCoreKind {
    case efficiency
    case performance
    case unknown
}

struct CPUDetail {
    var total: Double
    var system: Double
    var user: Double
    var idle: Double
    var usagePerCore: [Double]
    var coreKinds: [CPUCoreKind]
    var loadAvg1: Double
    var loadAvg5: Double
    var loadAvg15: Double
    var uptime: String
    var history: [Double]
}

final class CPUReader {
    private struct Tick { var user, sys, idle, nice: Double }
    private var prev: [Tick] = []
    private var history = ScalarHistory(capacity: 180)
    private let coreKinds = CPUReader.readCoreKinds()
    private let uptimeFormatter: DateComponentsFormatter = {
        let form = DateComponentsFormatter()
        form.maximumUnitCount = 2
        form.unitsStyle = .full
        form.allowedUnits = [.day, .hour, .minute]
        return form
    }()
    private var cachedUptimeMinute = -1
    private var cachedUptime = "Unknown"

    func read() -> CPUDetail {
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        var cpuCount: natural_t = 0

        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO,
                                  &cpuCount, &info, &infoCount) == KERN_SUCCESS,
              let info else {
            return CPUDetail(total: 0, system: 0, user: 0, idle: 1, usagePerCore: [],
                             coreKinds: coreKinds,
                             loadAvg1: 0, loadAvg5: 0, loadAvg15: 0, uptime: uptimeString(), history: history.orderedValues)
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

        var loadAvgRaw = [Double](repeating: 0, count: 3)
        getloadavg(&loadAvgRaw, 3)

        return CPUDetail(
            total: total,
            system: min(1, max(0, systemUsage)),
            user: min(1, max(0, userUsage)),
            idle: min(1, max(0, 1 - totalUsage)),
            usagePerCore: perCore,
            coreKinds: coreKinds,
            loadAvg1: loadAvgRaw[0],
            loadAvg5: loadAvgRaw[1],
            loadAvg15: loadAvgRaw[2],
            uptime: uptimeString(),
            history: history.orderedValues
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

                let id = (properties["cpu-id"] as? Data)?.withUnsafeBytes { $0.load(as: Int32.self) } ?? Int32(cores.count)
                let rawType = (properties["cluster-type"] as? Data).flatMap { String(data: $0, encoding: .utf8) }?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
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
        guard maxID >= 0 else { return [] }

        var kinds = Array(repeating: CPUCoreKind.unknown, count: Int(maxID) + 1)
        for core in cores where core.id >= 0 {
            kinds[Int(core.id)] = core.kind
        }
        return kinds
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
    private var history = ScalarHistory(capacity: 180)

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
                             freeBytes: 0, swapBytes: 0, totalBytes: totalBytes, pressureLevel: 0, history: history.orderedValues)
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

        return RAMDetail(
            total: fraction,
            appBytes: app,
            wiredBytes: wired,
            compressedBytes: compressed,
            freeBytes: free,
            swapBytes: swap.xsu_used,
            totalBytes: totalBytes,
            pressureLevel: pressureLevel,
            history: history.orderedValues
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
    var renderHistory: [Double]
    var tilerHistory: [Double]
}

final class GPUReader {
    private var history = ScalarHistory(capacity: 120)
    private var renderHistory = ScalarHistory(capacity: 120)
    private var tilerHistory = ScalarHistory(capacity: 120)
    // EMA smoothing matches Stats' visually calm GPU graph
    private var emaTotal:  Double = 0
    private var emaRender: Double = 0
    private var emaTiler:  Double = 0
    private let alpha = 0.3

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
        ) == KERN_SUCCESS else { return detail() }
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
            let rawTotal  = pct / 100.0
            let rawRender = (perf["Renderer Utilization %"] as? Double ?? 0) / 100.0
            let rawTiler  = (perf["Tiler Utilization %"]   as? Double ?? 0) / 100.0

            emaTotal  = alpha * rawTotal  + (1 - alpha) * emaTotal
            emaRender = alpha * rawRender + (1 - alpha) * emaRender
            emaTiler  = alpha * rawTiler  + (1 - alpha) * emaTiler

            history.append(emaTotal)
            renderHistory.append(emaRender)
            tilerHistory.append(emaTiler)

            return detail()
        }
        return detail()
    }

    private func detail() -> GPUDetail {
        GPUDetail(
            total: emaTotal,
            render: emaRender,
            tiler: emaTiler,
            model: Self.modelName,
            history: history.orderedValues,
            renderHistory: renderHistory.orderedValues,
            tilerHistory: tilerHistory.orderedValues
        )
    }
}

// MARK: - Power

struct PowerDetail {
    var total: Double?
    var system: Double?
    var modeled: Double?
    var charging: ChargingDetail?
    var cpu: Double?
    var gpu: Double?
    var ane: Double?
    var memory: Double?
    var media: Double?
    var display: Double?
    var other: Double?
    var history: [PowerHistorySample]
}

struct PowerHistorySample: Equatable {
    var total: Double
    var modeled: Double
    var cpu: Double
    var gpu: Double
    var ane: Double
    var memory: Double
    var media: Double
    var display: Double
    var other: Double
}

struct ChargingDetail {
    var externalConnected: Bool
    var isCharging: Bool
    var isFullyCharged: Bool
    var adapterName: String?
    var adapterWatts: Double?
    var inputWatts: Double?
    var batteryWatts: Double?
    var batteryFraction: Double?
    var wallWatts: Double?
    var chargerWatts: Double? {
        guard let inputWatts else { return nil }
        return inputWatts + max(batteryWatts ?? 0, 0)
    }
    var status: String {
        if !externalConnected { return "Battery" }
        if isCharging { return "Charging" }
        if isFullyCharged { return "Full" }
        return "Connected"
    }
}

final class PowerReader {
    private struct PowerSample {
        var cpu: Double
        var gpu: Double
        var ane: Double
        var memory: Double
        var media: Double
        var display: Double
        var other: Double
        var system: Double?
        var hasModeled: Bool
        var modeled: Double { cpu + gpu + ane + memory + media + display + other }
        var total: Double { system ?? modeled }
        var historySample: PowerHistorySample? {
            guard hasModeled else { return nil }
            return PowerHistorySample(
                total: total,
                modeled: modeled,
                cpu: cpu,
                gpu: gpu,
                ane: ane,
                memory: memory,
                media: media,
                display: display,
                other: other
            )
        }
    }

    private struct PowerHistory {
        private var entries: [(date: Date, sample: PowerHistorySample)] = []
        private let window: TimeInterval = 10 * 60

        mutating func append(_ sample: PowerSample, at date: Date) {
            guard let historySample = sample.historySample else { return }
            entries.append((date, historySample))
            prune(at: date)
        }

        private mutating func prune(at date: Date) {
            let cutoff = date.addingTimeInterval(-window)
            entries.removeAll { $0.date < cutoff }
        }

        var values: [PowerHistorySample] { entries.map(\.sample) }
    }

    private final class ModeledPowerReader {
        private struct IOReportAPI {
            typealias CopyChannelsInGroup = @convention(c) (UnsafeRawPointer?, UnsafeRawPointer?, UInt64, UInt64, UInt64) -> UnsafeRawPointer?
            typealias CreateSubscription = @convention(c) (UnsafeRawPointer?, UnsafeRawPointer?, UnsafeMutablePointer<UnsafeRawPointer?>?, UInt64, UnsafeRawPointer?) -> UnsafeRawPointer?
            typealias CreateSamples = @convention(c) (UnsafeRawPointer?, UnsafeRawPointer?, UnsafeRawPointer?) -> UnsafeRawPointer?
            typealias CreateSamplesDelta = @convention(c) (UnsafeRawPointer?, UnsafeRawPointer?, UnsafeRawPointer?) -> UnsafeRawPointer?
            typealias MergeChannels = @convention(c) (UnsafeRawPointer?, UnsafeRawPointer?, UnsafeRawPointer?) -> Void
            typealias ChannelString = @convention(c) (UnsafeRawPointer?) -> UnsafeRawPointer?
            typealias SimpleIntegerValue = @convention(c) (UnsafeRawPointer?, Int32) -> Int64

            var handle: UnsafeMutableRawPointer
            var copyChannelsInGroup: CopyChannelsInGroup
            var createSubscription: CreateSubscription
            var createSamples: CreateSamples
            var createSamplesDelta: CreateSamplesDelta
            var mergeChannels: MergeChannels
            var channelGetGroup: ChannelString
            var channelGetSubGroup: ChannelString
            var channelGetChannelName: ChannelString
            var channelGetUnitLabel: ChannelString
            var simpleGetIntegerValue: SimpleIntegerValue
        }

        private let api: IOReportAPI
        private let channels: CFMutableDictionary
        private let subscription: UnsafeRawPointer
        private let debugEnabled = ProcessInfo.processInfo.environment["MACTOP_DEBUG_POWER"] == "1"
        private var didLogDebug = false
        private var previousSample: (sample: CFDictionary, time: Date)?

        init?() {
            guard let api = Self.loadAPI(),
                  let channels = Self.copyPowerChannels(api: api) else { return nil }

            var returnedChannels: UnsafeRawPointer?
            let channelsPtr = Unmanaged.passUnretained(channels).toOpaque()
            guard let subscription = api.createSubscription(nil, channelsPtr, &returnedChannels, 0, nil) else { return nil }

            self.api = api
            self.channels = channels
            self.subscription = subscription
        }

        deinit {
            Unmanaged<AnyObject>.fromOpaque(subscription).release()
            dlclose(api.handle)
        }

        func readPower() -> PowerSample? {
            guard let next = rawSample() else { return nil }
            guard let previous = previousSample else {
                previousSample = next
                return nil
            }

            let elapsed = next.time.timeIntervalSince(previous.time)
            previousSample = next
            guard elapsed > 0 else { return nil }

            let previousPtr = Unmanaged.passUnretained(previous.sample).toOpaque()
            let nextPtr = Unmanaged.passUnretained(next.sample).toOpaque()
            guard let deltaPtr = api.createSamplesDelta(previousPtr, nextPtr, nil) else { return nil }
            let delta = Unmanaged<CFDictionary>.fromOpaque(deltaPtr).takeRetainedValue()

            return parsePower(delta: delta, elapsed: elapsed)
        }

        private func rawSample() -> (sample: CFDictionary, time: Date)? {
            let subscriptionPtr = UnsafeRawPointer(subscription)
            let channelsPtr = Unmanaged.passUnretained(channels).toOpaque()
            guard let samplePtr = api.createSamples(subscriptionPtr, channelsPtr, nil) else { return nil }
            let sample = Unmanaged<CFDictionary>.fromOpaque(samplePtr).takeRetainedValue()
            return (sample, Date())
        }

        private func parsePower(delta: CFDictionary, elapsed: TimeInterval) -> PowerSample? {
            let key = "IOReportChannels" as CFString
            guard let arrayPtr = CFDictionaryGetValue(delta, Unmanaged.passUnretained(key).toOpaque()) else { return nil }
            let array = Unmanaged<CFArray>.fromOpaque(arrayPtr).takeUnretainedValue()
            let count = CFArrayGetCount(array)

            var cpu = 0.0
            var gpu = 0.0
            var ane = 0.0
            var memory = 0.0
            var media = 0.0
            var energyDisplay = 0.0
            var dcpDisplay = 0.0
            var other = 0.0
            var found = false
            var debugRows: [String] = []

            for i in 0..<count {
                guard let item = CFArrayGetValueAtIndex(array, i) else { continue }

                let group = cfString(api.channelGetGroup(item))
                let subgroup = cfString(api.channelGetSubGroup(item))
                let channel = cfString(api.channelGetChannelName(item))
                let unit = cfString(api.channelGetUnitLabel(item)).trimmingCharacters(in: .whitespacesAndNewlines)

                if group == "Energy Model" {
                    guard let watts = watts(item: item, unit: unit, elapsed: elapsed) else { continue }
                    switch channel {
                    case "GPU Energy":
                        gpu += watts
                        found = true
                    case let name where name.hasSuffix("CPU Energy"):
                        cpu += watts
                        found = true
                    case let name where name.hasPrefix("ANE"):
                        ane += watts
                        found = true
                    case let name where name.hasPrefix("DRAM") || name.hasPrefix("AMCC") || name.hasPrefix("GPU SRAM"):
                        memory += watts
                        found = true
                    case let name where name.hasPrefix("DCS"):
                        energyDisplay += watts
                        found = true
                    case let name where name.hasPrefix("AVE") || name.hasPrefix("ISP") || name.hasPrefix("MSR"):
                        media += watts
                        found = true
                    case let name where name.contains("PCIe") || name.hasPrefix("apciec"):
                        other += watts
                        found = true
                    default:
                        continue
                    }
                    if debugEnabled {
                        debugRows.append(String(format: "Energy Model/%@: %.3f W", channel, watts))
                    }
                } else if group.hasPrefix("DCP"), subgroup == "display stats", channel == "power" {
                    let watts = microwattSecondsToWatts(api.simpleGetIntegerValue(item, 0), elapsed: elapsed)
                    dcpDisplay += watts
                    found = true
                    if debugEnabled {
                        debugRows.append(String(format: "%@/%@/%@: %.3f W", group, subgroup, channel, watts))
                    }
                }
            }

            guard found else { return nil }
            if debugEnabled, !didLogDebug {
                didLogDebug = true
                fputs((["mactop power channels:"] + debugRows.sorted()).joined(separator: "\n") + "\n", stderr)
            }

            let display = dcpDisplay > 0 ? dcpDisplay : energyDisplay
            return PowerSample(cpu: cpu, gpu: gpu, ane: ane, memory: memory, media: media, display: display, other: other, system: nil, hasModeled: true)
        }

        private func watts(item: UnsafeRawPointer, unit: String, elapsed: TimeInterval) -> Double? {
            let value = Double(api.simpleGetIntegerValue(item, 0))
            let joules: Double
            switch unit {
            case "mJ": joules = value / 1_000
            case "uJ": joules = value / 1_000_000
            case "nJ": joules = value / 1_000_000_000
            default: return nil
            }
            return max(0, joules / elapsed)
        }

        private func microwattSecondsToWatts(_ value: Int64, elapsed: TimeInterval) -> Double {
            Double(value) / 1_000_000 / elapsed
        }

        private func cfString(_ pointer: UnsafeRawPointer?) -> String {
            guard let pointer else { return "" }
            return Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String
        }

        private static func loadAPI() -> IOReportAPI? {
            let paths = [
                "/usr/lib/libIOReport.dylib",
                "libIOReport.dylib",
                "/System/Library/PrivateFrameworks/IOReport.framework/IOReport",
                "IOReport",
            ]

            guard let handle = paths.lazy.compactMap({ dlopen($0, RTLD_LAZY) }).first else { return nil }

            guard let copyChannelsInGroup = symbol(handle, "IOReportCopyChannelsInGroup", as: IOReportAPI.CopyChannelsInGroup.self),
                  let createSubscription = symbol(handle, "IOReportCreateSubscription", as: IOReportAPI.CreateSubscription.self),
                  let createSamples = symbol(handle, "IOReportCreateSamples", as: IOReportAPI.CreateSamples.self),
                  let createSamplesDelta = symbol(handle, "IOReportCreateSamplesDelta", as: IOReportAPI.CreateSamplesDelta.self),
                  let mergeChannels = symbol(handle, "IOReportMergeChannels", as: IOReportAPI.MergeChannels.self),
                  let channelGetGroup = symbol(handle, "IOReportChannelGetGroup", as: IOReportAPI.ChannelString.self),
                  let channelGetSubGroup = symbol(handle, "IOReportChannelGetSubGroup", as: IOReportAPI.ChannelString.self),
                  let channelGetChannelName = symbol(handle, "IOReportChannelGetChannelName", as: IOReportAPI.ChannelString.self),
                  let channelGetUnitLabel = symbol(handle, "IOReportChannelGetUnitLabel", as: IOReportAPI.ChannelString.self),
                  let simpleGetIntegerValue = symbol(handle, "IOReportSimpleGetIntegerValue", as: IOReportAPI.SimpleIntegerValue.self) else {
                dlclose(handle)
                return nil
            }

            return IOReportAPI(
                handle: handle,
                copyChannelsInGroup: copyChannelsInGroup,
                createSubscription: createSubscription,
                createSamples: createSamples,
                createSamplesDelta: createSamplesDelta,
                mergeChannels: mergeChannels,
                channelGetGroup: channelGetGroup,
                channelGetSubGroup: channelGetSubGroup,
                channelGetChannelName: channelGetChannelName,
                channelGetUnitLabel: channelGetUnitLabel,
                simpleGetIntegerValue: simpleGetIntegerValue
            )
        }

        private static func symbol<T>(_ handle: UnsafeMutableRawPointer, _ name: String, as type: T.Type) -> T? {
            guard let pointer = dlsym(handle, name) else { return nil }
            return unsafeBitCast(pointer, to: type)
        }

        private static func copyPowerChannels(api: IOReportAPI) -> CFMutableDictionary? {
            let groups = [
                (group: "Energy Model", subgroup: nil as String?),
                (group: "DCP", subgroup: nil as String?),
                (group: "DCPEXT0", subgroup: nil as String?),
                (group: "DCPEXT1", subgroup: nil as String?),
            ]
            var dictionaries: [CFDictionary] = []
            for entry in groups {
                let group = entry.group as CFString
                let groupPtr = Unmanaged.passUnretained(group).toOpaque()
                let subgroup = entry.subgroup.map { $0 as CFString }
                let subgroupPtr = subgroup.map { Unmanaged.passUnretained($0).toOpaque() }
                guard let rawPtr = api.copyChannelsInGroup(groupPtr, subgroupPtr, 0, 0, 0) else { continue }
                dictionaries.append(Unmanaged<CFDictionary>.fromOpaque(rawPtr).takeRetainedValue())
            }

            guard let first = dictionaries.first,
                  let channels = CFDictionaryCreateMutableCopy(kCFAllocatorDefault, CFDictionaryGetCount(first), first) else { return nil }

            let channelsPtr = Unmanaged.passUnretained(channels).toOpaque()
            for dictionary in dictionaries.dropFirst() {
                api.mergeChannels(channelsPtr, Unmanaged.passUnretained(dictionary).toOpaque(), nil)
            }

            let key = "IOReportChannels" as CFString
            guard CFDictionaryGetValue(channels, Unmanaged.passUnretained(key).toOpaque()) != nil else { return nil }
            return channels
        }
    }

    private final class BatteryPowerReader {
        func read() -> ChargingDetail? {
            let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
            guard service != 0 else { return nil }
            defer { IOObjectRelease(service) }

            var unmanagedProperties: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(service, &unmanagedProperties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                  let properties = unmanagedProperties?.takeRetainedValue() as? [String: Any] else { return nil }

            let telemetry = properties["PowerTelemetryData"] as? [String: Any]
            let systemWatts = systemWatts(properties: properties, telemetry: telemetry)
            let batteryWatts = numeric(telemetry?["BatteryPower"]).flatMap { batteryPowerWatts($0) }
            let batteryFraction = batteryFraction(properties)
            let adapter = adapterDetails(properties)

            return ChargingDetail(
                externalConnected: bool(properties["ExternalConnected"]) ?? bool(properties["AppleRawExternalConnected"]) ?? false,
                isCharging: bool(properties["IsCharging"]) ?? false,
                isFullyCharged: bool(properties["FullyCharged"]) ?? false,
                adapterName: adapter.name,
                adapterWatts: adapter.watts,
                inputWatts: systemWatts,
                batteryWatts: batteryWatts,
                batteryFraction: batteryFraction,
                wallWatts: numeric(telemetry?["WallEnergyEstimate"]).map { $0 / 1_000 }
            )
        }

        private func systemWatts(properties: [String: Any], telemetry: [String: Any]?) -> Double? {
            if let telemetry {
                if let power = numeric(telemetry["SystemPowerIn"]), power > 0 {
                    return wattsFromMilliwatts(power)
                }
                if let current = numeric(telemetry["SystemCurrentIn"]),
                   let voltage = numeric(telemetry["SystemVoltageIn"]),
                   current > 0, voltage > 0 {
                    return wattsFromMillivoltsAndMilliamps(voltage: voltage, amperage: current)
                }
                if let power = numeric(telemetry["SystemLoad"]), power > 0 {
                    return wattsFromMilliwatts(power)
                }
                if let power = numeric(telemetry["BatteryPower"]), power != 0 {
                    return abs(wattsFromMilliwatts(power))
                }
            }

            let voltage = numeric(properties["Voltage"]) ?? numeric(properties["AppleRawBatteryVoltage"]) ?? 0
            let amperage = numeric(properties["InstantAmperage"]) ?? numeric(properties["Amperage"]) ?? 0
            guard voltage > 0, amperage != 0 else { return nil }
            return wattsFromMillivoltsAndMilliamps(voltage: voltage, amperage: amperage)
        }

        private func adapterDetails(_ properties: [String: Any]) -> (name: String?, watts: Double?) {
            let details = properties["AdapterDetails"] as? [String: Any]
                ?? (properties["AppleRawAdapterDetails"] as? [[String: Any]])?.first
            return (details?["Name"] as? String, numeric(details?["Watts"]))
        }

        private func batteryPowerWatts(_ milliwatts: Double) -> Double? {
            guard milliwatts != 0 else { return nil }
            guard abs(milliwatts) < 1_000_000 else { return nil }
            return wattsFromMilliwatts(milliwatts)
        }

        private func wattsFromMilliwatts(_ milliwatts: Double) -> Double {
            milliwatts / 1_000
        }

        private func wattsFromMillivoltsAndMilliamps(voltage: Double, amperage: Double) -> Double {
            abs(voltage * amperage) / 1_000_000
        }

        private func batteryFraction(_ properties: [String: Any]) -> Double? {
            let current = numeric(properties["CurrentCapacity"]) ?? numeric(properties["AppleRawCurrentCapacity"])
            let capacity = numeric(properties["MaxCapacity"]) ?? numeric(properties["AppleRawMaxCapacity"])
            guard let current, let capacity, capacity > 0 else { return nil }
            return min(1, max(0, current / capacity))
        }

        private func bool(_ value: Any?) -> Bool? {
            switch value {
            case let value as Bool:
                return value
            case let number as NSNumber:
                return number.boolValue
            default:
                return nil
            }
        }

        private func numeric(_ value: Any?) -> Double? {
            switch value {
            case let number as NSNumber:
                return number.doubleValue
            case let value as Int:
                return Double(value)
            case let value as Int64:
                return Double(value)
            case let value as UInt64:
                return Double(value)
            case let value as Double:
                return value
            default:
                return nil
            }
        }
    }

    private var modeledPowerReaderAttempted = false
    private var modeledPowerReader: ModeledPowerReader?
    private let batteryPowerReader = BatteryPowerReader()
    private var history = PowerHistory()
    private var systemOverhead: Double?
    private var lastRawSystem: Double?
    private var cachedCharging: ChargingDetail?
    private var rawSystemLastRead = Date.distantPast
    private var current: PowerSample?
    private let chargingCacheInterval: TimeInterval = 2

    func invalidateChargingCache() {
        cachedCharging = nil
        rawSystemLastRead = .distantPast
        lastRawSystem = nil
        systemOverhead = nil
    }

    func read() -> PowerDetail {
        if !modeledPowerReaderAttempted {
            modeledPowerReader = ModeledPowerReader()
            modeledPowerReaderAttempted = true
        }

        let charging = readChargingDetail()
        let rawSystem = charging?.inputWatts
        if let sample = modeledPowerReader?.readPower() {
            if let rawSystem, (lastRawSystem != rawSystem || systemOverhead == nil) {
                systemOverhead = max(0, rawSystem - sample.modeled)
                lastRawSystem = rawSystem
            }
            let system = systemOverhead.map { sample.modeled + $0 } ?? rawSystem
            current = PowerSample(
                cpu: sample.cpu,
                gpu: sample.gpu,
                ane: sample.ane,
                memory: sample.memory,
                media: sample.media,
                display: sample.display,
                other: sample.other,
                system: system,
                hasModeled: true
            )
        } else if let current, current.system != rawSystem {
            self.current = PowerSample(
                cpu: current.cpu,
                gpu: current.gpu,
                ane: current.ane,
                memory: current.memory,
                media: current.media,
                display: current.display,
                other: current.other,
                system: rawSystem,
                hasModeled: current.hasModeled
            )
        } else if current == nil, rawSystem != nil {
            current = PowerSample(cpu: 0, gpu: 0, ane: 0, memory: 0, media: 0, display: 0, other: 0, system: rawSystem, hasModeled: false)
        }

        if let sample = current {
            history.append(sample, at: Date())
        }

        let hasModeled = current?.hasModeled == true
        return PowerDetail(
            total: current?.total,
            system: current?.system,
            modeled: hasModeled ? current?.modeled : nil,
            charging: charging,
            cpu: hasModeled ? current?.cpu : nil,
            gpu: hasModeled ? current?.gpu : nil,
            ane: hasModeled ? current?.ane : nil,
            memory: hasModeled ? current?.memory : nil,
            media: hasModeled ? current?.media : nil,
            display: hasModeled ? current?.display : nil,
            other: hasModeled ? current?.other : nil,
            history: history.values
        )
    }

    private func readChargingDetail() -> ChargingDetail? {
        let now = Date()
        if cachedCharging == nil || now.timeIntervalSince(rawSystemLastRead) >= chargingCacheInterval {
            cachedCharging = batteryPowerReader.read()
            rawSystemLastRead = now
        }
        return cachedCharging
    }
}

// MARK: - Network

struct NetDetail {
    var upload: Double
    var download: Double
    var totalUp: UInt64
    var totalDown: UInt64
    var interfaceName: String     // BSD name, e.g. "en0"
    var displayName: String       // localized, e.g. "Wi-Fi"
    var macAddress: String        // e.g. "a4:c3:f0:12:34:56"
    var ssid: String?             // WiFi only
    var localIP: String
    var publicIP: String?         // async-fetched; nil until available
    var transmitRate: Double      // Mbps from ifi_baudrate
    var isUp: Bool
    var history: [(up: Double, down: Double)]
}

final class NetReader {
    private var prevUp: UInt64 = 0
    private var prevDown: UInt64 = 0
    private var cumulativeUp: UInt64 = 0
    private var cumulativeDown: UInt64 = 0
    private var lastTime = Date()
    private var history = PairHistory(capacity: 180)
    private let dynamicStore = SCDynamicStoreCreate(nil, "mactop" as CFString, nil, nil)
    private var primaryInterfaceLastRead = Date.distantPast
    private var cachedPrimaryInterface: String? = nil

    // Interface detail cache — refreshed at most every 15 s
    private var detailsLastRead = Date.distantPast
    private var cachedDisplayName = ""
    private var cachedMAC = ""
    private var cachedSSID: String? = nil
    private var cachedTransmitRate: Double = 0

    // Public IP — fetched async, at most every 300 s
    private var publicIPLastFetch = Date.distantPast
    private var cachedPublicIP: String? = nil
    private let publicIPLock = NSLock()

    func read() -> NetDetail {
        let preferredIface = primaryInterfaceName()
        var ifap: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifap) == 0, let head = ifap else {
            return NetDetail(upload: 0, download: 0, totalUp: cumulativeUp, totalDown: cumulativeDown,
                             interfaceName: "", displayName: "", macAddress: "", ssid: nil,
                             localIP: "", publicIP: lockedPublicIP(), transmitRate: 0, isUp: false, history: history.orderedValues)
        }
        defer { freeifaddrs(head) }

        var totalUp: UInt64 = 0
        var totalDown: UInt64 = 0
        var primaryIface = ""
        var localIP = ""
        var isUp = false
        var macFromLink = ""
        var transmitFromLink: Double = 0
        var linkDetails: [String: (isUp: Bool, mac: String, transmitRate: Double)] = [:]
        var ipByInterface: [String: String] = [:]
        var firstLinkInterface = ""
        var firstIPInterface = ""

        var cursor: UnsafeMutablePointer<ifaddrs>? = head
        while let iface = cursor {
            defer { cursor = iface.pointee.ifa_next }
            let name = String(cString: iface.pointee.ifa_name)
            guard name.hasPrefix("en") else { continue }

            if let addr = iface.pointee.ifa_addr,
               addr.pointee.sa_family == UInt8(AF_LINK),
               let raw = iface.pointee.ifa_data {
                let ifData = raw.assumingMemoryBound(to: if_data.self).pointee
                totalUp   += UInt64(ifData.ifi_obytes)
                totalDown += UInt64(ifData.ifi_ibytes)
                var mac = ""
                addr.withMemoryRebound(to: sockaddr_dl.self, capacity: 1) { sdl in
                    let alen = Int(sdl.pointee.sdl_alen)
                    let nlen = Int(sdl.pointee.sdl_nlen)
                    if alen == 6 {
                        mac = withUnsafeBytes(of: sdl.pointee.sdl_data) { raw in
                            Self.macString(bytes: raw, offset: nlen)
                        }
                    }
                }
                linkDetails[name] = (
                    isUp: (iface.pointee.ifa_flags & UInt32(IFF_UP)) != 0,
                    mac: mac,
                    transmitRate: Double(ifData.ifi_baudrate) / 1_000_000
                )
                if firstLinkInterface.isEmpty { firstLinkInterface = name }
            }

            if let addr = iface.pointee.ifa_addr,
               addr.pointee.sa_family == UInt8(AF_INET),
               ipByInterface[name] == nil {
                var rawAddr = addr.pointee
                var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                withUnsafeMutablePointer(to: &rawAddr) {
                    $0.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                        var inAddr = $0.pointee.sin_addr
                        inet_ntop(AF_INET, &inAddr, &buf, socklen_t(INET_ADDRSTRLEN))
                    }
                }
                ipByInterface[name] = String(cString: buf)
                if firstIPInterface.isEmpty { firstIPInterface = name }
            }
        }

        if let preferredIface, linkDetails[preferredIface] != nil {
            primaryIface = preferredIface
        } else if !firstIPInterface.isEmpty {
            primaryIface = firstIPInterface
        } else {
            primaryIface = firstLinkInterface
        }

        if let link = linkDetails[primaryIface] {
            isUp = link.isUp
            macFromLink = link.mac
            transmitFromLink = link.transmitRate
        }
        localIP = ipByInterface[primaryIface] ?? ""

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

        history.append(up: upRate, down: downRate)

        // Refresh slow/cached details
        if !macFromLink.isEmpty { cachedMAC = macFromLink }
        if transmitFromLink > 0 { cachedTransmitRate = transmitFromLink }
        refreshDetails(ifName: primaryIface)
        refreshPublicIP()

        return NetDetail(
            upload: upRate,
            download: downRate,
            totalUp: cumulativeUp,
            totalDown: cumulativeDown,
            interfaceName: primaryIface,
            displayName: cachedDisplayName,
            macAddress: cachedMAC,
            ssid: cachedSSID,
            localIP: localIP,
            publicIP: lockedPublicIP(),
            transmitRate: cachedTransmitRate,
            isUp: isUp,
            history: history.orderedValues
        )
    }

    private func primaryInterfaceName() -> String? {
        let now = Date()
        guard now.timeIntervalSince(primaryInterfaceLastRead) >= 15 else {
            return cachedPrimaryInterface
        }
        primaryInterfaceLastRead = now

        guard let dynamicStore,
              let global = SCDynamicStoreCopyValue(dynamicStore, "State:/Network/Global/IPv4" as CFString) as? [String: Any],
              let iface = global["PrimaryInterface"] as? String,
              !iface.isEmpty else { return nil }
        cachedPrimaryInterface = iface
        return iface
    }

    // Reads display name and SSID via SystemConfiguration — throttled to 15 s
    private func refreshDetails(ifName: String) {
        guard !ifName.isEmpty, Date().timeIntervalSince(detailsLastRead) >= 15 else { return }
        detailsLastRead = Date()

        for case let scIface as SCNetworkInterface in SCNetworkInterfaceCopyAll() as NSArray {
            guard let bsd = SCNetworkInterfaceGetBSDName(scIface) as String?,
                  bsd == ifName else { continue }
            cachedDisplayName = SCNetworkInterfaceGetLocalizedDisplayName(scIface) as String? ?? ifName
            // SSID for WiFi interfaces via SCDynamicStore
            let ifType = SCNetworkInterfaceGetInterfaceType(scIface) as String?
            if ifType == (kSCNetworkInterfaceTypeIEEE80211 as String) {
                let key = "State:/Network/Interface/\(ifName)/AirPort" as CFString
                if let dynamicStore,
                   let info = SCDynamicStoreCopyValue(dynamicStore, key) as? [String: Any] {
                    cachedSSID = info["SSID_STR"] as? String
                }
            } else {
                cachedSSID = nil
            }
            break
        }
    }

    // Fetches public IPv4 from ipify — throttled to 300 s, non-blocking
    private func refreshPublicIP() {
        guard Date().timeIntervalSince(publicIPLastFetch) >= 300,
              let publicIPURL = Self.publicIPURL else { return }
        publicIPLastFetch = Date()
        URLSession.shared.dataTask(with: publicIPURL) { [weak self] data, _, _ in
            guard let self, let data,
                  let ip = String(data: data, encoding: .utf8) else { return }
            self.publicIPLock.lock()
            self.cachedPublicIP = ip.trimmingCharacters(in: .whitespacesAndNewlines)
            self.publicIPLock.unlock()
        }.resume()
    }

    private func lockedPublicIP() -> String? {
        publicIPLock.lock()
        defer { publicIPLock.unlock() }
        return cachedPublicIP
    }

    private static let publicIPURL = URL(string: "https://api.ipify.org")

    private static func macString(bytes: UnsafeRawBufferPointer, offset: Int) -> String {
        guard offset + 5 < bytes.count else { return "" }
        let digits = Array("0123456789abcdef".utf8)
        var output = [UInt8]()
        output.reserveCapacity(17)
        for i in 0..<6 {
            let byte = bytes[offset + i]
            if i > 0 { output.append(58) }
            output.append(digits[Int(byte >> 4)])
            output.append(digits[Int(byte & 0x0f)])
        }
        return String(decoding: output, as: UTF8.self)
    }
}
